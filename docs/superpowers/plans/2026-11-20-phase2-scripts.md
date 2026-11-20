# Phase 2: Getting scripts into the system — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Home candidates sit with a countdown and a parent's acknowledgement, then photograph or upload their pages and get a receipt; centre staff record sheets and custody and upload scanner batches; a processing server turns every upload into clean page pictures matched to candidates by the 1A QR codes; anything uncertain goes to an exception queue; every candidate's pages become one verified script.

**Architecture:** Postgres (Supabase) holds uploads, pages, scripts, versions, jobs, exceptions, collection and custody, with every rule in `security definer` SQL functions. Families and staff upload straight to a private bucket with resumable uploads, after a SQL function has created the upload row whose exact path the storage policy allows. A Python processing server in Docker claims jobs through a SQL function, prepares pages (render, find page, straighten, read code, blank and quality checks, marking picture without the name band and hidden areas), stores the pictures, and hands the page list back to one SQL function that matches pages and assembles scripts in a single transaction. The web app has no service-role key; only the processing server and Edge Functions hold it.

**Tech Stack:** Supabase (Postgres 17, pg_cron, pg_net, Storage with resumable uploads, Edge Functions on Deno), pgTAP; Python 3.12 in Docker (`python:3.12-slim`) with pypdfium2, zxing-cpp, opencv-python-headless, Pillow, pillow-heif, numpy, httpx, pytest; Next.js 16, React 19, tus-js-client, pdf.js, pdf-lib, Vitest, Playwright.

**Spec:** `docs/superpowers/specs/2026-11-20-web-platform-design.md`, section 5 (approved 2026-11-20). Master plan: `docs/owner/2026-11-functional-specification.pdf`, sections 11 to 16. Builds on Phase 1A (`docs/superpowers/specs/2026-11-17-phase1-papers-design.md`, branch `phase1-papers`, not yet merged or deployed).

**Not in this plan:** automatic deletion of scripts 12 months after results (spec §5.8) needs published results, so it is planned with Phase 4; the "Name visible" button belongs to the marking screen (Phase 3), although its exception kind is created here; the Supabase Pro plan, the host account and real test files are owner actions (spec §16).

## Global Constraints

- Row-level security on every new table; writes only through `security definer` SQL functions with `set search_path = ''`; `revoke execute ... from public, anon` then explicit grants; an `audit_log` row (with `reason` where the action asks for one) in the same transaction as every staff change; no personal data in logs, job errors or exception details.
- The web app never holds the service-role key. Only Edge Functions and the processing server use it. Functions meant for the processing server are granted to `service_role` only.
- Every test runs against the local Supabase in Docker. Never run `db:push`, `fn:deploy`, `vercel`, `fly deploy` or `supabase config push` while executing this plan. Never use `--remote` or `--linked`.
- Work on branch `phase2-scripts` (already created from `phase1-papers`), one commit per task, messages ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Times are `timestamptz`, shown in `Europe/London`; the database clock decides every window. Functions with a time rule take `p_now timestamptz default null` for tests, as in 1A (`public.paper_clock`).
- Exam finish = `starts_at + duration_minutes`. Home uploads: open from the start; on time until finish + 2 hours; late (flagged, admin decides) until finish + 24 hours; refused after that.
- Who may upload a home script: the student or a linked parent, for a booking with sitting `home` and status `paid` or `cancel_requested`.
- File limits: home photo ≤ 25 MB (`image/jpeg`, `image/png`, `image/heic`, `image/heif`); home PDF ≤ 100 MB; at most 60 files per home submission; scanner file ≤ 1 GB (`application/pdf`, `image/jpeg`, `image/png`). Local `supabase/config.toml` storage limit becomes `1GiB` (local only).
- Page pictures: PDFs rendered at 200 dpi; every page normalised to A4 portrait at 1654 × 2339 px; stored as JPEG quality 85.
- Marking picture: the top 34 pt of the 841.89 pt A4 copy page (the 1A `TOP_BAND`) and every hidden area are painted white. Hidden areas are stored as fractions (0 to 1) of the A4 copy page, measured from the top-left.
- Page roles: `answer`, `cover`, `blank`, `information`. Copy pages beyond the paper's own pages (1A spare pages) are always `answer` and optional.
- QR content is exactly `SX1.<copy code>.<page>` (1A); the copy code check symbol uses 1A's mod-37 rule (`public.copy_code_valid`).
- Numbers: script `S-<exam code>-<4 digits>` (per exam, from 0001), batch `B-<exam code>-<2 digits>`, manifest `M-<exam code>-<2 digits>`.
- Processing jobs: 3 attempts in total, waiting 1 minute then 2 minutes; a `running` job whose lock is older than 15 minutes may be claimed again.
- Family statuses (exact words): "Uploading", "Checking your pages", "Received", "Needs your attention", "Submitted late", "Rejected". Prompts: "Was page {n} left blank?", "Retake page {n}". Receipt heading: "We have received your answers".
- Python: dependencies pinned in `services/processor/requirements.lock`; no AGPL or GPL libraries; all Python runs and tests in Docker.

## Review Focus

1. A phone loses signal and the family presses Submit twice: one submission, no duplicate pages. Tests: Task 6 `submit_twice_is_idempotent`, Task 4 `rerun_job_replaces_pages`.
2. A family uploads a page printed for a brother's booking: never matched to this script; an exception for staff. Test: Task 4 `home_page_from_other_booking_not_matched`.
3. A centre batch holds a page of a candidate marked absent, or booked at another centre: flagged, never matched. Test: Task 4 `centre_page_absent_or_other_centre_flagged`.
4. A phone photo taken upside down, sideways and at an angle on a dark table: still found, read and turned upright. Test: Task 3 `photo_rotated_skewed_dark_background_reads`.
5. An upload started after finish + 24 hours through the API with the page left open: refused by the database. Test: Task 6 `begin_after_late_window_refused`.

## File map

| Area | Files |
|---|---|
| Processing server | `services/processor/` (`Dockerfile`, `docker-compose.yml`, `fly.toml`, `requirements.in`, `requirements.lock`, `processor/{codes,imaging,pipeline,supa,main}.py`, `tests/`) |
| Fixtures | `scripts/make-script-fixtures.ts`, `services/processor/tests/fixtures/` (generated, committed), `services/processor/tests/real/` (git-ignored, owner's files) |
| Paper pages (DB, web) | `supabase/migrations/20261120000050_paper_page_roles.sql`, `supabase/tests/027_paper_page_roles.test.sql`, `apps/web/src/components/papers/PageRolesPanel.tsx`, `apps/web/src/lib/hidden-areas.ts` (+ test) |
| Scripts core (DB) | `supabase/migrations/20261120000051_scripts.sql`, `..052_script_matching.sql`, `supabase/tests/028_scripts.test.sql`, `029_script_matching.test.sql` |
| Home sitting and upload | `supabase/migrations/20261120000053_home_sitting.sql`, `..054_home_upload.sql`, `supabase/tests/030_home_sitting.test.sql`, `031_home_upload.test.sql`, `apps/web/src/components/scripts/{SittingPanel,HomeUpload,CameraCapture,UploadReceipt}.tsx`, `apps/web/src/lib/{sitting-state,resumable-upload,blur-check}.ts` (+ tests) |
| Notices | `supabase/migrations/20261120000055_script_notices.sql`, `supabase/tests/032_script_notices.test.sql`, `supabase/functions/script-notify/index.ts` (+ test), `supabase/functions/_shared/email.ts` |
| Centre | `supabase/migrations/20261120000056_collection_custody.sql`, `..057_scan_batches.sql`, `supabase/tests/033_collection_custody.test.sql`, `034_scan_batches.test.sql`, `apps/web/src/components/scripts/{CollectionColumn,CustodyPanel,ScanBatches}.tsx`, `apps/web/src/lib/manifest-pdf.ts` (+ test) |
| Staff screens | `supabase/migrations/20261120000058_script_resolution.sql`, `supabase/tests/035_script_resolution.test.sql`, `apps/web/src/app/admin/scripts/{page.tsx,[id]/page.tsx,exceptions/page.tsx}`, `apps/web/src/components/scripts/{ScriptList,ScriptDetail,ExceptionQueue,PageViewer}.tsx` |
| Shared | `packages/shared/src/errors.ts`, `packages/shared/src/database.types.ts`, `apps/web/e2e/scripts-*.spec.ts`, `docs/superpowers/<date written>-phase2-release-notes.md` |

---

### Task 0: Processing server skeleton and test fixtures

**Files:**
- Create: `services/processor/Dockerfile`, `docker-compose.yml`, `fly.toml`, `requirements.in`, `requirements.lock`, `processor/__init__.py`, `processor/codes.py`, `tests/test_codes.py`, `scripts/make-script-fixtures.ts`, `services/processor/tests/fixtures/README.md`
- Modify: `supabase/config.toml` (storage `file_size_limit = "1GiB"`), `.gitignore` (`services/processor/tests/real/`), root `package.json`

**Interfaces:**
- Produces: `npm run proc:test` = `docker compose -f services/processor/docker-compose.yml run --rm processor pytest -q`; `processor.codes.parse_payload(text: str) -> tuple[str, int] | None` (same regex as `apps/web/src/lib/paper-payload.ts`); `processor.codes.code_valid(code: str) -> bool` (port of `public.copy_code_valid`); fixtures listed in `tests/fixtures/README.md`.

- [ ] **Step 1: Docker image.** `Dockerfile` from `python:3.12-slim`, installs `requirements.lock` with `pip install --require-hashes`, copies `processor/` and `tests/`, default command `python -m processor.main`. `requirements.in` lists pypdfium2, zxing-cpp, opencv-python-headless, pillow, pillow-heif, numpy, httpx, pytest; lock with `pip-compile --generate-hashes` inside the image. `docker-compose.yml` service `processor` with `env_file: ../../supabase/functions/.env.test.local` and `SUPABASE_URL=http://host.docker.internal:54321`. `fly.toml`: app `stem-processor`, `primary_region = "lhr"`, one machine `shared-cpu-2x` with 2048 MB, no services/ports (it accepts no requests). Not deployed.
- [ ] **Step 2: Failing tests** in `tests/test_codes.py`: `parse_payload("SX1.0123456789.3")` returns a tuple only when the 9-character code matches `[0-9A-HJKMNP-TV-Z]{8}[0-9A-HJKMNP-TV-Z*~$=U]`; `parse_payload("SX1.ABCDEFGH*.0")` is `None`; `parse_payload("sx1...")` is `None`; `code_valid(c)` is true for codes built with the 1A algorithm in the test and false when any one character changes.
- [ ] **Step 3: Implement `processor/codes.py`.** Run `npm run proc:test`. Expected: PASS.
- [ ] **Step 4: Fixture generator.** `scripts/make-script-fixtures.ts` (Deno, imports `buildCopy` from `supabase/functions/_shared/paper/stamp.ts` and the master builders in `test_fixtures.ts`) writes to `services/processor/tests/fixtures/`: `copy-a.pdf` (3-page portrait master, 2 spare pages, code A), `copy-b.pdf` (same master, code B, another candidate), `copy-landscape.pdf` (one landscape master page), and `codes.json` (codes, page counts). Document in the README how to regenerate (`deno run -A scripts/make-script-fixtures.ts`). Image fixtures (photos, scans) are made inside the Python tests from these PDFs with OpenCV, so they are reproducible.
- [ ] **Step 5: Commit** `chore(processor): Python processing server skeleton and script fixtures`.

### Task 1: Page roles and hidden areas

**Files:**
- Create: `supabase/migrations/20261120000050_paper_page_roles.sql`, `supabase/tests/027_paper_page_roles.test.sql`, `apps/web/src/components/papers/PageRolesPanel.tsx`, `apps/web/src/lib/hidden-areas.ts`, `apps/web/src/lib/hidden-areas.test.ts`
- Modify: `apps/web/src/components/papers/PaperPanel.tsx`, `apps/web/src/app/admin/exams/[id]/actions.ts`, `packages/shared/src/errors.ts`

**Interfaces:**
- Produces:
  - enum `public.page_role ('answer','cover','blank','information')`.
  - table `public.paper_page_roles(paper_id uuid references exam_papers on delete cascade, page int check (page >= 1), role page_role not null, primary key (paper_id, page))`; a trigger on `exam_papers` insert of `kind = 'paper'` fills `answer` for pages 1..page_count, copying the previous version's role for each page number that existed there.
  - table `public.paper_hidden_areas(id uuid pk, paper_id uuid references exam_papers on delete cascade, page int check (page >= 1), x numeric, y numeric, w numeric, h numeric, created_by uuid, created_at timestamptz)`, with `0 <= x, y` and `x + w <= 1`, `y + h <= 1`, `w, h > 0`; new versions copy the previous version's areas.
  - column `exam_papers.pages_reviewed_at timestamptz`.
  - `public.set_paper_page_roles(p_paper uuid, p_roles jsonb) returns jsonb`: `p_roles` = `[{"page":1,"role":"cover"},...]` covering every page exactly once; admin only; `conflict` once any `script_pages` row references a copy of this paper (Task 2 table; guard with `to_regclass` so this migration stands alone); sets `pages_reviewed_at`; audit `paper_page_roles_set`.
  - `public.set_paper_hidden_areas(p_paper uuid, p_areas jsonb) returns jsonb`: replaces the paper's areas (`[{"page":1,"x":..,"y":..,"w":..,"h":..}]`, at most 20 per page); admin only; audit `paper_hidden_areas_set`; returns `{ok, changed_pages:int[]}` (Task 11 queues re-masking from it).
  - `public.paper_page_layout(p_paper uuid) returns jsonb`: `{pages:[{page, role}], areas:[...], reviewed_at}`; admin only.
  - web: `toFraction(rect: {x,y,w,h}, viewport: {width,height}) -> Area` and `clampArea(a: Area) -> Area` in `hidden-areas.ts`.
- Consumes: 1A `exam_papers`, `paper-copy` (`admin_preview` copy, used as the drawing surface so areas are in A4 copy-page fractions).

- [ ] **Step 1: Failing pgTAP tests** (`027`): `roles_default_answer_on_register`; `roles_copied_to_new_version`; `roles_must_cover_every_page` (missing or duplicate page → `invalid_input`); `roles_teacher_forbidden`; `areas_out_of_bounds_refused`; `areas_copied_to_new_version`; `roles_set_writes_audit`.
- [ ] **Step 2: Run** `npm run db:test:local`. Expected: 027 fails.
- [ ] **Step 3: Migration 050** as above. Run tests. Expected: PASS.
- [ ] **Step 4: Web.** `PageRolesPanel` under the paper in `PaperPanel`: thumbnails of the admin preview copy's pages (pdf.js), a role menu per page ("Answer page", "Cover", "Blank page", "Information"), and a "Hide areas" mode that draws rectangles on a page with mouse, finger or Pencil, lists them, and deletes them. Saving calls both functions through server actions. Show "Check the page roles before the release time" on the exam page while `pages_reviewed_at` is null. Unit tests for `toFraction` and `clampArea` (a rectangle dragged past the edge is clamped; a zero-size drag is ignored).
- [ ] **Step 5: Commit** `feat(papers): page roles and hidden areas per paper version`.

### Task 2: Scripts, uploads, pages and jobs (database)

**Files:**
- Create: `supabase/migrations/20261120000051_scripts.sql`, `supabase/tests/028_scripts.test.sql`

**Interfaces:**
- Produces:
  - enums: `script_source ('home','centre')`; `script_state ('receiving','checking','needs_attention','verified','ready_to_mark','marking','marked','checked','final','withdrawn','void')`; `upload_kind ('home_photo','home_pdf','scan_file')`; `upload_state ('pending','stored','discarded','queued','processing','processed','failed')`; `page_state ('matched','blank','duplicate','unmatched','rejected')`; `job_state ('queued','running','done','failed')`; `exception_kind ('no_code','unknown_code','other_exam','not_expected','duplicate','missing_pages','uncoded_family_page','mixed_versions','poor_quality','late','name_visible','processing_failed')`; `submission_state ('draft','checking','received','needs_attention','rejected')`.
  - tables:
    - `scripts(id uuid pk, booking_id uuid unique not null references bookings, exam_id uuid not null references exams, source script_source not null, number text unique not null, state script_state not null default 'receiving', version int not null default 0, complete boolean not null default false, late boolean not null default false, late_decision text check (late_decision in ('accept','reject')), received_at timestamptz, state_reason text, created_at, updated_at)`.
    - `script_versions(script_id uuid references scripts, version int, created_at, created_by uuid, reason text, primary key (script_id, version))`.
    - `script_page_links(script_id uuid, version int, copy_page int, page_id uuid references script_pages, primary key (script_id, version, copy_page))`.
    - `home_submissions(id uuid pk, booking_id uuid not null references bookings, seq int not null, replaces_all boolean not null default true, state submission_state not null default 'draft', late boolean not null default false, submitted_by uuid, submitted_at timestamptz, checked_at timestamptz, blank_confirmed int[] not null default '{}', unique (booking_id, seq))`; at most one `draft` per booking (partial unique index).
    - `scan_batches(id uuid pk, exam_id uuid not null, centre_id uuid not null references exam_centres, manifest_id uuid, number text unique not null, created_by uuid, created_at, submitted_at timestamptz)`.
    - `script_uploads(id uuid pk, exam_id uuid not null, booking_id uuid, submission_id uuid references home_submissions, batch_id uuid references scan_batches, kind upload_kind not null, position int, storage_path text unique not null, mime text not null, byte_size bigint not null, sha256 text, state upload_state not null default 'pending', uploaded_by uuid not null, created_at, stored_at)`; exactly one of `submission_id`, `batch_id` is set.
    - `script_pages(id uuid pk, upload_id uuid not null references script_uploads, source_index int not null, exam_id uuid not null, copy_id uuid references paper_copies, copy_page int, booking_id uuid references bookings, state page_state not null, blank boolean not null default false, quality jsonb not null default '{}', rotation int not null default 0 check (rotation in (0,90,180,270)), full_path text not null, marking_path text, placed_after int, created_at, unique (upload_id, source_index))`.
    - `processing_jobs(id bigint identity pk, upload_id uuid not null references script_uploads, kind text not null check (kind in ('prepare','remask')), state job_state not null default 'queued', attempts int not null default 0, run_after timestamptz not null default now(), locked_by text, locked_at timestamptz, last_error text check (char_length(last_error) <= 300), created_at, finished_at)`.
    - `script_exceptions(id uuid pk, exam_id uuid not null, kind exception_kind not null, booking_id uuid, script_id uuid, page_id uuid, upload_id uuid, details jsonb not null default '{}', state text not null default 'open' check (state in ('open','resolved')), created_at, resolved_by uuid, resolved_at timestamptz, resolution text, reason text)`.
  - storage buckets: `script-uploads` (private, 1073741824 bytes, the Global Constraints mime list) and `script-pages` (private, 10485760 bytes, `image/jpeg`). Upload paths: `home/<booking>/<upload>.<ext>`, `batch/<batch>/<upload>.<ext>`; page paths `<exam>/<upload>/<source_index>-full.jpg` and `-marking.jpg`.
  - storage policies: insert into `script-uploads` only when a `script_uploads` row with that exact `storage_path`, state `pending` and `uploaded_by = auth.uid()` exists; select on `script-uploads` for the uploader while the upload is `pending` or `stored` and for staff admins; select on `script-pages` for staff admins; no update or delete policies.
  - `public.script_number_next(p_exam uuid) returns text` (internal; advisory lock per exam).
  - `public.processing_job_claim(p_worker text, p_now timestamptz default null) returns jsonb` (service_role only): takes the oldest claimable job with `for update skip locked`, sets `running`, `attempts + 1`, returns `{job:{id,kind,attempts}, upload:{id,kind,mime,storage_path,exam_id,booking_id,batch_id}, papers:[{paper_id, page_count, roles:[...], areas:[...]}], copies:{"<code>": {"copy_id","paper_id","booking_id","page_count"}}}` for the upload's exam, or `null` when nothing is claimable.
  - `public.processing_job_finish(p_job bigint, p_ok boolean, p_error text default null, p_now timestamptz default null) returns jsonb` (service_role only): `done`; or back to `queued` with `run_after = now + attempts minutes` while `attempts < 3`; else `failed` with a `processing_failed` exception and the upload `failed`.
- Consumes: 1A `bookings`, `exam_centres`, `paper_copies`, `exam_papers`, `exams.exam_code`.

- [ ] **Step 1: Failing pgTAP tests** (`028`): `tables_have_rls`; `family_cannot_insert_rows_directly`; `storage_insert_only_for_pending_row_path` (as the uploader: allowed for its row's path, refused for any other path and for another user's row); `claim_skips_locked_jobs` (two claims in one transaction return different jobs); `claim_reclaims_after_15_minutes` (with `p_now`); `finish_retries_twice_then_fails` (third failure → `failed`, upload `failed`, one `processing_failed` exception); `claim_not_granted_to_authenticated`; `script_number_sequence_per_exam` (`S-<code>-0001`, `-0002`; another exam starts at `0001`).
- [ ] **Step 2: Run** `npm run db:test:local`. Expected: 028 fails.
- [ ] **Step 3: Migration 051.** Run tests. Expected: PASS. Regenerate `packages/shared/src/database.types.ts` from the local database.
- [ ] **Step 4: Commit** `feat(scripts): script, upload, page and job tables`.

### Task 3: Preparing pages (processing server, pure functions)

**Files:**
- Create: `services/processor/processor/imaging.py`, `services/processor/processor/pipeline.py`, `services/processor/tests/test_imaging.py`, `services/processor/tests/test_pipeline.py`, `services/processor/tests/synth.py` (test helpers that turn fixture PDFs into photos and scans)

**Interfaces:**
- Produces:
  - `imaging.A4_PX = (1654, 2339)`; `imaging.TOP_BAND_FRACTION = 34 / 841.89`.
  - `imaging.render_pdf(data: bytes, dpi: int = 200) -> Iterator[np.ndarray]` (RGB uint8; raises `UnreadableFile` for broken or password-protected PDFs).
  - `imaging.load_photo(data: bytes) -> np.ndarray` (applies EXIF orientation; JPEG, PNG, HEIC, HEIF).
  - `imaging.find_page(img) -> np.ndarray | None` (4 corners of the largest paper-like quadrilateral) and `imaging.warp_to_a4(img, quad) -> np.ndarray`.
  - `imaging.read_code(img) -> CodeRead | None`, `CodeRead(code: str, page: int, corners: np.ndarray)`; tries the full image, then the bottom third, then a 2× enlargement of the bottom-right quarter.
  - `imaging.upright(img, read: CodeRead) -> np.ndarray` (rotates by 90° steps so the code sits bottom-right, then straightens the remaining tilt from the code's corners, at most ±10°).
  - `imaging.is_blank(img) -> bool`, `imaging.quality(img) -> Quality(sharpness: float, brightness: float, cut_off: bool, flags: list[str])` with flags `blurred`, `dark`, `cut_off`; `sharpness` is the variance of the Laplacian on a 1000 px wide greyscale copy (higher is sharper) and `brightness` the mean grey level (0 to 255). Thresholds are named constants in `imaging.py` (initial: `blurred` under 60, `dark` under 90, `cut_off` when a found page touches the photo's edge within 1%), calibrated on the fixtures and later on the owner's real files.
  - `pipeline.JobContext(copies: dict[str, CopyRef], papers: dict[str, PaperLayout])`, `CopyRef(copy_id, paper_id, booking_id, page_count)`, `PaperLayout(page_count, roles: dict[int, str], areas: list[Area])`, `Area(page: int, x: float, y: float, w: float, h: float)`; Task 4 builds it from `processing_job_claim`'s result.
  - `imaging.marking_image(page: np.ndarray, areas: list[Area]) -> np.ndarray` (white top band and areas).
  - `imaging.encode_jpeg(img, quality: int = 85) -> bytes`.
  - `pipeline.prepare(data: bytes, kind: str, mime: str, ctx: JobContext) -> list[PreparedPage]`, `PreparedPage(source_index: int, code: str | None, copy_page: int | None, blank: bool, quality: Quality, rotation: int, full: bytes, marking: bytes | None)`; marking is made only for pages whose code is in `ctx.copies` and whose page role is `answer` (spare pages count as answer pages); scanner files: each PDF page or image is one page; home photos: `find_page` + `warp_to_a4` first, and a photo with no page found is still kept with `cut_off`.

- [ ] **Step 1: Failing tests** with images from `synth.py`: `scan_page_reads_code_and_page`; `scan_upside_down_turned_upright`; `scan_sideways_turned_upright`; `scan_tilted_3_degrees_straightened`; `photo_rotated_skewed_dark_background_reads` (Review Focus 4: copy page warped with a perspective, rotated 180°, on a dark textured background); `blank_back_detected`; `blurred_photo_flagged`; `dark_photo_flagged`; `cut_off_photo_flagged`; `marking_image_blanks_top_band_and_areas` (sampled pixels inside are white, the code area outside is unchanged); `cover_page_gets_no_marking_image`; `spare_page_gets_marking_image`; `unknown_code_gets_no_marking_image`; `landscape_master_page_reads`; `password_pdf_raises_unreadable`.
- [ ] **Step 2: Run** `npm run proc:test`. Expected: the new tests fail.
- [ ] **Step 3: Implement** `imaging.py` and `pipeline.py` with OpenCV (contours and `getPerspectiveTransform` for the page, `warpAffine` for straightening), zxing-cpp for codes, pypdfium2 for rendering, Pillow and pillow-heif for loading and saving. Run tests. Expected: PASS.
- [ ] **Step 4: Commit** `feat(processor): prepare pages from scans and photos`.

### Task 4: Matching pages and assembling scripts

**Files:**
- Create: `supabase/migrations/20261120000052_script_matching.sql`, `supabase/tests/029_script_matching.test.sql`, `services/processor/processor/supa.py`, `services/processor/processor/main.py`, `services/processor/tests/test_integration.py`

**Interfaces:**
- Produces:
  - `public.script_pages_record(p_job bigint, p_pages jsonb, p_now timestamptz default null) returns jsonb` (service_role only). `p_pages` items: `{source_index, code|null, copy_page|null, blank, quality:{sharpness,brightness,cut_off,flags}, rotation, full_path, marking_path|null}`. In one transaction it deletes earlier pages of this upload (so a rerun replaces them), inserts the pages, sets each page's state and raises exceptions:
    - code not found → `unknown_code`; copy of another exam → `other_exam`;
    - home upload whose copy belongs to another booking → `not_expected` (Review Focus 2);
    - scan file whose booking is not `paid`/`cancel_requested`, sitting `home`, another centre, or marked absent → `not_expected` (Review Focus 3);
    - no code and not blank: home → `unmatched`, left for the family to place; scan → `no_code` exception;
    - same `(booking, copy_page)` twice: the page with the higher `sharpness` is kept `matched`, the other `duplicate`; home → no exception; scan → `duplicate` exception;
    - pages from two paper versions in one script → `mixed_versions`;
    - scan pages with `blurred`, `dark` or `cut_off` → `poor_quality`.
    Then it assembles scripts: creates the booking's `scripts` row on its first matched page (`source` from the upload, number from `script_number_next`), writes a new `script_versions` row and links (home: the submission's matched pages over the previous version's links, or alone when `replaces_all`; scan: added to the current links), and sets the upload `processed`. Home submission state: `received` when every answer page of the copy's paper version is linked or in `blank_confirmed` and no page is waiting to be placed; otherwise `needs_attention`. A home submission becoming `received` sets `scripts.complete`; for centre scripts Task 9 sets it. Script state: `verified` when `complete` and no open exception, else `needs_attention` (or `checking` while any of its uploads is queued or processing); `received_at` on first `received`.
  - `public.script_evaluate(p_script uuid) returns void` (internal): recomputes the script state; reused by Tasks 6, 9 and 10.
  - `supa.Client` with `claim(worker_id) -> dict | None`, `download(bucket, path) -> bytes`, `upload(bucket, path, data, content_type)`, `record_pages(job_id, pages) -> dict`, `finish(job_id, ok, error=None)`, using httpx against PostgREST RPC and Storage with the service key.
  - `main.run(client, worker_id, *, once=False)`: loop claim → download → `pipeline.prepare` → upload pictures → `record_pages` → `finish`; on an exception, `finish(ok=False, error=<exception class name only>)`; sleeps 2 seconds when idle; stops on SIGTERM after the current job. Logs carry job id, upload id, page count and timings only.
- Consumes: Task 2 tables and `processing_job_claim`/`finish`; Task 3 `pipeline.prepare`; Task 1 `paper_page_roles`.

- [ ] **Step 1: Failing pgTAP tests** (`029`), feeding `script_pages_record` hand-written page lists: `home_pages_match_and_receive`; `home_missing_answer_page_needs_attention`; `cover_and_blank_pages_not_required`; `home_page_from_other_booking_not_matched`; `centre_page_absent_or_other_centre_flagged`; `duplicate_keeps_clearer_page`; `pages_from_two_versions_raise_mixed_versions`; `unknown_code_raises_exception`; `rerun_job_replaces_pages` (recording the same job twice leaves one set of pages and one version); `script_number_assigned_once`; `record_not_granted_to_authenticated`.
- [ ] **Step 2: Run** `npm run db:test:local`. Expected: 029 fails.
- [ ] **Step 3: Migration 052.** Run tests. Expected: PASS.
- [ ] **Step 4: Server loop and integration test.** `test_integration.py` (skipped when `SUPABASE_URL` is unset): seeds an exam, a home booking with a 1A copy and a fixture upload through the service key, runs `main.run(once=True)`, and asserts the pages, pictures in `script-pages` and a `received` submission. Run `npm run proc:test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(scripts): match pages and assemble scripts`.

### Task 5: Home sitting screen

**Files:**
- Create: `supabase/migrations/20261120000053_home_sitting.sql`, `supabase/tests/030_home_sitting.test.sql`, `apps/web/src/lib/sitting-state.ts` (+ test), `apps/web/src/components/scripts/SittingPanel.tsx`
- Modify: `apps/web/src/components/papers/BookingPaper.tsx` (or the "My bookings" card that hosts it), the exam form (`apps/web/src/components/exams/ExamForm.tsx`, `apps/web/src/lib/exam-form.ts`, `save_exam`)

**Interfaces:**
- Produces:
  - columns `exams.home_rules text check (char_length(home_rules) <= 2000)`, `exams.allowed_materials text check (char_length(allowed_materials) <= 500)`, saved through `save_exam` (new optional fields).
  - table `sitting_acknowledgements(booking_id uuid pk references bookings, acknowledged_by uuid not null, as_role text not null check (as_role in ('parent','student')), at timestamptz not null)`.
  - `public.sitting_acknowledge(p_booking uuid, p_now timestamptz default null) returns jsonb`: family of a paid home booking, before the finish; first acknowledgement stands (a second call returns it unchanged).
  - `public.booking_sitting_state(p_booking uuid, p_now timestamptz default null) returns jsonb` = `{phase, server_now, starts_at, finish_at, on_time_until, late_until, rules, materials, acknowledged:{as_role, at, by_name}|null, script:{number, state, late}|null, submission:{id, seq, state, late}|null}` where `phase` is `before_start`, `sitting`, `upload_open`, `late_window` or `closed`.
  - web: `sittingPhaseText(state, now) -> {title, countdown}` in `sitting-state.ts`; the countdown uses `server_now` to correct the device clock.
- Ruling (spec says "a default per subject"): subjects have no admin screen yet, so empty `home_rules`/`allowed_materials` show one institution default text (constant in `sitting-state.ts`); per-subject defaults come with Phase 1B's subject management. Recorded in the release notes.

- [ ] **Step 1: Failing tests**: pgTAP `phase_boundaries_use_server_time` (with `p_now` at start − 1 s, start, finish, finish + 2 h, finish + 24 h); `acknowledge_parent_and_student_roles`; `acknowledge_after_finish_refused`; `centre_booking_has_no_sitting_state`; `other_family_forbidden`. Vitest: `countdown_uses_server_offset`; `phase_texts`.
- [ ] **Step 2: Run** both suites. Expected: fail.
- [ ] **Step 3: Migration 053 and `SittingPanel`**: before the start, the paper download (1A), times, rules, materials, the early-download warning ("The paper is available 10 minutes before the start so you can print it. Please do not read it before the start.") and the acknowledgement ("I will supervise this exam at home and follow the rules" for a parent; for a student with no linked parent, the adult-supervision rule and "I will sit this exam under an adult's supervision"); during the exam, a countdown to the finish; after it, "Upload your answers" with time left (Task 6 fills this in). The exam form gains "Home exam rules" and "Allowed materials".
- [ ] **Step 4: Run** tests. Expected: PASS.
- [ ] **Step 5: Commit** `feat(scripts): home sitting screen and parent acknowledgement`.

### Task 6: Home upload and receipt

**Files:**
- Create: `supabase/migrations/20261120000054_home_upload.sql`, `supabase/tests/031_home_upload.test.sql`, `apps/web/src/lib/resumable-upload.ts` (+ test), `apps/web/src/lib/blur-check.ts` (+ test), `apps/web/src/components/scripts/{HomeUpload,CameraCapture,UploadReceipt}.tsx`
- Modify: `apps/web/package.json` (add `tus-js-client`), `SittingPanel.tsx`, `packages/shared/src/errors.ts`

**Interfaces:**
- Produces (all for the family of the booking, inside the upload window, checked with `p_now`):
  - `public.home_submission_open(p_booking uuid, p_replaces_all boolean default true, p_now timestamptz default null) returns jsonb` → `{submission_id, seq}`; returns the existing draft if one exists.
  - `public.script_upload_begin(p_submission uuid, p_kind upload_kind, p_mime text, p_bytes bigint, p_now timestamptz default null) returns jsonb` → `{upload_id, storage_path}`; enforces kind/mime/size and the 60-file limit.
  - `public.script_upload_stored(p_upload uuid) returns jsonb`: checks the storage object exists with the declared size; sets `stored`, `stored_at`.
  - `public.script_upload_discard(p_upload uuid) returns jsonb` (draft only); `public.script_upload_reorder(p_submission uuid, p_uploads uuid[]) returns jsonb`.
  - `public.home_submission_submit(p_submission uuid, p_now timestamptz default null) returns jsonb`: needs at least one stored upload and none still `pending`; sets `checking`, `submitted_by/at`, `late` (after finish + 2 h); queues a `prepare` job per upload; a second call on a submission no longer `draft` returns the same result without changes.
  - `public.home_submission_status(p_booking uuid) returns jsonb` = `{submission:{id, seq, state, late, submitted_at}, pages:[{copy_page, state, flags, upload_id, source_index}], missing:int[], unplaced:[{page_id, upload_id, source_index}], script:{number, state}}`.
  - `public.home_missing_confirm_blank(p_submission uuid, p_pages int[]) returns jsonb`; `public.home_page_place(p_page uuid, p_after_page int) returns jsonb` (counts the page as present after page `p_after_page` and raises an `uncoded_family_page` exception for staff); both call `script_evaluate`.
  - discarded drafts' storage objects are removed by the processing server (a `cleanup` step in `main.run` that deletes `discarded` uploads' objects older than 1 hour with the service key).
  - web: `uploadResumable(file, {bucket, path, accessToken, onProgress}) -> Promise<void>` (tus to `${SUPABASE_URL}/storage/v1/upload/resumable`, 6 MB chunks, `x-upsert: false`, resumes from stored fingerprints); `blurScore(imageData) -> number` (same Laplacian measure and threshold as the server).
- Consumes: Task 2 tables and policies, Task 4 `script_evaluate`, Task 5 `booking_sitting_state`.

- [ ] **Step 1: Failing tests**: pgTAP `begin_before_start_refused`; `begin_on_time_and_late` (late flag after finish + 2 h); `begin_after_late_window_refused` (Review Focus 5); `begin_wrong_mime_or_size_refused`; `sixty_one_files_refused`; `stored_requires_object_of_declared_size`; `submit_needs_stored_uploads`; `submit_twice_is_idempotent` (Review Focus 1); `centre_booking_cannot_upload`; `unpaid_booking_cannot_upload`; `other_family_forbidden`; `confirm_blank_receives_submission`; `place_uncoded_page_raises_exception`. Vitest: `blur_score_sharp_vs_blurred`; `resumable_upload_uses_6mb_chunks_and_no_upsert` (mocked tus).
- [ ] **Step 2: Run** both suites. Expected: fail.
- [ ] **Step 3: Migration 054 and the screens.** `HomeUpload` inside `SittingPanel` after the start: "Upload a PDF or photos" (drop zone, multiple files) on a computer; "Photograph pages" on a phone, opening `CameraCapture` (rear camera via `getUserMedia` with a page-shaped guide; falls back to a file input with `capture="environment"`), a thumbnail strip with retake, delete and drag to reorder, and the blur check asking "This photo is blurred. Retake it?". Each file shows "Uploading" with progress. "Submit" calls `home_submission_submit`, then the panel shows "Checking your pages" and polls `home_submission_status` every 3 seconds until it is not `checking`. "Needs your attention" lists "Retake page {n}" for flagged pages, "Was page {n} left blank?" (Yes / Add the page) for missing pages, and "Which page does this follow?" for pages without a code. "Received" shows `UploadReceipt` ("We have received your answers", script number and submission, time, page count and the page list), with Print. Until the deadline: "Replace all pages" and "Replace some pages" (opens a new submission with `replaces_all` false).
- [ ] **Step 4: Run** tests. Expected: PASS.
- [ ] **Step 5: Commit** `feat(scripts): home upload, checking and receipt`.

### Task 7: Receipts and staff alerts by email

**Files:**
- Create: `supabase/migrations/20261120000055_script_notices.sql`, `supabase/tests/032_script_notices.test.sql`, `supabase/functions/script-notify/index.ts`, `supabase/functions/script-notify/handler.ts`, `supabase/functions/script-notify/index.test.ts`
- Modify: `supabase/functions/_shared/email.ts`, `supabase/config.toml` (`[functions.script-notify] verify_jwt = false`)

**Interfaces:**
- Produces:
  - table `script_notices(id bigint identity pk, kind text check (kind in ('receipt','needs_attention','rejected','staff_alert')), script_id uuid, submission_id uuid, exception_id uuid, created_at, claimed_at, sent_at, attempts int default 0)`; rows are added in the same transaction as: a submission becoming `received` (receipt), `needs_attention` (needs_attention), rejected (rejected, Task 10), and every new exception of kinds `late`, `processing_failed`, `uncoded_family_page`, `not_expected`, `other_exam` (staff_alert).
  - `public.script_notice_next(p_limit int, p_now timestamptz default null) returns jsonb`, `public.script_notice_mark(p_id bigint, p_ok boolean) returns void` (service_role only), following 1A's `paper_notice_next`/`paper_notice_mark` claim-before-send pattern, looking back 6 hours, 3 attempts.
  - pg_cron job `script-notify` every minute calling the function through pg_net with Vault secrets `script_notify_url` and `cron_secret`.
  - email templates in `email.ts`: `scriptReceiptEmail` (to the student and linked parents: heading "We have received your answers", exam, script number, submission, time, page count, page list), `scriptAttentionEmail`, `scriptRejectedEmail`, `scriptStaffAlertEmail` (to active owner and admin accounts: exam, kind, script number; no candidate name).
  - With email off, nothing is sent or marked (as 1A).
- Consumes: Task 4 and Task 6 state changes; 1A `paper-release-notify` structure (`makeHandler`, `x-cron-secret`).

- [ ] **Step 1: Failing tests**: pgTAP `receipt_queued_once_on_received`; `staff_alert_on_late_and_failed`; `next_claims_before_send`; `notice_functions_not_granted_to_authenticated`. Deno: `handler_rejects_wrong_secret`; `email_off_sends_and_marks_nothing`; `receipt_goes_to_student_and_linked_parents`; `staff_alert_has_no_candidate_name`.
- [ ] **Step 2: Run** `npm run db:test:local` and `npm run fn:test:local`. Expected: fail.
- [ ] **Step 3: Implement** migration 055 and the function. Run tests. Expected: PASS.
- [ ] **Step 4: Commit** `feat(scripts): receipt and staff alert emails`.

### Task 8: Centre collection, manifest and custody

**Files:**
- Create: `supabase/migrations/20261120000056_collection_custody.sql`, `supabase/tests/033_collection_custody.test.sql`, `apps/web/src/components/scripts/{CollectionColumn,CustodyPanel}.tsx`, `apps/web/src/lib/manifest-pdf.ts` (+ test)
- Modify: `apps/web/src/components/attendance/*` (the register), `apps/web/src/app/admin/attendance/[examId]/page.tsx`, `apps/web/src/app/teacher/attendance/[examId]/page.tsx`

**Interfaces:**
- Produces:
  - table `collection_counts(booking_id uuid pk references bookings, exam_id uuid not null, extra_sheets int not null check (extra_sheets between 0 and 50), recorded_by uuid not null, recorded_at timestamptz not null)`; the printed copy always counts as one booklet.
  - `public.collection_record(p_booking uuid, p_extra_sheets int) returns jsonb`: staff for whom `attendance_can_manage(auth.uid(), subject)` holds, for a candidate marked `present` or `late`; audit `collection_recorded`.
  - table `collection_manifests(id uuid pk, exam_id uuid, centre_id uuid, number text unique, created_by uuid, created_at)`; `public.collection_manifest_create(p_exam uuid, p_centre uuid) returns jsonb` → `{manifest_id, number, rows:[{index_number, name, attendance, extra_sheets}]}` in index order.
  - table `custody_events(id uuid pk, exam_id uuid not null, centre_id uuid not null, manifest_id uuid, batch_id uuid, step text not null check (step in ('collected','handed_over','scanned','archived')), from_staff uuid, to_staff uuid, location text not null check (char_length(location) between 1 and 120), note text check (char_length(note) <= 300), recorded_by uuid not null, at timestamptz not null)`; `public.custody_record(p_exam uuid, p_centre uuid, p_step text, p_from uuid, p_to uuid, p_location text, p_note text, p_manifest uuid default null) returns jsonb`; `public.custody_list(p_exam uuid, p_centre uuid) returns jsonb`.
  - web: `buildManifestPdf(manifest) -> Promise<Uint8Array>` (pdf-lib, A4, the manifest number as a QR code with the 1A `qrcode` library, a signature box).
- Consumes: 1A registers and `attendance_can_manage`.

- [ ] **Step 1: Failing tests**: pgTAP `collection_only_for_present_candidates`; `collection_requires_register_permission`; `manifest_rows_in_index_order`; `custody_steps_and_lengths_checked`; `custody_staff_must_be_staff_accounts`. Vitest: `manifest_pdf_has_qr_and_every_candidate`.
- [ ] **Step 2: Run** suites. Expected: fail.
- [ ] **Step 3: Implement** migration 056 and the screens: on the register after the start, a "Sheets" column ("Booklet + {n} extra sheets") for present candidates; "Print collection manifest"; a "Custody" panel listing handovers with "Record handover" (step, from, to, place, note). Run tests. Expected: PASS.
- [ ] **Step 4: Commit** `feat(scripts): centre collection, manifest and custody`.

### Task 9: Bulk scan upload

**Files:**
- Create: `supabase/migrations/20261120000057_scan_batches.sql`, `supabase/tests/034_scan_batches.test.sql`, `apps/web/src/components/scripts/ScanBatches.tsx`
- Modify: `apps/web/src/app/admin/exams/[id]/page.tsx`

**Interfaces:**
- Produces:
  - `public.scan_batch_create(p_exam uuid, p_centre uuid, p_manifest_number text default null) returns jsonb` → `{batch_id, number}`; staff admins; refuses a manifest number of another exam or centre.
  - `public.scan_upload_begin(p_batch uuid, p_mime text, p_bytes bigint) returns jsonb` → `{upload_id, storage_path}`; kind `scan_file`; ≤ 1 GB.
  - `public.scan_batch_submit(p_batch uuid) returns jsonb`: queues a `prepare` job per stored upload, sets `submitted_at`, and adds a `scanned` custody event for the batch (location "Scanning", recorded by the caller).
  - `public.scan_batch_status(p_batch uuid) returns jsonb` = `{number, uploads:[{id, state, byte_size}], totals:{pages, matched, blank, flagged, duplicates}, jobs:{queued, running, failed}, candidates_complete}`.
  - `public.scan_centre_complete(p_exam uuid, p_centre uuid) returns jsonb`: for each present or late candidate of the centre, raises `missing_pages` (with the missing page numbers in `details`) when an answer page is missing, otherwise marks the centre script complete and calls `script_evaluate`; for a present candidate with no pages at all, raises `missing_pages` with every answer page; returns counts.
  - `script_upload_stored` from Task 6 accepts scan uploads too (staff caller).
- Consumes: Task 2, Task 4 `script_evaluate`, Task 6 `script_upload_stored`, Task 8 manifests and custody, `resumable-upload.ts`.

- [ ] **Step 1: Failing tests**: `batch_numbers_per_exam`; `batch_for_teacher_forbidden`; `submit_queues_jobs_and_scanned_custody`; `status_totals_count_pages`; `complete_raises_missing_pages_and_verifies_complete`; `absent_candidate_needs_no_script`.
- [ ] **Step 2: Run** `npm run db:test:local`. Expected: fail.
- [ ] **Step 3: Implement** migration 057 and `ScanBatches` on the admin exam page, per centre: "New scan batch" (with an optional manifest number), file upload with progress, "Start processing", live totals (poll every 3 seconds while jobs are queued or running) and "All scans for this centre are uploaded". Run tests. Expected: PASS.
- [ ] **Step 4: Commit** `feat(scripts): bulk scan batches`.

### Task 10: Exception queue

**Files:**
- Create: `supabase/migrations/20261120000058_script_resolution.sql`, `supabase/tests/035_script_resolution.test.sql`, `apps/web/src/app/admin/scripts/exceptions/page.tsx`, `apps/web/src/components/scripts/{ExceptionQueue,PageViewer}.tsx`

**Interfaces:**
- Produces (staff admins; each writes an audit row with the reason and calls `script_evaluate`; a second resolution of the same exception returns `conflict` with `resolved_by` name and time):
  - `public.script_exceptions_list(p_exam uuid default null, p_kind exception_kind default null, p_state text default 'open') returns jsonb` (newest first, at most 200, with the page picture path).
  - `public.script_exception_assign(p_exception uuid, p_booking uuid, p_copy_page int, p_reason text) returns jsonb`: puts the page into that candidate's script at that page (new version).
  - `public.script_exception_blank(p_exception uuid, p_reason text)`, `public.script_exception_keep_existing(p_exception uuid, p_reason text)` (duplicates), `public.script_exception_reject(p_exception uuid, p_reason text)` (home: the submission becomes `rejected` and the family is emailed, Task 7), `public.script_exception_confirm(p_exception uuid, p_reason text default null)` (family-placed pages, poor quality accepted), `public.script_exception_dismiss_missing(p_exception uuid, p_pages int[], p_reason text)` (staff confirm pages were left blank).
  - `public.script_late_decide(p_script uuid, p_accept boolean, p_reason text) returns jsonb` (resolves the `late` exception; `late_decision`).
  - web `PageViewer`: signed links from `supabase.storage.from('script-pages').createSignedUrl(path, 300)`, zoom, rotate view.
- Consumes: Tasks 2, 4, 6, 7, 9.

- [ ] **Step 1: Failing tests**: `assign_moves_page_into_script_new_version`; `assign_to_candidate_of_other_exam_refused`; `reject_home_submission_queues_email`; `late_accept_and_reject`; `second_resolution_conflict`; `reason_required` (3 to 300 characters); `teacher_forbidden`; `resolution_keeps_original_page_row`.
- [ ] **Step 2: Run** `npm run db:test:local`. Expected: fail.
- [ ] **Step 3: Implement** migration 058 and the page: filters (exam, kind, open or resolved), a list, and a detail pane with the page picture, what the server found in plain words, and the actions with a reason box; search candidates by index number for "Assign". Run tests. Expected: PASS.
- [ ] **Step 4: Commit** `feat(scripts): exception queue`.

### Task 11: Script repository

**Files:**
- Modify: `services/processor/processor/{pipeline,main}.py`
- Create: `supabase/migrations/20261120000059_script_repository.sql`, `supabase/tests/036_script_repository.test.sql`, `apps/web/src/app/admin/scripts/page.tsx`, `apps/web/src/app/admin/scripts/[id]/page.tsx`, `apps/web/src/components/scripts/{ScriptList,ScriptDetail}.tsx`, `services/processor/tests/test_remask.py`

**Interfaces:**
- Produces:
  - `public.scripts_list(p_exam uuid default null, p_source script_source default null, p_state script_state default null, p_late boolean default null) returns jsonb` (staff admins).
  - `public.script_detail(p_script uuid) returns jsonb` = `{script, candidate:{name, index_number}, versions:[...], pages:[{copy_page, page_id, role, full_path, marking_path, quality, upload_id, source_index}], uploads:[...], exceptions:[...], custody:[...]}`.
  - `public.script_page_rotate(p_page uuid, p_quarter_turns int, p_reason text)`: adds to `rotation`, queues a `remask` job for the page's upload.
  - `public.script_upload_reprocess(p_upload uuid, p_reason text)`: queues a `prepare` job (rerun replaces the upload's pages, Task 4).
  - `public.script_void(p_script uuid, p_reason text)`; trigger on `bookings` status change to `cancelled`, `refunded` or `expired` → script `withdrawn` with `state_reason`.
  - `set_paper_hidden_areas` (Task 1) now queues a `remask` job for every processed upload holding pages of that paper's copies on the changed pages.
  - processor: `remask` jobs re-make marking pictures from the stored full pictures with the current rotation and hidden areas (`pipeline.remask(full: bytes, rotation: int, areas) -> bytes`), then call `script_pages_remasked(p_job bigint, p_pages jsonb)` (service_role only; updates `marking_path` and `rotation` only).
- Consumes: Tasks 1, 2, 4, 10.

- [ ] **Step 1: Failing tests**: pgTAP `list_filters`; `detail_for_staff_only`; `rotate_queues_remask`; `reprocess_queues_prepare`; `cancelled_booking_withdraws_script`; `hidden_area_change_queues_remask`; `void_needs_reason`. Python: `remask_applies_rotation_and_areas`.
- [ ] **Step 2: Run** suites. Expected: fail.
- [ ] **Step 3: Implement** the SQL, the processor `remask` path and the screens: `/admin/scripts` (filters, script number, candidate, exam, source, state, late, pages, received), `/admin/scripts/[id]` (metadata, versions, page viewer with full and marking pictures side by side, rotate, reprocess, void, exceptions and custody). Add "Scripts" to the admin navigation. Run tests. Expected: PASS.
- [ ] **Step 4: Commit** `feat(scripts): script repository`.

### Task 12: Dashboard, release notes and whole-branch check

**Files:**
- Modify: `apps/web/src/app/admin/page.tsx` (admin home), `apps/web/src/lib/alerts.ts`
- Create: `apps/web/e2e/scripts-home.spec.ts`, `apps/web/e2e/scripts-centre.spec.ts`, `docs/superpowers/<date written>-phase2-release-notes.md`

**Interfaces:**
- Produces: `public.scripts_dashboard(p_now timestamptz default null) returns jsonb` = per exam in the last 14 days `{exam, expected (paid present centre + paid home), received, verified, needs_attention, late}`, plus `{open_exceptions, failed_jobs, oldest_queued_minutes, centres_without_scanned_custody}` (a centre with collection counts but no `scanned` custody event by 09:00 the next day).

- [ ] **Step 1: Dashboard** tiles and alerts from `scripts_dashboard`, with a pgTAP test `dashboard_counts` in `036`.
- [ ] **Step 2: Browser tests** (local stack, processing server running from `docker compose`): `scripts-home.spec.ts` (a parent acknowledges, uploads the fixture photos of copy A, sees "Checking your pages" then "Received" and the receipt; a page from copy B shows in the admin exception queue); `scripts-centre.spec.ts` (staff record sheets and custody, print a manifest, upload a fixture scan batch, see totals, complete the centre, resolve a duplicate, see the verified script in `/admin/scripts`). Desktop 1440, tablet 768 and phone 390 widths; no sideways scroll.
- [ ] **Step 3: Release notes** for the owner in plain English: what changed for families and staff; deploy order (migrations 050–059 after 1A's; the `script-notify` function; the processing server on the owner's host with `SUPABASE_URL` and the service key as secrets; the website); owner actions (Supabase Pro and the 1 GB upload limit, the host account, Vault secrets `script_notify_url` and `cron_secret`, real test files); the per-subject rules ruling; known limits.
- [ ] **Step 4: Whole-branch run**: `npm run db:test:local`, `npm run fn:test:local`, `npm run proc:test`, `npm test -w @stem/web`, `npm test -w @stem/shared`, `npx tsc --noEmit -p apps/web`, `npx tsc --noEmit -p packages/shared`, `npm run lint -w @stem/web`, `npm run e2e:local -w @stem/web`, `npm run build -w @stem/web`. Expected: all pass.
- [ ] **Step 5: Commit** `docs: Phase 2 release notes; dashboard and browser tests`.
