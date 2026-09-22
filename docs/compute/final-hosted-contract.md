# Final hosted result contract

`GET /scores` uses the same validated selection for an installation credential plus fleet
credential, or an account JWT plus `x-noop-source-id`. The latter source must belong to the
authenticated owner. Both require an explicit external `deviceId`; the server resolves the
canonical device without choosing another wearable. `project` comes from Edge configuration.

`POST /scores/devices` accepts `{deviceId}` and returns
`{identity:{userId,sourceId,deviceId,externalDeviceId,project}}`. The authenticated JWT route
requires `x-noop-source-id`; registration binds its first owner through
`register_account_compute_source`/`compute_account_sources`. Subsequent reads require an existing,
unrevoked account source or installation belonging to that owner. A supplied source identifier is
not, by itself, authorization. Installation enrollment retains its source-bound credential surface.

The existing `server_scoring` schema 2 fields are unchanged. Contract revision 2 adds:

```json
{"compute":{"mode":"final_hosted","policy_version":"vps-only-1","project":"https://project.supabase.co","owner_id":"owner-uuid","source_id":"source-uuid","device_id":"device-uuid","day":"2026-09-21","families":{"ppg_hr":{"owner":"server","metrics":["derived_ppg_hr"],"status":"unqualified","reason":"optical_clock_channel_unqualified","result_revision":"compute:42","input_revision":17,"algorithm_version":"vps-only-1","model_version":null,"preprocessing_version":null,"quality_version":null,"configuration_version":"vps-only-1","manifest_hash":null,"feature_manifest_hash":null,"canonical_qualification":null,"project":"https://project.supabase.co","owner_id":"owner-uuid","source_id":"source-uuid","device_id":"device-uuid","window":"2026-09-21","timezone_id":"America/Los_Angeles","computed_at":"2026-09-22T07:01:00Z","observed_through":null,"freshness":"current","expires_at":null,"decision_id":null,"values":{"derived_ppg_hr":null},"details":{}}}}}
```

All 27 registry families are present. `metrics` and `values` use registry metric IDs. Ownership
is independent of availability. Before a result exists, a processing/unavailable state has a
null result revision and computed time; clients must not manufacture one. Published missing
states have immutable database revisions. Existing physiology result identities use their
stored payload hash, prefixed `sha256:`. Historical shadows never acquire canonical values.
The request `source_id` fences the read/cache; original input sources remain in result evidence.
Result metadata that was absent from a retained source contract remains null rather than being
invented. In particular, numeric `configuration_version` can be null with
`details.configuration_metadata_status=unavailable_in_source_contract`; that does not manufacture
a new configuration identity. The required session-request versions below remain `vps-only-1`.

`POST /scores/compute-requests` accepts `{deviceId,request}`. The request contains `id`, `family`,
`session_id`, `event_start`, nullable `event_end`, `timezone_id`, `input_revision`,
`algorithm_version` and `configuration_version` (both `vps-only-1`), `consent`, and nullable
`expires_at`. IDs are UUIDs; times are ISO 8601; timezone is IANA. Retry uses the identical ID
and body. Reusing an ID with different input is a conflict, not an edit. Edits create a new
request and input revision. A request does not attest input qualification.

`GET /scores/compute-requests?deviceId=...&requestId=...` returns
`{request_id,state,result}` with a nullable family result. Workers independently publish
abstention states where no qualified producer exists. Time-sensitive requests require an expiry
within five minutes of their event, and expired results cannot cause coaching/haptic replay.
Result revisions are prefixed `session:`. A persisted client decision ID is consumed at most once.

The additive migration and worker must be integrated before the phone release. A missing or
older server contract remains unavailable on a final-hosted client; it never enables local scoring.

## Consumer exports and Health admission

Apple `canonical_results.json` and `noop_server_results.json` use export schema 1:
`{schema_version:1,windows:[{ledger,current_result,historical_result}]}`. Each window carries its
full ownership/read-state ledger. Only admitted current reads populate `current_result`; failed,
pending or cached reads can retain the original immutable payload as `historical_result`, never
as a current measurement. CSV includes `read_state` and `cached`, with numeric cells blank for
those reads. ZIP exports include the same JSON, ledger and CSV. Original imported rows remain
separately labelled historical provenance. The old unrevisioned shortcut file is emptied before
publishing the replacement document, so an old automation cannot replay local derived data.

Android ZIP exports instead contain `index.json` with format `noop-canonical-compute-1` and
unchanged per-day server envelopes named `YYYY-MM-DD.json`. The index includes project/owner,
family IDs and per-day `stale`, `read_failure`, and `result_revisions`. Its top-level state is
`unavailable` or `immutable_cached_results`; an archived envelope is not a newly current reading.
This is intentionally not Apple's schema 1 document shape. Both formats retain read-state and
revision evidence without reconstructing physiology.

Widget/watch builders, Health records and exports carry the same family receipt. Publication
checks include the full read state as well as identity; even a read failure with an unchanged
result revision invalidates an in-flight write. File-provider access and Health delete/save
boundaries recheck account, device and admission. No physiological reconstruction occurs there.

Health Connect does not accept an HRV value of zero. A canonical zero remains zero in the result,
widget and export; the Health adapter records `health_export_unsupported` with an explicit
unsupported/partial export state instead of clamping or fabricating a positive measurement.
Health permissions/provider delivery still require device validation.
