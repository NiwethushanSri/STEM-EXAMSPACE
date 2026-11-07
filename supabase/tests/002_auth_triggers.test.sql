begin;
create extension if not exists pgtap with schema extensions;
select plan(34);

-- Sign-up with full metadata, messy email casing/whitespace.
insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data, created_at, instance_id, aud, role)
values ('00000000-0000-0000-0000-0000000000b1', 'Nimal.Perera@Example.com ',
  '{"first_name":"Nimal","last_name":"Perera","date_of_birth":"2009-05-01","school":"Royal College","parent_name":"Kamal Perera","parent_email":"  Kamal.Perera@Example.com "}'::jsonb,
  '{}'::jsonb, now(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated');

-- signup_creates_pending_student_profile
select is((select role::text from public.profiles where id = '00000000-0000-0000-0000-0000000000b1'),
  'student', 'signup_creates_pending_student_profile: role is student');
select is((select status::text from public.profiles where id = '00000000-0000-0000-0000-0000000000b1'),
  'unconfirmed', 'signup_creates_pending_student_profile: status is unconfirmed');
select is((select school from public.student_details where profile_id = '00000000-0000-0000-0000-0000000000b1'),
  'Royal College', 'signup_creates_pending_student_profile: school copied');
select is((select first_name || ' ' || last_name from public.profiles where id = '00000000-0000-0000-0000-0000000000b1'),
  'Nimal Perera', 'signup_creates_pending_student_profile: names copied');
select is((select date_of_birth from public.student_details where profile_id = '00000000-0000-0000-0000-0000000000b1'),
  '2009-05-01'::date, 'signup_creates_pending_student_profile: date of birth copied');
select is((select signup_parent_name from public.student_details where profile_id = '00000000-0000-0000-0000-0000000000b1'),
  'Kamal Perera', 'signup_creates_pending_student_profile: parent name copied');

-- signup_normalises_email
select is((select email::text from public.profiles where id = '00000000-0000-0000-0000-0000000000b1'),
  'nimal.perera@example.com', 'signup_normalises_email: profile email lowercased and trimmed');
select is((select signup_parent_email from public.student_details where profile_id = '00000000-0000-0000-0000-0000000000b1'),
  'kamal.perera@example.com', 'signup_normalises_email: parent email lowercased and trimmed');

-- signup_ignores_role_in_metadata
insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data, created_at, instance_id, aud, role)
values ('00000000-0000-0000-0000-0000000000b2', 'sneaky@example.com',
  '{"role":"owner","status":"active","first_name":"S"}'::jsonb,
  '{}'::jsonb, now(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated');
select is((select role::text from public.profiles where id = '00000000-0000-0000-0000-0000000000b2'),
  'student', 'signup_ignores_role_in_metadata: role stays student');
select is((select status::text from public.profiles where id = '00000000-0000-0000-0000-0000000000b2'),
  'unconfirmed', 'signup_ignores_role_in_metadata: status stays unconfirmed');

-- app_metadata invited_role is ignored entirely (no pending_invites row)
insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data, created_at, instance_id, aud, role)
values ('00000000-0000-0000-0000-0000000000b3', 'appmeta@example.com',
  '{}'::jsonb, '{"invited_role":"owner"}'::jsonb, now(),
  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated');
select is((select role::text from public.profiles where id = '00000000-0000-0000-0000-0000000000b3'),
  'student', 'app_metadata_invited_role_is_ignored: role is student');
select is((select status::text from public.profiles where id = '00000000-0000-0000-0000-0000000000b3'),
  'unconfirmed', 'app_metadata_invited_role_is_ignored: status is unconfirmed');

-- confirming_email_sets_pending
update auth.users set email_confirmed_at = now() where id = '00000000-0000-0000-0000-0000000000b1';
select is((select status::text from public.profiles where id = '00000000-0000-0000-0000-0000000000b1'),
  'pending', 'confirming_email_sets_pending: unconfirmed becomes pending');

-- invited_role_is_applied
insert into public.pending_invites (email, role) values ('Tutor.One@Example.com', 'tutor');
insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data, created_at, instance_id, aud, role)
values ('00000000-0000-0000-0000-0000000000b4', 'tutor.one@example.com',
  '{"first_name":"Tara","last_name":"Tutor"}'::jsonb,
  '{}'::jsonb, now(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated');
select is((select role::text from public.profiles where id = '00000000-0000-0000-0000-0000000000b4'),
  'tutor', 'invited_role_is_applied: role is tutor');
select is((select status::text from public.profiles where id = '00000000-0000-0000-0000-0000000000b4'),
  'active', 'invited_role_is_applied: status is active');
select is((select count(*)::int from public.pending_invites where email = 'tutor.one@example.com'),
  0, 'invited_role_is_applied: invite row consumed');
select is((select count(*)::int from public.student_details where profile_id = '00000000-0000-0000-0000-0000000000b4'),
  0, 'invited_role_is_applied: no student_details for staff');
select is((select first_name || ' ' || last_name from public.profiles where id = '00000000-0000-0000-0000-0000000000b4'),
  'Tara Tutor', 'invited_role_is_applied: names from metadata');

-- confirming an already-active invited user must not change status
update auth.users set email_confirmed_at = now() where id = '00000000-0000-0000-0000-0000000000b4';
select is((select status::text from public.profiles where id = '00000000-0000-0000-0000-0000000000b4'),
  'active', 'confirming_email_does_not_touch_active_staff');

-- invite_row_for_other_email_is_ignored
insert into public.pending_invites (email, role) values ('a@example.com', 'admin');
insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data, created_at, instance_id, aud, role)
values ('00000000-0000-0000-0000-0000000000b5', 'b@example.com',
  '{}'::jsonb, '{}'::jsonb, now(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated');
select is((select role::text from public.profiles where id = '00000000-0000-0000-0000-0000000000b5'),
  'student', 'invite_row_for_other_email_is_ignored: role is student');
select is((select status::text from public.profiles where id = '00000000-0000-0000-0000-0000000000b5'),
  'unconfirmed', 'invite_row_for_other_email_is_ignored: status is unconfirmed');
select is((select count(*)::int from public.pending_invites where email = 'a@example.com'),
  1, 'invite_row_for_other_email_is_ignored: invite for a@ untouched');

-- pending_invites hardening
select throws_ok(
  $$insert into public.pending_invites (email, role) values ('s@example.com', 'student')$$,
  '23514', null, 'pending_invites_rejects_student_role');
select is((select relrowsecurity from pg_class where oid = 'public.pending_invites'::regclass),
  true, 'pending_invites has RLS enabled');
select is(has_table_privilege('anon', 'public.pending_invites', 'select,insert,update,delete'),
  false, 'pending_invites_not_accessible_to_anon');
select is(has_table_privilege('authenticated', 'public.pending_invites', 'select,insert,update,delete'),
  false, 'pending_invites_not_accessible_to_authenticated');

-- guard_blocks_protected_columns_without_bypass (postgres role, no bypass)
select throws_ok(
  $$update public.profiles set role = 'owner' where id = '00000000-0000-0000-0000-0000000000b1'$$,
  '42501', null, 'guard_blocks_role_change_without_bypass');
select throws_ok(
  $$update public.profiles set status = 'active' where id = '00000000-0000-0000-0000-0000000000b1'$$,
  '42501', null, 'guard_blocks_status_change_without_bypass');
select throws_ok(
  $$update public.student_details set index_number = 'SE-2026-0001' where profile_id = '00000000-0000-0000-0000-0000000000b1'$$,
  '42501', null, 'guard_blocks_index_number_change_without_bypass');
select lives_ok(
  $$update public.profiles set first_name = 'Nim' where id = '00000000-0000-0000-0000-0000000000b1'$$,
  'guard_allows_unprotected_column_change');

-- guard_bypass_setting_allows_change
select set_config('app.bypass_guard', 'on', true);
select lives_ok(
  $$update public.profiles set status = 'active' where id = '00000000-0000-0000-0000-0000000000b1'$$,
  'guard_bypass_setting_allows_change');
select set_config('app.bypass_guard', 'off', true);

-- user_cannot_change_own_role_as_authenticated (no policies yet: update must change nothing)
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', '00000000-0000-0000-0000-0000000000b2', 'role', 'authenticated')::text, true);
update public.profiles set role = 'owner' where id = '00000000-0000-0000-0000-0000000000b2';
reset role;
select set_config('request.jwt.claims', '', true);
select is((select role::text from public.profiles where id = '00000000-0000-0000-0000-0000000000b2'),
  'student', 'user_cannot_change_own_role_as_authenticated: role unchanged');

-- service_role_context_can_change_status
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
select lives_ok(
  $$update public.profiles set status = 'suspended' where id = '00000000-0000-0000-0000-0000000000b2'$$,
  'service_role_context_can_change_status: update allowed');
select set_config('request.jwt.claims', '', true);
select is((select status::text from public.profiles where id = '00000000-0000-0000-0000-0000000000b2'),
  'suspended', 'service_role_context_can_change_status: status changed');

select * from finish();
rollback;
