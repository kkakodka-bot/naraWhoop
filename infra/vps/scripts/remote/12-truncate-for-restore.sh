#!/usr/bin/env bash
# Truncate all VPS public + auth data before a full cloud restore. Destructive — maintenance window only.
set -euo pipefail

TABLES=$(docker exec supabase-db psql -U postgres -d postgres -Atc \
  "SELECT string_agg(quote_ident(schemaname) || '.' || quote_ident(tablename), ', ' ORDER BY tablename)
   FROM pg_tables WHERE schemaname = 'public';")

docker exec supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -c "TRUNCATE TABLE ${TABLES} RESTART IDENTITY CASCADE;"

# Auth tables: avoid RESTART IDENTITY (sequence ownership differs on self-hosted).
docker exec supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -c "TRUNCATE TABLE auth.identities, auth.users CASCADE;"

DEVICES=$(docker exec supabase-db psql -U postgres -d postgres -Atc "SELECT count(*) FROM devices;")
USERS=$(docker exec supabase-db psql -U postgres -d postgres -Atc "SELECT count(*) FROM auth.users;")
echo "VPS truncated: devices=${DEVICES} auth.users=${USERS}"
