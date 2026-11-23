-- Phase 3A final review, the minor items fixed in the one fix wave (Ruling R22).
--
-- Changed, each from its latest definition:
--   exam_structure_save (20261122000005):
--     M2. A question added after opening no longer gives a piece back to a marker who saw a name on it: a name_seen
--       exclusion counts as a block (the marking is set aside as name_seen, the piece is open, nobody is given it), as
--       marking_units_refresh does (Ruling R15). The keys of the markers whose submitted piece may go back to them are
--       taken (shared, in uuid order) before the exam's marking row and the script rows (Ruling R10); a piece
--       submitted between that read and the lock makes the save fail as a serialisation failure (40001), to be tried
--       again.
--     M5. After the lock, the audit row's reason ends with what changed: "(maximum 2(b) 5 -> 6; 1 question added;
--       3 pieces reopened)", or "(no maximum changed and no question added)".
--   marking_script_hold (20261122000008):
--     M3. The alert, and so its email, is raised only when at least one piece was held. A changed picture on a script
--       nobody has taken or submitted holds nothing and raises nothing (the script still waits for its picture check
--       where one is due: marking_script_waiting). picture_missing keeps its rule: it holds every piece.
--   marking_exam_get (20261122000009):
--     M4. The waiting rule runs once per script (a materialised step), not once per counted reason. Same result.
--   marking_units_list (20261122000006):
--     M9. The result also says more: true when more than the 2,000 listed pieces matched.
--   marking_tick (20261122000006):
--     Each exam's sync runs in its own block: one exam's error is logged (the exam and the SQLSTATE only, no message)
--       and does not stop the others or the holds that ran out from ending.
-- Privileges are as they were (create or replace keeps them; restated below).

-- ---------------------------------------------------------------------------------------------
-- exam_structure_save: as 20261122000005, with M2 and M5 above.
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
  -- (Ruling R10): the keys of the markers who have a submitted live marking in this exam are taken here (shared, in
  -- uuid order), before the exam's marking row and every script row. Only a save that may add a question takes them.
  -- A piece submitted between this read and the marking row's lock is caught below, where the pieces are read.
  if exists (select 1 from public.exam_marking m where m.exam_id = p_exam and m.opened_at is not null)
     and jsonb_typeof(p_structure -> 'questions') = 'array' then
    if exists (select 1 from jsonb_array_elements(p_structure -> 'questions') e where e ->> 'id' is null) then
      for v_marker in
        select distinct m.marker_id from public.markings m join public.marking_units u on u.id = m.unit_id
        where u.exam_id = p_exam and m.kind = 'live' and m.status = 'submitted'
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

  -- A question added once marking has opened: the submitted live pieces that include it (the whole script, or the
  -- group of its top-level question) of scripts still being marked (not withdrawn or void) are reopened, and their
  -- scripts are being marked again. A piece goes back to the same marker when they may still mark it (is_marker_for:
  -- an active, approved marker of the subject; and not blocked for the candidate). Otherwise the piece is open again
  -- for anyone and that marking is set aside (unapproved, or conflict when blocked), so no hold is left stranded.
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

    -- Every marker whose piece may go back to them must have had their key taken above. One who submitted since
    -- (before this save held the exam's marking row) was not: nothing is saved, and the save is tried again.
    if exists (select 1 from public.markings m
               where m.unit_id = any (v_units) and m.kind = 'live' and m.status = 'submitted' and not (m.marker_id = any (v_keys))) then
      raise exception 'a piece was submitted while the structure was being saved' using errcode = '40001';
    end if;

    with pieces as (
      select m.id as marking_id, m.unit_id, m.marker_id, u.script_id,
        public.is_marker_for(m.marker_id, v_e.subject_id) as approved,
        -- A marker who saw a name on the piece (a name_seen exclusion, Name visible) is not given it again: as a block.
        public.marking_marker_blocked(m.marker_id, b.student_id)
          or exists (select 1 from public.marking_unit_exclusions x where x.unit_id = m.unit_id and x.marker_id = m.marker_id) as blocked,
        exists (select 1 from public.marking_unit_exclusions x where x.unit_id = m.unit_id and x.marker_id = m.marker_id) as name_seen
      from public.markings m
      join public.marking_units u on u.id = m.unit_id
      join public.scripts s on s.id = u.script_id
      join public.bookings b on b.id = s.booking_id
      where m.unit_id = any (v_units) and m.kind = 'live' and m.status = 'submitted'
        and s.state not in ('withdrawn', 'void')
    ),
    reopened as (
      update public.markings m set status = 'in_progress', submitted_at = null
      from pieces p where m.id = p.marking_id and p.approved and not p.blocked
      returning m.unit_id, m.marker_id
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
      from pieces p where u.id = p.unit_id
      returning u.script_id
    ),
    assigned as (
      insert into public.marking_assignments (unit_id, kind, marker_id, how, assigned_by)
      select ro.unit_id, 'live', ro.marker_id, 'assigned', v_actor from reopened ro
    )
    select coalesce(array_agg(distinct units.script_id order by units.script_id), '{}'), count(*)::int
    into v_scripts, v_reopened from units;
    -- Each reopened script's state follows its units (a marked script is being marked again).
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
-- Internal: marking_script_hold, as 20261122000008, with M3 above.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_script_hold(p_script uuid, p_hold_reason text, p_alert_kind text, p_page uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_held int;
begin
  perform 1 from public.scripts s where s.id = p_script for no key update;
  update public.marking_units u
  set on_hold = true,
    hold_reason = case when u.on_hold and u.hold_reason is distinct from 'picture_changed' then u.hold_reason else p_hold_reason end
  where u.script_id = p_script and (p_hold_reason = 'picture_missing' or u.state in ('taken', 'submitted'));
  get diagnostics v_held = row_count;
  if v_held > 0 then
    perform public.marking_alert_raise(p_script, p_alert_kind, null, p_page);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_exam_get: as 20261122000009, with M4 above.
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
                  'marked', count(*) filter (where s.state = 'marked'))
                from public.scripts s where s.exam_id = p_exam),
    'waiting', v_waiting);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_units_list: as 20261122000006, with M9 above. Returns {ok, units, more}.
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
      'marker_id', p.id,
      'marker_name', case when p.id is not null then coalesce(nullif(btrim(p.first_name || ' ' || p.last_name), ''), 'Marker ' || left(p.id::text, 8)) end,
      'how', a.how, 'hold_until', a.hold_until, 'last_saved_at', x.last_saved_at, 'submitted_at', x.submitted_at, 'total', x.total,
      'waiting', case when u.state <> 'submitted' then w.why end) as j
    from public.marking_units u
    join public.scripts s on s.id = u.script_id
    left join waiting w on w.script_id = u.script_id
    join public.bookings b on b.id = s.booking_id
    left join public.student_details d on d.profile_id = b.student_id
    left join public.question_groups g on g.id = u.group_id
    left join public.marking_assignments a on a.unit_id = u.id and a.kind = 'live' and a.ended_at is null
    left join public.markings x on x.unit_id = u.id and x.kind = 'live' and x.status <> 'set_aside'
    left join public.profiles p on p.id = coalesce(a.marker_id, x.marker_id)
    where u.exam_id = p_exam
      and (p_state is null or (p_state = 'on_hold' and u.on_hold) or u.state = p_state)
      and (p_marker is null or coalesce(a.marker_id, x.marker_id) = p_marker)
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
-- Internal: the minute job, as 20261122000006, with a block per exam.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_tick()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
begin
  for r in select m.exam_id from public.exam_marking m where m.opened_at is not null and m.closed_at is null order by m.exam_id loop
    -- One exam's failure is its own: what it did is undone, the others still run, and the next minute tries it again.
    -- The log line names the exam and the error's SQLSTATE only: an error's message can quote a row.
    begin
      perform public.marking_exam_sync(r.exam_id, null);
    exception when others then
      raise warning 'marking_tick: the sync of exam % failed (SQLSTATE %)', r.exam_id, sqlstate;
    end;
  end loop;
  perform public.marking_holds_expire(null);
end;
$$;

revoke execute on function public.exam_structure_save(uuid, jsonb, text) from public, anon;
grant execute on function public.exam_structure_save(uuid, jsonb, text) to authenticated;
revoke execute on function public.marking_script_hold(uuid, text, text, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.marking_exam_get(uuid, timestamptz) from public, anon;
grant execute on function public.marking_exam_get(uuid, timestamptz) to authenticated;
revoke execute on function public.marking_units_list(uuid, text, uuid) from public, anon;
grant execute on function public.marking_units_list(uuid, text, uuid) to authenticated;
revoke execute on function public.marking_tick() from public, anon, authenticated, service_role;
