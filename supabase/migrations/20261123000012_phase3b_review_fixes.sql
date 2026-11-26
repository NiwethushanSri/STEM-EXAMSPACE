-- Phase 3B: the fixes of the final review of the whole branch (.superpowers/sdd/2026-11-23-phase3b-checking/
-- final-review.md; its issue numbers below). Rulings R27 to R30.
--
-- Changed, each from its latest definition, adding only what is said here:
--   marking_approval_blocks (20261123000009), issue 1: a block no_scripts ({code, count: 0}, first in the list) when the
--     exam has no script that is not withdrawn or void. An exam whose marking opened before any script arrived is then
--     neither approvable (marking_approve refuses not_all_checked, marking_approval_get's can_approve is false) nor
--     counted ready on the admin home.
--   marking_units_list (20261123000005), issue 2: for a caller who is not an admin, the first marking's total is null on
--     every piece, not only on the pieces Ruling R7 makes blind (a lead could read the running total of a marking in
--     progress, or of a checked piece, and then be handed its second pass). Admins see it as before. No lead page reads it.
--   marking_units_allowed (20261123000007), issue 12: a second pass is never given to a marker who closed a review of the
--     piece (marking_reviews.closed_by, the only column that records who acted on a review: the check opens difference
--     and paused marker's reviews, and a routine sample is opened per marker, its audit row naming the marker sampled,
--     not the piece). Ruling R14 asks only who leads now; a former lead who settled, accepted or sent back the piece's
--     review is now excluded too.
--   marking_second_stuck (20261123000005), issue 13: a piece whose second pass someone holds (an open second assignment)
--     is not stuck, whether or not the holder may still be given it.
--   marking_review_list (20261123000007), issues 14 and 15 (Ruling R29): each open review's second marking is the piece's
--     submitted second marking now, as marking_review_open shows it (a sample review opened before the piece was
--     second-marked showed none); and an open routine sample review of an exam whose marking is approved is left out of
--     the list and its counts (it can no longer be accepted; it is not closed, and comes back if the approval is
--     withdrawn).
--   marking_dashboard (20261123000011), issues 4 to 6 (Rulings R28, R30): an exam whose marking has opened is listed
--     while it is open, closed in the last 14 days, or not approved, however long ago it closed; checked, with_lead and
--     waiting_second (each row and so the totals) and stuck_second count scripts, not pieces (checked: scripts in the
--     state checked); what blocks approval (marking_approval_blocks) is asked only of the listed exams, once each, for
--     ready_to_approve and approved_stale: an approved exam closed more than 14 days ago is no longer tested for stale
--     here (its approval page and Phase 4's refusal still are). left and marked still count pieces.
--   marking_progress (20261123000011), issue 4 (Ruling R30): checks.waiting_second, with_lead and stuck_second count
--     scripts, not pieces, as scripts.checked does.
-- Added:
--   marking_checks_backfill() (internal, issue 3, Ruling R27): for every exam whose marking has opened and is not
--     approved (an approved exam is frozen) with any of double marking, seeded scripts and practice on, the three are
--     turned off with the reason "Marked before the checks existed" (checks_off_reason, at now, by nobody: the migration,
--     as the minute job's writes have no actor), audited marking_checks_set with that reason and no actor, and the exam's
--     pieces are checked (marking_check_exam, as marking_checks_set does when double marking is turned off): a piece
--     submitted before Phase 3B, with no check state, is checked on its first marks. Seeded and practice scripts still in
--     use are retired as marking_checks_set does (none exist before Phase 3B). Returns how many exams it changed. Called
--     once at the end of this migration: an exam already marking when Phase 3B goes in can be approved. Called again it
--     changes nothing.
-- Nothing here names a candidate.
--
-- Lock order (as 20261123000003): marker key -> exam_marking -> booking lock -> script rows in id order -> units in id
-- order -> assignments and markings -> marking_reviews -> final_marks -> exam_markers. The backfill takes, exam by exam
-- in id order, the structure lock and the exam's marking row, then (marking_check_exam) its scripts and its pieces in id
-- order, as marking_checks_set does.

-- ---------------------------------------------------------------------------------------------
-- Internal: what blocks the exam's approval, as 20261123000009, and (the final review's issue 1) no_scripts first when
-- the exam has no script that is not withdrawn or void. In this order, only those with something to block: [{code,
-- count}] (no_scripts: count 0), and scripts_not_checked also says with_staff.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_approval_blocks(p_exam uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with s as materialized (
    select s.id, s.state from public.scripts s where s.exam_id = p_exam and s.state not in ('withdrawn', 'void')
  ),
  u as materialized (
    select u.id, u.check_state, u.on_hold from public.marking_units u join s on s.id = u.script_id where u.exam_id = p_exam
  ),
  -- Only a script that may show a page staff confirmed or assigned whose marking picture is not the one checked (its
  -- current version links it, or it came with the script's hand-in), as script_marking_checks_due finds them, is asked
  -- script_pages_to_check: the others have no page to check.
  accepted as materialized (
    select distinct p.id
    from public.script_exceptions e join public.script_pages p on p.id = e.page_id
    where e.state = 'resolved' and e.resolution in ('confirmed', 'assigned') and p.exam_id = p_exam
      and p.replaced_at is null and p.marking_path is not null and p.marking_path is distinct from p.marking_checked_path
  ),
  shown as materialized (
    select l.script_id as id from accepted a
    join public.script_page_links l on l.page_id = a.id
    join public.scripts x on x.id = l.script_id and x.version = l.version
    union
    select x.id from accepted a
    join public.script_pages p on p.id = a.id
    join public.script_uploads up on up.id = p.upload_id
    join public.home_submissions hs on hs.id = up.submission_id
    join public.scripts x on x.booking_id = hs.booking_id
  ),
  -- Materialized, so script_pages_to_check runs only on these.
  maybe as materialized (
    select s.id from s where s.id in (select shown.id from shown)
  ),
  -- Materialized, so each count is worked out once.
  n as materialized (
    select
      (select count(*)::int from s) as scripts,
      (select count(*)::int from s where s.state not in ('checked', 'final')) as scripts_not_checked,
      (select count(*)::int from s where s.state in ('receiving', 'checking', 'needs_attention', 'verified')) as with_staff,
      (select count(*)::int from u where u.check_state = 'to_lead') as with_lead,
      (select count(*)::int from u where u.check_state = 'waiting_second') as waiting_second,
      (select count(*)::int from u where u.on_hold) as on_hold,
      (select count(*)::int from public.marking_alerts a join s on s.id = a.script_id
       where a.exam_id = p_exam and a.state = 'open') as alerts_open,
      (select count(*)::int from maybe where exists (select 1 from public.script_pages_to_check(maybe.id))) as pictures_to_check,
      (select count(*)::int from public.exam_markers x
       where x.exam_id = p_exam and x.paused_at is not null and x.pause_applied_at is null) as pause_pending
  )
  select coalesce(jsonb_agg(b.j order by b.o) filter (where b.n > 0), '[]'::jsonb)
  from n cross join lateral (values
    -- The final review's issue 1: no script has arrived (none that is not withdrawn or void): nothing to approve yet.
    (0, (n.scripts = 0)::int, jsonb_build_object('code', 'no_scripts', 'count', 0)),
    (1, n.scripts_not_checked,
     jsonb_build_object('code', 'scripts_not_checked', 'count', n.scripts_not_checked, 'with_staff', n.with_staff)),
    (2, n.with_lead, jsonb_build_object('code', 'with_lead', 'count', n.with_lead)),
    (3, n.waiting_second, jsonb_build_object('code', 'waiting_second', 'count', n.waiting_second)),
    (4, n.on_hold, jsonb_build_object('code', 'on_hold', 'count', n.on_hold)),
    (5, n.alerts_open, jsonb_build_object('code', 'alerts_open', 'count', n.alerts_open)),
    (6, n.pictures_to_check, jsonb_build_object('code', 'pictures_to_check', 'count', n.pictures_to_check)),
    (7, n.pause_pending, jsonb_build_object('code', 'pause_pending', 'count', n.pause_pending))
  ) b(o, n, j)
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_units_list: as 20261123000005, and (the final review's issue 2) for a caller who is not an admin the first
-- marking's total is null on every piece. For admins and the subject's lead marker. A lead (any caller who is not an
-- admin) is blind to the first marking of a piece waiting for a second marking, and of a piece whose second pass is
-- theirs (they hold it, or have a second marking of it that is not set aside, whatever its status): its marker_id,
-- marker_name, last_saved_at and submitted_at are null too. p_marker finds a piece by its first marker only when the
-- piece is not blind to the caller (Ruling R8), and also keeps the pieces whose second pass that marker holds or has
-- marked. Each piece says check_state and second: who has its second pass and how ({marker_id, marker_name, state:
-- taken while they hold it, submitted once their second marking is, else open (their marking in progress, no hold),
-- how}, or null when nobody does). Admins see everything. Returns {ok, units, more}.
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
      -- A piece the lead may be blind to (sm.blind) shows nothing of its first marking: no marker, no times, no total.
      'marker_id', case when not sm.blind then p.id end,
      'marker_name', case when p.id is not null and not sm.blind
                          then coalesce(nullif(btrim(p.first_name || ' ' || p.last_name), ''), 'Marker ' || left(p.id::text, 8)) end,
      'how', a.how, 'hold_until', a.hold_until, 'last_saved_at', case when not sm.blind then x.last_saved_at end,
      -- The final review's issue 2: the first marking's total only ever to an admin.
      'submitted_at', case when not sm.blind then x.submitted_at end, 'total', case when v_admin then x.total end,
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
    -- Blind, for a caller who is not an admin: a piece waiting for a second marking (they may be handed it), or one
    -- whose second pass is theirs (they hold it, or their second marking of it is not set aside, whatever its status).
    cross join lateral (
      select not v_admin and (u.check_state is not distinct from 'waiting_second'
                              or coalesce(a2.marker_id = v_actor, false)
                              or coalesce(x2.marker_id = v_actor, false)) as blind) sm
    where u.exam_id = p_exam
      and (p_state is null or (p_state = 'on_hold' and u.on_hold) or u.state = p_state)
      -- Ruling R8: the first marker is matched only where the caller may see who it is.
      and (p_marker is null or (not sm.blind and coalesce(a.marker_id, x.marker_id) = p_marker)
           or coalesce(a2.marker_id, x2.marker_id) = p_marker)
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
-- Internal: as 20261123000007, the one rule, and (the final review's issue 12) a second pass is never given to a
-- marker who closed a review of the piece, of any kind, as a lead then or not (closed_by: a former lead who settled,
-- accepted or sent it back). Ruling R14 as before: never to the subject's lead marker or a staff admin when the piece
-- has a review of any kind, closed or withdrawn ones included. The pieces of the exam (p_unit: that one only) that
-- p_marker may be given as a p_kind pass, whatever the piece's own state and its live holder. Each piece comes with its
-- group and its script.
--   Every kind (live, second, practice, seed): the exam's marking is open and not closed, the marker is approved for its
--   subject and not paused on the exam (read once); the piece is not on hold; its script was not taken back; the marker
--   has no declared conflict or tutor link with the candidate; they hold no open assignment of another kind on it and
--   no marking of theirs of another kind stands on it (one pass per marker).
--   live, second and seed: the marker is cleared for live marking on the exam (marking_marker_cleared).
--   live: the script is ready to mark or being marked; for Next script only (p_next), they did not see a name on it.
--   second: the script is being marked, marked or checked; the piece waits for a second marking (check_state); nobody
--   else holds its second pass and no second marking of another marker is submitted on it; they did not see a name on
--   it, whoever hands it out; (Ruling R14) they are not the subject's lead or a staff admin when the piece has a
--   review (read once per call: whether they are is asked once, the piece's reviews only then); and they closed no
--   review of it.
--   practice and seed: the script is being marked, marked or checked; the piece is a standard of that use, not retired
--   and not set by this marker; no attempt of theirs on it is submitted; they never had a marking or a hold of another
--   kind on it, in any state (one who held the script live would know it again); they did not see a name on it.
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
                  -- 3B Task 7 (Ruling R14): the subject's lead or a staff admin may have seen its first marking through
                  -- a review: no second pass for them on a piece with any review.
                  and not ((select public.is_lead_for(p_marker, e.subject_id)
                                   or exists (select 1 from public.profiles p where p.id = p_marker and p.role in ('owner', 'admin'))
                            from public.exams e where e.id = p_exam)
                           and exists (select 1 from public.marking_reviews r where r.unit_id = u.id))
                  -- The final review's issue 12: nor for one who closed a review of it (a lead then, not now, too).
                  and not exists (select 1 from public.marking_reviews r where r.unit_id = u.id and r.closed_by = p_marker)
             -- 3B Task 5: a practice or seeded pass: the piece is a standard of that use, not retired and not set by
             -- this marker, and no attempt of theirs on it is submitted (each once per marker); nor did they ever have
             -- a marking or a hold of another kind on it, in any state (one who held the script live would know it).
             else s.state in ('marking', 'marked', 'checked')
                  and exists (select 1 from public.marking_standards st
                              where st.unit_id = u.id and st.use = p_kind::text and st.retired_at is null and st.set_by <> p_marker)
                  and not exists (select 1 from public.markings k
                                  where k.unit_id = u.id and k.marker_id = p_marker and k.kind = p_kind and k.status = 'submitted')
                  and not exists (select 1 from public.markings k
                                  where k.unit_id = u.id and k.marker_id = p_marker and k.kind <> p_kind)
                  and not exists (select 1 from public.marking_assignments x
                                  where x.unit_id = u.id and x.marker_id = p_marker and x.kind <> p_kind) end
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
-- Internal (Review Focus 2): as 20261123000005, the pieces of the exam waiting for a second marking (not on hold) that
-- no approved active marker of the subject may be given as a second pass (marking_units_allowed, second, as an admin
-- would hand it out): nobody can second-mark them. (The final review's issue 13) a piece whose second pass someone
-- holds (an open second assignment) is not stuck, whether or not they may still be given it; given back, it is stuck
-- again if nobody may be given it. Lead and admin pages count these; marking_second_drop releases them.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_second_stuck(p_exam uuid)
returns table (unit_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  with markers as materialized (
    select a.marker_id from public.marker_approvals a join public.exams e on e.subject_id = a.subject_id
    where e.id = p_exam and public.is_marker_for(a.marker_id, a.subject_id)
  ),
  allowed as materialized (
    select distinct x.unit_id from markers k cross join lateral public.marking_units_allowed(p_exam, k.marker_id, 'second', false) x
  )
  select u.id from public.marking_units u
  where u.exam_id = p_exam and u.check_state = 'waiting_second' and not u.on_hold
    -- The final review's issue 13: someone holds its second pass.
    and not exists (select 1 from public.marking_assignments a where a.unit_id = u.id and a.kind = 'second' and a.ended_at is null)
    and not exists (select 1 from allowed w where w.unit_id = u.id)
  order by u.id
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_review_list: as 20261123000007, and (the final review's issues 14 and 15) each review's second marking is the
-- piece's submitted second marking now, as marking_review_open shows an open review's; and (Ruling R29) an open routine
-- sample review of an exam whose marking is approved is left out of the items and the counts (it is not closed: it
-- comes back if the approval is withdrawn). The open reviews the caller may act on, oldest first (at most 500, with
-- more), of the exams whose marking has opened (p_exam: that one) of a subject they lead (an admin: every subject);
-- p_kind (difference, paused_marker or sample) narrows the items, not the counts. A lead's list leaves out the reviews
-- they are refused (marking_review_refusal) or blind to (marking_review_blind). counts: open reviews of each kind;
-- to_clear: markers of those exams who did every practice script they may do and are not cleared yet; stuck_second:
-- pieces waiting for a second marker whom nobody can be (marking_second_stuck). No candidate's name. Returns {ok,
-- counts: {difference, paused_marker, sample, to_clear, stuck_second}, items: [{review_id, kind, exam_id, exam_title,
-- unit_id, script_number, index_number, group_label, first: {marker_id, name, total}, second: {marker_id, name,
-- total}|null, max_total, opened_at, party}], more}; party is true when the caller is one of the two markers.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_review_list(p_exam uuid default null, p_kind text default null)
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
  v_exams uuid[];
  v_counts jsonb;
  v_items jsonb;
  v_more boolean;
begin
  if p_kind is not null and p_kind not in ('difference', 'paused_marker', 'sample') then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if not v_admin and not exists (select 1 from public.marker_approvals a
                                 where a.marker_id = v_actor and a.lead and public.is_lead_for(v_actor, a.subject_id)) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is not null then
    select e.subject_id into v_subject from public.exams e where e.id = p_exam;
    if not found then
      return jsonb_build_object('ok', false, 'code', case when v_admin then 'not_found' else 'forbidden' end);
    end if;
    if not v_admin and not public.is_lead_for(v_actor, v_subject) then
      return jsonb_build_object('ok', false, 'code', 'forbidden');
    end if;
  end if;

  select coalesce(array_agg(e.id order by e.id), '{}') into v_exams
  from public.exams e join public.exam_marking m on m.exam_id = e.id
  where m.opened_at is not null and (p_exam is null or e.id = p_exam) and (v_admin or public.is_lead_for(v_actor, e.subject_id));

  with pending as materialized (
    select r.id, r.kind, r.exam_id, r.unit_id, r.marking_id, r.second_marking_id, r.opened_at
    from public.marking_reviews r
    where r.exam_id = any (v_exams) and r.state = 'open'
      and (v_admin or (public.marking_review_refusal(r.unit_id) is null and not public.marking_review_blind(r.unit_id)))
      -- Ruling R29: a routine sample of an approved exam can no longer be acted on.
      and not (r.kind = 'sample'
               and exists (select 1 from public.exam_marking m where m.exam_id = r.exam_id and m.approved_at is not null))
  ),
  listed as materialized (
    select p.* from pending p
    where p_kind is null or p.kind = p_kind
    order by p.opened_at, p.id
    limit 501  -- one more than is listed, to know whether there are more
  )
  select
    jsonb_build_object(
      'difference', (select count(*)::int from pending p where p.kind = 'difference'),
      'paused_marker', (select count(*)::int from pending p where p.kind = 'paused_marker'),
      'sample', (select count(*)::int from pending p where p.kind = 'sample')),
    coalesce((
      select jsonb_agg(jsonb_build_object(
          'review_id', l.id, 'kind', l.kind, 'exam_id', l.exam_id, 'exam_title', e.title, 'unit_id', l.unit_id,
          'script_number', s.number, 'index_number', d.index_number, 'group_label', g.label,
          'first', jsonb_build_object('marker_id', f.marker_id,
            'name', coalesce(nullif(btrim(pf.first_name || ' ' || pf.last_name), ''), 'Marker ' || left(pf.id::text, 8)),
            'total', f.total),
          'second', case when k.id is not null then jsonb_build_object('marker_id', k.marker_id,
            'name', coalesce(nullif(btrim(pk.first_name || ' ' || pk.last_name), ''), 'Marker ' || left(pk.id::text, 8)),
            'total', k.total) end,
          'max_total', public.marking_unit_max_total(l.unit_id),
          'opened_at', l.opened_at,
          'party', coalesce(f.marker_id = v_actor, false) or coalesce(k.marker_id = v_actor, false))
        order by l.opened_at, l.id)
      from (select x.* from listed x order by x.opened_at, x.id limit 500) l
      join public.exams e on e.id = l.exam_id
      join public.marking_units u on u.id = l.unit_id
      join public.scripts s on s.id = u.script_id
      join public.bookings b on b.id = s.booking_id
      left join public.student_details d on d.profile_id = b.student_id
      left join public.question_groups g on g.id = u.group_id
      join public.markings f on f.id = l.marking_id
      join public.profiles pf on pf.id = f.marker_id
      -- The final review's issue 14: the piece's submitted second marking now, as marking_review_open shows an open
      -- review's (every review listed is open; a piece has at most one standing second marking).
      left join public.markings k on k.unit_id = l.unit_id and k.kind = 'second' and k.status = 'submitted'
      left join public.profiles pk on pk.id = k.marker_id), '[]'::jsonb),
    (select count(*) > 500 from listed)
  into v_counts, v_items, v_more;

  v_counts := v_counts || jsonb_build_object(
    'to_clear', (
      select count(*)::int
      from unnest(v_exams) x(exam_id)
      join public.exams e on e.id = x.exam_id
      join public.marker_approvals a on a.subject_id = e.subject_id
      where public.is_marker_for(a.marker_id, a.subject_id)
        and not public.marking_marker_cleared(x.exam_id, a.marker_id)
        and exists (select 1 from public.markings k join public.marking_units u on u.id = k.unit_id
                    where u.exam_id = x.exam_id and k.marker_id = a.marker_id and k.kind = 'practice' and k.status = 'submitted')
        and not exists (select 1 from public.marking_units_allowed(x.exam_id, a.marker_id, 'practice', true))),
    'stuck_second', (select count(*)::int from unnest(v_exams) x(exam_id) cross join lateral public.marking_second_stuck(x.exam_id) t));
  return jsonb_build_object('ok', true, 'counts', v_counts, 'items', v_items, 'more', v_more);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_dashboard: as 20261123000011, with the final review's issues 4 to 6 (see the header). The marking figures of
-- the admin home page. Per exam whose marking has opened and is open, closed in the last 14 days, or not approved: of
-- its scripts not withdrawn or void, left and marked (pieces), on_hold (scripts with a piece on hold), checked
-- (scripts checked), with_lead and waiting_second (scripts with a piece with the lead marker, or waiting for a second
-- marker), and approved. Totals: left, on_hold, overdue_exams, with_lead and waiting_second of the listed exams;
-- alerts_open (scripts with an open marking alert, of any exam); pictures_to_check; stale_assigned; stuck_second
-- (scripts of the listed exams with a piece nobody can second-mark: marking_second_stuck); markers_paused (the markers
-- paused on a listed exam whose marking is not approved, each once); ready_to_approve and approved_stale (listed exams
-- not approved with nothing blocking, and approved with something blocking: marking_approval_blocks, asked once per
-- listed exam). Admins only.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_dashboard(p_now timestamptz default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := public.paper_clock(p_now);
  v_exams jsonb;
  v_listed uuid[];
  v_left int;
  v_on_hold int;
  v_overdue int;
  v_with_lead int;
  v_waiting int;
  v_ready int;
  v_stale int;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;

  -- Materialized, so what blocks each listed exam is worked out once.
  with ex as materialized (
    select e.id, e.title, e.paper, e.starts_at, m.deadline, m.approved_at, public.marking_exam_overdue(e.id, v_now) as overdue,
      c.left_n, c.marked, c.on_hold, c.checked, c.with_lead, c.waiting_second,
      jsonb_array_length(public.marking_approval_blocks(e.id)) as blocks
    from public.exam_marking m
    join public.exams e on e.id = m.exam_id
    cross join lateral (
      select count(*) filter (where u.state <> 'submitted')::int as left_n,
             count(*) filter (where u.state = 'submitted')::int as marked,
             count(distinct u.script_id) filter (where u.on_hold)::int as on_hold,
             -- The final review's issue 4 (Ruling R30): scripts, where staff read scripts.
             count(distinct u.script_id) filter (where s.state = 'checked')::int as checked,
             count(distinct u.script_id) filter (where u.check_state = 'to_lead')::int as with_lead,
             count(distinct u.script_id) filter (where u.check_state = 'waiting_second')::int as waiting_second
      from public.marking_units u join public.scripts s on s.id = u.script_id
      where u.exam_id = e.id and s.state not in ('withdrawn', 'void')
    ) c
    -- The final review's issue 5: listed while not approved, however long ago its marking closed.
    where m.opened_at is not null
      and (m.closed_at is null or m.closed_at > v_now - interval '14 days' or m.approved_at is null)
  )
  select coalesce(jsonb_agg(jsonb_build_object('exam_id', x.id, 'title', x.title, 'paper', x.paper, 'deadline', x.deadline,
           'overdue', x.overdue, 'left', x.left_n, 'marked', x.marked, 'on_hold', x.on_hold, 'checked', x.checked,
           'with_lead', x.with_lead, 'waiting_second', x.waiting_second, 'approved', x.approved_at is not null)
           order by x.starts_at, x.id), '[]'::jsonb),
         coalesce(array_agg(x.id), '{}'),
         coalesce(sum(x.left_n), 0)::int, coalesce(sum(x.on_hold), 0)::int, (count(*) filter (where x.overdue))::int,
         coalesce(sum(x.with_lead), 0)::int, coalesce(sum(x.waiting_second), 0)::int,
         -- The final review's issue 6 (Ruling R28): of the listed exams only.
         (count(*) filter (where x.approved_at is null and x.blocks = 0))::int,
         (count(*) filter (where x.approved_at is not null and x.blocks > 0))::int
  into v_exams, v_listed, v_left, v_on_hold, v_overdue, v_with_lead, v_waiting, v_ready, v_stale
  from ex x;

  return jsonb_build_object('ok', true, 'exams', v_exams, 'totals', jsonb_build_object(
    'left', v_left,
    'on_hold', v_on_hold,
    'overdue_exams', v_overdue,
    'alerts_open', (select count(distinct a.script_id)::int from public.marking_alerts a
                    join public.exams e on e.id = a.exam_id join public.scripts s on s.id = a.script_id
                    where a.state = 'open'),
    'pictures_to_check', (select count(*)::int from public.script_marking_checks_due(null)),
    'stale_assigned', (
      select count(*)::int
      from public.marking_assignments a
      join public.marking_units u on u.id = a.unit_id
      join public.scripts s on s.id = u.script_id
      join public.exam_marking m on m.exam_id = u.exam_id
      left join public.markings x on x.unit_id = a.unit_id and x.kind = 'live' and x.marker_id = a.marker_id
                                 and x.status <> 'set_aside'
      where a.kind = 'live' and a.how = 'assigned' and a.ended_at is null
        and m.opened_at is not null and m.closed_at is null
        and not u.on_hold and s.state not in ('withdrawn', 'void')
        and greatest(a.created_at, x.last_saved_at) < v_now - interval '7 days'),
    'with_lead', v_with_lead,
    'waiting_second', v_waiting,
    'stuck_second', (select count(distinct u.script_id)::int
                     from unnest(v_listed) l(exam_id) cross join lateral public.marking_second_stuck(l.exam_id) t
                     join public.marking_units u on u.id = t.unit_id),
    'markers_paused', (select count(distinct x.marker_id)::int
                       from public.exam_markers x join public.exam_marking m on m.exam_id = x.exam_id
                       where x.exam_id = any (v_listed) and x.paused_at is not null and m.approved_at is null),
    'ready_to_approve', v_ready,
    'approved_stale', v_stale));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_progress: as 20261123000011, and (the final review's issue 4, Ruling R30) checks.waiting_second, with_lead and
-- stuck_second count scripts, not pieces. What is left, per exam and per marker. Admins: every exam with marking
-- settings (p_exam: that one); a lead marker: the exams of the subjects they lead. Per exam: {exam_id, title, paper,
-- subject, mode, deadline, overdue (marking_exam_overdue), opened_at, closed_at, scripts: {waiting (verified, not yet
-- ready), ready_to_mark, marking, marked (marked or checked), checked}, units: {open, taken, submitted (not on hold),
-- on_hold} of scripts not withdrawn or void, checks: {waiting_second, with_lead (scripts with such a piece, of scripts
-- not withdrawn or void), stuck_second (scripts with a piece nobody can second-mark: marking_second_stuck),
-- paused_markers, approved_at}, markers: [{marker_id, name, taken, submitted, last_saved_at}] of scripts not withdrawn
-- or void, alerts_open}. A marker's name is never their email (as marking_units_list).
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_progress(p_exam uuid default null, p_now timestamptz default null)
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
                    'marked', count(*) filter (where s.state in ('marked', 'checked')),
                    'checked', count(*) filter (where s.state = 'checked'))
                  from public.scripts s where s.exam_id = e.id),
      'units', (select jsonb_build_object(
                  'open', count(*) filter (where not u.on_hold and u.state = 'open'),
                  'taken', count(*) filter (where not u.on_hold and u.state = 'taken'),
                  'submitted', count(*) filter (where not u.on_hold and u.state = 'submitted'),
                  'on_hold', count(*) filter (where u.on_hold))
                from public.marking_units u join public.scripts s on s.id = u.script_id
                where u.exam_id = e.id and s.state not in ('withdrawn', 'void')),
      -- The final review's issue 4 (Ruling R30): scripts, as the card reads them beside scripts.checked.
      'checks', (select jsonb_build_object(
                   'waiting_second', count(distinct u.script_id) filter (where u.check_state = 'waiting_second'),
                   'with_lead', count(distinct u.script_id) filter (where u.check_state = 'to_lead'),
                   'stuck_second', (select count(distinct su.script_id)::int from public.marking_second_stuck(e.id) t
                                    join public.marking_units su on su.id = t.unit_id),
                   'paused_markers', (select count(*)::int from public.exam_markers x where x.exam_id = e.id and x.paused_at is not null),
                   'approved_at', m.approved_at)
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
            join public.scripts s on s.id = u.script_id
            where u.exam_id = e.id and a.kind = 'live' and a.ended_at is null and s.state not in ('withdrawn', 'void')
            union all
            select x.marker_id, 0, (x.status = 'submitted')::int, x.last_saved_at
            from public.markings x join public.marking_units u on u.id = x.unit_id
            join public.scripts s on s.id = u.script_id
            where u.exam_id = e.id and x.kind = 'live' and x.status <> 'set_aside' and s.state not in ('withdrawn', 'void')
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
-- Internal (the final review's issue 3, Ruling R27): the exams already marking when the checks arrived (see the header).
-- Returns how many exams it changed.
-- ---------------------------------------------------------------------------------------------
create function public.marking_checks_backfill()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reason constant text := 'Marked before the checks existed';
  v_m public.exam_marking%rowtype;
  v_standards uuid[];
  v_n int := 0;
  r record;
  st record;
begin
  for r in select m.exam_id from public.exam_marking m
           where m.opened_at is not null and m.approved_at is null
             and (coalesce(m.double_marking, true) or coalesce(m.seeds, true) or coalesce(m.practice, true))
           order by m.exam_id loop
    -- The structure lock, then the exam's marking row, as marking_checks_set takes them; read again under them.
    perform pg_advisory_xact_lock(hashtextextended('exam_structure:' || r.exam_id::text, 0));
    select * into v_m from public.exam_marking m where m.exam_id = r.exam_id for update;
    if v_m.approved_at is not null
       or not (coalesce(v_m.double_marking, true) or coalesce(v_m.seeds, true) or coalesce(v_m.practice, true)) then
      continue;
    end if;
    update public.exam_marking m
    set double_marking = false, seeds = false, practice = false,
      checks_off_reason = v_reason, checks_off_by = null, checks_off_at = now(), updated_at = now()
    where m.exam_id = r.exam_id;
    -- Every submitted piece is checked again with double marking off: one with no check state yet is checked on its
    -- first marks, and one waiting for a second marking is released first (marking_check_exam).
    perform public.marking_check_exam(r.exam_id);
    -- Seeded scripts or practice turned off: their standards still in use are retired, as marking_checks_set does.
    if coalesce(v_m.seeds, true) or coalesce(v_m.practice, true) then
      select coalesce(array_agg(s.id), '{}') into v_standards
      from public.marking_standards s
      where s.exam_id = r.exam_id and s.retired_at is null
        and ((s.use = 'seed' and coalesce(v_m.seeds, true)) or (s.use = 'practice' and coalesce(v_m.practice, true)));
      if cardinality(v_standards) > 0 then
        perform 1 from public.scripts s
        where s.id in (select u.script_id from public.marking_standards x join public.marking_units u on u.id = x.unit_id
                       where x.id = any (v_standards))
        order by s.id
        for no key update;
        perform 1 from public.marking_units u
        where u.id in (select x.unit_id from public.marking_standards x where x.id = any (v_standards))
        order by u.id
        for update;
        for st in select x.id, x.use from public.marking_standards x where x.id = any (v_standards) order by x.unit_id loop
          perform public.marking_standard_end(st.id, null,
            case when st.use = 'seed' then 'Seeded scripts were turned off.' else 'Practice was turned off.' end);
        end loop;
      end if;
    end if;
    insert into public.audit_log (actor_id, action, target_type, target_id, reason)
    values (null, 'marking_checks_set', 'exam', r.exam_id, v_reason);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Privileges. The internal functions are for definer callers only (the backfill for this migration); the others for
-- signed-in users (they check who). Functions made again by create or replace keep theirs (restated).
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.marking_approval_blocks(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_units_allowed(uuid, uuid, public.marking_kind, boolean, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_second_stuck(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_checks_backfill() from public, anon, authenticated, service_role;
revoke execute on function public.marking_units_list(uuid, text, uuid) from public, anon;
revoke execute on function public.marking_review_list(uuid, text) from public, anon;
revoke execute on function public.marking_dashboard(timestamptz) from public, anon;
revoke execute on function public.marking_progress(uuid, timestamptz) from public, anon;
grant execute on function public.marking_units_list(uuid, text, uuid) to authenticated;
grant execute on function public.marking_review_list(uuid, text) to authenticated;
grant execute on function public.marking_dashboard(timestamptz) to authenticated;
grant execute on function public.marking_progress(uuid, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- Once: the exams already marking when Phase 3B goes in (Ruling R27). None today: nothing is marking on the live
-- project, so it changes no row there now.
-- ---------------------------------------------------------------------------------------------
select public.marking_checks_backfill();
