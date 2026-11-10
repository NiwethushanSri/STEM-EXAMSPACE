begin;
create extension if not exists pgtap with schema extensions;
select plan(48);
select tests.assert_no_owner();

create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('admin', tests.create_user('admin', 'active'));
insert into c values ('teacher', tests.create_user('teacher', 'active'));
insert into c values ('tutor', tests.create_user('tutor', 'active'));
insert into c values ('s1', tests.create_user('student', 'active'));
insert into c values ('s2', tests.create_user('student', 'active'));
insert into c values ('s3', tests.create_user('student', 'active'));
insert into c values ('s4', tests.create_user('student', 'active'));
insert into c values ('s5', tests.create_user('student', 'active'));
insert into c values ('s6', tests.create_user('student', 'active'));
insert into c values ('s7', tests.create_user('student', 'active'));
insert into c values ('s8', tests.create_user('student', 'active'));
insert into c values ('s9', tests.create_user('student', 'active'));
insert into c values ('steacher', tests.create_user('teacher', 'suspended'));
insert into c values ('teacherb', tests.create_user('teacher', 'active'));
update public.profiles set first_name = 'Ada', last_name = 'Lovelace' where id = (select id from c where name = 's1');
update public.student_details
  set index_number = 'SE-2026-9001', photo_path = profile_id::text || '/photo.jpg'
  where profile_id = (select id from c where name = 's1');
update public.student_details set index_number = 'SE-2026-9002' where profile_id = (select id from c where name = 's2');

insert into public.subjects (name, kind) values ('ZZ Att A', 'school'), ('ZZ Att B', 'school');
insert into public.teacher_subjects values
  ((select id from c where name = 'teacher'), (select id from public.subjects where name = 'ZZ Att A'));

insert into public.teacher_subjects values
  ((select id from c where name = 'steacher'), (select id from public.subjects where name = 'ZZ Att A')),
  ((select id from c where name = 'teacherb'), (select id from public.subjects where name = 'ZZ Att B'));

create temp table ex (name text primary key, id uuid not null);
grant select on ex to public;
create function pg_temp.mk_exam(p_name text, p_subject text, p_starts timestamptz,
  p_status public.exam_status default 'published') returns void
language plpgsql as $$
begin
  with x as (
    insert into public.exams (subject_id, title, paper, format, starts_at, duration_minutes, seat_limit, price_pence,
      price_confirmed, booking_deadline, status)
    values ((select id from public.subjects where name = p_subject), 'ZZ ' || p_name, 'P1', 'online', p_starts, 60,
      10, 1000, true, p_starts - interval '1 day', p_status)
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

select pg_temp.mk_exam('summer', 'ZZ Att A', '2026-07-01 09:00 Europe/London');
select pg_temp.mk_exam('winter', 'ZZ Att A', '2026-12-01 09:00 Europe/London');
select pg_temp.mk_exam('other', 'ZZ Att B', '2026-07-01 09:00 Europe/London');
select pg_temp.mk_exam('future', 'ZZ Att A', now() + interval '30 days');
select pg_temp.mk_exam('draft', 'ZZ Att A', '2026-07-01 09:00 Europe/London', 'draft');
select pg_temp.mk_exam('edge', 'ZZ Att A', '2026-07-01 09:00 Europe/London');
select pg_temp.mk_exam('live', 'ZZ Att A', now() - interval '1 hour');

select pg_temp.mk_booking('summer', 's1', 'paid');
select pg_temp.mk_booking('summer', 's3', 'paid');
select pg_temp.mk_booking('summer', 's4', 'cancel_requested');
select pg_temp.mk_booking('summer', 's5', 'paid');
select pg_temp.mk_booking('summer', 's6', 'awaiting_payment');
select pg_temp.mk_booking('winter', 's1', 'paid');
select pg_temp.mk_booking('winter', 's3', 'paid');
select pg_temp.mk_booking('other', 's1', 'paid');
select pg_temp.mk_booking('future', 's1', 'paid');
select pg_temp.mk_booking('live', 's1', 'paid');
select pg_temp.mk_booking('edge', 's1', 'paid');
select pg_temp.mk_booking('edge', 's7', 'cancel_requested');
select pg_temp.mk_booking('edge', 's8', 'refunded');
select pg_temp.mk_booking('edge', 's9', 'cancelled');
select pg_temp.mk_booking('draft', 's1', 'paid');

-- normalise_index mirrors the TypeScript rules.
select is(public.normalise_index(' se 2026-0142 '), 'SE-2026-0142', 'normalise: spaces, case, hyphens');
select is(public.normalise_index('SE20260142'), 'SE-2026-0142', 'normalise: no separators');
select is(public.normalise_index('ab c-d'), 'ABC-D', 'normalise: non-matching is upper-cased with spaces removed');
select is(public.normalise_index('SE-2026-12'), 'SE-2026-12', 'normalise: too short is left alone');

-- Permissions.
select is(public.mark_attendance_as((select id from c where name = 'teacher'), (select id from ex where name = 'other'), (select id from c where name = 's1'), '2026-07-01 09:05 Europe/London') ->> 'code', 'forbidden', 'teacher_other_subject_forbidden');
select is(public.mark_attendance_as((select id from c where name = 'tutor'), (select id from ex where name = 'summer'), (select id from c where name = 's1'), '2026-07-01 09:05 Europe/London') ->> 'code', 'forbidden', 'tutor forbidden');
select is(public.mark_attendance_as((select id from c where name = 's1'), (select id from ex where name = 'summer'), (select id from c where name = 's1'), '2026-07-01 09:05 Europe/London') ->> 'code', 'forbidden', 'student forbidden');
select is(public.close_register_as((select id from c where name = 'tutor'), (select id from ex where name = 'summer'), '2026-07-01 10:00 Europe/London') ->> 'code', 'forbidden', 'tutor cannot close register');

-- Booked rules.
select is(public.mark_attendance_as((select id from c where name = 'teacher'), (select id from ex where name = 'summer'), (select id from c where name = 's2'), '2026-07-01 09:05 Europe/London') ->> 'code', 'not_booked', 'unbooked_student_refused');
select is(public.mark_attendance_as((select id from c where name = 'teacher'), (select id from ex where name = 'summer'), (select id from c where name = 's6'), '2026-07-01 09:05 Europe/London') ->> 'code', 'not_booked', 'awaiting_payment student refused');
select is(public.mark_attendance_as((select id from c where name = 'teacher'), (select id from ex where name = 'draft'), (select id from c where name = 's1'), '2026-07-01 09:05 Europe/London') ->> 'code', 'conflict', 'draft exam: conflict');

-- Late threshold uses the real instant (BST in July, GMT in December).
select is(public.mark_attendance_as((select id from c where name = 'teacher'), (select id from ex where name = 'summer'), (select id from c where name = 's1'), '2026-07-01 09:14 Europe/London') ->> 'status', 'present', 'late_threshold_uses_instant: summer +14 present');
select is(public.mark_attendance_as((select id from c where name = 'teacher'), (select id from ex where name = 'summer'), (select id from c where name = 's3'), '2026-07-01 09:16 Europe/London') ->> 'status', 'late', 'late_threshold_uses_instant: summer +16 late');
select is(public.mark_attendance_as((select id from c where name = 'admin'), (select id from ex where name = 'winter'), (select id from c where name = 's1'), '2026-12-01 09:14 Europe/London') ->> 'status', 'present', 'late_threshold_uses_instant: winter +14 present');
select is(public.mark_attendance_as((select id from c where name = 'admin'), (select id from ex where name = 'winter'), (select id from c where name = 's3'), '2026-12-01 09:16 Europe/London') ->> 'status', 'late', 'late_threshold_uses_instant: winter +16 late');
select is(public.mark_attendance_as((select id from c where name = 'teacher'), (select id from ex where name = 'summer'), (select id from c where name = 's4'), '2026-07-01 09:01 Europe/London') ->> 'status', 'present', 'cancel_requested student can be marked');

-- Rescan keeps the first mark.
select is(public.mark_attendance_as((select id from c where name = 'teacher'), (select id from ex where name = 'summer'), (select id from c where name = 's1'), '2026-07-01 09:30 Europe/London'), '{"ok":true,"status":"present","already":true}'::jsonb, 'rescan_idempotent');
select is((select count(*)::int from public.attendance where exam_id = (select id from ex where name = 'summer') and student_id = (select id from c where name = 's1')), 1, 'rescan leaves one row');
select is((select count(*)::int from public.audit_log where action = 'attendance_marked' and target_type = 'booking'
  and target_id in (select id from public.bookings where exam_id = (select id from ex where name = 'summer') and student_id = (select id from c where name = 's1'))), 1, 'rescan writes no second audit row');

-- Lookup.
select is(public.attendance_lookup_as((select id from c where name = 'admin'), (select id from ex where name = 'summer'), 'se 2026 9001'), jsonb_build_object('ok', true, 'studentId', (select id from c where name = 's1'), 'name', 'Ada Lovelace', 'photoPath', (select id from c where name = 's1')::text || '/photo.jpg', 'booked', true, 'status', 'present'), 'lookup returns card data with status');
select is(public.attendance_lookup_as((select id from c where name = 'admin'), (select id from ex where name = 'future'), 'SE-2026-9999') ->> 'code', 'not_found', 'lookup returns nothing for unknown index');
select is(public.attendance_lookup_as((select id from c where name = 'admin'), (select id from ex where name = 'summer'), 'garbage') ->> 'code', 'not_found', 'lookup of malformed index is not_found');
select is(public.attendance_lookup_as((select id from c where name = 'admin'), (select id from ex where name = 'summer'), 'SE-2026-9002') ->> 'booked', 'false', 'admin sees an unbooked student');
select is(public.attendance_lookup_as((select id from c where name = 'teacher'), (select id from ex where name = 'summer'), 'SE-2026-9002'), '{"ok":true,"booked":false}'::jsonb, 'teacher sees no name for an unbooked student');
select is(public.attendance_lookup_as((select id from c where name = 'teacher'), (select id from ex where name = 'summer'), 'SE-2026-9001') ->> 'name', 'Ada Lovelace', 'teacher sees the name of a booked student');
select is(public.attendance_lookup_as((select id from c where name = 'tutor'), (select id from ex where name = 'summer'), 'SE-2026-9001') ->> 'code', 'forbidden', 'tutor lookup forbidden');

-- Close register.
select is(public.close_register_as((select id from c where name = 'teacher'), (select id from ex where name = 'future'), now()) ->> 'code', 'conflict', 'close_before_start_refused');
select is(public.close_register_as((select id from c where name = 'teacher'), (select id from ex where name = 'other'), '2026-07-01 10:00 Europe/London') ->> 'code', 'forbidden', 'teacher of another subject cannot close');
select is(public.close_register_as((select id from c where name = 'teacher'), (select id from ex where name = 'summer'), '2026-07-01 10:00 Europe/London'), '{"ok":true,"absent":1}'::jsonb, 'close_marks_absent_and_completes: one absent');
select is((select status::text from public.attendance where exam_id = (select id from ex where name = 'summer') and student_id = (select id from c where name = 's5')), 'absent', 'unmarked paid student is absent');
select is((select status::text from public.bookings where exam_id = (select id from ex where name = 'summer') and student_id = (select id from c where name = 's6')), 'expired', 'close expires awaiting_payment bookings');
select is((select status::text from public.exams where id = (select id from ex where name = 'summer')), 'completed', 'exam completed');
select is(public.mark_attendance_as((select id from c where name = 'teacher'), (select id from ex where name = 'summer'), (select id from c where name = 's5'), '2026-07-01 10:05 Europe/London') ->> 'code', 'conflict', 'marking on a completed exam is a conflict');
select is(public.close_register_as((select id from c where name = 'teacher'), (select id from ex where name = 'summer'), '2026-07-01 10:10 Europe/London') ->> 'code', 'conflict', 'closing twice is a conflict');
select is((select count(*)::int from public.audit_log where action = 'register_closed' and target_id = (select id from ex where name = 'summer')), 1, 'close writes an audit row');

-- Fix round 1.
select is(public.mark_attendance_as((select id from c where name = 'teacher'), (select id from ex where name = 'edge'), (select id from c where name = 's1'), '2026-07-01 09:15 Europe/London'), '{"ok":true,"status":"late","already":false}'::jsonb, 'first mark returns already false; exactly +15:00 is late');
select is(public.mark_attendance_as((select id from c where name = 'teacher'), (select id from ex where name = 'edge'), (select id from c where name = 's8'), '2026-07-01 09:05 Europe/London') ->> 'code', 'not_booked', 'refunded booking is not_booked');
select is(public.mark_attendance_as((select id from c where name = 'teacher'), (select id from ex where name = 'edge'), (select id from c where name = 's9'), '2026-07-01 09:05 Europe/London') ->> 'code', 'not_booked', 'cancelled booking is not_booked');
select is(public.mark_attendance_as((select id from c where name = 'steacher'), (select id from ex where name = 'edge'), (select id from c where name = 's7'), '2026-07-01 09:05 Europe/London') ->> 'code', 'forbidden', 'suspended teacher forbidden');
select is(public.attendance_lookup_as((select id from c where name = 'teacherb'), (select id from ex where name = 'edge'), 'SE-2026-9001') ->> 'code', 'forbidden', 'lookup by teacher of another subject forbidden');
select is(public.close_register_as((select id from c where name = 'admin'), (select id from ex where name = 'draft'), '2026-07-01 10:00 Europe/London') ->> 'code', 'conflict', 'close on a draft exam is a conflict');
select is(public.close_register_as((select id from c where name = 'teacher'), (select id from ex where name = 'edge'), '2026-07-01 10:00 Europe/London'), '{"ok":true,"absent":1}'::jsonb, 'unmarked cancel_requested student counted absent');
select is((select status::text from public.attendance where exam_id = (select id from ex where name = 'edge') and student_id = (select id from c where name = 's7')), 'absent', 'cancel_requested student is absent');
select ok(not has_function_privilege('authenticated', 'public.attendance_lookup_as(uuid, uuid, text)', 'execute')
  and not has_function_privilege('authenticated', 'public.close_register_as(uuid, uuid, timestamptz)', 'execute'), 'internal helpers have no client grant');
select is(public.mark_attendance_as((select id from c where name = 'admin'), (select id from ex where name = 'nonexistent_x'), (select id from c where name = 's1'), now()) ->> 'code', 'invalid_input', 'null exam id is invalid_input');
select is(public.mark_attendance_as((select id from c where name = 'admin'), gen_random_uuid(), (select id from c where name = 's1'), now()) ->> 'code', 'not_found', 'missing exam is not_found');

-- Client RPCs: grants and a real call as admin.
select ok(not has_function_privilege('anon', 'public.mark_attendance(uuid, uuid)', 'execute')
  and has_function_privilege('authenticated', 'public.mark_attendance(uuid, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'public.mark_attendance_as(uuid, uuid, uuid, timestamptz)', 'execute')
  and not has_function_privilege('anon', 'public.close_register(uuid)', 'execute'), 'attendance grants');
select tests.as_user((select id from c where name = 'admin'));
select is(public.mark_attendance((select id from ex where name = 'live'), (select id from c where name = 's1')) ->> 'status', 'late', 'client mark_attendance works (an hour in is late)');
select tests.as_postgres();

select * from finish();
rollback;
