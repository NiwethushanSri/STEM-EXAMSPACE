-- Phase 3A, Task 0: Phase 2's five small fixes before launch (found by the review of Phase 2).
--
--   1. paper_notice_next: as 20261118000049, and a release or corrected notice is handed out only while the exam's
--      current paper has pages_reviewed_at set. Migration 20261120000075 refuses every candidate copy until an admin
--      has saved the page roles, so an email that says "your paper is ready" must wait for them. Nothing is dropped:
--      the notice stays open and goes out once the roles are saved, inside its window.
--   2. home_drafts_unsubmitted: as 20261120000074, and each item says whether submitting the draft replaces pages the
--      family already handed in: replaces_received (the booking has a submission that is not a draft or rejected),
--      replaces_all (the draft replaces every page) and received_pages (the pages of the script's current version).
--   3. Family emails can be skipped. script_notices.skipped_at: script_notice_next (as 20261120000076) and
--      script_notice_given_up (as 20261120000076) leave a skipped notice alone. script_family_notices_waiting counts
--      the family emails still to be sent; script_family_notices_skip skips them all, for an admin, with a reason kept
--      in the audit log. Staff alerts are never skipped.
-- (The fourth and fifth fixes are in the web app and the processing server's tests.)

-- ---------------------------------------------------------------------------------------------
-- 1. paper_notice_next: as 20261118000049, and the current paper's page roles must have been saved.
-- ---------------------------------------------------------------------------------------------
create or replace function public.paper_notice_next(p_exclude bigint[] default '{}', p_now timestamptz default now())
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
        and p.pages_reviewed_at is not null
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

-- ---------------------------------------------------------------------------------------------
-- 2. home_drafts_unsubmitted: as 20261120000074, and what submitting the draft replaces.
-- ---------------------------------------------------------------------------------------------
create or replace function public.home_drafts_unsubmitted(p_exam uuid default null, p_now timestamptz default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := public.paper_clock(p_now);
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  return jsonb_build_object('ok', true, 'now', v_now, 'items', (
    select coalesce(jsonb_agg(jsonb_build_object(
             'submission_id', d.submission_id,
             'booking', public.script_booking_json(d.booking_id),
             'exam', jsonb_build_object('id', e.id, 'title', e.title, 'paper', e.paper, 'starts_at', e.starts_at),
             'files', d.files, 'last_file_at', d.last_file_at, 'late', d.late,
             'replaces_received', exists (select 1 from public.home_submissions r
                                          where r.booking_id = d.booking_id and r.state not in ('draft', 'rejected')),
             'replaces_all', s.replaces_all,
             'received_pages', (select count(*)::int from public.scripts x
                                join public.script_page_links l on l.script_id = x.id and l.version = x.version
                                where x.booking_id = d.booking_id))
           order by e.starts_at, e.id, d.last_file_at, d.submission_id), '[]'::jsonb)
    from public.home_drafts_stored(v_now) d
    join public.exams e on e.id = d.exam_id
    join public.home_submissions s on s.id = d.submission_id
    where p_exam is null or d.exam_id = p_exam));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. Family emails that staff chose not to send.
-- ---------------------------------------------------------------------------------------------
alter table public.script_notices add column skipped_at timestamptz;

-- script_notice_next: as 20261120000076, and a skipped notice is never handed out.
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
      and n.skipped_at is null
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

-- script_notice_given_up: as 20261120000076, without the skipped notices (they were chosen, not given up).
create or replace function public.script_notice_given_up(p_now timestamptz default null)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int from public.script_notices n
  where n.sent_at is null
    and n.skipped_at is null
    and case when n.kind = 'staff_alert'
             then n.attempts >= 3 and n.created_at > coalesce(p_now, now()) - interval '6 hours'
             else n.created_at <= coalesce(p_now, now()) - interval '7 days'
                  and n.created_at > coalesce(p_now, now()) - interval '7 days 6 hours'
        end
$$;

-- How many family emails (receipts, needs attention, rejected) are still to be sent, and when the oldest was queued.
create function public.script_family_notices_waiting()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_count int;
  v_oldest timestamptz;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select count(*)::int, min(n.created_at) into v_count, v_oldest
  from public.script_notices n
  where n.sent_at is null and n.skipped_at is null and n.kind <> 'staff_alert';
  return jsonb_build_object('ok', true, 'count', v_count, 'oldest', v_oldest);
end;
$$;

-- Skips every family email still to be sent, with a reason kept in the audit log. Staff alerts are not touched.
create function public.script_family_notices_skip(p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_skipped int;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  update public.script_notices set skipped_at = now()
  where sent_at is null and skipped_at is null and kind <> 'staff_alert';
  get diagnostics v_skipped = row_count;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'script_family_notices_skipped', 'script_notices', null, v_reason);
  return jsonb_build_object('ok', true, 'skipped', v_skipped);
end;
$$;

revoke execute on function public.script_family_notices_waiting() from public, anon;
revoke execute on function public.script_family_notices_skip(text) from public, anon;
grant execute on function public.script_family_notices_waiting() to authenticated;
grant execute on function public.script_family_notices_skip(text) to authenticated;
