"""
HTTP client for the calorcheeky cloud server's `/admin/seed-pack/*`
endpoints. Synchronous httpx — Streamlit's render flow doesn't need
async, and sync code is easier to read in a tool that runs ~3 HTTP
calls per click.

Auth: HTTP Basic Auth with the same credentials the server's
`ADMIN_USER` / `ADMIN_PASSWORD` env vars set. Both must be non-blank
on the server or `/admin/*` returns 404 (the entire admin surface
is gated).

Env vars (read from `.env` via python-dotenv on import):
    CALORCHEEKY_BASE_URL       — e.g. `https://cloud.calorcheeky.com`
    CALORCHEEKY_ADMIN_USER     — usually "admin"
    CALORCHEEKY_ADMIN_PASSWORD — long random string
"""

from __future__ import annotations

import os

import httpx
from dotenv import load_dotenv

from models import (
    HistoryResponse,
    PackResponse,
    PublishRequest,
    PublishResponse,
    SeedPackPayload,
)

load_dotenv()


class CalorcheekyClient:
    """Thin wrapper around the four HTTP calls we need. Constructed
    once at app start; reused across every Streamlit re-render.

    Raises [httpx.HTTPStatusError] on any non-2xx response. Callers
    should catch and surface to the user — Streamlit's `st.error`
    is the standard target.
    """

    def __init__(
        self,
        base_url: str | None = None,
        username: str | None = None,
        password: str | None = None,
        timeout_seconds: float = 30.0,
    ) -> None:
        self.base_url = (base_url or os.getenv("CALORCHEEKY_BASE_URL", "")).rstrip("/")
        if not self.base_url:
            raise RuntimeError(
                "CALORCHEEKY_BASE_URL is not set. Add it to .env or pass via constructor."
            )
        u = username or os.getenv("CALORCHEEKY_ADMIN_USER", "")
        p = password or os.getenv("CALORCHEEKY_ADMIN_PASSWORD", "")
        if not u or not p:
            raise RuntimeError(
                "CALORCHEEKY_ADMIN_USER / CALORCHEEKY_ADMIN_PASSWORD missing. "
                "Add them to .env (and make sure the server has the same values)."
            )
        self._auth = httpx.BasicAuth(u, p)
        self._timeout = httpx.Timeout(timeout_seconds)

    # ── Reads ───────────────────────────────────────────────────────────

    def get_latest(self, country: str) -> PackResponse | None:
        """GET `/admin/seed-pack/{country}` → latest published pack.
        Returns `None` if no pack has been published yet (404).
        """
        url = f"{self.base_url}/admin/seed-pack/{country}"
        with httpx.Client(auth=self._auth, timeout=self._timeout) as c:
            r = c.get(url)
        if r.status_code == 404:
            return None
        r.raise_for_status()
        return PackResponse.model_validate(r.json())

    def get_history(self, country: str) -> HistoryResponse:
        """GET `/admin/seed-pack/{country}/history` — list of published
        versions with their timestamps. Used for the rollback UI."""
        url = f"{self.base_url}/admin/seed-pack/{country}/history"
        with httpx.Client(auth=self._auth, timeout=self._timeout) as c:
            r = c.get(url)
        r.raise_for_status()
        return HistoryResponse.model_validate(r.json())

    # ── Writes ──────────────────────────────────────────────────────────

    def publish(self, payload: SeedPackPayload) -> PublishResponse:
        """POST `/admin/seed-pack/{country}` — publish a new pack
        version. Server stamps version = max(version)+1 in a
        transaction; we get the assigned version back."""
        country = payload.country
        url = f"{self.base_url}/admin/seed-pack/{country}"
        body = PublishRequest(payload=payload)
        with httpx.Client(auth=self._auth, timeout=self._timeout) as c:
            r = c.post(url, json=body.model_dump(mode="json"))
        r.raise_for_status()
        return PublishResponse.model_validate(r.json())

    # ── Sanity ──────────────────────────────────────────────────────────

    def healthcheck(self) -> None:
        """Smoke-test the connection + auth. Used by the Streamlit
        sidebar to render a green/red dot. Throws on any auth or
        network failure — caller surfaces."""
        url = f"{self.base_url}/admin/stats.json"
        with httpx.Client(auth=self._auth, timeout=self._timeout) as c:
            r = c.get(url)
        r.raise_for_status()
