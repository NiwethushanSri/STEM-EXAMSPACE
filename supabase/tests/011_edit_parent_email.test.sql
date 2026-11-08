begin;
create extension if not exists pgtap with schema extensions;
select plan(20);
select tests.assert_no_owner();

select is(has_function_privilege('service_role', 'public.edit_parent_email_tx(uuid,uuid,text)', 'execute'), true, 'service_role may execute');
select is(has_function_privilege('authenticated', 'public.edit_parent_email_tx(uuid,uuid,text)', 'execute'), false, 'authenticated may not');
select is(has_function_privilege('anon', 'public.edit_parent_email_tx(uuid,uuid,text)', 'execute'), false, 'anon may not');

create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('admin', tests.create_user('admin', 'active')), ('tutor', tests.create_user('tutor', 'active')),
  ('parent', tests.create_user('parent', 'active')),
  ('s_pend', tests.create_user('student', 'pending')), ('s_appr', tests.create_user('student', 'active')),
  ('s_linked', tests.create_user('student', 'active')), ('s_susp', tests.create_user('student', 'suspended')),
  ('s_blank', tests.create_user('student', 'pending')), ('s_shell', tests.create_user('student', 'pending'));
update public.student_details set signup_parent_email = 'orig.parent@example.test' where profile_id = (select id from c where name='s_pend');
update public.student_details set signup_parent_email = null where profile_id in (select id from c where name in ('s_blank','s_shell'));
update auth.users set raw_app_meta_data = '{"invite_token":"00000000-0000-0000-0000-000000000001"}'::jsonb where id = (select id from c where name='s_shell');
update public.student_details set index_number = 'SE-2099-9101' where profile_id = (select id from c where name='s_appr');
update public.student_details set index_number = 'SE-2099-9102' where profile_id = (select id from c where name='s_linked');
insert into public.parent_children (parent_id, student_id) values ((select id from c where name='parent'), (select id from c where name='s_linked'));

select is(public.edit_parent_email_tx((select id from c where name='s_pend'), (select id from c where name='admin'), '  New.Parent@Example.TEST '), 'ok', 'admin edits pending student');
select is((select signup_parent_email from public.student_details where profile_id = (select id from c where name='s_pend')), 'new.parent@example.test', 'email normalised');
select is((select count(*)::int from public.audit_log where action='parent_email_edited' and target_type='profile'
  and target_id=(select id from c where name='s_pend') and actor_id=(select id from c where name='admin')), 1, 'audited with target');
select is(public.edit_parent_email_tx((select id from c where name='s_appr'), (select id from c where name='admin'), 'p2@example.test'), 'ok', 'approved unlinked student allowed');
select is(public.edit_parent_email_tx((select id from c where name='s_linked'), (select id from c where name='admin'), 'p3@example.test'), 'conflict', 'approved linked student refused');
select is(public.edit_parent_email_tx((select id from c where name='s_susp'), (select id from c where name='admin'), 'p4@example.test'), 'conflict', 'suspended student refused');
select is(public.edit_parent_email_tx((select id from c where name='tutor'), (select id from c where name='admin'), 'p5@example.test'), 'conflict', 'non-student refused');
select is(public.edit_parent_email_tx((select id from c where name='s_pend'), (select id from c where name='tutor'), 'p6@example.test'), 'forbidden', 'non-admin actor refused');
select is(public.edit_parent_email_tx((select id from c where name='s_pend'), (select id from c where name='admin'), 'not-an-email'), 'invalid_input', 'bad shape refused');
select is(public.edit_parent_email_tx((select id from c where name='s_pend'), (select id from c where name='admin'), 'a b@example.test'), 'invalid_input', 'whitespace inside refused');
select is(public.edit_parent_email_tx(gen_random_uuid(), (select id from c where name='admin'), 'p7@example.test'), 'not_found', 'unknown target');
select is((select signup_parent_email from public.student_details where profile_id = (select id from c where name='s_pend')), 'new.parent@example.test', 'refusals changed nothing');
select is((select count(*)::int from public.audit_log where action='parent_email_edited' and actor_id=(select id from c where name='admin')), 2, 'only successful edits audited');
select is((select count(*)::int from public.audit_log where action='parent_email_edited' and target_id=(select id from c where name='s_linked')), 0, 'no audit for refused');

select is(public.edit_parent_email_tx((select id from c where name='s_blank'), (select id from c where name='admin'), 'b1@example.test'), 'conflict', 'pending student without signup parent email refused');
select is(public.edit_parent_email_tx((select id from c where name='s_shell'), (select id from c where name='admin'), 'b2@example.test'), 'conflict', 'token-bearing invite shell refused');
select is((select count(*)::int from public.student_details where profile_id in (select id from c where name in ('s_blank','s_shell')) and signup_parent_email is not null), 0, 'shell and blank rows unchanged');

select * from finish();
rollback;
