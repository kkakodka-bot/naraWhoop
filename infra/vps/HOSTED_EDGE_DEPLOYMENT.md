# Hosted Edge deployment gate

This procedure targets only the hosted Supabase project
`sgoyxzcagqyxexmsidtk`. It is not deployment authorization. The retained
`scripts/deploy-edge-functions.sh` is a different, legacy self-hosted VPS workflow and must not be
used for this hosted project.

The hosted deployer accepts only the six reviewed functions, in this order:

```text
account-deletion,ingest-verify,push,reconcile,retention-sweep,scores
```

It first verifies the aggregate phone-test artifact manifest against the exact candidate commit and
artifact root. The requested Edge directory and SHA-256 must be the Edge artifact named by that
manifest. The parity executable must be byte-for-byte identical to
`infra/vps/scripts/verify-hosted-score-route-parity.mjs` in the same candidate commit; the deployer
runs a private staged copy of those committed bytes.

The deployer stages Edge source from the verified deterministic tar, checks a pinned Supabase CLI
version and executable SHA-256, confirms the authenticated CLI can see the exact project, and records
the existing function identities. It deploys each role from the temporary source with Supabase CLI
`--use-api --no-verify-jwt`. After every deployment, and in the final discovery, all six exact roles
must have an ID, a version, `ACTIVE` status, and `verify_jwt=false`. The deployed role's version must
advance, and the final list must still match all six recorded post-deploy identities. No mutable
checkout source is sent.

Use the Supabase CLI and authentication environment supplied by the authorized operator. Do not put
an access token in command-line arguments or evidence. Pin the reviewed CLI version and Edge bundle
SHA-256:

```sh
node infra/vps/scripts/deploy-hosted-edge-functions.mjs deploy \
  --project-ref sgoyxzcagqyxexmsidtk \
  --repo-root /reviewed/release-integration \
  --artifact-root /reviewed/phone-test-artifacts \
  --release-manifest /reviewed/phone-test-artifacts/release-manifest.json \
  --bundle /reviewed/phone-test-artifacts/edge-source-bundle \
  --expected-bundle-sha REVIEWED_SHA256 \
  --functions account-deletion,ingest-verify,push,reconcile,retention-sweep,scores \
  --supabase-cli /absolute/path/to/supabase \
  --expected-cli-version 2.75.0 \
  --expected-cli-sha REVIEWED_SUPABASE_CLI_SHA256 \
  --parity-command /reviewed/deployment-source/infra/vps/scripts/verify-hosted-score-route-parity.mjs \
  --receipt /protected/new-hosted-edge-receipt.json
```

The parity executable is repository-owned deployment tooling. The deployer checks its
`frwhoop-hosted-score-route-parity` version-1 contract before the first mutation. For the post-deploy
read, inject a reviewed account session and installation for the same owner/source/device using this
protected environment:

```text
FRWHOOP_HOSTED_ACCOUNT_JWT
FRWHOOP_HOSTED_ANON_KEY
FRWHOOP_HOSTED_ENROLLMENT_TOKEN
FRWHOOP_HOSTED_FLEET_TOKEN
FRWHOOP_HOSTED_USER_ID
FRWHOOP_HOSTED_SOURCE_ID
FRWHOOP_HOSTED_DEVICE_ID
FRWHOOP_HOSTED_DAY
```

The deployer gives the Supabase CLI only its access token plus the small process, TLS, and proxy
environment allowlist. The parity process receives only its eight `FRWHOOP_HOSTED_*` values plus the
process, TLS, and proxy allowlist. The Supabase access token never reaches parity, and phone/account
credentials never reach the Supabase CLI.

The verifier performs real GET requests to the production `scores` function through both account JWT
and enrollment-token authentication. It requires HTTP 200, JSON, `cache-control: no-store`, and the
expected owner/source/device/project identity. It validates contract revision 2, `final_hosted` mode,
the exact 27-family set, family scope, immutable result revisions, explicit values, and canonical
qualification before comparing the two canonical envelopes. A pending-device envelope is accepted
only when device identities and all family revisions and values are explicitly unavailable. Null and
numeric zero remain distinct. The 30-second timeout covers response-body consumption; streaming is
aborted as soon as a body exceeds 2 MiB. Output records only response-envelope hashes. Credentials and
response bodies are neither printed nor stored in the deployment receipt.

The receipt is written and fsynced before each remote mutation. It records the aggregate manifest and
candidate identities, expected and actual CLI hash/version provenance, Edge release identity, prior
and deployed function IDs/versions/status/JWT policy, command output hashes, final function
identities, and the separate route-parity result. A failed function stops later deployments.
The tool never guesses a rollback or deploys old worktree bytes. A partial receipt names the mixed
state and requires either forward completion from the same reviewed bundle or a separately authorized
rollback using reviewed prior bundle bytes and the recorded prior identities.
