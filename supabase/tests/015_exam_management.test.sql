begin;
create extension if not exists pgtap with schema extensions;
select plan(91);
select tests.assert_no_owner();

-- Fixtures.
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('admin', tests.create_user('admin', 'active'));
insert into c values ('sadmin', tests.create_user('admin', 'suspended'));
insert into c values ('teacher', tests.create_user('teacher', 'active'));
insert into c values ('teacher2', tests.create_user('teacher', 'active'));
insert into c values ('s1', tests.create_user('student', 'active'));
insert into c values ('s2', tests.create_user('student', 'active'));
insert into c values ('s3', tests.create_user('student', 'active'));

insert into public.subjects (name, kind) values ('ZZ Maths', 'school'), ('ZZ Physics', 'school');
create temp table subj (name text primary key, id bigint not null);
grant select on subj to public;
insert into subj select name, id from public.subjects where name in ('ZZ Maths', 'ZZ Physics');
insert into public.teacher_subjects values ((select id from c where name = 'teacher'), (select id from subj where name = 'ZZ Maths'));
insert into public.teacher_subjects values ((select id from c where name = 'teacher2'), (select id from subj where name = 'ZZ Physics'));

-- Stash for ids returned by the functions.
create temp table st (name text primary key, id uuid);
grant all on st to public;

-- Privileges.
select is(has_function_privilege('anon', 'public.save_venue(uuid,text,text[],boolean)', 'execute'), false, 'save_venue: not anon');
select is(has_function_privilege('anon', 'public.save_exam(uuid,bigint,text,text,public.exam_format,uuid,text,timestamptz,integer,integer,integer,timestamptz)', 'execute'), false, 'save_exam: not anon');
select is(has_function_privilege('anon', 'public.set_exam_status(uuid,public.exam_status)', 'execute'), false, 'set_exam_status: not anon');
select is(has_function_privilege('authenticated', 'public.save_venue(uuid,text,text[],boolean)', 'execute'), true, 'save_venue: authenticated');
select is(has_function_privilege('authenticated', 'public.save_exam(uuid,bigint,text,text,public.exam_format,uuid,text,timestamptz,integer,integer,integer,timestamptz)', 'execute'), true, 'save_exam: authenticated');
select is(has_function_privilege('authenticated', 'public.set_exam_status(uuid,public.exam_status)', 'execute'), true, 'set_exam_status: authenticated');

-- Venues.
select tests.as_user((select id from c where name = 'teacher'));
select is(public.save_venue(null, 'ZZ Venue T', array['R1'], true) ->> 'code', 'forbidden', 'teacher cannot save a venue');
select tests.as_postgres();
select tests.as_user((select id from c where name = 'sadmin'));
select is(public.save_venue(null, 'ZZ Venue S', array['R1'], true) ->> 'code', 'forbidden', 'suspended admin cannot save a venue');
select tests.as_postgres();
select tests.as_user((select id from c where name = 'admin'));
insert into st select 'venue', (public.save_venue(null, '  ZZ Venue  ', array['A1', ' A2 '], true) ->> 'id')::uuid;
insert into st select 'venue_off', (public.save_venue(null, 'ZZ Venue Off', array['B1'], false) ->> 'id')::uuid;
select isnt((select id from st where name = 'venue'), null, 'admin creates a venue');
select is((select rooms from public.venues where id = (select id from st where name = 'venue')), array['A1', 'A2'], 'venue rooms trimmed');
select is((select name from public.venues where id = (select id from st where name = 'venue')), 'ZZ Venue', 'venue name trimmed');
select is(public.save_venue(null, 'ZZ Venue', array['A1'], true) ->> 'code', 'conflict', 'duplicate venue name is a conflict');
select is(public.save_venue(null, '', array['A1'], true) ->> 'code', 'invalid_input', 'empty venue name invalid');
select is(public.save_venue(null, 'ZZ Venue X', array['A1', 'A1'], true) ->> 'code', 'invalid_input', 'duplicate rooms invalid');
select is(public.save_venue(null, 'ZZ Venue X', array['A1', ''], true) ->> 'code', 'invalid_input', 'blank room invalid');
select is(public.save_venue(gen_random_uuid(), 'ZZ Venue Y', array['A1'], true) ->> 'code', 'not_found', 'unknown venue id is not_found');
select is(public.save_venue((select id from st where name = 'venue'), 'ZZ Venue', array['A1', 'A2', 'A3'], true) ->> 'ok', 'true', 'admin updates a venue');
select is((select cardinality(rooms) from public.venues where id = (select id from st where name = 'venue')), 3, 'venue update applied');
select tests.as_postgres();
select is((select count(*)::int from public.audit_log where action in ('venue_created', 'venue_updated') and target_id = (select id from st where name = 'venue')), 2, 'venue create and update audited');

-- Exam creation.
select tests.as_user((select id from c where name = 'admin'));
insert into st select 'a_draft', (public.save_exam(null, (select id from subj where name = 'ZZ Maths'), 'ZZ Admin exam', 'P1', 'in_person',
  (select id from st where name = 'venue'), 'A1', now() + interval '30 days', 90, 5, 2500, now() + interval '20 days') ->> 'id')::uuid;
select isnt((select id from st where name = 'a_draft'), null, 'admin creates an exam');
select tests.as_postgres();
select is((select status::text || '/' || price_pence::text from public.exams where id = (select id from st where name = 'a_draft')), 'draft/2500', 'new exam is a draft with admin price');
select is((select created_by from public.exams where id = (select id from st where name = 'a_draft')), (select id from c where name = 'admin'), 'created_by is the actor');
select is((select count(*)::int from public.audit_log where action = 'exam_created' and target_id = (select id from st where name = 'a_draft')), 1, 'creation audited');

select tests.as_user((select id from c where name = 'teacher'));
insert into st select 't_draft', (public.save_exam(null, (select id from subj where name = 'ZZ Maths'), 'ZZ Teacher exam', 'P2', 'online',
  null, null, now() + interval '30 days', 60, 5, 9999, now() + interval '20 days') ->> 'id')::uuid;
select isnt((select id from st where name = 't_draft'), null, 'teacher creates a draft in own subject');
select is(public.save_exam(null, (select id from subj where name = 'ZZ Physics'), 'ZZ Other', 'P1', 'online',
  null, null, now() + interval '30 days', 60, 5, 0, now() + interval '20 days') ->> 'code', 'forbidden', 'teacher_cannot_save_other_subject');
select tests.as_postgres();
select is((select price_pence from public.exams where id = (select id from st where name = 't_draft')), 0, 'teacher cannot set price on create');

select tests.as_user((select id from c where name = 'teacher'));
select is(public.save_exam((select id from st where name = 't_draft'), (select id from subj where name = 'ZZ Maths'), 'ZZ Teacher exam v2', 'P2', 'online',
  null, null, now() + interval '31 days', 60, 6, 5000, now() + interval '20 days') ->> 'ok', 'true', 'teacher edits own draft');
select tests.as_postgres();
select is((select price_pence::text || '/' || title from public.exams where id = (select id from st where name = 't_draft')), '0/ZZ Teacher exam v2', 'teacher_cannot_set_price_or_status: price kept, edit applied');
select is((select status::text from public.exams where id = (select id from st where name = 't_draft')), 'draft', 'teacher edit leaves the status alone');
select is((select count(*)::int from public.audit_log where action = 'exam_updated' and target_id = (select id from st where name = 't_draft')), 0, 'draft edits are not audited');

select tests.as_user((select id from c where name = 'teacher'));
select is(public.set_exam_status((select id from st where name = 't_draft'), 'published') ->> 'code', 'forbidden', 'teacher cannot publish');
select tests.as_postgres();
select tests.as_user((select id from c where name = 'teacher2'));
select is(public.save_exam((select id from st where name = 't_draft'), (select id from subj where name = 'ZZ Maths'), 'ZZ Hijack', 'P1', 'online',
  null, null, now() + interval '30 days', 60, 5, 0, now() + interval '20 days') ->> 'code', 'forbidden', 'teacher of another subject cannot edit the draft');
select is(public.save_exam((select id from st where name = 't_draft'), (select id from subj where name = 'ZZ Physics'), 'ZZ Hijack', 'P1', 'online',
  null, null, now() + interval '30 days', 60, 5, 0, now() + interval '20 days') ->> 'code', 'forbidden', 'teacher cannot move a foreign draft into own subject');
select tests.as_postgres();
select tests.as_user((select id from c where name = 'teacher'));
select is(public.save_exam((select id from st where name = 't_draft'), (select id from subj where name = 'ZZ Physics'), 'ZZ Move', 'P1', 'online',
  null, null, now() + interval '30 days', 60, 5, 0, now() + interval '20 days') ->> 'code', 'forbidden', 'teacher cannot move own draft to a foreign subject');
select tests.as_postgres();

select tests.as_user((select id from c where name = 'sadmin'));
select is(public.save_exam(null, (select id from subj where name = 'ZZ Maths'), 'ZZ Susp', 'P1', 'online',
  null, null, now() + interval '30 days', 60, 5, 0, now() + interval '20 days') ->> 'code', 'forbidden', 'suspended admin cannot save an exam');
select is(public.set_exam_status((select id from st where name = 'a_draft'), 'published') ->> 'code', 'forbidden', 'suspended admin cannot publish');
select tests.as_postgres();

-- Invalid input, one case per rule (admin).
select tests.as_user((select id from c where name = 'admin'));
select is(public.save_exam(null, (select id from subj where name = 'ZZ Maths'), '', 'P1', 'online', null, null, now() + interval '30 days', 60, 5, 0, now() + interval '20 days') ->> 'code', 'invalid_input', 'empty title');
select is(public.save_exam(null, (select id from subj where name = 'ZZ Maths'), repeat('x', 121), 'P1', 'online', null, null, now() + interval '30 days', 60, 5, 0, now() + interval '20 days') ->> 'code', 'invalid_input', 'title too long');
select is(public.save_exam(null, (select id from subj where name = 'ZZ Maths'), 'T', repeat('x', 81), 'online', null, null, now() + interval '30 days', 60, 5, 0, now() + interval '20 days') ->> 'code', 'invalid_input', 'paper too long');
select is(public.save_exam(null, (select id from subj where name = 'ZZ Maths'), 'T', 'P1', 'online', null, null, now() + interval '30 days', 14, 5, 0, now() + interval '20 days') ->> 'code', 'invalid_input', 'duration too short');
select is(public.save_exam(null, (select id from subj where name = 'ZZ Maths'), 'T', 'P1', 'online', null, null, now() + interval '30 days', 601, 5, 0, now() + interval '20 days') ->> 'code', 'invalid_input', 'duration too long');
select is(public.save_exam(null, (select id from subj where name = 'ZZ Maths'), 'T', 'P1', 'online', null, null, now() + interval '30 days', 60, 0, 0, now() + interval '20 days') ->> 'code', 'invalid_input', 'seat limit zero');
select is(public.save_exam(null, (select id from subj where name = 'ZZ Maths'), 'T', 'P1', 'online', null, null, now() + interval '30 days', 60, 1001, 0, now() + interval '20 days') ->> 'code', 'invalid_input', 'seat limit too high');
select is(public.save_exam(null, (select id from subj where name = 'ZZ Maths'), 'T', 'P1', 'online', null, null, now() + interval '30 days', 60, 5, -1, now() + interval '20 days') ->> 'code', 'invalid_input', 'negative price');
select is(public.save_exam(null, (select id from subj where name = 'ZZ Maths'), 'T', 'P1', 'online', null, null, now() + interval '30 days', 60, 5, 100001, now() + interval '20 days') ->> 'code', 'invalid_input', 'price too high');
select is(public.save_exam(null, (select id from subj where name = 'ZZ Maths'), 'T', 'P1', 'online', null, null, now() + interval '30 days', 60, 5, null, now() + interval '20 days') ->> 'code', 'invalid_input', 'admin must give a price');
select is(public.save_exam(null, (select id from subj where name = 'ZZ Maths'), 'T', 'P1', 'online', null, null, now() + interval '30 days', 60, 5, 0, now() + interval '31 days') ->> 'code', 'invalid_input', 'deadline after start');
select is(public.save_exam(null, (select id from subj where name = 'ZZ Maths'), 'T', 'P1', 'online', (select id from st where name = 'venue'), null, now() + interval '30 days', 60, 5, 0, now() + interval '20 days') ->> 'code', 'invalid_input', 'online exam with a venue');
select is(public.save_exam(null, (select id from subj where name = 'ZZ Maths'), 'T', 'P1', 'online', null, 'A1', now() + interval '30 days', 60, 5, 0, now() + interval '20 days') ->> 'code', 'invalid_input', 'online exam with a room');
select is(public.save_exam(null, (select id from subj where name = 'ZZ Maths'), 'T', 'P1', 'in_person', null, 'A1', now() + interval '30 days', 60, 5, 0, now() + interval '20 days') ->> 'code', 'invalid_input', 'in-person exam without a venue');
select is(public.save_exam(null, (select id from subj where name = 'ZZ Maths'), 'T', 'P1', 'in_person', (select id from st where name = 'venue'), 'Z9', now() + interval '30 days', 60, 5, 0, now() + interval '20 days') ->> 'code', 'invalid_input', 'room not in venue');
select is(public.save_exam(null, (select id from subj where name = 'ZZ Maths'), 'T', 'P1', 'in_person', (select id from st where name = 'venue'), null, now() + interval '30 days', 60, 5, 0, now() + interval '20 days') ->> 'code', 'invalid_input', 'in-person exam without a room');
select is(public.save_exam(null, (select id from subj where name = 'ZZ Maths'), 'T', 'P1', 'in_person', (select id from st where name = 'venue_off'), 'B1', now() + interval '30 days', 60, 5, 0, now() + interval '20 days') ->> 'code', 'invalid_input', 'inactive venue');
select is(public.save_exam(null, -1, 'T', 'P1', 'online', null, null, now() + interval '30 days', 60, 5, 0, now() + interval '20 days') ->> 'code', 'invalid_input', 'unknown subject');
select is(public.save_exam(gen_random_uuid(), (select id from subj where name = 'ZZ Maths'), 'T', 'P1', 'online', null, null, now() + interval '30 days', 60, 5, 0, now() + interval '20 days') ->> 'code', 'not_found', 'unknown exam id is not_found');
select tests.as_postgres();
select is((select count(*)::int from public.exams where title in ('T', 'ZZ Susp', 'ZZ Other', 'ZZ Hijack', 'ZZ Move')), 0, 'refused saves wrote nothing');

-- Publishing.
select tests.as_user((select id from c where name = 'admin'));
insert into st select 'past', (public.save_exam(null, (select id from subj where name = 'ZZ Maths'), 'ZZ Past exam', 'P1', 'online',
  null, null, now() - interval '1 day', 60, 5, 0, now() - interval '2 days') ->> 'id')::uuid;
select is(public.set_exam_status((select id from st where name = 'past'), 'published') ->> 'code', 'invalid_input', 'cannot publish an exam that already started');
insert into st select 'late_deadline', (public.save_exam(null, (select id from subj where name = 'ZZ Maths'), 'ZZ Late deadline', 'P1', 'online',
  null, null, now() + interval '2 days', 60, 5, 0, now() - interval '1 day') ->> 'id')::uuid;
select is(public.set_exam_status((select id from st where name = 'late_deadline'), 'published') ->> 'code', 'invalid_input', 'cannot publish past the booking deadline');
select is(public.set_exam_status((select id from st where name = 'a_draft'), 'completed') ->> 'code', 'invalid_input', 'completed is not settable here');
select is(public.set_exam_status((select id from st where name = 'a_draft'), 'draft') ->> 'code', 'invalid_input', 'draft is not settable here');
select is(public.set_exam_status((select id from st where name = 'a_draft'), 'cancelled') ->> 'code', 'conflict', 'cannot cancel a draft');
select is(public.set_exam_status(gen_random_uuid(), 'published') ->> 'code', 'not_found', 'unknown exam is not_found');
select is(public.set_exam_status((select id from st where name = 'a_draft'), 'published') ->> 'ok', 'true', 'admin_publishes');
select is(public.set_exam_status((select id from st where name = 'a_draft'), 'published') ->> 'code', 'conflict', 'cannot publish twice');
select tests.as_postgres();
select is((select status::text from public.exams where id = (select id from st where name = 'a_draft')), 'published', 'exam is published');
select is((select count(*)::int from public.audit_log where action = 'exam_published' and target_id = (select id from st where name = 'a_draft')), 1, 'publish audited');

-- Teacher cannot edit a published exam.
select tests.as_user((select id from c where name = 'teacher'));
select is(public.save_exam((select id from st where name = 'a_draft'), (select id from subj where name = 'ZZ Maths'), 'ZZ Admin exam', 'P1', 'in_person',
  (select id from st where name = 'venue'), 'A1', now() + interval '30 days', 90, 5, 2500, now() + interval '20 days') ->> 'code', 'forbidden', 'teacher cannot edit a published exam');
select tests.as_postgres();

-- Bookings on the published exam.
insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence) values
  ((select id from st where name = 'a_draft'), (select id from c where name = 's1'), (select id from c where name = 's1'), 'paid', 2500),
  ((select id from st where name = 'a_draft'), (select id from c where name = 's2'), (select id from c where name = 's2'), 'awaiting_payment', 2500);

select tests.as_user((select id from c where name = 'admin'));
select is(public.save_exam((select id from st where name = 'a_draft'), (select id from subj where name = 'ZZ Maths'), 'ZZ Admin exam', 'P1', 'in_person',
  (select id from st where name = 'venue'), 'A2', now() + interval '31 days', 120, 5, 2500, now() + interval '20 days') ->> 'ok', 'true', 'edit_published_keeps_bookings: admin edits date, room, duration');
select tests.as_postgres();
select is((select count(*)::int from public.bookings where exam_id = (select id from st where name = 'a_draft')), 2, 'bookings kept after the edit');
select is((select room || '/' || duration_minutes::text from public.exams where id = (select id from st where name = 'a_draft')), 'A2/120', 'published edit applied');
select is((select count(*)::int from public.audit_log where action = 'exam_updated' and target_id = (select id from st where name = 'a_draft')), 1, 'published edit audited');

select tests.as_user((select id from c where name = 'admin'));
select is(public.save_exam((select id from st where name = 'a_draft'), (select id from subj where name = 'ZZ Maths'), 'ZZ Admin exam', 'P1', 'in_person',
  (select id from st where name = 'venue'), 'A2', now() - interval '1 hour', 120, 5, 2500, now() - interval '2 hours') ->> 'code', 'invalid_input', 'published exam cannot move into the past');
select is(public.save_exam((select id from st where name = 'a_draft'), (select id from subj where name = 'ZZ Maths'), 'ZZ Admin exam', 'P1', 'in_person',
  (select id from st where name = 'venue'), 'A2', now() + interval '31 days', 120, 1, 2500, now() + interval '20 days') ->> 'code', 'conflict', 'seat_limit_not_below_taken');
select is(public.save_exam((select id from st where name = 'a_draft'), (select id from subj where name = 'ZZ Maths'), 'ZZ Admin exam', 'P1', 'in_person',
  (select id from st where name = 'venue'), 'A2', now() + interval '31 days', 120, 2, 2500, now() + interval '20 days') ->> 'ok', 'true', 'seat limit equal to seats taken is allowed');
select is(public.save_exam((select id from st where name = 'a_draft'), (select id from subj where name = 'ZZ Maths'), 'ZZ Admin exam', 'P1', 'in_person',
  (select id from st where name = 'venue'), 'A2', now() + interval '31 days', 120, 2, 3000, now() + interval '20 days') ->> 'code', 'conflict', 'price_locked_after_booking');
select tests.as_postgres();
select is((select price_pence from public.exams where id = (select id from st where name = 'a_draft')), 2500, 'price unchanged after refused change');

-- A draft can change price freely; no bookings, so a published exam without bookings can too.
select tests.as_user((select id from c where name = 'admin'));
select is(public.save_exam((select id from st where name = 't_draft'), (select id from subj where name = 'ZZ Maths'), 'ZZ Teacher exam v2', 'P2', 'online',
  null, null, now() + interval '31 days', 60, 6, 4000, now() + interval '20 days') ->> 'ok', 'true', 'admin sets the price on a draft');
select is(public.set_exam_status((select id from st where name = 't_draft'), 'published') ->> 'ok', 'true', 'admin publishes the teacher draft');
select is(public.save_exam((select id from st where name = 't_draft'), (select id from subj where name = 'ZZ Maths'), 'ZZ Teacher exam v2', 'P2', 'online',
  null, null, now() + interval '31 days', 60, 6, 4500, now() + interval '20 days') ->> 'ok', 'true', 'published exam without bookings may change price');
select tests.as_postgres();
select is((select price_pence from public.exams where id = (select id from st where name = 't_draft')), 4500, 'price changed');

-- Cancelling a published exam.
insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, notes) values
  ((select id from st where name = 'a_draft'), (select id from c where name = 's3'), (select id from c where name = 's3'), 'cancel_requested', 2500, 'student asked'),
  ((select id from st where name = 'a_draft'), (select id from c where name = 's1'), (select id from c where name = 's1'), 'refunded', 2500, null);
update public.bookings set refunded_pence = 2500 where exam_id = (select id from st where name = 'a_draft') and status = 'refunded';

select tests.as_user((select id from c where name = 'teacher'));
select is(public.set_exam_status((select id from st where name = 'a_draft'), 'cancelled') ->> 'code', 'forbidden', 'teacher cannot cancel');
select tests.as_postgres();
select tests.as_user((select id from c where name = 'admin'));
select is(public.set_exam_status((select id from st where name = 'a_draft'), 'cancelled') ->> 'ok', 'true', 'admin cancels the published exam');
select is(public.set_exam_status((select id from st where name = 'a_draft'), 'cancelled') ->> 'code', 'conflict', 'cannot cancel twice');
select is(public.save_exam((select id from st where name = 'a_draft'), (select id from subj where name = 'ZZ Maths'), 'ZZ Admin exam', 'P1', 'in_person',
  (select id from st where name = 'venue'), 'A2', now() + interval '31 days', 120, 5, 2500, now() + interval '20 days') ->> 'code', 'conflict', 'cancelled exam cannot be edited');
select is(public.set_exam_status((select id from st where name = 'a_draft'), 'published') ->> 'code', 'conflict', 'cancelled exam cannot be republished');
select tests.as_postgres();
select is((select status::text from public.exams where id = (select id from st where name = 'a_draft')), 'cancelled', 'exam is cancelled');
select is((select status::text from public.bookings where exam_id = (select id from st where name = 'a_draft') and student_id = (select id from c where name = 's2')), 'cancelled', 'awaiting_payment booking cancelled');
select is((select status::text || '/' || notes from public.bookings where exam_id = (select id from st where name = 'a_draft') and student_id = (select id from c where name = 's1') and amount_pence = 2500 and refunded_pence = 0), 'cancel_requested/exam cancelled — refund due', 'cancel_exam_flags_paid_for_refund');
select is((select status::text || '/' || notes from public.bookings where exam_id = (select id from st where name = 'a_draft') and student_id = (select id from c where name = 's3')), E'cancel_requested/student asked\nexam cancelled — refund due', 'cancel_requested booking keeps its note and is flagged');
select is((select status::text from public.bookings where exam_id = (select id from st where name = 'a_draft') and refunded_pence = 2500), 'refunded', 'refunded booking untouched');
select is((select count(*)::int from public.audit_log where action = 'exam_cancelled' and target_id = (select id from st where name = 'a_draft')), 1, 'cancel audited');

select * from finish();
rollback;
