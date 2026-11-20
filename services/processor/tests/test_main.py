"""main.run and main.process against a fake Supabase client: what is stored, recorded and finished for a job."""
import hashlib
import logging
import signal
import threading
import time

import pytest

import synth
from processor import main, pipeline
from processor.imaging import Quality

EXAM, UPLOAD, PAPER, COPY, BOOKING = "exam-1", "upload-1", "paper-1", "copy-1", "booking-1"
PATH = "home/booking-1/upload-1.pdf"


def claimed(kind="prepare", attempts=1, upload_kind="home_pdf", mime="application/pdf", job_id=7):
    return {
        "job": {"id": job_id, "kind": kind, "attempts": attempts},
        "upload": {"id": UPLOAD, "kind": upload_kind, "mime": mime, "storage_path": PATH, "exam_id": EXAM,
                   "booking_id": BOOKING, "batch_id": None},
        "papers": [{"paper_id": PAPER, "page_count": 3,
                    "roles": [{"page": 1, "role": "cover"}, {"page": 2, "role": "answer"}, {"page": 3, "role": "answer"}],
                    "areas": [{"page": 2, "x": 0.1, "y": 0.2, "w": 0.3, "h": 0.05}]}],
        "copies": {synth.CODE_A: {"copy_id": COPY, "paper_id": PAPER, "booking_id": BOOKING, "page_count": 5}},
    }


class FakeClient:
    """Records every call. `data` is the upload's bytes; `beats` answers heartbeats; `record` answers record_pages."""

    def __init__(self, jobs=(), data=b"", record=None, beats=True, on_download=None):
        self.jobs = list(jobs)
        self.data = data
        self.record = record or {"ok": True, "pages": 0}
        self.beats = beats
        self.on_download = on_download
        self.calls = []
        self.stored = {}
        self.lock = threading.Lock()

    def _log(self, *call):
        with self.lock:
            self.calls.append(call)

    def claim(self, worker_id):
        self._log("claim", worker_id)
        return self.jobs.pop(0) if self.jobs else None

    def heartbeat(self, job_id, *, worker, attempt):
        self._log("heartbeat", job_id, worker, attempt)
        return self.beats

    def download(self, bucket, path):
        self._log("download", bucket, path)
        if self.on_download:
            self.on_download(self)
        return self.data

    def upload(self, bucket, path, data, content_type):
        self._log("upload", bucket, path, content_type)
        self.stored[path] = data

    def record_pages(self, job_id, pages, *, worker, attempt, sha256):
        self._log("record_pages", job_id, pages, worker, attempt, sha256)
        return self.record

    def finish(self, job_id, ok, error=None, *, worker, attempt):
        self._log("finish", job_id, ok, error, worker, attempt)
        return {"ok": True, "state": "done" if ok else "queued"}

    def named(self, name):
        return [c for c in self.calls if c[0] == name]


def fake_pages(n=2):
    def iter_prepare(data, kind, mime, ctx):
        for i in range(n):
            yield pipeline.PreparedPage(source_index=i, code=synth.CODE_A, copy_page=i + 2, blank=False,
                                        quality=Quality(sharpness=120.0, brightness=200.0, cut_off=False, flags=[]),
                                        rotation=0, full=b"full-%d" % i, marking=b"marking-%d" % i if i == 0 else None)
    return iter_prepare


def test_job_context_from_claim():
    ctx = main.job_context(claimed())
    assert ctx.copies[synth.CODE_A] == pipeline.CopyRef(copy_id=COPY, paper_id=PAPER, booking_id=BOOKING, page_count=5)
    layout = ctx.papers[PAPER]
    assert layout.page_count == 3 and layout.roles == {1: "cover", 2: "answer", 3: "answer"}
    assert layout.areas == [pipeline.Area(page=2, x=0.1, y=0.2, w=0.3, h=0.05)]


def test_prepare_job_stores_pictures_and_records_pages():
    client = FakeClient(data=synth.fixture_bytes("copy-a.pdf"), record={"ok": True, "pages": 5})
    assert main.process(client, "w-1", claimed(attempts=2)) == "done"

    assert client.named("download") == [("download", "script-uploads", PATH)]
    (_, job_id, pages, worker, attempt, sha256), = client.named("record_pages")
    assert (job_id, worker, attempt) == (7, "w-1", 2)
    assert sha256 == hashlib.sha256(synth.fixture_bytes("copy-a.pdf")).hexdigest()
    assert [(p["source_index"], p["code"], p["copy_page"]) for p in pages] == [(i, synth.CODE_A, i + 1) for i in range(5)]
    for p in pages:
        assert p["full_path"] == f"{EXAM}/{UPLOAD}/{p['source_index']}-full.jpg"
        assert set(p["quality"]) == {"sharpness", "brightness", "cut_off", "flags"} and p["blank"] is False
        assert p["rotation"] == 0
        assert client.stored[p["full_path"]][:2] == b"\xff\xd8"
    # The cover is not an answer page, so it has no marking picture; the answer and spare pages do.
    assert pages[0]["marking_path"] is None
    assert [p["marking_path"] for p in pages[1:]] == [f"{EXAM}/{UPLOAD}/{i}-marking.jpg" for i in range(1, 5)]
    assert all(client.stored[p["marking_path"]][:2] == b"\xff\xd8" for p in pages[1:])
    assert all(c[1] == "script-pages" and c[3] == "image/jpeg" for c in client.named("upload"))
    assert client.named("finish") == [("finish", 7, True, None, "w-1", 2)]


def test_unreadable_file_finishes_unreadable():
    client = FakeClient(data=b"not a pdf at all")
    assert main.process(client, "w-1", claimed()) == "queued"
    assert client.named("record_pages") == []
    assert client.named("finish") == [("finish", 7, False, "unreadable", "w-1", 1)]


def test_other_errors_finish_with_class_name_only():
    def boom(_):
        raise RuntimeError(f"cannot open {PATH}")

    client = FakeClient(on_download=boom)
    main.process(client, "w-1", claimed())
    assert client.named("finish") == [("finish", 7, False, "RuntimeError", "w-1", 1)]


def test_record_refused_is_a_failure(monkeypatch):
    monkeypatch.setattr(pipeline, "iter_prepare", fake_pages())
    client = FakeClient(record={"ok": False, "code": "invalid_input"})
    main.process(client, "w-1", claimed())
    assert client.named("finish") == [("finish", 7, False, "RecordRefused", "w-1", 1)]


def test_conflict_on_record_does_not_finish(monkeypatch):
    monkeypatch.setattr(pipeline, "iter_prepare", fake_pages())
    client = FakeClient(record={"ok": False, "code": "conflict"})
    assert main.process(client, "w-1", claimed()) == "lost"
    assert client.named("finish") == []


def test_changed_original_is_a_failure_not_a_lost_job(monkeypatch):
    monkeypatch.setattr(pipeline, "iter_prepare", fake_pages())
    client = FakeClient(data=b"other bytes", record={"ok": False, "code": "conflict", "reason": "sha256_mismatch"})
    assert main.process(client, "w-1", claimed()) == "queued"
    (_, _, _, _, _, sha256), = client.named("record_pages")
    assert sha256 == hashlib.sha256(b"other bytes").hexdigest()
    assert client.named("finish") == [("finish", 7, False, "OriginalChanged", "w-1", 1)]


def test_lost_lock_stops_before_recording(monkeypatch):
    monkeypatch.setattr(pipeline, "iter_prepare", fake_pages(3))
    client = FakeClient(beats=False, on_download=lambda c: time.sleep(0.3))
    assert main.process(client, "w-1", claimed(), heartbeat_seconds=0.05) == "lost"
    assert client.named("heartbeat")[0] == ("heartbeat", 7, "w-1", 1)
    assert client.named("upload") == [] and client.named("record_pages") == [] and client.named("finish") == []


def test_heartbeat_keeps_a_long_job_alive(monkeypatch):
    monkeypatch.setattr(pipeline, "iter_prepare", fake_pages())
    client = FakeClient(on_download=lambda c: time.sleep(0.35))
    assert main.process(client, "w-1", claimed(attempts=3), heartbeat_seconds=0.1) == "done"
    beats = client.named("heartbeat")
    assert len(beats) >= 2 and set(beats) == {("heartbeat", 7, "w-1", 3)}
    assert main.HEARTBEAT_SECONDS <= 60


def test_page_without_marking_picture_records_null(monkeypatch):
    monkeypatch.setattr(pipeline, "iter_prepare", fake_pages())
    client = FakeClient()
    main.process(client, "w-1", claimed())
    (_, _, pages, _, _, _), = client.named("record_pages")
    assert [p["marking_path"] for p in pages] == [f"{EXAM}/{UPLOAD}/0-marking.jpg", None]
    assert f"{EXAM}/{UPLOAD}/1-marking.jpg" not in client.stored


def test_remask_jobs_are_not_run_yet():
    client = FakeClient()
    main.process(client, "w-1", claimed(kind="remask"))
    assert client.named("download") == []
    assert client.named("finish") == [("finish", 7, False, "UnsupportedJob", "w-1", 1)]


def test_logs_carry_ids_counts_and_timings_only(monkeypatch, caplog):
    monkeypatch.setattr(pipeline, "iter_prepare", fake_pages())
    caplog.set_level(logging.DEBUG, logger="processor")
    main.process(FakeClient(), "w-1", claimed())
    main.process(FakeClient(data=b"broken"), "w-1", claimed(job_id=8))
    text = "\n".join(r.getMessage() for r in caplog.records)
    assert "7" in text and UPLOAD in text and "2 pages" in text
    for secret in (PATH, synth.CODE_A, BOOKING, COPY, "home/"):
        assert secret not in text


def test_request_urls_are_not_logged():
    main.configure_logging()
    for name in ("httpx", "httpcore"):
        assert not logging.getLogger(name).isEnabledFor(logging.INFO)
    assert logging.getLogger("processor").isEnabledFor(logging.INFO)


def test_run_once_with_nothing_to_do_returns():
    client = FakeClient()
    started = time.monotonic()
    assert main.run(client, "w-1", once=True) == 0
    assert time.monotonic() - started < 1 and client.named("claim") == [("claim", "w-1")]


def test_run_once_runs_one_job(monkeypatch):
    monkeypatch.setattr(pipeline, "iter_prepare", fake_pages())
    client = FakeClient(jobs=[claimed(job_id=1), claimed(job_id=2)])
    assert main.run(client, "w-1", once=True) == 1
    assert [c[1] for c in client.named("finish")] == [1]


def test_run_waits_two_seconds_when_idle():
    assert main.IDLE_SECONDS == 2
    stop = threading.Event()
    client = FakeClient()
    threading.Timer(0.3, stop.set).start()
    started = time.monotonic()
    assert main.run(client, "w-1", stop=stop) == 0
    assert time.monotonic() - started < 1.5 and len(client.named("claim")) == 1


@pytest.mark.skipif(threading.current_thread() is not threading.main_thread(), reason="signals need the main thread")
def test_sigterm_stops_after_the_current_job(monkeypatch):
    monkeypatch.setattr(pipeline, "iter_prepare", fake_pages())
    client = FakeClient(jobs=[claimed(job_id=1), claimed(job_id=2)], on_download=lambda c: signal.raise_signal(signal.SIGTERM))
    before = signal.getsignal(signal.SIGTERM)
    assert main.run(client, "w-1") == 1
    assert [c[1] for c in client.named("finish")] == [1]
    assert signal.getsignal(signal.SIGTERM) is before
