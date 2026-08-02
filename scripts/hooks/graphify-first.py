#!/usr/bin/env python3
"""Redirige vers Graphify les recherches de STRUCTURE dans `backend/bff/`.

── Pourquoi un hook et pas une règle écrite ────────────────────────────────

La règle 11 de `CLAUDE.md` dit d'interroger le graphe avant le `grep` pour les
questions de structure. Elle avait la faiblesse que la doctrine du dépôt
dénonce partout ailleurs : **elle ne peut pas échouer**. Les dix autres règles
sont tenues par des vérificateurs qui refusent (`check_error_codes`,
`check_buttons`, `check_inputs`, `check_spacing`, `check_server_rules`) ;
celle-ci ne s'adressait qu'au jugement — et le jugement a dérapé le jour même
où la règle a été écrite.

Ce hook est son vérificateur.

── Ce qu'il refuse, et surtout ce qu'il laisse passer ─────────────────────

Un hook trop large devient une gêne quotidienne, et une gêne quotidienne se
désactive. Il ne refuse donc QUE le cas où le graphe est certainement meilleur :

  * un motif qui ressemble à un **identifiant nu** (`canTakeCashOrder`) ;
  * dans **`backend/bff/`**, où l'extraction est faite par tree-sitter.

Tout le reste passe sans un mot :

  * un motif avec des métacaractères — c'est une recherche textuelle ;
  * `echango_delivery/` — l'extraction Dart est par regex, et le graphe y rend
    des chemins **plausibles et faux** (mesuré : 64 nœuds fantômes) ;
  * les chaînes, les noms de colonnes, les clés JSON — ils ne sont pas des
    nœuds du graphe, et le graphe n'a rien à en dire ;
  * un identifiant court (< 4 caractères), trop ambigu pour valoir un refus.

⚠️ **Échappatoire au second essai.** Un refus définitif rendrait le travail
impossible le jour où le graphe ne sait pas répondre — un symbole absent, un
graphe périmé, un nom qui n'est pas une fonction. Le même motif relancé une
seconde fois passe donc. Le hook installe une habitude ; il ne prend pas le
contrôle.
"""

import json
import os
import re
import sys
import tempfile

ALLOW = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}


def allow() -> None:
    # Silencieux : un hook qui parle à chaque appel finit par ne plus être lu.
    print(json.dumps(ALLOW))
    sys.exit(0)


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        # ⚠️ Une charge illisible LAISSE PASSER. Un hook qui bloque parce qu'il
        # n'a pas compris son entrée casse l'outil qu'il devait améliorer, et le
        # défaut serait attribué au Grep.
        allow()

    if payload.get("tool_name") != "Grep":
        allow()

    tool_input = payload.get("tool_input") or {}
    pattern = (tool_input.get("pattern") or "").strip()
    path = (tool_input.get("path") or "").replace("\\", "/")

    # Un identifiant NU : lettres, chiffres, underscore, et rien d'autre. Dès
    # qu'un métacaractère apparaît, c'est une recherche textuelle — le graphe
    # n'a pas de réponse à ça.
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{3,}", pattern):
        allow()

    # Hors de `backend/bff/`, on ne dit rien. Un chemin vide veut dire « tout le
    # dépôt » : la moitié Dart est concernée, donc on laisse passer plutôt que
    # de rediriger vers un graphe qui répondrait faux.
    if "backend/bff" not in path.lower():
        allow()

    # Échappatoire : le même motif, une seconde fois, passe.
    #
    # La clé inclut la session pour que l'habitude se réinstalle à chaque
    # nouvelle conversation — sans quoi un motif redemandé des semaines plus
    # tard passerait sans rappel.
    session = str(payload.get("session_id") or "sans-session")
    seen_path = os.path.join(
        tempfile.gettempdir(), f"graphify-first-{re.sub(r'[^A-Za-z0-9]', '', session)[:32]}.txt"
    )
    try:
        with open(seen_path, "r", encoding="utf-8") as handle:
            already = set(handle.read().split())
    except OSError:
        already = set()

    if pattern in already:
        allow()

    try:
        with open(seen_path, "a", encoding="utf-8") as handle:
            handle.write(pattern + "\n")
    except OSError:
        # Si le marqueur ne peut pas s'écrire, on ne refuse pas : sans lui
        # l'échappatoire ne fonctionnerait plus, et le refus deviendrait
        # définitif — exactement ce que ce hook ne doit jamais être.
        allow()

    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": (
                        f"Règle 11 — « {pattern} » ressemble à un identifiant, et la question "
                        "porte sur backend/bff/ (TypeScript, extraction tree-sitter).\n"
                        f"  python -m graphify explain \"{pattern}\"\n"
                        "Le graphe rend les appelants AVEC leur fonction englobante, le sens des "
                        "arêtes et les appels en aval — le grep ne rend que fichier:ligne.\n"
                        "Si le graphe ne répond pas (symbole absent, graphe périmé), relancer le "
                        "MÊME Grep : le second essai passe."
                    ),
                }
            }
        )
    )
    sys.exit(0)


if __name__ == "__main__":
    main()
