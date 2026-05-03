#!/usr/bin/env bash
# Wire-contract drift check.
#
# Compares the field shape of a freshly-fetched seed pack against
# the canonical shape documented in this repo's CLAUDE.md
# ("Wire contract reference" section). If the actual server
# response is missing a REQUIRED field (= the runbook is more
# generous than reality, generated proposals will fail to publish)
# OR carries fields the runbook doesn't know about (= the server
# has a new column we should be populating), the curator's mental
# model is stale.
#
# Usage:
#   scripts/check-wire.sh UA
#
# Exits 0 when the payload shape matches; non-zero (with a clear
# message) when there's drift. Safe to call as the first step of
# any curation run — adds ~half a second over a plain fetch and
# short-circuits the entire workflow when the schemas differ.
#
# What it does NOT check:
#   - Value types (e.g. kcal as number not string). Pydantic-style
#     deep validation would catch more but adds dependency weight.
#     Type drift in the SeedPack.kt @Serializable would surface as
#     a publish-time 500 anyway.
#   - Recipe entries (v1 ignores them).
#   - Optional keys missing from row 0 specifically — kotlinx-
#     serialization with default values OMITS keys when the value
#     equals the default (e.g. `brand: String? = null` writes no
#     `brand` field on the wire). The check tolerates that by
#     classifying optional keys as "may be absent".
set -euo pipefail

COUNTRY="${1:?usage: $0 <country-code, e.g. UA|UK>}"
COUNTRY="${COUNTRY^^}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# What the runbook says SHOULD be in the payload. Keep this in
# lockstep with the "Wire contract reference" section of CLAUDE.md
# in this repo. When the server's SeedPack.kt shape changes, both
# this list AND the CLAUDE.md table need to be updated together.
PAYLOAD_REQUIRED=("country" "ingredients" "recipes")
PAYLOAD_OPTIONAL=()  # none currently — every payload field is required

INGREDIENT_REQUIRED=(
  "name"
  "kcal_per_100g"
  "fat_per_100g"
  "protein_per_100g"
  "carbs_per_100g"
  "category"
  "external_id"
)
INGREDIENT_OPTIONAL=(
  "emoji"   # Kotlin default "🍽️" — kotlinx-serialization omits when default
  "brand"   # nullable, kotlinx-serialization omits when null
)

# Helpers ───────────────────────────────────────────────────────────────

# `contains_in <needle> <haystack-array...>` returns 0 if needle is
# in the array, 1 otherwise. Used to classify each actual key as
# required / optional / unknown.
contains_in() {
  local needle="$1"; shift
  local element
  for element in "$@"; do
    [[ "$element" == "$needle" ]] && return 0
  done
  return 1
}

# Compare a sample of actual keys against required + optional sets,
# emitting drift messages for anything missing-required or
# unknown. `kind` is "payload" / "ingredient" — used in the error
# message only.
check_keys() {
  local kind="$1"
  local actual_keys="$2"
  shift 2
  # Args after that: required... -- optional...
  local mode="required" required=() optional=()
  for arg in "$@"; do
    if [[ "$arg" == "--" ]]; then mode="optional"; continue; fi
    if [[ "$mode" == "required" ]]; then required+=("$arg"); else optional+=("$arg"); fi
  done

  local drift=0

  # Every required key must be in the actual set.
  local req
  for req in "${required[@]}"; do
    if ! grep -qx -- "$req" <<<"$actual_keys"; then
      echo "ERROR: $kind missing required key '$req' (server's SeedPack.kt may have removed it)" >&2
      drift=1
    fi
  done

  # Every actual key must be in (required ∪ optional).
  local actual
  while IFS= read -r actual; do
    [[ -z "$actual" ]] && continue
    if ! contains_in "$actual" "${required[@]}" "${optional[@]}"; then
      echo "ERROR: $kind has unknown key '$actual' (server's SeedPack.kt added a column — update CLAUDE.md + this script)" >&2
      drift=1
    fi
  done <<<"$actual_keys"

  return $drift
}

# Main ─────────────────────────────────────────────────────────────────

# Pull the latest pack. If the server has nothing yet (HTTP 404),
# we can't compare shapes — bail "ok" since there's nothing to
# drift against.
PACK_JSON=$(bash "$SCRIPT_DIR/fetch-pack.sh" "$COUNTRY" 2>/dev/null || true)
if [[ -z "$PACK_JSON" ]]; then
  echo "[check-wire] no published pack for $COUNTRY yet — nothing to check"
  exit 0
fi

# `tr -d '\r'` strips CRs that jq emits between lines on Windows;
# without it, every key looks like it has trailing whitespace and
# all comparisons fail.
ACTUAL_PAYLOAD_KEYS=$(jq -r '.payload | keys[] | .' <<<"$PACK_JSON" | tr -d '\r')

drift=0
if ! check_keys "payload" "$ACTUAL_PAYLOAD_KEYS" \
       "${PAYLOAD_REQUIRED[@]}" -- "${PAYLOAD_OPTIONAL[@]}"; then
  drift=1
fi

INGREDIENT_COUNT=$(jq '.payload.ingredients | length' <<<"$PACK_JSON")
if [[ "$INGREDIENT_COUNT" -gt 0 ]]; then
  ACTUAL_INGREDIENT_KEYS=$(jq -r '.payload.ingredients[0] | keys[] | .' <<<"$PACK_JSON" | tr -d '\r')
  if ! check_keys "ingredient" "$ACTUAL_INGREDIENT_KEYS" \
         "${INGREDIENT_REQUIRED[@]}" -- "${INGREDIENT_OPTIONAL[@]}"; then
    drift=1
  fi
fi

if [[ "$drift" -eq 1 ]]; then
  echo "" >&2
  echo "       The server's SeedPack.kt has drifted vs this repo's" >&2
  echo "       CLAUDE.md. UPDATE THE RUNBOOK BEFORE PROCEEDING — a" >&2
  echo "       proposal generated against the stale shape would" >&2
  echo "       4xx / 5xx at publish time." >&2
  exit 2
fi

echo "[check-wire] payload shape matches CLAUDE.md"
