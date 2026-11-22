-- Phase 3A, Task 9: clean up page pictures that nothing points at.
--
-- A prepare that is retried, a rerun of matching, a remask and a "name hidden" redo each store new pictures in the
-- bucket script-pages (<exam>/<upload>/<job>-<attempt>/<source_index>-full.jpg and -marking.jpg) and leave the old ones
-- behind. script_pictures_unused_take lists those objects for the processing server, which deletes them.
-- Only the bucket script-pages is looked at. The originals in script-uploads are never listed and never deleted.
--
-- An object is listed only when ALL of these hold (when in doubt it is kept):
--   - its name has exactly the shape the processing server writes (anything else is never touched);
--   - it was created more than 24 hours before p_now;
--   - no script_pages row has it as full_path or marking_path (a replaced row, replaced_at set, still counts while the
--     row exists; marking_checked_path is only a record of what was checked, so it does not count);
--   - its upload (the second part of the name) has no processing job queued or running.

create index script_pages_full_path_idx on public.script_pages (full_path);
-- (Task 6 made script_pages_marking_path_idx for current rows only; this one also holds replaced rows.)
create index script_pages_marking_path_any_idx on public.script_pages (marking_path) where marking_path is not null;

create function public.script_pictures_unused_take(p_limit int default 500, p_now timestamptz default null)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('name', t.name) order by t.created_at, t.name), '[]'::jsonb)
  from (
    select o.name, o.created_at
    from storage.objects o
    where o.bucket_id = 'script-pages'
      and o.name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9]+-[0-9]+/[0-9]+-(full|marking)\.jpg$'
      and o.created_at < public.paper_clock(p_now) - interval '24 hours'
      and not exists (select 1 from public.script_pages p where p.full_path = o.name or p.marking_path = o.name)
      and not exists (select 1 from public.processing_jobs j
                      where j.upload_id::text = split_part(o.name, '/', 2) and j.state in ('queued', 'running'))
    order by o.created_at, o.name
    limit least(greatest(coalesce(p_limit, 500), 1), 1000)
  ) t
$$;

revoke execute on function public.script_pictures_unused_take(int, timestamptz) from public, anon, authenticated;
grant execute on function public.script_pictures_unused_take(int, timestamptz) to service_role;
