#!/usr/bin/env bash
#
# Banc d'essai des bibliothèques de scripts, hors ligne.
#
# ── Pourquoi il existe ─────────────────────────────────────────────────────
#
# Ces bibliothèques ne contiennent plus seulement des appels : elles portent du
# **diagnostic** — quel conducteur choisir, pourquoi une invitation est refusée,
# lequel des deux gardes a mordu. Ce sont des branches, et une branche qu'on n'a
# jamais vue s'exécuter n'est pas vérifiée : elle est espérée.
#
# Or aucune ne se déclenche sur le chemin nominal. Le seul moyen de les voir est
# de **fabriquer les réponses** qui les provoquent, ce que fait ce banc en
# remplaçant `fb_get` par un talon. Règle 8 du projet : un contrôle doit prouver
# qu'il sait refuser, et il le prouve avec autant de cas qui échouent que de cas
# qui passent.
#
# ⚠️ Ce banc ne parle à AUCUN serveur, et c'est le but : il éprouve la logique
# de message, pas la disponibilité de Fleetbase. Ce que la chaîne réelle fait
# reste du ressort de `test-parcours-argent-flotte.sh`.
#
#   ./scripts/lib/self-test.sh              # les cas
#   ./scripts/lib/self-test.sh --mutations  # et la preuve qu'ils savent refuser
#
# `MUTATE=<sed>` applique une transformation aux bibliothèques avant de les
# charger, sur une copie — le dépôt n'est jamais écrit. `--mutations` rejoue
# celles de la liste `MUTATIONS` (fin du fichier) et vérifie que chacune fait
# tomber **le nombre de cas attendu**.

set -uo pipefail

SELF_NAME="$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "${BASH_SOURCE[0]}")"

OK=0
KO=0

check() { # libellé attendu obtenu
  if [[ "$3" == *"$2"* ]]; then
    OK=$((OK + 1))
    echo "  ✅ $1"
  else
    KO=$((KO + 1))
    echo "  ❌ $1"
    echo "     attendu (fragment) : $2"
    echo "     obtenu             : $3"
  fi
}

refuse() { # libellé interdit obtenu — la moitié qui compte
  if [[ "$3" != *"$2"* ]]; then
    OK=$((OK + 1))
    echo "  ✅ $1"
  else
    KO=$((KO + 1))
    echo "  ❌ $1"
    echo "     ne devait PAS contenir : $2"
    echo "     obtenu                 : $3"
  fi
}

# ── Les bibliothèques, éventuellement mutées ───────────────────────────────
#
# Chargées depuis une copie pour que `MUTATE` n'écrive jamais dans le dépôt.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp fleetbase.sh resolve-driver.sh driver-session.sh ledger.sh "$WORK/"
if [ -n "${MUTATE:-}" ]; then
  sed -i "$MUTATE" "$WORK"/*.sh
  echo "⚠️  mutation appliquée : $MUTATE"
fi

BFF_URL="http://127.0.0.1:1"   # jamais appelé : aucun cas ne sort du talon
PASSWORD="x"
# shellcheck disable=SC1090
. "$WORK/fleetbase.sh"
# shellcheck disable=SC1090
. "$WORK/resolve-driver.sh"
# shellcheck disable=SC1090
. "$WORK/driver-session.sh"
# shellcheck disable=SC1090
. "$WORK/ledger.sh"

# ── Le talon ───────────────────────────────────────────────────────────────
#
# Remplace `fb_get` après le chargement : les fonctions appelantes le résolvent
# à l'exécution, donc le talon gagne. `FB_RESPONSE` vide = échec réseau, ce qui
# est un cas à part entière — c'est celui où le script ne doit rien affirmer.
FB_RESPONSE=""
fb_get() {
  if [ -z "$FB_RESPONSE" ]; then
    FLEETBASE_ERROR="réseau indisponible (talon)"
    return 1
  fi
  printf '%s' "$FB_RESPONSE"
}

ALICE='{"uuid":"u-alice","public_id":"driver_alice","name":"Alice","email":"alice@t.dz","vendor_uuid":"v-transport"}'
BOB='{"uuid":"u-bob","public_id":"driver_bob","name":"Bob","email":"bob@t.dz","vendor_uuid":null}'
CARLA='{"uuid":"u-carla","public_id":"driver_carla","name":"Carla","phone":"+213555000001"}'
# Rattaché comme Alice, mais déjà inscrit : utilisable sans invitation.
DIA='{"uuid":"u-dia","public_id":"driver_dia","name":"Dia","email":"dia@t.dz","vendor_uuid":"v-autre"}'

# Talon de la base du BFF : aucun `docker` n'est appelé.
ACCOUNTS=""
_accounted_driver_uuids() { printf '%s' "$ACCOUNTS"; }

echo
echo "── fb_drivers : deux enveloppes acceptées, le reste refusé ──"

FB_RESPONSE="{\"drivers\":[$BOB]}"
out="$(fb_drivers)"; check "enveloppe « drivers »" 'driver_bob' "$out"

FB_RESPONSE="{\"data\":[$BOB]}"
out="$(fb_drivers)"; check "enveloppe « data »" 'driver_bob' "$out"

FB_RESPONSE='{"resultat":[]}'
if fb_drivers >/dev/null 2>&1; then
  KO=$((KO + 1)); echo "  ❌ une enveloppe inconnue doit ÉCHOUER, pas rendre une liste vide"
else
  OK=$((OK + 1)); echo "  ✅ enveloppe inconnue refusée (« $FLEETBASE_ERROR »)"
fi

FB_RESPONSE='{"drivers":[]}'
out="$(fb_drivers)"; check "liste vide légitime acceptée" '[]' "$out"

echo
echo "── _rd_list : le rattachement est dit, il ne se devine pas ──"

listing="$(_rd_list "[$ALICE,$BOB]" 2>&1)"
check "un conducteur rattaché est marqué"  '[rattaché]' "$listing"
check "un conducteur du pool est marqué"   '[pool]'     "$listing"
check "l'absence de vendor_uuid vaut pool" 'Carla'      "$(_rd_list "[$CARLA]" 2>&1)"
check "clé absente = pool, pas rattaché"   '[pool]'     "$(_rd_list "[$CARLA]" 2>&1)"

echo
echo "── resolve_driver : choisit seul quand c'est sans ambiguïté ──"

FB_RESPONSE="{\"drivers\":[$BOB]}"
resolve_driver "" && check "un seul conducteur, pris sans indice" 'u-bob' "$DRIVER_UUID"

FB_RESPONSE="{\"drivers\":[$ALICE,$BOB]}"
if resolve_driver "" 2>/dev/null; then
  KO=$((KO + 1)); echo "  ❌ deux conducteurs sans indice : il ne doit PAS choisir"
else
  OK=$((OK + 1)); echo "  ✅ deux conducteurs sans indice : refus motivé"
fi
resolve_driver "alice" && check "résolution par fragment de nom" 'u-alice' "$DRIVER_UUID"
resolve_driver "bob@t.dz" && check "résolution par email" 'u-bob' "$DRIVER_UUID"
resolve_driver "driver_alice" && check "résolution par ID public" 'u-alice' "$DRIVER_UUID"
if resolve_driver "zoé" 2>/dev/null; then
  KO=$((KO + 1)); echo "  ❌ un nom inconnu doit être refusé"
else
  OK=$((OK + 1)); echo "  ✅ nom inconnu refusé (« $RESOLVE_DRIVER_ERROR »)"
fi

# ⚠️ Le cas qui a trouvé un défaut réel, et pré-existant. La lecture posait
# `RESOLVE_DRIVER_ERROR` **dans une substitution de commande** : la variable
# mourait avec le sous-shell, l'appelant retombait sur son repli, et une panne
# réseau s'annonçait « Conducteur introuvable » — envoyant chercher un
# conducteur qui existe. Le message doit venir du parent.
FB_RESPONSE=""
if resolve_driver "" 2>/dev/null; then
  KO=$((KO + 1)); echo "  ❌ lecture impossible : il ne doit rien rendre"
else
  check  "l'échec de lecture est nommé"      'lecture des conducteurs impossible' "$RESOLVE_DRIVER_ERROR"
  refuse "et n'accuse pas le conducteur"     'introuvable'                        "$RESOLVE_DRIVER_ERROR"
fi

echo
echo "── _invitation_refusal_reason : dire quoi faire, pas relayer un 403 ──"

NOT_IN_FLEET='{"statusCode":403,"code":"auth.driver_not_in_fleet","message":"Ce transporteur n'"'"'appartient pas à votre entreprise."}'

FB_RESPONSE="{\"drivers\":[$ALICE,$BOB]}"
msg="$(_invitation_refusal_reason u-alice "$NOT_IN_FLEET")"
check  "nomme le fournisseur qui bloque"      'v-transport'  "$msg"
check  "propose un conducteur du pool"        'driver_bob'   "$msg"
refuse "ne propose PAS un conducteur rattaché" 'driver_alice' "$msg"

FB_RESPONSE="{\"drivers\":[$ALICE]}"
msg="$(_invitation_refusal_reason u-alice "$NOT_IN_FLEET")"
check "aucun conducteur utilisable : le dit" "Aucun autre conducteur n'est utilisable" "$msg"

# ⚠️ Un conducteur RATTACHÉ mais déjà inscrit convient : l'invitation ne le
# concerne pas. Ne lister que le pool écarterait les seuls conducteurs
# disponibles sur une base où les scripts précédents ont déjà tourné.
FB_RESPONSE="{\"drivers\":[$ALICE,$DIA]}"
ACCOUNTS="u-dia"
msg="$(_invitation_refusal_reason u-alice "$NOT_IN_FLEET")"
check  "un rattaché DÉJÀ INSCRIT est proposé"   'driver_dia'        "$msg"
check  "et présenté comme tel"                  '[compte existant]' "$msg"
refuse "le rattaché sans compte reste exclu"    'driver_alice'      "$msg"

FB_RESPONSE="{\"drivers\":[$ALICE,$BOB,$DIA]}"
msg="$(_invitation_refusal_reason u-alice "$NOT_IN_FLEET")"
check "les deux voies sont distinguées" '[pool — compte à créer]' "$msg"

# Sans compte enregistré, un rattaché redevient inutilisable — c'est le
# marqueur qui doit décider, pas la simple présence dans la liste.
ACCOUNTS=""
msg="$(_invitation_refusal_reason u-alice "$NOT_IN_FLEET")"
refuse "sans compte, le rattaché n'est plus proposé" 'driver_dia' "$msg"
check  "et le conducteur du pool reste proposé"      'driver_bob' "$msg"

# Le conducteur est en règle : c'est l'autre moitié du garde qui a mordu, et
# envoyer chercher du côté du conducteur ferait perdre le temps qui compte.
FB_RESPONSE="{\"drivers\":[$ALICE,$BOB]}"
msg="$(_invitation_refusal_reason u-bob "$NOT_IN_FLEET")"
check  "conducteur du pool refusé ⇒ pointe le compte opérateur" 'isPlatform' "$msg"
refuse "et ne parle pas de rattachement"                        'rattaché'   "$msg"

# Un autre code n'est pas ce refus-là : le relayer tel quel vaut mieux que de
# l'interpréter à tort.
other='{"statusCode":404,"code":"auth.driver_not_found","message":"Driver not found"}'
msg="$(_invitation_refusal_reason u-alice "$other")"
check  "un autre code est relayé tel quel" 'auth.driver_not_found' "$msg"
refuse "sans diagnostic inventé"           'pool'                  "$msg"

# Liste illisible : ne rien affirmer. Un message qui conclurait « aucun
# conducteur du pool » sur une panne réseau enverrait en créer un pour rien.
FB_RESPONSE=""
msg="$(_invitation_refusal_reason u-alice "$NOT_IN_FLEET")"
check  "liste illisible : le dit"          'illisible'                "$msg"
refuse "et n'affirme rien sur le pool"     'Aucun conducteur du pool' "$msg"

echo
echo "── ledger : une dette absente n'est pas une dette nulle ──"

# ⚠️ **Le cas constaté en réel le 01/08/2026**, et celui qui justifie tout ce
# fichier : une dette soldée disparaît de `balances` (`filter(b => b.debt !== 0)`),
# donc `first(…)` ne rend RIEN — pas « aucune », rien. La version précédente
# s'appuyait sur `// "aucune"`, qui ne s'applique jamais à un flux vide, et le
# contrôle passait grâce à `printf '%.0f' ""` = 0. Le seul signe visible était un
# montant manquant DANS un message de succès : « à jour ( DZD) ».
SOLDE='{"currency":"DZD","balances":[]}'
check "contrepartie absente ⇒ « aucune », jamais du vide" 'aucune' "$(debt_toward "$SOLDE" c-fleet)"
check "et « aucune » vaut 0 à la comparaison"             '0'      "$(amount_number "$(debt_toward "$SOLDE" c-fleet)")"

DEUX='{"balances":[{"counterparty_id":"c-fleet","counterparty_type":"fleet","debt":1300},
                   {"counterparty_id":"c-autre","counterparty_type":"driver","debt":700}]}'
check "la bonne contrepartie, pas la première venue" '1300' "$(debt_toward "$DEUX" c-fleet)"
check "une dette négative traverse"                  '-500' \
      "$(amount_number "$(debt_toward '{"balances":[{"counterparty_id":"c","debt":-500}]}' c)")"
check "le total somme les soldes"                    '2000' "$(ledger_total "$DEUX")"
check "un registre vide totalise 0"                  '0'    "$(ledger_total "$SOLDE")"

# ⚠️ La moitié qui compte : une réponse qu'on n'a pas su lire ne doit ressembler
# à AUCUN montant. Trois contrôles de ces scripts attendent exactement 0 — ce
# sont ceux qui prouvent qu'une remise a soldé la dette, donc précisément ceux
# qu'une réponse vide rendrait verts.
for bad in '{"statusCode":401,"code":"auth.invalid"}' '' 'pas du json'; do
  got="$(amount_number "$(debt_toward "$bad" c-fleet)")"
  refuse "réponse illisible ≠ 0 (« ${bad:-<vide>} »)" '0' "$got"
  got="$(amount_number "$(ledger_total "$bad")")"
  refuse "total illisible ≠ 0 (« ${bad:-<vide>} »)"   '0' "$got"
done

check "une valeur vide se nomme"          '<vide>' "$(amount_number "")"
check "un texte ressort tel quel"         'absent' "$(amount_number 'absent')"
check "un décimal est arrondi à l'entier" '1300'   "$(amount_number '1300.4')"

echo
if [ "$KO" -eq 0 ]; then
  echo "✅ $OK cas — le banc passe."
else
  echo "❌ $KO échec(s) sur $((OK + KO)) cas."
fi

# ── Mutations : la moitié qui prouve que ce banc sait dire non ─────────────
#
# Un banc vert n'a montré que sa capacité à dire oui. Chacune de ces mutations
# casse une décision réelle du code, et doit faire tomber les cas qui la
# couvrent — le nombre attendu est écrit à côté, et vérifié.
#
# ⚠️ **La liste exécutée EST la liste documentée.** La première version les
# écrivait en commentaire et les rejouait par un `grep` : celui-ci tronquait
# toute mutation contenant un guillemet, la transformait en `sed` sans effet, et
# **affichait « vert »**. Un contrôle incapable de voir qu'il n'a rien muté ne
# contrôle rien — c'est exactement la faute qu'il est censé attraper.
#
#   ./self-test.sh --mutations
MUTATIONS=(
  # Remet la lecture d'origine : sur une dette soldée, `first` d'un flux vide ne
  # rend RIEN, et `printf '%.0f' ""` vaut 0. Défaut constaté en réel, avec
  # « à jour ( DZD) » pour seul signe.
  '2|s/| if length == 0 then "aucune" else (.\[0\].debt | tostring) end/| first(.[]) | .debt/'
  # Une réponse illisible redevient une dette nulle.
  "6|s/echo 'sans-registre'/echo 0/"
  # Une valeur absente redevient 0 — le repli que la règle 10 interdit sur une
  # somme d'argent.
  "1|s/echo '<vide>'/echo 0/"
  # Remet le message d'erreur dans le sous-shell : la panne réseau redevient
  # « Conducteur introuvable ».
  '1|s/RESOLVE_DRIVER_ERROR="lecture des conducteurs impossible[^"]*"/:/'
  # Le filtre d'utilisabilité tombe : des conducteurs qui seront refusés pareil
  # sont proposés, et la branche « aucun autre conducteur » ne sort jamais.
  '4|s/select($v == null or/select(true or/'
  # Seul le pool est proposé : un rattaché DÉJÀ INSCRIT disparaît du message.
  '2|s/or (.uuid as $u | $with | index($u) != null)//'
  # Les deux voies cessent d'être distinguées.
  '1|s/\[compte existant\]/[?]/'
  # Le listing ne dit plus qui est invitable — l'état d'avant ce lot.
  '2|s/\[pool\]/[?]/'
  # Une enveloppe inconnue passe pour une liste vide.
  '1|s/jq -e/jq/'
  # Le fournisseur nommé devient celui du premier conducteur venu.
  '2|s/first(.\[\] | select(.uuid == $u))/first(.[])/'
)

if [ "${1:-}" = "--mutations" ]; then
  echo
  echo "── Mutations : chacune DOIT faire tomber ses cas ──"
  bad=0
  for entry in "${MUTATIONS[@]}"; do
    want="${entry%%|*}"
    mutation="${entry#*|}"
    # ⚠️ Réinvoqué par son nom de fichier, jamais par `$0` : le banc commence
    # par `cd` dans son propre dossier, donc un `$0` relatif — la forme
    # ordinaire, `./scripts/lib/self-test.sh` — ne résout plus. Le symptôme
    # était « aucun » partout, c'est-à-dire dix mutations non attrapées.
    got="$(MUTATE="$mutation" bash "./$SELF_NAME" 2>/dev/null \
           | sed -nE 's/^❌ ([0-9]+) échec.*/\1/p')"
    if [ "$got" = "$want" ]; then
      echo "  ✅ $want échec(s) — ${mutation:0:64}"
    else
      bad=$((bad + 1))
      echo "  ❌ attendu $want échec(s), obtenu « ${got:-aucun} » — $mutation"
    fi
  done
  echo
  [ "$bad" -eq 0 ] && echo "✅ les ${#MUTATIONS[@]} mutations sont toutes attrapées." \
                   || echo "❌ $bad mutation(s) non attrapée(s)."
  exit $([ "$bad" -eq 0 ] && echo 0 || echo 1)
fi

[ "$KO" -eq 0 ]
