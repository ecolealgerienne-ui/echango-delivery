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
#   ./scripts/lib/self-test.sh
#
# `MUTATE=<sed>` applique une transformation aux bibliothèques avant de les
# charger — c'est ainsi qu'on vérifie que le banc sait dire non (voir la fin du
# fichier pour les mutations éprouvées).

set -uo pipefail

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
cp fleetbase.sh resolve-driver.sh driver-session.sh "$WORK/"
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
if [ "$KO" -eq 0 ]; then
  echo "✅ $OK cas — le banc passe."
else
  echo "❌ $KO échec(s) sur $((OK + KO)) cas."
fi

# ── Mutations éprouvées ────────────────────────────────────────────────────
#
# Un banc vert n'a montré que sa capacité à dire oui. Celles-ci le font passer
# au rouge, chacune sur le cas qu'elle casse — c'est ce qui prouve qu'il
# regarde :
#
#   MUTATE='s/RESOLVE_DRIVER_ERROR="lecture des conducteurs impossible[^"]*"/:/'
#                                                                       → 1 échec
#     Remet le message dans le sous-shell, c'est-à-dire le défaut trouvé par ce
#     banc : la panne réseau redevient « Conducteur introuvable ».
#
#   MUTATE='s/select($v == null or/select(true or/'                     → 4 échecs
#     Le filtre d'utilisabilité tombe : le message propose des conducteurs
#     rattachés sans compte, qui seront refusés pareil, et la branche « aucun
#     autre conducteur » ne se déclenche plus jamais.
#
#   MUTATE='s/or (.uuid as $u | $with | index($u) != null)//'           → 2 échecs
#     Seul le pool est proposé : un conducteur rattaché DÉJÀ INSCRIT, souvent le
#     seul disponible en pratique, disparaît du message.
#
#   MUTATE='s/\[compte existant\]/[?]/'                                 → 1 échec
#     Les deux voies cessent d'être distinguées : on ne sait plus si le compte
#     est à créer ou déjà là.
#
#   MUTATE='s/\[pool\]/[?]/'                                            → 2 échecs
#     Le listing cesse de dire qui est invitable — ce qui était l'état d'avant
#     ce lot, et la raison du 403 subi.
#
#   MUTATE='s/jq -e/jq/'                                                → 1 échec
#     Une enveloppe inconnue passe pour une liste vide : « aucun conducteur »
#     au lieu d'« je n'ai pas su lire ».
#
#   MUTATE='s/first(.\[\] | select(.uuid == $u))/first(.[])/'           → 2 échecs
#     Le fournisseur nommé devient celui du premier conducteur venu : un
#     conducteur du pool est alors décrit comme rattaché.

[ "$KO" -eq 0 ]
