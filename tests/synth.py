"""Générateur de DI synthétiques à vérité terrain (guitare et basse), pour le banc d'essai.

Corde de Karplus-Strong (synthèse à 44100 Hz puis rééchantillonnage à 22050 Hz comme le fait l'export).
Vérité terrain = instant où l'excitation de la première corde commence. Effets réalistes inclus :
accords de 2-3 cordes avec léger étalement (aller du médiator), clic du médiator, étouffé (palm mute) ou
ouvert, notes précédentes qui sonnent encore sur d'autres cordes (battements), coupure de la note précédente
sur la même corde, variations de niveau, bruit de fond et ronflette 50 Hz, notes liées sans médiator (douces).
"""
import numpy as np
from scipy.signal import butter, lfilter, resample_poly

SR = 44100
OUT_FS = 22050


def ks_string(f0, dur, decay_s, bright, rng, sr=SR):
    """Corde de Karplus-Strong. decay_s : temps pour -60 dB ; bright 0..1 (excitation plus ou moins filtrée)."""
    period = sr / f0
    L = int(period)
    n = max(int(dur * sr), L + 2)
    frac = period - L
    # corde pincée : forme initiale en triangle (pincement à 10-30 % de la longueur), vue par le micro comme une
    # vitesse -> impulsions ; un peu de bruit pour varier le timbre
    beta = rng.uniform(0.1, 0.3)
    k = max(1, int(beta * L))
    tri = np.concatenate([np.linspace(0, 1, k, endpoint=False), np.linspace(1, 0, L - k)])
    exc = np.diff(tri, prepend=0.0)
    exc = exc / (np.abs(exc).max() + 1e-12) + rng.uniform(-0.15, 0.15, L)
    if bright < 1:
        b, a = butter(1, 500 + 6000 * bright, fs=sr)
        exc = lfilter(b, a, exc)
    exc -= exc.mean()
    # gain de boucle pour atteindre -60 dB en decay_s
    loops = decay_s * f0
    g = 10 ** (-3 / max(loops, 1))
    y = np.zeros(n)
    buf = np.zeros(L + 2)
    buf[:L] = exc
    # boucle vectorisée par périodes : y[i] = g * (0.5*(y[i-L] + y[i-L-1])) avec retard fractionnaire approché
    y[:L] = exc
    c = 0.5 + 0.5 * frac   # pondération pour l'accord fin
    for i in range(L, n, L):
        j = min(n, i + L)
        prev = y[i - L:j - L]
        prev2 = y[i - L - 1:j - L - 1] if i - L - 1 >= 0 else np.concatenate([[0], y[i - L:j - L - 1]])
        if len(prev2) < len(prev):
            prev2 = np.concatenate([[0] * (len(prev) - len(prev2)), prev2])
        y[i:j] = g * ((1 - c) * prev + c * prev2)
    return y[:max(1, int(dur * sr))]


def pick_click(rng, sr=SR, amp=0.3):
    n = int(0.0015 * sr)
    c = rng.normal(0, 1, n) * np.hanning(2 * n)[n:] * amp
    b, a = butter(2, 2000, btype="high", fs=sr)
    return lfilter(b, a, c)


def render(notes, dur, kind, rng, noise_db=-72, hum_db=-62):
    """notes : liste de dicts {t, f0s, decay, bright, amp, click, spread_ms, string}. Renvoie (signal 22050 Hz, vérité)."""
    n = int(dur * SR)
    out = np.zeros(n)
    voices = {}   # corde -> (début, signal) pour couper la note précédente sur la même corde
    truth = []
    for nt in sorted(notes, key=lambda d: d["t"]):
        i0 = int(round(nt["t"] * SR))
        if i0 >= n:
            continue
        tail = n - i0
        sig = np.zeros(min(tail, int(3 * SR)))
        for k, f0 in enumerate(nt["f0s"]):
            off = int(k * nt.get("spread_ms", 0) * SR / 1000)
            s = ks_string(f0, (len(sig) + 2) / SR, nt["decay"], nt["bright"], rng)
            s *= nt["amp"] / (1 + 0.3 * k)
            sig[off:] += s[:len(sig) - off]
        # les aigus s'éteignent bien plus vite que la fondamentale (corde réelle) : constante hi_tau
        bl, al = butter(2, 1500, fs=SR)
        lowp = lfilter(bl, al, sig)
        tau = nt.get("hi_tau", 0.08)
        sig = lowp + (sig - lowp) * np.exp(-np.arange(len(sig)) / (tau * SR))
        if nt.get("click", 0) > 0:
            c = pick_click(rng, amp=nt["click"] * nt["amp"])
            sig[:len(c)] += c
        # coupe la note précédente sur la même corde (étouffement en 3 ms)
        st = nt.get("string", 0)
        if st in voices:
            p0, psig = voices[st]
            end = min(p0 + len(psig), n)
            if i0 < end:
                rem = psig[i0 - p0:end - p0]
                keep = np.zeros(len(rem))
                fade = min(int(0.003 * SR), len(rem))
                keep[:fade] = np.linspace(1, 0, fade)
                out[i0:end] -= rem * (1 - keep)
        m = min(len(sig), n - i0)
        out[i0:i0 + m] += sig[:m]
        voices[st] = (i0, sig[:m])
        truth.append(dict(t=nt["t"], soft=nt.get("soft", False), kind=nt.get("tag", "")))
    out += rng.normal(0, 10 ** (noise_db / 20), n)
    out += 10 ** (hum_db / 20) * np.sin(2 * np.pi * 50 * np.arange(n) / SR)
    y = resample_poly(out, 1, 2)
    y = y / (np.max(np.abs(y)) + 1e-12) * 0.5
    return y.astype(np.float32), truth



GUITAR_ROOTS = [82.41, 87.31, 98.0, 110.0, 123.47, 130.81, 146.83, 164.81]   # E2..E3
BASS_ROOTS = [41.2, 43.65, 49.0, 55.0, 61.74, 65.41, 73.42, 82.41]


def make_part(kind, rng, dur=20.0, tempo=None, scenario="mix"):
    """Partie aléatoire : mesures en croches / doubles / triolets, silences, écarts de jeu ±10 ms.
    scenario : 'mute' (palm mute serré), 'open' (accords qui sonnent), 'mix', 'fast' (doubles rapides)."""
    tempo = tempo or rng.uniform(110, 210)
    beat = 60 / tempo
    t = 0.3
    notes = []
    roots = GUITAR_ROOTS if kind == "guitar" else BASS_ROOTS
    while t < dur - 1.0:
        sub = rng.choice([2, 4, 3, 6] if scenario != "fast" else [4, 4, 6])
        if kind == "bass" and sub == 6 and tempo > 160:
            sub = 4
        step = beat / sub
        for k in range(int(4 * sub)):
            if rng.random() < 0.15:
                continue
            tj = t + k * step + rng.uniform(-0.010, 0.010)
            if notes and tj - notes[-1]["t"] < 0.040:
                continue
            ri = rng.integers(len(roots))
            mute = scenario == "mute" or (scenario in ("mix", "fast") and rng.random() < 0.55)
            if kind == "guitar":
                f0s = [roots[ri], roots[ri] * 1.4983] + ([roots[ri] * 2] if rng.random() < 0.5 else [])
                nt = dict(t=tj, f0s=f0s, decay=rng.uniform(0.08, 0.2) if mute else rng.uniform(1.0, 2.5),
                          bright=0.35 if mute else 0.8, amp=10 ** (rng.uniform(-8, 0) / 20),
                          click=rng.uniform(0.3, 1.0), spread_ms=rng.uniform(0, 4), string=ri % 3,
                          hi_tau=rng.uniform(0.03, 0.08) if mute else rng.uniform(0.08, 0.25),
                          tag="mute" if mute else "open")
            else:
                f0s = [roots[ri]]
                nt = dict(t=tj, f0s=f0s, decay=rng.uniform(0.3, 0.8) if mute else rng.uniform(1.5, 3.0),
                          bright=rng.uniform(0.15, 0.5), amp=10 ** (rng.uniform(-6, 0) / 20),
                          click=rng.uniform(0.0, 0.3), string=ri % 2, tag="mute" if mute else "open",
                          hi_tau=rng.uniform(0.05, 0.2))
            if rng.random() < 0.05:      # note liée (hammer-on) : pas de médiator, douce
                nt.update(click=0, amp=nt["amp"] * 0.4, bright=0.2, soft=True, tag="soft")
            notes.append(nt)
        t += 4 * beat
    return notes, tempo
