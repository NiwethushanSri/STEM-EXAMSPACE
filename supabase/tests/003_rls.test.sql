begin;
create extension if not exists pgtap with schema extensions;
select plan(87);

-- Fixtures (as postgres).
create temp table u (name text primary key, id uuid not null);
create temp table tot (profiles int, details int);
insert into u values
  ('owner',   tests.create_user('owner', 'active')),
  ('admin',   tests.create_user('admin', 'active')),
  ('sadmin',  tests.create_user('admin', 'suspended')),
  ('teacher', tests.create_user('teacher', 'active')),
  ('corr',    tests.create_user('corrector', 'active')),
  ('tutor',   tests.create_user('tutor', 'active')),
  ('tutor2',  tests.create_user('tutor', 'active')),
  ('parent',  tests.create_user('parent', 'active')),
  ('parent2', tests.create_user('parent', 'active')),
  ('stu1',    tests.create_user('student', 'active')),
  ('stu2',    tests.create_user('student', 'active')),
  ('stu3',    tests.create_user('student', 'pending'));
insert into public.parent_children values
  ((select id from u where name = 'parent'),  (select id from u where name = 'stu1')),
  ((select id from u where name = 'parent2'), (select id from u where name = 'stu2'));
insert into public.tutor_students values
  ((select id from u where name = 'tutor'),  (select id from u where name = 'stu1')),
  ((select id from u where name = 'tutor2'), (select id from u where name = 'stu2'));
insert into public.teacher_subjects values
  ((select id from u where name = 'teacher'), (select id from public.subjects where name = 'Maths'));
insert into public.student_subjects values
  ((select id from u where name = 'stu1'), (select id from public.subjects where name = 'Maths')),
  ((select id from u where name = 'stu2'), (select id from public.subjects where name = 'Physics'));
update public.student_details set parent_phone = '0700000000'
  where profile_id = (select id from u where name = 'stu1');
insert into public.audit_log (actor_id, action) values ((select id from u where name = 'admin'), 'rls_test');
insert into tot select (select count(*)::int from public.profiles), (select count(*)::int from public.student_details);
grant select on u, tot to public;

-- Helper function privileges.
select is(has_function_privilege('anon', 'public.my_role()', 'execute'), false, 'my_role not executable by anon');
select is(has_function_privilege('authenticated', 'public.my_role()', 'execute'), true, 'my_role executable by authenticated');
select is(has_function_privilege('anon', 'public.is_staff_admin()', 'execute'), false, 'is_staff_admin not executable by anon');
select is(has_function_privilege('authenticated', 'public.is_staff_admin()', 'execute'), true, 'is_staff_admin executable by authenticated');

-- Student (active).
select tests.as_user((select id from u where name = 'stu1'));
select is((select count(*)::int from public.profiles), 1, 'student sees only own profile (not parent, not others)');
select is((select count(*)::int from public.profiles where id = (select id from u where name = 'stu2')), 0, 'student cannot read another student profile');
select is((select count(*)::int from public.student_details), 1, 'student reads own details only');
select is((select count(*)::int from public.student_details where profile_id = (select id from u where name = 'stu2')), 0, 'student cannot read another student details');
select is((select count(*)::int from public.subjects), 9, 'student reads 9 subjects');
select throws_ok($$insert into public.subjects (name, kind) values ('Hack', 'school')$$, '42501', null, 'student cannot insert subjects');
select throws_ok($$update public.student_details set parent_phone = '1' where profile_id = (select id from u where name = 'stu1')$$, '42501', null, 'student cannot update parent_phone directly');
select throws_ok($$update public.profiles set role = 'owner' where id = (select id from u where name = 'stu1')$$, '42501', null, 'student cannot update own role');
select throws_ok($$delete from public.profiles where id = (select id from u where name = 'stu1')$$, '42501', null, 'student cannot delete profile');
select is((select count(*)::int from public.student_subjects), 1, 'student reads own student_subjects only');
select is((select count(*)::int from public.parent_children), 0, 'student sees no parent_children rows');
select is((select count(*)::int from public.tutor_students), 0, 'student sees no tutor_students rows');
select is((select count(*)::int from public.audit_log), 0, 'student reads 0 audit_log rows');
select is(public.my_role()::text, 'student', 'my_role is student');
select is(public.is_staff_admin(), false, 'student is not staff admin');
reset role;
select is((select role::text from public.profiles where id = (select id from u where name = 'stu1')), 'student', 'student role unchanged after attempted update');
select is((select parent_phone from public.student_details where profile_id = (select id from u where name = 'stu1')), '0700000000', 'parent_phone unchanged after attempted update');

-- Pending student.
select tests.as_user((select id from u where name = 'stu3'));
select is((select count(*)::int from public.profiles), 1, 'pending student sees own profile');
select is((select count(*)::int from public.student_details), 1, 'pending student sees own details');
reset role;

-- Parent.
select tests.as_user((select id from u where name = 'parent'));
select is((select count(*)::int from public.profiles), 2, 'parent sees own profile and linked child');
select is((select count(*)::int from public.profiles where id = (select id from u where name = 'stu1')), 1, 'parent reads linked child profile');
select is((select count(*)::int from public.profiles where id = (select id from u where name = 'stu2')), 0, 'parent cannot read unlinked student profile');
select is((select count(*)::int from public.student_details), 1, 'parent reads linked child details only');
select is((select count(*)::int from public.student_details where profile_id = (select id from u where name = 'stu2')), 0, 'parent cannot read unlinked student details');
select is((select count(*)::int from public.parent_children), 1, 'parent sees own parent_children rows only');
select throws_ok($$insert into public.parent_children values ((select id from u where name = 'parent'), (select id from u where name = 'stu2'))$$, '42501', null, 'parent cannot link themselves to a student');
select is((select count(*)::int from public.student_subjects), 0, 'parent sees no student_subjects in part 1');
reset role;

-- Tutor.
select tests.as_user((select id from u where name = 'tutor'));
select is((select count(*)::int from public.profiles), 2, 'tutor sees own profile and assigned student');
select is((select count(*)::int from public.profiles where id = (select id from u where name = 'stu1')), 1, 'tutor reads assigned student profile');
select is((select count(*)::int from public.profiles where id = (select id from u where name = 'stu2')), 0, 'tutor cannot read unassigned student profile');
select is((select count(*)::int from public.student_details), 1, 'tutor reads assigned student details only');
select is((select count(*)::int from public.tutor_students), 1, 'tutor sees own tutor_students rows only');
select throws_ok($$insert into public.tutor_students values ((select id from u where name = 'tutor'), (select id from u where name = 'stu2'))$$, '42501', null, 'tutor cannot assign themselves a student');
reset role;

-- Teacher.
select tests.as_user((select id from u where name = 'teacher'));
select is((select count(*)::int from public.profiles), 1, 'teacher sees only own profile');
select is((select count(*)::int from public.student_details), 0, 'teacher reads 0 student_details');
select is((select count(*)::int from public.tutor_students), 0, 'teacher sees 0 tutor_students rows');
select is((select count(*)::int from public.teacher_subjects), 1, 'teacher sees own teacher_subjects');
select is((select count(*)::int from public.subjects), 9, 'teacher reads 9 subjects');
reset role;

-- Corrector.
select tests.as_user((select id from u where name = 'corr'));
select is((select count(*)::int from public.profiles), 1, 'corrector sees only own profile');
select is((select count(*)::int from public.student_details), 0, 'corrector reads 0 student_details');
reset role;

-- Admin.
select tests.as_user((select id from u where name = 'admin'));
select is((select count(*)::int from public.profiles), (select profiles from tot), 'admin reads all profiles');
select is((select count(*)::int from public.student_details), (select details from tot), 'admin reads all student_details');
select is((select count(*)::int from public.student_subjects), 2, 'admin reads all student_subjects');
select is((select count(*)::int from public.audit_log where action = 'rls_test'), 1, 'admin reads audit_log');
select throws_ok($$update public.audit_log set action = 'x'$$, '42501', null, 'admin cannot update audit_log');
select throws_ok($$delete from public.audit_log$$, '42501', null, 'admin cannot delete audit_log');
select throws_ok($$insert into public.audit_log (action) values ('x')$$, '42501', null, 'admin cannot insert audit_log directly');
select lives_ok($$insert into public.subjects (name, kind) values ('Statistics', 'school')$$, 'admin can insert subjects');
select lives_ok($$update public.subjects set active = false where name = 'Statistics'$$, 'admin can update subjects');
select tests.as_postgres();
select is((select active from public.subjects where name = 'Statistics'), false, 'admin subjects update took effect');
select tests.as_user((select id from u where name = 'admin'));
select throws_ok($$delete from public.subjects where name = 'Statistics'$$, '42501', null, 'admin cannot delete subjects');
select lives_ok($$insert into public.parent_children values ((select id from u where name = 'parent'), (select id from u where name = 'stu2'))$$, 'admin can write parent_children');
select lives_ok($$delete from public.tutor_students where tutor_id = (select id from u where name = 'tutor2')$$, 'admin can delete tutor_students');
select tests.as_postgres();
select is((select count(*)::int from public.tutor_students where tutor_id = (select id from u where name = 'tutor2')), 0, 'admin tutor_students delete took effect');
select tests.as_user((select id from u where name = 'admin'));
select throws_ok($$update public.profiles set first_name = 'x'$$, '42501', null, 'admin cannot write profiles directly');
select is(public.my_role()::text, 'admin', 'my_role is admin');
select is(public.is_staff_admin(), true, 'active admin is staff admin');
reset role;

-- Owner.
select tests.as_user((select id from u where name = 'owner'));
select is((select count(*)::int from public.profiles), (select profiles from tot), 'owner reads all profiles');
select is((select count(*)::int from public.student_details), (select details from tot), 'owner reads all student_details');
select is((select count(*)::int from public.audit_log where action = 'rls_test'), 1, 'owner reads audit_log');
select lives_ok($$insert into public.teacher_subjects values ((select id from u where name = 'teacher'), (select id from public.subjects where name = 'Physics'))$$, 'owner can write teacher_subjects');
select is(public.is_staff_admin(), true, 'owner is staff admin');
reset role;

-- Suspended admin gets no admin powers.
select tests.as_user((select id from u where name = 'sadmin'));
select is((select count(*)::int from public.profiles), 1, 'suspended admin sees only own profile');
select is((select count(*)::int from public.student_details), 0, 'suspended admin reads 0 student_details');
select is((select count(*)::int from public.audit_log), 0, 'suspended admin reads 0 audit_log rows');
select throws_ok($$insert into public.parent_children values ((select id from u where name = 'parent'), (select id from u where name = 'stu2'))$$, '42501', null, 'suspended admin cannot write link tables');
select throws_ok($$insert into public.subjects (name, kind) values ('Nope', 'school')$$, '42501', null, 'suspended admin cannot insert subjects');
select is(public.my_role()::text, null, 'my_role is null for suspended user');
select is(public.is_staff_admin(), false, 'suspended admin is not staff admin');
reset role;

-- Closed default privileges for new objects, and pending_invites for authenticated.
set local role postgres;
create table public.scratch_t (id int);
create function public.scratch_f() returns int language sql as 'select 1';
reset role;
select is(has_table_privilege('authenticated', 'public.scratch_t', 'select'), false, 'new public table is closed to authenticated');
select is(has_table_privilege('anon', 'public.scratch_t', 'select'), false, 'new public table is closed to anon');
select is(has_function_privilege('authenticated', 'public.scratch_f()', 'execute'), false, 'new public function is closed to authenticated');
select is(has_function_privilege('anon', 'public.scratch_f()', 'execute'), false, 'new public function is closed to anon');
select tests.as_user((select id from u where name = 'stu1'));
select throws_ok($$select count(*) from public.pending_invites$$, '42501', null, 'authenticated cannot read pending_invites');
select tests.as_postgres();

-- Anon: no privileges on any table.
select set_config('request.jwt.claims', '', true);
set local role anon;
select throws_ok($$select count(*) from public.subjects$$, '42501', null, 'anon cannot read subjects');
select throws_ok($$select count(*) from public.profiles$$, '42501', null, 'anon cannot read profiles');
select throws_ok($$select count(*) from public.student_details$$, '42501', null, 'anon cannot read student_details');
select throws_ok($$select count(*) from public.student_subjects$$, '42501', null, 'anon cannot read student_subjects');
select throws_ok($$select count(*) from public.parent_children$$, '42501', null, 'anon cannot read parent_children');
select throws_ok($$select count(*) from public.teacher_subjects$$, '42501', null, 'anon cannot read teacher_subjects');
select throws_ok($$select count(*) from public.tutor_students$$, '42501', null, 'anon cannot read tutor_students');
select throws_ok($$select count(*) from public.audit_log$$, '42501', null, 'anon cannot read audit_log');
select throws_ok($$select count(*) from public.pending_invites$$, '42501', null, 'anon cannot read pending_invites');
reset role;

select * from finish();
rollback;
