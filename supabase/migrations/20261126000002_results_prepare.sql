-- ---------------------------------------------------------------------------------------------
-- Phase 4A, Task 3: an admin prepares an exam's results from the final marks, with grade boundaries, statuses and fair
-- ranks. Before publication only (Ruling R1): everything here that changes results is refused results_published while
-- the exam's results are scheduled or published; a state of withdrawn is treated as prepared (the results may be
-- prepared again). The correction after publication and the recording of a published version are Task 4's.
--
-- Who has a result (Builder's call 4): every booking of the exam that is paid, part refunded or awaiting a cancellation
-- decision, and every booking that has a script (a row ever published is kept too). Its status, unless an admin set
-- one (absent, incomplete or disqualified, with a reason, which stands until the admin sets auto):
--   present     a script that is not withdrawn or void (approval, not stale, means it is checked);
--   withdrawn   the script was withdrawn;
--   incomplete  the script was void;
--   absent      no script (absent on the register, at home without a script, or not on the register).
-- A centre candidate marked present or late on the register with no script and no admin-set status is missing: it
-- stops preparation (missing_scripts, with the count) until an admin sets their status. Only present candidates have
-- marks: the total is script_final_total, the marks per question script_final_marks (changed_on_review when the final
-- mark's source is the lead), never markings.total. Every other status has no total, percentage, grade or rank.
--
-- The rules, each in one internal helper (Ruling R2; Task 9's re-mark reuses them):
--   result_percentage(total, max): the total out of the paper's maximum, to one decimal place, half up (Call 5).
--   result_grade(total, grades): the grade of the highest boundary at or below the total, "U" below the lowest; none
--     without boundaries (Call 6). Boundaries are raw marks: 1 to 15 grades, top first, labels of 1 to 10 characters,
--     lowest marks strictly decreasing, at most one decimal place and not above the paper's maximum.
--   result_rank(total, totals): 1 + how many of the totals (the present totals of the candidate's sitting mode, theirs
--     included) are higher, so ties share a place (1, 2, 2, 4); none under result_cohort_min() totals (Calls 7 and 8).
--   result_cohort_min(): 5, the smallest group anything is compared in (Call 8).
-- rank_cohort is the number of present candidates in the candidate's mode ("3rd of 42"), null with the rank. The
-- cohort figures (exam_results.cohort, Call 8) are null under 5 present candidates in the exam, else {present,
-- average, lower_quartile, upper_quartile, questions: [{question_id, average}]}: the average and the quartiles
-- (percentile_cont 0.25 and 0.75) of the present totals and the average mark per question over every present
-- candidate (No response, or no mark, counts 0), each to one decimal place half up; never the highest or lowest.
--
-- exam_results.version counts preparations and changes before publication: preparing, a status change and a change of
-- boundaries each add 1, so totals checked before it no longer publish (Task 4 compares it).
--
-- Added (admins; each refuses forbidden for anyone else):
--   results_prepare(p_exam): {ok, version, counts, cohort}. Refused invalid_input, not_found, marking_not_approved,
--     results_published, approval_stale (the approval with anything blocking it: marking_approval_blocks), and
--     missing_scripts {count}. Writes every candidate's row, ranks them, the cohort figures; state prepared. Audited
--     results_prepared.
--   results_get(p_exam): the results page (state, version, approval {approved_at, stale}, boundaries, max_total, counts,
--     cohort, 10% bands of the present candidates' percentages, grades {grade, all, centre, home} with U last, the
--     missing candidates, rows capped at 2,000 with more, and the publication fields).
--   result_status_set(p_booking, p_status, p_reason): absent, incomplete, disqualified or auto, with a reason (3 to 300
--     characters). Refused invalid_input (also for a booking that is not a candidate), reason_required, not_found,
--     results_published, missing_scripts {count: 1} (auto while the candidate would be missing). Rewrites the row, ranks
--     the exam again and its cohort figures. Audited result_status_set "<status>: <reason>". {ok, version, status}.
--   grade_boundaries_preview(p_exam, p_grades): {ok, grades: [{grade, all, centre, home}], below: {all, centre, home}}
--     over the prepared present candidates; nothing is saved. invalid_input for a bad set (1 to 15 grades here).
--   grade_boundaries_set(p_exam, p_grades, p_reason): replaces the boundaries ([] clears them) and grades the prepared
--     rows again. A reason is optional (3 to 300 characters when given). Refused invalid_input, not_found,
--     results_published. Audited grade_boundaries_set with the grades and the reason. {ok, version, boundaries}.
--   results_export(p_exam): {ok, rows, filename}: every row (not capped) with each question's mark in paper order.
--     Audited results_exported in the same call.
-- Internal: result_cohort_min, result_percentage, result_grade, result_rank, results_questions, exam_grades,
--   results_counts, results_missing, results_cohort, results_write, results_rank, grade_boundaries_valid.
-- Changed, each from its latest definition:
--   exam_max_total (20261126000001, Ruling R5): leaf maxima only, as exam_structure_max_total counts them.
--   marking_approval_withdraw (20261123000009): refused results_published while the exam's results are scheduled or
--     published (Call 11), read once the exam's marking row is held. Nothing else in it changed.
-- Admin answers carry candidates' names and index numbers (admins see them); nothing here is for families.
--
-- Lock order (Phase 4A): exam_marking -> exam_results -> booking advisory lock -> script rows in id order -> ... ->
-- results in booking id order. results_prepare holds the exam's marking row for share (an approval cannot be withdrawn
-- meanwhile), the exam's results row for update, the exam's scripts for share (none changes state while the results
-- are worked out; a script arriving later makes the approval stale), then the results rows. result_status_set also
-- takes the booking's advisory lock before its script. grade_boundaries_set takes the exam's results row, then the
-- results rows.
-- ---------------------------------------------------------------------------------------------

-- ---------------------------------------------------------------------------------------------
-- Internal: the paper's maximum, as 20261126000001, and (Ruling R5) leaf maxima only, as exam_structure_max_total
-- counts them: leaf maxima summed per top-level question, then within each group of optional questions only the best
-- `choose` top-level questions.
-- ---------------------------------------------------------------------------------------------
create or replace function public.exam_max_total(p_exam uuid)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  with recursive tree as (
    select q.id, q.id as top_id
    from public.exam_questions q where q.exam_id = p_exam and q.parent_id is null
    union all
    select c.id, t.top_id from public.exam_questions c join tree t on c.parent_id = t.id
  ),
  tops as (
    select t.top_id, sum(coalesce(q.max_mark, 0)) as total
    from tree t
    join public.exam_questions q on q.id = t.id
    where not exists (select 1 from public.exam_questions k where k.parent_id = t.id)
    group by t.top_id
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
-- Internal: the rules (see the header).
-- ---------------------------------------------------------------------------------------------
create function public.result_cohort_min()
returns int
language sql
immutable
set search_path = ''
as $$
  select 5
$$;

create function public.result_percentage(p_total numeric, p_max numeric)
returns numeric
language sql
immutable
set search_path = ''
as $$
  -- numeric round() takes a half away from zero: totals are never negative, so a half goes up.
  select case when p_total is not null and p_max > 0 then round(p_total * 100 / p_max, 1) end
$$;

-- p_grades: the boundaries, [{grade, min_mark}] (exam_grades, or a set being previewed).
create function public.result_grade(p_total numeric, p_grades jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_total is null or p_grades is null then null
    when jsonb_typeof(p_grades) <> 'array' then null
    when jsonb_array_length(p_grades) = 0 then null
    else coalesce((select g ->> 'grade' from jsonb_array_elements(p_grades) g
                   where (g ->> 'min_mark')::numeric <= p_total
                   order by (g ->> 'min_mark')::numeric desc limit 1), 'U')
  end
$$;

-- p_totals: the present totals of the candidate's sitting mode, the candidate's own included.
create function public.result_rank(p_total numeric, p_totals numeric[])
returns int
language sql
immutable
set search_path = ''
as $$
  select case when p_total is null or coalesce(cardinality(p_totals), 0) < public.result_cohort_min() then null
              else 1 + (select count(*)::int from unnest(p_totals) t where t > p_total) end
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the exam's questions in paper order: label as printed ("2(b)(i)"), path (positions from the top), leaf
-- (it is marked), maximum.
-- ---------------------------------------------------------------------------------------------
create function public.results_questions(p_exam uuid)
returns table (question_id uuid, label text, path int[], leaf boolean, max_mark numeric)
language sql
stable
security definer
set search_path = ''
as $$
  with recursive t as (
    select q.id, q.label::text as label, array[q.position] as path
    from public.exam_questions q where q.exam_id = p_exam and q.parent_id is null
    union all
    select c.id, t.label || '(' || c.label || ')', t.path || c.position
    from t join public.exam_questions c on c.parent_id = t.id
  )
  select t.id, t.label, t.path, not exists (select 1 from public.exam_questions k where k.parent_id = t.id), q.max_mark
  from t join public.exam_questions q on q.id = t.id
$$;

-- Internal: the exam's saved boundaries, top first: [{grade, min_mark}].
create function public.exam_grades(p_exam uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('grade', g.grade, 'min_mark', g.min_mark) order by g.position), '[]'::jsonb)
  from public.grade_boundaries g where g.exam_id = p_exam
$$;

-- Internal: the exam's rows by status.
create function public.results_counts(p_exam uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'present', count(*) filter (where r.status = 'present'),
    'absent', count(*) filter (where r.status = 'absent'),
    'withdrawn', count(*) filter (where r.status = 'withdrawn'),
    'incomplete', count(*) filter (where r.status = 'incomplete'),
    'disqualified', count(*) filter (where r.status = 'disqualified'))
  from public.results r where r.exam_id = p_exam
$$;

-- Internal: the missing candidates: centre bookings that are candidates (paid, part refunded or awaiting a cancellation
-- decision), marked present or late on the register, with no script and no status an admin set.
create function public.results_missing(p_exam uuid)
returns table (booking_id uuid, student_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select b.id, b.student_id
  from public.bookings b
  join public.attendance a on a.exam_id = b.exam_id and a.student_id = b.student_id and a.status in ('present', 'late')
  where b.exam_id = p_exam and b.sitting = 'centre' and b.status in ('paid', 'part_refunded', 'cancel_requested')
    and not exists (select 1 from public.scripts s where s.booking_id = b.id)
    and not exists (select 1 from public.results r where r.booking_id = b.id and r.status_set)
$$;

-- Internal: the cohort figures from the exam's present rows (see the header); null under result_cohort_min().
create function public.results_cohort(p_exam uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with p as materialized (
    select r.total, r.question_marks from public.results r
    where r.exam_id = p_exam and r.status = 'present' and r.total is not null
  ),
  n as (select count(*)::int as n from p),
  qs as (
    select (e ->> 'question_id')::uuid as question_id, sum(coalesce((e ->> 'mark')::numeric, 0)) as marks
    from p cross join lateral jsonb_array_elements(p.question_marks) e
    group by 1
  )
  select case when n.n < public.result_cohort_min() then null else jsonb_build_object(
    'present', n.n,
    'average', (select round(avg(p.total), 1) from p),
    -- percentile_cont works in double precision: back to numeric (15 significant digits) before rounding.
    'lower_quartile', (select round((percentile_cont(0.25) within group (order by p.total))::numeric, 1) from p),
    'upper_quartile', (select round((percentile_cont(0.75) within group (order by p.total))::numeric, 1) from p),
    'questions', (select coalesce(jsonb_agg(jsonb_build_object('question_id', qs.question_id, 'average', round(qs.marks / n.n, 1))
                                  order by o.path nulls last, qs.question_id), '[]'::jsonb)
                  from qs left join public.results_questions(p_exam) o on o.question_id = qs.question_id))
  end
  from n
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: writes the rows of the exam's candidates (all of them when p_bookings is null, else those bookings) from
-- the bookings, the scripts and the final marks, as the header says: an admin-set status stands; totals, marks per
-- question, the maximum, the percentage and the grade by the saved boundaries. Ranks are results_rank's. Preparing the
-- whole exam first removes the rows of bookings that are no longer candidates and were never published. A row whose
-- values did not change is not touched. Callers hold the exam's results row and the results rows, and have refused
-- the missing candidates.
-- ---------------------------------------------------------------------------------------------
create function public.results_write(p_exam uuid, p_bookings uuid[] default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_max numeric := public.exam_max_total(p_exam);
  v_grades jsonb := public.exam_grades(p_exam);
begin
  if p_bookings is null then
    delete from public.results r
    where r.exam_id = p_exam and r.version = 0
      and not exists (select 1 from public.bookings b
                      where b.id = r.booking_id and b.status in ('paid', 'part_refunded', 'cancel_requested'))
      and not exists (select 1 from public.scripts s where s.booking_id = r.booking_id);
  end if;

  with q as materialized (
    select x.question_id, x.path from public.results_questions(p_exam) x
  ),
  cand as materialized (
    select b.id as booking_id, b.student_id, b.sitting, s.id as script_id, s.state as script_state,
      coalesce(r.status_set, false) as status_set, r.status as kept
    from public.bookings b
    left join public.scripts s on s.booking_id = b.id
    left join public.results r on r.booking_id = b.id
    where b.exam_id = p_exam and (p_bookings is null or b.id = any (p_bookings))
      and (b.status in ('paid', 'part_refunded', 'cancel_requested') or s.id is not null or r.id is not null)
  ),
  d as materialized (
    select c.booking_id, c.student_id, c.sitting, c.script_id,
      (case when c.status_set then c.kept::text
            when c.script_id is null then 'absent'
            when c.script_state = 'withdrawn' then 'withdrawn'
            when c.script_state = 'void' then 'incomplete'
            else 'present' end)::public.result_status as status
    from cand c
  ),
  v as materialized (
    select d.booking_id, d.student_id, d.sitting, d.script_id, d.status,
      case when d.status = 'present' then public.script_final_total(d.script_id) end as total,
      case when d.status = 'present' then (
        select coalesce(jsonb_agg(jsonb_build_object('question_id', f.question_id, 'mark', f.mark,
                 'not_attempted', f.not_attempted, 'changed_on_review', f.source = 'lead') order by q.path nulls last, f.question_id),
               '[]'::jsonb)
        from public.script_final_marks(d.script_id) f left join q on q.question_id = f.question_id)
      else '[]'::jsonb end as question_marks
    from d
  )
  insert into public.results as r (exam_id, booking_id, student_id, script_id, sitting, status, total, max_total, percentage,
    grade, question_marks)
  select p_exam, v.booking_id, v.student_id, v.script_id, v.sitting, v.status, v.total, v_max,
    public.result_percentage(v.total, v_max), public.result_grade(v.total, v_grades), v.question_marks
  from v
  on conflict (booking_id) do update set
    student_id = excluded.student_id, script_id = excluded.script_id, sitting = excluded.sitting, status = excluded.status,
    total = excluded.total, max_total = excluded.max_total, percentage = excluded.percentage, grade = excluded.grade,
    question_marks = excluded.question_marks
  where (r.student_id, r.script_id, r.sitting, r.status, r.total, r.max_total, r.percentage, r.grade, r.question_marks)
    is distinct from (excluded.student_id, excluded.script_id, excluded.sitting, excluded.status, excluded.total,
                      excluded.max_total, excluded.percentage, excluded.grade, excluded.question_marks);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: ranks every row of the exam (result_rank within its sitting mode among the present totals; rank_cohort the
-- number of them); every other row has neither. result_rank is asked once per mode and distinct total (equal totals
-- share a place), not once per candidate. Only rows that change are written. Callers hold the results rows.
-- ---------------------------------------------------------------------------------------------
create function public.results_rank(p_exam uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  with p as materialized (
    select r.sitting, r.total from public.results r
    where r.exam_id = p_exam and r.status = 'present' and r.total is not null
  ),
  m as materialized (
    select p.sitting, array_agg(p.total) as totals from p group by p.sitting
  ),
  k as materialized (
    select t.sitting, t.total, public.result_rank(t.total, m.totals) as rank, cardinality(m.totals) as n
    from (select distinct p.sitting, p.total from p) t join m on m.sitting = t.sitting
  ),
  x as materialized (
    select r.id, k.rank, case when k.rank is not null then k.n end as rank_cohort
    from public.results r
    left join k on k.sitting = r.sitting and k.total = r.total and r.status = 'present'
    where r.exam_id = p_exam
  )
  update public.results r set rank = x.rank, rank_cohort = x.rank_cohort
  from x
  where r.id = x.id and (r.rank, r.rank_cohort) is distinct from (x.rank, x.rank_cohort)
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: whether p_grades is a set of boundaries (see the header) for a paper of maximum p_max; 0 to 15 grades
-- (an empty set clears). Reads only its arguments.
-- ---------------------------------------------------------------------------------------------
create function public.grade_boundaries_valid(p_grades jsonb, p_max numeric)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_grades is null or jsonb_typeof(p_grades) is distinct from 'array' then
    return false;
  end if;
  if jsonb_array_length(p_grades) > 15 then
    return false;
  end if;
  -- Shapes and types first, so that every cast below is safe.
  if exists (select 1 from jsonb_array_elements(p_grades) g
             where jsonb_typeof(g) <> 'object'
                or jsonb_typeof(g -> 'grade') is distinct from 'string'
                or char_length(btrim(g ->> 'grade')) not between 1 and 10
                or jsonb_typeof(g -> 'min_mark') is distinct from 'number') then
    return false;
  end if;
  if exists (select 1 from jsonb_array_elements(p_grades) g cross join lateral (select (g ->> 'min_mark')::numeric as m) x
             where x.m < 0 or x.m > coalesce(p_max, 0) or x.m * 10 <> trunc(x.m * 10)) then
    return false;
  end if;
  -- Top first: each lowest mark below the one above; and no label twice.
  if exists (select 1 from (
               select (g ->> 'min_mark')::numeric as m, lag((g ->> 'min_mark')::numeric) over (order by o) as above
               from jsonb_array_elements(p_grades) with ordinality t(g, o)) x
             where x.m >= x.above) then
    return false;
  end if;
  if (select count(distinct btrim(g ->> 'grade')) from jsonb_array_elements(p_grades) g) <> jsonb_array_length(p_grades) then
    return false;
  end if;
  return true;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- results_prepare: see the header.
-- ---------------------------------------------------------------------------------------------
create function public.results_prepare(p_exam uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_approved timestamptz;
  v_state public.results_state;
  v_missing int;
  v_version int;
  v_counts jsonb;
  v_cohort jsonb;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if not exists (select 1 from public.exams e where e.id = p_exam) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  -- The exam's marking row for share: the approval cannot be withdrawn until this ends.
  select m.approved_at into v_approved from public.exam_marking m where m.exam_id = p_exam for share;
  if v_approved is null then
    return jsonb_build_object('ok', false, 'code', 'marking_not_approved');
  end if;
  insert into public.exam_results (exam_id) values (p_exam) on conflict (exam_id) do nothing;
  select r.state into v_state from public.exam_results r where r.exam_id = p_exam for update;
  if v_state in ('scheduled', 'published') then
    return jsonb_build_object('ok', false, 'code', 'results_published');
  end if;
  -- The scripts for share before asking what blocks the approval: none changes state until this ends.
  perform 1 from public.scripts s where s.exam_id = p_exam order by s.id for share;
  if jsonb_array_length(public.marking_approval_blocks(p_exam)) > 0 then
    return jsonb_build_object('ok', false, 'code', 'approval_stale');
  end if;
  select count(*)::int into v_missing from public.results_missing(p_exam);
  if v_missing > 0 then
    return jsonb_build_object('ok', false, 'code', 'missing_scripts', 'count', v_missing);
  end if;

  perform 1 from public.results r where r.exam_id = p_exam order by r.booking_id for update;
  perform public.results_write(p_exam, null);
  perform public.results_rank(p_exam);
  v_cohort := public.results_cohort(p_exam);
  v_counts := public.results_counts(p_exam);
  update public.exam_results r
  set state = 'prepared', version = r.version + 1, prepared_at = now(), prepared_by = v_actor, cohort = v_cohort
  where r.exam_id = p_exam
  returning r.version into v_version;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'results_prepared', 'exam', p_exam,
    format('version %s: %s present, %s absent, %s withdrawn, %s incomplete, %s disqualified', v_version,
      v_counts ->> 'present', v_counts ->> 'absent', v_counts ->> 'withdrawn', v_counts ->> 'incomplete',
      v_counts ->> 'disqualified'));
  return jsonb_build_object('ok', true, 'version', v_version, 'counts', v_counts, 'cohort', v_cohort);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- result_status_set: see the header.
-- ---------------------------------------------------------------------------------------------
create function public.result_status_set(p_booking uuid, p_status text, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_b public.bookings%rowtype;
  v_state public.results_state;
  v_script uuid;
  v_row uuid;
  v_version int;
  v_status public.result_status;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_booking is null or p_status is null or p_status not in ('absent', 'incomplete', 'disqualified', 'auto') then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  select * into v_b from public.bookings b where b.id = p_booking;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  perform 1 from public.exam_marking m where m.exam_id = v_b.exam_id for share;
  insert into public.exam_results (exam_id) values (v_b.exam_id) on conflict (exam_id) do nothing;
  select r.state into v_state from public.exam_results r where r.exam_id = v_b.exam_id for update;
  if v_state in ('scheduled', 'published') then
    return jsonb_build_object('ok', false, 'code', 'results_published');
  end if;
  perform public.script_bookings_lock(array[p_booking]);
  select s.id into v_script from public.scripts s where s.booking_id = p_booking for share;
  perform 1 from public.results r where r.exam_id = v_b.exam_id order by r.booking_id for update;
  select r.id into v_row from public.results r where r.booking_id = p_booking;

  -- A candidate (as results_write counts them).
  if v_b.status not in ('paid', 'part_refunded', 'cancel_requested') and v_script is null and v_row is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  -- auto would make a missing candidate (results_missing) missing again: preparation would stop for them.
  if p_status = 'auto' and v_script is null and v_b.sitting = 'centre'
     and v_b.status in ('paid', 'part_refunded', 'cancel_requested')
     and exists (select 1 from public.attendance a
                 where a.exam_id = v_b.exam_id and a.student_id = v_b.student_id and a.status in ('present', 'late')) then
    return jsonb_build_object('ok', false, 'code', 'missing_scripts', 'count', 1);
  end if;

  insert into public.results as r (exam_id, booking_id, student_id, script_id, sitting, status, status_set, status_reason, max_total)
  values (v_b.exam_id, p_booking, v_b.student_id, v_script, v_b.sitting,
    (case when p_status = 'auto' then 'absent' else p_status end)::public.result_status,
    p_status <> 'auto', case when p_status <> 'auto' then v_reason end, public.exam_max_total(v_b.exam_id))
  on conflict (booking_id) do update set
    status_set = excluded.status_set, status_reason = excluded.status_reason,
    status = case when excluded.status_set then excluded.status else r.status end;
  perform public.results_write(v_b.exam_id, array[p_booking]);
  perform public.results_rank(v_b.exam_id);
  update public.exam_results r set version = r.version + 1, cohort = public.results_cohort(v_b.exam_id)
  where r.exam_id = v_b.exam_id
  returning r.version into v_version;
  select r.status into v_status from public.results r where r.booking_id = p_booking;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'result_status_set', 'booking', p_booking, p_status || ': ' || v_reason);
  return jsonb_build_object('ok', true, 'version', v_version, 'status', v_status);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- grade_boundaries_preview: see the header.
-- ---------------------------------------------------------------------------------------------
create function public.grade_boundaries_preview(p_exam uuid, p_grades jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_grades jsonb;
  v_lowest numeric;
  v_counts jsonb;
  v_below jsonb;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if not exists (select 1 from public.exams e where e.id = p_exam) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if not public.grade_boundaries_valid(p_grades, public.exam_max_total(p_exam)) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  -- A preview needs at least one grade.
  if jsonb_array_length(p_grades) = 0 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select jsonb_agg(jsonb_build_object('grade', btrim(g ->> 'grade'), 'min_mark', (g ->> 'min_mark')::numeric) order by o)
  into v_grades from jsonb_array_elements(p_grades) with ordinality t(g, o);
  select min((g ->> 'min_mark')::numeric) into v_lowest from jsonb_array_elements(v_grades) g;

  with p as materialized (
    select r.sitting, r.total, public.result_grade(r.total, v_grades) as grade
    from public.results r where r.exam_id = p_exam and r.status = 'present' and r.total is not null
  )
  select
    (select jsonb_agg(jsonb_build_object('grade', g ->> 'grade',
              'all', (select count(*) from p where p.grade = g ->> 'grade' and p.total >= v_lowest),
              'centre', (select count(*) from p where p.grade = g ->> 'grade' and p.total >= v_lowest and p.sitting = 'centre'),
              'home', (select count(*) from p where p.grade = g ->> 'grade' and p.total >= v_lowest and p.sitting = 'home'))
            order by o)
     from jsonb_array_elements(v_grades) with ordinality t(g, o)),
    jsonb_build_object('all', (select count(*) from p where p.total < v_lowest),
      'centre', (select count(*) from p where p.total < v_lowest and p.sitting = 'centre'),
      'home', (select count(*) from p where p.total < v_lowest and p.sitting = 'home'))
  into v_counts, v_below;
  return jsonb_build_object('ok', true, 'grades', v_counts, 'below', v_below);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- grade_boundaries_set: see the header.
-- ---------------------------------------------------------------------------------------------
create function public.grade_boundaries_set(p_exam uuid, p_grades jsonb, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_given text := nullif(btrim(coalesce(p_reason, '')), '');
  v_reason text := public.script_resolution_reason(p_reason);
  v_state public.results_state;
  v_grades jsonb;
  v_version int;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null or (v_given is not null and v_reason is null) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if not exists (select 1 from public.exams e where e.id = p_exam) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if not public.grade_boundaries_valid(p_grades, public.exam_max_total(p_exam)) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('grade', btrim(g ->> 'grade'), 'min_mark', (g ->> 'min_mark')::numeric) order by o),
                  '[]'::jsonb)
  into v_grades from jsonb_array_elements(p_grades) with ordinality t(g, o);

  insert into public.exam_results (exam_id) values (p_exam) on conflict (exam_id) do nothing;
  select r.state into v_state from public.exam_results r where r.exam_id = p_exam for update;
  if v_state in ('scheduled', 'published') then
    return jsonb_build_object('ok', false, 'code', 'results_published');
  end if;
  perform 1 from public.results r where r.exam_id = p_exam order by r.booking_id for update;

  delete from public.grade_boundaries g where g.exam_id = p_exam;
  insert into public.grade_boundaries (exam_id, position, grade, min_mark, set_by, set_at)
  select p_exam, o, g ->> 'grade', (g ->> 'min_mark')::numeric, v_actor, now()
  from jsonb_array_elements(v_grades) with ordinality t(g, o);
  update public.results r set grade = public.result_grade(r.total, v_grades)
  where r.exam_id = p_exam and r.grade is distinct from public.result_grade(r.total, v_grades);
  update public.exam_results r set version = r.version + 1 where r.exam_id = p_exam returning r.version into v_version;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'grade_boundaries_set', 'exam', p_exam,
    left(concat_ws('; ', coalesce('Grades: ' || (select string_agg((g ->> 'grade') || ' from ' || (g ->> 'min_mark'), ', ' order by o)
                                                 from jsonb_array_elements(v_grades) with ordinality t(g, o)), 'Grades cleared'),
                   v_reason), 600));
  return jsonb_build_object('ok', true, 'version', v_version, 'boundaries', public.exam_grades(p_exam));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- results_get: see the header. rows: [{booking_id, name, index_number, sitting, status, status_set, status_reason,
-- total, percentage, grade, rank, rank_cohort, version, remarked}] by index number, at most 2,000 (more says there
-- are others).
-- ---------------------------------------------------------------------------------------------
create function public.results_get(p_exam uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_er public.exam_results%rowtype;
  v_approved timestamptz;
  v_grades jsonb;
  v_lowest numeric;
  v_n int;
  v_rows jsonb;
  v_bands jsonb;
  v_grade_counts jsonb;
  v_missing jsonb;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if not exists (select 1 from public.exams e where e.id = p_exam) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select * into v_er from public.exam_results r where r.exam_id = p_exam;
  select m.approved_at into v_approved from public.exam_marking m where m.exam_id = p_exam;
  v_grades := public.exam_grades(p_exam);
  select min((g ->> 'min_mark')::numeric) into v_lowest from jsonb_array_elements(v_grades) g;

  select count(*)::int into v_n from public.results r where r.exam_id = p_exam;
  select coalesce(jsonb_agg(jsonb_build_object('booking_id', x.booking_id, 'name', x.name, 'index_number', x.index_number,
           'sitting', x.sitting, 'status', x.status, 'status_set', x.status_set, 'status_reason', x.status_reason,
           'total', x.total, 'percentage', x.percentage, 'grade', x.grade, 'rank', x.rank, 'rank_cohort', x.rank_cohort,
           'version', x.version, 'remarked', x.remarked) order by x.n), '[]'::jsonb)
  into v_rows
  from (
    select r.*, nullif(btrim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), '') as name, d.index_number,
      row_number() over (order by d.index_number nulls last, r.booking_id) as n
    from public.results r
    join public.profiles p on p.id = r.student_id
    left join public.student_details d on d.profile_id = r.student_id
    where r.exam_id = p_exam
    order by d.index_number nulls last, r.booking_id
    limit 2000
  ) x;

  select jsonb_agg(jsonb_build_object('from', b.b * 10, 'to', b.b * 10 + 10, 'count', coalesce(c.n, 0)) order by b.b)
  into v_bands
  from generate_series(0, 9) b(b)
  left join (
    select least(floor(r.percentage / 10), 9)::int as b, count(*)::int as n
    from public.results r where r.exam_id = p_exam and r.status = 'present' and r.percentage is not null
    group by 1
  ) c on c.b = b.b;

  with p as materialized (
    select r.sitting, r.total, r.grade from public.results r
    where r.exam_id = p_exam and r.status = 'present' and r.total is not null
  )
  select case when jsonb_array_length(v_grades) = 0 then '[]'::jsonb else
    (select jsonb_agg(jsonb_build_object('grade', x.grade, 'all', x.n_all, 'centre', x.n_centre, 'home', x.n_home) order by x.o)
     from (
       select o, g ->> 'grade' as grade,
         (select count(*) from p where p.grade = g ->> 'grade' and p.total >= v_lowest) as n_all,
         (select count(*) from p where p.grade = g ->> 'grade' and p.total >= v_lowest and p.sitting = 'centre') as n_centre,
         (select count(*) from p where p.grade = g ->> 'grade' and p.total >= v_lowest and p.sitting = 'home') as n_home
       from jsonb_array_elements(v_grades) with ordinality t(g, o)
       union all
       select 100, 'U', (select count(*) from p where p.total < v_lowest),
         (select count(*) from p where p.total < v_lowest and p.sitting = 'centre'),
         (select count(*) from p where p.total < v_lowest and p.sitting = 'home')
     ) x)
  end
  into v_grade_counts;

  select coalesce(jsonb_agg(jsonb_build_object('booking_id', x.booking_id, 'name', x.name, 'index_number', x.index_number)
           order by x.index_number nulls last, x.booking_id), '[]'::jsonb)
  into v_missing
  from (
    select m.booking_id, nullif(btrim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), '') as name, d.index_number
    from public.results_missing(p_exam) m
    join public.profiles p on p.id = m.student_id
    left join public.student_details d on d.profile_id = m.student_id
    order by d.index_number nulls last, m.booking_id
    limit 2000
  ) x;

  return jsonb_build_object(
    'ok', true,
    'state', coalesce(v_er.state, 'none'),
    'version', coalesce(v_er.version, 0),
    'approval', jsonb_build_object('approved_at', v_approved,
      'stale', v_approved is not null and jsonb_array_length(public.marking_approval_blocks(p_exam)) > 0),
    'boundaries', v_grades,
    'max_total', public.exam_max_total(p_exam),
    'counts', public.results_counts(p_exam),
    'cohort', v_er.cohort,
    'bands', v_bands,
    'grades', v_grade_counts,
    'missing', v_missing,
    'rows', v_rows,
    'more', v_n > 2000,
    'publish_at', v_er.publish_at,
    'first_published_at', v_er.first_published_at,
    'published_at', v_er.published_at,
    'publish_failed_at', v_er.publish_failed_at,
    'publish_failed_reason', v_er.publish_failed_reason,
    'withdrawn_at', v_er.withdrawn_at,
    'withdraw_reason', v_er.withdraw_reason);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- results_export: see the header. rows: as results_get's (by index number, every row) with max_total and marks:
-- [{label, mark, not_attempted}] for each question marked (leaf), in paper order (mark null for No response or none).
-- filename: results-<exam code>.csv.
-- ---------------------------------------------------------------------------------------------
create function public.results_export(p_exam uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_e public.exams%rowtype;
  v_version int;
  v_rows jsonb;
  v_n int;
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
  select r.version into v_version from public.exam_results r where r.exam_id = p_exam;

  with q as materialized (
    select x.question_id, x.label, x.path from public.results_questions(p_exam) x where x.leaf
  )
  select coalesce(jsonb_agg(jsonb_build_object('booking_id', x.booking_id, 'name', x.name, 'index_number', x.index_number,
           'sitting', x.sitting, 'status', x.status, 'status_set', x.status_set, 'status_reason', x.status_reason,
           'total', x.total, 'max_total', x.max_total, 'percentage', x.percentage, 'grade', x.grade, 'rank', x.rank,
           'rank_cohort', x.rank_cohort, 'version', x.version, 'remarked', x.remarked,
           'marks', (select coalesce(jsonb_agg(jsonb_build_object('label', q.label, 'mark', e.v -> 'mark',
                                       'not_attempted', coalesce((e.v ->> 'not_attempted')::boolean, false)) order by q.path), '[]'::jsonb)
                     from q left join lateral (
                       select v from jsonb_array_elements(x.question_marks) v where (v ->> 'question_id')::uuid = q.question_id limit 1
                     ) e on true))
           order by x.index_number nulls last, x.booking_id), '[]'::jsonb),
    count(*)::int
  into v_rows, v_n
  from (
    select r.*, nullif(btrim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), '') as name, d.index_number
    from public.results r
    join public.profiles p on p.id = r.student_id
    left join public.student_details d on d.profile_id = r.student_id
    where r.exam_id = p_exam
  ) x;

  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'results_exported', 'exam', p_exam,
    format('version %s: %s %s', coalesce(v_version, 0), v_n, case when v_n = 1 then 'row' else 'rows' end));
  return jsonb_build_object('ok', true, 'rows', v_rows,
    'filename', 'results-' || coalesce(nullif(regexp_replace(coalesce(v_e.exam_code, ''), '[^A-Za-z0-9-]+', '-', 'g'), ''), 'exam') || '.csv');
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_approval_withdraw: as 20261123000009, and (Phase 4A, Call 11) refused results_published while the exam's
-- results are scheduled or published, read once the exam's marking row is held (then its results row, for share).
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_approval_withdraw(p_exam uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_m public.exam_marking%rowtype;
  v_results public.results_state;
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
  -- Phase 4A: the approval stays while the results are scheduled or published (withdraw the results first).
  select r.state into v_results from public.exam_results r where r.exam_id = p_exam for share;
  if v_results in ('scheduled', 'published') then
    return jsonb_build_object('ok', false, 'code', 'results_published');
  end if;
  update public.exam_marking m set approved_at = null, approved_by = null, updated_at = now() where m.exam_id = p_exam;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marking_approval_withdrawn', 'exam', p_exam, v_reason);
  return jsonb_build_object('ok', true, 'already', false);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Privileges. The internal functions are for definer callers only; the results functions for signed-in users (they
-- check for an admin). Functions made again by create or replace keep theirs (restated).
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.exam_max_total(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.result_cohort_min() from public, anon, authenticated, service_role;
revoke execute on function public.result_percentage(numeric, numeric) from public, anon, authenticated, service_role;
revoke execute on function public.result_grade(numeric, jsonb) from public, anon, authenticated, service_role;
revoke execute on function public.result_rank(numeric, numeric[]) from public, anon, authenticated, service_role;
revoke execute on function public.results_questions(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.exam_grades(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.results_counts(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.results_missing(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.results_cohort(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.results_write(uuid, uuid[]) from public, anon, authenticated, service_role;
revoke execute on function public.results_rank(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.grade_boundaries_valid(jsonb, numeric) from public, anon, authenticated, service_role;
revoke execute on function public.results_prepare(uuid) from public, anon;
revoke execute on function public.results_get(uuid) from public, anon;
revoke execute on function public.result_status_set(uuid, text, text) from public, anon;
revoke execute on function public.grade_boundaries_preview(uuid, jsonb) from public, anon;
revoke execute on function public.grade_boundaries_set(uuid, jsonb, text) from public, anon;
revoke execute on function public.results_export(uuid) from public, anon;
revoke execute on function public.marking_approval_withdraw(uuid, text) from public, anon;
grant execute on function public.results_prepare(uuid) to authenticated;
grant execute on function public.results_get(uuid) to authenticated;
grant execute on function public.result_status_set(uuid, text, text) to authenticated;
grant execute on function public.grade_boundaries_preview(uuid, jsonb) to authenticated;
grant execute on function public.grade_boundaries_set(uuid, jsonb, text) to authenticated;
grant execute on function public.results_export(uuid) to authenticated;
grant execute on function public.marking_approval_withdraw(uuid, text) to authenticated;
