-- Manual Event Recorder labels delivered through the NOOP push replace-window stream.
-- `id` stays server-namespaced; `external_id` is the stable UUID created on the phone.
alter table public.noop_event_labels
  add column if not exists external_id uuid,
  add column if not exists time_zone_identifier text,
  add column if not exists local_source text,
  add column if not exists source_id uuid,
  add column if not exists batch_id uuid,
  add column if not exists replacement_id uuid;

update public.noop_event_labels
set external_id = id
where external_id is null;

alter table public.noop_event_labels
  alter column external_id set not null;

create unique index if not exists noop_event_labels_user_external_id_uidx
  on public.noop_event_labels (user_id, external_id);

create index if not exists noop_event_labels_device_start_idx
  on public.noop_event_labels (user_id, device_id, start_ts desc);

comment on column public.noop_event_labels.external_id is
  'Stable event UUID created by the originating phone; server id is user-namespaced.';
comment on column public.noop_event_labels.local_source is
  'Original client provenance such as manual_experiment; source retains the controlled evidence vocabulary.';
