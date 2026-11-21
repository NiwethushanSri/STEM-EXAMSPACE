-- Phase 3A Task 2: an exam's questions and mark scheme, the lock once marking has opened, and the mark scheme PDF.
--
-- An admin or a teacher of the subject (structure_can_edit) saves the whole structure at once: questions and parts
-- (at most 3 levels, 1 to 200 questions to mark), each with its maximum, whole or half marks, marking by levels, the
-- answer or spare pages where it is answered, its marking points, acceptable alternatives and guidance; question
-- groups (the units of an exam marked by question) and optional questions ("Answer {choose} of these").
--
-- Before marking opens the save replaces everything: questions sent with an id are kept, the others are added, and
-- those not sent are deleted. Groups and optional questions are matched by their label. Once exam_marking.opened_at is
-- set (Task 4's marking_open; Ruling R1) only an admin may change it, with a reason, and only as Builder's call 11
-- allows: wording, marking points, guidance and pages; a maximum, never below a mark already given; and new questions.
-- A question added then reopens every submitted live piece that includes it, for the same marker (Task 4 replaces the
-- script state line with marking_script_state). Every save adds 1 to exam_marking.structure_version (the row is made
-- when it is missing) and writes an audit row.
--
-- The mark scheme PDF lives in the private mark-schemes bucket at <exam>/<file id>.pdf (Builder's call 18): one stored
-- file per exam, which editors of the structure and the subject's approved markers may read.
--
-- No earlier function is changed.

-- ---------------------------------------------------------------------------------------------
-- Internal: the pages a question may be answered on: the current paper's answer pages, then its spare pages
-- (page_count + 1 to page_count + spare_pages). Empty while the exam has no paper.
-- ---------------------------------------------------------------------------------------------
create function public.exam_structure_pages(p_exam uuid)
returns int[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(g.page order by g.page), '{}')
  from public.exams e
  join public.exam_papers p on p.exam_id = e.id and p.kind = 'paper' and p.superseded_at is null
  cross join lateral (
    select r.page from public.paper_page_roles r where r.paper_id = p.id and r.role = 'answer'
    union all
    select p.page_count + s.n from generate_series(1, e.spare_pages) s(n)
  ) g
  where e.id = p_exam
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the paper total. The maxima of the questions to mark (questions without parts), where each group of
-- optional questions counts only its best `choose` questions.
-- ---------------------------------------------------------------------------------------------
create function public.exam_structure_max_total(p_exam uuid)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  with recursive tree as (
    select q.id, q.id as top_id from public.exam_questions q where q.exam_id = p_exam and q.parent_id is null
    union all
    select c.id, t.top_id from public.exam_questions c join tree t on c.parent_id = t.id
  ),
  tops as (
    select t.top_id, sum(coalesce(q.max_mark, 0)) as total
    from tree t
    join public.exam_questions q on q.id = t.id
    where not exists (select 1 from public.exam_questions k where k.parent_id = q.id)
    group by t.top_id
  ),
  ranked as (
    select tp.total, top.option_group_id, og.choose,
      row_number() over (partition by top.option_group_id order by tp.total desc) as n
    from tops tp
    join public.exam_questions top on top.id = tp.top_id
    left join public.exam_option_groups og on og.id = top.option_group_id
  )
  select coalesce(sum(total) filter (where option_group_id is null or n <= choose), 0) from ranked
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: whether p_structure keeps every rule of exam_structure_save, given the pages it may use. Reads only the
-- payload.
-- ---------------------------------------------------------------------------------------------
create function public.exam_structure_valid(p_structure jsonb, p_pages int[])
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_groups jsonb;
  v_options jsonb;
  v_qs jsonb;
  v_uuid constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
  v_ok boolean;
begin
  if p_structure is null or jsonb_typeof(p_structure) <> 'object' then
    return false;
  end if;
  v_groups := coalesce(p_structure -> 'groups', '[]');
  v_options := coalesce(p_structure -> 'option_groups', '[]');
  v_qs := p_structure -> 'questions';
  if jsonb_typeof(v_groups) <> 'array' or jsonb_typeof(v_options) <> 'array' or jsonb_typeof(v_qs) is distinct from 'array'
     or jsonb_array_length(v_qs) not between 1 and 600 or jsonb_array_length(v_groups) > 200 or jsonb_array_length(v_options) > 100 then
    return false;
  end if;

  -- Shapes and types, so that every cast below is safe.
  if exists (
       select 1 from jsonb_array_elements(v_groups) g
       where jsonb_typeof(g) <> 'object'
          or jsonb_typeof(g -> 'key') is distinct from 'string' or char_length(g ->> 'key') not between 1 and 100
          or jsonb_typeof(g -> 'label') is distinct from 'string' or char_length(btrim(g ->> 'label')) not between 1 and 40)
     or exists (
       select 1 from jsonb_array_elements(v_options) o
       where jsonb_typeof(o) <> 'object'
          or jsonb_typeof(o -> 'key') is distinct from 'string' or char_length(o ->> 'key') not between 1 and 100
          or jsonb_typeof(o -> 'label') is distinct from 'string' or char_length(btrim(o ->> 'label')) not between 1 and 60
          or jsonb_typeof(o -> 'choose') is distinct from 'number' or (o ->> 'choose') !~ '^[0-9]{1,3}$' or (o ->> 'choose')::int < 1)
     or exists (
       select 1 from jsonb_array_elements(v_qs) q
       where jsonb_typeof(q) <> 'object'
          or coalesce(jsonb_typeof(q -> 'id'), 'null') not in ('null', 'string') or (q ->> 'id') !~ v_uuid
          or jsonb_typeof(q -> 'key') is distinct from 'string' or char_length(q ->> 'key') not between 1 and 100
          or coalesce(jsonb_typeof(q -> 'parent_key'), 'null') not in ('null', 'string')
          or jsonb_typeof(q -> 'label') is distinct from 'string' or char_length(btrim(q ->> 'label')) not between 1 and 20
          or coalesce(jsonb_typeof(q -> 'max_mark'), 'null') not in ('null', 'number')
          or jsonb_typeof(q -> 'mark_step') is distinct from 'number' or (q ->> 'mark_step')::numeric not in (0.5, 1)
          or jsonb_typeof(q -> 'levels') is distinct from 'boolean'
          or coalesce(jsonb_typeof(q -> 'pages'), 'array') <> 'array'
          or coalesce(jsonb_typeof(q -> 'areas'), 'array') <> 'array'
          or coalesce(jsonb_typeof(q -> 'points'), 'array') <> 'array'
          or coalesce(jsonb_typeof(q -> 'group_key'), 'null') not in ('null', 'string')
          or coalesce(jsonb_typeof(q -> 'option_group_key'), 'null') not in ('null', 'string')
          or coalesce(jsonb_typeof(q -> 'guidance'), 'null') not in ('null', 'string') or char_length(btrim(q ->> 'guidance')) > 4000
          or coalesce(jsonb_typeof(q -> 'alternatives'), 'null') not in ('null', 'string') or char_length(btrim(q ->> 'alternatives')) > 2000
          or jsonb_array_length(coalesce(q -> 'areas', '[]')) > 5
          or jsonb_array_length(coalesce(q -> 'points', '[]')) > 30
          or exists (select 1 from jsonb_array_elements(coalesce(q -> 'pages', '[]')) p
                     where jsonb_typeof(p) <> 'number' or (p #>> '{}') !~ '^[0-9]{1,4}$' or (p #>> '{}')::int <> all (p_pages))
          or (select count(*) <> count(distinct p #>> '{}') from jsonb_array_elements(coalesce(q -> 'pages', '[]')) p)
          or exists (select 1 from jsonb_array_elements(coalesce(q -> 'areas', '[]')) a
                     where jsonb_typeof(a) <> 'object'
                        or jsonb_typeof(a -> 'page') is distinct from 'number' or (a ->> 'page') !~ '^[0-9]{1,4}$'
                        or (a ->> 'page')::int <> all (p_pages)
                        or jsonb_typeof(a -> 'x') is distinct from 'number' or jsonb_typeof(a -> 'y') is distinct from 'number'
                        or jsonb_typeof(a -> 'w') is distinct from 'number' or jsonb_typeof(a -> 'h') is distinct from 'number'
                        or (a ->> 'x')::numeric < 0 or (a ->> 'y')::numeric < 0
                        or (a ->> 'w')::numeric <= 0 or (a ->> 'h')::numeric <= 0
                        or (a ->> 'x')::numeric + (a ->> 'w')::numeric > 1 or (a ->> 'y')::numeric + (a ->> 'h')::numeric > 1)
          or exists (select 1 from jsonb_array_elements(coalesce(q -> 'points', '[]')) p
                     where jsonb_typeof(p) <> 'object'
                        or coalesce(jsonb_typeof(p -> 'label'), 'null') not in ('null', 'string') or char_length(btrim(p ->> 'label')) > 12
                        or jsonb_typeof(p -> 'marks') is distinct from 'number'
                        or (p ->> 'marks')::numeric < 0 or (p ->> 'marks')::numeric > 100 or mod((p ->> 'marks')::numeric, 0.5) <> 0
                        or coalesce(jsonb_typeof(p -> 'marks_to'), 'null') not in ('null', 'number')
                        or (p ->> 'marks_to')::numeric < (p ->> 'marks')::numeric or (p ->> 'marks_to')::numeric > 100
                        or mod((p ->> 'marks_to')::numeric, 0.5) <> 0
                        or jsonb_typeof(p -> 'text') is distinct from 'string' or char_length(btrim(p ->> 'text')) not between 1 and 500))
  then
    return false;
  end if;

  -- The rules between rows.
  with recursive q as (
    select e ->> 'id' as id, e ->> 'key' as key, e ->> 'parent_key' as parent_key, btrim(e ->> 'label') as label,
      (e ->> 'max_mark')::numeric as max_mark, (e ->> 'mark_step')::numeric as mark_step,
      e ->> 'group_key' as group_key, e ->> 'option_group_key' as option_group_key, coalesce(e -> 'points', '[]') as points
    from jsonb_array_elements(v_qs) e
  ),
  tree as (
    select q.key, 1 as depth from q where q.parent_key is null
    union all
    select c.key, t.depth + 1 from q c join tree t on c.parent_key = t.key where t.depth < 4
  ),
  leaf as (
    select q.* from q where not exists (select 1 from q c where c.parent_key = q.key)
  ),
  -- Every question with each of its ancestors (and itself); bounded, as a cycle is only refused below.
  anc as (
    select q.key, q.key as anc, 0 as n from q
    union all
    select a.key, p.parent_key, a.n + 1 from anc a join q p on p.key = a.anc where p.parent_key is not null and a.n < 4
  ),
  total as (
    select a.anc as key, sum(l.max_mark) as total from anc a join leaf l on l.key = a.key group by a.anc
  ),
  g as (
    select x ->> 'key' as key, btrim(x ->> 'label') as label from jsonb_array_elements(v_groups) x
  ),
  o as (
    select x ->> 'key' as key, btrim(x ->> 'label') as label, (x ->> 'choose')::int as choose from jsonb_array_elements(v_options) x
  )
  select
    -- keys and ids unique; every parent sent; no cycle; at most 3 levels; 1 to 200 questions to mark
    (select count(distinct key) = count(*) from q)
    and (select count(distinct id) = count(id) from q)
    and (select count(distinct key) = count(*) from g) and (select count(distinct label) = count(*) from g)
    and (select count(distinct key) = count(*) from o) and (select count(distinct label) = count(*) from o)
    and not exists (select 1 from q where q.parent_key is not null and not exists (select 1 from q p where p.key = q.parent_key))
    and (select count(*) from tree) = (select count(*) from q)
    and (select max(depth) from tree) <= 3
    and (select count(*) from leaf) between 1 and 200
    -- labels unique among siblings
    and not exists (select 1 from q group by coalesce(q.parent_key, ''), q.label having count(*) > 1)
    -- a question with parts has no maximum; a question without parts has one, between 0.5 and 100, a multiple of its step
    and not exists (select 1 from q where q.max_mark is not null and exists (select 1 from q c where c.parent_key = q.key))
    and not exists (select 1 from leaf where leaf.max_mark is null or leaf.max_mark not between 0.5 and 100
                                          or mod(leaf.max_mark, leaf.mark_step) <> 0)
    -- groups and optional questions: known keys, on top-level questions only
    and not exists (select 1 from q where q.group_key is not null and (q.parent_key is not null or q.group_key not in (select key from g)))
    and not exists (select 1 from q where q.option_group_key is not null
                                      and (q.parent_key is not null or q.option_group_key not in (select key from o)))
    -- every group has a question
    and not exists (select 1 from g where not exists (select 1 from q where q.group_key = g.key))
    -- optional questions: at least 2, choose below their number, equal totals
    and not exists (
      select 1 from o
      left join q on q.option_group_key = o.key
      left join total t on t.key = q.key
      group by o.key, o.choose
      having count(q.key) < 2 or o.choose >= count(q.key) or count(distinct t.total) <> 1)
    -- a marking point (and the top of a band) is worth no more than its question
    and not exists (
      select 1 from q join total t on t.key = q.key, jsonb_array_elements(q.points) p
      where (p ->> 'marks')::numeric > t.total or (p ->> 'marks_to')::numeric > t.total)
  into v_ok;
  return coalesce(v_ok, false);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- exam_structure_get: the structure for an editor. {ok, version, locked, max_total, groups, option_groups, questions
-- (in paper order, each part after its question), mark_scheme_file, paper}. `paper` is what the editor offers pages
-- from: {page_count, spare_pages, answer_pages}, or null while the exam has no paper (teachers cannot read papers).
-- ---------------------------------------------------------------------------------------------
create function public.exam_structure_get(p_exam uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_e public.exams%rowtype;
  v_m public.exam_marking%rowtype;
  v_paper public.exam_papers%rowtype;
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
  select * into v_m from public.exam_marking m where m.exam_id = p_exam;
  select * into v_paper from public.exam_papers p where p.exam_id = p_exam and p.kind = 'paper' and p.superseded_at is null;

  return jsonb_build_object(
    'ok', true,
    'version', coalesce(v_m.structure_version, 0),
    'locked', v_m.opened_at is not null,
    'max_total', public.exam_structure_max_total(p_exam),
    'groups', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'label', g.label) order by g.position, g.label)
                        from public.question_groups g where g.exam_id = p_exam), '[]'::jsonb),
    'option_groups', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'label', o.label, 'choose', o.choose) order by o.label, o.id)
                               from public.exam_option_groups o where o.exam_id = p_exam), '[]'::jsonb),
    'questions', coalesce((
      with recursive t as (
        select q.id, array[q.position] as path from public.exam_questions q where q.exam_id = p_exam and q.parent_id is null
        union all
        select c.id, t.path || c.position from public.exam_questions c join t on c.parent_id = t.id
      )
      select jsonb_agg(jsonb_build_object(
          'id', q.id, 'parent_id', q.parent_id, 'label', q.label, 'position', q.position, 'max_mark', q.max_mark,
          'mark_step', q.mark_step, 'levels', q.levels, 'pages', to_jsonb(q.pages), 'areas', q.areas, 'group_id', q.group_id,
          'option_group_id', q.option_group_id, 'guidance', q.guidance, 'alternatives', q.alternatives,
          'points', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'label', p.label, 'marks', p.marks,
                                                                  'marks_to', p.marks_to, 'text', p.text) order by p.position)
                              from public.mark_scheme_points p where p.question_id = q.id), '[]'::jsonb))
        order by t.path)
      from t join public.exam_questions q on q.id = t.id), '[]'::jsonb),
    'mark_scheme_file', (select jsonb_build_object('id', f.id, 'storage_path', f.storage_path)
                         from public.exam_mark_scheme_files f where f.exam_id = p_exam and f.state = 'stored'
                         order by f.uploaded_at desc limit 1),
    'paper', case when v_paper.id is null then null else jsonb_build_object(
      'page_count', v_paper.page_count, 'spare_pages', v_e.spare_pages,
      'answer_pages', coalesce((select jsonb_agg(r.page order by r.page) from public.paper_page_roles r
                                where r.paper_id = v_paper.id and r.role = 'answer'), '[]'::jsonb)) end);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- exam_structure_save: replaces the structure (before marking opens) or changes it as Builder's call 11 allows (after).
-- Returns {ok, version, max_total}. Refusals: invalid_input, not_found, forbidden, reason_required, structure_locked,
-- conflict (a maximum below a mark already given).
-- ---------------------------------------------------------------------------------------------
create function public.exam_structure_save(p_exam uuid, p_structure jsonb, p_reason text default null)
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
  v_version int;
  v_opened timestamptz;
  v_id uuid;
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

  -- One save of an exam's structure at a time.
  perform pg_advisory_xact_lock(hashtextextended('exam_structure:' || p_exam::text, 0));
  select * into v_m from public.exam_marking m where m.exam_id = p_exam;
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
  -- group of its top-level question) are marked again by the same marker, and their scripts are being marked again.
  if v_locked and cardinality(v_added) > 0 then
    with recursive up as (
      select q.id, q.parent_id, q.group_id from public.exam_questions q where q.id = any (v_added)
      union all
      select p.id, p.parent_id, p.group_id from up join public.exam_questions p on p.id = up.parent_id
    )
    select coalesce(array_agg(u.id), '{}') into v_units
    from public.marking_units u
    where u.exam_id = p_exam
      and (u.group_id is null or u.group_id in (select up.group_id from up where up.parent_id is null));

    with reopened as (
      update public.markings m set status = 'in_progress', submitted_at = null
      where m.unit_id = any (v_units) and m.kind = 'live' and m.status = 'submitted'
      returning m.unit_id, m.marker_id
    ),
    units as (
      update public.marking_units u set state = 'taken' from reopened ro where u.id = ro.unit_id
      returning u.script_id
    ),
    assigned as (
      insert into public.marking_assignments (unit_id, kind, marker_id, how, assigned_by)
      select ro.unit_id, 'live', ro.marker_id, 'assigned', v_actor from reopened ro
    )
    update public.scripts s set state = 'marking' where s.id in (select script_id from units) and s.state = 'marked';
  end if;

  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, case when v_locked then 'exam_structure_changed_after_lock' else 'exam_structure_saved' end, 'exam', p_exam, v_reason);
  return jsonb_build_object('ok', true, 'version', v_version, 'max_total', public.exam_structure_max_total(p_exam));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- The mark scheme PDF. Once marking has opened only an admin may change it (teachers read only).
-- ---------------------------------------------------------------------------------------------

-- Internal: whether the caller may change an exam's mark scheme PDF now.
create function public.mark_scheme_file_can_change(p_user uuid, p_exam uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.structure_can_edit(p_user, p_exam)
     and (not exists (select 1 from public.exam_marking m where m.exam_id = p_exam and m.opened_at is not null)
          or exists (select 1 from public.profiles a where a.id = p_user and a.status = 'active' and a.role in ('owner', 'admin')))
$$;

-- mark_scheme_file_begin: a pending file row at <exam>/<file id>.pdf, the one path the storage policy lets the caller
-- fill. {ok, file_id, storage_path}.
create function public.mark_scheme_file_begin(p_exam uuid, p_bytes bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_id uuid := gen_random_uuid();
  v_path text;
begin
  if p_exam is null or p_bytes is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if not exists (select 1 from public.exams e where e.id = p_exam) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if not public.mark_scheme_file_can_change(v_actor, p_exam) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_bytes < 1 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if p_bytes > 20971520 then
    return jsonb_build_object('ok', false, 'code', 'file_too_large');
  end if;
  v_path := p_exam::text || '/' || v_id::text || '.pdf';
  insert into public.exam_mark_scheme_files (id, exam_id, storage_path, byte_size, uploaded_by)
  values (v_id, p_exam, v_path, p_bytes, v_actor);
  return jsonb_build_object('ok', true, 'file_id', v_id, 'storage_path', v_path);
end;
$$;

-- mark_scheme_file_stored: said by the uploader once the file is in storage with the declared size. It becomes the
-- exam's PDF; an earlier stored one is removed. A second call answers ok.
create function public.mark_scheme_file_stored(p_file uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_f public.exam_mark_scheme_files%rowtype;
  v_meta jsonb;
begin
  if p_file is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_f from public.exam_mark_scheme_files f where f.id = p_file for update;
  if not found or v_f.uploaded_by is distinct from v_actor or not public.mark_scheme_file_can_change(v_actor, v_f.exam_id) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if v_f.state = 'removed' then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  if v_f.state = 'stored' then
    return jsonb_build_object('ok', true, 'file_id', v_f.id, 'state', 'stored');
  end if;

  select o.metadata into v_meta from storage.objects o where o.bucket_id = 'mark-schemes' and o.name = v_f.storage_path;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if jsonb_typeof(v_meta -> 'size') is distinct from 'number' or (v_meta ->> 'size')::numeric <> v_f.byte_size
     or (v_meta ->> 'mimetype') is distinct from 'application/pdf' then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  update public.exam_mark_scheme_files set state = 'removed', removed_at = now()
  where exam_id = v_f.exam_id and state = 'stored' and id <> v_f.id;
  update public.exam_mark_scheme_files set state = 'stored', uploaded_at = now() where id = v_f.id;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'mark_scheme_file_added', 'mark_scheme_file', v_f.id);
  return jsonb_build_object('ok', true, 'file_id', v_f.id, 'state', 'stored');
end;
$$;

-- mark_scheme_file_remove: the exam's PDF is taken off, with a reason. The file itself is kept.
create function public.mark_scheme_file_remove(p_file uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_f public.exam_mark_scheme_files%rowtype;
  v_reason text := public.script_resolution_reason(p_reason);
begin
  if p_file is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_f from public.exam_mark_scheme_files f where f.id = p_file for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if not public.mark_scheme_file_can_change(v_actor, v_f.exam_id) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if v_f.state <> 'stored' then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  update public.exam_mark_scheme_files set state = 'removed', removed_at = now() where id = v_f.id;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'mark_scheme_file_removed', 'mark_scheme_file', v_f.id, v_reason);
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Storage policies on mark-schemes. The policies cannot read the file rows as the caller, so they ask these definer
-- functions. There is no update or delete policy: a file is never overwritten or deleted from the API.
-- ---------------------------------------------------------------------------------------------

-- The caller's own pending file is at this path.
create function public.mark_scheme_upload_allowed(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.exam_mark_scheme_files f
    where f.storage_path = p_name and f.state = 'pending' and f.uploaded_by = (select auth.uid()))
$$;

-- The stored PDF at this path, for an editor of the exam's structure or an approved marker of its subject.
create function public.mark_scheme_path_allowed(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.exam_mark_scheme_files f
    join public.exams e on e.id = f.exam_id
    where f.storage_path = p_name and f.state = 'stored'
      and (public.structure_can_edit((select auth.uid()), f.exam_id) or public.is_marker_for((select auth.uid()), e.subject_id)))
$$;

create policy mark_schemes_objects_insert on storage.objects for insert to authenticated
with check (bucket_id = 'mark-schemes' and public.mark_scheme_upload_allowed(name));

create policy mark_schemes_objects_select on storage.objects for select to authenticated
using (bucket_id = 'mark-schemes' and public.mark_scheme_path_allowed(name));

-- ---------------------------------------------------------------------------------------------
-- Privileges.
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.exam_structure_pages(uuid) from public, anon, authenticated;
revoke execute on function public.exam_structure_max_total(uuid) from public, anon, authenticated;
revoke execute on function public.exam_structure_valid(jsonb, int[]) from public, anon, authenticated;
revoke execute on function public.mark_scheme_file_can_change(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.exam_structure_get(uuid) from public, anon;
revoke execute on function public.exam_structure_save(uuid, jsonb, text) from public, anon;
revoke execute on function public.mark_scheme_file_begin(uuid, bigint) from public, anon;
revoke execute on function public.mark_scheme_file_stored(uuid) from public, anon;
revoke execute on function public.mark_scheme_file_remove(uuid, text) from public, anon;
revoke execute on function public.mark_scheme_upload_allowed(text) from public, anon;
revoke execute on function public.mark_scheme_path_allowed(text) from public, anon;
grant execute on function public.exam_structure_get(uuid) to authenticated;
grant execute on function public.exam_structure_save(uuid, jsonb, text) to authenticated;
grant execute on function public.mark_scheme_file_begin(uuid, bigint) to authenticated;
grant execute on function public.mark_scheme_file_stored(uuid) to authenticated;
grant execute on function public.mark_scheme_file_remove(uuid, text) to authenticated;
grant execute on function public.mark_scheme_upload_allowed(text) to authenticated;
grant execute on function public.mark_scheme_path_allowed(text) to authenticated;
