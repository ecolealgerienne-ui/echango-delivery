# Revue croisée du 28/07/2026 — backend BFF + app Flutter

Trois agents lancés en parallèle (orchestration Fable, revues en lecture seule),
chacun avec un angle et un modèle choisis pour la tâche :

| Fichier | Angle | Modèle | Pourquoi ce modèle |
|---|---|---|---|
| `01_architecture.md` | Structure, dette, performance | Opus | Analyse transversale, arbitrages |
| `02_securite.md` | Isolation, auth, injection | Opus | Raisonnement adversarial |
| `03_metier.md` | Parcours réels, règles produit | Sonnet | Confrontation code/specs cadrée |

`00_synthese.md` est la synthèse croisée : constats convergents, corrections
d'affirmations antérieures de la session, et liste priorisée unique (P0 avant
VPS / P1 avant pilote / P2 ensuite).

Chaque agent avait reçu la liste des choix documentés comme VOULUS (anti-IDOR
côté BFF, public_id vs uuid, contournement du bug amont preuve photo…) pour ne
pas les signaler comme des défauts.
