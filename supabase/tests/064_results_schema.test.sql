begin;
create extension if not exists pgtap with schema extensions;
select plan(33);
select tests.assert_no_owner();

-- Phase 4A, Task 2: the results tables. Fixture: tests.results_exam(2, 1) (two home candidates and a centre one, totals
-- 24, 22, 20); a row in each of the four tables; an admin, a student (the first candidate), a parent linked to them, an
-- unlinked parent, a suspended linked parent, a corrector and a teacher.
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
-- Signs the claims in as the user without changing role (the internal functions are not granted to any client role).
create function pg_temp.claims(p uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true) $$;

select set_config('t.exam', tests.results_exam(2, 1)::text, true);
insert into c values ('admin', tests.create_user('admin', 'active')), ('teacher', tests.create_user('teacher', 'active')),
  ('corrector', tests.create_user('corrector', 'active')), ('parent', tests.create_user('parent', 'active')),
  ('other_parent', tests.create_user('parent', 'active')), ('suspended_parent', tests.create_user('parent', 'active')),
  ('other_student', tests.create_user('student', 'active'));
insert into c select 'student', b.student_id from public.scripts s join public.bookings b on b.id = s.booking_id
  where s.exam_id = current_setting('t.exam')::uuid order by s.number limit 1;
insert into public.parent_children (parent_id, student_id)
select pg_temp.uid(p), pg_temp.uid('student') from unnest(array['parent', 'suspended_parent']) p;
update public.profiles set status = 'suspended' where id = pg_temp.uid('suspended_parent');

insert into public.exam_results (exam_id, state, version) values (current_setting('t.exam')::uuid, 'prepared', 1);
insert into public.grade_boundaries (exam_id, position, grade, min_mark) values (current_setting('t.exam')::uuid, 1, 'A', 18);
insert into public.results (id, exam_id, booking_id, student_id, script_id, sitting, status, total, max_total)
select gen_random_uuid(), s.exam_id, s.booking_id, b.student_id, s.id, b.sitting, 'present', public.script_final_total(s.id),
  public.exam_max_total(s.exam_id)
from public.scripts s join public.bookings b on b.id = s.booking_id where s.exam_id = current_setting('t.exam')::uuid;
insert into public.result_versions (result_id, version, published_at, snapshot)
select r.id, 1, now(), '{}'::jsonb from public.results r where r.exam_id = current_setting('t.exam')::uuid limit 1;

create function pg_temp.visible() returns bigint language sql stable as $$
  select (select count(*) from public.exam_results) + (select count(*) from public.grade_boundaries)
       + (select count(*) from public.results) + (select count(*) from public.result_versions) $$;
grant execute on function pg_temp.visible() to public;

-- ---------------------------------------------------------------------------------------------
-- The fixture
-- ---------------------------------------------------------------------------------------------
select is((select array_agg(public.script_final_total(s.id) order by s.number) from public.scripts s
           where s.exam_id = current_setting('t.exam')::uuid), array[24.0, 22.0, 20.0]::numeric[],
  'results_exam: three checked scripts with the default totals');
select is((select array_agg(b.sitting::text order by s.number) from public.scripts s join public.bookings b on b.id = s.booking_id
           where s.exam_id = current_setting('t.exam')::uuid), array['home', 'home', 'centre'],
  'results_exam: two home candidates, then one at a centre');
select ok((select approved_at is not null from public.exam_marking where exam_id = current_setting('t.exam')::uuid),
  'results_exam: the exam''s marking is approved');
select set_config('t.exam2', tests.results_exam(2, 0, array[7.5, 0]::numeric[])::text, true);
select is((select array_agg(public.script_final_total(s.id) order by s.number)
           from public.scripts s where s.exam_id = current_setting('t.exam2')::uuid),
  array[7.5, 0.0]::numeric[], 'results_exam: totals can be given');

-- ---------------------------------------------------------------------------------------------
-- tables_have_rls_and_admin_only_select
-- ---------------------------------------------------------------------------------------------
select is((select count(*) from pg_class where oid in ('public.exam_results'::regclass, 'public.grade_boundaries'::regclass,
  'public.results'::regclass, 'public.result_versions'::regclass) and relrowsecurity), 4::bigint, 'all four tables have row-level security');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.visible(), 6::bigint, 'an admin reads every row: 1 exam_results, 1 boundary, 3 results, 1 version');
select tests.as_postgres();
select tests.as_user(pg_temp.uid('student'));
select is(pg_temp.visible(), 0::bigint, 'a student reads no row of the four tables');
select tests.as_postgres();
select tests.as_user(pg_temp.uid('parent'));
select is(pg_temp.visible(), 0::bigint, 'a parent reads no row of the four tables');
select tests.as_postgres();
select tests.as_user(pg_temp.uid('corrector'));
select is(pg_temp.visible(), 0::bigint, 'a corrector reads no row of the four tables');
select tests.as_postgres();
select tests.as_user(pg_temp.uid('teacher'));
select is(pg_temp.visible(), 0::bigint, 'a teacher reads no row of the four tables');
select tests.as_postgres();
select tests.as_user(pg_temp.uid('admin'));
select throws_ok($$insert into public.results (exam_id, booking_id, student_id, sitting, status, max_total)
  select exam_id, booking_id, student_id, sitting, status, max_total from public.results limit 1$$, '42501', null,
  'not even an admin writes a results row directly');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- result_versions_cannot_be_changed
-- ---------------------------------------------------------------------------------------------
set local role service_role;
select throws_ok($$update public.result_versions set reason = 'x'$$, '42501', null, 'service_role cannot update a version');
select throws_ok($$delete from public.result_versions$$, '42501', null, 'service_role cannot delete a version');
select throws_ok($$insert into public.result_versions (result_id, version, published_at, snapshot)
  select result_id, 2, now(), '{}' from public.result_versions$$, '42501', null, 'service_role cannot insert a version');
select throws_ok($$truncate public.result_versions$$, '42501', null, 'service_role cannot truncate the versions');
reset role;
select throws_ok($$update public.result_versions set reason = 'x'$$, 'P0001', 'Published result versions never change.',
  'the owner of the table cannot update a version');
select throws_ok($$delete from public.result_versions$$, 'P0001', 'Published result versions never change.',
  'the owner of the table cannot delete a version');
select throws_ok($$truncate public.result_versions$$, 'P0001', 'Published result versions never change.',
  'the owner of the table cannot truncate the versions');
select is((select count(*) from public.result_versions), 1::bigint, 'the version is still there');

-- ---------------------------------------------------------------------------------------------
-- exam_max_total_counts_best_of_option_groups
-- ---------------------------------------------------------------------------------------------
select is(public.exam_max_total(current_setting('t.exam')::uuid), 24.0::numeric,
  'exam_max_total: question 1 (10) and the best two of 8, 6 and 5 (question 2 has parts 3 and 5) make 24');
select is(public.exam_max_total(current_setting('t.exam2')::uuid), 24.0::numeric, 'exam_max_total: another fixture paper, the same');
select is(public.exam_max_total(tests.marking_exam()), 0.0::numeric, 'exam_max_total: a paper with no questions is 0');

-- ---------------------------------------------------------------------------------------------
-- is_family_of_true_for_self_and_linked_parent_only
-- ---------------------------------------------------------------------------------------------
select pg_temp.claims(pg_temp.uid('student'));
select is(public.is_family_of(pg_temp.uid('student')), true, 'is_family_of: the student themself');
select is(public.is_family_of(pg_temp.uid('other_student')), false, 'is_family_of: another student is not family');
select pg_temp.claims(pg_temp.uid('parent'));
select is(public.is_family_of(pg_temp.uid('student')), true, 'is_family_of: a linked parent');
select is(public.is_family_of(pg_temp.uid('other_student')), false, 'is_family_of: a parent of someone else''s child');
select pg_temp.claims(pg_temp.uid('other_parent'));
select is(public.is_family_of(pg_temp.uid('student')), false, 'is_family_of: an unlinked parent');
select pg_temp.claims(pg_temp.uid('suspended_parent'));
select is(public.is_family_of(pg_temp.uid('student')), false, 'is_family_of: a suspended linked parent');
select pg_temp.claims(pg_temp.uid('student'));
select is(public.is_family_of(null), false, 'is_family_of: nobody is nobody''s family');

-- ---------------------------------------------------------------------------------------------
-- boundary_labels_and_marks_are_checked
-- ---------------------------------------------------------------------------------------------
select throws_ok($$insert into public.grade_boundaries (exam_id, position, grade, min_mark)
  values (current_setting('t.exam')::uuid, 16, 'Z', 1)$$, '23514', null, 'a 16th grade is refused');
select throws_ok($$insert into public.grade_boundaries (exam_id, position, grade, min_mark)
  values (current_setting('t.exam')::uuid, 2, 'ABCDEFGHIJK', 1)$$, '23514', null, 'an 11-character label is refused');
select throws_ok($$insert into public.grade_boundaries (exam_id, position, grade, min_mark)
  values (current_setting('t.exam')::uuid, 2, 'B', -1)$$, '23514', null, 'a negative mark is refused');
select throws_ok($$insert into public.grade_boundaries (exam_id, position, grade, min_mark)
  values (current_setting('t.exam')::uuid, 2, 'A', 10)$$, '23505', null, 'the same grade twice is refused');

select * from finish();
rollback;
