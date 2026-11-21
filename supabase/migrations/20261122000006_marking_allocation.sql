-- Phase 3A Task 5: handing pieces (marking units) to markers, holds, giving back, assigning and taking back, and what
-- is left per exam and per marker.
--
-- "Next script" (marking_next) first makes the exam's verified scripts ready (marking_exam_sync) and ends the holds
-- that ran out (marking_holds_expire). It then gives the marker, in this order: (1) a piece of the exam they hold,
-- oldest first, with its hold renewed; (2) a free piece on which their marking is in progress (their hold ran out and
-- nobody has taken it since), so they carry on with the same marking; (3) one free piece at random among those they may
-- mark, chosen with for update skip locked, so two markers pressing at the same moment never get the same piece. Each
-- step checks again that the piece may be handed to them now (marking_unit_blocked): it is not on hold; its script is
-- ready to mark or being marked and nothing holds it back (marking_script_blocked); the marker is approved for the
-- subject and not blocked for the candidate (a declared conflict or a tutor link); and, for Next script only, the
-- marker did not see a name on it (a piece an admin assigned is resumed all the same). A hold from Next script lasts 2
-- hours; a piece an admin assigns has no time limit. The same rule over a whole exam (marking_units_candidates, then
-- marking_script_blocked once per script) chooses step 3's piece and the next n an admin assigns (marking_units_pick),
-- and counts the pieces "left" on a marker's list (marking_units_free).
--
-- Taking a piece sets aside any other marker's marking in progress on it (set_aside_reason: how their hold ended), and
-- brings the taker's own earlier marking on it (in progress or set aside) back into progress: there is never a second
-- marking row for the same marker. Giving a piece back and taking it back set the marking aside too (as taking an
-- approval away and declaring a conflict do, 20261122000004), so a marking in progress on a free piece always means its
-- hold ran out, and Next script never hands a piece straight back to the marker who gave it back or had it taken back.
-- Nothing is deleted. Every hand-out, give-back, assignment and take-back writes an audit row (Builder's call 13); a
-- resumed hold does not.
--
-- A hold on a piece that is on hold does not run out: lifting the hold gives the piece back to its marker (Task 7).
-- Closing marking stops hand-out and giving back; an admin may still take pieces back.
--
-- Lock order (Ruling R9, as 20261122000005): the marker's advisory lock where taken (hashtextextended('marker:' ||
-- marker id, 0): shared by every hand-out to that marker, exclusive in marker_approve, marker_unapprove and
-- marker_conflict_set, so an approval taken away or a conflict declared meanwhile is seen), then the exams' marking rows
-- (for share), then the bookings' locks where taken (the sync), then the scripts' rows in id order (for no key update),
-- then the units, then assignments and markings. Next script, assigning the next n and the hold expiry take script, unit
-- and assignment rows with skip locked, after the exam's marking row and the sync's locks, so they never wait for a row
-- another transaction holds.
--
-- Changed: marking_tick, from its latest definition (20261122000005): after the syncs it also ends the holds that ran
-- out (marking_holds_expire). Nothing else in it changed.

-- ---------------------------------------------------------------------------------------------
-- Internal: why the piece may not be handed to p_marker at p_now (null: it may), whatever its own state and holder.
-- The first of not_found, on_hold, marking_not_open, marking_closed, not_ready (its script is not ready to mark or being
-- marked, or something holds it back: marking_script_blocked), not_approved (is_marker_for the exam's subject),
-- conflict_of_interest (marking_marker_blocked) and, for Next script only (p_next), name_seen.
-- ---------------------------------------------------------------------------------------------
create function public.marking_unit_blocked(p_unit uuid, p_marker uuid, p_now timestamptz, p_next boolean)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_u public.marking_units%rowtype;
  v_state public.script_state;
  v_student uuid;
  v_subject bigint;
  v_why text;
begin
  select * into v_u from public.marking_units u where u.id = p_unit;
  if not found then
    return 'not_found';
  end if;
  if v_u.on_hold then
    return 'on_hold';
  end if;
  select s.state, b.student_id into v_state, v_student
  from public.scripts s join public.bookings b on b.id = s.booking_id
  where s.id = v_u.script_id;
  v_why := public.marking_script_blocked(v_u.script_id, p_now);
  if v_why in ('marking_not_open', 'marking_closed') then
    return v_why;
  end if;
  if v_why is not null or v_state not in ('ready_to_mark', 'marking') then
    return 'not_ready';
  end if;
  select e.subject_id into v_subject from public.exams e where e.id = v_u.exam_id;
  if not public.is_marker_for(p_marker, v_subject) then
    return 'not_approved';
  end if;
  if public.marking_marker_blocked(p_marker, v_student) then
    return 'conflict_of_interest';
  end if;
  if p_next and exists (select 1 from public.marking_unit_exclusions x where x.unit_id = p_unit and x.marker_id = p_marker) then
    return 'name_seen';
  end if;
  -- 3B: not the marker of the unit's other pass.
  return null;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: marking_unit_blocked with p_next over a whole exam (of the group, when given), for its open pieces, in one
-- pass, all but what holds a script back. The exam's marking and the marker's approval are read once; the conflict,
-- tutor link and name seen are joins. Each piece comes with its script, for marking_script_blocked.
-- ---------------------------------------------------------------------------------------------
create function public.marking_units_candidates(p_exam uuid, p_group uuid, p_marker uuid)
returns table (unit_id uuid, group_id uuid, script_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select u.id, u.group_id, u.script_id
  from public.marking_units u
  join public.scripts s on s.id = u.script_id
  join public.bookings b on b.id = s.booking_id
  where u.exam_id = p_exam and u.state = 'open' and not u.on_hold
    and (p_group is null or u.group_id = p_group)
    and s.state in ('ready_to_mark', 'marking') and s.taken_back_at is null
    and exists (select 1 from public.exams e join public.exam_marking m on m.exam_id = e.id
                where e.id = p_exam and m.opened_at is not null and m.closed_at is null
                  and public.is_marker_for(p_marker, e.subject_id))
    -- marking_marker_blocked: a declared conflict or a tutor link.
    and not exists (select 1 from public.marker_conflicts c where c.marker_id = p_marker and c.student_id = b.student_id)
    and not exists (select 1 from public.tutor_students t where t.tutor_id = p_marker and t.student_id = b.student_id)
    and not exists (select 1 from public.marking_unit_exclusions x where x.unit_id = u.id and x.marker_id = p_marker)
    -- 3B: not the marker of the unit's other pass.
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the free pieces of the exam (of the group, when given) that Next script may hand to p_marker at p_now: the
-- candidates whose script nothing holds back, marking_script_blocked running once per script. The pieces left on a
-- marker's list. marking_units_pick reads the same two parts.
-- ---------------------------------------------------------------------------------------------
create function public.marking_units_free(p_exam uuid, p_group uuid, p_marker uuid, p_now timestamptz)
returns table (unit_id uuid, group_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  with pieces as materialized (
    select c.unit_id, c.group_id, c.script_id from public.marking_units_candidates(p_exam, p_group, p_marker) c
  ),
  scripts as materialized (
    select distinct p.script_id from pieces p
  ),
  ready as materialized (
    select x.script_id from scripts x where public.marking_script_blocked(x.script_id, p_now) is null
  )
  select p.unit_id, p.group_id from pieces p where p.script_id in (select r.script_id from ready r)
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: up to p_count free pieces at random (step 3 of Next script, and the next n an admin assigns). The
-- candidates are read once, in random order; each script is checked once (marking_script_blocked), when one of its
-- pieces comes up; each piece is taken with its script's row and its own (Ruling R9), skip locked, so two markers never
-- get the same piece and nobody waits. The state of the piece and of its script are read again on the locked rows: a
-- change committed meanwhile (taken, taken back, on hold) leaves the piece out.
-- ---------------------------------------------------------------------------------------------
create function public.marking_units_pick(p_exam uuid, p_group uuid, p_marker uuid, p_now timestamptz, p_count int)
returns uuid[]
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_units uuid[] := '{}';
  v_ready uuid[] := '{}';
  v_held_back uuid[] := '{}';
  v_unit uuid;
  r record;
begin
  for r in
    select c.unit_id, c.script_id from public.marking_units_candidates(p_exam, p_group, p_marker) c order by random()
  loop
    exit when cardinality(v_units) >= p_count;
    continue when r.script_id = any (v_held_back);
    if not r.script_id = any (v_ready) then
      if public.marking_script_blocked(r.script_id, p_now) is null then
        v_ready := v_ready || r.script_id;
      else
        v_held_back := v_held_back || r.script_id;
        continue;
      end if;
    end if;
    select u.id into v_unit
    from public.marking_units u
    join public.scripts s on s.id = u.script_id
    where u.id = r.unit_id and u.state = 'open' and not u.on_hold
      and s.state in ('ready_to_mark', 'marking') and s.taken_back_at is null
    for no key update of s skip locked
    for update of u skip locked;
    if found then
      v_units := v_units || v_unit;
    end if;
  end loop;
  return v_units;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: p_marker takes the piece; the caller holds its script's row and its own. The piece is taken, with a live
-- assignment (how, by whom, until when: null is no time limit); any other marker's marking in progress on it is set
-- aside (set_aside_reason: how their assignment ended); the marker's own earlier marking on it, in progress or set
-- aside, is in progress again (never a second row); the script's state follows.
-- ---------------------------------------------------------------------------------------------
create function public.marking_unit_take(p_unit uuid, p_marker uuid, p_how text, p_by uuid, p_hold_until timestamptz)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_script uuid;
begin
  update public.marking_units u set state = 'taken' where u.id = p_unit returning u.script_id into v_script;
  insert into public.marking_assignments (unit_id, kind, marker_id, how, assigned_by, hold_until)
  values (p_unit, 'live', p_marker, p_how, p_by, p_hold_until);
  update public.markings m
  set status = 'set_aside', set_aside_at = now(),
    set_aside_reason = coalesce((
      select a.end_reason from public.marking_assignments a
      where a.unit_id = m.unit_id and a.kind = m.kind and a.marker_id = m.marker_id and a.ended_at is not null
      order by a.ended_at desc, a.created_at desc limit 1), 'released')
  where m.unit_id = p_unit and m.kind = 'live' and m.marker_id <> p_marker and m.status = 'in_progress';
  update public.markings m
  set status = 'in_progress', submitted_at = null, set_aside_at = null, set_aside_reason = null
  where m.unit_id = p_unit and m.kind = 'live' and m.marker_id = p_marker and m.status = 'set_aside';
  perform public.marking_script_state(v_script);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the piece's live pass is taken back; the caller holds its script's row and its own. Its open assignment
-- ends (taken_back), its marking in progress or submitted is set aside (taken_back), the piece is open and the
-- script's state follows (a marked script is being marked again). Nothing is deleted. False when there was nothing to
-- take back (a free piece with no marking in progress).
-- ---------------------------------------------------------------------------------------------
create function public.marking_unit_take_back(p_unit uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_u public.marking_units%rowtype;
begin
  select * into v_u from public.marking_units u where u.id = p_unit;
  if v_u.state = 'open' and not exists (
       select 1 from public.markings m where m.unit_id = p_unit and m.kind = 'live' and m.status in ('in_progress', 'submitted')) then
    return false;
  end if;
  update public.marking_units u set state = 'open' where u.id = p_unit;
  update public.marking_assignments a set ended_at = now(), end_reason = 'taken_back'
  where a.unit_id = p_unit and a.kind = 'live' and a.ended_at is null;
  update public.markings m set status = 'set_aside', set_aside_at = now(), set_aside_reason = 'taken_back'
  where m.unit_id = p_unit and m.kind = 'live' and m.status in ('in_progress', 'submitted');
  perform public.marking_script_state(v_u.script_id);
  return true;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: holds what a change of these pieces needs, in the order of Ruling R9: their exams' marking rows (for share,
-- so a close or a structure save waits), then their scripts' rows in id order, then the pieces' rows in id order.
-- ---------------------------------------------------------------------------------------------
create function public.marking_units_lock(p_units uuid[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform 1 from public.exam_marking m
  where m.exam_id in (select u.exam_id from public.marking_units u where u.id = any (p_units))
  order by m.exam_id
  for share;
  perform 1 from public.scripts s
  where s.id in (select u.script_id from public.marking_units u where u.id = any (p_units))
  order by s.id
  for no key update;
  perform 1 from public.marking_units u where u.id = any (p_units) order by u.id for update;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal (Next script and the minute job): every open assignment whose hold ran out before p_now ends (expired) and
-- its piece is open again. The marking stays in progress: the marker carries on with Next script while the piece is
-- free. A piece on hold keeps its holder. Rows another transaction holds are skipped (the next run ends them), so this
-- never waits. Returns how many ended.
-- ---------------------------------------------------------------------------------------------
create function public.marking_holds_expire(p_now timestamptz)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := public.paper_clock(p_now);
  v_ids uuid[] := '{}';
  v_units uuid[] := '{}';
  v_scripts uuid[] := '{}';
  v_id uuid;
  r record;
begin
  for r in
    select a.id, a.kind, a.unit_id, u.script_id
    from public.marking_assignments a
    join public.marking_units u on u.id = a.unit_id
    join public.scripts s on s.id = u.script_id
    where a.ended_at is null and a.hold_until < v_now and not u.on_hold
    order by s.id, u.id, a.id
    for no key update of s skip locked
    for update of u, a skip locked
  loop
    v_ids := v_ids || r.id;
    if r.kind = 'live' then
      v_units := v_units || r.unit_id;
    end if;
    v_scripts := v_scripts || r.script_id;
  end loop;
  update public.marking_units u set state = 'open' where u.id = any (v_units) and u.state = 'taken';
  update public.marking_assignments a set ended_at = now(), end_reason = 'expired' where a.id = any (v_ids);
  for v_id in select distinct x from unnest(v_scripts) x order by 1 loop
    perform public.marking_script_state(v_id);
  end loop;
  return cardinality(v_ids);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the exam is overdue at p_now: its marking deadline has passed, marking has not closed, and a piece of a
-- script still being marked (not withdrawn or void) is not submitted.
-- ---------------------------------------------------------------------------------------------
create function public.marking_exam_overdue(p_exam uuid, p_now timestamptz)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select m.deadline is not null and public.paper_clock(p_now) > m.deadline and m.closed_at is null
      and exists (select 1 from public.marking_units u join public.scripts s on s.id = u.script_id
                  where u.exam_id = p_exam and u.state <> 'submitted' and s.state not in ('withdrawn', 'void'))
    from public.exam_marking m where m.exam_id = p_exam), false)
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the minute job, as 20261122000005, and then the holds that ran out end (marking_holds_expire).
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_tick()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
begin
  for r in select m.exam_id from public.exam_marking m where m.opened_at is not null and m.closed_at is null order by m.exam_id loop
    perform public.marking_exam_sync(r.exam_id, null);
  end loop;
  perform public.marking_holds_expire(null);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_next: "Next script" for the signed-in marker (see the header). p_group is one of the exam's question groups,
-- or null for any piece. Returns {ok, unit_id, resumed} (resumed: a piece they held, or their marking in progress), or
-- {ok: false, code} with not_approved, marking_not_open, marking_closed or nothing_left (and invalid_input, not_found).
-- ---------------------------------------------------------------------------------------------
create function public.marking_next(p_exam uuid, p_group uuid default null, p_now timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := public.paper_clock(p_now);
  v_subject bigint;
  v_m public.exam_marking%rowtype;
  v_held uuid[];
  v_unit uuid;
  v_resumed boolean := true;
begin
  if p_exam is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  -- First of all the marker's lock (shared): an approval taken away or a conflict declared at this moment is seen.
  perform pg_advisory_xact_lock_shared(hashtextextended('marker:' || v_actor::text, 0));
  select e.subject_id into v_subject from public.exams e where e.id = p_exam;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if not public.is_marker_for(v_actor, v_subject) then
    return jsonb_build_object('ok', false, 'code', 'not_approved');
  end if;
  if p_group is not null and not exists (select 1 from public.question_groups g where g.id = p_group and g.exam_id = p_exam) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  -- The sync first (it holds the exam's marking row for share, so a close waits until this ends), then the hold
  -- expiry, which takes script rows only after that row and the sync's booking locks (Ruling R9).
  perform public.marking_exam_sync(p_exam, v_now);
  select * into v_m from public.exam_marking m where m.exam_id = p_exam for share;
  if v_m.opened_at is null then
    return jsonb_build_object('ok', false, 'code', 'marking_not_open');
  end if;
  if v_m.closed_at is not null then
    return jsonb_build_object('ok', false, 'code', 'marking_closed');
  end if;
  perform public.marking_holds_expire(v_now);

  -- (1) A piece of this exam the caller holds, oldest first, while it may still be handed to them: a name they saw
  -- stops a piece held by Next script, not one an admin assigned. Its hold is renewed on the locked rows; should
  -- another transaction hold them at this moment (their own save on another screen, say), the piece is resumed as it
  -- is rather than a second one handed out. (The caller's own pieces are found first, so the rule runs on those only.)
  with mine as materialized (
    select u.id, a.how, a.created_at, a.id as aid
    from public.marking_assignments a
    join public.marking_units u on u.id = a.unit_id
    where a.marker_id = v_actor and a.kind = 'live' and a.ended_at is null
      and (a.hold_until is null or a.hold_until >= v_now)
      and u.exam_id = p_exam and u.state = 'taken' and (p_group is null or u.group_id = p_group)
  )
  select array_agg(t.id order by t.created_at, t.aid) into v_held
  from mine t
  where public.marking_unit_blocked(t.id, v_actor, v_now, t.how = 'next') is null;
  if v_held is not null then
    select u.id into v_unit
    from public.marking_assignments a
    join public.marking_units u on u.id = a.unit_id
    join public.scripts s on s.id = u.script_id
    where u.id = any (v_held) and a.marker_id = v_actor and a.kind = 'live' and a.ended_at is null
      and u.state = 'taken' and not u.on_hold and s.state in ('ready_to_mark', 'marking') and s.taken_back_at is null
    order by a.created_at, a.id
    limit 1
    for no key update of s skip locked
    for update of u, a skip locked;
    if v_unit is null then
      return jsonb_build_object('ok', true, 'unit_id', v_held[1], 'resumed', true);
    end if;
    update public.marking_assignments a set hold_until = v_now + interval '2 hours'
    where a.unit_id = v_unit and a.kind = 'live' and a.ended_at is null and a.how = 'next';
    return jsonb_build_object('ok', true, 'unit_id', v_unit, 'resumed', true);
  end if;

  -- (2) A free piece of this exam on which the caller's marking is in progress: their hold ran out and nobody has
  -- taken it since. The caller's own markings are found first, so the rule runs on those only; the states are read
  -- again on the locked rows.
  with mine as materialized (
    select u.id, m.started_at, m.id as mid
    from public.markings m
    join public.marking_units u on u.id = m.unit_id
    where m.marker_id = v_actor and m.kind = 'live' and m.status = 'in_progress'
      and u.exam_id = p_exam and u.state = 'open' and not u.on_hold and (p_group is null or u.group_id = p_group)
  )
  select array_agg(t.id order by t.started_at, t.mid) into v_held
  from mine t
  where public.marking_unit_blocked(t.id, v_actor, v_now, true) is null;
  select u.id into v_unit
  from public.marking_units u
  join public.scripts s on s.id = u.script_id
  where u.id = any (coalesce(v_held, '{}')) and u.state = 'open' and not u.on_hold
    and s.state in ('ready_to_mark', 'marking') and s.taken_back_at is null
  order by array_position(v_held, u.id)
  limit 1
  for no key update of s skip locked
  for update of u skip locked;

  -- (3) One free piece at random.
  if v_unit is null then
    v_resumed := false;
    v_unit := (public.marking_units_pick(p_exam, p_group, v_actor, v_now, 1))[1];
    if v_unit is null then
      return jsonb_build_object('ok', false, 'code', 'nothing_left');
    end if;
  end if;

  perform public.marking_unit_take(v_unit, v_actor, 'next', null, v_now + interval '2 hours');
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'marking_unit_taken', 'marking_unit', v_unit);
  return jsonb_build_object('ok', true, 'unit_id', v_unit, 'resumed', v_resumed);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_give_back: the holder gives a piece back (or the marker whose hold on it ran out, while it is free): their
-- hold ends (given_back), the piece is open, and their marking in progress is set aside (given_back). The reason is
-- optional; given, it is 3 to 300 characters (invalid_input). Refused once marking has closed. Returns {ok}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_give_back(p_unit uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_u public.marking_units%rowtype;
  v_closed timestamptz;
  v_held boolean;
begin
  if p_unit is null or (btrim(coalesce(p_reason, '')) <> '' and v_reason is null) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_u from public.marking_units u where u.id = p_unit;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  -- Ruling R9: the exam's marking row, the script's row, then the piece's.
  select m.closed_at into v_closed from public.exam_marking m where m.exam_id = v_u.exam_id for share;
  perform 1 from public.scripts s where s.id = v_u.script_id for no key update;
  select * into v_u from public.marking_units u where u.id = p_unit for update;

  v_held := exists (select 1 from public.marking_assignments a
                    where a.unit_id = p_unit and a.kind = 'live' and a.ended_at is null and a.marker_id = v_actor);
  if not v_held and not (v_u.state = 'open' and exists (
       select 1 from public.markings m
       where m.unit_id = p_unit and m.kind = 'live' and m.marker_id = v_actor and m.status = 'in_progress')) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if v_closed is not null then
    return jsonb_build_object('ok', false, 'code', 'marking_closed');
  end if;

  if v_held then
    update public.marking_units u set state = 'open' where u.id = p_unit and u.state = 'taken';
    update public.marking_assignments a set ended_at = now(), end_reason = 'given_back'
    where a.unit_id = p_unit and a.kind = 'live' and a.ended_at is null;
  end if;
  update public.markings m set status = 'set_aside', set_aside_at = now(), set_aside_reason = 'given_back'
  where m.unit_id = p_unit and m.kind = 'live' and m.marker_id = v_actor and m.status = 'in_progress';
  perform public.marking_script_state(v_u.script_id);
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marking_given_back', 'marking_unit', p_unit, v_reason);
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_assign: an admin gives 1 to 200 pieces to a marker, with a reason, and no time limit. A piece must be open
-- and may be handed to that marker now (marking_unit_blocked; a name the marker saw does not stop an admin). The others
-- are skipped with their code: not_found, taken, submitted, on_hold, marking_not_open, marking_closed, not_ready,
-- not_approved, conflict_of_interest. Returns {ok, assigned, skipped: [{unit_id, code}]}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_assign(p_units uuid[], p_marker uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_units uuid[];
  v_why text;
  v_n int := 0;
  v_skipped jsonb := '[]';
  r record;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select coalesce(array_agg(distinct x), '{}') into v_units from unnest(coalesce(p_units, '{}')) x where x is not null;
  if p_marker is null or cardinality(v_units) not between 1 and 200 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;

  -- The marker's lock (shared) first: an approval taken away or a conflict declared at this moment is seen.
  perform pg_advisory_xact_lock_shared(hashtextextended('marker:' || p_marker::text, 0));
  perform public.marking_units_lock(v_units);
  for r in
    select x.id, u.state from unnest(v_units) x(id) left join public.marking_units u on u.id = x.id
    order by u.script_id, x.id
  loop
    v_why := case when r.state is null then 'not_found'
                  when r.state <> 'open' then r.state
                  else public.marking_unit_blocked(r.id, p_marker, null, false) end;
    if v_why is not null then
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('unit_id', r.id, 'code', v_why));
      continue;
    end if;
    perform public.marking_unit_take(r.id, p_marker, 'assigned', v_actor, null);
    insert into public.audit_log (actor_id, action, target_type, target_id, reason)
    values (v_actor, 'marking_assigned', 'marking_unit', r.id, v_reason);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'assigned', v_n, 'skipped', v_skipped);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_assign_some: an admin gives a marker the next p_count (1 to 200) pieces of the exam (of the group, when
-- given), chosen as Next script chooses them, with no time limit. Refused: not_approved, marking_not_open,
-- marking_closed. Returns {ok, assigned}: fewer when fewer are left.
-- ---------------------------------------------------------------------------------------------
create function public.marking_assign_some(p_exam uuid, p_group uuid, p_marker uuid, p_count int, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_subject bigint;
  v_m public.exam_marking%rowtype;
  v_unit uuid;
  v_n int := 0;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null or p_marker is null or p_count is null or p_count not between 1 and 200 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  -- The marker's lock (shared) first: an approval taken away or a conflict declared at this moment is seen.
  perform pg_advisory_xact_lock_shared(hashtextextended('marker:' || p_marker::text, 0));
  select e.subject_id into v_subject from public.exams e where e.id = p_exam;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if p_group is not null and not exists (select 1 from public.question_groups g where g.id = p_group and g.exam_id = p_exam) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if not public.is_marker_for(p_marker, v_subject) then
    return jsonb_build_object('ok', false, 'code', 'not_approved');
  end if;

  -- As Next script: the sync, the exam's marking row, then the hold expiry (Ruling R9).
  perform public.marking_exam_sync(p_exam, null);
  select * into v_m from public.exam_marking m where m.exam_id = p_exam for share;
  if v_m.opened_at is null then
    return jsonb_build_object('ok', false, 'code', 'marking_not_open');
  end if;
  if v_m.closed_at is not null then
    return jsonb_build_object('ok', false, 'code', 'marking_closed');
  end if;
  perform public.marking_holds_expire(null);

  -- Every piece is chosen in one pass, then each is taken.
  foreach v_unit in array public.marking_units_pick(p_exam, p_group, p_marker, null, p_count) loop
    perform public.marking_unit_take(v_unit, p_marker, 'assigned', v_actor, null);
    insert into public.audit_log (actor_id, action, target_type, target_id, reason)
    values (v_actor, 'marking_assigned', 'marking_unit', v_unit, v_reason);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'assigned', v_n);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_take_back: an admin takes back 1 to 200 pieces, with a reason (marking_unit_take_back): a held piece's hold
-- ends and its marking in progress is set aside; a submitted piece's marking is set aside and its script is being
-- marked again. Nothing is deleted. A free piece with nothing in progress is left as it is. Returns {ok, taken_back}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_take_back(p_units uuid[], p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_units uuid[];
  v_n int := 0;
  r record;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select coalesce(array_agg(distinct x), '{}') into v_units from unnest(coalesce(p_units, '{}')) x where x is not null;
  if cardinality(v_units) not between 1 and 200 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;

  perform public.marking_units_lock(v_units);
  for r in select u.id from public.marking_units u where u.id = any (v_units) order by u.script_id, u.id loop
    if public.marking_unit_take_back(r.id) then
      insert into public.audit_log (actor_id, action, target_type, target_id, reason)
      values (v_actor, 'marking_taken_back', 'marking_unit', r.id, v_reason);
      v_n := v_n + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'taken_back', v_n);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_reassign: for each of 1 to 200 pieces, in one transaction, marking_take_back then marking_assign to the
-- marker. A piece the marker may not be given (marking_assign's codes) is left exactly as it was: its take-back is
-- undone. Returns {ok, taken_back, assigned, skipped: [{unit_id, code}]}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_reassign(p_units uuid[], p_marker uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_units uuid[];
  v_back boolean;
  v_why text;
  v_taken int := 0;
  v_n int := 0;
  v_skipped jsonb := '[]';
  r record;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select coalesce(array_agg(distinct x), '{}') into v_units from unnest(coalesce(p_units, '{}')) x where x is not null;
  if p_marker is null or cardinality(v_units) not between 1 and 200 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;

  -- The marker's lock (shared) first: an approval taken away or a conflict declared at this moment is seen.
  perform pg_advisory_xact_lock_shared(hashtextextended('marker:' || p_marker::text, 0));
  perform public.marking_units_lock(v_units);
  for r in
    select x.id, u.id as unit_id from unnest(v_units) x(id) left join public.marking_units u on u.id = x.id
    order by u.script_id, x.id
  loop
    if r.unit_id is null then
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('unit_id', r.id, 'code', 'not_found'));
      continue;
    end if;
    begin
      v_back := public.marking_unit_take_back(r.id);
      v_why := public.marking_unit_blocked(r.id, p_marker, null, false);
      if v_why is not null then
        raise exception using errcode = 'P0001', message = v_why;
      end if;
      perform public.marking_unit_take(r.id, p_marker, 'assigned', v_actor, null);
      if v_back then
        insert into public.audit_log (actor_id, action, target_type, target_id, reason)
        values (v_actor, 'marking_taken_back', 'marking_unit', r.id, v_reason);
        v_taken := v_taken + 1;
      end if;
      insert into public.audit_log (actor_id, action, target_type, target_id, reason)
      values (v_actor, 'marking_assigned', 'marking_unit', r.id, v_reason);
      v_n := v_n + 1;
    exception when raise_exception then
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('unit_id', r.id, 'code', sqlerrm));
    end;
  end loop;
  return jsonb_build_object('ok', true, 'taken_back', v_taken, 'assigned', v_n, 'skipped', v_skipped);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_my_work: the signed-in marker's work. {ok, approved, lead_subjects: [subject ids], exams: [...], pieces:
-- [...]}. exams: those of a subject they are approved for whose marking is open, and any exam where they hold a piece
-- or have a marking in progress; per exam left counts the pieces Next script could give them now (per group too, when
-- marked by question), mine counts the pieces they hold and have submitted. pieces: what they hold, have in progress
-- and have submitted in those exams, with how they hold it (a hold that ran out shows its end). The index number is
-- shown; nothing names the candidate.
-- ---------------------------------------------------------------------------------------------
create function public.marking_my_work(p_now timestamptz default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := public.paper_clock(p_now);
  v_subjects bigint[];
  v_mine uuid[];
  v_exams uuid[];
begin
  select coalesce(array_agg(a.subject_id order by a.subject_id), '{}') into v_subjects
  from public.marker_approvals a where a.marker_id = v_actor and public.is_marker_for(v_actor, a.subject_id);
  if cardinality(v_subjects) = 0 then
    return jsonb_build_object('ok', true, 'approved', false, 'lead_subjects', '[]'::jsonb, 'exams', '[]'::jsonb, 'pieces', '[]'::jsonb);
  end if;

  select coalesce(array_agg(t.unit_id), '{}') into v_mine from (
    select a.unit_id from public.marking_assignments a where a.marker_id = v_actor and a.kind = 'live' and a.ended_at is null
    union
    select m.unit_id from public.markings m where m.marker_id = v_actor and m.kind = 'live' and m.status in ('in_progress', 'submitted')
  ) t;
  select coalesce(array_agg(e.id), '{}') into v_exams
  from public.exams e join public.exam_marking m on m.exam_id = e.id
  where m.opened_at is not null
    and ((m.closed_at is null and e.subject_id = any (v_subjects))
         or exists (select 1 from public.marking_units u where u.exam_id = e.id and u.id = any (v_mine)
                      and (exists (select 1 from public.marking_assignments a
                                   where a.unit_id = u.id and a.kind = 'live' and a.ended_at is null and a.marker_id = v_actor)
                           or exists (select 1 from public.markings x
                                      where x.unit_id = u.id and x.kind = 'live' and x.marker_id = v_actor and x.status = 'in_progress'))));

  return jsonb_build_object(
    'ok', true,
    'approved', true,
    'lead_subjects', coalesce((select jsonb_agg(s order by s) from unnest(v_subjects) s where public.is_lead_for(v_actor, s)), '[]'::jsonb),
    'exams', coalesce((
      select jsonb_agg(jsonb_build_object(
        'exam_id', e.id, 'title', e.title, 'paper', e.paper, 'subject', sj.name, 'mode', m.mode,
        'groups', case when m.mode = 'by_question' then coalesce((
            select jsonb_agg(jsonb_build_object('id', g.id, 'label', g.label,
              'left', (select count(*)::int from unnest(f.groups) x where x = g.id)) order by g.position)
            from public.question_groups g where g.exam_id = e.id), '[]'::jsonb) else '[]'::jsonb end,
        'deadline', m.deadline,
        'overdue', public.marking_exam_overdue(e.id, v_now),
        'closed', m.closed_at is not null,
        'left', coalesce(cardinality(f.groups), 0),
        'mine', jsonb_build_object(
          'taken', (select count(*)::int from public.marking_assignments a join public.marking_units u on u.id = a.unit_id
                    where u.exam_id = e.id and a.kind = 'live' and a.ended_at is null and a.marker_id = v_actor),
          'submitted', (select count(*)::int from public.markings x join public.marking_units u on u.id = x.unit_id
                        where u.exam_id = e.id and x.kind = 'live' and x.marker_id = v_actor and x.status = 'submitted')))
        order by e.starts_at, e.id)
      from public.exams e
      join public.exam_marking m on m.exam_id = e.id
      join public.subjects sj on sj.id = e.subject_id
      -- The pieces Next script could give the caller now (their groups), in one pass per exam.
      cross join lateral (select array_agg(x.group_id) as groups from public.marking_units_free(e.id, null, v_actor, v_now) x) f
      where e.id = any (v_exams)), '[]'::jsonb),
    'pieces', coalesce((
      select jsonb_agg(jsonb_build_object(
        'unit_id', u.id, 'exam_id', u.exam_id, 'script_number', s.number, 'index_number', d.index_number, 'group_label', g.label,
        'state', u.state, 'how', h.how, 'hold_until', h.hold_until, 'on_hold', u.on_hold, 'hold_reason', u.hold_reason,
        'pages_changed', coalesce(x.pages_changed_at is not null, false), 'last_saved_at', x.last_saved_at)
        order by u.exam_id, s.number, g.position nulls first, u.id)
      from public.marking_units u
      join public.scripts s on s.id = u.script_id
      join public.bookings b on b.id = s.booking_id
      left join public.student_details d on d.profile_id = b.student_id
      left join public.question_groups g on g.id = u.group_id
      left join public.markings x on x.unit_id = u.id and x.kind = 'live' and x.marker_id = v_actor
      left join lateral (
        select a.how, a.hold_until from public.marking_assignments a
        where a.unit_id = u.id and a.kind = 'live' and a.marker_id = v_actor
          and (a.ended_at is null or (x.status = 'in_progress' and u.state = 'open'))
        order by a.ended_at desc nulls first, a.created_at desc
        limit 1) h on true
      where u.id = any (v_mine) and u.exam_id = any (v_exams)), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_units_list: an exam's pieces, at most 2,000, for admins and the lead marker of its subject. p_state is open,
-- taken, submitted or on_hold; p_marker keeps the pieces that marker holds or has marked. Each: {unit_id, script_number,
-- index_number, source, group_label, state, on_hold, hold_reason, marker_id, marker_name (the holder, else the marker
-- of its marking in progress or submitted), how, hold_until, last_saved_at, submitted_at, total, waiting (what holds a
-- piece not yet submitted back: marking_script_blocked)}. No candidate name. A marker with no name on their account is
-- "Marker" and the first 8 characters of their id, never their email.
-- ---------------------------------------------------------------------------------------------
create function public.marking_units_list(p_exam uuid, p_state text default null, p_marker uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_admin boolean := public.is_staff_admin();
  v_subject bigint;
begin
  if not v_admin and not exists (select 1 from public.marker_approvals a where a.marker_id = v_actor and a.lead and public.is_lead_for(v_actor, a.subject_id)) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null or (p_state is not null and p_state not in ('open', 'taken', 'submitted', 'on_hold')) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select e.subject_id into v_subject from public.exams e where e.id = p_exam;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if not v_admin and not public.is_lead_for(v_actor, v_subject) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;

  return jsonb_build_object('ok', true, 'units', coalesce((
    -- What holds each script back, once per script with a piece not yet submitted.
    with held as materialized (
      select distinct u.script_id from public.marking_units u where u.exam_id = p_exam and u.state <> 'submitted'
    ),
    waiting as materialized (
      select h.script_id, public.marking_script_blocked(h.script_id, null) as why from held h
    )
    select jsonb_agg(t.j order by t.number, t.position nulls first, t.id)
    from (
      select u.id, s.number, g.position, jsonb_build_object(
        'unit_id', u.id, 'script_number', s.number, 'index_number', d.index_number, 'source', s.source, 'group_label', g.label,
        'state', u.state, 'on_hold', u.on_hold, 'hold_reason', u.hold_reason,
        'marker_id', p.id,
        'marker_name', case when p.id is not null then coalesce(nullif(btrim(p.first_name || ' ' || p.last_name), ''), 'Marker ' || left(p.id::text, 8)) end,
        'how', a.how, 'hold_until', a.hold_until, 'last_saved_at', x.last_saved_at, 'submitted_at', x.submitted_at, 'total', x.total,
        'waiting', case when u.state <> 'submitted' then w.why end) as j
      from public.marking_units u
      join public.scripts s on s.id = u.script_id
      left join waiting w on w.script_id = u.script_id
      join public.bookings b on b.id = s.booking_id
      left join public.student_details d on d.profile_id = b.student_id
      left join public.question_groups g on g.id = u.group_id
      left join public.marking_assignments a on a.unit_id = u.id and a.kind = 'live' and a.ended_at is null
      left join public.markings x on x.unit_id = u.id and x.kind = 'live' and x.status <> 'set_aside'
      left join public.profiles p on p.id = coalesce(a.marker_id, x.marker_id)
      where u.exam_id = p_exam
        and (p_state is null or (p_state = 'on_hold' and u.on_hold) or u.state = p_state)
        and (p_marker is null or coalesce(a.marker_id, x.marker_id) = p_marker)
      order by s.number, g.position nulls first, u.id
      limit 2000
    ) t), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_progress: what is left, per exam and per marker. Admins: every exam with marking settings (p_exam: that one);
-- a lead marker: the exams of the subjects they lead. Per exam: {exam_id, title, paper, subject, mode, deadline,
-- overdue (marking_exam_overdue), opened_at, closed_at, scripts: {waiting (verified, not yet ready), ready_to_mark,
-- marking, marked}, units: {open, taken, submitted (not on hold), on_hold} of scripts not withdrawn or void, markers:
-- [{marker_id, name, taken, submitted, last_saved_at}], alerts_open}. A marker's name is never their email (as
-- marking_units_list).
-- ---------------------------------------------------------------------------------------------
create function public.marking_progress(p_exam uuid default null, p_now timestamptz default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := public.paper_clock(p_now);
  v_admin boolean := public.is_staff_admin();
  v_subject bigint;
begin
  if not v_admin and not exists (select 1 from public.marker_approvals a where a.marker_id = v_actor and a.lead and public.is_lead_for(v_actor, a.subject_id)) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is not null then
    select e.subject_id into v_subject from public.exams e where e.id = p_exam;
    if not found then
      return jsonb_build_object('ok', false, 'code', 'not_found');
    end if;
    if not v_admin and not public.is_lead_for(v_actor, v_subject) then
      return jsonb_build_object('ok', false, 'code', 'forbidden');
    end if;
  end if;

  return jsonb_build_object('ok', true, 'exams', coalesce((
    select jsonb_agg(jsonb_build_object(
      'exam_id', e.id, 'title', e.title, 'paper', e.paper, 'subject', sj.name, 'mode', m.mode, 'deadline', m.deadline,
      'overdue', public.marking_exam_overdue(e.id, v_now), 'opened_at', m.opened_at, 'closed_at', m.closed_at,
      'scripts', (select jsonb_build_object(
                    'waiting', count(*) filter (where s.state = 'verified'),
                    'ready_to_mark', count(*) filter (where s.state = 'ready_to_mark'),
                    'marking', count(*) filter (where s.state = 'marking'),
                    'marked', count(*) filter (where s.state = 'marked'))
                  from public.scripts s where s.exam_id = e.id),
      'units', (select jsonb_build_object(
                  'open', count(*) filter (where not u.on_hold and u.state = 'open'),
                  'taken', count(*) filter (where not u.on_hold and u.state = 'taken'),
                  'submitted', count(*) filter (where not u.on_hold and u.state = 'submitted'),
                  'on_hold', count(*) filter (where u.on_hold))
                from public.marking_units u join public.scripts s on s.id = u.script_id
                where u.exam_id = e.id and s.state not in ('withdrawn', 'void')),
      'markers', coalesce((
        select jsonb_agg(jsonb_build_object('marker_id', k.marker_id, 'name', k.name, 'taken', k.taken, 'submitted', k.submitted,
                                            'last_saved_at', k.last_saved_at) order by k.name, k.marker_id)
        from (
          select w.marker_id,
            coalesce(nullif(btrim(p.first_name || ' ' || p.last_name), ''), 'Marker ' || left(p.id::text, 8)) as name,
            sum(w.taken)::int as taken, sum(w.submitted)::int as submitted, max(w.last_saved_at) as last_saved_at
          from (
            select a.marker_id, 1 as taken, 0 as submitted, null::timestamptz as last_saved_at
            from public.marking_assignments a join public.marking_units u on u.id = a.unit_id
            where u.exam_id = e.id and a.kind = 'live' and a.ended_at is null
            union all
            select x.marker_id, 0, (x.status = 'submitted')::int, x.last_saved_at
            from public.markings x join public.marking_units u on u.id = x.unit_id
            where u.exam_id = e.id and x.kind = 'live' and x.status <> 'set_aside'
          ) w
          join public.profiles p on p.id = w.marker_id
          group by w.marker_id, p.id, p.first_name, p.last_name
        ) k), '[]'::jsonb),
      'alerts_open', (select count(*)::int from public.marking_alerts al where al.exam_id = e.id and al.state = 'open'))
      order by e.starts_at, e.id)
    from public.exams e
    join public.exam_marking m on m.exam_id = e.id
    join public.subjects sj on sj.id = e.subject_id
    where (p_exam is null or e.id = p_exam) and (v_admin or public.is_lead_for(v_actor, e.subject_id))), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Privileges.
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.marking_unit_blocked(uuid, uuid, timestamptz, boolean) from public, anon, authenticated, service_role;
revoke execute on function public.marking_units_candidates(uuid, uuid, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_units_free(uuid, uuid, uuid, timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.marking_units_pick(uuid, uuid, uuid, timestamptz, int) from public, anon, authenticated, service_role;
revoke execute on function public.marking_unit_take(uuid, uuid, text, uuid, timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.marking_unit_take_back(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_units_lock(uuid[]) from public, anon, authenticated, service_role;
revoke execute on function public.marking_holds_expire(timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.marking_exam_overdue(uuid, timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.marking_tick() from public, anon, authenticated, service_role;
revoke execute on function public.marking_next(uuid, uuid, timestamptz) from public, anon;
revoke execute on function public.marking_give_back(uuid, text) from public, anon;
revoke execute on function public.marking_assign(uuid[], uuid, text) from public, anon;
revoke execute on function public.marking_assign_some(uuid, uuid, uuid, int, text) from public, anon;
revoke execute on function public.marking_take_back(uuid[], text) from public, anon;
revoke execute on function public.marking_reassign(uuid[], uuid, text) from public, anon;
revoke execute on function public.marking_my_work(timestamptz) from public, anon;
revoke execute on function public.marking_units_list(uuid, text, uuid) from public, anon;
revoke execute on function public.marking_progress(uuid, timestamptz) from public, anon;
grant execute on function public.marking_next(uuid, uuid, timestamptz) to authenticated;
grant execute on function public.marking_give_back(uuid, text) to authenticated;
grant execute on function public.marking_assign(uuid[], uuid, text) to authenticated;
grant execute on function public.marking_assign_some(uuid, uuid, uuid, int, text) to authenticated;
grant execute on function public.marking_take_back(uuid[], text) to authenticated;
grant execute on function public.marking_reassign(uuid[], uuid, text) to authenticated;
grant execute on function public.marking_my_work(timestamptz) to authenticated;
grant execute on function public.marking_units_list(uuid, text, uuid) to authenticated;
grant execute on function public.marking_progress(uuid, timestamptz) to authenticated;
