begin;
create extension if not exists pgtap with schema extensions;
select plan(51);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Exam e. Student s1 (first name Zanzibar) with active parent p1 and suspended parent p2; booking b1 with
-- script S-... Student s2 without a parent (booking b2, no script yet). Staff: owner, admin, suspended admin, teacher.
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('owner', tests.create_user('owner', 'active')), ('admin', tests.create_user('admin', 'active')),
  ('admin2', tests.create_user('admin', 'suspended')), ('teacher', tests.create_user('teacher', 'active')),
  ('p1', tests.create_user('parent', 'active')), ('p2', tests.create_user('parent', 'suspended')),
  ('s1', tests.create_user('student', 'active')), ('s2', tests.create_user('student', 'active'));
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text) to public;

update public.profiles set first_name = 'Zanzibar' where id = pg_temp.uid('s1');
insert into public.parent_children values (pg_temp.uid('p1'), pg_temp.uid('s1')), (pg_temp.uid('p2'), pg_temp.uid('s1'));
insert into public.subjects (name, kind) values ('ZZ Notices', 'school');
insert into public.exams (subject_id, title, paper, format, starts_at, duration_minutes, price_pence, price_confirmed, booking_deadline, status)
select s.id, 'ZZN e', 'P1', 'both', '2031-06-07 10:00 Europe/London', 90, 0, true, '2031-06-06 10:00 Europe/London', 'published'
from public.subjects s where s.name = 'ZZ Notices';
insert into kv select 'e', e.id from public.exams e where e.title = 'ZZN e';
insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting)
select pg_temp.k('e'), c.id, c.id, 'paid', 0, 'home' from c where c.name in ('s1', 's2');
insert into kv select 'b' || right(s.name, 1), b.id from public.bookings b join c s on s.id = b.student_id where b.exam_id = pg_temp.k('e');
insert into kv select 'x1', (public.script_create(pg_temp.k('b1'), 'home', '2031-06-07 11:00Z')).id;
create function pg_temp.sub(p_name text, p_booking text, p_seq int) returns void language sql as $$
  with i as (insert into public.home_submissions (booking_id, seq, state) values (pg_temp.k(p_booking), p_seq, 'checking') returning id)
  insert into kv select p_name, id from i $$;
select pg_temp.sub('d1', 'b1', 1);
create function pg_temp.set_state(p_sub text, p_state text) returns void language sql as $$
  update public.home_submissions set state = p_state::public.submission_state where id = pg_temp.k(p_sub) $$;
create function pg_temp.n(p_kind text) returns int language sql stable as $$
  select count(*)::int from public.script_notices where kind = p_kind $$;

-- ----- receipt_queued_once_on_received -----
select is((select count(*)::int from public.script_notices), 0, 'a submission being checked queues nothing');
select pg_temp.set_state('d1', 'received');
select is(pg_temp.n('receipt'), 1, 'becoming received queues a receipt');
select is((select (script_id = pg_temp.k('x1'))::text || (submission_id = pg_temp.k('d1'))::text from public.script_notices where kind = 'receipt'),
  'truetrue', 'the receipt names the script and the submission');
select pg_temp.set_state('d1', 'needs_attention');
select is(pg_temp.n('needs_attention'), 1, 'becoming needs_attention queues that notice');
select pg_temp.set_state('d1', 'received');
select is(pg_temp.n('receipt'), 1, 'flipping back to received does not queue the receipt again');
select pg_temp.set_state('d1', 'needs_attention');
select is(pg_temp.n('needs_attention'), 1, 'nor does a second needs_attention');
select pg_temp.set_state('d1', 'received');
select pg_temp.sub('d2', 'b1', 2);
select pg_temp.set_state('d2', 'received');
select is(pg_temp.n('receipt'), 2, 'a new submission has its own receipt');
select pg_temp.sub('d3', 'b2', 1);
select pg_temp.set_state('d3', 'rejected');
select is(pg_temp.n('rejected'), 1, 'a rejected submission queues a rejected notice');
select is((select script_id from public.script_notices where kind = 'rejected'), null, 'without a script the notice has none');
update public.home_submissions set late = true where id = pg_temp.k('d3');
select is((select count(*)::int from public.script_notices), 4, 'a change that is not a state change queues nothing');

-- ----- staff_alert_on_late_and_failed -----
insert into public.script_exceptions (exam_id, kind, booking_id) values (pg_temp.k('e'), 'late', pg_temp.k('b1'));
insert into public.script_exceptions (exam_id, kind, booking_id) values (pg_temp.k('e'), 'processing_failed', pg_temp.k('b2'));
insert into public.script_exceptions (exam_id, kind) values (pg_temp.k('e'), 'uncoded_family_page'), (pg_temp.k('e'), 'not_expected'),
  (pg_temp.k('e'), 'other_exam');
select is(pg_temp.n('staff_alert'), 5, 'late, processing_failed, uncoded_family_page, not_expected and other_exam each queue an alert');
insert into public.script_exceptions (exam_id, kind) values (pg_temp.k('e'), 'poor_quality'), (pg_temp.k('e'), 'missing_pages'),
  (pg_temp.k('e'), 'duplicate');
select is(pg_temp.n('staff_alert'), 5, 'other kinds queue nothing');
select is((select n.script_id = pg_temp.k('x1') from public.script_notices n join public.script_exceptions e on e.id = n.exception_id
  where e.kind = 'late'), true, 'an alert carries the booking''s script');

-- ----- next_claims_before_send -----
-- Only the notices of this test (the table may hold others on a shared database): work from a fixed clock.
create function pg_temp.mine(p jsonb) returns jsonb language sql as $$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements(p) x
  where x ->> 'exam' like 'ZZN e%' $$;
create temp table got (j jsonb);
grant all on got to public;
insert into got select public.script_notice_next(100, now());
select is(jsonb_array_length(pg_temp.mine((select j from got))), 9, 'every queued notice is handed out');
select is((select count(*)::int from public.script_notices where attempts = 1 and claimed_at is not null and sent_at is null), 9,
  'each is claimed (attempts 1) before anything is sent');
select is(jsonb_array_length(pg_temp.mine(public.script_notice_next(100, now()))), 0, 'a claimed notice is not handed out again at once');
select is(jsonb_array_length(pg_temp.mine(public.script_notice_next(100, now() + interval '4 minutes 59 seconds'))), 0, 'nor within 5 minutes');
select is((select count(*)::int from public.script_notices where attempts = 1), 9, 'a refused hand-out claims nothing');
select is(jsonb_array_length(public.script_notice_next(0, now() + interval '6 minutes')), 0, 'a limit of 0 hands out nothing');
select is(jsonb_array_length(pg_temp.mine(public.script_notice_next(3, now() + interval '6 minutes'))), 3, 'a failed or crashed claim is retried after 5 minutes, up to the limit');
select public.script_notice_mark((select min(id) from public.script_notices), true);
select isnt((select sent_at from public.script_notices order by id limit 1), null, 'marking ok records the send');
select is(jsonb_array_length(pg_temp.mine(public.script_notice_next(100, now() + interval '5 hours'))), 8, 'a sent notice is not handed out again, the others are');
select is((select count(*)::int from public.script_notices where attempts = 3), 2, 'each claim counts as an attempt (two were claimed a third time)');
select is(jsonb_array_length(pg_temp.mine(public.script_notice_next(100, now() + interval '5 hours 30 minutes'))), 6, 'after 3 attempts a notice is given up (the 6 claimed fewer times are still due)');
select is(jsonb_array_length(pg_temp.mine(public.script_notice_next(100, now() + interval '7 hours'))), 0, 'nothing older than 6 hours is sent');

-- Content and recipients.
create temp table fresh (j jsonb);
grant all on fresh to public;
update public.script_notices set attempts = 0, claimed_at = null, sent_at = null;
insert into fresh select public.script_notice_next(100, now());
select is((select count(*)::int from jsonb_array_elements((select j from fresh)) x, jsonb_array_elements(x -> 'recipients') r
  where x ->> 'kind' = 'receipt' and x ->> 'submission_seq' = '1'
    and r ->> 'email' in ((select email from public.profiles where id = pg_temp.uid('s1')), (select email from public.profiles where id = pg_temp.uid('p1')))), 2,
  'a receipt goes to the student and the active linked parent');
select is((select jsonb_array_length(x -> 'recipients') from jsonb_array_elements((select j from fresh)) x
  where x ->> 'kind' = 'receipt' and x ->> 'submission_seq' = '1'), 2, 'a suspended parent is left out');
select is((select x ->> 'exam' from jsonb_array_elements((select j from fresh)) x where x ->> 'kind' = 'receipt' limit 1), 'ZZN e P1', 'the exam is its title and paper');
select is((select x ->> 'script_number' from jsonb_array_elements((select j from fresh)) x where x ->> 'kind' = 'receipt' limit 1),
  (select number from public.scripts where id = pg_temp.k('x1')), 'the script number is in the content');
select ok((select bool_and(r ->> 'email' in (select email from public.profiles where id in (pg_temp.uid('owner'), pg_temp.uid('admin'))))
  from jsonb_array_elements((select j from fresh)) x, jsonb_array_elements(x -> 'recipients') r where x ->> 'kind' = 'staff_alert'),
  'staff alerts go to owner and admin accounts only');
select is((select min(jsonb_array_length(x -> 'recipients')) from jsonb_array_elements((select j from fresh)) x where x ->> 'kind' = 'staff_alert'), 2,
  'the suspended admin and the teacher are left out');
select is((select count(*)::int from jsonb_array_elements((select j from fresh)) x where x ->> 'kind' = 'staff_alert' and x::text ilike '%Zanzibar%'), 0,
  'a staff alert has no candidate name');

-- ----- recipient_recorded_before_send: a failure, a crash or an overlapping run never repeats an email -----
create function pg_temp.rid() returns bigint language sql stable as $$
  select id from public.script_notices where kind = 'receipt' and submission_id = pg_temp.k('d1') $$;
create function pg_temp.reset() returns void language sql as $$
  update public.script_notices set attempts = 0, claimed_at = null, sent_at = null $$;
create function pg_temp.mine_rec() returns jsonb language sql as $$
  select x -> 'recipients' from jsonb_array_elements(public.script_notice_next(100, now())) x where (x ->> 'id')::bigint = pg_temp.rid() $$;
select pg_temp.reset();
select is(public.script_notice_record(pg_temp.rid(), pg_temp.uid('s1')), 'ok', 'a recipient is recorded before the send');
select is(public.script_notice_record(pg_temp.rid(), pg_temp.uid('s1')), 'already', 'an overlapping run sees them as already done');
select pg_temp.reset();
create temp table rr (j jsonb);
grant all on rr to public;
insert into rr select pg_temp.mine_rec();
select is(jsonb_array_length((select j from rr)), 1, 'a retry or a crashed run only has the people not recorded');
select is((select (j -> 0 ->> 'email') = (select email from public.profiles where id = pg_temp.uid('p1')) from rr), true, 'and that is the one not yet emailed');
select public.script_notice_unmark(pg_temp.rid(), pg_temp.uid('s1'));
select pg_temp.reset();
select is(jsonb_array_length(pg_temp.mine_rec()), 2, 'a failed send is forgotten so the person is tried again');
select public.script_notice_record(pg_temp.rid(), pg_temp.uid('s1'));
select public.script_notice_record(pg_temp.rid(), pg_temp.uid('p1'));
select pg_temp.reset();
select is(pg_temp.mine_rec(), null, 'a notice whose people are all recorded is not handed out');
select is((select sent_at is not null from public.script_notices where id = pg_temp.rid()), true, 'and is finished (a crash after the last send cannot repeat it)');
select is(public.script_notice_record(pg_temp.rid(), pg_temp.uid('s1')), 'stopped', 'nothing is recorded for a finished notice');

-- ----- rerun_does_not_repeat_alert -----
select pg_temp.reset();
select public.script_notice_mark((select n.id from public.script_notices n join public.script_exceptions e on e.id = n.exception_id where e.kind = 'late'), true);
delete from public.script_exceptions where kind in ('late', 'processing_failed');
select is((select count(*)::int from public.script_notices where kind = 'staff_alert' and exception_id is null), 2, 'deleting exceptions keeps their alerts (exception_id is set to null)');
insert into public.script_exceptions (exam_id, kind, booking_id) values (pg_temp.k('e'), 'late', pg_temp.k('b1'));
insert into public.script_exceptions (exam_id, kind, booking_id) values (pg_temp.k('e'), 'processing_failed', pg_temp.k('b2'));
select is(pg_temp.n('staff_alert'), 5, 'a re-run recreating them within the window queues no second alert');
select is((select count(*)::int from public.script_notices where kind = 'staff_alert' and sent_at is not null), 1, 'the sent alert stays recorded as sent');
select is((select x ->> 'exception_kind' from jsonb_array_elements(public.script_notice_next(100, now())) x
  where x ->> 'kind' = 'staff_alert' and x ->> 'exception_kind' = 'processing_failed'), 'processing_failed', 'an alert whose exception was deleted still says what it is about');
insert into public.script_exceptions (exam_id, kind, booking_id) values (pg_temp.k('e'), 'late', pg_temp.k('b2'));
select is(pg_temp.n('staff_alert'), 6, 'a different booking is a different alert');

-- ----- rerun_with_new_page_rows_queues_no_second_alert -----
insert into public.script_uploads (id, exam_id, booking_id, submission_id, kind, position, storage_path, mime, byte_size, uploaded_by)
values ('00000000-0000-4000-8000-0000000000a1', pg_temp.k('e'), pg_temp.k('b1'), pg_temp.k('d1'), 'home_photo', 1, 'zzn/a1.jpg',
  'image/jpeg', 1000, pg_temp.uid('s1'));
insert into public.script_pages (id, upload_id, source_index, exam_id, state, full_path)
values ('00000000-0000-4000-8000-0000000000b1', '00000000-0000-4000-8000-0000000000a1', 0, pg_temp.k('e'), 'unmatched', 'zzn/a1-0.jpg');
insert into public.script_exceptions (exam_id, kind, booking_id, upload_id, page_id)
values (pg_temp.k('e'), 'uncoded_family_page', pg_temp.k('b1'), '00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-0000000000b1');
select is(pg_temp.n('staff_alert'), 7, 'a page without a code queues an alert');
-- The rerun replaces the page row (same position in the upload) and recreates the exception.
update public.script_pages set replaced_at = now() where id = '00000000-0000-4000-8000-0000000000b1';
insert into public.script_pages (id, upload_id, source_index, exam_id, state, full_path)
values ('00000000-0000-4000-8000-0000000000b2', '00000000-0000-4000-8000-0000000000a1', 0, pg_temp.k('e'), 'unmatched', 'zzn/a1-0.jpg');
delete from public.script_exceptions where page_id = '00000000-0000-4000-8000-0000000000b1';
insert into public.script_exceptions (exam_id, kind, booking_id, upload_id, page_id)
values (pg_temp.k('e'), 'uncoded_family_page', pg_temp.k('b1'), '00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-0000000000b2');
select is(pg_temp.n('staff_alert'), 7, 'the same problem on new page rows after a rerun queues no second alert');
insert into public.script_pages (id, upload_id, source_index, exam_id, state, full_path)
values ('00000000-0000-4000-8000-0000000000b3', '00000000-0000-4000-8000-0000000000a1', 1, pg_temp.k('e'), 'unmatched', 'zzn/a1-1.jpg');
insert into public.script_exceptions (exam_id, kind, booking_id, upload_id, page_id)
values (pg_temp.k('e'), 'uncoded_family_page', pg_temp.k('b1'), '00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-0000000000b3');
select is(pg_temp.n('staff_alert'), 8, 'another page of the upload is its own alert');

-- ----- given_up_count -----
select pg_temp.reset();
update public.script_notices set attempts = 3 where id = pg_temp.rid() + 1;
select is(public.script_notice_given_up(now()), 1, 'notices given up after 3 attempts are counted');

-- ----- notice_functions_not_granted_to_authenticated -----
select ok((select bool_and(has_function_privilege('service_role', f, 'execute')
    and not has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute'))
  from unnest(array['public.script_notice_next(int,timestamptz)', 'public.script_notice_mark(bigint,boolean,timestamptz)', 'public.script_notice_record(bigint,uuid)', 'public.script_notice_unmark(bigint,uuid)', 'public.script_notice_given_up(timestamptz)']) f),
  'the notice functions are for the service role only');
select is((select count(*)::int from unnest(array['select', 'insert', 'update', 'delete']) pr, unnest(array['anon', 'authenticated']) ro
  where has_table_privilege(ro, 'public.script_notices', pr)), 0, 'anon and authenticated cannot touch the table');

select * from finish();
rollback;
