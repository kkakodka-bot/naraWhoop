-- Original 0x2A37 notification bytes and receipt clocks, independent of value-keyed RR rows.
-- No host-arrival clock is promoted into a sensor beat clock by this additive storage lane.
begin;

create table public.noop_standard_hr_receipts (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  source_id uuid,
  "receiptId" text not null,
  ts bigint not null check (ts >= 0),
  "sessionId" text not null check ("sessionId" ~ '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'),
  "notificationOrdinal" bigint not null check ("notificationOrdinal" between 0 and 9007199254740991),
  "receivedUnixMs" bigint not null check ("receivedUnixMs" between 0 and 9007199254740991),
  "receivedMonotonicNs" bigint not null check ("receivedMonotonicNs" >= 0),
  "rawHex" text not null check (length("rawHex") between 2 and 1024 and length("rawHex") % 2 = 0 and "rawHex" ~ '^[a-f0-9]+$'),
  "schemaVersion" integer not null check ("schemaVersion" = 1),
  "clockVersion" text not null check ("clockVersion" = 'host-arrival-unmapped'),
  batch_id uuid,
  ingested_at timestamptz not null default now(),
  primary key(user_id,device_id,"receiptId"),
  foreign key(user_id,device_id) references public.devices(user_id,id) on delete cascade,
  check ("receiptId" = "sessionId" || ':' || "notificationOrdinal"::text),
  check (ts = "receivedUnixMs" / 1000)
);
create index noop_standard_hr_receipts_owner_time on public.noop_standard_hr_receipts(user_id,device_id,ts);
alter table public.noop_standard_hr_receipts enable row level security;
create policy standard_hr_owner_read on public.noop_standard_hr_receipts for select to authenticated
  using (user_id=(select auth.uid()));
create policy standard_hr_service on public.noop_standard_hr_receipts for all to service_role
  using(true) with check(true);
revoke all on public.noop_standard_hr_receipts from public, anon, authenticated;
grant select on public.noop_standard_hr_receipts to authenticated;
grant all on public.noop_standard_hr_receipts to service_role;

-- The receiver upserts append batches. A replay may refresh delivery metadata, but must
-- never replace the first packet/clock evidence under an existing notification identity.
create function public.preserve_standard_hr_receipt() returns trigger
language plpgsql set search_path='' as $$
begin
  new.source_id := old.source_id;
  if (to_jsonb(new)-array['batch_id','ingested_at']) is distinct from
     (to_jsonb(old)-array['batch_id','ingested_at']) then
    raise exception 'standard HR receipt identity conflict' using errcode='23514';
  end if;
  return new;
end $$;
revoke all on function public.preserve_standard_hr_receipt() from public,anon,authenticated;
create trigger preserve_standard_hr_receipt before update on public.noop_standard_hr_receipts
  for each row execute function public.preserve_standard_hr_receipt();

create trigger scoring_dirty_insert after insert on public.noop_standard_hr_receipts
  referencing new table as new_rows for each statement execute function public.scoring_dirty_projection();
create trigger scoring_dirty_update after update on public.noop_standard_hr_receipts
  referencing old table as old_rows new table as new_rows for each statement execute function public.scoring_dirty_projection();
create trigger scoring_dirty_delete after delete on public.noop_standard_hr_receipts
  referencing old table as old_rows for each statement execute function public.scoring_dirty_projection();

commit;
