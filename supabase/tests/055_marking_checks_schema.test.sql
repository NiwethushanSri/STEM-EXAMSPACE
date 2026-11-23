begin;
create extension if not exists pgtap with schema extensions;
select plan(106);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Admins admin (Ada Checker) and admin2 (Bea Second). Subjects:
--   one: one approved marker, solo, who is also its lead; the teacher teaches it.
--   two: two approved markers, m1 and lead2 (its lead).
--   none: no approved marker.
--   open: o1 approved, no lead (more are approved in the opening tests).
--   fix: for the fixtures test.
-- corr is a corrector approved for nothing. Exams (tests.marking_exam, finished 2 days ago, with the test structure):
-- e1 (one), e2 and ed (two), e0 (none), eo, eo2 and eo3 (open); e1, e2, ed and e0 have no exam_marking row, as an
-- exam never saved (the fixture's row is deleted), so the column defaults apply. ex (two) holds one row of each new
-- table, for the select test.
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
create function pg_temp.subj(p text) returns bigint language sql stable as $$ select id from public.subjects where name = 'ZZ Checks ' || p $$;
-- A function's answer: 'ok', or its code.
create function pg_temp.code(j jsonb) returns text language sql immutable as $$
  select case when (j ->> 'ok')::boolean then 'ok' else coalesce(j ->> 'code', 'none') end $$;
-- The six settings, the defaults unless named.
create function pg_temp.s(dm boolean default true, sp int default 10, tp int default 10, se boolean default true, sv int default 10,
  pr boolean default true) returns jsonb language sql immutable as $$
  select jsonb_build_object('double_marking', dm, 'sample_percent', sp, 'tolerance_percent', tp, 'seeds', se, 'seed_every', sv, 'practice', pr) $$;
-- An exam's saved checks: 'double/sample/tolerance/seeds/gap/practice', or 'none' without a row.
create function pg_temp.saved(p text) returns text language sql stable as $$
  select coalesce((select concat_ws('/', m.double_marking, m.sample_percent, m.tolerance_percent, m.seeds, m.seed_every, m.practice)
                   from public.exam_marking m where m.exam_id = pg_temp.k(p)), 'none') $$;
-- How many audit rows of this action concern this target.
create function pg_temp.audits(p_action text, p_target uuid) returns int language sql stable as $$
  select count(*)::int from public.audit_log a where a.action = p_action and a.target_id = p_target $$;
-- Row counts of the five tables of marker_and_lead_select_nothing_directly, as the current user.
create function pg_temp.counts() returns text language sql stable as $$
  select concat_ws('/', (select count(*) from public.final_marks), (select count(*) from public.marking_reviews),
    (select count(*) from public.marking_standards), (select count(*) from public.marking_standard_marks),
    (select count(*) from public.exam_markers)) $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.r(text), pg_temp.subj(text), pg_temp.code(jsonb),
  pg_temp.s(boolean, int, int, boolean, int, boolean), pg_temp.counts() to public;

insert into public.subjects (name, kind)
values ('ZZ Checks one', 'school'), ('ZZ Checks two', 'school'), ('ZZ Checks none', 'school'), ('ZZ Checks open', 'school'),
  ('ZZ Checks fix', 'school');
insert into c values
  ('admin', tests.create_user('admin', 'active')),
  ('admin2', tests.create_user('admin', 'active')),
  ('teacher', tests.create_user('teacher', 'active')),
  ('corr', tests.create_user('corrector', 'active')),
  ('solo', tests.marker(pg_temp.subj('one'), true)),
  ('m1', tests.marker(pg_temp.subj('two'))),
  ('lead2', tests.marker(pg_temp.subj('two'), true)),
  ('o1', tests.marker(pg_temp.subj('open')));
update public.profiles set first_name = 'Ada', last_name = 'Checker' where id = pg_temp.uid('admin');
update public.profiles set first_name = 'Bea', last_name = 'Second' where id = pg_temp.uid('admin2');
insert into public.teacher_subjects values (pg_temp.uid('teacher'), pg_temp.subj('one'));

insert into kv values
  ('e1', tests.marking_exam(pg_temp.subj('one'))), ('e2', tests.marking_exam(pg_temp.subj('two'))),
  ('ed', tests.marking_exam(pg_temp.subj('two'))), ('e0', tests.marking_exam(pg_temp.subj('none'))),
  ('eo', tests.marking_exam(pg_temp.subj('open'))), ('eo2', tests.marking_exam(pg_temp.subj('open'))),
  ('eo3', tests.marking_exam(pg_temp.subj('open'))), ('ex', tests.marking_exam(pg_temp.subj('two')));
select tests.structure(pg_temp.k(x)) from unnest(array['e1', 'eo', 'eo2', 'eo3', 'ex']) x;
delete from public.exam_marking where exam_id in (pg_temp.k('e1'), pg_temp.k('e2'), pg_temp.k('ed'), pg_temp.k('e0'));
insert into kv values ('x1', tests.verified_script(pg_temp.k('e1'))), ('xo', tests.verified_script(pg_temp.k('eo'))),
  ('xx', tests.verified_script(pg_temp.k('ex')));

-- ---------------------------------------------------------------------------------------------
-- new_tables_have_rls
-- ---------------------------------------------------------------------------------------------
create temp table nt (t text primary key);
grant select on nt to public;
insert into nt values ('exam_markers'), ('marking_standards'), ('marking_standard_marks'), ('marking_reviews'), ('final_marks'),
  ('final_mark_history');
select is((select count(*)::int from pg_class k join pg_namespace n on n.oid = k.relnamespace
  where n.nspname = 'public' and k.relkind = 'r' and k.relrowsecurity and k.relname in (select t from nt)),
  6, 'new_tables_have_rls: the six new tables exist with RLS enabled');
select is((select concat_ws('/', count(*) filter (where p.cmd = 'SELECT' and p.roles = '{authenticated}'
                                                    and p.qual = '( SELECT is_staff_admin() AS is_staff_admin)'),
                            count(*), count(distinct p.tablename))
           from pg_policies p where p.schemaname = 'public' and p.tablename in (select t from nt)),
  '6/6/6', 'each has exactly one policy: select, for staff admins only');
select is((select count(*)::int from nt, unnest(array['insert', 'update', 'delete', 'truncate']) pr,
             unnest(array['anon', 'authenticated']) ro
           where has_table_privilege(ro, 'public.' || nt.t, pr)), 0, 'no direct writes for anon or authenticated');
select is((select count(*)::int from nt where has_table_privilege('anon', 'public.' || nt.t, 'select')), 0, 'anon reads none of them');
select is(has_sequence_privilege('authenticated', 'public.final_mark_history_id_seq', 'usage'), false,
  'the final mark history sequence is not usable by signed-in users');
select is((select string_agg(column_name || ':' || data_type, ', ' order by column_name) from information_schema.columns
           where table_schema = 'public' and table_name = 'marking_units'
             and column_name in ('sample_draw', 'second_wanted', 'check_state', 'checked_at', 'final_marking_id')),
  'check_state:text, checked_at:timestamp with time zone, final_marking_id:uuid, sample_draw:double precision, second_wanted:boolean',
  'a piece has its sample draw, whether a second marking is wanted, its check state, when it was checked and its final marking');
select is((select string_agg(column_name || ':' || data_type, ', ' order by column_name) from information_schema.columns
           where table_schema = 'public' and table_name = 'markings' and column_name in ('sent_back_note', 'feedback_at')),
  'feedback_at:timestamp with time zone, sent_back_note:text', 'a marking has a note when sent back and when feedback was shown');
select lives_ok($$insert into public.marking_units (script_id, exam_id) values (pg_temp.k('xx'), pg_temp.k('ex'))$$,
  'a piece made for ex');
insert into kv select 'ux', u.id from public.marking_units u where u.script_id = pg_temp.k('xx');
select is((select u.sample_draw >= 0 and u.sample_draw < 1 and u.second_wanted is null and u.check_state is null
           from public.marking_units u where u.id = pg_temp.k('ux')), true,
  'gets a stored random draw in [0, 1); nothing is decided yet');
with m as (insert into public.markings (unit_id, marker_id) values (pg_temp.k('ux'), pg_temp.uid('m1')) returning id)
insert into kv select 'mx', id from m;
select lives_ok($$insert into public.marking_assignments (unit_id, marker_id, how, ended_at, end_reason)
  values (pg_temp.k('ux'), pg_temp.uid('m1'), 'next', now(), 'paused'),
         (pg_temp.k('ux'), pg_temp.uid('m1'), 'next', now(), 'sent_back'),
         (pg_temp.k('ux'), pg_temp.uid('m1'), 'next', now(), 'switched_off')$$,
  'an assignment may end paused, sent back or switched off');
select lives_ok($$insert into public.marking_unit_exclusions (unit_id, marker_id, reason) values (pg_temp.k('ux'), pg_temp.uid('lead2'), 'sent_back')$$,
  'a piece may be kept from a marker it was sent back from');
select throws_ok($$insert into public.marking_reviews (exam_id, unit_id, kind, marking_id) values (pg_temp.k('ex'), pg_temp.k('ux'), 'other', pg_temp.k('mx'))$$,
  '23514', null, 'a review is of a difference, a paused marker or the sample');

-- ---------------------------------------------------------------------------------------------
-- marker_and_lead_select_nothing_directly
-- ---------------------------------------------------------------------------------------------
insert into public.exam_markers (exam_id, marker_id, misses, until_seed) values (pg_temp.k('ex'), pg_temp.uid('m1'), 1, 4);
with s as (insert into public.marking_standards (exam_id, unit_id, use, set_by, created_at)
           values (pg_temp.k('ex'), pg_temp.k('ux'), 'practice', pg_temp.uid('lead2'), now()) returning id)
insert into kv select 'std', id from s;
insert into kv select 'q1', q.id from public.exam_questions q where q.exam_id = pg_temp.k('ex') and q.label = '1' and q.parent_id is null;
insert into public.marking_standard_marks (standard_id, question_id, mark) values (pg_temp.k('std'), pg_temp.k('q1'), 2);
insert into public.marking_reviews (exam_id, unit_id, kind, marking_id, opened_at)
values (pg_temp.k('ex'), pg_temp.k('ux'), 'difference', pg_temp.k('mx'), now());
insert into public.final_marks (unit_id, question_id, mark, source, set_at) values (pg_temp.k('ux'), pg_temp.k('q1'), 2, 'first', now());
insert into public.final_mark_history (unit_id, question_id, mark, not_attempted, source, changed_at)
values (pg_temp.k('ux'), pg_temp.k('q1'), 2, false, 'first', now());
select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.counts(), '0/0/0/0/0',
  'marker_and_lead_select_nothing_directly: an approved marker reads no final marks, reviews, standards, standard marks or exam markers');
select is((select count(*)::int from public.final_mark_history), 0, 'nor the final mark history');
select tests.as_postgres();
select tests.as_user(pg_temp.uid('lead2'));
select is(pg_temp.counts(), '0/0/0/0/0', 'nor does the subject''s lead marker');
select is((select count(*)::int from public.final_mark_history), 0, 'nor its history');
select tests.as_postgres();
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.counts() || '/' || (select count(*) from public.final_mark_history), '1/1/1/1/1/1', 'staff admins read them (the rows exist)');
select tests.as_postgres();
select throws_ok($$insert into public.marking_reviews (exam_id, unit_id, kind, marking_id, opened_at)
  values (pg_temp.k('ex'), pg_temp.k('ux'), 'paused_marker', pg_temp.k('mx'), now())$$,
  '23505', null, 'one open difference or paused-marker review per piece');
select lives_ok($$insert into public.marking_reviews (exam_id, unit_id, kind, marking_id, opened_at)
  values (pg_temp.k('ex'), pg_temp.k('ux'), 'sample', pg_temp.k('mx'), now())$$, 'a sample review may stand beside it');
select throws_ok($$insert into public.final_marks (unit_id, question_id, mark, not_attempted, source, set_at)
  values (pg_temp.k('ux'), gen_random_uuid(), 1, true, 'lead', now())$$, '23514', null, 'a final mark is a mark or NR, not both');

-- ---------------------------------------------------------------------------------------------
-- defaults_are_ten_percent_and_ten_percent
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('ed', public.marking_checks_get(pg_temp.k('ed')));
select is(pg_temp.r('ed'), '{"ok": true, "double_marking": true, "sample_percent": 10, "tolerance_percent": 10, "seeds": true,
  "seed_every": 10, "practice": true, "off": null, "markers_approved": 2, "can_switch_off": false, "opened": false,
  "approved": false}'::jsonb,
  'defaults_are_ten_percent_and_ten_percent: an exam never saved has double marking (10% sampled, 10% tolerance), seeds (one in 10) and practice on');
select is(pg_temp.code(public.marking_settings_set(pg_temp.k('ed'), 'whole', null)), 'ok', 'its marking settings are saved');
select tests.as_postgres();
select is(pg_temp.saved('ed'), 't/10/10/t/10/t', 'the row made then has the same defaults');
select is((select m.checks_off_reason is null and m.checks_off_by is null and m.checks_off_at is null and m.approved_at is null
             and m.approved_by is null from public.exam_marking m where m.exam_id = pg_temp.k('ed')), true,
  'with nothing turned off and nothing approved');

-- ---------------------------------------------------------------------------------------------
-- switch_off_needs_a_reason_and_a_one_marker_subject
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_checks_set(pg_temp.k('e1'), pg_temp.s(dm => false))), 'reason_required',
  'switch_off_needs_a_reason_and_a_one_marker_subject: turning double marking off needs a reason');
select is(pg_temp.code(public.marking_checks_set(pg_temp.k('e1'), pg_temp.s(dm => false), '  no  ')), 'reason_required',
  'of 3 characters at least, trimmed');
select is(pg_temp.code(public.marking_checks_set(pg_temp.k('e1'), pg_temp.s(se => false))), 'reason_required', 'so does turning seeds off');
select is(pg_temp.code(public.marking_checks_set(pg_temp.k('e1'), pg_temp.s(pr => false))), 'reason_required', 'and practice');
select tests.as_postgres();
select is(pg_temp.saved('e1'), 'none', 'a refusal writes nothing');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_checks_set(pg_temp.k('e1'), pg_temp.s(dm => false), '  Only one marker for this subject  ')), 'ok',
  'with a reason, a subject with one approved marker may turn double marking off');
select is(pg_temp.code(public.marking_checks_set(pg_temp.k('e0'), pg_temp.s(dm => false, se => false, pr => false), 'Markers not chosen yet')), 'ok',
  'so may a subject with no approved marker yet');
select tests.as_postgres();
select is(pg_temp.saved('e1'), 'f/10/10/t/10/t', 'e1: double marking is off, the rest unchanged');
select is(pg_temp.saved('e0'), 'f/10/10/f/10/f', 'e0: all three are off');

-- ---------------------------------------------------------------------------------------------
-- switch_off_refused_with_two_markers
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_checks_set(pg_temp.k('e2'), pg_temp.s(dm => false), 'Only one marker really')), 'not_small_subject',
  'switch_off_refused_with_two_markers: double marking stays on with two approved markers');
select is(pg_temp.code(public.marking_checks_set(pg_temp.k('e2'), pg_temp.s(se => false), 'Only one marker really')), 'not_small_subject',
  'so do seeds');
select is(pg_temp.code(public.marking_checks_set(pg_temp.k('e2'), pg_temp.s(pr => false), 'Only one marker really')), 'not_small_subject',
  'and practice');
select is(pg_temp.code(public.marking_checks_set(pg_temp.k('e2'), pg_temp.s(dm => false))), 'not_small_subject',
  'without a reason too: no reason can change it');
select tests.as_postgres();
select is(pg_temp.saved('e2'), 'none', 'nothing was written');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_checks_set(pg_temp.k('e2'), pg_temp.s(sp => 20, tp => 5, sv => 12))), 'ok',
  'with all three on, the numbers may change without a reason before marking opens');
select tests.as_postgres();
select is(pg_temp.saved('e2'), 't/20/5/t/12/t', 'and are saved');
update public.profiles set status = 'suspended' where id = pg_temp.uid('m1');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_checks_set(pg_temp.k('e2'), pg_temp.s(sp => 20, tp => 5, sv => 12, pr => false), 'Only lead2 marks now')), 'ok',
  'a suspended marker does not count: with one active marker practice may go off');
select tests.as_postgres();
update public.profiles set status = 'active' where id = pg_temp.uid('m1');

-- ---------------------------------------------------------------------------------------------
-- off_reason_is_stored_with_who_and_when
-- ---------------------------------------------------------------------------------------------
select is((select m.checks_off_reason = 'Only one marker for this subject' and m.checks_off_by = pg_temp.uid('admin')
             and m.checks_off_at = now() from public.exam_marking m where m.exam_id = pg_temp.k('e1')), true,
  'off_reason_is_stored_with_who_and_when: the reason (trimmed), who and when');
select tests.as_user(pg_temp.uid('admin'));
select is(public.marking_checks_get(pg_temp.k('e1')) -> 'off',
  jsonb_build_object('reason', 'Only one marker for this subject', 'by_name', 'Ada Checker', 'at', now()),
  'marking_checks_get shows them with the name of who turned it off');
select tests.as_postgres();
select tests.as_user(pg_temp.uid('admin2'));
select is(pg_temp.code(public.marking_checks_set(pg_temp.k('e1'), pg_temp.s(dm => false, se => false), 'Seeds are not needed here')), 'ok',
  'a second admin turns seeds off too');
select is(public.marking_checks_get(pg_temp.k('e1')) -> 'off',
  jsonb_build_object('reason', 'Seeds are not needed here', 'by_name', 'Bea Second', 'at', now()),
  'the latest turning off is the one kept');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- switching_all_on_clears_the_reason
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_checks_set(pg_temp.k('e1'), pg_temp.s(se => false))), 'ok',
  'switching_all_on_clears_the_reason: turning double marking on again needs no reason before marking opens');
select tests.as_postgres();
select is((select concat_ws('/', m.double_marking, m.seeds, m.checks_off_reason, m.checks_off_by = pg_temp.uid('admin2'))
           from public.exam_marking m where m.exam_id = pg_temp.k('e1')), 't/f/Seeds are not needed here/t',
  'while seeds stay off, the reason stays');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_checks_set(pg_temp.k('e1'), pg_temp.s())), 'ok', 'all three on again');
select tests.as_postgres();
select is((select m.checks_off_reason is null and m.checks_off_by is null and m.checks_off_at is null
           from public.exam_marking m where m.exam_id = pg_temp.k('e1')), true, 'the reason, who and when are cleared');
select tests.as_user(pg_temp.uid('admin'));
select is(public.marking_checks_get(pg_temp.k('e1')) -> 'off', 'null'::jsonb, 'and nothing shows as turned off');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- one_marker_subject_opens_with_all_three_off
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_open(pg_temp.k('e1'))), 'needs_two_markers',
  'one_marker_subject_opens_with_all_three_off: with double marking on, one marker cannot open');
select is(pg_temp.code(public.marking_checks_set(pg_temp.k('e1'), pg_temp.s(dm => false, se => false, pr => false), 'One marker this time')), 'ok',
  'all three are turned off with a reason');
insert into res values ('open1', public.marking_open(pg_temp.k('e1')));
select is(pg_temp.r('open1'), '{"ok": true, "already": false, "ready": 1}'::jsonb, 'and marking opens: its verified script is ready');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- change_after_open_needs_a_reason
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_checks_set(pg_temp.k('e1'), pg_temp.s(dm => false, se => false, pr => false, sp => 20))), 'reason_required',
  'change_after_open_needs_a_reason: once marking has opened, even a number needs a reason');
select is(pg_temp.code(public.marking_checks_set(pg_temp.k('e1'), pg_temp.s(se => false, pr => false))), 'reason_required',
  'so does turning a check on');
select tests.as_postgres();
select is(pg_temp.audits('marking_checks_set', pg_temp.k('e1')), 5, 'the refusals write no audit row (five changes so far)');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_checks_set(pg_temp.k('e1'), pg_temp.s(dm => false, se => false, pr => false))), 'ok',
  'saving the same settings needs no reason');
select tests.as_postgres();
select is(pg_temp.audits('marking_checks_set', pg_temp.k('e1')), 5, 'and changes nothing, so no audit row');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_checks_set(pg_temp.k('e1'), pg_temp.s(dm => false, se => false, pr => false, sp => 20), 'A bigger sample, just in case')), 'ok',
  'with a reason the change is saved');
select tests.as_postgres();
select is(pg_temp.saved('e1'), 'f/20/10/f/10/f', 'the sample is 20%');

-- ---------------------------------------------------------------------------------------------
-- percent_out_of_range_refused
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select is(array[pg_temp.code(public.marking_checks_set(pg_temp.k('e2'), pg_temp.s(sp => 0))),
                pg_temp.code(public.marking_checks_set(pg_temp.k('e2'), pg_temp.s(sp => 101))),
                pg_temp.code(public.marking_checks_set(pg_temp.k('e2'), pg_temp.s(tp => 0))),
                pg_temp.code(public.marking_checks_set(pg_temp.k('e2'), pg_temp.s(tp => 51))),
                pg_temp.code(public.marking_checks_set(pg_temp.k('e2'), pg_temp.s(sv => 2))),
                pg_temp.code(public.marking_checks_set(pg_temp.k('e2'), pg_temp.s(sv => 51)))],
  array_fill('invalid_input'::text, array[6]),
  'percent_out_of_range_refused: sample 0 and 101, tolerance 0 and 51, a seed gap of 2 and 51');
select is(array[pg_temp.code(public.marking_checks_set(pg_temp.k('e2'), pg_temp.s(sp => 10) || '{"sample_percent": 10.5}')),
                pg_temp.code(public.marking_checks_set(pg_temp.k('e2'), pg_temp.s(sp => 10) || '{"seed_every": "10"}')),
                pg_temp.code(public.marking_checks_set(pg_temp.k('e2'), pg_temp.s(sp => 10) || '{"seeds": "false"}')),
                pg_temp.code(public.marking_checks_set(pg_temp.k('e2'), pg_temp.s(sp => 10) - 'practice')),
                pg_temp.code(public.marking_checks_set(pg_temp.k('e2'), '[]')),
                pg_temp.code(public.marking_checks_set(pg_temp.k('e2'), null)),
                pg_temp.code(public.marking_checks_set(null, pg_temp.s()))],
  array_fill('invalid_input'::text, array[7]),
  'so are a part percent, a number or a switch sent as text, a setting left out, and no settings or no exam');
select is(pg_temp.code(public.marking_checks_set(gen_random_uuid(), pg_temp.s())), 'not_found', 'an unknown exam is not found');
select tests.as_postgres();
select is(pg_temp.saved('e2'), 't/20/5/t/12/f', 'nothing was written');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_checks_set(pg_temp.k('e2'), pg_temp.s(sp => 1, tp => 50, sv => 3, pr => false))), 'ok',
  'the lowest sample, the highest tolerance and the shortest gap are allowed');
select is(pg_temp.code(public.marking_checks_set(pg_temp.k('e2'), pg_temp.s(sp => 100, tp => 1, sv => 50, pr => false))), 'ok',
  'so are the highest sample, the lowest tolerance and the longest gap');
select tests.as_postgres();
select is(pg_temp.saved('e2'), 't/100/1/t/50/f', 'and are saved');

-- ---------------------------------------------------------------------------------------------
-- open_with_double_marking_needs_two_markers
-- ---------------------------------------------------------------------------------------------
update public.exam_marking set double_marking = true, seeds = false, practice = false where exam_id = pg_temp.k('eo');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_open(pg_temp.k('eo'))), 'needs_two_markers',
  'open_with_double_marking_needs_two_markers: one approved marker is not enough');
select tests.as_postgres();
insert into c values ('o2', tests.marker(pg_temp.subj('open')));
update public.profiles set status = 'suspended' where id = pg_temp.uid('o2');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_open(pg_temp.k('eo'))), 'needs_two_markers', 'a suspended second marker does not count');
select tests.as_postgres();
select is((select m.opened_at is null from public.exam_marking m where m.exam_id = pg_temp.k('eo')), true, 'the refusals open nothing');
update public.profiles set status = 'active' where id = pg_temp.uid('o2');
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('openo', public.marking_open(pg_temp.k('eo')));
select is(pg_temp.r('openo'), '{"ok": true, "already": false, "ready": 1}'::jsonb, 'with two active approved markers it opens');
select is(pg_temp.code(public.marking_open(pg_temp.k('e0'))), 'structure_incomplete',
  'the structure is still checked first (e0 has no questions)');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- open_with_seeds_or_practice_needs_a_lead
-- ---------------------------------------------------------------------------------------------
update public.exam_marking set double_marking = true, seeds = true, practice = false where exam_id = pg_temp.k('eo2');
update public.exam_marking set double_marking = false, seeds = false, practice = true where exam_id = pg_temp.k('eo3');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_open(pg_temp.k('eo2'))), 'no_lead',
  'open_with_seeds_or_practice_needs_a_lead: with seeds on and no lead marker it does not open');
select is(pg_temp.code(public.marking_open(pg_temp.k('eo3'))), 'no_lead', 'nor with practice on');
select tests.as_postgres();
insert into c values ('olead', tests.marker(pg_temp.subj('open'), true));
update public.profiles set status = 'suspended' where id = pg_temp.uid('olead');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_open(pg_temp.k('eo2'))), 'no_lead', 'a suspended lead does not count');
select tests.as_postgres();
update public.profiles set status = 'active' where id = pg_temp.uid('olead');
select tests.as_user(pg_temp.uid('admin'));
select is(array[pg_temp.code(public.marking_open(pg_temp.k('eo2'))), pg_temp.code(public.marking_open(pg_temp.k('eo3')))], array['ok', 'ok'],
  'with an active lead marker both open');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- teacher_and_corrector_cannot_set
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('teacher'));
select is(pg_temp.code(public.marking_checks_set(pg_temp.k('e1'), pg_temp.s(), 'Turning it all on')), 'forbidden',
  'teacher_and_corrector_cannot_set: the subject''s teacher cannot');
select tests.as_postgres();
select tests.as_user(pg_temp.uid('solo'));
select is(pg_temp.code(public.marking_checks_set(pg_temp.k('e1'), pg_temp.s(), 'Turning it all on')), 'forbidden', 'nor its lead marker');
select tests.as_postgres();
select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.code(public.marking_checks_set(pg_temp.k('e2'), pg_temp.s(), 'Turning it all on')), 'forbidden', 'nor an approved corrector');
select tests.as_postgres();
select tests.as_user(pg_temp.uid('corr'));
select is(pg_temp.code(public.marking_checks_set(pg_temp.k('e2'), pg_temp.s(), 'Turning it all on')), 'forbidden', 'nor any corrector');
select tests.as_postgres();
select is(pg_temp.saved('e1') || ' ' || pg_temp.saved('e2'), 'f/20/10/f/10/f t/100/1/t/50/f', 'nothing changed');
select is(has_function_privilege('anon', 'public.marking_checks_set(uuid, jsonb, text)', 'execute')
          or has_function_privilege('anon', 'public.marking_checks_get(uuid)', 'execute'), false, 'anon may call neither function');

-- ---------------------------------------------------------------------------------------------
-- lead_reads_settings_of_own_subject_only
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('admin_e1', public.marking_checks_get(pg_temp.k('e1')));
select tests.as_postgres();
select tests.as_user(pg_temp.uid('solo'));
insert into res values ('solo_e1', public.marking_checks_get(pg_temp.k('e1')));
select is(pg_temp.r('solo_e1'), pg_temp.r('admin_e1'), 'lead_reads_settings_of_own_subject_only: the lead reads what an admin reads');
select is(pg_temp.r('solo_e1') - 'off', '{"ok": true, "double_marking": false, "sample_percent": 20, "tolerance_percent": 10, "seeds": false,
  "seed_every": 10, "practice": false, "markers_approved": 1, "can_switch_off": true, "opened": true, "approved": false}'::jsonb,
  'e1: its checks, one approved marker who may switch them off, opened, not approved');
select is(pg_temp.r('solo_e1') #>> '{off,reason}', 'One marker this time', 'with the reason they were turned off for (a later number change keeps it)');
select is(pg_temp.code(public.marking_checks_get(pg_temp.k('e2'))), 'forbidden', 'not another subject''s exam');
select is(pg_temp.code(public.marking_checks_get(gen_random_uuid())), 'forbidden', 'nor an unknown one');
select tests.as_postgres();
select tests.as_user(pg_temp.uid('lead2'));
select is(pg_temp.code(public.marking_checks_get(pg_temp.k('e2'))), 'ok', 'the other lead reads their own subject''s exam');
select is(pg_temp.code(public.marking_checks_get(pg_temp.k('e1'))), 'forbidden', 'and not e1');
select tests.as_postgres();
select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.code(public.marking_checks_get(pg_temp.k('e2'))), 'forbidden', 'a marker who is not the lead reads nothing');
select tests.as_postgres();
select tests.as_user(pg_temp.uid('teacher'));
select is(pg_temp.code(public.marking_checks_get(pg_temp.k('e1'))), 'forbidden', 'nor does the subject''s teacher');
select tests.as_postgres();
select tests.as_user(pg_temp.uid('admin'));
select is(array[pg_temp.code(public.marking_checks_get(gen_random_uuid())), pg_temp.code(public.marking_checks_get(null))],
  array['not_found', 'invalid_input'], 'an admin is told an exam is not found, or that none was given');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- set_writes_audit
-- ---------------------------------------------------------------------------------------------
select is((select string_agg(a.reason, ' | ' order by a.id) from public.audit_log a
           where a.action = 'marking_checks_set' and a.target_type = 'exam' and a.target_id = pg_temp.k('e1')),
  'double marking on -> off; reason: Only one marker for this subject'
  || ' | seeded scripts on -> off; reason: Seeds are not needed here'
  || ' | double marking off -> on'
  || ' | seeded scripts off -> on'
  || ' | double marking on -> off; seeded scripts on -> off; practice on -> off; reason: One marker this time'
  || ' | second-mark 10% -> 20%; reason: A bigger sample, just in case',
  'set_writes_audit: one row per change, saying what changed and why');
select is((select string_agg(coalesce(p.first_name, '?'), ',' order by a.id) from public.audit_log a join public.profiles p on p.id = a.actor_id
           where a.action = 'marking_checks_set' and a.target_id = pg_temp.k('e1')), 'Ada,Bea,Ada,Ada,Ada,Ada', 'each with who made it');
select is((select string_agg(a.reason, ' | ' order by a.id) from public.audit_log a
           where a.action = 'marking_checks_set' and a.target_id = pg_temp.k('e2')),
  'second-mark 10% -> 20%; tolerance 10% -> 5%; seed every 10 -> 12'
  || ' | practice on -> off; reason: Only lead2 marks now'
  || ' | second-mark 20% -> 1%; tolerance 5% -> 50%; seed every 12 -> 3'
  || ' | second-mark 1% -> 100%; tolerance 50% -> 1%; seed every 3 -> 50',
  'every number that changed is named; refusals wrote nothing');

-- ---------------------------------------------------------------------------------------------
-- fixtures_mark_a_piece
-- ---------------------------------------------------------------------------------------------
insert into c values ('fm', tests.marker(pg_temp.subj('fix'))), ('fl', tests.marker(pg_temp.subj('fix'), true));
select is((select string_agg(p.role || ' ' || p.status || ' ' || a.lead, ',' order by a.lead) from public.marker_approvals a
           join public.profiles p on p.id = a.marker_id where a.subject_id = pg_temp.subj('fix')),
  'corrector active false,corrector active true', 'fixtures_mark_a_piece: tests.marker makes an active approved corrector, the lead when asked');
insert into kv values ('ef', tests.marking_exam(pg_temp.subj('fix'))), ('ef2', tests.marking_exam(pg_temp.subj('fix')));
select is(pg_temp.saved('ef'), 'f/10/10/f/10/f', 'tests.marking_exam writes the exam''s checks with all three off');
select tests.structure(pg_temp.k('ef'));
insert into kv values ('f1', tests.verified_script(pg_temp.k('ef'))), ('f2', tests.verified_script(pg_temp.k('ef')));
select tests.open_marking(pg_temp.k('ef'));
select is((select m.opened_at is not null and m.closed_at is null from public.exam_marking m where m.exam_id = pg_temp.k('ef')), true,
  'tests.open_marking opens marking');
select is(pg_temp.saved('ef'), 'f/10/10/f/10/f', 'with the three checks off');
select is((select string_agg(s.state::text, ',') from public.scripts s where s.exam_id = pg_temp.k('ef')), 'ready_to_mark,ready_to_mark',
  'and its verified scripts are ready to mark');
select tests.open_marking(pg_temp.k('ef2'), '{"double_marking": true, "sample_percent": 25}');
select is(pg_temp.saved('ef2'), 't/25/10/f/10/f', 'it writes only the checks it is given');
insert into kv select 'uf' || right(x.name, 1), u.id from kv x join public.marking_units u on u.script_id = x.id where x.name in ('f1', 'f2');
insert into kv values ('mf1', tests.mark_piece(pg_temp.k('uf1'), pg_temp.uid('fm'), array[2, 1, 4]));
select is(current_user::text, 'postgres', 'tests.mark_piece returns as postgres');
select is((select concat_ws('/', m.kind, m.status, m.marker_id = pg_temp.uid('fm'), m.total, u.state, s.state)
           from public.markings m join public.marking_units u on u.id = m.unit_id join public.scripts s on s.id = u.script_id
           where m.id = pg_temp.k('mf1')), 'live/submitted/t/7.0/submitted/marked',
  'and the piece is marked: the marker''s live marking is submitted, with its total, and the script is marked');
select is((select string_agg(trim_scale(qm.mark)::text, ',' order by q.position, q.parent_id nulls first) from public.question_marks qm
           join public.exam_questions q on q.id = qm.question_id where qm.marking_id = pg_temp.k('mf1')), '2,1,4',
  'with the marks given, one per question in paper order');
select is((select a.end_reason from public.marking_assignments a where a.unit_id = pg_temp.k('uf1') and a.marker_id = pg_temp.uid('fm')),
  'submitted', 'its hold ended on submit');
insert into kv values ('mf2', tests.mark_piece(pg_temp.k('uf2'), pg_temp.uid('fm')));
select is((select string_agg(trim_scale(qm.mark)::text || ':' || qm.not_attempted, ',') from public.question_marks qm where qm.marking_id = pg_temp.k('mf2')),
  '0:false,0:false,0:false', 'without marks given, each question gets 0');

select * from finish();
rollback;
