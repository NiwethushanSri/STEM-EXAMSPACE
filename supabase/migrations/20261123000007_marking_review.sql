-- Phase 3B Task 7: the lead marker's review. Marks that differ, a paused marker's scripts, the routine sample, sending a
-- script back, and the lead's own change to a final mark.
--
-- What the lead reviews (marking_reviews, Task 2): a difference between a piece's first and second marking (Task 4's
-- rule 5), a paused marker's piece (rule 4), and a piece of the routine sample of one marker's work (made here, by hand).
-- Every review function here is for an admin or the subject's lead marker (forbidden otherwise; an unknown review, piece
-- or exam is not_found to an admin and forbidden to anyone else), and once the exam's marking is approved
-- (exam_marking.approved_at, Task 10) none of them changes anything (marking_approved). A lead with a declared conflict
-- or a tutor link for the candidate, or who saw a name on the script (a name_seen exclusion), is refused
-- conflict_of_interest (marking_review_refusal). An admin may do everything the lead does (Builder's call 11); a lead who
-- is one of the two markers may settle, and is told so (party). No answer names the candidate; markers' names are shown,
-- as in Phase 3A's progress. A lead is never shown the first marking of a piece they may still second-mark (it waits for
-- a second marking, or they hold its second pass or have a second marking of it in progress: marking_review_blind): their
-- list leaves its review out, and opening it and its pictures are refused.
--
-- Settling a difference (Review Focus 3): the lead settles the marks they were shown. A marking saved since the review
-- was opened (its rev is not the one passed) is refused (conflict, changed) and nothing is written; a review closed
-- already is refused (conflict, settled), so the lead and an admin settling at once settle it once. The final marks and
-- the marking they come from are written first (Ruling R9), then the review closes and the piece is evaluated: rule 3
-- finds it settled for the submission it reviewed and leaves them as they are. Neither marking is changed, and once
-- settled neither marker may change a mark (marking_save: settled, Task 4).
--
-- Sending back (Builder's call 12): to the same marker, whose marking opens again with the lead's note and an assigned
-- hold; or to another, when the lead asks or when the same marker may no longer have it (no longer approved, not
-- cleared, paused, blocked or barred for the piece, or it is a paused marker's piece under review): their marking is set
-- aside (sent_back), they are kept from the piece (an exclusion, sent_back) and the piece is free. A second marking stays,
-- and is compared again when the first is submitted again.
--
-- The lead's change to a final mark (Builder's call 13): on a checked piece the final mark changes (source lead, with
-- who, when and why), never a marker's own marks. It settles the piece for its current submission (the 3B ledger's note
-- for Task 7): an open sample review of it closes as lead_marks and, when no closed review settles that submission, one
-- is recorded (a closed sample review, lead_marks). So a later marker change is refused (settled), and no evaluation
-- writes the first marks over the lead's.
--
-- A second marker sees neither the first marks nor the first layer (Ruling R14): the subject's lead and staff admins,
-- whom a review may have shown a piece's first marking, are never given a second pass on a piece with any review. A
-- paused marker's piece accepted by the lead is checked without a second marking (Ruling R15): a second pass not yet
-- submitted ends, one submitted stands and is shown on the review.
--
-- Added:
--   marking_review_refusal(p_unit), marking_review_blind(p_unit), marking_review_marking(p_marking),
--     marking_lead_marks_refusal(p_unit, p_marks, p_every), marking_final_marks_lead(p_unit, p_marks, p_reason),
--     marking_review_sample_pieces(p_exam, p_marker, p_units) (internal).
--   marking_review_list, marking_review_open, marking_review_settle, marking_review_accept, marking_send_back,
--     marking_review_sample, marking_final_set.
--   Index marking_reviews_unit_idx (a piece's reviews).
-- Changed, each from its latest definition:
--   marking_units_allowed (20261123000006): Ruling R14 (above), in the second-pass branch; marking_unit_blocked then
--     answers not_eligible, and marking_second_stuck counts such a piece when nobody else may take it.
--   marking_unit_settled (20261123000005): a closed sample review with outcome lead_marks (the lead changed a final
--     mark) settles the piece too, closed after the first marking's current submission as before.
--   marking_check_evaluate (20261123000005): rule 3 reads such a review as marking_unit_settled does; accepted writes the
--     first marks as final marks only when it makes the piece checked (a final mark the lead changed afterwards stands
--     when the piece is evaluated again); rule 1 also withdraws an open sample review (the marking it was of is no longer
--     submitted); an open paused marker's review is kept on the piece's submitted second marking (Ruling R15).
--   marking_checks_set (20261123000005): Ruling R11: seeded scripts or practice turned off retire their standards still
--     in use (marking_standard_end: their open attempts end and those in progress are set aside, switched_off), so Next
--     script hands out and resumes none of them, as the list's left counts none.
--   marking_my_work (20261123000006): every piece says sent_back (its marking has the lead's note), with the same key
--     for every kind of pass.
--   marking_picture_paths (20261123000005): (d) a caller who may open a review of the piece, while the exam's marking is
--     not approved, the script is not taken back and shows no name.
-- Nothing else in them changed.
--
-- Lock order (as 20261123000003): marker key -> exam_marking -> booking lock -> script rows in id order -> units in id
-- order -> assignments and markings -> marking_reviews -> final_marks -> exam_markers. Each review action holds one script
-- (marking_script_lock), then the piece's markings, then its reviews, then writes the final marks; a send-back takes the
-- first marker's key before all of them. The routine sample holds the exam's marking row, then one sample at a time per
-- exam (an advisory lock), and only adds review rows. marking_checks_set takes the structure lock and the exam's marking
-- row, then the scripts of the standards it retires and their pieces, each in id order.

-- ---------------------------------------------------------------------------------------------
-- Internal: why the caller may not review the piece (null: they may): forbidden (neither an admin nor the subject's
-- active lead marker; also a piece that does not exist) or conflict_of_interest (a lead with a declared conflict or a
-- tutor link for its candidate, or who saw a name on its script: a name_seen exclusion on any piece of it).
-- ---------------------------------------------------------------------------------------------
create function public.marking_review_refusal(p_unit uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_subject bigint;
  v_student uuid;
  v_script uuid;
begin
  select e.subject_id, b.student_id, u.script_id into v_subject, v_student, v_script
  from public.marking_units u
  join public.exams e on e.id = u.exam_id
  join public.scripts s on s.id = u.script_id
  join public.bookings b on b.id = s.booking_id
  where u.id = p_unit;
  if not found then
    return 'forbidden';
  end if;
  if public.is_staff_admin() then
    return null;
  end if;
  if not public.is_lead_for(v_actor, v_subject) then
    return 'forbidden';
  end if;
  if public.marking_marker_blocked(v_actor, v_student)
     or exists (select 1 from public.marking_unit_exclusions x join public.marking_units w on w.id = x.unit_id
                where w.script_id = v_script and x.marker_id = v_actor and x.reason = 'name_seen') then
    return 'conflict_of_interest';
  end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the caller, not an admin, may still be (or is) the piece's second marker: it waits for a second marking, or
-- they hold its second pass or have a second marking of it in progress. They are shown nothing of its first marking.
-- ---------------------------------------------------------------------------------------------
create function public.marking_review_blind(p_unit uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not public.is_staff_admin() and exists (
    select 1 from public.marking_units u
    where u.id = p_unit
      and (u.check_state is not distinct from 'waiting_second'
           or exists (select 1 from public.marking_assignments a
                      where a.unit_id = u.id and a.kind = 'second' and a.ended_at is null and a.marker_id = auth.uid())
           or exists (select 1 from public.markings m
                      where m.unit_id = u.id and m.kind = 'second' and m.status = 'in_progress' and m.marker_id = auth.uid())))
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: one marking as the review screen shows it: {marking_id, rev, marker_name, total, lead_note (the marker's
-- note to the lead), active_seconds, submitted_at, marks: [{question_id, mark, na}] in paper order, annotations: [{id,
-- page_id, kind, x, y, points, text, question_id}] on the pages the piece shows, turned as they were drawn}. A marker's
-- name is never their email (as marking_units_list).
-- ---------------------------------------------------------------------------------------------
create function public.marking_review_marking(p_marking uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'marking_id', m.id,
    'rev', m.rev,
    'marker_name', coalesce(nullif(btrim(p.first_name || ' ' || p.last_name), ''), 'Marker ' || left(p.id::text, 8)),
    'total', m.total,
    'lead_note', m.lead_note,
    'active_seconds', m.active_seconds,
    'submitted_at', m.submitted_at,
    'marks', coalesce((
      select jsonb_agg(jsonb_build_object('question_id', q.question_id, 'mark', q.mark, 'na', q.not_attempted) order by t.path)
      from public.question_marks q join public.marking_unit_questions(m.unit_id) t on t.question_id = q.question_id
      where q.marking_id = m.id), '[]'::jsonb),
    'annotations', coalesce((
      select jsonb_agg(jsonb_build_object('id', a.id, 'page_id', a.page_id, 'kind', a.kind, 'x', a.x, 'y', a.y, 'points', a.points,
                                          'text', a.text, 'question_id', a.question_id) order by a.created_at, a.id)
      from public.page_annotations a
      join public.marking_script_pages(u.script_id) x on x.page_id = a.page_id and x.rotation = a.page_rotation
      where a.marking_id = m.id and a.deleted_at is null), '[]'::jsonb))
  from public.markings m
  join public.marking_units u on u.id = m.unit_id
  join public.profiles p on p.id = m.marker_id
  where m.id = p_marking
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: why a set of the lead's marks for the piece (p_marks: [{question_id, mark|null, na}]) may not be used
-- (null: it may), as an answer: invalid_input (not a list of 1 to 200 such entries, a question twice or not a question
-- of the piece that takes marks, NR with a mark); mark_out_of_range (a mark below 0, over its maximum or off its step);
-- incomplete, with missing (labels in paper order): an entry with neither a mark nor NR, and, with p_every, a question
-- of the piece with no entry.
-- ---------------------------------------------------------------------------------------------
create function public.marking_lead_marks_refusal(p_unit uuid, p_marks jsonb, p_every boolean)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uuid constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
  v_missing jsonb;
begin
  if jsonb_typeof(p_marks) is distinct from 'array' or jsonb_array_length(p_marks) not between 1 and 200
     or exists (select 1 from jsonb_array_elements(p_marks) e
                where jsonb_typeof(e) <> 'object'
                   or jsonb_typeof(e -> 'question_id') is distinct from 'string' or (e ->> 'question_id') !~ v_uuid
                   or coalesce(jsonb_typeof(e -> 'mark'), 'null') not in ('null', 'number')
                   or jsonb_typeof(e -> 'na') is distinct from 'boolean'
                   or case when jsonb_typeof(e -> 'na') = 'boolean' then (e ->> 'na')::boolean and (e ->> 'mark') is not null
                           else false end) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if exists (select 1 from jsonb_array_elements(p_marks) e group by (e ->> 'question_id')::uuid having count(*) > 1)
     or exists (select 1 from jsonb_array_elements(p_marks) e
                where not exists (select 1 from public.marking_unit_questions(p_unit) q
                                  where q.leaf and q.question_id = (e ->> 'question_id')::uuid)) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if exists (select 1 from jsonb_array_elements(p_marks) e
             join public.marking_unit_questions(p_unit) q on q.question_id = (e ->> 'question_id')::uuid
             where (e ->> 'mark') is not null
               and ((e ->> 'mark')::numeric < 0 or (e ->> 'mark')::numeric > q.max_mark or mod((e ->> 'mark')::numeric, q.mark_step) <> 0)) then
    return jsonb_build_object('ok', false, 'code', 'mark_out_of_range');
  end if;
  select coalesce(jsonb_agg(q.label order by q.path), '[]'::jsonb) into v_missing
  from public.marking_unit_questions(p_unit) q
  where q.leaf
    and (exists (select 1 from jsonb_array_elements(p_marks) e
                 where (e ->> 'question_id')::uuid = q.question_id and (e ->> 'mark') is null and not (e ->> 'na')::boolean)
         or (p_every and not exists (select 1 from jsonb_array_elements(p_marks) e where (e ->> 'question_id')::uuid = q.question_id)));
  if jsonb_array_length(v_missing) > 0 then
    return jsonb_build_object('ok', false, 'code', 'incomplete', 'missing', v_missing);
  end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the piece's final marks for the questions of p_marks (checked by marking_lead_marks_refusal) become the
-- lead's (source lead, set by the caller, for p_reason). Only what differs is written, each write with its history row.
-- ---------------------------------------------------------------------------------------------
create function public.marking_final_marks_lead(p_unit uuid, p_marks jsonb, p_reason text)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.final_marks as f (unit_id, question_id, mark, not_attempted, source, set_by, set_at, reason)
  select p_unit, (e ->> 'question_id')::uuid, case when (e ->> 'na')::boolean then null else (e ->> 'mark')::numeric end,
    (e ->> 'na')::boolean, 'lead', auth.uid(), now(), p_reason
  from jsonb_array_elements(p_marks) e
  on conflict (unit_id, question_id) do update
  set mark = excluded.mark, not_attempted = excluded.not_attempted, source = excluded.source, set_by = excluded.set_by,
    set_at = excluded.set_at, reason = excluded.reason
  where (f.mark, f.not_attempted, f.source) is distinct from (excluded.mark, excluded.not_attempted, excluded.source)
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: as 20261123000005, whether the lead settled the piece's first marking as it is submitted now (the 3B
-- ledger's R9): a closed difference or paused-marker review of its live marking that is not set aside, whose outcome
-- stands (first_stands, second_stands, lead_marks, accepted), and (3B Task 7) a closed sample review with outcome
-- lead_marks (the lead changed a final mark), closed after that marking's current submission. A marking that came back
-- in progress and was submitted again is not settled by a review of its earlier submission. Any other routine sample
-- review never settles a piece.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_unit_settled(p_unit uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.marking_reviews r
    join public.markings m on m.id = r.marking_id
    where r.unit_id = p_unit and r.state = 'closed'
      and ((r.kind in ('difference', 'paused_marker') and r.outcome in ('first_stands', 'second_stands', 'lead_marks', 'accepted'))
           or (r.kind = 'sample' and r.outcome = 'lead_marks'))
      and m.unit_id = p_unit and m.kind = 'live' and m.status <> 'set_aside'
      and r.closed_at >= m.submitted_at)
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: as 20261123000005, the piece's check, worked out again (that migration's header, rules 1 to 6), and (3B Task
-- 7): rule 1 also withdraws an open sample review; rule 3 also finds a closed sample review with outcome lead_marks (as
-- marking_unit_settled); accepted writes the first marks as final marks only when it makes the piece checked, so a final
-- mark the lead changed afterwards stands; and (Ruling R15) an open paused marker's review is kept on the piece's
-- submitted second marking, one submitted while it is open included. Sets the piece's check_state, second_wanted
-- (decided once), checked_at (when it became checked) and final_marking_id (the marking its final marks came from; null
-- unless checked), writes or removes its final marks, opens or withdraws its reviews, and then its script's state
-- follows. The caller holds the script's and the piece's rows. Returns the check state.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_check_evaluate(p_unit uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_u public.marking_units%rowtype;
  v_m public.exam_marking%rowtype;
  v_first public.markings%rowtype;
  v_second public.markings%rowtype;
  v_r public.marking_reviews%rowtype;
  v_wanted boolean;
  v_state text;
  v_final uuid;
begin
  select * into v_u from public.marking_units u where u.id = p_unit;
  if not found then
    return null;
  end if;
  select * into v_first from public.markings m where m.unit_id = p_unit and m.kind = 'live' and m.status <> 'set_aside';
  select * into v_second from public.markings m where m.unit_id = p_unit and m.kind = 'second' and m.status = 'submitted';
  v_wanted := v_u.second_wanted;

  -- The piece's own state counts too: a take-back opens the piece before it sets its marking aside, and the check run
  -- between the two must not see a submitted piece.
  if v_first.id is null or v_first.status <> 'submitted' or v_u.state <> 'submitted' then
    -- (1) Nothing to check: what waited for the lead is withdrawn (3B Task 7: a sample review too).
    update public.marking_reviews r set state = 'closed', outcome = 'withdrawn', closed_by = v_actor, closed_at = now()
    where r.unit_id = p_unit and r.state = 'open' and r.kind in ('difference', 'paused_marker', 'sample');
    v_state := null;
  else
    -- A difference whose markings no longer both stand has nothing left to settle.
    update public.marking_reviews r set state = 'closed', outcome = 'withdrawn', closed_by = v_actor, closed_at = now()
    where r.unit_id = p_unit and r.state = 'open' and r.kind = 'difference'
      and (r.marking_id <> v_first.id or r.second_marking_id is distinct from v_second.id);
    -- 3B Task 7 (Ruling R15): an open paused marker's review follows the piece's submitted second marking, so the lead
    -- sees one submitted while the review waits for them.
    update public.marking_reviews r set second_marking_id = v_second.id
    where r.unit_id = p_unit and r.state = 'open' and r.kind = 'paused_marker' and r.second_marking_id is distinct from v_second.id;
    -- A settle covers only the submission it reviewed (as marking_unit_settled): one closed before this submission does not.
    select r.* into v_r from public.marking_reviews r
    where r.unit_id = p_unit and r.marking_id = v_first.id and r.state = 'closed'
      and ((r.kind in ('difference', 'paused_marker') and r.outcome in ('first_stands', 'second_stands', 'lead_marks', 'accepted'))
           or (r.kind = 'sample' and r.outcome = 'lead_marks'))
      and r.closed_at >= v_first.submitted_at
    order by r.closed_at desc, r.id
    limit 1;
    if exists (select 1 from public.marking_reviews r
               where r.unit_id = p_unit and r.state = 'open' and r.kind in ('difference', 'paused_marker')) then
      v_state := 'to_lead';  -- (2)
    elsif v_r.id is not null then
      -- (3) Settled: the final marks are as the settle wrote them; accepted, the first marks stand, written when the
      -- acceptance makes the piece checked (3B Task 7: a final mark the lead changed afterwards stands).
      v_state := 'checked';
      if v_r.outcome = 'accepted' and v_u.check_state is distinct from 'checked' then
        perform public.marking_final_marks_from(p_unit, v_first.id, 'Checked: the lead marker accepted the first marking.');
        v_final := v_first.id;
      else
        v_final := coalesce(v_u.final_marking_id, case when v_r.outcome = 'second_stands' then v_r.second_marking_id else v_first.id end);
      end if;
    elsif exists (select 1 from public.exam_markers x
                  where x.exam_id = v_u.exam_id and x.marker_id = v_first.marker_id and x.paused_at is not null) then
      -- (4) The first marker is paused on the exam: the lead looks at it.
      insert into public.marking_reviews (exam_id, unit_id, kind, marking_id, second_marking_id)
      values (v_u.exam_id, p_unit, 'paused_marker', v_first.id, v_second.id);
      v_state := 'to_lead';
    else
      -- (5) Second-marked or not: decided once, from the stored draw, and kept.
      if v_wanted is null then
        select * into v_m from public.exam_marking m where m.exam_id = v_u.exam_id;
        v_wanted := coalesce(v_m.double_marking, true) and v_u.sample_draw < coalesce(v_m.sample_percent, 10) / 100.0;
      end if;
      if not v_wanted then
        -- (6)
        v_state := 'checked';
        perform public.marking_final_marks_from(p_unit, v_first.id, 'Checked: not second-marked.');
        v_final := v_first.id;
      elsif v_second.id is null then
        v_state := 'waiting_second';
      elsif coalesce((public.marking_compare(v_first.id, v_second.id) ->> 'within')::boolean, false) then
        v_state := 'checked';
        perform public.marking_final_marks_from(p_unit, v_first.id, 'Checked: the second marking is within tolerance.');
        v_final := v_first.id;
      else
        insert into public.marking_reviews (exam_id, unit_id, kind, marking_id, second_marking_id)
        values (v_u.exam_id, p_unit, 'difference', v_first.id, v_second.id);
        v_state := 'to_lead';
      end if;
    end if;
  end if;

  -- Only a checked piece has final marks.
  if v_state is distinct from 'checked' then
    perform public.marking_final_marks_remove(p_unit,
      case when v_state is null then 'The first marking is no longer submitted.'
           when v_state = 'waiting_second' then 'Waiting for a second marker.'
           else 'With the lead marker.' end);
  end if;
  update public.marking_units u
  set check_state = v_state, second_wanted = v_wanted,
    checked_at = case when v_state = 'checked' then coalesce(case when u.check_state = 'checked' then u.checked_at end, now()) end,
    final_marking_id = case when v_state = 'checked' then v_final end
  where u.id = p_unit
    and (u.check_state, u.second_wanted, u.final_marking_id)
        is distinct from (v_state, v_wanted, case when v_state = 'checked' then v_final end);
  perform public.marking_script_state(v_u.script_id);
  return v_state;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_review_list: the open reviews the caller may act on, oldest first (at most 500, with more), of the exams whose
-- marking has opened (p_exam: that one) of a subject they lead (an admin: every subject); p_kind (difference,
-- paused_marker or sample) narrows the items, not the counts. A lead's list leaves out the reviews they are refused
-- (marking_review_refusal) or blind to (marking_review_blind). counts: open reviews of each kind; to_clear: markers of
-- those exams who did every practice script they may do and are not cleared yet; stuck_second: pieces waiting for a
-- second marker whom nobody can be (marking_second_stuck). No candidate's name. Returns {ok, counts: {difference,
-- paused_marker, sample, to_clear, stuck_second}, items: [{review_id, kind, exam_id, exam_title, unit_id, script_number,
-- index_number, group_label, first: {marker_id, name, total}, second: {marker_id, name, total}|null, max_total,
-- opened_at, party}], more}; party is true when the caller is one of the two markers.
-- ---------------------------------------------------------------------------------------------
create function public.marking_review_list(p_exam uuid default null, p_kind text default null)
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
      left join public.markings k on k.id = l.second_marking_id
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
-- marking_review_open: one review, open or closed, for the review screen: refused as marking_review_refusal says, and
-- forbidden for a lead blind to the piece (marking_review_blind). Both markings (marking_review_marking: marks, total,
-- annotations and each marker's note to the lead), their comparison (marking_compare_sets, null without a second
-- marking) and the piece's final marks. The second marking of an open review is the piece's submitted second marking now
-- (Ruling R15: one submitted while a paused marker's review waits is shown); of a closed one, the one it was closed on.
-- Nothing names the candidate. Returns {ok, review: {id, kind, state, outcome,
-- party}, unit: {id, exam_title, paper, script_number, index_number, group_label}, structure: {questions,
-- option_groups}, pages: [{n, page_id, copy_page, extra, rotation}], first: {...}, second: {...}|null, compare, final:
-- [{question_id, mark, na, source}]}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_review_open(p_review uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_r public.marking_reviews%rowtype;
  v_u public.marking_units%rowtype;
  v_x public.scripts%rowtype;
  v_e public.exams%rowtype;
  v_why text;
  v_second uuid;
begin
  if p_review is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_r from public.marking_reviews r where r.id = p_review;
  if not found then
    return jsonb_build_object('ok', false, 'code', case when public.is_staff_admin() then 'not_found' else 'forbidden' end);
  end if;
  v_why := public.marking_review_refusal(v_r.unit_id);
  if v_why is not null then
    return jsonb_build_object('ok', false, 'code', v_why);
  end if;
  if public.marking_review_blind(v_r.unit_id) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select * into v_u from public.marking_units u where u.id = v_r.unit_id;
  select * into v_x from public.scripts s where s.id = v_u.script_id;
  select * into v_e from public.exams e where e.id = v_u.exam_id;
  -- Ruling R15: an open review shows the piece's submitted second marking now; a closed one, the one it was closed on.
  v_second := case when v_r.state = 'open'
                   then (select k.id from public.markings k where k.unit_id = v_r.unit_id and k.kind = 'second' and k.status = 'submitted')
                   else v_r.second_marking_id end;

  return jsonb_build_object(
    'ok', true,
    'review', jsonb_build_object(
      'id', v_r.id, 'kind', v_r.kind, 'state', v_r.state, 'outcome', v_r.outcome,
      'party', exists (select 1 from public.markings m where m.id in (v_r.marking_id, v_second) and m.marker_id = v_actor)),
    'unit', jsonb_build_object(
      'id', v_u.id,
      'exam_title', v_e.title,
      'paper', v_e.paper,
      'script_number', v_x.number,
      'index_number', (select d.index_number from public.bookings b join public.student_details d on d.profile_id = b.student_id
                       where b.id = v_x.booking_id),
      'group_label', (select g.label from public.question_groups g where g.id = v_u.group_id)),
    'structure', jsonb_build_object(
      'questions', coalesce((
        select jsonb_agg(jsonb_build_object(
            'id', q.id, 'parent_id', q.parent_id, 'label', q.label, 'position', q.position, 'max_mark', q.max_mark,
            'mark_step', q.mark_step, 'levels', q.levels, 'pages', to_jsonb(q.pages), 'areas', q.areas, 'group_id', q.group_id,
            'option_group_id', q.option_group_id, 'guidance', q.guidance, 'alternatives', q.alternatives,
            'points', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'label', p.label, 'marks', p.marks,
                                                                    'marks_to', p.marks_to, 'text', p.text) order by p.position)
                                from public.mark_scheme_points p where p.question_id = q.id), '[]'::jsonb))
          order by t.path)
        from public.marking_unit_questions(v_u.id) t join public.exam_questions q on q.id = t.question_id), '[]'::jsonb),
      'option_groups', coalesce((
        select jsonb_agg(jsonb_build_object('id', o.id, 'label', o.label, 'choose', o.choose) order by o.label, o.id)
        from public.exam_option_groups o
        where o.id in (select q.option_group_id from public.marking_unit_questions(v_u.id) t
                       join public.exam_questions q on q.id = t.question_id)), '[]'::jsonb)),
    'pages', coalesce((
      select jsonb_agg(jsonb_build_object('n', x.n, 'page_id', x.page_id, 'copy_page', x.copy_page, 'extra', x.extra,
                                          'rotation', x.rotation) order by x.n)
      from public.marking_script_pages(v_u.script_id) x), '[]'::jsonb),
    'first', public.marking_review_marking(v_r.marking_id),
    'second', case when v_second is not null then public.marking_review_marking(v_second) end,
    'compare', case when v_second is not null then public.marking_compare(v_r.marking_id, v_second) end,
    'final', coalesce((
      select jsonb_agg(jsonb_build_object('question_id', f.question_id, 'mark', f.mark, 'na', f.not_attempted, 'source', f.source)
                       order by t.path)
      from public.final_marks f join public.marking_unit_questions(v_u.id) t on t.question_id = f.question_id
      where f.unit_id = v_u.id), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_review_settle: the lead (or an admin) settles an open difference, with a reason (3 to 300 characters), at the
-- revs of the two markings they were shown. p_outcome: first_stands, second_stands, or lead_marks with p_marks
-- ([{question_id, mark|null, na}]: a mark or NR for every question of the piece, each within its maximum and step;
-- p_marks is read for lead_marks only). The final marks are written first (source first, second or lead; set by the
-- caller, with history and the reason) and final_marking_id (the second marking for second_stands, else the first), then
-- the review closes with its outcome and the piece is evaluated (rule 3: checked; its script follows). Neither marking
-- is changed. Refused, in this order: invalid_input; not_found; forbidden, conflict_of_interest; reason_required;
-- wrong_kind (not a difference); marking_approved; conflict with reason settled (the review is closed) or changed (a
-- marking's rev is not the one passed, or it is no longer submitted: nothing is written); then for lead_marks
-- invalid_input, mark_out_of_range and incomplete (with missing). Audited marking_review_settled (the outcome and the
-- reason). Returns {ok, check_state}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_review_settle(p_review uuid, p_outcome text, p_first_rev int, p_second_rev int, p_reason text,
  p_marks jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_r public.marking_reviews%rowtype;
  v_u public.marking_units%rowtype;
  v_first public.markings%rowtype;
  v_second public.markings%rowtype;
  v_why text;
  v_bad jsonb;
  v_from uuid;
  v_state text;
begin
  if p_review is null or p_outcome is null or p_outcome not in ('first_stands', 'second_stands', 'lead_marks')
     or p_first_rev is null or p_second_rev is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_r from public.marking_reviews r where r.id = p_review;
  if not found then
    return jsonb_build_object('ok', false, 'code', case when public.is_staff_admin() then 'not_found' else 'forbidden' end);
  end if;
  v_why := public.marking_review_refusal(v_r.unit_id);
  if v_why is not null then
    return jsonb_build_object('ok', false, 'code', v_why);
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if v_r.kind <> 'difference' then
    return jsonb_build_object('ok', false, 'code', 'wrong_kind');
  end if;

  -- Ruling R9: the exam's marking row, the booking's lock, the script's row and its pieces, the two markings, then the
  -- review: a marker's save, or another settle, of this piece waits or is waited for.
  select * into v_u from public.marking_units u where u.id = v_r.unit_id;
  perform public.marking_script_lock(v_u.script_id);
  perform 1 from public.markings m where m.id in (v_r.marking_id, v_r.second_marking_id) order by m.id for update;
  select * into v_r from public.marking_reviews r where r.id = p_review for update;
  if exists (select 1 from public.exam_marking m where m.exam_id = v_r.exam_id and m.approved_at is not null) then
    return jsonb_build_object('ok', false, 'code', 'marking_approved');
  end if;
  if v_r.state <> 'open' then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'settled');
  end if;
  select * into v_first from public.markings m where m.id = v_r.marking_id;
  select * into v_second from public.markings m where m.id = v_r.second_marking_id;
  -- Review Focus 3: the marks are settled as they were shown. A marking saved since is refused, and nothing is written.
  if v_first.rev <> p_first_rev or v_second.rev is distinct from p_second_rev
     or v_first.status <> 'submitted' or v_second.status is distinct from 'submitted' then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'changed');
  end if;
  if p_outcome = 'lead_marks' then
    v_bad := public.marking_lead_marks_refusal(v_r.unit_id, p_marks, true);
    if v_bad is not null then
      return v_bad;
    end if;
  end if;

  -- Ruling R9: the final marks and the marking they come from are written before anything evaluates the piece; the
  -- evaluation then finds it settled for this submission (rule 3) and leaves them as they are.
  v_from := case when p_outcome = 'second_stands' then v_second.id else v_first.id end;
  if p_outcome = 'lead_marks' then
    perform public.marking_final_marks_lead(v_r.unit_id, p_marks, v_reason);
  else
    perform public.marking_final_marks_from(v_r.unit_id, v_from, v_reason);
  end if;
  update public.marking_units u set final_marking_id = v_from where u.id = v_r.unit_id;
  update public.marking_reviews r
  set state = 'closed', outcome = p_outcome, reason = v_reason, closed_by = v_actor, closed_at = now()
  where r.id = p_review;
  v_state := public.marking_check_evaluate(v_r.unit_id);
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marking_review_settled', 'marking_unit', v_r.unit_id, p_outcome || '; reason: ' || v_reason);
  return jsonb_build_object('ok', true, 'check_state', v_state);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_review_accept: the lead (or an admin) accepts an open paused-marker or sample review; the reason is optional
-- and, given, 3 to 300 characters (reason_required). The review closes as accepted. A paused marker's piece is then
-- evaluated: rule 3 checks it on its first marks, without a second marking; first (Ruling R15) a second pass not yet
-- submitted ends (its hold ends and its marking in progress is set aside, switched_off; audited marking_second_ended),
-- second_wanted is kept and a submitted second marking stands. A sample review leaves the piece and its
-- script as they are. Refused: invalid_input; not_found; forbidden, conflict_of_interest; reason_required; wrong_kind (a
-- difference is settled instead); marking_approved; conflict with reason settled (the review is closed). Audited
-- marking_review_accepted. Returns {ok, check_state}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_review_accept(p_review uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_given text := nullif(btrim(coalesce(p_reason, '')), '');
  v_reason text := public.script_resolution_reason(p_reason);
  v_r public.marking_reviews%rowtype;
  v_u public.marking_units%rowtype;
  v_why text;
  v_state text;
  v_ended boolean;
begin
  if p_review is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_r from public.marking_reviews r where r.id = p_review;
  if not found then
    return jsonb_build_object('ok', false, 'code', case when public.is_staff_admin() then 'not_found' else 'forbidden' end);
  end if;
  v_why := public.marking_review_refusal(v_r.unit_id);
  if v_why is not null then
    return jsonb_build_object('ok', false, 'code', v_why);
  end if;
  if v_given is not null and v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if v_r.kind not in ('paused_marker', 'sample') then
    return jsonb_build_object('ok', false, 'code', 'wrong_kind');
  end if;

  -- Ruling R9: the exam's marking row, the booking's lock, the script's row and its pieces, every marking of the piece
  -- (Ruling R15), the review.
  select * into v_u from public.marking_units u where u.id = v_r.unit_id;
  perform public.marking_script_lock(v_u.script_id);
  perform 1 from public.markings m where m.unit_id = v_r.unit_id order by m.id for update;
  select * into v_r from public.marking_reviews r where r.id = p_review for update;
  if exists (select 1 from public.exam_marking m where m.exam_id = v_r.exam_id and m.approved_at is not null) then
    return jsonb_build_object('ok', false, 'code', 'marking_approved');
  end if;
  if v_r.state <> 'open' then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'settled');
  end if;

  -- Ruling R15: a paused marker's piece is checked without a second marking. A second pass not submitted ends: its hold
  -- ends and its marking in progress is set aside (switched_off; unpaid, Ruling R1). A submitted one stands. Whether a
  -- second marking is wanted is kept: a later re-mark of the piece is second-marked as it was drawn.
  if v_r.kind = 'paused_marker' then
    with ended as (
      update public.marking_assignments a set ended_at = now(), end_reason = 'switched_off'
      where a.unit_id = v_r.unit_id and a.kind = 'second' and a.ended_at is null
      returning a.marker_id
    ),
    set_aside as (
      update public.markings m set status = 'set_aside', set_aside_at = now(), set_aside_reason = 'switched_off'
      where m.unit_id = v_r.unit_id and m.kind = 'second' and m.status = 'in_progress'
      returning m.marker_id
    )
    select (select count(*) from ended) + (select count(*) from set_aside) > 0 into v_ended;
    if v_ended then
      insert into public.audit_log (actor_id, action, target_type, target_id, reason)
      values (v_actor, 'marking_second_ended', 'marking_unit', v_r.unit_id,
        'The lead marker accepted a paused marker''s script: its second marking in progress is no longer needed.');
    end if;
  end if;
  update public.marking_reviews r
  set state = 'closed', outcome = 'accepted', reason = v_reason, closed_by = v_actor, closed_at = now()
  where r.id = p_review;
  if v_r.kind = 'paused_marker' then
    v_state := public.marking_check_evaluate(v_r.unit_id);
  else
    select u.check_state into v_state from public.marking_units u where u.id = v_r.unit_id;
  end if;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marking_review_accepted', 'marking_unit', v_r.unit_id, v_r.kind || coalesce('; reason: ' || v_reason, ''));
  return jsonb_build_object('ok', true, 'check_state', v_state);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_send_back: the lead (or an admin) sends a piece whose first marking is submitted back, with a note to the
-- marker (3 to 1,000 characters) and a reason (3 to 300). p_to is same or other. same: the marking is in progress again
-- with the note (sent_back_note), the piece is taken with an assigned hold for that marker (no time limit) and its script
-- is being marked again; it goes as other, and the answer says so, when the marker is no longer approved, cleared and
-- unpaused, is blocked for the candidate or barred from the piece (an exclusion), or the piece's open review is a paused
-- marker's. other: the marking is set aside (sent_back, the note kept on it), the marker is kept from the piece (an
-- exclusion, sent_back; an existing name_seen one stays) and the piece is open for anyone. Either way an open review of
-- the piece (of any kind) closes as sent_back first, a second marking stays, and the recheck triggers remove the final
-- marks (no check state until the first marking is submitted again). Refused, in this order: invalid_input; not_found;
-- forbidden, conflict_of_interest; reason_required; conflict with reason not_submitted (no submitted first marking) or
-- changed (it changed hands meanwhile); marking_approved; marking_closed (Ruling R16: nobody could mark it again).
-- Audited marking_sent_back (to whom and the reason; the note is
-- never in the audit row). Returns {ok, to}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_send_back(p_unit uuid, p_to text, p_note text, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_reason text := public.script_resolution_reason(p_reason);
  v_u public.marking_units%rowtype;
  v_mk public.markings%rowtype;
  v_marker uuid;
  v_subject bigint;
  v_student uuid;
  v_why text;
  v_to text := p_to;
begin
  if p_unit is null or p_to is null or p_to not in ('same', 'other') or v_note is null or char_length(v_note) not between 3 and 1000 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_u from public.marking_units u where u.id = p_unit;
  if not found then
    return jsonb_build_object('ok', false, 'code', case when public.is_staff_admin() then 'not_found' else 'forbidden' end);
  end if;
  v_why := public.marking_review_refusal(p_unit);
  if v_why is not null then
    return jsonb_build_object('ok', false, 'code', v_why);
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  select m.marker_id into v_marker from public.markings m where m.unit_id = p_unit and m.kind = 'live' and m.status = 'submitted';
  if v_marker is null then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'not_submitted');
  end if;

  -- The first marker's key first, exclusive (an exclusion may be added, and the piece may go back to them, Ruling R10):
  -- their own calls wait. Then (Ruling R9) the script's locks, the piece's markings and its reviews.
  perform pg_advisory_xact_lock(hashtextextended('marker:' || v_marker::text, 0));
  perform public.marking_script_lock(v_u.script_id);
  perform 1 from public.markings m where m.unit_id = p_unit order by m.id for update;
  select * into v_mk from public.markings m where m.unit_id = p_unit and m.kind = 'live' and m.status = 'submitted';
  if v_mk.id is null then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'not_submitted');
  end if;
  if v_mk.marker_id <> v_marker then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'changed');
  end if;
  if exists (select 1 from public.exam_marking m where m.exam_id = v_u.exam_id and m.approved_at is not null) then
    return jsonb_build_object('ok', false, 'code', 'marking_approved');
  end if;
  -- Ruling R16: with marking closed nobody could mark it again.
  if exists (select 1 from public.exam_marking m where m.exam_id = v_u.exam_id and m.closed_at is not null) then
    return jsonb_build_object('ok', false, 'code', 'marking_closed');
  end if;
  perform 1 from public.marking_reviews r where r.unit_id = p_unit and r.state = 'open' order by r.id for update;

  -- To the same marker only while they may still mark it.
  select e.subject_id, b.student_id into v_subject, v_student
  from public.scripts s join public.exams e on e.id = s.exam_id join public.bookings b on b.id = s.booking_id
  where s.id = v_u.script_id;
  if v_to = 'same' and (
       not public.is_marker_for(v_marker, v_subject)
       or not public.marking_marker_cleared(v_u.exam_id, v_marker)
       or public.marking_marker_paused(v_u.exam_id, v_marker)
       or public.marking_marker_blocked(v_marker, v_student)
       or exists (select 1 from public.marking_unit_exclusions x where x.unit_id = p_unit and x.marker_id = v_marker)
       or exists (select 1 from public.marking_reviews r where r.unit_id = p_unit and r.state = 'open' and r.kind = 'paused_marker')) then
    v_to := 'other';
  end if;

  -- The open reviews close first: the evaluation the marking's change sets off finds nothing open to withdraw.
  update public.marking_reviews r
  set state = 'closed', outcome = 'sent_back', reason = v_reason, closed_by = v_actor, closed_at = now()
  where r.unit_id = p_unit and r.state = 'open';
  if v_to = 'same' then
    update public.markings m set status = 'in_progress', submitted_at = null, sent_back_note = v_note where m.id = v_mk.id;
    update public.marking_units u set state = 'taken' where u.id = p_unit;
    insert into public.marking_assignments (unit_id, kind, marker_id, how, assigned_by)
    values (p_unit, 'live', v_marker, 'assigned', v_actor);
  else
    update public.markings m
    set status = 'set_aside', set_aside_at = now(), set_aside_reason = 'sent_back', sent_back_note = v_note
    where m.id = v_mk.id;
    update public.marking_units u set state = 'open' where u.id = p_unit;
    insert into public.marking_unit_exclusions (unit_id, marker_id, reason) values (p_unit, v_marker, 'sent_back')
    on conflict (unit_id, marker_id) do nothing;
  end if;
  perform public.marking_script_state(v_u.script_id);
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marking_sent_back', 'marking_unit', p_unit, 'to ' || v_to || '; reason: ' || v_reason);
  return jsonb_build_object('ok', true, 'to', v_to);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the pieces of the exam (p_units: of those only) the routine sample may take of p_marker's work, each with
-- its submitted live marking and submitted second marking: the piece is submitted, its live marking is p_marker's and
-- submitted, and no review of that marking stands (one withdrawn does not count); it is not on hold and does not wait
-- for a second marking (the lead may yet be its second marker); its script is being marked, marked or checked and not
-- taken back; and the caller, unless an admin, is not refused it (marking_review_refusal).
-- ---------------------------------------------------------------------------------------------
create function public.marking_review_sample_pieces(p_exam uuid, p_marker uuid, p_units uuid[])
returns table (unit_id uuid, marking_id uuid, second_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select u.id, f.id,
    (select k.id from public.markings k where k.unit_id = u.id and k.kind = 'second' and k.status = 'submitted')
  from public.marking_units u
  join public.markings f on f.unit_id = u.id and f.kind = 'live' and f.status = 'submitted' and f.marker_id = p_marker
  join public.scripts s on s.id = u.script_id
  where u.exam_id = p_exam and (p_units is null or u.id = any (p_units))
    and u.state = 'submitted' and not u.on_hold
    and u.check_state is distinct from 'waiting_second'
    and s.state in ('marking', 'marked', 'checked') and s.taken_back_at is null
    and not exists (select 1 from public.marking_reviews r
                    where r.unit_id = u.id and r.marking_id = f.id and r.outcome is distinct from 'withdrawn')
    and (public.is_staff_admin() or public.marking_review_refusal(u.id) is null)
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_review_sample: the lead's routine sample of one marker's work on an exam (for the subject's lead and
-- admins): p_count (1 to 20) pieces at random of those marking_review_sample_pieces gives, each given one open sample
-- review. The pieces are held in the standard order (Ruling R16) and read again under the locks, so one whose first
-- marking was taken back or sent back meanwhile is skipped. The pieces' check states and their scripts' states are not
-- touched. Refused: invalid_input; not_found; forbidden; marking_approved. Audited marking_review_sampled when a piece is
-- added. Returns {ok, added}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_review_sample(p_exam uuid, p_marker uuid, p_count int default 5)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_admin boolean := public.is_staff_admin();
  v_subject bigint;
  v_units uuid[];
  v_n int;
begin
  if p_exam is null or p_marker is null or p_count is null or p_count not between 1 and 20 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select e.subject_id into v_subject from public.exams e where e.id = p_exam;
  if not found then
    return jsonb_build_object('ok', false, 'code', case when v_admin then 'not_found' else 'forbidden' end);
  end if;
  if not v_admin and not public.is_lead_for(v_actor, v_subject) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;

  -- The exam's marking row, then one sample of the exam at a time: two at once never review a piece twice.
  perform 1 from public.exam_marking m where m.exam_id = p_exam for share;
  if exists (select 1 from public.exam_marking m where m.exam_id = p_exam and m.approved_at is not null) then
    return jsonb_build_object('ok', false, 'code', 'marking_approved');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('marking_review_sample:' || p_exam::text, 0));

  -- The pieces, at random; then (Ruling R16) the standard order: their scripts' rows in id order and their own
  -- (marking_units_lock), then their markings. Each is read again under the locks: one whose first marking is no longer
  -- submitted (taken back or sent back meanwhile) is skipped.
  select coalesce(array_agg(t.unit_id), '{}') into v_units
  from (select p.unit_id from public.marking_review_sample_pieces(p_exam, p_marker, null) p order by random() limit p_count) t;
  v_n := 0;
  if cardinality(v_units) > 0 then
    perform public.marking_units_lock(v_units);
    perform 1 from public.markings m where m.unit_id = any (v_units) order by m.id for share;
    with added as (
      insert into public.marking_reviews (exam_id, unit_id, kind, marking_id, second_marking_id)
      select p_exam, p.unit_id, 'sample', p.marking_id, p.second_id
      from public.marking_review_sample_pieces(p_exam, p_marker, v_units) p
      returning 1
    )
    select count(*)::int into v_n from added;
  end if;
  if v_n > 0 then
    insert into public.audit_log (actor_id, action, target_type, target_id, reason)
    values (v_actor, 'marking_review_sampled', 'marker', p_marker,
      public.marker_audit_reason(v_n || case when v_n = 1 then ' piece' else ' pieces' end, 'exam: ' || p_exam::text));
  end if;
  return jsonb_build_object('ok', true, 'added', v_n);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_final_set: the lead (or an admin) changes final marks of a checked piece, with a reason (3 to 300
-- characters). p_marks: 1 or more of {question_id, mark|null, na}, each a question of the piece that takes marks, within
-- its maximum and step, and never left empty (a mark or NR). The final marks become the lead's (source lead, set by the
-- caller, with history and the reason; only what differs is written); the marker's own marks never change, and the
-- piece stays checked. The piece is then settled for its current submission (the 3B ledger's note for Task 7): its open
-- sample review closes as lead_marks and, when no closed review settles that submission (marking_unit_settled), one is
-- recorded (a closed sample review, lead_marks). Refused, in this order: invalid_input; not_found; forbidden,
-- conflict_of_interest; reason_required; marking_approved; conflict with reason with_lead (an open difference or paused
-- marker's review is settled or accepted instead) or not_checked; then invalid_input, mark_out_of_range and incomplete
-- (with missing). Audited final_mark_changed. Returns {ok, total} (the piece's final total, its "answer n of these" rule
-- applied).
-- ---------------------------------------------------------------------------------------------
create function public.marking_final_set(p_unit uuid, p_marks jsonb, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_u public.marking_units%rowtype;
  v_first public.markings%rowtype;
  v_why text;
  v_bad jsonb;
begin
  if p_unit is null or jsonb_typeof(p_marks) is distinct from 'array' then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_u from public.marking_units u where u.id = p_unit;
  if not found then
    return jsonb_build_object('ok', false, 'code', case when public.is_staff_admin() then 'not_found' else 'forbidden' end);
  end if;
  v_why := public.marking_review_refusal(p_unit);
  if v_why is not null then
    return jsonb_build_object('ok', false, 'code', v_why);
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;

  -- Ruling R9: the exam's marking row, the booking's lock, the script's row and its pieces, the piece's markings, its
  -- reviews, then its final marks.
  perform public.marking_script_lock(v_u.script_id);
  perform 1 from public.markings m where m.unit_id = p_unit order by m.id for update;
  perform 1 from public.marking_reviews r where r.unit_id = p_unit and r.state = 'open' order by r.id for update;
  select * into v_u from public.marking_units u where u.id = p_unit;
  if exists (select 1 from public.exam_marking m where m.exam_id = v_u.exam_id and m.approved_at is not null) then
    return jsonb_build_object('ok', false, 'code', 'marking_approved');
  end if;
  if v_u.check_state is distinct from 'checked' then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason',
      case when v_u.check_state = 'to_lead' then 'with_lead' else 'not_checked' end);
  end if;
  v_bad := public.marking_lead_marks_refusal(p_unit, p_marks, false);
  if v_bad is not null then
    return v_bad;
  end if;

  -- Settled for its current submission: a later marker change is refused, and no evaluation writes over these marks.
  select * into v_first from public.markings m where m.unit_id = p_unit and m.kind = 'live' and m.status = 'submitted';
  update public.marking_reviews r
  set state = 'closed', outcome = 'lead_marks', reason = v_reason, closed_by = v_actor, closed_at = now()
  where r.unit_id = p_unit and r.state = 'open' and r.kind = 'sample' and r.marking_id = v_first.id;
  if not public.marking_unit_settled(p_unit) then
    insert into public.marking_reviews (exam_id, unit_id, kind, marking_id, second_marking_id, state, outcome, reason, opened_at,
      closed_by, closed_at)
    values (v_u.exam_id, p_unit, 'sample', v_first.id,
      (select k.id from public.markings k where k.unit_id = p_unit and k.kind = 'second' and k.status = 'submitted'),
      'closed', 'lead_marks', v_reason, now(), v_actor, now());
  end if;
  perform public.marking_final_marks_lead(p_unit, p_marks, v_reason);
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'final_mark_changed', 'marking_unit', p_unit, v_reason);
  return jsonb_build_object('ok', true, 'total', public.marking_set_total(p_unit, (
    select coalesce(jsonb_agg(jsonb_build_object('question_id', f.question_id, 'mark', f.mark, 'na', f.not_attempted)), '[]'::jsonb)
    from public.final_marks f where f.unit_id = p_unit)));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_checks_set: as 20261123000005, and (3B Task 7, Ruling R11) seeded scripts or practice turned off retire the
-- exam's standards of that use still in use (marking_standard_end, by the caller: their open attempts end and those in
-- progress are set aside, switched_off; submitted attempts, and the misses they counted, stand), so Next script hands
-- out and resumes none of them, as the list's left counts none. Their scripts' rows are taken in id order, then their
-- pieces' rows. When double marking is turned off once marking has opened, the exam's pieces are checked again
-- (marking_check_exam): the pieces waiting for a second marking are released and checked. Turned on again, nothing is
-- reached back to (the decisions are kept), so nothing is checked again. p_settings has all six, in range:
-- {double_marking, sample_percent (1 to 100), tolerance_percent (1 to 50), seeds, seed_every (3 to 50), practice}, the
-- numbers whole (invalid_input otherwise). Turning any of double marking, seeds and practice off needs at most one
-- approved active marker of the subject (not_small_subject) and a reason (reason_required), and keeps the reason with
-- who and when; with all three on again they are cleared. Once marking has opened, any change needs a reason, and a
-- check turned on follows marking_open's rules: double marking needs two approved active markers (needs_two_markers),
-- seeds or practice an active lead marker (no_lead). The refusals no reason can change come before reason_required.
-- Saving the same settings changes nothing and writes no audit row; a change writes one (marking_checks_set) saying what
-- changed, with the reason. Admins only. Returns {ok, double_marking, sample_percent, tolerance_percent, seeds,
-- seed_every, practice}.
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
-- marking_my_work: as 20261123000006, and (3B Task 7) every piece says sent_back: the caller's marking of it carries
-- the lead's note (marking_send_back). The key is the same for every kind of pass, and false for a seeded or practice
-- piece as for any piece never sent back: it tells no kind of pass apart. For the caller's passes of every kind
-- (marking_pass). {ok, approved, lead_subjects: [subject ids], exams: [...], pieces: [...]}. exams: those of a subject
-- they are approved for whose marking is open, and any exam where they hold a piece or have a marking in progress; per
-- exam left counts the pieces Next script could give them now (marking_units_free; per group too, when marked by
-- question: for a marker not cleared, their practice pieces; for one cleared, seeds counted as any piece), mine counts
-- the pieces they hold and have submitted; paused, and practice ({needed: those done and those they may still do, done:
-- submitted, waiting: done some and none left} while they are not cleared for live marking on the exam, else null).
-- pieces: what they hold, have in progress and have submitted in those exams, with state (their pass: taken while they
-- hold it, submitted once their marking is, else open), how they hold it (a hold that ran out shows its end), practice (a
-- practice pass) and sent_back. No key names any other kind of pass: a seeded piece is listed as a live one. The index
-- number is shown; nothing names the candidate.
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
        'practice', p.kind = 'practice',
        -- 3B Task 7: the lead sent it back with a note; the same key, and false, for every kind never sent back.
        'sent_back', x.sent_back_note is not null)
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
-- marking_picture_paths: as 20261123000005, and (3B Task 7) branch (d). The current marking pictures of p_pages (1 to 40
-- page ids; invalid_input otherwise) of the piece p_unit (not_found when there is none), for the caller, when one of
-- these holds:
--   (a) they may work on the piece now (marking_work_blocked(p_unit, caller, p_now) is null);
--   (b) they are the subject's lead marker, marking is open, the script is ready to mark, being marked, marked or
--       checked and not taken back, they are not blocked for its candidate, the script has an open alert other than
--       name_visible and no open name_visible alert, and no requested page has an open name_visible exception;
--   (c) they are an admin (is_staff_admin);
--   (d) they may open a review of the piece (it has one; marking_review_refusal says nothing and they are not blind to
--       it, marking_review_blind), the exam's marking is not approved, the script is not taken back, and it shows no
--       name: no open name_visible alert, and no requested page with an open name_visible exception.
-- Otherwise: the refusal marking_work_blocked gave, or forbidden. Every page must be one the piece shows with a current
-- marking picture that is not its full picture: one that is not refuses the whole call (forbidden). Returns
-- {ok, paths: [{page_id, marking_path}]}, once per page, in the order asked.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_picture_paths(p_unit uuid, p_pages uuid[], p_now timestamptz default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_u public.marking_units%rowtype;
  v_why text;
  v_paths jsonb;
  v_all boolean;
begin
  if p_unit is null or p_pages is null or coalesce(cardinality(p_pages), 0) not between 1 and 40
     or array_position(p_pages, null) is not null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_u from public.marking_units u where u.id = p_unit;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  v_why := public.marking_work_blocked(p_unit, v_actor, p_now);
  if v_why is not null and not public.is_staff_admin() and not exists (
       select 1 from public.scripts s
       join public.bookings b on b.id = s.booking_id
       join public.exams e on e.id = s.exam_id
       join public.exam_marking m on m.exam_id = s.exam_id
       where s.id = v_u.script_id
         and m.opened_at is not null and m.closed_at is null
         and s.state in ('ready_to_mark', 'marking', 'marked', 'checked') and s.taken_back_at is null
         and public.is_lead_for(v_actor, e.subject_id)
         and not public.marking_marker_blocked(v_actor, b.student_id)
         and exists (select 1 from public.marking_alerts a where a.script_id = s.id and a.state = 'open' and a.kind <> 'name_visible')
         and not exists (select 1 from public.marking_alerts a where a.script_id = s.id and a.state = 'open' and a.kind = 'name_visible')
         and not exists (select 1 from public.script_exceptions v
                         where v.page_id = any (p_pages) and v.kind = 'name_visible' and v.state = 'open'))
     -- (d) 3B Task 7: a reviewer of the piece, until the exam's marking is approved.
     and not (exists (select 1 from public.marking_reviews r where r.unit_id = p_unit)
              and public.marking_review_refusal(p_unit) is null and not public.marking_review_blind(p_unit)
              and exists (
                select 1 from public.scripts s
                join public.exam_marking m on m.exam_id = s.exam_id
                where s.id = v_u.script_id and m.approved_at is null and s.taken_back_at is null
                  and not exists (select 1 from public.marking_alerts a where a.script_id = s.id and a.state = 'open' and a.kind = 'name_visible')
                  and not exists (select 1 from public.script_exceptions v
                                  where v.page_id = any (p_pages) and v.kind = 'name_visible' and v.state = 'open'))) then
    return jsonb_build_object('ok', false, 'code', coalesce(v_why, 'forbidden'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('page_id', w.page_id, 'marking_path', x.marking_path) order by w.o), '[]'::jsonb),
    coalesce(bool_and(x.page_id is not null), false)
  into v_paths, v_all
  from (select t.page_id, min(t.o) as o from unnest(p_pages) with ordinality t(page_id, o) group by t.page_id) w
  left join (
    select mp.page_id, mp.marking_path
    from public.marking_script_pages(v_u.script_id) mp
    join public.script_pages p on p.id = mp.page_id
    where mp.marking_path is not null and mp.marking_path <> p.full_path
  ) x on x.page_id = w.page_id;
  if not v_all then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  return jsonb_build_object('ok', true, 'paths', v_paths);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- The reviews of a piece, found by the piece (the one rule below asks whether a piece has any).
-- ---------------------------------------------------------------------------------------------
create index marking_reviews_unit_idx on public.marking_reviews (unit_id);

-- ---------------------------------------------------------------------------------------------
-- Internal: as 20261123000006, the one rule, and (3B Task 7, Ruling R14) a second pass is never given to the subject's
-- lead marker or a staff admin when the piece has a review of any kind, closed or withdrawn ones included: the lead's
-- list and the review screen may have shown them its first marking ("a second marker who sees neither the first marks
-- nor the first layer"). The pieces of the exam (p_unit: that one only) that p_marker may be given as a p_kind pass,
-- whatever the piece's own state and its live holder. Each piece comes with its group and its script.
--   Every kind (live, second, practice, seed): the exam's marking is open and not closed, the marker is approved for its
--   subject and not paused on the exam (read once); the piece is not on hold; its script was not taken back; the marker
--   has no declared conflict or tutor link with the candidate; they hold no open assignment of another kind on it and
--   no marking of theirs of another kind stands on it (one pass per marker).
--   live, second and seed: the marker is cleared for live marking on the exam (marking_marker_cleared).
--   live: the script is ready to mark or being marked; for Next script only (p_next), they did not see a name on it.
--   second: the script is being marked, marked or checked; the piece waits for a second marking (check_state); nobody
--   else holds its second pass and no second marking of another marker is submitted on it; they did not see a name on
--   it, whoever hands it out; and (Ruling R14) they are not the subject's lead or a staff admin when the piece has a
--   review (read once per call: whether they are is asked once, the piece's reviews only then).
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
-- Privileges. The internal functions are for definer callers only; the review functions for signed-in users (they
-- check who). Functions made again by create or replace keep theirs (restated).
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.marking_review_refusal(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_review_blind(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_review_marking(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_lead_marks_refusal(uuid, jsonb, boolean) from public, anon, authenticated, service_role;
revoke execute on function public.marking_final_marks_lead(uuid, jsonb, text) from public, anon, authenticated, service_role;
revoke execute on function public.marking_review_sample_pieces(uuid, uuid, uuid[]) from public, anon, authenticated, service_role;
revoke execute on function public.marking_units_allowed(uuid, uuid, public.marking_kind, boolean, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_unit_settled(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_check_evaluate(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_review_list(uuid, text) from public, anon;
revoke execute on function public.marking_review_open(uuid) from public, anon;
revoke execute on function public.marking_review_settle(uuid, text, int, int, text, jsonb) from public, anon;
revoke execute on function public.marking_review_accept(uuid, text) from public, anon;
revoke execute on function public.marking_send_back(uuid, text, text, text) from public, anon;
revoke execute on function public.marking_review_sample(uuid, uuid, int) from public, anon;
revoke execute on function public.marking_final_set(uuid, jsonb, text) from public, anon;
revoke execute on function public.marking_checks_set(uuid, jsonb, text) from public, anon;
revoke execute on function public.marking_my_work(timestamptz) from public, anon;
revoke execute on function public.marking_picture_paths(uuid, uuid[], timestamptz) from public, anon;
grant execute on function public.marking_review_list(uuid, text) to authenticated;
grant execute on function public.marking_review_open(uuid) to authenticated;
grant execute on function public.marking_review_settle(uuid, text, int, int, text, jsonb) to authenticated;
grant execute on function public.marking_review_accept(uuid, text) to authenticated;
grant execute on function public.marking_send_back(uuid, text, text, text) to authenticated;
grant execute on function public.marking_review_sample(uuid, uuid, int) to authenticated;
grant execute on function public.marking_final_set(uuid, jsonb, text) to authenticated;
grant execute on function public.marking_checks_set(uuid, jsonb, text) to authenticated;
grant execute on function public.marking_my_work(timestamptz) to authenticated;
grant execute on function public.marking_picture_paths(uuid, uuid[], timestamptz) to authenticated;
