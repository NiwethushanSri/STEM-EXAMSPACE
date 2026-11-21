"""main.run and main.process against a fake Supabase client: what is stored, recorded and finished for a job."""
import hashlib
import io
import logging
import signal
import threading
import time

import numpy as np
import pytest
from PIL import Image

import synth
from processor import main, pipeline, supa
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
    """Records every call. `data` is the upload's bytes; `beats` answers heartbeats; `record` answers record_pages;
    `discarded` is what script_discarded_take lists (each item taken once); `remove_error` is raised by remove."""

    def __init__(self, jobs=(), data=b"", record=None, beats=True, on_download=None, discarded=(), remove_error=None,
                 pictures=None, remasked=None):
        self.jobs = list(jobs)
        self.data = data
        self.record = record or {"ok": True, "pages": 0}
        self.pictures = dict(pictures or {})  # script-pages objects already stored, by path
        self.remasked = remasked or {"ok": True, "pages": 0}
        self.beats = beats
        self.on_download = on_download
        self.discarded = list(discarded)
        self.remove_error = remove_error
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
        return self.pictures[path] if bucket == "script-pages" else self.data

    def upload(self, bucket, path, data, content_type):
        self._log("upload", bucket, path, content_type)
        self.stored[path] = data

    def record_pages(self, job_id, pages, *, worker, attempt, sha256):
        self._log("record_pages", job_id, pages, worker, attempt, sha256)
        return self.record

    def record_remask(self, job_id, pages, *, worker, attempt):
        self._log("record_remask", job_id, pages, worker, attempt)
        return self.remasked

    def finish(self, job_id, ok, error=None, *, worker, attempt):
        self._log("finish", job_id, ok, error, worker, attempt)
        return {"ok": True, "state": "done" if ok else "queued"}

    def discarded_take(self, limit):
        self._log("discarded_take", limit)
        taken, self.discarded = self.discarded[:limit], self.discarded[limit:]
        return taken

    def remove(self, bucket, paths):
        self._log("remove", bucket, list(paths))
        if self.remove_error:
            raise self.remove_error

    def mark_purged(self, upload_ids):
        self._log("mark_purged", list(upload_ids))

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
        assert p["full_path"] == f"{EXAM}/{UPLOAD}/7-2/{p['source_index']}-full.jpg"  # the job's folder for this attempt
        assert set(p["quality"]) == {"sharpness", "brightness", "cut_off", "flags"} and p["blank"] is False
        assert p["rotation"] == 0
        assert client.stored[p["full_path"]][:2] == b"\xff\xd8"
    # The cover is not an answer page, so it has no marking picture; the answer and spare pages do.
    assert pages[0]["marking_path"] is None
    assert [p["marking_path"] for p in pages[1:]] == [f"{EXAM}/{UPLOAD}/7-2/{i}-marking.jpg" for i in range(1, 5)]
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


def test_changed_original_stores_no_picture(monkeypatch):
    monkeypatch.setattr(pipeline, "iter_prepare", fake_pages())
    job = claimed()
    job["upload"]["sha256"] = hashlib.sha256(b"the original as first recorded").hexdigest()
    client = FakeClient(data=b"something else now")
    assert main.process(client, "w-1", job) == "queued"
    assert client.named("upload") == [] and client.stored == {} and client.named("record_pages") == []
    assert client.named("finish") == [("finish", 7, False, "OriginalChanged", "w-1", 1)]


def test_same_original_again_is_prepared(monkeypatch):
    monkeypatch.setattr(pipeline, "iter_prepare", fake_pages())
    job = claimed()
    job["upload"]["sha256"] = hashlib.sha256(b"same bytes").hexdigest()
    client = FakeClient(data=b"same bytes")
    assert main.process(client, "w-1", job) == "done"
    assert len(client.named("upload")) == 3


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
    assert [p["marking_path"] for p in pages] == [f"{EXAM}/{UPLOAD}/7-1/0-marking.jpg", None]
    assert f"{EXAM}/{UPLOAD}/7-1/1-marking.jpg" not in client.stored


def test_page_paths_are_in_the_folder_of_the_job_and_attempt():
    upload = claimed()["upload"]
    assert main.page_paths(upload, 12, 2, 3) == (f"{EXAM}/{UPLOAD}/12-2/3-full.jpg", f"{EXAM}/{UPLOAD}/12-2/3-marking.jpg")


def test_a_retried_attempt_never_overwrites_the_last_attempts_pictures(monkeypatch):
    monkeypatch.setattr(pipeline, "iter_prepare", fake_pages())
    client = FakeClient()
    main.process(client, "w-1", claimed(attempts=1))
    main.process(client, "w-1", claimed(attempts=2))
    first, second = ({c[2] for c in client.named("upload") if f"/7-{a}/" in c[2]} for a in (1, 2))
    assert first and second and first.isdisjoint(second)


def test_a_rerun_never_overwrites_an_earlier_runs_pictures(monkeypatch):
    monkeypatch.setattr(pipeline, "iter_prepare", fake_pages())
    client = FakeClient()
    main.process(client, "w-1", claimed(job_id=7))
    main.process(client, "w-1", claimed(job_id=8))
    first, second = ({c[2] for c in client.named("upload") if f"/{j}-1/" in c[2]} for j in (7, 8))
    assert first and second and first.isdisjoint(second)
    assert len(client.named("upload")) == len(first) + len(second)


# Remask jobs ---------------------------------------------------------------------------------------------------

FULL_0, FULL_1 = f"{EXAM}/{UPLOAD}/5/0-full.jpg", f"{EXAM}/{UPLOAD}/5/1-full.jpg"


def remask_claim(job_id=9, attempts=1):
    """A remask job's claim: the file's answer pages, each with what its marking picture is made from."""
    job = claimed(kind="remask", attempts=attempts, job_id=job_id)
    job["papers"], job["copies"] = [], {}
    job["pages"] = [
        {"page_id": "page-0", "source_index": 0, "full_path": FULL_0, "rotation": 90, "turn": 90, "code": synth.CODE_A,
         "copy_page": 2, "answer": True, "provable": True, "confirmed": False, "key": "k0",
         "paper_areas": [{"x": 0.1, "y": 0.2, "w": 0.3, "h": 0.05}], "staff_areas": [{"x": 0.5, "y": 0.1, "w": 0.2, "h": 0.1}]},
        {"page_id": "page-1", "source_index": 1, "full_path": FULL_1, "rotation": 0, "turn": 0, "code": None,
         "copy_page": None, "answer": True, "provable": False, "confirmed": True, "key": "k1", "paper_areas": [], "staff_areas": []},
    ]
    return job


def fake_remask(made):
    calls = []

    def remask(full, rotation, areas, *, staff_areas=(), code=None, copy_page=None, provable=True, confirmed=False):
        calls.append((full, rotation, areas, list(staff_areas), code, copy_page, provable, confirmed))
        return made.get(full)
    return remask, calls


def test_remask_job_makes_marking_pictures_from_the_full_pictures_only(monkeypatch):
    remask, calls = fake_remask({b"full-0": b"new-marking-0"})
    monkeypatch.setattr(pipeline, "remask", remask)
    client = FakeClient(pictures={FULL_0: b"full-0", FULL_1: b"full-1"}, remasked={"ok": True, "pages": 2})
    assert main.process(client, "w-1", remask_claim()) == "done"

    # Only the full pictures are read: the original is never downloaded, and no full picture is written.
    assert client.named("download") == [("download", "script-pages", FULL_0), ("download", "script-pages", FULL_1)]
    assert client.named("upload") == [("upload", "script-pages", f"{EXAM}/{UPLOAD}/9-1/0-marking.jpg", "image/jpeg")]
    assert client.stored == {f"{EXAM}/{UPLOAD}/9-1/0-marking.jpg": b"new-marking-0"}
    assert client.pictures == {FULL_0: b"full-0", FULL_1: b"full-1"}
    (_, job_id, pages, worker, attempt), = client.named("record_remask")
    assert (job_id, worker, attempt) == (9, "w-1", 1)
    assert pages == [
        {"page_id": "page-0", "marking_path": f"{EXAM}/{UPLOAD}/9-1/0-marking.jpg", "rotation": 90, "key": "k0"},
        {"page_id": "page-1", "marking_path": None, "rotation": 0, "key": "k1"},
    ]
    assert client.named("record_pages") == []
    assert client.named("finish") == [("finish", 9, True, None, "w-1", 1)]


def test_remask_passes_the_turn_and_every_area(monkeypatch):
    remask, calls = fake_remask({})
    monkeypatch.setattr(pipeline, "remask", remask)
    main.process(FakeClient(pictures={FULL_0: b"full-0", FULL_1: b"full-1"}), "w-1", remask_claim())
    assert calls[0] == (b"full-0", 90, [pipeline.Area(page=2, x=0.1, y=0.2, w=0.3, h=0.05)],
                        [pipeline.Area(page=0, x=0.5, y=0.1, w=0.2, h=0.1)], synth.CODE_A, 2, True, False)
    assert calls[1] == (b"full-1", 0, [], [], None, None, False, True)


def test_remask_with_a_real_page_hides_the_band():
    [page] = [p for p in pipeline.prepare(synth.fixture_bytes("copy-a.pdf"), "scan_file", "application/pdf",
                                          main.job_context(claimed())) if p.copy_page == 2]
    job = remask_claim()
    job["pages"] = [dict(job["pages"][0], turn=0, rotation=0, staff_areas=[])]
    client = FakeClient(pictures={FULL_0: page.full})
    assert main.process(client, "w-1", job) == "done"
    marking = np.asarray(Image.open(io.BytesIO(client.stored[f"{EXAM}/{UPLOAD}/9-1/0-marking.jpg"])).convert("RGB"))
    full = np.asarray(Image.open(io.BytesIO(page.full)).convert("RGB"))
    assert full[:90].min() < 100 and marking[:90].min() > 225 and marking[-300:].min() < 100


def test_remask_conflict_is_a_lost_job(monkeypatch):
    remask, _ = fake_remask({})
    monkeypatch.setattr(pipeline, "remask", remask)
    client = FakeClient(pictures={FULL_0: b"full-0", FULL_1: b"full-1"}, remasked={"ok": False, "code": "conflict"})
    assert main.process(client, "w-1", remask_claim()) == "lost"
    assert client.named("finish") == []


def test_remask_refused_is_a_failure(monkeypatch):
    remask, _ = fake_remask({})
    monkeypatch.setattr(pipeline, "remask", remask)
    client = FakeClient(pictures={FULL_0: b"full-0", FULL_1: b"full-1"}, remasked={"ok": False, "code": "invalid_input"})
    main.process(client, "w-1", remask_claim())
    assert client.named("finish") == [("finish", 9, False, "RecordRefused", "w-1", 1)]


def test_remask_lost_lock_stops_before_recording(monkeypatch):
    remask, _ = fake_remask({b"full-0": b"m"})
    monkeypatch.setattr(pipeline, "remask", remask)
    client = FakeClient(beats=False, pictures={FULL_0: b"full-0", FULL_1: b"full-1"}, on_download=lambda c: time.sleep(0.3))
    assert main.process(client, "w-1", remask_claim(), heartbeat_seconds=0.05) == "lost"
    assert client.named("record_remask") == [] and client.named("finish") == []


def test_other_job_kinds_are_not_run():
    client = FakeClient()
    main.process(client, "w-1", claimed(kind="archive"))
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


def test_run_survives_an_unexpected_error(monkeypatch, caplog):
    """An answer process() does not expect (a finish result that is not an object, a claim without its upload)
    fails that job with the error's class name only, and the worker carries on."""
    monkeypatch.setattr(pipeline, "iter_prepare", fake_pages())
    caplog.set_level(logging.DEBUG, logger="processor")
    stop = threading.Event()

    class Odd(FakeClient):
        def claim(self, worker_id):
            job = super().claim(worker_id)
            if job is None:
                stop.set()
            return job

        def finish(self, job_id, ok, error=None, *, worker, attempt):
            result = super().finish(job_id, ok, error, worker=worker, attempt=attempt)
            return ["not", "an", "object"] if job_id == 1 and ok else result

    broken = {"job": {"id": 2, "kind": "prepare", "attempts": 1}}
    client = Odd(jobs=[claimed(job_id=1), broken, claimed(job_id=3)])
    assert main.run(client, "w-1", stop=stop, idle_seconds=0.01) == 3
    finishes = client.named("finish")
    assert ("finish", 1, False, "AttributeError", "w-1", 1) in finishes
    assert ("finish", 2, False, "KeyError", "w-1", 1) in finishes
    assert ("finish", 3, True, None, "w-1", 1) in finishes
    text = "\n".join(r.getMessage() for r in caplog.records)
    assert "AttributeError" in text and "KeyError" in text
    for secret in (PATH, "upload'", "not", BOOKING):
        assert secret not in text


@pytest.mark.skipif(threading.current_thread() is not threading.main_thread(), reason="signals need the main thread")
def test_sigterm_stops_after_the_current_job(monkeypatch):
    monkeypatch.setattr(pipeline, "iter_prepare", fake_pages())
    client = FakeClient(jobs=[claimed(job_id=1), claimed(job_id=2)], on_download=lambda c: signal.raise_signal(signal.SIGTERM))
    before = signal.getsignal(signal.SIGTERM)
    assert main.run(client, "w-1") == 1
    assert [c[1] for c in client.named("finish")] == [1]
    assert signal.getsignal(signal.SIGTERM) is before


# Discarded draft files ------------------------------------------------------------------------------------------

DISCARDED = [{"id": "up-a", "storage_path": "home/booking-1/up-a.jpg"}, {"id": "up-b", "storage_path": "home/booking-1/up-b.pdf"}]


def test_cleanup_removes_discarded_files_then_marks_them_purged():
    client = FakeClient(discarded=DISCARDED)
    assert main.cleanup(client) == 2
    assert [c[0] for c in client.calls] == ["discarded_take", "remove", "mark_purged"]
    assert client.named("discarded_take") == [("discarded_take", main.CLEANUP_BATCH)]
    assert client.named("remove") == [("remove", "script-uploads", ["home/booking-1/up-a.jpg", "home/booking-1/up-b.pdf"])]
    assert client.named("mark_purged") == [("mark_purged", ["up-a", "up-b"])]


def test_cleanup_with_nothing_discarded_touches_nothing():
    client = FakeClient()
    assert main.cleanup(client) == 0
    assert client.named("remove") == [] and client.named("mark_purged") == []


def test_cleanup_marks_nothing_when_removing_fails():
    client = FakeClient(discarded=DISCARDED, remove_error=supa.SupabaseError("remove: HTTP 500"))
    with pytest.raises(supa.SupabaseError):
        main.cleanup(client)
    assert client.named("mark_purged") == []


def test_cleanup_only_ever_removes_from_script_uploads():
    client = FakeClient(discarded=DISCARDED)
    main.cleanup(client)
    assert {c[1] for c in client.named("remove")} == {"script-uploads"}
    assert 1 <= main.CLEANUP_BATCH <= 1000


def test_run_cleans_up_at_most_once_a_minute():
    assert main.CLEANUP_SECONDS == 60
    stop = threading.Event()
    client = FakeClient(discarded=DISCARDED)
    threading.Timer(0.3, stop.set).start()
    main.run(client, "w-1", stop=stop, idle_seconds=0.01)
    assert len(client.named("claim")) > 3
    assert len(client.named("discarded_take")) == 1


def test_run_cleans_up_again_after_the_interval():
    stop = threading.Event()
    client = FakeClient()
    threading.Timer(0.35, stop.set).start()
    main.run(client, "w-1", stop=stop, idle_seconds=0.01, cleanup_seconds=0.1)
    assert 2 <= len(client.named("discarded_take")) <= 5


def test_run_cleans_up_between_jobs_never_during_one(monkeypatch):
    monkeypatch.setattr(pipeline, "iter_prepare", fake_pages())
    stop = threading.Event()

    class Ending(FakeClient):
        def claim(self, worker_id):
            job = super().claim(worker_id)
            if job is None:
                stop.set()
            return job

    client = Ending(jobs=[claimed(job_id=1), claimed(job_id=2)])
    main.run(client, "w-1", stop=stop, idle_seconds=0.01, cleanup_seconds=0)
    names = [c[0] for c in client.calls if c[0] in ("claim", "finish", "discarded_take")]
    assert names[:2] == ["discarded_take", "claim"]
    # Between a claim that returned a job and that job's finish there is no cleanup; between two jobs there is.
    first, second = names.index("finish"), len(names) - 1 - names[::-1].index("finish")
    assert "discarded_take" not in names[1:first] and "discarded_take" in names[first:second]


def test_run_survives_a_failed_cleanup_and_logs_no_paths(monkeypatch, caplog):
    monkeypatch.setattr(pipeline, "iter_prepare", fake_pages())
    caplog.set_level(logging.DEBUG, logger="processor")
    client = FakeClient(jobs=[claimed(job_id=1)], discarded=DISCARDED,
                        remove_error=supa.SupabaseError("remove: HTTP 500"))
    assert main.run(client, "w-1", once=True) == 1
    assert client.named("finish") == [("finish", 1, True, None, "w-1", 1)]
    text = "\n".join(r.getMessage() for r in caplog.records)
    assert "SupabaseError" in text
    for secret in ("home/", "up-a", "booking-1"):
        assert secret not in text


def test_cleanup_logs_the_count_only(caplog):
    caplog.set_level(logging.DEBUG, logger="processor")
    main.cleanup(FakeClient(discarded=DISCARDED))
    text = "\n".join(r.getMessage() for r in caplog.records)
    assert "2" in text
    for secret in ("home/", "up-a", "up-b", "booking-1"):
        assert secret not in text
