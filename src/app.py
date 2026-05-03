"""
Calorcheeky-curator Streamlit UI.

Run: `streamlit run src/app.py` (or `calorcheeky-curator` if you
installed via `pip install -e .` and the venv is active).

Layout:
  - Sidebar: country picker, server health dot, "Reload current pack",
    danger-zone "Force-publish manually-edited JSON".
  - Main area, three tabs:
      1. Review — current state + AI proposal + per-row checkboxes.
      2. History — list of published versions (read-only).
      3. Raw JSON — escape hatch for hand-editing pack content.

Single Python session per launch. Streamlit reruns the script on
every interaction; the cached client + last-loaded pack live in
`st.session_state`.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

# Streamlit launches us as a script, NOT as a package — `streamlit run
# src/app.py`. The sibling imports (`models`, `client`, etc.) need
# `src/` on the path. Adding it explicitly keeps both `streamlit run`
# and `pytest`-style imports working.
sys.path.insert(0, str(Path(__file__).parent))

import httpx
import streamlit as st

from client import CalorcheekyClient
from diff import apply_selection_to_pack, compute_diff
from models import (
    PackResponse,
    ProposedDiff,
    ProposedIngredient,
    SeedIngredient,
    SeedPackPayload,
)
from proposer import Proposer, ProposerError

# ── Page config ────────────────────────────────────────────────────────

st.set_page_config(
    page_title="Calorcheeky · curator",
    page_icon="🌱",
    layout="wide",
)

# ── Session-state bootstrapping ────────────────────────────────────────
#
# Streamlit reruns the entire script on every interaction. Anything that
# should survive between reruns goes in `st.session_state`. Lazy
# construction so we don't pay for the client / proposer until the
# user actually does something.

def _get_client() -> CalorcheekyClient:
    if "client" not in st.session_state:
        st.session_state.client = CalorcheekyClient()
    return st.session_state.client


def _get_proposer() -> Proposer:
    if "proposer" not in st.session_state:
        st.session_state.proposer = Proposer()
    return st.session_state.proposer


# ── Sidebar ────────────────────────────────────────────────────────────

with st.sidebar:
    st.title("🌱 Curator")
    st.caption("Seasonal seed-pack publisher")
    st.divider()

    country = st.selectbox(
        "Country",
        options=["UA", "UK"],
        format_func=lambda c: {"UA": "🇺🇦 Ukraine", "UK": "🇬🇧 United Kingdom"}[c],
        help=(
            "Which country's catalogue to manage. Each country has its own "
            "independent pack version stream on the server."
        ),
    )
    if "country" in st.session_state and st.session_state.country != country:
        # Country changed — clear any cached pack / proposal so the UI
        # doesn't show stale data from the previous country.
        for key in ("current_pack", "proposal", "approved_external_ids"):
            st.session_state.pop(key, None)
    st.session_state.country = country

    st.divider()
    st.subheader("Server")
    if st.button("Health check", use_container_width=True):
        try:
            _get_client().healthcheck()
            st.success("✅ Reachable + auth OK")
        except (httpx.HTTPStatusError, httpx.RequestError) as e:
            st.error(f"❌ {type(e).__name__}: {e}")
        except RuntimeError as e:  # config errors from CalorcheekyClient.__init__
            st.error(f"❌ {e}")

    if st.button("Reload current pack", use_container_width=True):
        st.session_state.pop("current_pack", None)
        st.session_state.pop("proposal", None)


# ── Loaders ────────────────────────────────────────────────────────────

def _load_current_pack(country: str) -> PackResponse | None:
    """Cached fetcher for the currently-published pack. Re-fetches if
    not cached. Safe to call on every rerun — Streamlit's session
    state holds the result."""
    if "current_pack" not in st.session_state:
        try:
            st.session_state.current_pack = _get_client().get_latest(country)
        except (httpx.HTTPStatusError, httpx.RequestError) as e:
            st.error(f"Failed to load current pack: {e}")
            return None
    return st.session_state.current_pack


def _current_ingredients(country: str) -> list[SeedIngredient]:
    pack = _load_current_pack(country)
    return pack.payload.ingredients if pack else []


# ── Main: tabs ─────────────────────────────────────────────────────────

st.title(f"🌱 Calorcheeky curator — {country}")
tab_review, tab_history, tab_raw = st.tabs(["Review", "History", "Raw JSON"])


# ── Tab 1: Review ──────────────────────────────────────────────────────

with tab_review:
    pack = _load_current_pack(country)
    if pack is None:
        st.info(
            f"No pack published yet for **{country}**. Generate a proposal "
            f"or use the **Raw JSON** tab to publish v1 by hand."
        )
        current_version = 0
    else:
        st.markdown(
            f"**Current pack:** `v{pack.version}` published "
            f"`{pack.published_at}` · {len(pack.payload.ingredients)} ingredients"
        )
        current_version = pack.version
    next_version = current_version + 1

    st.divider()
    col1, col2 = st.columns([1, 4])
    with col1:
        propose_clicked = st.button("✨ Generate proposal", type="primary")
    with col2:
        st.caption(
            "Asks Claude to web-search for in-season products for "
            f"**{country}** this month, returns a structured ADD / UPDATE "
            "/ REMOVE diff. Manual approval per row before publish."
        )

    if propose_clicked:
        try:
            with st.spinner("Calling Claude with web_search…"):
                proposal = _get_proposer().propose(
                    country_code=country,
                    current_pack=(
                        pack.payload if pack else SeedPackPayload(country=country)
                    ),
                    next_version=next_version,
                )
            st.session_state.proposal = proposal
            # Reset approval state — every row in the new proposal
            # starts at its default (proposed = approved by default).
            st.session_state.approved_external_ids = _default_approval_set(proposal)
            st.success(
                f"Got proposal: +{len(proposal.additions)}, "
                f"~{len(proposal.updates)}, −{len(proposal.removals)}"
            )
        except ProposerError as e:
            st.error(f"Proposer error: {e}")

    proposal: ProposedDiff | None = st.session_state.get("proposal")
    if proposal is None:
        st.info("No proposal loaded. Tap **Generate proposal** above.")
    else:
        st.divider()
        st.subheader("Proposed changes")
        st.caption(
            "Tick the rows you want to publish. Default state mirrors the "
            "proposer's recommendation — every row is checked. Untick to "
            "skip."
        )
        approved: set[str] = st.session_state.get("approved_external_ids", set())

        # Three sections: additions, updates, removals.
        if proposal.additions:
            st.markdown(f"### ➕ Additions ({len(proposal.additions)})")
            for add in proposal.additions:
                _row_checkbox(add, approved, kind="add", current=None)
        if proposal.updates:
            st.markdown(f"### 🔄 Updates ({len(proposal.updates)})")
            current_by_id = {ing.external_id: ing for ing in _current_ingredients(country)}
            for upd in proposal.updates:
                _row_checkbox(upd, approved, kind="update", current=current_by_id.get(upd.external_id))
        if proposal.removals:
            st.markdown(f"### 🗑 Removals ({len(proposal.removals)})")
            current_by_id = {ing.external_id: ing for ing in _current_ingredients(country)}
            for ext_id in proposal.removals:
                _removal_checkbox(ext_id, approved, current_by_id.get(ext_id))

        st.session_state.approved_external_ids = approved

        st.divider()
        approved_count = len(approved)
        st.markdown(f"**{approved_count}** rows approved for publishing.")
        if st.button("📤 Publish approved subset", type="primary", disabled=approved_count == 0):
            _publish_approved(
                country=country,
                proposal=proposal,
                approved=approved,
            )


def _default_approval_set(proposal: ProposedDiff) -> set[str]:
    """Every proposed row starts in the approved set — the operator's
    job is to opt OUT of rows they don't trust, not to opt in to each
    one."""
    return {*(a.external_id for a in proposal.additions),
            *(u.external_id for u in proposal.updates),
            *proposal.removals}


def _row_checkbox(
    ing: ProposedIngredient,
    approved: set[str],
    *,
    kind: str,
    current: SeedIngredient | None,
) -> None:
    """One row in the additions / updates section. Checkbox + name +
    macros + (for updates) before/after diff."""
    col_check, col_body = st.columns([1, 12])
    with col_check:
        keep = st.checkbox(
            label="approved",
            value=ing.external_id in approved,
            key=f"chk-{kind}-{ing.external_id}",
            label_visibility="collapsed",
        )
    if keep:
        approved.add(ing.external_id)
    else:
        approved.discard(ing.external_id)
    with col_body:
        macros_line = (
            f"{ing.kcal_per_100g:.0f} kcal · F {ing.fat_per_100g:.1f} · "
            f"P {ing.protein_per_100g:.1f} · C {ing.carbs_per_100g:.1f}"
        )
        st.markdown(
            f"**{ing.emoji} {ing.name}** — _{ing.category}_ · `{ing.external_id}`<br>"
            f"<small>{macros_line}</small>",
            unsafe_allow_html=True,
        )
        if current is not None and kind == "update":
            cur_macros = (
                f"{current.kcal_per_100g:.0f} kcal · F {current.fat_per_100g:.1f} · "
                f"P {current.protein_per_100g:.1f} · C {current.carbs_per_100g:.1f}"
            )
            st.caption(f"Was: {cur_macros}")
        if ing.rationale:
            st.caption(f"💡 {ing.rationale}")
        if ing.citation_url:
            st.caption(f"🔗 [source]({ing.citation_url})")


def _removal_checkbox(
    ext_id: str,
    approved: set[str],
    current: SeedIngredient | None,
) -> None:
    """One row in the removals section — references an existing
    external_id, so the body shows the row that would disappear."""
    col_check, col_body = st.columns([1, 12])
    with col_check:
        keep = st.checkbox(
            label="approved",
            value=ext_id in approved,
            key=f"chk-rem-{ext_id}",
            label_visibility="collapsed",
        )
    if keep:
        approved.add(ext_id)
    else:
        approved.discard(ext_id)
    with col_body:
        if current is None:
            st.markdown(
                f"`{ext_id}` — *not found in current pack (already gone?)*"
            )
        else:
            st.markdown(
                f"**{current.emoji} {current.name}** · _{current.category}_ "
                f"· `{ext_id}`",
            )


def _publish_approved(
    *,
    country: str,
    proposal: ProposedDiff,
    approved: set[str],
) -> None:
    """Build the final pack body from the approved subset, POST it,
    surface the result."""
    current = _current_ingredients(country)
    final_ingredients = apply_selection_to_pack(
        country=country,
        current=current,
        proposed=[*proposal.additions, *proposal.updates],
        approved_external_ids=approved,
    )
    pack_body = SeedPackPayload(
        country=country,
        ingredients=final_ingredients,
        recipes=[],
    )
    try:
        with st.spinner("Publishing…"):
            response = _get_client().publish(pack_body)
        st.success(
            f"✅ Published `{response.country}` v{response.version}. "
            "Phones will see the prompt on next sync."
        )
        # Invalidate the cached current pack so the Review tab refreshes
        # against the just-published version.
        st.session_state.pop("current_pack", None)
        st.session_state.pop("proposal", None)
        st.session_state.pop("approved_external_ids", None)
    except (httpx.HTTPStatusError, httpx.RequestError) as e:
        st.error(f"Publish failed: {e}")


# ── Tab 2: History ─────────────────────────────────────────────────────

with tab_history:
    if st.button("Refresh history"):
        try:
            history = _get_client().get_history(country)
            st.session_state.history = history
        except (httpx.HTTPStatusError, httpx.RequestError) as e:
            st.error(f"Failed to load history: {e}")
    history = st.session_state.get("history")
    if history is None:
        st.info("Tap **Refresh history** to load.")
    elif not history.items:
        st.info(f"No packs published yet for {country}.")
    else:
        for item in history.items:
            st.markdown(f"- **v{item.version}** · `{item.published_at}`")


# ── Tab 3: Raw JSON ────────────────────────────────────────────────────

with tab_raw:
    st.caption(
        "Hand-author the entire pack body here. Bypasses the AI proposer "
        "entirely — useful for the v1 publish on a fresh country, or to "
        "fix a row the AI got wrong without re-running it."
    )
    pack = _load_current_pack(country)
    placeholder = (
        pack.payload.model_dump_json(indent=2)
        if pack
        else json.dumps(
            {"country": country, "ingredients": [], "recipes": []},
            indent=2,
        )
    )
    raw_text = st.text_area(
        "Pack JSON",
        value=placeholder,
        height=480,
        help=(
            "Must be a SeedPackPayload — `country`, `ingredients[]`, "
            "`recipes[]`. Server wraps it under `{\"payload\": ...}` "
            "for you."
        ),
        key=f"raw-{country}",
    )
    if st.button("📤 Publish RAW JSON", type="secondary"):
        try:
            parsed = SeedPackPayload.model_validate_json(raw_text)
        except Exception as e:
            st.error(f"JSON validation failed: {e}")
        else:
            try:
                with st.spinner("Publishing raw…"):
                    response = _get_client().publish(parsed)
                st.success(
                    f"✅ Published `{response.country}` v{response.version}."
                )
                st.session_state.pop("current_pack", None)
            except (httpx.HTTPStatusError, httpx.RequestError) as e:
                st.error(f"Publish failed: {e}")


# ── pyproject `calorcheeky-curator` script entry ───────────────────────


def cli_main() -> None:
    """Entry point for `pip install -e .` + `calorcheeky-curator`.
    Re-launches Streamlit pointing at this file. Optional convenience —
    `streamlit run src/app.py` works too."""
    import streamlit.web.cli as stcli

    sys.argv = ["streamlit", "run", str(Path(__file__).resolve())]
    sys.exit(stcli.main())
