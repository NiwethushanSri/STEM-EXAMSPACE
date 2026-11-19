-- Release emails. The paper-release-notify Edge Function (called every minute by pg_cron through pg_net) emails
-- the families of home bookings when their exam's paper is released, and once more when a paper they already
-- downloaded is replaced. These functions decide what is due, who gets it and who already got it; the function
-- only sends.
--
-- Every email belongs to a notice (paper_notices): an exam's release, or the replacement of one or more paper
-- versions. A notice can take several runs: each run works it for at most its time budget and the next run
-- carries on with the families not emailed yet. Each recipient is recorded (paper_notices_sent) before the email
-- goes out, so nobody gets the same notice twice, even if two runs overlap. When every email of a run fails, the
-- notice waits 15 minutes before it is tried again, and after 3 such runs it is given up.
-- Everything is bounded by a 6-hour window, and nothing is announced once downloads have closed (2 hours after
-- the scheduled end), so turning email on later, or an outage, cannot announce old releases.

create extension if not exists pg_net with schema extensions;

-- ---------------------------------------------------------------------------------------------
-- Notices and who has been emailed. Service role reads only; writes only through the functions below.
-- ---------------------------------------------------------------------------------------------
create table public.paper_notices (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('released', 'corrected')),
  exam_id uuid not null references public.exams (id) on delete cascade,
  -- released: the release time announced. When the exam's release is reset (the exam is moved, or its release
  -- is set later), its open release notice is closed and a new one opens at the new time.
  release_at timestamptz,
  -- corrected: the replaced paper versions the notice is about.
  paper_ids uuid[] not null default '{}',
  -- nothing is sent from this time on
  window_until timestamptz not null,
  created_at timestamptz not null default now(),
  -- a run is working the notice until then
  lease_until timestamptz,
  -- runs in which every email failed; after a failed run nothing is tried before retry_at
  failed_rounds int not null default 0,
  retry_at timestamptz,
  done_at timestamptz,
  constraint paper_notices_kind_fields check (
    (kind = 'released' and release_at is not null and cardinality(paper_ids) = 0)
    or (kind = 'corrected' and release_at is null and cardinality(paper_ids) > 0))
);
create index paper_notices_open_idx on public.paper_notices (created_at, id) where done_at is null;
create index paper_notices_exam_idx on public.paper_notices (exam_id);

-- One row per notice and person emailed (ids only: no address or name is copied here).
create table public.paper_notices_sent (
  notice_id bigint not null references public.paper_notices (id) on delete cascade,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  sent_at timestamptz not null default now(),
  primary key (notice_id, profile_id)
);
create index paper_notices_sent_profile_idx on public.paper_notices_sent (profile_id);

alter table public.paper_notices enable row level security;
alter table public.paper_notices_sent enable row level security;
revoke all on public.paper_notices, public.paper_notices_sent from public, anon, authenticated, service_role;
revoke all on sequence public.paper_notices_id_seq from public, anon, authenticated, service_role;
grant select on public.paper_notices, public.paper_notices_sent to service_role;

-- ---------------------------------------------------------------------------------------------
-- What is due, and who gets it.
-- ---------------------------------------------------------------------------------------------

-- Exams whose release time fell in the last 6 hours, that are published, not held, not yet announced, still open
-- for downloads (before the scheduled end plus 2 hours) and have a current paper.
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
    and p_now < e.starts_at + e.duration_minutes * interval '1 minute' + interval '2 hours'
    and exists (
      select 1 from public.exam_papers p
      where p.exam_id = e.id and p.kind = 'paper' and p.superseded_at is null
    )
$$;

-- The active candidate and active linked parents of each paid or cancel_requested home booking, once per address.
create function public.paper_release_recipients(p_exam uuid)
returns table (profile_id uuid, email text, first_name text)
language sql
stable
security definer
set search_path = ''
as $$
  select distinct on (lower(r.email)) r.id, r.email, r.first_name
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

-- Exams with a paper version replaced in the last 6 hours (and not yet announced) while a current paper exists and
-- downloads are still open.
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
    and old.superseded_at <= p_now
    and old.superseded_at > p_now - interval '6 hours'
    and old.corrected_notified_at is null
    and p_now < e.starts_at + e.duration_minutes * interval '1 minute' + interval '2 hours'
    and exists (
      select 1 from public.exam_papers cur
      where cur.exam_id = e.id and cur.kind = 'paper' and cur.superseded_at is null
    )
  group by e.id, e.title, e.paper
$$;

-- Active candidate and active linked parents of home bookings that downloaded one of the replaced versions.
create function public.paper_corrected_recipients(p_paper_ids uuid[])
returns table (profile_id uuid, email text, first_name text)
language sql
stable
security definer
set search_path = ''
as $$
  select distinct on (lower(r.email)) r.id, r.email, r.first_name
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

-- ---------------------------------------------------------------------------------------------
-- Working the notices (service role, from the Edge Function).
-- ---------------------------------------------------------------------------------------------

-- Opens a notice for every release and replacement that is due (claiming it on the exam or paper rows, so two runs
-- cannot open the same one) and closes notices that can no longer be sent. Returns how many were opened.
create function public.paper_notice_open(p_now timestamptz default now())
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := public.paper_clock(p_now);
  v_released int;
  v_corrected int;
begin
  -- past their window
  update public.paper_notices n set done_at = v_now, lease_until = null
  where n.done_at is null and n.window_until <= v_now;

  with due as (
    select d.exam_id, public.paper_release_at(d.exam_id) as release_at from public.paper_release_due(v_now) d
  ), claimed as (
    update public.exams e set release_notified_at = v_now
    from due
    where e.id = due.exam_id and e.release_notified_at is null
    returning e.id, due.release_at
  )
  insert into public.paper_notices (kind, exam_id, release_at, window_until)
  select 'released', c.id, c.release_at, c.release_at + interval '6 hours' from claimed c;
  get diagnostics v_released = row_count;

  with due as (
    select d.paper_ids from public.paper_corrected_due(v_now) d
  ), claimed as (
    update public.exam_papers p set corrected_notified_at = v_now
    from due
    where p.id = any (due.paper_ids) and p.corrected_notified_at is null
    returning p.id, p.exam_id, p.superseded_at
  )
  insert into public.paper_notices (kind, exam_id, paper_ids, window_until)
  select 'corrected', c.exam_id, array_agg(c.id order by c.id), max(c.superseded_at) + interval '6 hours'
  from claimed c
  group by c.exam_id;
  get diagnostics v_corrected = row_count;

  return v_released + v_corrected;
end;
$$;

-- The oldest notice that can be worked now, leased to the caller for 5 minutes (other runs skip it). p_exclude:
-- notices this run already worked. Nothing is returned for a held, cancelled or closed exam, an exam without a
-- current paper, or a notice waiting after a failed run.
create function public.paper_notice_next(p_exclude bigint[] default '{}', p_now timestamptz default now())
returns table (notice_id bigint, kind text, exam_id uuid, title text, paper text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := public.paper_clock(p_now);
  v_id bigint;
begin
  select n.id into v_id
  from public.paper_notices n
  join public.exams e on e.id = n.exam_id
  where n.done_at is null
    and not (n.id = any (coalesce(p_exclude, '{}')))
    and (n.lease_until is null or n.lease_until <= v_now)
    and (n.retry_at is null or n.retry_at <= v_now)
    and n.window_until > v_now
    and e.status = 'published'
    and not e.release_held
    and v_now < e.starts_at + e.duration_minutes * interval '1 minute' + interval '2 hours'
    and exists (
      select 1 from public.exam_papers p
      where p.exam_id = e.id and p.kind = 'paper' and p.superseded_at is null
    )
  order by n.created_at, n.id
  limit 1
  for update of n skip locked;
  if v_id is null then
    return;
  end if;
  update public.paper_notices set lease_until = v_now + interval '5 minutes' where id = v_id;
  return query
    select n.id, n.kind, n.exam_id, e.title, e.paper
    from public.paper_notices n join public.exams e on e.id = n.exam_id
    where n.id = v_id;
end;
$$;

-- Who the notice still has to reach: everyone it is for, less those already recorded for it.
create function public.paper_notice_recipients(p_notice bigint)
returns table (profile_id uuid, email text, first_name text)
language sql
stable
security definer
set search_path = ''
as $$
  select r.profile_id, r.email, r.first_name
  from public.paper_notices n
  cross join lateral (
    select x.profile_id, x.email, x.first_name from public.paper_release_recipients(n.exam_id) x
    where n.kind = 'released'
    union all
    select x.profile_id, x.email, x.first_name from public.paper_corrected_recipients(n.paper_ids) x
    where n.kind = 'corrected'
  ) r
  where n.id = p_notice
    and not exists (
      select 1 from public.paper_notices_sent s where s.notice_id = n.id and s.profile_id = r.profile_id
    )
  order by lower(r.email)
$$;

-- Records a recipient just before the email is sent. ok: send it. already: someone else did (do not send).
-- stopped: the notice is closed or its exam was held, cancelled or closed meanwhile (stop sending).
create function public.paper_notice_mark(p_notice bigint, p_profile uuid, p_now timestamptz default now())
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := public.paper_clock(p_now);
begin
  if not exists (
    select 1
    from public.paper_notices n
    join public.exams e on e.id = n.exam_id
    where n.id = p_notice
      and n.done_at is null
      and n.window_until > v_now
      and e.status = 'published'
      and not e.release_held
      and v_now < e.starts_at + e.duration_minutes * interval '1 minute' + interval '2 hours') then
    return 'stopped';
  end if;
  insert into public.paper_notices_sent (notice_id, profile_id) values (p_notice, p_profile)
  on conflict do nothing;
  return case when found then 'ok' else 'already' end;
end;
$$;

-- The email to this recipient failed: forget them so a later run can try again.
create function public.paper_notice_unmark(p_notice bigint, p_profile uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.paper_notices_sent where notice_id = p_notice and profile_id = p_profile
$$;

-- Ends a run's work on a notice and releases the lease. Returns
--   done: nobody is left to email;
--   retry: every email of the run failed, so the notice waits 15 minutes;
--   gave_up: that happened for the third time, so the notice is closed;
--   continue: people are left (time ran out, or some emails failed), the next run carries on.
create function public.paper_notice_finish(p_notice bigint, p_sent int, p_failed int, p_now timestamptz default now())
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := public.paper_clock(p_now);
  v_n public.paper_notices%rowtype;
begin
  select * into v_n from public.paper_notices where id = p_notice for update;
  if not found then
    return 'done';
  end if;
  if v_n.done_at is not null then
    update public.paper_notices set lease_until = null where id = p_notice;
    return 'done';
  end if;
  if not exists (select 1 from public.paper_notice_recipients(p_notice)) then
    update public.paper_notices set lease_until = null, done_at = v_now where id = p_notice;
    return 'done';
  end if;
  if coalesce(p_sent, 0) = 0 and coalesce(p_failed, 0) > 0 then
    if v_n.failed_rounds + 1 >= 3 then
      update public.paper_notices
      set lease_until = null, failed_rounds = failed_rounds + 1, done_at = v_now
      where id = p_notice;
      return 'gave_up';
    end if;
    update public.paper_notices
    set lease_until = null, failed_rounds = failed_rounds + 1, retry_at = v_now + interval '15 minutes'
    where id = p_notice;
    return 'retry';
  end if;
  update public.paper_notices set lease_until = null where id = p_notice;
  return 'continue';
end;
$$;

-- A reset release (exams_release_follows_start on a move, or set_exam_paper_settings setting a later release)
-- closes the exam's open release notice; the new release time opens a new one.
create function public.paper_notices_close_on_release_reset()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.paper_notices set done_at = now(), lease_until = null
  where exam_id = new.id and kind = 'released' and done_at is null;
  return null;
end;
$$;
create trigger exams_release_notice_reset after update on public.exams
  for each row when (old.release_notified_at is not null and new.release_notified_at is null)
  execute function public.paper_notices_close_on_release_reset();

revoke execute on function public.paper_notices_close_on_release_reset() from public, anon, authenticated, service_role;
revoke execute on function public.paper_release_due(timestamptz) from public, anon, authenticated;
revoke execute on function public.paper_release_recipients(uuid) from public, anon, authenticated;
revoke execute on function public.paper_corrected_due(timestamptz) from public, anon, authenticated;
revoke execute on function public.paper_corrected_recipients(uuid[]) from public, anon, authenticated;
revoke execute on function public.paper_notice_open(timestamptz) from public, anon, authenticated;
revoke execute on function public.paper_notice_next(bigint[], timestamptz) from public, anon, authenticated;
revoke execute on function public.paper_notice_recipients(bigint) from public, anon, authenticated;
revoke execute on function public.paper_notice_mark(bigint, uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.paper_notice_unmark(bigint, uuid) from public, anon, authenticated;
revoke execute on function public.paper_notice_finish(bigint, int, int, timestamptz) from public, anon, authenticated;
grant execute on function public.paper_release_due(timestamptz) to service_role;
grant execute on function public.paper_release_recipients(uuid) to service_role;
grant execute on function public.paper_corrected_due(timestamptz) to service_role;
grant execute on function public.paper_corrected_recipients(uuid[]) to service_role;
grant execute on function public.paper_notice_open(timestamptz) to service_role;
grant execute on function public.paper_notice_next(bigint[], timestamptz) to service_role;
grant execute on function public.paper_notice_recipients(bigint) to service_role;
grant execute on function public.paper_notice_mark(bigint, uuid, timestamptz) to service_role;
grant execute on function public.paper_notice_unmark(bigint, uuid) to service_role;
grant execute on function public.paper_notice_finish(bigint, int, int, timestamptz) to service_role;

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
