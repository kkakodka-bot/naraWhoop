-- Phase 5: derived-artifact lane retry bookkeeping on the scoring work queue.
-- Scores commit even when B2 archive fails; this column records the last failure for ops.

alter table public.scoring_work_items
  add column if not exists derived_artifact_error text,
  add column if not exists derived_artifact_at timestamptz;

comment on column public.scoring_work_items.derived_artifact_error is
  'Last B2 derived-archive failure for this day; null when the latest score archived successfully.';
comment on column public.scoring_work_items.derived_artifact_at is
  'When derived_artifact_error was last set (success clears the error but does not reset this timestamp).';
