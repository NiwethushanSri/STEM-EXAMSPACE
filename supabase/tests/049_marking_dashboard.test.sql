begin;
create extension if not exists pgtap with schema extensions;
select plan(21);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Subject 'ZZ Dashboard': m1 marks it, lead leads it. Exams (tests.marking_exam, titled 'ZZ Dash <name>'),
-- opened here as postgres as marking_open would, their verified home scripts made ready by marking_exam_sync:
--   a: deadline in a day; scripts a1 (submitted), a2 (taken, on hold), a3 (submitted, on hold), a4 (open) and aw
--      (withdrawn after opening, so its piece is on hold and counted nowhere);
--   b: deadline in 3 hours; script b1 (open);
--   c: deadline a day ago, closed 3 days ago (still listed); script c1, assigned to m1 8 days ago;
--   d: closed 20 days ago (not listed); f: settings saved, never opened (not listed);
--   s: no deadline; scripts s1 to s7 held in the ways the stale test describes.
-- The pieces' states, holds, assignments and markings are written directly, as postgres. The local database may hold
-- other exams, so the figures that count every exam (the totals) are compared with a dashboard read before the
-- fixtures, at the same moments (now() stays the same through the transaction).
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values
  ('admin', tests.create_user('admin', 'active')),
  ('teacher', tests.create_user('teacher', 'active')),
  ('m1', tests.create_user('corrector', 'active')),
  ('lead', tests.create_user('corrector', 'active'));
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create temp table res (name text primary key, j jsonb);
grant all on res to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
create function pg_temp.r(p text) returns jsonb language sql stable as $$ select j from res where name = p $$;
create function pg_temp.code(j jsonb) returns text language sql immutable as $$
  select case when (j ->> 'ok')::boolean then 'ok' else coalesce(j ->> 'code', 'none') end $$;
create function pg_temp.s() returns bigint language sql stable as $$ select id from public.subjects where name = 'ZZ Dashboard' $$;
-- A script's piece (the exams are marked as whole scripts: one piece per script).
create function pg_temp.u(p text) returns uuid language sql stable as $$
  select u.id from public.marking_units u where u.script_id = pg_temp.k(p) $$;
-- Exam p's row of dashboard d (null when it is not listed), and one of its fields.
create function pg_temp.row(d text, p text) returns jsonb language sql stable as $$
  select x from jsonb_array_elements(pg_temp.r(d) -> 'exams') x where (x ->> 'exam_id')::uuid = pg_temp.k(p) $$;
create function pg_temp.f(d text, p text, field text) returns text language sql stable as $$
  select pg_temp.row(d, p) ->> field $$;
-- 'left marked on_hold' of exam p in dashboard d.
create function pg_temp.counts(d text, p text) returns text language sql stable as $$
  select pg_temp.f(d, p, 'left') || ' ' || pg_temp.f(d, p, 'marked') || ' ' || pg_temp.f(d, p, 'on_hold') $$;
-- A total of dashboard d less the same total of the dashboard read before the fixtures (base).
create function pg_temp.more(d text, base text, field text) returns int language sql stable as $$
  select (pg_temp.r(d) -> 'totals' ->> field)::int - (pg_temp.r(base) -> 'totals' ->> field)::int $$;
-- A new exam of the subject, kept as p and titled 'ZZ Dash <p>'.
create function pg_temp.exam(p text) returns void language plpgsql as $$
begin
  insert into kv values (p, tests.marking_exam(pg_temp.s()));
  update public.exams set title = 'ZZ Dash ' || p where id = pg_temp.k(p);
end $$;
-- New verified home scripts of exam p_exam, kept by name.
create function pg_temp.scripts(p_exam text, p_names text[]) returns void language sql as $$
  insert into kv select x, tests.verified_script(pg_temp.k(p_exam)) from unnest(p_names) x $$;
-- Opens exam p's marking with that deadline (as marking_open would) and makes its verified scripts ready.
create function pg_temp.open(p text, p_deadline timestamptz) returns void language plpgsql as $$
begin
  insert into public.exam_marking (exam_id, deadline, opened_at, opened_by) values (pg_temp.k(p), p_deadline, now(), pg_temp.uid('admin'));
  perform public.marking_exam_sync(pg_temp.k(p), null);
end $$;
-- Sets a script's piece to a state, on hold (picture_changed) or not.
create function pg_temp.piece(p text, p_state text, p_hold boolean) returns void language sql as $$
  update public.marking_units set state = p_state, on_hold = p_hold, hold_reason = case when p_hold then 'picture_changed' end
  where id = pg_temp.u(p) $$;
-- An assignment of a script's piece to m1, made p_ago before now().
create function pg_temp.assign(p text, p_how text, p_ago interval) returns void language sql as $$
  insert into public.marking_assignments (unit_id, kind, marker_id, how, assigned_by, hold_until, created_at)
  values (pg_temp.u(p), 'live', pg_temp.uid('m1'), p_how, case when p_how = 'assigned' then pg_temp.uid('admin') end,
          case when p_how = 'next' then now() - p_ago + interval '2 hours' end, now() - p_ago) $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.r(text), pg_temp.code(jsonb) to public;

-- The dashboard before the fixtures, at each moment the tests read it.
select tests.as_user(pg_temp.uid('admin'));
insert into res values
  ('base', public.marking_dashboard()),
  ('base:b-1', public.marking_dashboard(now() + interval '3 hours' - interval '1 second')),
  ('base:b+1', public.marking_dashboard(now() + interval '3 hours' + interval '1 second')),
  ('base:7d', public.marking_dashboard(now() + interval '1 day')),
  ('base:7d+1', public.marking_dashboard(now() + interval '1 day' + interval '1 second'));
select tests.as_postgres();

insert into public.subjects (name, kind) values ('ZZ Dashboard', 'school');
insert into public.marker_approvals (marker_id, subject_id, lead, approved_at)
select c.id, pg_temp.s(), c.name = 'lead', now() from c where c.name in ('m1', 'lead');

select pg_temp.exam(x) from unnest(array['a', 'b', 'c', 'd', 'f', 's']) x;
select pg_temp.scripts('a', array['a1', 'a2', 'a3', 'a4', 'aw']);
select pg_temp.scripts('b', array['b1']);
select pg_temp.scripts('c', array['c1']);
select pg_temp.scripts('d', array['d1']);
select pg_temp.scripts('s', array['s1', 's2', 's3', 's4', 's5', 's6', 's7']);
select pg_temp.open('a', now() + interval '1 day');
select pg_temp.open('b', now() + interval '3 hours');
select pg_temp.open('c', now() - interval '1 day');
select pg_temp.open('d', null);
select pg_temp.open('s', null);
insert into public.exam_marking (exam_id) values (pg_temp.k('f'));
update public.exam_marking set closed_at = now() - interval '3 days', closed_by = pg_temp.uid('admin') where exam_id = pg_temp.k('c');
update public.exam_marking set closed_at = now() - interval '20 days', closed_by = pg_temp.uid('admin') where exam_id = pg_temp.k('d');

select pg_temp.piece('a1', 'submitted', false);
select pg_temp.piece('a2', 'taken', true);
select pg_temp.piece('a3', 'submitted', true);
update public.scripts set state = 'withdrawn' where id = pg_temp.k('aw');

-- s1: assigned 8 days ago, never saved. s2: assigned 8 days ago, saved 2 days ago. s3: assigned 8 days ago, last saved
-- 8 days ago. s4: taken with Next script 8 days ago (a hold, not an assignment). s5: assigned 8 days ago, on hold. s6:
-- assigned 6 days ago. s7: assigned 8 days ago and taken back since. c1: assigned 8 days ago, but c's marking is closed.
select pg_temp.assign(x, 'assigned', interval '8 days') from unnest(array['s1', 's2', 's3', 's5', 's7', 'c1']) x;
select pg_temp.assign('s4', 'next', interval '8 days');
select pg_temp.assign('s6', 'assigned', interval '6 days');
select pg_temp.piece(x, 'taken', x = 's5') from unnest(array['s1', 's2', 's3', 's4', 's5', 's6', 'c1']) x;
update public.marking_assignments set ended_at = now() - interval '7 days', end_reason = 'taken_back' where unit_id = pg_temp.u('s7');
insert into public.markings (unit_id, kind, marker_id, started_at, last_saved_at)
values (pg_temp.u('s2'), 'live', pg_temp.uid('m1'), now() - interval '8 days', now() - interval '2 days'),
       (pg_temp.u('s3'), 'live', pg_temp.uid('m1'), now() - interval '8 days', now() - interval '8 days');

select is((select count(*)::int from public.marking_units u join kv on kv.id = u.script_id), 15,
  'fixture: every script of the opened exams has its one piece');

select tests.as_user(pg_temp.uid('admin'));
insert into res values
  ('d', public.marking_dashboard()),
  ('d:b-1', public.marking_dashboard(now() + interval '3 hours' - interval '1 second')),
  ('d:b+1', public.marking_dashboard(now() + interval '3 hours' + interval '1 second')),
  ('d:7d', public.marking_dashboard(now() + interval '1 day')),
  ('d:7d+1', public.marking_dashboard(now() + interval '1 day' + interval '1 second')),
  ('d:year', public.marking_dashboard(now() + interval '1 year'));
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- dashboard_counts_left_marked_and_on_hold
-- ---------------------------------------------------------------------------------------------
select is(pg_temp.counts('d', 'a'), '2 2 2',
  'dashboard_counts_left_marked_and_on_hold: left counts the pieces not submitted (a2, a4), marked the submitted (a1, a3), on hold both held pieces; the withdrawn script counts nowhere');
select is(pg_temp.counts('d', 'b'), '1 0 0', 'an exam with one open piece: 1 left');
select is(array(select x ->> 'title' from jsonb_array_elements(pg_temp.r('d') -> 'exams') x
                where (x ->> 'exam_id')::uuid in (select id from kv) order by x ->> 'title'),
  array['ZZ Dash a', 'ZZ Dash b', 'ZZ Dash c', 'ZZ Dash s'],
  'exams whose marking is open, or closed in the last 14 days, are listed; one closed 20 days ago or never opened is not');
select is(array[pg_temp.f('d', 'a', 'title'), pg_temp.f('d', 'a', 'paper'), (pg_temp.f('d', 'a', 'deadline')::timestamptz = now() + interval '1 day')::text],
  array['ZZ Dash a', 'Paper 1', 'true'], 'each row names the exam, its paper and its deadline');
select is(array[(pg_temp.r('d') -> 'totals' ->> 'left')::int, (pg_temp.r('d') -> 'totals' ->> 'on_hold')::int],
  array[(select sum((x ->> 'left')::int)::int from jsonb_array_elements(pg_temp.r('d') -> 'exams') x),
        (select sum((x ->> 'on_hold')::int)::int from jsonb_array_elements(pg_temp.r('d') -> 'exams') x)],
  'the totals left and on hold add up the listed exams');
select is(array[pg_temp.more('d', 'base', 'left'), pg_temp.more('d', 'base', 'on_hold')], array[2 + 1 + 1 + 7, 2 + 1],
  'these exams add 11 pieces left (a 2, b 1, c 1, s 7) and 3 on hold (a 2, s 1)');

-- ---------------------------------------------------------------------------------------------
-- overdue_only_after_the_deadline_with_work_left
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.f('d:b-1', 'b', 'overdue'), pg_temp.f('d:b+1', 'b', 'overdue')], array['false', 'true'],
  'overdue_only_after_the_deadline_with_work_left: b is not overdue a second before its deadline, and is a second after');
select is(array[pg_temp.more('d:b-1', 'base:b-1', 'overdue_exams'), pg_temp.more('d:b+1', 'base:b+1', 'overdue_exams')], array[0, 1],
  'overdue_exams counts it from then');
select is(array[pg_temp.f('d:b+1', 'c', 'overdue'), pg_temp.f('d:b+1', 'a', 'overdue')], array['false', 'false'],
  'c is past its deadline with a piece left, but its marking is closed; a''s deadline has not come');
select is(pg_temp.f('d:year', 's', 'overdue'), 'false', 'an exam with no deadline is never overdue');

select pg_temp.piece('b1', 'submitted', false);
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('d:b+1 done', public.marking_dashboard(now() + interval '3 hours' + interval '1 second'));
select tests.as_postgres();
select is(array[pg_temp.f('d:b+1 done', 'b', 'overdue'), pg_temp.more('d:b+1 done', 'base:b+1', 'overdue_exams')::text], array['false', '0'],
  'once every piece of b is submitted it is no longer overdue');

-- ---------------------------------------------------------------------------------------------
-- stale_assigned_after_7_days
-- ---------------------------------------------------------------------------------------------
select is(pg_temp.more('d', 'base', 'stale_assigned'), 2,
  'stale_assigned_after_7_days: s1 (never saved) and s3 (last saved 8 days ago); not one saved since, held by Next script, on hold, taken back, or of a closed exam');
select is(array[pg_temp.more('d:7d', 'base:7d', 'stale_assigned'), pg_temp.more('d:7d+1', 'base:7d+1', 'stale_assigned')], array[2, 3],
  'a piece assigned exactly 7 days ago with no save is not yet counted; a second later it is (s6)');

-- ---------------------------------------------------------------------------------------------
-- The open marking alerts and the marking pictures that wait for staff.
-- ---------------------------------------------------------------------------------------------
insert into public.marking_alerts (exam_id, kind, script_id) values (pg_temp.k('a'), 'picture_changed', pg_temp.k('a2')),
  (pg_temp.k('a'), 'pages_changed', pg_temp.k('a3'));
insert into public.marking_alerts (exam_id, kind, script_id, state, closed_by, closed_at, resolution, reason)
values (pg_temp.k('a'), 'picture_changed', pg_temp.k('a1'), 'closed', pg_temp.uid('lead'), now(), 'released', 'Pictures checked');
-- Staff accepted page 2 of a4, and its marking picture is not checked yet.
insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details, state, resolution, resolved_by, resolved_at)
select s.exam_id, 'poor_quality', s.booking_id, s.id, l.page_id, p.upload_id, '{"flags": ["layout_unexpected"]}'::jsonb,
  'resolved', 'confirmed', pg_temp.uid('admin'), now()
from public.scripts s
join public.script_page_links l on l.script_id = s.id and l.version = s.version and l.copy_page = 2
join public.script_pages p on p.id = l.page_id
where s.id = pg_temp.k('a4');
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('d2', public.marking_dashboard()), ('checks', public.script_marking_checks_list());
select tests.as_postgres();

select is(array[pg_temp.more('d2', 'base', 'alerts_open'), (pg_temp.r('d2') -> 'totals' ->> 'alerts_open')::int],
  array[2, (select count(*)::int from public.marking_alerts a join public.exams e on e.id = a.exam_id
            join public.scripts s on s.id = a.script_id where a.state = 'open')],
  'alerts_open counts every open marking alert (2 more here; the closed one is not counted)');
select is(pg_temp.more('d2', 'base', 'pictures_to_check'), 1, 'pictures_to_check counts the marking picture staff must check');
select is((pg_temp.r('d2') -> 'totals' ->> 'pictures_to_check')::int, jsonb_array_length(pg_temp.r('checks') -> 'items'),
  'it is what the list of marking pictures to check shows');

update public.script_pages p set marking_checked_path = p.marking_path, marking_checked_by = pg_temp.uid('admin'), marking_checked_at = now()
from public.scripts s join public.script_page_links l on l.script_id = s.id and l.version = s.version and l.copy_page = 2
where s.id = pg_temp.k('a4') and p.id = l.page_id;
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('d3', public.marking_dashboard());
select tests.as_postgres();
select is(pg_temp.more('d3', 'base', 'pictures_to_check'), 0, 'once staff check the picture it is no longer counted');

-- ---------------------------------------------------------------------------------------------
-- admins_only
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('teacher'));
insert into res values ('teacher', public.marking_dashboard());
select tests.as_postgres();
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('m1', public.marking_dashboard());
select tests.as_postgres();
select tests.as_user(pg_temp.uid('lead'));
insert into res values ('lead', public.marking_dashboard());
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('teacher')), pg_temp.code(pg_temp.r('m1')), pg_temp.code(pg_temp.r('lead'))],
  array['forbidden', 'forbidden', 'forbidden'], 'admins_only: a teacher, a marker and a lead marker are refused');
select is(array[has_function_privilege('anon', 'public.marking_dashboard(timestamptz)', 'execute'),
                has_function_privilege('authenticated', 'public.marking_dashboard(timestamptz)', 'execute')],
  array[false, true], 'signed-out visitors cannot call it; signed-in staff can, and it checks for an admin');
select is(array[has_function_privilege('authenticated', 'public.script_marking_checks_due(uuid)', 'execute'),
                has_function_privilege('service_role', 'public.script_marking_checks_due(uuid)', 'execute')],
  array[false, false], 'the pages-to-check helper is internal');

select * from finish();
rollback;
