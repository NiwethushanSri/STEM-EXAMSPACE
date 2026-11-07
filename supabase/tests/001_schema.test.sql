begin;
create extension if not exists pgtap with schema extensions;
select plan(26);

select has_table('public', t, t || ' table exists')
from unnest(array['profiles','student_details','subjects','student_subjects',
                  'parent_children','teacher_subjects','tutor_students','audit_log']) as t;

select enum_has_labels('public', 'app_role',
  array['owner','admin','teacher','tutor','corrector','student','parent']);
select enum_has_labels('public', 'account_status',
  array['unconfirmed','pending','profile_incomplete','active','suspended']);
select enum_has_labels('public', 'subject_kind', array['school','entrance']);

select is((select count(*)::int from public.subjects), 9, '9 seeded subjects');
select results_eq(
  $$select name::text from public.subjects where kind = 'school' order by name$$,
  array['Biology','Chemistry','Computer Science','Further Maths','Maths','Physics'],
  'school subjects');
select results_eq(
  $$select name::text from public.subjects where kind = 'entrance' order by name$$,
  array['FSAT','TMUA','UCAT'],
  'entrance subjects');

select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = any(array['profiles','student_details','subjects',
      'student_subjects','parent_children','teacher_subjects','tutor_students','audit_log'])
      and c.relrowsecurity),
  8, 'RLS enabled on all 8 tables');

select col_is_pk('public', 'profiles', array['id'], 'profiles.id primary key');
select col_is_unique('public', 'profiles', array['email'], 'profiles.email unique');
select col_type_is('public', 'profiles', 'email', 'extensions', 'citext', 'profiles.email is citext');
select col_is_unique('public', 'student_details', array['index_number'], 'student_details.index_number unique');
select col_is_pk('public', 'student_details', array['profile_id'], 'student_details.profile_id primary key');
select col_is_unique('public', 'subjects', array['name'], 'subjects.name unique');
select col_is_pk('public', 'student_subjects', array['student_id','subject_id'], 'student_subjects composite primary key');
select col_is_pk('public', 'parent_children', array['parent_id','student_id'], 'parent_children composite primary key');
select col_is_pk('public', 'teacher_subjects', array['teacher_id','subject_id'], 'teacher_subjects composite primary key');
select col_is_pk('public', 'tutor_students', array['tutor_id','student_id'], 'tutor_students composite primary key');

insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000a1', 'cascade@example.com');
insert into public.profiles (id, role, status, first_name, last_name, email)
  values ('00000000-0000-0000-0000-0000000000a1', 'student', 'pending', 'C', 'D', 'cascade@example.com');
insert into public.student_details (profile_id) values ('00000000-0000-0000-0000-0000000000a1');
delete from auth.users where id = '00000000-0000-0000-0000-0000000000a1';
select is(
  (select count(*)::int from public.profiles where id = '00000000-0000-0000-0000-0000000000a1')
  + (select count(*)::int from public.student_details where profile_id = '00000000-0000-0000-0000-0000000000a1'),
  0, 'deleting auth user cascades to profile and student_details');

select * from finish();
rollback;
