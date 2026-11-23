begin;
create extension if not exists pgtap with schema extensions;
select plan(46);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Subject 'ZZ Picture links': correctors m1 and m2 and the lead marker are approved for it; corr is never
-- approved. Exam e (tests.marking_exam, finished 2 days ago, the test structure) has the home scripts a1 (m1 holds it
-- by Next script and has opened it), a2 (m2 holds it, opened) and b1 (m1 holds it, never opened); exam ec has c1 (m1
-- holds it, opened). A unit is kept as 'u:<script>'; a page as 'p:<script>:<copy page>'.
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values
  ('admin', tests.create_user('admin', 'active')),
  ('m1', tests.create_user('corrector', 'active')),
  ('m2', tests.create_user('corrector', 'active')),
  ('lead', tests.create_user('corrector', 'active')),
  ('corr', tests.create_user('corrector', 'active'));
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create temp table res (name text primary key, j jsonb);
grant all on res to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
create function pg_temp.u(p text) returns uuid language sql stable as $$ select id from kv where name = 'u:' || p $$;
create function pg_temp.r(p text) returns jsonb language sql stable as $$ select j from res where name = p $$;
create function pg_temp.subj() returns bigint language sql stable as $$ select id from public.subjects where name = 'ZZ Picture links' $$;
create function pg_temp.code(j jsonb) returns text language sql immutable as $$
  select case when (j ->> 'ok')::boolean then 'ok' else coalesce(j ->> 'code', 'none') end $$;
-- A script's pages, in copy page order, and their marking or full pictures (read as postgres).
create function pg_temp.pages(p_script text) returns uuid[] language sql stable security definer as $$
  select coalesce(array_agg(l.page_id order by l.copy_page), '{}')
  from public.scripts s join public.script_page_links l on l.script_id = s.id and l.version = s.version where s.id = pg_temp.k(p_script) $$;
create function pg_temp.paths(p_script text, p_kind text) returns text[] language sql stable security definer as $$
  select coalesce(array_agg(case when p_kind = 'full' then p.full_path else p.marking_path end order by l.copy_page), '{}')
  from public.scripts s join public.script_page_links l on l.script_id = s.id and l.version = s.version
  join public.script_pages p on p.id = l.page_id where s.id = pg_temp.k(p_script) $$;
-- The paths an answer of marking_picture_paths gives, in its order.
create function pg_temp.given(j jsonb) returns text[] language sql immutable as $$
  select coalesce(array_agg(x ->> 'marking_path' order by o), '{}') from jsonb_array_elements(j -> 'paths') with ordinality t(x, o) $$;
-- How many of these pictures the caller reads straight from storage.
create function pg_temp.seen(p_names text[]) returns int language sql stable as $$
  select count(*)::int from storage.objects where bucket_id = 'script-pages' and name = any (p_names) $$;
create function pg_temp.put(p_names text[]) returns void language sql as $$
  insert into storage.objects (bucket_id, name) select 'script-pages', n from unnest(p_names) n on conflict do nothing $$;
create function pg_temp.script(p_name text, p_exam text) returns void language plpgsql as $$
begin
  insert into kv values (p_name, tests.verified_script(pg_temp.k(p_exam), 'home'));
  insert into kv select 'p:' || p_name || ':' || l.copy_page, l.page_id
  from public.scripts s join public.script_page_links l on l.script_id = s.id and l.version = s.version where s.id = pg_temp.k(p_name);
end $$;
-- Opens an exam's marking (as marking_open would), makes its verified scripts ready, and keeps their units.
create function pg_temp.open(p text) returns void language plpgsql as $$
begin
  insert into public.exam_marking (exam_id, opened_at, opened_by) values (pg_temp.k(p), now(), pg_temp.uid('admin'))
  on conflict (exam_id) do update set opened_at = excluded.opened_at, closed_at = null;
  perform public.marking_exam_sync(pg_temp.k(p), null);
  insert into kv select 'u:' || x.name, u.id from kv x join public.marking_units u on u.script_id = x.id on conflict (name) do nothing;
end $$;
create function pg_temp.take(p text, p_marker text) returns void language sql as $$
  select public.marking_unit_take(pg_temp.u(p), pg_temp.uid(p_marker), 'next', null, now() + interval '2 hours') $$;
create function pg_temp.hold(p text) returns text language sql stable as $$
  select case when on_hold then coalesce(hold_reason, '?') else '-' end from public.marking_units where id = pg_temp.u(p) $$;
create function pg_temp.alert(p text, p_kind text) returns uuid language sql stable security definer as $$
  select a.id from public.marking_alerts a where a.script_id = pg_temp.k(p) and a.kind = p_kind order by a.created_at desc limit 1 $$;
create function pg_temp.student(p text) returns uuid language sql stable as $$
  select b.student_id from public.scripts s join public.bookings b on b.id = s.booking_id where s.id = pg_temp.k(p) $$;
create function pg_temp.upload(p text) returns uuid language sql stable as $$
  select pg.upload_id from public.script_pages pg where pg.id = pg_temp.k('p:' || p || ':1') $$;
-- What would give a candidate away: their first and last name, email, booking id and student id.
create function pg_temp.names(p_script text) returns text[] language sql stable as $$
  select array['Wilhelmina', 'Quarterfield', (select pr.email::text from public.profiles pr where pr.id = pg_temp.student(p_script)),
               (select s.booking_id::text from public.scripts s where s.id = pg_temp.k(p_script)), pg_temp.student(p_script)::text] $$;
create function pg_temp.found_in(p_names text[], p_text text) returns text[] language sql immutable as $$
  select array(select x from unnest(p_names) x where position(lower(x) in lower(p_text)) > 0) $$;
-- What a page's picture hides changes: one more staff hidden area on it; its remask is taken as done.
create function pg_temp.area(p_page text) returns void language plpgsql as $$
begin
  insert into public.script_page_hidden_areas (page_id, x, y, w, h, created_by)
  select pg_temp.k(p_page), 0.05 + 0.1 * count(*), 0.02, 0.05, 0.05, pg_temp.uid('admin')
  from public.script_page_hidden_areas a where a.page_id = pg_temp.k(p_page);
  update public.processing_jobs j set state = 'done', finished_at = now()
  where j.kind = 'remask' and j.state in ('queued', 'running')
    and j.upload_id = (select p.upload_id from public.script_pages p where p.id = pg_temp.k(p_page));
end $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.u(text), pg_temp.r(text), pg_temp.code(jsonb),
  pg_temp.pages(text), pg_temp.paths(text, text), pg_temp.given(jsonb), pg_temp.seen(text[]), pg_temp.alert(text, text) to public;

insert into public.subjects (name, kind) values ('ZZ Picture links', 'school');
insert into public.marker_approvals (marker_id, subject_id, lead, approved_at)
select c.id, pg_temp.subj(), c.name = 'lead', now() from c where c.name in ('m1', 'm2', 'lead');

insert into kv values ('e', tests.marking_exam(pg_temp.subj())), ('ec', tests.marking_exam(pg_temp.subj()));
select tests.structure(pg_temp.k('e'));
select tests.structure(pg_temp.k('ec'));
select pg_temp.script('a1', 'e');
select pg_temp.script('a2', 'e');
select pg_temp.script('b1', 'e');
select pg_temp.script('c1', 'ec');
select pg_temp.open('e');
select pg_temp.open('ec');
select pg_temp.take('a1', 'm1');
select pg_temp.take('a2', 'm2');
select pg_temp.take('b1', 'm1');
select pg_temp.take('c1', 'm1');
select tests.as_user(pg_temp.uid('m1'));
select public.marking_unit_open(pg_temp.u('a1'));
select public.marking_unit_open(pg_temp.u('c1'));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m2'));
select public.marking_unit_open(pg_temp.u('a2'));
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- holder_gets_paths_only_for_pages_of_the_piece
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('h1', public.marking_picture_paths(pg_temp.u('a1'), pg_temp.pages('a1')));
insert into res values ('h_mixed', public.marking_picture_paths(pg_temp.u('a1'), pg_temp.pages('a1') || pg_temp.k('p:a2:1')));
insert into res values ('h_other', public.marking_picture_paths(pg_temp.u('a2'), pg_temp.pages('a2')));
insert into res values ('h_one', public.marking_picture_paths(pg_temp.u('a1'), array[pg_temp.k('p:a1:3'), pg_temp.k('p:a1:1')]));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m2'));
insert into res values ('h_m2', public.marking_picture_paths(pg_temp.u('a1'), pg_temp.pages('a1')));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('corr'));
insert into res values ('h_corr', public.marking_picture_paths(pg_temp.u('a1'), pg_temp.pages('a1')));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
insert into res values ('h_admin', public.marking_picture_paths(pg_temp.u('a1'), pg_temp.pages('a1')));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('h1'))] || pg_temp.given(pg_temp.r('h1')), array['ok'] || pg_temp.paths('a1', 'marking'),
  'holder_gets_paths_only_for_pages_of_the_piece: the holder gets the marking picture of each page of the piece, in page order');
select is((select array_agg((x ->> 'page_id')::uuid order by o) from jsonb_array_elements(pg_temp.r('h1') -> 'paths') with ordinality t(x, o)),
  pg_temp.pages('a1'), 'each with its page');
select is(pg_temp.given(pg_temp.r('h_one')), array[(pg_temp.paths('a1', 'marking'))[3], (pg_temp.paths('a1', 'marking'))[1]],
  'in the order they were asked for');
select is(pg_temp.r('h_mixed'), '{"ok": false, "code": "forbidden"}'::jsonb,
  'a page of another script in the list refuses the whole call, with no path');
select is(array[pg_temp.code(pg_temp.r('h_other')), pg_temp.code(pg_temp.r('h_m2')), pg_temp.code(pg_temp.r('h_corr'))],
  array['forbidden', 'forbidden', 'forbidden'], 'a marker gets none of another marker''s piece, nor does a corrector who is not approved');
select is(array[pg_temp.code(pg_temp.r('h_admin'))] || pg_temp.given(pg_temp.r('h_admin')), array['ok'] || pg_temp.paths('a1', 'marking'),
  'an admin gets them');

-- ---------------------------------------------------------------------------------------------
-- full_picture_path_is_never_returned
-- ---------------------------------------------------------------------------------------------
select is(pg_temp.found_in(pg_temp.paths('a1', 'full') || array['-full.jpg'], pg_temp.r('h1')::text || pg_temp.r('h_admin')::text), '{}'::text[],
  'full_picture_path_is_never_returned: no answer holds a full picture');
-- A page whose marking picture would be its full picture (never made so, but the rule holds).
insert into res select 'kept_path', to_jsonb(marking_path) from public.script_pages where id = pg_temp.k('p:a1:2');
update public.script_pages set marking_path = full_path where id = pg_temp.k('p:a1:2');
select is(pg_temp.hold('a1'), '-', 'the piece is not held: what the picture hides is the same');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('full_m1', public.marking_picture_paths(pg_temp.u('a1'), array[pg_temp.k('p:a1:2')]));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
insert into res values ('full_admin', public.marking_picture_paths(pg_temp.u('a1'), pg_temp.pages('a1')));
select tests.as_postgres();
select is(array[pg_temp.r('full_m1'), pg_temp.r('full_admin')], array['{"ok": false, "code": "forbidden"}', '{"ok": false, "code": "forbidden"}']::jsonb[],
  'such a page is refused, to the holder and to an admin');
update public.script_pages set marking_path = pg_temp.r('kept_path') #>> '{}' where id = pg_temp.k('p:a1:2');

-- ---------------------------------------------------------------------------------------------
-- no_paths_while_on_hold_or_pictures_updating
-- ---------------------------------------------------------------------------------------------
update public.marking_units set on_hold = true, hold_reason = 'picture_changed' where id = pg_temp.u('a1');
select tests.as_user(pg_temp.uid('m1'));
select is(public.marking_picture_paths(pg_temp.u('a1'), pg_temp.pages('a1')), '{"ok": false, "code": "on_hold"}'::jsonb,
  'no_paths_while_on_hold_or_pictures_updating: none while the piece is on hold');
select tests.as_postgres();
update public.marking_units set on_hold = false, hold_reason = null where id = pg_temp.u('a1');
insert into public.processing_jobs (upload_id, kind, state) values (pg_temp.upload('a1'), 'remask', 'queued');
select tests.as_user(pg_temp.uid('m1'));
select is(public.marking_picture_paths(pg_temp.u('a1'), pg_temp.pages('a1')), '{"ok": false, "code": "pictures_updating"}'::jsonb,
  'none while a file of its pages is being remasked');
select tests.as_postgres();
update public.processing_jobs set state = 'done', finished_at = now() where upload_id = pg_temp.upload('a1') and kind = 'remask';
select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.code(public.marking_picture_paths(pg_temp.u('a1'), pg_temp.pages('a1'))), 'ok', 'once it is done, they are given again');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- no_paths_after_hold_expired_take_back_or_close
-- ---------------------------------------------------------------------------------------------
update public.marking_assignments set hold_until = now() - interval '1 minute' where unit_id = pg_temp.u('a1') and ended_at is null;
select tests.as_user(pg_temp.uid('m1'));
select is(public.marking_picture_paths(pg_temp.u('a1'), pg_temp.pages('a1')), '{"ok": false, "code": "hold_expired"}'::jsonb,
  'no_paths_after_hold_expired_take_back_or_close: none once the hold has run out');
insert into res values ('b1_before', public.marking_picture_paths(pg_temp.u('b1'), pg_temp.pages('b1')));
select tests.as_postgres();
update public.marking_assignments set hold_until = now() + interval '1 hour' where unit_id = pg_temp.u('a1') and ended_at is null;
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_take_back(array[pg_temp.u('b1')], 'Another marker will take it')), 'ok', 'an admin takes b1 back from m1');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m1'));
select is(array[pg_temp.code(pg_temp.r('b1_before')), pg_temp.code(public.marking_picture_paths(pg_temp.u('b1'), pg_temp.pages('b1')))],
  array['ok', 'forbidden'], 'a piece m1 held (not opened yet) gives its paths, and none once it is taken back');
select tests.as_postgres();
update public.exam_marking set closed_at = now() where exam_id = pg_temp.k('ec');
select tests.as_user(pg_temp.uid('m1'));
select is(public.marking_picture_paths(pg_temp.u('c1'), pg_temp.pages('c1')), '{"ok": false, "code": "marking_closed"}'::jsonb,
  'none once marking has closed');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('lead'));
select is(pg_temp.code(public.marking_picture_paths(pg_temp.u('c1'), pg_temp.pages('c1'))), 'forbidden', 'nor to the lead');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- marker_reads_nothing_from_storage_directly
-- ---------------------------------------------------------------------------------------------
select pg_temp.put(pg_temp.paths('a1', 'marking') || pg_temp.paths('a1', 'full'));
select tests.as_user(pg_temp.uid('m1'));
select is(array[pg_temp.seen(pg_temp.paths('a1', 'marking')), cardinality(pg_temp.given(public.marking_picture_paths(pg_temp.u('a1'), pg_temp.pages('a1'))))],
  array[0, 3], 'marker_reads_nothing_from_storage_directly: the holder reads none of their own piece''s marking pictures from storage, though the function gives them');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('lead'));
select is(pg_temp.seen(pg_temp.paths('a1', 'marking')), 0, 'nor does the lead');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.seen(pg_temp.paths('a1', 'marking') || pg_temp.paths('a1', 'full')), 6, 'staff still read every picture (their policy is kept)');
select tests.as_postgres();
select is((select array_agg(p.policyname::text order by p.policyname) from pg_policies p
           where p.schemaname = 'storage' and p.tablename = 'objects' and p.policyname like 'script_pages_objects%'),
  array['script_pages_objects_select'], 'the only policy on script-pages is the staff one (Ruling R12)');
select is(to_regprocedure('public.marking_picture_allowed(text)'), null, 'and marking_picture_allowed is gone');

-- ---------------------------------------------------------------------------------------------
-- more_than_40_pages_refused
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('m2'));
insert into res values ('p41', public.marking_picture_paths(pg_temp.u('a2'), array(select pg_temp.k('p:a2:1') from generate_series(1, 41))));
insert into res values ('p40', public.marking_picture_paths(pg_temp.u('a2'),
  array(select (pg_temp.pages('a2'))[1 + g % 3] from generate_series(0, 39) g)));
select tests.as_postgres();
select is(pg_temp.r('p41'), '{"ok": false, "code": "invalid_input"}'::jsonb, 'more_than_40_pages_refused: 41 pages are refused');
select is(array[pg_temp.code(pg_temp.r('p40')), cardinality(pg_temp.given(pg_temp.r('p40')))::text], array['ok', '3'],
  '40 are not (a page asked for twice is given once)');
select tests.as_user(pg_temp.uid('m2'));
select is(array[pg_temp.code(public.marking_picture_paths(pg_temp.u('a2'), '{}')), pg_temp.code(public.marking_picture_paths(pg_temp.u('a2'), null)),
                pg_temp.code(public.marking_picture_paths(null, pg_temp.pages('a2'))),
                pg_temp.code(public.marking_picture_paths(pg_temp.u('a2'), array[pg_temp.k('p:a2:1'), null])),
                pg_temp.code(public.marking_picture_paths(gen_random_uuid(), pg_temp.pages('a2')))],
  array['invalid_input', 'invalid_input', 'invalid_input', 'invalid_input', 'not_found'],
  'no page, no list, no piece or an empty page id is invalid_input; an unknown piece is not_found');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- unit_open_sends_no_path: page 3 of a2 was replaced by a rerun, so it has no current marking picture.
-- ---------------------------------------------------------------------------------------------
update public.script_pages set replaced_at = now() where id = pg_temp.k('p:a2:3');
select tests.as_user(pg_temp.uid('m2'));
insert into res values ('open_a2', public.marking_unit_open(pg_temp.u('a2')));
insert into res values ('replaced_a2', public.marking_picture_paths(pg_temp.u('a2'), array[pg_temp.k('p:a2:3')]));
select tests.as_postgres();
update public.script_pages set replaced_at = null where id = pg_temp.k('p:a2:3');
select is(pg_temp.code(pg_temp.r('open_a2')), 'ok', 'unit_open_sends_no_path: m2 opens a2');
select is(array[position('marking_path' in pg_temp.r('open_a2')::text), position('-marking.jpg' in pg_temp.r('open_a2')::text),
                position('-full.jpg' in pg_temp.r('open_a2')::text)],
  array[0, 0, 0], 'the answer holds no marking_path and no picture''s path');
select is((select array_agg(jsonb_build_array(p -> 'n', p -> 'page_id', p -> 'has_picture') order by (p ->> 'n')::int)
           from jsonb_array_elements(pg_temp.r('open_a2') -> 'pages') p),
  array[jsonb_build_array(1, pg_temp.k('p:a2:1'), true), jsonb_build_array(2, pg_temp.k('p:a2:2'), true), jsonb_build_array(3, pg_temp.k('p:a2:3'), false)],
  'each page says whether it has a marking picture');
select is((select array_agg(distinct k order by k) from jsonb_array_elements(pg_temp.r('open_a2') -> 'pages') p, jsonb_object_keys(p) k),
  array['copy_page', 'extra', 'has_picture', 'n', 'page_id', 'rotation'], 'and nothing more');
select is(pg_temp.r('replaced_a2'), '{"ok": false, "code": "forbidden"}'::jsonb, 'a page with no current marking picture is refused');

-- ---------------------------------------------------------------------------------------------
-- lead_without_an_open_alert_is_refused
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('lead'));
select is(array[pg_temp.code(public.marking_picture_paths(pg_temp.u('a1'), pg_temp.pages('a1'))),
                pg_temp.code(public.marking_picture_paths(pg_temp.u('a2'), pg_temp.pages('a2')))],
  array['forbidden', 'forbidden'], 'lead_without_an_open_alert_is_refused: the lead gets nothing of a script with no open alert');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- lead_gets_paths_for_a_held_script_with_an_open_alert: a1's page 2 is masked again to hide something more.
-- ---------------------------------------------------------------------------------------------
select pg_temp.area('p:a1:2');
update public.script_pages set marking_path = replace(marking_path, '-marking.jpg', '-remask-marking.jpg') where id = pg_temp.k('p:a1:2');
select is(array[pg_temp.hold('a1'), (pg_temp.alert('a1', 'picture_changed') is not null)::text], array['picture_changed', 'true'],
  'lead_gets_paths_for_a_held_script_with_an_open_alert: a1 is on hold with an open picture_changed alert');
select tests.as_user(pg_temp.uid('lead'));
insert into res values ('lead_a1', public.marking_picture_paths(pg_temp.u('a1'), pg_temp.pages('a1')));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m1'));
insert into res values ('held_m1', public.marking_picture_paths(pg_temp.u('a1'), pg_temp.pages('a1')));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m2'));
insert into res values ('held_m2', public.marking_picture_paths(pg_temp.u('a1'), pg_temp.pages('a1')));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('lead_a1'))] || pg_temp.given(pg_temp.r('lead_a1')), array['ok'] || pg_temp.paths('a1', 'marking'),
  'the lead gets the script''s marking pictures, the new one with them');
select ok((pg_temp.given(pg_temp.r('lead_a1')))[2] like '%-remask-marking.jpg', 'page 2''s is its new picture');
select is(array[pg_temp.code(pg_temp.r('held_m1')), pg_temp.code(pg_temp.r('held_m2'))], array['on_hold', 'forbidden'],
  'the marker holding it gets none while it is on hold, nor does another marker');
-- An open name_visible exception on a page keeps that page from the lead.
insert into public.script_exceptions (exam_id, kind, script_id, page_id, state)
values (pg_temp.k('e'), 'name_visible', pg_temp.k('a1'), pg_temp.k('p:a1:1'), 'open');
select tests.as_user(pg_temp.uid('lead'));
select is(array[pg_temp.code(public.marking_picture_paths(pg_temp.u('a1'), array[pg_temp.k('p:a1:1')])),
                pg_temp.code(public.marking_picture_paths(pg_temp.u('a1'), pg_temp.pages('a1'))),
                pg_temp.code(public.marking_picture_paths(pg_temp.u('a1'), array[pg_temp.k('p:a1:2'), pg_temp.k('p:a1:3')]))],
  array['forbidden', 'forbidden', 'ok'], 'a page with an open name_visible exception is not given to the lead; the others are');
select tests.as_postgres();
delete from public.script_exceptions where script_id = pg_temp.k('a1') and kind = 'name_visible';

-- ---------------------------------------------------------------------------------------------
-- blocked_lead_is_refused
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('lead'));
insert into res values ('list_free', public.marking_alerts_list(pg_temp.k('e')));
select tests.as_postgres();
insert into public.marker_conflicts (marker_id, student_id, recorded_at) values (pg_temp.uid('lead'), pg_temp.student('a1'), now());
select tests.as_user(pg_temp.uid('lead'));
insert into res values ('blocked_paths', public.marking_picture_paths(pg_temp.u('a1'), pg_temp.pages('a1')));
insert into res values ('blocked_pages', public.marking_alert_pages(pg_temp.alert('a1', 'picture_changed')));
insert into res values ('list_blocked', public.marking_alerts_list(pg_temp.k('e')));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
insert into res values ('list_admin', public.marking_alerts_list(pg_temp.k('e')));
select tests.as_postgres();
create function pg_temp.release_line(p_list text) returns text language sql stable as $$
  select (a ->> 'can_release') || ' ' || coalesce(a ->> 'release_blocked', '-')
  from jsonb_array_elements(pg_temp.r(p_list) -> 'alerts') a where (a ->> 'id')::uuid = pg_temp.alert('a1', 'picture_changed') $$;
select is(array[pg_temp.r('blocked_paths'), pg_temp.r('blocked_pages')],
  array['{"ok": false, "code": "forbidden"}', '{"ok": false, "code": "conflict_of_interest"}']::jsonb[],
  'blocked_lead_is_refused: a lead with a declared conflict for the candidate gets no path, and the alert''s pages say conflict_of_interest');
select is(array[pg_temp.release_line('list_blocked'), pg_temp.release_line('list_free'), pg_temp.release_line('list_admin')],
  array['false conflict_of_interest', 'true -', 'true -'],
  'their alerts list does not offer Release and says why (the conflict); before the conflict, and to an admin, it is offered');
delete from public.marker_conflicts where marker_id = pg_temp.uid('lead');

-- ---------------------------------------------------------------------------------------------
-- alert_pages_marks_the_changed_page_and_has_no_name
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('lead'));
insert into res values ('pages_lead', public.marking_alert_pages(pg_temp.alert('a1', 'picture_changed')));
insert into res values ('pages_unknown_lead', public.marking_alert_pages(gen_random_uuid()));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
insert into res values ('pages_admin', public.marking_alert_pages(pg_temp.alert('a1', 'picture_changed')));
insert into res values ('pages_unknown_admin', public.marking_alert_pages(gen_random_uuid()));
insert into res values ('pages_null', public.marking_alert_pages(null));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m1'));
insert into res values ('pages_m1', public.marking_alert_pages(pg_temp.alert('a1', 'picture_changed')));
select tests.as_postgres();
select is(pg_temp.r('pages_lead'),
  (select jsonb_build_object('ok', true, 'unit_id', pg_temp.u('a1'), 'script_number', s.number, 'index_number', d.index_number,
     'pages', jsonb_build_array(
       jsonb_build_object('n', 1, 'page_id', pg_temp.k('p:a1:1'), 'copy_page', 1, 'changed', false, 'has_picture', true),
       jsonb_build_object('n', 2, 'page_id', pg_temp.k('p:a1:2'), 'copy_page', 2, 'changed', true, 'has_picture', true),
       jsonb_build_object('n', 3, 'page_id', pg_temp.k('p:a1:3'), 'copy_page', 3, 'changed', false, 'has_picture', true)))
   from public.scripts s join public.bookings b on b.id = s.booking_id join public.student_details d on d.profile_id = b.student_id
   where s.id = pg_temp.k('a1')),
  'alert_pages_marks_the_changed_page_and_has_no_name: the lead gets the script''s pages, page 2 marked as changed, and a piece to ask for links with');
select is(pg_temp.found_in(pg_temp.names('a1') || array['.jpg'], pg_temp.r('pages_lead')::text), '{}'::text[],
  'with no name, email, booking id, student id or picture path');
select is(pg_temp.r('pages_admin'), pg_temp.r('pages_lead'), 'an admin gets the same');
select is(array[pg_temp.code(pg_temp.r('pages_m1')), pg_temp.code(pg_temp.r('pages_unknown_lead')), pg_temp.code(pg_temp.r('pages_unknown_admin')),
                pg_temp.code(pg_temp.r('pages_null'))],
  array['forbidden', 'forbidden', 'not_found', 'invalid_input'], 'a marker who leads nothing is refused; an unknown alert is not_found to an admin only');
-- A page with no current marking picture (a rerun replaced it) says so, as marking_unit_open does.
update public.script_pages set replaced_at = now() where id = pg_temp.k('p:a1:3');
select tests.as_user(pg_temp.uid('lead'));
insert into res values ('pages_no_picture', public.marking_alert_pages(pg_temp.alert('a1', 'picture_changed')));
select tests.as_postgres();
update public.script_pages set replaced_at = null where id = pg_temp.k('p:a1:3');
select is((select array_agg((x ->> 'has_picture')::boolean order by (x ->> 'n')::int) from jsonb_array_elements(pg_temp.r('pages_no_picture') -> 'pages') x),
  array[true, true, false], 'each page says whether it has a marking picture');
-- With the pages seen, the lead's links still come through the piece it names.
select tests.as_user(pg_temp.uid('lead'));
select is(pg_temp.code(public.marking_picture_paths((pg_temp.r('pages_lead') ->> 'unit_id')::uuid, array[pg_temp.k('p:a1:2')])), 'ok',
  'the piece it names gives the lead the changed page''s link');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- Privileges.
-- ---------------------------------------------------------------------------------------------
select is(array(select f from unnest(array['public.marking_picture_paths(uuid, uuid[], timestamptz)', 'public.marking_alert_pages(uuid)']) f
  where has_function_privilege('anon', f, 'execute') or not has_function_privilege('authenticated', f, 'execute')), '{}'::text[],
  'marking_picture_paths and marking_alert_pages are for signed-in users only');
select is(array(select x from unnest(array['marking_picture_paths', 'marking_alert_pages', 'marking_unit_open', 'marking_alerts_list']) x
  where not exists (select 1 from pg_proc p where p.proname = x and p.prosecdef and 'search_path=""' = any (p.proconfig))), '{}'::text[],
  'each is security definer with an empty search path');

select * from finish();
rollback;
