-- Part 2 Task 7: when a booking was paid (money basis) and the owner/admin money totals.

-- 1. bookings.paid_at: set once, the first time a booking is paid (or created paid), never cleared.
alter table public.bookings add column paid_at timestamptz;

-- Backfill: rows that were paid at some point get their last update time as the best estimate.
update public.bookings
set paid_at = updated_at
where paid_at is null
  and (status in ('paid', 'cancel_requested', 'part_refunded', 'refunded')
       or refunded_pence > 0
       or refund_due = true);

create function public.bookings_set_paid_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.paid_at is null and old.paid_at is not null then
    new.paid_at := old.paid_at;
  end if;
  if new.status = 'paid' and new.paid_at is null then
    new.paid_at := now();
  end if;
  return new;
end;
$$;

create trigger bookings_set_paid_at
before insert or update on public.bookings
for each row execute function public.bookings_set_paid_at();

create index bookings_paid_at_idx on public.bookings (paid_at) where paid_at is not null;

-- 2. Money totals for owner/admin. Money taken = amount when paid_at is set, else 0. Refunds count against
-- the period the booking was paid in. Dates are London calendar dates, both ends inclusive.
create function public.money_totals(p_from date, p_to date)
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
    where a.id = v_actor and a.status = 'active' and a.role in ('owner', 'admin') for share) then
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
