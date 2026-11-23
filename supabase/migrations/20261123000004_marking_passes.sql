-- Phase 3B Task 3: passes of any kind, and handing out second markings.
--
-- A marker has one pass on a piece (Task 0's indexes): their open assignment and their marking that is not set aside,
-- of one kind (marking_pass). The work functions find that pass instead of the live one, so a second marker opens,
-- saves, submits, gives back and reports a name as a first marker does, and is answered with the same keys: nothing
-- they are given says which pass it is. A first open makes the marking with the assignment's kind. A piece's own state
-- (marking_units.state) stays the live pass's: only a live pass changes it, and a script's state follows it as before.
-- A script that is checked (Task 4) is accepted wherever a marked one was.
--
-- A second marking is handed out blind, mixed in with the live pieces by Next script. A piece waits for one while its
-- check_state is waiting_second (Task 4 decides it). Its second pass may be given to a marker by the one rule
-- (marking_units_allowed, kind second): the common rule (marking open, the marker approved, the piece not on hold, the
-- script not taken back, no declared conflict or tutor link, one pass on the piece per marker), the script in marking,
-- marked or checked, nobody else holding the second pass and no second marking of another marker submitted. So the
-- first marker never is (they have a pass on the piece), and a marker who saw a name on the piece never is, by Next
-- script or by an admin. The second marker is shown the piece's pages, questions and mark scheme and none of the first
-- marker's marks, total, annotations or note (nor, for a lead marker, the first total in the list of pieces). A second
-- pass is freed as a live one is: when its hold runs out the marker's marking is kept and Next script gives it back to
-- them while nobody else has taken the pass; another marker who takes it has that marking set aside (expired); giving
-- it back, an admin taking it back, or the marker losing their approval or declaring a conflict sets it aside. None of
-- these touches the first marking or the piece's state. Admins assign and take back second passes as they do live ones.
--
-- The name-seen rules (Rulings R14, R15) and the picture check (R16, R17) hold for every kind of pass: "Name visible",
-- "A name still shows" and a hand-back with changed pages treat every marker with a marking of any kind on the script
-- as Phase 3A treats its live markers, and what holds a script back (marking_script_blocked) holds a second pass back.
--
-- Added (internal):
--   marking_pass(p_unit, p_marker): the marker's one pass on the piece.
--   marking_after_submit(p_marking), marking_after_change(p_marking): nothing yet (Tasks 4 and 5 replace them).
--     marking_submit calls the first (its answer is the submit's feedback), marking_save the second on a submitted
--     marking, while the script's and the piece's rows are held.
--   marking_units_offered(p_exam, p_group, p_marker, p_kinds): the pieces Next script may offer, of each kind asked.
-- Changed, each from its latest definition:
--   marking_units_allowed (20261123000001): kind second (above). Also, for every kind: a marker who holds an open
--     assignment of another kind on the piece is refused as one whose marking of another kind stands (controller note
--     a); and one piece (p_unit) is found by its key, not by a scan of the exam (two union all branches, note b).
--   marking_unit_blocked (20261123000001): takes p_kind (default live). For second, not_ready also when the script is
--     not being marked, marked or checked or the piece is not waiting for a second marking, and name_seen for an admin
--     too.
--   marking_units_free (20261122000006): the pieces of every kind Next script may offer (marking_units_offered), so a
--     marker's "left" counts second passes as Next script hands them out.
--   marking_units_pick (20261122000006): takes p_kinds (default live) and returns each piece with its kind; a second
--     pass is taken with its script's row and its own, skip locked, and read again under them.
--   marking_unit_take, marking_unit_take_back (20261122000006): take p_kind (default live). Another kind leaves the
--     piece's state, and the script's, alone.
--   marking_next (20261122000006): step 1 resumes a held piece of any kind and step 2 a marking of any kind in
--     progress on a free pass, each while the one rule of that kind allows it (step 2 tries each such marking in turn,
--     so one taken meanwhile leaves the next); step 3 picks live and second pieces.
--   marking_give_back (20261122000006), marking_my_work (20261122000006): the caller's pass of any kind. A piece of
--     marking_my_work says state taken while they hold it, submitted once their marking is (else open), and practice
--     (false until Task 5).
--   marking_assign (20261122000006): takes p_kind (live or second; invalid_input otherwise). A second pass is skipped
--     as taken while a marker holds it, and as submitted once a second marking is. Audited marking_second_assigned.
--   marking_assign_some (20261122000006): reads the new marking_units_pick, live only.
--   marking_take_back (20261122000006): takes p_kind (live or second). Audited marking_second_taken_back for second.
--   marking_units_list (20261122000015): each piece also says check_state and second: {marker_id, marker_name, state
--     (taken, open: their marking in progress with no hold, or submitted), how} or null; p_marker also keeps the pieces
--     whose second pass that marker holds or has marked. A lead holding a piece's second pass, or with their second
--     marking of it in progress, gets its total and submitted_at as null.
--   marking_work_blocked (20261122000007): the caller's pass of any kind (a marking of theirs set aside, with no pass,
--     is hold_expired as before); a checked script is accepted.
--   marking_unit_open (20261123000002): the caller's pass; marking also says practice (false) and sent_back_note.
--   marking_save, marking_submit (20261122000007): the caller's own marking of any kind. The submit no longer says
--     script_state (a seeded piece's script would give it away) and says feedback (marking_after_submit). A change after
--     submit calls marking_after_change.
--   marking_name_visible (20261122000008), script_page_marking_name_shows (20261122000009), marking_units_refresh
--     (20261122000008): every marker with a marking of any kind not set aside on the script, as the live ones. A live
--     pass that ends opens its piece; another kind does not. The refresh gives a submitted second marking back to its
--     marker as it does a live one. "Name visible" takes a checked script back as a marked one.
--   marking_script_hand_back (20261122000008): takes the keys of the markers of every kind of marking (the refresh may
--     give them a piece back, Ruling R10) and restarts their Next script holds of every kind.
--   marking_alert_release, marking_alerts_release_all (20261122000008): restart the Next script holds of every kind.
--   marking_script_waiting (20261122000009): a checked script waits for a picture check as a marked one does.
--   marking_script_blocked (20261122000005): for a marked or checked script it says what holds the script back, not
--     not_verified, so the picture check and the busy rule hold a second pass back. Its other callers read the
--     script's state themselves.
--   mark_scheme_path_allowed (20261122000013): a marker holding a piece, or with a marking on one, of any kind.
--   marker_unapprove, marker_conflict_set (20261122000004): the marker's markings in progress of the kind of each
--     assignment that ends are set aside, not only live ones.
-- Nothing else in them changed. Every changed function names a candidate no more than before.
--
-- Lock order (as 20261123000003): marker key -> exam_marking -> booking lock -> script rows in id order -> units in id
-- order -> assignments and markings. A second pass is held by its piece's row, as a live one: every hand-out of it holds
-- that row first, and reads the second pass again under it.

-- ---------------------------------------------------------------------------------------------
-- Internal: the marker's one pass on the piece: their open assignment and their marking that is not set aside (one of
-- each at most, Task 0's indexes), of the same kind. No row when they have neither.
-- ---------------------------------------------------------------------------------------------
create function public.marking_pass(p_unit uuid, p_marker uuid)
returns table (kind public.marking_kind, assignment_id uuid, how text, hold_until timestamptz, marking_id uuid, status text)
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(a.kind, m.kind), a.id, a.how, a.hold_until, m.id, m.status
  from (select x.id, x.kind, x.how, x.hold_until from public.marking_assignments x
        where x.unit_id = p_unit and x.marker_id = p_marker and x.ended_at is null) a
  full join (select k.id, k.kind, k.status from public.markings k
             where k.unit_id = p_unit and k.marker_id = p_marker and k.status <> 'set_aside') m on m.kind = a.kind
  order by a.id is null
  limit 1
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: what follows a submit (its answer is the submit's feedback) and a change after submit. Nothing yet: Tasks 4
-- and 5 replace them. The caller holds the script's and the piece's rows.
-- ---------------------------------------------------------------------------------------------
create function public.marking_after_submit(p_marking uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
begin
  return null;
end;
$$;

create function public.marking_after_change(p_marking uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  return;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: as 20261122000005, and a script being marked, marked or checked passes the first test: what holds a
-- second pass back is asked of a marked script too. Its other callers look at the script's state themselves.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_script_blocked(p_script uuid, p_now timestamptz)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_x public.scripts%rowtype;
  v_m public.exam_marking%rowtype;
begin
  select * into v_x from public.scripts s where s.id = p_script;
  if not found or v_x.state not in ('verified', 'ready_to_mark', 'marking', 'marked', 'checked') then
    return 'not_verified';
  end if;
  select * into v_m from public.exam_marking m where m.exam_id = v_x.exam_id;
  if v_m.opened_at is null then
    return 'marking_not_open';
  end if;
  if v_m.closed_at is not null then
    return 'marking_closed';
  end if;
  return public.marking_script_waiting(p_script, p_now);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: as 20261122000009, and a checked script waits for a picture check as a marked one does.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_script_waiting(p_script uuid, p_now timestamptz)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := public.paper_clock(p_now);
  v_x public.scripts%rowtype;
  v_e public.exams%rowtype;
begin
  select * into v_x from public.scripts s where s.id = p_script;
  if not found then
    return null;
  end if;
  if v_x.taken_back_at is not null then
    return 'taken_back';
  end if;
  if v_x.late and v_x.late_decision is distinct from 'accept' then
    return 'late_undecided';
  end if;
  if v_x.source = 'home' then
    select * into v_e from public.exams e where e.id = v_x.exam_id;
    if v_now < v_e.starts_at + v_e.duration_minutes * interval '1 minute' + interval '24 hours' then
      return 'home_window_open';
    end if;
  end if;
  if v_x.source = 'centre' and exists (
       select 1 from public.bookings b
       join public.scan_batches sb on sb.exam_id = v_x.exam_id and sb.centre_id = b.centre_id
       join public.script_uploads u on u.batch_id = sb.id
       join public.script_exceptions x on x.upload_id = u.id
       where b.id = v_x.booking_id and x.kind in ('no_code', 'unknown_code') and x.state = 'open') then
    return 'centre_pages_unsettled';
  end if;
  if public.marking_script_busy(p_script) then
    return 'pictures_updating';
  end if;
  if v_x.state in ('ready_to_mark', 'marking', 'marked', 'checked') then
    if exists (select 1 from public.script_pages_to_check(p_script)) then
      return 'picture_unchecked';
    end if;
  end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the one rule, as 20261123000001: the pieces of the exam (p_unit: that one only) that p_marker may be given
-- as a p_kind pass, whatever the piece's own state and its live holder. Each piece comes with its group and its script.
--   Every kind (live, second): the exam's marking is open and not closed and the marker is approved for its subject
--   (read once); the piece is not on hold; its script was not taken back; the marker has no declared conflict or tutor
--   link with the candidate; they hold no open assignment of another kind on it and no marking of theirs of another
--   kind stands on it (one pass per marker).
--   live: the script is ready to mark or being marked; for Next script only (p_next), they did not see a name on it.
--   second: the script is being marked, marked or checked; the piece waits for a second marking (check_state); nobody
--   else holds its second pass and no second marking of another marker is submitted on it (one in progress whose hold
--   ended is set aside when the pass is taken, as on a live piece); and they did not see a name on it, whoever hands it
--   out.
-- Other kinds allow nothing yet (Task 5). One piece is found by its key: the exam is scanned only when p_unit is null.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_units_allowed(p_exam uuid, p_marker uuid, p_kind public.marking_kind, p_next boolean,
  p_unit uuid default null)
returns table (unit_id uuid, group_id uuid, script_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select u.id, u.group_id, u.script_id
  from (
    select v.id, v.group_id, v.script_id, v.on_hold, v.check_state from public.marking_units v
    where p_unit is null and v.exam_id = p_exam
    union all
    select v.id, v.group_id, v.script_id, v.on_hold, v.check_state from public.marking_units v
    where v.id = p_unit and v.exam_id = p_exam
  ) u
  join public.scripts s on s.id = u.script_id
  join public.bookings b on b.id = s.booking_id
  where p_kind in ('live', 'second')
    and not u.on_hold
    and s.taken_back_at is null
    and case when p_kind = 'live' then s.state in ('ready_to_mark', 'marking')
             else s.state in ('marking', 'marked', 'checked') and u.check_state = 'waiting_second'
                  -- Nobody else has the second pass: no other holder, no other second marking submitted.
                  and not exists (select 1 from public.marking_assignments x
                                  where x.unit_id = u.id and x.kind = 'second' and x.ended_at is null and x.marker_id <> p_marker)
                  and not exists (select 1 from public.markings k
                                  where k.unit_id = u.id and k.kind = 'second' and k.marker_id <> p_marker
                                    and k.status = 'submitted') end
    -- Read once: the exam's marking is open and not closed, and the marker is approved for its subject.
    and exists (select 1 from public.exams e join public.exam_marking m on m.exam_id = e.id
                where e.id = p_exam and m.opened_at is not null and m.closed_at is null
                  and public.is_marker_for(p_marker, e.subject_id))
    -- marking_marker_blocked: a declared conflict or a tutor link.
    and not exists (select 1 from public.marker_conflicts c where c.marker_id = p_marker and c.student_id = b.student_id)
    and not exists (select 1 from public.tutor_students t where t.tutor_id = p_marker and t.student_id = b.student_id)
    -- A name they saw: Next script never offers the piece; nobody gives them its second pass.
    and not ((p_next or p_kind = 'second')
             and exists (select 1 from public.marking_unit_exclusions x where x.unit_id = u.id and x.marker_id = p_marker))
    -- One pass on a piece per marker: no marking of theirs of another kind stands on it, and they hold no other kind.
    and not exists (select 1 from public.markings k
                    where k.unit_id = u.id and k.marker_id = p_marker and k.kind <> p_kind and k.status <> 'set_aside')
    and not exists (select 1 from public.marking_assignments x
                    where x.unit_id = u.id and x.marker_id = p_marker and x.kind <> p_kind and x.ended_at is null)
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: as 20261123000001, with p_kind (live by default): why the piece may not be handed to p_marker at p_now as
-- that pass (null: it may), whatever its own state and holder. The first of not_found, on_hold, marking_not_open,
-- marking_closed and not_ready (its script is held back, marking_script_blocked; or, live, it is not ready to mark or
-- being marked; or, second, it is not being marked, marked or checked or the piece does not wait for a second
-- marking); then null exactly when the one rule (marking_units_allowed) has a row for the piece; otherwise the first
-- of not_approved, conflict_of_interest, name_seen (for Next script, and for a second pass always) and not_eligible.
-- ---------------------------------------------------------------------------------------------
drop function public.marking_unit_blocked(uuid, uuid, timestamptz, boolean);
create function public.marking_unit_blocked(p_unit uuid, p_marker uuid, p_now timestamptz, p_next boolean,
  p_kind public.marking_kind default 'live')
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
  if v_why is not null
     or (p_kind = 'live' and v_state not in ('ready_to_mark', 'marking'))
     or (p_kind = 'second' and (v_state not in ('marking', 'marked', 'checked') or v_u.check_state is distinct from 'waiting_second')) then
    return 'not_ready';
  end if;
  if exists (select 1 from public.marking_units_allowed(v_u.exam_id, p_marker, p_kind, p_next, p_unit)) then
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
  if (p_next or p_kind = 'second')
     and exists (select 1 from public.marking_unit_exclusions x where x.unit_id = p_unit and x.marker_id = p_marker) then
    return 'name_seen';
  end if;
  return 'not_eligible';
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the pieces of the exam (of the group, when given) that Next script may offer p_marker, each with the kind
-- of pass of p_kinds it would be, all but what holds a script back (marking_script_blocked, which the callers ask once
-- per script): live, an open piece of the one rule (marking_units_candidates); second, a piece of the one rule (second,
-- Next script) whose second pass nobody holds and nobody has submitted.
-- ---------------------------------------------------------------------------------------------
create function public.marking_units_offered(p_exam uuid, p_group uuid, p_marker uuid, p_kinds public.marking_kind[])
returns table (unit_id uuid, group_id uuid, script_id uuid, kind public.marking_kind)
language sql
stable
security definer
set search_path = ''
as $$
  select c.unit_id, c.group_id, c.script_id, 'live'::public.marking_kind
  from public.marking_units_candidates(p_exam, p_group, p_marker) c
  where 'live' = any (p_kinds)
  union all
  select a.unit_id, a.group_id, a.script_id, 'second'::public.marking_kind
  from public.marking_units_allowed(p_exam, p_marker, 'second', true) a
  where 'second' = any (p_kinds) and (p_group is null or a.group_id = p_group)
    and not exists (select 1 from public.marking_assignments x where x.unit_id = a.unit_id and x.kind = 'second' and x.ended_at is null)
    and not exists (select 1 from public.markings k where k.unit_id = a.unit_id and k.kind = 'second' and k.status = 'submitted')
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: as 20261122000006, from the pieces of every kind Next script may offer (marking_units_offered: live and
-- second): the free pieces of the exam (of the group, when given) that Next script may hand to p_marker at p_now, whose
-- script nothing holds back, marking_script_blocked running once per script. The pieces left on a marker's list.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_units_free(p_exam uuid, p_group uuid, p_marker uuid, p_now timestamptz)
returns table (unit_id uuid, group_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  with pieces as materialized (
    select distinct o.unit_id, o.group_id, o.script_id from public.marking_units_offered(p_exam, p_group, p_marker, '{live,second}') o
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
-- Internal: as 20261122000006, over the passes of p_kinds (live by default): up to p_count free pieces at random, each
-- with its kind (step 3 of Next script, and the next n an admin assigns). The offered pieces are read once, in one
-- random order over every kind; each script is checked once (marking_script_blocked), when one of its pieces comes
-- up; each piece is taken with its script's row and its own (Ruling R9), skip locked, so two markers never get the same
-- pass and nobody waits. The state of the piece and of its script are read again on the locked rows (a change committed
-- meanwhile leaves the piece out), and a second pass's holders and markings are read again once the piece is held. A
-- piece is returned once.
-- ---------------------------------------------------------------------------------------------
drop function public.marking_units_pick(uuid, uuid, uuid, timestamptz, int);
create function public.marking_units_pick(p_exam uuid, p_group uuid, p_marker uuid, p_now timestamptz, p_count int,
  p_kinds public.marking_kind[] default '{live}')
returns table (unit_id uuid, kind public.marking_kind)
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
    select o.unit_id as id, o.script_id as script, o.kind as pass
    from public.marking_units_offered(p_exam, p_group, p_marker, p_kinds) o
    order by random()
  loop
    exit when cardinality(v_units) >= p_count;
    continue when r.id = any (v_units) or r.script = any (v_held_back);
    if not r.script = any (v_ready) then
      if public.marking_script_blocked(r.script, p_now) is null then
        v_ready := v_ready || r.script;
      else
        v_held_back := v_held_back || r.script;
        continue;
      end if;
    end if;
    v_unit := null;
    if r.pass = 'live' then
      select u.id into v_unit
      from public.marking_units u
      join public.scripts s on s.id = u.script_id
      where u.id = r.id and u.state = 'open' and not u.on_hold
        and s.state in ('ready_to_mark', 'marking') and s.taken_back_at is null
      for no key update of s skip locked
      for update of u skip locked;
    else
      select u.id into v_unit
      from public.marking_units u
      join public.scripts s on s.id = u.script_id
      where u.id = r.id and not u.on_hold and u.check_state = 'waiting_second'
        and s.state in ('marking', 'marked', 'checked') and s.taken_back_at is null
      for no key update of s skip locked
      for update of u skip locked;
      -- Held now: nobody took the second pass or submitted it meanwhile.
      if v_unit is not null and (
           exists (select 1 from public.marking_assignments a where a.unit_id = v_unit and a.kind = r.pass and a.ended_at is null)
           or exists (select 1 from public.markings m where m.unit_id = v_unit and m.kind = r.pass and m.status = 'submitted')) then
        v_unit := null;
      end if;
    end if;
    if v_unit is not null then
      v_units := v_units || v_unit;
      unit_id := v_unit;
      kind := r.pass;
      return next;
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: as 20261122000006, with p_kind (live by default): p_marker takes the piece's p_kind pass; the caller holds
-- its script's row and its own. A p_kind assignment (how, by whom, until when: null is no time limit); any other
-- marker's marking of that kind in progress on it is set aside (set_aside_reason: how their assignment ended); the
-- marker's own earlier marking of that kind, in progress or set aside, is in progress again (never a second row). A
-- live pass also takes the piece, and the script's state follows; another kind leaves both alone.
-- ---------------------------------------------------------------------------------------------
drop function public.marking_unit_take(uuid, uuid, text, uuid, timestamptz);
create function public.marking_unit_take(p_unit uuid, p_marker uuid, p_how text, p_by uuid, p_hold_until timestamptz,
  p_kind public.marking_kind default 'live')
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_script uuid;
begin
  if p_kind = 'live' then
    update public.marking_units u set state = 'taken' where u.id = p_unit returning u.script_id into v_script;
  end if;
  insert into public.marking_assignments (unit_id, kind, marker_id, how, assigned_by, hold_until)
  values (p_unit, p_kind, p_marker, p_how, p_by, p_hold_until);
  update public.markings m
  set status = 'set_aside', set_aside_at = now(),
    set_aside_reason = coalesce((
      select a.end_reason from public.marking_assignments a
      where a.unit_id = m.unit_id and a.kind = m.kind and a.marker_id = m.marker_id and a.ended_at is not null
      order by a.ended_at desc, a.created_at desc limit 1), 'released')
  where m.unit_id = p_unit and m.kind = p_kind and m.marker_id <> p_marker and m.status = 'in_progress';
  update public.markings m
  set status = 'in_progress', submitted_at = null, set_aside_at = null, set_aside_reason = null
  where m.unit_id = p_unit and m.kind = p_kind and m.marker_id = p_marker and m.status = 'set_aside';
  if p_kind = 'live' then
    perform public.marking_script_state(v_script);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: as 20261122000006, with p_kind (live by default): the piece's p_kind pass is taken back; the caller holds
-- its script's row and its own. Its open assignment ends (taken_back) and its marking in progress or submitted is set
-- aside (taken_back). A live pass also opens the piece and the script's state follows (a marked script is being marked
-- again); another kind leaves both, and the other passes, alone. Nothing is deleted. False when there was nothing to
-- take back.
-- ---------------------------------------------------------------------------------------------
drop function public.marking_unit_take_back(uuid);
create function public.marking_unit_take_back(p_unit uuid, p_kind public.marking_kind default 'live')
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_u public.marking_units%rowtype;
begin
  select * into v_u from public.marking_units u where u.id = p_unit;
  if (p_kind <> 'live' or v_u.state = 'open')
     and not exists (select 1 from public.marking_assignments a where a.unit_id = p_unit and a.kind = p_kind and a.ended_at is null)
     and not exists (select 1 from public.markings m
                     where m.unit_id = p_unit and m.kind = p_kind and m.status in ('in_progress', 'submitted')) then
    return false;
  end if;
  if p_kind = 'live' then
    update public.marking_units u set state = 'open' where u.id = p_unit;
  end if;
  update public.marking_assignments a set ended_at = now(), end_reason = 'taken_back'
  where a.unit_id = p_unit and a.kind = p_kind and a.ended_at is null;
  update public.markings m set status = 'set_aside', set_aside_at = now(), set_aside_reason = 'taken_back'
  where m.unit_id = p_unit and m.kind = p_kind and m.status in ('in_progress', 'submitted');
  if p_kind = 'live' then
    perform public.marking_script_state(v_u.script_id);
  end if;
  return true;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_next: as 20261122000006, for every kind of pass. (1) A piece of this exam the caller holds, of any kind,
-- oldest first, while the one rule of that kind still allows it (a name they saw stops a piece held by Next script);
-- (2) a free pass of this exam on which their marking of that kind is in progress, while the rule allows it; (3) one
-- free piece at random among the live and second passes they may be given. Returns {ok, unit_id, resumed} whatever the
-- kind, or {ok: false, code} with not_approved, marking_not_open, marking_closed or nothing_left (and invalid_input,
-- not_found).
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_next(p_exam uuid, p_group uuid default null, p_now timestamptz default null)
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
  v_kinds public.marking_kind[];
  v_unit uuid;
  v_kind public.marking_kind;
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

  -- (1) A piece of this exam the caller holds, of any kind, oldest first, while it may still be handed to them as that
  -- pass: a name they saw stops a piece held by Next script, not one an admin assigned (a live one); a marking of
  -- another kind standing on it stops it too. Its hold is renewed on the locked rows; should another transaction hold
  -- them at this moment (their own save on another screen, say), the piece is resumed as it is rather than a second one
  -- handed out. (The caller's own pieces are found first, so the rule runs on those only.)
  with mine as materialized (
    select u.id, a.kind, a.how, a.created_at, a.id as aid
    from public.marking_assignments a
    join public.marking_units u on u.id = a.unit_id
    where a.marker_id = v_actor and a.ended_at is null
      and (a.hold_until is null or a.hold_until >= v_now)
      and u.exam_id = p_exam and (a.kind <> 'live' or u.state = 'taken') and (p_group is null or u.group_id = p_group)
  )
  select array_agg(t.id order by t.created_at, t.aid) into v_held
  from mine t
  where public.marking_unit_blocked(t.id, v_actor, v_now, t.how = 'next', t.kind) is null;
  if v_held is not null then
    select u.id into v_unit
    from public.marking_assignments a
    join public.marking_units u on u.id = a.unit_id
    join public.scripts s on s.id = u.script_id
    where u.id = any (v_held) and a.marker_id = v_actor and a.ended_at is null
      and not u.on_hold and s.taken_back_at is null
      and case when a.kind = 'live' then u.state = 'taken' and s.state in ('ready_to_mark', 'marking')
               else s.state in ('marking', 'marked', 'checked') end
    order by a.created_at, a.id
    limit 1
    for no key update of s skip locked
    for update of u, a skip locked;
    if v_unit is null then
      return jsonb_build_object('ok', true, 'unit_id', v_held[1], 'resumed', true);
    end if;
    update public.marking_assignments a set hold_until = v_now + interval '2 hours'
    where a.unit_id = v_unit and a.marker_id = v_actor and a.ended_at is null and a.how = 'next';
    return jsonb_build_object('ok', true, 'unit_id', v_unit, 'resumed', true);
  end if;

  -- (2) A free pass of this exam on which the caller's marking of that kind is in progress: their hold ran out and
  -- nobody has taken the pass since. The caller's own markings are found first, so the rule runs on those only. Each
  -- is tried in turn, oldest first: its states are read again on the locked rows, and a second pass's holder once the
  -- piece is held; one taken or locked meanwhile leaves the next to be tried.
  with mine as materialized (
    select u.id, m.kind, m.started_at, m.id as mid
    from public.markings m
    join public.marking_units u on u.id = m.unit_id
    where m.marker_id = v_actor and m.status = 'in_progress'
      and u.exam_id = p_exam and not u.on_hold and (p_group is null or u.group_id = p_group)
      and case when m.kind = 'live' then u.state = 'open'
               else not exists (select 1 from public.marking_assignments a where a.unit_id = u.id and a.kind = m.kind and a.ended_at is null) end
  )
  select array_agg(t.id order by t.started_at, t.mid), array_agg(t.kind order by t.started_at, t.mid) into v_held, v_kinds
  from mine t
  where public.marking_unit_blocked(t.id, v_actor, v_now, true, t.kind) is null;
  for i in 1 .. coalesce(cardinality(v_held), 0) loop
    v_kind := v_kinds[i];
    select u.id into v_unit
    from public.marking_units u
    join public.scripts s on s.id = u.script_id
    where u.id = v_held[i] and not u.on_hold and s.taken_back_at is null
      and case when v_kind = 'live' then u.state = 'open' and s.state in ('ready_to_mark', 'marking')
               else s.state in ('marking', 'marked', 'checked') end
    for no key update of s skip locked
    for update of u skip locked;
    if v_unit is not null and v_kind <> 'live'
       and exists (select 1 from public.marking_assignments a where a.unit_id = v_unit and a.kind = v_kind and a.ended_at is null) then
      v_unit := null;
    end if;
    exit when v_unit is not null;
  end loop;

  -- (3) One free piece at random, a live or a second pass.
  if v_unit is null then
    v_resumed := false;
    select p.unit_id, p.kind into v_unit, v_kind from public.marking_units_pick(p_exam, p_group, v_actor, v_now, 1, '{live,second}') p;
    if v_unit is null then
      return jsonb_build_object('ok', false, 'code', 'nothing_left');
    end if;
  end if;

  perform public.marking_unit_take(v_unit, v_actor, 'next', null, v_now + interval '2 hours', v_kind);
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'marking_unit_taken', 'marking_unit', v_unit);
  return jsonb_build_object('ok', true, 'unit_id', v_unit, 'resumed', v_resumed);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_give_back: as 20261122000006, for the caller's pass of any kind (marking_pass): the holder gives it back (or
-- the marker whose hold on it ran out, while nobody holds that pass): their hold ends (given_back), their marking in
-- progress is set aside (given_back), and a live piece is open again. Another kind leaves the piece, the script and the
-- first marking alone. The reason is optional; given, it is 3 to 300 characters (invalid_input). Refused once marking
-- has closed. Returns {ok}.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_give_back(p_unit uuid, p_reason text default null)
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
  v_p record;
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

  select * into v_p from public.marking_pass(p_unit, v_actor);
  v_held := v_p.assignment_id is not null;
  if not v_held and not (v_p.status is not distinct from 'in_progress' and not exists (
       select 1 from public.marking_assignments a where a.unit_id = p_unit and a.kind = v_p.kind and a.ended_at is null)) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if v_closed is not null then
    return jsonb_build_object('ok', false, 'code', 'marking_closed');
  end if;

  if v_held then
    if v_p.kind = 'live' then
      update public.marking_units u set state = 'open' where u.id = p_unit and u.state = 'taken';
    end if;
    update public.marking_assignments a set ended_at = now(), end_reason = 'given_back' where a.id = v_p.assignment_id;
  end if;
  update public.markings m set status = 'set_aside', set_aside_at = now(), set_aside_reason = 'given_back'
  where m.id = v_p.marking_id and m.status = 'in_progress';
  if v_p.kind = 'live' then
    perform public.marking_script_state(v_u.script_id);
  end if;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marking_given_back', 'marking_unit', p_unit, v_reason);
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_assign: as 20261122000006, with p_kind (live or second; invalid_input otherwise): an admin gives 1 to 200
-- pieces' p_kind pass to a marker, with a reason, and no time limit. A live pass must be open and may be handed to that
-- marker now (marking_unit_blocked; a name the marker saw does not stop an admin). A second pass must be free (taken
-- while a marker holds it; submitted once a second marking is submitted; a second marking in progress whose hold ended
-- is set aside, as on a live piece) and may be handed to the marker as a second pass (a name they saw does stop it).
-- The others are skipped with their code: not_found, taken, submitted, on_hold, marking_not_open, marking_closed,
-- not_ready, not_approved, conflict_of_interest, name_seen, not_eligible. Audited per piece: marking_assigned, or
-- marking_second_assigned.
-- Returns {ok, assigned, skipped: [{unit_id, code}]}.
-- ---------------------------------------------------------------------------------------------
drop function public.marking_assign(uuid[], uuid, text);
create function public.marking_assign(p_units uuid[], p_marker uuid, p_reason text, p_kind public.marking_kind default 'live')
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
  if p_marker is null or cardinality(v_units) not between 1 and 200 or p_kind is null or p_kind not in ('live', 'second') then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;

  -- The marker's lock (shared) first: an approval taken away or a conflict declared at this moment is seen.
  perform pg_advisory_xact_lock_shared(hashtextextended('marker:' || p_marker::text, 0));
  perform public.marking_units_lock(v_units);
  for r in
    select x.id, u.id as unit_id,
      case when p_kind = 'live' then u.state
           when exists (select 1 from public.marking_assignments a where a.unit_id = u.id and a.kind = p_kind and a.ended_at is null) then 'taken'
           when exists (select 1 from public.markings m where m.unit_id = u.id and m.kind = p_kind and m.status = 'submitted') then 'submitted'
           else 'open' end as state
    from unnest(v_units) x(id) left join public.marking_units u on u.id = x.id
    order by u.script_id, x.id
  loop
    v_why := case when r.unit_id is null then 'not_found'
                  when r.state <> 'open' then r.state
                  else public.marking_unit_blocked(r.id, p_marker, null, false, p_kind) end;
    if v_why is not null then
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('unit_id', r.id, 'code', v_why));
      continue;
    end if;
    perform public.marking_unit_take(r.id, p_marker, 'assigned', v_actor, null, p_kind);
    insert into public.audit_log (actor_id, action, target_type, target_id, reason)
    values (v_actor, case when p_kind = 'live' then 'marking_assigned' else 'marking_second_assigned' end, 'marking_unit', r.id, v_reason);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'assigned', v_n, 'skipped', v_skipped);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_assign_some: as 20261122000006 (live passes only), reading marking_units_pick as it is now.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_assign_some(p_exam uuid, p_group uuid, p_marker uuid, p_count int, p_reason text)
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
  for v_unit in select p.unit_id from public.marking_units_pick(p_exam, p_group, p_marker, null, p_count, '{live}') p loop
    perform public.marking_unit_take(v_unit, p_marker, 'assigned', v_actor, null);
    insert into public.audit_log (actor_id, action, target_type, target_id, reason)
    values (v_actor, 'marking_assigned', 'marking_unit', v_unit, v_reason);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'assigned', v_n);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_take_back: as 20261122000006, with p_kind (live or second; invalid_input otherwise): an admin takes back the
-- p_kind pass of 1 to 200 pieces, with a reason (marking_unit_take_back). A live pass: a held piece's hold ends and its
-- marking in progress is set aside; a submitted piece's marking is set aside and its script is being marked again. A
-- second pass: its hold ends and its marking is set aside; the first marking and the piece's state are left alone.
-- Nothing is deleted. A pass with nothing to take back is left as it is. Audited per piece: marking_taken_back, or
-- marking_second_taken_back. Returns {ok, taken_back}.
-- ---------------------------------------------------------------------------------------------
drop function public.marking_take_back(uuid[], text);
create function public.marking_take_back(p_units uuid[], p_reason text, p_kind public.marking_kind default 'live')
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
  if cardinality(v_units) not between 1 and 200 or p_kind is null or p_kind not in ('live', 'second') then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;

  perform public.marking_units_lock(v_units);
  for r in select u.id from public.marking_units u where u.id = any (v_units) order by u.script_id, u.id loop
    if public.marking_unit_take_back(r.id, p_kind) then
      insert into public.audit_log (actor_id, action, target_type, target_id, reason)
      values (v_actor, case when p_kind = 'live' then 'marking_taken_back' else 'marking_second_taken_back' end, 'marking_unit', r.id, v_reason);
      v_n := v_n + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'taken_back', v_n);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_my_work: as 20261122000006, for the caller's passes of every kind (marking_pass). {ok, approved,
-- lead_subjects: [subject ids], exams: [...], pieces: [...]}. exams: those of a subject they are approved for whose
-- marking is open, and any exam where they hold a piece or have a marking in progress; per exam left counts the pieces
-- Next script could give them now (per group too, when marked by question), mine counts the pieces they hold and have
-- submitted. pieces: what they hold, have in progress and have submitted in those exams, with state (their pass: taken
-- while they hold it, submitted once their marking is, else open), how they hold it (a hold that ran out shows its end)
-- and practice (false: Task 5). No key names the kind of pass. The index number is shown; nothing names the candidate.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_my_work(p_now timestamptz default null)
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
    select a.unit_id from public.marking_assignments a where a.marker_id = v_actor and a.ended_at is null
    union
    select m.unit_id from public.markings m where m.marker_id = v_actor and m.status in ('in_progress', 'submitted')
  ) t;
  select coalesce(array_agg(e.id), '{}') into v_exams
  from public.exams e join public.exam_marking m on m.exam_id = e.id
  where m.opened_at is not null
    and ((m.closed_at is null and e.subject_id = any (v_subjects))
         or exists (select 1 from public.marking_units u where u.exam_id = e.id and u.id = any (v_mine)
                      and (exists (select 1 from public.marking_assignments a
                                   where a.unit_id = u.id and a.ended_at is null and a.marker_id = v_actor)
                           or exists (select 1 from public.markings x
                                      where x.unit_id = u.id and x.marker_id = v_actor and x.status = 'in_progress'))));

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
                    where u.exam_id = e.id and a.ended_at is null and a.marker_id = v_actor),
          'submitted', (select count(*)::int from public.markings x join public.marking_units u on u.id = x.unit_id
                        where u.exam_id = e.id and x.marker_id = v_actor and x.status = 'submitted')))
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
        'state', case when p.assignment_id is not null then 'taken' when p.status = 'submitted' then 'submitted' else 'open' end,
        'how', h.how, 'hold_until', h.hold_until, 'on_hold', u.on_hold, 'hold_reason', u.hold_reason,
        'pages_changed', coalesce(x.pages_changed_at is not null, false), 'last_saved_at', x.last_saved_at,
        'practice', false)
        order by u.exam_id, s.number, g.position nulls first, u.id)
      from public.marking_units u
      join public.scripts s on s.id = u.script_id
      join public.bookings b on b.id = s.booking_id
      left join public.student_details d on d.profile_id = b.student_id
      left join public.question_groups g on g.id = u.group_id
      cross join lateral (select * from public.marking_pass(u.id, v_actor)) p
      left join public.markings x on x.id = p.marking_id
      left join lateral (
        select a.how, a.hold_until from public.marking_assignments a
        where a.unit_id = u.id and a.kind = p.kind and a.marker_id = v_actor
          and (a.ended_at is null or (p.assignment_id is null and p.status = 'in_progress'))
        order by a.ended_at desc nulls first, a.created_at desc
        limit 1) h on true
      where u.id = any (v_mine) and u.exam_id = any (v_exams)), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_units_list: as 20261122000015. Each piece also says check_state and second: who has its second pass and how
-- ({marker_id, marker_name, state: taken while they hold it, submitted once their second marking is, else open (their
-- marking in progress, no hold), how}, or null when nobody does). p_marker also keeps the pieces whose second pass that
-- marker holds or has marked. For admins and the subject's lead marker. A lead who holds a piece's second pass, or has
-- their second marking of it in progress, is given its total and submitted_at as null: a second marker never sees the
-- first total. Returns {ok, units, more}.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_units_list(p_exam uuid, p_state text default null, p_marker uuid default null)
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
  v_units jsonb;
  v_more boolean;
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

  -- What holds each script back, once per script with a piece not yet submitted.
  with held as materialized (
    select distinct u.script_id from public.marking_units u where u.exam_id = p_exam and u.state <> 'submitted'
  ),
  waiting as materialized (
    select h.script_id, public.marking_script_blocked(h.script_id, null) as why from held h
  ),
  found as materialized (
    select u.id, s.number, g.position, jsonb_build_object(
      'unit_id', u.id, 'script_number', s.number, 'index_number', d.index_number, 'source', s.source, 'group_label', g.label,
      'state', u.state, 'on_hold', u.on_hold, 'hold_reason', u.hold_reason,
      'marker_id', p.id,
      'marker_name', case when p.id is not null then coalesce(nullif(btrim(p.first_name || ' ' || p.last_name), ''), 'Marker ' || left(p.id::text, 8)) end,
      'how', a.how, 'hold_until', a.hold_until, 'last_saved_at', x.last_saved_at,
      -- A lead marking the piece's second pass (holding it, or with their second marking in progress) is not shown the
      -- first marking's total or when it was submitted.
      'submitted_at', case when not sm.blind then x.submitted_at end, 'total', case when not sm.blind then x.total end,
      'waiting', case when u.state <> 'submitted' then w.why end,
      'check_state', u.check_state,
      'second', case when p2.id is not null then jsonb_build_object(
        'marker_id', p2.id,
        'marker_name', coalesce(nullif(btrim(p2.first_name || ' ' || p2.last_name), ''), 'Marker ' || left(p2.id::text, 8)),
        'state', case when a2.id is not null then 'taken' when x2.status = 'submitted' then 'submitted' else 'open' end,
        'how', a2.how) end) as j
    from public.marking_units u
    join public.scripts s on s.id = u.script_id
    left join waiting w on w.script_id = u.script_id
    join public.bookings b on b.id = s.booking_id
    left join public.student_details d on d.profile_id = b.student_id
    left join public.question_groups g on g.id = u.group_id
    left join public.marking_assignments a on a.unit_id = u.id and a.kind = 'live' and a.ended_at is null
    left join public.markings x on x.unit_id = u.id and x.kind = 'live' and x.status <> 'set_aside'
    left join public.profiles p on p.id = coalesce(a.marker_id, x.marker_id)
    left join public.marking_assignments a2 on a2.unit_id = u.id and a2.kind = 'second' and a2.ended_at is null
    left join public.markings x2 on x2.unit_id = u.id and x2.kind = 'second' and x2.status <> 'set_aside'
    left join public.profiles p2 on p2.id = coalesce(a2.marker_id, x2.marker_id)
    cross join lateral (
      select not v_admin and (coalesce(a2.marker_id = v_actor, false)
                              or coalesce(x2.marker_id = v_actor and x2.status = 'in_progress', false)) as blind) sm
    where u.exam_id = p_exam
      and (p_state is null or (p_state = 'on_hold' and u.on_hold) or u.state = p_state)
      and (p_marker is null or coalesce(a.marker_id, x.marker_id) = p_marker or coalesce(a2.marker_id, x2.marker_id) = p_marker)
    order by s.number, g.position nulls first, u.id
    limit 2001  -- one more than is listed, to know whether there are more
  )
  select coalesce(jsonb_agg(t.j order by t.number, t.position nulls first, t.id), '[]'::jsonb), (select count(*) > 2000 from found)
  into v_units, v_more
  from (select * from found f order by f.number, f.position nulls first, f.id limit 2000) t;
  return jsonb_build_object('ok', true, 'units', v_units, 'more', v_more);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: as 20261122000007, for p_user's pass on the piece of any kind (marking_pass): why they may not work on it
-- at p_now (null: they may). The first of:
--   not_found;
--   forbidden: they neither hold it nor have a marking on it that is not set aside, and no marking of theirs on it was
--     set aside; or they are no longer approved for the subject (is_marker_for), or are now blocked for the candidate
--     (marking_marker_blocked);
--   on_hold;
--   hold_expired: their marking was set aside and they have no pass on it, or it is in progress and they hold the
--     piece no more or their hold ran out (a submitted marking needs no hold);
--   forbidden: the script is not ready to mark, being marked, marked or checked (or was taken back);
--   pictures_updating: a file holding its pages is being prepared or remasked (marking_script_busy);
--   marking_closed.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_work_blocked(p_unit uuid, p_user uuid, p_now timestamptz)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := public.paper_clock(p_now);
  v_u public.marking_units%rowtype;
  v_x public.scripts%rowtype;
  v_hold timestamptz;
  v_held boolean;
  v_status text;
  v_subject bigint;
  v_student uuid;
  v_m public.exam_marking%rowtype;
begin
  select * into v_u from public.marking_units u where u.id = p_unit;
  if not found then
    return 'not_found';
  end if;
  select p.assignment_id is not null, p.hold_until, p.status into v_held, v_hold, v_status
  from public.marking_pass(p_unit, p_user) p;
  v_held := coalesce(v_held, false);
  if not v_held and v_status is null then
    -- No pass: a marking of theirs set aside is told its hold ended, as before.
    select m.status into v_status from public.markings m where m.unit_id = p_unit and m.marker_id = p_user limit 1;
  end if;
  if not v_held and v_status is null then
    return 'forbidden';
  end if;
  select * into v_x from public.scripts s where s.id = v_u.script_id;
  select e.subject_id into v_subject from public.exams e where e.id = v_u.exam_id;
  select b.student_id into v_student from public.bookings b where b.id = v_x.booking_id;
  if not public.is_marker_for(p_user, v_subject) or public.marking_marker_blocked(p_user, v_student) then
    return 'forbidden';
  end if;
  if v_u.on_hold then
    return 'on_hold';
  end if;
  if v_status is not distinct from 'set_aside'
     or (v_status is distinct from 'submitted' and (not v_held or coalesce(v_hold < v_now, false))) then
    return 'hold_expired';
  end if;
  if v_x.state not in ('ready_to_mark', 'marking', 'marked', 'checked') or v_x.taken_back_at is not null then
    return 'forbidden';
  end if;
  if public.marking_script_busy(v_u.script_id) then
    return 'pictures_updating';
  end if;
  select * into v_m from public.exam_marking m where m.exam_id = v_u.exam_id;
  if v_m.opened_at is null or v_m.closed_at is not null then
    return 'marking_closed';
  end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_unit_open: as 20261123000002, for the caller's pass of any kind (marking_pass): the piece for its holder (the
-- first open makes their marking, of the kind of their assignment, with the pages key; a Next script hold is renewed to
-- 2 hours from now) or for the marker of its submitted marking (read only once marking has closed: unit.closed). The
-- marking also says practice (false until Task 5) and sent_back_note (the lead's note when the piece was sent back to
-- them). The answer has the same keys for every kind of pass, and carries only the caller's own marking: never another
-- marker's marks, total, annotations or note. Refusals (marking_work_blocked): invalid_input, not_found, forbidden,
-- on_hold, hold_expired, pictures_updating, marking_closed. Returns {ok, unit:{id, exam_title, paper, subject,
-- script_number, index_number, group_label, deadline, hold_until, closed}, marking:{id, rev, status, lead_note, total,
-- max_total, pages_changed, practice, sent_back_note}, structure:{version, questions, option_groups,
-- mark_scheme_file}, pages:[{n, page_id, copy_page, extra, rotation, has_picture}], marks:[{question_id, mark, na}],
-- annotations:[{id, page_id, kind, x, y, points, text, question_id}]}. Nothing in it names the candidate.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_unit_open(p_unit uuid, p_now timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := public.paper_clock(p_now);
  v_u public.marking_units%rowtype;
  v_x public.scripts%rowtype;
  v_e public.exams%rowtype;
  v_m public.exam_marking%rowtype;
  v_p record;
  v_a public.marking_assignments%rowtype;
  v_mk public.markings%rowtype;
  v_why text;
  v_pages jsonb;
begin
  if p_unit is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  perform pg_advisory_xact_lock_shared(hashtextextended('marker:' || v_actor::text, 0));
  select * into v_u from public.marking_units u where u.id = p_unit;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  -- Ruling R9: the exam's marking row, the script's row, the piece's, then its assignment and marking.
  select * into v_m from public.exam_marking m where m.exam_id = v_u.exam_id for share;
  select * into v_x from public.scripts s where s.id = v_u.script_id for no key update;
  select * into v_u from public.marking_units u where u.id = p_unit for update;
  select * into v_p from public.marking_pass(p_unit, v_actor);
  select * into v_mk from public.markings m where m.id = v_p.marking_id for update;
  v_why := public.marking_work_blocked(p_unit, v_actor, v_now);
  if v_why is not null and not (v_why = 'marking_closed' and v_mk.status = 'submitted') then
    return jsonb_build_object('ok', false, 'code', v_why);
  end if;

  select * into v_a from public.marking_assignments a where a.id = v_p.assignment_id for update;
  if v_mk.id is null then
    insert into public.markings (unit_id, kind, marker_id, pages_key)
    values (p_unit, v_p.kind, v_actor, public.marking_pages_key(v_u.script_id))
    returning * into v_mk;
    if v_p.kind = 'live' then
      perform public.marking_script_state(v_u.script_id);
    end if;
  end if;
  if v_a.how = 'next' then
    update public.marking_assignments set hold_until = v_now + interval '2 hours' where id = v_a.id returning * into v_a;
  end if;
  select * into v_e from public.exams e where e.id = v_u.exam_id;

  select coalesce(jsonb_agg(jsonb_build_object('n', x.n, 'page_id', x.page_id, 'copy_page', x.copy_page, 'extra', x.extra,
                                               'rotation', x.rotation, 'has_picture', x.marking_path is not null) order by x.n), '[]'::jsonb)
  into v_pages
  from public.marking_script_pages(v_u.script_id) x;

  return jsonb_build_object(
    'ok', true,
    'unit', jsonb_build_object(
      'id', v_u.id,
      'exam_title', v_e.title,
      'paper', v_e.paper,
      'subject', (select s.name from public.subjects s where s.id = v_e.subject_id),
      'script_number', v_x.number,
      'index_number', (select d.index_number from public.bookings b join public.student_details d on d.profile_id = b.student_id
                       where b.id = v_x.booking_id),
      'group_label', (select g.label from public.question_groups g where g.id = v_u.group_id),
      'deadline', v_m.deadline,
      'hold_until', v_a.hold_until,
      'closed', v_m.closed_at is not null),
    'marking', jsonb_build_object(
      'id', v_mk.id, 'rev', v_mk.rev, 'status', v_mk.status, 'lead_note', v_mk.lead_note, 'total', v_mk.total,
      'max_total', public.marking_unit_max_total(p_unit), 'pages_changed', v_mk.pages_changed_at is not null,
      'practice', false, 'sent_back_note', v_mk.sent_back_note),
    'structure', jsonb_build_object(
      'version', coalesce(v_m.structure_version, 0),
      'questions', coalesce((
        select jsonb_agg(jsonb_build_object(
            'id', q.id, 'parent_id', q.parent_id, 'label', q.label, 'position', q.position, 'max_mark', q.max_mark,
            'mark_step', q.mark_step, 'levels', q.levels, 'pages', to_jsonb(q.pages), 'areas', q.areas, 'group_id', q.group_id,
            'option_group_id', q.option_group_id, 'guidance', q.guidance, 'alternatives', q.alternatives,
            'points', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'label', p.label, 'marks', p.marks,
                                                                    'marks_to', p.marks_to, 'text', p.text) order by p.position)
                                from public.mark_scheme_points p where p.question_id = q.id), '[]'::jsonb))
          order by t.path)
        from public.marking_unit_questions(p_unit) t join public.exam_questions q on q.id = t.question_id), '[]'::jsonb),
      'option_groups', coalesce((
        select jsonb_agg(jsonb_build_object('id', o.id, 'label', o.label, 'choose', o.choose) order by o.label, o.id)
        from public.exam_option_groups o
        where o.id in (select q.option_group_id from public.marking_unit_questions(p_unit) t
                       join public.exam_questions q on q.id = t.question_id)), '[]'::jsonb),
      'mark_scheme_file', (select jsonb_build_object('id', f.id, 'storage_path', f.storage_path)
                           from public.exam_mark_scheme_files f where f.exam_id = v_u.exam_id and f.state = 'stored'
                           order by f.uploaded_at desc limit 1)),
    'pages', v_pages,
    'marks', coalesce((
      select jsonb_agg(jsonb_build_object('question_id', m.question_id, 'mark', m.mark, 'na', m.not_attempted) order by t.path)
      from public.question_marks m join public.marking_unit_questions(p_unit) t on t.question_id = m.question_id
      where m.marking_id = v_mk.id), '[]'::jsonb),
    'annotations', coalesce((
      select jsonb_agg(jsonb_build_object('id', a.id, 'page_id', a.page_id, 'kind', a.kind, 'x', a.x, 'y', a.y, 'points', a.points,
                                          'text', a.text, 'question_id', a.question_id) order by a.created_at, a.id)
      from public.page_annotations a
      where a.marking_id = v_mk.id and a.deleted_at is null
        and exists (select 1 from jsonb_array_elements(v_pages) p
                    where (p ->> 'page_id')::uuid = a.page_id and (p ->> 'rotation')::int = a.page_rotation)), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_save: as 20261122000007, on the caller's own marking of any kind: their pass's hold (a Next script hold is
-- renewed) and, on a submitted marking, marking_after_change once the change is written (the script's and the piece's
-- rows are held). Refused: invalid_input, forbidden (not the caller's marking), conflict (set_aside, or rev with the
-- current rev), on_hold, hold_expired, pictures_updating, marking_closed, reason_required, incomplete,
-- mark_out_of_range. Returns {ok, rev, total, hold_until}.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_save(p_marking uuid, p_rev int, p_ops jsonb, p_active_seconds int default 0,
  p_reason text default null, p_now timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := public.paper_clock(p_now);
  v_reason text := public.script_resolution_reason(p_reason);
  v_mk public.markings%rowtype;
  v_u public.marking_units%rowtype;
  v_why text;
  v_after boolean;
  v_hold timestamptz;
  v_detail text;
begin
  if p_marking is null or p_rev is null or jsonb_typeof(p_ops) is distinct from 'array' or jsonb_array_length(p_ops) not between 1 and 200 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  perform pg_advisory_xact_lock_shared(hashtextextended('marker:' || v_actor::text, 0));
  select * into v_mk from public.markings m where m.id = p_marking;
  if not found or v_mk.marker_id is distinct from v_actor then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select * into v_u from public.marking_units u where u.id = v_mk.unit_id;
  -- Ruling R9: the exam's marking row, the script's row, the piece's, then the marking's.
  perform 1 from public.exam_marking m where m.exam_id = v_u.exam_id for share;
  perform 1 from public.scripts s where s.id = v_u.script_id for no key update;
  select * into v_u from public.marking_units u where u.id = v_mk.unit_id for update;
  select * into v_mk from public.markings m where m.id = p_marking for update;
  if v_mk.status = 'set_aside' then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'set_aside');
  end if;
  v_why := public.marking_work_blocked(v_u.id, v_actor, v_now);
  if v_why is not null then
    return jsonb_build_object('ok', false, 'code', v_why);
  end if;
  if p_rev <> v_mk.rev then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'rev', 'rev', v_mk.rev);
  end if;
  v_after := v_mk.status = 'submitted';
  if v_after and v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;

  -- All or nothing: a refused operation undoes the others. Only the operations' own refusals are answered; any other
  -- error is raised again.
  begin
    perform public.marking_ops_apply(v_mk.id, v_u.id, v_u.script_id, p_ops, v_actor, v_after, case when v_after then v_reason end);
  exception when raise_exception then
    get stacked diagnostics v_detail = pg_exception_detail;
    if sqlerrm = 'incomplete' then
      return jsonb_build_object('ok', false, 'code', 'incomplete', 'missing', v_detail::jsonb);
    elsif sqlerrm in ('invalid_input', 'mark_out_of_range') then
      return jsonb_build_object('ok', false, 'code', sqlerrm);
    end if;
    raise;
  end;

  update public.markings
  set rev = rev + 1, last_saved_at = now(), active_seconds = active_seconds + least(greatest(coalesce(p_active_seconds, 0), 0), 300),
    total = public.marking_total(id)
  where id = v_mk.id
  returning * into v_mk;
  update public.marking_assignments a set hold_until = v_now + interval '2 hours'
  where a.unit_id = v_u.id and a.kind = v_mk.kind and a.marker_id = v_actor and a.ended_at is null and a.how = 'next';
  select a.hold_until into v_hold from public.marking_assignments a
  where a.unit_id = v_u.id and a.kind = v_mk.kind and a.marker_id = v_actor and a.ended_at is null;
  if v_after then
    perform public.marking_after_change(v_mk.id);
    insert into public.audit_log (actor_id, action, target_type, target_id, reason)
    values (v_actor, 'marking_changed_after_submit', 'marking', v_mk.id, v_reason);
  end if;
  return jsonb_build_object('ok', true, 'rev', v_mk.rev, 'total', v_mk.total, 'hold_until', v_hold);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_submit: as 20261122000007, on the caller's own marking of any kind, in progress at rev p_rev. The checks of
-- a save; every question of the piece has a mark or NR (incomplete, with missing: their labels). The marking is
-- submitted (with the structure version and the total; pages_changed_at cleared) and its rev moves on; their hold ends
-- (submitted); a live piece is submitted and its script follows (marking_script_state); then marking_after_submit,
-- whose answer is the feedback (null here), while the script's and the piece's rows are held. The answer no longer
-- says the script's state: a seeded piece's script would give it away. Refused also: conflict with reason submitted
-- (already submitted). Returns {ok, rev, total, max_total, feedback}.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_submit(p_marking uuid, p_rev int, p_now timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := public.paper_clock(p_now);
  v_mk public.markings%rowtype;
  v_u public.marking_units%rowtype;
  v_version int;
  v_why text;
  v_missing jsonb;
  v_feedback text;
begin
  if p_marking is null or p_rev is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  perform pg_advisory_xact_lock_shared(hashtextextended('marker:' || v_actor::text, 0));
  select * into v_mk from public.markings m where m.id = p_marking;
  if not found or v_mk.marker_id is distinct from v_actor then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select * into v_u from public.marking_units u where u.id = v_mk.unit_id;
  -- Ruling R9: the exam's marking row, the script's row, the piece's, then the marking's.
  select m.structure_version into v_version from public.exam_marking m where m.exam_id = v_u.exam_id for share;
  perform 1 from public.scripts s where s.id = v_u.script_id for no key update;
  select * into v_u from public.marking_units u where u.id = v_mk.unit_id for update;
  select * into v_mk from public.markings m where m.id = p_marking for update;
  if v_mk.status in ('set_aside', 'submitted') then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', v_mk.status);
  end if;
  v_why := public.marking_work_blocked(v_u.id, v_actor, v_now);
  if v_why is not null then
    return jsonb_build_object('ok', false, 'code', v_why);
  end if;
  if p_rev <> v_mk.rev then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'rev', 'rev', v_mk.rev);
  end if;
  v_missing := public.marking_missing(v_mk.id, v_u.id);
  if jsonb_array_length(v_missing) > 0 then
    return jsonb_build_object('ok', false, 'code', 'incomplete', 'missing', v_missing);
  end if;

  update public.markings
  set status = 'submitted', rev = rev + 1, submitted_at = now(), structure_version = coalesce(v_version, 0),
    total = public.marking_total(id), pages_changed_at = null
  where id = v_mk.id
  returning * into v_mk;
  update public.marking_assignments a set ended_at = now(), end_reason = 'submitted'
  where a.unit_id = v_u.id and a.kind = v_mk.kind and a.marker_id = v_actor and a.ended_at is null;
  if v_mk.kind = 'live' then
    update public.marking_units set state = 'submitted' where id = v_u.id;
    perform public.marking_script_state(v_u.script_id);
  end if;
  v_feedback := public.marking_after_submit(v_mk.id);
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'marking_submitted', 'marking', v_mk.id);
  return jsonb_build_object('ok', true, 'rev', v_mk.rev, 'total', v_mk.total, 'max_total', public.marking_unit_max_total(v_u.id),
    'feedback', v_feedback);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_name_visible: as 20261122000008, for the caller's passes of every kind. A name a marker saw is always
-- reportable: the caller holds the piece, or has a marking on it that is not set aside (in progress or submitted), of
-- any kind. Refused: invalid_input (also a page the piece does not show), not_found, forbidden (no such claim). In one
-- transaction:
--   a name_visible exception for the page ({"from": "marker"}), unless one is open for it already;
--   on every piece of the script, the caller's holds of every kind end (name_seen), their markings in progress are
--     set aside (name_seen) and Next script never offers them the piece again (an exclusion, which also bars them from
--     its second pass); their marking of the reported piece is set aside whatever its state; their submitted markings
--     of other pieces stand; the pieces whose live pass they no longer hold, or whose live marking of theirs was set
--     aside, are open (another kind of pass leaves the piece's state alone);
--   the script (ready to mark, being marked, marked or checked) is taken back from the markers
--     (marking_script_take_back_as), unless it was already;
--   a name_visible alert; audit marking_name_visible.
-- Returns {ok}.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_name_visible(p_unit uuid, p_page uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_u public.marking_units%rowtype;
  v_x public.scripts%rowtype;
  v_p record;
  v_ended uuid[];
begin
  if p_unit is null or p_page is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  -- Ruling R10: the marker's advisory lock, exclusive (exclusions are added), first of all.
  perform pg_advisory_xact_lock(hashtextextended('marker:' || v_actor::text, 0));
  select * into v_u from public.marking_units u where u.id = p_unit;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  perform public.marking_script_lock(v_u.script_id);
  select * into v_x from public.scripts s where s.id = v_u.script_id;
  perform 1 from public.markings m
  where m.marker_id = v_actor
    and m.unit_id in (select u.id from public.marking_units u where u.script_id = v_x.id)
  order by m.id
  for update;
  select * into v_p from public.marking_pass(p_unit, v_actor);
  if v_p.assignment_id is null and v_p.marking_id is null then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if not exists (select 1 from public.marking_script_pages(v_x.id) x where x.page_id = p_page) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details)
  select v_x.exam_id, 'name_visible', v_x.booking_id, v_x.id, p.id, p.upload_id, '{"from": "marker"}'::jsonb
  from public.script_pages p
  where p.id = p_page
    and not exists (select 1 from public.script_exceptions e where e.page_id = p_page and e.kind = 'name_visible' and e.state = 'open');
  with ended as (
    update public.marking_assignments a set ended_at = now(), end_reason = 'name_seen'
    where a.marker_id = v_actor and a.ended_at is null
      and a.unit_id in (select u.id from public.marking_units u where u.script_id = v_x.id)
    returning a.unit_id, a.kind
  )
  select coalesce(array_agg(e.unit_id) filter (where e.kind = 'live'), '{}') into v_ended from ended e;
  update public.markings m set status = 'set_aside', set_aside_at = now(), set_aside_reason = 'name_seen'
  where m.marker_id = v_actor
    and m.unit_id in (select u.id from public.marking_units u where u.script_id = v_x.id)
    and (m.status = 'in_progress' or (m.unit_id = p_unit and m.status = 'submitted'));
  update public.marking_units u set state = 'open'
  where ((u.id = p_unit and v_p.kind = 'live') or u.id = any (v_ended)) and u.state <> 'open';
  insert into public.marking_unit_exclusions (unit_id, marker_id, reason)
  select u.id, v_actor, 'name_seen' from public.marking_units u where u.script_id = v_x.id
  on conflict do nothing;
  if v_x.state in ('ready_to_mark', 'marking', 'marked', 'checked') and v_x.taken_back_at is null then
    perform public.marking_script_take_back_as(v_x.id, v_actor, 'name_visible');
  end if;
  perform public.marking_alert_raise(v_x.id, 'name_visible', p_unit, p_page);
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'marking_name_visible', 'marking_unit', p_unit);
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_page_marking_name_shows: as 20261122000009, for markings of every kind. "A name still shows" (an admin, with
-- a reason): a name_visible exception for the page ({"from": "staff_check"}), unless one is open. On a script with
-- markers that shows the page (being marked, or taken back from them already), every marker with a marking of any kind
-- on it that is not set aside may have seen the name: on every piece of the script their holds of every kind end, their
-- markings in progress are set aside and they are excluded (name_seen); the pieces whose live pass they no longer hold
-- are open; their submitted markings stand. A script being marked is then taken back (marking_script_take_back_as,
-- with the reason). Audited script_page_marking_name_shows. Refused also: forbidden, invalid_input (no page),
-- reason_required, not_found, conflict with reason changed (a rerun replaced the page). Answers {ok, exception_id}.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_page_marking_name_shows(p_page uuid, p_reason text)
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
  -- The scripts with markers that show the page (being marked, or taken back from the markers): every marker who may
  -- have seen the page (a marking of any kind on it, not set aside) is kept from it below, and one being marked is
  -- taken back. Ruling R10: those markers' keys first, exclusive (exclusions are added), in uuid order; then (Ruling
  -- R9) the scripts' locks.
  for v_m in
    select distinct m.marker_id from public.scripts s
    join public.marking_units u on u.script_id = s.id
    join public.markings m on m.unit_id = u.id
    where s.booking_id = any (v_owners) and (s.taken_back_at is not null or s.state in ('ready_to_mark', 'marking', 'marked'))
      and m.status <> 'set_aside'
    order by 1
  loop
    perform pg_advisory_xact_lock(hashtextextended('marker:' || v_m::text, 0));
  end loop;
  for v_s in
    select s.id from public.scripts s
    where s.booking_id = any (v_owners) and (s.taken_back_at is not null or s.state in ('ready_to_mark', 'marking', 'marked'))
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

  -- A script with markers that shows the page to them (being marked, or taken back already; its locks are held, and one
  -- that came to be marked meanwhile has them taken here). Every marker with a marking of any kind on it that is not
  -- set aside may have seen the name, as with a marker's Name visible: on every piece of the script their holds end
  -- (name_seen), their markings in progress are set aside (name_seen), the pieces whose live pass they no longer hold
  -- are open, and Next script never offers them a piece of it again (an exclusion). Their submitted markings stand. A
  -- script being marked then goes back to staff; one taken back already stays as it is.
  for v_s in
    select s.id from public.scripts s
    where s.booking_id = any (v_bookings) and (s.taken_back_at is not null or s.state in ('ready_to_mark', 'marking', 'marked'))
      and exists (select 1 from public.marking_script_pages(s.id) x where x.page_id = v_p.id)
    order by s.id
  loop
    perform public.marking_script_lock(v_s);
    perform 1 from public.markings m
    where m.unit_id in (select u.id from public.marking_units u where u.script_id = v_s)
    order by m.id
    for update;
    v_markers := array(
      select distinct m.marker_id from public.markings m
      where m.status <> 'set_aside'
        and m.unit_id in (select u.id from public.marking_units u where u.script_id = v_s)
      order by 1);
    foreach v_m in array v_markers loop  -- held already, unless their marking began meanwhile
      perform pg_advisory_xact_lock(hashtextextended('marker:' || v_m::text, 0));
    end loop;
    with ended as (
      update public.marking_assignments a set ended_at = now(), end_reason = 'name_seen'
      where a.marker_id = any (v_markers) and a.ended_at is null
        and a.unit_id in (select u.id from public.marking_units u where u.script_id = v_s)
      returning a.unit_id, a.kind
    )
    select coalesce(array_agg(e.unit_id) filter (where e.kind = 'live'), '{}') into v_ended from ended e;
    update public.markings m set status = 'set_aside', set_aside_at = now(), set_aside_reason = 'name_seen'
    where m.marker_id = any (v_markers) and m.status = 'in_progress'
      and m.unit_id in (select u.id from public.marking_units u where u.script_id = v_s);
    update public.marking_units u set state = 'open' where u.id = any (v_ended) and u.state <> 'open';
    insert into public.marking_unit_exclusions (unit_id, marker_id, reason)
    select u.id, mk, 'name_seen' from public.marking_units u cross join unnest(v_markers) mk where u.script_id = v_s
    on conflict do nothing;
    if exists (select 1 from public.scripts s
               where s.id = v_s and s.taken_back_at is null and s.state in ('ready_to_mark', 'marking', 'marked')) then
      perform public.marking_script_take_back_as(v_s, v_actor, v_reason);
    end if;
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
-- Internal: as 20261122000008, for markings of every kind. The script's markings (not set aside) whose pages_key is not
-- that of its pages now (marking_pages_key) are marked as changed (pages_key, pages_changed_at = now; their rev moves
-- on). A submitted one goes back to its marker when they may still mark it (is_marker_for, not blocked for the
-- candidate, no name_seen exclusion): in progress again, with an assigned hold of its kind (no time limit) unless that
-- pass has an open one, and, for a live marking, its piece taken. Otherwise it is set aside (name_seen, conflict or
-- unapproved) and nobody is given it; a live one's piece is open. A pages_changed alert when any changed. Returns how
-- many went back to their markers. The caller holds the keys of those markers (shared, in uuid order: a piece going
-- back to its marker is a hand-out, Ruling R10), then the script's locks.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_units_refresh(p_script uuid)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text := public.marking_pages_key(p_script);
  v_subject bigint;
  v_student uuid;
  v_changed int := 0;
  v_n int := 0;
  r record;
begin
  select e.subject_id, b.student_id into v_subject, v_student
  from public.scripts s join public.exams e on e.id = s.exam_id join public.bookings b on b.id = s.booking_id
  where s.id = p_script;
  for r in
    select m.id, m.unit_id, m.kind, m.marker_id, m.status,
      public.is_marker_for(m.marker_id, v_subject) as approved,
      public.marking_marker_blocked(m.marker_id, v_student) as blocked,
      exists (select 1 from public.marking_unit_exclusions x where x.unit_id = m.unit_id and x.marker_id = m.marker_id) as name_seen
    from public.markings m join public.marking_units u on u.id = m.unit_id
    where u.script_id = p_script and m.status <> 'set_aside' and m.pages_key is distinct from v_key
    order by u.id, m.id
  loop
    v_changed := v_changed + 1;
    update public.markings set pages_key = v_key, pages_changed_at = now(), rev = rev + 1 where id = r.id;
    if r.status = 'submitted' then
      if r.approved and not r.blocked and not r.name_seen then
        update public.markings set status = 'in_progress', submitted_at = null where id = r.id;
        if r.kind = 'live' then
          update public.marking_units set state = 'taken' where id = r.unit_id;
        end if;
        insert into public.marking_assignments (unit_id, kind, marker_id, how, assigned_by)
        select r.unit_id, r.kind, r.marker_id, 'assigned', auth.uid()
        where not exists (select 1 from public.marking_assignments a where a.unit_id = r.unit_id and a.kind = r.kind and a.ended_at is null);
        v_n := v_n + 1;
      else
        update public.markings
        set status = 'set_aside', set_aside_at = now(),
          set_aside_reason = case when r.name_seen then 'name_seen' when r.blocked then 'conflict' else 'unapproved' end
        where id = r.id;
        if r.kind = 'live' then
          update public.marking_units set state = 'open' where id = r.unit_id and state = 'submitted';
        end if;
      end if;
    end if;
  end loop;
  if v_changed > 0 then
    perform public.marking_alert_raise(p_script, 'pages_changed', null, null);
  end if;
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_script_hand_back: as 20261122000008, for markings of every kind: the keys taken first are those of the
-- markers of the script's markings of any kind that are not set aside (the refresh may give any of them a piece back,
-- Ruling R10), and the Next script holds of every kind restart at now + 2 hours. An admin hands a taken-back script
-- back to the markers. The reason is optional; given, it is 3 to 300 characters (reason_required). The script must be
-- verified (conflict, not_verified) and not busy (conflict, pictures_updating). Its taken_back_* are cleared; it is
-- ready to mark again and the pieces whose pages changed are refreshed (marking_units_refresh); the holds for
-- taken_back, name_visible, picture_changed and picture_missing are lifted; its state follows its pieces. Its open
-- alerts close (handed_back) before the refresh raises any pages_changed alert. Audited (marking_script_handed_back).
-- Refused also: forbidden, invalid_input, not_found, conflict with reason not_taken_back. Returns {ok, state, reopened}.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_script_hand_back(p_script uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_given text := nullif(btrim(coalesce(p_reason, '')), '');
  v_reason text := public.script_resolution_reason(p_reason);
  v_x public.scripts%rowtype;
  v_reopened int;
  v_marker uuid;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_script is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_given is not null and v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if not exists (select 1 from public.scripts s where s.id = p_script) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  -- Ruling R10: a submitted piece may go back to its marker (marking_units_refresh), as a hand-out does, so the markers
  -- of the script's markings of every kind have their keys taken (shared, in uuid order) before the script's locks.
  -- While the script is taken back its pieces are on hold, so no new marking appears meanwhile.
  for v_marker in
    select distinct m.marker_id from public.markings m join public.marking_units u on u.id = m.unit_id
    where u.script_id = p_script and m.status <> 'set_aside'
    order by 1
  loop
    perform pg_advisory_xact_lock_shared(hashtextextended('marker:' || v_marker::text, 0));
  end loop;
  perform public.marking_script_lock(p_script);
  select * into v_x from public.scripts s where s.id = p_script;
  if v_x.taken_back_at is null then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'not_taken_back');
  end if;
  if v_x.state <> 'verified' then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'not_verified');
  end if;
  if public.marking_script_busy(p_script) then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'pictures_updating');
  end if;

  -- Through ready to mark first: marking_exam_sync looks at no pieces, and the extras trigger writes extras_locked.
  update public.scripts set taken_back_at = null, taken_back_by = null, taken_back_reason = null, state = 'ready_to_mark'
  where id = p_script;
  update public.marking_alerts set state = 'closed', closed_by = v_actor, closed_at = now(), resolution = 'handed_back', reason = v_reason
  where script_id = p_script and state = 'open';
  v_reopened := public.marking_units_refresh(p_script);
  update public.marking_units u set on_hold = false, hold_reason = null
  where u.script_id = p_script and u.on_hold and u.hold_reason in ('taken_back', 'name_visible', 'picture_changed', 'picture_missing');
  update public.marking_assignments a set hold_until = now() + interval '2 hours'
  where a.ended_at is null and a.how = 'next'
    and a.unit_id in (select u.id from public.marking_units u where u.script_id = p_script and not u.on_hold);
  perform public.marking_script_state(p_script);
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marking_script_handed_back', 'script', p_script, v_reason);
  select * into v_x from public.scripts s where s.id = p_script;
  return jsonb_build_object('ok', true, 'state', v_x.state, 'reopened', v_reopened);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_alert_release: as 20261122000008, and the released pieces' Next script holds of every kind restart at now +
-- 2 hours (a second marker's as a first marker's). An admin or the subject's lead releases a picture_changed alert
-- (wrong_kind for any other), with a reason, when marking_alert_can_release allows it (conflict with that reason). The
-- script's picture_changed holds are lifted; the alert closes (released). Audited (marking_alert_released). Refused
-- also: forbidden (also a lead blocked for the script's candidate), invalid_input, reason_required, not_found, conflict
-- with reason closed. Returns {ok, released} (how many pieces were released).
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_alert_release(p_alert uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_a public.marking_alerts%rowtype;
  v_subject bigint;
  v_student uuid;
  v_why text;
  v_units uuid[];
begin
  if p_alert is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_a from public.marking_alerts a where a.id = p_alert;
  if not found then
    return jsonb_build_object('ok', false, 'code', case when public.is_staff_admin() then 'not_found' else 'forbidden' end);
  end if;
  select e.subject_id into v_subject from public.exams e where e.id = v_a.exam_id;
  select b.student_id into v_student from public.scripts s join public.bookings b on b.id = s.booking_id where s.id = v_a.script_id;
  if not public.is_staff_admin()
     and (not public.is_lead_for(v_actor, v_subject) or public.marking_marker_blocked(v_actor, v_student)) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if v_a.kind <> 'picture_changed' then
    return jsonb_build_object('ok', false, 'code', 'wrong_kind');
  end if;

  -- Ruling R9: the exam's marking row, the script's row, its pieces; then the alert.
  perform 1 from public.exam_marking m where m.exam_id = v_a.exam_id for share;
  perform 1 from public.scripts s where s.id = v_a.script_id for no key update;
  perform 1 from public.marking_units u where u.script_id = v_a.script_id order by u.id for update;
  select * into v_a from public.marking_alerts a where a.id = p_alert for update;
  if v_a.state <> 'open' then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'closed');
  end if;
  v_why := public.marking_alert_can_release(v_a.script_id);
  if v_why is not null then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', v_why);
  end if;

  with released as (
    update public.marking_units u set on_hold = false, hold_reason = null
    where u.script_id = v_a.script_id and u.on_hold and u.hold_reason = 'picture_changed'
    returning u.id
  )
  select coalesce(array_agg(r.id), '{}') into v_units from released r;
  update public.marking_assignments a set hold_until = now() + interval '2 hours'
  where a.unit_id = any (v_units) and a.ended_at is null and a.how = 'next';
  update public.marking_alerts set state = 'closed', closed_by = v_actor, closed_at = now(), resolution = 'released', reason = v_reason
  where id = v_a.id;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marking_alert_released', 'marking_alert', v_a.id, v_reason);
  return jsonb_build_object('ok', true, 'released', cardinality(v_units));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_alerts_release_all: as 20261122000008, and the released pieces' Next script holds of every kind restart at
-- now + 2 hours. An admin or the subject's lead releases, with one reason, every open picture_changed alert of the exam
-- that marking_alert_can_release allows (the others stay open), as marking_alert_release does each one, under the locks
-- of Ruling R9; a lead blocked for a script's candidate leaves its alert alone (blocked counts them). One audit row for
-- the exam (marking_alerts_released_all). Refused: forbidden, invalid_input, reason_required, not_found. Returns {ok,
-- released, blocked} (how many alerts).
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_alerts_release_all(p_exam uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_admin boolean := public.is_staff_admin();
  v_reason text := public.script_resolution_reason(p_reason);
  v_subject bigint;
  v_scripts uuid[];
  v_units uuid[];
  v_n int := 0;
  v_blocked int := 0;
  r record;
begin
  if p_exam is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select e.subject_id into v_subject from public.exams e where e.id = p_exam;
  if not found then
    return jsonb_build_object('ok', false, 'code', case when v_admin then 'not_found' else 'forbidden' end);
  end if;
  if not v_admin and not public.is_lead_for(v_actor, v_subject) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;

  -- The scripts of the open alerts, then Ruling R9: the exam's marking row, those scripts' rows in id order, their
  -- pieces; then their alerts again, under the locks.
  select coalesce(array_agg(distinct a.script_id order by a.script_id), '{}') into v_scripts
  from public.marking_alerts a where a.exam_id = p_exam and a.kind = 'picture_changed' and a.state = 'open';
  perform 1 from public.exam_marking m where m.exam_id = p_exam for share;
  perform 1 from public.scripts s where s.id = any (v_scripts) order by s.id for no key update;
  perform 1 from public.marking_units u where u.script_id = any (v_scripts) order by u.id for update;
  for r in
    select a.id, a.script_id, b.student_id
    from public.marking_alerts a
    join public.scripts s on s.id = a.script_id
    join public.bookings b on b.id = s.booking_id
    where a.script_id = any (v_scripts) and a.exam_id = p_exam and a.kind = 'picture_changed' and a.state = 'open'
    order by a.script_id
    for update of a
  loop
    if not v_admin and public.marking_marker_blocked(v_actor, r.student_id) then
      v_blocked := v_blocked + 1;
      continue;
    end if;
    continue when public.marking_alert_can_release(r.script_id) is not null;
    with released as (
      update public.marking_units u set on_hold = false, hold_reason = null
      where u.script_id = r.script_id and u.on_hold and u.hold_reason = 'picture_changed'
      returning u.id
    )
    select coalesce(array_agg(x.id), '{}') into v_units from released x;
    update public.marking_assignments a set hold_until = now() + interval '2 hours'
    where a.unit_id = any (v_units) and a.ended_at is null and a.how = 'next';
    update public.marking_alerts set state = 'closed', closed_by = v_actor, closed_at = now(), resolution = 'released', reason = v_reason
    where id = r.id;
    v_n := v_n + 1;
  end loop;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marking_alerts_released_all', 'exam', p_exam,
    v_reason || ' (alerts released: ' || v_n
    || case when v_blocked > 0 then '; skipped, a conflict with the candidate: ' || v_blocked else '' end || ')');
  return jsonb_build_object('ok', true, 'released', v_n, 'blocked', v_blocked);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marker_unapprove: as 20261122000004, and the marker's markings in progress of the kind of each assignment that ends
-- are set aside (unapproved), not only live ones, so a second pass they held is free for another marker. Removes the
-- approval (and the lead flag with it) and ends the marker's open assignments on the subject's exams ('unapproved'; a
-- taken unit of the live pass goes back to open). Submitted markings stay. Returns {ok, released}.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marker_unapprove(p_marker uuid, p_subject bigint, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_subject text;
  v_released int;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_marker is null or p_subject is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  select s.name into v_subject from public.subjects s where s.id = p_subject;
  perform pg_advisory_xact_lock(hashtextextended('marker:' || p_marker::text, 0));
  if v_subject is null or not exists (select 1 from public.marker_approvals a where a.marker_id = p_marker and a.subject_id = p_subject) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  delete from public.marker_approvals a where a.marker_id = p_marker and a.subject_id = p_subject;

  -- Ruling R9: the rows of the scripts whose pieces the marker holds for the subject, then those pieces, in id order,
  -- before their assignments and markings change.
  perform 1 from public.scripts s
  where s.id in (select u.script_id from public.marking_assignments x
                 join public.marking_units u on u.id = x.unit_id
                 join public.exams e on e.id = u.exam_id
                 where x.marker_id = p_marker and x.ended_at is null and e.subject_id = p_subject)
  order by s.id
  for no key update;
  perform 1 from public.marking_units u
  where u.id in (select x.unit_id from public.marking_assignments x
                 join public.marking_units v on v.id = x.unit_id
                 join public.exams e on e.id = v.exam_id
                 where x.marker_id = p_marker and x.ended_at is null and e.subject_id = p_subject)
  order by u.id
  for update;

  with ended as (
    update public.marking_assignments x set ended_at = now(), end_reason = 'unapproved'
    from public.marking_units u
    join public.exams e on e.id = u.exam_id
    where x.unit_id = u.id and x.marker_id = p_marker and x.ended_at is null and e.subject_id = p_subject
    returning x.unit_id, x.kind
  ),
  reopened as (
    update public.marking_units u set state = 'open'
    from ended where u.id = ended.unit_id and ended.kind = 'live' and u.state = 'taken'
    returning u.id
  ),
  aside as (
    update public.markings m
    set status = 'set_aside', set_aside_at = now(), set_aside_reason = 'unapproved'
    from ended where m.unit_id = ended.unit_id and m.marker_id = p_marker and m.kind = ended.kind and m.status = 'in_progress'
    returning m.id
  )
  select count(*)::int into v_released from ended;

  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marker_unapproved', 'marker', p_marker, public.marker_audit_reason(v_reason, 'subject: ' || v_subject));
  return jsonb_build_object('ok', true, 'released', v_released);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marker_conflict_set: as 20261122000004, and the marker's markings in progress of the kind of each assignment that
-- ends are set aside (conflict), not only live ones. The marker must never mark this candidate; ends their open
-- assignments on the candidate's scripts ('conflict'). already_marked counts their submitted markings on them.
-- Returns {ok, released, already_marked}.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marker_conflict_set(p_marker uuid, p_student uuid, p_note text, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_index text;
  v_released int;
  v_marked int;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_marker is null or p_student is null or char_length(coalesce(v_note, '')) > 300 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if not exists (select 1 from public.profiles p where p.id = p_marker and p.role in ('corrector', 'teacher')) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select d.index_number into v_index
  from public.profiles s left join public.student_details d on d.profile_id = s.id
  where s.id = p_student and s.role = 'student';
  if not found then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  perform pg_advisory_xact_lock(hashtextextended('marker:' || p_marker::text, 0));
  insert into public.marker_conflicts (marker_id, student_id, note, recorded_by, recorded_at)
  values (p_marker, p_student, v_note, v_actor, now())
  on conflict (marker_id, student_id) do update set note = excluded.note, recorded_by = excluded.recorded_by, recorded_at = excluded.recorded_at;

  -- Ruling R9: the rows of the candidate's scripts whose pieces the marker holds, then those pieces, in id order, before
  -- their assignments and markings change.
  perform 1 from public.scripts s
  where s.id in (select u.script_id from public.marking_assignments x
                 join public.marking_units u on u.id = x.unit_id
                 join public.scripts t on t.id = u.script_id
                 join public.bookings b on b.id = t.booking_id
                 where x.marker_id = p_marker and x.ended_at is null and b.student_id = p_student)
  order by s.id
  for no key update;
  perform 1 from public.marking_units u
  where u.id in (select x.unit_id from public.marking_assignments x
                 join public.marking_units v on v.id = x.unit_id
                 join public.scripts t on t.id = v.script_id
                 join public.bookings b on b.id = t.booking_id
                 where x.marker_id = p_marker and x.ended_at is null and b.student_id = p_student)
  order by u.id
  for update;

  with ended as (
    update public.marking_assignments x set ended_at = now(), end_reason = 'conflict'
    from public.marking_units u
    join public.scripts s on s.id = u.script_id
    join public.bookings b on b.id = s.booking_id
    where x.unit_id = u.id and x.marker_id = p_marker and x.ended_at is null and b.student_id = p_student
    returning x.unit_id, x.kind
  ),
  reopened as (
    update public.marking_units u set state = 'open'
    from ended where u.id = ended.unit_id and ended.kind = 'live' and u.state = 'taken'
    returning u.id
  ),
  aside as (
    update public.markings m
    set status = 'set_aside', set_aside_at = now(), set_aside_reason = 'conflict'
    from ended where m.unit_id = ended.unit_id and m.marker_id = p_marker and m.kind = ended.kind and m.status = 'in_progress'
    returning m.id
  )
  select count(*)::int into v_released from ended;

  select count(distinct u.script_id)::int into v_marked
  from public.markings m
  join public.marking_units u on u.id = m.unit_id
  join public.scripts s on s.id = u.script_id
  join public.bookings b on b.id = s.booking_id
  where m.marker_id = p_marker and m.status = 'submitted' and b.student_id = p_student;

  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marker_conflict_set', 'marker', p_marker, public.marker_audit_reason(v_reason, 'candidate: ' || coalesce(v_index, 'no index number')));
  return jsonb_build_object('ok', true, 'released', v_released, 'already_marked', v_marked);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- mark_scheme_path_allowed: as 20261122000013, and the marker branch counts a piece they hold, or a marking of theirs
-- not set aside, of any kind: a second marker reads the mark scheme as a first marker does. Editors (structure_can_edit)
-- keep their access; an approved marker of the exam's subject reads the stored PDF only while its marking is open, and
-- only as the subject's lead or with such a piece or marking of that exam.
-- ---------------------------------------------------------------------------------------------
create or replace function public.mark_scheme_path_allowed(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.exam_mark_scheme_files f
    join public.exams e on e.id = f.exam_id
    where f.storage_path = p_name and f.state = 'stored'
      and (public.structure_can_edit((select auth.uid()), f.exam_id)
           or (public.is_marker_for((select auth.uid()), e.subject_id)
               and exists (select 1 from public.exam_marking m
                           where m.exam_id = f.exam_id and m.opened_at is not null and m.closed_at is null)
               and (public.is_lead_for((select auth.uid()), e.subject_id)
                    or exists (select 1 from public.marking_assignments a
                               join public.marking_units u on u.id = a.unit_id
                               where u.exam_id = f.exam_id and a.marker_id = (select auth.uid()) and a.ended_at is null)
                    or exists (select 1 from public.markings x
                               join public.marking_units u on u.id = x.unit_id
                               where u.exam_id = f.exam_id and x.marker_id = (select auth.uid()) and x.status <> 'set_aside')))))
$$;

-- ---------------------------------------------------------------------------------------------
-- Privileges. The internal functions are for definer callers only; the others for signed-in users. Functions made
-- again by create or replace keep theirs (restated).
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.marking_pass(uuid, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_after_submit(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_after_change(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_units_offered(uuid, uuid, uuid, public.marking_kind[]) from public, anon, authenticated, service_role;
revoke execute on function public.marking_units_allowed(uuid, uuid, public.marking_kind, boolean, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_unit_blocked(uuid, uuid, timestamptz, boolean, public.marking_kind) from public, anon, authenticated, service_role;
revoke execute on function public.marking_units_free(uuid, uuid, uuid, timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.marking_units_pick(uuid, uuid, uuid, timestamptz, int, public.marking_kind[]) from public, anon, authenticated, service_role;
revoke execute on function public.marking_unit_take(uuid, uuid, text, uuid, timestamptz, public.marking_kind) from public, anon, authenticated, service_role;
revoke execute on function public.marking_unit_take_back(uuid, public.marking_kind) from public, anon, authenticated, service_role;
revoke execute on function public.marking_work_blocked(uuid, uuid, timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.marking_units_refresh(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_script_waiting(uuid, timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.marking_script_blocked(uuid, timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.marking_next(uuid, uuid, timestamptz) from public, anon;
revoke execute on function public.marking_give_back(uuid, text) from public, anon;
revoke execute on function public.marking_assign(uuid[], uuid, text, public.marking_kind) from public, anon;
revoke execute on function public.marking_assign_some(uuid, uuid, uuid, int, text) from public, anon;
revoke execute on function public.marking_take_back(uuid[], text, public.marking_kind) from public, anon;
revoke execute on function public.marking_my_work(timestamptz) from public, anon;
revoke execute on function public.marking_units_list(uuid, text, uuid) from public, anon;
revoke execute on function public.marking_unit_open(uuid, timestamptz) from public, anon;
revoke execute on function public.marking_save(uuid, int, jsonb, int, text, timestamptz) from public, anon;
revoke execute on function public.marking_submit(uuid, int, timestamptz) from public, anon;
revoke execute on function public.marking_name_visible(uuid, uuid) from public, anon;
revoke execute on function public.script_page_marking_name_shows(uuid, text) from public, anon;
revoke execute on function public.marking_script_hand_back(uuid, text) from public, anon;
revoke execute on function public.marking_alert_release(uuid, text) from public, anon;
revoke execute on function public.marking_alerts_release_all(uuid, text) from public, anon;
revoke execute on function public.mark_scheme_path_allowed(text) from public, anon;
revoke execute on function public.marker_unapprove(uuid, bigint, text) from public, anon;
revoke execute on function public.marker_conflict_set(uuid, uuid, text, text) from public, anon;
grant execute on function public.marking_next(uuid, uuid, timestamptz) to authenticated;
grant execute on function public.marking_give_back(uuid, text) to authenticated;
grant execute on function public.marking_assign(uuid[], uuid, text, public.marking_kind) to authenticated;
grant execute on function public.marking_assign_some(uuid, uuid, uuid, int, text) to authenticated;
grant execute on function public.marking_take_back(uuid[], text, public.marking_kind) to authenticated;
grant execute on function public.marking_my_work(timestamptz) to authenticated;
grant execute on function public.marking_units_list(uuid, text, uuid) to authenticated;
grant execute on function public.marking_unit_open(uuid, timestamptz) to authenticated;
grant execute on function public.marking_save(uuid, int, jsonb, int, text, timestamptz) to authenticated;
grant execute on function public.marking_submit(uuid, int, timestamptz) to authenticated;
grant execute on function public.marking_name_visible(uuid, uuid) to authenticated;
grant execute on function public.script_page_marking_name_shows(uuid, text) to authenticated;
grant execute on function public.marking_script_hand_back(uuid, text) to authenticated;
grant execute on function public.marking_alert_release(uuid, text) to authenticated;
grant execute on function public.marking_alerts_release_all(uuid, text) to authenticated;
grant execute on function public.mark_scheme_path_allowed(text) to authenticated;
grant execute on function public.marker_unapprove(uuid, bigint, text) to authenticated;
grant execute on function public.marker_conflict_set(uuid, uuid, text, text) to authenticated;
