-- Phase 2 Task 7: emails about scripts. A notice is queued by a trigger in the same transaction as its event:
--   a home submission becoming received (receipt), needs_attention or rejected (to the student and linked parents),
--   and a new script exception of a kind staff must see (staff_alert, to the active owner and admin accounts).
-- The script-notify Edge Function (called every minute by pg_cron through pg_net) sends them. Who gets an email is
-- worked out when it is sent, from the accounts as they are then. Each notice is claimed before it is sent
-- (script_notice_next), so two runs never send the same one; a failed one is tried again after a growing wait, up
-- to 3 times, and nothing older than 6 hours is sent, so turning email on later cannot announce old events.
-- Each recipient is recorded (script_notices_sent) just before their email goes out and forgotten only if that send
-- fails, so a failure, timeout or crash never makes a later run email someone twice; a notice is finished when
-- everyone is recorded.
-- A student notice is queued once per submission and kind: a re-check that flips a submission back to received
-- does not send the receipt again, and a new submission has its own receipt.

create table public.script_notices (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('receipt', 'needs_attention', 'rejected', 'staff_alert')),
  script_id uuid references public.scripts (id) on delete set null,
  submission_id uuid references public.home_submissions (id) on delete cascade,
  -- A re-run deletes and recreates exceptions: the notice keeps what the alert needs (exam, kind) and survives.
  exception_id uuid references public.script_exceptions (id) on delete set null,
  exam_id uuid,
  exception_kind text,
  -- exam, kind, booking, upload and page of the exception: the same alert is not queued twice within 6 hours
  dedupe_key text,
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  sent_at timestamptz,
  attempts int not null default 0,
  constraint script_notices_owner check (
    (kind = 'staff_alert' and exam_id is not null and exception_kind is not null)
    or (kind <> 'staff_alert' and submission_id is not null))
);
create index script_notices_dedupe_idx on public.script_notices (dedupe_key, created_at) where dedupe_key is not null;

-- One row per notice and person, recorded just before the email is sent and removed only when that send fails
-- (ids only: no address or name), so nobody gets the same notice twice, whatever fails or overlaps.
create table public.script_notices_sent (
  notice_id bigint not null references public.script_notices (id) on delete cascade,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  sent_at timestamptz not null default now(),
  primary key (notice_id, profile_id)
);
alter table public.script_notices_sent enable row level security;
revoke all on public.script_notices_sent from public, anon, authenticated, service_role;
grant select on public.script_notices_sent to service_role;
create unique index script_notices_once_per_submission on public.script_notices (kind, submission_id)
  where kind <> 'staff_alert';
create unique index script_notices_once_per_exception on public.script_notices (exception_id)
  where kind = 'staff_alert';
create index script_notices_open_idx on public.script_notices (created_at, id) where sent_at is null;

alter table public.script_notices enable row level security;
revoke all on public.script_notices from public, anon, authenticated, service_role;
revoke all on sequence public.script_notices_id_seq from public, anon, authenticated, service_role;
grant select on public.script_notices to service_role;

-- ---------------------------------------------------------------------------------------------
-- Queueing (triggers).
-- ---------------------------------------------------------------------------------------------
create function public.script_notice_on_submission()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kind text := case new.state::text
    when 'received' then 'receipt'
    when 'needs_attention' then 'needs_attention'
    when 'rejected' then 'rejected'
  end;
begin
  if v_kind is null then
    return null;
  end if;
  insert into public.script_notices (kind, script_id, submission_id)
  values (v_kind, (select s.id from public.scripts s where s.booking_id = new.booking_id), new.id)
  on conflict do nothing;
  return null;
end;
$$;
create trigger home_submissions_notice after update of state on public.home_submissions
  for each row when (old.state is distinct from new.state) execute function public.script_notice_on_submission();

create function public.script_notice_on_exception()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text;
begin
  v_key := concat_ws('|', new.exam_id, new.kind, coalesce(new.booking_id::text, '-'), coalesce(new.upload_id::text, '-'),
    coalesce(new.page_id::text, '-'));
  if exists (select 1 from public.script_notices n
             where n.dedupe_key = v_key and n.created_at > now() - interval '6 hours') then
    return null; -- a re-run recreated an exception already announced
  end if;
  insert into public.script_notices (kind, script_id, exception_id, exam_id, exception_kind, dedupe_key)
  values ('staff_alert',
    coalesce(new.script_id, (select s.id from public.scripts s where s.booking_id = new.booking_id)), new.id,
    new.exam_id, new.kind::text, v_key)
  on conflict do nothing;
  return null;
end;
$$;
create trigger script_exceptions_notice after insert on public.script_exceptions
  for each row when (new.kind in ('late', 'processing_failed', 'uncoded_family_page', 'not_expected', 'other_exam'))
  execute function public.script_notice_on_exception();

revoke execute on function public.script_notice_on_submission() from public, anon, authenticated, service_role;
revoke execute on function public.script_notice_on_exception() from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Sending (service role, from the Edge Function).
-- ---------------------------------------------------------------------------------------------

-- Who a notice goes to, as [{email, first_name}], one per address, from the accounts as they are now.
create function public.script_notice_recipients(p_notice public.script_notices)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('profile_id', x.id, 'email', x.email, 'first_name', x.first_name)
    order by lower(x.email)), '[]'::jsonb)
  from (
    select distinct on (lower(r.email)) r.id, r.email, r.first_name
    from (
      select p.id, p.email::text as email, p.first_name, 0 as rnk
      from public.home_submissions h
      join public.bookings b on b.id = h.booking_id
      join public.profiles p on p.id = b.student_id and p.status = 'active'
      where p_notice.kind <> 'staff_alert' and h.id = p_notice.submission_id
      union all
      select p.id, p.email::text, p.first_name, 1
      from public.home_submissions h
      join public.bookings b on b.id = h.booking_id
      join public.parent_children pc on pc.student_id = b.student_id
      join public.profiles p on p.id = pc.parent_id and p.status = 'active'
      where p_notice.kind <> 'staff_alert' and h.id = p_notice.submission_id
      union all
      select p.id, p.email::text, p.first_name, 0
      from public.profiles p
      where p_notice.kind = 'staff_alert' and p.status = 'active' and p.role in ('owner', 'admin')
    ) r
    where r.email is not null and r.email <> ''
      and not exists (select 1 from public.script_notices_sent s where s.notice_id = p_notice.id and s.profile_id = r.id)
    order by lower(r.email), r.rnk
  ) x
$$;

-- What the email says, as jsonb. Staff alerts never carry a candidate's name.
create function public.script_notice_content(p_notice public.script_notices)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_sub public.home_submissions%rowtype;
  v_script public.scripts%rowtype;
  v_exam uuid;
  v_label text;
  v_pages int[];
begin
  if p_notice.kind = 'staff_alert' then
    v_exam := p_notice.exam_id;
  else
    select * into v_sub from public.home_submissions h where h.id = p_notice.submission_id;
    select b.exam_id into v_exam from public.bookings b where b.id = v_sub.booking_id;
  end if;
  select * into v_script from public.scripts s where s.id = p_notice.script_id;
  select case when coalesce(btrim(e.paper), '') <> '' and position(lower(btrim(e.paper)) in lower(e.title)) = 0
              then e.title || ' ' || btrim(e.paper) else e.title end
  into v_label from public.exams e where e.id = v_exam;
  select coalesce(array_agg(l.copy_page order by l.copy_page), '{}') into v_pages
  from public.script_page_links l where l.script_id = v_script.id and l.version = v_script.version;

  return jsonb_build_object(
    'exam', v_label,
    'script_number', v_script.number,
    'submission_seq', v_sub.seq,
    'at', coalesce(v_sub.checked_at, v_sub.submitted_at, p_notice.created_at),
    'page_count', cardinality(v_pages),
    'pages', to_jsonb(v_pages),
    'exception_kind', p_notice.exception_kind);
end;
$$;

-- Claims up to p_limit notices that are due and returns them as a jsonb array
-- [{id, kind, recipients, exam, script_number, submission_seq, at, page_count, pages, exception_kind}]. Claimed means
-- claimed_at = now and attempts + 1; a notice is due when unsent, under 6 hours old, under 3 attempts, and not
-- claimed within the last 5 minutes times its attempts (so a failed or crashed run is retried after 5, then 10
-- minutes).
create function public.script_notice_next(p_limit int, p_now timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  v_out jsonb := '[]'::jsonb;
  v_n public.script_notices%rowtype;
  v_rec jsonb;
begin
  for v_n in
    select n.* from public.script_notices n
    where n.sent_at is null
      and n.attempts < 3
      and n.created_at > v_now - interval '6 hours'
      and (n.claimed_at is null or n.claimed_at <= v_now - n.attempts * interval '5 minutes')
    order by n.created_at, n.id
    limit greatest(coalesce(p_limit, 0), 0)
    for update skip locked
  loop
    update public.script_notices set claimed_at = v_now, attempts = attempts + 1 where id = v_n.id
    returning * into v_n;
    v_rec := public.script_notice_recipients(v_n);
    if jsonb_array_length(v_rec) = 0 then
      -- everyone was already recorded (a run stopped before marking): nothing left to send
      update public.script_notices set sent_at = v_now where id = v_n.id;
      continue;
    end if;
    v_out := v_out || (jsonb_build_object('id', v_n.id, 'kind', v_n.kind, 'recipients', v_rec)
      || public.script_notice_content(v_n));
  end loop;
  return v_out;
end;
$$;

-- The run's result for a claimed notice: sent (p_ok) or failed (it stays claimed, so the wait above applies).
create function public.script_notice_mark(p_id bigint, p_ok boolean, p_now timestamptz default null)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.script_notices set sent_at = coalesce(p_now, now())
  where id = p_id and sent_at is null and coalesce(p_ok, false)
$$;

-- Records a recipient just before the email is sent. ok: send it. already: someone else did (do not send).
-- stopped: the notice is already sent.
create function public.script_notice_record(p_id bigint, p_profile uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.script_notices n where n.id = p_id and n.sent_at is null) then
    return 'stopped';
  end if;
  insert into public.script_notices_sent (notice_id, profile_id) values (p_id, p_profile) on conflict do nothing;
  return case when found then 'ok' else 'already' end;
end;
$$;

-- The email to this recipient failed: forget them so a later run can try again.
create function public.script_notice_unmark(p_id bigint, p_profile uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.script_notices_sent where notice_id = p_id and profile_id = p_profile
$$;

-- How many notices were given up (3 attempts, unsent) within the look-back window. A count only.
create function public.script_notice_given_up(p_now timestamptz default null)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int from public.script_notices n
  where n.sent_at is null and n.attempts >= 3 and n.created_at > coalesce(p_now, now()) - interval '6 hours'
$$;

revoke execute on function public.script_notice_recipients(public.script_notices) from public, anon, authenticated, service_role;
revoke execute on function public.script_notice_content(public.script_notices) from public, anon, authenticated, service_role;
revoke execute on function public.script_notice_next(int, timestamptz) from public, anon, authenticated;
revoke execute on function public.script_notice_mark(bigint, boolean, timestamptz) from public, anon, authenticated;
revoke execute on function public.script_notice_record(bigint, uuid) from public, anon, authenticated;
revoke execute on function public.script_notice_unmark(bigint, uuid) from public, anon, authenticated;
revoke execute on function public.script_notice_given_up(timestamptz) from public, anon, authenticated;
grant execute on function public.script_notice_record(bigint, uuid) to service_role;
grant execute on function public.script_notice_unmark(bigint, uuid) to service_role;
grant execute on function public.script_notice_given_up(timestamptz) to service_role;
grant execute on function public.script_notice_next(int, timestamptz) to service_role;
grant execute on function public.script_notice_mark(bigint, boolean, timestamptz) to service_role;

-- ---------------------------------------------------------------------------------------------
-- The cron tick (Vault secrets script_notify_url and cron_secret; with either missing it does nothing).
-- ---------------------------------------------------------------------------------------------
create function public.script_notify_tick()
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
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'script_notify_url';
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
revoke execute on function public.script_notify_tick() from public, anon, authenticated, service_role;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'script-notify') then
    perform cron.unschedule('script-notify');
  end if;
  perform cron.schedule('script-notify', '* * * * *', $job$select public.script_notify_tick()$job$);
end;
$$;
