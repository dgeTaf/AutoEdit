"""Test de recollage sur de VRAIES DI (projet de test de l'utilisateur, lecture seule).

1. Détection (ae_detect) sur la DI.
2. Chaque attaque sûre reçoit un déplacement aléatoire connu (±8 ms) ; le plan de coupe est calculé par
   AutoEdit_core.lua (exécuté par lupa, Lua 5.4 comme Reaper) : points de coupe, notes bloquées.
3. Le signal édité est reconstruit comme Reaper le jouerait (segments déplacés, fondus linéaires de 3 ms,
   à la fréquence d'origine).
4. Nouvelle détection : chaque attaque doit être retrouvée à t + déplacement ; on compte les attaques en trop
   (une attaque doublée par un raccord en ferait apparaître une) et les manquantes.

  out/venv/Scripts/python.exe tests/test_splice_real.py          (lupa requis : venv de développement)
Code de sortie 1 si un critère n'est pas tenu.
"""
import os
import sys

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import ae_detect  # noqa: E402
import ae_engine  # noqa: E402

FILES = [
    ("guitar", r"F:\reaper\death\15-guitar_left-260814_1725.wav"),
    ("guitar", r"F:\reaper\death\04-guitar_right2-260814_1722.wav"),
    ("guitar", r"F:\reaper\death\05-guitar_right3-260814_1726.wav"),
    ("bass", r"F:\reaper\death\23-bass Sat-260814_1739.wav"),
    ("bass", r"F:\reaper\death\24-bass Sat-260814_1820-glued-01.wav"),
]
MAX_SHIFT = 0.008
CRIT = dict(p95_ms=0.5, max_extra_frac=0.10, max_missing_frac=0.15)


def load_core():
    from lupa import lua54
    lua = lua54.LuaRuntime(unpack_returned_tuples=True)
    with open(os.path.join(ROOT, "AutoEdit_core.lua"), encoding="utf-8") as fh:
        core = lua.execute(fh.read())
    return lua, core


def render(src, fs, geo):
    """Reconstruit la lecture : chaque segment lit src depuis offs, placé à pos, fondus linéaires."""
    n = len(src)
    out = np.zeros(n + int(0.1 * fs))
    for g in geo:
        p0 = int(round(g["pos"] * fs))
        o0 = int(round(g["offs"] * fs))
        ln = int(round(g["len"] * fs))
        if p0 < 0:
            o0 -= p0
            ln += p0
            p0 = 0
        ln = min(ln, n - o0, len(out) - p0)
        if ln <= 0:
            continue
        seg = src[o0:o0 + ln].astype(np.float64).copy()
        if g["fadein"]:
            k = min(ln, int(round(g["fadein"] * fs)))
            seg[:k] *= np.linspace(0, 1, k, endpoint=False)
        if g["fadeout"]:
            k = min(ln, int(round(g["fadeout"] * fs)))
            seg[ln - k:] *= np.linspace(1, 0, k, endpoint=False)
        out[p0:p0 + ln] += seg
    return out[:n]


def run_file(lua, core, kind, path, seed):
    x, fs = sf.read(path, dtype="float32", always_2d=True)
    x = x.mean(axis=1)
    y = resample_poly(x, ae_detect.FS, fs).astype(np.float32)
    on = ae_engine.prepare(y, ae_detect.detect(y, kind), kind)
    rng = np.random.default_rng(seed)
    shifts = [float(rng.uniform(-MAX_SHIFT, MAX_SHIFT)) if o["sure"] else 0.0 for o in on]
    lon = lua.table_from([lua.table_from({"t": float(o["t"]), "t_start": float(o["t_start"]), "shift": s,
                                          "cuts": lua.table_from([float(c) for c in o["cuts"]])}) for o, s in zip(on, shifts)])
    opts = lua.table_from(dict(core.DEFAULTS))
    item = lua.table_from({"pos": 0.0, "len": len(x) / fs})
    plan = core.plan_item(item, lon, opts)
    geo_l = core.segment_geometry(item, plan.segs, opts)
    geo = [dict(pos=g.pos, len=g.len, offs=g.offs, fadein=g.fadein, fadeout=g.fadeout) for g in geo_l.values()]
    blocked = {int(k) - 1 for k in plan.blocked.keys()}
    applied = [lon[i + 1].shift_applied for i in range(len(on))]
    # invariant des raccords : la source lue par le segment précédent (étendu ou rogné, fondu compris) et le
    # fondu d'entrée finissent avant le début (prudent) de l'attaque qui suit la coupe -> pas d'attaque doublée
    segs = [(s.c, s.d, s.onset) for s in plan.segs.values()]
    xf, margin = core.DEFAULTS.xf_ms / 1000, core.DEFAULTS.margin_ms / 1000
    violations = 0
    for j in range(1, len(segs)):
        c, d, oi = segs[j]
        D = d - segs[j - 1][1]
        ts = on[int(oi) - 1]["t_start"]
        if c + max(D, 0) + xf > ts - margin + 1e-9:
            violations += 1
        # aucune autre attaque (douteuse comprise) entre la coupe et la fin de la source révélée
        for o in on:
            if c - 1e-9 <= o["t_start"] < c + max(D, 0) + xf and o is not on[int(oi) - 1]:
                violations += 1
    z = render(x, fs, geo)
    z22 = resample_poly(z, ae_detect.FS, fs).astype(np.float32)
    on2 = ae_detect.detect(z22, kind)
    t2 = np.array([o["t"] for o in on2])
    # attendus : toutes les attaques d'origine, déplacées de ce qui a été appliqué
    errs, used, missing = [], set(), 0
    for i, o in enumerate(on):
        exp = o["t"] + (applied[i] or 0.0)
        j = int(np.argmin(np.abs(t2 - exp))) if len(t2) else -1
        if j >= 0 and abs(t2[j] - exp) < 0.010:
            used.add(j)
            if o["sure"] and on2[j]["sure"] and i not in blocked:
                errs.append((t2[j] - exp) * 1000)
        else:
            missing += 1
    # attaques en trop : à moins de 3 ms d'un raccord (saut de phase du fondu, revu par le flux) ou ailleurs
    bounds = np.array([c + d for c, d, _ in segs[1:]]) if len(segs) > 1 else np.array([-1.0])
    extra = [t2[j] for j in range(len(t2)) if j not in used]
    at_join = [t for t in extra if np.min(np.abs(bounds - t)) < 0.003]
    other = [t for t in extra if np.min(np.abs(bounds - t)) >= 0.003]
    e = np.abs(np.array(errs)) if errs else np.zeros(1)
    return dict(name=os.path.basename(path)[:34], n=len(on), sure=sum(o["sure"] for o in on), segs=len(geo) - 1,
                blocked=len(blocked), p95=float(np.percentile(e, 95)), emax=float(e.max()),
                bias=float(np.mean(errs)) if errs else 0.0, extra=len(other), join=len(at_join), missing=missing,
                extra_t=other[:5], viol=violations)


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    lua, core = load_core()
    ok = True
    print("temps : attaques sûres non bloquées ; « raccord » : attaque revue à < 3 ms d'un raccord (saut de phase "
          "du fondu, ignorée à une nouvelle analyse) ; « viol. » : raccords qui révéleraient une attaque (doit être 0)")
    print(f"{'fichier':34} {'notes':>5} {'sûres':>5} {'coupes':>6} {'bloq.':>5} {'biais':>6} {'p95':>5} {'max':>5} "
          f"{'en trop':>7} {'raccord':>7} {'manq.':>5} {'viol.':>5}")
    for k, (kind, path) in enumerate(FILES):
        if not os.path.exists(path):
            print("absent :", path)
            continue
        r = run_file(lua, core, kind, path, seed=10 + k)
        bad = (r["p95"] > CRIT["p95_ms"] or r["extra"] > max(1, CRIT["max_extra_frac"] * r["n"])
               or r["missing"] > max(1, CRIT["max_missing_frac"] * r["n"]) or r["viol"] > 0)
        ok &= not bad
        print(f"{r['name']:34} {r['n']:5d} {r['sure']:5d} {r['segs']:6d} {r['blocked']:5d} {r['bias']:+6.2f} "
              f"{r['p95']:5.2f} {r['emax']:5.2f} {r['extra']:7d} {r['join']:7d} {r['missing']:5d} {r['viol']:5d}"
              + ("   <-- HORS SEUIL " + str([round(t, 3) for t in r["extra_t"]]) if bad else ""))
    print("OK" if ok else "ÉCHEC", CRIT)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
