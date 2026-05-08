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
      "brand": null,
      "kcal_per_100g": 32.0,
      "fat_per_100g": 0.3,
      "protein_per_100g": 0.7,
      "carbs_per_100g": 7.7,
      "category": "FRUIT",
      "external_id": "seed.UA.strawberry.v18",
      "retired_at": null
    }
  ],
  "recipes": []
}
```

**Required fields per ingredient:** `name`, `kcal_per_100g`,
`fat_per_100g`, `protein_per_100g`, `carbs_per_100g`, `category`,
`external_id`.

**Optional fields per ingredient:** `emoji` (default `"🍽️"`),
`brand` (default `null`), `translations` (per-locale display names,
default `{}`), `retired_at` (0.7.55+ retire-not-delete marker,
default `null`).

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
6. `scripts/publish-pack.sh UA proposals/UA-2026-05/pack.json` —
   this auto-runs `scripts/verify-publish.sh` after the POST to
   confirm the data landed clean (no `?` substitution chars, count
   matches). Both lines must succeed; if verify fails, see step 5
   above for the recovery path.
7. Append the publish summary (with "Verified clean" suffix), commit.

That's it. Don't overthink.
