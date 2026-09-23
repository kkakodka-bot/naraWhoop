# FRWHOOP hosted migration gate

`hosted-migration-release.mjs` is the only repository runner for the hosted FRWHOOP upgrade. It is
separate from `infra/vps/scripts/apply-migrations.sh`, which requires
`--self-hosted-reviewed` and operates only on the VPS-local Supabase database.

The hosted runner is fail closed. It accepts only project `sgoyxzcagqyxexmsidtk`, verifies every
manifest entry and migration byte hash against the exact candidate commit and tree, and reads both
hosted ledgers before any mutation. Git object replacement, lazy fetch, hooks, global configuration,
and nonlocal protocols are disabled during source verification. The native Supabase ledger remains a
110-row timestamp ledger. The runner does not rewrite or backfill it. The full identity ledger in
`supabase_migrations.scoring_source_identities` must contain the exact 117-row reviewed baseline. The
plan then names the ten forward migrations in their immutable order.

Do not use `supabase db push` for this release. Do not run the `apply` command without explicit
production-migration authorization and a reviewed plan fingerprint.

## 0. Review and pin psql

Every database command requires `--psql-path` with an absolute canonical path to a regular executable.
Symlink paths are rejected. Planning records the path, file size, SHA-256, and `psql --version` output
inside the signed plan. Apply and verify recalculate the identity and reject any difference before a
database query.

The client used for the current local release-tooling test is:

```text
path: /opt/homebrew/Cellar/postgresql@18/18.3/bin/psql
version: psql (PostgreSQL) 18.3 (Homebrew)
sha256: 39b056bee3aa2439d379afa5fdb52c30fa20f849631d67af33598412d069cfd4
```

Review the actual operator-host client independently. If it differs, review that absolute path,
version, and hash before creating the plan. Do not substitute a symlink such as
`/opt/homebrew/opt/postgresql@18/bin/psql`.

The child receives only `LANG`, `LC_ALL`, `PGPASSWORD`, `PGSSLMODE`, `PGSSLROOTCERT`, `PGCONNECT_TIMEOUT`, and
`PGAPPNAME`. It uses a 10-second connection timeout, a 10-minute process timeout, a 30-second ledger
statement timeout, and a five-minute migration statement timeout. `-X` disables startup files and
`-w` prevents an interactive password prompt.

## 1. Bind the hosted target

Create a non-secret target binding. Direct connections must use
`db.sgoyxzcagqyxexmsidtk.supabase.co:5432` with user `postgres`. A Supabase pooler hostname is also
accepted only when the user is `postgres.sgoyxzcagqyxexmsidtk`. Both paths require `sslmode=verify-full`. The binding uses either the system trust store or one
explicit public CA file with its reviewed SHA256; the same trust choice must be present in the URL.

```bash
node Tools/release/hosted-migration-release.mjs bind-target \
  --project-ref sgoyxzcagqyxexmsidtk \
  --host db.sgoyxzcagqyxexmsidtk.supabase.co \
  --port 5432 \
  --database postgres \
  --user postgres \
  --expected-current-user postgres \
  --output /absolute/evidence/hosted-target-binding.json
```

For the observed FRWHOOP target, system trust failed certificate validation. Supabase
[documents](https://supabase.com/docs/guides/platform/ssl-enforcement) its downloadable CA for
`verify-full`; the public certificate and provenance are in `Tools/release/certificates/`. To bind it,
add both `--ssl-root-cert /canonical/absolute/path/supabase-prod-ca-2021.crt` and
`--ssl-root-cert-sha256 700723581420dd1ac98fd7e9ac529f0ef210eadcaf87fc868a3ad7d114c2f3b7`
to `bind-target`. The runner rejects symlinks, invalid/non-CA/expired certificates and changed bytes
before each connection. It does not change system trust or download a certificate during apply.

Supply the credential through `FRWHOOP_HOSTED_DATABASE_URL`. The URL must match the binding exactly
and include exactly `sslmode=verify-full` and `sslrootcert=system` or the URL-encoded pinned CA path. The runner passes the decoded password to `psql` only through its
child environment. It never puts the URL or password in arguments, evidence, or normal output.

## 2. Create the read-only plan

```bash
node Tools/release/hosted-migration-release.mjs plan \
  --repo-root "$PWD" \
  --manifest /absolute/release-artifacts/migration-manifest.json \
  --project-ref sgoyxzcagqyxexmsidtk \
  --target-binding /absolute/evidence/hosted-target-binding.json \
  --evidence-dir /absolute/evidence/hosted-migration \
  --psql-path /absolute/canonical/path/to/psql
```

Planning runs a read-only transaction. It records `current_database`, `current_user`, server address,
port, version, and database OID. It exports the native ledger and the complete basename/hash ledger,
then reconciles the latter to the 117 applied entries in the immutable manifest. Any extra, missing,
reordered, or hash-mismatched full identity blocks the plan.

Review these files before authorization:

- `preflight-hosted-ledger.json`
- `hosted-migration-plan.json`
- `hosted-migration-state.json`

The plan fingerprint binds the target, candidate SHA and tree, migration manifest, verifier hash,
psql path/hash/version, bounded timeouts, native ledger fingerprint, exact twelve migration files,
apply order, and both expected schema fingerprints. The migration-catalog fingerprint is
`bd78bdc02131edb3f5de974158202dc948e899cffb85b05970a45b1db2ae4edd`. The integrated database
definition fingerprint is `d9fb8fcb73324dcc94c67190756c3ec292fec89a2d959ef05bdc3c9915c957f4`,
measured identically on fresh, populated, and representative 117-to-129 disposable database paths.
The verifier asserts 32 functions, 11 triggers, 24 policies and RLS on 136 tables. The predecessor
test executes the actual hosted apply wrapper for all twelve pending migrations and proves that
the captured 110-row native timestamp/name ledger remains unchanged, alongside the 117 full source
identities. Older runs generated a 111-row native surrogate from source timestamps; those receipts
are retained as surrogate tests and do not prove fidelity to the hosted native ledger. The corrected
fixture rejects the extra superseded timestamp and the colliding timestamp's wrong native name.
This is local DDL replay with captured ledger metadata, not a restored production data snapshot.
These local receipts do not establish deployment or phone acceptance.

Migration 129 changes legacy read eligibility globally: unqualified beat-derived values and old
unmarked stage-dependent sleep values are withheld, while independently eligible HR and in-bed
bounds remain readable. Newly published RR-excluded results preserve the unchanged scalar sleep
computation. The immutable historical payloads/hashes remain untouched. One-owner/device worker
admission does not restrict this schema/read-policy change to that pair; include this effect in the
explicit deployment approval.

## 3. Apply the reviewed plan

This command mutates the hosted database. It is intentionally not part of candidate build or phone
testing and must wait for explicit authorization.

```bash
node Tools/release/hosted-migration-release.mjs apply \
  --repo-root "$PWD" \
  --manifest /absolute/release-artifacts/migration-manifest.json \
  --project-ref sgoyxzcagqyxexmsidtk \
  --target-binding /absolute/evidence/hosted-target-binding.json \
  --plan /absolute/evidence/hosted-migration/hosted-migration-plan.json \
  --evidence-dir /absolute/evidence/hosted-migration \
  --apply-plan-fingerprint REVIEWED_64_HEX_PLAN_FINGERPRINT \
  --psql-path /absolute/canonical/path/to/psql
```

Before each migration the runner re-exports both ledgers. The database transaction locks both ledger
tables, checks their exact expected contents, executes one reviewed migration body, and inserts that
migration's basename and source hash into `scoring_source_identities` before the same commit. It does
not insert into, rename, delete from, or rewrite `schema_migrations`.

After each response, a new read-only export must show the exact next full-identity prefix while the
native ledger fingerprint remains unchanged. A local fsync-backed receipt and state file are then
written. If the response is lost, the read-only reconciliation distinguishes an atomic commit from a
rollback and stops without replaying the migration. Drift or an unreconciled partial result stops the
run.

After all ten migrations, the runner executes the already captured, candidate-commit-verified bytes
of `verify-integrated-schema.sql` inside a read-only transaction. It does not reread the worktree after
mutation begins. Its assertions cover the final account and enrollment routes, immutable result
identity, metric ownership, queue claims, grants, triggers, RLS tables and policies, and
shadow/canonical separation. The verifier result must also equal the exact integrated database
fingerprint above. The state reaches `PASS` only after that verification succeeds. A post-verification
failure is recorded as `POSTVERIFY_FAILED`; it does not roll back or replay already committed
migrations.

## 4. Re-run read-only verification

```bash
node Tools/release/hosted-migration-release.mjs verify \
  --repo-root "$PWD" \
  --manifest /absolute/release-artifacts/migration-manifest.json \
  --project-ref sgoyxzcagqyxexmsidtk \
  --target-binding /absolute/evidence/hosted-target-binding.json \
  --plan /absolute/evidence/hosted-migration/hosted-migration-plan.json \
  --evidence-dir /absolute/evidence/hosted-migration-verification \
  --psql-path /absolute/canonical/path/to/psql
```

`verify` performs no mutation. It requires all 129 full identities with their manifest hashes, the
unchanged reviewed native ledger, and a passing integrated schema verification.

## Repository test

```bash
node --test Tools/release/hosted-migration-release.test.mjs
```

The deterministic suite uses a mocked hosted database for state transitions and real child-process
spawns against a nonnetwork fake psql for the CLI contract. It covers wrong project and target
identity, manifest and migration mutation, Git blob replacement refs, ledger drift, response loss
after a partial apply, post-verification failure, exact database fingerprint enforcement, captured
verifier bytes, exact-order success, atomic full-identity receipt SQL, exact psql flags/environment,
timeouts, target arguments, and credential redaction.
