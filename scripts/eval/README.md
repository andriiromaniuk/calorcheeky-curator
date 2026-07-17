# Eval runner — Job B machinery

The protocol (coverage check → curate → run → grade → feed back)
lives in [`../../CLAUDE.md`](../../CLAUDE.md) § Job B; the suite and
rubric context in [`../../prompts/README.md`](../../prompts/README.md).
This folder is just the machinery:

| File | Role |
|---|---|
| `run-eval.sh` | Replays the suite against the Anthropic Messages API with the production request shape per surface (models, max_tokens, cache markers, LIBRARY hint blocks, vision routing + thinking-off). Selectors: case ids, `prompts/` folder names (`text` / `photo` / `library` / `recipe-ideas` / `translate` — `./run-eval.sh recipe-ideas` runs exactly that folder, nothing else), and/or runtime surface names (`meal` includes photos; `advise` == recipe-ideas). `--model haiku\|sonnet\|<full-id>` overrides the TEXT model for A/B runs (production Haiku is the default; `sonnet` resolves to the production vision-model id and, like the app's premium reroute, disables thinking; photos always use the vision model). Override runs get a `-<model>`-tagged name under `runs/`. `KEEP_BODIES=1` keeps assembled request bodies. |
| `extract-prod.sh` | Regenerates `prompts/` mirrors from the app's `AnthropicNutritionApi.kt` (`$CALORCHEEKY_DIR`, default `M:/Projects/Calorcheeky`) and fails loud (exit 3) when a hand-mirrored schema's property keys drift from production. Runs automatically at the start of every eval. |
| `summarize.sh` | Aggregates a run's raw JSONs into the markdown scoring sheet (quick-reference table + per-surface ⬜ grids + totals). |
| `prompts/` | AUTO-GENERATED production mirrors — do not edit by hand; tracked so prompt drift shows up in git diffs. |
| `schemas/` | HAND-MIRRORED tool schemas (all five tools). When `extract-prod.sh` flags drift, update keys, bounds AND descriptions from the Kotlin literals. |

## Why LLM-as-judge grading works here

The grader (the Claude Code session — a stronger model) scores a
weaker model-under-test (Haiku for text surfaces; the vision model
for photos) against per-case `expected` fields. Known caveats:
self-bias (mitigated by grounding in `expected` + the app's own
prompt rules, not vibes), and calibration drift across grader
versions (mitigated by pinning the STIMULI — the suite — and
recording the resolved model ids in every run header).

## Route A (Agent tool) — free spot-checks

Instead of the script, the grader can drive Haiku directly via the
Agent tool (`model: "haiku"`), embedding the extracted system
prompt + a description of the tool schema, and asking for a JSON
reply. Caveats vs the script:

- Not byte-identical to production transport (no real forced
  `tool_choice`, harness chrome around the model), so treat
  injection-resistance results as indicative only.
- No exact token counts — estimate from characters: ~4 chars/token
  for English, ~2.5 for Cyrillic, ~3 for mixed text.
- The Agent tool's "haiku" may drift from the production-pinned id
  in `prompts/models.json` — note the resolved id in the run file.

Use Route A for quick iteration on a single case; use the script
(Route B) for anything you intend to grade and keep.
