-- Phase 2 Task 12, fix round 1 (Ruling R39 2, 4, 5): the scripts dashboard as 20261120000068, and
--   failed_jobs: the files that could not be processed and that staff have not settled yet, one per file and kind of
--     job: an OPEN processing_failed exception. Noting it (confirm) or rejecting it takes it off the count, so the
--     alert clears once staff have dealt with every one (the 068 count of failed jobs could not be cleared);
--   exams and centres: only exams published or completed (no drafts);
--   stuck_jobs: jobs still "running" whose lock is older than 15 minutes (the server stopped part-way through a file;
--     a working server renews its lock every 30 seconds), and oldest_queued_minutes also counts them, from the time
--     the lock was last renewed, so a dead server shows on the tile and in the alert.

create or replace function public.scripts_dashboard(p_now timestamptz default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  v_exams jsonb;
  v_centres jsonb;
  v_oldest timestamptz;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'exam', jsonb_build_object('id', e.id, 'title', e.title, 'paper', e.paper, 'starts_at', e.starts_at),
           'expected', (select count(*) from public.bookings b
                        where b.exam_id = e.id and b.status in ('paid', 'cancel_requested') and b.student_id is not null
                          and (b.sitting = 'home'
                               or exists (select 1 from public.attendance a
                                          where a.exam_id = e.id and a.student_id = b.student_id
                                            and a.status in ('present', 'late')))),
           'received', (select count(*) from public.scripts s
                        where s.exam_id = e.id and s.state not in ('withdrawn', 'void')),
           'verified', (select count(*) from public.scripts s
                        where s.exam_id = e.id
                          and s.state in ('verified', 'ready_to_mark', 'marking', 'marked', 'checked', 'final')),
           'needs_attention', (select count(*) from public.scripts s where s.exam_id = e.id and s.state = 'needs_attention'),
           'late', (select count(*) from public.scripts s
                    where s.exam_id = e.id and s.late and s.state not in ('withdrawn', 'void')))
         order by e.starts_at, e.id), '[]'::jsonb)
  into v_exams
  from public.exams e
  where e.status in ('published', 'completed') and e.starts_at <= v_now and e.starts_at > v_now - interval '14 days';

  select coalesce(jsonb_agg(jsonb_build_object(
           'exam_id', e.id, 'title', e.title, 'paper', e.paper, 'starts_at', e.starts_at,
           'centre_id', ec.id, 'venue', v.name, 'room', ec.room, 'counted', t.counted,
           'scanned_by', t.due)
         order by e.starts_at, e.id, v.name, ec.room, ec.id), '[]'::jsonb)
  into v_centres
  from public.exams e
  join public.exam_centres ec on ec.exam_id = e.id
  join public.venues v on v.id = ec.venue_id
  cross join lateral (
    select (select count(*) from public.collection_counts cc
            join public.bookings b on b.id = cc.booking_id
            where cc.exam_id = e.id and b.centre_id = ec.id) as counted,
           ((((e.starts_at at time zone 'Europe/London')::date + 1) + time '09:00') at time zone 'Europe/London') as due
  ) t
  where e.status in ('published', 'completed') and e.starts_at <= v_now and e.starts_at > v_now - interval '14 days'
    and t.counted > 0 and v_now >= t.due
    and not exists (select 1 from public.custody_events ce
                    where ce.exam_id = e.id and ce.centre_id = ec.id and ce.step = 'scanned');

  -- The oldest wait: a queued job due to run (since it became due), or a running job whose lock went stale (since the
  -- lock was last renewed).
  select min(w) into v_oldest from (
    select j.run_after as w from public.processing_jobs j where j.state = 'queued' and j.run_after <= v_now
    union all
    select j.locked_at from public.processing_jobs j
    where j.state = 'running' and j.locked_at is not null and j.locked_at < v_now - interval '15 minutes'
  ) t;

  return jsonb_build_object('ok', true, 'now', v_now, 'exams', v_exams,
    'open_exceptions', (select count(*) from public.script_exceptions x where x.state = 'open'),
    'failed_jobs', (select count(*) from (
                      select distinct x.upload_id, coalesce(x.details ->> 'kind', 'prepare')
                      from public.script_exceptions x
                      where x.kind = 'processing_failed' and x.state = 'open') f),
    'stuck_jobs', (select count(*) from public.processing_jobs j
                   where j.state = 'running' and j.locked_at is not null and j.locked_at < v_now - interval '15 minutes'),
    'oldest_queued_minutes', case when v_oldest is not null
                                  then floor(extract(epoch from v_now - v_oldest) / 60)::int end,
    'centres_without_scanned_custody', v_centres);
end;
$$;
