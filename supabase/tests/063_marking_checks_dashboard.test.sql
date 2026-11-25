begin;
create extension if not exists pgtap with schema extensions;
select plan(32);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Subject 'ZZ Chk3': markers m1, m2 and m3, and its lead marker; 'ZZ Chk3 Two': its lead marker x1 and one
-- more marker x2 (two markers in all); 'ZZ Chk3 Gone': a lead marker who is then suspended. An admin, a teacher and a
-- corrector never approved. Every exam has the test structure (1 of 3 marks, 2(a) of 2, 2(b) of 5) except q.
--   e:  ('ZZ Chk3') double marking on at 100%, tolerance 10%. m1 marks ck1, ck2, df1 and ws1 (1, 1, 1); m2 second-marks
--       ck1 and ck2 the same (checked) and df1 with 3, 2, 5 (outside: with the lead marker); ws1 waits for a second
--       marker whom m2 or the lead could be. The lead pauses m3 (who marked nothing).
--   g:  ('ZZ Chk3 Two') double marking on at 100%. x1, the lead, marks gst1; x2 then declares a conflict for its
--       candidate, so nobody can second-mark it (Review Focus 2).
--   r:  checks off; r1 marked by m1 (checked): nothing blocks its approval.
--   r2: checks off; r2a marked by m1, r2b not yet (it blocks), then marked.
--   ap: checks off; ap1 marked by m1, then the admin approves the exam's marking; then a late script arrives.
--   q:  marked by question (two groups, so two pieces a script); q1's two pieces and one of q2's are on hold; q1 has two
--       open alerts, q2 one.
--   mw: checks off; m1 marks mw1 and mw2 and holds mw4; m2 marks mw5; then mw2 is withdrawn and mw5 made void.
-- The local database may hold other exams, so the totals are compared with a dashboard read before the fixtures (as
-- 049): now() stays the same through the transaction.
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create temp table res (name text primary key, j jsonb);
grant all on res to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
create function pg_temp.r(p text) returns jsonb language sql stable as $$ select j from res where name = p $$;
create function pg_temp.subj(p text) returns bigint language sql stable as $$ select id from public.subjects where name = p $$;
create function pg_temp.code(j jsonb) returns text language sql immutable as $$
  select case when (j ->> 'ok')::boolean then 'ok' else coalesce(j ->> 'code', 'none') end $$;
-- A script's piece (whole scripts: one piece a script).
create function pg_temp.u(p text) returns uuid language sql stable security definer as $$
  select u.id from public.marking_units u where u.script_id = pg_temp.k(p) $$;
create function pg_temp.student(p text) returns uuid language sql stable security definer as $$
  select b.student_id from public.scripts s join public.bookings b on b.id = s.booking_id where s.id = pg_temp.k(p) $$;
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
create function pg_temp.dash() returns jsonb language sql as $$ select pg_temp.as('admin', 'select public.marking_dashboard()') $$;
create function pg_temp.progress(p_who text, p_exam text default null) returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.marking_progress(%L)', pg_temp.k(p_exam))) $$;
-- Exam p's row of dashboard d; a field of it; a total of d less the same total of the base read before the fixtures.
create function pg_temp.row(d text, p text) returns jsonb language sql stable as $$
  select x from jsonb_array_elements(pg_temp.r(d) -> 'exams') x where (x ->> 'exam_id')::uuid = pg_temp.k(p) $$;
create function pg_temp.f(d text, p text, field text) returns text language sql stable as $$
  select pg_temp.row(d, p) ->> field $$;
create function pg_temp.more(d text, field text) returns int language sql stable as $$
  select (pg_temp.r(d) -> 'totals' ->> field)::int - (pg_temp.r('base') -> 'totals' ->> field)::int $$;
-- Exam p's entry in a progress answer.
create function pg_temp.pe(d text, p text) returns jsonb language sql stable as $$
  select x from jsonb_array_elements(pg_temp.r(d) -> 'exams') x where (x ->> 'exam_id')::uuid = pg_temp.k(p) $$;
-- New verified home scripts of an exam, made ready when its marking is open, kept by name.
create function pg_temp.scripts(p_exam text, p_names text[]) returns void language plpgsql as $$
begin
  insert into kv select x, tests.verified_script(pg_temp.k(p_exam)) from unnest(p_names) x;
  perform public.marking_exam_sync(pg_temp.k(p_exam), null);
end $$;
-- The first marking of a script's piece (tests.mark_piece), and a second one: its second pass taken as Next script
-- would, then marked and submitted.
create function pg_temp.first(p text, p_marker text, p_marks numeric[]) returns void language plpgsql as $$
begin
  perform tests.mark_piece(pg_temp.u(p), pg_temp.uid(p_marker), p_marks);
end $$;
create function pg_temp.second(p text, p_marker text, p_marks numeric[]) returns void language plpgsql as $$
declare
  v_why text := public.marking_unit_blocked(pg_temp.u(p), pg_temp.uid(p_marker), null, true, 'second');
begin
  if v_why is not null then
    raise exception 'pg_temp.second: % cannot be given the second pass (%)', p_marker, v_why;
  end if;
  perform public.marking_unit_take(pg_temp.u(p), pg_temp.uid(p_marker), 'next', null, now() + interval '2 hours', 'second');
  perform tests.mark_piece(pg_temp.u(p), pg_temp.uid(p_marker), p_marks);
end $$;

-- The dashboard before the fixtures.
insert into c values ('admin', tests.create_user('admin', 'active'));
insert into res values ('base', pg_temp.dash());

insert into public.subjects (name, kind) values ('ZZ Chk3', 'school'), ('ZZ Chk3 Two', 'school'), ('ZZ Chk3 Gone', 'school');
insert into c values ('teacher', tests.create_user('teacher', 'active')), ('corr', tests.create_user('corrector', 'active')),
  ('m1', tests.marker(pg_temp.subj('ZZ Chk3'))), ('m2', tests.marker(pg_temp.subj('ZZ Chk3'))),
  ('m3', tests.marker(pg_temp.subj('ZZ Chk3'))), ('lead', tests.marker(pg_temp.subj('ZZ Chk3'), true)),
  ('x1', tests.marker(pg_temp.subj('ZZ Chk3 Two'), true)), ('x2', tests.marker(pg_temp.subj('ZZ Chk3 Two'))),
  ('gone', tests.marker(pg_temp.subj('ZZ Chk3 Gone'), true));
update public.profiles set status = 'suspended' where id = pg_temp.uid('gone');

insert into kv select x, tests.marking_exam(pg_temp.subj('ZZ Chk3')) from unnest(array['e', 'r', 'r2', 'ap', 'q', 'mw']) x;
insert into kv values ('g', tests.marking_exam(pg_temp.subj('ZZ Chk3 Two')));
select tests.structure(pg_temp.k(x)) from unnest(array['e', 'g', 'r', 'r2', 'ap', 'mw']) x;

-- Exam e.
select tests.open_marking(pg_temp.k('e'), '{"double_marking": true, "sample_percent": 100, "tolerance_percent": 10}');
select pg_temp.scripts('e', array['ck1', 'ck2', 'df1', 'ws1']);
select pg_temp.first(x, 'm1', array[1, 1, 1]) from unnest(array['ck1', 'ck2', 'df1', 'ws1']) x;
select pg_temp.second(x, 'm2', array[1, 1, 1]) from unnest(array['ck1', 'ck2']) x;
select pg_temp.second('df1', 'm2', array[3, 2, 5]);
insert into res values ('pause_m3', pg_temp.as('lead', format($q$ select public.marking_marker_pause(%L, %L, 'Marks to look at together.') $q$,
  pg_temp.k('e'), pg_temp.uid('m3'))));

-- Exam g: before x2's conflict, x2 could second-mark gst1.
select tests.open_marking(pg_temp.k('g'), '{"double_marking": true, "sample_percent": 100}');
select pg_temp.scripts('g', array['gst1']);
select pg_temp.first('gst1', 'x1', array[1, 1, 1]);
insert into res values ('x1_before', pg_temp.progress('x1', 'g'));
insert into public.marker_conflicts (marker_id, student_id, recorded_at) values (pg_temp.uid('x2'), pg_temp.student('gst1'), now());

-- Exams r, r2 and ap.
select tests.open_marking(pg_temp.k(x)) from unnest(array['r', 'r2', 'ap', 'mw']) x;
select pg_temp.scripts('r', array['r1']);
select pg_temp.scripts('r2', array['r2a', 'r2b']);
select pg_temp.scripts('ap', array['ap1']);
select pg_temp.first(x, 'm1', array[1, 1, 1]) from unnest(array['r1', 'r2a', 'ap1']) x;
insert into res values ('approve_ap', pg_temp.as('admin', format('select public.marking_approve(%L)', pg_temp.k('ap'))));

-- Exam q, marked by question.
with g as (insert into public.question_groups (exam_id, label, position) values (pg_temp.k('q'), 'G1', 1), (pg_temp.k('q'), 'G2', 2) returning id)
select count(*) from g;
update public.exam_marking set mode = 'by_question' where exam_id = pg_temp.k('q');
select tests.open_marking(pg_temp.k('q'));
select pg_temp.scripts('q', array['q1', 'q2']);
update public.marking_units u set on_hold = true, hold_reason = 'picture_changed'
where u.script_id = pg_temp.k('q1')
   or u.id = (select x.id from public.marking_units x where x.script_id = pg_temp.k('q2') order by x.id limit 1);
insert into public.marking_alerts (exam_id, kind, script_id, state)
values (pg_temp.k('q'), 'picture_changed', pg_temp.k('q1'), 'open'), (pg_temp.k('q'), 'pages_changed', pg_temp.k('q1'), 'open'),
       (pg_temp.k('q'), 'picture_changed', pg_temp.k('q2'), 'open');

-- Exam mw.
select pg_temp.scripts('mw', array['mw1', 'mw2', 'mw4', 'mw5']);
select pg_temp.first(x, 'm1', array[1, 1, 1]) from unnest(array['mw1', 'mw2']) x;
select pg_temp.first('mw5', 'm2', array[1, 1, 1]);
select public.marking_unit_take(pg_temp.u('mw4'), pg_temp.uid('m1'), 'next', null, now() + interval '2 hours');
update public.scripts set state = 'withdrawn' where id = pg_temp.k('mw2');
update public.scripts set state = 'void' where id = pg_temp.k('mw5');

select is(array[(select string_agg(coalesce(u.check_state, '-'), ' ' order by s.number)
                 from public.marking_units u join public.scripts s on s.id = u.script_id where u.exam_id = pg_temp.k('e')),
                (select coalesce(check_state, '-') from public.marking_units where id = pg_temp.u('gst1')),
                pg_temp.code(pg_temp.r('pause_m3')), pg_temp.code(pg_temp.r('approve_ap')),
                (select count(*)::text from public.marking_units u where u.exam_id = pg_temp.k('q') and u.on_hold)],
  array['checked checked to_lead waiting_second', 'waiting_second', 'ok', 'ok', '3'],
  'fixture: e is checked twice, with the lead once and waiting once; gst1 waits; m3 paused; ap approved; 3 of q''s pieces on hold');

insert into res values ('d', pg_temp.dash()), ('lead', pg_temp.progress('lead')), ('x1', pg_temp.progress('x1')),
  ('admin_mw', pg_temp.progress('admin', 'mw'));

-- ---------------------------------------------------------------------------------------------
-- dashboard_counts_checked_with_lead_and_waiting
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.f('d', 'e', 'checked'), pg_temp.f('d', 'e', 'with_lead'), pg_temp.f('d', 'e', 'waiting_second'),
                pg_temp.f('d', 'e', 'left'), pg_temp.f('d', 'e', 'marked')],
  array['2', '1', '1', '0', '4'],
  'dashboard_counts_checked_with_lead_and_waiting: e has 2 pieces checked, 1 with the lead marker, 1 waiting for a second marker (all 4 marked)');
select is(array[pg_temp.f('d', 'g', 'checked'), pg_temp.f('d', 'g', 'with_lead'), pg_temp.f('d', 'g', 'waiting_second'),
                pg_temp.f('d', 'r', 'checked'), pg_temp.f('d', 'r2', 'checked')],
  array['0', '0', '1', '1', '1'], 'g has its one piece waiting; r and r2 one checked each');
select is(array[pg_temp.more('d', 'with_lead'), pg_temp.more('d', 'waiting_second'), pg_temp.more('d', 'markers_paused')],
  array[1, 2, 1], 'the totals add 1 with the lead marker, 2 waiting for a second marker (e and g) and 1 paused marker (m3)');
select is(array[(pg_temp.r('d') -> 'totals' ->> 'with_lead')::int, (pg_temp.r('d') -> 'totals' ->> 'waiting_second')::int],
  array[(select sum((x ->> 'with_lead')::int)::int from jsonb_array_elements(pg_temp.r('d') -> 'exams') x),
        (select sum((x ->> 'waiting_second')::int)::int from jsonb_array_elements(pg_temp.r('d') -> 'exams') x)],
  'the totals with the lead marker and waiting add up the listed exams');
select is(array[pg_temp.pe('lead', 'e') #>> '{scripts,checked}', pg_temp.pe('lead', 'e') #>> '{scripts,marked}',
                pg_temp.pe('lead', 'e') #>> '{checks,waiting_second}', pg_temp.pe('lead', 'e') #>> '{checks,with_lead}',
                pg_temp.pe('lead', 'e') #>> '{checks,stuck_second}', pg_temp.pe('lead', 'e') #>> '{checks,paused_markers}',
                coalesce(pg_temp.pe('lead', 'e') #>> '{checks,approved_at}', 'none')],
  array['2', '4', '1', '1', '0', '1', 'none'],
  'the lead''s progress of e: 2 scripts checked (of the 4 marked or checked), 1 piece waiting, 1 with the lead, none stuck, 1 marker paused, not approved');
select is(pg_temp.pe('lead', 'r') #>> '{scripts,checked}', '1', 'r: its one script is checked');

-- ---------------------------------------------------------------------------------------------
-- waiting_piece_nobody_can_second_is_counted_as_stuck
-- ---------------------------------------------------------------------------------------------
select is(pg_temp.pe('x1_before', 'g') #>> '{checks,stuck_second}', '0',
  'waiting_piece_nobody_can_second_is_counted_as_stuck: before x2''s conflict, x2 could second-mark gst1: not stuck');
select is(array[pg_temp.more('d', 'stuck_second'), (pg_temp.pe('x1', 'g') #>> '{checks,stuck_second}')::int],
  array[1, 1], 'once x2 has a declared conflict for its candidate (and x1 marked it first), nobody can: stuck 1 on the dashboard and in the lead''s progress');
select is(pg_temp.pe('lead', 'e') #>> '{checks,stuck_second}', '0', 'ws1, which m2 or the lead could second-mark, is not stuck');

-- ---------------------------------------------------------------------------------------------
-- ready_to_approve_only_when_nothing_blocks
-- ---------------------------------------------------------------------------------------------
select is(pg_temp.more('d', 'ready_to_approve'), 1,
  'ready_to_approve_only_when_nothing_blocks: only r (r2 has a script to mark; e, g, q and mw are blocked; ap is approved)');
select is(array[pg_temp.f('d', 'ap', 'approved'), pg_temp.f('d', 'r', 'approved')], array['true', 'false'],
  'each exam row says whether its marking is approved');
select pg_temp.first('r2b', 'm1', array[1, 1, 1]);
insert into res values ('d_r2', pg_temp.dash());
select is(pg_temp.more('d_r2', 'ready_to_approve'), 2, 'once r2b is marked and checked, r2 is ready too');
select is(pg_temp.as('admin', format('select public.marking_approval_get(%L)', pg_temp.k('r2'))) ->> 'can_approve', 'true',
  'as the approval page says');

-- ---------------------------------------------------------------------------------------------
-- approved_stale_counts_a_late_script
-- ---------------------------------------------------------------------------------------------
select is(pg_temp.more('d', 'approved_stale'), 0, 'approved_stale_counts_a_late_script: ap''s approval is not stale while nothing blocks it');
insert into kv values ('ap_late', tests.verified_script(pg_temp.k('ap')));
insert into res values ('d_late', pg_temp.dash());
select is(array[pg_temp.more('d_late', 'approved_stale'), pg_temp.more('d_late', 'ready_to_approve')], array[1, 2],
  'a script verified after the approval makes it stale; it is not ready to approve again');
select is(pg_temp.as('admin', format('select public.marking_approval_get(%L)', pg_temp.k('ap'))) ->> 'stale', 'true',
  'as the approval page says');
update public.exam_marking set closed_at = now() - interval '20 days' where exam_id = pg_temp.k('ap');
insert into res values ('d_old', pg_temp.dash());
select is(array[coalesce(pg_temp.f('d_old', 'ap', 'title'), 'not listed'), pg_temp.more('d_old', 'approved_stale')::text],
  array['not listed', '1'], 'a stale approval is counted even once the exam is no longer listed (closed more than 14 days ago)');

-- ---------------------------------------------------------------------------------------------
-- on_hold_counts_scripts_not_pieces
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.f('d', 'q', 'on_hold')::int, pg_temp.more('d', 'on_hold')], array[2, 2],
  'on_hold_counts_scripts_not_pieces: q''s three pieces on hold are of two scripts: 2 on its row and in the total');
select is(pg_temp.more('d', 'alerts_open'), 2, 'alerts_open counts the scripts with an open alert: q1''s two alerts count once');
select is((pg_temp.r('d') -> 'totals' ->> 'alerts_open')::int,
  (select count(distinct a.script_id)::int from public.marking_alerts a join public.exams e on e.id = a.exam_id
   join public.scripts s on s.id = a.script_id where a.state = 'open'),
  'it is the number of scripts with an open marking alert, of any exam');
select is(pg_temp.f('d', 'q', 'left'), '4', 'the pieces left still count pieces');

-- ---------------------------------------------------------------------------------------------
-- marker_counts_leave_out_withdrawn_scripts
-- ---------------------------------------------------------------------------------------------
select is((select string_agg((x ->> 'marker_id')::uuid::text || ' ' || (x ->> 'taken') || ' ' || (x ->> 'submitted'), ',')
           from jsonb_array_elements(pg_temp.pe('admin_mw', 'mw') -> 'markers') x),
  pg_temp.uid('m1')::text || ' 1 1',
  'marker_counts_leave_out_withdrawn_scripts: m1 holds mw4 and submitted mw1 (mw2 is withdrawn); m2, whose only script is void, is not listed');
select is(pg_temp.pe('admin_mw', 'mw') #>> '{units,submitted}', '1', 'as the pieces of the exam count them');

-- ---------------------------------------------------------------------------------------------
-- admins_only_and_lead_own_subject
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.code(pg_temp.as('teacher', 'select public.marking_dashboard()')),
                pg_temp.code(pg_temp.as('m1', 'select public.marking_dashboard()')),
                pg_temp.code(pg_temp.as('lead', 'select public.marking_dashboard()'))],
  array['forbidden', 'forbidden', 'forbidden'], 'admins_only_and_lead_own_subject: the dashboard refuses a teacher, a marker and a lead marker');
select is(array[pg_temp.code(pg_temp.progress('m1')), pg_temp.code(pg_temp.progress('corr')), pg_temp.code(pg_temp.progress('gone')),
                pg_temp.code(pg_temp.progress('lead', 'g')), pg_temp.code(pg_temp.progress('x1', 'e'))],
  array['forbidden', 'forbidden', 'forbidden', 'forbidden', 'forbidden'],
  'the progress refuses a marker, a corrector never approved and a suspended lead, and a lead asking for another subject''s exam');
select is(array[pg_temp.pe('lead', 'e') is not null, pg_temp.pe('lead', 'g') is null, pg_temp.pe('x1', 'g') is not null, pg_temp.pe('x1', 'e') is null,
                (select bool_and(e.subject_id = pg_temp.subj('ZZ Chk3')) from jsonb_array_elements(pg_temp.r('lead') -> 'exams') x
                 join public.exams e on e.id = (x ->> 'exam_id')::uuid)],
  array[true, true, true, true, true], 'a lead marker''s progress lists the exams of the subject they lead only');
select is(array[has_function_privilege('anon', 'public.marking_dashboard(timestamptz)', 'execute'),
                has_function_privilege('authenticated', 'public.marking_dashboard(timestamptz)', 'execute'),
                has_function_privilege('anon', 'public.marking_progress(uuid, timestamptz)', 'execute'),
                has_function_privilege('authenticated', 'public.marking_progress(uuid, timestamptz)', 'execute')],
  array[false, true, false, true], 'signed-out visitors can call neither; signed-in staff can, and each checks who they are');

-- The light lead flag for the teacher's and corrector's menus (Task 8, M4).
select is(array[pg_temp.as('lead', 'select to_jsonb(public.marking_is_lead())'), pg_temp.as('x1', 'select to_jsonb(public.marking_is_lead())'),
                pg_temp.as('m1', 'select to_jsonb(public.marking_is_lead())'), pg_temp.as('admin', 'select to_jsonb(public.marking_is_lead())'),
                pg_temp.as('teacher', 'select to_jsonb(public.marking_is_lead())'), pg_temp.as('gone', 'select to_jsonb(public.marking_is_lead())')]::text[],
  array['true', 'true', 'false', 'false', 'false', 'false'],
  'lead_flag_says_whether_the_caller_leads_a_subject: two leads yes; a marker, an admin, a teacher and a suspended lead no');
select is((select (w ->> 'lead_subjects') <> '[]' from (select pg_temp.as(x, 'select public.marking_my_work()') as w) t),
  (select pg_temp.as(x, 'select to_jsonb(public.marking_is_lead())')::text::boolean), 'for ' || x || ' it agrees with marking_my_work''s lead subjects')
from unnest(array['lead', 'm1']) x;
select is(array[has_function_privilege('anon', 'public.marking_is_lead()', 'execute'),
                has_function_privilege('authenticated', 'public.marking_is_lead()', 'execute')],
  array[false, true], 'signed-out visitors cannot ask it');

select * from finish();
rollback;
