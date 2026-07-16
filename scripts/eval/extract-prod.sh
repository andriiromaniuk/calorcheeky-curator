#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
# Extract production-pinned values from the calorcheeky app's
# AnthropicNutritionApi.kt into eval-readable mirrors so the eval
# ALWAYS tests against current production behaviour. Run
# automatically by run-eval.sh.
#
# Source repo: $CALORCHEEKY_DIR (default M:/Projects/Calorcheeky) —
# same cross-repo coupling pattern as check-wire.sh vs SeedPack.kt.
#
# Mirrors generated under prompts/:
#   - meal-system.txt        ← `basePrompt`
#   - ingredient-system.txt  ← `ingredientSystemPrompt`
#   - recipe-system.txt      ← `recipeSystemPrompt`
#   - advise-system.txt      ← `adviseRecipeIdeasSystemPrompt`
#   - translate-system.txt   ← `translateSystemPrompt`
#   - variant-explainer.txt  ← `INGREDIENT_VARIANT_EXPLAINER`
#   - *-uk-clause.txt        ← the per-surface `"uk" ->` clauses
#   - advise-units-clause.txt← metric branch of `adviseFridgeRecipeUnitsClause`
#   - max-tokens.json        ← per-surface max_tokens (incl. vision)
#   - models.json            ← MODEL + VISION_MODEL constants
#
# Also VERIFIES the hand-mirrored tool schemas in schemas/ against
# the Kotlin `buildJsonObject` literals (property-KEY sets must
# match) — the schemas can't be auto-extracted, and a stale mirror
# silently grades the wrong artifact (the pre-renewal mirrors were
# missing low_confidence / request_text / the echo-label trio /
# variants). Exits 3 on drift; fix the mirror, then re-run.
#
# Why scrape the .kt rather than hand-mirror the prompts: any drift
# between production and the eval would silently grade the wrong
# artifact. "It is possible that in future we will forget to update
# it and will test with old ai prompts."
#
# Usage: ./extract-prod.sh
# ─────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALORCHEEKY_DIR="${CALORCHEEKY_DIR:-M:/Projects/Calorcheeky}"
SOURCE_KT="$CALORCHEEKY_DIR/composeApp/src/commonMain/kotlin/com/romaniukandrii/calorcheeky/data/api/AnthropicNutritionApi.kt"
OUT_DIR="$SCRIPT_DIR/prompts"
SCHEMAS_DIR="$SCRIPT_DIR/schemas"

if [[ ! -f "$SOURCE_KT" ]]; then
    echo "ERROR: AnthropicNutritionApi.kt not found at:" >&2
    echo "  $SOURCE_KT" >&2
    echo "Set CALORCHEEKY_DIR to the calorcheeky app checkout." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

# `trimIndent()`-equivalent: strip the smallest common leading
# whitespace from every non-blank line, so the mirror is
# byte-identical to what production passes to the API.
trim_indent() {
    awk '
        {
            lines[NR] = $0
            if ($0 ~ /[^[:space:]]/) {
                match($0, /[^[:space:]]/)
                indent = RSTART - 1
                if (!have_min || indent < min) { min = indent; have_min = 1 }
            }
        }
        END {
            for (i = 1; i <= NR; i++) {
                line = lines[i]
                if (line ~ /[^[:space:]]/) print substr(line, min + 1)
                else                       print ""
            }
        }
    '
}

# extract_prompt <kotlin_val_name> <output_basename>
# Captures lines between `val <name> = """` and the closing
# `""".trimIndent()` (exclusive of both).
extract_prompt() {
    local val_name="$1"
    local out_base="$2"
    local out_file="$OUT_DIR/$out_base.txt"

    local raw
    raw="$(awk -v name="$val_name" '
        $0 ~ "(private|internal) val " name " = \"\"\"" { capture=1; next }
        capture && /""".trimIndent\(\)/                   { capture=0 }
        capture                                            { print }
    ' "$SOURCE_KT")"

    if [[ -z "$raw" ]]; then
        echo "  ERROR: no body extracted for '$val_name' — check the regex / source" >&2
        exit 1
    fi

    echo "$raw" | trim_indent > "$out_file"
    echo "  $out_base.txt ($(wc -c < "$out_file" | tr -d ' ') bytes)"
}

echo "Extracting production AI prompts → $OUT_DIR"
extract_prompt "basePrompt"                   "meal-system"
extract_prompt "ingredientSystemPrompt"       "ingredient-system"
extract_prompt "recipeSystemPrompt"           "recipe-system"
extract_prompt "adviseRecipeIdeasSystemPrompt" "advise-system"
extract_prompt "translateSystemPrompt"        "translate-system"
extract_prompt "INGREDIENT_VARIANT_EXPLAINER" "variant-explainer"

# ── Per-surface UK locale clauses ──────────────────────────────────
# meal / ingredient / recipe clauses are triple-quoted bodies inside a
# `when (targetLang)` arm; capture between `"uk"  -> """` and the
# closing `""".trimIndent()`. The extracted files KEEP their leading
# blank line (Kotlin's trimIndent yields a clause starting with "\n"),
# and run-eval.sh joins parts with "\n\n" exactly like the production
# `buildList { … }.joinToString("\n\n")`.
extract_locale_clause() {
    local fn_name="$1"
    local out_base="$2"
    local out_file="$OUT_DIR/$out_base.txt"

    local raw
    raw="$(awk -v fn="$fn_name" '
        $0 ~ "private fun " fn { in_fn = 1 }
        in_fn && /^\}/        { in_fn = 0 }
        in_fn && /"uk"[[:space:]]+-> """/ { capture = 1; next }
        capture && /""".trimIndent\(\)/   { capture = 0; in_fn = 0 }
        capture                            { print }
    ' "$SOURCE_KT")"

    if [[ -z "$raw" ]]; then
        echo "  ERROR: no UK clause extracted for '$fn_name' — check the regex / source" >&2
        exit 1
    fi

    echo "$raw" | trim_indent > "$out_file"
    echo "  $out_base.txt ($(wc -c < "$out_file" | tr -d ' ') bytes)"
}

extract_locale_clause "localeClauseFor"           "meal-system-uk-clause"
extract_locale_clause "ingredientLocaleClauseFor" "ingredient-system-uk-clause"
extract_locale_clause "recipeLocaleClauseFor"     "recipe-system-uk-clause"

# The advise UK clause is a SINGLE-LINE quoted string (not a
# triple-quote), so it gets its own extractor: the text between the
# first and last double-quote on the `"uk" ->` line inside
# `adviseFridgeRecipeLocaleClauseFor`. Escaped \" inside the Kotlin
# string are unescaped back to plain quotes.
extract_inline_uk_clause() {
    local out_file="$OUT_DIR/advise-system-uk-clause.txt"
    local raw
    raw="$(awk '
        /private fun adviseFridgeRecipeLocaleClauseFor/ { in_fn = 1 }
        in_fn && /"uk"[[:space:]]*->[[:space:]]*"/ {
            line = $0
            sub(/^[^>]*->[[:space:]]*"/, "", line)   # drop up to the opening quote
            sub(/"[[:space:]]*$/, "", line)          # drop the closing quote
            gsub(/\\"/, "\"", line)                  # unescape \" → "
            print line
            exit
        }
    ' "$SOURCE_KT")"
    if [[ -z "$raw" ]]; then
        echo "  ERROR: no inline UK clause extracted for adviseFridgeRecipeLocaleClauseFor" >&2
        exit 1
    fi
    printf '%s\n' "$raw" > "$out_file"
    echo "  advise-system-uk-clause.txt ($(wc -c < "$out_file" | tr -d ' ') bytes)"
}
extract_inline_uk_clause

# Metric branch of `adviseFridgeRecipeUnitsClause` (the eval always
# runs with useMetric=true, matching the app default).
extract_units_clause() {
    local out_file="$OUT_DIR/advise-units-clause.txt"
    local raw
    raw="$(awk '
        /private fun adviseFridgeRecipeUnitsClause/ { in_fn = 1 }
        in_fn && /if \(useMetric\) "/ {
            line = $0
            sub(/^[^"]*"/, "", line)
            sub(/"[^"]*$/, "", line)
            gsub(/\\"/, "\"", line)
            print line
            exit
        }
    ' "$SOURCE_KT")"
    if [[ -z "$raw" ]]; then
        echo "  ERROR: no metric units clause extracted from adviseFridgeRecipeUnitsClause" >&2
        exit 1
    fi
    printf '%s\n' "$raw" > "$out_file"
    echo "  advise-units-clause.txt ($(wc -c < "$out_file" | tr -d ' ') bytes)"
}
extract_units_clause

# ── Model constants ────────────────────────────────────────────────
MODEL="$(grep -oE 'const val MODEL = "[^"]+"' "$SOURCE_KT" | sed 's/.*"\(.*\)"/\1/')"
VISION_MODEL="$(grep -oE 'const val VISION_MODEL = "[^"]+"' "$SOURCE_KT" | sed 's/.*"\(.*\)"/\1/')"
if [[ -z "$MODEL" || -z "$VISION_MODEL" ]]; then
    echo "  ERROR: MODEL / VISION_MODEL constants not extracted" >&2
    exit 1
fi
cat > "$OUT_DIR/models.json" <<EOF
{
  "text":   "$MODEL",
  "vision": "$VISION_MODEL"
}
EOF
echo "  models.json → text=$MODEL vision=$VISION_MODEL"

# ── max_tokens scrape ──────────────────────────────────────────────
# The meal path routes through `commonRequestFields(maxTokens: Int = N)`
# (text uses the default; the photo path overrides it with a named
# `maxTokens = N` argument). Ingredient / recipe / advise / translate
# carry `put("max_tokens", N)` literals inside their own builder
# functions — extract each inside its function scope so document-order
# drift can't mis-assign them.
extract_fn_max_tokens() {
    local fn="$1"
    awk -v fn="$fn" '
        $0 ~ "fun " fn        { in_fn = 1 }
        in_fn && /put\("max_tokens",[[:space:]]*[0-9]+\)/ {
            match($0, /[0-9]+/)
            print substr($0, RSTART, RLENGTH)
            exit
        }
    ' "$SOURCE_KT"
}

MEAL_MAX="$(grep -oE 'maxTokens: Int = [0-9]+' "$SOURCE_KT" | head -1 | grep -oE '[0-9]+$' || true)"
INGR_MAX="$(extract_fn_max_tokens buildIngredientRequestBody)"
RCP_MAX="$(extract_fn_max_tokens buildRecipeRequestBody)"
ADVISE_MAX="$(extract_fn_max_tokens buildAdviseRecipeIdeasRequestBody)"
TRANSLATE_MAX="$(extract_fn_max_tokens buildTranslateRequestBody)"
VISION_MAX="$(awk '
    /fun buildImageRequestBody/ { in_fn = 1 }
    in_fn && /maxTokens = [0-9]+/ {
        match($0, /[0-9]+/); print substr($0, RSTART, RLENGTH); exit
    }
' "$SOURCE_KT")"

for pair in "meal:$MEAL_MAX" "ingredient:$INGR_MAX" "recipe:$RCP_MAX" \
            "advise:$ADVISE_MAX" "translate:$TRANSLATE_MAX" "vision:$VISION_MAX"; do
    if ! [[ "${pair#*:}" =~ ^[0-9]+$ ]]; then
        echo "  ERROR: max_tokens for '${pair%%:*}' not extracted (got '${pair#*:}')" >&2
        exit 1
    fi
done
cat > "$OUT_DIR/max-tokens.json" <<EOF
{
  "meal":       $MEAL_MAX,
  "ingredient": $INGR_MAX,
  "recipe":     $RCP_MAX,
  "advise":     $ADVISE_MAX,
  "translate":  $TRANSLATE_MAX,
  "vision":     $VISION_MAX
}
EOF
echo "  max-tokens.json → meal=$MEAL_MAX ingredient=$INGR_MAX recipe=$RCP_MAX advise=$ADVISE_MAX translate=$TRANSLATE_MAX vision=$VISION_MAX"

# ── Schema-mirror drift guard ──────────────────────────────────────
# The tool schemas are `buildJsonObject { … }` literals that a regex
# can't fully extract, so schemas/*.json are hand-mirrored. This
# check catches the failure mode that actually bites — a property
# ADDED or REMOVED in production while the mirror sleeps — by
# comparing the property-KEY sets on both sides. Descriptions /
# bounds drifting is not detected; re-read the Kotlin when a key-set
# change fires this guard.
check_schema_mirror() {
    local kt_val="$1"
    local mirror="$SCHEMAS_DIR/$2"

    if [[ ! -f "$mirror" ]]; then
        echo "  ERROR: schema mirror missing: $mirror" >&2
        exit 3
    fi

    # Kotlin side: every putJsonObject("key") inside the val block,
    # minus the structural keys (input_schema / properties / items).
    # Block ends at the next `private val|fun` declaration.
    local kt_keys
    kt_keys="$(awk -v name="$kt_val" '
        $0 ~ "private val " name ".*buildJsonObject" { capture = 1; next }
        capture && /private (val|fun|suspend)/       { capture = 0 }
        capture {
            line = $0
            while (match(line, /putJsonObject\("[a-z_0-9]+"\)/)) {
                key = substr(line, RSTART + 15, RLENGTH - 17)
                if (key != "input_schema" && key != "properties" && key != "items") print key
                line = substr(line, RSTART + RLENGTH)
            }
        }
    ' "$SOURCE_KT" | sort -u)"

    # Mirror side: every key that sits directly under a "properties"
    # object, at any depth. (`tr -d '\r'` — jq on Git Bash emits CRLF,
    # which would false-positive the comparison.) "items" is excluded
    # on BOTH sides: the Kotlin scrape can't tell a property literally
    # named "items" (translate_products has one) from the structural
    # array-items key, so the guard is blind to that one name — every
    # other key is compared.
    local mirror_keys
    mirror_keys="$(jq -r '[paths | select(length > 1 and .[-2] == "properties") | .[-1]] | unique | .[] | select(. != "items")' "$mirror" | tr -d '\r' | sort -u)"

    if [[ "$kt_keys" != "$mirror_keys" ]]; then
        echo "  ERROR: schema drift — $2 vs Kotlin '$kt_val'" >&2
        echo "    production keys: $(echo "$kt_keys" | tr '\n' ' ')" >&2
        echo "    mirror keys:     $(echo "$mirror_keys" | tr '\n' ' ')" >&2
        echo "  Re-mirror schemas/$2 from AnthropicNutritionApi.kt (keys," >&2
        echo "  bounds AND descriptions), then re-run." >&2
        exit 3
    fi
    echo "  schemas/$2 ✓ (keys match '$kt_val')"
}

echo "Verifying hand-mirrored tool schemas against production"
check_schema_mirror "toolSchema"                 "log_food.json"
check_schema_mirror "ingredientToolSchema"       "define_ingredient.json"
check_schema_mirror "recipeToolSchema"           "define_recipe.json"
check_schema_mirror "adviseRecipeIdeasToolSchema" "advise_recipe_ideas.json"
check_schema_mirror "translateToolSchema"        "translate_products.json"

echo "Done."
