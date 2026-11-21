-- Phase 2 Task 11: the script repository.
--
-- Staff admins list every script (scripts_list: by exam, source, state and late) and open one (script_detail: the
-- candidate, its versions, its pages in reading order with their full and marking pictures, the files they came from
-- with their jobs, its exceptions, the centre's custody and what staff did). Page tools, each with a reason (3 to 300
-- characters) and audited: turn a page (script_page_rotate), prepare a file again (script_upload_reprocess), take a
-- page out of a script (script_page_remove) and void a script (script_void). A booking that is cancelled, refunded or
-- expires withdraws its script. Every staff function takes the booking locks first (Task 10's order).
--
-- Marking pictures (privacy-critical). A remask job re-makes the marking pictures of a file's current answer pages
-- from their stored full pictures (never from the original, and never changing a full picture). Each page is turned
-- by the turn staff gave it since its full picture was made (rotation - full_rotation), then painted white, as one
-- union: the nominal name band, its paper version's hidden areas, the staff hidden areas (fractions of the stored
-- full picture), and, only when its geometry is proved again from the full picture with a prepare's checks, the band
-- and areas placed through that fit and everything above the measured top rule. A page that cannot be proved gets a
-- marking picture only when staff confirmed it (a resolved poor_quality or name_visible exception, with staff areas or
-- "there is no name on this page"); otherwise none. The database hands each page's context to the server with a key
-- (an md5 of the context) and takes the result back through script_pages_remasked, which writes only the marking
-- picture, and only for a page whose context is still the one the job was given (a page changed meanwhile is left as
-- it is and a new remask job is queued).
--
-- Remask jobs are queued when a page is turned, when staff hidden areas change, when a paper version's hidden areas
-- change (set_paper_hidden_areas: every processed file with a current page on a changed page, and every file still
-- being prepared), and as Task 10 queues them. One job of a kind per file waits while one runs (the single "active"
-- index becomes one queued and one running); a waiting remask job is not claimed while its file is prepared. A remask
-- job that fails for good raises processing_failed for each script showing the file's pages and works them out again.
--
-- Pictures go to a folder per job: <exam>/<upload>/<job>/<source_index>-full.jpg and -marking.jpg, so a rerun or a
-- remask never overwrites the pictures of a page kept (replaced_at) with an earlier version. Pages recorded before keep
-- their pictures at <exam>/<upload>/ (still accepted).

-- ---------------------------------------------------------------------------------------------
-- Schema additions.
-- ---------------------------------------------------------------------------------------------

-- The quarter turn the stored full picture was made with (the prepare's rotation). rotation - full_rotation is the
-- turn staff gave the page since: the marking picture is made with it; the full picture stays as stored.
alter table public.script_pages
  add column full_rotation int not null default 0 constraint script_pages_full_rotation_check check (full_rotation in (0, 90, 180, 270));
update public.script_pages set full_rotation = rotation where full_rotation <> rotation;

create function public.script_pages_full_rotation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.full_rotation := new.rotation;
  return new;
end;
$$;
create trigger script_pages_full_rotation before insert on public.script_pages
  for each row execute function public.script_pages_full_rotation();

-- One job of a kind per file may wait while one runs (a page turned during a remask gets its own next job).
drop index public.processing_jobs_one_active;
create unique index processing_jobs_one_queued on public.processing_jobs (upload_id, kind) where state = 'queued';
create unique index processing_jobs_one_running on public.processing_jobs (upload_id, kind) where state = 'running';

create index audit_log_target_idx on public.audit_log (target_id) where target_type in ('script', 'script_page', 'script_upload');

-- ---------------------------------------------------------------------------------------------
-- Helpers (internal).
-- ---------------------------------------------------------------------------------------------

-- Queues a remask job for a file (one waiting job per file is enough).
create function public.script_remask_queue(p_upload uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.processing_jobs (upload_id, kind) values (p_upload, 'remask') on conflict do nothing;
  return found;
end;
$$;

-- The copy and copy page a page stands for: those of its own code, or, for a page with no code that a script shows,
-- that script's candidate's latest copy at the copy page the script shows it at.
create function public.script_page_copy(p_page uuid, out copy_id uuid, out copy_page int)
returns record
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(p.copy_id, t.copy_id), coalesce(p.copy_page, t.copy_page)
  from public.script_pages p
  left join lateral (
    select (select c.id from public.paper_copies c where c.booking_id = s.booking_id order by c.created_at desc, c.id limit 1) as copy_id,
           l.copy_page
    from public.script_page_links l join public.scripts s on s.id = l.script_id and l.version = s.version
    where l.page_id = p.id and p.copy_id is null
    order by s.id
    limit 1
  ) t on true
  where p.id = p_page
$$;

-- Staff confirmed the page's name is hidden: a poor_quality or name_visible exception about it resolved as confirmed,
-- with staff hidden areas on the page or "there is no name on this page" (details.no_name).
create function public.script_page_confirmed(p_page uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.script_exceptions e
    where e.page_id = p_page and e.kind in ('poor_quality', 'name_visible') and e.state = 'resolved' and e.resolution = 'confirmed'
      and (coalesce(e.details ->> 'no_name', '') = 'true'
           or exists (select 1 from public.script_page_hidden_areas a where a.page_id = p_page)))
$$;

-- What a remask job makes a page's marking picture from: its full picture, the turn staff gave it since the full
-- picture was made, its code and copy page (to prove its geometry again), whether it is an answer page (only answer
-- pages get marking pictures; a family's confirmed extra page is one), whether it may be proved (it has a code and its
-- prepare did not flag layout_unexpected), whether staff confirmed it, its paper version's hidden areas on its copy
-- page (fractions of the A4 copy page) and the staff hidden areas (fractions of the stored full picture).
create function public.script_page_remask_context(p_page uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'page_id', p.id,
    'source_index', p.source_index,
    'full_path', p.full_path,
    'rotation', p.rotation,
    'turn', ((p.rotation - p.full_rotation) % 360 + 360) % 360,
    'code', c.code,
    'copy_page', p.copy_page,
    'answer', case when t.copy_id is not null then public.script_page_is_answer(t.copy_id, t.copy_page)
                   else p.state = 'unmatched' and p.placed_after is not null end,
    'provable', p.copy_id is not null and not coalesce(p.quality -> 'flags' ? 'layout_unexpected', false),
    'confirmed', public.script_page_confirmed(p.id),
    'paper_areas', coalesce((
      select jsonb_agg(jsonb_build_object('x', a.x, 'y', a.y, 'w', a.w, 'h', a.h) order by a.created_at, a.id)
      from public.paper_copies tc join public.paper_hidden_areas a on a.paper_id = tc.paper_id and a.page = t.copy_page
      where tc.id = t.copy_id), '[]'::jsonb),
    'staff_areas', coalesce((
      select jsonb_agg(jsonb_build_object('x', a.x, 'y', a.y, 'w', a.w, 'h', a.h) order by a.created_at, a.id)
      from public.script_page_hidden_areas a where a.page_id = p.id), '[]'::jsonb))
  from public.script_pages p
  left join public.paper_copies c on c.id = p.copy_id
  cross join lateral public.script_page_copy(p.id) t
  where p.id = p_page
$$;

-- The key of a page's remask context: a result made from another context is stale.
create function public.script_page_remask_key(p_page uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select md5(public.script_page_remask_context(p_page)::text)
$$;

-- Locks what changing a page touches, in the lock order: the bookings it concerns (with p_extra), then the page row.
-- The bookings are worked out again once the page is locked, as script_resolution_lock does; null when they changed
-- twice (the caller refuses: conflict, changed).
create function public.script_page_lock(p_page uuid, p_extra uuid[])
returns uuid[]
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_want uuid[];
  v_locked uuid[] := '{}';
  v_try int;
begin
  for v_try in 1..3 loop
    v_want := array(select distinct b from unnest(coalesce(p_extra, '{}'::uuid[]) || public.script_page_bookings(p_page)) b
                    where b is not null order by 1);
    if v_try > 1 and v_want <@ v_locked then
      return v_locked;
    end if;
    if v_try = 3 then
      return null;
    end if;
    perform public.script_bookings_lock(v_want);
    v_locked := array(select distinct b from unnest(v_locked || v_want) b order by 1);
    perform 1 from public.script_pages p where p.id = p_page for update;
  end loop;
  return null;
end;
$$;

-- A home script's extra pages: pages with no code that the family placed after a copy page and staff confirmed
-- (uncoded_family_page resolved as confirmed), from the submissions that count (handed in, not rejected, from the
-- latest that replaced all pages on), current and not linked.
create function public.script_extra_pages(p_script uuid)
returns table (page_id uuid, placed_after int, file_position int, source_index int)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, p.placed_after, u.position, p.source_index
  from public.scripts s
  join public.home_submissions hs on hs.booking_id = s.booking_id and hs.state not in ('draft', 'rejected')
  join public.script_uploads u on u.submission_id = hs.id
  join public.script_pages p on p.upload_id = u.id
  where s.id = p_script and p.replaced_at is null and p.state = 'unmatched' and p.placed_after is not null
    and hs.seq >= coalesce((select max(h2.seq) from public.home_submissions h2
                            where h2.booking_id = s.booking_id and h2.state not in ('draft', 'rejected') and h2.replaces_all), 0)
    and not exists (select 1 from public.script_page_links l where l.script_id = s.id and l.version = s.version and l.page_id = p.id)
    and exists (select 1 from public.script_exceptions e
                where e.page_id = p.id and e.kind = 'uncoded_family_page' and e.state = 'resolved' and e.resolution = 'confirmed')
$$;

-- ---------------------------------------------------------------------------------------------
-- Remask jobs are queued by what changes a marking picture: staff hidden areas (any change on a current page).
-- ---------------------------------------------------------------------------------------------
create function public.script_page_areas_remask()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.script_remask_queue(p.upload_id)
  from public.script_pages p
  where p.id = coalesce(new.page_id, old.page_id) and p.replaced_at is null;
  return null;
end;
$$;
create trigger script_page_hidden_areas_remask after insert or delete on public.script_page_hidden_areas
  for each row execute function public.script_page_areas_remask();

-- ---------------------------------------------------------------------------------------------
-- A booking cancelled, refunded or expired withdraws its script (state_reason booking_<status>), unless it is final
-- (results out) or already void or withdrawn. Takes the booking's lock before the script row (the lock order).
-- ---------------------------------------------------------------------------------------------
create function public.script_withdraw_on_booking()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('script_booking:' || new.id::text, 0));
  update public.scripts
  set state = 'withdrawn', state_reason = 'booking_' || new.status::text
  where booking_id = new.id and state not in ('final', 'void', 'withdrawn');
  return null;
end;
$$;
create trigger bookings_withdraw_script after update of status on public.bookings
  for each row when (new.status in ('cancelled', 'refunded', 'expired') and old.status is distinct from new.status)
  execute function public.script_withdraw_on_booking();

-- ---------------------------------------------------------------------------------------------
-- processing_job_claim: as 20261120000052, and (a) a queued job waits while its file has a job of the same kind
-- running, and a queued remask job while its file has a prepare job queued or running (it then works on the new
-- pages); (b) a remask job's claim carries the file's current answer pages with their remask context and key
-- (script_page_remask_context) instead of the exam's paper versions and copies.
-- ---------------------------------------------------------------------------------------------
create or replace function public.processing_job_claim(p_worker text, p_now timestamptz default null)
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
  for v_job in
    select j.* from public.processing_jobs j
    where j.state = 'running' and j.attempts >= 3 and j.locked_at < v_now - interval '15 minutes'
    order by j.id
    for update skip locked
  loop
    perform public.processing_job_fail(v_job, 'worker stopped responding', v_now);
  end loop;

  select j.* into v_job from public.processing_jobs j
  where (j.state = 'queued' and j.run_after <= v_now
         and not exists (select 1 from public.processing_jobs r
                         where r.upload_id = j.upload_id and r.id <> j.id
                           and ((r.kind = j.kind and r.state = 'running')
                                or (j.kind = 'remask' and r.kind = 'prepare' and r.state in ('queued', 'running')))))
     or (j.state = 'running' and j.attempts < 3 and j.locked_at < v_now - interval '15 minutes')
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
  if v_job.kind = 'prepare' then
    update public.script_uploads set state = 'processing' where id = v_job.upload_id;
  end if;
  select * into v_up from public.script_uploads u where u.id = v_job.upload_id;

  return jsonb_build_object(
    'job', jsonb_build_object('id', v_job.id, 'kind', v_job.kind, 'attempts', v_job.attempts),
    'upload', jsonb_build_object('id', v_up.id, 'kind', v_up.kind, 'mime', v_up.mime, 'storage_path', v_up.storage_path,
      'exam_id', v_up.exam_id, 'booking_id', v_up.booking_id, 'batch_id', v_up.batch_id, 'sha256', v_up.sha256),
    'papers', case when v_job.kind = 'prepare' then coalesce((
      select jsonb_agg(jsonb_build_object(
        'paper_id', p.id,
        'page_count', p.page_count,
        'roles', coalesce((select jsonb_agg(jsonb_build_object('page', r.page, 'role', r.role) order by r.page)
                           from public.paper_page_roles r where r.paper_id = p.id), '[]'::jsonb),
        'areas', coalesce((select jsonb_agg(jsonb_build_object('page', a.page, 'x', a.x, 'y', a.y, 'w', a.w, 'h', a.h)
                                            order by a.page, a.created_at, a.id)
                           from public.paper_hidden_areas a where a.paper_id = p.id), '[]'::jsonb))
        order by p.version)
      from public.exam_papers p where p.exam_id = v_up.exam_id and p.kind = 'paper'), '[]'::jsonb) else '[]'::jsonb end,
    'copies', case when v_job.kind = 'prepare' then coalesce((
      select jsonb_object_agg(c.code, jsonb_build_object(
        'copy_id', c.id, 'paper_id', c.paper_id, 'booking_id', c.booking_id, 'page_count', c.page_count))
      from public.paper_copies c
      join public.exam_papers p on p.id = c.paper_id
      where p.exam_id = v_up.exam_id and p.kind = 'paper'), '{}'::jsonb) else '{}'::jsonb end,
    'pages', case when v_job.kind = 'remask' then coalesce((
      select jsonb_agg(x.ctx || jsonb_build_object('key', md5(x.ctx::text)) order by x.idx)
      from (select p.source_index as idx, public.script_page_remask_context(p.id) as ctx
            from public.script_pages p where p.upload_id = v_up.id and p.replaced_at is null) x
      where (x.ctx ->> 'answer')::boolean), '[]'::jsonb) end);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- processing_job_finish: as 20261120000051, and a failed attempt whose file already has a newer job of the same kind
-- waiting is not retried: it ends (state done, the error kept, answer 'superseded') and the newer job does the work.
-- ---------------------------------------------------------------------------------------------
create or replace function public.processing_job_finish(
  p_job bigint,
  p_worker text,
  p_attempt int,
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
begin
  select * into v_job from public.processing_jobs j where j.id = p_job for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_job.state <> 'running' or v_job.locked_by is distinct from left(coalesce(p_worker, ''), 100)
     or v_job.attempts is distinct from p_attempt then
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
    if exists (select 1 from public.processing_jobs j
               where j.upload_id = v_job.upload_id and j.kind = v_job.kind and j.state = 'queued' and j.id <> v_job.id) then
      update public.processing_jobs
      set state = 'done', finished_at = v_now, locked_by = null, locked_at = null, last_error = left(p_error, 300)
      where id = v_job.id;
      return jsonb_build_object('ok', true, 'state', 'superseded');
    end if;
    update public.processing_jobs
    set state = 'queued', run_after = v_now + v_job.attempts * interval '1 minute', locked_by = null, locked_at = null,
        last_error = left(p_error, 300)
    where id = v_job.id;
    return jsonb_build_object('ok', true, 'state', 'queued');
  end if;

  perform public.processing_job_fail(v_job, p_error, v_now);
  return jsonb_build_object('ok', true, 'state', 'failed');
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- processing_job_fail: as 20261120000052 for prepare jobs. A remask job that fails for good raises one
-- processing_failed exception for each booking whose script shows the file's current pages (else, as before, one for
-- the file's booking) and works those scripts out again under the bookings' locks: their marking pictures could not
-- be made, so they are not verified until staff look.
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
  v_bookings uuid[];
begin
  update public.processing_jobs
  set state = 'failed', finished_at = p_now, locked_by = null, locked_at = null, last_error = left(p_error, 300)
  where id = p_job.id;
  if p_job.kind = 'prepare' then
    update public.script_uploads set state = 'failed' where id = p_job.upload_id returning * into v_up;
  else
    select * into v_up from public.script_uploads u where u.id = p_job.upload_id;
  end if;
  -- A home upload's booking is its submission's (script_uploads.booking_id may be empty).
  select s.booking_id into v_booking from public.home_submissions s where s.id = v_up.submission_id;
  v_booking := coalesce(v_booking, v_up.booking_id);

  if p_job.kind <> 'prepare' then
    select coalesce(array_agg(distinct s.booking_id order by s.booking_id), '{}') into v_bookings
    from public.script_pages p
    join public.script_page_links l on l.page_id = p.id
    join public.scripts s on s.id = l.script_id and l.version = s.version
    where p.upload_id = v_up.id and p.replaced_at is null;
    perform public.script_bookings_lock(v_bookings || v_booking);
    if cardinality(v_bookings) = 0 then
      insert into public.script_exceptions (exam_id, kind, booking_id, script_id, upload_id, details)
      values (v_up.exam_id, 'processing_failed', v_booking, (select x.id from public.scripts x where x.booking_id = v_booking), v_up.id,
        jsonb_build_object('job_id', p_job.id, 'kind', p_job.kind, 'attempts', p_job.attempts));
    else
      insert into public.script_exceptions (exam_id, kind, booking_id, script_id, upload_id, details)
      select v_up.exam_id, 'processing_failed', b, (select x.id from public.scripts x where x.booking_id = b), v_up.id,
        jsonb_build_object('job_id', p_job.id, 'kind', p_job.kind, 'attempts', p_job.attempts)
      from unnest(v_bookings) b order by b;
    end if;
    for v_script in select s.id from public.scripts s where s.booking_id = any (v_bookings || v_booking) order by s.booking_id loop
      perform public.script_evaluate_at(v_script, p_now);
    end loop;
    return;
  end if;

  insert into public.script_exceptions (exam_id, kind, booking_id, script_id, upload_id, details)
  values (v_up.exam_id, 'processing_failed', v_booking, (select x.id from public.scripts x where x.booking_id = v_booking), v_up.id,
    jsonb_build_object('job_id', p_job.id, 'kind', p_job.kind, 'attempts', p_job.attempts));
  if v_up.submission_id is not null then
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
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_pages_remasked: the processing server (service role) records the marking pictures a claimed remask job made.
-- Acts only for the worker and attempt that hold the job (else {ok:false, code:'conflict'}). p_pages =
-- [{page_id, marking_path|null, rotation, key}], each a page of the job's file, listed once, with its picture (when
-- one was made) at <exam>/<upload>/<job>/<source_index>-marking.jpg (else invalid_input, nothing changed). For each
-- current page whose rotation and key are still those of the claim, marking_path is written (null: no marking
-- picture may be made); nothing else of the page changes. A page whose context changed meanwhile (stale) is left as
-- it is and a remask job is queued for it; a replaced page is left alone. A scanned answer page that a script shows
-- and that now has no marking picture is raised for staff (poor_quality, from remask, once). The scripts showing the
-- pages are then worked out again. Returns {ok, pages (written), marking (with a picture), stale, replaced}.
-- ---------------------------------------------------------------------------------------------
create function public.script_pages_remasked(p_job bigint, p_worker text, p_attempt int, p_pages jsonb, p_now timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  v_job public.processing_jobs%rowtype;
  v_up public.script_uploads%rowtype;
  v_dir text;
  v_ids uuid[];
  v_bookings uuid[];
  v_more uuid[];
  v_i record;
  v_p public.script_pages%rowtype;
  v_lost uuid[] := '{}';
  v_written int := 0;
  v_marking int := 0;
  v_stale int := 0;
  v_replaced int := 0;
  v_script uuid;
begin
  select * into v_job from public.processing_jobs j where j.id = p_job for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_job.state <> 'running' or v_job.locked_by is distinct from left(coalesce(p_worker, ''), 100)
     or v_job.attempts is distinct from p_attempt then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  select * into v_up from public.script_uploads u where u.id = v_job.upload_id;
  v_dir := v_up.exam_id::text || '/' || v_up.id::text || '/' || v_job.id::text || '/';
  if v_job.kind <> 'remask' or p_pages is null or jsonb_typeof(p_pages) <> 'array' or jsonb_array_length(p_pages) > 5000
     or exists (
       select 1 from jsonb_array_elements(p_pages) e
       left join public.script_pages p
         on p.id = case when jsonb_typeof(e) = 'object' and (e ->> 'page_id') ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                        then (e ->> 'page_id')::uuid end
        and p.upload_id = v_up.id
       where p.id is null
          or jsonb_typeof(e -> 'rotation') is distinct from 'number' or (e ->> 'rotation') not in ('0', '90', '180', '270')
          or jsonb_typeof(e -> 'key') is distinct from 'string' or char_length(e ->> 'key') > 64
          or coalesce(jsonb_typeof(e -> 'marking_path'), 'null') not in ('null', 'string')
          or (e ->> 'marking_path') <> v_dir || p.source_index || '-marking.jpg')
     or (select count(distinct e ->> 'page_id') from jsonb_array_elements(p_pages) e) <> jsonb_array_length(p_pages) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  v_ids := array(select (e ->> 'page_id')::uuid from jsonb_array_elements(p_pages) e order by 1);

  -- The bookings the pages concern, in the lock order (as script_page_lock, for all of them): booking locks, then
  -- the page rows; bookings that joined meanwhile are locked too.
  select coalesce(array_agg(distinct b order by b), '{}') into v_bookings
  from unnest(v_ids) i cross join lateral unnest(public.script_page_bookings(i)) b;
  perform public.script_bookings_lock(v_bookings);
  perform 1 from public.script_pages p where p.id = any (v_ids) order by p.id for update;
  select coalesce(array_agg(distinct b order by b), '{}') into v_more
  from unnest(v_ids) i cross join lateral unnest(public.script_page_bookings(i)) b;
  if not v_more <@ v_bookings then
    perform public.script_bookings_lock(v_more);
    v_bookings := array(select distinct b from unnest(v_bookings || v_more) b order by 1);
  end if;

  for v_i in
    select (e ->> 'page_id')::uuid as page_id, e ->> 'marking_path' as marking_path, (e ->> 'rotation')::int as rotation, e ->> 'key' as key
    from jsonb_array_elements(p_pages) e order by 1
  loop
    select * into v_p from public.script_pages p where p.id = v_i.page_id;
    if v_p.replaced_at is not null then
      v_replaced := v_replaced + 1;
      continue;
    end if;
    if v_i.rotation <> v_p.rotation or v_i.key <> public.script_page_remask_key(v_p.id) then
      v_stale := v_stale + 1;
      perform public.script_remask_queue(v_up.id);
      continue;
    end if;
    if v_p.marking_path is not null and v_i.marking_path is null then
      v_lost := v_lost || v_p.id;
    end if;
    if v_p.marking_path is distinct from v_i.marking_path then
      update public.script_pages set marking_path = v_i.marking_path where id = v_p.id;
    end if;
    v_written := v_written + 1;
    if v_i.marking_path is not null then
      v_marking := v_marking + 1;
    end if;
  end loop;

  if v_up.batch_id is not null and cardinality(v_lost) > 0 then
    insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details)
    select distinct on (p.id) v_up.exam_id, 'poor_quality', s.booking_id, s.id, p.id, v_up.id,
      jsonb_build_object('flags', coalesce(p.quality -> 'flags', '[]'::jsonb), 'copy_page', l.copy_page, 'marking_picture', false,
        'from', 'remask')
    from public.script_pages p
    join public.script_page_links l on l.page_id = p.id
    join public.scripts s on s.id = l.script_id and l.version = s.version
    where p.id = any (v_lost)
      and not exists (select 1 from public.script_exceptions e where e.page_id = p.id and e.kind = 'poor_quality' and e.state = 'open')
    order by p.id, s.id;
  end if;

  for v_script in select s.id from public.scripts s where s.booking_id = any (v_bookings) order by s.booking_id loop
    perform public.script_evaluate_at(v_script, v_now);
  end loop;
  return jsonb_build_object('ok', true, 'pages', v_written, 'marking', v_marking, 'stale', v_stale, 'replaced', v_replaced);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_pages_record: as 20261120000052, and the pictures may be (and, from this processor on, are) in the prepare
-- job's own folder, <exam>/<upload>/<job>/; pictures at <exam>/<upload>/ (stored before) are still accepted.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_pages_record(
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
     or not (public.script_pages_valid(p_pages, v_up.exam_id::text || '/' || v_up.id::text || '/' || v_job.id::text || '/')
             or public.script_pages_valid(p_pages, v_up.exam_id::text || '/' || v_up.id::text || '/')) then
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

  -- A rerun. The latest versions this upload (or its submission) made are undone, to be made again below. The open
  -- exceptions this function raised on the earlier run go (they are raised again where they still hold); on a home
  -- upload an open poor_quality exception is the family's "Send as it is" and moves to the new page of the same
  -- copy page. The earlier pages are set aside (replaced_at) and, once the new pages are in, deleted unless a kept
  -- version or an exception still names them. A family's placement of a page with no code carries over to the new
  -- page at the same position.
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
    and not (v_home and e.kind = 'poor_quality')
    and (e.upload_id = v_up.id or e.page_id = any (v_old));
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
                 (p2.quality ->> 'sharpness')::numeric desc nulls last, u.position nulls last, u.created_at, u.id,
                 p2.source_index) as rn
      from public.script_pages p2
      join public.script_uploads u on u.id = p2.upload_id
      where u.submission_id = v_sub.id and p2.replaced_at is null and p2.booking_id = v_sub.booking_id
        and p2.state in ('matched', 'duplicate')
    ) r
    where p.id = r.id and p.state <> (case when r.rn = 1 then 'matched' else 'duplicate' end)::public.page_state;

    -- The family's "Send as it is" (an open poor_quality exception) follows its page to the new run's page of the
    -- same copy page, the kept one first.
    update public.script_exceptions e set page_id = n.id
    from public.script_pages o
    cross join lateral (
      select n2.id from public.script_pages n2
      where n2.upload_id = v_up.id and n2.replaced_at is null and n2.booking_id = o.booking_id and n2.copy_page = o.copy_page
      order by (n2.state = 'matched') desc, n2.source_index
      limit 1
    ) n
    where o.id = e.page_id and o.id = any (v_old) and e.kind = 'poor_quality' and e.state = 'open';

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
                 (c.quality ->> 'sharpness')::numeric desc nulls last, u.created_at, u.id, c.source_index
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

  -- The earlier run's pages that no version and no exception names any more are deleted; the rest stay, replaced.
  delete from public.script_pages p
  where p.id = any (v_old)
    and not exists (select 1 from public.script_page_links l where l.page_id = p.id)
    and not exists (select 1 from public.script_exceptions e where e.page_id = p.id);

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
-- set_paper_hidden_areas: as 20261120000050, and when areas changed, a remask job is queued for every processed file
-- of the exam holding a current page of this version's copies on a changed page (its own code's copy page, or the
-- copy page a script shows a page with no code at), and for every file of the exam still being prepared (its job read
-- the old areas). Returns also how many were queued (remask_queued).
-- ---------------------------------------------------------------------------------------------
create or replace function public.set_paper_hidden_areas(p_paper uuid, p_areas jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_p public.exam_papers%rowtype;
  v_changed int[];
  v_queued int := 0;
begin
  if not exists (
    select 1 from public.profiles a
    where a.id = v_actor and a.status = 'active' and a.role in ('owner', 'admin') for share) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_paper is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_p from public.exam_papers p where p.id = p_paper and p.kind = 'paper' for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  if p_areas is null or jsonb_typeof(p_areas) <> 'array' then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if exists (
       select 1 from jsonb_array_elements(p_areas) e
       where jsonb_typeof(e) <> 'object'
          or jsonb_typeof(e -> 'page') is distinct from 'number'
          or jsonb_typeof(e -> 'x') is distinct from 'number'
          or jsonb_typeof(e -> 'y') is distinct from 'number'
          or jsonb_typeof(e -> 'w') is distinct from 'number'
          or jsonb_typeof(e -> 'h') is distinct from 'number'
          or (e ->> 'page') !~ '^[0-9]{1,4}$'
          or (e ->> 'page')::int not between 1 and v_p.page_count
          or (e ->> 'x')::numeric < 0 or (e ->> 'y')::numeric < 0
          or (e ->> 'w')::numeric <= 0 or (e ->> 'h')::numeric <= 0
          or (e ->> 'x')::numeric + (e ->> 'w')::numeric > 1
          or (e ->> 'y')::numeric + (e ->> 'h')::numeric > 1)
     or exists (
       select 1 from jsonb_array_elements(p_areas) e
       group by (e ->> 'page')::int having count(*) > 20) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  select coalesce(array_agg(d.page order by d.page), '{}') into v_changed
  from (
    select page from (
      (select page, x, y, w, h from public.paper_hidden_areas where paper_id = v_p.id
       except
       select (e ->> 'page')::int, (e ->> 'x')::numeric, (e ->> 'y')::numeric, (e ->> 'w')::numeric, (e ->> 'h')::numeric
       from jsonb_array_elements(p_areas) e)
      union all
      (select (e ->> 'page')::int, (e ->> 'x')::numeric, (e ->> 'y')::numeric, (e ->> 'w')::numeric, (e ->> 'h')::numeric
       from jsonb_array_elements(p_areas) e
       except
       select page, x, y, w, h from public.paper_hidden_areas where paper_id = v_p.id)
    ) diff group by page
  ) d;

  delete from public.paper_hidden_areas where paper_id = v_p.id;
  insert into public.paper_hidden_areas (paper_id, page, x, y, w, h, created_by)
  select v_p.id, (e ->> 'page')::int, (e ->> 'x')::numeric, (e ->> 'y')::numeric, (e ->> 'w')::numeric,
         (e ->> 'h')::numeric, v_actor
  from jsonb_array_elements(p_areas) e;

  if cardinality(v_changed) > 0 then
    insert into public.processing_jobs (upload_id, kind)
    select u.id, 'remask' from public.script_uploads u
    where u.exam_id = v_p.exam_id
      and (u.state = 'processing'
           or (u.state = 'processed' and exists (
                 select 1 from public.script_pages p
                 cross join lateral public.script_page_copy(p.id) t
                 join public.paper_copies c on c.id = t.copy_id
                 where p.upload_id = u.id and p.replaced_at is null and c.paper_id = v_p.id and t.copy_page = any (v_changed))))
    order by u.id
    on conflict do nothing;
    get diagnostics v_queued = row_count;
  end if;

  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'paper_hidden_areas_set', 'exam_paper', v_p.id);
  return jsonb_build_object('ok', true, 'changed_pages', to_jsonb(v_changed), 'remask_queued', v_queued);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_page_rotate: turns a page by p_quarter_turns quarter turns (1 to 3 clockwise, -1 to -3 anticlockwise) for
-- good: rotation changes (the full picture stays as stored) and a remask job re-makes its marking picture turned.
-- With a reason, audited. Refused for a replaced page (page_replaced) and a page a script past verification shows
-- (script_locked). Returns {ok, page_id, rotation, queued}.
-- ---------------------------------------------------------------------------------------------
create function public.script_page_rotate(p_page uuid, p_quarter_turns int, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_p public.script_pages%rowtype;
  v_rotation int;
  v_queued boolean;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_page is null or p_quarter_turns is null or p_quarter_turns not between -3 and 3 or p_quarter_turns = 0 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if not exists (select 1 from public.script_pages p where p.id = p_page) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if public.script_page_lock(p_page, '{}') is null then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'changed');
  end if;
  select * into v_p from public.script_pages p where p.id = p_page;
  if v_p.replaced_at is not null then
    return jsonb_build_object('ok', false, 'code', 'page_replaced');
  end if;
  if public.script_page_locked(v_p.id) then
    return jsonb_build_object('ok', false, 'code', 'script_locked');
  end if;

  v_rotation := ((v_p.rotation + 90 * p_quarter_turns) % 360 + 360) % 360;
  update public.script_pages set rotation = v_rotation where id = v_p.id;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'script_page_rotated', 'script_page', v_p.id, v_reason);
  v_queued := public.script_remask_queue(v_p.upload_id);
  return jsonb_build_object('ok', true, 'page_id', v_p.id, 'rotation', v_rotation, 'queued', v_queued);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_upload_reprocess: prepares a file again (a prepare job; the rerun replaces the file's pages, Task 4). Only a
-- file that is processed or failed (else conflict, busy), and not while a script showing its pages, or its booking's
-- script, is being marked or marked (script_locked). With a reason, audited. The file waits (queued), so the scripts
-- concerned show checking until it is done. Returns {ok, upload_id, job_id}.
-- ---------------------------------------------------------------------------------------------
create function public.script_upload_reprocess(p_upload uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_up public.script_uploads%rowtype;
  v_bookings uuid[];
  v_job bigint;
  v_script uuid;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_upload is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  select * into v_up from public.script_uploads u where u.id = p_upload;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_up.state not in ('processed', 'failed') then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'busy');
  end if;

  select array(select distinct b from (
      select v_up.booking_id as b
      union all
      select hs.booking_id from public.home_submissions hs where hs.id = v_up.submission_id
      union all
      select p.booking_id from public.script_pages p where p.upload_id = v_up.id and p.replaced_at is null
      union all
      select s.booking_id from public.script_pages p
      join public.script_page_links l on l.page_id = p.id
      join public.scripts s on s.id = l.script_id and l.version = s.version
      where p.upload_id = v_up.id) t
    where b is not null order by 1)
  into v_bookings;
  perform public.script_bookings_lock(v_bookings);
  select * into v_up from public.script_uploads u where u.id = p_upload for update;
  if v_up.state not in ('processed', 'failed') then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'busy');
  end if;
  if exists (select 1 from public.scripts s
             where s.booking_id = any (v_bookings) and s.state in ('ready_to_mark', 'marking', 'marked', 'checked', 'final')) then
    return jsonb_build_object('ok', false, 'code', 'script_locked');
  end if;

  insert into public.processing_jobs (upload_id, kind) values (v_up.id, 'prepare') on conflict do nothing returning id into v_job;
  if v_job is null then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'busy');
  end if;
  update public.script_uploads set state = 'queued' where id = v_up.id;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'script_upload_reprocess', 'script_upload', v_up.id, v_reason);
  for v_script in select s.id from public.scripts s where s.booking_id = any (v_bookings) order by s.booking_id loop
    perform public.script_evaluate(v_script);
  end loop;
  return jsonb_build_object('ok', true, 'upload_id', v_up.id, 'job_id', v_job);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_void: staff void a script (state void, state_reason voided), visibly not marked. Any script that is not
-- final (results out: script_locked), including one being marked; a void script again is conflict (void). With a
-- reason, audited. Returns {ok, script_id, state}.
-- ---------------------------------------------------------------------------------------------
create function public.script_void(p_script uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_x public.scripts%rowtype;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_script is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  select * into v_x from public.scripts s where s.id = p_script;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  perform public.script_bookings_lock(array[v_x.booking_id]);
  select * into v_x from public.scripts s where s.id = p_script for update;
  if v_x.state = 'final' then
    return jsonb_build_object('ok', false, 'code', 'script_locked');
  end if;
  if v_x.state = 'void' then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'void');
  end if;
  update public.scripts set state = 'void', state_reason = 'voided' where id = v_x.id;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'script_voided', 'script', v_x.id, v_reason);
  return jsonb_build_object('ok', true, 'script_id', v_x.id, 'state', 'void');
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_page_remove: takes the page a script shows at copy page p_copy_page out of it: the page is set aside as Task
-- 10 sets pages aside (each script showing it gets a version without it, by staff with the reason; its open
-- exceptions close as set_aside), the page row itself is kept. Then the script is worked out again
-- (script_resolution_settle: one paper version again closes mixed_versions; a centre script already checked is
-- checked again with scan_booking_complete, else script_evaluate). Refused past verification (script_locked).
-- Audited. Returns {ok, script_id, page_id, version}.
-- ---------------------------------------------------------------------------------------------
create function public.script_page_remove(p_script uuid, p_copy_page int, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := now();
  v_reason text := public.script_resolution_reason(p_reason);
  v_x public.scripts%rowtype;
  v_page uuid;
  v_bookings uuid[];
  v_b uuid;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_script is null or p_copy_page is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  select * into v_x from public.scripts s where s.id = p_script;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  v_page := (public.script_links(v_x.id) ->> p_copy_page::text)::uuid;
  if v_page is null then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  v_bookings := public.script_page_lock(v_page, array[v_x.booking_id]);
  if v_bookings is null then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'changed');
  end if;
  select * into v_x from public.scripts s where s.id = p_script for update;
  if (public.script_links(v_x.id) ->> p_copy_page::text)::uuid is distinct from v_page then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'changed');
  end if;
  if public.script_page_locked(v_page) then
    return jsonb_build_object('ok', false, 'code', 'script_locked');
  end if;

  perform public.script_page_set_aside(v_page, v_actor, v_now, v_reason);
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'script_page_removed', 'script_page', v_page, v_reason);
  foreach v_b in array v_bookings loop
    perform public.script_resolution_settle(v_b, v_actor, v_reason);
  end loop;
  select * into v_x from public.scripts s where s.id = p_script;
  return jsonb_build_object('ok', true, 'script_id', v_x.id, 'page_id', v_page, 'version', v_x.version);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- scripts_list: every script for staff admins, newest received first, filtered by exam, source, state and late. Each
-- with its number, candidate (name and index number), exam, source, state (and why), late (and the decision), how many
-- pages it shows (and extra pages), open exceptions and when it was received. At most 500; more says whether there
-- were others.
-- ---------------------------------------------------------------------------------------------
create function public.scripts_list(
  p_exam uuid default null,
  p_source public.script_source default null,
  p_state public.script_state default null,
  p_late boolean default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_items jsonb;
  v_n int;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select coalesce(jsonb_agg(t.item order by t.n) filter (where t.n <= 500), '[]'::jsonb), count(*)
  into v_items, v_n
  from (
    select row_number() over (order by coalesce(s.received_at, s.created_at) desc, s.number desc) as n,
      jsonb_build_object(
        'id', s.id, 'number', s.number, 'booking_id', s.booking_id, 'source', s.source, 'state', s.state,
        'state_reason', s.state_reason, 'late', s.late, 'late_decision', s.late_decision, 'complete', s.complete,
        'version', s.version, 'received_at', s.received_at, 'created_at', s.created_at,
        'pages', (select count(*) from public.script_page_links l where l.script_id = s.id and l.version = s.version),
        'extra_pages', (select count(*) from public.script_extra_pages(s.id)),
        'open_exceptions', (select count(*) from public.script_exceptions e
                            where e.state = 'open' and (e.script_id = s.id or (e.script_id is null and e.booking_id = s.booking_id))),
        'exam', jsonb_build_object('id', e.id, 'title', e.title, 'paper', e.paper, 'code', e.exam_code, 'starts_at', e.starts_at),
        'candidate', jsonb_build_object(
          'name', nullif(btrim(coalesce(pr.first_name, '') || ' ' || coalesce(pr.last_name, '')), ''),
          'index_number', d.index_number)) as item
    from public.scripts s
    join public.exams e on e.id = s.exam_id
    join public.bookings b on b.id = s.booking_id
    left join public.profiles pr on pr.id = b.student_id
    left join public.student_details d on d.profile_id = b.student_id
    where (p_exam is null or s.exam_id = p_exam) and (p_source is null or s.source = p_source)
      and (p_state is null or s.state = p_state) and (p_late is null or s.late = p_late)
    order by 1
    limit 501
  ) t;
  return jsonb_build_object('ok', true, 'items', v_items, 'more', v_n > 500);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_detail: one script for staff admins: {script (with exam and booking), candidate {name, index_number},
-- versions (newest first: who, why, which copy pages), pages (the current version's, in reading order, each with its
-- copy page, role, full and marking pictures, quality, file and position, turn and staff hidden areas; a home script's
-- confirmed extra pages after the page they follow, extra: true), uploads (the files its pages came from and its
-- booking's handed-in files, with their jobs), exceptions (as the queue shows them, open first), custody (the centre's
-- custody chain) and actions (what staff did to it, its pages and files, newest first)}.
-- ---------------------------------------------------------------------------------------------
create function public.script_detail(p_script uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_x public.scripts%rowtype;
  v_b public.bookings%rowtype;
  v_pages uuid[];
  v_uploads uuid[];
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_script is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_x from public.scripts s where s.id = p_script;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select * into v_b from public.bookings b where b.id = v_x.booking_id;
  -- Every page any version showed, and the extra pages.
  v_pages := array(select distinct l.page_id from public.script_page_links l where l.script_id = v_x.id
                   union select x.page_id from public.script_extra_pages(v_x.id) x);
  v_uploads := array(
    select distinct p.upload_id from public.script_pages p where p.id = any (v_pages)
    union
    select u.id from public.script_uploads u join public.home_submissions hs on hs.id = u.submission_id
    where hs.booking_id = v_x.booking_id and hs.state <> 'draft' and u.state not in ('pending', 'discarded'));

  return jsonb_build_object(
    'ok', true,
    'script', jsonb_build_object('id', v_x.id, 'number', v_x.number, 'source', v_x.source, 'state', v_x.state,
      'state_reason', v_x.state_reason, 'version', v_x.version, 'complete', v_x.complete, 'late', v_x.late,
      'late_decision', v_x.late_decision, 'received_at', v_x.received_at, 'created_at', v_x.created_at, 'updated_at', v_x.updated_at,
      'exam', (select jsonb_build_object('id', e.id, 'title', e.title, 'paper', e.paper, 'code', e.exam_code, 'starts_at', e.starts_at)
               from public.exams e where e.id = v_x.exam_id),
      'booking', public.script_booking_json(v_x.booking_id)),
    'candidate', (select jsonb_build_object('name', nullif(btrim(coalesce(pr.first_name, '') || ' ' || coalesce(pr.last_name, '')), ''),
                                            'index_number', d.index_number)
                  from public.bookings b left join public.profiles pr on pr.id = b.student_id
                  left join public.student_details d on d.profile_id = b.student_id where b.id = v_x.booking_id),
    'versions', coalesce((
      select jsonb_agg(jsonb_build_object('version', v.version, 'created_at', v.created_at, 'reason', v.reason,
               'by', (select nullif(btrim(coalesce(pr.first_name, '') || ' ' || coalesce(pr.last_name, '')), '') from public.profiles pr where pr.id = v.created_by),
               'submission_seq', hs.seq, 'upload_id', v.upload_id,
               'pages', coalesce((select jsonb_agg(l.copy_page order by l.copy_page) from public.script_page_links l
                                  where l.script_id = v.script_id and l.version = v.version), '[]'::jsonb))
             order by v.version desc)
      from public.script_versions v left join public.home_submissions hs on hs.id = v.submission_id
      where v.script_id = v_x.id), '[]'::jsonb),
    'pages', coalesce((
      select jsonb_agg(x.j order by x.at, x.extra, x.pos, x.idx)
      from (
        select l.copy_page as at, 0 as extra, 0 as pos, 0 as idx,
          public.script_page_json(l.page_id) || jsonb_build_object('page_id', l.page_id, 'copy_page', l.copy_page,
            'printed_page', p.copy_page, 'extra', false, 'turn', ((p.rotation - p.full_rotation) % 360 + 360) % 360,
            'role', case when t.copy_id is null then null
                         when t.copy_page > ep.page_count then 'spare'
                         else (select r.role::text from public.paper_page_roles r where r.paper_id = ep.id and r.page = t.copy_page) end) as j
        from public.script_page_links l
        join public.script_pages p on p.id = l.page_id
        cross join lateral public.script_page_copy(p.id) t
        left join public.paper_copies tc on tc.id = t.copy_id
        left join public.exam_papers ep on ep.id = tc.paper_id
        where l.script_id = v_x.id and l.version = v_x.version
        union all
        select xp.placed_after, 1, coalesce(xp.file_position, 0), xp.source_index,
          public.script_page_json(xp.page_id) || jsonb_build_object('page_id', xp.page_id, 'copy_page', null,
            'printed_page', null, 'extra', true, 'role', 'extra', 'turn', ((p.rotation - p.full_rotation) % 360 + 360) % 360)
        from public.script_extra_pages(v_x.id) xp join public.script_pages p on p.id = xp.page_id
      ) x), '[]'::jsonb),
    'uploads', coalesce((
      select jsonb_agg(jsonb_build_object('id', u.id, 'kind', u.kind, 'state', u.state,
               'source', case when u.batch_id is not null then 'centre' else 'home' end,
               'position', u.position, 'batch_number', sb.number, 'submission_seq', hs.seq, 'submission_state', hs.state,
               'created_at', u.created_at,
               'pages', (select count(*) from public.script_pages p where p.upload_id = u.id and p.replaced_at is null),
               'jobs', coalesce((select jsonb_agg(jsonb_build_object('id', j.id, 'kind', j.kind, 'state', j.state, 'attempts', j.attempts,
                                          'last_error', j.last_error, 'created_at', j.created_at, 'finished_at', j.finished_at) order by j.id desc)
                                 from (select * from public.processing_jobs j2 where j2.upload_id = u.id order by j2.id desc limit 10) j), '[]'::jsonb))
             order by u.created_at, u.id)
      from public.script_uploads u
      left join public.scan_batches sb on sb.id = u.batch_id
      left join public.home_submissions hs on hs.id = u.submission_id
      where u.id = any (v_uploads)), '[]'::jsonb),
    'exceptions', coalesce((
      select jsonb_agg(public.script_exception_json(e.id) order by (e.state = 'open') desc, e.created_at desc, e.id)
      from public.script_exceptions e
      where e.script_id = v_x.id or (e.script_id is null and e.booking_id = v_x.booking_id)), '[]'::jsonb),
    'custody', case when v_b.centre_id is null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
        'step', ev.step, 'at', ev.at, 'location', ev.location, 'note', ev.note, 'manifest', m.number,
        'from_name', nullif(btrim(coalesce(pf.first_name, '') || ' ' || coalesce(pf.last_name, '')), ''),
        'to_name', nullif(btrim(coalesce(pt.first_name, '') || ' ' || coalesce(pt.last_name, '')), ''),
        'by_name', nullif(btrim(coalesce(pb.first_name, '') || ' ' || coalesce(pb.last_name, '')), '')) order by ev.at, ev.seq)
      from public.custody_events ev
      left join public.collection_manifests m on m.id = ev.manifest_id
      left join public.profiles pf on pf.id = ev.from_staff
      left join public.profiles pt on pt.id = ev.to_staff
      left join public.profiles pb on pb.id = ev.recorded_by
      where ev.exam_id = v_x.exam_id and ev.centre_id = v_b.centre_id), '[]'::jsonb) end,
    'actions', coalesce((
      select jsonb_agg(jsonb_build_object('action', a.action, 'at', a.created_at, 'reason', a.reason, 'target_type', a.target_type,
               'by', (select nullif(btrim(coalesce(pr.first_name, '') || ' ' || coalesce(pr.last_name, '')), '') from public.profiles pr where pr.id = a.actor_id))
             order by a.created_at desc, a.id desc)
      from (select * from public.audit_log a2
            where (a2.target_type = 'script' and a2.target_id = v_x.id)
               or (a2.target_type = 'script_page' and a2.target_id = any (v_pages))
               or (a2.target_type = 'script_upload' and a2.target_id = any (v_uploads))
            order by a2.created_at desc, a2.id desc limit 100) a), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Access: the repository's staff functions check the caller (staff admins); script_pages_remasked is for the
-- processing server; the helpers are internal.
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.script_pages_full_rotation() from public, anon, authenticated, service_role;
revoke execute on function public.script_remask_queue(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_copy(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_confirmed(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_remask_context(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_remask_key(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_lock(uuid, uuid[]) from public, anon, authenticated, service_role;
revoke execute on function public.script_extra_pages(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_areas_remask() from public, anon, authenticated, service_role;
revoke execute on function public.script_withdraw_on_booking() from public, anon, authenticated, service_role;
-- The functions re-created above keep their access (create or replace keeps it).

revoke execute on function public.script_pages_remasked(bigint, text, int, jsonb, timestamptz) from public, anon, authenticated;
grant execute on function public.script_pages_remasked(bigint, text, int, jsonb, timestamptz) to service_role;

revoke execute on function public.scripts_list(uuid, public.script_source, public.script_state, boolean) from public, anon;
revoke execute on function public.script_detail(uuid) from public, anon;
revoke execute on function public.script_page_rotate(uuid, int, text) from public, anon;
revoke execute on function public.script_upload_reprocess(uuid, text) from public, anon;
revoke execute on function public.script_void(uuid, text) from public, anon;
revoke execute on function public.script_page_remove(uuid, int, text) from public, anon;
grant execute on function public.scripts_list(uuid, public.script_source, public.script_state, boolean) to authenticated;
grant execute on function public.script_detail(uuid) to authenticated;
grant execute on function public.script_page_rotate(uuid, int, text) to authenticated;
grant execute on function public.script_upload_reprocess(uuid, text) to authenticated;
grant execute on function public.script_void(uuid, text) to authenticated;
grant execute on function public.script_page_remove(uuid, int, text) to authenticated;
