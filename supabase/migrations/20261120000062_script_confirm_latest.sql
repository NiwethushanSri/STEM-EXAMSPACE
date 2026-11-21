-- Phase 2 Task 11 fix round 2 (Ruling R33): only a page's latest name check counts, and pages staff placed or the
-- family added stay in the scripts (and in remask scope) when their file is processed again.
--
-- (1) script_page_confirmed counts only the page's latest name-checked confirmation (bound, R32): an older one never
-- comes back when a newer one stops holding. "No name" confirmations made before a name_visible resolution of the
-- page are void, and while a name_visible exception about the page is open nothing confirms it.
-- (2) A rerun (script_pages_record) moves staff links to the file's earlier pages that no slot decides (pages
-- without a booking: no code, or a rejected code, that staff assigned) onto the new page at the same position, so no
-- script keeps showing a replaced page (a replaced page is never remasked); staff check such a page's name again. A
-- script that still shows a replaced page is not verified.
-- (3) On a home rerun, a family's page with no code that staff had confirmed gets an open uncoded_family_page
-- exception again on its new page, so it is not silently dropped from the script.
-- (4) An answer page is one by its own copy page or by the slot a script shows it at (remask scope and the
-- verification check).
-- (5) A page the prepare proved closes the exceptions a remask raised about it (marking_made).
-- (6) script_page_set_hidden_areas refuses pages of scripts past verification; a remask job that fails for good no
-- longer takes the marking pictures of such scripts away (staff are told: stale_marking).

-- When an exception was last resolved, in the order resolutions were recorded: its latest audit row (timestamps are
-- the same for every resolution of one transaction).
create index audit_log_exception_idx on public.audit_log (target_id, id) where target_type = 'script_exception';
create function public.script_exception_seq(p_exception uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select max(a.id) from public.audit_log a where a.target_type = 'script_exception' and a.target_id = p_exception
$$;

-- ---------------------------------------------------------------------------------------------
-- script_page_confirmed: as 20261120000061, and only the page's latest name-checked confirmation counts (Ruling R33):
-- the latest by its audit row; it must hold now (the same turn and staff areas as when staff confirmed, and staff areas or "no name"); a "no name"
-- confirmation older than a name_visible resolution of the page is void; while a name_visible exception about the
-- page is open, nothing confirms it.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_page_confirmed(p_page uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
      select (exists (select 1 from public.script_page_hidden_areas a where a.page_id = p_page)
              or (coalesce(e.details ->> 'no_name', '') = 'true'
                  and not exists (select 1 from public.script_exceptions v
                                  where v.page_id = p_page and v.kind = 'name_visible' and v.state = 'resolved'
                                    and v.id <> e.id
                                    and public.script_exception_seq(v.id) > coalesce(public.script_exception_seq(e.id), 0))))
             and e.details ->> 'confirmed_rotation' = p.rotation::text
             and e.details ->> 'confirmed_areas' = public.script_page_areas_key(p.id)
      from public.script_exceptions e
      join public.script_pages p on p.id = e.page_id
      where e.page_id = p_page and e.state = 'resolved' and e.details ? 'confirmed_rotation'
        and ((e.resolution = 'confirmed' and e.kind in ('poor_quality', 'name_visible', 'uncoded_family_page'))
             or (e.resolution = 'assigned' and e.kind in ('no_code', 'unknown_code', 'uncoded_family_page')))
      order by public.script_exception_seq(e.id) desc nulls last, e.resolved_at desc nulls last, e.created_at desc, e.id desc
      limit 1), false)
    and not exists (select 1 from public.script_exceptions v where v.page_id = p_page and v.kind = 'name_visible' and v.state = 'open')
$$;

-- The candidate's copy a script's slots are of: the one of the paper version most of its linked pages are from, else
-- the latest.
create function public.script_slot_copy(p_script uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select c.id from public.scripts s join public.paper_copies c on c.booking_id = s.booking_id
  where s.id = p_script
  order by (c.paper_id is not distinct from (
              select pc.paper_id from public.script_page_links l
              join public.script_pages p on p.id = l.page_id
              join public.paper_copies pc on pc.id = p.copy_id
              where l.script_id = s.id and l.version = s.version
              group by pc.paper_id order by count(*) desc, pc.paper_id limit 1)) desc,
           c.created_at desc, c.id
  limit 1
$$;

-- Whether a script shows the page at an answer slot (an answer page of its candidate's copy, or a spare page).
create function public.script_page_slot_answer(p_page uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.script_page_links l join public.scripts s on s.id = l.script_id and l.version = s.version
                 where l.page_id = p_page and public.script_page_is_answer(public.script_slot_copy(s.id), l.copy_page))
$$;

-- ---------------------------------------------------------------------------------------------
-- script_page_marking_lost: as 20261120000061, with p_cleared: false for a page that keeps its (possibly out of
-- date) marking picture because its script is past verification; the exception then says marking_picture true and
-- stale_marking.
-- ---------------------------------------------------------------------------------------------
drop function public.script_page_marking_lost(uuid);
create function public.script_page_marking_lost(p_page uuid, p_cleared boolean default true)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_p public.script_pages%rowtype;
  v_e public.script_exceptions%rowtype;
  v_booking uuid;
  v_script uuid;
  v_copy_page int;
  v_marks jsonb := case when coalesce(p_cleared, true) then '{"from": "remask", "marking_picture": false}'::jsonb
                        else '{"from": "remask", "marking_picture": true, "stale_marking": true}'::jsonb end;
begin
  select * into v_p from public.script_pages p where p.id = p_page;
  if not found then
    return;
  end if;
  select * into v_e from public.script_exceptions e
  where e.page_id = p_page and e.kind = 'poor_quality' and e.state = 'open' order by e.created_at, e.id limit 1;
  if v_e.id is not null then
    update public.script_exceptions e
    set details = e.details
      || case when e.details ->> 'from' is distinct from 'remask' and not e.details ? 'before_remask'
              then jsonb_build_object('before_remask', jsonb_build_object('from', e.details -> 'from', 'marking_picture', e.details -> 'marking_picture'))
              else '{}'::jsonb end
      || v_marks
    where e.id = v_e.id;
    return;
  end if;
  select s.booking_id, s.id, l.copy_page into v_booking, v_script, v_copy_page
  from public.script_page_links l join public.scripts s on s.id = l.script_id and l.version = s.version
  where l.page_id = p_page order by s.id limit 1;
  if v_booking is null then
    v_booking := coalesce(v_p.booking_id, (select hs.booking_id from public.script_uploads u
                                           join public.home_submissions hs on hs.id = u.submission_id where u.id = v_p.upload_id));
    select x.id into v_script from public.scripts x where x.booking_id = v_booking;
  end if;
  insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details)
  values (v_p.exam_id, 'poor_quality', v_booking, v_script, v_p.id, v_p.upload_id,
    jsonb_build_object('flags', coalesce(v_p.quality -> 'flags', '[]'::jsonb), 'copy_page', coalesce(v_copy_page, v_p.copy_page)) || v_marks);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_page_remask_context: as 20261120000059, and a page is an answer page also when a script shows it at an answer
-- slot (a page staff assigned to an answer page of a candidate's copy), whatever its own copy page is (Ruling R33).
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_page_remask_context(p_page uuid)
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
    'answer', coalesce(case when t.copy_id is not null then public.script_page_is_answer(t.copy_id, t.copy_page)
                            else p.state = 'unmatched' and p.placed_after is not null end, false)
              or public.script_page_slot_answer(p.id),
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

-- ---------------------------------------------------------------------------------------------
-- script_evaluate_at: as 20261120000061, and an answer page is one by its own copy page or by the slot the script shows
-- it at; a page the script shows that a rerun replaced (never made again by a remask) counts as having no marking
-- picture (Ruling R33).
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_evaluate_at(p_script uuid, p_now timestamptz)
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
  v_unmarked boolean;
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
                      and (e.script_id = v_x.id or (e.script_id is null and e.booking_id = v_x.booking_id)))
    or exists (select 1 from public.script_page_links l
               where l.script_id = v_x.id and l.version = v_x.version and public.script_page_refused(l.page_id));
  -- An answer page it shows (a page staff refused aside), or a family's confirmed extra page, with no marking picture:
  -- markers could not see it, so the script is not verified (Ruling R32 d).
  v_unmarked := exists (
      select 1 from public.script_page_links l
      join public.script_pages p on p.id = l.page_id
      cross join lateral public.script_page_copy(p.id) t
      where l.script_id = v_x.id and l.version = v_x.version and not public.script_page_refused(p.id)
        and (p.marking_path is null or p.replaced_at is not null)
        and (coalesce(public.script_page_is_answer(t.copy_id, t.copy_page), false)
             or public.script_page_is_answer(public.script_slot_copy(v_x.id), l.copy_page)))
    or exists (select 1 from public.script_extra_pages(v_x.id) xp join public.script_pages p on p.id = xp.page_id
               where p.marking_path is null);
  v_state := case
    when v_busy then 'checking'
    when v_complete and not v_open and not v_unmarked then 'verified'
    when v_complete and v_unmarked then 'needs_attention'
    when v_x.source = 'centre' and not v_complete and not v_open then 'receiving'
    else 'needs_attention'
  end;

  if (v_x.state, v_x.complete, v_x.received_at) is distinct from (v_state, v_complete, v_received) then
    update public.scripts set state = v_state, complete = v_complete, received_at = v_received where id = v_x.id;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- processing_job_fail: as 20261120000061, and a page that a script past verification shows keeps its marking picture
-- (that script is Phase 3's): staff get the exception, with stale_marking (Ruling R33).
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
  v_page uuid;
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
    perform public.script_bookings_lock(v_bookings || v_booking || array(
      select distinct b from public.script_pages p cross join lateral unnest(public.script_page_owners(p.id)) b
      where p.upload_id = v_up.id and p.replaced_at is null));
    -- Its pages' marking pictures may have been made before the change that queued it: they go, and staff are told
    -- (Ruling R32 e).
    for v_page in
      select p.id from public.script_pages p
      where p.upload_id = v_up.id and p.replaced_at is null and p.marking_path is not null
        and (public.script_page_remask_context(p.id) ->> 'answer')::boolean
      order by p.id
      for update
    loop
      if public.script_page_locked(v_page) then
        -- A script already being marked keeps its pictures; staff are told they may be out of date (Ruling R33).
        perform public.script_page_marking_lost(v_page, false);
      else
        update public.script_pages set marking_path = null where id = v_page;
        perform public.script_page_marking_lost(v_page);
      end if;
    end loop;
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
    for v_script in
      select s.id from public.scripts s
      where s.booking_id = any (v_bookings || v_booking || array(
        select distinct b from public.script_pages p cross join lateral unnest(public.script_page_owners(p.id)) b
        where p.upload_id = v_up.id and p.replaced_at is null))
      order by s.booking_id
    loop
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
-- script_page_set_hidden_areas: as 20261120000058, and refused (script_locked) for a page a script past verification
-- shows, its extra pages included (Ruling R33).
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_page_set_hidden_areas(p_page uuid, p_areas jsonb, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_p public.script_pages%rowtype;
  v_changed boolean;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_page is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if p_areas is null or jsonb_typeof(p_areas) <> 'array' or jsonb_array_length(p_areas) > 20
     or exists (
       select 1 from jsonb_array_elements(p_areas) e
       where jsonb_typeof(e) <> 'object'
          or jsonb_typeof(e -> 'x') is distinct from 'number'
          or jsonb_typeof(e -> 'y') is distinct from 'number'
          or jsonb_typeof(e -> 'w') is distinct from 'number'
          or jsonb_typeof(e -> 'h') is distinct from 'number'
          or (e ->> 'x')::numeric < 0 or (e ->> 'y')::numeric < 0
          or (e ->> 'w')::numeric <= 0 or (e ->> 'h')::numeric <= 0
          or (e ->> 'x')::numeric + (e ->> 'w')::numeric > 1
          or (e ->> 'y')::numeric + (e ->> 'h')::numeric > 1) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_p from public.script_pages p where p.id = p_page for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_p.replaced_at is not null then
    return jsonb_build_object('ok', false, 'code', 'page_replaced');
  end if;
  if public.script_page_locked(v_p.id) then
    return jsonb_build_object('ok', false, 'code', 'script_locked');
  end if;

  v_changed := exists (
    (select a.x, a.y, a.w, a.h from public.script_page_hidden_areas a where a.page_id = v_p.id
     except all
     select (e ->> 'x')::numeric, (e ->> 'y')::numeric, (e ->> 'w')::numeric, (e ->> 'h')::numeric from jsonb_array_elements(p_areas) e)
    union all
    (select (e ->> 'x')::numeric, (e ->> 'y')::numeric, (e ->> 'w')::numeric, (e ->> 'h')::numeric from jsonb_array_elements(p_areas) e
     except all
     select a.x, a.y, a.w, a.h from public.script_page_hidden_areas a where a.page_id = v_p.id));
  delete from public.script_page_hidden_areas where page_id = v_p.id;
  insert into public.script_page_hidden_areas (page_id, x, y, w, h, created_by)
  select v_p.id, (e ->> 'x')::numeric, (e ->> 'y')::numeric, (e ->> 'w')::numeric, (e ->> 'h')::numeric, v_actor
  from jsonb_array_elements(p_areas) with ordinality t(e, n) order by n;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'script_page_hidden_areas_set', 'script_page', v_p.id, v_reason);
  return jsonb_build_object('ok', true, 'page_id', v_p.id, 'areas', jsonb_array_length(p_areas), 'changed', v_changed);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_pages_record: as 20261120000061, and (Ruling R33) the bookings it locks include those of the scripts showing the
-- file's pages; a page staff placed that no slot decides (no booking) stays in its script on the rerun's page at the
-- same position, and staff check its name again; a family's page with no code that staff had confirmed gets an open
-- uncoded_family_page exception again on its new page; a page the prepare proved closes what a remask raised about it.
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
  v_carried uuid[] := '{}';
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
     or not public.script_pages_valid(p_pages,
              v_up.exam_id::text || '/' || v_up.id::text || '/' || v_job.id::text || '-' || v_job.attempts::text || '/') then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_up.sha256 is not null and v_up.sha256 <> p_sha256 then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'sha256_mismatch');
  end if;
  v_home := v_up.submission_id is not null;

  -- Every booking this can touch: those of the upload's current pages, of the scripts that show them, of the codes
  -- read and of the submission.
  select coalesce(array_agg(distinct t.b order by t.b), '{}') into v_bookings
  from (
    select p.booking_id as b from public.script_pages p
    where p.upload_id = v_up.id and p.replaced_at is null and p.booking_id is not null
    union
    select s.booking_id from public.script_pages p
    join public.script_page_links l on l.page_id = p.id
    join public.scripts s on s.id = l.script_id and l.version = s.version
    where p.upload_id = v_up.id and p.replaced_at is null
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

  -- A page staff placed that no slot of the rerun decides (one without a booking: no code, or a rejected code, that
  -- staff assigned) stays in the script: the link moves to the new page at the same position (a new version), and
  -- staff check its name again (Ruling R33).
  for v_x in
    select s.* from public.scripts s
    where exists (select 1 from public.script_page_links l join public.script_pages o on o.id = l.page_id
                  where l.script_id = s.id and l.version = s.version and o.id = any (v_old) and o.booking_id is null)
    order by s.id
    for update
  loop
    v_carried := v_carried || array(
      select n.id from public.script_page_links l
      join public.script_pages o on o.id = l.page_id and o.id = any (v_old) and o.booking_id is null
      join public.script_pages n on n.upload_id = v_up.id and n.replaced_at is null and n.source_index = o.source_index
      where l.script_id = v_x.id and l.version = v_x.version);
    if public.script_version_write(v_x.id, (
         select coalesce(jsonb_object_agg(l.copy_page::text, coalesce(n.id, l.page_id)), '{}'::jsonb)
         from public.script_page_links l
         left join public.script_pages o on o.id = l.page_id and o.id = any (v_old) and o.booking_id is null
         left join public.script_pages n on o.id is not null and n.upload_id = v_up.id and n.replaced_at is null
           and n.source_index = o.source_index
         where l.script_id = v_x.id and l.version = v_x.version), null, v_up.id, 'reprocessed', v_now) then
      v_changed := v_changed || v_x.id;
    end if;
  end loop;

  -- A family's page with no code that staff had confirmed: its placement carried over, so staff confirm the new page
  -- again (it is not silently dropped from the script; Ruling R33).
  if v_home then
    insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details)
    select v_up.exam_id, 'uncoded_family_page', v_sub.booking_id, (select x.id from public.scripts x where x.booking_id = v_sub.booking_id),
      n.id, v_up.id, jsonb_build_object('after_page', n.placed_after, 'from', 'family', 'reprocessed', true)
    from public.script_pages o
    join public.script_pages n on n.upload_id = v_up.id and n.replaced_at is null and n.source_index = o.source_index
      and n.state = 'unmatched' and n.placed_after is not null
    where o.id = any (v_old)
      and exists (select 1 from public.script_exceptions e
                  where e.page_id = o.id and e.kind = 'uncoded_family_page' and e.state = 'resolved' and e.resolution = 'confirmed')
      and not exists (select 1 from public.script_exceptions e where e.page_id = n.id and e.kind = 'uncoded_family_page' and e.state = 'open');
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
  where (x ->> 'finding' in ('unknown_code', 'other_exam', 'not_expected') or (x ->> 'finding' = 'no_code' and not v_home))
    and not (p.id = any (v_carried));  -- a page staff placed, carried over: its name check is asked for instead

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

  -- A page the prepare proved (it has a marking picture) settles what a remask raised about it; a carried page without
  -- one goes to staff (Ruling R33).
  perform public.script_page_marking_made(p.id) from public.script_pages p
  where p.upload_id = v_up.id and p.replaced_at is null and p.marking_path is not null;
  perform public.script_page_marking_lost(c) from unnest(v_carried) c
  where (select p.marking_path from public.script_pages p where p.id = c) is null;

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
-- Access: the new helpers are internal (the re-created functions keep their access).
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.script_exception_seq(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_slot_copy(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_slot_answer(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_marking_lost(uuid, boolean) from public, anon, authenticated, service_role;
