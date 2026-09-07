-- SpotiFLAC Cloud — Supabase schema (Phase 3)
--
-- Additive, idempotent. Apply with `supabase db push` or the SQL editor.
-- Row Level Security is enabled on every table; policies live in rls.sql.
-- The existing Dart `SupabaseSyncAdapter` continues to speak `sync_records`;
-- the domain tables below are the source of truth the adapter (and the
-- PostgREST views) project into that wire format.

create extension if not exists pgcrypto;

create table if not exists public.users (
  id uuid primary key default gen_random_uuid(),
  handle text unique,
  display_name text not null default '',
  email text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.playlists (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  title text not null,
  description text not null default '',
  cover_url text,
  is_collaborative boolean not null default false,
  visibility text not null default 'private'
    check (visibility in ('public', 'friends', 'private')),
  revision integer not null default 1,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

create index if not exists playlists_user_id_idx on public.playlists(user_id);

create table if not exists public.playlist_tracks (
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  track_id text not null,
  position integer not null default 0,
  added_by uuid references public.users(id) on delete set null,
  added_at timestamptz not null default now(),
  primary key (playlist_id, track_id)
);

create table if not exists public.favorites (
  user_id uuid not null references public.users(id) on delete cascade,
  kind text not null check (kind in ('track', 'album', 'artist', 'playlist')),
  item_id text not null,
  payload jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false,
  primary key (user_id, kind, item_id)
);

create table if not exists public.play_history (
  id bigserial primary key,
  user_id uuid not null references public.users(id) on delete cascade,
  track_id text not null,
  played_at timestamptz not null default now(),
  duration_ms integer not null default 0,
  completion_pct real not null default 0,
  source text not null default 'app'
);

create index if not exists play_history_user_played_idx
  on public.play_history(user_id, played_at desc);

create table if not exists public.downloads (
  user_id uuid not null references public.users(id) on delete cascade,
  track_id text not null,
  quality text not null default '',
  provider_id text not null default '',
  downloaded_at timestamptz not null default now(),
  primary key (user_id, track_id)
);

create table if not exists public.settings (
  user_id uuid not null references public.users(id) on delete cascade,
  key text not null,
  value jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (user_id, key)
);

create table if not exists public.recommendations (
  user_id uuid not null references public.users(id) on delete cascade,
  kind text not null,
  shelf_id text not null,
  track_ids text[] not null default '{}',
  generated_at timestamptz not null default now(),
  payload jsonb not null default '{}'::jsonb,
  primary key (user_id, kind, shelf_id)
);

-- Generic sync ledger consumed by `SupabaseSyncAdapter` (existing contract).
create table if not exists public.sync_records (
  user_id uuid not null references public.users(id) on delete cascade,
  scope text not null,
  record_id text not null,
  revision integer not null default 1,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false,
  payload jsonb not null default '{}'::jsonb,
  primary key (user_id, scope, record_id)
);

create index if not exists sync_records_scope_rev_idx
  on public.sync_records(user_id, scope, revision);
