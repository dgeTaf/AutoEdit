"""AutoEdit : détection des attaques de guitare / basse sur une DI (mono, 22050 Hz).

Deux étapes (détails et mesures : docs/ALGORITHME.md) :

1. TROUVER les notes : flux spectral « SuperFlux » (STFT, log, différence positive avec la trame de quelques ms
   avant, maximum en fréquence sur la trame de référence pour ignorer vibrato et battements). Un changement de
   note fait apparaître de nouvelles fréquences même si la note est plus faible que la précédente ; les
   ondulations à la fondamentale (DI = suite d'impulsions, une par période) sont moyennées par la fenêtre.
   Pics du flux au-dessus d'une moyenne locale ; pics trop proches regroupés (le plus fort gardé).
2. DATER chaque note : enveloppe CAUSALE (passe-bande causal, moyenne glissante de x², aucune pré-réponse, donc
   jamais en avance) dans une fenêtre autour du pic de flux. Marche = maximum de
       J(k) = max(env[k, k+post]) - max(env[k-pre, k])      (pre >= une période : la queue de la note d'avant)
   c.-à-d. la première impulsion qui dépasse franchement la note précédente ; instant = franchissement de
   pre + tfrac * J, interpolé. Deux bandes essayées (large, aiguë = médiator) : la plus nette l'emporte.
   Mesuré au banc : marche >= 6 dB -> datation fiable (p95 < 1 ms) ; en dessous l'attaque est DOUTEUSE :
   recherche limitée autour du temps du flux corrigé de son avance moyenne (guitare 4,8 ms, basse 10,7 ms).

Aucune dépendance à Reaper : utilisé par ae_engine.py et par le banc d'essai (tests/bench_detect.py).
"""
import numpy as np
from scipy.ndimage import maximum_filter, maximum_filter1d, uniform_filter1d
from scipy.signal import butter, sosfilt, stft

FS = 22050

PARAMS = {
    "guitar": dict(nfft=1024, hop=64, lam=100.0, mu=3, fmin=70.0, fmax=9000.0, thr=0.10, local_ms=120.0,
                   local_k=0.8, group_ms=35.0, flux_lead_ms=4.8, flux_sigma_ms=2.0,
                   tbands=((300.0, 9000.0, 0.5), (2000.0, 9000.0, 0.5)), tpre_ms=14.0, tpost_ms=1.5,
                   tsearch=(-12.0, 30.0), tfrac=0.5, tmin_db=3.0, tsure_db=6.0, tlat_ms=0.0),
    "bass": dict(nfft=2048, hop=64, lam=100.0, mu=4, fmin=35.0, fmax=4000.0, thr=0.10, local_ms=150.0,
                 local_k=0.8, group_ms=45.0, flux_lead_ms=10.7, flux_sigma_ms=4.8,
                 tbands=((60.0, 3000.0, 1.0), (500.0, 4000.0, 0.7)), tpre_ms=28.0, tpost_ms=3.0,
                 tsearch=(-15.0, 40.0), tfrac=0.5, tmin_db=3.0, tsure_db=8.0, tlat_ms=0.0),
}


def superflux(x, p, fs=FS):
    """Renvoie (temps des trames en s, flux normalisé). Le temps d'une trame est le centre de sa fenêtre."""
    f, t, Z = stft(x, fs, nperseg=p["nfft"], noverlap=p["nfft"] - p["hop"], boundary=None, padded=False)
    band = (f >= p["fmin"]) & (f <= p["fmax"])
    S = np.log1p(p["lam"] * np.abs(Z[band]))
    ref = maximum_filter(S, size=(3, 1))
    mu = p["mu"]
    D = np.zeros(S.shape[1])
    if S.shape[1] > mu:
        D[mu:] = np.maximum(S[:, mu:] - ref[:, :-mu], 0).sum(0)
    scale = np.percentile(D, 99) if len(D) else 1.0
    return t, D / (scale + 1e-12)


def causal_env_db(x, band, win_ms, fs=FS):
    """Enveloppe causale en dB (0 = crête) : passe-bande causal d'ordre 2, moyenne glissante causale de x²."""
    hi = min(band[1], 0.45 * fs)
    sos = butter(2, [band[0], hi], btype="bandpass", fs=fs, output="sos")
    y = sosfilt(sos, x) ** 2
    w = max(1, int(round(win_ms * fs / 1000)))
    c = np.cumsum(np.concatenate([[0.0], y]))
    e = np.empty(len(y))
    e[w - 1:] = (c[w:] - c[:-w]) / w
    e[:w - 1] = c[1:w] / np.arange(1, w)
    pk = e.max() if len(e) else 0.0
    return 10 * np.log10(e / (pk + 1e-30) + 1e-12)


def _cmax_pre(e, w):
    """max de e sur [k-w, k-1]."""
    m = maximum_filter1d(e, w, origin=(w - 1) // 2, mode="nearest")
    return np.concatenate([[e[0]], m[:-1]])


def _cmax_post(e, w):
    """max de e sur [k, k+w-1]."""
    return maximum_filter1d(e, w, origin=-(w // 2), mode="nearest")


def step_time(e, pre_m, post_m, a, b, p, fs=FS):
    """Marche la plus nette de e dans [a, b). Renvoie (échantillon fractionnaire, contraste dB) ou (None, J)."""
    if b - a < 2:
        return None, 0.0
    J = post_m[a:b] - pre_m[a:b]
    j = int(np.argmax(J))
    contrast = float(J[j])
    if contrast < p["tmin_db"]:
        return None, contrast
    k = a + j
    thr = pre_m[k] + p["tfrac"] * contrast
    hi = min(len(e), k + int(p["tpost_ms"] * fs / 1000) + 1)
    idx = np.flatnonzero(e[k:hi] > thr)
    k1 = k + (idx[0] if len(idx) else 0)
    if k1 == 0:
        return float(k1), contrast
    y0, y1 = e[k1 - 1], e[k1]
    frac = (thr - y0) / (y1 - y0) if y1 > y0 else 1.0
    return k1 - 1 + max(0.0, min(1.0, frac)) - p["tlat_ms"] * fs / 1000, contrast


def analyse(x, kind="guitar", fs=FS, params=None):
    """Renvoie (onsets, aux). onsets : dicts triés par temps (s depuis le début de x) :
    t (attaque), t_start (début de montée, pour placer une coupe avant), strength (flux), contrast (dB),
    conf (0-1), amb (ambiguë : un autre pic de flux presque aussi fort tout près),
    sure (marche nette >= tsure_db et pas ambiguë : seules ces attaques sont déplacées par défaut)."""
    p = dict(PARAMS[kind])
    if params:
        p.update(params)
    x = np.asarray(x, np.float64)
    if x.ndim > 1:
        x = x.mean(axis=1)
    ms = fs / 1000.0
    if len(x) < p["nfft"] * 2:
        return [], {}
    tt, D = superflux(x, p, fs)
    hop_ms = p["hop"] / ms
    # pics du flux au-dessus d'un seuil absolu et d'une moyenne locale
    loc = D >= maximum_filter1d(D, 3)
    avg = uniform_filter1d(D, max(3, int(p["local_ms"] / hop_ms)) | 1)
    cand = np.flatnonzero(loc & (D > p["thr"]) & (D > p["local_k"] * avg))
    # regroupement : par force décroissante, on écarte les pics à moins de group_ms d'un pic gardé
    g = p["group_ms"] / hop_ms
    kept, rivals = [], {}
    for i in sorted(cand, key=lambda i: -D[i]):
        owner = next((k for k in kept if abs(k - i) < g), None)
        if owner is None:
            kept.append(i)
            rivals[i] = []
        else:
            rivals[owner].append(i)
    kept.sort()

    envs = []
    for lo, hi, win in p["tbands"]:
        e = causal_env_db(x, (lo, hi), win, fs)
        envs.append((e, _cmax_pre(e, int(p["tpre_ms"] * ms)), _cmax_post(e, max(1, int(p["tpost_ms"] * ms)))))

    def best_step(a, b):
        best = (None, 0.0)
        for e, pre_m, post_m in envs:
            r = step_time(e, pre_m, post_m, a, b, p, fs)
            if r[0] is None:
                continue
            # la plus nette ; à netteté proche (3 dB), la plus précoce
            if best[0] is None or r[1] > best[1] + 3.0 or (r[1] > best[1] - 3.0 and r[0] < best[0]):
                best = r
        return best

    onsets = []
    prev_t = -1.0
    for idx, i in enumerate(kept):
        tc = tt[i] + p["flux_lead_ms"] / 1000.0          # temps du flux corrigé de son avance moyenne
        a = int((tt[i] + p["tsearch"][0] / 1000.0) * fs)
        b = int((tt[i] + p["tsearch"][1] / 1000.0) * fs)
        lo_b = int((prev_t + 0.012) * fs) if prev_t >= 0 else 1      # pas avant l'attaque précédente + 12 ms
        hi_b = int((tt[kept[idx + 1]] - 0.005) * fs) if idx + 1 < len(kept) else len(x) - 1
        a, b = max(a, lo_b, 1), min(b, hi_b, len(x) - 1)
        best = best_step(a, b)
        sure = best[0] is not None and best[1] >= p["tsure_db"]
        how = "step" if sure else "flux"
        if not sure:
            # marche peu nette (la note d'avant sonne encore) : recherche limitée près du temps du flux
            # (±2,5 écarts-types). Un résidu de peigne (x[n] - x[n-T]) a été essayé : 16-28 % d'erreurs, écarté.
            w = 2.5 * p["flux_sigma_ms"] / 1000.0
            best = best_step(max(lo_b, int((tc - w) * fs)), min(hi_b, int((tc + w) * fs)))
            how = "step?" if best[0] is not None else "flux"
        timed = best[0] is not None
        t = best[0] / fs if timed else tc
        # début de montée : creux de l'enveloppe large dans les 10 ms qui précèdent
        e0 = envs[0][0]
        k = int(t * fs)
        lo = max(0, k - int(10 * ms))
        t_start = (lo + int(np.argmin(e0[lo:k + 1]))) / fs if k > lo else t
        amb = any(D[j] >= 0.7 * D[i] and abs(j - i) * hop_ms > 12 for j in rivals[i])
        if sure:
            conf = 0.6 + 0.4 * min(1.0, max(0.0, best[1] - p["tsure_db"]) / 10.0)
        else:
            conf = 0.15 + 0.2 * min(1.0, best[1] / p["tsure_db"])
        conf *= min(1.0, 0.5 + D[i])
        if amb:
            conf *= 0.5
        onsets.append(dict(t=float(t), t_start=float(min(t_start, t)), strength=float(D[i]),
                           contrast=float(best[1]), conf=round(float(conf), 3), amb=bool(amb),
                           sure=bool(sure and not amb), how=how, t_flux=float(tc)))
        prev_t = t
    return onsets, dict(tt=tt, flux=D, envs=envs)


def detect(x, kind="guitar", fs=FS, params=None):
    return analyse(x, kind, fs, params)[0]
