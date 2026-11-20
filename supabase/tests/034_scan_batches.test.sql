begin;
create extension if not exists pgtap with schema extensions;
select plan(109);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Exam e (centres ce1, ce2, ce3) and exam f (centre cf), one subject. Paper of e: 4 pages (1 cover, 2-3
-- answer, 4 information); every copy has 6 pages (5-6 spare). Centre ce1: b1 present, b2 late, b3 present (sends
-- nothing), b4 absent, b5 present but cancelled, b8 present with a cancellation requested. b6 sits at home, b7 at
-- ce2, b9 at ce3 (removed near the end); b10 (ce1) is added later, not marked on the register. Exam g (centre cg) has
-- no paper: gb is present. Exam h (centre ch) has two paper versions (v1: 2-3 answer; v2: 2-4 answer): hb is present
-- with a copy of each, the v2 copy the latest. Staff: admin, admin2, a suspended admin, a teacher of the subject.
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('admin', tests.create_user('admin', 'active')), ('admin2', tests.create_user('admin', 'active')),
  ('admin3', tests.create_user('admin', 'suspended')), ('teacher', tests.create_user('teacher', 'active'));
insert into c select 's' || i, tests.create_user('student', 'active') from generate_series(1, 13) i;
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create temp table res (name text primary key, j jsonb);
grant all on res to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
create function pg_temp.r(p text) returns jsonb language sql stable as $$ select j from res where name = p $$;
create function pg_temp.code(j jsonb) returns text language sql immutable as $$ select coalesce(j ->> 'code', 'ok') $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.r(text), pg_temp.code(jsonb) to public;

insert into public.subjects (name, kind) values ('ZZ Scan batches', 'school');
insert into public.venues (name, rooms) values ('ZZ Scan hall', array['R1', 'R2', 'R3']);
insert into public.exams (subject_id, title, paper, format, starts_at, duration_minutes, price_pence, price_confirmed, booking_deadline, status)
select s.id, 'ZZS ' || t.n, 'P1', 'both', t.at::timestamptz, 90, 0, true, t.at::timestamptz - interval '1 day', 'published'
from public.subjects s, (values ('e', '2031-06-07 10:00 Europe/London'), ('f', '2031-06-08 10:00 Europe/London'),
             ('g', '2031-06-09 10:00 Europe/London'), ('h', '2031-06-10 10:00 Europe/London')) t(n, at)
where s.name = 'ZZ Scan batches';
insert into kv select substr(e.title, 5), e.id from public.exams e join public.subjects s on s.id = e.subject_id where s.name = 'ZZ Scan batches';
insert into public.teacher_subjects select pg_temp.uid('teacher'), id from public.subjects where name = 'ZZ Scan batches';
insert into public.exam_centres (exam_id, venue_id, room, seat_limit)
select pg_temp.k('e'), v.id, r, 50 from public.venues v, unnest(array['R1', 'R2', 'R3']) r where v.name = 'ZZ Scan hall';
insert into kv select 'ce' || right(room, 1), id from public.exam_centres where exam_id = pg_temp.k('e');
insert into public.exam_centres (exam_id, venue_id, room, seat_limit)
select pg_temp.k('f'), v.id, 'R1', 50 from public.venues v where v.name = 'ZZ Scan hall';
insert into kv select 'cf', id from public.exam_centres where exam_id = pg_temp.k('f');
insert into public.exam_centres (exam_id, venue_id, room, seat_limit)
select pg_temp.k(t.x), v.id, 'R1', 50 from public.venues v, (values ('g'), ('h')) t(x) where v.name = 'ZZ Scan hall';
insert into kv select 'c' || t.x, ec.id from public.exam_centres ec join (values ('g'), ('h')) t(x) on ec.exam_id = pg_temp.k(t.x);

insert into public.exam_papers (exam_id, kind, title, version, storage_path, page_count, byte_size)
values (pg_temp.k('e'), 'paper', 'Question paper', 1, pg_temp.k('e')::text || '/' || gen_random_uuid()::text || '.pdf', 4, 1000);
insert into kv select 'pv', id from public.exam_papers where exam_id = pg_temp.k('e');
update public.paper_page_roles set role = (case page when 1 then 'cover' when 4 then 'information' else 'answer' end)::public.page_role
where paper_id = pg_temp.k('pv');

insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting, centre_id)
select pg_temp.k('e'), pg_temp.uid(t.s), pg_temp.uid(t.s), t.st::public.booking_status, 0, t.sit::public.sitting_mode, pg_temp.k(t.ce)
from (values ('s1', 'paid', 'centre', 'ce1'), ('s2', 'paid', 'centre', 'ce1'), ('s3', 'paid', 'centre', 'ce1'),
             ('s4', 'paid', 'centre', 'ce1'), ('s5', 'cancelled', 'centre', 'ce1'), ('s6', 'paid', 'home', null),
             ('s7', 'paid', 'centre', 'ce2'), ('s8', 'cancel_requested', 'centre', 'ce1'), ('s9', 'paid', 'centre', 'ce3')) t(s, st, sit, ce);
insert into kv select 'b' || right(s.name, 1), b.id from public.bookings b join c s on s.id = b.student_id where b.exam_id = pg_temp.k('e');
insert into public.paper_copies (code, booking_id, paper_id, page_count)
select public.copy_code_new(), pg_temp.k(b), pg_temp.k('pv'), 6 from unnest(array['b1', 'b2', 'b3', 'b4', 'b5', 'b7', 'b8']) b;
insert into kv select 'c' || right(k.name, 1), pc.id from public.paper_copies pc join kv k on k.id = pc.booking_id where k.name like 'b%';
insert into public.attendance (exam_id, student_id, status, marked_by, marked_at)
select pg_temp.k('e'), pg_temp.uid(t.s), t.st::public.attendance_status, pg_temp.uid('admin'), '2031-06-07 09:00Z'
from (values ('s1', 'present'), ('s2', 'late'), ('s3', 'present'), ('s4', 'absent'), ('s5', 'present'), ('s6', 'present'),
             ('s7', 'present'), ('s8', 'present'), ('s9', 'present')) t(s, st);

insert into public.exam_papers (exam_id, kind, title, version, storage_path, page_count, byte_size, superseded_at)
values (pg_temp.k('h'), 'paper', 'Question paper', 1, pg_temp.k('h')::text || '/' || gen_random_uuid()::text || '.pdf', 4, 1000, now());
insert into public.exam_papers (exam_id, kind, title, version, storage_path, page_count, byte_size)
values (pg_temp.k('h'), 'paper', 'Question paper', 2, pg_temp.k('h')::text || '/' || gen_random_uuid()::text || '.pdf', 4, 1000);
insert into kv select 'hv' || version, id from public.exam_papers where exam_id = pg_temp.k('h');
update public.paper_page_roles
set role = (case when page = 1 then 'cover' when page = 4 and paper_id = pg_temp.k('hv1') then 'information' else 'answer' end)::public.page_role
where paper_id in (pg_temp.k('hv1'), pg_temp.k('hv2'));
insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting, centre_id)
select pg_temp.k(t.x), pg_temp.uid('s1'), pg_temp.uid('s1'), 'paid', 0, 'centre', pg_temp.k('c' || t.x) from (values ('g'), ('h')) t(x);
insert into kv select t.x || 'b', b.id from public.bookings b join (values ('g'), ('h')) t(x) on b.exam_id = pg_temp.k(t.x);
insert into public.attendance (exam_id, student_id, status, marked_by, marked_at)
select pg_temp.k(t.x), pg_temp.uid('s1'), 'present', pg_temp.uid('admin'), '2031-06-09 09:00Z' from (values ('g'), ('h')) t(x);
insert into public.paper_copies (code, booking_id, paper_id, page_count, created_at)
values (public.copy_code_new(), pg_temp.k('hb'), pg_temp.k('hv1'), 6, now() - interval '1 hour'),
       (public.copy_code_new(), pg_temp.k('hb'), pg_temp.k('hv2'), 6, now());
insert into kv select 'hc' || right(k.name, 1), pc.id from public.paper_copies pc join kv k on k.id = pc.paper_id where k.name in ('hv1', 'hv2');

-- Staff calls. A successful call keeps its result under p_name, and the new id in kv.
create function pg_temp.batch(p_name text, p_exam text, p_centre text, p_manifest text default null) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  r := public.scan_batch_create(pg_temp.k(p_exam), pg_temp.k(p_centre), p_manifest);
  if r ->> 'ok' = 'true' and p_name is not null then
    insert into kv values (p_name, (r ->> 'batch_id')::uuid);
    insert into res values (p_name, r);
  end if;
  return r;
end $$;
create function pg_temp.bgn(p_name text, p_batch text, p_mime text, p_bytes bigint) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  r := public.scan_upload_begin(pg_temp.k(p_batch), p_mime, p_bytes);
  if r ->> 'ok' = 'true' and p_name is not null then
    insert into kv values (p_name, (r ->> 'upload_id')::uuid);
    insert into res values (p_name, r);
  end if;
  return r;
end $$;
-- The file arriving in storage (the storage server writes its size and mimetype).
create function pg_temp.put(p_name text, p_size bigint, p_mime text) returns void language sql as $$
  insert into storage.objects (bucket_id, name, metadata)
  values ('script-uploads', pg_temp.r(p_name) ->> 'storage_path', jsonb_build_object('size', p_size, 'mimetype', p_mime)) $$;
create function pg_temp.stored(p_name text) returns jsonb language sql as $$ select public.script_upload_stored(pg_temp.k(p_name)) $$;
create function pg_temp.submit(p_batch text) returns jsonb language sql as $$ select public.scan_batch_submit(pg_temp.k(p_batch)) $$;
create function pg_temp.status(p_batch text) returns jsonb language sql as $$ select public.scan_batch_status(pg_temp.k(p_batch)) $$;
create function pg_temp.complete(p_centre text) returns jsonb language sql as $$ select public.scan_centre_complete(pg_temp.k('e'), pg_temp.k(p_centre)) $$;
-- pages/matched/blank/flagged/duplicates/set_aside/accepted
create function pg_temp.totals(p_batch text) returns text language sql as $$
  select concat_ws('/', t ->> 'pages', t ->> 'matched', t ->> 'blank', t ->> 'flagged', t ->> 'duplicates', t ->> 'set_aside', t ->> 'accepted')
  from (select pg_temp.status(p_batch) -> 'totals' as t) x $$;
create function pg_temp.complete_in(p_exam text, p_centre text) returns jsonb language sql as $$
  select public.scan_centre_complete(pg_temp.k(p_exam), pg_temp.k(p_centre)) $$;
create function pg_temp.counts(j jsonb) returns text language sql immutable as $$
  select concat_ws('/', j ->> 'candidates', j ->> 'complete', j ->> 'missing') $$;
grant execute on function pg_temp.batch(text, text, text, text), pg_temp.bgn(text, text, text, bigint), pg_temp.put(text, bigint, text),
  pg_temp.stored(text), pg_temp.submit(text), pg_temp.status(text), pg_temp.complete(text), pg_temp.totals(text), pg_temp.counts(jsonb),
  pg_temp.complete_in(text, text) to public;

-- The processing server (as postgres): one prepared page (p_copy null: a page with no code), and a prepare job run.
create function pg_temp.page(p_up text, p_idx int, p_copy text, p_page int, p_sharp numeric default 200, p_flags text[] default '{}',
  p_marking boolean default true, p_blank boolean default false) returns jsonb language sql stable as $$
  select jsonb_build_object('source_index', p_idx,
    'code', (select code from public.paper_copies where id = pg_temp.k(p_copy)), 'copy_page', case when p_copy is not null then p_page end,
    'blank', p_blank,
    'quality', jsonb_build_object('sharpness', p_sharp, 'brightness', 180, 'cut_off', false, 'flags', to_jsonb(p_flags)),
    'rotation', 0,
    'full_path', u.exam_id::text || '/' || u.id::text || '/' || p_idx || '-full.jpg',
    'marking_path', case when p_copy is not null and p_marking then u.exam_id::text || '/' || u.id::text || '/' || p_idx || '-marking.jpg' end)
  from public.script_uploads u where u.id = pg_temp.k(p_up)
$$;
create function pg_temp.run(p_up text, p_pages jsonb) returns jsonb language plpgsql as $$
declare
  v jsonb;
  r jsonb;
begin
  update public.processing_jobs set run_after = '2000-01-01' where upload_id = pg_temp.k(p_up) and state = 'queued';
  v := public.processing_job_claim('t-worker');
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
create function pg_temp.script(p_booking text) returns text language sql stable as $$
  select complete || '/' || state::text from public.scripts where booking_id = pg_temp.k(p_booking) $$;
create function pg_temp.missing(p_booking text) returns text language sql stable as $$
  select coalesce(string_agg(state || ':' || (details -> 'pages')::text, ',' order by state, created_at), '')
  from public.script_exceptions where booking_id = pg_temp.k(p_booking) and kind = 'missing_pages' $$;
grant execute on function pg_temp.script(text), pg_temp.missing(text) to public;

-- Jobs left in a local database by other work are not part of this test.
update public.processing_jobs set state = 'done' where state in ('queued', 'running');

-- Manifests of e's centres ce1 and ce2, and of f.
select tests.as_user(pg_temp.uid('admin'));
insert into res select 'm1', public.collection_manifest_create(pg_temp.k('e'), pg_temp.k('ce1'));
insert into res select 'm2', public.collection_manifest_create(pg_temp.k('e'), pg_temp.k('ce2'));
insert into res select 'mf', public.collection_manifest_create(pg_temp.k('f'), pg_temp.k('cf'));
select tests.as_postgres();
insert into kv select t.n, (pg_temp.r(t.n) ->> 'manifest_id')::uuid from unnest(array['m1', 'm2', 'mf']) t(n);

-- ---------------------------------------------------------------------------------------------
-- Access.
-- ---------------------------------------------------------------------------------------------
select ok(not exists (select 1 from unnest(array['public.scan_batch_create(uuid,uuid,text)', 'public.scan_upload_begin(uuid,text,bigint)',
    'public.scan_batch_submit(uuid)', 'public.scan_batch_status(uuid)', 'public.scan_centre_complete(uuid,uuid)']) f
  where has_function_privilege('anon', f, 'execute') or not has_function_privilege('authenticated', f, 'execute')),
  'the scan functions are for signed-in users (they check the caller), never anon');
select ok(not exists (select 1 from unnest(array['public.scan_upload_type_ok(text)', 'public.scan_upload_max_bytes()',
    'public.scan_booking_complete(uuid)', 'public.script_version_uncomplete()']) f,
  unnest(array['anon', 'authenticated', 'service_role']) r where has_function_privilege(r, f, 'execute')), 'the scan helpers are internal');
select ok(exists (select 1 from pg_constraint where conrelid = 'public.scan_batches'::regclass and contype = 'f'
                    and confrelid = 'public.collection_manifests'::regclass)
      and exists (select 1 from pg_constraint where conrelid = 'public.custody_events'::regclass and contype = 'f'
                    and confrelid = 'public.scan_batches'::regclass),
  'a batch names a real manifest, and a custody event a real batch');

-- ---------------------------------------------------------------------------------------------
-- batch_numbers_per_exam
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.batch('bt1', 'e', 'ce1', pg_temp.r('m1') ->> 'number') ->> 'number',
  'B-' || (select exam_code from public.exams where id = pg_temp.k('e')) || '-01', 'batch_numbers_per_exam: the first batch is 01');
select is(pg_temp.r('bt1') ->> 'manifest', pg_temp.r('m1') ->> 'number', 'it names the manifest it came with');
select is(pg_temp.batch('bt2', 'e', 'ce2') ->> 'number',
  'B-' || (select exam_code from public.exams where id = pg_temp.k('e')) || '-02', 'numbers run on across the exam''s centres');
select is(pg_temp.batch('btf', 'f', 'cf') ->> 'number',
  'B-' || (select exam_code from public.exams where id = pg_temp.k('f')) || '-01', 'another exam starts again at 01');
select is(pg_temp.batch('bt3', 'e', 'ce1', '  ' || lower(pg_temp.r('m1') ->> 'number') || ' ') ->> 'manifest', pg_temp.r('m1') ->> 'number',
  'a manifest number is read without spaces or case');
select is(pg_temp.code(pg_temp.batch(null, 'e', 'ce1', pg_temp.r('m2') ->> 'number')), 'other_manifest', 'a manifest of another centre is refused');
select is(pg_temp.code(pg_temp.batch(null, 'e', 'ce1', pg_temp.r('mf') ->> 'number')), 'other_manifest', 'a manifest of another exam is refused');
select is(pg_temp.code(pg_temp.batch(null, 'e', 'ce1', 'M-NOPE-01')), 'unknown_manifest', 'an unknown manifest number is refused');
select is(pg_temp.code(pg_temp.batch(null, 'e', 'cf')), 'not_found', 'a centre of another exam is not found');
select is(pg_temp.code(public.scan_batch_create(pg_temp.k('e'), null)), 'invalid_input', 'no centre is refused');
select tests.as_postgres();
select is((select manifest_id from public.scan_batches where id = pg_temp.k('bt1')), pg_temp.k('m1'), 'the batch keeps the manifest''s id');
select is((select count(*)::int from public.audit_log where action = 'scan_batch_created' and target_type = 'scan_batch'
           and target_id in (pg_temp.k('bt1'), pg_temp.k('bt2'), pg_temp.k('btf'), pg_temp.k('bt3'))), 4, 'each batch made is audited');
-- Exam f gets batches 02 to 99: its 100th is refused.
insert into public.scan_batches (exam_id, centre_id, number, created_by)
select pg_temp.k('f'), pg_temp.k('cf'), 'B-' || (select exam_code from public.exams where id = pg_temp.k('f')) || '-' || lpad(n::text, 2, '0'), pg_temp.uid('admin')
from generate_series(2, 99) n;
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(pg_temp.batch(null, 'f', 'cf')), 'conflict', 'an exam has at most 99 batches (numbers have two digits)');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- batch_for_teacher_forbidden
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('teacher'));
select is(pg_temp.code(pg_temp.batch(null, 'e', 'ce1')), 'forbidden', 'batch_for_teacher_forbidden: a teacher of the subject cannot make a batch');
select is(pg_temp.code(pg_temp.bgn(null, 'bt1', 'application/pdf', 1000)), 'forbidden', 'nor add a file');
select is(pg_temp.code(pg_temp.submit('bt1')), 'forbidden', 'nor start processing');
select is(pg_temp.code(pg_temp.status('bt1')), 'forbidden', 'nor follow a batch');
select is(pg_temp.code(pg_temp.complete('ce1')), 'forbidden', 'nor complete a centre');
select is((select count(*)::int from public.scan_batches), 0, 'nor read the batches');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(pg_temp.code(pg_temp.batch(null, 'e', 'ce1')), 'forbidden', 'a student cannot make a batch');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin3'));
select is(pg_temp.code(pg_temp.batch(null, 'e', 'ce1')), 'forbidden', 'a suspended admin cannot make a batch');
select tests.as_postgres();
select is((select count(*)::int from public.scan_batches where exam_id = pg_temp.k('e')), 3, 'refused calls made no batch');

-- ---------------------------------------------------------------------------------------------
-- Files: scan_upload_begin and script_upload_stored for staff.
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select pg_temp.bgn('u1', 'bt1', 'application/pdf', 1073741824);
select is(pg_temp.r('u1') ->> 'storage_path',
  'batch/' || pg_temp.k('bt1')::text || '/' || pg_temp.k('u1')::text || '.pdf', 'a PDF of 1 GB is begun at the batch''s path');
select is(pg_temp.code(pg_temp.bgn(null, 'bt1', 'application/pdf', 1073741825)), 'file_too_large', 'a file over 1 GB is refused');
select is(pg_temp.code(pg_temp.bgn(null, 'bt1', 'image/heic', 1000)), 'wrong_file_type', 'a HEIC file is refused');
select is(pg_temp.code(pg_temp.bgn(null, 'bt1', 'image/jpeg', 0)), 'invalid_input', 'an empty file is refused');
select is(pg_temp.code(public.scan_upload_begin(gen_random_uuid(), 'application/pdf', 1000)), 'not_found', 'an unknown batch is not found');
select pg_temp.bgn('u2', 'bt1', ' IMAGE/PNG', 2000);
select is(pg_temp.r('u2') ->> 'storage_path',
  'batch/' || pg_temp.k('bt1')::text || '/' || pg_temp.k('u2')::text || '.png', 'a PNG is begun (the type is read in lower case)');
select is(right(pg_temp.bgn('u3', 'bt1', 'image/jpeg', 3000) ->> 'storage_path', 4), '.jpg', 'a JPEG is begun');
select tests.as_postgres();
select is((select string_agg(kind || '/' || state || '/' || position || '/' || mime || '/' || (exam_id = pg_temp.k('e')) || '/' || (uploaded_by = pg_temp.uid('admin'))
                             || '/' || (booking_id is null and submission_id is null), ',' order by position)
           from public.script_uploads where batch_id = pg_temp.k('bt1')),
  'scan_file/pending/1/application/pdf/true/true/true,scan_file/pending/2/image/png/true/true/true,scan_file/pending/3/image/jpeg/true/true/true',
  'each file is a pending scan_file of the batch''s exam, in order, uploaded by the caller');

select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(pg_temp.stored('u1')), 'not_found', 'stored before the file is in storage: refused');
select tests.as_postgres();
select pg_temp.put('u1', 5, 'application/pdf');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(pg_temp.stored('u1')), 'invalid_input', 'a file of another size than declared: refused');
select tests.as_postgres();
update storage.objects set metadata = jsonb_build_object('size', 1073741824, 'mimetype', 'application/pdf') where name = pg_temp.r('u1') ->> 'storage_path';
select tests.as_user(pg_temp.uid('admin2'));
select is(pg_temp.code(pg_temp.stored('u1')), 'forbidden', 'another admin cannot say the file is stored');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('teacher'));
select is(pg_temp.code(pg_temp.stored('u1')), 'forbidden', 'nor a teacher');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.stored('u1') ->> 'state', 'stored', 'the uploader''s file of 1 GB, of the declared size and type: stored');
select tests.as_postgres();
select pg_temp.put('u2', 2000, 'image/png');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.stored('u2') ->> 'state', 'stored', 'the PNG is stored');

-- ---------------------------------------------------------------------------------------------
-- submit_queues_jobs_and_scanned_custody (u3 never arrived)
-- ---------------------------------------------------------------------------------------------
select is(pg_temp.code(pg_temp.submit('bt2')), 'nothing_to_submit', 'submit_queues_jobs_and_scanned_custody: a batch with no stored file cannot start');
insert into res select 'sub1', pg_temp.submit('bt1');
select is((pg_temp.r('sub1') ->> 'ok') || '/' || (pg_temp.r('sub1') ->> 'queued'), 'true/2', 'starting processing queues the two stored files');
select tests.as_postgres();
select is((select string_agg(u.position || ':' || u.state || ':' || coalesce(j.kind || '/' || j.state, '-'), ',' order by u.position)
           from public.script_uploads u left join public.processing_jobs j on j.upload_id = u.id where u.batch_id = pg_temp.k('bt1')),
  '1:queued:prepare/queued,2:queued:prepare/queued,3:discarded:-', 'one prepare job per stored file; the file that never arrived is left out');
select ok((select submitted_at is not null from public.scan_batches where id = pg_temp.k('bt1')), 'the batch is submitted');
select is((select string_agg(step || '/' || location || '/' || (manifest_id = pg_temp.k('m1')) || '/' || (recorded_by = pg_temp.uid('admin'))
                             || '/' || (centre_id = pg_temp.k('ce1')) || '/' || (exam_id = pg_temp.k('e')), ',')
           from public.custody_events where batch_id = pg_temp.k('bt1')),
  'scanned/Scanning/true/true/true/true', 'one scanned custody event at "Scanning", with the manifest, recorded by the caller');
select tests.as_user(pg_temp.uid('admin'));
select is((select x ->> 'step' || '/' || (x ->> 'manifest') from jsonb_array_elements(public.custody_list(pg_temp.k('e'), pg_temp.k('ce1')) -> 'events') x
           where x ->> 'step' = 'scanned'), 'scanned/' || (pg_temp.r('m1') ->> 'number'), 'the custody list shows the scan with its manifest number');
select is(pg_temp.submit('bt1') ->> 'queued', '0', 'starting again changes nothing');
select tests.as_postgres();
select is((select count(*)::int from public.custody_events where batch_id = pg_temp.k('bt1')) || '/'
          || (select count(*) from public.processing_jobs j join public.script_uploads u on u.id = j.upload_id where u.batch_id = pg_temp.k('bt1')),
  '1/2', 'still one custody event and two jobs');
select is((select count(*)::int from public.audit_log where action = 'scan_batch_submitted' and target_id = pg_temp.k('bt1')), 1, 'the start is audited once');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(pg_temp.bgn(null, 'bt1', 'application/pdf', 100)), 'conflict', 'no file can be added once processing has started');
select is(pg_temp.code(pg_temp.stored('u3')), 'conflict', 'the file left out cannot be stored afterwards');
insert into res select 'st1', pg_temp.status('bt1');
select is((pg_temp.r('st1') ->> 'number') || '/' || (pg_temp.r('st1') ->> 'manifest'), (pg_temp.r('bt1') ->> 'number') || '/' || (pg_temp.r('m1') ->> 'number'),
  'the status shows the batch and manifest numbers');
select is((select string_agg((x ->> 'state') || ':' || (x ->> 'byte_size'), ',') from jsonb_array_elements(pg_temp.r('st1') -> 'uploads') x),
  'queued:1073741824,queued:2000', 'and the files handed in');
select is(concat_ws('/', pg_temp.r('st1') -> 'jobs' ->> 'queued', pg_temp.r('st1') -> 'jobs' ->> 'running', pg_temp.r('st1') -> 'jobs' ->> 'failed'),
  '2/0/0', 'and the jobs waiting');
select is(pg_temp.code(pg_temp.complete('ce1')), 'still_processing', 'a centre cannot be completed while its scans are processing');
select is(pg_temp.code(public.scan_batch_status(gen_random_uuid())), 'not_found', 'an unknown batch has no status');

-- ---------------------------------------------------------------------------------------------
-- status_totals_count_pages: u1 holds b1's pages 1-3, a blank sheet, a page with no code, absent b4's page, page 2 of
-- b8 twice, b8's blurred page 3 and b2's page 2; u2 holds b1's spare page 5 and a page of b7 (another centre).
-- ---------------------------------------------------------------------------------------------
select tests.as_postgres();
create temp table u1_pages as select jsonb_build_array(
  pg_temp.page('u1', 0, 'c1', 1, p_marking => false), pg_temp.page('u1', 1, 'c1', 2), pg_temp.page('u1', 2, 'c1', 3),
  pg_temp.page('u1', 3, null, null, 80, '{}', false, true), pg_temp.page('u1', 4, null, null, 80, '{}', false, false),
  pg_temp.page('u1', 5, 'c4', 2), pg_temp.page('u1', 6, 'c8', 2, 100), pg_temp.page('u1', 7, 'c8', 2, 300),
  pg_temp.page('u1', 8, 'c8', 3, 20, '{blurred}'), pg_temp.page('u1', 9, 'c2', 2)) as j;
select is((pg_temp.run('u1', (select j from u1_pages)) ->> 'pages'), '10', 'status_totals_count_pages: the first file is recorded');
select is((pg_temp.run('u2', jsonb_build_array(pg_temp.page('u2', 0, 'c1', 5), pg_temp.page('u2', 1, 'c7', 2))) ->> 'pages'), '2', 'and the second');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.totals('bt1'), '12/6/1/4/1/0/0',
  'each page once: matched, blank, flagged (open: no code, absent, blurred b8 page 3, other centre), duplicate, set aside; none accepted');
select is(pg_temp.status('bt1') -> 'jobs' ->> 'queued', '0', 'no job waits any more');
select tests.as_postgres();
insert into public.processing_jobs (upload_id, kind) values (pg_temp.k('u1'), 'prepare');
select pg_temp.run('u1', (select j from u1_pages));
select is((select count(*)::int from public.script_pages where upload_id = pg_temp.k('u1') and replaced_at is not null), 3,
  'the first file run again keeps b1''s earlier pages, replaced (older versions show them)');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.totals('bt1'), '12/6/1/4/1/0/0', 'the totals count the current pages only');
select tests.as_postgres();
update public.script_exceptions set state = 'resolved', resolved_at = now(), resolution = 'blank'
where upload_id = pg_temp.k('u1') and kind = 'no_code' and state = 'open';
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.totals('bt1'), '12/6/1/3/1/1/0', 'flagged counts open exceptions only: the page dealt with is set aside, and the totals still add up');
select is(pg_temp.status('bt1') ->> 'candidates_complete', '0', 'no candidate is complete before the centre is');

-- ---------------------------------------------------------------------------------------------
-- complete_raises_missing_pages_and_verifies_complete
-- ---------------------------------------------------------------------------------------------
select tests.as_postgres();
insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting, centre_id)
values (pg_temp.k('e'), pg_temp.uid('s10'), pg_temp.uid('s10'), 'paid', 0, 'centre', pg_temp.k('ce1'));
insert into kv select 'b10', id from public.bookings where exam_id = pg_temp.k('e') and student_id = pg_temp.uid('s10');
-- Not marked either, and none of them needs to be: an anonymised booking (its student's profile was deleted, its
-- attendance with it), a cancelled and a refunded booking at ce1, and a home booking.
insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting, centre_id)
values (pg_temp.k('e'), null, null, 'paid', 0, 'centre', pg_temp.k('ce1')),
       (pg_temp.k('e'), pg_temp.uid('s11'), pg_temp.uid('s11'), 'cancelled', 0, 'centre', pg_temp.k('ce1')),
       (pg_temp.k('e'), pg_temp.uid('s12'), pg_temp.uid('s12'), 'refunded', 0, 'centre', pg_temp.k('ce1')),
       (pg_temp.k('e'), pg_temp.uid('s13'), pg_temp.uid('s13'), 'paid', 0, 'home', null);
select tests.as_user(pg_temp.uid('admin'));
select is((select concat_ws('/', j ->> 'code', j ->> 'not_marked') from (select pg_temp.complete('ce1') as j) x), 'register_incomplete/1',
  'a centre with a candidate not marked on the register cannot be completed (anonymised, cancelled, refunded and home bookings do not count)');
select tests.as_postgres();
insert into public.attendance (exam_id, student_id, status, marked_by, marked_at)
values (pg_temp.k('e'), pg_temp.uid('s10'), 'absent', pg_temp.uid('admin'), '2031-06-07 09:05Z');
select tests.as_user(pg_temp.uid('admin'));
insert into res select 'cp1', pg_temp.complete('ce1');
select is(pg_temp.counts(pg_temp.r('cp1')), '4/2/2',
  'complete_raises_missing_pages_and_verifies_complete: four candidates, two complete, two with pages missing');
select tests.as_postgres();
select is(pg_temp.script('b1'), 'true/verified', 'b1 has every answer page: complete and verified');
select is(pg_temp.script('b8'), 'true/needs_attention', 'b8 has every answer page but open exceptions: complete, needs attention');
select is(pg_temp.script('b2') || ' ' || pg_temp.missing('b2'), 'false/needs_attention open:[3]', 'b2 misses page 3: one missing_pages exception');
select is((select count(*)::int from public.script_exceptions e join public.scripts s on s.id = e.script_id
           where e.booking_id = pg_temp.k('b2') and e.kind = 'missing_pages' and s.booking_id = pg_temp.k('b2') and e.exam_id = pg_temp.k('e')), 1,
  'the exception names b2''s script');
select is(coalesce(pg_temp.script('b3'), 'none') || ' ' || pg_temp.missing('b3'), 'none open:[2, 3]', 'b3 sent nothing: every answer page is missing');
select is((select details from public.script_exceptions where booking_id = pg_temp.k('b3') and kind = 'missing_pages'), '{"pages": [2, 3]}'::jsonb,
  'details hold the missing page numbers only');
select tests.as_user(pg_temp.uid('admin'));
select is((pg_temp.status('bt1') ->> 'candidates_complete') || '/' || (pg_temp.status('bt1') ->> 'candidates_expected'), '2/4',
  'the status counts the complete candidates of the centre');
select is(pg_temp.status('bt1') -> 'totals' ->> 'accepted', '1', 'and b1''s verified script as accepted');
select is(pg_temp.counts(pg_temp.complete('ce1')), '4/2/2', 'completing again gives the same answer');
select tests.as_postgres();
select is((select count(*)::int from public.script_exceptions where exam_id = pg_temp.k('e') and kind = 'missing_pages'), 2,
  'with no second exception for anyone');
select is((select count(*)::int from public.audit_log where action = 'scan_centre_completed' and target_id = pg_temp.k('ce1')), 2, 'each completion is audited');
insert into public.processing_jobs (upload_id, kind) values (pg_temp.k('u2'), 'prepare');
select pg_temp.run('u2', jsonb_build_array(pg_temp.page('u2', 0, 'c1', 5, 250), pg_temp.page('u2', 1, 'c7', 2)));
select is(pg_temp.script('b1'), 'false/receiving', 'a new version of b1''s script (the second file run again) makes it incomplete');
select is(public.scan_booking_complete(pg_temp.k('b1')) ->> 'outcome', 'complete', 'checking b1 again finds it still complete');
select is(pg_temp.script('b1'), 'true/verified', 'and marks it complete and verified again');

-- ---------------------------------------------------------------------------------------------
-- absent_candidate_needs_no_script
-- ---------------------------------------------------------------------------------------------
select is((select count(*)::int from public.scripts where booking_id = pg_temp.k('b4')) || '/' || pg_temp.missing('b4'), '0/',
  'absent_candidate_needs_no_script: absent b4 has no script and nothing missing');
select is(pg_temp.missing('b5') || pg_temp.missing('b6') || pg_temp.missing('b7'), '',
  'a cancelled booking, a home candidate and a candidate of another centre need nothing here');

-- ---------------------------------------------------------------------------------------------
-- More scans arrive; staff say a page of b3 was left blank (as the exception queue will).
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.batch('bt4', 'e', 'ce1') ->> 'number', 'B-' || (select exam_code from public.exams where id = pg_temp.k('e')) || '-04',
  'a later batch of the centre runs on');
select pg_temp.bgn('u4', 'bt4', 'application/pdf', 500);
select tests.as_postgres();
select pg_temp.put('u4', 500, 'application/pdf');
select tests.as_user(pg_temp.uid('admin'));
select pg_temp.stored('u4');
select is(pg_temp.submit('bt4') ->> 'queued', '1', 'its file is queued');
select is(pg_temp.code(pg_temp.complete('ce1')), 'still_processing', 'the centre waits for it');
select tests.as_postgres();
select is((select count(*)::int from public.custody_events where batch_id = pg_temp.k('bt4') and manifest_id is null and step = 'scanned'), 1,
  'a batch without a manifest records its scan without one');
select pg_temp.run('u4', jsonb_build_array(pg_temp.page('u4', 0, 'c2', 3)));
update public.script_exceptions set state = 'resolved', resolved_at = now(), resolution = 'dismiss_missing', details = details || '{"dismissed": [2]}'
where booking_id = pg_temp.k('b3') and kind = 'missing_pages' and state = 'open';

select tests.as_user(pg_temp.uid('admin'));
select pg_temp.batch('bt5', 'e', 'ce1');
select pg_temp.bgn('u5', 'bt5', 'application/pdf', 600);
select tests.as_postgres();
select pg_temp.put('u5', 600, 'application/pdf');
select tests.as_user(pg_temp.uid('admin'));
select pg_temp.stored('u5');
select is(pg_temp.code(pg_temp.complete('ce1')), 'still_processing', 'a stored file not yet handed to processing holds the centre too');
select pg_temp.submit('bt5');
select tests.as_postgres();
select pg_temp.run('u5', '[]'::jsonb);
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.counts(pg_temp.complete('ce1')), '4/3/1', 'now b2 is complete too; b3 still misses a page');
select tests.as_postgres();
select is(pg_temp.script('b2') || ' ' || pg_temp.missing('b2'), 'true/verified resolved:[3]', 'b2 is verified and its missing_pages exception resolved');
select is(pg_temp.missing('b3'), 'open:[3],resolved:[2, 3]', 'b3: page 2 was dismissed, so a new exception names page 3 alone');

select tests.as_postgres();
update public.attendance set status = 'absent' where exam_id = pg_temp.k('e') and student_id = pg_temp.uid('s3');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.counts(pg_temp.complete('ce1')), '3/3/0', 'b3 marked absent after all is no longer a candidate');
select tests.as_postgres();
select is((select count(*)::int from public.script_exceptions where booking_id = pg_temp.k('b3') and kind = 'missing_pages' and state = 'open'), 0,
  'and their open missing_pages exception is resolved');

-- A file adds b8's spare page 5 (a new version), then is run again and reads nothing: the rerun rolls that version
-- back and writes none.
create temp table v8 as select version from public.scripts where booking_id = pg_temp.k('b8');
select tests.as_user(pg_temp.uid('admin'));
select pg_temp.batch('bt6', 'e', 'ce1');
select pg_temp.bgn('u6', 'bt6', 'application/pdf', 900);
select tests.as_postgres();
select pg_temp.put('u6', 900, 'application/pdf');
select tests.as_user(pg_temp.uid('admin'));
select pg_temp.stored('u6');
select pg_temp.submit('bt6');
select tests.as_postgres();
select pg_temp.run('u6', jsonb_build_array(pg_temp.page('u6', 0, 'c8', 5)));
select is(pg_temp.script('b8'), 'false/needs_attention', 'a new version of b8''s script makes it incomplete');
select public.scan_booking_complete(pg_temp.k('b8'));
select is(pg_temp.script('b8'), 'true/needs_attention', 'checked again, it is complete');
insert into public.processing_jobs (upload_id, kind) values (pg_temp.k('u6'), 'prepare');
select pg_temp.run('u6', '[]'::jsonb);
select is((select s.version || '/' || (select count(*) from public.script_versions v where v.script_id = s.id) from public.scripts s where s.booking_id = pg_temp.k('b8')),
  (select version || '/' || version from v8), 'the rerun rolled the version back without writing a new one');
select is(pg_temp.script('b8'), 'false/needs_attention', 'and the script is incomplete again until it is checked');

-- A script past verification is Phase 3's: a version change leaves complete as it is.
update public.scripts set state = 'ready_to_mark' where booking_id = pg_temp.k('b1');
select ok((select public.script_version_write(s.id, public.script_links(s.id) - '5', null, null, 'test', now()) from public.scripts s where s.booking_id = pg_temp.k('b1')),
  'a new version is written for b1''s script, ready to mark');
select is(pg_temp.script('b1'), 'true/ready_to_mark', 'and it stays complete');

-- ---------------------------------------------------------------------------------------------
-- No paper version known (exam g has none): never complete, one missing_pages exception says why.
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
insert into res select 'cg1', pg_temp.complete_in('g', 'cg');
select is(pg_temp.counts(pg_temp.r('cg1')), '1/0/1', 'a candidate whose paper is not known is not complete');
select is(pg_temp.counts(pg_temp.complete_in('g', 'cg')), '1/0/1', 'nor when completing again');
select tests.as_postgres();
select is((select string_agg(state || ':' || details::text, ',') from public.script_exceptions where booking_id = pg_temp.k('gb') and kind = 'missing_pages'),
  'open:{"pages": [], "reason": "no_paper"}', 'one open missing_pages exception: no pages known, reason no_paper');

-- ---------------------------------------------------------------------------------------------
-- Pages of two paper versions (exam h): hb's first file has v1 pages 2, 3 and 5 and v2 page 4.
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select pg_temp.batch('bth1', 'h', 'ch');
select pg_temp.bgn('uh1', 'bth1', 'application/pdf', 700);
select tests.as_postgres();
select pg_temp.put('uh1', 700, 'application/pdf');
select tests.as_user(pg_temp.uid('admin'));
select pg_temp.stored('uh1');
select pg_temp.submit('bth1');
select tests.as_postgres();
select pg_temp.run('uh1', jsonb_build_array(pg_temp.page('uh1', 0, 'hc1', 2), pg_temp.page('uh1', 1, 'hc1', 3), pg_temp.page('uh1', 2, 'hc2', 4),
  pg_temp.page('uh1', 3, 'hc1', 5)));
update public.script_exceptions set state = 'resolved', resolved_at = now(), resolution = 'accepted'
where booking_id = pg_temp.k('hb') and kind = 'mixed_versions' and state = 'open';
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.counts(pg_temp.complete_in('h', 'ch')), '1/0/1',
  'pages of two versions: v1 pages 2-3 do not stand in for v2 pages 2-3, even with mixed_versions resolved');
select tests.as_postgres();
select is(pg_temp.script('hb') || ' ' || pg_temp.missing('hb'), 'false/needs_attention open:[2, 3]',
  'the script is not complete and v2''s pages 2 and 3 are missing');
select tests.as_user(pg_temp.uid('admin'));
select pg_temp.batch('bth2', 'h', 'ch');
select pg_temp.bgn('uh2', 'bth2', 'application/pdf', 800);
select tests.as_postgres();
select pg_temp.put('uh2', 800, 'application/pdf');
select tests.as_user(pg_temp.uid('admin'));
select pg_temp.stored('uh2');
select pg_temp.submit('bth2');
select tests.as_postgres();
select pg_temp.run('uh2', jsonb_build_array(pg_temp.page('uh2', 0, 'hc2', 2, 300), pg_temp.page('uh2', 1, 'hc2', 3, 300)));
update public.script_exceptions set state = 'resolved', resolved_at = now(), resolution = 'accepted'
where booking_id = pg_temp.k('hb') and kind = 'mixed_versions' and state = 'open';
select tests.as_user(pg_temp.uid('admin'));
select is((select concat_ws('/', j ->> 'candidates', j ->> 'complete', j ->> 'missing', j ->> 'mixed') from (select pg_temp.complete_in('h', 'ch') as j) x),
  '1/0/0/1', 'with every v2 answer page but v1 page 5 still linked, the script is reported mixed, not complete');
select tests.as_postgres();
select is(pg_temp.script('hb') || ' ' || pg_temp.missing('hb') || ' '
          || (select count(*) from public.script_exceptions where booking_id = pg_temp.k('hb') and kind = 'mixed_versions' and state = 'open'),
  'false/needs_attention resolved:[2, 3] 1', 'nothing is missing any more, and mixed_versions is open again for staff');

-- ---------------------------------------------------------------------------------------------
-- A removed centre takes no scans, collection, manifest or custody.
-- ---------------------------------------------------------------------------------------------
update public.exam_centres set removed_at = now() where id = pg_temp.k('ce3');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(pg_temp.batch(null, 'e', 'ce3')), 'conflict', 'no batch for a removed centre');
select is(pg_temp.code(pg_temp.complete('ce3')), 'conflict', 'nor completing it');
select is(pg_temp.code(public.collection_record(pg_temp.k('b9'), 1)), 'conflict', 'nor counting sheets of its candidate');
select is(pg_temp.code(public.collection_manifest_create(pg_temp.k('e'), pg_temp.k('ce3'))), 'conflict', 'nor a manifest');
select is(pg_temp.code(public.custody_record(pg_temp.k('e'), pg_temp.k('ce3'), 'collected', pg_temp.uid('admin'), null, 'Room', null)), 'conflict',
  'nor a custody event');
select tests.as_postgres();

select * from finish();
rollback;
