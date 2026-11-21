-- Phase 2 final review, fix wave (Ruling R40, I6): staff alerts by file, family notices first, receipts kept.
--
-- 055 queued one staff alert for every page with a problem. A scan of a centre whose register was not marked raised
-- "not expected" for every page of the file: hundreds of emails, sent at two a second, with the families' receipts
-- waiting behind them; and nothing older than 6 hours was ever sent, a receipt included.
--   - One staff alert per kind of problem and per file (for a family's hand-in: per hand-in), or per exam for a
--     problem that has no file. Problems of the same kind that arrive while that alert still waits to be sent join it;
--     the email says how many it is about (script_notice_content: count, worked out when the notice is handed out).
--     A rerun that raises a file's problems again is not announced twice (6 hours, as before).
--   - script_notice_next hands out the families' notices (receipt, needs attention, rejected) before staff alerts.
--   - A family's notice is never dropped quietly: it is tried for 7 days (the wait between tries grows to an hour) and
--     then counted as given up, which the function logs. Staff alerts keep 3 tries and 6 hours.
--   - A home script that comes to need attention queues a staff alert (spec 5.3), once per script; the scripts of one
--     exam share the alert that is still waiting.
-- Which problems email staff: late, processing_failed, uncoded_family_page, not_expected, other_exam, and a home
-- script needing attention. The others are in the exception queue and on the admin home page only.

-- The file a staff alert is about (a family's hand-in: its submission; a scan: its file); null when it has none.
alter table public.script_notices add column group_id uuid;
-- When a home script's "needs attention" was first told to staff (once per script).
alter table public.scripts add column attention_notified_at timestamptz;

-- ---------------------------------------------------------------------------------------------
-- script_notice_on_exception: as 20261120000055, keyed by exam, kind and file (not by page).
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_notice_on_exception()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group uuid;
  v_key text;
begin
  select coalesce(u.submission_id, u.id) into v_group from public.script_uploads u where u.id = new.upload_id;
  v_key := concat_ws('|', new.exam_id, new.kind, coalesce(v_group::text, '-'));
  -- An alert about the same kind and file still waits to be sent: this problem joins it (it is counted when sent).
  if exists (select 1 from public.script_notices n
             where n.dedupe_key = v_key and n.kind = 'staff_alert' and n.sent_at is null and n.claimed_at is null
               and n.created_at > now() - interval '6 hours') then
    return null;
  end if;
  -- A file's problems were announced already: a re-run that raises them again says nothing new.
  if v_group is not null and exists (select 1 from public.script_notices n
                                     where n.dedupe_key = v_key and n.created_at > now() - interval '6 hours') then
    return null;
  end if;
  insert into public.script_notices (kind, script_id, exception_id, exam_id, exception_kind, dedupe_key, group_id)
  values ('staff_alert',
    coalesce(new.script_id, (select s.id from public.scripts s where s.booking_id = new.booking_id)), new.id,
    new.exam_id, new.kind::text, v_key, v_group)
  on conflict do nothing;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- A home script that comes to need attention: a staff alert, once per script (spec 5.3). The scripts of one exam
-- share the alert that still waits to be sent.
-- ---------------------------------------------------------------------------------------------
create function public.script_notice_on_attention()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text := concat_ws('|', new.exam_id, 'needs_attention', '-');
begin
  new.attention_notified_at := now();
  if not exists (select 1 from public.script_notices n
                 where n.dedupe_key = v_key and n.kind = 'staff_alert' and n.sent_at is null and n.claimed_at is null
                   and n.created_at > now() - interval '6 hours') then
    insert into public.script_notices (kind, script_id, exam_id, exception_kind, dedupe_key)
    values ('staff_alert', new.id, new.exam_id, 'needs_attention', v_key);
  end if;
  return new;
end;
$$;
create trigger scripts_attention_notice before update of state on public.scripts
  for each row
  when (new.state = 'needs_attention' and old.state is distinct from new.state and new.source = 'home'
        and new.attention_notified_at is null)
  execute function public.script_notice_on_attention();
revoke execute on function public.script_notice_on_attention() from public, anon, authenticated, service_role;

-- How many problems a staff alert is about: the exceptions of its exam, kind and file raised since it was queued (the
-- home scripts first told to staff since then, for "needs attention"). At least 1.
create function public.script_notice_count(p_notice public.script_notices)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select greatest(1, case
    when p_notice.kind <> 'staff_alert' then 1
    when p_notice.exception_kind = 'needs_attention' then (
      select count(*)::int from public.scripts s
      where s.exam_id = p_notice.exam_id and s.source = 'home' and s.attention_notified_at >= p_notice.created_at)
    else (
      select count(*)::int from public.script_exceptions e
      where e.exam_id = p_notice.exam_id and e.kind::text = p_notice.exception_kind and e.created_at >= p_notice.created_at
        and case when p_notice.group_id is null then e.upload_id is null
                 else e.upload_id in (select u.id from public.script_uploads u
                                      where u.id = p_notice.group_id or u.submission_id = p_notice.group_id) end)
  end)
$$;
revoke execute on function public.script_notice_count(public.script_notices) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- script_notice_content: as 20261120000055, and count (how many problems a staff alert is about).
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_notice_content(p_notice public.script_notices)
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
    'exception_kind', p_notice.exception_kind,
    'count', public.script_notice_count(p_notice));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_notice_next: as 20261120000055, and
--   - the families' notices come first, then staff alerts, each oldest first;
--   - a staff alert is due when unsent, under 6 hours old, under 3 attempts, and not claimed within the last 5
--     minutes times its attempts (as before);
--   - a family's notice is due when unsent, under 7 days old, and not claimed within the last 5 minutes times its
--     attempts, at most an hour: it has no limit of attempts.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_notice_next(p_limit int, p_now timestamptz default null)
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
      and case when n.kind = 'staff_alert'
               then n.attempts < 3
                    and n.created_at > v_now - interval '6 hours'
                    and (n.claimed_at is null or n.claimed_at <= v_now - n.attempts * interval '5 minutes')
               else n.created_at > v_now - interval '7 days'
                    and (n.claimed_at is null or n.claimed_at <= v_now - least(n.attempts * 5, 60) * interval '1 minute')
          end
    order by (n.kind = 'staff_alert'), n.created_at, n.id
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

-- ---------------------------------------------------------------------------------------------
-- script_notice_given_up: as 20261120000055 for staff alerts (3 attempts, unsent, within 6 hours), and the families'
-- notices that passed their 7 days unsent within the last 6 hours. A count only; the function logs it.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_notice_given_up(p_now timestamptz default null)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int from public.script_notices n
  where n.sent_at is null
    and case when n.kind = 'staff_alert'
             then n.attempts >= 3 and n.created_at > coalesce(p_now, now()) - interval '6 hours'
             else n.created_at <= coalesce(p_now, now()) - interval '7 days'
                  and n.created_at > coalesce(p_now, now()) - interval '7 days 6 hours'
        end
$$;
