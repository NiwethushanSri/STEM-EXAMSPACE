begin;
create extension if not exists pgtap with schema extensions;
select plan(19);
select tests.assert_no_owner();

-- ---------------------------------------------------------------------------------------------
-- Final review I1: the mark scheme PDF is closed to markers until marking opens.
-- Fixtures. Subject 'ZZ Scheme access': teacher teaches it, lead leads it, m1 and m2 are approved correctors. Exam e
-- (tests.marking_exam) has the test structure, two verified home scripts and a stored mark scheme PDF; exam e_next of
-- the same subject has a stored PDF too and its marking never opens. The files are written directly, as postgres.
-- ---------------------------------------------------------------------------------------------
create temp table c (name text primary key, id uuid not null);
grant select on c to public;
insert into c values
  ('admin', tests.create_user('admin', 'active')),
  ('teacher', tests.create_user('teacher', 'active')),
  ('lead', tests.create_user('corrector', 'active')),
  ('m1', tests.create_user('corrector', 'active')),
  ('m2', tests.create_user('corrector', 'active'));
create temp table kv (name text primary key, id uuid);
grant all on kv to public;
create temp table paths (name text primary key, path text);
grant select on paths to public;
create function pg_temp.uid(p text) returns uuid language sql stable as $$ select id from c where name = p $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from kv where name = p $$;
create function pg_temp.code(j jsonb) returns text language sql immutable as $$
  select case when (j ->> 'ok')::boolean then 'ok' else coalesce(j ->> 'code', 'none') end $$;
-- A stored mark scheme PDF of an exam, and its file in the bucket.
create function pg_temp.scheme(p_name text, p_exam text) returns void language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
  v_path text := pg_temp.k(p_exam)::text || '/' || v_id::text || '.pdf';
begin
  insert into public.exam_mark_scheme_files (id, exam_id, storage_path, byte_size, state, uploaded_by, uploaded_at)
  values (v_id, pg_temp.k(p_exam), v_path, 1000, 'stored', pg_temp.uid('teacher'), now());
  insert into storage.objects (bucket_id, name, metadata) values ('mark-schemes', v_path, '{"size": 1000, "mimetype": "application/pdf"}');
  insert into paths values (p_name, v_path);
end $$;
-- Who reads the PDF, of admin teacher lead m1 m2: through the storage policy (a list or a signed link asks it).
create function pg_temp.sees(p_file text) returns text language plpgsql as $$
declare
  v_out text := '';
  v_who text;
  v_n int;
begin
  foreach v_who in array array['admin', 'teacher', 'lead', 'm1', 'm2'] loop
    perform tests.as_user(pg_temp.uid(v_who));
    select count(*) into v_n from storage.objects o where o.bucket_id = 'mark-schemes' and o.name = (select path from paths where name = p_file);
    perform tests.as_postgres();
    if v_n > 0 then
      v_out := v_out || v_who || ' ';
    end if;
  end loop;
  return coalesce(nullif(btrim(v_out), ''), '-');
end $$;
grant execute on function pg_temp.uid(text), pg_temp.k(text), pg_temp.code(jsonb) to public;

insert into public.subjects (name, kind) values ('ZZ Scheme access', 'school');
insert into public.teacher_subjects (teacher_id, subject_id) select pg_temp.uid('teacher'), id from public.subjects where name = 'ZZ Scheme access';
insert into public.marker_approvals (marker_id, subject_id, lead, approved_at)
select c.id, (select id from public.subjects where name = 'ZZ Scheme access'), c.name = 'lead', now() from c where c.name in ('lead', 'm1', 'm2');
insert into kv values ('e', tests.marking_exam((select id from public.subjects where name = 'ZZ Scheme access'))),
                      ('e_next', tests.marking_exam((select id from public.subjects where name = 'ZZ Scheme access')));
-- e has no marking settings until the first case saves them: no exam_marking row (tests.marking_exam writes one).
delete from public.exam_marking where exam_id = pg_temp.k('e');
select tests.structure(pg_temp.k('e'));
insert into kv values ('a1', tests.verified_script(pg_temp.k('e'))), ('a2', tests.verified_script(pg_temp.k('e')));
select pg_temp.scheme('f', 'e');
select pg_temp.scheme('f_next', 'e_next');

-- ---------------------------------------------------------------------------------------------
-- marker_refused_before_marking_opens
-- ---------------------------------------------------------------------------------------------
select is(pg_temp.sees('f'), 'admin teacher',
  'marker_refused_before_marking_opens: with no marking settings, only the editors read the PDF; an approved corrector and the lead do not');
insert into public.exam_marking (exam_id, mode, double_marking, seeds, practice) values (pg_temp.k('e'), 'whole', false, false, false);
select is(pg_temp.sees('f'), 'admin teacher', 'nor with settings saved and marking not yet open');
select tests.as_user(pg_temp.uid('m1'));
select is((select count(*)::int from storage.objects where bucket_id = 'mark-schemes'), 0, 'a storage list shows the corrector no mark scheme at all');
select is(public.mark_scheme_path_allowed((select path from paths where name = 'f')), false, 'and the rule itself answers no');
select tests.as_postgres();

-- ---------------------------------------------------------------------------------------------
-- marker_reads_only_while_holding_a_piece_of_an_open_exam
-- ---------------------------------------------------------------------------------------------
update public.exam_marking set opened_at = now(), opened_by = pg_temp.uid('admin') where exam_id = pg_temp.k('e');
select public.marking_exam_sync(pg_temp.k('e'), null);
select is(pg_temp.sees('f'), 'admin teacher lead',
  'marker_reads_only_while_holding_a_piece_of_an_open_exam: once marking is open the lead reads it; a corrector who holds nothing does not');
select tests.as_user(pg_temp.uid('m1'));
insert into kv select 'u1', (public.marking_next(pg_temp.k('e')) ->> 'unit_id')::uuid;
select tests.as_postgres();
select isnt(pg_temp.k('u1'), null, 'm1 presses Next script and holds a piece');
select is(pg_temp.sees('f'), 'admin teacher lead m1', 'while m1 holds a piece they read the PDF; m2, who holds none, does not');
select is(pg_temp.sees('f_next'), 'admin teacher', 'the PDF of another exam of the subject, not yet open, stays closed to all of them');

-- A marking in progress whose hold ran out still reads it; set aside, it does not.
select tests.as_user(pg_temp.uid('m1'));
select is(pg_temp.code(public.marking_unit_open(pg_temp.k('u1'))), 'ok', 'm1 opens the piece (their marking starts)');
select tests.as_postgres();
update public.marking_assignments set ended_at = now(), end_reason = 'expired' where unit_id = pg_temp.k('u1') and ended_at is null;
update public.marking_units set state = 'open' where id = pg_temp.k('u1');
select is(pg_temp.sees('f'), 'admin teacher lead m1', 'with the hold ended, m1''s marking in progress still reads it');
update public.markings set status = 'set_aside', set_aside_at = now(), set_aside_reason = 'unapproved' where unit_id = pg_temp.k('u1');
select is(pg_temp.sees('f'), 'admin teacher lead', 'once that marking is set aside, m1 does not');
update public.markings set status = 'submitted', submitted_at = now(), set_aside_at = null, set_aside_reason = null where unit_id = pg_temp.k('u1');
update public.marking_units set state = 'submitted' where id = pg_temp.k('u1');
select is(pg_temp.sees('f'), 'admin teacher lead m1', 'a submitted marking reads it while marking is open');

-- A corrector no longer approved reads nothing, whatever they marked.
delete from public.marker_approvals where marker_id = pg_temp.uid('m1');
select is(pg_temp.sees('f'), 'admin teacher lead', 'a corrector whose approval was removed does not');
insert into public.marker_approvals (marker_id, subject_id, approved_at)
select pg_temp.uid('m1'), id, now() from public.subjects where name = 'ZZ Scheme access';
update public.profiles set status = 'suspended' where id = pg_temp.uid('lead');
select is(pg_temp.sees('f'), 'admin teacher m1', 'nor a suspended lead');
update public.profiles set status = 'active' where id = pg_temp.uid('lead');

-- ---------------------------------------------------------------------------------------------
-- everyone_but_editors_refused_after_close
-- ---------------------------------------------------------------------------------------------
update public.exam_marking set closed_at = now(), closed_by = pg_temp.uid('admin') where exam_id = pg_temp.k('e');
select is(pg_temp.sees('f'), 'admin teacher',
  'everyone_but_editors_refused_after_close: after marking closes, the lead and the corrector who marked read nothing; the editors still do');
update public.exam_marking set closed_at = null, closed_by = null where exam_id = pg_temp.k('e');
select is(pg_temp.sees('f'), 'admin teacher lead m1', 'reopened, they read it again');

-- A removed PDF: the stored-files rule is unchanged.
update public.exam_mark_scheme_files set state = 'removed', removed_at = now() where storage_path = (select path from paths where name = 'f');
select is(pg_temp.sees('f'), '-', 'a removed PDF is read by nobody');

-- ---------------------------------------------------------------------------------------------
-- Privileges: unchanged.
-- ---------------------------------------------------------------------------------------------
select is(array[has_function_privilege('anon', 'public.mark_scheme_path_allowed(text)', 'execute'),
                has_function_privilege('authenticated', 'public.mark_scheme_path_allowed(text)', 'execute')],
  array[false, true], 'the rule is for signed-in users only');
select is((select array[p.prosecdef::text, array_to_string(p.proconfig, ',')] from pg_proc p where p.oid = 'public.mark_scheme_path_allowed(text)'::regprocedure),
  array['true', 'search_path=""'], 'it is security definer with an empty search path');

select * from finish();
rollback;
