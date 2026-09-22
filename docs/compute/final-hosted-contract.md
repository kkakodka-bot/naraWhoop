# Final hosted result contract

`GET /scores` uses the same validated selection for an installation credential plus fleet
credential, or an account JWT plus `x-noop-source-id`. The latter source must belong to the
authenticated owner. Both require an explicit external `deviceId`; the server resolves the
canonical device without choosing another wearable. `project` comes from Edge configuration.

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
