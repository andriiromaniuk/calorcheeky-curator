#!/usr/bin/env bash
# Fetch the currently-published seed pack for a country.
#
# Usage:
#   scripts/fetch-pack.sh UA
#   scripts/fetch-pack.sh UK | jq .payload.ingredients
#
# Outputs the raw server JSON (PackResponse — { version, country,
# published_at, payload }) to stdout. Pipe to jq for filtering.
#
# Exits 0 on 200 (pack found), non-zero on 404 (no pack yet) or any
# auth / network failure. The 404 path is intentional — the curator
# treats "no current pack" as a legitimate state ("publish v1 from
# scratch"), so callers should `if scripts/fetch-pack.sh UA > /tmp/x`
# rather than relying on a non-zero exit.
set -euo pipefail

COUNTRY="${1:?usage: $0 <country-code, e.g. UA|UK>}"
COUNTRY="${COUNTRY^^}"  # uppercase (server validates case-sensitively)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"
[[ -f "$ENV_FILE" ]] || { echo "missing $ENV_FILE — copy .env.example and fill it in" >&2; exit 2; }

# Export every var defined in .env so curl + ${VAR} expansion below
# both see them. `set -a` auto-exports each subsequent assignment.
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

: "${CALORCHEEKY_BASE_URL:?CALORCHEEKY_BASE_URL must be set in .env}"
: "${CALORCHEEKY_ADMIN_USER:?CALORCHEEKY_ADMIN_USER must be set in .env}"
: "${CALORCHEEKY_ADMIN_PASSWORD:?CALORCHEEKY_ADMIN_PASSWORD must be set in .env}"

curl -fsS \
  -u "$CALORCHEEKY_ADMIN_USER:$CALORCHEEKY_ADMIN_PASSWORD" \
  "$CALORCHEEKY_BASE_URL/admin/seed-pack/$COUNTRY"
