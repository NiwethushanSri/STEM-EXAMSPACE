-- Fix: function EXECUTE is checked against the calling role (anon), not the view owner, so the public
-- view cannot call seats_taken (not granted to anon). Count seats inline; table access runs as the owner.
create or replace view public.exams_public as
select
  e.id,
  s.name as subject,
  e.title,
  e.paper,
  e.format,
  v.name as venue,
  e.room,
  e.starts_at,
  e.duration_minutes,
  e.price_pence,
  e.booking_deadline,
  greatest(e.seat_limit - (
    select count(*)::int from public.bookings b
    where b.exam_id = e.id and b.status in ('awaiting_payment', 'paid', 'cancel_requested')), 0) as seats_left
from public.exams e
join public.subjects s on s.id = e.subject_id
left join public.venues v on v.id = e.venue_id
where e.status = 'published';
