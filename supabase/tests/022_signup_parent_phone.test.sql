begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

-- signup_copies_parent_phone: a valid phone in the metadata lands on student_details, spaces tidied.
insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data, created_at, instance_id, aud, role)
values ('00000000-0000-0000-0000-0000000044a1', 'phone.one@example.com',
  '{"first_name":"Amara","last_name":"Perera","date_of_birth":"2009-03-12","school":"Kingsbury High School","parent_name":"Nimal Perera","parent_email":"nimal@example.com","parent_phone":"  +44   7700 900123 "}'::jsonb,
  '{}'::jsonb, now(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated');
select is((select parent_phone from public.student_details where profile_id = '00000000-0000-0000-0000-0000000044a1'),
  '+44 7700 900123', 'signup_copies_parent_phone: phone copied with single spaces');

-- signup_without_phone: older clients send none; the column stays null.
insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data, created_at, instance_id, aud, role)
values ('00000000-0000-0000-0000-0000000044a2', 'phone.two@example.com',
  '{"first_name":"B","last_name":"C","parent_email":"p2@example.com"}'::jsonb,
  '{}'::jsonb, now(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated');
select is((select parent_phone from public.student_details where profile_id = '00000000-0000-0000-0000-0000000044a2'),
  null, 'signup_without_phone: parent_phone is null');

-- signup_rejects_bad_phone: letters or too few digits are dropped, never stored.
insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data, created_at, instance_id, aud, role)
values ('00000000-0000-0000-0000-0000000044a3', 'phone.three@example.com',
  '{"first_name":"D","last_name":"E","parent_phone":"call me maybe"}'::jsonb,
  '{}'::jsonb, now(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated');
select is((select parent_phone from public.student_details where profile_id = '00000000-0000-0000-0000-0000000044a3'),
  null, 'signup_rejects_bad_phone: text that is not a phone is dropped');
insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data, created_at, instance_id, aud, role)
values ('00000000-0000-0000-0000-0000000044a4', 'phone.four@example.com',
  '{"first_name":"F","last_name":"G","parent_phone":"077009001"}'::jsonb,
  '{}'::jsonb, now(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated');
select is((select parent_phone from public.student_details where profile_id = '00000000-0000-0000-0000-0000000044a4'),
  null, 'signup_rejects_bad_phone: nine digits are dropped');

select * from finish();
rollback;
