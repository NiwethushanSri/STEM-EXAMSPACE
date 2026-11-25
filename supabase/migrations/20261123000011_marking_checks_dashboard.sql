-- Phase 3B Task 13: the checking figures of the admin dashboard and of the progress card, and a light lead flag.
--
-- Changed, each from its latest definition:
--   marking_dashboard (20261122000012), admins only as before. Added:
--     per exam (whose marking is open, or closed in the last 14 days, as before), of its scripts not withdrawn or void:
--       checked (pieces checked), with_lead (pieces with the lead marker: check_state to_lead), waiting_second (pieces
--       waiting for a second marker) and approved (its marking is approved);
--     totals: with_lead and waiting_second (the listed exams' rows added up); stuck_second (the listed exams' pieces
--       waiting for a second marker whom nobody can be: marking_second_stuck, as the lead's review list counts them);
--       markers_paused (the markers paused on a listed exam whose marking is not approved, each marker once);
--       ready_to_approve (exams whose marking has opened and is not approved, with nothing blocking it) and
--       approved_stale (exams approved with something blocking: a script arrived or changed after the approval), both
--       from Task 10's marking_approval_blocks, so they say what the approval page's can_approve and stale say. These two
--       count every exam whose marking has opened, listed or not: approving closes marking, so an approved exam leaves
--       the list after 14 days, and a stale approval must not go unseen (Phase 4 refuses to prepare results while it is).
--     Changed (3A's deferred minor): on_hold, on each row and so in the total, counts the scripts with a piece on hold,
--       and alerts_open counts the scripts with an open marking alert, so a script marked by question, or with two
--       alerts, counts once ("{n} scripts are on hold in marking."). left and marked still count pieces.
--   marking_progress (20261123000005), admins and a lead for their own subjects as before. Added: scripts.checked (the
--     exam's scripts checked), and checks: {waiting_second, with_lead (pieces, of scripts not withdrawn or void),
--     stuck_second (marking_second_stuck), paused_markers (markers paused on the exam), approved_at}. Changed (3A's
--     deferred minor): each marker's taken, submitted and last_saved_at leave out the pieces of withdrawn and void
--     scripts, as the exam's own figures do; a marker whose only work is on such scripts is not listed.
-- Added:
--   marking_is_lead() (authenticated): whether the caller leads a subject (an active approved marker with the lead
--     flag, as marking_my_work's lead_subjects says), for the teacher's and corrector's menus (Task 8, M4), which asked
--     the whole of marking_my_work for it. Says nothing about which subject.
-- Read only. Nothing here names a candidate.

-- ---------------------------------------------------------------------------------------------
-- marking_dashboard: the marking figures of the admin home page (see the header).
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
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;

  with ex as (
    select e.id, e.title, e.paper, e.starts_at, m.deadline, m.approved_at, public.marking_exam_overdue(e.id, v_now) as overdue,
      c.left_n, c.marked, c.on_hold, c.checked, c.with_lead, c.waiting_second
    from public.exam_marking m
    join public.exams e on e.id = m.exam_id
    cross join lateral (
      select count(*) filter (where u.state <> 'submitted')::int as left_n,
             count(*) filter (where u.state = 'submitted')::int as marked,
             count(distinct u.script_id) filter (where u.on_hold)::int as on_hold,
             count(*) filter (where u.check_state = 'checked')::int as checked,
             count(*) filter (where u.check_state = 'to_lead')::int as with_lead,
             count(*) filter (where u.check_state = 'waiting_second')::int as waiting_second
      from public.marking_units u join public.scripts s on s.id = u.script_id
      where u.exam_id = e.id and s.state not in ('withdrawn', 'void')
    ) c
    where m.opened_at is not null and (m.closed_at is null or m.closed_at > v_now - interval '14 days')
  )
  select coalesce(jsonb_agg(jsonb_build_object('exam_id', x.id, 'title', x.title, 'paper', x.paper, 'deadline', x.deadline,
           'overdue', x.overdue, 'left', x.left_n, 'marked', x.marked, 'on_hold', x.on_hold, 'checked', x.checked,
           'with_lead', x.with_lead, 'waiting_second', x.waiting_second, 'approved', x.approved_at is not null)
           order by x.starts_at, x.id), '[]'::jsonb),
         coalesce(array_agg(x.id), '{}'),
         coalesce(sum(x.left_n), 0)::int, coalesce(sum(x.on_hold), 0)::int, (count(*) filter (where x.overdue))::int,
         coalesce(sum(x.with_lead), 0)::int, coalesce(sum(x.waiting_second), 0)::int
  into v_exams, v_listed, v_left, v_on_hold, v_overdue, v_with_lead, v_waiting
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
    'stuck_second', (select count(*)::int from unnest(v_listed) l(exam_id) cross join lateral public.marking_second_stuck(l.exam_id) t),
    'markers_paused', (select count(distinct x.marker_id)::int
                       from public.exam_markers x join public.exam_marking m on m.exam_id = x.exam_id
                       where x.exam_id = any (v_listed) and x.paused_at is not null and m.approved_at is null),
    'ready_to_approve', (select count(*)::int from public.exam_marking m
                         where m.opened_at is not null and m.approved_at is null
                           and jsonb_array_length(public.marking_approval_blocks(m.exam_id)) = 0),
    'approved_stale', (select count(*)::int from public.exam_marking m
                       where m.approved_at is not null
                         and jsonb_array_length(public.marking_approval_blocks(m.exam_id)) > 0)));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_progress: as 20261123000005, with the checks (see the header). What is left, per exam and per marker. Admins:
-- every exam with marking settings (p_exam: that one); a lead marker: the exams of the subjects they lead. Per exam:
-- {exam_id, title, paper, subject, mode, deadline, overdue (marking_exam_overdue), opened_at, closed_at, scripts:
-- {waiting (verified, not yet ready), ready_to_mark, marking, marked (marked or checked), checked}, units: {open, taken,
-- submitted (not on hold), on_hold} of scripts not withdrawn or void, checks: {waiting_second, with_lead, stuck_second,
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
      'checks', (select jsonb_build_object(
                   'waiting_second', count(*) filter (where u.check_state = 'waiting_second'),
                   'with_lead', count(*) filter (where u.check_state = 'to_lead'),
                   'stuck_second', (select count(*)::int from public.marking_second_stuck(e.id)),
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
-- marking_is_lead: the caller leads a subject (see the header).
-- ---------------------------------------------------------------------------------------------
create function public.marking_is_lead()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.marker_approvals a
                 where a.marker_id = auth.uid() and a.lead and public.is_lead_for(auth.uid(), a.subject_id))
$$;

-- ---------------------------------------------------------------------------------------------
-- Access: marking_dashboard and marking_progress keep theirs (each checks who calls); marking_is_lead is for signed-in
-- users and says only about the caller.
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.marking_dashboard(timestamptz) from public, anon;
grant execute on function public.marking_dashboard(timestamptz) to authenticated;
revoke execute on function public.marking_progress(uuid, timestamptz) from public, anon;
grant execute on function public.marking_progress(uuid, timestamptz) to authenticated;
revoke execute on function public.marking_is_lead() from public, anon;
grant execute on function public.marking_is_lead() to authenticated;
