"""The processing server's only way out: Supabase's database functions (PostgREST RPC) and Storage, with the
service key. Errors carry the HTTP status and the database's error code only, never request or response bodies
(they can hold storage paths)."""
from __future__ import annotations

import os
from typing import Any
from urllib.parse import quote

import httpx


class SupabaseError(Exception):
    """A request to Supabase failed."""


class Client:
    def __init__(self, url: str, key: str, *, timeout: float = 120.0, transport: httpx.BaseTransport | None = None):
        self._http = httpx.Client(base_url=url.rstrip("/"), timeout=timeout, transport=transport,
                                  headers={"apikey": key, "Authorization": f"Bearer {key}"})

    @classmethod
    def from_env(cls) -> Client:
        """From SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY."""
        return cls(os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_ROLE_KEY"])

    def close(self) -> None:
        self._http.close()

    def __enter__(self) -> Client:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    # Database functions -------------------------------------------------------------------------------

    def rpc(self, name: str, args: dict[str, Any]) -> Any:
        r = self._http.post(f"/rest/v1/rpc/{name}", json=args)
        _check(r, name)
        return r.json() if r.content else None

    def claim(self, worker_id: str) -> dict | None:
        """The next job with its upload, paper versions and copies (processing_job_claim), or None."""
        return self.rpc("processing_job_claim", {"p_worker": worker_id})

    def heartbeat(self, job_id: int, *, worker: str, attempt: int) -> bool:
        """Keeps the job's lock; False when this worker and attempt no longer hold it."""
        return bool(self.rpc("processing_job_heartbeat", {"p_job": job_id, "p_worker": worker, "p_attempt": attempt}))

    def record_pages(self, job_id: int, pages: list[dict], *, worker: str, attempt: int, sha256: str) -> dict:
        """Hands the prepared pages and the original's SHA-256 (lowercase hex) to script_pages_record.
        {ok:false, code:'conflict'} when the job was lost; with reason 'sha256_mismatch' when the original's hash
        differs from the one recorded before."""
        return self.rpc("script_pages_record", {"p_job": job_id, "p_worker": worker, "p_attempt": attempt,
                                                "p_sha256": sha256, "p_pages": pages})

    def finish(self, job_id: int, ok: bool, error: str | None = None, *, worker: str, attempt: int) -> dict:
        return self.rpc("processing_job_finish",
                        {"p_job": job_id, "p_worker": worker, "p_attempt": attempt, "p_ok": ok, "p_error": error})

    def discarded_take(self, limit: int) -> list[dict]:
        """Up to `limit` uploads a family never handed in and not yet purged, as [{id, storage_path}]
        (script_discarded_take): discarded from a draft over an hour ago, or still in a draft or pending once the
        booking's late window has been closed a day."""
        return self.rpc("script_discarded_take", {"p_limit": limit}) or []

    def mark_purged(self, upload_ids: list[str]) -> None:
        """Records that these discarded uploads' objects are deleted (script_upload_purged)."""
        self.rpc("script_upload_purged", {"p_ids": upload_ids})

    # Storage --------------------------------------------------------------------------------------------

    def download(self, bucket: str, path: str) -> bytes:
        r = self._http.get(f"/storage/v1/object/{bucket}/{quote(path)}")
        _check(r, "download")
        return r.content

    def upload(self, bucket: str, path: str, data: bytes, content_type: str) -> None:
        """Stores (or replaces: a rerun writes the same paths) one object."""
        r = self._http.post(f"/storage/v1/object/{bucket}/{quote(path)}", content=data,
                            headers={"Content-Type": content_type, "x-upsert": "true"})
        _check(r, "upload")

    def remove(self, bucket: str, paths: list[str]) -> None:
        """Deletes these objects in one request (an object already gone is no error)."""
        r = self._http.request("DELETE", f"/storage/v1/object/{bucket}", json={"prefixes": list(paths)})
        _check(r, "remove")


def _check(r: httpx.Response, what: str) -> None:
    if r.status_code < 400:
        return
    code = None
    try:
        body = r.json()
        if isinstance(body, dict) and isinstance(body.get("code"), str) and len(body["code"]) <= 10:
            code = body["code"]
    except ValueError:
        pass
    raise SupabaseError(f"{what}: HTTP {r.status_code}" + (f" ({code})" if code else ""))
