# AutoEdit : guide d'utilisation

## Avant de commencer

- Les guitares et basses sont en **DI** sur leur piste, l'ampli (Neural DSP) en effet de piste : AutoEdit lit
  l'audio avant les effets. La carte de tempo du projet doit correspondre au clic de l'enregistrement.
- Une piste avec un item à vitesse modifiée, des marqueurs d'étirement, du MIDI ou un item verrouillé dans la plage
  est ignorée (le message dit lequel et où).

## Déroulement

1. **Sélection** : les pistes à caler (plusieurs à la fois : guitares, doublures, basse) et une sélection de
   temps sur le passage (5-30 s conseillé).
2. **Analyser les pistes sélectionnées** : lecture de l'audio (barre de progression), puis détection en Python
   (quelques secondes). Rien n'est modifié.
3. **Lire les résultats** :
   - *Pistes* : type (Guitare / Basse, deviné d'après le nom ; le changer demande une nouvelle analyse), force,
     décalage voulu (+ = en arrière : une basse un peu derrière, par exemple +2 ms), résumé des attaques.
     Les doublures gauche/droite sont repérées (pastille violette) : force proposée 70 % pour garder l'effet de double.
   - *Graphique* : écart de chaque attaque à sa ligne (point) et déplacement proposé (trait). Survol : détail ;
     clic : curseur d'édition sur l'attaque.
   - *Tableau* : case (décocher pour laisser une attaque telle quelle), position mesure.temps.centièmes,
     subdivision, écart actuel, décalage proposé, état.
   - *Mesures* : subdivision choisie automatiquement par mesure, avec la part d'attaques dans la fenêtre ;
     « Forcer » impose une subdivision (pour toutes les pistes). Une mesure **irrégulière** (aucune subdivision
     ne l'explique nettement mieux que le hasard) n'est pas touchée tant que vous ne forcez pas sa subdivision.
4. **Appliquer**. La première fois dans la session : copie datée du .rpp (enregistrement proposé si le projet est
   modifié) et piste muette « AutoEdit original : … » au-dessus de chaque piste traitée.
5. **Écouter**, puis au besoin : Ctrl+Z (une application), **Revenir à l'état d'avant** (toutes celles de la
   session), ou relancer l'analyse pour vérifier / affiner (les attaques calées apparaissent « déjà calées »).

## États des attaques

| État | Signification |
|---|---|
| à déplacer | sera calée sur la ligne (+ décalage voulu), à la force choisie |
| déjà calée | écart < 0,3 ms |
| hors grille | écart > fenêtre (syncope, swing, note volontairement décalée) : intacte |
| mesure irrégulière | la mesure ne suit aucune subdivision de façon nette : intacte sauf subdivision forcée |
| douteuse | attaque peu nette (note d'avant qui sonne encore, note liée) : position à ±2-5 ms, non déplacée sauf « Déplacer aussi les attaques douteuses » |
| bloquée | trop proche de la note précédente pour couper sans doubler une attaque : suit le segment précédent |
| raccord | artefact d'un raccord d'un calage précédent : ignorée |
| décochée | laissée telle quelle à votre demande |

## Réglages

| Réglage | Défaut | Effet |
|---|---|---|
| Force | 100 % | part de l'écart corrigée |
| Écart max | 30 ms | au-delà, la note est hors grille |
| Fenêtre | 35 % | fenêtre d'appariement en part de l'écart entre lignes (le plus petit des deux limite) |
| Fondu | 3 ms | fondu enchaîné aux raccords |
| Subdivisions possibles | toutes | décocher celles que le morceau n'utilise pas rend le choix automatique plus sûr |

Les réglages sont mémorisés (ExtState « AutoEdit »). Fichiers de travail : `<projet>\AutoEdit\`. En cas d'erreur
Python, le message s'affiche dans la fenêtre ; journal : `<projet>\AutoEdit\engine.log`.
