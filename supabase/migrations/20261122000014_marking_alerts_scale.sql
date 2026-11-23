-- Phase 3A final review, I2 (and M9 for this list): the alerts list stays fast with 300 open alerts.
--
-- Before, marking_alerts_list ran marking_script_pages twice per alert (the page's number, and the missing-picture
-- rule inside marking_alert_can_release). With 300 open picture_changed alerts on 16-page scripts it took about 4 s
-- of the 8 s the API allows, and "Release all" sat behind it.
--
-- Added:
--   marking_scripts_pages(uuid[]) (internal): the pages markers mark, for many scripts in one read. The same rule as
--     marking_script_pages (20261122000007), which is left as it is; 051 tests that the two agree.
-- Changed, from its latest definition:
--   marking_alerts_list (20261122000011): the pages of the listed scripts are read once, together
--     (marking_scripts_pages), and each script's release reason is worked out once per script, not per alert; page_n
--     comes from the same read. The alerts and their fields are what they were (id, kind, exam_id, exam_title,
--     script_id, script_number, index_number, page_n, unit_id, created_at, can_release, release_blocked). The result
--     also says more: true when more than the 500 listed alerts matched.
-- Nothing else changed. No candidate name and no marker name.

-- ---------------------------------------------------------------------------------------------
-- Internal: marking_script_pages for many scripts at once: for each script named (once, however often it is named),
-- the pages markers mark, numbered from 1 within the script. Keep it in step with marking_script_pages: the same
-- pages, order and columns, with the script beside each row.
-- ---------------------------------------------------------------------------------------------
create function public.marking_scripts_pages(p_scripts uuid[])
returns table (script_id uuid, n int, page_id uuid, copy_page int, extra boolean, marking_path text, rotation int)
language sql
stable
security definer
set search_path = ''
as $$
  with wanted as materialized (
    select distinct s.id from public.scripts s where s.id = any (p_scripts)
  ),
  links as materialized (
    select s.id as script_id, l.copy_page, l.page_id
    from public.scripts s
    join public.script_page_links l on l.script_id = s.id and l.version = s.version
    where s.id in (select w.id from wanted w)
  ),
  slot as materialized (
    select w.id as script_id, public.script_slot_copy(w.id) as copy_id from wanted w
  ),
  shown as (
    select l.script_id, l.page_id, l.copy_page, false as extra, l.copy_page as after, 0 as tie, 0 as file_position, 0 as source_index
    from links l
    join slot s on s.script_id = l.script_id
    cross join lateral public.script_page_copy(l.page_id) t
    where not public.script_page_refused(l.page_id)
      and (coalesce(public.script_page_is_answer(t.copy_id, t.copy_page), false)
           or coalesce(public.script_page_is_answer(s.copy_id, l.copy_page), false))
    union all
    select w.id, x.page_id, null, true, x.placed_after, 1, x.file_position, x.source_index
    from wanted w
    cross join lateral public.script_extra_pages(w.id) x
    where not public.script_page_refused(x.page_id)
  )
  select sh.script_id,
    (row_number() over (partition by sh.script_id order by sh.after, sh.tie, sh.file_position, sh.source_index, sh.page_id))::int,
    sh.page_id, sh.copy_page, sh.extra, case when p.replaced_at is null then p.marking_path end, p.rotation
  from shown sh
  join public.script_pages p on p.id = sh.page_id
  order by 1, 2
$$;

revoke execute on function public.marking_scripts_pages(uuid[]) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- marking_alerts_list: the marking alerts (p_state open, closed, or null for all; of one exam when given), at most
-- 500, oldest first. Admins: all; a lead marker: those of the subjects they lead. Returns {ok, alerts, more (true when
-- more than those 500 matched)}. Each alert: {id, kind, exam_id, exam_title, script_id, script_number, index_number,
-- page_n (the page's number in the pieces, null when they do not show it), unit_id, created_at, can_release (an open
-- picture_changed alert whose script nothing holds back), release_blocked (for an open picture_changed alert, what
-- holds its release back; else null)}. No candidate name and no marker name.
--
-- What holds a release back is the rule of marking_alert_can_release (20261122000009), in its order: taken_back,
-- pictures_updating, picture_missing, picture_unchecked. It is worked out here once per script, from the one read of
-- the listed scripts' pages; marking_alert_release and marking_alerts_release_all still ask marking_alert_can_release
-- under their locks. Keep the two in step (048 and 051 test that they agree).
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_alerts_list(p_exam uuid default null, p_state text default 'open')
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
  v_alerts jsonb;
  v_more boolean;
begin
  if not v_admin and not exists (select 1 from public.marker_approvals a where a.marker_id = v_actor and a.lead and public.is_lead_for(v_actor, a.subject_id)) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_state is not null and p_state not in ('open', 'closed') then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
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

  with found as materialized (
    -- One more than is listed, to know whether there are more.
    select a.id, a.kind, a.exam_id, e.title, a.script_id, s.number, d.index_number, a.page_id, a.unit_id, a.created_at, a.state,
      s.taken_back_at is not null as taken_back
    from public.marking_alerts a
    join public.exams e on e.id = a.exam_id
    join public.scripts s on s.id = a.script_id
    join public.bookings b on b.id = s.booking_id
    left join public.student_details d on d.profile_id = b.student_id
    where (p_exam is null or a.exam_id = p_exam)
      and (p_state is null or a.state = p_state)
      and (v_admin or public.is_lead_for(v_actor, e.subject_id))
    order by a.created_at, a.id
    limit 501
  ),
  t as materialized (
    select * from found f order by f.created_at, f.id limit 500
  ),
  -- The pages of the listed scripts that need them (an alert about a page, or one that may be released), in one read.
  pages as materialized (
    select x.script_id, coalesce(bool_or(x.marking_path is null), false) as missing, jsonb_object_agg(x.page_id::text, x.n) as numbers
    from public.marking_scripts_pages(array(
           select distinct t.script_id from t where t.page_id is not null or (t.kind = 'picture_changed' and t.state = 'open'))) x
    group by x.script_id
  ),
  -- What holds each script's release back, once per script with an open picture_changed alert listed.
  held as materialized (
    select o.script_id,
      case
        when o.taken_back then 'taken_back'
        when public.marking_script_busy(o.script_id) then 'pictures_updating'
        when coalesce((select pg.missing from pages pg where pg.script_id = o.script_id), false) then 'picture_missing'
        when exists (select 1 from public.script_pages_to_check(o.script_id)) then 'picture_unchecked'
      end as why
    from (select distinct t.script_id, t.taken_back from t where t.kind = 'picture_changed' and t.state = 'open') o
  )
  select coalesce(jsonb_agg(jsonb_build_object(
        'id', t.id, 'kind', t.kind, 'exam_id', t.exam_id, 'exam_title', t.title, 'script_id', t.script_id,
        'script_number', t.number, 'index_number', t.index_number,
        'page_n', (pg.numbers ->> t.page_id::text)::int,
        'unit_id', t.unit_id, 'created_at', t.created_at,
        'can_release', t.kind = 'picture_changed' and t.state = 'open' and h.why is null,
        'release_blocked', h.why)
      order by t.created_at, t.id), '[]'::jsonb),
    (select count(*) > 500 from found)
  into v_alerts, v_more
  from t
  left join pages pg on pg.script_id = t.script_id
  left join held h on h.script_id = t.script_id and t.kind = 'picture_changed' and t.state = 'open';

  return jsonb_build_object('ok', true, 'alerts', v_alerts, 'more', v_more);
end;
$$;

revoke execute on function public.marking_alerts_list(uuid, text) from public, anon;
grant execute on function public.marking_alerts_list(uuid, text) to authenticated;
