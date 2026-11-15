"""AutoEdit : moteur lancé par Reaper (en arrière-plan) sur les WAV exportés par AutoEdit_GUI.lua.

  py -3 ae_engine.py --job <job.json> --out <result.lua> [--log <log.txt>]

job.json : { "items": [ { "id": "...", "wav": "chemin", "kind": "guitar" | "bass" } ... ] }
Les WAV sont mono float32 22050 Hz (export par take accessor, audio du take AVANT les effets de piste).
Résultat : result.lua (table Lua relue par Reaper), temps en secondes depuis le début de chaque WAV :
  return { version = 1, items = { ["id"] = { onsets = { { t=, ts=, conf=, sure=, amb=, contrast=,
           cuts = { temps candidats de coupe... } } ... } } } }
En cas d'erreur : error.txt à côté de result.lua.
"""
import argparse
import json
import os
import sys
import time
import traceback

import numpy as np
import soundfile as sf

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ae_detect  # noqa: E402

LOG = None


def log(msg):
    line = time.strftime("[%H:%M:%S] ") + msg
    if LOG:
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        print(line, flush=True)


def cut_candidates(x, t_from, t_to, fs=ae_detect.FS, n_max=16):
    """Points de coupe candidats dans [t_from, t_to] (s) : creux locaux d'énergie (RMS 1 ms) ramenés au passage
    par zéro le plus proche (±1 ms). Triés par temps ; on garde les n_max plus tardifs (proches de l'attaque)."""
    a, b = max(1, int(t_from * fs)), min(len(x) - 2, int(t_to * fs))
    if b - a < 4:
        return []
    w = max(1, int(0.001 * fs))
    seg = x[max(0, a - w):b + w + 1].astype(np.float64)
    c = np.cumsum(np.concatenate([[0.0], seg * seg]))
    e = (c[2 * w:] - c[:-2 * w])          # énergie centrée sur ±w, alignée sur [a, b]
    e = e[:b - a + 1]
    out = []
    r = w
    for k in range(r, len(e) - r):
        if e[k] <= e[k - r:k + r + 1].min():
            n = a + k
            # passage par zéro le plus proche
            best = None
            for j in range(max(a, n - w), min(b, n + w)):
                if x[j] == 0 or (x[j] > 0) != (x[j + 1] > 0):
                    if best is None or abs(j - n) < abs(best - n):
                        best = j
            if best is not None:
                # interpolation linéaire du zéro
                y0, y1 = x[best], x[best + 1]
                frac = y0 / (y0 - y1) if y0 != y1 else 0.0
                tz = (best + frac) / fs
                if not out or tz - out[-1] > 0.0005:
                    out.append(float(tz))
    return out[-n_max:]


def analyse_item(wav, kind):
    x, fs = sf.read(wav, dtype="float32", always_2d=True)
    x = x.mean(axis=1)
    if fs != ae_detect.FS:
        from scipy.signal import resample_poly
        x = resample_poly(x, ae_detect.FS, fs).astype(np.float32)
    on = prepare(x, ae_detect.detect(x, kind), kind)
    return on, len(x) / ae_detect.FS


def prepare(x, on, kind):
    """Début d'attaque prudent et points de coupe candidats.
    Attaque douteuse : sa vraie position peut être plus tôt ; on prend le plus tôt plausible (temps du flux
    - 2,5 écarts-types, et au moins 10 ms avant t), pour qu'aucun segment voisin révélé ne contienne l'attaque."""
    p = ae_detect.PARAMS[kind]
    prev = 0.0
    for o in on:
        if not o["sure"]:
            o["t_start"] = min(o["t_start"], o["t_flux"] - 2.5 * p["flux_sigma_ms"] / 1000.0, o["t"] - 0.010)
            o["t_start"] = max(o["t_start"], prev + 0.002)
        o["cuts"] = cut_candidates(x, prev + 0.005, o["t_start"] - 0.0005)
        prev = o["t"]
    return on


def lua_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float, np.floating, np.integer)):
        return repr(round(float(v), 6))
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'
    if isinstance(v, (list, tuple)):
        return "{" + ",".join(lua_value(e) for e in v) + "}"
    if isinstance(v, dict):
        return "{" + ",".join(f"[{lua_value(str(k))}]={lua_value(e)}" for k, e in v.items()) + "}"
    raise TypeError(type(v))


def main():
    global LOG
    ap = argparse.ArgumentParser()
    ap.add_argument("--job", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--log")
    a = ap.parse_args()
    LOG = a.log
    err_path = os.path.join(os.path.dirname(os.path.abspath(a.out)), "error.txt")
    try:
        with open(a.job, encoding="utf-8") as fh:
            job = json.load(fh)
        items = {}
        n = len(job["items"])
        for i, it in enumerate(job["items"]):
            t = time.time()
            on, dur = analyse_item(it["wav"], it.get("kind", "guitar"))
            keep = ("t", "t_start", "conf", "sure", "amb", "contrast", "cuts")
            items[str(it["id"])] = {"dur": dur, "onsets": [{k: o[k] for k in keep} for o in on]}
            log(f"{i + 1}/{n} {os.path.basename(it['wav'])} : {len(on)} attaques "
                f"({sum(o['sure'] for o in on)} sûres) en {time.time() - t:.1f} s")
        tmp = a.out + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write("return " + lua_value({"version": 1, "items": items}) + "\n")
        os.replace(tmp, a.out)
        log("terminé")
    except Exception:
        tb = traceback.format_exc()
        log(tb)
        with open(err_path, "w", encoding="utf-8") as fh:
            fh.write(tb)
        sys.exit(1)


if __name__ == "__main__":
    main()
