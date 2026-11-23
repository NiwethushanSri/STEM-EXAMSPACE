-- Phase 3A Task 13: the marking figures of the admin dashboard.
--
-- marking_dashboard (admins): per exam whose marking is open, or closed in the last 14 days: {exam_id, title, paper,
-- deadline, overdue (marking_exam_overdue: the deadline passed, marking not closed and a piece not submitted), left (its
-- pieces not submitted), marked (its pieces submitted), on_hold (its pieces on hold)}, counting the pieces of scripts that
-- are not withdrawn or void. A piece on hold is also counted as left or marked. Totals: {left, on_hold, overdue_exams}
-- add up those exams. alerts_open counts every open marking alert, of any exam (the alerts marking_alerts_list gives
-- an admin). pictures_to_check counts every marking picture that waits for staff, as script_marking_checks_list lists
-- them, with no cap. stale_assigned counts the pieces an admin assigned (no time limit) of exams whose marking is open,
-- still held and not on hold, of scripts not withdrawn or void, with no save and no assignment for 7 days (the later of
-- the assignment and the holder's last save is more than 7 days before p_now). Read only. No candidate name.
--
-- script_marking_checks_due (internal): the pages script_marking_checks_list lists, one row per page with the script
-- that shows it (unordered, uncapped), so the dashboard counts what the list shows.
--
-- Changed, from its latest definition:
--   script_marking_checks_list (20261122000009): reads its pages from script_marking_checks_due (the same rule, moved
--     there unchanged). Nothing else in it changed: still oldest first, at most 200, and more.

-- ---------------------------------------------------------------------------------------------
-- Internal: the pages to check (see the header), as script_marking_checks_list worked them out.
-- ---------------------------------------------------------------------------------------------
create function public.script_marking_checks_due(p_exam uuid default null)
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
    where s.state in ('receiving', 'checking', 'needs_attention', 'verified', 'ready_to_mark', 'marking', 'marked')
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
-- script_marking_checks_list: as 20261122000009, its pages read from script_marking_checks_due. Each item: {page_id,
-- exam_id, script_number, booking (script_booking_json: the candidate's name and index number, for staff), copy_page
-- (the page of the script, null for an extra page), full_path, marking_path}.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_marking_checks_list(p_exam uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_items jsonb;
  v_more boolean;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  with items as (
    select d.page_id, s.exam_id, s.number, s.booking_id, d.copy_page, p.full_path, p.marking_path,
      greatest((select max(e.resolved_at) from public.script_exceptions e
                where e.page_id = d.page_id and e.state = 'resolved' and e.resolution in ('confirmed', 'assigned')),
               p.marking_checked_at) as since
    from public.script_marking_checks_due(p_exam) d
    join public.scripts s on s.id = d.script_id
    join public.script_pages p on p.id = d.page_id
    order by 8 nulls first, d.page_id
    limit 201
  ),
  numbered as (
    select i.*, row_number() over (order by i.since nulls first, i.page_id) as n from items i
  )
  select coalesce(jsonb_agg(jsonb_build_object('page_id', i.page_id, 'exam_id', i.exam_id, 'script_number', i.number,
           'booking', public.script_booking_json(i.booking_id), 'copy_page', i.copy_page, 'full_path', i.full_path,
           'marking_path', i.marking_path) order by i.n) filter (where i.n <= 200), '[]'::jsonb),
         count(*) > 200
  into v_items, v_more
  from numbered i;
  return jsonb_build_object('ok', true, 'items', v_items, 'more', v_more);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_dashboard: the marking figures of the admin home page (see the header).
-- ---------------------------------------------------------------------------------------------
create function public.marking_dashboard(p_now timestamptz default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := public.paper_clock(p_now);
  v_exams jsonb;
  v_left int;
  v_on_hold int;
  v_overdue int;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;

  with ex as (
    select e.id, e.title, e.paper, e.starts_at, m.deadline, public.marking_exam_overdue(e.id, v_now) as overdue,
      c.left_n, c.marked, c.on_hold
    from public.exam_marking m
    join public.exams e on e.id = m.exam_id
    cross join lateral (
      select count(*) filter (where u.state <> 'submitted')::int as left_n,
             count(*) filter (where u.state = 'submitted')::int as marked,
             count(*) filter (where u.on_hold)::int as on_hold
      from public.marking_units u join public.scripts s on s.id = u.script_id
      where u.exam_id = e.id and s.state not in ('withdrawn', 'void')
    ) c
    where m.opened_at is not null and (m.closed_at is null or m.closed_at > v_now - interval '14 days')
  )
  select coalesce(jsonb_agg(jsonb_build_object('exam_id', x.id, 'title', x.title, 'paper', x.paper, 'deadline', x.deadline,
           'overdue', x.overdue, 'left', x.left_n, 'marked', x.marked, 'on_hold', x.on_hold)
           order by x.starts_at, x.id), '[]'::jsonb),
         coalesce(sum(x.left_n), 0)::int, coalesce(sum(x.on_hold), 0)::int, (count(*) filter (where x.overdue))::int
  into v_exams, v_left, v_on_hold, v_overdue
  from ex x;

  return jsonb_build_object('ok', true, 'exams', v_exams, 'totals', jsonb_build_object(
    'left', v_left,
    'on_hold', v_on_hold,
    'overdue_exams', v_overdue,
    'alerts_open', (select count(*)::int from public.marking_alerts a
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
        and greatest(a.created_at, x.last_saved_at) < v_now - interval '7 days')));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Access: marking_dashboard checks for an admin; the helper is internal. script_marking_checks_list keeps its
-- privileges.
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.script_marking_checks_due(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_dashboard(timestamptz) from public, anon;
grant execute on function public.marking_dashboard(timestamptz) to authenticated;
