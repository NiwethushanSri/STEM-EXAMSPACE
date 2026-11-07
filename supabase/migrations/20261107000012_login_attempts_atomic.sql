-- Atomic rate limiting: the attempt is recorded in the same locked step as the limit check.

drop function public.login_attempt_check(text, text);
drop function public.login_attempt_fail(text, text);

create index login_attempts_attempted_at_idx on public.login_attempts (attempted_at);

create or replace function public.login_attempt_begin(p_ip_key text, p_idx_key text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_k text;
begin
  -- Serialise per key, always in sorted order to avoid deadlocks.
  foreach v_k in array (select array_agg(k order by k) from unnest(array[p_ip_key, p_idx_key]) as k) loop
    perform pg_advisory_xact_lock(hashtextextended(v_k, 0));
  end loop;

  delete from public.login_attempts where attempted_at < now() - interval '1 day';

  if exists (
    select 1
    from public.login_attempts a
    where a.key in (p_ip_key, p_idx_key)
      and a.attempted_at > now() - interval '15 minutes'
    group by a.key
    having count(*) >= 5
  ) then
    return false;
  end if;

  insert into public.login_attempts (key) values (p_ip_key), (p_idx_key);
  return true;
end;
$$;

-- Successful sign-in: forget the index's attempts and the one ip row this attempt added.
create or replace function public.login_attempt_succeed(p_ip_key text, p_idx_key text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.login_attempts where key = p_idx_key;
  delete from public.login_attempts where ctid = (
    select a.ctid from public.login_attempts a where a.key = p_ip_key order by a.attempted_at desc limit 1
  );
end;
$$;

-- Infrastructure error: give the attempt back (most recent row per key).
create or replace function public.login_attempt_refund(p_ip_key text, p_idx_key text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_k text;
begin
  foreach v_k in array array[p_ip_key, p_idx_key] loop
    delete from public.login_attempts where ctid = (
      select a.ctid from public.login_attempts a where a.key = v_k order by a.attempted_at desc limit 1
    );
  end loop;
end;
$$;

revoke all on function public.login_attempt_begin(text, text) from public, anon, authenticated;
revoke all on function public.login_attempt_succeed(text, text) from public, anon, authenticated;
revoke all on function public.login_attempt_refund(text, text) from public, anon, authenticated;
grant execute on function public.login_attempt_begin(text, text) to service_role;
grant execute on function public.login_attempt_succeed(text, text) to service_role;
grant execute on function public.login_attempt_refund(text, text) to service_role;
