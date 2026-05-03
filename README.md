# calorcheeky-curator

AI-driven admin tool for publishing seasonal seed packs to the
Calorcheeky cloud-sync server. Used by the operator (you) to keep
the per-country library catalogue fresh — adds trending /
in-season grocery products, removes stale ones, edits macros.

This repo is **separate from the main `calorcheeky` app**. It
talks to the running server's `/admin/seed-pack/*` endpoints over
HTTPS. Phones don't run this — only the operator's laptop.

The server contract is locked at the calorcheeky repo's
`server/src/.../SeedPack.kt` (the wire DTOs) and documented in
the seasonal-update plan (`.claude/plans/lively-bubbling-tarjan.md`
in the calorcheeky repo).

---

## Quick start

Prereqs: Python 3.11+, an Anthropic API key, network access to
your cloud server.

```bash
# Clone (or just sit in the directory you've already created)
cd ~/code/calorcheeky-curator   # or wherever it lives

# Set up a virtualenv + install deps
python3 -m venv .venv
source .venv/bin/activate       # Windows: .venv\Scripts\activate
pip install -e .

# Configure
cp .env.example .env
# Edit .env — fill in:
#   CALORCHEEKY_BASE_URL       (e.g. https://cloud.calorcheeky.com)
#   CALORCHEEKY_ADMIN_USER     (matches the server's ADMIN_USER)
#   CALORCHEEKY_ADMIN_PASSWORD (matches the server's ADMIN_PASSWORD)
#   ANTHROPIC_API_KEY          (for the AI proposer)

# Run
streamlit run src/app.py
```

A browser opens at <http://localhost:8501>. Pick a country, load
the current pack, generate a proposal, review per-row, publish.

---

## What it does

```
┌──────────────────┐     web_search       ┌──────────────────┐
│  AI proposer     │────────────────────▶ │  Anthropic API   │
│  (proposer.py)   │◀───────────────────  │  + web_search    │
└──────────────────┘   structured JSON    │  tool            │
        │                                 └──────────────────┘
        ▼
┌──────────────────┐                      ┌──────────────────┐
│  Streamlit UI    │     HTTPS+BasicAuth  │  Calorcheeky     │
│  (app.py)        │────────────────────▶ │  server          │
│                  │      GET / POST       │  /admin/seed-pack│
│  - per-row diff  │      seed-pack        │                  │
│  - approve / ✗   │                       │  Postgres        │
│  - publish       │                       │  storage         │
└──────────────────┘                      └──────────────────┘
        ▲                                          │
        │  POST approved subset                    │  client app
        │                                          │  fetches on
        │                                          ▼  next sync
        └──────────────── operator (you) ◀── phone, banner
                                                    "Library
                                                    update
                                                    available"
```

Per the calorcheeky repo's README "How the app is structured"
section, **seasonal updates only mutate the library tier** —
logs and fridge entries stay intact, with the client rendering
"Template removed" badges for any history that referenced a
since-removed row. The curator never has to think about that
contract because it can only POST library-shaped payloads to
the server's narrow API surface; the client enforces the rest.

---

## Layout

```
calorcheeky-curator/
├── pyproject.toml      # python 3.11+, deps: streamlit, anthropic, httpx, pydantic
├── README.md
├── .env.example        # template for the four required env vars
├── src/
│   ├── app.py          # Streamlit entry point — `streamlit run src/app.py`
│   ├── prompts.py      # System + user prompts for the AI proposer
│   ├── proposer.py     # Anthropic client wrapper — web search + structured output
│   ├── client.py       # Calorcheeky server client (httpx, basic auth)
│   ├── diff.py         # Diff display helpers — compute add/update/remove
│   └── models.py       # pydantic DTOs that mirror the server's wire shape
└── tests/
    └── test_diff.py    # Pure-function tests on the diff logic
```

---

## Workflow

1. **Pick country** in the sidebar (UA / UK).
2. **Load current pack** — fetches `GET /admin/seed-pack/{country}`
   and shows the live state.
3. **Generate proposal** (optional — skip if you want to hand-edit).
   AI does a web search for trending products in the target
   country for the current month, returns a structured diff.
4. **Per-row review** — every proposed Add / Update / Remove gets
   a checkbox. Default state honors the resolver's hint
   (auto-apply for safe rows, marked-with-notice for rows the
   user is likely to care about).
5. **Edit raw JSON** — escape hatch. The "Raw JSON" tab lets you
   skip the AI entirely and hand-author a pack.
6. **Publish** — POSTs the approved subset as a new pack version.
   Server stamps the version monotonically.

---

## Adding a third country

Two changes:

1. **Server side** (calorcheeky repo, not this one):
   `server/src/.../SeedPack.kt` → add the country code to
   `SUPPORTED_COUNTRIES`. Bump versionCode + redeploy.
2. **Client app** (calorcheeky repo):
   `data/SettingsRepository.kt` → add the value to the `Country`
   enum. New string for the picker. Ship a new APK.
3. **This repo**:
   `src/app.py` → add the country to the dropdown.
   `src/prompts.py` → add a prompt-template entry for the new
   country (which sources to search, language to query in).

The architecture is country-agnostic; the constraint is the
curator operator's domain knowledge for that country.
