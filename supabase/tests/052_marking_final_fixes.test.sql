begin;
create extension if not exists pgtap with schema extensions;
select plan(41);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Final review, the minor items of the fix wave (20261122000015): a question added after opening and a marker who saw
-- a name (M2), what a change after the lock records (M5), no alert when nothing was held (M3), the waiting counts
-- (M4), the more flag of the pieces list (M9) and one exam's error in the minute job.
-- Fixtures. Subject 'ZZ Final fixes': correctors m1, m2 and m3 are approved. Exam eq is marked by question: question 1
-- (3 marks) is group G1, question 2 with parts (a) (2) and (b) (5) is group G2. Exam e is marked as whole scripts.
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values
  ('admin', tests.create_user('admin', 'active')),
  ('m1', tests.create_user('corrector', 'active')),
  ('m2', tests.create_user('corrector', 'active')),
  ('m3', tests.create_user('corrector', 'active'));
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create temp table res (name text primary key, j jsonb);
grant all on res to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
create function pg_temp.r(p text) returns jsonb language sql stable as $$ select j from res where name = p $$;
create function pg_temp.subj() returns bigint language sql stable as $$ select id from public.subjects where name = 'ZZ Final fixes' $$;
create function pg_temp.code(j jsonb) returns text language sql immutable as $$
  select case when (j ->> 'ok')::boolean then 'ok' else coalesce(j ->> 'code', 'none') end $$;
create function pg_temp.who(p uuid) returns text language sql stable as $$ select coalesce((select name from c where id = p), '?') $$;
-- A script's piece (of a group, or the whole script).
create function pg_temp.unit(p_script text, p_group text default null) returns uuid language sql stable as $$
  select u.id from public.marking_units u left join public.question_groups g on g.id = u.group_id
  where u.script_id = pg_temp.k(p_script) and g.label is not distinct from p_group $$;
-- A piece: its state, its markings (marker status reason) and who holds it how ('-' for nobody).
create function pg_temp.piece(p_script text, p_group text default null) returns text language sql stable as $$
  select u.state || ' | '
    || coalesce((select string_agg(pg_temp.who(m.marker_id) || ' ' || m.status || coalesce(' ' || m.set_aside_reason, ''), ',' order by m.started_at, m.id)
                 from public.markings m where m.unit_id = u.id), '-') || ' | '
    || coalesce((select pg_temp.who(a.marker_id) || ' ' || a.how from public.marking_assignments a where a.unit_id = u.id and a.ended_at is null), '-')
  from public.marking_units u where u.id = pg_temp.unit(p_script, p_group) $$;
-- A script's pieces on hold, as "state hold_reason" in id order ('' when none is), its alerts and its alert emails.
create function pg_temp.holds(p text) returns text language sql stable as $$
  select coalesce(string_agg(u.state || ' ' || u.hold_reason, ',' order by u.id), '') from public.marking_units u
  where u.script_id = pg_temp.k(p) and u.on_hold $$;
create function pg_temp.alerts(p text) returns text language sql stable as $$
  select coalesce(string_agg(a.kind || ' ' || a.state, ',' order by a.kind), '') from public.marking_alerts a where a.script_id = pg_temp.k(p) $$;
create function pg_temp.notices(p text) returns int language sql stable as $$
  select count(*)::int from public.script_notices n where n.kind = 'marking_alert' and n.script_id = pg_temp.k(p) $$;
-- The marker's advisory lock this transaction holds ('-' for none), as 043.
create function pg_temp.marker_lock(p text) returns text language sql stable as $$
  select coalesce(string_agg(l.mode, ',' order by l.mode), '-') from pg_locks l
  where l.locktype = 'advisory' and l.pid = pg_backend_pid()
    and ((l.classid::bigint << 32) | l.objid::bigint) = hashtextextended('marker:' || pg_temp.uid(p)::text, 0) $$;
-- What exam_structure_get gives, as a draft to save again (as 040 and the editor make it).
create function pg_temp.draft(g jsonb) returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'groups', coalesce((select jsonb_agg(jsonb_build_object('key', x ->> 'id', 'label', x -> 'label')) from jsonb_array_elements(g -> 'groups') x), '[]'),
    'option_groups', '[]'::jsonb,
    'questions', coalesce((select jsonb_agg(jsonb_build_object('id', x -> 'id', 'key', x ->> 'id', 'parent_key', x -> 'parent_id',
        'label', x -> 'label', 'max_mark', x -> 'max_mark', 'mark_step', x -> 'mark_step', 'levels', x -> 'levels', 'pages', x -> 'pages',
        'areas', x -> 'areas', 'group_key', x -> 'group_id', 'option_group_key', x -> 'option_group_id', 'guidance', x -> 'guidance',
        'alternatives', x -> 'alternatives',
        'points', coalesce((select jsonb_agg(p - 'id') from jsonb_array_elements(x -> 'points') p), '[]')) order by o)
      from jsonb_array_elements(g -> 'questions') with ordinality t(x, o)), '[]')) $$;
-- A draft with one question changed (by its label and its parent's), or one added.
create function pg_temp.edit(d jsonb, p_id uuid, p_patch jsonb) returns jsonb language sql immutable as $$
  select jsonb_set(d, '{questions}', (select jsonb_agg(case when x ->> 'id' = p_id::text then x || p_patch else x end order by o)
                                      from jsonb_array_elements(d -> 'questions') with ordinality t(x, o))) $$;
create function pg_temp.plus(d jsonb, p_key text, p_label text, p_max numeric, p_group uuid) returns jsonb language sql immutable as $$
  select jsonb_set(d, '{questions}', (d -> 'questions') || jsonb_build_array(jsonb_build_object('id', null, 'key', p_key, 'parent_key', null,
    'label', p_label, 'max_mark', p_max, 'mark_step', 1, 'levels', false, 'pages', '[1]'::jsonb, 'areas', '[]'::jsonb, 'group_key', p_group,
    'option_group_key', null, 'guidance', null, 'alternatives', null, 'points', '[]'::jsonb))) $$;
-- The reasons of an exam's structure changes after the lock, oldest first.
create function pg_temp.after_lock(p_exam text) returns text[] language sql stable as $$
  select coalesce(array_agg(a.reason order by a.id), '{}') from public.audit_log a
  where a.target_id = pg_temp.k(p_exam) and a.action = 'exam_structure_changed_after_lock' $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.r(text), pg_temp.subj(), pg_temp.code(jsonb), pg_temp.draft(jsonb),
  pg_temp.edit(jsonb, uuid, jsonb), pg_temp.plus(jsonb, text, text, numeric, uuid) to public;

insert into public.subjects (name, kind) values ('ZZ Final fixes', 'school');
insert into public.marker_approvals (marker_id, subject_id, approved_at) select c.id, pg_temp.subj(), now() from c where c.name in ('m1', 'm2', 'm3');

-- Exam eq, by question, opened by hand; scripts a, b, c and d are ready, each with a piece per group.
insert into kv values ('eq', tests.marking_exam(pg_temp.subj()));
select tests.structure(pg_temp.k('eq'));
insert into public.question_groups (exam_id, label, position) values (pg_temp.k('eq'), 'G1', 1), (pg_temp.k('eq'), 'G2', 2);
insert into kv select 'g:' || g.label, g.id from public.question_groups g where g.exam_id = pg_temp.k('eq');
update public.exam_questions q set group_id = pg_temp.k('g:G' || q.label) where q.exam_id = pg_temp.k('eq') and q.parent_id is null;
insert into kv select 'q:' || coalesce(p.label || '(' || q.label || ')', q.label), q.id
from public.exam_questions q left join public.exam_questions p on p.id = q.parent_id where q.exam_id = pg_temp.k('eq');
insert into public.exam_marking (exam_id, mode, opened_at, opened_by) values (pg_temp.k('eq'), 'by_question', now(), pg_temp.uid('admin'))
on conflict (exam_id) do update set mode = excluded.mode, opened_at = excluded.opened_at, opened_by = excluded.opened_by;
insert into kv select x, tests.verified_script(pg_temp.k('eq')) from unnest(array['a', 'b', 'c', 'd']) x;
select public.marking_exam_sync(pg_temp.k('eq'), null);

-- ---------------------------------------------------------------------------------------------
-- added_question_keeps_a_piece_from_a_marker_who_saw_a_name (M2)
-- G1 of each script was marked and submitted: a and d by m1, b by m2, c by m3. m1 then saw a name on script a (Name
-- visible, on its G2): a name_seen exclusion on each piece of a, their submitted G1 stands (Ruling R14). m3's approval
-- was removed since. An admin adds question 3 to G1.
-- ---------------------------------------------------------------------------------------------
create function pg_temp.submit(p_script text, p_marker text) returns void language plpgsql as $$
begin
  update public.marking_units set state = 'submitted' where id = pg_temp.unit(p_script, 'G1');
  insert into public.markings (unit_id, marker_id, status, total, submitted_at)
  values (pg_temp.unit(p_script, 'G1'), pg_temp.uid(p_marker), 'submitted', 2, now());
  insert into public.marking_assignments (unit_id, marker_id, how, hold_until, created_at, ended_at, end_reason)
  values (pg_temp.unit(p_script, 'G1'), pg_temp.uid(p_marker), 'next', now() + interval '1 hour', now() - interval '1 hour', now(), 'submitted');
  perform public.marking_script_state(pg_temp.k(p_script));
end $$;
select pg_temp.submit('a', 'm1');
select pg_temp.submit('b', 'm2');
select pg_temp.submit('c', 'm3');
select pg_temp.submit('d', 'm1');
insert into public.marking_unit_exclusions (unit_id, marker_id, reason)
select u.id, pg_temp.uid('m1'), 'name_seen' from public.marking_units u where u.script_id = pg_temp.k('a');
delete from public.marker_approvals where marker_id = pg_temp.uid('m3');
select is(array[pg_temp.piece('a', 'G1'), pg_temp.piece('b', 'G1'), pg_temp.piece('c', 'G1'), pg_temp.piece('d', 'G1')],
  array['submitted | m1 submitted | -', 'submitted | m2 submitted | -', 'submitted | m3 submitted | -', 'submitted | m1 submitted | -'],
  'fixture: G1 of each script is submitted');
select is(array[pg_temp.marker_lock('m1'), pg_temp.marker_lock('m2'), pg_temp.marker_lock('m3')], array['-', '-', '-'], 'no marker''s key is held yet');

-- A change that adds no question takes no marker's key.
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.exam_structure_save(pg_temp.k('eq'),
    pg_temp.edit(pg_temp.draft(public.exam_structure_get(pg_temp.k('eq'))), pg_temp.k('q:1'), '{"guidance": "Units are needed."}'), 'Clearer guidance')),
  'ok', 'added_question_keeps_a_piece_from_a_marker_who_saw_a_name: an admin changes the guidance after opening');
select tests.as_postgres();
select is(array[pg_temp.marker_lock('m1'), pg_temp.marker_lock('m2'), pg_temp.marker_lock('m3')], array['-', '-', '-'],
  'a change that adds no question takes no marker''s key');

select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.exam_structure_save(pg_temp.k('eq'),
    pg_temp.plus(pg_temp.draft(public.exam_structure_get(pg_temp.k('eq'))), 'new3', '3', 2, pg_temp.k('g:G1')), 'Question 3 was left out')),
  'ok', 'an admin adds question 3 to G1');
select tests.as_postgres();
select is(pg_temp.piece('a', 'G1'), 'open | m1 set_aside name_seen | -',
  'the piece m1 saw a name on does not go back to m1: their marking is set aside (name_seen), the piece is open and nobody holds it');
select is(pg_temp.piece('d', 'G1'), 'taken | m1 in_progress | m1 assigned', 'm1''s piece of another script, with no name seen, goes back to m1');
select is(pg_temp.piece('b', 'G1'), 'taken | m2 in_progress | m2 assigned', 'm2''s piece goes back to m2');
select is(pg_temp.piece('c', 'G1'), 'open | m3 set_aside unapproved | -', 'the piece of a marker no longer approved is open, their marking set aside (as before)');
select is(array[pg_temp.piece('a', 'G2'), pg_temp.piece('b', 'G2')], array['open | - | -', 'open | - | -'], 'the other group''s pieces are untouched');
select is(array[pg_temp.marker_lock('m1'), pg_temp.marker_lock('m2'), pg_temp.marker_lock('m3')], array['ShareLock', 'ShareLock', 'ShareLock'],
  'the save held the key of every marker with a submitted piece, shared (marker_unapprove and Name visible take it exclusively)');
select is((select array_agg(s.state::text order by x.o) from unnest(array['a', 'b', 'c', 'd']) with ordinality x(name, o)
           join public.scripts s on s.id = pg_temp.k(x.name)), array['marking', 'marking', 'marking', 'marking'], 'the scripts are being marked');
-- m1 is not offered the piece again either.
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('m1_work', public.marking_my_work());
select tests.as_postgres();
select is((select count(*)::int from jsonb_array_elements(pg_temp.r('m1_work') -> 'pieces') p where (p ->> 'unit_id')::uuid = pg_temp.unit('a', 'G1')), 0,
  'and it is not in m1''s list');

-- ---------------------------------------------------------------------------------------------
-- structure_change_after_lock_says_what_changed (M5)
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.exam_structure_save(pg_temp.k('eq'),
    pg_temp.edit(pg_temp.draft(public.exam_structure_get(pg_temp.k('eq'))), pg_temp.k('q:2(b)'), '{"max_mark": 6}'), 'Part (b) is out of 6')),
  'ok', 'structure_change_after_lock_says_what_changed: an admin raises the maximum of 2(b)');
select is(pg_temp.code(public.exam_structure_save(pg_temp.k('eq'),
    pg_temp.plus(pg_temp.edit(pg_temp.edit(pg_temp.draft(public.exam_structure_get(pg_temp.k('eq'))), pg_temp.k('q:1'), '{"max_mark": 4}'),
                              pg_temp.k('q:2(a)'), '{"max_mark": 3}'),
                 'new4', '4', 1, pg_temp.k('g:G2')), 'Question 4 was left out; two maxima were wrong')),
  'ok', 'then changes two maxima and adds a question to G2, where nothing is submitted');
select tests.as_postgres();
select is(pg_temp.after_lock('eq'), array[
    'Clearer guidance (no maximum changed and no question added)',
    'Question 3 was left out (1 question added; 4 pieces reopened)',
    'Part (b) is out of 6 (maximum 2(b) 5 -> 6)',
    'Question 4 was left out; two maxima were wrong (maximum 1 3 -> 4; maximum 2(a) 2 -> 3; 1 question added; 0 pieces reopened)'],
  'each change after the lock records its reason and then what changed: the maxima from and to, the questions added, the pieces reopened');
select is((select array[a.actor_id::text, a.target_type] from public.audit_log a
           where a.target_id = pg_temp.k('eq') and a.action = 'exam_structure_changed_after_lock' order by a.id desc limit 1),
  array[pg_temp.uid('admin')::text, 'exam'], 'by the admin, about the exam');

-- Many maxima at once: the first five are named, the rest counted, and the reason stays within the audit log's limit.
insert into kv values ('em', tests.marking_exam(pg_temp.subj()));
insert into public.exam_questions (exam_id, label, position, max_mark, pages)
select pg_temp.k('em'), i::text, i, 3, '{1}' from generate_series(1, 8) i;
insert into public.exam_marking (exam_id, mode, opened_at, opened_by) values (pg_temp.k('em'), 'whole', now(), pg_temp.uid('admin'))
on conflict (exam_id) do update set mode = excluded.mode, opened_at = excluded.opened_at, opened_by = excluded.opened_by;
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.exam_structure_save(pg_temp.k('em'),
    (select jsonb_set(d, '{questions}', (select jsonb_agg(x || '{"max_mark": 4}' order by o) from jsonb_array_elements(d -> 'questions') with ordinality t(x, o)))
     from (select pg_temp.draft(public.exam_structure_get(pg_temp.k('em'))) as d) y), repeat('Every question is out of 4. ', 10))),
  'ok', 'eight maxima change in one save, with a long reason');
select tests.as_postgres();
select is(pg_temp.after_lock('em'), array[btrim(repeat('Every question is out of 4. ', 10))
    || ' (maximum 1 3 -> 4; maximum 2 3 -> 4; maximum 3 3 -> 4; maximum 4 3 -> 4; maximum 5 3 -> 4; 3 more maxima changed)'],
  'the first five are named in paper order, the others counted');

-- ---------------------------------------------------------------------------------------------
-- no_alert_when_nothing_was_held (M3). Exam e, whole scripts: h_free and h_gone are ready with nobody on them, h_taken
-- is held by m1, h_done was submitted by m2.
-- ---------------------------------------------------------------------------------------------
insert into kv values ('e', tests.marking_exam(pg_temp.subj()));
select tests.structure(pg_temp.k('e'));
insert into public.exam_marking (exam_id, mode, opened_at, opened_by) values (pg_temp.k('e'), 'whole', now(), pg_temp.uid('admin'))
on conflict (exam_id) do update set mode = excluded.mode, opened_at = excluded.opened_at, opened_by = excluded.opened_by;
insert into kv select x, tests.verified_script(pg_temp.k('e')) from unnest(array['h_free', 'h_gone', 'h_taken', 'h_done', 'h_trig']) x;
select public.marking_exam_sync(pg_temp.k('e'), null);
update public.marking_units set state = 'taken' where id = pg_temp.unit('h_taken');
insert into public.marking_assignments (unit_id, marker_id, how, hold_until) values (pg_temp.unit('h_taken'), pg_temp.uid('m1'), 'next', now() + interval '1 hour');
update public.marking_units set state = 'submitted' where id = pg_temp.unit('h_done');
insert into public.markings (unit_id, marker_id, status, total, submitted_at) values (pg_temp.unit('h_done'), pg_temp.uid('m2'), 'submitted', 5, now());

select public.marking_script_hold(pg_temp.k(x), 'picture_changed', 'picture_changed',
  (select l.page_id from public.script_page_links l where l.script_id = pg_temp.k(x) and l.copy_page = 2))
from unnest(array['h_free', 'h_taken', 'h_done']) x;
select is(array[pg_temp.holds('h_free'), pg_temp.alerts('h_free'), pg_temp.notices('h_free')::text], array['', '', '0'],
  'no_alert_when_nothing_was_held: a changed picture on a script nobody has taken holds nothing, raises no alert and queues no email');
select is(array[pg_temp.holds('h_taken'), pg_temp.alerts('h_taken')], array['taken picture_changed', 'picture_changed open'],
  'a taken piece is held, with its alert');
select is(array[pg_temp.holds('h_done'), pg_temp.alerts('h_done')], array['submitted picture_changed', 'picture_changed open'],
  'and so is a submitted one');
select is(pg_temp.notices('h_taken') + pg_temp.notices('h_done'), 1, 'one email is queued for the exam''s changed pictures (grouped, as before)');
-- A second change to the held script raises no second alert (one open per script and kind, as before).
select public.marking_script_hold(pg_temp.k('h_taken'), 'picture_changed', 'picture_changed', null);
select is(pg_temp.alerts('h_taken'), 'picture_changed open', 'a second change to a held script keeps its one open alert');
-- A missing picture holds every piece, open ones too, and says so.
select public.marking_script_hold(pg_temp.k('h_gone'), 'picture_missing', 'picture_missing',
  (select l.page_id from public.script_page_links l where l.script_id = pg_temp.k('h_gone') and l.copy_page = 2));
select is(array[pg_temp.holds('h_gone'), pg_temp.alerts('h_gone'), pg_temp.notices('h_gone')::text], array['open picture_missing', 'picture_missing open', '1'],
  'a missing picture keeps its rule: the open piece is held, with an alert and its email');
-- Through the page trigger: a picture that goes on a script nobody has taken.
update public.script_pages set marking_path = null
where id = (select l.page_id from public.script_page_links l where l.script_id = pg_temp.k('h_trig') and l.copy_page = 2);
select is(array[pg_temp.holds('h_trig'), pg_temp.alerts('h_trig')], array['open picture_missing', 'picture_missing open'],
  'and the page trigger still holds and alerts for a picture that went');
-- A script with no piece at all (not yet ready): nothing to hold, nothing raised, whatever the reason.
insert into kv values ('h_none', tests.verified_script(pg_temp.k('e')));
select public.marking_script_hold(pg_temp.k('h_none'), 'picture_missing', 'picture_missing', null);
select is(array[pg_temp.alerts('h_none'), pg_temp.notices('h_none')::text], array['', '0'], 'a script with no piece yet raises nothing');

-- ---------------------------------------------------------------------------------------------
-- waiting_counts_once_per_script (M4): the same answer as counting the rule script by script.
-- ---------------------------------------------------------------------------------------------
update public.scripts set taken_back_at = now(), taken_back_by = pg_temp.uid('admin'), taken_back_reason = 'Look again' where id = pg_temp.k('h_free');
insert into public.processing_jobs (upload_id, kind, state, attempts, run_after)
select p.upload_id, 'remask', 'queued', 0, now() from public.script_pages p
join public.script_page_links l on l.page_id = p.id where l.script_id = pg_temp.k('h_taken') and l.copy_page = 1;
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('get', public.marking_exam_get(pg_temp.k('e')));
select tests.as_postgres();
select is(pg_temp.r('get') -> 'waiting',
  (select jsonb_build_object(
     'home_window_open', count(*) filter (where public.marking_script_waiting(s.id, now()) = 'home_window_open'),
     'centre_pages_unsettled', count(*) filter (where public.marking_script_waiting(s.id, now()) = 'centre_pages_unsettled'),
     'pictures_updating', count(*) filter (where public.marking_script_waiting(s.id, now()) = 'pictures_updating'),
     'late_undecided', count(*) filter (where public.marking_script_waiting(s.id, now()) = 'late_undecided'),
     'taken_back', count(*) filter (where public.marking_script_waiting(s.id, now()) = 'taken_back'),
     'picture_unchecked', count(*) filter (where public.marking_script_waiting(s.id, now()) = 'picture_unchecked'))
   from public.scripts s where s.exam_id = pg_temp.k('e') and s.state in ('verified', 'ready_to_mark', 'marking')),
  'waiting_counts_once_per_script: the waiting counts are what the rule gives script by script');
select is(array[pg_temp.r('get') #>> '{waiting,taken_back}', pg_temp.r('get') #>> '{waiting,pictures_updating}', pg_temp.r('get') #>> '{waiting,home_window_open}'],
  array['1', '1', '0'], 'one script taken back, one whose pictures are being made, none in its hand-in time');
select is((select array_agg(k order by k) from jsonb_object_keys(pg_temp.r('get')) k),
  array['closed_at', 'deadline', 'markers', 'mode', 'ok', 'opened_at', 'scripts', 'structure', 'waiting'], 'the answer has the fields it had');

-- ---------------------------------------------------------------------------------------------
-- units_list_says_when_there_are_more (M9). Exam eb, by question in 100 groups: 20 scripts make 2,000 pieces.
-- ---------------------------------------------------------------------------------------------
insert into kv values ('eb', tests.marking_exam(pg_temp.subj()));
insert into public.question_groups (exam_id, label, position) select pg_temp.k('eb'), 'B' || i, i from generate_series(1, 100) i;
insert into public.exam_marking (exam_id, mode, opened_at, opened_by) values (pg_temp.k('eb'), 'by_question', now(), pg_temp.uid('admin'))
on conflict (exam_id) do update set mode = excluded.mode, opened_at = excluded.opened_at, opened_by = excluded.opened_by;
create temp table bs as select tests.verified_script(pg_temp.k('eb')) as id from generate_series(1, 20);
select public.marking_exam_sync(pg_temp.k('eb'), null);
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('u2000', public.marking_units_list(pg_temp.k('eb')));
insert into res values ('u_small', public.marking_units_list(pg_temp.k('e')));
select tests.as_postgres();
select is(array[jsonb_array_length(pg_temp.r('u2000') -> 'units')::text, pg_temp.r('u2000') ->> 'more', pg_temp.r('u_small') ->> 'more'],
  array['2000', 'false', 'false'], 'units_list_says_when_there_are_more: exactly 2,000 pieces are all listed and more is false; so it is for a short list');
insert into kv values ('b21', tests.verified_script(pg_temp.k('eb')));
select public.marking_exam_sync(pg_temp.k('eb'), null);
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('u2100', public.marking_units_list(pg_temp.k('eb')));
insert into res values ('u_taken', public.marking_units_list(pg_temp.k('eb'), 'taken'));
select tests.as_postgres();
select is(array[jsonb_array_length(pg_temp.r('u2100') -> 'units')::text, pg_temp.r('u2100') ->> 'more'], array['2000', 'true'],
  'with 2,100 pieces the first 2,000 are listed and more is true');
select is((select count(*)::int from jsonb_array_elements(pg_temp.r('u2100') -> 'units') u
           join public.marking_units x on x.id = (u ->> 'unit_id')::uuid where x.script_id = pg_temp.k('b21')), 0,
  'the first 2,000 by script number: the last script''s pieces are the ones left out');
select is(array[jsonb_array_length(pg_temp.r('u_taken') -> 'units')::text, pg_temp.r('u_taken') ->> 'more'], array['0', 'false'],
  'a filter that matches fewer says more is false');
select is((select array_agg(k order by k) from jsonb_object_keys(pg_temp.r('u_small') -> 'units' -> 0) k),
  array['group_label', 'hold_reason', 'hold_until', 'how', 'index_number', 'last_saved_at', 'marker_id', 'marker_name', 'on_hold', 'script_number',
        'source', 'state', 'submitted_at', 'total', 'unit_id', 'waiting'], 'each piece has the fields it had');

-- ---------------------------------------------------------------------------------------------
-- tick_goes_on_after_one_exam_fails. Exams t_bad and t_ok are open, each with a verified script waiting to be made
-- ready; a trigger (this transaction only) makes every new piece of t_bad fail. A hold of exam e ran out.
-- ---------------------------------------------------------------------------------------------
insert into kv values ('t_bad', tests.marking_exam(pg_temp.subj())), ('t_ok', tests.marking_exam(pg_temp.subj())), ('t_ok2', tests.marking_exam(pg_temp.subj()));
insert into public.exam_marking (exam_id, mode, opened_at, opened_by)
select pg_temp.k(x), 'whole', now(), pg_temp.uid('admin') from unnest(array['t_bad', 't_ok', 't_ok2']) x
on conflict (exam_id) do update set mode = excluded.mode, opened_at = excluded.opened_at, opened_by = excluded.opened_by;
insert into kv values ('s_bad', tests.verified_script(pg_temp.k('t_bad'))), ('s_ok', tests.verified_script(pg_temp.k('t_ok'))),
                      ('s_ok2', tests.verified_script(pg_temp.k('t_ok2')));
create function pg_temp.fail_bad() returns trigger language plpgsql as $$
begin
  if new.exam_id = (select id from kv where name = 't_bad') then
    raise exception 'a made-up failure for candidate Wilhelmina Quarterfield';
  end if;
  return new;
end $$;
create trigger zz_fail_bad before insert on public.marking_units for each row execute function pg_temp.fail_bad();
update public.marking_assignments set hold_until = now() - interval '1 minute' where unit_id = pg_temp.unit('h_taken');
update public.marking_units set on_hold = false, hold_reason = null where id = pg_temp.unit('h_taken');
set local client_min_messages = error;
select lives_ok($$ select public.marking_tick() $$, 'tick_goes_on_after_one_exam_fails: the minute job does not fail when one exam''s sync does');
reset client_min_messages;
select is((select array_agg(s.state::text order by x.o) from unnest(array['s_bad', 's_ok', 's_ok2']) with ordinality x(name, o)
           join public.scripts s on s.id = pg_temp.k(x.name)), array['verified', 'ready_to_mark', 'ready_to_mark'],
  'the other exams'' scripts are made ready (whichever side of the failing exam they run); the failing exam''s script stays as it was');
select is((select count(*)::int from public.marking_units u where u.exam_id = pg_temp.k('t_bad')), 0, 'nothing of the failed sync is kept');
select is((select a.end_reason from public.marking_assignments a where a.unit_id = pg_temp.unit('h_taken')), 'expired',
  'and the holds that ran out still end');
drop trigger zz_fail_bad on public.marking_units;

-- ---------------------------------------------------------------------------------------------
-- Privileges: unchanged.
-- ---------------------------------------------------------------------------------------------
select is(array(select f from unnest(array['public.marking_script_hold(uuid, text, text, uuid)', 'public.marking_tick()']) f
  where has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute')
     or has_function_privilege('service_role', f, 'execute')), '{}'::text[], 'the internal functions cannot be called from the API');
select is(array(select f from unnest(array['public.exam_structure_save(uuid, jsonb, text)', 'public.marking_exam_get(uuid, timestamptz)',
    'public.marking_units_list(uuid, text, uuid)']) f
  where has_function_privilege('anon', f, 'execute') or not has_function_privilege('authenticated', f, 'execute')), '{}'::text[],
  'the staff functions are for signed-in users only');

select * from finish();
rollback;
