# Physiology input revisions

Migration `20260918010000_physiology_revisions.sql` installs transactional invalidation for HR,
intervals, respiration, gravity, events, native motion counters, band state, annotations, sleep
sessions/details and verified raw-object availability. Physiological profile/preferences and device
family/firmware/calibration corrections invalidate existing periods; last-seen updates do not.
Insert, semantic update and delete dirty the
affected device/day and following wake day. Bulk projection statements coalesce to one revision per
affected device/day; changing only arrival metadata does not trigger a new revision. A one-time
migration scan catches existing projection rows missed by the former polling watermark.

Migration `20260918100000` moves v2 debt to `physiology_work_items`, retaining its
`(user_id, device_id, day)` primary key. Baseline debt remains independently in
`scoring_work_items`; migration `20260918120000` requires its token-aware baseline worker.
[Algorithm isolation](algorithm-work-isolation.md) describes migration and rollback prerequisites. Each revision has an independent
failure budget. Successful runs reset failures; the eighth consecutive failure exhausts that
revision. Retry delay doubles from five seconds to one hour. New input resets the budget and is
debounced for two seconds. Waiting for absent inputs retries after five minutes without consuming
the failure budget. `attempts` remains for compatibility and mirrors failures, not successful runs.

`scoring_claim_one` claims one runnable row using `FOR UPDATE SKIP LOCKED`. The returned
`input_revision`, UUID `lease_token` and UUID `run_id` form the capability for that computation.
The poller renews the lease every third of its duration. Replay uses the same queue path.

Publication RPCs must call `scoring_begin_publication(user,device,day,revision,token,run)` before
writing any output, in the same transaction. This locks the queue row and checks ownership,
revision and expiry **after** acquiring the lock. New input takes that same lock. Thus either the
publication precedes the new input commit and the new revision remains pending, or the new input
commits first and the old publication fails with SQLSTATE `40001`. Renewal and completion use the
same check. Obsolete workers cannot release a successor's lease. The fence is unavailable to
authenticated/anonymous callers; service-role publication remains the only writer.

Raw availability requires both `sha256_source = server_verified` and decoder verification
(`decode_verified_at`, `decoder_version`) on a ready/verified manifest. A HEAD check or client digest
does not qualify. Verification and revocation dirty the dependent periods. The raw reader must
fetch/hash/decode the bytes before writing these fields. Invalid sensor timestamps remain retained
in projections even if they cannot be represented as a PostgreSQL calendar job.

Timezone history records profile changes prospectively. A late historical record uses its
event-time timezone; the queue's original zone is compatibility metadata. Earlier travel history cannot
be recovered from a current profile: the migration explicitly labels that baseline
`migration_profile_snapshot`. Migration `20260918050000` intersects each date with historical zone
segments, including disjoint travel intervals. Readers filter samples by this union before RR
transport selection. Profile changes and ingestion serialize through the owner/device mutex so
waiting arrivals see committed history. Tests cover DST, same-day travel, skipped dates and a
74-hour repeated-date context; the explicit context bound is 76 hours.

Migration `20260918030000` separates direct measurement revisions from baseline-only refreshes.
Forward HRV dependents include the earliest prior-night window's full 28-day history, not only the
current day's midnight. Migration `20260918100000` checks actual owned calendar intervals when refreshing HRV
dependents, including precreated days whose original queue timezone predates date-line travel.
Migration `20260918060000` invalidates persistent wrist-state influence
through the next wrist transition, including transitions preceding the raw reader lower bound.
Neither path creates an unbounded future job series.

`scoring_dependency_policy` describes preceding/following calendar-day context. Its initial values
match a full scoring day plus the preceding local day. A model with a larger receptive field must
expand this policy before activation, and existing outputs must be explicitly invalidated for
that model change. Inference cannot silently enlarge context while retaining narrower invalidation.

Run the real database gate from `scoring-service`:

```sh
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
  bash scripts/test-physiology-queue.sh
```

The script starts a new local PostgreSQL cluster, loads the baseline queue/projection migrations,
seeds old successful work and auxiliary input, applies the additive migration, and executes the
JDBC integration tests. It stops its own cluster on exit and retains its log directory. Ordinary
Gradle tests skip this class unless the disposable database environment variable is present.
The gate covers more than 350 revisions, failure exhaustion/new input, waiting, row-lock races,
expiry during lock wait, corrections/deletions/replay, owner/device fences, raw verification and
timezone handling. This is functional database evidence, not clinical or deployment validation.
