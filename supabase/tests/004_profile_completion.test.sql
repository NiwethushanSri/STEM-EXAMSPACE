begin;
create extension if not exists pgtap with schema extensions;
select plan(34);

create temp table u (name text primary key, id uuid not null);
insert into u values
  ('a',       tests.create_user('student', 'profile_incomplete')),
  ('b',       tests.create_user('student', 'profile_incomplete')),
  ('c',       tests.create_user('student', 'profile_incomplete')),
  ('d',       tests.create_user('student', 'profile_incomplete')),
  ('pending', tests.create_user('student', 'pending')),
  ('active',  tests.create_user('student', 'active')),
  ('parent',  tests.create_user('parent', 'active')),
  ('admin',   tests.create_user('admin', 'active')),
  ('tutor',   tests.create_user('tutor', 'active'));
grant select on u to public;

insert into public.subjects (name, kind, active) values ('Retired Subject', 'school', false);
create temp table s (name text primary key, id bigint not null);
insert into s select name, id from public.subjects where name in ('Maths', 'Physics', 'TMUA', 'Retired Subject');
grant select on s to public;

-- Privileges.
select is(has_function_privilege('anon', 'public.complete_profile(text,text,bigint[],text,text)', 'execute'), false, 'anon cannot execute complete_profile');
select is(has_function_privilege('authenticated', 'public.complete_profile(text,text,bigint[],text,text)', 'execute'), true, 'authenticated can execute complete_profile');
select results_eq($q$select public, file_size_limit, allowed_mime_types from storage.buckets where id = 'student-photos'$q$,
  $q$values (false, 5242880::bigint, array['image/jpeg']::text[])$q$, 'bucket is private with 5MB and jpeg-only limits');

-- Happy path (student a).
select tests.as_postgres(); select tests.as_user((select id from u where name = 'a'));
select lives_ok(
  format($q$select public.complete_profile('Female', 'Year 12', array[%s,%s]::bigint[], ' 07123 456789 ', %L)$q$,
    (select id from s where name = 'Maths'), (select id from s where name = 'Physics'),
    (select id from u where name = 'a') || '/photo.jpg'),
  'complete_profile_activates_student: call succeeds');
select tests.as_postgres();
select is((select status::text from public.profiles where id = (select id from u where name = 'a')), 'active', 'status is active after completion');
select results_eq(
  format($q$select gender, year_group, parent_phone, photo_path from public.student_details where profile_id = %L$q$, (select id from u where name = 'a')),
  format($q$values ('Female'::text, 'Year 12'::text, '07123 456789'::text, %L::text)$q$, (select id from u where name = 'a') || '/photo.jpg'),
  'details written, phone trimmed, photo path stored');
select results_eq(
  format($q$select subject_id from public.student_subjects where student_id = %L order by subject_id$q$, (select id from u where name = 'a')),
  $q$select id from public.subjects where name in ('Maths','Physics') order by id$q$,
  'complete_profile_replaces_subjects: exactly the given set');

-- Replaces pre-existing subject rows (student b has TMUA already).
insert into public.student_subjects values ((select id from u where name = 'b'), (select id from s where name = 'TMUA'));
select tests.as_postgres(); select tests.as_user((select id from u where name = 'b'));
select lives_ok(
  format($q$select public.complete_profile('Male', 'Year 13', array[%s]::bigint[], '0700', null)$q$, (select id from s where name = 'Maths')),
  'complete without photo succeeds');
select tests.as_postgres();
select results_eq(
  format($q$select subject_id from public.student_subjects where student_id = %L$q$, (select id from u where name = 'b')),
  format($q$select %s::bigint$q$, (select id from s where name = 'Maths')),
  'old subject rows replaced');
select is((select photo_path from public.student_details where profile_id = (select id from u where name = 'b')), null, 'no photo path when none given');

-- Rejections (student c, profile_incomplete).
select tests.as_postgres(); select tests.as_user((select id from u where name = 'c'));
select throws_ok($q$select public.complete_profile('Female', 'Year 11', array[]::bigint[], '0700', null)$q$,
  'P0001', 'Choose at least one subject', 'complete_profile_rejects_empty_subjects');
select throws_ok($q$select public.complete_profile('Female', 'Year 11', null, '0700', null)$q$,
  'P0001', 'Choose at least one subject', 'null subjects rejected');
select throws_ok(
  format($q$select public.complete_profile('Female', 'Year 9', array[%s]::bigint[], '0700', null)$q$, (select id from s where name = 'Maths')),
  'P0001', 'Invalid year group', 'complete_profile_rejects_unknown_year_group');
select throws_ok(
  format($q$select public.complete_profile('Robot', 'Year 11', array[%s]::bigint[], '0700', null)$q$, (select id from s where name = 'Maths')),
  'P0001', 'Invalid gender', 'unknown gender rejected');
select throws_ok(
  format($q$select public.complete_profile('Female', 'Year 11', array[%s]::bigint[], '   ', null)$q$, (select id from s where name = 'Maths')),
  'P0001', 'Parent phone is required', 'blank phone rejected');
select throws_ok(
  format($q$select public.complete_profile('Female', 'Year 11', array[%s]::bigint[], '0700', null)$q$, (select id from s where name = 'Retired Subject')),
  'P0001', 'Every subject must exist and be active', 'complete_profile_rejects_inactive_subject');
select throws_ok(
  format($q$select public.complete_profile('Female', 'Year 11', array[%s, -5]::bigint[], '0700', null)$q$, (select id from s where name = 'Maths')),
  'P0001', 'Every subject must exist and be active', 'unknown subject id rejected');
select throws_ok(
  format($q$select public.complete_profile('Female', 'Year 11', array[%s]::bigint[], '0700', %L)$q$,
    (select id from s where name = 'Maths'), (select id from u where name = 'a') || '/photo.jpg'),
  'P0001', 'Invalid photo path', 'complete_profile_rejects_wrong_photo_path');
select tests.as_postgres();
select is((select status::text from public.profiles where id = (select id from u where name = 'c')), 'profile_incomplete', 'rejections leave status unchanged');

-- Wrong state / wrong role.
select tests.as_postgres(); select tests.as_user((select id from u where name = 'pending'));
select throws_ok(
  format($q$select public.complete_profile('Female', 'Year 11', array[%s]::bigint[], '0700', null)$q$, (select id from s where name = 'Maths')),
  'P0001', 'Profile can only be completed by a student with an incomplete profile', 'complete_profile_rejects_when_pending');
select tests.as_postgres(); select tests.as_user((select id from u where name = 'active'));
select throws_ok(
  format($q$select public.complete_profile('Female', 'Year 11', array[%s]::bigint[], '0700', null)$q$, (select id from s where name = 'Maths')),
  'P0001', 'Profile can only be completed by a student with an incomplete profile', 'already-active student cannot re-run');
select tests.as_postgres(); select tests.as_user((select id from u where name = 'parent'));
select throws_ok(
  format($q$select public.complete_profile('Female', 'Year 11', array[%s]::bigint[], '0700', null)$q$, (select id from s where name = 'Maths')),
  'P0001', 'Profile can only be completed by a student with an incomplete profile', 'parent_cannot_complete_profile');
select tests.as_postgres();

-- Storage policies.
insert into storage.objects (bucket_id, name) values
  ('student-photos', (select id from u where name = 'd') || '/photo.jpg');
select tests.as_postgres(); select tests.as_user((select id from u where name = 'c'));
select lives_ok(
  format($q$insert into storage.objects (bucket_id, name) values ('student-photos', %L)$q$, (select id from u where name = 'c') || '/photo.jpg'),
  'student can upload own photo');
select throws_ok(
  format($q$insert into storage.objects (bucket_id, name) values ('student-photos', %L)$q$, (select id from u where name = 'd') || '/other.jpg'),
  '42501', null, 'student_cannot_upload_to_other_folder');
select throws_ok(
  format($q$insert into storage.objects (bucket_id, name) values ('student-photos', %L)$q$, (select id from u where name = 'c') || '/other.jpg'),
  '42501', null, 'student cannot upload other file name in own folder');
select is((select count(*)::int from storage.objects where bucket_id = 'student-photos' and name = (select id from u where name = 'd') || '/photo.jpg'), 0, 'student_cannot_read_other_photo');
select is((select count(*)::int from storage.objects where bucket_id = 'student-photos' and name = (select id from u where name = 'c') || '/photo.jpg'), 1, 'student reads own photo');
select tests.as_postgres(); select tests.as_user((select id from u where name = 'tutor'));
select is((select count(*)::int from storage.objects where bucket_id = 'student-photos' and name in (select id || '/photo.jpg' from u where name in ('c','d'))), 0, 'tutor cannot read photos');
select tests.as_postgres(); select tests.as_user((select id from u where name = 'admin'));
select is((select count(*)::int from storage.objects where bucket_id = 'student-photos' and name in (select id || '/photo.jpg' from u where name in ('c','d'))), 2, 'admin_can_read_any_photo_object');
-- Update / delete policies (c owns c/photo.jpg, d owns d/photo.jpg).
select tests.as_postgres(); select tests.as_user((select id from u where name = 'c'));
select throws_ok(
  format($q$update storage.objects set name = %L where bucket_id = 'student-photos' and name = %L$q$,
    (select id from u where name = 'd') || '/photo.jpg', (select id from u where name = 'c') || '/photo.jpg'),
  '42501', null, 'student cannot rename own object into another folder');
select lives_ok(
  format($q$update storage.objects set metadata = '{"x":1}' where bucket_id = 'student-photos' and name = %L$q$, (select id from u where name = 'd') || '/photo.jpg'),
  'update of other student object runs but matches nothing');
select tests.as_postgres();
select is((select count(*)::int from storage.objects where bucket_id = 'student-photos' and name = (select id from u where name = 'c') || '/photo.jpg'), 1, 'own object not renamed');
select is((select count(*)::int from storage.objects where bucket_id = 'student-photos' and name = (select id from u where name = 'd') || '/photo.jpg' and metadata is null), 1, 'other object still exists and unchanged');
select tests.as_user((select id from u where name = 'c'));
select lives_ok(
  format($q$update storage.objects set metadata = '{"x":1}' where bucket_id = 'student-photos' and name = %L$q$, (select id from u where name = 'c') || '/photo.jpg'),
  'student can update own object');
select tests.as_postgres();

select * from finish();
rollback;
