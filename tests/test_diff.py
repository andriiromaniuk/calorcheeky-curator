"""
Pure-function tests for `src/diff.py`. The diff logic is the
load-bearing part of the curator — if the splits between
additions/updates/removals are wrong, the operator sees a misleading
review UI and might publish the wrong thing. Cover all the cases.

Run: `pytest tests/`
"""

from __future__ import annotations

import sys
from pathlib import Path

# Make src/ importable when running pytest from repo root.
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from diff import apply_selection_to_pack, compute_diff
from models import ProposedIngredient, SeedIngredient


def _seed(external_id: str, name: str = "X", kcal: float = 32.0) -> SeedIngredient:
    return SeedIngredient(
        name=name,
        emoji="🍓",
        kcal_per_100g=kcal,
        fat_per_100g=0.3,
        protein_per_100g=0.7,
        carbs_per_100g=7.7,
        category="FRUIT",
        external_id=external_id,
    )


def _proposed(external_id: str, name: str = "X", kcal: float = 32.0) -> ProposedIngredient:
    return ProposedIngredient(
        name=name,
        emoji="🍓",
        kcal_per_100g=kcal,
        fat_per_100g=0.3,
        protein_per_100g=0.7,
        carbs_per_100g=7.7,
        category="FRUIT",
        external_id=external_id,
    )


# ── compute_diff ────────────────────────────────────────────────────────


def test_diff_empty_inputs_produces_empty_diff():
    d = compute_diff(country="UA", current=[], proposed=[])
    assert d.additions == []
    assert d.updates == []
    assert d.removals == []


def test_diff_addition_only():
    d = compute_diff(
        country="UA",
        current=[_seed("seed.UA.x.v1")],
        proposed=[_seed_to_prop(_seed("seed.UA.x.v1")), _proposed("seed.UA.y.v1", name="Y")],
    )
    assert len(d.additions) == 1
    assert d.additions[0].external_id == "seed.UA.y.v1"
    assert d.updates == []
    assert d.removals == []


def test_diff_removal_only():
    d = compute_diff(
        country="UA",
        current=[_seed("seed.UA.x.v1"), _seed("seed.UA.y.v1")],
        proposed=[_seed_to_prop(_seed("seed.UA.x.v1"))],
    )
    assert d.additions == []
    assert d.updates == []
    assert d.removals == ["seed.UA.y.v1"]


def test_diff_update_when_macros_change_beyond_tolerance():
    d = compute_diff(
        country="UA",
        current=[_seed("seed.UA.x.v1", kcal=32.0)],
        proposed=[_proposed("seed.UA.x.v1", kcal=50.0)],  # +18 kcal
    )
    assert d.additions == []
    assert len(d.updates) == 1
    assert d.updates[0].external_id == "seed.UA.x.v1"
    assert d.removals == []


def test_diff_no_update_when_macros_within_tolerance():
    """Rounding-noise — same row, same name, same macros within 0.5 of
    each other → no update emitted."""
    d = compute_diff(
        country="UA",
        current=[_seed("seed.UA.x.v1", kcal=32.0)],
        proposed=[_proposed("seed.UA.x.v1", kcal=32.3)],
    )
    assert d.updates == []


def test_diff_update_when_only_name_changes():
    """Curator renamed the row but kept macros identical — still
    counts as an update so the operator sees it in the review UI."""
    d = compute_diff(
        country="UA",
        current=[_seed("seed.UA.x.v1", name="Полуниця")],
        proposed=[_proposed("seed.UA.x.v1", name="Полуниці")],  # plural rename
    )
    assert len(d.updates) == 1


def test_diff_mixed_add_update_remove():
    d = compute_diff(
        country="UA",
        current=[
            _seed("seed.UA.a.v1"),  # stays unchanged
            _seed("seed.UA.b.v1", kcal=20.0),  # gets updated
            _seed("seed.UA.c.v1"),  # gets removed
        ],
        proposed=[
            _seed_to_prop(_seed("seed.UA.a.v1")),
            _proposed("seed.UA.b.v1", kcal=40.0),
            _proposed("seed.UA.d.v1", name="D"),  # new
        ],
    )
    assert [a.external_id for a in d.additions] == ["seed.UA.d.v1"]
    assert [u.external_id for u in d.updates] == ["seed.UA.b.v1"]
    assert d.removals == ["seed.UA.c.v1"]


# ── apply_selection_to_pack ────────────────────────────────────────────


def test_apply_empty_selection_keeps_current_intact():
    """When the operator approves nothing, the published pack equals
    the current state — every existing row survives, no new ones are
    added, no removals happen."""
    current = [_seed("seed.UA.a.v1"), _seed("seed.UA.b.v1")]
    proposed = [_proposed("seed.UA.c.v1", name="C")]
    out = apply_selection_to_pack(
        country="UA",
        current=current,
        proposed=proposed,
        approved_external_ids=set(),
    )
    assert {ing.external_id for ing in out} == {"seed.UA.a.v1", "seed.UA.b.v1"}


def test_apply_approves_addition_only():
    out = apply_selection_to_pack(
        country="UA",
        current=[_seed("seed.UA.a.v1")],
        proposed=[
            _seed_to_prop(_seed("seed.UA.a.v1")),
            _proposed("seed.UA.b.v1", name="B"),
        ],
        approved_external_ids={"seed.UA.b.v1"},
    )
    assert {ing.external_id for ing in out} == {"seed.UA.a.v1", "seed.UA.b.v1"}


def test_apply_approves_removal_only():
    out = apply_selection_to_pack(
        country="UA",
        current=[_seed("seed.UA.a.v1"), _seed("seed.UA.b.v1")],
        proposed=[_seed_to_prop(_seed("seed.UA.a.v1"))],
        approved_external_ids={"seed.UA.b.v1"},
    )
    assert {ing.external_id for ing in out} == {"seed.UA.a.v1"}


def test_apply_approves_update_swaps_macros():
    out = apply_selection_to_pack(
        country="UA",
        current=[_seed("seed.UA.x.v1", kcal=32.0)],
        proposed=[_proposed("seed.UA.x.v1", kcal=50.0)],
        approved_external_ids={"seed.UA.x.v1"},
    )
    assert len(out) == 1
    assert out[0].kcal_per_100g == 50.0


def test_apply_unapproved_update_leaves_current_value():
    out = apply_selection_to_pack(
        country="UA",
        current=[_seed("seed.UA.x.v1", kcal=32.0)],
        proposed=[_proposed("seed.UA.x.v1", kcal=50.0)],
        approved_external_ids=set(),  # operator unticked the update
    )
    assert len(out) == 1
    assert out[0].kcal_per_100g == 32.0  # unchanged


def test_apply_strips_curator_only_fields():
    """Citations and rationale never leave the curator — the wire
    payload is the strict SeedIngredient shape."""
    p = _proposed("seed.UA.b.v1", name="B")
    p.citation_url = "https://example.com/source"
    p.rationale = "in season in UA in May"
    out = apply_selection_to_pack(
        country="UA",
        current=[],
        proposed=[p],
        approved_external_ids={"seed.UA.b.v1"},
    )
    # The output type is SeedIngredient (no extras allowed by pydantic
    # `extra="forbid"`), so a roundtrip via model_dump() must succeed
    # without those keys appearing.
    serialised = out[0].model_dump()
    assert "citation_url" not in serialised
    assert "rationale" not in serialised


# ── Helpers ────────────────────────────────────────────────────────────


def _seed_to_prop(s: SeedIngredient) -> ProposedIngredient:
    """Lift a SeedIngredient into a ProposedIngredient (no citation /
    rationale). For tests where the proposed entry equals the current
    one verbatim."""
    return ProposedIngredient(
        name=s.name,
        emoji=s.emoji,
        brand=s.brand,
        kcal_per_100g=s.kcal_per_100g,
        fat_per_100g=s.fat_per_100g,
        protein_per_100g=s.protein_per_100g,
        carbs_per_100g=s.carbs_per_100g,
        category=s.category,
        external_id=s.external_id,
    )
