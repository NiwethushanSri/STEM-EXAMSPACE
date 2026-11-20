begin;
create extension if not exists pgtap with schema extensions;
select plan(132);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Exam e (centre ce, and home), 2031-07-07 10:00 London (09:00 UTC), 90 minutes: finish 10:30 UTC, on
-- time until 12:30 UTC. Paper of e: version 1 (superseded) and version 2, 4 pages each (1 cover, 2-4 answer); every
-- copy has 6 pages (5-6 spare). Centre: b1 and b2 present, b3 absent, b4 late; b2 has a v1 copy and (latest) a v2
-- copy. Home: b5 (s5, parent p1) is rejected, b6 hands in late (accepted), b7 hands in on time then late (the late
-- one rejected), b8 sends a page as it is and places a page with no code (both confirmed). Exam f (centre cf): fb.
-- Staff: admin (Ada Admin), admin2 (Bea Second), a teacher of the subject.
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('admin', tests.create_user('admin', 'active')), ('admin2', tests.create_user('admin', 'active')),
  ('teacher', tests.create_user('teacher', 'active')), ('p1', tests.create_user('parent', 'active'));
insert into c select 's' || i, tests.create_user('student', 'active') from generate_series(1, 8) i;
update public.profiles set first_name = 'Ada', last_name = 'Admin' where id = (select id from c where name = 'admin');
update public.profiles set first_name = 'Bea', last_name = 'Second' where id = (select id from c where name = 'admin2');
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create temp table res (name text primary key, j jsonb);
grant all on res to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
create function pg_temp.r(p text) returns jsonb language sql stable as $$ select j from res where name = p $$;
create function pg_temp.code(j jsonb) returns text language sql immutable as $$ select coalesce(j ->> 'code', 'ok') $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.r(text), pg_temp.code(jsonb) to public;

insert into public.parent_children values (pg_temp.uid('p1'), pg_temp.uid('s5'));
insert into public.subjects (name, kind) values ('ZZ Script resolution', 'school');
insert into public.venues (name, rooms) values ('ZZ Resolution hall', array['R1']);
insert into public.exams (subject_id, title, paper, format, starts_at, duration_minutes, price_pence, price_confirmed, booking_deadline, status)
select s.id, 'ZZR ' || t.n, 'P1', 'both', t.at::timestamptz, 90, 0, true, t.at::timestamptz - interval '1 day', 'published'
from public.subjects s, (values ('e', '2031-07-07 10:00 Europe/London'), ('f', '2031-07-08 10:00 Europe/London')) t(n, at)
where s.name = 'ZZ Script resolution';
insert into kv select substr(e.title, 5), e.id from public.exams e join public.subjects s on s.id = e.subject_id where s.name = 'ZZ Script resolution';
insert into public.teacher_subjects select pg_temp.uid('teacher'), id from public.subjects where name = 'ZZ Script resolution';
insert into public.exam_centres (exam_id, venue_id, room, seat_limit)
select pg_temp.k(t.x), v.id, 'R1', 50 from public.venues v, (values ('e'), ('f')) t(x) where v.name = 'ZZ Resolution hall';
insert into kv select 'c' || t.x, ec.id from public.exam_centres ec join (values ('e'), ('f')) t(x) on ec.exam_id = pg_temp.k(t.x);

insert into public.exam_papers (exam_id, kind, title, version, storage_path, page_count, byte_size, superseded_at)
values (pg_temp.k('e'), 'paper', 'Question paper', 1, pg_temp.k('e')::text || '/' || gen_random_uuid()::text || '.pdf', 4, 1000, now());
insert into public.exam_papers (exam_id, kind, title, version, storage_path, page_count, byte_size)
values (pg_temp.k('e'), 'paper', 'Question paper', 2, pg_temp.k('e')::text || '/' || gen_random_uuid()::text || '.pdf', 4, 1000);
insert into kv select 'pv' || version, id from public.exam_papers where exam_id = pg_temp.k('e');
update public.paper_page_roles set role = (case page when 1 then 'cover' else 'answer' end)::public.page_role
where paper_id in (pg_temp.k('pv1'), pg_temp.k('pv2'));

insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting, centre_id)
select pg_temp.k('e'), pg_temp.uid(t.s), pg_temp.uid(t.s), 'paid', 0, t.sit::public.sitting_mode, case when t.sit = 'centre' then pg_temp.k('ce') end
from (values ('s1', 'centre'), ('s2', 'centre'), ('s3', 'centre'), ('s4', 'centre'),
             ('s5', 'home'), ('s6', 'home'), ('s7', 'home'), ('s8', 'home')) t(s, sit);
insert into kv select 'b' || substr(s.name, 2), b.id from public.bookings b join c s on s.id = b.student_id where b.exam_id = pg_temp.k('e');
insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting, centre_id)
values (pg_temp.k('f'), pg_temp.uid('s1'), pg_temp.uid('s1'), 'paid', 0, 'centre', pg_temp.k('cf'));
insert into kv select 'fb', id from public.bookings where exam_id = pg_temp.k('f');
insert into public.paper_copies (code, booking_id, paper_id, page_count, created_at)
select public.copy_code_new(), pg_temp.k(t.b), pg_temp.k(t.p), 6, now() - t.age * interval '1 hour'
from (values ('b1', 'pv2', 0), ('b2', 'pv1', 1), ('b2', 'pv2', 0), ('b3', 'pv2', 0), ('b4', 'pv2', 0),
             ('b5', 'pv2', 0), ('b6', 'pv2', 0), ('b7', 'pv2', 0), ('b8', 'pv2', 0)) t(b, p, age);
insert into kv select 'q' || substr(k.name, 2) || case when pc.paper_id = pg_temp.k('pv1') then 'a' else '' end, pc.id
from public.paper_copies pc join kv k on k.id = pc.booking_id where k.name ~ '^b[0-9]$';
insert into public.attendance (exam_id, student_id, status, marked_by, marked_at)
select pg_temp.k('e'), pg_temp.uid(t.s), t.st::public.attendance_status, pg_temp.uid('admin'), '2031-07-07 09:00Z'
from (values ('s1', 'present'), ('s2', 'present'), ('s3', 'absent'), ('s4', 'late')) t(s, st);

-- The processing server (as postgres): one prepared page (p_copy null: a page with no code), and a prepare job run.
create function pg_temp.page(p_up text, p_idx int, p_copy text, p_page int, p_sharp numeric default 200, p_flags text[] default '{}',
  p_marking boolean default true) returns jsonb language sql stable as $$
  select jsonb_build_object('source_index', p_idx,
    'code', (select code from public.paper_copies where id = pg_temp.k(p_copy)), 'copy_page', case when p_copy is not null then p_page end,
    'blank', false,
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
  update public.processing_jobs set run_after = '2000-01-01' where upload_id = pg_temp.k(p_up) and state = 'queued' and kind = 'prepare';
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
-- The current page at a position of an upload, and the latest exception of a kind about it.
create function pg_temp.pid(p_up text, p_idx int) returns uuid language sql stable as $$
  select id from public.script_pages where upload_id = pg_temp.k(p_up) and source_index = p_idx and replaced_at is null $$;
create function pg_temp.exc(p_up text, p_idx int, p_kind text) returns uuid language sql stable as $$
  select e.id from public.script_exceptions e where e.page_id = pg_temp.pid(p_up, p_idx) and e.kind::text = p_kind
  order by e.created_at desc, e.id limit 1 $$;
create function pg_temp.bexc(p_booking text, p_kind text) returns uuid language sql stable as $$
  select e.id from public.script_exceptions e where e.booking_id = pg_temp.k(p_booking) and e.kind::text = p_kind
  order by e.created_at desc, e.id limit 1 $$;
create function pg_temp.sid(p_booking text) returns uuid language sql stable as $$
  select id from public.scripts where booking_id = pg_temp.k(p_booking) $$;
create function pg_temp.script(p_booking text) returns text language sql stable as $$
  select complete || '/' || state::text from public.scripts where booking_id = pg_temp.k(p_booking) $$;
-- The current links as <copy page>:<source index>@<upload>, in page order.
create function pg_temp.links(p_booking text) returns text language sql stable as $$
  select coalesce(string_agg(l.copy_page || ':' || p.source_index || '@' || coalesce((select name from kv where id = p.upload_id), '?'), ','
                             order by l.copy_page), '')
  from public.scripts s join public.script_page_links l on l.script_id = s.id and l.version = s.version
  join public.script_pages p on p.id = l.page_id where s.booking_id = pg_temp.k(p_booking) $$;
create function pg_temp.missing(p_booking text) returns text language sql stable as $$
  select coalesce(string_agg(state || ':' || (details -> 'pages')::text, ',' order by state, created_at), '')
  from public.script_exceptions where booking_id = pg_temp.k(p_booking) and kind = 'missing_pages' $$;
create function pg_temp.remasks(p_up text) returns int language sql stable as $$
  select count(*)::int from public.processing_jobs where upload_id = pg_temp.k(p_up) and kind = 'remask' and state = 'queued' $$;
grant execute on function pg_temp.page(text, int, text, int, numeric, text[], boolean), pg_temp.pid(text, int), pg_temp.exc(text, int, text),
  pg_temp.bexc(text, text), pg_temp.sid(text), pg_temp.script(text), pg_temp.links(text), pg_temp.missing(text), pg_temp.remasks(text) to public;

-- Family calls (as the signed-in user), as in 031.
create function pg_temp.open(p_name text, p_booking text, p_all boolean, p_now text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  r := public.home_submission_open(pg_temp.k(p_booking), p_all, p_now::timestamptz);
  if r ->> 'ok' = 'true' and p_name is not null then
    insert into kv values (p_name, (r ->> 'submission_id')::uuid);
  end if;
  return r;
end $$;
create function pg_temp.bgn(p_name text, p_sub text, p_now text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  r := public.script_upload_begin(pg_temp.k(p_sub), 'home_pdf', 'application/pdf', 5000, p_now::timestamptz);
  if r ->> 'ok' = 'true' and p_name is not null then
    insert into kv values (p_name, (r ->> 'upload_id')::uuid);
    insert into res values (p_name, r);
  end if;
  return r;
end $$;
create function pg_temp.put(p_name text) returns void language sql as $$
  insert into storage.objects (bucket_id, name, metadata)
  values ('script-uploads', pg_temp.r(p_name) ->> 'storage_path', jsonb_build_object('size', 5000, 'mimetype', 'application/pdf')) $$;
create function pg_temp.stored(p_name text) returns jsonb language sql as $$ select public.script_upload_stored(pg_temp.k(p_name)) $$;
create function pg_temp.submit(p_sub text, p_now text) returns jsonb language sql as $$
  select public.home_submission_submit(pg_temp.k(p_sub), p_now::timestamptz) $$;
grant execute on function pg_temp.open(text, text, boolean, text), pg_temp.bgn(text, text, text), pg_temp.put(text), pg_temp.stored(text),
  pg_temp.submit(text, text) to public;
-- A family hands in one PDF (begun and submitted at the given times) and the server prepares it into these pages.
create function pg_temp.hand_in(p_student text, p_booking text, p_sub text, p_up text, p_all boolean, p_begin text, p_submit text)
returns void language plpgsql as $$
begin
  perform tests.as_user(pg_temp.uid(p_student));
  perform pg_temp.open(p_sub, p_booking, p_all, p_begin);
  perform pg_temp.bgn(p_up, p_sub, p_begin);
  perform tests.as_postgres();
  perform pg_temp.put(p_up);
  perform tests.as_user(pg_temp.uid(p_student));
  perform pg_temp.stored(p_up);
  perform pg_temp.submit(p_sub, p_submit);
  perform tests.as_postgres();
end $$;

-- Jobs left in a local database by other work are not part of this test.
update public.processing_jobs set state = 'done' where state in ('queued', 'running');

-- A centre scan batch of e with one scanner file u1:
--   0, 1: b1's pages 2 and 3;            2, 3, 4: pages with no code;
--   5: b2's v1 page 2 (sharp), 6: b2's v2 page 2 (set aside as a duplicate), 7: b2's v2 page 3 (mixed versions);
--   8: b4's page 2, 11: b4's page 2 again (blurrier, a duplicate);
--   9: b1's spare page 5, layout unexpected, no marking picture (poor quality); 10: absent b3's page 2 (not expected).
select tests.as_user(pg_temp.uid('admin'));
insert into res select 'bt', public.scan_batch_create(pg_temp.k('e'), pg_temp.k('ce'));
select tests.as_postgres();
insert into kv values ('bt', (pg_temp.r('bt') ->> 'batch_id')::uuid), ('u1', gen_random_uuid());
insert into public.script_uploads (id, exam_id, batch_id, kind, position, storage_path, mime, byte_size, state, uploaded_by)
values (pg_temp.k('u1'), pg_temp.k('e'), pg_temp.k('bt'), 'scan_file', 1, 'batch/' || pg_temp.k('bt') || '/' || pg_temp.k('u1') || '.pdf',
  'application/pdf', 1000, 'queued', pg_temp.uid('admin'));
insert into public.processing_jobs (upload_id, kind) values (pg_temp.k('u1'), 'prepare');
select pg_temp.run('u1', jsonb_build_array(
  pg_temp.page('u1', 0, 'q1', 2), pg_temp.page('u1', 1, 'q1', 3),
  pg_temp.page('u1', 2, null, null, 80), pg_temp.page('u1', 3, null, null, 80), pg_temp.page('u1', 4, null, null, 80),
  pg_temp.page('u1', 5, 'q2a', 2, 300), pg_temp.page('u1', 6, 'q2', 2, 100), pg_temp.page('u1', 7, 'q2', 3),
  pg_temp.page('u1', 8, 'q4', 2, 250), pg_temp.page('u1', 9, 'q1', 5, 200, '{layout_unexpected}', false),
  pg_temp.page('u1', 10, 'q3', 2), pg_temp.page('u1', 11, 'q4', 2, 50)));
-- Each exception a moment older than the one of the page after it, so "newest first" means something.
update public.script_exceptions e set created_at = e.created_at - interval '1 minute' * (20 - coalesce(p.source_index, 15))
from public.script_pages p where p.id = e.page_id and e.upload_id = pg_temp.k('u1');
-- What the server recorded, to compare at the end.
create temp table snap as select p.id, to_jsonb(p) as j from public.script_pages p where p.upload_id = pg_temp.k('u1');

select is((select string_agg(e.kind::text || ':' || coalesce(p.source_index::text, '-'), ',' order by e.kind::text, p.source_index)
           from public.script_exceptions e left join public.script_pages p on p.id = e.page_id where e.exam_id = pg_temp.k('e')),
  'duplicate:6,duplicate:11,mixed_versions:-,no_code:2,no_code:3,no_code:4,not_expected:10,poor_quality:9',
  'fixture: the scanner file raised the exceptions the queue resolves');

-- ---------------------------------------------------------------------------------------------
-- Access.
-- ---------------------------------------------------------------------------------------------
select ok(not exists (select 1 from unnest(array[
    'public.script_exceptions_list(uuid,public.exception_kind,text)', 'public.script_exception_assign(uuid,uuid,integer,text)',
    'public.script_exception_blank(uuid,text)', 'public.script_exception_keep_existing(uuid,text)', 'public.script_exception_reject(uuid,text)',
    'public.script_exception_confirm(uuid,text)', 'public.script_exception_dismiss_missing(uuid,integer[],text)',
    'public.script_late_decide(uuid,boolean,text)', 'public.script_page_set_hidden_areas(uuid,jsonb,text)']) f
  where has_function_privilege('anon', f, 'execute') or not has_function_privilege('authenticated', f, 'execute')),
  'the resolution functions are for signed-in users (they check the caller), never anon');
select ok(not exists (select 1 from unnest(array[
    'public.script_resolution_reason(text)', 'public.script_exception_conflict(uuid)',
    'public.script_bookings_lock(uuid[])', 'public.script_page_bookings(uuid)', 'public.script_centre_checked(uuid)',
    'public.script_resolution_settle(uuid,uuid)', 'public.script_links_write(uuid,jsonb,text,uuid,timestamptz)',
    'public.script_exception_close(uuid,text,text,uuid,timestamptz,text)', 'public.script_page_set_aside(uuid,uuid,timestamptz)',
    'public.script_home_reject(uuid,uuid[],text,uuid,timestamptz)', 'public.script_page_remask(uuid)', 'public.script_booking_json(uuid)', 'public.script_page_json(uuid)',
    'public.script_exception_json(uuid)']) f,
  unnest(array['anon', 'authenticated', 'service_role']) r where has_function_privilege(r, f, 'execute')), 'the resolution helpers are internal');
select ok((select relrowsecurity from pg_class where oid = 'public.script_page_hidden_areas'::regclass)
      and not has_table_privilege('authenticated', 'public.script_page_hidden_areas', 'insert')
      and not has_table_privilege('authenticated', 'public.script_page_hidden_areas', 'delete')
      and not has_table_privilege('anon', 'public.script_page_hidden_areas', 'select'),
  'staff hidden areas: row security on, written only through the function');

-- ---------------------------------------------------------------------------------------------
-- teacher_forbidden
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
insert into kv values ('x_nc2', pg_temp.exc('u1', 2, 'no_code')), ('x_nc3', pg_temp.exc('u1', 3, 'no_code')), ('x_nc4', pg_temp.exc('u1', 4, 'no_code')),
  ('x_dup6', pg_temp.exc('u1', 6, 'duplicate')), ('x_dup11', pg_temp.exc('u1', 11, 'duplicate')), ('x_pq9', pg_temp.exc('u1', 9, 'poor_quality')),
  ('x_ne10', pg_temp.exc('u1', 10, 'not_expected')), ('x_mix2', pg_temp.bexc('b2', 'mixed_versions')), ('pg9', pg_temp.pid('u1', 9));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('teacher'));
select is(pg_temp.code(public.script_exceptions_list(pg_temp.k('e'))), 'forbidden', 'teacher_forbidden: a teacher of the subject cannot list the queue');
select is(pg_temp.code(public.script_exception_assign(pg_temp.k('x_nc2'), pg_temp.k('b1'), 4, 'Teacher try')), 'forbidden', 'nor assign a page');
select is(pg_temp.code(public.script_exception_blank(pg_temp.k('x_nc2'), 'Teacher try')), 'forbidden', 'nor mark it blank');
select is(pg_temp.code(public.script_exception_keep_existing(pg_temp.k('x_dup6'), 'Teacher try')), 'forbidden', 'nor keep a duplicate''s page');
select is(pg_temp.code(public.script_exception_reject(pg_temp.k('x_nc2'), 'Teacher try')), 'forbidden', 'nor reject');
select is(pg_temp.code(public.script_exception_confirm(pg_temp.k('x_pq9'))), 'forbidden', 'nor confirm');
select is(pg_temp.code(public.script_exception_dismiss_missing(pg_temp.k('x_nc2'), array[3], 'Teacher try')), 'forbidden', 'nor dismiss missing pages');
select is(pg_temp.code(public.script_late_decide(gen_random_uuid(), true, 'Teacher try')), 'forbidden', 'nor decide on a late script');
select is(pg_temp.code(public.script_page_set_hidden_areas(pg_temp.k('pg9'), '[]', 'Teacher try')), 'forbidden', 'nor hide areas of a page');
select is((select count(*)::int from public.script_exceptions) + (select count(*)::int from public.script_page_hidden_areas), 0,
  'nor read the exceptions or the hidden areas');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s1'));
select is(pg_temp.code(public.script_exceptions_list(pg_temp.k('e'))), 'forbidden', 'a student cannot list the queue');
select is(pg_temp.code(public.script_exception_reject(pg_temp.k('x_nc2'), 'Student try')), 'forbidden', 'nor reject a page');
select tests.as_postgres();
select is((select count(*)::int from public.script_exceptions where id in (pg_temp.k('x_nc2'), pg_temp.k('x_pq9')) and state = 'open'), 2,
  'refused callers changed nothing');

-- ---------------------------------------------------------------------------------------------
-- reason_required (3 to 300 characters)
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.script_exception_reject(pg_temp.k('x_nc4'), null)), 'reason_required', 'reason_required: no reason is refused');
select is(pg_temp.code(public.script_exception_reject(pg_temp.k('x_nc4'), '  ab  ')), 'reason_required', 'two characters (once trimmed) are too few');
select is(pg_temp.code(public.script_exception_reject(pg_temp.k('x_nc4'), repeat('x', 301))), 'reason_required', '301 characters are too many');
select is(pg_temp.code(public.script_exception_blank(pg_temp.k('x_nc4'), '')), 'reason_required', 'marking blank needs a reason');
select is(pg_temp.code(public.script_exception_assign(pg_temp.k('x_nc4'), pg_temp.k('b1'), 4, 'ab')), 'reason_required', 'so does assigning');
select is(pg_temp.code(public.script_exception_keep_existing(pg_temp.k('x_dup11'), 'ab')), 'reason_required', 'and keeping the existing page');
select is(pg_temp.code(public.script_exception_dismiss_missing(gen_random_uuid(), array[3], 'ab')), 'reason_required', 'and dismissing missing pages');
select is(pg_temp.code(public.script_late_decide(gen_random_uuid(), true, 'ab')), 'reason_required', 'and a late decision');
select is(pg_temp.code(public.script_page_set_hidden_areas(pg_temp.k('pg9'), '[]', 'ab')), 'reason_required', 'and hiding areas of a page');
select is(pg_temp.code(public.script_exception_confirm(pg_temp.k('x_pq9'), 'ab')), 'reason_required',
  'confirming needs no reason, but one given must be 3 to 300 characters');
select tests.as_postgres();
select is((select count(*)::int from public.script_exceptions where id in (pg_temp.k('x_nc4'), pg_temp.k('x_dup11'), pg_temp.k('x_pq9')) and state = 'open'), 3,
  'calls without a proper reason changed nothing');

-- ---------------------------------------------------------------------------------------------
-- assign_moves_page_into_script_new_version (before the centre's scans are all in)
-- ---------------------------------------------------------------------------------------------
insert into res select 'b1v', to_jsonb((select version from public.scripts where booking_id = pg_temp.k('b1')));
select is(pg_temp.links('b1'), '2:0@u1,3:1@u1,5:9@u1', 'b1''s script shows pages 2, 3 and the spare page 5');
select tests.as_user(pg_temp.uid('admin'));
insert into res select 'as1', public.script_exception_assign(pg_temp.k('x_nc2'), pg_temp.k('b1'), 4, 'Page 4 of this candidate, the code was torn off');
select is(pg_temp.r('as1') ->> 'ok', 'true', 'assign_moves_page_into_script_new_version: the page with no code is assigned to b1 page 4');
select tests.as_postgres();
select is(pg_temp.links('b1'), '2:0@u1,3:1@u1,4:2@u1,5:9@u1', 'b1''s script now shows it at page 4');
select is((select version from public.scripts where booking_id = pg_temp.k('b1')), (pg_temp.r('b1v'))::int + 1, 'as a new version');
select is((pg_temp.r('as1') ->> 'version')::int, (pg_temp.r('b1v'))::int + 1, 'which the answer names');
select is((select v.reason || '/' || (v.created_by = pg_temp.uid('admin')) || '/' || (v.upload_id is null and v.submission_id is null)
           from public.script_versions v join public.scripts s on s.id = v.script_id and v.version = s.version where s.booking_id = pg_temp.k('b1')),
  'staff_assign/true/true', 'the version says a staff member made it, and who');
select is((select count(*)::int from public.script_page_links l join public.scripts s on s.id = l.script_id
           where s.booking_id = pg_temp.k('b1') and l.version = (pg_temp.r('b1v'))::int), 3, 'the earlier version is kept as it was');
select is((select concat_ws('/', state, resolution, resolved_by = pg_temp.uid('admin'), resolved_at is not null, reason, details -> 'assigned' ->> 'copy_page',
                            details -> 'assigned' ->> 'booking_id' = pg_temp.k('b1')::text, booking_id = pg_temp.k('b1'), script_id = pg_temp.sid('b1'))
           from public.script_exceptions where id = pg_temp.k('x_nc2')),
  'resolved/assigned/t/t/Page 4 of this candidate, the code was torn off/4/t/t/t',
  'the exception is resolved with who, when, the reason and where the page went');
select is((select count(*)::int from public.audit_log where action = 'script_exception_assigned' and target_type = 'script_exception'
           and target_id = pg_temp.k('x_nc2') and actor_id = pg_temp.uid('admin') and reason = 'Page 4 of this candidate, the code was torn off'), 1,
  'the assignment is audited with the reason');
select is(pg_temp.remasks('u1'), 1, 'the page has no marking picture yet: one remask job is queued for its file');
select is(pg_temp.missing('b1') || ' ' || pg_temp.script('b1'), ' false/needs_attention',
  'before the centre''s scans are all in, nothing is called missing (b1 still has its poor-quality page open)');

select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.script_exception_assign(pg_temp.k('x_nc3'), pg_temp.k('b3'), 2, 'Absent candidate')), 'not_present',
  'a page cannot go to a centre candidate marked absent');
select is(pg_temp.code(public.script_exception_assign(pg_temp.k('x_nc3'), pg_temp.k('b1'), 7, 'Beyond the copy')), 'invalid_input',
  'nor beyond the pages of the candidate''s copy');
select is(pg_temp.code(public.script_exception_assign(pg_temp.k('x_nc3'), pg_temp.k('b5'), 2, 'Home candidate')), 'wrong_sitting',
  'nor a scanned page to a candidate sitting at home');
select is(pg_temp.code(public.script_exception_assign(pg_temp.k('x_nc3'), gen_random_uuid(), 2, 'Unknown booking')), 'not_found', 'nor to an unknown booking');
select is(pg_temp.code(public.script_exception_assign(gen_random_uuid(), pg_temp.k('b1'), 2, 'Unknown exception')), 'not_found', 'an unknown exception is not found');
select is(pg_temp.code(public.script_exception_keep_existing(pg_temp.k('x_nc3'), 'Not a duplicate')), 'wrong_kind', 'keeping the existing page is for duplicates only');
select is(pg_temp.code(public.script_exception_dismiss_missing(pg_temp.k('x_nc3'), array[2], 'Not missing pages')), 'wrong_kind',
  'and dismissing for missing pages only');

-- ---------------------------------------------------------------------------------------------
-- assign_to_candidate_of_other_exam_refused
-- ---------------------------------------------------------------------------------------------
select is(pg_temp.code(public.script_exception_assign(pg_temp.k('x_nc3'), pg_temp.k('fb'), 2, 'Candidate of exam f')), 'other_exam',
  'assign_to_candidate_of_other_exam_refused: a page of exam e cannot go into a script of exam f');
select tests.as_postgres();
select is((select count(*)::int from public.scripts where booking_id = pg_temp.k('fb'))
          + (select count(*)::int from public.script_exceptions where id = pg_temp.k('x_nc3') and state <> 'open'), 0,
  'no script was made for fb and the exception is still open');

-- ---------------------------------------------------------------------------------------------
-- Blank, reject (a scanned page set aside) and second_resolution_conflict.
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select is(public.script_exception_blank(pg_temp.k('x_nc3'), 'abc') ->> 'resolution', 'blank', 'a page with no code is marked blank (a 3-character reason is enough)');
select is(public.script_exception_reject(pg_temp.k('x_nc4'), repeat('r', 300)) ->> 'resolution', 'rejected', 'another is rejected (300 characters are allowed)');
select tests.as_postgres();
select is((select string_agg(concat_ws('/', resolution, char_length(reason), resolved_by = pg_temp.uid('admin')), ',' order by resolution)
           from public.script_exceptions where id in (pg_temp.k('x_nc3'), pg_temp.k('x_nc4'))), 'blank/3/t,rejected/300/t',
  'both are resolved with their reasons');
select is(pg_temp.links('b1'), '2:0@u1,3:1@u1,4:2@u1,5:9@u1', 'setting pages aside changes no script');
select tests.as_user(pg_temp.uid('admin2'));
insert into res select 'cf1', public.script_exception_blank(pg_temp.k('x_nc4'), 'Second look');
select is(concat_ws('/', pg_temp.r('cf1') ->> 'code', pg_temp.r('cf1') ->> 'resolved_by', pg_temp.r('cf1') ->> 'resolution', pg_temp.r('cf1') ? 'resolved_at'),
  'conflict/Ada Admin/rejected/t', 'second_resolution_conflict: a second resolution says who resolved it, how and when');
select is(pg_temp.code(public.script_exception_assign(pg_temp.k('x_nc2'), pg_temp.k('b1'), 4, 'Again')), 'conflict', 'assigning again is a conflict too');
select is((select concat_ws('/', resolution, resolved_by = pg_temp.uid('admin')) from public.script_exceptions where id = pg_temp.k('x_nc4')), 'rejected/t',
  'and the first resolution stands');
select tests.as_postgres();
select is((select count(*)::int from public.audit_log where target_id in (pg_temp.k('x_nc3'), pg_temp.k('x_nc4')) and actor_id = pg_temp.uid('admin')
           and action in ('script_exception_blank', 'script_exception_rejected') and reason is not null), 2, 'each resolution is audited with its reason');

-- ---------------------------------------------------------------------------------------------
-- Staff hidden areas on a page, then the poor-quality page is confirmed.
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.script_page_set_hidden_areas(pg_temp.k('pg9'), '[{"x":0.6,"y":0.1,"w":0.5,"h":0.1}]', 'Name box')), 'invalid_input',
  'an area must stay inside the page');
select is(pg_temp.code(public.script_page_set_hidden_areas(pg_temp.k('pg9'), '[{"x":0.1,"y":0.1,"w":0,"h":0.1}]', 'Name box')), 'invalid_input',
  'an area must have a size');
select is(pg_temp.code(public.script_page_set_hidden_areas(pg_temp.k('pg9'), '[{"x":"0.1","y":0.1,"w":0.2,"h":0.1}]', 'Name box')), 'invalid_input',
  'sizes are numbers');
select is(pg_temp.code(public.script_page_set_hidden_areas(pg_temp.k('pg9'), '{"x":0.1}', 'Name box')), 'invalid_input', 'the areas are a list');
select is(pg_temp.code(public.script_page_set_hidden_areas(pg_temp.k('pg9'),
            (select jsonb_agg(jsonb_build_object('x', 0.01 * i, 'y', 0.01, 'w', 0.01, 'h', 0.01)) from generate_series(1, 21) i), 'Name box')),
  'invalid_input', 'a page has at most 20 areas');
select is(public.script_page_set_hidden_areas(pg_temp.k('pg9'),
            (select jsonb_agg(jsonb_build_object('x', 0.01 * i, 'y', 0.01, 'w', 0.01, 'h', 0.01)) from generate_series(1, 20) i), 'Name box') ->> 'areas',
  '20', 'twenty are allowed');
select is(pg_temp.code(public.script_page_set_hidden_areas(gen_random_uuid(), '[]', 'Name box')), 'not_found', 'an unknown page is not found');
insert into res select 'ha', public.script_page_set_hidden_areas(pg_temp.k('pg9'),
  '[{"x":0.1,"y":0.05,"w":0.5,"h":0.04},{"x":0.6,"y":0.9,"w":0.3,"h":0.05}]', 'Name written across the top and at the foot');
select is(concat_ws('/', pg_temp.r('ha') ->> 'ok', pg_temp.r('ha') ->> 'areas', pg_temp.r('ha') ->> 'changed'), 'true/2/true',
  'staff draw two areas over the name on the full page picture: they replace the page''s areas');
select tests.as_postgres();
select is((select string_agg(concat_ws(':', x, y, w, h, created_by = pg_temp.uid('admin')), ',' order by x) from public.script_page_hidden_areas
           where page_id = pg_temp.k('pg9')), '0.1:0.05:0.5:0.04:t,0.6:0.9:0.3:0.05:t', 'the page keeps exactly those areas, with who drew them');
select is((select count(*)::int from public.audit_log where action = 'script_page_hidden_areas_set' and target_type = 'script_page'
           and target_id = pg_temp.k('pg9') and reason is not null), 2, 'each change of areas is audited with its reason');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('teacher'));
select is((select count(*)::int from public.script_page_hidden_areas), 0, 'a teacher cannot read the areas');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is((select count(*)::int from public.script_page_hidden_areas where page_id = pg_temp.k('pg9')), 2, 'a staff admin can');

select is(pg_temp.code(public.script_exception_confirm(pg_temp.k('x_mix2'))), 'still_mixed',
  'mixed versions cannot be confirmed while the script still shows pages of two versions');
insert into res select 'cq', public.script_exception_confirm(pg_temp.k('x_pq9'));
select is(pg_temp.r('cq') ->> 'resolution', 'confirmed', 'the poor-quality page is confirmed for marking, with no reason');
select tests.as_postgres();
select is((select concat_ws('/', state, resolution, coalesce(reason, 'none')) from public.script_exceptions where id = pg_temp.k('x_pq9')),
  'resolved/confirmed/none', 'resolved without a reason');
select is((select count(*)::int from public.audit_log where action = 'script_exception_confirmed' and target_id = pg_temp.k('x_pq9') and reason is null), 1,
  'and audited');
select is(pg_temp.remasks('u1'), 1, 'its file already waits for a remask: no second job');

-- ---------------------------------------------------------------------------------------------
-- The centre's scans are all in; then the duplicates and the missing pages.
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
insert into res select 'cc', public.scan_centre_complete(pg_temp.k('e'), pg_temp.k('ce'));
select is(concat_ws('/', pg_temp.r('cc') ->> 'candidates', pg_temp.r('cc') ->> 'complete', pg_temp.r('cc') ->> 'missing'), '3/1/2',
  'all scans in: b1 is complete, b2 and b4 miss pages');
select tests.as_postgres();
select is(pg_temp.script('b1'), 'true/verified', 'b1, with page 4 assigned and its page 5 confirmed, is verified');
select is(pg_temp.missing('b2') || ' ' || pg_temp.missing('b4'), 'open:[2, 4] open:[3, 4]',
  'b2''s v1 page 2 does not count for its v2 paper; b4 misses pages 3 and 4');

select tests.as_user(pg_temp.uid('admin'));
insert into res select 'ld', public.script_exceptions_list(pg_temp.k('e'), 'duplicate', 'open');
select is((select string_agg(concat_ws('/', x -> 'page' ->> 'source_index', x -> 'page' ->> 'paper_version', x -> 'kept_page' ->> 'source_index',
                                       x -> 'kept_page' ->> 'paper_version'), ',' order by x -> 'page' ->> 'source_index')
           from jsonb_array_elements(pg_temp.r('ld') -> 'items') x), '11/2/8/2,6/2/5/1',
  'the queue shows each duplicate and the page kept, with the paper version of each (v1 and v2 of the same page number)');
select is(public.script_exception_keep_existing(pg_temp.k('x_dup11'), 'The sharper scan is the right one') ->> 'resolution', 'kept',
  'b4''s duplicate: the page kept stays');
insert into res select 'as2', public.script_exception_assign(pg_temp.k('x_dup6'), pg_temp.k('b2'), 2, 'Use the version 2 page like the rest');
select is((pg_temp.r('as2') ->> 'replaced_page_id')::uuid, pg_temp.pid('u1', 5), 'b2''s v2 page 2 is used instead: the answer names the page it replaced');
select tests.as_postgres();
select is(pg_temp.links('b4') || ' ' || pg_temp.links('b2'), '2:8@u1 2:6@u1,3:7@u1', 'b4 keeps its page; b2 now shows v2 pages only');
select is((select concat_ws('/', state, resolution) from public.script_exceptions where id = pg_temp.k('x_mix2')), 'resolved/one_version',
  'b2''s mixed_versions exception is resolved now that its pages are one version');
select is(pg_temp.missing('b2'), 'open:[4]', 'and its missing pages are checked again: only page 4 is missing');

select tests.as_user(pg_temp.uid('admin'));
insert into kv values ('x_mp4', pg_temp.bexc('b4', 'missing_pages'));
select is(pg_temp.code(public.script_exception_dismiss_missing(pg_temp.k('x_mp4'), array[5], 'Page 5 blank')), 'invalid_input',
  'only pages that are missing can be dismissed');
select is(pg_temp.code(public.script_exception_dismiss_missing(pg_temp.k('x_mp4'), array[]::int[], 'No pages')), 'invalid_input', 'and at least one');
select is(public.script_exception_dismiss_missing(pg_temp.k('x_mp4'), array[3], 'Page 3 was left blank, checked the booklet') ->> 'state', 'open',
  'staff say page 3 was left blank: page 4 is still missing');
select tests.as_postgres();
select is((select concat_ws(' ', details -> 'dismissed', details -> 'pages') from public.script_exceptions where id = pg_temp.k('x_mp4')), '[3] [4]',
  'the dismissed page is kept under details.dismissed, and the pages still missing are worked out again');
select is(pg_temp.script('b4'), 'false/needs_attention', 'b4 is not complete yet');
select tests.as_user(pg_temp.uid('admin'));
select is(public.script_exception_dismiss_missing(pg_temp.k('x_mp4'), array[4], 'Page 4 was left blank too') ->> 'state', 'resolved',
  'page 4 dismissed as well: the exception is resolved');
select tests.as_postgres();
select is((select concat_ws(' ', details -> 'dismissed', resolution, reason) from public.script_exceptions where id = pg_temp.k('x_mp4')),
  '[3, 4] dismissed Page 4 was left blank too', 'with both pages dismissed, how and why');
select is(pg_temp.script('b4'), 'true/verified', 'b4 is complete and verified');
select is((select count(*)::int from public.audit_log where action = 'script_missing_dismissed' and target_id = pg_temp.k('x_mp4') and reason is not null), 2,
  'each dismissal is audited with its reason');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.script_exception_dismiss_missing(pg_temp.k('x_mp4'), array[4], 'Again')), 'conflict', 'a resolved missing_pages exception is a conflict');
select is(pg_temp.code(public.script_late_decide(pg_temp.sid('b1'), true, 'Not late')), 'not_late', 'a centre script has no late decision');

-- ---------------------------------------------------------------------------------------------
-- The list.
-- ---------------------------------------------------------------------------------------------
insert into res select 'lo', public.script_exceptions_list(pg_temp.k('e'));
select is((select string_agg(x ->> 'kind', ',') from jsonb_array_elements(pg_temp.r('lo') -> 'items') x), 'missing_pages,not_expected',
  'open by default: what is still open for exam e, newest first (b2''s missing page, then b3''s page)');
select is((select x -> 'page' ->> 'full_path' from jsonb_array_elements(pg_temp.r('lo') -> 'items') x where x ->> 'kind' = 'not_expected'),
  pg_temp.k('e')::text || '/' || pg_temp.k('u1')::text || '/10-full.jpg', 'each item carries the full page picture''s path');
select is((select concat_ws('/', x -> 'printed_for' ->> 'id' = pg_temp.k('b3')::text, x -> 'upload' ->> 'source', x -> 'details' ->> 'reason')
           from jsonb_array_elements(pg_temp.r('lo') -> 'items') x where x ->> 'kind' = 'not_expected'), 't/centre/absent',
  'and who the page was printed for, where it came from and what the server found');
insert into res select 'lr', public.script_exceptions_list(pg_temp.k('e'), 'no_code', 'resolved');
select is((select string_agg(concat_ws('/', x ->> 'kind', x -> 'resolved' ->> 'resolution', x -> 'resolved' ->> 'by'), ',' order by x -> 'resolved' ->> 'resolution')
           from jsonb_array_elements(pg_temp.r('lr') -> 'items') x), 'no_code/assigned/Ada Admin,no_code/blank/Ada Admin,no_code/rejected/Ada Admin',
  'resolved items of one kind, with how and by whom');
select is((pg_temp.r('lr') ->> 'more') || '/' || jsonb_array_length(pg_temp.r('lr') -> 'items'), 'false/3', 'with no more beyond them');
select is(pg_temp.code(public.script_exceptions_list(pg_temp.k('e'), null, 'closed')), 'invalid_input', 'the state is open or resolved');
select is(jsonb_array_length(public.script_exceptions_list(pg_temp.k('f')) -> 'items'), 0, 'another exam has its own queue');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- reject_home_submission_queues_email: b5's file holds b6's page 2 as well as its own pages.
-- ---------------------------------------------------------------------------------------------
select pg_temp.hand_in('s5', 'b5', 'd5', 'u5', true, '2031-07-07 10:40Z', '2031-07-07 10:45Z');
select pg_temp.run('u5', jsonb_build_array(pg_temp.page('u5', 0, 'q5', 2), pg_temp.page('u5', 1, 'q5', 3), pg_temp.page('u5', 2, 'q5', 4),
  pg_temp.page('u5', 3, 'q6', 2)));
create temp table snap5 as select p.id, to_jsonb(p) as j from public.script_pages p where p.upload_id = pg_temp.k('u5');
insert into kv values ('x_ne5', pg_temp.exc('u5', 3, 'not_expected'));
select is(pg_temp.links('b5') || ' ' || pg_temp.script('b5') || ' ' || (select state::text from public.home_submissions where id = pg_temp.k('d5')),
  '2:0@u5,3:1@u5,4:2@u5 true/needs_attention received', 'b5''s pages are in its script; the other booking''s page waits for staff');
select tests.as_user(pg_temp.uid('admin'));
insert into res select 'rh', public.script_exception_reject(pg_temp.k('x_ne5'), 'These pages are not all yours. Please upload your own answers again.');
select is(concat_ws('/', pg_temp.r('rh') ->> 'ok', pg_temp.r('rh') ->> 'submission_rejected'), 'true/true',
  'reject_home_submission_queues_email: rejecting the page rejects the family''s submission');
select tests.as_postgres();
select is((select concat_ws('/', state, rejected_reason) from public.home_submissions where id = pg_temp.k('d5')),
  'rejected/These pages are not all yours. Please upload your own answers again.', 'the submission is rejected with the reason');
select is((select count(*)::int from public.script_notices where kind = 'rejected' and submission_id = pg_temp.k('d5')), 1,
  'and an email to the family is queued (the student and linked parents)');
select is((select r ->> 'email' from public.script_notices n, jsonb_array_elements(public.script_notice_recipients(n)) r
           where n.kind = 'rejected' and n.submission_id = pg_temp.k('d5') and (r ->> 'profile_id')::uuid = pg_temp.uid('p1')),
  (select email::text from public.profiles where id = pg_temp.uid('p1')), 'the linked parent is one of the recipients');
select is(pg_temp.links('b5') || '|' || pg_temp.script('b5'), '|false/needs_attention',
  'the script no longer shows the rejected pages (no earlier submission counts)');
select is((select v.reason from public.script_versions v join public.scripts s on s.id = v.script_id and v.version = s.version where s.booking_id = pg_temp.k('b5')),
  'submission_rejected', 'as a new version; the earlier one is kept');
select is((select concat_ws('/', state, resolution) from public.script_exceptions where id = pg_temp.k('x_ne5')), 'resolved/rejected', 'the exception is resolved');
select tests.as_user(pg_temp.uid('s5'));
select is((select concat_ws('/', j -> 'submission' ->> 'state', j -> 'submission' ->> 'rejected_reason') from (select public.home_submission_status(pg_temp.k('b5')) as j) x),
  'rejected/These pages are not all yours. Please upload your own answers again.', 'the family sees "Rejected" with the reason from staff');
select tests.as_postgres();
select is((select count(*)::int from snap5 s join public.script_pages p on p.id = s.id and to_jsonb(p) = s.j), (select count(*)::int from snap5),
  'the rejected pages are kept exactly as they were');

-- ---------------------------------------------------------------------------------------------
-- late_accept_and_reject
-- ---------------------------------------------------------------------------------------------
-- b6 hands in late once: accepted.
select pg_temp.hand_in('s6', 'b6', 'd6', 'u6', true, '2031-07-07 12:40Z', '2031-07-07 12:45Z');
select pg_temp.run('u6', jsonb_build_array(pg_temp.page('u6', 0, 'q6', 2), pg_temp.page('u6', 1, 'q6', 3), pg_temp.page('u6', 2, 'q6', 4)));
select is(concat_ws('/', (select late from public.scripts where booking_id = pg_temp.k('b6')), pg_temp.script('b6'),
                    (select state from public.script_exceptions where id = pg_temp.bexc('b6', 'late'))), 't/true/needs_attention/open',
  'late_accept_and_reject: b6''s script is late, complete, and waits for the decision');
select tests.as_user(pg_temp.uid('admin'));
insert into res select 'la', public.script_late_decide(pg_temp.sid('b6'), true, 'The family had a power cut; accepted');
select is(concat_ws('/', pg_temp.r('la') ->> 'ok', pg_temp.r('la') ->> 'late_decision'), 'true/accept', 'staff accept the late script');
select tests.as_postgres();
select is(concat_ws('/', (select late || '/' || late_decision from public.scripts where booking_id = pg_temp.k('b6')), pg_temp.script('b6')),
  'true/accept/true/verified', 'it stays late, is accepted and is verified');
select is((select concat_ws('/', state, resolution, reason, resolved_by = pg_temp.uid('admin')) from public.script_exceptions where id = pg_temp.bexc('b6', 'late')),
  'resolved/late_accepted/The family had a power cut; accepted/t', 'the late exception is resolved with the decision and the reason');
select is((select count(*)::int from public.audit_log where action = 'script_late_accepted' and target_type = 'script' and target_id = pg_temp.sid('b6')
           and reason = 'The family had a power cut; accepted'), 1, 'and audited');
select tests.as_user(pg_temp.uid('admin2'));
select is(concat_ws('/', pg_temp.code(public.script_late_decide(pg_temp.sid('b6'), false, 'Changed my mind')),
                    public.script_late_decide(pg_temp.sid('b6'), false, 'Changed my mind') ->> 'resolved_by'), 'conflict/Ada Admin',
  'a second decision is a conflict naming who decided');
select tests.as_postgres();

-- b7 hands in on time, then replaces every page late: the late one is rejected and the on-time one counts again.
select pg_temp.hand_in('s7', 'b7', 'd7a', 'u7a', true, '2031-07-07 10:40Z', '2031-07-07 10:50Z');
select pg_temp.run('u7a', jsonb_build_array(pg_temp.page('u7a', 0, 'q7', 2), pg_temp.page('u7a', 1, 'q7', 3), pg_temp.page('u7a', 2, 'q7', 4)));
select is(pg_temp.script('b7'), 'true/verified', 'b7''s on-time submission is received and verified');
select pg_temp.hand_in('s7', 'b7', 'd7b', 'u7b', true, '2031-07-07 12:40Z', '2031-07-07 12:45Z');
select pg_temp.run('u7b', jsonb_build_array(pg_temp.page('u7b', 0, 'q7', 2), pg_temp.page('u7b', 1, 'q7', 3), pg_temp.page('u7b', 2, 'q7', 4)));
select is(pg_temp.links('b7') || ' ' || (select late::text from public.scripts where booking_id = pg_temp.k('b7')) || ' ' || pg_temp.script('b7'),
  '2:0@u7b,3:1@u7b,4:2@u7b true true/needs_attention', 'the late replacement now counts, and the script is late');
select tests.as_user(pg_temp.uid('admin'));
insert into res select 'lj', public.script_late_decide(pg_temp.sid('b7'), false, 'Handed in after the deadline with no reason given');
select is(concat_ws('/', pg_temp.r('lj') ->> 'ok', pg_temp.r('lj') ->> 'late_decision'), 'true/reject', 'staff reject the late script');
select tests.as_postgres();
select is((select string_agg(concat_ws('/', seq, state, coalesce(rejected_reason, '-')), ',' order by seq) from public.home_submissions where booking_id = pg_temp.k('b7')),
  '1/received/-,2/rejected/Handed in after the deadline with no reason given', 'the late submission is rejected with the reason; the on-time one is not');
select is((select count(*)::int from public.script_notices where kind = 'rejected' and submission_id = pg_temp.k('d7b')), 1, 'the family is emailed');
select is(pg_temp.links('b7') || ' ' || (select late || '/' || late_decision from public.scripts where booking_id = pg_temp.k('b7')) || ' ' || pg_temp.script('b7'),
  '2:0@u7a,3:1@u7a,4:2@u7a false/reject true/verified', 'the on-time pages count again: not late, verified');
select is((select concat_ws('/', state, resolution) from public.script_exceptions where id = pg_temp.bexc('b7', 'late')), 'resolved/late_rejected',
  'the late exception is resolved as rejected');
select is((select count(*)::int from public.audit_log where action = 'script_late_rejected' and target_id = pg_temp.sid('b7') and reason is not null), 1, 'and audited');

-- ---------------------------------------------------------------------------------------------
-- Confirming family-placed pages and pages sent as they are (b8).
-- ---------------------------------------------------------------------------------------------
select pg_temp.hand_in('s8', 'b8', 'd8', 'u8', true, '2031-07-07 10:40Z', '2031-07-07 10:45Z');
select pg_temp.run('u8', jsonb_build_array(pg_temp.page('u8', 0, 'q8', 2), pg_temp.page('u8', 1, 'q8', 3),
  pg_temp.page('u8', 2, 'q8', 4, 200, '{layout_unexpected}', false), pg_temp.page('u8', 3, null, null, 120)));
insert into kv values ('p8_2', pg_temp.pid('u8', 2)), ('p8_3', pg_temp.pid('u8', 3));
select tests.as_user(pg_temp.uid('s8'));
select public.home_page_send_as_is(pg_temp.k('p8_2'));
select public.home_page_place(pg_temp.k('p8_3'), 4);
select tests.as_postgres();
select is((select state::text from public.home_submissions where id = pg_temp.k('d8')) || ' ' || pg_temp.script('b8'), 'received true/needs_attention',
  'b8 sent page 4 as it is and placed a page with no code after page 4: received, waiting for staff');
select tests.as_user(pg_temp.uid('admin'));
select is(public.script_page_set_hidden_areas(pg_temp.pid('u8', 2), '[{"x":0.05,"y":0.02,"w":0.6,"h":0.05}]', 'Candidate name across the top') ->> 'areas', '1',
  'staff hide the name on the page whose layout was unexpected');
select is(public.script_exception_confirm(pg_temp.exc('u8', 2, 'poor_quality')) ->> 'resolution', 'confirmed', 'and confirm it');
select is(pg_temp.remasks('u8'), 1, 'a page with no marking picture, confirmed: a remask job is queued for its file');
select is(public.script_exception_confirm(pg_temp.exc('u8', 3, 'uncoded_family_page'), 'Continuation of question 4') ->> 'resolution', 'confirmed',
  'the family''s placement of the page with no code is confirmed');
select tests.as_postgres();
select is(pg_temp.remasks('u8') || ' ' || pg_temp.script('b8'), '1 true/verified', 'still one remask job; the script is verified');

-- ---------------------------------------------------------------------------------------------
-- resolution_keeps_original_page_row
-- ---------------------------------------------------------------------------------------------
select is((select count(*)::int from snap s join public.script_pages p on p.id = s.id and to_jsonb(p) = s.j), (select count(*)::int from snap),
  'resolution_keeps_original_page_row: every page row of the scanner file is exactly as the server recorded it');
select is((select count(*)::int from snap), 12, 'and none was deleted');

select * from finish();
rollback;
