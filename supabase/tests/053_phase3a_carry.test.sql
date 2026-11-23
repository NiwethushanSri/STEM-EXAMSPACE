begin;
create extension if not exists pgtap with schema extensions;
select plan(30);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Subject 'ZZ Carry': markers m1 to m5 are approved for it; m6 is a corrector never approved. Exam e
-- (tests.marking_exam: finished 2 days ago) is marked by question in groups G1 and G2, and its marking is open; its ten
-- verified home scripts x1 to x10 make 20 pieces, kept as '<script>/<group>'. m1 declared a conflict with x1's
-- candidate and saw a name on x1/G1 as well; m2 tutors x2's candidate; m3 saw a name on x3/G1; m4's second marking
-- stands on x4/G1; m6 declared a conflict with x9's candidate; x6/G1 is on hold; x7 was taken back; an admin assigned
-- x5/G1 to m5 (taken); m2 submitted x8/G2.
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values
  ('admin', tests.create_user('admin', 'active')),
  ('m1', tests.create_user('corrector', 'active')),
  ('m2', tests.create_user('corrector', 'active')),
  ('m3', tests.create_user('corrector', 'active')),
  ('m4', tests.create_user('corrector', 'active')),
  ('m5', tests.create_user('corrector', 'active')),
  ('m6', tests.create_user('corrector', 'active'));
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
-- The six markers of the agreement test.
create temp table w (n text primary key);
insert into w values ('m1'), ('m2'), ('m3'), ('m4'), ('m5'), ('m6');
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
-- The candidate of a script.
create function pg_temp.student(p text) returns uuid language sql stable as $$
  select b.student_id from public.scripts s join public.bookings b on b.id = s.booking_id where s.id = pg_temp.k(p) $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text) to public;

insert into public.subjects (name, kind) values ('ZZ Carry', 'school');
insert into public.marker_approvals (marker_id, subject_id, approved_at)
select c.id, (select id from public.subjects where name = 'ZZ Carry'), now() from c where c.name in ('m1', 'm2', 'm3', 'm4', 'm5');
insert into kv values ('e', tests.marking_exam((select id from public.subjects where name = 'ZZ Carry')));
with g as (insert into public.question_groups (exam_id, label, position) values (pg_temp.k('e'), 'G1', 1), (pg_temp.k('e'), 'G2', 2) returning id, label)
insert into kv select label, id from g;
do $$ begin for i in 1..10 loop insert into kv values ('x' || i, tests.verified_script(pg_temp.k('e'))); end loop; end $$;
insert into public.exam_marking (exam_id, mode, opened_at, opened_by) values (pg_temp.k('e'), 'by_question', now(), pg_temp.uid('admin'));
select public.marking_exam_sync(pg_temp.k('e'), null);
insert into kv select x.name || '/' || g.label, u.id
from kv x join public.marking_units u on u.script_id = x.id join public.question_groups g on g.id = u.group_id;
select is((select count(*)::int from public.marking_units u where u.exam_id = pg_temp.k('e') and u.state = 'open'), 20,
  'fixtures: ten scripts marked by question in two groups: 20 open pieces');

insert into public.marker_conflicts (marker_id, student_id, recorded_at)
values (pg_temp.uid('m1'), pg_temp.student('x1'), now()), (pg_temp.uid('m6'), pg_temp.student('x9'), now());
insert into public.tutor_students (tutor_id, student_id) values (pg_temp.uid('m2'), pg_temp.student('x2'));
insert into public.marking_unit_exclusions (unit_id, marker_id, reason)
values (pg_temp.k('x3/G1'), pg_temp.uid('m3'), 'name_seen'), (pg_temp.k('x1/G1'), pg_temp.uid('m1'), 'name_seen');
insert into public.markings (unit_id, kind, marker_id) values (pg_temp.k('x4/G1'), 'second', pg_temp.uid('m4'));
update public.marking_units set on_hold = true, hold_reason = 'picture_changed' where id = pg_temp.k('x6/G1');
update public.scripts set taken_back_at = now(), taken_back_by = pg_temp.uid('admin'), taken_back_reason = 'A name shows' where id = pg_temp.k('x7');
update public.marking_units set state = 'submitted' where id = pg_temp.k('x8/G2');
insert into public.markings (unit_id, marker_id, status, total, last_saved_at, submitted_at)
values (pg_temp.k('x8/G2'), pg_temp.uid('m2'), 'submitted', 5, now(), now());
select public.marking_script_state(pg_temp.k('x8'));
select tests.as_user(pg_temp.uid('admin'));
select is(public.marking_assign(array[pg_temp.k('x5/G1')], pg_temp.uid('m5'), 'Spread the work'),
  '{"ok": true, "assigned": 1, "skipped": []}'::jsonb, 'fixtures: an admin assigns x5/G1 to m5');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- allowed_and_blocked_agree_for_every_marker_and_piece: for each of the 6 markers and each of the 20 pieces, whatever
-- its state and holder, the rule for one piece (marking_unit_blocked) says null exactly when the piece is in the one
-- rule's set (marking_units_allowed), for Next script and for an admin's assignment.
-- ---------------------------------------------------------------------------------------------
select is((with nx(p) as (values (true), (false)),
                allowed as materialized (
                  select w.n, nx.p, a.unit_id from w cross join nx
                  cross join lateral public.marking_units_allowed(pg_temp.k('e'), pg_temp.uid(w.n), 'live', nx.p) a)
           select count(*)::int from public.marking_units u cross join w cross join nx
           where u.exam_id = pg_temp.k('e')
             and (public.marking_unit_blocked(u.id, pg_temp.uid(w.n), now(), nx.p) is null)
                 <> exists (select 1 from allowed a where a.n = w.n and a.p = nx.p and a.unit_id = u.id)), 0,
  'allowed_and_blocked_agree_for_every_marker_and_piece: the two forms agree on all 120 pairs, from Next script and from an admin');
select is((select string_agg(w.n || ':' || (select count(*) from public.marking_units_allowed(pg_temp.k('e'), pg_temp.uid(w.n), 'live', true)), ' ' order by w.n)
           from w),
  'm1:15 m2:15 m3:16 m4:16 m5:17 m6:0',
  'of the 17 pieces not on hold or taken back: m1 loses x1 (conflict), m2 x2 (tutor), m3 x3/G1 (name seen), m4 x4/G1 (their second marking); m6 is not approved');
select is(array[public.marking_unit_blocked(pg_temp.k('x4/G1'), pg_temp.uid('m4'), now(), true),
                public.marking_unit_blocked(pg_temp.k('x4/G1'), pg_temp.uid('m4'), now(), false)],
  array['not_eligible', 'not_eligible'], 'a marker whose second marking stands on a piece is not eligible for its live pass');
update public.markings set status = 'set_aside', set_aside_at = now(), set_aside_reason = 'given_back'
where unit_id = pg_temp.k('x4/G1') and marker_id = pg_temp.uid('m4');
select is(coalesce(public.marking_unit_blocked(pg_temp.k('x4/G1'), pg_temp.uid('m4'), now(), true), 'ok'), 'ok',
  'once that marking is set aside, they are');
select is((select count(*)::int from unnest(array['second', 'seed', 'practice', 'remark']::public.marking_kind[]) k
           cross join lateral public.marking_units_allowed(pg_temp.k('e'), pg_temp.uid('m5'), k, true)), 0,
  'no other kind of pass is allowed yet');
select is((select count(*)::int from public.marking_units_candidates(pg_temp.k('e'), pg_temp.k('G1'), pg_temp.uid('m5'))), 7,
  'marking_units_candidates: m5 may be offered 7 open G1 pieces (not x5, taken; x6, on hold; x7, taken back)');
select is(array(select c.unit_id from public.marking_units_candidates(pg_temp.k('e'), pg_temp.k('G1'), pg_temp.uid('m5')) c order by 1),
          array(select a.unit_id from public.marking_units_allowed(pg_temp.k('e'), pg_temp.uid('m5'), 'live', true) a
                join public.marking_units u on u.id = a.unit_id
                where u.state = 'open' and a.group_id = pg_temp.k('G1') order by 1),
  'they are the rule''s open pieces of the group');

-- ---------------------------------------------------------------------------------------------
-- blocked_reason_codes_are_unchanged: the codes and their order are those of 043.
-- ---------------------------------------------------------------------------------------------
select is(array[public.marking_unit_blocked(pg_temp.k('x9/G1'), pg_temp.uid('m6'), now(), true),
                public.marking_unit_blocked(pg_temp.k('x1/G1'), pg_temp.uid('m1'), now(), true),
                public.marking_unit_blocked(pg_temp.k('x2/G2'), pg_temp.uid('m2'), now(), true),
                public.marking_unit_blocked(pg_temp.k('x3/G1'), pg_temp.uid('m3'), now(), true)],
  array['not_approved', 'conflict_of_interest', 'conflict_of_interest', 'name_seen'],
  'blocked_reason_codes_are_unchanged: not approved (before a conflict), a declared conflict (before a name seen), a tutor link, a name seen');
select is(array[public.marking_unit_blocked(gen_random_uuid(), pg_temp.uid('m5'), now(), true),
                public.marking_unit_blocked(pg_temp.k('x6/G1'), pg_temp.uid('m5'), now(), true),
                public.marking_unit_blocked(pg_temp.k('x7/G1'), pg_temp.uid('m5'), now(), true)],
  array['not_found', 'on_hold', 'not_ready'], 'a piece that does not exist, one on hold and one of a script taken back');
update public.exam_marking set closed_at = now(), closed_by = pg_temp.uid('admin') where exam_id = pg_temp.k('e');
select is(concat_ws('/', public.marking_unit_blocked(pg_temp.k('x9/G1'), pg_temp.uid('m5'), now(), true),
                    (select count(*) from public.marking_units_allowed(pg_temp.k('e'), pg_temp.uid('m5'), 'live', true))),
  'marking_closed/0', 'once marking has closed: marking_closed, and the rule allows nothing');
update public.exam_marking set opened_at = null, closed_at = null, closed_by = null where exam_id = pg_temp.k('e');
select is(concat_ws('/', public.marking_unit_blocked(pg_temp.k('x9/G1'), pg_temp.uid('m5'), now(), true),
                    (select count(*) from public.marking_units_allowed(pg_temp.k('e'), pg_temp.uid('m5'), 'live', true))),
  'marking_not_open/0', 'before it opens: marking_not_open, and the rule allows nothing');
update public.exam_marking set opened_at = now() where exam_id = pg_temp.k('e');

-- ---------------------------------------------------------------------------------------------
-- assigned_piece_ignores_name_seen: an admin may give a marker a piece they saw a name on (p_next false).
-- ---------------------------------------------------------------------------------------------
select is(concat_ws('/', coalesce(public.marking_unit_blocked(pg_temp.k('x3/G1'), pg_temp.uid('m3'), now(), false), 'ok'),
                    exists (select 1 from public.marking_units_allowed(pg_temp.k('e'), pg_temp.uid('m3'), 'live', false) a
                            where a.unit_id = pg_temp.k('x3/G1')),
                    exists (select 1 from public.marking_units_allowed(pg_temp.k('e'), pg_temp.uid('m3'), 'live', true) a
                            where a.unit_id = pg_temp.k('x3/G1'))),
  'ok/t/f', 'assigned_piece_ignores_name_seen: m3 may be assigned x3/G1, not given it by Next script');
select tests.as_user(pg_temp.uid('admin'));
select is(public.marking_assign(array[pg_temp.k('x3/G1')], pg_temp.uid('m3'), 'The name is hidden now'),
  '{"ok": true, "assigned": 1, "skipped": []}'::jsonb, 'and an admin assigns it to them');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- allowed_is_internal
-- ---------------------------------------------------------------------------------------------
select is((select count(*)::int from unnest(array['anon', 'authenticated', 'service_role']) ro
           where has_function_privilege(ro, 'public.marking_units_allowed(uuid, uuid, public.marking_kind, boolean, uuid)', 'execute')), 0,
  'allowed_is_internal: marking_units_allowed cannot be called from the API, nor by the service role');

-- ---------------------------------------------------------------------------------------------
-- seed_kind_can_have_two_holders_on_one_piece, practice_kind_can_have_two_holders_on_one_piece
-- ---------------------------------------------------------------------------------------------
select lives_ok($$insert into public.marking_assignments (unit_id, kind, marker_id, how, assigned_by)
                  values (pg_temp.k('x9/G1'), 'seed', pg_temp.uid('m1'), 'assigned', pg_temp.uid('admin')),
                         (pg_temp.k('x9/G1'), 'seed', pg_temp.uid('m2'), 'assigned', pg_temp.uid('admin'))$$,
  'seed_kind_can_have_two_holders_on_one_piece: two markers hold the seeded pass of one piece at once');
select lives_ok($$insert into public.marking_assignments (unit_id, kind, marker_id, how, assigned_by)
                  values (pg_temp.k('x9/G2'), 'practice', pg_temp.uid('m1'), 'assigned', pg_temp.uid('admin')),
                         (pg_temp.k('x9/G2'), 'practice', pg_temp.uid('m2'), 'assigned', pg_temp.uid('admin'))$$,
  'practice_kind_can_have_two_holders_on_one_piece: two markers hold the practice pass of one piece at once');

-- ---------------------------------------------------------------------------------------------
-- live_second_and_remark_keep_one_holder (each refusal names the one-holder index, not the one per marker)
-- ---------------------------------------------------------------------------------------------
select lives_ok($$insert into public.marking_assignments (unit_id, kind, marker_id, how, assigned_by)
                  values (pg_temp.k('x10/G1'), 'live', pg_temp.uid('m1'), 'assigned', pg_temp.uid('admin')),
                         (pg_temp.k('x10/G1'), 'second', pg_temp.uid('m2'), 'assigned', pg_temp.uid('admin')),
                         (pg_temp.k('x10/G1'), 'remark', pg_temp.uid('m3'), 'assigned', pg_temp.uid('admin'))$$,
  'live_second_and_remark_keep_one_holder: three markers hold the live, second and re-mark passes of one piece');
select throws_ok($$insert into public.marking_assignments (unit_id, kind, marker_id, how, assigned_by)
                   values (pg_temp.k('x10/G1'), 'live', pg_temp.uid('m4'), 'assigned', pg_temp.uid('admin'))$$,
  '23505', 'duplicate key value violates unique constraint "marking_assignments_one_holder"', 'a second open live hold is refused');
select throws_ok($$insert into public.marking_assignments (unit_id, kind, marker_id, how, assigned_by)
                   values (pg_temp.k('x10/G1'), 'second', pg_temp.uid('m5'), 'assigned', pg_temp.uid('admin'))$$,
  '23505', 'duplicate key value violates unique constraint "marking_assignments_one_holder"', 'so is a second open second-pass hold');
select throws_ok($$insert into public.marking_assignments (unit_id, kind, marker_id, how, assigned_by)
                   values (pg_temp.k('x10/G1'), 'remark', pg_temp.uid('m6'), 'assigned', pg_temp.uid('admin'))$$,
  '23505', 'duplicate key value violates unique constraint "marking_assignments_one_holder"', 'and a second open re-mark hold');

-- ---------------------------------------------------------------------------------------------
-- one_marker_one_open_hold_per_piece
-- ---------------------------------------------------------------------------------------------
insert into public.marking_assignments (unit_id, kind, marker_id, how, assigned_by)
values (pg_temp.k('x10/G2'), 'live', pg_temp.uid('m1'), 'assigned', pg_temp.uid('admin'));
select throws_ok($$insert into public.marking_assignments (unit_id, kind, marker_id, how, assigned_by)
                   values (pg_temp.k('x10/G2'), 'second', pg_temp.uid('m1'), 'assigned', pg_temp.uid('admin'))$$,
  '23505', 'duplicate key value violates unique constraint "marking_assignments_one_per_marker"',
  'one_marker_one_open_hold_per_piece: the marker who holds a piece live cannot hold its second pass too');
select throws_ok($$insert into public.marking_assignments (unit_id, kind, marker_id, how, assigned_by)
                   values (pg_temp.k('x10/G2'), 'seed', pg_temp.uid('m1'), 'assigned', pg_temp.uid('admin'))$$,
  '23505', 'duplicate key value violates unique constraint "marking_assignments_one_per_marker"', 'nor a seeded pass of it');
select lives_ok($$insert into public.marking_assignments (unit_id, kind, marker_id, how, assigned_by)
                  values (pg_temp.k('x10/G2'), 'second', pg_temp.uid('m2'), 'assigned', pg_temp.uid('admin'))$$,
  'another marker can hold its second pass');
update public.marking_assignments set ended_at = now(), end_reason = 'given_back'
where unit_id = pg_temp.k('x10/G2') and marker_id = pg_temp.uid('m1');
select lives_ok($$insert into public.marking_assignments (unit_id, kind, marker_id, how, assigned_by)
                  values (pg_temp.k('x10/G2'), 'seed', pg_temp.uid('m1'), 'assigned', pg_temp.uid('admin'))$$,
  'an ended hold does not count (it stays as a record)');

-- ---------------------------------------------------------------------------------------------
-- one_marker_one_standing_marking_per_piece
-- ---------------------------------------------------------------------------------------------
insert into public.markings (unit_id, marker_id) values (pg_temp.k('x10/G2'), pg_temp.uid('m1'));
select throws_ok($$insert into public.markings (unit_id, kind, marker_id) values (pg_temp.k('x10/G2'), 'second', pg_temp.uid('m1'))$$,
  '23505', 'duplicate key value violates unique constraint "markings_one_pass_per_marker"',
  'one_marker_one_standing_marking_per_piece: a marker whose live marking stands cannot start a second marking of the piece');
select throws_ok($$insert into public.markings (unit_id, kind, marker_id) values (pg_temp.k('x10/G2'), 'seed', pg_temp.uid('m1'))$$,
  '23505', 'duplicate key value violates unique constraint "markings_one_pass_per_marker"', 'nor a seeded one');
select lives_ok($$insert into public.markings (unit_id, kind, marker_id) values (pg_temp.k('x10/G2'), 'second', pg_temp.uid('m2'))$$,
  'another marker''s second marking may stand beside it');
update public.markings set status = 'set_aside', set_aside_at = now(), set_aside_reason = 'given_back'
where unit_id = pg_temp.k('x10/G2') and marker_id = pg_temp.uid('m1') and kind = 'live';
select lives_ok($$insert into public.markings (unit_id, kind, marker_id) values (pg_temp.k('x10/G2'), 'seed', pg_temp.uid('m1'))$$,
  'a marking set aside does not count');

select * from finish();
rollback;
