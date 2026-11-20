-- Phase 2 Task 6: home upload, checking and receipt.
--
-- A family (the student, or a linked parent) hands in a home script as a submission. While it is a draft, each photo
-- or PDF first gets an upload row (script_upload_begin), whose exact path the storage policy then lets the uploader
-- fill; the web app uploads the file (resumable) and script_upload_stored checks the stored object against the row.
-- Submit queues a prepare job per file; the processing server prepares and records the pages (Task 4), and the
-- family follows the result with home_submission_status: checking, received, or needs attention (pages to retake or
-- send as they are, answer pages left blank, pages without a code to place).
--
-- Times (as booking_sitting_state): uploads are open from the start; a submission handed in from finish + 2 hours is
-- late (an exception for staff, who decide); nothing is begun or submitted from finish + 24 hours. p_now is honoured
-- only for direct database sessions (paper_clock); an API call always uses the database clock. Confirming blank
-- pages, placing a page and "Send as it is" describe what was already handed in, so they have no time rule.
--
-- Discarded draft files were never handed in: the processing server removes their objects an hour after the discard
-- (script_discarded_take, script_upload_purged). A file that was submitted is never deleted.
--
-- Lock order (as 052): upload, booking (advisory lock), home submission, script. Family functions that change a
-- draft read the upload without a lock, then take the booking, the submission and only then the upload; the
-- processing server never locks a draft's uploads, and a draft's uploads leave it only under the submission's lock.

-- ---------------------------------------------------------------------------------------------
-- Schema additions.
-- ---------------------------------------------------------------------------------------------
alter table public.script_uploads
  add column discarded_at timestamptz,
  add column purged_at timestamptz;
create index script_uploads_discarded_idx on public.script_uploads (discarded_at) where state = 'discarded' and purged_at is null;

-- ---------------------------------------------------------------------------------------------
-- Helpers (internal).
-- ---------------------------------------------------------------------------------------------

-- The file types and largest size a family may hand in per kind: photos (JPEG, PNG, HEIC, HEIF) up to 25 MB, a PDF up
-- to 100 MB.
create function public.home_upload_type_ok(p_kind public.upload_kind, p_mime text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case p_kind
    when 'home_photo' then coalesce(p_mime in ('image/jpeg', 'image/png', 'image/heic', 'image/heif'), false)
    when 'home_pdf' then coalesce(p_mime = 'application/pdf', false)
    else false
  end
$$;

create function public.home_upload_max_bytes(p_kind public.upload_kind)
returns bigint
language sql
immutable
set search_path = ''
as $$
  select case p_kind when 'home_photo' then 26214400::bigint when 'home_pdf' then 104857600::bigint end
$$;

-- Why p_actor may not hand in answers for this booking (null: they may): the student or an active linked parent of
-- a paid (or cancel-requested) home booking. With p_at, also inside the upload window: from the start until
-- finish + 24 hours (a cancelled exam is closed).
create function public.home_upload_code(p_actor uuid, p_booking public.bookings, p_at timestamptz)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_code text;
  v_phase text;
begin
  v_code := public.sitting_access_code(p_actor, p_booking, true);
  if v_code is not null then
    return v_code;
  end if;
  if p_booking.sitting <> 'home' then
    return 'wrong_sitting';
  end if;
  if p_booking.status not in ('paid', 'cancel_requested') then
    return 'conflict';
  end if;
  if p_at is not null then
    select public.sitting_phase(e, p_at) into v_phase from public.exams e where e.id = p_booking.exam_id;
    if v_phase = 'before_start' then
      return 'uploads_not_open';
    elsif v_phase is distinct from 'sitting' and v_phase is distinct from 'upload_open' and v_phase is distinct from 'late_window' then
      return 'uploads_closed';
    end if;
  end if;
  return null;
end;
$$;

create function public.home_booking_lock(p_booking uuid)
returns void
language sql
set search_path = ''
as $$
  select pg_advisory_xact_lock(hashtextextended('script_booking:' || p_booking::text, 0))
$$;

-- The booking's latest submission that was handed in (not a draft): the one the family follows and the script
-- counts (a rejected one included, which then counts for nothing).
create function public.home_submission_latest(p_booking uuid)
returns public.home_submissions
language sql
stable
security definer
set search_path = ''
as $$
  select s.* from public.home_submissions s
  where s.booking_id = p_booking and s.state <> 'draft'
  order by s.seq desc limit 1
$$;

-- The answer pages of a submission's paper version that the script does not show (and, with p_skip_confirmed, that
-- the family has not said were left blank), worked out as home_submission_evaluate does: the paper version of the
-- linked pages, or of the booking's latest copy when none is linked. Pages from two versions: none (staff decide).
create function public.home_missing_pages(p_submission uuid, p_skip_confirmed boolean)
returns int[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_s public.home_submissions%rowtype;
  v_script uuid;
  v_version int;
  v_papers uuid[];
  v_paper uuid;
begin
  select * into v_s from public.home_submissions s where s.id = p_submission;
  if not found then
    return '{}';
  end if;
  select s.id, s.version into v_script, v_version from public.scripts s where s.booking_id = v_s.booking_id;
  select coalesce(array_agg(distinct c.paper_id), '{}') into v_papers
  from public.script_page_links l
  join public.script_pages p on p.id = l.page_id
  join public.paper_copies c on c.id = p.copy_id
  where l.script_id = v_script and l.version = v_version;
  if cardinality(v_papers) = 1 then
    v_paper := v_papers[1];
  elsif cardinality(v_papers) = 0 then
    select c.paper_id into v_paper from public.paper_copies c
    where c.booking_id = v_s.booking_id order by c.created_at desc, c.id limit 1;
  end if;
  if v_paper is null then
    return '{}';
  end if;
  return coalesce((
    select array_agg(r.page order by r.page)
    from public.paper_page_roles r
    where r.paper_id = v_paper and r.role = 'answer'
      and (not p_skip_confirmed or r.page <> all (v_s.blank_confirmed))
      and not exists (select 1 from public.script_page_links l
                      where l.script_id = v_script and l.version = v_version and l.copy_page = r.page)), '{}');
end;
$$;

-- Works the submission and the booking's script out again after the family changed something (script_evaluate; a
-- booking with no script yet has only its submission). Returns the submission's state.
create function public.home_reevaluate(p_booking uuid, p_submission uuid)
returns public.submission_state
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_script uuid;
begin
  select s.id into v_script from public.scripts s where s.booking_id = p_booking;
  if v_script is not null then
    perform public.script_evaluate(v_script);
  else
    perform public.home_submission_evaluate(p_submission, now());
  end if;
  return (select s.state from public.home_submissions s where s.id = p_submission);
end;
$$;

-- What home_submission_submit answers: the submission as it now stands.
create function public.home_submission_result(p_submission uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('ok', true, 'submission_id', s.id, 'seq', s.seq, 'state', s.state, 'late', s.late,
    'submitted_at', s.submitted_at)
  from public.home_submissions s where s.id = p_submission
$$;

-- ---------------------------------------------------------------------------------------------
-- A script is late when the submission it counts was handed in late (from finish + 2 hours). The script made from a
-- late submission's first pages is late from the start. (Same as 20261120000052 otherwise.)
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_create(p_booking uuid, p_source public.script_source, p_now timestamptz)
returns public.scripts
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_exam uuid;
  v_x public.scripts%rowtype;
begin
  select b.exam_id into v_exam from public.bookings b where b.id = p_booking;
  insert into public.scripts (booking_id, exam_id, source, number, received_at, late)
  values (p_booking, v_exam, p_source, public.script_number_next(v_exam), case when p_source = 'centre' then p_now end,
    p_source = 'home' and coalesce((
      select s.late from public.home_submissions s
      where s.booking_id = p_booking and s.state not in ('draft', 'rejected')
      order by s.seq desc limit 1), false))
  returning * into v_x;
  update public.script_exceptions e set script_id = v_x.id where e.booking_id = p_booking and e.script_id is null;
  return v_x;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- home_submission_open: the booking's draft submission, made if there is none. p_replaces_all says whether the
-- pages handed in replace the whole script (true) or only the copy pages they show (false: "Replace some pages");
-- the first submission always replaces all. An open draft is returned, set to p_replaces_all.
-- ---------------------------------------------------------------------------------------------
create function public.home_submission_open(p_booking uuid, p_replaces_all boolean default true, p_now timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := public.paper_clock(p_now);
  v_b public.bookings%rowtype;
  v_code text;
  v_all boolean;
  v_s public.home_submissions%rowtype;
begin
  if p_booking is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_b from public.bookings b where b.id = p_booking;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  v_code := public.home_upload_code(v_actor, v_b, v_now);
  if v_code is not null then
    return jsonb_build_object('ok', false, 'code', v_code);
  end if;

  perform public.home_booking_lock(v_b.id);
  v_all := coalesce(p_replaces_all, true)
    or not exists (select 1 from public.home_submissions s where s.booking_id = v_b.id and s.state <> 'draft');
  select * into v_s from public.home_submissions s where s.booking_id = v_b.id and s.state = 'draft' for update;
  if found then
    if v_s.replaces_all <> v_all then
      update public.home_submissions set replaces_all = v_all where id = v_s.id returning * into v_s;
    end if;
  else
    insert into public.home_submissions (booking_id, seq, replaces_all)
    values (v_b.id, coalesce((select max(s.seq) from public.home_submissions s where s.booking_id = v_b.id), 0) + 1, v_all)
    returning * into v_s;
  end if;
  return jsonb_build_object('ok', true, 'submission_id', v_s.id, 'seq', v_s.seq, 'replaces_all', v_s.replaces_all);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_upload_begin: one more file for a draft: a photo (JPEG, PNG, HEIC or HEIF, up to 25 MB) or a PDF (up to
-- 100 MB), at most 60 files per submission. Makes the pending upload row whose path (home/<booking>/<upload>.<ext>)
-- the storage policy lets this user fill. late: whether handing in now would be late.
-- ---------------------------------------------------------------------------------------------
create function public.script_upload_begin(
  p_submission uuid,
  p_kind public.upload_kind,
  p_mime text,
  p_bytes bigint,
  p_now timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := public.paper_clock(p_now);
  v_s public.home_submissions%rowtype;
  v_b public.bookings%rowtype;
  v_e public.exams%rowtype;
  v_code text;
  v_mime text := lower(btrim(coalesce(p_mime, '')));
  v_id uuid := gen_random_uuid();
  v_path text;
  v_pos int;
begin
  if p_submission is null or p_kind is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_s from public.home_submissions s where s.id = p_submission;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select * into v_b from public.bookings b where b.id = v_s.booking_id;
  v_code := public.home_upload_code(v_actor, v_b, v_now);
  if v_code is not null then
    return jsonb_build_object('ok', false, 'code', v_code);
  end if;
  if p_kind not in ('home_photo', 'home_pdf') or p_bytes is null or p_bytes <= 0 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if not public.home_upload_type_ok(p_kind, v_mime) then
    return jsonb_build_object('ok', false, 'code', 'wrong_file_type');
  end if;
  if p_bytes > public.home_upload_max_bytes(p_kind) then
    return jsonb_build_object('ok', false, 'code', 'file_too_large');
  end if;

  perform public.home_booking_lock(v_b.id);
  select * into v_s from public.home_submissions s where s.id = p_submission for update;
  if v_s.state <> 'draft' then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  if (select count(*) from public.script_uploads u where u.submission_id = v_s.id and u.state <> 'discarded') >= 60 then
    return jsonb_build_object('ok', false, 'code', 'too_many_files');
  end if;
  select coalesce(max(u.position), 0) + 1 into v_pos
  from public.script_uploads u where u.submission_id = v_s.id and u.state <> 'discarded';
  v_path := 'home/' || v_b.id::text || '/' || v_id::text || '.'
    || case v_mime when 'image/jpeg' then 'jpg' when 'image/png' then 'png' when 'image/heic' then 'heic'
                   when 'image/heif' then 'heif' else 'pdf' end;
  insert into public.script_uploads (id, exam_id, booking_id, submission_id, kind, position, storage_path, mime, byte_size, uploaded_by)
  values (v_id, v_b.exam_id, v_b.id, v_s.id, p_kind, v_pos, v_path, v_mime, p_bytes, v_actor);

  select * into v_e from public.exams e where e.id = v_b.exam_id;
  return jsonb_build_object('ok', true, 'upload_id', v_id, 'storage_path', v_path, 'position', v_pos,
    'late', v_now >= v_e.starts_at + v_e.duration_minutes * interval '1 minute' + interval '2 hours');
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_upload_stored: the uploader says the file is in storage. The object must be there with the size and type
-- declared (as the storage server recorded them), within the kind's limits; else the row stays pending
-- (not_found / invalid_input). A stored (or later) upload answers ok again.
-- ---------------------------------------------------------------------------------------------
create function public.script_upload_stored(p_upload uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_up public.script_uploads%rowtype;
  v_b public.bookings%rowtype;
  v_code text;
  v_meta jsonb;
begin
  if p_upload is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_up from public.script_uploads u where u.id = p_upload for update;
  if not found or v_up.uploaded_by is distinct from v_actor or v_up.submission_id is null then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select b.* into v_b from public.bookings b join public.home_submissions s on s.booking_id = b.id where s.id = v_up.submission_id;
  v_code := public.home_upload_code(v_actor, v_b, null);
  if v_code is not null then
    return jsonb_build_object('ok', false, 'code', v_code);
  end if;
  if v_up.state = 'discarded' then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  if v_up.state <> 'pending' then
    return jsonb_build_object('ok', true, 'upload_id', v_up.id, 'state', v_up.state);
  end if;

  select o.metadata into v_meta from storage.objects o where o.bucket_id = 'script-uploads' and o.name = v_up.storage_path;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if jsonb_typeof(v_meta -> 'size') is distinct from 'number'
     or (v_meta ->> 'size')::numeric <> v_up.byte_size
     or (v_meta ->> 'size')::numeric > public.home_upload_max_bytes(v_up.kind)
     or (v_meta ->> 'mimetype') is distinct from v_up.mime
     or not public.home_upload_type_ok(v_up.kind, v_meta ->> 'mimetype') then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  update public.script_uploads set state = 'stored', stored_at = now() where id = v_up.id;
  return jsonb_build_object('ok', true, 'upload_id', v_up.id, 'state', 'stored');
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_upload_discard: the family takes a file out of a draft (pending or stored). Its object is removed later by
-- the processing server. Discarding again answers the same.
-- ---------------------------------------------------------------------------------------------
create function public.script_upload_discard(p_upload uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_up public.script_uploads%rowtype;
  v_s public.home_submissions%rowtype;
  v_b public.bookings%rowtype;
  v_code text;
begin
  if p_upload is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_up from public.script_uploads u where u.id = p_upload;
  if not found or v_up.submission_id is null then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select b.* into v_b from public.bookings b join public.home_submissions s on s.booking_id = b.id where s.id = v_up.submission_id;
  v_code := public.home_upload_code(v_actor, v_b, null);
  if v_code is not null then
    return jsonb_build_object('ok', false, 'code', v_code);
  end if;

  perform public.home_booking_lock(v_b.id);
  select * into v_s from public.home_submissions s where s.id = v_up.submission_id for update;
  if v_s.state <> 'draft' then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  select * into v_up from public.script_uploads u where u.id = p_upload for update;
  if v_up.state = 'discarded' then
    return jsonb_build_object('ok', true, 'upload_id', v_up.id, 'state', 'discarded');
  end if;
  if v_up.state not in ('pending', 'stored') then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  update public.script_uploads set state = 'discarded', discarded_at = now() where id = v_up.id;
  return jsonb_build_object('ok', true, 'upload_id', v_up.id, 'state', 'discarded');
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_upload_reorder: the order of a draft's files (each file of the draft not discarded, once).
-- ---------------------------------------------------------------------------------------------
create function public.script_upload_reorder(p_submission uuid, p_uploads uuid[])
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_s public.home_submissions%rowtype;
  v_b public.bookings%rowtype;
  v_code text;
begin
  if p_submission is null or p_uploads is null or cardinality(p_uploads) > 60 or array_position(p_uploads, null) is not null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_s from public.home_submissions s where s.id = p_submission;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select * into v_b from public.bookings b where b.id = v_s.booking_id;
  v_code := public.home_upload_code(v_actor, v_b, null);
  if v_code is not null then
    return jsonb_build_object('ok', false, 'code', v_code);
  end if;

  perform public.home_booking_lock(v_b.id);
  select * into v_s from public.home_submissions s where s.id = p_submission for update;
  if v_s.state <> 'draft' then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  if (select count(distinct x) from unnest(p_uploads) x) <> cardinality(p_uploads)
     or coalesce((select array_agg(u.id order by u.id) from public.script_uploads u
                  where u.submission_id = v_s.id and u.state <> 'discarded'), '{}')
        <> coalesce((select array_agg(x order by x) from unnest(p_uploads) x), '{}') then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  update public.script_uploads u set position = t.n
  from unnest(p_uploads) with ordinality as t(id, n)
  where u.id = t.id and u.position is distinct from t.n::int;
  return jsonb_build_object('ok', true, 'uploads', to_jsonb(p_uploads));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- home_submission_submit: hands a draft in. It needs a stored file and none still uploading, inside the upload
-- window; it is late from finish + 2 hours (one open late exception per booking for staff, and the script is late).
-- Each stored file gets a prepare job. "Replace some pages" keeps the pages the family confirmed blank before. A
-- submission no longer a draft answers as the first call did (its state now), changing nothing.
-- ---------------------------------------------------------------------------------------------
create function public.home_submission_submit(p_submission uuid, p_now timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := public.paper_clock(p_now);
  v_s public.home_submissions%rowtype;
  v_b public.bookings%rowtype;
  v_e public.exams%rowtype;
  v_prev public.home_submissions%rowtype;
  v_code text;
  v_late boolean;
  v_script uuid;
begin
  if p_submission is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_s from public.home_submissions s where s.id = p_submission;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select * into v_b from public.bookings b where b.id = v_s.booking_id;
  v_code := public.home_upload_code(v_actor, v_b, null);
  if v_code is not null then
    return jsonb_build_object('ok', false, 'code', v_code);
  end if;

  perform public.home_booking_lock(v_b.id);
  select * into v_s from public.home_submissions s where s.id = p_submission for update;
  if v_s.state <> 'draft' then
    return public.home_submission_result(v_s.id);
  end if;
  v_code := public.home_upload_code(v_actor, v_b, v_now);
  if v_code is not null then
    return jsonb_build_object('ok', false, 'code', v_code);
  end if;
  if exists (select 1 from public.script_uploads u where u.submission_id = v_s.id and u.state = 'pending') then
    return jsonb_build_object('ok', false, 'code', 'still_uploading');
  end if;
  if not exists (select 1 from public.script_uploads u where u.submission_id = v_s.id and u.state = 'stored') then
    return jsonb_build_object('ok', false, 'code', 'nothing_to_submit');
  end if;

  select * into v_e from public.exams e where e.id = v_b.exam_id;
  v_late := v_now >= v_e.starts_at + v_e.duration_minutes * interval '1 minute' + interval '2 hours';
  if not v_s.replaces_all then
    select * into v_prev from public.home_submissions s
    where s.booking_id = v_b.id and s.state not in ('draft', 'rejected')
    order by s.seq desc limit 1;
  end if;
  update public.home_submissions
  set state = 'checking', submitted_by = v_actor, submitted_at = v_now, late = v_late,
      blank_confirmed = coalesce(v_prev.blank_confirmed, v_s.blank_confirmed)
  where id = v_s.id
  returning * into v_s;
  update public.script_uploads set state = 'queued' where submission_id = v_s.id and state = 'stored';
  insert into public.processing_jobs (upload_id, kind)
  select u.id, 'prepare' from public.script_uploads u where u.submission_id = v_s.id and u.state = 'queued' order by u.position, u.id;

  select x.id into v_script from public.scripts x where x.booking_id = v_b.id;
  if v_late then
    update public.scripts set late = true where id = v_script and not late;
    insert into public.script_exceptions (exam_id, kind, booking_id, script_id, details)
    select v_b.exam_id, 'late', v_b.id, v_script, jsonb_build_object('submission_id', v_s.id, 'seq', v_s.seq)
    where not exists (select 1 from public.script_exceptions e where e.booking_id = v_b.id and e.kind = 'late' and e.state = 'open');
  end if;
  if v_script is not null then
    perform public.script_evaluate_at(v_script, v_now);
  end if;
  return public.home_submission_result(v_s.id);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- home_submission_status: what the family sees after handing in (the student, a linked parent, or an admin to read).
--   submission: the latest handed in (not a draft), or null;
--   pages:      its files' current pages (what each is and where it came from; file_number is the file's place);
--   missing:    answer pages neither in the script nor confirmed blank ("Was page {n} left blank?");
--   retake:     answer pages in the script that cannot be marked as they are ("Retake page {n}" / "Send as it is");
--   unplaced:   its pages with no code not yet placed ("Which page does this follow?");
--   failed:     the file_number of each file that could not be prepared;
--   blank:      pages confirmed blank that the script does not show;
--   script:     number, state and the copy pages it shows; copy_pages: the copy's page count;
--   draft:      the open draft and its files, or null.
-- missing, retake and unplaced are empty until the pages have been checked (exactly what keeps it from received).
-- ---------------------------------------------------------------------------------------------
create function public.home_submission_status(p_booking uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_b public.bookings%rowtype;
  v_code text;
  v_s public.home_submissions%rowtype;
  v_d public.home_submissions%rowtype;
  v_x public.scripts%rowtype;
  v_linked int[];
  v_files jsonb;
  v_settled boolean;
begin
  if p_booking is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_b from public.bookings b where b.id = p_booking;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  v_code := public.sitting_access_code(v_actor, v_b, false);
  if v_code is not null then
    return jsonb_build_object('ok', false, 'code', v_code);
  end if;
  if v_b.sitting <> 'home' then
    return jsonb_build_object('ok', false, 'code', 'wrong_sitting');
  end if;
  if v_b.status not in ('paid', 'cancel_requested') then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;

  v_s := public.home_submission_latest(v_b.id);
  select * into v_d from public.home_submissions s where s.booking_id = v_b.id and s.state = 'draft';
  select * into v_x from public.scripts s where s.booking_id = v_b.id;
  select coalesce(array_agg(l.copy_page order by l.copy_page), '{}') into v_linked
  from public.script_page_links l where l.script_id = v_x.id and l.version = v_x.version;
  select coalesce(jsonb_object_agg(f.id::text, f.n), '{}') into v_files
  from (select u.id, row_number() over (order by u.position nulls last, u.created_at, u.id) as n
        from public.script_uploads u where u.submission_id = v_s.id and u.state <> 'discarded') f;
  v_settled := coalesce(v_s.state in ('needs_attention', 'received'), false);

  return jsonb_build_object(
    'ok', true,
    'submission', case when v_s.id is not null then jsonb_build_object('id', v_s.id, 'seq', v_s.seq, 'state', v_s.state,
      'late', v_s.late, 'submitted_at', v_s.submitted_at, 'checked_at', v_s.checked_at, 'replaces_all', v_s.replaces_all) end,
    'pages', (
      select coalesce(jsonb_agg(jsonb_build_object('page_id', p.id, 'copy_page', p.copy_page, 'state', p.state,
               'flags', coalesce(p.quality -> 'flags', '[]'::jsonb), 'upload_id', p.upload_id, 'source_index', p.source_index,
               'file_number', (v_files ->> p.upload_id::text)::int)
             order by (v_files ->> p.upload_id::text)::int, p.source_index), '[]'::jsonb)
      from public.script_pages p
      where v_files ? p.upload_id::text and p.replaced_at is null),
    'missing', case when v_settled then to_jsonb(public.home_missing_pages(v_s.id, true)) else '[]'::jsonb end,
    'retake', case when v_settled then (
      select coalesce(jsonb_agg(jsonb_build_object('page_id', p.id, 'copy_page', l.copy_page,
               'flags', coalesce(p.quality -> 'flags', '[]'::jsonb)) order by l.copy_page), '[]'::jsonb)
      from public.script_page_links l
      join public.script_pages p on p.id = l.page_id
      where l.script_id = v_x.id and l.version = v_x.version
        and public.script_page_is_answer(p.copy_id, p.copy_page)
        and public.script_page_poor(p.quality, p.marking_path, true)
        and not exists (select 1 from public.script_exceptions e where e.page_id = p.id and e.kind = 'poor_quality'))
      else '[]'::jsonb end,
    'unplaced', case when v_settled then (
      select coalesce(jsonb_agg(jsonb_build_object('page_id', p.id, 'upload_id', p.upload_id, 'source_index', p.source_index,
               'file_number', (v_files ->> p.upload_id::text)::int)
             order by (v_files ->> p.upload_id::text)::int, p.source_index), '[]'::jsonb)
      from public.script_pages p
      where v_files ? p.upload_id::text and p.replaced_at is null and p.state = 'unmatched' and p.placed_after is null)
      else '[]'::jsonb end,
    'failed', (
      select coalesce(jsonb_agg((v_files ->> u.id::text)::int order by (v_files ->> u.id::text)::int), '[]'::jsonb)
      from public.script_uploads u where v_files ? u.id::text and u.state = 'failed'),
    'blank', case when v_s.id is not null then
      to_jsonb(array(select x from unnest(v_s.blank_confirmed) x where x <> all (v_linked) order by x)) else '[]'::jsonb end,
    'script', case when v_x.id is not null then jsonb_build_object('number', v_x.number, 'state', v_x.state,
      'pages', to_jsonb(v_linked)) end,
    'copy_pages', (select c.page_count from public.paper_copies c where c.booking_id = v_b.id order by c.created_at desc, c.id limit 1),
    'draft', case when v_d.id is not null then jsonb_build_object('id', v_d.id, 'seq', v_d.seq, 'replaces_all', v_d.replaces_all,
      'uploads', (
        select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'kind', u.kind, 'mime', u.mime, 'byte_size', u.byte_size,
                 'state', u.state, 'position', u.position, 'storage_path', u.storage_path, 'mine', u.uploaded_by = v_actor)
               order by u.position nulls last, u.created_at, u.id), '[]'::jsonb)
        from public.script_uploads u where u.submission_id = v_d.id and u.state <> 'discarded')) end);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- home_missing_confirm_blank: the family says these answer pages were left blank ("Was page {n} left blank?" ->
-- Yes). Each must be an answer page of the paper version that the script does not show; the submission must be the
-- latest handed in, checked (needs attention or received).
-- ---------------------------------------------------------------------------------------------
create function public.home_missing_confirm_blank(p_submission uuid, p_pages int[])
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_s public.home_submissions%rowtype;
  v_b public.bookings%rowtype;
  v_code text;
  v_gaps int[];
begin
  if p_submission is null or p_pages is null or cardinality(p_pages) = 0 or cardinality(p_pages) > 100
     or array_position(p_pages, null) is not null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_s from public.home_submissions s where s.id = p_submission;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select * into v_b from public.bookings b where b.id = v_s.booking_id;
  v_code := public.home_upload_code(v_actor, v_b, null);
  if v_code is not null then
    return jsonb_build_object('ok', false, 'code', v_code);
  end if;

  perform public.home_booking_lock(v_b.id);
  select * into v_s from public.home_submissions s where s.id = p_submission for update;
  if v_s.state not in ('needs_attention', 'received') or (public.home_submission_latest(v_b.id)).id is distinct from v_s.id then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  v_gaps := public.home_missing_pages(v_s.id, false);
  if exists (select 1 from unnest(p_pages) x where x <> all (v_gaps)) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  update public.home_submissions
  set blank_confirmed = array(select distinct x from unnest(blank_confirmed || p_pages) x order by x)
  where id = v_s.id;
  return jsonb_build_object('ok', true, 'state', public.home_reevaluate(v_b.id, v_s.id));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- home_page_place: the family says which copy page a page with no code follows ("Which page does this follow?"),
-- 1 to the copy's page count. The page then no longer waits to be placed (it does not stand in for a missing answer
-- page), and one open uncoded_family_page exception asks staff to confirm it (placing again updates it).
-- ---------------------------------------------------------------------------------------------
create function public.home_page_place(p_page uuid, p_after_page int)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_p public.script_pages%rowtype;
  v_sub uuid;
  v_s public.home_submissions%rowtype;
  v_b public.bookings%rowtype;
  v_code text;
  v_pages int;
  v_exc uuid;
begin
  if p_page is null or p_after_page is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_p from public.script_pages p where p.id = p_page;
  select u.submission_id into v_sub from public.script_uploads u where u.id = v_p.upload_id;
  if v_p.id is null or v_sub is null then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select b.* into v_b from public.bookings b join public.home_submissions s on s.booking_id = b.id where s.id = v_sub;
  v_code := public.home_upload_code(v_actor, v_b, null);
  if v_code is not null then
    return jsonb_build_object('ok', false, 'code', v_code);
  end if;

  perform public.home_booking_lock(v_b.id);
  select * into v_s from public.home_submissions s where s.id = v_sub for update;
  if v_s.state not in ('needs_attention', 'received') or (public.home_submission_latest(v_b.id)).id is distinct from v_s.id then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  select * into v_p from public.script_pages p where p.id = p_page for update;
  select c.page_count into v_pages from public.paper_copies c where c.booking_id = v_b.id order by c.created_at desc, c.id limit 1;
  if v_p.replaced_at is not null or v_p.state <> 'unmatched' or p_after_page < 1 or p_after_page > coalesce(v_pages, 0) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  update public.script_pages set placed_after = p_after_page where id = v_p.id;
  update public.script_exceptions e
  set details = jsonb_build_object('after_page', p_after_page, 'from', 'family')
  where e.page_id = v_p.id and e.kind = 'uncoded_family_page' and e.state = 'open'
  returning e.id into v_exc;
  if v_exc is null then
    insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details)
    values (v_p.exam_id, 'uncoded_family_page', v_b.id, (select x.id from public.scripts x where x.booking_id = v_b.id),
      v_p.id, v_p.upload_id, jsonb_build_object('after_page', p_after_page, 'from', 'family'))
    returning id into v_exc;
  end if;
  return jsonb_build_object('ok', true, 'state', public.home_reevaluate(v_b.id, v_s.id), 'exception_id', v_exc);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- home_page_send_as_is: the family sends a page that cannot be marked as it is ("Send as it is"), for an answer
-- page the script shows (current, matched, from a home file of this booking) with a quality flag or no marking
-- picture. One poor_quality exception on the page tells staff; the submission no longer waits for a retake of it.
-- ---------------------------------------------------------------------------------------------
create function public.home_page_send_as_is(p_page uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_p public.script_pages%rowtype;
  v_sub uuid;
  v_s public.home_submissions%rowtype;
  v_b public.bookings%rowtype;
  v_x public.scripts%rowtype;
  v_code text;
  v_exc uuid;
begin
  if p_page is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_p from public.script_pages p where p.id = p_page;
  select u.submission_id into v_sub from public.script_uploads u where u.id = v_p.upload_id;
  if v_p.id is null or v_sub is null then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select b.* into v_b from public.bookings b join public.home_submissions s on s.booking_id = b.id where s.id = v_sub;
  v_code := public.home_upload_code(v_actor, v_b, null);
  if v_code is not null then
    return jsonb_build_object('ok', false, 'code', v_code);
  end if;

  perform public.home_booking_lock(v_b.id);
  v_s := public.home_submission_latest(v_b.id);
  select * into v_s from public.home_submissions s where s.id = v_s.id for update;
  if v_s.id is null or v_s.state not in ('needs_attention', 'received') then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  select * into v_x from public.scripts s where s.booking_id = v_b.id;
  select * into v_p from public.script_pages p where p.id = p_page;
  if v_p.replaced_at is not null or v_p.state <> 'matched' or v_p.booking_id is distinct from v_b.id
     or not exists (select 1 from public.script_page_links l where l.script_id = v_x.id and l.version = v_x.version and l.page_id = v_p.id)
     or not public.script_page_is_answer(v_p.copy_id, v_p.copy_page)
     or not public.script_page_poor(v_p.quality, v_p.marking_path, true) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  select e.id into v_exc from public.script_exceptions e where e.page_id = v_p.id and e.kind = 'poor_quality' order by e.created_at limit 1;
  if v_exc is null then
    insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details)
    values (v_p.exam_id, 'poor_quality', v_b.id, v_x.id, v_p.id, v_p.upload_id,
      jsonb_build_object('flags', coalesce(v_p.quality -> 'flags', '[]'::jsonb), 'copy_page', v_p.copy_page,
        'marking_picture', v_p.marking_path is not null, 'from', 'family'))
    returning id into v_exc;
  end if;
  return jsonb_build_object('ok', true, 'state', public.home_reevaluate(v_b.id, v_s.id), 'exception_id', v_exc);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Discarded draft files, for the processing server (service role): up to p_limit (1 to 1000) discarded more than an
-- hour ago and not yet purged, oldest first, as [{id, storage_path}]; and marking them purged once their objects are
-- deleted. Only discarded uploads are ever listed or marked; they were never handed in.
-- ---------------------------------------------------------------------------------------------
create function public.script_discarded_take(p_limit int, p_now timestamptz default null)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'storage_path', t.storage_path) order by t.discarded_at, t.id), '[]'::jsonb)
  from (
    select u.id, u.storage_path, u.discarded_at
    from public.script_uploads u
    where u.state = 'discarded' and u.purged_at is null
      and u.discarded_at < public.paper_clock(p_now) - interval '1 hour'
    order by u.discarded_at, u.id
    limit least(greatest(coalesce(p_limit, 100), 1), 1000)
  ) t
$$;

create function public.script_upload_purged(p_ids uuid[])
returns void
language sql
security definer
set search_path = ''
as $$
  update public.script_uploads set purged_at = now()
  where id = any (coalesce(p_ids, '{}')) and state = 'discarded' and purged_at is null
$$;

-- ---------------------------------------------------------------------------------------------
-- Access.
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.home_upload_type_ok(public.upload_kind, text) from public, anon, authenticated, service_role;
revoke execute on function public.home_upload_max_bytes(public.upload_kind) from public, anon, authenticated, service_role;
revoke execute on function public.home_upload_code(uuid, public.bookings, timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.home_booking_lock(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.home_submission_latest(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.home_missing_pages(uuid, boolean) from public, anon, authenticated, service_role;
revoke execute on function public.home_reevaluate(uuid, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.home_submission_result(uuid) from public, anon, authenticated, service_role;

revoke execute on function public.home_submission_open(uuid, boolean, timestamptz) from public, anon;
revoke execute on function public.script_upload_begin(uuid, public.upload_kind, text, bigint, timestamptz) from public, anon;
revoke execute on function public.script_upload_stored(uuid) from public, anon;
revoke execute on function public.script_upload_discard(uuid) from public, anon;
revoke execute on function public.script_upload_reorder(uuid, uuid[]) from public, anon;
revoke execute on function public.home_submission_submit(uuid, timestamptz) from public, anon;
revoke execute on function public.home_submission_status(uuid) from public, anon;
revoke execute on function public.home_missing_confirm_blank(uuid, int[]) from public, anon;
revoke execute on function public.home_page_place(uuid, int) from public, anon;
revoke execute on function public.home_page_send_as_is(uuid) from public, anon;
grant execute on function public.home_submission_open(uuid, boolean, timestamptz) to authenticated;
grant execute on function public.script_upload_begin(uuid, public.upload_kind, text, bigint, timestamptz) to authenticated;
grant execute on function public.script_upload_stored(uuid) to authenticated;
grant execute on function public.script_upload_discard(uuid) to authenticated;
grant execute on function public.script_upload_reorder(uuid, uuid[]) to authenticated;
grant execute on function public.home_submission_submit(uuid, timestamptz) to authenticated;
grant execute on function public.home_submission_status(uuid) to authenticated;
grant execute on function public.home_missing_confirm_blank(uuid, int[]) to authenticated;
grant execute on function public.home_page_place(uuid, int) to authenticated;
grant execute on function public.home_page_send_as_is(uuid) to authenticated;

revoke execute on function public.script_discarded_take(int, timestamptz) from public, anon, authenticated;
revoke execute on function public.script_upload_purged(uuid[]) from public, anon, authenticated;
grant execute on function public.script_discarded_take(int, timestamptz) to service_role;
grant execute on function public.script_upload_purged(uuid[]) to service_role;
