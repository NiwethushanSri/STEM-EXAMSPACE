begin;
create extension if not exists pgtap with schema extensions;
select plan(98);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Subject 'ZZ Passes': markers m1 (Mara One) to m7 and the lead marker are approved for it (tests.marker);
-- corr is a corrector never approved. Exam e (tests.marking_exam: finished 2 days ago; the test structure; whole
-- scripts) has the home scripts x1 to x6, opened (tests.open_marking). m1 marks every one of them (their live pass is
-- submitted and, the checks being off, each piece and script is checked: Task 4); x1 by hand, with an annotation and a
-- note to the lead. A piece is sent for second marking as postgres through the check itself (pg_temp.wait_second: a
-- second marking wanted, then marking_check_evaluate), so it waits as Task 4 leaves it and its script is marked; one
-- that should wait no more is released with marking_second_drop. Scripts made later
-- (y1, y2, z1, z2, h1) come in once marking is open; exam eb is the timing guard's. A unit is kept as 'u:<script>', a page as 'p:<script>:<copy page>', a
-- question as 'q:<label>', a marking as 'mk<marker number>:<script>'.
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
create function pg_temp.subj() returns bigint language sql stable as $$ select id from public.subjects where name = 'ZZ Passes' $$;
create function pg_temp.code(j jsonb) returns text language sql immutable as $$
  select case when (j ->> 'ok')::boolean then 'ok' else coalesce(j ->> 'code', 'none') end $$;
create function pg_temp.who(p uuid) returns text language sql stable as $$ select coalesce((select name from c where id = p), '?') $$;
-- A save's mark for a question.
create function pg_temp.mk(p_q text, p_mark numeric) returns jsonb language sql stable as $$
  select jsonb_build_object('op', 'mark', 'question_id', pg_temp.k('q:' || p_q), 'mark', p_mark, 'na', false) $$;
-- Every mark of the piece: 1, 2(a), 2(b).
create function pg_temp.all_marks(p1 numeric, p2 numeric, p3 numeric) returns jsonb language sql stable as $$
  select jsonb_build_array(pg_temp.mk('1', p1), pg_temp.mk('2(a)', p2), pg_temp.mk('2(b)', p3)) $$;
-- A marking's rev and marks, read as postgres.
create function pg_temp.rev(p text) returns int language sql stable security definer as $$
  select rev from public.markings where id = pg_temp.k(p) $$;
create function pg_temp.marks(p text) returns text language sql stable security definer as $$
  select coalesce(string_agg(coalesce(pq.label || '(' || q.label || ')', q.label) || '=' || coalesce(trim_scale(m.mark)::text, 'NR'),
                             ',' order by coalesce(pq.position, q.position), pq.id is not null, q.position), '')
  from public.question_marks m join public.exam_questions q on q.id = m.question_id
  left join public.exam_questions pq on pq.id = q.parent_id
  where m.marking_id = pg_temp.k(p) $$;
-- A marker's markings on a script's piece (one per kind, in kind order): status, and why set aside ('-' for none).
create function pg_temp.ms(p text, p_marker text) returns text language sql stable security definer as $$
  select coalesce(string_agg(m.status || coalesce(' ' || m.set_aside_reason, ''), ',' order by m.kind), '-') from public.markings m
  where m.unit_id = pg_temp.u(p) and m.marker_id = pg_temp.uid(p_marker) $$;
-- How a marker's holds on a script's piece ended ('open' for one that has not), sorted ('-' for none). Every row of
-- this transaction has the same created_at, so they are not told apart by time.
create function pg_temp.ended(p text, p_marker text) returns text language sql stable security definer as $$
  select coalesce(string_agg(coalesce(a.end_reason, 'open'), ',' order by coalesce(a.end_reason, 'open')), '-')
  from public.marking_assignments a where a.unit_id = pg_temp.u(p) and a.marker_id = pg_temp.uid(p_marker) $$;
-- Who holds a script's piece, of which pass, and how ('-' for nobody).
create function pg_temp.holders(p text) returns text language sql stable security definer as $$
  select coalesce(string_agg(pg_temp.who(a.marker_id) || ' ' || a.kind || ' ' || a.how, ',' order by a.kind), '-')
  from public.marking_assignments a where a.unit_id = pg_temp.u(p) and a.ended_at is null $$;
create function pg_temp.us(p text) returns text language sql stable security definer as $$
  select state from public.marking_units where id = pg_temp.u(p) $$;
create function pg_temp.st(p text) returns text language sql stable security definer as $$
  select state::text from public.scripts where id = pg_temp.k(p) $$;
create function pg_temp.hold(p text) returns text language sql stable security definer as $$
  select case when on_hold then coalesce(hold_reason, '?') else '-' end from public.marking_units where id = pg_temp.u(p) $$;
create function pg_temp.audits(p_action text, p_target uuid) returns int language sql stable security definer as $$
  select count(*)::int from public.audit_log a where a.action = p_action and a.target_id = p_target $$;
create function pg_temp.student(p text) returns uuid language sql stable security definer as $$
  select b.student_id from public.scripts s join public.bookings b on b.id = s.booking_id where s.id = pg_temp.k(p) $$;
create function pg_temp.upload(p text) returns uuid language sql stable security definer as $$
  select pg.upload_id from public.script_pages pg where pg.id = pg_temp.k('p:' || p || ':1') $$;
-- A script's pages, in copy page order (read as postgres).
create function pg_temp.pages(p text) returns uuid[] language sql stable security definer as $$
  select coalesce(array_agg(l.page_id order by l.copy_page), '{}')
  from public.scripts s join public.script_page_links l on l.script_id = s.id and l.version = s.version where s.id = pg_temp.k(p) $$;
-- The key paths of an answer: '.marking.id', '.pages[].n', ... (values left out).
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
-- A piece of the caller's work list (marking_my_work), by its script.
create function pg_temp.piece(j jsonb, p text) returns jsonb language sql stable as $$
  select x from jsonb_array_elements(j -> 'pieces') x where x ->> 'unit_id' = pg_temp.u(p)::text $$;
-- A piece of a list of pieces (marking_units_list), by its script.
create function pg_temp.unit(j jsonb, p text) returns jsonb language sql stable as $$
  select x from jsonb_array_elements(j -> 'units') x where x ->> 'unit_id' = pg_temp.u(p)::text $$;
-- The stored mark scheme of exam e (read as postgres).
create function pg_temp.scheme() returns text language sql stable security definer as $$
  select f.storage_path from public.exam_mark_scheme_files f where f.exam_id = pg_temp.k('e') and f.state = 'stored' limit 1 $$;
-- A new verified home script of exam e, its pages and, once marking is open, its piece.
create function pg_temp.script(p_name text) returns void language plpgsql as $$
begin
  insert into kv values (p_name, tests.verified_script(pg_temp.k('e'), 'home'));
  insert into kv select 'p:' || p_name || ':' || l.copy_page, l.page_id
  from public.scripts s join public.script_page_links l on l.script_id = s.id and l.version = s.version where s.id = pg_temp.k(p_name);
  perform public.marking_exam_sync(pg_temp.k('e'), null);
  insert into kv select 'u:' || p_name, u.id from public.marking_units u where u.script_id = pg_temp.k(p_name) on conflict (name) do nothing;
end $$;
-- A piece waits for a second marking: one is wanted and the check is worked out again (Task 4), as "Second-mark these"
-- does. Its script is then marked.
create function pg_temp.wait_second(p text) returns void language plpgsql as $$
begin
  update public.marking_units set second_wanted = true where id = pg_temp.u(p);
  perform public.marking_check_evaluate(pg_temp.u(p));
end $$;
-- A piece waits no more: an admin releases its second marking (marking_second_drop), and it is checked.
create function pg_temp.wait_no_more(p text[]) returns void language plpgsql as $$
declare
  v_units uuid[] := array(select pg_temp.u(x) from unnest(p) x);
  v_admin uuid := pg_temp.uid('admin');
begin
  perform tests.as_user(v_admin);
  perform public.marking_second_drop(v_units, 'Enough second marking for these tests');
  perform tests.as_postgres();
end $$;
-- The marker's advisory lock this transaction holds ('-' for none).
create function pg_temp.marker_lock(p text) returns text language sql stable as $$
  select coalesce(string_agg(l.mode, ',' order by l.mode), '-') from pg_locks l
  where l.locktype = 'advisory' and l.pid = pg_backend_pid()
    and ((l.classid::bigint << 32) | l.objid::bigint) = hashtextextended('marker:' || pg_temp.uid(p)::text, 0) $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.u(text), pg_temp.r(text), pg_temp.code(jsonb), pg_temp.who(uuid),
  pg_temp.mk(text, numeric), pg_temp.all_marks(numeric, numeric, numeric), pg_temp.rev(text), pg_temp.pages(text),
  pg_temp.piece(jsonb, text), pg_temp.unit(jsonb, text), pg_temp.scheme(), pg_temp.subj(), pg_temp.student(text) to public;

insert into public.subjects (name, kind) values ('ZZ Passes', 'school');
insert into c values ('admin', tests.create_user('admin', 'active')), ('corr', tests.create_user('corrector', 'active'));
insert into c select 'm' || i, tests.marker(pg_temp.subj()) from generate_series(1, 7) i;
insert into c values ('lead', tests.marker(pg_temp.subj(), true));
update public.profiles set first_name = 'Mara', last_name = 'One' where id = pg_temp.uid('m1');

insert into kv values ('e', tests.marking_exam(pg_temp.subj()));
select tests.structure(pg_temp.k('e'));
insert into kv select 'q:' || coalesce(p.label || '(' || q.label || ')', q.label), q.id
from public.exam_questions q left join public.exam_questions p on p.id = q.parent_id where q.exam_id = pg_temp.k('e');
select tests.open_marking(pg_temp.k('e'));
do $$ begin for i in 1..6 loop perform pg_temp.script('x' || i); end loop; end $$;

-- m1 marks x1 by hand: an annotation on page 1 and a note to the lead, then the marks.
select public.marking_unit_take(pg_temp.u('x1'), pg_temp.uid('m1'), 'next', null, now() + interval '2 hours');
insert into kv values ('ann1', gen_random_uuid());
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('open1', public.marking_unit_open(pg_temp.u('x1')));
insert into kv values ('mk1:x1', (pg_temp.r('open1') #>> '{marking,id}')::uuid);
insert into res values ('save1', public.marking_save(pg_temp.k('mk1:x1'), 0, pg_temp.all_marks(2, 1, 4) || jsonb_build_array(
  jsonb_build_object('op', 'ann_put', 'id', pg_temp.k('ann1'), 'page_id', pg_temp.k('p:x1:1'), 'kind', 'tick', 'x', 0.5, 'y', 0.5),
  jsonb_build_object('op', 'note', 'text', 'Zebra crossing in 2(b), please look'))));
insert into res values ('sub1', public.marking_submit(pg_temp.k('mk1:x1'), 1));
select tests.as_postgres();
do $$ begin for i in 2..6 loop perform tests.mark_piece(pg_temp.u('x' || i), pg_temp.uid('m1'), array[1, 1, 1]); end loop; end $$;
select is((select string_agg(pg_temp.us('x' || i) || '/' || pg_temp.st('x' || i), ' ' order by i) from generate_series(1, 6) i),
  'submitted/checked submitted/checked submitted/checked submitted/checked submitted/checked submitted/checked',
  'fixtures: m1 has marked x1 to x6; each piece is submitted and each script marked (checked: the checks are off)');
select is(array[pg_temp.code(pg_temp.r('save1')), pg_temp.code(pg_temp.r('sub1')), pg_temp.marks('mk1:x1')], array['ok', 'ok', '1=2,2(a)=1,2(b)=4'],
  'fixtures: m1''s marking of x1 has marks, an annotation and a note');

-- ---------------------------------------------------------------------------------------------
-- second_marker_open_has_no_first_marks_or_layer
-- ---------------------------------------------------------------------------------------------
select pg_temp.wait_second('x1');
select tests.as_user(pg_temp.uid('m2'));
insert into res values ('a_next', public.marking_next(pg_temp.k('e')));
insert into res values ('open2', public.marking_unit_open(pg_temp.u('x1')));
select tests.as_postgres();
insert into kv values ('mk2:x1', (pg_temp.r('open2') #>> '{marking,id}')::uuid);
select is(pg_temp.r('a_next'), jsonb_build_object('ok', true, 'unit_id', pg_temp.u('x1'), 'resumed', false),
  'second_marker_open_has_no_first_marks_or_layer: x1 waits for a second marking; m2 presses Next script and is given it like any piece');
select is((select array[m.kind::text, m.status, (m.id <> pg_temp.k('mk1:x1'))::text] from public.markings m where m.id = pg_temp.k('mk2:x1')),
  array['second', 'in_progress', 'true'], 'the first open makes m2''s own marking, of the kind of their hold');
select is(pg_temp.found(array[pg_temp.k('ann1')::text, 'Zebra crossing', pg_temp.uid('m1')::text, pg_temp.k('mk1:x1')::text, 'Mara',
                              'Wilhelmina', 'Quarterfield'], pg_temp.r('open2')::text), '{}'::text[],
  'the open holds none of the first marker''s annotation ids, their note, their marker id, their marking or their name, and no candidate name');
select is(array[pg_temp.r('open2') #>> '{marking,total}', pg_temp.r('open2') #>> '{marking,lead_note}', pg_temp.r('open2') ->> 'marks',
                pg_temp.r('open2') ->> 'annotations'],
  array[null, null, '[]', '[]'], 'no total, no note, no marks and no annotations: m2 starts from nothing');
select is(pg_temp.keys(pg_temp.r('open2')), pg_temp.keys(pg_temp.r('open1')),
  'its keys are those of the first marker''s first open: nothing tells a second marking from a first');
select is(array[pg_temp.r('open2') #>> '{marking,practice}', pg_temp.r('open2') #>> '{marking,sent_back_note}',
                pg_temp.r('open1') #>> '{marking,practice}'],
  array['false', null, 'false'], 'every open says practice (false) and the note sent back (none)');
select is(pg_temp.r('open2') -> 'pages', pg_temp.r('open1') -> 'pages', 'm2 is shown the same pages');

-- ---------------------------------------------------------------------------------------------
-- second_marker_cannot_save_or_submit_the_first_marking
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('m2'));
insert into res values ('b_save', public.marking_save(pg_temp.k('mk1:x1'), pg_temp.rev('mk1:x1'), jsonb_build_array(pg_temp.mk('1', 0)), 0,
  'Changing the first marks'));
insert into res values ('b_submit', public.marking_submit(pg_temp.k('mk1:x1'), pg_temp.rev('mk1:x1')));
insert into res values ('b_own', public.marking_save(pg_temp.k('mk2:x1'), 0, jsonb_build_array(pg_temp.mk('1', 1))));
select tests.as_postgres();
select is(array[pg_temp.r('b_save'), pg_temp.r('b_submit')], array['{"ok": false, "code": "forbidden"}', '{"ok": false, "code": "forbidden"}']::jsonb[],
  'second_marker_cannot_save_or_submit_the_first_marking: m2 may neither save nor submit m1''s marking');
select is(array[pg_temp.marks('mk1:x1'), pg_temp.rev('mk1:x1')::text, pg_temp.ms('x1', 'm1')],
  array['1=2,2(a)=1,2(b)=4', pg_temp.r('sub1') ->> 'rev', 'submitted'], 'the first marking is as m1 submitted it');
select is(array[pg_temp.code(pg_temp.r('b_own')), pg_temp.marks('mk2:x1')], array['ok', '1=1'], 'm2 saves their own');

-- ---------------------------------------------------------------------------------------------
-- first_marker_is_never_offered_the_second_pass
-- ---------------------------------------------------------------------------------------------
select pg_temp.wait_second('x2');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('c_next', public.marking_next(pg_temp.k('e')));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
insert into res values ('c_assign', public.marking_assign(array[pg_temp.u('x2')], pg_temp.uid('m1'), 'Second marking please', 'second'));
select tests.as_postgres();
select is(pg_temp.r('c_next'), '{"ok": false, "code": "nothing_left"}'::jsonb,
  'first_marker_is_never_offered_the_second_pass: x2 waits too; m1, who marked it, is given nothing');
select is(array[public.marking_unit_blocked(pg_temp.u('x2'), pg_temp.uid('m1'), null, true, 'second'),
                public.marking_unit_blocked(pg_temp.u('x2'), pg_temp.uid('m1'), null, false, 'second')],
  array['not_eligible', 'not_eligible'], 'the one rule refuses them, for Next script and for an admin');
select is(pg_temp.r('c_assign'), jsonb_build_object('ok', true, 'assigned', 0, 'skipped',
                                   jsonb_build_array(jsonb_build_object('unit_id', pg_temp.u('x2'), 'code', 'not_eligible'))),
  'an admin cannot give it to them either');
select is((select count(*)::int from public.marking_units_allowed(pg_temp.k('e'), pg_temp.uid('m1'), 'second', false)), 0,
  'm1 may be given no second pass of the exam: they marked every script');

-- ---------------------------------------------------------------------------------------------
-- second_pass_skips_conflict_tutor_link_and_name_seen: m4 declared a conflict with x2's candidate, m5 tutors them and
-- m6 saw a name on x2.
-- ---------------------------------------------------------------------------------------------
insert into public.marker_conflicts (marker_id, student_id, recorded_at) values (pg_temp.uid('m4'), pg_temp.student('x2'), now());
insert into public.tutor_students (tutor_id, student_id) values (pg_temp.uid('m5'), pg_temp.student('x2'));
insert into public.marking_unit_exclusions (unit_id, marker_id, reason) values (pg_temp.u('x2'), pg_temp.uid('m6'), 'name_seen');
select tests.as_user(pg_temp.uid('m4')); insert into res values ('d4', public.marking_next(pg_temp.k('e'))); select tests.as_postgres();
select tests.as_user(pg_temp.uid('m5')); insert into res values ('d5', public.marking_next(pg_temp.k('e'))); select tests.as_postgres();
select tests.as_user(pg_temp.uid('m6')); insert into res values ('d6', public.marking_next(pg_temp.k('e'))); select tests.as_postgres();
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('d_assign', public.marking_assign(array[pg_temp.u('x2')], pg_temp.uid('m6'), 'Second marking please', 'second'));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('d4')), pg_temp.code(pg_temp.r('d5')), pg_temp.code(pg_temp.r('d6'))],
  array['nothing_left', 'nothing_left', 'nothing_left'],
  'second_pass_skips_conflict_tutor_link_and_name_seen: Next script gives m4 (a conflict), m5 (a tutor link) and m6 (a name seen) nothing');
select is(array[public.marking_unit_blocked(pg_temp.u('x2'), pg_temp.uid('m4'), null, true, 'second'),
                public.marking_unit_blocked(pg_temp.u('x2'), pg_temp.uid('m5'), null, true, 'second'),
                public.marking_unit_blocked(pg_temp.u('x2'), pg_temp.uid('m6'), null, true, 'second'),
                public.marking_unit_blocked(pg_temp.u('x2'), pg_temp.uid('m6'), null, false, 'second')],
  array['conflict_of_interest', 'conflict_of_interest', 'name_seen', 'name_seen'],
  'the rule says why; a name seen bars a second marker for an admin''s assignment too');
select is(pg_temp.r('d_assign') -> 'skipped', jsonb_build_array(jsonb_build_object('unit_id', pg_temp.u('x2'), 'code', 'name_seen')),
  'so an admin cannot give m6 the second pass of x2');
select is(coalesce(public.marking_unit_blocked(pg_temp.u('x2'), pg_temp.uid('m3'), null, true, 'second'), 'ok'), 'ok',
  'm3, with none of these, may be given it');

-- ---------------------------------------------------------------------------------------------
-- lead_is_blind_to_pieces_waiting_for_a_second_marking: the lead holds nothing yet; x1 and x2 wait, x3 does not.
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('lead'));
insert into res values ('d_lead_list', public.marking_units_list(pg_temp.k('e')));
select tests.as_postgres();
select is(array[pg_temp.unit(pg_temp.r('d_lead_list'), 'x2') ->> 'total', pg_temp.unit(pg_temp.r('d_lead_list'), 'x2') ->> 'submitted_at',
                pg_temp.unit(pg_temp.r('d_lead_list'), 'x2') ->> 'last_saved_at', pg_temp.unit(pg_temp.r('d_lead_list'), 'x2') ->> 'marker_id',
                pg_temp.unit(pg_temp.r('d_lead_list'), 'x2') ->> 'marker_name', pg_temp.unit(pg_temp.r('d_lead_list'), 'x3') ->> 'marker_name',
                pg_temp.unit(pg_temp.r('d_lead_list'), 'x3') ->> 'total'],
  array[null, null, null, null, null, 'Mara One', '3.0'],
  'lead_is_blind_to_pieces_waiting_for_a_second_marking: holding nothing, the lead sees nothing of x2''s first marking; x3''s shows');

-- ---------------------------------------------------------------------------------------------
-- lead_may_take_a_second_pass
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('lead'));
insert into res values ('e_next', public.marking_next(pg_temp.k('e')));
insert into res values ('e_open', public.marking_unit_open(pg_temp.u('x2')));
select tests.as_postgres();
select is(pg_temp.r('e_next'), jsonb_build_object('ok', true, 'unit_id', pg_temp.u('x2'), 'resumed', false),
  'lead_may_take_a_second_pass: the lead marker presses Next script and is given x2''s second pass');
select is(array[pg_temp.code(pg_temp.r('e_open')), pg_temp.holders('x2')], array['ok', 'lead second next'], 'they hold it and open it');

-- ---------------------------------------------------------------------------------------------
-- two_markers_one_second_pass_never_both
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('m3'));
insert into res values ('f_next', public.marking_next(pg_temp.k('e')));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
insert into res values ('f_assign', public.marking_assign(array[pg_temp.u('x1')], pg_temp.uid('m3'), 'Second marking please', 'second'));
select tests.as_postgres();
select is(pg_temp.r('f_next'), '{"ok": false, "code": "nothing_left"}'::jsonb,
  'two_markers_one_second_pass_never_both: m2 holds x1''s second pass and the lead x2''s: m3 is given neither');
select is(pg_temp.r('f_assign') -> 'skipped', jsonb_build_array(jsonb_build_object('unit_id', pg_temp.u('x1'), 'code', 'taken')),
  'an admin cannot give x1''s second pass to m3 while m2 holds it');
select is(public.marking_unit_blocked(pg_temp.u('x1'), pg_temp.uid('m3'), null, false, 'second'), 'not_eligible',
  'the one rule refuses m3 while another marker holds it');
select throws_ok(format('insert into public.marking_assignments (unit_id, kind, marker_id, how) values (%L, %L, %L, %L)',
                        pg_temp.u('x1'), 'second', pg_temp.uid('m3'), 'next'),
  '23505', 'duplicate key value violates unique constraint "marking_assignments_one_holder"', 'and the database refuses a second holder');
select is(pg_temp.holders('x1'), 'm2 second next', 'm2 alone holds it');

-- lead_second_marker_never_sees_the_first_total: the lead holds x2's second pass.
select tests.as_user(pg_temp.uid('lead'));
insert into res values ('f_lead_list', public.marking_units_list(pg_temp.k('e')));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
insert into res values ('f_admin_list', public.marking_units_list(pg_temp.k('e')));
select tests.as_postgres();
select is(array[pg_temp.unit(pg_temp.r('f_lead_list'), 'x2') ->> 'total', pg_temp.unit(pg_temp.r('f_lead_list'), 'x2') ->> 'submitted_at',
                pg_temp.unit(pg_temp.r('f_lead_list'), 'x3') ->> 'total', pg_temp.unit(pg_temp.r('f_admin_list'), 'x2') ->> 'total'],
  array[null, null, '3.0', '3.0'],
  'lead_second_marker_never_sees_the_first_total: the lead''s list gives x2''s total and submit time as null while they hold its second pass; x3''s, and the admin''s, are shown');

-- ---------------------------------------------------------------------------------------------
-- second_hold_expires_and_frees_only_the_second_pass
-- ---------------------------------------------------------------------------------------------
update public.marking_assignments set hold_until = now() - interval '1 minute'
where unit_id = pg_temp.u('x1') and kind = 'second' and ended_at is null;
select public.marking_holds_expire(null);
select is(array[pg_temp.ended('x1', 'm2'), pg_temp.ms('x1', 'm2'), pg_temp.us('x1'), pg_temp.ms('x1', 'm1'), pg_temp.st('x1')],
  array['expired', 'in_progress', 'submitted', 'submitted', 'marked'],
  'second_hold_expires_and_frees_only_the_second_pass: m2''s hold ends and their marking is kept; the piece stays submitted, the first marking stands and the script stays marked');
select is(array[pg_temp.marks('mk1:x1'), pg_temp.rev('mk1:x1')::text], array['1=2,2(a)=1,2(b)=4', pg_temp.r('sub1') ->> 'rev'],
  'the first marking is untouched');
select tests.as_user(pg_temp.uid('m2'));
insert into res values ('g_open', public.marking_unit_open(pg_temp.u('x1')));
insert into res values ('g_next', public.marking_next(pg_temp.k('e')));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('g_open')), pg_temp.r('g_next')::text],
  array['hold_expired', jsonb_build_object('ok', true, 'unit_id', pg_temp.u('x1'), 'resumed', true)::text],
  'm2 is told the hold ended, as on a live piece; while nobody else has taken the pass, Next script gives them their marking back');
-- Their hold runs out again, and this time another marker presses Next script first.
update public.marking_assignments set hold_until = now() - interval '1 minute'
where unit_id = pg_temp.u('x1') and kind = 'second' and ended_at is null;
select public.marking_holds_expire(null);
select tests.as_user(pg_temp.uid('m3'));
insert into res values ('g_next3', public.marking_next(pg_temp.k('e')));
insert into res values ('g_open3', public.marking_unit_open(pg_temp.u('x1')));
select tests.as_postgres();
insert into kv values ('mk3:x1', (pg_temp.r('g_open3') #>> '{marking,id}')::uuid);
select is(pg_temp.r('g_next3'), jsonb_build_object('ok', true, 'unit_id', pg_temp.u('x1'), 'resumed', false),
  'an abandoned second pass frees up, as a live one does: m3 presses Next script and is given it');
select is(array[pg_temp.holders('x1'), pg_temp.ms('x1', 'm2'), pg_temp.ms('x1', 'm3'), pg_temp.us('x1'), pg_temp.ms('x1', 'm1')],
  array['m3 second next', 'set_aside expired', 'in_progress', 'submitted', 'submitted'],
  'm2''s marking is set aside (expired) and m3 starts their own; the piece and the first marking are as they were');

-- ---------------------------------------------------------------------------------------------
-- give_back_of_a_second_pass_leaves_the_first_marking_alone
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('m3'));
insert into res values ('h_gb', public.marking_give_back(pg_temp.u('x1'), 'I know this school'));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m2'));
insert into res values ('h_next', public.marking_next(pg_temp.k('e')));
select tests.as_postgres();
select is(pg_temp.r('h_gb'), '{"ok": true}'::jsonb, 'give_back_of_a_second_pass_leaves_the_first_marking_alone: m3 gives x1''s second pass back');
select is(array[pg_temp.ended('x1', 'm3'), pg_temp.ms('x1', 'm3'),
                pg_temp.us('x1'), pg_temp.ms('x1', 'm1'), pg_temp.marks('mk1:x1'), pg_temp.rev('mk1:x1')::text],
  array['given_back', 'set_aside given_back', 'submitted', 'submitted', '1=2,2(a)=1,2(b)=4', pg_temp.r('sub1') ->> 'rev'],
  'their hold ends and their marking is set aside; the piece stays submitted and the first marking is untouched');
select is(pg_temp.audits('marking_given_back', pg_temp.u('x1')), 1, 'audited');
select is(array[pg_temp.r('h_next')::text, pg_temp.ms('x1', 'm2')],
  array[jsonb_build_object('ok', true, 'unit_id', pg_temp.u('x1'), 'resumed', false)::text, 'in_progress'],
  'the second pass is free: m2 presses Next script and is given it, with their own earlier marking in progress again');

-- ---------------------------------------------------------------------------------------------
-- second_submit_ends_only_the_second_hold
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('m2'));
insert into res values ('i_open', public.marking_unit_open(pg_temp.u('x1')));
insert into res values ('i_save', public.marking_save(pg_temp.k('mk2:x1'), 1, pg_temp.all_marks(3, 2, 5)));
insert into res values ('i_sub', public.marking_submit(pg_temp.k('mk2:x1'), 2));
select tests.as_postgres();
select is(array[pg_temp.r('i_open') #>> '{marking,id}', pg_temp.r('i_sub')::text],
  array[pg_temp.k('mk2:x1')::text, '{"ok": true, "rev": 3, "total": 10.0, "feedback": null, "max_total": 10.0}'],
  'second_submit_ends_only_the_second_hold: m2 opens their marking again and submits it');
select is(array[pg_temp.ended('x1', 'm2'), pg_temp.ms('x1', 'm2'), pg_temp.holders('x1'), pg_temp.us('x1'), pg_temp.st('x1')],
  array['expired,expired,submitted', 'submitted', '-', 'submitted', 'marked'], 'their hold ends; the piece and its script are as they were');
select is(array[pg_temp.ms('x1', 'm1'), pg_temp.marks('mk1:x1'), pg_temp.rev('mk1:x1')::text, pg_temp.holders('x2')],
  array['submitted', '1=2,2(a)=1,2(b)=4', pg_temp.r('sub1') ->> 'rev', 'lead second next'],
  'the first marking stands as it was, and the lead still holds x2''s second pass');
select is(pg_temp.audits('marking_submitted', pg_temp.k('mk2:x1')), 1, 'the submit is audited');

-- ---------------------------------------------------------------------------------------------
-- submit_result_has_no_script_state
-- ---------------------------------------------------------------------------------------------
select is(array(select k from jsonb_object_keys(pg_temp.r('sub1')) k order by 1), array['feedback', 'max_total', 'ok', 'rev', 'total'],
  'submit_result_has_no_script_state: a first marking''s submit answers ok, rev, total, max_total and feedback');
select is(array(select k from jsonb_object_keys(pg_temp.r('i_sub')) k order by 1), array['feedback', 'max_total', 'ok', 'rev', 'total'],
  'so does a second marking''s');
select is(array[pg_temp.r('sub1') -> 'feedback', pg_temp.r('i_sub') -> 'feedback'], array['null', 'null']::jsonb[],
  'feedback is null for both (Tasks 4 and 5 fill it)');

-- ---------------------------------------------------------------------------------------------
-- my_work_shows_a_second_piece_like_any_other: m2 holds y1's live pass (Next script) and an admin gives them x3's
-- second pass; they open and save both.
-- ---------------------------------------------------------------------------------------------
select pg_temp.script('y1');
select pg_temp.wait_second('x3');
select public.marking_unit_take(pg_temp.u('y1'), pg_temp.uid('m2'), 'next', null, now() + interval '2 hours');
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('k_assign', public.marking_assign(array[pg_temp.u('x3')], pg_temp.uid('m2'), 'Second marking please', 'second'));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m2'));
insert into res values ('k_open_y1', public.marking_unit_open(pg_temp.u('y1')));
insert into res values ('k_open_x3', public.marking_unit_open(pg_temp.u('x3')));
insert into kv values ('mk2:y1', (pg_temp.r('k_open_y1') #>> '{marking,id}')::uuid), ('mk2:x3', (pg_temp.r('k_open_x3') #>> '{marking,id}')::uuid);
select public.marking_save(pg_temp.k('mk2:y1'), 0, jsonb_build_array(pg_temp.mk('1', 1)));
select public.marking_save(pg_temp.k('mk2:x3'), 0, jsonb_build_array(pg_temp.mk('1', 2)));
insert into res values ('k_work', public.marking_my_work());
select tests.as_postgres();
select is(array(select k from jsonb_object_keys(pg_temp.piece(pg_temp.r('k_work'), 'x3')) k order by 1),
          array(select k from jsonb_object_keys(pg_temp.piece(pg_temp.r('k_work'), 'y1')) k order by 1),
  'my_work_shows_a_second_piece_like_any_other: m2''s second piece has the keys of their live piece');
select is(array[pg_temp.piece(pg_temp.r('k_work'), 'x3') ->> 'state', pg_temp.piece(pg_temp.r('k_work'), 'y1') ->> 'state',
                pg_temp.piece(pg_temp.r('k_work'), 'x3') ->> 'practice', pg_temp.piece(pg_temp.r('k_work'), 'y1') ->> 'practice'],
  array['taken', 'taken', 'false', 'false'], 'both are taken while m2 holds them (x3''s own state is submitted), and neither is practice');
select is(pg_temp.found(array['second', 'live', 'kind'], pg_temp.r('k_work')::text), '{}'::text[], 'no key or value of the list names a kind');
select is(pg_temp.piece(pg_temp.r('k_work'), 'x1') ->> 'state', 'submitted', 'm2''s submitted second marking of x1 shows as submitted');
select is((select (e -> 'mine' ->> 'taken') || ' ' || (e -> 'mine' ->> 'submitted') from jsonb_array_elements(pg_temp.r('k_work') -> 'exams') e
           where e ->> 'exam_id' = pg_temp.k('e')::text), '2 1', 'm2''s exam counts the two pieces they hold and the one they submitted');

-- ---------------------------------------------------------------------------------------------
-- admin_assigns_and_takes_back_a_second_pass
-- ---------------------------------------------------------------------------------------------
select pg_temp.wait_second('x4');
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('l_assign', public.marking_assign(array[pg_temp.u('x4')], pg_temp.uid('m3'), 'Second marking for the sample', 'second'));
select tests.as_postgres();
select is(pg_temp.r('l_assign'), '{"ok": true, "assigned": 1, "skipped": []}'::jsonb,
  'admin_assigns_and_takes_back_a_second_pass: an admin gives x4''s second pass to m3');
select is((select array[a.kind::text, a.how, (a.hold_until is null)::text, pg_temp.who(a.assigned_by)] from public.marking_assignments a
           where a.unit_id = pg_temp.u('x4') and a.marker_id = pg_temp.uid('m3') and a.ended_at is null),
  array['second', 'assigned', 'true', 'admin'], 'm3 holds it, with no time limit');
select is(array[pg_temp.us('x4'), pg_temp.ms('x4', 'm1'), pg_temp.st('x4')], array['submitted', 'submitted', 'marked'],
  'the piece, its first marking and its script are as they were');
select is((select a.reason from public.audit_log a where a.action = 'marking_second_assigned' and a.target_id = pg_temp.u('x4')),
  'Second marking for the sample', 'audited, with the reason');
select tests.as_user(pg_temp.uid('m3'));
insert into res values ('l_open', public.marking_unit_open(pg_temp.u('x4')));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
insert into res values ('l_reassign', public.marking_reassign(array[pg_temp.u('x4')], pg_temp.uid('m3'), 'Give m3 the first marking'));
select tests.as_postgres();
select is(pg_temp.r('l_reassign'), jsonb_build_object('ok', true, 'taken_back', 0, 'assigned', 0, 'skipped',
                                     jsonb_build_array(jsonb_build_object('unit_id', pg_temp.u('x4'), 'code', 'not_eligible'))),
  'reassigning x4''s live pass to m3, who holds its second, is refused with not_eligible');
select is(array[pg_temp.us('x4'), pg_temp.ms('x4', 'm1'), pg_temp.holders('x4')], array['submitted', 'submitted', 'm3 second assigned'],
  'and left exactly as it was');
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('l_tb', public.marking_take_back(array[pg_temp.u('x4')], 'The sample changed', 'second'));
insert into res values ('l_tb2', public.marking_take_back(array[pg_temp.u('x4')], 'The sample changed', 'second'));
insert into res values ('l_bad', jsonb_build_array(
  public.marking_assign(array[pg_temp.u('x4')], pg_temp.uid('m3'), 'Seed it', 'seed'),
  public.marking_take_back(array[pg_temp.u('x4')], 'Practice it', 'practice'),
  public.marking_assign(array[pg_temp.u('x4')], pg_temp.uid('m3'), 'No kind', null)));
select tests.as_postgres();
select is(array[pg_temp.r('l_tb'), pg_temp.r('l_tb2')], array['{"ok": true, "taken_back": 1}', '{"ok": true, "taken_back": 0}']::jsonb[],
  'the admin takes the second pass back (and a second time there is nothing to take back)');
select is(array[pg_temp.ended('x4', 'm3'), pg_temp.ms('x4', 'm3'), pg_temp.us('x4'), pg_temp.ms('x4', 'm1'), pg_temp.holders('x4')],
  array['taken_back', 'set_aside taken_back', 'submitted', 'submitted', '-'],
  'm3''s hold ends and their second marking is set aside; the piece stays submitted and the first marking stands');
select is((select a.reason from public.audit_log a where a.action = 'marking_second_taken_back' and a.target_id = pg_temp.u('x4')),
  'The sample changed', 'audited, with the reason');
select is(array(select pg_temp.code(x) from jsonb_array_elements(pg_temp.r('l_bad')) x), array['invalid_input', 'invalid_input', 'invalid_input'],
  'only a live or a second pass may be assigned or taken back');

-- ---------------------------------------------------------------------------------------------
-- name_visible_from_the_second_marker_takes_the_script_back_and_bars_them
-- ---------------------------------------------------------------------------------------------
select pg_temp.wait_second('x5');
select tests.as_user(pg_temp.uid('admin'));
select public.marking_assign(array[pg_temp.u('x5')], pg_temp.uid('m3'), 'Second marking please', 'second');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m3'));
select public.marking_unit_open(pg_temp.u('x5'));
insert into res values ('m_nv', public.marking_name_visible(pg_temp.u('x5'), pg_temp.k('p:x5:1')));
select tests.as_postgres();
select is(pg_temp.r('m_nv'), '{"ok": true}'::jsonb,
  'name_visible_from_the_second_marker_takes_the_script_back_and_bars_them: m3 reports a name on x5');
select is(array[(select (s.taken_back_at is not null)::text from public.scripts s where s.id = pg_temp.k('x5')), pg_temp.hold('x5'), pg_temp.us('x5')],
  array['true', 'name_visible', 'submitted'], 'the script is taken back and its piece is on hold; the piece''s own state is still the first marking''s');
select is(array[pg_temp.ended('x5', 'm3'), pg_temp.ms('x5', 'm3'), pg_temp.ms('x5', 'm1')],
  array['name_seen', 'set_aside name_seen', 'submitted'], 'm3''s hold ends and their marking is set aside; the first marking stands');
select is((select string_agg(pg_temp.who(x.marker_id) || ' ' || x.reason, ',') from public.marking_unit_exclusions x where x.unit_id = pg_temp.u('x5')),
  'm3 name_seen', 'm3 is kept from the piece');
select is((select count(*)::int from public.script_exceptions x where x.page_id = pg_temp.k('p:x5:1') and x.kind = 'name_visible' and x.state = 'open')
          + (select count(*)::int from public.marking_alerts a where a.script_id = pg_temp.k('x5') and a.kind = 'name_visible' and a.state = 'open'),
  2, 'a name_visible exception for the page and an alert, as from a first marker');

-- ---------------------------------------------------------------------------------------------
-- a_name_still_shows_bars_second_markers_too
-- ---------------------------------------------------------------------------------------------
select pg_temp.wait_second('x6');
select tests.as_user(pg_temp.uid('admin'));
select public.marking_assign(array[pg_temp.u('x6')], pg_temp.uid('m2'), 'Second marking please', 'second');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m2'));
select public.marking_unit_open(pg_temp.u('x6'));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
insert into res values ('n_ns', public.script_page_marking_name_shows(pg_temp.k('p:x6:2'), 'A name shows on page 2'));
select tests.as_postgres();
select is(pg_temp.code(pg_temp.r('n_ns')), 'ok', 'a_name_still_shows_bars_second_markers_too: staff say a name still shows on page 2 of x6');
select is(array[pg_temp.ended('x6', 'm2'), pg_temp.ms('x6', 'm2'), pg_temp.ms('x6', 'm1'), pg_temp.us('x6'), pg_temp.hold('x6')],
  array['name_seen', 'set_aside name_seen', 'submitted', 'submitted', 'taken_back'],
  'm2''s second hold ends and their marking is set aside; m1''s submitted marking stands; the script is taken back');
select is((select string_agg(pg_temp.who(x.marker_id), ',' order by pg_temp.who(x.marker_id)) from public.marking_unit_exclusions x
           where x.unit_id = pg_temp.u('x6')), 'm1,m2', 'both markers who may have seen the page are kept from it');
select is(array[pg_temp.holders('y1'), pg_temp.holders('x3')], array['m2 live next', 'm2 second assigned'], 'm2''s pieces of other scripts are left alone');

-- ---------------------------------------------------------------------------------------------
-- unapproved_or_conflicted_second_marker_frees_the_pass: m1 marks z1 and z2; m6 is given z1's second pass and m5
-- z2's, and each opens it. Then m6's approval is removed and m5 declares a conflict with z2's candidate.
-- ---------------------------------------------------------------------------------------------
select pg_temp.script('z1');
select pg_temp.script('z2');
select tests.mark_piece(pg_temp.u('z1'), pg_temp.uid('m1'), array[1, 1, 1]);
select tests.mark_piece(pg_temp.u('z2'), pg_temp.uid('m1'), array[1, 1, 1]);
select pg_temp.wait_second('z1');
select pg_temp.wait_second('z2');
select tests.as_user(pg_temp.uid('admin'));
select public.marking_assign(array[pg_temp.u('z1')], pg_temp.uid('m6'), 'Second marking please', 'second');
select public.marking_assign(array[pg_temp.u('z2')], pg_temp.uid('m5'), 'Second marking please', 'second');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m6'));
select public.marking_unit_open(pg_temp.u('z1'));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m5'));
select public.marking_unit_open(pg_temp.u('z2'));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select public.marker_unapprove(pg_temp.uid('m6'), pg_temp.subj(), 'No longer marks this subject');
select public.marker_conflict_set(pg_temp.uid('m5'), pg_temp.student('z2'), null, 'Knows the candidate');
select tests.as_postgres();
select is(array[pg_temp.ended('z1', 'm6'), pg_temp.ms('z1', 'm6'), pg_temp.us('z1'), pg_temp.ms('z1', 'm1'),
                coalesce(public.marking_unit_blocked(pg_temp.u('z1'), pg_temp.uid('m3'), null, true, 'second'), 'ok')],
  array['unapproved', 'set_aside unapproved', 'submitted', 'submitted', 'ok'],
  'unapproved_or_conflicted_second_marker_frees_the_pass: m6''s approval goes: their second hold ends, their marking is set aside and another marker may be given the pass; the first marking stands');
select is(array[pg_temp.ended('z2', 'm5'), pg_temp.ms('z2', 'm5'), pg_temp.us('z2'), pg_temp.ms('z2', 'm1'),
                coalesce(public.marking_unit_blocked(pg_temp.u('z2'), pg_temp.uid('m3'), null, true, 'second'), 'ok')],
  array['conflict', 'set_aside conflict', 'submitted', 'submitted', 'ok'],
  'm5 declares a conflict: the same, with conflict');
-- z1 and z2 wait no more, for the tests below.
select pg_temp.wait_no_more(array['z1', 'z2']);

-- ---------------------------------------------------------------------------------------------
-- picture_paths_follow_the_pass (marking_picture_paths): m2 holds x3's second pass.
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('m2'));
insert into res values ('o_m2', public.marking_picture_paths(pg_temp.u('x3'), pg_temp.pages('x3')));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m3'));
insert into res values ('o_m3', public.marking_picture_paths(pg_temp.u('x3'), pg_temp.pages('x3')));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select public.marking_take_back(array[pg_temp.u('x3')], 'Not needed after all', 'second');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m2'));
insert into res values ('o_after', public.marking_picture_paths(pg_temp.u('x3'), pg_temp.pages('x3')));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('o_m2')), jsonb_array_length(pg_temp.r('o_m2') -> 'paths')::text], array['ok', '3'],
  'picture_paths_follow_the_pass: m2, who holds x3''s second pass, is given its marking pictures');
select is(pg_temp.code(pg_temp.r('o_m3')), 'forbidden', 'a marker with no pass on the piece is not');
select is(pg_temp.r('o_after'), '{"ok": false, "code": "hold_expired"}'::jsonb, 'nor is m2 once the pass is taken back');

-- ---------------------------------------------------------------------------------------------
-- second_pass_waits_for_the_picture_check_and_a_busy_script: x3's second pass is free again; x4 no longer waits.
-- ---------------------------------------------------------------------------------------------
select pg_temp.wait_no_more(array['x4']);
insert into public.processing_jobs (upload_id, kind, state) values (pg_temp.upload('x3'), 'remask', 'queued');
insert into public.processing_jobs (upload_id, kind, state) values (pg_temp.upload('x2'), 'remask', 'queued');
select tests.as_user(pg_temp.uid('m4'));
insert into res values ('p_busy', public.marking_next(pg_temp.k('e')));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('lead'));
insert into res values ('p_lead', public.marking_unit_open(pg_temp.u('x2')));
select tests.as_postgres();
select is(array[public.marking_script_blocked(pg_temp.k('x3'), null), public.marking_unit_blocked(pg_temp.u('x3'), pg_temp.uid('m4'), null, true, 'second'),
                pg_temp.code(pg_temp.r('p_busy'))],
  array['pictures_updating', 'not_ready', 'nothing_left'],
  'second_pass_waits_for_the_picture_check_and_a_busy_script: while a file of x3''s pages is remasked its second pass is not handed out');
select is(pg_temp.code(pg_temp.r('p_lead')), 'pictures_updating', 'and the lead may not work on x2''s second pass while its file is remasked');
update public.processing_jobs set state = 'done', finished_at = now() where upload_id in (pg_temp.upload('x3'), pg_temp.upload('x2')) and kind = 'remask';
-- Staff confirmed page 1 of x3 (a resolved poor_quality exception): its marking picture waits for their check.
insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, state, resolved_by, resolved_at, resolution)
select s.exam_id, 'poor_quality', s.booking_id, s.id, pg_temp.k('p:x3:1'), pg_temp.upload('x3'), 'resolved', pg_temp.uid('admin'), now(), 'confirmed'
from public.scripts s where s.id = pg_temp.k('x3');
select tests.as_user(pg_temp.uid('m4'));
insert into res values ('p_unchecked', public.marking_next(pg_temp.k('e')));
select tests.as_postgres();
select is(array[public.marking_script_waiting(pg_temp.k('x3'), null), public.marking_unit_blocked(pg_temp.u('x3'), pg_temp.uid('m4'), null, true, 'second'),
                pg_temp.code(pg_temp.r('p_unchecked'))],
  array['picture_unchecked', 'not_ready', 'nothing_left'], 'while a picture of the marked script waits for its check, nor is it');
update public.script_pages set marking_checked_path = marking_path, marking_checked_by = pg_temp.uid('admin'), marking_checked_at = now()
where id = pg_temp.k('p:x3:1');
select tests.as_user(pg_temp.uid('m4'));
insert into res values ('p_work', public.marking_my_work());
insert into res values ('p_checked', public.marking_next(pg_temp.k('e')));
select tests.as_postgres();
select is((select e ->> 'left' from jsonb_array_elements(pg_temp.r('p_work') -> 'exams') e where e ->> 'exam_id' = pg_temp.k('e')::text), '1',
  'left_counts_second_passes: with only x3''s second pass free for them, m4''s list says 1 left');
select is(pg_temp.r('p_checked'), jsonb_build_object('ok', true, 'unit_id', pg_temp.u('x3'), 'resumed', false),
  'once the picture is checked, Next script gives m4 the second pass');

-- ---------------------------------------------------------------------------------------------
-- second_hold_restarts_when_its_alert_is_released: x3's picture changed while m4 held its second pass, and their hold
-- would have run out meanwhile.
-- ---------------------------------------------------------------------------------------------
update public.marking_units set on_hold = true, hold_reason = 'picture_changed' where id = pg_temp.u('x3');
update public.marking_assignments set hold_until = now() - interval '1 hour' where unit_id = pg_temp.u('x3') and ended_at is null;
with a as (insert into public.marking_alerts (exam_id, kind, script_id) values (pg_temp.k('e'), 'picture_changed', pg_temp.k('x3')) returning id)
insert into kv select 'al:x3', a.id from a;
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('s_release', public.marking_alert_release(pg_temp.k('al:x3'), 'The picture is fine'));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('s_release')), pg_temp.hold('x3'),
                (select (a.hold_until = now() + interval '2 hours')::text from public.marking_assignments a
                 where a.unit_id = pg_temp.u('x3') and a.marker_id = pg_temp.uid('m4') and a.ended_at is null)],
  array['ok', '-', 'true'], 'second_hold_restarts_when_its_alert_is_released: the release lifts the hold and m4''s Next script hold restarts at 2 hours');

-- ---------------------------------------------------------------------------------------------
-- mark_scheme_for_a_second_marker: exam e has a stored mark scheme; m4's only pass on e is x3's second.
-- ---------------------------------------------------------------------------------------------
with f as (select gen_random_uuid() as id)
insert into public.exam_mark_scheme_files (id, exam_id, storage_path, byte_size, state, uploaded_by, uploaded_at)
select f.id, pg_temp.k('e'), pg_temp.k('e')::text || '/' || f.id::text || '.pdf', 1000, 'stored', pg_temp.uid('admin'), now() from f;
select tests.as_user(pg_temp.uid('m4'));
insert into res values ('t_m4', to_jsonb(public.mark_scheme_path_allowed(pg_temp.scheme())));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m7'));
insert into res values ('t_m7', to_jsonb(public.mark_scheme_path_allowed(pg_temp.scheme())));
select tests.as_postgres();
select is(array[pg_temp.r('t_m4'), pg_temp.r('t_m7')], array['true', 'false']::jsonb[],
  'mark_scheme_for_a_second_marker: m4 may read the mark scheme, as a first marker may; m7, with no pass on the exam, may not');

-- ---------------------------------------------------------------------------------------------
-- units_list_says_who_has_the_second_pass
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('v_list', public.marking_units_list(pg_temp.k('e')));
insert into res values ('v_list_m4', public.marking_units_list(pg_temp.k('e'), null, pg_temp.uid('m4')));
select tests.as_postgres();
select is(array[pg_temp.unit(pg_temp.r('v_list'), 'x2') -> 'second', pg_temp.unit(pg_temp.r('v_list'), 'x1') -> 'second',
                pg_temp.unit(pg_temp.r('v_list'), 'x4') -> 'second', pg_temp.unit(pg_temp.r('v_list'), 'x2') -> 'check_state'],
  array[jsonb_build_object('marker_id', pg_temp.uid('lead'), 'marker_name', 'Marker ' || left(pg_temp.uid('lead')::text, 8), 'state', 'taken', 'how', 'next'),
        jsonb_build_object('marker_id', pg_temp.uid('m2'), 'marker_name', 'Marker ' || left(pg_temp.uid('m2')::text, 8), 'state', 'submitted', 'how', null),
        'null'::jsonb, '"waiting_second"'::jsonb],
  'units_list_says_who_has_the_second_pass: the lead holds x2''s (Next script); m2 submitted x1''s; nobody has x4''s; and the piece''s check state');
select is(array(select x ->> 'unit_id' from jsonb_array_elements(pg_temp.r('v_list_m4') -> 'units') x),
  array[pg_temp.u('x3')::text], 'filtered by marker, m4''s pieces are the one whose second pass they hold');

-- ---------------------------------------------------------------------------------------------
-- next_drops_a_held_piece_when_another_kind_stands (controller note c): m3 holds y2's live pass while a second marking
-- of theirs stands on it (written as postgres; the functions never allow it).
-- ---------------------------------------------------------------------------------------------
select pg_temp.script('y2');
select public.marking_unit_take(pg_temp.u('y2'), pg_temp.uid('m3'), 'next', null, now() + interval '2 hours');
insert into public.markings (unit_id, kind, marker_id) values (pg_temp.u('y2'), 'second', pg_temp.uid('m3'));
select tests.as_user(pg_temp.uid('m3'));
insert into res values ('q_next', public.marking_next(pg_temp.k('e')));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('q_next')), public.marking_unit_blocked(pg_temp.u('y2'), pg_temp.uid('m3'), null, true)],
  array['nothing_left', 'not_eligible'],
  'next_drops_a_held_piece_when_another_kind_stands: Next script does not resume y2 for m3: the rule refuses them');
update public.markings set status = 'set_aside', set_aside_at = now(), set_aside_reason = 'given_back'
where unit_id = pg_temp.u('y2') and marker_id = pg_temp.uid('m3') and kind = 'second';
select tests.as_user(pg_temp.uid('m3'));
insert into res values ('q_next2', public.marking_next(pg_temp.k('e')));
select tests.as_postgres();
select is(pg_temp.r('q_next2'), jsonb_build_object('ok', true, 'unit_id', pg_temp.u('y2'), 'resumed', true),
  'once that marking is set aside, the held piece is resumed');

-- ---------------------------------------------------------------------------------------------
-- hand_back_reopens_a_second_marking_whose_pages_changed (marking_units_refresh, Ruling R10): m1 marked h1 and m7's
-- second marking of it is submitted (written as postgres, so m7's key is not held before the hand-back).
-- ---------------------------------------------------------------------------------------------
select pg_temp.script('h1');
select tests.mark_piece(pg_temp.u('h1'), pg_temp.uid('m1'), array[1, 1, 1]);
select pg_temp.wait_second('h1');
with x as (
  insert into public.markings (unit_id, kind, marker_id, status, pages_key, total, last_saved_at, submitted_at)
  values (pg_temp.u('h1'), 'second', pg_temp.uid('m7'), 'submitted', public.marking_pages_key(pg_temp.k('h1')), 3, now(), now())
  returning id)
insert into kv select 'mk7:h1', x.id from x;
select is(pg_temp.marker_lock('m7'), '-', 'hand_back_reopens_a_second_marking_whose_pages_changed: m7''s key is not held yet');
select tests.as_user(pg_temp.uid('admin'));
select public.marking_script_take_back(pg_temp.k('h1'), 'Turn page 1');
select tests.as_postgres();
update public.script_pages set rotation = 90 where id = pg_temp.k('p:h1:1');
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('r_hb', public.marking_script_hand_back(pg_temp.k('h1')));
select tests.as_postgres();
select is(pg_temp.r('r_hb'), '{"ok": true, "state": "marking", "reopened": 2}'::jsonb,
  'the script is handed back with page 1 turned: both markings go back to their markers');
select is((select array[m.status, (m.pages_changed_at is not null)::text] from public.markings m where m.id = pg_temp.k('mk7:h1'))
          || array[pg_temp.holders('h1'), pg_temp.us('h1')],
  array['in_progress', 'true', 'm1 live assigned,m7 second assigned', 'taken'],
  'm7''s second marking is in progress again, marked as changed, with an assigned hold, beside m1''s live one');
select is(pg_temp.marker_lock('m7'), 'ShareLock', 'the hand-back took m7''s key, shared, as a hand-out does');

-- ---------------------------------------------------------------------------------------------
-- assign_takes_over_an_abandoned_second_pass: m5 is given x4's second pass by Next script, opens it, and their hold
-- runs out; an admin then gives the pass to m3.
-- ---------------------------------------------------------------------------------------------
select pg_temp.wait_second('x4');
select tests.as_user(pg_temp.uid('m5'));
insert into res values ('u_next', public.marking_next(pg_temp.k('e')));
select public.marking_unit_open(pg_temp.u('x4'));
select tests.as_postgres();
update public.marking_assignments set hold_until = now() - interval '1 minute'
where unit_id = pg_temp.u('x4') and kind = 'second' and ended_at is null;
select public.marking_holds_expire(null);
insert into res values ('u_before', to_jsonb(pg_temp.ended('x4', 'm5') || ' ' || pg_temp.ms('x4', 'm5')));
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('u_assign', public.marking_assign(array[pg_temp.u('x4')], pg_temp.uid('m3'), 'Give it to m3', 'second'));
select tests.as_postgres();
select is(array[pg_temp.r('u_next') ->> 'unit_id', pg_temp.r('u_before') #>> '{}', pg_temp.r('u_assign')::text],
  array[pg_temp.u('x4')::text, 'expired in_progress', '{"ok": true, "skipped": [], "assigned": 1}'],
  'assign_takes_over_an_abandoned_second_pass: m5''s hold on x4''s second pass ran out with their marking in progress; an admin gives the pass to m3');
select is(array[pg_temp.holders('x4'), pg_temp.ms('x4', 'm5'), pg_temp.ms('x4', 'm3'), pg_temp.us('x4'), pg_temp.ms('x4', 'm1')],
  array['m3 second assigned', 'set_aside expired', 'in_progress', 'submitted', 'submitted'],
  'm5''s marking is set aside (expired) and m3 holds the pass, their own earlier marking in progress again; the first marking stands');

-- ---------------------------------------------------------------------------------------------
-- lead_stays_blind_while_their_second_marking_stands: the lead's hold on x2's second pass runs out with their marking
-- in progress, and x2 is moved on (to_lead, as Task 4 may move it); then they take it up again and submit it, and x2
-- is checked.
-- ---------------------------------------------------------------------------------------------
update public.marking_assignments set hold_until = now() - interval '1 minute'
where unit_id = pg_temp.u('x2') and marker_id = pg_temp.uid('lead') and ended_at is null;
select public.marking_holds_expire(null);
update public.marking_units set check_state = 'to_lead' where id = pg_temp.u('x2');
select tests.as_user(pg_temp.uid('lead'));
insert into res values ('bl_list1', public.marking_units_list(pg_temp.k('e')));
select tests.as_postgres();
select is(array[pg_temp.unit(pg_temp.r('bl_list1'), 'x2') ->> 'total', pg_temp.unit(pg_temp.r('bl_list1'), 'x2') ->> 'submitted_at',
                pg_temp.unit(pg_temp.r('bl_list1'), 'x2') ->> 'last_saved_at', pg_temp.unit(pg_temp.r('bl_list1'), 'x2') ->> 'marker_id',
                pg_temp.unit(pg_temp.r('bl_list1'), 'x2') ->> 'marker_name', pg_temp.unit(pg_temp.r('bl_list1'), 'x2') #>> '{second,state}',
                pg_temp.holders('x2')],
  array[null, null, null, null, null, 'open', '-'],
  'lead_stays_blind_while_their_second_marking_stands: with their second marking in progress and no hold, the lead sees nothing of x2''s first marking');
update public.marking_units set check_state = 'waiting_second' where id = pg_temp.u('x2');
select tests.as_user(pg_temp.uid('lead'));
insert into res values ('bl_next', public.marking_next(pg_temp.k('e')));
insert into res values ('bl_open', public.marking_unit_open(pg_temp.u('x2')));
insert into res values ('bl_save', public.marking_save((pg_temp.r('bl_open') #>> '{marking,id}')::uuid, (pg_temp.r('bl_open') #>> '{marking,rev}')::int,
  pg_temp.all_marks(1, 1, 1)));
insert into res values ('bl_sub', public.marking_submit((pg_temp.r('bl_open') #>> '{marking,id}')::uuid, (pg_temp.r('bl_save') ->> 'rev')::int));
select tests.as_postgres();
update public.marking_units set check_state = 'checked' where id = pg_temp.u('x2');
select tests.as_user(pg_temp.uid('lead'));
insert into res values ('bl_list2', public.marking_units_list(pg_temp.k('e')));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
insert into res values ('bl_admin', public.marking_units_list(pg_temp.k('e')));
select tests.as_postgres();
select is(array[pg_temp.r('bl_next')::text, pg_temp.code(pg_temp.r('bl_sub')),
                pg_temp.unit(pg_temp.r('bl_list2'), 'x2') ->> 'total', pg_temp.unit(pg_temp.r('bl_list2'), 'x2') ->> 'submitted_at',
                pg_temp.unit(pg_temp.r('bl_list2'), 'x2') ->> 'last_saved_at', pg_temp.unit(pg_temp.r('bl_list2'), 'x2') ->> 'marker_id',
                pg_temp.unit(pg_temp.r('bl_list2'), 'x2') ->> 'marker_name', pg_temp.unit(pg_temp.r('bl_list2'), 'x2') #>> '{second,state}'],
  array[jsonb_build_object('ok', true, 'unit_id', pg_temp.u('x2'), 'resumed', true)::text, 'ok', null, null, null, null, null, 'submitted'],
  'Next script gives the lead their marking back and they submit it; with the piece checked, the lead still sees nothing of the first marking');
select is(array[pg_temp.unit(pg_temp.r('bl_admin'), 'x2') ->> 'total', pg_temp.unit(pg_temp.r('bl_admin'), 'x2') ->> 'marker_name',
                (pg_temp.unit(pg_temp.r('bl_admin'), 'x2') ->> 'marker_id' = pg_temp.uid('m1')::text)::text,
                (pg_temp.unit(pg_temp.r('bl_admin'), 'x2') ->> 'last_saved_at' is not null)::text,
                (pg_temp.unit(pg_temp.r('bl_admin'), 'x2') ->> 'submitted_at' is not null)::text],
  array['3.0', 'Mara One', 'true', 'true', 'true'], 'an admin sees the first marking in full');

-- ---------------------------------------------------------------------------------------------
-- second_rule_and_blocked_agree: for every user of c and every piece of e, whatever its state and holders, the rule
-- for one piece (marking_unit_blocked, second) says null exactly when the piece is in the one rule's set
-- (marking_units_allowed, second), for Next script and for an admin's assignment.
-- ---------------------------------------------------------------------------------------------
select is((with nx(p) as (values (true), (false)),
                allowed as materialized (
                  select c.name, nx.p, a.unit_id from c cross join nx
                  cross join lateral public.marking_units_allowed(pg_temp.k('e'), c.id, 'second', nx.p) a)
           select count(*)::int from public.marking_units u cross join c cross join nx
           where u.exam_id = pg_temp.k('e')
             and (public.marking_unit_blocked(u.id, c.id, null, nx.p, 'second') is null)
                 <> exists (select 1 from allowed a where a.name = c.name and a.p = nx.p and a.unit_id = u.id)), 0,
  'second_rule_and_blocked_agree: the two forms of the rule agree on every user and piece, for Next script and for an admin');

-- ---------------------------------------------------------------------------------------------
-- new_helpers_are_internal
-- ---------------------------------------------------------------------------------------------
select is(array(select f from unnest(array[
    'public.marking_pass(uuid, uuid)', 'public.marking_after_submit(uuid)', 'public.marking_after_change(uuid)',
    'public.marking_units_offered(uuid, uuid, uuid, public.marking_kind[])']) f
  where has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute')
     or has_function_privilege('service_role', f, 'execute')), '{}'::text[],
  'new_helpers_are_internal: marking_pass, marking_after_submit, marking_after_change and marking_units_offered cannot be called from the API');

-- ---------------------------------------------------------------------------------------------
-- next_and_left_in_time_at_1500_second_passes (a timing guard, as 043, Ruling R25: the fixture tables are analysed
-- first). Exam eb, marked by question in 5 groups, has 300 marked scripts: m1's live marking of each of the 1,500
-- pieces is submitted (written as postgres) and every piece waits for a second marking. Each timed call runs under the
-- statement_timeout it must meet.
-- ---------------------------------------------------------------------------------------------
insert into c values ('mb', tests.marker(pg_temp.subj()));
insert into kv values ('eb', tests.marking_exam(pg_temp.subj()));
insert into public.question_groups (exam_id, label, position) select pg_temp.k('eb'), 'B' || i, i from generate_series(1, 5) i;
do $$ begin for i in 1..300 loop perform tests.verified_script(pg_temp.k('eb')); end loop; end $$;
update public.exam_marking set mode = 'by_question' where exam_id = pg_temp.k('eb');
select tests.open_marking(pg_temp.k('eb'));
insert into public.markings (unit_id, kind, marker_id, status, total, last_saved_at, submitted_at)
select u.id, 'live', pg_temp.uid('m1'), 'submitted', 1, now(), now() from public.marking_units u where u.exam_id = pg_temp.k('eb');
update public.marking_units set state = 'submitted', check_state = 'waiting_second' where exam_id = pg_temp.k('eb');
update public.scripts set state = 'marked' where exam_id = pg_temp.k('eb');
analyze public.scripts, public.script_pages, public.script_page_links, public.script_versions, public.question_groups,
        public.marking_units, public.marking_assignments, public.markings, public.marking_alerts, public.exam_marking,
        public.marker_approvals, public.marker_conflicts, public.marking_unit_exclusions, public.exams, public.profiles, public.bookings, public.home_submissions,
        public.script_uploads, public.script_exceptions, public.script_page_hidden_areas, public.question_marks, public.tutor_students;
select tests.as_user(pg_temp.uid('mb'));
set local statement_timeout = '2s';
insert into res values ('w_next', public.marking_next(pg_temp.k('eb')));
reset statement_timeout;
set local statement_timeout = '4s';
insert into res values ('w_work', public.marking_my_work());
reset statement_timeout;
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('w_next')), pg_temp.r('w_next') ->> 'resumed',
                (select a.kind::text from public.marking_assignments a where a.marker_id = pg_temp.uid('mb') and a.ended_at is null)],
  array['ok', 'false', 'second'],
  'next_and_left_in_time_at_1500_second_passes: Next script hands mb one of the 1,500 second passes within 2 s');
select is((select e ->> 'left' from jsonb_array_elements(pg_temp.r('w_work') -> 'exams') e where e ->> 'exam_id' = pg_temp.k('eb')::text), '1499',
  'and their list counts the 1,499 left within 4 s');

select * from finish();
rollback;
