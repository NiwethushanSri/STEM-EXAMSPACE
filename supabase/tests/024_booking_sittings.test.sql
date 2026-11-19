begin;
create extension if not exists pgtap with schema extensions;
select plan(70);
select tests.assert_no_owner();

-- Fixtures.
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('admin', tests.create_user('admin', 'active'));
insert into c values ('teacher', tests.create_user('teacher', 'active'));
insert into c values ('parent', tests.create_user('parent', 'active'));
insert into c values ('s1', tests.create_user('student', 'active'));
insert into c values ('s2', tests.create_user('student', 'active'));
insert into c values ('s3', tests.create_user('student', 'active'));
insert into c values ('s4', tests.create_user('student', 'active'));
insert into c values ('s5', tests.create_user('student', 'active'));
insert into c values ('s6', tests.create_user('student', 'active'));
insert into c select 'h' || i, tests.create_user('student', 'active') from generate_series(1, 11) i;
insert into public.parent_children values ((select id from c where name = 'parent'), (select id from c where name = 's1'));
update public.student_details set index_number = 'SE-2031-9101' where profile_id = (select id from c where name = 's1');
update public.student_details set index_number = 'SE-2031-9102' where profile_id = (select id from c where name = 's2');

insert into public.subjects (name, kind) values ('ZZ Sittings', 'school');
insert into public.teacher_subjects values
  ((select id from c where name = 'teacher'), (select id from public.subjects where name = 'ZZ Sittings'));
insert into public.venues (name, rooms) values ('ZZ Sit Hall', array['R1']), ('ZZ Sit Annex', array['X1']);

create temp table ex (name text primary key, id uuid not null);
grant select on ex to public;
create temp table ctr (name text primary key, id uuid not null);
grant select on ctr to public;
create temp table st (name text primary key, id uuid);
grant all on st to public;

-- Free, published, price-confirmed exams (free bookings are paid at once, so no unpaid cap applies).
create function pg_temp.mk_exam(p_name text, p_format public.exam_format, p_starts timestamptz) returns void
language sql as $$
  with x as (
    insert into public.exams (subject_id, title, paper, format, starts_at, duration_minutes, price_pence,
      price_confirmed, booking_deadline, status)
    values ((select id from public.subjects where name = 'ZZ Sittings'), 'ZZ ' || p_name, 'P1', p_format, p_starts, 60,
      0, true, p_starts - interval '1 day', 'published')
    returning id)
  insert into ex select p_name, x.id from x
$$;
create function pg_temp.mk_centre(p_key text, p_exam text, p_venue text, p_room text, p_seats int) returns void
language sql as $$
  with y as (
    insert into public.exam_centres (exam_id, venue_id, room, seat_limit)
    values ((select id from ex where name = p_exam), (select id from public.venues where name = p_venue), p_room, p_seats)
    returning id)
  insert into ctr select p_key, y.id from y
$$;
-- A booking written directly, at the named centre or (null) at home.
create function pg_temp.book(p_key text, p_exam text, p_student text, p_status public.booking_status, p_centre text) returns void
language sql as $$
  with b as (
    insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting, centre_id)
    values ((select id from ex where name = p_exam), (select id from c where name = p_student),
      (select id from c where name = p_student), p_status, 0,
      case when p_centre is null then 'home'::public.sitting_mode else 'centre'::public.sitting_mode end,
      (select id from ctr where name = p_centre))
    returning id)
  insert into st select p_key, b.id from b
$$;

select pg_temp.mk_exam('ip1', 'in_person', now() + interval '30 days');
select pg_temp.mk_centre('ip1', 'ip1', 'ZZ Sit Hall', 'R1', 10);
select pg_temp.mk_exam('on1', 'online', now() + interval '30 days');
select pg_temp.mk_exam('both1', 'both', now() + interval '30 days');
select pg_temp.mk_centre('both1', 'both1', 'ZZ Sit Hall', 'R1', 10);
select pg_temp.mk_exam('multi', 'in_person', now() + interval '30 days');
select pg_temp.mk_centre('multi_A', 'multi', 'ZZ Sit Hall', 'R1', 1);
select pg_temp.mk_centre('multi_B', 'multi', 'ZZ Sit Annex', 'X1', 5);
select pg_temp.mk_exam('bothm', 'both', now() + interval '30 days');
select pg_temp.mk_centre('bothm_A', 'bothm', 'ZZ Sit Hall', 'R1', 1);
select pg_temp.mk_centre('bothm_B', 'bothm', 'ZZ Sit Annex', 'X1', 2);
select pg_temp.mk_exam('day', 'in_person', now() - interval '1 hour');
select pg_temp.mk_centre('day_A', 'day', 'ZZ Sit Hall', 'R1', 10);
select pg_temp.mk_centre('day_B', 'day', 'ZZ Sit Annex', 'X1', 10);
select pg_temp.mk_exam('dayboth', 'both', now() - interval '1 hour');
select pg_temp.mk_centre('dayboth_A', 'dayboth', 'ZZ Sit Hall', 'R1', 10);

-- Schema.
select is((select array_agg(e.enumlabel::text order by e.enumsortorder) from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'sitting_mode'), array['centre', 'home'], 'sitting_mode labels');
select throws_ok($$insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting) values ((select id from ex where name = 'ip1'), (select id from c where name = 's6'), (select id from c where name = 's6'), 'paid', 0, 'centre')$$, '23514', null, 'a centre booking needs a centre');
select throws_ok($$insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting, centre_id) values ((select id from ex where name = 'both1'), (select id from c where name = 's6'), (select id from c where name = 's6'), 'paid', 0, 'home', (select id from ctr where name = 'both1'))$$, '23514', null, 'a home booking has no centre');
select throws_ok($$insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting, centre_id) values ((select id from ex where name = 'on1'), (select id from c where name = 's6'), (select id from c where name = 's6'), 'paid', 0, 'centre', (select id from ctr where name = 'ip1'))$$, '23503', null, 'a booking''s centre belongs to its exam');
select throws_ok($$insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence) values ((select id from ex where name = 'on1'), (select id from c where name = 's6'), (select id from c where name = 's6'), 'paid', 0)$$, '23502', null, 'every booking records its sitting');
select is((select string_agg(proname || '/' || pronargs::text, ',' order by proname) from pg_proc where pronamespace = 'public'::regnamespace
  and proname in ('admin_add_booking', 'booking_create_as', 'booking_create_core', 'create_booking')),
  'admin_add_booking/6,booking_create_as/6,booking_create_core/9,create_booking/4', 'only the sitting-aware booking functions remain');
select is((select string_agg(proname || '(' || array_to_string(proargnames, ',') || ')', ' ' order by proname) from pg_proc where pronamespace = 'public'::regnamespace
  and proname in ('attendance_lookup', 'mark_attendance', 'close_register')),
  'attendance_lookup(p_centre,p_index) close_register(p_centre) mark_attendance(p_centre,p_student)', 'registers take a centre');
select ok(has_function_privilege('authenticated', 'public.change_booking_sitting(uuid,public.sitting_mode,uuid,text)', 'execute')
  and not has_function_privilege('anon', 'public.change_booking_sitting(uuid,public.sitting_mode,uuid,text)', 'execute')
  and has_function_privilege('authenticated', 'public.admin_add_booking(uuid,uuid,boolean,text,public.sitting_mode,uuid)', 'execute')
  and not has_function_privilege('anon', 'public.admin_add_booking(uuid,uuid,boolean,text,public.sitting_mode,uuid)', 'execute')
  and not has_function_privilege('anon', 'public.create_booking(uuid,uuid,public.sitting_mode,uuid)', 'execute'), 'booking grants as before; change_booking_sitting for signed-in callers only');

-- single_sitting_exam_needs_no_choice
select tests.as_user((select id from c where name = 's1'));
insert into st select 'b_ip', (public.create_booking((select id from ex where name = 'ip1'), (select id from c where name = 's1')) ->> 'id')::uuid;
insert into st select 'b_on', (public.create_booking((select id from ex where name = 'on1'), (select id from c where name = 's1')) ->> 'id')::uuid;
select isnt((select id from st where name = 'b_ip'), null, 'single_sitting_exam_needs_no_choice: an in-person exam books without a choice');
select isnt((select id from st where name = 'b_on'), null, 'so does an online exam');
select tests.as_postgres();
select is((select sitting::text || '/' || (centre_id = (select id from ctr where name = 'ip1'))::text from public.bookings where id = (select id from st where name = 'b_ip')), 'centre/true', 'booked at the exam''s only centre');
select is((select sitting::text || '/' || coalesce(centre_id::text, 'none') from public.bookings where id = (select id from st where name = 'b_on')), 'home/none', 'the online booking sits at home');

-- both_without_sitting_is_choose_sitting, and sittings an exam does not offer.
select tests.as_user((select id from c where name = 's2'));
select is(public.create_booking((select id from ex where name = 'both1'), (select id from c where name = 's2')) ->> 'code', 'choose_sitting', 'both_without_sitting_is_choose_sitting');
select is(public.create_booking((select id from ex where name = 'ip1'), (select id from c where name = 's2'), 'home') ->> 'code', 'sitting_not_offered', 'an in-person exam offers no home sitting');
select is(public.create_booking((select id from ex where name = 'on1'), (select id from c where name = 's2'), 'centre') ->> 'code', 'sitting_not_offered', 'an online exam offers no centre');
select is(public.create_booking((select id from ex where name = 'on1'), (select id from c where name = 's2'), 'home', (select id from ctr where name = 'ip1')) ->> 'code', 'invalid_input', 'a home sitting takes no centre');
select is(public.create_booking((select id from ex where name = 'both1'), (select id from c where name = 's2'), 'centre') ->> 'ok', 'true', 'choosing the centre books it');

-- several_centres_without_centre_is_choose_centre, centre_from_other_exam_refused
select is(public.create_booking((select id from ex where name = 'multi'), (select id from c where name = 's2')) ->> 'code', 'choose_centre', 'several_centres_without_centre_is_choose_centre');
select is(public.create_booking((select id from ex where name = 'multi'), (select id from c where name = 's2'), null, (select id from ctr where name = 'ip1')) ->> 'code', 'invalid_input', 'centre_from_other_exam_refused');
select is(public.create_booking((select id from ex where name = 'multi'), (select id from c where name = 's2'), 'centre', gen_random_uuid()) ->> 'code', 'invalid_input', 'an unknown centre is refused');

-- centre_full_but_other_centre_free (centre A has one seat)
select is(public.create_booking((select id from ex where name = 'multi'), (select id from c where name = 's2'), null, (select id from ctr where name = 'multi_A')) ->> 'ok', 'true', 'centre_full_but_other_centre_free: the last seat at centre A');
select tests.as_postgres(); select tests.as_user((select id from c where name = 's3'));
select is(public.create_booking((select id from ex where name = 'multi'), (select id from c where name = 's3'), null, (select id from ctr where name = 'multi_A')) ->> 'code', 'centre_full', 'centre A is then full');
select is(public.create_booking((select id from ex where name = 'multi'), (select id from c where name = 's3'), 'centre', (select id from ctr where name = 'multi_B')) ->> 'ok', 'true', 'centre B still has seats');
select tests.as_postgres(); select tests.as_user((select id from c where name = 'admin'));
select is(public.admin_add_booking((select id from ex where name = 'multi'), (select id from c where name = 's4'), true, null, null, (select id from ctr where name = 'multi_A')) ->> 'code', 'centre_full', 'admin bookings respect the centre''s seats');
select is(public.admin_add_booking((select id from ex where name = 'multi'), (select id from c where name = 's4'), true, null, 'centre', (select id from ctr where name = 'multi_B')) ->> 'ok', 'true', 'admin books the other centre');
select is(public.admin_add_booking((select id from ex where name = 'multi'), (select id from c where name = 's5'), true, null) ->> 'code', 'choose_centre', 'admin bookings choose a centre too');
select tests.as_postgres();
select is(public.centre_seats_taken((select id from ctr where name = 'multi_A'))::text || '/' || public.centre_seats_taken((select id from ctr where name = 'multi_B'))::text, '1/2', 'seats are counted per centre');

-- home_has_no_limit (the only centre has 10 seats)
select is((with h as materialized (select id from c where name like 'h%')
  select count(*)::int from h, lateral public.booking_create_as(h.id, (select id from ex where name = 'both1'), h.id, now(), 'home', null) r
  where r ->> 'ok' = 'true'), 11, 'home_has_no_limit: 11 home bookings on an exam whose only centre has 10 seats');
select is(public.centre_seats_taken((select id from ctr where name = 'both1')), 1, 'home bookings take no centre seat');

-- change_booking_sitting_checks_seats_and_audits (centre A: 1 seat, centre B: 2 seats)
select pg_temp.book('m_s1', 'bothm', 's1', 'paid', 'bothm_A');
select pg_temp.book('m_s2', 'bothm', 's2', 'paid', 'bothm_B');
select pg_temp.book('m_s3', 'bothm', 's3', 'paid', null);
select pg_temp.book('m_s5', 'bothm', 's5', 'cancelled', 'bothm_B');
select tests.as_user((select id from c where name = 'admin'));
select is(public.change_booking_sitting((select id from st where name = 'm_s3'), 'centre', (select id from ctr where name = 'bothm_A'), 'Moved to the hall') ->> 'code', 'centre_full', 'change_booking_sitting_checks_seats_and_audits: a full centre is refused');
select is(public.change_booking_sitting((select id from st where name = 'm_s3'), 'centre', (select id from ctr where name = 'bothm_B'), '  Moved to the annex  ') ->> 'ok', 'true', 'home to a centre with a seat');
select is(public.change_booking_sitting((select id from st where name = 'm_s2'), 'centre', (select id from ctr where name = 'bothm_B'), 'Again') ->> 'code', 'conflict', 'the same sitting and centre is nothing to change');
select is(public.change_booking_sitting((select id from st where name = 'm_s1'), 'centre', (select id from ctr where name = 'bothm_B'), 'Swap') ->> 'code', 'centre_full', 'centre B is now full');
select is(public.change_booking_sitting((select id from st where name = 'm_s1'), 'home', null, 'Sitting at home instead') ->> 'ok', 'true', 'centre to home frees the seat');
select is(public.change_booking_sitting((select id from st where name = 'm_s2'), 'centre', (select id from ctr where name = 'bothm_A'), 'Closer to home') ->> 'ok', 'true', 'from one centre to another');
select is(public.change_booking_sitting((select id from st where name = 'm_s2'), 'centre', (select id from ctr where name = 'bothm_B'), '   ') ->> 'code', 'invalid_input', 'a reason is required');
select is(public.change_booking_sitting((select id from st where name = 'm_s2'), 'centre', (select id from ctr where name = 'bothm_B'), repeat('r', 301)) ->> 'code', 'invalid_input', 'a reason is at most 300 characters');
select is(public.change_booking_sitting((select id from st where name = 'm_s2'), 'home', (select id from ctr where name = 'bothm_B'), 'r') ->> 'code', 'invalid_input', 'a home sitting takes no centre');
select is(public.change_booking_sitting((select id from st where name = 'm_s2'), 'centre', (select id from ctr where name = 'ip1'), 'r') ->> 'code', 'invalid_input', 'a centre of another exam is refused');
select is(public.change_booking_sitting((select id from st where name = 'm_s5'), 'home', null, 'r') ->> 'code', 'conflict', 'only live bookings move');
select is(public.change_booking_sitting((select id from st where name = 'b_ip'), 'home', null, 'r') ->> 'code', 'sitting_not_offered', 'an in-person exam offers no home sitting');
select is(public.change_booking_sitting(gen_random_uuid(), 'home', null, 'r') ->> 'code', 'not_found', 'unknown booking');
select tests.as_postgres();
select is((select string_agg(c.name || ':' || b.sitting::text || coalesce(':' || ctr.name, ''), ',' order by c.name)
  from public.bookings b join c on c.id = b.student_id left join ctr on ctr.id = b.centre_id
  where b.exam_id = (select id from ex where name = 'bothm') and b.status = 'paid'), 's1:home,s2:centre:bothm_A,s3:centre:bothm_B', 'each booking is where it was moved');
select is((select count(*)::int from public.audit_log where action = 'booking_sitting_changed' and target_type = 'booking' and actor_id = (select id from c where name = 'admin')
  and target_id in (select id from public.bookings where exam_id = (select id from ex where name = 'bothm'))), 3, 'each move is audited');
select is((select notes from public.bookings where id = (select id from st where name = 'm_s3')), 'sitting changed — Moved to the annex', 'the reason is kept on the booking');

-- family_cannot_change_sitting
select tests.as_user((select id from c where name = 's3'));
select is(public.change_booking_sitting((select id from st where name = 'm_s3'), 'home', null, 'I prefer home') ->> 'code', 'forbidden', 'family_cannot_change_sitting: the student');
select tests.as_postgres(); select tests.as_user((select id from c where name = 'parent'));
select is(public.change_booking_sitting((select id from st where name = 'm_s1'), 'centre', (select id from ctr where name = 'bothm_A'), 'Please') ->> 'code', 'forbidden', 'nor a linked parent');
select tests.as_postgres(); select tests.as_user((select id from c where name = 'teacher'));
select is(public.change_booking_sitting((select id from st where name = 'm_s1'), 'centre', (select id from ctr where name = 'bothm_A'), 'Please') ->> 'code', 'forbidden', 'nor a teacher');
select tests.as_postgres();
select is((select sitting::text from public.bookings where id = (select id from st where name = 'm_s1')), 'home', 'refused changes wrote nothing');

-- register_lists_only_that_centre (exam started an hour ago; centre A: s1, s3, s5 unpaid; centre B: s2, s4)
select pg_temp.book('d_s1', 'day', 's1', 'paid', 'day_A');
select pg_temp.book('d_s3', 'day', 's3', 'paid', 'day_A');
select pg_temp.book('d_s5', 'day', 's5', 'awaiting_payment', 'day_A');
select pg_temp.book('d_s2', 'day', 's2', 'paid', 'day_B');
select pg_temp.book('d_s4', 'day', 's4', 'cancel_requested', 'day_B');
select is(public.attendance_lookup_as((select id from c where name = 'teacher'), (select id from ctr where name = 'day_A'), 'SE-2031-9102'), '{"ok":true,"booked":false}'::jsonb, 'register_lists_only_that_centre: centre B''s candidate is not on centre A''s register');
select is(public.attendance_lookup_as((select id from c where name = 'teacher'), (select id from ctr where name = 'day_B'), 'SE-2031-9102') ->> 'booked', 'true', 'but is on centre B''s');
select is(public.attendance_lookup_as((select id from c where name = 'admin'), (select id from ctr where name = 'day_A'), 'SE-2031-9102') ->> 'booked', 'false', 'an admin sees the card, marked as not booked here');
select is(public.mark_attendance_as((select id from c where name = 'teacher'), (select id from ctr where name = 'day_A'), (select id from c where name = 's2'), now()) ->> 'code', 'not_booked', 'centre B''s candidate cannot be marked at centre A');
select is(public.mark_attendance_as((select id from c where name = 'teacher'), (select id from ctr where name = 'day_A'), (select id from c where name = 's1'), now()) ->> 'status', 'late', 'centre A''s candidate is marked (an hour in is late)');

-- close_register_marks_only_that_centre_absent
select is(public.close_register_as((select id from c where name = 'teacher'), (select id from ctr where name = 'day_A'), now()), '{"ok":true,"absent":1}'::jsonb, 'close_register_marks_only_that_centre_absent');
select is((select string_agg(c.name || ':' || a.status::text, ',' order by c.name) from public.attendance a join c on c.id = a.student_id
  where a.exam_id = (select id from ex where name = 'day')), 's1:late,s3:absent', 'nobody at centre B is marked');
select is((select status::text from public.bookings where id = (select id from st where name = 'd_s5')), 'expired', 'centre A''s unpaid booking expired');
select is((select string_agg((register_closed_at is not null)::text, '/' order by room) from public.exam_centres where exam_id = (select id from ex where name = 'day')), 'true/false', 'only centre A''s register is closed');
select is((select status::text from public.exams where id = (select id from ex where name = 'day')), 'published', 'the exam stays open while centre B''s register is open');
select is(public.mark_attendance_as((select id from c where name = 'teacher'), (select id from ctr where name = 'day_A'), (select id from c where name = 's3'), now()) ->> 'code', 'conflict', 'a closed register takes no more marks');
select is(public.close_register_as((select id from c where name = 'teacher'), (select id from ctr where name = 'day_A'), now()) ->> 'code', 'conflict', 'a register closes once');
select is(public.mark_attendance_as((select id from c where name = 'teacher'), (select id from ctr where name = 'day_B'), (select id from c where name = 's2'), now()) ->> 'status', 'late', 'centre B''s register still takes marks');
select is(public.close_register_as((select id from c where name = 'teacher'), (select id from ctr where name = 'day_B'), now()), '{"ok":true,"absent":1}'::jsonb, 'closing centre B marks its unscanned candidate absent');
select is((select status::text from public.exams where id = (select id from ex where name = 'day')), 'completed', 'the exam completes when its last register closes');
select is((select string_agg(action || '/' || target_type, ',' order by id) from public.audit_log
  where actor_id = (select id from c where name = 'teacher') and action in ('register_closed', 'exam_completed')
    and target_id in ((select id from ctr where name = 'day_A'), (select id from ctr where name = 'day_B'), (select id from ex where name = 'day'))),
  'register_closed/exam_centre,register_closed/exam_centre,exam_completed/exam', 'each register close is audited on its centre, then the exam''s completion');

-- home_candidate_not_on_any_register (s1 at home, s2 at the centre, s6 unpaid at home)
select pg_temp.book('db_s1', 'dayboth', 's1', 'paid', null);
select pg_temp.book('db_s2', 'dayboth', 's2', 'paid', 'dayboth_A');
select pg_temp.book('db_s6', 'dayboth', 's6', 'awaiting_payment', null);
select is(public.attendance_lookup_as((select id from c where name = 'teacher'), (select id from ctr where name = 'dayboth_A'), 'SE-2031-9101'), '{"ok":true,"booked":false}'::jsonb, 'home_candidate_not_on_any_register: not found on the centre''s register');
select is(public.mark_attendance_as((select id from c where name = 'teacher'), (select id from ctr where name = 'dayboth_A'), (select id from c where name = 's1'), now()) ->> 'code', 'not_booked', 'a home candidate cannot be marked');
select is(public.close_register_as((select id from c where name = 'teacher'), (select id from ctr where name = 'dayboth_A'), now()), '{"ok":true,"absent":1}'::jsonb, 'closing marks only the centre candidate absent');
select is((select count(*)::int from public.attendance where exam_id = (select id from ex where name = 'dayboth') and student_id = (select id from c where name = 's1')), 0, 'the home candidate is not marked absent');
select is((select status::text from public.bookings where id = (select id from st where name = 'db_s6')), 'expired', 'unpaid home bookings expire when the exam completes');

select * from finish();
rollback;
