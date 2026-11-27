begin;
create extension if not exists pgtap with schema extensions;
select plan(33);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Phase 4A, Task 3: preparing results from the final marks, with grade boundaries, statuses and fair ranks.
-- Fixtures (tests.results_exam; the paper's maximum is 24; a candidate is kept as '<exam>:<n>' in the order the
-- fixture made them, home candidates first):
--   a: results_exam(2, 2) (totals 24, 22, 20, 18), and more bookings of its own: reg_absent (centre, absent on the
--      register, no script), home_none (home, no script), miss_p and miss_l (centre, present and late on the register, no
--      script), part (part refunded, home), creq (awaiting a cancellation decision, centre, not on the register),
--      cancelled, refunded (present on the register) and awaiting (awaiting payment), none with a script; wd (a home
--      script still verified, so the approval is stale, then withdrawn) and vd (a centre script made void). a:1's piece
--      has a final mark changed by the lead on question 1 (9, was 10), No response on question 4, and a submitted
--      marking whose total (20) is not its final total.
--   r: results_exam(5, 5) with totals 20, 16, 16, 12, 10 at home and 18, 18, 9, 8, 7 at a centre; r:1 has No response
--      on question 4 (it had 0).
--   s: results_exam(4, 5) (totals 24 to 8): four at home, five at a centre.  t: results_exam(4, 0) totals 7.5, 3, 2, 1.
--   q: results_exam(6, 0) totals 20, 16, 16, 12, 10, 8.  x: an exam whose question 1 (max 10) has a part (max 4).
--   big: the timing guard's exam, at the end.
-- People: an admin, the subject's lead marker, a teacher, a corrector, a:1's student and their linked parent.
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
-- A question of an exam by its label ('1', '2(a)', '2(b)', '3', '4'); a candidate's piece.
create function pg_temp.q(p_exam text, p_label text) returns uuid language sql stable as $$
  select q.id from public.exam_questions q left join public.exam_questions p on p.id = q.parent_id
  where q.exam_id = pg_temp.k(p_exam) and coalesce(p.label || '(' || q.label || ')', q.label) = p_label $$;
create function pg_temp.unit(p text) returns uuid language sql stable as $$
  select u.id from public.marking_units u join public.scripts s on s.id = u.script_id where s.booking_id = pg_temp.k(p) $$;
-- A candidate's question_marks entry for a question: 'mark not_attempted changed_on_review'.
create function pg_temp.qm(p text, p_exam text, p_label text) returns text language sql stable as $$
  select coalesce((select concat_ws(' ', coalesce(e ->> 'mark', 'null'), e ->> 'not_attempted', e ->> 'changed_on_review')
    from public.results r cross join jsonb_array_elements(r.question_marks) e
    where r.booking_id = pg_temp.k(p) and (e ->> 'question_id')::uuid = pg_temp.q(p_exam, p_label)), 'none') $$;
-- The exam's results row, as postgres.
create function pg_temp.er(p_exam text, p_field text) returns text language sql stable as $$
  select coalesce((select coalesce(to_jsonb(x) ->> p_field, 'null') from public.exam_results x where x.exam_id = pg_temp.k(p_exam)),
    'no row') $$;
create function pg_temp.audits(p_action text, p_target uuid) returns int language sql stable as $$
  select count(*)::int from public.audit_log a where a.action = p_action and a.target_id = p_target $$;
create function pg_temp.reason(p_action text, p_target uuid) returns text language sql stable as $$
  select coalesce(a.reason, 'none') from public.audit_log a where a.action = p_action and a.target_id = p_target
  order by a.id desc limit 1 $$;
-- An answer's grades ('A 3 2 1,B ...': grade, all, centre, home) and its 10% bands (the counts, lowest band first).
create function pg_temp.grades(j jsonb) returns text language sql immutable as $$
  select coalesce(string_agg(concat_ws(' ', x ->> 'grade', x ->> 'all', x ->> 'centre', x ->> 'home'), ',' order by o), '')
  from jsonb_array_elements(j -> 'grades') with ordinality t(x, o) $$;
create function pg_temp.bands(j jsonb) returns text language sql immutable as $$
  select coalesce(string_agg((x ->> 'from') || '-' || (x ->> 'to') || ':' || (x ->> 'count'), ',' order by o), '')
  from jsonb_array_elements(j -> 'bands') with ordinality t(x, o) $$;
-- A booking of a new active student (named "Zed <name>", index number SE-2098-nnnn) with no script; on the register
-- when p_att is given (marked by the admin).
create function pg_temp.booking(p_name text, p_exam text, p_sitting public.sitting_mode, p_status public.booking_status,
  p_att public.attendance_status default null) returns void language plpgsql as $$
declare
  v_student uuid := tests.create_user('student', 'active');
  v_centre uuid;
  v_b uuid;
begin
  update public.profiles set first_name = 'Zed', last_name = initcap(replace(p_name, '_', ' ')) where id = v_student;
  update public.student_details set index_number = 'SE-2098-' || lpad((select count(*) + 1 from kv)::text, 4, '0')
  where profile_id = v_student;
  if p_sitting = 'centre' then
    select ec.id into strict v_centre from public.exam_centres ec
    where ec.exam_id = pg_temp.k(p_exam) and ec.removed_at is null order by ec.created_at, ec.id limit 1;
  end if;
  insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting, centre_id)
  values (pg_temp.k(p_exam), v_student, v_student, p_status, 0, p_sitting, v_centre) returning id into v_b;
  insert into kv values (p_name, v_b);
  if p_att is not null then
    insert into public.attendance (exam_id, student_id, status, marked_by) values (pg_temp.k(p_exam), v_student, p_att, pg_temp.uid('admin'));
  end if;
end $$;
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
create function pg_temp.preview(p_who text, p_exam text, p_grades text) returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.grade_boundaries_preview(%L, %L::jsonb)', pg_temp.k(p_exam), p_grades)) $$;
create function pg_temp.bset(p_who text, p_exam text, p_grades text, p_reason text default null) returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.grade_boundaries_set(%L, %L::jsonb, %L)', pg_temp.k(p_exam), p_grades, p_reason)) $$;
create function pg_temp.export(p_who text, p_exam text) returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.results_export(%L)', pg_temp.k(p_exam))) $$;
create function pg_temp.withdraw(p_who text, p_exam text, p_reason text) returns jsonb language sql as $$
  select pg_temp.as(p_who, format('select public.marking_approval_withdraw(%L, %L)', pg_temp.k(p_exam), p_reason)) $$;

insert into c values ('admin', tests.create_user('admin', 'active')), ('teacher', tests.create_user('teacher', 'active')),
  ('corrector', tests.create_user('corrector', 'active')), ('parent', tests.create_user('parent', 'active')),
  ('lead', tests.marker(1, true));

-- Exam a.
insert into kv values ('a', tests.results_exam(2, 2));
select pg_temp.cands('a');
insert into c select 'student', b.student_id from public.bookings b where b.id = pg_temp.k('a:1');
insert into public.parent_children (parent_id, student_id) values (pg_temp.uid('parent'), pg_temp.uid('student'));
select pg_temp.booking('reg_absent', 'a', 'centre', 'paid', 'absent');
select pg_temp.booking('home_none', 'a', 'home', 'paid');
select pg_temp.booking('miss_p', 'a', 'centre', 'paid', 'present');
select pg_temp.booking('miss_l', 'a', 'centre', 'paid', 'late');
select pg_temp.booking('part', 'a', 'home', 'part_refunded');
select pg_temp.booking('creq', 'a', 'centre', 'cancel_requested');
select pg_temp.booking('cancelled', 'a', 'home', 'cancelled');
select pg_temp.booking('refunded', 'a', 'centre', 'refunded', 'present');
select pg_temp.booking('awaiting', 'a', 'home', 'awaiting_payment');
insert into kv values ('wd:s', tests.verified_script(pg_temp.k('a'), 'home'));
insert into kv select 'wd', s.booking_id from public.scripts s where s.id = pg_temp.k('wd:s');
insert into kv values ('vd:s', tests.verified_script(pg_temp.k('a'), 'centre'));
insert into kv select 'vd', s.booking_id from public.scripts s where s.id = pg_temp.k('vd:s');
update public.scripts set state = 'void' where id = pg_temp.k('vd:s');
update public.final_marks set mark = 9, source = 'lead' where unit_id = pg_temp.unit('a:1') and question_id = pg_temp.q('a', '1');
update public.final_marks set mark = null, not_attempted = true where unit_id = pg_temp.unit('a:1') and question_id = pg_temp.q('a', '4');
insert into public.markings (unit_id, kind, marker_id, status, rev, total, submitted_at)
values (pg_temp.unit('a:1'), 'live', pg_temp.uid('lead'), 'submitted', 1, 20, now());

-- Exams r, s, t, q and x.
insert into kv values ('r', tests.results_exam(5, 5, array[20, 16, 16, 12, 10, 18, 18, 9, 8, 7]));
select pg_temp.cands('r');
update public.final_marks set mark = null, not_attempted = true where unit_id = pg_temp.unit('r:1') and question_id = pg_temp.q('r', '4');
insert into kv values ('s', tests.results_exam(4, 5));
select pg_temp.cands('s');
insert into kv values ('t', tests.results_exam(4, 0, array[7.5, 3, 2, 1]));
select pg_temp.cands('t');
insert into kv values ('q', tests.results_exam(6, 0, array[20, 16, 16, 12, 10, 8]));
select pg_temp.cands('q');
insert into kv values ('x', tests.marking_exam());
with one as (insert into public.exam_questions (exam_id, label, position, max_mark, pages)
             values (pg_temp.k('x'), '1', 1, 10, '{1}') returning id)
insert into public.exam_questions (exam_id, parent_id, label, position, max_mark, pages)
select pg_temp.k('x'), one.id, 'a', 1, 4, '{1}' from one;
insert into public.exam_questions (exam_id, label, position, max_mark, pages) values (pg_temp.k('x'), '2', 2, 3, '{2}');

-- ---------------------------------------------------------------------------------------------
-- The fixtures (Ruling R5): several exams in one file with centre candidates share the fixture's venue; the paper's
-- maximum counts leaf maxima only.
-- ---------------------------------------------------------------------------------------------
select is(array[(select count(*)::int from public.venues where name = 'ZZ Marking hall'),
    (select count(*)::int from public.exam_centres where exam_id in (pg_temp.k('a'), pg_temp.k('r'), pg_temp.k('s'))),
    (select count(*)::int from public.bookings where exam_id = pg_temp.k('r') and sitting = 'centre')],
  array[1, 3, 5], 'fixtures: three exams with centre candidates in one file share one venue, each with its own centre');
select is(array[public.exam_max_total(pg_temp.k('x')), public.exam_max_total(pg_temp.k('a'))], array[7.0, 24.0]::numeric[],
  'exam_max_total_counts_leaves_only: a question with a part counts the part (4), not its own maximum (10); the fixture paper is 24');

-- ---------------------------------------------------------------------------------------------
-- prepare_refused_until_marking_approved_and_not_stale
-- ---------------------------------------------------------------------------------------------
create temp table appr as select approved_at, approved_by from public.exam_marking where exam_id = pg_temp.k('a');
update public.exam_marking set approved_at = null, approved_by = null where exam_id = pg_temp.k('a');
insert into res values ('a_not_approved', pg_temp.prep('admin', 'a'));
update public.exam_marking m set approved_at = x.approved_at, approved_by = x.approved_by from appr x where m.exam_id = pg_temp.k('a');
insert into res values ('a_stale', pg_temp.prep('admin', 'a'));
update public.scripts set state = 'withdrawn' where id = pg_temp.k('wd:s');
insert into res values ('a_missing', pg_temp.prep('admin', 'a'));
select is(array[pg_temp.code(pg_temp.r('a_not_approved')), pg_temp.code(pg_temp.r('a_stale')), pg_temp.code(pg_temp.r('a_missing')),
    (select count(*)::text from public.results where exam_id = pg_temp.k('a')), pg_temp.er('a', 'version'),
    pg_temp.audits('results_prepared', pg_temp.k('a'))::text],
  array['marking_not_approved', 'approval_stale', 'missing_scripts', '0', '0', '0'],
  'prepare_refused_until_marking_approved_and_not_stale: not approved, then stale (a script still verified), then two candidates '
  || 'without a script; nothing is prepared or recorded');

-- ---------------------------------------------------------------------------------------------
-- present_without_script_blocks_preparation_until_an_admin_sets_a_status
-- ---------------------------------------------------------------------------------------------
insert into res values ('a_get0', pg_temp.get('admin', 'a'));
insert into res values ('st_bad', pg_temp.st('admin', 'miss_p', 'present', 'Was in the room.'));
insert into res values ('st_noreason', pg_temp.st('admin', 'miss_p', 'absent', ' x '));
insert into res values ('st_not_candidate', pg_temp.st('admin', 'cancelled', 'absent', 'Not a candidate.'));
insert into res values ('st_not_found', pg_temp.as('admin',
  format('select public.result_status_set(%L, %L, %L)', gen_random_uuid(), 'absent', 'No such booking.')));
insert into res values ('st_auto_missing', pg_temp.st('admin', 'miss_p', 'auto', 'Back to the register.'));
insert into res values ('st_p', pg_temp.st('admin', 'miss_p', 'absent', 'Left before the start.'));
insert into res values ('st_l', pg_temp.st('admin', 'miss_l', 'incomplete', 'The script was lost; see the incident note.'));
select is(array[pg_temp.r('a_missing') ->> 'count', pg_temp.r('a_get0') ->> 'state',
    (select string_agg((x ->> 'booking_id') || ' ' || (x ->> 'name') || ' ' || (x ->> 'index_number' like 'SE-2098-%')::text, ','
                       order by x ->> 'name') from jsonb_array_elements(pg_temp.r('a_get0') -> 'missing') x),
    jsonb_array_length(pg_temp.r('a_get0') -> 'rows')::text],
  array['2', 'none', pg_temp.k('miss_l') || ' Zed Miss L true,' || pg_temp.k('miss_p') || ' Zed Miss P true', '0'],
  'present_without_script_blocks_preparation_until_an_admin_sets_a_status: the two are listed by name and index number '
  || '(not the one absent on the register, the home candidate, nor the refunded booking present on the register)');
select is(array[pg_temp.code(pg_temp.r('st_bad')), pg_temp.code(pg_temp.r('st_noreason')), pg_temp.code(pg_temp.r('st_not_candidate')),
    pg_temp.code(pg_temp.r('st_not_found')), pg_temp.code(pg_temp.r('st_auto_missing')), pg_temp.r('st_auto_missing') ->> 'count',
    pg_temp.code(pg_temp.r('st_p')), pg_temp.code(pg_temp.r('st_l')), pg_temp.r('st_l') ->> 'version',
    pg_temp.reason('result_status_set', pg_temp.k('miss_p')), pg_temp.audits('result_status_set', pg_temp.k('miss_p'))::text],
  array['invalid_input', 'reason_required', 'invalid_input', 'not_found', 'missing_scripts', '1', 'ok', 'ok', '2',
    'absent: Left before the start.', '1'],
  'result_status_set: absent, incomplete or disqualified with a reason, on a candidate only; auto is refused while the '
  || 'candidate would be missing again; each change is audited with what it set and why');

insert into res values ('a_prep', pg_temp.prep('admin', 'a'));
select is(array[pg_temp.code(pg_temp.r('a_prep')), pg_temp.r('a_prep') ->> 'version', pg_temp.er('a', 'state'),
    pg_temp.er('a', 'version'), (pg_temp.er('a', 'prepared_by') = pg_temp.uid('admin')::text)::text,
    pg_temp.audits('results_prepared', pg_temp.k('a'))::text],
  array['ok', '3', 'prepared', '3', 'true', '1'],
  'present_without_script_blocks_preparation_until_an_admin_sets_a_status: once both have a status the results are '
  || 'prepared (version 3: two status changes, then the preparation), and the preparation is audited');

-- ---------------------------------------------------------------------------------------------
-- statuses_follow_the_register_and_the_script
-- ---------------------------------------------------------------------------------------------
select is(pg_temp.fs(array['reg_absent', 'home_none', 'wd', 'vd', 'a:1', 'a:2', 'a:3', 'a:4', 'miss_p', 'miss_l', 'part', 'creq',
    'cancelled', 'refunded', 'awaiting'], 'status'),
  array['absent', 'absent', 'withdrawn', 'incomplete', 'present', 'present', 'present', 'present', 'absent', 'incomplete',
    'absent', 'absent', 'no row', 'no row', 'no row'],
  'statuses_follow_the_register_and_the_script: absent on the register, no script at home, withdrawn, void, checked; the '
  || 'admin''s statuses; part refunded and awaiting a decision count; cancelled, refunded and unpaid bookings get no row');
select is(array[pg_temp.r('a_prep') -> 'counts', pg_temp.r('a_prep') -> 'cohort',
    to_jsonb(pg_temp.fs(array['miss_p', 'miss_l', 'reg_absent', 'a:1'], 'status_set')), to_jsonb(pg_temp.f('miss_p', 'status_reason')),
    to_jsonb(pg_temp.fs(array['a:1', 'vd', 'reg_absent'], 'script_id'))],
  array['{"present": 4, "absent": 5, "withdrawn": 1, "incomplete": 2, "disqualified": 0}'::jsonb, 'null'::jsonb,
    '["true", "true", "false", "false"]'::jsonb, '"Left before the start."'::jsonb,
    to_jsonb(array[(select id::text from public.scripts where booking_id = pg_temp.k('a:1')), pg_temp.k('vd:s')::text, 'null'])],
  'statuses_follow_the_register_and_the_script: the counts; the admin''s statuses are marked set, with the reason; a row '
  || 'keeps its script; four present make no cohort figures');

-- ---------------------------------------------------------------------------------------------
-- total_and_questions_come_from_final_marks_only
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.f('a:1', 'total'), pg_temp.qm('a:1', 'a', '1'), pg_temp.qm('a:1', 'a', '2(a)'), pg_temp.qm('a:1', 'a', '4'),
    pg_temp.qm('a:2', 'a', '1'), (select jsonb_array_length(question_marks)::text from public.results where booking_id = pg_temp.k('a:1')),
    (select string_agg(e ->> 'question_id', ',' order by o) from public.results r
       cross join jsonb_array_elements(r.question_marks) with ordinality t(e, o) where r.booking_id = pg_temp.k('a:1')),
    array_to_string(pg_temp.fs(array['a:2', 'a:3', 'a:4'], 'total'), ','),
    array_to_string(pg_temp.fs(array['reg_absent', 'wd', 'vd', 'miss_p'], 'total'), ','),
    array_to_string(pg_temp.fs(array['reg_absent', 'wd', 'vd', 'miss_p'], 'question_marks'), ',')],
  array['23.0', '9.0 false true', '3.0 false false', 'null true false', '10.0 false false', '5',
    concat_ws(',', pg_temp.q('a', '1'), pg_temp.q('a', '2(a)'), pg_temp.q('a', '2(b)'), pg_temp.q('a', '3'), pg_temp.q('a', '4')),
    '22.0,20.0,18.0', 'null,null,null,null', '[],[],[],[]'],
  'total_and_questions_come_from_final_marks_only: the final marks (23), not the marking''s total (20); the lead''s change '
  || 'is changed_on_review; No response is kept; questions in paper order; only present candidates have marks');

-- ---------------------------------------------------------------------------------------------
-- percentage_is_one_decimal_half_up
-- ---------------------------------------------------------------------------------------------
select is(array[public.result_percentage(37.5, 80), public.result_percentage(1, 8), public.result_percentage(7.5, 24),
    public.result_percentage(0, 24), public.result_percentage(null, 24), public.result_percentage(5, 0)],
  array[46.9, 12.5, 31.3, 0.0, null, null]::numeric[],
  'percentage_is_one_decimal_half_up: 37.5 of 80 is 46.9, 1 of 8 is 12.5, 7.5 of 24 (31.25) is 31.3; none without a total '
  || 'or a maximum');
insert into res values ('t_prep', pg_temp.prep('admin', 't'));
select is(array[pg_temp.fs(pg_temp.ns('a', 1, 4), 'percentage'), pg_temp.fs(pg_temp.ns('t', 1, 4), 'percentage'),
    array[pg_temp.f('a:1', 'max_total'), pg_temp.f('reg_absent', 'max_total'), pg_temp.f('reg_absent', 'percentage'),
      pg_temp.f('vd', 'percentage')]],
  array[array['95.8', '91.7', '83.3', '75.0'], array['31.3', '12.5', '8.3', '4.2'], array['24.0', '24.0', 'null', 'null']],
  'percentage_is_one_decimal_half_up: each prepared row''s percentage of the paper''s maximum (24)');

-- ---------------------------------------------------------------------------------------------
-- admin_status_survives_prepare_again
-- ---------------------------------------------------------------------------------------------
insert into res values ('st_dq', pg_temp.st('admin', 'a:2', 'disqualified', 'Notes found on the desk.'));
insert into res values ('a_prep2', pg_temp.prep('admin', 'a'));
select is(array[pg_temp.code(pg_temp.r('st_dq')), pg_temp.code(pg_temp.r('a_prep2')), pg_temp.r('a_prep2') ->> 'version',
    pg_temp.f('miss_p', 'status'), pg_temp.f('miss_p', 'status_set'), pg_temp.f('miss_p', 'status_reason'),
    pg_temp.f('miss_l', 'status'), pg_temp.f('a:2', 'status'), pg_temp.f('a:2', 'total'), pg_temp.f('a:2', 'percentage'),
    pg_temp.r('a_prep2') #>> '{counts,present}', pg_temp.r('a_prep2') #>> '{counts,disqualified}',
    pg_temp.audits('results_prepared', pg_temp.k('a'))::text],
  array['ok', 'ok', '5', 'absent', 'true', 'Left before the start.', 'incomplete', 'disqualified', 'null', 'null', '3', '1', '2'],
  'admin_status_survives_prepare_again: preparing again keeps every status an admin set, and its reason');
insert into res values ('st_auto', pg_temp.st('admin', 'a:2', 'auto', 'Disqualified by mistake.'));
select is(array[pg_temp.code(pg_temp.r('st_auto')), pg_temp.r('st_auto') ->> 'status', pg_temp.r('st_auto') ->> 'version',
    pg_temp.f('a:2', 'status'), pg_temp.f('a:2', 'status_set'), pg_temp.f('a:2', 'status_reason'), pg_temp.f('a:2', 'total'),
    pg_temp.f('a:2', 'percentage'), pg_temp.reason('result_status_set', pg_temp.k('a:2'))],
  array['ok', 'present', '6', 'present', 'false', 'null', '22.0', '91.7', 'auto: Disqualified by mistake.'],
  'admin_status_survives_prepare_again: auto drops the admin''s status and the candidate is worked out again from the script');

-- ---------------------------------------------------------------------------------------------
-- ties_share_a_rank_within_the_mode
-- ---------------------------------------------------------------------------------------------
insert into res values ('r_prep', pg_temp.prep('admin', 'r'));
select is(array[pg_temp.fs(pg_temp.ns('r', 1, 10), 'total'), pg_temp.fs(pg_temp.ns('r', 1, 10), 'rank'),
    pg_temp.fs(pg_temp.ns('r', 1, 10), 'rank_cohort')],
  array[array['20.0', '16.0', '16.0', '12.0', '10.0', '18.0', '18.0', '9.0', '8.0', '7.0'],
    array['1', '2', '2', '4', '5', '1', '1', '3', '4', '5'], array['5', '5', '5', '5', '5', '5', '5', '5', '5', '5']],
  'ties_share_a_rank_within_the_mode: home 20, 16, 16, 12, 10 rank 1, 2, 2, 4, 5 and the centre''s 18, 18, 9, 8, 7 rank 1, 1, '
  || '3, 4, 5, each of 5 in its own mode');
select is(array[public.result_rank(40, array[50, 40, 40, 30, 20]), public.result_rank(30, array[50, 40, 40, 30, 20]),
    public.result_rank(50, array[50, 40, 40, 30, 20]), public.result_rank(50, array[50, 40, 40, 30]),
    public.result_rank(null, array[50, 40, 40, 30, 20])],
  array[2, 4, 1, null, null],
  'ties_share_a_rank_within_the_mode: the rank helper (1, 2, 2, 4 for 50, 40, 40, 30); none under five totals or without a total');

-- ---------------------------------------------------------------------------------------------
-- cohort_under_five_shows_no_rank_or_figures
-- ---------------------------------------------------------------------------------------------
insert into res values ('s_prep', pg_temp.prep('admin', 's'));
insert into res values ('t_get', pg_temp.get('admin', 't'));
select is(pg_temp.fs(pg_temp.ns('s', 1, 9), 'rank') || pg_temp.fs(pg_temp.ns('s', 1, 9), 'rank_cohort')
    || array[pg_temp.r('s_prep') #>> '{cohort,present}', pg_temp.r('s_prep') #>> '{cohort,average}']
    || pg_temp.fs(pg_temp.ns('t', 1, 4), 'rank') || pg_temp.fs(pg_temp.ns('t', 1, 4), 'rank_cohort')
    || array[coalesce(pg_temp.r('t_prep') ->> 'cohort', 'null'), coalesce(pg_temp.r('t_get') ->> 'cohort', 'null'), pg_temp.er('t', 'cohort'),
      pg_temp.r('t_prep') #>> '{counts,present}'],
  array['null', 'null', 'null', 'null', '1', '2', '3', '4', '5'] || array['null', 'null', 'null', 'null', '5', '5', '5', '5', '5']
    || array['9', '16.0'] || array['null', 'null', 'null', 'null', 'null', 'null', 'null', 'null'] || array['null', 'null', 'null', '4'],
  'cohort_under_five_shows_no_rank_or_figures: four at home have no rank while five at the centre do; four present in all '
  || 'make no cohort figures');

-- ---------------------------------------------------------------------------------------------
-- cohort_figures_are_average_and_quartiles_never_extremes
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.keys(pg_temp.r('r_prep') -> 'cohort'), pg_temp.r('r_prep') #>> '{cohort,present}',
    pg_temp.r('r_prep') #>> '{cohort,average}', pg_temp.r('r_prep') #>> '{cohort,lower_quartile}',
    pg_temp.r('r_prep') #>> '{cohort,upper_quartile}',
    (select string_agg(x ->> 'average', ',' order by o) from jsonb_array_elements(pg_temp.r('r_prep') #> '{cohort,questions}') with ordinality t(x, o)),
    (select string_agg(x ->> 'question_id', ',' order by o) from jsonb_array_elements(pg_temp.r('r_prep') #> '{cohort,questions}') with ordinality t(x, o)),
    (select string_agg(pg_temp.keys(x), ',') from jsonb_array_elements(pg_temp.r('r_prep') #> '{cohort,questions}') x),
    (pg_temp.er('r', 'cohort')::jsonb = pg_temp.r('r_prep') -> 'cohort')::text],
  array['average,lower_quartile,present,questions,upper_quartile', '10', '13.4', '9.3', '17.5', '9.4,1.7,2.1,0.2,0.0',
    concat_ws(',', pg_temp.q('r', '1'), pg_temp.q('r', '2(a)'), pg_temp.q('r', '2(b)'), pg_temp.q('r', '3'), pg_temp.q('r', '4')),
    'average,question_id,average,question_id,average,question_id,average,question_id,average,question_id', 'true'],
  'cohort_figures_are_average_and_quartiles_never_extremes: average 13.4, quartiles 9.25 (half up: 9.3) and 17.5, the '
  || 'average per question in paper order (No response counts 0); no highest or lowest anywhere; kept on the exam');

-- ---------------------------------------------------------------------------------------------
-- results_get_shows_the_batch_totals
-- ---------------------------------------------------------------------------------------------
insert into res values ('r_get', pg_temp.get('admin', 'r'));
select is(array[pg_temp.keys(pg_temp.r('r_get')), pg_temp.keys(pg_temp.r('r_get') -> 'rows' -> 0), pg_temp.r('r_get') ->> 'state',
    pg_temp.r('r_get') ->> 'version', pg_temp.r('r_get') ->> 'max_total', pg_temp.r('r_get') ->> 'more',
    jsonb_array_length(pg_temp.r('r_get') -> 'rows')::text, pg_temp.r('r_get') #>> '{counts,present}',
    pg_temp.bands(pg_temp.r('r_get')), pg_temp.grades(pg_temp.r('r_get')), (pg_temp.r('r_get') -> 'boundaries')::text,
    pg_temp.r('r_get') #>> '{approval,stale}', ((pg_temp.r('r_get') #>> '{approval,approved_at}') is not null)::text,
    (pg_temp.r('r_get') -> 'missing')::text, (pg_temp.r('r_get') -> 'cohort' = pg_temp.r('r_prep') -> 'cohort')::text,
    (select string_agg((x ->> 'name') || ' ' || (x ->> 'rank'), ',' order by x ->> 'booking_id')
     from jsonb_array_elements(pg_temp.r('r_get') -> 'rows') x where x ->> 'booking_id' = pg_temp.k('r:2')::text)],
  array['approval,bands,boundaries,cohort,counts,first_published_at,grades,max_total,missing,more,ok,publish_at,'
      || 'publish_failed_at,publish_failed_reason,published_at,rows,state,version,withdraw_reason,withdrawn_at',
    'booking_id,grade,index_number,name,percentage,rank,rank_cohort,remarked,sitting,status,status_reason,status_set,total,version',
    'prepared', '1', '24.0', 'false', '10', '10', '0-10:0,10-20:0,20-30:1,30-40:2,40-50:1,50-60:1,60-70:2,70-80:2,80-90:1,90-100:0',
    '', '[]', 'false', 'true', '[]', 'true', 'Wilhelmina Quarterfield 2'],
  'results_get_shows_the_batch_totals: state, version, the maximum, candidates by status, 10% bands, no grades without '
  || 'boundaries, the approval (not stale), the cohort, and each candidate by name');

-- ---------------------------------------------------------------------------------------------
-- boundaries_preview_counts_without_saving
-- ---------------------------------------------------------------------------------------------
insert into res values ('r_preview', pg_temp.preview('admin', 'r',
  '[{"grade": "A", "min_mark": 18}, {"grade": "B", "min_mark": 12}, {"grade": "C", "min_mark": 9.5}]'));
select is(array[pg_temp.code(pg_temp.r('r_preview')), pg_temp.keys(pg_temp.r('r_preview')), pg_temp.grades(pg_temp.r('r_preview')),
    concat_ws(' ', pg_temp.r('r_preview') #>> '{below,all}', pg_temp.r('r_preview') #>> '{below,centre}', pg_temp.r('r_preview') #>> '{below,home}'),
    (select count(*)::text from public.grade_boundaries where exam_id = pg_temp.k('r')), pg_temp.er('r', 'version'),
    array_to_string(pg_temp.fs(pg_temp.ns('r', 1, 10), 'grade'), ',')],
  array['ok', 'below,grades,ok', 'A 3 2 1,B 3 0 3,C 1 0 1', '3 3 0', '0', '1', 'null,null,null,null,null,null,null,null,null,null'],
  'boundaries_preview_counts_without_saving: A from 18, B from 12, C from 9.5 counted for all, the centre and home, with '
  || 'those below; nothing is saved and no grade changes');
create temp table bad (n int, g text);
insert into bad values (1, '[{"grade": "A", "min_mark": 12}, {"grade": "B", "min_mark": 12}]'),
  (2, '[{"grade": "A", "min_mark": 24.5}]'),
  (3, (select jsonb_agg(jsonb_build_object('grade', 'G' || i, 'min_mark', 17 - i) order by i)::text from generate_series(1, 16) i)),
  (4, '[{"grade": "ABCDEFGHIJK", "min_mark": 10}]'), (5, '[{"grade": "  ", "min_mark": 10}]'),
  (6, '[{"grade": "A", "min_mark": 12.25}]'), (7, '[{"grade": "A", "min_mark": -1}]'),
  (8, '[{"grade": "A", "min_mark": 18}, {"grade": "A", "min_mark": 12}]'), (9, '{"grade": "A", "min_mark": 18}'), (10, '[]'),
  (11, '[{"grade": "A", "min_mark": "18"}]'), (12, '[{"grade": "A"}]'), (13, '[5]'),
  (14, '[{"grade": "B", "min_mark": 10}, {"grade": "A", "min_mark": 18}]');
select is(array[(select string_agg(n || ' ' || pg_temp.code(pg_temp.preview('admin', 'r', g)), ',' order by n) from bad),
    pg_temp.code(pg_temp.preview('admin', 'r',
      (select jsonb_agg(jsonb_build_object('grade', 'G' || i, 'min_mark', 16 - i) order by i)::text from generate_series(1, 15) i))),
    pg_temp.code(pg_temp.preview('admin', 'r', '[{"grade": " A* ", "min_mark": 24}]')),
    pg_temp.code(pg_temp.bset('admin', 'r', '[{"grade": "A", "min_mark": 25}]', 'Too high.')),
    pg_temp.code(pg_temp.bset('admin', 'r', '[{"grade": "A", "min_mark": 18}]', 'no')),
    pg_temp.code(pg_temp.as('admin', format('select public.grade_boundaries_preview(%L, %L::jsonb)', gen_random_uuid(), '[{"grade": "A", "min_mark": 1}]'))),
    (select count(*)::text from public.grade_boundaries where exam_id = pg_temp.k('r')), pg_temp.er('r', 'version')],
  array['1 invalid_input,2 invalid_input,3 invalid_input,4 invalid_input,5 invalid_input,6 invalid_input,7 invalid_input,'
      || '8 invalid_input,9 invalid_input,10 invalid_input,11 invalid_input,12 invalid_input,13 invalid_input,14 invalid_input',
    'ok', 'ok', 'invalid_input', 'invalid_input', 'not_found', '0', '1'],
  'boundaries_preview_counts_without_saving: 1 to 15 grades, top first, marks strictly decreasing and not above the '
  || 'maximum, at most one decimal, labels of 1 to 10 characters and different; a bad set is never saved');

-- ---------------------------------------------------------------------------------------------
-- grades_follow_raw_mark_boundaries_and_u_below
-- ---------------------------------------------------------------------------------------------
insert into res values ('r_bset', pg_temp.bset('admin', 'r',
  '[{"grade": "A", "min_mark": 18}, {"grade": "B", "min_mark": 12}, {"grade": "C", "min_mark": 9.5}]', 'First boundaries.'));
insert into res values ('r_get2', pg_temp.get('admin', 'r'));
select is(array[pg_temp.code(pg_temp.r('r_bset')), pg_temp.r('r_bset') ->> 'version', pg_temp.er('r', 'version'),
    array_to_string(pg_temp.fs(pg_temp.ns('r', 1, 10), 'grade'), ','), pg_temp.grades(pg_temp.r('r_get2')),
    (select string_agg(x ->> 'grade' || ' ' || (x ->> 'min_mark'), ',' order by o)
       from jsonb_array_elements(pg_temp.r('r_get2') -> 'boundaries') with ordinality t(x, o)),
    (select string_agg(g.position || ' ' || g.grade || ' ' || g.min_mark || ' ' || (g.set_by = pg_temp.uid('admin'))::text, ','
              order by g.position)
       from public.grade_boundaries g where g.exam_id = pg_temp.k('r')),
    pg_temp.audits('grade_boundaries_set', pg_temp.k('r'))::text,
    (pg_temp.reason('grade_boundaries_set', pg_temp.k('r')) like '%First boundaries.')::text],
  array['ok', '2', '2', 'A,B,B,B,C,A,A,U,U,U', 'A 3 2 1,B 3 0 3,C 1 0 1,U 3 3 0', 'A 18.0,B 12.0,C 9.5',
    '1 A 18.0 true,2 B 12.0 true,3 C 9.5 true', '1', 'true'],
  'grades_follow_raw_mark_boundaries_and_u_below: the lowest mark of each grade in raw marks; a total below the lowest gets '
  || 'U; the prepared rows are graded again (version 2) and the change is audited with the reason');
select is(array[public.result_grade(18, '[{"grade": "A", "min_mark": 18}, {"grade": "C", "min_mark": 9.5}]'),
    public.result_grade(9.5, '[{"grade": "A", "min_mark": 18}, {"grade": "C", "min_mark": 9.5}]'),
    public.result_grade(9.4, '[{"grade": "A", "min_mark": 18}, {"grade": "C", "min_mark": 9.5}]'),
    public.result_grade(5, '[]'), public.result_grade(null, '[{"grade": "A", "min_mark": 18}]')],
  array['A', 'C', 'U', null, null],
  'grades_follow_raw_mark_boundaries_and_u_below: the grade helper (none without boundaries or a total)');
insert into res values ('r_clear', pg_temp.bset('admin', 'r', '[]'));
select is(array[pg_temp.code(pg_temp.r('r_clear')), pg_temp.er('r', 'version'),
    (select count(*)::text from public.grade_boundaries where exam_id = pg_temp.k('r')),
    array_to_string(pg_temp.fs(pg_temp.ns('r', 1, 10), 'grade'), ','), pg_temp.grades(pg_temp.get('admin', 'r')),
    pg_temp.audits('grade_boundaries_set', pg_temp.k('r'))::text],
  array['ok', '3', '0', 'null,null,null,null,null,null,null,null,null,null', '', '2'],
  'grades_follow_raw_mark_boundaries_and_u_below: an empty set clears the boundaries: marks and percentage only');

-- ---------------------------------------------------------------------------------------------
-- disqualified_has_no_rank_and_others_close_up
-- ---------------------------------------------------------------------------------------------
insert into res values ('q_prep', pg_temp.prep('admin', 'q'));
select is(array[pg_temp.fs(pg_temp.ns('q', 1, 6), 'rank'), pg_temp.fs(pg_temp.ns('q', 1, 6), 'rank_cohort')],
  array[array['1', '2', '2', '4', '5', '6'], array['6', '6', '6', '6', '6', '6']],
  'disqualified_has_no_rank_and_others_close_up: before, six at home rank 1, 2, 2, 4, 5, 6');
insert into res values ('q_dq', pg_temp.st('admin', 'q:1', 'disqualified', 'Copied from notes.'));
select is(pg_temp.fs(pg_temp.ns('q', 1, 6), 'rank') || pg_temp.fs(pg_temp.ns('q', 1, 6), 'rank_cohort')
    || array[pg_temp.code(pg_temp.r('q_dq')), pg_temp.r('q_dq') ->> 'status', pg_temp.r('q_dq') ->> 'version', pg_temp.er('q', 'version'),
      pg_temp.f('q:1', 'status'), pg_temp.f('q:1', 'status_set'), pg_temp.f('q:1', 'total'), pg_temp.f('q:1', 'percentage'),
      pg_temp.f('q:1', 'grade'), pg_temp.er('q', 'cohort')::jsonb ->> 'present', pg_temp.er('q', 'cohort')::jsonb ->> 'average',
      pg_temp.reason('result_status_set', pg_temp.k('q:1'))],
  array['null', '1', '1', '3', '4', '5'] || array['null', '5', '5', '5', '5', '5']
    || array['ok', 'disqualified', '2', '2', 'disqualified', 'true', 'null', 'null', 'null', '5', '12.4', 'disqualified: Copied from notes.'],
  'disqualified_has_no_rank_and_others_close_up: the disqualified candidate has no total, rank or grade; the others close '
  || 'up (1, 1, 3, 4, 5 of 5) and the cohort figures leave them out (before publication)');

-- ---------------------------------------------------------------------------------------------
-- boundaries_locked_once_published
-- ---------------------------------------------------------------------------------------------
update public.exam_results set state = 'published' where exam_id = pg_temp.k('q');
insert into res values ('q_pub_bset', pg_temp.bset('admin', 'q', '[{"grade": "A", "min_mark": 10}]', 'After publishing.'));
insert into res values ('q_pub_prep', pg_temp.prep('admin', 'q'));
insert into res values ('q_pub_st', pg_temp.st('admin', 'q:2', 'absent', 'After publishing.'));
insert into res values ('q_pub_preview', pg_temp.preview('admin', 'q', '[{"grade": "A", "min_mark": 10}]'));
update public.exam_results set state = 'scheduled' where exam_id = pg_temp.k('q');
insert into res values ('q_sch_bset', pg_temp.bset('admin', 'q', '[{"grade": "A", "min_mark": 10}]', 'While scheduled.'));
insert into res values ('q_sch_prep', pg_temp.prep('admin', 'q'));
insert into res values ('q_sch_st', pg_temp.st('admin', 'q:2', 'absent', 'While scheduled.'));
select is(array[pg_temp.code(pg_temp.r('q_pub_bset')), pg_temp.code(pg_temp.r('q_pub_prep')), pg_temp.code(pg_temp.r('q_pub_st')),
    pg_temp.code(pg_temp.r('q_pub_preview')), pg_temp.code(pg_temp.r('q_sch_bset')), pg_temp.code(pg_temp.r('q_sch_prep')),
    pg_temp.code(pg_temp.r('q_sch_st')), (select count(*)::text from public.grade_boundaries where exam_id = pg_temp.k('q')),
    pg_temp.er('q', 'version'), pg_temp.f('q:2', 'status'), pg_temp.audits('grade_boundaries_set', pg_temp.k('q'))::text],
  array['results_published', 'results_published', 'results_published', 'ok', 'results_published', 'results_published',
    'results_published', '0', '2', 'present', '0'],
  'boundaries_locked_once_published: published or scheduled results refuse boundaries, preparing and statuses (a preview '
  || 'still answers); nothing changes');

-- ---------------------------------------------------------------------------------------------
-- approval_withdraw_refused_once_published
-- ---------------------------------------------------------------------------------------------
insert into res values ('q_sch_wd', pg_temp.withdraw('admin', 'q', 'Marks need another look.'));
update public.exam_results set state = 'published' where exam_id = pg_temp.k('q');
insert into res values ('q_pub_wd', pg_temp.withdraw('admin', 'q', 'Marks need another look.'));
create temp table q_approved as select (approved_at is not null) as yes from public.exam_marking where exam_id = pg_temp.k('q');
update public.exam_results set state = 'prepared' where exam_id = pg_temp.k('q');
insert into res values ('q_prep_wd', pg_temp.withdraw('admin', 'q', 'Marks need another look.'));
select is(array[pg_temp.code(pg_temp.r('q_sch_wd')), pg_temp.code(pg_temp.r('q_pub_wd')), (select yes::text from q_approved),
    pg_temp.code(pg_temp.r('q_prep_wd')), pg_temp.r('q_prep_wd') ->> 'already',
    (select (approved_at is null)::text from public.exam_marking where exam_id = pg_temp.k('q')),
    pg_temp.audits('marking_approval_withdrawn', pg_temp.k('q'))::text],
  array['results_published', 'results_published', 'true', 'ok', 'false', 'true', '1'],
  'approval_withdraw_refused_once_published: the marking approval stays while results are scheduled or published, and '
  || 'can be withdrawn once they are only prepared');
insert into res values ('q_prep_unapproved', pg_temp.prep('admin', 'q'));
select is(pg_temp.code(pg_temp.r('q_prep_unapproved')), 'marking_not_approved',
  'approval_withdraw_refused_once_published: once the approval is withdrawn the results cannot be prepared again');

-- ---------------------------------------------------------------------------------------------
-- export_is_recorded
-- ---------------------------------------------------------------------------------------------
insert into res values ('a_export', pg_temp.export('admin', 'a'));
select is(array[pg_temp.code(pg_temp.r('a_export')), pg_temp.keys(pg_temp.r('a_export')),
    jsonb_array_length(pg_temp.r('a_export') -> 'rows')::text, ((pg_temp.r('a_export') ->> 'filename') ~ '^results-[A-Za-z0-9-]+\.csv$')::text,
    (select string_agg(x ->> 'label', ',' order by o) from jsonb_array_elements(
       (select x -> 'marks' from jsonb_array_elements(pg_temp.r('a_export') -> 'rows') x where x ->> 'booking_id' = pg_temp.k('a:1')::text))
       with ordinality t(x, o)),
    (select string_agg(coalesce(x ->> 'mark', 'null') || ' ' || (x ->> 'not_attempted'), ',' order by o) from jsonb_array_elements(
       (select x -> 'marks' from jsonb_array_elements(pg_temp.r('a_export') -> 'rows') x where x ->> 'booking_id' = pg_temp.k('a:1')::text))
       with ordinality t(x, o)),
    (select string_agg(coalesce(x ->> 'mark', 'null'), ',' order by o) from jsonb_array_elements(
       (select x -> 'marks' from jsonb_array_elements(pg_temp.r('a_export') -> 'rows') x where x ->> 'booking_id' = pg_temp.k('vd')::text))
       with ordinality t(x, o)),
    (select concat_ws(' ', x ->> 'name', x ->> 'status', x ->> 'total', x ->> 'max_total', x ->> 'percentage')
       from jsonb_array_elements(pg_temp.r('a_export') -> 'rows') x where x ->> 'booking_id' = pg_temp.k('a:1')::text),
    pg_temp.audits('results_exported', pg_temp.k('a'))::text,
    (select (actor_id = pg_temp.uid('admin'))::text from public.audit_log where action = 'results_exported' and target_id = pg_temp.k('a'))],
  array['ok', 'filename,ok,rows', '12', 'true', '1,2(a),2(b),3,4', '9.0 false,3.0 false,5.0 false,6.0 false,null true',
    'null,null,null,null,null', 'Wilhelmina Quarterfield present 23.0 24.0 95.8', '1', 'true'],
  'export_is_recorded: every candidate with each question''s mark in paper order (No response kept), and the download is '
  || 'audited in the same call');

-- ---------------------------------------------------------------------------------------------
-- admins_only (lead, teacher, corrector, student, parent -> forbidden; nothing written)
-- ---------------------------------------------------------------------------------------------
create function pg_temp.all_codes(p_who text) returns text language sql as $$
  select concat_ws(',', pg_temp.code(pg_temp.prep(p_who, 'a')), pg_temp.code(pg_temp.get(p_who, 'a')),
    pg_temp.code(pg_temp.st(p_who, 'a:3', 'absent', 'Not allowed.')),
    pg_temp.code(pg_temp.preview(p_who, 'r', '[{"grade": "A", "min_mark": 10}]')),
    pg_temp.code(pg_temp.bset(p_who, 'r', '[{"grade": "A", "min_mark": 10}]', 'Not allowed.')),
    pg_temp.code(pg_temp.export(p_who, 'a'))) $$;
select is(array[pg_temp.all_codes('lead'), pg_temp.all_codes('teacher'), pg_temp.all_codes('corrector'),
    pg_temp.all_codes('student'), pg_temp.all_codes('parent'), pg_temp.er('a', 'version'), pg_temp.er('r', 'version'),
    pg_temp.f('a:3', 'status'), (select count(*)::text from public.grade_boundaries where exam_id = pg_temp.k('r')),
    pg_temp.audits('results_exported', pg_temp.k('a'))::text, pg_temp.audits('results_prepared', pg_temp.k('a'))::text],
  array['forbidden,forbidden,forbidden,forbidden,forbidden,forbidden', 'forbidden,forbidden,forbidden,forbidden,forbidden,forbidden',
    'forbidden,forbidden,forbidden,forbidden,forbidden,forbidden', 'forbidden,forbidden,forbidden,forbidden,forbidden,forbidden',
    'forbidden,forbidden,forbidden,forbidden,forbidden,forbidden', '6', '3', 'present', '0', '1', '2'],
  'admins_only: the lead marker, a teacher, a corrector, the candidate and their parent are refused every results call, '
  || 'and nothing is written');
select is(array[
    has_function_privilege('anon', 'public.results_prepare(uuid)', 'execute'),
    has_function_privilege('anon', 'public.results_get(uuid)', 'execute'),
    has_function_privilege('anon', 'public.result_status_set(uuid, text, text)', 'execute'),
    has_function_privilege('anon', 'public.grade_boundaries_preview(uuid, jsonb)', 'execute'),
    has_function_privilege('anon', 'public.grade_boundaries_set(uuid, jsonb, text)', 'execute'),
    has_function_privilege('anon', 'public.results_export(uuid)', 'execute'),
    has_function_privilege('anon', 'public.marking_approval_withdraw(uuid, text)', 'execute'),
    has_function_privilege('authenticated', 'public.results_prepare(uuid)', 'execute'),
    has_function_privilege('authenticated', 'public.results_get(uuid)', 'execute'),
    has_function_privilege('authenticated', 'public.result_status_set(uuid, text, text)', 'execute'),
    has_function_privilege('authenticated', 'public.grade_boundaries_preview(uuid, jsonb)', 'execute'),
    has_function_privilege('authenticated', 'public.grade_boundaries_set(uuid, jsonb, text)', 'execute'),
    has_function_privilege('authenticated', 'public.results_export(uuid)', 'execute'),
    has_function_privilege('authenticated', 'public.marking_approval_withdraw(uuid, text)', 'execute')],
  array[false, false, false, false, false, false, false, true, true, true, true, true, true, true],
  'admins_only: anon cannot call the results functions; signed-in users can (each checks for an admin)');
select is((select array_agg(p.proname::text || ' ' || has_function_privilege(r.rolname, p.oid, 'execute')::text order by p.proname, r.rolname)
           from pg_proc p cross join (values ('authenticated'), ('service_role')) r(rolname)
           where p.pronamespace = 'public'::regnamespace
             and p.proname in ('exam_max_total', 'result_percentage', 'result_grade', 'result_rank', 'result_cohort_min', 'exam_grades',
                               'results_questions', 'results_cohort', 'results_counts', 'results_missing', 'results_write',
                               'results_rank', 'grade_boundaries_valid')
             and has_function_privilege(r.rolname, p.oid, 'execute')),
  null::text[],
  'admins_only: the internal helpers are callable by no client role, the service role included');

-- ---------------------------------------------------------------------------------------------
-- prepare_and_get_in_time_at_1500_candidates (a timing guard, as Phase 3B R22: the fixture tables are analysed first).
-- Exam big: 1,000 candidates at home and 500 at a centre, each with a checked script and its final marks (totals 1 to
-- 24 and 0, round and round). As an admin, preparing must answer within 4 s and the results page within 2 s, under the
-- 8 s statement timeout a signed-in call meets. A status change (one candidate disqualified, every rank worked out
-- again) is timed for the report only.
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
insert into kv select 'big:dq', s.booking_id from public.scripts s where s.exam_id = pg_temp.k('big') order by s.number limit 1;
analyze public.bookings, public.scripts, public.marking_units, public.final_marks, public.exam_questions, public.exam_option_groups,
        public.attendance, public.results, public.exam_results, public.grade_boundaries, public.profiles, public.student_details,
        public.script_pages, public.script_page_links, public.script_uploads, public.home_submissions, public.script_exceptions,
        public.marking_alerts, public.exam_markers, public.exam_marking, public.exams;
select tests.as_user(pg_temp.uid('admin'));
set local statement_timeout = '4s';
insert into res values ('big_prep', pg_temp.timed('ms_prep', format('select public.results_prepare(%L)', pg_temp.k('big'))));
reset statement_timeout;
select tests.as_postgres();
analyze public.results, public.exam_results;
select tests.as_user(pg_temp.uid('admin'));
set local statement_timeout = '2s';
insert into res values ('big_get', pg_temp.timed('ms_get', format('select public.results_get(%L)', pg_temp.k('big'))));
set local statement_timeout = '8s';
insert into res values ('big_st', pg_temp.timed('ms_st',
  format('select public.result_status_set(%L, %L, %L)', pg_temp.k('big:dq'), 'disqualified', 'Timing check.')));
reset statement_timeout;
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('big_prep')), pg_temp.r('big_prep') #>> '{counts,present}',
    pg_temp.r('big_prep') #>> '{cohort,present}', pg_temp.code(pg_temp.r('big_get')),
    jsonb_array_length(pg_temp.r('big_get') -> 'rows')::text, pg_temp.r('big_get') ->> 'more', pg_temp.code(pg_temp.r('big_st')),
    ((pg_temp.r('ms_prep') ->> 'ms')::int <= 4000)::text, ((pg_temp.r('ms_get') ->> 'ms')::int <= 2000)::text],
  array['ok', '1500', '1500', 'ok', '1500', 'false', 'ok', 'true', 'true'],
  'prepare_and_get_in_time_at_1500_candidates: preparing 1,500 candidates within 4 s and the results page within 2 s');
select diag('results_prepare at 1,500 candidates: ' || (pg_temp.r('ms_prep') ->> 'ms') || ' ms; results_get: '
  || (pg_temp.r('ms_get') ->> 'ms') || ' ms; result_status_set (re-ranking 1,500): ' || (pg_temp.r('ms_st') ->> 'ms') || ' ms');

select * from finish();
rollback;
