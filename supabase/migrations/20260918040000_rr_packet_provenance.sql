-- Additive immutable packet receipts. Legacy value-keyed RR rows are neither rewritten nor promoted
-- into original beat identities. No field here asserts a verified subsecond clock.
create table public.noop_rr_packet_provenance (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  source_id uuid,
  "packetId" text not null check ("packetId" ~ '^[a-f0-9]{64}$'),
  ts bigint not null,
  "sensorTs" bigint not null,
  "recordIndex" bigint not null check ("recordIndex" between 0 and 4294967295),
  "rawHex" text not null check (length("rawHex") between 56 and 131086 and length("rawHex") % 2 = 0 and "rawHex" ~ '^[a-f0-9]+$'),
  "srcChannel" integer not null check ("srcChannel" = 5),
  "schemaVersion" integer not null check ("schemaVersion" = 1),
  "decoderVersion" text not null check ("decoderVersion" = 'whoop5-v18-original-words-v1'),
  "clockVersion" text not null check ("clockVersion" in ('sensor-second-unmapped','legacy-stale-clock-snap300-v1')),
  "timestampPrecisionSeconds" double precision not null check ("timestampPrecisionSeconds" in (1,300)),
  "clockOffsetSeconds" bigint not null,
  "declaredCount" integer not null check ("declaredCount" between 0 and 255),
  batch_id uuid,
  ingested_at timestamptz not null default now(),
  primary key(user_id,device_id,"packetId"),
  check (ts-"sensorTs" = "clockOffsetSeconds")
);
create index noop_rr_packet_provenance_owner_time on public.noop_rr_packet_provenance(user_id,device_id,ts);
alter table public.noop_rr_packet_provenance enable row level security;
create policy rr_packet_owner_read on public.noop_rr_packet_provenance for select to authenticated
  using (user_id=(select auth.uid()));
create policy rr_packet_service on public.noop_rr_packet_provenance for all to service_role using(true) with check(true);
grant select on public.noop_rr_packet_provenance to authenticated;
grant all on public.noop_rr_packet_provenance to service_role;
create trigger scoring_dirty_insert after insert on public.noop_rr_packet_provenance
  referencing new table as new_rows for each statement execute function public.scoring_dirty_projection();
create trigger scoring_dirty_update after update on public.noop_rr_packet_provenance
  referencing old table as old_rows new table as new_rows for each statement execute function public.scoring_dirty_projection();
create trigger scoring_dirty_delete after delete on public.noop_rr_packet_provenance
  referencing old table as old_rows for each statement execute function public.scoring_dirty_projection();
