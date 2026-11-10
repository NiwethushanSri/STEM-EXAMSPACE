begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

create temp table u (name text primary key, id uuid not null);
insert into u values
  ('fresh',  tests.create_user('student', 'unconfirmed')),
  ('old',    tests.create_user('student', 'unconfirmed')),
  ('prot',   tests.create_user('tutor', 'unconfirmed'));
grant select on u to public;
update auth.users set created_at = now() - interval '61 minutes' where id in (select id from u where name in ('old', 'prot'));
update auth.users set created_at = now() - interval '59 minutes' where id = (select id from u where name = 'fresh');

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
select is(public.login_attempt_begin('ipn:f', 'idn:f'), true, 'existing begin unchanged');

select * from finish();
rollback;
