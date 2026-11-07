begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

-- Privileges.
select is(has_table_privilege('anon', 'public.login_attempts', 'select'), false, 'anon no select');
select is(has_table_privilege('authenticated', 'public.login_attempts', 'select'), false, 'authenticated no select');
select is(has_table_privilege('authenticated', 'public.login_attempts', 'insert'), false, 'authenticated no insert');
select is((select relrowsecurity from pg_class where oid = 'public.login_attempts'::regclass), true, 'rls on');
select is(has_function_privilege('anon', 'public.login_attempt_check(text,text)', 'execute'), false, 'anon no check');
select is(has_function_privilege('authenticated', 'public.login_attempt_fail(text,text)', 'execute'), false, 'authenticated no fail');
select is(has_function_privilege('authenticated', 'public.login_attempt_clear(text)', 'execute'), false, 'authenticated no clear');
select is(has_function_privilege('service_role', 'public.login_attempt_check(text,text)', 'execute'), true, 'service_role check');

-- Behaviour.
select is(public.login_attempt_check('ip:t1', 'idx:t1'), true, 'check true with no rows');

insert into public.login_attempts (key) select 'idx:t2' from generate_series(1, 4);
select is(public.login_attempt_check('ip:t2', 'idx:t2'), true, 'true below threshold (4)');
insert into public.login_attempts (key) values ('idx:t2');
select is(public.login_attempt_check('ip:t2', 'idx:t2'), false, 'false at 5 on idx key');

insert into public.login_attempts (key) select 'ip:t3' from generate_series(1, 5);
select is(public.login_attempt_check('ip:t3', 'idx:t3'), false, 'false at 5 on ip key');

insert into public.login_attempts (key, attempted_at) select 'idx:t4', now() - interval '16 minutes' from generate_series(1, 5);
select is(public.login_attempt_check('ip:t4', 'idx:t4'), true, 'rows older than 15 min ignored');

select public.login_attempt_clear('idx:t2');
select is((select count(*)::int from public.login_attempts where key = 'idx:t2'), 0, 'clear removes idx rows');
select is((select count(*)::int from public.login_attempts where key = 'ip:t3'), 5, 'clear leaves other keys');

select public.login_attempt_fail('ip:t5', 'idx:t5');
select is((select count(*)::int from public.login_attempts where key in ('ip:t5', 'idx:t5')), 2, 'fail inserts two rows');

select * from finish();
rollback;
