"""Page pictures for the web app's staff marking browser test (apps/web/e2e/marking-admin.spec.ts): the full and marking
pictures the pipeline itself makes of pages 1 to 3 of the committed fixture copies, so the test can seed two verified
scripts whose pages a remask proves again, as it proves a real scan's.

Run inside the processing server's container, which has OpenCV and the pipeline:

    docker compose -f services/processor/docker-compose.yml exec -T processor python tests/e2e_pages.py

It prints one JSON object, {"a": [...], "b": [...]}: for copy A and copy B, pages 1 to 3 in order, each
{"full": base64 JPEG, "marking": base64 JPEG}. Every page is a scanner's page read with the pipeline (as e2e_files.py
does): it must come out upright as its copy and page, with no quality flag and with a marking picture. A scan that does
not is made again with the next seed; the run fails if none of a few seeds gives a clean page.
"""
from __future__ import annotations

import base64
import json
import sys

import synth
from e2e_files import CTX, SEEDS, clean
from processor import pipeline

PAGES = 3


def pictures(name: str, code: str, index: int) -> dict[str, str]:
    """The full and marking pictures prepare makes of a clean scan of page index + 1 of a fixture copy."""
    for seed in SEEDS:
        data = synth.scan_pdf([synth.scan(synth.render(name, index), tilt=0.4, seed=seed * 50 + index)])
        found = pipeline.prepare(data, "scan_file", "application/pdf", CTX)
        if len(found) == 1 and clean(found[0], code, index + 1) and found[0].rotation == 0:
            page = found[0]
            return {"full": base64.b64encode(page.full).decode("ascii"), "marking": base64.b64encode(page.marking).decode("ascii")}
    raise SystemExit(f"no clean scan of {name} page {index + 1}")


def main() -> None:
    copies = (("a", "copy-a.pdf", synth.CODE_A), ("b", "copy-b.pdf", synth.CODE_B))
    json.dump({key: [pictures(name, code, i) for i in range(PAGES)] for key, name, code in copies}, sys.stdout)


if __name__ == "__main__":
    main()
