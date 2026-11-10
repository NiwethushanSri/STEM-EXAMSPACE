-- Registration hardening review fixes.
-- 1-hour no-replace rule now covers the latest of creation, last confirmation link and last recovery link.
-- login_attempt_begin_n rejects NULL or negative limits.

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
  v_last timestamptz;
  v_token text;
  v_role public.app_role;
  v_status public.account_status;
begin
  select au.id, au.email_confirmed_at,
         greatest(au.created_at, coalesce(au.recovery_sent_at, au.created_at), coalesce(au.confirmation_sent_at, au.created_at)),
         au.raw_app_meta_data ->> 'invite_token'
    into v_id, v_confirmed, v_last, v_token
  from auth.users au
  where lower(btrim(au.email)) = v_email
  for update;
  if not found then
    return 'none';
  end if;
  if v_confirmed is not null then
    return 'confirmed';
  end if;
  -- A link (confirmation or recovery) may still be live: leave it alone for 1 hour after the latest of
  -- creation and the last link sent.
  if v_last is null or v_last > now() - interval '1 hour' then
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

create or replace function public.login_attempt_begin_n(p_key_a text, p_key_b text, p_limit_a int, p_limit_b int)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_k text;
begin
  if p_limit_a is null or p_limit_b is null or p_limit_a < 0 or p_limit_b < 0 then
    raise exception 'invalid attempt limits';
  end if;
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
