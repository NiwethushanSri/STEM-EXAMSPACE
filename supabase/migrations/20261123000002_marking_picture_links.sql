-- Phase 3B Task 1: marking picture links are signed on the server, after a permission check in the database
-- (Phase 3A's known limit R12: a marker holding a piece could make a long-lived signed link to its pictures through
-- the storage policy).
--
-- The Edge Function marking-pictures asks marking_picture_paths, as the signed-in caller, for the marking pictures of
-- some pages of a piece, then signs each path it is given for 120 seconds with the service role. Nobody is handed a
-- picture's path any more, and no marker or lead may read script-pages from storage themselves: the policy
-- script_pages_objects_select_marker and its question marking_picture_allowed are dropped. The staff policy
-- (script_pages_objects_select: is_staff_admin) stays, so the admin pages keep their own links.
--
-- Added:
--   marking_picture_paths(p_unit, p_pages, p_now): the marking pictures of 1 to 40 pages of a piece, for the caller
--     who may see them now (the marker who may work on the piece, as marking_work_blocked says; the subject's lead
--     marker, by the lead's rule of marking_picture_allowed (20261122000008), word for word; an admin). Never a full
--     picture.
--   marking_alert_pages(p_alert): the pages of an alert's script, the changed one marked, for the lead's page viewer.
-- Dropped: the policy script_pages_objects_select_marker and marking_picture_allowed(text) (20261122000008).
-- Changed, each from its latest definition:
--   marking_unit_open (20261122000007): each page is {n, page_id, copy_page, extra, rotation, has_picture}; its
--     marking_path is no longer sent.
--   marking_alerts_list (20261122000014): for a lead marker blocked for the candidate (marking_marker_blocked: a
--     declared conflict or a tutor link), an open picture_changed alert says release_blocked conflict_of_interest and
--     can_release false (the release itself was already refused).
-- Nothing else in them changed. Nothing here names a candidate: script and index numbers only.

drop policy script_pages_objects_select_marker on storage.objects;
drop function public.marking_picture_allowed(text);

-- ---------------------------------------------------------------------------------------------
-- marking_picture_paths: the current marking pictures of p_pages (1 to 40 page ids; invalid_input otherwise) of the
-- piece p_unit (not_found when there is none), for the caller, when one of these holds:
--   (a) they may work on the piece now (marking_work_blocked(p_unit, caller, p_now) is null: they hold it, or
--       submitted it, it is not on hold, its script is being marked and not busy, and marking is open);
--   (b) they are the subject's lead marker, marking is open, the script is ready to mark, being marked or marked and
--       not taken back, they are not blocked for its candidate, the script has an open alert other than name_visible
--       and no open name_visible alert, and no requested page has an open name_visible exception (the lead's rule of
--       marking_picture_allowed, 20261122000008);
--   (c) they are an admin (is_staff_admin).
-- Otherwise: the refusal marking_work_blocked gave (on_hold, hold_expired, pictures_updating, marking_closed,
-- forbidden), or forbidden. Every page must be one the piece shows (marking_script_pages of its script) with a current
-- marking picture that is not its full picture: one that is not refuses the whole call (forbidden). Returns
-- {ok, paths: [{page_id, marking_path}]}, once per page, in the order asked.
-- ---------------------------------------------------------------------------------------------
create function public.marking_picture_paths(p_unit uuid, p_pages uuid[], p_now timestamptz default null)
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
         and s.state in ('ready_to_mark', 'marking', 'marked') and s.taken_back_at is null
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
-- marking_unit_open: as 20261122000007, except that each page says has_picture (it has a current marking picture)
-- instead of its marking_path: pages:[{n, page_id, copy_page, extra, rotation, has_picture}]. The screen asks the Edge
-- Function marking-pictures for its links.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_unit_open(p_unit uuid, p_now timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := public.paper_clock(p_now);
  v_u public.marking_units%rowtype;
  v_x public.scripts%rowtype;
  v_e public.exams%rowtype;
  v_m public.exam_marking%rowtype;
  v_a public.marking_assignments%rowtype;
  v_mk public.markings%rowtype;
  v_why text;
  v_pages jsonb;
begin
  if p_unit is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  perform pg_advisory_xact_lock_shared(hashtextextended('marker:' || v_actor::text, 0));
  select * into v_u from public.marking_units u where u.id = p_unit;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  -- Ruling R9: the exam's marking row, the script's row, the piece's, then its assignment and marking.
  select * into v_m from public.exam_marking m where m.exam_id = v_u.exam_id for share;
  select * into v_x from public.scripts s where s.id = v_u.script_id for no key update;
  select * into v_u from public.marking_units u where u.id = p_unit for update;
  select * into v_mk from public.markings m where m.unit_id = p_unit and m.kind = 'live' and m.marker_id = v_actor for update;
  v_why := public.marking_work_blocked(p_unit, v_actor, v_now);
  if v_why is not null and not (v_why = 'marking_closed' and v_mk.status = 'submitted') then
    return jsonb_build_object('ok', false, 'code', v_why);
  end if;

  select * into v_a from public.marking_assignments a
  where a.unit_id = p_unit and a.kind = 'live' and a.marker_id = v_actor and a.ended_at is null for update;
  if v_mk.id is null then
    insert into public.markings (unit_id, kind, marker_id, pages_key)
    values (p_unit, 'live', v_actor, public.marking_pages_key(v_u.script_id))
    returning * into v_mk;
    perform public.marking_script_state(v_u.script_id);
  end if;
  if v_a.how = 'next' then
    update public.marking_assignments set hold_until = v_now + interval '2 hours' where id = v_a.id returning * into v_a;
  end if;
  select * into v_e from public.exams e where e.id = v_u.exam_id;

  select coalesce(jsonb_agg(jsonb_build_object('n', x.n, 'page_id', x.page_id, 'copy_page', x.copy_page, 'extra', x.extra,
                                               'rotation', x.rotation, 'has_picture', x.marking_path is not null) order by x.n), '[]'::jsonb)
  into v_pages
  from public.marking_script_pages(v_u.script_id) x;

  return jsonb_build_object(
    'ok', true,
    'unit', jsonb_build_object(
      'id', v_u.id,
      'exam_title', v_e.title,
      'paper', v_e.paper,
      'subject', (select s.name from public.subjects s where s.id = v_e.subject_id),
      'script_number', v_x.number,
      'index_number', (select d.index_number from public.bookings b join public.student_details d on d.profile_id = b.student_id
                       where b.id = v_x.booking_id),
      'group_label', (select g.label from public.question_groups g where g.id = v_u.group_id),
      'deadline', v_m.deadline,
      'hold_until', v_a.hold_until,
      'closed', v_m.closed_at is not null),
    'marking', jsonb_build_object(
      'id', v_mk.id, 'rev', v_mk.rev, 'status', v_mk.status, 'lead_note', v_mk.lead_note, 'total', v_mk.total,
      'max_total', public.marking_unit_max_total(p_unit), 'pages_changed', v_mk.pages_changed_at is not null),
    'structure', jsonb_build_object(
      'version', coalesce(v_m.structure_version, 0),
      'questions', coalesce((
        select jsonb_agg(jsonb_build_object(
            'id', q.id, 'parent_id', q.parent_id, 'label', q.label, 'position', q.position, 'max_mark', q.max_mark,
            'mark_step', q.mark_step, 'levels', q.levels, 'pages', to_jsonb(q.pages), 'areas', q.areas, 'group_id', q.group_id,
            'option_group_id', q.option_group_id, 'guidance', q.guidance, 'alternatives', q.alternatives,
            'points', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'label', p.label, 'marks', p.marks,
                                                                    'marks_to', p.marks_to, 'text', p.text) order by p.position)
                                from public.mark_scheme_points p where p.question_id = q.id), '[]'::jsonb))
          order by t.path)
        from public.marking_unit_questions(p_unit) t join public.exam_questions q on q.id = t.question_id), '[]'::jsonb),
      'option_groups', coalesce((
        select jsonb_agg(jsonb_build_object('id', o.id, 'label', o.label, 'choose', o.choose) order by o.label, o.id)
        from public.exam_option_groups o
        where o.id in (select q.option_group_id from public.marking_unit_questions(p_unit) t
                       join public.exam_questions q on q.id = t.question_id)), '[]'::jsonb),
      'mark_scheme_file', (select jsonb_build_object('id', f.id, 'storage_path', f.storage_path)
                           from public.exam_mark_scheme_files f where f.exam_id = v_u.exam_id and f.state = 'stored'
                           order by f.uploaded_at desc limit 1)),
    'pages', v_pages,
    'marks', coalesce((
      select jsonb_agg(jsonb_build_object('question_id', m.question_id, 'mark', m.mark, 'na', m.not_attempted) order by t.path)
      from public.question_marks m join public.marking_unit_questions(p_unit) t on t.question_id = m.question_id
      where m.marking_id = v_mk.id), '[]'::jsonb),
    'annotations', coalesce((
      select jsonb_agg(jsonb_build_object('id', a.id, 'page_id', a.page_id, 'kind', a.kind, 'x', a.x, 'y', a.y, 'points', a.points,
                                          'text', a.text, 'question_id', a.question_id) order by a.created_at, a.id)
      from public.page_annotations a
      where a.marking_id = v_mk.id and a.deleted_at is null
        and exists (select 1 from jsonb_array_elements(v_pages) p
                    where (p ->> 'page_id')::uuid = a.page_id and (p ->> 'rotation')::int = a.page_rotation)), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_alert_pages: for an admin or the subject's lead marker, the pages an alert's script shows to its markers
-- (marking_script_pages), the alert's page marked as changed, and a piece of the script (unit_id, the one with the
-- lowest id) to ask marking-pictures for their links. Refused: invalid_input, not_found (an admin; others are told
-- forbidden), forbidden (not the subject's lead), conflict_of_interest (a lead blocked for the candidate,
-- marking_marker_blocked; an admin never is). Returns {ok, unit_id, script_number, index_number,
-- pages: [{n, page_id, copy_page, changed}]}. No candidate name and no path.
-- ---------------------------------------------------------------------------------------------
create function public.marking_alert_pages(p_alert uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_admin boolean := public.is_staff_admin();
  v_a public.marking_alerts%rowtype;
  v_x public.scripts%rowtype;
  v_subject bigint;
  v_student uuid;
begin
  if p_alert is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_a from public.marking_alerts a where a.id = p_alert;
  if not found then
    return jsonb_build_object('ok', false, 'code', case when v_admin then 'not_found' else 'forbidden' end);
  end if;
  select e.subject_id into v_subject from public.exams e where e.id = v_a.exam_id;
  if not v_admin and not public.is_lead_for(v_actor, v_subject) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select * into v_x from public.scripts s where s.id = v_a.script_id;
  select b.student_id into v_student from public.bookings b where b.id = v_x.booking_id;
  if not v_admin and public.marking_marker_blocked(v_actor, v_student) then
    return jsonb_build_object('ok', false, 'code', 'conflict_of_interest');
  end if;

  return jsonb_build_object(
    'ok', true,
    'unit_id', (select u.id from public.marking_units u where u.script_id = v_x.id order by u.id limit 1),
    'script_number', v_x.number,
    'index_number', (select d.index_number from public.student_details d where d.profile_id = v_student),
    'pages', coalesce((
      select jsonb_agg(jsonb_build_object('n', x.n, 'page_id', x.page_id, 'copy_page', x.copy_page,
                                          'changed', coalesce(x.page_id = v_a.page_id, false)) order by x.n)
      from public.marking_script_pages(v_x.id) x), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_alerts_list: as 20261122000014, and for a lead marker blocked for a script's candidate
-- (marking_marker_blocked) an open picture_changed alert of that script says release_blocked conflict_of_interest
-- (before any other reason) and can_release false. An admin is never blocked.
--
-- The marking alerts (p_state open, closed, or null for all; of one exam when given), at most 500, oldest first.
-- Admins: all; a lead marker: those of the subjects they lead. Returns {ok, alerts, more (true when more than those 500
-- matched)}. Each alert: {id, kind, exam_id, exam_title, script_id, script_number, index_number, page_n (the page's
-- number in the pieces, null when they do not show it), unit_id, created_at, can_release (an open picture_changed
-- alert whose script nothing holds back), release_blocked (for an open picture_changed alert, what holds its release
-- back; else null)}. No candidate name and no marker name.
--
-- What holds a release back is conflict_of_interest for a blocked lead, then the rule of marking_alert_can_release
-- (20261122000009), in its order: taken_back, pictures_updating, picture_missing, picture_unchecked. It is worked out
-- here once per script, from the one read of the listed scripts' pages; marking_alert_release and
-- marking_alerts_release_all still ask marking_alert_can_release under their locks. Keep the two in step (048 and 051
-- test that they agree).
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
      s.taken_back_at is not null as taken_back, b.student_id
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
        when not v_admin and public.marking_marker_blocked(v_actor, o.student_id) then 'conflict_of_interest'
        when o.taken_back then 'taken_back'
        when public.marking_script_busy(o.script_id) then 'pictures_updating'
        when coalesce((select pg.missing from pages pg where pg.script_id = o.script_id), false) then 'picture_missing'
        when exists (select 1 from public.script_pages_to_check(o.script_id)) then 'picture_unchecked'
      end as why
    from (select distinct t.script_id, t.taken_back, t.student_id from t where t.kind = 'picture_changed' and t.state = 'open') o
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

-- ---------------------------------------------------------------------------------------------
-- Privileges. marking_unit_open and marking_alerts_list keep theirs.
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.marking_picture_paths(uuid, uuid[], timestamptz) from public, anon;
revoke execute on function public.marking_alert_pages(uuid) from public, anon;
grant execute on function public.marking_picture_paths(uuid, uuid[], timestamptz) to authenticated;
grant execute on function public.marking_alert_pages(uuid) to authenticated;
