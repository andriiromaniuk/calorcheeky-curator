# calorcheeky-curator

Operator's runbook + thin bash CLI for publishing seasonal seed
packs to the Calorcheeky cloud-sync server. The actual AI work
(researching what's in season, drafting the diff, writing the
report) is done **inside Claude Code** — no Streamlit, no
Anthropic API key, no Python. Just **a runbook
([CLAUDE.md](./CLAUDE.md)) + three bash scripts**.

This repo is **separate** from the main `calorcheeky` app. It
talks to that app's running server's `/admin/seed-pack/*`
endpoints over HTTPS. Phones don't run this — only the operator.

---

## Why no Streamlit / Anthropic SDK?

Earlier (v0.1) this repo had a Streamlit app with an Anthropic
API integration that did web-search + structured-output to
generate proposals. That version worked but cost ~$0.01–0.10
per "Generate proposal" click against the API key — separate
billing from the operator's Claude Max subscription.

Pivoted to the current shape because:

1. **Cost.** Claude Max already covers Claude Code usage; running
   the work inside this conversation costs $0 marginal.
2. **Better tools.** Claude Code has WebSearch + WebFetch + Bash +
   Read + Write + Edit in one agent. The Streamlit app's single
   `web_search_20241222` API tool was strictly less capable.
3. **Less code.** No Python venv, no Streamlit version compat, no
   Anthropic SDK upgrades. Just bash + jq.
4. **Cadence.** Curation runs ~3× a year. A click-button UI's UX
   advantage at that cadence is negligible — the operator spends
   30 minutes on each run anyway, reviewing macros and clicking
   citations. The interface is the LEAST important part.

---

## Quick start

Prereqs: bash, curl, jq, a Claude Code session pointed at this
directory, an active `.env`.

### One-time setup

```bash
cd M:/Projects/calorcheeky-curator   # or wherever you cloned

cp .env.example .env
# Edit .env — fill in:
#   CALORCHEEKY_BASE_URL       (e.g. https://cloud.calorcheeky.com)
#   CALORCHEEKY_ADMIN_USER     (matches the server's ADMIN_USER)
#   CALORCHEEKY_ADMIN_PASSWORD (matches the server's ADMIN_PASSWORD)

chmod +x scripts/*.sh   # if not already
```

### Smoke-test the connection

```bash
scripts/fetch-pack.sh UA | jq .version
# expect a number; or 404 if no pack yet (curl exits non-zero)
```

### Run a curation

Open Claude Code in **this directory**, then type:

> *"Do the May 2026 seasonal evaluation for UA."*

Claude reads [CLAUDE.md](./CLAUDE.md), executes the 5-step
workflow:

1. Fetches the current pack via `scripts/fetch-pack.sh`.
2. Researches in-season products via WebSearch / WebFetch.
3. Drafts a per-row report (`proposals/UA-2026-05/report.md`)
   + a candidate `pack.json`.
4. Asks you to confirm / reject per row.
5. Publishes via `scripts/publish-pack.sh`.

Each phone running ≥0.6 sees the prompt on its next sync.

---

## Architecture

```
                    ┌─────────────────────────────────┐
                    │   Claude Code session           │
                    │   (in this dir; Max-sub-paid)   │
                    │                                 │
                    │   - Reads CLAUDE.md             │
                    │   - Uses WebSearch / WebFetch   │
                    │   - Drafts proposals/...        │
                    │   - Awaits user approval        │
                    │   - Runs scripts/*.sh           │
                    └────────────────┬────────────────┘
                                     │ bash + jq
                                     ▼
              ┌────────────────────────────────────────┐
              │   scripts/                             │
              │     fetch-pack.sh     (GET)            │
              │     publish-pack.sh   (POST)           │
              │     pack-history.sh   (GET)            │
              └────────────────┬───────────────────────┘
                               │ HTTPS + Basic Auth
                               ▼
                    ┌──────────────────────────┐
                    │  Calorcheeky cloud       │
                    │  /admin/seed-pack/*      │
                    └──────────────────────────┘
                                  │
                                  │ phones poll
                                  ▼
                    "Library update available" prompt
                       on app cold-launch / Sync now
```

---

## Layout

```
calorcheeky-curator/
├── CLAUDE.md              # The runbook Claude reads on session entry
├── README.md              # ← you are here
├── .env.example           # Template — copy to .env
├── .gitignore
├── scripts/
│   ├── fetch-pack.sh      # GET /admin/seed-pack/{country}
│   ├── publish-pack.sh    # POST /admin/seed-pack/{country}
│   └── pack-history.sh    # GET /admin/seed-pack/{country}/history
└── proposals/             # One folder per curation run, checked in
    └── <COUNTRY>-<YYYY-MM>/
        ├── report.md        ← human review surface, audit trail
        └── pack.json        ← canonical proposed payload
```

`proposals/` is the audit trail — each run leaves a folder
behind with the report + the published pack.json. Diff against
the previous run to see "what changed in May vs February".

---

## Adding a third country

1. **Server** (calorcheeky repo): add the country code to
   `SUPPORTED_COUNTRIES` in `server/.../SeedPack.kt`. Bump
   versionCode + redeploy.
2. **Client** (calorcheeky repo): add the value to the `Country`
   enum in `data/SettingsRepository.kt`. New string in the
   country picker. Ship a new APK.
3. **This repo**: nothing. The bash scripts are country-agnostic
   (they just pass the code through). The next curation run
   for the new country happens by typing
   *"Do the seasonal evaluation for {NEW}"* in Claude Code —
   the runbook handles the rest.

---

## Security notes

- `.env` is gitignored. Do NOT commit it.
- The admin password is plaintext on disk wherever you have
  this repo cloned. Treat it like any other secret.
- The bash scripts source `.env` directly — keep it free of
  shell-special characters in unquoted positions, or quote the
  values: `CALORCHEEKY_ADMIN_PASSWORD='secret$with$dollars'`.
- The server's admin endpoints are HTTP Basic Auth gated by env
  vars. If you set `ADMIN_USER` and `ADMIN_PASSWORD` to blank on
  the server, the entire `/admin/*` surface returns 404 — useful
  for read-only public deployments.
