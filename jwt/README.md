# JWT Test Issuer

Static JWT issuer for acceptance tests using RS256 signing with a local JWKS.

## Overview

This directory contains:
- **`generate.sh`**: Generates RSA keypair, JWKS, and test tokens
- **`jwks.json`**: Public key in JWKS format (generated, served by jwt-issuer service)
- **`private.pem`**: RSA private key (generated, gitignored)
- **`tokens/`**: Test JWT tokens (generated, gitignored)

## Token Claims

All tokens have:
- **`iss`** (issuer): `https://jwt-issuer.praxis.local`
- **`aud`** (audience): `praxis-playground`
- **`sub`** (subject): User identifier (e.g., `user-gold`)
- **`iat`**, **`exp`**: Issued/expiry timestamps (10-year validity)
- **`tier`** (custom): Tier claim for rate limiting (gold/silver/enterprise/basic) — **absent** in `notier.jwt`

## Available Tokens

| Token | Subject | Tier | Purpose |
|-------|---------|------|---------|
| `gold.jwt` | `user-gold` | `gold` | Premium tier (high token budget) |
| `silver.jwt` | `user-silver` | `silver` | Mid tier (moderate budget) |
| `enterprise.jwt` | `user-enterprise` | `enterprise` | Exempt from limits (unlimited) |
| `basic.jwt` | `user-basic` | `basic` | Default tier (catch-all budget) |
| `notier.jwt` | `user-notier` | *(absent)* | Test missing claim handling |

## Generating Tokens

Run from the repository root:

```bash
make jwt-tokens
# Or directly:
./jwt/generate.sh
```

This creates:
- `jwt/private.pem` (2048-bit RSA key)
- `jwt/jwks.json` (public JWKS document)
- `jwt/tokens/*.jwt` (5 test tokens)

## JWKS Endpoint

The `jwt-issuer` service (nginx) serves the JWKS at:
- `http://jwt-issuer/jwks.json`
- `http://jwt-issuer/.well-known/jwks.json`
- `http://localhost:8888/jwks.json` (from host)

Praxis config reference: `http://localhost:8888/jwks.json` (the host gateway
reaches the issuer via the compose port map; the `jwt-issuer` service name only
resolves from inside the compose network).

## Usage in Tests

```bash
# Load a token
TOKEN=$(cat jwt/tokens/gold.jwt)

# Send authenticated request
curl -H "Authorization: Bearer $TOKEN" \
     http://localhost:8080/v1/chat/completions \
     -d '{"model":"mock","messages":[{"role":"user","content":"test"}]}'
```

## Decoding Tokens

```bash
# Decode payload (requires jq)
cat jwt/tokens/gold.jwt | cut -d. -f2 | base64 -d | jq

# Example output:
# {
#   "iss": "https://jwt-issuer.praxis.local",
#   "sub": "user-gold",
#   "aud": "praxis-playground",
#   "tier": "gold",
#   "iat": 1699000000,
#   "exp": 2014360000
# }
```

## Regenerating

To regenerate (e.g., after changing issuer/audience):

```bash
rm -rf jwt/private.pem jwt/jwks.json jwt/tokens/
./jwt/generate.sh
```

Restart `jwt-issuer` service to pick up the new JWKS:

```bash
docker compose restart jwt-issuer
```
