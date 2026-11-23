-- Phase 3A Task 10 (Ruling R18): the marking alerts list says why Release is not offered, so the lead's and the admins'
-- pages can say it in one plain sentence.
--
-- Changed, from its latest definition:
--   marking_alerts_list (20261122000008): each alert also says release_blocked, beside can_release: for an open
--     picture_changed alert, the reason marking_alert_can_release gives (taken_back, pictures_updating, picture_missing
--     or picture_unchecked), or null when it may be released; null for any other alert (another kind is never released,
--     and a closed one has nothing to release). can_release is now worked out from it: an open picture_changed alert
--     with no reason. marking_alert_can_release runs once per alert.
-- Nothing else in it changed. No candidate name and no marker name.

-- ---------------------------------------------------------------------------------------------
-- marking_alerts_list: the marking alerts (p_state open, closed, or null for all; of one exam when given), at most
-- 500, oldest first. Admins: all; a lead marker: those of the subjects they lead. Each: {id, kind, exam_id,
-- exam_title, script_id, script_number, index_number, page_n (the page's number in the pieces, null when they do not
-- show it), unit_id, created_at, can_release (an open picture_changed alert whose script marking_alert_can_release
-- allows), release_blocked (for an open picture_changed alert, what marking_alert_can_release says holds it back;
-- else null)}. No candidate name and no marker name.
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

  return jsonb_build_object('ok', true, 'alerts', coalesce((
    select jsonb_agg(jsonb_build_object(
        'id', t.id, 'kind', t.kind, 'exam_id', t.exam_id, 'exam_title', t.title, 'script_id', t.script_id,
        'script_number', t.number, 'index_number', t.index_number,
        'page_n', (select x.n from public.marking_script_pages(t.script_id) x where x.page_id = t.page_id),
        'unit_id', t.unit_id, 'created_at', t.created_at,
        'can_release', t.kind = 'picture_changed' and t.state = 'open' and w.why is null,
        'release_blocked', w.why)
      order by t.created_at, t.id)
    from (
      select a.id, a.kind, a.exam_id, e.title, a.script_id, s.number, d.index_number, a.page_id, a.unit_id, a.created_at, a.state
      from public.marking_alerts a
      join public.exams e on e.id = a.exam_id
      join public.scripts s on s.id = a.script_id
      join public.bookings b on b.id = s.booking_id
      left join public.student_details d on d.profile_id = b.student_id
      where (p_exam is null or a.exam_id = p_exam)
        and (p_state is null or a.state = p_state)
        and (v_admin or public.is_lead_for(v_actor, e.subject_id))
      order by a.created_at, a.id
      limit 500
    ) t
    -- What holds an open picture_changed alert's release back, once per alert (null for the others).
    cross join lateral (
      select case when t.kind = 'picture_changed' and t.state = 'open' then public.marking_alert_can_release(t.script_id) end as why
    ) w), '[]'::jsonb));
end;
$$;

revoke execute on function public.marking_alerts_list(uuid, text) from public, anon;
grant execute on function public.marking_alerts_list(uuid, text) to authenticated;
