-- Phase 3B Task 10: an admin approves an exam's marking.
--
-- Approval says the marking of an exam is done: every script is checked (Builder's call 15). Withdrawn and void
-- scripts do not block and are counted on the page. Approving closes marking and freezes everything about it (marks,
-- final marks, questions, check settings) until an admin withdraws the approval with a reason; marking then stays
-- closed until an admin reopens it. A script that turns up after the approval (verified, handed back or un-withdrawn)
-- is flagged on the page (stale) and never added silently: marking is closed, so it is not handed out, not checked and
-- has no final marks (Review Focus 4). Results (Phase 4) may be prepared only while exam_marking.approved_at is set,
-- and (Ruling R22) not while the approval is stale.
--
-- A seen name is always reportable (Ruling R22: the privacy anti-goal outranks the freeze): a marker's Name visible
-- (marking_name_visible) and staff's "A name still shows" (script_page_marking_name_shows) work on an approved exam as
-- before. They take the script back from the markers, so it is no longer checked and its final marks go; the approval
-- is then stale: stale is the exam approved with anything blocking it (a script arrived or changed after the approval).
--
-- A pause never strands an approval (Ruling R22): the minute job applies the pauses not applied yet on every exam whose
-- marking has opened and is not approved, a closed one too, so pause_pending clears within a minute and the paused
-- marker's scripts wait for the lead (with_lead), as on an open exam.
--
-- What blocks approval (marking_approval_blocks), on the scripts of the exam that are not withdrawn or void:
--   scripts_not_checked: scripts not checked, whatever their state (a script still with staff counts); with_staff says
--     how many of them are still with staff (receiving, checking, needs attention or verified and not handed out yet);
--   with_lead: pieces with the lead marker (to_lead);
--   waiting_second: pieces waiting for a second marker;
--   on_hold: pieces on hold;
--   alerts_open: open marking alerts;
--   pictures_to_check: scripts with a marking picture waiting for a staff check (script_pages_to_check);
--   pause_pending: markers paused on the exam whose pause the minute job has not applied yet (marking_pause_apply).
-- An open routine sample review does not block. Paid bookings of the exam with no script are counted (no_script) and
-- never block. A script in the state final (after results, Phase 4) counts as checked.
--
-- What the checks found (figures), on the same scripts:
--   pieces; second_marked and within_tolerance: the second-marked pairs the check compared, and those of them within
--     tolerance, as it recorded them (Ruling R23: marking_second_pairs, which the marker statistics use too): a pair
--     sent back and marked again is compared again (within, or outside through its new difference); a paused marker's
--     piece accepted with a second marking submitted while the lead was looking, or whose submit itself opened the
--     lead's review (an automatic pause not applied yet, Ruling R24), was never compared (Ruling R15) and counts in
--     neither; a later tolerance change moves neither (as R20 for seeds). Nothing is compared again here
--     (marking_compare per pair was too slow at 1,500 pairs);
--   settled: difference reviews closed as first_stands, second_stands or lead_marks (a lead's change of a final mark is
--     recorded as a closed sample review with outcome lead_marks, 20261123000007, and is not a settle);
--   settled_by_a_party: those settled by one of the piece's two markers (the party flag of the lead's list);
--   accepted_after_pause: paused-marker reviews closed as accepted;
--   sent_back: live markings ever sent back (Ruling R19: sent_back_note persists, to the same marker and to another);
--   final_marks_changed: pieces whose final marks the lead (or an admin) changed (marking_final_set), counted from its
--     audit rows (final_mark_changed): a change on a piece settled already records no review, so reviews undercount;
--   standards: practice and seeded scripts made (retired ones too: they were used);
--   seed_attempts and seed_outside: submitted seeded attempts, and those outside as their submit judged them (Ruling
--     R20: feedback_at set);
--   sample_reviews_open: open routine sample reviews.
--
-- The checks turned off (checks.off): who turned them off, when and why, from exam_marking.checks_off_*, as
-- marking_checks_get gives them to an admin; null when nothing is off. marking_checks_set writes them in the same
-- transaction as its audit row, from the latest change that turned a check off, and clears them once all three are on
-- again, so they are what that audit row says.
--
-- Added:
--   marking_exam_frozen(p_exam) (internal): the exam's marking is approved.
--   marking_approval_blocks(p_exam) (internal): what blocks approval, above.
--   marking_second_pairs(p_exam) (internal, Ruling R23): each second-marked pair's outcome as the check recorded it.
--   marking_approval_get(p_exam), marking_approve(p_exam, p_note), marking_approval_withdraw(p_exam, p_reason): admins.
--   Indexes: audit_log_final_mark_changed_idx (the figure above), final_marks_question_idx (the maximum rule below).
-- Changed, each from its latest definition, adding only the freeze (refused marking_approved while the exam's marking
-- is approved, read once the exam's marking row is held) and, for exam_structure_save, one more maximum rule:
--   marking_reopen (20261122000005), marking_settings_set (20261122000005), marking_take_back (20261123000004),
--   marking_assign (20261123000006), marking_script_take_back (20261123000005), marking_second_add (20261123000005),
--   marking_second_drop (20261123000005), marking_standard_set (20261123000006), marking_marker_clear
--   (20261123000006), marking_marker_pause (20261123000006), marking_checks_set (20261123000007), and (Ruling R22)
--   marking_script_hand_back (20261123000004) and marking_standard_retire (20261123000006);
--   exam_structure_save (20261123000005): frozen too, and a maximum cannot go below a final mark or a practice or
--     seeded script's mark either (final_marks, marking_standard_marks), as it cannot go below a marker's.
--   marking_tick (20261123000006): the pauses not applied yet, on closed exams that are not approved too (above),
--     visiting a closed exam only when it has one (Ruling R23); marking_exam_sync still runs on open exams only.
--   marking_pause_apply (20261123000006): nothing is done on an approved exam (Ruling R23).
--   marking_stats (20261123000008): second (compared, within, mean_gap) from marking_second_pairs (Ruling R23), so the
--     statistics and the approval page count the same pairs alike; mean_gap is still from the two totals.
-- Already frozen since 20261123000007, so not made again: marking_review_settle, marking_review_accept,
-- marking_send_back, marking_review_sample, marking_final_set. A marker's save after approval is refused marking_closed
-- (approval closes marking). Looked at and left alone (Ruling R22, the review's M4): marking_alert_release and
-- marking_alerts_release_all (only after a picture changed since the approval), marking_holds_expire (holds only),
-- marker_unapprove and marker_conflict_set (markings in progress only), marking_reassign (marking_closed undoes it).
-- Nothing else in them changed. Nothing here names a candidate.
--
-- Lock order (as 20261123000003): marker key -> exam_marking -> booking lock -> script rows in id order -> units in id
-- order -> assignments and markings -> marking_reviews -> final_marks -> exam_markers. Approving and withdrawing take
-- the exam's marking row for update first; every marking change takes it (for share or update) before it reads
-- anything it changes, so an approval and a change of the exam's marking never pass each other.

-- ---------------------------------------------------------------------------------------------
-- Indexes.
-- ---------------------------------------------------------------------------------------------
create index audit_log_final_mark_changed_idx on public.audit_log (target_id) where action = 'final_mark_changed';
create index final_marks_question_idx on public.final_marks (question_id);

-- ---------------------------------------------------------------------------------------------
-- Internal: the exam's marking is approved. Callers hold the exam's marking row.
-- ---------------------------------------------------------------------------------------------
create function public.marking_exam_frozen(p_exam uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.exam_marking m where m.exam_id = p_exam and m.approved_at is not null)
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: what blocks the exam's approval (see the header), in this order, only those with something to count:
-- [{code, count}], and scripts_not_checked also says with_staff.
-- ---------------------------------------------------------------------------------------------
create function public.marking_approval_blocks(p_exam uuid)
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
-- Internal (Ruling R23): the exam's second-marked pairs, each with its outcome as the check recorded it
-- (marking_check_evaluate, 20261123000007), for the approval page and the marker statistics alike. A pair is a piece's
-- submitted first (live) marking and its submitted second marking, on a script that is not withdrawn or void.
--   outside: a difference review of these two markings stands for their current submissions. The check opens one
--     exactly when a second marking is outside tolerance (Task 4's rule 5); a closed one counts only when closed at or
--     after both current submissions, as the check bounds a settle (a submission made again is compared again). A
--     withdrawn one, or one closed when the piece was sent back, does not: a sent-back first marking submitted again is
--     compared again, and a new review is opened if it still differs.
--   compared: outside, or the check found the pair within tolerance: the piece is checked, with no paused marker's
--     review of the first marking's current submission (a piece later made a practice or seeded script, which then
--     wants no second marking, stays compared: Ruling R24). When there is one (rule 4, open or accepted), the pair was
--     compared only if both its submissions came strictly before that review was opened (Ruling R24): a second
--     marking submitted while the lead was looking, or one whose own submit opened the review because the first
--     marker's automatic pause was still waiting for the minute job (both in one transaction, so at one time), was
--     never compared (Ruling R15: accepted without a comparison) and is compared in neither sense.
--   within: compared and not outside.
-- So the figure is the check's judgement with the tolerance of its time: a later tolerance change does not move it (as
-- Ruling R20 for seeds). Totals are given for the gap.
-- A known limit (Ruling R24, N6): the times compared are now(), a transaction's start. A pause (by hand, or the minute
-- job's) that began before a concurrent second marking's submit committed, and that waited for the script's lock,
-- opens its review dated before that submission, though the check had compared the pair by then: such a pair is
-- counted in neither. It needs the two calls to overlap on the same piece, and is rare.
-- ---------------------------------------------------------------------------------------------
create function public.marking_second_pairs(p_exam uuid)
returns table (unit_id uuid, first_id uuid, first_marker_id uuid, first_total numeric, second_id uuid, second_marker_id uuid,
  second_total numeric, compared boolean, within boolean)
language sql
stable
security definer
set search_path = ''
as $$
  with p as materialized (
    select u.id as unit_id, u.check_state,
      f.id as first_id, f.marker_id as first_marker_id, f.total as first_total, f.submitted_at as first_at,
      k.id as second_id, k.marker_id as second_marker_id, k.total as second_total, k.submitted_at as second_at
    from public.marking_units u
    join public.scripts s on s.id = u.script_id
    join public.markings f on f.unit_id = u.id and f.kind = 'live' and f.status = 'submitted'
    join public.markings k on k.unit_id = u.id and k.kind = 'second' and k.status = 'submitted'
    where u.exam_id = p_exam and s.state not in ('withdrawn', 'void')
  ),
  o as materialized (
    select p.*,
      exists (select 1 from public.marking_reviews r
              where r.exam_id = p_exam and r.unit_id = p.unit_id and r.kind = 'difference'
                and r.marking_id = p.first_id and r.second_marking_id = p.second_id
                and coalesce(r.outcome, '') not in ('withdrawn', 'sent_back')
                and (r.state = 'open' or r.closed_at >= greatest(p.first_at, p.second_at))) as outside,
      (select max(r.opened_at) from public.marking_reviews r
       where r.exam_id = p_exam and r.unit_id = p.unit_id and r.kind = 'paused_marker' and r.marking_id = p.first_id
         and (r.state = 'open' or (r.outcome = 'accepted' and r.closed_at >= p.first_at))) as paused_at
    from p
  )
  select o.unit_id, o.first_id, o.first_marker_id, o.first_total, o.second_id, o.second_marker_id, o.second_total,
    o.outside or c.found_within, not o.outside and c.found_within
  from o
  cross join lateral (
    select case when o.paused_at is not null then greatest(o.first_at, o.second_at) < o.paused_at
                else o.check_state = 'checked' end as found_within
  ) c
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_approval_get: the exam's approval page (see the header). Admins only (forbidden otherwise); invalid_input (no
-- exam); not_found. can_approve: marking has opened and nothing blocks. stale (Ruling R22): the exam is approved and
-- something blocks (a script arrived after the approval, or a name was reported, a picture changed or an alert was
-- raised on one since). Returns {ok, approved_at, approved_by_name, opened, can_approve, stale,
-- blocks: [{code, count}], scripts: {checked, withdrawn, void, other}, no_script, checks: {double_marking,
-- sample_percent, tolerance_percent, seeds, seed_every, practice, off: {reason, by_name, at}|null}, lead_name, figures:
-- {pieces, second_marked, within_tolerance, settled: {first_stands, second_stands, lead_marks}, settled_by_a_party,
-- accepted_after_pause, sent_back, final_marks_changed, standards: {practice, seed}, seed_attempts, seed_outside,
-- sample_reviews_open}}. Markers' and staff names only; no candidate's.
-- ---------------------------------------------------------------------------------------------
create function public.marking_approval_get(p_exam uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_e public.exams%rowtype;
  v_m public.exam_marking%rowtype;
  v_blocks jsonb;
  v_figures jsonb;
  v_scripts jsonb;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_e from public.exams e where e.id = p_exam;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select * into v_m from public.exam_marking m where m.exam_id = p_exam;
  v_blocks := public.marking_approval_blocks(p_exam);

  select jsonb_build_object(
    'checked', count(*) filter (where s.state in ('checked', 'final')),
    'withdrawn', count(*) filter (where s.state = 'withdrawn'),
    'void', count(*) filter (where s.state = 'void'),
    'other', count(*) filter (where s.state not in ('checked', 'final', 'withdrawn', 'void')))
  into v_scripts
  from public.scripts s where s.exam_id = p_exam;

  with s as materialized (
    select s.id from public.scripts s where s.exam_id = p_exam and s.state not in ('withdrawn', 'void')
  ),
  u as materialized (
    select u.id from public.marking_units u join s on s.id = u.script_id where u.exam_id = p_exam
  ),
  -- Ruling R23: the pairs as the check recorded them (marking_second_pairs), as the marker statistics count them.
  pairs as materialized (
    select p.compared, p.within from public.marking_second_pairs(p_exam) p
  ),
  rv as materialized (
    select r.kind, r.outcome,
      r.closed_by in (select m.marker_id from public.markings m where m.id in (r.marking_id, r.second_marking_id)) as party,
      r.state
    from public.marking_reviews r join u on u.id = r.unit_id
    where r.exam_id = p_exam
  ),
  seeds as materialized (
    select m.feedback_at is not null as outside
    from u join public.markings m on m.unit_id = u.id and m.kind = 'seed' and m.status = 'submitted'
  )
  select jsonb_build_object(
    'pieces', (select count(*)::int from u),
    'second_marked', (select count(*)::int from pairs p where p.compared),
    'within_tolerance', (select count(*)::int from pairs p where p.within),
    'settled', jsonb_build_object(
      'first_stands', (select count(*)::int from rv where rv.kind = 'difference' and rv.state = 'closed' and rv.outcome = 'first_stands'),
      'second_stands', (select count(*)::int from rv where rv.kind = 'difference' and rv.state = 'closed' and rv.outcome = 'second_stands'),
      'lead_marks', (select count(*)::int from rv where rv.kind = 'difference' and rv.state = 'closed' and rv.outcome = 'lead_marks')),
    'settled_by_a_party', (select count(*)::int from rv
                           where rv.kind = 'difference' and rv.state = 'closed'
                             and rv.outcome in ('first_stands', 'second_stands', 'lead_marks') and rv.party),
    'accepted_after_pause', (select count(*)::int from rv
                             where rv.kind = 'paused_marker' and rv.state = 'closed' and rv.outcome = 'accepted'),
    'sent_back', (select count(*)::int from u join public.markings m on m.unit_id = u.id
                  where m.kind = 'live' and m.sent_back_note is not null),
    'final_marks_changed', (select count(distinct a.target_id)::int from public.audit_log a
                            where a.action = 'final_mark_changed' and a.target_type = 'marking_unit'
                              and a.target_id in (select u.id from u)),
    'standards', jsonb_build_object(
      'practice', (select count(*)::int from public.marking_standards st join u on u.id = st.unit_id
                   where st.exam_id = p_exam and st.use = 'practice'),
      'seed', (select count(*)::int from public.marking_standards st join u on u.id = st.unit_id
               where st.exam_id = p_exam and st.use = 'seed')),
    'seed_attempts', (select count(*)::int from seeds),
    'seed_outside', (select count(*)::int from seeds where seeds.outside),
    'sample_reviews_open', (select count(*)::int from rv where rv.kind = 'sample' and rv.state = 'open'))
  into v_figures;

  return jsonb_build_object(
    'ok', true,
    'approved_at', v_m.approved_at,
    'approved_by_name', (select nullif(btrim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), '')
                         from public.profiles p where p.id = v_m.approved_by),
    'opened', v_m.opened_at is not null,
    'can_approve', v_m.opened_at is not null and jsonb_array_length(v_blocks) = 0,
    'stale', v_m.approved_at is not null and jsonb_array_length(v_blocks) > 0,
    'blocks', v_blocks,
    'scripts', v_scripts,
    'no_script', (select count(*)::int from public.bookings b
                  where b.exam_id = p_exam and b.status in ('paid', 'cancel_requested')
                    and not exists (select 1 from public.scripts s where s.booking_id = b.id)),
    'checks', jsonb_build_object(
      'double_marking', coalesce(v_m.double_marking, true),
      'sample_percent', coalesce(v_m.sample_percent, 10),
      'tolerance_percent', coalesce(v_m.tolerance_percent, 10),
      'seeds', coalesce(v_m.seeds, true),
      'seed_every', coalesce(v_m.seed_every, 10),
      'practice', coalesce(v_m.practice, true),
      'off', case when v_m.checks_off_at is not null then jsonb_build_object(
               'reason', v_m.checks_off_reason,
               'by_name', (select nullif(btrim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), '')
                           from public.profiles p where p.id = v_m.checks_off_by),
               'at', v_m.checks_off_at) end),
    'lead_name', (select nullif(btrim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), '')
                  from public.marker_approvals a join public.profiles p on p.id = a.marker_id
                  where a.subject_id = v_e.subject_id and a.lead and public.is_lead_for(a.marker_id, a.subject_id)
                  limit 1),
    'figures', v_figures);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_approve: an admin approves the exam's marking, with an optional note (given, 3 to 300 characters, trimmed:
-- Ruling R22). Refused: forbidden; invalid_input (no exam, or a note of another length); not_found; marking_not_open;
-- not_all_checked with the blocks (marking_approval_blocks). Sets approved_at and approved_by and, when marking is not
-- closed, closes it (closed_at and closed_by, the same moment and admin). Audited marking_approved: its reason is the
-- note and, when checks were turned off, "Checks turned off: {the reason}". An approved exam answers {ok, already:
-- true} and nothing is written. Returns {ok, already: false, closed} (closed: marking was closed by this approval).
-- ---------------------------------------------------------------------------------------------
create function public.marking_approve(p_exam uuid, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_given text := nullif(btrim(coalesce(p_note, '')), '');
  v_note text := public.script_resolution_reason(p_note);
  v_m public.exam_marking%rowtype;
  v_blocks jsonb;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null or (v_given is not null and v_note is null) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if not exists (select 1 from public.exams e where e.id = p_exam) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  -- The exam's marking row first (for update): every change of its marking holds it, so none passes the check below.
  select * into v_m from public.exam_marking m where m.exam_id = p_exam for update;
  if v_m.approved_at is not null then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  if v_m.opened_at is null then
    return jsonb_build_object('ok', false, 'code', 'marking_not_open');
  end if;
  v_blocks := public.marking_approval_blocks(p_exam);
  if jsonb_array_length(v_blocks) > 0 then
    return jsonb_build_object('ok', false, 'code', 'not_all_checked', 'blocks', v_blocks);
  end if;

  update public.exam_marking m
  set approved_at = now(), approved_by = v_actor,
    closed_at = coalesce(m.closed_at, now()), closed_by = case when m.closed_at is null then v_actor else m.closed_by end,
    updated_at = now()
  where m.exam_id = p_exam;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marking_approved', 'exam', p_exam,
    nullif(left(concat_ws('; ', v_note, case when v_m.checks_off_at is not null then 'Checks turned off: ' || v_m.checks_off_reason end), 600), ''));
  return jsonb_build_object('ok', true, 'already', false, 'closed', v_m.closed_at is null);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_approval_withdraw: an admin withdraws the approval, with a reason (3 to 300 characters): approved_at and
-- approved_by are cleared; marking stays closed until an admin reopens it (marking_reopen). Refused: forbidden;
-- invalid_input; reason_required; not_found. An exam not approved answers {ok, already: true} and nothing is written.
-- Audited marking_approval_withdrawn with the reason. Returns {ok, already: false}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_approval_withdraw(p_exam uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_m public.exam_marking%rowtype;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if not exists (select 1 from public.exams e where e.id = p_exam) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select * into v_m from public.exam_marking m where m.exam_id = p_exam for update;
  if v_m.approved_at is null then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  update public.exam_marking m set approved_at = null, approved_by = null, updated_at = now() where m.exam_id = p_exam;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marking_approval_withdrawn', 'exam', p_exam, v_reason);
  return jsonb_build_object('ok', true, 'already', false);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_reopen: as 20261122000005, and (3B Task 10) refused marking_approved while the exam's marking is approved
-- (an admin withdraws the approval first), once the exam's marking row is held.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_reopen(p_exam uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_m public.exam_marking%rowtype;
  v_ready int;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if not exists (select 1 from public.exams e where e.id = p_exam) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select * into v_m from public.exam_marking m where m.exam_id = p_exam for update;
  -- 3B Task 10: nothing about an approved exam's marking changes until an admin withdraws the approval.
  if public.marking_exam_frozen(p_exam) then
    return jsonb_build_object('ok', false, 'code', 'marking_approved');
  end if;
  if v_m.opened_at is null then
    return jsonb_build_object('ok', false, 'code', 'marking_not_open');
  end if;
  if v_m.closed_at is null then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  update public.exam_marking set closed_at = null, closed_by = null, updated_at = now() where exam_id = p_exam;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marking_reopened', 'exam', p_exam, v_reason);
  v_ready := public.marking_exam_sync(p_exam, null);
  return jsonb_build_object('ok', true, 'already', false, 'ready', v_ready);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_settings_set: as 20261122000005, and (3B Task 10) refused marking_approved while the exam's marking is
-- approved, once the exam's marking row is held.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_settings_set(p_exam uuid, p_mode public.marking_mode, p_deadline timestamptz, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_e public.exams%rowtype;
  v_m public.exam_marking%rowtype;
  v_mode public.marking_mode;
  v_london constant text := 'YYYY-MM-DD HH24:MI';
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null or p_mode is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_e from public.exams e where e.id = p_exam;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if p_deadline is not null and p_deadline <= v_e.starts_at + v_e.duration_minutes * interval '1 minute' then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  perform pg_advisory_xact_lock(hashtextextended('exam_structure:' || p_exam::text, 0));
  select * into v_m from public.exam_marking m where m.exam_id = p_exam for update;
  -- 3B Task 10: nothing about an approved exam's marking changes until an admin withdraws the approval.
  if public.marking_exam_frozen(p_exam) then
    return jsonb_build_object('ok', false, 'code', 'marking_approved');
  end if;
  v_mode := coalesce(v_m.mode, 'whole');
  if v_m.opened_at is not null then
    if p_mode <> v_mode then
      return jsonb_build_object('ok', false, 'code', 'conflict');
    end if;
    if p_deadline is distinct from v_m.deadline and v_reason is null then
      return jsonb_build_object('ok', false, 'code', 'reason_required');
    end if;
  end if;

  if v_m.exam_id is null or p_mode <> v_mode or p_deadline is distinct from v_m.deadline then
    insert into public.exam_marking as m (exam_id, mode, deadline, updated_at)
    values (p_exam, p_mode, p_deadline, now())
    on conflict (exam_id) do update set mode = excluded.mode, deadline = excluded.deadline, updated_at = now();
    insert into public.audit_log (actor_id, action, target_type, target_id, reason)
    values (v_actor, 'marking_settings_set', 'exam', p_exam,
      'mode ' || v_mode || ' -> ' || p_mode
      || '; deadline ' || coalesce(to_char(v_m.deadline at time zone 'Europe/London', v_london), 'none')
      || ' -> ' || coalesce(to_char(p_deadline at time zone 'Europe/London', v_london), 'none') || ' (UK time)'
      || coalesce('; reason: ' || v_reason, ''));
  end if;
  return jsonb_build_object('ok', true, 'mode', p_mode, 'deadline', p_deadline);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_checks_set: as 20261123000007, and (3B Task 10) refused marking_approved while the exam's marking is
-- approved, once the exam's marking row is held (before a save that changes nothing is answered).
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_checks_set(p_exam uuid, p_settings jsonb, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_whole constant text := '^[0-9]{1,3}$';
  v_e public.exams%rowtype;
  v_m public.exam_marking%rowtype;
  v_dm boolean;
  v_sp int;
  v_tp int;
  v_se boolean;
  v_sv int;
  v_pr boolean;
  v_was_dm boolean;
  v_was_sp int;
  v_was_tp int;
  v_was_se boolean;
  v_was_sv int;
  v_was_pr boolean;
  v_turning_off boolean;
  v_markers int;
  v_changes text[] := '{}';
  v_off_reason text;
  v_off_by uuid;
  v_off_at timestamptz;
  v_onoff constant text[] := array['off', 'on'];
  v_standards uuid[];
  r record;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null or jsonb_typeof(p_settings) is distinct from 'object'
     or jsonb_typeof(p_settings -> 'double_marking') is distinct from 'boolean'
     or jsonb_typeof(p_settings -> 'seeds') is distinct from 'boolean'
     or jsonb_typeof(p_settings -> 'practice') is distinct from 'boolean'
     or jsonb_typeof(p_settings -> 'sample_percent') is distinct from 'number' or (p_settings ->> 'sample_percent') !~ v_whole
     or jsonb_typeof(p_settings -> 'tolerance_percent') is distinct from 'number' or (p_settings ->> 'tolerance_percent') !~ v_whole
     or jsonb_typeof(p_settings -> 'seed_every') is distinct from 'number' or (p_settings ->> 'seed_every') !~ v_whole then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  v_dm := (p_settings ->> 'double_marking')::boolean;
  v_sp := (p_settings ->> 'sample_percent')::int;
  v_tp := (p_settings ->> 'tolerance_percent')::int;
  v_se := (p_settings ->> 'seeds')::boolean;
  v_sv := (p_settings ->> 'seed_every')::int;
  v_pr := (p_settings ->> 'practice')::boolean;
  if v_sp not between 1 and 100 or v_tp not between 1 and 50 or v_sv not between 3 and 50 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_e from public.exams e where e.id = p_exam;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  -- The structure lock, then the exam's marking row, as marking_settings_set and marking_open take them: the checks an
  -- opening reads are the ones saved here.
  perform pg_advisory_xact_lock(hashtextextended('exam_structure:' || p_exam::text, 0));
  select * into v_m from public.exam_marking m where m.exam_id = p_exam for update;
  -- 3B Task 10: nothing about an approved exam's marking changes until an admin withdraws the approval.
  if public.marking_exam_frozen(p_exam) then
    return jsonb_build_object('ok', false, 'code', 'marking_approved');
  end if;
  -- What is saved now: an exam never saved has the column defaults.
  v_was_dm := coalesce(v_m.double_marking, true);
  v_was_sp := coalesce(v_m.sample_percent, 10);
  v_was_tp := coalesce(v_m.tolerance_percent, 10);
  v_was_se := coalesce(v_m.seeds, true);
  v_was_sv := coalesce(v_m.seed_every, 10);
  v_was_pr := coalesce(v_m.practice, true);

  if v_dm <> v_was_dm then
    v_changes := v_changes || ('double marking ' || v_onoff[v_was_dm::int + 1] || ' -> ' || v_onoff[v_dm::int + 1]);
  end if;
  if v_sp <> v_was_sp then
    v_changes := v_changes || ('second-mark ' || v_was_sp || '% -> ' || v_sp || '%');
  end if;
  if v_tp <> v_was_tp then
    v_changes := v_changes || ('tolerance ' || v_was_tp || '% -> ' || v_tp || '%');
  end if;
  if v_se <> v_was_se then
    v_changes := v_changes || ('seeded scripts ' || v_onoff[v_was_se::int + 1] || ' -> ' || v_onoff[v_se::int + 1]);
  end if;
  if v_sv <> v_was_sv then
    v_changes := v_changes || ('seed every ' || v_was_sv || ' -> ' || v_sv);
  end if;
  if v_pr <> v_was_pr then
    v_changes := v_changes || ('practice ' || v_onoff[v_was_pr::int + 1] || ' -> ' || v_onoff[v_pr::int + 1]);
  end if;
  if cardinality(v_changes) = 0 then
    return jsonb_build_object('ok', true, 'double_marking', v_dm, 'sample_percent', v_sp, 'tolerance_percent', v_tp,
      'seeds', v_se, 'seed_every', v_sv, 'practice', v_pr);
  end if;

  -- What no reason can change is answered first.
  v_turning_off := (v_was_dm and not v_dm) or (v_was_se and not v_se) or (v_was_pr and not v_pr);
  v_markers := public.marking_subject_markers(v_e.subject_id);
  if v_turning_off and v_markers > 1 then
    return jsonb_build_object('ok', false, 'code', 'not_small_subject');
  end if;
  -- Once marking has opened, a check turned on needs what opening would have needed.
  if v_m.opened_at is not null then
    if v_dm and not v_was_dm and v_markers < 2 then
      return jsonb_build_object('ok', false, 'code', 'needs_two_markers');
    end if;
    if ((v_se and not v_was_se) or (v_pr and not v_was_pr)) and not public.marking_subject_has_lead(v_e.subject_id) then
      return jsonb_build_object('ok', false, 'code', 'no_lead');
    end if;
  end if;
  if (v_turning_off or v_m.opened_at is not null) and v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;

  -- Turned off now: this reason, by whom and when. All three on: nothing is off. Otherwise they stay as they were.
  if v_turning_off then
    v_off_reason := v_reason;
    v_off_by := v_actor;
    v_off_at := now();
  elsif not (v_dm and v_se and v_pr) then
    v_off_reason := v_m.checks_off_reason;
    v_off_by := v_m.checks_off_by;
    v_off_at := v_m.checks_off_at;
  end if;
  insert into public.exam_marking as m (exam_id, double_marking, sample_percent, tolerance_percent, seeds, seed_every, practice,
    checks_off_reason, checks_off_by, checks_off_at, updated_at)
  values (p_exam, v_dm, v_sp, v_tp, v_se, v_sv, v_pr, v_off_reason, v_off_by, v_off_at, now())
  on conflict (exam_id) do update set
    double_marking = excluded.double_marking, sample_percent = excluded.sample_percent,
    tolerance_percent = excluded.tolerance_percent, seeds = excluded.seeds, seed_every = excluded.seed_every,
    practice = excluded.practice, checks_off_reason = excluded.checks_off_reason, checks_off_by = excluded.checks_off_by,
    checks_off_at = excluded.checks_off_at, updated_at = now();
  -- 3B Task 4: double marking turned off once marking has opened: the exam's pieces are checked again. Turned on again,
  -- nothing changes: every submitted piece's decision is kept, and the others are decided when they are submitted.
  if v_m.opened_at is not null and v_was_dm and not v_dm then
    perform public.marking_check_exam(p_exam);
  end if;
  -- 3B Task 7 (Ruling R11): seeded scripts or practice turned off: their standards still in use are retired, so Next
  -- script hands out and resumes none of them and the list's left counts none. Their scripts' rows in id order, then
  -- their pieces' rows, then each standard (marking_standard_end: open attempts end, those in progress are set aside).
  if (v_was_se and not v_se) or (v_was_pr and not v_pr) then
    select coalesce(array_agg(st.id), '{}') into v_standards
    from public.marking_standards st
    where st.exam_id = p_exam and st.retired_at is null
      and ((st.use = 'seed' and v_was_se and not v_se) or (st.use = 'practice' and v_was_pr and not v_pr));
    if cardinality(v_standards) > 0 then
      perform 1 from public.scripts s
      where s.id in (select u.script_id from public.marking_standards st join public.marking_units u on u.id = st.unit_id
                     where st.id = any (v_standards))
      order by s.id
      for no key update;
      perform 1 from public.marking_units u
      where u.id in (select st.unit_id from public.marking_standards st where st.id = any (v_standards))
      order by u.id
      for update;
      for r in select st.id, st.use from public.marking_standards st where st.id = any (v_standards) order by st.unit_id loop
        perform public.marking_standard_end(r.id, v_actor,
          case when r.use = 'seed' then 'Seeded scripts were turned off.' else 'Practice was turned off.' end);
      end loop;
    end if;
  end if;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marking_checks_set', 'exam', p_exam,
    array_to_string(v_changes, '; ') || coalesce('; reason: ' || v_reason, ''));
  return jsonb_build_object('ok', true, 'double_marking', v_dm, 'sample_percent', v_sp, 'tolerance_percent', v_tp,
    'seeds', v_se, 'seed_every', v_sv, 'practice', v_pr);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- exam_structure_save: as 20261123000005, and (3B Task 10) once marking has opened, refused marking_approved while the
-- exam's marking is approved (after forbidden, once the exam's marking row is held); and a maximum cannot go below a
-- final mark (final_marks) or a practice or seeded script's mark (marking_standard_marks) either, as it cannot go
-- below a marker's (conflict).
-- ---------------------------------------------------------------------------------------------
create or replace function public.exam_structure_save(p_exam uuid, p_structure jsonb, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_e public.exams%rowtype;
  v_m public.exam_marking%rowtype;
  v_locked boolean;
  v_reason text := public.script_resolution_reason(p_reason);
  v_groups jsonb;
  v_options jsonb;
  v_qs jsonb;
  v_ids jsonb := '{}';
  v_gids jsonb;
  v_oids jsonb;
  v_added uuid[] := '{}';
  v_units uuid[];
  v_held uuid[];
  v_scripts uuid[];
  v_version int;
  v_opened timestamptz;
  v_id uuid;
  v_marker uuid;
  v_keys uuid[] := '{}';
  v_maxima text;
  v_maxima_n int := 0;
  v_reopened int := 0;
  v_summary text;
  r record;
begin
  if p_exam is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_e from public.exams e where e.id = p_exam;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if not public.structure_can_edit(v_actor, p_exam) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;

  -- One save of an exam's structure at a time. The exam's marking row (when there is one) is held from here, before
  -- the lock rules and the maximum check: a mark saved at the same moment (marking saves hold it for share), a submit
  -- and marking opening wait until this save ends.
  perform pg_advisory_xact_lock(hashtextextended('exam_structure:' || p_exam::text, 0));
  -- A question added once marking has opened may give a submitted piece back to its marker, which is a hand-out
  -- (Ruling R10): the keys of the markers who have a submitted live or second marking in this exam are taken here
  -- (shared, in uuid order), before the exam's marking row and every script row. Only a save that may add a question
  -- takes them. A piece submitted between this read and the marking row's lock is caught below, where the pieces are
  -- read.
  if exists (select 1 from public.exam_marking m where m.exam_id = p_exam and m.opened_at is not null)
     and jsonb_typeof(p_structure -> 'questions') = 'array' then
    if exists (select 1 from jsonb_array_elements(p_structure -> 'questions') e where e ->> 'id' is null) then
      for v_marker in
        select distinct m.marker_id from public.markings m join public.marking_units u on u.id = m.unit_id
        where u.exam_id = p_exam and m.kind in ('live', 'second') and m.status = 'submitted'
        order by 1
      loop
        perform pg_advisory_xact_lock_shared(hashtextextended('marker:' || v_marker::text, 0));
        v_keys := v_keys || v_marker;
      end loop;
    end if;
  end if;
  select * into v_m from public.exam_marking m where m.exam_id = p_exam for update;
  v_locked := v_m.opened_at is not null;
  if v_locked then
    if not exists (select 1 from public.profiles a where a.id = v_actor and a.status = 'active' and a.role in ('owner', 'admin')) then
      return jsonb_build_object('ok', false, 'code', 'forbidden');
    end if;
    -- 3B Task 10: nothing about an approved exam's marking changes until an admin withdraws the approval.
    if public.marking_exam_frozen(p_exam) then
      return jsonb_build_object('ok', false, 'code', 'marking_approved');
    end if;
    if v_reason is null then
      return jsonb_build_object('ok', false, 'code', 'reason_required');
    end if;
  end if;

  if not public.exam_structure_valid(p_structure, public.exam_structure_pages(p_exam)) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  v_groups := coalesce(p_structure -> 'groups', '[]');
  v_options := coalesce(p_structure -> 'option_groups', '[]');
  v_qs := p_structure -> 'questions';
  -- A question sent with an id must be one of this exam's.
  if exists (select 1 from jsonb_array_elements(v_qs) e
             where e ->> 'id' is not null
               and not exists (select 1 from public.exam_questions x where x.id = (e ->> 'id')::uuid and x.exam_id = p_exam)) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  if v_locked then
    -- Only the changes of Builder's call 11.
    if exists (
         with q as (
           select (e ->> 'id')::uuid as id, e ->> 'key' as key, e ->> 'parent_key' as parent_key,
             (e ->> 'mark_step')::numeric as mark_step, (e ->> 'levels')::boolean as levels,
             e ->> 'group_key' as group_key, e ->> 'option_group_key' as option_group_key
           from jsonb_array_elements(v_qs) e
         )
         -- a question removed
         select 1 from public.exam_questions x where x.exam_id = p_exam and not exists (select 1 from q where q.id = x.id)
         union all
         -- a question moved, given parts or a different step or levels; a question changing group or optional rule
         select 1 from q join public.exam_questions x on x.id = q.id
         where x.parent_id is distinct from (select p.id from q p where p.key = q.parent_key)
            or (x.max_mark is null) <> exists (select 1 from q c where c.parent_key = q.key)
            or x.mark_step <> q.mark_step or x.levels <> q.levels
            or (select g.label from public.question_groups g where g.id = x.group_id)
               is distinct from (select btrim(g ->> 'label') from jsonb_array_elements(v_groups) g where g ->> 'key' = q.group_key)
            or (select o.label from public.exam_option_groups o where o.id = x.option_group_id)
               is distinct from (select btrim(o ->> 'label') from jsonb_array_elements(v_options) o where o ->> 'key' = q.option_group_key)
         union all
         -- a new question made optional, or (marked by question) a new question without a group
         select 1 from q where q.id is null
           and (q.option_group_key is not null or (v_m.mode = 'by_question' and q.parent_key is null and q.group_key is null))
         union all
         -- the groups or the optional questions changed
         select 1 where (select array_agg(g.label order by g.label) from public.question_groups g where g.exam_id = p_exam)
                        is distinct from (select array_agg(btrim(g ->> 'label') order by btrim(g ->> 'label')) from jsonb_array_elements(v_groups) g)
         union all
         select 1 where (select array_agg(o.label || '|' || o.choose order by o.label || '|' || o.choose) from public.exam_option_groups o where o.exam_id = p_exam)
                        is distinct from (select array_agg(btrim(o ->> 'label') || '|' || (o ->> 'choose') order by btrim(o ->> 'label') || '|' || (o ->> 'choose'))
                                          from jsonb_array_elements(v_options) o)) then
      return jsonb_build_object('ok', false, 'code', 'structure_locked');
    end if;
    -- A maximum cannot go below a mark already given: a marker's, and (3B Task 10) a final mark or a practice or seeded
    -- script's mark.
    if exists (
         select 1 from jsonb_array_elements(v_qs) e
         join public.question_marks m on m.question_id = (e ->> 'id')::uuid
         where e ->> 'id' is not null and m.mark > (e ->> 'max_mark')::numeric)
       or exists (
         select 1 from jsonb_array_elements(v_qs) e
         join public.final_marks f on f.question_id = (e ->> 'id')::uuid
         where e ->> 'id' is not null and f.mark > (e ->> 'max_mark')::numeric)
       or exists (
         select 1 from jsonb_array_elements(v_qs) e
         join public.marking_standard_marks sm on sm.question_id = (e ->> 'id')::uuid
         where e ->> 'id' is not null and sm.mark > (e ->> 'max_mark')::numeric) then
      return jsonb_build_object('ok', false, 'code', 'conflict');
    end if;
    -- What this save changes, for the audit row: the maxima that change, by the question's label as printed (the
    -- first five, in paper order, then how many more).
    with recursive t as (
      select q.id, q.label::text as label, array[q.position] as path
      from public.exam_questions q where q.exam_id = p_exam and q.parent_id is null
      union all
      select c.id, t.label || '(' || c.label || ')', t.path || c.position
      from t join public.exam_questions c on c.parent_id = t.id
    ),
    changed as (
      select t.label, x.max_mark as was, (e ->> 'max_mark')::numeric as now, row_number() over (order by t.path) as n
      from jsonb_array_elements(v_qs) e
      join public.exam_questions x on x.id = (e ->> 'id')::uuid
      join t on t.id = x.id
      where e ->> 'id' is not null and x.max_mark is distinct from (e ->> 'max_mark')::numeric
    )
    select count(*)::int,
      string_agg('maximum ' || c.label || ' ' || coalesce(trim_scale(c.was)::text, 'none') || ' -> ' || coalesce(trim_scale(c.now)::text, 'none'),
                 '; ' order by c.n) filter (where c.n <= 5)
    into v_maxima_n, v_maxima
    from changed c;
  end if;

  -- The new version, which also holds the exam's marking row until this save ends. Should marking have opened since
  -- the structure was read as unlocked, nothing is saved.
  insert into public.exam_marking as m (exam_id, structure_version, updated_at)
  values (p_exam, 1, now())
  on conflict (exam_id) do update set structure_version = m.structure_version + 1, updated_at = now()
  returning m.structure_version, m.opened_at into v_version, v_opened;
  if v_opened is not null and not v_locked then
    raise exception 'marking opened while the structure was being saved' using errcode = '40001';
  end if;

  -- Groups and optional questions, matched by label: kept, added, or (before opening) deleted.
  update public.exam_questions set group_id = null, option_group_id = null, parent_id = null where exam_id = p_exam;
  delete from public.question_groups g
  where g.exam_id = p_exam and g.label not in (select btrim(x ->> 'label') from jsonb_array_elements(v_groups) x);
  update public.question_groups g set position = x.n
  from jsonb_array_elements(v_groups) with ordinality x(j, n)
  where g.exam_id = p_exam and g.label = btrim(x.j ->> 'label');
  insert into public.question_groups (exam_id, label, position)
  select p_exam, btrim(x.j ->> 'label'), x.n from jsonb_array_elements(v_groups) with ordinality x(j, n)
  where not exists (select 1 from public.question_groups g where g.exam_id = p_exam and g.label = btrim(x.j ->> 'label'));
  select coalesce(jsonb_object_agg(x ->> 'key', g.id), '{}') into v_gids
  from jsonb_array_elements(v_groups) x join public.question_groups g on g.exam_id = p_exam and g.label = btrim(x ->> 'label');

  delete from public.exam_option_groups o
  where o.exam_id = p_exam and o.label not in (select btrim(x ->> 'label') from jsonb_array_elements(v_options) x);
  update public.exam_option_groups o set choose = (x ->> 'choose')::int
  from jsonb_array_elements(v_options) x
  where o.exam_id = p_exam and o.label = btrim(x ->> 'label');
  insert into public.exam_option_groups (exam_id, label, choose)
  select p_exam, btrim(x ->> 'label'), (x ->> 'choose')::int from jsonb_array_elements(v_options) x
  where not exists (select 1 from public.exam_option_groups o where o.exam_id = p_exam and o.label = btrim(x ->> 'label'));
  select coalesce(jsonb_object_agg(x ->> 'key', o.id), '{}') into v_oids
  from jsonb_array_elements(v_options) x join public.exam_option_groups o on o.exam_id = p_exam and o.label = btrim(x ->> 'label');

  -- Questions: those not sent are deleted (never once marking has opened: refused above), the others kept or added,
  -- parents first; their marking points are replaced.
  delete from public.exam_questions x
  where x.exam_id = p_exam
    and x.id not in (select (e ->> 'id')::uuid from jsonb_array_elements(v_qs) e where e ->> 'id' is not null);
  delete from public.mark_scheme_points p using public.exam_questions x where x.id = p.question_id and x.exam_id = p_exam;
  for r in
    with recursive q as (
      select e, o, e ->> 'key' as key, e ->> 'parent_key' as parent_key from jsonb_array_elements(v_qs) with ordinality t(e, o)
    ),
    tree as (
      select q.key, 1 as depth from q where q.parent_key is null
      union all
      select c.key, t.depth + 1 from q c join tree t on c.parent_key = t.key
    )
    select q.e, q.key, q.parent_key, tree.depth,
      row_number() over (partition by q.parent_key order by q.o) as position,
      exists (select 1 from q c where c.parent_key = q.key) as has_parts
    from q join tree on tree.key = q.key
    order by tree.depth, q.o
  loop
    if r.e ->> 'id' is null then
      insert into public.exam_questions (exam_id, label, position) values (p_exam, btrim(r.e ->> 'label'), r.position)
      returning id into v_id;
      if not r.has_parts then
        v_added := v_added || v_id;
      end if;
    else
      v_id := (r.e ->> 'id')::uuid;
    end if;
    update public.exam_questions set
      parent_id = (v_ids ->> r.parent_key)::uuid,
      label = btrim(r.e ->> 'label'),
      position = r.position,
      max_mark = (r.e ->> 'max_mark')::numeric,
      mark_step = (r.e ->> 'mark_step')::numeric,
      levels = (r.e ->> 'levels')::boolean,
      pages = coalesce((select array_agg((p #>> '{}')::int order by o) from jsonb_array_elements(r.e -> 'pages') with ordinality t(p, o)), '{}'),
      areas = coalesce((select jsonb_agg(jsonb_build_object('page', (a ->> 'page')::int, 'x', (a ->> 'x')::numeric, 'y', (a ->> 'y')::numeric,
                                                            'w', (a ->> 'w')::numeric, 'h', (a ->> 'h')::numeric) order by o)
                        from jsonb_array_elements(r.e -> 'areas') with ordinality t(a, o)), '[]'),
      group_id = (v_gids ->> (r.e ->> 'group_key'))::uuid,
      option_group_id = (v_oids ->> (r.e ->> 'option_group_key'))::uuid,
      guidance = nullif(btrim(r.e ->> 'guidance'), ''),
      alternatives = nullif(btrim(r.e ->> 'alternatives'), ''),
      updated_at = now()
    where id = v_id;
    insert into public.mark_scheme_points (question_id, position, label, marks, marks_to, text)
    select v_id, o, nullif(btrim(p ->> 'label'), ''), (p ->> 'marks')::numeric, (p ->> 'marks_to')::numeric, btrim(p ->> 'text')
    from jsonb_array_elements(coalesce(r.e -> 'points', '[]')) with ordinality t(p, o);
    v_ids := v_ids || jsonb_build_object(r.key, v_id);
  end loop;

  -- A question added once marking has opened: the submitted live and second markings of the pieces that include it (the
  -- whole script, or the group of its top-level question) of scripts still being marked (not withdrawn or void) are
  -- reopened; their pieces (by their live marking) are being marked again, and so are their scripts. A marking goes
  -- back to the same marker when they may still mark it (is_marker_for: an active, approved marker of the subject; and
  -- not blocked for the candidate), with an assigned hold of its kind. Otherwise that marking is set aside (unapproved,
  -- or conflict when blocked) and given to nobody; a live one's piece is open again for anyone, so no hold is left
  -- stranded. The recheck triggers work out each piece's check again.
  if v_locked and cardinality(v_added) > 0 then
    -- The rows of the scripts whose pieces include the new question are held first, in id order (Ruling R9), and
    -- only then are their states and pieces read: a booking cancelled or a script voided at the same moment has either
    -- finished (the script is withdrawn or void and left alone) or waits until this save ends.
    with recursive up as (
      select q.id, q.parent_id, q.group_id from public.exam_questions q where q.id = any (v_added)
      union all
      select p.id, p.parent_id, p.group_id from up join public.exam_questions p on p.id = up.parent_id
    )
    select coalesce(array_agg(distinct u.script_id order by u.script_id), '{}') into v_held
    from public.marking_units u
    where u.exam_id = p_exam
      and (u.group_id is null or u.group_id in (select up.group_id from up where up.parent_id is null));
    perform 1 from public.scripts s where s.id = any (v_held) order by s.id for no key update;

    with recursive up as (
      select q.id, q.parent_id, q.group_id from public.exam_questions q where q.id = any (v_added)
      union all
      select p.id, p.parent_id, p.group_id from up join public.exam_questions p on p.id = up.parent_id
    )
    select coalesce(array_agg(u.id), '{}') into v_units
    from public.marking_units u
    join public.scripts s on s.id = u.script_id
    where u.exam_id = p_exam
      and s.id = any (v_held)
      and s.state not in ('withdrawn', 'void')
      and (u.group_id is null or u.group_id in (select up.group_id from up where up.parent_id is null));

    -- Every marker whose marking may go back to them must have had their key taken above. One who submitted since
    -- (before this save held the exam's marking row) was not: nothing is saved, and the save is tried again.
    if exists (select 1 from public.markings m
               where m.unit_id = any (v_units) and m.kind in ('live', 'second') and m.status = 'submitted'
                 and not (m.marker_id = any (v_keys))) then
      raise exception 'a piece was submitted while the structure was being saved' using errcode = '40001';
    end if;

    with pieces as (
      select m.id as marking_id, m.unit_id, m.kind, m.marker_id, u.script_id,
        public.is_marker_for(m.marker_id, v_e.subject_id) as approved,
        -- A marker who saw a name on the piece (a name_seen exclusion, Name visible) is not given it again: as a block.
        public.marking_marker_blocked(m.marker_id, b.student_id)
          or exists (select 1 from public.marking_unit_exclusions x where x.unit_id = m.unit_id and x.marker_id = m.marker_id) as blocked,
        exists (select 1 from public.marking_unit_exclusions x where x.unit_id = m.unit_id and x.marker_id = m.marker_id) as name_seen
      from public.markings m
      join public.marking_units u on u.id = m.unit_id
      join public.scripts s on s.id = u.script_id
      join public.bookings b on b.id = s.booking_id
      where m.unit_id = any (v_units) and m.kind in ('live', 'second') and m.status = 'submitted'
        and s.state not in ('withdrawn', 'void')
    ),
    reopened as (
      update public.markings m set status = 'in_progress', submitted_at = null
      from pieces p where m.id = p.marking_id and p.approved and not p.blocked
      returning m.unit_id, m.kind, m.marker_id
    ),
    set_aside as (
      update public.markings m
      set status = 'set_aside', set_aside_at = now(),
        set_aside_reason = case when p.name_seen then 'name_seen' when p.blocked then 'conflict' else 'unapproved' end
      from pieces p where m.id = p.marking_id and not (p.approved and not p.blocked)
      returning m.id
    ),
    units as (
      update public.marking_units u set state = case when p.approved and not p.blocked then 'taken' else 'open' end
      from pieces p where u.id = p.unit_id and p.kind = 'live'
      returning u.script_id
    ),
    assigned as (
      insert into public.marking_assignments (unit_id, kind, marker_id, how, assigned_by)
      select ro.unit_id, ro.kind, ro.marker_id, 'assigned', v_actor from reopened ro
      where ro.kind = 'live'
         or not exists (select 1 from public.marking_assignments a where a.unit_id = ro.unit_id and a.kind = ro.kind and a.ended_at is null)
    )
    select coalesce(array_agg(distinct units.script_id order by units.script_id), '{}'), count(*)::int
    into v_scripts, v_reopened from units;
    -- Each reopened script's state follows its units (a marked or checked script is being marked again).
    foreach v_id in array v_scripts loop
      perform public.marking_script_state(v_id);
    end loop;
  end if;

  -- After the lock the audit row also says what changed, after the reason: "(maximum 2(b) 5 -> 6; 1 question added;
  -- 3 pieces reopened)". A question added is one that takes marks (a part counts, a heading for parts does not).
  if v_locked then
    v_summary := concat_ws('; ',
      v_maxima,
      case when v_maxima_n > 5 then (v_maxima_n - 5) || ' more ' || case when v_maxima_n = 6 then 'maximum' else 'maxima' end || ' changed' end,
      case when cardinality(v_added) > 0
           then cardinality(v_added) || case when cardinality(v_added) = 1 then ' question added' else ' questions added' end end,
      case when cardinality(v_added) > 0
           then v_reopened || case when v_reopened = 1 then ' piece reopened' else ' pieces reopened' end end);
    v_reason := left(v_reason || ' (' || coalesce(nullif(v_summary, ''), 'no maximum changed and no question added') || ')', 600);
  end if;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, case when v_locked then 'exam_structure_changed_after_lock' else 'exam_structure_saved' end, 'exam', p_exam, v_reason);
  return jsonb_build_object('ok', true, 'version', v_version, 'max_total', public.exam_structure_max_total(p_exam));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_take_back: as 20261123000004, and (3B Task 10) refused marking_approved when the marking of an exam of the
-- pieces is approved, once their rows are held (marking_units_lock): nothing is taken back.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_take_back(p_units uuid[], p_reason text, p_kind public.marking_kind default 'live')
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
  -- 3B Task 10: nothing about an approved exam's marking changes until an admin withdraws the approval.
  if exists (select 1 from (select distinct u.exam_id from public.marking_units u where u.id = any (v_units)) x
             where public.marking_exam_frozen(x.exam_id)) then
    return jsonb_build_object('ok', false, 'code', 'marking_approved');
  end if;
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
-- marking_assign: as 20261123000006, and (3B Task 10) refused marking_approved when the marking of an exam of the
-- pieces is approved, once their rows are held (marking_units_lock): nothing is assigned.
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
  -- 3B Task 10: nothing about an approved exam's marking changes until an admin withdraws the approval.
  if exists (select 1 from (select distinct u.exam_id from public.marking_units u where u.id = any (v_units)) x
             where public.marking_exam_frozen(x.exam_id)) then
    return jsonb_build_object('ok', false, 'code', 'marking_approved');
  end if;
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
-- marking_script_take_back: as 20261123000005, and (3B Task 10) refused marking_approved while the exam's marking is
-- approved, once the script's locks are held (marking_script_lock).
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_script_take_back(p_script uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_x public.scripts%rowtype;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_script is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if not exists (select 1 from public.scripts s where s.id = p_script) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  perform public.marking_script_lock(p_script);
  select * into v_x from public.scripts s where s.id = p_script;
  -- 3B Task 10: nothing about an approved exam's marking changes until an admin withdraws the approval.
  if public.marking_exam_frozen(v_x.exam_id) then
    return jsonb_build_object('ok', false, 'code', 'marking_approved');
  end if;
  if v_x.taken_back_at is not null then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'taken_back');
  end if;
  if v_x.state not in ('ready_to_mark', 'marking', 'marked', 'checked') then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'not_marking');
  end if;
  perform public.marking_script_take_back_as(p_script, v_actor, v_reason);
  select * into v_x from public.scripts s where s.id = p_script;
  return jsonb_build_object('ok', true, 'state', v_x.state);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_second_add: as 20261123000005, and (3B Task 10) refused marking_approved when the marking of an exam of the
-- pieces is approved, once their rows are held (marking_units_lock): nothing is added.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_second_add(p_units uuid[], p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_admin boolean := public.is_staff_admin();
  v_reason text := public.script_resolution_reason(p_reason);
  v_units uuid[];
  v_why text;
  v_n int := 0;
  v_skipped jsonb := '[]';
  r record;
begin
  if not v_admin and not exists (select 1 from public.marker_approvals a
                                 where a.marker_id = v_actor and a.lead and public.is_lead_for(v_actor, a.subject_id)) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select coalesce(array_agg(distinct x), '{}') into v_units from unnest(coalesce(p_units, '{}')) x where x is not null;
  if cardinality(v_units) not between 1 and 200 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;

  -- Ruling R9: the exams' marking rows, the scripts' rows in id order, the pieces' rows in id order.
  perform public.marking_units_lock(v_units);
  -- 3B Task 10: nothing about an approved exam's marking changes until an admin withdraws the approval.
  if exists (select 1 from (select distinct u.exam_id from public.marking_units u where u.id = any (v_units)) x
             where public.marking_exam_frozen(x.exam_id)) then
    return jsonb_build_object('ok', false, 'code', 'marking_approved');
  end if;
  for r in
    select x.id, u.id as unit_id, u.check_state, u.second_wanted, e.subject_id, b.student_id, m.closed_at,
      exists (select 1 from public.markings k where k.unit_id = u.id and k.kind = 'live' and k.status = 'submitted') as submitted
    from unnest(v_units) x(id)
    left join public.marking_units u on u.id = x.id
    left join public.exams e on e.id = u.exam_id
    left join public.scripts s on s.id = u.script_id
    left join public.bookings b on b.id = s.booking_id
    left join public.exam_marking m on m.exam_id = u.exam_id
    order by u.script_id, x.id
  loop
    v_why := case
      when r.unit_id is null then 'not_found'
      when not v_admin and not public.is_lead_for(v_actor, r.subject_id) then 'forbidden'
      when not v_admin and public.marking_marker_blocked(v_actor, r.student_id) then 'conflict_of_interest'
      when r.closed_at is not null then 'marking_closed'
      when not r.submitted then 'not_submitted'
      when public.marking_unit_settled(r.unit_id) then 'settled'
      when r.check_state = 'to_lead' then 'with_lead'
      when coalesce(r.second_wanted, false) then 'already'
    end;
    if v_why is not null then
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('unit_id', r.id, 'code', v_why));
      continue;
    end if;
    update public.marking_units u set second_wanted = true where u.id = r.unit_id;
    perform public.marking_check_evaluate(r.unit_id);
    insert into public.audit_log (actor_id, action, target_type, target_id, reason)
    values (v_actor, 'marking_second_added', 'marking_unit', r.unit_id, v_reason);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'added', v_n, 'skipped', v_skipped);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_second_drop: as 20261123000005, and (3B Task 10) refused marking_approved when the marking of an exam of the
-- pieces is approved, once their rows are held (marking_units_lock): nothing is dropped.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_second_drop(p_units uuid[], p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_admin boolean := public.is_staff_admin();
  v_reason text := public.script_resolution_reason(p_reason);
  v_units uuid[];
  v_why text;
  v_n int := 0;
  v_skipped jsonb := '[]';
  r record;
begin
  if not v_admin and not exists (select 1 from public.marker_approvals a
                                 where a.marker_id = v_actor and a.lead and public.is_lead_for(v_actor, a.subject_id)) then
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
  -- 3B Task 10: nothing about an approved exam's marking changes until an admin withdraws the approval.
  if exists (select 1 from (select distinct u.exam_id from public.marking_units u where u.id = any (v_units)) x
             where public.marking_exam_frozen(x.exam_id)) then
    return jsonb_build_object('ok', false, 'code', 'marking_approved');
  end if;
  for r in
    select x.id, u.id as unit_id, u.check_state, e.subject_id, b.student_id
    from unnest(v_units) x(id)
    left join public.marking_units u on u.id = x.id
    left join public.exams e on e.id = u.exam_id
    left join public.scripts s on s.id = u.script_id
    left join public.bookings b on b.id = s.booking_id
    order by u.script_id, x.id
  loop
    v_why := case
      when r.unit_id is null then 'not_found'
      when not v_admin and not public.is_lead_for(v_actor, r.subject_id) then 'forbidden'
      when not v_admin and public.marking_marker_blocked(v_actor, r.student_id) then 'conflict_of_interest'
      when r.check_state is distinct from 'waiting_second' then 'not_waiting'
    end;
    if v_why is not null then
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('unit_id', r.id, 'code', v_why));
      continue;
    end if;
    perform public.marking_second_release(r.unit_id, v_reason);
    perform public.marking_check_evaluate(r.unit_id);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'dropped', v_n, 'skipped', v_skipped);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_standard_set: as 20261123000006, and (3B Task 10) refused marking_approved while the exam's marking is
-- approved, once the exam's marking row is held (before not_yours).
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_standard_set(p_unit uuid, p_use text, p_note text default null)
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
  -- 3B Task 10: nothing about an approved exam's marking changes until an admin withdraws the approval.
  if public.marking_exam_frozen(v_u.exam_id) then
    return jsonb_build_object('ok', false, 'code', 'marking_approved');
  end if;
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
-- marking_marker_clear: as 20261123000006, and (3B Task 10) refused marking_approved while the exam's marking is
-- approved, once the marker's key and the exam's marking row are held (before a pause is applied).
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_marker_clear(p_exam uuid, p_marker uuid, p_reason text)
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
  -- 3B Task 10: nothing about an approved exam's marking changes until an admin withdraws the approval.
  if public.marking_exam_frozen(p_exam) then
    return jsonb_build_object('ok', false, 'code', 'marking_approved');
  end if;
  v_every := coalesce(v_every, 10);
  -- A pause the minute job has not applied yet is applied first: the scripts its email said wait for the lead marker
  -- go to the lead before the marker works again.
  if exists (select 1 from public.exam_markers x where x.exam_id = p_exam and x.marker_id = p_marker
             and x.paused_at is not null and x.pause_applied_at is null) then
    perform public.marking_pause_apply(p_exam, p_marker);
  end if;
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
-- marking_marker_pause: as 20261123000006, and (3B Task 10) refused marking_approved while the exam's marking is
-- approved, once the marker's key and the exam's marking row are held.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_marker_pause(p_exam uuid, p_marker uuid, p_reason text)
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
  -- 3B Task 10: nothing about an approved exam's marking changes until an admin withdraws the approval.
  if public.marking_exam_frozen(p_exam) then
    return jsonb_build_object('ok', false, 'code', 'marking_approved');
  end if;
  insert into public.exam_markers as x (exam_id, marker_id, paused_at) values (p_exam, p_marker, now())
  on conflict (exam_id, marker_id) do update set paused_at = coalesce(x.paused_at, now()), pause_applied_at = null;
  perform public.marking_pause_apply(p_exam, p_marker);
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marker_paused', 'marker', p_marker, public.marker_audit_reason(v_reason, 'exam: ' || p_exam::text));
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_script_hand_back: as 20261123000004, and (3B Task 10, Ruling R22) refused marking_approved while the exam's
-- marking is approved, once the script's locks are held (marking_script_lock): a script taken back after the approval
-- (a name reported) is handed back only once an admin has withdrawn it.
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
  -- 3B Task 10: nothing about an approved exam's marking changes until an admin withdraws the approval.
  if public.marking_exam_frozen(v_x.exam_id) then
    return jsonb_build_object('ok', false, 'code', 'marking_approved');
  end if;
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
-- marking_standard_retire: as 20261123000006, and (3B Task 10, Ruling R22) refused marking_approved while the exam's
-- marking is approved, once the exam's marking row is held.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_standard_retire(p_standard uuid, p_reason text)
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
  -- 3B Task 10: nothing about an approved exam's marking changes until an admin withdraws the approval.
  if public.marking_exam_frozen(v_u.exam_id) then
    return jsonb_build_object('ok', false, 'code', 'marking_approved');
  end if;
  perform 1 from public.scripts s where s.id = v_u.script_id for no key update;
  perform 1 from public.marking_units u where u.id = v_u.id for update;
  if not public.marking_standard_end(p_standard, v_actor, v_reason) then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'retired');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the minute job, as 20261123000006, and (3B Task 10, Ruling R22) the pauses not applied yet are applied on
-- every exam whose marking has opened and is not approved, a closed one too, so a pause never strands an approval
-- (pause_pending clears within a minute); only an exam whose marking is open is synced. The marker's key is still only
-- tried, before the pause takes the exam's row.
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
  -- 3B Task 10 (Rulings R22, R23): every exam whose marking is open, and every closed one that is not approved and has a
  -- pause not applied yet (its pauses only).
  for r in select m.exam_id, m.closed_at is null as is_open from public.exam_marking m
           where m.opened_at is not null and m.approved_at is null
             and (m.closed_at is null
                  or exists (select 1 from public.exam_markers x
                             where x.exam_id = m.exam_id and x.paused_at is not null and x.pause_applied_at is null))
           order by m.exam_id loop
    -- One exam's failure is its own: what it did is undone, the others still run, and the next minute tries it again.
    -- The log line names the exam and the error's SQLSTATE only: an error's message can quote a row.
    begin
      if r.is_open then
        perform public.marking_exam_sync(r.exam_id, null);
      end if;
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
-- marking_stats: as 20261123000008, and (3B Task 10, Ruling R23) second (compared, within, mean_gap) counts the pairs
-- as the check recorded them (marking_second_pairs): a pair is compared when the check evaluated both of its current
-- submissions, and within unless a difference review of them stands; mean_gap is still from the two totals, of the
-- pairs compared. marking_compare is no longer called per pair. Nothing else in it changed.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_stats(p_exam uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin boolean := public.is_staff_admin();
  v_subject bigint;
  v_tol int;
  v_out jsonb;
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
  v_tol := coalesce((select m.tolerance_percent from public.exam_marking m where m.exam_id = p_exam), 10);

  with
  -- What a piece is out of, once per question group: every piece of a group holds the same questions. Materialized, so
  -- the maximum is worked out once per group, not once per marking it is joined to.
  maxes as materialized (
    select g.group_id, public.marking_unit_max_total(g.id) as max_total
    from (select distinct on (u.group_id) u.group_id, u.id from public.marking_units u
          where u.exam_id = p_exam order by u.group_id, u.id) g
  ),
  -- The exam's markings, on scripts that are not withdrawn or void.
  mk as materialized (
    select m.id, m.unit_id, m.kind, m.marker_id, m.status, m.total, m.active_seconds, m.sent_back_note is not null as sent_back,
      m.feedback_at is not null as feedback_shown, u.group_id, x.max_total
    from public.marking_units u
    join public.scripts s on s.id = u.script_id
    join public.markings m on m.unit_id = u.id
    join maxes x on x.group_id is not distinct from u.group_id
    where u.exam_id = p_exam and s.state not in ('withdrawn', 'void')
  ),
  -- The pieces: submitted live markings, each as a percentage of its maximum.
  live as materialized (
    select k.marker_id, k.group_id, k.total * 100.0 / nullif(k.max_total, 0) as pct, k.total >= k.max_total as at_max
    from mk k where k.kind = 'live' and k.status = 'submitted'
  ),
  piece_stats as (
    select l.marker_id, count(*)::int as n, avg(l.pct) as mean, count(*) filter (where l.at_max)::int as at_max
    from live l group by l.marker_id
  ),
  group_mean as (
    select l.group_id, avg(l.pct) as mean, count(distinct l.marker_id) as markers from live l group by l.group_id
  ),
  cohort as (
    select b.marker_id, sum(b.n * g.mean) / nullif(sum(b.n), 0) as mean, bool_or(g.markers > 1) as has_others
    from (select l.marker_id, l.group_id, count(l.pct) as n from live l group by l.marker_id, l.group_id) b
    join group_mean g on g.group_id is not distinct from b.group_id
    group by b.marker_id
  ),
  -- First and second markings of a piece, both submitted, that the check compared, as it recorded them (3B Task 10,
  -- Ruling R23: marking_second_pairs, as the approval page counts them); the gap is still from the two totals.
  pairs as materialized (
    select p.first_marker_id as first_id, p.second_marker_id as second_id, abs(p.first_total - p.second_total) as gap,
      p.within
    from public.marking_second_pairs(p_exam) p
    where p.compared
  ),
  agreement as (
    select r.marker_id, count(*)::int as compared, count(*) filter (where r.within)::int as within, avg(r.gap) as gap
    from (select p.first_id as marker_id, p.gap, p.within from pairs p
          union all
          select p.second_id, p.gap, p.within from pairs p) r
    group by r.marker_id
  ),
  -- A seed as its submit judged it (no feedback shown: within); practice compared now.
  attempts as materialized (
    select k.marker_id, k.kind, count(*)::int as done,
      count(*) filter (where case when k.kind = 'seed' then not k.feedback_shown
                                  else coalesce((public.marking_standard_compare(k.id) ->> 'within')::boolean, false)
                             end)::int as within
    from mk k where k.kind in ('seed', 'practice') and k.status = 'submitted'
    group by k.marker_id, k.kind
  ),
  speed as (
    select k.marker_id, percentile_cont(0.5) within group (order by k.active_seconds) as median
    from mk k where k.kind in ('live', 'second') and k.status = 'submitted'
    group by k.marker_id
  ),
  exam_speed as (
    select percentile_cont(0.5) within group (order by k.active_seconds) as median
    from mk k where k.kind in ('live', 'second') and k.status = 'submitted'
  ),
  sent as (
    select k.marker_id, count(*)::int as n from mk k where k.kind = 'live' and k.sent_back group by k.marker_id
  ),
  who as (
    select distinct k.marker_id from mk k
    where (k.status = 'submitted' and k.kind in ('live', 'second', 'seed', 'practice')) or (k.kind = 'live' and k.sent_back)
  ),
  per_marker as (
    select w.marker_id,
      nullif(btrim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), '') as name,
      coalesce(ps.n, 0) as pieces, coalesce(ps.at_max, 0) as at_max,
      round(ps.mean, 1) as mean_percent, round(c.mean, 1) as cohort_mean_percent,
      coalesce(c.has_others, false) as cohort_has_others, round(ps.mean, 1) - round(c.mean, 1) as difference,
      a.compared, a.within, round(a.gap, 1) as mean_gap,
      sd.done as seeds_done, sd.within as seeds_within, pr.done as practice_done, pr.within as practice_within,
      sp.median, coalesce(sb.n, 0) as sent_back
    from who w
    join public.profiles p on p.id = w.marker_id
    left join piece_stats ps on ps.marker_id = w.marker_id
    left join cohort c on c.marker_id = w.marker_id
    left join agreement a on a.marker_id = w.marker_id
    left join attempts sd on sd.marker_id = w.marker_id and sd.kind = 'seed'
    left join attempts pr on pr.marker_id = w.marker_id and pr.kind = 'practice'
    left join speed sp on sp.marker_id = w.marker_id
    left join sent sb on sb.marker_id = w.marker_id
  )
  select jsonb_build_object(
    'ok', true,
    'tolerance_percent', v_tol,
    'exam', jsonb_build_object(
      'pieces', (select count(*)::int from live),
      'mean_percent', (select round(avg(l.pct), 1) from live l),
      'median_seconds', (select round(e.median)::int from exam_speed e)),
    'markers', coalesce((
      select jsonb_agg(jsonb_build_object(
          'marker_id', r.marker_id, 'name', r.name, 'pieces', r.pieces,
          'mean_percent', r.mean_percent, 'cohort_mean_percent', r.cohort_mean_percent, 'cohort_has_others', r.cohort_has_others,
          'difference', r.difference,
          'second', jsonb_build_object('compared', coalesce(r.compared, 0), 'within', coalesce(r.within, 0), 'mean_gap', r.mean_gap),
          'seeds', jsonb_build_object('done', coalesce(r.seeds_done, 0), 'within', coalesce(r.seeds_within, 0)),
          'practice', jsonb_build_object('done', coalesce(r.practice_done, 0), 'within', coalesce(r.practice_within, 0)),
          'median_seconds', round(r.median)::int,
          'sent_back', r.sent_back,
          'notes', to_jsonb(array_remove(array[
            case when r.pieces >= 10 and r.median < (select e.median from exam_speed e) / 3 then 'fast' end,
            case when r.pieces >= 10 and r.at_max * 10 >= r.pieces * 3 then 'full_marks' end,
            case when r.pieces >= 10 and abs(r.difference) > v_tol then 'mean_apart' end], null)))
        order by r.name nulls last, r.marker_id)
      from per_marker r), '[]'::jsonb))
  into v_out;
  return v_out;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: as 20261123000006, and (3B Task 10, Ruling R23) nothing is done on an approved exam (0), read once the
-- exam's marking row is held: an approval and a pause never pass each other.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_pause_apply(p_exam uuid, p_marker uuid)
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
  -- 3B Task 10: nothing about an approved exam's marking changes until an admin withdraws the approval.
  if public.marking_exam_frozen(p_exam) then
    return 0;
  end if;
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
-- Privileges. The internal functions are for definer callers only; the approval functions for signed-in users (they
-- check for an admin). Functions made again by create or replace keep theirs (restated).
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.marking_exam_frozen(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_approval_blocks(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_approval_get(uuid) from public, anon;
revoke execute on function public.marking_approve(uuid, text) from public, anon;
revoke execute on function public.marking_approval_withdraw(uuid, text) from public, anon;
revoke execute on function public.marking_reopen(uuid, text) from public, anon;
revoke execute on function public.marking_settings_set(uuid, public.marking_mode, timestamptz, text) from public, anon;
revoke execute on function public.marking_checks_set(uuid, jsonb, text) from public, anon;
revoke execute on function public.exam_structure_save(uuid, jsonb, text) from public, anon;
revoke execute on function public.marking_take_back(uuid[], text, public.marking_kind) from public, anon;
revoke execute on function public.marking_assign(uuid[], uuid, text, public.marking_kind) from public, anon;
revoke execute on function public.marking_script_take_back(uuid, text) from public, anon;
revoke execute on function public.marking_second_add(uuid[], text) from public, anon;
revoke execute on function public.marking_second_drop(uuid[], text) from public, anon;
revoke execute on function public.marking_standard_set(uuid, text, text) from public, anon;
revoke execute on function public.marking_marker_clear(uuid, uuid, text) from public, anon;
revoke execute on function public.marking_marker_pause(uuid, uuid, text) from public, anon;
revoke execute on function public.marking_script_hand_back(uuid, text) from public, anon;
revoke execute on function public.marking_standard_retire(uuid, text) from public, anon;
revoke execute on function public.marking_tick() from public, anon, authenticated, service_role;
revoke execute on function public.marking_second_pairs(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_pause_apply(uuid, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_stats(uuid) from public, anon;
grant execute on function public.marking_stats(uuid) to authenticated;
grant execute on function public.marking_approval_get(uuid) to authenticated;
grant execute on function public.marking_approve(uuid, text) to authenticated;
grant execute on function public.marking_approval_withdraw(uuid, text) to authenticated;
grant execute on function public.marking_reopen(uuid, text) to authenticated;
grant execute on function public.marking_settings_set(uuid, public.marking_mode, timestamptz, text) to authenticated;
grant execute on function public.marking_checks_set(uuid, jsonb, text) to authenticated;
grant execute on function public.exam_structure_save(uuid, jsonb, text) to authenticated;
grant execute on function public.marking_take_back(uuid[], text, public.marking_kind) to authenticated;
grant execute on function public.marking_assign(uuid[], uuid, text, public.marking_kind) to authenticated;
grant execute on function public.marking_script_take_back(uuid, text) to authenticated;
grant execute on function public.marking_second_add(uuid[], text) to authenticated;
grant execute on function public.marking_second_drop(uuid[], text) to authenticated;
grant execute on function public.marking_standard_set(uuid, text, text) to authenticated;
grant execute on function public.marking_marker_clear(uuid, uuid, text) to authenticated;
grant execute on function public.marking_marker_pause(uuid, uuid, text) to authenticated;
grant execute on function public.marking_script_hand_back(uuid, text) to authenticated;
grant execute on function public.marking_standard_retire(uuid, text) to authenticated;
