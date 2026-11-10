begin;
create extension if not exists pgtap with schema extensions;
select plan(31);
select tests.assert_no_owner();

create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('admin', tests.create_user('admin', 'active'));
insert into c values ('sadmin', tests.create_user('admin', 'suspended'));
insert into c values ('teacher', tests.create_user('teacher', 'active'));
insert into c values ('tutor', tests.create_user('tutor', 'active'));
insert into c values ('parent', tests.create_user('parent', 'active'));
insert into c values ('s1', tests.create_user('student', 'active'));
insert into c values ('s2', tests.create_user('student', 'active'));
insert into c values ('s3', tests.create_user('student', 'active'));
insert into c values ('s4', tests.create_user('student', 'active'));

insert into public.subjects (name, kind) values ('ZZ Finance', 'school');
create temp table ex (name text primary key, id uuid not null);
grant select on ex to public;
create temp table bk (name text primary key, id uuid not null);
grant all on bk to public;

create function pg_temp.mk_exam(p_name text, p_price int, p_starts timestamptz, p_deadline timestamptz) returns void
language plpgsql as $$
begin
  with x as (
    insert into public.exams (subject_id, title, paper, format, starts_at, duration_minutes, seat_limit, price_pence,
      price_confirmed, booking_deadline, status)
    values ((select id from public.subjects where name = 'ZZ Finance'), 'ZZ Fin ' || p_name, 'P1', 'online', p_starts, 60,
      20, p_price, true, p_deadline, 'published')
    returning id)
  insert into ex select p_name, x.id from x;
end; $$;
create function pg_temp.mk_booking(p_key text, p_exam text, p_student text, p_status public.booking_status,
  p_amount int, p_refunded int, p_paid_at timestamptz, p_due boolean default false) returns void
language plpgsql as $$
begin
  with x as (
    insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, refunded_pence, paid_at, refund_due)
    values ((select id from ex where name = p_exam), (select id from c where name = p_student),
      (select id from c where name = p_student), p_status, p_amount, p_refunded, p_paid_at, p_due)
    returning id)
  insert into bk select p_key, x.id from x;
end; $$;

-- All seeded money sits in 2031 so real dev data cannot change the totals.
select pg_temp.mk_exam('A', 2000, '2031-12-06 09:00+00', '2031-12-01 09:00+00');
select pg_temp.mk_exam('B', 1500, '2031-12-07 09:00+00', '2031-12-01 09:00+00');
select pg_temp.mk_exam('C', 0, '2031-12-08 09:00+00', '2031-12-01 09:00+00');
-- Exam A: a paid booking; a part refund paid at 23:30 UTC on 31 Oct (31 Oct in London, GMT); a full refund paid at 00:30 on 1 Nov.
select pg_temp.mk_booking('a1', 'A', 's1', 'paid', 2000, 0, '2031-10-10 12:00+00');
select pg_temp.mk_booking('a2', 'A', 's2', 'part_refunded', 2000, 500, '2031-10-31 23:30+00');
select pg_temp.mk_booking('a3', 'A', 's3', 'refunded', 2000, 2000, '2031-11-01 00:30+00');
-- Exam B: unpaid (excluded); a refund-due cancelled booking paid at 23:30 UTC on 30 Sep (00:30 BST on 1 Oct); paid at 22:30 UTC on 30 Sep (23:30 BST, September).
select pg_temp.mk_booking('b1', 'B', 's1', 'awaiting_payment', 1500, 0, null);
select pg_temp.mk_booking('b2', 'B', 's2', 'cancelled', 1500, 0, '2031-09-30 23:30+00', true);
select pg_temp.mk_booking('b3', 'B', 's3', 'paid', 1500, 0, '2031-09-30 22:30+00');
-- Exam C is free.
select pg_temp.mk_booking('c1', 'C', 's1', 'paid', 0, 0, '2031-11-15 10:00+00');

-- 1. Totals for October and November 2031 (London dates).
select tests.as_user((select id from c where name = 'admin'));
select tests.as_postgres();
create temp table r1 as select public.money_totals('2031-10-01', '2031-11-30') as j;
grant select on r1 to public;
select tests.as_user((select id from c where name = 'admin'));
select is((select j ->> 'ok' from r1), 'true', 'admin gets totals');
select is((select j -> 'total' from r1), '{"taken": 7500, "refunded": 2500, "net": 5000}'::jsonb, 'overall total across Oct and Nov');
select is((select j -> 'months' from r1),
  '[{"month": "2031-10", "taken": 5500, "refunded": 500, "net": 5000, "bookings": 3},
    {"month": "2031-11", "taken": 2000, "refunded": 2000, "net": 0, "bookings": 2}]'::jsonb,
  'months: 00:30 BST on 1 Oct and 23:30 UTC on 31 Oct are October, 00:30 on 1 Nov is November');
select is((select jsonb_agg(e - 'examId' - 'startsAt' order by e ->> 'title') from r1, jsonb_array_elements(j -> 'exams') e),
  '[{"subject": "ZZ Finance", "title": "ZZ Fin A", "taken": 6000, "refunded": 2500, "net": 3500, "bookings": 3},
    {"subject": "ZZ Finance", "title": "ZZ Fin B", "taken": 1500, "refunded": 0, "net": 1500, "bookings": 1},
    {"subject": "ZZ Finance", "title": "ZZ Fin C", "taken": 0, "refunded": 0, "net": 0, "bookings": 1}]'::jsonb,
  'exams: part and full refunds, refund-due cancelled counted as taken, unpaid excluded, free exam is zero');
select is((select (e ->> 'examId')::uuid from r1, jsonb_array_elements(j -> 'exams') e where e ->> 'title' = 'ZZ Fin A'),
  (select id from ex where name = 'A'), 'exam id is returned');
select is((select (e ->> 'startsAt')::timestamptz from r1, jsonb_array_elements(j -> 'exams') e where e ->> 'title' = 'ZZ Fin A'),
  '2031-12-06 09:00+00'::timestamptz, 'exam start is returned');
select is((select e ->> 'title' from r1, jsonb_array_elements(j -> 'exams') with ordinality t(e, n) order by n limit 1), 'ZZ Fin A', 'exams ordered by start time');

-- 2. Edges of the range are inclusive and use London dates.
select is(public.money_totals('2031-10-01', '2031-10-31') -> 'total', '{"taken": 5500, "refunded": 500, "net": 5000}'::jsonb, 'October only: includes 31 Oct 23:30 UTC and 1 Oct 00:30 BST, not 1 Nov 00:30');
select is(public.money_totals('2031-11-01', '2031-11-01') -> 'total', '{"taken": 2000, "refunded": 2000, "net": 0}'::jsonb, 'a single London day (1 Nov) is inclusive on both ends');
select is(public.money_totals('2031-09-01', '2031-09-30') -> 'total', '{"taken": 1500, "refunded": 0, "net": 1500}'::jsonb, 'September only: 22:30 UTC on 30 Sep is 23:30 BST, 23:30 UTC is already 1 Oct');
select is(public.money_totals('2031-01-01', '2031-01-31'), '{"ok": true, "months": [], "exams": [], "total": {"taken": 0, "refunded": 0, "net": 0}}'::jsonb, 'an empty range is zero');
select is(public.money_totals('2031-11-30', '2031-10-01') ->> 'code', 'invalid_input', 'from after to is invalid');
select is(public.money_totals(null, '2031-10-01') ->> 'code', 'invalid_input', 'null from is invalid');
select is(public.money_totals('2031-10-01', null) ->> 'code', 'invalid_input', 'null to is invalid');
select tests.as_postgres();

-- 3. Everyone else is refused.
select tests.as_user((select id from c where name = 'teacher'));
select is(public.money_totals('2031-10-01', '2031-11-30') ->> 'code', 'forbidden', 'teacher forbidden');
select tests.as_postgres(); select tests.as_user((select id from c where name = 'tutor'));
select is(public.money_totals('2031-10-01', '2031-11-30') ->> 'code', 'forbidden', 'tutor forbidden');
select tests.as_postgres(); select tests.as_user((select id from c where name = 'parent'));
select is(public.money_totals('2031-10-01', '2031-11-30') ->> 'code', 'forbidden', 'parent forbidden');
select tests.as_postgres(); select tests.as_user((select id from c where name = 's1'));
select is(public.money_totals('2031-10-01', '2031-11-30') ->> 'code', 'forbidden', 'student forbidden');
select tests.as_postgres(); select tests.as_user((select id from c where name = 'sadmin'));
select is(public.money_totals('2031-10-01', '2031-11-30') ->> 'code', 'forbidden', 'suspended admin forbidden');
select tests.as_postgres();
select ok(not has_function_privilege('anon', 'public.money_totals(date,date)', 'execute'), 'anon cannot execute money_totals');
select ok(has_function_privilege('authenticated', 'public.money_totals(date,date)', 'execute'), 'authenticated can execute money_totals');

-- 4. paid_at trigger: set on insert as paid, on admin_add_booking(paid) and on mark_booking_paid; never cleared.
insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence)
  values ((select id from ex where name = 'A'), (select id from c where name = 's4'),
          (select id from c where name = 's4'), 'paid', 2000);
select is((select paid_at from public.bookings where exam_id = (select id from ex where name = 'A') and student_id = (select id from c where name = 's4')), now(), 'a booking inserted as paid gets paid_at');
select pg_temp.mk_exam('F', 1000, now() + interval '20 days', now() + interval '10 days');
select pg_temp.mk_exam('G', 1000, now() + interval '20 days', now() + interval '10 days');
select tests.as_user((select id from c where name = 'admin'));
insert into bk select 'f1', (public.admin_add_booking((select id from ex where name = 'F'), (select id from c where name = 's1'), true, null) ->> 'id')::uuid;
insert into bk select 'g1', (public.admin_add_booking((select id from ex where name = 'G'), (select id from c where name = 's1'), false, null) ->> 'id')::uuid;
select tests.as_postgres();
select is((select paid_at from public.bookings where id = (select id from bk where name = 'f1')), now(), 'admin_add_booking(paid) sets paid_at');
select is((select paid_at from public.bookings where id = (select id from bk where name = 'g1')), null, 'admin_add_booking(unpaid) leaves paid_at empty');
select tests.as_user((select id from c where name = 'admin'));
select is(public.mark_booking_paid((select id from bk where name = 'g1'), null) ->> 'ok', 'true', 'mark_booking_paid works');
select tests.as_postgres();
select is((select paid_at from public.bookings where id = (select id from bk where name = 'g1')), now(), 'mark_booking_paid sets paid_at');

-- A later cancellation request and full refund do not clear or move paid_at.
alter table public.bookings disable trigger bookings_set_paid_at;
update public.bookings set paid_at = '2031-10-20 10:00+00' where id = (select id from bk where name = 'f1');
alter table public.bookings enable trigger bookings_set_paid_at;
update public.bookings set status = 'cancel_requested' where id = (select id from bk where name = 'f1');
select tests.as_user((select id from c where name = 'admin'));
select is(public.decide_cancellation((select id from bk where name = 'f1'), true, 1000, 'refund') ->> 'ok', 'true', 'full refund recorded');
select tests.as_postgres();
select is((select status::text || '/' || paid_at::text from public.bookings where id = (select id from bk where name = 'f1')), 'refunded/2031-10-20 10:00:00+00', 'refund keeps paid_at');
update public.bookings set paid_at = null where id = (select id from bk where name = 'f1');
select is((select paid_at from public.bookings where id = (select id from bk where name = 'f1')), '2031-10-20 10:00:00+00'::timestamptz, 'paid_at cannot be cleared');
update public.bookings set status = 'cancelled' where id = (select id from bk where name = 'g1');
select is((select paid_at from public.bookings where id = (select id from bk where name = 'g1')), now(), 'cancelling keeps paid_at');
update public.bookings set paid_at = '2031-12-25 10:00+00' where id = (select id from bk where name = 'f1');
select is((select paid_at from public.bookings where id = (select id from bk where name = 'f1')), '2031-10-20 10:00:00+00'::timestamptz, 'a later update cannot move paid_at');

select * from finish();
rollback;
