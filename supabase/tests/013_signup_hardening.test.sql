begin;
create extension if not exists pgtap with schema extensions;
select plan(26);

create temp table u (name text primary key, id uuid not null);
insert into u values
  ('fresh',  tests.create_user('student', 'unconfirmed')),
  ('old',    tests.create_user('student', 'unconfirmed')),
  ('prot',   tests.create_user('tutor', 'unconfirmed')),
  ('rec',    tests.create_user('student', 'unconfirmed')),
  ('conf',   tests.create_user('student', 'unconfirmed')),
  ('allold', tests.create_user('student', 'unconfirmed'));
grant select on u to public;
update auth.users set created_at = now() - interval '61 minutes' where id in (select id from u where name in ('old', 'prot'));
update auth.users set created_at = now() - interval '59 minutes' where id = (select id from u where name = 'fresh');

-- Created 2 h ago but a recovery link went out 10 minutes ago: protected. Same for a confirmation link.
update auth.users set created_at = now() - interval '2 hours', recovery_sent_at = now() - interval '10 minutes'
  where id = (select id from u where name = 'rec');
update auth.users set created_at = now() - interval '2 hours', confirmation_sent_at = now() - interval '10 minutes'
  where id = (select id from u where name = 'conf');
-- Everything older than 1 hour: replaceable.
update auth.users set created_at = now() - interval '3 hours', recovery_sent_at = now() - interval '2 hours', confirmation_sent_at = now() - interval '90 minutes'
  where id = (select id from u where name = 'allold');

select is(public.replace_unconfirmed_signup((select email from auth.users where id = (select id from u where name = 'rec'))), 'protected', 'recent recovery link protects an old account');
select is((select count(*)::int from auth.users where id = (select id from u where name = 'rec')), 1, 'recovery-protected row exists');
select is(public.replace_unconfirmed_signup((select email from auth.users where id = (select id from u where name = 'conf'))), 'protected', 'recent confirmation link protects an old account');
select is((select count(*)::int from auth.users where id = (select id from u where name = 'conf')), 1, 'confirmation-protected row exists');
select is(public.replace_unconfirmed_signup((select email from auth.users where id = (select id from u where name = 'allold'))), 'replaced', 'all timestamps older than 1 hour: replaced');
select is((select count(*)::int from auth.users where id = (select id from u where name = 'allold')), 0, 'all-old sign-up gone');

-- replace_unconfirmed_signup: a sign-up younger than 1 hour is left alone.
select is(public.replace_unconfirmed_signup((select email from auth.users where id = (select id from u where name = 'fresh'))), 'protected', 'unconfirmed sign-up under 1 hour old is protected');
select is((select count(*)::int from auth.users where id = (select id from u where name = 'fresh')), 1, 'young sign-up still exists');
select is(public.replace_unconfirmed_signup((select email from auth.users where id = (select id from u where name = 'prot'))), 'protected', 'old non-student shell stays protected');
select is((select count(*)::int from auth.users where id = (select id from u where name = 'prot')), 1, 'protected row untouched');
select is(public.replace_unconfirmed_signup((select email from auth.users where id = (select id from u where name = 'old'))), 'replaced', 'sign-up over 1 hour old is replaced');
select is((select count(*)::int from auth.users where id = (select id from u where name = 'old')), 0, 'old sign-up gone');

-- login_attempt_begin_n: parameterised limits.
select is(has_function_privilege('anon', 'public.login_attempt_begin_n(text,text,int,int)', 'execute'), false, 'anon no begin_n');
select is(has_function_privilege('authenticated', 'public.login_attempt_begin_n(text,text,int,int)', 'execute'), false, 'authenticated no begin_n');
select is(has_function_privilege('service_role', 'public.login_attempt_begin_n(text,text,int,int)', 'execute'), true, 'service_role begin_n');
select is((select array_agg(public.login_attempt_begin_n('ipn:a', 'idn:a' || g, 30, 3) order by g) from generate_series(1, 4) g),
  array[true, true, true, true], 'distinct b keys: all allowed');
select is((select array_agg(public.login_attempt_begin_n('ipn:b' || g, 'idn:b', 30, 3) order by g) from generate_series(1, 5) g),
  array[true, true, true, false, false], 'b limit 3');
select is((select count(*)::int from public.login_attempts where key = 'idn:b'), 3, 'refused begin_n inserts nothing');
select is((select array_agg(public.login_attempt_begin_n('ipn:c', 'idn:c' || g, 30, 3) order by g) from generate_series(1, 31) g) [31],
  false, 'a limit 30: 31st refused');
insert into public.login_attempts (key, attempted_at) select 'idn:d', now() - interval '16 minutes' from generate_series(1, 5);
select is(public.login_attempt_begin_n('ipn:d', 'idn:d', 30, 3), true, 'rows older than 15 minutes ignored');
select is(public.login_attempt_begin_n('ipn:e', 'idn:e', 0, 0), false, 'limit 0 refuses');
select throws_ok($$select public.login_attempt_begin_n('ipn:g', 'idn:g', null, 3)$$, null, 'invalid attempt limits', 'null limit a raises');
select throws_ok($$select public.login_attempt_begin_n('ipn:g', 'idn:g', 30, null)$$, null, 'invalid attempt limits', 'null limit b raises');
select throws_ok($$select public.login_attempt_begin_n('ipn:g', 'idn:g', -1, 3)$$, null, 'invalid attempt limits', 'negative limit raises');
select throws_ok($$select public.login_attempt_begin_n('ipn:g', 'idn:g', 30, -1)$$, null, 'invalid attempt limits', 'negative limit b raises');
select is(public.login_attempt_begin('ipn:f', 'idn:f'), true, 'existing begin unchanged');

select * from finish();
rollback;
