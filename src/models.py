"""
Wire DTOs — byte-compatible with the calorcheeky server's
`server/src/main/kotlin/com/romaniukandrii/calorcheeky/server/SeedPack.kt`.

Whenever the server's @Serializable shape changes, update these
in lockstep — they're literally the same JSON in flight.

Runtime validation via pydantic so a typo / bad AI proposal is
caught at parse time with a clear field path, not at curl time
with a 500.
"""

from __future__ import annotations

from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field

# ── 14 ingredient categories the client knows about ─────────────────────
# Mirror of `data.IngredientCategory` enum on the client side. The server
# stores the string verbatim in JSONB; the client parses via
# `IngredientCategory.fromString` and falls back to OTHER on unknown
# values — but we'd rather not rely on the fallback. Validate here.

IngredientCategory = Literal[
    "MEAT",
    "FISH_SEAFOOD",
    "DAIRY",
    "EGG",
    "GRAIN",
    "VEGETABLE",
    "FRUIT",
    "NUT_SEED",
    "LEGUME",
    "FAT_OIL",
    "SWEET",
    "BEVERAGE",
    "PROCESSED",
    "OTHER",
]


# ── Single ingredient row ───────────────────────────────────────────────


class SeedIngredient(BaseModel):
    """One ingredient inside a seed pack. Mirrors
    `server/.../SeedPack.kt:SeedPackIngredient`."""

    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    name: Annotated[str, Field(min_length=1, max_length=120)]
    emoji: Annotated[str, Field(min_length=1, max_length=10)] = "🍽️"
    brand: str | None = None

    # Per-100g macros. The client's UI clamps grams to 0..100_000 and
    # macros to sane bounds; we mirror those upper limits as a sanity
    # check on AI proposals (Claude has been known to confidently
    # propose 4000 kcal/100g which is physically impossible).
    kcal_per_100g: Annotated[float, Field(ge=0, le=900)]
    fat_per_100g: Annotated[float, Field(ge=0, le=100)]
    protein_per_100g: Annotated[float, Field(ge=0, le=100)]
    carbs_per_100g: Annotated[float, Field(ge=0, le=100)]

    category: IngredientCategory

    # Stable cross-version identifier minted by the curator. Format:
    # `seed.{country}.{slug}.v{introduced_at_version}`. The curator owns
    # this — never reuse a slug across different ingredients (would
    # confuse the client's reconciler into treating them as one row
    # across versions).
    external_id: Annotated[str, Field(pattern=r"^seed\.[A-Z]{2}\.[a-z0-9_-]+\.v\d+$")]


# ── Pack body ───────────────────────────────────────────────────────────


class SeedPackPayload(BaseModel):
    """The `payload` field — a full pack body. The server's outer
    response wraps this with version + published_at; admin POSTs send
    only this nested under {"payload": <pack>}."""

    model_config = ConfigDict(extra="forbid")

    country: Annotated[str, Field(pattern=r"^[A-Z]{2}$")]
    ingredients: list[SeedIngredient] = Field(default_factory=list)
    # Recipes are part of the wire format (the client's SeedPackPayload
    # has a `recipes: List<JsonElement>` field), but v1 of the curator
    # only handles ingredients. Always send an empty list — the client
    # ignores recipe entries on apply for now.
    recipes: list[dict] = Field(default_factory=list)


class PublishRequest(BaseModel):
    """POST body for `/admin/seed-pack/{country}`."""

    model_config = ConfigDict(extra="forbid")

    payload: SeedPackPayload


# ── Server responses ────────────────────────────────────────────────────


class PackResponse(BaseModel):
    """GET `/admin/seed-pack/{country}` response."""

    model_config = ConfigDict(extra="ignore")

    version: int
    country: str
    published_at: str
    payload: SeedPackPayload


class PublishResponse(BaseModel):
    """POST `/admin/seed-pack/{country}` 201 body."""

    model_config = ConfigDict(extra="ignore")

    country: str
    version: int


class HistoryItem(BaseModel):
    """One row in the GET `/admin/seed-pack/{country}/history` listing."""

    model_config = ConfigDict(extra="ignore")

    version: int
    published_at: str


class HistoryResponse(BaseModel):
    """Wrapper for the history listing."""

    model_config = ConfigDict(extra="ignore")

    country: str
    items: list[HistoryItem]


# ── Local-only proposal types (no wire) ─────────────────────────────────


class ProposedIngredient(SeedIngredient):
    """An ingredient the AI proposer suggested, with citation and
    rationale fields the human reviews. Strips down to a plain
    SeedIngredient when published — the citation/rationale stay
    in the curator's UI for the diff display only."""

    citation_url: str | None = None
    rationale: str | None = None


class ProposedDiff(BaseModel):
    """The output of `proposer.propose(...)`. Three buckets keyed
    by external_id; the UI lays out each as its own section with
    per-row checkboxes."""

    model_config = ConfigDict(extra="forbid")

    country: str
    additions: list[ProposedIngredient] = Field(default_factory=list)
    updates: list[ProposedIngredient] = Field(default_factory=list)
    # Removals reference an existing external_id, not a full ingredient
    # body — the curator already knows the name + macros for context.
    removals: list[str] = Field(default_factory=list)
