begin;
create extension if not exists pgtap with schema extensions;
select plan(28);

create temp table u (name text primary key, id uuid not null);
insert into u values
  ('rej',     tests.create_user('student', 'pending')),
  ('active',  tests.create_user('student', 'active')),
  ('shell',   tests.create_user('student', 'pending')),
  ('old_unc', tests.create_user('student', 'unconfirmed')),
  ('new_unc', tests.create_user('student', 'unconfirmed')),
  ('old_pen', tests.create_user('student', 'pending')),
  ('old_stf', tests.create_user('tutor', 'unconfirmed')),
  ('old_stu', tests.create_user('student', 'unconfirmed'));
grant select on u to public;

update public.student_details set signup_parent_email = 'p@example.com'
  where profile_id = (select id from u where name = 'rej');
update auth.users set raw_app_meta_data = '{"invite_token":"7b0f6c1e-0000-4000-8000-000000000001"}'::jsonb
  where id = (select id from u where name = 'shell');

-- Privileges.
select is(has_function_privilege('authenticated', 'public.reject_student_tx(uuid)', 'execute'), false, 'reject_tx not executable by authenticated');
select is(has_function_privilege('anon', 'public.reject_student_tx(uuid)', 'execute'), false, 'reject_tx not executable by anon');
select is(has_function_privilege('service_role', 'public.reject_student_tx(uuid)', 'execute'), true, 'reject_tx executable by service_role');
select is(has_function_privilege('authenticated', 'public.expire_unconfirmed(timestamptz)', 'execute'), false, 'expire not executable by authenticated');
select is(has_function_privilege('anon', 'public.expire_unconfirmed(timestamptz)', 'execute'), false, 'expire not executable by anon');
select is(has_function_privilege('service_role', 'public.expire_unconfirmed(timestamptz)', 'execute'), false, 'expire not executable by service_role');

-- Rejection refusals.
select throws_ok(format($q$select public.reject_student_tx(%L)$q$, (select id from u where name = 'active')),
  'P0001', 'conflict', 'active student -> conflict');
select throws_ok(format($q$select public.reject_student_tx(%L)$q$, (select id from u where name = 'shell')),
  'P0001', 'conflict', 'claim shell -> conflict');
select throws_ok(format($q$select public.reject_student_tx(%L)$q$, (select id from u where name = 'old_stf')),
  'P0001', 'conflict', 'non-student -> conflict');
select throws_ok(format($q$select public.reject_student_tx(%L)$q$, gen_random_uuid()),
  'P0001', 'not_found', 'unknown id -> not_found');
select is((select count(*)::int from auth.users where id in (select id from u where name in ('active', 'shell'))), 2,
  'refused rejections leave users in place');

-- Rejection.
create temp table rej_email as select email::text as e from public.profiles where id = (select id from u where name = 'rej');
grant select on rej_email to public;
select is(public.reject_student_tx((select id from u where name = 'rej')), (select e from rej_email), 'reject returns the captured email');
select is((select count(*)::int from auth.users where id = (select id from u where name = 'rej')), 0, 'auth user gone');
select is((select count(*)::int from public.profiles where id = (select id from u where name = 'rej')), 0, 'profile gone');
select is((select count(*)::int from public.student_details where profile_id = (select id from u where name = 'rej')), 0, 'details gone');

-- Expiry. Use a fixed far-past "now" so real dev data is never matched.
create temp table t0 as select '2000-01-01 00:00:00+00'::timestamptz as now_;
grant select on t0 to public;
update auth.users set created_at = (select now_ from t0) - interval '8 days'
  where id in (select id from u where name in ('old_unc', 'old_pen', 'old_stf', 'old_stu'));
update auth.users set created_at = (select now_ from t0) - interval '6 days'
  where id = (select id from u where name = 'new_unc');

create temp table before_audit as select count(*)::int as n from public.audit_log where action = 'registration_expired';
grant select on before_audit to public;
select is(public.expire_unconfirmed((select now_ from t0)), 2, 'expire returns exact count');
select is((select count(*)::int from auth.users where id in (select id from u where name in ('old_unc', 'old_stu'))), 0, '8-day unconfirmed students deleted');
select is((select count(*)::int from public.profiles where id in (select id from u where name in ('old_unc', 'old_stu'))), 0, 'their profiles gone');
select is((select count(*)::int from auth.users where id = (select id from u where name = 'new_unc')), 1, '6-day unconfirmed kept');
select is((select count(*)::int from auth.users where id = (select id from u where name = 'old_pen')), 1, '8-day pending kept');
select is((select count(*)::int from auth.users where id = (select id from u where name = 'old_stf')), 1, '8-day unconfirmed staff kept');
select is((select count(*)::int from public.audit_log where action = 'registration_expired') - (select n from before_audit), 2, 'two expiry audit rows');
select is((select count(*)::int from public.audit_log where action = 'registration_expired'
  and actor_id is null and target_type is null and target_id is null) - (select n from before_audit), 2, 'expiry audit rows have null actor and target');
select is(public.expire_unconfirmed((select now_ from t0)), 0, 'second run deletes nothing');

-- Cron job.
select is((select count(*)::int from cron.job where jobname = 'expire-unconfirmed-signups'), 1, 'cron job exists');
select is((select schedule from cron.job where jobname = 'expire-unconfirmed-signups'), '0 3 * * *', 'cron schedule');
select ok((select command from cron.job where jobname = 'expire-unconfirmed-signups') like '%expire_unconfirmed()%', 'cron command');

-- Authenticated callers cannot execute.
select tests.as_user((select id from u where name = 'old_pen'));
select throws_ok($q$select public.expire_unconfirmed()$q$, '42501', null, 'authenticated cannot call expire');
select tests.as_postgres();

select * from finish();
rollback;
