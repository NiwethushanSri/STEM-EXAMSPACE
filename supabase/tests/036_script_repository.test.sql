begin;
create extension if not exists pgtap with schema extensions;
select plan(126);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Exam e (centre ce, and home), 2031-08-04 10:00 London (09:00 UTC), 90 minutes: finish 10:30 UTC, on time
-- until 12:30 UTC. Its paper: version 1 (superseded) and version 2, 4 pages each (1 cover, 2-4 answer); every copy
-- has 6 pages (5-6 spare). Centre: b1, b2 (a v1 and, latest, a v2 copy), b5 present. Home: b3 hands in on time with a
-- page with no code that the family places after page 2 (staff confirm it), b4 hands in late. Exam f (centre cf): fb.
-- Index numbers SE-2097-66<nn> for s<nn>. Staff: admin (Ada Admin) and a teacher of the subject.
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('admin', tests.create_user('admin', 'active')), ('teacher', tests.create_user('teacher', 'active'));
insert into c select 's' || i, tests.create_user('student', 'active') from generate_series(1, 6) i;
update public.student_details d set index_number = 'SE-2097-66' || lpad(substr(c.name, 2), 2, '0') from c
where c.name ~ '^s[0-9]+$' and d.profile_id = c.id;
update public.profiles set first_name = 'Ada', last_name = 'Admin' where id = (select id from c where name = 'admin');
update public.profiles set first_name = 'Sam', last_name = 'One' where id = (select id from c where name = 's1');
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create temp table res (name text primary key, j jsonb);
grant all on res to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
create function pg_temp.r(p text) returns jsonb language sql stable as $$ select j from res where name = p $$;
create function pg_temp.code(j jsonb) returns text language sql immutable as $$ select coalesce(j ->> 'code', 'ok') $$;
create function pg_temp.kname(p uuid) returns text language sql stable as $$ select name from kv where id = p $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.r(text), pg_temp.code(jsonb), pg_temp.kname(uuid) to public;

insert into public.subjects (name, kind) values ('ZZ Script repository', 'school');
insert into public.venues (name, rooms) values ('ZZ Repository hall', array['R1']);
insert into public.exams (subject_id, title, paper, format, starts_at, duration_minutes, price_pence, price_confirmed, booking_deadline, status)
select s.id, 'ZZS ' || t.n, 'P1', 'both', t.at::timestamptz, 90, 0, true, t.at::timestamptz - interval '1 day', 'published'
from public.subjects s, (values ('e', '2031-08-04 10:00 Europe/London'), ('f', '2031-08-05 10:00 Europe/London')) t(n, at)
where s.name = 'ZZ Script repository';
insert into kv select substr(e.title, 5), e.id from public.exams e join public.subjects s on s.id = e.subject_id where s.name = 'ZZ Script repository';
insert into public.teacher_subjects select pg_temp.uid('teacher'), id from public.subjects where name = 'ZZ Script repository';
insert into public.exam_centres (exam_id, venue_id, room, seat_limit)
select pg_temp.k(t.x), v.id, 'R1', 50 from public.venues v, (values ('e'), ('f')) t(x) where v.name = 'ZZ Repository hall';
insert into kv select 'c' || t.x, ec.id from public.exam_centres ec join (values ('e'), ('f')) t(x) on ec.exam_id = pg_temp.k(t.x);

insert into public.exam_papers (exam_id, kind, title, version, storage_path, page_count, byte_size, superseded_at)
values (pg_temp.k('e'), 'paper', 'Question paper', 1, pg_temp.k('e')::text || '/' || gen_random_uuid()::text || '.pdf', 4, 1000, now());
insert into public.exam_papers (exam_id, kind, title, version, storage_path, page_count, byte_size)
values (pg_temp.k('e'), 'paper', 'Question paper', 2, pg_temp.k('e')::text || '/' || gen_random_uuid()::text || '.pdf', 4, 1000),
       (pg_temp.k('f'), 'paper', 'Question paper', 1, pg_temp.k('f')::text || '/' || gen_random_uuid()::text || '.pdf', 2, 1000);
insert into kv select 'pv' || version, id from public.exam_papers where exam_id = pg_temp.k('e');
insert into kv select 'pf', id from public.exam_papers where exam_id = pg_temp.k('f');
update public.paper_page_roles set role = (case page when 1 then 'cover' else 'answer' end)::public.page_role
where paper_id in (pg_temp.k('pv1'), pg_temp.k('pv2'));

insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting, centre_id)
select pg_temp.k('e'), pg_temp.uid(t.s), pg_temp.uid(t.s), 'paid', 0, t.sit::public.sitting_mode, case when t.sit = 'centre' then pg_temp.k('ce') end
from (values ('s1', 'centre'), ('s2', 'centre'), ('s3', 'home'), ('s4', 'home'), ('s5', 'centre')) t(s, sit);
insert into kv select 'b' || substr(s.name, 2), b.id from public.bookings b join c s on s.id = b.student_id where b.exam_id = pg_temp.k('e');
insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting, centre_id)
values (pg_temp.k('f'), pg_temp.uid('s6'), pg_temp.uid('s6'), 'paid', 0, 'centre', pg_temp.k('cf'));
insert into kv select 'fb', id from public.bookings where exam_id = pg_temp.k('f');
insert into public.paper_copies (code, booking_id, paper_id, page_count, created_at)
select public.copy_code_new(), pg_temp.k(t.b), pg_temp.k(t.p), t.n, now() - t.age * interval '1 hour'
from (values ('b1', 'pv2', 6, 0), ('b2', 'pv1', 6, 1), ('b2', 'pv2', 6, 0), ('b3', 'pv2', 6, 0), ('b4', 'pv2', 6, 0), ('b5', 'pv2', 6, 0),
             ('fb', 'pf', 4, 0)) t(b, p, n, age);
insert into kv select 'q' || substr(k.name, 2) || case when pc.paper_id = pg_temp.k('pv1') then 'a' else '' end, pc.id
from public.paper_copies pc join kv k on k.id = pc.booking_id where k.name ~ '^b[0-9]+$';
insert into kv select 'qf', pc.id from public.paper_copies pc where pc.booking_id = pg_temp.k('fb');
insert into public.attendance (exam_id, student_id, status, marked_by, marked_at)
select pg_temp.k(t.x), pg_temp.uid(t.s), 'present', pg_temp.uid('admin'), '2031-08-04 09:00Z'
from (values ('e', 's1'), ('e', 's2'), ('e', 's5'), ('f', 's6')) t(x, s);

-- The processing server (as postgres). An upload's pictures go to <exam>/<upload>/<job>-<attempt>/ (the job and attempt
-- that make them); legacy() is the upload's own folder.
create function pg_temp.job(p_up text, p_kind text) returns bigint language sql stable as $$
  select id from public.processing_jobs where upload_id = pg_temp.k(p_up) and kind = p_kind and state in ('queued', 'running')
  order by id desc limit 1 $$;
create function pg_temp.legacy(p_up text) returns text language sql stable as $$
  select u.exam_id::text || '/' || u.id::text || '/' from public.script_uploads u where u.id = pg_temp.k(p_up) $$;
create function pg_temp.dir(p_up text) returns text language sql stable as $$
  select pg_temp.legacy(p_up) || j.id || '-' || (j.attempts + case when j.state = 'queued' then 1 else 0 end) || '/'
  from public.processing_jobs j where j.upload_id = pg_temp.k(p_up) and j.kind = 'prepare' and j.state in ('queued', 'running')
  order by j.id desc limit 1 $$;
create function pg_temp.page(p_up text, p_idx int, p_copy text, p_page int, p_flags text[] default '{}', p_marking boolean default true,
  p_dir text default null) returns jsonb language sql stable as $$
  select jsonb_build_object('source_index', p_idx,
    'code', (select code from public.paper_copies where id = pg_temp.k(p_copy)), 'copy_page', case when p_copy is not null then p_page end,
    'blank', false,
    'quality', jsonb_build_object('sharpness', 200, 'brightness', 180, 'cut_off', false, 'flags', to_jsonb(p_flags)),
    'rotation', 0,
    'full_path', coalesce(p_dir, pg_temp.dir(p_up)) || p_idx || '-full.jpg',
    'marking_path', case when p_copy is not null and p_marking then coalesce(p_dir, pg_temp.dir(p_up)) || p_idx || '-marking.jpg' end)
$$;
-- Claims the upload's waiting prepare job, records these pages and finishes it.
create function pg_temp.run(p_up text, p_pages jsonb) returns jsonb language plpgsql as $$
declare
  v jsonb;
  r jsonb;
begin
  update public.processing_jobs set run_after = '2000-01-01' where upload_id = pg_temp.k(p_up) and state = 'queued' and kind = 'prepare';
  v := public.processing_job_claim('t-worker');
  -- The pages go to the claimed job's folder for this attempt (they may have been made before it existed, or for an
  -- earlier run of the file).
  p_pages := regexp_replace(p_pages::text, '/(none|[0-9]+-[0-9]+)/([0-9]+-(full|marking)[.]jpg)',
    '/' || (v -> 'job' ->> 'id') || '-' || (v -> 'job' ->> 'attempts') || '/\2', 'g')::jsonb;
  if v is null or v -> 'upload' ->> 'id' <> pg_temp.k(p_up)::text or v -> 'job' ->> 'kind' <> 'prepare' then
    raise exception 'claimed another job: %', v -> 'job';
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
-- Claims the upload's waiting remask job (it must be the one claimed).
create function pg_temp.claim_remask(p_up text) returns jsonb language plpgsql as $$
declare
  v jsonb;
begin
  update public.processing_jobs set run_after = '2000-01-01' where upload_id = pg_temp.k(p_up) and state = 'queued' and kind = 'remask';
  v := public.processing_job_claim('t-worker');
  if v is null or v -> 'upload' ->> 'id' <> pg_temp.k(p_up)::text or v -> 'job' ->> 'kind' <> 'remask' then
    raise exception 'claimed another job: %', v -> 'job';
  end if;
  return v;
end;
$$;
-- What the processor answers for a claimed remask: each page listed with a new marking picture in the job's own
-- folder, except the pages at the positions in p_none (no marking picture could be made).
create function pg_temp.answer(p_claim jsonb, p_none int[] default '{}') returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('page_id', x ->> 'page_id', 'rotation', (x ->> 'rotation')::int, 'key', x ->> 'key',
    'marking_path', case when (x ->> 'source_index')::int <> all (p_none) then
      (p_claim -> 'upload' ->> 'exam_id') || '/' || (p_claim -> 'upload' ->> 'id') || '/' || (p_claim -> 'job' ->> 'id') || '-'
      || (p_claim -> 'job' ->> 'attempts') || '/' || (x ->> 'source_index') || '-marking.jpg' end)), '[]'::jsonb)
  from jsonb_array_elements(p_claim -> 'pages') x $$;
create function pg_temp.remasked(p_claim jsonb, p_pages jsonb, p_worker text default 't-worker') returns jsonb language sql as $$
  select public.script_pages_remasked((p_claim -> 'job' ->> 'id')::bigint, p_worker, (p_claim -> 'job' ->> 'attempts')::int, p_pages) $$;
create function pg_temp.finish(p_claim jsonb, p_ok boolean) returns jsonb language sql as $$
  select public.processing_job_finish((p_claim -> 'job' ->> 'id')::bigint, 't-worker', (p_claim -> 'job' ->> 'attempts')::int, p_ok,
    case when not p_ok then 'RuntimeError' end) $$;
create function pg_temp.fail_remask(p_up text) returns jsonb language sql as $$
  select pg_temp.finish(pg_temp.claim_remask(p_up), false) $$;
-- One page of a claim, by position.
create function pg_temp.at(p_claim jsonb, p_idx int) returns jsonb language sql immutable as $$
  select x from jsonb_array_elements(p_claim -> 'pages') x where (x ->> 'source_index')::int = p_idx $$;
-- The current page at a position of an upload, and the latest exception of a kind about it.
create function pg_temp.pid(p_up text, p_idx int) returns uuid language sql stable as $$
  select id from public.script_pages where upload_id = pg_temp.k(p_up) and source_index = p_idx and replaced_at is null $$;
create function pg_temp.pg(p_up text, p_idx int) returns public.script_pages language sql stable as $$
  select * from public.script_pages where id = pg_temp.pid(p_up, p_idx) $$;
create function pg_temp.exc(p_up text, p_idx int, p_kind text) returns uuid language sql stable as $$
  select e.id from public.script_exceptions e where e.page_id = pg_temp.pid(p_up, p_idx) and e.kind::text = p_kind
  order by e.created_at desc, e.id limit 1 $$;
create function pg_temp.sid(p_booking text) returns uuid language sql stable as $$
  select id from public.scripts where booking_id = pg_temp.k(p_booking) $$;
create function pg_temp.state(p_booking text) returns text language sql stable as $$
  select state::text from public.scripts where booking_id = pg_temp.k(p_booking) $$;
-- The current links as <copy page>:<source index>@<upload>, in page order.
create function pg_temp.links(p_booking text) returns text language sql stable as $$
  select coalesce(string_agg(l.copy_page || ':' || p.source_index || '@' || coalesce(pg_temp.kname(p.upload_id), '?'), ','
                             order by l.copy_page), '')
  from public.scripts s join public.script_page_links l on l.script_id = s.id and l.version = s.version
  join public.script_pages p on p.id = l.page_id where s.booking_id = pg_temp.k(p_booking) $$;
-- Jobs of an upload by kind and state, e.g. 'queued' -> how many.
create function pg_temp.jobs(p_up text, p_kind text, p_state text) returns int language sql stable as $$
  select count(*)::int from public.processing_jobs where upload_id = pg_temp.k(p_up) and kind = p_kind and state::text = p_state $$;
-- The booking names a list answer's items stand for, in order of name.
create function pg_temp.listed(j jsonb) returns text language sql stable as $$
  select coalesce(string_agg(n, ',' order by n), '') from (
    select pg_temp.kname((x ->> 'booking_id')::uuid) as n from jsonb_array_elements(j -> 'items') x) t where n is not null $$;
grant execute on function pg_temp.job(text, text), pg_temp.legacy(text), pg_temp.dir(text),
  pg_temp.page(text, int, text, int, text[], boolean, text), pg_temp.pid(text, int), pg_temp.pg(text, int), pg_temp.exc(text, int, text),
  pg_temp.sid(text), pg_temp.state(text), pg_temp.links(text), pg_temp.jobs(text, text, text), pg_temp.listed(jsonb),
  pg_temp.at(jsonb, int), pg_temp.answer(jsonb, int[]) to public;

-- Family calls (as the signed-in user), as in 031.
create function pg_temp.hand_in(p_student text, p_booking text, p_sub text, p_up text, p_begin text, p_submit text)
returns void language plpgsql as $$
declare
  r jsonb;
begin
  perform tests.as_user(pg_temp.uid(p_student));
  r := public.home_submission_open(pg_temp.k(p_booking), true, p_begin::timestamptz);
  insert into kv values (p_sub, (r ->> 'submission_id')::uuid);
  r := public.script_upload_begin(pg_temp.k(p_sub), 'home_pdf', 'application/pdf', 5000, p_begin::timestamptz);
  insert into kv values (p_up, (r ->> 'upload_id')::uuid);
  perform tests.as_postgres();
  insert into storage.objects (bucket_id, name, metadata)
  values ('script-uploads', r ->> 'storage_path', jsonb_build_object('size', 5000, 'mimetype', 'application/pdf'));
  perform tests.as_user(pg_temp.uid(p_student));
  perform public.script_upload_stored(pg_temp.k(p_up));
  perform public.home_submission_submit(pg_temp.k(p_sub), p_submit::timestamptz);
  perform tests.as_postgres();
end $$;
-- A scanner file of a batch, queued for processing.
create function pg_temp.scan_file(p_up text, p_exam text, p_batch text, p_state text default 'queued', p_job boolean default true)
returns void language plpgsql as $$
begin
  insert into kv values (p_up, gen_random_uuid());
  insert into public.script_uploads (id, exam_id, batch_id, kind, position, storage_path, mime, byte_size, state, uploaded_by)
  values (pg_temp.k(p_up), pg_temp.k(p_exam), pg_temp.k(p_batch), 'scan_file', 1,
    'batch/' || pg_temp.k(p_batch) || '/' || pg_temp.k(p_up) || '.pdf', 'application/pdf', 1000, p_state::public.upload_state, pg_temp.uid('admin'));
  if p_job then
    insert into public.processing_jobs (upload_id, kind) values (pg_temp.k(p_up), 'prepare');
  end if;
end $$;

-- Jobs left in a local database by other work are not part of this test.
update public.processing_jobs set state = 'done' where state in ('queued', 'running');

-- Centre e, scanner file u1: 0-3 b1's pages 1-4; 4 b2's v1 page 2, 5-6 b2's v2 pages 3-4 (mixed versions); 7 b5's page 2,
-- 8 b5's page 3 (layout unexpected: no marking picture, poor quality); 9 a page with no code.
select tests.as_user(pg_temp.uid('admin'));
insert into res select 'bt', public.scan_batch_create(pg_temp.k('e'), pg_temp.k('ce'));
insert into res select 'btf', public.scan_batch_create(pg_temp.k('f'), pg_temp.k('cf'));
select tests.as_postgres();
insert into kv values ('bt', (pg_temp.r('bt') ->> 'batch_id')::uuid), ('btf', (pg_temp.r('btf') ->> 'batch_id')::uuid);
select pg_temp.scan_file('u1', 'e', 'bt');
select pg_temp.run('u1', jsonb_build_array(
  pg_temp.page('u1', 0, 'q1', 1), pg_temp.page('u1', 1, 'q1', 2), pg_temp.page('u1', 2, 'q1', 3), pg_temp.page('u1', 3, 'q1', 4),
  pg_temp.page('u1', 4, 'q2a', 2), pg_temp.page('u1', 5, 'q2', 3), pg_temp.page('u1', 6, 'q2', 4),
  pg_temp.page('u1', 7, 'q5', 2), pg_temp.page('u1', 8, 'q5', 3, '{layout_unexpected}', false), pg_temp.page('u1', 9, null, null)));
-- The folder of u1's first prepare job.
create temp table prep1 as select pg_temp.legacy('u1') || max(id) || '-1/' as dir from public.processing_jobs where upload_id = pg_temp.k('u1') and kind = 'prepare';
grant select on prep1 to public;
-- Centre f, scanner file uf: fb's pages 1-2.
select pg_temp.scan_file('uf', 'f', 'btf');
select pg_temp.run('uf', jsonb_build_array(pg_temp.page('uf', 0, 'qf', 1), pg_temp.page('uf', 1, 'qf', 2)));
-- Home b3: on time, with a page with no code (4) that the family places after page 2 and staff confirm.
select pg_temp.hand_in('s3', 'b3', 'd3', 'u3', '2031-08-04 10:40Z', '2031-08-04 10:45Z');
select pg_temp.run('u3', jsonb_build_array(pg_temp.page('u3', 0, 'q3', 1), pg_temp.page('u3', 1, 'q3', 2), pg_temp.page('u3', 2, 'q3', 3),
  pg_temp.page('u3', 3, 'q3', 4), pg_temp.page('u3', 4, null, null)));
insert into kv values ('p3_4', pg_temp.pid('u3', 4));
select tests.as_user(pg_temp.uid('s3'));
select public.home_page_place(pg_temp.k('p3_4'), 2);
select tests.as_postgres();
insert into kv values ('x3_4', pg_temp.exc('u3', 4, 'uncoded_family_page'));
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.script_exception_confirm(pg_temp.k('x3_4'), 'Working for question 2')), 'name_not_hidden',
  'R31: a family''s page with no code is confirmed only once its name is hidden or staff say there is none');
select is(public.script_exception_confirm(pg_temp.k('x3_4'), 'Working for question 2', true) ->> 'resolution', 'confirmed',
  'staff say there is no name on it');
select tests.as_postgres();
-- The processing server makes the marking pictures the confirmation asked for (the extra page's from the staff check).
insert into res select 'r0', pg_temp.claim_remask('u3');
select pg_temp.remasked(pg_temp.r('r0'), pg_temp.answer(pg_temp.r('r0')));
select pg_temp.finish(pg_temp.r('r0'), true);
-- Home b4: late.
select pg_temp.hand_in('s4', 'b4', 'd4', 'u4', '2031-08-04 13:00Z', '2031-08-04 13:05Z');
select pg_temp.run('u4', jsonb_build_array(pg_temp.page('u4', 0, 'q4', 1), pg_temp.page('u4', 1, 'q4', 2), pg_temp.page('u4', 2, 'q4', 3),
  pg_temp.page('u4', 3, 'q4', 4)));
-- The centre's papers were collected.
insert into public.custody_events (exam_id, centre_id, step, location, recorded_by)
values (pg_temp.k('e'), pg_temp.k('ce'), 'collected', 'Exam hall', pg_temp.uid('admin'));

select is(concat_ws(' ', pg_temp.state('b1'), pg_temp.state('b2'), pg_temp.state('b3'), pg_temp.state('b4'), pg_temp.state('b5'), pg_temp.state('fb')),
  'receiving needs_attention verified needs_attention needs_attention receiving',
  'fixture: b2 has mixed versions, b4 is late, b5 has a page of poor quality; b3 is verified');

-- ---------------------------------------------------------------------------------------------
-- Access.
-- ---------------------------------------------------------------------------------------------
select ok(not exists (select 1 from unnest(array[
    'public.scripts_list(uuid,public.script_source,public.script_state,boolean)', 'public.script_detail(uuid)',
    'public.script_page_rotate(uuid,integer,text)', 'public.script_upload_reprocess(uuid,text)', 'public.script_void(uuid,text)',
    'public.script_page_remove(uuid,integer,text)']) f
  where has_function_privilege('anon', f, 'execute') or not has_function_privilege('authenticated', f, 'execute')),
  'the repository functions are for signed-in users (they check the caller), never anon');
select ok(has_function_privilege('service_role', 'public.script_pages_remasked(bigint,text,integer,jsonb,timestamptz)', 'execute')
      and not has_function_privilege('authenticated', 'public.script_pages_remasked(bigint,text,integer,jsonb,timestamptz)', 'execute')
      and not has_function_privilege('anon', 'public.script_pages_remasked(bigint,text,integer,jsonb,timestamptz)', 'execute'),
  'script_pages_remasked is for the processing server only');
select ok(not exists (select 1 from unnest(array[
    'public.script_page_copy(uuid)', 'public.script_page_confirmed(uuid)', 'public.script_page_remask_context(uuid)',
    'public.script_page_remask_key(uuid)', 'public.script_page_lock(uuid,uuid[])', 'public.script_extra_pages(uuid)',
    'public.script_withdraw_on_booking()', 'public.script_pages_full_rotation()', 'public.script_page_areas_remask()',
    'public.script_remask_queue(uuid)']) f,
  unnest(array['anon', 'authenticated', 'service_role']) r where has_function_privilege(r, f, 'execute')), 'the repository helpers are internal');

-- ---------------------------------------------------------------------------------------------
-- list_filters
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('teacher'));
select is(pg_temp.code(public.scripts_list(pg_temp.k('e'))), 'forbidden', 'list_filters: a teacher cannot list scripts');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.listed(public.scripts_list(pg_temp.k('e'))), 'b1,b2,b3,b4,b5', 'the exam''s scripts, home and centre');
select is(pg_temp.listed(public.scripts_list()), 'b1,b2,b3,b4,b5,fb', 'every exam''s scripts without a filter');
select is(pg_temp.listed(public.scripts_list(pg_temp.k('e'), 'home')), 'b3,b4', 'by source: home');
select is(pg_temp.listed(public.scripts_list(pg_temp.k('e'), 'centre')), 'b1,b2,b5', 'by source: centre');
select is(pg_temp.listed(public.scripts_list(pg_temp.k('e'), null, 'needs_attention')), 'b2,b4,b5', 'by state');
select is(pg_temp.listed(public.scripts_list(pg_temp.k('e'), null, null, true)) || ' ' || pg_temp.listed(public.scripts_list(pg_temp.k('e'), null, null, false)),
  'b4 b1,b2,b3,b5', 'late, and not late');
insert into res select 'list', x from jsonb_array_elements(public.scripts_list(pg_temp.k('e')) -> 'items') x where (x ->> 'booking_id')::uuid = pg_temp.k('b1');
select is(concat_ws('/', pg_temp.r('list') ->> 'number' = (select number from public.scripts where booking_id = pg_temp.k('b1')),
    pg_temp.r('list') -> 'candidate' ->> 'name', pg_temp.r('list') -> 'candidate' ->> 'index_number', pg_temp.r('list') -> 'exam' ->> 'title',
    pg_temp.r('list') ->> 'source', pg_temp.r('list') ->> 'state', pg_temp.r('list') ->> 'late', pg_temp.r('list') ->> 'pages',
    pg_temp.r('list') ->> 'received_at' is not null),
  't/Sam One/SE-2097-6601/ZZS e/centre/receiving/false/4/t', 'an item: number, candidate, exam, source, state, late, pages, received');
select is((select (x ->> 'pages') || '+' || (x ->> 'extra_pages') from jsonb_array_elements(public.scripts_list(pg_temp.k('e'), 'home') -> 'items') x
           where (x ->> 'booking_id')::uuid = pg_temp.k('b3')), '4+1', 'a home script counts the family''s confirmed extra page');

-- ---------------------------------------------------------------------------------------------
-- detail_for_staff_only
-- ---------------------------------------------------------------------------------------------
select tests.as_postgres(); select tests.as_user(pg_temp.uid('teacher'));
select is(pg_temp.code(public.script_detail(pg_temp.sid('b1'))), 'forbidden', 'detail_for_staff_only: not a teacher');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(pg_temp.code(public.script_detail(pg_temp.sid('b1'))), 'forbidden', 'nor the candidate');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.script_detail(gen_random_uuid())), 'not_found', 'an unknown script is not found');
insert into res select 'd1', public.script_detail(pg_temp.sid('b1'));
select is(concat_ws('/', pg_temp.r('d1') -> 'candidate' ->> 'name', pg_temp.r('d1') -> 'candidate' ->> 'index_number',
    pg_temp.r('d1') -> 'script' ->> 'number' = (select number from public.scripts where booking_id = pg_temp.k('b1')),
    pg_temp.r('d1') -> 'script' ->> 'source'),
  'Sam One/SE-2097-6601/t/centre', 'staff see the candidate''s name and index number and the script');
select is((select string_agg(concat_ws(':', x ->> 'copy_page', x ->> 'role', x ->> 'source_index'), ',' order by n)
           from jsonb_array_elements(pg_temp.r('d1') -> 'pages') with ordinality t(x, n)),
  '1:cover:0,2:answer:1,3:answer:2,4:answer:3', 'its pages in order, with their roles');
select is((select count(*)::int from jsonb_array_elements(pg_temp.r('d1') -> 'pages') x
           where x ->> 'full_path' = (select dir from prep1) || (x ->> 'source_index') || '-full.jpg'
             and x ->> 'marking_path' = (select dir from prep1) || (x ->> 'source_index') || '-marking.jpg'
             and (x ->> 'upload_id')::uuid = pg_temp.k('u1') and (x ->> 'page_id')::uuid is not null
             and jsonb_typeof(x -> 'quality') = 'object'), 4, 'each page with its full and marking pictures, file, position and quality');
select is(concat_ws('/', jsonb_array_length(pg_temp.r('d1') -> 'versions'), pg_temp.r('d1') -> 'versions' -> 0 ->> 'reason',
    (select string_agg(pg_temp.kname((x ->> 'id')::uuid), ',') from jsonb_array_elements(pg_temp.r('d1') -> 'uploads') x),
    pg_temp.r('d1') -> 'uploads' -> 0 ->> 'batch_number' = (pg_temp.r('bt') ->> 'number'),
    (select string_agg(x ->> 'step', ',') from jsonb_array_elements(pg_temp.r('d1') -> 'custody') x)),
  '1/scan_upload/u1/t/collected', 'its versions, the file its pages came from (with the batch) and the centre''s custody');
insert into res select 'd3', public.script_detail(pg_temp.sid('b3'));
select is((select string_agg(coalesce(x ->> 'copy_page', '+' || (x ->> 'placed_after')) || ':' || (x ->> 'source_index'), ',' order by n)
           from jsonb_array_elements(pg_temp.r('d3') -> 'pages') with ordinality t(x, n)),
  '1:0,2:1,+2:4,3:2,4:3', 'a home script shows the family''s confirmed page after the page it follows');
select is((select concat_ws('/', x ->> 'extra', x ->> 'role', x ->> 'full_path' is not null) from jsonb_array_elements(pg_temp.r('d3') -> 'pages') x
           where x ->> 'copy_page' is null), 'true/extra/t', 'as an extra page, with its picture');
select is((select count(*)::int from jsonb_array_elements(public.script_detail(pg_temp.sid('b2')) -> 'exceptions') x
           where x ->> 'kind' = 'mixed_versions' and x ->> 'state' = 'open'), 1, 'and each script''s exceptions');
select is(pg_temp.r('d3') -> 'script' ->> 'source', 'home', 'every script says whether it is home or centre');

-- ---------------------------------------------------------------------------------------------
-- hidden_area_change_queues_remask: Task 1's areas now re-make the marking pictures of the pages they cover.
-- u9: a file of exam e being prepared (its job was claimed with the old areas).
-- ---------------------------------------------------------------------------------------------
select tests.as_postgres();
select pg_temp.scan_file('u9', 'e', 'bt', 'processing', false);
select is(concat_ws(' ', pg_temp.jobs('u1', 'remask', 'queued'), pg_temp.jobs('u4', 'remask', 'queued'), pg_temp.jobs('uf', 'remask', 'queued'),
    pg_temp.jobs('u9', 'remask', 'queued')), '0 0 0 0', 'no remask job waits before the areas change');
select tests.as_user(pg_temp.uid('admin'));
select is(public.set_paper_hidden_areas(pg_temp.k('pv1'), '[{"page":3,"x":0.1,"y":0.3,"w":0.3,"h":0.05}]') -> 'changed_pages', '[3]'::jsonb,
  'an area on page 3 of version 1');
select is(pg_temp.jobs('u1', 'remask', 'queued'), 0, 'hidden_area_change_queues_remask: no current page is of version 1''s page 3: nothing queued');
insert into res select 'areas', public.set_paper_hidden_areas(pg_temp.k('pv2'), '[{"page":2,"x":0.1,"y":0.2,"w":0.3,"h":0.05}]');
select is(pg_temp.r('areas') -> 'changed_pages', '[2]'::jsonb, 'an area on page 2 of version 2');
select is(concat_ws(' ', pg_temp.jobs('u1', 'remask', 'queued'), pg_temp.jobs('u3', 'remask', 'queued'), pg_temp.jobs('u4', 'remask', 'queued'),
    pg_temp.jobs('u9', 'remask', 'queued'), pg_temp.jobs('uf', 'remask', 'queued')), '1 1 1 1 0',
  'one remask job for each file with a current page 2 of version 2 and for the file being prepared, none for exam f');
select tests.as_postgres();
update public.processing_jobs set state = 'done' where upload_id = pg_temp.k('u9');

-- ---------------------------------------------------------------------------------------------
-- rotate_queues_remask
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('teacher'));
select is(pg_temp.code(public.script_page_rotate(pg_temp.pid('uf', 0), 1, 'Upside down')), 'forbidden', 'a teacher cannot turn a page');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.script_page_rotate(pg_temp.pid('uf', 0), 1, ' ')), 'reason_required', 'turning a page needs a reason');
select is(pg_temp.code(public.script_page_rotate(pg_temp.pid('uf', 0), 0, 'No turn')), 'invalid_input', 'and a turn');
select is(pg_temp.code(public.script_page_rotate(gen_random_uuid(), 1, 'Sideways')), 'not_found', 'of a page that exists');
select is(public.script_page_rotate(pg_temp.pid('uf', 0), 1, 'Scanned sideways') ->> 'rotation', '90', 'rotate_queues_remask: a quarter turn clockwise');
select tests.as_postgres();
select is(concat_ws('/', (pg_temp.pg('uf', 0)).rotation, (pg_temp.pg('uf', 0)).full_rotation, pg_temp.jobs('uf', 'remask', 'queued'),
    (select reason from public.audit_log where action = 'script_page_rotated' and target_id = pg_temp.pid('uf', 0))),
  '90/0/1/Scanned sideways', 'the page turns (its full picture stays as it was made), a remask job is queued, audited with the reason');
select tests.as_user(pg_temp.uid('admin'));
select is(public.script_page_rotate(pg_temp.pid('u1', 1), 2, 'Upside down') ->> 'rotation', '180', 'a half turn of b1''s page 2');
select is(public.script_page_rotate(pg_temp.pid('u1', 0), -1, 'Turn back') ->> 'rotation', '270', 'turns can go anticlockwise');
select tests.as_postgres();
select is(pg_temp.jobs('u1', 'remask', 'queued'), 1, 'one waiting remask job per file is enough');

-- ---------------------------------------------------------------------------------------------
-- The remask job: what the processing server is given, and what it may record.
-- ---------------------------------------------------------------------------------------------
insert into res select 'r1', pg_temp.claim_remask('u1');
select is((select string_agg(x ->> 'source_index', ',' order by (x ->> 'source_index')::int) from jsonb_array_elements(pg_temp.r('r1') -> 'pages') x),
  '1,2,3,4,5,6,7,8', 'remask: the file''s current answer pages (not the cover, nor the page with no code)');
select is(concat_ws('/', pg_temp.at(pg_temp.r('r1'), 1) ->> 'turn', pg_temp.at(pg_temp.r('r1'), 1) ->> 'rotation',
    pg_temp.at(pg_temp.r('r1'), 1) ->> 'code' = (select code from public.paper_copies where id = pg_temp.k('q1')),
    pg_temp.at(pg_temp.r('r1'), 1) ->> 'copy_page', pg_temp.at(pg_temp.r('r1'), 1) ->> 'provable', pg_temp.at(pg_temp.r('r1'), 1) ->> 'confirmed',
    pg_temp.at(pg_temp.r('r1'), 1) -> 'paper_areas', pg_temp.at(pg_temp.r('r1'), 1) -> 'staff_areas',
    pg_temp.at(pg_temp.r('r1'), 1) ->> 'full_path' = (pg_temp.pg('u1', 1)).full_path),
  '180/180/t/2/true/false/[{"h": 0.05, "w": 0.3, "x": 0.1, "y": 0.2}]/[]/t',
  'a page: the turn since its full picture was made, its code and copy page, its paper version''s areas and its full picture');
select is(concat_ws('/', pg_temp.at(pg_temp.r('r1'), 4) -> 'paper_areas', pg_temp.at(pg_temp.r('r1'), 8) ->> 'provable'),
  '[]/false', 'version 1''s page 2 has no area; a page whose layout was unexpected is not proved again');
create temp table snap as select p.id, to_jsonb(p) - 'marking_path' as j, p.marking_path from public.script_pages p where p.upload_id = pg_temp.k('u1');
select is(pg_temp.code(pg_temp.remasked(pg_temp.r('r1'), pg_temp.answer(pg_temp.r('r1')), 'other-worker')), 'conflict',
  'only the worker holding the job may record it');
select is(pg_temp.code(pg_temp.remasked(pg_temp.r('r1'), jsonb_set(pg_temp.answer(pg_temp.r('r1')), '{0,marking_path}',
    to_jsonb((select dir from prep1) || '1-marking.jpg')))), 'invalid_input', 'a marking picture outside the remask job''s own folder is refused');
select is(pg_temp.code(pg_temp.remasked(pg_temp.r('r1'), pg_temp.answer(pg_temp.r('r1')) || jsonb_build_array(jsonb_build_object(
    'page_id', pg_temp.pid('uf', 1), 'rotation', 0, 'key', 'x', 'marking_path', null)))), 'invalid_input', 'and a page of another file');
-- b2's page 4 already has an open poor_quality exception (blurred: it had a marking picture).
insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details)
values (pg_temp.k('e'), 'poor_quality', pg_temp.k('b2'), pg_temp.sid('b2'), pg_temp.pid('u1', 6), pg_temp.k('u1'),
  '{"flags": ["blurred"], "copy_page": 4, "marking_picture": true}');
insert into kv values ('x6', (select id from public.script_exceptions where page_id = pg_temp.pid('u1', 6) and kind = 'poor_quality'));
insert into res select 'rm1', pg_temp.remasked(pg_temp.r('r1'), pg_temp.answer(pg_temp.r('r1'), '{6,7,8}'));
select is(concat_ws('/', pg_temp.r('rm1') ->> 'ok', pg_temp.r('rm1') ->> 'pages', pg_temp.r('rm1') ->> 'marking', pg_temp.r('rm1') ->> 'stale'),
  'true/8/5/0', 'the server records the new marking pictures');
select is((pg_temp.pg('u1', 1)).marking_path, pg_temp.legacy('u1') || (pg_temp.r('r1') -> 'job' ->> 'id') || '-' || (pg_temp.r('r1') -> 'job' ->> 'attempts') || '/1-marking.jpg',
  'a new marking picture is in the remask job''s own folder');
select is((select count(*)::int from snap s join public.script_pages p on p.id = s.id where to_jsonb(p) - 'marking_path' = s.j),
  (select count(*)::int from snap), 'nothing but the marking picture changes: the full picture, rotation and the rest stay');
select is(concat_ws('/', (pg_temp.pg('u1', 7)).marking_path is null, (select marking_path from snap where id = pg_temp.pid('u1', 7)) is not null,
    (select details ->> 'from' from public.script_exceptions where page_id = pg_temp.pid('u1', 7) and kind = 'poor_quality' and state = 'open'),
    (select count(*) from public.script_exceptions where page_id = pg_temp.pid('u1', 8) and kind = 'poor_quality' and state = 'open')),
  't/t/remask/1', 'a centre answer page that loses its marking picture is raised for staff (once per page)');
select is((select concat_ws('/', count(*), min(details ->> 'from'), min(details ->> 'marking_picture'), min(details -> 'before_remask' ->> 'marking_picture'))
           from public.script_exceptions where page_id = pg_temp.pid('u1', 6) and kind = 'poor_quality' and state = 'open'),
  '1/remask/false/true', 'R32: a page with an open poor_quality exception that loses its picture: merged into that one, not skipped');
insert into kv values ('x7', pg_temp.exc('u1', 7, 'poor_quality'));
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.script_exception_confirm(pg_temp.k('x6'))) || ' ' || pg_temp.code(public.script_exception_confirm(pg_temp.k('x7'))),
  'name_not_hidden name_not_hidden', 'R32: accepting either needs the name hidden or none said (marking_picture false)');
select tests.as_postgres();
select is(pg_temp.finish(pg_temp.r('r1'), true) ->> 'state', 'done', 'the remask job is done');

-- A change while a remask job runs: the next job waits (one queued while one runs) and the stale page is not written.
select tests.as_user(pg_temp.uid('admin'));
select public.script_page_rotate(pg_temp.pid('u1', 3), 1, 'Sideways');
select tests.as_postgres();
insert into res select 'r2', pg_temp.claim_remask('u1');
select tests.as_user(pg_temp.uid('admin'));
select is(public.script_page_set_hidden_areas(pg_temp.pid('u1', 3), '[{"x":0.05,"y":0.05,"w":0.5,"h":0.05}]', 'Name written in the margin') ->> 'ok',
  'true', 'staff hide a name on page 4 while the remask job runs');
select tests.as_postgres();
select is(pg_temp.jobs('u1', 'remask', 'running') || '+' || pg_temp.jobs('u1', 'remask', 'queued'), '1+1',
  'staff hidden areas queue a remask job, which waits while one runs');
select is(pg_temp.remasked(pg_temp.r('r2'), pg_temp.answer(pg_temp.r('r2'))) ->> 'stale', '1', 'the running job''s page 4 is stale');
select is(concat_ws('/', (select resolution from public.script_exceptions where id = pg_temp.k('x7')),
    (select count(*) from public.audit_log where action = 'script_exception_marking_made' and target_id = pg_temp.k('x7')),
    (select state || ':' || details::text from public.script_exceptions where id = pg_temp.k('x6'))),
  'marking_made/1/open:{"flags": ["blurred"], "copy_page": 4, "marking_picture": true}',
  'R32: once the marking pictures are made again, the exception the remask raised closes and the merged one is as it was');
select tests.as_user(pg_temp.uid('admin'));
select is(public.script_exception_confirm(pg_temp.k('x6')) ->> 'resolution', 'confirmed', 'a blurred page with a marking picture is accepted as before');
select tests.as_postgres();
select is((pg_temp.pg('u1', 3)).marking_path, pg_temp.legacy('u1') || (pg_temp.r('r1') -> 'job' ->> 'id') || '-' || (pg_temp.r('r1') -> 'job' ->> 'attempts') || '/3-marking.jpg',
  'so its marking picture is not replaced by one made before the change');
select is(pg_temp.finish(pg_temp.r('r2'), true) ->> 'state', 'done', 'the job finishes');
insert into res select 'r3', pg_temp.claim_remask('u1');
select is(concat_ws('/', pg_temp.at(pg_temp.r('r3'), 3) ->> 'turn', pg_temp.at(pg_temp.r('r3'), 3) -> 'staff_areas' -> 0 ->> 'w'),
  '90/0.5', 'the next job makes it with the turn and the staff area');
select tests.as_user(pg_temp.uid('admin'));
select public.script_page_rotate(pg_temp.pid('u1', 3), -1, 'Back upright');
select tests.as_postgres();
select is(pg_temp.finish(pg_temp.r('r3'), false) ->> 'state', 'superseded', 'a failed attempt with a newer job waiting is superseded, not retried');
select is(pg_temp.jobs('u1', 'remask', 'queued') || '/' || (select state::text from public.processing_jobs where id = (pg_temp.r('r3') -> 'job' ->> 'id')::bigint),
  '1/done', 'the newer job waits; the superseded one is over');

-- A page whose layout was unexpected cannot be proved: it gets a marking picture only once staff confirm its name is
-- hidden (a staff area) or that there is none.
select is(public.script_page_remask_context(pg_temp.pid('u1', 8)) ->> 'confirmed', 'false', 'not confirmed before staff look at it');
insert into kv values ('x8', pg_temp.exc('u1', 8, 'poor_quality'));
select tests.as_user(pg_temp.uid('admin'));
select public.script_page_set_hidden_areas(pg_temp.pid('u1', 8), '[{"x":0.05,"y":0.03,"w":0.6,"h":0.05}]', 'Name across the top');
select public.script_exception_confirm(pg_temp.k('x8'));
select tests.as_postgres();
select is(concat_ws('/', public.script_page_remask_context(pg_temp.pid('u1', 8)) ->> 'confirmed',
    public.script_page_remask_context(pg_temp.pid('u1', 7)) ->> 'confirmed',
    (select concat_ws(':', details ->> 'confirmed_rotation', details ->> 'confirmed_areas' = public.script_page_areas_key(pg_temp.pid('u1', 8)))
     from public.script_exceptions where id = pg_temp.k('x8'))),
  'true/false/0:t', 'confirmed once staff hid the name and accepted it, bound to the page''s turn and areas then');
select tests.as_user(pg_temp.uid('admin'));
select public.script_page_rotate(pg_temp.pid('u1', 8), 1, 'Sideways');
select tests.as_postgres();
select is(public.script_page_remask_context(pg_temp.pid('u1', 8)) ->> 'confirmed', 'false', 'R32: a later turn undoes the confirmation');
select tests.as_user(pg_temp.uid('admin'));
select public.script_page_rotate(pg_temp.pid('u1', 8), -1, 'Upright again');
select tests.as_postgres();
select is(public.script_page_remask_context(pg_temp.pid('u1', 8)) ->> 'confirmed', 'true', 'turned back as staff saw it, it holds again');
select tests.as_user(pg_temp.uid('admin'));
select public.script_page_set_hidden_areas(pg_temp.pid('u1', 8), '[{"x":0.05,"y":0.03,"w":0.6,"h":0.05},{"x":0.5,"y":0.5,"w":0.1,"h":0.1}]', 'Another mark');
select tests.as_postgres();
select is(public.script_page_remask_context(pg_temp.pid('u1', 8)) ->> 'confirmed', 'false', 'R32: so does a change of its staff areas');

-- ---------------------------------------------------------------------------------------------
-- script_page_remove: takes a page out of a script (new version), which unsticks mixed versions.
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.script_page_remove(pg_temp.sid('b2'), 2, '')), 'reason_required', 'removing a page needs a reason');
select is(pg_temp.code(public.script_page_remove(pg_temp.sid('b2'), 1, 'Not there')), 'not_found', 'and a page the script shows');
select is(public.script_page_remove(pg_temp.sid('b2'), 2, 'Page of the old version, rescanned on the new') ->> 'version', '2',
  'script_page_remove: a new version');
select tests.as_postgres();
select is(concat_ws(' ', pg_temp.links('b2'),
    (select resolution from public.script_exceptions where booking_id = pg_temp.k('b2') and kind = 'mixed_versions'),
    (select created_by = pg_temp.uid('admin') from public.script_versions where script_id = pg_temp.sid('b2') and version = 2),
    (select count(*) from public.script_page_links where script_id = pg_temp.sid('b2') and version = 1),
    pg_temp.state('b2'),
    (select reason from public.audit_log where action = 'script_page_removed' and target_id = pg_temp.pid('u1', 4))),
  '3:5@u1,4:6@u1 one_version t 3 receiving Page of the old version, rescanned on the new',
  'without the version 1 page: mixed versions resolved, earlier version kept, the script worked out again, audited');
select is((pg_temp.pg('u1', 4)).state::text || '/' || ((pg_temp.pg('u1', 4)).replaced_at is null), 'matched/true', 'the page row is kept as it was');

-- ---------------------------------------------------------------------------------------------
-- A script past verification (fb ready to mark) keeps its pages; it may still be voided.
-- ---------------------------------------------------------------------------------------------
update public.scripts set state = 'ready_to_mark' where booking_id = pg_temp.k('fb');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.script_page_rotate(pg_temp.pid('uf', 1), 1, 'Sideways')), 'script_locked', 'no turning a page of a script being marked');
select is(pg_temp.code(public.script_upload_reprocess(pg_temp.k('uf'), 'Rescan')), 'script_locked', 'nor reprocessing its file');
select is(pg_temp.code(public.script_page_remove(pg_temp.sid('fb'), 1, 'Wrong page')), 'script_locked', 'nor removing its page');
select is(pg_temp.code(public.script_void(pg_temp.sid('fb'), '')), 'reason_required', 'void_needs_reason');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('teacher'));
select is(pg_temp.code(public.script_void(pg_temp.sid('fb'), 'Cheating')), 'forbidden', 'a teacher cannot void a script');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(public.script_void(pg_temp.sid('fb'), 'Candidate copied from a neighbour') ->> 'state', 'void', 'a script being marked can be voided');
select tests.as_postgres();
select is(concat_ws('/', (select state_reason from public.scripts where booking_id = pg_temp.k('fb')),
    (select reason from public.audit_log where action = 'script_voided' and target_id = pg_temp.sid('fb'))),
  'voided/Candidate copied from a neighbour', 'void, audited with the reason');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.script_void(pg_temp.sid('fb'), 'Again')), 'conflict', 'a void script is not voided twice');
select tests.as_postgres();
update public.scripts set state = 'final' where booking_id = pg_temp.k('fb');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.script_void(pg_temp.sid('fb'), 'Too late')), 'script_locked', 'a final script cannot be voided');
select tests.as_postgres();
update public.bookings set status = 'cancelled' where id = pg_temp.k('fb');
select is(pg_temp.state('fb'), 'final', 'a final script stays final when its booking is cancelled');

-- ---------------------------------------------------------------------------------------------
-- reprocess_queues_prepare
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('teacher'));
select is(pg_temp.code(public.script_upload_reprocess(pg_temp.k('u1'), 'Rescan')), 'forbidden', 'a teacher cannot reprocess a file');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.script_upload_reprocess(pg_temp.k('u1'), 'x')), 'reason_required', 'reprocessing needs a reason');
select is(pg_temp.code(public.script_upload_reprocess(gen_random_uuid(), 'Rescan')), 'not_found', 'of a file that exists');
insert into res select 'rp', public.script_upload_reprocess(pg_temp.k('u1'), 'Pages read wrongly');
select tests.as_postgres();
select is(concat_ws('/', pg_temp.r('rp') ->> 'ok', (pg_temp.r('rp') ->> 'job_id')::bigint = pg_temp.job('u1', 'prepare'),
    (select state::text from public.script_uploads where id = pg_temp.k('u1')),
    (select reason from public.audit_log where action = 'script_upload_reprocess' and target_id = pg_temp.k('u1'))),
  'true/t/queued/Pages read wrongly', 'reprocess_queues_prepare: a prepare job is queued, the file waits, audited');
select is(concat_ws(' ', pg_temp.state('b1'), pg_temp.state('b2'), pg_temp.state('b5')), 'checking checking checking',
  'the scripts showing its pages are being checked again');
select tests.as_user(pg_temp.uid('admin'));
select is(public.script_upload_reprocess(pg_temp.k('u1'), 'Again') ->> 'reason', 'busy', 'a file waiting to be prepared is not queued twice');
select tests.as_postgres();
-- The waiting remask job is due first, but waits while the file is prepared again.
update public.processing_jobs set run_after = '1999-01-01' where upload_id = pg_temp.k('u1') and kind = 'remask' and state = 'queued';
insert into res select 'old5', to_jsonb(pg_temp.pg('u1', 5));
select is(pg_temp.run('u1', jsonb_build_array(
  pg_temp.page('u1', 0, 'q1', 1), pg_temp.page('u1', 1, 'q1', 2), pg_temp.page('u1', 2, 'q1', 3), pg_temp.page('u1', 3, 'q1', 4),
  pg_temp.page('u1', 4, 'q2a', 2), pg_temp.page('u1', 5, 'q2', 3), pg_temp.page('u1', 6, 'q2', 4),
  pg_temp.page('u1', 7, 'q5', 2), pg_temp.page('u1', 8, 'q5', 3, '{layout_unexpected}', false), pg_temp.page('u1', 9, null, null))) ->> 'pages',
  '10', 'the prepare job is claimed before the remask job waiting on the same file, and records the file again');
select is(concat_ws('/', (select replaced_at is not null from public.script_pages where id = (pg_temp.r('old5') ->> 'id')::uuid),
    (select full_path from public.script_pages where id = (pg_temp.r('old5') ->> 'id')::uuid) = (select dir from prep1) || '5-full.jpg',
    (pg_temp.pg('u1', 5)).full_path = pg_temp.legacy('u1') || (pg_temp.r('rp') ->> 'job_id') || '-1/5-full.jpg'),
  't/t/t', 'a page kept with its old version keeps its own picture; the rerun''s pictures are in the new job''s folder');
insert into res select 'r4', pg_temp.claim_remask('u1');
select is((select count(*)::int from jsonb_array_elements(pg_temp.r('r4') -> 'pages') x
           join public.script_pages p on p.id = (x ->> 'page_id')::uuid where p.replaced_at is null), 8,
  'then the remask job runs on the file''s new pages');
select is(pg_temp.finish(pg_temp.r('r4'), false) ->> 'state', 'queued', 'a failed remask attempt is retried');

-- ---------------------------------------------------------------------------------------------
-- cancelled_booking_withdraws_script
-- ---------------------------------------------------------------------------------------------
update public.bookings set status = 'cancelled' where id = pg_temp.k('b4');
select is((select state::text || '/' || state_reason from public.scripts where booking_id = pg_temp.k('b4')), 'withdrawn/booking_cancelled',
  'cancelled_booking_withdraws_script');
update public.bookings set status = 'refunded' where id = pg_temp.k('b5');
select is((select state::text || '/' || state_reason from public.scripts where booking_id = pg_temp.k('b5')), 'withdrawn/booking_refunded',
  'a refunded booking''s script is withdrawn too');

-- ---------------------------------------------------------------------------------------------
-- R31 (b): at home, a remask that cannot make a page's marking picture again takes the old one away and tells staff;
-- the family is not asked to take the page again.
-- ---------------------------------------------------------------------------------------------
select is(pg_temp.state('b3') || ' ' || (select state::text from public.home_submissions where id = pg_temp.k('d3')), 'verified received',
  'b3 is verified, its submission received');
insert into res select 'r5', pg_temp.claim_remask('u3');
insert into res select 'rm5', pg_temp.remasked(pg_temp.r('r5'), pg_temp.answer(pg_temp.r('r5'), '{1}'));
select is(pg_temp.finish(pg_temp.r('r5'), true) ->> 'state', 'done', 'the remask job could not make page 2''s marking picture again');
insert into kv values ('x5_1', (select id from public.script_exceptions where page_id = pg_temp.pid('u3', 1) and kind = 'poor_quality' and state = 'open'));
select is(concat_ws('/', (pg_temp.pg('u3', 1)).marking_path is null,
    (select concat_ws(':', details ->> 'from', details ->> 'marking_picture', script_id = pg_temp.sid('b3')) from public.script_exceptions where id = pg_temp.k('x5_1')),
    (select count(*) from public.script_exceptions where page_id = pg_temp.pid('u3', 1) and kind = 'poor_quality'),
    (select state::text from public.home_submissions where id = pg_temp.k('d3')), pg_temp.state('b3')),
  't/remask:false:t/1/received/needs_attention',
  'the old marking picture is gone, one open poor_quality exception from remask; the family is not asked to retake; the script waits for staff');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.script_exception_reject(pg_temp.k('x5_1'), 'Unreadable page')), 'wrong_kind',
  'it is not the family''s file: it cannot be rejected');
select is((select x ->> 'rejects_submission' from jsonb_array_elements(public.script_detail(pg_temp.sid('b3')) -> 'exceptions') x
           where (x ->> 'id')::uuid = pg_temp.k('x5_1')), 'false', 'and the queue does not offer to reject the submission');
select is(pg_temp.code(public.script_exception_confirm(pg_temp.k('x5_1'))), 'name_not_hidden', 'staff hide the name or say there is none first');
select is(public.script_exception_confirm(pg_temp.k('x5_1'), 'Checked: the name band is empty', true) ->> 'resolution', 'confirmed',
  'staff say there is no name on it');
select tests.as_postgres();
select is(concat_ws('/', pg_temp.jobs('u3', 'remask', 'queued'), public.script_page_remask_context(pg_temp.pid('u3', 1)) ->> 'confirmed',
    (select details ->> 'no_name' from public.script_exceptions where id = pg_temp.k('x5_1')), pg_temp.state('b3'),
    (select state::text from public.home_submissions where id = pg_temp.k('d3'))),
  '1/true/true/needs_attention/received',
  'R32: a remask is queued; nothing is open, but while its answer page has no marking picture the script is not verified');
insert into res select 'r5b', pg_temp.claim_remask('u3');
select pg_temp.remasked(pg_temp.r('r5b'), pg_temp.answer(pg_temp.r('r5b')));
select pg_temp.finish(pg_temp.r('r5b'), true);
select is(pg_temp.state('b3'), 'verified', 'once the remask makes its picture (proved again), the script is verified');

-- ---------------------------------------------------------------------------------------------
-- A remask job that fails for good: the scripts showing the file's pages are worked out again.
-- ---------------------------------------------------------------------------------------------
select is(pg_temp.state('b3'), 'verified', 'b3 is verified');
-- A privacy change: a new hidden area on page 3 of version 2 queues a remask of b3's file, which fails for good.
select tests.as_user(pg_temp.uid('admin'));
select is(public.set_paper_hidden_areas(pg_temp.k('pv2'), '[{"page":2,"x":0.1,"y":0.2,"w":0.3,"h":0.05},{"page":3,"x":0.6,"y":0.1,"w":0.3,"h":0.05}]')
  -> 'changed_pages', '[3]'::jsonb, 'an area is added on page 3 of version 2');
select tests.as_postgres();
select pg_temp.fail_remask('u3');
select pg_temp.fail_remask('u3');
select is(pg_temp.fail_remask('u3') ->> 'state', 'failed', 'b3''s file''s remask job fails for good');
select is(concat_ws('/', (select details ->> 'kind' from public.script_exceptions where upload_id = pg_temp.k('u3') and kind = 'processing_failed'),
    (select script_id = pg_temp.sid('b3') from public.script_exceptions where upload_id = pg_temp.k('u3') and kind = 'processing_failed'),
    pg_temp.state('b3')),
  'remask/t/needs_attention', 'staff are told, and the home script is worked out again: it needs attention');
select is(concat_ws('/', (select count(*) from public.script_pages where upload_id = pg_temp.k('u3') and replaced_at is null and marking_path is not null
                           and (public.script_page_remask_context(id) ->> 'answer')::boolean),
    (select count(*) from public.script_exceptions e join public.script_pages p on p.id = e.page_id
     where p.upload_id = pg_temp.k('u3') and e.kind = 'poor_quality' and e.state = 'open' and e.details ->> 'from' = 'remask'),
    (select concat_ws(':', pg_temp.kname(booking_id), script_id = pg_temp.sid('b3')) from public.script_exceptions
     where page_id = pg_temp.k('p3_4') and kind = 'poor_quality' and state = 'open')),
  '0/4/b3:t', 'R32: its answer pages lose their marking pictures (made before the change) and each goes to staff, the extra page on b3''s script');
insert into kv values ('x_pf3', (select id from public.script_exceptions where upload_id = pg_temp.k('u3') and kind = 'processing_failed'));
select tests.as_user(pg_temp.uid('admin'));
select is(public.script_exception_confirm(pg_temp.k('x_pf3'), 'Try again') ->> 'resolution', 'confirmed', 'staff note the failure');
select tests.as_postgres();
select is(pg_temp.jobs('u3', 'remask', 'queued'), 1, 'R32: noting a remask failure queues the remask again');
select is(pg_temp.state('b1'), 'receiving', 'b1 is receiving');
select pg_temp.fail_remask('u1');
select is(pg_temp.fail_remask('u1') ->> 'state', 'failed', 'u1''s remask job fails for good');
select is((select string_agg(pg_temp.kname(booking_id), ',' order by pg_temp.kname(booking_id)) from public.script_exceptions
           where upload_id = pg_temp.k('u1') and kind = 'processing_failed' and state = 'open'), 'b1,b2,b5',
  'a scanner file''s failure is raised for each script showing its pages');
select is(pg_temp.state('b1') || ' ' || pg_temp.state('b5'), 'needs_attention withdrawn', 'which are worked out again (a withdrawn one stays)');

-- ---------------------------------------------------------------------------------------------
-- R31 (a): a page with no code is assigned only once its name is hidden or staff say there is none; it then gets a
-- marking picture from the staff check (u1's page 9 to b1's spare page 5).
-- ---------------------------------------------------------------------------------------------
insert into kv values ('x9', pg_temp.exc('u1', 9, 'no_code')), ('p1_9', pg_temp.pid('u1', 9));
select is(pg_temp.jobs('u1', 'remask', 'queued'), 0, 'no remask job waits for u1');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.script_exception_assign(pg_temp.k('x9'), pg_temp.k('b1'), 5, 'Spare page, code torn off')), 'name_not_hidden',
  'R31: a page with no code is not assigned before its name is hidden or staff say there is none');
select is(public.script_exception_assign(pg_temp.k('x9'), pg_temp.k('b1'), 5, 'Spare page, code torn off', false, true) ->> 'resolution', 'assigned',
  'staff say there is no name on it, and it is assigned');
select tests.as_postgres();
select is(concat_ws('/', (select details ->> 'no_name' from public.script_exceptions where id = pg_temp.k('x9')),
    public.script_page_remask_context(pg_temp.k('p1_9')) ->> 'answer', public.script_page_remask_context(pg_temp.k('p1_9')) ->> 'provable',
    public.script_page_remask_context(pg_temp.k('p1_9')) ->> 'confirmed', pg_temp.jobs('u1', 'remask', 'queued')),
  'true/true/false/true/1', 'recorded; an answer page that cannot be proved but is confirmed, and a remask job is queued for its file');
insert into res select 'r6', pg_temp.claim_remask('u1');
select is(concat_ws('/', pg_temp.at(pg_temp.r('r6'), 9) ->> 'confirmed', coalesce(pg_temp.at(pg_temp.r('r6'), 9) ->> 'code', 'none')), 'true/none',
  'the remask job is told to make it from the staff check (no code to prove it by)');
select is(pg_temp.remasked(pg_temp.r('r6'), pg_temp.answer(pg_temp.r('r6'))) ->> 'ok', 'true', 'its marking picture is recorded');
select is((pg_temp.pg('u1', 9)).marking_path, pg_temp.legacy('u1') || (pg_temp.r('r6') -> 'job' ->> 'id') || '-' || (pg_temp.r('r6') -> 'job' ->> 'attempts') || '/9-marking.jpg', 'page 9 has a marking picture');
select pg_temp.finish(pg_temp.r('r6'), true);

-- ---------------------------------------------------------------------------------------------
-- Per-run picture folders: a prepare job's pictures must be in the folder of the job and its attempt.
-- ---------------------------------------------------------------------------------------------
select pg_temp.scan_file('u8', 'e', 'bt');
update public.processing_jobs set run_after = '2000-01-01' where upload_id = pg_temp.k('u8');
insert into res select 'p8', public.processing_job_claim('t-worker');
select is(public.script_pages_record((pg_temp.r('p8') -> 'job' ->> 'id')::bigint, 't-worker', 1, repeat('a', 64),
    jsonb_build_array(pg_temp.page('u8', 0, null, null, '{}', true, pg_temp.legacy('u8') || '999999-1/'))) ->> 'code', 'invalid_input',
  'pictures in another job''s folder are refused');
select is(public.script_pages_record((pg_temp.r('p8') -> 'job' ->> 'id')::bigint, 't-worker', 1, repeat('a', 64),
    jsonb_build_array(pg_temp.page('u8', 0, null, null, '{}', true, pg_temp.legacy('u8') || (pg_temp.r('p8') -> 'job' ->> 'id') || '-2/'))) ->> 'code',
  'invalid_input', 'and in another attempt''s folder');
select is(public.script_pages_record((pg_temp.r('p8') -> 'job' ->> 'id')::bigint, 't-worker', 1, repeat('a', 64),
    jsonb_build_array(pg_temp.page('u8', 0, null, null, '{}', true, pg_temp.legacy('u8')))) ->> 'code', 'invalid_input',
  'and in the file''s own folder (R32: no longer accepted)');
select is(public.script_pages_record((pg_temp.r('p8') -> 'job' ->> 'id')::bigint, 't-worker', 1, repeat('a', 64),
    jsonb_build_array(pg_temp.page('u8', 0, null, null))) ->> 'ok', 'true', 'pictures in the job''s own folder are recorded');

select * from finish();
rollback;
