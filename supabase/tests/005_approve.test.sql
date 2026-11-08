begin;
create extension if not exists pgtap with schema extensions;
select plan(51);

-- The dev project's counters persist between function-test runs; clear them inside this transaction (rolled back).
delete from public.index_counters;

create temp table u (name text primary key, id uuid not null);
insert into u values
  ('s1',      tests.create_user('student', 'pending')),
  ('s2',      tests.create_user('student', 'pending')),
  ('s3',      tests.create_user('student', 'pending')),
  ('s4',      tests.create_user('student', 'pending')),
  ('s5',      tests.create_user('student', 'pending')),
  ('s6',      tests.create_user('student', 'pending')),
  ('s7',      tests.create_user('student', 'pending')),
  ('s8',      tests.create_user('student', 'pending')),
  ('s9',      tests.create_user('student', 'pending')),
  ('active',  tests.create_user('student', 'active')),
  ('parent',  tests.create_user('parent', 'active')),
  ('tutor',   tests.create_user('tutor', 'active')),
  ('admin',   tests.create_user('admin', 'active'));
grant select on u to public;

update public.profiles set email = 'nimal.perera@example.com' where id = (select id from u where name = 'parent');
update public.profiles set email = 'staff.tutor@example.com' where id = (select id from u where name = 'tutor');

update public.student_details set signup_parent_name = 'Kamal Perera', signup_parent_email = 'new.parent@example.com'
  where profile_id = (select id from u where name = 's1');
update public.student_details set signup_parent_email = 'new.parent@example.com'
  where profile_id in (select id from u where name in ('s2', 's3', 's6', 's8'));
update public.student_details set signup_parent_email = 'nimal.perera@example.com'
  where profile_id = (select id from u where name = 's4');
update public.student_details set signup_parent_email = ' Nimal.Perera@Example.com '
  where profile_id = (select id from u where name = 's5');
update public.student_details set signup_parent_email = 'staff.tutor@example.com'
  where profile_id = (select id from u where name = 's7');

-- Privileges.
select is(has_table_privilege('authenticated', 'public.index_counters', 'select'), false, 'index_counters_not_readable_by_authenticated: select');
select is(has_table_privilege('anon', 'public.index_counters', 'insert'), false, 'index_counters_not_readable_by_authenticated: anon insert');
select is(has_function_privilege('authenticated', 'public.approve_student_tx(uuid,uuid,int)', 'execute'), false, 'approve_tx_not_executable_by_authenticated');
select is(has_function_privilege('anon', 'public.approve_student_tx(uuid,uuid,int)', 'execute'), false, 'approve_tx_not_executable_by_anon');
select is(has_function_privilege('service_role', 'public.approve_student_tx(uuid,uuid,int)', 'execute'), true, 'approve_tx executable by service_role');

-- Happy path with a brand-new parent email.
select results_eq(
  format($q$select index_number, parent_id is null, parent_email, invite_token is not null from public.approve_student_tx(%L, %L, 2026)$q$,
    (select id from u where name = 's1'), (select id from u where name = 'admin')),
  $q$values ('SE-2026-0001'::text, true, 'new.parent@example.com'::text, true)$q$,
  'approve_assigns_index_and_status: returns index, no parent id, parent email, token');
select is((select status::text from public.profiles where id = (select id from u where name = 's1')), 'profile_incomplete',
  'approve_assigns_index_and_status: status profile_incomplete');
select is((select index_number from public.student_details where profile_id = (select id from u where name = 's1')), 'SE-2026-0001',
  'approve_assigns_index_and_status: index stored');
select results_eq($q$select role::text from public.pending_invites where email = 'new.parent@example.com'$q$, $q$values ('parent')$q$,
  'approve_new_parent_returns_token: parent invite row exists');
select is((select invited_by from public.pending_invites where email = 'new.parent@example.com'), (select id from u where name = 'admin'),
  'approve_new_parent_returns_token: invited_by is the actor');
select is((select count(*)::int from public.audit_log where action = 'student_approved' and target_type = 'student'
  and target_id = (select id from u where name = 's1') and actor_id = (select id from u where name = 'admin')), 1,
  'approve writes student_approved audit row');

-- Same sequence, second student, same parent email: existing invite is reused (same token).
select results_eq(
  format($q$select index_number, parent_id is null, invite_token = (select token from public.pending_invites where email = 'new.parent@example.com') from public.approve_student_tx(%L, %L, 2026)$q$,
    (select id from u where name = 's2'), (select id from u where name = 'admin')),
  $q$values ('SE-2026-0002'::text, true, true)$q$,
  'index_sequence_restarts_each_year: second 2026 approval is 0002 and reuses the invite');
select is((select count(*)::int from public.pending_invites where email = 'new.parent@example.com'), 1, 'only one invite row per email');
select is((select index_number from public.approve_student_tx((select id from u where name = 's3'), (select id from u where name = 'admin'), 2027)),
  'SE-2027-0001', 'index_sequence_restarts_each_year: 2027 restarts at 0001');

-- Existing parent, exact and messy email.
select results_eq(
  format($q$select index_number is not null, parent_id = %L, invite_token is null from public.approve_student_tx(%L, %L, 2026)$q$,
    (select id from u where name = 'parent'), (select id from u where name = 's4'), (select id from u where name = 'admin')),
  $q$values (true, true, true)$q$, 'approve_links_existing_parent: returns parent id, no token');
select is((select count(*)::int from public.parent_children where parent_id = (select id from u where name = 'parent')
  and student_id = (select id from u where name = 's4')), 1, 'approve_links_existing_parent: link row exists');
select results_eq(
  format($q$select parent_id = %L, invite_token is null from public.approve_student_tx(%L, %L, 2026)$q$,
    (select id from u where name = 'parent'), (select id from u where name = 's5'), (select id from u where name = 'admin')),
  $q$values (true, true)$q$, 'approve_matches_parent_email_case_insensitively: padded mixed-case email matches');
select is((select count(*)::int from public.parent_children where parent_id = (select id from u where name = 'parent')
  and student_id = (select id from u where name = 's5')), 1, 'approve_matches_parent_email_case_insensitively: link row exists');

-- Rejections.
select throws_ok(
  format($q$select * from public.approve_student_tx(%L, %L, 2026)$q$, (select id from u where name = 's7'), (select id from u where name = 'admin')),
  'P0001', 'parent_email_is_staff', 'approve_rejects_staff_parent_email');
select is((select status::text from public.profiles where id = (select id from u where name = 's7')), 'pending',
  'staff-email failure leaves student pending');
select throws_ok(
  format($q$select * from public.approve_student_tx(%L, %L, 2026)$q$, (select id from u where name = 's1'), (select id from u where name = 'admin')),
  'P0001', 'conflict', 'approve_twice_conflicts');
select throws_ok(
  format($q$select * from public.approve_student_tx(%L, %L, 2026)$q$, (select id from u where name = 'active'), (select id from u where name = 'admin')),
  'P0001', 'conflict', 'approve_non_student_conflicts: active student');
select throws_ok(
  format($q$select * from public.approve_student_tx(%L, %L, 2026)$q$, (select id from u where name = 'tutor'), (select id from u where name = 'admin')),
  'P0001', 'conflict', 'approve_non_student_conflicts: tutor');
select throws_ok(
  format($q$select * from public.approve_student_tx(%L, %L, 2026)$q$, gen_random_uuid(), (select id from u where name = 'admin')),
  'P0001', 'conflict', 'unknown student conflicts');

update public.student_details set signup_parent_email = '   ' where profile_id = (select id from u where name = 's6');
select throws_ok(
  format($q$select * from public.approve_student_tx(%L, %L, 2026)$q$, (select id from u where name = 's6'), (select id from u where name = 'admin')),
  'P0001', 'invalid_input', 'blank parent email is invalid_input');
select is((select status::text from public.profiles where id = (select id from u where name = 's6')), 'pending', 'invalid_input leaves student pending');

-- Behaviour as authenticated: cannot call or read.
select tests.as_user((select id from u where name = 'admin'));
select throws_ok(
  format($q$select * from public.approve_student_tx(%L, %L, 2026)$q$, (select id from u where name = 's6'), (select id from u where name = 'admin')),
  '42501', null, 'approve_tx_not_executable_by_authenticated: call is denied');
select throws_ok($q$select * from public.index_counters$q$, '42501', null, 'index_counters_not_readable_by_authenticated: select denied');
select tests.as_postgres();
select is((select count(*)::int from public.index_counters), 2, 'counters rows for 2026 and 2027 only');

-- claim_invite (parent) is bound to the user created for that invite (token in app_metadata, fresh, bare shell).
select is(has_function_privilege('authenticated', 'public.claim_invite(uuid,uuid,text,public.app_role)', 'execute'), false, 'claim_invite not executable by authenticated');
select is(has_function_privilege('service_role', 'public.claim_invite(uuid,uuid,text,public.app_role)', 'execute'), true, 'claim_invite executable by service_role');
insert into public.pending_invites (email, role) values
  ('claim.me@example.com', 'parent'), ('claim.g@example.com', 'parent'),
  ('claim.o@example.com', 'parent'), ('claim.tutor@example.com', 'tutor');
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c select n, tests.create_user('student', 'pending') from unnest(array['p','g','o','t']) n;
update public.profiles set email = 'claim.me@example.com' where id = (select id from c where name = 'p');
update public.profiles set email = 'claim.g@example.com' where id = (select id from c where name = 'g');
update public.profiles set email = 'claim.o@example.com' where id = (select id from c where name = 'o');
update public.profiles set email = 'claim.tutor@example.com' where id = (select id from c where name = 't');
update auth.users set raw_app_meta_data = jsonb_build_object('invite_token', (select token::text from public.pending_invites where email = 'claim.me@example.com'))
  where id = (select id from c where name = 'p');
update auth.users set raw_app_meta_data = jsonb_build_object('invite_token', (select token::text from public.pending_invites where email = 'claim.g@example.com'))
  where id = (select id from c where name = 'g');
update auth.users set raw_app_meta_data = jsonb_build_object('invite_token', (select token::text from public.pending_invites where email = 'claim.o@example.com')),
  created_at = now() - interval '48 hours' where id = (select id from c where name = 'o');
update auth.users set raw_app_meta_data = jsonb_build_object('invite_token', (select token::text from public.pending_invites where email = 'claim.tutor@example.com'))
  where id = (select id from c where name = 't');
update public.student_details set signup_parent_email = 'x@example.com', signup_parent_name = 'X' where profile_id = (select id from c where name = 'g');

select is(public.claim_invite((select id from c where name = 'g'),
  (select token from public.pending_invites where email = 'claim.g@example.com'), 'claim.g@example.com', 'parent'), 'refused',
  'genuine pending student (signup data) is refused even with the correct token');
select is(public.claim_invite((select id from c where name = 'p'), gen_random_uuid(), 'claim.me@example.com', 'parent'), 'refused', 'claim with wrong token refused');
select is(public.claim_invite((select id from c where name = 'o'),
  (select token from public.pending_invites where email = 'claim.o@example.com'), 'claim.o@example.com', 'parent'), 'refused', 'claim for a user older than 24 hours refused');
select is(public.claim_invite((select id from c where name = 't'),
  (select token from public.pending_invites where email = 'claim.tutor@example.com'), 'claim.tutor@example.com', 'parent'), 'refused', 'claim of a non-parent invite refused');
select is(public.claim_invite((select id from u where name = 's1'),
  (select token from public.pending_invites where email = 'new.parent@example.com'), 'x@example.com', 'parent'), 'refused', 'approved student cannot be claimed as parent');
select is(public.claim_invite((select id from c where name = 'p'),
  (select token from public.pending_invites where email = 'claim.me@example.com'), 'Claim.Me@example.com ', 'parent'), 'claimed', 'user with matching app_metadata token is claimed');
select results_eq(format($q$select role::text, status::text from public.profiles where id = %L$q$, (select id from c where name = 'p')),
  $q$values ('parent', 'active')$q$, 'claimed profile is an active parent');
select is(public.claim_invite((select id from c where name = 'p'), gen_random_uuid(), 'claim.me@example.com', 'parent'), 'already', 'second claim on an already-claimed parent returns already');

select is(public.claim_invite((select id from c where name = 'p'), gen_random_uuid(), 'other@example.com', 'parent'), 'refused',
  'already-parent with a different email is refused');

-- Crash-orphan shell: tx reuses the existing invite token; genuine students still raise.
insert into public.pending_invites (email, role) values ('orphan.parent@example.com', 'parent');
create temp table o (name text primary key, id uuid not null);
grant select on o to public;
insert into o select 'shell', tests.create_user('student', 'pending');
insert into o select 'real', tests.create_user('student', 'pending');
update public.profiles set email = 'orphan.parent@example.com' where id = (select id from o where name = 'shell');
update auth.users set raw_app_meta_data = jsonb_build_object('invite_token', (select token::text from public.pending_invites where email = 'orphan.parent@example.com'))
  where id = (select id from o where name = 'shell');
insert into u values ('s10', tests.create_user('student', 'pending')), ('s11', tests.create_user('student', 'pending'));
update public.student_details set signup_parent_email = 'orphan.parent@example.com' where profile_id = (select id from u where name = 's10');
select results_eq(
  format($q$select parent_id is null, invite_token = (select token from public.pending_invites where email = 'orphan.parent@example.com') from public.approve_student_tx(%L, %L, 2026)$q$,
    (select id from u where name = 's10'), (select id from u where name = 'admin')),
  $q$values (true, true)$q$, 'tx returns the existing token for a token-bearing shell');
select is((select count(*)::int from public.pending_invites where email = 'orphan.parent@example.com'), 1, 'no second invite for the shell');
select is(public.claim_invite((select id from o where name = 'shell'),
  (select token from public.pending_invites where email = 'orphan.parent@example.com'), 'orphan.parent@example.com', 'parent'), 'claimed', 'shell is then claimed');
update public.profiles set email = 'real.student@example.com' where id = (select id from o where name = 'real');
update public.student_details set signup_parent_email = 'real.student@example.com' where profile_id = (select id from u where name = 's11');
-- A parent invite exists for that email and the student carries a wrong invite_token: still not a shell.
insert into public.pending_invites (email, role) values ('real.student@example.com', 'parent');
update auth.users set raw_app_meta_data = jsonb_build_object('invite_token', gen_random_uuid()::text) where id = (select id from o where name = 'real');
select throws_ok(
  format($q$select * from public.approve_student_tx(%L, %L, 2026)$q$, (select id from u where name = 's11'), (select id from u where name = 'admin')),
  'P0001', 'parent_email_is_staff', 'genuine student with that email still raises parent_email_is_staff');

-- Index numbers pad to at least 4 digits and never truncate.
insert into public.index_counters values (2030, 9999);
select is((select index_number from public.approve_student_tx((select id from u where name = 's8'), (select id from u where name = 'admin'), 2030)),
  'SE-2030-10000', 'index_number_not_truncated_past_9999');

-- A student account as the parent email gets the same code.
update public.student_details set signup_parent_email = (select email::text from public.profiles where id = (select id from u where name = 'active'))
  where profile_id = (select id from u where name = 's9');
select throws_ok(
  format($q$select * from public.approve_student_tx(%L, %L, 2026)$q$, (select id from u where name = 's9'), (select id from u where name = 'admin')),
  'P0001', 'parent_email_is_staff', 'student account as parent email is rejected');


-- Existing parent that is suspended, or a deliberately unlinked pair: approval does not link.
insert into u values ('sp1', tests.create_user('parent', 'suspended')), ('bp1', tests.create_user('parent', 'active')),
  ('s12', tests.create_user('student', 'pending')), ('s13', tests.create_user('student', 'pending'));
update public.profiles set email = 'susp.parent@example.com' where id = (select id from u where name = 'sp1');
update public.profiles set email = 'blocked.parent@example.com' where id = (select id from u where name = 'bp1');
update public.student_details set signup_parent_email = 'susp.parent@example.com' where profile_id = (select id from u where name = 's12');
update public.student_details set signup_parent_email = 'blocked.parent@example.com' where profile_id = (select id from u where name = 's13');
insert into public.parent_link_blocks (parent_id, student_id) values ((select id from u where name = 'bp1'), (select id from u where name = 's13'));
select lives_ok(format($q$select * from public.approve_student_tx(%L, %L, 2026)$q$, (select id from u where name = 's12'), (select id from u where name = 'admin')),
  'approval with a suspended existing parent succeeds');
select is((select count(*)::int from public.parent_children where student_id = (select id from u where name = 's12')), 0, 'suspended parent is not linked');
select lives_ok(format($q$select * from public.approve_student_tx(%L, %L, 2026)$q$, (select id from u where name = 's13'), (select id from u where name = 'admin')),
  'approval with a blocked pair succeeds');
select is((select count(*)::int from public.parent_children where student_id = (select id from u where name = 's13')), 0, 'blocked pair is not linked');

-- A token-bearing parent shell older than 24 hours is not reused.
insert into public.pending_invites (email, role) values ('stale.parent@example.com', 'parent');
insert into u values ('stale', tests.create_user('student', 'pending')), ('s14', tests.create_user('student', 'pending'));
update public.profiles set email = 'stale.parent@example.com' where id = (select id from u where name = 'stale');
update auth.users set raw_app_meta_data = jsonb_build_object('invite_token', (select token::text from public.pending_invites where email = 'stale.parent@example.com')),
  created_at = now() - interval '25 hours' where id = (select id from u where name = 'stale');
update public.student_details set signup_parent_email = 'stale.parent@example.com' where profile_id = (select id from u where name = 's14');
select throws_ok(
  format($q$select * from public.approve_student_tx(%L, %L, 2026)$q$, (select id from u where name = 's14'), (select id from u where name = 'admin')),
  'P0001', 'parent_email_is_staff', 'stale token-bearing shell is refused');

select * from finish();
rollback;
