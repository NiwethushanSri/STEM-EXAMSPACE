begin;
create extension if not exists pgtap with schema extensions;
select plan(143);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Subject subj, taught by the teacher. Correctors m1 (approved later) and m2 (approved, then suspended), and
-- corr (never approved). Exams of subj, each finished 2 days ago: e0 (no questions), e (the test structure, marked as
-- whole scripts), eq (marked by question), eh (home hand-in window) and et (the tick). Scripts are made where a test
-- needs them.
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values
  ('admin', tests.create_user('admin', 'active')),
  ('teacher', tests.create_user('teacher', 'active')),
  ('m1', tests.create_user('corrector', 'active')),
  ('m2', tests.create_user('corrector', 'active')),
  ('corr', tests.create_user('corrector', 'active'));
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create temp table res (name text primary key, j jsonb);
grant all on res to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
create function pg_temp.r(p text) returns jsonb language sql stable as $$ select j from res where name = p $$;
create function pg_temp.subj() returns bigint language sql stable as $$ select id from public.subjects where name = 'ZZ Marking open' $$;
-- A function's answer: 'ok', or its code.
create function pg_temp.code(j jsonb) returns text language sql immutable as $$
  select case when (j ->> 'ok')::boolean then 'ok' else coalesce(j ->> 'code', 'none') end $$;
-- A script's state.
create function pg_temp.st(p text) returns text language sql stable as $$ select state::text from public.scripts where id = pg_temp.k(p) $$;
-- A script's units by their group label ('-' for the whole script), in group order.
create function pg_temp.units(p text) returns text language sql stable as $$
  select coalesce(string_agg(coalesce(g.label, '-'), ',' order by g.position nulls first), '')
  from public.marking_units u left join public.question_groups g on g.id = u.group_id where u.script_id = pg_temp.k(p) $$;
-- Why a script cannot be handed out ('ok' when it can).
create function pg_temp.why(p text, p_now timestamptz default null) returns text language sql stable as $$
  select coalesce(public.marking_script_blocked(pg_temp.k(p), p_now), 'ok') $$;
-- The file holding a script's first page.
create function pg_temp.upload(p text) returns uuid language sql stable as $$
  select pg.upload_id from public.scripts s
  join public.script_page_links l on l.script_id = s.id and l.version = s.version
  join public.script_pages pg on pg.id = l.page_id
  where s.id = pg_temp.k(p) order by l.copy_page limit 1 $$;
-- When an exam finished.
create function pg_temp.finish(p text) returns timestamptz language sql stable as $$
  select e.starts_at + e.duration_minutes * interval '1 minute' from public.exams e where e.id = pg_temp.k(p) $$;
-- How many audit rows of this action concern this target.
create function pg_temp.audits(p_action text, p_target uuid) returns int language sql stable as $$
  select count(*)::int from public.audit_log a where a.action = p_action and a.target_id = p_target $$;
-- A family's extra page for a home script: a second hand-in (adding pages) with one photo whose page has no code,
-- placed after page 1 and confirmed by staff. Returns the photo's upload.
create function pg_temp.extra_page(p text) returns uuid language plpgsql as $$
declare
  v_s public.scripts%rowtype;
  v_student uuid;
  v_sub uuid;
  v_up uuid := gen_random_uuid();
  v_page uuid;
begin
  select * into v_s from public.scripts where id = pg_temp.k(p);
  select b.student_id into v_student from public.bookings b where b.id = v_s.booking_id;
  insert into public.home_submissions (booking_id, seq, replaces_all, state, submitted_by, submitted_at, checked_at)
  values (v_s.booking_id, 2, false, 'received', v_student, now(), now()) returning id into v_sub;
  insert into public.script_uploads (id, exam_id, booking_id, submission_id, kind, position, storage_path, mime, byte_size, state,
    uploaded_by, stored_at)
  values (v_up, v_s.exam_id, v_s.booking_id, v_sub, 'home_photo', 1, 'home/' || v_s.booking_id || '/' || v_up || '.jpg', 'image/jpeg',
    5000, 'processed', v_student, now());
  insert into public.script_pages (upload_id, source_index, exam_id, booking_id, state, full_path, marking_path, placed_after)
  values (v_up, 0, v_s.exam_id, v_s.booking_id, 'unmatched', v_up || '/0-full.jpg', v_up || '/0-marking.jpg', 1)
  returning id into v_page;
  insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, state, resolved_by, resolved_at, resolution)
  values (v_s.exam_id, 'uncoded_family_page', v_s.booking_id, v_s.id, v_page, v_up, 'resolved', pg_temp.uid('admin'), now(), 'confirmed');
  return v_up;
end $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.r(text), pg_temp.subj(), pg_temp.code(jsonb), pg_temp.st(text),
  pg_temp.units(text), pg_temp.finish(text), pg_temp.audits(text, uuid) to public;

insert into public.subjects (name, kind) values ('ZZ Marking open', 'school');
insert into public.teacher_subjects values (pg_temp.uid('teacher'), pg_temp.subj());
insert into kv values ('e0', tests.marking_exam(pg_temp.subj()));
insert into kv values ('e', tests.marking_exam(pg_temp.subj()));
insert into kv values ('eq', tests.marking_exam(pg_temp.subj()));
insert into kv values ('eh', tests.marking_exam(pg_temp.subj()));
insert into kv values ('et', tests.marking_exam(pg_temp.subj()));
select tests.structure(pg_temp.k('e'));
select tests.structure(pg_temp.k('eq'));
select tests.structure(pg_temp.k('eh'));
select tests.structure(pg_temp.k('et'));
insert into kv values ('h1', tests.verified_script(pg_temp.k('e')));
insert into kv values ('c1', tests.verified_script(pg_temp.k('e'), 'centre'));

-- ---------------------------------------------------------------------------------------------
-- open_needs_structure_and_a_marker
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_open(pg_temp.k('e0'))), 'structure_incomplete',
  'open_needs_structure_and_a_marker: an exam with no questions cannot open');
select is(pg_temp.code(public.marking_open(pg_temp.k('e'))), 'no_markers', 'nor one with no approved marker for its subject');
select is(pg_temp.code(public.marker_approve(pg_temp.uid('m2'), pg_temp.subj(), 'Marked this paper last year')), 'ok', 'm2 is approved');
select tests.as_postgres();
update public.profiles set status = 'suspended' where id = pg_temp.uid('m2');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_open(pg_temp.k('e'))), 'no_markers', 'a suspended marker does not count');
select tests.as_postgres();
select is((select count(*)::int from public.exam_marking where exam_id in (pg_temp.k('e0'), pg_temp.k('e'))), 0,
  'a refused opening leaves nothing behind');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marker_approve(pg_temp.uid('m1'), pg_temp.subj(), 'Marked this paper last year')), 'ok', 'm1 is approved');
insert into res values ('open', public.marking_open(pg_temp.k('e')));
select is(pg_temp.r('open'), '{"ok": true, "already": false, "ready": 2}'::jsonb,
  'with questions and an active approved marker marking opens, and the 2 verified scripts are made ready');
select tests.as_postgres();
select is((select (m.opened_at = now()) and m.opened_by = pg_temp.uid('admin') and m.closed_at is null and m.mode = 'whole'
           from public.exam_marking m where m.exam_id = pg_temp.k('e')), true, 'opened_at and opened_by are set; marked as whole scripts');
select is((select count(*)::int from public.audit_log a where a.action = 'marking_opened' and a.target_type = 'exam' and a.target_id = pg_temp.k('e')
             and a.actor_id = pg_temp.uid('admin')), 1, 'an audit row says who opened it');

-- ---------------------------------------------------------------------------------------------
-- open_makes_verified_scripts_ready_with_one_unit
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.st('h1'), pg_temp.st('c1')], array['ready_to_mark', 'ready_to_mark'],
  'open_makes_verified_scripts_ready_with_one_unit: the home and the centre script are ready to mark');
select is(array[pg_temp.units('h1'), pg_temp.units('c1')], array['-', '-'], 'each has one unit, for the whole script');
select is((select string_agg(distinct u.state || ' ' || u.on_hold || ' ' || coalesce(u.hold_reason, '-') || ' ' || (u.exam_id = pg_temp.k('e')), ',')
           from public.marking_units u where u.script_id in (pg_temp.k('h1'), pg_temp.k('c1'))), 'open false - true',
  'open, not on hold, of the exam');
select is((select count(*)::int from public.markings m join public.marking_units u on u.id = m.unit_id where u.exam_id = pg_temp.k('e')), 0,
  'nobody holds or marks them yet');
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('get', public.marking_exam_get(pg_temp.k('e')));
select is(pg_temp.r('get') - 'opened_at' - 'waiting',
  '{"ok": true, "mode": "whole", "deadline": null, "closed_at": null, "markers": 1,
    "structure": {"version": 0, "leaves": 3, "max_total": 10, "ungrouped": 2},
    "scripts": {"verified": 0, "ready_to_mark": 2, "marking": 0, "marked": 0}}'::jsonb,
  'marking_exam_get: 3 questions to mark out of 10, 1 marker (m2 is suspended), 2 scripts ready');
select is(pg_temp.r('get') -> 'waiting',
  '{"home_window_open": 0, "centre_pages_unsettled": 0, "pictures_updating": 0, "late_undecided": 0, "taken_back": 0, "picture_unchecked": 0}'::jsonb,
  'and nothing waits');
select ok((pg_temp.r('get') ->> 'opened_at')::timestamptz = now(), 'it says when marking opened');

-- ---------------------------------------------------------------------------------------------
-- by_question_makes_one_unit_per_group
-- ---------------------------------------------------------------------------------------------
select tests.as_postgres();
insert into public.question_groups (exam_id, label, position) values (pg_temp.k('eq'), 'G1', 1), (pg_temp.k('eq'), 'G2', 2);
insert into kv values ('q1', tests.verified_script(pg_temp.k('eq')));
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_settings_set(pg_temp.k('eq'), 'by_question', null)), 'ok',
  'by_question_makes_one_unit_per_group: before opening the mode changes with no reason');
select is(pg_temp.code(public.marking_open(pg_temp.k('eq'))), 'structure_incomplete', 'by question, a question in no group stops opening');
select tests.as_postgres();
update public.exam_questions q set group_id = g.id from public.question_groups g
where q.exam_id = pg_temp.k('eq') and q.parent_id is null and q.label = '1' and g.exam_id = q.exam_id and g.label = 'G1';
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_open(pg_temp.k('eq'))), 'structure_incomplete', 'so does one question left without a group');
select is(public.marking_exam_get(pg_temp.k('eq')) -> 'structure' ->> 'ungrouped', '1', 'marking_exam_get counts it');
select tests.as_postgres();
update public.exam_questions q set group_id = g.id from public.question_groups g
where q.exam_id = pg_temp.k('eq') and q.parent_id is null and q.label = '2' and g.exam_id = q.exam_id and g.label = 'G2';
select tests.as_user(pg_temp.uid('admin'));
select is(public.marking_open(pg_temp.k('eq')), '{"ok": true, "already": false, "ready": 1}'::jsonb, 'with every question in a group it opens');
select tests.as_postgres();
select is(pg_temp.units('q1'), 'G1,G2', 'the script has one unit per question group');
select is(pg_temp.st('q1'), 'ready_to_mark', 'and is ready to mark');

-- ---------------------------------------------------------------------------------------------
-- open_twice_makes_no_second_units
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select is(public.marking_open(pg_temp.k('e')), '{"ok": true, "already": true}'::jsonb, 'open_twice_makes_no_second_units: a second call says so');
select tests.as_postgres();
select is(pg_temp.audits('marking_opened', pg_temp.k('e')), 1, 'and writes no second audit row');
select is(public.marking_exam_sync(pg_temp.k('e'), null), 0, 'a sync finds nothing new');
select is((select count(*)::int from public.marking_units where exam_id = pg_temp.k('e')), 2, 'the exam still has 2 units');
update public.scripts set state = 'verified' where id = pg_temp.k('h1');
select is(public.marking_exam_sync(pg_temp.k('e'), null), 1, 'a script back at verified is made ready again');
select is(array[pg_temp.st('h1'), pg_temp.units('h1')], array['ready_to_mark', '-'], 'with the unit it already had, not a second one');

-- ---------------------------------------------------------------------------------------------
-- script_waits_while_a_remask_job_is_queued_or_running
-- ---------------------------------------------------------------------------------------------
insert into kv values ('p1', tests.verified_script(pg_temp.k('e')));
insert into public.processing_jobs (upload_id, kind, state) values (pg_temp.upload('p1'), 'remask', 'queued');
select is(public.marking_script_busy(pg_temp.k('p1')), true,
  'script_waits_while_a_remask_job_is_queued_or_running: a remask queued for the file of one of its pages makes it busy');
select is(pg_temp.why('p1'), 'pictures_updating', 'so it waits');
select is(public.marking_exam_sync(pg_temp.k('e'), null), 0, 'the sync leaves it');
select is(pg_temp.st('p1'), 'verified', 'still verified');
update public.processing_jobs set state = 'running', locked_at = now() where upload_id = pg_temp.upload('p1') and kind = 'remask';
select is(pg_temp.why('p1'), 'pictures_updating', 'it waits while the job runs');
select is(public.marking_exam_sync(pg_temp.k('e'), null), 0, 'and the sync still leaves it');
update public.processing_jobs set state = 'done', finished_at = now() where upload_id = pg_temp.upload('p1') and kind = 'remask';
select is(public.marking_script_busy(pg_temp.k('p1')), false, 'once the job is done it is not busy');
select is(public.marking_exam_sync(pg_temp.k('e'), null), 1, 'and the next sync makes it ready');
select is(array[pg_temp.st('p1'), pg_temp.units('p1')], array['ready_to_mark', '-'], 'with its unit');
insert into public.processing_jobs (upload_id, kind, state) values (pg_temp.upload('p1'), 'prepare', 'queued');
select is(pg_temp.why('p1'), 'pictures_updating', 'a prepare job queued for its file holds a ready script back too');
update public.processing_jobs set state = 'failed', finished_at = now() where upload_id = pg_temp.upload('p1') and kind = 'prepare';
select is(pg_temp.why('p1'), 'ok', 'a failed job holds nothing back');
insert into kv values ('p2', tests.verified_script(pg_temp.k('e')));
insert into kv values ('p2x', pg_temp.extra_page('p2'));
select is((select count(*)::int from public.script_extra_pages(pg_temp.k('p2'))), 1, 'p2 has a family''s extra page');
insert into public.processing_jobs (upload_id, kind, state) values (pg_temp.k('p2x'), 'remask', 'running');
select is(pg_temp.why('p2'), 'pictures_updating', 'a job on the file of one of its extra pages makes it wait');
select is(public.marking_exam_sync(pg_temp.k('e'), null), 0, 'the sync leaves it');
update public.processing_jobs set state = 'done', finished_at = now() where upload_id = pg_temp.k('p2x');
select is(public.marking_exam_sync(pg_temp.k('e'), null), 1, 'once done the next sync makes it ready');

-- ---------------------------------------------------------------------------------------------
-- ready_script_locks_family_changes
-- ---------------------------------------------------------------------------------------------
select is(public.script_booking_locked((select booking_id from public.scripts where id = pg_temp.k('h1'))), true,
  'ready_script_locks_family_changes: a ready script''s booking is locked for family changes');
select is((select extras_locked from public.scripts where id = pg_temp.k('h1')), '[]'::jsonb, 'its extra pages are written down: none');
select is((select jsonb_array_length(extras_locked) || ' '
                  || ((extras_locked -> 0 ->> 'page_id')::uuid = (select id from public.script_pages where upload_id = pg_temp.k('p2x')))
           from public.scripts where id = pg_temp.k('p2')), '1 true', 'p2''s extra page is written down');
select is(public.script_booking_locked((select booking_id from public.scripts where id = pg_temp.k('c1'))), true, 'the centre script''s too');

-- ---------------------------------------------------------------------------------------------
-- centre_script_waits_for_no_code_and_unknown_code_pages_of_its_centre
-- ---------------------------------------------------------------------------------------------
insert into kv values ('c2', tests.verified_script(pg_temp.k('e'), 'centre'));
with v as (insert into public.venues (name, rooms) values ('ZZ Other hall 042', array['R2']) returning id),
     ec as (insert into public.exam_centres (exam_id, venue_id, room, seat_limit) select pg_temp.k('e'), v.id, 'R2', 100 from v returning id)
insert into kv select 'ec2', id from ec;
with b as (insert into public.scan_batches (exam_id, centre_id, number, created_by, created_at, submitted_at)
           values (pg_temp.k('e'), pg_temp.k('ec2'), 'B-ZZ-042-OTHER', pg_temp.uid('admin'), now(), now()) returning id)
insert into kv select 'b2', id from b;
with u as (insert into public.script_uploads (exam_id, batch_id, kind, position, storage_path, mime, byte_size, state, uploaded_by, stored_at)
           values (pg_temp.k('e'), pg_temp.k('b2'), 'scan_file', 1, 'batch/' || pg_temp.k('b2') || '/other.pdf', 'application/pdf', 1000,
                   'processed', pg_temp.uid('admin'), now()) returning id)
insert into kv select 'up2', id from u;
insert into public.script_exceptions (exam_id, kind, upload_id) values (pg_temp.k('e'), 'no_code', pg_temp.k('up2'));
select is(pg_temp.why('c2'), 'ok',
  'centre_script_waits_for_no_code_and_unknown_code_pages_of_its_centre: a page with no code from another centre does not hold it');
with x as (insert into public.script_exceptions (exam_id, kind, upload_id) values (pg_temp.k('e'), 'no_code', pg_temp.upload('c2')) returning id)
insert into kv select 'x1', id from x;
select is(pg_temp.why('c2'), 'centre_pages_unsettled', 'a page with no code in a scan file of its own centre does');
select is(pg_temp.why('c1'), 'centre_pages_unsettled', 'it holds back a ready script of that centre too');
select is(pg_temp.why('h1'), 'ok', 'but not a home script');
select tests.as_user(pg_temp.uid('admin'));
select is(public.marking_exam_get(pg_temp.k('e')) -> 'waiting' ->> 'centre_pages_unsettled', '2', 'marking_exam_get counts both');
select tests.as_postgres();
select is(public.marking_exam_sync(pg_temp.k('e'), null), 0, 'the sync leaves c2');
update public.script_exceptions set state = 'resolved', resolved_at = now(), resolution = 'matched' where id = pg_temp.k('x1');
select is(pg_temp.why('c2'), 'ok', 'once that page is settled it may be handed out');
with x as (insert into public.script_exceptions (exam_id, kind, upload_id) values (pg_temp.k('e'), 'unknown_code', pg_temp.upload('c1')) returning id)
insert into kv select 'x2', id from x;
select is(pg_temp.why('c2'), 'centre_pages_unsettled', 'a code not read in a scan file of its centre holds it too');
select is(public.marking_exam_sync(pg_temp.k('e'), null), 0, 'and the sync leaves it');
update public.script_exceptions set state = 'resolved', resolved_at = now(), resolution = 'matched' where id = pg_temp.k('x2');
select is(public.marking_exam_sync(pg_temp.k('e'), null), 1, 'once settled the next sync makes it ready');
select is(pg_temp.st('c2'), 'ready_to_mark', 'c2 is ready to mark');

-- ---------------------------------------------------------------------------------------------
-- home_script_waits_until_finish_plus_24_hours
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select is(public.marking_open(pg_temp.k('eh')), '{"ok": true, "already": false, "ready": 0}'::jsonb,
  'home_script_waits_until_finish_plus_24_hours: exam eh opens with no scripts');
select tests.as_postgres();
insert into kv values ('hw', tests.verified_script(pg_temp.k('eh')));
-- Exam eh sits in the hall exam e uses (the fixture would make a second hall of the same name).
insert into public.exam_centres (exam_id, venue_id, room, seat_limit)
select pg_temp.k('eh'), ec.venue_id, ec.room, 100 from public.exam_centres ec where ec.exam_id = pg_temp.k('e') and ec.id <> pg_temp.k('ec2');
insert into kv values ('cw', tests.verified_script(pg_temp.k('eh'), 'centre'));
select is(pg_temp.why('hw', pg_temp.finish('eh') + interval '24 hours' - interval '1 second'), 'home_window_open',
  'one second before finish + 24 hours a home script waits');
select is(pg_temp.why('hw', pg_temp.finish('eh') + interval '24 hours'), 'ok', 'at finish + 24 hours it may be handed out');
select is(pg_temp.why('cw', pg_temp.finish('eh') + interval '1 minute'), 'ok', 'a centre script does not wait for the home hand-in time');
select tests.as_user(pg_temp.uid('admin'));
select is(public.marking_exam_get(pg_temp.k('eh'), pg_temp.finish('eh') + interval '24 hours' - interval '1 second') -> 'waiting' ->> 'home_window_open',
  '1', 'marking_exam_get counts it as waiting');
select tests.as_postgres();
select is(public.marking_exam_sync(pg_temp.k('eh'), pg_temp.finish('eh') + interval '24 hours' - interval '1 second'), 1,
  'a sync one second before makes only the centre script ready');
select is(array[pg_temp.st('hw'), pg_temp.st('cw')], array['verified', 'ready_to_mark'], 'the home script still waits');
select is(public.marking_exam_sync(pg_temp.k('eh'), pg_temp.finish('eh') + interval '24 hours'), 1, 'a sync at the boundary makes it ready');
select is(pg_temp.st('hw'), 'ready_to_mark', 'the home script is ready to mark');

-- ---------------------------------------------------------------------------------------------
-- late_script_waits_for_accept_and_rejected_late_is_never_ready
-- ---------------------------------------------------------------------------------------------
insert into kv values ('l1', tests.verified_script(pg_temp.k('e')));
update public.scripts set late = true where id = pg_temp.k('l1');
select is(pg_temp.why('l1'), 'late_undecided', 'late_script_waits_for_accept_and_rejected_late_is_never_ready: a late script waits for a decision');
select is(public.marking_exam_sync(pg_temp.k('e'), null), 0, 'the sync leaves it');
update public.scripts set late_decision = 'accept' where id = pg_temp.k('l1');
select is(public.marking_exam_sync(pg_temp.k('e'), null), 1, 'once accepted the next sync makes it ready');
select is(pg_temp.st('l1'), 'ready_to_mark', 'the accepted late script is ready to mark');
insert into kv values ('l2', tests.verified_script(pg_temp.k('e')));
update public.scripts set late = true, late_decision = 'reject' where id = pg_temp.k('l2');
insert into kv values ('l3', tests.verified_script(pg_temp.k('e')));
update public.scripts set late = true, late_decision = 'reject', state = 'void', state_reason = 'late_rejected' where id = pg_temp.k('l3');
select is(array[pg_temp.why('l2'), pg_temp.why('l3')], array['late_undecided', 'not_verified'], 'a rejected late script is held back, or void');
select is(public.marking_exam_sync(pg_temp.k('e'), null), 0, 'the sync makes neither ready');
select is(array[pg_temp.st('l2'), pg_temp.units('l2'), pg_temp.st('l3'), pg_temp.units('l3')], array['verified', '', 'void', ''],
  'they have no units');

-- ---------------------------------------------------------------------------------------------
-- needs_attention_script_is_never_ready
-- ---------------------------------------------------------------------------------------------
insert into kv values ('n1', tests.verified_script(pg_temp.k('e')));
update public.scripts set state = 'needs_attention' where id = pg_temp.k('n1');
insert into kv values ('n2', tests.verified_script(pg_temp.k('e')));
update public.scripts set state = 'checking' where id = pg_temp.k('n2');
select is(array[pg_temp.why('n1'), pg_temp.why('n2')], array['not_verified', 'not_verified'],
  'needs_attention_script_is_never_ready: a script needing attention or being checked is not verified');
select is(public.marking_exam_sync(pg_temp.k('e'), null), 0, 'the sync makes neither ready');
select is(array[pg_temp.st('n1'), pg_temp.units('n1'), pg_temp.st('n2'), pg_temp.units('n2')], array['needs_attention', '', 'checking', ''],
  'they keep their state and have no units');

-- ---------------------------------------------------------------------------------------------
-- script_state_follows_its_units (marking_script_state)
-- ---------------------------------------------------------------------------------------------
create function pg_temp.unit(p_script text, p_group text) returns uuid language sql stable as $$
  select u.id from public.marking_units u left join public.question_groups g on g.id = u.group_id
  where u.script_id = pg_temp.k(p_script) and coalesce(g.label, '-') = p_group $$;
select public.marking_script_state(pg_temp.k('q1'));
select is(pg_temp.st('q1'), 'ready_to_mark', 'script_state_follows_its_units: open units: ready to mark');
update public.marking_units set state = 'taken' where id = pg_temp.unit('q1', 'G1');
select public.marking_script_state(pg_temp.k('q1'));
select is(pg_temp.st('q1'), 'marking', 'a unit taken: being marked');
update public.marking_units set state = 'submitted' where id = pg_temp.unit('q1', 'G1');
select public.marking_script_state(pg_temp.k('q1'));
select is(pg_temp.st('q1'), 'marking', 'one of two units submitted: still being marked');
update public.marking_units set state = 'submitted' where id = pg_temp.unit('q1', 'G2');
select public.marking_script_state(pg_temp.k('q1'));
select is(pg_temp.st('q1'), 'marked', 'every unit submitted: marked');
update public.marking_units set state = 'open' where script_id = pg_temp.k('q1');
insert into public.markings (unit_id, marker_id, status, set_aside_at, set_aside_reason)
values (pg_temp.unit('q1', 'G2'), pg_temp.uid('m1'), 'set_aside', now(), 'taken_back');
select public.marking_script_state(pg_temp.k('q1'));
select is(pg_temp.st('q1'), 'marking', 'every unit open again but one has a marking: still being marked');
select public.marking_script_state(pg_temp.k('l2'));
select is(pg_temp.st('l2'), 'verified', 'a script not yet ready is left as it is');

-- ---------------------------------------------------------------------------------------------
-- mode_cannot_change_after_open
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_settings_set(pg_temp.k('e'), 'by_question', null)), 'conflict',
  'mode_cannot_change_after_open: once open the mode is fixed');
select is(pg_temp.code(public.marking_settings_set(pg_temp.k('e'), 'whole', pg_temp.finish('e') + interval '7 days')), 'reason_required',
  'a deadline change after opening needs a reason');
select is(pg_temp.code(public.marking_settings_set(pg_temp.k('e'), 'whole', pg_temp.finish('e') + interval '7 days', ' ab ')), 'reason_required',
  'of 3 characters or more');
select is(public.marking_settings_set(pg_temp.k('e'), 'whole', pg_temp.finish('e') + interval '7 days', 'Markers asked for more time'),
  jsonb_build_object('ok', true, 'mode', 'whole', 'deadline', pg_temp.finish('e') + interval '7 days'), 'with a reason it changes');
select tests.as_postgres();
select is((select mode::text || ' ' || (deadline = pg_temp.finish('e') + interval '7 days') from public.exam_marking where exam_id = pg_temp.k('e')),
  'whole true', 'the deadline is saved and the mode is unchanged');
select is((select count(*)::int from public.audit_log a where a.action = 'marking_settings_set' and a.target_id = pg_temp.k('e')
             and a.actor_id = pg_temp.uid('admin') and a.reason like '%deadline none -> %' and a.reason like '%reason: Markers asked for more time'), 1,
  'the audit row has the old and new deadline and the reason');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_settings_set(pg_temp.k('e'), 'whole', pg_temp.finish('e') + interval '7 days')), 'ok',
  'the same settings again need no reason');
select tests.as_postgres();
select is(pg_temp.audits('marking_settings_set', pg_temp.k('e')), 1, 'and write no audit row');
select is(pg_temp.audits('marking_settings_set', pg_temp.k('eq')), 1, 'the mode change before opening was audited');

-- ---------------------------------------------------------------------------------------------
-- deadline_must_follow_the_finish
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_settings_set(pg_temp.k('e0'), 'whole', pg_temp.finish('e0'))), 'invalid_input',
  'deadline_must_follow_the_finish: not at the finish');
select is(pg_temp.code(public.marking_settings_set(pg_temp.k('e0'), 'whole', pg_temp.finish('e0') - interval '1 day')), 'invalid_input',
  'nor before it');
select is(pg_temp.code(public.marking_settings_set(pg_temp.k('e0'), 'whole', pg_temp.finish('e0') + interval '1 minute')), 'ok',
  'a minute after it is fine');
select is(pg_temp.code(public.marking_settings_set(null, 'whole', null)), 'invalid_input', 'an exam is needed');
select is(pg_temp.code(public.marking_settings_set(pg_temp.k('e0'), null, null)), 'invalid_input', 'and a mode');
select is(pg_temp.code(public.marking_settings_set(gen_random_uuid(), 'whole', null)), 'not_found', 'of an exam that exists');
select tests.as_postgres();
select is((select deadline = pg_temp.finish('e0') + interval '1 minute' and opened_at is null from public.exam_marking where exam_id = pg_temp.k('e0')),
  true, 'the deadline is saved; marking has not opened');

-- ---------------------------------------------------------------------------------------------
-- close_stops_sync_and_reopen_resumes
-- ---------------------------------------------------------------------------------------------
-- h1's unit is held by m1, who has started marking it.
update public.marking_units set state = 'taken' where script_id = pg_temp.k('h1');
insert into public.marking_assignments (unit_id, marker_id, how, hold_until) values (pg_temp.unit('h1', '-'), pg_temp.uid('m1'), 'next', now() + interval '2 hours');
insert into public.markings (unit_id, marker_id) values (pg_temp.unit('h1', '-'), pg_temp.uid('m1'));
update public.scripts set state = 'marking' where id = pg_temp.k('h1');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_close(pg_temp.k('e'), 'ab')), 'reason_required', 'close_stops_sync_and_reopen_resumes: closing needs a reason');
select is(pg_temp.code(public.marking_close(pg_temp.k('e0'), 'Marking is finished')), 'marking_not_open', 'an exam that never opened cannot close');
select is(pg_temp.code(public.marking_reopen(pg_temp.k('e'), 'More scripts came in')), 'ok', 'reopening an exam that is open changes nothing');
select is(public.marking_close(pg_temp.k('e'), 'Marking is finished'), '{"ok": true, "already": false}'::jsonb, 'an admin closes marking');
select is(public.marking_close(pg_temp.k('e'), 'Marking is finished'), '{"ok": true, "already": true}'::jsonb, 'a second close says so');
select tests.as_postgres();
select is((select (closed_at = now()) and closed_by = pg_temp.uid('admin') from public.exam_marking where exam_id = pg_temp.k('e')), true,
  'closed_at and closed_by are set');
select is((select count(*)::int from public.audit_log where action = 'marking_closed' and target_id = pg_temp.k('e') and reason = 'Marking is finished'), 1,
  'one audit row with the reason');
select is(pg_temp.audits('marking_reopened', pg_temp.k('e')), 0, 'the reopen that changed nothing wrote no audit row');
insert into kv values ('k1', tests.verified_script(pg_temp.k('e')));
select is(array[pg_temp.why('k1'), pg_temp.why('h1')], array['marking_closed', 'marking_closed'], 'nothing is handed out once closed');
select is(public.marking_exam_sync(pg_temp.k('e'), null), 0, 'the sync makes nothing ready');
select is(pg_temp.st('k1'), 'verified', 'the new script stays verified');
select is((select u.state || ' ' || u.on_hold || ' ' || (select count(*) from public.marking_assignments a where a.unit_id = u.id and a.ended_at is null)
                  || ' ' || (select string_agg(m.status, ',') from public.markings m where m.unit_id = u.id)
           from public.marking_units u where u.script_id = pg_temp.k('h1')), 'taken false 1 in_progress',
  'closing ends nothing: the held unit keeps its holder and its marking');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_reopen(pg_temp.k('e'), ' ')), 'reason_required', 'reopening needs a reason');
select is(public.marking_reopen(pg_temp.k('e'), 'More scripts came in'), '{"ok": true, "already": false, "ready": 1}'::jsonb,
  'reopening makes the waiting script ready');
select tests.as_postgres();
select is(array[pg_temp.st('k1'), pg_temp.units('k1')], array['ready_to_mark', '-'], 'k1 is ready to mark');
select is((select closed_at is null and closed_by is null from public.exam_marking where exam_id = pg_temp.k('e')), true, 'closed_at is cleared');
select is((select count(*)::int from public.audit_log where action = 'marking_reopened' and target_id = pg_temp.k('e') and reason = 'More scripts came in'), 1,
  'one audit row with the reason');

-- ---------------------------------------------------------------------------------------------
-- cancelled_booking_puts_units_on_hold
-- ---------------------------------------------------------------------------------------------
update public.bookings set status = 'cancelled' where id = (select booking_id from public.scripts where id = pg_temp.k('h1'));
select is(pg_temp.st('h1'), 'withdrawn', 'cancelled_booking_puts_units_on_hold: the cancelled booking withdraws its script');
select is((select u.on_hold || ' ' || u.hold_reason from public.marking_units u where u.script_id = pg_temp.k('h1')), 'true withdrawn',
  'its unit is on hold, withdrawn');
select is((select string_agg((a.marker_id = pg_temp.uid('m1')) || ' ' || (a.ended_at = now()) || ' ' || a.end_reason, ',')
           from public.marking_assignments a where a.unit_id = pg_temp.unit('h1', '-')), 'true true withdrawn', 'the marker''s hold ends, withdrawn');
select is((select string_agg(m.status, ',') from public.markings m where m.unit_id = pg_temp.unit('h1', '-')), 'in_progress', 'their marking is kept');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.script_void(pg_temp.k('c1'), 'Scanned for the wrong exam')), 'ok', 'an admin voids the ready centre script');
select tests.as_postgres();
select is((select u.on_hold || ' ' || u.hold_reason || ' ' || u.state from public.marking_units u where u.script_id = pg_temp.k('c1')), 'true withdrawn open',
  'its unit is on hold too');
select is(public.marking_exam_sync(pg_temp.k('e'), null), 0, 'the sync does not bring them back');

-- ---------------------------------------------------------------------------------------------
-- tick_syncs_open_exams
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_open(pg_temp.k('et'))), 'ok', 'tick_syncs_open_exams: exam et opens');
select tests.as_postgres();
insert into kv values ('t1', tests.verified_script(pg_temp.k('et')));
insert into kv values ('t0', tests.verified_script(pg_temp.k('e0')));
insert into kv values ('tq', tests.verified_script(pg_temp.k('eq')));
update public.exam_marking set closed_at = now(), closed_by = pg_temp.uid('admin') where exam_id = pg_temp.k('eq');
select lives_ok($$ select public.marking_tick() $$, 'the tick runs');
select is(array[pg_temp.st('t1'), pg_temp.units('t1')], array['ready_to_mark', '-'], 'it makes a verified script of an open exam ready');
select is(array[pg_temp.st('t0'), pg_temp.st('tq')], array['verified', 'verified'], 'not one of an exam not opened, nor of a closed one');
select is((select schedule || ' | ' || command from cron.job where jobname = 'marking-tick'), '* * * * * | select public.marking_tick()',
  'the marking-tick job runs it every minute');
select is((select count(*)::int from cron.job where jobname = 'marking-tick'), 1, 'once');

-- ---------------------------------------------------------------------------------------------
-- added_question_leaves_withdrawn_scripts_alone (exam_structure_save after opening, Rulings R1 and R9)
-- ---------------------------------------------------------------------------------------------
-- In exam et, m1 has marked t1 and t2: each unit submitted, its marking submitted, the hold ended. Then t2's booking
-- is cancelled, and an admin adds question 3.
insert into kv values ('t2', tests.verified_script(pg_temp.k('et')));
select is(public.marking_exam_sync(pg_temp.k('et'), null), 1, 'added_question_leaves_withdrawn_scripts_alone: t2 is made ready');
update public.marking_units set state = 'submitted' where script_id in (pg_temp.k('t1'), pg_temp.k('t2'));
insert into public.markings (unit_id, marker_id, status, total, submitted_at)
select u.id, pg_temp.uid('m1'), 'submitted', 8, now() from public.marking_units u where u.script_id in (pg_temp.k('t1'), pg_temp.k('t2'));
insert into public.marking_assignments (unit_id, marker_id, how, hold_until, created_at, ended_at, end_reason)
select u.id, pg_temp.uid('m1'), 'next', now() + interval '1 hour', now() - interval '1 hour', now(), 'submitted'
from public.marking_units u where u.script_id in (pg_temp.k('t1'), pg_temp.k('t2'));
select public.marking_script_state(pg_temp.k('t1'));
select public.marking_script_state(pg_temp.k('t2'));
select is(array[pg_temp.st('t1'), pg_temp.st('t2')], array['marked', 'marked'], 'both scripts are marked');
update public.bookings set status = 'cancelled' where id = (select booking_id from public.scripts where id = pg_temp.k('t2'));
select is((select s.state || ' ' || u.on_hold || ' ' || u.hold_reason from public.scripts s join public.marking_units u on u.script_id = s.id
           where s.id = pg_temp.k('t2')), 'withdrawn true withdrawn', 't2''s booking is cancelled: withdrawn, its piece on hold');
-- What exam_structure_get gives, as a draft to save again (as 040 and the editor make it), with question 3 added.
create function pg_temp.with_q3(g jsonb) returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'groups', '[]'::jsonb, 'option_groups', '[]'::jsonb,
    'questions', (select jsonb_agg(jsonb_build_object('id', x -> 'id', 'key', x ->> 'id', 'parent_key', x -> 'parent_id',
        'label', x -> 'label', 'max_mark', x -> 'max_mark', 'mark_step', x -> 'mark_step', 'levels', x -> 'levels', 'pages', x -> 'pages',
        'areas', x -> 'areas', 'group_key', null, 'option_group_key', null, 'guidance', x -> 'guidance', 'alternatives', x -> 'alternatives',
        'points', '[]'::jsonb) order by o)
      from jsonb_array_elements(g -> 'questions') with ordinality t(x, o))
      || jsonb_build_array(jsonb_build_object('id', null, 'key', 'new3', 'parent_key', null, 'label', '3', 'max_mark', 2, 'mark_step', 1,
           'levels', false, 'pages', '[3]'::jsonb, 'areas', '[]'::jsonb, 'group_key', null, 'option_group_key', null,
           'guidance', null, 'alternatives', null, 'points', '[]'::jsonb))) $$;
grant execute on function pg_temp.with_q3(jsonb) to public;
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.exam_structure_save(pg_temp.k('et'), pg_temp.with_q3(public.exam_structure_get(pg_temp.k('et'))), 'Question 3 was left out')),
  'ok', 'an admin adds question 3 after marking has opened');
select tests.as_postgres();
select is((select s.state || ' ' || u.state || ' ' || (select count(*) from public.marking_assignments a where a.unit_id = u.id and a.ended_at is null)
                  || ' ' || (select string_agg(m.status, ',') from public.markings m where m.unit_id = u.id)
           from public.scripts s join public.marking_units u on u.script_id = s.id where s.id = pg_temp.k('t1')),
  'marking taken 1 in_progress', 't1''s piece is reopened for m1 and the script is being marked again');
select is((select s.state || ' ' || u.state || ' ' || u.on_hold || ' ' || u.hold_reason
                  || ' ' || (select count(*) from public.marking_assignments a where a.unit_id = u.id and a.ended_at is null)
                  || ' ' || (select string_agg(m.status, ',') from public.markings m where m.unit_id = u.id)
           from public.scripts s join public.marking_units u on u.script_id = s.id where s.id = pg_temp.k('t2')),
  'withdrawn submitted true withdrawn 0 submitted', 'the withdrawn script''s piece stays submitted and on hold, with no holder, and the script stays withdrawn');

-- ---------------------------------------------------------------------------------------------
-- teacher_and_corrector_forbidden
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('teacher'));
select is(array[pg_temp.code(public.marking_settings_set(pg_temp.k('e0'), 'whole', null)), pg_temp.code(public.marking_exam_get(pg_temp.k('e'))),
                pg_temp.code(public.marking_open(pg_temp.k('e0'))), pg_temp.code(public.marking_close(pg_temp.k('e'), 'Marking is finished')),
                pg_temp.code(public.marking_reopen(pg_temp.k('eq'), 'More scripts came in'))],
  array['forbidden', 'forbidden', 'forbidden', 'forbidden', 'forbidden'], 'teacher_and_corrector_forbidden: a teacher of the subject is refused');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m1'));
select is(array[pg_temp.code(public.marking_settings_set(pg_temp.k('e0'), 'whole', null)), pg_temp.code(public.marking_exam_get(pg_temp.k('e'))),
                pg_temp.code(public.marking_open(pg_temp.k('e0'))), pg_temp.code(public.marking_close(pg_temp.k('e'), 'Marking is finished')),
                pg_temp.code(public.marking_reopen(pg_temp.k('eq'), 'More scripts came in'))],
  array['forbidden', 'forbidden', 'forbidden', 'forbidden', 'forbidden'], 'so is an approved corrector');
select tests.as_postgres();
select is((select closed_at is not null from public.exam_marking where exam_id = pg_temp.k('eq')), true, 'nothing changed');
select is(pg_temp.audits('marking_opened', pg_temp.k('e0')), 0, 'and nothing was audited');
select is(array(select f from unnest(array[
    'public.marking_script_busy(uuid)', 'public.marking_script_waiting(uuid, timestamptz)', 'public.marking_script_blocked(uuid, timestamptz)',
    'public.marking_exam_sync(uuid, timestamptz)', 'public.marking_script_state(uuid)', 'public.marking_tick()',
    'public.marking_on_script_state()']) f
  where has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute')
     or has_function_privilege('service_role', f, 'execute')), '{}'::text[],
  'the internal functions cannot be called from the API, nor by the service role');
select is((select j.username from cron.job j where j.jobname = 'marking-tick'),
  (select p.proowner::regrole::text from pg_proc p where p.oid = 'public.marking_tick()'::regprocedure),
  'the marking-tick job runs as the owner of marking_tick, who may still run it');
select is(array(select f from unnest(array[
    'public.marking_settings_set(uuid, public.marking_mode, timestamptz, text)', 'public.marking_exam_get(uuid, timestamptz)',
    'public.marking_open(uuid)', 'public.marking_close(uuid, text)', 'public.marking_reopen(uuid, text)']) f
  where has_function_privilege('anon', f, 'execute') or not has_function_privilege('authenticated', f, 'execute')), '{}'::text[],
  'the admin functions are for signed-in users only');

select * from finish();
rollback;
