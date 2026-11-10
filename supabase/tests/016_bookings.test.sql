begin;
create extension if not exists pgtap with schema extensions;
select plan(100);
select tests.assert_no_owner();

-- Fixtures.
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('admin', tests.create_user('admin', 'active'));
insert into c values ('teacher', tests.create_user('teacher', 'active'));
insert into c values ('parent', tests.create_user('parent', 'active'));
insert into c values ('parent2', tests.create_user('parent', 'active'));
insert into c values ('s1', tests.create_user('student', 'active'));
insert into c values ('s2', tests.create_user('student', 'active'));
insert into c values ('s3', tests.create_user('student', 'active'));
insert into c values ('s4', tests.create_user('student', 'active'));
insert into c values ('sp', tests.create_user('student', 'pending'));
insert into c values ('sd', tests.create_user('student', 'active'));
insert into public.parent_children values
  ((select id from c where name = 'parent'), (select id from c where name = 's2')),
  ((select id from c where name = 'parent'), (select id from c where name = 'sp')),
  ((select id from c where name = 'parent2'), (select id from c where name = 's4'));

insert into public.subjects (name, kind) values ('ZZ Bookings', 'school');
create temp table st (name text primary key, id uuid);
grant all on st to public;

-- Published, price-confirmed online exams.
create temp table ex (name text primary key, id uuid not null);
grant select on ex to public;
create function pg_temp.mk_exam(p_name text, p_seats int, p_price int, p_deadline timestamptz, p_starts timestamptz,
  p_status public.exam_status default 'published', p_confirmed boolean default true) returns void
language plpgsql as $$
begin
  with x as (
    insert into public.exams (subject_id, title, paper, format, starts_at, duration_minutes, seat_limit, price_pence,
      price_confirmed, booking_deadline, status)
    values ((select id from public.subjects where name = 'ZZ Bookings'), 'ZZ ' || p_name, 'P1', 'online', p_starts, 60,
      p_seats, p_price, p_confirmed, p_deadline, p_status)
    returning id)
  insert into ex select p_name, x.id from x;
end; $$;
-- Helper: insert a booking row directly and stash its id.
create function pg_temp.mk_booking(p_key text, p_exam text, p_student text, p_status public.booking_status, p_amount int, p_refunded int default 0) returns void
language plpgsql as $$
begin
  with x as (
    insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, refunded_pence)
    values ((select id from ex where name = p_exam), (select id from c where name = p_student),
      (select id from c where name = p_student), p_status, p_amount, p_refunded)
    returning id)
  insert into st select p_key, x.id from x;
end; $$;

select pg_temp.mk_exam('e1', 10, 1000, now() + interval '10 days', now() + interval '20 days');
select pg_temp.mk_exam('free', 10, 0, now() + interval '10 days', now() + interval '20 days');
select pg_temp.mk_exam('one', 1, 500, now() + interval '10 days', now() + interval '20 days');
select pg_temp.mk_exam('dl', 10, 800, date_trunc('second', now()) + interval '5 days', now() + interval '20 days');
select pg_temp.mk_exam('late', 10, 800, now() - interval '1 day', now() + interval '5 days');
select pg_temp.mk_exam('draft', 10, 800, now() + interval '10 days', now() + interval '20 days', 'draft');
select pg_temp.mk_exam('unconf', 10, 800, now() + interval '10 days', now() + interval '20 days', 'published', false);
select pg_temp.mk_exam('past', 10, 800, now() - interval '3 days', now() - interval '2 days');
select pg_temp.mk_exam('cx', 10, 800, now() + interval '10 days', now() + interval '20 days', 'cancelled');
select pg_temp.mk_exam('refund', 10, 1000, now() + interval '10 days', now() + interval '20 days');
select pg_temp.mk_exam('dec', 10, 1000, now() + interval '10 days', now() + interval '20 days');
select pg_temp.mk_exam('exp', 10, 1000, now() - interval '1 day', now() + interval '20 days');
select pg_temp.mk_exam('xc', 10, 1000, now() + interval '10 days', now() + interval '20 days');
select pg_temp.mk_exam('xf', 10, 0, now() + interval '10 days', now() + interval '20 days');
select pg_temp.mk_exam('del1', 10, 1000, now() + interval '10 days', now() + interval '20 days');
select pg_temp.mk_exam('del2', 10, 1000, now() + interval '10 days', now() + interval '20 days');
select pg_temp.mk_exam('del3', 10, 0, now() + interval '10 days', now() + interval '20 days');

-- Privileges.
select is(has_function_privilege('anon', 'public.create_booking(uuid,uuid)', 'execute'), false, 'create_booking: not anon');
select is(has_function_privilege('authenticated', 'public.create_booking(uuid,uuid)', 'execute'), true, 'create_booking: authenticated');
select is(has_function_privilege('anon', 'public.decide_cancellation(uuid,boolean,integer,text)', 'execute'), false, 'decide_cancellation: not anon');
select is(has_function_privilege('authenticated', 'public.decide_cancellation(uuid,boolean,integer,text)', 'execute'), true, 'decide_cancellation: authenticated');
select is(has_function_privilege('authenticated', 'public.expire_unpaid_bookings(timestamptz)', 'execute'), false, 'expire_unpaid_bookings: no client grant');
select is(has_function_privilege('authenticated', 'public.booking_create_as(uuid,uuid,uuid,timestamptz)', 'execute'), false, 'booking_create_as: no client grant');
select is(has_function_privilege('authenticated', 'public.booking_create_core(uuid,uuid,uuid,timestamptz,boolean,boolean,text)', 'execute'), false, 'booking_create_core: no client grant');
select is(has_function_privilege('authenticated', 'public.request_cancellation_as(uuid,uuid,timestamptz)', 'execute'), false, 'request_cancellation_as: no client grant');

-- student_books_self
select tests.as_postgres(); select tests.as_user((select id from c where name = 's1'));
insert into st select 'b1', (public.create_booking((select id from ex where name = 'e1'), (select id from c where name = 's1')) ->> 'id')::uuid;
select isnt((select id from st where name = 'b1'), null, 'student_books_self');
select is(public.create_booking((select id from ex where name = 'e1'), (select id from c where name = 's2')) ->> 'code', 'forbidden', 'student cannot book another student');
select is(public.create_booking((select id from ex where name = 'e1'), (select id from c where name = 's1')) ->> 'code', 'already_booked', 'already_booked');
select tests.as_postgres();
select is((select status::text || '/' || amount_pence || '/' || paid_offline from public.bookings where id = (select id from st where name = 'b1')), 'awaiting_payment/1000/false', 'booking awaits payment at the exam price');
select is((select booked_by from public.bookings where id = (select id from st where name = 'b1')), (select id from c where name = 's1'), 'booked_by is the caller');
select is((select count(*)::int from public.audit_log where action = 'booking_created' and target_type = 'booking' and target_id = (select id from st where name = 'b1')), 1, 'creation audited');

-- parent_books_linked_child / parent_cannot_book_unlinked / pending
select tests.as_postgres(); select tests.as_user((select id from c where name = 'parent'));
insert into st select 'b2', (public.create_booking((select id from ex where name = 'e1'), (select id from c where name = 's2')) ->> 'id')::uuid;
select isnt((select id from st where name = 'b2'), null, 'parent_books_linked_child');
select is(public.create_booking((select id from ex where name = 'e1'), (select id from c where name = 's3')) ->> 'code', 'forbidden', 'parent_cannot_book_unlinked');
select is(public.create_booking((select id from ex where name = 'e1'), (select id from c where name = 'sp')) ->> 'code', 'invalid_input', 'pending_student_cannot_be_booked (by parent)');
select tests.as_postgres();
select is((select booked_by from public.bookings where id = (select id from st where name = 'b2')), (select id from c where name = 'parent'), 'booked_by is the parent');
select tests.as_postgres(); select tests.as_user((select id from c where name = 'sp'));
select is(public.create_booking((select id from ex where name = 'e1'), (select id from c where name = 'sp')) ->> 'code', 'forbidden', 'pending student cannot book self');
select tests.as_postgres(); select tests.as_user((select id from c where name = 'teacher'));
select is(public.create_booking((select id from ex where name = 'e1'), (select id from c where name = 's3')) ->> 'code', 'forbidden', 'teacher cannot book');
select tests.as_postgres();
select set_config('request.jwt.claims', '', true);
select is(public.create_booking((select id from ex where name = 'e1'), (select id from c where name = 's3')) ->> 'code', 'forbidden', 'no session cannot book');

-- not_bookable
select is(public.booking_create_as((select id from c where name = 's3'), (select id from ex where name = 'draft'), (select id from c where name = 's3'), now()) ->> 'code', 'not_bookable', 'draft exam not bookable');
select is(public.booking_create_as((select id from c where name = 's3'), (select id from ex where name = 'unconf'), (select id from c where name = 's3'), now()) ->> 'code', 'not_bookable', 'unconfirmed price not bookable');
select is(public.booking_create_as((select id from c where name = 's3'), (select id from ex where name = 'past'), (select id from c where name = 's3'), now()) ->> 'code', 'not_bookable', 'started exam not bookable');
select is(public.booking_create_as((select id from c where name = 's3'), (select id from ex where name = 'cx'), (select id from c where name = 's3'), now()) ->> 'code', 'not_bookable', 'cancelled exam not bookable');
select is(public.booking_create_as((select id from c where name = 's3'), gen_random_uuid(), (select id from c where name = 's3'), now()) ->> 'code', 'not_found', 'unknown exam');

-- deadline_boundary
select is(public.booking_create_as((select id from c where name = 's3'), (select id from ex where name = 'dl'), (select id from c where name = 's3'),
  (select booking_deadline - interval '1 second' from public.exams where id = (select id from ex where name = 'dl'))) ->> 'ok', 'true', 'deadline_boundary: one second before is ok');
select is(public.booking_create_as((select id from c where name = 's4'), (select id from ex where name = 'dl'), (select id from c where name = 's4'),
  (select booking_deadline from public.exams where id = (select id from ex where name = 'dl'))) ->> 'code', 'deadline_passed', 'deadline_boundary: exactly at the deadline is refused');
select is(public.booking_create_as((select id from c where name = 's4'), (select id from ex where name = 'dl'), (select id from c where name = 's4'),
  (select booking_deadline + interval '1 second' from public.exams where id = (select id from ex where name = 'dl'))) ->> 'code', 'deadline_passed', 'deadline_boundary: after is refused');
select tests.as_postgres(); select tests.as_user((select id from c where name = 's4'));
select is(public.create_booking((select id from ex where name = 'late'), (select id from c where name = 's4')) ->> 'code', 'deadline_passed', 'client RPC uses now()');
select tests.as_postgres();

-- fully_booked
select tests.as_postgres(); select tests.as_user((select id from c where name = 's1'));
insert into st select 'one1', (public.create_booking((select id from ex where name = 'one'), (select id from c where name = 's1')) ->> 'id')::uuid;
select tests.as_postgres(); select tests.as_user((select id from c where name = 's4'));
select is(public.create_booking((select id from ex where name = 'one'), (select id from c where name = 's4')) ->> 'code', 'fully_booked', 'fully_booked');
select tests.as_postgres();

-- free_exam_paid_immediately
select tests.as_postgres(); select tests.as_user((select id from c where name = 's1'));
insert into st select 'free1', (public.create_booking((select id from ex where name = 'free'), (select id from c where name = 's1')) ->> 'id')::uuid;
select tests.as_postgres();
select is((select status::text || '/' || amount_pence || '/' || paid_offline from public.bookings where id = (select id from st where name = 'free1')), 'paid/0/false', 'free_exam_paid_immediately');

-- Admin add / mark paid / cancel.
select tests.as_postgres(); select tests.as_user((select id from c where name = 's1'));
select is(public.admin_add_booking((select id from ex where name = 'e1'), (select id from c where name = 's3'), true, null) ->> 'code', 'forbidden', 'student cannot admin_add_booking');
select is(public.mark_booking_paid((select id from st where name = 'b1'), null) ->> 'code', 'forbidden', 'student cannot mark paid');
select is(public.cancel_booking_admin((select id from st where name = 'b1'), null) ->> 'code', 'forbidden', 'student cannot admin-cancel');
select is(public.decide_cancellation((select id from st where name = 'b1'), true, 0, null) ->> 'code', 'forbidden', 'student cannot decide');
select tests.as_postgres(); select tests.as_user((select id from c where name = 'admin'));
insert into st select 'a1', (public.admin_add_booking((select id from ex where name = 'late'), (select id from c where name = 's3'), true, '  cash at desk ') ->> 'id')::uuid;
select isnt((select id from st where name = 'a1'), null, 'admin adds a booking ignoring the deadline');
select is(public.admin_add_booking((select id from ex where name = 'one'), (select id from c where name = 's4'), false, null) ->> 'code', 'fully_booked', 'admin add respects seat limit');
select is(public.admin_add_booking((select id from ex where name = 'e1'), (select id from c where name = 'sp'), false, null) ->> 'code', 'invalid_input', 'admin cannot add a pending student');
select is(public.admin_add_booking((select id from ex where name = 'e1'), (select id from c where name = 's1'), false, null) ->> 'code', 'already_booked', 'admin add respects one active booking');
select is(public.mark_booking_paid((select id from st where name = 'b2'), 'bank transfer') ->> 'ok', 'true', 'admin_marks_paid');
select is(public.mark_booking_paid((select id from st where name = 'b2'), null) ->> 'code', 'conflict', 'cannot mark paid twice');
select is(public.mark_booking_paid(gen_random_uuid(), null) ->> 'code', 'not_found', 'mark paid unknown booking');
select is(public.cancel_booking_admin((select id from st where name = 'b2'), null) ->> 'code', 'conflict', 'cannot admin-cancel a paid booking');
select is(public.cancel_booking_admin((select id from st where name = 'b1'), 'no show') ->> 'ok', 'true', 'admin cancels an awaiting booking');
select tests.as_postgres();
select is((select status::text || '/' || paid_offline || '/' || notes from public.bookings where id = (select id from st where name = 'a1')), 'paid/true/cash at desk', 'admin booking paid offline with trimmed note');
select is((select status::text || '/' || paid_offline from public.bookings where id = (select id from st where name = 'b2')), 'paid/true', 'marked paid offline');
select is((select status::text from public.bookings where id = (select id from st where name = 'b1')), 'cancelled', 'awaiting booking cancelled');
select is((select count(*)::int from public.audit_log where target_type = 'booking' and actor_id = (select id from c where name = 'admin')
  and action in ('booking_marked_paid', 'booking_cancelled_by_admin') and target_id in (select id from st)), 2, 'admin actions audited');
select is(public.seats_taken((select id from ex where name = 'e1')), 1, 'cancelled booking released its seat');

-- request_and_partial_refund (b2 is paid for s2, parent is linked)
select tests.as_postgres(); select tests.as_user((select id from c where name = 'parent2'));
select is(public.request_cancellation((select id from st where name = 'b2')) ->> 'code', 'forbidden', 'unlinked parent cannot request cancellation');
select tests.as_postgres(); select tests.as_user((select id from c where name = 's4'));
select is(public.request_cancellation((select id from st where name = 'b2')) ->> 'code', 'forbidden', 'other student cannot request cancellation');
select tests.as_postgres(); select tests.as_user((select id from c where name = 'parent'));
select is(public.request_cancellation((select id from st where name = 'b2')) ->> 'ok', 'true', 'linked parent requests cancellation');
select is(public.request_cancellation((select id from st where name = 'b2')) ->> 'code', 'conflict', 'cannot request twice');
select tests.as_postgres();
select is((select status::text from public.bookings where id = (select id from st where name = 'b2')), 'cancel_requested', 'status cancel_requested');
select is(public.seats_taken((select id from ex where name = 'e1')), 1, 'seat still held while cancel is requested');
select tests.as_postgres(); select tests.as_user((select id from c where name = 'admin'));
select is(public.decide_cancellation((select id from st where name = 'b2'), true, 1001, null) ->> 'code', 'invalid_input', 'refund above amount refused');
select is(public.decide_cancellation((select id from st where name = 'b2'), true, -1, null) ->> 'code', 'invalid_input', 'negative refund refused');
select is(public.decide_cancellation((select id from st where name = 'b2'), true, 400, 'goodwill') ->> 'ok', 'true', 'request_and_partial_refund');
select tests.as_postgres();
select is((select status::text || '/' || refunded_pence || '/' || refund_due from public.bookings where id = (select id from st where name = 'b2')), 'part_refunded/400/false', 'part_refunded with amount recorded');
select is(public.seats_taken((select id from ex where name = 'e1')), 0, 'seat released after approval');
select tests.as_postgres(); select tests.as_user((select id from c where name = 'admin'));
select is(public.decide_cancellation((select id from st where name = 'b2'), true, 100, null) ->> 'code', 'conflict', 'part_refunded without refund_due is not decidable');
select is(public.decide_cancellation((select id from st where name = 'b2'), false, 0, null) ->> 'code', 'conflict', 'cannot decline a decided booking');
select tests.as_postgres();
select is((select count(*)::int from public.audit_log where action in ('booking_cancellation_requested', 'booking_cancellation_approved') and target_id = (select id from st where name = 'b2')), 2, 'cancellation request and approval audited');

-- Full refund, zero refund, request after the exam starts.
select pg_temp.mk_booking('r1', 'refund', 's1', 'paid', 1000);
select pg_temp.mk_booking('r2', 'refund', 's2', 'paid', 1000);
select is(public.request_cancellation_as((select id from c where name = 's1'), (select id from st where name = 'r1'),
  (select starts_at from public.exams where id = (select id from ex where name = 'refund'))) ->> 'code', 'conflict', 'no cancellation request once the exam has started');
select is(public.request_cancellation_as((select id from c where name = 's1'), (select id from st where name = 'r1'), now()) ->> 'ok', 'true', 'cancellation request before start');
select is(public.request_cancellation_as((select id from c where name = 's2'), (select id from st where name = 'r2'), now()) ->> 'ok', 'true', 'second request');
select tests.as_postgres(); select tests.as_user((select id from c where name = 'admin'));
select is(public.decide_cancellation((select id from st where name = 'r1'), true, 1000, null) ->> 'ok', 'true', 'full refund approved');
select is(public.decide_cancellation((select id from st where name = 'r2'), true, 0, 'no refund') ->> 'ok', 'true', 'zero refund approved');
select tests.as_postgres();
select is((select status::text || '/' || refunded_pence from public.bookings where id = (select id from st where name = 'r1')), 'refunded/1000', 'full refund -> refunded');
select is((select status::text || '/' || refunded_pence from public.bookings where id = (select id from st where name = 'r2')), 'cancelled/0', 'zero refund -> cancelled');

-- decline_returns_to_paid
select pg_temp.mk_booking('d1', 'dec', 's1', 'paid', 1000);
select is(public.request_cancellation_as((select id from c where name = 's1'), (select id from st where name = 'd1'), now()) ->> 'ok', 'true', 'request for decline');
select tests.as_postgres(); select tests.as_user((select id from c where name = 'admin'));
select is(public.decide_cancellation((select id from st where name = 'd1'), false, null, 'keep') ->> 'ok', 'true', 'decline_returns_to_paid');
select tests.as_postgres();
select is((select status::text || '/' || refunded_pence from public.bookings where id = (select id from st where name = 'd1')), 'paid/0', 'declined booking is paid again');
select is(public.seats_taken((select id from ex where name = 'dec')), 1, 'seat kept after decline');

-- expiry_releases_seat
select pg_temp.mk_booking('x1', 'exp', 's1', 'awaiting_payment', 1000);
select pg_temp.mk_booking('x2', 'exp', 's2', 'paid', 1000);
select pg_temp.mk_booking('x3', 'e1', 's3', 'awaiting_payment', 1000);
select is(public.seats_taken((select id from ex where name = 'exp')), 2, 'seats before expiry');
select cmp_ok(public.expire_unpaid_bookings(now()), '>=', 1, 'expiry returns a count');
select is((select status::text from public.bookings where id = (select id from st where name = 'x1')), 'expired', 'unpaid booking past its deadline expired');
select is((select status::text from public.bookings where id = (select id from st where name = 'x2')), 'paid', 'paid booking untouched');
select is((select status::text from public.bookings where id = (select id from st where name = 'x3')), 'awaiting_payment', 'booking before its deadline untouched');
select is(public.seats_taken((select id from ex where name = 'exp')), 1, 'expiry_releases_seat');
select is((select count(*)::int from public.audit_log where action = 'booking_expired' and target_id = (select id from st where name = 'x1')), 1, 'expiry audited');

-- cron job exists
select is((select schedule from cron.job where jobname = 'expire-unpaid-bookings'), '*/5 * * * *', 'cron job scheduled every 5 minutes');

-- Exam cancel: free paid -> cancelled; paid -> refund follow-up; decisions on follow-ups.
select pg_temp.mk_booking('c1', 'xc', 's1', 'paid', 1000);
select pg_temp.mk_booking('c2', 'xc', 's2', 'awaiting_payment', 1000);
select pg_temp.mk_booking('c3', 'xc', 's3', 'cancel_requested', 1000);
select pg_temp.mk_booking('c4', 'xc', 'sd', 'part_refunded', 1000, 400);
select pg_temp.mk_booking('f1', 'xf', 's1', 'paid', 0);
select pg_temp.mk_booking('f2', 'xf', 's2', 'cancel_requested', 0);
select tests.as_postgres(); select tests.as_user((select id from c where name = 'admin'));
select is(public.set_exam_status((select id from ex where name = 'xc'), 'cancelled') ->> 'ok', 'true', 'paid exam cancelled');
select is(public.set_exam_status((select id from ex where name = 'xf'), 'cancelled') ->> 'ok', 'true', 'free exam cancelled');
select tests.as_postgres();
select is((select string_agg(status::text || '/' || refund_due::text, ',' order by name) from public.bookings b join st on st.id = b.id where st.name in ('f1', 'f2')), 'cancelled/false,cancelled/false', 'free paid bookings simply cancelled, nothing to refund');
select is((select status::text || '/' || refund_due::text from public.bookings where id = (select id from st where name = 'c1')), 'cancel_requested/true', 'paid booking becomes a refund follow-up');
select is((select status::text from public.bookings where id = (select id from st where name = 'c2')), 'cancelled', 'unpaid booking cancelled');
select tests.as_postgres(); select tests.as_user((select id from c where name = 'admin'));
select is(public.decide_cancellation((select id from st where name = 'c3'), false, null, null) ->> 'code', 'conflict', 'cancelled exam booking cannot be declined');
select is(public.decide_cancellation((select id from st where name = 'c1'), true, 1000, null) ->> 'ok', 'true', 'full refund recorded on cancelled-exam booking');
select is(public.decide_cancellation((select id from st where name = 'c4'), true, 601, null) ->> 'code', 'invalid_input', 'part_refunded top-up cannot exceed amount');
select is(public.decide_cancellation((select id from st where name = 'c4'), true, 600, null) ->> 'ok', 'true', 'part_refunded refund_due booking can be topped up');
select tests.as_postgres();
select is((select status::text || '/' || refunded_pence || '/' || refund_due::text from public.bookings where id = (select id from st where name = 'c1')), 'refunded/1000/false', 'refund clears refund_due');
select is((select status::text || '/' || refunded_pence || '/' || refund_due::text from public.bookings where id = (select id from st where name = 'c4')), 'refunded/1000/false', 'top-up adds to refunded_pence');

-- Account deletion releases seats and leaves refund follow-ups.
select pg_temp.mk_booking('g1', 'del1', 'sd', 'awaiting_payment', 1000);
select pg_temp.mk_booking('g2', 'del2', 'sd', 'paid', 1000);
select pg_temp.mk_booking('g3', 'del3', 'sd', 'paid', 0);
select is((public.seats_taken((select id from ex where name = 'del1')) + public.seats_taken((select id from ex where name = 'del2')) + public.seats_taken((select id from ex where name = 'del3'))), 3, 'three seats held before deletion');
delete from auth.users where id = (select id from c where name = 'sd');
select is((public.seats_taken((select id from ex where name = 'del1')) + public.seats_taken((select id from ex where name = 'del2')) + public.seats_taken((select id from ex where name = 'del3'))), 0, 'deleting a student frees their seats');
select is((select string_agg(b.status::text || '/' || b.refund_due::text || '/' || (b.student_id is null)::text, ',' order by st.name) from public.bookings b join st on st.id = b.id where st.name in ('g1', 'g2', 'g3')), 'cancelled/false/true,cancelled/true/true,cancelled/false/true', 'deleted student: rows kept anonymised, only the paid one is refund_due');
select is((select notes from public.bookings where id = (select id from st where name = 'g2')), 'account deleted — refund due', 'refund note recorded');
select is((select count(*)::int from public.audit_log where action = 'booking_cancelled_by_account_deletion' and target_id in (select id from st where name in ('g1', 'g2', 'g3'))), 3, 'account deletion releases audited');
select tests.as_postgres(); select tests.as_user((select id from c where name = 'admin'));
select is(public.decide_cancellation((select id from st where name = 'g2'), true, 1000, null) ->> 'ok', 'true', 'refund recorded for a deleted account booking');
select tests.as_postgres();

select * from finish();
rollback;
