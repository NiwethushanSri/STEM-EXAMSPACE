-- Invitations: staff roles are chosen server-side (service role) by writing a row here.
-- The sign-up trigger consumes the row when a user with that email is created.
create table public.pending_invites (
  email extensions.citext primary key check (email::text = lower(btrim(email::text))),
  token uuid not null default gen_random_uuid(),
  role public.app_role not null check (role <> 'student'),
  invited_by uuid,
  created_at timestamptz not null default now()
);
alter table public.pending_invites enable row level security;
revoke all on public.pending_invites from anon, authenticated;

-- Sign-up: build the profile. Role and status are never taken from client metadata.
create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text := lower(btrim(coalesce(new.email, '')));
  v_meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_first text := coalesce(v_meta ->> 'first_name', '');
  v_last text := coalesce(v_meta ->> 'last_name', '');
  v_invite_role public.app_role;
  v_dob date;
begin
  -- An invite applies only if the email matches AND the server-set app_metadata
  -- invite_token matches. Clients cannot set app_metadata on public sign-up.
  begin
    select i.role into strict v_invite_role
    from public.pending_invites i
    where lower(i.email::text) = v_email
      and i.token::text = new.raw_app_meta_data ->> 'invite_token';
  exception when no_data_found then
    v_invite_role := null;
  end;

  if v_invite_role is not null then
    insert into public.profiles (id, role, status, first_name, last_name, email)
    values (new.id, v_invite_role, 'active', v_first, v_last, v_email);
    delete from public.pending_invites where lower(email::text) = v_email;
    return new;
  end if;

  begin
    v_dob := nullif(btrim(v_meta ->> 'date_of_birth'), '')::date;
  exception when others then
    v_dob := null;
  end;

  insert into public.profiles (id, role, status, first_name, last_name, email)
  values (
    new.id, 'student',
    case when new.email_confirmed_at is not null then 'pending'::public.account_status
         else 'unconfirmed'::public.account_status end,
    v_first, v_last, v_email);

  insert into public.student_details (profile_id, date_of_birth, school, signup_parent_name, signup_parent_email)
  values (
    new.id,
    v_dob,
    v_meta ->> 'school',
    v_meta ->> 'parent_name',
    lower(btrim(v_meta ->> 'parent_email'))
  );

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Email confirmation: unconfirmed -> pending (never touches any other status).
create function public.handle_email_confirmed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.email_confirmed_at is null and new.email_confirmed_at is not null then
    update public.profiles
      set status = 'pending'
      where id = new.id and status = 'unconfirmed';
  end if;
  return new;
end;
$$;

create trigger on_auth_user_email_confirmed
  after update of email_confirmed_at on auth.users
  for each row execute function public.handle_email_confirmed();

-- Guard: end-user roles (authenticated, anon) cannot change role, status or index_number.
-- SECURITY INVOKER so current_user is the caller; definer functions owned by postgres
-- and service_role/postgres sessions pass. No client-settable switch is consulted.
create function public.guard_protected_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_changed boolean;
begin
  if tg_table_name = 'profiles' then
    v_changed := new.role is distinct from old.role or new.status is distinct from old.status;
  else
    v_changed := new.index_number is distinct from old.index_number;
  end if;

  if v_changed and current_user in ('authenticated', 'anon') then
    raise exception 'protected column change not permitted' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger guard_profiles_protected
  before update on public.profiles
  for each row execute function public.guard_protected_columns();

create trigger guard_student_details_protected
  before update on public.student_details
  for each row execute function public.guard_protected_columns();

revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.handle_email_confirmed() from public, anon, authenticated;
revoke execute on function public.guard_protected_columns() from public, anon, authenticated;
