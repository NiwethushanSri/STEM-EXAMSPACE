-- Test helpers: injected by scripts/db-test.mjs right after each test file's first `begin;`.
-- They live inside the test transaction and roll back with it.
create schema if not exists tests;

-- Creates an auth user (the sign-up trigger builds the profile), then sets role/status as postgres.
create or replace function tests.create_user(p_role public.app_role, p_status public.account_status)
returns uuid
language plpgsql
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data, created_at, instance_id, aud, role)
  values (v_id, p_role::text || '-' || v_id::text || '@test.example',
    '{}'::jsonb, '{}'::jsonb, now(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated');
  update public.profiles set role = p_role, status = p_status where id = v_id;
  if p_role <> 'student' then
    delete from public.student_details where profile_id = v_id;
  end if;
  return v_id;
end;
$$;

-- Acts as the given signed-in user until reset role / end of transaction.
create or replace function tests.as_user(p_uid uuid)
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  set local role authenticated;
end;
$$;

create or replace function tests.as_postgres()
returns void
language plpgsql
as $$
begin
  reset role;
end;
$$;

grant usage on schema tests to anon, authenticated;
grant execute on function tests.as_postgres() to anon, authenticated;
