begin;
create extension if not exists pgtap with schema extensions;
select plan(69);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Subject 'ZZ Rev': markers m1 to m7 and the lead marker (tests.marker); corr is a corrector never approved;
-- olead leads another subject. Every exam has the test structure (1 of 3 marks, 2(a) of 2, 2(b) of 5: out of 10, every
-- tolerance the floor of one mark).
--   e: double marking on (10%, 10% tolerance), seeds and practice off. Second-marked (stored draw 0.01): d1 to d6 (first
--      1,1,1 by m1, second 3,2,5 by m2: each a difference; d5 is the lead's first marking and m1's second), p1 (m3), k1
--      (m1; m2's second marking 1,1,1 is within tolerance), wt1 and wt2 (m1; waiting). Not second-marked (draw 0.99): p2
--      (m3), s1 (m1), s2 (m4), s3 (m5), s4 (m6). The lead then pauses m3: p1 and p2 go to the lead.
--   f: the checks off. m1 marks f1 to f5 (1,1,1), m2 marks f6 and f7 (2,2,2); f5 has a settled difference.
--   g: practice on; the lead's gp1 is its practice script.
--   w (subject 'ZZ Rev Two': t1, t2 and their lead tl): every piece second-marked; t1 marks w1.
--   s and p (subject 'ZZ Rev Small': x1 and their lead sl): s with seeded scripts on (q1, q2; r1 and r2 to mark), p with
--      practice on (pr1; l1 and l2 to mark).
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
create function pg_temp.a(p text) returns uuid language sql stable as $$ select id from kv where name = 'a:' || p $$;
create function pg_temp.r(p text) returns jsonb language sql stable as $$ select j from res where name = p $$;
-- A number of an answer, without trailing zeros ('5', '2.5').
create function pg_temp.n(j jsonb, p text) returns text language sql immutable as $$ select trim_scale((j ->> p)::numeric)::text $$;
create function pg_temp.subj(p text) returns bigint language sql stable as $$ select id from public.subjects where name = p $$;
create function pg_temp.code(j jsonb) returns text language sql immutable as $$
  select case when (j ->> 'ok')::boolean then 'ok' else coalesce(j ->> 'code', 'none') end $$;
-- A piece's name ('d1', 'f2', ...; '-' for none).
create function pg_temp.nm(p uuid) returns text language sql stable as $$
  select coalesce((select substr(name, 3) from kv where id = p and name like 'u:%' limit 1), '-') $$;
-- A piece's check state ('-' for none), its own state, its script's state, whether a second marking is wanted.
create function pg_temp.cs(p text) returns text language sql stable security definer as $$
  select coalesce(check_state, '-') from public.marking_units where id = pg_temp.u(p) $$;
create function pg_temp.us(p text) returns text language sql stable security definer as $$
  select state from public.marking_units where id = pg_temp.u(p) $$;
create function pg_temp.st(p text) returns text language sql stable security definer as $$
  select s.state::text from public.scripts s join public.marking_units u on u.script_id = s.id where u.id = pg_temp.u(p) $$;
create function pg_temp.wanted(p text) returns text language sql stable security definer as $$
  select coalesce(second_wanted::text, '-') from public.marking_units where id = pg_temp.u(p) $$;
create function pg_temp.final_from(p text) returns uuid language sql stable security definer as $$
  select final_marking_id from public.marking_units where id = pg_temp.u(p) $$;
-- A piece's final marks in paper order ('' for none), and the history of one of its questions, oldest first.
create function pg_temp.fm(p text) returns text language sql stable security definer as $$
  select coalesce(string_agg(q.label || '=' || coalesce(trim_scale(f.mark)::text, 'NR') || ' ' || f.source, ',' order by q.path), '')
  from public.final_marks f join public.marking_unit_questions(pg_temp.u(p)) q on q.question_id = f.question_id
  where f.unit_id = pg_temp.u(p) $$;
create function pg_temp.hist(p text, p_label text) returns text language sql stable security definer as $$
  select coalesce(string_agg(case when h.removed then 'removed' else coalesce(trim_scale(h.mark)::text, 'NR') || ' ' || h.source end, ',' order by h.id), '')
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
-- A marker's markings on a piece ('kind status reason'), how their holds ended ('kind how end', 'open' for one that has
-- not, those that ended first), and their exclusion from it.
create function pg_temp.ms(p text, p_marker text) returns text language sql stable security definer as $$
  select coalesce(string_agg(m.kind || ' ' || m.status || coalesce(' ' || m.set_aside_reason, ''), ',' order by m.kind), '-') from public.markings m
  where m.unit_id = pg_temp.u(p) and m.marker_id = pg_temp.uid(p_marker) $$;
create function pg_temp.ended(p text, p_marker text) returns text language sql stable security definer as $$
  select coalesce(string_agg(a.kind || ' ' || a.how || ' ' || coalesce(a.end_reason, 'open'), ',' order by a.ended_at is null, a.created_at, a.id), '-')
  from public.marking_assignments a where a.unit_id = pg_temp.u(p) and a.marker_id = pg_temp.uid(p_marker) $$;
create function pg_temp.excl(p text, p_marker text) returns text language sql stable security definer as $$
  select coalesce((select x.reason from public.marking_unit_exclusions x where x.unit_id = pg_temp.u(p) and x.marker_id = pg_temp.uid(p_marker)), '-') $$;
-- A piece's reviews: 'kind state outcome' in the order they were opened; the latest of a kind (an open one first).
create function pg_temp.reviews(p text) returns text language sql stable security definer as $$
  select coalesce(string_agg(r.kind || ' ' || r.state || coalesce(' ' || r.outcome, ''), ',' order by r.opened_at, r.id), '-')
  from public.marking_reviews r where r.unit_id = pg_temp.u(p) $$;
create function pg_temp.rv(p text, p_kind text) returns uuid language sql stable security definer as $$
  select r.id from public.marking_reviews r where r.unit_id = pg_temp.u(p) and r.kind = p_kind
  order by r.state = 'open' desc, r.opened_at desc, r.id limit 1 $$;
create function pg_temp.audits(p_action text, p_target uuid) returns int language sql stable security definer as $$
  select count(*)::int from public.audit_log a where a.action = p_action and a.target_id = p_target $$;
create function pg_temp.student(p text) returns uuid language sql stable security definer as $$
  select b.student_id from public.marking_units u join public.scripts s on s.id = u.script_id join public.bookings b on b.id = s.booking_id
  where u.id = pg_temp.u(p) $$;
-- The pages of a piece's script, in copy-page order.
create function pg_temp.pages(p text) returns uuid[] language sql stable security definer as $$
  select coalesce(array_agg(l.page_id order by l.copy_page), '{}')
  from public.marking_units u join public.scripts s on s.id = u.script_id
  join public.script_page_links l on l.script_id = s.id and l.version = s.version where u.id = pg_temp.u(p) $$;
-- A question of a piece, by its label; an entry of a set of marks ({question_id, mark, na}); a save's mark operation.
create function pg_temp.q(p text, p_label text) returns uuid language sql stable security definer as $$
  select q.question_id from public.marking_unit_questions(pg_temp.u(p)) q where q.label = p_label $$;
create function pg_temp.mk(p text, p_label text, p_mark numeric, p_na boolean default false) returns jsonb language sql stable as $$
  select jsonb_build_object('question_id', pg_temp.q(p, p_label), 'mark', p_mark, 'na', p_na) $$;
create function pg_temp.op(p text, p_label text, p_mark numeric) returns jsonb language sql stable as $$
  select jsonb_build_object('op', 'mark', 'question_id', pg_temp.q(p, p_label), 'mark', p_mark, 'na', false) $$;
create function pg_temp.ops(p_unit uuid, p_marks numeric[]) returns jsonb language sql stable security definer as $$
  select jsonb_agg(jsonb_build_object('op', 'mark', 'question_id', q.question_id, 'mark', coalesce(p_marks[q.n], 0), 'na', false) order by q.n)
  from (select t.question_id, row_number() over (order by t.path) as n from public.marking_unit_questions(p_unit) t where t.leaf) q $$;
-- The pieces the one rule allows a marker on an exam (Next script), and why one may not be handed to them.
create function pg_temp.allowed(p_exam text, p_marker text, p_kind text) returns text language sql stable as $$
  select coalesce(string_agg(pg_temp.nm(a.unit_id), ',' order by pg_temp.nm(a.unit_id)), '')
  from public.marking_units_allowed(pg_temp.k(p_exam), pg_temp.uid(p_marker), p_kind::public.marking_kind, true) a $$;
create function pg_temp.blocked(p text, p_marker text, p_kind text default 'live') returns text language sql stable as $$
  select coalesce(public.marking_unit_blocked(pg_temp.u(p), pg_temp.uid(p_marker), null, true, p_kind::public.marking_kind), 'null') $$;
create function pg_temp.std(p text) returns public.marking_standards language sql stable security definer as $$
  select * from public.marking_standards where unit_id = pg_temp.u(p) $$;
create function pg_temp.until0(p_exam text, p_marker text) returns void language sql security definer as $$
  insert into public.exam_markers (exam_id, marker_id, until_seed) values (pg_temp.k(p_exam), pg_temp.uid(p_marker), 0)
  on conflict (exam_id, marker_id) do update set until_seed = excluded.until_seed $$;
-- The top-level keys of an answer, sorted; the words of p_words that a text holds.
create function pg_temp.keys(j jsonb) returns text[] language sql immutable as $$ select array(select k from jsonb_object_keys(j) k order by 1) $$;
create function pg_temp.found(p_words text[], p_text text) returns text[] language sql immutable as $$
  select array(select w from unnest(p_words) w where position(lower(w) in lower(p_text)) > 0) $$;
-- A review list's items: the pieces in its order, the same sorted, and the item of a piece.
create function pg_temp.items(j jsonb) returns text language sql stable as $$
  select coalesce(string_agg(pg_temp.nm((x ->> 'unit_id')::uuid), ',' order by o), '') from jsonb_array_elements(j -> 'items') with ordinality t(x, o) $$;
create function pg_temp.itemset(j jsonb) returns text language sql stable as $$
  select coalesce(string_agg(pg_temp.nm((x ->> 'unit_id')::uuid), ',' order by pg_temp.nm((x ->> 'unit_id')::uuid)), '') from jsonb_array_elements(j -> 'items') x $$;
create function pg_temp.item(j jsonb, p text) returns jsonb language sql stable as $$
  select x from jsonb_array_elements(j -> 'items') x where (x ->> 'unit_id')::uuid = pg_temp.u(p) limit 1 $$;
-- A piece and an exam of a work list (marking_my_work).
create function pg_temp.piece(j jsonb, p uuid) returns jsonb language sql immutable as $$
  select x from jsonb_array_elements(j -> 'pieces') x where x ->> 'unit_id' = p::text $$;
create function pg_temp.exam(j jsonb, p text) returns jsonb language sql stable as $$
  select x from jsonb_array_elements(j -> 'exams') x where x ->> 'exam_id' = pg_temp.k(p)::text $$;
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
-- Signed in as the marker, who holds the piece: open it, save p_marks and submit. The marking is kept as kv p_key.
-- Returns the submit's answer.
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
-- A second marking of a piece (as 057): its second pass taken as Next script would, then marked and submitted.
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
-- Signed in as the marker: Next script on an exam.
create function pg_temp.next(p_marker text, p_exam text) returns jsonb language sql as $$
  select pg_temp.as(p_marker, format('select public.marking_next(%L)', pg_temp.k(p_exam))) $$;
-- A marker's save of a submitted marking (with a reason), at its current rev.
create function pg_temp.change(p_marking text, p_marker text, p_ops jsonb, p_reason text) returns jsonb language plpgsql as $$
begin
  return pg_temp.as(p_marker, format('select public.marking_save(%L, %s, %L::jsonb, 0, %L)', pg_temp.k(p_marking), pg_temp.rev(p_marking), p_ops, p_reason));
end $$;
-- The review actions, signed in as someone: settle a piece's difference (at the markings' current revs unless given),
-- send a piece back, change its final marks.
create function pg_temp.settle(p_who text, p text, p_outcome text, p_reason text, p_marks jsonb default null,
  p_first_rev int default null, p_second_rev int default null) returns jsonb language plpgsql as $$
begin
  return pg_temp.as(p_who, format('select public.marking_review_settle(%L, %L, %s, %s, %L, %L::jsonb)',
    pg_temp.rv(p, 'difference'), p_outcome, coalesce(p_first_rev, pg_temp.rev('f:' || p)), coalesce(p_second_rev, pg_temp.rev('s:' || p)),
    p_reason, p_marks));
end $$;
create function pg_temp.sb(p_who text, p text, p_to text, p_note text, p_reason text) returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.marking_send_back(%L, %L, %L, %L)', pg_temp.u(p), p_to, p_note, p_reason)) $$;
create function pg_temp.fs(p_who text, p text, p_marks jsonb, p_reason text) returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.marking_final_set(%L, %L::jsonb, %L)', pg_temp.u(p), p_marks, p_reason)) $$;
create function pg_temp.open(p_who text, p uuid) returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.marking_review_open(%L)', p)) $$;
create function pg_temp.accept(p_who text, p uuid, p_reason text default null) returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.marking_review_accept(%L, %L)', p, p_reason)) $$;
create function pg_temp.list(p_who text, p_exam uuid, p_kind text default null) returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.marking_review_list(%L, %L)', p_exam, p_kind)) $$;
create function pg_temp.sample(p_who text, p_exam text, p_marker text, p_count int default 5) returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.marking_review_sample(%L, %L, %s)', pg_temp.k(p_exam), pg_temp.uid(p_marker), p_count)) $$;
create function pg_temp.pics(p_who text, p text) returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.marking_picture_paths(%L, %L::uuid[])', pg_temp.u(p), pg_temp.pages(p))) $$;

insert into public.subjects (name, kind) values ('ZZ Rev', 'school'), ('ZZ Rev Other', 'school'), ('ZZ Rev Two', 'school'),
  ('ZZ Rev Small', 'school');
insert into c values ('admin', tests.create_user('admin', 'active')), ('corr', tests.create_user('corrector', 'active'));
insert into c select 'm' || i, tests.marker(pg_temp.subj('ZZ Rev')) from generate_series(1, 7) i;
insert into c values ('lead', tests.marker(pg_temp.subj('ZZ Rev'), true)), ('olead', tests.marker(pg_temp.subj('ZZ Rev Other'), true)),
  ('t1', tests.marker(pg_temp.subj('ZZ Rev Two'))), ('t2', tests.marker(pg_temp.subj('ZZ Rev Two'))),
  ('tl', tests.marker(pg_temp.subj('ZZ Rev Two'), true)),
  ('x1', tests.marker(pg_temp.subj('ZZ Rev Small'))), ('sl', tests.marker(pg_temp.subj('ZZ Rev Small'), true));
update public.profiles set first_name = 'Aurelius', last_name = 'Firstley' where id = pg_temp.uid('m1');
update public.profiles set first_name = 'Bartholomew', last_name = 'Secondo' where id = pg_temp.uid('m2');
update public.profiles set first_name = 'Ermengarde', last_name = 'Leadbetter' where id = pg_temp.uid('lead');

insert into kv values ('e', tests.marking_exam(pg_temp.subj('ZZ Rev'))), ('f', tests.marking_exam(pg_temp.subj('ZZ Rev'))),
  ('g', tests.marking_exam(pg_temp.subj('ZZ Rev'))), ('w', tests.marking_exam(pg_temp.subj('ZZ Rev Two'))),
  ('s', tests.marking_exam(pg_temp.subj('ZZ Rev Small'))), ('p', tests.marking_exam(pg_temp.subj('ZZ Rev Small')));
select tests.structure(pg_temp.k(x)) from unnest(array['e', 'f', 'g', 'w', 's', 'p']) x;
select tests.open_marking(pg_temp.k('e'),
  '{"double_marking": true, "sample_percent": 10, "tolerance_percent": 10, "seeds": false, "practice": false}');
select tests.open_marking(pg_temp.k('f'));
select tests.open_marking(pg_temp.k('g'), '{"double_marking": false, "seeds": false, "practice": true}');
select tests.open_marking(pg_temp.k('w'), '{"double_marking": true, "sample_percent": 100, "seeds": false, "practice": false}');
select tests.open_marking(pg_temp.k('s'), '{"double_marking": false, "seeds": true, "seed_every": 3, "practice": false}');
select tests.open_marking(pg_temp.k('p'), '{"double_marking": false, "seeds": false, "practice": true}');

-- Exam e.
select pg_temp.script(x, 'e', 0.01) from unnest(array['d1', 'd2', 'd3', 'd4', 'd5', 'd6', 'p1', 'k1', 'wt1', 'wt2']) x;
select pg_temp.script(x, 'e') from unnest(array['p2', 's1', 's2', 's3', 's4']) x;
select pg_temp.first(x, 'm1', array[1, 1, 1]) from unnest(array['d1', 'd2', 'd3', 'd4', 'd6', 'k1', 'wt1', 'wt2', 's1']) x;
select pg_temp.first('d5', 'lead', array[1, 1, 1]);
select pg_temp.second(x, 'm2', array[3, 2, 5]) from unnest(array['d1', 'd2', 'd3', 'd4', 'd6']) x;
select pg_temp.second('d5', 'm1', array[3, 2, 5]);
select pg_temp.second('k1', 'm2', array[1, 1, 1]);
select pg_temp.first(x, 'm3', array[1, 1, 1]) from unnest(array['p1', 'p2']) x;
select pg_temp.first('s2', 'm4', array[1, 1, 1]), pg_temp.first('s3', 'm5', array[1, 1, 1]), pg_temp.first('s4', 'm6', array[1, 1, 1]);
insert into res values ('pause_m3', pg_temp.as('lead', format($q$ select public.marking_marker_pause(%L, %L, 'Three scripts look harsh.') $q$,
  pg_temp.k('e'), pg_temp.uid('m3'))));
-- d6's difference is the oldest.
update public.marking_reviews set opened_at = now() - interval '1 hour' where unit_id = pg_temp.u('d6');

-- Exam f.
select pg_temp.script(x, 'f') from unnest(array['f1', 'f2', 'f3', 'f4', 'f5', 'f6', 'f7']) x;
select pg_temp.first(x, 'm1', array[1, 1, 1]) from unnest(array['f1', 'f2', 'f3', 'f4', 'f5']) x;
select pg_temp.first(x, 'm2', array[2, 2, 2]) from unnest(array['f6', 'f7']) x;
insert into public.marking_reviews (exam_id, unit_id, kind, marking_id, state, outcome, closed_by, closed_at)
values (pg_temp.k('f'), pg_temp.u('f5'), 'difference', pg_temp.k('f:f5'), 'closed', 'first_stands', pg_temp.uid('lead'), now());

-- Exams g, w, s and p.
select pg_temp.script(x, 'g') from unnest(array['gp1', 'gl1']) x;
select pg_temp.first('gp1', 'lead', array[1, 1, 1]);
insert into res values ('set_gp1', pg_temp.as('lead', format($q$ select public.marking_standard_set(%L, 'practice') $q$, pg_temp.u('gp1'))));
select pg_temp.script('w1', 'w');
select pg_temp.first('w1', 't1', array[1, 1, 1]);
select pg_temp.script(x, 's') from unnest(array['q1', 'q2', 'r1', 'r2']) x;
select pg_temp.first(x, 'sl', array[3, 2, 5]) from unnest(array['q1', 'q2']) x;
insert into res select 'set_' || x, pg_temp.as('sl', format($q$ select public.marking_standard_set(%L, 'seed') $q$, pg_temp.u(x)))
from unnest(array['q1', 'q2']) x;
select pg_temp.script(x, 'p') from unnest(array['pr1', 'l1', 'l2']) x;
select pg_temp.first('pr1', 'sl', array[1, 1, 1]);
insert into res values ('set_pr1', pg_temp.as('sl', format($q$ select public.marking_standard_set(%L, 'practice') $q$, pg_temp.u('pr1'))));

select is(array[pg_temp.code(pg_temp.r('pause_m3')), pg_temp.cs('d1'), pg_temp.cs('d5'), pg_temp.cs('d6'), pg_temp.cs('p1'), pg_temp.cs('p2'),
    pg_temp.cs('k1'), pg_temp.cs('wt1'), pg_temp.cs('s1'), pg_temp.cs('s4'), pg_temp.cs('f1'), pg_temp.cs('w1'),
    pg_temp.code(pg_temp.r('set_gp1')), pg_temp.code(pg_temp.r('set_q1')), pg_temp.code(pg_temp.r('set_q2')), pg_temp.code(pg_temp.r('set_pr1'))],
  array['ok', 'to_lead', 'to_lead', 'to_lead', 'to_lead', 'to_lead', 'checked', 'waiting_second', 'checked', 'checked', 'checked',
    'waiting_second', 'ok', 'ok', 'ok', 'ok'],
  'fixtures: d1 to d6 differ; m3''s p1 and p2 are with the lead; k1, s1, s4 and f1 are checked; wt1 and w1 wait; the standards are set');
select is(array[pg_temp.reviews('d1'), pg_temp.reviews('d5'), pg_temp.reviews('p1'), pg_temp.reviews('p2')],
  array['difference open', 'difference open', 'paused_marker open', 'paused_marker open'], 'fixtures: the open reviews');

-- ---------------------------------------------------------------------------------------------
-- differences_list_for_the_subject_lead_and_admins_only
-- ---------------------------------------------------------------------------------------------
insert into res values ('list_lead', pg_temp.list('lead', pg_temp.k('e')));
insert into res values ('list_lead_diff', pg_temp.list('lead', pg_temp.k('e'), 'difference'));
insert into res values ('list_admin_paused', pg_temp.list('admin', null, 'paused_marker'));
insert into res values ('list_olead', pg_temp.list('olead', null));
select is(array[pg_temp.code(pg_temp.r('list_lead')), pg_temp.code(pg_temp.list('admin', pg_temp.k('e'))),
    pg_temp.code(pg_temp.list('m1', pg_temp.k('e'))), pg_temp.code(pg_temp.list('olead', pg_temp.k('e'))),
    pg_temp.code(pg_temp.list('corr', null)), pg_temp.code(pg_temp.list('lead', pg_temp.k('e'), 'other')),
    pg_temp.code(pg_temp.list('admin', gen_random_uuid())), pg_temp.code(pg_temp.list('lead', gen_random_uuid()))],
  array['ok', 'ok', 'forbidden', 'forbidden', 'forbidden', 'invalid_input', 'not_found', 'forbidden'],
  'differences_list_for_the_subject_lead_and_admins_only: a marker, another subject''s lead and a corrector are forbidden');
select is(array[split_part(pg_temp.items(pg_temp.r('list_lead_diff')), ',', 1), pg_temp.itemset(pg_temp.r('list_admin_paused')),
    pg_temp.itemset(pg_temp.r('list_olead')), pg_temp.r('list_lead_diff') ->> 'more'],
  array['d6', 'p1,p2', '', 'false'],
  'the open reviews, oldest first (d6''s first); admins see every exam''s; another subject''s lead none of these');
select is(pg_temp.itemset(pg_temp.r('list_lead_diff')), 'd1,d2,d3,d4,d5,d6', 'marks that differ: d1 to d6');
select is(pg_temp.r('list_lead') -> 'counts', '{"difference": 6, "paused_marker": 2, "sample": 0, "to_clear": 0, "stuck_second": 0}'::jsonb,
  'the counts');
select is(array[array_to_string(pg_temp.keys(pg_temp.r('list_lead')), ','),
    array_to_string(pg_temp.keys(pg_temp.item(pg_temp.r('list_lead_diff'), 'd1')), ',')],
  array['counts,items,more,ok',
        'exam_id,exam_title,first,group_label,index_number,kind,max_total,opened_at,party,review_id,script_number,second,unit_id'],
  'the answer, and each item''s keys');
select is(array[pg_temp.item(pg_temp.r('list_lead_diff'), 'd1') #>> '{first,name}', pg_temp.n(pg_temp.item(pg_temp.r('list_lead_diff'), 'd1') -> 'first', 'total'),
    pg_temp.item(pg_temp.r('list_lead_diff'), 'd1') #>> '{second,name}', pg_temp.n(pg_temp.item(pg_temp.r('list_lead_diff'), 'd1') -> 'second', 'total'),
    pg_temp.n(pg_temp.item(pg_temp.r('list_lead_diff'), 'd1'), 'max_total'), pg_temp.item(pg_temp.r('list_lead_diff'), 'p1') ->> 'kind',
    pg_temp.item(pg_temp.r('list_admin_paused'), 'p1') ->> 'second'],
  array['Aurelius Firstley', '3', 'Bartholomew Secondo', '10', '10', null, null],
  'each item: both markers'' names and totals, the maximum; a paused marker''s piece has no second marking');
select is(pg_temp.found(array['Wilhelmina', 'Quarterfield'], pg_temp.r('list_lead')::text), '{}'::text[], 'the list names no candidate');

-- ---------------------------------------------------------------------------------------------
-- review_open_shows_both_markings_and_no_name
-- ---------------------------------------------------------------------------------------------
insert into res values ('open_d1', pg_temp.open('lead', pg_temp.rv('d1', 'difference')));
select is(array[array_to_string(pg_temp.keys(pg_temp.r('open_d1')), ','), array_to_string(pg_temp.keys(pg_temp.r('open_d1') -> 'first'), ','),
    array_to_string(pg_temp.keys(pg_temp.r('open_d1') -> 'unit'), ','), array_to_string(pg_temp.keys(pg_temp.r('open_d1') -> 'review'), ',')],
  array['compare,final,first,ok,pages,review,second,structure,unit',
        'active_seconds,annotations,lead_note,marker_name,marking_id,marks,rev,submitted_at,total',
        'exam_title,group_label,id,index_number,paper,script_number', 'id,kind,outcome,party,state'],
  'review_open_shows_both_markings_and_no_name: the answer''s parts');
select is(array[pg_temp.r('open_d1') #>> '{review,kind}', pg_temp.r('open_d1') #>> '{review,state}', pg_temp.r('open_d1') #>> '{review,party}',
    pg_temp.r('open_d1') #>> '{first,marker_name}', pg_temp.r('open_d1') #>> '{second,marker_name}',
    pg_temp.n(pg_temp.r('open_d1') -> 'first', 'total'), pg_temp.n(pg_temp.r('open_d1') -> 'second', 'total'),
    pg_temp.r('open_d1') #>> '{compare,within}', jsonb_array_length(pg_temp.r('open_d1') #> '{first,marks}')::text,
    jsonb_array_length(pg_temp.r('open_d1') -> 'pages')::text, jsonb_array_length(pg_temp.r('open_d1') -> 'final')::text,
    (pg_temp.r('open_d1') #>> '{first,marking_id}' = pg_temp.k('f:d1')::text)::text],
  array['difference', 'open', 'false', 'Aurelius Firstley', 'Bartholomew Secondo', '3', '10', 'false', '3', '3', '0', 'true'],
  'both markings side by side, with their markers'' names, totals and the comparison; no final marks yet');
select is(pg_temp.found(array['Wilhelmina', 'Quarterfield', (select p.email::text from public.profiles p where p.id = pg_temp.student('d1')),
      pg_temp.student('d1')::text, (select s.booking_id::text from public.scripts s where s.id = pg_temp.k('d1'))],
    pg_temp.r('open_d1')::text), '{}'::text[], 'it holds no first name, last name, email, booking id or student id');
select is(position((select d.index_number from public.student_details d where d.profile_id = pg_temp.student('d1')) in pg_temp.r('open_d1')::text) > 0,
  true, 'it holds the index number');

-- ---------------------------------------------------------------------------------------------
-- Refusals of a settle before anything is settled.
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.code(pg_temp.settle('lead', 'd4', 'average', 'The marks look odd.')),
    pg_temp.code(pg_temp.as('lead', format($q$ select public.marking_review_settle(%L, 'first_stands', null, 0, 'The marks look odd.') $q$,
      pg_temp.rv('d4', 'difference')))),
    pg_temp.code(pg_temp.as('lead', format($q$ select public.marking_review_settle(%L, 'first_stands', 0, 0, 'The marks look odd.') $q$,
      pg_temp.rv('p1', 'paused_marker')))),
    pg_temp.code(pg_temp.accept('lead', pg_temp.rv('d4', 'difference'))),
    pg_temp.code(pg_temp.settle('lead', 'd4', 'first_stands', null)), pg_temp.code(pg_temp.settle('lead', 'd4', 'first_stands', 'ab'))],
  array['invalid_input', 'invalid_input', 'wrong_kind', 'wrong_kind', 'reason_required', 'reason_required'],
  'settle_needs_a_reason_and_writes_audit_and_history: an unknown outcome or no rev is invalid; only a difference is settled, and only a difference is not accepted; a reason of 3 to 300 characters');

-- ---------------------------------------------------------------------------------------------
-- settle_first_stands_writes_final_marks_and_checks_the_script, markings_are_unchanged_by_a_settle
-- ---------------------------------------------------------------------------------------------
insert into res values ('before_d1', to_jsonb(array[pg_temp.marks('f:d1'), pg_temp.marks('s:d1'), pg_temp.rev('f:d1')::text, pg_temp.rev('s:d1')::text]));
insert into res values ('settle_d1', pg_temp.settle('lead', 'd1', 'first_stands', 'The first marks are right.'));
select is(array[pg_temp.code(pg_temp.r('settle_d1')), pg_temp.r('settle_d1') ->> 'check_state', pg_temp.cs('d1'), pg_temp.fm('d1'),
    (pg_temp.final_from('d1') = pg_temp.k('f:d1'))::text, pg_temp.st('d1'), pg_temp.reviews('d1')],
  array['ok', 'checked', 'checked', '1=1 first,2(a)=1 first,2(b)=1 first', 'true', 'checked', 'difference closed first_stands'],
  'settle_first_stands_writes_final_marks_and_checks_the_script');
select is(to_jsonb(array[pg_temp.marks('f:d1'), pg_temp.marks('s:d1'), pg_temp.rev('f:d1')::text, pg_temp.rev('s:d1')::text]), pg_temp.r('before_d1'),
  'markings_are_unchanged_by_a_settle: both markings'' marks and revs are as they were');
select is(array[pg_temp.code(pg_temp.change('f:d1', 'm1', jsonb_build_array(pg_temp.op('d1', '1', 2)), 'I missed a mark.')),
    pg_temp.code(pg_temp.change('s:d1', 'm2', jsonb_build_array(pg_temp.op('d1', '1', 2)), 'I missed a mark.')), pg_temp.fm('d1')],
  array['settled', 'settled', '1=1 first,2(a)=1 first,2(b)=1 first'],
  'R9: once the lead settled the piece, neither marker may change a mark (settled)');
select is(array[pg_temp.audits('marking_review_settled', pg_temp.u('d1')),
    (select count(*)::int from public.audit_log a where a.action = 'marking_review_settled' and a.target_id = pg_temp.u('d1')
       and a.actor_id = pg_temp.uid('lead') and position('The first marks are right.' in a.reason) > 0),
    (select count(*)::int from public.final_mark_history h where h.unit_id = pg_temp.u('d1') and not h.removed
       and h.changed_by = pg_temp.uid('lead') and h.reason = 'The first marks are right.'),
    (select count(*)::int from public.final_marks f where f.unit_id = pg_temp.u('d1') and f.set_by = pg_temp.uid('lead'))],
  array[1, 1, 3, 3], 'the settle is audited with its reason, and each final mark has its history with who and why');

-- ---------------------------------------------------------------------------------------------
-- settle_twice_is_refused (Review Focus 3)
-- ---------------------------------------------------------------------------------------------
insert into res values ('settle_d1_lead', pg_temp.settle('lead', 'd1', 'second_stands', 'Second thoughts.'));
insert into res values ('settle_d1_admin', pg_temp.settle('admin', 'd1', 'first_stands', 'Checking it again.'));
select is(array[pg_temp.code(pg_temp.r('settle_d1_lead')), pg_temp.r('settle_d1_lead') ->> 'reason',
    pg_temp.code(pg_temp.r('settle_d1_admin')), pg_temp.r('settle_d1_admin') ->> 'reason', pg_temp.fm('d1')],
  array['conflict', 'settled', 'conflict', 'settled', '1=1 first,2(a)=1 first,2(b)=1 first'],
  'settle_twice_is_refused: the lead again, or an admin after them: conflict, settled; the final marks stay');

-- ---------------------------------------------------------------------------------------------
-- settle_second_stands_uses_the_second_marks_and_layer
-- ---------------------------------------------------------------------------------------------
insert into res values ('settle_d2', pg_temp.settle('lead', 'd2', 'second_stands', 'The second marker is right.'));
select is(array[pg_temp.code(pg_temp.r('settle_d2')), pg_temp.fm('d2'), (pg_temp.final_from('d2') = pg_temp.k('s:d2'))::text, pg_temp.st('d2')],
  array['ok', '1=3 second,2(a)=2 second,2(b)=5 second', 'true', 'checked'],
  'settle_second_stands_uses_the_second_marks_and_layer: final_marking_id is the second marking');

-- ---------------------------------------------------------------------------------------------
-- settle_lead_marks_needs_every_question_in_range
-- ---------------------------------------------------------------------------------------------
insert into res values ('lm_missing', pg_temp.settle('lead', 'd3', 'lead_marks', 'Neither is right.',
  jsonb_build_array(pg_temp.mk('d3', '1', 2), pg_temp.mk('d3', '2(a)', null, true))));
select is(array[pg_temp.code(pg_temp.r('lm_missing')), pg_temp.r('lm_missing') ->> 'missing',
    pg_temp.code(pg_temp.settle('lead', 'd3', 'lead_marks', 'Neither is right.',
      jsonb_build_array(pg_temp.mk('d3', '1', 4), pg_temp.mk('d3', '2(a)', 1), pg_temp.mk('d3', '2(b)', 4)))),
    pg_temp.code(pg_temp.settle('lead', 'd3', 'lead_marks', 'Neither is right.',
      jsonb_build_array(pg_temp.mk('d3', '1', 0.5), pg_temp.mk('d3', '2(a)', 1), pg_temp.mk('d3', '2(b)', 4)))),
    pg_temp.code(pg_temp.settle('lead', 'd3', 'lead_marks', 'Neither is right.',
      jsonb_build_array(pg_temp.mk('d3', '1', 2), pg_temp.mk('d3', '2(a)', 1, true), pg_temp.mk('d3', '2(b)', 4)))),
    pg_temp.code(pg_temp.settle('lead', 'd3', 'lead_marks', 'Neither is right.',
      jsonb_build_array(pg_temp.mk('d3', '1', 2), pg_temp.mk('d3', '2(a)', 1), pg_temp.mk('d3', '2(b)', 4), pg_temp.mk('f1', '1', 1)))),
    pg_temp.code(pg_temp.settle('lead', 'd3', 'lead_marks', 'Neither is right.')), pg_temp.fm('d3'), pg_temp.cs('d3')],
  array['incomplete', '["2(b)"]', 'mark_out_of_range', 'mark_out_of_range', 'invalid_input', 'invalid_input', 'invalid_input', '', 'to_lead'],
  'settle_lead_marks_needs_every_question_in_range: a question left out, a mark over its maximum or off its step, NR with a mark, another exam''s question, no marks');
insert into res values ('settle_d3', pg_temp.settle('lead', 'd3', 'lead_marks', 'Neither is right.',
  jsonb_build_array(pg_temp.mk('d3', '1', 2), pg_temp.mk('d3', '2(a)', null, true), pg_temp.mk('d3', '2(b)', 4))));
select is(array[pg_temp.code(pg_temp.r('settle_d3')), pg_temp.fm('d3'), (pg_temp.final_from('d3') = pg_temp.k('f:d3'))::text,
    pg_temp.reviews('d3'), pg_temp.marks('f:d3'), pg_temp.marks('s:d3')],
  array['ok', '1=2 lead,2(a)=NR lead,2(b)=4 lead', 'true', 'difference closed lead_marks', '1=1,2(a)=1,2(b)=1', '1=3,2(a)=2,2(b)=5'],
  'the lead''s own marks for every question (NR counted): the final marks, the first marking''s layer; neither marking changes');

-- ---------------------------------------------------------------------------------------------
-- settle_refused_when_a_marking_changed_since_it_was_shown (Review Focus 3)
-- ---------------------------------------------------------------------------------------------
insert into res values ('open_d4', pg_temp.open('lead', pg_temp.rv('d4', 'difference')));
insert into res values ('chg_d4', pg_temp.change('f:d4', 'm1', jsonb_build_array(pg_temp.op('d4', '1', 2)), 'I missed a mark on 1.'));
insert into res values ('stale_d4', pg_temp.settle('lead', 'd4', 'first_stands', 'The first marks are right.', null,
  (pg_temp.r('open_d4') #>> '{first,rev}')::int, (pg_temp.r('open_d4') #>> '{second,rev}')::int));
select is(array[pg_temp.code(pg_temp.r('chg_d4')), pg_temp.code(pg_temp.r('stale_d4')), pg_temp.r('stale_d4') ->> 'reason', pg_temp.fm('d4'),
    pg_temp.reviews('d4'), pg_temp.cs('d4')],
  array['ok', 'conflict', 'changed', '', 'difference open', 'to_lead'],
  'settle_refused_when_a_marking_changed_since_it_was_shown: the first marker saved a change after it was opened: conflict, changed; no final mark');
insert into res values ('settle_d4', pg_temp.settle('lead', 'd4', 'first_stands', 'The first marks are right now.'));
select is(array[pg_temp.code(pg_temp.r('settle_d4')), pg_temp.fm('d4')], array['ok', '1=2 first,2(a)=1 first,2(b)=1 first'],
  'settled at the marks as they are now, it is the changed first marks that stand');

-- ---------------------------------------------------------------------------------------------
-- lead_who_is_a_party_may_settle_and_is_flagged
-- ---------------------------------------------------------------------------------------------
insert into res values ('open_d5', pg_temp.open('lead', pg_temp.rv('d5', 'difference')));
insert into res values ('settle_d5', pg_temp.settle('lead', 'd5', 'first_stands', 'My own marks were right.'));
select is(array[pg_temp.item(pg_temp.r('list_lead_diff'), 'd5') ->> 'party', pg_temp.item(pg_temp.r('list_lead_diff'), 'd1') ->> 'party',
    pg_temp.r('open_d5') #>> '{review,party}', pg_temp.code(pg_temp.r('settle_d5')), pg_temp.fm('d5')],
  array['true', 'false', 'true', 'ok', '1=1 first,2(a)=1 first,2(b)=1 first'],
  'lead_who_is_a_party_may_settle_and_is_flagged: the lead first-marked d5: party in the list and on opening, and they may settle it');

-- ---------------------------------------------------------------------------------------------
-- blocked_lead_cannot_open_settle_or_get_pictures
-- ---------------------------------------------------------------------------------------------
insert into public.marker_conflicts (marker_id, student_id, recorded_at) values (pg_temp.uid('lead'), pg_temp.student('d6'), now());
select is(array[pg_temp.code(pg_temp.open('lead', pg_temp.rv('d6', 'difference'))),
    pg_temp.code(pg_temp.settle('lead', 'd6', 'first_stands', 'The first marks are right.')), pg_temp.code(pg_temp.pics('lead', 'd6')),
    pg_temp.code(pg_temp.sb('lead', 'd6', 'other', 'Please mark this again.', 'Marks look off.')),
    pg_temp.itemset(pg_temp.list('lead', pg_temp.k('e'), 'difference')), pg_temp.itemset(pg_temp.list('admin', pg_temp.k('e'), 'difference'))],
  array['conflict_of_interest', 'conflict_of_interest', 'forbidden', 'conflict_of_interest', '', 'd6'],
  'blocked_lead_cannot_open_settle_or_get_pictures: a declared conflict for the candidate; the lead''s list leaves d6 out, an admin''s has it');
insert into public.tutor_students (tutor_id, student_id) values (pg_temp.uid('lead'), pg_temp.student('p1'));
insert into public.marking_unit_exclusions (unit_id, marker_id, reason) values (pg_temp.u('p2'), pg_temp.uid('lead'), 'name_seen');
select is(array[pg_temp.code(pg_temp.open('lead', pg_temp.rv('p1', 'paused_marker'))), pg_temp.code(pg_temp.open('lead', pg_temp.rv('p2', 'paused_marker')))],
  array['conflict_of_interest', 'conflict_of_interest'], 'so is a tutor link, and a name the lead saw on the script');
delete from public.tutor_students where tutor_id = pg_temp.uid('lead');
delete from public.marking_unit_exclusions where marker_id = pg_temp.uid('lead');

-- ---------------------------------------------------------------------------------------------
-- review_pictures_only_for_those_who_may_review
-- ---------------------------------------------------------------------------------------------
insert into res values ('pics_lead', pg_temp.pics('lead', 'p1'));
select is(array[pg_temp.code(pg_temp.r('pics_lead')), jsonb_array_length(pg_temp.r('pics_lead') -> 'paths')::text,
    pg_temp.code(pg_temp.pics('admin', 'p1')), pg_temp.code(pg_temp.pics('olead', 'p1')), pg_temp.code(pg_temp.pics('m7', 'p1')),
    pg_temp.code(pg_temp.pics('corr', 'p1')), pg_temp.code(pg_temp.pics('lead', 'f6'))],
  array['ok', '3', 'ok', 'forbidden', 'forbidden', 'forbidden', 'forbidden'],
  'review_pictures_only_for_those_who_may_review: the lead of a piece under review and admins; not another lead, a marker with no pass, a corrector, nor the lead on a piece with no review');
update public.exam_marking set approved_at = now(), approved_by = pg_temp.uid('admin') where exam_id = pg_temp.k('e');
select is(array[pg_temp.code(pg_temp.pics('lead', 'p1')), pg_temp.code(pg_temp.accept('lead', pg_temp.rv('p1', 'paused_marker'))),
    pg_temp.code(pg_temp.sb('lead', 'p2', 'other', 'Please mark this again.', 'Marks look off.')),
    pg_temp.code(pg_temp.settle('admin', 'd6', 'second_stands', 'The second marker is right.')),
    pg_temp.code(pg_temp.fs('admin', 's1', jsonb_build_array(pg_temp.mk('s1', '1', 2)), 'A fairer mark.')),
    pg_temp.code(pg_temp.sample('admin', 'e', 'm1'))],
  array['forbidden', 'marking_approved', 'marking_approved', 'marking_approved', 'marking_approved', 'marking_approved'],
  'once the exam''s marking is approved, no pictures through a review, and nothing is accepted, sent back, settled, changed or sampled');
update public.exam_marking set approved_at = null, approved_by = null where exam_id = pg_temp.k('e');
insert into res values ('settle_d6', pg_temp.settle('admin', 'd6', 'second_stands', 'The second marker is right.'));
select is(array[pg_temp.code(pg_temp.open('admin', pg_temp.rv('d6', 'difference'))), pg_temp.code(pg_temp.r('settle_d6')), pg_temp.fm('d6')],
  array['ok', 'ok', '1=3 second,2(a)=2 second,2(b)=5 second'], 'an admin opens and settles d6 instead');

-- ---------------------------------------------------------------------------------------------
-- paused_piece_accept_checks_it_without_a_second_marking
-- ---------------------------------------------------------------------------------------------
insert into res values ('acc_p1', pg_temp.accept('lead', pg_temp.rv('p1', 'paused_marker')));
select is(array[pg_temp.code(pg_temp.r('acc_p1')), pg_temp.r('acc_p1') ->> 'check_state', pg_temp.cs('p1'), pg_temp.reviews('p1'), pg_temp.fm('p1'),
    (select count(*)::text from public.markings m where m.unit_id = pg_temp.u('p1') and m.kind = 'second'), pg_temp.wanted('p1'),
    (pg_temp.final_from('p1') = pg_temp.k('f:p1'))::text, pg_temp.st('p1'), pg_temp.audits('marking_review_accepted', pg_temp.u('p1'))::text],
  array['ok', 'checked', 'checked', 'paused_marker closed accepted', '1=1 first,2(a)=1 first,2(b)=1 first', '0', 'true', 'true', 'checked', '1'],
  'paused_piece_accept_checks_it_without_a_second_marking: in the sample, yet checked on its first marks; audited');
select is(array[pg_temp.code(pg_temp.accept('lead', pg_temp.rv('p1', 'paused_marker'))),
    pg_temp.accept('lead', pg_temp.rv('p1', 'paused_marker')) ->> 'reason',
    pg_temp.code(pg_temp.accept('lead', pg_temp.rv('p2', 'paused_marker'), 'ab'))],
  array['conflict', 'settled', 'reason_required'], 'accepted twice: conflict, settled; a reason, when given, is 3 to 300 characters');

-- ---------------------------------------------------------------------------------------------
-- paused_piece_goes_only_to_another_marker
-- ---------------------------------------------------------------------------------------------
insert into res values ('sb_p2', pg_temp.sb('lead', 'p2', 'same', 'Please look at 2(b) again.', 'The marker was paused.'));
select is(array[pg_temp.code(pg_temp.r('sb_p2')), pg_temp.r('sb_p2') ->> 'to', pg_temp.ms('p2', 'm3'), pg_temp.excl('p2', 'm3'), pg_temp.us('p2'),
    pg_temp.cs('p2'), pg_temp.fm('p2'), pg_temp.reviews('p2')],
  array['ok', 'other', 'live set_aside sent_back', 'sent_back', 'open', '-', '', 'paused_marker closed sent_back'],
  'paused_piece_goes_only_to_another_marker: "same" asked, "other" answered; the marking set aside, the marker kept from the piece, the piece free');
insert into res values ('clear_m3', pg_temp.as('lead', format($q$ select public.marking_marker_clear(%L, %L, 'Talked it through.') $q$,
  pg_temp.k('e'), pg_temp.uid('m3'))));
select is(array[pg_temp.code(pg_temp.r('clear_m3')), pg_temp.blocked('p2', 'm3'),
    (pg_temp.u('p2') in (select a.unit_id from public.marking_units_allowed(pg_temp.k('e'), pg_temp.uid('m3'), 'live', true) a))::text,
    (pg_temp.u('p2') in (select a.unit_id from public.marking_units_allowed(pg_temp.k('e'), pg_temp.uid('m4'), 'live', true) a))::text],
  array['ok', 'name_seen', 'false', 'true'], 'cleared again, m3 is not offered it by Next script; another marker is');

-- ---------------------------------------------------------------------------------------------
-- send_back_same_reopens_the_marking_with_the_note_and_unchecks_the_script, sent_back_note_is_not_in_the_audit_log
-- ---------------------------------------------------------------------------------------------
insert into res values ('sb_s1', pg_temp.sb('lead', 's1', 'same', 'Look again at question two, please.', 'Marks look generous.'));
select is(array[pg_temp.code(pg_temp.r('sb_s1')), pg_temp.r('sb_s1') ->> 'to', pg_temp.ms('s1', 'm1'),
    (select m.sent_back_note from public.markings m where m.id = pg_temp.k('f:s1')), pg_temp.us('s1'), pg_temp.ended('s1', 'm1'), pg_temp.cs('s1'),
    pg_temp.st('s1'), pg_temp.fm('s1'), pg_temp.hist('s1', '1')],
  array['ok', 'same', 'live in_progress', 'Look again at question two, please.', 'taken', 'live next submitted,live assigned open', '-',
    'marking', '', '1 first,removed'],
  'send_back_same_reopens_the_marking_with_the_note_and_unchecks_the_script: an assigned hold, no check state, the final marks removed');
insert into res values ('open_s1', pg_temp.as('m1', format('select public.marking_unit_open(%L)', pg_temp.u('s1'))));
insert into res values ('work_m1', pg_temp.as('m1', 'select public.marking_my_work()'));
select is(array[pg_temp.code(pg_temp.r('open_s1')), pg_temp.r('open_s1') #>> '{marking,status}', pg_temp.r('open_s1') #>> '{marking,sent_back_note}',
    pg_temp.piece(pg_temp.r('work_m1'), pg_temp.u('s1')) ->> 'sent_back', pg_temp.piece(pg_temp.r('work_m1'), pg_temp.u('f1')) ->> 'sent_back'],
  array['ok', 'in_progress', 'Look again at question two, please.', 'true', 'false'],
  'the marker opens it with the lead''s note, and their list says it was sent back');
insert into res values ('resub_s1', pg_temp.mark('m1', pg_temp.u('s1'), array[1, 0, 1], 'f:s1'));
select is(array[pg_temp.code(pg_temp.r('resub_s1')), pg_temp.cs('s1'), pg_temp.fm('s1'), pg_temp.st('s1')],
  array['ok', 'checked', '1=1 first,2(a)=0 first,2(b)=1 first', 'checked'], 'submitted again, it is checked again');
select is(array[pg_temp.audits('marking_sent_back', pg_temp.u('s1')),
    (select count(*)::int from public.audit_log a where a.action = 'marking_sent_back' and a.target_id = pg_temp.u('s1')
       and a.actor_id = pg_temp.uid('lead') and position('Marks look generous.' in a.reason) > 0),
    (select count(*)::int from public.audit_log a where position('question two' in coalesce(a.reason, '')) > 0)],
  array[1, 1, 0], 'sent_back_note_is_not_in_the_audit_log: audited with the reason; the note is in no audit row');

-- ---------------------------------------------------------------------------------------------
-- send_back_falls_to_other_when_the_marker_is_unapproved_paused_or_blocked
-- ---------------------------------------------------------------------------------------------
delete from public.marker_approvals where marker_id = pg_temp.uid('m4');
insert into public.exam_markers (exam_id, marker_id, paused_at) values (pg_temp.k('e'), pg_temp.uid('m5'), now())
on conflict (exam_id, marker_id) do update set paused_at = excluded.paused_at;
insert into public.marker_conflicts (marker_id, student_id, recorded_at) values (pg_temp.uid('m6'), pg_temp.student('s4'), now());
insert into res select 'sb_' || x, pg_temp.sb('lead', x, 'same', 'Please mark this one again.', 'Marks look off.') from unnest(array['s2', 's3', 's4']) x;
select is(array[pg_temp.r('sb_s2') ->> 'to', pg_temp.r('sb_s3') ->> 'to', pg_temp.r('sb_s4') ->> 'to',
    pg_temp.ms('s2', 'm4'), pg_temp.ms('s3', 'm5'), pg_temp.ms('s4', 'm6'), pg_temp.excl('s2', 'm4'), pg_temp.excl('s3', 'm5'), pg_temp.excl('s4', 'm6'),
    pg_temp.us('s2'), pg_temp.us('s3'), pg_temp.us('s4')],
  array['other', 'other', 'other', 'live set_aside sent_back', 'live set_aside sent_back', 'live set_aside sent_back', 'sent_back', 'sent_back',
    'sent_back', 'open', 'open', 'open'],
  'send_back_falls_to_other_when_the_marker_is_unapproved_paused_or_blocked: m4 unapproved, m5 paused, m6 with a declared conflict');
select is(array[pg_temp.code(pg_temp.sb('lead', 's1', 'elsewhere', 'Please mark this one again.', 'Marks look off.')),
    pg_temp.code(pg_temp.sb('lead', 's1', 'same', 'ab', 'Marks look off.')),
    pg_temp.code(pg_temp.sb('lead', 's1', 'same', repeat('x', 1001), 'Marks look off.')),
    pg_temp.code(pg_temp.sb('lead', 's1', 'same', 'Please mark this one again.', null)),
    pg_temp.code(pg_temp.sb('lead', 's2', 'same', 'Please mark this one again.', 'Marks look off.')),
    pg_temp.sb('lead', 's2', 'same', 'Please mark this one again.', 'Marks look off.') ->> 'reason'],
  array['invalid_input', 'invalid_input', 'invalid_input', 'reason_required', 'conflict', 'not_submitted'],
  'send back needs same or other, a note of 3 to 1,000 characters, a reason, and a submitted first marking');

-- ---------------------------------------------------------------------------------------------
-- send_back_keeps_the_second_marking_and_compares_again_on_resubmit
-- ---------------------------------------------------------------------------------------------
insert into res values ('sb_k1', pg_temp.sb('lead', 'k1', 'same', 'Have another look at 2(b).', 'A second look is due.'));
select is(array[pg_temp.code(pg_temp.r('sb_k1')), pg_temp.r('sb_k1') ->> 'to', pg_temp.ms('k1', 'm2'), pg_temp.cs('k1'), pg_temp.fm('k1')],
  array['ok', 'same', 'second submitted', '-', ''], 'send_back_keeps_the_second_marking_and_compares_again_on_resubmit: the second marking stays');
insert into res values ('resub_k1', pg_temp.mark('m1', pg_temp.u('k1'), array[3, 2, 5], 'f:k1'));
select is(array[pg_temp.code(pg_temp.r('resub_k1')), pg_temp.cs('k1'), pg_temp.reviews('k1'),
    ((select r.marking_id = pg_temp.k('f:k1') and r.second_marking_id = pg_temp.k('s:k1') from public.marking_reviews r
      where r.id = pg_temp.rv('k1', 'difference')))::text],
  array['ok', 'to_lead', 'difference open', 'true'], 'submitted again, the two are compared again: now outside tolerance, with the lead');
-- R9: a settle covers the submission it reviewed only. d2's markings were submitted, and settled, an hour or more ago.
update public.markings set submitted_at = now() - interval '2 hours' where id in (pg_temp.k('f:d2'), pg_temp.k('s:d2'));
update public.marking_reviews set opened_at = now() - interval '90 minutes', closed_at = now() - interval '1 hour' where unit_id = pg_temp.u('d2');
insert into res values ('sb_d2', pg_temp.sb('lead', 'd2', 'same', 'Have another look, please.', 'Checking this again.'));
insert into res values ('resub_d2', pg_temp.mark('m1', pg_temp.u('d2'), array[1, 1, 1], 'f:d2'));
select is(array[pg_temp.r('sb_d2') ->> 'to', pg_temp.code(pg_temp.r('resub_d2')), pg_temp.cs('d2'), pg_temp.reviews('d2'), pg_temp.fm('d2')],
  array['same', 'ok', 'to_lead', 'difference closed second_stands,difference open', ''],
  'R9: sent back and submitted again, a settled piece is compared again: the old settle does not cover the new submission');

-- ---------------------------------------------------------------------------------------------
-- sample_review_leaves_check_state_and_script_state_alone, sample_skips_pieces_already_reviewed (exam f)
-- ---------------------------------------------------------------------------------------------
insert into res values ('f_before', (select jsonb_agg(jsonb_build_array(pg_temp.cs(x), pg_temp.st(x), pg_temp.fm(x)) order by x)
  from unnest(array['f1', 'f2', 'f3', 'f4', 'f5']) x));
select is(array[pg_temp.code(pg_temp.sample('m1', 'f', 'm1')), pg_temp.code(pg_temp.sample('olead', 'f', 'm1')),
    pg_temp.code(pg_temp.sample('lead', 'f', 'm1', 0)), pg_temp.code(pg_temp.sample('lead', 'f', 'm1', 21)),
    pg_temp.code(pg_temp.as('admin', format('select public.marking_review_sample(%L, %L)', gen_random_uuid(), pg_temp.uid('m1'))))],
  array['forbidden', 'forbidden', 'invalid_input', 'invalid_input', 'not_found'],
  'the routine sample is for the subject''s lead and admins, of 1 to 20 pieces');
insert into res values ('smp1', pg_temp.sample('lead', 'f', 'm1', 2));
insert into res values ('smp2', pg_temp.sample('lead', 'f', 'm1'));
insert into res values ('smp3', pg_temp.sample('admin', 'f', 'm1'));
select is(array[pg_temp.code(pg_temp.r('smp1')), pg_temp.r('smp1') ->> 'added', pg_temp.r('smp2') ->> 'added', pg_temp.r('smp3') ->> 'added'],
  array['ok', '2', '2', '0'], 'sample_skips_pieces_already_reviewed: 2 asked and added; then the 2 left; then none');
select is((select string_agg(pg_temp.nm(r.unit_id) || ' ' || r.state, ',' order by pg_temp.nm(r.unit_id))
           from public.marking_reviews r where r.exam_id = pg_temp.k('f') and r.kind = 'sample'),
  'f1 open,f2 open,f3 open,f4 open', 'one open sample review for each of m1''s pieces: not f5 (its difference was settled), not m2''s');
select is((select jsonb_agg(jsonb_build_array(pg_temp.cs(x), pg_temp.st(x), pg_temp.fm(x)) order by x) from unnest(array['f1', 'f2', 'f3', 'f4', 'f5']) x),
  pg_temp.r('f_before'), 'sample_review_leaves_check_state_and_script_state_alone: check states, script states and final marks as they were');
insert into res values ('list_f', pg_temp.list('lead', pg_temp.k('f'), 'sample'));
select is(array[pg_temp.itemset(pg_temp.r('list_f')), pg_temp.r('list_f') #>> '{counts,sample}',
    (select count(*)::text from public.audit_log a where a.action = 'marking_review_sampled' and a.target_id = pg_temp.uid('m1'))],
  array['f1,f2,f3,f4', '4', '2'], 'the lead''s list has the sample; each call that added pieces is audited');
insert into res values ('acc_f2', pg_temp.accept('lead', pg_temp.rv('f2', 'sample'), 'Looks fine to me.'));
insert into res values ('chg_f2', pg_temp.change('f:f2', 'm1', jsonb_build_array(pg_temp.op('f2', '1', 2)), 'A slip on question 1.'));
select is(array[pg_temp.code(pg_temp.r('acc_f2')), pg_temp.r('acc_f2') ->> 'check_state', pg_temp.reviews('f2'), pg_temp.code(pg_temp.r('chg_f2')),
    pg_temp.fm('f2')],
  array['ok', 'checked', 'sample closed accepted', 'ok', '1=2 first,2(a)=1 first,2(b)=1 first'],
  'an accepted sample settles nothing: the marker may still change a mark, and the final mark follows');
-- A lead is never shown the first marking of a piece they may yet second-mark.
insert into public.marking_reviews (exam_id, unit_id, kind, marking_id) values (pg_temp.k('e'), pg_temp.u('wt1'), 'sample', pg_temp.k('f:wt1'));
insert into res values ('smp_e', pg_temp.sample('lead', 'e', 'm1', 20));
select is(array[pg_temp.itemset(pg_temp.list('lead', pg_temp.k('e'), 'sample')), pg_temp.itemset(pg_temp.list('admin', pg_temp.k('e'), 'sample')),
    pg_temp.code(pg_temp.open('lead', pg_temp.rv('wt1', 'sample'))), pg_temp.code(pg_temp.open('admin', pg_temp.rv('wt1', 'sample'))),
    pg_temp.r('smp_e') ->> 'added', pg_temp.reviews('wt2')],
  array['s1', 's1,wt1', 'forbidden', 'ok', '1', '-'],
  'a piece waiting for a second marker: the lead''s list leaves its review out and opening it is refused; the sample skips such pieces (of m1''s on e only s1 is added: the others have reviews, wt2 waits)');

-- ---------------------------------------------------------------------------------------------
-- final_set_keeps_the_piece_checked_and_records_who_and_why
-- ---------------------------------------------------------------------------------------------
insert into res values ('fs_f1', pg_temp.fs('lead', 'f1', jsonb_build_array(pg_temp.mk('f1', '2(b)', 4)), 'A fairer mark for 2(b).'));
select is(array[pg_temp.code(pg_temp.r('fs_f1')), pg_temp.n(pg_temp.r('fs_f1'), 'total'), pg_temp.cs('f1'), pg_temp.fm('f1'), pg_temp.st('f1'),
    pg_temp.reviews('f1'), pg_temp.marks('f:f1')],
  array['ok', '6', 'checked', '1=1 first,2(a)=1 first,2(b)=4 lead', 'checked', 'sample closed lead_marks', '1=1,2(a)=1,2(b)=1'],
  'final_set_keeps_the_piece_checked_and_records_who_and_why: the final mark is the lead''s; the marker''s own marks stay');
select is(array[(select (f.set_by = pg_temp.uid('lead') and f.reason = 'A fairer mark for 2(b).')::text from public.final_marks f
                 where f.unit_id = pg_temp.u('f1') and f.question_id = pg_temp.q('f1', '2(b)')),
    pg_temp.hist('f1', '2(b)'),
    (select (h.changed_by = pg_temp.uid('lead') and h.reason = 'A fairer mark for 2(b).')::text from public.final_mark_history h
     where h.unit_id = pg_temp.u('f1') order by h.id desc limit 1),
    pg_temp.audits('final_mark_changed', pg_temp.u('f1'))::text],
  array['true', '1 first,4 lead', 'true', '1'], 'who and why are on the final mark and its history; audited');
select is(pg_temp.code(pg_temp.change('f:f1', 'm1', jsonb_build_array(pg_temp.op('f1', '1', 2)), 'A slip on question 1.')), 'settled',
  'R9: once the lead changed a final mark, the marker''s change is refused (settled)');
insert into res values ('fs_f7', pg_temp.fs('lead', 'f7', jsonb_build_array(pg_temp.mk('f7', '1', 3)), 'Question 1 deserves full marks.'));
select is(array[pg_temp.code(pg_temp.r('fs_f7')), pg_temp.reviews('f7'),
    pg_temp.code(pg_temp.change('f:f7', 'm2', jsonb_build_array(pg_temp.op('f7', '1', 1)), 'A slip on question 1.')), pg_temp.fm('f7')],
  array['ok', 'sample closed lead_marks', 'settled', '1=3 lead,2(a)=2 first,2(b)=2 first'],
  'with no review of the piece, a closed one is recorded: the marker''s change is refused (settled) and the lead''s mark stands');
insert into res values ('fs_p1', pg_temp.fs('lead', 'p1', jsonb_build_array(pg_temp.mk('p1', '1', 2)), 'Question 1 is worth 2.'));
insert into res values ('eval_p1', to_jsonb(public.marking_check_evaluate(pg_temp.u('p1'))));
select is(array[pg_temp.code(pg_temp.r('fs_p1')), pg_temp.r('eval_p1') #>> '{}', pg_temp.fm('p1')],
  array['ok', 'checked', '1=2 lead,2(a)=1 first,2(b)=1 first'],
  'a final mark changed after an accept stands when the piece is evaluated again');

-- ---------------------------------------------------------------------------------------------
-- final_set_out_of_range_or_empty_refused, final_set_on_a_piece_with_the_lead_refused
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.code(pg_temp.fs('lead', 'f3', jsonb_build_array(pg_temp.mk('f3', '1', 4)), 'A fairer mark.')),
    pg_temp.code(pg_temp.fs('lead', 'f3', jsonb_build_array(pg_temp.mk('f3', '1', 0.5)), 'A fairer mark.')),
    pg_temp.code(pg_temp.fs('lead', 'f3', jsonb_build_array(pg_temp.mk('f3', '1', null)), 'A fairer mark.')),
    pg_temp.code(pg_temp.fs('lead', 'f3', '[]', 'A fairer mark.')),
    pg_temp.code(pg_temp.fs('lead', 'f3', jsonb_build_array(pg_temp.mk('d1', '1', 1)), 'A fairer mark.')),
    pg_temp.code(pg_temp.fs('lead', 'f3', jsonb_build_array(pg_temp.mk('f3', '1', 2, true)), 'A fairer mark.')),
    pg_temp.code(pg_temp.fs('lead', 'f3', '{"question_id": 1}', 'A fairer mark.')),
    pg_temp.code(pg_temp.fs('lead', 'f3', jsonb_build_array(pg_temp.mk('f3', '1', 2)), null)), pg_temp.fm('f3'), pg_temp.reviews('f3')],
  array['mark_out_of_range', 'mark_out_of_range', 'incomplete', 'invalid_input', 'invalid_input', 'invalid_input', 'invalid_input',
    'reason_required', '1=1 first,2(a)=1 first,2(b)=1 first', 'sample open'],
  'final_set_out_of_range_or_empty_refused: over the maximum, off the step, left empty, none, another exam''s question, NR with a mark, not a list, no reason');
select is(array[pg_temp.code(pg_temp.fs('lead', 'k1', jsonb_build_array(pg_temp.mk('k1', '1', 2)), 'A fairer mark.')),
    pg_temp.fs('lead', 'k1', jsonb_build_array(pg_temp.mk('k1', '1', 2)), 'A fairer mark.') ->> 'reason',
    pg_temp.code(pg_temp.fs('lead', 'wt2', jsonb_build_array(pg_temp.mk('wt2', '1', 2)), 'A fairer mark.')),
    pg_temp.fs('lead', 'wt2', jsonb_build_array(pg_temp.mk('wt2', '1', 2)), 'A fairer mark.') ->> 'reason', pg_temp.fm('k1')],
  array['conflict', 'with_lead', 'conflict', 'not_checked', ''],
  'final_set_on_a_piece_with_the_lead_refused: a difference is settled instead; a piece not checked yet is refused too');

-- ---------------------------------------------------------------------------------------------
-- lead_of_another_subject_and_corrector_forbidden
-- ---------------------------------------------------------------------------------------------
select is(array[
    pg_temp.code(pg_temp.open('olead', pg_temp.rv('k1', 'difference'))), pg_temp.code(pg_temp.settle('olead', 'k1', 'first_stands', 'Looks right to me.')),
    pg_temp.code(pg_temp.accept('olead', pg_temp.rv('f3', 'sample'))), pg_temp.code(pg_temp.sb('olead', 'f3', 'same', 'Please mark this again.', 'Marks look off.')),
    pg_temp.code(pg_temp.sample('olead', 'f', 'm2')), pg_temp.code(pg_temp.fs('olead', 'f3', jsonb_build_array(pg_temp.mk('f3', '1', 2)), 'A fairer mark.')),
    pg_temp.code(pg_temp.open('corr', pg_temp.rv('k1', 'difference'))), pg_temp.code(pg_temp.settle('corr', 'k1', 'first_stands', 'Looks right to me.')),
    pg_temp.code(pg_temp.accept('corr', pg_temp.rv('f3', 'sample'))), pg_temp.code(pg_temp.sb('corr', 'f3', 'same', 'Please mark this again.', 'Marks look off.')),
    pg_temp.code(pg_temp.sample('corr', 'f', 'm2')), pg_temp.code(pg_temp.fs('corr', 'f3', jsonb_build_array(pg_temp.mk('f3', '1', 2)), 'A fairer mark.')),
    pg_temp.code(pg_temp.open('m7', pg_temp.rv('k1', 'difference'))), pg_temp.code(pg_temp.fs('m7', 'f3', jsonb_build_array(pg_temp.mk('f3', '1', 2)), 'A fairer mark.'))],
  array_fill('forbidden'::text, array[14]),
  'lead_of_another_subject_and_corrector_forbidden: another subject''s lead, a corrector and a marker can do none of it');
select is(array[pg_temp.code(pg_temp.open('admin', gen_random_uuid())), pg_temp.code(pg_temp.open('lead', gen_random_uuid())),
    pg_temp.code(pg_temp.as('admin', format($q$ select public.marking_send_back(%L, 'same', 'Please mark this again.', 'Marks look off.') $q$, gen_random_uuid())))],
  array['not_found', 'forbidden', 'not_found'], 'an unknown review or piece: not_found to an admin, forbidden to anyone else');

-- ---------------------------------------------------------------------------------------------
-- stuck_second_counts_a_piece_nobody_can_take (exam w), and to_clear (exam g)
-- ---------------------------------------------------------------------------------------------
insert into res values ('w_before', pg_temp.list('admin', pg_temp.k('w')));
insert into public.marker_conflicts (marker_id, student_id, recorded_at) values (pg_temp.uid('t2'), pg_temp.student('w1'), now());
insert into public.exam_markers (exam_id, marker_id, paused_at) values (pg_temp.k('w'), pg_temp.uid('tl'), now());
select is(array[pg_temp.r('w_before') #>> '{counts,stuck_second}', pg_temp.list('admin', pg_temp.k('w')) #>> '{counts,stuck_second}',
    pg_temp.list('tl', pg_temp.k('w')) #>> '{counts,stuck_second}'],
  array['0', '1', '1'],
  'stuck_second_counts_a_piece_nobody_can_take: w1 waits; once t2 has a conflict and the lead is paused, nobody can second-mark it');
insert into res values ('g_next', pg_temp.next('m7', 'g'));
select pg_temp.mark('m7', (pg_temp.r('g_next') ->> 'unit_id')::uuid, array[1, 1, 1], 'g:m7');
insert into res values ('g_list', pg_temp.list('lead', pg_temp.k('g')));
insert into res values ('g_clear', pg_temp.as('lead', format($q$ select public.marking_marker_clear(%L, %L, 'Practice went well.') $q$,
  pg_temp.k('g'), pg_temp.uid('m7'))));
select is(array[pg_temp.nm((pg_temp.r('g_next') ->> 'unit_id')::uuid), pg_temp.r('g_list') #>> '{counts,to_clear}', pg_temp.code(pg_temp.r('g_clear')),
    pg_temp.list('lead', pg_temp.k('g')) #>> '{counts,to_clear}'],
  array['gp1', '1', 'ok', '0'], 'to_clear counts a marker who did every practice script and is not cleared yet');

-- ---------------------------------------------------------------------------------------------
-- Ruling R11: seeded scripts or practice turned off mid-exam (subject 'ZZ Rev Small').
-- ---------------------------------------------------------------------------------------------
select pg_temp.until0('s', 'x1');
insert into res values ('s_next1', pg_temp.next('x1', 's'));
insert into kv values ('a:seedS', (pg_temp.r('s_next1') ->> 'unit_id')::uuid);
insert into res values ('s_open', pg_temp.as('x1', format('select public.marking_unit_open(%L)', pg_temp.a('seedS'))));
insert into res values ('p_next1', pg_temp.next('x1', 'p'));
insert into res values ('p_open', pg_temp.as('x1', format('select public.marking_unit_open(%L)', pg_temp.u('pr1'))));
insert into res values ('work_x1', pg_temp.as('x1', 'select public.marking_my_work()'));
select is(array[(pg_temp.nm(pg_temp.a('seedS')) in ('q1', 'q2'))::text, pg_temp.code(pg_temp.r('s_open')), pg_temp.nm((pg_temp.r('p_next1') ->> 'unit_id')::uuid),
    pg_temp.code(pg_temp.r('p_open')), pg_temp.exam(pg_temp.r('work_x1'), 's') ->> 'left'],
  array['true', 'ok', 'pr1', 'ok', '3'], 'fixtures: x1 holds a seeded script on s (left counts r1, r2 and the other seed) and a practice script on p');
-- The subject must have one approved marker for a check to be turned off: its lead leaves.
update public.profiles set status = 'suspended' where id = pg_temp.uid('sl');
insert into res values ('s_off', pg_temp.as('admin', format($q$ select public.marking_checks_set(%L,
  '{"double_marking": false, "sample_percent": 10, "tolerance_percent": 10, "seeds": false, "seed_every": 3, "practice": false}',
  'Only one marker is left.') $q$, pg_temp.k('s'))));
select is(array[pg_temp.code(pg_temp.r('s_off')), ((pg_temp.std('q1')).retired_at is not null)::text, ((pg_temp.std('q2')).retired_at is not null)::text,
    pg_temp.ended(pg_temp.nm(pg_temp.a('seedS')), 'x1'), pg_temp.ms(pg_temp.nm(pg_temp.a('seedS')), 'x1'),
    (select count(*)::text from public.audit_log a where a.action = 'marking_standard_retired' and a.actor_id = pg_temp.uid('admin')
       and a.target_id in ((pg_temp.std('q1')).id, (pg_temp.std('q2')).id))],
  array['ok', 'true', 'true', 'seed next switched_off', 'seed set_aside switched_off', '2'],
  'R11 seeds off mid-exam: the seeded scripts stop being used; x1''s hold ends and their attempt is set aside (switched_off)');
insert into res values ('s_work', pg_temp.as('x1', 'select public.marking_my_work()'));
insert into res values ('s_next2', pg_temp.next('x1', 's'));
select pg_temp.mark('x1', (pg_temp.r('s_next2') ->> 'unit_id')::uuid, array[1, 1, 1], 'x1:s:1');
insert into res values ('s_next3', pg_temp.next('x1', 's'));
select pg_temp.mark('x1', (pg_temp.r('s_next3') ->> 'unit_id')::uuid, array[1, 1, 1], 'x1:s:2');
insert into res values ('s_work2', pg_temp.as('x1', 'select public.marking_my_work()'));
insert into res values ('s_next4', pg_temp.next('x1', 's'));
select is(array[pg_temp.exam(pg_temp.r('s_work'), 's') ->> 'left', pg_temp.r('s_next2') ->> 'resumed',
    (select string_agg(pg_temp.nm((pg_temp.r(x) ->> 'unit_id')::uuid), ',' order by pg_temp.nm((pg_temp.r(x) ->> 'unit_id')::uuid))
     from unnest(array['s_next2', 's_next3']) x),
    pg_temp.exam(pg_temp.r('s_work2'), 's') ->> 'left', pg_temp.code(pg_temp.r('s_next4'))],
  array['2', 'false', 'r1,r2', '0', 'nothing_left'],
  'then left and Next script agree: left counts r1 and r2, Next script hands out those two and no seed, then left is 0 and Next says nothing_left');
insert into res values ('p_off', pg_temp.as('admin', format($q$ select public.marking_checks_set(%L,
  '{"double_marking": false, "sample_percent": 10, "tolerance_percent": 10, "seeds": false, "seed_every": 10, "practice": false}',
  'Practice is not needed now.') $q$, pg_temp.k('p'))));
insert into res values ('p_work', pg_temp.as('x1', 'select public.marking_my_work()'));
insert into res values ('p_next2', pg_temp.next('x1', 'p'));
select is(array[pg_temp.code(pg_temp.r('p_off')), ((pg_temp.std('pr1')).retired_at is not null)::text, pg_temp.ended('pr1', 'x1'), pg_temp.ms('pr1', 'x1'),
    coalesce(pg_temp.exam(pg_temp.r('p_work'), 'p') ->> 'practice', 'null'), pg_temp.exam(pg_temp.r('p_work'), 'p') ->> 'left',
    left(pg_temp.nm((pg_temp.r('p_next2') ->> 'unit_id')::uuid), 1), pg_temp.r('p_next2') ->> 'resumed'],
  array['ok', 'true', 'practice next switched_off', 'practice set_aside switched_off', 'null', '2', 'l', 'false'],
  'R11 practice off mid-exam: the practice script stops being used and x1''s hold on it ends; x1 is cleared, left counts l1 and l2 and Next script gives one of them');

-- ---------------------------------------------------------------------------------------------
-- sent_back in the marker's list: the same key on every kind of piece (Review Focus 1).
-- ---------------------------------------------------------------------------------------------
insert into res values ('work_m2', pg_temp.as('m2', 'select public.marking_my_work()'));
select is(array[
    (select count(*)::text from res r cross join jsonb_array_elements(r.j -> 'pieces') x
     where r.name in ('work_m1', 'work_m2', 'work_x1') and not x ? 'sent_back'),
    pg_temp.piece(pg_temp.r('work_m2'), pg_temp.u('d1')) ->> 'sent_back', pg_temp.piece(pg_temp.r('work_x1'), pg_temp.a('seedS')) ->> 'sent_back',
    pg_temp.piece(pg_temp.r('work_x1'), pg_temp.u('pr1')) ->> 'sent_back', pg_temp.piece(pg_temp.r('work_m1'), pg_temp.u('s1')) ->> 'sent_back',
    (pg_temp.keys(pg_temp.piece(pg_temp.r('work_x1'), pg_temp.a('seedS'))) = pg_temp.keys(pg_temp.piece(pg_temp.r('work_m1'), pg_temp.u('f1'))))::text],
  array['0', 'false', 'false', 'false', 'true', 'true'],
  'marking_my_work: every piece says sent_back, live, second, seeded and practice alike; a seeded piece has a live piece''s keys');

-- ---------------------------------------------------------------------------------------------
-- Privileges.
-- ---------------------------------------------------------------------------------------------
select is((select array_agg(f order by f) from unnest(array[
    'public.marking_review_refusal(uuid)', 'public.marking_review_blind(uuid)', 'public.marking_review_marking(uuid)',
    'public.marking_lead_marks_refusal(uuid,jsonb,boolean)', 'public.marking_final_marks_lead(uuid,jsonb,text)',
    'public.marking_unit_settled(uuid)', 'public.marking_check_evaluate(uuid)']) f
  where has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute')
     or has_function_privilege('service_role', f, 'execute')),
  null, 'the internal functions are revoked from every client role');
select is((select array_agg(f order by f) from unnest(array[
    'public.marking_review_list(uuid,text)', 'public.marking_review_open(uuid)',
    'public.marking_review_settle(uuid,text,integer,integer,text,jsonb)', 'public.marking_review_accept(uuid,text)',
    'public.marking_send_back(uuid,text,text,text)', 'public.marking_review_sample(uuid,uuid,integer)',
    'public.marking_final_set(uuid,jsonb,text)', 'public.marking_checks_set(uuid,jsonb,text)', 'public.marking_my_work(timestamptz)',
    'public.marking_picture_paths(uuid,uuid[],timestamptz)']) f
  where not has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute')),
  null, 'the others are for signed-in users only');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('marking_review_list', 'marking_review_open', 'marking_review_settle', 'marking_review_accept', 'marking_send_back',
                             'marking_review_sample', 'marking_final_set', 'marking_review_refusal', 'marking_review_blind', 'marking_review_marking',
                             'marking_lead_marks_refusal', 'marking_final_marks_lead')
           and p.prosecdef and p.proconfig @> array['search_path=""']),
  12, 'each is security definer with an empty search path');

select * from finish();
rollback;
