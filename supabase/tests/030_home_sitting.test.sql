begin;
create extension if not exists pgtap with schema extensions;
select plan(60);
select tests.assert_no_owner();

-- Fixtures. Exam e: home and centre, 2031-06-07 10:00 London (09:00 UTC), 90 minutes: finish 10:30 UTC.
-- Family 1: parent p1 with students s1 (home booking b1) and s4 (centre booking b4). Student s2 has no parent (b2).
-- Family 2: parent p2, student s3 (b3). b5: unpaid home booking (s5). d: a draft exam.
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('admin', tests.create_user('admin', 'active')), ('teacher', tests.create_user('teacher', 'active')),
  ('teacher2', tests.create_user('teacher', 'active')), ('p1', tests.create_user('parent', 'active')), ('p2', tests.create_user('parent', 'active'));
insert into c select 's' || i, tests.create_user('student', 'active') from generate_series(1, 5) i;
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
create function pg_temp.ts(p text) returns timestamptz language sql immutable as $$ select p::timestamptz $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.ts(text) to public;

update public.profiles set first_name = 'Pat', last_name = 'Tester' where id = pg_temp.uid('p1');
insert into public.parent_children values (pg_temp.uid('p1'), pg_temp.uid('s1')), (pg_temp.uid('p1'), pg_temp.uid('s4')), (pg_temp.uid('p2'), pg_temp.uid('s3'));
insert into public.subjects (name, kind) values ('ZZ Sitting', 'school');
insert into public.venues (name, rooms) values ('ZZ Sitting hall', array['R1']);
insert into public.exams (subject_id, title, paper, format, starts_at, duration_minutes, price_pence, price_confirmed, booking_deadline, status)
select s.id, 'ZZS ' || t.n, 'P', 'both', t.st, 90, 0, true, '2031-06-06 10:00 Europe/London', t.status::public.exam_status
from public.subjects s, (values ('e', '2031-06-07 10:00 Europe/London'::timestamptz, 'published'), ('d', '2031-06-08 10:00 Europe/London'::timestamptz, 'draft')) t(n, st, status)
where s.name = 'ZZ Sitting';
insert into kv select substr(e.title, 5), e.id from public.exams e join public.subjects s on s.id = e.subject_id where s.name = 'ZZ Sitting';
insert into public.teacher_subjects select pg_temp.uid('teacher'), id from public.subjects where name = 'ZZ Sitting';
insert into public.exam_centres (exam_id, venue_id, room, seat_limit)
select pg_temp.k('e'), v.id, 'R1', 50 from public.venues v where v.name = 'ZZ Sitting hall';
insert into kv select 'ce', id from public.exam_centres where exam_id = pg_temp.k('e');

insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting, centre_id) values
  (pg_temp.k('e'), pg_temp.uid('s1'), pg_temp.uid('s1'), 'paid', 0, 'home', null),
  (pg_temp.k('e'), pg_temp.uid('s2'), pg_temp.uid('s2'), 'paid', 0, 'home', null),
  (pg_temp.k('e'), pg_temp.uid('s3'), pg_temp.uid('s3'), 'paid', 0, 'home', null),
  (pg_temp.k('e'), pg_temp.uid('s4'), pg_temp.uid('s4'), 'paid', 0, 'centre', pg_temp.k('ce')),
  (pg_temp.k('e'), pg_temp.uid('s5'), pg_temp.uid('s5'), 'awaiting_payment', 0, 'home', null);
insert into kv select 'b' || right(s.name, 1), b.id from public.bookings b join c s on s.id = b.student_id where b.exam_id = pg_temp.k('e') and s.name like 's%';

create function pg_temp.state(p_b text, p_now text) returns jsonb language sql as $$
  select public.booking_sitting_state(pg_temp.k(p_b), pg_temp.ts(p_now)) $$;
create function pg_temp.ack(p_b text, p_now text) returns jsonb language sql as $$
  select public.sitting_acknowledge(pg_temp.k(p_b), pg_temp.ts(p_now)) $$;
grant execute on function pg_temp.state(text, text), pg_temp.ack(text, text) to public;

-- ----- phase_boundaries_use_server_time -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(pg_temp.state('b1', '2031-06-07 08:59:59Z') ->> 'phase', 'before_start', 'start - 1 s: before_start');
select is(pg_temp.state('b1', '2031-06-07 09:00:00Z') ->> 'phase', 'sitting', 'start: sitting');
select is(pg_temp.state('b1', '2031-06-07 10:29:59Z') ->> 'phase', 'sitting', 'finish - 1 s: sitting');
select is(pg_temp.state('b1', '2031-06-07 10:30:00Z') ->> 'phase', 'upload_open', 'finish: upload_open');
select is(pg_temp.state('b1', '2031-06-07 12:29:59Z') ->> 'phase', 'upload_open', 'finish + 2 h - 1 s: upload_open');
select is(pg_temp.state('b1', '2031-06-07 12:30:00Z') ->> 'phase', 'late_window', 'finish + 2 h: late_window');
select is(pg_temp.state('b1', '2031-06-08 10:29:59Z') ->> 'phase', 'late_window', 'finish + 24 h - 1 s: late_window');
select is(pg_temp.state('b1', '2031-06-08 10:30:00Z') ->> 'phase', 'closed', 'finish + 24 h: closed');
select is((pg_temp.state('b1', '2031-06-07 09:15:00Z') ->> 'server_now')::timestamptz, pg_temp.ts('2031-06-07 09:15:00Z'), 'server_now is the database clock');
select is(
  (select array[(j ->> 'starts_at')::timestamptz, (j ->> 'finish_at')::timestamptz, (j ->> 'on_time_until')::timestamptz, (j ->> 'late_until')::timestamptz]
   from (select pg_temp.state('b1', '2031-06-07 08:00:00Z') j) x),
  array[pg_temp.ts('2031-06-07 09:00:00Z'), pg_temp.ts('2031-06-07 10:30:00Z'), pg_temp.ts('2031-06-07 12:30:00Z'), pg_temp.ts('2031-06-08 10:30:00Z')],
  'the four times follow the start and the duration');
select is(pg_temp.state('b1', '2031-06-07 08:00:00Z') -> 'rules', 'null'::jsonb, 'no rules yet: null');
select is(pg_temp.state('b1', '2031-06-07 08:00:00Z') -> 'acknowledged', 'null'::jsonb, 'not acknowledged yet');
select is(pg_temp.state('b1', '2031-06-07 08:00:00Z') -> 'script', 'null'::jsonb, 'no script yet');
select is(pg_temp.state('b1', '2031-06-07 08:00:00Z') -> 'submission', 'null'::jsonb, 'no submission yet');
-- An API call ignores p_now (the database clock decides): this exam is years ahead.
select tests.as_postgres();
select set_config('request.method', 'POST', true);
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(pg_temp.state('b1', '2031-06-07 10:00:00Z') ->> 'phase', 'before_start', 'an API call uses the database clock, not p_now');
select tests.as_postgres();
select set_config('request.method', '', true);

-- ----- acknowledge_parent_and_student_roles -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p1'));
select is(pg_temp.ack('b1', '2031-06-07 08:00:00Z') ->> 'as_role', 'parent', 'a linked parent acknowledges as parent (before the start)');
select is(pg_temp.state('b1', '2031-06-07 08:00:01Z') -> 'acknowledged' ->> 'as_role', 'parent', 'the state shows who acknowledged');
select ok((pg_temp.state('b1', '2031-06-07 08:00:01Z') -> 'acknowledged' ->> 'by_name') is not null, 'and their name');
select is((pg_temp.ack('b1', '2031-06-07 09:30:00Z') ->> 'at')::timestamptz, pg_temp.ts('2031-06-07 08:00:00Z'), 'a second call returns the first acknowledgement unchanged');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(pg_temp.ack('b1', '2031-06-07 09:31:00Z') ->> 'code', 'forbidden', 'a student with a linked parent leaves it to the parent');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s2'));
select is(pg_temp.ack('b2', '2031-06-07 08:00:00Z') ->> 'as_role', 'student', 'a student with no linked parent acknowledges as student');
select is(pg_temp.state('b2', '2031-06-07 08:00:01Z') -> 'acknowledged' ->> 'as_role', 'student', 'the state shows it');
select throws_ok('select 1 from public.sitting_acknowledgements', '42501', null, 'nobody reads acknowledgements directly');
select tests.as_postgres();
select is((select count(*)::int from public.sitting_acknowledgements), 2, 'one row per booking');

select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(pg_temp.state('b1', '2031-06-07 08:00:00Z') ->> 'ack_as', null, 'a student with a linked parent is told nobody (the parent does it)');
select is(pg_temp.state('b1', '2031-06-07 08:00:00Z') ->> 'has_parent', 'true', 'and that a parent is linked');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p1'));
select is(pg_temp.state('b1', '2031-06-07 08:00:00Z') ->> 'ack_as', 'parent', 'a parent acknowledges as parent');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s2'));
select is(pg_temp.state('b2', '2031-06-07 08:00:00Z') ->> 'ack_as', 'student', 'a student with no parent acknowledges as student');

-- ----- acknowledge_after_finish_refused -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p2'));
select is(pg_temp.ack('b3', '2031-06-07 10:30:00Z') ->> 'code', 'conflict', 'at the finish: refused');
select is(pg_temp.ack('b3', '2031-06-07 13:00:00Z') ->> 'code', 'conflict', 'after the finish: refused');
select is(pg_temp.ack('b3', '2031-06-07 10:29:59Z') ->> 'ok', 'true', 'one second before the finish: accepted');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p1'));
select is(pg_temp.ack('b1', '2031-06-07 13:00:00Z') ->> 'ok', 'true', 'an existing acknowledgement still reads back after the finish');

-- ----- centre_booking_has_no_sitting_state -----
select is(pg_temp.state('b4', '2031-06-07 08:00:00Z') ->> 'code', 'wrong_sitting', 'a centre booking has no sitting state');
select is(pg_temp.ack('b4', '2031-06-07 08:00:00Z') ->> 'code', 'wrong_sitting', 'and cannot be acknowledged');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s5'));
select is(pg_temp.state('b5', '2031-06-07 08:00:00Z') ->> 'code', 'conflict', 'an unpaid home booking has no sitting state');
select is(pg_temp.ack('b5', '2031-06-07 08:00:00Z') ->> 'code', 'conflict', 'and cannot be acknowledged');

-- ----- other_family_forbidden -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p2'));
select is(pg_temp.state('b1', '2031-06-07 08:00:00Z') ->> 'code', 'forbidden', 'another family cannot read the state');
select is(pg_temp.ack('b1', '2031-06-07 08:00:00Z') ->> 'code', 'forbidden', 'or acknowledge');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s3'));
select is(pg_temp.state('b1', '2031-06-07 08:00:00Z') ->> 'code', 'forbidden', 'another student cannot read the state');
select is(public.booking_sitting_state(gen_random_uuid()) ->> 'code', 'forbidden', 'an unknown booking answers forbidden');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.state('b1', '2031-06-07 08:00:00Z') ->> 'ok', 'true', 'an admin can read the state');
select is(pg_temp.ack('b2', '2031-06-07 08:00:00Z') ->> 'code', 'forbidden', 'but not acknowledge');

-- ----- the script and the latest submission, nothing of other bookings -----
select tests.as_postgres();
insert into public.scripts (booking_id, exam_id, source, number, state, late)
values (pg_temp.k('b1'), pg_temp.k('e'), 'home', 'ZZ-SIT-1', 'checking', true);
insert into public.home_submissions (booking_id, seq, state, late) values
  (pg_temp.k('b1'), 1, 'rejected', false), (pg_temp.k('b1'), 2, 'received', true);
insert into public.home_submissions (booking_id, seq, state) values (pg_temp.k('b3'), 1, 'received');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p1'));
select is(pg_temp.state('b1', '2031-06-07 13:00:00Z') -> 'script', '{"number":"ZZ-SIT-1","state":"checking","late":true}'::jsonb, 'the script shows number, state and late');
select is(pg_temp.state('b1', '2031-06-07 13:00:00Z') -> 'submission' ->> 'seq', '2', 'the latest submission by seq');
select is(pg_temp.state('b1', '2031-06-07 13:00:00Z') -> 'submission' ->> 'state', 'received', 'with its state');
select is(pg_temp.state('b1', '2031-06-07 13:00:00Z') -> 'submission' ->> 'late', 'true', 'and its late flag');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s2'));
select is(pg_temp.state('b2', '2031-06-07 13:00:00Z') -> 'submission', 'null'::jsonb, 'another booking shows none of this');

-- ----- set_exam_home_rules -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(public.set_exam_home_rules(pg_temp.k('e'), '  Sit alone.  ', 'Pens, ruler') ->> 'ok', 'true', 'an admin sets rules and materials');
select tests.as_postgres();
select is((select home_rules || '|' || allowed_materials from public.exams where id = pg_temp.k('e')), 'Sit alone.|Pens, ruler', 'saved trimmed');
select is((select count(*)::int from public.audit_log where action = 'exam_home_rules_set' and target_id = pg_temp.k('e')), 1, 'audited');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p1'));
select is(pg_temp.state('b1', '2031-06-07 08:00:00Z') ->> 'rules', 'Sit alone.', 'the family reads them in the state');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(public.set_exam_home_rules(pg_temp.k('e'), '   ', '') ->> 'ok', 'true', 'empty text is accepted');
select tests.as_postgres();
select ok((select home_rules is null and allowed_materials is null from public.exams where id = pg_temp.k('e')), 'and stored as null');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(public.set_exam_home_rules(pg_temp.k('e'), repeat('x', 2001), null) ->> 'code', 'invalid_input', 'rules over 2000 characters refused');
select is(public.set_exam_home_rules(pg_temp.k('e'), repeat('x', 2000), repeat('y', 501)) ->> 'code', 'invalid_input', 'materials over 500 characters refused');
select is(public.set_exam_home_rules(gen_random_uuid(), 'x', 'y') ->> 'code', 'not_found', 'an unknown exam');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('teacher'));
select is(public.set_exam_home_rules(pg_temp.k('d'), 'Draft rules', null) ->> 'ok', 'true', 'a teacher edits a draft in their subject');
select is(public.set_exam_home_rules(pg_temp.k('e'), 'x', null) ->> 'code', 'forbidden', 'but not a published exam');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('teacher2'));
select is(public.set_exam_home_rules(pg_temp.k('d'), 'x', null) ->> 'code', 'forbidden', 'nor a subject that is not theirs');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(public.set_exam_home_rules(pg_temp.k('d'), 'x', null) ->> 'code', 'forbidden', 'nor a student');

select * from finish();
rollback;
