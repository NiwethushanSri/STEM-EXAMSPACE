begin;
create extension if not exists pgtap with schema extensions;
select plan(17);

-- Privileges.
select is(has_table_privilege('anon', 'public.login_attempts', 'select'), false, 'anon no select');
select is(has_table_privilege('authenticated', 'public.login_attempts', 'insert'), false, 'authenticated no insert');
select is((select relrowsecurity from pg_class where oid = 'public.login_attempts'::regclass), true, 'rls on');
select is(has_function_privilege('anon', 'public.login_attempt_begin(text,text)', 'execute'), false, 'anon no begin');
select is(has_function_privilege('authenticated', 'public.login_attempt_begin(text,text)', 'execute'), false, 'authenticated no begin');
select is(has_function_privilege('authenticated', 'public.login_attempt_succeed(text,text)', 'execute'), false, 'authenticated no succeed');
select is(has_function_privilege('authenticated', 'public.login_attempt_refund(text,text)', 'execute'), false, 'authenticated no refund');
select is(has_function_privilege('service_role', 'public.login_attempt_begin(text,text)', 'execute'), true, 'service_role begin');
select is(to_regprocedure('public.login_attempt_check(text,text)') is null, true, 'check dropped');

-- begin: true 5 times then false (idx key).
select is((select array_agg(public.login_attempt_begin('ip:a' || g, 'idx:a') order by g) from generate_series(1, 6) g),
  array[true, true, true, true, true, false], 'idx key: 5 true then false');
-- ip key.
select is((select array_agg(public.login_attempt_begin('ip:b', 'idx:b' || g) order by g) from generate_series(1, 6) g),
  array[true, true, true, true, true, false], 'ip key: 5 true then false');
-- old rows ignored.
insert into public.login_attempts (key, attempted_at) select 'idx:c', now() - interval '16 minutes' from generate_series(1, 5);
select is(public.login_attempt_begin('ip:c', 'idx:c'), true, 'rows older than 15 min ignored');
-- a refused begin records nothing.
select is((select count(*)::int from public.login_attempts where key = 'idx:a'), 5, 'refused begin inserts nothing');

-- succeed removes idx rows and exactly one ip row.
select public.login_attempt_succeed('ip:b', 'idx:b1');
select is((select count(*)::int from public.login_attempts where key = 'ip:b'), 4, 'succeed removes one ip row');
select is((select count(*)::int from public.login_attempts where key = 'idx:b1'), 0, 'succeed removes idx rows');

-- refund removes the latest row per key.
select public.login_attempt_refund('ip:b', 'idx:b2');
select is((select count(*)::int from public.login_attempts where key = 'ip:b'), 3, 'refund removes one ip row');
select is((select count(*)::int from public.login_attempts where key = 'idx:b2'), 0, 'refund removes idx row');

select * from finish();
rollback;
