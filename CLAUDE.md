# AutoEdit : directives du projet

Répondre en **français**, de façon concise. Avant de modifier le code, charger la skill **`autoedit-dev`**
(`.claude/skills/autoedit-dev/SKILL.md` : architecture, règles, tests).

| Document | Contenu |
|---|---|
| `LISEZMOI.md` | présentation, installation, tests, état |
| `docs/UTILISATION.md` | guide utilisateur |
| `docs/ALGORITHME.md` | détection, grille, plan de coupe, application, mesures du banc |

## Objectif
Script Reaper (Lua + ReaImGui 0.10.0.5, moteur Python numpy/scipy/soundfile lancé en arrière-plan) qui cale les
attaques de guitares / basses enregistrées en DI au clic (Focusrite Scarlett 6i6, ampli Neural DSP en effet de
piste) sur la **grille de tempo du projet** (pas sur le MIDI de batterie). Remplace la coupe + micro-recalage à la main.

## Décisions de l'utilisateur
- Audio lu par **take accessor** (avant effets), export WAV mono float32 22050 Hz par tranches.
- Subdivisions : toutes possibles (temps, croches, triolets de croche, doubles, triolets de double) ; « jusqu'à la
  double croche, c'est déjà assez fin ». Plage de travail habituelle : **un riff (5-30 s)**.
- Notes hors grille intactes, attaques douteuses signalées ; doublures G/D : force plus basse proposée.
- Pistes à vitesse modifiée ou marqueurs d'étirement ignorées avec message. Pas de paires DI + ampli.
- Retour arrière : bloc d'annulation, pistes muettes de copie (chunks sans GUID), copie datée du .rpp, bouton
  « Revenir à l'état d'avant ».
- Git : branche **`dev`**, commits en français ; fusion dans `main` et push **seulement sur demande**. `gh` absent.

## Environnement
- Windows 11, Reaper 7 (`C:\Program Files\REAPER (x64)\reaper.exe`), ReaImGui 0.10.0.5.
- Python : `%LOCALAPPDATA%\Programs\Python\Python312\python.exe` (`py -3`) ; le `python` du PATH est celui
  d'Inkscape (sans pip). Venv de développement `out/venv` (lupa, matplotlib) ; `out/` ignoré par git.
- Projet de test (lecture seule) : `F:\reaper\death\deathV0.0_tests.RPP` (200 BPM après 15 s). DI utilisées :
  `15-guitar_left-260814_1725.wav`, `04-guitar_right2-…`, `05-guitar_right3-…`, `23-bass Sat-260814_1739.wav`,
  `24-bass Sat-260814_1820-glued-01.wav`. Le jeu s'écarte de ±25 ms de la grille : pas de vérité terrain absolue.

## État (15/11/2026)
- Détection validée sur banc synthétique et par recollage sur vraies DI ; test de bout en bout dans un vrai Reaper
  (analyse, application, réanalyse à 0,01 ms, retour identique, capture de la fenêtre) : voir LISEZMOI.
- **Pas encore testé par l'utilisateur** dans son projet : écoute des raccords, ergonomie, basse.
- Limite connue : basse jouée liée / aux doigts -> beaucoup d'attaques douteuses (≈ 30 % de sûres sur « bass Sat »).
