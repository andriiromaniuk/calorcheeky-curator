"""
Prompt templates for the AI proposer. Per-country: search hints
+ language guidance + citation requirements.

Adding a third country:
  1. Add a new entry to `COUNTRY_PROMPTS`.
  2. Pick representative source domains (supermarket flyers, food
     ministry data, popular nutrition sites).
  3. The system prompt below applies uniformly.
"""

from __future__ import annotations

from datetime import datetime
from textwrap import dedent

# ── Per-country source hints ───────────────────────────────────────────
#
# Hand-picked source domains for each supported country. The AI is
# free to roam the web, but we nudge toward domains we've vetted as
# "tend to have macros published" or "represent the country's actual
# market". Empty list means "let Claude decide" — fine for an MVP,
# tighten later.

COUNTRY_PROMPTS: dict[str, dict[str, str | list[str]]] = {
    "UA": {
        "name": "Ukraine",
        "language": "Ukrainian",
        "language_iso": "uk",
        "preferred_sources": [
            "silpo.ua",
            "auchan.ua",
            "atb.com.ua",
            "tablycjakalorijnosti.com.ua",
            "varenuha.com.ua",
        ],
        "search_query_template": (
            "продукти що зараз в сезоні в Україні {month} {year} калорійність на 100г"
        ),
        "ingredient_naming": (
            "Use the canonical Ukrainian name in the nominative singular "
            "(e.g. 'Полуниця', 'Кавун'). Capitalise the first letter."
        ),
    },
    "UK": {
        "name": "United Kingdom",
        "language": "English",
        "language_iso": "en",
        "preferred_sources": [
            "tesco.com",
            "sainsburys.co.uk",
            "waitrose.com",
            "ocado.com",
            "nutrition.org.uk",
        ],
        "search_query_template": (
            "what produce is in season in the UK {month} {year} calories per 100g"
        ),
        "ingredient_naming": (
            "Use the canonical English name in singular (e.g. 'Strawberry', "
            "'Watermelon'). Capitalise the first letter."
        ),
    },
}

# ── System prompt — uniform across countries ───────────────────────────

SYSTEM_PROMPT = dedent("""\
    You are the AI proposer for a per-country seasonal grocery
    catalogue. Your job: given the catalogue currently published
    for a specific country and the current month, propose ADD /
    UPDATE / REMOVE changes that reflect what people in that
    country are actually buying right now.

    Rules:
      - **Use the `web_search` tool** for every fresh piece of
        data. Do not rely on training-data lists — they are
        months stale by definition.
      - **Cite a source URL** for every ADD or UPDATE row. If you
        cannot find a citation that lists per-100g macros, OMIT
        the row rather than guess. Hallucinated nutrition data
        is the failure mode this whole tool is designed to
        prevent.
      - **Macro values are per 100 g**, USDA-style. kcal must be
        between 0 and 900 (no row exceeds 900 kcal/100g — even
        pure fat is 884). Each macronutrient (fat / protein /
        carbs) must be 0–100 g per 100g.
      - **Removals must include a one-sentence reason** — "out of
        season in {country} after April", "supermarkets stopped
        carrying", etc. Do not propose a removal without a reason.
      - **Pick stable external_ids** in the format
        `seed.{COUNTRY}.{slug}.v{version}`. The version number
        you pick should be the NEXT pack version (current_max + 1).
        Use a-z, 0-9, hyphen, underscore for the slug. Never reuse
        a slug across different ingredients.
      - **Categories must be one of**: MEAT, FISH_SEAFOOD, DAIRY,
        EGG, GRAIN, VEGETABLE, FRUIT, NUT_SEED, LEGUME, FAT_OIL,
        SWEET, BEVERAGE, PROCESSED, OTHER.

    Output format: a JSON object with the shape

        {
          "additions": [ <ProposedIngredient>, ... ],
          "updates":   [ <ProposedIngredient>, ... ],
          "removals":  [ "external_id_1", "external_id_2", ... ]
        }

    Where ProposedIngredient is:

        {
          "name": "...",
          "emoji": "...",
          "brand": null,
          "kcal_per_100g": 32.0,
          "fat_per_100g": 0.3,
          "protein_per_100g": 0.7,
          "carbs_per_100g": 7.7,
          "category": "FRUIT",
          "external_id": "seed.UA.strawberry.v18",
          "citation_url": "https://example.com/source",
          "rationale": "in season in UA in May"
        }

    Output ONLY the JSON object, no prose around it. The operator
    reviews every row before publishing — your job is to make
    review fast, not to be exhaustive.
""")


# ── User prompt builder ────────────────────────────────────────────────

def build_user_prompt(*, country_code: str, current_pack_json: str, version_to_mint: int) -> str:
    """Assemble the per-call user prompt: current pack + month +
    country-specific search hints."""
    if country_code not in COUNTRY_PROMPTS:
        raise ValueError(f"Unsupported country: {country_code!r}")
    cfg = COUNTRY_PROMPTS[country_code]

    now = datetime.now()
    month_name = now.strftime("%B")  # e.g. "May"
    year = now.year

    sources_block = (
        "\n".join(f"  - {s}" for s in cfg["preferred_sources"])  # type: ignore[arg-type]
        if cfg["preferred_sources"]
        else "  (operator did not pre-pick any — use your best judgement)"
    )

    return dedent(f"""\
        Country: **{cfg["name"]}** ({country_code})
        Month: **{month_name} {year}**
        Catalogue language: **{cfg["language"]}** ({cfg["language_iso"]})
        Pack version to mint for new external_ids: **v{version_to_mint}**

        Naming guidance: {cfg["ingredient_naming"]}

        Preferred sources for citations (you may roam beyond, but these
        are vetted):
        {sources_block}

        Suggested search query (in the catalogue language):
            {(cfg["search_query_template"]).format(month=month_name, year=year)}

        --- Currently published pack ---
        {current_pack_json}
        --- end pack ---

        Propose changes to bring the catalogue in line with what people
        in {cfg["name"]} are actually buying / not buying RIGHT NOW.
        Focus on seasonal fruit + vegetables; only touch dairy / meat
        / processed if you have strong web-sourced reason to.
    """)
