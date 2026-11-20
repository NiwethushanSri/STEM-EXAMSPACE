-- Phase 2 Task 4: matching prepared pages to candidates and assembling scripts.
--
-- The processing server hands each prepared upload's page list to script_pages_record, which in one transaction
-- replaces the upload's earlier pages (a rerun), works out what each page is, raises exceptions for staff, puts the
-- matched pages into the candidate's script (a new version whenever the set of pages changes), marks the upload
-- processed and works out the state of the home submission and of the script.
--
-- Page states: matched (counts for its booking); duplicate (the same copy page again, set aside, kept); blank (a
-- blank sheet: recorded, never discarded); unmatched (no code: a home family says where it goes, a centre page goes
-- to staff); rejected (a code that is unknown, of another exam, or of a booking not expected in this upload).
--
-- Versions: a home submission makes one version once every upload in it is prepared (its matched pages over the
-- previous version's links, or alone when it replaces all pages); a scanner file makes one version for each script
-- it changes (its pages added to the current links). A rerun of an upload first undoes the latest version it made,
-- so the same job recorded twice ends with one set of pages and one version. A page that an earlier version, kept
-- as history, still shows is not deleted by a rerun but marked replaced (replaced_at): every query of an upload's
-- current pages filters replaced_at is null.
--
-- Exceptions raised here carry upload_id = the upload whose processing raised them, page_id where one page is
-- concerned, booking_id = the booking concerned (home: the uploader's; centre: the booking the page was printed
-- for) and script_id once that booking has a script. A script counts the open exceptions with its script_id, and
-- those of its booking that have none.
--
-- Lock order, for every function that changes scripts: processing job, upload, booking (advisory lock, in uuid
-- order), home submission, script.

-- ---------------------------------------------------------------------------------------------
-- Schema additions.
-- ---------------------------------------------------------------------------------------------
alter table public.script_pages add column replaced_at timestamptz;
alter table public.script_pages drop constraint script_pages_upload_index_key;
create unique index script_pages_upload_index_key on public.script_pages (upload_id, source_index) where replaced_at is null;

-- What made a version: a home submission, or a scanner file or rerun of an upload (null for staff corrections).
alter table public.script_versions
  add column submission_id uuid references public.home_submissions (id),
  add column upload_id uuid references public.script_uploads (id);

create index script_exceptions_page_idx on public.script_exceptions (page_id) where page_id is not null;
create index script_exceptions_upload_idx on public.script_exceptions (upload_id) where upload_id is not null;
create index script_exceptions_script_idx on public.script_exceptions (script_id) where script_id is not null;
create index script_exceptions_booking_idx on public.script_exceptions (booking_id) where booking_id is not null;

-- ---------------------------------------------------------------------------------------------
-- Helpers (internal).
-- ---------------------------------------------------------------------------------------------

-- Whether page p_page of a copy is an answer page: its paper version's role, or a spare page (after the paper's
-- own pages, up to the copy's page count).
create function public.script_page_is_answer(p_copy uuid, p_page int)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select case
      when p_page > p.page_count then p_page <= c.page_count
      else exists (select 1 from public.paper_page_roles r where r.paper_id = p.id and r.page = p_page and r.role = 'answer')
    end
    from public.paper_copies c join public.exam_papers p on p.id = c.paper_id
    where c.id = p_copy and p_page >= 1), false)
$$;

-- A page that cannot be marked as it is: a quality flag, or an answer page without a marking picture.
create function public.script_page_poor(p_quality jsonb, p_marking text, p_answer boolean)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(p_quality -> 'flags' ?| array['blurred', 'dark', 'cut_off', 'layout_unexpected'], false)
    or (coalesce(p_answer, false) and p_marking is null)
$$;

-- The current version's links of a script as {"<copy page>": "<page id>"}.
create function public.script_links(p_script uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_object_agg(l.copy_page::text, l.page_id), '{}'::jsonb)
  from public.scripts s
  join public.script_page_links l on l.script_id = s.id and l.version = s.version
  where s.id = p_script
$$;

-- Writes the next version of a script with these links, unless they are the current version's links. True when a
-- version was written.
create function public.script_version_write(
  p_script uuid,
  p_links jsonb,
  p_submission uuid,
  p_upload uuid,
  p_reason text,
  p_now timestamptz
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_x public.scripts%rowtype;
  v_links jsonb := coalesce(p_links, '{}'::jsonb);
begin
  select * into v_x from public.scripts s where s.id = p_script for update;
  if not found or public.script_links(v_x.id) = v_links then
    return false;
  end if;
  insert into public.script_versions (script_id, version, created_at, reason, submission_id, upload_id)
  values (v_x.id, v_x.version + 1, p_now, p_reason, p_submission, p_upload);
  insert into public.script_page_links (script_id, version, copy_page, page_id)
  select v_x.id, v_x.version + 1, t.k::int, t.v::uuid from jsonb_each_text(v_links) t(k, v);
  update public.scripts set version = v_x.version + 1 where id = v_x.id;
  return true;
end;
$$;

-- Creates the booking's script: numbered per exam (script_number_next holds the exam's lock), from a home
-- submission or a centre scan. A centre script is received when its first page arrives. Exceptions already raised
-- for the booking are attached to it.
create function public.script_create(p_booking uuid, p_source public.script_source, p_now timestamptz)
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
  insert into public.scripts (booking_id, exam_id, source, number, received_at)
  values (p_booking, v_exam, p_source, public.script_number_next(v_exam), case when p_source = 'centre' then p_now end)
  returning * into v_x;
  update public.script_exceptions e set script_id = v_x.id where e.booking_id = p_booking and e.script_id is null;
  return v_x;
end;
$$;

-- Raises mixed_versions for a script whose current links come from two paper versions, unless one is open.
create function public.script_raise_mixed(p_script uuid, p_upload uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.script_exceptions (exam_id, kind, booking_id, script_id, upload_id, details)
  select s.exam_id, 'mixed_versions', s.booking_id, s.id, p_upload, jsonb_build_object('paper_ids', m.papers)
  from public.scripts s
  cross join lateral (
    select jsonb_agg(distinct c.paper_id) as papers, count(distinct c.paper_id) as n
    from public.script_page_links l
    join public.script_pages p on p.id = l.page_id
    join public.paper_copies c on c.id = p.copy_id
    where l.script_id = s.id and l.version = s.version
  ) m
  where s.id = p_script and m.n > 1
    and not exists (select 1 from public.script_exceptions e where e.script_id = s.id and e.kind = 'mixed_versions' and e.state = 'open')
$$;

-- Makes a home submission's version once every upload in it has been prepared or has failed for good: its matched
-- pages over the previous version's links, or alone when it replaces all pages. p_upload is the upload just
-- recorded (still processing until its record ends) or just failed. A submission that a later one has already
-- replaced makes no version; an upload of an older submission prepared again swaps its pages that the current
-- version shows for the new pages at the same copy page (or drops them). The caller holds the booking's lock.
-- True when a version was written.
create function public.home_submission_assemble(p_submission uuid, p_upload uuid, p_now timestamptz)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sub public.home_submissions%rowtype;
  v_x public.scripts%rowtype;
  v_links jsonb;
begin
  select * into v_sub from public.home_submissions s where s.id = p_submission for update;
  if not found or v_sub.state in ('draft', 'rejected') then
    return false;
  end if;
  select * into v_x from public.scripts s where s.booking_id = v_sub.booking_id for update;
  if v_x.id is null or exists (
    select 1 from public.script_uploads u
    where u.submission_id = v_sub.id and u.id is distinct from p_upload and u.state in ('pending', 'stored', 'queued', 'processing')) then
    return false;
  end if;

  if not exists (select 1 from public.script_versions v where v.script_id = v_x.id and v.submission_id = v_sub.id) then
    if exists (select 1 from public.script_versions v join public.home_submissions s2 on s2.id = v.submission_id
               where v.script_id = v_x.id and s2.seq > v_sub.seq) then
      return false;
    end if;
    select coalesce(jsonb_object_agg(p.copy_page::text, p.id), '{}'::jsonb) into v_links
    from public.script_pages p join public.script_uploads u on u.id = p.upload_id
    where u.submission_id = v_sub.id and p.replaced_at is null and p.state = 'matched';
    return public.script_version_write(v_x.id,
      case when v_sub.replaces_all then '{}'::jsonb else public.script_links(v_x.id) end || v_links,
      v_sub.id, null, 'home_submission', p_now);
  end if;

  return public.script_version_write(v_x.id, (
    select coalesce(jsonb_object_agg(l.copy_page::text, coalesce(n.id, l.page_id))
                      filter (where o.id is null or n.id is not null), '{}'::jsonb)
    from public.script_page_links l
    left join public.script_pages o on o.id = l.page_id and o.upload_id = p_upload and o.replaced_at is not null
    left join public.script_pages n on o.id is not null and n.upload_id = p_upload and n.replaced_at is null
      and n.state = 'matched' and n.copy_page = l.copy_page
    where l.script_id = v_x.id and l.version = v_x.version), null, p_upload, 'reprocessed', p_now);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- A home submission's state, from its uploads and the script's current links. checking while any upload is not
-- yet prepared; else received when the pages come from one paper version, every answer page of that version is
-- linked or confirmed blank by the family (blank_confirmed), no linked answer page needs a retake (a quality flag
-- or no marking picture, unless the family sent it as it is: a poor_quality exception exists for the page) and no
-- page without a code is waiting to be placed; otherwise needs_attention. Drafts and rejected submissions are left
-- as they are. Returns the state.
-- ---------------------------------------------------------------------------------------------
create function public.home_submission_evaluate(p_submission uuid, p_now timestamptz)
returns public.submission_state
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s public.home_submissions%rowtype;
  v_script uuid;
  v_version int;
  v_papers uuid[];
  v_paper uuid;
  v_state public.submission_state;
begin
  select * into v_s from public.home_submissions s where s.id = p_submission for update;
  if not found then
    return null;
  end if;
  if v_s.state in ('draft', 'rejected') then
    return v_s.state;
  end if;

  if exists (select 1 from public.script_uploads u
             where u.submission_id = v_s.id and u.state in ('pending', 'stored', 'queued', 'processing')) then
    v_state := 'checking';
  else
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

    if v_paper is null
       or exists (
         select 1 from public.paper_page_roles r
         where r.paper_id = v_paper and r.role = 'answer' and r.page <> all (v_s.blank_confirmed)
           and not exists (select 1 from public.script_page_links l
                           where l.script_id = v_script and l.version = v_version and l.copy_page = r.page))
       or exists (
         select 1 from public.script_page_links l
         join public.script_pages p on p.id = l.page_id
         where l.script_id = v_script and l.version = v_version
           and public.script_page_poor(p.quality, p.marking_path, public.script_page_is_answer(p.copy_id, p.copy_page))
           and not exists (select 1 from public.script_exceptions e where e.page_id = p.id and e.kind = 'poor_quality'))
       or exists (
         select 1 from public.script_pages p
         join public.script_uploads u on u.id = p.upload_id
         where u.submission_id = v_s.id and p.replaced_at is null and p.state = 'unmatched' and p.placed_after is null)
    then
      v_state := 'needs_attention';
    else
      v_state := 'received';
    end if;
  end if;

  if v_state is distinct from v_s.state then
    update public.home_submissions
    set state = v_state, checked_at = case when v_state <> 'checking' then p_now else checked_at end
    where id = v_s.id;
  end if;
  return v_state;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- A script's state. Home scripts first check the booking's latest submission (not draft or rejected): complete
-- exactly while it is received, and received_at is set the first time it is. Centre scripts keep complete as staff
-- set it (Task 9). Then: checking while the submission is checking or an upload of the booking, or of a linked
-- page, is queued or processing; verified when complete with no open exception; receiving for a centre script
-- that is not complete yet and has no open exception; otherwise needs_attention. Scripts already past verification
-- (ready to mark and later, withdrawn, void) are left alone.
-- ---------------------------------------------------------------------------------------------
create function public.script_evaluate_at(p_script uuid, p_now timestamptz)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_x public.scripts%rowtype;
  v_sub uuid;
  v_sub_state public.submission_state;
  v_complete boolean;
  v_busy boolean;
  v_open boolean;
  v_state public.script_state;
  v_received timestamptz;
begin
  select * into v_x from public.scripts s where s.id = p_script;
  if not found then
    return;
  end if;
  if v_x.source = 'home' then
    select s.id into v_sub from public.home_submissions s
    where s.booking_id = v_x.booking_id and s.state not in ('draft', 'rejected')
    order by s.seq desc limit 1
    for update;
  end if;
  select * into v_x from public.scripts s where s.id = p_script for update;
  if v_x.state not in ('receiving', 'checking', 'needs_attention', 'verified') then
    return;
  end if;

  v_complete := v_x.complete;
  v_received := v_x.received_at;
  if v_x.source = 'home' then
    if v_sub is not null then
      v_sub_state := public.home_submission_evaluate(v_sub, p_now);
    end if;
    v_complete := coalesce(v_sub_state = 'received', false);
    if v_complete then
      v_received := coalesce(v_received, p_now);
    end if;
  end if;

  v_busy := coalesce(v_sub_state = 'checking', false)
    or exists (select 1 from public.script_uploads u
               where u.state in ('queued', 'processing')
                 and (u.booking_id = v_x.booking_id
                      or u.submission_id in (select s.id from public.home_submissions s where s.booking_id = v_x.booking_id)))
    or exists (select 1 from public.script_page_links l
               join public.script_pages p on p.id = l.page_id
               join public.script_uploads u on u.id = p.upload_id
               where l.script_id = v_x.id and l.version = v_x.version and u.state in ('queued', 'processing'));
  v_open := exists (select 1 from public.script_exceptions e
                    where e.state = 'open'
                      and (e.script_id = v_x.id or (e.script_id is null and e.booking_id = v_x.booking_id)));
  v_state := case
    when v_busy then 'checking'
    when v_complete and not v_open then 'verified'
    when v_x.source = 'centre' and not v_complete and not v_open then 'receiving'
    else 'needs_attention'
  end;

  if (v_x.state, v_x.complete, v_x.received_at) is distinct from (v_state, v_complete, v_received) then
    update public.scripts set state = v_state, complete = v_complete, received_at = v_received where id = v_x.id;
  end if;
end;
$$;

-- Recomputes a script's state now (Tasks 6, 9 and 10 call it after changing a submission, a page or an exception).
create function public.script_evaluate(p_script uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  select public.script_evaluate_at(p_script, now())
$$;

-- ---------------------------------------------------------------------------------------------
-- Checks a page list from the processing server: every item {source_index, code|null, copy_page|null, blank,
-- quality:{sharpness, brightness, cut_off, flags}, rotation, full_path, marking_path|null}, positions unique, and
-- the pictures at <prefix><source_index>-full.jpg and -marking.jpg (prefix = <exam>/<upload>/).
-- ---------------------------------------------------------------------------------------------
create function public.script_pages_valid(p_pages jsonb, p_prefix text)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  e jsonb;
begin
  if p_pages is null or jsonb_typeof(p_pages) <> 'array' or jsonb_array_length(p_pages) > 5000 then
    return false;
  end if;
  for e in select x from jsonb_array_elements(p_pages) x loop
    if jsonb_typeof(e) <> 'object'
       or jsonb_typeof(e -> 'source_index') is distinct from 'number' or (e ->> 'source_index') !~ '^[0-9]{1,5}$'
       or jsonb_typeof(e -> 'blank') is distinct from 'boolean'
       or coalesce(jsonb_typeof(e -> 'code'), 'null') not in ('null', 'string')
       or coalesce(jsonb_typeof(e -> 'copy_page'), 'null') not in ('null', 'number')
       or ((e ->> 'code') is null) <> ((e ->> 'copy_page') is null)
       or coalesce(jsonb_typeof(e -> 'rotation'), 'null') <> 'number' or (e ->> 'rotation') not in ('0', '90', '180', '270')
       or jsonb_typeof(e -> 'quality') is distinct from 'object'
       or jsonb_typeof(e -> 'quality' -> 'sharpness') is distinct from 'number'
       or jsonb_typeof(e -> 'quality' -> 'brightness') is distinct from 'number'
       or jsonb_typeof(e -> 'quality' -> 'cut_off') is distinct from 'boolean'
       or jsonb_typeof(e -> 'quality' -> 'flags') is distinct from 'array'
       or (e ->> 'full_path') is distinct from p_prefix || (e ->> 'source_index') || '-full.jpg'
       or coalesce(jsonb_typeof(e -> 'marking_path'), 'null') not in ('null', 'string') then
      return false;
    end if;
    if (e ->> 'code') is not null and (char_length(e ->> 'code') > 20 or (e ->> 'copy_page') !~ '^[1-9][0-9]{0,3}$') then
      return false;
    end if;
    if (e ->> 'marking_path') is not null and (e ->> 'marking_path') <> p_prefix || (e ->> 'source_index') || '-marking.jpg' then
      return false;
    end if;
    if exists (select 1 from jsonb_array_elements(e -> 'quality' -> 'flags') f where jsonb_typeof(f) <> 'string') then
      return false;
    end if;
  end loop;
  return (select count(distinct x ->> 'source_index') from jsonb_array_elements(p_pages) x) = jsonb_array_length(p_pages);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Records the prepared pages of a claimed prepare job (the processing server, with the service role). Acts only
-- for the worker and attempt that hold the job (else {ok:false, code:'conflict'}, nothing changed). p_sha256 is
-- the SHA-256 of the original as downloaded (64 lowercase hex characters, else invalid_input): the first record
-- stores it on the upload; a later record must bring the same hash, else {ok:false, code:'conflict', reason:
-- 'sha256_mismatch'} and nothing changes (an original is never changed). Returns {ok:true, pages, matched,
-- exceptions} (the upload's current pages, how many matched, its open exceptions).
--
-- What each page is:
--   blank sheet (no code)                      -> blank, no exception;
--   no code, not blank                         -> unmatched; home: the family places it; scan: no_code;
--   code not found, or a page the copy lacks   -> rejected, unknown_code;
--   copy of another exam                       -> rejected, other_exam;
--   home: copy of another booking              -> rejected, not_expected (reason other_booking);
--   scan: booking not paid / cancel_requested, sitting at home, at another centre, or marked absent
--                                              -> rejected, not_expected (reason booking_status, home_sitting,
--                                                 other_centre or absent);
--   otherwise                                  -> matched, or duplicate when the same copy page is there twice:
--                                                 the usable page (no quality flag, a marking picture for an
--                                                 answer page) is kept before a flagged one, then the sharper.
--                                                 Home: within the submission, no exception. Scan: across the
--                                                 booking's scanner files, duplicate exception for the page set
--                                                 aside.
-- Scan pages with a quality flag, and matched scan answer pages without a marking picture, raise poor_quality.
-- A script whose linked pages come from two paper versions raises mixed_versions.
-- ---------------------------------------------------------------------------------------------
create function public.script_pages_record(
  p_job bigint,
  p_worker text,
  p_attempt int,
  p_sha256 text,
  p_pages jsonb,
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
  v_sub public.home_submissions%rowtype;
  v_home boolean;
  v_centre uuid;
  v_old uuid[];
  v_old_slots jsonb;
  v_placed jsonb;
  v_found jsonb;
  v_bookings uuid[];
  v_b uuid;
  v_x public.scripts%rowtype;
  v_links jsonb;
  v_slot int;
  v_linked uuid;
  v_winner uuid;
  v_changed uuid[] := '{}';
begin
  select * into v_job from public.processing_jobs j where j.id = p_job for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_job.state <> 'running' or v_job.locked_by is distinct from left(coalesce(p_worker, ''), 100)
     or v_job.attempts is distinct from p_attempt then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  select * into v_up from public.script_uploads u where u.id = v_job.upload_id for update;
  if v_job.kind <> 'prepare' or p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$'
     or not public.script_pages_valid(p_pages, v_up.exam_id::text || '/' || v_up.id::text || '/') then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_up.sha256 is not null and v_up.sha256 <> p_sha256 then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'sha256_mismatch');
  end if;
  v_home := v_up.submission_id is not null;

  -- Every booking this can touch: those of the upload's current pages, of the codes read and of the submission.
  select coalesce(array_agg(distinct t.b order by t.b), '{}') into v_bookings
  from (
    select p.booking_id as b from public.script_pages p
    where p.upload_id = v_up.id and p.replaced_at is null and p.booking_id is not null
    union
    select c.booking_id from jsonb_array_elements(p_pages) e
    join public.paper_copies c on c.code = e ->> 'code'
    join public.exam_papers ep on ep.id = c.paper_id and ep.exam_id = v_up.exam_id
    union
    select s.booking_id from public.home_submissions s where s.id = v_up.submission_id
  ) t;
  foreach v_b in array v_bookings loop
    perform pg_advisory_xact_lock(hashtextextended('script_booking:' || v_b::text, 0));
  end loop;
  if v_home then
    select * into v_sub from public.home_submissions s where s.id = v_up.submission_id for update;
  else
    select sb.centre_id into v_centre from public.scan_batches sb where sb.id = v_up.batch_id;
  end if;

  -- A rerun. The latest versions this upload (or its submission) made are undone, to be made again below; the
  -- open exceptions of the earlier run go; earlier pages go, except those a kept version still shows, which are
  -- marked replaced. A family's placement of a page with no code carries over to the page at the same position.
  for v_x in
    select s.* from public.scripts s
    join public.script_versions v on v.script_id = s.id and v.version = s.version
    where s.booking_id = any (v_bookings)
      and (v.upload_id = v_up.id or (v_home and v.submission_id = v_up.submission_id))
    for update of s
  loop
    delete from public.script_page_links l where l.script_id = v_x.id and l.version = v_x.version;
    delete from public.script_versions v where v.script_id = v_x.id and v.version = v_x.version;
    update public.scripts set version = v_x.version - 1 where id = v_x.id;
  end loop;

  select coalesce(array_agg(p.id), '{}'),
         coalesce(jsonb_agg(jsonb_build_object('booking_id', p.booking_id, 'copy_page', p.copy_page))
                    filter (where p.booking_id is not null), '[]'::jsonb),
         coalesce(jsonb_object_agg(p.source_index::text, jsonb_build_object('id', p.id, 'placed_after', p.placed_after))
                    filter (where p.state = 'unmatched' and p.placed_after is not null), '{}'::jsonb)
  into v_old, v_old_slots, v_placed
  from public.script_pages p where p.upload_id = v_up.id and p.replaced_at is null;

  delete from public.script_exceptions e
  where e.state = 'open'
    and e.kind in ('no_code', 'unknown_code', 'other_exam', 'not_expected', 'duplicate', 'mixed_versions', 'poor_quality')
    and (e.upload_id = v_up.id or e.page_id = any (v_old));
  delete from public.script_pages p
  where p.id = any (v_old) and not exists (select 1 from public.script_page_links l where l.page_id = p.id);
  update public.script_pages p set replaced_at = v_now where p.id = any (v_old);

  -- What each page is.
  with f as (
    select (e ->> 'source_index')::int as idx, e, c.id as copy_id, c.booking_id as copy_booking, c.page_count as copy_pages,
      ep.exam_id as copy_exam, b.status as b_status, b.sitting as b_sitting, b.centre_id as b_centre,
      exists (select 1 from public.attendance a
              where a.exam_id = b.exam_id and a.student_id = b.student_id and a.status = 'absent') as absent
    from jsonb_array_elements(p_pages) e
    left join public.paper_copies c on c.code = e ->> 'code'
    left join public.exam_papers ep on ep.id = c.paper_id
    left join public.bookings b on b.id = c.booking_id
  ), g as (
    select f.*,
      case
        when f.e ->> 'code' is null then case when (f.e ->> 'blank')::boolean then 'blank' else 'no_code' end
        when f.copy_id is null then 'unknown_code'
        when f.copy_exam <> v_up.exam_id then 'other_exam'
        when (f.e ->> 'copy_page')::int > f.copy_pages then 'unknown_code'
        when v_home and f.copy_booking is distinct from v_sub.booking_id then 'not_expected'
        when not v_home and (f.b_status not in ('paid', 'cancel_requested') or f.b_sitting <> 'centre'
                             or f.b_centre is distinct from v_centre or f.absent) then 'not_expected'
        else 'match'
      end as finding,
      case
        when v_home then 'other_booking'
        when f.b_status not in ('paid', 'cancel_requested') then 'booking_status'
        when f.b_sitting <> 'centre' then 'home_sitting'
        when f.b_centre is distinct from v_centre then 'other_centre'
        else 'absent'
      end as reason
    from f
  )
  select coalesce(jsonb_agg(jsonb_build_object('idx', g.idx, 'e', g.e, 'finding', g.finding, 'reason', g.reason,
           'copy_id', case when g.finding <> 'other_exam' then g.copy_id end, 'copy_booking', g.copy_booking,
           'copy_exam', g.copy_exam)), '[]'::jsonb)
  into v_found from g;

  insert into public.script_pages (upload_id, source_index, exam_id, copy_id, copy_page, booking_id, state, blank, quality,
    rotation, full_path, marking_path)
  select v_up.id, (x ->> 'idx')::int, v_up.exam_id, (x ->> 'copy_id')::uuid, (x -> 'e' ->> 'copy_page')::int,
    case when x ->> 'finding' = 'match' then (x ->> 'copy_booking')::uuid end,
    (case x ->> 'finding' when 'match' then 'matched' when 'blank' then 'blank' when 'no_code' then 'unmatched'
       else 'rejected' end)::public.page_state,
    (x -> 'e' ->> 'blank')::boolean,
    jsonb_build_object('sharpness', x -> 'e' -> 'quality' -> 'sharpness', 'brightness', x -> 'e' -> 'quality' -> 'brightness',
      'cut_off', x -> 'e' -> 'quality' -> 'cut_off', 'flags', x -> 'e' -> 'quality' -> 'flags'),
    (x -> 'e' ->> 'rotation')::int, x -> 'e' ->> 'full_path', x -> 'e' ->> 'marking_path'
  from jsonb_array_elements(v_found) x;

  if v_placed <> '{}'::jsonb then
    update public.script_exceptions e set page_id = p.id
    from public.script_pages p
    where p.upload_id = v_up.id and p.replaced_at is null and p.state = 'unmatched' and v_placed ? p.source_index::text
      and e.page_id = (v_placed -> p.source_index::text ->> 'id')::uuid and e.kind = 'uncoded_family_page' and e.state = 'open';
    update public.script_pages p set placed_after = (v_placed -> p.source_index::text ->> 'placed_after')::int
    where p.upload_id = v_up.id and p.replaced_at is null and p.state = 'unmatched' and v_placed ? p.source_index::text;
  end if;

  if v_home then
    -- Duplicates within the submission.
    update public.script_pages p
    set state = (case when r.rn = 1 then 'matched' else 'duplicate' end)::public.page_state
    from (
      select p2.id, row_number() over (
        partition by p2.copy_page
        order by public.script_page_poor(p2.quality, p2.marking_path, public.script_page_is_answer(p2.copy_id, p2.copy_page)),
                 (p2.quality ->> 'sharpness')::numeric desc, u.position nulls last, u.created_at, u.id, p2.source_index) as rn
      from public.script_pages p2
      join public.script_uploads u on u.id = p2.upload_id
      where u.submission_id = v_sub.id and p2.replaced_at is null and p2.booking_id = v_sub.booking_id
        and p2.state in ('matched', 'duplicate')
    ) r
    where p.id = r.id and p.state <> (case when r.rn = 1 then 'matched' else 'duplicate' end)::public.page_state;

    select * into v_x from public.scripts s where s.booking_id = v_sub.booking_id for update;
    if v_x.id is null and exists (
      select 1 from public.script_pages p join public.script_uploads u on u.id = p.upload_id
      where u.submission_id = v_sub.id and p.replaced_at is null and p.state = 'matched') then
      v_x := public.script_create(v_sub.booking_id, 'home', v_now);
    end if;

    if public.home_submission_assemble(v_sub.id, v_up.id, v_now) then
      v_changed := v_changed || v_x.id;
    end if;
  else
    -- Scanner file: per booking, each copy page this file (or its earlier run) touched is decided again between
    -- the booking's scanned pages of that copy page and the page the script shows there now.
    foreach v_b in array v_bookings loop
      select * into v_x from public.scripts s where s.booking_id = v_b for update;
      v_links := case when v_x.id is null then '{}'::jsonb else public.script_links(v_x.id) end;
      for v_slot in
        select distinct t.copy_page from (
          select p.copy_page from public.script_pages p
          where p.upload_id = v_up.id and p.replaced_at is null and p.state = 'matched' and p.booking_id = v_b
          union
          select (o ->> 'copy_page')::int from jsonb_array_elements(v_old_slots) o where (o ->> 'booking_id')::uuid = v_b
        ) t
        order by 1
      loop
        v_linked := (v_links ->> v_slot::text)::uuid;
        v_winner := null;
        select c.id into v_winner
        from (
          select p.id, p.quality, p.marking_path, p.copy_id, p.copy_page, p.source_index, p.upload_id
          from public.script_pages p join public.script_uploads u on u.id = p.upload_id
          where p.replaced_at is null and u.submission_id is null and p.booking_id = v_b and p.copy_page = v_slot
            and p.state in ('matched', 'duplicate')
          union
          select p.id, p.quality, p.marking_path, p.copy_id, p.copy_page, p.source_index, p.upload_id
          from public.script_pages p where p.id = v_linked and p.replaced_at is null
        ) c
        join public.script_uploads u on u.id = c.upload_id
        order by public.script_page_poor(c.quality, c.marking_path, public.script_page_is_answer(c.copy_id, c.copy_page)),
                 (c.quality ->> 'sharpness')::numeric desc, u.created_at, u.id, c.source_index
        limit 1;

        update public.script_pages p
        set state = (case when p.id = v_winner then 'matched' else 'duplicate' end)::public.page_state
        where p.replaced_at is null and p.booking_id = v_b and p.copy_page = v_slot and p.state in ('matched', 'duplicate')
          and exists (select 1 from public.script_uploads u where u.id = p.upload_id and u.submission_id is null)
          and p.state <> (case when p.id = v_winner then 'matched' else 'duplicate' end)::public.page_state;
        delete from public.script_exceptions e where e.state = 'open' and e.kind = 'duplicate' and e.page_id = v_winner;
        insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details)
        select v_up.exam_id, 'duplicate', v_b, v_x.id, p.id, v_up.id,
          jsonb_build_object('copy_page', v_slot, 'kept_page_id', v_winner)
        from public.script_pages p
        where p.replaced_at is null and p.booking_id = v_b and p.copy_page = v_slot and p.state = 'duplicate'
          and exists (select 1 from public.script_uploads u where u.id = p.upload_id and u.submission_id is null)
          and not exists (select 1 from public.script_exceptions e where e.page_id = p.id and e.kind = 'duplicate' and e.state = 'open');

        v_links := case when v_winner is null then v_links - v_slot::text
                        else v_links || jsonb_build_object(v_slot::text, v_winner) end;
      end loop;

      if v_x.id is null and v_links <> '{}'::jsonb then
        v_x := public.script_create(v_b, 'centre', v_now);
      end if;
      if v_x.id is not null then
        if public.script_version_write(v_x.id, v_links, null, v_up.id, 'scan_upload', v_now) then
          v_changed := v_changed || v_x.id;
        end if;
      end if;
    end loop;
  end if;

  -- Exceptions about single pages.
  insert into public.script_exceptions (exam_id, kind, booking_id, page_id, upload_id, details)
  select v_up.exam_id, (x ->> 'finding')::public.exception_kind,
    case when v_home then v_sub.booking_id when x ->> 'finding' = 'not_expected' then (x ->> 'copy_booking')::uuid end,
    p.id, v_up.id,
    case x ->> 'finding'
      when 'unknown_code' then jsonb_build_object('code', x -> 'e' ->> 'code', 'copy_page', (x -> 'e' ->> 'copy_page')::int)
      when 'other_exam' then jsonb_build_object('copy_page', (x -> 'e' ->> 'copy_page')::int, 'other_exam_id', x ->> 'copy_exam')
      when 'not_expected' then jsonb_build_object('copy_id', x ->> 'copy_id', 'copy_page', (x -> 'e' ->> 'copy_page')::int,
        'reason', x ->> 'reason')
      else '{}'::jsonb
    end
  from jsonb_array_elements(v_found) x
  join public.script_pages p on p.upload_id = v_up.id and p.replaced_at is null and p.source_index = (x ->> 'idx')::int
  where x ->> 'finding' in ('unknown_code', 'other_exam', 'not_expected') or (x ->> 'finding' = 'no_code' and not v_home);

  if not v_home then
    insert into public.script_exceptions (exam_id, kind, booking_id, page_id, upload_id, details)
    select v_up.exam_id, 'poor_quality', p.booking_id, p.id, v_up.id,
      jsonb_build_object('flags', p.quality -> 'flags', 'copy_page', p.copy_page, 'marking_picture', p.marking_path is not null)
    from public.script_pages p
    where p.upload_id = v_up.id and p.replaced_at is null
      and (p.quality -> 'flags' ?| array['blurred', 'dark', 'cut_off', 'layout_unexpected']
           or (p.state = 'matched' and p.marking_path is null and public.script_page_is_answer(p.copy_id, p.copy_page)));
  end if;

  foreach v_b in array v_changed loop
    perform public.script_raise_mixed(v_b, v_up.id);
  end loop;

  update public.script_exceptions e set script_id = s.id
  from public.scripts s
  where e.upload_id = v_up.id and e.script_id is null and s.booking_id = e.booking_id;

  update public.script_uploads set state = 'processed', sha256 = coalesce(sha256, p_sha256) where id = v_up.id;

  if v_home then
    perform public.home_submission_evaluate(v_sub.id, v_now);
  end if;
  for v_x in select s.* from public.scripts s where s.booking_id = any (v_bookings) order by s.booking_id loop
    perform public.script_evaluate_at(v_x.id, v_now);
  end loop;

  return jsonb_build_object('ok', true,
    'pages', (select count(*) from public.script_pages p where p.upload_id = v_up.id and p.replaced_at is null),
    'matched', (select count(*) from public.script_pages p where p.upload_id = v_up.id and p.replaced_at is null and p.state = 'matched'),
    'exceptions', (select count(*) from public.script_exceptions e where e.upload_id = v_up.id and e.state = 'open'));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- A prepare job that fails for good now also settles what waits on its upload: a home submission whose other
-- uploads are prepared makes its version from them (the failed file is often the last to settle, after its
-- retries) and stops showing "Checking your pages"; the booking's script, and any script showing the upload's
-- pages, are worked out again. (Same as 20261120000051 otherwise.)
-- ---------------------------------------------------------------------------------------------
create or replace function public.processing_job_fail(p_job public.processing_jobs, p_error text, p_now timestamptz)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_up public.script_uploads%rowtype;
  v_booking uuid;
  v_script uuid;
begin
  update public.processing_jobs
  set state = 'failed', finished_at = p_now, locked_by = null, locked_at = null, last_error = left(p_error, 300)
  where id = p_job.id;
  if p_job.kind = 'prepare' then
    update public.script_uploads set state = 'failed' where id = p_job.upload_id returning * into v_up;
  else
    select * into v_up from public.script_uploads u where u.id = p_job.upload_id;
  end if;
  insert into public.script_exceptions (exam_id, kind, booking_id, upload_id, details)
  values (v_up.exam_id, 'processing_failed', v_up.booking_id, v_up.id,
    jsonb_build_object('job_id', p_job.id, 'kind', p_job.kind, 'attempts', p_job.attempts));

  if p_job.kind = 'prepare' then
    select s.booking_id into v_booking from public.home_submissions s where s.id = v_up.submission_id;
    if v_booking is not null then
      perform pg_advisory_xact_lock(hashtextextended('script_booking:' || v_booking::text, 0));
      if public.home_submission_assemble(v_up.submission_id, v_up.id, p_now) then
        perform public.script_raise_mixed(s.id, v_up.id) from public.scripts s where s.booking_id = v_booking;
      end if;
      perform public.home_submission_evaluate(v_up.submission_id, p_now);
    end if;
    for v_script in
      select s.id from public.scripts s where s.booking_id = v_booking
      union
      select l.script_id from public.script_page_links l join public.script_pages p on p.id = l.page_id
      where p.upload_id = v_up.id
    loop
      perform public.script_evaluate_at(v_script, p_now);
    end loop;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Access: script_pages_record is for the processing server; everything else here is internal.
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.script_pages_record(bigint, text, int, text, jsonb, timestamptz) from public, anon, authenticated;
grant execute on function public.script_pages_record(bigint, text, int, text, jsonb, timestamptz) to service_role;
revoke execute on function public.script_page_is_answer(uuid, int) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_poor(jsonb, text, boolean) from public, anon, authenticated, service_role;
revoke execute on function public.script_links(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_version_write(uuid, jsonb, uuid, uuid, text, timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.script_create(uuid, public.script_source, timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.script_raise_mixed(uuid, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.home_submission_assemble(uuid, uuid, timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.home_submission_evaluate(uuid, timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.script_evaluate_at(uuid, timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.script_evaluate(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_pages_valid(jsonb, text) from public, anon, authenticated, service_role;
