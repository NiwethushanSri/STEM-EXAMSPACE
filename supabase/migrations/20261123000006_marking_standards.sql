-- Phase 3B Task 5: practice and seeded scripts. Making them from the lead's own submitted live marking, clearing a
-- marker after practice, mixing seeds into Next script, counting misses, the pause (applied by the minute job), the
-- marker's feedback, and the email when a marker is paused.
--
-- A standard (marking_standards) is a piece the subject's lead marked live themselves, used for practice or as a
-- seeded script (Builder's call 5): their marks are copied and frozen (marking_standard_marks); the candidate's own
-- marking and final marks are never touched by a practice or seed pass, and the piece is never second-marked. At most
-- 10 standards of each use that are not retired per exam and question group, one per piece. A standard stops being used
-- (retired) by the lead or an admin with a reason, or by itself when the live marking it was copied from leaves
-- submitted (trigger marking_standards_follow): its open attempts end (switched_off), those in progress are set aside;
-- submitted attempts, and the misses they counted, stand.
--
-- A practice or seeded pass is one more pass of the piece (Task 3), with many markers at once: the one rule
-- (marking_units_allowed) allows it on a standard of that use that is not retired and was not set by the marker, while
-- the script is being marked, marked or checked, once per marker (no attempt of theirs submitted), and with the rule's
-- common part (marking open, approved, not on hold, not taken back, no conflict or tutor link, no name seen, one pass
-- per piece). Practice is announced (marking.practice; the piece in the marker's list says practice). A seeded piece
-- looks like any live piece (Review Focus 1): opening it, the list, Next script, saving, submitting and the picture
-- check answer with the same keys and words, the same hold and no timing of their own, and giving it back says nothing.
--
-- Clearance (exam_markers.cleared_at; marking_marker_cleared): with practice on, a marker is handed live and second
-- passes, and seeds, only once the lead or an admin clears them, with a reason (Builder's call 9); the lead needs no
-- practice. Not cleared, Next script gives practice pieces (2-hour holds), then practice_wait (they did at least one)
-- or practice_not_ready. Cleared, it gives a seed when the marker's count to the next seed has run out (exam_markers.
-- until_seed: drawn 1 to seed_every on their first call, counted down by each live or second submit, and drawn again
-- between half and one and a half times seed_every when a seed is handed out), otherwise live and second pieces as
-- before. Seeds come through Next script only (Builder's call 6).
--
-- Misses (Builder's call 7): a seeded attempt outside tolerance (marking_compare_sets against the standard's marks) is
-- a miss: the submit says feedback 'seed', the marker may see the lead's marks (marking_feedback) and the attempt is
-- locked. Within tolerance nothing is said and the run of misses starts again. Three in a row pause the marker on that
-- exam: their work stops at once (paused everywhere they would mark), an audit row and one marker_paused email (no
-- name). The minute job then applies the pause (Builder's call 8, marking_pause_apply): their holds on the exam end,
-- their markings in progress are set aside, their submitted second markings that no review settled are set aside (the
-- piece waits for another second marker), and every piece whose live marking they submitted and the lead has not settled
-- goes to the lead (a paused_marker review, Task 4's rule 4), also a checked one. Clearing a paused marker lets them
-- work again; the pieces with the lead stay there. The lead or an admin may also pause a marker by hand, with a reason
-- (applied at once, no email).
--
-- Added:
--   marking_marker_cleared(p_exam, p_marker), marking_marker_paused(p_exam, p_marker) (internal).
--   marking_standard_compare(p_marking) (internal): a practice or seeded attempt against its standard's marks.
--   marking_standard_end(p_standard, p_actor, p_reason) (internal) and trigger marking_standards_follow on markings.
--   marking_standard_set, marking_standard_retire, marking_standards_list: the lead's standards.
--   marking_pause_apply(p_exam, p_marker) (internal), marking_marker_clear, marking_marker_pause,
--     marking_exam_markers: clearance and the pause.
--   marking_feedback(p_marking): a practice or missed seed attempt beside the lead's marks, for its marker only.
--   script_notices kind marker_paused (with exam_id).
-- Changed, each from its latest definition:
--   marking_units_allowed (20261123000004): kinds practice and seed (above); live and second also need the marker
--     cleared and not paused; practice needs them not paused (the pause stops all their work on the exam, so Next
--     script never resumes a practice piece it could not open). A practice or seeded piece is found from the exam's
--     standards, not by a scan of its pieces.
--   marking_unit_blocked (20261123000004): not_ready for a practice or seeded pass of a script that is not being
--     marked, marked or checked; paused, then practice_first (not for practice), before not_eligible; name_seen for
--     every kind but live.
--   marking_units_offered (20261123000004): practice and seed pieces of the rule that the marker does not hold.
--   marking_units_free (20261123000004): a marker not cleared is counted their practice pieces; a cleared one live and
--     second pieces as before, never a seed.
--   marking_units_pick (20261123000004): practice and seed pieces, held skip locked and read again under the locks.
--   marking_unit_take (20261123000004): only a pass with one holder (live, second, re-mark) sets aside another marker's
--     marking in progress: practice and seed passes have many.
--   marking_next (20261123000004): the marker's exam_markers row; step 2 resumes a practice or seeded piece whose
--     hold ran out (the caller holds it no more; others may); after steps 1 and 2: paused, practice (or practice_wait,
--     practice_not_ready), the seed, then step 3.
--   marking_give_back (20261123000004): a practice or seeded piece whose hold ran out may be given back while others
--     hold it.
--   marking_assign, marking_assign_some (20261123000004): a marker paused (paused) or not cleared (practice_first) on
--     the exam is refused.
--   marking_my_work (20261123000004): each exam also says paused and practice ({needed, done, waiting} for a marker not
--     cleared, else null); left counts practice pieces for a marker not cleared and never a seed; a piece says
--     practice for a practice pass.
--   marking_work_blocked (20261123000004): paused for a paused marker's pass that is not submitted.
--   marking_unit_open (20261123000004): marking.practice is true for a practice pass.
--   marking_save (20261123000005): a paused marker's change to a submitted marking is refused (paused); an attempt
--     whose feedback was shown is locked (locked).
--   marking_after_submit (20261123000005): practice and seeds (above); a live or second submit also counts down to the
--     next seed. A practice or seed pass never evaluates the piece and never writes final marks.
--   marking_tick (20261122000015): also applies each pause not applied yet, in the exam's own exception block, trying
--     the marker's key only (a marker at work is left for the next minute).
--   script_notice_recipients, script_notice_content, script_notice_next, script_notice_given_up,
--     script_family_notices_waiting, script_family_notices_skip (20261122000008): marker_paused goes to the subject's
--     lead and the active owner and admin accounts, about its exam, handed out and given up as a staff alert is; it is
--     not a family notice.
-- Nothing else in them changed. Nothing here gives a marker or a lead a candidate's name; marking_feedback names
-- nobody; the email names the exam only.
--
-- Lock order (as 20261123000003): marker key -> exam_marking -> booking lock -> script rows in id order -> units in id
-- order -> assignments and markings -> marking_reviews -> final_marks -> exam_markers. A marker's exam_markers row is
-- written only by their own calls (Next script, a submit) and by calls that hold their key exclusively (clear, pause,
-- the pause's application); a submit writes it last. Next script makes it before it takes any piece, and every piece it
-- then takes is taken skip locked, so it never waits while holding the row. A pause writes paused_at before the
-- application evaluates the pieces (the check reads it), under the marker's key. No function locks two scripts out of
-- order: the pause's application starts from the minute job or from a lead or admin action at the top. A standard is
-- written after its piece's rows (an advisory lock per exam, 'marking_standards:', counts the standards of a new one).

-- ---------------------------------------------------------------------------------------------
-- Notices: the kind marker_paused, about an exam.
-- ---------------------------------------------------------------------------------------------
alter table public.script_notices drop constraint script_notices_kind_check;
alter table public.script_notices add constraint script_notices_kind_check
  check (kind in ('receipt', 'needs_attention', 'rejected', 'staff_alert', 'marking_alert', 'marker_paused'));
alter table public.script_notices drop constraint script_notices_owner;
alter table public.script_notices add constraint script_notices_owner check (
  (kind = 'staff_alert' and exam_id is not null and exception_kind is not null)
  or (kind = 'marking_alert' and exam_id is not null and alert_id is not null)
  or (kind = 'marker_paused' and exam_id is not null)
  or (kind not in ('staff_alert', 'marking_alert', 'marker_paused') and submission_id is not null));

-- ---------------------------------------------------------------------------------------------
-- Internal: the marker is cleared for live marking on the exam: practice is off for it, or they are the subject's lead
-- marker, or they were cleared (exam_markers.cleared_at). An exam never saved has practice on.
-- ---------------------------------------------------------------------------------------------
create function public.marking_marker_cleared(p_exam uuid, p_marker uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select not m.practice from public.exam_marking m where m.exam_id = p_exam), false)
    or exists (select 1 from public.exams e where e.id = p_exam and public.is_lead_for(p_marker, e.subject_id))
    or exists (select 1 from public.exam_markers x where x.exam_id = p_exam and x.marker_id = p_marker and x.cleared_at is not null)
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the marker is paused on the exam (exam_markers.paused_at).
-- ---------------------------------------------------------------------------------------------
create function public.marking_marker_paused(p_exam uuid, p_marker uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.exam_markers x where x.exam_id = p_exam and x.marker_id = p_marker and x.paused_at is not null)
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: as 20261123000004, the one rule: the pieces of the exam (p_unit: that one only) that p_marker may be given
-- as a p_kind pass, whatever the piece's own state and its live holder. Each piece comes with its group and its script.
--   Every kind (live, second, practice, seed): the exam's marking is open and not closed, the marker is approved for its
--   subject and not paused on the exam (read once); the piece is not on hold; its script was not taken back; the marker
--   has no declared conflict or tutor link with the candidate; they hold no open assignment of another kind on it and
--   no marking of theirs of another kind stands on it (one pass per marker).
--   live, second and seed: the marker is cleared for live marking on the exam (marking_marker_cleared).
--   live: the script is ready to mark or being marked; for Next script only (p_next), they did not see a name on it.
--   second: the script is being marked, marked or checked; the piece waits for a second marking (check_state); nobody
--   else holds its second pass and no second marking of another marker is submitted on it; and they did not see a name
--   on it, whoever hands it out.
--   practice and seed: the script is being marked, marked or checked; the piece is a standard of that use, not retired
--   and not set by this marker; no attempt of theirs on it is submitted; they did not see a name on it.
-- Other kinds allow nothing. One piece is found by its key, a practice or seeded one from the exam's standards: the
-- exam's pieces are scanned only for a live or second pass with p_unit null.
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
    where p_unit is null and p_kind in ('live', 'second') and v.exam_id = p_exam
    union all
    -- A practice or seeded pass is only ever one of the exam's standards: the exam's pieces are not scanned for it.
    select v.id, v.group_id, v.script_id, v.on_hold, v.check_state
    from public.marking_standards st join public.marking_units v on v.id = st.unit_id
    where p_unit is null and p_kind in ('practice', 'seed') and st.exam_id = p_exam and st.use = p_kind::text
      and st.retired_at is null and v.exam_id = p_exam
    union all
    select v.id, v.group_id, v.script_id, v.on_hold, v.check_state from public.marking_units v
    where v.id = p_unit and v.exam_id = p_exam
  ) u
  join public.scripts s on s.id = u.script_id
  join public.bookings b on b.id = s.booking_id
  where p_kind in ('live', 'second', 'practice', 'seed')
    and not u.on_hold
    and s.taken_back_at is null
    and case when p_kind = 'live' then s.state in ('ready_to_mark', 'marking')
             when p_kind = 'second' then s.state in ('marking', 'marked', 'checked') and u.check_state = 'waiting_second'
                  -- Nobody else has the second pass: no other holder, no other second marking submitted.
                  and not exists (select 1 from public.marking_assignments x
                                  where x.unit_id = u.id and x.kind = 'second' and x.ended_at is null and x.marker_id <> p_marker)
                  and not exists (select 1 from public.markings k
                                  where k.unit_id = u.id and k.kind = 'second' and k.marker_id <> p_marker
                                    and k.status = 'submitted')
             -- 3B Task 5: a practice or seeded pass: the piece is a standard of that use, not retired and not set by
             -- this marker, and no attempt of theirs on it is submitted (each once per marker).
             else s.state in ('marking', 'marked', 'checked')
                  and exists (select 1 from public.marking_standards st
                              where st.unit_id = u.id and st.use = p_kind::text and st.retired_at is null and st.set_by <> p_marker)
                  and not exists (select 1 from public.markings k
                                  where k.unit_id = u.id and k.marker_id = p_marker and k.kind = p_kind and k.status = 'submitted') end
    -- Read once: the exam's marking is open and not closed, and the marker is approved for its subject; 3B Task 5: they
    -- are not paused on the exam and, for every kind but practice, are cleared for live marking on it.
    and exists (select 1 from public.exams e join public.exam_marking m on m.exam_id = e.id
                where e.id = p_exam and m.opened_at is not null and m.closed_at is null
                  and public.is_marker_for(p_marker, e.subject_id)
                  and not public.marking_marker_paused(p_exam, p_marker)
                  and (p_kind = 'practice' or public.marking_marker_cleared(p_exam, p_marker)))
    -- marking_marker_blocked: a declared conflict or a tutor link.
    and not exists (select 1 from public.marker_conflicts c where c.marker_id = p_marker and c.student_id = b.student_id)
    and not exists (select 1 from public.tutor_students t where t.tutor_id = p_marker and t.student_id = b.student_id)
    -- A name they saw: Next script never offers the piece; nobody gives them any other kind of pass on it.
    and not ((p_next or p_kind <> 'live')
             and exists (select 1 from public.marking_unit_exclusions x where x.unit_id = u.id and x.marker_id = p_marker))
    -- One pass on a piece per marker: no marking of theirs of another kind stands on it, and they hold no other kind.
    and not exists (select 1 from public.markings k
                    where k.unit_id = u.id and k.marker_id = p_marker and k.kind <> p_kind and k.status <> 'set_aside')
    and not exists (select 1 from public.marking_assignments x
                    where x.unit_id = u.id and x.marker_id = p_marker and x.kind <> p_kind and x.ended_at is null)
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: as 20261123000004, why the piece may not be handed to p_marker at p_now as a p_kind pass (null: it may),
-- whatever its own state and holder. The first of not_found, on_hold, marking_not_open, marking_closed and not_ready
-- (its script is held back, marking_script_blocked; or, live, it is not ready to mark or being marked; or, second, it is
-- not being marked, marked or checked or the piece does not wait for a second marking; or, practice and seed, it is
-- not being marked, marked or checked); then null exactly when the one rule (marking_units_allowed) has a row for the
-- piece; otherwise the first of not_approved, conflict_of_interest, name_seen (for Next script, and for every kind but
-- live always), paused, practice_first (every kind but practice) and not_eligible.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_unit_blocked(p_unit uuid, p_marker uuid, p_now timestamptz, p_next boolean,
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
     or (p_kind = 'second' and (v_state not in ('marking', 'marked', 'checked') or v_u.check_state is distinct from 'waiting_second'))
     or (p_kind in ('practice', 'seed') and v_state not in ('marking', 'marked', 'checked')) then
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
  if (p_next or p_kind <> 'live')
     and exists (select 1 from public.marking_unit_exclusions x where x.unit_id = p_unit and x.marker_id = p_marker) then
    return 'name_seen';
  end if;
  -- 3B Task 5: paused on the exam, or (for every kind but practice) not cleared for live marking on it.
  if public.marking_marker_paused(v_u.exam_id, p_marker) then
    return 'paused';
  end if;
  if p_kind <> 'practice' and not public.marking_marker_cleared(v_u.exam_id, p_marker) then
    return 'practice_first';
  end if;
  return 'not_eligible';
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: as 20261123000004, the pieces of the exam (of the group, when given) that Next script may offer p_marker,
-- each with the kind of pass of p_kinds it would be, all but what holds a script back (marking_script_blocked, which the
-- callers ask once per script): live, an open piece of the one rule (marking_units_candidates); second, a piece of the
-- one rule (second, Next script) whose second pass nobody holds and nobody has submitted; practice and seed, a piece of
-- the one rule of that kind that the marker does not hold (others may).
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_units_offered(p_exam uuid, p_group uuid, p_marker uuid, p_kinds public.marking_kind[])
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
  -- 3B Task 5: a practice or seeded piece of the one rule (Next script) that the marker does not hold (others may).
  union all
  select a.unit_id, a.group_id, a.script_id, 'practice'::public.marking_kind
  from public.marking_units_allowed(p_exam, p_marker, 'practice', true) a
  where 'practice' = any (p_kinds) and (p_group is null or a.group_id = p_group)
    and not exists (select 1 from public.marking_assignments x where x.unit_id = a.unit_id and x.marker_id = p_marker and x.ended_at is null)
  union all
  select a.unit_id, a.group_id, a.script_id, 'seed'::public.marking_kind
  from public.marking_units_allowed(p_exam, p_marker, 'seed', true) a
  where 'seed' = any (p_kinds) and (p_group is null or a.group_id = p_group)
    and not exists (select 1 from public.marking_assignments x where x.unit_id = a.unit_id and x.marker_id = p_marker and x.ended_at is null)
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: as 20261123000004, the free pieces of the exam (of the group, when given) that Next script may hand to
-- p_marker at p_now, whose script nothing holds back, marking_script_blocked running once per script: for a marker
-- cleared for live marking on the exam, its live and second pieces (marking_units_offered), never a seed; for one not
-- cleared, its practice pieces. The pieces left on a marker's list.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_units_free(p_exam uuid, p_group uuid, p_marker uuid, p_now timestamptz)
returns table (unit_id uuid, group_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  with pieces as materialized (
    select distinct o.unit_id, o.group_id, o.script_id
    from public.marking_units_offered(p_exam, p_group, p_marker,
      case when public.marking_marker_cleared(p_exam, p_marker) then '{live,second}'::public.marking_kind[]
           else '{practice}'::public.marking_kind[] end) o
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
-- Internal: as 20261123000004, over the passes of p_kinds (live by default): up to p_count free pieces at random, each
-- with its kind (Next script, and the next n an admin assigns). The offered pieces are read once, in one random order
-- over every kind; each script is checked once (marking_script_blocked), when one of its pieces comes up; each piece is
-- taken with its script's row and its own (Ruling R9), skip locked, so two markers never get the same pass and nobody
-- waits. The state of the piece and of its script are read again on the locked rows (a change committed meanwhile
-- leaves the piece out); a second pass's holders and markings are read again once the piece is held, and so are a
-- practice or seeded piece's standard (not retired) and the marker's own hold and attempt. A piece is returned once.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_units_pick(p_exam uuid, p_group uuid, p_marker uuid, p_now timestamptz, p_count int,
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
    elsif r.pass in ('practice', 'seed') then
      -- 3B Task 5: a practice or seeded piece.
      select u.id into v_unit
      from public.marking_units u
      join public.scripts s on s.id = u.script_id
      where u.id = r.id and not u.on_hold and s.state in ('marking', 'marked', 'checked') and s.taken_back_at is null
      for no key update of s skip locked
      for update of u skip locked;
      -- Held now: still a standard of that use, and the marker neither holds the piece nor has submitted an attempt on it.
      if v_unit is not null and (
           not exists (select 1 from public.marking_standards st where st.unit_id = v_unit and st.use = r.pass::text and st.retired_at is null)
           or exists (select 1 from public.marking_assignments a where a.unit_id = v_unit and a.marker_id = p_marker and a.ended_at is null)
           or exists (select 1 from public.markings m
                      where m.unit_id = v_unit and m.marker_id = p_marker and m.kind = r.pass and m.status = 'submitted')) then
        v_unit := null;
      end if;
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
-- Internal: as 20261123000004: p_marker takes the piece's p_kind pass; the caller holds its script's row and its own. A
-- p_kind assignment (how, by whom, until when: null is no time limit); for a pass with one holder (live, second,
-- re-mark), any other marker's marking of that kind in progress on it is set aside (set_aside_reason: how their
-- assignment ended), while a practice or seeded piece keeps every other marker's attempt; the marker's own earlier
-- marking of that kind, in progress or set aside, is in progress again (never a second row). A live pass also takes the
-- piece, and the script's state follows; another kind leaves both alone.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_unit_take(p_unit uuid, p_marker uuid, p_how text, p_by uuid, p_hold_until timestamptz,
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
  where m.unit_id = p_unit and m.kind = p_kind and m.marker_id <> p_marker and m.status = 'in_progress'
    and p_kind in ('live', 'second', 'remark');  -- 3B Task 5: a practice or seeded piece has many markers at once
  update public.markings m
  set status = 'in_progress', submitted_at = null, set_aside_at = null, set_aside_reason = null
  where m.unit_id = p_unit and m.kind = p_kind and m.marker_id = p_marker and m.status = 'set_aside';
  if p_kind = 'live' then
    perform public.marking_script_state(v_script);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: a practice or seeded attempt (p_marking) compared with its piece's standard (marking_compare_sets: a is the
-- attempt, b the lead's frozen marks). Null when the marking is not such an attempt or its piece has no standard.
-- ---------------------------------------------------------------------------------------------
create function public.marking_standard_compare(p_marking uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.marking_compare_sets(m.unit_id,
    (select coalesce(jsonb_agg(jsonb_build_object('question_id', q.question_id, 'mark', q.mark, 'na', q.not_attempted)), '[]'::jsonb)
     from public.question_marks q where q.marking_id = m.id),
    (select coalesce(jsonb_agg(jsonb_build_object('question_id', sm.question_id, 'mark', sm.mark, 'na', sm.not_attempted)), '[]'::jsonb)
     from public.marking_standard_marks sm where sm.standard_id = st.id))
  from public.markings m
  join public.marking_standards st on st.unit_id = m.unit_id and st.use = m.kind::text
  where m.id = p_marking and m.kind in ('practice', 'seed')
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the standard is no longer used (by p_actor, for p_reason): its open attempts end (switched_off), those in
-- progress are set aside (switched_off); submitted attempts, and the misses they counted, stand. Audited
-- (marking_standard_retired). The caller holds the piece's script and its own row. False when it was retired already.
-- ---------------------------------------------------------------------------------------------
create function public.marking_standard_end(p_standard uuid, p_actor uuid, p_reason text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s public.marking_standards%rowtype;
begin
  select * into v_s from public.marking_standards s where s.id = p_standard;
  if not found or v_s.retired_at is not null then
    return false;
  end if;
  update public.marking_assignments a set ended_at = now(), end_reason = 'switched_off'
  where a.unit_id = v_s.unit_id and a.kind = v_s.use::public.marking_kind and a.ended_at is null;
  update public.markings m set status = 'set_aside', set_aside_at = now(), set_aside_reason = 'switched_off'
  where m.unit_id = v_s.unit_id and m.kind = v_s.use::public.marking_kind and m.status = 'in_progress';
  update public.marking_standards s set retired_at = now(), retired_by = p_actor where s.id = p_standard;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (p_actor, 'marking_standard_retired', 'marking_standard', p_standard, p_reason);
  return true;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- A standard follows the live marking it was copied from: when the lead's live marking of the piece leaves submitted
-- (taken back, reopened, set aside), the standard is retired as marking_standard_retire does, by the caller. Its
-- caller holds the piece's script and its own row.
-- ---------------------------------------------------------------------------------------------
create function public.marking_standards_follow()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.marking_standard_end(s.id, auth.uid(), 'The lead marker''s marking of this script is no longer submitted.')
  from public.marking_standards s
  where s.unit_id = new.unit_id and s.set_by = new.marker_id and s.retired_at is null;
  return null;
end;
$$;

create trigger marking_standards_follow after update of status on public.markings
  for each row
  when (old.status = 'submitted' and new.status <> 'submitted' and new.kind = 'live')
  execute function public.marking_standards_follow();

-- ---------------------------------------------------------------------------------------------
-- marking_standard_set: the subject's lead marker uses a piece they marked live themselves for practice or as a seeded
-- script (p_use), with an optional note to the markers ("why these marks", 3 to 1,000 characters). Refused:
-- invalid_input; not_found; forbidden (not the subject's lead: an admin, a marker, another subject's lead); not_yours
-- (the piece's submitted live marking is not theirs: another marker's, or theirs still in progress); conflict with
-- reason switched_off (the exam has that check off); on_hold; conflict with reason already (the piece is a standard
-- already, even a retired one); too_many (10 standards of that use not retired for the exam and the piece's group).
-- The lead's marks are copied (marking_standard_marks). The piece is never second-marked: a second marking wanted is
-- released (marking_second_release: an open second hold ends and one in progress is set aside), second_wanted is false,
-- and the piece is evaluated again. Audited (marking_standard_set). Returns {ok, standard_id}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_standard_set(p_unit uuid, p_use text, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_u public.marking_units%rowtype;
  v_subject bigint;
  v_m public.exam_marking%rowtype;
  v_live public.markings%rowtype;
  v_id uuid;
begin
  if p_unit is null or p_use is null or p_use not in ('practice', 'seed')
     or (v_note is not null and char_length(v_note) not between 3 and 1000) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_u from public.marking_units u where u.id = p_unit;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select e.subject_id into v_subject from public.exams e where e.id = v_u.exam_id;
  if not public.is_lead_for(v_actor, v_subject) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;

  -- Ruling R9: the exam's marking row, then the exam's standards (one new standard at a time), the script's row and the
  -- piece's.
  select * into v_m from public.exam_marking m where m.exam_id = v_u.exam_id for share;
  perform pg_advisory_xact_lock(hashtextextended('marking_standards:' || v_u.exam_id::text, 0));
  perform 1 from public.scripts s where s.id = v_u.script_id for no key update;
  select * into v_u from public.marking_units u where u.id = p_unit for update;
  select * into v_live from public.markings m where m.unit_id = p_unit and m.kind = 'live' and m.status = 'submitted';
  if v_live.id is null or v_live.marker_id <> v_actor then
    return jsonb_build_object('ok', false, 'code', 'not_yours');
  end if;
  if (p_use = 'practice' and not coalesce(v_m.practice, true)) or (p_use = 'seed' and not coalesce(v_m.seeds, true)) then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'switched_off');
  end if;
  if v_u.on_hold then
    return jsonb_build_object('ok', false, 'code', 'on_hold');
  end if;
  if exists (select 1 from public.marking_standards s where s.unit_id = p_unit) then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'already');
  end if;
  if (select count(*) from public.marking_standards s join public.marking_units w on w.id = s.unit_id
      where s.exam_id = v_u.exam_id and s.use = p_use and s.retired_at is null and w.group_id is not distinct from v_u.group_id) >= 10 then
    return jsonb_build_object('ok', false, 'code', 'too_many');
  end if;

  insert into public.marking_standards (exam_id, unit_id, use, set_by, note)
  values (v_u.exam_id, p_unit, p_use, v_actor, v_note)
  returning id into v_id;
  insert into public.marking_standard_marks (standard_id, question_id, mark, not_attempted)
  select v_id, q.question_id, m.mark, m.not_attempted
  from public.marking_unit_questions(p_unit) q
  join public.question_marks m on m.marking_id = v_live.id and m.question_id = q.question_id
  where q.leaf;
  -- Never second-marked (Builder's call 5).
  if exists (select 1 from public.marking_assignments a where a.unit_id = p_unit and a.kind = 'second' and a.ended_at is null)
     or exists (select 1 from public.markings k where k.unit_id = p_unit and k.kind = 'second' and k.status = 'in_progress') then
    perform public.marking_second_release(p_unit,
      case when p_use = 'practice' then 'Used for practice.' else 'Used as a seeded script.' end);
  else
    update public.marking_units u set second_wanted = false where u.id = p_unit and u.second_wanted is distinct from false;
  end if;
  perform public.marking_check_evaluate(p_unit);
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marking_standard_set', 'marking_unit', p_unit,
    case when p_use = 'practice' then 'Used for practice.' else 'Used as a seeded script.' end);
  return jsonb_build_object('ok', true, 'standard_id', v_id);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_standard_retire: the subject's lead or an admin stops using a standard, with a reason (3 to 300
-- characters): marking_standard_end. Refused: invalid_input; not_found (an admin; forbidden for anyone else);
-- forbidden; reason_required; conflict with reason retired (already). Returns {ok}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_standard_retire(p_standard uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_admin boolean := public.is_staff_admin();
  v_reason text := public.script_resolution_reason(p_reason);
  v_s public.marking_standards%rowtype;
  v_u public.marking_units%rowtype;
begin
  if p_standard is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_s from public.marking_standards s where s.id = p_standard;
  if not found then
    return jsonb_build_object('ok', false, 'code', case when v_admin then 'not_found' else 'forbidden' end);
  end if;
  if not v_admin and not exists (select 1 from public.exams e where e.id = v_s.exam_id and public.is_lead_for(v_actor, e.subject_id)) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  -- Ruling R9: the exam's marking row, the script's row, the piece's, then its passes.
  select * into v_u from public.marking_units u where u.id = v_s.unit_id;
  perform 1 from public.exam_marking m where m.exam_id = v_u.exam_id for share;
  perform 1 from public.scripts s where s.id = v_u.script_id for no key update;
  perform 1 from public.marking_units u where u.id = v_u.id for update;
  if not public.marking_standard_end(p_standard, v_actor, v_reason) then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'retired');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_standards_list: the exam's standards, for the subject's lead and admins (forbidden otherwise; an unknown
-- exam is not_found to an admin and forbidden to anyone else). Each with its script number, index number and group, the
-- lead's total of it (frozen) out of the piece's maximum, the note, whether it is retired, and its attempts: done
-- (submitted) and outside (a seed: a miss; practice: outside tolerance). The lead also gets can_add: their own
-- submitted live pieces of the exam that are not standards (at most 500, more when there are others). No candidate's
-- name. Returns {ok, standards: [{id, unit_id, use, script_number, index_number, group_label, total, max_total, note,
-- retired, attempts: {done, outside}}], can_add: [{unit_id, script_number, index_number, group_label, total}], more}
-- (can_add and more for the lead only).
-- ---------------------------------------------------------------------------------------------
create function public.marking_standards_list(p_exam uuid)
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
  v_lead boolean;
  v_out jsonb;
  v_add jsonb;
  v_more boolean;
begin
  if p_exam is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select e.subject_id into v_subject from public.exams e where e.id = p_exam;
  if not found then
    return jsonb_build_object('ok', false, 'code', case when v_admin then 'not_found' else 'forbidden' end);
  end if;
  v_lead := public.is_lead_for(v_actor, v_subject);
  if not v_admin and not v_lead then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;

  v_out := jsonb_build_object('ok', true, 'standards', coalesce((
    select jsonb_agg(jsonb_build_object(
        'id', st.id, 'unit_id', u.id, 'use', st.use, 'script_number', s.number, 'index_number', d.index_number,
        'group_label', g.label,
        'total', public.marking_set_total(u.id, (
          select coalesce(jsonb_agg(jsonb_build_object('question_id', sm.question_id, 'mark', sm.mark, 'na', sm.not_attempted)), '[]'::jsonb)
          from public.marking_standard_marks sm where sm.standard_id = st.id)),
        'max_total', public.marking_unit_max_total(u.id),
        'note', st.note, 'retired', st.retired_at is not null,
        'attempts', (
          select jsonb_build_object('done', count(*)::int,
            'outside', count(*) filter (where case when st.use = 'seed' then k.feedback_at is not null
                                              else not coalesce((public.marking_standard_compare(k.id) ->> 'within')::boolean, false) end)::int)
          from public.markings k where k.unit_id = u.id and k.kind = st.use::public.marking_kind and k.status = 'submitted'))
      order by s.number, g.position nulls first, st.created_at, st.id)
    from public.marking_standards st
    join public.marking_units u on u.id = st.unit_id
    join public.scripts s on s.id = u.script_id
    join public.bookings b on b.id = s.booking_id
    left join public.student_details d on d.profile_id = b.student_id
    left join public.question_groups g on g.id = u.group_id
    where st.exam_id = p_exam), '[]'::jsonb));
  if not v_lead then
    return v_out;
  end if;

  with mine as (
    select u.id, s.number, d.index_number, g.label, g.position, k.total
    from public.markings k
    join public.marking_units u on u.id = k.unit_id
    join public.scripts s on s.id = u.script_id
    join public.bookings b on b.id = s.booking_id
    left join public.student_details d on d.profile_id = b.student_id
    left join public.question_groups g on g.id = u.group_id
    where u.exam_id = p_exam and k.kind = 'live' and k.status = 'submitted' and k.marker_id = v_actor
      and not exists (select 1 from public.marking_standards st where st.unit_id = u.id)
    order by s.number, g.position nulls first, u.id
    limit 501
  )
  select coalesce(jsonb_agg(jsonb_build_object('unit_id', t.id, 'script_number', t.number, 'index_number', t.index_number,
                                               'group_label', t.label, 'total', t.total) order by t.number, t.position nulls first, t.id)
                  filter (where t.n <= 500), '[]'::jsonb),
         count(*) > 500
  into v_add, v_more
  from (select m.*, row_number() over (order by m.number, m.position nulls first, m.id) as n from mine m) t;
  return v_out || jsonb_build_object('can_add', v_add, 'more', v_more);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_next: as 20261123000004, for every kind of pass, with practice, seeds and the pause (3B Task 5). The caller's
-- row for the exam (exam_markers) is made on their first call, with the pieces until their first seed drawn at random
-- (1 to seed_every). (1) A piece of this exam the caller holds, of any kind, oldest first, while the one rule of that
-- kind still allows it (a name they saw stops a piece held by Next script); (2) a free pass of this exam on which their
-- marking of that kind is in progress (a practice or seeded piece: one they hold no more), while the rule allows it;
-- then: paused when they are paused on the exam; not cleared for live marking on it, one practice piece at random
-- (practice_wait when none is left and they did one, else practice_not_ready); cleared, a seeded piece at random when
-- the exam's seeds are on and their count to the next seed has run out (the count is then drawn again, from half to
-- one and a half times seed_every), otherwise (3) one free piece at random among the live and second passes they may be
-- given. Every hold is 2 hours. Returns {ok, unit_id, resumed} whatever the kind, or {ok: false, code} with
-- not_approved, marking_not_open, marking_closed, paused, practice_wait, practice_not_ready or nothing_left (and
-- invalid_input, not_found).
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
  v_every int;
  v_until int;
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

  -- 3B Task 5: the marker on this exam, made on their first call with the pieces until their first seed drawn at
  -- random (1 to seed_every); one made by a clear or a pause gets its draw now. Only this marker's calls and those that
  -- hold their key write the row.
  v_every := coalesce(v_m.seed_every, 10);
  insert into public.exam_markers as x (exam_id, marker_id, until_seed)
  values (p_exam, v_actor, 1 + floor(random() * v_every)::int)
  on conflict (exam_id, marker_id) do update set until_seed = excluded.until_seed where x.until_seed is null;

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
               -- 3B Task 5: a practice or seeded piece has many holders: free once the caller holds it no more.
               when m.kind in ('practice', 'seed') then not exists (select 1 from public.marking_assignments a
                                                                    where a.unit_id = u.id and a.marker_id = v_actor and a.ended_at is null)
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
               when v_kind = 'second' then u.check_state = 'waiting_second' and s.state in ('marking', 'marked', 'checked')
               else s.state in ('marking', 'marked', 'checked') end
    for no key update of s skip locked
    for update of u skip locked;
    -- Held now, read again as marking_units_pick reads a second pass: nobody took the pass or submitted it meanwhile.
    if v_unit is not null and v_kind = 'second' and (
         exists (select 1 from public.marking_assignments a where a.unit_id = v_unit and a.kind = v_kind and a.ended_at is null)
         or exists (select 1 from public.markings m where m.unit_id = v_unit and m.kind = v_kind and m.status = 'submitted')) then
      v_unit := null;
    end if;
    -- A practice or seeded piece: still a standard of its use, and the caller holds it no more.
    if v_unit is not null and v_kind in ('practice', 'seed') and (
         not exists (select 1 from public.marking_standards st where st.unit_id = v_unit and st.use = v_kind::text and st.retired_at is null)
         or exists (select 1 from public.marking_assignments a where a.unit_id = v_unit and a.marker_id = v_actor and a.ended_at is null)) then
      v_unit := null;
    end if;
    exit when v_unit is not null;
  end loop;

  if v_unit is null then
    v_resumed := false;
    -- 3B Task 5: a paused marker is given nothing (steps 1 and 2 resumed nothing of theirs: the one rule refuses it).
    if public.marking_marker_paused(p_exam, v_actor) then
      return jsonb_build_object('ok', false, 'code', 'paused');
    end if;
    if not public.marking_marker_cleared(p_exam, v_actor) then
      -- Not cleared for live marking: one practice piece at random, or wait.
      select p.unit_id, p.kind into v_unit, v_kind from public.marking_units_pick(p_exam, p_group, v_actor, v_now, 1, '{practice}') p;
      if v_unit is null then
        return jsonb_build_object('ok', false, 'code',
          case when exists (select 1 from public.markings m join public.marking_units u on u.id = m.unit_id
                            where m.marker_id = v_actor and m.kind = 'practice' and m.status = 'submitted' and u.exam_id = p_exam)
               then 'practice_wait' else 'practice_not_ready' end);
      end if;
    else
      -- Cleared: a seeded piece when their count has run out (Builder's call 6), and the gap is drawn again (half to
      -- one and a half times seed_every); otherwise (3) as before.
      select x.until_seed into v_until from public.exam_markers x where x.exam_id = p_exam and x.marker_id = v_actor for update;
      if coalesce(v_m.seeds, true) and v_until <= 0 then
        select p.unit_id, p.kind into v_unit, v_kind from public.marking_units_pick(p_exam, p_group, v_actor, v_now, 1, '{seed}') p;
        if v_unit is not null then
          update public.exam_markers x set until_seed = ceil(v_every / 2.0)::int + floor(random() * v_every)::int
          where x.exam_id = p_exam and x.marker_id = v_actor;
        end if;
      end if;
      -- (3) One free piece at random, a live or a second pass.
      if v_unit is null then
        select p.unit_id, p.kind into v_unit, v_kind from public.marking_units_pick(p_exam, p_group, v_actor, v_now, 1, '{live,second}') p;
        if v_unit is null then
          return jsonb_build_object('ok', false, 'code', 'nothing_left');
        end if;
      end if;
    end if;
  end if;

  perform public.marking_unit_take(v_unit, v_actor, 'next', null, v_now + interval '2 hours', v_kind);
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'marking_unit_taken', 'marking_unit', v_unit);
  return jsonb_build_object('ok', true, 'unit_id', v_unit, 'resumed', v_resumed);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_give_back: as 20261123000004, for the caller's pass of any kind (marking_pass): the holder gives it back (or
-- the marker whose hold on it ran out, while nobody holds that pass; for a practice or seeded piece, which has many
-- holders, while they hold it no more): their hold ends (given_back), their marking in progress is set aside
-- (given_back), and a live piece is open again. Another kind leaves the piece, the script and the first marking alone.
-- The reason is optional; given, it is 3 to 300 characters (invalid_input). Refused once marking has closed. Returns
-- {ok}: the same for every kind.
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
  -- 3B Task 5: a practice or seeded piece has many holders: the caller's own hold having ended is enough.
  if not v_held and not (v_p.status is not distinct from 'in_progress' and (v_p.kind in ('practice', 'seed') or not exists (
       select 1 from public.marking_assignments a where a.unit_id = p_unit and a.kind = v_p.kind and a.ended_at is null))) then
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
-- marking_assign: as 20261123000004, with p_kind (live or second; invalid_input otherwise): an admin gives 1 to 200
-- pieces' p_kind pass to a marker, with a reason, and no time limit. 3B Task 5: a marker paused on an exam of the pieces
-- whose marking is open is refused (paused), then one not cleared for live marking on it (practice_first). A live pass
-- must be open and may be handed to that marker now (marking_unit_blocked; a name the marker saw does not stop an
-- admin). A second pass must be
-- free (taken while a marker holds it; submitted once a second marking is submitted; a second marking in progress whose
-- hold ended is set aside, as on a live piece) and may be handed to the marker as a second pass (a name they saw does
-- stop it). The others are skipped with their code: not_found, taken, submitted, on_hold, marking_not_open,
-- marking_closed, not_ready, not_approved, conflict_of_interest, name_seen, not_eligible. Audited per piece:
-- marking_assigned, or marking_second_assigned. Returns {ok, assigned, skipped: [{unit_id, code}]}.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_assign(p_units uuid[], p_marker uuid, p_reason text, p_kind public.marking_kind default 'live')
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
  -- 3B Task 5: a marker paused on an exam of these pieces whose marking is open, or not cleared for live marking on
  -- it, is refused (a piece of an exam not open is skipped with its own code).
  select t.why into v_why
  from (select case when public.marking_marker_paused(x.exam_id, p_marker) then 'paused'
                    when not public.marking_marker_cleared(x.exam_id, p_marker) then 'practice_first' end as why
        from (select distinct u.exam_id from public.marking_units u
              join public.exam_marking m on m.exam_id = u.exam_id and m.opened_at is not null and m.closed_at is null
              where u.id = any (v_units)) x) t
  where t.why is not null
  order by t.why = 'paused' desc
  limit 1;
  if v_why is not null then
    return jsonb_build_object('ok', false, 'code', v_why);
  end if;
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
-- marking_assign_some: as 20261123000004 (live passes only), and a marker paused on the exam (paused) or not cleared
-- for live marking on it (practice_first) is refused, after marking_not_open and marking_closed.
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
  -- 3B Task 5: a marker paused on the exam, or not cleared for live marking on it, is refused.
  if public.marking_marker_paused(p_exam, p_marker) then
    return jsonb_build_object('ok', false, 'code', 'paused');
  end if;
  if not public.marking_marker_cleared(p_exam, p_marker) then
    return jsonb_build_object('ok', false, 'code', 'practice_first');
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
-- marking_work_blocked: as 20261123000004, and paused (3B Task 5): the caller is paused on the exam and their pass is
-- not submitted (a held piece, a marking in progress, or one set aside), after the first forbidden answers. Why the
-- caller may not work on the piece at p_now (null: they may), the first of:
--   not_found;
--   forbidden: they neither hold it nor have a marking on it that is not set aside, and no marking of theirs on it was
--     set aside; or they are no longer approved for the subject (is_marker_for), or are now blocked for the candidate
--     (marking_marker_blocked);
--   paused;
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
  -- 3B Task 5: the pause stops a marker's work on the exam at once: every pass of theirs that is not submitted.
  if v_status is distinct from 'submitted' and public.marking_marker_paused(v_u.exam_id, p_user) then
    return 'paused';
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
-- marking_unit_open: as 20261123000004, and marking.practice is true for a practice pass (3B Task 5). The piece for
-- its holder (the first open makes their marking, of the kind of their assignment, with the pages key; a Next script
-- hold is renewed to 2 hours from now) or for the marker of its submitted marking (read only once marking has closed:
-- unit.closed). The answer has the same keys for every kind of pass, and carries only the caller's own marking: never
-- another marker's marks, total, annotations or note; a seeded pass answers as a live one does. Refusals
-- (marking_work_blocked): invalid_input, not_found, forbidden, paused, on_hold, hold_expired, pictures_updating,
-- marking_closed. Returns {ok, unit:{id, exam_title, paper, subject, script_number, index_number, group_label,
-- deadline, hold_until, closed}, marking:{id, rev, status, lead_note, total, max_total, pages_changed, practice,
-- sent_back_note}, structure:{version, questions, option_groups, mark_scheme_file}, pages:[{n, page_id, copy_page,
-- extra, rotation, has_picture}], marks:[{question_id, mark, na}], annotations:[{id, page_id, kind, x, y, points, text,
-- question_id}]}. Nothing in it names the candidate.
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
      'practice', v_mk.kind = 'practice', 'sent_back_note', v_mk.sent_back_note),
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
-- marking_save: as 20261123000005, and (3B Task 5) a paused marker's change to a submitted marking is refused (paused:
-- their pass in progress is refused by marking_work_blocked), and an attempt whose feedback was shown (feedback_at: a
-- practice script, or a seeded one outside tolerance) is locked (locked). On the caller's own marking of any kind: their
-- pass's hold (a Next script hold is renewed) and, on a submitted marking, marking_after_change once the change is
-- written (the script's and the piece's rows are held). Refused: invalid_input, forbidden (not the caller's marking),
-- conflict (set_aside, or rev with the current rev), paused, on_hold, hold_expired, pictures_updating, marking_closed,
-- locked, settled, reason_required, incomplete, mark_out_of_range. Returns {ok, rev, total, hold_until}: the same for
-- every kind.
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
  -- 3B Task 5: a paused marker changes nothing on the exam, a submitted marking neither; an attempt whose feedback was
  -- shown (a practice script, or a seeded one outside tolerance) is locked.
  if v_mk.status = 'submitted' and public.marking_marker_paused(v_u.exam_id, v_actor) then
    return jsonb_build_object('ok', false, 'code', 'paused');
  end if;
  if v_mk.feedback_at is not null then
    return jsonb_build_object('ok', false, 'code', 'locked');
  end if;
  if p_rev <> v_mk.rev then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'rev', 'rev', v_mk.rev);
  end if;
  v_after := v_mk.status = 'submitted';
  -- 3B: once the lead has settled the piece, neither of its markers changes a mark (Builder's call 14).
  if v_after and v_mk.kind in ('live', 'second') and public.marking_unit_settled(v_u.id) then
    return jsonb_build_object('ok', false, 'code', 'settled');
  end if;
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
-- Internal: as 20261123000005, what follows a submit; its answer is the submit's feedback. The caller holds the
-- script's and the piece's rows.
--   live or second: the piece is evaluated (marking_check_evaluate) and the marker's count to the next seed goes down
--     by one; null.
--   practice: its feedback is shown (feedback_at); 'practice'.
--   seed: compared with the standard (marking_standard_compare). Within tolerance: the run of misses starts again
--     (misses 0); null, so the marker is told nothing. Outside: a miss (misses + 1) and the feedback is shown
--     (feedback_at, which also locks the attempt); 'seed'. At three in a row the marker is paused on the exam
--     (paused_at; the minute job applies it), audited marker_paused (no actor, reason "three seeded scripts outside
--     tolerance") with one marker_paused email.
-- A practice or seed pass never evaluates the piece and never writes final marks.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_after_submit(p_marking uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_mk public.markings%rowtype;
  v_exam uuid;
  v_x public.exam_markers%rowtype;
begin
  select * into v_mk from public.markings m where m.id = p_marking;
  select u.exam_id into v_exam from public.marking_units u where u.id = v_mk.unit_id;
  if v_mk.kind in ('live', 'second') then
    perform public.marking_check_evaluate(v_mk.unit_id);
    update public.exam_markers x set until_seed = x.until_seed - 1
    where x.exam_id = v_exam and x.marker_id = v_mk.marker_id and x.until_seed is not null;
    return null;
  end if;
  if v_mk.kind = 'practice' then
    update public.markings m set feedback_at = now() where m.id = p_marking;
    return 'practice';
  end if;
  if v_mk.kind is distinct from 'seed' then
    return null;
  end if;

  if coalesce((public.marking_standard_compare(p_marking) ->> 'within')::boolean, false) then
    insert into public.exam_markers as x (exam_id, marker_id, misses) values (v_exam, v_mk.marker_id, 0)
    on conflict (exam_id, marker_id) do update set misses = 0;
    return null;
  end if;
  update public.markings m set feedback_at = now() where m.id = p_marking;
  insert into public.exam_markers as x (exam_id, marker_id, misses) values (v_exam, v_mk.marker_id, 1)
  on conflict (exam_id, marker_id) do update set misses = x.misses + 1
  returning * into v_x;
  if v_x.misses >= 3 and v_x.paused_at is null then
    update public.exam_markers x set paused_at = now(), pause_applied_at = null
    where x.exam_id = v_exam and x.marker_id = v_mk.marker_id;
    insert into public.audit_log (actor_id, action, target_type, target_id, reason)
    values (null, 'marker_paused', 'marker', v_mk.marker_id,
      public.marker_audit_reason('three seeded scripts outside tolerance', 'exam: ' || v_exam::text));
    insert into public.script_notices (kind, exam_id) values ('marker_paused', v_exam);
  end if;
  return 'seed';
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_feedback: a practice attempt, or a seeded one outside tolerance, beside the lead's marks: for the marking's
-- own marker only, and only once its feedback was shown (feedback_at; forbidden otherwise, for anyone else, and for any
-- other marking). The totals apply the piece's "answer n of these" rule; a question is out as the comparison says
-- (Builder's call 3). The lead's note on the standard is shown. Nothing names anybody. Returns {ok, use, total,
-- lead_total, max_total, note, questions: [{question_id, label, max, yours, yours_na, lead, lead_na, out}]} in paper
-- order (yours and lead are null for NR).
-- ---------------------------------------------------------------------------------------------
create function public.marking_feedback(p_marking uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_mk public.markings%rowtype;
  v_s public.marking_standards%rowtype;
  v_cmp jsonb;
begin
  select * into v_mk from public.markings m where m.id = p_marking;
  if not found or v_mk.marker_id is distinct from auth.uid() or v_mk.feedback_at is null or v_mk.kind not in ('practice', 'seed') then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select * into v_s from public.marking_standards s where s.unit_id = v_mk.unit_id and s.use = v_mk.kind::text;
  v_cmp := public.marking_standard_compare(p_marking);
  if v_s.id is null or v_cmp is null then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  return jsonb_build_object(
    'ok', true,
    'use', v_s.use,
    'total', v_cmp -> 'total_a',
    'lead_total', v_cmp -> 'total_b',
    'max_total', v_cmp -> 'max_total',
    'note', v_s.note,
    'questions', coalesce((
      select jsonb_agg(jsonb_build_object('question_id', q -> 'question_id', 'label', q -> 'label', 'max', q -> 'max',
                                          'yours', q -> 'a', 'yours_na', q -> 'a_na', 'lead', q -> 'b', 'lead_na', q -> 'b_na',
                                          'out', q -> 'out') order by o)
      from jsonb_array_elements(v_cmp -> 'questions') with ordinality t(q, o)), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_my_work: as 20261123000004, for the caller's passes of every kind (marking_pass). {ok, approved,
-- lead_subjects: [subject ids], exams: [...], pieces: [...]}. exams: those of a subject they are approved for whose
-- marking is open, and any exam where they hold a piece or have a marking in progress; per exam left counts the pieces
-- Next script could give them now (per group too, when marked by question: for a marker not cleared, their practice
-- pieces; never a seed), mine counts the pieces they hold and have submitted; 3B Task 5: paused, and practice
-- ({needed: those done and those they may still do, done: submitted, waiting: done some and none left} while they are
-- not cleared for live marking on the exam, else null). pieces: what they hold, have in progress and have submitted in
-- those exams, with state (their pass: taken while they hold it, submitted once their marking is, else open), how they
-- hold it (a hold that ran out shows its end) and practice (a practice pass). No key names any other kind of pass: a
-- seeded piece is listed as a live one. The index number is shown; nothing names the candidate.
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
  v_cleared uuid[];
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

  -- 3B Task 5: the exams the caller is cleared for live marking on.
  select coalesce(array_agg(x), '{}') into v_cleared from unnest(v_exams) x where public.marking_marker_cleared(x, v_actor);

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
        'paused', public.marking_marker_paused(e.id, v_actor),
        'practice', case when e.id <> all (v_cleared) then jsonb_build_object(
            'needed', pr.done + pr.allowed, 'done', pr.done, 'waiting', pr.done > 0 and pr.allowed = 0) end,
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
      -- Practice, for a marker not cleared: their submitted practice pieces, and those they may still do.
      left join lateral (
        select (select count(*)::int from public.markings x join public.marking_units u on u.id = x.unit_id
                where u.exam_id = e.id and x.marker_id = v_actor and x.kind = 'practice' and x.status = 'submitted') as done,
               (select count(*)::int from public.marking_units_allowed(e.id, v_actor, 'practice', true)) as allowed
        where e.id <> all (v_cleared)) pr0 on true
      cross join lateral (select coalesce(pr0.done, 0) as done, coalesce(pr0.allowed, 0) as allowed) pr
      where e.id = any (v_exams)), '[]'::jsonb),
    'pieces', coalesce((
      select jsonb_agg(jsonb_build_object(
        'unit_id', u.id, 'exam_id', u.exam_id, 'script_number', s.number, 'index_number', d.index_number, 'group_label', g.label,
        'state', case when p.assignment_id is not null then 'taken' when p.status = 'submitted' then 'submitted' else 'open' end,
        'how', h.how, 'hold_until', h.hold_until, 'on_hold', u.on_hold, 'hold_reason', u.hold_reason,
        'pages_changed', coalesce(x.pages_changed_at is not null, false), 'last_saved_at', x.last_saved_at,
        'practice', p.kind = 'practice')
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
-- Internal: the pause of p_marker on p_exam is applied (Builder's calls 7 and 8). Holds the marker's key, the exam's
-- marking row, then the scripts in id order and their pieces in id order. Nothing is done unless they are paused there.
-- Their open holds on the exam end (paused) and their markings in progress are set aside (paused): those pieces are
-- free (a live one is open). Their submitted second markings on pieces the lead has not settled are set aside (paused):
-- each piece waits for another second marker (the markings_recheck trigger evaluates it). Every piece whose live
-- marking they submitted and the lead has not settled (marking_unit_settled) is evaluated again: it goes to the lead
-- (Task 4's rule 4, a paused_marker review), a checked one too; one already with the lead stays. The scripts follow
-- their pieces. pause_applied_at is set. Returns how many pieces it touched.
-- ---------------------------------------------------------------------------------------------
create function public.marking_pause_apply(p_exam uuid, p_marker uuid)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_units uuid[];
  v_scripts uuid[];
  v_id uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended('marker:' || p_marker::text, 0));
  perform 1 from public.exam_marking m where m.exam_id = p_exam for share;
  if not public.marking_marker_paused(p_exam, p_marker) then
    return 0;
  end if;

  -- The pieces of the exam it touches: those the marker holds, has a marking in progress on, or has submitted a live or
  -- second marking of.
  select coalesce(array_agg(u.id order by u.id), '{}'), coalesce(array_agg(distinct u.script_id), '{}') into v_units, v_scripts
  from public.marking_units u
  where u.exam_id = p_exam
    and (exists (select 1 from public.marking_assignments a where a.unit_id = u.id and a.marker_id = p_marker and a.ended_at is null)
         or exists (select 1 from public.markings m where m.unit_id = u.id and m.marker_id = p_marker
                    and (m.status = 'in_progress' or (m.status = 'submitted' and m.kind in ('live', 'second')))));
  -- Ruling R9: the scripts' rows in id order, then the pieces' rows in id order.
  perform 1 from public.scripts s where s.id = any (v_scripts) order by s.id for no key update;
  perform 1 from public.marking_units u where u.id = any (v_units) order by u.id for update;

  -- Their holds end and their markings in progress are set aside: those pieces are free.
  with ended as (
    update public.marking_assignments a set ended_at = now(), end_reason = 'paused'
    where a.unit_id = any (v_units) and a.marker_id = p_marker and a.ended_at is null
    returning a.unit_id, a.kind
  )
  update public.marking_units u set state = 'open'
  from ended where u.id = ended.unit_id and ended.kind = 'live' and u.state = 'taken';
  update public.markings m set status = 'set_aside', set_aside_at = now(), set_aside_reason = 'paused'
  where m.unit_id = any (v_units) and m.marker_id = p_marker and m.status = 'in_progress';
  -- Their second markings no review settled: set aside; each piece waits for another second marker.
  update public.markings m set status = 'set_aside', set_aside_at = now(), set_aside_reason = 'paused'
  where m.unit_id = any (v_units) and m.marker_id = p_marker and m.kind = 'second' and m.status = 'submitted'
    and not public.marking_unit_settled(m.unit_id);
  -- Their first markings the lead has not settled: to the lead.
  for v_id in
    select m.unit_id from public.markings m
    where m.unit_id = any (v_units) and m.marker_id = p_marker and m.kind = 'live' and m.status = 'submitted'
      and not public.marking_unit_settled(m.unit_id)
    order by m.unit_id
  loop
    perform public.marking_check_evaluate(v_id);
  end loop;
  for v_id in select x from unnest(v_scripts) x order by 1 loop
    perform public.marking_script_state(v_id);
  end loop;
  update public.exam_markers x set pause_applied_at = now() where x.exam_id = p_exam and x.marker_id = p_marker;
  return cardinality(v_units);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the minute job, as 20261122000015. Every exam whose marking is open and not closed is synced, and (3B Task
-- 5) the pause of each of its paused markers whose pause is not applied yet is applied (marking_pause_apply), in the
-- exam's own exception block. The marker's key is only tried: a marker at work at this moment is left for the next
-- minute, so the job never waits for them while it holds the exam's rows. Then the holds that ran out end.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_tick()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_marker uuid;
begin
  for r in select m.exam_id from public.exam_marking m where m.opened_at is not null and m.closed_at is null order by m.exam_id loop
    -- One exam's failure is its own: what it did is undone, the others still run, and the next minute tries it again.
    -- The log line names the exam and the error's SQLSTATE only: an error's message can quote a row.
    begin
      perform public.marking_exam_sync(r.exam_id, null);
      for v_marker in
        select x.marker_id from public.exam_markers x
        where x.exam_id = r.exam_id and x.paused_at is not null and x.pause_applied_at is null
        order by x.marker_id
      loop
        if pg_try_advisory_xact_lock(hashtextextended('marker:' || v_marker::text, 0)) then
          perform public.marking_pause_apply(r.exam_id, v_marker);
        end if;
      end loop;
    exception when others then
      raise warning 'marking_tick: the sync of exam % failed (SQLSTATE %)', r.exam_id, sqlstate;
    end;
  end loop;
  perform public.marking_holds_expire(null);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_marker_clear: the subject's lead (never for themselves) or an admin clears a marker for live marking on the
-- exam, with a reason (3 to 300 characters): cleared_at and cleared_by are set; a pause ends (paused_at and
-- pause_applied_at null) and the run of misses starts again (misses 0); the pieces held for the lead's review stay with
-- the lead. Refused: invalid_input; not_found (an admin; forbidden for anyone else); forbidden; reason_required;
-- not_approved (not an approved active marker of the subject). Audited marker_cleared (with the exam). Returns {ok}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_marker_clear(p_exam uuid, p_marker uuid, p_reason text)
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
  v_every int;
begin
  if p_exam is null or p_marker is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select e.subject_id into v_subject from public.exams e where e.id = p_exam;
  if not found then
    return jsonb_build_object('ok', false, 'code', case when v_admin then 'not_found' else 'forbidden' end);
  end if;
  if not v_admin and (not public.is_lead_for(v_actor, v_subject) or p_marker = v_actor) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if not public.is_marker_for(p_marker, v_subject) then
    return jsonb_build_object('ok', false, 'code', 'not_approved');
  end if;

  -- The marker's key first: their own Next script and submits wait, and so does the minute job's pause.
  perform pg_advisory_xact_lock(hashtextextended('marker:' || p_marker::text, 0));
  select coalesce(m.seed_every, 10) into v_every from public.exam_marking m where m.exam_id = p_exam for share;
  v_every := coalesce(v_every, 10);
  insert into public.exam_markers as x (exam_id, marker_id, cleared_at, cleared_by, until_seed)
  values (p_exam, p_marker, now(), v_actor, 1 + floor(random() * v_every)::int)
  on conflict (exam_id, marker_id) do update set
    cleared_at = now(), cleared_by = v_actor, paused_at = null, pause_applied_at = null, misses = 0,
    until_seed = coalesce(x.until_seed, excluded.until_seed);
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marker_cleared', 'marker', p_marker, public.marker_audit_reason(v_reason, 'exam: ' || p_exam::text));
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_marker_pause: the subject's lead (never for themselves) or an admin pauses a marker on the exam, with a reason
-- (3 to 300 characters): paused_at is set (kept when they were paused already) and the pause is applied at once
-- (marking_pause_apply). No email: the person who paused them knows. Refused as marking_marker_clear. Audited
-- marker_paused (with the exam). Returns {ok}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_marker_pause(p_exam uuid, p_marker uuid, p_reason text)
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
begin
  if p_exam is null or p_marker is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select e.subject_id into v_subject from public.exams e where e.id = p_exam;
  if not found then
    return jsonb_build_object('ok', false, 'code', case when v_admin then 'not_found' else 'forbidden' end);
  end if;
  if not v_admin and (not public.is_lead_for(v_actor, v_subject) or p_marker = v_actor) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if not public.is_marker_for(p_marker, v_subject) then
    return jsonb_build_object('ok', false, 'code', 'not_approved');
  end if;

  -- The marker's key first (see the header: their row is written under it before the pieces are evaluated).
  perform pg_advisory_xact_lock(hashtextextended('marker:' || p_marker::text, 0));
  perform 1 from public.exam_marking m where m.exam_id = p_exam for share;
  insert into public.exam_markers as x (exam_id, marker_id, paused_at) values (p_exam, p_marker, now())
  on conflict (exam_id, marker_id) do update set paused_at = coalesce(x.paused_at, now()), pause_applied_at = null;
  perform public.marking_pause_apply(p_exam, p_marker);
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marker_paused', 'marker', p_marker, public.marker_audit_reason(v_reason, 'exam: ' || p_exam::text));
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_exam_markers: the exam's markers (the subject's approved active markers, the lead first), for the subject's
-- lead and admins (forbidden otherwise; an unknown exam is not_found to an admin and forbidden to anyone else). Each:
-- name, whether they lead, cleared (and when), paused (and when), misses in a row, their submitted practice attempts
-- (standard, script number, their total, the lead's, the maximum, within tolerance), practice_left (the practice pieces
-- they may still do, 0 once cleared), their seeds (done, outside) and to_review (open reviews of their first markings).
-- No candidate's name. Returns {ok, practice_on, seeds_on, markers: [{marker_id, name, lead, cleared, cleared_at,
-- paused, paused_at, misses, practice: [{standard_id, script_number, total, lead_total, max_total, within}],
-- practice_left, seeds: {done, outside}, to_review}]}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_exam_markers(p_exam uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin boolean := public.is_staff_admin();
  v_subject bigint;
  v_m public.exam_marking%rowtype;
begin
  if p_exam is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select e.subject_id into v_subject from public.exams e where e.id = p_exam;
  if not found then
    return jsonb_build_object('ok', false, 'code', case when v_admin then 'not_found' else 'forbidden' end);
  end if;
  if not v_admin and not public.is_lead_for(auth.uid(), v_subject) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select * into v_m from public.exam_marking m where m.exam_id = p_exam;

  return jsonb_build_object(
    'ok', true,
    'practice_on', coalesce(v_m.practice, true),
    'seeds_on', coalesce(v_m.seeds, true),
    'markers', coalesce((
      select jsonb_agg(jsonb_build_object(
          'marker_id', k.marker_id, 'name', k.name, 'lead', k.lead, 'cleared', k.cleared, 'cleared_at', x.cleared_at,
          'paused', x.paused_at is not null, 'paused_at', x.paused_at, 'misses', coalesce(x.misses, 0),
          'practice', coalesce((
            select jsonb_agg(jsonb_build_object('standard_id', st.id, 'script_number', s.number,
                'total', c.cmp -> 'total_a', 'lead_total', c.cmp -> 'total_b', 'max_total', c.cmp -> 'max_total',
                'within', coalesce((c.cmp ->> 'within')::boolean, false))
              order by mk.submitted_at, mk.id)
            from public.markings mk
            join public.marking_units u on u.id = mk.unit_id
            join public.scripts s on s.id = u.script_id
            join public.marking_standards st on st.unit_id = u.id and st.use = 'practice'
            cross join lateral (select public.marking_standard_compare(mk.id) as cmp) c
            where u.exam_id = p_exam and mk.marker_id = k.marker_id and mk.kind = 'practice' and mk.status = 'submitted'), '[]'::jsonb),
          'practice_left', case when k.cleared then 0
                                else (select count(*)::int from public.marking_units_allowed(p_exam, k.marker_id, 'practice', true)) end,
          'seeds', (select jsonb_build_object('done', count(*)::int, 'outside', count(*) filter (where mk.feedback_at is not null)::int)
                    from public.markings mk join public.marking_units u on u.id = mk.unit_id
                    where u.exam_id = p_exam and mk.marker_id = k.marker_id and mk.kind = 'seed' and mk.status = 'submitted'),
          'to_review', (select count(*)::int from public.marking_reviews r join public.markings mk on mk.id = r.marking_id
                        where r.exam_id = p_exam and r.state = 'open' and mk.marker_id = k.marker_id))
        order by k.lead desc, k.name, k.marker_id)
      from (
        select a.marker_id, a.lead, public.marking_marker_cleared(p_exam, a.marker_id) as cleared,
          nullif(btrim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), '') as name
        from public.marker_approvals a join public.profiles p on p.id = a.marker_id
        where a.subject_id = v_subject and public.is_marker_for(a.marker_id, a.subject_id)
      ) k
      left join public.exam_markers x on x.exam_id = p_exam and x.marker_id = k.marker_id), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_notice_recipients: as 20261122000008, and a marker_paused notice goes, as a marking_alert does, to the
-- subject's lead marker (is_lead_for) and the active owner and admin accounts.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_notice_recipients(p_notice public.script_notices)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('profile_id', x.id, 'email', x.email, 'first_name', x.first_name)
    order by lower(x.email)), '[]'::jsonb)
  from (
    select distinct on (lower(r.email)) r.id, r.email, r.first_name
    from (
      select p.id, p.email::text as email, p.first_name, 0 as rnk
      from public.home_submissions h
      join public.bookings b on b.id = h.booking_id
      join public.profiles p on p.id = b.student_id and p.status = 'active'
      where p_notice.kind not in ('staff_alert', 'marking_alert', 'marker_paused') and h.id = p_notice.submission_id
      union all
      select p.id, p.email::text, p.first_name, 1
      from public.home_submissions h
      join public.bookings b on b.id = h.booking_id
      join public.parent_children pc on pc.student_id = b.student_id
      join public.profiles p on p.id = pc.parent_id and p.status = 'active'
      where p_notice.kind not in ('staff_alert', 'marking_alert', 'marker_paused') and h.id = p_notice.submission_id
      union all
      select p.id, p.email::text, p.first_name, 0
      from public.profiles p
      where p_notice.kind in ('staff_alert', 'marking_alert', 'marker_paused') and p.status = 'active' and p.role in ('owner', 'admin')
      union all
      select p.id, p.email::text, p.first_name, 0
      from public.profiles p
      where p_notice.kind in ('marking_alert', 'marker_paused')
        and public.is_lead_for(p.id, (select e.subject_id from public.exams e where e.id = p_notice.exam_id))
    ) r
    where r.email is not null and r.email <> ''
      and not exists (select 1 from public.script_notices_sent s where s.notice_id = p_notice.id and s.profile_id = r.id)
    order by lower(r.email), r.rnk
  ) x
$$;

-- ---------------------------------------------------------------------------------------------
-- script_notice_content: as 20261122000008, and a marker_paused notice's exam is the notice's (it has no script).
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_notice_content(p_notice public.script_notices)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_sub public.home_submissions%rowtype;
  v_script public.scripts%rowtype;
  v_exam uuid;
  v_label text;
  v_pages int[];
begin
  if p_notice.kind in ('staff_alert', 'marking_alert', 'marker_paused') then
    v_exam := p_notice.exam_id;
  else
    select * into v_sub from public.home_submissions h where h.id = p_notice.submission_id;
    select b.exam_id into v_exam from public.bookings b where b.id = v_sub.booking_id;
  end if;
  select * into v_script from public.scripts s where s.id = p_notice.script_id;
  select case when coalesce(btrim(e.paper), '') <> '' and position(lower(btrim(e.paper)) in lower(e.title)) = 0
              then e.title || ' ' || btrim(e.paper) else e.title end
  into v_label from public.exams e where e.id = v_exam;
  select coalesce(array_agg(l.copy_page order by l.copy_page), '{}') into v_pages
  from public.script_page_links l where l.script_id = v_script.id and l.version = v_script.version;

  return jsonb_build_object(
    'exam', v_label,
    'script_number', v_script.number,
    'submission_seq', v_sub.seq,
    'at', coalesce(v_sub.checked_at, v_sub.submitted_at, p_notice.created_at),
    'page_count', cardinality(v_pages),
    'pages', to_jsonb(v_pages),
    'exception_kind', p_notice.exception_kind,
    'count', public.script_notice_count(p_notice),
    'alert_kind', (select a.kind from public.marking_alerts a where a.id = p_notice.alert_id));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_notice_next: as 20261122000008, and a marker_paused notice is handed out as a staff alert is (after the
-- families' notices; 3 tries within 6 hours).
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_notice_next(p_limit int, p_now timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  v_out jsonb := '[]'::jsonb;
  v_n public.script_notices%rowtype;
  v_rec jsonb;
begin
  for v_n in
    select n.* from public.script_notices n
    where n.sent_at is null
      and n.skipped_at is null
      and case when n.kind in ('staff_alert', 'marking_alert', 'marker_paused')
               then n.attempts < 3
                    and n.created_at > v_now - interval '6 hours'
                    and (n.claimed_at is null or n.claimed_at <= v_now - n.attempts * interval '5 minutes')
               else n.created_at > v_now - interval '7 days'
                    and (n.claimed_at is null or n.claimed_at <= v_now - least(n.attempts * 5, 60) * interval '1 minute')
          end
    order by (n.kind in ('staff_alert', 'marking_alert', 'marker_paused')), n.created_at, n.id
    limit greatest(coalesce(p_limit, 0), 0)
    for update skip locked
  loop
    update public.script_notices set claimed_at = v_now, attempts = attempts + 1 where id = v_n.id
    returning * into v_n;
    v_rec := public.script_notice_recipients(v_n);
    if jsonb_array_length(v_rec) = 0 then
      -- everyone was already recorded (a run stopped before marking): nothing left to send
      update public.script_notices set sent_at = v_now where id = v_n.id;
      continue;
    end if;
    v_out := v_out || (jsonb_build_object('id', v_n.id, 'kind', v_n.kind, 'recipients', v_rec)
      || public.script_notice_content(v_n));
  end loop;
  return v_out;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_notice_given_up: as 20261122000008, and a marker_paused notice is given up as a staff alert is.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_notice_given_up(p_now timestamptz default null)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int from public.script_notices n
  where n.sent_at is null
    and n.skipped_at is null
    and case when n.kind in ('staff_alert', 'marking_alert', 'marker_paused')
             then n.attempts >= 3 and n.created_at > coalesce(p_now, now()) - interval '6 hours'
             else n.created_at <= coalesce(p_now, now()) - interval '7 days'
                  and n.created_at > coalesce(p_now, now()) - interval '7 days 6 hours'
        end
$$;

-- ---------------------------------------------------------------------------------------------
-- script_family_notices_waiting: as 20261122000008, without the marker_paused notices (they are not family emails).
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_family_notices_waiting()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_count int;
  v_oldest timestamptz;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select count(*)::int, min(n.created_at) into v_count, v_oldest
  from public.script_notices n
  where n.sent_at is null and n.skipped_at is null and n.kind not in ('staff_alert', 'marking_alert', 'marker_paused');
  return jsonb_build_object('ok', true, 'count', v_count, 'oldest', v_oldest);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_family_notices_skip: as 20261122000008; staff alerts, marking alerts and marker_paused notices are not
-- touched.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_family_notices_skip(p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_skipped int;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  update public.script_notices set skipped_at = now()
  where sent_at is null and skipped_at is null and kind not in ('staff_alert', 'marking_alert', 'marker_paused');
  get diagnostics v_skipped = row_count;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'script_family_notices_skipped', 'script_notices', null, v_reason);
  return jsonb_build_object('ok', true, 'skipped', v_skipped);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Privileges. The functions replaced above keep theirs.
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.marking_marker_cleared(uuid, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_marker_paused(uuid, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_standard_compare(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_standard_end(uuid, uuid, text) from public, anon, authenticated, service_role;
revoke execute on function public.marking_standards_follow() from public, anon, authenticated, service_role;
revoke execute on function public.marking_pause_apply(uuid, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_standard_set(uuid, text, text) from public, anon;
revoke execute on function public.marking_standard_retire(uuid, text) from public, anon;
revoke execute on function public.marking_standards_list(uuid) from public, anon;
revoke execute on function public.marking_marker_clear(uuid, uuid, text) from public, anon;
revoke execute on function public.marking_marker_pause(uuid, uuid, text) from public, anon;
revoke execute on function public.marking_exam_markers(uuid) from public, anon;
revoke execute on function public.marking_feedback(uuid) from public, anon;
grant execute on function public.marking_standard_set(uuid, text, text) to authenticated;
grant execute on function public.marking_standard_retire(uuid, text) to authenticated;
grant execute on function public.marking_standards_list(uuid) to authenticated;
grant execute on function public.marking_marker_clear(uuid, uuid, text) to authenticated;
grant execute on function public.marking_marker_pause(uuid, uuid, text) to authenticated;
grant execute on function public.marking_exam_markers(uuid) to authenticated;
grant execute on function public.marking_feedback(uuid) to authenticated;
