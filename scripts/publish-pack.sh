#!/usr/bin/env bash
# Publish a new seed-pack version for a country.
#
# Usage:
#   scripts/publish-pack.sh UA proposals/UA-2026-05.json
#
# The payload file MUST be a `SeedPackPayload` shape — i.e. just
# `{ "country": "...", "ingredients": [...], "recipes": [] }` —
# WITHOUT the outer `{ "payload": ... }` wrapper. The script wraps
# it for you using jq, so the file stays diff-friendly across runs.
#
# On success: prints the server's response, e.g.
#   { "country": "UA", "version": 7 }
#
# Exits non-zero on 4xx / 5xx — the server's `--fail-with-body` curl
# flag dumps the error body before exiting so you see the reason.
set -euo pipefail

COUNTRY="${1:?usage: $0 <country-code, e.g. UA|UK> <path/to/pack.json>}"
PAYLOAD_FILE="${2:?usage: $0 <country-code> <path/to/pack.json>}"
COUNTRY="${COUNTRY^^}"

[[ -f "$PAYLOAD_FILE" ]] || { echo "no such file: $PAYLOAD_FILE" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"
[[ -f "$ENV_FILE" ]] || { echo "missing $ENV_FILE" >&2; exit 2; }

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

: "${CALORCHEEKY_BASE_URL:?CALORCHEEKY_BASE_URL must be set in .env}"
: "${CALORCHEEKY_ADMIN_USER:?CALORCHEEKY_ADMIN_USER must be set in .env}"
: "${CALORCHEEKY_ADMIN_PASSWORD:?CALORCHEEKY_ADMIN_PASSWORD must be set in .env}"

# Sanity-check the payload file is valid JSON before sending. Saves
# the operator from a server 500 when a missing comma slips through.
if ! jq -e . "$PAYLOAD_FILE" >/dev/null 2>&1; then
  echo "ERROR: $PAYLOAD_FILE is not valid JSON. Run: jq . '$PAYLOAD_FILE' to see the parse error." >&2
  exit 3
fi

# Sanity-check the file has the expected SeedPackPayload shape — no
# `payload` key at the top level (means the operator wrapped it
# already by mistake), `country` matches the URL country.
TOP_LEVEL_PAYLOAD=$(jq -r 'has("payload")' "$PAYLOAD_FILE")
if [[ "$TOP_LEVEL_PAYLOAD" == "true" ]]; then
  echo "ERROR: $PAYLOAD_FILE looks pre-wrapped (has top-level 'payload' key). The script wraps it for you — pass the raw payload, not the request body." >&2
  exit 3
fi
FILE_COUNTRY=$(jq -r '.country // empty' "$PAYLOAD_FILE")
if [[ -n "$FILE_COUNTRY" && "$FILE_COUNTRY" != "$COUNTRY" ]]; then
  echo "WARNING: payload.country='$FILE_COUNTRY' but URL country='$COUNTRY' — server records the URL, not the body. Continuing." >&2
fi

# Wrap with `{ "payload": <file> }` and POST. `jq -nc --slurpfile`
# guarantees a valid one-shot JSON — beats a printf concat that
# could escape weirdly on Cyrillic input.
WRAPPED=$(jq -nc --slurpfile p "$PAYLOAD_FILE" '{payload: $p[0]}')

curl -fsS \
  -u "$CALORCHEEKY_ADMIN_USER:$CALORCHEEKY_ADMIN_PASSWORD" \
  -H "Content-Type: application/json" \
  -X POST \
  --data "$WRAPPED" \
  "$CALORCHEEKY_BASE_URL/admin/seed-pack/$COUNTRY"
