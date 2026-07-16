# Calorcheeky AI prompt suite

The curated set of test prompts that exercises **every way the
Calorcheeky app talks to the Claude API**. One folder per surface
theme; each folder's `cases.json` is the source of truth for that
surface's probes. The runner (`scripts/eval/run-eval.sh`)
concatenates all folders into one run.

## Coverage matrix — app ↔ Claude surfaces

Everything the app sends to `api.anthropic.com` lives in ONE file:
`composeApp/.../data/api/AnthropicNutritionApi.kt` (the calorcheeky
repo). Six surfaces, all covered here:

| # | App surface | API fn | Forced tool | Model | max_tokens | Suite folder | Case IDs |
|---|---|---|---|---|---|---|---|
| 1 | Meal text → log entries | `parse` | `log_food` | Haiku (premium → Sonnet) | 768 | `text/` | `M*` |
| 2 | Meal photo → log entries | `parseImage` | `log_food` (+`reasoning`) | **VISION_MODEL (Sonnet)** | **1536**, thinking off | `photo/` | `P*` (auto-discovered) |
| 3 | Recipe text → library recipe | `parseRecipe` | `define_recipe` | Haiku | 2048 | `library/` | `R*` |
| 4 | Ingredient lookup → library ingredient | `parseIngredient` | `define_ingredient` | Haiku | 256 | `library/` | `I*`, `V4-V6` |
| 5 | Fridge tab → recipe ideas | `adviseRecipeIdeas` | `advise_recipe_ideas` | Haiku | 4096 | `recipe-ideas/` | `A*` |
| 6 | OFF search-result translation | `translateProducts` | `translate_products` | Haiku | 1024 | `translate/` | `T*` |

Cross-surface protocol probes: the **echo-label protocol**
(`library_name` / `variant` / `readiness` against a LIBRARY hints
block) is themed under `library/` as `V1-V3` even though they run on
the meal surface — folder = curation theme, `surface` field = runtime
routing.

Rate-limit buckets (app-side, `AIUsageRepository.kt`): surfaces 1+3+4+5
share TEXT, 2 is VISION, 6 is TRANSLATE.

## Case format

```json
{ "id": "M3",
  "surface": "meal | recipe | ingredient | advise | translate",
  "input": "the exact user-turn payload",
  "locale": "uk",                  // optional — appends the surface's UK clause
  "hints": ["Kidney beans [raw|cooked|canned]", "Olive oil"],
                                   // optional — injected as the production
                                   // LIBRARY block (per-surface preamble)
  "expected": "what a PASS looks like — concrete, self-contained" }
```

`{ "//section": "…" }` entries are grouping markers, skipped by the
runner. IDs are globally unique across folders; never reuse a retired
ID (run history references them).

**Every case carries its own `expected`.** A probe whose pass
criterion lives only in a grader's memory is not a curated prompt.
Ground new expectations in citations or the production prompt rules,
same bar as seed-pack macros.

## Authoring rules

- One case = one failure mode. If you can't say which distinct
  failure a case probes, it's redundant — cut it.
- For `advise` cases the `input` is the full production user-turn
  payload: a `REQUEST:` block (`source mode` = `strict`/`mix`/
  `discover`, `meal category` = a `MealCategory.promptTerm` or the
  "none — vary…" line, `to-buy list: wanted|not wanted`, optional
  `NOTE («…»)` line), then `KITCHEN: {"ingredients":[…],"dishes":[…]}`,
  then optionally the exclude-clause sentence. Mirror
  `adviseRequestBlock` in the .kt when in doubt.
- For `translate` cases the `input` is the compact JSON payload
  (`target_language` + `items[{name}]`) exactly as
  `buildTranslateRequestBody` sends it.
- `hints` lines mirror `hintLine()` formats: `Name` (single form),
  `Name [label|label]` (forms), `Name [label: 120kcal C0 P22 F3 | …] per 100g`
  (fridge-advisor macro format).
- Ukrainian probes: prefer pairs that caught real bugs (transliteration,
  Russian-word leakage, gendered labels) over mechanical EN→UK clones
  of existing cases.

## Pruning log

Dropped as redundant (grounded in graded-run history — each surviving
case still probes a distinct failure mode):

| Removed | Covered by | When |
|---|---|---|
| M4, M22-M25 | M21+M26 (hostile-input class) | 2026-05-01-1825 audit |
| R9, R14-R15 | R13+R16 (hostile-input class) | 2026-05-01-1825 audit |
| M1, M2, M6, M10, R1-R3, R5, I1, I2 | M38/M57-M61 (portions), R17-R23 (real-world dishes), I4/I10 + V4-V6 (profiles + variants) | later pre-renewal audits (already absent from tests.json) |
| M50 (`Кава американо з молоком`) | M51 (uk superset with sugar) + M52 (en milk) + M48 (uk base) | 2026-07-16 renewal |
| M53 (`black tea`) | M3 (water) + M55 (diet coke) + M56 (uk tea) | 2026-07-16 renewal |
| M59 (`1 apple`) | M58 (same unit-weight default probe) | 2026-07-16 renewal |

Added in the 2026-07-16 renewal: `A1-A8` (recipe-ideas surface —
previously ZERO coverage), `T1-T7` (translate surface — previously
ZERO coverage), `V1-V6` (echo-label protocol + variant authoring —
were documented in the old README but never in the runnable suite),
`M62` (request_text split + proper-noun preservation).

## Running + grading

Protocol, rubric, and runner internals: [`../scripts/eval/`](../scripts/eval/)
and the runbook section "Job B" in [`../CLAUDE.md`](../CLAUDE.md).
Photo-specific grading: [`photo/README.md`](photo/README.md).
