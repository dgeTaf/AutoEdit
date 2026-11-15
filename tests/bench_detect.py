"""Banc d'essai de la détection : signaux synthétiques à vérité terrain (tests/synth.py).

Mesure, par instrument et par scénario : rappel (attaques trouvées à ±20 ms), fausses détections, biais moyen,
écart-type, |erreur| au 95e centile et maximale, part des erreurs > 3 ms. Les notes liées (sans médiator)
sont comptées à part : les manquer est acceptable.
  py -3 tests/bench_detect.py            (rapide : 3 parties par cas)
  py -3 tests/bench_detect.py --n 10     (plus de parties)
Code de sortie 1 si un seuil d'acceptation n'est pas tenu (voir CRITERIA).
"""
import argparse
import io
import os
import sys

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ae_detect  # noqa: E402
import synth  # noqa: E402

# seuils d'acceptation (notes franches seulement)
# rappel = notes trouvées (sûres ou douteuses) ; sure_* = attaques « sûres » seulement (celles qui seront déplacées)
# Basse : la nouvelle note est souvent à peine plus forte que la précédente qui sonne encore -> beaucoup d'attaques
# douteuses (limite connue, voir docs/ALGORITHME.md) ; jouée ouverte : non exigé.
CRITERIA = dict(recall=0.97, fp_rate=0.04, sure_min=0.70, sure_min_bass=0.25, abs_bias_ms=0.5, p95_ms=1.0, gt3=0.01)


def match(truth, det, tol=0.020):
    """Appariement glouton par distance croissante. Renvoie (paires (i_vérité, j_détection, erreur), fausses)."""
    pairs = []
    for i, tr in enumerate(truth):
        for j, d in enumerate(det):
            e = d["t"] - tr["t"]
            if abs(e) <= tol:
                pairs.append((abs(e), i, j, e))
    pairs.sort()
    used_t, used_d, out = set(), set(), []
    for _, i, j, e in pairs:
        if i in used_t or j in used_d:
            continue
        used_t.add(i)
        used_d.add(j)
        out.append((i, j, e))
    fp = [j for j in range(len(det)) if j not in used_d]
    return out, fp


def run_case(kind, scenario, n_parts, seed):
    errs, n_true, n_found, n_fp, n_det, soft_true, soft_found = [], 0, 0, 0, 0, 0, 0
    n_sure, errs_all = 0, []
    worst = []
    for k in range(n_parts):
        rng = np.random.default_rng(seed + 1000 * k)
        notes, tempo = synth.make_part(kind, rng, dur=16.0, scenario=scenario)
        x, truth = synth.render(notes, 16.0, kind, rng)
        det = ae_detect.detect(x, kind)
        pairs, fp = match(truth, det, tol=0.040)
        found = {i: e for i, j, e in pairs if det[j]["sure"]}
        found_any = {i: e for i, _, e in pairs}
        for i, tr in enumerate(truth):
            if tr["soft"]:
                soft_true += 1
                soft_found += i in found_any
                continue
            n_true += 1
            n_found += i in found_any
            if i in found_any:
                errs_all.append(found_any[i])
            if i in found:
                n_sure += 1
                errs.append(found[i])
                if abs(found[i]) > 0.003:
                    worst.append((abs(found[i]) * 1000, k, tr["t"], tr["kind"]))
        n_fp += len(fp)
        n_det += len(det)
    e = np.array(errs) * 1000
    ea = np.abs(np.array(errs_all) * 1000)
    res = dict(kind=kind, scenario=scenario, n=n_true, recall=n_found / max(1, n_true), sure=n_sure / max(1, n_true),
               all_gt3=float(np.mean(ea > 3)) if len(ea) else 0.0,
               fp_rate=n_fp / max(1, n_det), bias_ms=float(e.mean()) if len(e) else 0.0,
               std_ms=float(e.std()) if len(e) else 0.0,
               p95_ms=float(np.percentile(np.abs(e), 95)) if len(e) else 0.0,
               max_ms=float(np.abs(e).max()) if len(e) else 0.0,
               gt3=float(np.mean(np.abs(e) > 3)) if len(e) else 0.0,
               soft=f"{soft_found}/{soft_true}")
    return res, sorted(worst, reverse=True)[:5]


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=3)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--kind", default="")
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()
    ok = True
    print("rappel = notes trouvées (à ±40 ms) ; sûres = part des notes trouvées ET sûres ; colonnes de temps :"
          " attaques sûres seulement ; (tout) : >3 ms parmi toutes les notes trouvées")
    print(f"{'instrument':10} {'scénario':8} {'notes':>5} {'rappel':>7} {'fausses':>8} {'sûres':>6} {'biais':>7} "
          f"{'ec.t':>6} {'p95':>6} {'max':>6} {'>3ms':>6} {'(tout)':>6} douces")
    for kind in ("guitar", "bass"):
        if a.kind and kind != a.kind:
            continue
        for sc in ("mute", "open", "mix", "fast"):
            r, worst = run_case(kind, sc, a.n, a.seed)
            bad = (r["recall"] < CRITERIA["recall"] or r["fp_rate"] > CRITERIA["fp_rate"]
                   or (r["sure"] < CRITERIA["sure_min_bass" if kind == "bass" else "sure_min"]
                       and not (kind == "bass" and sc == "open"))
                   or r["gt3"] > CRITERIA["gt3"]
                   or abs(r["bias_ms"]) > CRITERIA["abs_bias_ms"] or r["p95_ms"] > CRITERIA["p95_ms"])
            ok &= not bad
            print(f"{kind:10} {sc:8} {r['n']:5d} {r['recall']:7.1%} {r['fp_rate']:8.1%} {r['sure']:6.0%} "
                  f"{r['bias_ms']:+7.2f} {r['std_ms']:6.2f} {r['p95_ms']:6.2f} {r['max_ms']:6.2f} {r['gt3']:6.1%} "
                  f"{r['all_gt3']:6.0%} {r['soft']:>6}"
                  + ("   <-- HORS SEUIL" if bad else ""))
            if a.verbose and worst:
                print("    pires :", ", ".join(f"{w[0]:.1f} ms (partie {w[1]}, t={w[2]:.3f}, {w[3]})" for w in worst))
    print("OK" if ok else "ÉCHEC : au moins un cas hors seuil", CRITERIA)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
