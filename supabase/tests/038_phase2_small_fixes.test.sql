begin;
create extension if not exists pgtap with schema extensions;
select plan(16);
select tests.assert_no_owner();
-- Notices left in a local database by other work are not part of this test: parked inside its transaction, which is
-- rolled back.
delete from public.paper_notices;
delete from public.script_notices;

-- ---------------------------------------------------------------------------------------------
-- Fixtures.
--   Exams rel and cor: published, at-home, a 2-page paper whose roles are not yet reviewed (rel: the first release;
--   cor: version 1 replaced at 09:55 by version 2). Exam e (2031-06-07 10:00 London, 90 minutes): student s1 (home b1)
--   has a script with a received hand-in of 3 pages and a second hand-in as a draft with a stored file; s2 (home b2)
--   has a first draft with a stored file.
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('admin', tests.create_user('admin', 'active')), ('teacher', tests.create_user('teacher', 'active')),
  ('s1', tests.create_user('student', 'active')), ('s2', tests.create_user('student', 'active'));
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
create function pg_temp.t(p text) returns timestamptz language sql immutable as $$ select (p || ' Europe/London')::timestamptz $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.t(text) to public;

insert into public.subjects (name, kind) values ('ZZ Small fixes', 'school');
insert into public.exams (subject_id, title, paper, format, starts_at, duration_minutes, price_pence, price_confirmed, booking_deadline, status)
select s.id, 'ZZF ' || t.n, 'P1', 'both', t.at::timestamptz, 90, 0, true, t.at::timestamptz - interval '1 day', 'published'
from public.subjects s, (values ('rel', '2031-03-01 10:00 Europe/London'), ('cor', '2031-03-01 10:00 Europe/London'),
  ('e', '2031-06-07 10:00 Europe/London')) t(n, at)
where s.name = 'ZZ Small fixes';
insert into kv select substr(e.title, 5), e.id from public.exams e where e.title like 'ZZF %';
-- Every other exam in this database is already announced, so only these fixtures open notices here.
update public.exams set release_notified_at = now() where id not in (select id from kv) and release_notified_at is null;
update public.exam_papers set corrected_notified_at = now()
where superseded_at is not null and corrected_notified_at is null;
insert into public.exam_papers (exam_id, kind, title, version, storage_path, page_count, byte_size)
select pg_temp.k(t.x), 'paper', 'Question paper', t.v, pg_temp.k(t.x)::text || '/' || gen_random_uuid()::text || '.pdf', 2, 1000
from (values ('rel', 1), ('cor', 1)) t(x, v);
insert into kv select 'pv_rel', id from public.exam_papers where exam_id = pg_temp.k('rel');
insert into kv select 'pv_cor1', id from public.exam_papers where exam_id = pg_temp.k('cor');
insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting)
select pg_temp.k(t.x), pg_temp.uid('s1'), pg_temp.uid('s1'), 'paid', 0, 'home' from (values ('rel'), ('cor')) t(x);
insert into public.paper_copies (code, booking_id, paper_id, page_count)
select public.copy_code_new(), b.id, pg_temp.k('pv_cor1'), 4 from public.bookings b where b.exam_id = pg_temp.k('cor');
insert into public.paper_downloads (copy_id, downloaded_by, kind)
select pc.id, pg_temp.uid('s1'), 'home' from public.paper_copies pc where pc.paper_id = pg_temp.k('pv_cor1');
update public.exam_papers set superseded_at = pg_temp.t('2031-03-01 09:55') where id = pg_temp.k('pv_cor1');
insert into public.exam_papers (exam_id, kind, title, version, storage_path, page_count, byte_size)
values (pg_temp.k('cor'), 'paper', 'Question paper', 2, pg_temp.k('cor')::text || '/' || gen_random_uuid()::text || '.pdf', 2, 1000);
insert into kv select 'pv_cor2', id from public.exam_papers where exam_id = pg_temp.k('cor') and superseded_at is null;
-- The corrected notice goes out for the exam that was already released.
update public.exams set release_notified_at = now() where id = pg_temp.k('cor');

-- The notices open (the roles are not checked yet).
select is(public.paper_notice_open(pg_temp.t('2031-03-01 09:56')), 2, 'the release notice and the corrected notice open');

-- Each check below hands out one notice at a time: the other one is excluded, so the answer is about this exam only.
create temp table nid (name text primary key, id bigint not null);
insert into nid select 'rel', id from public.paper_notices where exam_id = pg_temp.k('rel');
insert into nid select 'cor', id from public.paper_notices where exam_id = pg_temp.k('cor');
grant select on nid to public;

-- ----- release_notice_waits_for_page_roles -----
select is((select count(*)::int from public.paper_notice_next(array[(select id from nid where name = 'cor')], pg_temp.t('2031-03-01 09:57')) where exam_id = pg_temp.k('rel')), 0,
  'release_notice_waits_for_page_roles: no release notice is handed out while the paper''s roles are unchecked');
select tests.as_user(pg_temp.uid('admin'));
select is(public.set_paper_page_roles(pg_temp.k('pv_rel'), '[{"page":1,"role":"cover"},{"page":2,"role":"answer"}]'::jsonb) ->> 'ok', 'true',
  'an admin saves the roles');
select tests.as_postgres();
select is((select count(*)::int from public.paper_notice_next(array[(select id from nid where name = 'cor')], pg_temp.t('2031-03-01 09:57')) where exam_id = pg_temp.k('rel')), 1,
  'once the roles are saved, the notice goes out (nothing was dropped)');

-- ----- corrected_notice_waits_for_page_roles -----
select is((select count(*)::int from public.paper_notice_next(array[(select id from nid where name = 'rel')], pg_temp.t('2031-03-01 09:57')) where exam_id = pg_temp.k('cor')), 0,
  'corrected_notice_waits_for_page_roles: nor a corrected notice while the new version''s roles are unchecked');
select tests.as_user(pg_temp.uid('admin'));
select is(public.set_paper_page_roles(pg_temp.k('pv_cor2'), '[{"page":1,"role":"cover"},{"page":2,"role":"answer"}]'::jsonb) ->> 'ok', 'true',
  'and saves the roles of the new version');
select tests.as_postgres();
select is((select kind from public.paper_notice_next(array[(select id from nid where name = 'rel')], pg_temp.t('2031-03-01 09:57')) where exam_id = pg_temp.k('cor')), 'corrected',
  'after the roles are saved it goes out');

-- ----- unsent list -----
insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting)
select pg_temp.k('e'), c.id, c.id, 'paid', 0, 'home' from c where c.name in ('s1', 's2');
insert into kv select 'b' || right(s.name, 1), b.id from public.bookings b join c s on s.id = b.student_id where b.exam_id = pg_temp.k('e');
insert into kv select 'x1', (public.script_create(pg_temp.k('b1'), 'home', '2031-06-07 11:00Z')).id;
insert into public.home_submissions (id, booking_id, seq, state, replaces_all) values
  (gen_random_uuid(), pg_temp.k('b1'), 1, 'received', true),
  (gen_random_uuid(), pg_temp.k('b1'), 2, 'draft', true),
  (gen_random_uuid(), pg_temp.k('b2'), 1, 'draft', true);
insert into kv select 'd1', id from public.home_submissions where booking_id = pg_temp.k('b1') and seq = 1;
insert into kv select 'd2', id from public.home_submissions where booking_id = pg_temp.k('b1') and seq = 2;
insert into kv select 'd3', id from public.home_submissions where booking_id = pg_temp.k('b2') and seq = 1;
insert into public.script_uploads (id, exam_id, booking_id, submission_id, kind, position, storage_path, mime, byte_size, state, uploaded_by, stored_at)
select gen_random_uuid(), pg_temp.k('e'), b.id, pg_temp.k(d.s), 'home_photo', 1, 'home/' || gen_random_uuid()::text || '.jpg',
  'image/jpeg', 1000, d.st::public.upload_state, pg_temp.uid('s1'), now()
from (values ('b1', 'd1', 'processed'), ('b1', 'd2', 'stored'), ('b2', 'd3', 'stored')) d(b, s, st)
join kv b on b.name = d.b;
insert into public.script_pages (upload_id, source_index, exam_id, booking_id, state, full_path)
select u.id, g.i, pg_temp.k('e'), pg_temp.k('b1'), 'matched', 'x/' || g.i || '-full.jpg'
from public.script_uploads u cross join generate_series(1, 3) g(i) where u.submission_id = pg_temp.k('d1');
insert into public.script_page_links (script_id, version, copy_page, page_id)
select pg_temp.k('x1'), s.version, p.source_index, p.id
from public.script_pages p cross join public.scripts s where s.id = pg_temp.k('x1') and p.booking_id = pg_temp.k('b1');

select tests.as_user(pg_temp.uid('admin'));
create temp table res as select public.home_drafts_unsubmitted(pg_temp.k('e'), '2031-06-08 12:00:00Z') as j;
grant select on res to public;
select tests.as_postgres();
select is((select string_agg(concat_ws(':', k.name, x ->> 'replaces_received', x ->> 'replaces_all', x ->> 'received_pages'), ',' order by k.name)
           from res, jsonb_array_elements(res.j -> 'items') x join kv k on k.id = (x ->> 'submission_id')::uuid),
  'd2:true:true:3,d3:false:true:0',
  'unsent_list_says_when_a_draft_replaces_received_pages: the second draft replaces 3 received pages, the first replaces none');

-- ----- family notices skipped -----
delete from public.script_notices;
insert into public.script_notices (kind, script_id, submission_id) values
  ('receipt', pg_temp.k('x1'), pg_temp.k('d1')), ('needs_attention', pg_temp.k('x1'), pg_temp.k('d1'));
insert into public.script_notices (kind, exam_id, exception_kind, dedupe_key)
values ('staff_alert', pg_temp.k('e'), 'late', 'ZZF|late');

select tests.as_user(pg_temp.uid('teacher'));
select is(concat_ws('/', public.script_family_notices_skip('Wrong emails went out') ->> 'code', public.script_family_notices_waiting() ->> 'code'),
  'forbidden/forbidden', 'skip_needs_admin_and_reason: a teacher can neither count nor skip the family emails');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(concat_ws('/', public.script_family_notices_skip(null) ->> 'code', public.script_family_notices_skip('  x ') ->> 'code'),
  'reason_required/reason_required', 'skip_needs_admin_and_reason: a reason of 3 to 300 characters is needed');
select is((select concat_ws('/', w ->> 'count', w ->> 'oldest' is not null) from (select public.script_family_notices_waiting() w) q),
  '2/t', 'two family emails wait (the staff alert is not counted)');
create temp table sk as select public.script_family_notices_skip('Wrong emails went out on 21 November') as j;
grant select on sk to public;
select tests.as_postgres();
select is(concat_ws('/', (select j ->> 'ok' from sk), (select j ->> 'skipped' from sk),
    (select count(*)::int from public.audit_log where action = 'script_family_notices_skipped' and reason = 'Wrong emails went out on 21 November')),
  'true/2/1', 'the family emails are skipped, and the audit log keeps the reason');
select is((select count(*)::int from public.script_notices where kind = 'staff_alert' and skipped_at is not null), 0,
  'staff_alerts_are_not_skipped');

-- ----- skipped_family_notice_is_never_claimed -----
-- A new family notice that is not skipped is handed out in the same call, so the call does reach the table.
insert into public.script_notices (kind, script_id, submission_id) values ('rejected', pg_temp.k('x1'), pg_temp.k('d2'));
create temp table claimed as select public.script_notice_next(10, now()) as j;
select is(concat_ws('/', (select count(*)::int from public.script_notices where skipped_at is not null and (claimed_at is not null or attempts > 0)),
    (select count(*)::int from public.script_notices where kind = 'rejected' and claimed_at is not null)),
  '0/1', 'skipped_family_notice_is_never_claimed: the skipped ones stay untouched while a new one is claimed');
select is(public.script_notice_given_up(now() + interval '7 days 1 hour'), 1, 'and only the one that was not skipped counts as given up after 7 days');

-- ----- record_takes_exactly_5000_pages -----
select is(concat_ws('/',
    public.script_pages_valid((select jsonb_agg(jsonb_build_object('source_index', i, 'code', null, 'copy_page', null, 'blank', false,
       'quality', jsonb_build_object('sharpness', 1, 'brightness', 1, 'cut_off', false, 'flags', '[]'::jsonb), 'rotation', 0,
       'full_path', 'x/' || i || '-full.jpg', 'marking_path', null)) from generate_series(0, 4999) i), 'x/'),
    public.script_pages_valid((select jsonb_agg(jsonb_build_object('source_index', i, 'code', null, 'copy_page', null, 'blank', false,
       'quality', jsonb_build_object('sharpness', 1, 'brightness', 1, 'cut_off', false, 'flags', '[]'::jsonb), 'rotation', 0,
       'full_path', 'x/' || i || '-full.jpg', 'marking_path', null)) from generate_series(0, 5000) i), 'x/')),
  't/f', 'record_takes_exactly_5000_pages: 5,000 pages are valid, 5,001 are not');

select * from finish();
rollback;
