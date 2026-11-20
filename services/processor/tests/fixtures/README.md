# Test fixtures

Generated from the 1A paper builder, so the QR codes match real copies.

Regenerate from the repository root:

    deno run -A --config supabase/functions/deno.json scripts/make-script-fixtures.ts

| File | Contents |
| --- | --- |
| `copy-a.pdf` | 3-page portrait master plus 2 spare pages, code A |
| `copy-b.pdf` | same master, code B, another candidate |
| `copy-landscape.pdf` | one landscape master page, code A |
| `codes.json` | the codes and page counts above |

Image fixtures (photos, scans) are made inside the Python tests from these PDFs with OpenCV, so they are reproducible.
Real-world samples go in `services/processor/tests/real/` (git-ignored).
