begin;
create extension if not exists pgtap with schema extensions;
select plan(74);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures: an admin and three students; exam ea (papers v1 superseded and v2 current, two bookings), exam eb (one booking).
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('admin', tests.create_user('admin', 'active'));
insert into c select 's' || i, tests.create_user('student', 'active') from generate_series(1, 3) i;
create temp table kv (name text primary key, id uuid, path text);
grant all on kv to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
create function pg_temp.kp(p text) returns text language sql stable as $$ select path from kv where name = p $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.kp(text) to public;

insert into public.subjects (name, kind) values ('ZZ Scripts', 'school');
insert into public.exams (subject_id, title, paper, format, starts_at, duration_minutes, price_pence, price_confirmed, booking_deadline, status)
select s.id, 'ZZ ' || t.n, 'Paper ' || t.p, 'online', '2031-06-07 10:00 Europe/London', 90, 0, true, '2031-06-06 10:00 Europe/London', 'published'
from public.subjects s, (values ('ea', '1'), ('eb', '2')) t(n, p) where s.name = 'ZZ Scripts';
insert into kv (name, id) select substr(title, 4), id from public.exams where title in ('ZZ ea', 'ZZ eb');

insert into public.exam_papers (exam_id, kind, title, version, storage_path, page_count, byte_size, superseded_at)
values (pg_temp.k('ea'), 'paper', 'Question paper', 1, pg_temp.k('ea')::text || '/' || gen_random_uuid()::text || '.pdf', 3, 1000, now()),
       (pg_temp.k('ea'), 'paper', 'Question paper', 2, pg_temp.k('ea')::text || '/' || gen_random_uuid()::text || '.pdf', 4, 1000, null),
       (pg_temp.k('ea'), 'insert', 'Formula sheet', 1, pg_temp.k('ea')::text || '/' || gen_random_uuid()::text || '.pdf', 1, 1000, null),
       (pg_temp.k('eb'), 'paper', 'Question paper', 1, pg_temp.k('eb')::text || '/' || gen_random_uuid()::text || '.pdf', 2, 1000, null);
insert into kv (name, id) select 'pv1', id from public.exam_papers where exam_id = pg_temp.k('ea') and kind = 'paper' and version = 1;
insert into kv (name, id) select 'pv2', id from public.exam_papers where exam_id = pg_temp.k('ea') and kind = 'paper' and version = 2;
insert into kv (name, id) select 'pb', id from public.exam_papers where exam_id = pg_temp.k('eb');
update public.paper_page_roles set role = 'cover' where paper_id = pg_temp.k('pv2') and page = 1;
insert into public.paper_hidden_areas (paper_id, page, x, y, w, h) values (pg_temp.k('pv2'), 2, 0.1, 0.1, 0.5, 0.05);

insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting)
select pg_temp.k(t.e), pg_temp.uid(t.s), pg_temp.uid(t.s), 'paid', 0, 'home' from (values ('ea', 's1'), ('ea', 's2'), ('eb', 's3')) t(e, s);
insert into kv (name, id)
select t.n, b.id from (values ('b1', 's1'), ('b2', 's2'), ('b3', 's3')) t(n, s) join public.bookings b on b.student_id = pg_temp.uid(t.s);
insert into public.paper_copies (code, booking_id, paper_id, page_count) values
  (public.copy_code_new(), pg_temp.k('b1'), pg_temp.k('pv1'), 5),
  (public.copy_code_new(), pg_temp.k('b1'), pg_temp.k('pv2'), 6),
  (public.copy_code_new(), pg_temp.k('b2'), pg_temp.k('pv2'), 6),
  (public.copy_code_new(), pg_temp.k('b3'), pg_temp.k('pb'), 4);
insert into kv (name, id) select 'c1v2', id from public.paper_copies where booking_id = pg_temp.k('b1') and paper_id = pg_temp.k('pv2');
insert into kv (name, id) select 'cb3', id from public.paper_copies where booking_id = pg_temp.k('b3');

insert into public.home_submissions (booking_id, seq, submitted_by) values
  (pg_temp.k('b1'), 1, pg_temp.uid('s1')), (pg_temp.k('b2'), 1, pg_temp.uid('s2'));
insert into kv (name, id) select 'h1', id from public.home_submissions where booking_id = pg_temp.k('b1');
insert into kv (name, id) select 'h2', id from public.home_submissions where booking_id = pg_temp.k('b2');

-- Uploads u1 (s1, b1, pending), u2 (s2, b2, pending), u3 (s1, b1, queued).
create function pg_temp.mk_upload(p_name text, p_user text, p_bk text, p_sub text, p_state public.upload_state) returns void
language sql as $$
  insert into kv values (p_name, gen_random_uuid(), 'home/' || pg_temp.k(p_bk)::text || '/' || gen_random_uuid()::text || '.jpg');
  insert into public.script_uploads (id, exam_id, booking_id, submission_id, kind, position, storage_path, mime, byte_size, state, uploaded_by)
  select k.id, (select exam_id from public.bookings where id = pg_temp.k(p_bk)), pg_temp.k(p_bk), pg_temp.k(p_sub), 'home_photo', 1,
    k.path, 'image/jpeg', 1000, p_state, pg_temp.uid(p_user) from kv k where k.name = p_name;
$$;
grant execute on function pg_temp.mk_upload(text, text, text, text, public.upload_state) to public;
select pg_temp.mk_upload('u1', 's1', 'b1', 'h1', 'pending');
select pg_temp.mk_upload('u2', 's2', 'b2', 'h2', 'pending');
select pg_temp.mk_upload('u3', 's1', 'b1', 'h1', 'queued');

-- ---------------------------------------------------------------------------------------------
-- Schema and privileges.
-- ---------------------------------------------------------------------------------------------
select is((select count(*)::int from pg_class k join pg_namespace n on n.oid = k.relnamespace
  where n.nspname = 'public' and k.relkind = 'r' and k.relrowsecurity
    and k.relname in ('scripts', 'script_versions', 'script_page_links', 'home_submissions', 'scan_batches',
                      'script_uploads', 'script_pages', 'processing_jobs', 'script_exceptions')),
  9, 'tables_have_rls: the nine script tables exist with RLS enabled');
select is((select count(*)::int from unnest(array['scripts', 'script_versions', 'script_page_links', 'home_submissions', 'scan_batches',
    'script_uploads', 'script_pages', 'processing_jobs', 'script_exceptions']) t,
  unnest(array['insert', 'update', 'delete', 'truncate']) pr, unnest(array['anon', 'authenticated']) ro
  where has_table_privilege(ro, 'public.' || t, pr)), 0, 'no direct writes for anon or authenticated');
select is((select count(*)::int from unnest(array['scripts', 'script_versions', 'script_page_links', 'home_submissions', 'scan_batches',
    'script_uploads', 'script_pages', 'processing_jobs', 'script_exceptions']) t
  where has_table_privilege('anon', 'public.' || t, 'select')), 0, 'anon reads none of them');
select is((select array_agg(t.typname::text order by t.typname) from pg_type t join pg_namespace n on n.oid = t.typnamespace
  where n.nspname = 'public' and t.typname in ('script_source', 'script_state', 'upload_kind', 'upload_state', 'page_state', 'job_state',
    'exception_kind', 'submission_state')),
  array['exception_kind', 'job_state', 'page_state', 'script_source', 'script_state', 'submission_state', 'upload_kind', 'upload_state'],
  'the eight enums exist');
select is((select array_agg(e.enumlabel::text order by e.enumsortorder) from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'script_state'),
  array['receiving', 'checking', 'needs_attention', 'verified', 'ready_to_mark', 'marking', 'marked', 'checked', 'final', 'withdrawn', 'void'], 'script_state labels');
select is((select array_agg(e.enumlabel::text order by e.enumsortorder) from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'exception_kind'),
  array['no_code', 'unknown_code', 'other_exam', 'not_expected', 'duplicate', 'missing_pages', 'uncoded_family_page', 'mixed_versions',
    'poor_quality', 'late', 'name_visible', 'processing_failed'], 'exception_kind labels');
select results_eq($q$select public, file_size_limit, allowed_mime_types from storage.buckets where id = 'script-uploads'$q$,
  $q$values (false, 1073741824::bigint, array['image/jpeg', 'image/png', 'image/heic', 'image/heif', 'application/pdf'])$q$,
  'script-uploads is a private 1 GiB bucket for photos and PDFs');
select results_eq($q$select public, file_size_limit, allowed_mime_types from storage.buckets where id = 'script-pages'$q$,
  $q$values (false, 10485760::bigint, array['image/jpeg'])$q$, 'script-pages is a private 10 MB JPEG bucket');
select throws_ok($$insert into public.script_uploads (exam_id, kind, storage_path, mime, byte_size, uploaded_by)
  values (gen_random_uuid(), 'home_photo', 'x/none', 'image/jpeg', 1, gen_random_uuid())$$, '23514', null, 'an upload belongs to a submission or a batch');
select throws_ok(format($q$insert into public.script_uploads (exam_id, submission_id, batch_id, kind, storage_path, mime, byte_size, uploaded_by)
  values (%L, %L, gen_random_uuid(), 'home_photo', 'x/both', 'image/jpeg', 1, gen_random_uuid())$q$, pg_temp.k('ea'), pg_temp.k('h1')),
  '23514', null, 'an upload cannot belong to both');
select throws_ok(format($q$insert into public.home_submissions (booking_id, seq) values (%L, 2)$q$, pg_temp.k('b1')),
  '23505', null, 'at most one draft submission per booking');
select ok(not has_function_privilege('authenticated', 'public.processing_job_claim(text,timestamptz)', 'execute')
  and not has_function_privilege('anon', 'public.processing_job_claim(text,timestamptz)', 'execute')
  and has_function_privilege('service_role', 'public.processing_job_claim(text,timestamptz)', 'execute')
  and not has_function_privilege('authenticated', 'public.processing_job_finish(bigint,boolean,text,timestamptz)', 'execute')
  and not has_function_privilege('anon', 'public.processing_job_finish(bigint,boolean,text,timestamptz)', 'execute')
  and has_function_privilege('service_role', 'public.processing_job_finish(bigint,boolean,text,timestamptz)', 'execute'),
  'claim_not_granted_to_authenticated: the job functions are for service_role only');
select ok(not has_function_privilege('authenticated', 'public.script_number_next(uuid)', 'execute')
  and not has_function_privilege('anon', 'public.script_number_next(uuid)', 'execute'), 'script_number_next is internal');

-- ---------------------------------------------------------------------------------------------
-- family_cannot_insert_rows_directly
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('s1'));
select throws_ok(format($q$insert into public.script_uploads (exam_id, submission_id, kind, storage_path, mime, byte_size, uploaded_by)
  values (%L, %L, 'home_photo', 'home/x/y.jpg', 'image/jpeg', 1, %L)$q$, pg_temp.k('ea'), pg_temp.k('h1'), pg_temp.uid('s1')),
  '42501', null, 'family_cannot_insert_rows_directly: no upload row');
select throws_ok(format($q$insert into public.home_submissions (booking_id, seq) values (%L, 9)$q$, pg_temp.k('b1')), '42501', null, 'no submission row');
select throws_ok($q$insert into public.processing_jobs (upload_id, kind) values (gen_random_uuid(), 'prepare')$q$, '42501', null, 'no job row');
select throws_ok($q$update public.script_uploads set state = 'stored'$q$, '42501', null, 'no update of an upload');
select is((select count(*)::int from public.script_uploads) + (select count(*)::int from public.home_submissions) + (select count(*)::int from public.scripts),
  0, 'a family reads none of the script rows directly');
select throws_ok($q$select public.processing_job_claim('w')$q$, '42501', null, 'claim_not_granted_to_authenticated: a signed-in user cannot claim');
select tests.as_postgres();
select tests.as_user(pg_temp.uid('admin'));
select ok((select count(*) from public.script_uploads) = 3 and (select count(*) from public.home_submissions) = 2, 'an admin reads uploads and submissions');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- storage_insert_only_for_pending_row_path
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('s1'));
select lives_ok(format($q$insert into storage.objects (bucket_id, name) values ('script-uploads', %L)$q$, pg_temp.kp('u1')),
  'storage_insert_only_for_pending_row_path: the uploader stores the file of its pending row');
select throws_ok(format($q$insert into storage.objects (bucket_id, name) values ('script-uploads', %L)$q$, 'home/' || pg_temp.k('b1')::text || '/' || gen_random_uuid()::text || '.jpg'),
  '42501', null, 'a path with no row is refused');
select throws_ok(format($q$insert into storage.objects (bucket_id, name) values ('script-uploads', %L)$q$, pg_temp.kp('u2')),
  '42501', null, 'another user''s row path is refused');
select throws_ok(format($q$insert into storage.objects (bucket_id, name) values ('script-uploads', %L)$q$, pg_temp.kp('u3')),
  '42501', null, 'a row that is no longer pending is refused');
select throws_ok(format($q$insert into storage.objects (bucket_id, name) values ('script-pages', %L)$q$, pg_temp.kp('u1')),
  '42501', null, 'the page bucket takes no uploads from users');
select is((select count(*)::int from storage.objects where bucket_id = 'script-uploads'), 1, 'the uploader reads its own file');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('s2'));
select is((select count(*)::int from storage.objects where bucket_id = 'script-uploads'), 0, 'another user reads nothing');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is((select count(*)::int from storage.objects where bucket_id = 'script-uploads'), 1, 'an admin reads it');
select tests.as_postgres();
update public.script_uploads set state = 'stored' where id = pg_temp.k('u1');
select tests.as_user(pg_temp.uid('s1'));
select is((select count(*)::int from storage.objects where bucket_id = 'script-uploads'), 1, 'the uploader still reads it once stored');
select tests.as_postgres();
update public.script_uploads set state = 'queued' where id = pg_temp.k('u1');
select tests.as_user(pg_temp.uid('s1'));
select is((select count(*)::int from storage.objects where bucket_id = 'script-uploads'), 0, 'but not once it is queued for processing');
select tests.as_postgres();
select tests.as_user(pg_temp.uid('admin'));
select set_config('storage.allow_delete_query', 'true', true);
delete from storage.objects where bucket_id = 'script-uploads';
select set_config('storage.allow_delete_query', '', true);
select tests.as_postgres();
select is((select count(*)::int from storage.objects where bucket_id = 'script-uploads'), 1, 'not even an admin can delete script files from the API');
select tests.as_user(pg_temp.uid('admin'));
select throws_ok(format($q$insert into storage.objects (bucket_id, name) values ('script-pages', %L)$q$, pg_temp.k('ea')::text || '/x/1-full.jpg'),
  '42501', null, 'nor add page pictures from the API');
select tests.as_postgres();
insert into storage.objects (bucket_id, name) values ('script-pages', pg_temp.k('ea')::text || '/x/1-full.jpg');
select tests.as_user(pg_temp.uid('s1'));
select is((select count(*)::int from storage.objects where bucket_id = 'script-pages'), 0, 'a family reads no page pictures');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is((select count(*)::int from storage.objects where bucket_id = 'script-pages'), 1, 'an admin reads page pictures');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- Jobs: claim.
-- ---------------------------------------------------------------------------------------------
insert into public.processing_jobs (upload_id, kind) values (pg_temp.k('u1'), 'prepare');
insert into public.processing_jobs (upload_id, kind) values (pg_temp.k('u2'), 'prepare');
create temp table claims (name text primary key, j jsonb);
grant all on claims to public;
insert into claims select 'a', public.processing_job_claim('worker-1');
insert into claims select 'b', public.processing_job_claim('worker-2');
insert into claims select 'c', public.processing_job_claim('worker-3');
select ok((select j -> 'job' ->> 'id' from claims where name = 'a') <> (select j -> 'job' ->> 'id' from claims where name = 'b')
  and (select j from claims where name = 'a') is not null and (select j from claims where name = 'b') is not null,
  'claim_skips_locked_jobs: two claims in one transaction return different jobs');
select is((select j from claims where name = 'c'), null, 'and when nothing is left, the claim is SQL null');
select is((select j -> 'upload' ->> 'id' from claims where name = 'a'), pg_temp.k('u1')::text, 'the oldest job is claimed first');
select is((select (j -> 'job' ->> 'kind') || '/' || (j -> 'job' ->> 'attempts') from claims where name = 'a'), 'prepare/1', 'the job: kind and first attempt');
select is((select state::text || '/' || attempts || '/' || locked_by from public.processing_jobs where upload_id = pg_temp.k('u1')), 'running/1/worker-1', 'claimed: running, attempts 1, locked by the worker');
select is((select (j -> 'upload') - 'id' from claims where name = 'a'),
  jsonb_build_object('kind', 'home_photo', 'mime', 'image/jpeg', 'storage_path', pg_temp.kp('u1'), 'exam_id', pg_temp.k('ea'),
    'booking_id', pg_temp.k('b1'), 'batch_id', null), 'the upload: kind, mime, path, exam, booking and no batch');
select is((select jsonb_array_length(j -> 'papers') from claims where name = 'a'), 2, 'every version of the exam''s question paper (inserts are not papers)');
select is((select p ->> 'page_count' from claims x, jsonb_array_elements(x.j -> 'papers') p where x.name = 'a' and p ->> 'paper_id' = pg_temp.k('pv2')::text),
  '4', 'a paper carries its page count');
select is((select p -> 'roles' -> 0 from claims x, jsonb_array_elements(x.j -> 'papers') p where x.name = 'a' and p ->> 'paper_id' = pg_temp.k('pv2')::text),
  jsonb_build_object('page', 1, 'role', 'cover'), 'and its page roles');
select is((select jsonb_array_length(p -> 'roles') from claims x, jsonb_array_elements(x.j -> 'papers') p where x.name = 'a' and p ->> 'paper_id' = pg_temp.k('pv2')::text),
  4, 'one role per page');
select is((select p -> 'areas' from claims x, jsonb_array_elements(x.j -> 'papers') p where x.name = 'a' and p ->> 'paper_id' = pg_temp.k('pv2')::text),
  '[{"page": 2, "x": 0.1, "y": 0.1, "w": 0.5, "h": 0.05}]'::jsonb, 'and its hidden areas');
select is((select jsonb_array_length(p -> 'areas') from claims x, jsonb_array_elements(x.j -> 'papers') p where x.name = 'a' and p ->> 'paper_id' = pg_temp.k('pv1')::text),
  0, 'a paper with no hidden areas has an empty list');
select is((select count(*)::int from claims x, jsonb_object_keys(x.j -> 'copies') where x.name = 'a'), 3, 'copies of both versions, for this exam only');
select is((select j -> 'copies' -> (select code from public.paper_copies where id = pg_temp.k('c1v2')) from claims where name = 'a'),
  jsonb_build_object('copy_id', pg_temp.k('c1v2'), 'paper_id', pg_temp.k('pv2'), 'booking_id', pg_temp.k('b1'), 'page_count', 6),
  'a copy by its code: copy, paper, booking and page count');
select ok((select not ((j -> 'copies') ? (select code from public.paper_copies where id = pg_temp.k('cb3'))) from claims where name = 'a'),
  'copies of another exam are not included');

-- claim_reclaims_after_15_minutes: a running job whose worker went quiet comes back.
select is(public.processing_job_claim('worker-4', now() + interval '14 minutes'), null, 'a job locked 14 minutes ago is not reclaimed');
insert into claims select 'd', public.processing_job_claim('worker-4', now() + interval '16 minutes');
select is((select (j -> 'upload' ->> 'id') || '/' || (j -> 'job' ->> 'attempts') from claims where name = 'd'), pg_temp.k('u1')::text || '/2',
  'claim_reclaims_after_15_minutes: the quiet job comes back with attempts 2');
select is((select locked_by || '/' || (locked_at = now() + interval '16 minutes') from public.processing_jobs where upload_id = pg_temp.k('u1')), 'worker-4/true',
  'locked by the new worker at the given time');

-- ---------------------------------------------------------------------------------------------
-- Jobs: finish.
-- ---------------------------------------------------------------------------------------------
select is(public.processing_job_finish((select id from public.processing_jobs where upload_id = pg_temp.k('u1')), true) ->> 'ok', 'true', 'a finished job');
select is((select state::text || '/' || (finished_at is not null) from public.processing_jobs where upload_id = pg_temp.k('u1')), 'done/true', 'is done with a finish time');
select is(public.processing_job_finish((select id from public.processing_jobs where upload_id = pg_temp.k('u1')), true) ->> 'code', 'conflict', 'a job that is not running cannot finish again');
select is(public.processing_job_finish(-1, true) ->> 'code', 'not_found', 'an unknown job');
select is(public.processing_job_finish((select id from public.processing_jobs where upload_id = pg_temp.k('u2')), true) ->> 'ok', 'true', 'the other job finishes');

-- finish_retries_twice_then_fails (upload u3).
insert into public.processing_jobs (upload_id, kind) values (pg_temp.k('u3'), 'prepare');
insert into claims select 'e1', public.processing_job_claim('w', now());
select is(public.processing_job_finish((select (j -> 'job' ->> 'id')::bigint from claims where name = 'e1'), false, repeat('x', 400), now()) ->> 'state', 'queued',
  'finish_retries_twice_then_fails: the first failure queues a retry');
select is((select state::text || '/' || char_length(last_error) || '/' || (run_after = now() + interval '1 minute') || '/' || coalesce(locked_by, 'none')
  from public.processing_jobs where upload_id = pg_temp.k('u3')), 'queued/300/true/none', 'the error is cut to 300 characters, the retry is a minute away and unlocked');
select is(public.processing_job_claim('w', now()), null, 'a retry is not claimed before its time');
insert into claims select 'e2', public.processing_job_claim('w', now() + interval '2 minutes');
select is((select j -> 'job' ->> 'attempts' from claims where name = 'e2'), '2', 'the retry is attempt 2');
select is(public.processing_job_finish((select (j -> 'job' ->> 'id')::bigint from claims where name = 'e2'), false, 'second', now() + interval '2 minutes') ->> 'state', 'queued',
  'the second failure queues another retry');
select is((select run_after = now() + interval '4 minutes' from public.processing_jobs where upload_id = pg_temp.k('u3')), true, 'two minutes after the second attempt');
insert into claims select 'e3', public.processing_job_claim('w', now() + interval '10 minutes');
select is(public.processing_job_finish((select (j -> 'job' ->> 'id')::bigint from claims where name = 'e3'), false, 'third', now() + interval '10 minutes') ->> 'state', 'failed',
  'the third failure fails the job');
select is((select state::text from public.script_uploads where id = pg_temp.k('u3')), 'failed', 'and the upload');
select is((select count(*)::int from public.script_exceptions where upload_id = pg_temp.k('u3') and kind = 'processing_failed' and state = 'open'
  and exam_id = pg_temp.k('ea') and booking_id = pg_temp.k('b1')), 1, 'with exactly one open processing_failed exception');
select is((select last_error from public.processing_jobs where upload_id = pg_temp.k('u3')), 'third', 'the last error is kept');
select is(public.processing_job_claim('w', now() + interval '1 day'), null, 'a failed job is never claimed again');

-- ---------------------------------------------------------------------------------------------
-- script_number_sequence_per_exam
-- ---------------------------------------------------------------------------------------------
select is(public.script_number_next(pg_temp.k('ea')), 'S-' || (select exam_code from public.exams where id = pg_temp.k('ea')) || '-0001', 'script_number_sequence_per_exam: the first number');
insert into public.scripts (booking_id, exam_id, source, number)
values (pg_temp.k('b1'), pg_temp.k('ea'), 'home', public.script_number_next(pg_temp.k('ea')));
select is(public.script_number_next(pg_temp.k('ea')), 'S-' || (select exam_code from public.exams where id = pg_temp.k('ea')) || '-0002', 'the second');
insert into public.scripts (booking_id, exam_id, source, number)
values (pg_temp.k('b2'), pg_temp.k('ea'), 'home', public.script_number_next(pg_temp.k('ea')));
select is((select string_agg(number, ',' order by number) from public.scripts where exam_id = pg_temp.k('ea')),
  (select 'S-' || exam_code || '-0001,S-' || exam_code || '-0002' from public.exams where id = pg_temp.k('ea')), 'numbers are kept');
select is(public.script_number_next(pg_temp.k('eb')), 'S-' || (select exam_code from public.exams where id = pg_temp.k('eb')) || '-0001', 'another exam starts at 0001');
select is((select state::text || '/' || version || '/' || complete || '/' || late from public.scripts where booking_id = pg_temp.k('b1')), 'receiving/0/false/false', 'a new script is receiving, version 0');
select throws_ok(format($q$insert into public.scripts (booking_id, exam_id, source, number) values (%L, %L, 'home', 'S-X-0001')$q$, pg_temp.k('b1'), pg_temp.k('ea')),
  '23505', null, 'one script per booking');

select * from finish();
rollback;
