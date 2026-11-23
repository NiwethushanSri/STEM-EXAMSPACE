begin;
create extension if not exists pgtap with schema extensions;
select plan(121);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Subject 'ZZ Std': markers m1 to m6 and the lead marker (tests.marker); corr is a corrector never
-- approved; olead leads another subject. Every exam has the test structure (1 of 3 marks, 2(a) of 2, 2(b) of 5: out
-- of 10, every tolerance the floor of one mark).
--   e: double marking on (10%, 10% tolerance), seeded scripts on (one about every 4), practice on. The lead marks
--      p1 and p2 (practice: 1,1,1 and 2,2,2), s1 to s5 (seeded: 3,2,5 each) and c1, c2 (theirs, not used); m1
--      marks x0. Every piece's stored draw is set so that it is not second-marked, unless a test says otherwise.
--   d: double marking and seeded scripts on, practice off.
--   f: the checks off (Task 3's Next script).
--   n: practice on, and no practice script.
--   g: practice and seeds on, for the count of standards.
-- A piece is kept as 'u:<script>', a marking as kv '<key>' (pg_temp.mark) with its answers in res as '<key>:open',
-- '<key>:save' and '<key>:submit'.
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
-- A piece a call handed out, kept under another name ('a:<name>'); pg_temp.nm gives its own name.
create function pg_temp.a(p text) returns uuid language sql stable as $$ select id from kv where name = 'a:' || p $$;
create function pg_temp.r(p text) returns jsonb language sql stable as $$ select j from res where name = p $$;
-- A number of an answer, without trailing zeros ('5', '2.5').
create function pg_temp.n(j jsonb, p text) returns text language sql immutable as $$ select trim_scale((j ->> p)::numeric)::text $$;
create function pg_temp.subj(p text) returns bigint language sql stable as $$ select id from public.subjects where name = p $$;
create function pg_temp.code(j jsonb) returns text language sql immutable as $$
  select case when (j ->> 'ok')::boolean then 'ok' else coalesce(j ->> 'code', 'none') end $$;
-- A piece's name ('x1', 'p1', ...; '-' for none).
create function pg_temp.nm(p uuid) returns text language sql stable as $$
  select coalesce((select substr(name, 3) from kv where id = p and name like 'u:%' limit 1), '-') $$;
-- A piece's check state ('-' for none), its own state, its script's state.
create function pg_temp.cs(p text) returns text language sql stable security definer as $$
  select coalesce(check_state, '-') from public.marking_units where id = pg_temp.u(p) $$;
create function pg_temp.us(p text) returns text language sql stable security definer as $$
  select state from public.marking_units where id = pg_temp.u(p) $$;
create function pg_temp.st(p text) returns text language sql stable security definer as $$
  select s.state::text from public.scripts s join public.marking_units u on u.script_id = s.id where u.id = pg_temp.u(p) $$;
create function pg_temp.wanted(p text) returns text language sql stable security definer as $$
  select coalesce(second_wanted::text, '-') from public.marking_units where id = pg_temp.u(p) $$;
-- A piece's final marks in paper order ('' for none).
create function pg_temp.fm(p text) returns text language sql stable security definer as $$
  select coalesce(string_agg(q.label || '=' || coalesce(trim_scale(f.mark)::text, 'NR') || ' ' || f.source, ',' order by q.path), '')
  from public.final_marks f join public.marking_unit_questions(pg_temp.u(p)) q on q.question_id = f.question_id
  where f.unit_id = pg_temp.u(p) $$;
-- A marker's markings and holds on a piece: 'kind status reason', and how their holds ended ('open' for one that has not).
create function pg_temp.ms(p text, p_marker text) returns text language sql stable security definer as $$
  select coalesce(string_agg(m.kind || ' ' || m.status || coalesce(' ' || m.set_aside_reason, ''), ',' order by m.kind), '-') from public.markings m
  where m.unit_id = pg_temp.u(p) and m.marker_id = pg_temp.uid(p_marker) $$;
create function pg_temp.ended(p text, p_marker text) returns text language sql stable security definer as $$
  select coalesce(string_agg(a.kind || ' ' || coalesce(a.end_reason, 'open'), ',' order by a.created_at, a.id), '-')
  from public.marking_assignments a where a.unit_id = pg_temp.u(p) and a.marker_id = pg_temp.uid(p_marker) $$;
-- A piece's reviews: 'kind state outcome' in the order they were opened.
create function pg_temp.reviews(p text) returns text language sql stable security definer as $$
  select coalesce(string_agg(r.kind || ' ' || r.state || coalesce(' ' || r.outcome, ''), ',' order by r.opened_at, r.id), '-')
  from public.marking_reviews r where r.unit_id = pg_temp.u(p) $$;
create function pg_temp.audits(p_action text, p_target uuid) returns int language sql stable security definer as $$
  select count(*)::int from public.audit_log a where a.action = p_action and a.target_id = p_target $$;
create function pg_temp.student(p text) returns uuid language sql stable security definer as $$
  select b.student_id from public.marking_units u join public.scripts s on s.id = u.script_id join public.bookings b on b.id = s.booking_id
  where u.id = pg_temp.u(p) $$;
-- A marker on an exam (exam_markers), read as postgres.
create function pg_temp.xm(p_exam text, p_marker text) returns public.exam_markers language sql stable security definer as $$
  select * from public.exam_markers where exam_id = pg_temp.k(p_exam) and marker_id = pg_temp.uid(p_marker) $$;
create function pg_temp.until0(p_exam text, p_marker text, p_n int default 0) returns void language sql security definer as $$
  insert into public.exam_markers (exam_id, marker_id, until_seed) values (pg_temp.k(p_exam), pg_temp.uid(p_marker), p_n)
  on conflict (exam_id, marker_id) do update set until_seed = excluded.until_seed $$;
-- A piece's standard, and its frozen marks in paper order.
create function pg_temp.std(p text) returns public.marking_standards language sql stable security definer as $$
  select * from public.marking_standards where unit_id = pg_temp.u(p) $$;
create function pg_temp.stdmarks(p text) returns text language sql stable security definer as $$
  select coalesce(string_agg(q.label || '=' || coalesce(trim_scale(m.mark)::text, 'NR'), ',' order by q.path), '')
  from public.marking_standards s join public.marking_standard_marks m on m.standard_id = s.id
  join public.marking_unit_questions(s.unit_id) q on q.question_id = m.question_id where s.unit_id = pg_temp.u(p) $$;
create function pg_temp.is_std(p uuid, p_use text) returns boolean language sql stable security definer as $$
  select exists (select 1 from public.marking_standards s where s.unit_id = p and s.use = p_use) $$;
-- The live marking of a piece: its marks in paper order.
create function pg_temp.livemarks(p text) returns text language sql stable security definer as $$
  select coalesce(string_agg(q.label || '=' || coalesce(trim_scale(m.mark)::text, 'NR'), ',' order by q.path), '')
  from public.markings k join public.question_marks m on m.marking_id = k.id
  join public.marking_unit_questions(k.unit_id) q on q.question_id = m.question_id
  where k.unit_id = pg_temp.u(p) and k.kind = 'live' and k.status <> 'set_aside' $$;
-- The pieces the one rule allows a marker as a kind of pass on an exam (Next script), by name.
create function pg_temp.allowed(p_exam text, p_marker text, p_kind text) returns text language sql stable as $$
  select coalesce(string_agg(pg_temp.nm(a.unit_id), ',' order by pg_temp.nm(a.unit_id)), '')
  from public.marking_units_allowed(pg_temp.k(p_exam), pg_temp.uid(p_marker), p_kind::public.marking_kind, true) a $$;
create function pg_temp.blocked(p text, p_marker text, p_kind text default 'live') returns text language sql stable as $$
  select coalesce(public.marking_unit_blocked(pg_temp.u(p), pg_temp.uid(p_marker), null, true, p_kind::public.marking_kind), 'null') $$;
-- Everything about the candidate's own marking of a piece, read as postgres: the live marking (status, rev, total,
-- submitted_at) and its marks, the final marks (with when) and their history, the piece's state and check state, the
-- script's state, its audit rows and the piece's reviews.
create function pg_temp.snap(p text) returns text language sql stable security definer as $$
  select concat_ws(' | ',
    (select string_agg(m.status || ' ' || m.rev || ' ' || coalesce(trim_scale(m.total)::text, '-') || ' ' || coalesce(m.submitted_at::text, '-'), ',' order by m.id)
     from public.markings m where m.unit_id = pg_temp.u(p) and m.kind = 'live'),
    pg_temp.livemarks(p),
    (select string_agg(f.question_id || '=' || coalesce(trim_scale(f.mark)::text, 'NR') || ' ' || f.source || ' ' || f.set_at, ',' order by f.question_id)
     from public.final_marks f where f.unit_id = pg_temp.u(p)),
    (select count(*)::text from public.final_mark_history h where h.unit_id = pg_temp.u(p)),
    (select u.state || ' ' || coalesce(u.check_state, '-') || ' ' || coalesce(u.checked_at::text, '-') || ' ' || coalesce(u.final_marking_id::text, '-')
     from public.marking_units u where u.id = pg_temp.u(p)),
    pg_temp.st(p),
    (select count(*)::text from public.audit_log a where a.target_id = (select u.script_id from public.marking_units u where u.id = pg_temp.u(p))),
    pg_temp.reviews(p)) $$;
-- The key paths of an answer: '.marking.id', '.pages[].n', ... (values left out), as 056.
create function pg_temp.keys(j jsonb) returns text[] language sql immutable as $$
  with recursive t(path, v) as (
    select '', j
    union all
    select t.path || x.k, x.v from t cross join lateral (
      select '.' || e.key as k, e.value as v from jsonb_each(case when jsonb_typeof(t.v) = 'object' then t.v else '{}' end) e
      union all
      select '[]', a.value from jsonb_array_elements(case when jsonb_typeof(t.v) = 'array' then t.v else '[]' end) a) x
  )
  select array(select distinct t.path from t where t.path <> '' order by 1) $$;
-- The words of p_words that a text holds.
create function pg_temp.found(p_words text[], p_text text) returns text[] language sql immutable as $$
  select array(select w from unnest(p_words) w where position(lower(w) in lower(p_text)) > 0) $$;
-- A piece of a work list (marking_my_work), and an exam of it.
create function pg_temp.piece(j jsonb, p uuid) returns jsonb language sql immutable as $$
  select x from jsonb_array_elements(j -> 'pieces') x where x ->> 'unit_id' = p::text $$;
create function pg_temp.exam(j jsonb, p text) returns jsonb language sql stable as $$
  select x from jsonb_array_elements(j -> 'exams') x where x ->> 'exam_id' = pg_temp.k(p)::text $$;
-- A new verified home script of an exam, its pages and its piece, not second-marked (its draw is 0.99).
create function pg_temp.script(p_name text, p_exam text) returns void language plpgsql as $$
begin
  insert into kv values (p_name, tests.verified_script(pg_temp.k(p_exam), 'home'));
  insert into kv select 'p:' || p_name || ':' || l.copy_page, l.page_id
  from public.scripts s join public.script_page_links l on l.script_id = s.id and l.version = s.version where s.id = pg_temp.k(p_name);
  perform public.marking_exam_sync(pg_temp.k(p_exam), null);
  insert into kv select 'u:' || p_name, u.id from public.marking_units u where u.script_id = pg_temp.k(p_name) on conflict (name) do nothing;
  update public.marking_units set sample_draw = 0.99 where script_id = pg_temp.k(p_name);
end $$;
create function pg_temp.scripts(p_prefix text, p_exam text, p_n int) returns void language plpgsql as $$
begin
  for i in 1 .. p_n loop
    perform pg_temp.script(p_prefix || i, p_exam);
  end loop;
end $$;
-- A save's operations: a mark for each question of the piece, in paper order (p_marks[i], 0 when not given).
create function pg_temp.ops(p_unit uuid, p_marks numeric[]) returns jsonb language sql stable security definer as $$
  select jsonb_agg(jsonb_build_object('op', 'mark', 'question_id', q.question_id, 'mark', coalesce(p_marks[q.n], 0), 'na', false) order by q.n)
  from (select t.question_id, row_number() over (order by t.path) as n from public.marking_unit_questions(p_unit) t where t.leaf) q $$;
-- The live marking of a piece by a marker (tests.mark_piece), kept as 'f:<piece>'.
create function pg_temp.first(p text, p_marker text, p_marks numeric[]) returns void language plpgsql as $$
begin
  insert into kv values ('f:' || p, tests.mark_piece(pg_temp.u(p), pg_temp.uid(p_marker), p_marks))
  on conflict (name) do update set id = excluded.id;
end $$;
-- The marker takes a pass of the piece as Next script does (a 2-hour hold), as postgres.
create function pg_temp.take(p text, p_marker text, p_kind text) returns void language plpgsql as $$
begin
  perform public.marking_unit_take(pg_temp.u(p), pg_temp.uid(p_marker), 'next', null, now() + interval '2 hours', p_kind::public.marking_kind);
end $$;
-- Signed in as the marker, who holds the piece: open it, save p_marks and submit. The answers are kept in res as
-- '<p_key>:open', '<p_key>:save' and '<p_key>:submit', the marking as kv '<p_key>'. Returns the submit's answer.
create function pg_temp.mark(p_marker text, p_unit uuid, p_marks numeric[], p_key text) returns jsonb language plpgsql as $$
declare
  v_marker uuid := pg_temp.uid(p_marker);
  v_ops jsonb := pg_temp.ops(p_unit, p_marks);
  v_r jsonb;
  v_mk uuid;
begin
  perform tests.as_user(v_marker);
  v_r := public.marking_unit_open(p_unit);
  insert into res values (p_key || ':open', v_r) on conflict (name) do update set j = excluded.j;
  v_mk := (v_r #>> '{marking,id}')::uuid;
  v_r := public.marking_save(v_mk, (v_r #>> '{marking,rev}')::int, v_ops);
  insert into res values (p_key || ':save', v_r) on conflict (name) do update set j = excluded.j;
  v_r := public.marking_submit(v_mk, (v_r ->> 'rev')::int);
  insert into res values (p_key || ':submit', v_r) on conflict (name) do update set j = excluded.j;
  perform tests.as_postgres();
  insert into kv values (p_key, v_mk) on conflict (name) do update set id = excluded.id;
  return v_r;
end $$;
-- Signed in as the marker: Next script on an exam. Returns its answer.
create function pg_temp.next(p_marker text, p_exam text) returns jsonb language plpgsql as $$
declare
  v_marker uuid := pg_temp.uid(p_marker);
  v_exam uuid := pg_temp.k(p_exam);
  v_r jsonb;
begin
  perform tests.as_user(v_marker);
  v_r := public.marking_next(v_exam);
  perform tests.as_postgres();
  return v_r;
end $$;
-- The marker's next seeded script: their pieces until the next seed set to 0, then Next script, which must hand out a
-- seeded piece; it is kept as 'seed:<marker>:<n>', and marked (pg_temp.mark, key 'sm:<marker>:<n>'). Returns the
-- submit's answer.
create function pg_temp.seed(p_marker text, p_exam text, p_n int, p_marks numeric[]) returns jsonb language plpgsql as $$
declare
  v_r jsonb;
  v_unit uuid;
begin
  perform pg_temp.until0(p_exam, p_marker);
  v_r := pg_temp.next(p_marker, p_exam);
  v_unit := (v_r ->> 'unit_id')::uuid;
  if v_unit is null or not pg_temp.is_std(v_unit, 'seed') then
    raise exception 'pg_temp.seed: Next script gave % (%), not a seeded piece', pg_temp.nm(v_unit), v_r;
  end if;
  insert into kv values ('seed:' || p_marker || ':' || p_n, v_unit) on conflict (name) do update set id = excluded.id;
  return pg_temp.mark(p_marker, v_unit, p_marks, 'sm:' || p_marker || ':' || p_n);
end $$;
-- A second marking of a piece (as 057): its second pass taken as Next script would, then marked and submitted.
create function pg_temp.second(p text, p_marker text, p_marks numeric[]) returns void language plpgsql as $$
declare
  v_why text := public.marking_unit_blocked(pg_temp.u(p), pg_temp.uid(p_marker), null, true, 'second');
begin
  if v_why is not null then
    raise exception 'pg_temp.second: % cannot be given the second pass (%)', p_marker, v_why;
  end if;
  perform pg_temp.take(p, p_marker, 'second');
  if pg_temp.code(pg_temp.mark(p_marker, pg_temp.u(p), p_marks, 's:' || p)) <> 'ok' then
    raise exception 'pg_temp.second: the submit was refused';
  end if;
end $$;
-- Signed in as someone: a call's answer (p_sql is run as that user).
create function pg_temp.as(p_who text, p_sql text) returns jsonb language plpgsql as $$
declare
  v_who uuid := pg_temp.uid(p_who);
  v_r jsonb;
begin
  perform tests.as_user(v_who);
  execute p_sql into v_r;
  perform tests.as_postgres();
  return v_r;
end $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.u(text), pg_temp.r(text), pg_temp.code(jsonb), pg_temp.nm(uuid),
  pg_temp.keys(jsonb), pg_temp.found(text[], text), pg_temp.piece(jsonb, uuid), pg_temp.exam(jsonb, text) to public;

insert into public.subjects (name, kind) values ('ZZ Std', 'school'), ('ZZ Std Other', 'school');
insert into c values ('admin', tests.create_user('admin', 'active')), ('corr', tests.create_user('corrector', 'active'));
insert into c select 'm' || i, tests.marker(pg_temp.subj('ZZ Std')) from generate_series(1, 6) i;
insert into c values ('lead', tests.marker(pg_temp.subj('ZZ Std'), true)), ('olead', tests.marker(pg_temp.subj('ZZ Std Other'), true));
update public.profiles set first_name = 'Peregrine', last_name = 'Sixsmith' where id in (select id from c where name like 'm%');
update public.profiles set first_name = 'Ermengarde', last_name = 'Leadbetter' where id = pg_temp.uid('lead');

insert into kv values ('e', tests.marking_exam(pg_temp.subj('ZZ Std'))), ('d', tests.marking_exam(pg_temp.subj('ZZ Std'))),
  ('f', tests.marking_exam(pg_temp.subj('ZZ Std'))), ('n', tests.marking_exam(pg_temp.subj('ZZ Std'))),
  ('g', tests.marking_exam(pg_temp.subj('ZZ Std')));
select tests.structure(pg_temp.k(x)) from unnest(array['e', 'd', 'f', 'n', 'g']) x;
select tests.open_marking(pg_temp.k('e'),
  '{"double_marking": true, "sample_percent": 10, "tolerance_percent": 10, "seeds": true, "seed_every": 4, "practice": true}');
select tests.open_marking(pg_temp.k('d'), '{"double_marking": true, "sample_percent": 10, "seeds": true, "seed_every": 4, "practice": false}');
select tests.open_marking(pg_temp.k('f'));
select tests.open_marking(pg_temp.k('n'), '{"double_marking": false, "seeds": false, "practice": true}');
select tests.open_marking(pg_temp.k('g'), '{"double_marking": false, "seeds": true, "practice": true}');

-- The lead marks the pieces of exam e that become standards, and two of their own; m1 (cleared) marks x0.
select pg_temp.script(x, 'e') from unnest(array['p1', 'p2', 's1', 's2', 's3', 's4', 's5', 'c1', 'c2', 'x0', 'y0']) x;
select pg_temp.first('p1', 'lead', array[1, 1, 1]), pg_temp.first('p2', 'lead', array[2, 2, 2]), pg_temp.first('c1', 'lead', array[1, 2, 3]),
  pg_temp.first('c2', 'lead', array[1, 2, 3]);
select pg_temp.first(x, 'lead', array[3, 2, 5]) from unnest(array['s1', 's2', 's3', 's4', 's5']) x;
insert into res values ('clear_m1', pg_temp.as('lead', format($q$ select public.marking_marker_clear(%L, %L, 'Knows this paper well.') $q$, pg_temp.k('e'), pg_temp.uid('m1'))));
select pg_temp.first('x0', 'm1', array[1, 1, 1]);
-- y0: the lead's own marking in progress.
select pg_temp.take('y0', 'lead', 'live');
insert into res values ('y0_open', pg_temp.as('lead', format('select public.marking_unit_open(%L)', pg_temp.u('y0'))));

-- ---------------------------------------------------------------------------------------------
-- standard_only_from_the_leads_own_submitted_live_marking
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.code(pg_temp.r('clear_m1')), pg_temp.st('p1'), pg_temp.st('x0'), pg_temp.code(pg_temp.r('y0_open'))],
  array['ok', 'checked', 'checked', 'ok'], 'fixtures: m1 is cleared on e; the lead''s pieces and m1''s are checked; the lead has y0 open');
select is(array[
    pg_temp.code(pg_temp.as('admin', format($q$ select public.marking_standard_set(%L, 'practice') $q$, pg_temp.u('p1')))),
    pg_temp.code(pg_temp.as('m1', format($q$ select public.marking_standard_set(%L, 'practice') $q$, pg_temp.u('x0')))),
    pg_temp.code(pg_temp.as('olead', format($q$ select public.marking_standard_set(%L, 'practice') $q$, pg_temp.u('p1')))),
    pg_temp.code(pg_temp.as('corr', format($q$ select public.marking_standard_set(%L, 'practice') $q$, pg_temp.u('p1'))))],
  array['forbidden', 'forbidden', 'forbidden', 'forbidden'],
  'standard_only_from_the_leads_own_submitted_live_marking: an admin, a marker, another subject''s lead and a corrector are forbidden');
select is(array[
    pg_temp.code(pg_temp.as('lead', format($q$ select public.marking_standard_set(%L, 'practice') $q$, pg_temp.u('x0')))),
    pg_temp.code(pg_temp.as('lead', format($q$ select public.marking_standard_set(%L, 'seed') $q$, pg_temp.u('y0'))))],
  array['not_yours', 'not_yours'], 'the lead on another marker''s piece, and on their own marking still in progress: not_yours');
select is(array[
    pg_temp.code(pg_temp.as('lead', format($q$ select public.marking_standard_set(%L, 'other') $q$, pg_temp.u('p1')))),
    pg_temp.code(pg_temp.as('lead', format($q$ select public.marking_standard_set(%L, 'practice', 'ab') $q$, pg_temp.u('p1')))),
    pg_temp.code(pg_temp.as('lead', format($q$ select public.marking_standard_set(%L, 'practice', %L) $q$, pg_temp.u('p1'), repeat('x', 1001))))],
  array['invalid_input', 'invalid_input', 'invalid_input'], 'an unknown use, or a note under 3 or over 1,000 characters: invalid_input');
insert into res values ('set_p1', pg_temp.as('lead', format($q$ select public.marking_standard_set(%L, 'practice', 'Look at 2(b) carefully.') $q$, pg_temp.u('p1'))));
insert into res values ('set_p2', pg_temp.as('lead', format($q$ select public.marking_standard_set(%L, 'practice') $q$, pg_temp.u('p2'))));
insert into res select 'set_' || x, pg_temp.as('lead', format($q$ select public.marking_standard_set(%L, 'seed') $q$, pg_temp.u(x)))
from unnest(array['s1', 's2', 's3', 's4', 's5']) x;
select is((select array_agg(pg_temp.code(j) order by name) from res where name like 'set_%'), array_fill('ok'::text, array[7]),
  'the lead''s own submitted live pieces become two practice and five seeded scripts');
select is(array(select k from jsonb_object_keys(pg_temp.r('set_p1')) k order by 1), array['ok', 'standard_id'], 'the answer is {ok, standard_id}');
select is(array[(pg_temp.std('p1')).id, (pg_temp.std('p1')).use, (pg_temp.std('p1')).note, (pg_temp.std('s1')).use]::text[],
  array[pg_temp.r('set_p1') ->> 'standard_id', 'practice', 'Look at 2(b) carefully.', 'seed'], 'each is kept with its use and the lead''s note');
select is(array[pg_temp.stdmarks('p1'), pg_temp.stdmarks('p2'), pg_temp.stdmarks('s3')], array['1=1,2(a)=1,2(b)=1', '1=2,2(a)=2,2(b)=2', '1=3,2(a)=2,2(b)=5'],
  'the lead''s marks are copied');
select is((select count(*)::int from public.audit_log a where a.action = 'marking_standard_set' and a.actor_id = pg_temp.uid('lead')
           and a.target_id in (select u.id from public.marking_units u where u.exam_id = pg_temp.k('e'))),
  7, 'each is audited (marking_standard_set)');
select is(array[
    pg_temp.code(pg_temp.as('lead', format($q$ select public.marking_standard_set(%L, 'seed') $q$, pg_temp.u('p1')))),
    (pg_temp.as('lead', format($q$ select public.marking_standard_set(%L, 'seed') $q$, pg_temp.u('p1')))) ->> 'reason'],
  array['conflict', 'already'], 'one per piece: a piece already used is refused (conflict, already)');
update public.marking_units set on_hold = true, hold_reason = 'taken_back' where id = pg_temp.u('c2');
select is(pg_temp.code(pg_temp.as('lead', format($q$ select public.marking_standard_set(%L, 'seed') $q$, pg_temp.u('c2')))), 'on_hold',
  'a piece on hold is refused');
update public.marking_units set on_hold = false, hold_reason = null where id = pg_temp.u('c2');

-- ---------------------------------------------------------------------------------------------
-- standard_marks_stay_when_the_live_marking_changes
-- ---------------------------------------------------------------------------------------------
insert into res values ('chg_p1', pg_temp.as('lead', format($q$ select public.marking_save(%L, %s, %L::jsonb, 0, 'A slip on question 1.') $q$,
  pg_temp.k('f:p1'), (select rev from public.markings where id = pg_temp.k('f:p1')),
  jsonb_build_array(jsonb_build_object('op', 'mark', 'question_id', (pg_temp.ops(pg_temp.u('p1'), array[2]) -> 0 ->> 'question_id'), 'mark', 2, 'na', false)))));
select is(array[pg_temp.code(pg_temp.r('chg_p1')), pg_temp.livemarks('p1'), pg_temp.stdmarks('p1'), (pg_temp.std('p1')).retired_at::text],
  array['ok', '1=2,2(a)=1,2(b)=1', '1=1,2(a)=1,2(b)=1', null],
  'standard_marks_stay_when_the_live_marking_changes: the lead changes their live mark; the practice script''s marks stay as copied');

-- ---------------------------------------------------------------------------------------------
-- eleventh_standard_refused (exam g)
-- ---------------------------------------------------------------------------------------------
select pg_temp.scripts('g', 'g', 11);
select pg_temp.first('g' || i, 'lead', array[1, 1, 1]) from generate_series(1, 11) i;
insert into res select 'g_' || i, pg_temp.as('lead', format($q$ select public.marking_standard_set(%L, 'practice') $q$, pg_temp.u('g' || i)))
from generate_series(1, 11) i;
select is((select array_agg(pg_temp.code(j) order by (substr(name, 3))::int) from res where name like 'g\_%'),
  array_fill('ok'::text, array[10]) || 'too_many'::text, 'eleventh_standard_refused: ten practice scripts per exam and group, then too_many');
insert into res values ('g_seed', pg_temp.as('lead', format($q$ select public.marking_standard_set(%L, 'seed') $q$, pg_temp.u('g11'))));
insert into res values ('g_retire', pg_temp.as('lead', format($q$ select public.marking_standard_retire(%L, 'Too easy a script.') $q$, (pg_temp.std('g1')).id)));
select is(array[pg_temp.code(pg_temp.r('g_seed')), pg_temp.code(pg_temp.r('g_retire'))], array['ok', 'ok'],
  'the count is per use: the eleventh piece may be a seeded script; one practice script stops being used');
select pg_temp.script('g12', 'g');
select pg_temp.first('g12', 'lead', array[1, 1, 1]);
select is(pg_temp.code(pg_temp.as('lead', format($q$ select public.marking_standard_set(%L, 'practice') $q$, pg_temp.u('g12')))), 'ok',
  'a retired one no longer counts: another practice script may be added');
select is(pg_temp.code(pg_temp.as('lead', format($q$ select public.marking_standard_set(%L, 'practice') $q$, pg_temp.u('x0')))), 'not_yours',
  'and the rules still hold');

-- ---------------------------------------------------------------------------------------------
-- The lead's list (marking_standards_list).
-- ---------------------------------------------------------------------------------------------
insert into res values ('list_lead', pg_temp.as('lead', format('select public.marking_standards_list(%L)', pg_temp.k('e'))));
insert into res values ('list_admin', pg_temp.as('admin', format('select public.marking_standards_list(%L)', pg_temp.k('e'))));
select is(array[pg_temp.code(pg_temp.r('list_lead')), pg_temp.code(pg_temp.r('list_admin')),
    pg_temp.code(pg_temp.as('m1', format('select public.marking_standards_list(%L)', pg_temp.k('e')))),
    pg_temp.code(pg_temp.as('olead', format('select public.marking_standards_list(%L)', pg_temp.k('e'))))],
  array['ok', 'ok', 'forbidden', 'forbidden'], 'the list is for the subject''s lead and admins');
select is((select string_agg(pg_temp.nm((x ->> 'unit_id')::uuid) || ' ' || (x ->> 'use') || ' ' || pg_temp.n(x, 'total') || '/' || pg_temp.n(x, 'max_total'), ',' order by pg_temp.nm((x ->> 'unit_id')::uuid))
           from jsonb_array_elements(pg_temp.r('list_lead') -> 'standards') x),
  'p1 practice 3/10,p2 practice 6/10,s1 seed 10/10,s2 seed 10/10,s3 seed 10/10,s4 seed 10/10,s5 seed 10/10',
  'it lists each standard with the lead''s total');
select is(array(select k from jsonb_object_keys(pg_temp.r('list_lead') -> 'standards' -> 0) k order by 1),
  array['attempts', 'group_label', 'id', 'index_number', 'max_total', 'note', 'retired', 'script_number', 'total', 'unit_id', 'use'],
  'with its script number, index number, group, note, whether retired and its attempts');
select is((select string_agg(pg_temp.nm((x ->> 'unit_id')::uuid), ',' order by pg_temp.nm((x ->> 'unit_id')::uuid))
           from jsonb_array_elements(pg_temp.r('list_lead') -> 'can_add') x),
  'c1,c2', 'can_add: the lead''s own submitted live pieces that are not standards (not y0, in progress; not m1''s x0)');
select is(array[pg_temp.r('list_admin') ? 'can_add', jsonb_array_length(pg_temp.r('list_admin') -> 'standards') = 7],
  array[false, true], 'an admin sees the list without can_add');
select is(pg_temp.found(array['Wilhelmina', 'Quarterfield'], pg_temp.r('list_lead')::text), '{}'::text[], 'the list names no candidate');

-- ---------------------------------------------------------------------------------------------
-- standard_piece_is_never_second_marked (exam d: double marking and seeds on, practice off)
-- ---------------------------------------------------------------------------------------------
select pg_temp.script(x, 'd') from unnest(array['d1', 'd2', 'd3']) x;
update public.marking_units set sample_draw = 0 where id in (pg_temp.u('d1'), pg_temp.u('d2'));
select pg_temp.first('d1', 'lead', array[3, 2, 5]), pg_temp.first('d2', 'lead', array[3, 2, 5]);
select pg_temp.second('d1', 'm5', array[3, 2, 5]);
select pg_temp.take('d2', 'm6', 'second');
insert into res values ('d2_open', pg_temp.as('m6', format('select public.marking_unit_open(%L)', pg_temp.u('d2'))));
select is(array[pg_temp.cs('d1'), pg_temp.cs('d2'), pg_temp.ms('d2', 'm6'), pg_temp.ended('d2', 'm6')],
  array['checked', 'waiting_second', 'second in_progress', 'second open'],
  'fixtures: d1 second-marked by m5 within tolerance; d2 waits for m6''s second marking');
select is(pg_temp.code(pg_temp.as('lead', format($q$ select public.marking_standard_set(%L, 'practice') $q$, pg_temp.u('d1')))), 'conflict',
  'a practice script on an exam with practice off: conflict');
insert into res values ('set_d2', pg_temp.as('lead', format($q$ select public.marking_standard_set(%L, 'seed') $q$, pg_temp.u('d2'))));
insert into res values ('set_d1', pg_temp.as('lead', format($q$ select public.marking_standard_set(%L, 'seed') $q$, pg_temp.u('d1'))));
select is(array[pg_temp.code(pg_temp.r('set_d2')), pg_temp.wanted('d2'), pg_temp.cs('d2'), pg_temp.st('d2'), pg_temp.fm('d2')],
  array['ok', 'false', 'checked', 'checked', '1=3 first,2(a)=2 first,2(b)=5 first'],
  'standard_piece_is_never_second_marked: a piece waiting for a second marking that becomes a seed is no longer second-marked, and is checked');
select is(array[pg_temp.ms('d2', 'm6'), pg_temp.ended('d2', 'm6'), pg_temp.blocked('d2', 'm6', 'second'), pg_temp.allowed('d', 'm6', 'second')],
  array['second set_aside switched_off', 'second switched_off', 'not_ready', ''],
  'the second marker''s hold ends and their marking is set aside; nobody may be given its second pass');

-- ---------------------------------------------------------------------------------------------
-- seed_is_never_offered_to_the_lead_who_set_it
-- ---------------------------------------------------------------------------------------------
select pg_temp.until0('d', 'lead');
insert into res values ('lead_next_d', pg_temp.next('lead', 'd'));
select is(array[pg_temp.allowed('d', 'lead', 'seed'), pg_temp.blocked('d1', 'lead', 'seed'), pg_temp.code(pg_temp.r('lead_next_d')),
    pg_temp.nm((pg_temp.r('lead_next_d') ->> 'unit_id')::uuid)],
  array['', 'not_eligible', 'ok', 'd3'],
  'seed_is_never_offered_to_the_lead_who_set_it: with no pieces left before a seed, the lead''s Next script gives a live piece');

-- ---------------------------------------------------------------------------------------------
-- seed_is_never_offered_to_a_marker_with_a_pass_on_that_piece; seed_skips_conflict_and_name_seen
-- ---------------------------------------------------------------------------------------------
insert into public.marker_conflicts (marker_id, student_id, recorded_by, recorded_at) values (pg_temp.uid('m4'), pg_temp.student('d1'), pg_temp.uid('admin'), now());
insert into public.marking_unit_exclusions (unit_id, marker_id, reason) values (pg_temp.u('d1'), pg_temp.uid('m3'), 'name_seen');
select is(array[pg_temp.blocked('d1', 'm5', 'seed'), pg_temp.allowed('d', 'm5', 'seed'), pg_temp.blocked('d1', 'm6', 'seed')],
  array['not_eligible', 'd2', 'null'],
  'seed_is_never_offered_to_a_marker_with_a_pass_on_that_piece: m5''s second marking stands on d1 (m6 may have it)');
select is(array[pg_temp.blocked('d1', 'm4', 'seed'), pg_temp.allowed('d', 'm4', 'seed'), pg_temp.blocked('d1', 'm3', 'seed'), pg_temp.allowed('d', 'm3', 'seed')],
  array['conflict_of_interest', 'd2', 'name_seen', 'd2'],
  'seed_skips_conflict_and_name_seen: a declared conflict, or a name seen on the piece, keeps the seed away');

-- ---------------------------------------------------------------------------------------------
-- seed_piece_opens_with_the_same_keys_as_a_live_piece (Review Focus 1). m1 (cleared on e) takes a live piece, then a
-- seeded one.
-- ---------------------------------------------------------------------------------------------
select pg_temp.scripts('x', 'e', 8);
select pg_temp.until0('e', 'm1', 3);
insert into res values ('next_live', pg_temp.next('m1', 'e'));
insert into kv values ('a:live1', (pg_temp.r('next_live') ->> 'unit_id')::uuid);
insert into res values ('open_live', pg_temp.as('m1', format('select public.marking_unit_open(%L)', pg_temp.a('live1'))));
insert into res values ('work_live', pg_temp.as('m1', 'select public.marking_my_work()'));
select pg_temp.mark('m1', pg_temp.a('live1'), array[1, 1, 1], 'ml1');
select is(array[pg_temp.code(pg_temp.r('next_live')), (pg_temp.nm(pg_temp.a('live1')) like 'x_')::text, pg_temp.code(pg_temp.r('ml1:submit')),
    (pg_temp.xm('e', 'm1')).until_seed::text],
  array['ok', 'true', 'ok', '2'], 'fixtures: m1''s Next script gives a live piece; its submit counts down to the next seed');
select pg_temp.until0('e', 'm1');
insert into res values ('next_seed', pg_temp.next('m1', 'e'));
insert into kv values ('a:seedA', (pg_temp.r('next_seed') ->> 'unit_id')::uuid);
select is(array[pg_temp.code(pg_temp.r('next_seed')), pg_temp.is_std(pg_temp.a('seedA'), 'seed')::text, ((pg_temp.xm('e', 'm1')).until_seed between 2 and 5)::text],
  array['ok', 'true', 'true'],
  'seed_comes_when_until_seed_runs_out_and_the_gap_is_redrawn: at 0 the next piece is a seed; the gap is redrawn between ceil(4/2) and ceil(4/2) + 4 - 1');
insert into res values ('open_seed', pg_temp.as('m1', format('select public.marking_unit_open(%L)', pg_temp.a('seedA'))));
insert into res values ('work_seed', pg_temp.as('m1', 'select public.marking_my_work()'));
select is(pg_temp.keys(pg_temp.r('open_seed')), pg_temp.keys(pg_temp.r('open_live')),
  'seed_piece_opens_with_the_same_keys_as_a_live_piece: marking_unit_open answers with the same key paths');
select is(array[pg_temp.r('open_seed') #>> '{marking,practice}', pg_temp.r('open_seed') #>> '{marking,status}', pg_temp.r('open_seed') #>> '{marking,rev}',
    (pg_temp.r('open_seed') #>> '{unit,hold_until}') = (pg_temp.r('open_live') #>> '{unit,hold_until}'), pg_temp.r('open_seed') #>> '{marking,total}',
    pg_temp.r('open_seed') #>> '{marking,lead_note}', pg_temp.r('open_seed') #>> '{marking,sent_back_note}']::text[],
  array['false', 'in_progress', '0', 'true', null, null, null],
  'and the same values where a live piece would show its kind: not practice, a fresh marking, the same 2-hour hold, no note');
select is(array(select k from jsonb_object_keys(pg_temp.piece(pg_temp.r('work_seed'), pg_temp.a('seedA'))) k order by 1),
          array(select k from jsonb_object_keys(pg_temp.piece(pg_temp.r('work_live'), pg_temp.a('live1'))) k order by 1),
  'marking_my_work shows the seed with the keys of a live piece');
select is(pg_temp.piece(pg_temp.r('work_seed'), pg_temp.a('seedA')) - array['unit_id', 'script_number', 'index_number', 'hold_until'],
          pg_temp.piece(pg_temp.r('work_live'), pg_temp.a('live1')) - array['unit_id', 'script_number', 'index_number', 'hold_until'],
  'and the same values: taken by Next script, not practice, nothing saved yet');
select is(array(select k from jsonb_object_keys(pg_temp.r('next_seed')) k order by 1), array(select k from jsonb_object_keys(pg_temp.r('next_live')) k order by 1),
  'marking_next answers with the same keys');
select is(pg_temp.r('next_seed') -> 'resumed', pg_temp.r('next_live') -> 'resumed', 'and says resumed alike');
select is(array[position('seed' in lower(pg_temp.r('open_seed')::text)), position('seed' in lower(pg_temp.r('work_seed')::text)),
    position('seed' in lower(pg_temp.r('next_seed')::text))], array[0, 0, 0], 'none of the three texts holds "seed"');
select is(pg_temp.code(pg_temp.as('m1', format('select public.marking_picture_paths(%L, %L::uuid[])', pg_temp.a('seedA'),
    array[(pg_temp.r('open_seed') -> 'pages' -> 0 ->> 'page_id')::uuid]))), 'ok', 'the picture check lets m1 see the seed''s pages, as a live piece''s');

-- ---------------------------------------------------------------------------------------------
-- given_back_seed_returns_later_and_tells_nothing (Review Focus 1)
-- ---------------------------------------------------------------------------------------------
insert into res values ('gb_seed', pg_temp.as('m1', format('select public.marking_give_back(%L)', pg_temp.a('seedA'))));
insert into res values ('until_gb', to_jsonb((pg_temp.xm('e', 'm1')).until_seed));
insert into res values ('next_gb', pg_temp.next('m1', 'e'));
insert into kv values ('a:live2', (pg_temp.r('next_gb') ->> 'unit_id')::uuid);
select is(array[pg_temp.r('gb_seed')::text, pg_temp.ms(pg_temp.nm(pg_temp.a('seedA')), 'm1'), ((pg_temp.r('until_gb'))::int > 0)::text],
  array['{"ok": true}', 'seed set_aside given_back', 'true'],
  'given_back_seed_returns_later_and_tells_nothing: giving it back answers {ok} as for any piece; the count to the next seed is positive again');
select is(array[pg_temp.code(pg_temp.r('next_gb')), (pg_temp.nm(pg_temp.a('live2')) like 'x_')::text, pg_temp.r('next_gb') ->> 'resumed',
    (((pg_temp.xm('e', 'm1')).until_seed)::text = pg_temp.r('until_gb')::text)::text],
  array['ok', 'true', 'false', 'true'], 'the next piece is a live one, and nothing counted down');
select is(position(pg_temp.nm(pg_temp.a('seedA')) in pg_temp.allowed('e', 'm1', 'seed')) > 0, true, 'the given-back seed may come again later');
select pg_temp.mark('m1', pg_temp.a('live2'), array[1, 1, 1], 'ml2');

-- ---------------------------------------------------------------------------------------------
-- seed_submit_within_tolerance_tells_nothing
-- ---------------------------------------------------------------------------------------------
select pg_temp.seed('m1', 'e', 1, array[3, 2, 4]);
select is(array[pg_temp.code(pg_temp.r('sm:m1:1:submit')), pg_temp.r('sm:m1:1:submit') ->> 'feedback',
    (pg_temp.xm('e', 'm1')).misses::text, (select feedback_at::text from public.markings where id = pg_temp.k('sm:m1:1'))],
  array['ok', null, '0', null], 'seed_submit_within_tolerance_tells_nothing: no feedback, no miss');
select is(pg_temp.code(pg_temp.as('m1', format('select public.marking_feedback(%L)', pg_temp.k('sm:m1:1')))), 'forbidden',
  'and the marker cannot ask for the lead''s marks');
select is(pg_temp.keys(pg_temp.r('sm:m1:1:save')) || '{|}'::text[] || pg_temp.keys(pg_temp.r('sm:m1:1:submit')),
  pg_temp.keys(pg_temp.r('ml1:save')) || '{|}'::text[] || pg_temp.keys(pg_temp.r('ml1:submit')), 'its save and submit answer with the keys of a live piece''s');
select is(pg_temp.code(pg_temp.as('m1', format($q$ select public.marking_save(%L, %s, %L::jsonb, 0, 'Second look at 2(b).') $q$,
    pg_temp.k('sm:m1:1'), (select rev from public.markings where id = pg_temp.k('sm:m1:1')), pg_temp.ops(pg_temp.k('seed:m1:1'), array[3, 2, 5])))),
  'ok', 'and it may be changed after submit, as a live piece may');

-- ---------------------------------------------------------------------------------------------
-- seed_outside_tolerance_shows_the_leads_marks_and_locks_the_attempt; seed_pass_never_touches_the_candidates_marking
-- ---------------------------------------------------------------------------------------------
select pg_temp.until0('e', 'm1');
insert into res values ('next_out', pg_temp.next('m1', 'e'));
insert into kv values ('a:seedO', (pg_temp.r('next_out') ->> 'unit_id')::uuid);
insert into res values ('snap_before', to_jsonb(pg_temp.snap(pg_temp.nm(pg_temp.a('seedO')))));
select pg_temp.mark('m1', pg_temp.a('seedO'), array[0, 0, 0], 'smo');
select is(array[pg_temp.is_std(pg_temp.a('seedO'), 'seed')::text, pg_temp.r('smo:submit') ->> 'feedback', (pg_temp.xm('e', 'm1')).misses::text,
    ((select feedback_at from public.markings where id = pg_temp.k('smo')) is not null)::text],
  array['true', 'seed', '1', 'true'], 'seed_outside_tolerance_shows_the_leads_marks_and_locks_the_attempt: the submit says seed, and it is a miss');
insert into res values ('fb_o', pg_temp.as('m1', format('select public.marking_feedback(%L)', pg_temp.k('smo'))));
select is(array[pg_temp.code(pg_temp.r('fb_o')), pg_temp.r('fb_o') ->> 'use', pg_temp.n(pg_temp.r('fb_o'), 'total'), pg_temp.n(pg_temp.r('fb_o'), 'lead_total'),
    pg_temp.n(pg_temp.r('fb_o'), 'max_total')],
  array['ok', 'seed', '0', '10', '10'], 'the lead''s marks are shown beside the marker''s');
select is((select string_agg(concat_ws(' ', x ->> 'label', pg_temp.n(x, 'max'), pg_temp.n(x, 'yours'), pg_temp.n(x, 'lead'), x ->> 'out'), ',' order by o)
           from jsonb_array_elements(pg_temp.r('fb_o') -> 'questions') with ordinality t(x, o)),
  '1 3 0 3 true,2(a) 2 0 2 true,2(b) 5 0 5 true', 'question by question, with the ones outside tolerance');
select is(array(select k from jsonb_object_keys(pg_temp.r('fb_o') -> 'questions' -> 0) k order by 1),
  array['label', 'lead', 'lead_na', 'max', 'out', 'question_id', 'yours', 'yours_na'], 'each question says label, max, both marks and NRs, and out');
select is(pg_temp.code(pg_temp.as('m1', format($q$ select public.marking_save(%L, %s, %L::jsonb, 0, 'I see now.') $q$,
    pg_temp.k('smo'), (select rev from public.markings where id = pg_temp.k('smo')), pg_temp.ops(pg_temp.a('seedO'), array[3, 2, 5])))),
  'locked', 'and the attempt is locked');
select is(pg_temp.snap(pg_temp.nm(pg_temp.a('seedO'))), pg_temp.r('snap_before') #>> '{}',
  'seed_pass_never_touches_the_candidates_marking: the live marking, its marks, the final marks, the piece''s state and check state, the script''s state and audit rows are as before');

-- ---------------------------------------------------------------------------------------------
-- seed_within_tolerance_resets_the_run: out (above), out, in, out: one miss in a row, not paused.
-- ---------------------------------------------------------------------------------------------
select pg_temp.seed('m1', 'e', 2, array[0, 0, 0]);
insert into res values ('misses_2', to_jsonb((pg_temp.xm('e', 'm1')).misses));
select pg_temp.seed('m1', 'e', 3, array[3, 2, 5]);
insert into res values ('misses_3', to_jsonb((pg_temp.xm('e', 'm1')).misses));
select pg_temp.seed('m1', 'e', 4, array[0, 0, 0]);
select is(array[pg_temp.r('misses_2')::int, pg_temp.r('misses_3')::int, (pg_temp.xm('e', 'm1')).misses], array[2, 0, 1],
  'seed_within_tolerance_resets_the_run: out, out, in, out counts 2, then 0, then 1');
select is(array[(pg_temp.xm('e', 'm1')).paused_at is null, public.marking_marker_paused(pg_temp.k('e'), pg_temp.uid('m1'))], array[true, false],
  'and the marker is not paused');

-- ---------------------------------------------------------------------------------------------
-- each_seed_once_per_marker: m1 has submitted all five; no seed is left for them.
-- ---------------------------------------------------------------------------------------------
select pg_temp.until0('e', 'm1');
insert into res values ('next_none', pg_temp.next('m1', 'e'));
select is(array[pg_temp.allowed('e', 'm1', 'seed'), pg_temp.code(pg_temp.r('next_none')),
    pg_temp.is_std((pg_temp.r('next_none') ->> 'unit_id')::uuid, 'seed')::text,
    (select count(distinct m.unit_id)::text from public.markings m where m.marker_id = pg_temp.uid('m1') and m.kind = 'seed' and m.status = 'submitted')],
  array['', 'ok', 'false', '5'], 'each_seed_once_per_marker: five seeds, each submitted once; then Next script gives a live piece');
select is(public.marking_unit_blocked(pg_temp.u('s1'), pg_temp.uid('m1'), null, true, 'seed'), 'not_eligible', 'a seed they did is not_eligible');
insert into kv values ('a:live3', (pg_temp.r('next_none') ->> 'unit_id')::uuid);
select pg_temp.mark('m1', pg_temp.a('live3'), array[1, 1, 1], 'ml3');

-- ---------------------------------------------------------------------------------------------
-- Practice (m3, not cleared on e): practice_first_gates_next_and_assign; practice_piece_says_practice_and_shows_the_differences;
-- practice_marks_never_reach_final_marks_or_the_check; practice_wait_after_the_last_practice_piece. z1 is an open piece.
-- m3 marks both practice pieces 3, 1, 1: outside tolerance on p1 (lead 1, 1, 1), within on p2 (lead 2, 2, 2).
-- ---------------------------------------------------------------------------------------------
select pg_temp.script('z1', 'e');
insert into res values ('snap_p1', to_jsonb(pg_temp.snap('p1'))), ('snap_p2', to_jsonb(pg_temp.snap('p2')));
insert into res values ('pn1', pg_temp.next('m3', 'e'));
insert into kv values ('a:pr1', (pg_temp.r('pn1') ->> 'unit_id')::uuid);
select is(array[pg_temp.code(pg_temp.r('pn1')), pg_temp.is_std(pg_temp.a('pr1'), 'practice')::text, pg_temp.ended(pg_temp.nm(pg_temp.a('pr1')), 'm3'),
    ((select a.hold_until from public.marking_assignments a where a.unit_id = pg_temp.a('pr1') and a.marker_id = pg_temp.uid('m3') and a.ended_at is null) = now() + interval '2 hours')::text],
  array['ok', 'true', 'practice open', 'true'], 'practice_first_gates_next_and_assign: a marker not cleared gets a practice piece, held 2 hours');
select is(array[pg_temp.blocked('z1', 'm3'), pg_temp.allowed('e', 'm3', 'live'), public.marking_marker_cleared(pg_temp.k('e'), pg_temp.uid('m3'))::text],
  array['practice_first', '', 'false'], 'no live piece may be handed to them');
select is(array[
    pg_temp.code(pg_temp.as('admin', format($q$ select public.marking_assign(array[%L]::uuid[], %L, 'Help with the backlog.') $q$, pg_temp.u('z1'), pg_temp.uid('m3')))),
    pg_temp.code(pg_temp.as('admin', format($q$ select public.marking_assign_some(%L, null, %L, 2, 'Help with the backlog.') $q$, pg_temp.k('e'), pg_temp.uid('m3')))),
    pg_temp.us('z1')],
  array['practice_first', 'practice_first', 'open'], 'an admin cannot assign them live pieces (practice_first)');
insert into res values ('pr1_open', pg_temp.as('m3', format('select public.marking_unit_open(%L)', pg_temp.a('pr1'))));
insert into res values ('pr1_work', pg_temp.as('m3', 'select public.marking_my_work()'));
select is(array[pg_temp.code(pg_temp.r('pr1_open')), pg_temp.r('pr1_open') #>> '{marking,practice}', pg_temp.piece(pg_temp.r('pr1_work'), pg_temp.a('pr1')) ->> 'practice'],
  array['ok', 'true', 'true'], 'practice_piece_says_practice_and_shows_the_differences: the piece says practice when opened and in the list');
select is(pg_temp.keys(pg_temp.r('pr1_open')), pg_temp.keys(pg_temp.r('open_live')), 'and nothing else differs: the same key paths as a live piece');
select is(array[pg_temp.exam(pg_temp.r('pr1_work'), 'e') -> 'practice', pg_temp.exam(pg_temp.r('pr1_work'), 'e') -> 'left', pg_temp.exam(pg_temp.r('pr1_work'), 'e') -> 'paused'],
  array['{"done": 0, "needed": 2, "waiting": false}'::jsonb, '1'::jsonb, 'false'::jsonb],
  'their exam says practice: 0 of 2 done; left counts the other practice piece');
select is(pg_temp.code(pg_temp.as('m3', format('select public.marking_picture_paths(%L, %L::uuid[])', pg_temp.a('pr1'),
    array[(pg_temp.r('pr1_open') -> 'pages' -> 0 ->> 'page_id')::uuid]))), 'ok', 'the picture check lets them see a practice piece''s pages');
select pg_temp.mark('m3', pg_temp.a('pr1'), array[3, 1, 1], 'pm1');
select is(array[pg_temp.code(pg_temp.r('pm1:submit')), pg_temp.r('pm1:submit') ->> 'feedback',
    ((select feedback_at from public.markings where id = pg_temp.k('pm1')) is not null)::text],
  array['ok', 'practice', 'true'], 'the submit says practice');
insert into res values ('fb_p', pg_temp.as('m3', format('select public.marking_feedback(%L)', pg_temp.k('pm1'))));
select is(array[pg_temp.code(pg_temp.r('fb_p')), pg_temp.r('fb_p') ->> 'use', pg_temp.n(pg_temp.r('fb_p'), 'total'),
    pg_temp.n(pg_temp.r('fb_p'), 'lead_total'), (select string_agg(x ->> 'out', ',' order by o) from jsonb_array_elements(pg_temp.r('fb_p') -> 'questions') with ordinality t(x, o))],
  array['ok', 'practice', '5',
        case pg_temp.nm(pg_temp.a('pr1')) when 'p1' then '3' else '6' end,
        case pg_temp.nm(pg_temp.a('pr1')) when 'p1' then 'true,false,false' else 'false,false,false' end],
  'and the differences from the lead''s marks are shown');
select is(pg_temp.r('fb_p') ->> 'note', case pg_temp.nm(pg_temp.a('pr1')) when 'p1' then 'Look at 2(b) carefully.' end, 'with the lead''s note');
select is(pg_temp.code(pg_temp.as('m3', format($q$ select public.marking_save(%L, %s, %L::jsonb, 0, 'I see now.') $q$,
    pg_temp.k('pm1'), (select rev from public.markings where id = pg_temp.k('pm1')), pg_temp.ops(pg_temp.a('pr1'), array[1, 1, 1])))),
  'locked', 'a practice attempt is locked once its differences are shown');
select is(array[pg_temp.snap('p1'), pg_temp.snap('p2')], array[pg_temp.r('snap_p1') #>> '{}', pg_temp.r('snap_p2') #>> '{}'],
  'practice_marks_never_reach_final_marks_or_the_check: the piece''s marking, final marks, check state, reviews and script are as before');
insert into res values ('pn2', pg_temp.next('m3', 'e'));
insert into kv values ('a:pr2', (pg_temp.r('pn2') ->> 'unit_id')::uuid);
select is(array[pg_temp.code(pg_temp.r('pn2')), pg_temp.is_std(pg_temp.a('pr2'), 'practice')::text, (pg_temp.a('pr2') <> pg_temp.a('pr1'))::text],
  array['ok', 'true', 'true'], 'Next script gives the other practice piece');
select pg_temp.mark('m3', pg_temp.a('pr2'), array[3, 1, 1], 'pm2');
insert into res values ('pn3', pg_temp.next('m3', 'e'));
insert into res values ('pr_work', pg_temp.as('m3', 'select public.marking_my_work()'));
select is(array[pg_temp.r('pm2:submit') ->> 'feedback', pg_temp.code(pg_temp.r('pn3'))], array['practice', 'practice_wait'],
  'practice_wait_after_the_last_practice_piece: with every practice piece done, Next script says practice_wait');
select is(array[pg_temp.exam(pg_temp.r('pr_work'), 'e') -> 'practice', pg_temp.exam(pg_temp.r('pr_work'), 'e') -> 'left'],
  array['{"done": 2, "needed": 2, "waiting": true}'::jsonb, '0'::jsonb], 'and their exam says 2 of 2 done, waiting for the lead');
select is(array[pg_temp.snap('p1'), pg_temp.snap('p2'), pg_temp.us('z1')], array[pg_temp.r('snap_p1') #>> '{}', pg_temp.r('snap_p2') #>> '{}', 'open'],
  'neither practice attempt touched the candidates'' marking or its check, and no live piece was handed out');

-- practice_not_ready (exam n: practice on, no practice script).
insert into res values ('nn', pg_temp.next('m4', 'n'));
insert into res values ('n_work', pg_temp.as('m4', 'select public.marking_my_work()'));
select is(array[pg_temp.code(pg_temp.r('nn')), (pg_temp.exam(pg_temp.r('n_work'), 'n') -> 'practice')::text],
  array['practice_not_ready', '{"done": 0, "needed": 0, "waiting": false}'], 'with no practice script yet, Next script says practice_not_ready');

-- ---------------------------------------------------------------------------------------------
-- lead_needs_no_practice (the lead still holds y0)
-- ---------------------------------------------------------------------------------------------
insert into res values ('lead_next', pg_temp.next('lead', 'e'));
insert into res values ('lead_work', pg_temp.as('lead', 'select public.marking_my_work()'));
select is(array[public.marking_marker_cleared(pg_temp.k('e'), pg_temp.uid('lead'))::text, pg_temp.code(pg_temp.r('lead_next')),
    (select a.kind::text from public.marking_assignments a
     where a.unit_id = (pg_temp.r('lead_next') ->> 'unit_id')::uuid and a.marker_id = pg_temp.uid('lead') and a.ended_at is null),
    (pg_temp.exam(pg_temp.r('lead_work'), 'e') -> 'practice')::text],
  array['true', 'ok', 'live', 'null'], 'lead_needs_no_practice: the lead is cleared, Next script gives them live work, and their list asks no practice');

-- ---------------------------------------------------------------------------------------------
-- The pause (m2, cleared on e). m2 marks l1 (checked), second-marks q1 (first-marked by m5, sampled) within tolerance,
-- misses two seeds, holds h1 in progress, then misses a third.
-- ---------------------------------------------------------------------------------------------
select pg_temp.script(x, 'e') from unnest(array['l1', 'q1', 'h1']) x;
update public.marking_units set sample_draw = 0 where id = pg_temp.u('q1');
insert into res values ('clear_m2', pg_temp.as('lead', format($q$ select public.marking_marker_clear(%L, %L, 'Practised on paper.') $q$, pg_temp.k('e'), pg_temp.uid('m2'))));
insert into res values ('clear_m5', pg_temp.as('lead', format($q$ select public.marking_marker_clear(%L, %L, 'Practised on paper.') $q$, pg_temp.k('e'), pg_temp.uid('m5'))));
select pg_temp.first('l1', 'm2', array[1, 1, 1]);
select pg_temp.first('q1', 'm5', array[2, 2, 2]);
select pg_temp.second('q1', 'm2', array[2, 2, 2]);
select is(array[pg_temp.code(pg_temp.r('clear_m2')), pg_temp.cs('l1'), pg_temp.st('l1'), pg_temp.cs('q1'), pg_temp.ms('q1', 'm2')],
  array['ok', 'checked', 'checked', 'checked', 'second submitted'], 'fixtures: m2''s l1 is checked; their second marking of q1 checked it');
select pg_temp.seed('m2', 'e', 1, array[0, 0, 0]);
select pg_temp.seed('m2', 'e', 2, array[0, 0, 0]);
select pg_temp.take('h1', 'm2', 'live');
insert into res values ('h1_open', pg_temp.as('m2', format('select public.marking_unit_open(%L)', pg_temp.u('h1'))));
insert into kv values ('a:seed3', (select st.unit_id from public.marking_standards st where st.exam_id = pg_temp.k('e') and st.use = 'seed'
  and not exists (select 1 from public.markings m where m.unit_id = st.unit_id and m.marker_id = pg_temp.uid('m2')) order by st.unit_id limit 1));
select pg_temp.take(pg_temp.nm(pg_temp.a('seed3')), 'm2', 'seed');
insert into res values ('notices_before', to_jsonb((select count(*)::int from public.script_notices where kind = 'marker_paused' and exam_id = pg_temp.k('e'))));
select pg_temp.mark('m2', pg_temp.a('seed3'), array[0, 0, 0], 'sm3');
select is(array[pg_temp.r('sm:m2:1:submit') ->> 'feedback', pg_temp.r('sm:m2:2:submit') ->> 'feedback', pg_temp.r('sm3:submit') ->> 'feedback',
    (pg_temp.xm('e', 'm2')).misses::text, ((pg_temp.xm('e', 'm2')).paused_at is not null)::text, ((pg_temp.xm('e', 'm2')).pause_applied_at is null)::text],
  array['seed', 'seed', 'seed', '3', 'true', 'true'],
  'three_misses_in_a_row_pause_the_marker: the third miss in a row pauses m2 on the exam; the pause is applied later');
select is((select array[count(*)::text, min(a.actor_id::text), min(a.target_type), bool_and(a.reason like 'three seeded scripts outside tolerance%')::text]
           from public.audit_log a where a.action = 'marker_paused' and a.target_id = pg_temp.uid('m2')),
  array['1', null, 'marker', 'true'], 'audited marker_paused, with no actor and the reason');
select is((select count(*)::int from public.script_notices where kind = 'marker_paused' and exam_id = pg_temp.k('e')) - pg_temp.r('notices_before')::int,
  1, 'one marker_paused email is queued for the exam');
select is((select array_agg((r ->> 'profile_id')::uuid order by r ->> 'profile_id')
           from public.script_notices n, jsonb_array_elements(public.script_notice_recipients(n)) r
           where n.kind = 'marker_paused' and n.exam_id = pg_temp.k('e')),
  (select array_agg(p.id order by p.id::text) from public.profiles p
   where p.status = 'active' and (p.role in ('owner', 'admin') or p.id = pg_temp.uid('lead'))),
  'it goes to the subject''s lead marker and the active owner and admin accounts (the fixtures'' extra admin among them)');
insert into res select 'content_paused', public.script_notice_content(n) from public.script_notices n where n.kind = 'marker_paused' and n.exam_id = pg_temp.k('e');
select is(array[pg_temp.r('content_paused') ->> 'exam', pg_temp.r('content_paused') ->> 'script_number'],
  array['ZZ Marking exam Paper 1', null], 'the email is about the exam, and no script');
select is(pg_temp.found(array['Wilhelmina', 'Quarterfield', 'Peregrine', 'Sixsmith', 'Ermengarde'], pg_temp.r('content_paused')::text), '{}'::text[],
  'and names neither a candidate nor a marker');
select is((select count(*)::int from jsonb_array_elements(public.script_notice_next(100, now())) x where x ->> 'kind' = 'marker_paused'), 1,
  'it is handed out to be sent as a staff alert is');

-- paused_marker_cannot_take_open_save_or_submit (z2 is an open piece)
select pg_temp.script('z2', 'e');
insert into res values ('p_next', pg_temp.next('m2', 'e'));
insert into res values ('p_open', pg_temp.as('m2', format('select public.marking_unit_open(%L)', pg_temp.u('h1'))));
insert into res values ('p_save', pg_temp.as('m2', format($q$ select public.marking_save(%L, 0, %L::jsonb) $q$, pg_temp.r('h1_open') #>> '{marking,id}',
  pg_temp.ops(pg_temp.u('h1'), array[1]))));
insert into res values ('p_submit', pg_temp.as('m2', format('select public.marking_submit(%L, 0)', pg_temp.r('h1_open') #>> '{marking,id}')));
insert into res values ('p_change', pg_temp.as('m2', format($q$ select public.marking_save(%L, %s, %L::jsonb, 0, 'Another look.') $q$,
  pg_temp.k('f:l1'), (select rev from public.markings where id = pg_temp.k('f:l1')), pg_temp.ops(pg_temp.u('l1'), array[2]))));
insert into res values ('p_work', pg_temp.as('m2', 'select public.marking_my_work()'));
select is(array[pg_temp.code(pg_temp.r('p_next')), pg_temp.code(pg_temp.r('p_open')), pg_temp.code(pg_temp.r('p_save')), pg_temp.code(pg_temp.r('p_submit')),
    pg_temp.code(pg_temp.r('p_change'))],
  array['paused', 'paused', 'paused', 'paused', 'paused'],
  'paused_marker_cannot_take_open_save_or_submit: Next script, opening, saving and submitting the piece they hold, and changing a submitted one');
select is(array[pg_temp.blocked('z2', 'm2'), pg_temp.allowed('e', 'm2', 'seed'),
    pg_temp.code(pg_temp.as('admin', format($q$ select public.marking_assign(array[%L]::uuid[], %L, 'Help with the backlog.') $q$, pg_temp.u('z2'), pg_temp.uid('m2')))),
    (pg_temp.exam(pg_temp.r('p_work'), 'e') ->> 'paused')],
  array['paused', '', 'paused', 'true'], 'nothing may be handed to them, not even by an admin; their list says paused');
select is(array[pg_temp.cs('l1'), pg_temp.st('l1'), pg_temp.ended('h1', 'm2')], array['checked', 'checked', 'live open'],
  'until the minute job runs, their pieces are as they were');

-- pause_is_per_exam
select pg_temp.script(x, 'f') from unnest(array['f1', 'f2']) x;
insert into res values ('f_next', pg_temp.next('m2', 'f'));
select is(array[pg_temp.code(pg_temp.r('f_next')), public.marking_marker_paused(pg_temp.k('f'), pg_temp.uid('m2'))::text], array['ok', 'false'],
  'pause_is_per_exam: m2 still marks their other exam');

-- pause_apply_ends_holds_and_sends_submitted_pieces_to_the_lead; tick_applies_a_pause_once
select lives_ok($$ select public.marking_tick() $$, 'the minute job runs');
insert into res values ('applied_at', to_jsonb((pg_temp.xm('e', 'm2')).pause_applied_at));
select is(array[pg_temp.ended('h1', 'm2'), pg_temp.ms('h1', 'm2'), pg_temp.us('h1')], array['live paused', 'live set_aside paused', 'open'],
  'pause_apply_ends_holds_and_sends_submitted_pieces_to_the_lead: their hold ends and their marking is set aside; the piece is free');
select is(array[pg_temp.cs('l1'), pg_temp.reviews('l1'), pg_temp.st('l1'), pg_temp.fm('l1')], array['to_lead', 'paused_marker open', 'marked', ''],
  'their checked piece goes to the lead; its script is marked again and has no final marks');
select is(array[pg_temp.ms('q1', 'm2'), pg_temp.cs('q1'), pg_temp.ms('q1', 'm5'), pg_temp.st('q1')],
  array['second set_aside paused', 'waiting_second', 'live submitted', 'marked'],
  'their second marking is set aside; the piece waits for another second marker');
select is(array[(pg_temp.r('applied_at') <> 'null'::jsonb)::text, pg_temp.ended(pg_temp.nm((pg_temp.r('f_next') ->> 'unit_id')::uuid), 'm2')],
  array['true', 'live open'], 'the pause is applied once, on that exam only');
select lives_ok($$ select public.marking_tick() $$, 'the minute job runs again');
select is(array[to_jsonb((pg_temp.xm('e', 'm2')).pause_applied_at) = pg_temp.r('applied_at'), pg_temp.reviews('l1') = 'paused_marker open',
    (select count(*) = 1 from public.marking_reviews where unit_id = pg_temp.u('l1'))],
  array[true, true, true], 'tick_applies_a_pause_once: a second run changes nothing');

-- clear_lets_the_marker_work_and_leaves_held_pieces_with_the_lead
insert into res values ('clear_m2b', pg_temp.as('lead', format($q$ select public.marking_marker_clear(%L, %L, 'Talked it through.') $q$, pg_temp.k('e'), pg_temp.uid('m2'))));
select pg_temp.until0('e', 'm2', 5);
insert into res values ('m2_next', pg_temp.next('m2', 'e'));
select is(array[pg_temp.code(pg_temp.r('clear_m2b')), ((pg_temp.xm('e', 'm2')).paused_at is null)::text, ((pg_temp.xm('e', 'm2')).pause_applied_at is null)::text,
    (pg_temp.xm('e', 'm2')).misses::text, pg_temp.code(pg_temp.r('m2_next'))],
  array['ok', 'true', 'true', '0', 'ok'], 'clear_lets_the_marker_work_and_leaves_held_pieces_with_the_lead: m2 works again');
select is(array[pg_temp.cs('l1'), pg_temp.reviews('l1')], array['to_lead', 'paused_marker open'], 'and l1 stays with the lead');

-- ---------------------------------------------------------------------------------------------
-- clear_needs_lead_or_admin_and_a_reason_and_never_oneself; the lead's and admins' view of the markers; a pause by hand.
-- ---------------------------------------------------------------------------------------------
select is(array[
    pg_temp.code(pg_temp.as('m1', format($q$ select public.marking_marker_clear(%L, %L, 'Seems fine to me.') $q$, pg_temp.k('e'), pg_temp.uid('m3')))),
    pg_temp.code(pg_temp.as('olead', format($q$ select public.marking_marker_clear(%L, %L, 'Seems fine to me.') $q$, pg_temp.k('e'), pg_temp.uid('m3')))),
    pg_temp.code(pg_temp.as('corr', format($q$ select public.marking_marker_clear(%L, %L, 'Seems fine to me.') $q$, pg_temp.k('e'), pg_temp.uid('m3')))),
    pg_temp.code(pg_temp.as('lead', format($q$ select public.marking_marker_clear(%L, %L, 'ok') $q$, pg_temp.k('e'), pg_temp.uid('m3')))),
    pg_temp.code(pg_temp.as('lead', format($q$ select public.marking_marker_clear(%L, %L, 'Seems fine to me.') $q$, pg_temp.k('e'), pg_temp.uid('lead')))),
    pg_temp.code(pg_temp.as('lead', format($q$ select public.marking_marker_pause(%L, %L, 'Take a break.') $q$, pg_temp.k('e'), pg_temp.uid('lead')))),
    pg_temp.code(pg_temp.as('m1', format($q$ select public.marking_marker_pause(%L, %L, 'Take a break.') $q$, pg_temp.k('e'), pg_temp.uid('m3'))))],
  array['forbidden', 'forbidden', 'forbidden', 'reason_required', 'forbidden', 'forbidden', 'forbidden'],
  'clear_needs_lead_or_admin_and_a_reason_and_never_oneself: a marker, another subject''s lead and a corrector are forbidden; a reason is needed; the lead never clears or pauses themselves');
insert into res values ('xm_lead', pg_temp.as('lead', format('select public.marking_exam_markers(%L)', pg_temp.k('e'))));
select is(array[pg_temp.code(pg_temp.r('xm_lead')), pg_temp.r('xm_lead') ->> 'practice_on', pg_temp.r('xm_lead') ->> 'seeds_on',
    pg_temp.code(pg_temp.as('admin', format('select public.marking_exam_markers(%L)', pg_temp.k('e')))),
    pg_temp.code(pg_temp.as('m1', format('select public.marking_exam_markers(%L)', pg_temp.k('e')))),
    pg_temp.code(pg_temp.as('olead', format('select public.marking_exam_markers(%L)', pg_temp.k('e'))))],
  array['ok', 'true', 'true', 'ok', 'forbidden', 'forbidden'], 'the markers of an exam are for the subject''s lead and admins');
select is((select concat_ws(' ', x ->> 'name', x ->> 'lead', x ->> 'cleared', x ->> 'paused', x ->> 'misses', jsonb_array_length(x -> 'practice'), x ->> 'practice_left', x -> 'seeds')
           from jsonb_array_elements(pg_temp.r('xm_lead') -> 'markers') x where x ->> 'marker_id' = pg_temp.uid('m3')::text),
  'Peregrine Sixsmith false false false 0 2 0 {"done": 0, "outside": 0}', 'm3: not cleared, both practice scripts done');
select is((select string_agg(concat_ws(' ', pg_temp.n(y, 'total'), pg_temp.n(y, 'lead_total'), pg_temp.n(y, 'max_total'), y ->> 'within'), ',' order by (y ->> 'lead_total')::numeric)
           from jsonb_array_elements(pg_temp.r('xm_lead') -> 'markers') x, jsonb_array_elements(x -> 'practice') y
           where x ->> 'marker_id' = pg_temp.uid('m3')::text),
  '5 3 10 false,5 6 10 true', 'each practice total is shown beside the lead''s, and whether it was within tolerance');
select is((select concat_ws(' ', x ->> 'cleared', ((x ->> 'cleared_at') is not null)::text, x ->> 'misses', x -> 'seeds')
           from jsonb_array_elements(pg_temp.r('xm_lead') -> 'markers') x where x ->> 'marker_id' = pg_temp.uid('m1')::text),
  'true true 1 {"done": 5, "outside": 3}', 'm1: cleared, one miss in a row, five seeds of which three were outside');
select is((select concat_ws(' ', x ->> 'lead', x ->> 'cleared') from jsonb_array_elements(pg_temp.r('xm_lead') -> 'markers') x
           where x ->> 'marker_id' = pg_temp.uid('lead')::text), 'true true', 'the lead is listed, cleared');
select is((select (x ->> 'to_review')::int from jsonb_array_elements(pg_temp.r('xm_lead') -> 'markers') x where x ->> 'marker_id' = pg_temp.uid('m2')::text),
  1, 'm2 has one script waiting for the lead''s review');
select is(pg_temp.found(array['Wilhelmina', 'Quarterfield'], pg_temp.r('xm_lead')::text), '{}'::text[], 'no candidate is named');
insert into res values ('clear_m3', pg_temp.as('admin', format($q$ select public.marking_marker_clear(%L, %L, 'Practice looked fine.') $q$, pg_temp.k('e'), pg_temp.uid('m3'))));
select pg_temp.until0('e', 'm3', 5);
insert into res values ('m3_next', pg_temp.next('m3', 'e'));
select is(array[pg_temp.code(pg_temp.r('clear_m3')), public.marking_marker_cleared(pg_temp.k('e'), pg_temp.uid('m3'))::text,
    ((pg_temp.xm('e', 'm3')).cleared_by = pg_temp.uid('admin'))::text, pg_temp.code(pg_temp.r('m3_next')),
    pg_temp.is_std((pg_temp.r('m3_next') ->> 'unit_id')::uuid, 'practice')::text],
  array['ok', 'true', 'true', 'ok', 'false'], 'an admin clears m3 with a reason; Next script now gives them a live piece');
select is((select count(*)::int from public.audit_log a where a.action = 'marker_cleared' and a.target_id = pg_temp.uid('m3') and a.actor_id = pg_temp.uid('admin')
           and a.reason like 'Practice looked fine.%'), 1, 'audited marker_cleared, with the reason');
insert into res values ('pause_m5', pg_temp.as('lead', format($q$ select public.marking_marker_pause(%L, %L, 'Marks look generous.') $q$, pg_temp.k('e'), pg_temp.uid('m5'))));
select is(array[pg_temp.code(pg_temp.r('pause_m5')), ((pg_temp.xm('e', 'm5')).pause_applied_at is not null)::text, pg_temp.cs('q1'),
    pg_temp.reviews('q1'), pg_temp.audits('marker_paused', pg_temp.uid('m5'))::text,
    (select count(*)::text from public.script_notices where kind = 'marker_paused' and exam_id = pg_temp.k('e'))],
  array['ok', 'true', 'to_lead', 'paused_marker open', '1', '1'],
  'a pause by hand is applied at once (q1, first-marked by m5, goes to the lead); audited; no email');

-- ---------------------------------------------------------------------------------------------
-- feedback_only_for_its_marker_and_has_no_name
-- ---------------------------------------------------------------------------------------------
select is(array[
    pg_temp.code(pg_temp.as('m1', format('select public.marking_feedback(%L)', pg_temp.k('pm1')))),
    pg_temp.code(pg_temp.as('lead', format('select public.marking_feedback(%L)', pg_temp.k('pm1')))),
    pg_temp.code(pg_temp.as('admin', format('select public.marking_feedback(%L)', pg_temp.k('pm1')))),
    pg_temp.code(pg_temp.as('m1', format('select public.marking_feedback(%L)', pg_temp.k('ml1')))),
    pg_temp.code(pg_temp.as('m3', format('select public.marking_feedback(%L)', gen_random_uuid())))],
  array['forbidden', 'forbidden', 'forbidden', 'forbidden', 'forbidden'],
  'feedback_only_for_its_marker_and_has_no_name: another marker, the lead, an admin, a live marking or an unknown one: forbidden');
select is(pg_temp.found(array['Wilhelmina', 'Quarterfield', 'Peregrine', 'Sixsmith', 'Ermengarde', 'Leadbetter'], pg_temp.r('fb_p')::text || pg_temp.r('fb_o')::text),
  '{}'::text[], 'and the feedback names nobody');
select is(array(select k from jsonb_object_keys(pg_temp.r('fb_p')) k order by 1),
  array['lead_total', 'max_total', 'note', 'ok', 'questions', 'total', 'use'], 'it holds the marks, the totals and the lead''s note only');

-- ---------------------------------------------------------------------------------------------
-- retire_keeps_submitted_attempts (m6, not cleared on e, holds p1; m3 submitted on it; m1 missed seedO)
-- ---------------------------------------------------------------------------------------------
select pg_temp.take('p1', 'm6', 'practice');
insert into res values ('m6_p1', pg_temp.as('m6', format('select public.marking_unit_open(%L)', pg_temp.u('p1'))));
select is(array[pg_temp.code(pg_temp.as('lead', format($q$ select public.marking_standard_retire(%L, 'ok') $q$, (pg_temp.std('p1')).id))),
    pg_temp.code(pg_temp.as('m1', format($q$ select public.marking_standard_retire(%L, 'Not needed.') $q$, (pg_temp.std('p1')).id))),
    pg_temp.code(pg_temp.as('olead', format($q$ select public.marking_standard_retire(%L, 'Not needed.') $q$, (pg_temp.std('p1')).id)))],
  array['reason_required', 'forbidden', 'forbidden'], 'retiring needs the lead or an admin, and a reason');
insert into res values ('ret_p1', pg_temp.as('lead', format($q$ select public.marking_standard_retire(%L, 'Too easy a script.') $q$, (pg_temp.std('p1')).id)));
select is(array[pg_temp.code(pg_temp.r('ret_p1')), ((pg_temp.std('p1')).retired_at is not null)::text, ((pg_temp.std('p1')).retired_by = pg_temp.uid('lead'))::text,
    pg_temp.ended('p1', 'm6'), pg_temp.ms('p1', 'm6'), pg_temp.ms('p1', 'm3')],
  array['ok', 'true', 'true', 'practice switched_off', 'practice set_aside switched_off', 'practice submitted'],
  'retire_keeps_submitted_attempts: an open attempt ends, one in progress is set aside, a submitted one stands');
select is(array[pg_temp.code(pg_temp.as('lead', format($q$ select public.marking_standard_retire(%L, 'Too easy a script.') $q$, (pg_temp.std('p1')).id))) ,
    pg_temp.audits('marking_standard_retired', (pg_temp.std('p1')).id)::text, pg_temp.allowed('e', 'm6', 'practice')],
  array['conflict', '1', 'p2'], 'retiring twice is a conflict; it is audited; the retired piece is not offered again');
insert into res values ('ret_seedO', pg_temp.as('admin', format($q$ select public.marking_standard_retire(%L, 'Replaced by another.') $q$, (pg_temp.std(pg_temp.nm(pg_temp.a('seedO')))).id)));
select is(array[pg_temp.code(pg_temp.r('ret_seedO')), (pg_temp.xm('e', 'm1')).misses::text,
    (select status from public.markings where id = pg_temp.k('smo'))], array['ok', '1', 'submitted'],
  'an admin retires a seed: the attempt outside tolerance and the miss it counted stand');
insert into res values ('list_after', pg_temp.as('lead', format('select public.marking_standards_list(%L)', pg_temp.k('e'))));
select is((select concat_ws(' ', x ->> 'retired', x -> 'attempts') from jsonb_array_elements(pg_temp.r('list_after') -> 'standards') x
           where x ->> 'unit_id' = pg_temp.u('p1')::text),
  'true {"done": 1, "outside": 1}',
  'the list shows it retired, with its attempts');

-- ---------------------------------------------------------------------------------------------
-- live_marking_taken_back_retires_its_standard (m6 takes p2 by Next script)
-- ---------------------------------------------------------------------------------------------
insert into res values ('m6_next', pg_temp.next('m6', 'e'));
insert into res values ('m6_p2', pg_temp.as('m6', format('select public.marking_unit_open(%L)', pg_temp.u('p2'))));
insert into res values ('tb_p2', pg_temp.as('admin', format($q$ select public.marking_take_back(array[%L]::uuid[], 'The lead marked the wrong pages.', 'live') $q$, pg_temp.u('p2'))));
select is(array[pg_temp.nm((pg_temp.r('m6_next') ->> 'unit_id')::uuid), pg_temp.code(pg_temp.r('tb_p2')), ((pg_temp.std('p2')).retired_at is not null)::text,
    pg_temp.ended('p2', 'm6'), pg_temp.ms('p2', 'm6'), pg_temp.ms('p2', 'm3'), pg_temp.audits('marking_standard_retired', (pg_temp.std('p2')).id)::text],
  array['p2', 'ok', 'true', 'practice switched_off', 'practice set_aside switched_off', 'practice submitted', '1'],
  'live_marking_taken_back_retires_its_standard: the lead''s live marking taken back retires the practice script the same way');
insert into res values ('m6_after', pg_temp.next('m6', 'e'));
select is(pg_temp.code(pg_temp.r('m6_after')), 'practice_not_ready', 'with no practice script left and none done, m6 waits for practice scripts');

-- ---------------------------------------------------------------------------------------------
-- practice_and_seeds_off_change_nothing (exam f: the checks off)
-- ---------------------------------------------------------------------------------------------
select pg_temp.until0('f', 'm6');
insert into res values ('f_m6', pg_temp.next('m6', 'f'));
insert into res values ('f_work', pg_temp.as('m6', 'select public.marking_my_work()'));
select is(array[public.marking_marker_cleared(pg_temp.k('f'), pg_temp.uid('m6'))::text, pg_temp.code(pg_temp.r('f_m6')),
    (pg_temp.nm((pg_temp.r('f_m6') ->> 'unit_id')::uuid) like 'f_')::text, pg_temp.r('f_m6') ->> 'resumed', (pg_temp.exam(pg_temp.r('f_work'), 'f') -> 'practice')::text,
    pg_temp.exam(pg_temp.r('f_work'), 'f') ->> 'paused'],
  array['true', 'ok', 'true', 'false', 'null', 'false'],
  'practice_and_seeds_off_change_nothing: with the checks off every marker is cleared and Next script gives a live piece as before');
select is((select count(*)::int from public.marking_assignments a join public.marking_units u on u.id = a.unit_id
           where u.exam_id = pg_temp.k('f') and a.kind <> 'live'), 0, 'and nothing but live passes is handed out');

-- ---------------------------------------------------------------------------------------------
-- Privileges.
-- ---------------------------------------------------------------------------------------------
select is((select array_agg(f order by f) from unnest(array[
    'public.marking_marker_cleared(uuid,uuid)', 'public.marking_marker_paused(uuid,uuid)', 'public.marking_pause_apply(uuid,uuid)',
    'public.marking_standard_end(uuid,uuid,text)', 'public.marking_standards_follow()', 'public.marking_standard_compare(uuid)']) f
  where has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute')
     or has_function_privilege('service_role', f, 'execute')),
  null, 'the internal functions are revoked from every client role');
select is((select array_agg(f order by f) from unnest(array[
    'public.marking_standard_set(uuid,text,text)', 'public.marking_standard_retire(uuid,text)', 'public.marking_standards_list(uuid)',
    'public.marking_marker_clear(uuid,uuid,text)', 'public.marking_marker_pause(uuid,uuid,text)', 'public.marking_exam_markers(uuid)',
    'public.marking_feedback(uuid)']) f
  where not has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute')),
  null, 'the others are for signed-in users only');
select is((select count(*)::int from pg_trigger where tgname = 'marking_standards_follow' and tgrelid = 'public.markings'::regclass), 1,
  'the trigger marking_standards_follow is on markings');

select * from finish();
rollback;
