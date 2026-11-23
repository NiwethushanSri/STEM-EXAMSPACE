begin;
create extension if not exists pgtap with schema extensions;
select plan(61);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. s1 has a linked parent p1, s2 a linked parent p2; s3 is suspended. All times are passed as p_now
-- (honoured for this direct database session).
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
insert into c values ('p1', tests.create_user('parent', 'active'));
insert into c values ('p2', tests.create_user('parent', 'active'));
insert into c select 's' || i, tests.create_user('student', 'active') from generate_series(1, 4) i;
update public.profiles set status = 'suspended' where id = (select id from c where name = 's3');
insert into public.parent_children values
  ((select id from c where name = 'p1'), (select id from c where name = 's1')),
  ((select id from c where name = 'p2'), (select id from c where name = 's2'));
insert into public.subjects (name, kind) values ('ZZ Notices', 'school');

create temp table ex (name text primary key, id uuid not null);
create temp table pp (name text primary key, id uuid not null);
create temp table n (name text primary key, id bigint not null);
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.eid(p text) returns uuid language sql stable as $$ select id from ex where name = p $$;
create function pg_temp.pid(p text) returns uuid language sql stable as $$ select id from pp where name = p $$;
create function pg_temp.nid(p text) returns bigint language sql stable as $$ select id from n where name = p $$;
create function pg_temp.t(p text) returns timestamptz language sql immutable as $$ select (p || ' Europe/London')::timestamptz $$;

-- Published at-home exams, released 10 minutes before the start. Their papers' page roles are saved (a notice waits
-- for that: test 038).
create function pg_temp.mk_exam(p_name text, p_starts timestamptz, p_minutes int default 90) returns void language sql as $$
  with x as (
    insert into public.exams (subject_id, title, paper, format, starts_at, duration_minutes, price_pence,
      price_confirmed, booking_deadline, status)
    values ((select id from public.subjects where name = 'ZZ Notices'), 'ZZ ' || p_name, 'Paper 1', 'online', p_starts,
      p_minutes, 0, true, p_starts - interval '1 day', 'published')
    returning id)
  insert into ex select p_name, x.id from x
$$;
create function pg_temp.mk_paper(p_key text, p_exam text, p_version int default 1) returns void language sql as $$
  with p as (
    insert into public.exam_papers (exam_id, kind, title, version, storage_path, page_count, byte_size, pages_reviewed_at)
    values (pg_temp.eid(p_exam), 'paper', 'Question paper', p_version,
      pg_temp.eid(p_exam)::text || '/' || gen_random_uuid()::text || '.pdf', 2, 1000, now())
    returning id)
  insert into pp select p_key, p.id from p
$$;
create function pg_temp.book(p_exam text, p_student text, p_status public.booking_status default 'paid') returns uuid
language sql as $$
  insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting)
  values (pg_temp.eid(p_exam), pg_temp.uid(p_student), pg_temp.uid(p_student), p_status, 0, 'home')
  returning id
$$;
create function pg_temp.next_id(p_now timestamptz, p_exclude bigint[] default '{}') returns bigint language sql as $$
  select notice_id from public.paper_notice_next(p_exclude, p_now)
$$;
create function pg_temp.left_for(p_notice bigint) returns int language sql as $$
  select count(*)::int from public.paper_notice_recipients(p_notice)
$$;

select pg_temp.mk_exam('rel', pg_temp.t('2031-03-01 10:00'));
select pg_temp.mk_paper('rel', 'rel');
select pg_temp.book('rel', 's1');
select pg_temp.book('rel', 's2');
select pg_temp.book('rel', 's3');
select pg_temp.book('rel', 's4', 'awaiting_payment');
-- 60 minutes: downloads close at 13:00, inside the 6-hour window of its 09:50 release.
select pg_temp.mk_exam('short', pg_temp.t('2031-03-02 10:00'), 60);
select pg_temp.mk_paper('short', 'short');
select pg_temp.book('short', 's1');
select pg_temp.mk_exam('bare', pg_temp.t('2031-03-03 10:00'));
select pg_temp.book('bare', 's1');
select pg_temp.mk_exam('one', pg_temp.t('2031-03-04 10:00'));
select pg_temp.mk_paper('one', 'one');
select pg_temp.book('one', 's4');
select pg_temp.mk_exam('mv', pg_temp.t('2031-03-05 10:00'));
select pg_temp.mk_paper('mv', 'mv');
select pg_temp.book('mv', 's4');
-- A paper s1 downloaded (version 1), replaced at 09:55 by version 2.
select pg_temp.mk_exam('cor', pg_temp.t('2031-03-06 10:00'));
select pg_temp.mk_paper('cor_v1', 'cor');
create temp table cb as select pg_temp.book('cor', 's1') as id;
insert into public.paper_copies (code, booking_id, paper_id, page_count)
values (public.copy_code_new(), (select id from cb), pg_temp.pid('cor_v1'), 4);
insert into public.paper_downloads (copy_id, downloaded_by, kind)
select pc.id, pg_temp.uid('s1'), 'home' from public.paper_copies pc where pc.paper_id = pg_temp.pid('cor_v1');
update public.exam_papers set superseded_at = pg_temp.t('2031-03-06 09:55') where id = pg_temp.pid('cor_v1');
select pg_temp.mk_paper('cor_v2', 'cor', 2);
-- Every other exam in this database is already announced, so only these fixtures open notices here.
update public.exams set release_notified_at = now() where id not in (select id from ex) and release_notified_at is null;
update public.exam_papers set corrected_notified_at = now()
where exam_id not in (select id from ex) and superseded_at is not null and corrected_notified_at is null;

-- ---------------------------------------------------------------------------------------------
-- Tables and privileges.
-- ---------------------------------------------------------------------------------------------
select is((select count(*)::int from pg_class k join pg_namespace s on s.oid = k.relnamespace
  where s.nspname = 'public' and k.relname in ('paper_notices', 'paper_notices_sent') and k.relrowsecurity), 2,
  'both notice tables have RLS');
select is((select count(*)::int from unnest(array['paper_notices', 'paper_notices_sent']) t,
  unnest(array['select', 'insert', 'update', 'delete']) pr, unnest(array['anon', 'authenticated']) ro
  where has_table_privilege(ro, 'public.' || t, pr)), 0, 'anon and authenticated cannot touch them');
select ok(has_table_privilege('service_role', 'public.paper_notices', 'select')
  and has_table_privilege('service_role', 'public.paper_notices_sent', 'select')
  and not has_table_privilege('service_role', 'public.paper_notices', 'insert')
  and not has_table_privilege('service_role', 'public.paper_notices_sent', 'insert')
  and not has_table_privilege('service_role', 'public.paper_notices_sent', 'delete'),
  'the service role reads them and writes only through the functions');
select ok((select bool_and(has_function_privilege('service_role', f, 'execute')
    and not has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute'))
  from unnest(array['public.paper_notice_open(timestamptz)', 'public.paper_notice_next(bigint[],timestamptz)',
    'public.paper_notice_recipients(bigint)', 'public.paper_notice_mark(bigint,uuid,timestamptz)',
    'public.paper_notice_unmark(bigint,uuid)', 'public.paper_notice_finish(bigint,int,int,timestamptz)']) f),
  'the notice functions are for the service role only');
select is((select count(*)::int from information_schema.columns
  where table_schema = 'public' and table_name in ('paper_notices', 'paper_notices_sent')
    and column_name in ('email', 'first_name', 'last_name', 'name')), 0, 'no address or name is stored with a notice');

-- ---------------------------------------------------------------------------------------------
-- What is due (M7: nothing once downloads have closed).
-- ---------------------------------------------------------------------------------------------
select is((select count(*)::int from public.paper_release_due(pg_temp.t('2031-03-01 09:49:59')) where exam_id = pg_temp.eid('rel')), 0,
  'not due before the release');
select is((select count(*)::int from public.paper_release_due(pg_temp.t('2031-03-01 09:50')) where exam_id = pg_temp.eid('rel')), 1,
  'due at the release');
select is((select count(*)::int from public.paper_release_due(pg_temp.t('2031-03-02 12:59')) where exam_id = pg_temp.eid('short')), 1,
  'still due while downloads are open');
select is((select count(*)::int from public.paper_release_due(pg_temp.t('2031-03-02 13:00')) where exam_id = pg_temp.eid('short')), 0,
  'release_due_stops_when_downloads_close: not due after the scheduled end plus 2 hours, though inside 6 hours');
select is((select count(*)::int from public.paper_release_due(pg_temp.t('2031-03-03 09:51')) where exam_id = pg_temp.eid('bare')), 0,
  'an exam without a paper is not due');
select is((select count(*)::int from public.paper_corrected_due(pg_temp.t('2031-03-06 13:29')) where exam_id = pg_temp.eid('cor')), 1,
  'a replacement is due while downloads are open');
select is((select count(*)::int from public.paper_corrected_due(pg_temp.t('2031-03-06 13:30')) where exam_id = pg_temp.eid('cor')), 0,
  'and not once they have closed');

-- ---------------------------------------------------------------------------------------------
-- Opening and leasing.
-- ---------------------------------------------------------------------------------------------
select is(public.paper_notice_open(pg_temp.t('2031-03-01 09:50:30')), 1, 'the due release opens one notice');
insert into n select 'rel', id from public.paper_notices where exam_id = pg_temp.eid('rel');
select is((select kind || '/' || (release_at = pg_temp.t('2031-03-01 09:50')) || '/' || (window_until = pg_temp.t('2031-03-01 15:50'))
  from public.paper_notices where id = pg_temp.nid('rel')), 'released/true/true', 'a release notice keeps its release time and a 6-hour window');
select is((select release_notified_at from public.exams where id = pg_temp.eid('rel')), pg_temp.t('2031-03-01 09:50:30'), 'and claims the exam');
select is(public.paper_notice_open(pg_temp.t('2031-03-01 09:51')), 0, 'it is opened once');
select is(pg_temp.next_id(pg_temp.t('2031-03-01 09:51')), pg_temp.nid('rel'), 'the open notice is handed out');
select is((select lease_until from public.paper_notices where id = pg_temp.nid('rel')), pg_temp.t('2031-03-01 09:56'), 'leased for 5 minutes');
select is(pg_temp.next_id(pg_temp.t('2031-03-01 09:52')), null, 'another run does not get a leased notice');
select is(pg_temp.next_id(pg_temp.t('2031-03-01 09:56')), pg_temp.nid('rel'), 'an expired lease (a run that died) is handed out again');

-- ---------------------------------------------------------------------------------------------
-- Recipients, marks and the remainder carried to the next run.
-- ---------------------------------------------------------------------------------------------
select is(pg_temp.left_for(pg_temp.nid('rel')), 4, 'the active candidates and linked parents of paid home bookings (not suspended, not unpaid)');
select is(public.paper_notice_mark(pg_temp.nid('rel'), pg_temp.uid('s1'), pg_temp.t('2031-03-01 09:57')), 'ok', 'a recipient is recorded before the email');
select is(public.paper_notice_mark(pg_temp.nid('rel'), pg_temp.uid('s1'), pg_temp.t('2031-03-01 09:57')), 'already', 'at_most_once_per_recipient: a second mark is refused');
select is(pg_temp.left_for(pg_temp.nid('rel')), 3, 'a recorded recipient is no longer listed');
select is(public.paper_notice_mark(pg_temp.nid('rel'), pg_temp.uid('p1'), pg_temp.t('2031-03-01 09:57')), 'ok', 'the parent is marked');
select lives_ok($$select public.paper_notice_unmark(pg_temp.nid('rel'), pg_temp.uid('p1'))$$, 'a failed email is unmarked');
select is(pg_temp.left_for(pg_temp.nid('rel')), 3, 'so the parent is listed again for a later run');
select is(public.paper_notice_finish(pg_temp.nid('rel'), 1, 1, pg_temp.t('2031-03-01 09:58')), 'continue', 'people left after a run: continue');
select is((select coalesce(lease_until::text, 'free') || '/' || failed_rounds || '/' || coalesce(retry_at::text, 'none')
  from public.paper_notices where id = pg_temp.nid('rel')), 'free/0/none', 'the lease is released and no failure is counted');
select is(pg_temp.next_id(pg_temp.t('2031-03-01 09:58'), array[pg_temp.nid('rel')]), null, 'a run does not take the same notice twice');
select is(pg_temp.next_id(pg_temp.t('2031-03-01 09:59')), pg_temp.nid('rel'), 'remainder_on_next_tick: the next run carries on');

-- ---------------------------------------------------------------------------------------------
-- Every email of a run failing: back off 15 minutes, give up after the third time.
-- ---------------------------------------------------------------------------------------------
select is(public.paper_notice_finish(pg_temp.nid('rel'), 0, 3, pg_temp.t('2031-03-01 10:00')), 'retry', 'total_failure_backs_off');
select is((select failed_rounds || '/' || (retry_at = pg_temp.t('2031-03-01 10:15')) from public.paper_notices where id = pg_temp.nid('rel')),
  '1/true', 'retry no sooner than 15 minutes');
select is(pg_temp.next_id(pg_temp.t('2031-03-01 10:01')), null, 'not tried every minute');
select is(pg_temp.next_id(pg_temp.t('2031-03-01 10:14:59')), null, 'nor just before the 15 minutes');
select is(pg_temp.next_id(pg_temp.t('2031-03-01 10:15')), pg_temp.nid('rel'), 'tried again after 15 minutes');
select is(public.paper_notice_finish(pg_temp.nid('rel'), 0, 3, pg_temp.t('2031-03-01 10:16')), 'retry', 'a second failed run waits again');
select is(pg_temp.next_id(pg_temp.t('2031-03-01 10:31')), pg_temp.nid('rel'), 'and is tried once more');
select is(public.paper_notice_finish(pg_temp.nid('rel'), 0, 3, pg_temp.t('2031-03-01 10:32')), 'gave_up', 'the third failed run gives up');
select is((select done_at from public.paper_notices where id = pg_temp.nid('rel')), pg_temp.t('2031-03-01 10:32'), 'the notice is closed');
select is(pg_temp.next_id(pg_temp.t('2031-03-01 11:00')), null, 'and never handed out again');

-- ---------------------------------------------------------------------------------------------
-- Done, held, moved, out of window.
-- ---------------------------------------------------------------------------------------------
select is(public.paper_notice_open(pg_temp.t('2031-03-04 09:50')), 1, 'the single-recipient release opens');
insert into n select 'one', id from public.paper_notices where exam_id = pg_temp.eid('one');
select is(pg_temp.next_id(pg_temp.t('2031-03-04 09:50')), pg_temp.nid('one'), 'handed out');
select is(public.paper_notice_mark(pg_temp.nid('one'), pg_temp.uid('s4'), pg_temp.t('2031-03-04 09:50')), 'ok', 'marked');
select is(public.paper_notice_finish(pg_temp.nid('one'), 1, 0, pg_temp.t('2031-03-04 09:51')), 'done', 'everyone emailed: done');
select is(public.paper_notice_open(pg_temp.t('2031-03-04 09:52')) + coalesce(pg_temp.next_id(pg_temp.t('2031-03-04 09:52')), 0), 0::bigint,
  'a finished release is neither opened nor handed out again');

select is(public.paper_notice_open(pg_temp.t('2031-03-05 09:50')), 1, 'the release of the exam to be moved opens');
insert into n select 'mv', id from public.paper_notices where exam_id = pg_temp.eid('mv');
update public.exams set release_held = true where id = pg_temp.eid('mv');
select is(pg_temp.next_id(pg_temp.t('2031-03-05 09:51')), null, 'a held exam''s notice is not handed out');
select is(public.paper_notice_mark(pg_temp.nid('mv'), pg_temp.uid('s4'), pg_temp.t('2031-03-05 09:51')), 'stopped', 'a hold mid-run stops the sending');
update public.exams set release_held = false where id = pg_temp.eid('mv');
update public.exams set starts_at = pg_temp.t('2031-03-12 10:00') where id = pg_temp.eid('mv');
select is((select done_at is not null from public.paper_notices where id = pg_temp.nid('mv')), true, 'moving the exam closes its open release notice');
select is(public.paper_notice_open(pg_temp.t('2031-03-12 09:50')), 1, 'and the new release time opens a new one');

select is(public.paper_notice_open(pg_temp.t('2031-03-02 09:50')), 1, 'the short exam''s release opens');
insert into n select 'short', id from public.paper_notices where exam_id = pg_temp.eid('short');
select is(pg_temp.next_id(pg_temp.t('2031-03-02 12:59'), array(select id from public.paper_notices where id <> pg_temp.nid('short'))),
  pg_temp.nid('short'), 'handed out while downloads are open');
update public.paper_notices set lease_until = null where id = pg_temp.nid('short');
select is(pg_temp.next_id(pg_temp.t('2031-03-02 13:00'), array(select id from public.paper_notices where id <> pg_temp.nid('short'))),
  null, 'next_stops_when_downloads_close: nothing is sent after the scheduled end plus 2 hours');
select is(public.paper_notice_mark(pg_temp.nid('short'), pg_temp.uid('s1'), pg_temp.t('2031-03-02 13:00')), 'stopped', 'and a run still going stops');

-- ---------------------------------------------------------------------------------------------
-- Corrected papers.
-- ---------------------------------------------------------------------------------------------
select is(public.paper_notice_open(pg_temp.t('2031-03-06 09:56')), 2, 'the release and the replacement each open a notice');
insert into n select 'cor', id from public.paper_notices where exam_id = pg_temp.eid('cor') and kind = 'corrected';
select is((select paper_ids from public.paper_notices where id = pg_temp.nid('cor')), array[pg_temp.pid('cor_v1')], 'about the replaced version');
select is((select array_agg(profile_id order by profile_id) from public.paper_notice_recipients(pg_temp.nid('cor'))),
  (select array_agg(id order by id) from c where name in ('s1', 'p1')), 'for the candidate who downloaded it and their parent');
select is((select corrected_notified_at from public.exam_papers where id = pg_temp.pid('cor_v1')), pg_temp.t('2031-03-06 09:56'), 'the old version is claimed');
select is(public.paper_notice_open(pg_temp.t('2031-03-06 15:56')), 0, 'nothing new opens');
select is((select count(*)::int from public.paper_notices where exam_id = pg_temp.eid('cor') and done_at is not null), 2,
  'notices past their 6-hour window are closed');

select * from finish();
rollback;
