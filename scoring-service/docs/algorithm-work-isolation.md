# Independent baseline and shadow work

The v1 baseline and v2 shadow worker have separate queues, leases, retries and heartbeats.
A direct input change invalidates both queues in the ingestion transaction. An explicit replay
or HRV-derived dependency refresh affects only the algorithm that consumes it. Completing one
algorithm cannot consume another's work. Canonical feature defaults remain `frwhoop-server-1`;
none of these migrations qualifies or selects v2.

Migration `20260918100000` copies v2 work into `physiology_work_items`, preserves legacy data
and active claims, and separates baseline freshness from shadow debt. The transient legacy
receipt records completion and a payload hash; it never claims a fenced revision.

Migration `20260918120000` requires the [frozen baseline transport patch](../legacy-baseline/README.md).
Its numerical kernel and `DayScorer` remain the exact baseline implementation. The patch changes
claim/publication transport, renews leases, sends revision/run/token identity, and removes mutable
legacy archive writes. The database rejects the old unfenced publication RPC and direct legacy
queue mutations. Pre-protocol baseline claims are revoked and their work is requeued; source
rows, previous scores, v2 live leases and archives are retained. This transport transition is
necessary because an unpatched worker cannot distinguish itself from a successor on the same
input revision.

Before any authorized deployment, build and test the patched baseline artifact, stop unpatched
baseline workers, apply the reviewed migrations, and start the patched baseline and v2 shadow
services. Applying the transport migration while expecting the unpatched binary to continue
scoring fails closed. This repository work does not authorize deployment.

Both publication RPCs fence in the same transaction as persistence. Baseline results retain the
original numerical values while their immutable snapshot contains only that publication's
complete episode set. Older start keys remain in legacy tables for preservation but cannot
accumulate in the current immutable result. Each algorithm's results have its own input revision,
run ID, manifest identity and immutable archive outbox entry. The v2 RPC rejects a v1 version label.

The archive worker reads exact committed snapshots for either version and retries independently
of scoring. During baseline-only operation, run the repaired service with `--archive-only` and B2
configuration; this mode does not construct a scorer or claim physiological work. A stopped archive
worker leaves explicit pending archive debt; it does not turn missing archival verification into
success.

Rollback retains canonical v1 selection and uses the separately built v1 image with the pinned
kernel and fenced transport. The original unpatched binary is not a compatible rollback artifact
after the transport migration. Do not relabel the upgraded v2 kernel as v1. Functional queue tests
and the frozen baseline build do not establish physiological accuracy, device acquisition,
overnight operation or a deployed-stack result.
