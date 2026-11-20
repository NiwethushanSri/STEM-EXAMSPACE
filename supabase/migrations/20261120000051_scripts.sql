-- Phase 2 Task 2: scripts, uploads, pages and processing jobs.
--
-- Families and staff upload finished scripts (photos, PDFs, scanner files) to the private bucket script-uploads. A
-- Python processing server claims a job per upload, prepares page pictures (bucket script-pages) and hands the page
-- list back to the database, which matches pages to candidates and assembles one script per booking (later tasks).
-- This migration holds the tables, the buckets, their policies and the two functions the server calls.
--
-- Nothing here is written by a signed-in user directly: rows come from security definer functions (later tasks) and
-- the service role. Staff admins can read the rows and the files. A user may add a file only at the exact path of a
-- pending upload row of their own, and never overwrites or deletes one (there are no update or delete policies).

create type public.script_source as enum ('home', 'centre');
create type public.script_state as enum (
  'receiving', 'checking', 'needs_attention', 'verified', 'ready_to_mark', 'marking', 'marked', 'checked', 'final',
  'withdrawn', 'void');
create type public.upload_kind as enum ('home_photo', 'home_pdf', 'scan_file');
create type public.upload_state as enum ('pending', 'stored', 'discarded', 'queued', 'processing', 'processed', 'failed');
create type public.page_state as enum ('matched', 'blank', 'duplicate', 'unmatched', 'rejected');
create type public.job_state as enum ('queued', 'running', 'done', 'failed');
create type public.exception_kind as enum (
  'no_code', 'unknown_code', 'other_exam', 'not_expected', 'duplicate', 'missing_pages', 'uncoded_family_page',
  'mixed_versions', 'poor_quality', 'late', 'name_visible', 'processing_failed');
create type public.submission_state as enum ('draft', 'checking', 'received', 'needs_attention', 'rejected');

-- ---------------------------------------------------------------------------------------------
-- Tables.
-- ---------------------------------------------------------------------------------------------

-- One script per booking. version counts the times the set of pages changed (script_versions keeps each one).
create table public.scripts (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null unique references public.bookings (id),
  exam_id uuid not null references public.exams (id),
  source public.script_source not null,
  number text not null unique,
  state public.script_state not null default 'receiving',
  version int not null default 0,
  complete boolean not null default false,
  late boolean not null default false,
  late_decision text check (late_decision in ('accept', 'reject')),
  received_at timestamptz,
  state_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index scripts_exam_idx on public.scripts (exam_id);
create trigger scripts_touch_updated_at before update on public.scripts
  for each row execute function public.touch_updated_at();

create table public.script_versions (
  script_id uuid not null references public.scripts (id),
  version int not null,
  created_at timestamptz not null default now(),
  created_by uuid,
  reason text,
  primary key (script_id, version)
);

-- A family's try at handing in a script: a draft while photos are added, then checked and received.
create table public.home_submissions (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings (id),
  seq int not null,
  replaces_all boolean not null default true,
  state public.submission_state not null default 'draft',
  late boolean not null default false,
  submitted_by uuid,
  submitted_at timestamptz,
  checked_at timestamptz,
  blank_confirmed int[] not null default '{}',
  constraint home_submissions_booking_seq_key unique (booking_id, seq)
);
create unique index home_submissions_one_draft on public.home_submissions (booking_id) where state = 'draft';

-- A pile of scanner files from a centre. manifest_id gets its foreign key with the manifests table.
create table public.scan_batches (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null,
  centre_id uuid not null references public.exam_centres (id),
  manifest_id uuid,
  number text not null unique,
  created_by uuid,
  created_at timestamptz not null default now(),
  submitted_at timestamptz
);
create index scan_batches_exam_idx on public.scan_batches (exam_id);

create table public.script_uploads (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null,
  booking_id uuid,
  submission_id uuid references public.home_submissions (id),
  batch_id uuid references public.scan_batches (id),
  kind public.upload_kind not null,
  position int,
  storage_path text not null unique,
  mime text not null,
  byte_size bigint not null,
  sha256 text,
  state public.upload_state not null default 'pending',
  uploaded_by uuid not null,
  created_at timestamptz not null default now(),
  stored_at timestamptz,
  constraint script_uploads_one_owner check ((submission_id is null) <> (batch_id is null))
);
create index script_uploads_submission_idx on public.script_uploads (submission_id);
create index script_uploads_batch_idx on public.script_uploads (batch_id);
create index script_uploads_booking_idx on public.script_uploads (booking_id);

-- One picture per source page of an upload. copy_id and copy_page say which page of which candidate's copy it is.
create table public.script_pages (
  id uuid primary key default gen_random_uuid(),
  upload_id uuid not null references public.script_uploads (id),
  source_index int not null,
  exam_id uuid not null,
  copy_id uuid references public.paper_copies (id),
  copy_page int,
  booking_id uuid references public.bookings (id),
  state public.page_state not null,
  blank boolean not null default false,
  quality jsonb not null default '{}',
  rotation int not null default 0 check (rotation in (0, 90, 180, 270)),
  full_path text not null,
  marking_path text,
  placed_after int,
  created_at timestamptz not null default now(),
  constraint script_pages_upload_index_key unique (upload_id, source_index)
);
create index script_pages_copy_idx on public.script_pages (copy_id);
create index script_pages_booking_idx on public.script_pages (booking_id);

-- The pages of each version of a script: page number of the copy -> picture.
create table public.script_page_links (
  script_id uuid not null references public.scripts (id),
  version int not null,
  copy_page int not null,
  page_id uuid not null references public.script_pages (id),
  primary key (script_id, version, copy_page)
);
create index script_page_links_page_idx on public.script_page_links (page_id);

create table public.processing_jobs (
  id bigint generated always as identity primary key,
  upload_id uuid not null references public.script_uploads (id),
  kind text not null check (kind in ('prepare', 'remask')),
  state public.job_state not null default 'queued',
  attempts int not null default 0,
  run_after timestamptz not null default now(),
  locked_by text,
  locked_at timestamptz,
  last_error text check (char_length(last_error) <= 300),
  created_at timestamptz not null default now(),
  finished_at timestamptz
);
create index processing_jobs_claim_idx on public.processing_jobs (run_after, id) where state in ('queued', 'running');
create index processing_jobs_upload_idx on public.processing_jobs (upload_id);

create table public.script_exceptions (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null,
  kind public.exception_kind not null,
  booking_id uuid,
  script_id uuid,
  page_id uuid,
  upload_id uuid,
  details jsonb not null default '{}',
  state text not null default 'open' check (state in ('open', 'resolved')),
  created_at timestamptz not null default now(),
  resolved_by uuid,
  resolved_at timestamptz,
  resolution text,
  reason text
);
create index script_exceptions_exam_state_idx on public.script_exceptions (exam_id, state);

-- ---------------------------------------------------------------------------------------------
-- Access: staff admins read; nobody but the service role and definer functions writes.
-- ---------------------------------------------------------------------------------------------
alter table public.scripts enable row level security;
alter table public.script_versions enable row level security;
alter table public.script_page_links enable row level security;
alter table public.home_submissions enable row level security;
alter table public.scan_batches enable row level security;
alter table public.script_uploads enable row level security;
alter table public.script_pages enable row level security;
alter table public.processing_jobs enable row level security;
alter table public.script_exceptions enable row level security;

revoke all on public.scripts, public.script_versions, public.script_page_links, public.home_submissions,
  public.scan_batches, public.script_uploads, public.script_pages, public.processing_jobs, public.script_exceptions
  from anon, authenticated;
revoke all on sequence public.processing_jobs_id_seq from anon, authenticated;
grant select on public.scripts, public.script_versions, public.script_page_links, public.home_submissions,
  public.scan_batches, public.script_uploads, public.script_pages, public.processing_jobs, public.script_exceptions
  to authenticated;

create policy scripts_select on public.scripts for select to authenticated using ((select public.is_staff_admin()));
create policy script_versions_select on public.script_versions for select to authenticated using ((select public.is_staff_admin()));
create policy script_page_links_select on public.script_page_links for select to authenticated using ((select public.is_staff_admin()));
create policy home_submissions_select on public.home_submissions for select to authenticated using ((select public.is_staff_admin()));
create policy scan_batches_select on public.scan_batches for select to authenticated using ((select public.is_staff_admin()));
create policy script_uploads_select on public.script_uploads for select to authenticated using ((select public.is_staff_admin()));
create policy script_pages_select on public.script_pages for select to authenticated using ((select public.is_staff_admin()));
create policy processing_jobs_select on public.processing_jobs for select to authenticated using ((select public.is_staff_admin()));
create policy script_exceptions_select on public.script_exceptions for select to authenticated using ((select public.is_staff_admin()));

-- ---------------------------------------------------------------------------------------------
-- Buckets and storage policies.
--   script-uploads: home/<booking>/<upload>.<ext> and batch/<batch>/<upload>.<ext>; 1 GiB, photos and PDFs.
--   script-pages: <exam>/<upload>/<source_index>-full.jpg and -marking.jpg, written by the processing server with
--   the service role; staff admins read.
-- ---------------------------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('script-uploads', 'script-uploads', false, 1073741824,
  array['image/jpeg', 'image/png', 'image/heic', 'image/heif', 'application/pdf'])
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('script-pages', 'script-pages', false, 10485760, array['image/jpeg'])
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Whether the caller may add (p_add) or read (not p_add) the file at this path of script-uploads. The policies
-- cannot read script_uploads as the caller (families have no table access), so they ask this definer function.
create function public.script_upload_path_allowed(p_path text, p_add boolean)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.script_uploads u
    where u.storage_path = p_path
      and u.uploaded_by = (select auth.uid())
      and case when p_add then u.state = 'pending' else u.state in ('pending', 'stored') end)
$$;
revoke execute on function public.script_upload_path_allowed(text, boolean) from public, anon;
grant execute on function public.script_upload_path_allowed(text, boolean) to authenticated;

create policy script_uploads_objects_insert on storage.objects for insert to authenticated
with check (bucket_id = 'script-uploads' and public.script_upload_path_allowed(name, true));

create policy script_uploads_objects_select on storage.objects for select to authenticated
using (
  bucket_id = 'script-uploads'
  and ((select public.is_staff_admin()) or public.script_upload_path_allowed(name, false))
);

create policy script_pages_objects_select on storage.objects for select to authenticated
using (bucket_id = 'script-pages' and (select public.is_staff_admin()));

-- ---------------------------------------------------------------------------------------------
-- Script numbers: S-<exam code>-<0001, 0002 ...> per exam. Internal; callers hold the exam's advisory lock until
-- they have inserted the script (the lock is released at the end of the transaction).
-- ---------------------------------------------------------------------------------------------
create function public.script_number_next(p_exam uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text;
  v_n int;
begin
  select e.exam_code into v_code from public.exams e where e.id = p_exam;
  if v_code is null then
    raise exception 'unknown exam';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('script_number:' || p_exam::text, 0));
  select coalesce(max(substring(s.number from '-([0-9]+)$')::int), 0) + 1 into v_n
  from public.scripts s where s.exam_id = p_exam;
  return 'S-' || v_code || '-' || lpad(v_n::text, 4, '0');
end;
$$;
revoke execute on function public.script_number_next(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- Processing jobs (the Python server, with the service role).
-- ---------------------------------------------------------------------------------------------

-- Takes the oldest claimable job: queued and due, or running whose worker has been quiet for 15 minutes. Returns
-- what the server needs to prepare the upload: the upload, every question-paper version of its exam (current and
-- superseded) with page count, page roles and hidden areas, and every copy made from them by code. SQL null when
-- nothing is claimable. p_now (default now()) lets tests and the server's clock-free callers choose the time.
create function public.processing_job_claim(p_worker text, p_now timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  v_job public.processing_jobs%rowtype;
  v_up public.script_uploads%rowtype;
begin
  select j.* into v_job from public.processing_jobs j
  where (j.state = 'queued' and j.run_after <= v_now)
     or (j.state = 'running' and j.locked_at < v_now - interval '15 minutes')
  order by j.run_after, j.id
  limit 1
  for update skip locked;
  if not found then
    return null;
  end if;
  update public.processing_jobs
  set state = 'running', attempts = attempts + 1, locked_by = left(coalesce(p_worker, ''), 100), locked_at = v_now
  where id = v_job.id
  returning * into v_job;
  select * into v_up from public.script_uploads u where u.id = v_job.upload_id;

  return jsonb_build_object(
    'job', jsonb_build_object('id', v_job.id, 'kind', v_job.kind, 'attempts', v_job.attempts),
    'upload', jsonb_build_object('id', v_up.id, 'kind', v_up.kind, 'mime', v_up.mime, 'storage_path', v_up.storage_path,
      'exam_id', v_up.exam_id, 'booking_id', v_up.booking_id, 'batch_id', v_up.batch_id),
    'papers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'paper_id', p.id,
        'page_count', p.page_count,
        'roles', coalesce((select jsonb_agg(jsonb_build_object('page', r.page, 'role', r.role) order by r.page)
                           from public.paper_page_roles r where r.paper_id = p.id), '[]'::jsonb),
        'areas', coalesce((select jsonb_agg(jsonb_build_object('page', a.page, 'x', a.x, 'y', a.y, 'w', a.w, 'h', a.h)
                                            order by a.page, a.created_at, a.id)
                           from public.paper_hidden_areas a where a.paper_id = p.id), '[]'::jsonb))
        order by p.version)
      from public.exam_papers p where p.exam_id = v_up.exam_id and p.kind = 'paper'), '[]'::jsonb),
    'copies', coalesce((
      select jsonb_object_agg(c.code, jsonb_build_object(
        'copy_id', c.id, 'paper_id', c.paper_id, 'booking_id', c.booking_id, 'page_count', c.page_count))
      from public.paper_copies c
      join public.exam_papers p on p.id = c.paper_id
      where p.exam_id = v_up.exam_id and p.kind = 'paper'), '{}'::jsonb));
end;
$$;

-- Ends a claimed job. ok: done. Not ok: queued again for attempts minutes later while attempts < 3; after that the
-- job and its upload fail and one processing_failed exception is raised for staff. Only the short error text the
-- server sends is stored (300 characters at most): never page contents or names.
create function public.processing_job_finish(
  p_job bigint,
  p_ok boolean,
  p_error text default null,
  p_now timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  v_job public.processing_jobs%rowtype;
  v_up public.script_uploads%rowtype;
  v_error text := left(p_error, 300);
begin
  select * into v_job from public.processing_jobs j where j.id = p_job for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_job.state <> 'running' then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  if p_ok is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  if p_ok then
    update public.processing_jobs set state = 'done', finished_at = v_now, locked_by = null, locked_at = null
    where id = v_job.id;
    return jsonb_build_object('ok', true, 'state', 'done');
  end if;

  if v_job.attempts < 3 then
    update public.processing_jobs
    set state = 'queued', run_after = v_now + v_job.attempts * interval '1 minute', locked_by = null, locked_at = null,
        last_error = v_error
    where id = v_job.id;
    return jsonb_build_object('ok', true, 'state', 'queued');
  end if;

  update public.processing_jobs
  set state = 'failed', finished_at = v_now, locked_by = null, locked_at = null, last_error = v_error
  where id = v_job.id;
  update public.script_uploads set state = 'failed' where id = v_job.upload_id returning * into v_up;
  insert into public.script_exceptions (exam_id, kind, booking_id, upload_id, details)
  values (v_up.exam_id, 'processing_failed', v_up.booking_id, v_up.id,
    jsonb_build_object('job_id', v_job.id, 'attempts', v_job.attempts));
  return jsonb_build_object('ok', true, 'state', 'failed');
end;
$$;

revoke execute on function public.processing_job_claim(text, timestamptz) from public, anon, authenticated;
revoke execute on function public.processing_job_finish(bigint, boolean, text, timestamptz) from public, anon, authenticated;
grant execute on function public.processing_job_claim(text, timestamptz) to service_role;
grant execute on function public.processing_job_finish(bigint, boolean, text, timestamptz) to service_role;
