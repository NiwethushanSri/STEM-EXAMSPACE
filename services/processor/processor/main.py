"""The processing server: claim a job, prepare its upload (or re-make its pages' marking pictures from their stored
full pictures: a remask job), store the pictures in the job's own folder, record them, finish the job.
Between jobs, at most once a minute, it also deletes the files families never handed in (discarded from a draft, or
left in a draft or unfinished after the booking's late window).

Run with `python -m processor.main` (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in the environment). It only
calls out to Supabase and listens to nothing. Logs carry job and upload ids, the attempt, page counts, timings
and outcome words only: never file names, storage paths, codes or page contents.
"""
from __future__ import annotations

import logging
import os
import signal
import socket
import tempfile
import threading
import time
from typing import Any, Callable

from processor import pipeline, supa
from processor.pipeline import Area, CopyRef, JobContext, PaperLayout, PreparedPage, UnreadableFile

log = logging.getLogger("processor")

UPLOADS = "script-uploads"
PAGES = "script-pages"
IDLE_SECONDS = 2.0  # between claims when there is nothing to do
HEARTBEAT_SECONDS = 30.0  # the job's lock is renewed this often while it runs (a quiet job is reclaimed after 15 min)
CLEANUP_SECONDS = 60.0  # discarded draft files are looked for at most this often, between jobs
CLEANUP_BATCH = 100  # discarded files deleted per look (one storage request)
MAX_PAGES = 5000  # a file of more pages is not read (the database takes at most this many pages of one file)


class LostJob(Exception):
    """Another worker holds the job now: stop without recording or finishing."""


class RecordRefused(Exception):
    """The database refused the page list."""


class OriginalChanged(Exception):
    """The original's SHA-256 differs from the one recorded on an earlier run: it must never change."""


class TooManyPages(Exception):
    """The file has more than MAX_PAGES pages: nothing is rendered or stored, and the job is not tried again."""


class UnsupportedJob(Exception):
    """A job kind this server does not run (it runs prepare and remask jobs)."""


def job_context(claimed: dict) -> JobContext:
    """The pipeline's view of processing_job_claim's result: the exam's copies by code and its paper versions."""
    papers = {
        p["paper_id"]: PaperLayout(
            page_count=int(p["page_count"]),
            roles={int(r["page"]): r["role"] for r in p["roles"]},
            areas=[Area(page=int(a["page"]), x=float(a["x"]), y=float(a["y"]), w=float(a["w"]), h=float(a["h"]))
                   for a in p["areas"]])
        for p in claimed["papers"]
    }
    copies = {
        code: CopyRef(copy_id=c["copy_id"], paper_id=c["paper_id"], booking_id=c["booking_id"],
                      page_count=int(c["page_count"]))
        for code, c in claimed["copies"].items()
    }
    return JobContext(copies=copies, papers=papers)


def page_paths(upload: dict, job_id: int, attempt: int, index: int) -> tuple[str, str]:
    """Where a job's attempt puts its pictures of page `index` of an upload in script-pages, in its own folder:
    <exam>/<upload>/<job>-<attempt>/<index>-full.jpg and -marking.jpg. A rerun, a remask or a retried attempt writes
    new paths, so no picture another page row names is ever overwritten."""
    base = f"{upload['exam_id']}/{upload['id']}/{job_id}-{attempt}/{index}"
    return f"{base}-full.jpg", f"{base}-marking.jpg"


def areas_of(items: list[dict], page: int = 0) -> list[Area]:
    """Hidden areas as the claim lists them ({x, y, w, h}, fractions)."""
    return [Area(page=page, x=float(a["x"]), y=float(a["y"]), w=float(a["w"]), h=float(a["h"])) for a in items]


def page_record(page: PreparedPage, full_path: str, marking_path: str | None) -> dict:
    """One item of script_pages_record's page list."""
    q = page.quality
    return {
        "source_index": page.source_index,
        "code": page.code,
        "copy_page": page.copy_page,
        "blank": page.blank,
        "quality": {"sharpness": q.sharpness, "brightness": q.brightness, "cut_off": q.cut_off, "flags": list(q.flags)},
        "rotation": page.rotation,
        "full_path": full_path,
        "marking_path": marking_path,
    }


class _Heartbeat:
    """Renews the job's lock from a background thread while the job runs, so a long scanner file is never taken
    for a dead worker's. `check()` raises LostJob once the database says another worker holds the job."""

    def __init__(self, client: Any, job_id: int, worker_id: str, attempt: int, interval: float):
        self._client, self._job, self._worker, self._attempt, self._interval = client, job_id, worker_id, attempt, interval
        self._lost = threading.Event()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, name=f"heartbeat-{job_id}", daemon=True)

    def _run(self) -> None:
        while not self._stop.wait(self._interval):
            try:
                if not self._client.heartbeat(self._job, worker=self._worker, attempt=self._attempt):
                    self._lost.set()
                    return
            except Exception as exc:  # a missed beat is retried at the next one
                log.warning("job %s heartbeat failed: %s", self._job, type(exc).__name__)

    def check(self) -> None:
        if self._lost.is_set():
            raise LostJob()

    def __enter__(self) -> _Heartbeat:
        self._thread.start()
        return self

    def __exit__(self, *exc: object) -> None:
        self._stop.set()
        self._thread.join()


def _prepare(client: Any, worker_id: str, claimed: dict, beat: _Heartbeat) -> int:
    """A prepare job: streams the original to a temporary file, hashing it on the way (SHA-256, recorded with the
    pages; a hash that differs from the one an earlier run recorded fails the job before any picture is stored, and the
    database checks it again). The original is never held whole in memory, and the temporary file is deleted whatever
    happens. The page count is read before anything is rendered: a file of more than MAX_PAGES pages fails at once
    (TooManyPages), with nothing rendered or stored. Then the pages are prepared and stored in the job's folder, and
    recorded. When the database answers that it kept the file's pages as they were (kept: staff worked on them, or a
    script being marked shows them, while the job waited), no page row names this job's pictures, so they are deleted
    again (a failure to delete is logged, never fails the job). Returns the page count."""
    job, upload = claimed["job"], claimed["upload"]
    fd, original = tempfile.mkstemp(prefix="original-")
    try:
        with os.fdopen(fd, "wb") as out:
            sha256 = client.download_to(UPLOADS, upload["storage_path"], out)
        if upload.get("sha256") and upload["sha256"] != sha256:
            raise OriginalChanged()  # before any picture is stored
        beat.check()
        if pipeline.page_count(original, upload["mime"]) > MAX_PAGES:
            raise TooManyPages()  # before anything is rendered
        pages = []
        stored: list[str] = []
        for page in pipeline.iter_prepare(original, upload["kind"], upload["mime"], job_context(claimed)):
            beat.check()
            full_path, marking_path = page_paths(upload, job["id"], job["attempts"], page.source_index)
            client.upload(PAGES, full_path, page.full, "image/jpeg")
            stored.append(full_path)
            if page.marking is not None:
                client.upload(PAGES, marking_path, page.marking, "image/jpeg")
                stored.append(marking_path)
            pages.append(page_record(page, full_path, marking_path if page.marking is not None else None))
    finally:
        try:
            os.unlink(original)
        except OSError:
            log.warning("job %s: could not delete its temporary file", job["id"])
    beat.check()
    result = client.record_pages(job["id"], pages, worker=worker_id, attempt=job["attempts"], sha256=sha256)
    if not result or not result.get("ok"):
        if result and result.get("code") == "conflict":
            if result.get("reason") == "sha256_mismatch":
                raise OriginalChanged()
            raise LostJob()
        raise RecordRefused()
    if result.get("kept") and stored:
        try:
            client.remove(PAGES, stored)
        except Exception as exc:  # the pictures are named by no page row; they only take up room
            log.warning("job %s: could not delete %d unused pictures: %s", job["id"], len(stored), type(exc).__name__)
    return len(pages)


def _remask(client: Any, worker_id: str, claimed: dict, beat: _Heartbeat) -> int:
    """A remask job: for each of the file's answer pages the claim lists, downloads its stored full picture (never the
    original), makes a new marking picture with the page's turn and hidden areas (pipeline.remask; None when none may
    be made), stores it in the job's folder (no full picture is ever written) and records them all
    (script_pages_remasked, which checks each page's key against its context now). Returns the page count."""
    job, upload = claimed["job"], claimed["upload"]
    items = []
    for p in claimed.get("pages") or []:
        beat.check()
        full = client.download(PAGES, p["full_path"])
        marking = pipeline.remask(
            full, int(p["turn"]), areas_of(p.get("paper_areas") or [], int(p["copy_page"] or 0)),
            staff_areas=areas_of(p.get("staff_areas") or []), code=p.get("code"), copy_page=p.get("copy_page"),
            provable=bool(p.get("provable")), confirmed=bool(p.get("confirmed")))
        marking_path = None
        if marking is not None:
            marking_path = page_paths(upload, job["id"], job["attempts"], int(p["source_index"]))[1]
            client.upload(PAGES, marking_path, marking, "image/jpeg")
        items.append({"page_id": p["page_id"], "marking_path": marking_path, "rotation": int(p["rotation"]), "key": p["key"]})
    beat.check()
    result = client.record_remask(job["id"], items, worker=worker_id, attempt=job["attempts"])
    if not result or not result.get("ok"):
        if result and result.get("code") == "conflict":
            raise LostJob()
        raise RecordRefused()
    return len(items)


RUNS = {"prepare": _prepare, "remask": _remask}


def process(client: Any, worker_id: str, claimed: dict, *, heartbeat_seconds: float = HEARTBEAT_SECONDS) -> str:
    """Runs one claimed job to its end (a prepare or a remask job, see _prepare and _remask) and finishes it. Returns
    the outcome: the job's state after finishing ('done', 'queued' for a retry, 'failed', 'superseded' when a newer
    job of the file waits), 'lost' when another worker took the job over, or 'unfinished' when finishing failed
    (the job is then claimed again after 15 minutes)."""
    job, upload = claimed["job"], claimed["upload"]
    job_id, attempt = job["id"], job["attempts"]
    started = time.monotonic()
    count = 0
    ok, error = True, None
    try:
        with _Heartbeat(client, job_id, worker_id, attempt, heartbeat_seconds) as beat:
            run = RUNS.get(job["kind"])
            if run is None:
                raise UnsupportedJob()
            count = run(client, worker_id, claimed, beat)
    except LostJob:
        log.warning("job %s upload %s attempt %s: lost to another worker after %.1f s",
                    job_id, upload["id"], attempt, time.monotonic() - started)
        return "lost"
    except UnreadableFile:
        ok, error = False, "unreadable"
    except TooManyPages:
        ok, error = False, "too_many_pages"  # the database fails the file at once and tells staff why
    except Exception as exc:
        ok, error = False, type(exc).__name__

    try:
        finished = client.finish(job_id, ok, error, worker=worker_id, attempt=attempt)
    except Exception as exc:
        log.error("job %s upload %s attempt %s: could not finish: %s", job_id, upload["id"], attempt, type(exc).__name__)
        return "unfinished"
    outcome = finished.get("state") if finished.get("ok") else finished.get("code")
    log.info("job %s upload %s attempt %s: %s%s, %d pages, %.1f s", job_id, upload["id"], attempt, outcome,
             f" ({error})" if error else "", count, time.monotonic() - started)
    return str(outcome)


def _abandon(client: Any, worker_id: str, claimed: Any, exc: Exception) -> None:
    """process() itself failed on an answer it did not expect: the job is failed with the error's class name only
    (when its id is known), and the worker carries on."""
    job = claimed.get("job") if isinstance(claimed, dict) else None
    job_id = job.get("id") if isinstance(job, dict) else None
    log.error("job %s: unexpected %s", job_id, type(exc).__name__)
    if job_id is None:
        return
    try:
        client.finish(job_id, False, type(exc).__name__, worker=worker_id, attempt=job.get("attempts"))
    except Exception as again:
        log.error("job %s: could not finish: %s", job_id, type(again).__name__)


def cleanup(client: Any) -> int:
    """Deletes from script-uploads the objects of files a family never handed in, as script_discarded_take lists
    them (discarded from a draft over an hour ago; still in a draft, or pending, from finish + 48 hours; a file that
    was handed in is never listed), then marks them purged. Nothing is marked when the deletion fails, so they are
    listed again next time. Returns how many were deleted."""
    items = client.discarded_take(CLEANUP_BATCH)
    if not items:
        return 0
    client.remove(UPLOADS, [item["storage_path"] for item in items])
    client.mark_purged([item["id"] for item in items])
    log.info("cleanup: %d files never handed in deleted", len(items))
    return len(items)


STOP_SIGNALS = (signal.SIGTERM, signal.SIGINT)  # the host's stop (fly.toml: kill_signal) and an interrupt


def _on_stop_signals(stop: threading.Event) -> Callable[[], None]:
    """Sets `stop` on SIGTERM or SIGINT (only possible in the main thread), so either one lets the job in hand finish
    and then ends the loop; returns what puts the old handlers back."""
    if threading.current_thread() is not threading.main_thread():
        return lambda: None
    previous = {sig: signal.signal(sig, lambda *_: stop.set()) for sig in STOP_SIGNALS}

    def restore() -> None:
        for sig, handler in previous.items():
            signal.signal(sig, handler)

    return restore


def run(client: Any, worker_id: str, *, once: bool = False, stop: threading.Event | None = None,
        idle_seconds: float = IDLE_SECONDS, heartbeat_seconds: float = HEARTBEAT_SECONDS,
        cleanup_seconds: float = CLEANUP_SECONDS) -> int:
    """Claims and runs jobs until SIGTERM or SIGINT (or `stop`), finishing the current job first; waits `idle_seconds`
    when there is nothing to do. Before a claim, when `cleanup_seconds` have passed since the last one (and at the
    start), deletes discarded draft files (cleanup; a failure is logged and tried again next time). With `once`,
    claims once and runs at most that job. Returns the jobs run."""
    stop = stop or threading.Event()
    restore = _on_stop_signals(stop)
    ran = 0
    next_cleanup = time.monotonic()
    try:
        while not stop.is_set():
            if time.monotonic() >= next_cleanup:
                next_cleanup = time.monotonic() + cleanup_seconds
                try:
                    cleanup(client)
                except Exception as exc:
                    log.warning("cleanup failed: %s", type(exc).__name__)
            try:
                claimed = client.claim(worker_id)
            except Exception as exc:
                if once:
                    raise
                log.warning("claim failed: %s", type(exc).__name__)
                stop.wait(idle_seconds)
                continue
            if claimed is None:
                if once:
                    break
                stop.wait(idle_seconds)
                continue
            try:
                process(client, worker_id, claimed, heartbeat_seconds=heartbeat_seconds)
            except Exception as exc:
                _abandon(client, worker_id, claimed, exc)
            ran += 1
            if once:
                break
    finally:
        restore()
    return ran


def configure_logging() -> None:
    """INFO for the server's own lines. httpx and httpcore log every request URL (storage paths name bookings and
    uploads), so only their warnings are kept."""
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    log.setLevel(logging.INFO)
    for name in ("httpx", "httpcore"):
        logging.getLogger(name).setLevel(logging.WARNING)


def main() -> None:
    configure_logging()
    worker_id = f"{socket.gethostname()}-{os.getpid()}"[:100]
    log.info("worker %s started", worker_id)
    with supa.Client.from_env() as client:
        run(client, worker_id)
    log.info("worker %s stopped", worker_id)


if __name__ == "__main__":
    main()
