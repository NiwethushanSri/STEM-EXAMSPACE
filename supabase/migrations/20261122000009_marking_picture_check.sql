-- Phase 3A Task 8: staff check a confirmed page's marking picture before that page counts (Builder's call 7).
--
-- A page whose name band the server did not prove gets its marking picture only after staff accept it (a staff
-- confirmation or assignment: script_page_confirm_given). That picture did not exist when staff looked, so it is shown
-- to them once it is made: until an admin has looked at it and pressed "The name is hidden", a script that shows the
-- page is never verified. A page the server proved needs no check.
--
-- script_pages.marking_checked_path, marking_checked_by and marking_checked_at say which marking picture was checked,
-- by whom and when. A page needs a check (script_page_needs_marking_check) while staff confirmed it, it has a marking
-- picture and that picture is not the one checked: a picture made again (a remask writes every answer page of its file
-- to a new folder) is checked again. Task 7's triggers on marking_path stay as they are: a picture of a script being
-- marked still holds its pieces, and a picture made again for a script with staff waits for a check.
--
-- The pages a script waits on (script_pages_to_check): its current linked answer pages (an answer page by its own copy
-- page or by the slot the script shows it at, as Phase 2 verifies them; not refused) and a family's confirmed extra
-- pages, that need a check.
--
-- script_marking_checks_list (admins): the pages to check of the scripts not yet being marked (receiving, checking,
-- needs attention or verified), oldest first (since the page was last accepted or checked), at most 200. A page whose
-- file is being prepared or remasked is left out (its picture is about to change), and so is a page with an open
-- name_visible exception (it goes through "Hide the name" first).
-- script_page_marking_checked (admins): "The name is hidden", for the picture staff were shown (p_marking_path). Refused
-- with conflict: changed (the page has another marking picture now, or a rerun replaced it), pictures_updating (its
-- file is being prepared or remasked), name_visible (a name was reported on it and not hidden yet), not_needed (the page
-- needs no check). Sets the three columns, audits script_page_marking_checked and works out the page's scripts again.
-- Answers {ok, page_id, script_state} (the state of the script that shows the page).
-- script_page_marking_name_shows (admins, with a reason): "A name still shows": a name_visible exception for the page
-- ({"from": "staff_check"}), unless one is open, so it goes through "Hide the name" and is accepted again; audited
-- script_page_marking_name_shows with the reason. A script being marked that shows the page (the list was read before
-- the script was handed out) is first taken back from the markers (marking_script_take_back_as, with the reason).
--
-- Lock order: as Phase 2's page tools, the page's bookings (script_page_lock: advisory, in uuid order), then the page
-- row, then (script_evaluate) the hand-in and the script rows. "A name still shows" takes the locks of a script being
-- marked first, in the order of Ruling R9 (marking_script_lock: the exam's marking row, the booking, the script, its
-- pieces), then the page's bookings.
--
-- Changed, from its latest definition:
--   script_evaluate_at (20261120000072): a complete script with nothing open and a marking picture on every answer
--     page is verified only when none of its pages waits for a check (script_pages_to_check); otherwise it needs
--     attention. The pages are looked at only when everything else would make it verified.
-- Nothing else in it changed. Scripts verified before this migration that show a page waiting for a check are worked
-- out again at the end.

alter table public.script_pages
  add column marking_checked_path text,
  add column marking_checked_by uuid references public.profiles (id) on delete set null,
  add column marking_checked_at timestamptz;

-- ---------------------------------------------------------------------------------------------
-- Internal: whether a page's marking picture waits for staff to check it: staff confirmed the page (its name band was
-- not proved by the server), it has a marking picture, and that picture is not the one checked.
-- ---------------------------------------------------------------------------------------------
create function public.script_page_needs_marking_check(p_page uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select p.marking_path is not null and p.marking_path is distinct from p.marking_checked_path
                   from public.script_pages p where p.id = p_page), false)
     and public.script_page_confirm_given(p_page)
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the pages of a script whose marking picture waits for a check (see the header), current pages only, with
-- the copy page the script shows each at (null for an extra page). The script's links are read first, then its pages
-- by their ids (as 20261120000072); whether staff confirmed a page is asked only of the pages whose picture is not the
-- one checked, and the script's slot copy is worked out once, when one of them needs it.
-- ---------------------------------------------------------------------------------------------
create function public.script_pages_to_check(p_script uuid)
returns table (page_id uuid, copy_page int)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_x public.scripts%rowtype;
  v_ids uuid[];
  v_slots int[];
  v_r record;
  v_slot int;
  v_copy uuid;
  v_copy_page int;
  v_slot_copy uuid;
  v_slot_copy_known boolean := false;
begin
  select * into v_x from public.scripts s where s.id = p_script;
  if not found then
    return;
  end if;
  select coalesce(array_agg(l.page_id order by l.copy_page), '{}'), coalesce(array_agg(l.copy_page order by l.copy_page), '{}')
  into v_ids, v_slots
  from public.script_page_links l where l.script_id = v_x.id and l.version = v_x.version;
  if cardinality(v_ids) > 0 then
    for v_r in
      select p.id, p.copy_id, p.copy_page from public.script_pages p
      where p.id = any (v_ids) and p.replaced_at is null and p.marking_path is not null
        and p.marking_path is distinct from p.marking_checked_path
      order by p.id
    loop
      if not public.script_page_confirm_given(v_r.id) or public.script_page_refused(v_r.id) then
        continue;
      end if;
      v_slot := v_slots[array_position(v_ids, v_r.id)];
      v_copy := v_r.copy_id;
      v_copy_page := v_r.copy_page;
      if v_copy is null or v_copy_page is null then  -- a page with no code: the copy and page of the slot it is linked at
        select t.copy_id, t.copy_page into v_copy, v_copy_page from public.script_page_copy(v_r.id) t;
      end if;
      if not coalesce(public.script_page_is_answer(v_copy, v_copy_page), false) then
        if not v_slot_copy_known then
          v_slot_copy := public.script_slot_copy(v_x.id);
          v_slot_copy_known := true;
        end if;
        if not coalesce(public.script_page_is_answer(v_slot_copy, v_slot), false) then
          continue;
        end if;
      end if;
      page_id := v_r.id;
      copy_page := v_slot;
      return next;
    end loop;
  end if;
  -- A family's confirmed extra pages, looked for only when the booking has a submission that was handed in.
  if exists (select 1 from public.home_submissions hs
             where hs.booking_id = v_x.booking_id and hs.state not in ('draft', 'rejected')) then
    return query
      select xp.page_id, null::int from public.script_extra_pages(v_x.id) xp
      join public.script_pages p on p.id = xp.page_id
      where p.replaced_at is null and public.script_page_needs_marking_check(xp.page_id)
        and not public.script_page_refused(xp.page_id);
  end if;
end;
$$;

-- Internal: whether a file of the page (its own) has a prepare or remask job queued or running: its marking picture
-- is about to change.
create function public.script_page_pictures_updating(p_page uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.processing_jobs j
    where j.upload_id = (select p.upload_id from public.script_pages p where p.id = p_page)
      and j.kind in ('prepare', 'remask') and j.state in ('queued', 'running'))
$$;

-- ---------------------------------------------------------------------------------------------
-- script_evaluate_at: as 20261120000072, and a script that would be verified is not while a page it shows waits for
-- staff to check its marking picture (script_pages_to_check): it needs attention.
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
  v_unmarked boolean := false;
  v_unchecked boolean := false;
  v_links jsonb;
  v_ids uuid[];
  v_uploads uuid[];
  v_r record;
  v_slot_copy uuid;
  v_slot_copy_known boolean := false;
  v_copy uuid;
  v_copy_page int;
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

  -- The script's current links, {copy page: page id}, and the pages they show.
  select coalesce(jsonb_object_agg(l.copy_page::text, l.page_id), '{}'::jsonb) into v_links
  from public.script_page_links l where l.script_id = v_x.id and l.version = v_x.version;
  v_ids := array(select t.value::uuid from jsonb_each_text(v_links) t);

  v_busy := coalesce(v_sub_state = 'checking', false)
    or exists (select 1 from public.script_uploads u
               where u.state in ('queued', 'processing')
                 and (u.booking_id = v_x.booking_id
                      or u.submission_id in (select s.id from public.home_submissions s where s.booking_id = v_x.booking_id)));
  if not v_busy and cardinality(v_ids) > 0 then
    v_uploads := array(select distinct p.upload_id from public.script_pages p where p.id = any (v_ids));
    v_busy := exists (select 1 from public.script_uploads u where u.id = any (v_uploads) and u.state in ('queued', 'processing'));
  end if;
  v_open := exists (select 1 from public.script_exceptions e
                    where e.state = 'open'
                      and (e.script_id = v_x.id or (e.script_id is null and e.booking_id = v_x.booking_id)))
    or (cardinality(v_ids) > 0
        and exists (select 1 from public.script_exceptions e
                    where e.page_id = any (v_ids) and e.state = 'resolved'
                      and e.resolution in ('rejected', 'blank', 'set_aside', 'submission_rejected')));  -- script_page_refused
  -- An answer page it shows (a page staff refused aside), or a family's confirmed extra page, with no marking picture:
  -- markers could not see it, so the script is not verified (Ruling R32 d). An answer page is one by its own copy page
  -- or by the slot the script shows it at (Ruling R33).
  if cardinality(v_ids) > 0 then
    for v_r in
      select p.id, p.copy_id, p.copy_page from public.script_pages p
      where p.id = any (v_ids) and (p.marking_path is null or p.replaced_at is not null)
    loop
      if public.script_page_refused(v_r.id) then
        continue;
      end if;
      v_copy := v_r.copy_id;
      v_copy_page := v_r.copy_page;
      if v_copy is null or v_copy_page is null then  -- a page with no code: the copy and page of the slot it is linked at
        select t.copy_id, t.copy_page into v_copy, v_copy_page from public.script_page_copy(v_r.id) t;
      end if;
      if coalesce(public.script_page_is_answer(v_copy, v_copy_page), false) then
        v_unmarked := true;
        exit;
      end if;
      if not v_slot_copy_known then
        v_slot_copy := public.script_slot_copy(v_x.id);
        v_slot_copy_known := true;
      end if;
      if exists (select 1 from jsonb_each_text(v_links) t
                 where t.value = v_r.id::text and public.script_page_is_answer(v_slot_copy, t.key::int)) then
        v_unmarked := true;
        exit;
      end if;
    end loop;
  end if;
  if not v_unmarked
     and exists (select 1 from public.home_submissions hs
                 where hs.booking_id = v_x.booking_id and hs.state not in ('draft', 'rejected')) then
    v_unmarked := exists (select 1 from public.script_extra_pages(v_x.id) xp join public.script_pages p on p.id = xp.page_id
                          where p.marking_path is null);
  end if;
  -- A page staff accepted whose marking picture nobody has checked yet (Phase 3A Task 8): looked at only when the
  -- script would otherwise be verified.
  if not v_busy and v_complete and not v_open and not v_unmarked then
    v_unchecked := exists (select 1 from public.script_pages_to_check(v_x.id));
  end if;
  v_state := case
    when v_busy then 'checking'
    when v_complete and not v_open and not v_unmarked and not v_unchecked then 'verified'
    when v_complete and (v_unmarked or v_unchecked) then 'needs_attention'
    when v_x.source = 'centre' and not v_complete and not v_open then 'receiving'
    else 'needs_attention'
  end;

  if (v_x.state, v_x.complete, v_x.received_at) is distinct from (v_state, v_complete, v_received) then
    update public.scripts set state = v_state, complete = v_complete, received_at = v_received where id = v_x.id;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_marking_checks_list: the marking pictures staff check (see the header). Each item: {page_id, exam_id,
-- script_number, booking (script_booking_json: the candidate's name and index number, for staff), copy_page (the page
-- of the script, null for an extra page), full_path, marking_path}.
-- ---------------------------------------------------------------------------------------------
create function public.script_marking_checks_list(p_exam uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_items jsonb;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  with accepted as materialized (
    -- The pages staff confirmed or assigned whose current marking picture is not the one checked.
    select distinct p.id
    from public.script_exceptions e join public.script_pages p on p.id = e.page_id
    where e.state = 'resolved' and e.resolution in ('confirmed', 'assigned') and (p_exam is null or p.exam_id = p_exam)
      and p.replaced_at is null and p.marking_path is not null and p.marking_path is distinct from p.marking_checked_path
  ),
  pages as materialized (
    select a.id from accepted a
    where public.script_page_needs_marking_check(a.id)
      and not public.script_page_pictures_updating(a.id)
      and not exists (select 1 from public.script_exceptions v where v.page_id = a.id and v.kind = 'name_visible' and v.state = 'open')
  ),
  scripts as materialized (
    -- The scripts not yet being marked that may show them: those whose current version links them, and the home
    -- script of the hand-in they came with (an extra page).
    select s.id from public.scripts s
    where s.state in ('receiving', 'checking', 'needs_attention', 'verified')
      and s.id in (select l.script_id from pages pg
                   join public.script_page_links l on l.page_id = pg.id
                   join public.scripts x on x.id = l.script_id and x.version = l.version
                   union
                   select x.id from pages pg
                   join public.script_pages p on p.id = pg.id
                   join public.script_uploads u on u.id = p.upload_id
                   join public.home_submissions hs on hs.id = u.submission_id
                   join public.scripts x on x.booking_id = hs.booking_id)
  ),
  due as (
    select distinct on (t.page_id) sc.id as script_id, t.page_id, t.copy_page
    from scripts sc cross join lateral public.script_pages_to_check(sc.id) t
    where t.page_id in (select pg.id from pages pg)
    order by t.page_id, sc.id
  ),
  items as (
    select d.page_id, s.exam_id, s.number, s.booking_id, d.copy_page, p.full_path, p.marking_path,
      greatest((select max(e.resolved_at) from public.script_exceptions e
                where e.page_id = d.page_id and e.state = 'resolved' and e.resolution in ('confirmed', 'assigned')),
               p.marking_checked_at) as since
    from due d
    join public.scripts s on s.id = d.script_id
    join public.script_pages p on p.id = d.page_id
    order by 8 nulls first, d.page_id
    limit 200
  )
  select coalesce(jsonb_agg(jsonb_build_object('page_id', i.page_id, 'exam_id', i.exam_id, 'script_number', i.number,
           'booking', public.script_booking_json(i.booking_id), 'copy_page', i.copy_page, 'full_path', i.full_path,
           'marking_path', i.marking_path) order by i.since nulls first, i.page_id), '[]'::jsonb)
  into v_items
  from items i;
  return jsonb_build_object('ok', true, 'items', v_items);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_page_marking_checked: "The name is hidden" (see the header). Refused also: forbidden, invalid_input (no page,
-- or no picture named), not_found.
-- ---------------------------------------------------------------------------------------------
create function public.script_page_marking_checked(p_page uuid, p_marking_path text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_bookings uuid[];
  v_p public.script_pages%rowtype;
  v_s uuid;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_page is null or nullif(btrim(coalesce(p_marking_path, '')), '') is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if not exists (select 1 from public.script_pages p where p.id = p_page) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  v_bookings := public.script_page_lock(p_page, public.script_page_owners(p_page));
  if v_bookings is null then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'changed');
  end if;
  select * into v_p from public.script_pages p where p.id = p_page;
  if v_p.replaced_at is not null or v_p.marking_path is distinct from p_marking_path then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'changed');
  end if;
  if public.script_page_pictures_updating(v_p.id) then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'pictures_updating');
  end if;
  if exists (select 1 from public.script_exceptions e where e.page_id = v_p.id and e.kind = 'name_visible' and e.state = 'open') then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'name_visible');
  end if;
  if not public.script_page_needs_marking_check(v_p.id) then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'not_needed');
  end if;

  update public.script_pages
  set marking_checked_path = v_p.marking_path, marking_checked_by = v_actor, marking_checked_at = now()
  where id = v_p.id;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'script_page_marking_checked', 'script_page', v_p.id);
  for v_s in select s.id from public.scripts s where s.booking_id = any (v_bookings) order by s.booking_id loop
    perform public.script_evaluate(v_s);
  end loop;
  return jsonb_build_object('ok', true, 'page_id', v_p.id, 'script_state', (
    select s.state from public.scripts s
    where s.booking_id = any (v_bookings)
    order by exists (select 1 from public.script_page_links l where l.script_id = s.id and l.version = s.version and l.page_id = v_p.id) desc,
             s.id
    limit 1));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_page_marking_name_shows: "A name still shows" (see the header). Refused also: forbidden, invalid_input (no
-- page), reason_required, not_found, conflict with reason changed (a rerun replaced the page). Answers {ok,
-- exception_id}.
-- ---------------------------------------------------------------------------------------------
create function public.script_page_marking_name_shows(p_page uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_bookings uuid[];
  v_p public.script_pages%rowtype;
  v_s uuid;
  v_booking uuid;
  v_script uuid;
  v_e uuid;
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
  if not exists (select 1 from public.script_pages p where p.id = p_page) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  -- A script being marked that shows the page is taken back below: its locks come first (Ruling R9).
  for v_s in
    select s.id from public.scripts s
    where s.booking_id = any (public.script_page_owners(p_page))
      and s.state in ('ready_to_mark', 'marking', 'marked') and s.taken_back_at is null
    order by s.id
  loop
    perform public.marking_script_lock(v_s);
  end loop;
  v_bookings := public.script_page_lock(p_page, public.script_page_owners(p_page));
  if v_bookings is null then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'changed');
  end if;
  select * into v_p from public.script_pages p where p.id = p_page;
  if v_p.replaced_at is not null then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'changed');
  end if;

  -- The booking and script the exception is about, as script_page_marking_lost finds them: the script whose current
  -- version shows the page, else the page's booking (a family's extra page: its family's booking) and its script.
  select s.booking_id, s.id into v_booking, v_script
  from public.script_page_links l join public.scripts s on s.id = l.script_id and l.version = s.version
  where l.page_id = v_p.id order by s.id limit 1;
  if v_booking is null then
    v_booking := coalesce(v_p.booking_id, (select hs.booking_id from public.script_uploads u
                                           join public.home_submissions hs on hs.id = u.submission_id where u.id = v_p.upload_id));
    select x.id into v_script from public.scripts x where x.booking_id = v_booking;
  end if;
  select e.id into v_e from public.script_exceptions e
  where e.page_id = v_p.id and e.kind = 'name_visible' and e.state = 'open' order by e.created_at, e.id limit 1;
  if v_e is null then
    insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details)
    values (v_p.exam_id, 'name_visible', v_booking, v_script, v_p.id, v_p.upload_id, '{"from": "staff_check"}'::jsonb)
    returning id into v_e;
  end if;

  -- A script being marked that shows the page to markers goes back to staff now (its locks are held; one that came to
  -- be marked meanwhile has them taken here).
  for v_s in
    select s.id from public.scripts s
    where s.booking_id = any (v_bookings) and s.state in ('ready_to_mark', 'marking', 'marked') and s.taken_back_at is null
      and exists (select 1 from public.marking_script_pages(s.id) x where x.page_id = v_p.id)
    order by s.id
  loop
    perform public.marking_script_lock(v_s);
    perform public.marking_script_take_back_as(v_s, v_actor, v_reason);
  end loop;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'script_page_marking_name_shows', 'script_page', v_p.id, v_reason);
  for v_s in select s.id from public.scripts s where s.booking_id = any (v_bookings) order by s.booking_id loop
    perform public.script_evaluate(v_s);
  end loop;
  return jsonb_build_object('ok', true, 'exception_id', v_e);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Access: the three staff functions check for an admin; the helpers are internal. script_evaluate_at keeps its
-- privileges (internal, as 20261120000058).
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.script_page_needs_marking_check(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_pages_to_check(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_pictures_updating(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_marking_checks_list(uuid) from public, anon;
revoke execute on function public.script_page_marking_checked(uuid, text) from public, anon;
revoke execute on function public.script_page_marking_name_shows(uuid, text) from public, anon;
grant execute on function public.script_marking_checks_list(uuid) to authenticated;
grant execute on function public.script_page_marking_checked(uuid, text) to authenticated;
grant execute on function public.script_page_marking_name_shows(uuid, text) to authenticated;

-- Scripts verified before this rule that show a page waiting for a check need attention until it is checked.
select public.script_evaluate(s.id) from public.scripts s
where s.state = 'verified' and exists (select 1 from public.script_pages_to_check(s.id));
