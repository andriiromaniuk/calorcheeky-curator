#!/usr/bin/env bash
# Post-publish verification — fetches the latest server-side seed
# pack for a country and asserts the data matches what we
# THOUGHT we published. Catches the kinds of silent corruption
# that a successful HTTP 201 doesn't rule out.
#
# Usage:
#   scripts/verify-publish.sh UA proposals/UA-2026-05/pack.json
#   scripts/verify-publish.sh UA                        # count check skipped
#
# What it checks:
#
# 1. No '?' substitution chars in any ingredient name or emoji.
#    (The Unicode replacement char "?" is what jq emits when
#    UTF-8 is mangled by a non-UTF-8 shell locale. v7 of the UA
#    pack stored "????????" instead of "Полуниця"; the publish
#    POST returned 201 so the operator thought it worked. This
#    check would have failed loud at publish-time.)
# 2. Server's ingredient count matches the proposal file's count
#    (if a proposal file is provided). Catches a different shape
#    of bug — proposal had N rows but only M made it to the wire,
#    e.g. truncation by some intermediate processor.
#
# Exits 0 on clean, non-zero with a clear stderr message on
# anything wrong. Pairs with publish-pack.sh which calls this
# automatically after a successful POST.
#
# Independent of check-wire.sh — that one validates the field-
# shape contract (which keys are present); this one validates
# the data values (no encoding corruption, count matches).
set -euo pipefail

COUNTRY="${1:?usage: $0 <country-code, e.g. UA|UK> [proposal-file]}"
COUNTRY="${COUNTRY^^}"
PROPOSAL_FILE="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# UTF-8 hygiene mirroring publish-pack.sh's hardening — jq
# pipelines need a UTF-8 locale to keep non-ASCII intact even
# when SCANNING for '?' chars. Without this, jq might convert
# real Cyrillic into '?' inside this script, false-positiving
# data that's actually fine on the server.
if locale -a 2>/dev/null | grep -qiE '^C\.UTF-?8$'; then
  export LC_ALL=C.UTF-8 LANG=C.UTF-8
elif locale -a 2>/dev/null | grep -qiE '^en_US\.UTF-?8$'; then
  export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
fi

# Pull the latest pack via the existing fetch script (it handles
# .env loading + admin auth). Use --raw flag if available, but
# the bare script already returns the raw JSON.
PACK=$(bash "$SCRIPT_DIR/fetch-pack.sh" "$COUNTRY" 2>/dev/null || true)

if [[ -z "$PACK" ]]; then
  echo "ERROR: fetch-pack returned empty — does the server have a pack for $COUNTRY?" >&2
  exit 2
fi

VERSION=$(jq -r '.version' <<<"$PACK")
SERVER_COUNT=$(jq '.payload.ingredients | length' <<<"$PACK")

# ── Check 1: substitution chars in name / emoji ────────────────
NAME_HITS=$(jq -r '
  .payload.ingredients[] |
  select(.name | contains("?")) |
  "  name=\"\(.name)\" external_id=\"\(.external_id // "<none>")\""
' <<<"$PACK")

EMOJI_HITS=$(jq -r '
  .payload.ingredients[] |
  select(.emoji | contains("?")) |
  "  emoji=\"\(.emoji)\" name=\"\(.name)\""
' <<<"$PACK")

if [[ -n "$NAME_HITS" || -n "$EMOJI_HITS" ]]; then
  echo "ERROR: $COUNTRY pack v$VERSION has '?' substitution chars in published rows." >&2
  echo "       Almost certainly an encoding pipeline ate the UTF-8 between" >&2
  echo "       proposal-file and Postgres. Re-publish with publish-pack.sh's" >&2
  echo "       LC_ALL=C.UTF-8 + jq -a hardening, then re-run this script." >&2
  echo "" >&2
  if [[ -n "$NAME_HITS" ]]; then
    echo "       Name-field hits:" >&2
    echo "$NAME_HITS" >&2
  fi
  if [[ -n "$EMOJI_HITS" ]]; then
    echo "       Emoji-field hits:" >&2
    echo "$EMOJI_HITS" >&2
  fi
  exit 3
fi

# ── Check 2: count matches proposal ────────────────────────────
if [[ -n "$PROPOSAL_FILE" ]]; then
  if [[ -f "$PROPOSAL_FILE" ]]; then
    EXPECTED_COUNT=$(jq '.ingredients | length' "$PROPOSAL_FILE")
    if [[ "$SERVER_COUNT" != "$EXPECTED_COUNT" ]]; then
      echo "ERROR: server has $SERVER_COUNT ingredients in v$VERSION but" >&2
      echo "       $PROPOSAL_FILE has $EXPECTED_COUNT. Truncation somewhere?" >&2
      exit 3
    fi
  else
    echo "[verify-publish] WARNING: proposal '$PROPOSAL_FILE' not found, skipping count check" >&2
  fi
fi

echo "[verify-publish] $COUNTRY v$VERSION OK — $SERVER_COUNT ingredients, no '?' chars"
