#!/usr/bin/env bash
# Pose le décor des parcours joués **dans l'application**, pour les TROIS
# personas, puis rend les identifiants à passer à `flutter drive`.
#
#   ./scripts/provision-app-parcours.sh [conducteur]
#
# ── Pourquoi un script à part, et pourquoi en shell ─────────────────────────
#
# Le test d'intégration Flutter pilote l'application ; il ne peut donc faire que
# ce qu'un utilisateur peut faire à l'écran. Or trois choses lui manquent avant
# de pouvoir commencer, et **aucune n'est un geste d'utilisateur** :
#
#   1. **L'activation des comptes.** Depuis le Lot 4, inscrire un commerçant ou
#      une entreprise enregistre une *demande* : `403 merchant_pending` /
#      `fleet_pending`, aucun jeton, aucune connexion tant qu'un administrateur
#      n'a pas passé le `Vendor` à `active`. Le garde est volontaire et reste
#      entier — c'est le rôle d'admin qui est tenu ici, pas le garde qui est
#      contourné. (Même parti pris que `test-parcours-argent.sh`.)
#
#   2. **Deux adresses au carnet.** Le formulaire de course exige quatre
#      coordonnées, désignées soit par la carte, soit par le carnet. Piloter une
#      carte glissante depuis un test est fragile et ne prouve rien du métier ;
#      choisir deux entrées d'un carnet est déterministe.
#
#   3. **Des courses à prendre.** Le transporteur et l'entreprise doivent
#      trouver quelque chose dans « Courses libres ». Les poser ici plutôt que
#      de faire dépendre un parcours du précédent : deux tests qui se passent
#      un état échouent ensemble, et le second accuse le premier.
#
# Ce script ne teste rien : il **provisionne**. Ce qui est vérifié l'est par
# `integration_test/`, dans l'application.
#
# ── ⚠️ Idempotent, et c'est une contrainte de plafond, pas de confort ───────
#
# Les emails sont **stables**, pas aléatoires : le throttle d'inscription est de
# dix par heure et la suite `run-all-scenarios.sh` en consomme déjà huit. Une
# version à `$RANDOM` rendait ce script inutilisable deux fois de suite. Sur un
# compte déjà présent, l'inscription répond le même `*_pending` et l'activation
# ne coûte rien — on rejoue sans rien consommer.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/fleetbase.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-driver.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/driver-session.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/free-driver.sh"

BFF_URL="${BFF_URL:-http://localhost:3001}"
PASSWORD="${PASSWORD:-motdepasse123}"
DRIVER_HINT="${1:-}"

MERCHANT_EMAIL="${MERCHANT_EMAIL:-app-parcours-commercant@echango.local}"
FLEET_EMAIL="${FLEET_EMAIL:-app-parcours-entreprise@echango.local}"
BUSINESS="${BUSINESS:-Boulangerie du Parcours}"
FLEET_NAME="${FLEET_NAME:-Transports du Parcours}"

PICKUP_NAME="${PICKUP_NAME:-Dépôt Alger-Centre}"
DROPOFF_NAME="${DROPOFF_NAME:-Client Hydra}"

# Combien de courses libres laisser en attente. Une pour le transporteur, une
# pour l'entreprise, plus une de marge — un parcours qui échoue en consomme
# parfois une sans la rendre.
#
# Quatre : les parcours en consomment une chacun — argent, écart, échec,
# transporteur — et l'écartement en masque une cinquième pour ce conducteur.
SPARE_ORDERS="${SPARE_ORDERS:-6}"

command -v jq >/dev/null 2>&1 || { echo "❌ jq requis." >&2; exit 1; }

pass() { echo "✅ $1"; }
info() { echo "   $1"; }
step() { echo; echo "── $1 ──"; }
fail() { echo "❌ $1" >&2; [ -n "${2:-}" ] && echo "   Réponse : $2" >&2; exit 1; }

# Reconnaît une erreur du BFF sur stdin.
#
# Par `statusCode`, jamais par `code` : `code` existe aussi sur des réponses de
# succès (un objet activité en porte un), donc le tester lirait un succès comme
# un échec. `statusCode` est le seul champ que le filtre d'exception pose sur
# **toutes** les erreurs, y compris celles sans code métier.
is_error() { jq -e 'type == "object" and ((.statusCode | type) == "number")' >/dev/null 2>&1; }

# Inscrit un persona et le fait valider — le refus EST le résultat attendu.
#
# ⚠️ La route est `/auth/merchant/register`, **pas** `/auth/register/merchant`.
# Écrite à l'envers ici le 02/08/2026 : le 404 qui en est sorti n'a pas de champ
# `code`, et la première version ne regardait que `code` — elle a donc annoncé
# « ✅ Inscription enregistrée » sur une route inexistante, et n'a échoué que
# trois étapes plus loin, en accusant l'activation. D'où la lecture du **code
# HTTP**, qui ne peut pas manquer.
register_and_activate() { # route email corps_json libellé code_attendu
  local route="$1" email="$2" body="$3" label="$4" want="$5"
  local out status payload code

  # ⚠️ **Ne pas dépenser une inscription pour apprendre ce qu'une connexion
  # dit gratuitement (02/08/2026).** L'inscription est plafonnée à dix par
  # heure ; ce script en consommait deux **à chaque exécution**, même sur des
  # comptes déjà provisionnés dont il savait qu'ils existaient. Six passages
  # suffisaient donc à épuiser le quota, et le parcours d'inscription — le seul
  # qui en a réellement besoin — se voyait refusé.
  #
  # La connexion, elle, n'est bornée qu'à la minute. Un compte qui rend un
  # jeton est provisionné ET validé : il n'y a rien à refaire.
  if [ -n "$(login_token "$email" 2>/dev/null)" ]; then
    pass "$label déjà provisionné et actif — $email (aucune inscription consommée)"
    return 0
  fi

  out="$(curl -sS -w '\n%{http_code}' -X POST "$BFF_URL$route" \
    -H 'Content-Type: application/json' -d "$body")"
  status="$(tail -n1 <<<"$out")"
  payload="$(sed '$d' <<<"$out")"
  code="$(jq -r '.code // empty' <<<"$payload" 2>/dev/null || true)"

  if [ "$status" = "200" ] || [ "$status" = "201" ]; then
    fail "$label : un accès a été délivré SANS validation — le garde du Lot 4 ne tient plus" "$payload"
  fi

  # ⚠️ **Trois réponses sont acceptables, et la troisième n'a été découverte
  # qu'au deuxième passage (02/08/2026).**
  #
  #   403 `*_pending`      → compte neuf, demande enregistrée : le cas nominal
  #   409 `auth.email_taken` → compte DÉJÀ provisionné par un passage précédent
  #
  # La première version n'acceptait que la première, parce qu'elle avait été
  # éprouvée sur un compte encore en attente. Une fois le `Vendor` activé, le
  # rejeu ne rend plus `*_pending` du tout — il rend `email_taken`, et le script
  # échouait donc **exactement dans le mode de réutilisation qu'il existe pour
  # servir**. C'est le même piège que partout ici : un chemin éprouvé une seule
  # fois n'a été éprouvé que dans un seul état.
  case "$status:$code" in
    "403:$want")
      info "$label : demande enregistrée, accès en attente" ;;
    409:auth.email_taken|409:email_taken)
      info "$label : compte déjà provisionné, repris tel quel" ;;
    *)
      fail "$label : refus inattendu (HTTP $status, code « ${code:-aucun} »)" "$payload" ;;
  esac

  # Activation rejouée dans les deux cas : elle est idempotente (le `PUT` relit
  # le statut) et coûte une requête, là où deviner l'état en coûterait autant
  # pour un résultat moins sûr.
  fb_activate_vendor_by_email "$email" \
    || fail "$label : activation impossible — ${FLEETBASE_ERROR:-raison inconnue}"
  pass "$label validé — $email"
}

# Jeton, avec attente du plafond si besoin.
#
# ⚠️ **Cinq connexions par minute, et ce script en fait trois** — plus celles
# des parcours qui suivent. Enchaîner décor et tests franchit la limite, et le
# refus ressemble alors à un mot de passe faux. On attend la fenêtre une fois,
# puis on abandonne en **nommant** la cause : un script qui dit « connexion
# refusée » sur un 429 envoie chercher au mauvais endroit.
login_token() { # email -> jeton sur stdout, vide et LOGIN_ERROR si échec
  local email="$1" out status body
  LOGIN_ERROR=""
  for attempt in 1 2; do
    out="$(curl -sS -w '\n%{http_code}' -X POST "$BFF_URL/auth/login" \
      -H 'Content-Type: application/json' \
      -d "$(jq -n --arg e "$email" --arg p "$PASSWORD" '{email:$e, password:$p}')")"
    status="$(tail -n1 <<<"$out")"
    body="$(sed '$d' <<<"$out")"

    local token
    token="$(jq -r '.token // empty' <<<"$body")"
    if [ -n "$token" ]; then printf '%s' "$token"; return 0; fi

    if [ "$status" = "429" ] && [ "$attempt" = "1" ]; then
      info "plafond de connexions atteint — attente de la fenêtre (65 s)"
      sleep 65
      continue
    fi
    LOGIN_ERROR="HTTP $status — $(jq -r '.message // .code // "sans message"' <<<"$body")"
    return 1
  done
}

# ── 1. Le commerçant ────────────────────────────────────────────────────────

step "Commerçant"
register_and_activate /auth/merchant/register "$MERCHANT_EMAIL" \
  "$(jq -n --arg e "$MERCHANT_EMAIL" --arg p "$PASSWORD" --arg b "$BUSINESS" \
     '{email:$e, password:$p, businessName:$b, phone:"0550000000"}')" \
  "Commerçant" merchant_pending

# ⚠️ Le champ s'appelle `token`. Ni `accessToken`, ni `access_token` — les deux
# ont été essayés d'abord, et un jeton vide se serait manifesté trois requêtes
# plus loin par un 401 sur le carnet d'adresses.
MERCHANT_TOKEN="$(login_token "$MERCHANT_EMAIL")"
[ -n "$MERCHANT_TOKEN" ] || fail "Connexion commerçant refusée : ${LOGIN_ERROR:-raison inconnue}"
pass "Jeton commerçant obtenu"

mapi() { # méthode chemin [corps]
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $MERCHANT_TOKEN" -d "$b"
  else
    curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $MERCHANT_TOKEN"
  fi
}

# ── 2. Le carnet d'adresses ─────────────────────────────────────────────────
#
# Deux adresses **réelles et distantes de quelques kilomètres** : un enlèvement
# et une livraison au même point passeraient la validation tout en ne prouvant
# rien du calcul de distance ni de l'affichage d'itinéraire.

step "Carnet d'adresses"

book="$(mapi GET /commercant/adresses)"

# ⚠️ **Comparaison insensible à la casse — sinon le carnet enfle à chaque
# passage (constaté le 02/08/2026).**
#
# Fleetbase rend les noms de lieux transformés : « Dépôt Alger-Centre » revient
# en « DéPôT ALGER-CENTRE ». Une égalité stricte ne matchait donc jamais, le
# script recréait les deux adresses à chaque exécution, et il y en avait **trois
# copies** avant qu'on s'en aperçoive. Le décor se dégradait avec son propre
# usage — le même défaut que les quatorze « Transports Alpha » du 01/08.
#
# `ascii_downcase` suffit : il abaisse les lettres ASCII et laisse les accents
# tels quels des deux côtés, donc « DéPôT » et « Dépôt » se rejoignent.
have() {
  jq -e --arg n "$1" \
    '[(.data // .)[]? | .name | ascii_downcase] | index($n | ascii_downcase) != null' \
    >/dev/null 2>&1 <<<"$book"
}

# Les doublons déjà accumulés sont retirés : le formulaire propose une liste, et
# trois entrées de même nom rendent le choix du test ambigu — un test ambigu
# échoue un jour sur deux sans qu'on sache pourquoi.
count_named() { # nom -> nombre d'entrées portant ce nom
  jq -r --arg n "$1" \
    '[(.data // .)[]? | select((.name | ascii_downcase) == ($n | ascii_downcase))] | length' \
    <<<"$book"
}

# Repart d'un carnet propre : supprime TOUTES les entrées de ce nom.
#
# ⚠️ **Supprimer puis recréer, plutôt que corriger en place** — la mise à jour
# exige le corps complet (`contactPhone` est obligatoire au DTO), donc un PUT
# partiel pour ajouter la wilaya est refusé. Un seul chemin vaut mieux que deux
# qui doivent rester d'accord.
#
# ⚠️ **Par `public_id`, jamais par `id`.** Le carnet rend les trois identifiants
# — `id: 517`, `uuid`, `public_id: place_…` —, et la route n'accepte pas le
# numérique. La première version prenait `.id // .uuid`, donc le numérique :
# **chaque suppression répondait 404** et les doublons s'accumulaient. Le
# contrôle par relecture le signalait bien ; c'est mon filtre d'affichage qui me
# cachait la ligne. Un contrôle qui parle dans le vide ne vaut pas mieux qu'un
# contrôle absent.
prune_named() { # nom
  local ids before after
  before="$(count_named "$1")"
  [ "$before" -gt 0 ] || return 0

  ids="$(jq -r --arg n "$1" \
    '(.data // .)[]? | select((.name | ascii_downcase) == ($n | ascii_downcase))
     | (.public_id // .uuid // empty)' <<<"$book")"
  while read -r id; do
    [ -n "$id" ] || continue
    mapi DELETE "/commercant/adresses/$id" >/dev/null || true
  done <<<"$ids"

  # Relu, jamais déduit du succès de `curl` : il réussit aussi sur un 404.
  book="$(mapi GET /commercant/adresses)"
  after="$(count_named "$1")"
  if [ "$after" -eq 0 ]; then
    [ "$before" -gt 0 ] && info "« $1 » : $before entrée(s) retirée(s)"
  else
    fail "« $1 » : $after entrée(s) subsistent après suppression — le carnet
   resterait ambigu, et sans wilaya la course créée depuis l'application
   n'aurait rien à filtrer."
  fi
}

add_address() { # nom adresse lat lon contact
  local body out
  body="$(jq -n --arg n "$1" --arg a "$2" --argjson lat "$3" --argjson lon "$4" \
    --arg c "$5" \
    '{name:$n, address:$a, latitude:$lat, longitude:$lon,
      contactName:$c, contactPhone:"0551020304",
      city:"Alger", province:"Alger", country:"DZ"}')"
  out="$(mapi POST /commercant/adresses "$body")"
  is_error <<<"$out" && fail "Adresse « $1 » refusée" "$out"
  pass "Adresse « $1 »"
}

# Deux entrées de même nom rendraient le choix du test ambigu, et un test ambigu
# échoue un jour sur deux sans qu'on sache pourquoi.
# ⚠️ **On repart d'un carnet neuf à chaque exécution, et ce n'est pas du
# gaspillage (02/08/2026).** La version précédente sautait la création quand
# l'entrée existait — donc les adresses posées **avant** l'ajout de la wilaya
# gardaient `province: null` pour toujours, et une course créée depuis
# l'application n'emportait aucune wilaya. Mesuré : la course de 15h02, créée
# par le parcours, portait `ABSENTE` là où celles du décor portaient `ALGER`.
#
# Le lot avait donc l'air fait — le chemin API le prouvait — alors que le chemin
# de l'application ne transportait rien. C'est exactement le défaut que ce
# dépôt nomme le plus souvent : *le serveur savait, l'app ignorait*.
prune_named "$PICKUP_NAME"
prune_named "$DROPOFF_NAME"
add_address "$PICKUP_NAME"  "12 rue Didouche Mourad, Alger-Centre" 36.7719 3.0589 "Karim"
add_address "$DROPOFF_NAME" "8 chemin Mackley, Hydra"              36.7434 3.0290 "Nadia"

# Relu : la wilaya doit être là, sinon le parcours créera une course sans elle
# et le filtre n'aura rien à filtrer — sans que rien ne le signale.
book="$(mapi GET /commercant/adresses)"
missing="$(jq -r --arg a "$PICKUP_NAME" --arg b "$DROPOFF_NAME" \
  '[(.data // [])[] | select((.name | ascii_downcase) == ($a | ascii_downcase)
                          or (.name | ascii_downcase) == ($b | ascii_downcase))
    | select(.province == null or .province == "")] | length' <<<"$book")"
[ "$missing" = "0" ] \
  || fail "$missing adresse(s) du carnet sans wilaya — une course créée depuis
   l'application n'en porterait aucune."
pass "Carnet : deux adresses, wilaya comprise"

# ── 3. L'entreprise de transport (le facilitateur) ──────────────────────────

step "Entreprise de transport"
register_and_activate /auth/flotte/register "$FLEET_EMAIL" \
  "$(jq -n --arg e "$FLEET_EMAIL" --arg p "$PASSWORD" --arg b "$FLEET_NAME" \
     '{email:$e, password:$p, businessName:$b, firstName:"Test", lastName:"Entreprise",
       phone:"0551111111"}')" \
  "Entreprise" fleet_pending

FLEET_TOKEN="$(login_token "$FLEET_EMAIL")"
[ -n "$FLEET_TOKEN" ] || fail "Connexion entreprise refusée : ${LOGIN_ERROR:-raison inconnue}"
pass "Jeton entreprise obtenu"

# ── 4. Le conducteur ────────────────────────────────────────────────────────
#
# Résolu et provisionné par la bibliothèque partagée : l'invitation est émise
# par un opérateur, un transporteur ne s'inscrit pas seul (revue C2). La même
# discipline que les scénarios s'applique — plusieurs conducteurs, il faut dire
# lequel.

step "Conducteur"
resolve_driver "$DRIVER_HINT" || fail "${RESOLVE_DRIVER_ERROR:-Conducteur introuvable}"
obtain_driver_token "$DRIVER_UUID" || fail "${DRIVER_SESSION_ERROR:-Session conducteur impossible}"
pass "Conducteur : ${DRIVER_LABEL:-$DRIVER_UUID}"
[ -n "${DRIVER_SESSION_NOTE:-}" ] && info "$DRIVER_SESSION_NOTE"
[ -n "$DRIVER_EMAIL" ] || fail "Aucun email de conducteur — impossible de se connecter dans l'app"

# ⚠️ **L'application se connecte par la route UNIFIÉE, pas par celle du
# transporteur — et les deux ne répondent pas pareil (constaté le 02/08/2026).**
#
# `POST /auth/login` résout le profil depuis l'email. Si le même email porte
# **deux** comptes de personas différents, il répond `requiresRoleSelection`
# **sans jeton**, et l'écran de connexion propose un choix au lieu de naviguer.
# Le parcours transporteur échouait alors en accusant l'accueil de ne jamais
# venir, alors que la connexion attendait un clic.
#
# Le cas n'est pas théorique : les scénarios d'argent réutilisent la variable
# `EMAIL` pour le **commerçant**, et un conducteur créé dans leur foulée peut
# hériter du même email. `driver-session.sh` documente déjà ce piège.
#
# On le vérifie donc ici, où il se lit, plutôt que dans l'application, où il se
# déguise en écran qui ne s'ouvre pas.
unified_raw="$(curl -sS -w '\n%{http_code}' -X POST "$BFF_URL/auth/login" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$DRIVER_EMAIL" --arg p "$PASSWORD" '{email:$e, password:$p}')")"
unified_status="$(tail -n1 <<<"$unified_raw")"
unified="$(sed '$d' <<<"$unified_raw")"

# ⚠️ **Le code HTTP d'abord, l'interprétation ensuite — sinon on accuse le mauvais
# coupable (constaté sur ce script même, 02/08/2026).** La première version
# concluait « cet email porte plusieurs comptes » dès qu'aucun jeton ne
# revenait ; elle a donc affirmé ça sur un `429 ThrottlerException`, c'est-à-dire
# sur un compte parfaitement sain qu'on venait d'interroger cinq fois. Un
# diagnostic sûr de lui sur une donnée qu'il n'a pas regardée est pire que pas
# de diagnostic.
if [ "$unified_status" = "429" ]; then
  fail "Plafond de connexions atteint (5/minute) — attendre une minute et rejouer.
   Ni le compte ni le mot de passe ne sont en cause."
fi
if [ -z "$(jq -r '.token // empty' <<<"$unified")" ]; then
  roles="$(jq -r '(.roles // []) | join(", ")' <<<"$unified")"
  if [ -n "$roles" ]; then
    fail "Le conducteur « $DRIVER_EMAIL » ne peut pas se connecter dans l'application.
   La connexion unifiée exige un choix de profil : $roles.
   Cet email porte plusieurs comptes ; l'app ne peut pas trancher à sa place.
   Choisir un autre conducteur :  $0 <nom|email|ID>" "$(jq -c '.' <<<"$unified")"
  fi
  fail "Connexion conducteur refusée (HTTP $unified_status)" "$(jq -c '.' <<<"$unified")"
fi
pass "Connexion unifiée vérifiée — l'app pourra ouvrir ce profil sans ambiguïté"

# Appel authentifié côté conducteur — attendu par `lib/free-driver.sh`, qui le
# suppose défini par l'appelant comme le font les sept scénarios.
dapi() { # méthode chemin [corps]
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $DRIVER_TOKEN" -d "$b"
  else
    curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $DRIVER_TOKEN"
  fi
}

# Le parcours transporteur **prend** une course : un conducteur déjà occupé se
# verrait refuser (« driver.unavailable ») et le test accuserait l'écran.
# `UNBLOCK=1` libère, comme pour les scénarios.
require_free_driver

# ⚠️ **Le soldage du registre a disparu le 03/08/2026 avec le registre
# lui-même** (`docs/registre_caisse_precis.md`). Il existait parce que les
# parcours d'argent déclaraient un encaissement à chaque exécution sans que
# rien ne le solde : l'encours montait d'environ 2800 par passage et, au
# septième, le plafond de dette refusait toute course encaissée.
#
# La déclaration à la porte s'écrit désormais **sur la commande**, donc chaque
# parcours écrit sur la sienne : rien ne s'accumule, il n'y a plus rien à
# remettre à zéro. `RESET_LEDGER` n'a plus d'effet et n'est plus lu.

# ── 5. Des courses libres à prendre ─────────────────────────────────────────
#
# Publiées ici, et non laissées à la charge du parcours commerçant : deux tests
# qui se passent un état échouent ensemble, et le second accuse le premier.

step "Courses libres"

published=0

# ⚠️ **Compté du point de vue du CONDUCTEUR, pas du commerçant (02/08/2026).**
#
# Les deux vues diffèrent, et la différence est structurelle : **écarter une
# opportunité la masque définitivement pour ce transporteur**. Le commerçant
# continue donc de voir une course libre que le conducteur ne verra plus jamais.
#
# Compter côté commerçant faisait croire le décor pourvu alors que la liste du
# conducteur se vidait à chaque exécution — le parcours d'écartement en retire
# une, les parcours d'argent et d'échec en consomment trois autres. La suite se
# dégradait avec son propre usage, exactement comme les quatorze « Transports
# Alpha » du 01/08.
#
# On interroge donc la liste que le conducteur reçoit vraiment.
free_now() {
  dapi GET '/transporteur/commandes?type=adhoc' \
    | jq '[(.orders // [])[]?] | length' 2>/dev/null || echo 0
}
already="$(free_now)"
info "déjà disponibles : $already"

while [ "$((already + published))" -lt "$SPARE_ORDERS" ]; do
  # ⚠️ `draft: true`, puis publication explicite — le parcours réel du
  # commerçant. Avec `draft: false` la commande est diffusée **dès la
  # création**, et le `publier` qui suit est refusé (`order.already_published`,
  # constaté). Passer par le brouillon garde les deux gestes distincts, comme à
  # l'écran.
  body="$(jq -n '{
    draft: true,
    pickupLocationName: "Dépôt du Parcours", pickupLatitude: 36.7719, pickupLongitude: 3.0589,
    pickupContactName: "Commerce", pickupContactPhone: "0551020304",
    dropoffLocationName: "Client du Parcours", dropoffLatitude: 36.7434, dropoffLongitude: 3.0290,
    dropoffContactName: "Destinataire", dropoffContactPhone: "0551020305",
    pickupCity: "Alger", pickupProvince: "Alger",
    dropoffCity: "Alger", dropoffProvince: "Alger",
    price: 650, podMethod: "aucune" }')"
  out="$(mapi POST /commercant/commandes "$body")"
  is_error <<<"$out" && fail "Création d'une course libre refusée" "$out"
  oid="$(jq -r '.id // empty' <<<"$out")"
  [ -n "$oid" ] || fail "Course créée sans identifiant" "$out"

  pub="$(mapi POST "/commercant/commandes/$oid/publier")"
  is_error <<<"$pub" && fail "Publication refusée" "$pub"
  published=$((published + 1))
  pass "Course libre publiée ($published)"
done

[ "$published" = "0" ] && info "Assez de courses libres, aucune créée"

# ── 5 bis. Une course ENCAISSÉE, pour le parcours d'argent ──────────────────
#
# Distincte des précédentes par son nom de destinataire : le parcours d'argent
# doit prendre **celle-là** et pas une autre, sinon il déclare un encaissement
# sur une course qui n'en attend aucun et le tiroir ne s'ouvre jamais.
#
# ⚠️ `podMethod: aucune` — délibéré. Exiger une photo ferait dépendre le
# parcours de la capture d'image de l'émulateur, c'est-à-dire d'un composant
# natif qui n'a rien à voir avec l'argent. La preuve photo se teste à part.

step "Course encaissée"

COD_DROPOFF="${COD_DROPOFF:-Client Encaissement}"
COD_AMOUNT="${COD_AMOUNT:-1950}"

# ⚠️ **Un prix distinctif, et c'est le seul repère utilisable.** La carte d'une
# opportunité n'affiche ni le nom du destinataire — masqué tant que la course
# n'est pas prise, une course libre se juge sans désigner une porte — ni le
# montant à encaisser. Elle affiche le **prix**. C'est donc lui qui permet au
# parcours d'argent de reconnaître SA course parmi les autres ; 777 ne peut se
# confondre avec les 650 des courses ordinaires.
COD_FEE="${COD_FEE:-777}"

# La seconde course encaissée, celle de l'écart à la porte. Un prix distinct de
# la première, faute de quoi les deux parcours se disputeraient la même course
# et le second échouerait selon l'ordre d'exécution.
COD_GAP_FEE="${COD_GAP_FEE:-888}"

cod_free() {
  mapi GET '/commercant/commandes?page=1&limit=50' \
    | jq --arg n "$COD_DROPOFF" '[(.orders // [])[]
         | select(.status == "dispatched")
         | select((.driver_assigned_uuid // .driver_uuid // .driver) == null)
         | select((.dropoff_name // .dropoff // "" | tostring | ascii_downcase)
                  | contains($n | ascii_downcase))] | length'
}

# Publie une course encaissée reconnaissable à son prix, si elle manque.
ensure_cod_order() { # prix libellé
  local fee="$1" what="$2"
  # ⚠️ Compté dans la liste du **conducteur**, comme les courses ordinaires :
  # une course prise par l'entreprise reste « sans conducteur » vue du
  # commerçant, et serait donc comptée comme libre à tort.
  local n
  n="$(dapi GET '/transporteur/commandes?type=adhoc' \
    | jq --argjson f "$fee" '[(.orders // [])[]?
         | select((.meta.price // .price) == $f)] | length' 2>/dev/null || echo 0)"
  if [ "${n:-0}" -gt 0 ]; then
    info "course « $what » (prix $fee) déjà disponible"
    return 0
  fi

  local body out oid pub
  body="$(jq -n --arg d "$COD_DROPOFF" --argjson cod "$COD_AMOUNT" --argjson fee "$fee" '{
    draft: true,
    pickupLocationName: "Dépôt du Parcours", pickupLatitude: 36.7719, pickupLongitude: 3.0589,
    pickupContactName: "Commerce", pickupContactPhone: "0551020304",
    dropoffLocationName: $d, dropoffLatitude: 36.7434, dropoffLongitude: 3.0290,
    dropoffContactName: "Destinataire", dropoffContactPhone: "0551020305",
    pickupCity: "Alger", pickupProvince: "Alger",
    dropoffCity: "Alger", dropoffProvince: "Alger",
    price: $fee, codAmount: $cod, codIncludesDelivery: false,
    podMethod: "aucune" }')"
  out="$(mapi POST /commercant/commandes "$body")"
  is_error <<<"$out" && fail "Création de la course « $what » refusée" "$out"
  oid="$(jq -r '.id // empty' <<<"$out")"
  [ -n "$oid" ] || fail "Course « $what » créée sans identifiant" "$out"
  pub="$(mapi POST "/commercant/commandes/$oid/publier")"
  is_error <<<"$pub" && fail "Publication de la course « $what » refusée" "$pub"
  pass "Course « $what » publiée — prix $fee, $COD_AMOUNT à encaisser"
}

# Deux courses encaissées, distinguées par leur prix : l'une sera encaissée au
# montant exact, l'autre servira à l'écart à la porte. Les mélanger ferait
# dépendre chaque parcours de l'ordre d'exécution de l'autre.
ensure_cod_order "$COD_FEE" "encaissement exact"
ensure_cod_order "$COD_GAP_FEE" "écart à la porte"

# ⚠️ **Le contrat imprimé doit refléter le décor, pas une valeur canned
# (règle 10).** `ensure_cod_order` réutilise une course reconnue à son PRIX
# sans jamais toucher son `cod_amount` : une course héritée d'un run précédent
# porte donc son propre montant. Constaté le 04/08/2026 — la course à 777
# portait cod=2727 pendant que le script annonçait TEST_COD_AMOUNT=1950, et le
# test échouait sur `screenHas(1950)`, un montant que l'écran n'affiche nulle
# part. On relit donc le cod RÉEL de la course « encaissement exact » (celle à
# $COD_FEE) et c'est LUI qu'on annonce au test. Une course fraîchement créée
# porte $COD_AMOUNT, donc la relecture est un no-op dans ce cas — le filet ne
# sert que la course réutilisée.
real_cod="$(dapi GET '/transporteur/commandes?type=adhoc' \
  | jq -r --argjson f "$COD_FEE" 'first((.orders // [])[]?
       | select((.meta.price // .price) == $f))
       | (.meta.cod_amount // .cod_amount // empty)' 2>/dev/null || true)"
if [ -n "$real_cod" ] && [ "$real_cod" != "null" ]; then
  if [ "$real_cod" != "$COD_AMOUNT" ]; then
    info "cod réel de la course à $COD_FEE = $real_cod (défaut $COD_AMOUNT écarté — décor réutilisé)"
  fi
  COD_AMOUNT="$real_cod"
else
  fail "cod_amount introuvable pour la course à $COD_FEE" \
    "la course « encaissement exact » n'est pas dans le seau adhoc — décor incohérent"
fi

# ── Course CONFIÉE au conducteur (favori sollicité) ─────────────────────────
#
# ⚠️ **Le seul décor d'où part le geste « rendre ».** Refuser une opportunité
# DIFFUSÉE l'écarte pour ce conducteur (`releasedToPool:false`, « écartée ») ;
# RENDRE une course qu'on lui a CONFIÉE la renvoie au réseau
# (`releasedToPool:true`, « rendue au réseau ») et prévient le commerçant. Même
# bouton, même tiroir — seul le MESSAGE change, et c'est cette distinction que
# l'écran doit porter. Elle exige une course assignée à CE conducteur, en
# attente (`dispatched`), non démarrée : elle apparaît alors dans « En cours »
# avec le bouton « Rendre ». Prix distinctif pour la reconnaître ; le nom du
# destinataire, lui, est visible (course confiée = projection pleine).
step "Course confiée au conducteur"

CONFIDED_FEE="${CONFIDED_FEE:-4444}"

# Le conducteur doit être favori du commerçant pour qu'on puisse lui cibler une
# course. Idempotent : déjà favori répond sans erreur.
mapi POST /commercant/transporteurs/favoris \
  "$(jq -n --arg u "$DRIVER_UUID" '{fleetbaseDriverUuid:$u, partyType:"driver"}')" >/dev/null 2>&1 || true

# Réutilise une course déjà confiée à ce prix ; en crée une sinon. ⚠️ Une
# course RENDUE lors d'un run précédent est repartie au pool (driver null,
# adhoc=true) : elle ne compte donc plus comme confiée, et une nouvelle est
# créée — le test retrouve toujours une course à rendre.
confided="$(dapi GET '/transporteur/commandes' \
  | jq -r --argjson f "$CONFIDED_FEE" 'first((.active // [])[]?
       | select((.meta.price // .price) == $f)
       | select((.driver_assigned_uuid // .driver_uuid) != null))
       | (.public_id // .id // empty)' 2>/dev/null || true)"
if [ -n "$confided" ] && [ "$confided" != "null" ]; then
  info "course confiée (prix $CONFIDED_FEE) déjà disponible"
else
  body="$(jq -n --arg t "$DRIVER_UUID" --argjson fee "$CONFIDED_FEE" '{
    pickupLocationName: "Dépôt Confié", pickupLatitude: 36.7538, pickupLongitude: 3.0588,
    pickupContactName: "Commerce", pickupContactPhone: "0551020304",
    dropoffLocationName: "Client Confié", dropoffLatitude: 36.7500, dropoffLongitude: 3.0600,
    dropoffContactName: "Destinataire", dropoffContactPhone: "0551020305",
    pickupCity: "Alger", pickupProvince: "Alger",
    dropoffCity: "Alger", dropoffProvince: "Alger",
    items: [{description: "colis", quantity: 1}],
    price: $fee, podMethod: "aucune", targetFavouriteUuid: $t }')"
  out="$(mapi POST /commercant/commandes "$body")"
  is_error <<<"$out" && fail "Création de la course confiée refusée" "$out"
  [ -n "$(jq -r '.fleetbaseOrderId // empty' <<<"$out")" ] \
    || fail "Course confiée créée sans identifiant Fleetbase" "$out"
  pass "Course confiée au conducteur — prix $CONFIDED_FEE"
fi

# ── Entreprise : un conducteur de flotte + « Mes courses » vide ─────────────
#
# ⚠️ Deux manques pour le parcours « l'entreprise réclame puis affecte » :
#   1. **Personne à désigner.** L'entreprise doit avoir au moins un conducteur
#      dans SA flotte, sinon le tiroir d'affectation est vide (`fleet.drivers.
#      empty`) et l'affectation échoue.
#   2. **« Mes courses » encombré.** Les courses réclamées aux runs précédents y
#      restent — Fleetbase les garde, ANNULÉES COMPRISES : les annuler ne les
#      retire pas de la liste (`/flotte/commandes` les sert quand même). Le test
#      ne saurait alors plus laquelle il vient de réclamer. On les SUPPRIME par
#      l'API interne pour repartir d'un onglet vide, où la course réclamée est
#      seule.
step "Entreprise : conducteur de flotte + « Mes courses » vide"

fapi() { # méthode chemin [corps] — appel authentifié côté ENTREPRISE
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $FLEET_TOKEN" -d "$b"
  else
    curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $FLEET_TOKEN"
  fi
}

FLEET_DRIVER_NAME="${FLEET_DRIVER_NAME:-Conducteur Flotte Parcours}"
FLEET_DRIVER_EMAIL="${FLEET_DRIVER_EMAIL:-flotte-driver-parcours@echango.local}"

# Un conducteur DANS la flotte, reconnaissable à son nom. Idempotent : ajouté
# une seule fois, réutilisé ensuite.
if fapi GET /flotte/drivers \
     | jq -e --arg n "$FLEET_DRIVER_NAME" '[(.data//[])[]|select(.name==$n)]|length>0' >/dev/null 2>&1; then
  info "conducteur de flotte « $FLEET_DRIVER_NAME » déjà rattaché"
else
  fapi POST /flotte/drivers \
    "$(jq -n --arg n "$FLEET_DRIVER_NAME" --arg e "$FLEET_DRIVER_EMAIL" \
       '{name:$n, email:$e, phone:"0551060606"}')" >/dev/null 2>&1 || true
  pass "conducteur ajouté à la flotte — $FLEET_DRIVER_NAME"
fi

# Vider « Mes courses » : SUPPRIMER (pas annuler — une annulée reste affichée)
# les courses de l'entreprise héritées des runs précédents.
cleaned=0
for u in $(fapi GET '/flotte/commandes?limit=100' | jq -r '(.data//[])[].uuid'); do
  fb_api DELETE "/int/v1/orders/$u" >/dev/null 2>&1 && cleaned=$((cleaned+1)) || true
done
info "« Mes courses » de l'entreprise vidé ($cleaned course(s) supprimée(s))"

# ── 6. Ce qu'il faut à `flutter drive` ──────────────────────────────────────

step "Prêt"
info "Le décor est posé pour les trois personas. La commande à lancer côté Windows :"
echo
cat <<CMD
  cd echango_delivery
  flutter drive \\
    --driver=test_driver/integration_test.dart \\
    --target=integration_test/parcours_trois_personas_test.dart \\
    -d <émulateur> \\
    --dart-define=TEST_MERCHANT_EMAIL=$MERCHANT_EMAIL \\
    --dart-define=TEST_FLEET_EMAIL=$FLEET_EMAIL \\
    --dart-define=TEST_DRIVER_EMAIL=$DRIVER_EMAIL \\
    --dart-define=TEST_PASSWORD=$PASSWORD \\
    --dart-define=TEST_PICKUP_NAME="$PICKUP_NAME" \\
    --dart-define=TEST_DROPOFF_NAME="$DROPOFF_NAME" \\
    --dart-define=TEST_COD_AMOUNT=$COD_AMOUNT \\
    --dart-define=TEST_COD_FEE=$COD_FEE \\
    --dart-define=TEST_COD_GAP_FEE=$COD_GAP_FEE \\
    --dart-define=TEST_CONFIDED_FEE=$CONFIDED_FEE \\
    --dart-define=TEST_FLEET_DRIVER_NAME="$FLEET_DRIVER_NAME"
CMD
echo
info "L'application vise déjà http://10.0.2.2:3001 (ApiConfig.bffBaseUrl),"
info "l'alias de l'hôte vu depuis un émulateur Android. Sur un autre support,"
info "ajouter --dart-define=BFF_BASE_URL=…"
