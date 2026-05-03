#!/usr/bin/env bash
# List published seed-pack versions for a country.
#
# Usage:
#   scripts/pack-history.sh UA
#   scripts/pack-history.sh UA | jq -r '.items[] | "\(.version)  \(.published_at)"'
#
# Outputs `{ country, items: [ { version, published_at } ] }` —
# items are server-sorted version-descending.
set -euo pipefail

COUNTRY="${1:?usage: $0 <country-code, e.g. UA|UK>}"
COUNTRY="${COUNTRY^^}"

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

curl -fsS \
  -u "$CALORCHEEKY_ADMIN_USER:$CALORCHEEKY_ADMIN_PASSWORD" \
  "$CALORCHEEKY_BASE_URL/admin/seed-pack/$COUNTRY/history"
