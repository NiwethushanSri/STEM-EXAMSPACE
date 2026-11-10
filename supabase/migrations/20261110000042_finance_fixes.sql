-- Part 2 Task 7 fix round 1.

-- 1. paid_at is fixed once set: an update can neither clear nor move it.
create or replace function public.bookings_set_paid_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    new.paid_at := coalesce(old.paid_at, new.paid_at);
  end if;
  if new.status = 'paid' and new.paid_at is null then
    new.paid_at := now();
  end if;
  return new;
end;
$$;

-- 2. money_totals without the row lock on the caller's profile (same body otherwise; grants kept).
create or replace function public.money_totals(p_from date, p_to date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_start timestamptz;
  v_end timestamptz;
  v_out jsonb;
begin
  if not exists (
    select 1 from public.profiles a
    where a.id = v_actor and a.status = 'active' and a.role in ('owner', 'admin')) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  v_start := p_from::timestamp at time zone 'Europe/London';
  v_end := (p_to + 1)::timestamp at time zone 'Europe/London';

  with p as (
    select b.exam_id, b.amount_pence::bigint as taken, b.refunded_pence::bigint as refunded,
           to_char(b.paid_at at time zone 'Europe/London', 'YYYY-MM') as m
    from public.bookings b
    where b.paid_at >= v_start and b.paid_at < v_end),
  months as (
    select m, sum(taken)::bigint t, sum(refunded)::bigint r, count(*)::bigint n from p group by m),
  exams as (
    select p.exam_id, s.name as subject, e.title, e.starts_at,
           sum(p.taken)::bigint t, sum(p.refunded)::bigint r, count(*)::bigint n
    from p
    join public.exams e on e.id = p.exam_id
    join public.subjects s on s.id = e.subject_id
    group by p.exam_id, s.name, e.title, e.starts_at)
  select jsonb_build_object(
    'ok', true,
    'months', coalesce((select jsonb_agg(jsonb_build_object(
        'month', m, 'taken', t, 'refunded', r, 'net', t - r, 'bookings', n) order by m) from months), '[]'::jsonb),
    'exams', coalesce((select jsonb_agg(jsonb_build_object(
        'examId', exam_id, 'subject', subject, 'title', title, 'startsAt', starts_at,
        'taken', t, 'refunded', r, 'net', t - r, 'bookings', n) order by starts_at, exam_id) from exams), '[]'::jsonb),
    'total', jsonb_build_object(
        'taken', (select coalesce(sum(taken), 0)::bigint from p),
        'refunded', (select coalesce(sum(refunded), 0)::bigint from p),
        'net', (select coalesce(sum(taken) - sum(refunded), 0)::bigint from p)))
  into v_out;
  return v_out;
end;
$$;

revoke execute on function public.money_totals(date, date) from public, anon;
grant execute on function public.money_totals(date, date) to authenticated;
