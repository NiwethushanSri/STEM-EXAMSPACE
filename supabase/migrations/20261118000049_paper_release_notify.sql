-- Release emails. The paper-release-notify Edge Function (called every minute by pg_cron through pg_net) emails
-- the families of home bookings when their exam's paper is released, and once more when a paper they already
-- downloaded is replaced. These functions only choose who to email; the function sends and marks.
-- Everything is bounded by a 6-hour window so turning email on later cannot announce old releases.

create extension if not exists pg_net with schema extensions;

-- Exams whose release time fell in the last 6 hours, that are published, not held, not yet announced and have a
-- current paper.
create function public.paper_release_due(p_now timestamptz default now())
returns table (exam_id uuid, title text, paper text)
language sql
stable
security definer
set search_path = ''
as $$
  select e.id, e.title, e.paper
  from public.exams e
  where e.status = 'published'
    and not e.release_held
    and e.release_notified_at is null
    and public.paper_release_at(e.id) <= p_now
    and public.paper_release_at(e.id) > p_now - interval '6 hours'
    and exists (
      select 1 from public.exam_papers p
      where p.exam_id = e.id and p.kind = 'paper' and p.superseded_at is null
    )
$$;

-- The active candidate and active linked parents of each paid or cancel_requested home booking, once per address.
create function public.paper_release_recipients(p_exam uuid)
returns table (email text, first_name text)
language sql
stable
security definer
set search_path = ''
as $$
  select distinct on (lower(r.email)) r.email, r.first_name
  from public.bookings b
  join lateral (
    select p.id, p.email, p.first_name, 0 as rnk, p.created_at from public.profiles p
    where p.id = b.student_id and p.status = 'active'
    union all
    select p.id, p.email, p.first_name, 1, p.created_at
    from public.parent_children pc
    join public.profiles p on p.id = pc.parent_id and p.status = 'active'
    where pc.student_id = b.student_id
  ) r on true
  where b.exam_id = p_exam
    and b.sitting = 'home'
    and b.status in ('paid', 'cancel_requested')
    and r.email is not null
  order by lower(r.email), r.rnk, r.created_at, r.id
$$;

-- Exams with a paper version replaced in the last 6 hours (and not yet announced) while a current paper exists.
create function public.paper_corrected_due(p_now timestamptz default now())
returns table (exam_id uuid, title text, paper text, paper_ids uuid[])
language sql
stable
security definer
set search_path = ''
as $$
  select e.id, e.title, e.paper, array_agg(old.id)
  from public.exam_papers old
  join public.exams e on e.id = old.exam_id
  where e.status = 'published'
    and not e.release_held
    and old.kind = 'paper'
    and old.superseded_at is not null
    and old.superseded_at > p_now - interval '6 hours'
    and old.corrected_notified_at is null
    and exists (
      select 1 from public.exam_papers cur
      where cur.exam_id = e.id and cur.kind = 'paper' and cur.superseded_at is null
    )
  group by e.id, e.title, e.paper
$$;

-- Active candidate and active linked parents of home bookings that downloaded one of the replaced versions.
create function public.paper_corrected_recipients(p_paper_ids uuid[])
returns table (email text, first_name text)
language sql
stable
security definer
set search_path = ''
as $$
  select distinct on (lower(r.email)) r.email, r.first_name
  from public.paper_copies c
  join public.bookings b on b.id = c.booking_id
  join lateral (
    select p.id, p.email, p.first_name, 0 as rnk, p.created_at from public.profiles p
    where p.id = b.student_id and p.status = 'active'
    union all
    select p.id, p.email, p.first_name, 1, p.created_at
    from public.parent_children pc
    join public.profiles p on p.id = pc.parent_id and p.status = 'active'
    where pc.student_id = b.student_id
  ) r on true
  where c.paper_id = any (p_paper_ids)
    and exists (select 1 from public.paper_downloads d where d.copy_id = c.id)
    and not exists (
      select 1
      from public.exam_papers cur
      join public.paper_copies cc on cc.paper_id = cur.id and cc.booking_id = b.id
      join public.paper_downloads cd on cd.copy_id = cc.id
      where cur.exam_id = b.exam_id and cur.kind = 'paper' and cur.superseded_at is null
    )
    and b.sitting = 'home'
    and b.status in ('paid', 'cancel_requested')
    and r.email is not null
  order by lower(r.email), r.rnk, r.created_at, r.id
$$;

revoke execute on function public.paper_release_due(timestamptz) from public, anon, authenticated;
revoke execute on function public.paper_release_recipients(uuid) from public, anon, authenticated;
revoke execute on function public.paper_corrected_due(timestamptz) from public, anon, authenticated;
revoke execute on function public.paper_corrected_recipients(uuid[]) from public, anon, authenticated;
grant execute on function public.paper_release_due(timestamptz) to service_role;
grant execute on function public.paper_release_recipients(uuid) to service_role;
grant execute on function public.paper_corrected_due(timestamptz) to service_role;
grant execute on function public.paper_corrected_recipients(uuid[]) to service_role;

-- The cron tick reads the function URL and shared secret from Vault (names paper_notify_url and cron_secret).
-- With either missing it does nothing, so a database without them (local, a fresh project) is quiet.
create function public.paper_release_notify_tick()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
  v_secret text;
begin
  if to_regclass('vault.decrypted_secrets') is null or to_regnamespace('net') is null then
    return;
  end if;
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'paper_notify_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'cron_secret';
  if coalesce(v_url, '') = '' or coalesce(v_secret, '') = '' then
    return;
  end if;
  perform net.http_post(
    url := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', v_secret),
    body := '{}'::jsonb,
    timeout_milliseconds := 120000
  );
end;
$$;
revoke execute on function public.paper_release_notify_tick() from public, anon, authenticated, service_role;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'paper-release-notify') then
    perform cron.unschedule('paper-release-notify');
  end if;
  perform cron.schedule('paper-release-notify', '* * * * *', $job$select public.paper_release_notify_tick()$job$);
end;
$$;
