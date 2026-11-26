-- ---------------------------------------------------------------------------------------------
-- Phase 4A, Task 2: the results tables.
--   enums result_status, results_state;
--   tables exam_results (one row per exam: where its results stand), grade_boundaries (an exam's grades and their lowest
--     marks), results (one row per booking: the candidate's outcome), result_versions (the published picture of a result,
--     one row per version, never changed once written). Row-level security on all four; select for admins only. Families
--     read results later through definer functions, never from these tables.
--   functions exam_max_total(exam) (internal): the paper's maximum counted as script_final_total counts a script;
--     is_family_of(student) (internal): the caller is that student, or a parent linked to them, and not suspended.
-- Only definer functions write these tables: no client role (the service role included) can insert, update or delete
-- (as Ruling R25 did for the pay tables). result_versions is also refused by a trigger to anyone, the owner included.
-- ---------------------------------------------------------------------------------------------
create type public.result_status as enum ('present', 'absent', 'withdrawn', 'incomplete', 'disqualified');
create type public.results_state as enum ('none', 'prepared', 'scheduled', 'published', 'withdrawn');

create table public.exam_results (
  exam_id uuid primary key references public.exams (id) on delete cascade,
  state public.results_state not null default 'none',
  version int not null default 0,
  prepared_at timestamptz,
  prepared_by uuid references public.profiles (id) on delete set null,
  publish_at timestamptz,
  first_published_at timestamptz,
  published_at timestamptz,
  published_by uuid references public.profiles (id) on delete set null,
  publish_failed_at timestamptz,
  publish_failed_reason text,
  withdrawn_at timestamptz,
  withdrawn_by uuid references public.profiles (id) on delete set null,
  withdraw_reason text,
  remark_fee_pence int check (remark_fee_pence between 0 and 100000),
  cohort jsonb,
  updated_at timestamptz not null default now()
);

create table public.grade_boundaries (
  exam_id uuid not null references public.exams (id) on delete cascade,
  position int not null check (position between 1 and 15),
  grade text not null check (char_length(grade) between 1 and 10),
  min_mark numeric(6,1) not null check (min_mark >= 0),
  set_by uuid references public.profiles (id) on delete set null,
  set_at timestamptz not null default now(),
  primary key (exam_id, position),
  unique (exam_id, grade)
);

create table public.results (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null references public.exams (id),
  booking_id uuid not null unique references public.bookings (id),
  student_id uuid not null references public.profiles (id),
  script_id uuid references public.scripts (id),
  sitting public.sitting_mode not null,
  status public.result_status not null,
  status_set boolean not null default false,
  status_reason text,
  total numeric(6,1),
  max_total numeric(6,1) not null,
  percentage numeric(5,1),
  grade text,
  rank int,
  rank_cohort int,
  -- [{question_id, mark, not_attempted, changed_on_review}] for top-level and leaf questions, as script_final_marks has them
  question_marks jsonb not null default '[]'::jsonb,
  version int not null default 0,
  remarked boolean not null default false,
  updated_at timestamptz not null default now()
);
create index results_exam_idx on public.results (exam_id);
create index results_student_idx on public.results (student_id);

create table public.result_versions (
  result_id uuid not null references public.results (id) on delete cascade,
  version int not null,
  published_at timestamptz not null,
  snapshot jsonb not null,
  reason text,
  made_by uuid,
  made_at timestamptz not null default now(),
  primary key (result_id, version)
);

create trigger exam_results_touch_updated_at before update on public.exam_results
  for each row execute function public.touch_updated_at();
create trigger results_touch_updated_at before update on public.results
  for each row execute function public.touch_updated_at();

alter table public.exam_results enable row level security;
alter table public.grade_boundaries enable row level security;
alter table public.results enable row level security;
alter table public.result_versions enable row level security;

revoke all on public.exam_results, public.grade_boundaries, public.results, public.result_versions from anon, authenticated;
grant select on public.exam_results, public.grade_boundaries, public.results, public.result_versions to authenticated;
revoke insert, update, delete, truncate, trigger on public.exam_results, public.grade_boundaries, public.results
  from service_role, anon, authenticated;
-- A published version is never changed: the service role cannot write it either. TRIGGER goes too, so no client role
-- can put a trigger on it that would run with the rights of the definer function writing it.
revoke insert, update, delete, truncate, trigger on public.result_versions from service_role, anon, authenticated;

create policy exam_results_select on public.exam_results for select to authenticated using ((select public.is_staff_admin()));
create policy grade_boundaries_select on public.grade_boundaries for select to authenticated using ((select public.is_staff_admin()));
create policy results_select on public.results for select to authenticated using ((select public.is_staff_admin()));
create policy result_versions_select on public.result_versions for select to authenticated using ((select public.is_staff_admin()));

-- A published version never changes: any update, delete or truncate is refused, whoever asks (the owner too).
create function public.result_versions_frozen()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'Published result versions never change.';
end;
$$;
create trigger result_versions_frozen before update or delete or truncate on public.result_versions
  for each statement execute function public.result_versions_frozen();

-- ---------------------------------------------------------------------------------------------
-- Internal: the paper's maximum, counted as script_final_total counts a script: leaf maxima summed per top-level
-- question, then within each group of optional questions only the best `choose` top-level questions.
-- ---------------------------------------------------------------------------------------------
create function public.exam_max_total(p_exam uuid)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  with recursive tree as (
    select q.id, q.id as top_id, q.max_mark
    from public.exam_questions q where q.exam_id = p_exam and q.parent_id is null
    union all
    select c.id, t.top_id, c.max_mark from public.exam_questions c join tree t on c.parent_id = t.id
  ),
  tops as (
    select t.top_id, sum(coalesce(t.max_mark, 0)) as total from tree t group by t.top_id
  ),
  ranked as (
    select tp.total, top.option_group_id, og.choose,
      row_number() over (partition by top.option_group_id order by tp.total desc) as n
    from tops tp
    join public.exam_questions top on top.id = tp.top_id
    left join public.exam_option_groups og on og.id = top.option_group_id
  )
  select coalesce(sum(r.total) filter (where r.option_group_id is null or r.n <= r.choose), 0)
  from ranked r
$$;

-- Internal: the caller is the student, or a parent linked to them, and is not suspended (my_role() is null then).
create function public.is_family_of(p_student uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_student is not null
    and (select public.my_role()) is not null
    and ((select auth.uid()) = p_student
         or exists (select 1 from public.parent_children pc
                    where pc.parent_id = (select auth.uid()) and pc.student_id = p_student))
$$;

revoke execute on function public.result_versions_frozen() from public, anon, authenticated, service_role;
revoke execute on function public.exam_max_total(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.is_family_of(uuid) from public, anon, authenticated, service_role;
