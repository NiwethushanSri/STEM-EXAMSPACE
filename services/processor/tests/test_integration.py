"""The whole server against the local Supabase: a home candidate's PDF of their 1A copy (fixture copy A) goes in,
pictures and a received submission come out.

Seeds through the service key an exam, a paper version, a paid home booking with copy A's code, a submitted
submission and an upload of copy-a.pdf with a queued prepare job; runs main.run(once=True); checks the pages,
the pictures in script-pages, the script and the submission. Skipped when SUPABASE_URL is unset. Everything it adds
is removed afterwards, and rows left by an interrupted run (its exams are titled TITLE) are removed first, so it
can run again and again. Its job is due in the year 2000, so it is claimed before any job left by other work.
"""
import os
import uuid
from datetime import datetime, timedelta, timezone

import httpx
import pytest

import synth
from processor import main, supa

pytestmark = pytest.mark.skipif(not os.environ.get("SUPABASE_URL"), reason="needs the local Supabase (SUPABASE_URL)")

TITLE = "ZZ Processor integration"


class Rest:
    """PostgREST and Storage with the service key, for seeding and cleaning up."""

    def __init__(self):
        key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
        self.http = httpx.Client(base_url=os.environ["SUPABASE_URL"].rstrip("/"), timeout=60,
                                 headers={"apikey": key, "Authorization": f"Bearer {key}"})

    def insert(self, table, row):
        r = self.http.post(f"/rest/v1/{table}", json=row, headers={"Prefer": "return=representation"})
        assert r.status_code == 201, f"insert {table}: HTTP {r.status_code}"
        return r.json()[0]

    def select(self, table, **filters):
        r = self.http.get(f"/rest/v1/{table}", params={"select": "*", **filters})
        assert r.status_code == 200, f"select {table}: HTTP {r.status_code}"
        return r.json()

    def delete(self, table, **filters):
        r = self.http.delete(f"/rest/v1/{table}", params=filters)
        assert r.status_code in (200, 204), f"delete {table}: HTTP {r.status_code}"

    def remove(self, bucket, paths):
        if paths:
            r = self.http.request("DELETE", f"/storage/v1/object/{bucket}", json={"prefixes": list(paths)})
            assert r.status_code == 200, f"remove from {bucket}: HTTP {r.status_code}"


def in_(ids):
    return "in.(" + ",".join(ids) + ")"


def cleanup(rest: Rest, exam_id: str) -> None:
    """Removes an exam made by this test and everything hanging off it, pictures included."""
    bookings = [b["id"] for b in rest.select("bookings", exam_id=f"eq.{exam_id}")]
    scripts = [s["id"] for s in rest.select("scripts", exam_id=f"eq.{exam_id}")]
    uploads = rest.select("script_uploads", exam_id=f"eq.{exam_id}")
    pages = rest.select("script_pages", exam_id=f"eq.{exam_id}")
    rest.delete("script_exceptions", exam_id=f"eq.{exam_id}")
    if scripts:
        rest.delete("script_page_links", script_id=in_(scripts))
        rest.delete("script_versions", script_id=in_(scripts))
        rest.delete("scripts", id=in_(scripts))
    rest.delete("script_pages", exam_id=f"eq.{exam_id}")
    if uploads:
        rest.delete("processing_jobs", upload_id=in_([u["id"] for u in uploads]))
        rest.delete("script_uploads", exam_id=f"eq.{exam_id}")
    if bookings:
        rest.delete("home_submissions", booking_id=in_(bookings))
        rest.delete("paper_copies", booking_id=in_(bookings))
    rest.delete("exam_papers", exam_id=f"eq.{exam_id}")
    rest.delete("bookings", exam_id=f"eq.{exam_id}")
    subject = rest.select("exams", id=f"eq.{exam_id}")
    rest.delete("exams", id=f"eq.{exam_id}")
    if subject:
        rest.delete("subjects", id=f"eq.{subject[0]['subject_id']}")
    rest.remove("script-uploads", [u["storage_path"] for u in uploads])
    rest.remove("script-pages", [p for row in pages for p in (row["full_path"], row["marking_path"]) if p])


@pytest.fixture
def rest():
    r = Rest()
    for exam in r.select("exams", title=f"eq.{TITLE}"):
        cleanup(r, exam["id"])
    if r.select("paper_copies", code=f"eq.{synth.CODE_A}"):
        pytest.skip("copy A's code is in use by other local data")
    yield r
    r.http.close()


def test_home_pdf_is_prepared_matched_and_received(rest):
    tag = uuid.uuid4().hex[:8].upper()
    starts = datetime.now(timezone.utc) - timedelta(hours=3)
    subject = rest.insert("subjects", {"name": f"ZZ Processor {tag}", "kind": "school"})
    exam = rest.insert("exams", {
        "subject_id": subject["id"], "title": TITLE, "paper": "Paper 1", "format": "online",
        "starts_at": starts.isoformat(), "duration_minutes": 90, "price_pence": 0, "price_confirmed": True,
        "booking_deadline": starts.isoformat(), "status": "published", "exam_code": f"ZZP{tag}"})
    exam_id = exam["id"]
    try:
        paper = rest.insert("exam_papers", {
            "exam_id": exam_id, "kind": "paper", "title": "Question paper", "version": 1,
            "storage_path": f"{exam_id}/{uuid.uuid4()}.pdf", "page_count": 3, "byte_size": 1000})
        booking = rest.insert("bookings", {"exam_id": exam_id, "status": "paid", "amount_pence": 0, "sitting": "home"})
        copy = rest.insert("paper_copies", {"code": synth.CODE_A, "booking_id": booking["id"], "paper_id": paper["id"],
                                            "page_count": synth.CODES["pages"]["copy-a.pdf"]})
        submission = rest.insert("home_submissions", {"booking_id": booking["id"], "seq": 1, "state": "checking",
                                                      "submitted_at": datetime.now(timezone.utc).isoformat()})
        data = synth.fixture_bytes("copy-a.pdf")
        upload_id = str(uuid.uuid4())
        path = f"home/{booking['id']}/{upload_id}.pdf"
        r = rest.http.post(f"/storage/v1/object/script-uploads/{path}", content=data,
                           headers={"Content-Type": "application/pdf"})
        assert r.status_code == 200, f"store upload: HTTP {r.status_code}"
        rest.insert("script_uploads", {
            "id": upload_id, "exam_id": exam_id, "booking_id": booking["id"], "submission_id": submission["id"],
            "kind": "home_pdf", "position": 1, "storage_path": path, "mime": "application/pdf", "byte_size": len(data),
            "state": "queued", "uploaded_by": str(uuid.uuid4())})
        job = rest.insert("processing_jobs", {"upload_id": upload_id, "kind": "prepare", "run_after": "2000-01-01T00:00:00Z"})

        with supa.Client.from_env() as client:
            assert main.run(client, f"itest-{tag}", once=True) == 1

        assert rest.select("processing_jobs", id=f"eq.{job['id']}")[0]["state"] == "done"
        assert rest.select("script_uploads", id=f"eq.{upload_id}")[0]["state"] == "processed"
        pages = sorted(rest.select("script_pages", upload_id=f"eq.{upload_id}"), key=lambda p: p["source_index"])
        assert [(p["state"], p["copy_page"], p["copy_id"], p["booking_id"]) for p in pages] == [
            ("matched", i + 1, copy["id"], booking["id"]) for i in range(5)]
        for p in pages:
            assert p["full_path"] == f"{exam_id}/{upload_id}/{p['source_index']}-full.jpg"
            assert p["marking_path"] == f"{exam_id}/{upload_id}/{p['source_index']}-marking.jpg"
            for picture in (p["full_path"], p["marking_path"]):
                got = rest.http.get(f"/storage/v1/object/script-pages/{picture}")
                assert got.status_code == 200 and got.content[:2] == b"\xff\xd8"

        sub = rest.select("home_submissions", id=f"eq.{submission['id']}")[0]
        assert sub["state"] == "received" and sub["checked_at"]
        script = rest.select("scripts", booking_id=f"eq.{booking['id']}")[0]
        assert (script["source"], script["state"], script["complete"], script["version"]) == ("home", "verified", True, 1)
        assert script["number"] == f"S-ZZP{tag}-0001"
        links = rest.select("script_page_links", script_id=f"eq.{script['id']}")
        assert sorted(link["copy_page"] for link in links) == [1, 2, 3, 4, 5]
        assert rest.select("script_exceptions", exam_id=f"eq.{exam_id}") == []
    finally:
        cleanup(rest, exam_id)
