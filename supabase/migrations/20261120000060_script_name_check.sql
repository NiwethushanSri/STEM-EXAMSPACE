-- Phase 2 Task 11 follow-up (Ruling R31): the name check for pages with no code, and remask results that no longer
-- prove a page go to staff.
--
-- (a) A page with no code (no copy: no code read, or an unknown one) is never proved by its print layout, so its
-- marking picture can only be the nominal band, its paper's areas and the staff areas. Staff assigning such a page
-- (script_exception_assign: no_code, unknown_code, uncoded_family_page) or confirming a family's placement of one
-- (script_exception_confirm: uncoded_family_page) must first hide the name on it (a staff hidden area) or say there is
-- none (p_no_name, kept as details.no_name), as Task 10's m4 asks for a page whose layout was unexpected; otherwise
-- name_not_hidden. That makes the page confirmed (script_page_confirmed) and the remask job the resolution queues
-- makes its marking picture.
--
-- (b) When a remask cannot make a page's marking picture again (not proved, not confirmed), the old picture is taken
-- away (it was made with other areas or another turn) and the page gets one open poor_quality exception for staff
-- ({"from": "remask"}), at home as at the centre. At home an open poor_quality exception on the page means the family
-- is not asked to take it again (Ruling R16): it is not the family's file, so it cannot be rejected either. Staff hide
-- the name or say there is none and accept it, which queues a remask that makes the picture from the staff areas.

-- ---------------------------------------------------------------------------------------------
-- script_page_confirmed: as 20261120000059, and staff confirm a page's name is hidden also when they confirm a
-- family's placement of a page with no code, or assign a page with no code (no_code, unknown_code,
-- uncoded_family_page), with staff hidden areas on it or "there is no name on this page".
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_page_confirmed(p_page uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.script_exceptions e
    where e.page_id = p_page and e.state = 'resolved'
      and ((e.resolution = 'confirmed' and e.kind in ('poor_quality', 'name_visible', 'uncoded_family_page'))
           or (e.resolution = 'assigned' and e.kind in ('no_code', 'unknown_code', 'uncoded_family_page')))
      and (coalesce(e.details ->> 'no_name', '') = 'true'
           or exists (select 1 from public.script_page_hidden_areas a where a.page_id = p_page)))
$$;

-- ---------------------------------------------------------------------------------------------
-- script_reject_targets: as 20261120000058, and a poor_quality exception raised by a remask (its marking picture
-- could not be made again) rejects no family submission: it is not the family's file.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_reject_targets(p_exception uuid)
returns uuid[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_e public.script_exceptions%rowtype;
  v_sub public.home_submissions%rowtype;
  v_latest public.home_submissions%rowtype;
begin
  select * into v_e from public.script_exceptions e where e.id = p_exception;
  if not found or (v_e.kind = 'processing_failed' and v_e.details ->> 'kind' = 'remask')
     or (v_e.kind = 'poor_quality' and v_e.details ->> 'from' = 'remask') then
    return '{}';
  end if;
  select s.* into v_sub from public.home_submissions s join public.script_uploads u on u.submission_id = s.id
  where u.id = coalesce(v_e.upload_id, (select p.upload_id from public.script_pages p where p.id = v_e.page_id));
  if v_sub.id is null then
    return '{}';
  end if;
  if v_e.page_id is not null and exists (
       select 1 from public.scripts s join public.script_page_links l on l.script_id = s.id and l.version = s.version
       where s.booking_id = v_sub.booking_id and l.page_id = v_e.page_id) then
    return array(select s.id from public.home_submissions s
                 where s.booking_id = v_sub.booking_id and s.seq >= v_sub.seq and s.state not in ('draft', 'rejected') order by s.seq);
  end if;
  v_latest := public.home_submission_latest(v_sub.booking_id);
  if v_latest.id = v_sub.id and v_sub.state not in ('draft', 'rejected') then
    return array[v_sub.id];
  end if;
  return '{}';
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_exception_reject: as 20261120000058, and a poor_quality exception raised by a remask cannot be rejected
-- (wrong_kind): the page was fine, only its marking picture could not be made again. Staff hide the name and accept
-- it.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_exception_reject(p_exception uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := now();
  v_reason text := public.script_resolution_reason(p_reason);
  v_e public.script_exceptions%rowtype;
  v_sub public.home_submissions%rowtype;
  v_targets uuid[];
  v_bookings uuid[];
  v_b uuid;
  v_outcome text;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exception is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  select * into v_e from public.script_exceptions e where e.id = p_exception;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select s.* into v_sub from public.home_submissions s join public.script_uploads u on u.submission_id = s.id
  where u.id = coalesce(v_e.upload_id, (select p.upload_id from public.script_pages p where p.id = v_e.page_id));

  v_bookings := public.script_resolution_lock(p_exception, array[v_sub.booking_id]);
  if v_bookings is null then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'changed');
  end if;
  select * into v_e from public.script_exceptions e where e.id = p_exception;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_e.state <> 'open' then
    return public.script_exception_conflict(v_e.id);
  end if;
  if v_e.kind not in ('no_code', 'unknown_code', 'other_exam', 'not_expected', 'uncoded_family_page', 'poor_quality', 'processing_failed')
     or (v_e.kind = 'processing_failed' and v_e.details ->> 'kind' = 'remask')
     or (v_e.kind = 'poor_quality' and v_e.details ->> 'from' = 'remask') then
    return jsonb_build_object('ok', false, 'code', 'wrong_kind');
  end if;
  v_targets := public.script_reject_targets(v_e.id);
  if (v_e.page_id is not null and public.script_page_locked(v_e.page_id))
     or (cardinality(v_targets) > 0 and exists (
           select 1 from public.scripts s where s.booking_id = v_sub.booking_id
             and s.state not in ('receiving', 'checking', 'needs_attention', 'verified'))) then
    return jsonb_build_object('ok', false, 'code', 'script_locked');
  end if;

  perform public.script_exception_close(v_e.id, 'rejected', v_reason, v_actor, v_now, 'script_exception_rejected');
  if cardinality(v_targets) > 0 then
    perform public.script_home_reject(v_sub.booking_id, v_targets, v_reason, v_actor, v_now);
    v_outcome := 'submission_rejected';
  end if;
  if v_e.page_id is not null then
    perform public.script_page_set_aside(v_e.page_id, v_actor, v_now, v_reason);
    v_outcome := coalesce(v_outcome, case when v_sub.id is null then 'set_aside' else 'closed' end);
  end if;
  foreach v_b in array v_bookings loop
    perform public.script_resolution_settle(v_b, v_actor, v_reason);
  end loop;
  return jsonb_build_object('ok', true, 'exception_id', v_e.id, 'resolution', 'rejected',
    'outcome', coalesce(v_outcome, 'closed'), 'submission_rejected', cardinality(v_targets) > 0);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_exception_confirm: as 20261120000058, and the name check (a staff hidden area on the page, or p_no_name,
-- kept as details.no_name; else name_not_hidden) also applies to a family's placement of a page with no code
-- (uncoded_family_page), to a poor-quality page with no code, and to a page whose marking picture a remask could not
-- make again (poor_quality from remask). Confirming then makes the page's marking picture (a remask job): the nominal
-- band, its paper's areas and the staff areas (Ruling R31).
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_exception_confirm(p_exception uuid, p_reason text default null, p_no_name boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := now();
  v_given text := nullif(btrim(coalesce(p_reason, '')), '');
  v_reason text := public.script_resolution_reason(p_reason);
  v_e public.script_exceptions%rowtype;
  v_name_check boolean;
  v_bookings uuid[];
  v_b uuid;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exception is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_given is not null and v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if not exists (select 1 from public.script_exceptions e where e.id = p_exception) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  v_bookings := public.script_resolution_lock(p_exception, '{}');
  if v_bookings is null then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'changed');
  end if;
  select * into v_e from public.script_exceptions e where e.id = p_exception;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_e.state <> 'open' then
    return public.script_exception_conflict(v_e.id);
  end if;
  if v_e.kind not in ('uncoded_family_page', 'poor_quality', 'mixed_versions', 'processing_failed', 'name_visible') then
    return jsonb_build_object('ok', false, 'code', 'wrong_kind');
  end if;
  if v_e.kind = 'mixed_versions' and (
       select count(distinct c.paper_id)
       from public.scripts s
       join public.script_page_links l on l.script_id = s.id and l.version = s.version
       join public.script_pages p on p.id = l.page_id
       join public.paper_copies c on c.id = p.copy_id
       where s.id = coalesce(v_e.script_id, (select x.id from public.scripts x where x.booking_id = v_e.booking_id))) > 1 then
    return jsonb_build_object('ok', false, 'code', 'still_mixed');
  end if;
  v_name_check := v_e.page_id is not null and (
    v_e.kind in ('name_visible', 'uncoded_family_page')
    or (v_e.kind = 'poor_quality' and (v_e.details ->> 'from' = 'remask'
        or exists (select 1 from public.script_pages p
                   where p.id = v_e.page_id and (p.copy_id is null or coalesce(p.quality -> 'flags' ? 'layout_unexpected', false))))));
  if v_name_check and not coalesce(p_no_name, false)
     and not exists (select 1 from public.script_page_hidden_areas a where a.page_id = v_e.page_id) then
    return jsonb_build_object('ok', false, 'code', 'name_not_hidden');
  end if;

  if v_name_check and coalesce(p_no_name, false) then
    update public.script_exceptions set details = details || '{"no_name": true}'::jsonb where id = v_e.id;
  end if;
  perform public.script_exception_close(v_e.id, 'confirmed', v_reason, v_actor, v_now, 'script_exception_confirmed');
  if v_e.page_id is not null then
    perform public.script_page_remask(v_e.page_id);
  end if;
  foreach v_b in array v_bookings loop
    perform public.script_resolution_settle(v_b, v_actor, v_reason);
  end loop;
  return jsonb_build_object('ok', true, 'exception_id', v_e.id, 'resolution', 'confirmed');
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_exception_assign: as 20261120000058, with p_no_name: a page with no copy (no code, or an unknown code) is
-- assigned only once staff hid the name on it (a staff hidden area) or say there is none (p_no_name, kept as
-- details.no_name); else name_not_hidden, nothing changed (Ruling R31). Its marking picture is then made by the remask
-- job the assignment queues: the nominal band, the paper's areas of the copy page it is assigned to and the staff
-- areas. The old five-argument function is replaced (one function, so calls are never ambiguous).
-- ---------------------------------------------------------------------------------------------
drop function public.script_exception_assign(uuid, uuid, int, text, boolean);
create function public.script_exception_assign(p_exception uuid, p_booking uuid, p_copy_page int, p_reason text, p_replace boolean default false,
  p_no_name boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := now();
  v_reason text := public.script_resolution_reason(p_reason);
  v_e public.script_exceptions%rowtype;
  v_p public.script_pages%rowtype;
  v_up public.script_uploads%rowtype;
  v_b public.bookings%rowtype;
  v_x public.scripts%rowtype;
  v_home boolean;
  v_from uuid;
  v_pages int;
  v_links jsonb;
  v_old uuid;
  v_bookings uuid[];
  v_s uuid;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exception is null or p_booking is null or p_copy_page is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  select * into v_e from public.script_exceptions e where e.id = p_exception;
  select * into v_b from public.bookings b where b.id = p_booking;
  if v_e.id is null or v_b.id is null then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  v_bookings := public.script_resolution_lock(p_exception, array[v_b.id]);
  if v_bookings is null then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'changed');
  end if;
  select * into v_e from public.script_exceptions e where e.id = p_exception;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_e.state <> 'open' then
    return public.script_exception_conflict(v_e.id);
  end if;
  if v_e.kind not in ('no_code', 'unknown_code', 'not_expected', 'uncoded_family_page', 'duplicate') or v_e.page_id is null then
    return jsonb_build_object('ok', false, 'code', 'wrong_kind');
  end if;
  select * into v_p from public.script_pages p where p.id = v_e.page_id;
  if v_p.replaced_at is not null then
    return jsonb_build_object('ok', false, 'code', 'page_replaced');
  end if;
  select * into v_up from public.script_uploads u where u.id = v_p.upload_id;
  v_home := v_up.submission_id is not null;

  if v_b.exam_id <> v_e.exam_id then
    return jsonb_build_object('ok', false, 'code', 'other_exam');
  end if;
  if v_b.status not in ('paid', 'cancel_requested') then
    return jsonb_build_object('ok', false, 'code', 'booking_not_active');
  end if;
  if v_b.sitting <> (case when v_home then 'home' else 'centre' end)::public.sitting_mode then
    return jsonb_build_object('ok', false, 'code', 'wrong_sitting');
  end if;
  if v_home then
    select s.booking_id into v_from from public.home_submissions s where s.id = v_up.submission_id;
    if v_b.id is distinct from v_from and not exists (
         select 1 from public.bookings f
         join public.parent_children a on a.student_id = f.student_id
         join public.parent_children o on o.parent_id = a.parent_id
         where f.id = v_from and o.student_id = v_b.student_id) then
      return jsonb_build_object('ok', false, 'code', 'forbidden', 'reason', 'other_family');
    end if;
  elsif not exists (select 1 from public.attendance a
                    where a.exam_id = v_b.exam_id and a.student_id = v_b.student_id and a.status in ('present', 'late')) then
    return jsonb_build_object('ok', false, 'code', 'not_present');
  end if;
  select c.page_count into v_pages from public.paper_copies c where c.booking_id = v_b.id order by c.created_at desc, c.id limit 1;
  if v_pages is null or p_copy_page not between 1 and v_pages then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if exists (select 1 from public.script_page_links l join public.scripts s on s.id = l.script_id and l.version = s.version
             where l.page_id = v_p.id and s.booking_id <> v_b.id) then
    return jsonb_build_object('ok', false, 'code', 'in_other_script');
  end if;

  select * into v_x from public.scripts s where s.booking_id = v_b.id for update;
  if v_x.id is not null and v_x.state not in ('receiving', 'checking', 'needs_attention', 'verified') then
    return jsonb_build_object('ok', false, 'code', 'script_locked');
  end if;
  if v_x.id is not null then
    v_old := (public.script_links(v_x.id) ->> p_copy_page::text)::uuid;
    if v_old is not null and v_old <> v_p.id and not coalesce(p_replace, false) then
      return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'occupied', 'page_id', v_old);
    end if;
  end if;
  -- A page with no code (no copy: no code read, or an unknown one) is never proved by its print layout, so its name
  -- must be hidden by staff first, or staff say there is none (Ruling R31).
  if v_p.copy_id is null and not coalesce(p_no_name, false)
     and not exists (select 1 from public.script_page_hidden_areas a where a.page_id = v_p.id) then
    return jsonb_build_object('ok', false, 'code', 'name_not_hidden');
  end if;
  if v_x.id is null then
    v_x := public.script_create(v_b.id, (case when v_home then 'home' else 'centre' end)::public.script_source, v_now);
  end if;
  v_links := public.script_links(v_x.id);
  v_links := coalesce((select jsonb_object_agg(t.k, t.v) from jsonb_each_text(v_links) t(k, v) where t.v <> v_p.id::text), '{}'::jsonb)
             || jsonb_build_object(p_copy_page::text, v_p.id);
  perform public.script_links_write(v_x.id, v_links, 'staff_assign', v_actor, v_now);
  select * into v_x from public.scripts s where s.id = v_x.id;

  if v_old is not null and v_old <> v_p.id
     and not (v_e.kind = 'duplicate' and v_old = (v_e.details ->> 'kept_page_id')::uuid)
     and not exists (select 1 from public.script_exceptions e where e.page_id = v_old and e.kind = 'duplicate' and e.state = 'open') then
    insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details)
    select v_e.exam_id, 'duplicate', v_b.id, v_x.id, o.id, o.upload_id,
      jsonb_build_object('copy_page', p_copy_page, 'kept_page_id', v_p.id, 'from', 'staff')
    from public.script_pages o where o.id = v_old;
  end if;

  update public.script_exceptions
  set details = details || jsonb_build_object('assigned', jsonb_build_object(
        'booking_id', v_b.id, 'copy_page', p_copy_page, 'script_id', v_x.id, 'version', v_x.version))
        || case when v_p.copy_id is null and coalesce(p_no_name, false) then '{"no_name": true}'::jsonb else '{}'::jsonb end,
      booking_id = coalesce(booking_id, v_b.id),
      script_id = coalesce(script_id, v_x.id)
  where id = v_e.id;
  perform public.script_exception_close(v_e.id, 'assigned', v_reason, v_actor, v_now, 'script_exception_assigned');
  perform public.script_page_remask(v_p.id);
  foreach v_s in array v_bookings loop
    perform public.script_resolution_settle(v_s, v_actor, v_reason);
  end loop;
  return jsonb_build_object('ok', true, 'exception_id', v_e.id, 'resolution', 'assigned', 'script_id', v_x.id,
    'script_number', v_x.number, 'version', v_x.version,
    'replaced_page_id', case when v_old is distinct from v_p.id then v_old end);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_pages_remasked: as 20261120000059, and an answer page whose marking picture the remask could not make again
-- (its geometry not proved, not confirmed by staff) loses the old one (marking_path null: it was made with other
-- areas or another turn) and gets one open poor_quality exception for staff, {"from": "remask"}, at home as at the
-- centre. At home that exception also means the family is not asked to take the page again (Ruling R16): it was not
-- their file. Staff hide the name or say there is none and accept it, which queues a remask (Ruling R31).
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_pages_remasked(p_job bigint, p_worker text, p_attempt int, p_pages jsonb, p_now timestamptz default null)
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

  if cardinality(v_lost) > 0 then
    insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details)
    select distinct on (p.id) v_up.exam_id, 'poor_quality', coalesce(s.booking_id, p.booking_id),
      coalesce(s.id, (select x.id from public.scripts x where x.booking_id = p.booking_id)), p.id, v_up.id,
      jsonb_build_object('flags', coalesce(p.quality -> 'flags', '[]'::jsonb), 'copy_page', coalesce(l.copy_page, p.copy_page),
        'marking_picture', false, 'from', 'remask')
    from public.script_pages p
    left join public.script_page_links l on l.page_id = p.id
      and l.version = (select s2.version from public.scripts s2 where s2.id = l.script_id)
    left join public.scripts s on s.id = l.script_id
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
-- Access (the re-created functions keep theirs; the assign function is new).
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.script_exception_assign(uuid, uuid, int, text, boolean, boolean) from public, anon;
grant execute on function public.script_exception_assign(uuid, uuid, int, text, boolean, boolean) to authenticated;
