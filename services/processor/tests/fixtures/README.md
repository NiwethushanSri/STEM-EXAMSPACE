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
| `two-tone.heic` | 64 × 96 HEIC, dark grey top half, light bottom half (583 bytes) |

Image fixtures (photos, scans) are made inside the Python tests from these PDFs with OpenCV, so they are reproducible.
The one exception is `two-tone.heic`: the processor installs pi-heif, which only decodes, so this small HEIC was
written once (2026-11-20) with pillow-heif 1.8.1 and is committed for `test_heic_photo_loads`.
Real-world samples go in `services/processor/tests/real/` (git-ignored).
