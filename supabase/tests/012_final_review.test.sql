begin;
create extension if not exists pgtap with schema extensions;
select plan(30);

create temp table u (name text primary key, id uuid not null);
insert into u values
  ('inc',    tests.create_user('student', 'profile_incomplete')),
  ('act',    tests.create_user('student', 'active')),
  ('pend',   tests.create_user('student', 'pending')),
  ('susp',   tests.create_user('student', 'suspended')),
  ('par',    tests.create_user('parent', 'active')),
  ('adm',    tests.create_user('admin', 'active')),
  ('shell',  tests.create_user('student', 'pending')),
  ('tutor',  tests.create_user('tutor', 'pending'));
grant select on u to public;

-- Removed functions.
select hasnt_function('public', 'login_attempt_clear', 'login_attempt_clear is gone');
select hasnt_function('public', 'claim_parent_invite', 'claim_parent_invite wrapper is gone');

-- Email sync (I2).
update auth.users set email = '  New.Address@Example.COM ' where id = (select id from u where name = 'act');
select is((select email::text from public.profiles where id = (select id from u where name = 'act')),
  'new.address@example.com', 'profile email follows an auth email change (lowercased, trimmed)');
update auth.users set raw_user_meta_data = '{"x":1}'::jsonb where id = (select id from u where name = 'act');
select is((select email::text from public.profiles where id = (select id from u where name = 'act')),
  'new.address@example.com', 'unrelated auth update leaves the profile email alone');

-- Sign-up still behaves the same without the invite branch.
insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data, created_at, instance_id, aud, role)
values ('00000000-0000-0000-0000-0000000000c1', 'Fresh.Signup@Example.com ',
  '{"first_name":"A","last_name":"B","school":"S","parent_email":" P@Example.com "}'::jsonb,
  '{}'::jsonb, now(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated');
select is((select status::text || '/' || email::text from public.profiles where id = '00000000-0000-0000-0000-0000000000c1'),
  'unconfirmed/fresh.signup@example.com', 'sign-up creates an unconfirmed student with a normalised email');
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data, raw_app_meta_data, created_at, instance_id, aud, role)
values ('00000000-0000-0000-0000-0000000000c2', 'confirmed.signup@example.com', now(), '{}'::jsonb, '{}'::jsonb, now(),
  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated');
select is((select status::text from public.profiles where id = '00000000-0000-0000-0000-0000000000c2'),
  'pending', 'sign-up of an already confirmed user is pending');
select is((select signup_parent_email from public.student_details where profile_id = '00000000-0000-0000-0000-0000000000c1'),
  'p@example.com', 'parent email normalised');

-- Privileges.
select is(has_function_privilege('authenticated', 'public.my_status()', 'execute'), true, 'authenticated can execute my_status');
select is(has_function_privilege('anon', 'public.my_status()', 'execute'), false, 'anon cannot execute my_status');
select is(has_function_privilege('authenticated', 'public.can_reject_student(uuid)', 'execute'), false, 'can_reject_student not executable by authenticated');
select is(has_function_privilege('service_role', 'public.can_reject_student(uuid)', 'execute'), true, 'can_reject_student executable by service_role');
select is(has_function_privilege('authenticated', 'public.sync_profile_email()', 'execute'), false, 'sync_profile_email not executable by authenticated');

-- can_reject_student mirrors reject_student_tx.
select is(public.can_reject_student((select id from u where name = 'pend')), 'ok', 'pending student can be rejected');
select is(public.can_reject_student((select id from u where name = 'act')), 'conflict', 'active student: conflict');
select is(public.can_reject_student((select id from u where name = 'tutor')), 'conflict', 'non-student: conflict');
select is(public.can_reject_student(gen_random_uuid()), 'not_found', 'unknown id: not_found');
update auth.users set raw_app_meta_data = jsonb_build_object('invite_token', gen_random_uuid()::text) where id = (select id from u where name = 'shell');
update public.student_details set signup_parent_email = null where profile_id = (select id from u where name = 'shell');
select is(public.can_reject_student((select id from u where name = 'shell')), 'conflict', 'token-bearing invite shell: conflict');

-- Storage writes: learners only, and only while profile_incomplete or active.
select tests.as_user((select id from u where name = 'inc'));
select is(public.my_status()::text, 'profile_incomplete', 'my_status reads the caller status');
select lives_ok(
  format($q$insert into storage.objects (bucket_id, name) values ('student-photos', %L)$q$, (select id from u where name = 'inc') || '/photo.jpg'),
  'profile_incomplete student can upload');
select tests.as_postgres(); select tests.as_user((select id from u where name = 'pend'));
select throws_ok(
  format($q$insert into storage.objects (bucket_id, name) values ('student-photos', %L)$q$, (select id from u where name = 'pend') || '/photo.jpg'),
  '42501', null, 'pending student cannot upload');
select tests.as_postgres(); select tests.as_user((select id from u where name = 'par'));
select throws_ok(
  format($q$insert into storage.objects (bucket_id, name) values ('student-photos', %L)$q$, (select id from u where name = 'par') || '/photo.jpg'),
  '42501', null, 'parent cannot upload');
select tests.as_postgres(); select tests.as_user((select id from u where name = 'susp'));
select throws_ok(
  format($q$insert into storage.objects (bucket_id, name) values ('student-photos', %L)$q$, (select id from u where name = 'susp') || '/photo.jpg'),
  '42501', null, 'suspended student cannot upload');
select tests.as_postgres();

-- replace_unconfirmed_signup (register-student): only a plain unconfirmed self sign-up is ever removed.
select is(has_function_privilege('authenticated', 'public.replace_unconfirmed_signup(text)', 'execute'), false, 'replace_unconfirmed_signup not executable by authenticated');
select is(has_function_privilege('service_role', 'public.replace_unconfirmed_signup(text)', 'execute'), true, 'replace_unconfirmed_signup executable by service_role');
insert into u values ('unc', tests.create_user('student', 'unconfirmed')), ('kid', tests.create_user('student', 'unconfirmed')),
  ('tunc', tests.create_user('tutor', 'unconfirmed'));
update public.student_details set requested_by_parent = (select id from u where name = 'par') where profile_id = (select id from u where name = 'kid');
update auth.users set email_confirmed_at = now() where id = (select id from u where name = 'act');
update auth.users set created_at = now() - interval '2 hours' where id in (select id from u where name in ('unc', 'kid', 'tunc'));
select is(public.replace_unconfirmed_signup('nobody@example.test'), 'none', 'unknown address: none');
select is(public.replace_unconfirmed_signup((select email from auth.users where id = (select id from u where name = 'act'))), 'confirmed', 'confirmed address: nothing changes');
select is(public.replace_unconfirmed_signup((select email from auth.users where id = (select id from u where name = 'kid'))), 'protected', 'child registered by a parent is protected');
select is(public.replace_unconfirmed_signup((select email from auth.users where id = (select id from u where name = 'tunc'))), 'protected', 'unconfirmed non-student is protected');
select is(public.replace_unconfirmed_signup((select upper(email) from auth.users where id = (select id from u where name = 'unc'))), 'replaced', 'unconfirmed self sign-up is replaced (case-insensitive)');
select is((select count(*)::int from auth.users where id in (select id from u where name in ('unc'))), 0, 'replaced account is gone');

select * from finish();
rollback;
