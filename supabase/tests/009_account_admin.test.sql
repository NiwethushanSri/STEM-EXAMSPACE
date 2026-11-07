begin;
create extension if not exists pgtap with schema extensions;
select plan(57);
select tests.assert_no_owner();

-- Privileges: service_role only.
select is(has_function_privilege('service_role', 'public.set_account_status_tx(uuid,uuid,text)', 'execute'), true, 'set_account_status_tx: service_role');
select is(has_function_privilege('authenticated', 'public.set_account_status_tx(uuid,uuid,text)', 'execute'), false, 'set_account_status_tx: not authenticated');
select is(has_function_privilege('anon', 'public.set_account_status_tx(uuid,uuid,text)', 'execute'), false, 'set_account_status_tx: not anon');
select is(has_function_privilege('service_role', 'public.remove_staff_tx(uuid,uuid)', 'execute'), true, 'remove_staff_tx: service_role');
select is(has_function_privilege('authenticated', 'public.remove_staff_tx(uuid,uuid)', 'execute'), false, 'remove_staff_tx: not authenticated');
select is(has_function_privilege('anon', 'public.remove_staff_tx(uuid,uuid)', 'execute'), false, 'remove_staff_tx: not anon');
select is(has_function_privilege('service_role', 'public.clear_invite_tx(text,uuid)', 'execute'), true, 'clear_invite_tx: service_role');
select is(has_function_privilege('authenticated', 'public.clear_invite_tx(text,uuid)', 'execute'), false, 'clear_invite_tx: not authenticated');
select is(has_function_privilege('anon', 'public.clear_invite_tx(text,uuid)', 'execute'), false, 'clear_invite_tx: not anon');
select is(has_function_privilege('service_role', 'public.delete_own_account_tx(uuid)', 'execute'), true, 'delete_own_account_tx: service_role');
select is(has_function_privilege('authenticated', 'public.delete_own_account_tx(uuid)', 'execute'), false, 'delete_own_account_tx: not authenticated');
select is(has_function_privilege('anon', 'public.delete_own_account_tx(uuid)', 'execute'), false, 'delete_own_account_tx: not anon');

create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('owner', tests.create_user('owner', 'active'));
insert into c select n, tests.create_user('admin', 'active') from unnest(array['admin','admin2']) n;
insert into c select n, tests.create_user('tutor', 'active') from unnest(array['tutor','tutor2']) n;
insert into c select n, tests.create_user('student', 'active') from unnest(array['s_subj','s_idx','s_none','s_uncf']) n;
insert into c values ('parent', tests.create_user('parent', 'active'));

-- Suspend: staff, owner/admin rules, self, wrong state.
select is(public.set_account_status_tx((select id from c where name='tutor'), (select id from c where name='admin'), 'suspend'), 'suspended', 'admin suspends tutor');
select is((select status::text from public.profiles where id = (select id from c where name='tutor')), 'suspended', 'tutor is suspended');
select is((select count(*)::int from public.audit_log where action='account_suspended' and target_type='profile'
  and target_id=(select id from c where name='tutor') and actor_id=(select id from c where name='admin')), 1, 'suspend audited with target');
select is(public.set_account_status_tx((select id from c where name='tutor'), (select id from c where name='admin'), 'suspend'), 'conflict', 'suspending suspended -> conflict');
select is((select count(*)::int from public.audit_log where action='account_suspended' and target_id=(select id from c where name='tutor')), 1, 'refusal writes no audit row');
select is(public.set_account_status_tx((select id from c where name='admin2'), (select id from c where name='admin'), 'suspend'), 'forbidden', 'admin cannot suspend admin');
select is(public.set_account_status_tx((select id from c where name='owner'), (select id from c where name='admin'), 'suspend'), 'forbidden', 'nobody suspends the owner (admin)');
select is(public.set_account_status_tx((select id from c where name='owner'), (select id from c where name='owner'), 'suspend'), 'forbidden', 'nobody suspends the owner (self)');
select is(public.set_account_status_tx((select id from c where name='admin'), (select id from c where name='admin'), 'suspend'), 'forbidden', 'no self-suspension');
select is(public.set_account_status_tx((select id from c where name='admin2'), (select id from c where name='owner'), 'suspend'), 'suspended', 'owner suspends admin');
select is(public.set_account_status_tx((select id from c where name='tutor2'), (select id from c where name='tutor'), 'suspend'), 'forbidden', 'suspended tutor cannot act');
select is(public.set_account_status_tx((select id from c where name='s_uncf'), (select id from c where name='admin'), 'suspend'), 'suspended', 'student suspended');
update public.profiles set status = 'unconfirmed' where id = (select id from c where name='s_none');
select is(public.set_account_status_tx((select id from c where name='s_none'), (select id from c where name='admin'), 'suspend'), 'conflict', 'unconfirmed cannot be suspended');
select is(public.set_account_status_tx(gen_random_uuid(), (select id from c where name='admin'), 'suspend'), 'not_found', 'unknown target -> not_found');

-- Reactivate destinations.
select is(public.set_account_status_tx((select id from c where name='tutor'), (select id from c where name='admin'), 'reactivate'), 'active', 'tutor reactivated to active');
select is((select count(*)::int from public.audit_log where action='account_reactivated' and target_id=(select id from c where name='tutor')), 1, 'reactivate audited');
select is(public.set_account_status_tx((select id from c where name='tutor'), (select id from c where name='admin'), 'reactivate'), 'conflict', 'reactivating active -> conflict');
insert into public.student_subjects (student_id, subject_id) values ((select id from c where name='s_subj'), (select id from public.subjects limit 1));
update public.student_details set index_number = 'SE-2099-9001' where profile_id = (select id from c where name='s_subj');
update public.student_details set index_number = 'SE-2099-9002' where profile_id = (select id from c where name='s_idx');
update public.profiles set status = 'suspended' where id in (select id from c where name in ('s_subj','s_idx','s_none'));
select is(public.set_account_status_tx((select id from c where name='s_subj'), (select id from c where name='admin'), 'reactivate'), 'active', 'student with subjects -> active');
select is(public.set_account_status_tx((select id from c where name='s_idx'), (select id from c where name='admin'), 'reactivate'), 'profile_incomplete', 'student with index, no subjects -> profile_incomplete');
select is(public.set_account_status_tx((select id from c where name='s_none'), (select id from c where name='admin'), 'reactivate'), 'pending', 'student without index -> pending');

-- remove_staff_tx.
select is(public.remove_staff_tx((select id from c where name='s_subj'), (select id from c where name='admin')), 'conflict', 'cannot remove a student');
select is(public.remove_staff_tx((select id from c where name='parent'), (select id from c where name='admin')), 'conflict', 'cannot remove a parent');
select is(public.remove_staff_tx((select id from c where name='owner'), (select id from c where name='admin')), 'forbidden', 'cannot remove the owner');
select is(public.remove_staff_tx((select id from c where name='owner'), (select id from c where name='owner')), 'forbidden', 'owner cannot remove self');
select is(public.remove_staff_tx((select id from c where name='admin2'), (select id from c where name='admin')), 'forbidden', 'admin cannot remove admin');
select is(public.remove_staff_tx((select id from c where name='tutor2'), (select id from c where name='admin')), 'removed', 'admin removes tutor');
select is((select count(*)::int from auth.users where id = (select id from c where name='tutor2')), 0, 'auth user deleted');
select is((select count(*)::int from public.audit_log where action='staff_removed' and target_type='profile'
  and target_id=(select id from c where name='tutor2') and actor_id=(select id from c where name='admin')), 1, 'staff_removed audited');
select is(public.remove_staff_tx((select id from c where name='admin2'), (select id from c where name='owner')), 'removed', 'owner removes admin');
select is(public.remove_staff_tx(gen_random_uuid(), (select id from c where name='owner')), 'not_found', 'remove unknown -> not_found');

-- clear_invite_tx.
insert into public.pending_invites (email, role) values
  ('ci.parent@example.com', 'parent'), ('ci.tutor@example.com', 'tutor'), ('ci.real@example.com', 'parent');
insert into c select n, tests.create_user('student', 'pending') from unnest(array['shell','real','tshell']) n;
update public.profiles set email = 'ci.parent@example.com' where id = (select id from c where name='shell');
update public.profiles set email = 'ci.real@example.com' where id = (select id from c where name='real');
update public.profiles set email = 'ci.tutor@example.com' where id = (select id from c where name='tshell');
update auth.users set raw_app_meta_data = jsonb_build_object('invite_token', (select token::text from public.pending_invites where email='ci.parent@example.com'))
  where id = (select id from c where name='shell');
update auth.users set raw_app_meta_data = jsonb_build_object('invite_token', (select token::text from public.pending_invites where email='ci.tutor@example.com'))
  where id = (select id from c where name='tshell');
-- 'real' is a genuine sign-up carrying the invite's token, with parent details and an index: never deleted.
update auth.users set raw_app_meta_data = jsonb_build_object('invite_token', (select token::text from public.pending_invites where email='ci.real@example.com'))
  where id = (select id from c where name='real');
update public.student_details set signup_parent_email = 'p@example.com', index_number = 'SE-2099-9003' where profile_id = (select id from c where name='real');

select is(public.clear_invite_tx('ci.tutor@example.com', (select id from c where name='admin')), 'forbidden', 'admin cannot clear a staff invite');
select is((select count(*)::int from public.pending_invites where email='ci.tutor@example.com'), 1, 'staff invite kept after refusal');
select is(public.clear_invite_tx('CI.Parent@example.com ', (select id from c where name='admin')), 'cleared', 'admin clears a parent invite');
select is((select count(*)::int from public.pending_invites where email='ci.parent@example.com') + (select count(*)::int from auth.users where id=(select id from c where name='shell')), 0, 'invite and token-bearing shell gone');
select is(public.clear_invite_tx('ci.real@example.com', (select id from c where name='admin')), 'cleared', 'invite cleared for the real-student email');
select is((select count(*)::int from auth.users where id=(select id from c where name='real')), 1, 'genuine student with the same email untouched');
select is(public.clear_invite_tx('ci.tutor@example.com', (select id from c where name='owner')), 'cleared', 'owner clears a staff invite');
select is((select count(*)::int from auth.users where id=(select id from c where name='tshell')), 0, 'staff shell removed');
select is((select count(*)::int from public.audit_log where action='invite_cleared' and created_at = now() and target_id is null and target_type is null), 3, 'invite_cleared audited without target');
select is(public.clear_invite_tx('ci.none@example.com', (select id from c where name='owner')), 'not_found', 'no invite -> not_found');

-- delete_own_account_tx.
select is(public.delete_own_account_tx((select id from c where name='tutor')), 'forbidden', 'staff cannot self-delete');
select is(public.delete_own_account_tx((select id from c where name='parent')), 'deleted', 'parent deletes self');
select is((select count(*)::int from auth.users where id=(select id from c where name='parent')), 0, 'parent auth user gone');
select is((select count(*)::int from public.audit_log where action='account_self_deleted' and created_at = now() and actor_id is null and target_id is null and target_type is null), 1, 'self-deletion audited with no actor or target');
select is(public.delete_own_account_tx((select id from c where name='parent')), 'not_found', 'second delete -> not_found');

select * from finish();
rollback;
