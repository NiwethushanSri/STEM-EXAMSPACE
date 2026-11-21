"""Files for the web app's browser tests (apps/web/e2e/scripts-*.spec.ts), made from the committed fixture copies with
the same synthetic camera and scanner as the Python tests (tests/synth.py), so every run gets the same files.

Run inside the processing server's container, which has OpenCV and the pipeline:

    docker compose -f services/processor/docker-compose.yml exec -T processor python tests/e2e_files.py

It prints one JSON object, {file name: base64 bytes}:
  a-1.jpg ... a-5.jpg  phone photos of copy A's pages 1 to 5 on a dark table (a home candidate's answers);
  b-2.jpg              a phone photo of copy B's page 2 (a page printed for another candidate);
  batch.pdf            a scanner's PDF of copy A's pages 1 to 5, copy B's pages 1 to 5, then copy A's page 2 again.
Every page is first checked with the pipeline itself: it must read as its copy and page, with no quality flag and with
a marking picture, so the browser tests follow a family's and a centre's normal path. A photo that does not is made
again with the next seed; the run fails if none of a few seeds gives a clean page.
"""
from __future__ import annotations

import base64
import json
import sys

import synth
from processor import pipeline
from processor.pipeline import CopyRef, JobContext, PaperLayout

A, B = synth.CODE_A, synth.CODE_B
SEEDS = range(1, 9)

# The fixture paper: 3 pages of its own, every one an answer page, and 2 spare pages per copy.
CTX = JobContext(
    copies={c: CopyRef(copy_id=f"copy-{c}", paper_id="paper", booking_id=f"booking-{c}", page_count=5) for c in (A, B)},
    papers={"paper": PaperLayout(page_count=3, roles={1: "answer", 2: "answer", 3: "answer"}, areas=[])},
)


def clean(p: pipeline.PreparedPage, code: str, page: int) -> bool:
    return (p.code, p.copy_page) == (code, page) and not p.quality.flags and not p.quality.cut_off and p.marking is not None


def photo(name: str, code: str, index: int) -> bytes:
    """A phone photo of page index + 1 of a fixture copy that the pipeline reads cleanly."""
    page = synth.render(name, index)
    for seed in SEEDS:
        img, _ = synth.photo(page, angle=(seed % 5) - 2.0, skew=0.03, seed=100 * index + seed)
        data = synth.jpeg(img)
        found = pipeline.prepare(data, "home_photo", "image/jpeg", CTX)
        if len(found) == 1 and clean(found[0], code, index + 1):
            return data
    raise SystemExit(f"no clean photo of {name} page {index + 1}")


def batch() -> bytes:
    """A scanner's PDF whose every page the pipeline reads cleanly: copy A 1-5, copy B 1-5, copy A page 2 again."""
    want = [("copy-a.pdf", A, i) for i in range(5)] + [("copy-b.pdf", B, i) for i in range(5)] + [("copy-a.pdf", A, 1)]
    for seed in SEEDS:
        pages = [synth.scan(synth.render(name, i), tilt=0.4, seed=seed * 50 + n) for n, (name, _, i) in enumerate(want)]
        data = synth.scan_pdf(pages)
        found = pipeline.prepare(data, "scan_file", "application/pdf", CTX)
        if len(found) == len(want) and all(clean(p, code, i + 1) for p, (_, code, i) in zip(found, want)):
            return data
    raise SystemExit("no clean scan batch")


def main() -> None:
    files = {f"a-{i + 1}.jpg": photo("copy-a.pdf", A, i) for i in range(5)}
    files["b-2.jpg"] = photo("copy-b.pdf", B, 1)
    files["batch.pdf"] = batch()
    json.dump({k: base64.b64encode(v).decode("ascii") for k, v in files.items()}, sys.stdout)


if __name__ == "__main__":
    main()
