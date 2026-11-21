begin;
create extension if not exists pgtap with schema extensions;
select plan(9);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- A timing guard (Ruling R40, I1). Everything happens in this one transaction, so the planner's statistics are those
-- of the tables before it: the script tables as they were last analysed (empty on a fresh database), never the rows
-- inserted here. Before 20261120000072, in that state, script_pages_record took 164 s for 100 candidates x 20 pages
-- and scan_centre_complete 146 s.
--   Exam e, centre ce: 100 candidates, a 20-page paper (page 1 the cover), one scan file of 2000 pages.
--   Exam f, centre cf: 300 candidates, a 5-page paper, one scan file of 1500 pages.
-- Each timed call runs under the statement_timeout it must meet (a call over it fails this file).
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('admin', tests.create_user('admin', 'active'));
insert into c select 's' || i, tests.create_user('student', 'active') from generate_series(1, 300) i;
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create temp table res (name text primary key, j jsonb, ms numeric);
grant all on res to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
create function pg_temp.r(p text) returns jsonb language sql stable as $$ select j from res where name = p $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.r(text) to public;

insert into public.subjects (name, kind) values ('ZZ Script scale', 'school');
insert into public.venues (name, rooms) values ('ZZ Scale hall', array['R1']);
insert into public.exams (subject_id, title, paper, format, starts_at, duration_minutes, price_pence, price_confirmed, booking_deadline, status)
select s.id, 'ZZScale ' || t.n, 'P1', 'both', t.at::timestamptz, 90, 0, true, t.at::timestamptz - interval '1 day', 'published'
from public.subjects s, (values ('e', '2031-08-07 10:00 Europe/London'), ('f', '2031-08-08 10:00 Europe/London')) t(n, at)
where s.name = 'ZZ Script scale';
insert into kv select substr(e.title, 9), e.id from public.exams e join public.subjects s on s.id = e.subject_id where s.name = 'ZZ Script scale';
insert into public.exam_centres (exam_id, venue_id, room, seat_limit)
select pg_temp.k(t.x), v.id, 'R1', 1000 from public.venues v, (values ('e'), ('f')) t(x) where v.name = 'ZZ Scale hall';
insert into kv select 'c' || t.x, ec.id from public.exam_centres ec join (values ('e'), ('f')) t(x) on ec.exam_id = pg_temp.k(t.x);
insert into public.exam_papers (exam_id, kind, title, version, storage_path, page_count, byte_size)
select pg_temp.k(t.x), 'paper', 'Question paper', 1, pg_temp.k(t.x)::text || '/' || gen_random_uuid()::text || '.pdf', t.n, 1000
from (values ('e', 20), ('f', 5)) t(x, n);
insert into kv select 'pv' || t.x, p.id from public.exam_papers p join (values ('e'), ('f')) t(x) on p.exam_id = pg_temp.k(t.x);
update public.paper_page_roles set role = (case page when 1 then 'cover' else 'answer' end)::public.page_role
where paper_id in (pg_temp.k('pve'), pg_temp.k('pvf'));
insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting, centre_id)
select pg_temp.k('e'), c.id, c.id, 'paid', 0, 'centre', pg_temp.k('ce') from c where c.name ~ '^s[0-9]+$' and substr(c.name, 2)::int <= 100;
insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting, centre_id)
select pg_temp.k('f'), c.id, c.id, 'paid', 0, 'centre', pg_temp.k('cf') from c where c.name ~ '^s[0-9]+$';
insert into public.paper_copies (code, booking_id, paper_id, page_count)
select public.copy_code_new(), b.id, p.id, p.page_count
from public.bookings b join public.exam_papers p on p.exam_id = b.exam_id where b.exam_id in (pg_temp.k('e'), pg_temp.k('f'));
insert into public.attendance (exam_id, student_id, status, marked_by, marked_at)
select b.exam_id, b.student_id, 'present', pg_temp.uid('admin'), '2031-08-07 09:00Z'
from public.bookings b where b.exam_id in (pg_temp.k('e'), pg_temp.k('f'));

-- Jobs left in a local database by other work are not part of this test.
update public.processing_jobs set state = 'done' where state in ('queued', 'running');

-- A scan batch with one stored file, submitted (as the admin); then the processing server's claim and its page list:
-- every page of every copy of the exam, in order, each answer page with a marking picture.
create function pg_temp.scan(p_exam text) returns void language plpgsql as $$
declare
  v_batch uuid;
  v_begin jsonb;
  v_claim jsonb;
  v_dir text;
begin
  perform tests.as_user(pg_temp.uid('admin'));
  v_batch := (public.scan_batch_create(pg_temp.k(p_exam), pg_temp.k('c' || p_exam), null) ->> 'batch_id')::uuid;
  v_begin := public.scan_upload_begin(v_batch, 'application/pdf', 5000000);
  perform tests.as_postgres();
  insert into storage.objects (bucket_id, name, metadata)
  values ('script-uploads', v_begin ->> 'storage_path', jsonb_build_object('size', 5000000, 'mimetype', 'application/pdf'));
  perform tests.as_user(pg_temp.uid('admin'));
  perform public.script_upload_stored((v_begin ->> 'upload_id')::uuid);
  perform public.scan_batch_submit(v_batch);
  perform tests.as_postgres();
  v_claim := public.processing_job_claim('t-worker');
  if v_claim is null or v_claim -> 'upload' ->> 'id' <> v_begin ->> 'upload_id' then
    raise exception 'claimed another job';
  end if;
  v_dir := pg_temp.k(p_exam)::text || '/' || (v_begin ->> 'upload_id') || '/' || (v_claim -> 'job' ->> 'id') || '-' || (v_claim -> 'job' ->> 'attempts') || '/';
  insert into res (name, j) values ('claim_' || p_exam, v_claim -> 'job');
  insert into res (name, j)
  select 'pages_' || p_exam, jsonb_agg(jsonb_build_object('source_index', t.idx, 'code', t.code, 'copy_page', t.pg, 'blank', false,
      'quality', jsonb_build_object('sharpness', 200, 'brightness', 180, 'cut_off', false, 'flags', '[]'::jsonb), 'rotation', 0,
      'full_path', v_dir || t.idx || '-full.jpg',
      'marking_path', case when t.pg > 1 then v_dir || t.idx || '-marking.jpg' end) order by t.idx)
  from (select (row_number() over (order by pc.code, g.pg) - 1)::int as idx, pc.code, g.pg
        from public.paper_copies pc cross join lateral generate_series(1, pc.page_count) g(pg)
        where pc.paper_id = pg_temp.k('pv' || p_exam)) t;
end;
$$;
create function pg_temp.record(p_exam text) returns jsonb language plpgsql as $$
declare
  v_t0 timestamptz := clock_timestamp();
  v_r jsonb;
begin
  v_r := public.script_pages_record((pg_temp.r('claim_' || p_exam) ->> 'id')::bigint, 't-worker', (pg_temp.r('claim_' || p_exam) ->> 'attempts')::int,
    repeat('a', 64), pg_temp.r('pages_' || p_exam));
  insert into res values ('record_' || p_exam, v_r, extract(epoch from clock_timestamp() - v_t0) * 1000);
  perform public.processing_job_finish((pg_temp.r('claim_' || p_exam) ->> 'id')::bigint, 't-worker', (pg_temp.r('claim_' || p_exam) ->> 'attempts')::int, true);
  return v_r;
end;
$$;
create function pg_temp.complete(p_exam text) returns jsonb language plpgsql as $$
declare
  v_t0 timestamptz := clock_timestamp();
  v_r jsonb;
begin
  v_r := public.scan_centre_complete(pg_temp.k(p_exam), pg_temp.k('c' || p_exam));
  insert into res values ('complete_' || p_exam, v_r, extract(epoch from clock_timestamp() - v_t0) * 1000);
  return v_r;
end;
$$;
grant execute on function pg_temp.complete(text) to public;

-- ---------------------------------------------------------------------------------------------
-- record_2000_pages_in_time
-- ---------------------------------------------------------------------------------------------
select pg_temp.scan('e');
select is(jsonb_array_length(pg_temp.r('pages_e')), 2000, 'one scan file of 100 candidates x 20 pages: 2000 pages');
set local statement_timeout = '30s';
select is(pg_temp.record('e') - 'exceptions', '{"ok": true, "pages": 2000, "matched": 2000}'::jsonb,
  'script_pages_record takes a 2000-page file within 30 s');
reset statement_timeout;
select cmp_ok((select ms from res where name = 'record_e'), '<', 30000::numeric, 'measured: under 30 s');
select is((select concat_ws('/', count(*), count(*) filter (where s.version = 1),
                            (select count(*) from public.script_page_links l join public.scripts x on x.id = l.script_id and x.version = l.version
                             where x.exam_id = pg_temp.k('e')))
           from public.scripts s where s.exam_id = pg_temp.k('e')), '100/100/2000',
  'every candidate has a script of one version showing its 20 pages');
select is((select count(*)::int from public.script_exceptions where exam_id = pg_temp.k('e')), 0, 'and nothing is raised');

-- ---------------------------------------------------------------------------------------------
-- centre_complete_300_candidates_in_time
-- ---------------------------------------------------------------------------------------------
select pg_temp.scan('f');
set local statement_timeout = '30s';
select is(pg_temp.record('f') - 'exceptions', '{"ok": true, "pages": 1500, "matched": 1500}'::jsonb, 'a centre of 300 candidates is scanned (1500 pages)');
reset statement_timeout;
select tests.as_user(pg_temp.uid('admin'));
set local statement_timeout = '5s';
select is(pg_temp.complete('f'), '{"ok": true, "candidates": 300, "complete": 300, "missing": 0, "mixed": 0}'::jsonb,
  '"All scans for this centre are uploaded" checks 300 candidates within 5 s');
reset statement_timeout;
select tests.as_postgres();
select cmp_ok((select ms from res where name = 'complete_f'), '<', 5000::numeric, 'measured: under 5 s');
select is((select count(*)::int from public.scripts where exam_id = pg_temp.k('f') and state = 'verified' and complete), 300,
  'and every script is complete and verified');

select * from finish();
rollback;
