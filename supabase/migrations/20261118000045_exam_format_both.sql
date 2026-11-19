-- Phase 1A Task 1: an exam can offer both sittings. `in_person` stays centre only, `online` stays home only.
-- Own migration: a new enum value cannot be used in the transaction that adds it.
alter type public.exam_format add value if not exists 'both';
