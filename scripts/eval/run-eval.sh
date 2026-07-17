#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
# Calorcheeky AI prompt-suite eval — direct API, exact tokens.
#
# Loops every case in prompts/*/cases.json through Anthropic's
# Messages API with the production system prompt + tool schema +
# forced tool_choice, mirroring each surface's request shape in
# AnthropicNutritionApi.kt (models, max_tokens, LIBRARY hint
# blocks, vision routing, thinking-off on the vision model).
# Captures raw responses (including usage.*_tokens) into a per-run
# folder under runs/raw/, then aggregates a markdown scoring sheet
# at runs/<timestamp>.md for the grader.
#
# Usage:
#   export ANTHROPIC_API_KEY="sk-ant-…your-key…"
#   cd scripts/eval
#   ./run-eval.sh                       # the whole suite, production models
#   ./run-eval.sh M3 A1 T4              # subset by id
#   ./run-eval.sh advise                # a whole surface (meal / recipe /
#                                       #   ingredient / advise / translate)
#   ./run-eval.sh --model sonnet advise # A/B the text model (see below)
#
# Requirements: bash, curl, jq. Git Bash on Windows is fine.
# The calorcheeky app checkout must exist at $CALORCHEEKY_DIR
# (default M:/Projects/Calorcheeky) — production prompts are
# re-extracted from it at the start of every run.
# ─────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Pre-flight ──────────────────────────────────────────────────
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "ERROR: ANTHROPIC_API_KEY env var not set." >&2
    echo "  PowerShell:  \$env:ANTHROPIC_API_KEY = 'sk-ant-…'" >&2
    echo "  Bash:        export ANTHROPIC_API_KEY='sk-ant-…'" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq not installed." >&2
    exit 1
fi

# ── Args ────────────────────────────────────────────────────────
# Selectors are case ids (M3, A1) and/or surface names (meal /
# recipe / ingredient / advise / translate); no selector = whole
# suite. `--model` overrides the TEXT model (photos always run the
# production vision model):
#   --model haiku      → the production text model (the default)
#   --model sonnet     → the production vision model id — the same
#                        reroute as the app's premium-text toggle
#   --model <full-id>  → any Anthropic model id, verbatim
MODEL_OVERRIDE=""
RAW_SUBSET=()
while (( $# )); do
    case "$1" in
        --model)   MODEL_OVERRIDE="${2:?--model needs a value}"; shift 2 ;;
        --model=*) MODEL_OVERRIDE="${1#--model=}"; shift ;;
        *)         RAW_SUBSET+=("$1"); shift ;;
    esac
done

# ── Paths ───────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SUITE_DIR="$REPO_DIR/prompts"
PROMPTS_DIR="$SCRIPT_DIR/prompts"     # auto-generated production mirrors
SCHEMAS_DIR="$SCRIPT_DIR/schemas"
RUNS_DIR="$REPO_DIR/runs"

# Model-override runs get a tagged name so an A/B pair is
# self-describing side by side in runs/.
RUN_TAG=""
[[ -n "$MODEL_OVERRIDE" ]] && RUN_TAG="-${MODEL_OVERRIDE//[^a-zA-Z0-9._-]/-}"
TIMESTAMP="$(date +'%Y-%m-%d-%H%M')$RUN_TAG"
RUN_RAW_DIR="$RUNS_DIR/raw/$TIMESTAMP"
RUN_MD="$RUNS_DIR/$TIMESTAMP.md"
mkdir -p "$RUN_RAW_DIR"

ANTHROPIC_VERSION="2023-06-01"

# ── Pricing (USD per million tokens) ────────────────────────────
# Haiku 4.5 rates for the cost estimate; the vision surface runs on
# Sonnet so per-photo cost is higher than the estimate shows.
PRICE_INPUT_PER_M=1.0
PRICE_OUTPUT_PER_M=5.0

# jq -r wrapper that strips the CR that jq emits on Git Bash —
# a stray \r inside a model id / token count corrupts the request.
jqr() { jq -r "$@" | tr -d '\r'; }

# Refresh production-pinned prompts + models + max_tokens FIRST and
# verify the hand-mirrored schemas, so the eval always tests against
# current production. See extract-prod.sh.
"$SCRIPT_DIR/extract-prod.sh"

PROD_TEXT_MODEL="$(jqr '.text'   "$PROMPTS_DIR/models.json")"
VISION_MODEL="$(jqr '.vision' "$PROMPTS_DIR/models.json")"
case "$MODEL_OVERRIDE" in
    ""|haiku) TEXT_MODEL="$PROD_TEXT_MODEL" ;;
    sonnet)   TEXT_MODEL="$VISION_MODEL" ;;
    *)        TEXT_MODEL="$MODEL_OVERRIDE" ;;
esac
# Console cost estimate follows the known aliases; custom ids keep
# Haiku rates (the run sheet's footer carries the same caveat).
if [[ "$TEXT_MODEL" == "$VISION_MODEL" ]]; then
    PRICE_INPUT_PER_M=3.0
    PRICE_OUTPUT_PER_M=15.0
fi

# ── Build the effective test manifest ───────────────────────────
# Concatenate every suite folder's cases.json (id-bearing entries;
# `//section` markers are skipped), then append photo tests
# auto-discovered from prompts/photo/images/.
EFFECTIVE_TESTS="$RUN_RAW_DIR/_tests.json"
CASE_FILES=(
    "$SUITE_DIR/text/cases.json"
    "$SUITE_DIR/library/cases.json"
    "$SUITE_DIR/recipe-ideas/cases.json"
    "$SUITE_DIR/translate/cases.json"
)
for f in "${CASE_FILES[@]}"; do
    [[ -f "$f" ]] || { echo "ERROR: suite file missing: $f" >&2; exit 1; }
done

PHOTO_TEST_CAP=10
PHOTO_DIR="$SUITE_DIR/photo/images"
mapfile -t PHOTO_FILES < <(
    if [[ -d "$PHOTO_DIR" ]]; then
        # Stable sort so P1 maps to the same file across runs.
        find "$PHOTO_DIR" -maxdepth 1 -type f \
            \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
               -o -iname '*.webp' -o -iname '*.gif' \) \
            2>/dev/null | sort
    fi
)
PHOTO_COUNT=${#PHOTO_FILES[@]}
if (( PHOTO_COUNT > PHOTO_TEST_CAP )); then
    echo "  NOTE: found $PHOTO_COUNT photos in prompts/photo/images/, capping at $PHOTO_TEST_CAP"
    PHOTO_COUNT=$PHOTO_TEST_CAP
fi
PHOTO_JSON='[]'
for (( i = 0; i < PHOTO_COUNT; i++ )); do
    PHOTO_JSON="$(jq --arg id "P$((i+1))" --arg photo "${PHOTO_FILES[i]}" \
        '. + [{ id: $id, surface: "meal", photo: $photo }]' \
        <<< "$PHOTO_JSON")"
done
jq -s --argjson photos "$PHOTO_JSON" \
    '[ .[][] | select(.id) ] + $photos' \
    "${CASE_FILES[@]}" > "$EFFECTIVE_TESTS"

# ── Test selection: expand surface names, default to all ───────
SUBSET=()
if (( ${#RAW_SUBSET[@]} == 0 )); then
    mapfile -t SUBSET < <(jq -r '.[].id' "$EFFECTIVE_TESTS")
else
    for sel in "${RAW_SUBSET[@]}"; do
        case "$sel" in
            meal|recipe|ingredient|advise|translate)
                while IFS= read -r id; do SUBSET+=("$id"); done \
                    < <(jq -r --arg s "$sel" '.[] | select(.surface == $s) | .id' "$EFFECTIVE_TESTS" | tr -d '\r')
                ;;
            *) SUBSET+=("$sel") ;;
        esac
    done
fi

echo "Running ${#SUBSET[@]} test(s) ($PHOTO_COUNT photos) → $RUN_RAW_DIR"
if [[ -n "$MODEL_OVERRIDE" ]]; then
    echo "  text model: $TEXT_MODEL (--model $MODEL_OVERRIDE) · vision model: $VISION_MODEL"
else
    echo "  text model: $TEXT_MODEL · vision model: $VISION_MODEL"
fi

# ── System-prompt composition ───────────────────────────────────
# Mirrors the build*SystemPrompt functions: parts joined with "\n\n"
# (the extracted uk-clause files keep their leading blank line, so
# the byte sequence matches production's joinToString exactly).
compose_system() {
    local out="$1"; shift
    for part in "$@"; do
        out+=$'\n\n'"$(cat "$part")"
    done
    printf '%s' "$out"
}

# ── LIBRARY hint-block preambles ────────────────────────────────
# Hand-mirrored from buildMealHintsBlock / buildRecipeHintsBlock /
# buildFridgeRecipeHintsBlock in AnthropicNutritionApi.kt — update
# alongside them if the wording changes there.
MEAL_HINTS_PREAMBLE="LIBRARY (the user's saved ingredient vocabulary; bracketed values are that ingredient's saved FORM labels — raw, cooked, fat-% and so on. When an item in the meal matches one of these ingredients: use the exact ingredient name as the item's \`name\`, copy it VERBATIM into \`library_name\`, and copy EXACTLY ONE of its bracketed labels VERBATIM into \`variant\` — pick the form the food was actually eaten in. Ingredients listed without brackets have a single form; set \`library_name\` only. Invent names only for foods NOT in this list):"
RECIPE_HINTS_PREAMBLE="LIBRARY (your saved ingredient vocabulary — apply the Library matching priority from the system rules: prefer exact / variant matches verbatim, invent only when user-qualifier override or no reasonable variant; skip entries that don't topically belong in the dish. Bracketed values are each ingredient's saved FORM labels with per-100g macros. Use RAW forms for items cooked DURING preparation; as-consumed forms for items added ready-to-eat. When you use a listed ingredient, copy its name into \`library_name\` and the chosen form label VERBATIM into \`variant\`):"
ADVISE_HINTS_PREAMBLE="LIBRARY (your saved ingredients — reuse an entry's exact name AND macros when it matches by name and nutrients per the Library matching rules; bracketed values are that ingredient's saved FORM labels with per-100g macros — when a recipe step needs a specific form, echo its label verbatim after the name, e.g. 'Chicken breast (raw)'; skip entries that don't belong in the dish):"

# ── Per-test runner ─────────────────────────────────────────────
run_test() {
    local id="$1"
    local test_json
    test_json="$(jq -c --arg id "$id" '.[] | select(.id == $id)' "$EFFECTIVE_TESTS")"
    if [[ -z "$test_json" || "$test_json" == "null" ]]; then
        echo "  $id: SKIP (not in the suite + auto-discovered photos)"
        return
    fi

    local surface input locale photo has_hints
    surface="$(echo "$test_json" | jqr '.surface')"
    input="$(echo "$test_json"   | jqr '.input  // empty')"
    locale="$(echo "$test_json"  | jqr '.locale // empty')"
    photo="$(echo "$test_json"   | jqr '.photo  // empty')"
    has_hints="$(echo "$test_json" | jqr 'has("hints")')"

    if [[ -n "$photo" && ! -f "$photo" ]]; then
        echo "  $id: SKIP (photo missing: $photo)"
        return
    fi

    # Map surface → system-prompt parts + tool schema + max_tokens +
    # hint preamble + user-turn prefix. Mirrors the per-surface
    # builders in AnthropicNutritionApi.kt.
    local schema_file tool_name max_tokens system_text
    local hints_preamble="" input_prefix=""
    case "$surface" in
        meal)
            # Photo requests carry the image-rules block, mirroring
            # buildSystemPrompt(includeImageRules = true); text requests
            # never see it.
            local parts=()
            [[ -n "$photo" ]] && parts+=("$PROMPTS_DIR/image-rules.txt")
            parts+=("$PROMPTS_DIR/variant-explainer.txt")
            [[ "$locale" == "uk" ]] && parts+=("$PROMPTS_DIR/meal-system-uk-clause.txt")
            system_text="$(compose_system "$(cat "$PROMPTS_DIR/meal-system.txt")" "${parts[@]}")"
            schema_file="$SCHEMAS_DIR/log_food.json"
            tool_name="log_food"
            if [[ -n "$photo" ]]; then
                max_tokens="$(jqr '.vision' "$PROMPTS_DIR/max-tokens.json")"
            else
                max_tokens="$(jqr '.meal'   "$PROMPTS_DIR/max-tokens.json")"
            fi
            hints_preamble="$MEAL_HINTS_PREAMBLE"
            input_prefix="MEAL: "
            ;;
        recipe)
            local parts=("$PROMPTS_DIR/variant-explainer.txt")
            [[ "$locale" == "uk" ]] && parts+=("$PROMPTS_DIR/recipe-system-uk-clause.txt")
            system_text="$(compose_system "$(cat "$PROMPTS_DIR/recipe-system.txt")" "${parts[@]}")"
            schema_file="$SCHEMAS_DIR/define_recipe.json"
            tool_name="define_recipe"
            max_tokens="$(jqr '.recipe' "$PROMPTS_DIR/max-tokens.json")"
            hints_preamble="$RECIPE_HINTS_PREAMBLE"
            input_prefix="RECIPE REQUEST: "
            ;;
        ingredient)
            local parts=()
            [[ "$locale" == "uk" ]] && parts+=("$PROMPTS_DIR/ingredient-system-uk-clause.txt")
            if (( ${#parts[@]} )); then
                system_text="$(compose_system "$(cat "$PROMPTS_DIR/ingredient-system.txt")" "${parts[@]}")"
            else
                system_text="$(cat "$PROMPTS_DIR/ingredient-system.txt")"
            fi
            schema_file="$SCHEMAS_DIR/define_ingredient.json"
            tool_name="define_ingredient"
            max_tokens="$(jqr '.ingredient' "$PROMPTS_DIR/max-tokens.json")"
            ;;
        advise)
            local parts=("$PROMPTS_DIR/variant-explainer.txt")
            [[ "$locale" == "uk" ]] && parts+=("$PROMPTS_DIR/advise-system-uk-clause.txt")
            parts+=("$PROMPTS_DIR/advise-units-clause.txt")
            system_text="$(compose_system "$(cat "$PROMPTS_DIR/advise-system.txt")" "${parts[@]}")"
            schema_file="$SCHEMAS_DIR/advise_recipe_ideas.json"
            tool_name="advise_recipe_ideas"
            max_tokens="$(jqr '.advise' "$PROMPTS_DIR/max-tokens.json")"
            hints_preamble="$ADVISE_HINTS_PREAMBLE"
            ;;
        translate)
            system_text="$(cat "$PROMPTS_DIR/translate-system.txt")"
            schema_file="$SCHEMAS_DIR/translate_products.json"
            tool_name="translate_products"
            max_tokens="$(jqr '.translate' "$PROMPTS_DIR/max-tokens.json")"
            ;;
        *)
            echo "  $id: SKIP (unknown surface: $surface)"
            return
            ;;
    esac

    # Model routing mirrors production: photos → VISION_MODEL with
    # thinking disabled (Sonnet defaults adaptive thinking on, which
    # is incompatible with the forced tool_choice); text → TEXT_MODEL,
    # and any non-Haiku text model also gets thinking disabled — the
    # same handling as the app's premium reroute (`putTextModel`).
    local model="$TEXT_MODEL" thinking_json="null"
    if [[ -n "$photo" ]]; then
        model="$VISION_MODEL"
        thinking_json='{ "type": "disabled" }'
    elif [[ "$TEXT_MODEL" != "$PROD_TEXT_MODEL" ]]; then
        thinking_json='{ "type": "disabled" }'
    fi

    # Build the user-turn content. With hints: two text blocks —
    # the cached LIBRARY block, then the prefixed request — exactly
    # like the production builders. Without: a plain string.
    local content_json
    if [[ "$has_hints" == "true" ]]; then
        local hints_block
        hints_block="$hints_preamble"$'\n'"$(echo "$test_json" | jqr '.hints[] | "- " + .')"
        content_json="$(jq -n --arg hints "$hints_block" --arg req "$input_prefix$input" \
            '[ { type: "text", text: $hints, cache_control: { type: "ephemeral" } },
               { type: "text", text: $req } ]')"
    else
        content_json="$(jq -n --arg t "$input" '$t')"
    fi

    # Assemble + POST. Bodies are staged through temp files so photo
    # payloads (base64 of a multi-MB JPEG) bypass the OS argv limit;
    # `--data-binary @file` keeps the bytes verbatim. The system
    # block carries cache_control like production — sequential calls
    # within the 5-min ephemeral window pay ~10% on the shared prefix.
    local body_file
    body_file="$(mktemp)"
    if [[ -n "$photo" ]]; then
        local mime="image/jpeg"
        case "${photo##*.}" in
            png|PNG)   mime="image/png"  ;;
            webp|WEBP) mime="image/webp" ;;
            gif|GIF)   mime="image/gif"  ;;
        esac
        local b64_file
        b64_file="$(mktemp)"
        {
            base64 -w 0 "$photo" 2>/dev/null || base64 "$photo"
        } | tr -d '\n' > "$b64_file"
        jq -n \
            --arg model "$model" \
            --argjson max_tokens "$max_tokens" \
            --argjson thinking "$thinking_json" \
            --arg system "$system_text" \
            --rawfile b64 "$b64_file" \
            --arg mime "$mime" \
            --slurpfile schema "$schema_file" \
            --arg tool_name "$tool_name" \
            '{
                model: $model,
                max_tokens: $max_tokens,
                system: [ { type: "text", text: $system,
                            cache_control: { type: "ephemeral" } } ],
                tools: $schema,
                tool_choice: { type: "tool", name: $tool_name },
                messages: [ {
                    role: "user",
                    content: [ {
                        type: "image",
                        source: { type: "base64", media_type: $mime, data: $b64 }
                    } ]
                } ]
            } + (if $thinking != null then { thinking: $thinking } else {} end)' \
            > "$body_file"
        rm -f "$b64_file"
    else
        jq -n \
            --arg model "$model" \
            --argjson max_tokens "$max_tokens" \
            --argjson thinking "$thinking_json" \
            --arg system "$system_text" \
            --argjson content "$content_json" \
            --slurpfile schema "$schema_file" \
            --arg tool_name "$tool_name" \
            '{
                model: $model,
                max_tokens: $max_tokens,
                system: [ { type: "text", text: $system,
                            cache_control: { type: "ephemeral" } } ],
                tools: $schema,
                tool_choice: { type: "tool", name: $tool_name },
                messages: [ { role: "user", content: $content } ]
            } + (if $thinking != null then { thinking: $thinking } else {} end)' \
            > "$body_file"
    fi

    # KEEP_BODIES=1 preserves the assembled request next to the raw
    # response — for debugging body-shape issues without re-running.
    if [[ "${KEEP_BODIES:-}" == "1" ]]; then
        cp "$body_file" "$RUN_RAW_DIR/$id.request.json"
    fi

    local out_file="$RUN_RAW_DIR/$id.json"
    local http_code
    http_code="$(curl -sS -o "$out_file" -w '%{http_code}' \
        https://api.anthropic.com/v1/messages \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: $ANTHROPIC_VERSION" \
        -H "content-type: application/json" \
        --data-binary "@$body_file" || echo "000")"
    rm -f "$body_file"

    if [[ "$http_code" != "200" ]]; then
        echo "  $id: HTTP $http_code (see $out_file)"
        return
    fi

    local in_tok out_tok
    in_tok="$(jqr  '.usage.input_tokens  // 0' "$out_file")"
    out_tok="$(jqr '.usage.output_tokens // 0' "$out_file")"
    echo "  $id ($surface): in=${in_tok} out=${out_tok}"
}

# ── Loop ────────────────────────────────────────────────────────
echo "─────────────────────────────────────────────────"
for id in "${SUBSET[@]}"; do
    run_test "$id"
done
echo "─────────────────────────────────────────────────"

# ── Summarise ───────────────────────────────────────────────────
echo "Aggregating into $RUN_MD …"
"$SCRIPT_DIR/summarize.sh" "$RUN_RAW_DIR" "$RUN_MD"

# ── Cost estimate ───────────────────────────────────────────────
RESPONSE_JSONS=()
while IFS= read -r f; do RESPONSE_JSONS+=("$f"); done < <(
    find "$RUN_RAW_DIR" -maxdepth 1 -type f -name '*.json' \
        ! -name '_tests.json' ! -name '*.request.json' | sort
)
TOTAL_IN=$(jq -s 'map(.usage.input_tokens  // 0) | add' "${RESPONSE_JSONS[@]}")
TOTAL_OUT=$(jq -s 'map(.usage.output_tokens // 0) | add' "${RESPONSE_JSONS[@]}")
COST=$(awk -v in_t="$TOTAL_IN" -v out_t="$TOTAL_OUT" \
    -v pi="$PRICE_INPUT_PER_M" -v po="$PRICE_OUTPUT_PER_M" \
    'BEGIN { printf "%.4f\n", (in_t/1e6)*pi + (out_t/1e6)*po }')

echo
echo "── Totals ──"
echo "  input_tokens:  $TOTAL_IN"
echo "  output_tokens: $TOTAL_OUT"
echo "  est. cost:     \$$COST"
echo
echo "Run summary: $RUN_MD"
echo "Raw responses: $RUN_RAW_DIR"
