-- Phase 3A final review, I1: the mark scheme PDF is closed to markers until marking opens.
--
-- Before, any approved marker of the subject could read (and, through a storage list, find) every stored mark scheme of
-- that subject, including the mark scheme of an exam not yet sat.
--
-- Changed, from its latest definition:
--   mark_scheme_path_allowed (20261122000003): the marker branch. An approved marker of the exam's subject now reads
--     the stored PDF only while the exam's marking is open (exam_marking.opened_at is set and closed_at is not), and
--     only when one of these holds: they hold a piece of that exam (an open live assignment), they have a live marking
--     on a piece of it that is not set aside (in progress or submitted), or they are the subject's lead marker.
--     Editors (structure_can_edit: owner, admin, a teacher of the subject) keep their access, before, during and after
--     marking. The stored-files rule (state = 'stored') is unchanged.
-- Nothing else changed: the policies on storage.objects call this function and are left as they are.

create or replace function public.mark_scheme_path_allowed(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.exam_mark_scheme_files f
    join public.exams e on e.id = f.exam_id
    where f.storage_path = p_name and f.state = 'stored'
      and (public.structure_can_edit((select auth.uid()), f.exam_id)
           or (public.is_marker_for((select auth.uid()), e.subject_id)
               and exists (select 1 from public.exam_marking m
                           where m.exam_id = f.exam_id and m.opened_at is not null and m.closed_at is null)
               and (public.is_lead_for((select auth.uid()), e.subject_id)
                    or exists (select 1 from public.marking_assignments a
                               join public.marking_units u on u.id = a.unit_id
                               where u.exam_id = f.exam_id and a.marker_id = (select auth.uid())
                                 and a.kind = 'live' and a.ended_at is null)
                    or exists (select 1 from public.markings x
                               join public.marking_units u on u.id = x.unit_id
                               where u.exam_id = f.exam_id and x.marker_id = (select auth.uid())
                                 and x.kind = 'live' and x.status <> 'set_aside')))))
$$;

revoke execute on function public.mark_scheme_path_allowed(text) from public, anon;
grant execute on function public.mark_scheme_path_allowed(text) to authenticated;
