begin;
create extension if not exists pgtap with schema extensions;
select plan(32);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Subject 'ZZ Appr': markers m1 to m4 and the lead marker; 'ZZ Appr Small': its one marker x1 and no lead.
-- admin (named Agatha Approver), a teacher and a corrector never approved. Every exam has the test structure (1 of 3
-- marks, 2(a) of 2, 2(b) of 5).
--   a1: c1 checked, c2 to mark; wd withdrawn and vd void; a paid booking with no script, and a cancelled one.
--   a2: cc1 checked; na1 needs attention, lt1 came in late and nobody decided, v1 verified and not handed out yet.
--   b:  double marking on (10%, 10% tolerance), seeded scripts on (one in 50), practice off. Second-marked (draw 0.01):
--       d1 to d3 (m1's first 1,1,1; m2's second 3,2,5: each differs), d4 (the lead's first, m1's second: differs), k1 (m1;
--       m2's second 1,1,1 is within), w1 (m1; waits), p1 (m3, whom the lead then pauses: to the lead). Not second-marked
--       (0.99): s1 and f1 (m1), sd1 and sd2 (the lead's). sd1 is a seeded script (the lead made it so); sd2 a practice
--       script, written as postgres; sd1 has three attempts: m1's within, m2's outside and m4's in progress.
--   c:  h1 to h3 checked (m1), hw withdrawn with an open alert.
--   mx: mf1 (m1) and ms1 (the lead's) checked, for the maximum rule.
--   s:  ('ZZ Appr Small') the checks were on; the admin turned all three off with a reason, then marking opened. t1
--       marked by x1.
--   pc: g1 marked by m4; then admin2 closed marking. no: marking never opened.
--   big: ('ZZ Appr Big') the timing guard's exam, at the end.
-- A piece is kept as 'u:<script>', its first marking as 'f:<piece>' and its second as 's:<piece>'.
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
-- A piece's check state ('-' for none); a script's state.
create function pg_temp.cs(p text) returns text language sql stable security definer as $$
  select coalesce(check_state, '-') from public.marking_units where id = pg_temp.u(p) $$;
create function pg_temp.st(p text) returns text language sql stable security definer as $$
  select s.state::text from public.scripts s where s.id = pg_temp.k(p) $$;
-- A marking's rev; the latest review of a kind on a piece (an open one first).
create function pg_temp.rev(p text) returns int language sql stable security definer as $$
  select rev from public.markings where id = pg_temp.k(p) $$;
create function pg_temp.rv(p text, p_kind text) returns uuid language sql stable security definer as $$
  select r.id from public.marking_reviews r where r.unit_id = pg_temp.u(p) and r.kind = p_kind
  order by r.state = 'open' desc, r.opened_at desc, r.id limit 1 $$;
-- A question of a piece by its label ('1', '2(a)', '2(b)'), and an entry of a set of marks.
create function pg_temp.q(p text, p_label text) returns uuid language sql stable security definer as $$
  select q.question_id from public.marking_unit_questions(pg_temp.u(p)) q where q.label = p_label $$;
create function pg_temp.mk(p text, p_label text, p_mark numeric) returns jsonb language sql stable as $$
  select jsonb_build_object('question_id', pg_temp.q(p, p_label), 'mark', p_mark, 'na', false) $$;
create function pg_temp.ops(p_unit uuid, p_marks numeric[]) returns jsonb language sql stable security definer as $$
  select jsonb_agg(jsonb_build_object('op', 'mark', 'question_id', q.question_id, 'mark', coalesce(p_marks[q.n], 0), 'na', false) order by q.n)
  from (select t.question_id, row_number() over (order by t.path) as n from public.marking_unit_questions(p_unit) t where t.leaf) q $$;
-- The top-level keys of an answer, sorted; the words of p_words that a text holds; an answer's blocks ('code count').
create function pg_temp.keys(j jsonb) returns text language sql immutable as $$
  select array_to_string(array(select k from jsonb_object_keys(j) k order by 1), ',') $$;
create function pg_temp.found(p_words text[], p_text text) returns text[] language sql immutable as $$
  select array(select w from unnest(p_words) w where position(lower(w) in lower(p_text)) > 0) $$;
create function pg_temp.blocks(j jsonb) returns text language sql immutable as $$
  select coalesce(string_agg((x ->> 'code') || ' ' || (x ->> 'count'), ',' order by o), '')
  from jsonb_array_elements(j -> 'blocks') with ordinality t(x, o) $$;
create function pg_temp.audits(p_action text, p_target uuid) returns int language sql stable security definer as $$
  select count(*)::int from public.audit_log a where a.action = p_action and a.target_id = p_target $$;
create function pg_temp.reason(p_action text, p_target uuid) returns text language sql stable security definer as $$
  select coalesce(a.reason, 'none') from public.audit_log a where a.action = p_action and a.target_id = p_target order by a.id desc limit 1 $$;
-- A new verified home script of an exam, its piece, with its stored draw (0.99 unless given).
create function pg_temp.script(p_name text, p_exam text, p_draw double precision default 0.99) returns void language plpgsql as $$
begin
  insert into kv values (p_name, tests.verified_script(pg_temp.k(p_exam), 'home'));
  perform public.marking_exam_sync(pg_temp.k(p_exam), null);
  insert into kv select 'u:' || p_name, u.id from public.marking_units u where u.script_id = pg_temp.k(p_name) on conflict (name) do nothing;
  update public.marking_units set sample_draw = p_draw where script_id = pg_temp.k(p_name);
end $$;
-- Signed in as someone: a call's answer (p_sql is run as that user).
create function pg_temp.as(p_who text, p_sql text) returns jsonb language plpgsql as $$
declare
  v_r jsonb;
begin
  perform tests.as_user(pg_temp.uid(p_who));
  execute p_sql into v_r;
  perform tests.as_postgres();
  return v_r;
end $$;
-- The live marking of a piece by a marker (tests.mark_piece), kept as 'f:<piece>'.
create function pg_temp.first(p text, p_marker text, p_marks numeric[]) returns void language plpgsql as $$
begin
  insert into kv values ('f:' || p, tests.mark_piece(pg_temp.u(p), pg_temp.uid(p_marker), p_marks))
  on conflict (name) do update set id = excluded.id;
end $$;
-- Signed in as the marker, who holds the piece: open it, save p_marks and submit. Kept as kv p_key; the submit's answer.
create function pg_temp.mark(p_marker text, p_unit uuid, p_marks numeric[], p_key text) returns jsonb language plpgsql as $$
declare
  v_ops jsonb := pg_temp.ops(p_unit, p_marks);
  v_r jsonb;
  v_mk uuid;
begin
  perform tests.as_user(pg_temp.uid(p_marker));
  v_r := public.marking_unit_open(p_unit);
  v_mk := (v_r #>> '{marking,id}')::uuid;
  v_r := public.marking_save(v_mk, (v_r #>> '{marking,rev}')::int, v_ops);
  v_r := public.marking_submit(v_mk, (v_r ->> 'rev')::int);
  perform tests.as_postgres();
  insert into kv values (p_key, v_mk) on conflict (name) do update set id = excluded.id;
  return v_r;
end $$;
-- A second marking of a piece: its second pass taken as Next script would, then marked and submitted.
create function pg_temp.second(p text, p_marker text, p_marks numeric[]) returns void language plpgsql as $$
declare
  v_why text := public.marking_unit_blocked(pg_temp.u(p), pg_temp.uid(p_marker), null, true, 'second');
begin
  if v_why is not null then
    raise exception 'pg_temp.second: % cannot be given the second pass (%)', p_marker, v_why;
  end if;
  perform public.marking_unit_take(pg_temp.u(p), pg_temp.uid(p_marker), 'next', null, now() + interval '2 hours', 'second');
  if pg_temp.code(pg_temp.mark(p_marker, pg_temp.u(p), p_marks, 's:' || p)) <> 'ok' then
    raise exception 'pg_temp.second: the submit was refused';
  end if;
end $$;
-- Signed in as someone: settle a piece's difference at the markings' current revs.
create function pg_temp.settle(p_who text, p text, p_outcome text, p_reason text, p_marks jsonb default null) returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.marking_review_settle(%L, %L, %s, %s, %L, %L::jsonb)',
    pg_temp.rv(p, 'difference'), p_outcome, pg_temp.rev('f:' || p), pg_temp.rev('s:' || p), p_reason, p_marks)) $$;
-- The approval functions, signed in as someone.
create function pg_temp.get(p_who text, p_exam text) returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.marking_approval_get(%L)', pg_temp.k(p_exam))) $$;
create function pg_temp.approve(p_who text, p_exam text, p_note text default null) returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.marking_approve(%L, %L)', pg_temp.k(p_exam), p_note)) $$;
create function pg_temp.withdraw(p_who text, p_exam text, p_reason text) returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.marking_approval_withdraw(%L, %L)', pg_temp.k(p_exam), p_reason)) $$;
-- A structure as exam_structure_save takes it, from exam_structure_get's answer (as 052); one question changed.
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
create function pg_temp.edit(d jsonb, p_id uuid, p_patch jsonb) returns jsonb language sql immutable as $$
  select jsonb_set(d, '{questions}', (select jsonb_agg(case when x ->> 'id' = p_id::text then x || p_patch else x end order by o)
                                      from jsonb_array_elements(d -> 'questions') with ordinality t(x, o))) $$;
-- An admin's structure save of an exam with one question of p_piece's changed.
create function pg_temp.save(p_exam text, p_piece text, p_label text, p_patch jsonb, p_reason text) returns jsonb language plpgsql as $$
declare
  v_s jsonb := pg_temp.as('admin', format('select public.exam_structure_get(%L)', pg_temp.k(p_exam)));
begin
  return pg_temp.as('admin', format('select public.exam_structure_save(%L, %L::jsonb, %L)', pg_temp.k(p_exam),
    pg_temp.edit(pg_temp.draft(v_s), pg_temp.q(p_piece, p_label), p_patch), p_reason));
end $$;

insert into public.subjects (name, kind) values ('ZZ Appr', 'school'), ('ZZ Appr Small', 'school');
insert into c values ('admin', tests.create_user('admin', 'active')), ('corr', tests.create_user('corrector', 'active')),
  ('teacher', tests.create_user('teacher', 'active')), ('admin2', tests.create_user('admin', 'active'));
insert into c select 'm' || i, tests.marker(pg_temp.subj('ZZ Appr')) from generate_series(1, 4) i;
insert into c values ('lead', tests.marker(pg_temp.subj('ZZ Appr'), true)), ('x1', tests.marker(pg_temp.subj('ZZ Appr Small')));
update public.profiles set first_name = 'Agatha', last_name = 'Approver' where id = pg_temp.uid('admin');
update public.profiles set first_name = 'Ermengarde', last_name = 'Leadbetter' where id = pg_temp.uid('lead');

insert into kv select x, tests.marking_exam(pg_temp.subj('ZZ Appr')) from unnest(array['a1', 'a2', 'b', 'c', 'mx', 'pc', 'no']) x;
insert into kv values ('s', tests.marking_exam(pg_temp.subj('ZZ Appr Small')));
select tests.structure(pg_temp.k(x)) from unnest(array['a1', 'a2', 'b', 'c', 'mx', 'pc', 'no', 's']) x;
select tests.open_marking(pg_temp.k(x)) from unnest(array['a1', 'a2', 'c', 'mx', 'pc']) x;
select tests.open_marking(pg_temp.k('b'),
  '{"double_marking": true, "sample_percent": 10, "tolerance_percent": 10, "seeds": true, "seed_every": 50, "practice": false}');
update public.exam_marking set double_marking = true, seeds = true, practice = true where exam_id = pg_temp.k('s');
insert into res values ('off_s', pg_temp.as('admin', format($q$ select public.marking_checks_set(%L,
  '{"double_marking": false, "sample_percent": 10, "tolerance_percent": 10, "seeds": false, "seed_every": 10, "practice": false}'::jsonb,
  'Only one marker this term.') $q$, pg_temp.k('s'))));
select tests.open_marking(pg_temp.k('s'));

-- Exam a1.
select pg_temp.script(x, 'a1') from unnest(array['c1', 'c2', 'wd', 'vd']) x;
select pg_temp.first('c1', 'm1', array[1, 1, 1]);
update public.scripts set state = 'withdrawn' where id = pg_temp.k('wd');
update public.scripts set state = 'void' where id = pg_temp.k('vd');
with st as (select tests.create_user('student', 'active') as id, 'paid'::public.booking_status as status
            union all select tests.create_user('student', 'active'), 'cancelled'::public.booking_status)
insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting)
select pg_temp.k('a1'), st.id, st.id, st.status, 0, 'home' from st;

-- Exam a2.
select pg_temp.script('cc1', 'a2');
select pg_temp.first('cc1', 'm1', array[1, 1, 1]);
insert into kv values ('na1', tests.verified_script(pg_temp.k('a2'), 'home')), ('lt1', tests.verified_script(pg_temp.k('a2'), 'home'));
update public.scripts set state = 'needs_attention' where id = pg_temp.k('na1');
update public.scripts set late = true where id = pg_temp.k('lt1');
select public.marking_exam_sync(pg_temp.k('a2'), null);
insert into kv values ('v1', tests.verified_script(pg_temp.k('a2'), 'home'));

-- Exam b.
select pg_temp.script(x, 'b', 0.01) from unnest(array['d1', 'd2', 'd3', 'd4', 'k1', 'w1', 'p1']) x;
select pg_temp.script(x, 'b') from unnest(array['s1', 'f1', 'sd1', 'sd2']) x;
select pg_temp.first(x, 'm1', array[1, 1, 1]) from unnest(array['d1', 'd2', 'd3', 'k1', 'w1', 's1', 'f1']) x;
select pg_temp.first('d4', 'lead', array[1, 1, 1]);
select pg_temp.first(x, 'lead', array[3, 2, 5]) from unnest(array['sd1', 'sd2']) x;
select pg_temp.first('p1', 'm3', array[1, 1, 1]);
select pg_temp.second(x, 'm2', array[3, 2, 5]) from unnest(array['d1', 'd2', 'd3']) x;
select pg_temp.second('k1', 'm2', array[1, 1, 1]);
select pg_temp.second('d4', 'm1', array[3, 2, 5]);
insert into res values ('pause_m3', pg_temp.as('lead', format($q$ select public.marking_marker_pause(%L, %L, 'Three scripts look harsh.') $q$,
  pg_temp.k('b'), pg_temp.uid('m3'))));
insert into res values ('seed_sd1', pg_temp.as('lead', format($q$ select public.marking_standard_set(%L, 'seed') $q$, pg_temp.u('sd1'))));
with st as (insert into public.marking_standards (exam_id, unit_id, use, set_by)
            values (pg_temp.k('b'), pg_temp.u('sd2'), 'practice', pg_temp.uid('lead')) returning id)
insert into public.marking_standard_marks (standard_id, question_id, mark)
select st.id, m.question_id, m.mark from st, public.question_marks m where m.marking_id = pg_temp.k('f:sd2');
insert into public.markings (unit_id, kind, marker_id, status, rev, total, submitted_at, feedback_at)
values (pg_temp.u('sd1'), 'seed', pg_temp.uid('m1'), 'submitted', 1, 10, now(), null),
       (pg_temp.u('sd1'), 'seed', pg_temp.uid('m2'), 'submitted', 1, 3, now(), now()),
       (pg_temp.u('sd1'), 'seed', pg_temp.uid('m4'), 'in_progress', 0, null, null, null);

-- Exam c.
select pg_temp.script(x, 'c') from unnest(array['h1', 'h2', 'h3', 'hw']) x;
select pg_temp.first(x, 'm1', array[1, 1, 1]) from unnest(array['h1', 'h2', 'h3']) x;
update public.scripts set state = 'withdrawn' where id = pg_temp.k('hw');
insert into public.marking_alerts (exam_id, kind, script_id, unit_id, state)
values (pg_temp.k('c'), 'pages_changed', pg_temp.k('hw'), pg_temp.u('hw'), 'open');

-- Exam mx.
select pg_temp.script(x, 'mx') from unnest(array['mf1', 'ms1']) x;
select pg_temp.first('mf1', 'm1', array[1, 1, 1]);
select pg_temp.first('ms1', 'lead', array[1, 1, 1]);

-- Exam s.
select pg_temp.script('t1', 's');
select pg_temp.first('t1', 'x1', array[1, 1, 1]);

-- Exam pc: g1 marked by m4; then a second admin closes marking. Exam no: marking never opened.
select pg_temp.script('g1', 'pc');
select pg_temp.first('g1', 'm4', array[1, 1, 1]);
insert into res values ('close_pc', pg_temp.as('admin2', format($q$ select public.marking_close(%L, 'Marking is finished.') $q$, pg_temp.k('pc'))));

select is(array[pg_temp.code(pg_temp.r('off_s')), pg_temp.st('c1'), pg_temp.st('c2'), pg_temp.st('wd'), pg_temp.st('vd'),
    pg_temp.st('cc1'), pg_temp.st('na1'), pg_temp.st('lt1'), pg_temp.st('v1'),
    pg_temp.code(pg_temp.r('pause_m3')), pg_temp.code(pg_temp.r('seed_sd1')),
    pg_temp.cs('d1'), pg_temp.cs('d4'), pg_temp.cs('p1'), pg_temp.cs('k1'), pg_temp.cs('w1'), pg_temp.cs('s1'), pg_temp.cs('sd1'),
    pg_temp.st('h3'), pg_temp.st('hw'), pg_temp.st('mf1'), pg_temp.st('ms1'), pg_temp.st('t1'), pg_temp.st('g1'),
    pg_temp.code(pg_temp.r('close_pc'))],
  array['ok', 'checked', 'ready_to_mark', 'withdrawn', 'void', 'checked', 'needs_attention', 'verified', 'verified',
    'ok', 'ok', 'to_lead', 'to_lead', 'to_lead', 'checked', 'waiting_second', 'checked', 'checked',
    'checked', 'withdrawn', 'checked', 'checked', 'checked', 'checked', 'ok'],
  'fixtures: the scripts and pieces are as described');

-- ---------------------------------------------------------------------------------------------
-- teacher_lead_and_corrector_cannot_approve_or_read
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.code(pg_temp.get('teacher', 'b')), pg_temp.code(pg_temp.get('lead', 'b')), pg_temp.code(pg_temp.get('corr', 'b')),
    pg_temp.code(pg_temp.get('m1', 'b')),
    pg_temp.code(pg_temp.approve('teacher', 'b')), pg_temp.code(pg_temp.approve('lead', 'b')), pg_temp.code(pg_temp.approve('corr', 'b')),
    pg_temp.code(pg_temp.withdraw('teacher', 'b', 'Wrongly approved')), pg_temp.code(pg_temp.withdraw('lead', 'b', 'Wrongly approved')),
    pg_temp.code(pg_temp.withdraw('corr', 'b', 'Wrongly approved')),
    pg_temp.code(pg_temp.as('admin', format('select public.marking_approval_get(%L)', gen_random_uuid()))),
    pg_temp.code(pg_temp.as('admin', 'select public.marking_approval_get(null)')),
    pg_temp.code(pg_temp.as('admin', format('select public.marking_approve(%L)', gen_random_uuid()))),
    pg_temp.code(pg_temp.as('admin', format('select public.marking_approval_withdraw(%L, %L)', gen_random_uuid(), 'No such exam'))),
    pg_temp.code(pg_temp.approve('admin', 'b', repeat('x', 301))), pg_temp.code(pg_temp.approve('admin', 'b', ' ab ')),
    pg_temp.code(pg_temp.approve('admin', 'no'))],
  array['forbidden', 'forbidden', 'forbidden', 'forbidden', 'forbidden', 'forbidden', 'forbidden', 'forbidden', 'forbidden', 'forbidden',
    'not_found', 'invalid_input', 'not_found', 'not_found', 'invalid_input', 'invalid_input', 'marking_not_open'],
  'teacher_lead_and_corrector_cannot_approve_or_read: a teacher, the lead, a corrector and a marker are forbidden; an unknown exam is not_found; a note, when given, is 3 to 300 characters; an exam whose marking never opened is not approved (marking_not_open)');
select is(array[(select count(*)::int from public.audit_log a
                 where a.action in ('marking_approved', 'marking_approval_withdrawn') and a.target_id in (select id from kv)),
    (select count(*)::int from public.exam_marking m where m.exam_id in (select id from kv) and m.approved_at is not null)],
  array[0, 0], 'nothing was approved and nothing written');
select is(array[has_function_privilege('authenticated', 'public.marking_exam_frozen(uuid)', 'execute'),
    has_function_privilege('service_role', 'public.marking_exam_frozen(uuid)', 'execute'),
    has_function_privilege('authenticated', 'public.marking_approval_blocks(uuid)', 'execute'),
    has_function_privilege('service_role', 'public.marking_approval_blocks(uuid)', 'execute'),
    has_function_privilege('anon', 'public.marking_approval_blocks(uuid)', 'execute'),
    has_function_privilege('authenticated', 'public.marking_tick()', 'execute'),
    has_function_privilege('anon', 'public.marking_approval_get(uuid)', 'execute'),
    has_function_privilege('anon', 'public.marking_approve(uuid, text)', 'execute'),
    has_function_privilege('anon', 'public.marking_approval_withdraw(uuid, text)', 'execute'),
    has_function_privilege('authenticated', 'public.marking_approval_get(uuid)', 'execute'),
    has_function_privilege('authenticated', 'public.marking_approve(uuid, text)', 'execute'),
    has_function_privilege('authenticated', 'public.marking_approval_withdraw(uuid, text)', 'execute')],
  array[false, false, false, false, false, false, false, false, false, true, true, true],
  'the internal freeze check, the blocks and the minute job are for definer functions only; the approval functions are for signed-in users, never anon');

-- ---------------------------------------------------------------------------------------------
-- approve_needs_every_script_checked
-- ---------------------------------------------------------------------------------------------
insert into res values ('a1_blocked', pg_temp.approve('admin', 'a1'));
insert into res values ('a1_get', pg_temp.get('admin', 'a1'));
select is(array[pg_temp.code(pg_temp.r('a1_blocked')), pg_temp.blocks(pg_temp.r('a1_blocked')), pg_temp.r('a1_blocked') #>> '{blocks,0,with_staff}',
    (select (m.approved_at is null and m.closed_at is null)::text from public.exam_marking m where m.exam_id = pg_temp.k('a1')),
    pg_temp.audits('marking_approved', pg_temp.k('a1'))::text,
    pg_temp.r('a1_get') ->> 'can_approve', pg_temp.blocks(pg_temp.r('a1_get')), pg_temp.r('a1_get') ->> 'opened'],
  array['not_all_checked', 'scripts_not_checked 1', '0', 'true', '0', 'false', 'scripts_not_checked 1', 'true'],
  'approve_needs_every_script_checked: c2 is not marked yet: refused, saying what blocks; nothing changes; the page says the same');
select pg_temp.first('c2', 'm1', array[1, 1, 1]);
insert into res values ('a1_ok', pg_temp.approve('admin', 'a1'));
select is(array[pg_temp.code(pg_temp.r('a1_ok')), pg_temp.r('a1_ok') ->> 'already', pg_temp.r('a1_ok') ->> 'closed',
    (select (m.approved_by = pg_temp.uid('admin') and m.approved_at is not null and m.closed_by = pg_temp.uid('admin')
             and m.closed_at = m.approved_at)::text from public.exam_marking m where m.exam_id = pg_temp.k('a1')),
    pg_temp.audits('marking_approved', pg_temp.k('a1'))::text, pg_temp.reason('marking_approved', pg_temp.k('a1'))],
  array['ok', 'false', 'true', 'true', '1', 'none'],
  'once every script is checked the admin approves: marking closes at the same moment, by them; no note and no check turned off with a reason, so the audit row has no reason');

-- ---------------------------------------------------------------------------------------------
-- withdrawn_and_void_scripts_do_not_block_and_are_counted
-- ---------------------------------------------------------------------------------------------
insert into res values ('a1_after', pg_temp.get('admin', 'a1'));
select is(array[pg_temp.r('a1_after') #>> '{scripts,checked}', pg_temp.r('a1_after') #>> '{scripts,withdrawn}',
    pg_temp.r('a1_after') #>> '{scripts,void}', pg_temp.r('a1_after') #>> '{scripts,other}', pg_temp.r('a1_after') ->> 'no_script',
    pg_temp.blocks(pg_temp.r('a1_after')), pg_temp.r('a1_after') ->> 'stale', pg_temp.r('a1_after') ->> 'approved_by_name',
    (select count(*)::text from public.marking_units u where u.script_id in (pg_temp.k('wd'), pg_temp.k('vd')) and u.on_hold)],
  array['2', '1', '1', '0', '1', '', 'false', 'Agatha Approver', '2'],
  'withdrawn_and_void_scripts_do_not_block_and_are_counted: 2 checked, 1 withdrawn, 1 void; their pieces on hold block nothing; 1 paid booking has no script (the cancelled one is not counted)');

-- ---------------------------------------------------------------------------------------------
-- a_script_still_with_staff_blocks
-- ---------------------------------------------------------------------------------------------
insert into res values ('a2', pg_temp.get('admin', 'a2'));
insert into res values ('a2_ap', pg_temp.approve('admin', 'a2'));
select is(array[pg_temp.blocks(pg_temp.r('a2')), pg_temp.r('a2') #>> '{blocks,0,with_staff}', pg_temp.r('a2') #>> '{scripts,other}',
    pg_temp.r('a2') #>> '{scripts,checked}', pg_temp.code(pg_temp.r('a2_ap')), pg_temp.blocks(pg_temp.r('a2_ap'))],
  array['scripts_not_checked 3', '3', '3', '1', 'not_all_checked', 'scripts_not_checked 3'],
  'a_script_still_with_staff_blocks: a script that needs attention, a late one nobody decided and a verified one not handed out yet each block, all still with staff');

-- ---------------------------------------------------------------------------------------------
-- piece_with_the_lead_or_waiting_for_a_second_blocks
-- ---------------------------------------------------------------------------------------------
insert into res values ('b1', pg_temp.get('admin', 'b'));
insert into res values ('b1_ap', pg_temp.approve('admin', 'b'));
select is(array[pg_temp.blocks(pg_temp.r('b1')), pg_temp.r('b1') #>> '{blocks,0,with_staff}', pg_temp.r('b1') ->> 'can_approve',
    pg_temp.code(pg_temp.r('b1_ap')), pg_temp.blocks(pg_temp.r('b1_ap'))],
  array['scripts_not_checked 6,with_lead 5,waiting_second 1', '0', 'false', 'not_all_checked',
    'scripts_not_checked 6,with_lead 5,waiting_second 1'],
  'piece_with_the_lead_or_waiting_for_a_second_blocks: d1 to d4 and paused m3''s p1 are with the lead, w1 waits for a second marker');

-- The lead settles each difference (d4, where the lead was the first marker, too), accepts p1, sends s1 back to m1 (who
-- marks it again) and changes a final mark of f1; an admin releases w1; then the lead samples one of m1's scripts.
insert into res values ('st_d1', pg_temp.settle('lead', 'd1', 'first_stands', 'The first marks are right.'));
insert into res values ('st_d2', pg_temp.settle('lead', 'd2', 'second_stands', 'The second marks are right.'));
insert into res values ('st_d3', pg_temp.settle('lead', 'd3', 'lead_marks', 'Both were some way off.',
  jsonb_build_array(pg_temp.mk('d3', '1', 2), pg_temp.mk('d3', '2(a)', 2), pg_temp.mk('d3', '2(b)', 3))));
insert into res values ('st_d4', pg_temp.settle('lead', 'd4', 'first_stands', 'My first marks stand.'));
insert into res values ('acc_p1', pg_temp.as('lead', format('select public.marking_review_accept(%L)', pg_temp.rv('p1', 'paused_marker'))));
insert into res values ('drop_w1', pg_temp.as('admin', format($q$ select public.marking_second_drop(array[%L]::uuid[], 'Nobody can take it.') $q$,
  pg_temp.u('w1'))));
insert into res values ('sb_s1', pg_temp.as('lead', format($q$ select public.marking_send_back(%L, 'same', 'Look again at question 2.',
  'Question 2 looks harsh.') $q$, pg_temp.u('s1'))));
insert into res values ('re_s1', pg_temp.mark('m1', pg_temp.u('s1'), array[1, 2, 2], 'f:s1'));
insert into res values ('fs_f1', pg_temp.as('lead', format($q$ select public.marking_final_set(%L, %L::jsonb, 'Question 1 was misread.') $q$,
  pg_temp.u('f1'), jsonb_build_array(pg_temp.mk('f1', '1', 2)))));
insert into res values ('sample', pg_temp.as('lead', format('select public.marking_review_sample(%L, %L, 1)', pg_temp.k('b'), pg_temp.uid('m1'))));
select is(array[pg_temp.code(pg_temp.r('st_d1')), pg_temp.code(pg_temp.r('st_d2')), pg_temp.code(pg_temp.r('st_d3')),
    pg_temp.code(pg_temp.r('st_d4')), pg_temp.code(pg_temp.r('acc_p1')), pg_temp.code(pg_temp.r('drop_w1')), pg_temp.r('drop_w1') ->> 'dropped',
    pg_temp.r('sb_s1') ->> 'to', pg_temp.code(pg_temp.r('re_s1')), pg_temp.code(pg_temp.r('fs_f1')), pg_temp.r('sample') ->> 'added',
    pg_temp.cs('d4'), pg_temp.cs('p1'), pg_temp.cs('w1'), pg_temp.cs('s1')],
  array['ok', 'ok', 'ok', 'ok', 'ok', 'ok', '1', 'same', 'ok', 'ok', '1', 'checked', 'checked', 'checked', 'checked'],
  'the lead settles, accepts, sends back and changes a final mark, an admin releases w1, and the lead samples one script');

-- ---------------------------------------------------------------------------------------------
-- figures_count_settles_by_outcome_and_by_a_party
-- ---------------------------------------------------------------------------------------------
insert into res values ('b2', pg_temp.get('admin', 'b'));
select is(pg_temp.r('b2') -> 'figures',
  '{"pieces": 11, "second_marked": 5, "within_tolerance": 1, "settled": {"first_stands": 2, "second_stands": 1, "lead_marks": 1},
    "settled_by_a_party": 1, "accepted_after_pause": 1, "sent_back": 1, "final_marks_changed": 1, "standards": {"practice": 1, "seed": 1},
    "seed_attempts": 2, "seed_outside": 1, "sample_reviews_open": 1}'::jsonb,
  'figures_count_settles_by_outcome_and_by_a_party: 5 second-marked, 1 within; differences settled 2 first, 1 second, 1 the lead''s own (f1''s final mark change is not a settle), 1 by a lead who was a marker; p1 accepted after a pause; s1 sent back; f1''s final mark changed; one seeded and one practice script, two attempts submitted, one outside');
select is(array[pg_temp.r('b2') -> 'checks', to_jsonb(pg_temp.r('b2') ->> 'lead_name'), pg_temp.r('b2') -> 'approved_at', pg_temp.r('b2') -> 'approved_by_name'],
  array['{"double_marking": true, "sample_percent": 10, "tolerance_percent": 10, "seeds": true, "seed_every": 50, "practice": false, "off": null}'::jsonb,
    '"Ermengarde Leadbetter"'::jsonb, 'null'::jsonb, 'null'::jsonb],
  'the checks in force, nothing turned off; the lead marker''s name; not approved yet');
select is(array[pg_temp.keys(pg_temp.r('b2')), pg_temp.keys(pg_temp.r('b2') -> 'scripts'), pg_temp.keys(pg_temp.r('b2') -> 'figures')],
  array['approved_at,approved_by_name,blocks,can_approve,checks,figures,lead_name,no_script,ok,opened,scripts,stale', 'checked,other,void,withdrawn',
    'accepted_after_pause,final_marks_changed,pieces,sample_reviews_open,second_marked,seed_attempts,seed_outside,sent_back,settled,settled_by_a_party,standards,within_tolerance'],
  'the answer''s parts');

-- ---------------------------------------------------------------------------------------------
-- open_sample_review_does_not_block
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.blocks(pg_temp.r('b2')), pg_temp.r('b2') ->> 'can_approve', pg_temp.r('b2') ->> 'stale', pg_temp.r('b2') #>> '{scripts,checked}',
    (select count(*)::text from public.marking_reviews r where r.exam_id = pg_temp.k('b') and r.kind = 'sample' and r.state = 'open')],
  array['', 'true', 'false', '11', '1'],
  'open_sample_review_does_not_block: with every script checked and one routine sample open, nothing blocks');

-- ---------------------------------------------------------------------------------------------
-- approve_closes_marking_and_freezes
-- ---------------------------------------------------------------------------------------------
insert into res values ('b_ap', pg_temp.approve('admin', 'b', 'Every script is checked.'));
insert into res values ('b_at', (select to_jsonb(m.approved_at) from public.exam_marking m where m.exam_id = pg_temp.k('b')));
insert into res values ('b3', pg_temp.get('admin', 'b'));
select is(array[pg_temp.code(pg_temp.r('b_ap')), pg_temp.r('b_ap') ->> 'closed',
    (select (m.approved_by = pg_temp.uid('admin') and m.closed_at is not null)::text from public.exam_marking m where m.exam_id = pg_temp.k('b')),
    pg_temp.reason('marking_approved', pg_temp.k('b')), pg_temp.r('b3') ->> 'approved_by_name',
    ((pg_temp.r('b3') ->> 'approved_at')::timestamptz = (pg_temp.r('b_at') #>> '{}')::timestamptz)::text, pg_temp.r('b3') ->> 'stale'],
  array['ok', 'true', 'true', 'Every script is checked.', 'Agatha Approver', 'true', 'false'],
  'approve_closes_marking_and_freezes: approved with a note, which is the audit row''s reason; marking is closed');
insert into res values ('struct_b', pg_temp.as('admin', format('select public.exam_structure_get(%L)', pg_temp.k('b'))));
select is(array[
    pg_temp.code(pg_temp.as('lead', format($q$ select public.marking_final_set(%L, %L::jsonb, 'Question 1 again.') $q$,
      pg_temp.u('f1'), jsonb_build_array(pg_temp.mk('f1', '1', 3))))),
    pg_temp.code(pg_temp.as('admin', format($q$ select public.exam_structure_save(%L, %L::jsonb, 'Clearer guidance') $q$, pg_temp.k('b'),
      pg_temp.edit(pg_temp.draft(pg_temp.r('struct_b')), pg_temp.q('k1', '1'), '{"guidance": "Units are needed."}')))),
    pg_temp.code(pg_temp.as('admin', format($q$ select public.marking_checks_set(%L,
      '{"double_marking": true, "sample_percent": 20, "tolerance_percent": 10, "seeds": true, "seed_every": 50, "practice": false}'::jsonb,
      'More second marking.') $q$, pg_temp.k('b')))),
    pg_temp.code(pg_temp.as('admin', format($q$ select public.marking_reopen(%L, 'More scripts came in.') $q$, pg_temp.k('b')))),
    pg_temp.code(pg_temp.as('admin', format($q$ select public.marking_take_back(array[%L]::uuid[], 'Marked wrongly.') $q$, pg_temp.u('k1')))),
    pg_temp.code(pg_temp.as('admin', format($q$ select public.marking_settings_set(%L, 'whole', null, 'No deadline after all.') $q$, pg_temp.k('b')))),
    pg_temp.code(pg_temp.as('admin', format($q$ select public.marking_assign(array[%L]::uuid[], %L, 'Cover for m1.') $q$, pg_temp.u('k1'), pg_temp.uid('m2')))),
    pg_temp.code(pg_temp.as('admin', format($q$ select public.marking_script_take_back(%L, 'Check the pages.') $q$, pg_temp.k('k1')))),
    pg_temp.code(pg_temp.as('admin', format($q$ select public.marking_second_add(array[%L]::uuid[], 'A second look.') $q$, pg_temp.u('s1')))),
    pg_temp.code(pg_temp.as('admin', format($q$ select public.marking_second_drop(array[%L]::uuid[], 'Not needed.') $q$, pg_temp.u('k1')))),
    pg_temp.code(pg_temp.settle('lead', 'd1', 'first_stands', 'Settled again.')),
    pg_temp.code(pg_temp.as('lead', format('select public.marking_review_accept(%L)',
      (select r.id from public.marking_reviews r where r.exam_id = pg_temp.k('b') and r.kind = 'sample' and r.state = 'open')))),
    pg_temp.code(pg_temp.as('lead', format($q$ select public.marking_send_back(%L, 'same', 'Look again.', 'Too generous.') $q$, pg_temp.u('k1')))),
    pg_temp.code(pg_temp.as('lead', format('select public.marking_review_sample(%L, %L, 1)', pg_temp.k('b'), pg_temp.uid('m1')))),
    pg_temp.code(pg_temp.as('lead', format($q$ select public.marking_standard_set(%L, 'seed') $q$, pg_temp.u('sd2')))),
    pg_temp.code(pg_temp.as('lead', format($q$ select public.marking_marker_clear(%L, %L, 'Practice is fine.') $q$, pg_temp.k('b'), pg_temp.uid('m3')))),
    pg_temp.code(pg_temp.as('lead', format($q$ select public.marking_marker_pause(%L, %L, 'Too generous.') $q$, pg_temp.k('b'), pg_temp.uid('m1')))),
    pg_temp.code(pg_temp.as('admin', format($q$ select public.marking_script_hand_back(%L, 'The pages are fine.') $q$, pg_temp.k('k1')))),
    pg_temp.code(pg_temp.as('lead', format($q$ select public.marking_standard_retire(%L, 'No longer a fair test.') $q$,
      (select st.id from public.marking_standards st where st.unit_id = pg_temp.u('sd1'))))),
    pg_temp.code(pg_temp.as('m1', format($q$ select public.marking_save(%L, %s, %L::jsonb, 0, 'A change after approval.') $q$,
      pg_temp.k('f:k1'), pg_temp.rev('f:k1'), pg_temp.ops(pg_temp.u('k1'), array[2, 1, 1]))))],
  array['marking_approved', 'marking_approved', 'marking_approved', 'marking_approved', 'marking_approved', 'marking_approved',
    'marking_approved', 'marking_approved', 'marking_approved', 'marking_approved', 'marking_approved', 'marking_approved',
    'marking_approved', 'marking_approved', 'marking_approved', 'marking_approved', 'marking_approved', 'marking_approved',
    'marking_approved', 'marking_closed'],
  'every marking action is refused while the approval stands (marking_approved): the brief''s 17, a script''s hand-back and a standard''s retirement (Ruling R22); a marker''s save is refused because marking is closed');
select is(array[pg_temp.cs('k1'), pg_temp.st('k1'), pg_temp.cs('d1'), pg_temp.cs('s1'),
    (select trim_scale(f.mark)::text from public.final_marks f where f.unit_id = pg_temp.u('f1') and f.question_id = pg_temp.q('f1', '1')),
    (select coalesce(trim_scale(q.max_mark)::text || ' ' || coalesce(q.guidance, '-'), '-') from public.exam_questions q where q.id = pg_temp.q('k1', '1')),
    (select m.sample_percent::text from public.exam_marking m where m.exam_id = pg_temp.k('b')),
    (select count(*)::text from public.exam_markers x where x.exam_id = pg_temp.k('b') and x.paused_at is not null),
    (select count(*) filter (where st.retired_at is null)::text from public.marking_standards st where st.exam_id = pg_temp.k('b')),
    (select count(*)::text from public.marking_reviews r where r.exam_id = pg_temp.k('b') and r.kind = 'sample' and r.state = 'open'),
    (select (m.closed_at is not null)::text from public.exam_marking m where m.exam_id = pg_temp.k('b'))],
  array['checked', 'checked', 'checked', 'checked', '2', '3 -', '10', '1', '2', '1', 'true'],
  'and nothing changed: the pieces stay checked, f1''s final mark, the questions, the checks, the pause, the standards and the sample are as they were');

-- ---------------------------------------------------------------------------------------------
-- approve_twice_is_one_approval
-- ---------------------------------------------------------------------------------------------
insert into res values ('b_ap2', pg_temp.approve('admin', 'b', 'Approved again.'));
select is(array[pg_temp.code(pg_temp.r('b_ap2')), pg_temp.r('b_ap2') ->> 'already', pg_temp.audits('marking_approved', pg_temp.k('b'))::text,
    (select (m.approved_at = (pg_temp.r('b_at') #>> '{}')::timestamptz)::text from public.exam_marking m where m.exam_id = pg_temp.k('b'))],
  array['ok', 'true', '1', 'true'], 'approve_twice_is_one_approval: a second approval changes nothing and writes nothing');

-- ---------------------------------------------------------------------------------------------
-- withdraw_needs_a_reason_and_then_reopen_works
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.code(pg_temp.withdraw('admin', 'b', null)), pg_temp.code(pg_temp.withdraw('admin', 'b', ' ab ')),
    pg_temp.code(pg_temp.withdraw('admin', 'b', repeat('x', 301))), pg_temp.audits('marking_approval_withdrawn', pg_temp.k('b'))::text,
    (select (m.approved_at is not null)::text from public.exam_marking m where m.exam_id = pg_temp.k('b'))],
  array['reason_required', 'reason_required', 'reason_required', '0', 'true'],
  'withdraw_needs_a_reason_and_then_reopen_works: a reason of 3 to 300 characters');
insert into res values ('b_wd', pg_temp.withdraw('admin', 'b', 'A script was marked wrongly.'));
insert into res values ('b_wd2', pg_temp.withdraw('admin', 'b', 'Again.'));
insert into res values ('b_save_closed', pg_temp.as('m1', format($q$ select public.marking_save(%L, %s, %L::jsonb, 0, 'A change.') $q$,
  pg_temp.k('f:k1'), pg_temp.rev('f:k1'), pg_temp.ops(pg_temp.u('k1'), array[1, 1, 1]))));
select is(array[pg_temp.code(pg_temp.r('b_wd')), pg_temp.r('b_wd') ->> 'already',
    (select (m.approved_at is null and m.approved_by is null and m.closed_at is not null)::text from public.exam_marking m where m.exam_id = pg_temp.k('b')),
    pg_temp.reason('marking_approval_withdrawn', pg_temp.k('b')), pg_temp.code(pg_temp.r('b_wd2')), pg_temp.r('b_wd2') ->> 'already',
    pg_temp.audits('marking_approval_withdrawn', pg_temp.k('b'))::text, pg_temp.code(pg_temp.r('b_save_closed'))],
  array['ok', 'false', 'true', 'A script was marked wrongly.', 'ok', 'true', '1', 'marking_closed'],
  'the approval is withdrawn with the reason in the audit row; marking stays closed until an admin reopens it');
insert into res values ('b_reopen', pg_temp.as('admin', format($q$ select public.marking_reopen(%L, 'One script needs another look.') $q$, pg_temp.k('b'))));
insert into res values ('b_save_open', pg_temp.as('m1', format($q$ select public.marking_save(%L, %s, %L::jsonb, 0, 'Same marks, checked again.') $q$,
  pg_temp.k('f:k1'), pg_temp.rev('f:k1'), pg_temp.ops(pg_temp.u('k1'), array[1, 1, 1]))));
insert into res values ('b4', pg_temp.get('admin', 'b'));
select is(array[pg_temp.code(pg_temp.r('b_reopen')),
    (select (m.closed_at is null)::text from public.exam_marking m where m.exam_id = pg_temp.k('b')),
    pg_temp.code(pg_temp.r('b_save_open')), pg_temp.r('b4') ->> 'approved_at', pg_temp.r('b4') ->> 'can_approve'],
  array['ok', 'true', 'ok', null, 'true'],
  'then reopening works, and a marker may save again; the exam may be approved again');

-- ---------------------------------------------------------------------------------------------
-- approval_shows_the_off_reason_who_and_when
-- ---------------------------------------------------------------------------------------------
insert into res values ('s1', pg_temp.get('admin', 's'));
select is(array[pg_temp.r('s1') #>> '{checks,double_marking}', pg_temp.r('s1') #>> '{checks,seeds}', pg_temp.r('s1') #>> '{checks,practice}',
    pg_temp.r('s1') #>> '{checks,off,reason}', pg_temp.r('s1') #>> '{checks,off,by_name}',
    ((pg_temp.r('s1') #>> '{checks,off,at}')::timestamptz = (select m.checks_off_at from public.exam_marking m where m.exam_id = pg_temp.k('s')))::text,
    coalesce(pg_temp.r('s1') ->> 'lead_name', 'none'),
    (select (a.actor_id = pg_temp.uid('admin') and a.reason like '%reason: Only one marker this term.')::text from public.audit_log a
     where a.action = 'marking_checks_set' and a.target_id = pg_temp.k('s') order by a.id desc limit 1)],
  array['false', 'false', 'false', 'Only one marker this term.', 'Agatha Approver', 'true', 'none', 'true'],
  'approval_shows_the_off_reason_who_and_when: the reason, who and when, as the audit row of turning them off has them; no lead marker');

-- ---------------------------------------------------------------------------------------------
-- approve_writes_audit_with_the_off_reason
-- ---------------------------------------------------------------------------------------------
insert into res values ('s_ap', pg_temp.approve('admin', 's', '  All scripts checked.  '));
insert into res values ('s2', pg_temp.get('admin', 's'));
select is(array[pg_temp.code(pg_temp.r('s_ap')), pg_temp.reason('marking_approved', pg_temp.k('s')), pg_temp.r('s2') ->> 'stale',
    pg_temp.blocks(pg_temp.r('s2'))],
  array['ok', 'All scripts checked.; Checks turned off: Only one marker this term.', 'false', ''],
  'approve_writes_audit_with_the_off_reason: the note, then the reason the checks were turned off');

-- ---------------------------------------------------------------------------------------------
-- script_arriving_after_approval_is_flagged (Review Focus 4)
-- ---------------------------------------------------------------------------------------------
insert into kv values ('late1', tests.verified_script(pg_temp.k('s'), 'home'));
select public.marking_exam_sync(pg_temp.k('s'), null);
insert into res values ('s3', pg_temp.get('admin', 's'));
select is(array[pg_temp.r('s3') ->> 'stale', pg_temp.blocks(pg_temp.r('s3')), pg_temp.r('s3') #>> '{blocks,0,with_staff}',
    (pg_temp.r('s3') ->> 'approved_at' is not null)::text, pg_temp.r('s3') ->> 'can_approve', pg_temp.st('late1'),
    (select count(*)::text from public.final_marks f join public.marking_units u on u.id = f.unit_id where u.script_id = pg_temp.k('late1')),
    coalesce(public.script_final_total(pg_temp.k('late1'))::text, 'none')],
  array['true', 'scripts_not_checked 1', '1', 'true', 'false', 'verified', '0', 'none'],
  'script_arriving_after_approval_is_flagged: a script verified after the approval is flagged (stale), counted as not checked, is not checked and has no final marks');

-- ---------------------------------------------------------------------------------------------
-- on_hold_piece_open_alert_or_unchecked_picture_blocks (and a marker's pause not applied yet)
-- ---------------------------------------------------------------------------------------------
update public.marking_units set on_hold = true, hold_reason = 'picture_changed' where id = pg_temp.u('h1');
insert into public.marking_alerts (exam_id, kind, script_id, unit_id, state)
values (pg_temp.k('c'), 'picture_changed', pg_temp.k('h2'), pg_temp.u('h2'), 'open');
insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details, state, resolution, resolved_at)
select s.exam_id, 'poor_quality', s.booking_id, s.id, p.id, p.upload_id, '{"flags": ["blurred"]}'::jsonb, 'resolved', 'confirmed', now()
from public.scripts s join public.script_page_links l on l.script_id = s.id and l.version = s.version and l.copy_page = 1
join public.script_pages p on p.id = l.page_id where s.id = pg_temp.k('h3');
insert into public.exam_markers (exam_id, marker_id, paused_at) values (pg_temp.k('c'), pg_temp.uid('m2'), now());
insert into res values ('c1', pg_temp.get('admin', 'c'));
insert into res values ('c1_ap', pg_temp.approve('admin', 'c'));
select is(array[pg_temp.blocks(pg_temp.r('c1')), pg_temp.code(pg_temp.r('c1_ap')), pg_temp.blocks(pg_temp.r('c1_ap')),
    pg_temp.r('c1') #>> '{scripts,checked}', pg_temp.r('c1') #>> '{scripts,withdrawn}'],
  array['on_hold 1,alerts_open 1,pictures_to_check 1,pause_pending 1', 'not_all_checked', 'on_hold 1,alerts_open 1,pictures_to_check 1,pause_pending 1',
    '3', '1'],
  'on_hold_piece_open_alert_or_unchecked_picture_blocks: a piece on hold, an open alert, a picture waiting for its check and a pause not applied yet each block (the withdrawn script''s alert does not)');
update public.marking_units set on_hold = false, hold_reason = null where id = pg_temp.u('h1');
update public.marking_alerts set state = 'closed', closed_at = now(), resolution = 'released' where script_id = pg_temp.k('h2');
update public.script_pages p set marking_checked_path = p.marking_path
from public.script_page_links l where l.page_id = p.id and l.script_id = pg_temp.k('h3');
update public.exam_markers set pause_applied_at = now() where exam_id = pg_temp.k('c');
insert into res values ('c2_ap', pg_temp.approve('admin', 'c'));
select is(pg_temp.code(pg_temp.r('c2_ap')), 'ok', 'once each is dealt with, the exam is approved');

-- ---------------------------------------------------------------------------------------------
-- a_name_reported_on_an_approved_exam_makes_it_stale (Ruling R22: a seen name is always reportable)
-- c is approved. m1 reports a name on page 1 of h1 (Name visible), and staff on page 1 of h2 ("A name still shows").
-- ---------------------------------------------------------------------------------------------
create function pg_temp.page1(p text) returns uuid language sql stable security definer as $$
  select l.page_id from public.script_page_links l join public.scripts s on s.id = l.script_id and s.version = l.version
  where s.id = pg_temp.k(p) and l.copy_page = 1 $$;
insert into res values ('h1_final_before', to_jsonb((select count(*)::int from public.final_marks f where f.unit_id = pg_temp.u('h1'))));
insert into res values ('nv_h1', pg_temp.as('m1', format('select public.marking_name_visible(%L, %L)', pg_temp.u('h1'), pg_temp.page1('h1'))));
insert into res values ('ns_h2', pg_temp.as('admin', format($q$ select public.script_page_marking_name_shows(%L, 'A name shows in the margin.') $q$,
  pg_temp.page1('h2'))));
insert into res values ('c3', pg_temp.get('admin', 'c'));
insert into res values ('hb_h1', pg_temp.as('admin', format($q$ select public.marking_script_hand_back(%L, 'The name is hidden now.') $q$, pg_temp.k('h1'))));
select is(array[pg_temp.code(pg_temp.r('nv_h1')), pg_temp.code(pg_temp.r('ns_h2')), pg_temp.r('c3') ->> 'stale',
    (pg_temp.r('c3') ->> 'approved_at' is not null)::text, pg_temp.r('c3') #>> '{blocks,0,code}', pg_temp.r('c3') #>> '{blocks,0,count}',
    pg_temp.st('h1'), pg_temp.st('h2'), pg_temp.cs('h1'), pg_temp.r('h1_final_before') #>> '{}',
    (select count(*)::text from public.final_marks f where f.unit_id = pg_temp.u('h1')), pg_temp.code(pg_temp.r('hb_h1'))],
  array['ok', 'ok', 'true', 'true', 'scripts_not_checked', '2', 'needs_attention', 'needs_attention', '-', '3', '0', 'marking_approved'],
  'a_name_reported_on_an_approved_exam_makes_it_stale: both name reports work on an approved exam; the approval stands but is stale, the scripts are not checked and h1''s final marks are gone; handing a script back stays frozen');

-- ---------------------------------------------------------------------------------------------
-- a_pending_pause_on_a_closed_exam_is_applied_by_the_minute_job (Ruling R22), and approving a closed exam
-- pc's marking was closed by admin2. m4 is paused there (as a third missed seed does) and the minute job has not run:
-- pause_pending blocks. The minute job applies it (a closed exam is not synced: a verified script stays verified),
-- and m4's g1 goes to the lead. Once the lead accepts it, the admin approves pc: marking stays closed by admin2.
-- ---------------------------------------------------------------------------------------------
insert into public.exam_markers (exam_id, marker_id, paused_at) values (pg_temp.k('pc'), pg_temp.uid('m4'), now());
insert into kv values ('g2', tests.verified_script(pg_temp.k('pc'), 'home'));
insert into res values ('pc1', pg_temp.get('admin', 'pc'));
select public.marking_tick();
insert into res values ('pc2', pg_temp.get('admin', 'pc'));
select is(array[pg_temp.blocks(pg_temp.r('pc1')), pg_temp.blocks(pg_temp.r('pc2')),
    (select (x.pause_applied_at is not null)::text from public.exam_markers x where x.exam_id = pg_temp.k('pc') and x.marker_id = pg_temp.uid('m4')),
    pg_temp.cs('g1'), pg_temp.st('g2'), (select (m.closed_at is not null)::text from public.exam_marking m where m.exam_id = pg_temp.k('pc'))],
  array['scripts_not_checked 1,pause_pending 1', 'scripts_not_checked 2,with_lead 1', 'true', 'to_lead', 'verified', 'true'],
  'a_pending_pause_on_a_closed_exam_is_applied_by_the_minute_job: the pause block becomes with_lead (g1 is no longer checked); the closed exam is not synced, so g2 stays verified (with staff)');
update public.scripts set state = 'void' where id = pg_temp.k('g2');
insert into res values ('acc_g1', pg_temp.as('lead', format('select public.marking_review_accept(%L)', pg_temp.rv('g1', 'paused_marker'))));
insert into res values ('pc_ap', pg_temp.approve('admin', 'pc', 'Checked after the pause.'));
select is(array[pg_temp.code(pg_temp.r('acc_g1')), pg_temp.code(pg_temp.r('pc_ap')), pg_temp.r('pc_ap') ->> 'closed',
    (select (m.closed_by = pg_temp.uid('admin2') and m.approved_by = pg_temp.uid('admin'))::text from public.exam_marking m where m.exam_id = pg_temp.k('pc')),
    pg_temp.audits('marking_closed', pg_temp.k('pc'))::text],
  array['ok', 'ok', 'false', 'true', '1'],
  'approving an exam whose marking is closed already: closed is false, and who closed it is kept');

-- ---------------------------------------------------------------------------------------------
-- maximum_cannot_drop_below_a_final_or_standard_mark
-- The lead gives mf1 a final mark of 3 on question 1 (m1 gave 1); ms1 is a seeded script whose frozen mark on 2(b) is
-- 5 (the lead's own marks are 1 each now). No marker's mark is above 1 anywhere.
-- ---------------------------------------------------------------------------------------------
insert into res values ('fs_mf1', pg_temp.as('lead', format($q$ select public.marking_final_set(%L, %L::jsonb, 'Question 1 deserves full marks.') $q$,
  pg_temp.u('mf1'), jsonb_build_array(pg_temp.mk('mf1', '1', 3)))));
with st as (insert into public.marking_standards (exam_id, unit_id, use, set_by)
            values (pg_temp.k('mx'), pg_temp.u('ms1'), 'seed', pg_temp.uid('lead')) returning id)
insert into public.marking_standard_marks (standard_id, question_id, mark)
select st.id, q.question_id, case when q.label = '2(b)' then 5 else 1 end from st, public.marking_unit_questions(pg_temp.u('ms1')) q where q.leaf;
insert into res values ('mx_1', pg_temp.save('mx', 'mf1', '1', '{"max_mark": 2}', 'Question 1 is out of 2.'));
insert into res values ('mx_2b', pg_temp.save('mx', 'mf1', '2(b)', '{"max_mark": 4}', 'Part (b) is out of 4.'));
insert into res values ('mx_2a', pg_temp.save('mx', 'mf1', '2(a)', '{"max_mark": 1}', 'Part (a) is out of 1.'));
select is(array[pg_temp.code(pg_temp.r('fs_mf1')),
    (select trim_scale(max(m.mark))::text from public.question_marks m join public.markings k on k.id = m.marking_id
     join public.marking_units u on u.id = k.unit_id where u.exam_id = pg_temp.k('mx')),
    pg_temp.code(pg_temp.r('mx_1')), pg_temp.code(pg_temp.r('mx_2b')), pg_temp.code(pg_temp.r('mx_2a')),
    (select string_agg(trim_scale(q.max_mark)::text, ',' order by q.position, q.label) from public.exam_questions q
     where q.exam_id = pg_temp.k('mx') and q.max_mark is not null)],
  array['ok', '1', 'conflict', 'conflict', 'ok', '3,1,5'],
  'maximum_cannot_drop_below_a_final_or_standard_mark: a maximum below a final mark or a standard''s mark is refused (conflict); one no mark is above is saved');

-- ---------------------------------------------------------------------------------------------
-- No answer names a candidate.
-- ---------------------------------------------------------------------------------------------
select is(pg_temp.found(array['Wilhelmina', 'Quarterfield'],
    pg_temp.r('b2')::text || pg_temp.r('a1_after')::text || pg_temp.r('a2')::text || pg_temp.r('s3')::text || pg_temp.r('c1')::text
    || pg_temp.r('b1_ap')::text),
  '{}'::text[], 'no approval answer names a candidate');

-- ---------------------------------------------------------------------------------------------
-- approval_in_time_at_1500_scripts (a timing guard, Ruling R22; as 060, Phase 3A Ruling R25: the fixture tables are
-- analysed first). Subject 'ZZ Appr Big' (markers v1 and v2): exam big, marked as whole scripts with double marking on
-- at 100%, has 1,500 scripts, each checked, first-marked by v1 and second-marked by v2 (1,500 pairs; every seventh
-- second marking is outside tolerance, its difference settled); pieces and markings written directly. 300 of the scripts (10 pages
-- each) have a page staff confirmed whose marking picture is not checked yet. As an admin, the approval page must
-- answer within 6 s and the (refused) approval within 4 s: the limit a user meets is the 8-second statement timeout of
-- a signed-in call (as Ruling R21).
-- ---------------------------------------------------------------------------------------------
create function pg_temp.timed(p_name text, p_sql text) returns jsonb language plpgsql as $$
declare
  v_t0 timestamptz := clock_timestamp();
  v jsonb;
begin
  execute p_sql into v;
  insert into res values (p_name, jsonb_build_object('ms', round(extract(epoch from clock_timestamp() - v_t0) * 1000)));
  return v;
end $$;
grant execute on function pg_temp.timed(text, text), pg_temp.k(text) to public;
insert into public.subjects (name, kind) values ('ZZ Appr Big', 'school');
insert into c values ('v1', tests.marker(pg_temp.subj('ZZ Appr Big'))), ('v2', tests.marker(pg_temp.subj('ZZ Appr Big')));
insert into kv values ('big', tests.marking_exam(pg_temp.subj('ZZ Appr Big')));
select tests.structure(pg_temp.k('big'));
create temp table bigs (id uuid primary key, n int not null, flagged boolean not null);
insert into bigs
select tests.verified_script(pg_temp.k('big'), 'home', case when i <= 300 then 10 else 3 end), i, i <= 300 from generate_series(1, 1500) i;
-- Analysed now as well: the scripts' state change below reads each script's hand-in through a trigger.
analyze public.scripts, public.script_pages, public.script_page_links, public.script_uploads, public.home_submissions, public.bookings;
update public.exam_marking set opened_at = now(), double_marking = true, sample_percent = 100 where exam_id = pg_temp.k('big');
insert into public.marking_units (script_id, exam_id, state, second_wanted, check_state, checked_at)
select b.id, pg_temp.k('big'), 'submitted', true, 'checked', now() from bigs b;
insert into public.markings (unit_id, kind, marker_id, status, rev, total, submitted_at)
select u.id, k.kind::public.marking_kind, pg_temp.uid(k.who), 'submitted', 1, case when k.kind = 'second' and b.n % 7 = 0 then 10 else 3 end, now()
from public.marking_units u join bigs b on b.id = u.script_id
cross join (values ('live', 'v1'), ('second', 'v2')) k(kind, who)
where u.exam_id = pg_temp.k('big');
insert into public.question_marks (marking_id, question_id, mark)
select m.id, q.id, case when m.kind = 'second' and b.n % 7 = 0 then q.max_mark else 1 end
from public.markings m join public.marking_units u on u.id = m.unit_id join bigs b on b.id = u.script_id
join public.exam_questions q on q.exam_id = u.exam_id and q.max_mark is not null
where u.exam_id = pg_temp.k('big');
-- Each pair outside tolerance had its difference settled by the lead (first marks stand), as the check records it.
insert into public.marking_reviews (exam_id, unit_id, kind, marking_id, second_marking_id, state, outcome, reason, closed_by, closed_at)
select u.exam_id, u.id, 'difference', f.id, k.id, 'closed', 'first_stands', 'The first marks are right.', pg_temp.uid('admin'), now()
from public.marking_units u join bigs b on b.id = u.script_id
join public.markings f on f.unit_id = u.id and f.kind = 'live'
join public.markings k on k.unit_id = u.id and k.kind = 'second'
where u.exam_id = pg_temp.k('big') and b.n % 7 = 0;
update public.scripts set state = 'checked' where exam_id = pg_temp.k('big');
insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details, state, resolution, resolved_at)
select s.exam_id, 'poor_quality', s.booking_id, s.id, p.id, p.upload_id, '{"flags": ["blurred"]}'::jsonb, 'resolved', 'confirmed', now()
from bigs b join public.scripts s on s.id = b.id
join public.script_page_links l on l.script_id = s.id and l.version = s.version and l.copy_page = 1
join public.script_pages p on p.id = l.page_id
where b.flagged;
analyze public.scripts, public.marking_units, public.markings, public.question_marks, public.exam_questions, public.script_pages,
        public.script_page_links, public.script_exceptions, public.script_uploads, public.home_submissions, public.bookings,
        public.paper_copies, public.exam_papers, public.exam_marking, public.exams, public.marking_reviews,
        public.marking_standards, public.marking_alerts, public.exam_markers, public.audit_log, public.profiles,
        public.marker_approvals;
select tests.as_user(pg_temp.uid('admin'));
set local statement_timeout = '6s';
insert into res values ('big', pg_temp.timed('ms_get', format('select public.marking_approval_get(%L)', pg_temp.k('big'))));
set local statement_timeout = '4s';
insert into res values ('big_ap', pg_temp.timed('ms_approve', format('select public.marking_approve(%L)', pg_temp.k('big'))));
reset statement_timeout;
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('big')), pg_temp.blocks(pg_temp.r('big')), pg_temp.r('big') #>> '{figures,pieces}',
    pg_temp.r('big') #>> '{figures,second_marked}', pg_temp.r('big') #>> '{figures,within_tolerance}',
    pg_temp.r('big') #>> '{figures,settled,first_stands}',
    pg_temp.code(pg_temp.r('big_ap')), pg_temp.blocks(pg_temp.r('big_ap')),
    ((pg_temp.r('ms_get') ->> 'ms')::int <= 6000)::text, ((pg_temp.r('ms_approve') ->> 'ms')::int <= 4000)::text],
  array['ok', 'pictures_to_check 300', '1500', '1500', '1286', '214', 'not_all_checked', 'pictures_to_check 300', 'true', 'true'],
  'approval_in_time_at_1500_scripts: the approval page of 1,500 second-marked scripts, 300 with a picture to check, within 6 s, '
  || 'and the refused approval within 4 s, under the 8 s statement timeout a signed-in user meets (Ruling R22, as R21)');
select diag('marking_approval_get at 1,500 scripts: ' || (pg_temp.r('ms_get') ->> 'ms') || ' ms; marking_approve: '
  || (pg_temp.r('ms_approve') ->> 'ms') || ' ms');

select * from finish();
rollback;
