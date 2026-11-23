-- Phase 3B Task 4: the check. Tolerance and the comparison of two markings, final marks, the checked state of a piece
-- and of a script, going back from checked, "Second-mark these" and its release, and a script's final total.
--
-- A piece is checked (marking_units.check_state) when its first (live) marking is submitted and nothing waits: it is
-- not in the second-marking sample, or its second marking is within tolerance, or the lead settled it. It waits for a
-- second marking (waiting_second) or is with the lead marker (to_lead) otherwise, and has no check state while its first
-- marking is not submitted. marking_check_evaluate works it out, in the order of the brief:
--   (1) the first marking is not submitted: no check state; its final marks are removed and an open difference or
--       paused-marker review is closed as withdrawn;
--   (2) an open difference or paused-marker review: to_lead (an open difference whose second marking no longer stands
--       is withdrawn first: there is nothing left to settle);
--   (3) a closed difference or paused-marker review of this first marking with outcome first_stands, second_stands,
--       lead_marks or accepted: checked, the final marks left as the settle wrote them (accepted: the first marks
--       stand, and are written as in (6)); a routine sample review never settles a piece;
--   (4) the first marker is paused on the exam: a paused_marker review is opened: to_lead;
--   (5) whether a second marking is wanted is decided once (double marking on, and the piece's stored draw under the
--       sample percentage) and then kept; wanted: no submitted second marking waits (waiting_second), a second marking
--       within tolerance is checked, one outside opens a difference review (to_lead);
--   (6) otherwise checked.
-- A piece that becomes or stays checked by (3) accepted, (5) or (6) has its final marks written from its first
-- marking (source first): only what differs is written. A piece that is not checked has no final marks: they are
-- removed with their reason. Then the script's state follows (marking_script_state: checked when every piece is).
--
-- Every write to final_marks leaves a final_mark_history row with who, when and why, by a trigger, so no later writer
-- can skip it: a final mark carries its reason (final_marks.reason, new), and a removal needs one too
-- (stem.final_marks_reason, set for the delete by marking_final_marks_remove).
--
-- A piece leaves the checked state through two triggers, whatever function moves it: marking_units_recheck (a piece
-- that leaves submitted: a take-back, a hand-back with changed pages, a question added after opening, "Name
-- visible") and markings_recheck (a live or second marking that leaves submitted). Each evaluates the piece again.
-- Their callers hold the script's and the piece's rows. A marker's change after submit evaluates it again too
-- (marking_after_change), so a second-marked piece is compared again; once the lead has settled a piece neither of its
-- markers may change a mark (marking_save: settled).
--
-- Added:
--   final_marks.reason; trigger final_marks_history.
--   marking_final_marks_from(p_unit, p_marking, p_reason), marking_final_marks_remove(p_unit, p_reason) (internal).
--   marking_tolerance(p_max, p_percent), marking_set_total(p_unit, p_set), marking_compare_sets(p_unit, p_a, p_b),
--     marking_compare(p_first, p_second) (internal): Builder's call 3.
--   marking_unit_settled(p_unit) (internal): a review settled the piece's first marking.
--   marking_check_evaluate(p_unit) (internal), triggers marking_units_recheck and markings_recheck.
--   marking_second_release(p_unit, p_reason) (internal), marking_second_add(p_units, p_reason) and
--     marking_second_drop(p_units, p_reason): "Second-mark these" and its release.
--   marking_check_exam(p_exam) (internal): every piece of an exam checked again.
--   marking_second_stuck(p_exam) (internal): the pieces waiting for a second marker whom nobody can be (Review Focus
--     2; for Task 13's dashboard and Task 7's list).
--   script_final_marks(p_script), script_final_total(p_script) (internal): what Phase 4 reads.
-- Changed, each from its latest definition:
--   marking_script_state (20261122000005): a script being marked, marked or checked is checked when it has pieces and
--     each is submitted and checked; marked when each is submitted; else as before.
--   marking_after_submit, marking_after_change (20261123000004): a live or second marking's piece is evaluated.
--   marking_save (20261123000004): a submitted live or second marking of a piece the lead settled is refused
--     (settled), before anything is written.
--   marking_checks_set (20261123000003): a change of double marking once marking has opened checks the exam's pieces
--     again (marking_check_exam).
--   exam_structure_save (20261122000015): a question added after opening also reopens the submitted second markings
--     of the pieces that hold it, as it reopens their first: back to the same marker when they may still mark it (an
--     assigned second hold), otherwise set aside (unapproved, conflict or name_seen) and given to nobody. The keys of
--     those markers are taken with the first markers'.
--   marking_units_list (20261123000004): Ruling R8: for a caller who is not an admin, p_marker finds a piece by its
--     first marker only when the piece is not blind to them.
--   'checked' beside 'marked' wherever a script is tested for being marked (the global rule): marking_on_page_picture,
--     marking_on_set_aside, marking_script_take_back_as, marking_script_take_back (20261122000008),
--     script_marking_checks_due (20261122000012, which script_marking_checks_list reads), the lead's branch of
--     marking_picture_paths (20261123000002) and script_page_marking_name_shows (20261123000004); marking_progress
--     (20261122000006) and marking_exam_get (20261122000015) count a checked script as marked.
--   Looked at and already accepting checked, or testing no script state: marking_script_hand_back,
--     marking_name_visible, marking_script_blocked, marking_script_waiting, marking_work_blocked, marking_units_allowed,
--     marking_unit_blocked (Task 3); marking_script_hold, marking_alert_can_release, script_pages_to_check,
--     script_detail, marking_on_script_state (no script-state list); the Phase 2 functions (they list checked).
-- Nothing else in them changed. Nothing here names a candidate.
--
-- Lock order (as 20261123000003): marker key -> exam_marking -> booking lock -> script rows in id order -> units in id
-- order -> assignments and markings -> marking_reviews -> final_marks -> exam_markers.

-- ---------------------------------------------------------------------------------------------
-- Final marks: why each is what it is, and its history, written by a trigger.
-- ---------------------------------------------------------------------------------------------
alter table public.final_marks add column reason text;

create function public.final_marks_history()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reason text;
begin
  if tg_op = 'DELETE' then
    v_reason := nullif(btrim(coalesce(current_setting('stem.final_marks_reason', true), '')), '');
    if v_reason is null then
      raise exception 'final_marks: every removal needs a reason';
    end if;
    insert into public.final_mark_history (unit_id, question_id, mark, not_attempted, source, removed, changed_by, changed_at, reason)
    values (old.unit_id, old.question_id, old.mark, old.not_attempted, old.source, true, auth.uid(), now(), v_reason);
    return null;
  end if;
  if nullif(btrim(coalesce(new.reason, '')), '') is null then
    raise exception 'final_marks: every final mark needs a reason';
  end if;
  if tg_op = 'UPDATE' and (old.mark, old.not_attempted, old.source, old.set_by, old.reason)
                           is not distinct from (new.mark, new.not_attempted, new.source, new.set_by, new.reason) then
    return null;
  end if;
  insert into public.final_mark_history (unit_id, question_id, mark, not_attempted, source, removed, changed_by, changed_at, reason)
  values (new.unit_id, new.question_id, new.mark, new.not_attempted, new.source, false, new.set_by, now(), new.reason);
  return null;
end;
$$;

create trigger final_marks_history after insert or update or delete on public.final_marks
  for each row
  execute function public.final_marks_history();

-- ---------------------------------------------------------------------------------------------
-- Internal: every final mark of the piece is removed, each with its history row (by the caller, for p_reason).
-- ---------------------------------------------------------------------------------------------
create function public.marking_final_marks_remove(p_unit uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.final_marks f where f.unit_id = p_unit) then
    return;
  end if;
  perform set_config('stem.final_marks_reason', p_reason, true);
  delete from public.final_marks f where f.unit_id = p_unit;
  perform set_config('stem.final_marks_reason', '', true);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the piece's final marks become p_marking's (source first for a live marking, second for a second one), for
-- each leaf of the piece the marking has a mark or NR for; set by the caller, for p_reason. Only what differs is
-- written, each write with its history row; a final mark the marking does not give is removed.
-- ---------------------------------------------------------------------------------------------
create function public.marking_final_marks_from(p_unit uuid, p_marking uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_source text;
begin
  select case m.kind when 'live' then 'first' when 'second' then 'second' end into v_source
  from public.markings m where m.id = p_marking;
  insert into public.final_marks as f (unit_id, question_id, mark, not_attempted, source, set_by, set_at, reason)
  select p_unit, q.question_id, m.mark, m.not_attempted, v_source, auth.uid(), now(), p_reason
  from public.marking_unit_questions(p_unit) q
  join public.question_marks m on m.marking_id = p_marking and m.question_id = q.question_id
  where q.leaf
  on conflict (unit_id, question_id) do update
  set mark = excluded.mark, not_attempted = excluded.not_attempted, source = excluded.source, set_by = excluded.set_by,
    set_at = excluded.set_at, reason = excluded.reason
  where (f.mark, f.not_attempted, f.source) is distinct from (excluded.mark, excluded.not_attempted, excluded.source);
  if exists (select 1 from public.final_marks f
             where f.unit_id = p_unit
               and not exists (select 1 from public.marking_unit_questions(p_unit) q
                               join public.question_marks m on m.marking_id = p_marking and m.question_id = q.question_id
                               where q.leaf and q.question_id = f.question_id)) then
    perform set_config('stem.final_marks_reason', p_reason, true);
    delete from public.final_marks f
    where f.unit_id = p_unit
      and not exists (select 1 from public.marking_unit_questions(p_unit) q
                      join public.question_marks m on m.marking_id = p_marking and m.question_id = q.question_id
                      where q.leaf and q.question_id = f.question_id);
    perform set_config('stem.final_marks_reason', '', true);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal (Builder's call 3): how far two marks of a question (or two totals) out of p_max may differ: p_percent of
-- it, at least one mark. Half marks are not rounded.
-- ---------------------------------------------------------------------------------------------
create function public.marking_tolerance(p_max numeric, p_percent int)
returns numeric
language sql
immutable
security definer
set search_path = ''
as $$
  select greatest(1, p_max * p_percent / 100.0)
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the total of a set of marks ([{question_id, mark, na}]) on a piece's questions, NR counting 0, where the
-- optional questions of a group that the piece holds count only their best `choose`, as marking_total does.
-- ---------------------------------------------------------------------------------------------
create function public.marking_set_total(p_unit uuid, p_set jsonb)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  with marks as (
    select distinct on ((e ->> 'question_id')::uuid) (e ->> 'question_id')::uuid as question_id,
      case when coalesce((e ->> 'na')::boolean, false) then 0 else coalesce((e ->> 'mark')::numeric, 0) end as mark
    from jsonb_array_elements(case when jsonb_typeof(p_set) = 'array' then p_set else '[]'::jsonb end) e
    order by (e ->> 'question_id')::uuid
  ),
  tops as (
    select q.top_id, sum(m.mark) as total
    from public.marking_unit_questions(p_unit) q
    join marks m on m.question_id = q.question_id
    where q.leaf
    group by q.top_id
  ),
  ranked as (
    select tp.total, top.option_group_id, og.choose,
      row_number() over (partition by top.option_group_id order by tp.total desc) as n
    from tops tp
    join public.exam_questions top on top.id = tp.top_id
    left join public.exam_option_groups og on og.id = top.option_group_id
  )
  select coalesce(sum(r.total) filter (where r.option_group_id is null or r.n <= r.choose), 0)
  from ranked r
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal (Builder's call 3): two sets of marks of a piece (p_a, p_b: [{question_id, mark, na}]) compared with the
-- exam's tolerance percentage (10 when the exam has none). A question is out when its marks differ by more than its
-- tolerance (marking_tolerance of its maximum); NR against 0 agrees, NR against any mark above 0 is out; a question
-- one set has no mark or NR for is out. The totals apply the piece's "answer n of these" rule (marking_set_total);
-- within is true when no question is out and the totals differ by at most the piece's tolerance. Returns {within,
-- total_a, total_b, total_tolerance, max_total, questions: [{question_id, label, max, a, a_na, b, b_na, tolerance, out}]}
-- in paper order (a and b are null for NR).
-- ---------------------------------------------------------------------------------------------
create function public.marking_compare_sets(p_unit uuid, p_a jsonb, p_b jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_percent int;
  v_max numeric := public.marking_unit_max_total(p_unit);
  v_tol numeric;
  v_ta numeric := public.marking_set_total(p_unit, p_a);
  v_tb numeric := public.marking_set_total(p_unit, p_b);
  v_questions jsonb;
  v_out boolean;
begin
  select m.tolerance_percent into v_percent
  from public.marking_units u join public.exam_marking m on m.exam_id = u.exam_id where u.id = p_unit;
  v_percent := coalesce(v_percent, 10);
  v_tol := public.marking_tolerance(v_max, v_percent);

  with a as (
    select distinct on ((e ->> 'question_id')::uuid) (e ->> 'question_id')::uuid as qid,
      coalesce((e ->> 'na')::boolean, false) as na,
      case when coalesce((e ->> 'na')::boolean, false) then null else (e ->> 'mark')::numeric end as mark
    from jsonb_array_elements(case when jsonb_typeof(p_a) = 'array' then p_a else '[]'::jsonb end) e
    order by (e ->> 'question_id')::uuid
  ),
  b as (
    select distinct on ((e ->> 'question_id')::uuid) (e ->> 'question_id')::uuid as qid,
      coalesce((e ->> 'na')::boolean, false) as na,
      case when coalesce((e ->> 'na')::boolean, false) then null else (e ->> 'mark')::numeric end as mark
    from jsonb_array_elements(case when jsonb_typeof(p_b) = 'array' then p_b else '[]'::jsonb end) e
    order by (e ->> 'question_id')::uuid
  ),
  judged as (
    select q.question_id, q.label, q.path, q.max_mark, a.mark as a_mark, coalesce(a.na, false) as a_na, b.mark as b_mark,
      coalesce(b.na, false) as b_na, public.marking_tolerance(q.max_mark, v_percent) as tol,
      case when not coalesce(a.na or a.mark is not null, false) or not coalesce(b.na or b.mark is not null, false) then true
           when a.na and b.na then false
           when a.na then b.mark > 0
           when b.na then a.mark > 0
           else abs(a.mark - b.mark) > public.marking_tolerance(q.max_mark, v_percent) end as is_out
    from public.marking_unit_questions(p_unit) q
    left join a on a.qid = q.question_id
    left join b on b.qid = q.question_id
    where q.leaf
  )
  select coalesce(jsonb_agg(jsonb_build_object('question_id', j.question_id, 'label', j.label, 'max', j.max_mark, 'a', j.a_mark,
                                               'a_na', j.a_na, 'b', j.b_mark, 'b_na', j.b_na, 'tolerance', j.tol, 'out', j.is_out)
                            order by j.path), '[]'::jsonb),
    coalesce(bool_or(j.is_out), false)
  into v_questions, v_out
  from judged j;

  return jsonb_build_object('within', not v_out and abs(v_ta - v_tb) <= v_tol, 'total_a', v_ta, 'total_b', v_tb,
    'total_tolerance', v_tol, 'max_total', v_max, 'questions', v_questions);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: marking_compare_sets for two markings of one piece (the first's piece), from their question marks.
-- ---------------------------------------------------------------------------------------------
create function public.marking_compare(p_first uuid, p_second uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.marking_compare_sets(f.unit_id,
    (select coalesce(jsonb_agg(jsonb_build_object('question_id', m.question_id, 'mark', m.mark, 'na', m.not_attempted)), '[]'::jsonb)
     from public.question_marks m where m.marking_id = p_first),
    (select coalesce(jsonb_agg(jsonb_build_object('question_id', m.question_id, 'mark', m.mark, 'na', m.not_attempted)), '[]'::jsonb)
     from public.question_marks m where m.marking_id = p_second))
  from public.markings f where f.id = p_first
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: whether the lead settled the piece's first marking (its live marking that is not set aside): a closed
-- difference or paused-marker review of it whose outcome stands (first_stands, second_stands, lead_marks, accepted).
-- A routine sample review never settles a piece.
-- ---------------------------------------------------------------------------------------------
create function public.marking_unit_settled(p_unit uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.marking_reviews r
    join public.markings m on m.id = r.marking_id
    where r.unit_id = p_unit and r.state = 'closed' and r.kind in ('difference', 'paused_marker')
      and r.outcome in ('first_stands', 'second_stands', 'lead_marks', 'accepted')
      and m.unit_id = p_unit and m.kind = 'live' and m.status <> 'set_aside')
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: as 20261122000005, and checked. A script being marked, marked or checked takes its state from its units:
-- checked when it has units and every one is submitted and checked; marked when every one is submitted; being marked
-- when a unit is taken or submitted or has a marking; else ready to mark. Scripts in other states are left as they
-- are. The script's row is held first, so two units submitted at the same moment end with the script marked.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_script_state(p_script uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_state public.script_state;
  v_new public.script_state;
begin
  select s.state into v_state from public.scripts s where s.id = p_script for no key update;
  if not found or v_state not in ('ready_to_mark', 'marking', 'marked', 'checked') then
    return;
  end if;
  select case
      when count(*) > 0 and bool_and(u.state = 'submitted' and u.check_state is not distinct from 'checked') then 'checked'
      when count(*) > 0 and bool_and(u.state = 'submitted') then 'marked'
      when bool_or(u.state in ('taken', 'submitted') or exists (select 1 from public.markings m where m.unit_id = u.id)) then 'marking'
      else 'ready_to_mark'
    end::public.script_state
  into v_new
  from public.marking_units u where u.script_id = p_script;
  if v_new <> v_state then
    update public.scripts set state = v_new where id = p_script;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the piece's check, worked out again (see the header, rules 1 to 6): sets its check_state, second_wanted
-- (decided once), checked_at (when it became checked) and final_marking_id (the marking its final marks came from; null
-- unless checked), writes or removes its final marks, opens or withdraws its reviews, and then its script's state
-- follows. The caller holds the script's and the piece's rows. Returns the check state.
-- ---------------------------------------------------------------------------------------------
create function public.marking_check_evaluate(p_unit uuid)
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

  if v_first.id is null or v_first.status <> 'submitted' then
    -- (1) Nothing to check: what waited for the lead is withdrawn.
    update public.marking_reviews r set state = 'closed', outcome = 'withdrawn', closed_by = v_actor, closed_at = now()
    where r.unit_id = p_unit and r.state = 'open' and r.kind in ('difference', 'paused_marker');
    v_state := null;
  else
    -- A difference whose markings no longer both stand has nothing left to settle.
    update public.marking_reviews r set state = 'closed', outcome = 'withdrawn', closed_by = v_actor, closed_at = now()
    where r.unit_id = p_unit and r.state = 'open' and r.kind = 'difference'
      and (r.marking_id <> v_first.id or r.second_marking_id is distinct from v_second.id);
    select r.* into v_r from public.marking_reviews r
    where r.unit_id = p_unit and r.marking_id = v_first.id and r.state = 'closed' and r.kind in ('difference', 'paused_marker')
      and r.outcome in ('first_stands', 'second_stands', 'lead_marks', 'accepted')
    order by r.closed_at desc, r.id
    limit 1;
    if exists (select 1 from public.marking_reviews r
               where r.unit_id = p_unit and r.state = 'open' and r.kind in ('difference', 'paused_marker')) then
      v_state := 'to_lead';  -- (2)
    elsif v_r.id is not null then
      -- (3) Settled: the final marks are as the settle wrote them; accepted, the first marks stand.
      v_state := 'checked';
      if v_r.outcome = 'accepted' then
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
-- Going back from checked: a piece that leaves submitted, or a live or second marking that leaves submitted, is
-- evaluated again (its caller holds the script's and the piece's rows).
-- ---------------------------------------------------------------------------------------------
create function public.marking_units_recheck()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.marking_check_evaluate(new.id);
  return null;
end;
$$;

create trigger marking_units_recheck after update of state on public.marking_units
  for each row
  when (old.state = 'submitted' and new.state <> 'submitted')
  execute function public.marking_units_recheck();

create function public.markings_recheck()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.marking_check_evaluate(new.unit_id);
  return null;
end;
$$;

create trigger markings_recheck after update of status on public.markings
  for each row
  when (old.status = 'submitted' and new.status <> 'submitted' and new.kind in ('live', 'second'))
  execute function public.markings_recheck();

-- ---------------------------------------------------------------------------------------------
-- Internal: as 20261123000004, now the check: after a live or second marking is submitted its piece is evaluated
-- (marking_check_evaluate). The answer is the submit's feedback: null (Task 5 fills it). The caller holds the script's
-- and the piece's rows.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_after_submit(p_marking uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_unit uuid;
begin
  select m.unit_id into v_unit from public.markings m where m.id = p_marking and m.kind in ('live', 'second');
  if v_unit is not null then
    perform public.marking_check_evaluate(v_unit);
  end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: as 20261123000004, now the check: after a change to a submitted live or second marking its piece is
-- evaluated again (a checked piece's final marks are written again, with history; a second-marked piece is compared
-- again). The caller holds the script's and the piece's rows.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_after_change(p_marking uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_unit uuid;
begin
  select m.unit_id into v_unit from public.markings m where m.id = p_marking and m.kind in ('live', 'second');
  if v_unit is not null then
    perform public.marking_check_evaluate(v_unit);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_save: as 20261123000004, and a submitted live or second marking of a piece the lead settled
-- (marking_unit_settled) is refused with settled, before anything is written. On the caller's own marking of any kind:
-- their pass's hold (a Next script hold is renewed) and, on a submitted marking, marking_after_change once the change is
-- written (the script's and the piece's rows are held). Refused: invalid_input, forbidden (not the caller's marking),
-- conflict (set_aside, or rev with the current rev), on_hold, hold_expired, pictures_updating, marking_closed, settled,
-- reason_required, incomplete, mark_out_of_range. Returns {ok, rev, total, hold_until}.
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
-- Internal: the piece's second marking is no longer wanted. Its open second hold ends (switched_off), a second marking
-- in progress is set aside (switched_off), second_wanted is false; audited marking_second_dropped with p_reason, by the
-- caller. The caller holds the script's and the piece's rows and evaluates the piece afterwards.
-- ---------------------------------------------------------------------------------------------
create function public.marking_second_release(p_unit uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.marking_assignments a set ended_at = now(), end_reason = 'switched_off'
  where a.unit_id = p_unit and a.kind = 'second' and a.ended_at is null;
  update public.markings m set status = 'set_aside', set_aside_at = now(), set_aside_reason = 'switched_off'
  where m.unit_id = p_unit and m.kind = 'second' and m.status = 'in_progress';
  update public.marking_units u set second_wanted = false where u.id = p_unit;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (auth.uid(), 'marking_second_dropped', 'marking_unit', p_unit, p_reason);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_second_add ("Second-mark these"): an admin, or the lead of each piece's subject, asks for 1 to 200 pieces to
-- be second-marked, with a reason (3 to 300 characters). A piece is skipped, with its code, when: not_found; forbidden
-- (a lead who does not lead its subject); conflict_of_interest (a lead with a declared conflict or a tutor link for
-- its candidate); marking_closed; not_submitted (its first marking is not submitted); settled (the lead settled it);
-- with_lead (it is with the lead marker); already (a second marking is wanted already). Otherwise second_wanted is set
-- and the piece is evaluated again (waiting_second: its final marks are removed and its script is marked again).
-- Audited per piece (marking_second_added). Refused: forbidden (neither an admin nor a lead marker), invalid_input,
-- reason_required. Returns {ok, added, skipped: [{unit_id, code}]}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_second_add(p_units uuid[], p_reason text)
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
-- marking_second_drop: an admin, or the lead of each piece's subject, releases 1 to 200 pieces waiting for a second
-- marking, with a reason (3 to 300 characters): a stuck piece is released this way (Review Focus 2). Each waiting
-- piece's second marking is no longer wanted (marking_second_release: its open second hold ends and a second marking in
-- progress is set aside, switched_off; audited marking_second_dropped with the reason) and it is evaluated again
-- (checked, on its first marks). A piece is skipped, with its code, when: not_found; forbidden; conflict_of_interest
-- (as marking_second_add); not_waiting (it does not wait for a second marking). Refused: forbidden, invalid_input,
-- reason_required. Returns {ok, dropped, skipped: [{unit_id, code}]}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_second_drop(p_units uuid[], p_reason text)
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
-- Internal: every piece of the exam whose first marking is submitted is evaluated again. With double marking off, every
-- piece still waiting for a second marking that has not come (wanted, no check state or waiting_second, no second
-- marking submitted) has it released first, as marking_second_drop does (reason: double marking was turned off).
-- Holds the exam's marking row, then the exam's scripts in id order, then its pieces in id order. Returns how many
-- pieces it evaluated.
-- ---------------------------------------------------------------------------------------------
create function public.marking_check_exam(p_exam uuid)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_m public.exam_marking%rowtype;
  v_n int := 0;
  r record;
begin
  select * into v_m from public.exam_marking m where m.exam_id = p_exam for share;
  perform 1 from public.scripts s
  where s.id in (select u.script_id from public.marking_units u where u.exam_id = p_exam)
  order by s.id
  for no key update;
  perform 1 from public.marking_units u where u.exam_id = p_exam order by u.id for update;
  if not coalesce(v_m.double_marking, true) then
    for r in
      select u.id from public.marking_units u
      where u.exam_id = p_exam and u.second_wanted and (u.check_state is null or u.check_state = 'waiting_second')
        and not exists (select 1 from public.markings k where k.unit_id = u.id and k.kind = 'second' and k.status = 'submitted')
      order by u.id
    loop
      perform public.marking_second_release(r.id, 'Double marking was turned off.');
    end loop;
  end if;
  for r in
    select u.id from public.marking_units u
    where u.exam_id = p_exam
      and exists (select 1 from public.markings k where k.unit_id = u.id and k.kind = 'live' and k.status = 'submitted')
    order by u.id
  loop
    perform public.marking_check_evaluate(r.id);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_checks_set: as 20261123000003, and when double marking is turned on or off once marking has opened, the
-- exam's pieces are checked again (marking_check_exam): off, the pieces waiting for a second marking are released and
-- checked; on again, nothing already checked is reached back to (the decisions are kept). p_settings has all six, in
-- range: {double_marking, sample_percent (1 to 100), tolerance_percent (1 to 50), seeds, seed_every (3 to 50),
-- practice}, the numbers whole (invalid_input otherwise). Turning any of double marking, seeds and practice off needs at
-- most one approved active marker of the subject (not_small_subject) and a reason (reason_required), and keeps the
-- reason with who and when; with all three on again they are cleared. Once marking has opened, any change needs a
-- reason, and a check turned on follows marking_open's rules: double marking needs two approved active markers
-- (needs_two_markers), seeds or practice an active lead marker (no_lead). The refusals no reason can change come before
-- reason_required. Saving the same settings changes nothing and writes no audit row; a change writes one
-- (marking_checks_set) saying what changed, with the reason. Admins only. Returns {ok, double_marking, sample_percent,
-- tolerance_percent, seeds, seed_every, practice}.
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
  -- 3B Task 4: double marking turned on or off once marking has opened: the exam's pieces are checked again.
  if v_m.opened_at is not null and v_dm <> v_was_dm then
    perform public.marking_check_exam(p_exam);
  end if;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marking_checks_set', 'exam', p_exam,
    array_to_string(v_changes, '; ') || coalesce('; reason: ' || v_reason, ''));
  return jsonb_build_object('ok', true, 'double_marking', v_dm, 'sample_percent', v_sp, 'tolerance_percent', v_tp,
    'seeds', v_se, 'seed_every', v_sv, 'practice', v_pr);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal (Review Focus 2): the pieces of the exam waiting for a second marking (not on hold) that no approved active
-- marker of the subject may be given as a second pass (marking_units_allowed, second, as an admin would hand it out):
-- nobody can second-mark them. A piece whose second pass a marker holds and may keep is not stuck. Lead and admin
-- pages count these; marking_second_drop releases them.
-- ---------------------------------------------------------------------------------------------
create function public.marking_second_stuck(p_exam uuid)
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
    and not exists (select 1 from allowed w where w.unit_id = u.id)
  order by u.id
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal (what Phase 4 reads): a checked script's final mark per question, from final_marks only (no rows unless the
-- script is checked).
-- ---------------------------------------------------------------------------------------------
create function public.script_final_marks(p_script uuid)
returns table (question_id uuid, mark numeric, not_attempted boolean, source text)
language sql
stable
security definer
set search_path = ''
as $$
  select f.question_id, f.mark, f.not_attempted, f.source
  from public.scripts s
  join public.marking_units u on u.script_id = s.id
  join public.final_marks f on f.unit_id = u.id
  where s.id = p_script and s.state = 'checked'
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal (what Phase 4 reads): a checked script's total, from its final marks (script_final_marks; NR counts 0), where
-- each group of optional questions counts only its best `choose` questions across the whole script, as
-- exam_structure_max_total counts the maximum. Never the sum of piece totals: a piece counts "answer n of these" inside
-- itself only. Null unless the script is checked.
-- ---------------------------------------------------------------------------------------------
create function public.script_final_total(p_script uuid)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  with recursive tree as (
    select q.id, q.id as top_id
    from public.scripts s join public.exam_questions q on q.exam_id = s.exam_id and q.parent_id is null
    where s.id = p_script
    union all
    select c.id, t.top_id from public.exam_questions c join tree t on c.parent_id = t.id
  ),
  tops as (
    select t.top_id, sum(coalesce(f.mark, 0)) as total
    from tree t join public.script_final_marks(p_script) f on f.question_id = t.id
    group by t.top_id
  ),
  ranked as (
    select tp.total, top.option_group_id, og.choose,
      row_number() over (partition by top.option_group_id order by tp.total desc) as n
    from tops tp
    join public.exam_questions top on top.id = tp.top_id
    left join public.exam_option_groups og on og.id = top.option_group_id
  )
  select case when (select s.state from public.scripts s where s.id = p_script) = 'checked'
              then coalesce(sum(r.total) filter (where r.option_group_id is null or r.n <= r.choose), 0) end
  from ranked r
$$;

-- ---------------------------------------------------------------------------------------------
-- As 20261122000008, and a checked script too: a page's marking picture went (picture_missing), or was made again to
-- hide something else (picture_changed: its inputs key differs; a first picture, with no key before, counts as changed),
-- while a script being marked, marked or checked shows it (marking_script_pages): that script's pieces are held
-- (marking_script_hold). A picture made again from the same inputs holds nothing, raises no alert and sends no email.
-- The rows of every such script that shows a page of the same file are taken first, in id order.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_on_page_picture()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hold text := case when new.marking_path is null then 'picture_missing' else 'picture_changed' end;
  v_s uuid;
begin
  -- The scripts that may show this page: those whose current version links it, and the home script of the hand-in it
  -- came with (an extra page). Usually none is being marked, and nothing more is done.
  if not exists (
       select 1 from public.scripts s
       where s.state in ('ready_to_mark', 'marking', 'marked', 'checked')
         and s.id in (select l.script_id from public.script_page_links l
                      join public.scripts x on x.id = l.script_id and x.version = l.version
                      where l.page_id = new.id
                      union
                      select x.id from public.script_uploads u
                      join public.home_submissions hs on hs.id = u.submission_id
                      join public.scripts x on x.booking_id = hs.booking_id
                      where u.id = new.upload_id)) then
    return null;
  end if;

  perform 1 from public.scripts s
  where s.state in ('ready_to_mark', 'marking', 'marked', 'checked')
    and s.id in (select l.script_id from public.script_pages p
                 join public.script_page_links l on l.page_id = p.id
                 join public.scripts x on x.id = l.script_id and x.version = l.version
                 where p.upload_id = new.upload_id
                 union
                 select x.id from public.script_uploads u
                 join public.home_submissions hs on hs.id = u.submission_id
                 join public.scripts x on x.booking_id = hs.booking_id
                 where u.id = new.upload_id)
  order by s.id
  for no key update;

  for v_s in
    select s.id from public.scripts s
    where s.state in ('ready_to_mark', 'marking', 'marked', 'checked')
      and s.id in (select l.script_id from public.script_page_links l
                   join public.scripts x on x.id = l.script_id and x.version = l.version
                   where l.page_id = new.id
                   union
                   select x.id from public.script_uploads u
                   join public.home_submissions hs on hs.id = u.submission_id
                   join public.scripts x on x.booking_id = hs.booking_id
                   where u.id = new.upload_id)
      and exists (select 1 from public.marking_script_pages(s.id) x where x.page_id = new.id)
    order by s.id
  loop
    perform public.marking_script_hold(v_s, v_hold, v_hold, new.id);
  end loop;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- As 20261122000008, and a checked script too: a page set aside because its script is being marked (Phase 2:
-- not_expected, reason script_locked): a pages_set_aside alert for that script. Nothing is held.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_on_set_aside()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s public.scripts%rowtype;
begin
  select * into v_s from public.scripts s
  where s.id = coalesce(new.script_id, (select x.id from public.scripts x where x.booking_id = new.booking_id));
  if v_s.id is not null and v_s.state in ('ready_to_mark', 'marking', 'marked', 'checked') then
    perform public.marking_alert_raise(v_s.id, 'pages_set_aside', null, new.page_id);
  end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: as 20261122000008, and a checked script too. The script is taken back from the markers, by p_actor. Every
-- piece goes on hold (name_visible when p_reason is 'name_visible', else taken_back); the holds and markings are kept,
-- so each piece returns to its marker; taken_back_at, taken_back_by and taken_back_reason are set; the script needs
-- attention and is worked out again (script_evaluate: verified when nothing is open). Audited
-- (marking_script_taken_back). The caller holds the locks (marking_script_lock) and has checked the script is being
-- marked (ready to mark, being marked, marked or checked) and not taken back.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_script_take_back_as(p_script uuid, p_actor uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.scripts s
                 where s.id = p_script and s.state in ('ready_to_mark', 'marking', 'marked', 'checked') and s.taken_back_at is null) then
    raise exception 'marking_script_take_back_as: the script is not being marked';
  end if;
  update public.marking_units u
  set on_hold = true, hold_reason = case when p_reason = 'name_visible' then 'name_visible' else 'taken_back' end
  where u.script_id = p_script;
  update public.scripts
  set taken_back_at = now(), taken_back_by = p_actor, taken_back_reason = p_reason, state = 'needs_attention'
  where id = p_script;
  perform public.script_evaluate(p_script);
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (p_actor, 'marking_script_taken_back', 'script', p_script,
    case when p_reason = 'name_visible' then 'A marker reported a visible name.' else p_reason end);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_script_take_back: as 20261122000008, and a checked script too: an admin takes a script being marked (ready to
-- mark, being marked, marked or checked) back from the markers, with a reason (marking_script_take_back_as). Refused:
-- forbidden, invalid_input, reason_required, not_found, conflict with reason taken_back (already) or not_marking.
-- Returns {ok, state}.
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
-- Internal: as 20261122000012, and a checked script too (script_marking_checks_list reads it): the pages to check.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_marking_checks_due(p_exam uuid default null)
returns table (script_id uuid, page_id uuid, copy_page int)
language sql
stable
security definer
set search_path = ''
as $$
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
    where s.state in ('receiving', 'checking', 'needs_attention', 'verified', 'ready_to_mark', 'marking', 'marked', 'checked')
      and s.id in (select l.script_id from pages pg
                   join public.script_page_links l on l.page_id = pg.id
                   join public.scripts x on x.id = l.script_id and x.version = l.version
                   union
                   select x.id from pages pg
                   join public.script_pages p on p.id = pg.id
                   join public.script_uploads u on u.id = p.upload_id
                   join public.home_submissions hs on hs.id = u.submission_id
                   join public.scripts x on x.booking_id = hs.booking_id)
  )
  select distinct on (t.page_id) sc.id, t.page_id, t.copy_page
  from scripts sc cross join lateral public.script_pages_to_check(sc.id) t
  where t.page_id in (select pg.id from pages pg)
  order by t.page_id, sc.id
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_progress: as 20261122000006, and scripts.marked counts checked scripts too (every piece submitted). What is
-- left, per exam and per marker. Admins: every exam with marking settings (p_exam: that one); a lead marker: the exams
-- of the subjects they lead. Per exam: {exam_id, title, paper, subject, mode, deadline, overdue (marking_exam_overdue),
-- opened_at, closed_at, scripts: {waiting (verified, not yet ready), ready_to_mark, marking, marked (marked or
-- checked)}, units: {open, taken, submitted (not on hold), on_hold} of scripts not withdrawn or void, markers:
-- [{marker_id, name, taken, submitted, last_saved_at}], alerts_open}. A marker's name is never their email (as
-- marking_units_list).
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
                    'marked', count(*) filter (where s.state in ('marked', 'checked')))
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
-- marking_exam_get: as 20261122000015, and scripts.marked counts checked scripts too (every piece submitted).
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_exam_get(p_exam uuid, p_now timestamptz default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := public.paper_clock(p_now);
  v_e public.exams%rowtype;
  v_m public.exam_marking%rowtype;
  v_waiting jsonb;
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

  -- What each script waits for, read once per script (a materialised step), then counted.
  with t as materialized (
    select public.marking_script_waiting(s.id, v_now) as why from public.scripts s
    where s.exam_id = p_exam and s.state in ('verified', 'ready_to_mark', 'marking')
  )
  select jsonb_build_object(
    'home_window_open', count(*) filter (where t.why = 'home_window_open'),
    'centre_pages_unsettled', count(*) filter (where t.why = 'centre_pages_unsettled'),
    'pictures_updating', count(*) filter (where t.why = 'pictures_updating'),
    'late_undecided', count(*) filter (where t.why = 'late_undecided'),
    'taken_back', count(*) filter (where t.why = 'taken_back'),
    'picture_unchecked', count(*) filter (where t.why = 'picture_unchecked'))
  into v_waiting
  from t;

  return jsonb_build_object(
    'ok', true,
    'mode', coalesce(v_m.mode, 'whole'),
    'deadline', v_m.deadline,
    'opened_at', v_m.opened_at,
    'closed_at', v_m.closed_at,
    'structure', jsonb_build_object(
      'version', coalesce(v_m.structure_version, 0),
      'leaves', (select count(*)::int from public.exam_questions q
                 where q.exam_id = p_exam and not exists (select 1 from public.exam_questions c where c.parent_id = q.id)),
      'max_total', public.exam_structure_max_total(p_exam),
      'ungrouped', (select count(*)::int from public.exam_questions q where q.exam_id = p_exam and q.parent_id is null and q.group_id is null)),
    'markers', (select count(*)::int from public.marker_approvals a
                where a.subject_id = v_e.subject_id and public.is_marker_for(a.marker_id, a.subject_id)),
    'scripts', (select jsonb_build_object(
                  'verified', count(*) filter (where s.state = 'verified'),
                  'ready_to_mark', count(*) filter (where s.state = 'ready_to_mark'),
                  'marking', count(*) filter (where s.state = 'marking'),
                  'marked', count(*) filter (where s.state in ('marked', 'checked')))
                from public.scripts s where s.exam_id = p_exam),
    'waiting', v_waiting);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_picture_paths: as 20261123000002, and in the lead's branch (b) a checked script too. The current marking
-- pictures of p_pages (1 to 40 page ids; invalid_input otherwise) of the piece p_unit (not_found when there is none),
-- for the caller, when one of these holds:
--   (a) they may work on the piece now (marking_work_blocked(p_unit, caller, p_now) is null);
--   (b) they are the subject's lead marker, marking is open, the script is ready to mark, being marked, marked or
--       checked and not taken back, they are not blocked for its candidate, the script has an open alert other than
--       name_visible and no open name_visible alert, and no requested page has an open name_visible exception;
--   (c) they are an admin (is_staff_admin).
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
                         where v.page_id = any (p_pages) and v.kind = 'name_visible' and v.state = 'open')) then
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
-- script_page_marking_name_shows: as 20261123000004, and a checked script too, wherever a script being marked or marked
-- is meant. "A name still shows" (an admin, with a reason): a name_visible exception for the page ({"from":
-- "staff_check"}), unless one is open. On a script with markers that shows the page (being marked, marked or checked,
-- or taken back from them already), every marker with a marking of any kind on it that is not set aside may have seen
-- the name: on every piece of the script their holds of every kind end, their markings in progress are set aside and
-- they are excluded (name_seen); the pieces whose live pass they no longer hold are open; their submitted markings
-- stand. A script being marked is then taken back (marking_script_take_back_as, with the reason). Audited
-- script_page_marking_name_shows. Refused also: forbidden, invalid_input (no page), reason_required, not_found, conflict
-- with reason changed (a rerun replaced the page). Answers {ok, exception_id}.
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
  -- The scripts with markers that show the page (being marked, marked or checked, or taken back from the markers):
  -- every marker who may have seen the page (a marking of any kind on it, not set aside) is kept from it below, and one
  -- being marked is taken back. Ruling R10: those markers' keys first, exclusive (exclusions are added), in uuid order;
  -- then (Ruling R9) the scripts' locks.
  for v_m in
    select distinct m.marker_id from public.scripts s
    join public.marking_units u on u.script_id = s.id
    join public.markings m on m.unit_id = u.id
    where s.booking_id = any (v_owners) and (s.taken_back_at is not null or s.state in ('ready_to_mark', 'marking', 'marked', 'checked'))
      and m.status <> 'set_aside'
    order by 1
  loop
    perform pg_advisory_xact_lock(hashtextextended('marker:' || v_m::text, 0));
  end loop;
  for v_s in
    select s.id from public.scripts s
    where s.booking_id = any (v_owners) and (s.taken_back_at is not null or s.state in ('ready_to_mark', 'marking', 'marked', 'checked'))
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

  -- A script with markers that shows the page to them (being marked, marked or checked, or taken back already; its locks
  -- are held, and one that came to be marked meanwhile has them taken here). Every marker with a marking of any kind on
  -- it that is not set aside may have seen the name, as with a marker's Name visible: on every piece of the script their
  -- holds end (name_seen), their markings in progress are set aside (name_seen), the pieces whose live pass they no
  -- longer hold are open, and Next script never offers them a piece of it again (an exclusion). Their submitted
  -- markings stand. A script being marked then goes back to staff; one taken back already stays as it is.
  for v_s in
    select s.id from public.scripts s
    where s.booking_id = any (v_bookings) and (s.taken_back_at is not null or s.state in ('ready_to_mark', 'marking', 'marked', 'checked'))
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
               where s.id = v_s and s.taken_back_at is null and s.state in ('ready_to_mark', 'marking', 'marked', 'checked')) then
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
-- exam_structure_save: as 20261122000015, and a question added once marking has opened also reopens the submitted
-- second markings of the pieces that hold it, as it reopens their first markings: each goes back to its marker when
-- they may still mark it (an assigned second hold, unless the second pass has an open one), otherwise it is set aside
-- (name_seen, conflict or unapproved) and given to nobody. The keys of the markers of submitted live and second markings
-- are taken (shared, in uuid order) before the exam's marking row, and a second marking submitted meanwhile makes the
-- save fail (40001) as a first one does. A piece's own state follows its first marking only; its check is worked out
-- again by the recheck triggers (no check state until its first marking is submitted again; then, wanted, it waits for
-- its second marking until that is submitted again and compared on every question).
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
    -- A maximum cannot go below a mark already given.
    if exists (
         select 1 from jsonb_array_elements(v_qs) e
         join public.question_marks m on m.question_id = (e ->> 'id')::uuid
         where e ->> 'id' is not null and m.mark > (e ->> 'max_mark')::numeric) then
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
-- marking_units_list: as 20261123000004, and (Ruling R8) for a caller who is not an admin p_marker finds a piece by its
-- first marker only when the piece is not blind to them: a lead filtering by each marker cannot learn who first-marked
-- a piece they are blind to. Each piece also says check_state and second: who has its second pass and how
-- ({marker_id, marker_name, state: taken while they hold it, submitted once their second marking is, else open (their
-- marking in progress, no hold), how}, or null when nobody does). p_marker also keeps the pieces whose second pass that
-- marker holds or has marked. For admins and the subject's lead marker. A lead (any caller who is not an admin) is
-- blind to the first marking of a piece waiting for a second marking, and of a piece whose second pass is theirs (they
-- hold it, or have a second marking of it that is not set aside, whatever its status): its marker_id, marker_name,
-- last_saved_at, submitted_at and total are null. Admins see everything. Returns {ok, units, more}.
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
-- Privileges. The internal functions and the trigger functions are for definer callers only; marking_second_add and
-- marking_second_drop for signed-in users (they check who). Functions made again by create or replace keep theirs
-- (restated).
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.final_marks_history() from public, anon, authenticated, service_role;
revoke execute on function public.marking_units_recheck() from public, anon, authenticated, service_role;
revoke execute on function public.markings_recheck() from public, anon, authenticated, service_role;
revoke execute on function public.marking_final_marks_remove(uuid, text) from public, anon, authenticated, service_role;
revoke execute on function public.marking_final_marks_from(uuid, uuid, text) from public, anon, authenticated, service_role;
revoke execute on function public.marking_tolerance(numeric, int) from public, anon, authenticated, service_role;
revoke execute on function public.marking_set_total(uuid, jsonb) from public, anon, authenticated, service_role;
revoke execute on function public.marking_compare_sets(uuid, jsonb, jsonb) from public, anon, authenticated, service_role;
revoke execute on function public.marking_compare(uuid, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_unit_settled(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_check_evaluate(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_second_release(uuid, text) from public, anon, authenticated, service_role;
revoke execute on function public.marking_check_exam(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_second_stuck(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_final_marks(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.script_final_total(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_script_state(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_after_submit(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_after_change(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_on_page_picture() from public, anon, authenticated, service_role;
revoke execute on function public.marking_on_set_aside() from public, anon, authenticated, service_role;
revoke execute on function public.marking_script_take_back_as(uuid, uuid, text) from public, anon, authenticated, service_role;
revoke execute on function public.script_marking_checks_due(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_second_add(uuid[], text) from public, anon;
revoke execute on function public.marking_second_drop(uuid[], text) from public, anon;
revoke execute on function public.marking_save(uuid, int, jsonb, int, text, timestamptz) from public, anon;
revoke execute on function public.marking_checks_set(uuid, jsonb, text) from public, anon;
revoke execute on function public.marking_script_take_back(uuid, text) from public, anon;
revoke execute on function public.marking_progress(uuid, timestamptz) from public, anon;
revoke execute on function public.marking_exam_get(uuid, timestamptz) from public, anon;
revoke execute on function public.marking_picture_paths(uuid, uuid[], timestamptz) from public, anon;
revoke execute on function public.script_page_marking_name_shows(uuid, text) from public, anon;
revoke execute on function public.exam_structure_save(uuid, jsonb, text) from public, anon;
revoke execute on function public.marking_units_list(uuid, text, uuid) from public, anon;
grant execute on function public.marking_second_add(uuid[], text) to authenticated;
grant execute on function public.marking_second_drop(uuid[], text) to authenticated;
grant execute on function public.marking_save(uuid, int, jsonb, int, text, timestamptz) to authenticated;
grant execute on function public.marking_checks_set(uuid, jsonb, text) to authenticated;
grant execute on function public.marking_script_take_back(uuid, text) to authenticated;
grant execute on function public.marking_progress(uuid, timestamptz) to authenticated;
grant execute on function public.marking_exam_get(uuid, timestamptz) to authenticated;
grant execute on function public.marking_picture_paths(uuid, uuid[], timestamptz) to authenticated;
grant execute on function public.script_page_marking_name_shows(uuid, text) to authenticated;
grant execute on function public.exam_structure_save(uuid, jsonb, text) to authenticated;
grant execute on function public.marking_units_list(uuid, text, uuid) to authenticated;
