#!/usr/bin/env bash
#
# Les fenêtres de PERTE D'ÉCRITURE : N acteurs, une même liste, le MÊME instant.
#
# ── Ce que ce banc mesure, et pourquoi il fallait le mesurer ──────────────────
#
# `docs/status_v1.md` (§ « La concurrence — aucun banc, aucun scénario, rien »)
# NOMME quatre fenêtres de concurrence et n'en a jamais constaté aucune. Le
# chantier du 03/08 a créé les deux premières : la table portait un `@@unique`,
# le champ personnalisé qui l'a remplacée ne l'a plus. Une conséquence
# **documentée** — « la course réapparaît une fois » — n'est pas une conséquence
# **constatée**. Ce banc lance N appels EN PARALLÈLE sur la même ressource, puis
# **compte ce qui a survécu**. C'est la demande exacte du fichier : cheap et
# décisif.
#
# ── Les deux fenêtres éprouvées, et pourquoi PAS les deux autres ──────────────
#
# Ce sont des lire-modifier-écrire à N acteurs DISTINCTS sur une liste partagée,
# donc la perte est propre et démontrable :
#
#   • `declines`        — `OrderCustomFieldsService.appendToOrderList`.
#                         Deux transporteurs refusent la MÊME course diffusée :
#                         chacun lit la liste (0 refus), y ajoute le sien, écrit.
#                         Le second `PUT` écrase le premier → un refus perdu.
#                         `dedupe` ne protège QUE la reprise du même conducteur.
#     route : POST /transporteur/commandes/:id/refuser
#
#   • `favourites`      — `MerchantFavouritesService.add`, même forme sur le
#                         `Vendor` du commerçant : deux ajouts de deux favoris
#                         distincts depuis deux appareils.
#     route : POST /commercant/transporteurs/favoris
#
# Les DEUX AUTRES fenêtres de la liste ne sont PAS des courses N-acteurs propres,
# et le dire évite de fabriquer un banc qui prouve moins qu'il n'en a l'air :
#
#   • `delivery_failures` — UN seul conducteur par course (l'assigné). Une
#     concurrence exigerait le MÊME conducteur signalant deux fois, que `dedupe`
#     rabat. `status_v1` le note « peu probable ». Pas une perte à N acteurs.
#   • clôture d'une course — idempotente depuis le retrait du registre (03/08) :
#     réécrire la même valeur sur la même commande donne le même état. Un double
#     appui ne perd rien. (Éprouvé ailleurs : la course ne se donne qu'une fois,
#     `test-concurrence-acceptation.sh`.)
#
# ── Comment il PROUVE qu'il sait compter (règle 8) ────────────────────────────
#
# Un banc de concurrence qui n'affiche que des nombres ne prouve rien : peut-être
# compte-t-il mal. Chaque fenêtre a donc un **témoin séquentiel** joué AVANT la
# mesure : les mêmes N gestes, un par un, doivent laisser N survivants. C'est une
# assertion DURE (sortie 1 si elle tombe) — si l'ajout ou le comptage est cassé,
# le témoin le dit, et une mesure concurrente à « N-1 » veut alors dire quelque
# chose. Puis la mesure parallèle, sur ROUNDS tours (un banc de concurrence est
# probabiliste : un tour peut être sérialisé par le réseau et ne rien perdre).
#
# ── D'un instrument de mesure à une GARDE (04/08/2026) ────────────────────────
#
# La première version de ce banc était un instrument : il RAPPORTAIT la perte
# (favoris 2/6, declines 1/2), sans prétendre que les fenêtres étaient fermées.
# Elles le sont désormais — `ResourceLockService` sérialise les sections
# critiques et relit la ressource dans le verrou. Le mutex étant en-processus et
# total, N/N est **déterministe**, pas probabiliste : ce banc peut donc ASSERTER
# la fermeture (sortie 1 si un seul tour perd une écriture), et il entre dans
# `run-all-scenarios.sh`.
#
# ⚠️ **Il sait refuser (règle 8), et la preuve est datée.** Avant le verrou, la
# mesure était 2/6 (favoris) et min 1/2 (declines) — exactement ce que
# l'assertion N/N ci-dessous refuse. Retirer le verrou de `appendToOrderList` ou
# de `MerchantFavouritesService.add` fait donc repasser ce banc au ROUGE. Le
# retrait du verrou EST la mutation qui l'éprouve.
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#
#   ./scripts/test-concurrence-fenetres.sh
#   ROUNDS=5    tours de mesure parallèle par fenêtre (défaut 5)
#   FANOUT=6    favoris lancés en parallèle (défaut : autant que de conducteurs
#               réels trouvés, borné à 6, minimum 3)

set -uo pipefail

BFF_URL="${BFF_URL:-http://localhost:3001}"
PASSWORD="${PASSWORD:-motdepasse123}"
MERCHANT="${MERCHANT:-app-parcours-commercant@echango.local}"
ROUNDS="${ROUNDS:-5}"

command -v jq >/dev/null 2>&1 || { echo "jq requis."; exit 1; }

pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; [ -n "${2:-}" ] && echo "   $2"; exit 1; }
note() { echo "ℹ️  $1"; }
step() { echo; echo "── $1 ──"; }

. "$(dirname "$0")/lib/fleetbase.sh"
. "$(dirname "$0")/lib/resolve-driver.sh"
. "$(dirname "$0")/lib/driver-session.sh"

mapi() { local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' -H "Authorization: Bearer $MERCHANT_TOKEN" -d "$b"
  else curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $MERCHANT_TOKEN"; fi; }

# Code HTTP seul, écrit dans un fichier — pour les lancements en parallèle.
mapi_code_bg() { # méthode chemin corps outfile token
  curl -sS -o "$4" -w '%{http_code}' -X "$1" "$BFF_URL$2" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $5" \
    -d "$3" > "$4.code"
}

echo "════════════════════════════════════════════════════════════════"
echo "  Concurrence : les fenêtres de perte d'écriture (declines, favoris)"
echo "════════════════════════════════════════════════════════════════"

step "Décor commun"
fb_activate_vendor_by_email "$MERCHANT" >/dev/null 2>&1 || true
MERCHANT_TOKEN="$(curl -sS -X POST "$BFF_URL/auth/merchant/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$MERCHANT" --arg p "$PASSWORD" '{email:$e, password:$p}')" | jq -r '.token // empty')"
[ -n "$MERCHANT_TOKEN" ] || fail "Connexion commerçant impossible"
pass "Commerçant connecté"

# ══════════════════════════════════════════════════════════════════════════════
#  FENÊTRE A — favourites.add : N favoris distincts, ajoutés en parallèle
# ══════════════════════════════════════════════════════════════════════════════
step "Fenêtre A — favoris : rassembler N conducteurs RÉELS"

# `addFavourite` appelle `getDriverByUuid` : un uuid inventé est refusé en 400.
# Il faut donc de vrais conducteurs de l'annuaire Fleetbase, pas des identifiants
# fabriqués — sinon on mesurerait un refus de validation, pas une perte d'écriture.
mapfile -t FAV_UUIDS < <(fb_get "/int/v1/drivers?limit=50" | jq -r '.drivers[]?.uuid | select(. != null)' | head -6)
FANOUT="${FANOUT:-${#FAV_UUIDS[@]}}"
[ "$FANOUT" -gt "${#FAV_UUIDS[@]}" ] && FANOUT="${#FAV_UUIDS[@]}"
[ "$FANOUT" -ge 2 ] || fail "Deux conducteurs réels distincts requis (trouvés ${#FAV_UUIDS[@]})"
FAV_UUIDS=("${FAV_UUIDS[@]:0:$FANOUT}")
pass "$FANOUT conducteurs réels pour l'éventail de favoris"

# Retire les favoris de test, pour partir d'un compte connu.
clean_favs() {
  for u in "${FAV_UUIDS[@]}"; do
    curl -sS -o /dev/null -X DELETE "$BFF_URL/commercant/transporteurs/favoris/$u" \
      -H "Authorization: Bearer $MERCHANT_TOKEN" >/dev/null 2>&1 || true
  done
}

# Combien des uuids de test sont dans la liste de favoris servie par le BFF ?
count_favs_present() {
  local liste; liste="$(mapi GET /commercant/transporteurs/favoris)"
  printf '%s\n' "${FAV_UUIDS[@]}" | jq -R . | jq -s \
    --argjson favs "$(echo "$liste" | jq '[.data[]?.driver_uuid]')" \
    'map(select(. as $u | $favs | index($u))) | length'
}

add_fav() { # uuid outfile
  mapi_code_bg POST /commercant/transporteurs/favoris \
    "$(jq -n --arg d "$1" '{fleetbaseDriverUuid:$d, partyType:"driver"}')" "$2" "$MERCHANT_TOKEN"
}

step "Fenêtre A — TÉMOIN séquentiel : $FANOUT ajouts un par un doivent TOUS survivre"
clean_favs
for u in "${FAV_UUIDS[@]}"; do
  code="$(curl -sS -o /tmp/fav_seq -w '%{http_code}' -X POST "$BFF_URL/commercant/transporteurs/favoris" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $MERCHANT_TOKEN" \
    -d "$(jq -n --arg d "$u" '{fleetbaseDriverUuid:$d, partyType:"driver"}')")"
  case "$code" in 200|201) ;; *) fail "Ajout séquentiel refusé ($code) pour ${u:0:12}…" "$(head -c 200 /tmp/fav_seq)";; esac
done
seq_favs="$(count_favs_present)"
[ "$seq_favs" -eq "$FANOUT" ] || fail "TÉMOIN faux : $FANOUT ajouts séquentiels, $seq_favs survivants (ajout ou comptage cassé)"
pass "Séquentiel : $seq_favs/$FANOUT — l'ajout ET le comptage marchent"

step "Fenêtre A — GARDE : $FANOUT ajouts EN PARALLÈLE ⇒ $FANOUT survivants, sur $ROUNDS tours"
for r in $(seq 1 "$ROUNDS"); do
  clean_favs
  i=0
  for u in "${FAV_UUIDS[@]}"; do add_fav "$u" "/tmp/fav_$i" & i=$((i+1)); done
  wait
  survivors="$(count_favs_present)"
  [ "$survivors" -le "$FANOUT" ] \
    || fail "Tour $r : $survivors > $FANOUT survivants — comptage ou route incohérents"
  [ "$survivors" -eq "$FANOUT" ] \
    || fail "Tour $r : $survivors/$FANOUT — PERTE D'ÉCRITURE : le verrou favoris a régressé" \
       "avant le verrou : 2/$FANOUT à chaque tour — c'est ce que cette garde empêche de revenir"
  echo "   tour $r : $survivors/$FANOUT favoris survivants"
done
clean_favs
VERDICT_A="fermée — $FANOUT/$FANOUT sur $ROUNDS tours (verrou tenu sous concurrence)"
echo "   → $VERDICT_A"

# ══════════════════════════════════════════════════════════════════════════════
#  FENÊTRE B — declines : deux refus de deux conducteurs, même course, en parallèle
# ══════════════════════════════════════════════════════════════════════════════
step "Fenêtre B — declines : deux conducteurs connectés"
mapfile -t DRV < <(_accounted_driver_uuids)
X_UUID="${DRV[0]:-}"; Y_UUID="${DRV[1]:-}"
[ -n "$X_UUID" ] && [ -n "$Y_UUID" ] && [ "$X_UUID" != "$Y_UUID" ] || fail "Deux conducteurs distincts requis"

free_driver() { # uuid : annule ses courses non terminées (Fleetbase direct)
  for u in $(fb_get "/int/v1/orders?limit=100" | jq -r --arg d "$1" \
      '[.orders[]? | select(.driver_assigned_uuid==$d and (.status|IN("completed","canceled","cancelled")|not))][].uuid'); do
    fb_api PUT "/int/v1/orders/$u" '{"order":{"status":"canceled","driver_assigned_uuid":null}}' >/dev/null 2>&1 || true
  done; }

free_driver "$X_UUID"; free_driver "$Y_UUID"
obtain_driver_token "$X_UUID" >/dev/null 2>&1 || fail "Jeton X impossible" "${DRIVER_SESSION_ERROR:-}"
X_TOKEN="$DRIVER_TOKEN"
obtain_driver_token "$Y_UUID" >/dev/null 2>&1 || fail "Jeton Y impossible" "${DRIVER_SESSION_ERROR:-}"
Y_TOKEN="$DRIVER_TOKEN"
pass "Deux conducteurs (${X_UUID:0:8}…, ${Y_UUID:0:8}…)"

publish_broadcast() { # -> fleetbaseOrderId
  local o uuid
  o="$(mapi POST /commercant/commandes "$(jq -n '{
    pickupLocationName:"Dépôt Concurrence", pickupLatitude:36.7538, pickupLongitude:3.0588,
    pickupContactName:"Commerce", pickupContactPhone:"+213555000000",
    dropoffLocationName:"Client Concurrence", dropoffLatitude:36.7500, dropoffLongitude:3.0600,
    dropoffContactName:"Destinataire", dropoffContactPhone:"+213555111111",
    items:[{description:"colis concurrence", quantity:1}], price:650, podMethod:"aucune", draft:true }')")"
  uuid="$(echo "$o" | jq -r '.fleetbaseOrderId // empty')"
  [ -n "$uuid" ] || { echo "ERR:$(echo "$o" | head -c 200)"; return 1; }
  mapi POST "/commercant/commandes/$uuid/publier" >/dev/null
  echo "$uuid"
}

# Vérité de terrain : combien de refus la commande porte-t-elle chez Fleetbase ?
# Les refus vivent dans le champ personnalisé `declines` (custom_field_values),
# avec un repli sur `meta.declines`. La valeur d'un champ `array` peut revenir en
# chaîne JSON OU déjà désérialisée — les deux sont gérées.
#
# ⚠️ **`with[]=customFieldValues.customField`, crochets ENCODÉS** (`%5B%5D`) :
#   – sans la relation, la lecture unitaire ne porte pas les valeurs des champs
#     personnalisés (mesuré dans le client BFF, `fleetbase-api.client.ts:1067`) ;
#   – `fb_api` appelle `curl` sans `-g`, donc un `[` nu déclenche le globbing
#     d'URL et fait échouer la requête. C'est le même client que le reste du banc.
count_declines() { # orderUuid
  fb_get "/int/v1/orders/$1?with%5B%5D=customFieldValues.customField" | jq '
    (.order // .data // .) as $o
    | ( ($o.custom_field_values // [])
        | map(select(((.custom_field.name // .field_name // "")) == "declines"))
        | (.[0].value // null) ) as $cfv
    | ( if $cfv == null then ($o.meta.declines // []) else $cfv end ) as $raw
    | ( if ($raw|type) == "string" then (try ($raw|fromjson) catch []) else $raw end )
    | if (type == "array") then length else 0 end'
}

decline_bg() { # orderUuid token outfile
  mapi_code_bg POST "/transporteur/commandes/$1/refuser" '{"reason":"indisponible"}' "$3" "$2"
}

step "Fenêtre B — TÉMOIN séquentiel : deux refus l'un après l'autre → 2 doivent rester"
free_driver "$X_UUID"; free_driver "$Y_UUID"
C="$(publish_broadcast)"; [[ "$C" == ERR:* ]] && fail "Publication (témoin)" "$C"
cx="$(curl -sS -o /tmp/dec_x -w '%{http_code}' -X POST "$BFF_URL/transporteur/commandes/$C/refuser" \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $X_TOKEN" -d '{"reason":"indisponible"}')"
case "$cx" in 200|201) ;; *) fail "Refus séquentiel X refusé ($cx)" "$(head -c 200 /tmp/dec_x)";; esac
cy="$(curl -sS -o /tmp/dec_y -w '%{http_code}' -X POST "$BFF_URL/transporteur/commandes/$C/refuser" \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $Y_TOKEN" -d '{"reason":"indisponible"}')"
case "$cy" in 200|201) ;; *) fail "Refus séquentiel Y refusé ($cy)" "$(head -c 200 /tmp/dec_y)";; esac
seq_dec="$(count_declines "$C")"
[ "$seq_dec" -eq 2 ] || fail "TÉMOIN faux : deux refus séquentiels distincts, $seq_dec enregistrés (append ou comptage cassé)" \
  "commande $C — si 0, la lecture des declines chez Fleetbase est à revoir"
pass "Séquentiel : 2/2 refus enregistrés — l'append ET le comptage marchent"

step "Fenêtre B — GARDE : deux refus EN PARALLÈLE ⇒ 2 enregistrés, sur $ROUNDS tours"
for r in $(seq 1 "$ROUNDS"); do
  free_driver "$X_UUID"; free_driver "$Y_UUID"
  C="$(publish_broadcast)"; [[ "$C" == ERR:* ]] && fail "Publication (tour $r)" "$C"
  decline_bg "$C" "$X_TOKEN" /tmp/dec_px &
  decline_bg "$C" "$Y_TOKEN" /tmp/dec_py &
  wait
  px="$(cat /tmp/dec_px.code)"; py="$(cat /tmp/dec_py.code)"
  survivors="$(count_declines "$C")"
  [ "$survivors" -le 2 ] \
    || fail "Tour $r : $survivors > 2 refus — comptage ou route incohérents" "X→$px Y→$py commande $C"
  [ "$survivors" -eq 2 ] \
    || fail "Tour $r : $survivors/2 — PERTE D'ÉCRITURE : le verrou declines a régressé" \
       "avant le verrou : min 1/2 — c'est ce que cette garde empêche de revenir (X→$px Y→$py commande $C)"
  echo "   tour $r : X→$px Y→$py | $survivors/2 refus enregistrés"
done
VERDICT_B="fermée — 2/2 sur $ROUNDS tours (verrou tenu sous concurrence)"
echo "   → $VERDICT_B"

echo
echo "════════════════════════════════════════════════════════════════"
echo "  GARDE DES FENÊTRES DE PERTE D'ÉCRITURE — les deux TENUES"
echo "  favoris   : $VERDICT_A"
echo "  declines  : $VERDICT_B"
echo "════════════════════════════════════════════════════════════════"
echo "  Témoins séquentiels N/N + concurrence N/N. Retirer le verrou"
echo "  fait repasser au rouge (avant : favoris 2/6, declines 1/2)."
echo "════════════════════════════════════════════════════════════════"
