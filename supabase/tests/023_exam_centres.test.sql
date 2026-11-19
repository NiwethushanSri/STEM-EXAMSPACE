begin;
create extension if not exists pgtap with schema extensions;
select plan(81);
select tests.assert_no_owner();

-- Fixtures.
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values ('admin', tests.create_user('admin', 'active'));
insert into c values ('teacher', tests.create_user('teacher', 'active'));
insert into c values ('teacher2', tests.create_user('teacher', 'active'));
insert into c values ('parent', tests.create_user('parent', 'active'));
insert into c values ('s1', tests.create_user('student', 'active'));
insert into c values ('s2', tests.create_user('student', 'active'));
insert into c values ('s3', tests.create_user('student', 'active'));
insert into c values ('s4', tests.create_user('student', 'active'));
insert into c values ('susp', tests.create_user('student', 'suspended'));
insert into public.parent_children values ((select id from c where name = 'parent'), (select id from c where name = 's1'));

insert into public.subjects (name, kind) values ('ZZ Centres', 'school'), ('ZZ Centres Other', 'school');
create temp table subj (name text primary key, id bigint not null);
grant select on subj to public;
insert into subj select name, id from public.subjects where name in ('ZZ Centres', 'ZZ Centres Other');
insert into public.teacher_subjects values
  ((select id from c where name = 'teacher'), (select id from subj where name = 'ZZ Centres')),
  ((select id from c where name = 'teacher2'), (select id from subj where name = 'ZZ Centres Other'));

create temp table st (name text primary key, id uuid);
grant all on st to public;
insert into public.venues (name, rooms) values
  ('ZZ Alpha Hall', array['A1', 'A2']), ('ZZ Beta Hall', array['B1', 'B2']), ('ZZ Gamma Hall', array['G1']),
  ('ZZ Delta Hall', array['D1']);
insert into public.venues (name, rooms) select 'ZZ Big Hall', array_agg('R' || i order by i) from generate_series(1, 21) i;
insert into st select 'alpha', id from public.venues where name = 'ZZ Alpha Hall';
insert into st select 'beta', id from public.venues where name = 'ZZ Beta Hall';
insert into st select 'gamma', id from public.venues where name = 'ZZ Gamma Hall';
insert into st select 'delta', id from public.venues where name = 'ZZ Delta Hall';
insert into st select 'big', id from public.venues where name = 'ZZ Big Hall';

-- One centre in save_exam's shape (venue by stash name).
create function pg_temp.ctr(p_venue text, p_room text, p_seats int, p_id uuid default null) returns jsonb
language sql stable as $$
  select jsonb_strip_nulls(jsonb_build_object('id', p_id, 'venue_id', (select id from st where name = p_venue),
    'room', p_room, 'seat_limit', p_seats))
$$;
grant execute on function pg_temp.ctr(text, text, int, uuid) to public;
-- An exam's current (not removed) centre by venue and room.
create function pg_temp.cid(p_exam text, p_venue text, p_room text) returns uuid
language sql stable as $$
  select ec.id from public.exam_centres ec
  where ec.exam_id = (select id from st where name = p_exam) and ec.removed_at is null
    and ec.venue_id = (select id from st where name = p_venue) and ec.room = p_room
$$;
grant execute on function pg_temp.cid(text, text, text) to public;
-- save_exam with the fields this file does not vary.
create function pg_temp.save(p_id uuid, p_format public.exam_format, p_centres jsonb, p_title text default 'ZZ Centre exam') returns jsonb
language sql as $$
  select public.save_exam(p_id, (select id from subj where name = 'ZZ Centres'), p_title, 'P1', p_format, p_centres,
    date_trunc('minute', now()) + interval '30 days', 60, 1000, date_trunc('minute', now()) + interval '20 days')
$$;
grant execute on function pg_temp.save(uuid, public.exam_format, jsonb, text) to public;
-- A booking written directly (at the given centre, or at home when it is null).
create function pg_temp.book(p_exam text, p_student text, p_status public.booking_status, p_centre uuid) returns void
language sql as $$
  insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence, sitting, centre_id)
  values ((select id from st where name = p_exam), (select id from c where name = p_student),
    (select id from c where name = p_student), p_status, 1000,
    case when p_centre is null then 'home'::public.sitting_mode else 'centre'::public.sitting_mode end, p_centre)
$$;

-- save_exam_two_centres
select tests.as_user((select id from c where name = 'admin'));
insert into st select 'two', (pg_temp.save(null, 'in_person', jsonb_build_array(pg_temp.ctr('beta', 'B1', 4), pg_temp.ctr('alpha', 'A1', 3)), 'ZZ Two centres') ->> 'id')::uuid;
select isnt((select id from st where name = 'two'), null, 'save_exam_two_centres: an in-person exam saves with two centres');
select is((select count(*)::int from public.exam_centres where exam_id = (select id from st where name = 'two')), 2, 'both centres are saved');
select is(public.set_exam_status((select id from st where name = 'two'), 'published') ->> 'ok', 'true', 'the two-centre exam publishes');
select tests.as_postgres();
insert into st select 'two_a', pg_temp.cid('two', 'alpha', 'A1');
insert into st select 'two_b', pg_temp.cid('two', 'beta', 'B1');
select pg_temp.book('two', 's1', 'paid', (select id from st where name = 'two_a'));
set local role anon;
select is((select seats_left from public.exams_public where id = (select id from st where name = 'two')), 6, 'seats_left is the sum over centres (3 + 4, one taken)');
select is((select centres from public.exams_public where id = (select id from st where name = 'two')),
  jsonb_build_array(
    jsonb_build_object('id', (select id from st where name = 'two_a'), 'venue', 'ZZ Alpha Hall', 'seats_left', 2),
    jsonb_build_object('id', (select id from st where name = 'two_b'), 'venue', 'ZZ Beta Hall', 'seats_left', 4)),
  'centres lists each centre with its seats left, ordered by venue name');
-- view_hides_rooms
select is((select count(*)::int from public.exams_public, jsonb_array_elements(centres) e where e ? 'room'), 0, 'view_hides_rooms: no centre entry has a room key');
select is((select array_agg(distinct k order by k) from public.exams_public, jsonb_array_elements(centres) e, jsonb_object_keys(e) k
  where id = (select id from st where name = 'two')), array['id', 'seats_left', 'venue'], 'a centre entry carries only id, venue and seats_left');
select tests.as_postgres();

-- online_exam_has_no_centres
select tests.as_user((select id from c where name = 'admin'));
select is(pg_temp.save(null, 'online', jsonb_build_array(pg_temp.ctr('alpha', 'A1', 5))) ->> 'code', 'invalid_input', 'online_exam_has_no_centres: an online exam with a centre is refused');
select is(pg_temp.save(null, 'in_person', '[]') ->> 'code', 'invalid_input', 'an in-person exam with no centre is refused');
select is(pg_temp.save(null, 'both', '[]') ->> 'code', 'invalid_input', 'an exam offering both sittings with no centre is refused');
select is(pg_temp.save(null, 'in_person', null) ->> 'code', 'invalid_input', 'an in-person exam with centres left out is refused');
insert into st select 'home', (pg_temp.save(null, 'online', null, 'ZZ Home only') ->> 'id')::uuid;
select isnt((select id from st where name = 'home'), null, 'an online exam saves with no centres');

-- duplicate_centre_refused, and other centre shapes.
select is(pg_temp.save(null, 'in_person', jsonb_build_array(pg_temp.ctr('alpha', 'A1', 5), pg_temp.ctr('alpha', 'A1', 7))) ->> 'code', 'invalid_input', 'duplicate_centre_refused: the same venue and room twice');
select is(pg_temp.save(null, 'in_person', jsonb_build_array(pg_temp.ctr('alpha', 'A1', 5), pg_temp.ctr('alpha', 'A2', 7)), 'ZZ Two rooms') ->> 'ok', 'true', 'two rooms at one venue are two centres');
select is(pg_temp.save(null, 'in_person', '[{"venue_id": "not-a-uuid", "room": "A1", "seat_limit": 5}]') ->> 'code', 'invalid_input', 'a venue id must be a uuid');
select is(pg_temp.save(null, 'in_person', jsonb_build_array(pg_temp.ctr('alpha', 'A1', 5) || '{"seat_limit": 2.5}')) ->> 'code', 'invalid_input', 'a seat limit must be a whole number');
select is(pg_temp.save(null, 'in_person', jsonb_build_array(pg_temp.ctr('alpha', 'A1', 5) || '{"seat_limit": "5"}')) ->> 'code', 'invalid_input', 'a seat limit must be a number');
select is(pg_temp.save(null, 'in_person', '[5]') ->> 'code', 'invalid_input', 'a centre must be an object');
select is(pg_temp.save(null, 'in_person', (select jsonb_agg(pg_temp.ctr('big', 'R' || i, 1)) from generate_series(1, 21) i)) ->> 'code', 'invalid_input', 'at most 20 centres');
select is(pg_temp.save(null, 'in_person', (select jsonb_agg(pg_temp.ctr('big', 'R' || i, 1)) from generate_series(1, 20) i), 'ZZ Twenty') ->> 'ok', 'true', '20 centres are allowed');
select is(pg_temp.save(null, 'in_person', jsonb_build_array(pg_temp.ctr('alpha', 'A1', 5, (select id from st where name = 'two_a')))) ->> 'code', 'invalid_input', 'a new exam cannot take an existing centre');
select is(pg_temp.save((select id from st where name = 'home'), 'in_person', jsonb_build_array(pg_temp.ctr('alpha', 'A1', 5, (select id from st where name = 'two_a'))), 'ZZ Home only') ->> 'code', 'invalid_input', 'nor can another exam');
select tests.as_postgres();
select is((select count(*)::int from public.exam_centres where exam_id = (select id from st where name = 'home')), 0, 'the refused save wrote nothing');

-- centre_seat_limit_not_below_taken (centre A1 holds two bookings, B1 none)
select pg_temp.book('two', 's2', 'awaiting_payment', (select id from st where name = 'two_a'));
select tests.as_user((select id from c where name = 'admin'));
select is(pg_temp.save((select id from st where name = 'two'), 'in_person', jsonb_build_array(
  pg_temp.ctr('alpha', 'A1', 1, (select id from st where name = 'two_a')), pg_temp.ctr('beta', 'B1', 4, (select id from st where name = 'two_b'))), 'ZZ Two centres') ->> 'code',
  'conflict', 'centre_seat_limit_not_below_taken: a centre cannot drop below its taken seats');
select is(pg_temp.save((select id from st where name = 'two'), 'in_person', jsonb_build_array(
  pg_temp.ctr('alpha', 'A1', 2, (select id from st where name = 'two_a')), pg_temp.ctr('beta', 'B1', 1, (select id from st where name = 'two_b'))), 'ZZ Two centres') ->> 'ok',
  'true', 'each centre is checked against its own bookings');
select tests.as_postgres();
select is((select string_agg(room || ':' || seat_limit::text, ',' order by room) from public.exam_centres where exam_id = (select id from st where name = 'two')), 'A1:2,B1:1', 'seat limits are saved per centre');

-- centre_with_bookings_cannot_be_removed
select tests.as_user((select id from c where name = 'admin'));
select is(pg_temp.save((select id from st where name = 'two'), 'in_person', jsonb_build_array(
  pg_temp.ctr('beta', 'B1', 1, (select id from st where name = 'two_b'))), 'ZZ Two centres') ->> 'code', 'conflict', 'centre_with_bookings_cannot_be_removed');
select is(pg_temp.save((select id from st where name = 'two'), 'in_person', jsonb_build_array(
  pg_temp.ctr('alpha', 'A1', 2, (select id from st where name = 'two_a'))), 'ZZ Two centres') ->> 'ok', 'true', 'a centre without bookings can be removed');
select is(pg_temp.save((select id from st where name = 'two'), 'in_person', jsonb_build_array(
  pg_temp.ctr('alpha', 'A1', 2, (select id from st where name = 'two_a')), pg_temp.ctr('beta', 'B2', 5)), 'ZZ Two centres') ->> 'ok', 'true', 'a centre can be added to a published exam');
select tests.as_postgres();
select is((select string_agg(room, ',' order by room) from public.exam_centres where exam_id = (select id from st where name = 'two') and removed_at is null), 'A1,B2', 'B1 removed, B2 added, A1 kept');
insert into st select 'two_b2', pg_temp.cid('two', 'beta', 'B2');
select pg_temp.book('two', 's3', 'cancelled', (select id from st where name = 'two_b2'));

-- Removed centres are archived: only live bookings hold a centre; a removed one is skipped everywhere.
select tests.as_user((select id from c where name = 'admin'));
select is(pg_temp.save((select id from st where name = 'two'), 'in_person', jsonb_build_array(
  pg_temp.ctr('alpha', 'A1', 2, (select id from st where name = 'two_a'))), 'ZZ Two centres') ->> 'ok', 'true', 'a centre whose only booking is cancelled can be removed');
select tests.as_postgres();
select is((select (removed_at is not null)::text from public.exam_centres where id = (select id from st where name = 'two_b2')) || '/'
  || (select (centre_id = (select id from st where name = 'two_b2'))::text from public.bookings where exam_id = (select id from st where name = 'two') and student_id = (select id from c where name = 's3')),
  'true/true', 'the centre is archived, and its cancelled booking keeps it on record');
set local role anon;
select is((select jsonb_agg(e ->> 'venue') from public.exams_public, jsonb_array_elements(centres) e where id = (select id from st where name = 'two')), '["ZZ Alpha Hall"]'::jsonb, 'the removed centre disappears from exams_public');
select is((select seats_left from public.exams_public where id = (select id from st where name = 'two')), 0, 'and from seats_left (A1 is full; B2''s five seats are gone)');
select tests.as_postgres();
select is(public.booking_create_as((select id from c where name = 's4'), (select id from st where name = 'two'), (select id from c where name = 's4'), now(), null, (select id from st where name = 'two_b2')) ->> 'code', 'invalid_input', 'a removed centre cannot be booked');
select is(public.mark_attendance_as((select id from c where name = 'admin'), (select id from st where name = 'two_b2'), (select id from c where name = 's3'), now()) ->> 'code', 'not_found', 'a removed centre has no register');
select tests.as_user((select id from c where name = 'admin'));
select is(public.change_booking_sitting((select id from public.bookings where exam_id = (select id from st where name = 'two') and student_id = (select id from c where name = 's2')),
  'centre', (select id from st where name = 'two_b'), 'Move') ->> 'code', 'invalid_input', 'a removed centre is not a move target');
select tests.as_postgres();
select is((select count(*)::int from public.audit_log where action = 'exam_updated' and target_id = (select id from st where name = 'two')), 4, 'each successful published edit is audited');

-- Re-adding a removed venue and room, then switching to online, once only past bookings remain.
select tests.as_user((select id from c where name = 'admin'));
insert into st select 'arch', (pg_temp.save(null, 'in_person', jsonb_build_array(pg_temp.ctr('alpha', 'A1', 5), pg_temp.ctr('beta', 'B1', 5)), 'ZZ Arch') ->> 'id')::uuid;
select is(public.set_exam_status((select id from st where name = 'arch'), 'published') ->> 'ok', 'true', 'arch published');
select tests.as_postgres();
insert into st select 'arch_a', pg_temp.cid('arch', 'alpha', 'A1');
insert into st select 'arch_b', pg_temp.cid('arch', 'beta', 'B1');
select pg_temp.book('arch', 's1', 'cancelled', (select id from st where name = 'arch_b'));
select pg_temp.book('arch', 's2', 'expired', (select id from st where name = 'arch_a'));
select tests.as_user((select id from c where name = 'admin'));
select is(pg_temp.save((select id from st where name = 'arch'), 'in_person', jsonb_build_array(
  pg_temp.ctr('alpha', 'A1', 5, (select id from st where name = 'arch_a'))), 'ZZ Arch') ->> 'ok', 'true', 'B1 (a cancelled booking only) is removed');
select is(pg_temp.save((select id from st where name = 'arch'), 'in_person', jsonb_build_array(
  pg_temp.ctr('alpha', 'A1', 5, (select id from st where name = 'arch_a')), pg_temp.ctr('beta', 'B1', 5, (select id from st where name = 'arch_b'))), 'ZZ Arch') ->> 'code',
  'invalid_input', 'a removed centre''s id cannot be saved again');
select is(pg_temp.save((select id from st where name = 'arch'), 'in_person', jsonb_build_array(
  pg_temp.ctr('alpha', 'A1', 5, (select id from st where name = 'arch_a')), pg_temp.ctr('beta', 'B1', 6)), 'ZZ Arch') ->> 'ok', 'true', 'the same venue and room can be added again after removal');
select tests.as_postgres();
select is((select string_agg((removed_at is null)::text || ':' || seat_limit::text, ',' order by removed_at nulls last) from public.exam_centres
  where exam_id = (select id from st where name = 'arch') and room = 'B1'), 'false:5,true:6', 'as a new centre beside the archived one');
select tests.as_user((select id from c where name = 'admin'));
select is(pg_temp.save((select id from st where name = 'arch'), 'online', '[]', 'ZZ Arch') ->> 'ok', 'true', 'the exam switches to online: its only bookings at a centre are past ones');
select tests.as_postgres();
select is((select count(*) filter (where removed_at is null) || '/' || count(*) from public.exam_centres where exam_id = (select id from st where name = 'arch')), '0/3', 'every centre is archived, none deleted');
set local role anon;
select is((select centres::text || '/' || coalesce(seats_left::text, 'null') from public.exams_public where id = (select id from st where name = 'arch')), '[]/null', 'the home-only exam lists no centres');
select tests.as_postgres();

-- A removed centre no longer holds its venue, and publishing skips it.
select tests.as_user((select id from c where name = 'admin'));
insert into st select 'del', (pg_temp.save(null, 'in_person', jsonb_build_array(pg_temp.ctr('alpha', 'A2', 5), pg_temp.ctr('delta', 'D1', 5)), 'ZZ Del') ->> 'id')::uuid;
select is(pg_temp.save((select id from st where name = 'del'), 'in_person', jsonb_build_array(pg_temp.ctr('alpha', 'A2', 5, pg_temp.cid('del', 'alpha', 'A2'))), 'ZZ Del') ->> 'ok', 'true', 'a draft drops its Delta centre');
select is(public.save_venue((select id from st where name = 'delta'), 'ZZ Delta Hall', array['D1'], false) ->> 'ok', 'true', 'a venue used only by a removed centre can be deactivated');
select is(public.set_exam_status((select id from st where name = 'del'), 'published') ->> 'ok', 'true', 'publishing skips the removed centre at the now inactive venue');
select tests.as_postgres();

-- Two centres can swap rooms in one save (the venue and room key is checked after all are written).
select tests.as_user((select id from c where name = 'admin'));
insert into st select 'swap', (pg_temp.save(null, 'in_person', jsonb_build_array(pg_temp.ctr('alpha', 'A1', 3), pg_temp.ctr('alpha', 'A2', 4)), 'ZZ Swap') ->> 'id')::uuid;
select tests.as_postgres();
insert into st select 'swap_1', pg_temp.cid('swap', 'alpha', 'A1');
insert into st select 'swap_2', pg_temp.cid('swap', 'alpha', 'A2');
select tests.as_user((select id from c where name = 'admin'));
select is(pg_temp.save((select id from st where name = 'swap'), 'in_person', jsonb_build_array(
  pg_temp.ctr('alpha', 'A2', 3, (select id from st where name = 'swap_1')), pg_temp.ctr('alpha', 'A1', 4, (select id from st where name = 'swap_2'))), 'ZZ Swap') ->> 'ok',
  'true', 'two centres swap rooms in one save');
select tests.as_postgres();
select is((select room from public.exam_centres where id = (select id from st where name = 'swap_1')) || (select room from public.exam_centres where id = (select id from st where name = 'swap_2')), 'A2A1', 'the rooms swapped in place');

-- format_switch_refused_with_conflicting_bookings
select tests.as_user((select id from c where name = 'admin'));
insert into st select 'both1', (pg_temp.save(null, 'both', jsonb_build_array(pg_temp.ctr('alpha', 'A1', 5)), 'ZZ Both 1') ->> 'id')::uuid;
insert into st select 'both2', (pg_temp.save(null, 'both', jsonb_build_array(pg_temp.ctr('alpha', 'A1', 5)), 'ZZ Both 2') ->> 'id')::uuid;
select is((public.set_exam_status((select id from st where name = 'both1'), 'published') ->> 'ok') || (public.set_exam_status((select id from st where name = 'both2'), 'published') ->> 'ok'), 'truetrue', 'exams offering both sittings publish');
select tests.as_postgres();
select pg_temp.book('both1', 's1', 'paid', pg_temp.cid('both1', 'alpha', 'A1'));
select pg_temp.book('both2', 's1', 'paid', null);
select tests.as_user((select id from c where name = 'admin'));
select is(pg_temp.save((select id from st where name = 'both1'), 'online', '[]', 'ZZ Both 1') ->> 'code', 'conflict', 'format_switch_refused_with_conflicting_bookings: both to online with a live centre booking');
select is(pg_temp.save((select id from st where name = 'both2'), 'in_person', jsonb_build_array(pg_temp.ctr('alpha', 'A1', 5, pg_temp.cid('both2', 'alpha', 'A1'))), 'ZZ Both 2') ->> 'code', 'conflict', 'both to in_person with a live home booking');
select is(pg_temp.save((select id from st where name = 'both1'), 'in_person', jsonb_build_array(pg_temp.ctr('alpha', 'A1', 5, pg_temp.cid('both1', 'alpha', 'A1'))), 'ZZ Both 1') ->> 'ok', 'true', 'both to in_person when every live booking is at the centre');
select is(pg_temp.save((select id from st where name = 'both2'), 'online', '[]', 'ZZ Both 2') ->> 'ok', 'true', 'both to online when every live booking is at home');
select tests.as_postgres();
select is((select count(*)::int from public.exam_centres where exam_id = (select id from st where name = 'both2') and removed_at is null), 0, 'the now home-only exam has no current centre');

-- publish_checks_every_centre
select tests.as_user((select id from c where name = 'admin'));
insert into st select 'pub', (pg_temp.save(null, 'in_person', jsonb_build_array(pg_temp.ctr('alpha', 'A1', 5), pg_temp.ctr('beta', 'B1', 5)), 'ZZ Pub') ->> 'id')::uuid;
select tests.as_postgres();
update public.venues set active = false where id = (select id from st where name = 'beta');
select tests.as_user((select id from c where name = 'admin'));
select is(public.set_exam_status((select id from st where name = 'pub'), 'published') ->> 'code', 'invalid_input', 'publish_checks_every_centre: a centre at an inactive venue');
select tests.as_postgres();
update public.venues set active = true where id = (select id from st where name = 'beta');
update public.venues set rooms = array['A2'] where id = (select id from st where name = 'alpha');
select tests.as_user((select id from c where name = 'admin'));
select is(public.set_exam_status((select id from st where name = 'pub'), 'published') ->> 'code', 'invalid_input', 'a centre whose room is no longer in the venue');
select tests.as_postgres();
update public.venues set rooms = array['A1', 'A2'] where id = (select id from st where name = 'alpha');
with x as (
  insert into public.exams (subject_id, title, paper, format, starts_at, duration_minutes, price_pence, price_confirmed, booking_deadline, status)
  values ((select id from subj where name = 'ZZ Centres'), 'ZZ Bare', 'P1', 'in_person', now() + interval '30 days', 60, 1000, true, now() + interval '20 days', 'draft')
  returning id)
insert into st select 'bare', id from x;
select tests.as_user((select id from c where name = 'admin'));
select is(public.set_exam_status((select id from st where name = 'bare'), 'published') ->> 'code', 'invalid_input', 'an in-person exam without centres cannot publish');
select is(public.set_exam_status((select id from st where name = 'pub'), 'published') ->> 'ok', 'true', 'publishes once every centre is valid');

-- save_venue_protects_centres
select is(public.save_venue((select id from st where name = 'beta'), 'ZZ Beta Hall', array['B1', 'B2'], false) ->> 'code', 'conflict', 'save_venue_protects_centres: cannot deactivate a venue used by an upcoming centre');
select is(public.save_venue((select id from st where name = 'beta'), 'ZZ Beta Hall', array['B2'], true) ->> 'code', 'conflict', 'cannot remove a room used by an upcoming centre');
select is(public.save_venue((select id from st where name = 'beta'), 'ZZ Beta Hall', array['B1', 'B2', 'B3'], true) ->> 'ok', 'true', 'adding a room is fine');
insert into st select 'gone', (pg_temp.save(null, 'in_person', jsonb_build_array(pg_temp.ctr('gamma', 'G1', 5)), 'ZZ Gone') ->> 'id')::uuid;
select is(public.set_exam_status((select id from st where name = 'gone'), 'published') ->> 'ok', 'true', 'gone published');
select tests.as_postgres();
select pg_temp.book('gone', 's4', 'paid', pg_temp.cid('gone', 'gamma', 'G1'));
select tests.as_user((select id from c where name = 'admin'));
select is(public.set_exam_status((select id from st where name = 'gone'), 'cancelled') ->> 'ok', 'true', 'gone cancelled');
select is(public.save_venue((select id from st where name = 'gamma'), 'ZZ Gamma Hall', array['G1'], false) ->> 'ok', 'true', 'a venue used only by a cancelled exam can be deactivated');

-- Teachers save centres on their own drafts; the price rules are unchanged.
select tests.as_postgres();
select tests.as_user((select id from c where name = 'teacher'));
insert into st select 't_draft', (pg_temp.save(null, 'in_person', jsonb_build_array(pg_temp.ctr('alpha', 'A2', 8)), 'ZZ Teacher centre') ->> 'id')::uuid;
select isnt((select id from st where name = 't_draft'), null, 'a teacher saves a draft with a centre');
select tests.as_postgres();
select is((select e.price_pence::text || '/' || ec.seat_limit::text from public.exams e join public.exam_centres ec on ec.exam_id = e.id where e.id = (select id from st where name = 't_draft')), '0/8', 'the teacher draft has its centre and no price');

-- exam_centres RLS mirrors exams.
select tests.as_user((select id from c where name = 'teacher'));
select is((select count(*)::int from public.exam_centres where exam_id = (select id from st where name = 'swap')), 2, 'exam_centres RLS: a teacher sees centres of own-subject drafts');
select tests.as_postgres(); select tests.as_user((select id from c where name = 'teacher2'));
select is((select count(*)::int from public.exam_centres where exam_id in ((select id from st where name = 'swap'), (select id from st where name = 'pub'))), 2, 'a teacher of another subject sees published centres only');
select tests.as_postgres(); select tests.as_user((select id from c where name = 'parent'));
select is((select count(*)::int from public.exam_centres where exam_id in ((select id from st where name = 'swap'), (select id from st where name = 'pub'))), 2, 'a family sees centres of published exams, not drafts');
select tests.as_postgres(); select tests.as_user((select id from c where name = 's4'));
select is((select count(*)::int from public.exam_centres where exam_id = (select id from st where name = 'gone')), 1, 'a family keeps seeing the centre of a cancelled exam it booked');
select tests.as_postgres(); select tests.as_user((select id from c where name = 's3'));
select is((select count(*)::int from public.exam_centres where exam_id = (select id from st where name = 'gone')), 0, 'others do not see a cancelled exam''s centres');
select tests.as_postgres(); select tests.as_user((select id from c where name = 'susp'));
select is((select count(*)::int from public.exam_centres where exam_id = (select id from st where name = 'pub')), 0, 'a suspended account sees no centres');
select tests.as_postgres(); select tests.as_user((select id from c where name = 'admin'));
select throws_ok($$update public.exam_centres set seat_limit = 999$$, '42501', null, 'no client writes to exam_centres, even as admin');
select tests.as_postgres();

-- backfill_one_centre_per_in_person_exam: recreate the shape before 20261118000046/0047 inside this rolled-back
-- transaction, then run those migrations' own backfill statements from the migration history.
alter table public.exams add column venue_id uuid, add column room text, add column seat_limit int;
alter table public.bookings alter column sitting drop not null, drop constraint bookings_sitting_matches_centre;
with x as (
  insert into public.exams (subject_id, title, paper, format, starts_at, duration_minutes, price_pence, booking_deadline, status, venue_id, room, seat_limit)
  values
    ((select id from subj where name = 'ZZ Centres'), 'ZZ Old in person', 'P1', 'in_person', now() + interval '30 days', 60, 1000, now() + interval '20 days', 'published', (select id from st where name = 'alpha'), 'A2', 7),
    ((select id from subj where name = 'ZZ Centres'), 'ZZ Old online', 'P1', 'online', now() + interval '30 days', 60, 1000, now() + interval '20 days', 'published', null, null, 5)
  returning id, format)
insert into st select case when format = 'online' then 'old_on' else 'old_ip' end, id from x;
insert into public.bookings (exam_id, student_id, booked_by, status, amount_pence) values
  ((select id from st where name = 'old_ip'), (select id from c where name = 's2'), (select id from c where name = 's2'), 'paid', 1000),
  ((select id from st where name = 'old_on'), (select id from c where name = 's2'), (select id from c where name = 's2'), 'paid', 1000);
create temp table backfill as
  select t.stmt, m.version, t.n from supabase_migrations.schema_migrations m, unnest(m.statements) with ordinality as t(stmt, n)
  where m.version in ('20261118000046', '20261118000047')
    and t.stmt ~* '^\s*(--[^\n]*\n\s*)*(insert into public\.exam_centres|update public\.bookings)';
select is((select count(*)::int from backfill), 3, 'the three backfill statements are in the migration history');
do $$
declare
  s text;
begin
  for s in select stmt from backfill order by version, n loop
    execute s;
  end loop;
end;
$$;
select is((select string_agg(venue_id::text || '/' || room || '/' || seat_limit::text, ',') from public.exam_centres where exam_id = (select id from st where name = 'old_ip')),
  (select id from st where name = 'alpha')::text || '/A2/7', 'backfill_one_centre_per_in_person_exam: one centre with the exam''s venue, room and seat limit');
select is((select count(*)::int from public.exam_centres where exam_id = (select id from st where name = 'old_on')), 0, 'an online exam gets no centre');
select is((select b.sitting::text || '/' || (b.centre_id = ec.id)::text from public.bookings b join public.exam_centres ec on ec.exam_id = b.exam_id where b.exam_id = (select id from st where name = 'old_ip')), 'centre/true', 'a booking on an in-person exam sits at its centre');
select is((select sitting::text || '/' || coalesce(centre_id::text, 'none') from public.bookings where exam_id = (select id from st where name = 'old_on')), 'home/none', 'a booking on an online exam sits at home');

select * from finish();
rollback;
