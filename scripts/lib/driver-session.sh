#!/usr/bin/env bash
# Obtention d'une session transporteur, partagée par les scripts de test.
#
# Extrait ici après une divergence réelle : la même séquence était recopiée
# dans test-driver-auth.sh et test-transporteur-module.sh, et le passage à
# l'inscription sur invitation (revue C2) n'a été répercuté que sur le premier.
# Le second a continué d'envoyer `fleetbaseDriverUuid`, champ que le DTO
# n'accepte plus, et échouait à l'étape d'authentification — avant d'avoir
# testé quoi que ce soit du module qu'il est censé valider.
#
# Pour qui : les scripts qui ont besoin d'une session transporteur pour tester
# AUTRE CHOSE. test-driver-auth.sh garde volontairement sa séquence en clair —
# c'est le parcours d'authentification lui-même qu'il valide, étape par étape,
# et le faire passer par ce raccourci reviendrait à ne plus tester ce qu'il
# annonce.
#
# À sourcer :  . "$(dirname "$0")/lib/driver-session.sh"
#
# Entrées (variables d'environnement) :
#   BFF_URL   — adresse du BFF
#   PASSWORD  — mot de passe des comptes de test
#   DRIVER_EMAIL_HINT — email souhaité pour un nouveau compte transporteur
#                       (facultatif). Volontairement distinct de `EMAIL`,
#                       qui ne veut pas dire la même chose d'un script à l'autre.
#
# Sorties :
#   DRIVER_TOKEN         — JWT transporteur
#   DRIVER_EMAIL         — email du compte utilisé
#   DRIVER_SESSION_NOTE  — comment la session a été obtenue, à afficher
#   DRIVER_SESSION_ERROR — renseigné en cas d'échec

_driver_login() { # email password -> token sur stdout
  curl -sS -X POST "$BFF_URL/auth/transporteur/login" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg e "$1" --arg p "$2" '{email:$e, password:$p}')" \
    | jq -r '.token // empty'
}

# Accorde le rôle « prestataire plateforme » au compte opérateur jetable.
#
# Écrit en base plutôt que par une route : `isPlatform` n'en a aucune, et c'est
# voulu — un compte flotte qui pourrait se déclarer plateforme ferait retenir à
# ses conducteurs une rémunération qui ne leur revient pas. C'est un geste
# d'admin, tenu ici par le script, exactement comme l'activation du fournisseur.
#
# **Refuse si un prestataire plateforme existe déjà.** L'invariant « exactement
# un » fonde la résolution du facilitateur pour toutes les courses du pool ; le
# casser pour faire passer un test rendrait le test vert et le produit faux.
_promote_operator_to_platform() { # email -> 0 si promu
  PLATFORM_PROMOTION_ERROR=""
  local existing

  existing=$(docker exec echango_bff_postgres psql -U bff_user -d echango_bff -tAc \
    "SELECT email FROM \"FleetAccount\" WHERE \"isPlatform\" = true LIMIT 1;" \
    2>/dev/null | tr -d '[:space:]' || true)

  if [ -n "$existing" ]; then
    PLATFORM_PROMOTION_ERROR=$(cat <<EOF
un prestataire plateforme existe déjà ($existing) et le script ne le remplace pas.
   Fournissez ses identifiants pour que les tests s'en servent :
     ECHANGO_PLATFORM_EMAIL='$existing' ECHANGO_PLATFORM_PASSWORD='<mdp>' \$0 …
EOF
)
    return 1
  fi

  docker exec echango_bff_postgres psql -U bff_user -d echango_bff -tAc \
    "UPDATE \"FleetAccount\" SET \"isPlatform\" = true WHERE email = '$1';" \
    >/dev/null 2>&1 || {
      PLATFORM_PROMOTION_ERROR="écriture impossible (conteneur echango_bff_postgres joignable ?)"
      return 1
    }
}

_existing_driver_email() { # driver_uuid -> email sur stdout, vide si aucun
  docker exec echango_bff_postgres psql -U bff_user -d echango_bff -tAc \
    "SELECT email FROM \"DriverAccount\" WHERE \"fleetbaseDriverUuid\"='$1';" \
    2>/dev/null | tr -d '[:space:]' || true
}

# Jeton d'un autre persona, utile pour vérifier le cloisonnement des rôles.
#
# Préférable à un jeton forgé localement : forger suppose de connaître le
# JWT_SECRET du serveur, et le lire dans un .env ne garantit pas que c'est
# celui du conteneur en cours d'exécution. Quand les deux diffèrent, le jeton
# est rejeté à la vérification de signature (401) et le contrôle de rôle n'est
# jamais atteint — le test passe alors sans rien démontrer. Un jeton émis par
# le serveur lui-même est toujours valide, donc toujours concluant.
obtain_operator_token() { # -> renseigne OPERATOR_TOKEN
  OPERATOR_TOKEN=$(_operator_token)
  [ -n "$OPERATOR_TOKEN" ]
}

# Compte opérateur (persona `fleet`), seul habilité à émettre une invitation.
#
# ── Trois étapes depuis le Lot 0, et non plus deux ──────────────────────────
#
# L'inscription d'une entreprise de transport ne délivre plus de jeton : elle
# enregistre une **demande**, et répond `403 fleet_pending`. Le `Vendor` naît
# `inactive`, et `loginFleet` refuse tant qu'un admin ne l'a pas validé.
#
# Le script tient donc le rôle de cet admin, avec la clé de service — comme
# `test-parcours-argent.sh` le fait déjà pour le commerçant. **Le garde n'est
# pas contourné**, il est franchi par le geste qui est prévu pour le franchir ;
# `register-merchant.sh` reste le script qui joue ce parcours à la main et
# prouve que le garde existe.
_operator_token() { # -> token sur stdout
  # Prestataire plateforme réel, si l'utilisateur l'a provisionné
  # (`npm run prisma:seed`) et en fournit les identifiants. C'est le chemin le
  # plus fidèle : c'est bien Echango qui invite les conducteurs du pool.
  if [ -n "${ECHANGO_PLATFORM_EMAIL:-}" ] && [ -n "${ECHANGO_PLATFORM_PASSWORD:-}" ]; then
    curl -sS -X POST "$BFF_URL/auth/flotte/login" \
      -H 'Content-Type: application/json' \
      -d "$(jq -n --arg e "$ECHANGO_PLATFORM_EMAIL" --arg p "$ECHANGO_PLATFORM_PASSWORD" \
         '{email:$e, password:$p}')" \
      | jq -r '.token // empty'
    return 0
  fi

  # ── Réutiliser le prestataire plateforme déjà posé ────────────────────────
  #
  # Le premier passage promeut un compte jetable en prestataire plateforme.
  # Les suivants trouvaient donc un prestataire existant et **refusaient**, ce
  # qui rendait le script utilisable une seule fois par base — un contrôle de
  # référence qu'on ne peut rejouer ne contrôle rien.
  #
  # Un compte d'opérateur de test a été créé avec `$PASSWORD` : on tente donc de
  # s'y connecter. Si ça marche, c'est le nôtre et on s'en sert ; si ça échoue,
  # c'est un vrai prestataire Echango, et le message actionnable reste dû.
  local existing_platform
  existing_platform=$(docker exec echango_bff_postgres psql -U bff_user -d echango_bff -tAc \
    "SELECT email FROM \"FleetAccount\" WHERE \"isPlatform\" = true LIMIT 1;" \
    2>/dev/null | tr -d '[:space:]' || true)

  if [ -n "$existing_platform" ]; then
    local reused
    reused=$(curl -sS -X POST "$BFF_URL/auth/flotte/login" \
      -H 'Content-Type: application/json' \
      -d "$(jq -n --arg e "$existing_platform" --arg p "$PASSWORD" '{email:$e, password:$p}')" \
      | jq -r '.token // empty')

    if [ -n "$reused" ]; then
      echo "$reused"
      return 0
    fi

    echo "prestataire plateforme existant ($existing_platform) non connectable avec le mot de passe de test.
   Fournissez ses identifiants :
     ECHANGO_PLATFORM_EMAIL='$existing_platform' ECHANGO_PLATFORM_PASSWORD='<mdp>' \$0 …" >&2
    return 0
  fi

  local email="operateur-test-$RANDOM@echango.local"

  # La bibliothèque Fleetbase n'est pas toujours déjà chargée : les scripts qui
  # ne veulent qu'une session transporteur ne la sourcent pas.
  if ! declare -F fb_activate_vendor_by_email >/dev/null 2>&1; then
    # shellcheck source=fleetbase.sh
    . "$(dirname "${BASH_SOURCE[0]}")/fleetbase.sh"
  fi

  curl -sS -o /dev/null -X POST "$BFF_URL/auth/flotte/register" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg e "$email" --arg p "$PASSWORD" \
       '{email:$e, password:$p, businessName:"Flotte de test"}')" || true

  # Un échec d'activation n'est pas silencieux : sans lui la connexion suivante
  # échouera, et sans ce message on mettrait le refus sur le compte du garde.
  if ! fb_activate_vendor_by_email "$email"; then
    echo "opérateur non activé : ${FLEETBASE_ERROR:-cause inconnue}" >&2
    return 0
  fi

  # ── Et il faut que cet opérateur ait le DROIT d'inviter ce conducteur ──────
  #
  # Depuis le Lot 0, une entreprise ne peut inviter qu'un conducteur qui lui est
  # rattaché — ou, si elle est le prestataire **plateforme**, un conducteur que
  # personne n'a rattaché, c'est-à-dire un conducteur du pool. Les conducteurs
  # de test en font partie.
  #
  # Le script tient donc ici le second rôle d'admin, comme il tenait le premier
  # en activant le fournisseur. Il ne le prend que si **aucun** prestataire
  # plateforme n'existe : promouvoir un compte jetable alors qu'Echango est déjà
  # posé casserait l'invariant « exactement un », et c'est un invariant dont
  # dépend la résolution du facilitateur.
  if ! _promote_operator_to_platform "$email"; then
    echo "opérateur non promu plateforme : ${PLATFORM_PROMOTION_ERROR:-cause inconnue}" >&2
    return 0
  fi

  curl -sS -X POST "$BFF_URL/auth/flotte/login" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg e "$email" --arg p "$PASSWORD" '{email:$e, password:$p}')" \
    | jq -r '.token // empty'
}

# Renvoie 0 et renseigne DRIVER_TOKEN, ou renvoie 1 et renseigne
# DRIVER_SESSION_ERROR.
obtain_driver_token() { # driver_uuid
  local driver_uuid="$1"
  DRIVER_TOKEN=""; DRIVER_EMAIL=""; DRIVER_SESSION_NOTE=""; DRIVER_SESSION_ERROR=""

  # 1. Un compte existe déjà pour ce Driver — cas normal dès la 2e exécution.
  #    Son email ne se devine pas : il faut le relire dans la base du BFF.
  local existing
  existing=$(_existing_driver_email "$driver_uuid")

  if [ -n "$existing" ]; then
    DRIVER_EMAIL="$existing"
    DRIVER_TOKEN=$(_driver_login "$existing" "$PASSWORD")

    if [ -z "$DRIVER_TOKEN" ]; then
      DRIVER_SESSION_ERROR=$(cat <<EOF
Compte existant trouvé ($existing) mais le mot de passe ne correspond pas.
   Le fournir :   PASSWORD='<le bon>' \$0 $driver_uuid
   Ou repartir de zéro pour ce driver :
     docker exec echango_bff_postgres psql -U bff_user -d echango_bff \\
       -c "DELETE FROM \\"DriverAccount\\" WHERE \\"fleetbaseDriverUuid\\"='$driver_uuid';"
EOF
)
      return 1
    fi

    DRIVER_SESSION_NOTE="compte existant réutilisé ($existing)"
    return 0
  fi

  # 2. Aucun compte : en créer un par le parcours réel, invitation comprise.
  #    Un transporteur ne peut pas s'inscrire seul (revue C2) — l'invitation
  #    est émise par un opérateur et fige le Driver visé côté serveur.
  local operator_token
  operator_token=$(_operator_token)
  if [ -z "$operator_token" ]; then
    DRIVER_SESSION_ERROR="impossible d'obtenir un compte opérateur (flotte) pour émettre l'invitation"
    return 1
  fi

  local invite invite_token
  invite=$(curl -sS -X POST "$BFF_URL/auth/transporteur/invitation" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $operator_token" \
    -d "$(jq -n --arg u "$driver_uuid" '{fleetbaseDriverUuid:$u}')")
  invite_token=$(echo "$invite" | jq -r '.invitationToken // empty')

  if [ -z "$invite_token" ]; then
    DRIVER_SESSION_ERROR="émission d'invitation échouée : $invite"
    return 1
  fi

  # ⚠️ **Jamais la variable ambiante `EMAIL`**, dont le sens dépend de
  # l'appelant : elle désigne le conducteur dans les scripts transporteur, et
  # le COMMERÇANT dans `test-parcours-argent.sh`. Le compte transporteur y
  # naissait donc avec l'email du commerçant.
  #
  # Ce n'est pas cosmétique. `POST /auth/login` résout le profil depuis
  # l'email : deux comptes de personas différents partageant email ET mot de
  # passe font répondre `requiresRoleSelection` sans jeton. La connexion
  # commerçant échouait alors — précisément dans le mode de réutilisation que
  # le script documente (`EMAIL= PASSWORD= réutilise un commerçant existant`).
  DRIVER_EMAIL="${DRIVER_EMAIL_HINT:-transporteur-test-$RANDOM@echango.local}"
  local register
  register=$(curl -sS -X POST "$BFF_URL/auth/transporteur/register" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg t "$invite_token" --arg e "$DRIVER_EMAIL" --arg p "$PASSWORD" \
       '{invitationToken:$t, email:$e, password:$p, firstName:"Test", lastName:"Transporteur"}')")
  DRIVER_TOKEN=$(echo "$register" | jq -r '.token // empty')

  if [ -z "$DRIVER_TOKEN" ]; then
    DRIVER_SESSION_ERROR="inscription du transporteur échouée : $register"
    return 1
  fi

  DRIVER_SESSION_NOTE="compte créé via invitation ($DRIVER_EMAIL)"
  return 0
}
