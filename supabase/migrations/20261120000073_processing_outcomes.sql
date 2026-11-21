-- Phase 2 final review, fix wave (Ruling R40, I1): a file of too many pages.
--
-- The processing server now reads a file's page count before it renders anything. A file of more than 5000 pages (the
-- most script_pages_record takes) is failed with the error word too_many_pages, with nothing rendered or stored:
--   processing_job_finish: that word fails a prepare job at once, whatever its attempt (the file is the same every
--     time); every other failure is tried again as before;
--   processing_job_fail: the processing_failed exception of such a file says why (details.reason = too_many_pages),
--     so the queue can tell staff to split the file. The word is one this system chose: no file name, path or content.
-- Both functions keep their access.

-- ---------------------------------------------------------------------------------------------
-- processing_job_finish: as 20261120000059, and too_many_pages fails a prepare job at once.
-- ---------------------------------------------------------------------------------------------
create or replace function public.processing_job_finish(
  p_job bigint,
  p_worker text,
  p_attempt int,
  p_ok boolean,
  p_error text default null,
  p_now timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  v_job public.processing_jobs%rowtype;
begin
  select * into v_job from public.processing_jobs j where j.id = p_job for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_job.state <> 'running' or v_job.locked_by is distinct from left(coalesce(p_worker, ''), 100)
     or v_job.attempts is distinct from p_attempt then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  if p_ok is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  if p_ok then
    update public.processing_jobs set state = 'done', finished_at = v_now, locked_by = null, locked_at = null
    where id = v_job.id;
    return jsonb_build_object('ok', true, 'state', 'done');
  end if;

  -- A file of too many pages is the same file at every attempt: it fails at once (Ruling R40, I1).
  if v_job.attempts < 3 and not (v_job.kind = 'prepare' and p_error = 'too_many_pages') then
    if exists (select 1 from public.processing_jobs j
               where j.upload_id = v_job.upload_id and j.kind = v_job.kind and j.state = 'queued' and j.id <> v_job.id) then
      update public.processing_jobs
      set state = 'done', finished_at = v_now, locked_by = null, locked_at = null, last_error = left(p_error, 300)
      where id = v_job.id;
      return jsonb_build_object('ok', true, 'state', 'superseded');
    end if;
    update public.processing_jobs
    set state = 'queued', run_after = v_now + v_job.attempts * interval '1 minute', locked_by = null, locked_at = null,
        last_error = left(p_error, 300)
    where id = v_job.id;
    return jsonb_build_object('ok', true, 'state', 'queued');
  end if;

  perform public.processing_job_fail(v_job, p_error, v_now);
  return jsonb_build_object('ok', true, 'state', 'failed');
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- processing_job_fail: as 20261120000062, and a prepare job's exception carries the reason too_many_pages.
-- ---------------------------------------------------------------------------------------------
create or replace function public.processing_job_fail(p_job public.processing_jobs, p_error text, p_now timestamptz)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_up public.script_uploads%rowtype;
  v_booking uuid;
  v_script uuid;
  v_bookings uuid[];
  v_page uuid;
begin
  update public.processing_jobs
  set state = 'failed', finished_at = p_now, locked_by = null, locked_at = null, last_error = left(p_error, 300)
  where id = p_job.id;
  if p_job.kind = 'prepare' then
    update public.script_uploads set state = 'failed' where id = p_job.upload_id returning * into v_up;
  else
    select * into v_up from public.script_uploads u where u.id = p_job.upload_id;
  end if;
  -- A home upload's booking is its submission's (script_uploads.booking_id may be empty).
  select s.booking_id into v_booking from public.home_submissions s where s.id = v_up.submission_id;
  v_booking := coalesce(v_booking, v_up.booking_id);

  if p_job.kind <> 'prepare' then
    select coalesce(array_agg(distinct s.booking_id order by s.booking_id), '{}') into v_bookings
    from public.script_pages p
    join public.script_page_links l on l.page_id = p.id
    join public.scripts s on s.id = l.script_id and l.version = s.version
    where p.upload_id = v_up.id and p.replaced_at is null;
    perform public.script_bookings_lock(v_bookings || v_booking || array(
      select distinct b from public.script_pages p cross join lateral unnest(public.script_page_owners(p.id)) b
      where p.upload_id = v_up.id and p.replaced_at is null));
    -- Its pages' marking pictures may have been made before the change that queued it: they go, and staff are told
    -- (Ruling R32 e).
    for v_page in
      select p.id from public.script_pages p
      where p.upload_id = v_up.id and p.replaced_at is null and p.marking_path is not null
        and (public.script_page_remask_context(p.id) ->> 'answer')::boolean
      order by p.id
      for update
    loop
      if public.script_page_locked(v_page) then
        -- A script already being marked keeps its pictures; staff are told they may be out of date (Ruling R33).
        perform public.script_page_marking_lost(v_page, false);
      else
        update public.script_pages set marking_path = null where id = v_page;
        perform public.script_page_marking_lost(v_page);
      end if;
    end loop;
    if cardinality(v_bookings) = 0 then
      insert into public.script_exceptions (exam_id, kind, booking_id, script_id, upload_id, details)
      values (v_up.exam_id, 'processing_failed', v_booking, (select x.id from public.scripts x where x.booking_id = v_booking), v_up.id,
        jsonb_build_object('job_id', p_job.id, 'kind', p_job.kind, 'attempts', p_job.attempts));
    else
      insert into public.script_exceptions (exam_id, kind, booking_id, script_id, upload_id, details)
      select v_up.exam_id, 'processing_failed', b, (select x.id from public.scripts x where x.booking_id = b), v_up.id,
        jsonb_build_object('job_id', p_job.id, 'kind', p_job.kind, 'attempts', p_job.attempts)
      from unnest(v_bookings) b order by b;
    end if;
    for v_script in
      select s.id from public.scripts s
      where s.booking_id = any (v_bookings || v_booking || array(
        select distinct b from public.script_pages p cross join lateral unnest(public.script_page_owners(p.id)) b
        where p.upload_id = v_up.id and p.replaced_at is null))
      order by s.booking_id
    loop
      perform public.script_evaluate_at(v_script, p_now);
    end loop;
    return;
  end if;

  insert into public.script_exceptions (exam_id, kind, booking_id, script_id, upload_id, details)
  values (v_up.exam_id, 'processing_failed', v_booking, (select x.id from public.scripts x where x.booking_id = v_booking), v_up.id,
    jsonb_build_object('job_id', p_job.id, 'kind', p_job.kind, 'attempts', p_job.attempts)
      || case when p_error = 'too_many_pages' then '{"reason": "too_many_pages"}'::jsonb else '{}'::jsonb end);
  if v_up.submission_id is not null then
    perform pg_advisory_xact_lock(hashtextextended('script_booking:' || v_booking::text, 0));
    if public.home_submission_assemble(v_up.submission_id, v_up.id, p_now) then
      perform public.script_raise_mixed(s.id, v_up.id) from public.scripts s where s.booking_id = v_booking;
    end if;
    perform public.home_submission_evaluate(v_up.submission_id, p_now);
  end if;
  for v_script in
    select s.id from public.scripts s where s.booking_id = v_booking
    union
    select l.script_id from public.script_page_links l join public.script_pages p on p.id = l.page_id
    where p.upload_id = v_up.id
  loop
    perform public.script_evaluate_at(v_script, p_now);
  end loop;
end;
$$;
