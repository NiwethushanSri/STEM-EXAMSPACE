begin;
create extension if not exists pgtap with schema extensions;
select plan(47);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Subject subj: correctors m1, m2, m3, the subject's teacher and a tutor all have an approval row (the
-- tutor's is a stray row: tutors never mark). teacher2 teaches subj2. Exam e (tests.marking_exam) with the test
-- structure and one verified home script x (tests.verified_script); on x: a unit u, m1's live marking mk with a mark
-- for question 1 and a tick on page 1. A declared conflict: m2 with student s2.
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values
  ('admin', tests.create_user('admin', 'active')),
  ('m1', tests.create_user('corrector', 'active')),
  ('m2', tests.create_user('corrector', 'active')),
  ('m3', tests.create_user('corrector', 'active')),
  ('teacher', tests.create_user('teacher', 'active')),
  ('teacher2', tests.create_user('teacher', 'active')),
  ('tutor', tests.create_user('tutor', 'active')),
  ('s1', tests.create_user('student', 'active')),
  ('s2', tests.create_user('student', 'active'));
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
create function pg_temp.subj(p text) returns bigint language sql stable as $$
  select id from public.subjects where name = case p when 'subj' then 'ZZ Marking schema' else 'ZZ Marking other' end $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.subj(text) to public;

-- The marking tables.
create temp table mt (t text primary key);
grant select on mt to public;
insert into mt values ('exam_marking'), ('question_groups'), ('exam_option_groups'), ('exam_questions'), ('mark_scheme_points'),
  ('exam_mark_scheme_files'), ('marker_approvals'), ('marker_conflicts'), ('marking_units'), ('marking_unit_exclusions'),
  ('markings'), ('marking_assignments'), ('question_marks'), ('question_mark_history'), ('page_annotations'), ('marking_alerts');

insert into public.subjects (name, kind) values ('ZZ Marking schema', 'school'), ('ZZ Marking other', 'school');
insert into public.teacher_subjects values (pg_temp.uid('teacher'), pg_temp.subj('subj')), (pg_temp.uid('teacher2'), pg_temp.subj('subj2'));
insert into public.marker_approvals (marker_id, subject_id, approved_by, approved_at)
select pg_temp.uid(t.m), pg_temp.subj('subj'), pg_temp.uid('admin'), now()
from (values ('m1'), ('m2'), ('m3'), ('teacher'), ('tutor')) t(m);

insert into kv values ('e', tests.marking_exam(pg_temp.subj('subj')));
insert into kv values ('x', tests.verified_script(pg_temp.k('e')));
select tests.structure(pg_temp.k('e'));
insert into kv select 'q1', q.id from public.exam_questions q where q.exam_id = pg_temp.k('e') and q.parent_id is null and q.label = '1';
insert into kv select 'p1', l.page_id from public.script_page_links l where l.script_id = pg_temp.k('x') and l.copy_page = 1;
with i as (insert into public.marking_units (script_id, exam_id) values (pg_temp.k('x'), pg_temp.k('e')) returning id)
insert into kv select 'u', id from i;
with i as (insert into public.markings (unit_id, marker_id) values (pg_temp.k('u'), pg_temp.uid('m1')) returning id)
insert into kv select 'mk', id from i;
insert into public.question_marks (marking_id, question_id, mark) values (pg_temp.k('mk'), pg_temp.k('q1'), 2);
insert into public.page_annotations (marking_id, page_id, page_rotation, kind, x, y, question_id)
values (pg_temp.k('mk'), pg_temp.k('p1'), 0, 'tick', 0.5, 0.5, pg_temp.k('q1'));
insert into public.marker_conflicts (marker_id, student_id, note, recorded_by, recorded_at)
values (pg_temp.uid('m2'), pg_temp.uid('s2'), 'Neighbour', pg_temp.uid('admin'), now());

-- Row counts of the five tables named in marker_selects_nothing_directly, as the current user.
create function pg_temp.counts() returns text language sql stable as $$
  select concat_ws('/', (select count(*) from public.marking_units), (select count(*) from public.markings),
    (select count(*) from public.question_marks), (select count(*) from public.page_annotations),
    (select count(*) from public.marker_conflicts)) $$;
-- Rows of every marking table together, as the current user.
create function pg_temp.all_rows() returns bigint language sql stable as $$
  select (select count(*) from public.exam_marking) + (select count(*) from public.question_groups)
    + (select count(*) from public.exam_option_groups) + (select count(*) from public.exam_questions)
    + (select count(*) from public.mark_scheme_points) + (select count(*) from public.exam_mark_scheme_files)
    + (select count(*) from public.marker_approvals) + (select count(*) from public.marker_conflicts)
    + (select count(*) from public.marking_units) + (select count(*) from public.marking_unit_exclusions)
    + (select count(*) from public.markings) + (select count(*) from public.marking_assignments)
    + (select count(*) from public.question_marks) + (select count(*) from public.question_mark_history)
    + (select count(*) from public.page_annotations) + (select count(*) from public.marking_alerts) $$;
grant execute on function pg_temp.counts(), pg_temp.all_rows() to public;

-- ---------------------------------------------------------------------------------------------
-- marking_tables_have_rls
-- ---------------------------------------------------------------------------------------------
select is((select count(*)::int from pg_class k join pg_namespace n on n.oid = k.relnamespace
  where n.nspname = 'public' and k.relkind = 'r' and k.relrowsecurity and k.relname in (select t from mt)),
  16, 'marking_tables_have_rls: the 16 marking tables exist with RLS enabled');
select is((select concat_ws('/', count(*) filter (where p.cmd = 'SELECT' and p.roles = '{authenticated}'
                                                    and p.qual = '( SELECT is_staff_admin() AS is_staff_admin)'),
                            count(*), count(distinct p.tablename))
           from pg_policies p where p.schemaname = 'public' and p.tablename in (select t from mt)),
  '16/16/16', 'each has exactly one policy: select, for staff admins only');
select is((select count(*)::int from mt, unnest(array['insert', 'update', 'delete', 'truncate']) pr,
             unnest(array['anon', 'authenticated']) ro
           where has_table_privilege(ro, 'public.' || mt.t, pr)), 0, 'no direct writes for anon or authenticated');
select is((select count(*)::int from mt where has_table_privilege('anon', 'public.' || mt.t, 'select')), 0, 'anon reads none of them');
select is(has_sequence_privilege('authenticated', 'public.question_mark_history_id_seq', 'usage'), false,
  'the history sequence is not usable by signed-in users');
select is((select concat_ws('/', b.public, b.file_size_limit, b.allowed_mime_types::text) from storage.buckets b where b.id = 'mark-schemes'),
  'f/20971520/{application/pdf}', 'bucket mark-schemes: private, 20 MB, PDF only');
select enum_has_labels('public', 'marking_kind', array['live', 'second', 'seed', 'practice', 'remark'], 'marking_kind has its five kinds');
select enum_has_labels('public', 'marking_mode', array['whole', 'by_question'], 'marking_mode is whole or by question');
select is((select string_agg(column_name || ':' || data_type, ', ' order by column_name) from information_schema.columns
           where table_schema = 'public' and table_name = 'scripts' and column_name like 'taken_back%'),
  'taken_back_at:timestamp with time zone, taken_back_by:uuid, taken_back_reason:text', 'scripts record a take-back');

-- ---------------------------------------------------------------------------------------------
-- marker_selects_nothing_directly
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.counts(), '0/0/0/0/0',
  'marker_selects_nothing_directly: an approved corrector reads no marking units, markings, marks, annotations or conflicts');
select is(pg_temp.all_rows(), 0::bigint, 'nor a row of any other marking table');
select tests.as_postgres();
select tests.as_user(pg_temp.uid('teacher'));
select is(pg_temp.all_rows(), 0::bigint, 'nor does the subject''s teacher');
select tests.as_postgres();
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.counts(), '1/1/1/1/1', 'staff admins read them (the rows exist)');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- no_direct_writes
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('m3'));
select throws_ok($$insert into public.markings (unit_id, kind, marker_id) values (pg_temp.k('u'), 'seed', pg_temp.uid('m3'))$$,
  '42501', null, 'no_direct_writes: a marker cannot insert a marking');
select tests.as_postgres();
select tests.as_user(pg_temp.uid('admin'));
select throws_ok($$update public.markings set total = 1$$, '42501', null, 'nor can an admin change one directly');
select tests.as_postgres();
select is((select count(*)::int
           from unnest(array['public.is_marker_for(uuid, bigint)', 'public.is_lead_for(uuid, bigint)',
                             'public.structure_can_edit(uuid, uuid)', 'public.marking_marker_blocked(uuid, uuid)']) f,
                unnest(array['anon', 'authenticated']) ro
           where has_function_privilege(ro, f, 'execute')), 0, 'the four predicates are internal: no grant to anon or authenticated');

-- ---------------------------------------------------------------------------------------------
-- one_lead_per_subject
-- ---------------------------------------------------------------------------------------------
select lives_ok($$update public.marker_approvals set lead = true where marker_id = pg_temp.uid('m1') and subject_id = pg_temp.subj('subj')$$,
  'one_lead_per_subject: m1 is the lead marker of the subject');
select throws_ok($$update public.marker_approvals set lead = true where marker_id = pg_temp.uid('m2') and subject_id = pg_temp.subj('subj')$$,
  '23505', null, 'a second lead for the same subject is refused');
select lives_ok($$insert into public.marker_approvals (marker_id, subject_id, lead, approved_at)
                  values (pg_temp.uid('m2'), pg_temp.subj('subj2'), true, now())$$, 'the lead of another subject is fine');

-- ---------------------------------------------------------------------------------------------
-- one_holder_per_unit_and_kind
-- ---------------------------------------------------------------------------------------------
select lives_ok($$insert into public.marking_assignments (unit_id, marker_id, how, hold_until)
                  values (pg_temp.k('u'), pg_temp.uid('m1'), 'next', now() + interval '2 hours')$$,
  'one_holder_per_unit_and_kind: m1 holds the unit');
select throws_ok($$insert into public.marking_assignments (unit_id, marker_id, how, assigned_by)
                   values (pg_temp.k('u'), pg_temp.uid('m2'), 'assigned', pg_temp.uid('admin'))$$,
  '23505', null, 'a second open live assignment of the same unit is refused');
update public.marking_assignments set ended_at = now(), end_reason = 'given_back' where unit_id = pg_temp.k('u') and marker_id = pg_temp.uid('m1');
select lives_ok($$insert into public.marking_assignments (unit_id, marker_id, how, assigned_by)
                  values (pg_temp.k('u'), pg_temp.uid('m2'), 'assigned', pg_temp.uid('admin'))$$,
  'once m1''s assignment has ended, m2 can hold it');
select is((select concat_ws('/', count(*) filter (where ended_at is null), count(*)) from public.marking_assignments where unit_id = pg_temp.k('u')),
  '1/2', 'one holder at a time; the ended assignment stays as a record');

-- The same guard for markings: one live marking per unit unless set aside; seed passes may have many markers.
select throws_ok($$insert into public.markings (unit_id, marker_id) values (pg_temp.k('u'), pg_temp.uid('m2'))$$,
  '23505', null, 'one_live_marking_per_unit: a second live marking of the unit is refused while m1''s stands');
update public.markings set status = 'set_aside', set_aside_at = now(), set_aside_reason = 'given_back' where id = pg_temp.k('mk');
select lives_ok($$insert into public.markings (unit_id, marker_id) values (pg_temp.k('u'), pg_temp.uid('m2'))$$,
  'once m1''s marking is set aside, m2 can mark it');
select lives_ok($$insert into public.markings (unit_id, kind, marker_id) values (pg_temp.k('u'), 'seed', pg_temp.uid('m1')), (pg_temp.k('u'), 'seed', pg_temp.uid('m3'))$$,
  'seed passes may have many markers on one unit');

-- ---------------------------------------------------------------------------------------------
-- second_kind_can_hold_the_same_unit
-- ---------------------------------------------------------------------------------------------
select lives_ok($$insert into public.marking_assignments (unit_id, kind, marker_id, how, assigned_by)
                  values (pg_temp.k('u'), 'second', pg_temp.uid('m3'), 'assigned', pg_temp.uid('admin'))$$,
  'second_kind_can_hold_the_same_unit: a second-pass holder beside the live holder is allowed');
select throws_ok($$insert into public.marking_assignments (unit_id, kind, marker_id, how, assigned_by)
                   values (pg_temp.k('u'), 'second', pg_temp.uid('m1'), 'assigned', pg_temp.uid('admin'))$$,
  '23505', null, 'but not two holders of the second pass');

-- ---------------------------------------------------------------------------------------------
-- suspended_marker_is_not_a_marker
-- ---------------------------------------------------------------------------------------------
select is(public.is_marker_for(pg_temp.uid('m1'), pg_temp.subj('subj')), true, 'an active approved corrector is a marker of the subject');
select is(public.is_marker_for(pg_temp.uid('teacher'), pg_temp.subj('subj')), true, 'so is an active approved teacher');
select is(public.is_marker_for(pg_temp.uid('m1'), pg_temp.subj('subj2')), false, 'not of a subject they are not approved for');
select is(public.is_marker_for(pg_temp.uid('tutor'), pg_temp.subj('subj')), false, 'a tutor with an approval row is not a marker');
select is(concat_ws('/', public.is_lead_for(pg_temp.uid('m1'), pg_temp.subj('subj')), public.is_lead_for(pg_temp.uid('m3'), pg_temp.subj('subj')),
                    public.is_lead_for(pg_temp.uid('m1'), pg_temp.subj('subj2'))),
  't/f/f', 'is_lead_for: the lead of the subject only');
update public.profiles set status = 'suspended' where id = pg_temp.uid('m1');
select is(concat_ws('/', public.is_marker_for(pg_temp.uid('m1'), pg_temp.subj('subj')), public.is_lead_for(pg_temp.uid('m1'), pg_temp.subj('subj'))),
  'f/f', 'suspended_marker_is_not_a_marker: suspended, m1 is neither a marker nor the lead');
select is(concat_ws('/', public.structure_can_edit(pg_temp.uid('admin'), pg_temp.k('e')), public.structure_can_edit(pg_temp.uid('teacher'), pg_temp.k('e')),
                    public.structure_can_edit(pg_temp.uid('teacher2'), pg_temp.k('e')), public.structure_can_edit(pg_temp.uid('m3'), pg_temp.k('e')),
                    public.structure_can_edit(pg_temp.uid('admin'), gen_random_uuid())),
  't/t/f/f/f', 'structure_can_edit: an admin or a teacher of the subject; not another teacher, a corrector, or an unknown exam');

-- ---------------------------------------------------------------------------------------------
-- tutor_link_or_declared_conflict_blocks
-- ---------------------------------------------------------------------------------------------
select is(public.marking_marker_blocked(pg_temp.uid('m3'), pg_temp.uid('s1')), false, 'tutor_link_or_declared_conflict_blocks: no link and no conflict');
insert into public.tutor_students values (pg_temp.uid('m3'), pg_temp.uid('s1'));
select is(public.marking_marker_blocked(pg_temp.uid('m3'), pg_temp.uid('s1')), true, 'a tutor_students row with the marker as tutor blocks');
select is(public.marking_marker_blocked(pg_temp.uid('m2'), pg_temp.uid('s2')), true, 'a declared conflict blocks');
select is(concat_ws('/', public.marking_marker_blocked(pg_temp.uid('m3'), pg_temp.uid('s2')), public.marking_marker_blocked(pg_temp.uid('m2'), pg_temp.uid('s1'))),
  'f/f', 'neither blocks another marker');

-- ---------------------------------------------------------------------------------------------
-- fixtures_make_a_verified_script
-- ---------------------------------------------------------------------------------------------
select is((select concat_ws('/', e.status, e.exam_code ~ '^[A-Z0-9-]{3,40}$', e.starts_at + make_interval(mins => e.duration_minutes) = now() - interval '2 days',
                            count(p.id), min(p.page_count), bool_and(p.pages_reviewed_at is not null))
           from public.exams e left join public.exam_papers p on p.exam_id = e.id and p.kind = 'paper' and p.superseded_at is null
           where e.id = pg_temp.k('e') group by e.id),
  'published/t/t/1/3/t', 'fixtures_make_a_verified_script: marking_exam is published, has a code, one current reviewed 3-page paper and finished 2 days ago');
insert into kv values ('e_default', tests.marking_exam());
select is((select subject_id from public.exams where id = pg_temp.k('e_default')), 1::bigint, 'marking_exam defaults to subject 1');
select is((select concat_ws('/', s.state, s.complete, s.source, s.version, s.late, s.received_at is not null) from public.scripts s where s.id = pg_temp.k('x')),
  'verified/t/home/1/f/t', 'verified_script: a complete verified home script, version 1');
select is((select concat_ws('/', count(*), count(*) filter (where p.state = 'matched' and p.full_path is not null and p.marking_path is not null
                                                              and p.replaced_at is null and p.copy_page = l.copy_page),
                            string_agg(l.copy_page::text, ',' order by l.copy_page))
           from public.script_page_links l join public.scripts s on s.id = l.script_id and s.version = l.version
           join public.script_pages p on p.id = l.page_id where l.script_id = pg_temp.k('x')),
  '3/3/1,2,3', 'its three pages are linked, matched, and each has a full and a marking picture');
select is((select concat_ws('/', pr.status, pr.first_name <> '', pr.last_name <> '', d.index_number is not null, b.status, b.sitting,
                            c.page_count >= 3, u.state, u.kind, h.state, j.state)
           from public.scripts s join public.bookings b on b.id = s.booking_id
           join public.profiles pr on pr.id = b.student_id join public.student_details d on d.profile_id = pr.id
           join public.paper_copies c on c.booking_id = b.id
           join public.script_versions v on v.script_id = s.id and v.version = s.version
           join public.home_submissions h on h.id = v.submission_id
           join public.script_uploads u on u.submission_id = h.id
           join public.processing_jobs j on j.upload_id = u.id
           where s.id = pg_temp.k('x')),
  'active/t/t/t/paid/home/t/processed/home_pdf/received/done',
  'an active student with a name and index number, a paid home booking, a copy, a received hand-in and a processed upload');
select public.script_evaluate_at(pg_temp.k('x'), now());
select is((select concat_ws('/', s.state, s.complete) from public.scripts s where s.id = pg_temp.k('x')), 'verified/t',
  'Phase 2''s own check (script_evaluate_at) keeps it verified and complete');
insert into kv values ('xc', tests.verified_script(pg_temp.k('e'), 'centre', 5));
select public.script_evaluate_at(pg_temp.k('xc'), now());
select is((select concat_ws('/', s.state, s.complete, s.source, b.sitting, b.centre_id is not null, v.reason, u.kind, u.batch_id is not null,
                            (select count(*) from public.script_page_links l where l.script_id = s.id and l.version = s.version))
           from public.scripts s join public.bookings b on b.id = s.booking_id
           join public.script_versions v on v.script_id = s.id and v.version = s.version
           join public.script_uploads u on u.id = v.upload_id
           where s.id = pg_temp.k('xc')),
  'verified/t/centre/centre/t/scan_upload/scan_file/t/5', 'a centre script of 5 pages from a scan file is verified and complete too');
select is((select string_agg(coalesce(pq.label || '(' || q.label || ')', q.label) || ':' || coalesce(q.max_mark::text, '-'), ' '
                             order by coalesce(pq.position, q.position), pq.position nulls first, q.position)
           from public.exam_questions q left join public.exam_questions pq on pq.id = q.parent_id where q.exam_id = pg_temp.k('e')),
  '1:3.0 2:- 2(a):2.0 2(b):5.0', 'structure: questions 1, 2(a) and 2(b) with maxima 3, 2 and 5');

select * from finish();
rollback;
