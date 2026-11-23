-- Phase 3B Task 0: Phase 3A's carry-overs. One holder per kind of pass, one pass per marker on a piece, and one
-- eligibility rule.
--
-- Holders. Only the live, second and re-mark passes keep one open holder per piece (marking_assignments_one_holder is
-- made again with that condition): a seeded or practice piece may be held by many markers at once. A marker holds a
-- piece once, whatever the kind (marking_assignments_one_per_marker), and has one marking standing on it, whatever the
-- kind (markings_one_pass_per_marker): nobody holds or marks two passes of one piece at once.
--
-- The rule. marking_units_allowed is the one rule for "this marker may be given this piece as this kind of pass",
-- whatever the piece's own state and holder. For live: the exam's marking is open and not closed and the marker is
-- approved for its subject (read once); the piece is not on hold; its script is ready to mark or being marked and was
-- not taken back; the marker has no declared conflict or tutor link with the candidate; for Next script only, they
-- did not see a name on it; and no marking of theirs of another kind stands on it. Other kinds allow nothing yet
-- (Tasks 3 and 5). The time rules that hold a script back (marking_script_blocked) stay where they were: the callers
-- read them once per script.
--
-- Changed, each from its latest definition (20261122000006):
--   marking_units_candidates: the rule's pieces (live, Next script) that are open and of the group. Same result as
--     before for every piece where no other pass of the marker stands.
--   marking_unit_blocked: after its own not_found, on_hold, marking_not_open, marking_closed and not_ready answers,
--     null exactly when the rule has a row for the piece; otherwise the first of not_approved, conflict_of_interest
--     and name_seen, else not_eligible (another pass of the marker stands on the piece).
-- Both "-- 3B" placeholders are gone. marking_units_free and marking_units_pick read marking_units_candidates and are
-- unchanged. Privileges are as they were (create or replace keeps them; restated below).

-- ---------------------------------------------------------------------------------------------
-- One holder per kind; one pass per marker.
-- ---------------------------------------------------------------------------------------------
drop index public.marking_assignments_one_holder;
-- Never two holders of a piece's live, second or re-mark pass. Seeded and practice passes may have many.
create unique index marking_assignments_one_holder on public.marking_assignments (unit_id, kind)
  where ended_at is null and kind in ('live', 'second', 'remark');
-- A marker holds a piece once, whatever the kind.
create unique index marking_assignments_one_per_marker on public.marking_assignments (unit_id, marker_id)
  where ended_at is null;
-- A marker has one pass on a piece, whatever its kind.
create unique index markings_one_pass_per_marker on public.markings (unit_id, marker_id)
  where status <> 'set_aside';

-- ---------------------------------------------------------------------------------------------
-- Internal: the one rule. The pieces of the exam (p_unit: that one only) that p_marker may be given as a p_kind pass,
-- whatever their own state and holder (see the header). p_next: for Next script (a name the marker saw stops it).
-- Each piece comes with its group and its script, for marking_script_blocked.
-- ---------------------------------------------------------------------------------------------
create function public.marking_units_allowed(p_exam uuid, p_marker uuid, p_kind public.marking_kind, p_next boolean,
  p_unit uuid default null)
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
  where p_kind = 'live'
    and u.exam_id = p_exam and (p_unit is null or u.id = p_unit)
    and not u.on_hold
    and s.state in ('ready_to_mark', 'marking') and s.taken_back_at is null
    -- Read once: the exam's marking is open and not closed, and the marker is approved for its subject.
    and exists (select 1 from public.exams e join public.exam_marking m on m.exam_id = e.id
                where e.id = p_exam and m.opened_at is not null and m.closed_at is null
                  and public.is_marker_for(p_marker, e.subject_id))
    -- marking_marker_blocked: a declared conflict or a tutor link.
    and not exists (select 1 from public.marker_conflicts c where c.marker_id = p_marker and c.student_id = b.student_id)
    and not exists (select 1 from public.tutor_students t where t.tutor_id = p_marker and t.student_id = b.student_id)
    and not (p_next and exists (select 1 from public.marking_unit_exclusions x where x.unit_id = u.id and x.marker_id = p_marker))
    -- One pass on a piece per marker: no marking of theirs of another kind stands on it.
    and not exists (select 1 from public.markings k
                    where k.unit_id = u.id and k.marker_id = p_marker and k.kind <> p_kind and k.status <> 'set_aside')
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: as 20261122000006, from the one rule: the pieces Next script may consider for p_marker (live), open and of
-- the group when given, all but what holds a script back. Each piece comes with its script, for
-- marking_script_blocked.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_units_candidates(p_exam uuid, p_group uuid, p_marker uuid)
returns table (unit_id uuid, group_id uuid, script_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select a.unit_id, a.group_id, a.script_id
  from public.marking_units_allowed(p_exam, p_marker, 'live', true) a
  join public.marking_units u on u.id = a.unit_id
  where u.state = 'open' and (p_group is null or a.group_id = p_group)
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: as 20261122000006, why the piece may not be handed to p_marker at p_now (null: it may), whatever its own
-- state and holder. The first of not_found, on_hold, marking_not_open, marking_closed and not_ready (its script is not
-- ready to mark or being marked, or something holds it back: marking_script_blocked); then null exactly when the one
-- rule (marking_units_allowed, live) has a row for the piece; otherwise the first of not_approved (is_marker_for the
-- exam's subject), conflict_of_interest (marking_marker_blocked) and, for Next script only (p_next), name_seen, else
-- not_eligible.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_unit_blocked(p_unit uuid, p_marker uuid, p_now timestamptz, p_next boolean)
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
  if exists (select 1 from public.marking_units_allowed(v_u.exam_id, p_marker, 'live', p_next, p_unit)) then
    return null;
  end if;
  -- Why not, in the order of 20261122000006.
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
  return 'not_eligible';
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Privileges: all three are internal.
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.marking_units_allowed(uuid, uuid, public.marking_kind, boolean, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_units_candidates(uuid, uuid, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_unit_blocked(uuid, uuid, timestamptz, boolean) from public, anon, authenticated, service_role;
