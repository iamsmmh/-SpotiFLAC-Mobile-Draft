-- Row Level Security for the SpotiFLAC Cloud tables.
-- Authenticated users may only read/write their own rows. Collaborative
-- playlist tracks are readable by members via the playlists.visibility flag.

alter table public.users enable row level security;
alter table public.playlists enable row level security;
alter table public.playlist_tracks enable row level security;
alter table public.favorites enable row level security;
alter table public.play_history enable row level security;
alter table public.downloads enable row level security;
alter table public.settings enable row level security;
alter table public.recommendations enable row level security;
alter table public.sync_records enable row level security;

drop policy if exists users_self on public.users;
create policy users_self on public.users
  for all using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists playlists_owner on public.playlists;
create policy playlists_owner on public.playlists
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists playlists_public_read on public.playlists;
create policy playlists_public_read on public.playlists
  for select using (visibility = 'public' and deleted = false);

drop policy if exists playlist_tracks_owner on public.playlist_tracks;
create policy playlist_tracks_owner on public.playlist_tracks
  for all using (
    exists (
      select 1 from public.playlists p
      where p.id = playlist_id and p.user_id = auth.uid()
    )
  );

drop policy if exists favorites_self on public.favorites;
create policy favorites_self on public.favorites
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists play_history_self on public.play_history;
create policy play_history_self on public.play_history
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists downloads_self on public.downloads;
create policy downloads_self on public.downloads
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists settings_self on public.settings;
create policy settings_self on public.settings
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists recommendations_self on public.recommendations;
create policy recommendations_self on public.recommendations
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists sync_records_self on public.sync_records;
create policy sync_records_self on public.sync_records
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
