begin;
create extension if not exists pgtap with schema extensions;
select plan(7);
select tests.assert_no_owner();

create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('admin', tests.create_user('admin', 'active'));
insert into c values ('s1', tests.create_user('student', 'active'));
insert into c values ('s2', tests.create_user('student', 'active'));
insert into c values ('p1', tests.create_user('parent', 'active'));
insert into c values ('p2', tests.create_user('parent', 'active'));
insert into public.parent_children (parent_id, student_id)
  values ((select id from c where name = 'p1'), (select id from c where name = 's1'));
insert into public.subjects (name, kind) values ('ZZ Fam A', 'school');

create temp table ex (name text primary key, id uuid not null);
grant select on ex to public;
with x as (
  insert into public.exams (subject_id, title, paper, format, starts_at, duration_minutes, seat_limit, price_pence,
    price_confirmed, booking_deadline, status, created_by)
  select (select id from public.subjects where name = 'ZZ Fam A'), 'ZZ ' || n, 'P1', 'online',
    now() + interval '30 days', 60, 10, 1000, true, now() + interval '20 days', st::public.exam_status,
    (select id from c where name = 'admin')
  from (values ('cancelled', 'cancelled'), ('draft', 'draft')) v(n, st)
  returning id, title)
insert into ex select substr(title, 4), id from x;
insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence)
  values ((select id from ex where name = 'cancelled'), (select id from c where name = 's1'),
          (select id from c where name = 's1'), 'cancelled', 1000);

select tests.as_user((select id from c where name = 's1'));
select is((select count(*)::int from public.exams where id = (select id from ex where name = 'cancelled')), 1, 'student sees own cancelled exam');
select is((select count(*)::int from public.exams where id = (select id from ex where name = 'draft')), 0, 'draft without a booking stays hidden');
select tests.as_postgres();
select tests.as_user((select id from c where name = 'p1'));
select is((select count(*)::int from public.exams where id = (select id from ex where name = 'cancelled')), 1, 'linked parent sees the cancelled exam');
select tests.as_postgres();
select tests.as_user((select id from c where name = 'p2'));
select is((select count(*)::int from public.exams where id = (select id from ex where name = 'cancelled')), 0, 'unrelated parent does not');
select tests.as_postgres();
select tests.as_user((select id from c where name = 's2'));
select is((select count(*)::int from public.exams where id = (select id from ex where name = 'cancelled')), 0, 'unrelated student does not');
select is((select count(*)::int from public.exams where id = (select id from ex where name = 'draft')), 0, 'unrelated student: draft hidden');
select tests.as_postgres();
select ok(not has_function_privilege('anon', 'public.family_has_booking(uuid)', 'execute'), 'anon cannot call the helper');

select * from finish();
rollback;
