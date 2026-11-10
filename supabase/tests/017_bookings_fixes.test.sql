begin;
create extension if not exists pgtap with schema extensions;
select plan(29);
select tests.assert_no_owner();

create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('admin', tests.create_user('admin', 'active'));
insert into c values ('teacher', tests.create_user('teacher', 'active'));
insert into c values ('parent', tests.create_user('parent', 'active'));
insert into c values ('sparent', tests.create_user('parent', 'suspended'));
insert into c values ('s1', tests.create_user('student', 'active'));
insert into c values ('s2', tests.create_user('student', 'active'));
insert into c values ('ss', tests.create_user('student', 'suspended'));
insert into c values ('sd', tests.create_user('student', 'active'));
insert into public.parent_children values
  ((select id from c where name = 'parent'), (select id from c where name = 's2')),
  ((select id from c where name = 'sparent'), (select id from c where name = 's2'));

insert into public.subjects (name, kind) values ('ZZ BookingsFix', 'school');
create temp table st (name text primary key, id uuid);
grant all on st to public;
create temp table ex (name text primary key, id uuid not null);
grant select on ex to public;

create function pg_temp.mk_exam(p_name text, p_price int, p_deadline timestamptz, p_starts timestamptz,
  p_status public.exam_status default 'published') returns void
language plpgsql as $$
begin
  with x as (
    insert into public.exams (subject_id, title, paper, format, starts_at, duration_minutes, seat_limit, price_pence,
      price_confirmed, booking_deadline, status)
    values ((select id from public.subjects where name = 'ZZ BookingsFix'), 'ZZ ' || p_name, 'P1', 'online', p_starts, 60,
      10, p_price, true, p_deadline, p_status)
    returning id)
  insert into ex select p_name, x.id from x;
end; $$;
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

select pg_temp.mk_exam('m1', 1000, now() + interval '10 days', now() + interval '20 days');
select pg_temp.mk_exam('m2', 1000, now() + interval '10 days', now() + interval '20 days');
select pg_temp.mk_exam('m3', 1000, now() + interval '10 days', now() + interval '20 days');
select pg_temp.mk_exam('m4', 1000, now() + interval '10 days', now() + interval '20 days');
select pg_temp.mk_exam('late', 1000, now() - interval '1 day', now() + interval '5 days');
select pg_temp.mk_exam('done', 1000, now() - interval '3 days', now() - interval '2 days', 'completed');
select pg_temp.mk_exam('started', 1000, now() - interval '3 days', now() - interval '2 days');
select pg_temp.mk_exam('cx', 1000, now() + interval '10 days', now() + interval '20 days', 'cancelled');

-- 1. Account deletion leaves started / completed exams alone.
select pg_temp.mk_booking('g1', 'done', 'sd', 'paid', 1000);
select pg_temp.mk_booking('g2', 'started', 'sd', 'paid', 1000);
select pg_temp.mk_booking('g3', 'm1', 'sd', 'paid', 1000);
delete from auth.users where id = (select id from c where name = 'sd');
select is((select status::text || '/' || refund_due::text from public.bookings where id = (select id from st where name = 'g1')), 'paid/false', 'paid booking on a completed exam stays paid after account deletion');
select is((select status::text || '/' || refund_due::text from public.bookings where id = (select id from st where name = 'g2')), 'paid/false', 'paid booking on a started exam stays paid after account deletion');
select is((select status::text || '/' || refund_due::text from public.bookings where id = (select id from st where name = 'g3')), 'cancelled/true', 'upcoming exam booking is still released with refund due');

-- 2. admin_add_booking deadline.
select tests.as_postgres(); select tests.as_user((select id from c where name = 'admin'));
select is(public.admin_add_booking((select id from ex where name = 'late'), (select id from c where name = 's1'), false, null) ->> 'code', 'deadline_passed', 'unpaid admin booking after the deadline refused');
select is(public.admin_add_booking((select id from ex where name = 'late'), (select id from c where name = 's1'), true, null) ->> 'ok', 'true', 'paid admin booking after the deadline allowed');
select tests.as_postgres();

-- 3b. Three unpaid bookings per booker.
select tests.as_postgres(); select tests.as_user((select id from c where name = 's1'));
insert into st select 'u1', (public.create_booking((select id from ex where name = 'm1'), (select id from c where name = 's1')) ->> 'id')::uuid;
insert into st select 'u2', (public.create_booking((select id from ex where name = 'm2'), (select id from c where name = 's1')) ->> 'id')::uuid;
insert into st select 'u3', (public.create_booking((select id from ex where name = 'm3'), (select id from c where name = 's1')) ->> 'id')::uuid;
select isnt((select id from st where name = 'u3'), null, 'third unpaid booking allowed');
select is(public.create_booking((select id from ex where name = 'm4'), (select id from c where name = 's1')) ->> 'code', 'too_many_unpaid', 'fourth unpaid booking refused');
-- 3a. Cancelling an unpaid booking is immediate and frees the slot and the seat.
select is(public.request_cancellation((select id from st where name = 'u1')) ->> 'ok', 'true', 'own unpaid booking cancelled at once');
select tests.as_postgres();
select is((select status::text from public.bookings where id = (select id from st where name = 'u1')), 'cancelled', 'unpaid booking is cancelled, not cancel_requested');
select is(public.seats_taken((select id from ex where name = 'm1')), 0, 'seat released immediately');
select is((select count(*)::int from public.audit_log where action = 'booking_cancelled_by_owner' and target_id = (select id from st where name = 'u1')), 1, 'immediate cancel audited');
select tests.as_user((select id from c where name = 's1'));
insert into st select 'u4', (public.create_booking((select id from ex where name = 'm4'), (select id from c where name = 's1')) ->> 'id')::uuid;
select isnt((select id from st where name = 'u4'), null, 'booking allowed again after a cancel');
select is(public.create_booking((select id from ex where name = 'm1'), (select id from c where name = 's1')) ->> 'code', 'too_many_unpaid', 'limit applies again');
select tests.as_postgres(); select tests.as_user((select id from c where name = 'admin'));
select is(public.mark_booking_paid((select id from st where name = 'u2'), null) ->> 'ok', 'true', 'one booking paid');
select is(public.admin_add_booking((select id from ex where name = 'm1'), (select id from c where name = 's1'), false, null) ->> 'ok', 'true', 'admin booking is not limited');
select tests.as_postgres(); select tests.as_user((select id from c where name = 's2'));
select is(public.create_booking((select id from ex where name = 'm1'), (select id from c where name = 's2')) ->> 'ok', 'true', 'limit is per booker');
select tests.as_postgres(); select tests.as_user((select id from c where name = 's1'));
-- paid booking still goes through cancel_requested
select is(public.request_cancellation((select id from st where name = 'u2')) ->> 'ok', 'true', 'paid booking cancellation requested');
select tests.as_postgres();
select is((select status::text from public.bookings where id = (select id from st where name = 'u2')), 'cancel_requested', 'paid booking goes to cancel_requested');

-- 4 + 5. decide_cancellation edge cases.
select pg_temp.mk_booking('d1', 'cx', 's1', 'cancel_requested', 1000);
select pg_temp.mk_booking('d2', 'm3', 's2', 'cancel_requested', 1000);
select tests.as_user((select id from c where name = 'admin'));
select is(public.decide_cancellation((select id from st where name = 'd1'), false, null, null) ->> 'code', 'conflict', 'decline refused on a cancelled exam');
select is(public.decide_cancellation((select id from st where name = 'd2'), true, 2147483647, null) ->> 'code', 'invalid_input', 'huge refund refused without overflow');
select is(public.decide_cancellation((select id from st where name = 'd2'), true, 1000, null) ->> 'ok', 'true', 'exact refund accepted');
select tests.as_postgres();

-- 6. Suspended accounts and wrong roles.
select tests.as_user((select id from c where name = 'sparent'));
select is(public.create_booking((select id from ex where name = 'm2'), (select id from c where name = 's2')) ->> 'code', 'forbidden', 'suspended parent refused');
select tests.as_postgres(); select tests.as_user((select id from c where name = 'ss'));
select is(public.create_booking((select id from ex where name = 'm2'), (select id from c where name = 'ss')) ->> 'code', 'forbidden', 'suspended student refused');
select tests.as_postgres(); select tests.as_user((select id from c where name = 'teacher'));
select is(public.admin_add_booking((select id from ex where name = 'm2'), (select id from c where name = 's2'), true, null) ->> 'code', 'forbidden', 'teacher: admin_add_booking forbidden');
select is(public.mark_booking_paid((select id from st where name = 'u4'), null) ->> 'code', 'forbidden', 'teacher: mark_booking_paid forbidden');
select is(public.decide_cancellation((select id from st where name = 'u2'), true, 0, null) ->> 'code', 'forbidden', 'teacher: decide_cancellation forbidden');
select tests.as_postgres(); select tests.as_user((select id from c where name = 'parent'));
select is(public.admin_add_booking((select id from ex where name = 'm2'), (select id from c where name = 's2'), true, null) ->> 'code', 'forbidden', 'parent: admin_add_booking forbidden');
select is(public.mark_booking_paid((select id from st where name = 'u4'), null) ->> 'code', 'forbidden', 'parent: mark_booking_paid forbidden');
select is(public.decide_cancellation((select id from st where name = 'u2'), true, 0, null) ->> 'code', 'forbidden', 'parent: decide_cancellation forbidden');
select tests.as_postgres();

select * from finish();
rollback;
