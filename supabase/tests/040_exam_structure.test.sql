begin;
create extension if not exists pgtap with schema extensions;
select plan(130);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Subject subj: teacher teaches it, corrector m1 is approved to mark it. Subject subj2: teacher2 and m2.
-- Exam e (tests.marking_exam: a current 3-page paper, every page an answer page, 2 spare pages, so pages 1 to 5)
-- gets its structure through exam_structure_save, is opened by hand (Ruling R1) and marked by question. Exam e2 of
-- the same subject stays open for changes and holds the mark scheme PDF tests.
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values
  ('admin', tests.create_user('admin', 'active')),
  ('teacher', tests.create_user('teacher', 'active')),
  ('teacher2', tests.create_user('teacher', 'active')),
  ('m1', tests.create_user('corrector', 'active')),
  ('m2', tests.create_user('corrector', 'active')),
  ('s1', tests.create_user('student', 'active'));
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create temp table res (name text primary key, j jsonb);
grant all on res to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
create function pg_temp.r(p text) returns jsonb language sql stable as $$ select j from res where name = p $$;
create function pg_temp.subj(p text) returns bigint language sql stable as $$
  select id from public.subjects where name = case p when 'subj' then 'ZZ Structure' else 'ZZ Structure other' end $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.r(text), pg_temp.subj(text) to public;

insert into public.subjects (name, kind) values ('ZZ Structure', 'school'), ('ZZ Structure other', 'school');
insert into public.teacher_subjects values (pg_temp.uid('teacher'), pg_temp.subj('subj')), (pg_temp.uid('teacher2'), pg_temp.subj('subj2'));
insert into public.marker_approvals (marker_id, subject_id, approved_by, approved_at)
values (pg_temp.uid('m1'), pg_temp.subj('subj'), pg_temp.uid('admin'), now()),
       (pg_temp.uid('m2'), pg_temp.subj('subj2'), pg_temp.uid('admin'), now());
insert into kv values ('e', tests.marking_exam(pg_temp.subj('subj')));
insert into kv values ('e2', tests.marking_exam(pg_temp.subj('subj')));

-- A question of a draft, with defaults for everything not given; a draft; the test structure as a draft:
-- 1 (3 marks, page 1, one marking point) and 2 with parts (a) (2 marks, page 2) and (b) (5 marks, page 3).
create function pg_temp.q(p_key text, p_parent text, p_label text, p_max numeric, p_more jsonb default '{}')
returns jsonb language sql immutable as $$
  select jsonb_build_object('id', null, 'key', p_key, 'parent_key', p_parent, 'label', p_label, 'max_mark', p_max,
    'mark_step', 1, 'levels', false, 'pages', '[1]'::jsonb, 'areas', '[]'::jsonb, 'group_key', null,
    'option_group_key', null, 'guidance', null, 'alternatives', null, 'points', '[]'::jsonb) || p_more $$;
create function pg_temp.st(p_questions jsonb, p_groups jsonb default '[]', p_options jsonb default '[]')
returns jsonb language sql immutable as $$
  select jsonb_build_object('groups', p_groups, 'option_groups', p_options, 'questions', p_questions) $$;
create function pg_temp.base(p_one jsonb default '{}') returns jsonb language sql immutable as $$
  select pg_temp.st(jsonb_build_array(
    pg_temp.q('q1', null, '1', 3, '{"points":[{"label":"M1","marks":1,"marks_to":null,"text":"speed = distance / time"}]}'::jsonb || p_one),
    pg_temp.q('q2', null, '2', null, '{"pages":[2,3]}'),
    pg_temp.q('q2a', 'q2', 'a', 2, '{"pages":[2]}'),
    pg_temp.q('q2b', 'q2', 'b', 5, '{"pages":[3]}'))) $$;
-- What exam_structure_get gives, as a draft to save again (the keys are the ids), as the editor makes it.
create function pg_temp.draft(g jsonb) returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'groups', coalesce((select jsonb_agg(jsonb_build_object('key', x ->> 'id', 'label', x -> 'label')) from jsonb_array_elements(g -> 'groups') x), '[]'),
    'option_groups', coalesce((select jsonb_agg(jsonb_build_object('key', x ->> 'id', 'label', x -> 'label', 'choose', x -> 'choose'))
                               from jsonb_array_elements(g -> 'option_groups') x), '[]'),
    'questions', coalesce((select jsonb_agg(jsonb_build_object('id', x -> 'id', 'key', x ->> 'id', 'parent_key', x -> 'parent_id',
        'label', x -> 'label', 'max_mark', x -> 'max_mark', 'mark_step', x -> 'mark_step', 'levels', x -> 'levels', 'pages', x -> 'pages',
        'areas', x -> 'areas', 'group_key', x -> 'group_id', 'option_group_key', x -> 'option_group_id', 'guidance', x -> 'guidance',
        'alternatives', x -> 'alternatives',
        'points', coalesce((select jsonb_agg(p - 'id') from jsonb_array_elements(x -> 'points') p), '[]')) order by o)
      from jsonb_array_elements(g -> 'questions') with ordinality t(x, o)), '[]')) $$;
-- A draft with one question changed, left out, or added.
create function pg_temp.edit(d jsonb, p_id uuid, p_patch jsonb) returns jsonb language sql immutable as $$
  select jsonb_set(d, '{questions}', (select jsonb_agg(case when x ->> 'id' = p_id::text then x || p_patch else x end order by o)
                                      from jsonb_array_elements(d -> 'questions') with ordinality t(x, o))) $$;
create function pg_temp.without(d jsonb, p_id uuid) returns jsonb language sql immutable as $$
  select jsonb_set(d, '{questions}', (select jsonb_agg(x order by o) from jsonb_array_elements(d -> 'questions') with ordinality t(x, o)
                                      where x ->> 'id' is distinct from p_id::text)) $$;
create function pg_temp.plus(d jsonb, p_q jsonb) returns jsonb language sql immutable as $$
  select jsonb_set(d, '{questions}', (d -> 'questions') || jsonb_build_array(p_q)) $$;
create function pg_temp.save(p_exam text, p_s jsonb, p_reason text default null) returns jsonb language sql as $$
  select public.exam_structure_save(pg_temp.k(p_exam), p_s, p_reason) $$;
create function pg_temp.code(p_exam text, p_s jsonb, p_reason text default null) returns text language sql as $$
  select coalesce(pg_temp.save(p_exam, p_s, p_reason) ->> 'code', 'ok') $$;
create function pg_temp.get(p_exam text) returns jsonb language sql as $$ select public.exam_structure_get(pg_temp.k(p_exam)) $$;
-- The id of an exam's question (a top-level label and a part label); the structure version; the exam's questions as
-- "label:max" in tree order (read as postgres).
create function pg_temp.qid(p_exam text, p_top text, p_part text default null) returns uuid language sql stable as $$
  select q.id from public.exam_questions t
  left join public.exam_questions q on (p_part is null and q.id = t.id) or (q.parent_id = t.id and q.label = p_part)
  where t.exam_id = pg_temp.k(p_exam) and t.parent_id is null and t.label = p_top and q.id is not null $$;
create function pg_temp.version(p_exam text) returns int language sql stable as $$
  select coalesce((select structure_version from public.exam_marking where exam_id = pg_temp.k(p_exam)), 0) $$;
create function pg_temp.shape(p_exam text) returns text language sql stable as $$
  with recursive t as (
    select q.id, q.label, q.max_mark, array[q.position] as path from public.exam_questions q
    where q.exam_id = pg_temp.k(p_exam) and q.parent_id is null
    union all
    select q.id, q.label, q.max_mark, t.path || q.position from public.exam_questions q join t on q.parent_id = t.id)
  select coalesce(string_agg(label || ':' || coalesce(trim_scale(max_mark)::text, '-'), ' ' order by path), '') from t $$;
-- The file a storage upload writes (the storage server sets its size and type).
create function pg_temp.put(p_path text, p_size bigint) returns void language sql as $$
  insert into storage.objects (bucket_id, name, metadata)
  values ('mark-schemes', p_path, jsonb_build_object('size', p_size, 'mimetype', 'application/pdf')) $$;
create function pg_temp.visible(p_path text) returns int language sql stable as $$
  select count(*)::int from storage.objects where bucket_id = 'mark-schemes' and name = p_path $$;
grant execute on function pg_temp.q(text, text, text, numeric, jsonb), pg_temp.st(jsonb, jsonb, jsonb), pg_temp.base(jsonb),
  pg_temp.draft(jsonb), pg_temp.edit(jsonb, uuid, jsonb), pg_temp.without(jsonb, uuid), pg_temp.plus(jsonb, jsonb),
  pg_temp.save(text, jsonb, text), pg_temp.code(text, jsonb, text), pg_temp.get(text), pg_temp.qid(text, text, text),
  pg_temp.version(text), pg_temp.shape(text), pg_temp.put(text, bigint), pg_temp.visible(text) to public;

-- ----- teacher_of_subject_saves_structure -----
select tests.as_user(pg_temp.uid('teacher'));
insert into res values ('save1', pg_temp.save('e', pg_temp.base()));
select is(jsonb_build_array(pg_temp.r('save1') -> 'ok', pg_temp.r('save1') -> 'version', (pg_temp.r('save1') ->> 'max_total')::numeric = 10),
  '[true, 1, true]'::jsonb, 'teacher_of_subject_saves_structure: saved, version 1, paper total 10');
insert into res values ('get1', pg_temp.get('e'));
select is(jsonb_build_array(pg_temp.r('get1') -> 'ok', pg_temp.r('get1') -> 'version', pg_temp.r('get1') -> 'locked',
    (pg_temp.r('get1') ->> 'max_total')::numeric = 10, pg_temp.r('get1') -> 'mark_scheme_file'),
  '[true, 1, false, true, null]'::jsonb, 'the teacher reads it back: version 1, not locked, total 10, no PDF');
select is((select array_agg(x ->> 'label' order by o) from jsonb_array_elements(pg_temp.r('get1') -> 'questions') with ordinality t(x, o)),
  array['1', '2', 'a', 'b'], 'questions come in paper order, each part after its question');
select is((select jsonb_agg(jsonb_build_array(x ->> 'label', x -> 'pages', (x ->> 'max_mark')::numeric, x ->> 'mark_step', x ->> 'parent_id' is not null) order by o)
           from jsonb_array_elements(pg_temp.r('get1') -> 'questions') with ordinality t(x, o)),
  '[["1", [1], 3, "1.0", false], ["2", [2, 3], null, "1.0", false], ["a", [2], 2, "1.0", true], ["b", [3], 5, "1.0", true]]'::jsonb,
  'with their pages, maxima, steps and parents');
select is((select jsonb_agg(p - 'id') from jsonb_array_elements(pg_temp.r('get1') -> 'questions' -> 0 -> 'points') p),
  '[{"label": "M1", "marks": 1.0, "marks_to": null, "text": "speed = distance / time"}]'::jsonb, 'and the marking point of question 1');
select is(pg_temp.r('get1') -> 'paper', '{"page_count": 3, "spare_pages": 2, "answer_pages": [1, 2, 3]}'::jsonb,
  'the paper the pages are chosen from: 3 pages, all answer pages, and 2 spare pages');
select tests.as_postgres();
select is(pg_temp.shape('e'), '1:3 2:- a:2 b:5', 'the rows are stored');
select is((select count(*)::int from public.mark_scheme_points p join public.exam_questions q on q.id = p.question_id where q.exam_id = pg_temp.k('e')),
  1, 'with one marking point');
select is(pg_temp.version('e'), 1, 'exam_marking was made with structure_version 1');

-- ----- teacher_of_other_subject_forbidden -----
select tests.as_user(pg_temp.uid('teacher2'));
select is(pg_temp.code('e', pg_temp.base()), 'forbidden', 'teacher_of_other_subject_forbidden: saving is refused');
select is(pg_temp.get('e') ->> 'code', 'forbidden', 'and so is reading');
select tests.as_postgres();
select is(pg_temp.version('e'), 1, 'nothing changed');

-- ----- corrector_forbidden -----
select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.code('e', pg_temp.base()), 'forbidden', 'corrector_forbidden: a marker of the subject cannot save');
select is(pg_temp.get('e') ->> 'code', 'forbidden', 'nor read the structure this way');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(pg_temp.code('e', pg_temp.base()), 'forbidden', 'a student cannot save');
select tests.as_postgres();
select is(public.exam_structure_get(gen_random_uuid()) ->> 'code', 'not_found', 'an unknown exam is not found');

-- ----- leaf_needs_a_maximum_and_parent_has_none -----
select tests.as_user(pg_temp.uid('teacher'));
select is(pg_temp.code('e', pg_temp.base('{"max_mark": null}')), 'invalid_input', 'leaf_needs_a_maximum_and_parent_has_none: a question without parts needs a maximum');
select is(pg_temp.code('e', pg_temp.st(jsonb_build_array(pg_temp.q('q2', null, '2', 7), pg_temp.q('q2a', 'q2', 'a', 7)))), 'invalid_input',
  'a question with parts has no maximum of its own');
select is(pg_temp.code('e', pg_temp.base('{"max_mark": 101}')), 'invalid_input', 'a maximum is at most 100');
select is(pg_temp.code('e', pg_temp.st('[]')), 'invalid_input', 'a structure has at least one question');
select is(pg_temp.code('e', pg_temp.st(jsonb_build_array(pg_temp.q('q1', null, '1', 1), pg_temp.q('q1b', null, '1', 1)))), 'invalid_input',
  'labels are unique among siblings');
select is(pg_temp.code('e', pg_temp.st(jsonb_build_array(pg_temp.q('a', null, '1', null), pg_temp.q('b', 'a', 'a', null),
    pg_temp.q('c', 'b', 'i', null), pg_temp.q('d', 'c', 'x', 1)))), 'invalid_input', 'at most 3 levels');
select is(pg_temp.code('e', pg_temp.st(jsonb_build_array(pg_temp.q('a', 'b', '1', 1), pg_temp.q('b', 'a', '2', 1)))), 'invalid_input',
  'a question cannot be its own ancestor');
select is(pg_temp.code('e', pg_temp.st((select jsonb_agg(pg_temp.q('k' || i, null, i::text, 1)) from generate_series(1, 201) i))), 'invalid_input',
  'at most 200 questions to mark');
select is(pg_temp.code('e', pg_temp.st((select jsonb_agg(pg_temp.q('k' || i, null, i::text, 1)) from generate_series(1, 200) i))), 'ok',
  '200 are allowed');
select is(pg_temp.code('e', pg_temp.base('{"points":[{"label":"M1","marks":4,"marks_to":null,"text":"Too many"}]}')), 'invalid_input',
  'a marking point is worth no more than its question');
select is(pg_temp.code('e', pg_temp.base('{"points":[{"label":"L2","marks":2,"marks_to":4,"text":"Band too high"}]}')), 'invalid_input',
  'nor is the top of a level band');
select is(pg_temp.code('e', pg_temp.base((select jsonb_build_object('points', jsonb_agg(jsonb_build_object('label', null, 'marks', 1, 'marks_to', null, 'text', 'Point ' || i))) from generate_series(1, 31) i))),
  'invalid_input', 'at most 30 marking points per question');
select is(pg_temp.code('e', pg_temp.base('{"label": "   "}')), 'invalid_input', 'a label is needed');
select is(pg_temp.code('e', jsonb_build_object('questions', 'nope')), 'invalid_input', 'a structure must have a list of questions');

-- ----- maximum_must_fit_the_step -----
select is(pg_temp.code('e', pg_temp.base('{"max_mark": 2.5}')), 'invalid_input', 'maximum_must_fit_the_step: 2.5 is refused in whole marks');
select is(pg_temp.code('e', pg_temp.base('{"max_mark": 2.5, "mark_step": 0.5}')), 'ok', 'and accepted in half marks');
select tests.as_postgres();
select is(pg_temp.shape('e'), '1:2.5 2:- a:2 b:5', 'question 1 is out of 2.5');
select is((select mark_step from public.exam_questions where id = pg_temp.qid('e', '1')), 0.5::numeric, 'in half marks');

-- ----- pages_must_be_answer_or_spare_pages -----
update public.paper_page_roles set role = 'cover'
where paper_id = (select id from public.exam_papers where exam_id = pg_temp.k('e') and kind = 'paper' and superseded_at is null) and page = 1;
select tests.as_user(pg_temp.uid('teacher'));
select is(pg_temp.code('e', pg_temp.base()), 'invalid_input', 'pages_must_be_answer_or_spare_pages: a cover page is refused');
select is(pg_temp.get('e') -> 'paper' -> 'answer_pages', '[2, 3]'::jsonb, 'the cover page is not offered');
select is(pg_temp.code('e', pg_temp.base('{"pages": [4, 5]}')), 'ok', 'the spare pages after the paper are allowed');
select is(pg_temp.code('e', pg_temp.base('{"pages": [6]}')), 'invalid_input', 'a page beyond the spare pages is refused');
select is(pg_temp.code('e', pg_temp.base('{"pages": [2, 2]}')), 'invalid_input', 'a page given twice is refused');
select is(pg_temp.code('e', pg_temp.base('{"pages": [2], "areas": [{"page": 2, "x": 0.1, "y": 0.2, "w": 0.5, "h": 0.3}]}')), 'ok',
  'an area inside an answer page is allowed');
select is(pg_temp.code('e', pg_temp.base('{"pages": [2], "areas": [{"page": 2, "x": 0.6, "y": 0.2, "w": 0.5, "h": 0.3}]}')), 'invalid_input',
  'an area that runs off the page is refused');
select is(pg_temp.code('e', pg_temp.base('{"pages": [2], "areas": [{"page": 1, "x": 0.1, "y": 0.2, "w": 0.5, "h": 0.3}]}')), 'invalid_input',
  'an area on the cover page is refused');
select is(pg_temp.code('e', pg_temp.base(jsonb_build_object('pages', '[2]'::jsonb, 'areas',
    (select jsonb_agg(jsonb_build_object('page', 2, 'x', 0, 'y', i / 10.0, 'w', 1, 'h', 0.05)) from generate_series(1, 6) i)))),
  'invalid_input', 'at most 5 areas per question');
select tests.as_postgres();
update public.paper_page_roles set role = 'answer'
where paper_id = (select id from public.exam_papers where exam_id = pg_temp.k('e') and kind = 'paper' and superseded_at is null) and page = 1;

-- ----- option_group_counts_best_n -----
-- Answer 2 of questions 5, 6 and 7, each out of 10 (7 in parts of 4 and 6).
create function pg_temp.options(p_choose int, p_seven_b numeric default 6, p_on_part boolean default false) returns jsonb language sql immutable as $$
  select pg_temp.st(jsonb_build_array(
      pg_temp.q('q5', null, '5', 10, '{"option_group_key": "o"}'),
      pg_temp.q('q6', null, '6', 10, '{"option_group_key": "o"}'),
      pg_temp.q('q7', null, '7', null, case when p_on_part then '{}' else '{"option_group_key": "o"}' end::jsonb),
      pg_temp.q('q7a', 'q7', 'a', 4, case when p_on_part then '{"option_group_key": "o"}' else '{}' end::jsonb),
      pg_temp.q('q7b', 'q7', 'b', p_seven_b)),
    '[]', jsonb_build_array(jsonb_build_object('key', 'o', 'label', 'Section B', 'choose', p_choose))) $$;
grant execute on function pg_temp.options(int, numeric, boolean) to public;
select tests.as_user(pg_temp.uid('teacher'));
insert into res values ('opt', pg_temp.save('e', pg_temp.options(2)));
select is((pg_temp.r('opt') ->> 'max_total')::numeric, 20::numeric, 'option_group_counts_best_n: answer 2 of three 10-mark questions counts 20');
select tests.as_postgres();
select is(public.exam_structure_max_total(pg_temp.k('e')), 20::numeric, 'exam_structure_max_total says the same');
select tests.as_user(pg_temp.uid('teacher'));
insert into res values ('get_opt', pg_temp.get('e'));
select is((select jsonb_agg(x - 'id') from jsonb_array_elements(pg_temp.r('get_opt') -> 'option_groups') x),
  '[{"label": "Section B", "choose": 2}]'::jsonb, 'the optional questions are read back');
select is((select count(*)::int from jsonb_array_elements(pg_temp.r('get_opt') -> 'questions') x
           where x ->> 'option_group_id' = pg_temp.r('get_opt') -> 'option_groups' -> 0 ->> 'id'), 3, 'with their 3 members');
select is(pg_temp.code('e', pg_temp.options(2, 5)), 'invalid_input', 'optional questions must have equal totals');
select is(pg_temp.code('e', pg_temp.options(3)), 'invalid_input', 'choose is below the number of questions');
select is(pg_temp.code('e', pg_temp.options(1, 6, true)), 'invalid_input', 'only questions, not parts, can be optional');
select is(pg_temp.code('e', pg_temp.st(jsonb_build_array(pg_temp.q('q5', null, '5', 10, '{"option_group_key": "o"}')), '[]',
    '[{"key": "o", "label": "Section B", "choose": 1}]')), 'invalid_input', 'optional questions need at least 2 questions');
select is(pg_temp.code('e', pg_temp.st(jsonb_build_array(pg_temp.q('q1', null, '1', null), pg_temp.q('q1a', 'q1', 'a', 3, '{"group_key": "g"}')),
    '[{"key": "g", "label": "Group 1"}]')), 'invalid_input', 'only questions, not parts, go in a question group');

-- ----- save_keeps_ids_given_and_bumps_version -----
select is(pg_temp.code('e', pg_temp.base()), 'ok', 'save_keeps_ids_given_and_bumps_version: the test structure again');
select tests.as_postgres();
insert into kv values ('v_before', null);
insert into kv select 'k1', pg_temp.qid('e', '1');
insert into kv select 'k2', pg_temp.qid('e', '2');
insert into kv select 'k2a', pg_temp.qid('e', '2', 'a');
insert into kv select 'k2b', pg_temp.qid('e', '2', 'b');
insert into res values ('v_before', to_jsonb(pg_temp.version('e')));
select tests.as_user(pg_temp.uid('teacher'));
insert into res values ('keep', pg_temp.save('e',
  pg_temp.plus(pg_temp.without(pg_temp.edit(pg_temp.draft(pg_temp.get('e')), pg_temp.k('k1'), '{"guidance": "Accept 3 m/s."}'), pg_temp.k('k2b')),
    pg_temp.q('new3', null, '3', 4, '{"pages": [3]}'))));
select is((pg_temp.r('keep') ->> 'version')::int, (pg_temp.r('v_before') #>> '{}')::int + 1, 'each save adds 1 to the version');
select tests.as_postgres();
select is(array[pg_temp.qid('e', '1'), pg_temp.qid('e', '2'), pg_temp.qid('e', '2', 'a')], array[pg_temp.k('k1'), pg_temp.k('k2'), pg_temp.k('k2a')],
  'the questions sent with their id keep it');
select is(pg_temp.shape('e'), '1:3 2:- a:2 3:4', 'the one left out is deleted and the new one added');
select is((select guidance from public.exam_questions where id = pg_temp.k('k1')), 'Accept 3 m/s.', 'and the change is saved');
select is((select count(*)::int from public.exam_questions where id = pg_temp.k('k2b')), 0, 'the deleted question is gone');
select is((select count(*)::int from public.mark_scheme_points where question_id = pg_temp.k('k1')), 1, 'its marking point came back with the draft');
select tests.as_user(pg_temp.uid('teacher'));
select is(pg_temp.code('e', pg_temp.edit(pg_temp.draft(pg_temp.get('e')), pg_temp.k('k1'), jsonb_build_object('id', gen_random_uuid()))),
  'invalid_input', 'an id that is not a question of this exam is refused');

-- ---------------------------------------------------------------------------------------------
-- Marking opens. The locked structure: groups G1 (1, 3, 4) and G2 (2 with parts (a) 2 and (b) 5); answer 1 of 3 and 4
-- (4 marks each). Two verified scripts x1 and x2, one unit per group each. On x1 both units are submitted by m1 (2(a) 2,
-- 2(b) 4, 1 given 3) and x1 is marked; on x2, m1 holds the G1 unit (in progress) and the G2 unit is open.
-- ---------------------------------------------------------------------------------------------
create function pg_temp.locked_structure() returns jsonb language sql immutable as $$
  select pg_temp.st(jsonb_build_array(
      pg_temp.q('q1', null, '1', 3, '{"group_key": "g1"}'),
      pg_temp.q('q2', null, '2', null, '{"group_key": "g2", "pages": [2, 3]}'),
      pg_temp.q('q2a', 'q2', 'a', 2, '{"pages": [2]}'),
      pg_temp.q('q2b', 'q2', 'b', 5, '{"pages": [3]}'),
      pg_temp.q('q3', null, '3', 4, '{"group_key": "g1", "option_group_key": "o"}'),
      pg_temp.q('q4', null, '4', 4, '{"group_key": "g1", "option_group_key": "o"}')),
    '[{"key": "g1", "label": "G1"}, {"key": "g2", "label": "G2"}]',
    '[{"key": "o", "label": "Answer one", "choose": 1}]') $$;
grant execute on function pg_temp.locked_structure() to public;
select is(pg_temp.code('e', pg_temp.locked_structure()), 'ok', 'the structure is saved before marking opens');
select tests.as_postgres();
select is(public.exam_structure_max_total(pg_temp.k('e')), 14::numeric, 'its total counts one of the optional questions: 3 + 7 + 4');
update public.exam_marking set opened_at = now(), opened_by = pg_temp.uid('admin'), mode = 'by_question' where exam_id = pg_temp.k('e');
insert into kv select 'g1', id from public.question_groups where exam_id = pg_temp.k('e') and label = 'G1';
insert into kv select 'g2', id from public.question_groups where exam_id = pg_temp.k('e') and label = 'G2';
insert into kv select 'L1', pg_temp.qid('e', '1');
insert into kv select 'L2', pg_temp.qid('e', '2');
insert into kv select 'L3', pg_temp.qid('e', '3');
insert into kv select 'og', id from public.exam_option_groups where exam_id = pg_temp.k('e');
insert into kv select 'L2a', pg_temp.qid('e', '2', 'a');
insert into kv select 'L2b', pg_temp.qid('e', '2', 'b');
insert into kv select 'L4', pg_temp.qid('e', '4');
insert into kv values ('x1', tests.verified_script(pg_temp.k('e')));
insert into kv values ('x2', tests.verified_script(pg_temp.k('e')));
update public.scripts set state = 'marked' where id = pg_temp.k('x1');
update public.scripts set state = 'marking' where id = pg_temp.k('x2');
with i as (insert into public.marking_units (script_id, exam_id, group_id, state)
           values (pg_temp.k('x1'), pg_temp.k('e'), pg_temp.k('g1'), 'submitted') returning id) insert into kv select 'u11', id from i;
with i as (insert into public.marking_units (script_id, exam_id, group_id, state)
           values (pg_temp.k('x1'), pg_temp.k('e'), pg_temp.k('g2'), 'submitted') returning id) insert into kv select 'u12', id from i;
with i as (insert into public.marking_units (script_id, exam_id, group_id, state)
           values (pg_temp.k('x2'), pg_temp.k('e'), pg_temp.k('g1'), 'taken') returning id) insert into kv select 'u21', id from i;
with i as (insert into public.marking_units (script_id, exam_id, group_id, state)
           values (pg_temp.k('x2'), pg_temp.k('e'), pg_temp.k('g2'), 'open') returning id) insert into kv select 'u22', id from i;
with i as (insert into public.markings (unit_id, marker_id, status, rev, structure_version, total, submitted_at)
           values (pg_temp.k('u11'), pg_temp.uid('m1'), 'submitted', 3, pg_temp.version('e'), 3, now()) returning id) insert into kv select 'mk11', id from i;
with i as (insert into public.markings (unit_id, marker_id, status, rev, structure_version, total, submitted_at)
           values (pg_temp.k('u12'), pg_temp.uid('m1'), 'submitted', 3, pg_temp.version('e'), 6, now()) returning id) insert into kv select 'mk12', id from i;
with i as (insert into public.markings (unit_id, marker_id, status, rev)
           values (pg_temp.k('u21'), pg_temp.uid('m1'), 'in_progress', 1) returning id) insert into kv select 'mk21', id from i;
insert into public.marking_assignments (unit_id, marker_id, how, hold_until, created_at, ended_at, end_reason)
values (pg_temp.k('u11'), pg_temp.uid('m1'), 'next', now() + interval '1 hour', now() - interval '1 hour', now(), 'submitted'),
       (pg_temp.k('u12'), pg_temp.uid('m1'), 'next', now() + interval '1 hour', now() - interval '1 hour', now(), 'submitted'),
       (pg_temp.k('u21'), pg_temp.uid('m1'), 'next', now() + interval '1 hour', now(), null, null);
insert into public.question_marks (marking_id, question_id, mark)
values (pg_temp.k('mk11'), pg_temp.k('L1'), 3), (pg_temp.k('mk12'), pg_temp.k('L2a'), 2), (pg_temp.k('mk12'), pg_temp.k('L2b'), 4);
insert into res values ('v_locked', to_jsonb(pg_temp.version('e')));
create function pg_temp.locked_draft() returns jsonb language sql as $$ select pg_temp.draft(pg_temp.get('e')) $$;
grant execute on function pg_temp.locked_draft() to public;

-- ----- locked_refuses_removal_and_regrouping -----
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code('e', pg_temp.without(pg_temp.locked_draft(), pg_temp.k('L2b')), 'Part (b) was a mistake'), 'structure_locked',
  'locked_refuses_removal_and_regrouping: a question cannot be removed');
select is(pg_temp.code('e', pg_temp.edit(pg_temp.locked_draft(), pg_temp.k('L1'), jsonb_build_object('group_key', pg_temp.k('g2'))), 'Move question 1'),
  'structure_locked', 'a question cannot change group');
select is(pg_temp.code('e', jsonb_set(pg_temp.locked_draft(), '{groups,1,label}', '"Group two"'), 'Rename the group'), 'structure_locked',
  'the groups cannot change');
select is(pg_temp.code('e', jsonb_set(pg_temp.edit(pg_temp.edit(pg_temp.locked_draft(), pg_temp.k('L3'), '{"option_group_key": null}'),
    pg_temp.k('L4'), '{"option_group_key": null}'), '{option_groups}', '[]'), 'Both questions count'), 'structure_locked',
  'the optional questions cannot change');
select is(pg_temp.code('e', pg_temp.plus(pg_temp.edit(pg_temp.locked_draft(), pg_temp.k('L1'), '{"max_mark": null}'),
    pg_temp.q('new1a', pg_temp.k('L1')::text, 'a', 3)), 'Split question 1'), 'structure_locked', 'a question without parts cannot get parts');
select is(pg_temp.code('e', pg_temp.edit(pg_temp.locked_draft(), pg_temp.k('L1'), '{"mark_step": 0.5}'), 'Half marks'), 'structure_locked',
  'half marks cannot be switched on');
select is(pg_temp.code('e', pg_temp.edit(pg_temp.locked_draft(), pg_temp.k('L2b'), jsonb_build_object('parent_key', null)), 'Make 2(b) a question'),
  'structure_locked', 'a part cannot move');
select is(pg_temp.code('e', pg_temp.plus(pg_temp.locked_draft(), pg_temp.q('new5', null, '5', 2)), 'Add question 5'), 'structure_locked',
  'marked by question: a question added after opening needs a group');
select is(pg_temp.code('e', pg_temp.plus(pg_temp.locked_draft(), pg_temp.q('new5', null, '5', 4, jsonb_build_object('group_key', pg_temp.k('g1'), 'option_group_key', pg_temp.k('og')))),
  'Another choice'), 'structure_locked', 'nor can it join the optional questions');
select tests.as_postgres();
select is(array[pg_temp.version('e')::text, pg_temp.shape('e')], array[pg_temp.r('v_locked') #>> '{}', '1:3 2:- a:2 b:5 3:4 4:4'],
  'nothing changed');

-- ----- locked_change_needs_admin_and_reason -----
select tests.as_user(pg_temp.uid('teacher'));
select is(pg_temp.get('e') -> 'locked', 'true'::jsonb, 'locked_change_needs_admin_and_reason: the teacher reads it as locked');
select is(pg_temp.code('e', pg_temp.edit(pg_temp.locked_draft(), pg_temp.k('L1'), '{"guidance": "Units needed."}'), 'Clearer guidance'), 'forbidden',
  'a teacher cannot change it once marking has opened');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code('e', pg_temp.edit(pg_temp.locked_draft(), pg_temp.k('L1'), '{"guidance": "Units needed."}')), 'reason_required',
  'an admin needs a reason');
select is(pg_temp.code('e', pg_temp.edit(pg_temp.locked_draft(), pg_temp.k('L1'), '{"guidance": "Units needed."}'), ' ab '), 'reason_required',
  'of 3 characters or more');
insert into res values ('wording', pg_temp.save('e',
  pg_temp.edit(pg_temp.edit(pg_temp.locked_draft(), pg_temp.k('L1'),
    '{"guidance": "Units needed.", "alternatives": "3 metres per second", "points": [{"label": "B1", "marks": 3, "marks_to": null, "text": "3 m/s"}]}'),
    pg_temp.k('L2a'), '{"pages": [2, 3]}'), 'Clearer guidance for question 1'));
select is(jsonb_build_array(pg_temp.r('wording') -> 'ok', (pg_temp.r('wording') ->> 'version')::int = (pg_temp.r('v_locked') #>> '{}')::int + 1),
  '[true, true]'::jsonb, 'with a reason: wording, points, guidance and pages change');
select tests.as_postgres();
select is((select guidance || ' | ' || alternatives || ' | ' || array_to_string(pages, ',') from public.exam_questions where id = pg_temp.k('L1')),
  'Units needed. | 3 metres per second | 1', 'the guidance and alternatives are saved');
select is((select string_agg(label || ' ' || trim_scale(marks) || ' ' || text, '; ') from public.mark_scheme_points where question_id = pg_temp.k('L1')),
  'B1 3 3 m/s', 'the marking points are replaced');
select is((select pages from public.exam_questions where id = pg_temp.k('L2a')), array[2, 3], 'the pages are saved');
select is((select string_agg(status, ',' order by id) from public.markings where id in (pg_temp.k('mk11'), pg_temp.k('mk12'))), 'submitted,submitted',
  'submitted pieces stay submitted');

-- ----- maximum_cannot_drop_below_a_given_mark -----
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code('e', pg_temp.edit(pg_temp.locked_draft(), pg_temp.k('L2b'), '{"max_mark": 3}'), 'Out of 3'), 'conflict',
  'maximum_cannot_drop_below_a_given_mark: 2(b) cannot go below the 4 already given');
select is(pg_temp.code('e', pg_temp.edit(pg_temp.locked_draft(), pg_temp.k('L2b'), '{"max_mark": 4}'), 'Out of 4'), 'ok',
  'it can go down to that mark');
select is(pg_temp.code('e', pg_temp.edit(pg_temp.locked_draft(), pg_temp.k('L4'), '{"max_mark": 5}'), 'Out of 5'), 'invalid_input',
  'optional questions keep equal totals');
select tests.as_postgres();
select is(pg_temp.shape('e'), '1:3 2:- a:2 b:4 3:4 4:4', '2(b) is now out of 4');

-- ----- added_question_reopens_submitted_pieces -----
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('added', pg_temp.save('e', pg_temp.plus(pg_temp.locked_draft(), pg_temp.q('new2c', pg_temp.k('L2')::text, 'c', 1, '{"pages": [3]}')),
  'Part (c) was left out'));
select is(pg_temp.r('added') -> 'ok', 'true'::jsonb, 'added_question_reopens_submitted_pieces: an admin adds part 2(c)');
select tests.as_postgres();
select is(pg_temp.shape('e'), '1:3 2:- a:2 b:4 c:1 3:4 4:4', 'the part is added');
select is((select status || ' ' || (submitted_at is null) from public.markings where id = pg_temp.k('mk12')), 'in_progress true',
  'the submitted marking of the G2 piece is open again');
select is((select state from public.marking_units where id = pg_temp.k('u12')), 'taken', 'its piece is taken again');
select is((select jsonb_agg(jsonb_build_array(a.marker_id = pg_temp.uid('m1'), a.how, a.hold_until, a.assigned_by = pg_temp.uid('admin')))
           from public.marking_assignments a where a.unit_id = pg_temp.k('u12') and a.ended_at is null),
  '[[true, "assigned", null, true]]'::jsonb, 'assigned to the same marker, with no time limit');
select is((select count(*)::int from public.markings where unit_id = pg_temp.k('u12')), 1, 'the same marking row, not a second one');
select is((select count(*)::int from public.question_marks where marking_id = pg_temp.k('mk12')), 2, 'and its marks are kept');
select is((select state::text from public.scripts where id = pg_temp.k('x1')), 'marking', 'the marked script is being marked again');
select is((select m.status || ' ' || u.state from public.markings m join public.marking_units u on u.id = m.unit_id where m.id = pg_temp.k('mk11')),
  'submitted submitted', 'the G1 piece does not have the new part and stays submitted');
select is((select string_agg(u.state || ':' || (select count(*) from public.marking_assignments a where a.unit_id = u.id and a.ended_at is null), ',' order by u.group_id = pg_temp.k('g2'))
           from public.marking_units u where u.script_id = pg_temp.k('x2')), 'taken:1,open:0', 'the other script''s pieces are untouched');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code('e', pg_temp.plus(pg_temp.locked_draft(), pg_temp.q('new5', null, '5', 2, jsonb_build_object('group_key', pg_temp.k('g1')))),
  'Question 5 was left out'), 'ok', 'a new question in G1');
select tests.as_postgres();
select is((select m.status || ' ' || u.state from public.markings m join public.marking_units u on u.id = m.unit_id where m.id = pg_temp.k('mk11')),
  'in_progress taken', 'reopens the submitted G1 piece');
select is((select count(*)::int from public.marking_assignments where unit_id = pg_temp.k('u21') and ended_at is null), 1,
  'and the piece being marked keeps its one holder');

-- ----- mark_scheme_file_only_at_its_pending_path -----
select tests.as_user(pg_temp.uid('teacher'));
insert into res values ('f1', public.mark_scheme_file_begin(pg_temp.k('e2'), 1000));
insert into kv select 'f1', (pg_temp.r('f1') ->> 'file_id')::uuid;
select is(pg_temp.r('f1') ->> 'storage_path', pg_temp.k('e2')::text || '/' || pg_temp.k('f1')::text || '.pdf',
  'mark_scheme_file_only_at_its_pending_path: a teacher of the subject begins an upload at <exam>/<file>.pdf');
select is(public.mark_scheme_file_begin(pg_temp.k('e2'), 0) ->> 'code', 'invalid_input', 'an empty file is refused');
select is(public.mark_scheme_file_begin(pg_temp.k('e2'), 20971521) ->> 'code', 'file_too_large', 'a file over 20 MB is refused');
select is(public.mark_scheme_file_stored(pg_temp.k('f1')) ->> 'code', 'not_found', 'stored before the file arrived: not found');
select throws_ok(format($q$insert into storage.objects (bucket_id, name) values ('mark-schemes', %L)$q$, pg_temp.k('e2')::text || '/' || gen_random_uuid()::text || '.pdf'),
  '42501', null, 'a file at any other path is refused');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('teacher2'));
select throws_ok(format($q$insert into storage.objects (bucket_id, name) values ('mark-schemes', %L)$q$, pg_temp.r('f1') ->> 'storage_path'),
  '42501', null, 'another user cannot fill the pending path');
select is(public.mark_scheme_file_begin(pg_temp.k('e2'), 1000) ->> 'code', 'forbidden', 'a teacher of another subject cannot begin');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m1'));
select is(public.mark_scheme_file_begin(pg_temp.k('e2'), 1000) ->> 'code', 'forbidden', 'nor can a marker');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('teacher'));
select lives_ok(format($q$select pg_temp.put(%L, 999)$q$, pg_temp.r('f1') ->> 'storage_path'), 'the uploader fills the pending path');
select is(public.mark_scheme_file_stored(pg_temp.k('f1')) ->> 'code', 'invalid_input', 'a file of another size than declared is refused');
select tests.as_postgres();
update storage.objects set metadata = jsonb_build_object('size', 1000, 'mimetype', 'application/pdf') where bucket_id = 'mark-schemes' and name = pg_temp.r('f1') ->> 'storage_path';
select tests.as_user(pg_temp.uid('teacher2'));
select is(public.mark_scheme_file_stored(pg_temp.k('f1')) ->> 'code', 'forbidden', 'only the uploader says it is stored');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('teacher'));
select is(public.mark_scheme_file_stored(pg_temp.k('f1')) ->> 'ok', 'true', 'the declared size: stored');
select is(pg_temp.get('e2') -> 'mark_scheme_file', jsonb_build_object('id', pg_temp.k('f1'), 'storage_path', pg_temp.r('f1') ->> 'storage_path'),
  'the structure names the PDF');
select throws_ok(format($q$select pg_temp.put(%L, 1000)$q$, pg_temp.r('f1') ->> 'storage_path'), '42501', null,
  'a stored path cannot be written again');
select is(public.mark_scheme_file_begin(pg_temp.k('e'), 1000) ->> 'code', 'forbidden', 'once marking has opened, a teacher cannot add a PDF');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(public.mark_scheme_file_begin(pg_temp.k('e'), 1000) ->> 'ok', 'true', 'an admin can');

-- ----- marker_of_subject_reads_stored_file_and_other_marker_cannot -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('teacher'));
insert into res values ('f2', public.mark_scheme_file_begin(pg_temp.k('e2'), 2000));
insert into kv select 'f2', (pg_temp.r('f2') ->> 'file_id')::uuid;
select pg_temp.put(pg_temp.r('f2') ->> 'storage_path', 2000);
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m1'));
select is(array[pg_temp.visible(pg_temp.r('f1') ->> 'storage_path'), pg_temp.visible(pg_temp.r('f2') ->> 'storage_path')], array[1, 0],
  'marker_of_subject_reads_stored_file_and_other_marker_cannot: a marker of the subject reads the stored PDF, not one still uploading');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m2'));
select is(pg_temp.visible(pg_temp.r('f1') ->> 'storage_path'), 0, 'a marker of another subject cannot');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('teacher2'));
select is(pg_temp.visible(pg_temp.r('f1') ->> 'storage_path'), 0, 'nor a teacher of another subject');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('teacher'));
select is(public.mark_scheme_file_stored(pg_temp.k('f2')) ->> 'ok', 'true', 'a second PDF is stored');
select tests.as_postgres();
select is((select string_agg(state, ',' order by byte_size) from public.exam_mark_scheme_files where id in (pg_temp.k('f1'), pg_temp.k('f2'))),
  'removed,stored', 'and replaces the first');
select tests.as_user(pg_temp.uid('m1'));
select is(array[pg_temp.visible(pg_temp.r('f1') ->> 'storage_path'), pg_temp.visible(pg_temp.r('f2') ->> 'storage_path')], array[0, 1],
  'the marker now reads only the new one');

-- ----- student_cannot_read_mark_scheme -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is((select count(*)::int from storage.objects where bucket_id = 'mark-schemes'), 0, 'student_cannot_read_mark_scheme: a student reads no mark scheme file');
select is(public.mark_scheme_file_remove(pg_temp.k('f2'), 'Not mine') ->> 'code', 'forbidden', 'nor removes one');

-- The teacher removes the PDF, with a reason.
select tests.as_postgres(); select tests.as_user(pg_temp.uid('teacher'));
select is(public.mark_scheme_file_remove(pg_temp.k('f2'), null) ->> 'code', 'reason_required', 'removing the PDF needs a reason');
select is(public.mark_scheme_file_remove(pg_temp.k('f2'), 'Wrong file') ->> 'ok', 'true', 'with one it is removed');
select is(pg_temp.get('e2') -> 'mark_scheme_file', 'null'::jsonb, 'the structure has no PDF now');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.visible(pg_temp.r('f2') ->> 'storage_path'), 0, 'and the marker cannot read it');

-- ----- structure_save_writes_audit -----
select tests.as_postgres();
select is((select count(*)::int from public.audit_log where target_id = pg_temp.k('e') and action in ('exam_structure_saved', 'exam_structure_changed_after_lock')),
  pg_temp.version('e'), 'structure_save_writes_audit: one row for every save, none for a refused one');
select is((select count(*)::int from public.audit_log where target_id = pg_temp.k('e') and action = 'exam_structure_saved'
             and actor_id = pg_temp.uid('teacher') and reason is null),
  (pg_temp.r('v_locked') #>> '{}')::int, 'the saves before marking opened are exam_structure_saved, by the teacher');
select is((select string_agg(reason, ' / ' order by id) from public.audit_log where target_id = pg_temp.k('e') and action = 'exam_structure_changed_after_lock'
             and actor_id = pg_temp.uid('admin')),
  'Clearer guidance for question 1 / Out of 4 / Part (c) was left out / Question 5 was left out', 'the changes after it are recorded with their reasons');
select is((select string_agg(action || ':' || coalesce(reason, '-'), ' ' order by id) from public.audit_log
           where target_type = 'mark_scheme_file' and target_id in (pg_temp.k('f1'), pg_temp.k('f2'))),
  'mark_scheme_file_added:- mark_scheme_file_added:- mark_scheme_file_removed:Wrong file', 'the PDFs added and removed are recorded');

select * from finish();
rollback;
