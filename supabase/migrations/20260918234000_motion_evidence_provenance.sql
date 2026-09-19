begin;

-- Earlier receivers coerced explicit null/false/empty strings to numeric zero.
-- Retain those source values, but never retrospectively attest their meaning.
alter table public.noop_gravity_samples add column motion_evidence_version text;
alter table public.noop_gravity_samples add column orientation_evidence_version text;
alter table public.noop_gravity_samples add constraint noop_gravity_orientation_evidence_contract
  check (orientation_evidence_version is null or (
    orientation_evidence_version='projected-gravity-g-1'
    and ts between -9007199254740991 and 9007199254740991
    and x not in ('NaN'::double precision,'Infinity'::double precision,'-Infinity'::double precision)
    and y not in ('NaN'::double precision,'Infinity'::double precision,'-Infinity'::double precision)
    and z not in ('NaN'::double precision,'Infinity'::double precision,'-Infinity'::double precision)));
alter table public.noop_gravity_samples add constraint noop_gravity_motion_evidence_contract
  check (motion_evidence_version is null or (
    motion_evidence_version='projected-dynamic-acceleration-g-1'
    and orientation_evidence_version is not null
    and orientation_evidence_version='projected-gravity-g-1'
    and "dynAccel" is not null and "dynAccel">=0 and "dynAccel"<=8));
comment on column public.noop_gravity_samples.orientation_evidence_version is
  'Receiver attestation of genuinely numeric finite gravity XYZ and a safe-integer numeric timestamp. NULL means unavailable provenance, including all pre-migration rows; never backfill from numeric columns alone. Physical gravity validity is evaluated separately.';
comment on column public.noop_gravity_samples.motion_evidence_version is
  'Receiver attestation of a genuinely numeric finite 0..8 g dynamic-acceleration field. NULL means unavailable provenance, including all pre-migration rows; never backfill from the stored scalar alone.';

-- Existing statement-level scoring_dirty_update compares complete row JSON, so
-- adding/removing this proof invalidates the dependent input revision atomically.
commit;
