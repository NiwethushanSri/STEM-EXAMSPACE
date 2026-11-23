begin;
create extension if not exists pgtap with schema extensions;
select plan(173);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Fixtures. Subject 'ZZ Marking work': correctors m1 (Mara One), m2 and m3 are approved for it; corr is never
-- approved; par is a parent. Each exam is tests.marking_exam (finished 2 days ago) with the test structure (1: 3 marks;
-- 2(a): 2 marks; 2(b): 5 marks, in half marks in exam e), opened here as postgres. A unit is kept as 'u:<script>', or
-- 'u:<script>/<group label>' when marked by question; a marking as 'mk:<script>' (or 'mk:<script>/<group>'); a
-- question as 'q:<exam>:<label>'; a script's page as 'p:<script>:<copy page>'. Pieces are handed out as Next script
-- and an admin's assignment do (marking_unit_take), except the first, which m1 takes with Next script.
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values
  ('admin', tests.create_user('admin', 'active')),
  ('m1', tests.create_user('corrector', 'active')),
  ('m2', tests.create_user('corrector', 'active')),
  ('m3', tests.create_user('corrector', 'active')),
  ('corr', tests.create_user('corrector', 'active')),
  ('par', tests.create_user('parent', 'active'));
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create temp table res (name text primary key, j jsonb);
grant all on res to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
create function pg_temp.u(p text) returns uuid language sql stable as $$ select id from kv where name = 'u:' || p $$;
create function pg_temp.r(p text) returns jsonb language sql stable as $$ select j from res where name = p $$;
create function pg_temp.subj() returns bigint language sql stable as $$ select id from public.subjects where name = 'ZZ Marking work' $$;
-- A function's answer: 'ok', or its code.
create function pg_temp.code(j jsonb) returns text language sql immutable as $$
  select case when (j ->> 'ok')::boolean then 'ok' else coalesce(j ->> 'code', 'none') end $$;
-- Operations of a save.
create function pg_temp.mk(p_q uuid, p_mark numeric, p_na boolean default false) returns jsonb language sql immutable as $$
  select jsonb_build_object('op', 'mark', 'question_id', p_q, 'mark', p_mark, 'na', p_na) $$;
create function pg_temp.tick(p_id uuid, p_page uuid, p_x numeric default 0.5) returns jsonb language sql immutable as $$
  select jsonb_build_object('op', 'ann_put', 'id', p_id, 'page_id', p_page, 'kind', 'tick', 'x', p_x, 'y', 0.5) $$;
-- A pen stroke of n points.
create function pg_temp.pen(p_id uuid, p_page uuid, p_n int) returns jsonb language sql immutable as $$
  select jsonb_build_object('op', 'ann_put', 'id', p_id, 'page_id', p_page, 'kind', 'pen', 'x', 0.1, 'y', 0.1,
    'points', (select jsonb_agg(jsonb_build_array(0.1 + i * 0.0001, 0.1)) from generate_series(1, p_n) i)) $$;
-- n ticks with new ids on a page.
create function pg_temp.ticks(p_page uuid, p_n int) returns jsonb language sql volatile as $$
  select jsonb_agg(pg_temp.tick(gen_random_uuid(), p_page)) from generate_series(1, p_n) $$;
-- A marking's current rev (read as postgres, so a marker's call can pass it).
create function pg_temp.rev(p text) returns int language sql stable security definer as $$
  select rev from public.markings where id = pg_temp.k(p) $$;
-- A script's marking or full pictures (read as postgres), and how many of these the caller can read in storage.
create function pg_temp.paths(p_script text, p_kind text) returns text[] language sql stable security definer as $$
  select coalesce(array_agg(case when p_kind = 'full' then p.full_path else p.marking_path end order by l.copy_page), '{}')
  from public.scripts s join public.script_page_links l on l.script_id = s.id and l.version = s.version
  join public.script_pages p on p.id = l.page_id where s.id = pg_temp.k(p_script) $$;
create function pg_temp.path(p_page text) returns text language sql stable security definer as $$
  select marking_path from public.script_pages where id = pg_temp.k(p_page) $$;
create function pg_temp.seen(p_names text[]) returns int language sql stable as $$
  select count(*)::int from storage.objects where bucket_id = 'script-pages' and name = any (p_names) $$;
create function pg_temp.put(p_names text[]) returns void language sql as $$
  insert into storage.objects (bucket_id, name) select 'script-pages', n from unnest(p_names) n on conflict do nothing $$;
-- 3B (Ruling R12): a marker reads no picture from storage; links are signed for what marking_picture_paths gives. The
-- pieces that show the page whose current marking picture is p_name (read as postgres), and how many of these
-- pictures the caller is given by marking_picture_paths, asking with each such piece. Only a page's current marking
-- picture is found this way: a full, old or replaced picture is asked of marking_picture_paths by its page instead.
create function pg_temp.shown(p_name text) returns table (unit_id uuid, page_id uuid) language sql stable security definer as $$
  with pages as (select p.id, p.upload_id from public.script_pages p where p.marking_path = p_name and p.replaced_at is null),
  scripts as (
    select l.script_id, pg.id as page_id from pages pg
    join public.script_page_links l on l.page_id = pg.id join public.scripts s on s.id = l.script_id and s.version = l.version
    union
    select s.id, pg.id from pages pg join public.script_uploads up on up.id = pg.upload_id
    join public.home_submissions hs on hs.id = up.submission_id join public.scripts s on s.booking_id = hs.booking_id)
  select u.id, x.page_id from scripts x join public.marking_units u on u.script_id = x.script_id $$;
create function pg_temp.got(p_names text[]) returns int language sql as $$
  select count(distinct n)::int from unnest(p_names) n
  where exists (select 1 from pg_temp.shown(n) s
                where public.marking_picture_paths(s.unit_id, array[s.page_id]) -> 'paths' -> 0 ->> 'marking_path' = n) $$;
-- A new verified home script of an exam.
create function pg_temp.script(p_name text, p_exam text, p_pages int default 3) returns void language plpgsql as $$
begin
  insert into kv values (p_name, tests.verified_script(pg_temp.k(p_exam), 'home', p_pages));
  insert into kv select 'p:' || p_name || ':' || l.copy_page, l.page_id
  from public.scripts s join public.script_page_links l on l.script_id = s.id and l.version = s.version where s.id = pg_temp.k(p_name);
end $$;
-- The test structure and its questions.
create function pg_temp.structure(p_exam text) returns void language plpgsql as $$
begin
  perform tests.structure(pg_temp.k(p_exam));
  insert into kv select 'q:' || p_exam || ':' || coalesce(p.label || '(' || q.label || ')', q.label), q.id
  from public.exam_questions q left join public.exam_questions p on p.id = q.parent_id where q.exam_id = pg_temp.k(p_exam);
end $$;
-- Opens an exam's marking (as marking_open would), makes its verified scripts ready, and keeps their units.
create function pg_temp.open(p text) returns void language plpgsql as $$
begin
  insert into public.exam_marking (exam_id, opened_at, opened_by) values (pg_temp.k(p), now(), pg_temp.uid('admin'))
  on conflict (exam_id) do update set opened_at = excluded.opened_at, closed_at = null;
  perform public.marking_exam_sync(pg_temp.k(p), null);
  insert into kv select 'u:' || x.name || coalesce('/' || g.label, ''), u.id
  from kv x join public.marking_units u on u.script_id = x.id left join public.question_groups g on g.id = u.group_id
  on conflict (name) do nothing;
end $$;
-- The marker takes a piece, as Next script (a 2-hour hold) or an admin's assignment (no time limit) does.
create function pg_temp.take(p text, p_marker text, p_how text default 'next') returns void language sql as $$
  select public.marking_unit_take(pg_temp.u(p), pg_temp.uid(p_marker), p_how,
    case when p_how = 'assigned' then pg_temp.uid('admin') end,
    case when p_how = 'next' then now() + interval '2 hours' end) $$;
-- Keeps the marker's live marking on a piece as 'mk:<piece>'.
create function pg_temp.keep(p text, p_marker text) returns void language sql as $$
  insert into kv select 'mk:' || p, m.id from public.markings m
  where m.unit_id = pg_temp.u(p) and m.kind = 'live' and m.marker_id = pg_temp.uid(p_marker) $$;
-- A marking's marks, in paper order: '1=2,2(a)=1,2(b)=NR'.
create function pg_temp.marks(p text) returns text language sql stable as $$
  select coalesce(string_agg(coalesce(pq.label || '(' || q.label || ')', q.label) || '='
                             || case when m.not_attempted then 'NR' else coalesce(trim_scale(m.mark)::text, '-') end,
                             ',' order by coalesce(pq.position, q.position), pq.id is not null, q.position), '')
  from public.question_marks m join public.exam_questions q on q.id = m.question_id
  left join public.exam_questions pq on pq.id = q.parent_id
  where m.marking_id = pg_temp.k(p) $$;
-- A script's state, a piece's state.
create function pg_temp.st(p text) returns text language sql stable as $$ select state::text from public.scripts where id = pg_temp.k(p) $$;
create function pg_temp.us(p text) returns text language sql stable as $$ select state from public.marking_units where id = pg_temp.u(p) $$;
-- How many audit rows of this action concern this target.
create function pg_temp.audits(p_action text, p_target uuid) returns int language sql stable as $$
  select count(*)::int from public.audit_log a where a.action = p_action and a.target_id = p_target $$;
-- The candidate of a script, and the file holding its pages.
create function pg_temp.student(p text) returns uuid language sql stable as $$
  select b.student_id from public.scripts s join public.bookings b on b.id = s.booking_id where s.id = pg_temp.k(p) $$;
create function pg_temp.upload(p text) returns uuid language sql stable as $$
  select pg.upload_id from public.script_pages pg where pg.id = pg_temp.k('p:' || p || ':1') $$;
-- A family's extra page for a home script: a further hand-in (adding pages) with one photo whose page has no code,
-- placed after a page, confirmed by staff or not. Returns the page.
create function pg_temp.extra(p_script text, p_after int, p_confirmed boolean) returns uuid language plpgsql as $$
declare
  v_s public.scripts%rowtype;
  v_student uuid;
  v_sub uuid;
  v_up uuid := gen_random_uuid();
  v_page uuid;
begin
  select * into v_s from public.scripts where id = pg_temp.k(p_script);
  select b.student_id into v_student from public.bookings b where b.id = v_s.booking_id;
  insert into public.home_submissions (booking_id, seq, replaces_all, state, submitted_by, submitted_at, checked_at)
  select v_s.booking_id, max(h.seq) + 1, false, 'received', v_student, now(), now()
  from public.home_submissions h where h.booking_id = v_s.booking_id
  returning id into v_sub;
  insert into public.script_uploads (id, exam_id, booking_id, submission_id, kind, position, storage_path, mime, byte_size, state,
    uploaded_by, stored_at)
  values (v_up, v_s.exam_id, v_s.booking_id, v_sub, 'home_photo', 1, 'home/' || v_s.booking_id || '/' || v_up || '.jpg', 'image/jpeg',
    5000, 'processed', v_student, now());
  insert into public.script_pages (upload_id, source_index, exam_id, booking_id, state, full_path, marking_path, placed_after)
  values (v_up, 0, v_s.exam_id, v_s.booking_id, 'unmatched', v_s.exam_id || '/' || v_up || '/1-1/0-full.jpg',
    v_s.exam_id || '/' || v_up || '/1-1/0-marking.jpg', p_after)
  returning id into v_page;
  insert into public.script_exceptions (exam_id, kind, booking_id, script_id, page_id, upload_id, state, resolved_by, resolved_at, resolution)
  values (v_s.exam_id, 'uncoded_family_page', v_s.booking_id, v_s.id, v_page, v_up,
    case when p_confirmed then 'resolved' else 'open' end, case when p_confirmed then pg_temp.uid('admin') end,
    case when p_confirmed then now() end, case when p_confirmed then 'confirmed' end);
  return v_page;
end $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.u(text), pg_temp.r(text), pg_temp.subj(), pg_temp.code(jsonb),
  pg_temp.mk(uuid, numeric, boolean), pg_temp.tick(uuid, uuid, numeric), pg_temp.pen(uuid, uuid, int), pg_temp.ticks(uuid, int),
  pg_temp.rev(text), pg_temp.paths(text, text), pg_temp.path(text), pg_temp.seen(text[]), pg_temp.shown(text), pg_temp.got(text[]) to public;

insert into public.subjects (name, kind) values ('ZZ Marking work', 'school');
insert into public.marker_approvals (marker_id, subject_id, approved_at)
select c.id, pg_temp.subj(), now() from c where c.name in ('m1', 'm2', 'm3');
update public.profiles set first_name = 'Mara', last_name = 'One' where id = pg_temp.uid('m1');

-- Exam e, marked as whole scripts; question 2(b) is in half marks.
insert into kv values ('e', tests.marking_exam(pg_temp.subj()));
select pg_temp.structure('e');
update public.exam_questions set mark_step = 0.5 where id = pg_temp.k('q:e:2(b)');
select pg_temp.script('a1', 'e');
select pg_temp.open('e');

-- ---------------------------------------------------------------------------------------------
-- open_creates_one_marking_and_sets_script_marking
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('next_a1', public.marking_next(pg_temp.k('e')));
insert into res values ('open_a1', public.marking_unit_open(pg_temp.u('a1')));
insert into res values ('open_a1b', public.marking_unit_open(pg_temp.u('a1')));
select tests.as_postgres();
select pg_temp.keep('a1', 'm1');
select is(array[pg_temp.r('next_a1') ->> 'unit_id', pg_temp.code(pg_temp.r('open_a1')), pg_temp.code(pg_temp.r('open_a1b'))],
  array[pg_temp.u('a1')::text, 'ok', 'ok'], 'open_creates_one_marking_and_sets_script_marking: m1 presses Next script and opens the piece twice');
select is((select count(*)::int from public.markings where unit_id = pg_temp.u('a1')), 1, 'the first open makes one marking; the second makes no other');
select is((select array[m.kind::text, m.status, m.rev::text, (m.pages_key = public.marking_pages_key(pg_temp.k('a1')))::text]
           from public.markings m where m.id = pg_temp.k('mk:a1')),
  array['live', 'in_progress', '0', 'true'], 'it is m1''s live marking, in progress at rev 0, with the key of the pages it was opened with');
select is(array[pg_temp.r('open_a1') -> 'marking' ->> 'id', pg_temp.r('open_a1b') -> 'marking' ->> 'id'],
  array[pg_temp.k('mk:a1')::text, pg_temp.k('mk:a1')::text], 'both opens return that marking');
select is(pg_temp.st('a1'), 'marking', 'the script is being marked');
select is(pg_temp.r('open_a1') -> 'marking',
  jsonb_build_object('id', pg_temp.k('mk:a1'), 'rev', 0, 'status', 'in_progress', 'lead_note', null, 'total', null, 'max_total', 10,
                     'pages_changed', false),
  'the marking: rev 0, no total yet, out of 10');
select is(pg_temp.r('open_a1') -> 'unit',
  (select jsonb_build_object('id', pg_temp.u('a1'), 'exam_title', 'ZZ Marking exam', 'paper', 'Paper 1', 'subject', 'ZZ Marking work',
     'script_number', s.number, 'index_number', d.index_number, 'group_label', null, 'deadline', null,
     'hold_until', now() + interval '2 hours', 'closed', false)
   from public.scripts s join public.bookings b on b.id = s.booking_id join public.student_details d on d.profile_id = b.student_id
   where s.id = pg_temp.k('a1')),
  'the piece: exam, paper, subject, script number, index number, and m1''s hold');
select is((select array_agg(q ->> 'label' order by o) from jsonb_array_elements(pg_temp.r('open_a1') -> 'structure' -> 'questions') with ordinality t(q, o)),
  array['1', '2', 'a', 'b'], 'a whole script has every question, in paper order, each part after its question');
select is((select array_agg(p -> 'copy_page' order by (p ->> 'n')::int) from jsonb_array_elements(pg_temp.r('open_a1') -> 'pages') p),
  array['1', '2', '3']::jsonb[], 'and every answer page');
select is(array[pg_temp.r('open_a1') -> 'marks', pg_temp.r('open_a1') -> 'annotations'], array['[]', '[]']::jsonb[],
  'no marks or annotations yet');
select is(pg_temp.r('open_a1') -> 'structure' -> 'version', '0'::jsonb, 'the structure version is the exam''s');

-- ---------------------------------------------------------------------------------------------
-- open_shows_answer_pages_only_in_order: exam er's paper has 4 pages: a cover (page 1), an information page (3) and a
-- blank page (4); r1 has 6 pages (5 and 6 are spare pages), page 6 refused by staff and page 5 turned a quarter.
-- ---------------------------------------------------------------------------------------------
insert into kv values ('er', tests.marking_exam(pg_temp.subj()));
select pg_temp.structure('er');
update public.paper_page_roles r
set role = case r.page when 1 then 'cover'::public.page_role when 3 then 'information'::public.page_role else 'answer'::public.page_role end
from public.exam_papers p where p.id = r.paper_id and p.exam_id = pg_temp.k('er');
update public.exam_papers set page_count = 4 where exam_id = pg_temp.k('er') and kind = 'paper';
insert into public.paper_page_roles (paper_id, page, role)
select p.id, 4, 'blank' from public.exam_papers p where p.exam_id = pg_temp.k('er') and p.kind = 'paper';
select pg_temp.script('r1', 'er', 6);
insert into public.script_exceptions (exam_id, kind, script_id, page_id, state, resolved_by, resolved_at, resolution)
values (pg_temp.k('er'), 'poor_quality', pg_temp.k('r1'), pg_temp.k('p:r1:6'), 'resolved', pg_temp.uid('admin'), now(), 'rejected');
update public.script_pages set rotation = 90 where id = pg_temp.k('p:r1:5');
select pg_temp.open('er');
select pg_temp.take('r1', 'm1');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('open_r1', public.marking_unit_open(pg_temp.u('r1')));
select tests.as_postgres();
select pg_temp.keep('r1', 'm1');
select is((select jsonb_agg(jsonb_build_array(p -> 'n', p -> 'copy_page', p -> 'extra') order by (p ->> 'n')::int)
           from jsonb_array_elements(pg_temp.r('open_r1') -> 'pages') p),
  '[[1, 2, false], [2, 5, false]]'::jsonb,
  'open_shows_answer_pages_only_in_order: the answer page and the spare page, numbered in page order; not the cover, the information page, the blank page or the refused page');
select is((select array_agg((p ->> 'page_id')::uuid order by (p ->> 'n')::int) from jsonb_array_elements(pg_temp.r('open_r1') -> 'pages') p),
  array[pg_temp.k('p:r1:2'), pg_temp.k('p:r1:5')], 'they are the pages the script shows there');
select is((select array_agg(jsonb_build_array(p -> 'has_picture', p -> 'rotation') order by (p ->> 'n')::int)
           from jsonb_array_elements(pg_temp.r('open_r1') -> 'pages') p),
  (select array_agg(jsonb_build_array(sp.marking_path is not null, sp.rotation) order by sp.source_index)
   from public.script_pages sp where sp.id in (pg_temp.k('p:r1:2'), pg_temp.k('p:r1:5'))),
  'each says it has a marking picture (not its path: 3B), with its rotation');
select is(public.marking_pages_key(pg_temp.k('r1')), md5(pg_temp.k('p:r1:2') || ':0,' || pg_temp.k('p:r1:5') || ':90'),
  'the pages key is the md5 of the ordered page:rotation list');

-- ---------------------------------------------------------------------------------------------
-- confirmed_family_extra_page_shown_after_its_page: x1's family placed a page after page 2 (confirmed by staff) and one
-- after page 1 (not confirmed), before marking opened.
-- ---------------------------------------------------------------------------------------------
insert into kv values ('ex', tests.marking_exam(pg_temp.subj()));
select pg_temp.structure('ex');
select pg_temp.script('x1', 'ex');
insert into kv values ('x1_extra', pg_temp.extra('x1', 2, true));
insert into kv values ('x1_unconfirmed', pg_temp.extra('x1', 1, false));
select pg_temp.open('ex');
select pg_temp.take('x1', 'm1');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('open_x1', public.marking_unit_open(pg_temp.u('x1')));
select tests.as_postgres();
select is((select jsonb_agg(jsonb_build_array(p -> 'n', p -> 'copy_page', p -> 'extra') order by (p ->> 'n')::int)
           from jsonb_array_elements(pg_temp.r('open_x1') -> 'pages') p),
  '[[1, 1, false], [2, 2, false], [3, null, true], [4, 3, false]]'::jsonb,
  'confirmed_family_extra_page_shown_after_its_page: the extra page placed after page 2 is n = 3, before page 3');
select is((select (p ->> 'page_id')::uuid from jsonb_array_elements(pg_temp.r('open_x1') -> 'pages') p where (p ->> 'n')::int = 3),
  pg_temp.k('x1_extra'), 'it is the confirmed page');
select is((select count(*)::int from jsonb_array_elements(pg_temp.r('open_x1') -> 'pages') p where (p ->> 'page_id')::uuid = pg_temp.k('x1_unconfirmed')),
  0, 'a page staff have not confirmed is not shown');

-- ---------------------------------------------------------------------------------------------
-- unit_open_has_no_name
-- ---------------------------------------------------------------------------------------------
select is(array(select x from unnest(array['Wilhelmina', 'Quarterfield',
                                           (select p.email::text from public.profiles p where p.id = pg_temp.student('a1')),
                                           (select s.booking_id::text from public.scripts s where s.id = pg_temp.k('a1')),
                                           pg_temp.student('a1')::text]) x
                where position(lower(x) in lower(pg_temp.r('open_a1')::text)) > 0),
  '{}'::text[], 'unit_open_has_no_name: the result has neither the candidate''s first or last name, email, booking id nor student id');
select is(position((pg_temp.r('open_a1') -> 'unit' ->> 'index_number') in pg_temp.r('open_a1')::text) > 0
          and pg_temp.r('open_a1') -> 'unit' ->> 'index_number' like 'SE-2099-%', true, 'it shows the index number');

-- ---------------------------------------------------------------------------------------------
-- group_unit_has_only_its_groups_questions: exam eq is marked by question, G1 (question 1) and G2 (question 2).
-- ---------------------------------------------------------------------------------------------
insert into kv values ('eq', tests.marking_exam(pg_temp.subj()));
select pg_temp.structure('eq');
insert into public.question_groups (exam_id, label, position) values (pg_temp.k('eq'), 'G1', 1), (pg_temp.k('eq'), 'G2', 2);
update public.exam_questions q set group_id = g.id from public.question_groups g
where q.exam_id = pg_temp.k('eq') and q.parent_id is null and g.exam_id = q.exam_id and g.label = 'G' || q.label;
insert into public.exam_marking (exam_id, mode) values (pg_temp.k('eq'), 'by_question');
select pg_temp.script('g1', 'eq');
select pg_temp.open('eq');
select pg_temp.take('g1/G2', 'm1');
select pg_temp.take('g1/G1', 'm2');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('open_g2', public.marking_unit_open(pg_temp.u('g1/G2')));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m2'));
insert into res values ('open_g1', public.marking_unit_open(pg_temp.u('g1/G1')));
select tests.as_postgres();
select pg_temp.keep('g1/G2', 'm1');
select pg_temp.keep('g1/G1', 'm2');
select is((select array_agg(q ->> 'label' order by o) from jsonb_array_elements(pg_temp.r('open_g2') -> 'structure' -> 'questions') with ordinality t(q, o)),
  array['2', 'a', 'b'], 'group_unit_has_only_its_groups_questions: G2''s piece has question 2 and its parts only');
select is(array[pg_temp.r('open_g2') -> 'unit' ->> 'group_label', pg_temp.r('open_g2') -> 'marking' ->> 'max_total'], array['G2', '7.0'],
  'it is G2, out of 7');
select is((select array_agg(q ->> 'label' order by o) from jsonb_array_elements(pg_temp.r('open_g1') -> 'structure' -> 'questions') with ordinality t(q, o)),
  array['1'], 'G1''s piece has question 1 only');
select is(array[pg_temp.r('open_g1') -> 'unit' ->> 'group_label', pg_temp.r('open_g1') -> 'marking' ->> 'max_total'], array['G1', '3.0'],
  'it is G1, out of 3');
select is(jsonb_array_length(pg_temp.r('open_g2') -> 'pages'), 3, 'each piece shows the script''s answer pages');
select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.code(public.marking_save(pg_temp.k('mk:g1/G2'), 0, jsonb_build_array(pg_temp.mk(pg_temp.k('q:eq:1'), 1)))), 'invalid_input',
  'a mark for a question of another group is refused');
select tests.as_postgres();
select is(pg_temp.marks('mk:g1/G2'), '', 'and nothing is stored');

-- ---------------------------------------------------------------------------------------------
-- save_marks_and_annotations_and_bumps_rev
-- ---------------------------------------------------------------------------------------------
insert into kv values ('ann1', gen_random_uuid());
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('s1', public.marking_save(pg_temp.k('mk:a1'), 0, jsonb_build_array(
  pg_temp.mk(pg_temp.k('q:e:1'), 2), pg_temp.mk(pg_temp.k('q:e:2(a)'), 1), pg_temp.tick(pg_temp.k('ann1'), pg_temp.k('p:a1:1'))), 400));
insert into res values ('s2', public.marking_save(pg_temp.k('mk:a1'), 1, jsonb_build_array(
  pg_temp.tick(pg_temp.k('ann1'), pg_temp.k('p:a1:2'), 0.25), jsonb_build_object('op', 'note', 'text', '  Check the working on page 2.  ')), 20));
insert into res values ('open_a1c', public.marking_unit_open(pg_temp.u('a1')));
select tests.as_postgres();
select is(pg_temp.r('s1'), jsonb_build_object('ok', true, 'rev', 1, 'total', 3, 'hold_until', now() + interval '2 hours'),
  'save_marks_and_annotations_and_bumps_rev: the first save is rev 1 with a total of 3, and the hold runs 2 hours from it');
select is(pg_temp.marks('mk:a1'), '1=2,2(a)=1', 'the marks are stored');
select is((select array[count(*)::text, min(a.page_id::text), min(a.kind), min(a.x::text), min(a.page_rotation::text), bool_and(a.deleted_at is null)::text]
           from public.page_annotations a where a.marking_id = pg_temp.k('mk:a1')),
  array['1', pg_temp.k('p:a1:2')::text, 'tick', '0.25', '0', 'true'], 'a second put of the same id moves the annotation: one row');
select is((select array[m.rev, m.active_seconds] from public.markings m where m.id = pg_temp.k('mk:a1')), array[2, 320],
  'rev counts the saves; active time adds at most 300 seconds a save');
select is((select array[m.lead_note, (m.last_saved_at = now())::text, m.total::text] from public.markings m where m.id = pg_temp.k('mk:a1')),
  array['Check the working on page 2.', 'true', '3.0'], 'the note to the lead is kept (trimmed), with the time of the save and the total');
select is((select count(*)::int from public.question_mark_history h
           where h.marking_id = pg_temp.k('mk:a1') and h.changed_by = pg_temp.uid('m1') and not h.after_submit and h.reason is null
             and h.source = 'marker' and h.changed_at = now()),
  2, 'each changed mark has a history row');
select is((select count(*)::int from public.audit_log a where a.target_id = pg_temp.k('mk:a1')), 0, 'draft saves write no audit row (Builder''s call 13)');
select is(pg_temp.r('open_a1c') -> 'marks',
  jsonb_build_array(jsonb_build_object('question_id', pg_temp.k('q:e:1'), 'mark', 2, 'na', false),
                    jsonb_build_object('question_id', pg_temp.k('q:e:2(a)'), 'mark', 1, 'na', false)),
  'opening again shows the marks');
select is(pg_temp.r('open_a1c') -> 'annotations',
  jsonb_build_array(jsonb_build_object('id', pg_temp.k('ann1'), 'page_id', pg_temp.k('p:a1:2'), 'kind', 'tick', 'x', 0.25, 'y', 0.5,
                                       'points', null, 'text', null, 'question_id', null)),
  'and the annotation');
select is(array[pg_temp.r('open_a1c') -> 'marking' ->> 'rev', pg_temp.r('open_a1c') -> 'marking' ->> 'lead_note',
                pg_temp.r('open_a1c') -> 'marking' ->> 'total'],
  array['2', 'Check the working on page 2.', '3.0'], 'and the rev, the note and the total');

-- ---------------------------------------------------------------------------------------------
-- mark_above_maximum_or_off_step_refused: question 1 is out of 3 in whole marks; 2(b) out of 5 in half marks.
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('r_over', public.marking_save(pg_temp.k('mk:a1'), 2, jsonb_build_array(
  pg_temp.mk(pg_temp.k('q:e:2(a)'), 2), pg_temp.mk(pg_temp.k('q:e:1'), 4))));
insert into res values ('r_step', public.marking_save(pg_temp.k('mk:a1'), 2, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 1.5))));
insert into res values ('r_neg', public.marking_save(pg_temp.k('mk:a1'), 2, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:2(b)'), -0.5))));
insert into res values ('r_half', public.marking_save(pg_temp.k('mk:a1'), 2, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:2(b)'), 2.5))));
insert into res values ('r_quarter', public.marking_save(pg_temp.k('mk:a1'), 3, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:2(b)'), 2.25))));
insert into res values ('r_above_half', public.marking_save(pg_temp.k('mk:a1'), 3, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:2(b)'), 5.5))));
insert into res values ('r_both', public.marking_save(pg_temp.k('mk:a1'), 3, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:2(b)'), 1, true))));
insert into res values ('r_parent', public.marking_save(pg_temp.k('mk:a1'), 3, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:2'), 1))));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('r_over')), pg_temp.code(pg_temp.r('r_step')), pg_temp.code(pg_temp.r('r_neg')),
                pg_temp.code(pg_temp.r('r_quarter')), pg_temp.code(pg_temp.r('r_above_half'))],
  array['mark_out_of_range', 'mark_out_of_range', 'mark_out_of_range', 'mark_out_of_range', 'mark_out_of_range'],
  'mark_above_maximum_or_off_step_refused: above the maximum, a half where only whole marks are given, below 0, a quarter, and above it in half marks');
select is(array[pg_temp.code(pg_temp.r('r_half')), pg_temp.r('r_half') ->> 'rev'], array['ok', '3'], 'a half mark is given where the question allows it');
select is(array[pg_temp.code(pg_temp.r('r_both')), pg_temp.code(pg_temp.r('r_parent'))], array['invalid_input', 'invalid_input'],
  'a mark with NR, or a mark for a question that has parts, is refused');
select is(array[pg_temp.marks('mk:a1'), pg_temp.rev('mk:a1')::text], array['1=2,2(a)=1,2(b)=2.5', '3'],
  'nothing of a refused save is kept, not even its other operations');

-- ---------------------------------------------------------------------------------------------
-- nr_is_recorded_not_zero
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('nr', public.marking_save(pg_temp.k('mk:a1'), 3, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:2(b)'), null, true))));
select tests.as_postgres();
select is((select array[coalesce(m.mark::text, 'null'), m.not_attempted::text] from public.question_marks m
           where m.marking_id = pg_temp.k('mk:a1') and m.question_id = pg_temp.k('q:e:2(b)')),
  array['null', 'true'], 'nr_is_recorded_not_zero: NR is stored as no response, with no mark');
select is(array[pg_temp.r('nr') ->> 'total', pg_temp.marks('mk:a1')], array['3.0', '1=2,2(a)=1,2(b)=NR'], 'and adds nothing to the total');
select is((select array[coalesce(h.mark::text, 'null'), h.not_attempted::text] from public.question_mark_history h
           where h.marking_id = pg_temp.k('mk:a1') and h.question_id = pg_temp.k('q:e:2(b)') order by h.id desc limit 1),
  array['null', 'true'], 'its history row says NR');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('clear', public.marking_save(pg_temp.k('mk:a1'), 4, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:2(b)'), null, false))));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('clear')), pg_temp.marks('mk:a1')], array['ok', '1=2,2(a)=1'], 'no mark and no NR clears the question');

-- ---------------------------------------------------------------------------------------------
-- stale_rev_is_refused_never_overwrites (Review Focus 3): two screens hold rev 5; the first saves.
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('screen1', public.marking_save(pg_temp.k('mk:a1'), 5, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 3))));
insert into res values ('screen2', public.marking_save(pg_temp.k('mk:a1'), 5, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 1))));
select tests.as_postgres();
select is(pg_temp.code(pg_temp.r('screen1')), 'ok', 'stale_rev_is_refused_never_overwrites: the first screen saves');
select is(pg_temp.r('screen2'), '{"ok": false, "code": "conflict", "reason": "rev", "rev": 6}'::jsonb,
  'the second screen''s save with the old rev is refused and told the current rev');
select is(array[pg_temp.marks('mk:a1'), pg_temp.rev('mk:a1')::text], array['1=3,2(a)=1', '6'], 'the stored mark is the first save''s');
select is((select count(*)::int from public.question_mark_history h where h.marking_id = pg_temp.k('mk:a1') and h.mark = 1
             and h.question_id = pg_temp.k('q:e:1')), 0, 'and the refused save left no history');

-- ---------------------------------------------------------------------------------------------
-- save_after_hold_expired_refused_and_work_kept (Review Focus 1)
-- ---------------------------------------------------------------------------------------------
select pg_temp.script('a2', 'e');
select pg_temp.open('e');
select pg_temp.take('a2', 'm1');
insert into kv values ('ann2', gen_random_uuid());
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('open_a2', public.marking_unit_open(pg_temp.u('a2')));
select tests.as_postgres();
select pg_temp.keep('a2', 'm1');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('s_a2', public.marking_save(pg_temp.k('mk:a2'), 0, jsonb_build_array(
  pg_temp.mk(pg_temp.k('q:e:1'), 1), pg_temp.tick(pg_temp.k('ann2'), pg_temp.k('p:a2:1')))));
insert into res values ('late_save', public.marking_save(pg_temp.k('mk:a2'), 1, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 2)), 0, null,
  now() + interval '2 hours 1 second'));
insert into res values ('late_open', public.marking_unit_open(pg_temp.u('a2'), now() + interval '2 hours 1 second'));
insert into res values ('late_submit', public.marking_submit(pg_temp.k('mk:a2'), 1, now() + interval '2 hours 1 second'));
select tests.as_postgres();
select is(pg_temp.code(pg_temp.r('s_a2')), 'ok', 'save_after_hold_expired_refused_and_work_kept: m1 saves within the hold');
select is(pg_temp.code(pg_temp.r('late_save')), 'hold_expired', 'a save a second after the hold ran out is refused');
select is(array[pg_temp.code(pg_temp.r('late_open')), pg_temp.code(pg_temp.r('late_submit'))], array['hold_expired', 'hold_expired'],
  'so are opening and submitting the piece');
select is(array[pg_temp.marks('mk:a2'), pg_temp.rev('mk:a2')::text,
                (select count(*)::text from public.page_annotations a where a.marking_id = pg_temp.k('mk:a2') and a.deleted_at is null)],
  array['1=1', '1', '1'], 'what m1 saved is kept as it was');
-- The hold ends, as the minute job (marking_holds_expire) ends it; run here for this piece only, as the job would also
-- end the other holds of this file.
update public.marking_assignments set ended_at = now(), end_reason = 'expired' where unit_id = pg_temp.u('a2') and ended_at is null;
update public.marking_units set state = 'open' where id = pg_temp.u('a2');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('ended_open', public.marking_unit_open(pg_temp.u('a2')));
insert into res values ('ended_save', public.marking_save(pg_temp.k('mk:a2'), 1, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 2))));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('ended_open')), pg_temp.code(pg_temp.r('ended_save')), pg_temp.us('a2'),
                (select status from public.markings where id = pg_temp.k('mk:a2'))],
  array['hold_expired', 'hold_expired', 'open', 'in_progress'], 'once the hold has ended the piece is free; the marking stays in progress');
-- Next script gives the free piece back to m1 (Task 5, step 2).
select pg_temp.take('a2', 'm1');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('back_open', public.marking_unit_open(pg_temp.u('a2')));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('back_open')), pg_temp.r('back_open') -> 'marking' ->> 'id', pg_temp.r('back_open') -> 'marking' ->> 'rev',
                jsonb_array_length(pg_temp.r('back_open') -> 'marks')::text, jsonb_array_length(pg_temp.r('back_open') -> 'annotations')::text],
  array['ok', pg_temp.k('mk:a2')::text, '1', '1', '1'], 'given the piece again, m1 carries on with the same marking and work');

-- ---------------------------------------------------------------------------------------------
-- save_renews_a_next_hold_and_not_an_assigned_one: m1 holds a2 by Next script; an admin assigned a3 to m2.
-- ---------------------------------------------------------------------------------------------
select pg_temp.script('a3', 'e');
select pg_temp.open('e');
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_assign(array[pg_temp.u('a3')], pg_temp.uid('m2'), 'Marking this one for us')), 'ok',
  'save_renews_a_next_hold_and_not_an_assigned_one: an admin assigns a3 to m2');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m1'));
insert into res values ('renew', public.marking_save(pg_temp.k('mk:a2'), 1, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 2)), 0, null,
  now() + interval '30 minutes'));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m2'));
insert into res values ('open_a3', public.marking_unit_open(pg_temp.u('a3')));
select tests.as_postgres();
select pg_temp.keep('a3', 'm2');
select tests.as_user(pg_temp.uid('m2'));
insert into res values ('s_a3', public.marking_save(pg_temp.k('mk:a3'), 0, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 1))));
insert into res values ('s_a3_late', public.marking_save(pg_temp.k('mk:a3'), 1, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 2)), 0, null,
  now() + interval '30 days'));
select tests.as_postgres();
select is(pg_temp.r('renew') -> 'hold_until', to_jsonb(now() + interval '2 hours 30 minutes'), 'a save renews a Next script hold to 2 hours from the save');
select is((select a.hold_until from public.marking_assignments a where a.unit_id = pg_temp.u('a2') and a.ended_at is null),
  now() + interval '2 hours 30 minutes', 'on the hold itself');
select is(array[pg_temp.r('open_a3') -> 'unit' -> 'hold_until', pg_temp.r('s_a3') -> 'hold_until'], array['null', 'null']::jsonb[],
  'an assigned piece has no time limit, before and after a save');
select is((select a.hold_until from public.marking_assignments a where a.unit_id = pg_temp.u('a3') and a.ended_at is null), null::timestamptz,
  'and its assignment keeps none');
select is(pg_temp.code(pg_temp.r('s_a3_late')), 'ok', 'so a save a month later is still taken');

-- ---------------------------------------------------------------------------------------------
-- other_marker_cannot_open_or_save
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('m2'));
select is(array[pg_temp.code(public.marking_unit_open(pg_temp.u('a1'))),
                pg_temp.code(public.marking_save(pg_temp.k('mk:a1'), 6, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 0)))),
                pg_temp.code(public.marking_submit(pg_temp.k('mk:a1'), 6))],
  array['forbidden', 'forbidden', 'forbidden'], 'other_marker_cannot_open_or_save: m2 cannot open, save or submit m1''s piece');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m1'));
select is(array[pg_temp.code(public.marking_unit_open(pg_temp.u('a3'))),
                pg_temp.code(public.marking_save(pg_temp.k('mk:a3'), 2, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 0))))],
  array['forbidden', 'forbidden'], 'nor m1 m2''s');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('corr'));
select is(array[pg_temp.code(public.marking_unit_open(pg_temp.u('a1'))),
                pg_temp.code(public.marking_save(pg_temp.k('mk:a1'), 6, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 0))))],
  array['forbidden', 'forbidden'], 'nor a corrector who is not approved');
select tests.as_postgres();
select is(array[pg_temp.marks('mk:a1'), pg_temp.rev('mk:a1')::text, pg_temp.marks('mk:a3')], array['1=3,2(a)=1', '6', '1=2'], 'nothing changed');
-- m3 holds a5 and has opened it; then a conflict with its candidate is declared, or m3's approval is taken away (as
-- postgres: the admin functions would also end the hold).
select pg_temp.script('a5', 'e');
select pg_temp.open('e');
select pg_temp.take('a5', 'm3');
select tests.as_user(pg_temp.uid('m3'));
select is(pg_temp.code(public.marking_unit_open(pg_temp.u('a5'))), 'ok', 'm3 opens the piece they hold');
select tests.as_postgres();
select pg_temp.keep('a5', 'm3');
insert into public.marker_conflicts (marker_id, student_id, recorded_at) values (pg_temp.uid('m3'), pg_temp.student('a5'), now());
select tests.as_user(pg_temp.uid('m3'));
select is(array[pg_temp.code(public.marking_unit_open(pg_temp.u('a5'))),
                pg_temp.code(public.marking_save(pg_temp.k('mk:a5'), 0, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 0))))],
  array['forbidden', 'forbidden'], 'a marker now blocked for the candidate can neither open nor save it');
select tests.as_postgres();
delete from public.marker_conflicts where marker_id = pg_temp.uid('m3');
delete from public.marker_approvals where marker_id = pg_temp.uid('m3');
select tests.as_user(pg_temp.uid('m3'));
select is(array[pg_temp.code(public.marking_unit_open(pg_temp.u('a5'))),
                pg_temp.code(public.marking_save(pg_temp.k('mk:a5'), 0, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 0))))],
  array['forbidden', 'forbidden'], 'nor one no longer approved for the subject');
select tests.as_postgres();
insert into public.marker_approvals (marker_id, subject_id, approved_at) values (pg_temp.uid('m3'), pg_temp.subj(), now());
select is(pg_temp.marks('mk:a5'), '', 'nothing was saved');

-- ---------------------------------------------------------------------------------------------
-- annotation_on_a_page_outside_the_unit_refused: m1 holds a1 and r1 (whose cover, information, blank and refused pages
-- are not shown).
-- ---------------------------------------------------------------------------------------------
insert into kv values ('ann_r2', gen_random_uuid()), ('ann_r5', gen_random_uuid()), ('ann_stale', gen_random_uuid());
select tests.as_user(pg_temp.uid('m1'));
select is(array[pg_temp.code(public.marking_save(pg_temp.k('mk:a1'), 6, jsonb_build_array(pg_temp.tick(gen_random_uuid(), pg_temp.k('p:a2:1'))))),
                pg_temp.code(public.marking_save(pg_temp.k('mk:r1'), 0, jsonb_build_array(pg_temp.tick(gen_random_uuid(), pg_temp.k('p:r1:1'))))),
                pg_temp.code(public.marking_save(pg_temp.k('mk:r1'), 0, jsonb_build_array(pg_temp.tick(gen_random_uuid(), pg_temp.k('p:r1:3'))))),
                pg_temp.code(public.marking_save(pg_temp.k('mk:r1'), 0, jsonb_build_array(pg_temp.tick(gen_random_uuid(), pg_temp.k('p:r1:4'))))),
                pg_temp.code(public.marking_save(pg_temp.k('mk:r1'), 0, jsonb_build_array(pg_temp.tick(gen_random_uuid(), pg_temp.k('p:r1:6'))))),
                pg_temp.code(public.marking_save(pg_temp.k('mk:r1'), 0, jsonb_build_array(pg_temp.tick(gen_random_uuid(), gen_random_uuid()))))],
  array['invalid_input', 'invalid_input', 'invalid_input', 'invalid_input', 'invalid_input', 'invalid_input'],
  'annotation_on_a_page_outside_the_unit_refused: another script''s page, a cover, an information page, a blank page, a refused page and an unknown page are refused');
select is(pg_temp.code(public.marking_save(pg_temp.k('mk:r1'), 0, jsonb_build_array(pg_temp.tick(pg_temp.k('ann_r2'), pg_temp.k('p:r1:2')),
                                                                                     pg_temp.tick(pg_temp.k('ann_r5'), pg_temp.k('p:r1:5'))))),
  'ok', 'an answer page and a spare page of the piece take annotations');
select is(pg_temp.code(public.marking_save(pg_temp.k('mk:a1'), 6, jsonb_build_array(pg_temp.tick(pg_temp.k('ann_r2'), pg_temp.k('p:a1:1'))))),
  'invalid_input', 'an annotation id of another marking is refused');
select tests.as_postgres();
select is((select count(*)::int from public.page_annotations a
           where a.marking_id in (pg_temp.k('mk:a1'), pg_temp.k('mk:r1'))
             and a.page_id not in (pg_temp.k('p:a1:1'), pg_temp.k('p:a1:2'), pg_temp.k('p:a1:3'), pg_temp.k('p:r1:2'), pg_temp.k('p:r1:5'))),
  0, 'nothing is stored on a page outside the pieces');
select is((select array_agg(a.page_rotation order by a.page_rotation) from public.page_annotations a
           where a.id in (pg_temp.k('ann_r2'), pg_temp.k('ann_r5'))),
  array[0, 90], 'an annotation keeps the rotation its page had');
select is((select a.page_id from public.page_annotations a where a.id = pg_temp.k('ann_r2')), pg_temp.k('p:r1:2'),
  'the annotation of the other marking was not moved');
-- An annotation drawn when page 5 was turned another way is kept but not shown.
insert into public.page_annotations (id, marking_id, page_id, page_rotation, kind, x, y)
values (pg_temp.k('ann_stale'), pg_temp.k('mk:r1'), pg_temp.k('p:r1:5'), 0, 'cross', 0.5, 0.5);
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('open_r1b', public.marking_unit_open(pg_temp.u('r1')));
select tests.as_postgres();
select is((select array_agg((a ->> 'id')::uuid order by a ->> 'page_id' = pg_temp.k('p:r1:5')::text)
           from jsonb_array_elements(pg_temp.r('open_r1b') -> 'annotations') a),
  array[pg_temp.k('ann_r2'), pg_temp.k('ann_r5')], 'opening shows the annotations drawn at each page''s current rotation only');

-- ---------------------------------------------------------------------------------------------
-- ann_del_is_a_soft_delete_and_restore_brings_it_back
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('del', public.marking_save(pg_temp.k('mk:a1'), 6, jsonb_build_array(jsonb_build_object('op', 'ann_del', 'id', pg_temp.k('ann1')))));
insert into res values ('open_del', public.marking_unit_open(pg_temp.u('a1')));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('del')),
                (select (a.deleted_at = now())::text from public.page_annotations a where a.id = pg_temp.k('ann1'))],
  array['ok', 'true'], 'ann_del_is_a_soft_delete_and_restore_brings_it_back: deleting keeps the row, with the time it was deleted');
select is(jsonb_array_length(pg_temp.r('open_del') -> 'annotations'), 0, 'a deleted annotation is not shown');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('restore', public.marking_save(pg_temp.k('mk:a1'), 7, jsonb_build_array(jsonb_build_object('op', 'ann_restore', 'id', pg_temp.k('ann1')))));
insert into res values ('open_restore', public.marking_unit_open(pg_temp.u('a1')));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('restore')),
                (select (a.deleted_at is null)::text from public.page_annotations a where a.id = pg_temp.k('ann1'))],
  array['ok', 'true'], 'restoring brings it back');
select is((select array_agg((a ->> 'id')::uuid) from jsonb_array_elements(pg_temp.r('open_restore') -> 'annotations') a), array[pg_temp.k('ann1')],
  'and it is shown again');
select tests.as_user(pg_temp.uid('m1'));
select is(array[pg_temp.code(public.marking_save(pg_temp.k('mk:a1'), 8, jsonb_build_array(jsonb_build_object('op', 'ann_del', 'id', pg_temp.k('ann2'))))),
                pg_temp.code(public.marking_save(pg_temp.k('mk:a1'), 8, jsonb_build_array(jsonb_build_object('op', 'ann_restore', 'id', gen_random_uuid())))),
                pg_temp.code(public.marking_save(pg_temp.k('mk:a1'), 8, jsonb_build_array(jsonb_build_object('op', 'shout'))))],
  array['invalid_input', 'invalid_input', 'invalid_input'], 'another marking''s annotation, an unknown one and an unknown operation are refused');
select tests.as_postgres();
select is((select a.deleted_at from public.page_annotations a where a.id = pg_temp.k('ann2')), null::timestamptz, 'm1''s other piece is untouched');
-- r1's page 2 is turned after its annotation was deleted: it cannot be brought back until the page is turned back.
select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.code(public.marking_save(pg_temp.k('mk:r1'), pg_temp.rev('mk:r1'), jsonb_build_array(jsonb_build_object('op', 'ann_del', 'id', pg_temp.k('ann_r2'))))),
  'ok', 'm1 deletes an annotation on r1''s page 2');
select tests.as_postgres();
update public.script_pages set rotation = 180 where id = pg_temp.k('p:r1:2');
select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.code(public.marking_save(pg_temp.k('mk:r1'), pg_temp.rev('mk:r1'), jsonb_build_array(jsonb_build_object('op', 'ann_restore', 'id', pg_temp.k('ann_r2'))))),
  'invalid_input', 'an annotation is not brought back onto a page turned since it was drawn');
select tests.as_postgres();
select is((select a.deleted_at is not null from public.page_annotations a where a.id = pg_temp.k('ann_r2')), true, 'it stays deleted');
update public.script_pages set rotation = 0 where id = pg_temp.k('p:r1:2');
select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.code(public.marking_save(pg_temp.k('mk:r1'), pg_temp.rev('mk:r1'), jsonb_build_array(jsonb_build_object('op', 'ann_restore', 'id', pg_temp.k('ann_r2'))))),
  'ok', 'once the page is turned back, it is');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- more_than_200_ops_refused (and the other limits: 1,500 points a stroke; 500 live annotations a page)
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('m1'));
select is(array[pg_temp.code(public.marking_save(pg_temp.k('mk:a1'), 8, (select jsonb_agg(pg_temp.mk(pg_temp.k('q:e:1'), 3)) from generate_series(1, 201)))),
                pg_temp.code(public.marking_save(pg_temp.k('mk:a1'), 8, '[]'::jsonb)),
                pg_temp.code(public.marking_save(pg_temp.k('mk:a1'), 8, '{}'::jsonb)),
                pg_temp.code(public.marking_save(pg_temp.k('mk:a1'), 8, null))],
  array['invalid_input', 'invalid_input', 'invalid_input', 'invalid_input'], 'more_than_200_ops_refused: 201 operations, none, or no list are refused');
select is(public.marking_save(pg_temp.k('mk:a1'), 8, (select jsonb_agg(pg_temp.mk(pg_temp.k('q:e:1'), 3)) from generate_series(1, 200))) ->> 'rev',
  '9', '200 are taken');
select is(array[pg_temp.code(public.marking_save(pg_temp.k('mk:a1'), 9, jsonb_build_array(pg_temp.pen(gen_random_uuid(), pg_temp.k('p:a1:1'), 1501)))),
                pg_temp.code(public.marking_save(pg_temp.k('mk:a1'), 9, jsonb_build_array(pg_temp.pen(gen_random_uuid(), pg_temp.k('p:a1:1'), 1500))))],
  array['invalid_input', 'ok'], 'a stroke of 1,501 points is refused; 1,500 are taken');
select is(array[pg_temp.code(public.marking_save(pg_temp.k('mk:a1'), 10, pg_temp.ticks(pg_temp.k('p:a1:3'), 200))),
                pg_temp.code(public.marking_save(pg_temp.k('mk:a1'), 11, pg_temp.ticks(pg_temp.k('p:a1:3'), 200))),
                pg_temp.code(public.marking_save(pg_temp.k('mk:a1'), 12, pg_temp.ticks(pg_temp.k('p:a1:3'), 100))),
                pg_temp.code(public.marking_save(pg_temp.k('mk:a1'), 13, pg_temp.ticks(pg_temp.k('p:a1:3'), 1)))],
  array['ok', 'ok', 'ok', 'invalid_input'], '500 live annotations fit on a page; a 501st is refused');
select tests.as_postgres();
insert into kv select 'ann500', a.id from public.page_annotations a
where a.marking_id = pg_temp.k('mk:a1') and a.page_id = pg_temp.k('p:a1:3') order by a.created_at, a.id limit 1;
select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.code(public.marking_save(pg_temp.k('mk:a1'), 13, jsonb_build_array(jsonb_build_object('op', 'ann_del', 'id', pg_temp.k('ann500')))
                                                                    || pg_temp.ticks(pg_temp.k('p:a1:3'), 1))),
  'ok', 'once one is deleted, another fits');
select tests.as_postgres();
select is((select count(*)::int from public.page_annotations a where a.marking_id = pg_temp.k('mk:a1') and a.page_id = pg_temp.k('p:a1:3')
             and a.deleted_at is null), 500, 'the page has 500 live annotations');
-- The other limits, on r1's marking: a note of at most 1,000 characters, a text of at most 500, x and y from 0 to 1,
-- and points as pairs of numbers.
insert into kv values ('ann_text', gen_random_uuid());
select tests.as_user(pg_temp.uid('m1'));
select is(array[
    pg_temp.code(public.marking_save(pg_temp.k('mk:r1'), pg_temp.rev('mk:r1'), jsonb_build_array(jsonb_build_object('op', 'note', 'text', repeat('n', 1001))))),
    pg_temp.code(public.marking_save(pg_temp.k('mk:r1'), pg_temp.rev('mk:r1'), jsonb_build_array(
      pg_temp.tick(pg_temp.k('ann_text'), pg_temp.k('p:r1:2')) || jsonb_build_object('kind', 'text', 'text', repeat('t', 501))))),
    pg_temp.code(public.marking_save(pg_temp.k('mk:r1'), pg_temp.rev('mk:r1'), jsonb_build_array(pg_temp.tick(gen_random_uuid(), pg_temp.k('p:r1:2'), 1.5)))),
    pg_temp.code(public.marking_save(pg_temp.k('mk:r1'), pg_temp.rev('mk:r1'), jsonb_build_array(
      pg_temp.tick(gen_random_uuid(), pg_temp.k('p:r1:2')) || jsonb_build_object('y', -0.1)))),
    pg_temp.code(public.marking_save(pg_temp.k('mk:r1'), pg_temp.rev('mk:r1'), jsonb_build_array(
      pg_temp.tick(gen_random_uuid(), pg_temp.k('p:r1:2')) || jsonb_build_object('kind', 'pen', 'points', '[[0.1, 0.1], [0.2]]'::jsonb)))),
    pg_temp.code(public.marking_save(pg_temp.k('mk:r1'), pg_temp.rev('mk:r1'), jsonb_build_array(
      pg_temp.tick(gen_random_uuid(), pg_temp.k('p:r1:2')) || jsonb_build_object('kind', 'pen', 'points', '[["a", 0.1]]'::jsonb)))),
    pg_temp.code(public.marking_save(pg_temp.k('mk:r1'), pg_temp.rev('mk:r1'), jsonb_build_array(
      pg_temp.tick(gen_random_uuid(), pg_temp.k('p:r1:2')) || jsonb_build_object('kind', 'pen', 'points', '[0.1, 0.2]'::jsonb)))),
    pg_temp.code(public.marking_save(pg_temp.k('mk:r1'), pg_temp.rev('mk:r1'), jsonb_build_array(
      pg_temp.tick(gen_random_uuid(), pg_temp.k('p:r1:2')) || jsonb_build_object('kind', 'pen', 'points', '{"x": 0.1}'::jsonb))))],
  array['invalid_input', 'invalid_input', 'invalid_input', 'invalid_input', 'invalid_input', 'invalid_input', 'invalid_input', 'invalid_input'],
  'a note of 1,001 characters, a text of 501, a mark off the page, and points that are not pairs of numbers are refused');
select is(pg_temp.code(public.marking_save(pg_temp.k('mk:r1'), pg_temp.rev('mk:r1'), jsonb_build_array(jsonb_build_object('op', 'note', 'text', repeat('n', 1000))))),
  'ok', 'a note of 1,000 characters is taken');
select is(pg_temp.code(public.marking_save(pg_temp.k('mk:r1'), pg_temp.rev('mk:r1'), jsonb_build_array(
    pg_temp.tick(pg_temp.k('ann_text'), pg_temp.k('p:r1:2')) || jsonb_build_object('kind', 'text', 'text', repeat('t', 500))))),
  'ok', 'and a text of 500');
select tests.as_postgres();
select is((select array[char_length(m.lead_note), (select char_length(a.text) from public.page_annotations a where a.id = pg_temp.k('ann_text'))]
           from public.markings m where m.id = pg_temp.k('mk:r1')),
  array[1000, 500], 'both are stored whole');
-- Any other error during the operations is raised again, not answered as a code (a trigger here, dropped after).
create function public.zz_test_boom() returns trigger language plpgsql as $$ begin raise exception 'boom'; end $$;
create trigger zz_test_boom before insert on public.page_annotations for each row execute function public.zz_test_boom();
select tests.as_user(pg_temp.uid('m1'));
select throws_ok(format('select public.marking_save(%L, %s, %L)', pg_temp.k('mk:r1'), pg_temp.rev('mk:r1'),
                        jsonb_build_array(pg_temp.tick(gen_random_uuid(), pg_temp.k('p:r1:2')))),
  'P0001', 'boom', 'an error that is not a refusal of an operation is raised, not answered as a code');
select tests.as_postgres();
drop trigger zz_test_boom on public.page_annotations;
drop function public.zz_test_boom();

-- ---------------------------------------------------------------------------------------------
-- submit_needs_every_question
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('sub_missing', public.marking_submit(pg_temp.k('mk:a1'), 14));
select tests.as_postgres();
select is(pg_temp.r('sub_missing'), '{"ok": false, "code": "incomplete", "missing": ["2(b)"]}'::jsonb,
  'submit_needs_every_question: a piece with a question without a mark or NR is not submitted, and the question is named');
select is(array[(select status from public.markings where id = pg_temp.k('mk:a1')), pg_temp.us('a1'),
                (select count(*)::text from public.marking_assignments a where a.unit_id = pg_temp.u('a1') and a.ended_at is null)],
  array['in_progress', 'taken', '1'], 'nothing changes: m1 still holds it');

-- ---------------------------------------------------------------------------------------------
-- submit_sets_script_marked_when_all_units_done
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.code(public.marking_save(pg_temp.k('mk:a1'), 14, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:2(b)'), null, true)))), 'ok',
  'submit_sets_script_marked_when_all_units_done: m1 gives 2(b) NR');
insert into res values ('sub_stale', public.marking_submit(pg_temp.k('mk:a1'), 14));
insert into res values ('sub_a1', public.marking_submit(pg_temp.k('mk:a1'), 15));
-- Screen B, still at rev 15, saves after screen A submitted.
insert into res values ('b_after_submit', public.marking_save(pg_temp.k('mk:a1'), 15, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 1))));
insert into res values ('b_after_submit_reason', public.marking_save(pg_temp.k('mk:a1'), 15, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 1)), 0,
  'Screen B change'));
insert into res values ('sub_again', public.marking_submit(pg_temp.k('mk:a1'), 16));
select tests.as_postgres();
select is(pg_temp.r('sub_stale'), '{"ok": false, "code": "conflict", "reason": "rev", "rev": 15}'::jsonb, 'a submit from a stale screen is refused');
select is(pg_temp.r('sub_a1'), '{"ok": true, "rev": 16, "total": 4, "max_total": 10, "script_state": "marked"}'::jsonb,
  'the piece is submitted: 4 out of 10, and its script (one piece) is marked; the rev moves on');
select is(array[pg_temp.r('b_after_submit'), pg_temp.r('b_after_submit_reason')],
  array['{"ok": false, "code": "conflict", "reason": "rev", "rev": 16}', '{"ok": false, "code": "conflict", "reason": "rev", "rev": 16}']::jsonb[],
  'a second screen still at the old rev is told to reload, with or without a reason, and changes nothing');
select is((select array[m.status, (m.submitted_at = now())::text, m.structure_version::text, coalesce(m.pages_changed_at::text, 'null'), m.total::text]
           from public.markings m where m.id = pg_temp.k('mk:a1')),
  array['submitted', 'true', '0', 'null', '4.0'], 'the marking is submitted, with the structure version and the total');
select is((select array[a.end_reason, (a.ended_at = now())::text] from public.marking_assignments a where a.unit_id = pg_temp.u('a1')),
  array['submitted', 'true'], 'm1''s hold ends');
select is(array[pg_temp.us('a1'), pg_temp.st('a1')], array['submitted', 'marked'], 'the piece is submitted and the script marked');
select is((select count(*)::int from public.audit_log a where a.action = 'marking_submitted' and a.target_type = 'marking'
             and a.target_id = pg_temp.k('mk:a1') and a.actor_id = pg_temp.uid('m1')), 1, 'an audit row says who submitted it');
select is(pg_temp.r('sub_again'), '{"ok": false, "code": "conflict", "reason": "submitted"}'::jsonb, 'a second submit is refused');
-- By question: G1 (m2), then G2 (m1).
select tests.as_user(pg_temp.uid('m2'));
select is(pg_temp.code(public.marking_save(pg_temp.k('mk:g1/G1'), 0, jsonb_build_array(pg_temp.mk(pg_temp.k('q:eq:1'), 2)))), 'ok', 'm2 marks G1');
insert into res values ('sub_g1', public.marking_submit(pg_temp.k('mk:g1/G1'), 1));
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.code(public.marking_save(pg_temp.k('mk:g1/G2'), 0, jsonb_build_array(pg_temp.mk(pg_temp.k('q:eq:2(a)'), 1),
                                                                                         pg_temp.mk(pg_temp.k('q:eq:2(b)'), 4)))), 'ok', 'm1 marks G2');
insert into res values ('sub_g2', public.marking_submit(pg_temp.k('mk:g1/G2'), 1));
select tests.as_postgres();
select is(pg_temp.r('sub_g1'), '{"ok": true, "rev": 2, "total": 2, "max_total": 3, "script_state": "marking"}'::jsonb,
  'by question, the script is still being marked after the first group is submitted');
select is(pg_temp.r('sub_g2'), '{"ok": true, "rev": 2, "total": 5, "max_total": 7, "script_state": "marked"}'::jsonb, 'and marked after the last');
select is(pg_temp.st('g1'), 'marked', 'the script is marked');

-- ---------------------------------------------------------------------------------------------
-- change_after_submit_needs_reason_and_keeps_history
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('open_sub', public.marking_unit_open(pg_temp.u('a1')));
select is(array[pg_temp.code(public.marking_save(pg_temp.k('mk:a1'), 16, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 2)))),
                pg_temp.code(public.marking_save(pg_temp.k('mk:a1'), 16, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 2)), 0, '  ok '))],
  array['reason_required', 'reason_required'], 'change_after_submit_needs_reason_and_keeps_history: a change after submit needs a reason of 3 to 300 characters');
insert into res values ('changed', public.marking_save(pg_temp.k('mk:a1'), 16, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 2)), 0,
  '  Misread the working  '));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('open_sub')), pg_temp.r('open_sub') -> 'marking' ->> 'status', pg_temp.r('open_sub') -> 'unit' ->> 'hold_until',
                pg_temp.r('open_sub') -> 'unit' ->> 'closed'],
  array['ok', 'submitted', null, 'false'], 'the marker opens their submitted piece, with no hold');
select is(pg_temp.r('changed'), jsonb_build_object('ok', true, 'rev', 17, 'total', 3, 'hold_until', null), 'with a reason the change is saved');
select is(array[(select status from public.markings where id = pg_temp.k('mk:a1')), pg_temp.marks('mk:a1'), pg_temp.us('a1'), pg_temp.st('a1')],
  array['submitted', '1=2,2(a)=1,2(b)=NR', 'submitted', 'marked'], 'the marking stays submitted and the script marked');
select is((select array[trim_scale(h.mark)::text, h.after_submit::text, h.reason, (h.changed_by = pg_temp.uid('m1'))::text]
           from public.question_mark_history h where h.marking_id = pg_temp.k('mk:a1') and h.question_id = pg_temp.k('q:e:1')
           order by h.id desc limit 1),
  array['2', 'true', 'Misread the working', 'true'], 'its history row says after submit, and why');
select is((select count(*)::int from public.audit_log a where a.action = 'marking_changed_after_submit' and a.target_type = 'marking'
             and a.target_id = pg_temp.k('mk:a1') and a.actor_id = pg_temp.uid('m1') and a.reason = 'Misread the working'), 1,
  'an audit row records the change and its reason');
-- m2, who submitted G1, is now blocked for its candidate.
insert into public.marker_conflicts (marker_id, student_id, recorded_at) values (pg_temp.uid('m2'), pg_temp.student('g1'), now());
select tests.as_user(pg_temp.uid('m2'));
select is(array[pg_temp.code(public.marking_unit_open(pg_temp.u('g1/G1'))),
                pg_temp.code(public.marking_save(pg_temp.k('mk:g1/G1'), 2, jsonb_build_array(pg_temp.mk(pg_temp.k('q:eq:1'), 1)), 0, 'Second look'))],
  array['forbidden', 'forbidden'], 'a marker since blocked for the candidate can neither open nor change a piece they submitted');
select tests.as_postgres();
delete from public.marker_conflicts where marker_id = pg_temp.uid('m2');

-- ---------------------------------------------------------------------------------------------
-- change_after_submit_cannot_leave_a_question_empty
-- ---------------------------------------------------------------------------------------------
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('empty', public.marking_save(pg_temp.k('mk:a1'), 17, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:2(b)'), null, false)), 0,
  'Not sure about 2(b)'));
insert into res values ('refill', public.marking_save(pg_temp.k('mk:a1'), 17, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:2(b)'), null, false),
  pg_temp.mk(pg_temp.k('q:e:2(b)'), 1.5)), 0, 'Read 2(b) again'));
select tests.as_postgres();
select is(pg_temp.r('empty'), '{"ok": false, "code": "incomplete", "missing": ["2(b)"]}'::jsonb,
  'change_after_submit_cannot_leave_a_question_empty: clearing a question of a submitted piece is refused');
select is(array[pg_temp.code(pg_temp.r('refill')), pg_temp.marks('mk:a1')], array['ok', '1=2,2(a)=1,2(b)=1.5'],
  'what counts is the piece after all the operations');

-- ---------------------------------------------------------------------------------------------
-- nothing_changes_after_marking_closes: exam ec; m1 holds c1 (in progress) and has submitted c2.
-- ---------------------------------------------------------------------------------------------
insert into kv values ('ec', tests.marking_exam(pg_temp.subj()));
select pg_temp.structure('ec');
select pg_temp.script('c1', 'ec');
select pg_temp.script('c2', 'ec');
select pg_temp.open('ec');
select pg_temp.take('c1', 'm1');
select pg_temp.take('c2', 'm1');
select tests.as_user(pg_temp.uid('m1'));
select public.marking_unit_open(pg_temp.u('c1'));
select public.marking_unit_open(pg_temp.u('c2'));
select tests.as_postgres();
select pg_temp.keep('c1', 'm1');
select pg_temp.keep('c2', 'm1');
select tests.as_user(pg_temp.uid('m1'));
select is(array[pg_temp.code(public.marking_save(pg_temp.k('mk:c1'), 0, jsonb_build_array(pg_temp.mk(pg_temp.k('q:ec:1'), 1)))),
                pg_temp.code(public.marking_save(pg_temp.k('mk:c2'), 0, jsonb_build_array(pg_temp.mk(pg_temp.k('q:ec:1'), 3),
                  pg_temp.mk(pg_temp.k('q:ec:2(a)'), 2), pg_temp.mk(pg_temp.k('q:ec:2(b)'), 5)))),
                pg_temp.code(public.marking_submit(pg_temp.k('mk:c2'), 1))],
  array['ok', 'ok', 'ok'], 'nothing_changes_after_marking_closes: m1 marks c1 and submits c2');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_close(pg_temp.k('ec'), 'All marks are in')), 'ok', 'an admin closes marking');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m1'));
select is(array[pg_temp.code(public.marking_unit_open(pg_temp.u('c1'))),
                pg_temp.code(public.marking_save(pg_temp.k('mk:c1'), 1, jsonb_build_array(pg_temp.mk(pg_temp.k('q:ec:1'), 2)))),
                pg_temp.code(public.marking_submit(pg_temp.k('mk:c1'), 1)),
                pg_temp.code(public.marking_save(pg_temp.k('mk:c2'), 2, jsonb_build_array(pg_temp.mk(pg_temp.k('q:ec:1'), 2)), 0, 'One more look'))],
  array['marking_closed', 'marking_closed', 'marking_closed', 'marking_closed'],
  'a piece in progress can no longer be opened, saved or submitted, and a submitted one can no longer change');
insert into res values ('open_closed', public.marking_unit_open(pg_temp.u('c2')));
select tests.as_postgres();
select is(array[pg_temp.code(pg_temp.r('open_closed')), pg_temp.r('open_closed') -> 'unit' ->> 'closed', pg_temp.r('open_closed') -> 'marking' ->> 'status',
                jsonb_array_length(pg_temp.r('open_closed') -> 'marks')::text],
  array['ok', 'true', 'submitted', '3'], 'a submitted piece still opens, read only, saying marking has closed');
select is(array[pg_temp.marks('mk:c1'), pg_temp.rev('mk:c1')::text, pg_temp.marks('mk:c2'), pg_temp.rev('mk:c2')::text,
                (select status from public.markings where id = pg_temp.k('mk:c1'))],
  array['1=1', '1', '1=3,2(a)=2,2(b)=5', '2', 'in_progress'], 'nothing changed');

-- ---------------------------------------------------------------------------------------------
-- total_counts_best_of_optional_questions: exam eo has question 1 (4 marks) and "Answer 1 of" questions 2 and 3 (6
-- marks each).
-- ---------------------------------------------------------------------------------------------
insert into kv values ('eo', tests.marking_exam(pg_temp.subj()));
insert into public.exam_option_groups (exam_id, label, choose) values (pg_temp.k('eo'), 'Section B', 1);
insert into public.exam_questions (exam_id, label, position, max_mark, option_group_id)
select pg_temp.k('eo'), q.label, q.position, q.max_mark, case when q.position > 1 then o.id end
from (values ('1', 1, 4), ('2', 2, 6), ('3', 3, 6)) q(label, position, max_mark)
cross join public.exam_option_groups o where o.exam_id = pg_temp.k('eo');
insert into kv select 'q:eo:' || q.label, q.id from public.exam_questions q where q.exam_id = pg_temp.k('eo');
select pg_temp.script('o1', 'eo');
select pg_temp.open('eo');
select pg_temp.take('o1', 'm1');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('open_o1', public.marking_unit_open(pg_temp.u('o1')));
select tests.as_postgres();
select pg_temp.keep('o1', 'm1');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('s_o1', public.marking_save(pg_temp.k('mk:o1'), 0, jsonb_build_array(pg_temp.mk(pg_temp.k('q:eo:1'), 3),
  pg_temp.mk(pg_temp.k('q:eo:2'), 2), pg_temp.mk(pg_temp.k('q:eo:3'), 5))));
select tests.as_postgres();
select is(pg_temp.r('open_o1') -> 'marking' -> 'max_total', '10'::jsonb, 'total_counts_best_of_optional_questions: the piece is out of 4 + 6');
select is((select jsonb_agg(o - 'id') from jsonb_array_elements(pg_temp.r('open_o1') -> 'structure' -> 'option_groups') o),
  '[{"label": "Section B", "choose": 1}]'::jsonb, 'the optional questions are shown with how many to answer');
select is(pg_temp.r('s_o1') -> 'total', '8'::jsonb, 'marks 3, 2 and 5 total 8: the better of the optional questions counts');
select is(public.marking_total(pg_temp.k('mk:o1')), 8.0, 'marking_total says the same');
-- Exam eg is marked by question: G1 is question 1 (4 marks); G2 holds "Answer 1 of" questions 2 and 3 (6 marks each).
insert into kv values ('eg', tests.marking_exam(pg_temp.subj()));
insert into public.question_groups (exam_id, label, position) values (pg_temp.k('eg'), 'G1', 1), (pg_temp.k('eg'), 'G2', 2);
insert into public.exam_option_groups (exam_id, label, choose) values (pg_temp.k('eg'), 'Section B', 1);
insert into public.exam_questions (exam_id, label, position, max_mark, group_id, option_group_id)
select pg_temp.k('eg'), q.label, q.position, q.max_mark, g.id, case when q.position > 1 then o.id end
from (values ('1', 1, 4, 'G1'), ('2', 2, 6, 'G2'), ('3', 3, 6, 'G2')) q(label, position, max_mark, grp)
join public.question_groups g on g.exam_id = pg_temp.k('eg') and g.label = q.grp
cross join public.exam_option_groups o where o.exam_id = pg_temp.k('eg');
insert into kv select 'q:eg:' || q.label, q.id from public.exam_questions q where q.exam_id = pg_temp.k('eg');
insert into public.exam_marking (exam_id, mode) values (pg_temp.k('eg'), 'by_question');
select pg_temp.script('gb1', 'eg');
select pg_temp.open('eg');
select pg_temp.take('gb1/G2', 'm1');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('open_gb2', public.marking_unit_open(pg_temp.u('gb1/G2')));
select tests.as_postgres();
select pg_temp.keep('gb1/G2', 'm1');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('s_gb2', public.marking_save(pg_temp.k('mk:gb1/G2'), 0, jsonb_build_array(pg_temp.mk(pg_temp.k('q:eg:2'), 2),
  pg_temp.mk(pg_temp.k('q:eg:3'), 5))));
select tests.as_postgres();
select is(pg_temp.r('open_gb2') -> 'marking' -> 'max_total', '6'::jsonb, 'a question group holding "Answer 1 of" two questions is out of one of them');
select is(array[pg_temp.r('s_gb2') -> 'total', to_jsonb(public.marking_total(pg_temp.k('mk:gb1/G2')))], array['5', '5']::jsonb[],
  'and marks 2 and 5 total 5: the better one counts');

-- ---------------------------------------------------------------------------------------------
-- open_and_save_refused_while_remask_queued_or_running: m1 holds a4.
-- ---------------------------------------------------------------------------------------------
select pg_temp.script('a4', 'e');
select pg_temp.open('e');
select pg_temp.take('a4', 'm1');
select tests.as_user(pg_temp.uid('m1'));
select public.marking_unit_open(pg_temp.u('a4'));
select tests.as_postgres();
select pg_temp.keep('a4', 'm1');
select pg_temp.put(pg_temp.paths('a4', 'marking'));
insert into public.processing_jobs (upload_id, kind, state) values (pg_temp.upload('a4'), 'remask', 'queued');
select tests.as_user(pg_temp.uid('m1'));
select is(array[pg_temp.code(public.marking_unit_open(pg_temp.u('a4'))),
                pg_temp.code(public.marking_save(pg_temp.k('mk:a4'), 0, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 1)))),
                pg_temp.code(public.marking_submit(pg_temp.k('mk:a4'), 0)),
                pg_temp.got(pg_temp.paths('a4', 'marking'))::text],
  array['pictures_updating', 'pictures_updating', 'pictures_updating', '0'],
  'open_and_save_refused_while_remask_queued_or_running: while a remask of its file waits, the piece cannot be opened, saved or submitted, nor its pictures read');
select tests.as_postgres();
update public.processing_jobs set state = 'running', locked_by = 'w1', locked_at = now() where upload_id = pg_temp.upload('a4') and kind = 'remask';
select tests.as_user(pg_temp.uid('m1'));
select is(array[pg_temp.code(public.marking_unit_open(pg_temp.u('a4'))),
                pg_temp.code(public.marking_save(pg_temp.k('mk:a4'), 0, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 1)))),
                pg_temp.got(pg_temp.paths('a4', 'marking'))::text],
  array['pictures_updating', 'pictures_updating', '0'], 'nor while it runs');
select tests.as_postgres();
update public.processing_jobs set state = 'done', finished_at = now(), locked_by = null, locked_at = null
where upload_id = pg_temp.upload('a4') and kind = 'remask';
select tests.as_user(pg_temp.uid('m1'));
select is(array[pg_temp.code(public.marking_unit_open(pg_temp.u('a4'))),
                pg_temp.code(public.marking_save(pg_temp.k('mk:a4'), 0, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 1)))),
                pg_temp.got(pg_temp.paths('a4', 'marking'))::text],
  array['ok', 'ok', '3'], 'once it is done, marking carries on');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- marker_reads_only_marking_pictures_of_a_held_piece: m1 holds p1 by Next script (not opened yet); m2 holds a3.
-- ---------------------------------------------------------------------------------------------
select pg_temp.script('p1', 'e');
select pg_temp.open('e');
select pg_temp.take('p1', 'm1');
select pg_temp.put(pg_temp.paths('p1', 'marking') || pg_temp.paths('p1', 'full') || pg_temp.paths('a3', 'marking') || pg_temp.paths('a1', 'marking')
                   || pg_temp.paths('r1', 'marking') || pg_temp.paths('c2', 'marking')
                   || array[pg_temp.path('x1_extra'), pg_temp.path('x1_unconfirmed')]);
select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.got(pg_temp.paths('p1', 'marking')), 3, 'marker_reads_only_marking_pictures_of_a_held_piece: the holder reads each marking picture of the piece');
insert into res values ('p1_all', public.marking_picture_paths(pg_temp.u('p1'), array[pg_temp.k('p:p1:1'), pg_temp.k('p:p1:2'), pg_temp.k('p:p1:3')]));
select is(array[pg_temp.code(pg_temp.r('p1_all')),
                (select count(*)::text from jsonb_array_elements(pg_temp.r('p1_all') -> 'paths') x where x ->> 'marking_path' = any (pg_temp.paths('p1', 'full')))],
  array['ok', '0'], 'never a full picture: asked for every page of the piece, it gives none of their full pictures');
select is(pg_temp.got(pg_temp.paths('a3', 'marking')), 0, 'nor another script''s marking picture');
select is(array[public.marking_picture_paths(pg_temp.u('p1'), array[pg_temp.k('p:p1:1')]) -> 'paths' -> 0 ->> 'marking_path',
                pg_temp.code(public.marking_picture_paths(pg_temp.u('p1'), null))],
  array[(pg_temp.paths('p1', 'marking'))[1], 'invalid_input'], 'marking_picture_paths says the same');
select is(pg_temp.got(pg_temp.paths('a1', 'marking')), 3, 'the marker of a submitted piece still reads its marking pictures');
select is(pg_temp.got(pg_temp.paths('r1', 'marking')), 2, 'only those of the pages shown: not a cover, an information page, a blank page or a refused page');
select is(array[pg_temp.got(array[pg_temp.path('x1_extra')]), pg_temp.got(array[pg_temp.path('x1_unconfirmed')])], array[1, 0],
  'a confirmed extra page, not an unconfirmed one');
select is(pg_temp.got(pg_temp.paths('c2', 'marking')), 0, 'none once marking has closed');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m2'));
select is(array[pg_temp.got(pg_temp.paths('a3', 'marking')), pg_temp.got(pg_temp.paths('p1', 'marking'))], array[3, 0],
  'm2 reads the piece an admin assigned them, not m1''s');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('corr'));
select is(pg_temp.got(pg_temp.paths('p1', 'marking') || pg_temp.paths('a1', 'marking') || pg_temp.paths('a3', 'marking')), 0,
  'a corrector with no hold reads none');
select tests.as_postgres();
update public.marking_units set on_hold = true, hold_reason = 'picture_changed' where id in (pg_temp.u('a1'), pg_temp.u('a4'));
select tests.as_user(pg_temp.uid('m1'));
select is(array[pg_temp.got(pg_temp.paths('a1', 'marking'))::text, pg_temp.code(public.marking_unit_open(pg_temp.u('a1')))], array['0', 'on_hold'],
  'none of a piece on hold, which does not open either');
select is(array[pg_temp.code(public.marking_save(pg_temp.k('mk:a1'), pg_temp.rev('mk:a1'), jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 3)), 0, 'Another look')),
                pg_temp.code(public.marking_save(pg_temp.k('mk:a4'), pg_temp.rev('mk:a4'), jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 2)))),
                pg_temp.code(public.marking_submit(pg_temp.k('mk:a4'), pg_temp.rev('mk:a4')))],
  array['on_hold', 'on_hold', 'on_hold'], 'nor can a piece on hold be saved or submitted, submitted or in progress');
select tests.as_postgres();
update public.marking_units set on_hold = false, hold_reason = null where id in (pg_temp.u('a1'), pg_temp.u('a4'));
select is(array[pg_temp.marks('mk:a1'), pg_temp.marks('mk:a4')], array['1=2,2(a)=1,2(b)=1.5', '1=1'], 'their marks are as they were');
-- An admin takes back m1's piece a4.
select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.code(public.marking_take_back(array[pg_temp.u('a4')], 'Needs a fresh marker')), 'ok', 'an admin takes back a4');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.got(pg_temp.paths('a4', 'marking')), 0, 'm1 reads none of a piece taken back from them');
select tests.as_postgres();
-- m2 submitted g1's G1; then a conflict with its candidate is declared.
select pg_temp.put(pg_temp.paths('g1', 'marking'));
select tests.as_user(pg_temp.uid('m2'));
select is(pg_temp.got(pg_temp.paths('g1', 'marking')), 3, 'm2 reads the pictures of the piece they submitted');
select tests.as_postgres();
insert into public.marker_conflicts (marker_id, student_id, recorded_at) values (pg_temp.uid('m2'), pg_temp.student('g1'), now());
select tests.as_user(pg_temp.uid('m2'));
select is(pg_temp.got(pg_temp.paths('g1', 'marking')), 0, 'none once a conflict with its candidate is declared');
select tests.as_postgres();
delete from public.marker_conflicts where marker_id = pg_temp.uid('m2');
update public.marking_assignments set hold_until = now() - interval '1 minute' where unit_id = pg_temp.u('p1') and ended_at is null;
select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.got(pg_temp.paths('p1', 'marking')), 0, 'none once the hold has run out');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('admin'));
select is(pg_temp.seen(pg_temp.paths('p1', 'marking') || pg_temp.paths('p1', 'full')), 6, 'staff still read every picture (their policy is unchanged)');
select tests.as_postgres();
-- m1 holds s1 and has saved a mark; their hold ends, as the minute job ends it (this piece only); then m2 takes the free
-- piece, which sets m1's marking aside.
select pg_temp.script('s1', 'e');
select pg_temp.open('e');
select pg_temp.take('s1', 'm1');
select tests.as_user(pg_temp.uid('m1'));
select public.marking_unit_open(pg_temp.u('s1'));
select tests.as_postgres();
select pg_temp.keep('s1', 'm1');
select pg_temp.put(pg_temp.paths('s1', 'marking'));
select tests.as_user(pg_temp.uid('m1'));
select is(array[pg_temp.code(public.marking_save(pg_temp.k('mk:s1'), 0, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 1)))),
                pg_temp.got(pg_temp.paths('s1', 'marking'))::text],
  array['ok', '3'], 'm1 saves on s1 and reads its pictures');
select tests.as_postgres();
update public.marking_assignments set ended_at = now(), end_reason = 'expired' where unit_id = pg_temp.u('s1') and ended_at is null;
update public.marking_units set state = 'open' where id = pg_temp.u('s1');
select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.got(pg_temp.paths('s1', 'marking')), 0, 'once the hold has ended, with the marking still in progress, m1 reads none');
select tests.as_postgres();
select pg_temp.take('s1', 'm2');
select tests.as_user(pg_temp.uid('m1'));
insert into res values ('aside_save', public.marking_save(pg_temp.k('mk:s1'), 1, jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 2))));
insert into res values ('aside_submit', public.marking_submit(pg_temp.k('mk:s1'), 1));
select tests.as_postgres();
select is(array[pg_temp.r('aside_save'), pg_temp.r('aside_submit')],
  array['{"ok": false, "code": "conflict", "reason": "set_aside"}', '{"ok": false, "code": "conflict", "reason": "set_aside"}']::jsonb[],
  'once m2 has taken the free piece, m1''s set-aside marking can be neither saved nor submitted');
select is(array[(select m.status || ' ' || m.set_aside_reason from public.markings m where m.id = pg_temp.k('mk:s1')), pg_temp.marks('mk:s1'),
                pg_temp.rev('mk:s1')::text],
  array['set_aside expired', '1=1', '1'], 'it is kept as it was');
select tests.as_user(pg_temp.uid('m2'));
select is(pg_temp.got(pg_temp.paths('s1', 'marking')), 3, 'm2, who holds it now, reads its pictures');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- old_marking_path_not_readable (Review Focus 5)
-- ---------------------------------------------------------------------------------------------
update public.marking_assignments set hold_until = now() + interval '1 hour' where unit_id = pg_temp.u('p1') and ended_at is null;
insert into res select 'old_paths', to_jsonb(pg_temp.paths('p1', 'marking'));
update public.script_pages set replaced_at = now() where id = pg_temp.k('p:p1:2');
select tests.as_user(pg_temp.uid('m1'));
select is(array[pg_temp.code(public.marking_picture_paths(pg_temp.u('p1'), array[pg_temp.k('p:p1:2')])), pg_temp.got(array[pg_temp.r('old_paths') ->> 0])::text],
  array['forbidden', '1'], 'old_marking_path_not_readable: the picture of a page a rerun replaced cannot be read; the piece''s other pages still can');
select tests.as_postgres();
update public.script_pages set marking_path = replace(marking_path, '-marking.jpg', '-remask-marking.jpg') where id = pg_temp.k('p:p1:1');
select pg_temp.put(array[pg_temp.path('p:p1:1')]);
select tests.as_user(pg_temp.uid('m1'));
select is(public.marking_picture_paths(pg_temp.u('p1'), array[pg_temp.k('p:p1:1')]) -> 'paths' -> 0 ->> 'marking_path', pg_temp.path('p:p1:1'),
  'once a page''s marking picture changes, the old one cannot be read: asked for the page, marking_picture_paths gives the new one');
-- Task 7: this picture was made again from the same inputs (no hidden area or turn changed), so the piece is not held
-- and its holder reads the new picture.
select is(pg_temp.got(array[pg_temp.path('p:p1:1')]), 1, 'the new one, made again from the same inputs, can be read');
select tests.as_postgres();
select is((select on_hold from public.marking_units where id = pg_temp.u('p1')), false,
  'the piece is not on hold: what the picture hides did not change');

-- ---------------------------------------------------------------------------------------------
-- student_and_parent_read_no_marking_table_or_picture: a1's candidate and a parent of theirs; and a marker reads no
-- marking table either.
-- ---------------------------------------------------------------------------------------------
insert into public.parent_children values (pg_temp.uid('par'), pg_temp.student('a1'));
insert into c values ('stu', pg_temp.student('a1'));
create function pg_temp.rows() returns int language sql stable as $$
  select ((select count(*) from public.markings) + (select count(*) from public.question_marks) + (select count(*) from public.question_mark_history)
        + (select count(*) from public.page_annotations) + (select count(*) from public.marking_units) + (select count(*) from public.marking_assignments)
        + (select count(*) from public.exam_questions) + (select count(*) from public.marking_alerts))::int $$;
grant execute on function pg_temp.rows() to public;
select tests.as_user(pg_temp.uid('stu'));
select is(array[pg_temp.rows(), pg_temp.seen(pg_temp.paths('a1', 'marking') || pg_temp.paths('a1', 'full'))], array[0, 0],
  'student_and_parent_read_no_marking_table_or_picture: the candidate reads no marking row and no picture of their script');
select is(array[pg_temp.code(public.marking_unit_open(pg_temp.u('a1'))),
                pg_temp.code(public.marking_save(pg_temp.k('mk:a1'), pg_temp.rev('mk:a1'), jsonb_build_array(pg_temp.mk(pg_temp.k('q:e:1'), 3)), 0, 'Give me the marks')),
                pg_temp.code(public.marking_submit(pg_temp.k('mk:a1'), pg_temp.rev('mk:a1'))),
                pg_temp.code(public.marking_picture_paths(pg_temp.u('a1'), array[pg_temp.k('p:a1:1')]))],
  array['forbidden', 'forbidden', 'forbidden', 'forbidden'], 'nor opens, saves or submits it');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('par'));
select is(array[pg_temp.rows(), pg_temp.seen(pg_temp.paths('a1', 'marking') || pg_temp.paths('a1', 'full'))], array[0, 0],
  'their parent reads none either');
select is(array[pg_temp.code(public.marking_unit_open(pg_temp.u('a1'))), pg_temp.code(public.marking_picture_paths(pg_temp.u('a1'), array[pg_temp.k('p:a1:1')]))],
  array['forbidden', 'forbidden'], 'nor opens it');
select tests.as_postgres(); select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.rows(), 0, 'a marker reads no marking table: only through the functions');
select tests.as_postgres();
select is(pg_temp.marks('mk:a1'), '1=2,2(a)=1,2(b)=1.5', 'nothing changed');

-- ---------------------------------------------------------------------------------------------
-- Privileges and the storage policies.
-- ---------------------------------------------------------------------------------------------
select is(array(select f from unnest(array[
    'public.marking_script_pages(uuid)', 'public.marking_pages_key(uuid)', 'public.marking_unit_questions(uuid)',
    'public.marking_unit_max_total(uuid)', 'public.marking_total(uuid)', 'public.marking_work_blocked(uuid, uuid, timestamptz)',
    'public.marking_ops_apply(uuid, uuid, uuid, jsonb, uuid, boolean, text)', 'public.marking_missing(uuid, uuid)']) f
  where has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute')
     or has_function_privilege('service_role', f, 'execute')), '{}'::text[],
  'the internal functions cannot be called from the API, nor by the service role');
select is(array(select f from unnest(array[
    'public.marking_unit_open(uuid, timestamptz)', 'public.marking_save(uuid, integer, jsonb, integer, text, timestamptz)',
    'public.marking_submit(uuid, integer, timestamptz)', 'public.marking_picture_paths(uuid, uuid[], timestamptz)']) f
  where has_function_privilege('anon', f, 'execute') or not has_function_privilege('authenticated', f, 'execute')), '{}'::text[],
  'the others are for signed-in users only');
select is((select array_agg(p.policyname::text order by p.policyname) from pg_policies p
           where p.schemaname = 'storage' and p.tablename = 'objects' and p.policyname like 'script_pages_objects%'),
  array['script_pages_objects_select'], 'the staff policy on script-pages is kept; markers have none (3B, Ruling R12)');

select * from finish();
rollback;
