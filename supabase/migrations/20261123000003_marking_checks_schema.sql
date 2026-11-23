-- Phase 3B Task 2: the tables for checking the marking, an exam's check settings, the small-subject switches and the
-- opening rules they bring.
--
-- An exam's checks (exam_marking): double marking (a sample of pieces marked again by a second marker; 10% by default,
-- 1 to 100) with a tolerance (10% of the maximum by default, 1 to 50) beyond which the lead marker settles the
-- difference; seeded scripts (about one in every 10 pieces by default, 3 to 50); and practice before live marking. All
-- three are on unless an admin turns them off, which needs a reason and a subject with at most one approved active
-- marker (Builder's call 10); the reason is kept with who and when, and cleared once all three are on again. Once
-- marking has opened any change needs a reason. Every change writes an audit row saying what changed, with the reason.
-- approved_at and approved_by are for Task 10.
--
-- Each piece gets a stored random draw for the sample (sample_draw), whether a second marking is wanted (null: not
-- decided yet), its check state, when it was checked and the marking its final marks came from. A marking gets the
-- lead's note when sent back and when its feedback was shown. Assignments may also end paused, sent_back or
-- switched_off; a piece may be kept from a marker it was sent back from (exclusion reason sent_back).
--
-- New tables, written by later tasks' functions only:
--   exam_markers: a marker on an exam (cleared after practice, paused, seeded-script misses, pieces until the next seed);
--   marking_standards and marking_standard_marks: a practice or seeded piece and the lead's frozen marks for it;
--   marking_reviews: what the lead marker looks at (a difference, a paused marker's piece, the routine sample), one open
--     difference or paused-marker review per piece;
--   final_marks and final_mark_history: the final mark per question of a checked piece, kept apart from every marker's
--     own marks, and every final mark as it was set or removed.
-- Like every marking table they have row-level security with one select policy, staff admins only: markers and lead
-- markers read nothing directly.
--
-- Added:
--   marking_checks_get(p_exam): the exam's checks, for admins and the subject's lead marker.
--   marking_checks_set(p_exam, p_settings, p_reason): the exam's checks, for admins.
-- Changed: marking_open, from its latest definition (20261122000005). With double marking on it also needs two
-- approved active markers of the subject (needs_two_markers); with seeds or practice on, an active lead marker of the
-- subject (no_lead). Both come after its own structure_incomplete and no_markers. Nothing else in it changed.
--
-- Lock order (R9, R10), extended for Phase 3B: marker advisory key -> exam_marking -> booking advisory lock -> script
-- rows in id order -> units in id order -> assignments and markings -> marking_reviews -> final_marks ->
-- exam_markers. marking_checks_set takes the exam's structure lock and then its exam_marking row, as
-- marking_settings_set and marking_open do.

-- ---------------------------------------------------------------------------------------------
-- Columns.
-- ---------------------------------------------------------------------------------------------
alter table public.exam_marking
  add column double_marking boolean not null default true,
  add column sample_percent int not null default 10 check (sample_percent between 1 and 100),
  add column tolerance_percent int not null default 10 check (tolerance_percent between 1 and 50),
  add column seeds boolean not null default true,
  add column seed_every int not null default 10 check (seed_every between 3 and 50),
  add column practice boolean not null default true,
  add column checks_off_reason text,
  add column checks_off_by uuid,
  add column checks_off_at timestamptz,
  add column approved_at timestamptz,
  add column approved_by uuid;

alter table public.marking_units
  add column sample_draw double precision not null default random(),
  add column second_wanted boolean,
  add column check_state text check (check_state in ('waiting_second', 'to_lead', 'checked')),
  add column checked_at timestamptz,
  add column final_marking_id uuid references public.markings (id);

alter table public.markings
  add column sent_back_note text check (char_length(sent_back_note) <= 1000),
  add column feedback_at timestamptz;

alter table public.marking_assignments drop constraint marking_assignments_end_reason_check;
alter table public.marking_assignments add constraint marking_assignments_end_reason_check
  check (end_reason in ('submitted', 'expired', 'given_back', 'taken_back', 'name_seen', 'unapproved', 'conflict', 'withdrawn',
                        'paused', 'sent_back', 'switched_off'));
alter table public.marking_unit_exclusions drop constraint marking_unit_exclusions_reason_check;
alter table public.marking_unit_exclusions add constraint marking_unit_exclusions_reason_check
  check (reason in ('name_seen', 'sent_back'));

-- ---------------------------------------------------------------------------------------------
-- Tables.
-- ---------------------------------------------------------------------------------------------

-- A marker on an exam: cleared for live marking after practice, paused (and when the pause was applied), seeded
-- scripts outside tolerance in a row, and pieces until the next seed.
create table public.exam_markers (
  exam_id uuid references public.exams (id) on delete cascade,
  marker_id uuid references public.profiles (id) on delete cascade,
  cleared_at timestamptz,
  cleared_by uuid,
  paused_at timestamptz,
  pause_applied_at timestamptz,
  misses int not null default 0,
  until_seed int,
  primary key (exam_id, marker_id)
);
create index exam_markers_marker_idx on public.exam_markers (marker_id);

-- A piece used for practice or as a seeded script, from the lead's own marking of it.
create table public.marking_standards (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null,
  unit_id uuid not null unique references public.marking_units (id),
  use text not null check (use in ('practice', 'seed')),
  set_by uuid not null,
  note text check (char_length(note) <= 1000),
  created_at timestamptz not null default now(),
  retired_at timestamptz,
  retired_by uuid
);
create index marking_standards_exam_idx on public.marking_standards (exam_id);

-- The lead's marks for a standard, copied and frozen. NR is not_attempted, not a zero.
create table public.marking_standard_marks (
  standard_id uuid references public.marking_standards (id) on delete cascade,
  question_id uuid,
  mark numeric(5,1),
  not_attempted boolean not null default false,
  primary key (standard_id, question_id),
  check (not (not_attempted and mark is not null))
);

-- What the lead marker reviews: a difference between the first and second marking, a paused marker's piece, or a
-- piece of the routine sample. One open difference or paused-marker review per piece.
create table public.marking_reviews (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null,
  unit_id uuid not null references public.marking_units (id),
  kind text not null check (kind in ('difference', 'paused_marker', 'sample')),
  marking_id uuid not null references public.markings (id),
  second_marking_id uuid references public.markings (id),
  state text not null default 'open' check (state in ('open', 'closed')),
  outcome text check (outcome in ('first_stands', 'second_stands', 'lead_marks', 'accepted', 'sent_back', 'withdrawn')),
  reason text,
  opened_at timestamptz not null default now(),
  closed_by uuid,
  closed_at timestamptz
);
create unique index marking_reviews_one_open on public.marking_reviews (unit_id) where state = 'open' and kind <> 'sample';
create index marking_reviews_exam_state_idx on public.marking_reviews (exam_id, state);

-- A checked piece's final mark per question: from the first marking, the second, or the lead's own.
create table public.final_marks (
  unit_id uuid references public.marking_units (id),
  question_id uuid,
  mark numeric(5,1),
  not_attempted boolean not null default false,
  source text not null check (source in ('first', 'second', 'lead')),
  set_by uuid,
  set_at timestamptz not null default now(),
  primary key (unit_id, question_id),
  check (not (not_attempted and mark is not null))
);

-- Every final mark as it was set, or removed: who, when and why.
create table public.final_mark_history (
  id bigint generated always as identity primary key,
  unit_id uuid not null,
  question_id uuid not null,
  mark numeric(5,1),
  not_attempted boolean not null,
  source text not null,
  removed boolean not null default false,
  changed_by uuid,
  changed_at timestamptz not null default now(),
  reason text
);
create index final_mark_history_unit_idx on public.final_mark_history (unit_id, question_id);

-- ---------------------------------------------------------------------------------------------
-- Access: staff admins read; nobody but definer functions and the service role writes.
-- ---------------------------------------------------------------------------------------------
alter table public.exam_markers enable row level security;
alter table public.marking_standards enable row level security;
alter table public.marking_standard_marks enable row level security;
alter table public.marking_reviews enable row level security;
alter table public.final_marks enable row level security;
alter table public.final_mark_history enable row level security;

revoke all on public.exam_markers, public.marking_standards, public.marking_standard_marks, public.marking_reviews,
  public.final_marks, public.final_mark_history
  from anon, authenticated;
revoke all on sequence public.final_mark_history_id_seq from anon, authenticated;
grant select on public.exam_markers, public.marking_standards, public.marking_standard_marks, public.marking_reviews,
  public.final_marks, public.final_mark_history
  to authenticated;

create policy exam_markers_select on public.exam_markers for select to authenticated using ((select public.is_staff_admin()));
create policy marking_standards_select on public.marking_standards for select to authenticated using ((select public.is_staff_admin()));
create policy marking_standard_marks_select on public.marking_standard_marks for select to authenticated using ((select public.is_staff_admin()));
create policy marking_reviews_select on public.marking_reviews for select to authenticated using ((select public.is_staff_admin()));
create policy final_marks_select on public.final_marks for select to authenticated using ((select public.is_staff_admin()));
create policy final_mark_history_select on public.final_mark_history for select to authenticated using ((select public.is_staff_admin()));

-- ---------------------------------------------------------------------------------------------
-- Internal: how many approved active markers the subject has (is_marker_for), as marking_exam_get counts them.
-- ---------------------------------------------------------------------------------------------
create function public.marking_subject_markers(p_subject bigint)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int from public.marker_approvals a
  where a.subject_id = p_subject and public.is_marker_for(a.marker_id, a.subject_id)
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_checks_get: the exam's checks. An exam never saved has the column defaults. off is the reason the checks
-- were last turned off, with who (by_name) and when, or null; markers_approved counts the subject's approved active
-- markers, and can_switch_off says whether that is at most one. Admins, and the subject's lead marker (forbidden
-- otherwise; an unknown exam is not_found to an admin and forbidden to anyone else). Returns {ok, double_marking,
-- sample_percent, tolerance_percent, seeds, seed_every, practice, off:{reason, by_name, at}|null, markers_approved,
-- can_switch_off, opened, approved}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_checks_get(p_exam uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin boolean := public.is_staff_admin();
  v_e public.exams%rowtype;
  v_m public.exam_marking%rowtype;
  v_markers int;
begin
  if p_exam is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_e from public.exams e where e.id = p_exam;
  if not found then
    return jsonb_build_object('ok', false, 'code', case when v_admin then 'not_found' else 'forbidden' end);
  end if;
  if not v_admin and not public.is_lead_for(auth.uid(), v_e.subject_id) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select * into v_m from public.exam_marking m where m.exam_id = p_exam;
  v_markers := public.marking_subject_markers(v_e.subject_id);

  return jsonb_build_object(
    'ok', true,
    'double_marking', coalesce(v_m.double_marking, true),
    'sample_percent', coalesce(v_m.sample_percent, 10),
    'tolerance_percent', coalesce(v_m.tolerance_percent, 10),
    'seeds', coalesce(v_m.seeds, true),
    'seed_every', coalesce(v_m.seed_every, 10),
    'practice', coalesce(v_m.practice, true),
    'off', case when v_m.checks_off_at is not null then jsonb_build_object(
             'reason', v_m.checks_off_reason,
             'by_name', (select nullif(btrim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), '')
                         from public.profiles p where p.id = v_m.checks_off_by),
             'at', v_m.checks_off_at) end,
    'markers_approved', v_markers,
    'can_switch_off', v_markers <= 1,
    'opened', v_m.opened_at is not null,
    'approved', v_m.approved_at is not null);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_checks_set: the exam's checks. p_settings has all six, in range: {double_marking, sample_percent (1 to 100),
-- tolerance_percent (1 to 50), seeds, seed_every (3 to 50), practice}, the numbers whole (invalid_input otherwise).
-- Turning any of double marking, seeds and practice off needs at most one approved active marker of the subject
-- (not_small_subject) and a reason (reason_required), and keeps the reason with who and when; with all three on again
-- they are cleared. Once marking has opened, any change needs a reason. Saving the same settings changes nothing and
-- writes no audit row; a change writes one (marking_checks_set) saying what changed, with the reason. Admins only.
-- Returns {ok, double_marking, sample_percent, tolerance_percent, seeds, seed_every, practice}.
-- ---------------------------------------------------------------------------------------------
create function public.marking_checks_set(p_exam uuid, p_settings jsonb, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := public.script_resolution_reason(p_reason);
  v_whole constant text := '^[0-9]{1,3}$';
  v_e public.exams%rowtype;
  v_m public.exam_marking%rowtype;
  v_dm boolean;
  v_sp int;
  v_tp int;
  v_se boolean;
  v_sv int;
  v_pr boolean;
  v_was_dm boolean;
  v_was_sp int;
  v_was_tp int;
  v_was_se boolean;
  v_was_sv int;
  v_was_pr boolean;
  v_turning_off boolean;
  v_changes text[] := '{}';
  v_off_reason text;
  v_off_by uuid;
  v_off_at timestamptz;
  v_onoff constant text[] := array['off', 'on'];
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null or jsonb_typeof(p_settings) is distinct from 'object'
     or jsonb_typeof(p_settings -> 'double_marking') is distinct from 'boolean'
     or jsonb_typeof(p_settings -> 'seeds') is distinct from 'boolean'
     or jsonb_typeof(p_settings -> 'practice') is distinct from 'boolean'
     or jsonb_typeof(p_settings -> 'sample_percent') is distinct from 'number' or (p_settings ->> 'sample_percent') !~ v_whole
     or jsonb_typeof(p_settings -> 'tolerance_percent') is distinct from 'number' or (p_settings ->> 'tolerance_percent') !~ v_whole
     or jsonb_typeof(p_settings -> 'seed_every') is distinct from 'number' or (p_settings ->> 'seed_every') !~ v_whole then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  v_dm := (p_settings ->> 'double_marking')::boolean;
  v_sp := (p_settings ->> 'sample_percent')::int;
  v_tp := (p_settings ->> 'tolerance_percent')::int;
  v_se := (p_settings ->> 'seeds')::boolean;
  v_sv := (p_settings ->> 'seed_every')::int;
  v_pr := (p_settings ->> 'practice')::boolean;
  if v_sp not between 1 and 100 or v_tp not between 1 and 50 or v_sv not between 3 and 50 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_e from public.exams e where e.id = p_exam;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  -- The structure lock, then the exam's marking row, as marking_settings_set and marking_open take them: the checks an
  -- opening reads are the ones saved here.
  perform pg_advisory_xact_lock(hashtextextended('exam_structure:' || p_exam::text, 0));
  select * into v_m from public.exam_marking m where m.exam_id = p_exam for update;
  -- What is saved now: an exam never saved has the column defaults.
  v_was_dm := coalesce(v_m.double_marking, true);
  v_was_sp := coalesce(v_m.sample_percent, 10);
  v_was_tp := coalesce(v_m.tolerance_percent, 10);
  v_was_se := coalesce(v_m.seeds, true);
  v_was_sv := coalesce(v_m.seed_every, 10);
  v_was_pr := coalesce(v_m.practice, true);

  if v_dm <> v_was_dm then
    v_changes := v_changes || ('double marking ' || v_onoff[v_was_dm::int + 1] || ' -> ' || v_onoff[v_dm::int + 1]);
  end if;
  if v_sp <> v_was_sp then
    v_changes := v_changes || ('second-mark ' || v_was_sp || '% -> ' || v_sp || '%');
  end if;
  if v_tp <> v_was_tp then
    v_changes := v_changes || ('tolerance ' || v_was_tp || '% -> ' || v_tp || '%');
  end if;
  if v_se <> v_was_se then
    v_changes := v_changes || ('seeded scripts ' || v_onoff[v_was_se::int + 1] || ' -> ' || v_onoff[v_se::int + 1]);
  end if;
  if v_sv <> v_was_sv then
    v_changes := v_changes || ('seed every ' || v_was_sv || ' -> ' || v_sv);
  end if;
  if v_pr <> v_was_pr then
    v_changes := v_changes || ('practice ' || v_onoff[v_was_pr::int + 1] || ' -> ' || v_onoff[v_pr::int + 1]);
  end if;
  if cardinality(v_changes) = 0 then
    return jsonb_build_object('ok', true, 'double_marking', v_dm, 'sample_percent', v_sp, 'tolerance_percent', v_tp,
      'seeds', v_se, 'seed_every', v_sv, 'practice', v_pr);
  end if;

  v_turning_off := (v_was_dm and not v_dm) or (v_was_se and not v_se) or (v_was_pr and not v_pr);
  if v_turning_off then
    -- No reason can change this, so it is answered first.
    if public.marking_subject_markers(v_e.subject_id) > 1 then
      return jsonb_build_object('ok', false, 'code', 'not_small_subject');
    end if;
    if v_reason is null then
      return jsonb_build_object('ok', false, 'code', 'reason_required');
    end if;
  end if;
  if v_m.opened_at is not null and v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;

  -- Turned off now: this reason, by whom and when. All three on: nothing is off. Otherwise they stay as they were.
  if v_turning_off then
    v_off_reason := v_reason;
    v_off_by := v_actor;
    v_off_at := now();
  elsif not (v_dm and v_se and v_pr) then
    v_off_reason := v_m.checks_off_reason;
    v_off_by := v_m.checks_off_by;
    v_off_at := v_m.checks_off_at;
  end if;
  insert into public.exam_marking as m (exam_id, double_marking, sample_percent, tolerance_percent, seeds, seed_every, practice,
    checks_off_reason, checks_off_by, checks_off_at, updated_at)
  values (p_exam, v_dm, v_sp, v_tp, v_se, v_sv, v_pr, v_off_reason, v_off_by, v_off_at, now())
  on conflict (exam_id) do update set
    double_marking = excluded.double_marking, sample_percent = excluded.sample_percent,
    tolerance_percent = excluded.tolerance_percent, seeds = excluded.seeds, seed_every = excluded.seed_every,
    practice = excluded.practice, checks_off_reason = excluded.checks_off_reason, checks_off_by = excluded.checks_off_by,
    checks_off_at = excluded.checks_off_at, updated_at = now();
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marking_checks_set', 'exam', p_exam,
    array_to_string(v_changes, '; ') || coalesce('; reason: ' || v_reason, ''));
  return jsonb_build_object('ok', true, 'double_marking', v_dm, 'sample_percent', v_sp, 'tolerance_percent', v_tp,
    'seeds', v_se, 'seed_every', v_sv, 'practice', v_pr);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marking_open: as 20261122000005, and then: with double marking on, two approved active markers of the subject
-- (needs_two_markers); with seeds or practice on, an active lead marker of the subject (no_lead). An exam never saved
-- has all three on. Needs a question to mark and, marked by question, every top-level question in a group
-- (structure_incomplete), and an approved active marker of the subject (no_markers), first. Sets opened_at and
-- opened_by, then makes the verified scripts ready (marking_exam_sync). Admins only. Returns {ok, already: false,
-- ready}, or {ok, already: true} when marking had opened before.
-- ---------------------------------------------------------------------------------------------
create or replace function public.marking_open(p_exam uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_e public.exams%rowtype;
  v_m public.exam_marking%rowtype;
  v_ready int;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_e from public.exams e where e.id = p_exam;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  -- The structure lock, as exam_structure_save takes it: the questions checked here are the ones marking opens with.
  perform pg_advisory_xact_lock(hashtextextended('exam_structure:' || p_exam::text, 0));
  select * into v_m from public.exam_marking m where m.exam_id = p_exam for update;
  if v_m.opened_at is not null then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  if not exists (select 1 from public.exam_questions q
                 where q.exam_id = p_exam and not exists (select 1 from public.exam_questions c where c.parent_id = q.id))
     or (coalesce(v_m.mode, 'whole') = 'by_question'
         and exists (select 1 from public.exam_questions q where q.exam_id = p_exam and q.parent_id is null and q.group_id is null)) then
    return jsonb_build_object('ok', false, 'code', 'structure_incomplete');
  end if;
  if not exists (select 1 from public.marker_approvals a
                 where a.subject_id = v_e.subject_id and public.is_marker_for(a.marker_id, a.subject_id)) then
    return jsonb_build_object('ok', false, 'code', 'no_markers');
  end if;
  -- 3B: the checks that are on need their markers.
  if coalesce(v_m.double_marking, true) and public.marking_subject_markers(v_e.subject_id) < 2 then
    return jsonb_build_object('ok', false, 'code', 'needs_two_markers');
  end if;
  if (coalesce(v_m.seeds, true) or coalesce(v_m.practice, true))
     and not exists (select 1 from public.marker_approvals a
                     where a.subject_id = v_e.subject_id and a.lead and public.is_lead_for(a.marker_id, a.subject_id)) then
    return jsonb_build_object('ok', false, 'code', 'no_lead');
  end if;

  insert into public.exam_marking as m (exam_id, opened_at, opened_by, updated_at)
  values (p_exam, now(), v_actor, now())
  on conflict (exam_id) do update set opened_at = excluded.opened_at, opened_by = excluded.opened_by, updated_at = now();
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'marking_opened', 'exam', p_exam);
  v_ready := public.marking_exam_sync(p_exam, null);
  return jsonb_build_object('ok', true, 'already', false, 'ready', v_ready);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Privileges. marking_open's are as they were (create or replace keeps them; restated).
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.marking_subject_markers(bigint) from public, anon, authenticated, service_role;
revoke execute on function public.marking_checks_get(uuid) from public, anon;
revoke execute on function public.marking_checks_set(uuid, jsonb, text) from public, anon;
revoke execute on function public.marking_open(uuid) from public, anon;
grant execute on function public.marking_checks_get(uuid) to authenticated;
grant execute on function public.marking_checks_set(uuid, jsonb, text) to authenticated;
grant execute on function public.marking_open(uuid) to authenticated;
