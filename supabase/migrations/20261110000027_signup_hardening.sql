-- Registration hardening (R1, R4).
-- R1: a sign-up younger than 1 hour is never replaced, so a second submitter cannot knock out a student
--     who has just registered and not yet used the emailed link (links last 1 hour).
-- R4: parameterised attempt limiter for register-student (per IP and per email limits differ from login).

create or replace function public.replace_unconfirmed_signup(p_email text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_id uuid;
  v_confirmed timestamptz;
  v_created timestamptz;
  v_token text;
  v_role public.app_role;
  v_status public.account_status;
begin
  select au.id, au.email_confirmed_at, au.created_at, au.raw_app_meta_data ->> 'invite_token'
    into v_id, v_confirmed, v_created, v_token
  from auth.users au
  where lower(btrim(au.email)) = v_email
  for update;
  if not found then
    return 'none';
  end if;
  if v_confirmed is not null then
    return 'confirmed';
  end if;
  -- Its confirmation link may still be live: leave it alone.
  if v_created is null or v_created > now() - interval '1 hour' then
    return 'protected';
  end if;

  select pr.role, pr.status into v_role, v_status from public.profiles pr where pr.id = v_id for update;
  if not found or v_role <> 'student' or v_status <> 'unconfirmed' or v_token is not null then
    return 'protected';
  end if;
  -- A child registered by a parent, or any approved/indexed student, is not a self sign-up.
  if exists (
    select 1 from public.student_details d
    where d.profile_id = v_id and (d.index_number is not null or d.requested_by_parent is not null)
  ) or exists (select 1 from public.student_subjects s where s.student_id = v_id)
     or exists (select 1 from public.parent_children c where c.student_id = v_id) then
    return 'protected';
  end if;

  perform public.purge_student_residue(v_id);
  delete from auth.users where id = v_id;
  insert into public.audit_log (actor_id, action) values (null, 'signup_replaced');
  return 'replaced';
end;
$$;

revoke execute on function public.replace_unconfirmed_signup(text) from public, anon, authenticated;
grant execute on function public.replace_unconfirmed_signup(text) to service_role;

-- Same pattern as login_attempt_begin (advisory locks in sorted key order, record in the same step),
-- with a limit per key. Records nothing when refused. login_attempt_begin itself is unchanged (5 / 5).
create or replace function public.login_attempt_begin_n(p_key_a text, p_key_b text, p_limit_a int, p_limit_b int)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_k text;
begin
  foreach v_k in array (select array_agg(k order by k) from unnest(array[p_key_a, p_key_b]) as k) loop
    perform pg_advisory_xact_lock(hashtextextended(v_k, 0));
  end loop;

  delete from public.login_attempts where attempted_at < now() - interval '1 day';

  if (select count(*) from public.login_attempts a where a.key = p_key_a and a.attempted_at > now() - interval '15 minutes') >= p_limit_a
     or (select count(*) from public.login_attempts a where a.key = p_key_b and a.attempted_at > now() - interval '15 minutes') >= p_limit_b then
    return false;
  end if;

  insert into public.login_attempts (key) values (p_key_a), (p_key_b);
  return true;
end;
$$;

revoke all on function public.login_attempt_begin_n(text, text, int, int) from public, anon, authenticated;
grant execute on function public.login_attempt_begin_n(text, text, int, int) to service_role;
