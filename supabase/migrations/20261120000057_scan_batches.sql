-- Phase 2 Task 9: bulk scan upload.
--
-- After a centre exam, staff scan the collected scripts on the office scanner and upload the files as a scan batch of
-- one centre (scan_batch_create, optionally naming the collection manifest the scripts came with). Each file first
-- gets an upload row (scan_upload_begin: kind scan_file, a PDF, JPEG or PNG of up to 1 GiB) whose exact path the
-- storage policy lets the uploader fill; the web app uploads it (resumable) and script_upload_stored checks the
-- stored object against the row. "Start processing" (scan_batch_submit) queues a prepare job per stored file and
-- records the scanned custody step. The processing server prepares the pages and script_pages_record (Task 4)
-- matches them to candidates. scan_batch_status follows a batch; once every scan of a centre is in, staff say so
-- (scan_centre_complete) and each candidate's script is complete, or a missing_pages exception says what is missing.
--
-- Every function here is for staff admins (per-action permissions come with Phase 1B). A removed centre takes no new
-- batch, no completion, and (fixing Task 8) no collection count, manifest or custody event.
--
-- Pages that staff confirm were left blank (Task 10's script_exception_dismiss_missing) are the numbers listed under
-- "dismissed" in the details of a missing_pages exception of the booking (any state); they are not missing any more.
--
-- Lock order (as 052): the centre's scan lock (advisory), batch, booking (advisory, in uuid order), script.

-- ---------------------------------------------------------------------------------------------
-- Schema additions: the foreign keys Task 2 and Task 8 left for this task.
-- ---------------------------------------------------------------------------------------------
alter table public.scan_batches
  add constraint scan_batches_manifest_id_fkey foreign key (manifest_id) references public.collection_manifests (id);
alter table public.custody_events
  add constraint custody_events_batch_id_fkey foreign key (batch_id) references public.scan_batches (id);
create index scan_batches_centre_idx on public.scan_batches (centre_id);
create index custody_events_batch_idx on public.custody_events (batch_id) where batch_id is not null;

-- ---------------------------------------------------------------------------------------------
-- Helpers (internal): what a scanner file may be.
-- ---------------------------------------------------------------------------------------------
create function public.scan_upload_type_ok(p_mime text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(p_mime in ('application/pdf', 'image/jpeg', 'image/png'), false)
$$;

-- 1 GiB, the bucket's own limit.
create function public.scan_upload_max_bytes()
returns bigint
language sql
immutable
set search_path = ''
as $$
  select 1073741824::bigint
$$;

-- ---------------------------------------------------------------------------------------------
-- scan_batch_create: a new batch of one centre of the exam, numbered B-<exam code>-<001..999> per exam. A manifest
-- number (as printed, read without spaces or case) must be a manifest of that exam and centre.
-- ---------------------------------------------------------------------------------------------
create function public.scan_batch_create(p_exam uuid, p_centre uuid, p_manifest_number text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_code text;
  v_centre public.exam_centres%rowtype;
  v_number_in text := nullif(upper(btrim(coalesce(p_manifest_number, ''))), '');
  v_m public.collection_manifests%rowtype;
  v_n int;
  v_number text;
  v_id uuid;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null or p_centre is null or char_length(coalesce(v_number_in, '')) > 60 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select e.exam_code into v_code from public.exams e where e.id = p_exam;
  select * into v_centre from public.exam_centres c where c.id = p_centre and c.exam_id = p_exam;
  if v_code is null or v_centre.id is null then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_centre.removed_at is not null then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  if v_number_in is not null then
    select * into v_m from public.collection_manifests m where m.number = v_number_in;
    if not found then
      return jsonb_build_object('ok', false, 'code', 'unknown_manifest');
    end if;
    if v_m.exam_id <> p_exam or v_m.centre_id <> p_centre then
      return jsonb_build_object('ok', false, 'code', 'other_manifest');
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('scan_batch:' || p_exam::text, 0));
  select coalesce(max(substring(b.number from '-([0-9]+)$')::int), 0) + 1 into v_n
  from public.scan_batches b where b.exam_id = p_exam;
  if v_n > 999 then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  v_number := 'B-' || v_code || '-' || lpad(v_n::text, 3, '0');
  insert into public.scan_batches (exam_id, centre_id, manifest_id, number, created_by)
  values (p_exam, p_centre, v_m.id, v_number, v_actor)
  returning id into v_id;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'scan_batch_created', 'scan_batch', v_id);
  return jsonb_build_object('ok', true, 'batch_id', v_id, 'number', v_number, 'manifest', v_m.number);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- scan_upload_begin: one more file for a batch that has not started processing. Makes the pending upload row whose
-- path (batch/<batch>/<upload>.<ext>) the storage policy lets this user fill.
-- ---------------------------------------------------------------------------------------------
create function public.scan_upload_begin(p_batch uuid, p_mime text, p_bytes bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_b public.scan_batches%rowtype;
  v_mime text := lower(btrim(coalesce(p_mime, '')));
  v_id uuid := gen_random_uuid();
  v_path text;
  v_pos int;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_batch is null or p_bytes is null or p_bytes <= 0 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_b from public.scan_batches b where b.id = p_batch for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_b.submitted_at is not null then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  if not public.scan_upload_type_ok(v_mime) then
    return jsonb_build_object('ok', false, 'code', 'wrong_file_type');
  end if;
  if p_bytes > public.scan_upload_max_bytes() then
    return jsonb_build_object('ok', false, 'code', 'file_too_large');
  end if;

  select coalesce(max(u.position), 0) + 1 into v_pos from public.script_uploads u where u.batch_id = v_b.id;
  v_path := 'batch/' || v_b.id::text || '/' || v_id::text || '.'
    || case v_mime when 'application/pdf' then 'pdf' when 'image/jpeg' then 'jpg' else 'png' end;
  insert into public.script_uploads (id, exam_id, batch_id, kind, position, storage_path, mime, byte_size, uploaded_by)
  values (v_id, v_b.exam_id, v_b.id, 'scan_file', v_pos, v_path, v_mime, p_bytes, v_actor);
  return jsonb_build_object('ok', true, 'upload_id', v_id, 'storage_path', v_path, 'position', v_pos);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- script_upload_stored: as 20261120000054, and now also for a scanner file of a batch, said by its uploader while a
-- staff admin (no time window; PDF, JPEG or PNG up to 1 GiB). A file left out when its batch started processing is
-- discarded and answers conflict.
-- ---------------------------------------------------------------------------------------------
create or replace function public.script_upload_stored(p_upload uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_up public.script_uploads%rowtype;
  v_b public.bookings%rowtype;
  v_code text;
  v_meta jsonb;
  v_scan boolean;
begin
  if p_upload is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_up from public.script_uploads u where u.id = p_upload for update;
  if not found or v_up.uploaded_by is distinct from v_actor then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  v_scan := v_up.batch_id is not null;
  if v_scan then
    if not public.is_staff_admin() then
      return jsonb_build_object('ok', false, 'code', 'forbidden');
    end if;
  else
    if v_up.submission_id is null then
      return jsonb_build_object('ok', false, 'code', 'forbidden');
    end if;
    select b.* into v_b from public.bookings b join public.home_submissions s on s.booking_id = b.id where s.id = v_up.submission_id;
    v_code := public.home_upload_code(v_actor, v_b, null);
    if v_code is not null then
      return jsonb_build_object('ok', false, 'code', v_code);
    end if;
  end if;
  if v_up.state = 'discarded' then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  if v_up.state <> 'pending' then
    return jsonb_build_object('ok', true, 'upload_id', v_up.id, 'state', v_up.state);
  end if;

  select o.metadata into v_meta from storage.objects o where o.bucket_id = 'script-uploads' and o.name = v_up.storage_path;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if jsonb_typeof(v_meta -> 'size') is distinct from 'number'
     or (v_meta ->> 'size')::numeric <> v_up.byte_size
     or (v_meta ->> 'size')::numeric > (case when v_scan then public.scan_upload_max_bytes() else public.home_upload_max_bytes(v_up.kind) end)
     or (v_meta ->> 'mimetype') is distinct from v_up.mime
     or not (case when v_scan then v_up.kind = 'scan_file' and public.scan_upload_type_ok(v_meta ->> 'mimetype')
                  else public.home_upload_type_ok(v_up.kind, v_meta ->> 'mimetype') end) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  update public.script_uploads set state = 'stored', stored_at = now() where id = v_up.id;
  return jsonb_build_object('ok', true, 'upload_id', v_up.id, 'state', 'stored');
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- scan_batch_submit ("Start processing"): every stored file of the batch gets a prepare job, in order; a file that
-- never arrived (still pending) is left out (discarded); the batch is submitted; and one scanned custody event at
-- "Scanning" names the batch and its manifest, recorded by the caller. It needs a stored file. A batch already
-- submitted answers ok with nothing queued and changes nothing.
-- ---------------------------------------------------------------------------------------------
create function public.scan_batch_submit(p_batch uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := now();
  v_b public.scan_batches%rowtype;
  v_n int;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_batch is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_b from public.scan_batches b where b.id = p_batch;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('scan_centre:' || v_b.centre_id::text, 0));
  select * into v_b from public.scan_batches b where b.id = p_batch for update;
  if v_b.submitted_at is not null then
    return jsonb_build_object('ok', true, 'batch_id', v_b.id, 'number', v_b.number, 'submitted_at', v_b.submitted_at, 'queued', 0);
  end if;
  if not exists (select 1 from public.script_uploads u where u.batch_id = v_b.id and u.state = 'stored') then
    return jsonb_build_object('ok', false, 'code', 'nothing_to_submit');
  end if;

  update public.script_uploads set state = 'discarded', discarded_at = v_now where batch_id = v_b.id and state = 'pending';
  update public.script_uploads set state = 'queued' where batch_id = v_b.id and state = 'stored';
  get diagnostics v_n = row_count;
  insert into public.processing_jobs (upload_id, kind)
  select u.id, 'prepare' from public.script_uploads u where u.batch_id = v_b.id and u.state = 'queued' order by u.position, u.id;
  update public.scan_batches set submitted_at = v_now where id = v_b.id;
  insert into public.custody_events (exam_id, centre_id, manifest_id, batch_id, step, location, note, recorded_by, at)
  values (v_b.exam_id, v_b.centre_id, v_b.manifest_id, v_b.id, 'scanned', 'Scanning', 'Scan batch ' || v_b.number, v_actor, v_now);
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'scan_batch_submitted', 'scan_batch', v_b.id);
  return jsonb_build_object('ok', true, 'batch_id', v_b.id, 'number', v_b.number, 'submitted_at', v_now, 'queued', v_n);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- scan_batch_status: what the batch screen shows.
--   uploads:  its files handed in or still uploading (not those left out), in order;
--   totals:   its current pages (replaced_at is null) and how many are matched, blank, flagged (raised to staff for
--             itself: no code, an unknown or unexpected code, poor quality) and duplicates;
--   jobs:     its processing jobs waiting, running and failed;
--   candidates_complete / candidates_expected: the centre's present or late candidates whose script is complete,
--             and how many there are.
-- ---------------------------------------------------------------------------------------------
create function public.scan_batch_status(p_batch uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_b public.scan_batches%rowtype;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_batch is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_b from public.scan_batches b where b.id = p_batch;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  return jsonb_build_object(
    'ok', true,
    'batch_id', v_b.id,
    'number', v_b.number,
    'exam_id', v_b.exam_id,
    'centre_id', v_b.centre_id,
    'manifest', (select m.number from public.collection_manifests m where m.id = v_b.manifest_id),
    'created_at', v_b.created_at,
    'submitted_at', v_b.submitted_at,
    'uploads', (
      select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'state', u.state, 'byte_size', u.byte_size, 'mime', u.mime)
                       order by u.position nulls last, u.created_at, u.id), '[]'::jsonb)
      from public.script_uploads u where u.batch_id = v_b.id and u.state <> 'discarded'),
    'totals', (
      select jsonb_build_object(
        'pages', count(*),
        'matched', count(*) filter (where p.state = 'matched'),
        'blank', count(*) filter (where p.state = 'blank'),
        'flagged', count(*) filter (where exists (select 1 from public.script_exceptions e where e.page_id = p.id and e.kind <> 'duplicate')),
        'duplicates', count(*) filter (where p.state = 'duplicate'))
      from public.script_pages p join public.script_uploads u on u.id = p.upload_id
      where u.batch_id = v_b.id and p.replaced_at is null),
    'jobs', (
      select jsonb_build_object(
        'queued', count(*) filter (where j.state = 'queued'),
        'running', count(*) filter (where j.state = 'running'),
        'failed', count(*) filter (where j.state = 'failed'))
      from public.processing_jobs j join public.script_uploads u on u.id = j.upload_id
      where u.batch_id = v_b.id),
    'candidates_complete', (
      select count(*) from public.bookings b
      join public.attendance a on a.exam_id = b.exam_id and a.student_id = b.student_id and a.status in ('present', 'late')
      join public.scripts s on s.booking_id = b.id and s.complete
      where b.exam_id = v_b.exam_id and b.centre_id = v_b.centre_id and b.sitting = 'centre' and b.status in ('paid', 'cancel_requested')),
    'candidates_expected', (
      select count(*) from public.bookings b
      join public.attendance a on a.exam_id = b.exam_id and a.student_id = b.student_id and a.status in ('present', 'late')
      where b.exam_id = v_b.exam_id and b.centre_id = v_b.centre_id and b.sitting = 'centre' and b.status in ('paid', 'cancel_requested')));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- scan_centre_complete ("All scans for this centre are uploaded"). Refused (still_processing) while a file of the
-- centre's batches is stored but not handed to processing, or queued or processing. Then, for each candidate of the
-- centre marked present or late (a paid or cancel-requested centre booking), the answer pages of their copy's paper
-- version (the version of the script's pages when they are of one, else the candidate's latest copy, else the exam's
-- current paper; spare pages are optional) must be in the current version of the script or dismissed:
--   pages missing -> one open missing_pages exception for the candidate, details {"pages": [...]} (an open one is
--                    brought up to date, never repeated); the script, if any, is not complete;
--   none missing  -> the script is complete and an open missing_pages exception is resolved.
-- A candidate with no script at all misses every answer page. An open missing_pages exception of a booking of the
-- centre that is no longer a candidate (marked absent after all) is resolved. Each script touched is worked out
-- again (script_evaluate): verified when complete with no open exception. Scripts past verification are left alone.
-- Safe to call again. Returns {candidates, complete, missing}.
-- ---------------------------------------------------------------------------------------------
create function public.scan_centre_complete(p_exam uuid, p_centre uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := now();
  v_centre public.exam_centres%rowtype;
  v_b public.bookings%rowtype;
  v_x public.scripts%rowtype;
  v_papers uuid[];
  v_paper uuid;
  v_missing int[];
  v_rows int;
  v_script uuid;
  v_gone uuid[];
  v_candidates int := 0;
  v_complete int := 0;
  v_short int := 0;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null or p_centre is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_centre from public.exam_centres c where c.id = p_centre and c.exam_id = p_exam;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_centre.removed_at is not null then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;

  perform pg_advisory_xact_lock(hashtextextended('scan_centre:' || p_centre::text, 0));
  if exists (
    select 1 from public.script_uploads u join public.scan_batches sb on sb.id = u.batch_id
    where sb.exam_id = p_exam and sb.centre_id = p_centre
      and (u.state in ('queued', 'processing') or (u.state = 'stored' and sb.submitted_at is null))) then
    return jsonb_build_object('ok', false, 'code', 'still_processing');
  end if;

  for v_b in select b.* from public.bookings b where b.exam_id = p_exam and b.centre_id = p_centre order by b.id loop
    perform pg_advisory_xact_lock(hashtextextended('script_booking:' || v_b.id::text, 0));
  end loop;

  for v_b in
    select b.* from public.bookings b
    join public.attendance a on a.exam_id = b.exam_id and a.student_id = b.student_id and a.status in ('present', 'late')
    where b.exam_id = p_exam and b.centre_id = p_centre and b.sitting = 'centre' and b.status in ('paid', 'cancel_requested')
    order by b.id
  loop
    v_candidates := v_candidates + 1;
    select * into v_x from public.scripts s where s.booking_id = v_b.id for update;
    if v_x.id is not null and v_x.state not in ('receiving', 'checking', 'needs_attention', 'verified') then
      if v_x.complete then
        v_complete := v_complete + 1;
      end if;
      continue;
    end if;

    v_paper := null;
    if v_x.id is not null then
      select coalesce(array_agg(distinct c.paper_id), '{}') into v_papers
      from public.script_page_links l
      join public.script_pages p on p.id = l.page_id
      join public.paper_copies c on c.id = p.copy_id
      where l.script_id = v_x.id and l.version = v_x.version;
      if cardinality(v_papers) = 1 then
        v_paper := v_papers[1];
      end if;
    end if;
    if v_paper is null then
      select c.paper_id into v_paper from public.paper_copies c where c.booking_id = v_b.id order by c.created_at desc, c.id limit 1;
    end if;
    if v_paper is null then
      select p.id into v_paper from public.exam_papers p
      where p.exam_id = p_exam and p.kind = 'paper' and p.superseded_at is null order by p.version desc limit 1;
    end if;

    select coalesce(array_agg(r.page order by r.page), '{}') into v_missing
    from public.paper_page_roles r
    where r.paper_id = v_paper and r.role = 'answer'
      and not exists (select 1 from public.script_page_links l
                      where l.script_id = v_x.id and l.version = v_x.version and l.copy_page = r.page)
      and not exists (
        select 1 from public.script_exceptions e
        cross join lateral jsonb_array_elements_text(
          case when jsonb_typeof(e.details -> 'dismissed') = 'array' then e.details -> 'dismissed' else '[]'::jsonb end) d(page)
        where e.booking_id = v_b.id and e.kind = 'missing_pages' and d.page = r.page::text);

    if cardinality(v_missing) > 0 then
      v_short := v_short + 1;
      update public.script_exceptions e
      set details = e.details || jsonb_build_object('pages', to_jsonb(v_missing)), script_id = coalesce(e.script_id, v_x.id)
      where e.booking_id = v_b.id and e.kind = 'missing_pages' and e.state = 'open';
      get diagnostics v_rows = row_count;
      if v_rows = 0 then
        insert into public.script_exceptions (exam_id, kind, booking_id, script_id, details)
        values (p_exam, 'missing_pages', v_b.id, v_x.id, jsonb_build_object('pages', to_jsonb(v_missing)));
      end if;
      if v_x.complete then
        update public.scripts set complete = false where id = v_x.id;
      end if;
    else
      update public.script_exceptions e
      set state = 'resolved', resolved_by = v_actor, resolved_at = v_now, resolution = 'pages_arrived'
      where e.booking_id = v_b.id and e.kind = 'missing_pages' and e.state = 'open';
      if v_x.id is not null then
        v_complete := v_complete + 1;
        if not v_x.complete then
          update public.scripts set complete = true where id = v_x.id;
        end if;
      end if;
    end if;
    if v_x.id is not null then
      perform public.script_evaluate(v_x.id);
    end if;
  end loop;

  -- Bookings of the centre that are no longer candidates need nothing.
  with gone as (
    update public.script_exceptions e
    set state = 'resolved', resolved_by = v_actor, resolved_at = v_now, resolution = 'not_expected'
    from public.bookings b
    where e.booking_id = b.id and e.kind = 'missing_pages' and e.state = 'open'
      and b.exam_id = p_exam and b.centre_id = p_centre
      and not (b.sitting = 'centre' and b.status in ('paid', 'cancel_requested')
               and exists (select 1 from public.attendance a
                           where a.exam_id = b.exam_id and a.student_id = b.student_id and a.status in ('present', 'late')))
    returning e.booking_id)
  select coalesce(array_agg(distinct gone.booking_id), '{}') into v_gone from gone;
  for v_script in select s.id from public.scripts s where s.booking_id = any (v_gone) order by s.booking_id loop
    perform public.script_evaluate(v_script);
  end loop;

  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'scan_centre_completed', 'exam_centre', p_centre);
  return jsonb_build_object('ok', true, 'candidates', v_candidates, 'complete', v_complete, 'missing', v_short);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Task 8's collection, manifest and custody functions refuse a removed centre (conflict), as everything else does.
-- (Same as 20261120000056 otherwise.)
-- ---------------------------------------------------------------------------------------------
create or replace function public.collection_record(p_booking uuid, p_extra_sheets int)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_b public.bookings%rowtype;
  v_subject bigint;
  v_att public.attendance_status;
begin
  if v_actor is null or p_booking is null or p_extra_sheets is null or p_extra_sheets not between 0 and 50 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_b from public.bookings b where b.id = p_booking;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select e.subject_id into v_subject from public.exams e where e.id = v_b.exam_id;
  if not public.attendance_can_manage(v_actor, v_subject) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if exists (select 1 from public.exam_centres c where c.id = v_b.centre_id and c.removed_at is not null) then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  select a.status into v_att from public.attendance a where a.exam_id = v_b.exam_id and a.student_id = v_b.student_id;
  if v_b.status not in ('paid', 'cancel_requested') or v_att is null or v_att not in ('present', 'late') then
    return jsonb_build_object('ok', false, 'code', 'not_present');
  end if;
  insert into public.collection_counts (booking_id, exam_id, extra_sheets, recorded_by, recorded_at)
  values (p_booking, v_b.exam_id, p_extra_sheets, v_actor, now())
  on conflict (booking_id) do update
    set extra_sheets = excluded.extra_sheets, recorded_by = excluded.recorded_by, recorded_at = excluded.recorded_at;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'collection_recorded', 'booking', p_booking);
  return jsonb_build_object('ok', true, 'extra_sheets', p_extra_sheets);
end;
$$;

create or replace function public.collection_manifest_create(p_exam uuid, p_centre uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_exam public.exams%rowtype;
  v_n int;
  v_number text;
  v_id uuid;
  v_rows jsonb;
begin
  if v_actor is null or p_exam is null or p_centre is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_exam from public.exams e where e.id = p_exam;
  if not found or not exists (select 1 from public.exam_centres c where c.id = p_centre and c.exam_id = p_exam) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if not public.attendance_can_manage(v_actor, v_exam.subject_id) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if exists (select 1 from public.exam_centres c where c.id = p_centre and c.removed_at is not null) then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('manifest:' || p_exam::text, 0));
  select count(*) + 1 into v_n from public.collection_manifests m where m.exam_id = p_exam;
  if v_n > 99 then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  v_number := 'M-' || coalesce(v_exam.exam_code, 'EXAM') || '-' || lpad(v_n::text, 2, '0');
  insert into public.collection_manifests (exam_id, centre_id, number, created_by)
  values (p_exam, p_centre, v_number, v_actor) returning id into v_id;

  select coalesce(jsonb_agg(jsonb_build_object(
      'index_number', r.index_number, 'name', r.name, 'attendance', r.attendance, 'extra_sheets', r.extra_sheets)
      order by r.index_number), '[]'::jsonb)
  into v_rows
  from (
    select d.index_number, btrim(p.first_name || ' ' || p.last_name) as name,
           coalesce(a.status::text, 'not_marked') as attendance,
           case when a.status in ('present', 'late') then cc.extra_sheets end as extra_sheets
    from public.bookings b
    join public.profiles p on p.id = b.student_id
    left join public.student_details d on d.profile_id = b.student_id
    left join public.attendance a on a.exam_id = b.exam_id and a.student_id = b.student_id
    left join public.collection_counts cc on cc.booking_id = b.id
    where b.exam_id = p_exam and b.centre_id = p_centre and b.sitting = 'centre'
      and b.status in ('paid', 'cancel_requested')
  ) r;

  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'collection_manifest_created', 'collection_manifest', v_id);
  return jsonb_build_object('ok', true, 'manifest_id', v_id, 'number', v_number, 'rows', v_rows);
end;
$$;

create or replace function public.custody_record(
  p_exam uuid, p_centre uuid, p_step text, p_from uuid, p_to uuid, p_location text, p_note text,
  p_manifest uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_subject bigint;
  v_loc text := btrim(p_location);
  v_note text := nullif(btrim(p_note), '');
  v_id uuid;
begin
  if v_actor is null or p_exam is null or p_centre is null
     or p_step is null or p_step not in ('collected', 'handed_over', 'scanned', 'archived')
     or v_loc is null or char_length(v_loc) not between 1 and 120
     or (v_note is not null and char_length(v_note) > 300)
     or (p_from is null and p_to is null and v_note is null) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select e.subject_id into v_subject from public.exams e
  where e.id = p_exam and exists (select 1 from public.exam_centres c where c.id = p_centre and c.exam_id = p_exam);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if not public.attendance_can_manage(v_actor, v_subject) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if exists (select 1 from public.exam_centres c where c.id = p_centre and c.removed_at is not null) then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  if exists (
    select 1 from unnest(array[p_from, p_to]) s(id)
    where s.id is not null and not exists (
      select 1 from public.profiles q
      where q.id = s.id and q.status = 'active' and q.role in ('owner', 'admin', 'teacher', 'tutor', 'corrector'))) then
    return jsonb_build_object('ok', false, 'code', 'invalid_staff');
  end if;
  if p_manifest is not null and not exists (
    select 1 from public.collection_manifests m where m.id = p_manifest and m.exam_id = p_exam and m.centre_id = p_centre) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  insert into public.custody_events (exam_id, centre_id, manifest_id, step, from_staff, to_staff, location, note, recorded_by)
  values (p_exam, p_centre, p_manifest, p_step, p_from, p_to, v_loc, v_note, v_actor)
  returning id into v_id;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'custody_recorded', 'custody_event', v_id);
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Access.
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.scan_upload_type_ok(text) from public, anon, authenticated, service_role;
revoke execute on function public.scan_upload_max_bytes() from public, anon, authenticated, service_role;

revoke execute on function public.scan_batch_create(uuid, uuid, text) from public, anon;
revoke execute on function public.scan_upload_begin(uuid, text, bigint) from public, anon;
revoke execute on function public.scan_batch_submit(uuid) from public, anon;
revoke execute on function public.scan_batch_status(uuid) from public, anon;
revoke execute on function public.scan_centre_complete(uuid, uuid) from public, anon;
grant execute on function public.scan_batch_create(uuid, uuid, text) to authenticated;
grant execute on function public.scan_upload_begin(uuid, text, bigint) to authenticated;
grant execute on function public.scan_batch_submit(uuid) to authenticated;
grant execute on function public.scan_batch_status(uuid) to authenticated;
grant execute on function public.scan_centre_complete(uuid, uuid) to authenticated;
