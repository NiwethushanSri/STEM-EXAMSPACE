begin;
create extension if not exists pgtap with schema extensions;
select plan(17);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Final review I2 (and M9 for this list): the alerts list at the stated scale, and what it answers.
-- Fixtures. Subject 'ZZ Alerts scale': lead leads it. Exam e holds 300 verified home scripts of 16 pages, each with an
-- open picture_changed alert about its page 2 (a paper hidden-area change while they are marked raises exactly this).
-- Exam v ("variety") holds a few scripts, each held back by one thing, with an extra page and a refused page among
-- them, and alerts of other kinds. The alerts are written directly, as postgres.
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values
  ('admin', tests.create_user('admin', 'active')),
  ('lead', tests.create_user('corrector', 'active'));
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create temp table res (name text primary key, j jsonb);
grant all on res to public;
create temp table big (id uuid primary key);
grant select on big to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
create function pg_temp.r(p text) returns jsonb language sql stable as $$ select j from res where name = p $$;
create function pg_temp.page(p_script text, p_n int) returns uuid language sql stable as $$
  select l.page_id from public.scripts s join public.script_page_links l on l.script_id = s.id and l.version = s.version
  where s.id = pg_temp.k(p_script) and l.copy_page = p_n $$;
-- A call's answer, with its time in res (as 043).
create function pg_temp.timed(p_name text, p_sql text) returns jsonb language plpgsql as $$
declare
  v_t0 timestamptz := clock_timestamp();
  v jsonb;
begin
  execute p_sql into v;
  insert into res values (p_name, jsonb_build_object('ms', round(extract(epoch from clock_timestamp() - v_t0) * 1000)));
  return v;
end $$;
-- What the list answered before 20261122000014 for one alert: its page number from marking_script_pages, and
-- marking_alert_can_release once per alert. The new list must answer the same.
create function pg_temp.old_alert(p_alert uuid) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'id', a.id, 'kind', a.kind, 'exam_id', a.exam_id, 'exam_title', e.title, 'script_id', a.script_id,
    'script_number', s.number, 'index_number', d.index_number,
    'page_n', (select x.n from public.marking_script_pages(a.script_id) x where x.page_id = a.page_id),
    'unit_id', a.unit_id, 'created_at', a.created_at,
    'can_release', a.kind = 'picture_changed' and a.state = 'open' and public.marking_alert_can_release(a.script_id) is null,
    'release_blocked', case when a.kind = 'picture_changed' and a.state = 'open' then public.marking_alert_can_release(a.script_id) end)
  from public.marking_alerts a
  join public.exams e on e.id = a.exam_id
  join public.scripts s on s.id = a.script_id
  join public.bookings b on b.id = s.booking_id
  left join public.student_details d on d.profile_id = b.student_id
  where a.id = p_alert $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.r(text), pg_temp.timed(text, text) to public;

insert into public.subjects (name, kind) values ('ZZ Alerts scale', 'school');
insert into public.marker_approvals (marker_id, subject_id, lead, approved_at)
select pg_temp.uid('lead'), id, true, now() from public.subjects where name = 'ZZ Alerts scale';
insert into kv values ('e', tests.marking_exam((select id from public.subjects where name = 'ZZ Alerts scale'))),
                      ('v', tests.marking_exam((select id from public.subjects where name = 'ZZ Alerts scale')));

-- The variety exam first (its alerts are the oldest, so they are in every list).
insert into kv select x, tests.verified_script(pg_temp.k('v'), 'home', 5) from unnest(array['ok', 'back', 'busy', 'gone', 'check', 'other', 'refused']) x;
insert into public.marking_alerts (exam_id, kind, script_id, page_id, created_at)
select pg_temp.k('v'), 'picture_changed', pg_temp.k(x), pg_temp.page(x, 4), now() - interval '2 hours'
from unnest(array['ok', 'back', 'busy', 'gone', 'check', 'refused']) x;
insert into public.marking_alerts (exam_id, kind, script_id, page_id, created_at)
values (pg_temp.k('v'), 'name_visible', pg_temp.k('other'), pg_temp.page('other', 2), now() - interval '2 hours'),
       (pg_temp.k('v'), 'pages_changed', pg_temp.k('other'), null, now() - interval '2 hours'),
       (pg_temp.k('v'), 'pages_changed', pg_temp.k('ok'), null, now() - interval '2 hours');
insert into public.marking_alerts (exam_id, kind, script_id, page_id, state, closed_by, closed_at, resolution, reason, created_at)
values (pg_temp.k('v'), 'picture_changed', pg_temp.k('ok'), pg_temp.page('ok', 5), 'closed', pg_temp.uid('lead'), now(), 'released', 'Pictures checked', now() - interval '3 hours');
update public.scripts set taken_back_at = now(), taken_back_by = pg_temp.uid('admin'), taken_back_reason = 'Look again' where id = pg_temp.k('back');
insert into public.processing_jobs (upload_id, kind, state, attempts, run_after)
select p.upload_id, 'remask', 'queued', 0, now() from public.script_pages p where p.id = pg_temp.page('busy', 1);
update public.script_pages set marking_path = null where id = pg_temp.page('gone', 2);
insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details, state, resolution, resolved_by, resolved_at)
select s.exam_id, 'poor_quality', s.booking_id, s.id, p.id, p.upload_id, '{"flags": ["layout_unexpected"]}'::jsonb,
  'resolved', 'confirmed', pg_temp.uid('admin'), now()
from public.scripts s join public.script_pages p on p.id = pg_temp.page('check', 2) where s.id = pg_temp.k('check');
-- 'refused' shows no page 2 (staff refused it), so its page 4 is the third page a marker sees.
insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, details, state, resolution, resolved_by, resolved_at)
select s.exam_id, 'poor_quality', s.booking_id, s.id, p.id, p.upload_id, '{"flags": ["blurred"]}'::jsonb,
  'resolved', 'rejected', pg_temp.uid('admin'), now()
from public.scripts s join public.script_pages p on p.id = pg_temp.page('refused', 2) where s.id = pg_temp.k('refused');

-- The 300 scripts of 16 pages and their alerts.
insert into big select tests.verified_script(pg_temp.k('e'), 'home', 16) from generate_series(1, 300);
insert into public.marking_alerts (exam_id, kind, script_id, page_id)
select pg_temp.k('e'), 'picture_changed', b.id,
  (select l.page_id from public.script_page_links l where l.script_id = b.id and l.copy_page = 2)
from big b;
select is((select count(*)::int from public.marking_alerts a where a.exam_id = pg_temp.k('e') and a.state = 'open'), 300,
  'fixture: 300 open picture_changed alerts on 16-page scripts');
select is((select count(*)::int from big b cross join lateral public.marking_script_pages(b.id) x), 4800, 'fixture: each of those scripts shows 16 pages');

-- ---------------------------------------------------------------------------------------------
-- pages_of_many_scripts_agree_with_pages_of_one: the rule for many scripts at once is the rule for one script.
-- ---------------------------------------------------------------------------------------------
select is((select count(*)::int from (
             (select s.id, x.n, x.page_id, x.copy_page, x.extra, x.marking_path, x.rotation
              from public.scripts s cross join lateral public.marking_script_pages(s.id) x
              where s.exam_id in (pg_temp.k('e'), pg_temp.k('v'))
              except all
              select x.script_id, x.n, x.page_id, x.copy_page, x.extra, x.marking_path, x.rotation
              from public.marking_scripts_pages(array(select s.id from public.scripts s where s.exam_id in (pg_temp.k('e'), pg_temp.k('v')))) x)
             union all
             (select x.script_id, x.n, x.page_id, x.copy_page, x.extra, x.marking_path, x.rotation
              from public.marking_scripts_pages(array(select s.id from public.scripts s where s.exam_id in (pg_temp.k('e'), pg_temp.k('v')))) x
              except all
              select s.id, x.n, x.page_id, x.copy_page, x.extra, x.marking_path, x.rotation
              from public.scripts s cross join lateral public.marking_script_pages(s.id) x
              where s.exam_id in (pg_temp.k('e'), pg_temp.k('v')))) d), 0,
  'pages_of_many_scripts_agree_with_pages_of_one: marking_scripts_pages gives every script the rows marking_script_pages gives it');
select is((select count(*)::int from public.marking_scripts_pages(array[pg_temp.k('refused'), pg_temp.k('refused'), gen_random_uuid(), null]::uuid[])), 4,
  'a script named twice is read once (the refused page left out), an unknown one and a null give nothing');
select is((select array_agg(x.n order by x.n) from public.marking_scripts_pages(array[pg_temp.k('refused')]) x), array[1, 2, 3, 4], 'and its pages are numbered from 1');

-- ---------------------------------------------------------------------------------------------
-- alerts_list_in_time_at_300_alerts (a timing guard, as 037 and 043). Each timed call runs under the statement_timeout
-- it must meet: a call over it fails this file.
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('lead'));
set local statement_timeout = '2s';
insert into res values ('lead', pg_temp.timed('ms_lead', 'select public.marking_alerts_list()'));
reset statement_timeout;
select tests.as_postgres();
select tests.as_user(pg_temp.uid('admin'));
set local statement_timeout = '2s';
insert into res values ('admin', pg_temp.timed('ms_admin', format('select public.marking_alerts_list(%L)', pg_temp.k('e'))));
reset statement_timeout;
insert into res values ('admin_all', public.marking_alerts_list(null, null));
select tests.as_postgres();
select is(array[jsonb_array_length(pg_temp.r('lead') -> 'alerts'), jsonb_array_length(pg_temp.r('admin') -> 'alerts')], array[309, 300],
  'alerts_list_in_time_at_300_alerts: the lead''s list of every open alert and the admin''s list of the exam''s 300 each come within 2 s');
select is((select count(*)::int from jsonb_array_elements(pg_temp.r('admin') -> 'alerts') a
           where (a ->> 'can_release')::boolean and a ->> 'release_blocked' is null and (a ->> 'page_n')::int = 2), 300,
  'each of the 300 may be released and names page 2');

-- ---------------------------------------------------------------------------------------------
-- alerts_list_answers_as_before: the same fields and values as the list of 20261122000011.
-- ---------------------------------------------------------------------------------------------
select is((select count(*)::int from jsonb_array_elements(pg_temp.r('admin_all') -> 'alerts') a
           where a is distinct from pg_temp.old_alert((a ->> 'id')::uuid)), 0,
  'alerts_list_answers_as_before: every alert of the full list (open and closed, every kind) is what the earlier list answered');
select is(jsonb_array_length(pg_temp.r('admin_all') -> 'alerts'), 310, 'the full list holds all 310 alerts');
select is((select count(*)::int from jsonb_array_elements(pg_temp.r('lead') -> 'alerts') a
           where a is distinct from pg_temp.old_alert((a ->> 'id')::uuid)), 0, 'and so is every alert of the lead''s list');
select is((select array_agg((a ->> 'can_release') || ' ' || coalesce(a ->> 'release_blocked', '-') || ' ' || coalesce(a ->> 'page_n', '-') order by x.o)
           from unnest(array['ok', 'back', 'busy', 'gone', 'check', 'refused']) with ordinality x(name, o)
           join jsonb_array_elements(pg_temp.r('lead') -> 'alerts') a on (a ->> 'script_id')::uuid = pg_temp.k(x.name) and a ->> 'kind' = 'picture_changed'),
  array['true - 4', 'false taken_back 4', 'false pictures_updating 4', 'false picture_missing 4', 'false picture_unchecked 4', 'true - 3'],
  'each reason, once per script, with the page''s number among the pages a marker sees');
select is((select array_agg((a ->> 'kind') || ' ' || (a ->> 'can_release') || ' ' || coalesce(a ->> 'release_blocked', '-') || ' ' || coalesce(a ->> 'page_n', '-') order by a ->> 'kind', a ->> 'script_id' = pg_temp.k('ok')::text)
           from jsonb_array_elements(pg_temp.r('admin_all') -> 'alerts') a
           where a ->> 'kind' <> 'picture_changed' or (a ->> 'page_n')::int = 5),
  array['name_visible false - 2', 'pages_changed false - -', 'pages_changed false - -', 'picture_changed false - 5'],
  'another kind and a closed alert are never released; a script with two alerts answers each');
select is((select array_agg(a ->> 'id' order by o) from jsonb_array_elements(pg_temp.r('admin_all') -> 'alerts') with ordinality t(a, o)),
  (select array_agg(a.id::text order by a.created_at, a.id) from public.marking_alerts a where a.exam_id in (pg_temp.k('e'), pg_temp.k('v'))),
  'oldest first, as before');

-- ---------------------------------------------------------------------------------------------
-- alerts_list_says_when_there_are_more (M9): at most 500, and a more flag.
-- ---------------------------------------------------------------------------------------------
select is(array[pg_temp.r('lead') ->> 'more', pg_temp.r('admin') ->> 'more', pg_temp.r('admin_all') ->> 'more'], array['false', 'false', 'false'],
  'alerts_list_says_when_there_are_more: with 500 or fewer, more is false');
insert into public.marking_alerts (exam_id, kind, script_id, created_at)
select pg_temp.k('e'), 'pages_changed', b.id, now() + interval '1 hour' from big b limit 200;
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('admin_more', public.marking_alerts_list(pg_temp.k('e')));
select tests.as_postgres();
select is(array[jsonb_array_length(pg_temp.r('admin_more') -> 'alerts')::text, pg_temp.r('admin_more') ->> 'more'], array['500', 'false'],
  'exactly 500: all are listed and more is false');
insert into public.marking_alerts (exam_id, kind, script_id, created_at)
select pg_temp.k('e'), 'pages_set_aside', b.id, now() + interval '2 hours' from big b limit 1;
select tests.as_user(pg_temp.uid('admin'));
insert into res values ('admin_more2', public.marking_alerts_list(pg_temp.k('e')));
select tests.as_postgres();
select is(array[jsonb_array_length(pg_temp.r('admin_more2') -> 'alerts')::text, pg_temp.r('admin_more2') ->> 'more',
                (pg_temp.r('admin_more2') -> 'alerts' -> 499 ->> 'kind')],
  array['500', 'true', 'pages_changed'], '501: the oldest 500 are listed and more is true');

select is((select array[has_function_privilege('authenticated', 'public.marking_scripts_pages(uuid[])', 'execute'),
                        has_function_privilege('service_role', 'public.marking_scripts_pages(uuid[])', 'execute'),
                        has_function_privilege('anon', 'public.marking_alerts_list(uuid, text)', 'execute'),
                        has_function_privilege('authenticated', 'public.marking_alerts_list(uuid, text)', 'execute')]),
  array[false, false, false, true], 'the pages of many scripts are internal; the list is for signed-in users only');

select * from finish();
rollback;
