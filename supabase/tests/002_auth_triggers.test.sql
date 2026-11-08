begin;
create extension if not exists pgtap with schema extensions;
select plan(42);

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

-- sign-up never applies an invite (claim_invite does, afterwards): even with a matching token it is a plain student
insert into public.pending_invites (email, role, token)
  values ('tutor.one@example.com', 'tutor', '00000000-0000-0000-0000-0000000000c1');
insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data, created_at, instance_id, aud, role)
values ('00000000-0000-0000-0000-0000000000b4', 'tutor.one@example.com',
  '{"first_name":"Tara","last_name":"Tutor"}'::jsonb,
  '{"invite_token":"00000000-0000-0000-0000-0000000000c1"}'::jsonb, now(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated');
select is((select role::text from public.profiles where id = '00000000-0000-0000-0000-0000000000b4'),
  'student', 'invite_not_applied_by_trigger: role is student');
select is((select status::text from public.profiles where id = '00000000-0000-0000-0000-0000000000b4'),
  'unconfirmed', 'invite_not_applied_by_trigger: status is unconfirmed');
select is((select count(*)::int from public.pending_invites where email = 'tutor.one@example.com'),
  1, 'invite_not_applied_by_trigger: invite row untouched');
select is((select count(*)::int from public.student_details where profile_id = '00000000-0000-0000-0000-0000000000b4'),
  1, 'invite_not_applied_by_trigger: student_details created');
select is((select first_name || ' ' || last_name from public.profiles where id = '00000000-0000-0000-0000-0000000000b4'),
  'Tara Tutor', 'invite_not_applied_by_trigger: names from metadata');

-- confirming moves the unclaimed shell to pending
update auth.users set email_confirmed_at = now() where id = '00000000-0000-0000-0000-0000000000b4';
select is((select status::text from public.profiles where id = '00000000-0000-0000-0000-0000000000b4'),
  'pending', 'confirming_email_moves_unclaimed_shell_to_pending');

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

-- public_signup_cannot_claim_invite (matching email, no token) and wrong_invite_token_is_ignored
insert into public.pending_invites (email, role) values ('victim@example.com', 'parent');
insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data, created_at, instance_id, aud, role)
values ('00000000-0000-0000-0000-0000000000b6', 'victim@example.com',
  '{"invite_token":"x"}'::jsonb, '{}'::jsonb, now(),
  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated');
select is((select role::text || '/' || status::text from public.profiles where id = '00000000-0000-0000-0000-0000000000b6'),
  'student/unconfirmed', 'public_signup_cannot_claim_invite: student/unconfirmed');
select is((select count(*)::int from public.pending_invites where email = 'victim@example.com'),
  1, 'public_signup_cannot_claim_invite: invite row still present');
insert into public.pending_invites (email, role) values ('victim2@example.com', 'admin');
insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data, created_at, instance_id, aud, role)
values ('00000000-0000-0000-0000-0000000000b7', 'victim2@example.com',
  '{}'::jsonb, '{"invite_token":"00000000-0000-0000-0000-0000000000ff"}'::jsonb, now(),
  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated');
select is((select role::text || '/' || status::text from public.profiles where id = '00000000-0000-0000-0000-0000000000b7'),
  'student/unconfirmed', 'wrong_invite_token_is_ignored: student/unconfirmed');
select is((select count(*)::int from public.pending_invites where email = 'victim2@example.com'),
  1, 'wrong_invite_token_is_ignored: invite row still present');
select is((select count(*)::int from public.student_details where profile_id = '00000000-0000-0000-0000-0000000000b7'),
  1, 'wrong_invite_token_is_ignored: student_details created');
select is((select count(*)::int from public.student_details where profile_id = '00000000-0000-0000-0000-0000000000b6'),
  1, 'public_signup_cannot_claim_invite: student_details created');

-- confirmed_at_insert_starts_pending
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data, raw_app_meta_data, created_at, instance_id, aud, role)
values ('00000000-0000-0000-0000-0000000000b8', 'preconfirmed@example.com', now(),
  '{}'::jsonb, '{}'::jsonb, now(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated');
select is((select status::text from public.profiles where id = '00000000-0000-0000-0000-0000000000b8'),
  'pending', 'confirmed_at_insert_starts_pending');

-- invalid date_of_birth does not abort sign-up
insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data, created_at, instance_id, aud, role)
values ('00000000-0000-0000-0000-0000000000b9', 'baddob@example.com',
  '{"date_of_birth":"not-a-date"}'::jsonb, '{}'::jsonb, now(),
  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated');
select is((select count(*)::int from public.profiles where id = '00000000-0000-0000-0000-0000000000b9'),
  1, 'invalid_dob_does_not_abort_signup: profile created');
select is((select date_of_birth from public.student_details where profile_id = '00000000-0000-0000-0000-0000000000b9'),
  null::date, 'invalid_dob_does_not_abort_signup: date_of_birth is null');

select throws_ok(
  $$insert into public.pending_invites (email, role) values ('Mixed@Example.com', 'admin')$$,
  '23514', null, 'pending_invites_requires_normalised_email');

-- Guard tests: temporary policies/grants (rolled back) make rows reachable for authenticated.
grant select, update on public.profiles, public.student_details to authenticated;
create policy tmp_sel on public.profiles for select to authenticated using (true);
create policy tmp_upd on public.profiles for update to authenticated using (true) with check (true);
create policy tmp_sel on public.student_details for select to authenticated using (true);
create policy tmp_upd on public.student_details for update to authenticated using (true) with check (true);
select set_config('request.jwt.claims',
  json_build_object('sub', '00000000-0000-0000-0000-0000000000b2', 'role', 'authenticated')::text, true);

set local role authenticated;
select throws_ok(
  $$update public.profiles set role = 'owner' where id = '00000000-0000-0000-0000-0000000000b2'$$,
  '42501', null, 'user_cannot_change_own_role: authenticated role change throws');
select throws_ok(
  $$update public.profiles set status = 'active' where id = '00000000-0000-0000-0000-0000000000b2'$$,
  '42501', null, 'authenticated_status_change_throws');
select throws_ok(
  $$update public.student_details set index_number = 'SE-2026-0001' where profile_id = '00000000-0000-0000-0000-0000000000b1'$$,
  '42501', null, 'authenticated_index_number_change_throws');
select lives_ok(
  $$update public.profiles set first_name = 'Nim' where id = '00000000-0000-0000-0000-0000000000b2'$$,
  'authenticated_can_change_unprotected_column');
reset role;

select lives_ok(
  $$update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-0000000000b2'$$,
  'postgres_can_change_role');

set local role service_role;
select lives_ok(
  $$update public.profiles set status = 'suspended' where id = '00000000-0000-0000-0000-0000000000b2'$$,
  'service_role_can_change_status');
reset role;

select * from finish();
rollback;
