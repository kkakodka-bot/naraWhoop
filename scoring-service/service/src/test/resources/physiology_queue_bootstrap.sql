-- Minimal pre-existing platform objects. Projection and queue tables are loaded from their actual
-- baseline migrations by the harness; these compatibility tables mirror production-persistence.
create role anon;
create role authenticated;
create role service_role bypassrls;
create schema auth;
create schema extensions;
create extension pgcrypto with schema extensions;
create function public.set_updated_at() returns trigger language plpgsql as
  $$begin new.updated_at=now(); return new; end$$;
create function auth.uid() returns uuid language sql stable as
  $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create function auth.role() returns text language sql stable as
  $$select coalesce(nullif(current_setting('request.jwt.claim.role',true),''),current_user)$$;
create table auth.users(id uuid primary key);
create table public.profiles(id uuid primary key references auth.users,timezone text not null default 'UTC',
  reported_age_years integer,sex_model text,weight_kg numeric,height_cm numeric);
create table public.devices(id uuid primary key,user_id uuid not null references auth.users,last_seen_at timestamptz,
  device_family text,firmware text);
create table public.sessions(id uuid primary key default gen_random_uuid(),user_id uuid not null references auth.users,
  device_id uuid references public.devices,start_at timestamptz not null,end_at timestamptz not null,
  user_modified boolean not null default false,kind text not null default 'sleep',updated_at timestamptz default now());
create table public.sleep_details(session_id uuid primary key references public.sessions on delete cascade,
  user_id uuid not null references auth.users,original_start_at timestamptz,original_end_at timestamptz,
  user_start_at timestamptz,user_end_at timestamptz,updated_at timestamptz default now());
create table public.sleep_nights(id uuid primary key default gen_random_uuid(),user_id uuid not null references auth.users,
  device_id uuid references public.devices,period_day date not null,start_at timestamptz not null,
  end_at timestamptz not null,updated_at timestamptz default now());
create table public.object_manifests(id uuid primary key default gen_random_uuid(),user_id uuid not null references auth.users,
  device_id uuid references public.devices,object_key text not null unique,status text not null default 'pending',
  sha256 text,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
  object_class text not null default 'raw',object_kind text,compression text,format text,sample_count bigint,
  compressed_bytes bigint,verified_at timestamptz);
create schema internal;
create function internal.assert_ingest_secret(text) returns void language plpgsql as $$begin end$$;
create table public.queue_test_publications(user_id uuid,device_id uuid,day date,revision bigint,
  primary key(user_id,device_id,day));
