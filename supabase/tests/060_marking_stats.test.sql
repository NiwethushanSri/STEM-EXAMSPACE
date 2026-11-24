begin;
create extension if not exists pgtap with schema extensions;
select plan(31);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Subject 'ZZ Stats': markers a to j, h2 and x1 to x5 (tests.marker), mk (approved, marks only a re-mark) and
-- the lead marker;
-- corr is a corrector never approved; olead leads 'ZZ Stats Other'. Markings are written directly as postgres (pg_temp.w: the
-- marks for the piece's questions in paper order, their total and the active seconds), except on exam sb, where the
-- pieces are marked and sent back through the real functions. marking_stats only reads.
--   q:  by question, groups A and B, each one question of 10 marks. Group A: a 4 pieces at 8, b 4 at 4, e 3 at 6;
--       group B: c 4 at 3, d 4 at 1, e 1 at 2. Group A's mean is 60%, group B's 20%, the exam's 42%.
--   w:  the test structure (1 of 3 marks, 2(a) of 2, 2(b) of 5: out of 10, every tolerance the floor of one mark),
--       first and second markings of w1 to w7 (below), and re-markings of w1 (c) and w2 (mk) that count nowhere.
--   s:  the lead's live markings of s1 to s4; s1 and s2 are seeded scripts, s3 and s4 practice; a, b and c attempt them.
--   v:  a marks v1 to v6; v3's script is withdrawn, v4's void, v5's marking set aside, v6's in progress.
--   n:  f marks 9 pieces at full marks; g 10 pieces, 3 at full marks; h 10 pieces, 2 at full marks.
--   p:  tolerance 20%: h2 marks 10 pieces at 1 of 10 in 10 seconds each; i and j 10 pieces each at 5 in 600 seconds.
--   r:  the notes' edges: x1 marks 10 pieces at 70% in 199 s, x2 10 at 49.9% in 201 s, x3 to x5 10 each at 60% in
--       600 s. The exam's median is 600 s (a third: 200) and the cohort 60.0% (2,999 / 50), so x1 is 10.0 points
--       above (at the tolerance) and x2 10.1 below (over it).
--   t:  a seeded script t1 (the lead's), attempted by f at tolerance 10% and by d at 50%, each judged by its submit
--       (marking_after_submit); the tolerance is then raised and lowered.
--   sb: checks off; pieces marked with tests.mark_piece and sent back by the lead.
-- A piece is kept as 'u:<script>' (whole script) or 'u:<script>:<group>' (by question); a marking as kv p_key.
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
create function pg_temp.keys(j jsonb) returns text language sql immutable as $$
  select array_to_string(array(select k from jsonb_object_keys(j) k order by 1), ',') $$;
-- A marker's entry of a result, and one of its figures ('null' for none; numbers without trailing zeros).
create function pg_temp.mrk(p_res text, p_marker text) returns jsonb language sql stable as $$
  select x from jsonb_array_elements(pg_temp.r(p_res) -> 'markers') x where x ->> 'marker_id' = pg_temp.uid(p_marker)::text $$;
create function pg_temp.f(p_res text, p_marker text, variadic p_path text[]) returns text language sql stable as $$
  select coalesce(trim_scale((pg_temp.mrk(p_res, p_marker) #>> p_path)::numeric)::text, 'null') $$;
create function pg_temp.e(p_res text, p_key text) returns text language sql stable as $$
  select coalesce(trim_scale((pg_temp.r(p_res) #>> array['exam', p_key])::numeric)::text, 'null') $$;
-- A marker's seeds outside tolerance on the Markers tab (marking_exam_markers).
create function pg_temp.tab_out(p_res text, p_marker text) returns text language sql stable as $$
  select x #>> '{seeds,outside}' from jsonb_array_elements(pg_temp.r(p_res) -> 'markers') x
  where x ->> 'marker_id' = pg_temp.uid(p_marker)::text $$;
create function pg_temp.notes(p_res text, p_marker text) returns text language sql stable as $$
  select coalesce((pg_temp.mrk(p_res, p_marker) -> 'notes')::text, 'null') $$;
-- Signed in as someone: a call's answer.
create function pg_temp.as(p_who text, p_sql text) returns jsonb language plpgsql as $$
declare
  v_r jsonb;
begin
  perform tests.as_user(pg_temp.uid(p_who));
  execute p_sql into v_r;
  perform tests.as_postgres();
  return v_r;
end $$;
create function pg_temp.stats(p_who text, p_exam uuid) returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.marking_stats(%L)', p_exam)) $$;
-- New verified home scripts of an exam, named p_prefix || 1..p_n (their pieces are made when marking opens).
create function pg_temp.scripts(p_prefix text, p_exam text, p_n int) returns void language plpgsql as $$
begin
  for i in 1..p_n loop
    insert into kv values (p_prefix || i, tests.verified_script(pg_temp.k(p_exam), 'home'));
  end loop;
end $$;
-- A save's mark operations for a piece's questions in paper order (p_marks[i], 0 when not given).
create function pg_temp.ops(p_unit uuid, p_marks numeric[]) returns jsonb language sql stable security definer as $$
  select jsonb_agg(jsonb_build_object('op', 'mark', 'question_id', q.question_id, 'mark', coalesce(p_marks[q.n], 0), 'na', false) order by q.n)
  from (select t.question_id, row_number() over (order by t.path) as n from public.marking_unit_questions(p_unit) t where t.leaf) q $$;
-- A marking written as postgres: its kind, marker and status (submitted unless given), its marks for the piece's
-- questions in paper order (p_marks[i], 0 when not given) and their total, and its active seconds. Kept as kv p_key.
create function pg_temp.w(p_key text, p text, p_kind text, p_marker text, p_marks numeric[], p_secs int default 60,
  p_status text default 'submitted') returns void language plpgsql as $$
declare
  v uuid;
begin
  insert into public.markings (unit_id, kind, marker_id, status, rev, total, active_seconds, last_saved_at, submitted_at, set_aside_at,
    set_aside_reason, feedback_at)
  values (pg_temp.u(p), p_kind::public.marking_kind, pg_temp.uid(p_marker), p_status, 1, (select coalesce(sum(x), 0) from unnest(p_marks) x),
    p_secs, now(), case when p_status = 'submitted' then now() end, case when p_status = 'set_aside' then now() end,
    case when p_status = 'set_aside' then 'taken_back' end, case when p_kind = 'practice' and p_status = 'submitted' then now() end)
  returning id into v;
  insert into public.question_marks (marking_id, question_id, mark)
  select v, q.question_id, coalesce(p_marks[q.n], 0)
  from (select t.question_id, row_number() over (order by t.path) as n from public.marking_unit_questions(pg_temp.u(p)) t where t.leaf) q;
  insert into kv values (p_key, v) on conflict (name) do update set id = excluded.id;
end $$;
-- A piece made a standard (a practice or seeded script) from the lead's live marking of it, kept as 'f:<piece>'.
create function pg_temp.standard(p text, p_use text) returns void language plpgsql as $$
declare
  v uuid;
begin
  insert into public.marking_standards (exam_id, unit_id, use, set_by)
  select u.exam_id, u.id, p_use, pg_temp.uid('lead') from public.marking_units u where u.id = pg_temp.u(p)
  returning id into v;
  insert into public.marking_standard_marks (standard_id, question_id, mark, not_attempted)
  select v, q.question_id, q.mark, q.not_attempted from public.question_marks q where q.marking_id = pg_temp.k('f:' || p);
end $$;
-- Sending a piece back, signed in as someone; the marker's own resubmit of a piece sent back to them.
create function pg_temp.sb(p_who text, p text, p_to text) returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.marking_send_back(%L, %L, %L, %L)', pg_temp.u(p), p_to,
    'Look again at question 2.', 'Question 2 looks harsh')) $$;
create function pg_temp.resubmit(p_marker text, p text, p_marks numeric[]) returns text language plpgsql as $$
declare
  v_unit uuid := pg_temp.u(p);
  v_who uuid := pg_temp.uid(p_marker);
  v_ops jsonb := pg_temp.ops(pg_temp.u(p), p_marks);
  v_r jsonb;
  v_mk uuid;
begin
  perform tests.as_user(v_who);
  v_r := public.marking_unit_open(v_unit);
  v_mk := (v_r #>> '{marking,id}')::uuid;
  v_r := public.marking_save(v_mk, (v_r #>> '{marking,rev}')::int, v_ops);
  v_r := public.marking_submit(v_mk, (v_r ->> 'rev')::int);
  perform tests.as_postgres();
  return pg_temp.code(v_r);
end $$;

insert into public.subjects (name, kind) values ('ZZ Stats', 'school'), ('ZZ Stats Other', 'school'), ('ZZ Stats Big', 'school');
insert into c values ('admin', tests.create_user('admin', 'active')), ('corr', tests.create_user('corrector', 'active'));
insert into c select x, tests.marker(pg_temp.subj('ZZ Stats'))
from unnest(array['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'h2', 'i', 'j', 'mk', 'x1', 'x2', 'x3', 'x4', 'x5']) x;
insert into c values ('lead', tests.marker(pg_temp.subj('ZZ Stats'), true)), ('olead', tests.marker(pg_temp.subj('ZZ Stats Other'), true));
update public.profiles set first_name = 'Aurelius', last_name = 'Firstley' where id = pg_temp.uid('a');
update public.profiles set first_name = 'Bartholomew', last_name = 'Secondo' where id = pg_temp.uid('b');

insert into kv select x, tests.marking_exam(pg_temp.subj('ZZ Stats')) from unnest(array['q', 'w', 's', 'v', 'n', 'p', 'sb', 'r', 't']) x;
select tests.structure(pg_temp.k(x)) from unnest(array['w', 's', 'v', 'n', 'p', 'sb', 'r', 't']) x;
insert into public.question_groups (exam_id, label, position) values (pg_temp.k('q'), 'A', 1), (pg_temp.k('q'), 'B', 2);
insert into public.exam_questions (exam_id, label, position, max_mark, pages, group_id)
select g.exam_id, g.position::text, g.position, 10, '{1}', g.id from public.question_groups g where g.exam_id = pg_temp.k('q');
update public.exam_marking set mode = 'by_question' where exam_id = pg_temp.k('q');
select pg_temp.scripts('q', 'q', 11), pg_temp.scripts('w', 'w', 7), pg_temp.scripts('s', 's', 4), pg_temp.scripts('v', 'v', 6),
  pg_temp.scripts('n', 'n', 29), pg_temp.scripts('p', 'p', 30), pg_temp.scripts('sb', 'sb', 4), pg_temp.scripts('r', 'r', 50),
  pg_temp.scripts('t', 't', 1);
select tests.open_marking(pg_temp.k(x)) from unnest(array['q', 'w', 's', 'v', 'n', 'sb', 'r', 't']) x;
select tests.open_marking(pg_temp.k('p'), '{"tolerance_percent": 20}');
insert into kv select 'u:' || k.name || coalesce(':' || g.label, ''), u.id
from kv k join public.marking_units u on u.script_id = k.id left join public.question_groups g on g.id = u.group_id;

-- Exam q.
select pg_temp.w('q' || i || 'A', 'q' || i || ':A', 'live', 'a', array[8]) from generate_series(1, 4) i;
select pg_temp.w('q' || i || 'A', 'q' || i || ':A', 'live', 'b', array[4]) from generate_series(5, 8) i;
select pg_temp.w('q' || i || 'A', 'q' || i || ':A', 'live', 'e', array[6]) from generate_series(9, 11) i;
select pg_temp.w('q' || i || 'B', 'q' || i || ':B', 'live', 'c', array[3]) from generate_series(1, 4) i;
select pg_temp.w('q' || i || 'B', 'q' || i || ':B', 'live', 'd', array[1]) from generate_series(5, 8) i;
select pg_temp.w('q9B', 'q9:B', 'live', 'e', array[2]);

-- Exam w: first (live) and second markings.
select pg_temp.w('f:w1', 'w1', 'live', 'a', array[1, 1, 1], 100), pg_temp.w('s:w1', 'w1', 'second', 'b', array[1, 1, 1], 50);
select pg_temp.w('f:w2', 'w2', 'live', 'a', array[1, 1, 1], 200), pg_temp.w('s:w2', 'w2', 'second', 'b', array[2, 1, 1], 50);
select pg_temp.w('f:w3', 'w3', 'live', 'a', array[1, 1, 1], 300), pg_temp.w('s:w3', 'w3', 'second', 'b', array[3, 2, 5], 50);
select pg_temp.w('f:w4', 'w4', 'live', 'b', array[2, 2, 2], 50), pg_temp.w('s:w4', 'w4', 'second', 'a', array[2, 2, 2], 400);
select pg_temp.w('f:w5', 'w5', 'live', 'c', array[3, 2, 5], 70), pg_temp.w('s:w5', 'w5', 'second', 'b', array[0, 0, 0], 50);
select pg_temp.w('f:w6', 'w6', 'live', 'a', array[1, 1, 1], 1000), pg_temp.w('s:w6', 'w6', 'second', 'c', array[1, 1, 1], 5, 'in_progress');
select pg_temp.w('f:w7', 'w7', 'live', 'a', array[3, 2, 5], 9999, 'set_aside'), pg_temp.w('s:w7', 'w7', 'second', 'b', array[3, 2, 5], 50);
select pg_temp.w('r:w1', 'w1', 'remark', 'c', array[3, 2, 5], 99999), pg_temp.w('r:w2', 'w2', 'remark', 'mk', array[3, 2, 5], 99999);

-- Exam s: the lead's live markings, the standards, and the attempts.
select pg_temp.w('f:s1', 's1', 'live', 'lead', array[1, 1, 1]), pg_temp.w('f:s2', 's2', 'live', 'lead', array[1, 1, 1]),
  pg_temp.w('f:s3', 's3', 'live', 'lead', array[1, 1, 1]), pg_temp.w('f:s4', 's4', 'live', 'lead', array[2, 2, 2]);
select pg_temp.standard('s1', 'seed'), pg_temp.standard('s2', 'seed'), pg_temp.standard('s3', 'practice'), pg_temp.standard('s4', 'practice');
select pg_temp.w('a:s1', 's1', 'seed', 'a', array[1, 1, 1]), pg_temp.w('a:s2', 's2', 'seed', 'a', array[3, 2, 5]),
  pg_temp.w('b:s1', 's1', 'seed', 'b', array[2, 1, 1]), pg_temp.w('b:s2', 's2', 'seed', 'b', array[1, 1, 1], 60, 'in_progress');
update public.markings set feedback_at = now() where id = pg_temp.k('a:s2');
select pg_temp.w('b:s3', 's3', 'practice', 'b', array[1, 1, 1]), pg_temp.w('b:s4', 's4', 'practice', 'b', array[0, 0, 0]),
  pg_temp.w('c:s3', 's3', 'practice', 'c', array[3, 2, 5]), pg_temp.w('a:s4', 's4', 'practice', 'a', array[2, 2, 2], 60, 'in_progress');

-- Exam v.
select pg_temp.w('f:v1', 'v1', 'live', 'a', array[1, 1, 1], 100), pg_temp.w('f:v2', 'v2', 'live', 'a', array[2, 2, 2], 300),
  pg_temp.w('f:v3', 'v3', 'live', 'a', array[3, 2, 5], 5000), pg_temp.w('f:v4', 'v4', 'live', 'a', array[3, 2, 5], 5000),
  pg_temp.w('f:v5', 'v5', 'live', 'a', array[3, 2, 5], 5000, 'set_aside'), pg_temp.w('f:v6', 'v6', 'live', 'a', array[3, 2, 5], 5000, 'in_progress');
select pg_temp.w('s:v1', 'v1', 'second', 'b', array[1, 1, 1], 50), pg_temp.w('s:v3', 'v3', 'second', 'b', array[3, 2, 5], 50),
  pg_temp.w('s:v4', 'v4', 'second', 'c', array[3, 2, 5], 50);
update public.scripts set state = 'withdrawn' where id = pg_temp.k('v3');
update public.scripts set state = 'void' where id = pg_temp.k('v4');

-- Exams n and p.
select pg_temp.w('f:n' || i, 'n' || i, 'live', 'f', array[3, 2, 5]) from generate_series(1, 9) i;
select pg_temp.w('f:n' || i, 'n' || i, 'live', 'g', case when i <= 12 then array[3, 2, 5] else array[3, 2, 4] end) from generate_series(10, 19) i;
select pg_temp.w('f:n' || i, 'n' || i, 'live', 'h', case when i <= 21 then array[3, 2, 5] else array[3, 2, 4] end) from generate_series(20, 29) i;
select pg_temp.w('f:p' || i, 'p' || i, 'live', 'h2', array[0, 0, 1], 10) from generate_series(1, 10) i;
select pg_temp.w('f:p' || i, 'p' || i, 'live', 'i', array[1, 1, 3], 600) from generate_series(11, 20) i;
select pg_temp.w('f:p' || i, 'p' || i, 'live', 'j', array[1, 1, 3], 600) from generate_series(21, 30) i;

-- Exam r.
select pg_temp.w('f:r' || i, 'r' || i, 'live', 'x1', array[2, 2, 3], 199) from generate_series(1, 10) i;
select pg_temp.w('f:r' || i, 'r' || i, 'live', 'x2', case when i < 20 then array[1, 1, 3] else array[1, 1, 2.9] end, 201)
from generate_series(11, 20) i;
select pg_temp.w('f:r' || i, 'r' || i, 'live', 'x' || (3 + (i - 21) / 10), array[2, 1, 3], 600) from generate_series(21, 50) i;

-- Exam t: f's seed attempt is submitted at 10% (outside: a miss is recorded), d's at 50% (within: nothing is). The
-- statistics and the Markers tab are read at 50% (f's attempt would now be within) and again at 10% (d's would now be
-- outside).
select pg_temp.w('f:t1', 't1', 'live', 'lead', array[1, 1, 1]);
select pg_temp.standard('t1', 'seed');
select pg_temp.w('a:t1:f', 't1', 'seed', 'f', array[1, 1, 3]);
insert into res values ('fb_f', jsonb_build_object('fb', public.marking_after_submit(pg_temp.k('a:t1:f'))));
update public.exam_marking set tolerance_percent = 50 where exam_id = pg_temp.k('t');
select pg_temp.w('a:t1:d', 't1', 'seed', 'd', array[1, 1, 3]);
insert into res values ('fb_d', jsonb_build_object('fb', public.marking_after_submit(pg_temp.k('a:t1:d'))));
insert into res values ('adm:t50', pg_temp.stats('admin', pg_temp.k('t'))),
  ('tab:t50', pg_temp.as('admin', format('select public.marking_exam_markers(%L)', pg_temp.k('t')))),
  ('now:t50', jsonb_build_object('f', public.marking_standard_compare(pg_temp.k('a:t1:f')) -> 'within'));
update public.exam_marking set tolerance_percent = 10 where exam_id = pg_temp.k('t');
insert into res values ('adm:t10', pg_temp.stats('admin', pg_temp.k('t'))),
  ('tab:t10', pg_temp.as('admin', format('select public.marking_exam_markers(%L)', pg_temp.k('t')))),
  ('now:t10', jsonb_build_object('d', public.marking_standard_compare(pg_temp.k('a:t1:d')) -> 'within'));

-- Exam sb, through the real functions: a's sb2 goes into the lead's routine sample and is sent to another marker (its
-- review closes as sent_back); a's sb1 is sent back to a, with no review open, and a submits it again; b's sb3 is sent to
-- another marker with no review open; a's sb4 is not sent back; c then marks sb2 afresh.
insert into kv values ('f:sb2', tests.mark_piece(pg_temp.u('sb2'), pg_temp.uid('a'), array[1, 1, 1]));
insert into res values ('sample_a', pg_temp.as('lead', format('select public.marking_review_sample(%L, %L, 5)', pg_temp.k('sb'), pg_temp.uid('a'))));
insert into res values ('sb2_other', pg_temp.sb('lead', 'sb2', 'other'));
insert into kv values ('f:sb1', tests.mark_piece(pg_temp.u('sb1'), pg_temp.uid('a'), array[1, 1, 1]));
insert into res values ('sb1_same', pg_temp.sb('lead', 'sb1', 'same'));
insert into res values ('sb1_again', jsonb_build_object('code', pg_temp.resubmit('a', 'sb1', array[2, 1, 1])));
insert into kv values ('f:sb3', tests.mark_piece(pg_temp.u('sb3'), pg_temp.uid('b'), array[1, 1, 1]));
insert into res values ('sb3_other', pg_temp.sb('lead', 'sb3', 'other'));
insert into kv values ('f:sb4', tests.mark_piece(pg_temp.u('sb4'), pg_temp.uid('a'), array[1, 1, 1]));
insert into kv values ('g:sb2', tests.mark_piece(pg_temp.u('sb2'), pg_temp.uid('c'), array[1, 1, 1]));

-- The admin's statistics of every exam, and the lead's of q, after the lead declared a conflict for q1's candidate.
insert into res select 'adm:' || x, pg_temp.stats('admin', pg_temp.k(x)) from unnest(array['q', 'w', 's', 'v', 'n', 'p', 'sb', 'r']) x;
insert into public.marker_conflicts (marker_id, student_id, note, recorded_by, recorded_at)
select pg_temp.uid('lead'), b.student_id, 'Tutors this candidate', pg_temp.uid('admin'), now()
from public.scripts s join public.bookings b on b.id = s.booking_id where s.id = pg_temp.k('q1');
insert into res values ('lead:q', pg_temp.stats('lead', pg_temp.k('q')));

-- ---------------------------------------------------------------------------------------------
-- mean_against_the_cohort_of_the_same_groups
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.f('adm:q', 'c', 'pieces'), pg_temp.f('adm:q', 'c', 'mean_percent'), pg_temp.f('adm:q', 'c', 'cohort_mean_percent'),
                pg_temp.f('adm:q', 'c', 'difference')],
  array['4', '30', '20', '10'],
  'mean_against_the_cohort_of_the_same_groups: c marked group B only and is compared with group B''s mean (20%), not the exam''s (42%)');
select is(array[pg_temp.f('adm:q', 'a', 'mean_percent'), pg_temp.f('adm:q', 'a', 'cohort_mean_percent'), pg_temp.f('adm:q', 'a', 'difference'),
                pg_temp.f('adm:q', 'b', 'mean_percent'), pg_temp.f('adm:q', 'b', 'cohort_mean_percent'), pg_temp.f('adm:q', 'b', 'difference'),
                pg_temp.f('adm:q', 'd', 'mean_percent'), pg_temp.f('adm:q', 'd', 'cohort_mean_percent'), pg_temp.f('adm:q', 'd', 'difference')],
  array['80', '60', '20', '40', '60', '-20', '10', '20', '-10'],
  'a and b are compared with group A (60%), d with group B (20%)');
select is(array[pg_temp.f('adm:q', 'e', 'pieces'), pg_temp.f('adm:q', 'e', 'mean_percent'), pg_temp.f('adm:q', 'e', 'cohort_mean_percent'),
                pg_temp.f('adm:q', 'e', 'difference')],
  array['4', '50', '50', '0'],
  'e marked 3 pieces of group A and 1 of group B: the cohort is weighted by e''s pieces per group (50%, not 40%)');
select is(array[pg_temp.e('adm:q', 'pieces'), pg_temp.e('adm:q', 'mean_percent'), pg_temp.e('adm:q', 'median_seconds'),
                pg_temp.r('adm:q') ->> 'tolerance_percent', pg_temp.code(pg_temp.r('adm:q'))],
  array['20', '42', '60', '10', 'ok'],
  'the exam: 20 pieces, a mean of 42%, a median of 60 seconds, and the exam''s tolerance');
select is(array[pg_temp.mrk('adm:q', 'c') ->> 'cohort_has_others', pg_temp.mrk('adm:q', 'e') ->> 'cohort_has_others',
                pg_temp.mrk('adm:s', 'lead') ->> 'cohort_has_others', pg_temp.f('adm:s', 'lead', 'difference'),
                pg_temp.mrk('adm:v', 'a') ->> 'cohort_has_others', pg_temp.mrk('adm:s', 'b') ->> 'cohort_has_others'],
  array['true', 'true', 'false', '0', 'false', 'false'],
  'cohort_has_others: c and e share their groups; the lead (exam s) and a (exam v) are the only markers of their pieces, so their 0 compares with nobody; b has no piece');

-- ---------------------------------------------------------------------------------------------
-- agreement_counts_first_and_second_roles
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.f('adm:w', 'a', 'second', 'compared'), pg_temp.f('adm:w', 'a', 'second', 'within'), pg_temp.f('adm:w', 'a', 'second', 'mean_gap'),
                pg_temp.f('adm:w', 'b', 'second', 'compared'), pg_temp.f('adm:w', 'b', 'second', 'within'), pg_temp.f('adm:w', 'b', 'second', 'mean_gap'),
                pg_temp.f('adm:w', 'c', 'second', 'compared'), pg_temp.f('adm:w', 'c', 'second', 'within'), pg_temp.f('adm:w', 'c', 'second', 'mean_gap')],
  array['4', '3', '2', '5', '3', '3.6', '1', '0', '10'],
  'agreement_counts_first_and_second_roles: a (first of w1 to w3, second of w4), b (second of w1 to w3 and w5, first of w4) and c (first of w5)');
select is(array[pg_temp.f('adm:w', 'a', 'pieces'), pg_temp.f('adm:w', 'b', 'pieces'), pg_temp.f('adm:w', 'c', 'pieces'), pg_temp.e('adm:w', 'pieces')],
  array['4', '1', '1', '6'],
  'a second marking in progress (w6) or against a first marking set aside (w7) is not compared; only submitted first markings are pieces');
select is(array[pg_temp.f('adm:w', 'c', 'pieces'), pg_temp.f('adm:w', 'c', 'mean_percent'), pg_temp.f('adm:w', 'c', 'median_seconds'),
                pg_temp.f('adm:w', 'c', 'second', 'compared'), pg_temp.e('adm:w', 'mean_percent'), pg_temp.e('adm:w', 'median_seconds'),
                (select count(*)::text from jsonb_array_elements(pg_temp.r('adm:w') -> 'markers') x
                 where x ->> 'marker_id' = pg_temp.uid('mk')::text)],
  array['1', '100', '70', '1', '46.7', '60', '0'],
  're-markings count in no figure: c''s re-marking of w1 at 10 of 10 in 99,999 s changes none of c''s or the exam''s figures, and mk, who only re-marked, is not listed');

-- ---------------------------------------------------------------------------------------------
-- seed_and_practice_agreement
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.f('adm:s', 'a', 'seeds', 'done'), pg_temp.f('adm:s', 'a', 'seeds', 'within'),
                pg_temp.f('adm:s', 'a', 'practice', 'done'), pg_temp.f('adm:s', 'a', 'practice', 'within'),
                pg_temp.f('adm:s', 'b', 'seeds', 'done'), pg_temp.f('adm:s', 'b', 'seeds', 'within'),
                pg_temp.f('adm:s', 'b', 'practice', 'done'), pg_temp.f('adm:s', 'b', 'practice', 'within'),
                pg_temp.f('adm:s', 'c', 'seeds', 'done'), pg_temp.f('adm:s', 'c', 'seeds', 'within'),
                pg_temp.f('adm:s', 'c', 'practice', 'done'), pg_temp.f('adm:s', 'c', 'practice', 'within')],
  array['2', '1', '0', '0', '1', '1', '2', '1', '0', '0', '1', '0'],
  'seed_and_practice_agreement: submitted attempts against the lead''s frozen marks, within the exam''s tolerance; attempts in progress not counted');
select is(array[pg_temp.f('adm:s', 'a', 'pieces'), pg_temp.f('adm:s', 'a', 'mean_percent'), pg_temp.f('adm:s', 'a', 'median_seconds'),
                pg_temp.f('adm:s', 'lead', 'pieces'), pg_temp.e('adm:s', 'pieces')],
  array['0', 'null', 'null', '4', '4'],
  'practice and seeded attempts are not pieces and not timed: the lead''s own live markings are');
select is(array[coalesce(pg_temp.r('fb_f') ->> 'fb', 'none'), pg_temp.r('now:t50') ->> 'f', pg_temp.f('adm:t50', 'f', 'seeds', 'done'),
                pg_temp.f('adm:t50', 'f', 'seeds', 'within'), pg_temp.tab_out('tab:t50', 'f')],
  array['seed', 'true', '1', '0', '1'],
  'a seed missed at submit stays a miss when the tolerance is raised (it would now be within), as the Markers tab counts it');
select is(array[coalesce(pg_temp.r('fb_d') ->> 'fb', 'none'), pg_temp.r('now:t10') ->> 'd', pg_temp.f('adm:t10', 'd', 'seeds', 'done'),
                pg_temp.f('adm:t10', 'd', 'seeds', 'within'), pg_temp.tab_out('tab:t10', 'd'), pg_temp.r('adm:t10') ->> 'tolerance_percent'],
  array['none', 'false', '1', '1', '0', '10'],
  'a seed judged within at submit stays within when the tolerance is lowered (it would now be outside), as the Markers tab counts it');

-- ---------------------------------------------------------------------------------------------
-- speed_is_the_median_of_active_seconds
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.f('adm:w', 'a', 'median_seconds'), pg_temp.f('adm:w', 'b', 'median_seconds'), pg_temp.f('adm:w', 'c', 'median_seconds'),
                pg_temp.e('adm:w', 'median_seconds')],
  array['300', '50', '70', '60'],
  'speed_is_the_median_of_active_seconds: a''s live and second markings (100, 200, 300, 400, 1000: not the mean 400, not the set-aside 9999), c''s without its second in progress, the exam''s of 12');

-- ---------------------------------------------------------------------------------------------
-- set_aside_withdrawn_and_void_do_not_count
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.f('adm:v', 'a', 'pieces'), pg_temp.f('adm:v', 'a', 'mean_percent'), pg_temp.f('adm:v', 'a', 'median_seconds'),
                pg_temp.f('adm:v', 'a', 'second', 'compared'), pg_temp.f('adm:v', 'b', 'second', 'compared'),
                pg_temp.e('adm:v', 'pieces'), pg_temp.e('adm:v', 'mean_percent'), pg_temp.e('adm:v', 'median_seconds')],
  array['2', '45', '200', '1', '1', '2', '45', '100'],
  'set_aside_withdrawn_and_void_do_not_count: only v1 and v2 count (v3 withdrawn, v4 void, v5 set aside, v6 in progress), nor the second marking of v3');
select is((select count(*)::int from jsonb_array_elements(pg_temp.r('adm:v') -> 'markers') x where x ->> 'marker_id' = pg_temp.uid('c')::text), 0,
  'c, who only second-marked the void script, is not listed');

-- ---------------------------------------------------------------------------------------------
-- notes_need_ten_pieces
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.f('adm:n', 'f', 'pieces'), pg_temp.notes('adm:n', 'f'), pg_temp.f('adm:n', 'g', 'pieces'), pg_temp.notes('adm:n', 'g'),
                pg_temp.notes('adm:n', 'h')],
  array['9', '[]', '10', '["full_marks"]', '[]'],
  'notes_need_ten_pieces: 9 pieces at full marks give no note; 10 with 3 at full marks (30%) give full_marks; 2 of 10 give none');
select is(array[pg_temp.notes('adm:p', 'h2'), pg_temp.notes('adm:p', 'i'), pg_temp.notes('adm:p', 'j'), pg_temp.f('adm:p', 'h2', 'difference'),
                pg_temp.f('adm:p', 'i', 'difference'), pg_temp.e('adm:p', 'median_seconds'), pg_temp.r('adm:p') ->> 'tolerance_percent'],
  array['["fast", "mean_apart"]', '[]', '[]', '-26.7', '13.3', '600', '20'],
  'h2 is fast (10 s against the exam''s 600) and far from the others (26.7 points, over the 20% tolerance); i and j, 13.3 points apart, are not');
select is(array[pg_temp.e('adm:r', 'median_seconds'), pg_temp.f('adm:r', 'x1', 'median_seconds'), pg_temp.f('adm:r', 'x1', 'difference'),
                pg_temp.notes('adm:r', 'x1'), pg_temp.f('adm:r', 'x2', 'median_seconds'), pg_temp.f('adm:r', 'x2', 'difference'),
                pg_temp.notes('adm:r', 'x2'), pg_temp.notes('adm:r', 'x3'), pg_temp.r('adm:r') ->> 'tolerance_percent'],
  array['600', '199', '10', '["fast"]', '201', '-10.1', '["mean_apart"]', '[]', '10'],
  'the notes'' edges: 199 s is under a third of 600 (fast), 201 s is not; 10.0 points is at the 10% tolerance (no note), 10.1 over it (mean_apart)');

-- ---------------------------------------------------------------------------------------------
-- sent_back counts every send-back of a marker's live marking, by the record it leaves on the marking (not reviews):
-- to the same marker (submitted again since), to another, with a review open and without one.
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.code(pg_temp.r('sample_a')), pg_temp.r('sample_a') ->> 'added', pg_temp.r('sb2_other') ->> 'to',
                pg_temp.r('sb1_same') ->> 'to', pg_temp.r('sb1_again') ->> 'code', pg_temp.r('sb3_other') ->> 'to'],
  array['ok', '1', 'other', 'same', 'ok', 'other'],
  'the send-backs: sb2 from the lead''s sample to another marker, sb1 to a again with no review open (and a submits it again), sb3 to another with none');
select is(array[pg_temp.f('adm:sb', 'a', 'sent_back'), pg_temp.f('adm:sb', 'b', 'sent_back'), pg_temp.f('adm:sb', 'c', 'sent_back'),
                (select count(*)::text from public.marking_reviews r where r.exam_id = pg_temp.k('sb') and r.outcome = 'sent_back')],
  array['2', '1', '0', '1'],
  'sent_back_counts_every_send_back: a 2 (sb1 to the same marker, sb2 to another), b 1 (sb3, no review), c 0, though one review closed as sent_back');
select is(array[pg_temp.f('adm:sb', 'a', 'pieces'), pg_temp.f('adm:sb', 'b', 'pieces'), pg_temp.f('adm:sb', 'c', 'pieces')],
  array['2', '0', '1'],
  'a''s pieces are sb1 (submitted again) and sb4; b, with no piece left, is still listed for its send-back');

-- ---------------------------------------------------------------------------------------------
-- stats_hold_no_candidate_data
-- ---------------------------------------------------------------------------------------------
create temp table secrets as
select d.index_number as v from kv k join public.scripts s on s.id = k.id join public.bookings b on b.id = s.booking_id
  join public.student_details d on d.profile_id = b.student_id where d.index_number is not null
union select s.number from kv k join public.scripts s on s.id = k.id
union select s.id::text from kv k join public.scripts s on s.id = k.id
union select b.id::text from kv k join public.scripts s on s.id = k.id join public.bookings b on b.id = s.booking_id
union select b.student_id::text from kv k join public.scripts s on s.id = k.id join public.bookings b on b.id = s.booking_id
union select p.email::text from kv k join public.scripts s on s.id = k.id join public.bookings b on b.id = s.booking_id
  join public.profiles p on p.id = b.student_id
union select u.id::text from kv k join public.marking_units u on u.script_id = k.id
union select m.id::text from kv k join public.marking_units u on u.script_id = k.id join public.markings m on m.unit_id = u.id
union values ('Wilhelmina'), ('Quarterfield');
select is(array[((select count(*) from secrets) > 500)::text,
                (select count(*)::text from secrets x join res r on r.name like 'adm:%' or r.name like 'lead:%'
                 where position(lower(x.v) in lower(r.j::text)) > 0)],
  array['true', '0'],
  'stats_hold_no_candidate_data: no index number, script number, candidate name or email, nor any script, booking, student, piece or marking id');
select is(array[pg_temp.keys(pg_temp.r('adm:w')), pg_temp.keys(pg_temp.r('adm:w') -> 'exam'), pg_temp.keys(pg_temp.mrk('adm:w', 'a')),
                pg_temp.keys(pg_temp.mrk('adm:w', 'a') -> 'second'), pg_temp.keys(pg_temp.mrk('adm:w', 'a') -> 'seeds'),
                pg_temp.keys(pg_temp.mrk('adm:w', 'a') -> 'practice')],
  array['exam,markers,ok,tolerance_percent', 'mean_percent,median_seconds,pieces',
        'cohort_has_others,cohort_mean_percent,difference,marker_id,mean_percent,median_seconds,name,notes,pieces,practice,second,seeds,sent_back',
        'compared,mean_gap,within', 'done,within', 'done,within'],
  'only the figures of the brief (and cohort_has_others): per marker and per piece, nothing of a script');
select is((select count(*)::int from res r cross join jsonb_array_elements(r.j -> 'markers') x
           where (r.name like 'adm:%' or r.name like 'lead:%') and pg_temp.keys(x) <> pg_temp.keys(pg_temp.mrk('adm:w', 'a'))),
  0, 'every marker of every answer has the same keys');
select is(array[pg_temp.mrk('adm:w', 'a') ->> 'name', pg_temp.mrk('adm:w', 'b') ->> 'name',
                (select string_agg(x ->> 'marker_id', ',' order by o) from jsonb_array_elements(pg_temp.r('adm:w') -> 'markers') with ordinality t(x, o))],
  array['Aurelius Firstley', 'Bartholomew Secondo',
        (select string_agg(id::text, ',' order by n) from (values (pg_temp.uid('a'), 1), (pg_temp.uid('b'), 2), (pg_temp.uid('c'), 3)) v(id, n))],
  'markers are named, in name order (c, with no name, last)');

-- ---------------------------------------------------------------------------------------------
-- corrector_forbidden_and_lead_sees_own_subject
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.code(pg_temp.stats('corr', pg_temp.k('q'))), pg_temp.code(pg_temp.stats('a', pg_temp.k('q'))),
                pg_temp.code(pg_temp.stats('mk', pg_temp.k('q'))), pg_temp.code(pg_temp.stats('olead', pg_temp.k('q'))),
                pg_temp.code(pg_temp.r('lead:q')), pg_temp.code(pg_temp.r('adm:q'))],
  array['forbidden', 'forbidden', 'forbidden', 'forbidden', 'ok', 'ok'],
  'corrector_forbidden_and_lead_sees_own_subject: a corrector, the subject''s markers and another subject''s lead are refused; the lead and an admin are not');
select is(pg_temp.r('lead:q'), pg_temp.r('adm:q'),
  'the lead sees what an admin sees, also with a declared conflict for a candidate: every figure is an aggregate');
select is(array[pg_temp.code(pg_temp.stats('admin', gen_random_uuid())), pg_temp.code(pg_temp.stats('lead', gen_random_uuid())),
                pg_temp.code(pg_temp.stats('admin', null))],
  array['not_found', 'forbidden', 'invalid_input'], 'an unknown exam is not_found to an admin and forbidden to a lead; none is invalid_input');
select is(array[has_function_privilege('authenticated', 'public.marking_stats(uuid)', 'execute'),
                has_function_privilege('anon', 'public.marking_stats(uuid)', 'execute'),
                (select p.prosecdef and p.proconfig @> array['search_path=""'] from pg_proc p where p.oid = 'public.marking_stats(uuid)'::regprocedure)],
  array[true, false, true], 'marking_stats is for signed-in users, security definer with an empty search path');
update public.profiles set status = 'suspended' where id = pg_temp.uid('lead');
insert into res values ('lead_suspended', pg_temp.stats('lead', pg_temp.k('q')));
update public.profiles set status = 'active' where id = pg_temp.uid('lead');
insert into res values ('lead_back', pg_temp.stats('lead', pg_temp.k('q')));
update public.marker_approvals set lead = false where marker_id = pg_temp.uid('lead');
insert into res values ('lead_removed', pg_temp.stats('lead', pg_temp.k('q')));
select is(array[pg_temp.code(pg_temp.r('lead_suspended')), pg_temp.code(pg_temp.r('lead_back')), pg_temp.code(pg_temp.r('lead_removed'))],
  array['forbidden', 'ok', 'forbidden'],
  'a lead whose account is suspended, or who is no longer the subject''s lead marker, is refused');

-- ---------------------------------------------------------------------------------------------
-- stats_in_time_at_1500_pieces (a timing guard, as 057, Phase 3A Ruling R25: the fixture tables are analysed first).
-- Subject 'ZZ Stats Big' (its lead bl, markers b1 to b5): exam big is marked by question in 5 groups (one question of 5
-- marks each) and has 300 scripts. Each of the 1,500 pieces is first-marked; 10 of them are made 5 seeded and 5 practice
-- scripts, attempted by the 4 markers who did not mark them live, and every other piece is second-marked (the worst case
-- the sample allows: 1,490 comparisons); rows written directly. The lead's call runs under a 6-second limit (Ruling
-- R21): the limit a user meets is the 8-second statement timeout of a signed-in call (as Phase 3A Ruling R25), and
-- this worst case took about 3.4 s in a full run here, too close to a list's 4 s.
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
insert into c values ('bl', tests.marker(pg_temp.subj('ZZ Stats Big'), true));
insert into c select 'b' || i, tests.marker(pg_temp.subj('ZZ Stats Big')) from generate_series(1, 5) i;
insert into kv values ('big', tests.marking_exam(pg_temp.subj('ZZ Stats Big')));
insert into public.question_groups (exam_id, label, position) select pg_temp.k('big'), 'G' || i, i from generate_series(1, 5) i;
insert into public.exam_questions (exam_id, label, position, max_mark, pages, group_id)
select g.exam_id, g.position::text, g.position, 5, '{1}', g.id from public.question_groups g where g.exam_id = pg_temp.k('big');
update public.exam_marking set mode = 'by_question' where exam_id = pg_temp.k('big');
do $$ begin for i in 1..300 loop perform tests.verified_script(pg_temp.k('big'), 'home'); end loop; end $$;
select tests.open_marking(pg_temp.k('big'), '{"double_marking": true, "sample_percent": 100, "seeds": true, "practice": true}');
create temp table bigu as
select u.id, u.group_id, row_number() over (order by u.id) as n from public.marking_units u where u.exam_id = pg_temp.k('big');
insert into public.markings (unit_id, kind, marker_id, status, rev, total, active_seconds, submitted_at)
select b.id, 'live', pg_temp.uid('b' || (b.n % 5 + 1)), 'submitted', 1, b.n % 6, 60 + b.n % 240, now() from bigu b;
insert into public.markings (unit_id, kind, marker_id, status, rev, total, active_seconds, submitted_at)
select b.id, 'second', pg_temp.uid('b' || ((b.n + 1) % 5 + 1)), 'submitted', 1, (b.n + 1) % 6, 60 + b.n % 200, now() from bigu b
where b.n not in (1, 2, 3, 4, 5, 6, 7, 8, 9, 11);
insert into public.marking_standards (exam_id, unit_id, use, set_by)
select pg_temp.k('big'), b.id, case when b.n <= 5 then 'seed' else 'practice' end, pg_temp.uid('bl') from bigu b
where b.n in (1, 2, 3, 4, 5, 6, 7, 8, 9, 11);
insert into public.markings (unit_id, kind, marker_id, status, rev, total, active_seconds, submitted_at, feedback_at)
select st.unit_id, st.use::public.marking_kind, pg_temp.uid('b' || i), 'submitted', 1, i % 6, 90, now(),
  case when st.use = 'practice' then now() end
from public.marking_standards st join bigu b on b.id = st.unit_id cross join generate_series(1, 5) i
where st.exam_id = pg_temp.k('big') and i <> b.n % 5 + 1;
insert into public.question_marks (marking_id, question_id, mark)
select m.id, q.id, m.total from public.markings m join bigu b on b.id = m.unit_id join public.exam_questions q on q.group_id = b.group_id;
insert into public.marking_standard_marks (standard_id, question_id, mark)
select st.id, q.id, 3 from public.marking_standards st join bigu b on b.id = st.unit_id join public.exam_questions q on q.group_id = b.group_id;
update public.marking_units set state = 'submitted' where exam_id = pg_temp.k('big');
update public.scripts set state = 'marked' where exam_id = pg_temp.k('big');
analyze public.scripts, public.marking_units, public.markings, public.question_marks, public.marking_standards,
        public.marking_standard_marks, public.exam_questions, public.question_groups, public.exam_option_groups,
        public.exam_marking, public.exams, public.marker_approvals, public.profiles;
select tests.as_user(pg_temp.uid('bl'));
set local statement_timeout = '6s';
insert into res values ('big', pg_temp.timed('ms_big', format('select public.marking_stats(%L)', pg_temp.k('big'))));
reset statement_timeout;
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('big')), pg_temp.e('big', 'pieces'), jsonb_array_length(pg_temp.r('big') -> 'markers')::text,
                (select sum((x #>> '{second,compared}')::int)::text from jsonb_array_elements(pg_temp.r('big') -> 'markers') x),
                (select sum((x #>> '{seeds,done}')::int + (x #>> '{practice,done}')::int)::text from jsonb_array_elements(pg_temp.r('big') -> 'markers') x),
                ((pg_temp.r('ms_big') ->> 'ms')::int <= 6000)::text],
  array['ok', '1500', '5', '2980', '40', 'true'],
  'stats_in_time_at_1500_pieces: the lead''s statistics of 1,500 pieces (1,490 second-marked, 40 attempts) within 6 s, '
  || 'under the 8 s statement timeout a signed-in user meets (Ruling R21, as Phase 3A R25)');
select diag('marking_stats at 1,500 pieces: ' || (pg_temp.r('ms_big') ->> 'ms') || ' ms');

select * from finish();
rollback;
