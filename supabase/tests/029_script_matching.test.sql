begin;
create extension if not exists pgtap with schema extensions;
select plan(105);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Exam ea: paper v1 (3 pages: 1 cover, 2 answer, 3 information; superseded) and v2 (4 pages: 1 cover, 2-3 answer, 4 blank), two
-- centres; exam eb: another exam. Home bookings b1, b2 (the brother), b3, b8-b12, b15-b20; centre bookings b4
-- (present), b5 (absent), b6 (the other centre), b7 (cancelled), b13, b14; bx on exam eb.
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('admin', tests.create_user('admin', 'active'));
insert into c select 's' || i, tests.create_user('student', 'active') from generate_series(1, 20) i;
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create temp table res (name text primary key, j jsonb);
grant all on res to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
create function pg_temp.r(p text) returns jsonb language sql stable as $$ select j from res where name = p $$;
-- A stand-in SHA-256 of an upload's original (64 lowercase hex characters, one per upload).
create function pg_temp.h(p text) returns text language sql stable as $$ select encode(sha256(convert_to(pg_temp.k(p)::text, 'UTF8')), 'hex') $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.r(text), pg_temp.h(text) to public;

insert into public.subjects (name, kind) values ('ZZ Matching', 'school');
insert into public.venues (name, rooms) values ('ZZ Matching hall', array['R1', 'R2']);
insert into public.exams (subject_id, title, paper, format, starts_at, duration_minutes, price_pence, price_confirmed, booking_deadline, status)
select s.id, 'ZZM ' || t.n, 'Paper ' || t.p, 'both', '2031-06-07 10:00 Europe/London', 90, 0, true, '2031-06-06 10:00 Europe/London', 'published'
from public.subjects s, (values ('ea', '1'), ('eb', '2')) t(n, p) where s.name = 'ZZ Matching';
insert into kv (name, id) select substr(e.title, 5), e.id from public.exams e join public.subjects s on s.id = e.subject_id where s.name = 'ZZ Matching';
insert into public.exam_centres (exam_id, venue_id, room, seat_limit)
select pg_temp.k('ea'), v.id, r, 50 from public.venues v, unnest(array['R1', 'R2']) r where v.name = 'ZZ Matching hall';
insert into kv (name, id) select 'ce' || substr(room, 2), id from public.exam_centres where exam_id = pg_temp.k('ea');

insert into public.exam_papers (exam_id, kind, title, version, storage_path, page_count, byte_size, superseded_at)
values (pg_temp.k('ea'), 'paper', 'Question paper', 1, pg_temp.k('ea')::text || '/' || gen_random_uuid()::text || '.pdf', 3, 1000, now());
insert into public.exam_papers (exam_id, kind, title, version, storage_path, page_count, byte_size, superseded_at)
values (pg_temp.k('ea'), 'paper', 'Question paper', 2, pg_temp.k('ea')::text || '/' || gen_random_uuid()::text || '.pdf', 4, 1000, null),
       (pg_temp.k('eb'), 'paper', 'Question paper', 1, pg_temp.k('eb')::text || '/' || gen_random_uuid()::text || '.pdf', 2, 1000, null);
insert into kv (name, id) select 'pv' || version, id from public.exam_papers where exam_id = pg_temp.k('ea');
insert into kv (name, id) select 'pb', id from public.exam_papers where exam_id = pg_temp.k('eb');
update public.paper_page_roles set role = (case page when 1 then 'cover' when 4 then 'blank' else 'answer' end)::public.page_role
where paper_id = pg_temp.k('pv2');
update public.paper_page_roles set role = (case page when 1 then 'cover' when 2 then 'answer' else 'information' end)::public.page_role
where paper_id = pg_temp.k('pv1');

create function pg_temp.mk_booking(p_name text, p_student text, p_exam text, p_sitting public.sitting_mode, p_centre text,
  p_status public.booking_status default 'paid') returns void language sql as $$
  insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting, centre_id)
  values (pg_temp.k(p_exam), pg_temp.uid(p_student), pg_temp.uid(p_student), p_status, 0, p_sitting, pg_temp.k(p_centre));
  insert into kv (name, id) select p_name, b.id from public.bookings b where b.student_id = pg_temp.uid(p_student) and b.exam_id = pg_temp.k(p_exam);
$$;
create function pg_temp.mk_copy(p_name text, p_booking text, p_paper text, p_pages int) returns void language sql as $$
  insert into public.paper_copies (code, booking_id, paper_id, page_count) values (public.copy_code_new(), pg_temp.k(p_booking), pg_temp.k(p_paper), p_pages);
  insert into kv (name, id) select p_name, id from public.paper_copies where booking_id = pg_temp.k(p_booking) and paper_id = pg_temp.k(p_paper);
$$;
create function pg_temp.mk_sub(p_name text, p_booking text, p_seq int, p_replaces boolean default true) returns void language sql as $$
  insert into public.home_submissions (booking_id, seq, replaces_all, state, submitted_at) values (pg_temp.k(p_booking), p_seq, p_replaces, 'checking', now());
  insert into kv (name, id) select p_name, id from public.home_submissions where booking_id = pg_temp.k(p_booking) and seq = p_seq;
$$;
create function pg_temp.mk_upload(p_name text, p_sub text, p_pos int default 1) returns void language sql as $$
  insert into kv (name, id) values (p_name, gen_random_uuid());
  insert into public.script_uploads (id, exam_id, booking_id, submission_id, kind, position, storage_path, mime, byte_size, state, uploaded_by)
  select pg_temp.k(p_name), b.exam_id, b.id, s.id, 'home_photo', p_pos, 'home/' || b.id::text || '/' || pg_temp.k(p_name)::text || '.jpg',
    'image/jpeg', 1000, 'queued', b.student_id
  from public.home_submissions s join public.bookings b on b.id = s.booking_id where s.id = pg_temp.k(p_sub);
$$;
create function pg_temp.mk_scan(p_name text, p_batch text) returns void language sql as $$
  insert into kv (name, id) values (p_name, gen_random_uuid());
  insert into public.script_uploads (id, exam_id, batch_id, kind, storage_path, mime, byte_size, state, uploaded_by)
  select pg_temp.k(p_name), sb.exam_id, sb.id, 'scan_file', 'batch/' || sb.id::text || '/' || pg_temp.k(p_name)::text || '.pdf',
    'application/pdf', 1000, 'queued', pg_temp.uid('admin')
  from public.scan_batches sb where sb.id = pg_temp.k(p_batch);
$$;

-- One prepared page as the processing server sends it: page p_page of copy p_copy (or the code p_code; neither for a
-- page with no code), with its sharpness, quality flags and whether a marking picture was made.
create function pg_temp.page(p_up text, p_idx int, p_code text, p_page int, p_blank boolean, p_sharp numeric,
  p_flags text[], p_marking boolean) returns jsonb language sql stable as $$
  select jsonb_build_object('source_index', p_idx, 'code', p_code, 'copy_page', p_page, 'blank', p_blank,
    'quality', jsonb_build_object('sharpness', p_sharp, 'brightness', 180, 'cut_off', 'cut_off' = any (p_flags), 'flags', to_jsonb(p_flags)),
    'rotation', 0,
    'full_path', u.exam_id::text || '/' || u.id::text || '/' || p_idx || '-full.jpg',
    'marking_path', case when p_marking then u.exam_id::text || '/' || u.id::text || '/' || p_idx || '-marking.jpg' end)
  from public.script_uploads u where u.id = pg_temp.k(p_up)
$$;
create function pg_temp.pg(p_up text, p_idx int, p_copy text, p_page int, p_sharp numeric default 200,
  p_flags text[] default '{}', p_marking boolean default true) returns jsonb language sql stable as $$
  select pg_temp.page(p_up, p_idx, (select code from public.paper_copies where id = pg_temp.k(p_copy)), p_page, false, p_sharp, p_flags, p_marking)
$$;
create function pg_temp.pg_none(p_up text, p_idx int, p_blank boolean, p_flags text[] default '{}') returns jsonb language sql stable as $$
  select pg_temp.page(p_up, p_idx, null, null, p_blank, 80, p_flags, false)
$$;

-- Runs a prepare job for an upload as the server would: claim, record the pages, finish.
create function pg_temp.run(p_up text, p_pages jsonb) returns jsonb language plpgsql as $$
declare
  v jsonb;
  r jsonb;
begin
  insert into public.processing_jobs (upload_id, kind) values (pg_temp.k(p_up), 'prepare');
  v := public.processing_job_claim('t-worker');
  if v is null or v -> 'upload' ->> 'id' <> pg_temp.k(p_up)::text then
    raise exception 'claimed another job';
  end if;
  r := public.script_pages_record((v -> 'job' ->> 'id')::bigint, 't-worker', (v -> 'job' ->> 'attempts')::int, pg_temp.h(p_up), p_pages);
  perform public.processing_job_finish((v -> 'job' ->> 'id')::bigint, 't-worker', (v -> 'job' ->> 'attempts')::int, true);
  return r;
end;
$$;
create function pg_temp.script(p_booking text) returns uuid language sql stable as $$ select id from public.scripts where booking_id = pg_temp.k(p_booking) $$;
create function pg_temp.links(p_booking text) returns text language sql stable as $$
  select coalesce(string_agg(l.copy_page::text, ',' order by l.copy_page), '')
  from public.scripts s join public.script_page_links l on l.script_id = s.id and l.version = s.version where s.booking_id = pg_temp.k(p_booking)
$$;
create function pg_temp.page_id(p_up text, p_idx int) returns uuid language sql stable as $$
  select id from public.script_pages where upload_id = pg_temp.k(p_up) and source_index = p_idx and replaced_at is null
$$;
grant execute on function pg_temp.script(text), pg_temp.links(text), pg_temp.page_id(text, int) to public;

select pg_temp.mk_booking(t.b, t.s, 'ea', 'home', null) from (values ('b1', 's1'), ('b2', 's2'), ('b3', 's3'), ('b8', 's8'), ('b9', 's9'),
  ('b10', 's10'), ('b11', 's11'), ('b12', 's12'), ('b15', 's15'), ('b16', 's16'), ('b17', 's17'), ('b18', 's18'), ('b19', 's19'), ('b20', 's20')) t(b, s);
select pg_temp.mk_booking('b4', 's4', 'ea', 'centre', 'ce1');
select pg_temp.mk_booking('b5', 's5', 'ea', 'centre', 'ce1');
select pg_temp.mk_booking('b6', 's6', 'ea', 'centre', 'ce2');
select pg_temp.mk_booking('b7', 's7', 'ea', 'centre', 'ce1', 'cancelled');
select pg_temp.mk_booking('b13', 's13', 'ea', 'centre', 'ce1');
select pg_temp.mk_booking('b14', 's14', 'ea', 'centre', 'ce1');
select pg_temp.mk_booking('bx', 's1', 'eb', 'home', null);
select pg_temp.mk_copy('c' || substr(t.b, 2), t.b, 'pv2', 6) from (values ('b1'), ('b2'), ('b4'), ('b5'), ('b6'), ('b7'), ('b8'), ('b9'),
  ('b10'), ('b11'), ('b12'), ('b13'), ('b14'), ('b15'), ('b16'), ('b17'), ('b18'), ('b20')) t(b);
select pg_temp.mk_copy('c3a', 'b3', 'pv1', 5);
select pg_temp.mk_copy('c19', 'b19', 'pv1', 5);
select pg_temp.mk_copy('c3b', 'b3', 'pv2', 6);
select pg_temp.mk_copy('cx', 'bx', 'pb', 4);
insert into public.attendance (exam_id, student_id, status, marked_by) values
  (pg_temp.k('ea'), pg_temp.uid('s4'), 'present', pg_temp.uid('admin')),
  (pg_temp.k('ea'), pg_temp.uid('s5'), 'absent', pg_temp.uid('admin'));

-- Jobs left in a local database by other work are not part of this test.
update public.processing_jobs set state = 'done' where state in ('queued', 'running');

-- ---------------------------------------------------------------------------------------------
-- record_not_granted_to_authenticated
-- ---------------------------------------------------------------------------------------------
select ok(not has_function_privilege('authenticated', 'public.script_pages_record(bigint,text,int,text,jsonb,timestamptz)', 'execute')
  and not has_function_privilege('anon', 'public.script_pages_record(bigint,text,int,text,jsonb,timestamptz)', 'execute')
  and has_function_privilege('service_role', 'public.script_pages_record(bigint,text,int,text,jsonb,timestamptz)', 'execute'),
  'record_not_granted_to_authenticated: recording pages is for the service role only');
select ok(not exists (select 1 from unnest(array['public.script_evaluate(uuid)', 'public.script_evaluate_at(uuid,timestamptz)',
    'public.home_submission_evaluate(uuid,timestamptz)', 'public.home_submission_assemble(uuid,uuid,timestamptz)',
    'public.script_create(uuid,public.script_source,timestamptz)', 'public.script_version_write(uuid,jsonb,uuid,uuid,text,timestamptz)',
    'public.script_links(uuid)', 'public.script_raise_mixed(uuid,uuid)', 'public.script_page_is_answer(uuid,int)',
    'public.script_page_poor(jsonb,text,boolean)', 'public.script_pages_valid(jsonb,text)']) f,
  unnest(array['anon', 'authenticated', 'service_role']) r
  where has_function_privilege(r, f, 'execute')), 'script_evaluate, the submission checks and the helpers are internal');
select tests.as_user(pg_temp.uid('s1'));
select throws_ok($$select public.script_pages_record(1, 'w', 1, repeat('0', 64), '[]'::jsonb)$$, '42501', null, 'a signed-in user cannot record pages');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- home_pages_match_and_receive: b1 sends every page of its copy (cover, answer pages, the page whose role is blank
-- and a used spare page) and a blank sheet.
-- ---------------------------------------------------------------------------------------------
select pg_temp.mk_sub('h1', 'b1', 1);
select pg_temp.mk_upload('u1', 'h1');
insert into res select 'b1', pg_temp.run('u1', jsonb_build_array(
  pg_temp.pg('u1', 0, 'c1', 1, p_marking => false), pg_temp.pg('u1', 1, 'c1', 2), pg_temp.pg('u1', 2, 'c1', 3),
  pg_temp.pg('u1', 3, 'c1', 4, p_marking => false), pg_temp.pg('u1', 4, 'c1', 5), pg_temp.pg_none('u1', 5, true)));
select is((select (j ->> 'ok') || '/' || (j ->> 'pages') || '/' || (j ->> 'matched') from res where name = 'b1'), 'true/6/5',
  'home_pages_match_and_receive: six pages recorded, five matched');
select is((select string_agg(source_index || ':' || state, ',' order by source_index) from public.script_pages where upload_id = pg_temp.k('u1')),
  '0:matched,1:matched,2:matched,3:matched,4:matched,5:blank', 'each page''s state');
select ok((select blank and booking_id is null and copy_id is null from public.script_pages where upload_id = pg_temp.k('u1') and source_index = 5),
  'the blank sheet is kept, marked blank');
select ok((select bool_and(booking_id = pg_temp.k('b1') and copy_id = pg_temp.k('c1') and copy_page = source_index + 1)
  from public.script_pages where upload_id = pg_temp.k('u1') and state = 'matched'), 'matched pages carry the booking, the copy and the page');
select is((select state::text from public.script_uploads where id = pg_temp.k('u1')), 'processed', 'the upload is processed');
select is((select state::text || '/' || (checked_at is not null) from public.home_submissions where id = pg_temp.k('h1')), 'received/true',
  'the submission is received');
select is((select source::text || '/' || version || '/' || complete || '/' || state::text || '/' || (received_at is not null)
  from public.scripts where booking_id = pg_temp.k('b1')), 'home/1/true/verified/true', 'the script: home, version 1, complete and verified');
select is((select number from public.scripts where booking_id = pg_temp.k('b1')),
  (select 'S-' || exam_code || '-0001' from public.exams where id = pg_temp.k('ea')), 'its number comes from the exam''s sequence');
select is(pg_temp.links('b1'), '1,2,3,4,5', 'every matched page is linked by its copy page');
select is((select count(*)::int || '/' || bool_and(submission_id = pg_temp.k('h1')) || '/' || bool_and(upload_id is null)
  from public.script_versions where script_id = pg_temp.script('b1')), '1/true/true', 'one version, made by the submission');
select is((select count(*)::int from public.script_exceptions where booking_id = pg_temp.k('b1') or upload_id = pg_temp.k('u1')), 0,
  'and no exception');

-- ---------------------------------------------------------------------------------------------
-- cover_and_blank_pages_not_required: b12 sends only the answer pages 2 and 3 of v2.
-- ---------------------------------------------------------------------------------------------
select pg_temp.mk_sub('h12', 'b12', 1);
select pg_temp.mk_upload('u12', 'h12');
select pg_temp.run('u12', jsonb_build_array(pg_temp.pg('u12', 0, 'c12', 2), pg_temp.pg('u12', 1, 'c12', 3)));
select is((select state::text from public.home_submissions where id = pg_temp.k('h12')), 'received',
  'cover_and_blank_pages_not_required: the answer pages alone are enough');
select is((select state::text || '/' || complete from public.scripts where booking_id = pg_temp.k('b12')), 'verified/true', 'the script is verified');
select is(pg_temp.links('b12'), '2,3', 'with the two answer pages');

-- ---------------------------------------------------------------------------------------------
-- home_page_from_other_booking_not_matched (Review Focus 2): b15's upload holds a page printed for b2.
-- ---------------------------------------------------------------------------------------------
select pg_temp.mk_sub('h15', 'b15', 1);
select pg_temp.mk_upload('u15', 'h15');
select pg_temp.run('u15', jsonb_build_array(pg_temp.pg('u15', 0, 'c15', 2), pg_temp.pg('u15', 1, 'c15', 3), pg_temp.pg('u15', 2, 'c2', 2)));
select is((select state::text || '/' || coalesce(booking_id::text, 'none') || '/' || (copy_id = pg_temp.k('c2'))
  from public.script_pages where upload_id = pg_temp.k('u15') and source_index = 2), 'rejected/none/true',
  'home_page_from_other_booking_not_matched: the brother''s page is rejected, matched to nobody');
select is((select count(*)::int from public.script_exceptions where kind = 'not_expected' and state = 'open' and page_id = pg_temp.page_id('u15', 2)
  and booking_id = pg_temp.k('b15') and script_id = pg_temp.script('b15') and upload_id = pg_temp.k('u15') and details ->> 'reason' = 'other_booking'),
  1, 'an open not_expected exception for staff, on the uploader''s script');
select is((select count(*)::int from public.script_pages where booking_id = pg_temp.k('b2')) + (select count(*)::int from public.scripts where booking_id = pg_temp.k('b2')),
  0, 'the brother''s booking gets no page and no script');
select is((select state::text from public.home_submissions where id = pg_temp.k('h15')), 'received', 'the family''s own pages are all there');
select is((select state::text from public.scripts where booking_id = pg_temp.k('b15')), 'needs_attention', 'but the script waits for staff');
select is(pg_temp.links('b15'), '2,3', 'the stray page is not linked');

-- ---------------------------------------------------------------------------------------------
-- unknown_code_raises_exception: an unknown code, a copy of another exam and a page beyond the copy.
-- ---------------------------------------------------------------------------------------------
select pg_temp.mk_sub('h16', 'b16', 1);
select pg_temp.mk_upload('u16', 'h16');
select pg_temp.run('u16', jsonb_build_array(pg_temp.pg('u16', 0, 'c16', 2), pg_temp.pg('u16', 1, 'c16', 3),
  pg_temp.page('u16', 2, 'ZZZZZZZZZ', 1, false, 200, '{}', true), pg_temp.pg('u16', 3, 'cx', 1), pg_temp.pg('u16', 4, 'c16', 9)));
select is((select string_agg(state::text, ',' order by source_index) from public.script_pages where upload_id = pg_temp.k('u16') and source_index >= 2),
  'rejected,rejected,rejected', 'unknown_code_raises_exception: the three pages are rejected');
select is((select string_agg(e.kind::text, ',' order by p.source_index) from public.script_exceptions e join public.script_pages p on p.id = e.page_id
  where e.upload_id = pg_temp.k('u16')), 'unknown_code,other_exam,unknown_code', 'unknown code, other exam, and a page the copy does not have');
select is((select details ->> 'code' from public.script_exceptions where page_id = pg_temp.page_id('u16', 2)), 'ZZZZZZZZZ', 'the unknown code is shown to staff');
select ok((select p.copy_id is null and e.details ->> 'other_exam_id' = pg_temp.k('eb')::text from public.script_pages p
  join public.script_exceptions e on e.page_id = p.id where p.id = pg_temp.page_id('u16', 3)), 'a page of another exam names that exam, not its copy');
select is((select s.state::text || '/' || x.state::text from public.home_submissions s, public.scripts x
  where s.id = pg_temp.k('h16') and x.booking_id = pg_temp.k('b16')), 'received/needs_attention', 'received; the script waits for staff');

-- ---------------------------------------------------------------------------------------------
-- home_missing_answer_page_needs_attention: b8 sends page 2 only; then confirms page 3 was left blank (R1).
-- ---------------------------------------------------------------------------------------------
select pg_temp.mk_sub('h8', 'b8', 1);
select pg_temp.mk_upload('u8', 'h8');
select pg_temp.run('u8', jsonb_build_array(pg_temp.pg('u8', 0, 'c8', 2)));
select is((select state::text from public.home_submissions where id = pg_temp.k('h8')), 'needs_attention',
  'home_missing_answer_page_needs_attention: answer page 3 is missing');
select is((select state::text || '/' || complete || '/' || (received_at is null) from public.scripts where booking_id = pg_temp.k('b8')),
  'needs_attention/false/true', 'the script needs attention, is not complete and not received');
select is(pg_temp.links('b8'), '2', 'page 2 is linked');
update public.home_submissions set blank_confirmed = '{3}' where id = pg_temp.k('h8');
select public.script_evaluate(pg_temp.script('b8'));
select is((select state::text from public.home_submissions where id = pg_temp.k('h8')), 'received',
  'script_evaluate checks the submission again: page 3 confirmed blank, received');
select is((select state::text || '/' || complete || '/' || (received_at is not null) from public.scripts where booking_id = pg_temp.k('b8')),
  'verified/true/true', 'and the script is complete, verified and received');

-- ---------------------------------------------------------------------------------------------
-- Two uploads in one submission; a blurred page and a page with no marking picture (R16).
-- ---------------------------------------------------------------------------------------------
select pg_temp.mk_sub('h9', 'b9', 1);
select pg_temp.mk_upload('u9a', 'h9', 1);
select pg_temp.mk_upload('u9b', 'h9', 2);
select pg_temp.run('u9a', jsonb_build_array(pg_temp.pg('u9a', 0, 'c9', 2, 30, '{blurred}')));
select is((select state::text from public.home_submissions where id = pg_temp.k('h9')), 'checking', 'the submission is checked once every upload is prepared');
select is((select state::text || '/' || version from public.scripts where booking_id = pg_temp.k('b9')), 'checking/0',
  'the script is made on its first matched page and is checking, with no version yet');
select pg_temp.run('u9b', jsonb_build_array(pg_temp.pg('u9b', 0, 'c9', 3, p_marking => false)));
select is((select state::text from public.home_submissions where id = pg_temp.k('h9')), 'needs_attention',
  'a blurred page and a page without a marking picture ask for a retake');
select is((select version || '/' || pg_temp.links('b9') from public.scripts where booking_id = pg_temp.k('b9')), '1/2,3', 'both are linked into version 1');
select is((select count(*)::int from public.script_versions where script_id = pg_temp.script('b9')), 1, 'one version for the two uploads');
select is((select count(*)::int from public.script_exceptions where booking_id = pg_temp.k('b9')), 0, 'home quality problems raise no exception');
insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id)
select pg_temp.k('ea'), 'poor_quality', pg_temp.k('b9'), pg_temp.script('b9'), p.id, p.upload_id
from public.script_pages p where p.upload_id in (pg_temp.k('u9a'), pg_temp.k('u9b'));
select public.script_evaluate(pg_temp.script('b9'));
select is((select s.state::text || '/' || x.state::text from public.home_submissions s, public.scripts x
  where s.id = pg_temp.k('h9') and x.booking_id = pg_temp.k('b9')), 'received/needs_attention',
  'pages sent as they are (a poor_quality exception each): received, and staff check them');

-- rerun_keeps_send_as_it_is: the first file is prepared again; the family's choice follows the page.
insert into public.processing_jobs (upload_id, kind) values (pg_temp.k('u9a'), 'prepare');
insert into res select 'claim9', public.processing_job_claim('R9');
select public.script_pages_record((pg_temp.r('claim9') -> 'job' ->> 'id')::bigint, 'R9', 1, pg_temp.h('u9a'),
  jsonb_build_array(pg_temp.pg('u9a', 0, 'c9', 2, 30, '{blurred}')));
select public.processing_job_finish((pg_temp.r('claim9') -> 'job' ->> 'id')::bigint, 'R9', 1, true);
select is((select count(*)::int from public.script_exceptions where kind = 'poor_quality' and state = 'open' and page_id = pg_temp.page_id('u9a', 0)), 1,
  'rerun_keeps_send_as_it_is: the family''s "Send as it is" moves to the new page');
select is((select count(*)::int from public.script_pages where upload_id = pg_temp.k('u9a')), 1, 'and the earlier page, named by nothing now, is gone');
select is((select s.state::text || '/' || x.state::text from public.home_submissions s, public.scripts x
  where s.id = pg_temp.k('h9') and x.booking_id = pg_temp.k('b9')), 'received/needs_attention', 'the submission stays received');

-- flagged_cover_page_still_received: on b19's v1 copy, a cut-off cover and an information page whose layout could not
-- be proven (neither is needed) with a clean answer page.
select pg_temp.mk_sub('h19', 'b19', 1);
select pg_temp.mk_upload('u19', 'h19');
select pg_temp.run('u19', jsonb_build_array(pg_temp.pg('u19', 0, 'c19', 1, 200, '{cut_off}', false), pg_temp.pg('u19', 1, 'c19', 2),
  pg_temp.pg('u19', 2, 'c19', 3, 200, '{layout_unexpected}', false)));
select is((select state::text from public.home_submissions where id = pg_temp.k('h19')), 'received',
  'flagged_cover_page_still_received: flags on pages that are not answer pages ask for no retake');
select is((select state::text || '/' || pg_temp.links('b19') from public.scripts where booking_id = pg_temp.k('b19')), 'verified/1,2,3',
  'the script is verified, with all three pages');

-- ---------------------------------------------------------------------------------------------
-- duplicate_keeps_clearer_page (home): page 2 twice; page 3 twice, the sharper one cut off.
-- ---------------------------------------------------------------------------------------------
select pg_temp.mk_sub('h11', 'b11', 1);
select pg_temp.mk_upload('u11', 'h11');
select pg_temp.run('u11', jsonb_build_array(pg_temp.pg('u11', 0, 'c11', 2, 100), pg_temp.pg('u11', 1, 'c11', 2, 300),
  pg_temp.pg('u11', 2, 'c11', 3, 500, '{cut_off}'), pg_temp.pg('u11', 3, 'c11', 3, 150)));
select is((select string_agg(source_index || ':' || state, ',' order by source_index) from public.script_pages where upload_id = pg_temp.k('u11')),
  '0:duplicate,1:matched,2:duplicate,3:matched', 'duplicate_keeps_clearer_page: the sharper page is kept, and a usable page before a flagged one');
select is((select string_agg(l.copy_page || '=' || p.source_index, ',' order by l.copy_page) from public.script_page_links l
  join public.script_pages p on p.id = l.page_id join public.scripts s on s.id = l.script_id and s.version = l.version
  where s.booking_id = pg_temp.k('b11')), '2=1,3=3', 'the kept pages are linked');
select is((select count(*)::int from public.script_exceptions where booking_id = pg_temp.k('b11')), 0, 'home duplicates raise no exception');
select is((select state::text from public.home_submissions where id = pg_temp.k('h11')), 'received', 'and the submission is received');

-- ---------------------------------------------------------------------------------------------
-- pages_from_two_versions_raise_mixed_versions: b3 sends page 2 of its v1 copy and page 3 of its v2 copy.
-- ---------------------------------------------------------------------------------------------
select pg_temp.mk_sub('h3', 'b3', 1);
select pg_temp.mk_upload('u3', 'h3');
select pg_temp.run('u3', jsonb_build_array(pg_temp.pg('u3', 0, 'c3a', 2), pg_temp.pg('u3', 1, 'c3b', 3)));
select is((select count(*)::int from public.script_exceptions where kind = 'mixed_versions' and state = 'open' and script_id = pg_temp.script('b3')
  and booking_id = pg_temp.k('b3') and upload_id = pg_temp.k('u3') and jsonb_array_length(details -> 'paper_ids') = 2), 1,
  'pages_from_two_versions_raise_mixed_versions: one exception naming both versions');
select is((select s.state::text || '/' || x.state::text from public.home_submissions s, public.scripts x
  where s.id = pg_temp.k('h3') and x.booking_id = pg_temp.k('b3')), 'needs_attention/needs_attention', 'the submission and the script need attention');

-- ---------------------------------------------------------------------------------------------
-- centre_page_absent_or_other_centre_flagged (Review Focus 3): one scanner file of centre ce1.
-- ---------------------------------------------------------------------------------------------
insert into public.scan_batches (exam_id, centre_id, number, created_by) values (pg_temp.k('ea'), pg_temp.k('ce1'), 'ZZ-' || gen_random_uuid()::text, pg_temp.uid('admin'));
insert into kv (name, id) select 'bt1', id from public.scan_batches where exam_id = pg_temp.k('ea');
select pg_temp.mk_scan('us1', 'bt1');
select pg_temp.run('us1', jsonb_build_array(
  pg_temp.pg('us1', 0, 'c4', 2), pg_temp.pg('us1', 1, 'c5', 2), pg_temp.pg('us1', 2, 'c6', 2), pg_temp.pg('us1', 3, 'c7', 2),
  pg_temp.pg('us1', 4, 'c2', 2), pg_temp.pg_none('us1', 5, false), pg_temp.pg_none('us1', 6, true), pg_temp.pg('us1', 7, 'c4', 3, 20, '{blurred}'),
  pg_temp.pg('us1', 8, 'c4', 1, p_marking => false), pg_temp.pg('us1', 9, 'c4', 5, p_marking => false),
  pg_temp.pg('us1', 10, 'c14', 2), pg_temp.pg('us1', 11, 'c14', 3)));
select is((select string_agg(source_index || ':' || state, ',' order by source_index) from public.script_pages where upload_id = pg_temp.k('us1')),
  '0:matched,1:rejected,2:rejected,3:rejected,4:rejected,5:unmatched,6:blank,7:matched,8:matched,9:matched,10:matched,11:matched',
  'centre_page_absent_or_other_centre_flagged: each page''s state');
select is((select string_agg(e.details ->> 'reason', ',' order by p.source_index) from public.script_exceptions e join public.script_pages p on p.id = e.page_id
  where e.upload_id = pg_temp.k('us1') and e.kind = 'not_expected'), 'absent,other_centre,booking_status,home_sitting',
  'absent, another centre, a cancelled booking and a home sitting are flagged, never matched');
select is((select count(*)::int from public.script_exceptions e join public.script_pages p on p.id = e.page_id join public.paper_copies cp on cp.id = p.copy_id
  where e.upload_id = pg_temp.k('us1') and e.kind = 'not_expected' and e.booking_id = cp.booking_id), 4, 'each names the booking the page was printed for');
select is((select count(*) filter (where e.kind = 'no_code' and p.source_index = 5)::int || '/' || count(*) filter (where p.source_index = 6)::int
  from public.script_exceptions e join public.script_pages p on p.id = e.page_id where e.upload_id = pg_temp.k('us1')), '1/0',
  'a page with no code goes to staff; a blank sheet raises nothing');
select is((select string_agg(p.source_index::text, ',' order by p.source_index) from public.script_exceptions e join public.script_pages p on p.id = e.page_id
  where e.upload_id = pg_temp.k('us1') and e.kind = 'poor_quality'), '7,9', 'poor_quality for the blurred page and the answer page with no marking picture');
select is((select count(*)::int from public.scripts where booking_id in (pg_temp.k('b5'), pg_temp.k('b6'), pg_temp.k('b7'), pg_temp.k('b2'))), 0,
  'no script for a flagged candidate');
select is((select source::text || '/' || state::text from public.scripts where booking_id = pg_temp.k('b4')) || '/' || pg_temp.links('b4'),
  'centre/needs_attention/1,2,3,5', 'the present candidate''s script: centre, its pages linked, waiting for staff');
select is((select state::text || '/' || complete || '/' || (received_at is not null) from public.scripts where booking_id = pg_temp.k('b14')),
  'receiving/false/true', 'a clean centre script is receiving until staff complete the centre');
update public.scripts set complete = true where booking_id = pg_temp.k('b14');
select public.script_evaluate(pg_temp.script('b14'));
select is((select state::text from public.scripts where booking_id = pg_temp.k('b14')), 'verified', 'once complete (Task 9) it is verified');
select is((select state::text from public.script_uploads where id = pg_temp.k('us1')), 'processed', 'the scanner file is processed');

-- ---------------------------------------------------------------------------------------------
-- duplicate_keeps_clearer_page (scan): page 2 of b13 in three files.
-- ---------------------------------------------------------------------------------------------
select pg_temp.mk_scan('us2', 'bt1');
select pg_temp.mk_scan('us3', 'bt1');
select pg_temp.mk_scan('us4', 'bt1');
select pg_temp.run('us2', jsonb_build_array(pg_temp.pg('us2', 0, 'c13', 2, 100)));
select pg_temp.run('us3', jsonb_build_array(pg_temp.pg('us3', 0, 'c13', 2, 400)));
select is((select state::text from public.script_pages where id = pg_temp.page_id('us2', 0)) || '/' || (select state::text from public.script_pages where id = pg_temp.page_id('us3', 0)),
  'duplicate/matched', 'a sharper scan of the same page in a later file is kept');
select is((select count(*)::int from public.script_exceptions where kind = 'duplicate' and state = 'open' and page_id = pg_temp.page_id('us2', 0)
  and upload_id = pg_temp.k('us3') and booking_id = pg_temp.k('b13') and details ->> 'kept_page_id' = pg_temp.page_id('us3', 0)::text), 1,
  'the page set aside raises a duplicate exception');
select is((select s.version || '/' || (l.page_id = pg_temp.page_id('us3', 0)) from public.scripts s
  join public.script_page_links l on l.script_id = s.id and l.version = s.version and l.copy_page = 2 where s.booking_id = pg_temp.k('b13')),
  '2/true', 'version 2 links the kept page');
select pg_temp.run('us4', jsonb_build_array(pg_temp.pg('us4', 0, 'c13', 2, 50)));
select is((select p.state::text || '/' || (select count(*) from public.script_exceptions e where e.page_id = p.id and e.kind = 'duplicate')
  from public.script_pages p where p.id = pg_temp.page_id('us4', 0)), 'duplicate/1', 'a less clear copy is set aside with one exception');
select is((select version from public.scripts where booking_id = pg_temp.k('b13')), 2, 'a page set aside makes no new version');

-- Staff accept b3's two versions; a stray page of b3's in a scanner file must not raise mixed_versions again.
update public.script_exceptions set state = 'resolved', resolved_at = now() where kind = 'mixed_versions' and script_id = pg_temp.script('b3');
select pg_temp.mk_scan('us7', 'bt1');
select pg_temp.run('us7', jsonb_build_array(pg_temp.pg('us7', 0, 'c3b', 2)));
select is((select string_agg(kind::text || ':' || state, ',' order by kind::text) from public.script_exceptions where booking_id = pg_temp.k('b3')),
  'mixed_versions:resolved,not_expected:open', 'a stray page of b3 in a scan is flagged, and the resolved mixed_versions stays resolved');

-- ---------------------------------------------------------------------------------------------
-- rerun_job_replaces_pages (Review Focus 1): the job is recorded, the worker dies, the job is claimed again.
-- ---------------------------------------------------------------------------------------------
select pg_temp.mk_sub('h10', 'b10', 1);
select pg_temp.mk_upload('u10', 'h10');
insert into public.processing_jobs (upload_id, kind) values (pg_temp.k('u10'), 'prepare');
insert into res select 'claimA', public.processing_job_claim('A');
insert into res select 'recA', public.script_pages_record((pg_temp.r('claimA') -> 'job' ->> 'id')::bigint, 'A', 1, pg_temp.h('u10'),
  jsonb_build_array(pg_temp.pg('u10', 0, 'c10', 2), pg_temp.pg('u10', 1, 'c10', 3), pg_temp.pg('u10', 2, 'c2', 2)));
select is(pg_temp.r('recA') ->> 'ok', 'true', 'rerun_job_replaces_pages: the first run records its pages');
create temp table old_ids as select id from public.script_pages where upload_id = pg_temp.k('u10');
insert into res select 'claimB', public.processing_job_claim('B', now() + interval '16 minutes');
select is(pg_temp.r('claimB') -> 'job' ->> 'attempts', '2', 'the quiet job is claimed again');
select is(public.script_pages_record((pg_temp.r('claimA') -> 'job' ->> 'id')::bigint, 'A', 1, pg_temp.h('u10'),
  jsonb_build_array(pg_temp.pg('u10', 0, 'c10', 2)), now() + interval '17 minutes') ->> 'code', 'conflict',
  'the old worker can no longer record');
select is((select count(*)::int from public.script_pages where upload_id = pg_temp.k('u10') and id in (select id from old_ids)), 3,
  'and changed nothing');
select is(public.script_pages_record((pg_temp.r('claimB') -> 'job' ->> 'id')::bigint, 'B', 2, pg_temp.h('u10'),
  jsonb_build_array(pg_temp.pg('u10', 0, 'c10', 2, 250), pg_temp.pg('u10', 1, 'c10', 3, 250), pg_temp.pg('u10', 2, 'c2', 2)),
  now() + interval '17 minutes') ->> 'ok', 'true', 'the new worker records the same upload again');
select is((select count(*)::int || '/' || count(*) filter (where id in (select id from old_ids))::int from public.script_pages where upload_id = pg_temp.k('u10')),
  '3/0', 'one set of pages: the earlier ones are gone');
select is((select (select count(*) from public.script_versions v where v.script_id = s.id) || '/' || s.version from public.scripts s where s.booking_id = pg_temp.k('b10')),
  '1/1', 'and one version');
select is((select count(*)::int from public.script_page_links l join public.script_pages p on p.id = l.page_id
  where l.script_id = pg_temp.script('b10') and p.upload_id = pg_temp.k('u10') and p.replaced_at is null), 2, 'linking the new pages');
select is((select count(*)::int from public.script_exceptions where upload_id = pg_temp.k('u10') and kind = 'not_expected'), 1, 'the exception is not raised twice');
select is((select state::text from public.home_submissions where id = pg_temp.k('h10')) || '/' || (select count(*) from public.scripts where booking_id = pg_temp.k('b10')),
  'received/1', 'the submission is received, with one script');
select is(public.processing_job_finish((pg_temp.r('claimB') -> 'job' ->> 'id')::bigint, 'B', 2, true, null, now() + interval '17 minutes') ->> 'state', 'done', 'and the job is done');

-- A scanner file recorded, its worker dies, another file adds to the same script, then the first file runs again:
-- its earlier page stays for the versions that show it, marked replaced.
select pg_temp.mk_scan('us5', 'bt1');
select pg_temp.mk_scan('us6', 'bt1');
insert into public.processing_jobs (upload_id, kind) values (pg_temp.k('us5'), 'prepare');
insert into res select 'claim5', public.processing_job_claim('A5');
select public.script_pages_record((pg_temp.r('claim5') -> 'job' ->> 'id')::bigint, 'A5', 1, pg_temp.h('us5'), jsonb_build_array(pg_temp.pg('us5', 0, 'c13', 3)));
select pg_temp.run('us6', jsonb_build_array(pg_temp.pg('us6', 0, 'c13', 5)));
insert into res select 'claim5b', public.processing_job_claim('B5', now() + interval '16 minutes');
select public.script_pages_record((pg_temp.r('claim5b') -> 'job' ->> 'id')::bigint, 'B5', 2, pg_temp.h('us5'), jsonb_build_array(pg_temp.pg('us5', 0, 'c13', 3, 250)),
  now() + interval '16 minutes');
select is((select count(*) filter (where replaced_at is null)::int || '/' || count(*) filter (where replaced_at is not null)::int
  from public.script_pages where upload_id = pg_temp.k('us5')), '1/1', 'a rerun after a later version keeps the earlier page, marked replaced');
select is((select string_agg(l.copy_page || ':' || (p.upload_id = pg_temp.k('us5') and p.replaced_at is null) || (p.upload_id = pg_temp.k('us6')), ',' order by l.copy_page)
  from public.script_page_links l join public.script_pages p on p.id = l.page_id join public.scripts s on s.id = l.script_id and s.version = l.version
  where s.booking_id = pg_temp.k('b13')), '2:falsefalse,3:truefalse,5:falsetrue', 'the current version shows the new page and keeps the other file''s page');
select ok(exists (select 1 from public.script_page_links l join public.script_pages p on p.id = l.page_id
  where l.script_id = pg_temp.script('b13') and l.version = (select version - 1 from public.scripts where booking_id = pg_temp.k('b13'))
    and p.upload_id = pg_temp.k('us5') and p.replaced_at is not null), 'the earlier version still shows the earlier page');
select public.processing_job_finish((pg_temp.r('claim5b') -> 'job' ->> 'id')::bigint, 'B5', 2, true, null, now() + interval '16 minutes');

-- ---------------------------------------------------------------------------------------------
-- sha256_recorded_once: the original's SHA-256 is kept from the first record; it can never change.
-- ---------------------------------------------------------------------------------------------
select is((select sha256 from public.script_uploads where id = pg_temp.k('u10')), pg_temp.h('u10'), 'sha256_recorded_once: a record keeps the original''s SHA-256');
select pg_temp.mk_scan('us8', 'bt1');
insert into public.processing_jobs (upload_id, kind) values (pg_temp.k('us8'), 'prepare');
insert into res select 'claim8', public.processing_job_claim('H');
select is((select string_agg(public.script_pages_record((pg_temp.r('claim8') -> 'job' ->> 'id')::bigint, 'H', 1, t.h,
    jsonb_build_array(pg_temp.pg('us8', 0, 'c13', 6))) ->> 'code', '/' order by t.n)
  from (values (1, 'abc'), (2, upper(pg_temp.h('us8'))), (3, null)) t(n, h)), 'invalid_input/invalid_input/invalid_input',
  'a SHA-256 that is not 64 lowercase hex characters is refused');
select is(public.script_pages_record((pg_temp.r('claim8') -> 'job' ->> 'id')::bigint, 'H', 1, pg_temp.h('us8'),
  jsonb_build_array(pg_temp.pg('us8', 0, 'c13', 6))) ->> 'ok', 'true', 'the first record is accepted');
select is((select sha256 from public.script_uploads where id = pg_temp.k('us8')), pg_temp.h('us8'), 'and sets the upload''s SHA-256');
create temp table us8_ids as select id from public.script_pages where upload_id = pg_temp.k('us8');
insert into public.script_exceptions (exam_id, kind, booking_id, page_id, upload_id)
values (pg_temp.k('ea'), 'name_visible', pg_temp.k('b13'), pg_temp.page_id('us8', 0), pg_temp.k('us8'));
select is(public.script_pages_record((pg_temp.r('claim8') -> 'job' ->> 'id')::bigint, 'H', 1, pg_temp.h('us8'),
  jsonb_build_array(pg_temp.pg('us8', 0, 'c13', 6, 300))) ->> 'ok', 'true', 'a rerun with the same SHA-256 is accepted');
select is((select count(*) filter (where p.replaced_at is null)::int || '/' || count(*) filter (where p.replaced_at is not null
    and exists (select 1 from public.script_exceptions e where e.page_id = p.id and e.kind = 'name_visible'))::int
  from public.script_pages p where p.upload_id = pg_temp.k('us8')), '1/1', 'a page an exception still names is kept, marked replaced, not deleted');
delete from us8_ids;
insert into us8_ids select id from public.script_pages where upload_id = pg_temp.k('us8');
select is(public.script_pages_record((pg_temp.r('claim8') -> 'job' ->> 'id')::bigint, 'H', 1, pg_temp.h('us1'),
  jsonb_build_array(pg_temp.pg('us8', 0, 'c13', 6, 400), pg_temp.pg('us8', 1, 'c13', 5))),
  '{"ok": false, "code": "conflict", "reason": "sha256_mismatch"}'::jsonb, 'a different SHA-256 is a conflict: the original must never change');
select is((select u.sha256 = pg_temp.h('us8') and u.state = 'processed'
    and (select array_agg(id order by id) from public.script_pages where upload_id = u.id) = (select array_agg(id order by id) from us8_ids)
  from public.script_uploads u where u.id = pg_temp.k('us8')), true, 'and nothing changed');
select public.processing_job_finish((pg_temp.r('claim8') -> 'job' ->> 'id')::bigint, 'H', 1, true);

-- ---------------------------------------------------------------------------------------------
-- script_number_assigned_once: b1 retakes page 3 in a second submission that replaces some pages.
-- ---------------------------------------------------------------------------------------------
select pg_temp.mk_sub('h1b', 'b1', 2, false);
select pg_temp.mk_upload('u1b', 'h1b');
select pg_temp.run('u1b', jsonb_build_array(pg_temp.pg('u1b', 0, 'c1', 3, 400)));
select is((select version || '/' || (number = (select 'S-' || exam_code || '-0001' from public.exams where id = pg_temp.k('ea')))
  || '/' || (select count(*) from public.scripts where booking_id = pg_temp.k('b1')) from public.scripts where booking_id = pg_temp.k('b1')),
  '2/true/1', 'script_number_assigned_once: a new version, the same number, one script');
select is((select string_agg(l.copy_page || ':' || (p.upload_id = pg_temp.k('u1b')), ',' order by l.copy_page) from public.script_page_links l
  join public.script_pages p on p.id = l.page_id join public.scripts s on s.id = l.script_id and s.version = l.version where s.booking_id = pg_temp.k('b1')),
  '1:false,2:false,3:true,4:false,5:false', 'the retaken page replaces page 3 over the previous version''s links');
select is((select string_agg(state::text, '/' order by seq) from public.home_submissions where booking_id = pg_temp.k('b1')), 'received/received',
  'the new submission is received');
select ok((select count(distinct number) = count(*) and count(*) >= 10 from public.scripts where exam_id = pg_temp.k('ea')), 'every script has its own number');

-- ---------------------------------------------------------------------------------------------
-- A prepare job that fails for good does not leave the family on "Checking your pages".
-- ---------------------------------------------------------------------------------------------
select pg_temp.mk_sub('h17', 'b17', 1);
select pg_temp.mk_upload('u17', 'h17');
insert into public.processing_jobs (upload_id, kind) values (pg_temp.k('u17'), 'prepare');
insert into res select 'f1', public.processing_job_claim('w', now());
select public.processing_job_finish((pg_temp.r('f1') -> 'job' ->> 'id')::bigint, 'w', 1, false, 'unreadable', now());
insert into res select 'f2', public.processing_job_claim('w', now() + interval '2 minutes');
select public.processing_job_finish((pg_temp.r('f2') -> 'job' ->> 'id')::bigint, 'w', 2, false, 'unreadable', now() + interval '2 minutes');
select is((select state::text from public.home_submissions where id = pg_temp.k('h17')), 'checking', 'while a retry is due the family sees checking');
insert into res select 'f3', public.processing_job_claim('w', now() + interval '10 minutes');
select public.processing_job_finish((pg_temp.r('f3') -> 'job' ->> 'id')::bigint, 'w', 3, false, 'unreadable', now() + interval '10 minutes');
select is((select u.state::text || '/' || s.state::text from public.script_uploads u join public.home_submissions s on s.id = u.submission_id
  where u.id = pg_temp.k('u17')), 'failed/needs_attention', 'after the last failure the submission needs attention');

-- b18 sends two files: the second is prepared at once, the first fails three times and is the last to settle.
select pg_temp.mk_sub('h18', 'b18', 1);
select pg_temp.mk_upload('u18bad', 'h18', 1);
select pg_temp.mk_upload('u18', 'h18', 2);
insert into public.processing_jobs (upload_id, kind) values (pg_temp.k('u18bad'), 'prepare');
insert into res select 'g1', public.processing_job_claim('w', now() + interval '2 days');
select public.processing_job_finish((pg_temp.r('g1') -> 'job' ->> 'id')::bigint, 'w', 1, false, 'unreadable', now() + interval '2 days');
insert into public.processing_jobs (upload_id, kind, run_after) values (pg_temp.k('u18'), 'prepare', now() + interval '2 days');
insert into res select 'g2', public.processing_job_claim('w', now() + interval '2 days');
select is(public.script_pages_record((pg_temp.r('g2') -> 'job' ->> 'id')::bigint, 'w', 1, pg_temp.h('u18'),
  jsonb_build_array(pg_temp.pg('u18', 0, 'c18', 2), pg_temp.pg('u18', 1, 'c18', 3)), now() + interval '2 days') ->> 'ok', 'true',
  'the good file is recorded while the other waits for a retry');
select public.processing_job_finish((pg_temp.r('g2') -> 'job' ->> 'id')::bigint, 'w', 1, true, null, now() + interval '2 days');
select is((select state::text from public.home_submissions where id = pg_temp.k('h18')), 'checking', 'so the submission is still checking');
insert into res select 'g3', public.processing_job_claim('w', now() + interval '2 days 2 minutes');
select public.processing_job_finish((pg_temp.r('g3') -> 'job' ->> 'id')::bigint, 'w', 2, false, 'unreadable', now() + interval '2 days 2 minutes');
insert into res select 'g4', public.processing_job_claim('w', now() + interval '2 days 10 minutes');
select public.processing_job_finish((pg_temp.r('g4') -> 'job' ->> 'id')::bigint, 'w', 3, false, 'unreadable', now() + interval '2 days 10 minutes');
select is((select s.state::text || '/' || x.version || '/' || pg_temp.links('b18') || '/' || x.state::text
  from public.home_submissions s, public.scripts x where s.id = pg_temp.k('h18') and x.booking_id = pg_temp.k('b18')),
  'received/1/2,3/needs_attention', 'when the failed file settles last, the good file''s pages still make the version; staff see the failure');

-- b20: the same with a failed file (holding only spare pages, say) whose upload row names no booking.
select pg_temp.mk_sub('h20', 'b20', 1);
select pg_temp.mk_upload('u20bad', 'h20', 1);
select pg_temp.mk_upload('u20', 'h20', 2);
update public.script_uploads set booking_id = null where id = pg_temp.k('u20bad');
insert into public.processing_jobs (upload_id, kind) values (pg_temp.k('u20bad'), 'prepare');
insert into res select 'k1', public.processing_job_claim('w', now() + interval '4 days');
select public.processing_job_finish((pg_temp.r('k1') -> 'job' ->> 'id')::bigint, 'w', 1, false, 'unreadable', now() + interval '4 days');
insert into public.processing_jobs (upload_id, kind, run_after) values (pg_temp.k('u20'), 'prepare', now() + interval '4 days');
insert into res select 'k2', public.processing_job_claim('w', now() + interval '4 days');
select public.script_pages_record((pg_temp.r('k2') -> 'job' ->> 'id')::bigint, 'w', 1, pg_temp.h('u20'),
  jsonb_build_array(pg_temp.pg('u20', 0, 'c20', 2), pg_temp.pg('u20', 1, 'c20', 3)), now() + interval '4 days');
select public.processing_job_finish((pg_temp.r('k2') -> 'job' ->> 'id')::bigint, 'w', 1, true, null, now() + interval '4 days');
insert into res select 'k3', public.processing_job_claim('w', now() + interval '4 days 2 minutes');
select public.processing_job_finish((pg_temp.r('k3') -> 'job' ->> 'id')::bigint, 'w', 2, false, 'unreadable', now() + interval '4 days 2 minutes');
insert into res select 'k4', public.processing_job_claim('w', now() + interval '4 days 10 minutes');
select public.processing_job_finish((pg_temp.r('k4') -> 'job' ->> 'id')::bigint, 'w', 3, false, 'unreadable', now() + interval '4 days 10 minutes');
select is((select s.state::text || '/' || x.state::text from public.home_submissions s, public.scripts x
  where s.id = pg_temp.k('h20') and x.booking_id = pg_temp.k('b20')), 'received/needs_attention',
  'a failed file whose upload names no booking still keeps the script out of verified');
select is((select count(*)::int from public.script_exceptions where kind = 'processing_failed' and upload_id = pg_temp.k('u20bad')
  and booking_id = pg_temp.k('b20') and script_id = pg_temp.script('b20')), 1, 'its processing_failed names the submission''s booking and script');

-- ---------------------------------------------------------------------------------------------
-- Invalid page lists are refused and record nothing.
-- ---------------------------------------------------------------------------------------------
select pg_temp.mk_upload('u17b', 'h17', 2);
insert into public.processing_jobs (upload_id, kind) values (pg_temp.k('u17b'), 'prepare');
insert into res select 'inv', public.processing_job_claim('w', now() + interval '1 day');
select is(public.script_pages_record((pg_temp.r('inv') -> 'job' ->> 'id')::bigint, 'w', 1, pg_temp.h('u17b'), '{}'::jsonb, now() + interval '1 day') ->> 'code',
  'invalid_input', 'a page list that is not a list is refused');
select is(public.script_pages_record((pg_temp.r('inv') -> 'job' ->> 'id')::bigint, 'w', 1, pg_temp.h('u17b'),
  jsonb_build_array(pg_temp.pg('u17b', 0, 'c17', 2) || jsonb_build_object('full_path', 'elsewhere/0-full.jpg')), now() + interval '1 day') ->> 'code',
  'invalid_input', 'a picture outside the upload''s folder is refused');
select is(public.script_pages_record((pg_temp.r('inv') -> 'job' ->> 'id')::bigint, 'w', 1, pg_temp.h('u17b'),
  jsonb_build_array(pg_temp.pg('u17b', 0, 'c17', 2), pg_temp.pg('u17b', 0, 'c17', 3)), now() + interval '1 day') ->> 'code',
  'invalid_input', 'two pages at one position are refused');
select is(public.script_pages_record((pg_temp.r('inv') -> 'job' ->> 'id')::bigint, 'w', 1, pg_temp.h('u17b'),
  jsonb_build_array(pg_temp.pg('u17b', 0, 'c17', 2) #- '{quality,flags}'), now() + interval '1 day') ->> 'code',
  'invalid_input', 'a page without its quality flags is refused');
select is((select count(*)::int from public.script_pages where upload_id = pg_temp.k('u17b')), 0, 'nothing was recorded');

select * from finish();
rollback;
