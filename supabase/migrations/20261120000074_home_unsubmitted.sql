-- Phase 2 final review, fix wave (Ruling R40, I2 and m3): answers uploaded but never submitted.
--
-- Each file a family uploads shows "Uploaded", but Submit is a separate step. A family that left without pressing it
-- was invisible to staff, and at finish + 48 hours the cleanup deleted the files. Staff could not submit for them.
--   1. script_upload_never_handed_in: the stored files of a draft are never listed for deletion. Only files discarded
--      from a draft (after an hour) and files never finished (pending, from finish + 48 h) are, as before.
--   2. home_drafts_stored: the drafts that hold stored files, of active home bookings, once the exam has finished;
--      scripts_dashboard counts them (unsubmitted_drafts, and unsubmitted per exam); home_drafts_unsubmitted lists
--      them for staff.
--   3. home_submission_accept_draft: an admin or the owner submits such a draft for the family, with a reason kept in
--      the audit log. It is submitted exactly as the family's own submit does it (the same function,
--      home_submission_send), late when the clock says so (from finish + 2 h); the family's own time window does not
--      apply to staff. Files of the draft that never finished uploading are discarded.
--   4. (m3) script_upload_begin: one hand-in holds at most 120 files in all, discarded ones included
--      (too_many_files_total); at most 60 at a time, as before.

-- ---------------------------------------------------------------------------------------------
-- script_upload_never_handed_in: as 20261120000054, without a draft's stored files.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_upload_never_handed_in(p_upload uuid, p_now timestamptz)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.script_uploads u
    join public.home_submissions s on s.id = u.submission_id
    join public.bookings b on b.id = s.booking_id
    join public.exams e on e.id = b.exam_id
    where u.id = p_upload
      and ((u.state = 'discarded' and u.discarded_at < p_now - interval '1 hour')
           or (u.state = 'pending'
               and p_now >= e.starts_at + e.duration_minutes * interval '1 minute' + interval '48 hours')))
$$;

-- The drafts that hold answers not sent: a draft submission of an active home booking with at least one stored file,
-- once the exam has finished (until then the family is still at work).
create function public.home_drafts_stored(p_now timestamptz)
returns table (submission_id uuid, booking_id uuid, exam_id uuid, files int, last_file_at timestamptz, late boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select s.id, b.id, b.exam_id, t.files, t.last_file_at,
    p_now >= e.starts_at + e.duration_minutes * interval '1 minute' + interval '2 hours'
  from public.home_submissions s
  join public.bookings b on b.id = s.booking_id
  join public.exams e on e.id = b.exam_id
  cross join lateral (
    select count(*)::int as files, max(u.created_at) as last_file_at
    from public.script_uploads u where u.submission_id = s.id and u.state = 'stored'
  ) t
  where s.state = 'draft' and t.files > 0
    and b.sitting = 'home' and b.status in ('paid', 'cancel_requested')
    and p_now >= e.starts_at + e.duration_minutes * interval '1 minute'
$$;
revoke execute on function public.home_drafts_stored(timestamptz) from public, anon, authenticated, service_role;

-- The same for staff (admin or owner): each draft with its candidate, exam, stored files, when the last one arrived
-- and whether accepting it now would mark it late. p_exam narrows it to one exam.
create function public.home_drafts_unsubmitted(p_exam uuid default null, p_now timestamptz default null)
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
             'files', d.files, 'last_file_at', d.last_file_at, 'late', d.late)
           order by e.starts_at, e.id, d.last_file_at, d.submission_id), '[]'::jsonb)
    from public.home_drafts_stored(v_now) d
    join public.exams e on e.id = d.exam_id
    where p_exam is null or d.exam_id = p_exam));
end;
$$;
revoke execute on function public.home_drafts_unsubmitted(uuid, timestamptz) from public, anon;
grant execute on function public.home_drafts_unsubmitted(uuid, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- home_submission_send: what submitting a draft does, once every check has passed and the booking is locked (the
-- second half of home_submission_submit as 20261120000066, word for word): the submission is "checking", late from
-- finish + 2 h, its stored files are queued with a prepare job each, a late one raises the late exception, and the
-- script is worked out again. Called by the family's submit and by the staff's accept.
-- ---------------------------------------------------------------------------------------------
create function public.home_submission_send(p_submission uuid, p_actor uuid, p_now timestamptz)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := p_now;
  v_actor uuid := p_actor;
  v_s public.home_submissions%rowtype;
  v_b public.bookings%rowtype;
  v_e public.exams%rowtype;
  v_prev public.home_submissions%rowtype;
  v_late boolean;
  v_script uuid;
begin
  select * into v_s from public.home_submissions s where s.id = p_submission for update;
  select * into v_b from public.bookings b where b.id = v_s.booking_id;
  select * into v_e from public.exams e where e.id = v_b.exam_id;
  v_late := v_now >= v_e.starts_at + v_e.duration_minutes * interval '1 minute' + interval '2 hours';
  if not v_s.replaces_all then
    select * into v_prev from public.home_submissions s
    where s.booking_id = v_b.id and s.state not in ('draft', 'rejected')
    order by s.seq desc limit 1;
  end if;
  update public.home_submissions
  set state = 'checking', submitted_by = v_actor, submitted_at = v_now, late = v_late,
      blank_confirmed = coalesce(v_prev.blank_confirmed, v_s.blank_confirmed)
  where id = v_s.id
  returning * into v_s;
  update public.script_uploads set state = 'queued' where submission_id = v_s.id and state = 'stored';
  insert into public.processing_jobs (upload_id, kind)
  select u.id, 'prepare' from public.script_uploads u where u.submission_id = v_s.id and u.state = 'queued' order by u.position, u.id;

  select x.id into v_script from public.scripts x where x.booking_id = v_b.id;
  if v_late then
    update public.scripts set late = true where id = v_script and not late;
    insert into public.script_exceptions (exam_id, kind, booking_id, script_id, details)
    select v_b.exam_id, 'late', v_b.id, v_script, jsonb_build_object('submission_id', v_s.id, 'seq', v_s.seq)
    where not exists (select 1 from public.script_exceptions e where e.booking_id = v_b.id and e.kind = 'late' and e.state = 'open');
  end if;
  if v_script is not null then
    perform public.script_evaluate_at(v_script, v_now);
  end if;
end;
$$;
revoke execute on function public.home_submission_send(uuid, uuid, timestamptz) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- home_submission_submit: as 20261120000066; what it does once every check has passed is home_submission_send.
-- ---------------------------------------------------------------------------------------------
create or replace function public.home_submission_submit(p_submission uuid, p_now timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := public.paper_clock(p_now);
  v_s public.home_submissions%rowtype;
  v_b public.bookings%rowtype;
  v_code text;
begin
  if p_submission is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_s from public.home_submissions s where s.id = p_submission;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select * into v_b from public.bookings b where b.id = v_s.booking_id;
  v_code := public.home_upload_code(v_actor, v_b, null);
  if v_code is not null then
    return jsonb_build_object('ok', false, 'code', v_code);
  end if;

  perform public.home_booking_lock(v_b.id);
  select * into v_s from public.home_submissions s where s.id = p_submission for update;
  if v_s.state <> 'draft' then
    return public.home_submission_result(v_s.id);
  end if;
  if public.script_booking_locked(v_b.id) then
    return jsonb_build_object('ok', false, 'code', 'script_locked');
  end if;
  v_code := public.home_upload_code(v_actor, v_b, v_now);
  if v_code is not null then
    return jsonb_build_object('ok', false, 'code', v_code);
  end if;
  if exists (select 1 from public.script_uploads u where u.submission_id = v_s.id and u.state = 'pending') then
    return jsonb_build_object('ok', false, 'code', 'still_uploading');
  end if;
  if not exists (select 1 from public.script_uploads u where u.submission_id = v_s.id and u.state = 'stored') then
    return jsonb_build_object('ok', false, 'code', 'nothing_to_submit');
  end if;

  perform public.home_submission_send(v_s.id, v_actor, v_now);
  return public.home_submission_result(v_s.id);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- home_submission_accept_draft: an admin or the owner submits a family's draft for them (Ruling R40, I2), with a
-- reason. The draft must hold at least one stored file, the booking must be an active home booking and its script not
-- yet being marked. The family's time window does not apply. Files that never finished uploading are discarded first.
-- ---------------------------------------------------------------------------------------------
create function public.home_submission_accept_draft(p_submission uuid, p_reason text, p_now timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := public.paper_clock(p_now);
  v_reason text := public.script_resolution_reason(p_reason);
  v_s public.home_submissions%rowtype;
  v_b public.bookings%rowtype;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_submission is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  select * into v_s from public.home_submissions s where s.id = p_submission;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select * into v_b from public.bookings b where b.id = v_s.booking_id;

  perform public.home_booking_lock(v_b.id);
  select * into v_s from public.home_submissions s where s.id = p_submission for update;
  if v_s.state <> 'draft' then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  select * into v_b from public.bookings b where b.id = v_s.booking_id;
  if v_b.sitting <> 'home' or v_b.status not in ('paid', 'cancel_requested') then
    return jsonb_build_object('ok', false, 'code', 'booking_not_active');
  end if;
  if public.script_booking_locked(v_b.id) then
    return jsonb_build_object('ok', false, 'code', 'script_locked');
  end if;
  if not exists (select 1 from public.script_uploads u where u.submission_id = v_s.id and u.state = 'stored') then
    return jsonb_build_object('ok', false, 'code', 'nothing_to_submit');
  end if;

  update public.script_uploads set state = 'discarded', discarded_at = now()
  where submission_id = v_s.id and state = 'pending';
  perform public.home_submission_send(v_s.id, v_actor, v_now);
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'home_submission_draft_accepted', 'home_submission', v_s.id, v_reason);
  select * into v_s from public.home_submissions s where s.id = v_s.id;
  return jsonb_build_object('ok', true, 'submission_id', v_s.id, 'state', v_s.state, 'late', v_s.late,
    'files', (select count(*) from public.script_uploads u where u.submission_id = v_s.id and u.state <> 'discarded'));
end;
$$;
revoke execute on function public.home_submission_accept_draft(uuid, text, timestamptz) from public, anon;
grant execute on function public.home_submission_accept_draft(uuid, text, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- script_upload_begin: as 20261120000054, and at most 120 files in all for one hand-in (Ruling R40, m3).
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_upload_begin(
  p_submission uuid,
  p_kind public.upload_kind,
  p_mime text,
  p_bytes bigint,
  p_now timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := public.paper_clock(p_now);
  v_s public.home_submissions%rowtype;
  v_b public.bookings%rowtype;
  v_e public.exams%rowtype;
  v_code text;
  v_mime text := lower(btrim(coalesce(p_mime, '')));
  v_id uuid := gen_random_uuid();
  v_path text;
  v_pos int;
begin
  if p_submission is null or p_kind is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_s from public.home_submissions s where s.id = p_submission;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select * into v_b from public.bookings b where b.id = v_s.booking_id;
  v_code := public.home_upload_code(v_actor, v_b, v_now);
  if v_code is not null then
    return jsonb_build_object('ok', false, 'code', v_code);
  end if;
  if p_kind not in ('home_photo', 'home_pdf') or p_bytes is null or p_bytes <= 0 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if not public.home_upload_type_ok(p_kind, v_mime) then
    return jsonb_build_object('ok', false, 'code', 'wrong_file_type');
  end if;
  if p_bytes > public.home_upload_max_bytes(p_kind) then
    return jsonb_build_object('ok', false, 'code', 'file_too_large');
  end if;

  perform public.home_booking_lock(v_b.id);
  select * into v_s from public.home_submissions s where s.id = p_submission for update;
  if v_s.state <> 'draft' then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  if (select count(*) from public.script_uploads u where u.submission_id = v_s.id and u.state <> 'discarded') >= 60 then
    return jsonb_build_object('ok', false, 'code', 'too_many_files');
  end if;
  -- Discarded files count towards a larger limit, so adding and removing files cannot fill the storage (Ruling R40, m3).
  if (select count(*) from public.script_uploads u where u.submission_id = v_s.id) >= 120 then
    return jsonb_build_object('ok', false, 'code', 'too_many_files_total');
  end if;
  select coalesce(max(u.position), 0) + 1 into v_pos
  from public.script_uploads u where u.submission_id = v_s.id and u.state <> 'discarded';
  v_path := 'home/' || v_b.id::text || '/' || v_id::text || '.'
    || case v_mime when 'image/jpeg' then 'jpg' when 'image/png' then 'png' when 'image/heic' then 'heic'
                   when 'image/heif' then 'heif' else 'pdf' end;
  insert into public.script_uploads (id, exam_id, booking_id, submission_id, kind, position, storage_path, mime, byte_size, uploaded_by)
  values (v_id, v_b.exam_id, v_b.id, v_s.id, p_kind, v_pos, v_path, v_mime, p_bytes, v_actor);

  select * into v_e from public.exams e where e.id = v_b.exam_id;
  return jsonb_build_object('ok', true, 'upload_id', v_id, 'storage_path', v_path, 'position', v_pos,
    'late', v_now >= v_e.starts_at + v_e.duration_minutes * interval '1 minute' + interval '2 hours');
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- scripts_dashboard: as 20261120000070, and the drafts with stored files never submitted (unsubmitted_drafts; per
-- exam: unsubmitted).
-- ---------------------------------------------------------------------------------------------
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
                    where s.exam_id = e.id and s.late and s.state not in ('withdrawn', 'void')),
           'unsubmitted', (select count(*) from public.home_drafts_stored(v_now) d where d.exam_id = e.id))
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
    'unsubmitted_drafts', (select count(*) from public.home_drafts_stored(v_now)),
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
