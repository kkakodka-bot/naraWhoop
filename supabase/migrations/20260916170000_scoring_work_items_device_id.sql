-- Phase 3 (Remaining 1): device-aware scoring work queue.
-- Identity becomes (user_id, device_id, day) so discovery, claim, and loadDay stay aligned.

alter table public.scoring_work_items
  add column if not exists device_id uuid references public.devices(id) on delete cascade;

-- Backfill-only: attach the user's most-recently-seen device to legacy (user, day) rows.
update public.scoring_work_items w
set device_id = d.id
from (
  select distinct on (user_id) user_id, id
  from public.devices
  order by user_id, last_seen_at desc nulls last
) d
where w.user_id = d.user_id
  and w.device_id is null;

-- Rows with no registered device cannot be scored; drop rather than leave a broken PK candidate.
delete from public.scoring_work_items
where device_id is null;

alter table public.scoring_work_items
  drop constraint if exists scoring_work_items_pkey;

alter table public.scoring_work_items
  alter column device_id set not null;

alter table public.scoring_work_items
  add primary key (user_id, device_id, day);

comment on table public.scoring_work_items is
  'Phase 3: durable score-on-arrival work queue (one row per user/device/local-day with new ingest).';
