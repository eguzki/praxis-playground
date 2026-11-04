#!/usr/bin/env bash
# Generate RSA keypair, JWKS document, and test JWT tokens.
#
# Outputs:
#   jwt/private.pem    - RSA 2048-bit private key
#   jwt/jwks.json      - JWKS document (public key)
#   jwt/tokens/*.jwt   - Test tokens (gold, silver, enterprise, basic, notier)
set -euo pipefail

cd "$(dirname "$0")"

JWT_ISSUER="${JWT_ISSUER:-https://jwt-issuer.praxis.local}"
JWT_AUDIENCE="${JWT_AUDIENCE:-praxis-playground}"
JWT_KID="${JWT_KID:-praxis-playground}"

PRIV_KEY="private.pem"
JWKS_FILE="jwks.json"
TOKENS_DIR="tokens"

# base64url (no padding), reading stdin
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# Convert hex string (stdin) to raw bytes
_hex_to_bin() {
  local hex escaped
  hex="$(cat)"
  escaped="$(printf '%s' "${hex}" | sed 's/../\\x&/g')"
  printf '%b' "${escaped}"
}

# Generate RSA keypair if not present
if [ ! -f "${PRIV_KEY}" ]; then
  echo "Generating RSA keypair..."
  openssl genrsa -out "${PRIV_KEY}" 2048 2>/dev/null
  echo "  Created: ${PRIV_KEY}"
fi

# Generate JWKS from private key
if [ ! -f "${JWKS_FILE}" ] || [ "${PRIV_KEY}" -nt "${JWKS_FILE}" ]; then
  echo "Generating JWKS..."

  # Extract RSA modulus as base64url
  modulus_hex="$(openssl rsa -in "${PRIV_KEY}" -noout -modulus 2>/dev/null | sed 's/^Modulus=//')"
  n="$(printf '%s' "${modulus_hex}" | _hex_to_bin | b64url)"

  cat > "${JWKS_FILE}" <<EOF
{
  "keys": [
    {
      "kty": "RSA",
      "use": "sig",
      "alg": "RS256",
      "kid": "${JWT_KID}",
      "n": "${n}",
      "e": "AQAB"
    }
  ]
}
EOF
  echo "  Created: ${JWKS_FILE}"
fi

# jwt_mint <sub> [tier]
# Prints a signed RS256 JWT
jwt_mint() {
  local sub="$1" tier="${2:-}"
  local header payload signing_input sig iat exp
  iat="$(date +%s)"
  exp="$((iat + 315360000))" # +10 years

  header="$(printf '{"alg":"RS256","typ":"JWT","kid":"%s"}' "${JWT_KID}" | b64url)"
  if [ -n "${tier}" ]; then
    payload="$(printf '{"iss":"%s","sub":"%s","aud":"%s","tier":"%s","iat":%s,"exp":%s}' \
      "${JWT_ISSUER}" "${sub}" "${JWT_AUDIENCE}" "${tier}" "${iat}" "${exp}" | b64url)"
  else
    payload="$(printf '{"iss":"%s","sub":"%s","aud":"%s","iat":%s,"exp":%s}' \
      "${JWT_ISSUER}" "${sub}" "${JWT_AUDIENCE}" "${iat}" "${exp}" | b64url)"
  fi
  signing_input="${header}.${payload}"
  sig="$(printf '%s' "${signing_input}" | openssl dgst -sha256 -sign "${PRIV_KEY}" -binary | b64url)"
  printf '%s.%s' "${signing_input}" "${sig}"
}

# Mint test tokens
echo "Minting test tokens..."
mkdir -p "${TOKENS_DIR}"

jwt_mint "user-gold"       "gold"       > "${TOKENS_DIR}/gold.jwt"
jwt_mint "user-silver"     "silver"     > "${TOKENS_DIR}/silver.jwt"
jwt_mint "user-enterprise" "enterprise" > "${TOKENS_DIR}/enterprise.jwt"
jwt_mint "user-basic"      "basic"      > "${TOKENS_DIR}/basic.jwt"
jwt_mint "user-notier"                  > "${TOKENS_DIR}/notier.jwt"

echo "  Created: ${TOKENS_DIR}/*.jwt"
echo ""
echo "JWT generation complete!"
echo "  JWKS:   jwt/jwks.json"
echo "  Tokens: jwt/tokens/{gold,silver,enterprise,basic,notier}.jwt"
