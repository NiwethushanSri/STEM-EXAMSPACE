-- Phase 3B Task 11: marker pay. Pay rates per exam (or per question group), what counts as payable, and the monthly
-- statements an admin fixes once the month has ended.
--
-- This is examiner pay, worked out for admins only: paying markers happens outside the system (6.6), and markers and
-- lead markers read no rates and no statements (Ruling R1, Builder's call 18). Nothing here touches family payments.
--
-- Rates (Builder's call 17). Whole pence from 0 to 100,000 per piece: one rate for an exam marked as whole scripts
-- (group_id null), one per question group for an exam marked by question (exam_marking.mode), for first, second and
-- re-marking alike (Ruling R1: a second marking is paid at the first-marking rate). An admin sets the exam's rates all
-- at once (marker_rates_set). Once a piece of the exam is in a fixed statement, a change needs a reason, and it reaches
-- only the pieces not fixed yet: an item keeps the pence it was fixed with. Rates are not marking, so an approved
-- exam's rates can still change. A question group removed before marking opens (exam_structure_save deletes it) takes
-- its rate with it (on delete cascade).
--
-- What is paid (marker_payable). A live, second or re-mark marking that is submitted and still stands, paid to the
-- marker who made it, at the rate of its exam (and group). Practice and seeded scripts are never paid (Ruling R10). A
-- marking set aside is not paid: taken back, sent to another marker (whose own marking is paid), a name seen, a second
-- marking switched off when a paused marker's piece is accepted (Ruling R15): no pay for work taken away (Ruling R1).
-- A piece sent back to the same marker keeps its marking and is paid once. A marking on a script withdrawn later
-- stands and is paid. A marking belongs to the UK calendar month (Europe/London) of its submission, and is never paid
-- twice: marker_statement_items is keyed by the marking.
--
-- Statements (Builder's call 18). Once a month has ended by server time in UK time, an admin fixes its statements
-- (marker_statements_fix): one statement per marker with payable pieces submitted before the month's end and no
-- statement for the month yet, and one item per piece with its pence. Every such piece needs a rate first
-- (rate_missing). A piece an earlier fixed month missed (its marker had that month's statement, or its submit
-- committed after the fix) is carried into the next month's, since a month's payable pieces are all those submitted
-- before its end and not fixed yet. A marker fixed already is left alone. Months are fixed in order (Ruling R25: a fix
-- is permanent): an earlier month with payable pieces and no statement at all is fixed first (earlier_month); a month
-- with a statement that missed a late piece or a marker does not hold the next one back.
--
-- Fixed statements and their items never change. No function updates or deletes them; a trigger refuses any update,
-- delete or truncate of either table, whoever asks; only the definer functions write the three pay tables (Ruling R25:
-- insert, update, delete, truncate and trigger are revoked from service_role, anon and authenticated); and after every
-- insert each statement it touches must have exactly its stored pieces and total in items, so nothing can be added to
-- a fixed statement either. A later take-back, send-back or rate change leaves them as they are. A fixed statement
-- keeps the exam's id and reads the exam's title and paper live, so a renamed exam shows its new name (pieces and pence
-- never move); its group labels cannot drift, since a question group with pieces cannot be deleted (the marking units'
-- foreign key) and groups are matched by label.
--
-- Two fixes at once. The fix takes a transaction advisory lock for the month, then the pay lock (exclusive), before it
-- reads the payable pieces, so a second admin's fix waits, then finds those markers fixed and adds nothing. The pay
-- lock also makes a fix of another month wait (a month's fix takes the pieces earlier months missed), and a rate change,
-- which takes it shared: a change is never let through without a reason by a fix still in flight. The unique (marker,
-- month) and the items' primary key are the backstop.
--
-- Added:
--   tables marker_rates, marker_statements, marker_statement_items: row-level security, select for admins only;
--   marker_payable(p_before), marker_statement_month(p_at): internal;
--   marker_statements_frozen(): the trigger that refuses changes to fixed statements;
--   marker_statements_add_up(): the trigger that refuses an insert leaving a statement apart from its items;
--   marker_rates_get(p_exam), marker_rates_set(p_exam, p_rates, p_reason), marker_statements_get(p_month),
--   marker_statements_fix(p_month, p_now), marker_statement_exported(p_month): admins.
-- No earlier function is changed. Nothing here names or points to a candidate: no script number, index number or id of
-- a script, booking, student or piece leaves these functions; only exams, question groups, kinds of marking, counts
-- and pence.

-- ---------------------------------------------------------------------------------------------
-- Tables.
-- ---------------------------------------------------------------------------------------------

-- An exam's pay rate per piece: group_id null for an exam marked as whole scripts, else one per question group.
create table public.marker_rates (
  exam_id uuid not null references public.exams (id) on delete cascade,
  group_id uuid references public.question_groups (id) on delete cascade,
  pence int not null check (pence between 0 and 100000),
  set_by uuid,
  set_at timestamptz not null,
  unique nulls not distinct (exam_id, group_id)
);

-- A marker's fixed statement for a UK calendar month (its first day).
create table public.marker_statements (
  id uuid primary key default gen_random_uuid(),
  marker_id uuid not null references public.profiles (id),
  month date not null check (month = date_trunc('month', month::timestamp)::date),
  pieces int not null,
  total_pence int not null,
  fixed_by uuid not null,
  fixed_at timestamptz not null,
  unique (marker_id, month)
);
create index marker_statements_month_idx on public.marker_statements (month);

-- A marking paid in a fixed statement, with the pence it was fixed at. A marking is paid once, ever.
create table public.marker_statement_items (
  marking_id uuid primary key references public.markings (id),
  statement_id uuid not null references public.marker_statements (id),
  exam_id uuid not null,
  group_id uuid,
  kind public.marking_kind not null,
  pence int not null,
  submitted_at timestamptz not null
);
create index marker_statement_items_statement_idx on public.marker_statement_items (statement_id);
create index marker_statement_items_exam_idx on public.marker_statement_items (exam_id);

-- ---------------------------------------------------------------------------------------------
-- Access: staff admins read; nobody but definer functions and the service role writes.
-- ---------------------------------------------------------------------------------------------
alter table public.marker_rates enable row level security;
alter table public.marker_statements enable row level security;
alter table public.marker_statement_items enable row level security;

revoke all on public.marker_rates, public.marker_statements, public.marker_statement_items from anon, authenticated;
grant select on public.marker_rates, public.marker_statements, public.marker_statement_items to authenticated;
-- Ruling R25: only the definer functions write the pay tables; no client role, the service role included, can. TRIGGER
-- goes too: a trigger a client role put on a pay table would run with the rights of the definer function writing it.
revoke insert, update, delete, truncate, trigger on public.marker_rates, public.marker_statements, public.marker_statement_items
  from service_role, anon, authenticated;

create policy marker_rates_select on public.marker_rates for select to authenticated using ((select public.is_staff_admin()));
create policy marker_statements_select on public.marker_statements for select to authenticated using ((select public.is_staff_admin()));
create policy marker_statement_items_select on public.marker_statement_items for select to authenticated using ((select public.is_staff_admin()));

-- ---------------------------------------------------------------------------------------------
-- Fixed statements never change: any update, delete or truncate of a statement or an item is refused, whoever asks.
-- No function needs one, so there is no way round it.
-- ---------------------------------------------------------------------------------------------
create function public.marker_statements_frozen()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'Fixed marker statements and their items never change.';
end;
$$;

create trigger marker_statements_frozen before update or delete or truncate on public.marker_statements
  for each statement execute function public.marker_statements_frozen();
create trigger marker_statement_items_frozen before update or delete or truncate on public.marker_statement_items
  for each statement execute function public.marker_statements_frozen();

-- ---------------------------------------------------------------------------------------------
-- A statement adds up to its items (Ruling R25): after any insert of statements or of items, every statement the
-- inserted rows touch has exactly its stored pieces and total_pence in items, or the insert is refused. So no item can
-- be added to a fixed statement, and no statement stands apart from its items. It is a statement-level check over the
-- inserted rows (a transition table): the fix writes the statements and their items in one SQL statement, so the check
-- at its end sees both, one query per fix. A deferred constraint trigger would also let a statement and its items be
-- written by separate SQL statements of one transaction, but constraint triggers are row-level only (3,000 checks at
-- commit for a 3,000-piece fix), and no function writes them apart.
-- ---------------------------------------------------------------------------------------------
create function public.marker_statements_add_up()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_ids uuid[];
begin
  if tg_table_name = 'marker_statements' then
    select array_agg(n.id) into v_ids from new_rows n;
  else
    select array_agg(distinct n.statement_id) into v_ids from new_rows n;
  end if;
  if exists (
    select 1
    from public.marker_statements s
    cross join lateral (select count(*) as n, coalesce(sum(i.pence), 0) as t
                        from public.marker_statement_items i where i.statement_id = s.id) x
    where s.id = any (v_ids) and (s.pieces <> x.n or s.total_pence <> x.t)) then
    raise exception 'A fixed marker statement''s items must add up to its pieces and total.' using errcode = 'check_violation';
  end if;
  return null;
end;
$$;

create trigger marker_statements_add_up after insert on public.marker_statements
  referencing new table as new_rows for each statement execute function public.marker_statements_add_up();
create trigger marker_statement_items_add_up after insert on public.marker_statement_items
  referencing new table as new_rows for each statement execute function public.marker_statements_add_up();

-- ---------------------------------------------------------------------------------------------
-- Internal: the first day of the UK calendar month (Europe/London, daylight saving handled) of p_at.
-- ---------------------------------------------------------------------------------------------
create function public.marker_statement_month(p_at timestamptz)
returns date
language sql
immutable
set search_path = ''
as $$
  select date_trunc('month', p_at at time zone 'Europe/London')::date
$$;

-- ---------------------------------------------------------------------------------------------
-- Internal: the markings payable before p_before and not in a statement yet (see the header): live, second and
-- re-mark markings, submitted, of every exam. pence is the rate of the piece's exam (and group), null when none is set.
-- ---------------------------------------------------------------------------------------------
create function public.marker_payable(p_before timestamptz)
returns table (marking_id uuid, marker_id uuid, exam_id uuid, group_id uuid, kind public.marking_kind, submitted_at timestamptz,
  pence int)
language sql
stable
security definer
set search_path = ''
as $$
  select m.id, m.marker_id, u.exam_id, u.group_id, m.kind, m.submitted_at, r.pence
  from public.markings m
  join public.marking_units u on u.id = m.unit_id
  left join public.marker_rates r on r.exam_id = u.exam_id and r.group_id is not distinct from u.group_id
  where m.kind in ('live', 'second', 'remark') and m.status = 'submitted' and m.submitted_at < p_before
    and not exists (select 1 from public.marker_statement_items i where i.marking_id = m.id)
$$;

-- ---------------------------------------------------------------------------------------------
-- marker_rates_get: an exam's pay rates, for admins. {ok, mode, rates: [{group_id, group_label, pence}], fixed_pieces}:
-- for an exam marked as whole scripts one rate with no group; marked by question, one per question group in the
-- paper's order; pence null where no rate is set. fixed_pieces: the exam's pieces in fixed statements (once there are
-- any, a change needs a reason). Refused: forbidden; invalid_input; not_found.
-- ---------------------------------------------------------------------------------------------
create function public.marker_rates_get(p_exam uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_mode public.marking_mode;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if not exists (select 1 from public.exams e where e.id = p_exam) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  v_mode := coalesce((select m.mode from public.exam_marking m where m.exam_id = p_exam), 'whole');
  return jsonb_build_object(
    'ok', true,
    'mode', v_mode,
    'rates', case
      when v_mode = 'whole' then jsonb_build_array(jsonb_build_object(
        'group_id', null, 'group_label', null,
        'pence', (select r.pence from public.marker_rates r where r.exam_id = p_exam and r.group_id is null)))
      else coalesce((select jsonb_agg(jsonb_build_object('group_id', g.id, 'group_label', g.label, 'pence', r.pence)
                                      order by g.position, g.label)
                     from public.question_groups g
                     left join public.marker_rates r on r.exam_id = p_exam and r.group_id = g.id
                     where g.exam_id = p_exam), '[]'::jsonb)
      end,
    'fixed_pieces', (select count(*)::int from public.marker_statement_items i where i.exam_id = p_exam));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marker_rates_set: an admin sets an exam's pay rates, p_rates = [{group_id (null or absent for a whole-script exam),
-- pence}]: whole pence from 0 to 100,000; exactly one with no group for an exam marked as whole scripts, exactly one per
-- question group of the exam otherwise. Rates not in the list (left from another mode) are removed. Once a piece of the
-- exam is in a fixed statement, a change needs a reason (3 to 300 characters); fixed items keep their pence. Refused,
-- in this order: forbidden; invalid_input (no exam, or rates that are not a list of valid rates); not_found;
-- invalid_input (rates that do not fit the exam's mode and question groups). The same rates again then answer {ok,
-- changed: false} and nothing is written, whatever the reason. A change is then refused reason_required (pieces are
-- fixed and no valid reason is given) or invalid_input (a reason given of another length when none is needed). Audited
-- marker_rate_set: what changed (the first five, in the paper's order) and the reason. Returns {ok, changed: true}.
-- ---------------------------------------------------------------------------------------------
create function public.marker_rates_set(p_exam uuid, p_rates jsonb, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_given text := nullif(btrim(coalesce(p_reason, '')), '');
  v_reason text := public.script_resolution_reason(p_reason);
  v_none constant uuid := '00000000-0000-0000-0000-000000000000';
  v_x jsonb;
  v_g jsonb;
  v_n numeric;
  v_groups uuid[] := '{}';
  v_pence int[] := '{}';
  v_mode public.marking_mode;
  v_changes text;
  v_count int;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_exam is null or p_rates is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if jsonb_typeof(p_rates) <> 'array' then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if jsonb_array_length(p_rates) not between 1 and 200 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  -- Each rate: an object with whole pence from 0 to 100,000 and a group id (a uuid) or none.
  for v_x in select x from jsonb_array_elements(p_rates) x loop
    if jsonb_typeof(v_x) <> 'object' then
      return jsonb_build_object('ok', false, 'code', 'invalid_input');
    end if;
    if jsonb_typeof(v_x -> 'pence') is distinct from 'number' then
      return jsonb_build_object('ok', false, 'code', 'invalid_input');
    end if;
    v_n := (v_x -> 'pence')::numeric;
    if v_n <> trunc(v_n) or v_n < 0 or v_n > 100000 then
      return jsonb_build_object('ok', false, 'code', 'invalid_input');
    end if;
    v_g := v_x -> 'group_id';
    if v_g is null or jsonb_typeof(v_g) = 'null' then
      v_groups := array_append(v_groups, null::uuid);
    elsif jsonb_typeof(v_g) = 'string'
          and (v_g #>> '{}') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      v_groups := array_append(v_groups, (v_g #>> '{}')::uuid);
    else
      return jsonb_build_object('ok', false, 'code', 'invalid_input');
    end if;
    v_pence := array_append(v_pence, v_n::int);
  end loop;
  if not exists (select 1 from public.exams e where e.id = p_exam) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  -- The pay lock, shared: a fix in flight finishes first, so the fixed pieces read below are all there are. Then the
  -- exam's marking row, so its mode and question groups hold still while the rates are checked against them.
  perform pg_advisory_xact_lock_shared(hashtextextended('marker_pay', 0));
  perform 1 from public.exam_marking m where m.exam_id = p_exam for share;
  v_mode := coalesce((select m.mode from public.exam_marking m where m.exam_id = p_exam), 'whole');
  if v_mode = 'whole' then
    if cardinality(v_groups) <> 1 or v_groups[1] is not null then
      return jsonb_build_object('ok', false, 'code', 'invalid_input');
    end if;
  else
    select count(*)::int into v_count from public.question_groups g where g.exam_id = p_exam;
    if exists (select 1 from unnest(v_groups) x where x is null)
       or (select count(distinct x) from unnest(v_groups) x) <> cardinality(v_groups)
       or cardinality(v_groups) <> v_count
       or exists (select 1 from unnest(v_groups) x
                  where not exists (select 1 from public.question_groups g where g.id = x and g.exam_id = p_exam)) then
      return jsonb_build_object('ok', false, 'code', 'invalid_input');
    end if;
  end if;

  -- What changes, in the paper's order (the rate with no group first): the first five, then how many more.
  with want as (
    select t.g, t.p from unnest(v_groups, v_pence) t(g, p)
  ),
  have as (
    select r.group_id as g, r.pence as p from public.marker_rates r where r.exam_id = p_exam
  ),
  diff as (
    select coalesce(w.g, h.g) as g, h.p as was, w.p as now
    from want w full join have h on coalesce(h.g, v_none) = coalesce(w.g, v_none)
    where h.p is distinct from w.p
  ),
  said as (
    select case when d.g is null then 'per script' else 'group ' || coalesce(q.label, '?') end
             || ': ' || case when d.now is null then d.was || ' pence removed'
                             else coalesce(d.was::text, 'none') || ' -> ' || d.now || ' pence' end as t,
           row_number() over (order by d.g is not null, q.position, q.label, d.g) as n
    from diff d left join public.question_groups q on q.id = d.g
  )
  select string_agg(s.t, '; ' order by s.n) filter (where s.n <= 5)
         || case when count(*) > 5 then '; and ' || (count(*) - 5) || ' more' else '' end
  into v_changes
  from said s;
  if v_changes is null then
    return jsonb_build_object('ok', true, 'changed', false);
  end if;

  if v_reason is null and exists (select 1 from public.marker_statement_items i where i.exam_id = p_exam) then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if v_given is not null and v_reason is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  delete from public.marker_rates r
  where r.exam_id = p_exam and coalesce(r.group_id, v_none) <> all (array(select coalesce(x, v_none) from unnest(v_groups) x));
  insert into public.marker_rates as r (exam_id, group_id, pence, set_by, set_at)
  select p_exam, t.g, t.p, v_actor, now() from unnest(v_groups, v_pence) t(g, p)
  on conflict (exam_id, group_id) do update set pence = excluded.pence, set_by = excluded.set_by, set_at = excluded.set_at
  where r.pence is distinct from excluded.pence;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (v_actor, 'marker_rate_set', 'exam', p_exam, left(v_changes || coalesce('; reason: ' || v_reason, ''), 600));
  return jsonb_build_object('ok', true, 'changed', true);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marker_statements_get: a month's statements (p_month: its first day), for admins. {ok, month, ended, fixed,
-- rate_missing, markers: [{marker_id, name, fixed_at, pieces, total_pence, lines: [{exam_id, exam_title, paper,
-- group_label, kind, pieces, rate_pence, pence}]}]}. For a marker with a statement fixed for the month: its items, and
-- its stored pieces and total. For the others: what marker_payable gives before the month's end (pieces an earlier
-- fixed month missed are carried in), not fixed yet (fixed_at null); a line with no rate has rate_pence and pence null,
-- and so has the marker's total_pence. A line is an exam, a question group (null for a whole script), a kind (live,
-- second or remark) and a rate. ended: the month has ended by server time in UK time. fixed: a statement is fixed for
-- the month and no other marker has payable pieces in it. rate_missing: [{exam_id, exam_title, paper}], the exams of
-- the pieces not fixed yet that have no rate. Markers by name, lines by exam, paper, group and kind. No script number
-- and no candidate data. Refused: forbidden; invalid_input (no month, or a day that is not the first).
-- ---------------------------------------------------------------------------------------------
create function public.marker_statements_get(p_month date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_r jsonb;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_month is null or p_month <> date_trunc('month', p_month::timestamp)::date then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  with st as materialized (
    select s.id, s.marker_id, s.pieces, s.total_pence, s.fixed_at from public.marker_statements s where s.month = p_month
  ),
  unfixed as materialized (
    select p.marker_id, p.exam_id, p.group_id, p.kind, p.pence
    from public.marker_payable((p_month + interval '1 month')::timestamp at time zone 'Europe/London') p
    where not exists (select 1 from st where st.marker_id = p.marker_id)
  ),
  pieces as (
    select st.marker_id, i.exam_id, i.group_id, i.kind, i.pence
    from st join public.marker_statement_items i on i.statement_id = st.id
    union all
    select u.marker_id, u.exam_id, u.group_id, u.kind, u.pence from unfixed u
  ),
  lines as (
    select x.marker_id, x.exam_id, x.group_id, x.kind, x.pence as rate_pence, count(*)::int as pieces, sum(x.pence) as pence
    from pieces x
    group by x.marker_id, x.exam_id, x.group_id, x.kind, x.pence
  ),
  per as (
    select l.marker_id,
      jsonb_agg(jsonb_build_object('exam_id', l.exam_id, 'exam_title', e.title, 'paper', e.paper, 'group_label', g.label,
                                   'kind', l.kind, 'pieces', l.pieces, 'rate_pence', l.rate_pence, 'pence', l.pence)
                order by e.title, e.paper, l.exam_id, g.position nulls first, g.label, l.kind, l.rate_pence) as lines,
      sum(l.pieces)::int as pieces,
      case when bool_and(l.rate_pence is not null) then sum(l.pence) end as total_pence
    from lines l
    left join public.exams e on e.id = l.exam_id
    left join public.question_groups g on g.id = l.group_id
    group by l.marker_id
  ),
  named as (
    select per.*, st.id as statement_id, st.pieces as fixed_pieces, st.total_pence as fixed_total, st.fixed_at,
      nullif(btrim(coalesce(pr.first_name, '') || ' ' || coalesce(pr.last_name, '')), '') as name
    from per
    left join st on st.marker_id = per.marker_id
    left join public.profiles pr on pr.id = per.marker_id
  )
  select jsonb_build_object(
    'ok', true,
    'month', p_month,
    'ended', public.marker_statement_month(now()) > p_month,
    'fixed', exists (select 1 from st) and not exists (select 1 from unfixed),
    'rate_missing', coalesce((select jsonb_agg(jsonb_build_object('exam_id', e.id, 'exam_title', e.title, 'paper', e.paper)
                                               order by e.title, e.paper, e.id)
                              from public.exams e where e.id in (select u.exam_id from unfixed u where u.pence is null)), '[]'::jsonb),
    'markers', coalesce((select jsonb_agg(jsonb_build_object(
                                  'marker_id', n.marker_id,
                                  'name', n.name,
                                  'fixed_at', n.fixed_at,
                                  'pieces', case when n.statement_id is not null then n.fixed_pieces else n.pieces end,
                                  'total_pence', case when n.statement_id is not null then n.fixed_total else n.total_pence end,
                                  'lines', n.lines)
                                order by n.name nulls last, n.marker_id)
                         from named n), '[]'::jsonb))
  into v_r;
  return v_r;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marker_statements_fix: an admin fixes a month's statements (p_month: its first day; p_now for tests, read through
-- paper_clock). Refused, in this order: forbidden; invalid_input; too_early (the month has not ended by server time in
-- UK time); earlier_month with month (Ruling R25: the earliest UK month before p_month that has payable pieces and no
-- statement at all, to be fixed first); rate_missing with exams: [{exam_id, exam_title, paper}] (a payable piece of a
-- marker not fixed yet has no rate). Nothing is fixed when refused. Otherwise one statement, with an item per piece at
-- its rate, for every marker with payable pieces before the month's end and no statement for the month; markers fixed
-- already are left alone. Takes the month's advisory lock, then the pay lock, before reading anything (see the header),
-- and the statements' add-up check runs at the end of its insert. Audited marker_statements_fixed
-- (the month, statements, pieces and pence) when it fixes something. Returns {ok, statements, pieces, total_pence} of
-- what this call fixed (all 0 when nothing was left).
-- ---------------------------------------------------------------------------------------------
create function public.marker_statements_fix(p_month date, p_now timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_start timestamptz;
  v_end timestamptz;
  v_earlier date;
  v_missing jsonb;
  v_statements int;
  v_pieces int;
  v_total bigint;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_month is null or p_month <> date_trunc('month', p_month::timestamp)::date then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if public.marker_statement_month(public.paper_clock(p_now)) <= p_month then
    return jsonb_build_object('ok', false, 'code', 'too_early');
  end if;
  v_start := p_month::timestamp at time zone 'Europe/London';
  v_end := (p_month + interval '1 month')::timestamp at time zone 'Europe/London';

  -- The month's lock, then the pay lock (exclusive): a second fix of the month waits here and then adds nothing.
  perform pg_advisory_xact_lock(hashtextextended('marker_statements:' || to_char(p_month, 'YYYY-MM'), 0));
  perform pg_advisory_xact_lock(hashtextextended('marker_pay', 0));

  -- Ruling R25: an earlier month with payable pieces and no statement at all is fixed first; a fix is permanent, so a
  -- month swept into a later one could never be put right. A month with a statement that missed a late piece or a
  -- marker does not count: those pieces carry into the next month.
  select min(x.month) into v_earlier
  from (select distinct public.marker_statement_month(p.submitted_at) as month from public.marker_payable(v_start) p) x
  where not exists (select 1 from public.marker_statements s where s.month = x.month);
  if v_earlier is not null then
    return jsonb_build_object('ok', false, 'code', 'earlier_month', 'month', v_earlier);
  end if;

  select jsonb_agg(jsonb_build_object('exam_id', e.id, 'exam_title', e.title, 'paper', e.paper) order by e.title, e.paper, e.id)
  into v_missing
  from public.exams e
  where e.id in (select p.exam_id from public.marker_payable(v_end) p
                 where p.pence is null
                   and not exists (select 1 from public.marker_statements s where s.marker_id = p.marker_id and s.month = p_month));
  if v_missing is not null then
    return jsonb_build_object('ok', false, 'code', 'rate_missing', 'exams', v_missing);
  end if;

  -- One read of the payable pieces makes both the statements and their items, so each statement's figures are its
  -- items'. (A piece whose submit committed since the check above, with no rate, waits for a later fix.)
  with p as materialized (
    select x.marking_id, x.marker_id, x.exam_id, x.group_id, x.kind, x.submitted_at, x.pence
    from public.marker_payable(v_end) x
    where x.pence is not null
      and not exists (select 1 from public.marker_statements s where s.marker_id = x.marker_id and s.month = p_month)
  ),
  s as (
    insert into public.marker_statements (marker_id, month, pieces, total_pence, fixed_by, fixed_at)
    select p.marker_id, p_month, count(*), sum(p.pence), v_actor, now() from p group by p.marker_id
    returning id, marker_id, pieces, total_pence
  ),
  i as (
    insert into public.marker_statement_items (marking_id, statement_id, exam_id, group_id, kind, pence, submitted_at)
    select p.marking_id, s.id, p.exam_id, p.group_id, p.kind, p.pence, p.submitted_at
    from p join s on s.marker_id = p.marker_id
    returning 1
  )
  select count(*)::int, coalesce(sum(s.pieces), 0)::int, coalesce(sum(s.total_pence), 0)
  into v_statements, v_pieces, v_total
  from s;

  if v_statements > 0 then
    insert into public.audit_log (actor_id, action, target_type, target_id, reason)
    values (v_actor, 'marker_statements_fixed', 'marker_statements', null,
      'month ' || to_char(p_month, 'YYYY-MM') || ': ' || v_statements || case when v_statements = 1 then ' statement, ' else ' statements, ' end
      || v_pieces || case when v_pieces = 1 then ' piece, ' else ' pieces, ' end || v_total || ' pence');
  end if;
  return jsonb_build_object('ok', true, 'statements', v_statements, 'pieces', v_pieces, 'total_pence', v_total);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- marker_statement_exported: an admin downloaded a month's statements (the design asks for every export to be
-- recorded). Audited marker_statement_exported with the month and how many statements are fixed for it. Refused:
-- forbidden; invalid_input. Returns {ok}.
-- ---------------------------------------------------------------------------------------------
create function public.marker_statement_exported(p_month date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int;
begin
  if not public.is_staff_admin() then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_month is null or p_month <> date_trunc('month', p_month::timestamp)::date then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select count(*)::int into v_n from public.marker_statements s where s.month = p_month;
  insert into public.audit_log (actor_id, action, target_type, target_id, reason)
  values (auth.uid(), 'marker_statement_exported', 'marker_statements', null,
    'month ' || to_char(p_month, 'YYYY-MM') || ': ' || v_n || case when v_n = 1 then ' fixed statement' else ' fixed statements' end);
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Privileges.
-- ---------------------------------------------------------------------------------------------
revoke execute on function public.marker_statements_frozen() from public, anon, authenticated, service_role;
revoke execute on function public.marker_statements_add_up() from public, anon, authenticated, service_role;
revoke execute on function public.marker_statement_month(timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.marker_payable(timestamptz) from public, anon, authenticated, service_role;

revoke execute on function public.marker_rates_get(uuid) from public, anon;
revoke execute on function public.marker_rates_set(uuid, jsonb, text) from public, anon;
revoke execute on function public.marker_statements_get(date) from public, anon;
revoke execute on function public.marker_statements_fix(date, timestamptz) from public, anon;
revoke execute on function public.marker_statement_exported(date) from public, anon;

grant execute on function public.marker_rates_get(uuid) to authenticated;
grant execute on function public.marker_rates_set(uuid, jsonb, text) to authenticated;
grant execute on function public.marker_statements_get(date) to authenticated;
grant execute on function public.marker_statements_fix(date, timestamptz) to authenticated;
grant execute on function public.marker_statement_exported(date) to authenticated;
