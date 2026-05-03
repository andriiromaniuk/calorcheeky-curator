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

# ── UTF-8 hygiene ──────────────────────────────────────────────
# Force a UTF-8 locale before jq runs. Without it, jq on Windows
# git-bash (and some bare-bones Docker shells) loses non-ASCII
# bytes and emits `?` for every Cyrillic / accented character.
# C.UTF-8 is universally available; en_US.UTF-8 is the fallback.
# Verified incident: v7 of UA pack was published from a non-UTF-8
# session and stored as `????????` in Postgres, breaking the
# entire seasonal-update prompt on the Ukrainian client.
if locale -a 2>/dev/null | grep -qiE '^C\.UTF-?8$'; then
  export LC_ALL=C.UTF-8 LANG=C.UTF-8
elif locale -a 2>/dev/null | grep -qiE '^en_US\.UTF-?8$'; then
  export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
fi

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

# Wrap with `{ "payload": <file> }` and POST. `jq -anc --slurpfile`
# guarantees a valid one-shot JSON — beats a printf concat that
# could escape weirdly on Cyrillic input.
#
# `-a` (--ascii-output) emits non-ASCII as `\uXXXX` JSON escapes
# instead of raw UTF-8 bytes. JSON spec says these are equivalent
# (every parser unescapes them back to the same characters), but
# 7-bit-ASCII bytes survive any pipe / shell / curl encoding
# pipeline that might otherwise mangle them. Belt-AND-suspenders
# alongside the LC_ALL=C.UTF-8 export at the top of the file —
# either alone is sufficient, but together they're proof against
# environments we don't control.
WRAPPED=$(jq -anc --slurpfile p "$PAYLOAD_FILE" '{payload: $p[0]}')

curl -fsS \
  -u "$CALORCHEEKY_ADMIN_USER:$CALORCHEEKY_ADMIN_PASSWORD" \
  -H "Content-Type: application/json" \
  -X POST \
  --data "$WRAPPED" \
  "$CALORCHEEKY_BASE_URL/admin/seed-pack/$COUNTRY"

# Trailing newline so the {country, version} response line + the
# verify message don't run together on stdout.
echo

# ── Post-publish verification ──────────────────────────────────
# A successful HTTP 201 doesn't prove the data on the server
# matches what we tried to publish. v7 of the UA pack returned
# 201 + the right version number but every Cyrillic character in
# Postgres came out as '?'. verify-publish.sh fetches the
# server-side pack back, asserts no '?' chars in any name /
# emoji, and asserts the ingredient count matches the proposal
# file. Failures here mean re-publish.
echo "[publish] verifying server stored the data correctly..." >&2
bash "$SCRIPT_DIR/verify-publish.sh" "$COUNTRY" "$PAYLOAD_FILE"
