"""
Pure-function diff helpers for the curator UI. Given a "current"
pack (what's published on the server right now) and a "proposed"
state (the AI's suggestion OR a hand-edited JSON), produce a
ProposedDiff splitting the changes into three buckets keyed by
`external_id`:

  - additions: external_ids present only in proposed
  - updates  : external_ids in both, with materially-different macros
  - removals : external_ids present only in current

Mirrors the SHAPE of the client's `core/SeedPackConflict.kt` resolver
(the per-row analysis), but runs on the curator side BEFORE publish
— so the operator can see exactly what would change before the
pack ships. The client does its own conflict resolution against
each individual user's local library on apply.

Pure functions, no I/O — easy to unit-test (see `tests/test_diff.py`).
"""

from __future__ import annotations

from models import ProposedDiff, ProposedIngredient, SeedIngredient

# Macro tolerance — mirror of `core/SeedPackConflict.kt:macrosMateriallyDiffer`.
# Below this delta we consider the values "the same" and skip the update
# — avoids spamming the user with no-op rounding-noise rewrites.
_MACRO_TOL = 0.5


def _macros_materially_differ(a: SeedIngredient, b: SeedIngredient) -> bool:
    """True when the proposed macros differ enough to be worth an
    UPDATE. Mirrors the client's resolver tolerance."""
    return any(
        abs(getattr(a, field) - getattr(b, field)) > _MACRO_TOL
        for field in ("kcal_per_100g", "fat_per_100g", "protein_per_100g", "carbs_per_100g")
    )


def _names_or_categories_differ(a: SeedIngredient, b: SeedIngredient) -> bool:
    """Catch UPDATE rows that touch metadata (name / category / emoji /
    brand) without changing macros. The macro-diff alone misses these
    — but a curator who decided to rename `Полуниця` → `Полуниці` (Ukrainian
    plural) deserves to see that as an update."""
    return (
        a.name != b.name
        or a.category != b.category
        or a.emoji != b.emoji
        or a.brand != b.brand
    )


def compute_diff(
    *,
    country: str,
    current: list[SeedIngredient],
    proposed: list[ProposedIngredient],
) -> ProposedDiff:
    """Produce a ProposedDiff against the [current] published pack."""
    current_by_id = {ing.external_id: ing for ing in current}
    proposed_by_id = {ing.external_id: ing for ing in proposed}

    additions: list[ProposedIngredient] = []
    updates: list[ProposedIngredient] = []
    for ext_id, prop in proposed_by_id.items():
        if ext_id not in current_by_id:
            additions.append(prop)
            continue
        cur = current_by_id[ext_id]
        if _macros_materially_differ(cur, prop) or _names_or_categories_differ(cur, prop):
            updates.append(prop)
        # else: no change — skip silently.

    removals = [ext_id for ext_id in current_by_id if ext_id not in proposed_by_id]

    return ProposedDiff(
        country=country,
        additions=additions,
        updates=updates,
        removals=removals,
    )


def apply_selection_to_pack(
    *,
    country: str,
    current: list[SeedIngredient],
    proposed: list[ProposedIngredient],
    approved_external_ids: set[str],
) -> list[SeedIngredient]:
    """Build the final ingredients list for the published pack body,
    applying only the approved subset of changes against [current].

    Logic:
      - For every current row, keep it UNLESS its external_id is in
        approved AND in the removals set.
      - Add every approved addition / replace every approved update
        from [proposed].

    Returns the merged ingredients list (no recipes; v1 is ingredient-
    only).
    """
    diff = compute_diff(country=country, current=current, proposed=proposed)
    proposed_by_id = {ing.external_id: ing for ing in proposed}

    # Start from current rows that aren't being removed (or whose
    # removal wasn't approved).
    approved_removals = {
        ext_id for ext_id in diff.removals if ext_id in approved_external_ids
    }
    out: list[SeedIngredient] = [
        ing for ing in current if ing.external_id not in approved_removals
    ]

    # Apply approved updates (overwrite in place).
    approved_update_ids = {
        u.external_id for u in diff.updates if u.external_id in approved_external_ids
    }
    if approved_update_ids:
        out = [
            (
                _to_seed_ingredient(proposed_by_id[ing.external_id])
                if ing.external_id in approved_update_ids
                else ing
            )
            for ing in out
        ]

    # Append approved additions.
    for add in diff.additions:
        if add.external_id in approved_external_ids:
            out.append(_to_seed_ingredient(add))

    return out


def _to_seed_ingredient(p: ProposedIngredient) -> SeedIngredient:
    """Strip the curator-only fields (citation_url, rationale) before
    publishing. The wire DTO is just the strict SeedIngredient —
    extra fields would be rejected by the server's pydantic-equivalent
    @Serializable shape (kotlinx-serialization with strict mode)."""
    return SeedIngredient(
        name=p.name,
        emoji=p.emoji,
        brand=p.brand,
        kcal_per_100g=p.kcal_per_100g,
        fat_per_100g=p.fat_per_100g,
        protein_per_100g=p.protein_per_100g,
        carbs_per_100g=p.carbs_per_100g,
        category=p.category,
        external_id=p.external_id,
    )
