begin;
create extension if not exists pgtap with schema extensions;
select plan(28);
select tests.assert_no_owner();
-- Notices left in a local database by other work are not part of this test: parked inside its transaction, which is
-- rolled back.
delete from public.script_notices;

-- ---------------------------------------------------------------------------------------------
-- Phase 4A, Task 4: sign-off and publishing, the minute job and the results email.
-- Fixtures (tests.results_exam; the paper's maximum is 24; a candidate is kept as '<exam>:<n>' in the order the fixture
-- made them, home candidates first):
--   p: results_exam(5, 5): home 24, 20, 16, 12, 8 and centre 23, 19, 15, 11, 7; grade A from 20. Published at once,
--      corrected after publication, withdrawn, given A from 21 and published again.
--   c: results_exam(2, 1): changed after the check (a status, a boundary, a new preparation).
--   k: results_exam(3, 1) and k_none (a paid home booking with no script): bookings cancelled after the check.
--   m: results_exam(2, 1): the approval withdrawn, a final mark changed and the marking approved again.
--   a: results_exam(2, 1): the approval withdrawn, then stale.   n: results_exam(1, 0), never prepared.
--   w: results_exam(1, 0): the 30-day window.   x: results_exam(1, 0): a scheduled publication cancelled.
--   f1, f2, f3: results_exam(1, 1) each: scheduled, then the approval withdrawn, stale, or a booking cancelled.
--   d: results_exam(2, 1): a publication at the hour UK clocks go back (2027-10-31 01:00 UTC).
--   big: the timing guard's exam, at the end.
-- People: an admin, the subject's lead marker, a teacher, a corrector, p:1's student, their parent (linked before the
-- publication, suspended after it) and a second parent (linked after it).
-- Exams are scheduled one test at a time, so each minute job (results_tick) below meets only the exam under test.
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create temp table res (name text primary key, j jsonb);
grant all on res to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
create function pg_temp.r(p text) returns jsonb language sql stable as $$ select j from res where name = p $$;
create function pg_temp.code(j jsonb) returns text language sql immutable as $$
  select case when (j ->> 'ok')::boolean then 'ok' else coalesce(j ->> 'code', 'none') end $$;
create function pg_temp.keys(j jsonb) returns text language sql immutable as $$
  select array_to_string(array(select k from jsonb_object_keys(j) k order by 1), ',') $$;
-- The candidates tests.results_exam made, as '<exam>:1', '<exam>:2', ... (their scripts' numbers give the order).
create function pg_temp.cands(p_exam text) returns void language sql as $$
  insert into kv select p_exam || ':' || row_number() over (order by s.number), s.booking_id
  from public.scripts s where s.exam_id = pg_temp.k(p_exam) $$;
create function pg_temp.ns(p_exam text, p_from int, p_to int) returns text[] language sql immutable as $$
  select array(select p_exam || ':' || i from generate_series(p_from, p_to) i) $$;
-- A field of a candidate's result row as text ('null' when null, 'no row' when there is none), and of several.
create function pg_temp.f(p text, p_field text) returns text language sql stable as $$
  select coalesce((select coalesce(to_jsonb(r) ->> p_field, 'null') from public.results r where r.booking_id = pg_temp.k(p)),
    'no row') $$;
create function pg_temp.fs(p_names text[], p_field text) returns text[] language sql stable as $$
  select array(select pg_temp.f(n, p_field) from unnest(p_names) with ordinality u(n, o) order by o) $$;
create function pg_temp.q(p_exam text, p_label text) returns uuid language sql stable as $$
  select q.id from public.exam_questions q left join public.exam_questions p on p.id = q.parent_id
  where q.exam_id = pg_temp.k(p_exam) and coalesce(p.label || '(' || q.label || ')', q.label) = p_label $$;
create function pg_temp.unit(p text) returns uuid language sql stable as $$
  select u.id from public.marking_units u join public.scripts s on s.id = u.script_id where s.booking_id = pg_temp.k(p) $$;
-- The exam's results row, as postgres.
create function pg_temp.er(p_exam text, p_field text) returns text language sql stable as $$
  select coalesce((select coalesce(to_jsonb(x) ->> p_field, 'null') from public.exam_results x where x.exam_id = pg_temp.k(p_exam)),
    'no row') $$;
create function pg_temp.ver(p_exam text) returns int language sql stable as $$
  select coalesce((select x.version from public.exam_results x where x.exam_id = pg_temp.k(p_exam)), 0) $$;
create function pg_temp.audits(p_action text, p_target uuid) returns int language sql stable as $$
  select count(*)::int from public.audit_log a where a.action = p_action and a.target_id = p_target $$;
create function pg_temp.reason(p_action text, p_target uuid) returns text language sql stable as $$
  select coalesce(a.reason, 'none') from public.audit_log a where a.action = p_action and a.target_id = p_target
  order by a.id desc limit 1 $$;
-- The exam's results emails; a candidate's published versions ('1 null,2 <reason>'); the exam's published versions.
create function pg_temp.notices(p_exam text) returns int language sql stable as $$
  select count(*)::int from public.script_notices n where n.kind = 'results_published' and n.exam_id = pg_temp.k(p_exam) $$;
create function pg_temp.vers(p text) returns text language sql stable as $$
  select coalesce(string_agg(v.version || ' ' || coalesce(v.reason, 'null'), ',' order by v.version), '')
  from public.result_versions v join public.results r on r.id = v.result_id where r.booking_id = pg_temp.k(p) $$;
create function pg_temp.exam_vers(p_exam text) returns int language sql stable as $$
  select count(*)::int from public.result_versions v join public.results r on r.id = v.result_id where r.exam_id = pg_temp.k(p_exam) $$;
create function pg_temp.stale(p_exam text) returns boolean language sql stable as $$
  select jsonb_array_length(public.marking_approval_blocks(pg_temp.k(p_exam))) > 0 $$;
-- A paid home booking of a new active student, with no script.
create function pg_temp.booking(p_name text, p_exam text) returns void language plpgsql as $$
declare
  v_student uuid := tests.create_user('student', 'active');
  v_b uuid;
begin
  insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting)
  values (pg_temp.k(p_exam), v_student, v_student, 'paid', 0, 'home') returning id into v_b;
  insert into kv values (p_name, v_b);
end $$;
-- The marking approved again (as tests.results_exam approves it).
create function pg_temp.reapprove(p_exam text) returns void language sql as $$
  update public.exam_marking set approved_at = now(), approved_by = pg_temp.uid('admin') where exam_id = pg_temp.k(p_exam) $$;
-- The minute job at a given time, as postgres (as pg_cron runs it).
create function pg_temp.tick(p_now timestamptz) returns void language sql as $$ select public.results_tick(p_now) $$;
-- Signed in as someone: a call's answer (p_sql is run as that user).
create function pg_temp.as(p_who text, p_sql text) returns jsonb language plpgsql as $$
declare
  v_r jsonb;
begin
  perform tests.as_user(pg_temp.uid(p_who));
  execute p_sql into v_r;
  perform tests.as_postgres();
  return v_r;
end $$;
create function pg_temp.prep(p_who text, p_exam text) returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.results_prepare(%L)', pg_temp.k(p_exam))) $$;
create function pg_temp.get(p_who text, p_exam text) returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.results_get(%L)', pg_temp.k(p_exam))) $$;
create function pg_temp.st(p_who text, p text, p_status text, p_reason text) returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.result_status_set(%L, %L, %L)', pg_temp.k(p), p_status, p_reason)) $$;
create function pg_temp.bset(p_who text, p_exam text, p_grades text, p_reason text default null) returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.grade_boundaries_set(%L, %L::jsonb, %L)', pg_temp.k(p_exam), p_grades, p_reason)) $$;
create function pg_temp.pub(p_who text, p_exam text, p_version int, p_at timestamptz default null, p_now timestamptz default null)
returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.results_publish(%L, %L, %L, %L)', pg_temp.k(p_exam), p_version, p_at, p_now)) $$;
-- Published with the version the results are at (the totals the admin checked are the current ones).
create function pg_temp.pubv(p_who text, p_exam text, p_at timestamptz default null, p_now timestamptz default null)
returns jsonb language sql as $$ select pg_temp.pub(p_who, p_exam, pg_temp.ver(p_exam), p_at, p_now) $$;
create function pg_temp.cancel(p_who text, p_exam text) returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.results_publish_cancel(%L)', pg_temp.k(p_exam))) $$;
create function pg_temp.wdr(p_who text, p_exam text, p_reason text) returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.results_withdraw(%L, %L)', pg_temp.k(p_exam), p_reason)) $$;
create function pg_temp.awd(p_who text, p_exam text, p_reason text) returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.marking_approval_withdraw(%L, %L)', pg_temp.k(p_exam), p_reason)) $$;

insert into c values ('admin', tests.create_user('admin', 'active')), ('teacher', tests.create_user('teacher', 'active')),
  ('corrector', tests.create_user('corrector', 'active')), ('parent', tests.create_user('parent', 'active')),
  ('parent2', tests.create_user('parent', 'active')), ('lead', tests.marker(1, true));

insert into kv values ('p', tests.results_exam(5, 5, array[24, 20, 16, 12, 8, 23, 19, 15, 11, 7]));
select pg_temp.cands('p');
insert into c select 'student', b.student_id from public.bookings b where b.id = pg_temp.k('p:1');
insert into public.parent_children (parent_id, student_id) values (pg_temp.uid('parent'), pg_temp.uid('student'));
insert into kv values ('c', tests.results_exam(2, 1));
select pg_temp.cands('c');
insert into kv values ('k', tests.results_exam(3, 1));
select pg_temp.cands('k');
select pg_temp.booking('k_none', 'k');
insert into kv values ('m', tests.results_exam(2, 1));
select pg_temp.cands('m');
insert into kv values ('a', tests.results_exam(2, 1));
insert into kv values ('n', tests.results_exam(1, 0));
insert into kv values ('w', tests.results_exam(1, 0));
insert into kv values ('x', tests.results_exam(1, 0));
select pg_temp.cands('x');
insert into kv values ('f1', tests.results_exam(1, 1));
insert into kv values ('f2', tests.results_exam(1, 1));
insert into kv values ('f3', tests.results_exam(1, 1));
select pg_temp.cands('f3');
insert into kv values ('d', tests.results_exam(2, 1));
select pg_temp.cands('d');

-- ---------------------------------------------------------------------------------------------
-- publish_now_shows_results_and_queues_one_email_per_candidate
-- ---------------------------------------------------------------------------------------------
insert into res values ('p_prep', pg_temp.prep('admin', 'p'));
insert into res values ('p_bset', pg_temp.bset('admin', 'p', '[{"grade": "A", "min_mark": 20}]', 'First boundaries.'));
insert into res values ('p_pub', pg_temp.pubv('admin', 'p'));
select is(array[pg_temp.code(pg_temp.r('p_pub')), pg_temp.keys(pg_temp.r('p_pub')), pg_temp.r('p_pub') ->> 'state',
    coalesce(pg_temp.r('p_pub') ->> 'publish_at', 'null'), pg_temp.er('p', 'state'),
    (pg_temp.er('p', 'published_at')::timestamptz = now())::text, (pg_temp.er('p', 'first_published_at')::timestamptz = now())::text,
    (pg_temp.er('p', 'published_by') = pg_temp.uid('admin')::text)::text, pg_temp.er('p', 'publish_at'), pg_temp.er('p', 'version'),
    pg_temp.audits('results_published', pg_temp.k('p'))::text,
    (select (actor_id = pg_temp.uid('admin'))::text from public.audit_log where action = 'results_published' and target_id = pg_temp.k('p')),
    pg_temp.get('admin', 'p') ->> 'state'],
  array['ok', 'ok,publish_at,state', 'published', 'null', 'published', 'true', 'true', 'true', 'null', '2', '1', 'true', 'published'],
  'publish_now_shows_results_and_queues_one_email_per_candidate: signed off and published at once by the admin, and audited');
select is(array[pg_temp.notices('p')::text,
    (select count(distinct n.booking_id)::text from public.script_notices n where n.kind = 'results_published' and n.exam_id = pg_temp.k('p')),
    (select count(*)::text from public.script_notices n join public.results r on r.booking_id = n.booking_id
     where n.kind = 'results_published' and r.exam_id = pg_temp.k('p')),
    (select count(*)::text from public.script_notices n where n.kind = 'results_published' and n.exam_id = pg_temp.k('p')
       and (n.submission_id is not null or n.script_id is not null or n.sent_at is not null)),
    (select count(*)::text from public.results where exam_id = pg_temp.k('p'))],
  array['10', '10', '10', '0', '10'],
  'publish_now_shows_results_and_queues_one_email_per_candidate: one results_published notice per candidate booking, about the '
  || 'booking and the exam only, waiting to be sent');

-- Who it goes to is worked out when it is sent: a parent linked since is told, one suspended since is not.
insert into public.parent_children (parent_id, student_id) values (pg_temp.uid('parent2'), pg_temp.uid('student'));
update public.profiles set status = 'suspended' where id = pg_temp.uid('parent');
create temp table p1n as select n.id from public.script_notices n where n.kind = 'results_published' and n.booking_id = pg_temp.k('p:1');
select is(array[
    (select string_agg(x ->> 'profile_id', ',' order by x ->> 'profile_id') from public.script_notices n
       cross join jsonb_array_elements(public.script_notice_recipients(n)) x where n.id = (select id from p1n)),
    (select public.script_notice_content(n) ->> 'exam' from public.script_notices n where n.id = (select id from p1n)),
    (select pg_temp.keys(public.script_notice_content(n)) from public.script_notices n where n.id = (select id from p1n)),
    (select coalesce(public.script_notice_content(n) ->> 'script_number', 'null') from public.script_notices n where n.id = (select id from p1n)),
    (select string_agg((x ->> 'kind') || ' ' || jsonb_array_length(x -> 'recipients'), ',')
       from jsonb_array_elements(public.script_notice_next(1000, now())) x where (x ->> 'id')::bigint = (select id from p1n))],
  array[(select string_agg(id::text, ',' order by id::text) from c where name in ('student', 'parent2')), 'ZZ Marking exam Paper 1',
    'alert_kind,at,count,exam,exception_kind,page_count,pages,script_number,submission_seq', 'null', 'results_published 2'],
  'publish_now_shows_results_and_queues_one_email_per_candidate: the email goes to the student and the parents linked when it '
  || 'is sent (not one suspended since); it names the exam and nothing of the result, and the send cycle hands it out');

-- ---------------------------------------------------------------------------------------------
-- first_publication_is_version_one_and_unchanged_rows_keep_their_version (the first publication)
-- ---------------------------------------------------------------------------------------------
select is(array[array_to_string(pg_temp.fs(pg_temp.ns('p', 1, 10), 'version'), ','), pg_temp.exam_vers('p')::text,
    (select count(*)::text from public.result_versions v join public.results r on r.id = v.result_id
     where r.exam_id = pg_temp.k('p') and v.version = 1 and v.reason is null and v.published_at = now() and v.made_by = pg_temp.uid('admin')),
    (select pg_temp.keys(v.snapshot) from public.result_versions v join public.results r on r.id = v.result_id where r.booking_id = pg_temp.k('p:1')),
    (select concat_ws(' ', v.snapshot ->> 'status', v.snapshot ->> 'total', v.snapshot ->> 'grade', v.snapshot ->> 'rank',
              v.snapshot ->> 'rank_cohort', v.snapshot ->> 'percentage', v.snapshot ->> 'sitting')
       from public.result_versions v join public.results r on r.id = v.result_id where r.booking_id = pg_temp.k('p:2'))],
  array['1,1,1,1,1,1,1,1,1,1', '10', '10',
    'grade,max_total,percentage,question_marks,rank,rank_cohort,remarked,sitting,status,total', 'present 20.0 A 2 5 83.3 home'],
  'first_publication_is_version_one_and_unchanged_rows_keep_their_version: the first publication makes every row version 1, '
  || 'kept with what the family sees and no reason');

-- ---------------------------------------------------------------------------------------------
-- correction_after_publication_changes_that_row_only (Ruling R1)
-- ---------------------------------------------------------------------------------------------
create temp table p_before as select x.cohort from public.exam_results x where x.exam_id = pg_temp.k('p');
insert into res values ('p_dq', pg_temp.st('admin', 'p:3', 'disqualified', 'Notes found after publication.'));
select is(array[pg_temp.code(pg_temp.r('p_dq')), pg_temp.r('p_dq') ->> 'status', pg_temp.r('p_dq') ->> 'version',
    pg_temp.r('p_dq') ->> 'result_version', pg_temp.f('p:3', 'status'), pg_temp.f('p:3', 'total'), pg_temp.f('p:3', 'grade'),
    pg_temp.f('p:3', 'rank'), pg_temp.f('p:3', 'rank_cohort'),
    array_to_string(pg_temp.fs(pg_temp.ns('p', 1, 10), 'rank'), ','), array_to_string(pg_temp.fs(pg_temp.ns('p', 1, 10), 'rank_cohort'), ','),
    array_to_string(pg_temp.fs(pg_temp.ns('p', 1, 10), 'version'), ','), pg_temp.vers('p:3'),
    ((select cohort from p_before) = pg_temp.er('p', 'cohort')::jsonb)::text, pg_temp.er('p', 'version'), pg_temp.er('p', 'state'),
    pg_temp.notices('p')::text, pg_temp.reason('result_status_set', pg_temp.k('p:3'))],
  array['ok', 'disqualified', '2', '2', 'disqualified', 'null', 'null', 'null', 'null',
    '1,2,null,4,5,1,2,3,4,5', '5,5,null,5,5,5,5,5,5,5', '1,1,2,1,1,1,1,1,1,1',
    '1 null,2 disqualified: Notes found after publication.', 'true', '2', 'published', '10',
    'disqualified: Notes found after publication.'],
  'correction_after_publication_changes_that_row_only: a status set after publication rewrites that candidate''s row and '
  || 'records it at once as a new published version; no other rank, no cohort figure and no version of the exam moves; no email');
insert into res values ('p_auto', pg_temp.st('admin', 'p:3', 'auto', 'Disqualified by mistake.'));
select is(array[pg_temp.code(pg_temp.r('p_auto')), pg_temp.f('p:3', 'status'), pg_temp.f('p:3', 'total'), pg_temp.f('p:3', 'rank'),
    pg_temp.f('p:3', 'rank_cohort'), pg_temp.f('p:3', 'grade'), pg_temp.vers('p:3'),
    array_to_string(pg_temp.fs(pg_temp.ns('p', 1, 10), 'version'), ','), pg_temp.notices('p')::text],
  array['ok', 'present', '16.0', '3', '5', 'U', '1 null,2 disqualified: Notes found after publication.,3 auto: Disqualified by mistake.',
    '1,1,3,1,1,1,1,1,1,1', '10'],
  'correction_after_publication_changes_that_row_only: auto after publication works the row out again, ranked among the '
  || 'others'' current totals in its mode, as version 3');

-- ---------------------------------------------------------------------------------------------
-- withdrawn_results_can_be_republished_without_email
-- ---------------------------------------------------------------------------------------------
insert into res values ('p_wd_short', pg_temp.wdr('admin', 'p', 'no'));
insert into res values ('p_wd', pg_temp.wdr('admin', 'p', 'A boundary was wrong.'));
insert into res values ('p_pub_wd', pg_temp.pubv('admin', 'p'));
insert into res values ('p_wd_again', pg_temp.wdr('admin', 'p', 'Again.'));
select is(array[pg_temp.code(pg_temp.r('p_wd_short')), pg_temp.code(pg_temp.r('p_wd')), pg_temp.r('p_wd') ->> 'state',
    pg_temp.r('p_wd') ->> 'already', pg_temp.code(pg_temp.r('p_pub_wd')), pg_temp.code(pg_temp.r('p_wd_again')),
    pg_temp.r('p_wd_again') ->> 'already', pg_temp.er('p', 'state'), pg_temp.er('p', 'withdraw_reason'),
    (pg_temp.er('p', 'withdrawn_by') = pg_temp.uid('admin')::text)::text, pg_temp.audits('results_withdrawn', pg_temp.k('p'))::text,
    pg_temp.reason('results_withdrawn', pg_temp.k('p'))],
  array['reason_required', 'ok', 'withdrawn', 'false', 'not_prepared', 'ok', 'true', 'withdrawn', 'A boundary was wrong.', 'true', '1',
    'A boundary was wrong.'],
  'withdrawn_results_can_be_republished_without_email: withdrawing needs a reason and is audited; withdrawn results are '
  || 'prepared again before they publish; withdrawing twice changes nothing');
insert into res values ('p_bset2', pg_temp.bset('admin', 'p', '[{"grade": "A", "min_mark": 21}]', 'A from 21.'));
insert into res values ('p_prep2', pg_temp.prep('admin', 'p'));
insert into res values ('p_pub2', pg_temp.pubv('admin', 'p', null, now() + interval '1 day'));
select is(array[pg_temp.code(pg_temp.r('p_bset2')), pg_temp.code(pg_temp.r('p_prep2')), pg_temp.code(pg_temp.r('p_pub2')),
    pg_temp.er('p', 'state'), (pg_temp.er('p', 'published_at')::timestamptz = now() + interval '1 day')::text,
    (pg_temp.er('p', 'first_published_at')::timestamptz = now())::text, pg_temp.notices('p')::text,
    pg_temp.audits('results_published', pg_temp.k('p'))::text],
  array['ok', 'ok', 'ok', 'published', 'true', 'true', '10', '2'],
  'withdrawn_results_can_be_republished_without_email: prepared and published again a day later; the first publication''s '
  || 'date stays and no email is queued');
select is(array[array_to_string(pg_temp.fs(pg_temp.ns('p', 1, 10), 'version'), ','), pg_temp.vers('p:2'), pg_temp.f('p:2', 'grade'),
    pg_temp.exam_vers('p')::text,
    (select (v.published_at = now() + interval '1 day')::text from public.result_versions v join public.results r on r.id = v.result_id
     where r.booking_id = pg_temp.k('p:2') and v.version = 2)],
  array['1,2,3,1,1,1,1,1,1,1', '1 null,2 Published again: A boundary was wrong.', 'U', '13', 'true'],
  'first_publication_is_version_one_and_unchanged_rows_keep_their_version: published again, only the row that changed (20 '
  || 'marks, now below A) gets a new version; every other row keeps its version');

-- ---------------------------------------------------------------------------------------------
-- one_results_email_per_candidate
-- ---------------------------------------------------------------------------------------------
select throws_ok(format($$insert into public.script_notices (kind, booking_id, exam_id) values ('results_published', %L, %L)$$,
    pg_temp.k('p:1'), pg_temp.k('p')), '23505', null,
  'one_results_email_per_candidate: the database refuses a second results notice for a booking');
select is(array[pg_temp.notices('p')::text,
    (select count(distinct n.booking_id)::text from public.script_notices n where n.kind = 'results_published' and n.exam_id = pg_temp.k('p'))],
  array['10', '10'],
  'one_results_email_per_candidate: published, withdrawn and published again: still one notice per booking');

-- ---------------------------------------------------------------------------------------------
-- publish_refused_when_results_changed_since_checked
-- ---------------------------------------------------------------------------------------------
insert into res values ('c_prep', pg_temp.prep('admin', 'c'));
insert into res values ('c_v1', to_jsonb(pg_temp.ver('c')));
insert into res values ('c_st', pg_temp.st('admin', 'c:2', 'absent', 'Left before the start.'));
insert into res values ('c_pub1', pg_temp.pub('admin', 'c', (pg_temp.r('c_v1') #>> '{}')::int));
insert into res values ('c_v2', to_jsonb(pg_temp.ver('c')));
insert into res values ('c_bset', pg_temp.bset('admin', 'c', '[{"grade": "A", "min_mark": 20}]'));
insert into res values ('c_pub2', pg_temp.pub('admin', 'c', (pg_temp.r('c_v2') #>> '{}')::int));
insert into res values ('c_v3', to_jsonb(pg_temp.ver('c')));
insert into res values ('c_prep2', pg_temp.prep('admin', 'c'));
insert into res values ('c_pub3', pg_temp.pub('admin', 'c', (pg_temp.r('c_v3') #>> '{}')::int));
select is(array[pg_temp.code(pg_temp.r('c_pub1')), pg_temp.code(pg_temp.r('c_pub2')), pg_temp.code(pg_temp.r('c_pub3')),
    pg_temp.r('c_v1') #>> '{}', pg_temp.r('c_v2') #>> '{}', pg_temp.r('c_v3') #>> '{}', pg_temp.er('c', 'version'), pg_temp.er('c', 'state'),
    pg_temp.notices('c')::text, pg_temp.exam_vers('c')::text, pg_temp.audits('results_published', pg_temp.k('c'))::text],
  array['results_changed', 'results_changed', 'results_changed', '1', '2', '3', '4', 'prepared', '0', '0', '0'],
  'publish_refused_when_results_changed_since_checked: after a status, a boundary or a new preparation, the totals checked '
  || 'before do not publish; nothing is published, recorded or emailed');
insert into res values ('c_pub4', pg_temp.pub('admin', 'c', 4));
select is(array[pg_temp.code(pg_temp.r('c_pub4')), pg_temp.er('c', 'state'), pg_temp.notices('c')::text],
  array['ok', 'published', '3'],
  'publish_refused_when_results_changed_since_checked: the totals as they are now publish');

insert into res values ('n_pub', pg_temp.pub('admin', 'n', 0));
insert into res values ('null_pub', pg_temp.pub('admin', 'c', null));
insert into res values ('nf_pub', pg_temp.as('admin', format('select public.results_publish(%L, 1)', gen_random_uuid())));
insert into res values ('pub_pub', pg_temp.pubv('admin', 'c'));
select is(array[pg_temp.code(pg_temp.r('n_pub')), pg_temp.code(pg_temp.r('null_pub')), pg_temp.code(pg_temp.r('nf_pub')),
    pg_temp.code(pg_temp.r('pub_pub')), pg_temp.notices('c')::text, pg_temp.notices('n')::text],
  array['not_prepared', 'invalid_input', 'not_found', 'results_published', '3', '0'],
  'results_publish refuses results never prepared, a missing version, an unknown exam and results already published');

-- ---------------------------------------------------------------------------------------------
-- publish_refused_when_approval_withdrawn_or_stale
-- ---------------------------------------------------------------------------------------------
insert into res values ('a_prep', pg_temp.prep('admin', 'a'));
insert into res values ('a_awd', pg_temp.awd('admin', 'a', 'Marks need another look.'));
insert into res values ('a_pub1', pg_temp.pubv('admin', 'a'));
insert into res values ('a_sch1', pg_temp.pubv('admin', 'a', now() + interval '1 day'));
select pg_temp.reapprove('a');
insert into kv values ('a_late', tests.verified_script(pg_temp.k('a'), 'home'));
insert into res values ('a_pub2', pg_temp.pubv('admin', 'a'));
insert into res values ('a_sch2', pg_temp.pubv('admin', 'a', now() + interval '1 day'));
select is(array[pg_temp.code(pg_temp.r('a_awd')), pg_temp.code(pg_temp.r('a_pub1')), pg_temp.code(pg_temp.r('a_sch1')),
    pg_temp.code(pg_temp.r('a_pub2')), pg_temp.code(pg_temp.r('a_sch2')), pg_temp.er('a', 'state'), pg_temp.notices('a')::text,
    pg_temp.exam_vers('a')::text],
  array['ok', 'marking_not_approved', 'marking_not_approved', 'approval_stale', 'approval_stale', 'prepared', '0', '0'],
  'publish_refused_when_approval_withdrawn_or_stale: neither at once nor at a time while the approval is withdrawn, or once a '
  || 'script arrived after it');

-- ---------------------------------------------------------------------------------------------
-- publish_refused_when_a_booking_is_cancelled_after_checking (Ruling R7)
-- ---------------------------------------------------------------------------------------------
insert into res values ('k_prep', pg_temp.prep('admin', 'k'));
update public.bookings set status = 'cancelled' where id = pg_temp.k('k:1');
insert into res values ('k_pub1', pg_temp.pubv('admin', 'k'));
insert into res values ('k_after', jsonb_build_object('stale', pg_temp.stale('k'), 'version', pg_temp.ver('k'),
  'script', (select s.state from public.scripts s where s.booking_id = pg_temp.k('k:1'))));
insert into res values ('k_prep2', pg_temp.prep('admin', 'k'));
update public.bookings set status = 'cancelled' where id = pg_temp.k('k_none');
insert into res values ('k_pub2', pg_temp.pubv('admin', 'k'));
insert into res values ('k_prep3', pg_temp.prep('admin', 'k'));
insert into res values ('k_pub3', pg_temp.pubv('admin', 'k'));
select is(array[pg_temp.code(pg_temp.r('k_pub1')), pg_temp.r('k_after') ->> 'stale', pg_temp.r('k_after') ->> 'version',
    pg_temp.r('k_after') ->> 'script', pg_temp.code(pg_temp.r('k_pub2')), pg_temp.code(pg_temp.r('k_pub3')), pg_temp.f('k:1', 'status'),
    pg_temp.f('k_none', 'status'), pg_temp.er('k', 'state'), pg_temp.notices('k')::text],
  array['results_changed', 'false', '1', 'withdrawn', 'results_changed', 'ok', 'withdrawn', 'no row', 'published', '4'],
  'publish_refused_when_a_booking_is_cancelled_after_checking: a cancelled booking withdraws its script without making the '
  || 'approval stale or changing the version, yet nothing publishes until the results are prepared again (also when a '
  || 'booking without a script stops being a candidate)');

-- withdraw -> change a final mark -> approve again -> publish refused until prepared again (Ruling R7)
insert into res values ('m_prep', pg_temp.prep('admin', 'm'));
insert into res values ('m_awd', pg_temp.awd('admin', 'm', 'One mark needs a change.'));
update public.final_marks set mark = mark - 1 where unit_id = pg_temp.unit('m:1') and question_id = pg_temp.q('m', '1');
select pg_temp.reapprove('m');
insert into res values ('m_after', jsonb_build_object('stale', pg_temp.stale('m'), 'version', pg_temp.ver('m')));
insert into res values ('m_pub1', pg_temp.pubv('admin', 'm'));
insert into res values ('m_prep2', pg_temp.prep('admin', 'm'));
insert into res values ('m_pub2', pg_temp.pubv('admin', 'm'));
select is(array[pg_temp.code(pg_temp.r('m_awd')), pg_temp.r('m_after') ->> 'stale', pg_temp.r('m_after') ->> 'version',
    pg_temp.code(pg_temp.r('m_pub1')), pg_temp.code(pg_temp.r('m_prep2')), pg_temp.r('m_prep2') ->> 'version', pg_temp.f('m:1', 'total'),
    pg_temp.code(pg_temp.r('m_pub2')), pg_temp.er('m', 'state')],
  array['ok', 'false', '1', 'results_changed', 'ok', '2', '23.0', 'ok', 'published'],
  'publish_refused_when_final_marks_changed_after_checking: the approval withdrawn, a final mark changed and the marking '
  || 'approved again: the totals checked before do not publish until the results are prepared again');

-- ---------------------------------------------------------------------------------------------
-- publish_at_must_be_within_30_days
-- ---------------------------------------------------------------------------------------------
insert into res values ('w_prep', pg_temp.prep('admin', 'w'));
insert into res values ('w_far', pg_temp.pubv('admin', 'w', now() + interval '30 days 1 minute'));
insert into res values ('w_past', pg_temp.pubv('admin', 'w', now() - interval '2 minutes'));
insert into res values ('w_30', pg_temp.pubv('admin', 'w', now() + interval '30 days'));
insert into res values ('w_cancel1', pg_temp.cancel('admin', 'w'));
insert into res values ('w_recent', pg_temp.pubv('admin', 'w', now() - interval '30 seconds'));
insert into res values ('w_cancel2', pg_temp.cancel('admin', 'w'));
insert into res values ('w_clock', pg_temp.pubv('admin', 'w', '2027-03-01 09:00+00', '2027-02-20 09:00+00'));
insert into res values ('w_cancel3', pg_temp.cancel('admin', 'w'));
select is(array[pg_temp.code(pg_temp.r('w_far')), pg_temp.code(pg_temp.r('w_past')), pg_temp.code(pg_temp.r('w_30')),
    pg_temp.r('w_30') ->> 'state', ((pg_temp.r('w_30') ->> 'publish_at')::timestamptz = now() + interval '30 days')::text,
    pg_temp.code(pg_temp.r('w_recent')), pg_temp.r('w_recent') ->> 'state', pg_temp.code(pg_temp.r('w_clock')),
    pg_temp.code(pg_temp.r('w_cancel3')), pg_temp.er('w', 'state'), pg_temp.notices('w')::text,
    pg_temp.audits('results_scheduled', pg_temp.k('w'))::text, pg_temp.audits('results_schedule_cancelled', pg_temp.k('w'))::text],
  array['invalid_input', 'invalid_input', 'ok', 'scheduled', 'true', 'ok', 'scheduled', 'ok', 'ok', 'prepared', '0', '3', '3'],
  'publish_at_must_be_within_30_days: up to 30 days ahead and at most a minute past, counted from the clock it is given');

-- ---------------------------------------------------------------------------------------------
-- scheduled_publish_skipped_when_approval_stale_or_withdrawn (and, Ruling R7, when the results changed)
-- ---------------------------------------------------------------------------------------------
insert into res values ('f1_prep', pg_temp.prep('admin', 'f1'));
insert into res values ('f2_prep', pg_temp.prep('admin', 'f2'));
insert into res values ('f3_prep', pg_temp.prep('admin', 'f3'));
insert into res values ('f1_sch', pg_temp.pubv('admin', 'f1', now() + interval '1 hour'));
insert into res values ('f2_sch', pg_temp.pubv('admin', 'f2', now() + interval '1 hour'));
insert into res values ('f3_sch', pg_temp.pubv('admin', 'f3', now() + interval '1 hour'));
-- The approval cannot be withdrawn while results are scheduled (marking_approval_withdraw refuses); the minute job checks anyway.
update public.exam_marking set approved_at = null, approved_by = null where exam_id = pg_temp.k('f1');
insert into kv values ('f2_late', tests.verified_script(pg_temp.k('f2'), 'home'));
update public.bookings set status = 'cancelled' where id = pg_temp.k('f3:1');
select pg_temp.tick(now() + interval '59 minutes');
insert into res values ('f_early', to_jsonb(array[pg_temp.er('f1', 'state'), pg_temp.er('f2', 'state'), pg_temp.er('f3', 'state')]));
select pg_temp.tick(now() + interval '2 hours');
create function pg_temp.failed(p_exam text) returns text language sql stable as $$
  select concat_ws(' ', pg_temp.er(p_exam, 'state'), pg_temp.er(p_exam, 'publish_failed_reason'),
    (pg_temp.er(p_exam, 'publish_failed_at')::timestamptz = now() + interval '2 hours')::text, pg_temp.er(p_exam, 'publish_at'),
    pg_temp.er(p_exam, 'published_at'), pg_temp.er(p_exam, 'first_published_at'), pg_temp.notices(p_exam), pg_temp.exam_vers(p_exam)) $$;
select is(array[pg_temp.code(pg_temp.r('f1_sch')), pg_temp.code(pg_temp.r('f2_sch')), pg_temp.code(pg_temp.r('f3_sch')),
    pg_temp.r('f_early') #>> '{}', pg_temp.failed('f1'), pg_temp.failed('f2'), pg_temp.failed('f3'),
    (select count(*)::text from public.audit_log a where a.action = 'results_publish_failed' and a.actor_id is null
       and a.target_id in (pg_temp.k('f1'), pg_temp.k('f2'), pg_temp.k('f3')))],
  array['ok', 'ok', 'ok', '["scheduled", "scheduled", "scheduled"]',
    'prepared marking_not_approved true null null null 0 0', 'prepared approval_stale true null null null 0 0',
    'prepared results_changed true null null null 0 0', '3'],
  'scheduled_publish_skipped_when_approval_stale_or_withdrawn: at its time the minute job publishes nothing when the approval '
  || 'was withdrawn, went stale or the results changed: the results go back to prepared, the failure is recorded, no email');
insert into res values ('f3_prep2', pg_temp.prep('admin', 'f3'));
insert into res values ('f3_pub', pg_temp.pubv('admin', 'f3'));
select is(array[pg_temp.code(pg_temp.r('f3_pub')), pg_temp.er('f3', 'state'), pg_temp.er('f3', 'publish_failed_at'),
    pg_temp.er('f3', 'publish_failed_reason'), pg_temp.notices('f3')::text],
  array['ok', 'published', 'null', 'null', '2'],
  'scheduled_publish_skipped_when_approval_stale_or_withdrawn: once prepared again and published, the failure is cleared');

-- ---------------------------------------------------------------------------------------------
-- cancel_a_scheduled_publication
-- ---------------------------------------------------------------------------------------------
insert into res values ('x_prep', pg_temp.prep('admin', 'x'));
insert into res values ('x_sch', pg_temp.pubv('admin', 'x', now() + interval '1 day'));
insert into res values ('x_again', pg_temp.pubv('admin', 'x'));
insert into res values ('x_st', pg_temp.st('admin', 'x:1', 'absent', 'While scheduled.'));
insert into res values ('x_awd', pg_temp.awd('admin', 'x', 'While scheduled.'));
insert into res values ('x_cancel', pg_temp.cancel('admin', 'x'));
select pg_temp.tick(now() + interval '2 days');
insert into res values ('x_cancel2', pg_temp.cancel('admin', 'x'));
select is(array[pg_temp.code(pg_temp.r('x_sch')), pg_temp.r('x_sch') ->> 'state', pg_temp.code(pg_temp.r('x_again')),
    pg_temp.code(pg_temp.r('x_st')), pg_temp.code(pg_temp.r('x_awd')), pg_temp.code(pg_temp.r('x_cancel')), pg_temp.r('x_cancel') ->> 'state',
    pg_temp.r('x_cancel') ->> 'already', pg_temp.er('x', 'state'), pg_temp.er('x', 'publish_at'), pg_temp.code(pg_temp.r('x_cancel2')),
    pg_temp.r('x_cancel2') ->> 'already', pg_temp.notices('x')::text, pg_temp.audits('results_schedule_cancelled', pg_temp.k('x'))::text,
    pg_temp.er('x', 'version'), pg_temp.f('x:1', 'status')],
  array['ok', 'scheduled', 'already_scheduled', 'results_published', 'results_published', 'ok', 'prepared', 'false', 'prepared',
    'null', 'ok', 'true', '0', '1', '1', 'present'],
  'cancel_a_scheduled_publication: while scheduled nothing else changes the results; cancelled, the results are prepared '
  || 'again, the minute job leaves them alone, and the cancel is audited');
insert into res values ('x_pub', pg_temp.pub('admin', 'x', 1));
insert into res values ('x_cancel3', pg_temp.cancel('admin', 'x'));
select is(array[pg_temp.code(pg_temp.r('x_pub')), pg_temp.code(pg_temp.r('x_cancel3')), pg_temp.er('x', 'state')],
  array['ok', 'results_published', 'published'],
  'cancel_a_scheduled_publication: the totals checked before the cancel still publish (nothing changed); published results '
  || 'have nothing to cancel');

-- ---------------------------------------------------------------------------------------------
-- scheduled_publish_happens_once_across_the_clock_change: UK clocks go back at 2027-10-31 01:00 UTC (02:00 BST becomes
-- 01:00 GMT), so 01:30 on UK clocks happens twice: at 00:30 UTC (BST) and at 01:30 UTC (GMT).
-- ---------------------------------------------------------------------------------------------
insert into res values ('d_prep', pg_temp.prep('admin', 'd'));
insert into res values ('d_sch', pg_temp.pubv('admin', 'd', '2027-10-31 01:30+00', '2027-10-20 12:00+00'));
set local timezone = 'Europe/London';
insert into res values ('d_uk', jsonb_build_object(
  'at', to_char((pg_temp.get('admin', 'd') ->> 'publish_at')::timestamptz, 'DD Mon YYYY HH24:MI TZ'),
  'bst', to_char('2027-10-31 00:30+00'::timestamptz, 'DD Mon YYYY HH24:MI TZ')));
set local timezone = 'UTC';
select pg_temp.tick('2027-10-31 00:30+00');
insert into res values ('d_0030', to_jsonb(pg_temp.er('d', 'state')));
select pg_temp.tick('2027-10-31 01:29+00');
insert into res values ('d_0129', to_jsonb(pg_temp.er('d', 'state')));
select pg_temp.tick('2027-10-31 01:30+00');
insert into res values ('d_0130', jsonb_build_object('state', pg_temp.er('d', 'state'), 'notices', pg_temp.notices('d')));
select pg_temp.tick('2027-10-31 01:30:40+00');
insert into res values ('d_hand', pg_temp.pubv('admin', 'd', null, '2027-10-31 01:30:50+00'));
select pg_temp.tick('2027-10-31 01:31+00');
set local timezone = 'Europe/London';
insert into res values ('d_uk2', to_jsonb(to_char(pg_temp.er('d', 'published_at')::timestamptz, 'DD Mon YYYY HH24:MI TZ')));
set local timezone = 'UTC';
select is(array[pg_temp.code(pg_temp.r('d_sch')), pg_temp.r('d_sch') ->> 'state', pg_temp.r('d_uk') ->> 'at', pg_temp.r('d_uk') ->> 'bst',
    pg_temp.r('d_0030') #>> '{}', pg_temp.r('d_0129') #>> '{}', pg_temp.r('d_0130') ->> 'state', pg_temp.r('d_0130') ->> 'notices',
    pg_temp.code(pg_temp.r('d_hand')), pg_temp.er('d', 'state'),
    (pg_temp.er('d', 'published_at')::timestamptz = '2027-10-31 01:30+00')::text,
    (pg_temp.er('d', 'first_published_at')::timestamptz = '2027-10-31 01:30+00')::text, pg_temp.r('d_uk2') #>> '{}',
    pg_temp.notices('d')::text, array_to_string(pg_temp.fs(pg_temp.ns('d', 1, 3), 'version'), ','),
    pg_temp.audits('results_published', pg_temp.k('d'))::text,
    (select (a.actor_id is null)::text from public.audit_log a where a.action = 'results_published' and a.target_id = pg_temp.k('d')),
    pg_temp.er('d', 'published_by')],
  array['ok', 'scheduled', '31 Oct 2027 01:30 GMT', '31 Oct 2027 01:30 BST', 'scheduled', 'scheduled', 'published', '3',
    'results_published', 'published', 'true', 'true', '31 Oct 2027 01:30 GMT', '3', '1,1,1', '1', 'true', 'null'],
  'scheduled_publish_happens_once_across_the_clock_change: set for 01:30 GMT, it is not published at 01:30 BST or 01:29, is '
  || 'published at the first tick of 01:30 UTC, once (a second tick that minute, a hand publication and 01:31 change nothing), '
  || 'and reads 01:30 GMT in UK time');

-- ---------------------------------------------------------------------------------------------
-- admins_only (lead, teacher, corrector, student, parent -> forbidden; nothing written)
-- ---------------------------------------------------------------------------------------------
create function pg_temp.all_codes(p_who text) returns text language sql as $$
  select concat_ws(',', pg_temp.code(pg_temp.pubv(p_who, 'a')), pg_temp.code(pg_temp.pubv(p_who, 'a', now() + interval '1 day')),
    pg_temp.code(pg_temp.cancel(p_who, 'x')), pg_temp.code(pg_temp.wdr(p_who, 'c', 'Not allowed.'))) $$;
select is(array[pg_temp.all_codes('lead'), pg_temp.all_codes('teacher'), pg_temp.all_codes('corrector'),
    pg_temp.all_codes('student'), pg_temp.all_codes('parent2'), pg_temp.er('a', 'state'), pg_temp.er('c', 'state'), pg_temp.er('x', 'state'),
    pg_temp.audits('results_withdrawn', pg_temp.k('c'))::text, pg_temp.audits('results_scheduled', pg_temp.k('a'))::text],
  array['forbidden,forbidden,forbidden,forbidden', 'forbidden,forbidden,forbidden,forbidden', 'forbidden,forbidden,forbidden,forbidden',
    'forbidden,forbidden,forbidden,forbidden', 'forbidden,forbidden,forbidden,forbidden', 'prepared', 'published', 'published', '0', '0'],
  'admins_only: the lead marker, a teacher, a corrector, the candidate and their parent are refused publishing, scheduling, '
  || 'cancelling and withdrawing, and nothing is written');
select is(array[
    has_function_privilege('anon', 'public.results_publish(uuid, int, timestamptz, timestamptz)', 'execute'),
    has_function_privilege('anon', 'public.results_publish_cancel(uuid)', 'execute'),
    has_function_privilege('anon', 'public.results_withdraw(uuid, text)', 'execute'),
    has_function_privilege('anon', 'public.result_status_set(uuid, text, text)', 'execute'),
    has_function_privilege('authenticated', 'public.results_publish(uuid, int, timestamptz, timestamptz)', 'execute'),
    has_function_privilege('authenticated', 'public.results_publish_cancel(uuid)', 'execute'),
    has_function_privilege('authenticated', 'public.results_withdraw(uuid, text)', 'execute'),
    has_function_privilege('authenticated', 'public.result_status_set(uuid, text, text)', 'execute')],
  array[false, false, false, false, true, true, true, true],
  'admins_only: anon cannot call the publishing functions; signed-in users can (each checks for an admin)');
select is((select array_agg(p.proname::text || ' ' || r.rolname order by p.proname, r.rolname)
           from pg_proc p cross join (values ('anon'), ('authenticated'), ('service_role')) r(rolname)
           where p.pronamespace = 'public'::regnamespace
             and p.proname in ('results_publish_now', 'results_tick', 'result_versions_record', 'results_derive', 'results_unchanged',
                               'results_write', 'script_notice_recipients', 'script_notice_content')
             and has_function_privilege(r.rolname, p.oid, 'execute')),
  null::text[],
  'admins_only: the internal functions (publishing now, the minute job, recording a version, deriving and comparing the rows, '
  || 'the notice helpers) are callable by no client role, the service role included');
select is((select concat_ws(' | ', j.schedule, j.command, j.username) from cron.job j where j.jobname = 'results-tick'),
  '* * * * * | select public.results_tick() | postgres',
  'the minute job results-tick runs every minute, as postgres');

-- ---------------------------------------------------------------------------------------------
-- publish_in_time_at_1500_candidates (a timing guard, as 065's: the fixture tables are analysed first). Exam big: 1,000
-- candidates at home and 500 at a centre, prepared. As an admin, publishing at once (the rows derived again and
-- compared, 1,500 versions recorded, 1,500 emails queued) must answer within 4 s, under the 8 s statement timeout a
-- signed-in call meets.
-- ---------------------------------------------------------------------------------------------
create function pg_temp.timed(p_name text, p_sql text) returns jsonb language plpgsql as $$
declare
  v_t0 timestamptz := clock_timestamp();
  v jsonb;
begin
  execute p_sql into v;
  insert into res values (p_name, jsonb_build_object('ms', round(extract(epoch from clock_timestamp() - v_t0) * 1000)));
  return v;
end $$;
grant execute on function pg_temp.timed(text, text), pg_temp.k(text) to public;
insert into kv values ('big', tests.results_exam(1000, 500, array(select (i % 25)::numeric from generate_series(1, 1500) i)));
insert into res values ('big_prep', pg_temp.prep('admin', 'big'));
analyze public.bookings, public.scripts, public.marking_units, public.final_marks, public.exam_questions, public.exam_option_groups,
        public.attendance, public.results, public.exam_results, public.result_versions, public.grade_boundaries, public.profiles,
        public.student_details, public.script_pages, public.script_page_links, public.script_uploads, public.home_submissions,
        public.script_exceptions, public.marking_alerts, public.exam_markers, public.exam_marking, public.exams, public.script_notices;
-- The call, written as postgres (only pg_temp.timed and pg_temp.k are granted to the signed-in role).
insert into res values ('big_sql', to_jsonb(format('select public.results_publish(%L, %s)', pg_temp.k('big'), pg_temp.ver('big'))));
create temp table big_sql as select j #>> '{}' as q from res where name = 'big_sql';
grant select on big_sql to public;
select tests.as_user(pg_temp.uid('admin'));
set local statement_timeout = '4s';
insert into res select 'big_pub', pg_temp.timed('ms_pub', q) from big_sql;
reset statement_timeout;
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('big_prep')), pg_temp.code(pg_temp.r('big_pub')), pg_temp.r('big_pub') ->> 'state',
    pg_temp.notices('big')::text, pg_temp.exam_vers('big')::text, ((pg_temp.r('ms_pub') ->> 'ms')::int <= 4000)::text],
  array['ok', 'ok', 'published', '1500', '1500', 'true'],
  'publish_in_time_at_1500_candidates: publishing 1,500 candidates within 4 s');
select diag('results_publish at 1,500 candidates: ' || (pg_temp.r('ms_pub') ->> 'ms') || ' ms');

select * from finish();
rollback;
