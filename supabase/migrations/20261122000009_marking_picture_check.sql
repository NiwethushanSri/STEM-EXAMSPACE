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
-- script_marking_checks_list (admins): the pages to check of the scripts before or in marking (receiving, checking,
-- needs attention, verified, ready to mark, being marked, marked), oldest first (since the page was last accepted or
-- checked), at most 200, and more (whether there were others). A page whose file is being prepared or remasked is left
-- out (its picture is about to change), and so is a page with an open name_visible exception (it goes through "Hide the
-- name" first). A script being marked is listed too: a paper area changed for it re-makes an accepted page's picture,
-- which holds its pieces (Task 7), and the lead may release them only once staff have checked it.
-- script_page_marking_checked (admins): "The name is hidden", for the picture staff were shown (p_marking_path). Refused
-- with conflict: changed (the page has another marking picture now, or a rerun replaced it), pictures_updating (its
-- file is being prepared or remasked), name_visible (a name was reported on it and not hidden yet), not_needed (the page
-- needs no check). Sets the three columns, audits script_page_marking_checked and works out the page's scripts again.
-- Answers {ok, page_id, script_state} (the state of the script that shows the page).
-- script_page_marking_name_shows (admins, with a reason): "A name still shows": a name_visible exception for the page
-- ({"from": "staff_check"}), unless one is open, so it goes through "Hide the name" and is accepted again; audited
-- script_page_marking_name_shows with the reason. A script being marked that shows the page is taken back from the
-- markers (marking_script_take_back_as, with the reason), and every marker with a live marking on it that is not set
-- aside may have seen the name: on every piece of the script their holds end, their markings in progress are set aside
-- and they are excluded (name_seen), as a marker's Name visible does for the marker; their submitted markings stand.
-- script_exception_check_due (admins): after a resolution, whether its page now waits for a check ('now', 'later' or
-- 'none'), for the note the exception queue shows.
--
-- Lock order: as Phase 2's page tools, the page's bookings (script_page_lock: advisory, in uuid order), then the page
-- row, then (script_evaluate) the hand-in and the script rows. "A name still shows" first takes the keys of the markers
-- with a live marking on a script being marked that shows the page (exclusive, in uuid order: Ruling R10), then that
-- script's locks in the order of Ruling R9 (marking_script_lock: the exam's marking row, the booking, the script, its
-- pieces), then the page's bookings, then the script's markings.
--
-- Changed, each from its latest definition:
--   script_evaluate_at (20261120000072): a complete script with nothing open and a marking picture on every answer
--     page is verified only when none of its pages waits for a check (script_pages_to_check); otherwise it needs
--     attention. The pages are looked at only when everything else would make it verified.
--   marking_alert_can_release (20261122000008): also not while a page of the script waits for a check
--     (picture_unchecked), so marking_alert_release, marking_alerts_release_all and marking_alerts_list's can_release
--     wait for it.
--   script_detail (20261122000008): the script also says pictures_to_check.
-- Nothing else in them changed. Scripts verified before this migration that show a page waiting for a check are worked
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
  v_more boolean;
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
    -- The scripts before or in marking that may show them: those whose current version links them, and the home
    -- script of the hand-in they came with (an extra page).
    select s.id from public.scripts s
    where s.state in ('receiving', 'checking', 'needs_attention', 'verified', 'ready_to_mark', 'marking', 'marked')
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
    limit 201
  ),
  numbered as (
    select i.*, row_number() over (order by i.since nulls first, i.page_id) as n from items i
  )
  select coalesce(jsonb_agg(jsonb_build_object('page_id', i.page_id, 'exam_id', i.exam_id, 'script_number', i.number,
           'booking', public.script_booking_json(i.booking_id), 'copy_page', i.copy_page, 'full_path', i.full_path,
           'marking_path', i.marking_path) order by i.n) filter (where i.n <= 200), '[]'::jsonb),
         count(*) > 200
  into v_items, v_more
  from numbered i;
  return jsonb_build_object('ok', true, 'items', v_items, 'more', v_more);
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
  v_owners uuid[];
  v_bookings uuid[];
  v_p public.script_pages%rowtype;
  v_s uuid;
  v_m uuid;
  v_markers uuid[];
  v_ended uuid[];
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
  v_owners := public.script_page_owners(p_page);
  -- A script being marked that shows the page is taken back below, and every marker who may have seen the page (a
  -- live marking on it, not set aside) is kept from it. Ruling R10: those markers' keys first, exclusive (exclusions
  -- are added), in uuid order; then (Ruling R9) the scripts' locks.
  for v_m in
    select distinct m.marker_id from public.scripts s
    join public.marking_units u on u.script_id = s.id
    join public.markings m on m.unit_id = u.id
    where s.booking_id = any (v_owners) and s.state in ('ready_to_mark', 'marking', 'marked') and s.taken_back_at is null
      and m.kind = 'live' and m.status <> 'set_aside'
    order by 1
  loop
    perform pg_advisory_xact_lock(hashtextextended('marker:' || v_m::text, 0));
  end loop;
  for v_s in
    select s.id from public.scripts s
    where s.booking_id = any (v_owners) and s.state in ('ready_to_mark', 'marking', 'marked') and s.taken_back_at is null
    order by s.id
  loop
    perform public.marking_script_lock(v_s);
  end loop;
  v_bookings := public.script_page_lock(p_page, v_owners);
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
  -- be marked meanwhile has them taken here). Every marker with a live marking on it that is not set aside may have
  -- seen the name, as with a marker's Name visible: on every piece of the script their holds end (name_seen), their
  -- markings in progress are set aside (name_seen), the pieces they no longer hold are open, and Next script never
  -- offers them a piece of it again (an exclusion). Their submitted markings stand.
  for v_s in
    select s.id from public.scripts s
    where s.booking_id = any (v_bookings) and s.state in ('ready_to_mark', 'marking', 'marked') and s.taken_back_at is null
      and exists (select 1 from public.marking_script_pages(s.id) x where x.page_id = v_p.id)
    order by s.id
  loop
    perform public.marking_script_lock(v_s);
    perform 1 from public.markings m
    where m.kind = 'live' and m.unit_id in (select u.id from public.marking_units u where u.script_id = v_s)
    order by m.id
    for update;
    v_markers := array(
      select distinct m.marker_id from public.markings m
      where m.kind = 'live' and m.status <> 'set_aside'
        and m.unit_id in (select u.id from public.marking_units u where u.script_id = v_s)
      order by 1);
    foreach v_m in array v_markers loop  -- held already, unless their marking began meanwhile
      perform pg_advisory_xact_lock(hashtextextended('marker:' || v_m::text, 0));
    end loop;
    with ended as (
      update public.marking_assignments a set ended_at = now(), end_reason = 'name_seen'
      where a.kind = 'live' and a.marker_id = any (v_markers) and a.ended_at is null
        and a.unit_id in (select u.id from public.marking_units u where u.script_id = v_s)
      returning a.unit_id
    )
    select coalesce(array_agg(e.unit_id), '{}') into v_ended from ended e;
    update public.markings m set status = 'set_aside', set_aside_at = now(), set_aside_reason = 'name_seen'
    where m.kind = 'live' and m.marker_id = any (v_markers) and m.status = 'in_progress'
      and m.unit_id in (select u.id from public.marking_units u where u.script_id = v_s);
    update public.marking_units u set state = 'open' where u.id = any (v_ended) and u.state <> 'open';
    insert into public.marking_unit_exclusions (unit_id, marker_id, reason)
    select u.id, mk, 'name_seen' from public.marking_units u cross join unnest(v_markers) mk where u.script_id = v_s
    on conflict do nothing;
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
-- marking_alert_can_release: as 20261122000008, and also not while a page of the script waits for staff to check its
-- marking picture (picture_unchecked): a picture made again for a page staff accepted (a paper area changed while the
-- script is being marked) is checked under "Marking pictures to check" before the lead releases the holds.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_alert_can_release(p_script uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when exists (select 1 from public.scripts s where s.id = p_script and s.taken_back_at is not null) then 'taken_back'
    when public.marking_script_busy(p_script) then 'pictures_updating'
    when exists (select 1 from public.marking_script_pages(p_script) x where x.marking_path is null) then 'picture_missing'
    when exists (select 1 from public.script_pages_to_check(p_script)) then 'picture_unchecked'
  end
$$;

-- ---------------------------------------------------------------------------------------------
-- script_detail: as 20261122000008, and the script also says pictures_to_check (how many of its pages wait for staff to
-- check their marking picture: script_pages_to_check).
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_detail(p_script uuid)
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
      'taken_back_at', v_x.taken_back_at, 'taken_back_reason', v_x.taken_back_reason,
      'pictures_to_check', (select count(*)::int from public.script_pages_to_check(v_x.id)),
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
               'reprocess_refused', public.script_upload_reprocess_refused(u.id),
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
-- script_exception_check_due: after staff resolve an exception, whether its page now waits for staff to check its
-- marking picture, so the queue can say so. due: 'now' (its picture is there to check), 'later' (its picture is still
-- to be made: there is none, or its file is being prepared or remasked) or 'none' (no page; staff did not accept it;
-- markers never see it, such as a cover; or its picture is checked). Admins. Refused: forbidden, invalid_input,
-- not_found. Answers {ok, due}.
-- ---------------------------------------------------------------------------------------------
create function public.script_exception_check_due(p_exception uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_page uuid;
  v_p public.script_pages%rowtype;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exception is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select e.page_id into v_page from public.script_exceptions e where e.id = p_exception;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select * into v_p from public.script_pages p where p.id = v_page;
  if v_p.id is null or v_p.replaced_at is not null or not public.script_page_confirm_given(v_p.id)
     or not exists (select 1 from public.scripts s cross join lateral public.marking_script_pages(s.id) x
                    where s.booking_id = any (public.script_page_owners(v_p.id)) and x.page_id = v_p.id) then
    return jsonb_build_object('ok', true, 'due', 'none');
  end if;
  return jsonb_build_object('ok', true, 'due', case
    when v_p.marking_path is null or public.script_page_pictures_updating(v_p.id) then 'later'
    when public.script_page_needs_marking_check(v_p.id) then 'now'
    else 'none'
  end);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Access: the four staff functions check for an admin; the helpers are internal. script_evaluate_at,
-- marking_alert_can_release and script_detail keep their privileges.
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.script_page_needs_marking_check(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_pages_to_check(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_page_pictures_updating(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_marking_checks_list(uuid) from public, anon;
revoke execute on function public.script_page_marking_checked(uuid, text) from public, anon;
revoke execute on function public.script_page_marking_name_shows(uuid, text) from public, anon;
revoke execute on function public.script_exception_check_due(uuid) from public, anon;
grant execute on function public.script_marking_checks_list(uuid) to authenticated;
grant execute on function public.script_page_marking_checked(uuid, text) to authenticated;
grant execute on function public.script_page_marking_name_shows(uuid, text) to authenticated;
grant execute on function public.script_exception_check_due(uuid) to authenticated;

-- Scripts verified before this rule that show a page waiting for a check need attention until it is checked.
select public.script_evaluate(s.id) from public.scripts s
where s.state = 'verified' and exists (select 1 from public.script_pages_to_check(s.id));
