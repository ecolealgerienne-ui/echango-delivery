#!/usr/bin/env bash
#
# La multi-appartenance : un conducteur qui roule pour PLUSIEURS entreprises.
#
# ── Pourquoi ce script ────────────────────────────────────────────────────
#
# Le chantier du 31/07/2026 a livré `DriverMembership`, ses deux garde-fous et
# une sortie côté conducteur. Rien de tout cela n'a **jamais tourné** :
# `test-parcours-argent-flotte.sh` exerce bien une adhésion, mais **une seule**,
# acceptée du premier coup. Il ne peut donc rien dire de ce qui fait la
# multi-appartenance — deux entreprises pour la même personne — ni d'aucun des
# refus qui la rendent sûre.
#
# Or c'est précisément là que sont les défauts trouvés à l'écriture : sept, dont
# deux graves, et **aucun trouvé à la lecture**.
#
# ── Le contournement, qui est la raison d'être de ce script ────────────────
#
# Un rattachement `active` s'obtenait SANS le consentement du conducteur, en
# deux appels entièrement dans les droits de l'entreprise :
#
#     demander    → pending
#     suspendre   → suspended    (aucune garde à l'époque)
#     reactiver   → active       (garde satisfaite)
#
# Le conducteur n'avait jamais répondu, et l'entreprise pouvait lui confier une
# course encaissée — exactement l'obligation financière unilatérale que le
# passage par `pending` existe pour empêcher. Le même chemin **écrasait un refus
# explicite** (`declined` → `suspended` → `active`).
#
# Le correctif garde les DEUX sens. Ce script rejoue les deux attaques.
#
# ── Ce qu'il ne fait pas, et pourquoi ─────────────────────────────────────
#
# **Les deux plafonds de dette ne sont pas ici.** Ils exigent d'accumuler une
# dette réelle — donc une course encaissée, livrée, et un registre garni —, ce
# qui est un autre scénario avec ses propres écritures. Les mélanger rendrait un
# échec ambigu : on ne saurait pas si c'est l'adhésion ou le plafond qui a cédé.
# Même raisonnement que pour l'écart à la porte, laissé hors de
# `test-parcours-argent.sh` pour cette raison exacte.
#
# De même, « une seule course active à la fois » est déjà exercé par
# `require_free_driver` dans le script d'argent flotte.
#
# ── Usage ─────────────────────────────────────────────────────────────────
#
#   ./scripts/test-multi-appartenance.sh                 # un conducteur au hasard
#   ./scripts/test-multi-appartenance.sh alice@test.dz   # ou email, téléphone,
#   ./scripts/test-multi-appartenance.sh "Alice"         # ou fragment de nom
#
#   BFF_URL=http://localhost:3001   adresse du BFF
#
# Les deux entreprises sont créées puis **activées par le script** avec la clé
# de service Fleetbase. Le garde du Lot 4 reste entier : c'est le rôle d'admin
# qui est tenu, pas le garde qui est contourné.

set -euo pipefail

BFF_URL="${BFF_URL:-http://localhost:3001}"
PASSWORD="${PASSWORD:-motdepasse123}"
DRIVER_HINT="${1:-}"

command -v jq >/dev/null 2>&1 || { echo "jq requis."; exit 1; }

pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; [ -n "${2:-}" ] && echo "   Réponse : $2"; exit 1; }
step() { echo; echo "── $1 ──"; }

# Par `statusCode` et non par `code` : un objet métier peut porter un `code`, et
# le tester ferait passer une réponse valide pour un échec. Même choix que dans
# les deux scripts d'argent.
is_error() { jq -e 'type == "object" and ((.statusCode | type) == "number")' >/dev/null 2>&1; }

# Le code métier d'un refus, ou vide. C'est LUI qu'on vérifie, jamais le
# message : le message est français et destiné à l'écran, le code est le
# contrat (règle 4 du projet).
err_code() { jq -r '.code // empty' 2>/dev/null; }

# Exige un refus portant un code précis. Un refus pour un AUTRE motif est un
# échec, pas un succès — sans quoi le contrôle passerait au vert le jour où la
# route disparaît (404) ou casse (500).
expect_refusal() { # libellé code_attendu réponse
  local label="$1" want="$2" body="$3" got
  echo "$body" | is_error || fail "$label : la requête a RÉUSSI, or elle doit être refusée" "$(echo "$body" | jq -c '.')"
  got="$(echo "$body" | err_code)"
  [ "$got" = "$want" ] || fail "$label : refusé pour '$got', attendu '$want'" "$(echo "$body" | jq -c '.')"
  pass "$label — refusé ($want)"
}

fapi() { # method path [body] — entreprise A
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $FLEET_A_TOKEN" -d "$b"
  else
    curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $FLEET_A_TOKEN"
  fi
}

gapi() { # method path [body] — entreprise B
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $FLEET_B_TOKEN" -d "$b"
  else
    curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $FLEET_B_TOKEN"
  fi
}

dapi() { # method path [body] — conducteur
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $DRIVER_TOKEN" -d "$b"
  else
    curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $DRIVER_TOKEN"
  fi
}

# L'adhésion de CETTE entreprise, vue par le conducteur. La liste peut porter en
# tête l'entreprise d'ORIGINE (`vendor_uuid`), qui n'est pas une adhésion et dont
# l'`id` vaut `null` — d'où le filtre sur l'identifiant, jamais `.data[0]`.
membership_status() { # membership_id -> statut sur stdout, vide si absente
  dapi GET /transporteur/entreprises \
    | jq -r --arg id "$1" '.data[]? | select(.id == $id) | .status' 2>/dev/null
}

echo "BFF : $BFF_URL"
echo "Scénario : UN conducteur, DEUX entreprises, et les refus qui gardent l'adhésion."

. "$(dirname "$0")/lib/fleetbase.sh"
. "$(dirname "$0")/lib/resolve-driver.sh"
. "$(dirname "$0")/lib/driver-session.sh"

SUFFIX="$(date +%s)"

# ── Le conducteur d'abord ──────────────────────────────────────────────────
#
# Ce qui peut refuser passe devant ce qui écrit : un conducteur introuvable ou
# sans compte doit faire échouer le script AVANT qu'il laisse derrière lui deux
# entreprises et deux fournisseurs activés. Leçon du 01/08 sur le script
# d'argent flotte, où le conducteur venait en dernier.
step "0. Le conducteur"
resolve_driver "$DRIVER_HINT" || fail "${RESOLVE_DRIVER_ERROR:-Conducteur introuvable}"
obtain_driver_token "$DRIVER_UUID" || fail "${DRIVER_SESSION_ERROR:-Session conducteur impossible}"
pass "Conducteur : ${DRIVER_LABEL:-$DRIVER_UUID} — ${DRIVER_SESSION_NOTE:-}"

# ── Les deux entreprises ───────────────────────────────────────────────────
#
# DEUX, et c'est tout l'objet : la multi-appartenance n'est pas observable avec
# une seule. Un script à une entreprise ne distingue pas « le conducteur peut
# adhérer » de « le conducteur peut adhérer à plusieurs », qui est la décision
# produit du 31/07.
register_fleet() { # variable_prefixe libellé -> renseigne <PREFIXE>_TOKEN et _ID
  local var="$1" label="$2" email reg status body login token id
  email="ma-$(echo "$var" | tr 'A-Z' 'a-z')-$SUFFIX@test.dz"

  reg="$(curl -sS -w '\n%{http_code}' -X POST "$BFF_URL/auth/flotte/register" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg e "$email" --arg p "$PASSWORD" --arg n "$label" '{
      email:$e, password:$p, businessName:$n, firstName:"Test",
      lastName:"Multi", phone:"+213555333333", businessPhone:"+213555333333"}')")"
  status="$(tail -n1 <<<"$reg")"; body="$(sed '$d' <<<"$reg")"

  # Le garde du Lot 4 : aucun jeton à l'inscription, le `Vendor` naît inactive.
  [ -z "$(jq -r '.token // empty' <<<"$body" 2>/dev/null)" ] \
    || fail "Un jeton a été délivré à l'inscription de $label" "$body"
  [ "$status" = "403" ] || fail "L'inscription de $label doit être mise en attente (HTTP $status)" "$body"

  fb_activate_vendor_by_email "$email" \
    || fail "Activation de $label impossible : ${FLEETBASE_ERROR:-}"

  # UNE seule connexion par acteur : `THROTTLE_LOGIN` plafonne à cinq par
  # minute, et deux par entreprise feraient échouer le script pour une raison
  # étrangère à ce qu'il teste.
  login="$(curl -sS -X POST "$BFF_URL/auth/login" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg e "$email" --arg p "$PASSWORD" '{email:$e,password:$p}')")"
  token="$(echo "$login" | jq -r '.token // empty')"
  id="$(echo "$login" | jq -r '.user.id // empty')"
  [ -n "$token" ] && [ -n "$id" ] || fail "Connexion de $label refusée après activation" "$login"

  printf -v "${var}_TOKEN" '%s' "$token"
  printf -v "${var}_ID" '%s' "$id"
  printf -v "${var}_EMAIL" '%s' "$email"
  pass "$label : $email ($id)"
}

step "0 bis. Les deux entreprises"
register_fleet FLEET_A "Transports Alpha"
register_fleet FLEET_B "Transports Beta"

# ── 1. La recherche ────────────────────────────────────────────────────────
step "1. Recherche d'un conducteur déjà dans le réseau"

# ⚠️ La recherche est le SEUL moyen pour une entreprise de trouver quelqu'un
# sans le recréer. Sans elle, la seconde entreprise qui embauche une personne
# déjà connue la recrée — deux `Driver` Fleetbase pour une personne, position et
# historique désynchronisés (le défaut documenté le 26/07 pour le
# multi-Organization).
#
# On cherche par un fragment du nom réel, celui que `resolve_driver` a relevé.
NEEDLE="$(printf '%s' "${DRIVER_LABEL:-}" | sed 's/ .*//' | tr -d '"')"
[ ${#NEEDLE} -ge 3 ] || NEEDLE="$(printf '%s' "${DRIVER_LABEL:-abc}" | cut -c1-3)"

found="$(fapi GET "/flotte/conducteurs/recherche?q=$(printf '%s' "$NEEDLE" | jq -sRr @uri)")"
echo "$found" | is_error && fail "Recherche refusée" "$(echo "$found" | jq -c '.')"
hits="$(echo "$found" | jq -r '.data | length' 2>/dev/null || echo 0)"
[ "$hits" -ge 1 ] || fail "La recherche ne trouve pas « $NEEDLE », alors que ce conducteur existe" "$found"

# Le téléphone n'est JAMAIS renvoyé : celui qui cherche le connaît déjà, et une
# liste qui le porterait serait l'annuaire qu'on refuse d'ouvrir (§ du 29/07).
echo "$found" | jq -e '[.data[]? | select(has("phone") or has("telephone"))] | length == 0' >/dev/null \
  || fail "La recherche expose un téléphone" "$(echo "$found" | jq -c '.data[0]')"
pass "Recherche : $hits résultat(s) pour « $NEEDLE », sans téléphone"

# ── 2. La garde anti-doublon ───────────────────────────────────────────────
step "2. Recréer une personne déjà dans le réseau est refusé"

# ⚠️ C'est la moitié qui rend la décision tenable : « chaque entreprise inscrit
# ses conducteurs » et « un conducteur peut rouler pour plusieurs » se
# contredisent si rien n'empêche la seconde entreprise de recréer la personne.
# `assertNotAlreadyInNetwork()` refuse sur l'email OU le téléphone.
#
# Le téléphone est normalisé aux neuf chiffres de l'abonné : `0555123456` et
# `+213555123456` sont la même personne, et un `endsWith` naïf sur les chiffres
# bruts échouait sur ce cas — le plus courant du pays.
# ⚠️ Par `fb_drivers`, la lecture déjà éprouvée de la bibliothèque, et non par un
# second appel unitaire : deux chemins de lecture pour la même donnée, c'est une
# borne de pagination ou une forme de réponse qui diverge sans bruit (règle 5,
# et c'est exactement le motif qui a fait remonter cette fonction dans
# `fleetbase.sh`). Un seul appel, aussi : la même donnée demandée deux fois,
# c'est deux occasions d'échouer.
DRIVER_RECORD="$(fb_drivers | jq -c --arg u "$DRIVER_UUID" 'map(select(.uuid == $u)) | first // {}')" \
  || fail "Lecture des conducteurs impossible" "${FLEETBASE_ERROR:-}"
DRIVER_EMAIL="$(echo "$DRIVER_RECORD" | jq -r '.email // .user.email // empty')"
DRIVER_PHONE="$(echo "$DRIVER_RECORD" | jq -r '.phone // .user.phone // empty')"

if [ -n "$DRIVER_EMAIL" ]; then
  # ⚠️ `name`, `email`, `phone` et RIEN d'autre : `AddDriverDto` ne déclare que
  # ces trois champs et le `ValidationPipe` refuse le reste. Un `vehicleType`
  # ajouté « au cas où » faisait répondre `validation.failed` — un refus, donc
  # un script naïf serait passé au vert sans avoir jamais atteint la garde
  # anti-doublon. C'est `expect_refusal`, qui exige le code EXACT, qui l'a vu.
  dup="$(gapi POST /flotte/drivers "$(jq -n --arg e "$DRIVER_EMAIL" '{
    name:"Doublon Email", email:$e}')")"
  expect_refusal "Recréation par email" "driver.already_in_network" "$dup"
else
  echo "ℹ️  Conducteur sans email : garde anti-doublon par email non exerçable."
fi

if [ -n "$DRIVER_PHONE" ]; then
  # (a) À l'identique — `sameIdentifier` compare d'abord littéralement, donc ce
  #     cas vaut quel que soit le format du numéro stocké.
  dup="$(gapi POST /flotte/drivers "$(jq -n --arg p "$DRIVER_PHONE" '{
    name:"Doublon Tel", phone:$p}')")"
  expect_refusal "Recréation par téléphone identique ($DRIVER_PHONE)" \
    "driver.already_in_network" "$dup"

  # (b) En format CROISÉ — c'est la normalisation qu'on éprouve, et c'est le
  #     couple le plus fréquent du pays : enregistré en `+213…`, ressaisi en
  #     `0…`.
  #
  # ⚠️ **Exerçable seulement sur un numéro algérien**, et le dire vaut mieux que
  # de faire semblant. `subscriberDigits` retire `213` puis le zéro de tête et
  # exige NEUF chiffres ; un `+33622222222` en donne onze, donc
  # `subscriberNumber` rend `null` et refuse — délibérément — de fonder un refus
  # sur un numéro qu'il ne sait pas interpréter. Un conducteur au numéro
  # étranger échappe donc au rapprochement inter-format : c'est cohérent avec un
  # produit algérien, mais ce n'est pas rien, et un script qui bricolerait un
  # « variant » jusqu'à obtenir un refus le masquerait au lieu de le montrer.
  digits="$(printf '%s' "$DRIVER_PHONE" | tr -cd '0-9')"
  digits="${digits#00}"; digits="${digits#213}"; digits="${digits#0}"
  if [ ${#digits} -eq 9 ]; then
    case "$DRIVER_PHONE" in
      +213*|00213*) variant="0$digits" ;;
      *)            variant="+213$digits" ;;
    esac
    dup="$(gapi POST /flotte/drivers "$(jq -n --arg p "$variant" '{
      name:"Doublon Tel Croise", phone:$p}')")"
    expect_refusal "Recréation en format croisé ($DRIVER_PHONE ≡ $variant)" \
      "driver.already_in_network" "$dup"
  else
    echo "ℹ️  $DRIVER_PHONE n'est pas un numéro algérien (${#digits} chiffres d'abonné,"
    echo "    9 attendus) : le rapprochement inter-format n'est pas exerçable sur"
    echo "    ce conducteur. L'égalité littérale ci-dessus, elle, a bien refusé."
  fi
else
  echo "ℹ️  Conducteur sans téléphone : garde anti-doublon par téléphone non exerçable."
fi

# ── 3. L'adhésion à la première entreprise ─────────────────────────────────
step "3. Adhésion à Alpha : demande, puis acceptation par le conducteur"

asked="$(fapi POST "/flotte/conducteurs/$DRIVER_UUID/adhesion")"
echo "$asked" | is_error && fail "Demande d'adhésion Alpha refusée" "$(echo "$asked" | jq -c '.')"
MA_ID="$(echo "$asked" | jq -r '.id // empty')"
[ -n "$MA_ID" ] || fail "La demande ne rend pas d'identifiant" "$asked"
[ "$(echo "$asked" | jq -r '.status')" = "pending" ] \
  || fail "Une adhésion doit naître 'pending'" "$asked"
pass "Alpha a demandé — statut pending"

# ⚠️ **L'attaque en deux temps, sur une adhésion jamais acceptée.**
suspend="$(fapi POST "/flotte/adhesions/$MA_ID/suspendre")"
expect_refusal "Suspendre une demande 'pending'" "membership.not_active" "$suspend"

react="$(fapi POST "/flotte/adhesions/$MA_ID/reactiver")"
expect_refusal "Réactiver ce qui n'a jamais été suspendu" "membership.not_suspended" "$react"
pass "Le contournement 'demander → suspendre → réactiver' est fermé des deux côtés"

# Le conducteur voit la demande, et c'est LUI qui tranche.
[ "$(membership_status "$MA_ID")" = "pending" ] \
  || fail "Le conducteur ne voit pas la demande d'Alpha" "$(dapi GET /transporteur/entreprises)"

acc="$(dapi POST "/transporteur/entreprises/$MA_ID/accepter")"
echo "$acc" | is_error && fail "Acceptation refusée" "$(echo "$acc" | jq -c '.')"
[ "$(echo "$acc" | jq -r '.status')" = "active" ] || fail "L'acceptation doit rendre 'active'" "$acc"
pass "Le conducteur a accepté Alpha — active"

# Répondre deux fois est refusé : sans ça, un refus pourrait être « repris ».
again="$(dapi POST "/transporteur/entreprises/$MA_ID/refuser")"
expect_refusal "Répondre une seconde fois" "membership.not_pending" "$again"

# ── 4. La multi-appartenance elle-même ─────────────────────────────────────
step "4. La même personne adhère AUSSI à Beta"

# C'est la décision produit du 31/07, et rien ne l'avait jamais exercée :
# « indépendant qui roule aussi pour une société » EST de la multi-appartenance.
asked_b="$(gapi POST "/flotte/conducteurs/$DRIVER_UUID/adhesion")"
echo "$asked_b" | is_error \
  && fail "Beta ne peut pas demander un conducteur déjà chez Alpha — la multi-appartenance ne marche pas" \
          "$(echo "$asked_b" | jq -c '.')"
MB_ID="$(echo "$asked_b" | jq -r '.id // empty')"
[ -n "$MB_ID" ] || fail "La demande de Beta ne rend pas d'identifiant" "$asked_b"
[ "$MB_ID" != "$MA_ID" ] || fail "Beta a reçu l'adhésion d'Alpha — les couples ne sont pas distincts" "$asked_b"

acc_b="$(dapi POST "/transporteur/entreprises/$MB_ID/accepter")"
echo "$acc_b" | is_error && fail "Acceptation de Beta refusée" "$(echo "$acc_b" | jq -c '.')"
pass "Deux adhésions distinctes, toutes deux actives"

# Les DEUX doivent être actives EN MÊME TEMPS. Vérifier chacune séparément ne
# distinguerait pas la multi-appartenance d'un simple transfert d'entreprise.
actives="$(dapi GET /transporteur/entreprises \
  | jq -r --arg a "$MA_ID" --arg b "$MB_ID" \
      '[.data[]? | select(.id == $a or .id == $b) | select(.status == "active")] | length')"
[ "$actives" = "2" ] \
  || fail "Le conducteur devrait avoir 2 rattachements actifs, il en a $actives" \
          "$(dapi GET /transporteur/entreprises | jq -c '.data')"
pass "Le conducteur roule simultanément pour Alpha ET Beta"

# Chaque entreprise ne voit QUE son propre lien : une adhésion chez un
# concurrent est une information commerciale.
seen_by_a="$(fapi GET /flotte/adhesions | jq -r --arg b "$MB_ID" '[.data[]? | select(.id == $b)] | length')"
[ "$seen_by_a" = "0" ] || fail "Alpha voit l'adhésion du conducteur chez Beta — fuite commerciale" \
  "$(fapi GET /flotte/adhesions | jq -c '.data')"
pass "Alpha ne voit pas l'adhésion chez Beta"

# ── 5. La sortie, côté conducteur ──────────────────────────────────────────
step "5. Le conducteur quitte Beta"

# ⚠️ Le consentement était à SENS UNIQUE jusqu'au 31/07 : ayant accepté une
# fois, le conducteur restait rattaché indéfiniment et seule l'entreprise
# pouvait rompre. `quitter` est le pendant en sortie.
left="$(dapi POST "/transporteur/entreprises/$MB_ID/quitter")"
echo "$left" | is_error && fail "Le conducteur ne peut pas quitter Beta" "$(echo "$left" | jq -c '.')"
[ "$(echo "$left" | jq -r '.status')" = "declined" ] \
  || fail "Quitter doit rendre 'declined'" "$left"
pass "Le conducteur a quitté Beta"

# Quitter deux fois est refusé — et le code le dit.
twice="$(dapi POST "/transporteur/entreprises/$MB_ID/quitter")"
expect_refusal "Quitter une seconde fois" "membership.not_active" "$twice"

# ⚠️ **Le lien n'est pas effacé.** La dette survit à la séparation ; supprimer la
# ligne emporterait la trace du lien qui l'explique, et le registre afficherait
# une dette sans contrepartie lisible. La ligne doit donc EXISTER, en `declined`.
[ "$(membership_status "$MB_ID")" = "declined" ] \
  || fail "L'adhésion quittée a disparu au lieu de rester 'declined'" \
          "$(dapi GET /transporteur/entreprises | jq -c '.data')"
pass "Le lien avec Beta subsiste en 'declined' — la dette garde sa contrepartie"

# Et Alpha n'a pas bougé : quitter l'un ne quitte pas l'autre.
[ "$(membership_status "$MA_ID")" = "active" ] \
  || fail "Quitter Beta a affecté le rattachement à Alpha"
pass "Alpha est intacte"

# ── 6. Un refus ne se contourne pas ────────────────────────────────────────
step "6. Beta redemande, le conducteur refuse, Beta insiste"

# Une adhésion `declined` se REDEMANDE — la ligne repasse à `pending` plutôt
# qu'une seconde soit créée, pour que l'unicité du couple tienne.
redo="$(gapi POST "/flotte/conducteurs/$DRIVER_UUID/adhesion")"
echo "$redo" | is_error && fail "Beta ne peut pas redemander après un départ" "$(echo "$redo" | jq -c '.')"
MB2_ID="$(echo "$redo" | jq -r '.id')"
[ "$MB2_ID" = "$MB_ID" ] \
  || fail "Une SECONDE ligne a été créée au lieu de rouvrir la première ($MB_ID → $MB2_ID)" "$redo"
pass "La demande rouvre la ligne existante, sans doublon"

ref="$(dapi POST "/transporteur/entreprises/$MB_ID/refuser")"
echo "$ref" | is_error && fail "Refus impossible" "$(echo "$ref" | jq -c '.')"
[ "$(echo "$ref" | jq -r '.status')" = "declined" ] || fail "Un refus doit rendre 'declined'" "$ref"
pass "Le conducteur a refusé"

# ⚠️ **La seconde attaque** : écraser un refus explicite par le même chemin.
s2="$(gapi POST "/flotte/adhesions/$MB_ID/suspendre")"
expect_refusal "Suspendre un refus explicite" "membership.not_active" "$s2"
r2="$(gapi POST "/flotte/adhesions/$MB_ID/reactiver")"
expect_refusal "Réactiver un refus explicite" "membership.not_suspended" "$r2"
pass "Un refus du conducteur ne se contourne pas"

# ── 7. La suspension légitime ──────────────────────────────────────────────
step "7. Alpha suspend puis réactive — le chemin normal"

sus="$(fapi POST "/flotte/adhesions/$MA_ID/suspendre")"
echo "$sus" | is_error && fail "Alpha ne peut pas suspendre un rattachement actif" "$(echo "$sus" | jq -c '.')"
[ "$(echo "$sus" | jq -r '.status')" = "suspended" ] || fail "La suspension doit rendre 'suspended'" "$sus"
pass "Alpha a suspendu"

rea="$(fapi POST "/flotte/adhesions/$MA_ID/reactiver")"
echo "$rea" | is_error && fail "Alpha ne peut pas réactiver ce qu'elle a suspendu" "$(echo "$rea" | jq -c '.')"
[ "$(echo "$rea" | jq -r '.status')" = "active" ] || fail "La réactivation doit rendre 'active'" "$rea"
pass "Alpha a réactivé — le chemin légitime fonctionne"

# ── 8. L'isolation entre entreprises ───────────────────────────────────────
step "8. Beta ne touche pas à l'adhésion d'Alpha"

# Un seul refus pour « inexistante » et « pas à vous » : distinguer les deux
# apprendrait à Beta que l'adhésion existe ailleurs.
cross="$(gapi POST "/flotte/adhesions/$MA_ID/suspendre")"
expect_refusal "Beta suspend l'adhésion d'Alpha" "membership.not_found" "$cross"

# ══════════════════════════════════════════════════════════════════════════
# 9 — LE COMMERÇANT MET UNE ENTREPRISE EN FAVORI
# ══════════════════════════════════════════════════════════════════════════
#
# ── Pourquoi ici, dans le scénario des adhésions ──────────────────────────
#
# Parce qu'il est le seul à disposer de **deux entreprises réellement
# inscrites et validées**. Un favori entreprise ne se teste pas contre un uuid
# fabriqué : la garde côté serveur exige un `FleetAccount` **actif**, et
# vérifier qu'elle refuse un inconnu ne dit rien de ce qu'elle accepte.
#
# ── Ce que ça exerce, et qui n'avait jamais tourné ───────────────────────
#
# La décision du 30/07 (`specs_flux_argent_quatre_acteurs.md` §6.1) : le
# commerçant choisit **au même endroit** un transporteur du pool ou une
# entreprise. Toute la chaîne — recherche, ajout, relecture, retrait — n'avait
# jamais été jouée pour la seconde famille.
step "9. Une entreprise mise en favori par un commerçant"

MERCHANT_EMAIL="ma-c-$SUFFIX@test.dz"
reg="$(curl -sS -w '\n%{http_code}' -X POST "$BFF_URL/auth/merchant/register" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$MERCHANT_EMAIL" --arg p "$PASSWORD" '{
    email:$e, password:$p, businessName:"Commerce Favori", firstName:"Test",
    lastName:"Favori", phone:"+213555444444", businessPhone:"+213555444444"}')")"
status="$(tail -n1 <<<"$reg")"
[ "$status" = "403" ] || fail "L'inscription commerçant doit être mise en attente (HTTP $status)" "$reg"
fb_activate_vendor_by_email "$MERCHANT_EMAIL" \
  || fail "Activation du commerçant impossible : ${FLEETBASE_ERROR:-}"
mlogin="$(curl -sS -X POST "$BFF_URL/auth/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$MERCHANT_EMAIL" --arg p "$PASSWORD" '{email:$e,password:$p}')")"
MERCHANT_TOKEN="$(echo "$mlogin" | jq -r '.token // empty')"
[ -n "$MERCHANT_TOKEN" ] || fail "Connexion commerçant refusée" "$mlogin"
pass "Commerçant : $MERCHANT_EMAIL"

capi() { # method path [body] — commerçant
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $MERCHANT_TOKEN" -d "$b"
  else
    curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $MERCHANT_TOKEN"
  fi
}

# ── La recherche rend les DEUX familles ──────────────────────────────────
#
# « Transports Alpha » est le nom donné plus haut ; la recherche porte sur le
# nom commercial du `FleetAccount`.
found="$(capi GET "/commercant/transporteurs/recherche?q=$(printf 'Transports Alpha' | jq -sRr @uri)")"
echo "$found" | is_error && fail "Recherche refusée" "$(echo "$found" | jq -c '.')"

ALPHA_VENDOR="$(echo "$found" | jq -r '[.data[]? | select(.party_type == "fleet")] | first.driver_uuid // empty')"
[ -n "$ALPHA_VENDOR" ] \
  || fail "La recherche ne rend aucune entreprise pour « Transports Alpha »" \
          "$(echo "$found" | jq -c '.data')"
pass "La recherche rend l'entreprise, typée « fleet »"

# ⚠️ **Le prestataire plateforme ne doit JAMAIS apparaître.** Echango est déjà
# le facilitateur par défaut de toute course du pool : le proposer parmi des
# prestataires « qu'on choisit » ferait croire à un choix qui n'en est pas un.
# Le contrôle porte sur une recherche large, celle qui a le plus de chances de
# le ramener.
wide="$(capi GET "/commercant/transporteurs/recherche?q=$(printf 'test' | jq -sRr @uri)")"
fb_resolve_platform || true
if [ -n "${PLATFORM_VENDOR_UUID:-}" ]; then
  echo "$wide" | jq -e --arg v "$PLATFORM_VENDOR_UUID" \
    '[.data[]? | select(.driver_uuid == $v)] | length == 0' >/dev/null \
    || fail "Le prestataire plateforme apparaît dans la recherche" "$(echo "$wide" | jq -c '.data')"
  pass "Le prestataire plateforme est exclu de la recherche"
fi

# ── L'ajout, et son refus quand l'entreprise n'existe pas ────────────────
ghost="$(capi POST /commercant/transporteurs/favoris \
  "$(jq -n '{partyType:"fleet", fleetbaseDriverUuid:"00000000-0000-0000-0000-000000000000"}')")"
expect_refusal "Mettre en favori une entreprise inconnue" "merchant.fleet_not_in_network" "$ghost"

added="$(capi POST /commercant/transporteurs/favoris \
  "$(jq -n --arg v "$ALPHA_VENDOR" '{partyType:"fleet", fleetbaseDriverUuid:$v}')")"
echo "$added" | is_error && fail "Ajout du favori entreprise refusé" "$(echo "$added" | jq -c '.')"
pass "Entreprise ajoutée aux favoris"

# ── La relecture porte le type, et le nom vient du SERVEUR ──────────────
favs="$(capi GET /commercant/transporteurs/favoris)"
row="$(echo "$favs" | jq -c --arg v "$ALPHA_VENDOR" '.data[]? | select(.driver_uuid == $v)')"
[ -n "$row" ] || fail "Le favori n'est pas relu" "$(echo "$favs" | jq -c '.data')"
[ "$(echo "$row" | jq -r '.party_type')" = "fleet" ] \
  || fail "Le favori devrait être typé « fleet »" "$row"
[ "$(echo "$row" | jq -r '.name')" = "Transports Alpha" ] \
  || fail "Le nom doit venir du serveur, pas de la requête" "$row"
pass "Relu : typé « fleet », nommé par le serveur"

# ⚠️ Un second ajout ne doit pas créer de doublon : l'unicité porte sur le
# couple (type, uuid), et l'écriture est un `upsert`.
capi POST /commercant/transporteurs/favoris \
  "$(jq -n --arg v "$ALPHA_VENDOR" '{partyType:"fleet", fleetbaseDriverUuid:$v}')" >/dev/null
count="$(capi GET /commercant/transporteurs/favoris \
  | jq --arg v "$ALPHA_VENDOR" '[.data[]? | select(.driver_uuid == $v)] | length')"
[ "$count" = "1" ] || fail "Un second ajout a créé un doublon ($count lignes)"
pass "Deux ajouts, une seule ligne — l'unicité tient"

# ── Le retrait ───────────────────────────────────────────────────────────
FAV_ID="$(echo "$row" | jq -r '.id')"
removed="$(capi DELETE "/commercant/transporteurs/favoris/$FAV_ID")"
echo "$removed" | is_error && fail "Retrait refusé" "$(echo "$removed" | jq -c '.')"
gone="$(capi GET /commercant/transporteurs/favoris \
  | jq --arg v "$ALPHA_VENDOR" '[.data[]? | select(.driver_uuid == $v)] | length')"
[ "$gone" = "0" ] || fail "Le favori subsiste après retrait"
pass "Retiré"

echo
echo "════════════════════════════════════════════════════════════════"
pass "Multi-appartenance vérifiée de bout en bout."
echo "   Alpha : active (suspendue puis réactivée)"
echo "   Beta  : declined (quittée, redemandée, refusée)"
echo "   Deux rattachements simultanés, deux attaques repoussées,"
echo "   un refus non contournable, et le lien conservé après départ."
echo "   Et une entreprise mise en favori : recherche typée, ajout,"
echo "   unicité sur le couple (type, uuid), retrait."
