# AutoEdit : algorithmes, seuils et mesures

## 1. Export (AutoEdit_reaper.lua)

- Audio lu par `CreateTakeAudioAccessor` sur le take actif : **avant les effets de piste** (Neural DSP ignoré).
  Vérifié dans Reaper 7 (`tests/probe_api_reaper.py`) : les temps de l'accessor sont **locaux à l'item**
  (0 = début de l'item, décalage de départ déjà compris), longueur = longueur de l'item.
- Une piste = un WAV mono float32 22050 Hz couvrant la sélection plus 1 s avant et 0,5 s après (contexte, attaques
  d'ancrage). Les items de la plage sont additionnés avec leurs fondus (linéaires) ; stéréo -> moyenne.
- Lecture par blocs de 0,5 s, 25 ms de calcul par passage de la boucle `defer` : Reaper reste fluide.
- Pistes refusées (message) : vitesse de lecture ≠ 1, marqueurs d'étirement, MIDI, item verrouillé.

## 2. Détection (ae_detect.py)

Ce qui a été essayé et écarté (mesures sur le banc et sur les vraies DI) :
- Enveloppe de Hilbert + lissage symétrique + maximum de pente en dB : **2 à 10 ms d'avance**. Le filtrage à phase
  nulle et le lissage symétrique étalent l'énergie avant l'attaque, et en dB cette queue porte la pente maximale.
- Bande 800-8000 Hz sur une vraie DI : la DI est une suite d'impulsions (une par période, ~10 ms), l'enveloppe
  y varie de ±10 dB à chaque période -> nombreux faux pics.
- Critère d'amplitude seul (« pic qui bat le maximum des 30 ms précédentes ») : rate les notes **plus faibles** que
  la précédente (changement de note sans attaque plus forte).
- Résidu de peigne (`x[n] - x[n-T]`, pour effacer la note qui sonne) : 16-28 % d'erreurs, période faussée par la
  note d'avant.

Méthode retenue, en deux étapes :

**Trouver les notes** : flux spectral « SuperFlux ». STFT (guitare 1024 points, basse 2048 ; pas de 64 échantillons
= 2,9 ms), log(1 + 100 |X|), différence positive avec la trame 3 (guitare) ou 4 (basse) pas avant, maximum sur 3
canaux voisins pour la trame de référence (ignore vibrato et battements). Pics au-dessus de 0,10 (normalisé au
99e centile) et de 0,8 x la moyenne locale (120-150 ms). Regroupement : pics à moins de 35 ms (guitare) / 45 ms
(basse) d'un pic plus fort écartés (ambiguïté signalée si un rival a ≥ 70 % de sa force à plus de 12 ms).

**Dater chaque note** : enveloppe **causale** (passe-bande causal d'ordre 2, moyenne glissante causale de x² sur
0,5-1 ms) : aucune pré-réponse, donc jamais en avance. Deux bandes : large (guitare 300-9000 Hz, basse 60-3000 Hz)
et aiguë (guitare 2000-9000, basse 500-4000 : le médiator). Dans [pic de flux − 12 ms, + 30 ms] (basse −15/+40),
marche la plus nette :

    J(k) = max(env[k, k + 1,5 ms]) − max(env[k − pré, k])     pré = 14 ms guitare, 28 ms basse (≥ une période)

c.-à-d. la première impulsion qui dépasse franchement la note d'avant. Instant = franchissement de
pré + 0,5 J, interpolé. Bande la plus nette ; à 3 dB près, la plus précoce.

**Sûre ou douteuse** : marche ≥ 6 dB (guitare) / 8 dB (basse) et pas ambiguë -> **sûre**. Mesure sur le banc
(erreur selon la netteté) : à ≥ 6 dB, p95 < 1 ms et ≤ 4 % d'aberrantes ; en dessous, jusqu'à 54 % d'erreurs
> 3 ms. Douteuse : recherche limitée à ±2,5 σ autour du temps du flux corrigé de son avance moyenne
(guitare 4,8 ms, σ 2,0 ; basse 10,7 ms, σ 4,8). Seules les sûres sont déplacées par défaut.

**Début d'attaque** (pour placer la coupe) : creux de l'enveloppe large dans les 10 ms avant l'instant. Pour une
douteuse, le plus tôt plausible (temps du flux − 2,5 σ, et au moins 10 ms avant), pour qu'aucune coupe voisine
n'emporte son attaque.

**Points de coupe candidats** (ae_engine.py) : creux locaux de l'énergie (1 ms) entre l'attaque précédente
+ 5 ms et le début d'attaque − 0,5 ms, ramenés au passage par zéro le plus proche ; les 16 plus tardifs.

### Mesures du banc synthétique (`tests/bench_detect.py`, 3 parties de 16 s par cas)

Générateur (`tests/synth.py`) : cordes de Karplus-Strong pincées (triangle, vu par le micro comme une vitesse
-> impulsions), accords de 2-3 cordes étalés de 0-4 ms, clic de médiator, étouffé ou ouvert, aigus qui
s'éteignent plus vite que la fondamentale, coupure de la note précédente sur la même corde, niveaux −8..0 dB,
bruit −72 dB, ronflette 50 Hz, notes liées sans médiator ; tempo 110-210, croches / doubles / triolets,
écarts de jeu ±10 ms.

| Cas | Rappel | Fausses | Sûres | Biais (sûres) | p95 (sûres) | > 3 ms (sûres) |
|---|---|---|---|---|---|---|
| guitare étouffée | 100 % | 0 % | 100 % | +0,01 ms | 0,09 ms | 0 % |
| guitare ouverte | 100 % | 1,5 % | 83 % | +0,20 | 0,32 | 0,3 % |
| guitare mixte | 99,5 % | 0 % | 93 % | +0,07 | 0,25 | 0,3 % |
| guitare rapide | 99,1 % | 0,2 % | 92 % | +0,09 | 0,28 | 0 % |
| basse étouffée | 99,4 % | 0 % | 68 % | +0,13 | 0,19 | 0 % |
| basse ouverte | 99,4 % | 3,6 % | 10 % | +0,15 | 0,22 | 0 % |
| basse mixte | 100 % | 0,3 % | 40 % | +0,14 | 0,19 | 0 % |
| basse rapide | 99,5 % | 0 % | 27 % | +0,17 | 0,21 | 0 % |

### Vraies DI (`tests/test_splice_real.py`, projet de test, lecture seule)

Pas de vérité terrain absolue (le jeu s'écarte de ±25 ms de la grille). Test de **recollage** : chaque attaque sûre
est déplacée de ±8 ms au hasard par le vrai plan de coupe (AutoEdit_core.lua via lupa), le signal est reconstruit
comme Reaper le joue, puis redétecté.

| DI | Attaques | Sûres | Biais | p95 | Raccords révélant une attaque |
|---|---|---|---|---|---|
| guitar_left | 70 | 49 | −0,01 ms | 0,10 ms | 0 |
| guitar_right2 | 130 | 85 | −0,17 | 0,10 | 0 |
| guitar_right3 | 62 | 53 | 0,00 | 0,06 | 0 |
| bass Sat (23) | 38 | 12 | 0,00 | 0,02 | 0 |
| bass Sat (24) | 32 | 11 | +0,04 | 0,24 | 0 |

À la redétection, 0 à 10 % d'attaques changent (douteuses redatées, regroupements différents) et quelques-unes
apparaissent à moins de 3 ms d'un raccord : le saut de phase du fondu, 10-17 ms avant l'attaque. Elles sont
ignorées à une nouvelle analyse (statut « raccord »).

## 3. Grille et choix de la subdivision (AutoEdit_core.lua)

- `TimeMap_GetMeasureInfo(0, m)` renvoie `temps_début, qn_début, qn_fin, num, dénom, tempo` (vérifié dans
  Reaper 7, 4/4 puis 6/8). Lignes en noires (QN) converties par `TimeMap2_QNToTime`.
- Temps : x/4 -> noire ; 6/8, 9/8, 12/8 -> noire pointée (1,5 QN) ; autres x/8 -> croche ; x/2 -> blanche.
  Croches 1/2 QN, triolets de croche 1/3, doubles 1/4, triolets de double 1/6. La barre suivante est une ligne.
- Fenêtre d'une subdivision : min(35 % de l'écart entre lignes, écart max 30 ms).
- Choix par mesure : la plus grossière active où ≥ 75 % des attaques sûres sont dans la fenêtre **et** au moins
  20 points de plus que le hasard (part attendue au hasard = 2 x fenêtre / écart ; avec 35 %, une grille fine
  attrape 70 % de notes jouées n'importe où). Sinon la mesure est **irrégulière** : rien n'y est déplacé tant
  que l'utilisateur ne force pas sa subdivision. Le choix forcé vaut pour toutes les pistes.

## 4. Propositions

Pour chaque attaque de la sélection : ligne la plus proche de la subdivision de sa mesure, écart = t − ligne.
Cible = ligne + décalage voulu de la piste. Déplacement = −(écart − décalage voulu) x force. États : hors grille
(écart > fenêtre), douteuse (non déplacée sauf option), déjà calée (< 0,3 ms), décochée, sur un raccord, mesure
irrégulière. Doublures gauche/droite (nom left/right/gauche/droite/L/R ou panoramique ≥ 30 %, au moins une de
chaque côté) : force proposée 70 %.

## 5. Plan de coupe (anti-doublement)

Pour chaque item, segments de déplacement constant ; une coupe c avant l'attaque i dès que son déplacement d_i
diffère de celui du segment courant (D = d_i − d_{i−1}). Le segment précédent est étendu ou rogné pour finir à
c + d_i + fondu : il lit la source jusqu'à c + D + fondu, ce qui révèle la source suivante (vérifié dans Reaper).
Contraintes :

    c ≤ début_attaque_i − marge (1 ms) − fondu (3 ms) − max(D, 0)      (ni le segment révélé ni le fondu ne contiennent l'attaque)
    c ≥ t_{i−1} + 15 ms + max(−D, 0) − fondu                             (le segment précédent garde son attaque, même rogné)
    c ≥ coupe précédente + 2 x fondu

Point choisi : le creux d'énergie candidat le plus tardif dans l'intervalle, sinon la borne haute. Intervalle vide :
la note est **bloquée** (elle suit le segment précédent, signalée). Les attaques hors sélection (ancrages, d = 0)
et non déplacées comptent aussi : le retour à d = 0 se fait par une coupe avant elles, sous les mêmes contraintes.
La fin de l'item reste à sa place.

## 6. Application et retour (AutoEdit_reaper.lua)

- Bloc d'annulation « AutoEdit : calage sur la grille », `PreventUIRefresh`.
- Coupes de droite à gauche (`SplitMediaItem`), puis géométrie imposée explicitement à chaque segment (position,
  longueur, `D_STARTOFFS` de chaque take, fondus) : indépendant des préférences de coupe/fondu de Reaper.
  Raccords : fondus linéaires (`C_FADEINSHAPE` 0, les deux côtés jouent la même note décalée de quelques ms),
  `D_FADEINLEN_AUTO` / `D_FADEOUTLEN_AUTO` à −1 ; fondus extérieurs d'origine conservés.
- Avant la 1re application de la session : copie du .rpp `<nom>_avant-AutoEdit_AAAAMMJJ-HHMMSS.rpp` à côté du
  projet (proposition d'enregistrer si le projet est modifié) ; piste muette « AutoEdit original : nom » insérée
  au-dessus de la piste (même dossier), items copiés par chunk sans lignes `IGUID`/`GUID` (vérifié : Reaper
  attribue de nouveaux GUID).
- Refus d'appliquer si les items ont changé depuis l'analyse (empreinte position/longueur/décalage).
- « Revenir à l'état d'avant » : supprime les segments créés (par GUID) et recrée les items d'origine depuis leurs
  chunks, pour toutes les applications de la session, dans un bloc d'annulation.
