"""
Anthropic-backed AI proposer. Given the currently-published pack
for a country, asks Claude (with the `web_search` tool) to propose
seasonal changes — additions, updates, removals.

Returns a `ProposedDiff` ready to feed into the Streamlit review UI.
Validation is done via pydantic (raises if Claude hallucinates a
field shape) — operator sees a clear error, not a 500 at publish time.
"""

from __future__ import annotations

import json
import os
from typing import Any

from anthropic import Anthropic
from anthropic.types import Message, ToolUseBlock
from dotenv import load_dotenv

from models import ProposedDiff, ProposedIngredient, SeedPackPayload
from prompts import SYSTEM_PROMPT, build_user_prompt

load_dotenv()


_DEFAULT_MODEL = os.getenv(
    "CALORCHEEKY_CURATOR_MODEL",
    # Sonnet 4.5 — the cheapest snapshot that handles structured-output
    # + tool-use reliably for this task. Override per-deploy via the env
    # var if you want to A/B different models.
    "claude-sonnet-4-5-20250929",
)

# Web-search tool. Anthropic's first-class server-side tool — Claude
# fetches URLs through Anthropic's infrastructure, returns cited
# snippets. Available in the SDK's `tools` list as
# `web_search_20241222`. See the Anthropic docs for parameter shape.
_WEB_SEARCH_TOOL: dict[str, Any] = {
    "type": "web_search_20241222",
    "name": "web_search",
    # Cap at 5 to keep latency reasonable. The proposer typically
    # only needs 2-3 queries (one for "in-season foods in X for May",
    # one to confirm macros).
    "max_uses": 5,
}


class ProposerError(RuntimeError):
    """Raised when the AI returned something we can't parse —
    surfaced to the Streamlit UI so the operator can retry."""


class Proposer:
    """One-shot wrapper around the Anthropic Messages API + web_search
    tool. Constructed once per Streamlit session.
    """

    def __init__(self, api_key: str | None = None, model: str = _DEFAULT_MODEL) -> None:
        key = api_key or os.getenv("ANTHROPIC_API_KEY")
        if not key:
            raise ProposerError(
                "ANTHROPIC_API_KEY is not set. Add it to .env."
            )
        self._client = Anthropic(api_key=key)
        self._model = model

    def propose(
        self,
        *,
        country_code: str,
        current_pack: SeedPackPayload,
        next_version: int,
    ) -> ProposedDiff:
        """Run one proposal round. Returns the parsed diff or raises
        [ProposerError] if Claude's response can't be coerced to the
        expected shape."""
        # Serialise the current pack as compact JSON so the prompt
        # doesn't waste tokens on whitespace.
        current_pack_json = current_pack.model_dump_json(
            indent=2,
            exclude_defaults=False,
        )
        user_prompt = build_user_prompt(
            country_code=country_code,
            current_pack_json=current_pack_json,
            version_to_mint=next_version,
        )

        response: Message = self._client.messages.create(
            model=self._model,
            max_tokens=8000,
            system=SYSTEM_PROMPT,
            tools=[_WEB_SEARCH_TOOL],
            messages=[{"role": "user", "content": user_prompt}],
        )

        # Stitch together the model's final text output. Tool-use
        # blocks (web_search invocations + their results) are
        # interleaved; we want only the final text content blocks.
        text_chunks = [
            block.text  # type: ignore[union-attr]
            for block in response.content
            if block.type == "text"
        ]
        if not text_chunks:
            raise ProposerError(
                "Claude returned no text content (only tool calls). "
                "Try again — sometimes the proposer hits the tool-use "
                f"limit without making the final summary call. Stop "
                f"reason: {response.stop_reason!r}"
            )
        raw_text = "".join(text_chunks).strip()

        diff = _parse_proposal(country_code=country_code, raw_text=raw_text)
        return diff


def _parse_proposal(*, country_code: str, raw_text: str) -> ProposedDiff:
    """Parse Claude's text output into a ProposedDiff. Tolerates
    the common pattern of code-fenced JSON (```json ... ```) by
    stripping fences before parsing. Raises [ProposerError] on
    anything we can't coerce."""
    cleaned = _strip_code_fence(raw_text)
    try:
        as_json = json.loads(cleaned)
    except json.JSONDecodeError as e:
        raise ProposerError(
            f"Claude's response wasn't valid JSON. First 400 chars:\n"
            f"{raw_text[:400]!r}\nDecode error: {e}"
        ) from e
    if not isinstance(as_json, dict):
        raise ProposerError(
            f"Claude returned a JSON value that's not an object: {type(as_json).__name__}"
        )
    additions_raw = as_json.get("additions", [])
    updates_raw   = as_json.get("updates", [])
    removals_raw  = as_json.get("removals", [])
    try:
        additions = [ProposedIngredient.model_validate(x) for x in additions_raw]
        updates   = [ProposedIngredient.model_validate(x) for x in updates_raw]
    except Exception as e:
        raise ProposerError(
            f"Claude returned ingredient rows that don't validate against "
            f"our schema. The rows you'd review would be untrustworthy — "
            f"retrying is usually enough. Error: {e}"
        ) from e
    if not all(isinstance(r, str) for r in removals_raw):
        raise ProposerError(
            f"Removals must be a list of external_id strings, got: {removals_raw!r}"
        )
    return ProposedDiff(
        country=country_code,
        additions=additions,
        updates=updates,
        removals=list(removals_raw),
    )


def _strip_code_fence(text: str) -> str:
    """Strip the ```json ... ``` or ``` ... ``` fences if present.
    Claude often wraps structured output in fences even when asked
    not to."""
    s = text.strip()
    if s.startswith("```"):
        # Drop opening fence (and language tag if any)
        first_newline = s.find("\n")
        if first_newline != -1:
            s = s[first_newline + 1 :]
    if s.endswith("```"):
        s = s[:-3]
    return s.strip()
