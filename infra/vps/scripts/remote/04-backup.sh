#!/usr/bin/env bash
# Nightly pg_dump + optional wal-g archive to B2 (single bucket FRWHOOP).
# Install on VPS via cron. Reads /opt/frwhoop/secrets.env + /opt/frwhoop/b2.env
set -euo pipefail

BASE="/opt/frwhoop"
SECRETS="${BASE}/secrets.env"
B2_ENV="${BASE}/b2.env"
BACKUP_DIR="${BASE}/backups"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)

[[ -f "$SECRETS" ]] && source "$SECRETS"
[[ -f "$B2_ENV" ]] && source "$B2_ENV"

: "${POSTGRES_PASSWORD:?}"
: "${B2_KEY_ID:?}"
: "${B2_APPLICATION_KEY:?}"
: "${B2_BUCKET_NAME:=FRWHOOP}"
: "${B2_S3_ENDPOINT:=s3.us-west-004.backblazeb2.com}"

mkdir -p "$BACKUP_DIR"
DUMP="${BACKUP_DIR}/postgres-${STAMP}.dump"

docker exec supabase-db pg_dump -U postgres -Fc postgres >"$DUMP"

export AWS_ACCESS_KEY_ID="$B2_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$B2_APPLICATION_KEY"
export AWS_DEFAULT_REGION=us-west-004

if command -v aws >/dev/null 2>&1; then
  aws s3 cp "$DUMP" "s3://${B2_BUCKET_NAME}/backups/pg/${STAMP}.dump" \
    --endpoint-url "https://${B2_S3_ENDPOINT}"
  echo "Uploaded s3://${B2_BUCKET_NAME}/backups/pg/${STAMP}.dump"
else
  echo "aws CLI missing — dump kept at ${DUMP}" >&2
fi

find "$BACKUP_DIR" -name '*.dump' -mtime +14 -delete
