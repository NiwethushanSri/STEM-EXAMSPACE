begin;
create extension if not exists pgtap with schema extensions;
select plan(67);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Exam e with two centres: ce1 (candidates s1 present, s2 late, s3 absent, s4 not marked, s7 unpaid) and ce2 (s6
-- present). s5 sits at home (present on no register). Staff: admin, suspended admin, teacher (teaches the subject),
-- teacher2 (does not), tutor, corrector, parent. Index numbers are given out of order on purpose.
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('admin', tests.create_user('admin', 'active')), ('admin2', tests.create_user('admin', 'suspended')),
  ('teacher', tests.create_user('teacher', 'active')), ('teacher2', tests.create_user('teacher', 'active')),
  ('tutor', tests.create_user('tutor', 'active')), ('corrector', tests.create_user('corrector', 'active')),
  ('tutor2', tests.create_user('tutor', 'suspended')), ('parent', tests.create_user('parent', 'active'));
insert into c select 's' || i, tests.create_user('student', 'active') from generate_series(1, 7) i;
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text) to public;

update public.profiles set first_name = 'Zelda', last_name = 'Quill' where id = pg_temp.uid('s1');
update public.profiles set first_name = 'Yusuf', last_name = 'Pike' where id = pg_temp.uid('s2');
update public.profiles set first_name = 'Xena', last_name = 'Oak' where id = pg_temp.uid('s3');
update public.student_details set index_number = case (select name from c where id = profile_id)
  when 's1' then 'SE-2031-0903' when 's2' then 'SE-2031-0901' when 's3' then 'SE-2031-0902' when 's4' then 'SE-2031-0904'
  when 's5' then 'SE-2031-0905' when 's6' then 'SE-2031-0906' when 's7' then 'SE-2031-0907' end
where profile_id in (select id from c where name like 's%');

insert into public.subjects (name, kind) values ('ZZ Collect', 'school'), ('ZZ Other', 'school');
insert into public.venues (name, rooms) values ('ZZ Collect hall', array['R1', 'R2']);
insert into public.exams (subject_id, title, paper, format, starts_at, duration_minutes, price_pence, price_confirmed, booking_deadline, status)
select s.id, 'ZZC e', 'P1', 'both', '2031-06-07 10:00 Europe/London', 90, 0, true, '2031-06-06 10:00 Europe/London', 'published'
from public.subjects s where s.name = 'ZZ Collect';
insert into kv select 'e', e.id from public.exams e where e.title = 'ZZC e';
insert into public.exams (subject_id, title, paper, format, starts_at, duration_minutes, price_pence, price_confirmed, booking_deadline, status)
select s.id, 'ZZC f', 'P1', 'both', '2031-06-08 10:00 Europe/London', 90, 0, true, '2031-06-07 10:00 Europe/London', 'published'
from public.subjects s where s.name = 'ZZ Collect';
insert into kv select 'f', e.id from public.exams e where e.title = 'ZZC f';
insert into public.teacher_subjects select pg_temp.uid('teacher'), id from public.subjects where name = 'ZZ Collect';
insert into public.teacher_subjects select pg_temp.uid('teacher2'), id from public.subjects where name = 'ZZ Other';
insert into public.exam_centres (exam_id, venue_id, room, seat_limit)
select pg_temp.k('e'), v.id, r, 50 from public.venues v, unnest(array['R1', 'R2']) r where v.name = 'ZZ Collect hall';
insert into kv select 'ce' || right(room, 1), id from public.exam_centres where exam_id = pg_temp.k('e');
insert into public.exam_centres (exam_id, venue_id, room, seat_limit)
select pg_temp.k('f'), v.id, 'R1', 50 from public.venues v where v.name = 'ZZ Collect hall';
insert into kv select 'cf', id from public.exam_centres where exam_id = pg_temp.k('f');

insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting, centre_id) values
  (pg_temp.k('e'), pg_temp.uid('s1'), pg_temp.uid('s1'), 'paid', 0, 'centre', pg_temp.k('ce1')),
  (pg_temp.k('e'), pg_temp.uid('s2'), pg_temp.uid('s2'), 'paid', 0, 'centre', pg_temp.k('ce1')),
  (pg_temp.k('e'), pg_temp.uid('s3'), pg_temp.uid('s3'), 'paid', 0, 'centre', pg_temp.k('ce1')),
  (pg_temp.k('e'), pg_temp.uid('s4'), pg_temp.uid('s4'), 'cancel_requested', 0, 'centre', pg_temp.k('ce1')),
  (pg_temp.k('e'), pg_temp.uid('s5'), pg_temp.uid('s5'), 'paid', 0, 'home', null),
  (pg_temp.k('e'), pg_temp.uid('s6'), pg_temp.uid('s6'), 'paid', 0, 'centre', pg_temp.k('ce2')),
  (pg_temp.k('e'), pg_temp.uid('s7'), pg_temp.uid('s7'), 'awaiting_payment', 0, 'centre', pg_temp.k('ce1'));
insert into kv select 'b' || right(s.name, 1), b.id from public.bookings b join c s on s.id = b.student_id where b.exam_id = pg_temp.k('e');
insert into public.attendance (exam_id, student_id, status, marked_by, marked_at)
select pg_temp.k('e'), pg_temp.uid(t.n), t.st::public.attendance_status, pg_temp.uid('admin'), '2031-06-07 09:00Z'
from (values ('s1', 'present'), ('s2', 'late'), ('s3', 'absent'), ('s5', 'present'), ('s6', 'present')) t(n, st);

create function pg_temp.rec(p_b text, p_n int) returns jsonb language sql as $$ select public.collection_record(pg_temp.k(p_b), p_n) $$;
create function pg_temp.man(p_centre text) returns jsonb language sql as $$ select public.collection_manifest_create(pg_temp.k('e'), pg_temp.k(p_centre)) $$;
create function pg_temp.cus(p_step text, p_from text, p_to text, p_loc text, p_note text) returns jsonb language sql as $$
  select public.custody_record(pg_temp.k('e'), pg_temp.k('ce1'), p_step, pg_temp.uid(p_from), pg_temp.uid(p_to), p_loc, p_note) $$;
grant execute on function pg_temp.rec(text, int), pg_temp.man(text), pg_temp.cus(text, text, text, text, text) to public;
create function pg_temp.code(j jsonb) returns text language sql immutable as $$ select coalesce(j ->> 'code', 'ok') $$;
grant execute on function pg_temp.code(jsonb) to public;

-- ----- tables are closed to signed-in users; functions are not open to anon -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select throws_ok($$select * from public.collection_counts$$, '42501', null, 'collection_counts is not readable directly');
select throws_ok($$select * from public.custody_events$$, '42501', null, 'custody_events is not readable directly');
select throws_ok($$select * from public.collection_manifests$$, '42501', null, 'collection_manifests is not readable directly');
select tests.as_postgres();
select is((select has_function_privilege('anon', 'public.collection_record(uuid, int)', 'execute')::text), 'false', 'anon cannot count sheets');

-- ----- collection_only_for_present_candidates -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(pg_temp.rec('b1', 3)), 'ok', 'a present candidate can have sheets recorded');
select is(pg_temp.code(pg_temp.rec('b2', 0)), 'ok', 'a late candidate can have sheets recorded');
select is(pg_temp.code(pg_temp.rec('b3', 1)), 'not_present', 'an absent candidate has nothing to collect');
select is(pg_temp.code(pg_temp.rec('b4', 1)), 'not_present', 'a candidate not marked yet has nothing to collect');
select is(pg_temp.code(pg_temp.rec('b7', 1)), 'not_present', 'an unpaid booking has nothing to collect');
select is(pg_temp.code(pg_temp.rec('b1', 51)), 'invalid_input', 'more than 50 extra sheets is refused');
select is(pg_temp.code(pg_temp.rec('b1', -1)), 'invalid_input', 'a negative count is refused');
select is(pg_temp.code(pg_temp.rec('b1', null)), 'invalid_input', 'no count is refused');
select is(pg_temp.code(public.collection_record(gen_random_uuid(), 1)), 'not_found', 'an unknown booking is not found');
select is(pg_temp.code(pg_temp.rec('b1', 50)), 'ok', '50 extra sheets is the largest count');
select is(pg_temp.code(pg_temp.rec('b1', 4)), 'ok', 'a count can be corrected');
select tests.as_postgres();
select is((select count(*)::int from public.collection_counts where exam_id = pg_temp.k('e')), 2, 'one count per candidate however often it is corrected');
select is((select extra_sheets from public.collection_counts where booking_id = pg_temp.k('b1')), 4, 'the latest count is kept');
select is((select count(*)::int from public.audit_log where action = 'collection_recorded' and actor_id = pg_temp.uid('admin')), 4,
  'each recording is audited');
select is((select count(*)::int from public.audit_log where action in ('collection_recorded', 'collection_manifest_created', 'custody_recorded')
           and target_type is distinct from case action when 'collection_recorded' then 'booking' when 'custody_recorded' then 'custody_event' else 'collection_manifest' end), 0,
  'audit rows name their target by id only');

-- ----- collection_requires_register_permission -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('teacher'));
select is(pg_temp.code(pg_temp.rec('b6', 2)), 'ok', 'a teacher of the exam''s subject can record');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('teacher2'));
select is(pg_temp.code(pg_temp.rec('b1', 2)), 'forbidden', 'a teacher of another subject cannot');
select is(pg_temp.code(pg_temp.man('ce1')), 'forbidden', 'nor create a manifest');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(pg_temp.code(pg_temp.rec('b1', 2)), 'forbidden', 'a student cannot');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('parent'));
select is(pg_temp.code(pg_temp.rec('b1', 2)), 'forbidden', 'a parent cannot');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin2'));
select is(pg_temp.code(pg_temp.rec('b1', 2)), 'forbidden', 'a suspended admin cannot');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('tutor'));
select is(pg_temp.code(pg_temp.cus('collected', 'tutor', 'admin', 'Front desk', null)), 'forbidden', 'a tutor cannot record custody');
select tests.as_postgres();
select is((select extra_sheets from public.collection_counts where booking_id = pg_temp.k('b1')), 4, 'a refused attempt changes nothing');

-- ----- manifest_rows_in_index_order -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
create temp table m1 as select pg_temp.man('ce1') j;
grant select on m1 to public;
select is((select j ->> 'number' from m1), 'M-' || (select exam_code from public.exams where id = pg_temp.k('e')) || '-01', 'the first manifest is numbered 01');
select is((select string_agg(r ->> 'index_number', ',') from m1, jsonb_array_elements(j -> 'rows') r),
  'SE-2031-0901,SE-2031-0902,SE-2031-0903,SE-2031-0904', 'rows are in index-number order: this centre''s paid and cancel-requested candidates only');
select is((select string_agg(r ->> 'name', ',') from m1, jsonb_array_elements(j -> 'rows') r), 'Yusuf Pike,Xena Oak,Zelda Quill,' || (select btrim(p.first_name || ' ' || p.last_name) from public.profiles p where p.id = pg_temp.uid('s4')),
  'each row carries the candidate''s name');
select is((select string_agg(coalesce(r ->> 'attendance', '?') || ':' || coalesce(r ->> 'extra_sheets', '-'), ',') from m1, jsonb_array_elements(j -> 'rows') r),
  'late:0,absent:-,present:4,not_marked:-', 'attendance and sheets per row; absent and unmarked candidates have no sheets');
select tests.as_postgres();
select is((select j ->> 'manifest_id' from m1), (select id::text from public.collection_manifests where number = (select j ->> 'number' from m1)), 'the manifest id is the stored one');
insert into kv select 'm1', id from public.collection_manifests where number like '%-01';
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.man('ce1') ->> 'number', 'M-' || (select exam_code from public.exams where id = pg_temp.k('e')) || '-02', 'printing again makes a new number');
select is(pg_temp.man('ce2') ->> 'number', 'M-' || (select exam_code from public.exams where id = pg_temp.k('e')) || '-03', 'numbers run on across the exam''s centres');
select tests.as_postgres();
insert into kv select 'm3', id from public.collection_manifests where number like '%-03';
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is((select count(*)::int from jsonb_array_elements(pg_temp.man('ce2') -> 'rows')), 1, 'the other centre lists only its own candidate');
select is(pg_temp.code(public.collection_manifest_create(pg_temp.k('e'), pg_temp.k('cf'))), 'not_found', 'a centre of another exam is not found');
select is(pg_temp.code(public.collection_manifest_create(pg_temp.k('e'), null)), 'invalid_input', 'no centre is refused');
select tests.as_postgres();
select is((select count(*)::int from public.audit_log where action = 'collection_manifest_created'), 4, 'each manifest is audited');

-- ----- custody_steps_and_lengths_checked -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(pg_temp.cus('collected', 'teacher', null, 'Exam room R1', null)), 'ok', 'a collection by a teacher is recorded');
select is(pg_temp.code(pg_temp.cus('handed_over', 'teacher', 'admin', 'Front desk', 'Sealed bag 1')), 'ok', 'a handover is recorded');
select is(pg_temp.code(pg_temp.cus('archived', null, null, 'Strong room', 'Locked away')), 'ok', 'a note alone can say who');
select is(pg_temp.code(pg_temp.cus('shredded', 'teacher', null, 'Room', null)), 'invalid_input', 'an unknown step is refused');
select is(pg_temp.code(pg_temp.cus('collected', null, null, 'Room', null)), 'invalid_input', 'someone or a note must say who');
select is(pg_temp.code(pg_temp.cus('collected', 'teacher', null, '', null)), 'invalid_input', 'a place is required');
select is(pg_temp.code(pg_temp.cus('collected', 'teacher', null, '   ', null)), 'invalid_input', 'a blank place is refused');
select is(pg_temp.code(pg_temp.cus('collected', 'teacher', null, null, null)), 'invalid_input', 'no place is refused');
select is(pg_temp.code(pg_temp.cus('collected', 'teacher', null, repeat('x', 121), null)), 'invalid_input', 'a place over 120 characters is refused');
select is(pg_temp.code(pg_temp.cus('collected', 'teacher', null, repeat('x', 120), null)), 'ok', 'a place of 120 characters is allowed');
select is(pg_temp.code(pg_temp.cus('collected', 'teacher', null, 'Room', repeat('n', 301))), 'invalid_input', 'a note over 300 characters is refused');
select is(pg_temp.code(pg_temp.cus('collected', 'teacher', null, 'Room', repeat('n', 300))), 'ok', 'a note of 300 characters is allowed');
select is(pg_temp.code(public.custody_record(pg_temp.k('e'), pg_temp.k('cf'), 'collected', pg_temp.uid('teacher'), null, 'Room', null)), 'not_found', 'a centre of another exam is not found');
select is(pg_temp.code(public.custody_record(pg_temp.k('e'), pg_temp.k('ce1'), 'collected', pg_temp.uid('teacher'), null, 'Room', null, pg_temp.k('m3'))), 'not_found',
  'a manifest of another centre is not found');
select is(pg_temp.code(public.custody_record(pg_temp.k('e'), pg_temp.k('ce1'), 'collected', pg_temp.uid('teacher'), null, 'Room', null, pg_temp.k('m1'))), 'ok',
  'a manifest of this centre can be named');

-- ----- custody_staff_must_be_staff_accounts -----
select is(pg_temp.code(pg_temp.cus('handed_over', 'corrector', 'tutor', 'Marking office', null)), 'ok', 'tutors and correctors are staff');
select is(pg_temp.code(pg_temp.cus('handed_over', 's1', 'admin', 'Room', null)), 'invalid_staff', 'a student is not staff');
select is(pg_temp.code(pg_temp.cus('handed_over', 'teacher', 'parent', 'Room', null)), 'invalid_staff', 'a parent is not staff');
select is(pg_temp.code(pg_temp.cus('handed_over', 'admin2', null, 'Room', null)), 'invalid_staff', 'a suspended account is not staff');
select is(pg_temp.code(pg_temp.cus('handed_over', 'teacher', 'tutor2', 'Room', null)), 'invalid_staff', 'a suspended tutor is not staff');

select is((select count(*)::int from jsonb_array_elements(public.custody_list(pg_temp.k('e'), pg_temp.k('ce1')) -> 'events')), 7, 'the list holds every recorded event');
select is((select string_agg(x ->> 'step', ',') from jsonb_array_elements(public.custody_list(pg_temp.k('e'), pg_temp.k('ce1')) -> 'events') x
           where x ->> 'note' in ('Sealed bag 1', 'Locked away')), 'handed_over,archived', 'events come back in the order they happened');
select is(pg_temp.code(public.custody_list(pg_temp.k('e'), pg_temp.k('ce2'))), 'ok', 'a centre with no events has an empty list');
select tests.as_postgres();
select is((select count(*)::int from public.audit_log where action = 'custody_recorded'), 7, 'each custody event is audited');

-- ----- what the screens read -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('teacher'));
select is((select string_agg((r ->> 'index_number') || ':' || coalesce(r ->> 'extra_sheets', '-'), ',')
           from jsonb_array_elements(public.collection_list(pg_temp.k('e'), pg_temp.k('ce1')) -> 'rows') r),
  'SE-2031-0901:0,SE-2031-0903:4', 'the collection list holds present and late candidates of the centre, in index order, with their sheets');
select is((select count(*)::int from jsonb_array_elements(public.custody_staff(pg_temp.k('e'), pg_temp.k('ce1')) -> 'staff') x
           where x ->> 'role' in ('student', 'parent') or (x ->> 'id')::uuid in (pg_temp.uid('admin2'), pg_temp.uid('tutor2'))), 0,
  'the staff list has no students, parents or suspended accounts');
select ok((select count(*) from jsonb_array_elements(public.custody_staff(pg_temp.k('e'), pg_temp.k('ce1')) -> 'staff') x
           where (x ->> 'id')::uuid in (pg_temp.uid('admin'), pg_temp.uid('teacher'), pg_temp.uid('tutor'), pg_temp.uid('corrector'))) = 4,
  'the staff list has the active admin, teacher, tutor and corrector');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('teacher2'));
select is(pg_temp.code(public.collection_list(pg_temp.k('e'), pg_temp.k('ce1'))), 'forbidden', 'a teacher of another subject cannot list collection');
select is(pg_temp.code(public.custody_staff(pg_temp.k('e'), pg_temp.k('ce1'))), 'forbidden', 'nor the staff');
select tests.as_postgres();

select * from finish();
rollback;
