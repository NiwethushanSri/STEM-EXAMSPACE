begin;
create extension if not exists pgtap with schema extensions;
select plan(50);

-- Privileges.
select is(has_function_privilege('authenticated', 'public.claim_invite(uuid,uuid,text,public.app_role)', 'execute'), false, 'claim_invite not executable by authenticated');
select is(has_function_privilege('anon', 'public.claim_invite(uuid,uuid,text,public.app_role)', 'execute'), false, 'claim_invite not executable by anon');
select is(has_function_privilege('service_role', 'public.claim_invite(uuid,uuid,text,public.app_role)', 'execute'), true, 'claim_invite executable by service_role');
select is(has_function_privilege('authenticated', 'public.claim_parent_invite(uuid,uuid,text)', 'execute'), false, 'claim_parent_invite not executable by authenticated');
select is(has_function_privilege('authenticated', 'public.link_children_to_parent(uuid)', 'execute'), false, 'link_children_to_parent not executable by authenticated');
select is(has_function_privilege('anon', 'public.link_children_to_parent(uuid)', 'execute'), false, 'link_children_to_parent not executable by anon');
select is(has_function_privilege('service_role', 'public.link_children_to_parent(uuid)', 'execute'), true, 'link_children_to_parent executable by service_role');

-- Shells for tutor / admin / owner invites.
insert into public.pending_invites (email, role) values
  ('inv.tutor@example.com', 'tutor'), ('inv.admin@example.com', 'admin'), ('inv.owner@example.com', 'owner'),
  ('inv.parent@example.com', 'parent'), ('inv.real@example.com', 'tutor');
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c select n, tests.create_user('student', 'pending') from unnest(array['tutor','admin','owner','parentshell','real','wrongmail']) n;
update public.profiles set email = 'inv.tutor@example.com' where id = (select id from c where name = 'tutor');
update public.profiles set email = 'inv.admin@example.com' where id = (select id from c where name = 'admin');
update public.profiles set email = 'inv.owner@example.com' where id = (select id from c where name = 'owner');
update public.profiles set email = 'inv.parent@example.com' where id = (select id from c where name = 'parentshell');
update public.profiles set email = 'inv.real@example.com' where id = (select id from c where name = 'real');
update public.profiles set email = 'inv.wrong@example.com' where id = (select id from c where name = 'wrongmail');
update auth.users set raw_app_meta_data = jsonb_build_object('invite_token', (select token::text from public.pending_invites where email = 'inv.tutor@example.com'))
  where id = (select id from c where name = 'tutor');
update auth.users set raw_app_meta_data = jsonb_build_object('invite_token', (select token::text from public.pending_invites where email = 'inv.admin@example.com'))
  where id = (select id from c where name = 'admin');
update auth.users set raw_app_meta_data = jsonb_build_object('invite_token', (select token::text from public.pending_invites where email = 'inv.owner@example.com'))
  where id = (select id from c where name = 'owner');
update auth.users set raw_app_meta_data = jsonb_build_object('invite_token', (select token::text from public.pending_invites where email = 'inv.parent@example.com'))
  where id = (select id from c where name = 'parentshell');
update auth.users set raw_app_meta_data = jsonb_build_object('invite_token', (select token::text from public.pending_invites where email = 'inv.real@example.com'))
  where id = (select id from c where name = 'real');
update auth.users set raw_app_meta_data = jsonb_build_object('invite_token', (select token::text from public.pending_invites where email = 'inv.tutor@example.com'))
  where id = (select id from c where name = 'wrongmail');
-- 'real' is a genuine pending student (has sign-up data).
update public.student_details set signup_parent_email = 'p@example.com', signup_parent_name = 'P' where profile_id = (select id from c where name = 'real');

select is(public.claim_invite((select id from c where name = 'tutor'),
  (select token from public.pending_invites where email = 'inv.tutor@example.com'), 'Inv.Tutor@example.com ', 'tutor'), 'claimed', 'tutor shell claimed');
select results_eq(format($q$select role::text, status::text from public.profiles where id = %L$q$, (select id from c where name = 'tutor')),
  $q$values ('tutor', 'active')$q$, 'claimed profile is an active tutor');
select is((select count(*)::int from public.student_details where profile_id = (select id from c where name = 'tutor')), 0, 'student_details removed');
select is((select count(*)::int from public.pending_invites where email = 'inv.tutor@example.com'), 0, 'invite consumed');

select is(public.claim_invite((select id from c where name = 'admin'),
  (select token from public.pending_invites where email = 'inv.admin@example.com'), 'inv.admin@example.com', 'admin'), 'claimed', 'admin shell claimed');
select is((select role::text from public.profiles where id = (select id from c where name = 'admin')), 'admin', 'claimed profile is admin');
select is(public.claim_invite((select id from c where name = 'owner'),
  (select token from public.pending_invites where email = 'inv.owner@example.com'), 'inv.owner@example.com', 'owner'), 'claimed', 'owner shell claimed');
select is((select role::text from public.profiles where id = (select id from c where name = 'owner')), 'owner', 'claimed profile is owner');

select is(public.claim_invite((select id from c where name = 'real'),
  (select token from public.pending_invites where email = 'inv.real@example.com'), 'inv.real@example.com', 'tutor'), 'refused',
  'genuine pending student refused even with the right token');
select is((select role::text from public.profiles where id = (select id from c where name = 'real')), 'student', 'genuine student unchanged');
select is(public.claim_invite((select id from c where name = 'wrongmail'), gen_random_uuid(), 'inv.wrong@example.com', 'tutor'), 'refused',
  'token of another email refused');
select is(public.claim_invite((select id from c where name = 'parentshell'), gen_random_uuid(), 'inv.parent@example.com', 'parent'), 'refused', 'wrong token refused');

-- 'already' semantics.
select is(public.claim_invite((select id from c where name = 'tutor'), gen_random_uuid(), 'inv.tutor@example.com', 'tutor'), 'already', 'claimed tutor again: already');
select is(public.claim_invite((select id from c where name = 'tutor'), gen_random_uuid(), 'someone.else@example.com', 'tutor'), 'refused', 'already-claimed with another email refused');
insert into public.pending_invites (email, role) values ('inv.other@example.com', 'owner');
select is(public.claim_invite((select id from c where name = 'tutor'),
  (select token from public.pending_invites where email = 'inv.other@example.com'), 'inv.tutor@example.com', 'tutor'), 'refused',
  'already-claimed whose role differs from a live invite is refused');

-- claim_parent_invite wrapper only accepts parent invites.
select is(public.claim_parent_invite((select id from c where name = 'parentshell'),
  (select token from public.pending_invites where email = 'inv.parent@example.com'), 'inv.parent@example.com'), 'claimed', 'parent wrapper claims parent invite');
select is(public.claim_parent_invite((select id from c where name = 'admin'), gen_random_uuid(), 'inv.admin@example.com'), 'refused', 'parent wrapper refuses an admin');

-- link_children_to_parent: a, b, c, d approved with the parent email; e has it but is not approved; f other email.
create temp table s (name text primary key, id uuid not null);
grant select on s to public;
insert into s select n, tests.create_user('student', 'active') from unnest(array['a','b','c','d','e','f']) n;
update public.student_details set index_number = 'SE-2099-0001', signup_parent_email = 'inv.parent@example.com' where profile_id = (select id from s where name = 'a');
update public.student_details set index_number = 'SE-2099-0002', signup_parent_email = '  Inv.Parent@Example.com ' where profile_id = (select id from s where name = 'b');
update public.student_details set index_number = 'SE-2099-0003', signup_parent_email = 'inv.parent@example.com' where profile_id = (select id from s where name = 'c');
update public.student_details set index_number = 'SE-2099-0004', signup_parent_email = 'inv.parent@example.com' where profile_id = (select id from s where name = 'd');
update public.student_details set signup_parent_email = 'inv.parent@example.com' where profile_id = (select id from s where name = 'e');
update public.student_details set index_number = 'SE-2099-0006', signup_parent_email = 'other.parent@example.com' where profile_id = (select id from s where name = 'f');
-- c already has another parent; d is already linked to this parent.
insert into public.parent_children (parent_id, student_id) values
  ((select id from c where name = 'admin'), (select id from s where name = 'c')),
  ((select id from c where name = 'parentshell'), (select id from s where name = 'd'));
select is(public.link_children_to_parent((select id from c where name = 'parentshell')), 2, 'links the two unlinked approved students (case/space-insensitive)');
select is(public.link_children_to_parent((select id from c where name = 'parentshell')), 0, 'second run links nothing');
select is((select count(*)::int from public.parent_children where parent_id = (select id from c where name = 'parentshell')), 3, 'parent now has a, b and d');
select is((select count(*)::int from public.parent_children where student_id = (select id from s where name = 'c')), 1, 'student with another parent is not double-linked');
select is((select count(*)::int from public.parent_children where student_id in (select id from s where name in ('e', 'f'))), 0, 'unapproved or other-email students not linked');
select is(public.link_children_to_parent((select id from c where name = 'tutor')), 0, 'non-parent target links nothing');


-- Role binding: the invite's role must equal p_role.
insert into public.pending_invites (email, role) values ('inv.mismatch@example.com', 'tutor'), ('inv.old@example.com', 'tutor');
insert into c select n, tests.create_user('student', 'pending') from unnest(array['mismatch','old']) n;
update public.profiles set email = 'inv.mismatch@example.com' where id = (select id from c where name = 'mismatch');
update public.profiles set email = 'inv.old@example.com' where id = (select id from c where name = 'old');
update auth.users set raw_app_meta_data = jsonb_build_object('invite_token', (select token::text from public.pending_invites where email = 'inv.mismatch@example.com'))
  where id = (select id from c where name = 'mismatch');
update auth.users set raw_app_meta_data = jsonb_build_object('invite_token', (select token::text from public.pending_invites where email = 'inv.old@example.com')),
  created_at = now() - interval '25 hours' where id = (select id from c where name = 'old');
select is(public.claim_invite((select id from c where name = 'mismatch'),
  (select token from public.pending_invites where email = 'inv.mismatch@example.com'), 'inv.mismatch@example.com', 'admin'), 'refused', 'tutor invite refused for p_role admin');
select is(public.claim_invite((select id from c where name = 'mismatch'),
  (select token from public.pending_invites where email = 'inv.mismatch@example.com'), 'inv.mismatch@example.com', 'student'), 'refused', 'student role refused');
select is((select role::text from public.profiles where id = (select id from c where name = 'mismatch')), 'student', 'mismatched claim changed nothing');
select is(public.claim_invite((select id from c where name = 'old'),
  (select token from public.pending_invites where email = 'inv.old@example.com'), 'inv.old@example.com', 'tutor'), 'refused', 'shell older than 24 hours refused');
select is(public.claim_invite((select id from c where name = 'tutor'), gen_random_uuid(), 'inv.tutor@example.com', 'admin'), 'refused', 'already only for the same role');

-- Single owner.
select throws_ok($q$update public.profiles set role = 'owner' where id = (select id from c where name = 'tutor')$q$, '23505', null, 'second owner rejected');

-- link_children_to_parent also skips non-approved statuses and inactive parents.
insert into s select n, tests.create_user('student', 'pending') from unnest(array['g','h']) n;
update public.student_details set index_number = 'SE-2099-0007', signup_parent_email = 'inv.parent@example.com' where profile_id = (select id from s where name = 'g');
update public.student_details set index_number = 'SE-2099-0008', signup_parent_email = 'inv.parent@example.com' where profile_id = (select id from s where name = 'h');
update public.profiles set status = 'suspended' where id = (select id from s where name = 'h');
select is(public.link_children_to_parent((select id from c where name = 'parentshell')), 0, 'pending and suspended students with an index are not linked');
update public.profiles set status = 'suspended' where id = (select id from c where name = 'parentshell');
update public.profiles set status = 'active' where id = (select id from s where name = 'g');
select is(public.link_children_to_parent((select id from c where name = 'parentshell')), 0, 'suspended parent is not linked to anyone');
select is(public.link_student_to_parent((select id from c where name = 'parentshell'), (select id from s where name = 'g')), 'parent_inactive', 'link_student_to_parent: inactive parent');
update public.profiles set status = 'active' where id = (select id from c where name = 'parentshell');
select is(public.link_student_to_parent((select id from c where name = 'parentshell'), (select id from s where name = 'g')), 'linked', 'link_student_to_parent: linked');
select is(public.link_student_to_parent((select id from c where name = 'parentshell'), (select id from s where name = 'g')), 'exists', 'link_student_to_parent: exists');

-- Link blocks: a staff delete creates one, automatic linking skips it, a staff re-insert clears it.
select is(has_table_privilege('authenticated', 'public.parent_link_blocks', 'insert'), false, 'authenticated cannot insert blocks');
select is(has_table_privilege('authenticated', 'public.parent_link_blocks', 'delete'), false, 'authenticated cannot delete blocks');
select is(has_table_privilege('anon', 'public.parent_link_blocks', 'select'), false, 'anon cannot read blocks');
select is(has_function_privilege('authenticated', 'public.link_student_to_parent(uuid,uuid)', 'execute'), false, 'link_student_to_parent not executable by authenticated');
insert into c values ('staff', tests.create_user('admin', 'active'));
select tests.as_user((select id from c where name = 'staff'));
delete from public.parent_children where parent_id = (select id from c where name = 'parentshell') and student_id = (select id from s where name = 'a');
select is((select count(*)::int from public.parent_link_blocks), 1, 'staff delete creates a block (visible to staff)');
select tests.as_postgres();
select is(public.link_children_to_parent((select id from c where name = 'parentshell')), 0, 'reconciliation skips the blocked pair');
select is(public.link_student_to_parent((select id from c where name = 'parentshell'), (select id from s where name = 'a')), 'blocked', 'link_student_to_parent skips the blocked pair');
-- A delete without an authenticated session (service role / postgres) creates no block.
delete from public.parent_children where parent_id = (select id from c where name = 'parentshell') and student_id = (select id from s where name = 'b');
select is((select count(*)::int from public.parent_link_blocks), 1, 'non-staff delete creates no block');
select tests.as_user((select id from c where name = 'staff'));
insert into public.parent_children (parent_id, student_id) values ((select id from c where name = 'parentshell'), (select id from s where name = 'a'));
select is((select count(*)::int from public.parent_link_blocks), 0, 'explicit staff re-insert clears the block');
select tests.as_postgres();

select * from finish();
rollback;
