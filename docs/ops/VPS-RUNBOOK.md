# FRWHOOP self-hosted VPS runbook (Phase 1)

No secrets in this file. Generated deployment tooling lives under `infra/vps/scripts/`.

## Stack layout

| Component | Location on VPS | Public exposure |
|---|---|---|
| Supabase (Postgres, Kong, Auth, REST, Realtime, Studio) | `/opt/frwhoop/supabase-docker/docker` | Kong + Studio bound to `127.0.0.1` only |
| Caddy (TLS termination) | `/opt/frwhoop/caddy` | Host network: **80/443 only** |
| Backups | `/opt/frwhoop/backups` + B2 prefix `FRWHOOP/backups/` | None |
| Secrets | `/opt/frwhoop/secrets.env`, `/opt/frwhoop/b2.env` | None — `chmod 600` |

## Prerequisites (owner)

1. DigitalOcean API token in repo-root `.env` as `DIGITAL_OCEAN_TOKEN`
2. Backblaze B2 application key in `.env` (`KEY_ID`, `APPLICATION_KEY`, `BUCKET_NAME=FRWHOOP`)
3. DNS **A record** for your API hostname → droplet IP (required before Caddy can issue Let's Encrypt certs). Dev fallback: `<ip-with-dashes>.sslip.io` in `infra/vps/droplet.env`.
4. Optional Studio hostname → same IP (e.g. `studio.api.example.com`)

Self-hosted Supabase (Envoy) requires `apikey` (and `Authorization: Bearer` for REST) on gateway routes — see `acceptance-checks.sh`.

## One-time deploy (from Mac/Linux with repo checkout)

```bash
chmod +x infra/vps/scripts/*.sh infra/vps/scripts/remote/*.sh

# 1) SSH key (once)
ssh-keygen -t ed25519 -f infra/vps/keys/frwhoop_deploy -N "" -C frwhoop-vps-deploy

# 2) Secrets bundle (gitignored → infra/vps/secrets.env)
./infra/vps/scripts/generate-secrets.sh

# 3) Create droplet (4 vCPU / 8 GB / 160 GB, Ubuntu 24.04, sfo3)
./infra/vps/scripts/provision-droplet.sh

# 4) Bootstrap VPS (replace API_DOMAIN)
export API_DOMAIN=api.example.com
source infra/vps/droplet.env
scp -i infra/vps/keys/frwhoop_deploy infra/vps/scripts/remote/*.sh deploy@$DROPLET_IP:/tmp/
ssh -i infra/vps/keys/frwhoop_deploy root@$DROPLET_IP 'bash /tmp/01-harden.sh'
ssh -i infra/vps/keys/frwhoop_deploy root@$DROPLET_IP 'bash /tmp/02-docker.sh'

scp -i infra/vps/keys/frwhoop_deploy infra/vps/secrets.env deploy@$DROPLET_IP:/opt/frwhoop/secrets.env
ssh -i infra/vps/keys/frwhoop_deploy deploy@$DROPLET_IP \
  "sudo mkdir -p /opt/frwhoop/scripts && sudo cp /tmp/0*.sh /opt/frwhoop/scripts/ && API_DOMAIN=$API_DOMAIN bash /tmp/03-supabase-stack.sh"

# 5) B2 env on VPS (no secrets in git)
ssh deploy@$DROPLET_IP 'sudo tee /opt/frwhoop/b2.env' <<'EOF'
B2_KEY_ID=...
B2_APPLICATION_KEY=...
B2_BUCKET_NAME=FRWHOOP
B2_S3_ENDPOINT=s3.us-west-004.backblazeb2.com
EOF

# 6) Migrations (71 files, halt on first error)
./infra/vps/scripts/apply-migrations.sh

# 7) Cron + restore drill
ssh deploy@$DROPLET_IP 'echo "0 3 * * * root /opt/frwhoop/scripts/04-backup.sh >> /var/log/frwhoop-backup.log 2>&1" | sudo tee /etc/cron.d/frwhoop-backup'
ssh deploy@$DROPLET_IP 'sudo /opt/frwhoop/scripts/04-backup.sh && sudo /opt/frwhoop/scripts/05-restore-drill.sh'

# 8) Acceptance (reads API_DOMAIN from droplet.env if set)
./infra/vps/scripts/acceptance-checks.sh
```

## Scoring service database URL (JVM gotcha)

The JVM scoring service connects with JDBC. pgJDBC does **not** accept userinfo in the URL:
`jdbc:postgresql://user:pass@host/db` parses `user:pass@host` as the host (libpq/Node `pg`
convention only). The service therefore accepts the receiver-style URL
(`postgresql://user:pass@host:port/db`, optional `jdbc:` prefix) and internally strips the
userinfo, passing user/password via Hikari data-source properties
(`PostgresClient.normalizeJdbcUrl` / `parseUserInfo`). Keep `SCORING_DATABASE_URL` in the
libpq form — do not hand-encode it as a bare JDBC URL with userinfo
(`jdbc:postgresql://host:port/db?user=...&password=...` also works if you must).

## Derived artifact lane (scoring service → B2)

The JVM scoring container shares `/opt/frwhoop/b2.env` with Edge Functions. After each scored day
it PUTs `v3/derived/users/{userId}/days/{day}/frwhoop-server-1.json.zst` and upserts
`object_manifests` (`object_kind=derived_scores`, 90-day `expires_at`). Scores land in Postgres
even when B2 blinks; check `scoring_work_items.derived_artifact_error` for the last archive
failure. Optional smoke: `node infra/vps/scripts/b2-derived-smoke.mjs` (service-role PUT + HEAD).

## Restart stack

```bash
ssh deploy@<ip> 'cd /opt/frwhoop/supabase-docker/docker && docker compose restart'
ssh deploy@<ip> 'cd /opt/frwhoop/caddy && docker compose restart'
```

## Backups

- **Nightly**: `pg_dump` custom format → `s3://FRWHOOP/backups/pg/<timestamp>.dump`
- **WAL** (optional Phase 1+): configure `wal-g` with `WALG_S3_PREFIX=s3://FRWHOOP/wal` and the same B2 S3 endpoint/credentials
- Local retention on disk: 14 days under `/opt/frwhoop/backups`

## Restore drill (quarterly)

Run `/opt/frwhoop/scripts/05-restore-drill.sh` after any schema change or backup policy change. A backup that has never been restored is not a backup.

## Rotate B2 application key

1. Create new B2 application key scoped to bucket `FRWHOOP`
2. Update `/opt/frwhoop/b2.env` on the VPS
3. Revoke old key in Backblaze console
4. Run a manual backup and restore drill

## Rotate Supabase JWT / service keys

1. Stop clients pushing (maintenance window)
2. Regenerate `JWT_SECRET`, mint new `ANON_KEY` / `SERVICE_ROLE_KEY` (`generate-secrets.sh` locally)
3. Update `/opt/frwhoop/secrets.env` and Supabase `.env`, `docker compose up -d`
4. Re-run `apply-migrations.sh` only if schema drifted (normally skip)
5. Update app/device configs with new keys (Phase 2+)

## Phase 1 non-goals

- Edge Functions (Phase 2)
- Scoring JVM service (Phase 3)
- App cutover from cloud Supabase
- Exposing Postgres (5432) or Kong (8000) on `0.0.0.0`

## Troubleshooting

| Symptom | Check |
|---|---|
| Caddy no cert | DNS A record live? `dig +short $API_DOMAIN` matches droplet IP |
| Migration failed | Fix upstream SQL only via **new** migration file — never edit applied files |
| Studio 401 | Use dashboard basic auth from secrets bundle |
| Supavisor restart loop | `VAULT_ENC_KEY` must be 32 hex chars (`openssl rand -hex 16`). Run `sudo bash /opt/frwhoop/scripts/10-fix-supavisor.sh` |
| anon reads data | RLS regression — inspect policies on affected table |
