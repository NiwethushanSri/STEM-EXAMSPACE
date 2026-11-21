-- Phase 2 Task 12: the scripts part of the operations dashboard (admin home).
--
-- scripts_dashboard(p_now) answers, for owners and admins:
--   exams: every exam that started in the last 14 days (not cancelled), oldest first, with
--     expected        = paid bookings (status paid or cancel_requested) sitting at home, plus those sitting at a
--                       centre whose candidate is marked present or late;
--     received        = the exam's scripts (not withdrawn or void);
--     verified        = scripts verified or further on (ready to mark, marking, marked, checked, final);
--     needs_attention = scripts that need attention;
--     late            = scripts handed in late (not withdrawn or void);
--   open_exceptions: open problems in the exception queue (every exam);
--   failed_jobs: processing jobs that failed for good in the last 14 days with no later job for the same file;
--   oldest_queued_minutes: how long the oldest job due to run has waited (null when none waits), so a stopped
--     processing server shows;
--   centres_without_scanned_custody: centres of those exams with sheets counted (collection counts) but no
--     "scanned" custody record, once 09:00 (UK time) the day after the exam has passed.
-- Anyone else gets {ok:false, code:'forbidden'}.

create function public.scripts_dashboard(p_now timestamptz default null)
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
  where e.status <> 'cancelled' and e.starts_at <= v_now and e.starts_at > v_now - interval '14 days';

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
  where e.status <> 'cancelled' and e.starts_at <= v_now and e.starts_at > v_now - interval '14 days'
    and t.counted > 0 and v_now >= t.due
    and not exists (select 1 from public.custody_events ce
                    where ce.exam_id = e.id and ce.centre_id = ec.id and ce.step = 'scanned');

  select min(j.run_after) into v_oldest
  from public.processing_jobs j where j.state = 'queued' and j.run_after <= v_now;

  return jsonb_build_object('ok', true, 'now', v_now, 'exams', v_exams,
    'open_exceptions', (select count(*) from public.script_exceptions x where x.state = 'open'),
    'failed_jobs', (select count(*) from public.processing_jobs j
                    where j.state = 'failed' and coalesce(j.finished_at, j.created_at) > v_now - interval '14 days'
                      and not exists (select 1 from public.processing_jobs n
                                      where n.upload_id = j.upload_id and n.kind = j.kind and n.id > j.id)),
    'oldest_queued_minutes', case when v_oldest is not null
                                  then floor(extract(epoch from v_now - v_oldest) / 60)::int end,
    'centres_without_scanned_custody', v_centres);
end;
$$;

revoke execute on function public.scripts_dashboard(timestamptz) from public, anon;
grant execute on function public.scripts_dashboard(timestamptz) to authenticated;
