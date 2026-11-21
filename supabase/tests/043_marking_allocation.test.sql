begin;
create extension if not exists pgtap with schema extensions;
select plan(158);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Subject s1 ('ZZ Allocation'), taught by the teacher: correctors m1 (Mara One), m2 (Milo Two), m3, the lead
-- marker and fresh markers f1 to f6 are approved for it; susp is approved but suspended; corr is never approved. Subject
-- s2 has its own lead, lead2. Each test uses its own exams (tests.marking_exam: finished 2 days ago, so home scripts may
-- be handed out), opened here as postgres; scripts are made where a test needs them. A unit is kept as 'u:<script>'.
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values
  ('admin', tests.create_user('admin', 'active')),
  ('teacher', tests.create_user('teacher', 'active')),
  ('m1', tests.create_user('corrector', 'active')),
  ('m2', tests.create_user('corrector', 'active')),
  ('m3', tests.create_user('corrector', 'active')),
  ('lead', tests.create_user('corrector', 'active')),
  ('lead2', tests.create_user('corrector', 'active')),
  ('corr', tests.create_user('corrector', 'active')),
  ('susp', tests.create_user('corrector', 'suspended')),
  ('f1', tests.create_user('corrector', 'active')),
  ('f2', tests.create_user('corrector', 'active')),
  ('f3', tests.create_user('corrector', 'active')),
  ('f4', tests.create_user('corrector', 'active')),
  ('f5', tests.create_user('corrector', 'active')),
  ('f6', tests.create_user('corrector', 'active'));
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create temp table res (name text primary key, j jsonb);
grant all on res to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
-- A script's unit (every exam here is marked as whole scripts).
create function pg_temp.u(p text) returns uuid language sql stable as $$ select id from kv where name = 'u:' || p $$;
create function pg_temp.r(p text) returns jsonb language sql stable as $$ select j from res where name = p $$;
create function pg_temp.s1() returns bigint language sql stable as $$ select id from public.subjects where name = 'ZZ Allocation' $$;
create function pg_temp.s2() returns bigint language sql stable as $$ select id from public.subjects where name = 'ZZ Allocation two' $$;
-- A function's answer: 'ok', or its code.
create function pg_temp.code(j jsonb) returns text language sql immutable as $$
  select case when (j ->> 'ok')::boolean then 'ok' else coalesce(j ->> 'code', 'none') end $$;
-- A test user's name in c.
create function pg_temp.who(p uuid) returns text language sql stable as $$ select coalesce((select name from c where id = p), '?') $$;
-- Who holds a script's piece, and how ('-' for nobody).
create function pg_temp.holder(p text) returns text language sql stable as $$
  select coalesce(string_agg(pg_temp.who(a.marker_id) || ' ' || a.how, ',' order by a.created_at), '-')
  from public.marking_assignments a where a.unit_id = pg_temp.u(p) and a.kind = 'live' and a.ended_at is null $$;
-- A script's piece's state, and the script's.
create function pg_temp.us(p text) returns text language sql stable as $$ select state from public.marking_units where id = pg_temp.u(p) $$;
create function pg_temp.st(p text) returns text language sql stable as $$ select state::text from public.scripts where id = pg_temp.k(p) $$;
-- A marker's live marking on a script's piece: its status and why it was set aside ('-' for none).
create function pg_temp.ms(p text, p_marker text) returns text language sql stable as $$
  select coalesce((select m.status || coalesce(' ' || m.set_aside_reason, '') from public.markings m
                   where m.unit_id = pg_temp.u(p) and m.kind = 'live' and m.marker_id = pg_temp.uid(p_marker)), '-') $$;
-- How many audit rows of this action concern this target.
create function pg_temp.audits(p_action text, p_target uuid) returns int language sql stable as $$
  select count(*)::int from public.audit_log a where a.action = p_action and a.target_id = p_target $$;
-- A new verified home script of an exam.
create function pg_temp.script(p_name text, p_exam text) returns void language sql as $$
  insert into kv values (p_name, tests.verified_script(pg_temp.k(p_exam))) $$;
-- Opens an exam's marking (as marking_open would), makes its verified scripts ready, and keeps their units.
create function pg_temp.open(p text) returns void language plpgsql as $$
begin
  insert into public.exam_marking (exam_id, opened_at, opened_by) values (pg_temp.k(p), now(), pg_temp.uid('admin'))
  on conflict (exam_id) do update set opened_at = excluded.opened_at, closed_at = null;
  perform public.marking_exam_sync(pg_temp.k(p), null);
  insert into kv select 'u:' || x.name, u.id from kv x join public.marking_units u on u.script_id = x.id on conflict (name) do nothing;
end $$;
-- The candidate of a script.
create function pg_temp.student(p text) returns uuid language sql stable as $$
  select b.student_id from public.scripts s join public.bookings b on b.id = s.booking_id where s.id = pg_temp.k(p) $$;
-- The file holding a script's first page.
create function pg_temp.upload(p text) returns uuid language sql stable as $$
  select pg.upload_id from public.scripts s
  join public.script_page_links l on l.script_id = s.id and l.version = s.version
  join public.script_pages pg on pg.id = l.page_id
  where s.id = pg_temp.k(p) order by l.copy_page limit 1 $$;
-- A marking the marker started on a script's piece (as Task 6's first open makes it), with question 1 marked 2.
create function pg_temp.started(p text, p_marker text) returns uuid language plpgsql as $$
declare
  v uuid;
begin
  insert into public.markings (unit_id, marker_id) values (pg_temp.u(p), pg_temp.uid(p_marker)) returning id into v;
  insert into public.question_marks (marking_id, question_id, mark)
  select v, q.id, 2 from public.exam_questions q
  where q.exam_id = (select exam_id from public.marking_units where id = pg_temp.u(p)) and q.label = '1' and q.parent_id is null;
  return v;
end $$;
-- A script's piece marked and submitted by the marker an hour ago (total 8, question 1 marked 3), their hold ended.
create function pg_temp.submitted(p text, p_marker text) returns uuid language plpgsql as $$
declare
  v uuid;
begin
  update public.marking_units set state = 'submitted' where id = pg_temp.u(p);
  insert into public.markings (unit_id, marker_id, status, total, last_saved_at, submitted_at)
  values (pg_temp.u(p), pg_temp.uid(p_marker), 'submitted', 8, now() - interval '1 hour', now() - interval '1 hour') returning id into v;
  insert into public.question_marks (marking_id, question_id, mark)
  select v, q.id, 3 from public.exam_questions q
  where q.exam_id = (select exam_id from public.marking_units where id = pg_temp.u(p)) and q.label = '1' and q.parent_id is null;
  insert into public.marking_assignments (unit_id, marker_id, how, hold_until, created_at, ended_at, end_reason)
  values (pg_temp.u(p), pg_temp.uid(p_marker), 'next', now() + interval '1 hour', now() - interval '2 hours', now() - interval '1 hour', 'submitted');
  perform public.marking_script_state(pg_temp.k(p));
  return v;
end $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.u(text), pg_temp.r(text), pg_temp.s1(), pg_temp.s2(),
  pg_temp.code(jsonb), pg_temp.who(uuid) to public;

insert into public.subjects (name, kind) values ('ZZ Allocation', 'school'), ('ZZ Allocation two', 'school');
insert into public.teacher_subjects values (pg_temp.uid('teacher'), pg_temp.s1());
insert into public.marker_approvals (marker_id, subject_id, lead, approved_at)
select c.id, pg_temp.s1(), c.name = 'lead', now() from c where c.name in ('m1', 'm2', 'm3', 'lead', 'susp', 'f1', 'f2', 'f3', 'f4', 'f5', 'f6');
insert into public.marker_approvals (marker_id, subject_id, lead, approved_at) values (pg_temp.uid('lead2'), pg_temp.s2(), true, now());
update public.profiles set first_name = 'Mara', last_name = 'One' where id = pg_temp.uid('m1');
update public.profiles set first_name = 'Milo', last_name = 'Two' where id = pg_temp.uid('m2');

-- ---------------------------------------------------------------------------------------------
-- next_gives_a_ready_piece_and_holds_it_two_hours
-- ---------------------------------------------------------------------------------------------
insert into kv values ('e1', tests.marking_exam(pg_temp.s1()));
select tests.structure(pg_temp.k('e1'));
select pg_temp.script('n1', 'e1');
select pg_temp.open('e1');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('next1', public.marking_next(pg_temp.k('e1')));
select tests.as_postgres();
select is(pg_temp.r('next1'), jsonb_build_object('ok', true, 'unit_id', pg_temp.u('n1'), 'resumed', false),
  'next_gives_a_ready_piece_and_holds_it_two_hours: m1 presses Next script and is given the ready piece');
select is(pg_temp.holder('n1'), 'm1 next', 'm1 holds it, by Next script');
select is((select a.hold_until = now() + interval '2 hours' and a.assigned_by is null from public.marking_assignments a
           where a.unit_id = pg_temp.u('n1') and a.ended_at is null), true, 'for 2 hours');
select is(array[pg_temp.us('n1'), pg_temp.st('n1')], array['taken', 'marking'], 'the piece is taken and the script is being marked');
select is((select count(*)::int from public.audit_log a where a.action = 'marking_unit_taken' and a.target_type = 'marking_unit'
             and a.target_id = pg_temp.u('n1') and a.actor_id = pg_temp.uid('m1')), 1, 'an audit row says who took it');
select is((select count(*)::int from public.markings where unit_id = pg_temp.u('n1')), 0, 'no marking yet: it starts when the piece is opened');

-- ---------------------------------------------------------------------------------------------
-- next_returns_the_piece_already_held
-- ---------------------------------------------------------------------------------------------
select pg_temp.script('n2', 'e1');
select pg_temp.open('e1');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('next2', public.marking_next(pg_temp.k('e1'), null, now() + interval '1 hour'));
select tests.as_postgres();
select is(pg_temp.r('next2'), jsonb_build_object('ok', true, 'unit_id', pg_temp.u('n1'), 'resumed', true),
  'next_returns_the_piece_already_held: an hour later m1 presses it again and gets the same piece back');
select is((select count(*)::int from public.marking_assignments a where a.marker_id = pg_temp.uid('m1') and a.ended_at is null
             and a.unit_id in (pg_temp.u('n1'), pg_temp.u('n2'))), 1, 'm1 still holds only that one');
select is((select a.hold_until = now() + interval '3 hours' from public.marking_assignments a where a.unit_id = pg_temp.u('n1') and a.ended_at is null),
  true, 'its hold is renewed: 2 hours from then');
select is(pg_temp.us('n2'), 'open', 'the other piece is still free');
select is(pg_temp.audits('marking_unit_taken', pg_temp.u('n1')), 1, 'resuming a piece writes no second audit row');

-- ---------------------------------------------------------------------------------------------
-- two_markers_one_piece_never_both (Review Focus 4)
-- ---------------------------------------------------------------------------------------------
insert into kv values ('e3', tests.marking_exam(pg_temp.s1()));
select pg_temp.script('w1', 'e3');
select pg_temp.open('e3');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('w_m1', public.marking_next(pg_temp.k('e3')));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m2'));
insert into res values ('w_m2', public.marking_next(pg_temp.k('e3')));
select tests.as_postgres();
select is(pg_temp.r('w_m1'), jsonb_build_object('ok', true, 'unit_id', pg_temp.u('w1'), 'resumed', false),
  'two_markers_one_piece_never_both: m1 presses Next script and gets the one piece left');
select is(pg_temp.r('w_m2'), '{"ok": false, "code": "nothing_left"}'::jsonb, 'm2 presses it next and is told nothing is left');
select is(pg_temp.holder('w1'), 'm1 next', 'only m1 holds it');
-- The two selects of Next script in one transaction.
insert into kv values ('e3b', tests.marking_exam(pg_temp.s1()));
select pg_temp.script('w2', 'e3b');
select pg_temp.open('e3b');
select is(public.marking_unit_pick(pg_temp.k('e3b'), null, pg_temp.uid('m1'), null), pg_temp.u('w2'),
  'the select of Next script (for update skip locked) offers m1 the piece');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('w2_m1', public.marking_next(pg_temp.k('e3b')));
select tests.as_postgres();
select is(pg_temp.r('w2_m1') ->> 'unit_id', pg_temp.u('w2')::text, 'm1 takes it');
select is(public.marking_unit_pick(pg_temp.k('e3b'), null, pg_temp.uid('m2'), null), null::uuid, 'the same select for m2 then returns no row');
select ok(pg_get_functiondef('public.marking_unit_pick(uuid, uuid, uuid, timestamptz)'::regprocedure) ~* 'for update of u skip locked',
  'the select skips a piece another marker''s Next script has locked');
select throws_ok(format('insert into public.marking_assignments (unit_id, marker_id, how) values (%L, %L, %L)',
                        pg_temp.u('w2'), pg_temp.uid('m2'), 'next'), '23505', null,
  'and the database refuses a second holder of a piece');

-- ---------------------------------------------------------------------------------------------
-- next_is_random
-- ---------------------------------------------------------------------------------------------
insert into kv values ('er', tests.marking_exam(pg_temp.s1()));
do $$ begin for i in 1..40 loop perform pg_temp.script('rs' || i, 'er'); end loop; end $$;
select pg_temp.open('er');
-- The pieces were all made in this transaction: they are spread a minute apart.
update public.marking_units u set created_at = now() - x.n * interval '1 minute'
from (select id, row_number() over (order by id) as n from public.marking_units where exam_id = pg_temp.k('er')) x where u.id = x.id;
select is((select count(*)::int from public.marking_units where exam_id = pg_temp.k('er') and state = 'open'), 40, 'next_is_random: 40 open pieces');
select tests.as_user(pg_temp.uid('f1')); insert into res values ('f1', public.marking_next(pg_temp.k('er'))); select tests.as_postgres();
select tests.as_user(pg_temp.uid('f2')); insert into res values ('f2', public.marking_next(pg_temp.k('er'))); select tests.as_postgres();
select tests.as_user(pg_temp.uid('f3')); insert into res values ('f3', public.marking_next(pg_temp.k('er'))); select tests.as_postgres();
select tests.as_user(pg_temp.uid('f4')); insert into res values ('f4', public.marking_next(pg_temp.k('er'))); select tests.as_postgres();
select tests.as_user(pg_temp.uid('f5')); insert into res values ('f5', public.marking_next(pg_temp.k('er'))); select tests.as_postgres();
select tests.as_user(pg_temp.uid('f6')); insert into res values ('f6', public.marking_next(pg_temp.k('er'))); select tests.as_postgres();
select is((select count(distinct j ->> 'unit_id')::int from res where name in ('f1', 'f2', 'f3', 'f4', 'f5', 'f6')
             and (j ->> 'ok')::boolean and not (j ->> 'resumed')::boolean), 6, 'six fresh markers each get a different piece');
select isnt(array(select (j ->> 'unit_id')::uuid from res where name in ('f1', 'f2', 'f3', 'f4', 'f5', 'f6') order by 1),
            array(select t.id from (select u.id from public.marking_units u where u.exam_id = pg_temp.k('er') order by u.created_at limit 6) t order by 1),
  'and not simply the six oldest: the choice is random');

-- ---------------------------------------------------------------------------------------------
-- next_skips_declared_conflict_and_tutor_link
-- ---------------------------------------------------------------------------------------------
insert into kv values ('ec', tests.marking_exam(pg_temp.s1()));
select pg_temp.script('cx', 'ec');
select pg_temp.script('cy', 'ec');
select pg_temp.script('cz', 'ec');
select pg_temp.open('ec');
insert into public.marker_conflicts (marker_id, student_id, recorded_at) values (pg_temp.uid('m1'), pg_temp.student('cx'), now());
insert into public.tutor_students (tutor_id, student_id) values (pg_temp.uid('m1'), pg_temp.student('cy'));
select is(array[public.marking_unit_blocked(pg_temp.u('cx'), pg_temp.uid('m1'), null, true),
                public.marking_unit_blocked(pg_temp.u('cy'), pg_temp.uid('m1'), null, true),
                coalesce(public.marking_unit_blocked(pg_temp.u('cz'), pg_temp.uid('m1'), null, true), 'ok')],
  array['conflict_of_interest', 'conflict_of_interest', 'ok'],
  'next_skips_declared_conflict_and_tutor_link: a declared conflict and a tutor link keep m1 off two of the candidates');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('ec_m1', public.marking_next(pg_temp.k('ec')));
select tests.as_postgres();
select is(pg_temp.r('ec_m1') ->> 'unit_id', pg_temp.u('cz')::text, 'm1 is given the third piece');
select is(public.marking_unit_pick(pg_temp.k('ec'), null, pg_temp.uid('m1'), null), null::uuid, 'and nothing more is offered to m1');
select tests.as_user(pg_temp.uid('m2'));
insert into res values ('ec_m2', public.marking_next(pg_temp.k('ec')));
select tests.as_postgres();
select ok(pg_temp.r('ec_m2') ->> 'unit_id' in (pg_temp.u('cx')::text, pg_temp.u('cy')::text), 'another marker may be given either of the two');

-- ---------------------------------------------------------------------------------------------
-- next_skips_units_on_hold_busy_or_taken_back
-- ---------------------------------------------------------------------------------------------
insert into kv values ('eh', tests.marking_exam(pg_temp.s1()));
select pg_temp.script('hh', 'eh');
select pg_temp.script('hb', 'eh');
select pg_temp.script('ht', 'eh');
select pg_temp.script('ho', 'eh');
select pg_temp.open('eh');
update public.marking_units set on_hold = true, hold_reason = 'picture_changed' where id = pg_temp.u('hh');
insert into public.processing_jobs (upload_id, kind, state) values (pg_temp.upload('hb'), 'remask', 'queued');
update public.scripts set taken_back_at = now(), taken_back_by = pg_temp.uid('admin'), taken_back_reason = 'A name shows' where id = pg_temp.k('ht');
select is(array[public.marking_unit_blocked(pg_temp.u('hh'), pg_temp.uid('m1'), null, true),
                public.marking_unit_blocked(pg_temp.u('hb'), pg_temp.uid('m1'), null, true),
                public.marking_unit_blocked(pg_temp.u('ht'), pg_temp.uid('m1'), null, true)],
  array['on_hold', 'not_ready', 'not_ready'],
  'next_skips_units_on_hold_busy_or_taken_back: a piece on hold, one whose pictures are being updated and one taken back are held back');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('eh1', public.marking_next(pg_temp.k('eh')));
select tests.as_postgres();
select is(pg_temp.r('eh1') ->> 'unit_id', pg_temp.u('ho')::text, 'm1 is given the only other piece');
-- The piece m1 holds is put on hold.
update public.marking_units set on_hold = true, hold_reason = 'picture_changed' where id = pg_temp.u('ho');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('eh2', public.marking_next(pg_temp.k('eh')));
select tests.as_postgres();
select is(pg_temp.r('eh2'), '{"ok": false, "code": "nothing_left"}'::jsonb, 'Next script does not resume a held piece that is now on hold');
select is(pg_temp.holder('ho'), 'm1 next', 'm1 keeps it, for when the hold is lifted');
update public.processing_jobs set state = 'done', finished_at = now() where upload_id = pg_temp.upload('hb') and kind = 'remask';
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('eh3', public.marking_next(pg_temp.k('eh')));
select tests.as_postgres();
select is(pg_temp.r('eh3') ->> 'unit_id', pg_temp.u('hb')::text, 'once its pictures are updated, that piece is handed out');

-- ---------------------------------------------------------------------------------------------
-- next_skips_the_marker_who_saw_a_name
-- ---------------------------------------------------------------------------------------------
insert into kv values ('en', tests.marking_exam(pg_temp.s1()));
select pg_temp.script('na', 'en');
select pg_temp.script('nb', 'en');
select pg_temp.open('en');
insert into public.marking_unit_exclusions (unit_id, marker_id, reason) values (pg_temp.u('na'), pg_temp.uid('m1'), 'name_seen');
select is(public.marking_unit_blocked(pg_temp.u('na'), pg_temp.uid('m1'), null, true), 'name_seen',
  'next_skips_the_marker_who_saw_a_name: m1 saw a name on one piece');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('en1', public.marking_next(pg_temp.k('en')));
select tests.as_postgres();
select is(pg_temp.r('en1') ->> 'unit_id', pg_temp.u('nb')::text, 'Next script gives m1 the other one');
select is(public.marking_unit_pick(pg_temp.k('en'), null, pg_temp.uid('m1'), null), null::uuid, 'and never that one');
select tests.as_user(pg_temp.uid('m2'));
insert into res values ('en2', public.marking_next(pg_temp.k('en')));
select tests.as_postgres();
select is(pg_temp.r('en2') ->> 'unit_id', pg_temp.u('na')::text, 'another marker is given it');
select tests.as_user(pg_temp.uid('admin'));
select is(public.marking_reassign(array[pg_temp.u('na')], pg_temp.uid('m1'), 'The name is hidden now'),
  '{"ok": true, "taken_back": 1, "assigned": 1, "skipped": []}'::jsonb, 'an admin can still give it to m1 on purpose');
select tests.as_postgres();
select is(pg_temp.holder('na'), 'm1 assigned', 'm1 holds it, assigned');

-- ---------------------------------------------------------------------------------------------
-- next_refused_when_not_approved_not_open_or_closed
-- ---------------------------------------------------------------------------------------------
insert into kv values ('e0', tests.marking_exam(pg_temp.s1()));
select pg_temp.script('z0', 'e0');
with g as (insert into public.question_groups (exam_id, label, position) values (pg_temp.k('e0'), 'G1', 1) returning id)
insert into kv select 'g0', id from g;
insert into kv values ('ez', tests.marking_exam(pg_temp.s1()));
select pg_temp.script('zc', 'ez');
select pg_temp.open('ez');
update public.exam_marking set closed_at = now(), closed_by = pg_temp.uid('admin') where exam_id = pg_temp.k('ez');
select tests.as_user(pg_temp.uid('corr'));
select is(pg_temp.code(public.marking_next(pg_temp.k('e1'))), 'not_approved',
  'next_refused_when_not_approved_not_open_or_closed: a corrector not approved for the subject is refused');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('susp'));
select is(pg_temp.code(public.marking_next(pg_temp.k('e1'))), 'not_approved', 'so is a suspended marker');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_next(pg_temp.k('e1'))), 'not_approved', 'and an admin, who is not a marker');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('teacher'));
select is(pg_temp.code(public.marking_next(pg_temp.k('e1'))), 'not_approved', 'and a teacher of the subject not approved to mark it');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.code(public.marking_next(pg_temp.k('e0'))), 'marking_not_open', 'an approved marker is refused while marking has not opened');
select is(pg_temp.code(public.marking_next(pg_temp.k('ez'))), 'marking_closed', 'and once it has closed');
select is(array[pg_temp.code(public.marking_next(null)), pg_temp.code(public.marking_next(gen_random_uuid())),
                pg_temp.code(public.marking_next(pg_temp.k('e1'), pg_temp.k('g0')))],
  array['invalid_input', 'not_found', 'invalid_input'], 'an exam is needed, one that exists, and a group of that exam');
select tests.as_postgres();
select is((select count(*)::int from public.marking_assignments a join public.marking_units u on u.id = a.unit_id
           where u.exam_id in (pg_temp.k('e0'), pg_temp.k('ez'))), 0, 'nothing was handed out');
select is(pg_temp.st('z0'), 'verified', 'the script of the exam not open stays verified');

-- ---------------------------------------------------------------------------------------------
-- hold_expires_and_piece_goes_to_another_marker
-- ---------------------------------------------------------------------------------------------
insert into kv values ('ex', tests.marking_exam(pg_temp.s1()));
select tests.structure(pg_temp.k('ex'));
select pg_temp.script('x1', 'ex');
select pg_temp.open('ex');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('x_m1', public.marking_next(pg_temp.k('ex')));
select tests.as_postgres();
insert into kv values ('mk_x1', pg_temp.started('x1', 'm1'));
select public.marking_holds_expire(now() + interval '2 hours');
select is(pg_temp.holder('x1'), 'm1 next', 'hold_expires_and_piece_goes_to_another_marker: at the end of the 2 hours m1 still holds it');
select tests.as_user(pg_temp.uid('m2'));
insert into res values ('x_m2', public.marking_next(pg_temp.k('ex'), null, now() + interval '2 hours 1 second'));
select tests.as_postgres();
select is(pg_temp.r('x_m2'), jsonb_build_object('ok', true, 'unit_id', pg_temp.u('x1'), 'resumed', false),
  'a second later m2 presses Next script and is given the piece');
select is((select a.end_reason || ' ' || (a.ended_at = now()) from public.marking_assignments a where a.unit_id = pg_temp.u('x1') and a.marker_id = pg_temp.uid('m1')),
  'expired true', 'm1''s hold ended: expired');
select is((select a.how || ' ' || (a.hold_until = now() + interval '4 hours 1 second') from public.marking_assignments a
           where a.unit_id = pg_temp.u('x1') and a.ended_at is null and a.marker_id = pg_temp.uid('m2')), 'next true', 'm2 holds it for 2 hours from then');
select is(pg_temp.ms('x1', 'm1'), 'set_aside expired', 'm1''s marking is set aside, as their hold ran out');
select is((select count(*)::int from public.question_marks where marking_id = pg_temp.k('mk_x1')), 1, 'with their marks kept');
-- The minute job ends holds that ran out.
update public.marking_assignments set hold_until = now() - interval '1 minute' where unit_id = pg_temp.u('x1') and ended_at is null;
select lives_ok($$ select public.marking_tick() $$, 'the minute job runs');
select is(pg_temp.holder('x1') || ' ' || pg_temp.us('x1'), '- open', 'it ended m2''s hold, which had run out, and the piece is free');
select is((select a.end_reason from public.marking_assignments a where a.unit_id = pg_temp.u('x1') and a.marker_id = pg_temp.uid('m2')), 'expired', 'expired');
select is(pg_temp.st('x1'), 'marking', 'the script is still being marked: m1''s marking is on it');
-- A hold on a piece that is on hold does not run out.
select tests.as_user(pg_temp.uid('m3'));
insert into res values ('x_m3', public.marking_next(pg_temp.k('ex')));
select tests.as_postgres();
update public.marking_units set on_hold = true, hold_reason = 'picture_changed' where id = pg_temp.u('x1');
select public.marking_holds_expire(now() + interval '1 day');
select is(pg_temp.holder('x1'), 'm3 next', 'a hold on a piece that is on hold does not run out: m3 keeps it until it is released');

-- ---------------------------------------------------------------------------------------------
-- expired_piece_resumes_for_same_marker (Review Focus 1)
-- ---------------------------------------------------------------------------------------------
insert into kv values ('ey', tests.marking_exam(pg_temp.s1()));
select tests.structure(pg_temp.k('ey'));
select pg_temp.script('y1', 'ey');
select pg_temp.open('ey');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('y_m1', public.marking_next(pg_temp.k('ey')));
select tests.as_postgres();
insert into kv values ('mk_y1', pg_temp.started('y1', 'm1'));
update public.markings set rev = 3, last_saved_at = now() where id = pg_temp.k('mk_y1');
select pg_temp.script('y2', 'ey');
select pg_temp.open('ey');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('y_resume', public.marking_next(pg_temp.k('ey'), null, now() + interval '2 hours 1 second'));
select tests.as_postgres();
select is(pg_temp.r('y_resume'), jsonb_build_object('ok', true, 'unit_id', pg_temp.u('y1'), 'resumed', true),
  'expired_piece_resumes_for_same_marker: after their hold ran out m1 presses Next script and carries on with the same piece');
select is((select string_agg(m.id::text, ',') from public.markings m where m.unit_id = pg_temp.u('y1')), pg_temp.k('mk_y1')::text,
  'with the same marking: no second row');
select is((select m.status || ' ' || m.rev from public.markings m where m.id = pg_temp.k('mk_y1')), 'in_progress 3', 'still in progress, as saved');
select is((select string_agg(q.mark::text, ',') from public.question_marks q where q.marking_id = pg_temp.k('mk_y1')), '2.0',
  'and their marks are still there');
select is((select count(*) filter (where a.end_reason = 'expired') || ' '
                  || count(*) filter (where a.ended_at is null and a.hold_until = now() + interval '4 hours 1 second')
           from public.marking_assignments a where a.unit_id = pg_temp.u('y1') and a.marker_id = pg_temp.uid('m1')),
  '1 1', 'the old hold expired and a new one runs for 2 hours from then');
select is(pg_temp.us('y2'), 'open', 'the other piece was not handed out');
-- Before resuming, Next script checks again that the piece may be handed out.
select public.marking_holds_expire(now() + interval '5 hours');
insert into public.processing_jobs (upload_id, kind, state) values (pg_temp.upload('y1'), 'remask', 'queued');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('y_busy', public.marking_next(pg_temp.k('ey'), null, now() + interval '5 hours'));
select tests.as_postgres();
select is(pg_temp.r('y_busy') ->> 'unit_id', pg_temp.u('y2')::text,
  'when its hold ran out again and its pictures are being updated, m1 is given the other piece instead');
select is(pg_temp.ms('y1', 'm1'), 'in_progress', 'their marking on the first is kept');

-- ---------------------------------------------------------------------------------------------
-- give_back_frees_the_piece
-- ---------------------------------------------------------------------------------------------
insert into kv values ('eg', tests.marking_exam(pg_temp.s1()));
select tests.structure(pg_temp.k('eg'));
select pg_temp.script('g1', 'eg');
select pg_temp.open('eg');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('g_m1', public.marking_next(pg_temp.k('eg')));
select tests.as_postgres();
insert into kv values ('mk_g1', pg_temp.started('g1', 'm1'));
select tests.as_user(pg_temp.uid('m2'));
select is(pg_temp.code(public.marking_give_back(pg_temp.u('g1'))), 'forbidden', 'give_back_frees_the_piece: only its holder can give a piece back');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.code(public.marking_give_back(pg_temp.u('g1'), 'ab')), 'invalid_input', 'a reason, when given, is 3 to 300 characters');
select is(public.marking_give_back(pg_temp.u('g1'), 'Handwriting I cannot read'), '{"ok": true}'::jsonb, 'm1 gives it back');
select tests.as_postgres();
select is(pg_temp.holder('g1') || ' ' || pg_temp.us('g1'), '- open', 'the piece is free');
select is((select a.end_reason from public.marking_assignments a where a.unit_id = pg_temp.u('g1') and a.marker_id = pg_temp.uid('m1')), 'given_back',
  'm1''s hold ended: given back');
select is(pg_temp.ms('g1', 'm1'), 'set_aside given_back', 'm1''s marking is set aside, so Next script does not hand it straight back');
select is((select count(*)::int from public.audit_log a where a.action = 'marking_given_back' and a.target_id = pg_temp.u('g1')
             and a.actor_id = pg_temp.uid('m1') and a.reason = 'Handwriting I cannot read'), 1, 'an audit row with the reason');
select tests.as_user(pg_temp.uid('m2'));
insert into res values ('g_m2', public.marking_next(pg_temp.k('eg')));
select tests.as_postgres();
select is(pg_temp.r('g_m2') ->> 'unit_id', pg_temp.u('g1')::text, 'm2 presses Next script and is given it');
select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.code(public.marking_give_back(pg_temp.u('g1'))), 'forbidden', 'm1 can no longer give it back');
select tests.as_postgres();
-- A piece whose hold ran out can be given back too.
insert into kv values ('mk_g1b', pg_temp.started('g1', 'm2'));
select public.marking_holds_expire(now() + interval '3 hours');
select tests.as_user(pg_temp.uid('m2'));
select is(public.marking_give_back(pg_temp.u('g1')), '{"ok": true}'::jsonb, 'm2, whose hold ran out, gives it back with no reason');
select tests.as_postgres();
select is(pg_temp.ms('g1', 'm2'), 'set_aside given_back', 'and m2''s marking is set aside');
-- Not while marking is closed.
select tests.as_user(pg_temp.uid('m3'));
insert into res values ('g_m3', public.marking_next(pg_temp.k('eg')));
select tests.as_postgres();
update public.exam_marking set closed_at = now() where exam_id = pg_temp.k('eg');
select tests.as_user(pg_temp.uid('m3'));
select is(pg_temp.code(public.marking_give_back(pg_temp.u('g1'))), 'marking_closed', 'nothing is given back once marking has closed');
select tests.as_postgres();
update public.exam_marking set closed_at = null where exam_id = pg_temp.k('eg');

-- ---------------------------------------------------------------------------------------------
-- assign_has_no_time_limit
-- ---------------------------------------------------------------------------------------------
insert into kv values ('ea', tests.marking_exam(pg_temp.s1()));
select tests.structure(pg_temp.k('ea'));
select pg_temp.script('a1', 'ea');
select pg_temp.script('a2', 'ea');
select pg_temp.script('a3', 'ea');
select pg_temp.script('a4', 'ea');
select pg_temp.script('a5', 'ea');
select pg_temp.script('a6', 'ea');
select pg_temp.open('ea');
select pg_temp.submitted('a3', 'm2');
update public.marking_units set on_hold = true, hold_reason = 'picture_changed' where id = pg_temp.u('a4');
-- m2 once held a2; their hold ran out and the piece went to another marker, so their marking was set aside.
with m as (insert into public.markings (unit_id, marker_id, status, set_aside_at, set_aside_reason)
           values (pg_temp.u('a2'), pg_temp.uid('m2'), 'set_aside', now(), 'expired') returning id)
insert into kv select 'mk_a2', id from m;
insert into kv values ('ghost', gen_random_uuid());
select tests.as_user(pg_temp.uid('admin'));
select is(public.marking_assign(array[pg_temp.u('a1')], pg_temp.uid('m1'), 'Needs an experienced marker'),
  '{"ok": true, "assigned": 1, "skipped": []}'::jsonb, 'assign_has_no_time_limit: an admin assigns a piece to m1');
select tests.as_postgres();
select is((select a.how || ' ' || coalesce(a.hold_until::text, 'no limit') || ' ' || (a.assigned_by = pg_temp.uid('admin'))
           from public.marking_assignments a where a.unit_id = pg_temp.u('a1') and a.ended_at is null), 'assigned no limit true',
  'assigned, by the admin, with no time limit');
select is(array[pg_temp.holder('a1'), pg_temp.us('a1'), pg_temp.st('a1')], array['m1 assigned', 'taken', 'marking'],
  'm1 holds it, the piece is taken and the script is being marked');
select is((select count(*)::int from public.audit_log a where a.action = 'marking_assigned' and a.target_id = pg_temp.u('a1')
             and a.actor_id = pg_temp.uid('admin') and a.reason = 'Needs an experienced marker'), 1, 'an audit row with the reason');
select public.marking_holds_expire(now() + interval '30 days');
select is(pg_temp.holder('a1'), 'm1 assigned', 'a month later it has not run out');
select tests.as_user(pg_temp.uid('m1'));
select is(public.marking_next(pg_temp.k('ea')), jsonb_build_object('ok', true, 'unit_id', pg_temp.u('a1'), 'resumed', true),
  'Next script gives m1 the piece assigned to them');
select tests.as_postgres();
select is((select a.hold_until from public.marking_assignments a where a.unit_id = pg_temp.u('a1') and a.ended_at is null), null::timestamptz,
  'and its hold stays without a limit');
select tests.as_user(pg_temp.uid('admin'));
select is(public.marking_assign(array[pg_temp.u('a2')], pg_temp.uid('m2'), 'Back to the marker who started it') ->> 'assigned', '1',
  'm2 is assigned a piece their earlier marking of was set aside');
select tests.as_postgres();
select is((select string_agg(m.id::text || ' ' || m.status || ' ' || coalesce(m.set_aside_reason, '-'), ',') from public.markings m where m.unit_id = pg_temp.u('a2')),
  pg_temp.k('mk_a2')::text || ' in_progress -', 'that marking is in progress again: the same row');
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('ea_skip', public.marking_assign(array[pg_temp.u('a1'), pg_temp.u('a3'), pg_temp.u('a4'), pg_temp.k('ghost')], pg_temp.uid('m3'), 'Spread the work'));
select tests.as_postgres();
select is(pg_temp.r('ea_skip') ->> 'assigned', '0', 'a piece taken, submitted or on hold is not assigned');
select is((select jsonb_object_agg(s ->> 'unit_id', s ->> 'code') from jsonb_array_elements(pg_temp.r('ea_skip') -> 'skipped') s),
  jsonb_build_object(pg_temp.u('a1'), 'taken', pg_temp.u('a3'), 'submitted', pg_temp.u('a4'), 'on_hold', pg_temp.k('ghost'), 'not_found'),
  'each is skipped with its reason, as is a piece that does not exist');
select tests.as_user(pg_temp.uid('admin'));
select is(array[pg_temp.code(public.marking_assign('{}', pg_temp.uid('m1'), 'Spread the work')),
                pg_temp.code(public.marking_assign(array(select gen_random_uuid() from generate_series(1, 201)), pg_temp.uid('m1'), 'Spread the work')),
                pg_temp.code(public.marking_assign(array[pg_temp.u('a5')], null, 'Spread the work')),
                pg_temp.code(public.marking_assign(array[pg_temp.u('a5')], pg_temp.uid('m1'), 'ab'))],
  array['invalid_input', 'invalid_input', 'invalid_input', 'reason_required'], 'it needs 1 to 200 pieces, a marker and a reason');
select tests.as_postgres();
select is(pg_temp.holder('a5') || ' ' || pg_temp.audits('marking_assigned', pg_temp.u('a5')), '- 0', 'and nothing else was assigned');

-- ---------------------------------------------------------------------------------------------
-- assign_refuses_conflict_and_unapproved_marker
-- ---------------------------------------------------------------------------------------------
insert into public.marker_conflicts (marker_id, student_id, recorded_at) values (pg_temp.uid('m3'), pg_temp.student('a5'), now());
select tests.as_user(pg_temp.uid('admin'));
select is(public.marking_assign(array[pg_temp.u('a5')], pg_temp.uid('m3'), 'Spread the work'),
  jsonb_build_object('ok', true, 'assigned', 0, 'skipped', jsonb_build_array(jsonb_build_object('unit_id', pg_temp.u('a5'), 'code', 'conflict_of_interest'))),
  'assign_refuses_conflict_and_unapproved_marker: not to a marker with a declared conflict with the candidate');
select tests.as_postgres();
insert into public.tutor_students (tutor_id, student_id) values (pg_temp.uid('m3'), pg_temp.student('a6'));
select tests.as_user(pg_temp.uid('admin'));
select is(public.marking_assign(array[pg_temp.u('a6')], pg_temp.uid('m3'), 'Spread the work') -> 'skipped' -> 0 ->> 'code', 'conflict_of_interest',
  'nor to the candidate''s tutor');
select is(array[public.marking_assign(array[pg_temp.u('a6')], pg_temp.uid('corr'), 'Spread the work') -> 'skipped' -> 0 ->> 'code',
                public.marking_assign(array[pg_temp.u('a6')], pg_temp.uid('susp'), 'Spread the work') -> 'skipped' -> 0 ->> 'code',
                public.marking_assign(array[pg_temp.u('a6')], pg_temp.uid('teacher'), 'Spread the work') -> 'skipped' -> 0 ->> 'code'],
  array['not_approved', 'not_approved', 'not_approved'], 'nor to a marker not approved for the subject, a suspended one, or a teacher not approved');
select tests.as_postgres();
select is(pg_temp.holder('a5') || pg_temp.holder('a6'), '--', 'neither piece was assigned');

-- ---------------------------------------------------------------------------------------------
-- take_back_of_submitted_piece_sets_marking_aside_and_script_back_to_marking
-- ---------------------------------------------------------------------------------------------
insert into kv values ('et', tests.marking_exam(pg_temp.s1()));
select tests.structure(pg_temp.k('et'));
select pg_temp.script('t1', 'et');
select pg_temp.script('t2', 'et');
select pg_temp.open('et');
select pg_temp.submitted('t1', 'm1');
select tests.as_user(pg_temp.uid('m2'));
insert into res values ('t_m2', public.marking_next(pg_temp.k('et')));
select tests.as_postgres();
insert into kv values ('mk_t2', pg_temp.started('t2', 'm2'));
select is(array[pg_temp.st('t1'), pg_temp.us('t1'), pg_temp.ms('t1', 'm1'), pg_temp.holder('t2')], array['marked', 'submitted', 'submitted', 'm2 next'],
  'take_back_of_submitted_piece_sets_marking_aside_and_script_back_to_marking: m1 marked t1, and m2 holds t2');
select tests.as_user(pg_temp.uid('admin'));
select is(public.marking_take_back(array[pg_temp.u('t1'), pg_temp.u('t2')], 'Marked against the wrong scheme'), '{"ok": true, "taken_back": 2}'::jsonb,
  'an admin takes back the submitted piece and the one m2 holds');
select tests.as_postgres();
select is(pg_temp.ms('t1', 'm1'), 'set_aside taken_back', 'the submitted marking is set aside');
select is(array[pg_temp.us('t1'), pg_temp.st('t1')], array['open', 'marking'], 'the piece is open again and the script is being marked again');
select is((select count(*)::int from public.question_marks q join public.markings m on m.id = q.marking_id where m.unit_id = pg_temp.u('t1')), 1,
  'nothing is deleted: the marks stay with the marking');
select is(pg_temp.holder('t2') || ' ' || pg_temp.us('t2') || ' '
          || (select a.end_reason from public.marking_assignments a where a.unit_id = pg_temp.u('t2') and a.marker_id = pg_temp.uid('m2')),
  '- open taken_back', 'm2''s hold ends: taken back');
select is(pg_temp.ms('t2', 'm2'), 'set_aside taken_back', 'and m2''s marking is set aside, so Next script does not hand it straight back');
select is((select count(*)::int from public.audit_log a where a.action = 'marking_taken_back' and a.actor_id = pg_temp.uid('admin')
             and a.reason = 'Marked against the wrong scheme' and a.target_id in (pg_temp.u('t1'), pg_temp.u('t2'))), 2,
  'an audit row per piece, with the reason');
select tests.as_user(pg_temp.uid('m2'));
insert into res values ('t_next', public.marking_next(pg_temp.k('et')));
select tests.as_postgres();
select is(pg_temp.r('t_next') ->> 'resumed', 'false', 'm2''s next piece is a new hand-out, not a resumed one');
insert into kv select 'free_t', u.id from public.marking_units u where u.id in (pg_temp.u('t1'), pg_temp.u('t2')) and u.state = 'open';
select tests.as_user(pg_temp.uid('admin'));
select is(public.marking_take_back(array[pg_temp.k('free_t')], 'Marked against the wrong scheme') ->> 'taken_back', '0',
  'a free piece has nothing to take back');
select is(array[pg_temp.code(public.marking_take_back('{}', 'Marked against the wrong scheme')),
                pg_temp.code(public.marking_take_back(array[pg_temp.u('t1')], null))],
  array['invalid_input', 'reason_required'], 'it needs 1 to 200 pieces and a reason');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- reassign_is_one_transaction
-- ---------------------------------------------------------------------------------------------
insert into kv values ('ev', tests.marking_exam(pg_temp.s1()));
select tests.structure(pg_temp.k('ev'));
select pg_temp.script('v1', 'ev');
select pg_temp.script('v2', 'ev');
select pg_temp.script('v3', 'ev');
select pg_temp.open('ev');
select pg_temp.submitted('v2', 'm1');
select tests.as_user(pg_temp.uid('admin'));
select is(public.marking_assign(array[pg_temp.u('v1'), pg_temp.u('v3')], pg_temp.uid('m1'), 'Started by m1') ->> 'assigned', '2',
  'reassign_is_one_transaction: m1 holds two pieces and has marked a third');
select tests.as_postgres();
insert into kv values ('mk_v1', pg_temp.started('v1', 'm1'));
insert into public.marker_conflicts (marker_id, student_id, recorded_at) values (pg_temp.uid('m2'), pg_temp.student('v3'), now());
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('rv', public.marking_reassign(array[pg_temp.u('v1'), pg_temp.u('v2'), pg_temp.u('v3')], pg_temp.uid('m2'), 'Marker one is away'));
select tests.as_postgres();
select is(pg_temp.r('rv') - 'skipped', '{"ok": true, "taken_back": 2, "assigned": 2}'::jsonb, 'an admin moves the three to m2: two move');
select is(pg_temp.r('rv') -> 'skipped', jsonb_build_array(jsonb_build_object('unit_id', pg_temp.u('v3'), 'code', 'conflict_of_interest')),
  'the third is skipped: m2 may not mark that candidate');
select is(array[pg_temp.holder('v1'), pg_temp.holder('v2'), pg_temp.holder('v3')], array['m2 assigned', 'm2 assigned', 'm1 assigned'],
  'm2 holds the two; the third stays with m1 and was not taken back');
select is(array[pg_temp.ms('v1', 'm1'), pg_temp.ms('v2', 'm1'), pg_temp.ms('v3', 'm1')], array['set_aside taken_back', 'set_aside taken_back', '-'],
  'm1''s markings on the two are set aside');
select is(pg_temp.st('v2'), 'marking', 'the marked script is being marked again');
select is(array[pg_temp.audits('marking_taken_back', pg_temp.u('v3')), pg_temp.audits('marking_assigned', pg_temp.u('v3'))], array[0, 1],
  'the skipped piece has no take-back audit row (only its first assignment)');
select is((select count(*)::int from public.audit_log a where a.action in ('marking_taken_back', 'marking_assigned')
             and a.target_id in (pg_temp.u('v1'), pg_temp.u('v2')) and a.reason = 'Marker one is away'), 4,
  'each piece moved has a take-back and an assignment audit row');
select tests.as_user(pg_temp.uid('admin'));
select is(public.marking_reassign(array[pg_temp.u('v1')], pg_temp.uid('corr'), 'Try another marker'),
  jsonb_build_object('ok', true, 'taken_back', 0, 'assigned', 0, 'skipped', jsonb_build_array(jsonb_build_object('unit_id', pg_temp.u('v1'), 'code', 'not_approved'))),
  'reassigning to a marker not approved changes nothing');
select tests.as_postgres();
select is(pg_temp.holder('v1') || ' ' || pg_temp.audits('marking_taken_back', pg_temp.u('v1')), 'm2 assigned 1', 'v1 stays with m2: the take-back was undone');

-- ---------------------------------------------------------------------------------------------
-- assign_some_assigns_n
-- ---------------------------------------------------------------------------------------------
insert into kv values ('es', tests.marking_exam(pg_temp.s1()));
select pg_temp.script('so1', 'es');
select pg_temp.script('so2', 'es');
select pg_temp.script('so3', 'es');
select pg_temp.script('so4', 'es');
select pg_temp.script('so5', 'es');
select pg_temp.open('es');
insert into public.marking_unit_exclusions (unit_id, marker_id, reason) values (pg_temp.u('so4'), pg_temp.uid('m3'), 'name_seen');
insert into public.marker_conflicts (marker_id, student_id, recorded_at) values (pg_temp.uid('m3'), pg_temp.student('so5'), now());
select tests.as_user(pg_temp.uid('admin'));
select is(public.marking_assign_some(pg_temp.k('es'), null, pg_temp.uid('m3'), 2, 'Give m3 a start'), '{"ok": true, "assigned": 2}'::jsonb,
  'assign_some_assigns_n: an admin gives m3 the next 2 pieces');
select tests.as_postgres();
select is((select count(*)::int from public.marking_assignments a join public.marking_units u on u.id = a.unit_id
           where u.exam_id = pg_temp.k('es') and a.marker_id = pg_temp.uid('m3') and a.ended_at is null and a.how = 'assigned' and a.hold_until is null), 2,
  'm3 holds 2, assigned with no time limit');
select is((select count(*)::int from public.audit_log a where a.action = 'marking_assigned' and a.reason = 'Give m3 a start'), 2, 'one audit row each');
select tests.as_user(pg_temp.uid('admin'));
select is(public.marking_assign_some(pg_temp.k('es'), null, pg_temp.uid('m3'), 10, 'The rest of them'), '{"ok": true, "assigned": 1}'::jsonb,
  'asked for 10, m3 gets the 1 left they may mark');
select tests.as_postgres();
select is(array[pg_temp.holder('so4'), pg_temp.holder('so5')], array['-', '-'],
  'not the piece m3 saw a name on, nor the candidate m3 may not mark');
select tests.as_user(pg_temp.uid('admin'));
select is(array[pg_temp.code(public.marking_assign_some(pg_temp.k('es'), null, pg_temp.uid('m3'), 0, 'The rest of them')),
                pg_temp.code(public.marking_assign_some(pg_temp.k('es'), null, pg_temp.uid('m3'), 201, 'The rest of them')),
                pg_temp.code(public.marking_assign_some(pg_temp.k('es'), null, pg_temp.uid('m3'), 1, null)),
                pg_temp.code(public.marking_assign_some(gen_random_uuid(), null, pg_temp.uid('m3'), 1, 'The rest of them')),
                pg_temp.code(public.marking_assign_some(pg_temp.k('es'), pg_temp.k('g0'), pg_temp.uid('m3'), 1, 'The rest of them')),
                pg_temp.code(public.marking_assign_some(pg_temp.k('es'), null, pg_temp.uid('corr'), 1, 'The rest of them')),
                pg_temp.code(public.marking_assign_some(pg_temp.k('e0'), null, pg_temp.uid('m3'), 1, 'The rest of them')),
                pg_temp.code(public.marking_assign_some(pg_temp.k('ez'), null, pg_temp.uid('m3'), 1, 'The rest of them'))],
  array['invalid_input', 'invalid_input', 'reason_required', 'not_found', 'invalid_input', 'not_approved', 'marking_not_open', 'marking_closed'],
  'it needs 1 to 200, a reason, an exam that exists (and a group of it), an approved marker and marking open');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- my_work_and_units_list_have_no_name
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('mw', public.marking_my_work());
select tests.as_postgres();
select is((select count(*)::int from (values ('Wilhelmina'), ('Quarterfield')) v(t) where position(v.t in pg_temp.r('mw')::text) > 0), 0,
  'my_work_and_units_list_have_no_name: m1''s work has no candidate''s first or last name');
select is((select count(*)::int from public.profiles p where p.role = 'student'
             and (position(p.email::text in pg_temp.r('mw')::text) > 0 or position(p.id::text in pg_temp.r('mw')::text) > 0)), 0,
  'nor a candidate''s email or student id');
select is((select count(*)::int from public.bookings b where position(b.id::text in pg_temp.r('mw')::text) > 0), 0, 'nor a booking id');
select is((select p - 'last_saved_at' from jsonb_array_elements(pg_temp.r('mw') -> 'pieces') p where p ->> 'unit_id' = pg_temp.u('a1')::text),
  jsonb_build_object('unit_id', pg_temp.u('a1'), 'exam_id', pg_temp.k('ea'), 'script_number', (select number from public.scripts where id = pg_temp.k('a1')),
    'index_number', (select d.index_number from public.student_details d where d.profile_id = pg_temp.student('a1')), 'group_label', null,
    'state', 'taken', 'how', 'assigned', 'hold_until', null, 'on_hold', false, 'hold_reason', null, 'pages_changed', false),
  'a piece m1 holds shows its script number, index number, state and hold');
select is((select (e ->> 'left') || ' ' || (e -> 'mine' ->> 'taken') || ' ' || (e -> 'mine' ->> 'submitted') || ' ' || (e ->> 'closed')
                  || ' ' || (e ->> 'overdue') || ' ' || (e ->> 'mode') || ' ' || (e -> 'groups')::text
           from jsonb_array_elements(pg_temp.r('mw') -> 'exams') e where e ->> 'exam_id' = pg_temp.k('ea')::text),
  '2 1 0 false false whole []', 'its exam: 2 pieces left that m1 may be given, 1 held, none submitted');
select is(pg_temp.r('mw') ->> 'approved', 'true', 'm1 is approved to mark');
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('ul', public.marking_units_list(pg_temp.k('ea')));
select tests.as_postgres();
select is((select count(*)::int from public.profiles p where p.role = 'student'
             and (position(p.email::text in pg_temp.r('ul')::text) > 0 or position(p.id::text in pg_temp.r('ul')::text) > 0))
          + (select count(*)::int from (values ('Wilhelmina'), ('Quarterfield')) v(t) where position(v.t in pg_temp.r('ul')::text) > 0), 0,
  'the admin''s list of pieces has no candidate''s name, email or student id');
select is(jsonb_array_length(pg_temp.r('ul') -> 'units'), 6, 'it lists the exam''s 6 pieces');
select is((select (x ->> 'marker_name') || ' ' || (x ->> 'how') || ' ' || (x ->> 'state') || ' ' || (x ->> 'source') || ' ' || (x ->> 'index_number' is not null)
           from jsonb_array_elements(pg_temp.r('ul') -> 'units') x where x ->> 'unit_id' = pg_temp.u('a1')::text),
  'Mara One assigned taken home true', 'each with its marker''s name and how they hold it');
select is((select (x ->> 'total') || ' ' || (x ->> 'marker_id' = pg_temp.uid('m2')::text) || ' ' || (x ->> 'submitted_at' is not null) || ' ' || coalesce(x ->> 'waiting', 'none')
           from jsonb_array_elements(pg_temp.r('ul') -> 'units') x where x ->> 'unit_id' = pg_temp.u('a3')::text),
  '8.0 true true none', 'a submitted piece: its marker, when, and its total');
select tests.as_user(pg_temp.uid('admin'));
select is(array[jsonb_array_length(public.marking_units_list(pg_temp.k('ea'), 'open') -> 'units'),
                jsonb_array_length(public.marking_units_list(pg_temp.k('ea'), 'on_hold') -> 'units'),
                jsonb_array_length(public.marking_units_list(pg_temp.k('ea'), 'taken') -> 'units'),
                jsonb_array_length(public.marking_units_list(pg_temp.k('ea'), 'submitted') -> 'units'),
                jsonb_array_length(public.marking_units_list(pg_temp.k('ea'), null, pg_temp.uid('m2')) -> 'units')],
  array[3, 1, 2, 1, 2], 'filtered by state, on hold, or by marker');
select is((select x ->> 'waiting' from jsonb_array_elements(public.marking_units_list(pg_temp.k('eh')) -> 'units') x where x ->> 'unit_id' = pg_temp.u('ht')::text),
  'taken_back', 'waiting says what holds a piece back');
select is(array[pg_temp.code(public.marking_units_list(pg_temp.k('ea'), 'nope')), pg_temp.code(public.marking_units_list(null)),
                pg_temp.code(public.marking_units_list(gen_random_uuid()))],
  array['invalid_input', 'invalid_input', 'not_found'], 'it needs an exam that exists and a state it knows');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('corr'));
select is(public.marking_my_work(), '{"ok": true, "approved": false, "lead_subjects": [], "exams": [], "pieces": []}'::jsonb,
  'a corrector not approved to mark has no work');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- progress_counts_and_overdue
-- ---------------------------------------------------------------------------------------------
insert into kv values ('ep', tests.marking_exam(pg_temp.s1()));
select tests.structure(pg_temp.k('ep'));
select pg_temp.script('p1', 'ep');
select pg_temp.script('p2', 'ep');
select pg_temp.script('p3', 'ep');
select pg_temp.script('p4', 'ep');
select pg_temp.script('p5', 'ep');
update public.scripts set late = true where id = pg_temp.k('p5');
select pg_temp.open('ep');
select pg_temp.submitted('p1', 'm1');
update public.marking_units set on_hold = true, hold_reason = 'picture_changed' where id = pg_temp.u('p4');
insert into public.marking_alerts (exam_id, kind, script_id, unit_id) values (pg_temp.k('ep'), 'picture_changed', pg_temp.k('p4'), pg_temp.u('p4'));
update public.exam_marking set deadline = now() - interval '1 hour' where exam_id = pg_temp.k('ep');
select tests.as_user(pg_temp.uid('admin'));
select is(public.marking_assign(array[pg_temp.u('p2')], pg_temp.uid('m2'), 'Quick one') ->> 'assigned', '1',
  'progress_counts_and_overdue: m1 marked p1, m2 is assigned p2, p3 is free, p4 is on hold and p5 came in late');
select tests.as_postgres();
insert into kv values ('mk_p2', pg_temp.started('p2', 'm2'));
update public.markings set last_saved_at = now() - interval '10 minutes' where id = pg_temp.k('mk_p2');
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('pg', public.marking_progress(pg_temp.k('ep')));
select tests.as_postgres();
select is(jsonb_array_length(pg_temp.r('pg') -> 'exams'), 1, 'one exam, as asked');
select is(pg_temp.r('pg') -> 'exams' -> 0 -> 'scripts', '{"waiting": 1, "ready_to_mark": 2, "marking": 1, "marked": 1}'::jsonb,
  'scripts: 1 waiting (late, not decided), 2 ready, 1 being marked, 1 marked');
select is(pg_temp.r('pg') -> 'exams' -> 0 -> 'units', '{"open": 1, "taken": 1, "submitted": 1, "on_hold": 1}'::jsonb,
  'pieces: 1 open, 1 taken, 1 submitted, 1 on hold');
select is(pg_temp.r('pg') -> 'exams' -> 0 -> 'markers',
  jsonb_build_array(
    jsonb_build_object('marker_id', pg_temp.uid('m1'), 'name', 'Mara One', 'taken', 0, 'submitted', 1, 'last_saved_at', now() - interval '1 hour'),
    jsonb_build_object('marker_id', pg_temp.uid('m2'), 'name', 'Milo Two', 'taken', 1, 'submitted', 0, 'last_saved_at', now() - interval '10 minutes')),
  'per marker: what they hold, what they submitted, and when they last saved');
select is(pg_temp.r('pg') -> 'exams' -> 0 ->> 'alerts_open', '1', 'one open alert');
select is(pg_temp.r('pg') -> 'exams' -> 0 ->> 'overdue', 'true', 'the deadline has passed with pieces not submitted: overdue');
select tests.as_user(pg_temp.uid('admin'));
select is(public.marking_progress(pg_temp.k('ep'), now() - interval '2 hours') -> 'exams' -> 0 ->> 'overdue', 'false', 'before the deadline it is not');
select tests.as_postgres();
update public.exam_marking set closed_at = now() where exam_id = pg_temp.k('ep');
select tests.as_user(pg_temp.uid('admin'));
select is(public.marking_progress(pg_temp.k('ep')) -> 'exams' -> 0 ->> 'overdue', 'false', 'nor once marking has closed');
select tests.as_postgres();
update public.exam_marking set closed_at = null where exam_id = pg_temp.k('ep');
select tests.as_user(pg_temp.uid('admin'));
select is((select count(*)::int from jsonb_array_elements(public.marking_progress() -> 'exams') e
           where e ->> 'exam_id' in (pg_temp.k('ep')::text, pg_temp.k('e1')::text, pg_temp.k('e0')::text)), 2,
  'asked for no exam, an admin sees every exam whose marking has been set up, not one never opened');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m2'));
select is((select e ->> 'overdue' from jsonb_array_elements(public.marking_my_work() -> 'exams') e where e ->> 'exam_id' = pg_temp.k('ep')::text), 'true',
  'a marker''s list shows the exam overdue too');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- lead_sees_own_subject_only
-- ---------------------------------------------------------------------------------------------
insert into kv values ('e2x', tests.marking_exam(pg_temp.s2()));
select pg_temp.script('x2s', 'e2x');
select pg_temp.open('e2x');
select tests.as_user(pg_temp.uid('lead'));
insert into res values ('lp', public.marking_progress());
select is((select count(*)::int from jsonb_array_elements(pg_temp.r('lp') -> 'exams') e where e ->> 'exam_id' = pg_temp.k('e2x')::text), 0,
  'lead_sees_own_subject_only: the lead of one subject does not see another subject''s exam');
select is((select count(*)::int from jsonb_array_elements(pg_temp.r('lp') -> 'exams') e where e ->> 'exam_id' = pg_temp.k('ep')::text), 1,
  'but sees their own subject''s');
select is(array[pg_temp.code(public.marking_progress(pg_temp.k('e2x'))), pg_temp.code(public.marking_units_list(pg_temp.k('e2x'))),
                pg_temp.code(public.marking_progress(pg_temp.k('ep'))), pg_temp.code(public.marking_units_list(pg_temp.k('ep')))],
  array['forbidden', 'forbidden', 'ok', 'ok'], 'they may list the pieces of their own subject''s exams only');
select is(public.marking_my_work() -> 'lead_subjects', jsonb_build_array(pg_temp.s1()), 'their work lists the subject they lead');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('lead2'));
select is(array(select e ->> 'exam_id' from jsonb_array_elements(public.marking_progress() -> 'exams') e), array[pg_temp.k('e2x')::text],
  'the other subject''s lead sees only that subject''s exam');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m1'));
select is(array[pg_temp.code(public.marking_progress()), pg_temp.code(public.marking_progress(pg_temp.k('ep'))),
                pg_temp.code(public.marking_units_list(pg_temp.k('ep')))],
  array['forbidden', 'forbidden', 'forbidden'], 'a marker who leads no subject sees neither');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- corrector_cannot_assign_or_take_back
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('m1'));
select is(array[pg_temp.code(public.marking_assign(array[pg_temp.u('a5')], pg_temp.uid('m1'), 'Give it to me')),
                pg_temp.code(public.marking_assign_some(pg_temp.k('es'), null, pg_temp.uid('m1'), 1, 'Give it to me')),
                pg_temp.code(public.marking_take_back(array[pg_temp.u('a2')], 'Give it to me')),
                pg_temp.code(public.marking_reassign(array[pg_temp.u('a2')], pg_temp.uid('m1'), 'Give it to me'))],
  array['forbidden', 'forbidden', 'forbidden', 'forbidden'], 'corrector_cannot_assign_or_take_back: an approved corrector is refused');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('lead'));
select is(array[pg_temp.code(public.marking_assign(array[pg_temp.u('a5')], pg_temp.uid('m1'), 'Give it to me')),
                pg_temp.code(public.marking_assign_some(pg_temp.k('es'), null, pg_temp.uid('m1'), 1, 'Give it to me')),
                pg_temp.code(public.marking_take_back(array[pg_temp.u('a2')], 'Give it to me')),
                pg_temp.code(public.marking_reassign(array[pg_temp.u('a2')], pg_temp.uid('m1'), 'Give it to me'))],
  array['forbidden', 'forbidden', 'forbidden', 'forbidden'], 'so is the lead marker');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('teacher'));
select is(array[pg_temp.code(public.marking_assign(array[pg_temp.u('a5')], pg_temp.uid('m1'), 'Give it to me')),
                pg_temp.code(public.marking_assign_some(pg_temp.k('es'), null, pg_temp.uid('m1'), 1, 'Give it to me')),
                pg_temp.code(public.marking_take_back(array[pg_temp.u('a2')], 'Give it to me')),
                pg_temp.code(public.marking_reassign(array[pg_temp.u('a2')], pg_temp.uid('m1'), 'Give it to me')),
                pg_temp.code(public.marking_units_list(pg_temp.k('ea'))), pg_temp.code(public.marking_progress())],
  array['forbidden', 'forbidden', 'forbidden', 'forbidden', 'forbidden', 'forbidden'], 'and a teacher of the subject');
select tests.as_postgres();
select is(pg_temp.holder('a2') || ' ' || pg_temp.holder('a5'), 'm2 assigned -', 'nothing changed');
select is(array(select f from unnest(array[
    'public.marking_unit_blocked(uuid, uuid, timestamptz, boolean)', 'public.marking_unit_pick(uuid, uuid, uuid, timestamptz)',
    'public.marking_unit_take(uuid, uuid, text, uuid, timestamptz)', 'public.marking_unit_take_back(uuid)', 'public.marking_units_lock(uuid[])',
    'public.marking_holds_expire(timestamptz)', 'public.marking_exam_overdue(uuid, timestamptz)', 'public.marking_tick()']) f
  where has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute')
     or has_function_privilege('service_role', f, 'execute')), '{}'::text[],
  'the internal functions cannot be called from the API, nor by the service role');
select is(array(select f from unnest(array[
    'public.marking_next(uuid, uuid, timestamptz)', 'public.marking_give_back(uuid, text)', 'public.marking_assign(uuid[], uuid, text)',
    'public.marking_assign_some(uuid, uuid, uuid, integer, text)', 'public.marking_take_back(uuid[], text)', 'public.marking_reassign(uuid[], uuid, text)',
    'public.marking_my_work(timestamptz)', 'public.marking_units_list(uuid, text, uuid)', 'public.marking_progress(uuid, timestamptz)']) f
  where has_function_privilege('anon', f, 'execute') or not has_function_privilege('authenticated', f, 'execute')), '{}'::text[],
  'the others are for signed-in users only');

select * from finish();
rollback;
