# CLAUDE.md — Calorcheeky-curator runbook

You are Claude, working inside Claude Code in the
`calorcheeky-curator` repository. **This file is your job
description for this directory.** Read it at session start,
follow the workflow when the user asks for a curation run.

The user's typical prompt:
> *"Do the seasonal evaluation for UA"*
> *"Run the May curation for UK"*
> *"Refresh the Ukrainian library"*

When you see one of those, execute the **5-step workflow** below.

---

## Context — what this repo does

The Calorcheeky calorie-tracker app has a per-country library of
template ingredients (apple, chicken breast, holubtsi, …). Twice
or three times a year, the operator wants to refresh the per-country
library — add what's seasonal, remove stale items, fix macros that
turned out wrong. **You** are the proposer. You research, you build
the diff, you publish (after the user signs off per row).

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

## The 5-step workflow

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

### 5. Publish

```bash
scripts/publish-pack.sh UA proposals/UA-2026-05/pack.json
```

Expected output: `{ "country": "UA", "version": <N+1> }`.

If you get any 4xx / 5xx, paste the curl output to the user — most
common failures are:

- `400 unsupported_country` — typo in the country code; check
  `^[A-Z]{2}$`.
- `401 Unauthorized` — `.env` credentials wrong / server admin
  not enabled.
- `500 internal` — usually means the JSON shape is wrong. Run
  `jq -e . proposals/...` to confirm validity, eyeball against
  the wire contract.

After a successful publish, **append a one-line summary to the
proposal's `report.md`** so the run is self-documenting:

```
> Published as v<N+1> at <ISO timestamp>. Approved by user: +<adds>, ~<updates>, −<removes>.
```

Then commit the proposal artifacts:

```bash
git add proposals/UA-2026-05/
git commit -m "curate(UA): seasonal update v<N+1> — <one-line summary>"
```

`proposals/` is checked in — it's the audit trail.

---

## Wire contract reference

The `SeedPackPayload` shape (matches the server's
`@Serializable data class SeedPackPayload`):

```json
{
  "country": "UA",
  "ingredients": [
    {
      "name": "Полуниця",
      "emoji": "🍓",
      "brand": null,
      "kcal_per_100g": 32.0,
      "fat_per_100g": 0.3,
      "protein_per_100g": 0.7,
      "carbs_per_100g": 7.7,
      "category": "FRUIT",
      "external_id": "seed.UA.strawberry.v18"
    }
  ],
  "recipes": []
}
```

**Required fields per ingredient:** `name`, `kcal_per_100g`,
`fat_per_100g`, `protein_per_100g`, `carbs_per_100g`, `category`,
`external_id`.

**Macro bounds (server-validated, fail-fast):**
- `kcal_per_100g`: 0–900 (pure fat is 884 — never propose higher)
- `fat_per_100g`, `protein_per_100g`, `carbs_per_100g`: 0–100

**Category** must be one of: `MEAT`, `FISH_SEAFOOD`, `DAIRY`,
`EGG`, `GRAIN`, `VEGETABLE`, `FRUIT`, `NUT_SEED`, `LEGUME`,
`FAT_OIL`, `SWEET`, `BEVERAGE`, `PROCESSED`, `OTHER`. Anything
else falls through to OTHER on the client.

**`external_id`** must match `seed\.[A-Z]{2}\.[a-z0-9_-]+\.v\d+`.
Format: `seed.{country}.{slug}.v{version-row-was-introduced-at}`.
**Never reuse a slug across different ingredients** — that confuses
the client's reconciler into matching them across packs. The slug
is a stable handle; the version suffix tells you when the row was
born. Updates to an existing row keep the OLD external_id (don't
mint a new one for the same slug).

**`recipes`** must be present (empty array is fine). v1 of the
client doesn't reconcile recipes; you can ignore the field.

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

## Sample first prompt + response shape

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
6. `scripts/publish-pack.sh UA proposals/UA-2026-05/pack.json`.
7. Append the publish summary, commit.

That's it. Don't overthink.
