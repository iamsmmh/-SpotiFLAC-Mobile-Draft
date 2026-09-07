# SpotiFLAC Cloud — Supabase

Preferred cloud backend for cross-device sync (Phase 3).

## Apply

```bash
supabase db push
# or paste 0001_init.sql then rls.sql in the SQL editor
```

## Tables

| Table | Purpose |
| --- | --- |
| `users` | Account profile |
| `playlists` / `playlist_tracks` | User + collaborative playlists |
| `favorites` | Loved tracks / albums / artists / playlists |
| `play_history` | Listening events |
| `downloads` | Offline-download ledger (metadata only) |
| `settings` | Synced preferences + Daily Mix stamps |
| `recommendations` | Discover Weekly / Daily Mix / Release Radar snapshots |
| `sync_records` | Wire ledger consumed by the existing `SupabaseSyncAdapter` |

Conflict rule: last-write-wins on `updated_at` (with `revision` as the
tie-breaker) plus a playlist union-merge in `SyncMergeEngine`. No existing
Dart `CloudSyncProvider` API is replaced — adapters register the same way.
