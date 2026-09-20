# VPS continuation after SSH restoration

Scope: continue PR #23's iOS/server production-candidate work, initially at `fa7fe6b1f0161011a9481cb52630ec5586b52cb0`. The original PR21 starting revision and feature-branch target are unchanged. This report distinguishes live operational diagnosis, isolated candidate validation and production deployment.

## SSH is restored

On September 20, 2026 at 00:17 UTC (September 19 Pacific time), key-only SSH to the supplied VPS succeeded as `deploy` on port 22 with the gitignored repository deployment key. The observed SSH service was active. The earlier refusal/Recovery Console blocker is superseded. No root SSH, alternative key, password SSH, key recreation, service restart or firewall change was attempted in this continuation. The console password is not an SSH credential.

## Confirmed destination mismatch

The VPS's running `supabase-scoring-1` container has these independently observed properties:

| Property | Observation |
| --- | --- |
| Image reference | `frwhoop/scoring-service:latest` |
| Image identity | `sha256:27041c79f8cb8e7fdab47eda6d32f6ff49a8232600062105c0da4d6102568590` |
| Source revision label | Absent |
| Algorithm | `frwhoop-server-1` |
| Database destination | VPS-local Docker service `db` |
| REST destination | VPS-local Docker service `rest` |
| Runtime state | Running, reported healthy, zero restart count and no current OOM flag |
| Replay variables | None present |
| Dedicated hosted scoring configuration | Required `SCORING_DATABASE_URL`, `SCORING_SUPABASE_URL`, `SCORING_INGEST_SECRET` and `SCORING_SUPABASE_SERVICE_ROLE_KEY` were absent from the deployment secrets file |

A read-only transaction against that local database at 00:21:18 UTC observed its legacy poll heartbeat advancing at 00:21:16 UTC. Its latest score heartbeat was September 17 07:41:12 UTC, two queue rows remained pending, and the v2 queue table was absent. This is not the hosted database that receives current app uploads.

The preceding read-only hosted observations found 71 never-attempted jobs in each legacy/v2 queue, null poll timestamps, ten old v2 snapshots and ten unattempted archive jobs. There were no current-revision v2 snapshots for those queued keys. The receiver nevertheless continued to acknowledge uploads. Together, the endpoint identity and contrasting heartbeats establish that the observed running scorer is servicing the local stack, not the hosted queue. A healthy local container cannot prove hosted processing.

The supplied local database URL fields contain password placeholders. The separate `DB_PASSWORD` successfully authenticated a read-only hosted connection when passed separately in process memory. The observed container's local database password is not a placeholder. Do not conflate the local template issue with the confirmed runtime destination mismatch.

## Publication safety remains a separate rollout gate

The live hosted schema still stops at migration `20260918220000`; it lacks PR #23's signed-promotion and independent-model tables. Live feature defaults remain v2 with the old `published` qualification and no reference policy/evaluation. These observations describe the pre-candidate deployment, not permission to publish unvalidated results.

Merely starting a hosted v2 worker would leave that unsafe publication selection in place. A reviewed rollout must first restore the legacy/default boundary through the candidate's additive promotion migration, preserve a real separately versioned legacy worker, and then establish hosted deterministic progress with v2 in shadow. This continuation does not deploy migrations, alter source selections, activate models or replace the running scorer.

## Resource and benchmark boundary

The actual target is native Linux x86_64 with four virtual CPUs, approximately 8 GiB RAM, cgroup v2 and Docker/Buildx available. Before candidate work, it had approximately 6.3 GB available memory and 144 GB free disk. Existing services were retained.

Candidate packaging uses a separate task-specific BuildKit container capped at one CPU, 3 GiB memory and no additional swap, with a 30-minute build deadline. Only committed public source/build inputs and the previously hash-verified offline model bundle are transferred to a task-specific scratch directory. No production credentials are supplied to this builder.

The synthetic-only model probe is separate from production activation. Its frozen plan binds image/source/probe/runtime/checkpoint identities, input construction and resource budgets before inference. It measures serial and two-process execution on synthetic ten-minute and eight-hour inputs. Probe containers are network-disabled, have no production credentials or exposed ports, and are capped at two CPUs, 3 GiB, 128 processes and no swap. Whole-cgroup charged peak memory is not relabeled as RSS. Resource measurements do not supply acquisition qualification, reference accuracy, production activation or canonical approval. The final [VPS report](vps-resource-report.md) records executed results and remaining limits.

## Follow-up source hardening

The continuation also addresses two independently reviewed availability gaps: a deterministic input query could outlive the input-gate connection deadline, and deployment accepted container existence without proving hosted poll/publication progress or recovering the prior worker on startup failure. Their regression and final-head evidence must be evaluated separately from the destination mismatch above; neither is claimed as the observed cause of this particular hosted outage.
