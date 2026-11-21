begin;
create extension if not exists pgtap with schema extensions;
select plan(161);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Exam e: home and centre, 2031-06-07 10:00 London (09:00 UTC), 90 minutes: finish 10:30 UTC, on time
-- until 12:30 UTC, late until 2031-06-08 10:30 UTC. Paper: 4 pages (1 cover, 2-4 answer); every copy has 6 pages
-- (2 spare). Family 1: parent p1 with students s1 (home b1) and s4 (centre b4). s2 has no parent (home b2). Family
-- 2: parent p2 with student s3 (home b3). s5: unpaid home booking b5. s6 (b6): the 60-file limit. s7 (b7): "Send as
-- it is". s8 (b8): submitting at the end of the late window. s9 (b9): a booking whose cancellation is requested.
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('admin', tests.create_user('admin', 'active')), ('p1', tests.create_user('parent', 'active')),
  ('p2', tests.create_user('parent', 'active'));
insert into c select 's' || i, tests.create_user('student', 'active') from generate_series(1, 9) i;
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create temp table res (name text primary key, j jsonb);
grant all on res to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
create function pg_temp.r(p text) returns jsonb language sql stable as $$ select j from res where name = p $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.r(text) to public;

insert into public.parent_children values (pg_temp.uid('p1'), pg_temp.uid('s1')), (pg_temp.uid('p1'), pg_temp.uid('s4')),
  (pg_temp.uid('p2'), pg_temp.uid('s3'));
insert into public.subjects (name, kind) values ('ZZ Home upload', 'school');
insert into public.venues (name, rooms) values ('ZZ Home upload hall', array['R1']);
insert into public.exams (subject_id, title, paper, format, starts_at, duration_minutes, price_pence, price_confirmed, booking_deadline, status)
select s.id, 'ZZH e', 'P', 'both', '2031-06-07 10:00 Europe/London', 90, 0, true, '2031-06-06 10:00 Europe/London', 'published'
from public.subjects s where s.name = 'ZZ Home upload';
insert into kv select 'e', e.id from public.exams e where e.title = 'ZZH e';
insert into public.exam_centres (exam_id, venue_id, room, seat_limit)
select pg_temp.k('e'), v.id, 'R1', 50 from public.venues v where v.name = 'ZZ Home upload hall';
insert into kv select 'ce', id from public.exam_centres where exam_id = pg_temp.k('e');
insert into public.exam_papers (exam_id, kind, title, version, storage_path, page_count, byte_size)
values (pg_temp.k('e'), 'paper', 'Question paper', 1, pg_temp.k('e')::text || '/' || gen_random_uuid()::text || '.pdf', 4, 1000);
insert into kv select 'pv', id from public.exam_papers where exam_id = pg_temp.k('e');
update public.paper_page_roles set role = (case page when 1 then 'cover' else 'answer' end)::public.page_role
where paper_id = pg_temp.k('pv');

insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting, centre_id)
select pg_temp.k('e'), c.id, c.id, (case c.name when 's5' then 'awaiting_payment' when 's9' then 'cancel_requested' else 'paid' end)::public.booking_status, 0,
  (case when c.name = 's4' then 'centre' else 'home' end)::public.sitting_mode, case when c.name = 's4' then pg_temp.k('ce') end
from c where c.name like 's%';
insert into kv select 'b' || right(s.name, 1), b.id from public.bookings b join c s on s.id = b.student_id
where b.exam_id = pg_temp.k('e');
insert into public.paper_copies (code, booking_id, paper_id, page_count)
select public.copy_code_new(), pg_temp.k(b), pg_temp.k('pv'), 6 from unnest(array['b1', 'b2', 'b3', 'b6', 'b7']) b;
insert into kv select 'c' || right(k.name, 1), pc.id from public.paper_copies pc join kv k on k.id = pc.booking_id where k.name like 'b%';

-- Family calls (as the signed-in user). A successful call keeps its result under p_name, and the new id in kv.
create function pg_temp.open(p_name text, p_booking text, p_all boolean, p_now text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  r := public.home_submission_open(pg_temp.k(p_booking), p_all, p_now::timestamptz);
  if r ->> 'ok' = 'true' and p_name is not null then
    insert into kv values (p_name, (r ->> 'submission_id')::uuid) on conflict (name) do update set id = excluded.id;
    insert into res values (p_name, r) on conflict (name) do update set j = excluded.j;
  end if;
  return r;
end $$;
create function pg_temp.bgn(p_name text, p_sub text, p_kind text, p_mime text, p_bytes bigint, p_now text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  r := public.script_upload_begin(pg_temp.k(p_sub), p_kind::public.upload_kind, p_mime, p_bytes, p_now::timestamptz);
  if r ->> 'ok' = 'true' and p_name is not null then
    insert into kv values (p_name, (r ->> 'upload_id')::uuid);
    insert into res values (p_name, r);
  end if;
  return r;
end $$;
-- The file arriving in storage (the storage server writes its size and mimetype), and the family's "stored" call.
create function pg_temp.put(p_name text, p_size bigint, p_mime text) returns void language sql as $$
  insert into storage.objects (bucket_id, name, metadata)
  values ('script-uploads', pg_temp.r(p_name) ->> 'storage_path', jsonb_build_object('size', p_size, 'mimetype', p_mime)) $$;
create function pg_temp.stored(p_name text) returns jsonb language sql as $$ select public.script_upload_stored(pg_temp.k(p_name)) $$;
create function pg_temp.discard(p_name text) returns jsonb language sql as $$ select public.script_upload_discard(pg_temp.k(p_name)) $$;
create function pg_temp.submit(p_sub text, p_now text) returns jsonb language sql as $$
  select public.home_submission_submit(pg_temp.k(p_sub), p_now::timestamptz) $$;
create function pg_temp.status(p_booking text) returns jsonb language sql as $$ select public.home_submission_status(pg_temp.k(p_booking)) $$;
grant execute on function pg_temp.open(text, text, boolean, text), pg_temp.bgn(text, text, text, text, bigint, text),
  pg_temp.put(text, bigint, text), pg_temp.stored(text), pg_temp.discard(text), pg_temp.submit(text, text), pg_temp.status(text) to public;

-- The processing server (as postgres): one prepared page (p_copy null: a page with no code), and a prepare job run
-- for one upload.
create function pg_temp.page(p_up text, p_idx int, p_copy text, p_page int, p_flags text[] default '{}')
returns jsonb language sql stable as $$
  select jsonb_build_object('source_index', p_idx,
    'code', (select code from public.paper_copies where id = pg_temp.k(p_copy)), 'copy_page', p_page, 'blank', false,
    'quality', jsonb_build_object('sharpness', 200, 'brightness', 180, 'cut_off', false, 'flags', to_jsonb(p_flags)),
    'rotation', 0,
    'full_path', u.exam_id::text || '/' || u.id::text || '/' || coalesce((select j.id || '-' || (j.attempts + case when j.state = 'queued' then 1 else 0 end) from public.processing_jobs j where j.upload_id = u.id and j.kind = 'prepare' and j.state in ('queued', 'running') order by j.id desc limit 1), 'none') || '/' || p_idx || '-full.jpg',
    'marking_path', case when p_copy is not null then u.exam_id::text || '/' || u.id::text || '/' || coalesce((select j.id || '-' || (j.attempts + case when j.state = 'queued' then 1 else 0 end) from public.processing_jobs j where j.upload_id = u.id and j.kind = 'prepare' and j.state in ('queued', 'running') order by j.id desc limit 1), 'none') || '/' || p_idx || '-marking.jpg' end)
  from public.script_uploads u where u.id = pg_temp.k(p_up)
$$;
create function pg_temp.run(p_up text, p_pages jsonb) returns jsonb language plpgsql as $$
declare
  v jsonb;
  r jsonb;
begin
  update public.processing_jobs set run_after = '2000-01-01' where upload_id = pg_temp.k(p_up) and state = 'queued';
  v := public.processing_job_claim('t-worker');
  -- The pages go to the claimed job's folder for this attempt (they may have been made before it existed, or for an
  -- earlier run of the file).
  p_pages := regexp_replace(p_pages::text, '/(none|[0-9]+-[0-9]+)/([0-9]+-(full|marking)[.]jpg)',
    '/' || (v -> 'job' ->> 'id') || '-' || (v -> 'job' ->> 'attempts') || '/\2', 'g')::jsonb;
  if v is null or v -> 'upload' ->> 'id' <> pg_temp.k(p_up)::text then
    raise exception 'claimed another job';
  end if;
  r := public.script_pages_record((v -> 'job' ->> 'id')::bigint, 't-worker', (v -> 'job' ->> 'attempts')::int,
    encode(sha256(convert_to(pg_temp.k(p_up)::text, 'UTF8')), 'hex'), p_pages);
  if r ->> 'ok' <> 'true' then
    raise exception 'record refused: %', r;
  end if;
  perform public.processing_job_finish((v -> 'job' ->> 'id')::bigint, 't-worker', (v -> 'job' ->> 'attempts')::int, true);
  return r;
end;
$$;
create function pg_temp.page_id(p_up text, p_idx int) returns uuid language sql stable as $$
  select id from public.script_pages where upload_id = pg_temp.k(p_up) and source_index = p_idx and replaced_at is null $$;

-- ----- begin_before_start_refused -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(pg_temp.open('d1', 'b1', true, '2031-06-07 08:59:59Z') ->> 'code', 'uploads_not_open', 'no submission can be opened before the start');
select is(pg_temp.open('d1', 'b1', true, '2031-06-07 09:00:00Z') ->> 'seq', '1', 'from the start one can (the first is number 1)');
select is(pg_temp.bgn(null, 'd1', 'home_photo', 'image/jpeg', 1000, '2031-06-07 08:59:59Z') ->> 'code', 'uploads_not_open', 'no file can be begun before the start');

-- ----- begin_on_time_and_late -----
select is(pg_temp.bgn('u1', 'd1', 'home_photo', 'image/jpeg', 1000, '2031-06-07 09:30:00Z') ->> 'late', 'false', 'during the exam: on time');
select is(pg_temp.r('u1') ->> 'storage_path', 'home/' || pg_temp.k('b1')::text || '/' || pg_temp.k('u1')::text || '.jpg', 'the path is home/<booking>/<upload>.jpg');
select is(pg_temp.bgn('u2', 'd1', 'home_pdf', 'application/pdf', 5000000, '2031-06-07 12:29:59Z') ->> 'late', 'false', 'finish + 2 h - 1 s: on time');
select is(pg_temp.bgn('u3', 'd1', 'home_photo', 'image/heic', 2000, '2031-06-07 12:30:00Z') ->> 'late', 'true', 'finish + 2 h: late');
select ok(pg_temp.r('u3') ->> 'storage_path' like '%.heic', 'a HEIC photo keeps its extension');
select tests.as_postgres();
select is((select format('%s|%s|%s|%s|%s|%s', u.booking_id = pg_temp.k('b1'), u.exam_id = pg_temp.k('e'), u.uploaded_by = pg_temp.uid('s1'), u.state, u.position, u.kind)
           from public.script_uploads u where u.id = pg_temp.k('u1')),
  't|t|t|pending|1|home_photo', 'the row has the booking, the exam, the uploader, pending and position 1');
select is((select array_agg(u.position order by u.position) from public.script_uploads u where u.submission_id = pg_temp.k('d1')),
  array[1, 2, 3], 'positions follow the order the files were begun');

-- ----- begin_after_late_window_refused (Review Focus 5) -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(pg_temp.bgn('u9', 'd1', 'home_photo', 'image/jpeg', 1000, '2031-06-08 10:29:59Z') ->> 'late', 'true', 'finish + 24 h - 1 s: accepted, late');
select is(pg_temp.bgn(null, 'd1', 'home_photo', 'image/jpeg', 1000, '2031-06-08 10:30:00Z') ->> 'code', 'uploads_closed', 'finish + 24 h: refused');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s2'));
select is(pg_temp.open(null, 'b2', true, '2031-06-08 10:30:00Z') ->> 'code', 'uploads_closed', 'and no submission can be opened then');
-- Through the API p_now is ignored and the database clock decides (the exam here is years ahead).
select tests.as_postgres();
select set_config('request.method', 'POST', true);
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(pg_temp.bgn(null, 'd1', 'home_photo', 'image/jpeg', 1000, '2031-06-07 11:00:00Z') ->> 'code', 'uploads_not_open', 'an API call cannot choose its own time to begin');
select is(pg_temp.submit('d1', '2031-06-07 11:00:00Z') ->> 'code', 'uploads_not_open', 'or to submit');
select tests.as_postgres();
select set_config('request.method', '', true);
select is((select count(*)::int from public.script_uploads where submission_id = pg_temp.k('d1')), 4, 'refused calls wrote nothing');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(pg_temp.discard('u9') ->> 'state', 'discarded', 'a draft file can be discarded');
select tests.as_postgres();
select is((select u.state::text || '|' || (u.discarded_at is not null) from public.script_uploads u where u.id = pg_temp.k('u9')), 'discarded|true', 'with the time it was discarded');

-- ----- begin_wrong_mime_or_size_refused -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(pg_temp.bgn(null, 'd1', 'home_photo', 'application/pdf', 1000, '2031-06-07 11:00:00Z') ->> 'code', 'wrong_file_type', 'a photo cannot be a PDF');
select is(pg_temp.bgn(null, 'd1', 'home_pdf', 'image/jpeg', 1000, '2031-06-07 11:00:00Z') ->> 'code', 'wrong_file_type', 'a PDF cannot be a JPEG');
select is(pg_temp.bgn(null, 'd1', 'home_photo', 'image/gif', 1000, '2031-06-07 11:00:00Z') ->> 'code', 'wrong_file_type', 'a GIF is refused');
select is(pg_temp.bgn(null, 'd1', 'home_photo', 'image/jpeg', 26214401, '2031-06-07 11:00:00Z') ->> 'code', 'file_too_large', 'a photo over 25 MB is refused');
select is(pg_temp.bgn(null, 'd1', 'home_pdf', 'application/pdf', 104857601, '2031-06-07 11:00:00Z') ->> 'code', 'file_too_large', 'a PDF over 100 MB is refused');
select is(pg_temp.bgn(null, 'd1', 'home_photo', 'image/jpeg', 0, '2031-06-07 11:00:00Z') ->> 'code', 'invalid_input', 'an empty file is refused');
select is(pg_temp.bgn(null, 'd1', 'scan_file', 'application/pdf', 1000, '2031-06-07 11:00:00Z') ->> 'code', 'invalid_input', 'a family cannot begin a scanner file');
select is(pg_temp.bgn('u4', 'd1', 'home_photo', 'image/png', 26214400, '2031-06-07 11:00:00Z') ->> 'ok', 'true', 'a 25 MB photo is accepted');
select is(pg_temp.bgn('u5', 'd1', 'home_pdf', 'application/pdf', 104857600, '2031-06-07 11:00:00Z') ->> 'ok', 'true', 'a 100 MB PDF is accepted');
select is(array[pg_temp.discard('u4') ->> 'state', pg_temp.discard('u5') ->> 'state', pg_temp.discard('u4') ->> 'state'],
  array['discarded', 'discarded', 'discarded'], 'both discarded again (a second discard is the same)');

-- ----- stored_requires_object_of_declared_size -----
select is(pg_temp.stored('u1') ->> 'code', 'not_found', 'stored without the file in storage: refused');
select pg_temp.put('u1', 999, 'image/jpeg');
select is(pg_temp.stored('u1') ->> 'code', 'invalid_input', 'a file of another size than declared: refused');
select tests.as_postgres();
select is((select state::text from public.script_uploads where id = pg_temp.k('u1')), 'pending', 'and the row stays pending');
update storage.objects set metadata = jsonb_build_object('size', 1000, 'mimetype', 'image/png') where name = pg_temp.r('u1') ->> 'storage_path';
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(pg_temp.stored('u1') ->> 'code', 'invalid_input', 'a file of another type than declared: refused');
select tests.as_postgres();
update storage.objects set metadata = jsonb_build_object('size', 1000, 'mimetype', 'image/jpeg') where name = pg_temp.r('u1') ->> 'storage_path';
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p1'));
select is(pg_temp.stored('u1') ->> 'code', 'forbidden', 'only the uploader says the file is stored');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(pg_temp.stored('u1') ->> 'ok', 'true', 'the declared size and type: stored');
select tests.as_postgres();
select is((select state::text || '|' || (stored_at is not null) from public.script_uploads where id = pg_temp.k('u1')), 'stored|true', 'with stored_at');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(pg_temp.stored('u1') ->> 'ok', 'true', 'a second call is the same');
select pg_temp.put('u2', 5000000, 'application/pdf');
select pg_temp.put('u3', 2000, 'image/heic');
select is(array[pg_temp.stored('u2') ->> 'ok', pg_temp.stored('u3') ->> 'ok'], array['true', 'true'], 'a PDF and a HEIC photo stored');
select is(pg_temp.stored('u4') ->> 'code', 'conflict', 'a discarded file cannot be stored');

-- ----- submit_needs_stored_uploads -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s2'));
select is(pg_temp.open('d2', 'b2', false, '2031-06-07 11:00:00Z') ->> 'replaces_all', 'true', 'the first submission is the whole script');
select is(pg_temp.submit('d2', '2031-06-07 11:00:00Z') ->> 'code', 'nothing_to_submit', 'nothing to submit: refused');
select pg_temp.bgn('u21', 'd2', 'home_photo', 'image/jpeg', 1500, '2031-06-07 11:00:00Z');
select is(pg_temp.submit('d2', '2031-06-07 11:00:00Z') ->> 'code', 'still_uploading', 'a file still uploading: refused');
select pg_temp.put('u21', 1500, 'image/jpeg');
select pg_temp.stored('u21');
select pg_temp.bgn('u22', 'd2', 'home_photo', 'image/jpeg', 1500, '2031-06-07 11:00:00Z');
select is(pg_temp.submit('d2', '2031-06-07 11:00:00Z') ->> 'code', 'still_uploading', 'one stored and one still uploading: refused');
select pg_temp.discard('u22');
insert into res select 'sub_d2', pg_temp.submit('d2', '2031-06-07 11:00:00Z');
select is(pg_temp.r('sub_d2') ->> 'state', 'checking', 'once every file is stored: submitted, checking');
select tests.as_postgres();
select is((select format('%s|%s|%s|%s', s.state, s.submitted_by = pg_temp.uid('s2'), s.submitted_at = '2031-06-07 11:00:00Z', s.late)
           from public.home_submissions s where s.id = pg_temp.k('d2')),
  'checking|t|t|f', 'submitted by the student, at the time, on time');
select is((select format('%s|%s|%s', (select count(*) from public.processing_jobs j where j.upload_id = pg_temp.k('u21') and j.kind = 'prepare' and j.state = 'queued'),
                         (select count(*) from public.processing_jobs j where j.upload_id = pg_temp.k('u22')),
                         (select state from public.script_uploads where id = pg_temp.k('u21')))),
  '1|0|queued', 'one prepare job for the stored file, none for the discarded one');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s2'));
select is(pg_temp.bgn(null, 'd2', 'home_photo', 'image/jpeg', 1500, '2031-06-07 11:05:00Z') ->> 'code', 'conflict', 'no file can be added once submitted');
select is(pg_temp.discard('u21') ->> 'code', 'conflict', 'or discarded');

-- ----- submit_twice_is_idempotent (Review Focus 1) -----
select is(pg_temp.submit('d2', '2031-06-07 13:00:00Z'), pg_temp.r('sub_d2'), 'a second submit returns the same result');
select tests.as_postgres();
select is((select format('%s|%s', (select count(*) from public.processing_jobs j join public.script_uploads u on u.id = j.upload_id where u.submission_id = pg_temp.k('d2')),
                         (select submitted_at = '2031-06-07 11:00:00Z' from public.home_submissions where id = pg_temp.k('d2')))),
  '1|t', 'and changes nothing: one job, the first time');

-- ----- a late submission (b1), by the linked parent -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p1'));
select is(pg_temp.submit('d1', '2031-06-07 12:30:00Z') ->> 'late', 'true', 'submitted at finish + 2 h: late');
select is(pg_temp.submit('d1', '2031-06-07 13:00:00Z') ->> 'late', 'true', 'a second submit is the same');
select tests.as_postgres();
select is((select s.submitted_by = pg_temp.uid('p1') from public.home_submissions s where s.id = pg_temp.k('d1')), true, 'a linked parent can submit');
select is((select jsonb_agg(e.details) from public.script_exceptions e where e.booking_id = pg_temp.k('b1') and e.kind = 'late' and e.state = 'open'),
  jsonb_build_array(jsonb_build_object('submission_id', pg_temp.k('d1'), 'seq', 1)), 'one late exception for staff, with no personal data');
select pg_temp.run('u1', jsonb_build_array(pg_temp.page('u1', 0, 'c1', 2)));
select is((select s.late from public.scripts s where s.booking_id = pg_temp.k('b1')), true, 'the script made from a late submission is late');
select is((select e.script_id = s.id from public.script_exceptions e join public.scripts s on s.booking_id = e.booking_id
           where e.booking_id = pg_temp.k('b1') and e.kind = 'late'), true, 'and the late exception names it');

-- ----- an open draft is returned again; replacing some pages -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p1'));
select is((select format('%s|%s', j ->> 'seq', j ->> 'replaces_all') from (select pg_temp.open('d1b', 'b1', false, '2031-06-07 13:00:00Z') j) x),
  '2|false', 'after a submission a new draft can replace some pages');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is((select format('%s|%s', (j ->> 'submission_id')::uuid = pg_temp.k('d1b'), j ->> 'replaces_all') from (select pg_temp.open(null, 'b1', true, '2031-06-07 13:01:00Z') j) x),
  't|true', 'opening again returns the same draft, now replacing all pages');
select is((select format('%s|%s', (j ->> 'submission_id')::uuid = pg_temp.k('d1b'), j ->> 'replaces_all') from (select pg_temp.open(null, 'b1', false, '2031-06-07 13:02:00Z') j) x),
  't|false', 'and back to some pages');

-- ----- reorder -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p1'));
select pg_temp.bgn(v, 'd1b', 'home_photo', 'image/jpeg', 1000, '2031-06-07 13:05:00Z') from unnest(array['v1', 'v2', 'v3']) v;
select is(public.script_upload_reorder(pg_temp.k('d1b'), array[pg_temp.k('v3'), pg_temp.k('v1'), pg_temp.k('v2')]) ->> 'ok', 'true', 'the files can be put in another order');
select tests.as_postgres();
select is((select array_agg(u.position order by k.name) from public.script_uploads u join kv k on k.id = u.id where k.name in ('v1', 'v2', 'v3')),
  array[2, 3, 1], 'positions follow the new order');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(public.script_upload_reorder(pg_temp.k('d1b'), array[pg_temp.k('v1'), pg_temp.k('v2')]) ->> 'code', 'invalid_input', 'every file must be named');
select is(public.script_upload_reorder(pg_temp.k('d1b'), array[pg_temp.k('v1'), pg_temp.k('v1'), pg_temp.k('v2'), pg_temp.k('v3')]) ->> 'code', 'invalid_input', 'once each');

-- ----- centre_booking_cannot_upload, unpaid_booking_cannot_upload -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p1'));
select is(pg_temp.open(null, 'b4', true, '2031-06-07 11:00:00Z') ->> 'code', 'wrong_sitting', 'a centre booking cannot upload');
select is(pg_temp.status('b4') ->> 'code', 'wrong_sitting', 'and has no upload status');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s5'));
select is(pg_temp.open(null, 'b5', true, '2031-06-07 11:00:00Z') ->> 'code', 'conflict', 'an unpaid booking cannot upload');
select is(pg_temp.status('b5') ->> 'code', 'conflict', 'and has no upload status');

-- ----- other_family_forbidden -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p2'));
select is(pg_temp.open(null, 'b1', true, '2031-06-07 11:00:00Z') ->> 'code', 'forbidden', 'another family cannot open a submission');
select is(pg_temp.bgn(null, 'd1b', 'home_photo', 'image/jpeg', 1000, '2031-06-07 13:10:00Z') ->> 'code', 'forbidden', 'or add a file');
select is(pg_temp.submit('d1b', '2031-06-07 13:10:00Z') ->> 'code', 'forbidden', 'or submit');
select is(pg_temp.status('b1') ->> 'code', 'forbidden', 'or read the status');
select is(pg_temp.discard('v1') ->> 'code', 'forbidden', 'or discard a file');
select is(public.script_upload_reorder(pg_temp.k('d1b'), array[pg_temp.k('v1'), pg_temp.k('v2'), pg_temp.k('v3')]) ->> 'code', 'forbidden', 'or reorder');
select is(public.home_missing_confirm_blank(pg_temp.k('d1'), array[3]) ->> 'code', 'forbidden', 'or confirm a blank page');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s3'));
select is(pg_temp.open(null, 'b1', true, '2031-06-07 11:00:00Z') ->> 'code', 'forbidden', 'another student cannot either');
select is(public.home_submission_open(gen_random_uuid(), true, '2031-06-07 11:00:00Z') ->> 'code', 'forbidden', 'an unknown booking answers forbidden');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.open(null, 'b1', true, '2031-06-07 11:00:00Z') ->> 'code', 'forbidden', 'staff do not upload for a family');
select is(pg_temp.status('b1') ->> 'ok', 'true', 'but an admin can read the status');

-- ----- confirm_blank_receives_submission (b2: pages 2 and 3 handed in, page 4 not) -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s2'));
select is((select format('%s|%s', j -> 'submission' ->> 'state', j -> 'missing') from (select pg_temp.status('b2') j) x), 'checking|[]', 'while checking nothing is said missing');
select tests.as_postgres();
select pg_temp.run('u21', jsonb_build_array(pg_temp.page('u21', 0, 'c2', 2), pg_temp.page('u21', 1, 'c2', 3)));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s2'));
insert into res select 'st2', pg_temp.status('b2');
select is(pg_temp.r('st2') -> 'submission' ->> 'state', 'needs_attention', 'a missing answer page needs attention');
select is(pg_temp.r('st2') -> 'missing', '[4]'::jsonb, 'page 4 is missing (the cover need not be handed in)');
select is((select string_agg(format('%s:%s:%s:%s', p ->> 'copy_page', p ->> 'state', p ->> 'source_index', p ->> 'file_number'), ',' order by p ->> 'source_index')
           from jsonb_array_elements(pg_temp.r('st2') -> 'pages') p),
  '2:matched:0:1,3:matched:1:1', 'the pages say what each one is and where it came from');
select is((pg_temp.r('st2') -> 'pages' -> 0 ->> 'upload_id')::uuid, pg_temp.k('u21'), 'with its upload');
select is(public.home_missing_confirm_blank(pg_temp.k('d2'), array[1]) ->> 'code', 'invalid_input', 'the cover is not an answer page');
select is(public.home_missing_confirm_blank(pg_temp.k('d2'), array[2]) ->> 'code', 'invalid_input', 'page 2 was handed in');
select is(public.home_missing_confirm_blank(pg_temp.k('d2'), array[4]) ->> 'state', 'received', 'page 4 left blank: received');
insert into res select 'st2b', pg_temp.status('b2');
select is((select format('%s|%s|%s|%s', j -> 'submission' ->> 'state', j -> 'missing', j -> 'blank', j -> 'script' -> 'pages') from (select pg_temp.r('st2b') j) x),
  'received|[]|[4]|[2, 3]', 'the status says received, page 4 blank, pages 2 and 3 in the script');
select ok(pg_temp.r('st2b') -> 'script' ->> 'number' ~ '^S-.+-[0-9]{4}$', 'with the script number');
select tests.as_postgres();
select is((select s.complete::text || '|' || s.state from public.scripts s where s.booking_id = pg_temp.k('b2')), 'true|verified', 'the script is complete and verified');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s2'));
select is(public.home_missing_confirm_blank(pg_temp.k('d2'), array[4]) ->> 'state', 'received', 'confirming again is the same');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p1'));
select is(public.home_missing_confirm_blank(pg_temp.k('d1b'), array[4]) ->> 'code', 'conflict', 'a draft has nothing to confirm');

-- ----- replacing some pages keeps the pages confirmed blank -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s2'));
select is(pg_temp.open('d2b', 'b2', false, '2031-06-07 12:00:00Z') ->> 'seq', '2', 'a second submission for b2');
select pg_temp.bgn('u23', 'd2b', 'home_photo', 'image/jpeg', 1500, '2031-06-07 12:00:00Z');
select pg_temp.put('u23', 1500, 'image/jpeg');
select pg_temp.stored('u23');
select is(pg_temp.submit('d2b', '2031-06-07 12:00:00Z') ->> 'state', 'checking', 'page 3 again, submitted');
select tests.as_postgres();
select pg_temp.run('u23', jsonb_build_array(pg_temp.page('u23', 0, 'c2', 3)));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s2'));
select is((select format('%s|%s', j -> 'submission' ->> 'state', j -> 'blank') from (select pg_temp.status('b2') j) x), 'received|[4]', 'received, page 4 still confirmed blank');
select tests.as_postgres();
select is((select l.page_id from public.scripts s join public.script_page_links l on l.script_id = s.id and l.version = s.version
           where s.booking_id = pg_temp.k('b2') and l.copy_page = 3), pg_temp.page_id('u23', 0), 'page 3 is the new one');

-- ----- place_uncoded_page_raises_exception (b3: pages 2 to 4 and a page with no code) -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p2'));
select pg_temp.open('d3', 'b3', true, '2031-06-07 11:00:00Z');
select pg_temp.bgn('u31', 'd3', 'home_pdf', 'application/pdf', 3000, '2031-06-07 11:00:00Z');
select pg_temp.put('u31', 3000, 'application/pdf');
select pg_temp.stored('u31');
select pg_temp.submit('d3', '2031-06-07 11:00:00Z');
select tests.as_postgres();
select pg_temp.run('u31', jsonb_build_array(pg_temp.page('u31', 0, 'c3', 2), pg_temp.page('u31', 1, 'c3', 3), pg_temp.page('u31', 2, 'c3', 4),
  pg_temp.page('u31', 3, null, null)));
insert into kv values ('pg31', pg_temp.page_id('u31', 3)), ('pg31m', pg_temp.page_id('u31', 0));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s3'));
insert into res select 'st3', pg_temp.status('b3');
select is(pg_temp.r('st3') -> 'submission' ->> 'state', 'needs_attention', 'a page with no code needs attention');
select is(pg_temp.r('st3') -> 'unplaced', jsonb_build_array(jsonb_build_object('page_id', pg_temp.k('pg31'), 'upload_id', pg_temp.k('u31'), 'source_index', 3, 'file_number', 1)),
  'the status names it');
select is(pg_temp.r('st3') -> 'missing', '[]'::jsonb, 'no answer page is missing');
select is(pg_temp.r('st3') ->> 'copy_pages', '6', 'and gives the number of pages to choose from');
select is(public.home_page_place(pg_temp.k('pg31'), 7) ->> 'code', 'invalid_input', 'after a page the copy does not have: refused');
select is(public.home_page_place(pg_temp.k('pg31'), 0) ->> 'code', 'invalid_input', 'after page 0: refused');
select is(public.home_page_place(pg_temp.k('pg31m'), 2) ->> 'code', 'invalid_input', 'a page with a code is not placed by the family');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p1'));
select is(public.home_page_place(pg_temp.k('pg31'), 3) ->> 'code', 'forbidden', 'another family cannot place it');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p2'));
select is(public.home_page_place(pg_temp.k('pg31'), 3) ->> 'state', 'received', 'placed after page 3: received');
select tests.as_postgres();
select is((select jsonb_agg(jsonb_build_object('page', e.page_id = pg_temp.k('pg31'), 'booking', e.booking_id = pg_temp.k('b3'), 'details', e.details))
           from public.script_exceptions e where e.kind = 'uncoded_family_page' and e.state = 'open' and e.exam_id = pg_temp.k('e')),
  jsonb_build_array(jsonb_build_object('page', true, 'booking', true, 'details', jsonb_build_object('after_page', 3, 'from', 'family'))),
  'one uncoded_family_page exception for staff, with no personal data');
select is((select placed_after from public.script_pages where id = pg_temp.k('pg31')), 3, 'the page is placed after page 3');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s3'));
select is(public.home_page_place(pg_temp.k('pg31'), 2) ->> 'state', 'received', 'placed again, after page 2');
select tests.as_postgres();
select is((select count(*)::text || '|' || max(e.details ->> 'after_page') from public.script_exceptions e where e.kind = 'uncoded_family_page' and e.page_id = pg_temp.k('pg31')),
  '1|2', 'still one exception, now after page 2');
select is((select state::text from public.scripts where booking_id = pg_temp.k('b3')), 'needs_attention', 'the script waits for staff to confirm the page');

-- ----- "Send as it is" (b7: page 2 blurred) -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s7'));
select pg_temp.open('d7', 'b7', true, '2031-06-07 11:00:00Z');
select pg_temp.bgn('u71', 'd7', 'home_photo', 'image/jpeg', 1000, '2031-06-07 11:00:00Z');
select pg_temp.put('u71', 1000, 'image/jpeg');
select pg_temp.stored('u71');
select pg_temp.submit('d7', '2031-06-07 11:00:00Z');
select tests.as_postgres();
select pg_temp.run('u71', jsonb_build_array(pg_temp.page('u71', 0, 'c7', 2, '{blurred}'), pg_temp.page('u71', 1, 'c7', 3), pg_temp.page('u71', 2, 'c7', 4)));
insert into kv values ('pg71', pg_temp.page_id('u71', 0)), ('pg71c', pg_temp.page_id('u71', 1));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s7'));
insert into res select 'st7', pg_temp.status('b7');
select is(pg_temp.r('st7') -> 'submission' ->> 'state', 'needs_attention', 'a blurred answer page needs attention');
select is(pg_temp.r('st7') -> 'retake', jsonb_build_array(jsonb_build_object('page_id', pg_temp.k('pg71'), 'copy_page', 2, 'flags', jsonb_build_array('blurred'))),
  'the status asks for page 2 again');
select is(public.home_page_send_as_is(pg_temp.k('pg71c')) ->> 'code', 'invalid_input', 'a clear page needs no "Send as it is"');
select is(public.home_page_send_as_is(pg_temp.k('pg71')) ->> 'state', 'received', 'sent as it is: received');
select is(public.home_page_send_as_is(pg_temp.k('pg71')) ->> 'state', 'received', 'a second call is the same');
select tests.as_postgres();
select is((select count(*)::text || '|' || max(e.details ->> 'from') || '|' || max(e.state) from public.script_exceptions e
           where e.kind = 'poor_quality' and e.page_id = pg_temp.k('pg71')),
  '1|family|open', 'one poor_quality exception for staff, from the family');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s7'));
select is(pg_temp.status('b7') -> 'retake', '[]'::jsonb, 'nothing left to retake');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p2'));
select is(public.home_page_send_as_is(pg_temp.k('pg71')) ->> 'code', 'forbidden', 'another family cannot send a page as it is');

-- ----- submitting at the end of the late window (b8) -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s8'));
select pg_temp.open('d8', 'b8', true, '2031-06-07 11:00:00Z');
select pg_temp.bgn('u81', 'd8', 'home_photo', 'image/jpeg', 1000, '2031-06-07 11:00:00Z');
select pg_temp.put('u81', 1000, 'image/jpeg');
select pg_temp.stored('u81');
select is(pg_temp.submit('d8', '2031-06-08 10:30:00Z') ->> 'code', 'uploads_closed', 'submitting at finish + 24 h: refused');
select is((select format('%s|%s', j ->> 'state', j ->> 'late') from (select pg_temp.submit('d8', '2031-06-08 10:29:59Z') j) x),
  'checking|true', 'at finish + 24 h - 1 s: accepted, late');

-- ----- a booking whose cancellation is requested may still hand in (b9) -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s9'));
select is(pg_temp.open('d9', 'b9', true, '2031-06-07 11:00:00Z') ->> 'ok', 'true', 'a cancel-requested booking opens a submission');
select is(pg_temp.bgn('u91', 'd9', 'home_photo', 'image/jpeg', 1000, '2031-06-07 11:00:00Z') ->> 'ok', 'true', 'and adds a file');

-- ----- sixty_one_files_refused -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s6'));
select pg_temp.open('d6', 'b6', true, '2031-06-07 11:00:00Z');
select is((select count(*)::int from generate_series(1, 60) i where pg_temp.bgn('f' || i, 'd6', 'home_photo', 'image/jpeg', 1000, '2031-06-07 11:00:00Z') ->> 'ok' = 'true'),
  60, '60 files are accepted');
select is(pg_temp.bgn(null, 'd6', 'home_photo', 'image/jpeg', 1000, '2031-06-07 11:00:00Z') ->> 'code', 'too_many_files', 'the 61st is refused');
select pg_temp.discard('f7');
select is(pg_temp.bgn(null, 'd6', 'home_photo', 'image/jpeg', 1000, '2031-06-07 11:00:00Z') ->> 'ok', 'true', 'after one is discarded another fits');
select pg_temp.put('f8', 1000, 'image/jpeg');
select pg_temp.put('f9', 999, 'image/jpeg');
select is(array[pg_temp.stored('f8') ->> 'ok', pg_temp.stored('f9') ->> 'code'], array['true', 'invalid_input'],
  'one draft file stored, one left pending after a refused stored');

-- ----- the draft in the status -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('p1'));
select is((select format('%s|%s|%s', (j -> 'draft' ->> 'id')::uuid = pg_temp.k('d1b'), jsonb_array_length(j -> 'draft' -> 'uploads'), j -> 'draft' -> 'uploads' -> 0 ->> 'mine')
           from (select pg_temp.status('b1') j) x),
  't|3|true', 'the status shows the open draft with its files in order');
select is((select (j -> 'draft' -> 'uploads' -> 0 ->> 'id')::uuid from (select pg_temp.status('b1') j) x), pg_temp.k('v3'), 'first the file put first');
select is((select j -> 'submission' ->> 'seq' from (select pg_temp.status('b1') j) x), '1', 'and the submission handed in');

-- ----- discarded drafts are removed by the processing server -----
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select throws_ok('select public.script_discarded_take(10)', '42501', null, 'a family cannot list discarded files');
select throws_ok($$select public.script_upload_purged('{}')$$, '42501', null, 'or mark them purged');
reset role;
set local role service_role;
select ok(not exists (select 1 from jsonb_array_elements(public.script_discarded_take(1000, now() + interval '30 minutes')) x
                      where (x ->> 'id')::uuid = pg_temp.k('u22')), 'a file discarded half an hour ago is kept');
select ok(exists (select 1 from jsonb_array_elements(public.script_discarded_take(1000, now() + interval '2 hours')) x
                  where x = jsonb_build_object('id', pg_temp.k('u22'), 'storage_path', pg_temp.r('u22') ->> 'storage_path')),
  'after an hour it is listed with its path');
reset role;
select is((select count(*)::int from jsonb_array_elements(public.script_discarded_take(1000, now() + interval '2 hours')) x
           join public.script_uploads u on u.id = (x ->> 'id')::uuid where u.state <> 'discarded'), 0,
  'while the booking can still hand in, only discarded files are listed');
set local role service_role;
select public.script_upload_purged(array[pg_temp.k('u22'), pg_temp.k('u21')], now() + interval '2 hours');
select ok(not exists (select 1 from jsonb_array_elements(public.script_discarded_take(1000, now() + interval '2 hours')) x
                      where (x ->> 'id')::uuid = pg_temp.k('u22')), 'once purged it is not listed again');
reset role;
select is((select format('%s|%s', (select purged_at is not null from public.script_uploads where id = pg_temp.k('u22')),
                         (select purged_at is null from public.script_uploads where id = pg_temp.k('u21')))),
  't|t', 'purged marks discarded files only, never a submitted one');

-- ----- files never finished are removed a day after the last chance to hand in (finish + 48 h); a draft's stored
-- ----- files are kept (Ruling R40, I2: staff can still accept the draft) -----
create function pg_temp.taken(p_now text) returns uuid[] language sql as $$
  select coalesce(array_agg((x ->> 'id')::uuid), '{}') from jsonb_array_elements(public.script_discarded_take(1000, p_now::timestamptz)) x $$;
grant execute on function pg_temp.taken(text) to public;
set local role service_role;
select ok(not (pg_temp.taken('2031-06-09 10:29:59Z') && array[pg_temp.k('v1'), pg_temp.k('f8'), pg_temp.k('f9')]),
  'finish + 48 h - 1 s: draft files are kept');
select ok(pg_temp.taken('2031-06-09 10:30:00Z') @> array[pg_temp.k('v1'), pg_temp.k('f9'), pg_temp.k('u91')]
          and not pg_temp.k('f8') = any (pg_temp.taken('2031-06-09 10:30:00Z')),
  'finish + 48 h: a pending draft file and one left pending after a refused stored are listed; a stored one never submitted is not');
select ok(not (pg_temp.taken('2040-01-01 00:00:00Z') && array[pg_temp.k('u1'), pg_temp.k('u2'), pg_temp.k('u21'), pg_temp.k('u23'),
  pg_temp.k('u31'), pg_temp.k('u71'), pg_temp.k('u81')]), 'a submitted file is never listed, however late');
reset role;
select is((select count(*)::int from unnest(pg_temp.taken('2040-01-01 00:00:00Z')) t(id) join public.script_uploads u on u.id = t.id
           where u.state not in ('discarded', 'pending')), 0,
  'everything listed was discarded or never finished');
set local role service_role;
select public.script_upload_purged(array[pg_temp.k('f8')], '2031-06-09 10:29:59Z');
reset role;
select is((select state::text || '|' || (purged_at is null) from public.script_uploads where id = pg_temp.k('f8')), 'stored|true',
  'a draft file cannot be marked purged before finish + 48 h');
set local role service_role;
select public.script_upload_purged(array[pg_temp.k('v1'), pg_temp.k('f8'), pg_temp.k('f9'), pg_temp.k('u81')], '2031-06-09 10:30:00Z');
reset role;
select is((select string_agg(k.name || ':' || u.state || ':' || (u.purged_at is not null), ',' order by k.name)
           from public.script_uploads u join kv k on k.id = u.id where k.name in ('v1', 'f8', 'f9', 'u81')),
  'f8:stored:false,f9:discarded:true,u81:queued:false,v1:discarded:true',
  'purged files never finished become discarded; a submitted file and a draft''s stored file are untouched');

-- ---------------------------------------------------------------------------------------------
-- Ruling R40 (m3): the files of one hand-in, discarded ones included, are capped at 120.
-- d6 has 61 so far (60 begun, one discarded, one more begun).
-- ---------------------------------------------------------------------------------------------
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s6'));
create function pg_temp.swap(p_n int) returns int language plpgsql as $$
declare
  v_ok int := 0;
  r jsonb;
begin
  for i in 1 .. p_n loop
    r := public.script_upload_begin(pg_temp.k('d6'), 'home_photo', 'image/jpeg', 1000, '2031-06-07 11:00:00Z');
    if r ->> 'ok' = 'true' then
      v_ok := v_ok + 1;
      perform public.script_upload_discard((r ->> 'upload_id')::uuid);
    end if;
  end loop;
  return v_ok;
end $$;
select pg_temp.discard('f10');
select is(pg_temp.swap(59), 59, 'a family can add and remove files: 120 in all for one hand-in');
select is(pg_temp.bgn(null, 'd6', 'home_photo', 'image/jpeg', 1000, '2031-06-07 11:00:00Z') ->> 'code', 'too_many_files_total',
  'R40 m3: the 121st file of one hand-in is refused, although fewer than 60 are in it now');
select tests.as_postgres();
select is((select concat_ws('/', count(*), count(*) filter (where u.state <> 'discarded') < 60) from public.script_uploads u where u.submission_id = pg_temp.k('d6')),
  '120/t', 'the hand-in holds 120 files, discarded ones included');

-- ---------------------------------------------------------------------------------------------
-- Ruling R40 (I2): uploaded but never submitted. d6 (b6) is a draft with one stored file (f8); d9 (b9) gets one too.
-- ---------------------------------------------------------------------------------------------
insert into c values ('teacher', tests.create_user('teacher', 'active'));
select tests.as_user(pg_temp.uid('s9'));
select pg_temp.put('u91', 1000, 'image/jpeg');
select is(pg_temp.stored('u91') ->> 'ok', 'true', 'b9 uploads a page and leaves without pressing Submit');
select tests.as_postgres();
select ok(not exists (select 1 from public.script_exceptions e where e.booking_id in (pg_temp.k('b6'), pg_temp.k('b9'))),
  'nothing in the exception queue shows these drafts');

-- cleanup_keeps_draft_files
set local role service_role;
select ok(not (pg_temp.taken('2040-01-01 00:00:00Z') && array[pg_temp.k('f8'), pg_temp.k('u91')]),
  'R40 I2: the stored files of a draft are never listed for deletion, however long ago the exam was');
select ok(pg_temp.taken('2031-06-09 10:30:00Z') @> array[pg_temp.k('f11'), pg_temp.k('f12')],
  'pending files (never finished) of the same draft still are, from finish + 48 h');
reset role;

-- dashboard_counts_unsubmitted_drafts
select tests.as_user(pg_temp.uid('admin'));
insert into res select 'dash_before', public.scripts_dashboard('2031-06-07 10:29:59Z');
insert into res select 'dash', public.scripts_dashboard('2031-06-08 12:00:00Z');
select is(concat_ws('/', (select x ->> 'unsubmitted' from jsonb_array_elements(pg_temp.r('dash_before') -> 'exams') x where (x -> 'exam' ->> 'id')::uuid = pg_temp.k('e')),
    (select x ->> 'unsubmitted' from jsonb_array_elements(pg_temp.r('dash') -> 'exams') x where (x -> 'exam' ->> 'id')::uuid = pg_temp.k('e'))),
  '0/2', 'R40 I2: the dashboard counts, per exam, the home bookings with stored files never submitted, once the exam has finished');
select cmp_ok((pg_temp.r('dash') ->> 'unsubmitted_drafts')::int, '>=', 2, 'and in its total');
insert into res select 'drafts', public.home_drafts_unsubmitted(pg_temp.k('e'), '2031-06-08 12:00:00Z');
select is((select string_agg(concat_ws(':', k.name, x ->> 'files', x ->> 'late', x -> 'booking' ->> 'id' is not null), ',' order by k.name)
           from jsonb_array_elements(pg_temp.r('drafts') -> 'items') x join kv k on k.id = (x ->> 'submission_id')::uuid),
  'd6:1:true:t,d9:1:true:t', 'the staff list names each such draft, its stored files and whether it would be late now');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('teacher'));
select is(concat_ws('/', public.home_drafts_unsubmitted(null) ->> 'code', public.home_submission_accept_draft(pg_temp.k('d9'), 'Family asked by phone') ->> 'code'),
  'forbidden/forbidden', 'R40 I2: a teacher can neither list the drafts nor accept one');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s9'));
select is(public.home_submission_accept_draft(pg_temp.k('d9'), 'Let me in') ->> 'code', 'forbidden', 'nor can the family');

-- staff_accept_draft
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(concat_ws('/', public.home_submission_accept_draft(pg_temp.k('d9'), 'ok') ->> 'code',
    public.home_submission_accept_draft(gen_random_uuid(), 'Family asked by phone') ->> 'code',
    public.home_submission_accept_draft(pg_temp.k('d8'), 'Family asked by phone') ->> 'code'),
  'reason_required/not_found/conflict', 'a reason is needed; an unknown submission is not found; one already submitted is refused');
insert into res select 'acc9', public.home_submission_accept_draft(pg_temp.k('d9'), 'Family asked by phone', '2031-06-07 12:29:59Z');
select is(concat_ws('/', pg_temp.r('acc9') ->> 'ok', pg_temp.r('acc9') ->> 'state', pg_temp.r('acc9') ->> 'late'), 'true/checking/false',
  'R40 I2: an admin submits the draft for the family: on time until finish + 2 h');
insert into res select 'acc6', public.home_submission_accept_draft(pg_temp.k('d6'), 'Uploaded in time, never submitted', '2031-06-08 12:00:00Z');
select is(concat_ws('/', pg_temp.r('acc6') ->> 'ok', pg_temp.r('acc6') ->> 'state', pg_temp.r('acc6') ->> 'late'), 'true/checking/true',
  'and late when the clock says so (here after the family''s own late window)');
select tests.as_postgres();
select is((select string_agg(concat_ws(':', k.name, s.state, s.late, s.submitted_by = pg_temp.uid('admin'), s.submitted_at), ',' order by k.name)
           from public.home_submissions s join kv k on k.id = s.id where k.name in ('d6', 'd9')),
  'd6:checking:t:t:2031-06-08 12:00:00+00,d9:checking:f:t:2031-06-07 12:29:59+00',
  'the submissions are submitted as the family''s own submit would, in the admin''s name');
select is((select string_agg(k.name || ':' || u.state, ',' order by k.name) from public.script_uploads u join kv k on k.id = u.id
           where k.name in ('f8', 'f11', 'u91')), 'f11:discarded,f8:queued,u91:queued',
  'its stored files wait to be processed; files never finished are discarded');
select is((select count(*)::int from public.processing_jobs j where j.upload_id in (pg_temp.k('f8'), pg_temp.k('u91')) and j.kind = 'prepare' and j.state = 'queued'),
  2, 'each with a prepare job');
select is((select count(*)::int from public.script_exceptions e where e.booking_id = pg_temp.k('b6') and e.kind = 'late' and e.state = 'open'), 1,
  'the late one is raised for a decision, as a late hand-in is');
select is((select string_agg(k.name || ':' || a.reason, ',' order by k.name) from public.audit_log a join kv k on k.id = a.target_id
           where a.action = 'home_submission_draft_accepted' and a.target_type = 'home_submission' and a.actor_id = pg_temp.uid('admin')),
  'd6:Uploaded in time, never submitted,d9:Family asked by phone', 'R40 I2: each acceptance is audited with its reason');
select tests.as_user(pg_temp.uid('admin'));
select is((select x ->> 'unsubmitted' from jsonb_array_elements(public.scripts_dashboard('2031-06-08 12:00:00Z') -> 'exams') x
           where (x -> 'exam' ->> 'id')::uuid = pg_temp.k('e')), '0', 'and the dashboard no longer counts them');
select tests.as_postgres();

select * from finish();
rollback;
