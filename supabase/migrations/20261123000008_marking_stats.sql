-- Phase 3B Task 9: marker statistics per exam.
--
-- marking_stats(p_exam): for each marker, how their marking of the exam looks beside the other markers'. The figures
-- are a prompt to look, not a finding: nothing here changes a mark or a marker's standing. Every figure is per piece (a
-- whole script, or one question group of it): no script total is ever formed, and nothing names or numbers a candidate
-- (no index number, script number or name, and no id of a script, piece or marking). Markers' names are shown, as in the
-- lead's other pages. Withdrawn and void scripts count in no figure.
--
-- For admins and the subject's lead marker; a plain marker or a corrector is refused (forbidden). A lead with a
-- declared conflict for a candidate sees the same answer: every figure is an aggregate over a marker's pieces, never one
-- candidate's.
--
-- Definitions (the brief's):
--   pieces: the marker's submitted live markings (not set aside), on scripts that are not withdrawn or void.
--   mean_percent: the mean of total / the piece's maximum (marking_unit_max_total) x 100 over their pieces.
--   cohort_mean_percent: the same over every marker's pieces of each question group this marker marked, weighted by
--     this marker's pieces per group, so a marker of a hard group is compared with that group. difference is the two
--     subtracted (each rounded to one place first, so the figures on screen add up). Added to the brief's shape:
--     cohort_has_others, whether another marker's piece is in that cohort (false for a marker who is the only one of
--     every group they marked, whose difference is 0 by construction: the screen then says there is no one to compare
--     with).
--   second: the pieces where the marker was the first or the second marker and both markings are submitted: how many,
--     how many within tolerance (marking_compare: Task 4's rule, greatest(1, percent x maximum), per question and on the
--     total), and the mean absolute gap between the two totals. (Replaced in 20261123000009, Ruling R23: the pairs the
--     check compared, and those within, as it recorded them, through marking_second_pairs, as the approval page counts
--     them; no longer compared again here.)
--   seeds, practice: their submitted seeded and practice attempts, and how many are within tolerance of the lead's
--     frozen marks. A seed counts as the submit judged it (Ruling R20): the miss it recorded (feedback_at, set by
--     marking_after_submit only for a seed outside tolerance) is what counted towards a pause, and what the Markers tab
--     (marking_exam_markers) and the practice and seeded scripts tab (marking_standards_list) count, so a seed is
--     within when its feedback_at is null. Practice is compared now (marking_standard_compare), as those tabs do: every
--     practice submit sets feedback_at.
--   median_seconds: the median active_seconds of their submitted live and second markings; the exam's is the same over
--     every marker's.
--   sent_back: their live markings ever sent back. A send-back closes a review only when one is open, so this is not
--     counted from reviews: marking_send_back (20261123000007) writes the lead's note on the marking (sent_back_note) to
--     the same marker and to another alike, and nothing clears it, also when the marking is submitted again.
--   notes, only for a marker with 10 pieces or more, in this order: fast (their median under one third of the exam's),
--     full_marks (30% or more of their pieces at the maximum), mean_apart (the difference, either way, above the exam's
--     tolerance percentage).
-- The exam's tolerance is its check setting (Task 2; 10 when never saved); second markings and practice are compared
-- under it now.
--
-- Added: marking_stats(p_exam). No earlier function is changed. It only reads, and takes no lock.

-- ---------------------------------------------------------------------------------------------
-- marking_stats: the exam's marker statistics (definitions above). Refused: invalid_input (no exam); not_found (an
-- unknown exam, to an admin; forbidden to anyone else); forbidden (neither an admin nor the subject's active lead
-- marker). A marker is listed when they have a piece, a submitted second marking, a submitted attempt or a live marking
-- sent back, in name order. Figures with nothing to count are null (counts are 0). Returns {ok, tolerance_percent,
-- exam:{pieces, mean_percent, median_seconds}, markers:[{marker_id, name, pieces, mean_percent, cohort_mean_percent,
-- cohort_has_others, difference, second:{compared, within, mean_gap}, seeds:{done, within}, practice:{done, within},
-- median_seconds, sent_back, notes:[text]}]}; percentages and the gap to one place, seconds whole.
-- ---------------------------------------------------------------------------------------------
create function public.marking_stats(p_exam uuid)
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
  -- First and second markings of a piece, both submitted, compared once each.
  pairs as materialized (
    select f.marker_id as first_id, k.marker_id as second_id, abs(f.total - k.total) as gap,
      coalesce((public.marking_compare(f.id, k.id) ->> 'within')::boolean, false) as within
    from mk f join mk k on k.unit_id = f.unit_id and k.kind = 'second' and k.status = 'submitted'
    where f.kind = 'live' and f.status = 'submitted'
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
-- Privileges.
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.marking_stats(uuid) from public, anon;
grant execute on function public.marking_stats(uuid) to authenticated;
