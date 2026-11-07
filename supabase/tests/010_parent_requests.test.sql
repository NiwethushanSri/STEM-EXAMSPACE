begin;
create extension if not exists pgtap with schema extensions;
select plan(52);
select tests.assert_no_owner();

-- Privileges: service_role only.
select is(has_function_privilege('service_role', 'public.request_parent_link_tx(uuid,text,date)', 'execute'), true, 'request: service_role');
select is(has_function_privilege('authenticated', 'public.request_parent_link_tx(uuid,text,date)', 'execute'), false, 'request: not authenticated');
select is(has_function_privilege('anon', 'public.request_parent_link_tx(uuid,text,date)', 'execute'), false, 'request: not anon');
select is(has_function_privilege('service_role', 'public.decide_parent_link_tx(uuid,uuid,boolean)', 'execute'), true, 'decide: service_role');
select is(has_function_privilege('authenticated', 'public.decide_parent_link_tx(uuid,uuid,boolean)', 'execute'), false, 'decide: not authenticated');
select is(has_function_privilege('anon', 'public.decide_parent_link_tx(uuid,uuid,boolean)', 'execute'), false, 'decide: not anon');

create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('admin', tests.create_user('admin', 'active'));
insert into c values ('tutor', tests.create_user('tutor', 'active'));
insert into c select n, tests.create_user('parent', 'active') from unnest(array['p1','p2','p_susp']) n;
insert into c select n, tests.create_user('student', 'active') from unnest(array['s_ok','s_pend','s_other']) n;

update public.student_details set index_number = 'SE-2099-7001', date_of_birth = date '2010-05-04'
  where profile_id = (select id from c where name='s_ok');
update public.student_details set index_number = 'SE-2099-7002', date_of_birth = date '2011-01-02'
  where profile_id = (select id from c where name='s_other');
update public.profiles set status = 'pending' where id = (select id from c where name='s_pend');
update public.profiles set status = 'suspended' where id = (select id from c where name='p_susp');

-- request_parent_link_tx: matching.
select is(public.request_parent_link_tx((select id from c where name='p1'), 'SE-2099-7001', date '2010-05-04'), true, 'exact index + DOB matches');
select is((select count(*)::int from public.parent_link_requests), 1, 'one request row');
select is((select count(*)::int from public.audit_log where action='parent_link_requested' and actor_id=(select id from c where name='p1')
  and target_type='profile' and target_id=(select id from c where name='s_ok')), 1, 'request audited with ids');
select is(public.request_parent_link_tx((select id from c where name='p1'), 'SE-2099-7001', date '2010-05-04'), true, 'duplicate request still true');
select is((select count(*)::int from public.parent_link_requests), 1, 'duplicate request inserts nothing');
select is((select count(*)::int from public.audit_log where action='parent_link_requested'), 1, 'duplicate request writes no second audit row');
select is(public.request_parent_link_tx((select id from c where name='p1'), 'SE-2099-7001', date '2010-05-05'), false, 'wrong DOB -> false');
select is(public.request_parent_link_tx((select id from c where name='p1'), 'SE-2099-9999', date '2010-05-04'), false, 'unknown index -> false');
select is(public.request_parent_link_tx((select id from c where name='p1'), 'SE-2099-7002', date '2010-05-04'), false, 'DOB of another child -> false');
select is(public.request_parent_link_tx((select id from c where name='p1'), 'se-2099-7001', date '2010-05-04'), false, 'index must be passed normalised (exact match)');
select is((select count(*)::int from public.parent_link_requests), 1, 'failed matches create no rows');
update public.student_details set index_number = 'SE-2099-7003', date_of_birth = date '2010-05-04'
  where profile_id = (select id from c where name='s_pend');
select is(public.request_parent_link_tx((select id from c where name='p1'), 'SE-2099-7003', date '2010-05-04'), false, 'pending (unapproved) student never matches');
select is(public.request_parent_link_tx((select id from c where name='p_susp'), 'SE-2099-7001', date '2010-05-04'), false, 'suspended parent cannot request');
select is(public.request_parent_link_tx((select id from c where name='tutor'), 'SE-2099-7001', date '2010-05-04'), false, 'non-parent cannot request');
select is((select count(*)::int from public.parent_link_requests), 1, 'still one request row');

-- Already linked: true, but no request row and no audit.
insert into public.parent_children (parent_id, student_id) values ((select id from c where name='p2'), (select id from c where name='s_other'));
select is(public.request_parent_link_tx((select id from c where name='p2'), 'SE-2099-7002', date '2011-01-02'), true, 'already linked -> true');
select is((select count(*)::int from public.parent_link_requests where parent_id=(select id from c where name='p2')), 0, 'already linked inserts no request');

-- RLS on parent_link_requests.
select tests.as_postgres();
select tests.as_user((select id from c where name='p1'));
select is((select count(*)::int from public.parent_link_requests), 1, 'parent sees own request');
select is((select count(*)::int from public.profiles where id=(select id from c where name='s_ok')), 0, 'parent still cannot read the requested child');
select throws_ok($q$insert into public.parent_link_requests (parent_id, student_id) values (gen_random_uuid(), gen_random_uuid())$q$, '42501', null, 'parent cannot insert requests');
select throws_ok($q$delete from public.parent_link_requests$q$, '42501', null, 'parent cannot delete requests');
select tests.as_postgres();
select tests.as_user((select id from c where name='p2'));
select is((select count(*)::int from public.parent_link_requests), 0, 'other parent sees none');
select tests.as_postgres();
select tests.as_user((select id from c where name='s_ok'));
select is((select count(*)::int from public.parent_link_requests), 0, 'student sees none');
select tests.as_postgres();
select tests.as_user((select id from c where name='tutor'));
select is((select count(*)::int from public.parent_link_requests), 0, 'tutor sees none');
select tests.as_postgres();
select tests.as_user((select id from c where name='admin'));
select is((select count(*)::int from public.parent_link_requests), 1, 'admin sees all');
select throws_ok($q$update public.parent_link_requests set created_at = now()$q$, '42501', null, 'admin has no client update');
select tests.as_postgres();

-- decide_parent_link_tx: approve.
insert into public.parent_link_blocks (parent_id, student_id) values ((select id from c where name='p1'), (select id from c where name='s_ok'));
select is(public.decide_parent_link_tx(gen_random_uuid(), (select id from c where name='admin'), true), 'not_found', 'unknown request -> not_found');
select is(public.decide_parent_link_tx((select id from public.parent_link_requests limit 1), (select id from c where name='tutor'), true), 'forbidden', 'non-admin actor refused');
select is((select count(*)::int from public.parent_link_requests), 1, 'forbidden decision keeps the request');
select is(public.decide_parent_link_tx((select id from public.parent_link_requests limit 1), (select id from c where name='admin'), true), 'approved', 'admin approves');
select is((select count(*)::int from public.parent_children where parent_id=(select id from c where name='p1') and student_id=(select id from c where name='s_ok')), 1, 'link created');
select is((select count(*)::int from public.parent_link_blocks where parent_id=(select id from c where name='p1')), 0, 'block cleared');
select is((select count(*)::int from public.parent_link_requests), 0, 'request deleted');
select is((select count(*)::int from public.audit_log where action='parent_link_approved' and target_type='parent_link_request' and actor_id=(select id from c where name='admin')), 1, 'approval audited');

-- reject, and conflicts.
select public.request_parent_link_tx((select id from c where name='p1'), 'SE-2099-7002', date '2011-01-02');
select is(public.decide_parent_link_tx((select id from public.parent_link_requests limit 1), (select id from c where name='admin'), false), 'rejected', 'admin rejects');
select is((select count(*)::int from public.parent_children where parent_id=(select id from c where name='p1') and student_id=(select id from c where name='s_other')), 0, 'reject creates no link');
select is((select count(*)::int from public.audit_log where action='parent_link_rejected' and target_type='parent_link_request'), 1, 'rejection audited');
insert into public.parent_link_requests (parent_id, student_id) values ((select id from c where name='p_susp'), (select id from c where name='s_ok'));
select is(public.decide_parent_link_tx((select id from public.parent_link_requests limit 1), (select id from c where name='admin'), true), 'conflict', 'inactive parent -> conflict');
select is((select count(*)::int from public.parent_children where parent_id=(select id from c where name='p_susp')), 0, 'no link for inactive parent');

-- approve_student_tx links requested_by_parent.
update public.profiles set status = 'pending' where id = (select id from c where name='s_pend');
update public.student_details set index_number = null, signup_parent_email = 'someone-else@test.example',
  requested_by_parent = (select id from c where name='p2') where profile_id = (select id from c where name='s_pend');
select lives_ok(format($q$select * from public.approve_student_tx(%L, %L, 2099)$q$, (select id from c where name='s_pend'), (select id from c where name='admin')), 'approve_student_tx runs');
select is((select count(*)::int from public.parent_children where parent_id=(select id from c where name='p2') and student_id=(select id from c where name='s_pend')), 1, 'requesting parent linked on approval');

-- register_child_tx.
select is(has_function_privilege('authenticated', 'public.register_child_tx(uuid,uuid)', 'execute'), false, 'register_child_tx: not authenticated');
update public.profiles set status = 'unconfirmed' where id = (select id from c where name='s_other');
update public.student_details set index_number = null where profile_id = (select id from c where name='s_other');
select is(public.register_child_tx((select id from c where name='s_other'), (select id from c where name='p1')), true, 'registers a fresh unconfirmed shell');
select is(public.register_child_tx((select id from c where name='s_other'), (select id from c where name='p2')), false, 'cannot be re-claimed by another parent');
select is(public.register_child_tx((select id from c where name='s_ok'), (select id from c where name='p1')), false, 'an approved student cannot be claimed');
select is((select count(*)::int from public.audit_log where action='child_registered_by_parent' and target_type='profile'), 1, 'one registration audit row');

select * from finish();
rollback;
