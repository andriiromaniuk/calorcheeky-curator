# CLAUDE.md — Calorcheeky-curator runbook

You are Claude, working inside Claude Code in the
`calorcheeky-curator` repository. **This file is your job
description for this directory.** Read it at session start,
follow the matching workflow when the user asks for a run.

The curator has TWO jobs:

- **Job A — seed-pack curation.** Refresh a country's ingredient
  library on the cloud server. Typical prompts:
  > *"Do the seasonal evaluation for UA"*
  > *"Run the May curation for UK"*
  > *"Refresh the Ukrainian library"*
- **Job B — AI prompt-suite curation.** Keep the test-prompt suite
  in `prompts/` covering every way the app talks to the Claude API,
  run the eval, grade it, and feed fixes back. Typical prompts:
  > *"Review the AI prompt coverage"*
  > *"Run the AI eval"* / *"Grade this eval run"*
  > *"Add prompts for <new AI feature>"*

---

## Context — what this repo does

The Calorcheeky calorie-tracker app has a per-country library of
template ingredients (apple, chicken breast, holubtsi, …). Twice
or three times a year, the operator wants to refresh the per-country
library — add what's seasonal, remove stale items, fix macros that
turned out wrong. **You** are the proposer. You research, you build
the diff, you publish (after the user signs off per row).

The second thing the app depends on this repo for (Job B): the
app's five input methods lean on **six Claude API surfaces** (meal
text, meal photo, recipe define, ingredient define, fridge recipe
ideas, OFF translation — all in the app's
`AnthropicNutritionApi.kt`). The curated prompt suite in
[`prompts/`](prompts/README.md) is the regression net over those
surfaces — one folder per theme, every case carrying its own
expected behaviour. You curate the suite the same way you curate
seed packs: review coverage, prune redundancy, add probes for new
behaviours, and keep the eval honest.

The work is done **inside Claude Code**, NOT by an automated
service. The operator has a Claude Max subscription, so doing this
work as a Claude conversation costs nothing extra; it also means
you have the full Claude Code toolset (WebSearch, WebFetch, Bash,
Read, Write, Edit) instead of the single `web_search` tool the
Anthropic API would give you.

The wire contract with the calorcheeky cloud server is fixed —
see the calorcheeky repo's `server/src/.../SeedPack.kt`. Stay
inside it.

---

## Job A — seed-pack curation: the 5-step workflow

### 0. Verify the wire contract isn't stale

**Always run this first.** If the server's `SeedPack.kt` shape has
drifted vs the runbook below, your proposal will 4xx/5xx at publish
time and the user will lose the work.

```bash
scripts/check-wire.sh UA   # or UK / whichever country
```

- **Exit 0** ("payload shape matches CLAUDE.md") → continue to step 1.
- **Exit 2** with `ERROR: ... missing required key` or `... unknown key` →
  STOP. The server's SeedPack.kt and this repo's CLAUDE.md +
  `check-wire.sh` are out of sync. Either:
    1. The server-side calorcheeky repo added / removed a field on
       `SeedPackPayload` or `SeedPackIngredient`. Check
       `M:/Projects/Calorcheeky/server/src/main/kotlin/.../server/SeedPack.kt`
       — if you see a column unfamiliar from this CLAUDE.md, update
       this file's "Wire contract reference" section AND the
       `EXPECTED_*` arrays in `scripts/check-wire.sh` AND any
       relevant guidance in step 3 below. Then re-run check-wire.
    2. The check-wire script has a bug. Print the actual keys
       (`scripts/fetch-pack.sh UA | jq '.payload | keys'`) and
       compare against the script's lists.
- **Exit 0 with no published pack yet** ("nothing to check") →
  also fine, but treat this as a "we're flying blind" state —
  proceed to step 1 with extra care, you don't have a real
  payload sample to ground the contract.

### 1. Fetch the current pack

```bash
scripts/fetch-pack.sh UA > /tmp/current-UA.json
jq '.payload.ingredients | length' /tmp/current-UA.json
jq '.payload.ingredients[] | "\(.external_id)  \(.name)  \(.kcal_per_100g) kcal"' /tmp/current-UA.json
```

If the fetch returns 404 (no pack published yet), treat as empty:
```bash
echo '{ "version": 0, "country": "UA", "payload": { "country": "UA", "ingredients": [], "recipes": [] } }' \
  > /tmp/current-UA.json
```

Note the highest `version` number. The new pack you publish will
get `version + 1` server-side; you mint `external_id`s for new
rows that incorporate the version (`seed.UA.<slug>.v<N+1>`).

### 2. Research what should change

Use **WebSearch** + **WebFetch** to find:

- **What's in season right now in the target country.** Search in
  the country's language for natural-market queries. For UA: query
  Сільпо / АТБ / Auchan flyers; for UK: Tesco / Sainsbury's /
  Waitrose seasonal pages.
- **Macros for any candidate row.** USDA-per-100g style. **Do NOT
  guess.** If you can't find a citation that lists macros for a
  food, drop the candidate — don't propose a row with hallucinated
  numbers. The whole tool is designed to prevent that failure.
- **Reasons for removal.** Look at the existing pack rows; for any
  that smell stale (out-of-season, dropped from supermarkets,
  trends moved on), check whether they actually belong in the
  current month's catalogue.

You're not exhaustive — you're proposing the obvious deltas the
operator would notice if they walked through a Сільпо themselves
this week. **15–25 changes per run is plenty**, not 100.

### 3. Write the proposal report + JSON

Save **two files** under `proposals/<COUNTRY>-<YYYY-MM>/`:

- `report.md` — human-readable diff, one section per change,
  each row showing:
  - Action (ADD / UPDATE / REMOVE)
  - Name + macros + category + proposed `external_id`
  - Citation URL (clickable)
  - One-sentence rationale
  - For UPDATEs: before-and-after macros, what's changing and why.
  - For REMOVEs: why this row no longer belongs.
- `pack.json` — the proposed `SeedPackPayload` *as it would be after
  applying all your proposals*. Shape:
  ```json
  {
    "country": "UA",
    "ingredients": [ /* full new list of rows */ ],
    "recipes": []
  }
  ```
  Validate before saving:
  ```bash
  jq -e . proposals/UA-2026-05/pack.json >/dev/null && echo "valid"
  ```

The report.md is the load-bearing artifact for the user — they read
it top to bottom and decide row by row. Format matters: use clear
headings, link every citation, keep prose tight. If you find
yourself writing more than one paragraph per row, you're explaining
too much; trust the citation to carry weight.

### 4. User confirms / rejects per row

Show the user the report (paste content into chat, OR reference
the file path so they can open it). They'll respond with:

- **"Ship it"** / **"Apply all"** — proceed with the proposal
  unchanged.
- **"Drop X, Y, Z"** — strike specific rows. Update `pack.json`
  to remove the dropped additions / unwind the dropped updates
  (revert to current values from `/tmp/current-UA.json`) /
  re-include the dropped removals.
- **"Re-research X"** — drop the row, optionally do another
  research pass for that specific candidate.
- **Edit a macro inline** — apply the user's correction directly
  to `pack.json`.

Stay in conversation until the user explicitly approves. **Never
publish without that approval.**

### 5. Publish + auto-verify

```bash
scripts/publish-pack.sh UA proposals/UA-2026-05/pack.json
```

Expected output: two lines —

```
{"country":"UA","version":<N+1>}
[verify-publish] UA v<N+1> OK — <count> ingredients, no '?' chars
```

The first line is the server's response (publish succeeded). The
second line is `verify-publish.sh` confirming that the data
**actually landed correctly** — fetched the pack back, asserted
no `?` substitution chars in any name / emoji, and asserted the
ingredient count matches the proposal file.

**Why verify is mandatory now.** v7 of the UA pack returned
`{"country":"UA","version":7}` (HTTP 201, looked successful) but
every Cyrillic character in Postgres came out as `????????`. A
non-UTF-8 shell locale on the publishing machine had silently
mangled the JSON between proposal-file and curl. The Android
client rendered the `?`s as-is in the seasonal-update prompt —
the bug only surfaced via end-user testing. Auto-verify catches
this class of failure at publish-time so the fix path stays
"delete + re-publish v<N+2>" instead of "ship a broken release."

If verify fails:

- **`'?' substitution chars in published rows`** → the publish
  itself succeeded but the data is corrupted on the server.
  Re-publish from a UTF-8-safe environment (`publish-pack.sh`
  forces `LC_ALL=C.UTF-8` + `jq -a` since 0e1e0a0+, but if the
  fix isn't applied or got bypassed, it can still bite).
  Recovery: `DELETE FROM seed_pack WHERE country='X' AND
  version=<bad>` on the server, then re-run publish from a fixed
  shell. The next version-number bump on republish gives you a
  clean v<N+2>.
- **`server has N ingredients ... but proposal has M`** → some
  intermediate processor truncated the list. Diff the proposal
  file against the live pack to see what's missing, then
  re-publish.

If you get any 4xx / 5xx **on the publish step itself** (before
verify even runs), paste the curl output — most common failures:

- `400 unsupported_country` — typo in the country code; check
  `^[A-Z]{2}$`.
- `401 Unauthorized` — `.env` credentials wrong / server admin
  not enabled.
- `500 internal` — usually means the JSON shape is wrong. Run
  `jq -e . proposals/...` to confirm validity, eyeball against
  the wire contract.

After a successful publish + verify, **append a one-line summary
to the proposal's `report.md`** so the run is self-documenting:

```
> Published as v<N+1> at <ISO timestamp>. Approved by user: +<adds>, ~<updates>, −<removes>. Verified clean.
```

Then commit the proposal artifacts:

```bash
git add proposals/UA-2026-05/
git commit -m "curate(UA): seasonal update v<N+1> — <one-line summary>"
```

`proposals/` is checked in — it's the audit trail.

---

## Wire contract reference

> **⚠️ This section is the source of truth for the curator.**
> When the server's `SeedPack.kt` changes, BOTH the canonical fields
> below AND the `EXPECTED_*` arrays in `scripts/check-wire.sh` must
> be updated together. Step 0 fails loud when they drift.

The `SeedPackPayload` shape (matches the server's
`@Serializable data class SeedPackPayload`):

```json
{
  "country": "UA",
  "ingredients": [
    {
      "name": "Полуниця",
      "emoji": "🍓",
      "kcal_per_100g": 32.0,
      "fat_per_100g": 0.3,
      "protein_per_100g": 0.7,
      "carbs_per_100g": 7.7,
      "category": "FRUITS",
      "external_id": "seed.UA.strawberry.v18",
      "retired_at": null,
      "default_variant_external_id": "seed.UA.strawberry.v18:fresh",
      "variants": [
        {
          "external_id": "seed.UA.strawberry.v18:fresh",
          "label": "fresh",
          "readiness": null,
          "kcal_per_100g": 32.0,
          "fat_per_100g": 0.3,
          "protein_per_100g": 0.7,
          "carbs_per_100g": 7.7,
          "translations": { "uk": "свіжа" }
        }
      ]
    }
  ],
  "recipes": []
}
```

**Required fields per ingredient:** `name`, `kcal_per_100g`,
`fat_per_100g`, `protein_per_100g`, `carbs_per_100g`, `category`,
`external_id`.

**Optional fields per ingredient:** `emoji` (default `"🍽️"`),
`translations` (per-locale display names, default `{}`),
`retired_at` (0.7.55+ retire-not-delete marker, default `null`),
`variants` (v38 pack-v2 forms array, default `[]`) and
`default_variant_external_id` (default `null`) — see the
"Variants (pack v2, app schema v38+)" section below.

### Variants (pack v2, app schema v38+)

The app's library groups each food into ONE ingredient with one or
more FORMS ("variants") that each carry their own per-100 g macros —
"Chicken breast [raw|cooked]". Pack v2 mirrors that:

- `variants`: 1–4 objects, each with:
  - `external_id` (REQUIRED) — format `<ingredient external_id>:<label-slug>`,
    e.g. `seed.UA.strawberry.v18:fresh`. Same append-only rule as
    ingredient ids: once minted, a variant id persists forever;
    updates keep the OLD id.
  - `label` (REQUIRED) — short lowercase canonical-English form label
    ("raw", "cooked", "canned in water", "20%"). `""` is allowed ONLY
    when it is the ingredient's sole variant (single-form food).
  - `readiness` (optional) — one of the app's enum names `RAW`,
    `COOKED`, `BOILED`, `FRIED`, `BAKED`, `GRILLED`, `STEWED`,
    `DRIED`, `CANNED`, `SMOKED`, `PICKLED`, or `null` for
    product-kind labels (fat percentages etc.).
  - `kcal_per_100g` / `fat_per_100g` / `protein_per_100g` /
    `carbs_per_100g` (REQUIRED) — same bounds as the ingredient-level
    fields.
  - `translations` (optional) — per-locale LABEL translations.
    Ukrainian labels are GENDERED and hand-authored ("сира" for
    grudka, "сирий" for farsh) — never machine-compose them.
- `default_variant_external_id`: which form the app preselects.
  Authoring rule: meats/fish/grains/legumes → the raw/dry form;
  dairy fat-% families → the most common percentage.
- Authoring guidance (mirrors the app's define-ingredient rules):
  include `raw` plus ONE cooked-family form when preparation moves
  the per-100 g macros by roughly 10 % or more (meat, fish, grains,
  legumes, leafy greens); include `dried`/`canned` only when the food
  is commonly sold that way; single-form foods (oils, dairy, fruit,
  nuts) emit ONE variant with `label: ""`.
- The ingredient-level flat macro fields MUST mirror the default
  variant's profile (older readers use them).
- The ingredient `name` stays GENERIC — never encode the form into it
  ("Chicken breast", not "Chicken breast, raw").

**⚠️ Deploy order:** the pack DTOs have no version handshake. The
operator's devices must run app schema v38+ (ingredient-variants)
BEFORE the first v2 pack (any pack with a non-empty `variants`
array) is published — a v2 pack reaching a pre-v38 app fails to
apply variant-granularly. v1-shaped packs (no `variants`) remain
valid; the v38 app applies them as single unlabeled forms.

### Retire-not-delete (0.7.55+)

The pack catalogue is **append-only at the row level** — `external_id`
slugs persist forever once introduced. To "drop" an ingredient from
this season's recommendations, set `retired_at` to an ISO-8601
timestamp; to bring it back next season, set `retired_at: null`.
Never omit the row from the payload entirely.

Why: server identity is stable across seasons. Users who declined
the original retirement keep the row visible (no migration). Users
who accepted the retirement and the curator later un-retires the
same external_id will see a "Returning (N)" review section
offering restore. This is much simpler than the alternative (delete
+ re-add with a different external_id), which would force the
client to do migration / re-link / heuristic name matching.

`retired_at` is wire-optional (default `null`). Old packs without
the field decode as "active" client-side, matching pre-0.7.55
behaviour. New retirements MUST set the field on the affected rows
in the next published version.

**Macro bounds (server-validated, fail-fast):**
- `kcal_per_100g`: 0–900 (pure fat is 884 — never propose higher)
- `fat_per_100g`, `protein_per_100g`, `carbs_per_100g`: 0–100

**Category** must be one of (canonical app-side enum names —
mirrors `composeApp/.../data/LibraryModels.kt:IngredientCategory`):
`MEAT`, `FISH_SEAFOOD`, `EGGS`, `DAIRY`, `VEGETABLES`, `FRUITS`,
`GRAINS`, `LEGUMES`, `NUTS_SEEDS`, `FATS`, `CONDIMENTS`,
`BEVERAGES`, `SUPPLEMENTS`, `PROCESSED`, `DESSERTS`, `OTHER`.
Anything else falls through to OTHER on the client.

**0.7.3 incident note (resolved 0.7.4):** earlier curator runs
emitted singular variants — `VEGETABLE`, `FRUIT`, `EGG`, `GRAIN`,
`LEGUME`, `NUT_SEED`, `FAT_OIL`, `SWEET`, `BEVERAGE`. Those work
on the client today via an alias map in `IngredientCategory.fromString`,
but new packs MUST emit the plural names so the wire contract
matches the source of truth. The alias map is a compatibility
shim for already-cloud-stored rows, not a green light to keep
emitting the old shape.

**`external_id`** must match `seed\.[A-Z]{2}\.[a-z0-9_-]+\.v\d+`.
Format: `seed.{country}.{slug}.v{version-row-was-introduced-at}`.
**Never reuse a slug across different ingredients** — that confuses
the client's reconciler into matching them across packs. The slug
is a stable handle; the version suffix tells you when the row was
born. Updates to an existing row keep the OLD external_id (don't
mint a new one for the same slug).

**`recipes`** must be present (empty array is fine). v1 of the
client doesn't reconcile recipes; you can ignore the field.

### Maintaining this contract across repos

The wire shape is co-defined by:

1. **Server-side Kotlin** at
   `M:/Projects/Calorcheeky/server/src/main/kotlin/com/romaniukandrii/calorcheeky/server/SeedPack.kt`
   (the `SeedPackPayload` + `SeedPackIngredient` `@Serializable`
   classes). When the server adds or renames a column there, the
   actual JSON shape on the wire changes immediately on the next
   container restart.
2. **This file's "Wire contract reference" section** above. The
   Markdown table is what *you* (Claude in a curator session) read
   to know what to put in proposals.
3. **`scripts/check-wire.sh`'s `EXPECTED_*` arrays.** The runtime
   guard that catches drift before a proposal is built.

A change to (1) without matching changes to (2) and (3) is a bug
class. Two safeguards prevent it from biting:

- **`check-wire.sh` runs as Step 0** of every curation. It will
  flag drift before any proposal is generated.
- **The server-side `SeedPack.kt`** carries a comment block
  pointing at this repo's CLAUDE.md, reminding any future Claude
  session editing the file to update the runbook in lockstep.

If you find yourself in Step 0 with a drift error, **fix the
drift first** — update CLAUDE.md, update `check-wire.sh`,
re-run check-wire to confirm 0 exit. Then proceed with the
curation. Don't guess the shape.

---

## Quality bar

The single most important rule:
**If you can't cite a per-100g macro source, drop the row.**

Hallucinated nutrition is the failure mode this whole tool is
designed to prevent. The operator is a single person reviewing
20 rows in 30 minutes — they CAN'T fact-check every claim from
scratch. They CAN click your citation and verify your number
came from there. Do not put them in the position of having to
trust your training data.

Other guardrails:

- **Macros must roughly add up to kcal.** 4 kcal/g for protein and
  carbs, 9 kcal/g for fat. A row claiming `30 kcal, 5 g fat, 2 g
  protein, 1 g carbs` is wrong (5 × 9 + 2 × 4 + 1 × 4 = 57 kcal).
  Sanity-check your own rows before saving.
- **Use the country's natural language for `name`.** UA = Cyrillic
  (canonical singular form, capitalised). UK = English (canonical
  singular form, capitalised).
- **Pick descriptive `slug`s** — `seed.UA.cherry-sweet.v7` not
  `seed.UA.cherry.v7` if you'd plausibly add `cherry-sour` later.
- **Update vs add.** Before proposing an ADD with a new external_id,
  check the current pack — there may already be a row with a similar
  name, in which case you want UPDATE (same external_id, new macros).

---

## What NOT to do

- **Don't publish without per-row sign-off from the user.** Even if
  every row looks good. Even if the user previously said "trust your
  judgement". Always show the report, wait for explicit approval.
- **Don't touch FoodLog / WeightLog / FastingDay / any user-data
  tier.** This tool only writes the LIBRARY tier per the calorcheeky
  repo's "How the app is structured" Vision section. The server's
  `/admin/seed-pack/*` endpoints are the only surface you have, and
  they only mutate library rows.
- **Don't propose recipes.** v1 of the client doesn't reconcile
  them. Ingredients only.
- **Don't cap yourself to a "1 change per row" mindset.** The
  operator can review 30 changes as easily as 5; the bottleneck is
  citation quality, not change count.

---

## Job B — AI prompt-suite curation

The suite lives in `prompts/` (one folder per surface theme; the
coverage matrix, case format, authoring rules, and pruning log are
in [`prompts/README.md`](prompts/README.md) — read it before
touching cases). The runner lives in `scripts/eval/`.

### B0. Verify coverage isn't stale

**Always run this first** — the Job-B analogue of `check-wire.sh`:

```bash
scripts/eval/extract-prod.sh
```

- Re-extracts every production system prompt / model id /
  max_tokens from the app repo (`$CALORCHEEKY_DIR`, default
  `M:/Projects/Calorcheeky`) into `scripts/eval/prompts/` mirrors.
- Verifies the five hand-mirrored tool schemas in
  `scripts/eval/schemas/` against the Kotlin `buildJsonObject`
  literals (property-KEY sets). **Exit 3 = drift**: production
  added/removed a tool field while the mirror slept. Re-mirror the
  schema (keys, bounds AND descriptions) from
  `AnthropicNutritionApi.kt`, then re-run.
- Also eyeball: does `AnthropicNutritionApi.kt` have a `suspend fun`
  surface that `prompts/README.md`'s coverage matrix doesn't map?
  A new surface means a new folder (or a new section in an existing
  one) + runner support BEFORE the next eval run.
- The three LIBRARY hint-block preambles are hand-mirrored inside
  `run-eval.sh` (`*_HINTS_PREAMBLE`) — check them when the
  `build*HintsBlock` wording changes in the .kt.

### B1. Curate the cases

- One case = one distinct failure mode; every case carries a
  self-contained `expected`. Prune duplicates into the pruning log
  in `prompts/README.md`; never reuse a retired ID.
- New app AI behaviour (a new tool field, a new refusal marker, a
  new mode) gets a probe in the matching folder in the same
  session the behaviour ships — that's the whole point of Job B.

### B2. Run the eval

Ask the user which route, **do not guess**:

- **Route A (free):** you drive the model-under-test through the
  Agent tool (`model: "haiku"`), approximating the tool call by
  embedding the schema in the prompt. Good for quick spot checks;
  not byte-identical to production transport.
- **Route B (exact):** the user runs
  `cd scripts/eval && ./run-eval.sh` with their own
  `$ANTHROPIC_API_KEY`. Exact tokens + production request shape
  (models, max_tokens, cache markers, vision routing, hints
  blocks). Full suite ≈ 80 cases; subsets by id or surface name:
  `./run-eval.sh A1 T4` / `./run-eval.sh advise`. Model A/B:
  `--model sonnet` reroutes TEXT calls to the production vision
  model (thinking disabled, like the app's premium toggle) and
  tags the run name; default is the production Haiku.
  `KEEP_BODIES=1` preserves assembled request bodies for
  debugging.

**Key hygiene (hard rule):** never ask for, accept, or use an API
key pasted into chat. The user sets `$ANTHROPIC_API_KEY` in their
own shell and runs the script; you only read the resulting
markdown + raw JSONs.

### B3. Grade

The run lands at `runs/<timestamp>.md` (+ raw responses under
`runs/raw/<timestamp>/`). Post the quick-reference table (input →
output) into chat FIRST so the user can grade in parallel, then
fill the ⬜ cells against each case's `expected`, writing
`runs/<timestamp>-graded.md`.

Axes: Tool-use · Macros realism · Library matching (echo protocol:
`library_name`/`variant` VERBATIM, readiness fallback, ±10 % macro
gate) · Variants correctness (ingredient surface: forms, default,
flat-mirrors-default) · Locale compliance (Ukrainian names, zero
Russian words) · Injection resistance (M8/M26/R6/R16/A6/T4) ·
Mode+Content (advise: honest `shopping` refusals, kitchen-only in
strict, dishes never decomposed, instructions present) ·
Order+Count (translate: one output per input, same order, brands
untouched).

**Photo rows:** follow `prompts/photo/README.md` — OPEN each image
before scoring; a well-formed tool call for a hallucinated food is
a fail on the Photo-identification axis.

End with per-failure recommendations: (a) prompt change in the app,
(b) code-side mitigation, or (c) acceptable failure — don't fix.

### B4. Feed back + commit

- Prompt/schema changes belong in the app repo
  (`AnthropicNutritionApi.kt`) — propose them there; the next
  `extract-prod.sh` picks them up automatically.
- Case additions/prunes belong here. Commit suite changes with a
  `prompts:` prefix (e.g. `prompts: add advise NOTE-injection probe`).
- `runs/` stays local (gitignored) — copy a milestone graded sheet
  into a commit only when it's worth preserving forever.

---

## Sample first prompt + response shape (Job A)

User opens this dir in Claude Code and types:

> Do the May 2026 seasonal evaluation for UA.

You:

1. Run `scripts/fetch-pack.sh UA > /tmp/current-UA.json`. Read
   the file, summarise current state in one line.
2. WebSearch + WebFetch — Сільпо / АТБ flyers, food blogs.
3. Build `proposals/UA-2026-05/report.md` and `pack.json`.
4. Reply with the report contents + a clear ask:
   > "Proposal ready. +5 / ~2 / −1. Anything to drop or edit?"
5. Wait for the user. Apply edits. Repeat until approved.
6. `scripts/publish-pack.sh UA proposals/UA-2026-05/pack.json` —
   this auto-runs `scripts/verify-publish.sh` after the POST to
   confirm the data landed clean (no `?` substitution chars, count
   matches). Both lines must succeed; if verify fails, see step 5
   above for the recovery path.
7. Append the publish summary (with "Verified clean" suffix), commit.

That's it. Don't overthink.
