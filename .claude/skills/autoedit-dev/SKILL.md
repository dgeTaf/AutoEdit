---
name: autoedit-dev
description: Reprendre le développement d'AutoEdit (script Reaper qui cale les attaques de guitare / basse DI sur la grille de tempo). À charger avant toute modification de AutoEdit_*.lua, ae_detect.py, ae_engine.py ou des tests, pour corriger une erreur remontée par l'utilisateur, régler la détection ou lancer les tests.
---

# Développer AutoEdit

Lire d'abord `CLAUDE.md` (décisions, état) et `docs/ALGORITHME.md` (méthode, seuils, mesures : ne pas revenir sur
un choix écarté sans relire pourquoi).

## Architecture

| Fichier | Rôle | Contraintes |
|---|---|---|
| `AutoEdit.lua` | lanceur | `dofile` de `AutoEdit_GUI.lua` |
| `AutoEdit_GUI.lua` | fenêtre, déroulement | aucune action Reaper pendant le dessin : `later(fn)` ; crochet `AUTOEDIT_TEST` |
| `AutoEdit_core.lua` | grille, choix de subdivision, propositions, plan de coupe | **pur** (aucun appel Reaper) : testable par lupa |
| `AutoEdit_reaper.lua` | export, moteur, application, sauvegardes, retour | sans ImGui |
| `AutoEdit_theme.lua` | thème gris perle | cartes = groupes, **jamais `BeginChild`** (plantage ReaImGui 0.10) |
| `ae_detect.py` | détection | sans Reaper ; `PARAMS` par type |
| `ae_engine.py` | job.json -> result.lua | `prepare()` : début d'attaque prudent + points de coupe |

## Règles
- Les temps d'attaque viennent de l'enveloppe **causale** (jamais de filtrage à phase nulle ni de lissage
  symétrique pour dater : avance de 2-10 ms mesurée).
- Toute modification du plan de coupe doit garder l'invariant « aucun raccord ne révèle une attaque »
  (`tests/test_splice_real.py`, colonne viol. = 0).
- Ne jamais modifier le projet de test de l'utilisateur : tests Reaper en instance séparée sur `out/`.
- Fichiers et messages en français ; texte affiché passé par `clean()` (police ImGui sans œ … − —).
- Commits sur `dev`, push et fusion sur demande.

## Tester
```bash
py -3 tests/bench_detect.py
```
```bash
out/venv/Scripts/python.exe tests/test_splice_real.py
```
```bash
py -3 tests/test_reaper_e2e.py --capture
```
```bash
py -3 tests/probe_api_reaper.py
```
`bench_detect` : synthèse à vérité terrain (critères dans `CRITERIA`). `test_splice_real` : vraies DI, déplacements
connus via le vrai plan Lua. `test_reaper_e2e` : vrai Reaper, analyse -> application -> réanalyse -> retour,
capture de la seule fenêtre AutoEdit (`out/capture_gui.png`, à regarder). `probe_api_reaper` : sémantique des API.

Venv de dev si absent : `py -3 -m venv out/venv` puis
`out/venv/Scripts/python.exe -m pip install numpy scipy soundfile lupa matplotlib`.

## Régler la détection
Tracer un passage : forme d'onde, enveloppes causales, flux, attaques (vertes = sûres) avec matplotlib du venv ;
la vraie DI est une suite d'impulsions (une par période). Mesurer l'effet sur `bench_detect` **et** `test_splice_real`
avant de garder un changement ; mettre à jour les tableaux de `docs/ALGORITHME.md`.
