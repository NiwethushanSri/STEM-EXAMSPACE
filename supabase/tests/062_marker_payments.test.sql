begin;
create extension if not exists pgtap with schema extensions;
select plan(41);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Subject 'ZZ Pay': markers A to E (tests.marker, named Alma Abbot to Ezra Eames) and the lead marker; an
-- admin and a teacher. Exams (each one paper, 'Paper 1'):
--   w ('ZZ Pay W'): the test structure, marked as whole scripts, double marking on (10%), seeds and practice off. Its
--      pieces (drawn 0.99, so not second-marked, unless said):
--        w1 (drawn 0.01): A's first marking and B's second; C's seeded attempt, D's practice attempt and E's re-mark
--           written directly, all submitted;
--        w2: A's marking in progress;   w3: A's, then taken back;   w4 (drawn 0.01): A's, and B's second in progress;
--        w5: A's, sent back to A and submitted again;   w6: A's, sent back to another marker, then B's;
--        w7: A's, then its script withdrawn;   w8: A's at 2027-03-31 23:30 UTC (00:30 on 1 April in the UK);
--        w9: A's at 2027-03-31 22:59:59 UTC (23:59:59 in the UK);   w10: B's at 2027-10-31 23:30 UTC (still October);
--        w11 and w12: marked after March is fixed (late_piece_is_carried_into_the_next_month).
--      Every submitted time is set in 2027 as postgres, so the months below are this file's alone.
--   r ('ZZ Pay R'): marked as whole scripts; rates only.   g ('ZZ Pay G'): marked by question, groups G1 and G2; rates only.
--   big1 to big5: the timing guard's, at the end.
-- Pieces another run left on the local stack (none on a fresh one) are fixed first, into January 2000, so the months
-- of this file hold only its own. Fixing a month passes p_now (the session is postgres, so paper_clock honours it).
-- A piece is kept as 'u:<script>'; a marking as 'f:<piece>' (live), 's:<piece>' (second) or as named.
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
-- A new verified home script of an exam and its piece, with its stored draw (0.99 unless given).
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
-- A marking's submitted time, set as postgres.
create function pg_temp.at(p_key text, p_at timestamptz) returns void language sql as $$
  update public.markings set submitted_at = p_at where id = pg_temp.k(p_key) $$;
-- Zero for each question of a piece, as marking_save takes them.
create function pg_temp.ops(p_unit uuid) returns jsonb language sql stable security definer as $$
  select jsonb_agg(jsonb_build_object('op', 'mark', 'question_id', q.question_id, 'mark', 0, 'na', false) order by q.path)
  from public.marking_unit_questions(p_unit) q where q.leaf $$;
-- The live marking of a piece by a marker (tests.mark_piece), kept as p_key ('f:<piece>' unless given), submitted at p_at.
create function pg_temp.first(p text, p_marker text, p_at timestamptz, p_key text default null) returns void language plpgsql as $$
begin
  insert into kv values (coalesce(p_key, 'f:' || p), tests.mark_piece(pg_temp.u(p), pg_temp.uid(p_marker)))
  on conflict (name) do update set id = excluded.id;
  perform pg_temp.at(coalesce(p_key, 'f:' || p), p_at);
end $$;
-- Signed in as the marker, who holds the piece: open it, save zeros and submit; submitted at p_at. The marking's id.
create function pg_temp.submit(p text, p_marker text, p_at timestamptz) returns uuid language plpgsql as $$
declare
  v_unit uuid := pg_temp.u(p);
  v_ops jsonb := pg_temp.ops(v_unit);
  v_r jsonb;
  v_mk uuid;
begin
  perform tests.as_user(pg_temp.uid(p_marker));
  v_r := public.marking_unit_open(v_unit);
  v_mk := (v_r #>> '{marking,id}')::uuid;
  v_r := public.marking_save(v_mk, (v_r #>> '{marking,rev}')::int, v_ops);
  v_r := public.marking_submit(v_mk, (v_r ->> 'rev')::int);
  perform tests.as_postgres();
  if not coalesce((v_r ->> 'ok')::boolean, false) then
    raise exception 'pg_temp.submit: the submit was refused (%)', v_r ->> 'code';
  end if;
  update public.markings set submitted_at = p_at where id = v_mk;
  return v_mk;
end $$;
-- A pass of a piece the marker takes as Next script would and opens: in progress, nothing submitted. Kept as p_key.
create function pg_temp.start(p text, p_marker text, p_kind public.marking_kind, p_key text) returns void language plpgsql as $$
declare
  v_unit uuid := pg_temp.u(p);
  v_r jsonb;
begin
  perform public.marking_unit_take(v_unit, pg_temp.uid(p_marker), 'next', null, now() + interval '2 hours', p_kind);
  perform tests.as_user(pg_temp.uid(p_marker));
  v_r := public.marking_unit_open(v_unit);
  perform tests.as_postgres();
  insert into kv values (p_key, (v_r #>> '{marking,id}')::uuid);
end $$;
-- A second marking of a piece: its second pass taken as Next script would, then marked and submitted at p_at.
create function pg_temp.second(p text, p_marker text, p_at timestamptz) returns void language plpgsql as $$
declare
  v_why text := public.marking_unit_blocked(pg_temp.u(p), pg_temp.uid(p_marker), null, true, 'second');
begin
  if v_why is not null then
    raise exception 'pg_temp.second: % cannot be given the second pass (%)', p_marker, v_why;
  end if;
  perform public.marking_unit_take(pg_temp.u(p), pg_temp.uid(p_marker), 'next', null, now() + interval '2 hours', 'second');
  insert into kv values ('s:' || p, pg_temp.submit(p, p_marker, p_at));
end $$;
-- The admin sends a piece back (same or other).
create function pg_temp.send_back(p text, p_to text) returns jsonb language sql as $$
  select pg_temp.as('admin', format($q$ select public.marking_send_back(%L, %L, 'Please look at question 2 again.', 'Marks look off.') $q$,
    pg_temp.u(p), p_to)) $$;
-- The pay functions, signed in as someone (the admin unless given).
create function pg_temp.rates(p_exam text, p_rates jsonb, p_reason text default null, p_who text default 'admin') returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.marker_rates_set(%L, %L::jsonb, %L)', pg_temp.k(p_exam), p_rates, p_reason)) $$;
create function pg_temp.rates_get(p_exam text, p_who text default 'admin') returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.marker_rates_get(%L)', pg_temp.k(p_exam))) $$;
create function pg_temp.get(p_month date, p_who text default 'admin') returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.marker_statements_get(%L)', p_month)) $$;
create function pg_temp.fix(p_month date, p_now timestamptz, p_who text default 'admin') returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.marker_statements_fix(%L, %L)', p_month, p_now)) $$;
-- A rates answer: 'mode: group pence, ...' ('-' for no group or no rate), and its fixed pieces.
create function pg_temp.rate_list(j jsonb) returns text language sql immutable as $$
  select (j ->> 'mode') || ': ' || coalesce(string_agg(coalesce(x ->> 'group_label', '-') || ' ' || coalesce(x ->> 'pence', '-'), ', ' order by o), '')
    || '; fixed ' || (j ->> 'fixed_pieces')
  from jsonb_array_elements(j -> 'rates') with ordinality t(x, o) $$;
-- What marker_payable gives before p_before of the pieces named: '<piece> <kind> <marker> <pence or ->', sorted.
create function pg_temp.paid(p_before timestamptz, p_pieces text[]) returns text language sql stable as $$
  select coalesce(string_agg(x, ', ' order by x), '')
  from (select substr(ku.name, 3) || ' ' || p.kind || ' ' || cm.name || ' ' || coalesce(p.pence::text, '-') as x
        from public.marker_payable(p_before) p
        join public.markings m on m.id = p.marking_id
        join kv ku on ku.name like 'u:%' and ku.id = m.unit_id and substr(ku.name, 3) = any (p_pieces)
        join c cm on cm.id = p.marker_id) t $$;
-- A marker's lines in a statements answer, in its order: 'exam|group|kind|pieces|rate|pence' ('-' for none).
create function pg_temp.lines(j jsonb, p_who text) returns text language sql stable as $$
  select coalesce(string_agg(concat_ws('|', l ->> 'exam_title', coalesce(l ->> 'group_label', '-'), l ->> 'kind', l ->> 'pieces',
                                       coalesce(l ->> 'rate_pence', '-'), coalesce(l ->> 'pence', '-')), '; ' order by o), '')
  from jsonb_array_elements(j -> 'markers') m cross join lateral jsonb_array_elements(m -> 'lines') with ordinality t(l, o)
  where m ->> 'marker_id' = pg_temp.uid(p_who)::text $$;
-- A marker in a statements answer: 'pieces total fixed|open', or 'none'.
create function pg_temp.who(j jsonb, p_who text) returns text language sql stable as $$
  select coalesce((select concat_ws(' ', m ->> 'pieces', coalesce(m ->> 'total_pence', '-'),
                                    case when m ->> 'fixed_at' is null then 'open' else 'fixed' end)
                   from jsonb_array_elements(j -> 'markers') m where m ->> 'marker_id' = pg_temp.uid(p_who)::text), 'none') $$;
-- The exams a statements answer (or a refused fix) says have no rate, by title.
create function pg_temp.missing(j jsonb, p_key text default 'rate_missing') returns text language sql immutable as $$
  select coalesce(string_agg(x ->> 'exam_title', ', ' order by o), '') from jsonb_array_elements(j -> p_key) with ordinality t(x, o) $$;
-- The admin's audit rows of an action (p_target: of that exam), and the latest one's reason.
create function pg_temp.audits(p_action text, p_target uuid default null) returns int language sql stable security definer as $$
  select count(*)::int from public.audit_log a
  where a.action = p_action and a.actor_id = pg_temp.uid('admin') and (p_target is null or a.target_id = p_target) $$;
create function pg_temp.reason(p_action text, p_target uuid default null) returns text language sql stable security definer as $$
  select coalesce(a.reason, 'none') from public.audit_log a
  where a.action = p_action and a.actor_id = pg_temp.uid('admin') and (p_target is null or a.target_id = p_target)
  order by a.id desc limit 1 $$;
-- A month's statements of this file's markers, as stored: 'name pieces total [the items' pence]', by name.
create function pg_temp.stored(p_month date) returns text language sql stable security definer as $$
  select coalesce(string_agg(p.first_name || ' ' || p.last_name || ' ' || s.pieces || ' ' || s.total_pence
                             || ' [' || (select string_agg(i.pence::text, ',' order by i.pence) from public.marker_statement_items i
                                         where i.statement_id = s.id) || ']', ', ' order by p.first_name), '')
  from public.marker_statements s join c cm on cm.id = s.marker_id join public.profiles p on p.id = s.marker_id
  where s.month = p_month $$;
-- The words of p_words, and the identifying values of exam w's candidates, scripts, pieces and markings, that a text holds.
create function pg_temp.leaks(p_text text) returns text[] language sql stable security definer as $$
  select array(select w from (
      select unnest(array['Wilhelmina', 'Quarterfield', 'SE-2099']) w
      union select s.number from public.scripts s where s.exam_id = pg_temp.k('w')
      union select s.id::text from public.scripts s where s.exam_id = pg_temp.k('w')
      union select s.booking_id::text from public.scripts s where s.exam_id = pg_temp.k('w')
      union select b.student_id::text from public.scripts s join public.bookings b on b.id = s.booking_id where s.exam_id = pg_temp.k('w')
      union select u.id::text from public.marking_units u where u.exam_id = pg_temp.k('w')
      union select m.id::text from public.markings m join public.marking_units u on u.id = m.unit_id where u.exam_id = pg_temp.k('w')
    ) x where position(lower(w) in lower(p_text)) > 0 order by w) $$;

-- Pieces left on the local stack by another run (none on a fresh one): fixed first, into January 2000.
with p as materialized (select * from public.marker_payable('infinity')),
s as (insert into public.marker_statements (marker_id, month, pieces, total_pence, fixed_by, fixed_at)
      select p.marker_id, date '2000-01-01', count(*), 0, p.marker_id, now() from p group by p.marker_id
      returning id, marker_id)
insert into public.marker_statement_items (marking_id, statement_id, exam_id, group_id, kind, pence, submitted_at)
select p.marking_id, s.id, p.exam_id, p.group_id, p.kind, 0, p.submitted_at from p join s on s.marker_id = p.marker_id;

insert into public.subjects (name, kind) values ('ZZ Pay', 'school');
insert into c values ('admin', tests.create_user('admin', 'active')), ('teacher', tests.create_user('teacher', 'active'));
insert into c select x, tests.marker(pg_temp.subj('ZZ Pay')) from unnest(array['A', 'B', 'C', 'D', 'E']) x;
insert into c values ('lead', tests.marker(pg_temp.subj('ZZ Pay'), true));
update public.profiles p set first_name = n.f, last_name = n.l
from (values ('A', 'Alma', 'Abbot'), ('B', 'Bede', 'Brook'), ('C', 'Cora', 'Cole'), ('D', 'Dov', 'Dunn'), ('E', 'Ezra', 'Eames')) n(k, f, l)
where p.id = pg_temp.uid(n.k);

insert into kv select x, tests.marking_exam(pg_temp.subj('ZZ Pay')) from unnest(array['w', 'r', 'g']) x;
update public.exams e set title = 'ZZ Pay ' || upper(x) from unnest(array['w', 'r', 'g']) x where e.id = pg_temp.k(x);
select tests.structure(pg_temp.k('w'));
select tests.open_marking(pg_temp.k('w'),
  '{"double_marking": true, "sample_percent": 10, "tolerance_percent": 10, "seeds": false, "practice": false}');
update public.exam_marking set mode = 'by_question' where exam_id = pg_temp.k('g');
insert into public.question_groups (exam_id, label, position) values (pg_temp.k('g'), 'G1', 1), (pg_temp.k('g'), 'G2', 2);
insert into kv select 'g:' || g.label, g.id from public.question_groups g where g.exam_id = pg_temp.k('g');

select pg_temp.script(x, 'w', 0.01) from unnest(array['w1', 'w4']) x;
select pg_temp.script(x, 'w') from unnest(array['w2', 'w3', 'w5', 'w6', 'w7', 'w8', 'w9', 'w10', 'w11', 'w12']) x;
-- w1: first and second markings; a seeded attempt, a practice attempt and a re-mark, written directly.
select pg_temp.first('w1', 'A', '2027-03-10 10:00Z');
select pg_temp.second('w1', 'B', '2027-03-10 11:00Z');
insert into public.markings (unit_id, kind, marker_id, status, rev, total, submitted_at)
values (pg_temp.u('w1'), 'seed', pg_temp.uid('C'), 'submitted', 1, 0, '2027-03-10 12:00Z'),
       (pg_temp.u('w1'), 'practice', pg_temp.uid('D'), 'submitted', 1, 0, '2027-03-10 12:00Z'),
       (pg_temp.u('w1'), 'remark', pg_temp.uid('E'), 'submitted', 1, 0, '2027-03-10 12:00Z');
-- w2 in progress; w3 taken back; w4's second marking in progress.
select pg_temp.start('w2', 'A', 'live', 'f:w2');
select pg_temp.first('w3', 'A', '2027-03-11 10:00Z');
insert into res values ('tb_w3', pg_temp.as('admin', format($q$ select public.marking_take_back(array[%L]::uuid[], 'Marked by mistake.') $q$,
  pg_temp.u('w3'))));
select pg_temp.first('w4', 'A', '2027-03-11 11:00Z');
select pg_temp.start('w4', 'B', 'second', 's:w4');
-- w5 sent back to A and submitted again; w6 sent back to another marker, then marked by B.
select pg_temp.first('w5', 'A', '2027-03-05 10:00Z');
insert into res values ('sb_w5', pg_temp.send_back('w5', 'same'));
insert into kv values ('f2:w5', pg_temp.submit('w5', 'A', '2027-03-12 10:00Z'));
select pg_temp.first('w6', 'A', '2027-03-06 10:00Z');
insert into res values ('sb_w6', pg_temp.send_back('w6', 'other'));
select pg_temp.first('w6', 'B', '2027-03-15 10:00Z', 'b:w6');
-- w7's script withdrawn after marking; w8, w9 and w10 at the month's edges.
select pg_temp.first('w7', 'A', '2027-03-16 10:00Z');
update public.scripts set state = 'withdrawn' where id = pg_temp.k('w7');
select pg_temp.first('w8', 'A', '2027-03-31 23:30Z');
select pg_temp.first('w9', 'A', '2027-03-31 22:59:59Z');
select pg_temp.first('w10', 'B', '2027-10-31 23:30Z');

-- ---------------------------------------------------------------------------------------------
-- rate_per_script_or_per_group_by_mode
-- ---------------------------------------------------------------------------------------------
select is(array[
    pg_temp.code(pg_temp.rates('r', jsonb_build_array(jsonb_build_object('group_id', pg_temp.k('g:G1'), 'pence', 100)))),
    pg_temp.code(pg_temp.rates('r', '[{"group_id": null, "pence": 100}, {"group_id": null, "pence": 200}]')),
    pg_temp.code(pg_temp.rates('r', '[{"pence": 100001}]')),
    pg_temp.code(pg_temp.rates('r', '[{"pence": -1}]')),
    pg_temp.code(pg_temp.rates('r', '[{"pence": 12.5}]')),
    pg_temp.code(pg_temp.rates('r', '[{"pence": "100"}]')),
    pg_temp.code(pg_temp.rates('r', '[]')),
    pg_temp.code(pg_temp.rates('r', '{"pence": 100}')),
    pg_temp.code(pg_temp.rates('r', '[{"pence": 100}]', 'no')),
    pg_temp.code(pg_temp.rates('r', null))],
  array['invalid_input', 'invalid_input', 'invalid_input', 'invalid_input', 'invalid_input', 'invalid_input', 'invalid_input',
        'invalid_input', 'invalid_input', 'invalid_input'],
  'rate_per_script_or_per_group_by_mode: a whole-script exam takes one rate with no group; a group rate, two rates, a rate '
  || 'outside 0 to 100,000 pence or not a whole number, an empty list or no list, or a reason given of 2 characters is invalid_input');
select is(array[
    pg_temp.code(pg_temp.rates('g', jsonb_build_array(jsonb_build_object('group_id', pg_temp.k('g:G1'), 'pence', 300)))),
    pg_temp.code(pg_temp.rates('g', jsonb_build_array(jsonb_build_object('group_id', pg_temp.k('g:G1'), 'pence', 300),
      jsonb_build_object('group_id', pg_temp.k('g:G2'), 'pence', 500), jsonb_build_object('group_id', null, 'pence', 100)))),
    pg_temp.code(pg_temp.rates('g', jsonb_build_array(jsonb_build_object('group_id', pg_temp.k('g:G1'), 'pence', 300),
      jsonb_build_object('group_id', pg_temp.k('g:G1'), 'pence', 500)))),
    pg_temp.code(pg_temp.rates('g', jsonb_build_array(jsonb_build_object('group_id', pg_temp.k('g:G1'), 'pence', 300),
      jsonb_build_object('group_id', 'not-a-group', 'pence', 500)))),
    pg_temp.code(pg_temp.rates('g', jsonb_build_array(jsonb_build_object('group_id', pg_temp.k('g:G1'), 'pence', 300),
      jsonb_build_object('group_id', gen_random_uuid(), 'pence', 500)))),
    (select count(*)::text from public.marker_rates where exam_id in (pg_temp.k('r'), pg_temp.k('g')))],
  array['invalid_input', 'invalid_input', 'invalid_input', 'invalid_input', 'invalid_input', '0'],
  'an exam marked by question takes exactly one rate per question group: a group missing, a rate with no group, a group '
  || 'twice, a group that is not a uuid or not the exam''s is invalid_input; nothing was written');
insert into res values ('g_set', pg_temp.rates('g', jsonb_build_array(jsonb_build_object('group_id', pg_temp.k('g:G2'), 'pence', 500),
  jsonb_build_object('group_id', pg_temp.k('g:G1'), 'pence', 300))));
insert into res values ('g_get', pg_temp.rates_get('g'));
insert into res values ('r_get0', pg_temp.rates_get('r'));
select is(array[pg_temp.code(pg_temp.r('g_set')), pg_temp.r('g_set') ->> 'changed', pg_temp.rate_list(pg_temp.r('g_get')),
    pg_temp.rate_list(pg_temp.r('r_get0')), pg_temp.reason('marker_rate_set', pg_temp.k('g'))],
  array['ok', 'true', 'by_question: G1 300, G2 500; fixed 0', 'whole: - -; fixed 0',
        'group G1: none -> 300 pence; group G2: none -> 500 pence'],
  'one rate per group is saved and read back in the groups'' order; a whole-script exam with no rate reads one empty rate');
delete from public.question_groups where id = pg_temp.k('g:G2');
select is(pg_temp.rate_list(pg_temp.rates_get('g')), 'by_question: G1 300; fixed 0',
  'a question group removed before marking opens (as exam_structure_save does) takes its rate with it');
select is(array[pg_temp.code(pg_temp.rates_get('r', 'admin')),
    pg_temp.code(pg_temp.as('admin', format('select public.marker_rates_get(%L)', gen_random_uuid()))),
    pg_temp.code(pg_temp.as('admin', format($q$ select public.marker_rates_set(%L, '[{"pence": 100}]'::jsonb) $q$, gen_random_uuid()))),
    pg_temp.code(pg_temp.as('admin', 'select public.marker_rates_get(null)'))],
  array['ok', 'not_found', 'not_found', 'invalid_input'], 'an exam that does not exist is not_found; no exam is invalid_input');

-- ---------------------------------------------------------------------------------------------
-- rate_set_by_admins_only_with_audit
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.code(pg_temp.rates('r', '[{"group_id": null, "pence": 1250}]', null, 'A')),
    pg_temp.code(pg_temp.rates('r', '[{"group_id": null, "pence": 1250}]', null, 'lead')),
    pg_temp.code(pg_temp.rates('r', '[{"group_id": null, "pence": 1250}]', null, 'teacher')),
    (select count(*)::text from public.marker_rates where exam_id = pg_temp.k('r')),
    (select count(*)::text from public.audit_log where action = 'marker_rate_set' and target_id = pg_temp.k('r'))],
  array['forbidden', 'forbidden', 'forbidden', '0', '0'],
  'rate_set_by_admins_only_with_audit: a marker, the lead marker and a teacher are refused, and nothing is written');
insert into res values ('r_set', pg_temp.rates('r', '[{"group_id": null, "pence": 1250}]'));
insert into res values ('r_same', pg_temp.rates('r', '[{"pence": 1250}]'));
select is(array[pg_temp.code(pg_temp.r('r_set')), pg_temp.r('r_set') ->> 'changed', pg_temp.code(pg_temp.r('r_same')),
    pg_temp.r('r_same') ->> 'changed', pg_temp.audits('marker_rate_set', pg_temp.k('r'))::text,
    pg_temp.reason('marker_rate_set', pg_temp.k('r')), pg_temp.rate_list(pg_temp.rates_get('r')),
    (select (r.set_by = pg_temp.uid('admin'))::text from public.marker_rates r where r.exam_id = pg_temp.k('r'))],
  array['ok', 'true', 'ok', 'false', '1', 'per script: none -> 1250 pence', 'whole: - 1250; fixed 0', 'true'],
  'an admin sets the rate per script, audited marker_rate_set with what changed and who set it; the same rates again change '
  || 'nothing and write no audit row');

-- ---------------------------------------------------------------------------------------------
-- first_and_second_markings_count_practice_and_seeds_never
-- ---------------------------------------------------------------------------------------------
select is(pg_temp.paid(timestamptz '2027-04-01 00:00 Europe/London', array['w1']), 'w1 live A -, w1 remark E -, w1 second B -',
  'first_and_second_markings_count_practice_and_seeds_never: the first, second and re-marking of a piece are payable, at '
  || 'no rate yet; the seeded and practice attempts are not');
select is((select string_agg(m.kind || ' ' || m.status, ', ' order by m.kind) from public.markings m where m.unit_id = pg_temp.u('w1')),
  'live submitted, second submitted, seed submitted, practice submitted, remark submitted',
  'all five markings of the piece are submitted');

-- ---------------------------------------------------------------------------------------------
-- in_progress_and_set_aside_markings_are_not_paid
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.paid('infinity', array['w2', 'w3', 'w4']),
    (select m.status from public.markings m where m.id = pg_temp.k('f:w2')),
    (select m.status || ' ' || m.set_aside_reason from public.markings m where m.id = pg_temp.k('f:w3')),
    (select m.kind || ' ' || m.status from public.markings m where m.id = pg_temp.k('s:w4'))],
  array['w4 live A -', 'in_progress', 'set_aside taken_back', 'second in_progress'],
  'in_progress_and_set_aside_markings_are_not_paid: a marking in progress, a second marking in progress and a marking '
  || 'taken back are not payable');

-- ---------------------------------------------------------------------------------------------
-- piece_sent_back_to_the_same_marker_is_paid_once
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.r('sb_w5') ->> 'to', pg_temp.paid('infinity', array['w5']), (pg_temp.k('f2:w5') = pg_temp.k('f:w5'))::text,
    (select count(*)::text from public.markings m where m.unit_id = pg_temp.u('w5'))],
  array['same', 'w5 live A -', 'true', '1'],
  'piece_sent_back_to_the_same_marker_is_paid_once: submitted again, it is the same marking and one payable piece');

-- ---------------------------------------------------------------------------------------------
-- piece_remarked_by_another_pays_the_remarker_only
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.r('sb_w6') ->> 'to', pg_temp.paid('infinity', array['w6']),
    (select m.status || ' ' || m.set_aside_reason from public.markings m where m.id = pg_temp.k('f:w6'))],
  array['other', 'w6 live B -', 'set_aside sent_back'],
  'piece_remarked_by_another_pays_the_remarker_only: the first marking, set aside, is not paid; the other marker''s is');

-- ---------------------------------------------------------------------------------------------
-- marking_on_a_later_withdrawn_script_is_still_paid
-- ---------------------------------------------------------------------------------------------
select is(array[(select s.state::text from public.scripts s where s.id = pg_temp.k('w7')), pg_temp.paid('infinity', array['w7'])],
  array['withdrawn', 'w7 live A -'],
  'marking_on_a_later_withdrawn_script_is_still_paid: the script is withdrawn and its submitted marking stands');

-- ---------------------------------------------------------------------------------------------
-- month_is_the_uk_calendar_month (Review Focus 5)
-- ---------------------------------------------------------------------------------------------
select is(array[public.marker_statement_month('2027-03-31 23:30Z'), public.marker_statement_month('2027-03-31 22:59:59Z'),
    public.marker_statement_month('2027-10-31 23:30Z'), public.marker_statement_month('2027-10-31 00:30Z'),
    public.marker_statement_month('2027-01-01 00:00Z')],
  array[date '2027-04-01', date '2027-03-01', date '2027-10-01', date '2027-10-01', date '2027-01-01'],
  'month_is_the_uk_calendar_month: 2027-03-31 23:30 UTC is 1 April 00:30 in the UK (April), 22:59:59 is still March; '
  || '2027-10-31 23:30 UTC is October (the clocks went back that morning); midnight on 1 January is January');
insert into res values ('m0', pg_temp.get('2027-03-01')), ('a0', pg_temp.get('2027-04-01'));
select is(array[pg_temp.paid(timestamptz '2027-04-01 00:00 Europe/London', array['w8', 'w9']),
    pg_temp.paid(timestamptz '2027-05-01 00:00 Europe/London', array['w8', 'w9']),
    pg_temp.paid(timestamptz '2027-10-01 00:00 Europe/London', array['w10']),
    pg_temp.paid(timestamptz '2027-11-01 00:00 Europe/London', array['w10']),
    pg_temp.who(pg_temp.r('m0'), 'A'), pg_temp.who(pg_temp.r('a0'), 'A')],
  array['w9 live A -', 'w8 live A -, w9 live A -', '', 'w10 live B -', '5 - open', '6 - open'],
  'a piece belongs to the UK month of its submission: w8 is April''s, not March''s; w10 is October''s, not September''s; '
  || 'March''s statement for A has 5 pieces and April''s (not fixed, so March''s carried in) 6');

-- ---------------------------------------------------------------------------------------------
-- fix_needs_the_month_ended_and_every_rate
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.code(pg_temp.r('m0')), pg_temp.r('m0') ->> 'month', pg_temp.r('m0') ->> 'fixed', pg_temp.missing(pg_temp.r('m0')),
    pg_temp.lines(pg_temp.r('m0'), 'A'), pg_temp.lines(pg_temp.r('m0'), 'B'), pg_temp.lines(pg_temp.r('m0'), 'E'),
    pg_temp.who(pg_temp.r('m0'), 'C'), pg_temp.who(pg_temp.r('m0'), 'D'),
    (select m ->> 'name' from jsonb_array_elements(pg_temp.r('m0') -> 'markers') m where m ->> 'marker_id' = pg_temp.uid('A')::text)],
  array['ok', '2027-03-01', 'false', 'ZZ Pay W', 'ZZ Pay W|-|live|5|-|-', 'ZZ Pay W|-|live|1|-|-; ZZ Pay W|-|second|1|-|-',
        'ZZ Pay W|-|remark|1|-|-', 'none', 'none', 'Alma Abbot'],
  'fix_needs_the_month_ended_and_every_rate: before the fix March shows each marker''s lines by exam and kind, the exam '
  || 'without a rate, and no line for seeded or practice attempts');
select is(array[pg_temp.code(pg_temp.fix('2027-03-01', '2027-03-31 22:59:59Z')),
    pg_temp.code(pg_temp.fix('2027-03-01', '2027-03-31 23:00Z')),
    pg_temp.missing(pg_temp.fix('2027-03-01', '2027-03-31 23:00Z'), 'exams'),
    pg_temp.code(pg_temp.fix('2027-03-01', '2027-04-02 12:00Z', 'A')),
    pg_temp.code(pg_temp.fix('2027-03-01', '2027-04-02 12:00Z', 'lead')),
    pg_temp.code(pg_temp.fix('2027-03-15', '2027-04-02 12:00Z')),
    pg_temp.code(pg_temp.as('admin', 'select public.marker_statements_fix(null)')),
    (select count(*)::text from public.marker_statements where month = '2027-03-01'),
    pg_temp.audits('marker_statements_fixed')::text],
  array['too_early', 'rate_missing', 'ZZ Pay W', 'forbidden', 'forbidden', 'invalid_input', 'invalid_input', '0', '0'],
  'at 23:59:59 on 31 March in the UK the month has not ended (too_early); at midnight it has, but exam w has no rate '
  || '(rate_missing names it); a marker and the lead are refused; a day that is not the first is invalid_input; nothing is fixed');
select set_config('request.method', 'POST', true);
insert into res values ('api_fix', pg_temp.fix('2099-01-01', '2099-02-02 12:00Z'));
select set_config('request.method', '', true);
select is(pg_temp.code(pg_temp.r('api_fix')), 'too_early',
  'p_now is ignored for a call through the API (as paper_clock): January 2099 has not ended by the server''s time');
select is(pg_temp.as('admin', 'select public.marker_statements_get(''2001-01-01'')') ->> 'ended'
          || ' ' || (pg_temp.as('admin', 'select public.marker_statements_get(''2099-01-01'')') ->> 'ended'),
  'true false', 'ended reads the server''s time: January 2001 has ended and January 2099 has not');
insert into res values ('w_set', pg_temp.rates('w', '[{"group_id": null, "pence": 1000}]'));
insert into res values ('fix_m', pg_temp.fix('2027-03-01', '2027-04-02 12:00Z'));
select is(array[pg_temp.code(pg_temp.r('w_set')), pg_temp.code(pg_temp.r('fix_m')), pg_temp.r('fix_m') ->> 'statements',
    pg_temp.r('fix_m') ->> 'pieces', pg_temp.r('fix_m') ->> 'total_pence', pg_temp.stored('2027-03-01'),
    pg_temp.audits('marker_statements_fixed')::text, pg_temp.reason('marker_statements_fixed')],
  array['ok', 'ok', '3', '8', '8000',
        'Alma Abbot 5 5000 [1000,1000,1000,1000,1000], Bede Brook 2 2000 [1000,1000], Ezra Eames 1 1000 [1000]',
        '1', 'month 2027-03: 3 statements, 8 pieces, 8000 pence'],
  'with the rate set, the fix makes one statement per marker with payable pieces (A 5, B 2, E 1 at 1,000 pence), audited');
select is((select count(*)::int from pg_locks l
           cross join (values (hashtextextended('marker_statements:2027-03', 0), 'ExclusiveLock'),
                              (hashtextextended('marker_pay', 0), 'ExclusiveLock'),
                              (hashtextextended('marker_pay', 0), 'ShareLock')) x(key, mode)
           where l.locktype = 'advisory' and l.pid = pg_backend_pid() and l.granted and l.mode = x.mode and l.objsubid = 1
             and l.classid::bigint = (x.key >> 32) & 4294967295 and l.objid::bigint = x.key & 4294967295),
  3, 'the fix held the month''s advisory lock and the pay lock (exclusive), and a rate change the pay lock shared, till the end');
insert into res values ('m1', pg_temp.get('2027-03-01'));
select is(array[pg_temp.r('m1') ->> 'fixed', pg_temp.missing(pg_temp.r('m1')), pg_temp.who(pg_temp.r('m1'), 'A'),
    pg_temp.lines(pg_temp.r('m1'), 'A'), pg_temp.lines(pg_temp.r('m1'), 'B'), pg_temp.who(pg_temp.r('m1'), 'E'),
    (select count(*)::text from jsonb_array_elements(pg_temp.r('m1') -> 'markers') m where m ->> 'fixed_at' is null)],
  array['true', '', '5 5000 fixed', 'ZZ Pay W|-|live|5|1000|5000', 'ZZ Pay W|-|live|1|1000|1000; ZZ Pay W|-|second|1|1000|1000',
        '1 1000 fixed', '0'],
  'March now reads as fixed, from the statements'' items');

-- ---------------------------------------------------------------------------------------------
-- fixed_statement_does_not_change (Review Focus 5)
-- ---------------------------------------------------------------------------------------------
insert into res values ('tb_w9', pg_temp.as('admin', format($q$ select public.marking_take_back(array[%L]::uuid[], 'Marked by mistake.') $q$,
  pg_temp.u('w9'))));
insert into res values ('w_double', pg_temp.rates('w', '[{"group_id": null, "pence": 2000}]'));
insert into res values ('w_double2', pg_temp.rates('w', '[{"group_id": null, "pence": 2000}]', 'The rate went up in April.'));
insert into res values ('m2', pg_temp.get('2027-03-01'));
select is(array[(pg_temp.r('tb_w9') ->> 'taken_back'), pg_temp.code(pg_temp.r('w_double')), pg_temp.code(pg_temp.r('w_double2')),
    pg_temp.reason('marker_rate_set', pg_temp.k('w')), pg_temp.rate_list(pg_temp.rates_get('w')),
    ((pg_temp.r('m2') -> 'markers') = (pg_temp.r('m1') -> 'markers'))::text, pg_temp.stored('2027-03-01')],
  array['1', 'reason_required', 'ok', 'per script: 1000 -> 2000 pence; reason: The rate went up in April.', 'whole: - 2000; fixed 8',
        'true', 'Alma Abbot 5 5000 [1000,1000,1000,1000,1000], Bede Brook 2 2000 [1000,1000], Ezra Eames 1 1000 [1000]'],
  'fixed_statement_does_not_change: after the fix one of A''s pieces is taken back and the rate doubled (a reason is needed '
  || 'once pieces are fixed): March''s lines, totals and items are as they were');
select throws_ok($$update public.marker_statements set total_pence = 0$$, 'P0001', 'Fixed marker statements and their items never change.',
  'an update of a statement is refused, even as postgres');
select throws_ok($$delete from public.marker_statement_items$$, 'P0001', 'Fixed marker statements and their items never change.',
  'so is a delete of its items');
select throws_ok($$truncate public.marker_statements cascade$$, 'P0001', 'Fixed marker statements and their items never change.',
  'and a truncate');

-- ---------------------------------------------------------------------------------------------
-- no_marking_is_ever_in_two_statements (Review Focus 5)
-- ---------------------------------------------------------------------------------------------
insert into res values ('sb2_w5', pg_temp.send_back('w5', 'same'));
insert into kv values ('f3:w5', pg_temp.submit('w5', 'A', '2027-04-10 10:00Z'));
insert into res values ('a1', pg_temp.get('2027-04-01'));
select is(array[pg_temp.r('sb2_w5') ->> 'to', (pg_temp.k('f3:w5') = pg_temp.k('f:w5'))::text,
    (select m.status || ' ' || m.submitted_at::date from public.markings m where m.id = pg_temp.k('f:w5')),
    pg_temp.paid('infinity', array['w5']), pg_temp.lines(pg_temp.r('a1'), 'A')],
  array['same', 'true', 'submitted 2027-04-10', '', 'ZZ Pay W|-|live|1|2000|2000'],
  'no_marking_is_ever_in_two_statements: a piece fixed in March, sent back to the same marker and submitted again in April, '
  || 'is not payable again: April shows only w8 for A');
select throws_ok(format($q$insert into public.marker_statement_items (marking_id, statement_id, exam_id, kind, pence, submitted_at)
                          select %L, s.id, %L, 'live', 2000, '2027-04-10 10:00Z' from public.marker_statements s
                          where s.marker_id = %L and s.month = '2027-03-01'$q$,
    pg_temp.k('f:w5'), pg_temp.k('w'), pg_temp.uid('B')),
  '23505', 'duplicate key value violates unique constraint "marker_statement_items_pkey"',
  'the primary key refuses a second item for the marking');
select throws_ok(format($q$insert into public.marker_statements (marker_id, month, pieces, total_pence, fixed_by, fixed_at)
                          values (%L, '2027-03-01', 1, 2000, %L, now())$q$, pg_temp.uid('A'), pg_temp.uid('admin')),
  '23505', 'duplicate key value violates unique constraint "marker_statements_marker_id_month_key"',
  'and a marker has one statement a month');

-- ---------------------------------------------------------------------------------------------
-- late_piece_is_carried_into_the_next_month
-- ---------------------------------------------------------------------------------------------
-- As if their submits had committed after March was fixed: A's w11 and C's w12, submitted in March.
select pg_temp.first('w11', 'A', '2027-03-20 10:00Z');
select pg_temp.first('w12', 'C', '2027-03-25 10:00Z');
insert into res values ('m3', pg_temp.get('2027-03-01')), ('a2', pg_temp.get('2027-04-01'));
select is(array[pg_temp.who(pg_temp.r('m3'), 'A'), pg_temp.lines(pg_temp.r('m3'), 'A'), pg_temp.who(pg_temp.r('m3'), 'C'),
    pg_temp.r('m3') ->> 'fixed', pg_temp.who(pg_temp.r('a2'), 'A'), pg_temp.lines(pg_temp.r('a2'), 'A'), pg_temp.who(pg_temp.r('a2'), 'C')],
  array['5 5000 fixed', 'ZZ Pay W|-|live|5|1000|5000', '1 2000 open', 'false', '2 4000 open', 'ZZ Pay W|-|live|2|2000|4000',
        '1 2000 open'],
  'late_piece_is_carried_into_the_next_month: A''s fixed March is as it was and A''s late piece shows in April; C, with no '
  || 'March statement, shows in March (not fixed yet) and, carried, in April');
insert into res values ('fix_m2', pg_temp.fix('2027-03-01', '2027-04-02 12:00Z'));
insert into res values ('fix_a', pg_temp.fix('2027-04-01', '2027-05-01 12:00Z'));
select is(array[pg_temp.r('fix_m2') ->> 'statements', pg_temp.r('fix_m2') ->> 'pieces', pg_temp.r('fix_m2') ->> 'total_pence',
    pg_temp.stored('2027-03-01'), pg_temp.r('fix_a') ->> 'statements', pg_temp.r('fix_a') ->> 'pieces',
    pg_temp.r('fix_a') ->> 'total_pence', pg_temp.stored('2027-04-01')],
  array['1', '1', '2000',
        'Alma Abbot 5 5000 [1000,1000,1000,1000,1000], Bede Brook 2 2000 [1000,1000], Cora Cole 1 2000 [2000], Ezra Eames 1 1000 [1000]',
        '1', '2', '4000', 'Alma Abbot 2 4000 [2000,2000]'],
  'fixing March again makes C''s statement and leaves the markers fixed already alone; April''s takes A''s w8 and the late w11 '
  || 'at the new rate');

-- ---------------------------------------------------------------------------------------------
-- fix_twice_adds_nothing
-- ---------------------------------------------------------------------------------------------
insert into res values ('fix_a2', pg_temp.fix('2027-04-01', '2027-05-01 12:00Z')), ('fix_m3', pg_temp.fix('2027-03-01', '2027-05-01 12:00Z'));
insert into res values ('a3', pg_temp.get('2027-04-01'));
select is(array[pg_temp.code(pg_temp.r('fix_a2')), pg_temp.r('fix_a2') ->> 'statements', pg_temp.r('fix_a2') ->> 'pieces',
    pg_temp.r('fix_a2') ->> 'total_pence', pg_temp.code(pg_temp.r('fix_m3')), pg_temp.r('fix_m3') ->> 'statements',
    (select count(*)::text from public.marker_statements where month in ('2027-03-01', '2027-04-01')),
    (select count(*)::text from public.marker_statement_items i join public.marker_statements s on s.id = i.statement_id
     where s.month in ('2027-03-01', '2027-04-01')),
    pg_temp.audits('marker_statements_fixed')::text, pg_temp.r('a3') ->> 'fixed', pg_temp.who(pg_temp.r('a3'), 'A')],
  array['ok', '0', '0', '0', 'ok', '0', '5', '11', '3', 'true', '2 4000 fixed'],
  'fix_twice_adds_nothing: April and March fixed again add no statement and no item and write no audit row');

-- ---------------------------------------------------------------------------------------------
-- statement_holds_no_candidate_data
-- ---------------------------------------------------------------------------------------------
select is(array[
    (select string_agg(a.attname, ',' order by a.attnum) from pg_attribute a
     where a.attrelid = 'public.marker_statement_items'::regclass and a.attnum > 0 and not a.attisdropped),
    (select string_agg(a.attname, ',' order by a.attnum) from pg_attribute a
     where a.attrelid = 'public.marker_statements'::regclass and a.attnum > 0 and not a.attisdropped)],
  array['marking_id,statement_id,exam_id,group_id,kind,pence,submitted_at', 'id,marker_id,month,pieces,total_pence,fixed_by,fixed_at'],
  'statement_holds_no_candidate_data: a statement keeps its marker, month and money; an item its marking, exam, group, kind, '
  || 'pence and time');
select is(pg_temp.leaks(concat_ws(' ', pg_temp.r('m0'), pg_temp.r('a0'), pg_temp.r('m1'), pg_temp.r('m3'), pg_temp.r('a2'),
    pg_temp.r('a3'), pg_temp.r('fix_m'), pg_temp.r('fix_a'), pg_temp.r('g_get'), pg_temp.rates_get('w'),
    pg_temp.fix('2027-10-01', '2027-11-02 12:00Z'))),
  '{}'::text[], 'no statement or rates answer names a candidate or holds a script number, index number or any id of a script, '
  || 'booking, student, piece or marking');

-- ---------------------------------------------------------------------------------------------
-- markers_and_leads_read_no_rates_or_statements
-- ---------------------------------------------------------------------------------------------
create function pg_temp.reads(p_who text) returns text language plpgsql as $$
declare
  v text;
begin
  perform tests.as_user(pg_temp.uid(p_who));
  select (select count(*) from public.marker_rates) || ' ' || (select count(*) from public.marker_statements) || ' '
    || (select count(*) from public.marker_statement_items) into v;
  perform tests.as_postgres();
  return v;
end $$;
select is(array[pg_temp.reads('A'), pg_temp.reads('lead'), pg_temp.reads('teacher'), pg_temp.reads('admin')],
  array['0 0 0', '0 0 0', '0 0 0', (select count(*) from public.marker_rates) || ' ' || (select count(*) from public.marker_statements)
        || ' ' || (select count(*) from public.marker_statement_items)],
  'markers_and_leads_read_no_rates_or_statements: a marker, the lead marker and a teacher read no row of the three tables; '
  || 'an admin reads them all');
select is(array[pg_temp.code(pg_temp.rates_get('w', 'A')), pg_temp.code(pg_temp.rates_get('w', 'lead')),
    pg_temp.code(pg_temp.rates('w', '[{"pence": 1}]', null, 'lead')), pg_temp.code(pg_temp.get('2027-03-01', 'A')),
    pg_temp.code(pg_temp.get('2027-03-01', 'lead')), pg_temp.code(pg_temp.get('2027-03-01', 'teacher')),
    pg_temp.code(pg_temp.as('lead', $$select public.marker_statement_exported('2027-03-01')$$))],
  array['forbidden', 'forbidden', 'forbidden', 'forbidden', 'forbidden', 'forbidden', 'forbidden'],
  'and every pay function refuses them');
select is((select array_agg(f order by f) from unnest(array['public.marker_payable(timestamptz)', 'public.marker_statement_month(timestamptz)',
    'public.marker_statements_frozen()']) f
  where has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute')
     or has_function_privilege('service_role', f, 'execute') or has_function_privilege('public', f, 'execute')),
  null, 'the internal functions are revoked from every client role');
select is((select array_agg(f order by f) from unnest(array['public.marker_rates_get(uuid)', 'public.marker_rates_set(uuid,jsonb,text)',
    'public.marker_statements_get(date)', 'public.marker_statements_fix(date,timestamptz)', 'public.marker_statement_exported(date)']) f
  where not has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute')),
  null, 'the others are for signed-in users only');
select is(array[
    (select count(*)::text from pg_proc p where p.pronamespace = 'public'::regnamespace
     and p.proname in ('marker_payable', 'marker_rates_get', 'marker_rates_set', 'marker_statements_get', 'marker_statements_fix',
                       'marker_statement_exported')
     and p.prosecdef and p.proconfig @> array['search_path=""']),
    (select count(*)::text from pg_proc p where p.pronamespace = 'public'::regnamespace
     and p.proname in ('marker_statement_month', 'marker_statements_frozen') and p.proconfig @> array['search_path=""']),
    (select string_agg(c.relname || ' ' || c.relrowsecurity, ', ' order by c.relname) from pg_class c
     where c.oid in ('public.marker_rates'::regclass, 'public.marker_statements'::regclass, 'public.marker_statement_items'::regclass)),
    (select count(*)::text from unnest(array['public.marker_rates', 'public.marker_statements', 'public.marker_statement_items']) t
     cross join unnest(array['insert', 'update', 'delete']) p
     where has_table_privilege('authenticated', t, p) or has_table_privilege('anon', t, p) or has_table_privilege('anon', t, 'select'))],
  array['6', '2', 'marker_rates true, marker_statement_items true, marker_statements true', '0'],
  'each reading function is security definer with an empty search path; the tables have row-level security and give '
  || 'signed-in users select only, under the admins'' policy');

-- ---------------------------------------------------------------------------------------------
-- export_is_recorded
-- ---------------------------------------------------------------------------------------------
insert into res values ('ex', pg_temp.as('admin', $$select public.marker_statement_exported('2027-03-01')$$));
insert into res values ('ex_a', pg_temp.as('A', $$select public.marker_statement_exported('2027-03-01')$$));
insert into res values ('ex_bad', pg_temp.as('admin', $$select public.marker_statement_exported('2027-03-02')$$));
select is(array[pg_temp.code(pg_temp.r('ex')), pg_temp.code(pg_temp.r('ex_a')), pg_temp.code(pg_temp.r('ex_bad')),
    pg_temp.audits('marker_statement_exported')::text, pg_temp.reason('marker_statement_exported'),
    (select count(*)::text from public.audit_log a where a.action = 'marker_statement_exported' and a.actor_id = pg_temp.uid('A'))],
  array['ok', 'forbidden', 'invalid_input', '1', 'month 2027-03: 4 fixed statements', '0'],
  'export_is_recorded: an admin''s download is audited marker_statement_exported with the month; a marker is refused and '
  || 'nothing is recorded');

-- ---------------------------------------------------------------------------------------------
-- marker_statements_in_time_at_3000_pieces (a timing guard; as 060 and 061, the fixture tables are analysed first).
-- Subject 'ZZ Pay Big': 30 markers; exams big1 to big5, marked by question (groups Q1 to Q5, rates 100 to 500 pence),
-- 60 scripts each. Every piece has a submitted first and second marking in June 2027: 3,000 payable markings, 100 per
-- marker, written directly. As an admin, June's statements before the fix, the fix, and the statements after it must
-- each answer within 6 s: the limit a user meets is the 8-second statement timeout of a signed-in call (Ruling R21).
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
grant execute on function pg_temp.timed(text, text) to public;
insert into public.subjects (name, kind) values ('ZZ Pay Big', 'school');
insert into c select 'v' || i, tests.marker(pg_temp.subj('ZZ Pay Big')) from generate_series(1, 30) i;
create temp table bigm (n int primary key, id uuid not null);
insert into bigm select i - 1, pg_temp.uid('v' || i) from generate_series(1, 30) i;
insert into kv select 'big' || i, tests.marking_exam(pg_temp.subj('ZZ Pay Big')) from generate_series(1, 5) i;
update public.exam_marking set mode = 'by_question', opened_at = now() where exam_id in (select id from kv where name like 'big_');
insert into public.question_groups (exam_id, label, position)
select k.id, 'Q' || g, g from kv k cross join generate_series(1, 5) g where k.name like 'big_';
insert into public.marker_rates (exam_id, group_id, pence, set_by, set_at)
select g.exam_id, g.id, 100 * g.position, pg_temp.uid('admin'), now()
from public.question_groups g where g.exam_id in (select id from kv where name like 'big_');
create temp table bigs (id uuid primary key, n int not null);
insert into bigs select tests.verified_script(x.id, 'home'), x.n
from (select k.id, row_number() over (order by k.name, i) as n from kv k cross join generate_series(1, 60) i where k.name like 'big_') x;
insert into public.marking_units (script_id, exam_id, group_id, state, check_state, checked_at)
select s.id, s.exam_id, g.id, 'submitted', 'checked', now()
from bigs b join public.scripts s on s.id = b.id join public.question_groups g on g.exam_id = s.exam_id;
insert into public.markings (unit_id, kind, marker_id, status, rev, total, submitted_at)
select u.id, k.kind::public.marking_kind, m.id, 'submitted', 1, 1, timestamptz '2027-06-15 12:00Z'
from public.marking_units u join bigs b on b.id = u.script_id join public.question_groups g on g.id = u.group_id
cross join (values ('live', 0), ('second', 7)) k(kind, shift)
join bigm m on m.n = (b.n * 5 + g.position + k.shift) % 30;
analyze public.markings, public.marking_units, public.marker_rates, public.marker_statements, public.marker_statement_items,
        public.exams, public.question_groups, public.profiles, public.scripts;
select tests.as_user(pg_temp.uid('admin'));
set local statement_timeout = '6s';
insert into res values ('big_get', pg_temp.timed('ms_get', $$select public.marker_statements_get('2027-06-01')$$));
insert into res values ('big_fix', pg_temp.timed('ms_fix', $$select public.marker_statements_fix('2027-06-01', '2027-07-02 12:00Z')$$));
insert into res values ('big_get2', pg_temp.timed('ms_get2', $$select public.marker_statements_get('2027-06-01')$$));
reset statement_timeout;
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('big_get')), jsonb_array_length(pg_temp.r('big_get') -> 'markers')::text,
    (select sum((m ->> 'pieces')::int)::text from jsonb_array_elements(pg_temp.r('big_get') -> 'markers') m),
    (select sum((m ->> 'total_pence')::int)::text from jsonb_array_elements(pg_temp.r('big_get') -> 'markers') m),
    pg_temp.code(pg_temp.r('big_fix')), pg_temp.r('big_fix') ->> 'statements', pg_temp.r('big_fix') ->> 'pieces',
    pg_temp.r('big_fix') ->> 'total_pence', pg_temp.r('big_get2') ->> 'fixed',
    (select sum((m ->> 'pieces')::int)::text from jsonb_array_elements(pg_temp.r('big_get2') -> 'markers') m),
    ((pg_temp.r('ms_get') ->> 'ms')::int <= 6000)::text, ((pg_temp.r('ms_fix') ->> 'ms')::int <= 6000)::text,
    ((pg_temp.r('ms_get2') ->> 'ms')::int <= 6000)::text],
  array['ok', '30', '3000', '900000', 'ok', '30', '3000', '900000', 'true', '3000', 'true', 'true', 'true'],
  'marker_statements_in_time_at_3000_pieces: June''s statements for 30 markers and 3,000 pieces of 5 exams, the fix, and '
  || 'the fixed statements each within 6 s, under the 8 s statement timeout a signed-in user meets (Ruling R21)');
select diag('marker_statements_get at 3,000 pieces: ' || (pg_temp.r('ms_get') ->> 'ms') || ' ms; marker_statements_fix: '
  || (pg_temp.r('ms_fix') ->> 'ms') || ' ms; marker_statements_get once fixed: ' || (pg_temp.r('ms_get2') ->> 'ms') || ' ms');

select * from finish();
rollback;
