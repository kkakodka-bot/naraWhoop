# Tester enrollment identity

## Decision

FRWHOOP uses **enrollment codes** for the current tester cohort. Each tester has one stable
`auth.users.id`. A reinstall, replacement phone, or second phone receives a new enrollment code that
maps back to that same user. Email OTP or Apple sign-in remains the recovery path to add later when
self-service recovery is needed.

The fleet credential only proves that a build belongs to the test fleet. It never selects a user.
Every accepted upload is authorized by both:

```http
Authorization: Bearer <per-installation-upload-token>
X-NOOP-Fleet-Token: <fleet-token>
```

The per-installation token is bound server-side to one `user_id` and one `source_id`. The receiver
rejects a request when the batch or object `sourceId` does not match that binding. The fleet header is
sent only to the Supabase Edge receiver; neither credential is sent with the presigned B2 `PUT`.

## Identity model

| Identifier | Meaning | Lifetime |
|---|---|---|
| `user_id` | Supabase Auth user for one tester | Stable across installations, phones, and wearables |
| `source_id` | One app installation | Generated locally; rotates after reinstall or device restore when device-local identity state is absent or mismatched |
| `device_id` | Server-resolved wearable identity within a user/source scope | Changes when the local wearable identity changes |

The server derives `user_id` from the per-installation token. It never accepts a client-supplied user
ID. It validates `source_id` against the token binding and resolves `device_id` in the authenticated
user namespace before writing projections, manifests, or receipts.

Some older NOOP databases identify the wearable as `my-whoop`. That value distinguishes a local data
scope but does not prove the physical strap across a wearable swap. Serial-backed local IDs provide
better continuity; legacy data must not be relabeled as a globally stable hardware identity.

## Enrollment exchange

An operator creates a tester once, then issues a short-lived code for each installation. The code is
displayed as `NARA-XXXX-XXXX-XXXX-XXXX-XXXX`; only its normalized HMAC is stored. The HMAC pepper is an
Edge/ops secret and is never present in an app build.

```http
POST /functions/v1/push/enroll
Authorization: Bearer <fleet-token>
Content-Type: application/json

{
  "code": "NARA-XXXX-XXXX-XXXX-XXXX-XXXX",
  "sourceId": "3a3486dd-5030-4e17-a00d-a781399890f9",
  "platform": "ios",
  "appVersion": "10.6.0"
}
```

A successful response returns the raw upload token exactly once:

```json
{
  "type": "enrollment",
  "protocolVersion": "1.1",
  "userId": "3ab0c13e-842f-4d22-b25c-4ef9c730897d",
  "sourceId": "3a3486dd-5030-4e17-a00d-a781399890f9",
  "tokenId": "00000000-0000-4000-8000-000000000003",
  "uploadToken": "noop_..."
}
```

The app stores the response in Keychain or Android encrypted preferences. It never stores the
enrollment code. Capabilities must echo the bound `userId` and `sourceId`; a mismatch stops upload
before health data is read.

Redemption is atomic. A code cannot bind a second source. A brief same-source retry window allows an
app to repeat the exchange if the successful HTTP response was lost. The server deterministically
derives the same installation token from that code/source pair with a server-only pepper, so
duplicated or reordered responses cannot invalidate one another. A reinstall or new phone needs a
fresh code issued for the existing `user_id`.

## Persistence and audit

For every accepted batch or object, `noop_upload_receipts` records the server-resolved `user_id`,
bound `source_id`, resolved `device_id`, token, authorization mode, content hash, record count, and
acceptance time. Projection and object-manifest rows carry the same identity scope. A shared fleet
token is therefore never the only identity evidence for a personal upload.

Existing fleet-only upload behavior is disabled by default. A temporary operator-controlled legacy
flag may accept it during migration, but those receipts are marked `legacy_fleet`; they are not proof
of per-person identity. A pre-migration shared credential must be explicitly reclassified with
`mark-fleet-token`; ordinary legacy per-user tokens are never accepted in the fleet slot.

## Secret boundary

These values are server-side only:

- Supabase service-role or secret key
- enrollment-code HMAC pepper
- B2 credentials

Apps receive only the public Supabase Edge URL, the fleet credential, and their own installation
token. Admin scripts read secrets from environment variables and do not write them to the repository.

## Recovery

Enrollment codes intentionally provide operator-assisted recovery:

1. Look up the tester's existing `user_id`.
2. Issue a new code for that user.
3. Enroll the replacement installation, producing a new `source_id` and token.
4. Revoke the prior installation token if the old phone is lost or retired.

Do not create a new auth user for a returning tester. Email OTP or Apple sign-in can later replace
steps 1-2 with self-service recovery without changing the upload identity model.

## Operator commands

Run the helper only from an operator machine. Its environment is deliberately incompatible with an
app build:

```bash
export SUPABASE_URL='https://<project-ref>.supabase.co'
export SUPABASE_SERVICE_ROLE_KEY='<server-only-key>'
export NOOP_ENROLLMENT_PEPPER='<at-least-32-random-bytes>'

# New tester: creates one auth user and prints the first code once.
node Tools/enrollment/manage.mjs create-tester --label 'Tester 01'

# Reinstall/replacement phone: preserve the tester identity and issue a new code.
node Tools/enrollment/manage.mjs issue-code \
  --user-id 3ab0c13e-842f-4d22-b25c-4ef9c730897d \
  --label 'replacement iPhone'

# Create a new fleet authorization credential; the plaintext is printed once.
node Tools/enrollment/manage.mjs create-fleet-token --label 'internal cohort'

# Classify the already-distributed shared token during migration.
NOOP_FLEET_TOKEN='noop_...' node Tools/enrollment/manage.mjs mark-fleet-token

# Revoke a retired installation or fleet credential.
node Tools/enrollment/manage.mjs revoke-token \
  --token-id 17c9e1ab-40d1-468c-a4ba-a62f727e69aa
```

The helper generates 100-bit enrollment codes, stores only HMACs, and prints each raw code or token
once. Shell history and terminal capture remain operator responsibilities; inject existing tokens
through a protected environment variable rather than a command-line argument.

## Integrated client behavior

New installations and upgrades require enrollment and the current cloud disclosure before collection.
The same account screen is available in Settings. Upload and score readback use the personal
installation credential; there is no separate scoring-account login. A returning tester receives
a new code for the existing user, not a new user record.

The first server acknowledgement of the selected wearable is required before onboarding completes
or an upgraded app opens its main screens. The acknowledgement is scoped to endpoint, user,
installation, and local device. A previously confirmed device can collect while offline; queued
data is uploaded when connectivity returns. Phone storage remains necessary for BLE capture and
retry, but is an account-owned buffer rather than an independent account or canonical result store.

The enrolled database, IMU files, session metadata, and rejected-frame replay archives have
owner/installation scopes. Rejected-frame archives also require the logical and physical device.
Unowned pre-enrollment health history is preserved separately. Only pairing metadata can seed the
new empty database. Whole-database restore into an enrolled store is blocked. An upgrade does not
repeat the wearable storage-reset onboarding step.

Score requests specify a local device ID. The receiver resolves the owned canonical device and
returns both identities. These endpoints require the installation bearer and fleet header:

- `POST /functions/v1/scores/devices` with `{ "deviceId": "<local ID>" }` registers the device.
- `GET /functions/v1/scores?day=YYYY-MM-DD&deviceId=<local ID>` reads that device's results.
- `POST /functions/v1/scores/sleep-overrides` edits only that device's sleep with revision checks.

Explicit `whoop-<serial>` identifiers can establish wearable continuity within an owner. Legacy
`my-whoop`, bare serials, and provisional identifiers remain installation-scoped. The rollout
does not infer ownership of old fleet data or silently reattribute it to an enrolled tester.

## Rollout and rollback

1. Build and verify the enrollment-capable clients. Pin the receiver and migration files to a commit.
2. Apply `20260919200000_noop_enrollment_identity.sql` and
   `20260919210000_enrolled_device_scores.sql` together. For a rollback trial, remove the second
   file's explicit top-level `BEGIN`/`COMMIT` before wrapping both files in a transaction.
3. Configure a whitespace-free `NOOP_ENROLLMENT_PEPPER` identically in Edge and protected operator
   tooling. Set `NOOP_ALLOW_LEGACY_FLEET_UPLOADS=false`.
4. At the mandatory-update cutoff, classify the exact distributed token as fleet and deploy both
   `push` and `scores` with gateway JWT verification disabled. Their handlers enforce enrollment.
5. Issue tester codes, install clients, and verify capabilities identity, device acknowledgement,
   durable upload receipts, and selected-device score readback before expanding the cohort.

This is a deliberate cutoff: older fleet-only clients stop uploading, and old JWT/legacy-token
`/scores` calls no longer work. The legacy upload flag does not restore a token that has been
reclassified as fleet. Preserve the original token row's ownership metadata privately before
classification. Archive and scoring workers keep their separate server credentials.

Keep additive schema during rollback. Restoring the old receiver after issuing installation tokens
would remove source binding and fleet enforcement for those credentials: revoke them first or keep
the new authentication boundary in the rollback receiver. Disabling only the fleet token is not
sufficient protection with the old handler. If tester creation succeeds but code issuance fails,
recover with `issue-code` for that existing user.

See [the integration audit](physiology-v2/cloud-enrollment-integration-20260920.md) for the tested
counterexamples and the separation between source, hosted, and physical-device evidence.
