begin;
create extension if not exists pgtap with schema extensions;
select plan(60);
select tests.assert_no_owner();

-- Enums.
select is((select array_agg(e.enumlabel::text order by e.enumsortorder) from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'exam_format'), array['in_person','online'], 'exam_format labels');
select is((select array_agg(e.enumlabel::text order by e.enumsortorder) from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'exam_status'), array['draft','published','cancelled','completed'], 'exam_status labels');
select is((select array_agg(e.enumlabel::text order by e.enumsortorder) from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'booking_status'), array['awaiting_payment','paid','cancel_requested','refunded','part_refunded','cancelled','expired'], 'booking_status labels');
select is((select array_agg(e.enumlabel::text order by e.enumsortorder) from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'attendance_status'), array['present','late','absent'], 'attendance_status labels');

-- Tables with RLS on.
select is((select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname in ('venues','exams','bookings','attendance') and c.relkind = 'r' and c.relrowsecurity), 4, 'four tables exist with RLS enabled');

-- Fixtures.
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('admin', tests.create_user('admin', 'active'));
insert into c values ('teacher', tests.create_user('teacher', 'active'));
insert into c values ('teacher2', tests.create_user('teacher', 'active'));
insert into c values ('tutor', tests.create_user('tutor', 'active'));
insert into c values ('tutor2', tests.create_user('tutor', 'active'));
insert into c values ('parent', tests.create_user('parent', 'active'));
insert into c values ('parent2', tests.create_user('parent', 'active'));
insert into c values ('s1', tests.create_user('student', 'active'));
insert into c values ('s2', tests.create_user('student', 'active'));
insert into c values ('s3', tests.create_user('student', 'active'));
insert into c values ('susp', tests.create_user('student', 'suspended'));

insert into public.subjects (name, kind) values ('ZZ Maths', 'school'), ('ZZ Physics', 'school');
create temp table subj (name text primary key, id bigint not null);
grant select on subj to public;
insert into subj select name, id from public.subjects where name in ('ZZ Maths','ZZ Physics');
insert into public.teacher_subjects values ((select id from c where name='teacher'), (select id from subj where name='ZZ Maths'));
insert into public.teacher_subjects values ((select id from c where name='teacher2'), (select id from subj where name='ZZ Physics'));
insert into public.parent_children values ((select id from c where name='parent'), (select id from c where name='s1'));
insert into public.tutor_students values ((select id from c where name='tutor'), (select id from c where name='s1'));

insert into public.venues (name, rooms) values ('ZZ Hall', array['A1','A2']);
create temp table v (id uuid not null);
grant select on v to public;
insert into v select id from public.venues where name = 'ZZ Hall';

create temp table ex (name text primary key, id uuid not null);
grant select on ex to public;
create temp table exdef (key text, subj text, title text, fmt text, seats int, st text);
insert into exdef values
  ('maths_pub','ZZ Maths','Maths mock','in_person',2,'published'),
  ('maths_draft','ZZ Maths','Maths draft','in_person',5,'draft'),
  ('phys_pub','ZZ Physics','Physics mock','online',5,'published'),
  ('phys_draft','ZZ Physics','Physics draft','online',5,'draft'),
  ('maths_canc','ZZ Maths','Maths cancelled','online',5,'cancelled');
insert into public.exams (subject_id, title, paper, format, venue_id, room, starts_at, duration_minutes, seat_limit, price_pence, booking_deadline, status, created_by)
select (select id from subj where name = d.subj), d.title, 'P1', d.fmt::public.exam_format,
  case when d.fmt = 'in_person' then (select id from v) end, case when d.fmt = 'in_person' then 'A1' end,
  now() + interval '30 days', 90, d.seats, 2500, now() + interval '20 days', d.st::public.exam_status,
  (select id from c where name='admin')
from exdef d;
insert into ex select d.key, e.id from exdef d join public.exams e on e.title = d.title;

-- Checks.
select throws_ok($$insert into public.exams (subject_id,title,paper,format,starts_at,duration_minutes,seat_limit,price_pence,booking_deadline,status,created_by) select (select id from subj limit 1),'x','p','online',now()+interval '5 days',60,0,100,now()+interval '4 days','draft',(select id from c where name='admin')$$, '23514', null, 'seat_limit must be > 0');
select throws_ok($$insert into public.exams (subject_id,title,paper,format,starts_at,duration_minutes,seat_limit,price_pence,booking_deadline,status,created_by) select (select id from subj limit 1),'x','p','online',now()+interval '5 days',60,5,-1,now()+interval '4 days','draft',(select id from c where name='admin')$$, '23514', null, 'price_pence must be >= 0');
select throws_ok($$insert into public.exams (subject_id,title,paper,format,starts_at,duration_minutes,seat_limit,price_pence,booking_deadline,status,created_by) select (select id from subj limit 1),'x','p','online',now()+interval '5 days',60,5,100,now()+interval '6 days','draft',(select id from c where name='admin')$$, '23514', null, 'booking_deadline must be <= starts_at');
select throws_ok($$insert into public.exams (subject_id,title,paper,format,venue_id,starts_at,duration_minutes,seat_limit,price_pence,booking_deadline,status,created_by) select (select id from subj limit 1),'x','p','online',(select id from v),now()+interval '5 days',60,5,100,now()+interval '4 days','draft',(select id from c where name='admin')$$, '23514', null, 'online exam must have no venue');
select throws_ok($$insert into public.exams (subject_id,title,paper,format,starts_at,duration_minutes,seat_limit,price_pence,booking_deadline,status,created_by) select (select id from subj limit 1),'x','p','in_person',now()+interval '5 days',60,5,100,now()+interval '4 days','draft',(select id from c where name='admin')$$, '23514', null, 'in_person exam needs a venue');
select throws_ok($$insert into public.exams (subject_id,title,paper,format,starts_at,duration_minutes,seat_limit,price_pence,booking_deadline,status,created_by) select (select id from subj limit 1),'x','p','online',now()+interval '5 days',0,5,100,now()+interval '4 days','draft',(select id from c where name='admin')$$, '23514', null, 'duration must be > 0');
select is((select currency from public.exams limit 1), 'gbp', 'currency defaults to gbp');
select throws_ok($$insert into public.venues (name) values ('ZZ Hall')$$, '23505', null, 'venue name unique');

-- Bookings and the partial unique index.
insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence) values
  ((select id from ex where name='maths_pub'), (select id from c where name='s1'), (select id from c where name='parent'), 'paid', 2500),
  ((select id from ex where name='maths_pub'), (select id from c where name='s2'), (select id from c where name='s2'), 'awaiting_payment', 2500),
  ((select id from ex where name='phys_pub'), (select id from c where name='s3'), (select id from c where name='s3'), 'paid', 2500);
select throws_ok($$insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence) values ((select id from ex where name='maths_pub'), (select id from c where name='s1'), (select id from c where name='s1'), 'awaiting_payment', 2500)$$, '23505', null, 'second active booking blocked');
insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence) values
  ((select id from ex where name='maths_pub'), (select id from c where name='s3'), (select id from c where name='s3'), 'expired', 2500),
  ((select id from ex where name='maths_pub'), (select id from c where name='s3'), (select id from c where name='s3'), 'cancelled', 2500);
select is((select count(*)::int from public.bookings where student_id = (select id from c where name='s3') and exam_id = (select id from ex where name='maths_pub')), 2, 'inactive bookings do not hit the unique index');
select is((select paid_offline from public.bookings limit 1), false, 'paid_offline defaults false');
select is((select refunded_pence from public.bookings limit 1), 0, 'refunded_pence defaults 0');

insert into public.attendance (exam_id, student_id, status, marked_by) values
  ((select id from ex where name='maths_pub'), (select id from c where name='s1'), 'present', (select id from c where name='admin')),
  ((select id from ex where name='phys_pub'), (select id from c where name='s3'), 'late', (select id from c where name='admin'));
select throws_ok($$insert into public.attendance (exam_id, student_id, status, marked_by) values ((select id from ex where name='maths_pub'), (select id from c where name='s1'), 'absent', (select id from c where name='admin'))$$, '23505', null, 'attendance primary key');

-- seats_taken.
select is(public.seats_taken((select id from ex where name='maths_pub')), 2, 'seats_taken counts paid + awaiting_payment only');
select is(has_function_privilege('anon', 'public.seats_taken(uuid)', 'execute'), false, 'seats_taken not anon');
select is(has_function_privilege('authenticated', 'public.seats_taken(uuid)', 'execute'), true, 'seats_taken authenticated');
select is(has_function_privilege('service_role', 'public.seats_taken(uuid)', 'execute'), true, 'seats_taken service_role');

-- seats_left never negative.
update public.bookings set status = 'cancel_requested' where student_id = (select id from c where name='s1') and exam_id = (select id from ex where name='maths_pub');
update public.exams set seat_limit = 1 where id = (select id from ex where name='maths_pub');
select is(public.seats_taken((select id from ex where name='maths_pub')), 2, 'cancel_requested still takes a seat');

-- Public view as anon.
set local role anon;
select is((select count(*)::int from public.exams_public where title in ('Maths mock','Maths draft','Physics mock','Physics draft','Maths cancelled')), 2, 'anon sees only the two published exams');
select is((select seats_left from public.exams_public where title = 'Maths mock'), 0, 'seats_left never negative (limit 1, taken 2)');
select is((select seats_left from public.exams_public where title = 'Physics mock'), 4, 'seats_left for other exam');
select is((select subject from public.exams_public where title = 'Maths mock'), 'ZZ Maths', 'subject name exposed');
select is((select venue from public.exams_public where title = 'Maths mock'), 'ZZ Hall', 'venue name exposed');
select is((select array_agg(a.attname::text order by a.attnum) from pg_attribute a where a.attrelid = 'public.exams_public'::regclass and a.attnum > 0 and not a.attisdropped),
  array['id','subject','title','paper','format','venue','room','starts_at','duration_minutes','price_pence','booking_deadline','seats_left'], 'view exposes only the listed columns');
select throws_ok($$select count(*) from public.bookings$$, '42501', null, 'anon cannot read bookings');
select throws_ok($$select count(*) from public.exams$$, '42501', null, 'anon cannot read exams');
select throws_ok($$select count(*) from public.attendance$$, '42501', null, 'anon cannot read attendance');
select throws_ok($$select count(*) from public.venues$$, '42501', null, 'anon cannot read venues');
select tests.as_postgres();
select is(has_table_privilege('authenticated', 'public.exams_public', 'select'), true, 'authenticated selects exams_public');
select is(has_table_privilege('authenticated', 'public.exams_public', 'insert'), false, 'view not writable by authenticated');
select is(has_table_privilege('anon', 'public.exams_public', 'insert'), false, 'view not writable by anon');

-- RLS matrix.
select tests.as_postgres();
select tests.as_user((select id from c where name='s1'));
select is((select count(*)::int from public.exams where title like 'Maths %' or title like 'Physics %'), 2, 'student reads published exams only');
select is((select count(*)::int from public.bookings), 1, 'student sees own booking only');
select is((select count(*)::int from public.attendance), 1, 'student sees own attendance only');
select is((select count(*)::int from public.venues where name = 'ZZ Hall'), 1, 'student reads venues');
select tests.as_postgres();
select tests.as_user((select id from c where name='s2'));
select is((select count(*)::int from public.attendance), 0, 'other student sees no attendance');
select tests.as_postgres();
select tests.as_user((select id from c where name='parent'));
select is((select count(*)::int from public.bookings), 1, 'parent sees linked child booking');
select is((select count(*)::int from public.attendance), 1, 'parent sees linked child attendance');
select is((select count(*)::int from public.exams where title like 'Maths %' or title like 'Physics %'), 2, 'parent reads published exams only');
select tests.as_postgres();
select tests.as_user((select id from c where name='parent2'));
select is((select count(*)::int from public.bookings) + (select count(*)::int from public.attendance), 0, 'unlinked parent sees nothing');
select tests.as_postgres();
select tests.as_user((select id from c where name='tutor'));
select is((select count(*)::int from public.bookings), 1, 'tutor sees assigned student booking');
select is((select count(*)::int from public.attendance), 1, 'tutor sees assigned student attendance');
select is((select count(*)::int from public.exams where title like 'Maths %' or title like 'Physics %'), 2, 'tutor reads published exams only');
select tests.as_postgres();
select tests.as_user((select id from c where name='tutor2'));
select is((select count(*)::int from public.bookings) + (select count(*)::int from public.attendance), 0, 'unassigned tutor sees nothing');
select tests.as_postgres();
select tests.as_user((select id from c where name='teacher'));
select is((select count(*)::int from public.exams where title like 'Maths %' or title like 'Physics %'), 4, 'teacher: published + own-subject draft and cancelled');
select is((select count(*)::int from public.bookings), 4, 'teacher sees bookings of own-subject exams only');
select is((select count(*)::int from public.attendance), 1, 'teacher sees attendance of own-subject exams only');
select tests.as_postgres();
select tests.as_user((select id from c where name='susp'));
select is((select count(*)::int from public.exams) + (select count(*)::int from public.bookings) + (select count(*)::int from public.venues), 0, 'suspended account reads nothing');
select tests.as_postgres();
select tests.as_user((select id from c where name='admin'));
select is((select count(*)::int from public.exams where title like 'Maths %' or title like 'Physics %'), 5, 'admin reads all exams');
select is((select count(*)::int from public.bookings), 5, 'admin reads all bookings');
select is((select count(*)::int from public.attendance), 2, 'admin reads all attendance');

-- No client writes anywhere (even admin).
select throws_ok($$insert into public.exams (subject_id,title,paper,format,starts_at,duration_minutes,seat_limit,price_pence,booking_deadline,status,created_by) select (select id from subj limit 1),'x','p','online',now()+interval '5 days',60,5,100,now()+interval '4 days','draft',(select id from c where name='admin')$$, '42501', null, 'admin cannot insert exams directly');
select throws_ok($$update public.bookings set status = 'paid'$$, '42501', null, 'admin cannot update bookings directly');
select throws_ok($$delete from public.attendance$$, '42501', null, 'admin cannot delete attendance directly');
select throws_ok($$insert into public.venues (name) values ('ZZ New')$$, '42501', null, 'admin cannot insert venues directly');

select * from finish();
rollback;
