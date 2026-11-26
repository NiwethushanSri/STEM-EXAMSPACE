begin;
create extension if not exists pgtap with schema extensions;
select plan(102);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Subject 'ZZ Check': markers m1 to m4 and the lead marker (tests.marker); corr is a corrector never
-- approved; olead leads another subject. Exam t holds one script (t1) whose piece is out of 60 (questions 1, 2 and 3 of
-- 5, 20 and 35 marks, half marks allowed) for the comparison itself. Exam e (the test structure: 1 of 3 marks, 2(a)
-- of 2 and 2(b) of 5, so every tolerance is the floor of one mark) is opened with double marking on, a 10% sample and
-- a 10% tolerance; its scripts a1, a2, ... are made as each test needs them, and a piece's stored draw is set before
-- its first marking is submitted. Exam d has the checks off. Exam q is marked by question (groups A and B), exam bq
-- by question with optional questions. Subjects 'ZZ Check Small' (s1, s2, lead sl) and 'ZZ Check Off' (o1, o2) have
-- their own exams. A piece is kept as 'u:<script>' ('u:<script>:<group>' by question), a page as
-- 'p:<script>:<copy page>', a first marking as 'f:<piece>' and a second as 's:<piece>'.
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create temp table res (name text primary key, j jsonb);
grant all on res to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
create function pg_temp.u(p text) returns uuid language sql stable as $$ select id from kv where name = 'u:' || p $$;
create function pg_temp.r(p text) returns jsonb language sql stable as $$ select j from res where name = p $$;
create function pg_temp.subj(p text) returns bigint language sql stable as $$ select id from public.subjects where name = p $$;
create function pg_temp.code(j jsonb) returns text language sql immutable as $$
  select case when (j ->> 'ok')::boolean then 'ok' else coalesce(j ->> 'code', 'none') end $$;
create function pg_temp.who(p uuid) returns text language sql stable as $$ select coalesce((select name from c where id = p), '?') $$;
create function pg_temp.n(j jsonb, p text) returns numeric language sql immutable as $$ select trim_scale((j ->> p)::numeric) $$;
-- A piece's check state ('-' for none), its script's state, its own state.
create function pg_temp.cs(p text) returns text language sql stable security definer as $$
  select coalesce(check_state, '-') from public.marking_units where id = pg_temp.u(p) $$;
create function pg_temp.st(p text) returns text language sql stable security definer as $$
  select s.state::text from public.scripts s where s.id = pg_temp.k(split_part(p, ':', 1)) $$;
create function pg_temp.wanted(p text) returns text language sql stable security definer as $$
  select coalesce(second_wanted::text, '-') from public.marking_units where id = pg_temp.u(p) $$;
-- A piece's final marks in paper order: '1=2 first,2(a)=1 first,...' ('' for none).
create function pg_temp.fm(p text) returns text language sql stable security definer as $$
  select coalesce(string_agg(q.label || '=' || coalesce(trim_scale(f.mark)::text, 'NR') || ' ' || f.source, ',' order by q.path), '')
  from public.final_marks f join public.marking_unit_questions(pg_temp.u(p)) q on q.question_id = f.question_id
  where f.unit_id = pg_temp.u(p) $$;
-- The history rows of a piece's question (by its label), oldest first: 'mark source' or 'removed'.
create function pg_temp.hist(p text, p_label text) returns text[] language sql stable security definer as $$
  select coalesce(array_agg(case when h.removed then 'removed' else coalesce(trim_scale(h.mark)::text, 'NR') || ' ' || h.source end order by h.id), '{}')
  from public.final_mark_history h
  where h.unit_id = pg_temp.u(p) and h.question_id = (select q.question_id from public.marking_unit_questions(pg_temp.u(p)) q where q.label = p_label) $$;
-- A marking's rev and marks, read as postgres.
create function pg_temp.rev(p text) returns int language sql stable security definer as $$
  select rev from public.markings where id = pg_temp.k(p) $$;
create function pg_temp.marks(p text) returns text language sql stable security definer as $$
  select coalesce(string_agg(q.label || '=' || coalesce(trim_scale(m.mark)::text, 'NR'), ',' order by q.path), '')
  from public.markings k join public.question_marks m on m.marking_id = k.id
  join public.marking_unit_questions(k.unit_id) q on q.question_id = m.question_id
  where k.id = pg_temp.k(p) $$;
-- A marker's markings and holds on a piece: 'status reason' and how their holds ended ('open' for one that has not).
create function pg_temp.ms(p text, p_marker text) returns text language sql stable security definer as $$
  select coalesce(string_agg(m.kind || ' ' || m.status || coalesce(' ' || m.set_aside_reason, ''), ',' order by m.kind), '-') from public.markings m
  where m.unit_id = pg_temp.u(p) and m.marker_id = pg_temp.uid(p_marker) $$;
create function pg_temp.ended(p text, p_marker text) returns text language sql stable security definer as $$
  select coalesce(string_agg(a.kind || ' ' || coalesce(a.end_reason, 'open'), ',' order by a.kind, coalesce(a.end_reason, 'open')), '-')
  from public.marking_assignments a where a.unit_id = pg_temp.u(p) and a.marker_id = pg_temp.uid(p_marker) $$;
-- A piece's reviews: 'kind state outcome' in the order they were opened.
create function pg_temp.reviews(p text) returns text language sql stable security definer as $$
  select coalesce(string_agg(r.kind || ' ' || r.state || coalesce(' ' || r.outcome, ''), ',' order by r.opened_at, r.id), '-')
  from public.marking_reviews r where r.unit_id = pg_temp.u(p) $$;
create function pg_temp.audits(p_action text, p_target uuid) returns int language sql stable security definer as $$
  select count(*)::int from public.audit_log a where a.action = p_action and a.target_id = p_target $$;
create function pg_temp.student(p text) returns uuid language sql stable security definer as $$
  select b.student_id from public.scripts s join public.bookings b on b.id = s.booking_id where s.id = pg_temp.k(p) $$;
create function pg_temp.pages(p text) returns uuid[] language sql stable security definer as $$
  select coalesce(array_agg(l.page_id order by l.copy_page), '{}')
  from public.scripts s join public.script_page_links l on l.script_id = s.id and l.version = s.version where s.id = pg_temp.k(p) $$;
-- A question of a piece, by its label, and a save's mark for it.
create function pg_temp.q(p text, p_label text) returns uuid language sql stable security definer as $$
  select q.question_id from public.marking_unit_questions(pg_temp.u(p)) q where q.label = p_label $$;
create function pg_temp.op(p text, p_label text, p_mark numeric) returns jsonb language sql stable as $$
  select jsonb_build_object('op', 'mark', 'question_id', pg_temp.q(p, p_label), 'mark', p_mark, 'na', false) $$;
-- An entry of a set of marks to compare ({question_id, mark, na}), and the three of the piece of t1.
create function pg_temp.item(p_label text, p_mark numeric, p_na boolean default false) returns jsonb language sql stable as $$
  select jsonb_build_object('question_id', pg_temp.q('t1', p_label), 'mark', p_mark, 'na', p_na) $$;
create function pg_temp.set3(p1 numeric, p2 numeric, p3 numeric) returns jsonb language sql stable as $$
  select jsonb_build_array(pg_temp.item('1', p1), pg_temp.item('2', p2), pg_temp.item('3', p3)) $$;
create function pg_temp.cmp(p_a jsonb, p_b jsonb) returns jsonb language sql stable as $$
  select public.marking_compare_sets(pg_temp.u('t1'), p_a, p_b) $$;
-- The questions of a comparison that are out, by label.
create function pg_temp.outs(j jsonb) returns text language sql immutable as $$
  select coalesce(string_agg(x ->> 'label', ',' order by o), '') from jsonb_array_elements(j -> 'questions') with ordinality t(x, o)
  where (x ->> 'out')::boolean $$;
-- A new verified home script of an exam, its pages and, once marking is open, its pieces.
create function pg_temp.script(p_name text, p_exam text) returns void language plpgsql as $$
begin
  insert into kv values (p_name, tests.verified_script(pg_temp.k(p_exam), 'home'));
  insert into kv select 'p:' || p_name || ':' || l.copy_page, l.page_id
  from public.scripts s join public.script_page_links l on l.script_id = s.id and l.version = s.version where s.id = pg_temp.k(p_name);
  perform public.marking_exam_sync(pg_temp.k(p_exam), null);
  insert into kv select 'u:' || p_name || coalesce(':' || g.label, ''), u.id
  from public.marking_units u left join public.question_groups g on g.id = u.group_id where u.script_id = pg_temp.k(p_name)
  on conflict (name) do nothing;
end $$;
create function pg_temp.draw(p text, p_draw double precision) returns void language sql as $$
  update public.marking_units set sample_draw = p_draw where id = pg_temp.u(p) $$;
-- The first marking of a piece (tests.mark_piece: taken as Next script would, marked in paper order, submitted).
create function pg_temp.first(p text, p_marker text, p_marks numeric[]) returns void language plpgsql as $$
begin
  insert into kv values ('f:' || p, tests.mark_piece(pg_temp.u(p), pg_temp.uid(p_marker), p_marks))
  on conflict (name) do update set id = excluded.id;
end $$;
-- A second marking of a piece: its second pass taken as Next script would (unless the marker holds it), then, signed in
-- as the marker, opened, marked in paper order and submitted.
create function pg_temp.second(p text, p_marker text, p_marks numeric[]) returns void language plpgsql as $$
declare
  v_unit uuid := pg_temp.u(p);
  v_marker uuid := pg_temp.uid(p_marker);
  v_why text;
  v_ops jsonb;
  v_r jsonb;
  v_mk uuid;
begin
  if not exists (select 1 from public.marking_assignments a
                 where a.unit_id = v_unit and a.marker_id = v_marker and a.kind = 'second' and a.ended_at is null) then
    v_why := public.marking_unit_blocked(v_unit, v_marker, null, true, 'second');
    if v_why is not null then
      raise exception 'pg_temp.second: % cannot be given the second pass (%)', p_marker, v_why;
    end if;
    perform public.marking_unit_take(v_unit, v_marker, 'next', null, now() + interval '2 hours', 'second');
  end if;
  select jsonb_agg(jsonb_build_object('op', 'mark', 'question_id', q.question_id, 'mark', coalesce(p_marks[q.n], 0), 'na', false) order by q.n)
  into v_ops
  from (select t.question_id, row_number() over (order by t.path) as n from public.marking_unit_questions(v_unit) t where t.leaf) q;
  perform tests.as_user(v_marker);
  v_r := public.marking_unit_open(v_unit);
  v_mk := (v_r #>> '{marking,id}')::uuid;
  v_r := public.marking_save(v_mk, (v_r #>> '{marking,rev}')::int, v_ops);
  v_r := public.marking_submit(v_mk, (v_r ->> 'rev')::int);
  if not coalesce((v_r ->> 'ok')::boolean, false) then
    raise exception 'pg_temp.second: the submit was refused (%)', v_r ->> 'code';
  end if;
  perform tests.as_postgres();
  insert into kv values ('s:' || p, v_mk) on conflict (name) do update set id = excluded.id;
end $$;
-- A marker's save of a submitted marking (one change, with a reason), at its current rev.
create function pg_temp.change(p_marking text, p_marker text, p_ops jsonb, p_reason text) returns jsonb language plpgsql as $$
declare
  v_rev int := pg_temp.rev(p_marking);
  v_r jsonb;
begin
  perform tests.as_user(pg_temp.uid(p_marker));
  v_r := public.marking_save(pg_temp.k(p_marking), v_rev, p_ops, 0, p_reason);
  perform tests.as_postgres();
  return v_r;
end $$;
-- A list of pieces (marking_units_list): the scripts its pieces belong to, in its order.
create function pg_temp.listed(j jsonb) returns text language sql stable as $$
  select coalesce(string_agg(k.name, ',' order by o), '') from jsonb_array_elements(j -> 'units') with ordinality t(x, o)
  join kv k on k.id = (x ->> 'unit_id')::uuid and k.name like 'u:%' $$;
-- What exam_structure_get gives, as a draft to save again, and one question added to it (as 052).
create function pg_temp.draft(g jsonb) returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'groups', coalesce((select jsonb_agg(jsonb_build_object('key', x ->> 'id', 'label', x -> 'label')) from jsonb_array_elements(g -> 'groups') x), '[]'),
    'option_groups', '[]'::jsonb,
    'questions', coalesce((select jsonb_agg(jsonb_build_object('id', x -> 'id', 'key', x ->> 'id', 'parent_key', x -> 'parent_id',
        'label', x -> 'label', 'max_mark', x -> 'max_mark', 'mark_step', x -> 'mark_step', 'levels', x -> 'levels', 'pages', x -> 'pages',
        'areas', x -> 'areas', 'group_key', x -> 'group_id', 'option_group_key', x -> 'option_group_id', 'guidance', x -> 'guidance',
        'alternatives', x -> 'alternatives',
        'points', coalesce((select jsonb_agg(p - 'id') from jsonb_array_elements(x -> 'points') p), '[]')) order by o)
      from jsonb_array_elements(g -> 'questions') with ordinality t(x, o)), '[]')) $$;
create function pg_temp.plus(d jsonb, p_key text, p_label text, p_max numeric) returns jsonb language sql immutable as $$
  select jsonb_set(d, '{questions}', (d -> 'questions') || jsonb_build_array(jsonb_build_object('id', null, 'key', p_key, 'parent_key', null,
    'label', p_label, 'max_mark', p_max, 'mark_step', 1, 'levels', false, 'pages', '[1]'::jsonb, 'areas', '[]'::jsonb, 'group_key', null,
    'option_group_key', null, 'guidance', null, 'alternatives', null, 'points', '[]'::jsonb))) $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.u(text), pg_temp.r(text), pg_temp.code(jsonb), pg_temp.who(uuid),
  pg_temp.rev(text), pg_temp.q(text, text), pg_temp.op(text, text, numeric), pg_temp.pages(text), pg_temp.subj(text), pg_temp.draft(jsonb),
  pg_temp.plus(jsonb, text, text, numeric) to public;

insert into public.subjects (name, kind) values ('ZZ Check', 'school'), ('ZZ Check Other', 'school'), ('ZZ Check Small', 'school'),
  ('ZZ Check Off', 'school');
insert into c values ('admin', tests.create_user('admin', 'active')), ('corr', tests.create_user('corrector', 'active'));
insert into c select 'm' || i, tests.marker(pg_temp.subj('ZZ Check')) from generate_series(1, 4) i;
insert into c values ('lead', tests.marker(pg_temp.subj('ZZ Check'), true)), ('olead', tests.marker(pg_temp.subj('ZZ Check Other'), true)),
  ('s1', tests.marker(pg_temp.subj('ZZ Check Small'))), ('s2', tests.marker(pg_temp.subj('ZZ Check Small'))),
  ('sl', tests.marker(pg_temp.subj('ZZ Check Small'), true)),
  ('o1', tests.marker(pg_temp.subj('ZZ Check Off'))), ('o2', tests.marker(pg_temp.subj('ZZ Check Off')));

-- Exam t: one piece out of 60.
insert into kv values ('t', tests.marking_exam(pg_temp.subj('ZZ Check')));
insert into public.exam_questions (exam_id, label, position, max_mark, mark_step, pages)
values (pg_temp.k('t'), '1', 1, 5, 0.5, '{1}'), (pg_temp.k('t'), '2', 2, 20, 0.5, '{2}'), (pg_temp.k('t'), '3', 3, 35, 0.5, '{3}');
select tests.open_marking(pg_temp.k('t'));
select pg_temp.script('t1', 't');

-- Exam e: double marking on, 10% second-marked, 10% tolerance.
insert into kv values ('e', tests.marking_exam(pg_temp.subj('ZZ Check')));
select tests.structure(pg_temp.k('e'));
select tests.open_marking(pg_temp.k('e'),
  '{"double_marking": true, "sample_percent": 10, "tolerance_percent": 10, "seeds": false, "practice": false}');
select is((select array[public.marking_unit_max_total(pg_temp.u('t1')), public.exam_structure_max_total(pg_temp.k('e'))]),
  array[60, 10]::numeric[], 'fixtures: the piece of t1 is out of 60; exam e is out of 10');

-- ---------------------------------------------------------------------------------------------
-- tolerance_is_ten_percent_with_a_floor_of_one_mark
-- ---------------------------------------------------------------------------------------------
select is(array[public.marking_tolerance(60, 10), public.marking_tolerance(5, 10), public.marking_tolerance(20, 10),
                public.marking_tolerance(60, 20), public.marking_tolerance(3, 10), public.marking_tolerance(35, 10)],
  array[6, 1, 2, 12, 1, 3.5]::numeric[],
  'tolerance_is_ten_percent_with_a_floor_of_one_mark: 10% of 60 is 6, of 20 is 2, of 35 is 3.5; of 5 or 3 it is the floor of one mark; 20% of 60 is 12');
insert into res values ('t30_36', pg_temp.cmp(pg_temp.set3(0, 10, 20), pg_temp.set3(1, 12, 23)));
select is(array[pg_temp.r('t30_36') ->> 'within', pg_temp.n(pg_temp.r('t30_36'), 'total_a')::text, pg_temp.n(pg_temp.r('t30_36'), 'total_b')::text,
                pg_temp.n(pg_temp.r('t30_36'), 'total_tolerance')::text, pg_temp.n(pg_temp.r('t30_36'), 'max_total')::text, pg_temp.outs(pg_temp.r('t30_36'))],
  array['true', '30', '36', '6', '60', ''], 'a piece out of 60: totals 30 and 36 are within tolerance (6)');
insert into res values ('t30_365', pg_temp.cmp(pg_temp.set3(0, 10, 20), pg_temp.set3(1, 12, 23.5)));
select is(array[pg_temp.r('t30_365') ->> 'within', pg_temp.n(pg_temp.r('t30_365'), 'total_b')::text, pg_temp.outs(pg_temp.r('t30_365'))],
  array['false', '36.5', ''], 'totals 30 and 36.5 are outside, though every question is within its own tolerance');
select is(array[pg_temp.cmp(pg_temp.set3(2, 10, 20), pg_temp.set3(3, 10, 20)) ->> 'within', pg_temp.cmp(pg_temp.set3(2, 10, 20), pg_temp.set3(3.5, 10, 20)) ->> 'within',
                pg_temp.outs(pg_temp.cmp(pg_temp.set3(2, 10, 20), pg_temp.set3(3.5, 10, 20)))],
  array['true', 'false', '1'], 'a question of 5: 2 and 3 are within (the floor of one mark), 2 and 3.5 are outside');
select is(array[pg_temp.cmp(pg_temp.set3(2, 10, 20), pg_temp.set3(2, 12, 20)) ->> 'within', pg_temp.cmp(pg_temp.set3(2, 10, 20), pg_temp.set3(2, 12.5, 20)) ->> 'within',
                pg_temp.outs(pg_temp.cmp(pg_temp.set3(2, 10, 20), pg_temp.set3(2, 12.5, 20)))],
  array['true', 'false', '2'], 'a question of 20: 10 and 12 are within (10% is 2), 10 and 12.5 are outside');
update public.exam_marking set tolerance_percent = 20 where exam_id = pg_temp.k('t');
insert into res values ('t20', pg_temp.cmp(pg_temp.set3(0, 10, 20), pg_temp.set3(1, 14, 27)));
update public.exam_marking set tolerance_percent = 10 where exam_id = pg_temp.k('t');
select is(array[pg_temp.r('t20') ->> 'within', pg_temp.n(pg_temp.r('t20'), 'total_tolerance')::text],
  array['true', '12'], 'with a 20% tolerance on 60, totals 30 and 42 are within');
select is((select array_agg(x ->> 'label' || ' ' || trim_scale((x ->> 'max')::numeric) || ' ' || trim_scale((x ->> 'tolerance')::numeric) order by o)
           from jsonb_array_elements(pg_temp.r('t30_36') -> 'questions') with ordinality t(x, o)),
  array['1 5 1', '2 20 2', '3 35 3.5'], 'each question comes with its label, maximum and tolerance, in paper order');
select is((select array(select k from jsonb_object_keys(pg_temp.r('t30_36') -> 'questions' -> 0) k order by 1)),
  array['a', 'a_na', 'b', 'b_na', 'label', 'max', 'out', 'question_id', 'tolerance'], 'and both marks, both NRs and whether it is out');

-- ---------------------------------------------------------------------------------------------
-- nr_against_zero_agrees_and_nr_against_a_mark_differs
-- ---------------------------------------------------------------------------------------------
insert into res values ('nr0', pg_temp.cmp(jsonb_build_array(pg_temp.item('1', null, true), pg_temp.item('2', 10), pg_temp.item('3', 20)),
                                           pg_temp.set3(0, 10, 20)));
insert into res values ('nr05', pg_temp.cmp(jsonb_build_array(pg_temp.item('1', null, true), pg_temp.item('2', 10), pg_temp.item('3', 20)),
                                            pg_temp.set3(0.5, 10, 20)));
select is(array[pg_temp.r('nr0') ->> 'within', pg_temp.outs(pg_temp.r('nr0')), pg_temp.n(pg_temp.r('nr0'), 'total_a')::text,
                pg_temp.r('nr0') #>> '{questions,0,a}', pg_temp.r('nr0') #>> '{questions,0,a_na}'],
  array['true', '', '30', null, 'true'], 'nr_against_zero_agrees_and_nr_against_a_mark_differs: NR and 0 agree; NR counts 0 in the total');
select is(array[pg_temp.r('nr05') ->> 'within', pg_temp.outs(pg_temp.r('nr05'))], array['false', '1'],
  'NR and 0.5 differ, though the difference is under one mark');
select is(pg_temp.cmp(jsonb_build_array(pg_temp.item('1', null, true), pg_temp.item('2', 10), pg_temp.item('3', 20)),
                      jsonb_build_array(pg_temp.item('1', null, true), pg_temp.item('2', 10), pg_temp.item('3', 20))) ->> 'within',
  'true', 'NR and NR agree');

-- ---------------------------------------------------------------------------------------------
-- half_marks_compare_exactly
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.cmp(pg_temp.set3(2.5, 10, 20), pg_temp.set3(3.5, 10, 20)) ->> 'within',
                pg_temp.cmp(pg_temp.set3(2.5, 10, 20), pg_temp.set3(4, 10, 20)) ->> 'within',
                pg_temp.cmp(pg_temp.set3(2, 10, 20), pg_temp.set3(2, 10, 23.5)) ->> 'within',
                pg_temp.cmp(pg_temp.set3(2, 10, 20), pg_temp.set3(2, 10, 24)) ->> 'within',
                pg_temp.cmp(pg_temp.set3(0.5, 10, 20), pg_temp.set3(1.5, 12, 23)) ->> 'within',
                pg_temp.cmp(pg_temp.set3(0.5, 10, 20), pg_temp.set3(1.5, 12, 23.5)) ->> 'within'],
  array['true', 'false', 'true', 'false', 'true', 'false'],
  'half_marks_compare_exactly: 2.5 and 3.5 agree, 2.5 and 4 do not; with 3.5 allowed on 35, 20 and 23.5 agree and 20 and 24 do not; totals 30.5 and 36.5 agree, 30.5 and 37 do not');

-- ---------------------------------------------------------------------------------------------
-- unsampled_piece_is_checked_on_submit_with_final_marks: a1's draw (0.5) is over the 10% sample.
-- ---------------------------------------------------------------------------------------------
select pg_temp.script('a1', 'e');
select pg_temp.draw('a1', 0.5);
select pg_temp.first('a1', 'm1', array[2, 1, 4]);
select is(array[pg_temp.cs('a1'), pg_temp.wanted('a1'), pg_temp.st('a1')], array['checked', 'false', 'checked'],
  'unsampled_piece_is_checked_on_submit_with_final_marks: m1 submits a1; it is not second-marked, so it is checked, and so is its script');
select is((select array[(checked_at is not null)::text, (final_marking_id = pg_temp.k('f:a1'))::text] from public.marking_units where id = pg_temp.u('a1')),
  array['true', 'true'], 'it says when, and that its final marks come from m1''s marking');
select is(pg_temp.fm('a1'), '1=2 first,2(a)=1 first,2(b)=4 first', 'its final marks are m1''s, from the first marking');
select is((select array[count(*)::text, bool_and(not h.removed)::text, bool_and(h.changed_by = pg_temp.uid('m1'))::text,
                        bool_and(char_length(h.reason) > 0)::text]
           from public.final_mark_history h where h.unit_id = pg_temp.u('a1')),
  array['3', 'true', 'true', 'true'], 'each final mark has its history row: who (m1, whose submit checked it), when and why');

-- ---------------------------------------------------------------------------------------------
-- sample_follows_the_stored_draw
-- ---------------------------------------------------------------------------------------------
select pg_temp.script('a2', 'e'); select pg_temp.draw('a2', 0.05); select pg_temp.first('a2', 'm1', array[2, 1, 4]);
select pg_temp.script('a3', 'e'); select pg_temp.draw('a3', 0.1); select pg_temp.first('a3', 'm1', array[1, 1, 1]);
select is(array[pg_temp.cs('a2'), pg_temp.wanted('a2'), pg_temp.st('a2'), pg_temp.fm('a2'), pg_temp.cs('a3'), pg_temp.wanted('a3')],
  array['waiting_second', 'true', 'marked', '', 'checked', 'false'],
  'sample_follows_the_stored_draw: at 10%, a draw of 0.05 waits for a second marking (its script is marked, with no final marks); a draw of 0.1 does not');
update public.exam_marking set sample_percent = 100 where exam_id = pg_temp.k('e');
select pg_temp.script('a4', 'e'); select pg_temp.draw('a4', 0.99); select pg_temp.first('a4', 'm1', array[2, 1, 4]);
select is(array[pg_temp.cs('a4'), pg_temp.wanted('a4')], array['waiting_second', 'true'], 'at 100% every piece waits, a draw of 0.99 too');

-- ---------------------------------------------------------------------------------------------
-- sample_decision_is_kept_when_the_percent_changes: a3 was left out at 10% and a2 taken in; now the sample is 100%.
-- ---------------------------------------------------------------------------------------------
insert into res values ('k_change', pg_temp.change('f:a3', 'm1', jsonb_build_array(pg_temp.op('a3', '1', 2)), 'A slip in question 1'));
select is(array[pg_temp.code(pg_temp.r('k_change')), pg_temp.cs('a3'), pg_temp.wanted('a3')], array['ok', 'checked', 'false'],
  'sample_decision_is_kept_when_the_percent_changes: at 100%, m1 changes a mark on a3; it is checked again at once, still not second-marked');
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('k_set', public.marking_checks_set(pg_temp.k('e'), '{"double_marking": true, "sample_percent": 1, "tolerance_percent": 10,
  "seeds": false, "seed_every": 10, "practice": false}', 'Less second marking'));
select tests.as_postgres();
select public.marking_check_evaluate(pg_temp.u('a2'));
select is(array[pg_temp.code(pg_temp.r('k_set')), pg_temp.cs('a2'), pg_temp.wanted('a2')], array['ok', 'waiting_second', 'true'],
  'an admin lowers the sample to 1%; a2, taken in at 10%, still waits for its second marking');
update public.exam_marking set sample_percent = 10 where exam_id = pg_temp.k('e');

-- ---------------------------------------------------------------------------------------------
-- double_marking_off_checks_every_piece_on_submit: exam d has its checks off; d1's draw would be in any sample.
-- ---------------------------------------------------------------------------------------------
insert into kv values ('d', tests.marking_exam(pg_temp.subj('ZZ Check')));
select tests.structure(pg_temp.k('d'));
select tests.open_marking(pg_temp.k('d'));
select pg_temp.script('d1', 'd'); select pg_temp.draw('d1', 0.01); select pg_temp.first('d1', 'm1', array[3, 2, 5]);
select is(array[pg_temp.cs('d1'), pg_temp.wanted('d1'), pg_temp.st('d1'), pg_temp.fm('d1')],
  array['checked', 'false', 'checked', '1=3 first,2(a)=2 first,2(b)=5 first'],
  'double_marking_off_checks_every_piece_on_submit: with double marking off, d1 is checked as soon as it is submitted');

-- ---------------------------------------------------------------------------------------------
-- second_within_tolerance_checks_and_first_marks_stand: m2 second-marks a2 one mark lower on 2(b).
-- ---------------------------------------------------------------------------------------------
select pg_temp.second('a2', 'm2', array[2, 1, 3]);
select is(array[pg_temp.cs('a2'), pg_temp.st('a2'), pg_temp.fm('a2')],
  array['checked', 'checked', '1=2 first,2(a)=1 first,2(b)=4 first'],
  'second_within_tolerance_checks_and_first_marks_stand: within tolerance, a2 is checked and its final marks are the first marker''s');
select is((select array[(final_marking_id = pg_temp.k('f:a2'))::text, (select string_agg(distinct f.source, ',') from public.final_marks f where f.unit_id = pg_temp.u('a2'))]
           from public.marking_units where id = pg_temp.u('a2')),
  array['true', 'first'], 'every final mark''s source is first, and the final marking is the first');
select is(public.marking_compare(pg_temp.k('f:a2'), pg_temp.k('s:a2')) ->> 'within', 'true', 'marking_compare finds the two markings within tolerance');
select is(pg_temp.reviews('a2'), '-', 'nothing goes to the lead');

-- ---------------------------------------------------------------------------------------------
-- second_outside_tolerance_goes_to_the_lead: m2 gives a4's question 1 two marks fewer.
-- ---------------------------------------------------------------------------------------------
select pg_temp.second('a4', 'm2', array[0, 1, 4]);
select is(array[pg_temp.cs('a4'), pg_temp.st('a4'), pg_temp.fm('a4'), pg_temp.reviews('a4')],
  array['to_lead', 'marked', '', 'difference open'],
  'second_outside_tolerance_goes_to_the_lead: outside tolerance, a4 goes to the lead with one open difference review, and no final marks');
select is((select array[(r.marking_id = pg_temp.k('f:a4'))::text, (r.second_marking_id = pg_temp.k('s:a4'))::text, (r.exam_id = pg_temp.k('e'))::text]
           from public.marking_reviews r where r.unit_id = pg_temp.u('a4')),
  array['true', 'true', 'true'], 'the review names both markings and the exam');

-- ---------------------------------------------------------------------------------------------
-- script_is_checked_only_when_every_piece_is: exam q is marked by question (A: question 1; B: question 2); q1's A is
-- not sampled, its B is.
-- ---------------------------------------------------------------------------------------------
insert into kv values ('q', tests.marking_exam(pg_temp.subj('ZZ Check')));
select tests.structure(pg_temp.k('q'));
insert into public.question_groups (exam_id, label, position) values (pg_temp.k('q'), 'A', 1), (pg_temp.k('q'), 'B', 2);
update public.exam_questions x set group_id = (select g.id from public.question_groups g where g.exam_id = x.exam_id
                                               and g.label = case x.label when '1' then 'A' else 'B' end)
where x.exam_id = pg_temp.k('q') and x.parent_id is null;
update public.exam_marking set mode = 'by_question' where exam_id = pg_temp.k('q');
select tests.open_marking(pg_temp.k('q'), '{"double_marking": true, "sample_percent": 10}');
select pg_temp.script('q1', 'q'); select pg_temp.draw('q1:A', 0.5); select pg_temp.draw('q1:B', 0.05);
select pg_temp.first('q1:A', 'm1', array[2]);
select is(array[pg_temp.cs('q1:A'), pg_temp.cs('q1:B'), pg_temp.st('q1')], array['checked', '-', 'marking'],
  'script_is_checked_only_when_every_piece_is: q1''s A is checked; its B is not marked yet, so the script is being marked');
select pg_temp.first('q1:B', 'm1', array[1, 4]);
select is(array[pg_temp.cs('q1:A'), pg_temp.cs('q1:B'), pg_temp.st('q1')], array['checked', 'waiting_second', 'marked'],
  'B is submitted and waits for a second marking: the script is marked, not checked');
select pg_temp.second('q1:B', 'm2', array[1, 4]);
select is(array[pg_temp.cs('q1:B'), pg_temp.st('q1')], array['checked', 'checked'], 'once B is checked, so is the script');

-- ---------------------------------------------------------------------------------------------
-- take_back_of_a_checked_piece_unchecks_the_script_and_removes_final_marks_with_history
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('tb', public.marking_take_back(array[pg_temp.u('a1')], 'Marked against the wrong scheme'));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('tb')), pg_temp.cs('a1'), pg_temp.st('a1'), pg_temp.fm('a1')],
  array['ok', '-', 'marking', ''],
  'take_back_of_a_checked_piece_unchecks_the_script_and_removes_final_marks_with_history: an admin takes back a1''s marking; it is no longer checked and its script is being marked again');
select is((select array[(checked_at is null)::text, (final_marking_id is null)::text] from public.marking_units where id = pg_temp.u('a1')),
  array['true', 'true'], 'it is no longer checked, and has no final marking');
select is(array[array_to_string(pg_temp.hist('a1', '1'), ';'), array_to_string(pg_temp.hist('a1', '2(b)'), ';')],
  array['2 first;removed', '4 first;removed'],
  'each final mark is kept in its history and then removed');
select is((select array[count(*)::text, bool_and(h.changed_by = pg_temp.uid('admin'))::text, bool_and(char_length(h.reason) > 0)::text]
           from public.final_mark_history h where h.unit_id = pg_temp.u('a1') and h.removed),
  array['3', 'true', 'true'], 'each removal says who (the admin who took it back), when and why');

-- ---------------------------------------------------------------------------------------------
-- marker_change_after_submit_rechecks: a5 is not sampled; a2 was second-marked within tolerance.
-- ---------------------------------------------------------------------------------------------
select pg_temp.script('a5', 'e'); select pg_temp.draw('a5', 0.5); select pg_temp.first('a5', 'm1', array[1, 1, 1]);
insert into res values ('ch5', pg_temp.change('f:a5', 'm1', jsonb_build_array(pg_temp.op('a5', '1', 2)), 'Question 1 deserves two'));
select is(array[pg_temp.code(pg_temp.r('ch5')), pg_temp.cs('a5'), pg_temp.fm('a5')], array['ok', 'checked', '1=2 first,2(a)=1 first,2(b)=1 first'],
  'marker_change_after_submit_rechecks: m1 changes a mark on a5 (not second-marked); it is checked again and its final mark follows');
select is(array[array_to_string(pg_temp.hist('a5', '1'), ';'), array_to_string(pg_temp.hist('a5', '2(a)'), ';')],
  array['1 first;2 first', '1 first'],
  'the changed question has two history rows; the others one');
insert into res values ('ch2', pg_temp.change('f:a2', 'm1', jsonb_build_array(pg_temp.op('a2', '1', 0)), 'Question 1 is wrong'));
select is(array[pg_temp.code(pg_temp.r('ch2')), pg_temp.cs('a2'), pg_temp.st('a2'), pg_temp.reviews('a2'), pg_temp.fm('a2')],
  array['ok', 'to_lead', 'marked', 'difference open', ''],
  'm1 changes question 1 of a2 (second-marked) from 2 to 0: it is compared again, is now outside tolerance and goes to the lead');

-- ---------------------------------------------------------------------------------------------
-- marker_change_refused_once_the_lead_settled: a6 is second-marked within tolerance; the lead settled it (first marks
-- stand), written here as postgres.
-- ---------------------------------------------------------------------------------------------
select pg_temp.script('a6', 'e'); select pg_temp.draw('a6', 0.05); select pg_temp.first('a6', 'm1', array[2, 1, 4]);
select pg_temp.second('a6', 'm3', array[2, 1, 4]);
insert into public.marking_reviews (exam_id, unit_id, kind, marking_id, second_marking_id, state, outcome, reason, closed_by, closed_at)
values (pg_temp.k('e'), pg_temp.u('a6'), 'difference', pg_temp.k('f:a6'), pg_temp.k('s:a6'), 'closed', 'first_stands', 'First marks stand',
        pg_temp.uid('lead'), now());
insert into res values ('st_rev', to_jsonb(array[pg_temp.rev('f:a6'), pg_temp.rev('s:a6')]));
insert into res values ('st1', pg_temp.change('f:a6', 'm1', jsonb_build_array(pg_temp.op('a6', '1', 1)), 'I was too generous'));
insert into res values ('st2', pg_temp.change('s:a6', 'm3', jsonb_build_array(pg_temp.op('a6', '1', 3)), 'I was too mean'));
select is(array[pg_temp.r('st1'), pg_temp.r('st2')], array['{"ok": false, "code": "settled"}', '{"ok": false, "code": "settled"}']::jsonb[],
  'marker_change_refused_once_the_lead_settled: once the lead has settled a6, neither its first nor its second marker may change a mark');
select is(array[pg_temp.marks('f:a6'), pg_temp.marks('s:a6'), to_jsonb(array[pg_temp.rev('f:a6'), pg_temp.rev('s:a6')])::text],
  array['1=2,2(a)=1,2(b)=4', '1=2,2(a)=1,2(b)=4', pg_temp.r('st_rev')::text], 'both markings are as they were, revs too');
select public.marking_check_evaluate(pg_temp.u('a6'));
select is(pg_temp.cs('a6'), 'checked', 'and a settled piece stays checked when it is looked at again');

-- ---------------------------------------------------------------------------------------------
-- settle_covers_only_the_submission_it_reviewed (the 3B ledger's R9): a9 is second-marked within tolerance and the
-- lead settled it (first marks stand) an hour after its first marking came in. An admin then takes that marking back
-- and gives it to m1 again (the same marking, in progress again); m1 changes a mark and submits it again.
-- ---------------------------------------------------------------------------------------------
select pg_temp.script('a9', 'e'); select pg_temp.draw('a9', 0.05); select pg_temp.first('a9', 'm1', array[2, 1, 4]);
select pg_temp.second('a9', 'm2', array[2, 1, 4]);
insert into kv values ('f0:a9', pg_temp.k('f:a9'));
update public.markings set submitted_at = now() - interval '2 hours' where id in (pg_temp.k('f:a9'), pg_temp.k('s:a9'));
insert into public.marking_reviews (exam_id, unit_id, kind, marking_id, second_marking_id, state, outcome, reason, opened_at, closed_by, closed_at)
values (pg_temp.k('e'), pg_temp.u('a9'), 'difference', pg_temp.k('f:a9'), pg_temp.k('s:a9'), 'closed', 'first_stands', 'First marks stand',
        now() - interval '90 minutes', pg_temp.uid('lead'), now() - interval '1 hour');
insert into res values ('r9_settled', pg_temp.change('f:a9', 'm1', jsonb_build_array(pg_temp.op('a9', '1', 1)), 'A slip in question 1'));
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('r9_tb', public.marking_take_back(array[pg_temp.u('a9')], 'Marked against the wrong scheme'));
insert into res values ('r9_assign', public.marking_assign(array[pg_temp.u('a9')], pg_temp.uid('m1'), 'Back to its marker'));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('r9_settled')), pg_temp.code(pg_temp.r('r9_tb')), pg_temp.r('r9_assign') ->> 'assigned',
                pg_temp.ms('a9', 'm1'), pg_temp.cs('a9'),
                ((select m.id from public.markings m where m.unit_id = pg_temp.u('a9') and m.kind = 'live') = pg_temp.k('f0:a9'))::text],
  array['settled', 'ok', '1', 'live in_progress', '-', 'true'],
  'settle_covers_only_the_submission_it_reviewed: a9 is settled; an admin takes its first marking back and gives the same marking to m1 again');
select pg_temp.first('a9', 'm1', array[0, 1, 4]);
select is(array[pg_temp.cs('a9'), pg_temp.reviews('a9'), pg_temp.fm('a9'), (pg_temp.k('f:a9') = pg_temp.k('f0:a9'))::text],
  array['to_lead', 'difference closed first_stands,difference open', '', 'true'],
  'm1 submits it again with question 1 changed: the old settle does not cover it, so it is compared again and goes to the lead');

-- ---------------------------------------------------------------------------------------------
-- second_add_sends_a_checked_piece_for_second_marking: a5 is checked and was not sampled.
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('lead'));
insert into res values ('add5', public.marking_second_add(array[pg_temp.u('a5')], 'Check this one too'));
select tests.as_postgres();
select is(pg_temp.r('add5'), '{"ok": true, "added": 1, "skipped": []}'::jsonb,
  'second_add_sends_a_checked_piece_for_second_marking: the lead asks for a5 to be second-marked');
select is(array[pg_temp.cs('a5'), pg_temp.wanted('a5'), pg_temp.st('a5'), pg_temp.fm('a5')], array['waiting_second', 'true', 'marked', ''],
  'a5 waits for a second marking: its script is marked again and its final marks are removed');
select is((select array[a.reason, pg_temp.who(a.actor_id)] from public.audit_log a where a.action = 'marking_second_added' and a.target_id = pg_temp.u('a5')),
  array['Check this one too', 'lead'], 'audited, with the reason');
select is(coalesce(public.marking_unit_blocked(pg_temp.u('a5'), pg_temp.uid('m4'), null, true, 'second'), 'ok'), 'ok',
  'another marker may now be given its second pass');
select pg_temp.script('a7', 'e');
select tests.as_user(pg_temp.uid('lead'));
insert into res values ('add_skip', public.marking_second_add(array[pg_temp.u('a7'), pg_temp.u('a6'), pg_temp.u('a4'), pg_temp.u('a5')],
  'Check these as well'));
select tests.as_postgres();
select is((select jsonb_agg(x ->> 'code' order by x ->> 'code') from jsonb_array_elements(pg_temp.r('add_skip') -> 'skipped') x),
  '["already", "not_submitted", "settled", "with_lead"]'::jsonb,
  'a piece not yet marked, one the lead settled, one with the lead and one already waiting are skipped, each with its code');
select is(array[(pg_temp.r('add_skip') ->> 'added'), pg_temp.cs('a7'), pg_temp.cs('a6'), pg_temp.cs('a4')], array['0', '-', 'checked', 'to_lead'],
  'and left as they were');

-- ---------------------------------------------------------------------------------------------
-- second_drop_checks_the_piece_with_a_reason (Review Focus 2). Exam sm of 'ZZ Check Small' second-marks every piece;
-- s1 marks sm1, then s2 declares a conflict with its candidate and the lead sl tutors them: nobody can second-mark it.
-- ---------------------------------------------------------------------------------------------
insert into kv values ('sm', tests.marking_exam(pg_temp.subj('ZZ Check Small')));
select tests.structure(pg_temp.k('sm'));
select tests.open_marking(pg_temp.k('sm'), '{"double_marking": true, "sample_percent": 100}');
select pg_temp.script('sm1', 'sm'); select pg_temp.first('sm1', 's1', array[2, 1, 4]);
select is(array(select x.unit_id from public.marking_second_stuck(pg_temp.k('sm')) x), '{}'::uuid[],
  'second_drop_checks_the_piece_with_a_reason: sm1 waits for a second marking; s2 or the lead could take it, so it is not stuck');
insert into public.marker_conflicts (marker_id, student_id, recorded_at) values (pg_temp.uid('s2'), pg_temp.student('sm1'), now());
insert into public.tutor_students (tutor_id, student_id) values (pg_temp.uid('sl'), pg_temp.student('sm1'));
select is(array(select x.unit_id from public.marking_second_stuck(pg_temp.k('sm')) x), array[pg_temp.u('sm1')],
  'once s2 has a conflict and the lead tutors the candidate, nobody can: sm1 is counted as stuck');
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('drop_none', public.marking_second_drop(array[pg_temp.u('sm1')], null));
insert into res values ('drop_sm1', public.marking_second_drop(array[pg_temp.u('sm1')], 'Nobody else can mark it'));
select tests.as_postgres();
select is(array[pg_temp.r('drop_none'), pg_temp.r('drop_sm1')],
  array['{"ok": false, "code": "reason_required"}', '{"ok": true, "dropped": 1, "skipped": []}']::jsonb[],
  'an admin releases it, with a reason (none is refused)');
select is(array[pg_temp.cs('sm1'), pg_temp.wanted('sm1'), pg_temp.st('sm1'), pg_temp.fm('sm1')],
  array['checked', 'false', 'checked', '1=2 first,2(a)=1 first,2(b)=4 first'], 'sm1 is checked on its first marks');
select is(array[(select a.reason from public.audit_log a where a.action = 'marking_second_dropped' and a.target_id = pg_temp.u('sm1')),
                (select count(*)::text from public.marking_second_stuck(pg_temp.k('sm')))],
  array['Nobody else can mark it', '0'], 'audited with the reason, and no longer stuck');
-- a5 waits; m4 takes its second pass and starts marking it; the lead drops it.
select public.marking_unit_take(pg_temp.u('a5'), pg_temp.uid('m4'), 'next', null, now() + interval '2 hours', 'second');
select tests.as_user(pg_temp.uid('m4'));
select public.marking_unit_open(pg_temp.u('a5'));
select tests.as_postgres();
select tests.as_user(pg_temp.uid('lead'));
insert into res values ('drop5', public.marking_second_drop(array[pg_temp.u('a5'), pg_temp.u('a6')], 'Enough second marking here'));
select tests.as_postgres();
select is(pg_temp.r('drop5'), jsonb_build_object('ok', true, 'dropped', 1, 'skipped',
                                 jsonb_build_array(jsonb_build_object('unit_id', pg_temp.u('a6'), 'code', 'not_waiting'))),
  'the lead drops a5''s second marking (a6, which waits for nothing, is skipped)');
select is(array[pg_temp.ended('a5', 'm4'), pg_temp.ms('a5', 'm4'), pg_temp.cs('a5'), pg_temp.wanted('a5'), pg_temp.fm('a5')],
  array['second switched_off', 'second set_aside switched_off', 'checked', 'false', '1=2 first,2(a)=1 first,2(b)=1 first'],
  'm4''s hold ends and their marking is set aside; a5 is checked on its first marks');

-- ---------------------------------------------------------------------------------------------
-- second_add_and_drop_need_lead_or_admin
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('m3')); insert into res values ('n_m3', public.marking_second_add(array[pg_temp.u('a3')], 'Please check'));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('corr'));
insert into res values ('n_corr', public.marking_second_drop(array[pg_temp.u('a5')], 'Please drop'));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('olead'));
insert into res values ('n_olead', public.marking_second_add(array[pg_temp.u('a3')], 'Please check'));
insert into res values ('n_olead_drop', public.marking_second_drop(array[pg_temp.u('a5')], 'Please drop'));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
insert into res values ('n_empty', public.marking_second_add('{}', 'Please check'));
insert into res values ('n_many', public.marking_second_add(array(select gen_random_uuid() from generate_series(1, 201)), 'Please check'));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('n_m3')), pg_temp.code(pg_temp.r('n_corr'))], array['forbidden', 'forbidden'],
  'second_add_and_drop_need_lead_or_admin: a marker and a corrector are refused');
select is(array[pg_temp.r('n_olead') -> 'skipped', pg_temp.r('n_olead_drop') -> 'skipped'],
  array[jsonb_build_array(jsonb_build_object('unit_id', pg_temp.u('a3'), 'code', 'forbidden')),
        jsonb_build_array(jsonb_build_object('unit_id', pg_temp.u('a5'), 'code', 'forbidden'))],
  'the lead of another subject has each piece skipped as forbidden');
select is(array[pg_temp.cs('a3'), pg_temp.wanted('a3'), pg_temp.code(pg_temp.r('n_empty')), pg_temp.code(pg_temp.r('n_many'))],
  array['checked', 'false', 'invalid_input', 'invalid_input'], 'a3 is unchanged; no piece, or more than 200, is invalid');
insert into public.tutor_students (tutor_id, student_id) values (pg_temp.uid('lead'), pg_temp.student('a3'));
select tests.as_user(pg_temp.uid('lead'));
insert into res values ('n_blocked', public.marking_second_add(array[pg_temp.u('a3')], 'Please check'));
select tests.as_postgres();
delete from public.tutor_students where tutor_id = pg_temp.uid('lead');
select is(pg_temp.r('n_blocked') -> 'skipped', jsonb_build_array(jsonb_build_object('unit_id', pg_temp.u('a3'), 'code', 'conflict_of_interest')),
  'a lead who tutors the candidate may not ask for a second marking of their script');

-- ---------------------------------------------------------------------------------------------
-- switching_double_marking_off_checks_waiting_pieces_and_ends_second_holds. Exam f of 'ZZ Check Off' second-marks every
-- piece; o1 marks f1 and f2; o2 takes f1's second pass and starts it; then o2 is suspended, leaving one marker.
-- ---------------------------------------------------------------------------------------------
insert into kv values ('f', tests.marking_exam(pg_temp.subj('ZZ Check Off')));
select tests.structure(pg_temp.k('f'));
select tests.open_marking(pg_temp.k('f'), '{"double_marking": true, "sample_percent": 100}');
select pg_temp.script('f1', 'f'); select pg_temp.first('f1', 'o1', array[2, 1, 4]);
select pg_temp.script('f2', 'f'); select pg_temp.first('f2', 'o1', array[3, 2, 5]);
-- f3 waits too, and is then withdrawn (its booking was cancelled, say).
select pg_temp.script('f3', 'f'); select pg_temp.first('f3', 'o1', array[1, 1, 1]);
update public.scripts set state = 'withdrawn' where id = pg_temp.k('f3');
select public.marking_unit_take(pg_temp.u('f1'), pg_temp.uid('o2'), 'next', null, now() + interval '2 hours', 'second');
select tests.as_user(pg_temp.uid('o2')); select public.marking_unit_open(pg_temp.u('f1')); select tests.as_postgres();
select is(array[pg_temp.cs('f1'), pg_temp.cs('f2'), pg_temp.ms('f1', 'o2')], array['waiting_second', 'waiting_second', 'second in_progress'],
  'switching_double_marking_off_checks_waiting_pieces_and_ends_second_holds: f1 and f2 wait; o2 is second-marking f1');
update public.profiles set status = 'suspended' where id = pg_temp.uid('o2');
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('off', public.marking_checks_set(pg_temp.k('f'), '{"double_marking": false, "sample_percent": 100, "tolerance_percent": 10,
  "seeds": false, "seed_every": 10, "practice": false}', 'Only one marker is left'));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('off')), pg_temp.cs('f1'), pg_temp.cs('f2'), pg_temp.st('f1'), pg_temp.st('f2'), pg_temp.wanted('f1'), pg_temp.wanted('f2')],
  array['ok', 'checked', 'checked', 'checked', 'checked', 'false', 'false'],
  'an admin turns double marking off: both pieces are checked on their first marks, and so are their scripts');
select is(array[pg_temp.ended('f1', 'o2'), pg_temp.ms('f1', 'o2'), pg_temp.fm('f2')],
  array['second switched_off', 'second set_aside switched_off', '1=3 first,2(a)=2 first,2(b)=5 first'],
  'o2''s second hold ends and their marking is set aside');
select is(array[pg_temp.audits('marking_second_dropped', pg_temp.u('f1')), pg_temp.audits('marking_second_dropped', pg_temp.u('f2'))], array[1, 1],
  'each piece''s second marking is recorded as dropped');
select is(array[pg_temp.cs('f3'), pg_temp.wanted('f3'), pg_temp.audits('marking_second_dropped', pg_temp.u('f3'))::text],
  array['waiting_second', 'true', '0'], 'the withdrawn script''s piece is left as it was');
update public.profiles set status = 'active' where id = pg_temp.uid('o2');
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('on', public.marking_checks_set(pg_temp.k('f'), '{"double_marking": true, "sample_percent": 100, "tolerance_percent": 10,
  "seeds": false, "seed_every": 10, "practice": false}', 'Two markers again'));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('on')), pg_temp.cs('f1'), pg_temp.cs('f2'), pg_temp.wanted('f1')], array['ok', 'checked', 'checked', 'false'],
  'turning it on again does not reach back to the pieces already checked');

-- ---------------------------------------------------------------------------------------------
-- checked_script_is_still_locked_held_and_taken_back_like_a_marked_one: d1 to d4 of exam d (checks off) are checked.
-- ---------------------------------------------------------------------------------------------
do $$ begin for i in 2..4 loop perform pg_temp.script('d' || i, 'd'); perform pg_temp.first('d' || i, 'm1', array[1, 1, 1]); end loop; end $$;
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('d_get', public.marking_exam_get(pg_temp.k('d')));
select tests.as_postgres();
select is(array[pg_temp.st('d1'), pg_temp.st('d4'), pg_temp.r('d_get') #>> '{scripts,marked}',
                public.script_booking_locked((select s.booking_id from public.scripts s where s.id = pg_temp.k('d1')))::text],
  array['checked', 'checked', '4', 'true'],
  'checked_script_is_still_locked_held_and_taken_back_like_a_marked_one: the four scripts are checked, counted as marked, and their bookings are locked');
update public.script_pages set marking_inputs = 'before' where id = pg_temp.k('p:d1:1');
update public.script_pages set marking_path = replace(marking_path, '-marking.jpg', '-again-marking.jpg') where id = pg_temp.k('p:d1:1');
select is((select array[u.on_hold::text, u.hold_reason, (select string_agg(a.kind || ' ' || a.state, ',') from public.marking_alerts a where a.script_id = pg_temp.k('d1'))]
           from public.marking_units u where u.id = pg_temp.u('d1')),
  array['true', 'picture_changed', 'picture_changed open'], 'a picture change holds d1''s piece and raises an alert');
select tests.as_user(pg_temp.uid('lead'));
insert into res values ('d_paths', public.marking_picture_paths(pg_temp.u('d1'), pg_temp.pages('d1')));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
insert into res values ('d_tb', public.marking_script_take_back(pg_temp.k('d1'), 'Hide the name on page 1'));
insert into res values ('d_shows', public.script_page_marking_name_shows(pg_temp.k('p:d3:1'), 'A name shows on page 1'));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m1'));
insert into res values ('d_name', public.marking_name_visible(pg_temp.u('d2'), pg_temp.k('p:d2:1')));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('d_paths')), pg_temp.code(pg_temp.r('d_tb')), pg_temp.code(pg_temp.r('d_name')), pg_temp.code(pg_temp.r('d_shows'))],
  array['ok', 'ok', 'ok', 'ok'],
  'the lead may look at its pictures; an admin takes d1 back; m1 reports a name on d2; an admin says a name still shows on d3');
select is((select array_agg(coalesce(s.taken_back_reason, '-') order by s.number) from public.scripts s
           where s.id in (pg_temp.k('d1'), pg_temp.k('d2'), pg_temp.k('d3'), pg_temp.k('d4'))),
  array['Hide the name on page 1', 'name_visible', 'A name shows on page 1', '-'], 'd1, d2 and d3 are taken back from the markers, as marked scripts are');
select is(array[pg_temp.cs('d2'), pg_temp.fm('d2'), array_to_string(pg_temp.hist('d2', '1'), ';'), pg_temp.cs('d3'), pg_temp.fm('d3')],
  array['-', '', '1 first;removed', 'checked', '1=1 first,2(a)=1 first,2(b)=1 first'],
  'name_visible_on_a_checked_piece_clears_its_check: m1''s marking of d2 is set aside, so d2 is no longer checked and its final marks are removed; d3''s submitted marking stands');
insert into public.script_exceptions (exam_id, kind, booking_id, script_id, details)
select s.exam_id, 'not_expected'::public.exception_kind, s.booking_id, s.id, '{"reason": "script_locked"}'::jsonb
from public.scripts s where s.id = pg_temp.k('d4');
select is((select string_agg(a.kind || ' ' || a.state, ',') from public.marking_alerts a where a.script_id = pg_temp.k('d4')),
  'pages_set_aside open', 'a page set aside for d4 raises its alert');

-- ---------------------------------------------------------------------------------------------
-- hand_back_with_changed_pages_unchecks_the_piece: d1 is taken back, page 1 is turned, and an admin hands it back.
-- ---------------------------------------------------------------------------------------------
update public.script_pages set rotation = 90 where id = pg_temp.k('p:d1:1');
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('d_hb', public.marking_script_hand_back(pg_temp.k('d1')));
select tests.as_postgres();
select is(array[pg_temp.r('d_hb')::text, pg_temp.ms('d1', 'm1'), pg_temp.cs('d1'), pg_temp.fm('d1'), pg_temp.st('d1')],
  array['{"ok": true, "state": "marking", "reopened": 1}', 'live in_progress', '-', '', 'marking'],
  'hand_back_with_changed_pages_unchecks_the_piece: d1''s marking goes back to m1, and d1 is no longer checked and has no final marks');
select pg_temp.first('d1', 'm1', array[3, 2, 4]);
select is(array[pg_temp.cs('d1'), pg_temp.st('d1'), pg_temp.fm('d1'), array_to_string(pg_temp.hist('d1', '2(b)'), ';')],
  array['checked', 'checked', '1=3 first,2(a)=2 first,2(b)=4 first', '5 first;removed;4 first'],
  'm1 submits it again: d1 is checked again, on the marks as they are now');

-- ---------------------------------------------------------------------------------------------
-- take_back_opens_no_stray_review: m2, whose marking of d5 is checked, is paused on exam d (as Task 5 will pause
-- markers); an admin takes d5's marking back.
-- ---------------------------------------------------------------------------------------------
select pg_temp.script('d5', 'd'); select pg_temp.first('d5', 'm2', array[1, 1, 1]);
insert into public.exam_markers (exam_id, marker_id, paused_at) values (pg_temp.k('d'), pg_temp.uid('m2'), now());
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('d5_tb', public.marking_take_back(array[pg_temp.u('d5')], 'Marked against the wrong scheme'));
select tests.as_postgres();
delete from public.exam_markers where exam_id = pg_temp.k('d') and marker_id = pg_temp.uid('m2');
select is(array[pg_temp.code(pg_temp.r('d5_tb')), pg_temp.cs('d5'), pg_temp.reviews('d5')], array['ok', '-', '-'],
  'take_back_opens_no_stray_review: the piece is opened before its marking is set aside, and no review is opened between the two');

-- ---------------------------------------------------------------------------------------------
-- script_total_comes_from_question_marks_not_piece_totals. Exam bq is marked by question with checks off: questions 5,
-- 6 and 7 of 10 marks each, answer 2 of them; 5 is in group A, 6 and 7 in group B.
-- ---------------------------------------------------------------------------------------------
insert into kv values ('bq', tests.marking_exam(pg_temp.subj('ZZ Check')));
insert into public.question_groups (exam_id, label, position) values (pg_temp.k('bq'), 'A', 1), (pg_temp.k('bq'), 'B', 2);
insert into public.exam_option_groups (exam_id, label, choose) values (pg_temp.k('bq'), 'Answer 2', 2);
insert into public.exam_questions (exam_id, label, position, max_mark, pages, group_id, option_group_id)
select pg_temp.k('bq'), x.label, x.pos, 10, array[x.pos], g.id, o.id
from (values ('5', 1, 'A'), ('6', 2, 'B'), ('7', 3, 'B')) x(label, pos, grp)
join public.question_groups g on g.exam_id = pg_temp.k('bq') and g.label = x.grp
cross join public.exam_option_groups o where o.exam_id = pg_temp.k('bq');
update public.exam_marking set mode = 'by_question' where exam_id = pg_temp.k('bq');
select tests.open_marking(pg_temp.k('bq'));
select pg_temp.script('b1', 'bq');
select pg_temp.first('b1:A', 'm1', array[9]);
select is(array[pg_temp.cs('b1:A'), pg_temp.st('b1'), coalesce(public.script_final_total(pg_temp.k('b1'))::text, 'null'),
                (select count(*)::text from public.script_final_marks(pg_temp.k('b1')))],
  array['checked', 'marking', 'null', '0'],
  'script_total_comes_from_question_marks_not_piece_totals: with only A checked the script is not, and has no total or final marks');
select pg_temp.first('b1:B', 'm1', array[8, 7]);
select is(array[pg_temp.st('b1'),
                (select trim_scale(sum(m.total))::text from public.markings m join public.marking_units u on u.id = m.unit_id where u.script_id = pg_temp.k('b1')),
                trim_scale(public.script_final_total(pg_temp.k('b1')))::text],
  array['checked', '24', '17'],
  'checked: the piece totals add up to 24 (each piece counts its own best two), but the script''s total is 17, its best two questions');
select is((select array_agg(trim_scale(f.mark)::text || ' ' || f.source || ' ' || f.not_attempted order by f.mark desc) from public.script_final_marks(pg_temp.k('b1')) f),
  array['9 first false', '8 first false', '7 first false'], 'its final marks, question by question, from final_marks');

-- ---------------------------------------------------------------------------------------------
-- final_marks_cover_every_leaf_of_a_checked_script
-- ---------------------------------------------------------------------------------------------
select is((select count(*)::int from public.marking_units u cross join lateral public.marking_unit_questions(u.id) q
           where u.exam_id in (select id from kv where name in ('e', 'd', 'q', 'bq', 'sm', 'f')) and u.check_state = 'checked' and q.leaf
             and not exists (select 1 from public.final_marks f where f.unit_id = u.id and f.question_id = q.question_id)), 0,
  'final_marks_cover_every_leaf_of_a_checked_script: every leaf of every checked piece has its final mark');
select is((select count(*)::int from public.final_marks f join public.marking_units u on u.id = f.unit_id
           where u.check_state is distinct from 'checked'
              or not exists (select 1 from public.marking_unit_questions(u.id) q where q.question_id = f.question_id and q.leaf)), 0,
  'and there is no final mark but for a leaf of a checked piece');
select is((select count(*)::int from public.scripts s where s.state = 'checked'
             and s.id in (select k.id from kv k where k.name ~ '^[a-z]+[0-9]+$')
             and exists (select 1 from public.marking_units u where u.script_id = s.id and u.check_state is distinct from 'checked')), 0,
  'a checked script has every piece checked');

-- ---------------------------------------------------------------------------------------------
-- every_final_mark_write_leaves_history (controller note): the history trigger on final_marks.
-- ---------------------------------------------------------------------------------------------
select is((select count(*)::int from public.final_marks f
           where not exists (select 1 from public.final_mark_history h
                             where h.unit_id = f.unit_id and h.question_id = f.question_id and not h.removed
                               and h.mark is not distinct from f.mark and h.not_attempted = f.not_attempted and h.source = f.source
                               and h.reason = f.reason)), 0,
  'every_final_mark_write_leaves_history: every final mark has the history row of its last write');
select throws_ok(format('insert into public.final_marks (unit_id, question_id, mark, source) values (%L, %L, 1, %L)',
                        pg_temp.u('a7'), pg_temp.q('a7', '1'), 'lead'),
  'P0001', 'final_marks: every final mark needs a reason', 'a final mark written without a reason is refused');
select throws_ok(format('delete from public.final_marks where unit_id = %L', pg_temp.u('d4')),
  'P0001', 'final_marks: every removal needs a reason', 'and so is one removed without a reason');

-- ---------------------------------------------------------------------------------------------
-- lead_filter_by_marker_never_finds_a_blind_first_marker (Ruling R8): m3 first-marks a8, which waits for a second
-- marking; m3 second-marked a6.
-- ---------------------------------------------------------------------------------------------
select pg_temp.script('a8', 'e'); select pg_temp.draw('a8', 0.05); select pg_temp.first('a8', 'm3', array[1, 1, 1]);
select tests.as_user(pg_temp.uid('lead'));
insert into res values ('r8_lead', public.marking_units_list(pg_temp.k('e'), null, pg_temp.uid('m3')));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
insert into res values ('r8_admin', public.marking_units_list(pg_temp.k('e'), null, pg_temp.uid('m3')));
select tests.as_postgres();
select is(array[pg_temp.cs('a8'), pg_temp.listed(pg_temp.r('r8_lead')), pg_temp.listed(pg_temp.r('r8_admin'))],
  array['waiting_second', 'u:a6', 'u:a6,u:a8'],
  'lead_filter_by_marker_never_finds_a_blind_first_marker: filtering by m3, the lead finds a6 (m3''s second marking) but not a8, which m3 first-marked and which waits; an admin finds both');

-- ---------------------------------------------------------------------------------------------
-- question_added_after_opening_reopens_the_second_marking (controller note). Exam g second-marks every piece: g1 by m1
-- and m2, g2 by m1 and m4, both within tolerance; then m4 declares a conflict with g2's candidate. An admin adds
-- question 3.
-- ---------------------------------------------------------------------------------------------
insert into kv values ('g', tests.marking_exam(pg_temp.subj('ZZ Check')));
select tests.structure(pg_temp.k('g'));
select tests.open_marking(pg_temp.k('g'), '{"double_marking": true, "sample_percent": 100}');
select pg_temp.script('g1', 'g'); select pg_temp.first('g1', 'm1', array[2, 1, 4]); select pg_temp.second('g1', 'm2', array[2, 1, 4]);
select pg_temp.script('g2', 'g'); select pg_temp.first('g2', 'm1', array[2, 1, 4]); select pg_temp.second('g2', 'm4', array[2, 1, 4]);
insert into public.marker_conflicts (marker_id, student_id, recorded_at) values (pg_temp.uid('m4'), pg_temp.student('g2'), now());
select is(array[pg_temp.cs('g1'), pg_temp.cs('g2'), pg_temp.st('g1')], array['checked', 'checked', 'checked'],
  'question_added_after_opening_reopens_the_second_marking: g1 and g2 are checked');
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('g_save', public.exam_structure_save(pg_temp.k('g'),
  pg_temp.plus(pg_temp.draft(public.exam_structure_get(pg_temp.k('g'))), 'new3', '3', 1), 'Question 3 was left out'));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('g_save')), pg_temp.ms('g1', 'm1'), pg_temp.ms('g1', 'm2'), pg_temp.cs('g1'), pg_temp.fm('g1'), pg_temp.st('g1')],
  array['ok', 'live in_progress', 'second in_progress', '-', '', 'marking'],
  'an admin adds question 3: both of g1''s markings are reopened, it is no longer checked and has no final marks');
select is(array[pg_temp.ended('g1', 'm1'), pg_temp.ended('g1', 'm2')], array['live open,live submitted', 'second open,second submitted'],
  'each marker holds their pass again, with no time limit');
select is(array[pg_temp.ms('g2', 'm1'), pg_temp.ms('g2', 'm4'), pg_temp.ended('g2', 'm4')], array['live in_progress', 'second set_aside conflict', 'second submitted'],
  'm4, who now has a conflict with g2''s candidate, has their second marking set aside and is given nothing');
select pg_temp.first('g1', 'm1', array[2, 1, 4, 1]);
select is(pg_temp.cs('g1'), 'waiting_second', 'm1 marks question 3 and submits: g1 waits for its second marking');
select pg_temp.second('g1', 'm2', array[2, 1, 4, 1]);
select is(array[pg_temp.cs('g1'), pg_temp.fm('g1')], array['checked', '1=2 first,2(a)=1 first,2(b)=4 first,3=1 first'],
  'm2 marks it too: compared on every question, g1 is checked again');

-- ---------------------------------------------------------------------------------------------
-- question_added_to_a_settled_piece_checks_it_again (the 3B ledger's R9): g3 is second-marked by m1 and m3 within
-- tolerance and the lead settled it (first marks stand) after it came in; an admin then adds question 4.
-- ---------------------------------------------------------------------------------------------
select pg_temp.script('g3', 'g'); select pg_temp.first('g3', 'm1', array[2, 1, 4, 1]); select pg_temp.second('g3', 'm3', array[2, 1, 4, 1]);
update public.markings set submitted_at = now() - interval '2 hours' where id in (pg_temp.k('f:g3'), pg_temp.k('s:g3'));
insert into public.marking_reviews (exam_id, unit_id, kind, marking_id, second_marking_id, state, outcome, reason, opened_at, closed_by, closed_at)
values (pg_temp.k('g'), pg_temp.u('g3'), 'difference', pg_temp.k('f:g3'), pg_temp.k('s:g3'), 'closed', 'first_stands', 'First marks stand',
        now() - interval '90 minutes', pg_temp.uid('lead'), now() - interval '1 hour');
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('g_save4', public.exam_structure_save(pg_temp.k('g'),
  pg_temp.plus(pg_temp.draft(public.exam_structure_get(pg_temp.k('g'))), 'new4', '4', 1), 'Question 4 was left out'));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('g_save4')), pg_temp.ms('g3', 'm1'), pg_temp.ms('g3', 'm3'), pg_temp.cs('g3'), pg_temp.fm('g3')],
  array['ok', 'live in_progress', 'second in_progress', '-', ''],
  'question_added_to_a_settled_piece_checks_it_again: an admin adds question 4: both of g3''s markings are reopened and it is no longer checked');
select pg_temp.first('g3', 'm1', array[2, 1, 4, 1, 1]);
select is(pg_temp.cs('g3'), 'waiting_second',
  'm1 marks question 4 and submits: the settle was of the earlier submission, so g3 waits for its second marking again');
select pg_temp.second('g3', 'm3', array[2, 1, 4, 1, 1]);
select is(array[pg_temp.cs('g3'), pg_temp.fm('g3')], array['checked', '1=2 first,2(a)=1 first,2(b)=4 first,3=1 first,4=1 first'],
  'm3 marks it too: compared again, g3 is checked with a final mark for every question');

-- ---------------------------------------------------------------------------------------------
-- first_and_second_marks_are_never_changed_by_the_check: every marking of these exams, before and after the check runs
-- again over exam e and each of their pieces is looked at again.
-- ---------------------------------------------------------------------------------------------
create temp table snap as
select m.id, m.rev, m.status, (select string_agg(q.question_id || '=' || coalesce(q.mark::text, 'NR'), ',' order by q.question_id)
                                from public.question_marks q where q.marking_id = m.id) as marks
from public.markings m join public.marking_units u on u.id = m.unit_id
where u.exam_id in (select id from kv where name in ('e', 'd', 'q', 'bq', 'sm', 'f', 'g'));
select public.marking_check_exam(pg_temp.k('e'));
select public.marking_check_evaluate(u.id) from public.marking_units u
where u.exam_id in (select id from kv where name in ('e', 'd', 'q', 'bq', 'sm', 'f', 'g')) order by u.id;
select is((select count(*)::int from snap s join public.markings m on m.id = s.id
           where (m.rev, m.status, (select string_agg(q.question_id || '=' || coalesce(q.mark::text, 'NR'), ',' order by q.question_id)
                                    from public.question_marks q where q.marking_id = m.id)) is distinct from (s.rev, s.status, s.marks)), 0,
  'first_and_second_marks_are_never_changed_by_the_check: no marking''s marks, rev or status changed');
select is(array[pg_temp.marks('f:a2'), pg_temp.marks('s:a2'), pg_temp.marks('f:a4'), pg_temp.marks('s:a4')],
  array['1=0,2(a)=1,2(b)=4', '1=2,2(a)=1,2(b)=3', '1=2,2(a)=1,2(b)=4', '1=0,2(a)=1,2(b)=4'],
  'the first and second marks are exactly what their markers gave');
select is(array[pg_temp.cs('a2'), pg_temp.cs('a4'), pg_temp.cs('a6'), pg_temp.cs('a8'), pg_temp.reviews('a4')],
  array['to_lead', 'to_lead', 'checked', 'waiting_second', 'difference open'], 'and each piece is where it was');

-- ---------------------------------------------------------------------------------------------
-- review_is_withdrawn_when_a_marking_it_compares_is_taken_back: a4 and a2 are with the lead.
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('tb_s4', public.marking_take_back(array[pg_temp.u('a4')], 'The second marker misread the scheme', 'second'));
insert into res values ('tb_f2', public.marking_take_back(array[pg_temp.u('a2')], 'The first marker misread the scheme'));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('tb_s4')), pg_temp.reviews('a4'), pg_temp.ms('a4', 'm2'), pg_temp.cs('a4'), pg_temp.st('a4')],
  array['ok', 'difference closed withdrawn', 'second set_aside taken_back', 'waiting_second', 'marked'],
  'review_is_withdrawn_when_a_marking_it_compares_is_taken_back: an admin takes back a4''s second marking: its difference is withdrawn and it waits for another');
select is(array[pg_temp.code(pg_temp.r('tb_f2')), pg_temp.reviews('a2'), pg_temp.cs('a2'), pg_temp.fm('a2'), pg_temp.st('a2')],
  array['ok', 'difference closed withdrawn', '-', '', 'marking'],
  'an admin takes back a2''s first marking: its difference is withdrawn and it has no check state until it is marked again');

-- ---------------------------------------------------------------------------------------------
-- checks_set_in_time_at_1500_pieces (a timing guard, as 043 and 056, Phase 3A Ruling R25: the fixture tables are
-- analysed first). Exam big of 'ZZ Check Big' (one approved marker) is marked by question in 5 groups and has 300
-- scripts: each of the 1,500 pieces is first-marked (written as postgres) and waits for a second marking. An admin turns
-- double marking off, under the 4-second limit of a list.
-- ---------------------------------------------------------------------------------------------
insert into public.subjects (name, kind) values ('ZZ Check Big', 'school');
insert into c values ('mbig', tests.marker(pg_temp.subj('ZZ Check Big')));
insert into kv values ('big', tests.marking_exam(pg_temp.subj('ZZ Check Big')));
insert into public.question_groups (exam_id, label, position) select pg_temp.k('big'), 'B' || i, i from generate_series(1, 5) i;
insert into public.exam_questions (exam_id, label, position, max_mark, pages, group_id)
select g.exam_id, g.position::text, g.position, 5, '{1}', g.id from public.question_groups g where g.exam_id = pg_temp.k('big');
do $$ begin for i in 1..300 loop perform tests.verified_script(pg_temp.k('big')); end loop; end $$;
update public.exam_marking set mode = 'by_question' where exam_id = pg_temp.k('big');
select tests.open_marking(pg_temp.k('big'), '{"double_marking": true, "sample_percent": 100}');
insert into public.markings (unit_id, kind, marker_id, status, total, last_saved_at, submitted_at)
select u.id, 'live', pg_temp.uid('mbig'), 'submitted', 1, now(), now() from public.marking_units u where u.exam_id = pg_temp.k('big');
insert into public.question_marks (marking_id, question_id, mark)
select m.id, q.id, 1 from public.markings m join public.marking_units u on u.id = m.unit_id
join public.exam_questions q on q.group_id = u.group_id where u.exam_id = pg_temp.k('big');
update public.marking_units set state = 'submitted', second_wanted = true, check_state = 'waiting_second' where exam_id = pg_temp.k('big');
update public.scripts set state = 'marked' where exam_id = pg_temp.k('big');
analyze public.scripts, public.marking_units, public.markings, public.question_marks, public.final_marks, public.final_mark_history,
        public.marking_reviews, public.marking_assignments, public.exam_questions, public.question_groups, public.exam_option_groups,
        public.exam_markers, public.exam_marking, public.marker_approvals, public.profiles, public.audit_log;
select tests.as_user(pg_temp.uid('admin'));
set local statement_timeout = '4s';
insert into res values ('big_off', public.marking_checks_set(pg_temp.k('big'), '{"double_marking": false, "sample_percent": 100,
  "tolerance_percent": 10, "seeds": false, "seed_every": 10, "practice": false}', 'One marker for this subject'));
reset statement_timeout;
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('big_off')),
                (select count(*)::text from public.marking_units u where u.exam_id = pg_temp.k('big') and u.check_state = 'checked'),
                (select count(*)::text from public.scripts s where s.exam_id = pg_temp.k('big') and s.state = 'checked'),
                (select count(*)::text from public.final_marks f join public.marking_units u on u.id = f.unit_id where u.exam_id = pg_temp.k('big'))],
  array['ok', '1500', '300', '1500'],
  'checks_set_in_time_at_1500_pieces: turning double marking off checks the 1,500 waiting pieces, with their final marks, within 4 s');

-- ---------------------------------------------------------------------------------------------
-- new_functions_are_internal_but_add_and_drop
-- ---------------------------------------------------------------------------------------------
select is(array(select f from unnest(array['public.marking_tolerance(numeric, integer)', 'public.marking_compare_sets(uuid, jsonb, jsonb)',
                  'public.marking_compare(uuid, uuid)', 'public.marking_check_evaluate(uuid)', 'public.marking_check_exam(uuid)',
                  'public.marking_second_stuck(uuid)', 'public.script_final_marks(uuid)', 'public.script_final_total(uuid)',
                  'public.marking_unit_settled(uuid)', 'public.marking_final_marks_from(uuid, uuid, text)',
                  'public.marking_final_marks_remove(uuid, text)', 'public.marking_second_release(uuid, text)',
                  'public.marking_set_total(uuid, jsonb)']) f
                where has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute')
                   or has_function_privilege('service_role', f, 'execute')),
  '{}'::text[], 'new_functions_are_internal_but_add_and_drop: the check''s helpers are for definer functions only');
select is(array[has_function_privilege('authenticated', 'public.marking_second_add(uuid[], text)', 'execute'),
                has_function_privilege('authenticated', 'public.marking_second_drop(uuid[], text)', 'execute'),
                has_function_privilege('anon', 'public.marking_second_add(uuid[], text)', 'execute'),
                has_function_privilege('anon', 'public.marking_second_drop(uuid[], text)', 'execute')],
  array[true, true, false, false], '"Second-mark these" and its release are for signed-in users');

select * from finish();
rollback;
