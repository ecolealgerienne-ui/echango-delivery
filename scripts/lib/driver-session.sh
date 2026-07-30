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
#   EMAIL     — email souhaité pour un nouveau compte (facultatif)
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
_operator_token() { # -> token sur stdout
  local email="operateur-test-$RANDOM@echango.local" token
  token=$(curl -sS -X POST "$BFF_URL/auth/flotte/register" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg e "$email" --arg p "$PASSWORD" \
       '{email:$e, password:$p, businessName:"Flotte de test"}')" \
    | jq -r '.token // empty')

  if [ -z "$token" ]; then
    token=$(curl -sS -X POST "$BFF_URL/auth/flotte/login" \
      -H 'Content-Type: application/json' \
      -d "$(jq -n --arg e "$email" --arg p "$PASSWORD" '{email:$e, password:$p}')" \
      | jq -r '.token // empty')
  fi
  echo "$token"
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

  DRIVER_EMAIL="${EMAIL:-transporteur-test-$RANDOM@echango.local}"
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
