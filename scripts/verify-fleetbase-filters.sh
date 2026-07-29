#!/usr/bin/env bash
# Lot 0 du plan de migration (docs/plan_migration_fleetbase.md §2).
#
# Vérifie par appels réels ce qui n'est aujourd'hui établi que par lecture de
# code : les filtres serveur de Fleetbase, le bug du filtre `phone`, et le
# comportement du cache Redis après écriture.
#
# ── Pourquoi ce script existe ────────────────────────────────────────────────
#
# Le journal §2.8 affirmait que Fleetbase ignore les filtres de query string.
# C'était faux : on envoyait `facilitator_uuid` alors que la méthode s'appelle
# `facilitator`. Trois mécanismes ont été construits côté BFF sur cette
# conclusion. La correction (architecture_bff_fleetbase.md §4) vient elle aussi
# d'une lecture de code — donc elle ne vaut rien tant que ce script n'est pas
# passé.
#
# ── La méthode, et c'est tout l'enjeu ────────────────────────────────────────
#
# Chaque filtre est appelé DEUX fois : avec une valeur réelle, puis avec un
# uuid inventé. On compare les totaux.
#
#   totaux différents  → le filtre est appliqué côté serveur
#   totaux identiques  → le paramètre est ignoré (nom inconnu, ou non supporté)
#
# Un seul appel « qui a l'air de marcher » ne prouve rien : les données
# cherchées sont incluses dans les deux réponses, simplement noyées dans l'une.
# C'est exactement ce qui manquait au test de juillet.
set -uo pipefail

FLEETBASE_URL="${FLEETBASE_URL:-http://localhost:8000}"
TOKEN="${FLEETBASE_API_KEY:-}"

# Un uuid syntaxiquement valide qui n'existe dans aucune table. Sert de témoin
# négatif partout : si le serveur filtre, il ne peut rien renvoyer pour lui.
FAKE_UUID="00000000-dead-4000-8000-000000000000"

if ! command -v jq >/dev/null 2>&1; then
  echo "❌ jq est requis." >&2
  exit 1
fi

if [ -z "$TOKEN" ]; then
  cat <<'EOF' >&2
❌ FLEETBASE_API_KEY manquant.

C'est un token **Sanctum** (format `8|xxxxx…`), PAS la clé `flb_live_…`
affichée dans la console — piège déjà rencontré, voir journal §2.2.
Le plus simple est de le relever dans l'onglet réseau du navigateur, en-tête
`authorization`, sur n'importe quelle requête de la console.

  export FLEETBASE_API_KEY='8|…'
  ./scripts/verify-fleetbase-filters.sh
EOF
  exit 1
fi

PASS=0
FAIL=0
SKIP=0

# Renvoie le corps sur stdout et le code HTTP sur le descripteur 3.
call() {
  local path="$1"
  curl -sS -w '\n%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Accept: application/json' \
    "$FLEETBASE_URL$path"
}

http_code() { tail -n1 <<<"$1"; }
body()      { sed '$d' <<<"$1"; }

# Fleetbase enveloppe ses collections de trois façons selon l'endpoint
# (journal §2.4) : tableau nu, clé `data`, ou clé nommée d'après la ressource.
count_of() {
  local raw="$1" key="$2"
  body "$raw" | jq -r "(.meta.total // (.$key | length?) // (.data | length?) // (length? // 0))" 2>/dev/null || echo "?"
}

compare() {
  local label="$1" path_real="$2" path_fake="$3" key="$4"

  local r f n_real n_fake c_real c_fake
  r=$(call "$path_real"); c_real=$(http_code "$r")
  f=$(call "$path_fake"); c_fake=$(http_code "$f")

  if [ "$c_real" != "200" ] || [ "$c_fake" != "200" ]; then
    echo "⚠️  $label — HTTP $c_real / $c_fake, comparaison impossible"
    body "$r" | head -c 300; echo
    SKIP=$((SKIP + 1))
    return
  fi

  n_real=$(count_of "$r" "$key")
  n_fake=$(count_of "$f" "$key")

  if [ "$n_fake" = "0" ] && [ "$n_real" != "0" ]; then
    echo "✅ $label — filtre APPLIQUÉ (réel: $n_real, témoin: 0)"
    PASS=$((PASS + 1))
  elif [ "$n_real" = "$n_fake" ]; then
    echo "❌ $label — filtre IGNORÉ (les deux renvoient $n_real)"
    echo "     → le nom du paramètre est probablement faux, ou non supporté."
    FAIL=$((FAIL + 1))
  else
    echo "⚠️  $label — résultat ambigu (réel: $n_real, témoin: $n_fake)"
    echo "     → à interpréter à la main : le témoin devrait être 0."
    SKIP=$((SKIP + 1))
  fi
}

echo "════ Fleetbase : $FLEETBASE_URL ════"
echo

# ─────────────────────────────────────────────────────────────────────────────
# Découverte des valeurs réelles — aucune n'est codée en dur : le script doit
# être rejouable sur n'importe quelle instance.
# ─────────────────────────────────────────────────────────────────────────────
echo "── Découverte des identifiants de test ──"

ORDERS=$(call '/int/v1/orders?limit=100')
if [ "$(http_code "$ORDERS")" != "200" ]; then
  echo "❌ GET /int/v1/orders a échoué (HTTP $(http_code "$ORDERS")) — token invalide ?" >&2
  body "$ORDERS" | head -c 400 >&2; echo >&2
  exit 1
fi

ORDER_LIST=$(body "$ORDERS" | jq -c '(.orders // .data // .)')
CUSTOMER_UUID=$(jq -r '[.[] | .customer_uuid // empty] | first // empty' <<<"$ORDER_LIST")
FACILITATOR_UUID=$(jq -r '[.[] | .facilitator_uuid // empty] | first // empty' <<<"$ORDER_LIST")
DRIVER_UUID=$(jq -r '[.[] | .driver_assigned_uuid // empty] | first // empty' <<<"$ORDER_LIST")
ORDER_UUID=$(jq -r '.[0].uuid // empty' <<<"$ORDER_LIST")
TOTAL=$(count_of "$ORDERS" orders)

echo "   commandes visibles : $TOTAL"
echo "   customer_uuid      : ${CUSTOMER_UUID:-(aucune commande de ce type)}"
echo "   facilitator_uuid   : ${FACILITATOR_UUID:-(aucune)}"
echo "   driver_assigned    : ${DRIVER_UUID:-(aucune)}"
echo

DRIVERS=$(call '/int/v1/drivers?limit=100')
DRIVER_NAME=$(body "$DRIVERS" | jq -r '((.drivers // .data // .) | [.[] | .name // empty] | first // empty)')
echo "   nom de conducteur  : ${DRIVER_NAME:-(aucun)}"
echo

# ─────────────────────────────────────────────────────────────────────────────
echo "── V1-V4 : les filtres sont-ils appliqués côté serveur ? ──"

if [ -n "$CUSTOMER_UUID" ]; then
  compare "V1 orders?customer" \
    "/int/v1/orders?customer=$CUSTOMER_UUID" \
    "/int/v1/orders?customer=$FAKE_UUID" orders
else
  echo "⏭️  V1 — aucune commande ne porte de customer_uuid, rien à comparer."
  echo "     (attendu si toutes les commandes de test sont antérieures au correctif §2.10)"
  SKIP=$((SKIP + 1))
fi

if [ -n "$FACILITATOR_UUID" ]; then
  compare "V2 orders?facilitator" \
    "/int/v1/orders?facilitator=$FACILITATOR_UUID" \
    "/int/v1/orders?facilitator=$FAKE_UUID" orders
else
  echo "⏭️  V2 — aucune commande ne porte de facilitator_uuid."
  SKIP=$((SKIP + 1))
fi

if [ -n "$DRIVER_UUID" ]; then
  compare "V3 orders?driver" \
    "/int/v1/orders?driver=$DRIVER_UUID" \
    "/int/v1/orders?driver=$FAKE_UUID" orders
else
  echo "⏭️  V3 — aucune commande assignée à un conducteur."
  SKIP=$((SKIP + 1))
fi

if [ -n "$DRIVER_NAME" ]; then
  ENCODED=$(jq -rn --arg v "$DRIVER_NAME" '$v|@uri')
  compare "V4 drivers?query" \
    "/int/v1/drivers?query=$ENCODED" \
    "/int/v1/drivers?query=zzz-aucun-conducteur-ne-porte-ce-nom" drivers
else
  echo "⏭️  V4 — aucun conducteur dans cette instance."
  SKIP=$((SKIP + 1))
fi

echo
# ─────────────────────────────────────────────────────────────────────────────
echo "── V5 : le filtre phone est-il bien cassé ? ──"
#
# DriverFilter::phone() fait whereHas('phone', …) alors que `phone` est un
# attribut calculé sur Driver, pas une relation. Laravel doit lever.
# `name`, lui, passe par whereHas('user', …) et doit répondre 200.

C_PHONE=$(http_code "$(call '/int/v1/drivers?phone=0555')")
C_NAME=$(http_code "$(call '/int/v1/drivers?name=zzz')")

if [ "$C_PHONE" = "500" ] && [ "$C_NAME" = "200" ]; then
  echo "✅ V5 — bug amont confirmé : phone → 500, name → 200"
  echo "     → utiliser 'query', jamais 'phone' (query couvre le téléphone)."
  PASS=$((PASS + 1))
elif [ "$C_PHONE" = "200" ]; then
  echo "⚠️  V5 — phone répond 200 : le bug est corrigé en amont, ou la version"
  echo "     installée est antérieure. Retirer l'avertissement de la doc."
  SKIP=$((SKIP + 1))
else
  echo "⚠️  V5 — résultat inattendu : phone → $C_PHONE, name → $C_NAME"
  SKIP=$((SKIP + 1))
fi

echo
# ─────────────────────────────────────────────────────────────────────────────
echo "── V6 : le cache Redis rend-il une lecture périmée après écriture ? ──"
#
# C'est le contrôle qui décide du Lot 3 et du Lot 5. Si une lecture juste après
# une écriture peut resservir l'état d'avant, supprimer les colonnes miroir
# exposerait l'application à un décalage qu'elles masquent aujourd'hui.
#
# On ne modifie rien ici : on relit deux fois la même requête et on observe si
# le cache SERT (HIT). Le test d'invalidation après écriture demande une
# modification réelle, laissée à la main pour ne pas altérer des données.

read_cache_headers() {
  curl -sS -o /dev/null -D - \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Accept: application/json' \
    "$FLEETBASE_URL/int/v1/orders?limit=5" \
    | tr -d '\r' | grep -i '^x-cache' || true
}

echo "   premier appel :"
read_cache_headers | sed 's/^/     /'
echo "   second appel  :"
SECOND=$(read_cache_headers)
echo "$SECOND" | sed 's/^/     /'

if grep -qi 'x-cache-status: *HIT' <<<"$SECOND"; then
  echo "✅ V6a — le cache SERT réellement (HIT au second appel)."
  echo "     → l'invalidation après écriture devient une question ouverte."
  PASS=$((PASS + 1))
else
  echo "ℹ️  V6a — pas de HIT observé : cache désactivé, ou clé variable."
  SKIP=$((SKIP + 1))
fi

cat <<EOF

   ⚠️  V6b — À FAIRE À LA MAIN, ce script ne modifie aucune donnée :
       1. relever le numéro de version dans x-cache-key ci-dessus (…:vNNN:…)
       2. modifier une commande dans la console (changer son statut suffit)
       3. rejouer ce script et comparer le numéro de version

       version incrémentée  → l'invalidation est correcte, Lots 3 et 5 sûrs
       version inchangée    → une lecture peut être périmée : conserver les
                              colonnes miroir jusqu'à comprendre la politique
EOF

echo
# ─────────────────────────────────────────────────────────────────────────────
echo "── V9 : GET /drivers/{uuid} renvoie-t-il UN objet, ou la liste ? ──"
#
# §2.13 a montré que GET /vendors/{uuid} ignore son paramètre de chemin et
# renvoie les 7 vendors de la compagnie. Si /drivers se comporte pareil, une
# lecture unitaire renverrait le premier conducteur venu — donc rattacherait un
# compte au mauvais transporteur, sans la moindre erreur. C'est pour ça que le
# BFF parcourt encore la liste (journal §22).

DRIVER_UUID=$(body "$DRIVERS" | jq -r '((.drivers // .data // .) | .[0].uuid // empty)')
if [ -n "$DRIVER_UUID" ]; then
  ONE=$(call "/int/v1/drivers/$DRIVER_UUID")
  N_ONE=$(count_of "$ONE" drivers)
  RETURNED=$(body "$ONE" | jq -r '(.driver.uuid // .uuid // ((.drivers // .data // [])[0].uuid) // "?")')

  if [ "$RETURNED" = "$DRIVER_UUID" ] && { [ "$N_ONE" = "1" ] || [ "$N_ONE" = "0" ]; }; then
    echo "✅ V9 — lecture unitaire fiable (uuid demandé = uuid renvoyé)"
    echo "     → le parcours paginé de fetchEveryDriver() peut être remplacé."
    PASS=$((PASS + 1))
  else
    echo "⚠️  V9 — réponse suspecte : $N_ONE enregistrement(s), premier uuid $RETURNED"
    echo "     → même défaut que /vendors/{uuid} : NE PAS passer en lecture unitaire."
    SKIP=$((SKIP + 1))
  fi
else
  echo "⏭️  V9 — aucun conducteur dans cette instance."
  SKIP=$((SKIP + 1))
fi

echo
# ─────────────────────────────────────────────────────────────────────────────
echo "── V7 : le statut du Vendor, support de la validation commerçant ──"

VENDORS=$(call '/int/v1/vendors?limit=5')
if [ "$(http_code "$VENDORS")" = "200" ]; then
  echo "   champs ressemblant à un statut sur le premier vendor :"
  body "$VENDORS" \
    | jq -r '((.vendors // .data // .) | .[0] // {}) | to_entries
             | map(select(.key | test("status|state|active|approv|verif";"i")))
             | if length == 0 then "     (aucun champ de statut trouvé)"
               else (.[] | "     \(.key) = \(.value|tostring)") end'
  echo "     → le changer dans la console, relancer, vérifier que la valeur suit."
else
  echo "⚠️  V7 — GET /vendors a répondu $(http_code "$VENDORS")"
  SKIP=$((SKIP + 1))
fi

echo
echo "════ Bilan : $PASS validés, $FAIL en échec, $SKIP à interpréter ════"
echo
if [ "$FAIL" -gt 0 ]; then
  cat <<'EOF'
❌ Au moins un filtre est ignoré. NE PAS lancer le Lot 1.
   Relever le nom exact dans l'onglet réseau de la console (elle envoie ce qui
   marche) et corriger docs/architecture_bff_fleetbase.md §4.2 avant de coder.
EOF
  exit 1
fi

cat <<'EOF'
Prochaines étapes selon le résultat — docs/plan_migration_fleetbase.md :
  V1-V4 ✅            → Lot 1 (filtrage serveur)
  V6b version bouge   → Lots 3 et 5
  V7 champ identifié  → Lot 4 (validation commerçant)
  V8 (webhooks)       → à faire depuis la console : Developers → Webhooks
EOF
