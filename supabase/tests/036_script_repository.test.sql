begin;
create extension if not exists pgtap with schema extensions;
select plan(194);
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
    'full_path', coalesce(p_dir, pg_temp.dir(p_up), pg_temp.legacy(p_up) || 'none/') || p_idx || '-full.jpg',
    'marking_path', case when p_copy is not null and p_marking then coalesce(p_dir, pg_temp.dir(p_up), pg_temp.legacy(p_up) || 'none/') || p_idx || '-marking.jpg' end)
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
-- Phase 3A (Task 8): an admin checks the marking pictures that wait on a candidate's script ("The name is hidden").
create function pg_temp.check_pictures(p_booking text) returns void language plpgsql as $$
begin
  perform tests.as_user(pg_temp.uid('admin'));
  perform public.script_page_marking_checked((x ->> 'page_id')::uuid, x ->> 'marking_path')
  from jsonb_array_elements(public.script_marking_checks_list() -> 'items') x
  where x ->> 'script_number' = (select s.number from public.scripts s where s.booking_id = pg_temp.k(p_booking));
  perform tests.as_postgres();
end $$;
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
select pg_temp.check_pictures('b3');
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
-- R35: a file staff have worked on is not processed again; a script being marked is never changed; no link ever
-- points at a replaced page. Each scenario starts from the fixture above and is rolled back when it ends
-- (pg_temp.scenario), so they do not disturb each other or the tests below.
-- ---------------------------------------------------------------------------------------------
-- Runs a scenario function in a subtransaction, takes its answer out and rolls back all it did.
create function pg_temp.scenario(p_fn text) returns text language plpgsql as $$
declare
  v text;
begin
  begin
    execute format('select pg_temp.%I()', p_fn) into v;
    raise exception using errcode = 'ZZ035', message = coalesce(v, '(null)');
  exception when sqlstate 'ZZ035' then
    v := sqlerrm;
  end;
  perform tests.as_postgres();
  return v;
end $$;
-- A statement run as the admin; its jsonb answer.
create function pg_temp.as_admin(p_sql text) returns jsonb language plpgsql as $$
declare
  r jsonb;
begin
  perform tests.as_user(pg_temp.uid('admin'));
  execute p_sql into r;
  perform tests.as_postgres();
  return r;
end $$;
-- Staff ask for the file to be processed again: the answer's code and reason.
create function pg_temp.ask(p_up text) returns text language sql as $$
  select concat_ws(':', pg_temp.code(r), r ->> 'reason')
  from pg_temp.as_admin(format('select public.script_upload_reprocess(pg_temp.k(%L), %L)', p_up, 'Read it again')) r $$;
-- A prepare job of the file runs although the reprocess was refused (as one already waiting when staff worked on the
-- file would): what the record answers (kept:<why>, or the pages recorded).
create function pg_temp.forced(p_up text, p_pages jsonb) returns text language plpgsql as $$
declare
  r jsonb;
begin
  insert into public.processing_jobs (upload_id, kind) values (pg_temp.k(p_up), 'prepare') on conflict do nothing;
  r := pg_temp.run(p_up, p_pages);
  return case when (r ->> 'kept')::boolean then 'kept:' || (r ->> 'reason') else 'recorded:' || (r ->> 'pages') end;
end $$;
-- The processing server answers the file's waiting remask job as pipeline.remask decides: a page that may be proved gets
-- a picture only upright (proved again); any other page only while confirmed. 'none' when no remask job waits.
create function pg_temp.sim(p_up text) returns text language plpgsql as $$
declare
  v jsonb;
  r jsonb;
begin
  if pg_temp.jobs(p_up, 'remask', 'queued') = 0 then
    return 'none';
  end if;
  v := pg_temp.claim_remask(p_up);
  r := public.script_pages_remasked((v -> 'job' ->> 'id')::bigint, 't-worker', (v -> 'job' ->> 'attempts')::int, (
    select coalesce(jsonb_agg(jsonb_build_object('page_id', x ->> 'page_id', 'rotation', (x ->> 'rotation')::int, 'key', x ->> 'key',
      'marking_path', case when (case when (x ->> 'provable')::boolean then (x ->> 'turn')::int = 0 else (x ->> 'confirmed')::boolean end)
        then (v -> 'upload' ->> 'exam_id') || '/' || (v -> 'upload' ->> 'id') || '/' || (v -> 'job' ->> 'id') || '-'
        || (v -> 'job' ->> 'attempts') || '/' || (x ->> 'source_index') || '-marking.jpg' end)), '[]'::jsonb)
    from jsonb_array_elements(v -> 'pages') x));
  perform public.processing_job_finish((v -> 'job' ->> 'id')::bigint, 't-worker', (v -> 'job' ->> 'attempts')::int, true);
  return (r ->> 'marking') || '/' || (r ->> 'pages');
end $$;
-- What must hold whatever happened: no script link points at a replaced page (stale), no page is in two scripts
-- (twice), no verified script shows an answer page without a marking picture (bare), and no open exception is left on
-- a replaced page (orphans).
create function pg_temp.safe() returns text language sql stable as $$
  select concat_ws(' ',
    'stale=' || (select count(*) from public.script_page_links l join public.scripts s on s.id = l.script_id and l.version = s.version
                 join public.script_pages p on p.id = l.page_id where p.replaced_at is not null),
    'twice=' || (select count(*) from (select l.page_id from public.script_page_links l
                 join public.scripts s on s.id = l.script_id and l.version = s.version group by l.page_id having count(*) > 1) t),
    'bare=' || (select count(*) from public.script_page_links l join public.scripts s on s.id = l.script_id and l.version = s.version
                join public.script_pages p on p.id = l.page_id
                where s.state = 'verified' and p.marking_path is null and (public.script_page_remask_context(p.id) ->> 'answer')::boolean),
    'orphans=' || (select count(*) from public.script_exceptions e join public.script_pages p on p.id = e.page_id
                   where e.state = 'open' and p.replaced_at is not null)) $$;
-- A page as markers would get it: its staff hidden areas, whether it has a marking picture, whether a script shows it.
create function pg_temp.seen(p_page uuid) returns text language sql stable as $$
  select concat_ws(' ', 'areas=' || (select count(*) from public.script_page_hidden_areas a where a.page_id = p.id),
    'mk=' || (p.marking_path is not null), 'replaced=' || (p.replaced_at is not null),
    'shown=' || (select count(*) from public.script_page_links l join public.scripts s on s.id = l.script_id and l.version = s.version
                 where l.page_id = p.id))
  from public.script_pages p where p.id = p_page $$;
-- A page for run(): its pictures in a placeholder folder (run() moves them to the claimed job's folder).
create function pg_temp.pp(p_up text, p_idx int, p_copy text, p_page int, p_flags text[] default '{}', p_marking boolean default true)
returns jsonb language sql stable as $$
  select pg_temp.page(p_up, p_idx, p_copy, p_page, p_flags, p_marking, pg_temp.legacy(p_up) || 'none/') $$;
grant execute on function pg_temp.pp(text, int, text, int, text[], boolean) to public;
create function pg_temp.u1pages(p2_copy_page int default 3, p2_flags text[] default '{}') returns jsonb language sql stable as $$
  select jsonb_build_array(
    pg_temp.pp('u1', 0, 'q1', 1), pg_temp.pp('u1', 1, 'q1', 2), pg_temp.pp('u1', 2, 'q1', p2_copy_page, p2_flags),
    jsonb_set(pg_temp.pp('u1', 3, 'q1', 4), '{quality,sharpness}', '400'),
    pg_temp.pp('u1', 4, 'q2a', 2), pg_temp.pp('u1', 5, 'q2', 3), pg_temp.pp('u1', 6, 'q2', 4),
    pg_temp.pp('u1', 7, 'q5', 2), pg_temp.pp('u1', 8, 'q5', 3, '{layout_unexpected}', false), pg_temp.pp('u1', 9, null, null)) $$;
create function pg_temp.u3pages() returns jsonb language sql stable as $$
  select jsonb_build_array(pg_temp.pp('u3', 0, 'q3', 1), pg_temp.pp('u3', 1, 'q3', 2), pg_temp.pp('u3', 2, 'q3', 3),
    pg_temp.pp('u3', 3, 'q3', 4), pg_temp.pp('u3', 4, null, null)) $$;
create function pg_temp.u4pages() returns jsonb language sql stable as $$
  select jsonb_build_array(pg_temp.pp('u4', 0, 'q4', 1), pg_temp.pp('u4', 1, 'q4', 2), pg_temp.pp('u4', 2, 'q4', 3),
    pg_temp.pp('u4', 3, 'q4', 4)) $$;
create function pg_temp.vers(p_b text) returns text language sql stable as $$
  select string_agg(v.version || ':' || v.reason || ':' || coalesce(pg_temp.kname(v.upload_id), pg_temp.kname(v.submission_id), '-') || ':'
                    || case when v.created_by is null then 'sys' else 'staff' end, ',' order by v.version)
  from public.script_versions v where v.script_id = pg_temp.sid(p_b) $$;
grant execute on function pg_temp.safe(), pg_temp.seen(uuid), pg_temp.u1pages(int, text[]), pg_temp.u3pages(), pg_temp.u4pages(),
  pg_temp.vers(text) to public;

-- What stops a reprocess, one kind of staff work at a time.
create function pg_temp.s_untouched() returns text language plpgsql as $$
declare
  v text;
begin
  v := concat_ws(' ', pg_temp.ask('u4'), pg_temp.forced('u4', pg_temp.u4pages()));
  return concat_ws(' ', v, pg_temp.links('b4'), pg_temp.state('b4'), pg_temp.safe());
end $$;
create function pg_temp.s_turned() returns text language plpgsql as $$
begin
  perform pg_temp.as_admin($q$select public.script_page_rotate(pg_temp.pid('u1', 1), 2, 'Upside down')$q$);
  return pg_temp.ask('u1');
end $$;
create function pg_temp.s_areas() returns text language plpgsql as $$
begin
  perform pg_temp.as_admin($q$select public.script_page_set_hidden_areas(pg_temp.pid('u1', 2), '[{"x":0.02,"y":0.4,"w":0.05,"h":0.3}]', 'Name in the margin')$q$);
  return pg_temp.ask('u1');
end $$;
create function pg_temp.s_resolved() returns text language plpgsql as $$
begin
  perform pg_temp.as_admin($q$select public.script_exception_blank(pg_temp.exc('u1', 9, 'no_code'), 'Nothing on it')$q$);
  return pg_temp.ask('u1');
end $$;
create function pg_temp.s_check() returns text language plpgsql as $$
begin
  insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id)
  values (pg_temp.k('e'), 'name_visible', pg_temp.k('b1'), pg_temp.sid('b1'), pg_temp.pid('u1', 1), pg_temp.k('u1'));
  return pg_temp.ask('u1');
end $$;
create function pg_temp.s_version() returns text language plpgsql as $$
begin
  perform pg_temp.as_admin($q$select public.script_page_remove(pg_temp.sid('b2'), 2, 'Page of the old version')$q$);
  return pg_temp.ask('u1') || ' ' || pg_temp.vers('b2');
end $$;
create function pg_temp.s_extra() returns text language plpgsql as $$
declare
  v_page uuid;
begin
  -- b4 hands in again with a page with no code and places it after page 2; staff have not looked at it.
  perform pg_temp.hand_in('s4', 'b4', 'd4b', 'u4b', '2031-08-04 13:10Z', '2031-08-04 13:15Z');
  perform pg_temp.run('u4b', jsonb_build_array(pg_temp.pp('u4b', 0, 'q4', 1), pg_temp.pp('u4b', 1, 'q4', 2),
    pg_temp.pp('u4b', 2, 'q4', 3), pg_temp.pp('u4b', 3, 'q4', 4), pg_temp.pp('u4b', 4, null, null)));
  v_page := pg_temp.pid('u4b', 4);
  perform tests.as_user(pg_temp.uid('s4'));
  perform public.home_page_place(v_page, 2);
  perform tests.as_postgres();
  return concat_ws(' ', 'placed after ' || (pg_temp.pg('u4b', 4)).placed_after, pg_temp.ask('u4b'));
end $$;

-- xU1, xU1b: b1's matched page 3 (u1 position 2) has a staff area over a name in its margin.
create function pg_temp.s_xu1() returns text language plpgsql as $$
declare
  v_page uuid := pg_temp.pid('u1', 2);
  v text;
begin
  perform pg_temp.as_admin($q$select public.script_page_set_hidden_areas(pg_temp.pid('u1', 2), '[{"x":0.02,"y":0.4,"w":0.05,"h":0.3}]', 'Name in the margin')$q$);
  v := concat_ws(' ', pg_temp.ask('u1'), pg_temp.forced('u1', pg_temp.u1pages()), pg_temp.sim('u1'), pg_temp.ask('u1'),
    pg_temp.forced('u1', pg_temp.u1pages()));
  perform public.scan_booking_complete(pg_temp.k('b1'));
  return concat_ws(' ', v, 'same=' || (pg_temp.pid('u1', 2) = v_page), pg_temp.links('b1'), pg_temp.seen(v_page), pg_temp.state('b1'), pg_temp.safe());
end $$;
-- xU2, xU3: an untouched file is processed again (page 3 now blurred); staff hide a name on it and accept the blur;
-- then the file is not processed again, however often it is tried.
create function pg_temp.s_xu2() returns text language plpgsql as $$
declare
  v_page uuid;
  v text;
begin
  v := concat_ws(' ', pg_temp.ask('u1'), pg_temp.forced('u1', pg_temp.u1pages(3, '{blurred}')));
  v_page := pg_temp.pid('u1', 2);
  perform pg_temp.as_admin($q$select public.script_page_set_hidden_areas(pg_temp.pid('u1', 2), '[{"x":0.02,"y":0.4,"w":0.05,"h":0.3}]', 'Name in the margin')$q$);
  perform pg_temp.as_admin($q$select public.script_exception_confirm(pg_temp.exc('u1', 2, 'poor_quality'), 'Readable')$q$);
  v := concat_ws(' ', v, pg_temp.ask('u1'), pg_temp.forced('u1', pg_temp.u1pages()), pg_temp.sim('u1'), pg_temp.ask('u1'),
    pg_temp.forced('u1', pg_temp.u1pages()));
  perform pg_temp.check_pictures('b1');
  perform public.scan_booking_complete(pg_temp.k('b1'));
  return concat_ws(' ', v, 'same=' || (pg_temp.pid('u1', 2) = v_page), pg_temp.seen(v_page), pg_temp.state('b1'), pg_temp.safe());
end $$;
-- xE2r: b5 is refunded; its page 3 (file u11, not expected) is placed in b1's spare slot 6 with a staff area over a
-- name in its margin; later the paper's hidden areas change and the file's marking pictures are made again.
create function pg_temp.s_xe2r() returns text language plpgsql as $$
declare
  v_page uuid;
  v text;
begin
  update public.bookings set status = 'refunded' where id = pg_temp.k('b5');
  perform pg_temp.scan_file('u11', 'e', 'bt');
  perform pg_temp.run('u11', jsonb_build_array(pg_temp.pp('u11', 0, 'q5', 3)));
  v_page := pg_temp.pid('u11', 0);
  perform pg_temp.as_admin($q$select public.script_exception_assign(pg_temp.exc('u11', 0, 'not_expected'), pg_temp.k('b1'), 6, 'Belongs to b1')$q$);
  perform pg_temp.as_admin($q$select public.script_page_set_hidden_areas(pg_temp.pid('u11', 0), '[{"x":0.02,"y":0.4,"w":0.05,"h":0.3}]', 'Name along the side')$q$);
  v := concat_ws(' ', pg_temp.sim('u11'), pg_temp.ask('u11'), pg_temp.forced('u11', jsonb_build_array(pg_temp.pp('u11', 0, 'q5', 3))));
  perform public.scan_booking_complete(pg_temp.k('b1'));
  perform pg_temp.as_admin($q$select public.set_paper_hidden_areas(pg_temp.k('pv2'), '[{"page":3,"x":0.6,"y":0.9,"w":0.1,"h":0.05}]')$q$);
  v := concat_ws(' ', v, pg_temp.sim('u11'));
  return concat_ws(' ', v, 'same=' || (pg_temp.pid('u11', 0) = v_page), pg_temp.links('b1'), pg_temp.seen(v_page),
    'staff areas sent=' || jsonb_array_length(public.script_page_remask_context(v_page) -> 'staff_areas'), pg_temp.state('b1'), pg_temp.safe());
end $$;
-- xH: the home file u3 holds the family's confirmed extra page and b3's page 3, which gets a staff area.
create function pg_temp.s_xh() returns text language plpgsql as $$
declare
  v_page uuid := pg_temp.pid('u3', 2);
  v text;
begin
  perform pg_temp.as_admin($q$select public.script_page_set_hidden_areas(pg_temp.pid('u3', 2), '[{"x":0.02,"y":0.4,"w":0.05,"h":0.3}]', 'Name in the margin')$q$);
  v := concat_ws(' ', pg_temp.sim('u3'), pg_temp.ask('u3'), pg_temp.forced('u3', pg_temp.u3pages()), pg_temp.ask('u3'),
    pg_temp.forced('u3', pg_temp.u3pages()));
  perform pg_temp.check_pictures('b3');
  return concat_ws(' ', v, 'same=' || (pg_temp.pid('u3', 2) = v_page), pg_temp.seen(v_page),
    'extra=' || (pg_temp.pid('u3', 4) = pg_temp.k('p3_4')) || ':' || (public.script_page_remask_context(pg_temp.k('p3_4')) ->> 'confirmed'),
    pg_temp.state('b3'), pg_temp.safe());
end $$;
-- xH2: a check staff were asked to make again (reprocessed) is never closed by a new marking picture, and stops a
-- reprocess; no open exception is ever left on a replaced page.
create function pg_temp.s_xh2() returns text language plpgsql as $$
declare
  v text;
begin
  insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details)
  values (pg_temp.k('e'), 'poor_quality', pg_temp.k('b1'), pg_temp.sid('b1'), pg_temp.pid('u1', 1), pg_temp.k('u1'),
    '{"flags": [], "copy_page": 2, "from": "remask", "marking_picture": false, "reprocessed": true}');
  perform public.script_remask_queue(pg_temp.k('u1'));
  v := pg_temp.sim('u1');
  return concat_ws(' ', v, 'mk=' || ((pg_temp.pg('u1', 1)).marking_path is not null),
    'check=' || (select state from public.script_exceptions where page_id = pg_temp.pid('u1', 1) and kind = 'poor_quality'),
    pg_temp.ask('u1'), pg_temp.state('b1'));
end $$;
-- xM: nothing is carried by position. A second file (u2: b1's page 5) made b1's latest version; u1 is processed again
-- and its third page now reads as page 4 (less sharp than the other page 4).
create function pg_temp.s_xm() returns text language plpgsql as $$
declare
  v text;
begin
  -- With a staff-placed page (the reviewer's case) the file is not processed again at all.
  perform pg_temp.as_admin($q$select public.script_exception_assign(pg_temp.exc('u1', 9, 'no_code'), pg_temp.k('b1'), 6, 'Her spare page', false, true)$q$);
  v := concat_ws(' ', pg_temp.ask('u1'), pg_temp.forced('u1', pg_temp.u1pages(4)));
  return concat_ws(' ', v, pg_temp.links('b1'), pg_temp.vers('b1'), pg_temp.safe());
end $$;
create function pg_temp.s_xm2() returns text language plpgsql as $$
declare
  v text;
begin
  perform pg_temp.scan_file('u2', 'e', 'bt');
  perform pg_temp.run('u2', jsonb_build_array(pg_temp.pp('u2', 0, 'q1', 5)));
  v := pg_temp.links('b1');
  v := concat_ws(' ', v, pg_temp.ask('u1'), pg_temp.forced('u1', pg_temp.u1pages(4)));
  return concat_ws(' ', v, pg_temp.links('b1'), pg_temp.vers('b1'), 'page 3=' || (pg_temp.pg('u1', 2)).state || ':' || (pg_temp.pg('u1', 2)).copy_page,
    'open=' || coalesce((select string_agg(e.kind::text, ',' order by e.kind::text) from public.script_exceptions e where e.page_id = pg_temp.pid('u1', 2) and e.state = 'open'), ''),
    'resolved=' || (select count(*) from public.script_exceptions e where e.page_id = pg_temp.pid('u1', 2) and e.state = 'resolved'),
    pg_temp.safe());
end $$;
-- A rerun's undo brings back an older version that shows pages replaced two runs ago: the stale slot is emptied.
create function pg_temp.s_undo() returns text language plpgsql as $$
declare
  v text;
begin
  perform pg_temp.scan_file('u2', 'e', 'bt');
  perform pg_temp.run('u2', jsonb_build_array(pg_temp.pp('u2', 0, 'q1', 5)));
  v := concat_ws(' ', pg_temp.ask('u1'), pg_temp.forced('u1', pg_temp.u1pages(6)));
  v := concat_ws(' ', v, pg_temp.links('b1'), pg_temp.vers('b1'), 'stale=' || public.script_stale_links(pg_temp.sid('b1')));
  v := concat_ws(' ', v, '|', pg_temp.ask('u1'), pg_temp.forced('u1', pg_temp.u1pages(6)));
  return concat_ws(' ', v, pg_temp.links('b1'), pg_temp.vers('b1'), pg_temp.safe());
end $$;
-- xL, xL4: a script being marked is never changed.
create function pg_temp.s_xl() returns text language plpgsql as $$
declare
  v text;
  v_before text;
begin
  -- u9: a page with no code, shown by no script; b1 is being marked.
  perform pg_temp.scan_file('u9', 'e', 'bt');
  perform pg_temp.run('u9', jsonb_build_array(pg_temp.pp('u9', 0, null, null)));
  update public.scripts set state = 'marking' where booking_id = pg_temp.k('b1');
  v_before := pg_temp.links('b1') || '|' || pg_temp.vers('b1');
  -- Processed again, the page reads as b1's page 3, sharper than the one b1 shows.
  v := concat_ws(' ', pg_temp.ask('u9'),
    pg_temp.forced('u9', jsonb_build_array(jsonb_set(pg_temp.pp('u9', 0, 'q1', 3), '{quality,sharpness}', '400'))));
  v := concat_ws(' ', v, 'page=' || (pg_temp.pg('u9', 0)).state || ':' || coalesce((pg_temp.pg('u9', 0)).booking_id::text, 'no booking'),
    'raised=' || (select concat_ws(':', e.kind, e.details ->> 'reason', pg_temp.kname(e.booking_id), e.script_id = pg_temp.sid('b1'))
                  from public.script_exceptions e where e.page_id = pg_temp.pid('u9', 0) and e.state = 'open'));
  -- A new scanner file with b1's page 6 (first run): the same.
  perform pg_temp.scan_file('u9b', 'e', 'bt');
  perform pg_temp.run('u9b', jsonb_build_array(pg_temp.pp('u9b', 0, 'q1', 6)));
  v := concat_ws(' ', v, 'new file=' || (pg_temp.pg('u9b', 0)).state || ':' || (select e.details ->> 'reason' from public.script_exceptions e
                                          where e.page_id = pg_temp.pid('u9b', 0) and e.state = 'open'));
  -- b1's own file: staff cannot ask; a job that runs anyway keeps its pages.
  v := concat_ws(' ', v, pg_temp.ask('u1'), pg_temp.forced('u1', pg_temp.u1pages(4)));
  -- Staff cannot place the page in the script either.
  v := concat_ws(' ', v, pg_temp.code(pg_temp.as_admin($q$select public.script_exception_assign(pg_temp.exc('u9b', 0, 'not_expected'), pg_temp.k('b1'), 6, 'Her spare page')$q$)));
  return concat_ws(' ', v, 'unchanged=' || (pg_temp.links('b1') || '|' || pg_temp.vers('b1') = v_before), pg_temp.state('b1'), pg_temp.safe());
end $$;
-- xR: b4 hands in again (u4b); staff process the first hand-in's file u4 again; then staff reject the second hand-in:
-- the script goes back to the first hand-in's version, which showed u4's pages as they were before the rerun.
create function pg_temp.s_xr() returns text language plpgsql as $$
declare
  v text;
begin
  perform pg_temp.hand_in('s4', 'b4', 'd4b', 'u4b', '2031-08-04 13:10Z', '2031-08-04 13:15Z');
  perform pg_temp.run('u4b', jsonb_build_array(pg_temp.pp('u4b', 0, 'q4', 1), pg_temp.pp('u4b', 1, 'q4', 2),
    pg_temp.pp('u4b', 2, 'q4', 3), pg_temp.pp('u4b', 3, 'q4', 4),
    jsonb_set(pg_temp.pp('u4b', 4, 'q4', 4), '{code}', '"ZZZZ-NOT-A-CODE"')));
  v := pg_temp.links('b4');
  v := concat_ws(' ', v, pg_temp.ask('u4'), pg_temp.forced('u4', pg_temp.u4pages()));
  v := concat_ws(' ', v, pg_temp.links('b4'), 'stale=' || public.script_upload_stale_links(pg_temp.k('u4')), '|');
  v := concat_ws(' ', v, pg_temp.as_admin($q$select public.script_exception_reject(pg_temp.exc('u4b', 4, 'unknown_code'), 'Not her paper; the first hand-in stands')$q$) ->> 'resolution');
  return concat_ws(' ', v, pg_temp.links('b4'), pg_temp.vers('b4'),
    'stale=' || public.script_upload_stale_links(pg_temp.k('u4')) || '/' || public.script_stale_links(pg_temp.sid('b4')),
    'current=' || (select bool_and(p.replaced_at is null) from public.script_page_links l join public.scripts s on s.id = l.script_id and l.version = s.version
                   join public.script_pages p on p.id = l.page_id where s.booking_id = pg_temp.k('b4')),
    pg_temp.safe());
end $$;

-- xH2: no open exception is left on a page a rerun replaced. b4 hands in again with a page with no code (not placed
-- yet); a remask had raised a check about it; the file is processed again.
create function pg_temp.s_orphan() returns text language plpgsql as $$
declare
  v_old uuid;
  v text;
begin
  perform pg_temp.hand_in('s4', 'b4', 'd4b', 'u4b', '2031-08-04 13:10Z', '2031-08-04 13:15Z');
  perform pg_temp.run('u4b', jsonb_build_array(pg_temp.pp('u4b', 0, 'q4', 1), pg_temp.pp('u4b', 1, 'q4', 2),
    pg_temp.pp('u4b', 2, 'q4', 3), pg_temp.pp('u4b', 3, 'q4', 4), pg_temp.pp('u4b', 4, null, null)));
  v_old := pg_temp.pid('u4b', 4);
  insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details)
  values (pg_temp.k('e'), 'poor_quality', pg_temp.k('b4'), pg_temp.sid('b4'), v_old, pg_temp.k('u4b'),
    '{"flags": [], "from": "remask", "marking_picture": false}');
  v := concat_ws(' ', pg_temp.ask('u4b'), pg_temp.forced('u4b', jsonb_build_array(pg_temp.pp('u4b', 0, 'q4', 1), pg_temp.pp('u4b', 1, 'q4', 2),
    pg_temp.pp('u4b', 2, 'q4', 3), pg_temp.pp('u4b', 3, 'q4', 4), pg_temp.pp('u4b', 4, null, null))));
  return concat_ws(' ', v, 'old page rows=' || (select count(*) from public.script_pages where id = v_old),
    'checks about it=' || (select count(*) from public.script_exceptions where page_id = v_old), pg_temp.links('b4'), pg_temp.safe());
end $$;

-- R36 (1): a slot staff filled keeps its page against a page scanned later for it. Staff place u1's page with no code
-- in b1's spare slot 6; a new scanner file then holds b1's own page 6, sharper.
create function pg_temp.s_slot() returns text language plpgsql as $$
declare
  v_staff uuid := pg_temp.pid('u1', 9);
  v text;
  r jsonb;
begin
  perform pg_temp.as_admin($q$select public.script_exception_assign(pg_temp.exc('u1', 9, 'no_code'), pg_temp.k('b1'), 6, 'Her spare page', false, true)$q$);
  perform pg_temp.scan_file('u2', 'e', 'bt');
  perform pg_temp.run('u2', jsonb_build_array(jsonb_set(pg_temp.pp('u2', 0, 'q1', 6), '{quality,sharpness}', '400')));
  v := concat_ws(' ', pg_temp.links('b1'), 'scanned=' || (pg_temp.pg('u2', 0)).state,
    'raised=' || (select concat_ws(':', e.kind, pg_temp.kname(e.booking_id), (e.details ->> 'kept_page_id')::uuid = v_staff, e.details ->> 'copy_page')
                  from public.script_exceptions e where e.page_id = pg_temp.pid('u2', 0) and e.state = 'open'),
    pg_temp.vers('b1'), pg_temp.safe());
  -- Staff decide: use the scanned page instead.
  r := pg_temp.as_admin($q$select public.script_exception_assign(pg_temp.exc('u2', 0, 'duplicate'), pg_temp.k('b1'), 6, 'The scanned page is hers', true)$q$);
  return concat_ws(' ', v, '|', pg_temp.code(r), pg_temp.links('b1'), pg_temp.safe());
end $$;
-- R36 (2): script_detail says for each file whether it may be processed again, and why not.
create function pg_temp.s_detail() returns text language plpgsql as $$
declare
  v text;
begin
  v := 'untouched=' || coalesce((select x ->> 'reprocess_refused' from jsonb_array_elements(pg_temp.as_admin($q$select public.script_detail(pg_temp.sid('b1'))$q$) -> 'uploads') x
                                 where (x ->> 'id')::uuid = pg_temp.k('u1')), 'null');
  perform pg_temp.as_admin($q$select public.script_page_set_hidden_areas(pg_temp.pid('u1', 2), '[{"x":0.02,"y":0.4,"w":0.05,"h":0.3}]', 'Name in the margin')$q$);
  v := v || ' areas=' || coalesce((select x ->> 'reprocess_refused' from jsonb_array_elements(pg_temp.as_admin($q$select public.script_detail(pg_temp.sid('b1'))$q$) -> 'uploads') x
                                   where (x ->> 'id')::uuid = pg_temp.k('u1')), 'null');
  update public.scripts set state = 'marking' where booking_id = pg_temp.k('b2');
  v := v || ' marking=' || coalesce((select x ->> 'reprocess_refused' from jsonb_array_elements(pg_temp.as_admin($q$select public.script_detail(pg_temp.sid('b1'))$q$) -> 'uploads') x
                                     where (x ->> 'id')::uuid = pg_temp.k('u1')), 'null');
  return v || ' asked=' || pg_temp.ask('u1');
end $$;

select is(pg_temp.scenario('s_slot'), '1:0@u1,2:1@u1,3:2@u1,4:3@u1,6:9@u1 scanned=duplicate raised=duplicate:b1:t:6 1:scan_upload:u1:sys,2:staff_assign:-:staff stale=0 twice=0 bare=0 orphans=0 | ok 1:0@u1,2:1@u1,3:2@u1,4:3@u1,6:0@u2 stale=0 twice=0 bare=0 orphans=0',
  'R36: a page staff placed keeps its slot against a sharper page scanned for it, which is raised as a duplicate; staff can use it instead');
select is(pg_temp.scenario('s_detail'), 'untouched=null areas=hidden_areas marking=script_locked asked=script_locked',
  'R36: the detail says per file whether it may be processed again (null), or why not, as the reprocess itself answers');
select is(pg_temp.scenario('s_untouched'), 'ok recorded:4 1:0@u4,2:1@u4,3:2@u4,4:3@u4 needs_attention stale=0 twice=0 bare=0 orphans=0',
  'R35: an untouched file is processed again as before (b4''s home file: its script shows the new pages)');
select is(pg_temp.scenario('s_turned'), 'ok', 'R35: a turn alone does not stop it (the rerun reads the page afresh)');
select is(pg_temp.scenario('s_areas'), 'staff_changes:hidden_areas', 'R35: reprocess is refused once a page of the file has staff hidden areas');
select is(pg_temp.scenario('s_resolved'), 'staff_changes:resolution', 'R35: or an exception staff resolved');
select is(pg_temp.scenario('s_check'), 'staff_changes:open_check', 'R35: or an open check staff raised (a reported name)');
select is(pg_temp.scenario('s_version'), 'staff_changes:staff_version 1:scan_upload:u1:sys,2:staff_set_aside:-:staff',
  'R35: or a place in a version staff made, or was taken out by one');
select is(pg_temp.scenario('s_extra'), 'placed after 2 staff_changes:extra_page', 'R35: or is a family''s placed extra page');
select is(pg_temp.scenario('s_xu1'),
  'staff_changes:hidden_areas kept:hidden_areas 7/8 staff_changes:hidden_areas kept:hidden_areas same=true 1:0@u1,2:1@u1,3:2@u1,4:3@u1 '
  || 'areas=1 mk=true replaced=false shown=1 verified stale=0 twice=0 bare=0 orphans=0',
  'R35 (xU1, xU1b): a matched page with a staff area is never replaced, asked for or not: the verified script shows it with its area');
select is(pg_temp.scenario('s_xu2'),
  'ok recorded:10 staff_changes:hidden_areas kept:hidden_areas 7/8 staff_changes:hidden_areas kept:hidden_areas same=true '
  || 'areas=1 mk=true replaced=false shown=1 verified stale=0 twice=0 bare=0 orphans=0',
  'R35 (xU2, xU3): after staff hid a name and accepted the page, no later rerun (second or third) replaces it');
select is(pg_temp.scenario('s_xe2r'),
  '1/1 staff_changes:hidden_areas kept:hidden_areas 1/1 same=true 1:0@u1,2:1@u1,3:2@u1,4:3@u1,6:0@u11 '
  || 'areas=1 mk=true replaced=false shown=1 staff areas sent=1 verified stale=0 twice=0 bare=0 orphans=0',
  'R35 (xE2r): a staff-placed page keeps its staff area; a later remask of its file is made with it');
select is(pg_temp.scenario('s_xh'),
  '4/4 staff_changes:hidden_areas kept:hidden_areas staff_changes:hidden_areas kept:hidden_areas same=true '
  || 'areas=1 mk=true replaced=false shown=1 extra=true:true verified stale=0 twice=0 bare=0 orphans=0',
  'R35 (xH): at home too; the family''s confirmed extra page stays confirmed');
select is(pg_temp.scenario('s_xh2'), '7/8 mk=true check=open staff_changes:open_check needs_attention',
  'R35 (xH2): a check staff were asked to make again is never closed by a new marking picture, and stops a reprocess');
select is(pg_temp.scenario('s_orphan'),
  'ok recorded:5 old page rows=0 checks about it=0 1:0@u4b,2:1@u4b,3:2@u4b,4:3@u4b stale=0 twice=0 bare=0 orphans=0',
  'R35 (xH2): no open check is left on a page a rerun replaced (there is nothing to offer for it)');
select is(pg_temp.scenario('s_xm'),
  'staff_changes:staff_version kept:staff_version 1:0@u1,2:1@u1,3:2@u1,4:3@u1,6:9@u1 1:scan_upload:u1:sys,2:staff_assign:-:staff stale=0 twice=0 bare=0 orphans=0',
  'R35 (xM): a file with a staff-placed page is not processed again: the script keeps the version staff made');
select is(pg_temp.scenario('s_xm2'),
  '1:0@u1,2:1@u1,3:2@u1,4:3@u1,5:0@u2 ok recorded:10 1:0@u1,2:1@u1,4:3@u1,5:0@u2 1:scan_upload:u1:sys,2:scan_upload:u2:sys,3:scan_upload:u1:sys '
  || 'page 3=duplicate:4 open=duplicate resolved=0 stale=0 twice=0 bare=0 orphans=0',
  'R35 (xM): nothing is carried by position: a page that now reads as page 4 leaves slot 3 empty and is raised as a duplicate, in a version no staff own');
select is(pg_temp.scenario('s_undo'),
  'ok recorded:10 1:0@u1,2:1@u1,4:3@u1,5:0@u2,6:2@u1 1:scan_upload:u1:sys,2:scan_upload:u2:sys,3:scan_upload:u1:sys stale=0 | '
  || 'ok recorded:10 1:0@u1,2:1@u1,4:3@u1,5:0@u2,6:2@u1 1:scan_upload:u1:sys,2:scan_upload:u2:sys,3:scan_upload:u1:sys stale=0 twice=0 bare=0 orphans=0',
  'R35: a rerun whose undo brings back a version showing pages replaced two runs ago leaves no link to them');
select is(pg_temp.scenario('s_xl'),
  'ok recorded:1 page=rejected:no booking raised=not_expected:script_locked:b1:t new file=rejected:script_locked script_locked kept:script_locked '
  || 'script_locked unchanged=true marking stale=0 twice=0 bare=0 orphans=0',
  'R35 (xL, xL4): a page read for a script being marked is recorded but never linked (not_expected, script_locked); the script and its versions do not change');
select is(pg_temp.scenario('s_xr'),
  '1:0@u4b,2:1@u4b,3:2@u4b,4:3@u4b ok recorded:4 1:0@u4b,2:1@u4b,3:2@u4b,4:3@u4b stale=0 | rejected 1:0@u4,2:1@u4,3:2@u4,4:3@u4 '
  || '1:home_submission:d4:sys,2:home_submission:d4b:sys,3:submission_rejected:-:staff stale=0/0 current=true stale=0 twice=0 bare=0 orphans=0',
  'R35 (xR): rejecting the later hand-in restores the earlier version with the file''s current pages, never the replaced ones');
-- ---------------------------------------------------------------------------------------------
-- R37: the record locks the file's pages before it checks for staff work; a page is never in two scripts; a script
-- being marked does not change through a family; a slot a version write leaves out is told to staff.
-- ---------------------------------------------------------------------------------------------
-- A home script's extra pages as <source index>@<upload>><placed after>.
create function pg_temp.extras(p_b text) returns text language sql stable as $$
  select coalesce(string_agg(p.source_index || '@' || pg_temp.kname(p.upload_id) || '>' || x.placed_after, ',' order by x.placed_after, p.source_index), 'none')
  from public.script_extra_pages(pg_temp.sid(p_b)) x join public.script_pages p on p.id = x.page_id $$;
-- A booking's open exceptions as <kind>[:<reason>][:<pages>][@<source index>@<upload>], in order.
create function pg_temp.opens(p_b text) returns text language sql stable as $$
  select coalesce(string_agg(concat_ws(':', e.kind, e.details ->> 'reason', nullif(e.details ->> 'pages', ''))
           || coalesce('@' || p.source_index || '@' || pg_temp.kname(p.upload_id), ''), ',' order by e.kind::text, p.source_index), 'none')
  from public.script_exceptions e left join public.script_pages p on p.id = e.page_id
  where e.booking_id = pg_temp.k(p_b) and e.state = 'open' $$;
grant execute on function pg_temp.extras(text), pg_temp.opens(text) to public;

-- R37 (1): staff may work on a file while its reprocess job waits. An area saved before the record is seen by its
-- check (the record holds the page rows by then): the pages are kept, with the area.
create function pg_temp.s_lock() returns text language plpgsql as $$
declare
  v_page uuid := pg_temp.pid('u1', 2);
  v text;
  r jsonb;
begin
  v := pg_temp.ask('u1');
  r := pg_temp.as_admin($q$select public.script_page_set_hidden_areas(pg_temp.pid('u1', 2), '[{"x":0.02,"y":0.4,"w":0.05,"h":0.3}]', 'Name in the margin')$q$);
  r := pg_temp.run('u1', pg_temp.u1pages());
  return concat_ws(' ', v, 'kept=' || coalesce(r ->> 'kept', 'false') || ':' || coalesce(r ->> 'reason', '-'), 'same=' || (pg_temp.pid('u1', 2) = v_page),
    pg_temp.seen(v_page), pg_temp.safe());
end $$;
-- R37 (1): a save that comes after the record lands on a page already replaced, and is refused.
create function pg_temp.s_lock_after() returns text language plpgsql as $$
declare
  v_page uuid := pg_temp.pid('u1', 2);
  v text;
  r jsonb;
begin
  v := pg_temp.ask('u1');
  r := pg_temp.run('u1', pg_temp.u1pages());
  v := concat_ws(' ', v, 'recorded:' || (r ->> 'pages'), 'same=' || (pg_temp.pid('u1', 2) = v_page));
  perform tests.as_user(pg_temp.uid('admin'));
  r := public.script_page_set_hidden_areas(v_page, '[{"x":0.02,"y":0.4,"w":0.05,"h":0.3}]', 'Name in the margin');
  perform tests.as_postgres();
  return concat_ws(' ', v, 'save=' || (pg_temp.code(r) in ('page_replaced', 'not_found')),
    'areas=' || (select count(*) from public.script_page_hidden_areas a join public.script_pages p on p.id = a.page_id where p.upload_id = pg_temp.k('u1')),
    pg_temp.safe());
end $$;

-- R37 (2), probe xT: u2 holds b1's page 3 again, sharper, and takes slot 3 (u1's page 3 is set aside as a duplicate).
-- Staff put that duplicate in b2's spare slot 6. u2 is then processed again and reads as page 5: its undo brings back
-- b1's first version, which showed the page b2 now has.
create function pg_temp.s_xt() returns text language plpgsql as $$
declare
  v text;
  r jsonb;
begin
  perform pg_temp.scan_file('u2', 'e', 'bt');
  perform pg_temp.run('u2', jsonb_build_array(jsonb_set(pg_temp.pp('u2', 0, 'q1', 3), '{quality,sharpness}', '400')));
  r := pg_temp.as_admin($q$select public.script_exception_assign(pg_temp.exc('u1', 2, 'duplicate'), pg_temp.k('b2'), 6, 'It is the other candidate''s')$q$);
  v := concat_ws(' ', pg_temp.code(r), pg_temp.links('b1'), '/', pg_temp.links('b2'), pg_temp.ask('u2'));
  r := pg_temp.run('u2', jsonb_build_array(jsonb_set(pg_temp.pp('u2', 0, 'q1', 5), '{quality,sharpness}', '400')));
  return concat_ws(' ', v, 'recorded:' || (r ->> 'pages'), pg_temp.links('b1'), '/', pg_temp.links('b2'), 'u1#2=' || (pg_temp.pg('u1', 2)).state,
    'b1 open=' || pg_temp.opens('b1'),
    'other=' || (select pg_temp.kname(s.booking_id) from public.script_exceptions e join public.scripts s on s.id = (e.details ->> 'other_script_id')::uuid
                 where e.page_id = pg_temp.pid('u1', 2) and e.kind = 'duplicate' and e.state = 'open'),
    'shared=' || public.script_shared_links(pg_temp.sid('b1')) + public.script_shared_links(pg_temp.sid('b2')), pg_temp.safe());
end $$;
-- R37 (2): the rule is central: whoever writes a version, a page another script shows is left out and raised.
create function pg_temp.s_central() returns text language plpgsql as $$
declare
  v_other uuid := pg_temp.pid('u1', 5);  -- b2's page 3
  v boolean;
begin
  v := public.script_version_write(pg_temp.sid('b1'), public.script_links(pg_temp.sid('b1')) || jsonb_build_object('6', v_other), null, null, 'test', now());
  return concat_ws(' ', 'written=' || v, pg_temp.links('b1'), 'b1 open=' || pg_temp.opens('b1'), pg_temp.safe());
end $$;

-- R37 (3), probe hL: b3's script starts being marked while the family has a draft open. The family can start and hand
-- in nothing more. Even a hand-in that got through at the same moment (forced here) changes nothing: the file is read,
-- but its pages are not linked, its page with no code is not offered for placing, and the extra page markers had stays.
create function pg_temp.s_hl() returns text language plpgsql as $$
declare
  v text;
  v_before text;
  v_page uuid;
  r jsonb;
begin
  perform tests.as_user(pg_temp.uid('s3'));
  r := public.home_submission_open(pg_temp.k('b3'), true, '2031-08-04 10:50Z');
  insert into kv values ('d3b', (r ->> 'submission_id')::uuid);
  r := public.script_upload_begin(pg_temp.k('d3b'), 'home_pdf', 'application/pdf', 5000, '2031-08-04 10:50Z');
  insert into kv values ('u3b', (r ->> 'upload_id')::uuid);
  perform tests.as_postgres();
  insert into storage.objects (bucket_id, name, metadata)
  values ('script-uploads', r ->> 'storage_path', jsonb_build_object('size', 5000, 'mimetype', 'application/pdf'));
  perform tests.as_user(pg_temp.uid('s3'));
  perform public.script_upload_stored(pg_temp.k('u3b'));
  perform tests.as_postgres();

  update public.scripts set state = 'marking' where booking_id = pg_temp.k('b3');
  v_before := concat_ws('|', pg_temp.links('b3'), pg_temp.vers('b3'), pg_temp.extras('b3'));
  v := 'extras=' || pg_temp.extras('b3');
  perform tests.as_user(pg_temp.uid('s3'));
  v := concat_ws(' ', v, 'open=' || pg_temp.code(public.home_submission_open(pg_temp.k('b3'), true, '2031-08-04 11:00Z')),
    'submit=' || pg_temp.code(public.home_submission_submit(pg_temp.k('d3b'), '2031-08-04 11:00Z')));
  perform tests.as_postgres();
  -- The hand-in that slipped through: handed in and queued, as home_submission_submit would have left it.
  update public.home_submissions set state = 'checking', submitted_by = pg_temp.uid('s3'), submitted_at = '2031-08-04 11:00Z' where id = pg_temp.k('d3b');
  update public.script_uploads set state = 'queued' where id = pg_temp.k('u3b');
  insert into public.processing_jobs (upload_id, kind) values (pg_temp.k('u3b'), 'prepare');
  v := concat_ws(' ', v, 'forced extras=' || pg_temp.extras('b3'));
  r := pg_temp.run('u3b', jsonb_build_array(pg_temp.pp('u3b', 0, 'q3', 1), pg_temp.pp('u3b', 1, 'q3', 2), pg_temp.pp('u3b', 2, 'q3', 3),
    pg_temp.pp('u3b', 3, 'q3', 4), pg_temp.pp('u3b', 4, null, null)));
  v_page := pg_temp.pid('u3b', 4);
  v := concat_ws(' ', v, 'recorded:' || (r ->> 'pages') || '/' || (r ->> 'matched'),
    'no code=' || (pg_temp.pg('u3b', 4)).state || ':' || (select e.kind || ':' || (e.details ->> 'reason') from public.script_exceptions e
                                                         where e.page_id = v_page and e.state = 'open'));
  perform tests.as_user(pg_temp.uid('s3'));
  v := concat_ws(' ', v, 'place=' || pg_temp.code(public.home_page_place(v_page, 2)));
  perform tests.as_postgres();
  return concat_ws(' ', v, 'unchanged=' || (concat_ws('|', pg_temp.links('b3'), pg_temp.vers('b3'), pg_temp.extras('b3')) = v_before),
    'extras=' || pg_temp.extras('b3'), pg_temp.state('b3'),
    'extra mk=' || (select bool_and(p.marking_path is not null) from public.script_extra_pages(pg_temp.sid('b3')) x join public.script_pages p on p.id = x.page_id),
    pg_temp.safe());
end $$;
-- R37 (3): a page the family placed before marking began (not yet confirmed) is not confirmed into the script, and
-- cannot be placed again.
create function pg_temp.s_hl2() returns text language plpgsql as $$
declare
  v text;
  v_before text;
  v_page uuid;
  v_exc uuid;
  r jsonb;
begin
  -- A second hand-in, read: its page with no code is placed by the family and waits for staff.
  perform pg_temp.hand_in('s3', 'b3', 'd3b', 'u3b', '2031-08-04 10:50Z', '2031-08-04 10:55Z');
  perform pg_temp.run('u3b', jsonb_build_array(pg_temp.pp('u3b', 0, 'q3', 1), pg_temp.pp('u3b', 1, 'q3', 2), pg_temp.pp('u3b', 2, 'q3', 3),
    pg_temp.pp('u3b', 3, 'q3', 4), pg_temp.pp('u3b', 4, null, null)));
  v_page := pg_temp.pid('u3b', 4);
  perform tests.as_user(pg_temp.uid('s3'));
  r := public.home_page_place(v_page, 3);
  perform tests.as_postgres();
  v_exc := pg_temp.exc('u3b', 4, 'uncoded_family_page');
  v := 'placed=' || pg_temp.code(r);

  update public.scripts set state = 'ready_to_mark' where booking_id = pg_temp.k('b3');
  v_before := concat_ws('|', pg_temp.links('b3'), pg_temp.vers('b3'), pg_temp.extras('b3'));
  perform tests.as_user(pg_temp.uid('s3'));
  v := concat_ws(' ', v, 'place=' || pg_temp.code(public.home_page_place(v_page, 2)));
  perform tests.as_postgres();
  perform tests.as_user(pg_temp.uid('admin'));
  v := concat_ws(' ', v, 'confirm=' || pg_temp.code(public.script_exception_confirm(v_exc, 'Working', true)));
  perform tests.as_postgres();
  -- Even a confirmation written straight into the table adds nothing to what markers see.
  update public.script_exceptions set state = 'resolved', resolution = 'confirmed', resolved_at = now() where id = v_exc;
  return concat_ws(' ', v, 'after=' || (select placed_after from public.script_pages where id = v_page),
    'unchanged=' || (concat_ws('|', pg_temp.links('b3'), pg_temp.vers('b3'), pg_temp.extras('b3')) = v_before),
    'extras=' || pg_temp.extras('b3'), pg_temp.state('b3'), pg_temp.safe());
end $$;

-- R37 (4), probe xR2: b4 hands in again (with a page of an unknown code); its first file is then processed again and
-- reads only pages 1 to 3; staff reject the second hand-in. The first version comes back without page 4, and staff
-- are told page 4 is missing.
create function pg_temp.s_xr2() returns text language plpgsql as $$
declare
  v text;
  r jsonb;
begin
  perform pg_temp.hand_in('s4', 'b4', 'd4b', 'u4b', '2031-08-04 13:10Z', '2031-08-04 13:15Z');
  perform pg_temp.run('u4b', jsonb_build_array(pg_temp.pp('u4b', 0, 'q4', 1), pg_temp.pp('u4b', 1, 'q4', 2),
    pg_temp.pp('u4b', 2, 'q4', 3), pg_temp.pp('u4b', 3, 'q4', 4),
    jsonb_set(pg_temp.pp('u4b', 4, 'q4', 4), '{code}', '"ZZZZ-NOT-A-CODE"')));
  v := pg_temp.ask('u4');
  r := pg_temp.run('u4', jsonb_build_array(pg_temp.pp('u4', 0, 'q4', 1), pg_temp.pp('u4', 1, 'q4', 2), pg_temp.pp('u4', 2, 'q4', 3)));
  v := concat_ws(' ', v, 'recorded:' || (r ->> 'pages'), pg_temp.links('b4'), '|');
  v := concat_ws(' ', v, pg_temp.as_admin($q$select public.script_exception_reject(pg_temp.exc('u4b', 4, 'unknown_code'), 'Not her paper; the first hand-in stands')$q$) ->> 'resolution');
  return concat_ws(' ', v, pg_temp.links('b4'), pg_temp.state('b4'), 'open=' || pg_temp.opens('b4'), pg_temp.safe());
end $$;

select is(pg_temp.scenario('s_lock'), 'ok kept=true:hidden_areas same=true areas=1 mk=true replaced=false shown=1 stale=0 twice=0 bare=0 orphans=0',
  'R37 (1): an area staff saved while the reprocess job waited is seen by the record''s check: the pages are kept, with the area');
select is(pg_temp.scenario('s_lock_after'), 'ok recorded:10 same=false save=true areas=0 stale=0 twice=0 bare=0 orphans=0',
  'R37 (1): an area saved after the record lands on a replaced page and is refused');
-- The lock order script_pages_record documents: the job's row, the file's row, the bookings' advisory locks, the file's
-- current page rows (id order), and only then the check for staff work. script_page_set_hidden_areas takes the file's
-- row before the page's row, so the two wait for each other in one order.
select ok((select position('from public.script_uploads u where u.id = v_job.upload_id for update' in d) > 0
             and position('from public.script_uploads u where u.id = v_job.upload_id for update' in d) < position('pg_advisory_xact_lock' in d)
             and position('pg_advisory_xact_lock' in d) < position('order by p.id for update' in d)
             and position('order by p.id for update' in d) < position('script_upload_staff_changes(v_up.id, false)' in d)
           from (select pg_get_functiondef('public.script_pages_record(bigint,text,integer,text,jsonb,timestamptz)'::regprocedure) d) t)
      and (select position('for no key update' in d) > 0 and position('for no key update' in d) < position('where p.id = p_page for update' in d)
           from (select pg_get_functiondef('public.script_page_set_hidden_areas(uuid,jsonb,text)'::regprocedure) d) t),
  'R37 (1): the record locks the file''s page rows before it checks for staff work; a staff area save takes the file''s row first');
select is(pg_temp.scenario('s_xt'),
  'ok 1:0@u1,2:1@u1,3:0@u2,4:3@u1 / 2:4@u1,3:5@u1,4:6@u1,6:2@u1 ok recorded:1 1:0@u1,2:1@u1,4:3@u1,5:0@u2 / 2:4@u1,3:5@u1,4:6@u1,6:2@u1 u1#2=duplicate '
  || 'b1 open=duplicate:in_other_script@2@u1,missing_pages:in_other_script:[3] other=b2 shared=0 stale=0 twice=0 bare=0 orphans=0',
  'R37 (2, xT): a rerun''s undo never puts a page back that staff have since placed in another script: it stays there, and staff are told');
select is(pg_temp.scenario('s_central'),
  'written=false 1:0@u1,2:1@u1,3:2@u1,4:3@u1 b1 open=duplicate:in_other_script@5@u1,missing_pages:in_other_script:[6] stale=0 twice=0 bare=0 orphans=0',
  'R37 (2): whoever writes a version, a page another script shows is left out of it and raised as a duplicate');
select is(pg_temp.scenario('s_hl'),
  'extras=4@u3>2 open=script_locked submit=script_locked forced extras=4@u3>2 recorded:5/0 no code=rejected:not_expected:script_locked place=script_locked '
  || 'unchanged=true extras=4@u3>2 marking extra mk=true stale=0 twice=0 bare=0 orphans=0',
  'R37 (3, hL): a script being marked does not change through a family: no new hand-in, no placing, and its extra pages stay');
select is(pg_temp.scenario('s_hl2'),
  'placed=ok place=script_locked confirm=script_locked after=3 unchanged=true extras=none ready_to_mark stale=0 twice=0 bare=0 orphans=0',
  'R37 (3): a page the family placed is not placed again or confirmed into a script being marked');
select is(pg_temp.scenario('s_xr2'),
  'ok recorded:3 1:0@u4b,2:1@u4b,3:2@u4b,4:3@u4b | rejected 1:0@u4,2:1@u4,3:2@u4 needs_attention open=late,missing_pages:reprocessed:[4] stale=0 twice=0 bare=0 orphans=0',
  'R37 (4, xR2): a slot a restored version can no longer show is told to staff (missing_pages), whoever writes the version');

-- ---------------------------------------------------------------------------------------------
-- R38: a rerun's undo never takes back a page staff placed, whichever order the rerun writes the scripts in.
-- ---------------------------------------------------------------------------------------------
-- Probes inc1/inc2: as xT, but the rerun also reads a page of the candidate staff gave the page to (bx), so bx's script
-- is written by the rerun too, while b1's undone version still shows the page. The rerun goes through its bookings in
-- uuid order, so bx's booking is made to sort before b1's (p_before) or after it.
-- The set-up: candidate bx, its pages 1-4 scanned (ux); u2 holds b1's page 3 again, sharper, and takes slot 3; staff put
-- the duplicate (u1#2) in bx's spare slot 6; staff ask for u2 to be processed again. Answers what it saw.
create function pg_temp.inc_setup(p_before boolean) returns text language plpgsql as $$
declare
  v_b uuid := (case when p_before then '00000000-0000-4000-8000-0000000000b7' else 'ffffffff-ffff-4fff-bfff-ffffffffffb7' end)::uuid;
  v_s uuid := tests.create_user('student', 'active');
  r jsonb;
begin
  insert into kv values ('bx', v_b);
  insert into public.bookings (id, exam_id, student_id, booked_by, status, amount_pence, sitting, centre_id)
  values (v_b, pg_temp.k('e'), v_s, v_s, 'paid', 0, 'centre', pg_temp.k('ce'));
  insert into public.paper_copies (code, booking_id, paper_id, page_count) values (public.copy_code_new(), v_b, pg_temp.k('pv2'), 6);
  insert into kv select 'qx', id from public.paper_copies where booking_id = v_b;
  insert into public.attendance (exam_id, student_id, status, marked_by, marked_at)
  values (pg_temp.k('e'), v_s, 'present', pg_temp.uid('admin'), '2031-08-04 09:00Z');
  -- bx's pages 1-4 are scanned (file ux).
  perform pg_temp.scan_file('ux', 'e', 'bt');
  perform pg_temp.run('ux', jsonb_build_array(pg_temp.pp('ux', 0, 'qx', 1), pg_temp.pp('ux', 1, 'qx', 2), pg_temp.pp('ux', 2, 'qx', 3),
    pg_temp.pp('ux', 3, 'qx', 4)));
  -- u2 holds b1's page 3 again, sharper: it takes slot 3, and u1's page 3 is set aside as a duplicate.
  perform pg_temp.scan_file('u2', 'e', 'bt');
  perform pg_temp.run('u2', jsonb_build_array(jsonb_set(pg_temp.pp('u2', 0, 'q1', 3), '{quality,sharpness}', '400')));
  -- Staff put that duplicate in bx's spare slot 6.
  r := pg_temp.as_admin($q$select public.script_exception_assign(pg_temp.exc('u1', 2, 'duplicate'), pg_temp.k('bx'), 6, 'It is the other candidate''s')$q$);
  insert into res values ('b1 before reprocess', to_jsonb(pg_temp.state('b1')));
  return concat_ws(' ', pg_temp.code(r), pg_temp.links('b1'), '/', pg_temp.links('bx'), pg_temp.ask('u2'));
end $$;
create function pg_temp.s_inc(p_before boolean) returns text language plpgsql as $$
declare
  v text := pg_temp.inc_setup(p_before);
  r jsonb;
begin
  -- u2 is processed again and now reads as b1's page 5 and bx's page 5.
  r := pg_temp.run('u2', jsonb_build_array(jsonb_set(pg_temp.pp('u2', 0, 'q1', 5), '{quality,sharpness}', '400'),
    pg_temp.pp('u2', 1, 'qx', 5)));
  v := concat_ws(' ', v, 'recorded:' || (r ->> 'pages'), pg_temp.links('b1'), '/', pg_temp.links('bx'), 'u1#2=' || (pg_temp.pg('u1', 2)).state,
    'placed=' || public.script_slot_staff_placed(pg_temp.sid('bx'), 6, pg_temp.pid('u1', 2)),
    'b1 open=' || pg_temp.opens('b1'), 'bx open=' || pg_temp.opens('bx'),
    'other=' || coalesce((select string_agg(pg_temp.kname(e.booking_id) || '>' || pg_temp.kname(s.booking_id), ',')
                          from public.script_exceptions e join public.scripts s on s.id = (e.details ->> 'other_script_id')::uuid
                          where e.page_id = pg_temp.pid('u1', 2) and e.kind = 'duplicate' and e.state = 'open'), '-'));
  -- The centre's scans are checked for both candidates.
  perform public.scan_booking_complete(pg_temp.k('bx'));
  perform public.scan_booking_complete(pg_temp.k('b1'));
  return concat_ws(' ', v, '|', pg_temp.state('b1'), pg_temp.state('bx'), 'b1 open=' || pg_temp.opens('b1'), 'bx open=' || pg_temp.opens('bx'),
    pg_temp.safe());
end $$;
create function pg_temp.s_inc_before() returns text language sql as $$ select pg_temp.s_inc(true) $$;
create function pg_temp.s_inc_after() returns text language sql as $$ select pg_temp.s_inc(false) $$;
-- R39 (1), the reviewer's probe: the same set-up, but u2 is read again as before (b1's page 3 and bx's page 5; with
-- p_six bx's page 6 too). Slot 3 is filled again by u2's page, so the rerun leaves b1 complete and tells staff nothing.
create function pg_temp.s_same(p_before boolean, p_six boolean) returns text language plpgsql as $$
declare
  v text := pg_temp.inc_setup(p_before);
  v_state text := pg_temp.r('b1 before reprocess') #>> '{}';
  r jsonb;
begin
  r := pg_temp.run('u2', jsonb_build_array(jsonb_set(pg_temp.pp('u2', 0, 'q1', 3), '{quality,sharpness}', '400'), pg_temp.pp('u2', 1, 'qx', 5))
    || case when p_six then jsonb_build_array(pg_temp.pp('u2', 2, 'qx', 6)) else '[]'::jsonb end);
  return concat_ws(' ', v, 'recorded:' || (r ->> 'pages'), pg_temp.links('b1'), '/', pg_temp.links('bx'),
    'b1 open=' || pg_temp.opens('b1'), 'bx open=' || pg_temp.opens('bx'), 'b1 ' || v_state || '>' || pg_temp.state('b1'), pg_temp.safe());
end $$;
create function pg_temp.s_same_before() returns text language sql as $$ select pg_temp.s_same(true, false) $$;
create function pg_temp.s_same_after() returns text language sql as $$ select pg_temp.s_same(false, false) $$;
create function pg_temp.s_same6_before() returns text language sql as $$ select pg_temp.s_same(true, true) $$;
create function pg_temp.s_same6_after() returns text language sql as $$ select pg_temp.s_same(false, true) $$;
-- The slot decision keeps a page and clears the duplicates about it, but not one saying another script's version asked
-- for that page (in_other_script) unless the page is kept in a slot staff placed it in. Here b5's version had asked
-- for b1's page 3 (u1#2), which b1 shows; a blurrier scan of the same page leaves u1#2 where it is.
create function pg_temp.s_dup_kept() returns text language plpgsql as $$
declare
  r jsonb;
begin
  insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details)
  values (pg_temp.k('e'), 'duplicate', pg_temp.k('b5'), pg_temp.sid('b5'), pg_temp.pid('u1', 2), pg_temp.k('u1'),
    jsonb_build_object('copy_page', 6, 'reason', 'in_other_script', 'other_script_id', pg_temp.sid('b1')));
  perform pg_temp.scan_file('u2', 'e', 'bt');
  r := pg_temp.run('u2', jsonb_build_array(jsonb_set(pg_temp.pp('u2', 0, 'q1', 3), '{quality,sharpness}', '100')));
  return concat_ws(' ', 'recorded:' || (r ->> 'pages'), pg_temp.links('b1'), 'u2#0=' || (pg_temp.pg('u2', 0)).state,
    'b5 open=' || pg_temp.opens('b5'), 'b1 open=' || pg_temp.opens('b1'), pg_temp.safe());
end $$;

select is(pg_temp.scenario('s_inc_before'),
  'ok 1:0@u1,2:1@u1,3:0@u2,4:3@u1 / 1:0@ux,2:1@ux,3:2@ux,4:3@ux,6:2@u1 ok recorded:2 1:0@u1,2:1@u1,4:3@u1,5:0@u2 / 1:0@ux,2:1@ux,3:2@ux,4:3@ux,5:1@u2,6:2@u1 '
  || 'u1#2=duplicate placed=true b1 open=duplicate:in_other_script@2@u1,missing_pages:in_other_script:[3] bx open=none other=b1>bx '
  || '| needs_attention verified b1 open=duplicate:in_other_script@2@u1,missing_pages:[3] bx open=none stale=0 twice=0 bare=0 orphans=0',
  'R38 (inc1/inc2, the staff-chosen script sorts first): the undone script gives the page up before the rerun writes the scripts; it stays where staff put it and b1 is told');
select is(pg_temp.scenario('s_inc_after'),
  'ok 1:0@u1,2:1@u1,3:0@u2,4:3@u1 / 1:0@ux,2:1@ux,3:2@ux,4:3@ux,6:2@u1 ok recorded:2 1:0@u1,2:1@u1,4:3@u1,5:0@u2 / 1:0@ux,2:1@ux,3:2@ux,4:3@ux,5:1@u2,6:2@u1 '
  || 'u1#2=duplicate placed=true b1 open=duplicate:in_other_script@2@u1,missing_pages:in_other_script:[3] bx open=none other=b1>bx '
  || '| needs_attention verified b1 open=duplicate:in_other_script@2@u1,missing_pages:[3] bx open=none stale=0 twice=0 bare=0 orphans=0',
  'R38 (inc1/inc2, the staff-chosen script sorts last): the same outcome');
select is(pg_temp.scenario('s_same_before'),
  'ok 1:0@u1,2:1@u1,3:0@u2,4:3@u1 / 1:0@ux,2:1@ux,3:2@ux,4:3@ux,6:2@u1 ok recorded:2 1:0@u1,2:1@u1,3:0@u2,4:3@u1 / 1:0@ux,2:1@ux,3:2@ux,4:3@ux,5:1@u2,6:2@u1 '
  || 'b1 open=none bx open=none b1 receiving>receiving stale=0 twice=0 bare=0 orphans=0',
  'R39 (1): a rerun that reads the file as before fills slot 3 again: b1 is complete and staff are told nothing (staff-chosen script first)');
select is(pg_temp.scenario('s_same_after'),
  'ok 1:0@u1,2:1@u1,3:0@u2,4:3@u1 / 1:0@ux,2:1@ux,3:2@ux,4:3@ux,6:2@u1 ok recorded:2 1:0@u1,2:1@u1,3:0@u2,4:3@u1 / 1:0@ux,2:1@ux,3:2@ux,4:3@ux,5:1@u2,6:2@u1 '
  || 'b1 open=none bx open=none b1 receiving>receiving stale=0 twice=0 bare=0 orphans=0',
  'R39 (1): the same, the staff-chosen script last');
select is(pg_temp.scenario('s_same6_before'),
  'ok 1:0@u1,2:1@u1,3:0@u2,4:3@u1 / 1:0@ux,2:1@ux,3:2@ux,4:3@ux,6:2@u1 ok recorded:3 1:0@u1,2:1@u1,3:0@u2,4:3@u1 / 1:0@ux,2:1@ux,3:2@ux,4:3@ux,5:1@u2,6:2@u1 '
  || 'b1 open=none bx open=duplicate@2@u2 b1 receiving>receiving stale=0 twice=0 bare=0 orphans=0',
  'R39 (1): read as before and with bx''s page 6 too: the page staff placed keeps slot 6, the new one is a duplicate, b1 is told nothing (first)');
select is(pg_temp.scenario('s_same6_after'),
  'ok 1:0@u1,2:1@u1,3:0@u2,4:3@u1 / 1:0@ux,2:1@ux,3:2@ux,4:3@ux,6:2@u1 ok recorded:3 1:0@u1,2:1@u1,3:0@u2,4:3@u1 / 1:0@ux,2:1@ux,3:2@ux,4:3@ux,5:1@u2,6:2@u1 '
  || 'b1 open=none bx open=duplicate@2@u2 b1 receiving>receiving stale=0 twice=0 bare=0 orphans=0',
  'R39 (1): the same with bx''s page 6, the staff-chosen script last');
select is(pg_temp.scenario('s_dup_kept'),
  'recorded:1 1:0@u1,2:1@u1,3:2@u1,4:3@u1 u2#0=duplicate b5 open=duplicate:in_other_script@2@u1,poor_quality@8@u1 b1 open=duplicate@0@u2 stale=0 twice=0 bare=0 orphans=0',
  'R38: the slot decision never deletes an in_other_script duplicate about the page it keeps, unless staff placed the page in that slot');
-- ---------------------------------------------------------------------------------------------
-- Task 12, dashboard_counts: the scripts part of the operations dashboard. Exam e started 2031-08-04 09:00 UTC and
-- f 2031-08-05 09:00 UTC (10:00 UK time, summer time); e expects b1, b2, b5 (present) and b3, b4 (home).
-- ---------------------------------------------------------------------------------------------
create function pg_temp.dash(p_now text) returns jsonb language sql as $$
  select pg_temp.as_admin(format('select public.scripts_dashboard(%L::timestamptz)', p_now)) $$;
-- An exam's row as expected/received/verified/needs attention/late ('-' when the exam is not listed).
create function pg_temp.dash_exam(d jsonb, p_exam text) returns text language sql stable as $$
  select coalesce((select concat_ws('/', x ->> 'expected', x ->> 'received', x ->> 'verified', x ->> 'needs_attention', x ->> 'late')
                   from jsonb_array_elements(d -> 'exams') x where (x -> 'exam' ->> 'id')::uuid = pg_temp.k(p_exam)), '-') $$;
-- The centres of e and f listed as not scanned, as <centre>:<candidates counted>.
create function pg_temp.dash_centres(d jsonb) returns text language sql stable as $$
  select coalesce(string_agg(pg_temp.kname((x ->> 'centre_id')::uuid) || ':' || (x ->> 'counted'), ','), 'none')
  from jsonb_array_elements(d -> 'centres_without_scanned_custody') x where (x ->> 'exam_id')::uuid in (pg_temp.k('e'), pg_temp.k('f')) $$;
-- One attempt of a file's waiting prepare job, failed (the third makes it fail for good: a processing_failed exception).
create function pg_temp.fail_prepare(p_up text) returns jsonb language plpgsql as $$
declare
  v jsonb;
begin
  update public.processing_jobs set run_after = '2000-01-01' where upload_id = pg_temp.k(p_up) and state = 'queued' and kind = 'prepare';
  v := public.processing_job_claim('t-worker');
  if v is null or v -> 'upload' ->> 'id' <> pg_temp.k(p_up)::text or v -> 'job' ->> 'kind' <> 'prepare' then
    raise exception 'claimed another job: %', v -> 'job';
  end if;
  return public.processing_job_finish((v -> 'job' ->> 'id')::bigint, 't-worker', (v -> 'job' ->> 'attempts')::int, false, 'RuntimeError');
end $$;
create function pg_temp.s_dashboard() returns text language plpgsql as $$
declare
  d jsonb;
  v text;
  v_failed int;
begin
  -- Jobs left waiting or running by other work are not part of this.
  update public.processing_jobs set state = 'done' where state in ('queued', 'running');
  d := pg_temp.dash('2031-08-05 12:00Z');
  v_failed := (d ->> 'failed_jobs')::int;
  v := concat_ws(' ', 'e=' || pg_temp.dash_exam(d, 'e'), 'f=' || pg_temp.dash_exam(d, 'f'),
    'open=' || ((d ->> 'open_exceptions')::int = (select count(*) from public.script_exceptions x where x.state = 'open')),
    'queue=' || coalesce(d ->> 'oldest_queued_minutes', 'none'), 'stuck=' || (d ->> 'stuck_jobs'), 'centres=' || pg_temp.dash_centres(d));
  -- A file has waited 30 minutes and another is not due yet.
  perform pg_temp.scan_file('u2', 'e', 'bt', 'queued', false);
  insert into public.processing_jobs (upload_id, kind, run_after) values (pg_temp.k('u2'), 'prepare', '2031-08-05 11:30Z');
  perform pg_temp.scan_file('u9', 'e', 'bt', 'queued', false);
  insert into public.processing_jobs (upload_id, kind, run_after) values (pg_temp.k('u9'), 'prepare', '2031-08-05 12:30Z');
  d := pg_temp.dash('2031-08-05 12:00Z');
  v := concat_ws(' ', v, '| queue=' || coalesce(d ->> 'oldest_queued_minutes', 'none'), 'stuck=' || (d ->> 'stuck_jobs'));
  -- A server died part-way through a file 40 minutes ago (its lock is old); another file is being read now.
  perform pg_temp.scan_file('u10', 'e', 'bt', 'processing', false);
  insert into public.processing_jobs (upload_id, kind, state, attempts, locked_by, locked_at, run_after)
  values (pg_temp.k('u10'), 'prepare', 'running', 1, 'dead-worker', '2031-08-05 11:20Z', '2031-08-05 11:19Z');
  perform pg_temp.scan_file('u13', 'e', 'bt', 'processing', false);
  insert into public.processing_jobs (upload_id, kind, state, attempts, locked_by, locked_at, run_after)
  values (pg_temp.k('u13'), 'prepare', 'running', 1, 'live-worker', '2031-08-05 11:59Z', '2031-08-05 11:58Z');
  d := pg_temp.dash('2031-08-05 12:00Z');
  v := concat_ws(' ', v, 'dead: queue=' || coalesce(d ->> 'oldest_queued_minutes', 'none'), 'stuck=' || (d ->> 'stuck_jobs'));
  -- Two files fail for good; staff note one (confirm) and reject the other: each leaves the count.
  perform pg_temp.scan_file('u11', 'e', 'bt');
  perform pg_temp.scan_file('u12', 'e', 'bt');
  for i in 1 .. 3 loop
    perform pg_temp.fail_prepare('u11');
    perform pg_temp.fail_prepare('u12');
  end loop;
  v := concat_ws(' ', v, '| failed+' || ((pg_temp.dash('2031-08-05 12:00Z') ->> 'failed_jobs')::int - v_failed));
  perform pg_temp.as_admin(format('select public.script_exception_confirm(%L, %L)',
    (select e.id from public.script_exceptions e where e.upload_id = pg_temp.k('u11') and e.kind = 'processing_failed' and e.state = 'open'), 'Noted'));
  v := concat_ws(' ', v, 'confirmed:+' || ((pg_temp.dash('2031-08-05 12:00Z') ->> 'failed_jobs')::int - v_failed));
  perform pg_temp.as_admin(format('select public.script_exception_reject(%L, %L)',
    (select e.id from public.script_exceptions e where e.upload_id = pg_temp.k('u12') and e.kind = 'processing_failed' and e.state = 'open'), 'Broken file'));
  v := concat_ws(' ', v, 'rejected:+' || ((pg_temp.dash('2031-08-05 12:00Z') ->> 'failed_jobs')::int - v_failed));
  -- A late script that staff later withdrew counts nowhere: b5 is handed in late, then withdrawn.
  update public.scripts set late = true where booking_id = pg_temp.k('b5');
  v := concat_ws(' ', v, '| late: e=' || pg_temp.dash_exam(pg_temp.dash('2031-08-05 12:00Z'), 'e'));
  update public.scripts set state = 'withdrawn' where booking_id = pg_temp.k('b5');
  v := concat_ws(' ', v, 'withdrawn: e=' || pg_temp.dash_exam(pg_temp.dash('2031-08-05 12:00Z'), 'e'));
  -- Sheets were counted at centre ce for b1 and b2; its custody has "collected" only. Listed from 09:00 UK time the
  -- next day until a "scanned" record exists.
  insert into public.collection_counts (booking_id, exam_id, extra_sheets, recorded_by)
  values (pg_temp.k('b1'), pg_temp.k('e'), 1, pg_temp.uid('admin')), (pg_temp.k('b2'), pg_temp.k('e'), 0, pg_temp.uid('admin'));
  v := concat_ws(' ', v, '| 08:59=' || pg_temp.dash_centres(pg_temp.dash('2031-08-05 07:59Z')),
    '09:00=' || pg_temp.dash_centres(pg_temp.dash('2031-08-05 08:00Z')));
  insert into public.custody_events (exam_id, centre_id, step, location, recorded_by)
  values (pg_temp.k('e'), pg_temp.k('ce'), 'scanned', 'Office', pg_temp.uid('admin'));
  v := concat_ws(' ', v, 'scanned=' || pg_temp.dash_centres(pg_temp.dash('2031-08-05 08:00Z')));
  -- Only exams that started in the last 14 days: on 18 August at 09:30 UTC, f but not e.
  d := pg_temp.dash('2031-08-18 09:30Z');
  v := concat_ws(' ', v, '| 14 days: e=' || pg_temp.dash_exam(d, 'e'), 'f=' || pg_temp.dash_exam(d, 'f'));
  -- Before f starts, it is not listed; nor is an exam still in draft.
  v := concat_ws(' ', v, 'not started: f=' || pg_temp.dash_exam(pg_temp.dash('2031-08-05 08:59Z'), 'f'));
  update public.exams set status = 'draft' where id = pg_temp.k('f');
  return concat_ws(' ', v, 'draft: f=' || pg_temp.dash_exam(pg_temp.dash('2031-08-05 12:00Z'), 'f'));
end $$;

select is(pg_temp.scenario('s_dashboard'),
  'e=5/5/1/3/1 f=1/1/0/0/0 open=true queue=none stuck=0 centres=none | queue=30 stuck=0 dead: queue=40 stuck=1 '
  || '| failed+2 confirmed:+1 rejected:+0 | late: e=5/5/1/3/2 withdrawn: e=5/4/1/2/1 | 08:59=none 09:00=ce:2 scanned=none '
  || '| 14 days: e=- f=1/1/0/0/0 not started: f=- draft: f=-',
  'dashboard_counts: expected, received, verified, needs attention and late per exam of the last 14 days; open problems, files that failed and are not yet settled, queue age (a dead server included) and centres not scanned by 09:00 the next day');
select tests.as_user(pg_temp.uid('teacher'));
select is(public.scripts_dashboard() ->> 'code', 'forbidden', 'the scripts dashboard is for owners and admins: a teacher is refused');
select tests.as_postgres();
select ok(pg_temp.as_admin('select public.scripts_dashboard()') ->> 'ok' = 'true'
      and not has_function_privilege('anon', 'public.scripts_dashboard(timestamptz)', 'execute')
      and has_function_privilege('authenticated', 'public.scripts_dashboard(timestamptz)', 'execute'),
  'an admin reads the scripts dashboard; anon cannot call it');
select is(concat_ws(' ', pg_temp.links('b1'), pg_temp.state('b1'), (select count(*) from kv where name in ('u2', 'u9', 'u10', 'u11', 'u12', 'u13', 'u4b', 'u3b', 'ux', 'bx')),
    (select count(*) from public.script_page_hidden_areas a join public.script_pages p on p.id = a.page_id where p.exam_id = pg_temp.k('e')),
    (select count(*) from public.bookings b where b.exam_id = pg_temp.k('e'))),
  '1:0@u1,2:1@u1,3:2@u1,4:3@u1 receiving 0 0 5', 'the scenarios left nothing behind');

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
select ok(not exists (select 1 from unnest(array[
    'public.script_page_staff_work(uuid)', 'public.script_upload_staff_changes(uuid,boolean)', 'public.script_links_current(uuid,jsonb)',
    'public.script_stale_links(uuid)', 'public.script_upload_stale_links(uuid)',
    'public.script_slot_staff_placed(uuid,integer,uuid)', 'public.script_upload_reprocess_refused(uuid)',
    'public.script_version_write(uuid,jsonb,uuid,uuid,text,timestamp with time zone)', 'public.script_page_marking_made(uuid)']) f,
  unnest(array['anon', 'authenticated', 'service_role']) r where has_function_privilege(r, f, 'execute')),
  'R35: the reprocess helpers are internal, and the re-created ones keep their access');
select ok(not exists (select 1 from unnest(array[
    'public.script_booking_locked(uuid)', 'public.script_page_elsewhere(uuid,uuid)', 'public.script_shared_links(uuid)',
    'public.script_slots_dropped(uuid,jsonb,jsonb,uuid)', 'public.script_extras_lock()', 'public.script_extra_pages(uuid)',
    'public.script_links_current(uuid,jsonb)', 'public.script_version_write(uuid,jsonb,uuid,uuid,text,timestamp with time zone)']) f,
  unnest(array['anon', 'authenticated', 'service_role']) r where has_function_privilege(r, f, 'execute'))
  and not exists (select 1 from unnest(array[
    'public.home_submission_open(uuid,boolean,timestamp with time zone)', 'public.home_submission_submit(uuid,timestamp with time zone)',
    'public.home_page_place(uuid,integer)', 'public.script_exception_confirm(uuid,text,boolean)',
    'public.script_page_set_hidden_areas(uuid,jsonb,text)']) f
  where has_function_privilege('anon', f, 'execute') or not has_function_privilege('authenticated', f, 'execute'))
  and has_function_privilege('service_role', 'public.script_pages_record(bigint,text,integer,text,jsonb,timestamp with time zone)', 'execute')
  and not has_function_privilege('authenticated', 'public.script_pages_record(bigint,text,integer,text,jsonb,timestamp with time zone)', 'execute'),
  'R37: the new helpers are internal, and the re-created functions keep their access');
select ok(has_function_privilege('service_role', 'public.script_pages_record(bigint,text,integer,text,jsonb,timestamp with time zone)', 'execute')
      and not has_function_privilege('authenticated', 'public.script_pages_record(bigint,text,integer,text,jsonb,timestamp with time zone)', 'execute'),
  'script_pages_record stays the processing server''s');

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
-- R33 (1): only a page's latest name check counts. b3's extra page was confirmed "no name"; a marker reports a name.
-- ---------------------------------------------------------------------------------------------
select tests.as_postgres();
select is(public.script_page_remask_context(pg_temp.k('p3_4')) ->> 'confirmed', 'true', 'the extra page is confirmed (no name)');
insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details)
values (pg_temp.k('e'), 'name_visible', pg_temp.k('b3'), pg_temp.sid('b3'), pg_temp.k('p3_4'), pg_temp.k('u3'), '{}');
insert into kv values ('x_nv', (select id from public.script_exceptions where page_id = pg_temp.k('p3_4') and kind = 'name_visible'));
select is(public.script_page_remask_context(pg_temp.k('p3_4')) ->> 'confirmed', 'false', 'R33: while a reported name is open, nothing confirms the page');
select tests.as_user(pg_temp.uid('admin'));
select public.script_page_set_hidden_areas(pg_temp.k('p3_4'), '[{"x":0.1,"y":0.3,"w":0.4,"h":0.05}]', 'Name in the margin');
select is(public.script_exception_confirm(pg_temp.k('x_nv'), 'Name hidden') ->> 'resolution', 'confirmed', 'staff hide the name and confirm');
select tests.as_postgres();
select is(public.script_page_remask_context(pg_temp.k('p3_4')) ->> 'confirmed', 'true', 'confirmed by the latest name check');
select tests.as_user(pg_temp.uid('admin'));
select public.script_page_set_hidden_areas(pg_temp.k('p3_4'), '[]', 'Redraw it');
select tests.as_postgres();
select is(public.script_page_remask_context(pg_temp.k('p3_4')) ->> 'confirmed', 'false',
  'R33: the areas cleared, the older "no name" does not come back (the latest check no longer holds)');
select tests.as_user(pg_temp.uid('admin'));
select public.script_page_set_hidden_areas(pg_temp.k('p3_4'), '[{"x":0.1,"y":0.3,"w":0.4,"h":0.05}]', 'Name in the margin again');
select tests.as_postgres();
select is(public.script_page_remask_context(pg_temp.k('p3_4')) ->> 'confirmed', 'true', 'the same area again: the latest check holds again');

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
-- reprocess_queues_prepare (before any staff work on u1's pages: Ruling R35 refuses it afterwards)
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
create temp table old1 as select id from public.script_pages where upload_id = pg_temp.k('u1');
select is(pg_temp.run('u1', jsonb_build_array(
  pg_temp.page('u1', 0, 'q1', 1), pg_temp.page('u1', 1, 'q1', 2), pg_temp.page('u1', 2, 'q1', 3), pg_temp.page('u1', 3, 'q1', 4),
  pg_temp.page('u1', 4, 'q2a', 2), pg_temp.page('u1', 5, 'q2', 3), pg_temp.page('u1', 6, 'q2', 4),
  pg_temp.page('u1', 7, 'q5', 2), pg_temp.page('u1', 8, 'q5', 3, '{layout_unexpected}', false), pg_temp.page('u1', 9, null, null))) ->> 'pages',
  '10', 'the prepare job is claimed before the remask job waiting on the same file, and records the file again');
select is(concat_ws('/', (select count(*) from public.script_pages p join old1 o on o.id = p.id),
    (pg_temp.pg('u1', 5)).full_path = pg_temp.legacy('u1') || (pg_temp.r('rp') ->> 'job_id') || '-1/5-full.jpg',
    public.script_upload_stale_links(pg_temp.k('u1')), pg_temp.links('b1')),
  '0/t/0/1:0@u1,2:1@u1,3:2@u1,4:3@u1',
  'the earlier pages, which nothing names any more, are gone; the rerun''s pictures are in the new job''s folder; the scripts show the new pages');
insert into res select 'r4', pg_temp.claim_remask('u1');
select is((select count(*)::int from jsonb_array_elements(pg_temp.r('r4') -> 'pages') x
           join public.script_pages p on p.id = (x ->> 'page_id')::uuid where p.replaced_at is null), 8,
  'then the remask job runs on the file''s new pages');
select is(pg_temp.finish(pg_temp.r('r4'), false) ->> 'state', 'queued', 'a failed remask attempt is retried');

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
-- marking_inputs (migration 20261122000008) is the key of what the marking picture hides, written with each picture.
select is((select count(*)::int from snap s join public.script_pages p on p.id = s.id
           where to_jsonb(p) - 'marking_path' - 'marking_inputs' = s.j - 'marking_inputs'),
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
select is(pg_temp.code(public.script_page_set_hidden_areas(pg_temp.pid('uf', 1), '[]', 'Clear them')), 'script_locked',
  'R33: nor changing its hidden areas');
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
select is(pg_temp.code(public.script_exception_confirm(pg_temp.k('x5_1'), 'Checked: the name band is empty', true)), 'name_area_required',
  'R40: the page has a code, so "no name" is refused');
select is(public.script_page_set_hidden_areas(pg_temp.pid('u3', 1), '[{"x":0.05,"y":0.01,"w":0.9,"h":0.05}]', 'Name box') ->> 'ok', 'true',
  'staff draw an area over the name box');
select is(public.script_exception_confirm(pg_temp.k('x5_1'), 'Name box hidden') ->> 'resolution', 'confirmed',
  'and then accept the page');
select tests.as_postgres();
select is(concat_ws('/', pg_temp.jobs('u3', 'remask', 'queued'), public.script_page_remask_context(pg_temp.pid('u3', 1)) ->> 'confirmed',
    (select details ->> 'no_name' from public.script_exceptions where id = pg_temp.k('x5_1')), pg_temp.state('b3'),
    (select state::text from public.home_submissions where id = pg_temp.k('d3'))),
  '1/true/needs_attention/received',
  'R32: a remask is queued; nothing is open, but while its answer page has no marking picture the script is not verified');
insert into res select 'r5b', pg_temp.claim_remask('u3');
select pg_temp.remasked(pg_temp.r('r5b'), pg_temp.answer(pg_temp.r('r5b')));
select pg_temp.finish(pg_temp.r('r5b'), true);
select pg_temp.check_pictures('b3');
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
select pg_temp.fail_remask('u1');
select is(pg_temp.fail_remask('u1') ->> 'state', 'failed', 'u1''s remask job fails for good');
select is((select string_agg(pg_temp.kname(booking_id), ',' order by pg_temp.kname(booking_id)) from public.script_exceptions
           where upload_id = pg_temp.k('u1') and kind = 'processing_failed' and state = 'open'), 'b1,b2,b5',
  'a scanner file''s failure is raised for each script showing its pages');
select is(pg_temp.state('b1') || ' ' || pg_temp.state('b5'), 'needs_attention withdrawn', 'which are worked out again (a withdrawn one stays)');
-- fb's script is final; its file's remask (queued when its page was turned) fails for good.
select pg_temp.fail_remask('uf');
select pg_temp.fail_remask('uf');
select is(pg_temp.fail_remask('uf') ->> 'state', 'failed', 'fb''s file''s remask job fails for good');
select is(concat_ws('/', (select count(*) from public.script_pages where upload_id = pg_temp.k('uf') and replaced_at is null and marking_path is not null),
    (select string_agg(distinct details ->> 'stale_marking', ',') from public.script_exceptions
     where upload_id = pg_temp.k('uf') and kind = 'poor_quality' and state = 'open' and details ->> 'from' = 'remask')),
  '2/true', 'R33: a script past verification keeps its marking pictures; staff are told they may be out of date');

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
-- R35: a file staff have worked on is not processed again (the scenarios above cover each kind and the reruns).
-- A page with no code that staff placed in b1's spare slot 6:
-- ---------------------------------------------------------------------------------------------
select pg_temp.scan_file('u10', 'e', 'bt');
select pg_temp.run('u10', jsonb_build_array(pg_temp.page('u10', 0, null, null)));
insert into kv values ('p10', pg_temp.pid('u10', 0)), ('x10', pg_temp.exc('u10', 0, 'no_code'));
select tests.as_user(pg_temp.uid('admin'));
select is(public.script_exception_assign(pg_temp.k('x10'), pg_temp.k('b1'), 6, 'Her spare page, code torn off', false, true) ->> 'resolution',
  'assigned', 'staff assign a page with no code to b1''s spare page 6');
select tests.as_postgres();
insert into res select 'r10', pg_temp.claim_remask('u10');
select pg_temp.remasked(pg_temp.r('r10'), pg_temp.answer(pg_temp.r('r10')));
select pg_temp.finish(pg_temp.r('r10'), true);
select tests.as_user(pg_temp.uid('admin'));
insert into res select 'rp10', public.script_upload_reprocess(pg_temp.k('u10'), 'Read it again');
select tests.as_postgres();
select is(concat_ws('/', pg_temp.r('rp10') ->> 'ok', pg_temp.r('rp10') ->> 'code', pg_temp.r('rp10') ->> 'reason',
    (select state::text from public.script_uploads where id = pg_temp.k('u10')), pg_temp.jobs('u10', 'prepare', 'queued'),
    (select count(*) from public.audit_log where action = 'script_upload_reprocess' and target_id = pg_temp.k('u10')),
    pg_temp.pid('u10', 0) = pg_temp.k('p10')),
  'false/staff_changes/resolution/processed/0/0/t',
  'R35: its file is not processed again (staff_changes): nothing is queued or audited, and the page stays');

-- R33 (4): a page is an answer page by the slot a script shows it at. b5's cover (b5's booking was refunded: an
-- unexpected page) assigned to b2's spare page 5.
select pg_temp.scan_file('u11', 'e', 'bt');
select pg_temp.run('u11', jsonb_build_array(pg_temp.page('u11', 0, 'q5', 1)));
select tests.as_user(pg_temp.uid('admin'));
select is(public.script_exception_assign(pg_temp.exc('u11', 0, 'not_expected'), pg_temp.k('b2'), 5, 'Belongs to b2''s spare page') ->> 'resolution',
  'assigned', 'staff assign a cover page to an answer slot');
select tests.as_postgres();
select is(concat_ws('/', public.script_page_is_answer(pg_temp.k('q5'), 1), public.script_page_remask_context(pg_temp.pid('u11', 0)) ->> 'answer'),
  'f/true', 'R33: its own copy page is a cover, but it is an answer page where the script shows it');

-- R35: nor b3's home file (its pages hold staff confirmations), nor u1 after the staff work above.
select tests.as_user(pg_temp.uid('admin'));
select is(concat_ws(' ', public.script_upload_reprocess(pg_temp.k('u3'), 'Read the photos again') ->> 'code',
    public.script_upload_reprocess(pg_temp.k('u1'), 'Read it again') ->> 'code'),
  'staff_changes staff_changes', 'R35: files whose pages staff confirmed, hid names on or placed are not processed again');
select tests.as_postgres();
select is((select count(*)::int from public.script_page_links l join public.scripts s on s.id = l.script_id and l.version = s.version
           join public.script_pages p on p.id = l.page_id where p.replaced_at is not null), 0,
  'R35: after all of the above no script shows a replaced page');

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

-- ---------------------------------------------------------------------------------------------
-- Ruling R40 (I1): a file of too many pages fails at once, and staff are told why.
-- ---------------------------------------------------------------------------------------------
select pg_temp.scan_file('u20', 'e', 'bt');
update public.processing_jobs set run_after = '2000-01-01' where upload_id = pg_temp.k('u20');
insert into res select 'p20', public.processing_job_claim('t-worker');
select is(public.processing_job_finish((pg_temp.r('p20') -> 'job' ->> 'id')::bigint, 't-worker', 1, false, 'too_many_pages') ->> 'state', 'failed',
  'R40: a file of more than 5000 pages is not tried again: its first attempt fails it');
select is((select concat_ws('/', u.state, e.state, e.details ->> 'reason', e.details ->> 'attempts', j.state, j.last_error)
           from public.script_uploads u
           join public.script_exceptions e on e.upload_id = u.id and e.kind = 'processing_failed'
           join public.processing_jobs j on j.upload_id = u.id
           where u.id = pg_temp.k('u20')), 'failed/open/too_many_pages/1/failed/too_many_pages',
  'R40: the file is failed and its open exception says why (too_many_pages)');

-- ---------------------------------------------------------------------------------------------
-- Ruling R40 (m1): a failed file that is later processed settles its own "could not be processed" exception.
-- ---------------------------------------------------------------------------------------------
select pg_temp.scan_file('u21', 'e', 'bt');
select pg_temp.fail_prepare('u21');
select pg_temp.fail_prepare('u21');
select is(pg_temp.fail_prepare('u21') ->> 'state', 'failed', 'a file fails for good after three attempts');
insert into kv values ('x_pf21', (select id from public.script_exceptions where upload_id = pg_temp.k('u21') and kind = 'processing_failed' and state = 'open'));
insert into res select 'd21', pg_temp.dash('2031-08-05 12:00Z');
select tests.as_user(pg_temp.uid('admin'));
select is(public.script_upload_reprocess(pg_temp.k('u21'), 'The scanner file was fine: read it again') ->> 'ok', 'true', 'staff have it processed again');
select tests.as_postgres();
select is(pg_temp.run('u21', jsonb_build_array(pg_temp.page('u21', 0, null, null))) ->> 'ok', 'true', 'and this time it is read');
select is((select concat_ws('/', state, resolution, resolved_by is null, reason) from public.script_exceptions where id = pg_temp.k('x_pf21')),
  'resolved/processed/t/The file was processed again.',
  'R40 m1: its open processing_failed exception is closed, with no actor');
select is((select count(*)::int from public.audit_log where action = 'script_exception_processed' and target_type = 'script_exception'
           and target_id = pg_temp.k('x_pf21') and actor_id is null and reason = 'The file was processed again.'), 1, 'R40 m1: and audited');
select is((pg_temp.dash('2031-08-05 12:00Z') ->> 'failed_jobs')::int - (pg_temp.r('d21') ->> 'failed_jobs')::int, -1,
  'R40 m1: the count of files that could not be processed drops by one on the dashboard');
select is((select state from public.script_exceptions where upload_id = pg_temp.k('u20') and kind = 'processing_failed'), 'open',
  'the exception of another file is left alone');

select * from finish();
rollback;
