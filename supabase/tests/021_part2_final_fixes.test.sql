begin;
create extension if not exists pgtap with schema extensions;
select plan(14);
select tests.assert_no_owner();

create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('admin', tests.create_user('admin', 'active'));
insert into c values ('teacher', tests.create_user('teacher', 'active'));
insert into c values ('s1', tests.create_user('student', 'active'));
insert into c values ('s2', tests.create_user('student', 'active'));
insert into c values ('s3', tests.create_user('student', 'active'));
insert into c values ('s4', tests.create_user('student', 'active'));

insert into public.subjects (name, kind) values ('ZZ Fix A', 'school');
insert into public.teacher_subjects values
  ((select id from c where name = 'teacher'), (select id from public.subjects where name = 'ZZ Fix A'));

create temp table ex (name text primary key, id uuid not null);
grant select on ex to public;
create function pg_temp.mk_exam(p_name text, p_starts timestamptz, p_deadline timestamptz) returns void
language plpgsql as $$
begin
  with x as (
    insert into public.exams (subject_id, title, paper, format, starts_at, duration_minutes, seat_limit, price_pence,
      price_confirmed, booking_deadline, status)
    values ((select id from public.subjects where name = 'ZZ Fix A'), 'ZZ ' || p_name, 'P1', 'online', p_starts, 60,
      10, 1000, true, p_deadline, 'published')
    returning id)
  insert into ex select p_name, x.id from x;
end; $$;
create function pg_temp.mk_booking(p_exam text, p_student text, p_status public.booking_status) returns void
language plpgsql as $$
begin
  insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence)
  values ((select id from ex where name = p_exam), (select id from c where name = p_student),
    (select id from c where name = p_student), p_status, 1000);
end; $$;

-- close_register with a deleted student and expired leftovers.
select pg_temp.mk_exam('live', now() - interval '1 hour', now() - interval '1 day');
select pg_temp.mk_booking('live', 's1', 'paid');
select pg_temp.mk_booking('live', 's2', 'paid');
select pg_temp.mk_booking('live', 's3', 'awaiting_payment');
select pg_temp.mk_booking('live', 's4', 'awaiting_payment');
delete from auth.users where id = (select id from c where name = 's2');
select is((select count(*)::int from public.bookings where exam_id = (select id from ex where name = 'live') and student_id is null), 1, 'deleted student leaves a null-student booking');
select is(public.close_register_as((select id from c where name = 'teacher'), (select id from ex where name = 'live'), now()), '{"ok":true,"absent":1}'::jsonb, 'close_register succeeds despite a null-student booking');
select is((select status::text from public.exams where id = (select id from ex where name = 'live')), 'completed', 'exam completed');
select is((select count(*)::int from public.attendance where exam_id = (select id from ex where name = 'live') and student_id is null), 0, 'no attendance row with a null student');
select is((select count(*)::int from public.attendance where exam_id = (select id from ex where name = 'live')), 1, 'only the live student is absent');
select is((select count(*)::int from public.audit_log where action = 'booking_expired' and actor_id = (select id from c where name = 'teacher')
  and target_id in (select id from public.bookings where exam_id = (select id from ex where name = 'live') and status = 'expired')), 2, 'expired-at-close bookings are audited with the actor');

-- save_exam date rules.
select pg_temp.mk_exam('future', now() + interval '10 days', now() + interval '5 days');
select pg_temp.mk_exam('pastdl', now() + interval '10 days', now() - interval '1 day');
select pg_temp.mk_exam('started', now() - interval '2 hours', now() - interval '1 day');
create temp table cur (name text primary key, subject bigint, starts timestamptz, dl timestamptz);
grant select on cur to public;
insert into cur select e.title, e.subject_id, e.starts_at, e.booking_deadline from public.exams e where e.id in (select id from ex);

select tests.as_user((select id from c where name = 'admin'));
select is(public.save_exam((select id from ex where name = 'future'), (select subject from cur where name = 'ZZ future'), 'ZZ future', 'P1', 'online', null, null,
  (select starts from cur where name = 'ZZ future'), 60, 10, 1000, now() - interval '1 hour') ->> 'code', 'conflict', 'deadline moved into the past is a conflict');
select is(public.save_exam((select id from ex where name = 'future'), (select subject from cur where name = 'ZZ future'), 'ZZ future', 'P1', 'online', null, null,
  (select starts from cur where name = 'ZZ future'), 60, 10, 1000, now() + interval '6 days') ->> 'ok', 'true', 'deadline moved to the future saves');
select is(public.save_exam((select id from ex where name = 'pastdl'), (select subject from cur where name = 'ZZ pastdl'), 'ZZ pastdl renamed', 'P1', 'online', null, null,
  (select starts from cur where name = 'ZZ pastdl'), 60, 10, 1000, (select dl from cur where name = 'ZZ pastdl')) ->> 'ok', 'true', 'unchanged past deadline still saves with other edits');
select is(public.save_exam((select id from ex where name = 'pastdl'), (select subject from cur where name = 'ZZ pastdl'), 'ZZ pastdl renamed', 'P1', 'online', null, null,
  (select starts from cur where name = 'ZZ pastdl'), 60, 10, 1000, now() - interval '2 hours') ->> 'code', 'conflict', 'changing a past deadline to another past time is a conflict');
select is(public.save_exam((select id from ex where name = 'started'), (select subject from cur where name = 'ZZ started'), 'ZZ started', 'P1', 'online', null, null,
  (select starts from cur where name = 'ZZ started') + interval '1 day', 60, 10, 1000, (select dl from cur where name = 'ZZ started')) ->> 'code', 'conflict', 'started exam: start change is a conflict');
select is(public.save_exam((select id from ex where name = 'started'), (select subject from cur where name = 'ZZ started'), 'ZZ started', 'P1', 'online', null, null,
  (select starts from cur where name = 'ZZ started'), 60, 10, 1000, now() - interval '3 hours') ->> 'code', 'conflict', 'started exam: deadline change is a conflict');
select is(public.save_exam((select id from ex where name = 'started'), (select subject from cur where name = 'ZZ started'), 'ZZ started edited', 'P1', 'online', null, null,
  (select starts from cur where name = 'ZZ started'), 60, 10, 1000, (select dl from cur where name = 'ZZ started')) ->> 'ok', 'true', 'started exam: unchanged dates still save');
select tests.as_postgres();
select is((select count(*)::int from public.audit_log where action = 'exam_updated' and target_id = (select id from ex where name = 'future')), 1, 'successful published edit is audited');

select * from finish();
rollback;
