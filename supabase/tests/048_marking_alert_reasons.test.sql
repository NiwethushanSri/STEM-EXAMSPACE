begin;
create extension if not exists pgtap with schema extensions;
select plan(13);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Subject 'ZZ Alert reasons': lead leads it, m1 marks it. Exam e (tests.marking_exam) holds the verified
-- home scripts ok, back, busy, gone and check, each with an open picture_changed alert, and other, with an open
-- name_visible and pages_changed alert. ok also has a closed picture_changed alert. Each script is then given what
-- holds its release back: back is taken back, busy has a remask queued, gone's page 2 has no marking picture, and
-- check's page 2 was confirmed by staff and its marking picture is not checked yet. The alerts are written directly,
-- as postgres.
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values
  ('admin', tests.create_user('admin', 'active')),
  ('lead', tests.create_user('corrector', 'active')),
  ('m1', tests.create_user('corrector', 'active'));
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create temp table res (name text primary key, j jsonb);
grant all on res to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
create function pg_temp.r(p text) returns jsonb language sql stable as $$ select j from res where name = p $$;
create function pg_temp.code(j jsonb) returns text language sql immutable as $$
  select case when (j ->> 'ok')::boolean then 'ok' else coalesce(j ->> 'code', 'none') end $$;
create function pg_temp.page(p_script text, p_n int) returns uuid language sql stable as $$
  select l.page_id from public.scripts s join public.script_page_links l on l.script_id = s.id and l.version = s.version
  where s.id = pg_temp.k(p_script) and l.copy_page = p_n $$;
-- The alert of list p about script p_script and kind p_kind.
create function pg_temp.item(p text, p_script text, p_kind text) returns jsonb language sql stable as $$
  select a from jsonb_array_elements(pg_temp.r(p) -> 'alerts') a
  where (a ->> 'script_id')::uuid = pg_temp.k(p_script) and a ->> 'kind' = p_kind and a ->> 'id' <> coalesce(pg_temp.k('closed')::text, '') $$;
-- 'can_release release_blocked' of that alert ('-' for null).
create function pg_temp.says(p text, p_script text, p_kind text) returns text language sql stable as $$
  select (pg_temp.item(p, p_script, p_kind) ->> 'can_release') || ' ' || coalesce(pg_temp.item(p, p_script, p_kind) ->> 'release_blocked', '-') $$;
-- What would give a candidate away: their first and last name, email, booking id and student id.
create function pg_temp.names(p_script text) returns text[] language sql stable as $$
  select array['Wilhelmina', 'Quarterfield', pr.email::text, b.id::text, b.student_id::text]
  from public.scripts s join public.bookings b on b.id = s.booking_id join public.profiles pr on pr.id = b.student_id
  where s.id = pg_temp.k(p_script) $$;
create function pg_temp.found_in(p_names text[], p_text text) returns text[] language sql immutable as $$
  select array(select x from unnest(p_names) x where position(lower(x) in lower(p_text)) > 0) $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.r(text), pg_temp.code(jsonb) to public;

insert into public.subjects (name, kind) values ('ZZ Alert reasons', 'school');
insert into public.marker_approvals (marker_id, subject_id, lead, approved_at)
select c.id, (select id from public.subjects where name = 'ZZ Alert reasons'), c.name = 'lead', now() from c where c.name in ('lead', 'm1');
insert into kv values ('e', tests.marking_exam((select id from public.subjects where name = 'ZZ Alert reasons')));
insert into kv select x, tests.verified_script(pg_temp.k('e'), 'home') from unnest(array['ok', 'back', 'busy', 'gone', 'check', 'other']) x;
insert into public.marking_alerts (exam_id, kind, script_id)
select pg_temp.k('e'), 'picture_changed', pg_temp.k(x) from unnest(array['ok', 'back', 'busy', 'gone', 'check']) x;
insert into public.marking_alerts (exam_id, kind, script_id, page_id)
values (pg_temp.k('e'), 'name_visible', pg_temp.k('other'), pg_temp.page('other', 2)),
       (pg_temp.k('e'), 'pages_changed', pg_temp.k('other'), null);
with a as (
  insert into public.marking_alerts (exam_id, kind, script_id, state, closed_by, closed_at, resolution, reason)
  values (pg_temp.k('e'), 'picture_changed', pg_temp.k('ok'), 'closed', pg_temp.uid('lead'), now(), 'released', 'Pictures checked')
  returning id)
insert into kv select 'closed', a.id from a;

update public.scripts set taken_back_at = now(), taken_back_by = pg_temp.uid('admin'), taken_back_reason = 'Look again' where id = pg_temp.k('back');
insert into public.processing_jobs (upload_id, kind, state, attempts, run_after)
select p.upload_id, 'remask', 'queued', 0, now() from public.script_pages p where p.id = pg_temp.page('busy', 1);
update public.script_pages set marking_path = null where id = pg_temp.page('gone', 2);
insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details, state, resolution, resolved_by, resolved_at)
select s.exam_id, 'poor_quality', s.booking_id, s.id, p.id, p.upload_id, '{"flags": ["layout_unexpected"]}'::jsonb,
  'resolved', 'confirmed', pg_temp.uid('admin'), now()
from public.scripts s join public.script_pages p on p.id = pg_temp.page('check', 2) where s.id = pg_temp.k('check');

select is(array(select coalesce(public.marking_alert_can_release(pg_temp.k(x)), '-') from unnest(array['ok', 'back', 'busy', 'gone', 'check']) x),
  array['-', 'taken_back', 'pictures_updating', 'picture_missing', 'picture_unchecked'],
  'fixture: each script is held back by one thing, as marking_alert_can_release says');

-- ---------------------------------------------------------------------------------------------
-- release_blocked_says_why_release_is_not_offered
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('admin', public.marking_alerts_list(pg_temp.k('e')));
insert into res values ('all', public.marking_alerts_list(pg_temp.k('e'), null));
select tests.as_postgres();
select tests.as_user(pg_temp.uid('lead'));
insert into res values ('lead', public.marking_alerts_list());
select tests.as_postgres();
select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.code(public.marking_alerts_list()), 'forbidden', 'a marker who leads no subject still sees no alerts');
select tests.as_postgres();

select is(array(select pg_temp.says('admin', x, 'picture_changed') from unnest(array['ok', 'back', 'busy', 'gone', 'check']) x),
  array['true -', 'false taken_back', 'false pictures_updating', 'false picture_missing', 'false picture_unchecked'],
  'release_blocked_says_why_release_is_not_offered: an admin''s list gives the reason beside can_release');
select is(array(select pg_temp.says('lead', x, 'picture_changed') from unnest(array['ok', 'back', 'busy', 'gone', 'check']) x),
  array['true -', 'false taken_back', 'false pictures_updating', 'false picture_missing', 'false picture_unchecked'],
  'and so does the lead''s');
select is((select count(*)::int from jsonb_array_elements(pg_temp.r('admin') -> 'alerts') a
           where a ->> 'kind' = 'picture_changed' and a ->> 'release_blocked' is distinct from public.marking_alert_can_release((a ->> 'script_id')::uuid)),
  0, 'for every open picture_changed alert it is what marking_alert_can_release answers');
select is((select count(*)::int from jsonb_array_elements(pg_temp.r('admin') -> 'alerts') a
           where (a ->> 'can_release')::boolean is distinct from (a ->> 'kind' = 'picture_changed' and a ->> 'release_blocked' is null)),
  0, 'Release is offered exactly where nothing holds it back');
select is(array[pg_temp.says('admin', 'other', 'name_visible'), pg_temp.says('admin', 'other', 'pages_changed')],
  array['false -', 'false -'], 'another kind of alert is never released, and has no reason (the kind says what happens)');
select is((select a ->> 'can_release' || ' ' || coalesce(a ->> 'release_blocked', '-') from jsonb_array_elements(pg_temp.r('all') -> 'alerts') a
           where (a ->> 'id')::uuid = pg_temp.k('closed')),
  'false -', 'nor does a closed alert');
select is((select count(*)::int from jsonb_array_elements(pg_temp.r('all') -> 'alerts') a where not (a ? 'release_blocked')), 0,
  'every alert carries the field, null where Release is offered or not the question');
select is(pg_temp.found_in(pg_temp.names('ok') || pg_temp.names('check') || pg_temp.names('other'), pg_temp.r('all')::text || pg_temp.r('lead')::text),
  '{}'::text[], 'no list names a candidate (first or last name, email, booking id, student id)');

-- Once staff check the picture, Release is offered.
update public.script_pages set marking_checked_path = marking_path, marking_checked_by = pg_temp.uid('admin'), marking_checked_at = now()
where id = pg_temp.page('check', 2);
select tests.as_user(pg_temp.uid('lead'));
insert into res values ('lead2', public.marking_alerts_list(pg_temp.k('e')));
select tests.as_postgres();
select is(pg_temp.says('lead2', 'check', 'picture_changed'), 'true -', 'once staff check the new picture, the reason goes and Release is offered');

-- ---------------------------------------------------------------------------------------------
-- Privileges: unchanged.
-- ---------------------------------------------------------------------------------------------
select is(array[has_function_privilege('anon', 'public.marking_alerts_list(uuid, text)', 'execute'),
                has_function_privilege('authenticated', 'public.marking_alerts_list(uuid, text)', 'execute')],
  array[false, true], 'the list is for signed-in users only');
select is((select array[p.prosecdef::text, array_to_string(p.proconfig, ',')] from pg_proc p where p.oid = 'public.marking_alerts_list(uuid, text)'::regprocedure),
  array['true', 'search_path=""'], 'it is security definer with an empty search path');

select * from finish();
rollback;
