-- Rate limiting for index-number login. Server-side only (service_role).

create table public.login_attempts (
  key text not null,
  attempted_at timestamptz not null default now()
);
create index login_attempts_key_attempted_at_idx on public.login_attempts (key, attempted_at);

alter table public.login_attempts enable row level security;
revoke all on table public.login_attempts from public, anon, authenticated;
grant select, insert, delete on table public.login_attempts to service_role;

-- False if EITHER key has 5 or more attempts in the last 15 minutes.
create or replace function public.login_attempt_check(p_ip_key text, p_idx_key text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not exists (
    select 1
    from public.login_attempts a
    where a.key in (p_ip_key, p_idx_key)
      and a.attempted_at > now() - interval '15 minutes'
    group by a.key
    having count(*) >= 5
  );
$$;

create or replace function public.login_attempt_fail(p_ip_key text, p_idx_key text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.login_attempts (key) values (p_ip_key), (p_idx_key);
  delete from public.login_attempts where attempted_at < now() - interval '1 day';
end;
$$;

create or replace function public.login_attempt_clear(p_idx_key text)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.login_attempts where key = p_idx_key;
$$;

revoke all on function public.login_attempt_check(text, text) from public, anon, authenticated;
revoke all on function public.login_attempt_fail(text, text) from public, anon, authenticated;
revoke all on function public.login_attempt_clear(text) from public, anon, authenticated;
grant execute on function public.login_attempt_check(text, text) to service_role;
grant execute on function public.login_attempt_fail(text, text) to service_role;
grant execute on function public.login_attempt_clear(text) to service_role;
