# AutoEdit

Script **Reaper** (ReaScript Lua + ReaImGui) qui cale automatiquement les attaques des guitares et basses
enregistrées en DI sur la **grille de tempo du projet** (4/4, 6/8, changements de mesure). Il remplace le travail
à la main : couper l'item juste avant l'attaque, recaler la tranche, réparer le raccord.

- Lit l'audio du take **avant les effets** (take accessor : Neural DSP n'intervient pas).
- Détection en Python (numpy, scipy, soundfile), lancée en arrière-plan : Reaper ne se fige pas.
- Subdivision choisie par mesure (temps, croches, triolets, doubles, triolets de double), modifiable.
- Notes hors grille (syncopes, swing) et mesures irrégulières laissées intactes ; attaques douteuses signalées.
- Coupe juste avant chaque attaque (creux d'énergie, passage par zéro), fondu de 3 ms, jamais d'attaque doublée.
- Retour arrière : Ctrl+Z, copie datée du .rpp, pistes muettes « AutoEdit original », bouton « Revenir à l'état d'avant ».

## Installation

1. **ReaImGui** (ReaPack : Extensions > ReaPack > Browse packages > « ReaImGui »), puis redémarrer Reaper.
2. **Python 3** avec les modules : `py -3 -m pip install numpy scipy soundfile`
   (le `python` du PATH peut être celui d'Inkscape, sans pip : utiliser `py -3`). Le script trouve lui-même
   `%LOCALAPPDATA%\Programs\Python\Python3xx\python.exe` ; sinon, renseigner `PYTHON` en tête de `AutoEdit_GUI.lua`.
3. Dans Reaper : Actions > Show action list > New action > Load ReaScript… > `AutoEdit.lua` (laisser les autres
   fichiers dans le même dossier).

## Utilisation en bref

1. Sélectionner les pistes à caler et faire une **sélection de temps** (un riff, 5 à 30 s).
2. **Analyser les pistes sélectionnées**. Le tableau liste les attaques : position (mesure.temps), écart actuel,
   décalage proposé, état (à déplacer, déjà calée, hors grille, douteuse, mesure irrégulière, bloquée).
   Un clic sur une position place le curseur d'édition sur l'attaque.
3. Régler si besoin : force (0-100 %), écart max, subdivisions possibles, type et décalage voulu par piste
   (ex. basse +2 ms en arrière), force réduite proposée pour les doublures gauche/droite, subdivision forcée
   d'une mesure. Décocher une attaque pour la laisser telle quelle.
4. **Appliquer**. Avant la 1re application : copie datée du .rpp (le script propose d'enregistrer si le projet
   est modifié) et une piste muette « AutoEdit original : … » avec les items d'origine.
5. Écouter. Ctrl+Z annule ; **Revenir à l'état d'avant** annule toutes les applications de la session.

Pistes ignorées (avec un message) : items à vitesse de lecture modifiée, avec marqueurs d'étirement, MIDI,
verrouillés. Détails : [docs/UTILISATION.md](docs/UTILISATION.md) ; algorithmes et mesures :
[docs/ALGORITHME.md](docs/ALGORITHME.md).

## Fichiers

| Fichier | Rôle |
|---|---|
| `AutoEdit.lua` | lanceur (nom visible dans la liste d'actions) |
| `AutoEdit_GUI.lua` | fenêtre ReaImGui, déroulement analyse / application |
| `AutoEdit_core.lua` | logique pure : grille, choix de subdivision, propositions, plan de coupe (testable hors Reaper) |
| `AutoEdit_reaper.lua` | lecture / modification du projet : export, moteur, application, sauvegardes, retour |
| `AutoEdit_theme.lua` | thème « gris perle » (repris de MixLike) |
| `ae_detect.py` | détection des attaques (flux spectral + enveloppe causale) |
| `ae_engine.py` | moteur lancé par Reaper : WAV exportés -> `result.lua` |
| `tests/` | banc d'essai synthétique, test de recollage sur vraies DI, sonde d'API et test de bout en bout dans Reaper |

Les fichiers de travail vont dans `<dossier du projet>\AutoEdit\` (WAV exportés, `job.json`, `result.lua`,
`engine.log`).

## Tests

```bash
py -3 tests/bench_detect.py
```

```bash
py -3 tests/test_reaper_e2e.py --capture
```

```bash
py -3 tests/probe_api_reaper.py
```

`tests/test_splice_real.py` demande `lupa` (venv de développement : `py -3 -m venv out/venv` puis
`out/venv/Scripts/python.exe -m pip install numpy scipy soundfile lupa matplotlib`). Les tests Reaper lancent une
**instance séparée** (`-newinst`) sur un projet temporaire dans `out/` ; le projet ouvert n'est pas touché.

## État (15/11/2026)

Testé :
- banc synthétique (guitare : rappel 99-100 %, attaques sûres 83-100 %, précision p95 0,1-0,3 ms ; basse : voir limites) ;
- recollage sur 5 vraies DI du projet de test : décalages retrouvés à p95 ≤ 0,24 ms, aucun raccord ne révèle une attaque ;
- bout en bout dans Reaper 7 (instance séparée) : analyse, application, réanalyse (attaques calées à 0,01 ms de la
  ligne en médiane), retour à l'état d'avant (items identiques), capture de la fenêtre.

À valider chez vous : l'écoute des raccords, le confort de la fenêtre sur de longues listes, le choix des
subdivisions sur vos morceaux, la basse.

Limites connues :
- **Basse** : quand la note précédente sonne encore et que la nouvelle n'est pas plus forte (jeu lié, aux doigts),
  l'attaque est « douteuse » (datée à ±5 ms environ) et n'est pas déplacée par défaut. Sur la DI « bass Sat » du
  projet de test, 30 % des attaques sont sûres.
- Une attaque redétectée à moins de 3 ms d'un raccord existant (calage précédent) est ignorée.
