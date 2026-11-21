-- Phase 2 Task 11 fix round 1 (Ruling R32): staff confirmations are bound to the page as staff saw it, and a page that
-- can be proved by its print layout never falls back to the nominal band.
--
-- (a) A name-checked confirmation (script_exception_confirm, or assigning a page with no code) records the page's
-- rotation and the key of its staff hidden areas (details.confirmed_rotation, details.confirmed_areas).
-- script_page_confirmed is true only while both still match: a later turn or change of the staff areas needs a new
-- confirmation before a marking picture is made from it.
-- (b) A page that can be proved (it has a code and its prepare did not flag layout_unexpected, which every page that
-- had a proved marking picture satisfies) never gets the nominal fallback: the processor ignores confirmations for it
-- and makes a marking picture only by proving its geometry again (services/processor: pipeline.remask).
-- (c) The processor also paints the nominal band and the paper's areas in the stored frame before turning.
-- (d) A page left without a marking picture by a remask, that had one or that staff had confirmed, is handed to staff:
-- a new open poor_quality exception {"from": "remask", "marking_picture": false}, or those keys merged into the page's
-- open poor_quality exception (what they were is kept under before_remask). Confirming any poor_quality whose
-- details say marking_picture false needs the name check. A script is never verified while an answer page it shows,
-- or a family's confirmed extra page, has no marking picture. When a later remask makes the picture again, an
-- exception the remask raised closes (marking_made) and a merged one goes back to what it was.
-- (e) A remask job that fails for good takes away the marking pictures of its file's current pages and hands each to
-- staff as in (d); confirming its processing_failed exception queues the remask again.
-- (f) script_page_locked covers a family's extra pages of a script past verification; a lost picture on an extra page
-- is raised on the placed page's booking and script; pictures go to a folder per job and attempt,
-- <exam>/<upload>/<job>-<attempt>/, and script_pages_record accepts no other; script_upload_reprocess works its
-- bookings out again once the file is locked; script_page_copy places a page with no code in the paper version of the
-- script's other pages.

-- ---------------------------------------------------------------------------------------------
-- Helpers (internal).
-- ---------------------------------------------------------------------------------------------

-- The key of a page's staff hidden areas (in any order): a confirmation holds while it is the same.
create function public.script_page_areas_key(p_page uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select md5(coalesce(string_agg(a.x::text || ',' || a.y::text || ',' || a.w::text || ',' || a.h::text, ';'
                                 order by a.x, a.y, a.w, a.h), ''))
  from public.script_page_hidden_areas a where a.page_id = p_page
$$;

-- What a confirmation is bound to: the page's rotation and the key of its staff hidden areas now.
create function public.script_page_binding(p_page uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('confirmed_rotation', p.rotation, 'confirmed_areas', public.script_page_areas_key(p.id))
  from public.script_pages p where p.id = p_page
$$;

-- Whether staff ever confirmed the page's name hidden (as script_page_confirmed, bound or not).
create function public.script_page_confirm_given(p_page uuid)
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
           or (e.resolution = 'assigned' and e.kind in ('no_code', 'unknown_code', 'uncoded_family_page'))))
$$;

-- ---------------------------------------------------------------------------------------------
-- script_page_confirmed: as 20261120000060, and only while the confirmation's binding still matches the page: the
-- same rotation and the same staff hidden areas as when staff confirmed (Ruling R32 a).
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
    join public.script_pages p on p.id = e.page_id
    where e.page_id = p_page and e.state = 'resolved'
      and ((e.resolution = 'confirmed' and e.kind in ('poor_quality', 'name_visible', 'uncoded_family_page'))
           or (e.resolution = 'assigned' and e.kind in ('no_code', 'unknown_code', 'uncoded_family_page')))
      and (coalesce(e.details ->> 'no_name', '') = 'true'
           or exists (select 1 from public.script_page_hidden_areas a where a.page_id = p_page))
      and e.details ->> 'confirmed_rotation' = p.rotation::text
      and e.details ->> 'confirmed_areas' = public.script_page_areas_key(p.id))
$$;

-- The bookings a page concerns (script_page_bookings) and, for a page of a home file, the family's booking (a placed
-- page with no code belongs to no booking itself).
create function public.script_page_owners(p_page uuid)
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select array(select distinct b from unnest(public.script_page_bookings(p_page) || array[(
      select hs.booking_id from public.script_pages p
      join public.script_uploads u on u.id = p.upload_id
      join public.home_submissions hs on hs.id = u.submission_id
      where p.id = p_page)]) b
    where b is not null order by 1)
$$;

-- Hands a page with no marking picture to staff (the caller holds the locks of script_page_owners): one open
-- poor_quality exception {"from": "remask", "marking_picture": false}, merged into the page's open poor_quality
-- exception when it has one (what its from and marking_picture were is kept under before_remask), else a new one on
-- the booking and script that show it (a family's extra page: its family's booking and script).
create function public.script_page_marking_lost(p_page uuid)
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
      || '{"from": "remask", "marking_picture": false}'::jsonb
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
    jsonb_build_object('flags', coalesce(v_p.quality -> 'flags', '[]'::jsonb), 'copy_page', coalesce(v_copy_page, v_p.copy_page),
      'marking_picture', false, 'from', 'remask'));
end;
$$;

-- A page has a marking picture again: an open exception a remask raised about it closes (marking_made, audited), and a
-- merged one goes back to what it was before (its before_remask).
create function public.script_page_marking_made(p_page uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  with closed as (
    update public.script_exceptions e
    set state = 'resolved', resolved_at = now(), resolution = 'marking_made', reason = 'The marking picture was made again.'
    where e.page_id = p_page and e.kind = 'poor_quality' and e.state = 'open' and e.details ->> 'from' = 'remask'
      and not e.details ? 'before_remask'
    returning e.id)
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  select null, 'script_exception_marking_made', 'script_exception', c.id, 'The marking picture was made again.' from closed c;
  update public.script_exceptions e
  set details = (e.details - 'before_remask' - 'from' - 'marking_picture') || jsonb_strip_nulls(e.details -> 'before_remask')
  where e.page_id = p_page and e.kind = 'poor_quality' and e.state = 'open' and e.details ? 'before_remask';
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_page_copy: as 20261120000059, and a page with no code that a script shows is placed in the paper version of
-- the script's other pages (the most of them), the candidate's copy of it; else the candidate's latest copy.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_page_copy(p_page uuid, out copy_id uuid, out copy_page int)
returns record
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(p.copy_id, t.copy_id), coalesce(p.copy_page, t.copy_page)
  from public.script_pages p
  left join lateral (
    select (select c.id from public.paper_copies c
            where c.booking_id = s.booking_id
            order by (c.paper_id is not distinct from (
                        select pc.paper_id from public.script_page_links l2
                        join public.script_pages p2 on p2.id = l2.page_id
                        join public.paper_copies pc on pc.id = p2.copy_id
                        where l2.script_id = s.id and l2.version = s.version and l2.page_id <> p.id
                        group by pc.paper_id order by count(*) desc, pc.paper_id limit 1)) desc,
                     c.created_at desc, c.id
            limit 1) as copy_id,
           l.copy_page
    from public.script_page_links l join public.scripts s on s.id = l.script_id and l.version = s.version
    where l.page_id = p.id and p.copy_id is null
    order by s.id
    limit 1
  ) t on true
  where p.id = p_page
$$;

-- ---------------------------------------------------------------------------------------------
-- script_page_locked: as 20261120000058, and a family's extra page of a script past verification is locked too.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_page_locked(p_page uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.script_page_links l join public.scripts s on s.id = l.script_id and l.version = s.version
                 where l.page_id = p_page and s.state not in ('receiving', 'checking', 'needs_attention', 'verified'))
      or exists (select 1 from public.script_pages p
                 join public.script_uploads u on u.id = p.upload_id
                 join public.home_submissions hs on hs.id = u.submission_id
                 join public.scripts s on s.booking_id = hs.booking_id
                 where p.id = p_page and s.state not in ('receiving', 'checking', 'needs_attention', 'verified')
                   and exists (select 1 from public.script_extra_pages(s.id) x where x.page_id = p_page))
$$;

-- The bookings a file concerns: its own (or its submission's), those of its current pages, and those whose current
-- script shows any of its pages.
create function public.script_upload_bookings(p_upload uuid)
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select array(select distinct b from (
      select u.booking_id as b from public.script_uploads u where u.id = p_upload
      union all
      select hs.booking_id from public.script_uploads u join public.home_submissions hs on hs.id = u.submission_id where u.id = p_upload
      union all
      select p.booking_id from public.script_pages p where p.upload_id = p_upload and p.replaced_at is null
      union all
      select s.booking_id from public.script_pages p
      join public.script_page_links l on l.page_id = p.id
      join public.scripts s on s.id = l.script_id and l.version = s.version
      where p.upload_id = p_upload) t
    where b is not null order by 1)
$$;

-- Locks what changing a file touches, in the lock order: its bookings, then the file's row; the bookings are worked
-- out again once the row is locked (as script_resolution_lock); null when they changed twice.
create function public.script_upload_lock(p_upload uuid)
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
    v_want := public.script_upload_bookings(p_upload);
    if v_try > 1 and v_want <@ v_locked then
      return v_locked;
    end if;
    if v_try = 3 then
      return null;
    end if;
    perform public.script_bookings_lock(v_want);
    v_locked := array(select distinct b from unnest(v_locked || v_want) b order by 1);
    perform 1 from public.script_uploads u where u.id = p_upload for update;
  end loop;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_exception_confirm: as 20261120000060, and (Ruling R32) a name-checked confirmation is bound to the page as
-- staff saw it (details.confirmed_rotation and details.confirmed_areas: its rotation and the key of its staff hidden
-- areas); confirming any poor_quality whose details say marking_picture false needs the name check; a name-checked
-- confirmation always queues a remask for the page's file; confirming a remask failure (processing_failed, kind
-- remask) queues the remask again.
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
    or (v_e.kind = 'poor_quality' and (v_e.details ->> 'from' = 'remask' or v_e.details ->> 'marking_picture' = 'false'
        or exists (select 1 from public.script_pages p
                   where p.id = v_e.page_id and (p.copy_id is null or coalesce(p.quality -> 'flags' ? 'layout_unexpected', false))))));
  if v_name_check and not coalesce(p_no_name, false)
     and not exists (select 1 from public.script_page_hidden_areas a where a.page_id = v_e.page_id) then
    return jsonb_build_object('ok', false, 'code', 'name_not_hidden');
  end if;

  if v_name_check then
    -- The confirmation holds for the page as staff saw it: its turn and its staff hidden areas now (Ruling R32).
    update public.script_exceptions
    set details = details || public.script_page_binding(v_e.page_id)
                  || case when coalesce(p_no_name, false) then '{"no_name": true}'::jsonb else '{}'::jsonb end
    where id = v_e.id;
  end if;
  perform public.script_exception_close(v_e.id, 'confirmed', v_reason, v_actor, v_now, 'script_exception_confirmed');
  if v_name_check then
    perform public.script_remask_queue(p.upload_id) from public.script_pages p where p.id = v_e.page_id and p.replaced_at is null;
  elsif v_e.page_id is not null then
    perform public.script_page_remask(v_e.page_id);
  end if;
  -- A remask that failed for good is made again once staff have looked (Ruling R32 e).
  if v_e.kind = 'processing_failed' and v_e.details ->> 'kind' = 'remask' and v_e.upload_id is not null then
    perform public.script_remask_queue(v_e.upload_id);
  end if;
  foreach v_b in array v_bookings loop
    perform public.script_resolution_settle(v_b, v_actor, v_reason);
  end loop;
  return jsonb_build_object('ok', true, 'exception_id', v_e.id, 'resolution', 'confirmed');
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_exception_assign: as 20261120000060, and the name check of a page with no code is bound to the page as staff
-- saw it (details.confirmed_rotation and confirmed_areas, Ruling R32).
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_exception_assign(p_exception uuid, p_booking uuid, p_copy_page int, p_reason text, p_replace boolean default false,
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
        || case when v_p.copy_id is null and coalesce(p_no_name, false) then '{"no_name": true}'::jsonb else '{}'::jsonb end
        || case when v_p.copy_id is null then public.script_page_binding(v_p.id) else '{}'::jsonb end,
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
-- script_pages_remasked: as 20261120000060, with the pictures in the job's folder for this attempt
-- (<exam>/<upload>/<job>-<attempt>/), and (Ruling R32 d) a page that has no marking picture now, and had one or had a
-- staff confirmation, is handed to staff by script_page_marking_lost (a new poor_quality exception, or merged into
-- the page's open one); a page that gets a marking picture again closes the exception a remask raised
-- (script_page_marking_made). The bookings concerned include a family's extra page's (script_page_owners).
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
  v_dir := v_up.exam_id::text || '/' || v_up.id::text || '/' || v_job.id::text || '-' || v_job.attempts::text || '/';
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
  from unnest(v_ids) i cross join lateral unnest(public.script_page_owners(i)) b;
  perform public.script_bookings_lock(v_bookings);
  perform 1 from public.script_pages p where p.id = any (v_ids) order by p.id for update;
  select coalesce(array_agg(distinct b order by b), '{}') into v_more
  from unnest(v_ids) i cross join lateral unnest(public.script_page_owners(i)) b;
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
    -- No marking picture now, for a page that had one or that staff had confirmed: staff are told (Ruling R32 d).
    if v_i.marking_path is null and (v_p.marking_path is not null or public.script_page_confirm_given(v_p.id)) then
      v_lost := v_lost || v_p.id;
    end if;
    if v_p.marking_path is distinct from v_i.marking_path then
      update public.script_pages set marking_path = v_i.marking_path where id = v_p.id;
    end if;
    v_written := v_written + 1;
    if v_i.marking_path is not null then
      v_marking := v_marking + 1;
      perform public.script_page_marking_made(v_p.id);
    end if;
  end loop;

  perform public.script_page_marking_lost(l) from unnest(v_lost) l;

  for v_script in select s.id from public.scripts s where s.booking_id = any (v_bookings) order by s.booking_id loop
    perform public.script_evaluate_at(v_script, v_now);
  end loop;
  return jsonb_build_object('ok', true, 'pages', v_written, 'marking', v_marking, 'stale', v_stale, 'replaced', v_replaced);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- processing_job_fail: as 20261120000059, and a remask job that fails for good takes away the marking pictures of its
-- file's current pages (they may have been made before the change that queued it) and hands each to staff
-- (script_page_marking_lost), before the scripts are worked out again (Ruling R32 e). Confirming its
-- processing_failed exception queues the remask again (script_exception_confirm).
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
      update public.script_pages set marking_path = null where id = v_page;
      perform public.script_page_marking_lost(v_page);
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
-- script_evaluate_at: as 20261120000058, and a complete script is not verified while an answer page it shows (not one
-- staff refused), or a confirmed extra page, has no marking picture: it needs attention (Ruling R32 d).
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
      where l.script_id = v_x.id and l.version = v_x.version and p.marking_path is null
        and not public.script_page_refused(p.id) and coalesce(public.script_page_is_answer(t.copy_id, t.copy_page), false))
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
-- script_pages_record: as 20261120000059, and the pictures must be in the folder of this job and attempt,
-- <exam>/<upload>/<job>-<attempt>/ (the file's own folder of before is no longer accepted, Ruling R32 f), so neither a
-- rerun nor a retried attempt overwrites pictures another page row names.
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
     or not public.script_pages_valid(p_pages,
              v_up.exam_id::text || '/' || v_up.id::text || '/' || v_job.id::text || '-' || v_job.attempts::text || '/') then
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
-- script_upload_reprocess: as 20261120000059, and the bookings to lock are worked out again once the file is locked
-- (script_upload_lock, as Task 10's script_resolution_lock), refusing (conflict, changed) if they keep changing.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_upload_reprocess(p_upload uuid, p_reason text)
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

  v_bookings := public.script_upload_lock(p_upload);
  if v_bookings is null then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'changed');
  end if;
  select * into v_up from public.script_uploads u where u.id = p_upload;
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
-- Access: the new helpers are internal (the re-created functions keep their access).
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.script_page_areas_key(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_binding(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_confirm_given(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_owners(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_marking_lost(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_marking_made(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_upload_bookings(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_upload_lock(uuid) from public, anon, authenticated, service_role;
