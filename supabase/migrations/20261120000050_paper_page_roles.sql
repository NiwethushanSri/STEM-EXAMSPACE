-- Phase 2 Task 1: which pages of a paper are answer pages, covers, blank pages or information pages, and the
-- "hidden areas" drawn over the exam board's own candidate-name boxes so markers never see a name.
--
-- Both are kept per paper version. A new version starts from the previous one (same page numbers keep their role
-- and their areas), but must be reviewed again: pages_reviewed_at is null until an admin saves the roles.
-- Hidden areas are fractions (0 to 1) of the A4 copy page, measured from its top left, so they are the same on
-- every candidate's copy. Roles lock once a scanned script page exists for any copy of the paper (the
-- script_pages table arrives with the scripts tables, so it is only looked at if it exists).

create type public.page_role as enum ('answer', 'cover', 'blank', 'information');

alter table public.exam_papers add column pages_reviewed_at timestamptz;

create table public.paper_page_roles (
  paper_id uuid not null references public.exam_papers (id) on delete cascade,
  page int not null check (page >= 1),
  role public.page_role not null,
  primary key (paper_id, page)
);

create table public.paper_hidden_areas (
  id uuid primary key default gen_random_uuid(),
  paper_id uuid not null references public.exam_papers (id) on delete cascade,
  page int not null check (page >= 1),
  x numeric not null,
  y numeric not null,
  w numeric not null,
  h numeric not null,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  constraint paper_hidden_areas_inside_page check (x >= 0 and y >= 0 and w > 0 and h > 0 and x + w <= 1 and y + h <= 1)
);
create index paper_hidden_areas_paper_idx on public.paper_hidden_areas (paper_id, page);

alter table public.paper_page_roles enable row level security;
alter table public.paper_hidden_areas enable row level security;
revoke all on public.paper_page_roles, public.paper_hidden_areas from anon, authenticated;
grant select on public.paper_page_roles, public.paper_hidden_areas to authenticated;
create policy paper_page_roles_select on public.paper_page_roles for select to authenticated
using ((select public.is_staff_admin()));
create policy paper_hidden_areas_select on public.paper_hidden_areas for select to authenticated
using ((select public.is_staff_admin()));

-- ---------------------------------------------------------------------------------------------
-- A registered paper gets a role for every page: the same as the previous version had for that page number, else
-- answer. Hidden areas carry over for pages the new version still has.
-- ---------------------------------------------------------------------------------------------
create function public.paper_page_roles_init()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev uuid;
begin
  if new.kind <> 'paper' then
    return new;
  end if;
  select p.id into v_prev from public.exam_papers p
  where p.exam_id = new.exam_id and p.kind = 'paper' and p.version < new.version
  order by p.version desc limit 1;

  insert into public.paper_page_roles (paper_id, page, role)
  select new.id, g.page, coalesce(r.role, 'answer')
  from generate_series(1, new.page_count) as g(page)
  left join public.paper_page_roles r on r.paper_id = v_prev and r.page = g.page;

  if v_prev is not null then
    insert into public.paper_hidden_areas (paper_id, page, x, y, w, h, created_by)
    select new.id, a.page, a.x, a.y, a.w, a.h, a.created_by
    from public.paper_hidden_areas a
    where a.paper_id = v_prev and a.page <= new.page_count;
  end if;
  return new;
end;
$$;
revoke execute on function public.paper_page_roles_init() from public, anon, authenticated;

create trigger exam_papers_page_roles_init after insert on public.exam_papers
for each row execute function public.paper_page_roles_init();

-- Papers registered before this migration: every page is an answer page, not yet reviewed.
insert into public.paper_page_roles (paper_id, page, role)
select p.id, g.page, 'answer'
from public.exam_papers p
cross join lateral generate_series(1, p.page_count) as g(page)
where p.kind = 'paper';

-- ---------------------------------------------------------------------------------------------
-- Set the roles of every page of a paper: p_roles = [{"page":1,"role":"cover"}, ...], each page exactly once.
-- ---------------------------------------------------------------------------------------------
create function public.set_paper_page_roles(p_paper uuid, p_roles jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_p public.exam_papers%rowtype;
  v_locked boolean := false;
  v_n int;
begin
  if not exists (
    select 1 from public.profiles a
    where a.id = v_actor and a.status = 'active' and a.role in ('owner', 'admin') for share) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_paper is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_p from public.exam_papers p where p.id = p_paper and p.kind = 'paper' for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  if p_roles is null or jsonb_typeof(p_roles) <> 'array' then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  v_n := jsonb_array_length(p_roles);
  if v_n <> v_p.page_count
     or exists (
       select 1 from jsonb_array_elements(p_roles) e
       where jsonb_typeof(e) <> 'object'
          or jsonb_typeof(e -> 'page') is distinct from 'number'
          or jsonb_typeof(e -> 'role') is distinct from 'string'
          or (e ->> 'page') !~ '^[0-9]{1,4}$'
          or (e ->> 'page')::int not between 1 and v_p.page_count
          or (e ->> 'role') not in ('answer', 'cover', 'blank', 'information'))
     or (select count(distinct (e ->> 'page')::int) from jsonb_array_elements(p_roles) e) <> v_p.page_count then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  -- Once a script page exists the roles decide how scans were matched; they must not move.
  if to_regclass('public.script_pages') is not null then
    execute 'select exists (select 1 from public.script_pages s join public.paper_copies c on c.id = s.copy_id where c.paper_id = $1)'
      into v_locked using v_p.id;
    if v_locked then
      return jsonb_build_object('ok', false, 'code', 'conflict');
    end if;
  end if;

  update public.paper_page_roles r
  set role = (e ->> 'role')::public.page_role
  from jsonb_array_elements(p_roles) e
  where r.paper_id = v_p.id and r.page = (e ->> 'page')::int;
  update public.exam_papers set pages_reviewed_at = now() where id = v_p.id;
  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'paper_page_roles_set', 'exam_paper', v_p.id);
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Replace the hidden areas of a paper: p_areas = [{"page":1,"x":0.1,"y":0.2,"w":0.3,"h":0.05}, ...]. Returns the
-- pages whose areas changed (their masked scans are redone).
-- ---------------------------------------------------------------------------------------------
create function public.set_paper_hidden_areas(p_paper uuid, p_areas jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_p public.exam_papers%rowtype;
  v_changed int[];
begin
  if not exists (
    select 1 from public.profiles a
    where a.id = v_actor and a.status = 'active' and a.role in ('owner', 'admin') for share) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_paper is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_p from public.exam_papers p where p.id = p_paper and p.kind = 'paper' for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  if p_areas is null or jsonb_typeof(p_areas) <> 'array' then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if exists (
       select 1 from jsonb_array_elements(p_areas) e
       where jsonb_typeof(e) <> 'object'
          or jsonb_typeof(e -> 'page') is distinct from 'number'
          or jsonb_typeof(e -> 'x') is distinct from 'number'
          or jsonb_typeof(e -> 'y') is distinct from 'number'
          or jsonb_typeof(e -> 'w') is distinct from 'number'
          or jsonb_typeof(e -> 'h') is distinct from 'number'
          or (e ->> 'page') !~ '^[0-9]{1,4}$'
          or (e ->> 'page')::int not between 1 and v_p.page_count
          or (e ->> 'x')::numeric < 0 or (e ->> 'y')::numeric < 0
          or (e ->> 'w')::numeric <= 0 or (e ->> 'h')::numeric <= 0
          or (e ->> 'x')::numeric + (e ->> 'w')::numeric > 1
          or (e ->> 'y')::numeric + (e ->> 'h')::numeric > 1)
     or exists (
       select 1 from jsonb_array_elements(p_areas) e
       group by (e ->> 'page')::int having count(*) > 20) then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  select coalesce(array_agg(d.page order by d.page), '{}') into v_changed
  from (
    select page from (
      (select page, x, y, w, h from public.paper_hidden_areas where paper_id = v_p.id
       except
       select (e ->> 'page')::int, (e ->> 'x')::numeric, (e ->> 'y')::numeric, (e ->> 'w')::numeric, (e ->> 'h')::numeric
       from jsonb_array_elements(p_areas) e)
      union all
      (select (e ->> 'page')::int, (e ->> 'x')::numeric, (e ->> 'y')::numeric, (e ->> 'w')::numeric, (e ->> 'h')::numeric
       from jsonb_array_elements(p_areas) e
       except
       select page, x, y, w, h from public.paper_hidden_areas where paper_id = v_p.id)
    ) diff group by page
  ) d;

  delete from public.paper_hidden_areas where paper_id = v_p.id;
  insert into public.paper_hidden_areas (paper_id, page, x, y, w, h, created_by)
  select v_p.id, (e ->> 'page')::int, (e ->> 'x')::numeric, (e ->> 'y')::numeric, (e ->> 'w')::numeric,
         (e ->> 'h')::numeric, v_actor
  from jsonb_array_elements(p_areas) e;

  insert into public.audit_log (actor_id, action, target_type, target_id)
  values (v_actor, 'paper_hidden_areas_set', 'exam_paper', v_p.id);
  return jsonb_build_object('ok', true, 'changed_pages', to_jsonb(v_changed));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- What the admin panel shows: {pages:[{page, role}], areas:[{id, page, x, y, w, h}], reviewed_at}.
-- ---------------------------------------------------------------------------------------------
create function public.paper_page_layout(p_paper uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_p public.exam_papers%rowtype;
begin
  if not (select public.is_staff_admin()) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select * into v_p from public.exam_papers p where p.id = p_paper and p.kind = 'paper';
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  return jsonb_build_object(
    'ok', true,
    'pages', coalesce((select jsonb_agg(jsonb_build_object('page', r.page, 'role', r.role) order by r.page)
                       from public.paper_page_roles r where r.paper_id = v_p.id), '[]'::jsonb),
    'areas', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'page', a.page, 'x', a.x, 'y', a.y, 'w', a.w, 'h', a.h)
                                        order by a.page, a.created_at, a.id)
                       from public.paper_hidden_areas a where a.paper_id = v_p.id), '[]'::jsonb),
    'reviewed_at', v_p.pages_reviewed_at);
end;
$$;

revoke execute on function public.set_paper_page_roles(uuid, jsonb) from public, anon;
revoke execute on function public.set_paper_hidden_areas(uuid, jsonb) from public, anon;
revoke execute on function public.paper_page_layout(uuid) from public, anon;
grant execute on function public.set_paper_page_roles(uuid, jsonb) to authenticated;
grant execute on function public.set_paper_hidden_areas(uuid, jsonb) to authenticated;
grant execute on function public.paper_page_layout(uuid) to authenticated;
