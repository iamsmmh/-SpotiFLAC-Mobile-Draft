#!/usr/bin/env python3
"""Regenerates the "Discovery tables (v6)" section of docs/SCHEMA.md.

The SQL in the doc is extracted from `lib/ecosystem/discovery/discovery_schema.dart`
rather than retyped, so the two cannot drift. Re-run after any schema change:

    python3 scripts/discovery_schema_doc.py

The scanner understands Dart's string grammar — `'''` blocks, `''` empty
literals and `$name` / `${name}` interpolation — because a naive
"split on quotes" pass silently drops the `''` in `DEFAULT ''` and emits broken
SQL into the doc.
"""

from __future__ import annotations

import io
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCHEMA = REPO / "lib" / "ecosystem" / "discovery" / "discovery_schema.dart"
DOC = REPO / "docs" / "SCHEMA.md"

SECTION_START = "## Discovery tables (v6)"
SECTION_END = "## Key conventions"

PURPOSE = {
    "ds_listening_statistics": (
        "Day-bucketed roll-up of `ec_listening_events`: one row per "
        "`(track_key, UTC day)` with plays, skips, listened milliseconds, "
        "completions, repeats and a 24-bucket hour histogram. The roll-up is "
        "incremental — a `last_event_id` watermark in `ec_meta` means a normal "
        "launch reads only new events, which is what keeps Phase 1 off the "
        "battery budget."
    ),
    "ds_user_profiles": (
        "Serialised `ListeningProfile` (top tracks / artists / albums / genres "
        "/ tags plus listening habits). Regenerated at most every 6 h; "
        "`schema_version` invalidates a profile written by an older algorithm "
        "instead of mixing two definitions of affinity."
    ),
    "ds_recommendation_cache": (
        "Generated shelves keyed by `(kind, key)`. Stores the engine version "
        "and an expiry timestamp, so a code change or a stale entry is a cache "
        "miss rather than a stale shelf."
    ),
    "ds_daily_mixes": (
        "Daily Mix 1-5: one row per `(day_key, position)`. `cluster_json` "
        "holds the genre centroid that seeded the mix, `seed_labels_json` the "
        "genre names shown as chips."
    ),
    "ds_discover_weekly": (
        "Discover Weekly: one row per ISO week (`week_key`), 30-50 tracks in "
        "`items_json`, plus the counts surfaced on the card (hidden gems and "
        "new releases)."
    ),
    "ds_radio_sessions": (
        "Persisted radio stations — seed, queue, played keys and affinity "
        "vectors — so a station survives an app restart. Closed sessions are "
        "pruned after 30 days."
    ),
    "ds_artist_similarity": (
        "Cached artist→artist similarity with its five component overlaps "
        "(genre, tag, co-listen, playlist, album), so the percentage shown in "
        "the UI can be explained."
    ),
    "ds_track_similarity": (
        "Cached track→track similarity used by Track Radio and "
        "\"more like this\"."
    ),
    "ds_mood_profiles": (
        "Mood playlists (Chill, Focus, Workout, ...). `bpm_evidence_count` "
        "records how much of the playlist was scored from real BPM metadata; "
        "the UI shows that instead of claiming tempo data it does not have."
    ),
    "ds_trending_statistics": (
        "Per-period trending snapshots (week, month, fastest growing, emerging "
        "artists) computed from the windowed play counts on "
        "`ds_listening_statistics`."
    ),
    "ds_continue_listening": (
        "Resume points: the primary \"pick up where you left off\" slot plus "
        "per-context rows (album, playlist, radio). The stored offset is "
        "cleared at >= 95 % completion so a finished track never resumes."
    ),
}


def scan_literals(src: str, start: int, stop: int):
    """Yield `(pos, text)` for each literal, and `(pos, None)` for top-level commas."""
    i = start
    while i < stop:
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = stop if j < 0 else j
            continue
        if src.startswith("'''", i):
            j = src.find("'''", i + 3)
            if j < 0:
                raise ValueError("unterminated triple-quoted literal")
            yield i, src[i + 3:j]
            i = j + 3
            continue
        if src[i] == "'":
            j = i + 1
            buf = []
            while j < stop:
                ch = src[j]
                if ch == "\\":
                    buf.append(src[j:j + 2])
                    j += 2
                    continue
                if ch == "'":
                    break
                buf.append(ch)
                j += 1
            yield i, "".join(buf)
            i = j + 1
            continue
        if src[i] == ",":
            yield i, None
        i += 1


def statements(identifier: str) -> list[str]:
    src = io.open(SCHEMA, encoding="utf-8").read()
    start = src.index("[", src.index(identifier))
    depth = 0
    stop = -1
    for j in range(start, len(src)):
        if src[j] == "[":
            depth += 1
        elif src[j] == "]":
            depth -= 1
            if depth == 0:
                stop = j
                break
    if stop < 0:
        raise ValueError(f"no closing bracket for {identifier}")

    consts = dict(re.findall(r"const String (ds\w+) = '([^']+)'", src))

    def resolve(text: str) -> str:
        text = re.sub(r"\$\{(ds\w+)\}", lambda m: consts[m.group(1)], text)
        text = re.sub(r"\$(ds\w+)\b", lambda m: consts[m.group(1)], text)
        return text.strip()

    chunks: list[list[str]] = [[]]
    for _pos, text in scan_literals(src, start + 1, stop):
        if text is None:
            chunks.append([])
        else:
            chunks[-1].append(text)
    return [resolved for resolved in (resolve("".join(c)) for c in chunks) if resolved]


def build_section() -> str:
    all_statements = statements("discoverySchemaV6")
    tables = [s for s in all_statements if s.upper().startswith("CREATE TABLE")]
    indexes = [s for s in all_statements if s.upper().startswith("CREATE INDEX")]

    out = [SECTION_START, ""]
    out.append(
        "Added by the 5 → 6 migration for the on-device recommendation engine. "
        "Purely additive: no `ec_*` table is altered and no column is dropped. "
        "Every table is prefixed `ds_`, listed in `discoveryTables`, and "
        "cleared by `EcosystemDatabase.clearAll`."
    )
    out.append("")
    for sql in tables:
        name = re.search(r"CREATE TABLE IF NOT EXISTS (\w+)", sql).group(1)
        out.append(f"### `{name}`")
        out.append("")
        purpose = PURPOSE.get(name)
        if purpose:
            out.append(purpose)
            out.append("")
        out += ["```sql", sql, "```", ""]

    out += [
        "### Discovery indexes",
        "",
        "```sql",
        *[sql + ";" for sql in indexes],
        "```",
        "",
        "## Columns added after v1",
        "",
        "Migrations 1 → 5 only add columns (`ALTER TABLE … ADD COLUMN … NOT NULL "
        "DEFAULT …`), so an older build reading a newer database still works.",
        "",
        "| Step | Table | Columns added |",
        "|---|---|---|",
        "| 2 → 3 | `ec_offline_collections` | per-collection network policy |",
        "| 2 → 3 | `ec_stream_cache` | completion + source URL |",
        "| 3 → 4 | `ec_podcast_subscriptions` | `auto_download`, `keep_episodes`, `notify_new` |",
        "| 3 → 4 | `ec_smart_playlist_state` | `last_track_count` |",
        "| 4 → 5 | `ec_stream_cache` | `sha256`, `encrypted`, `iv_hex` |",
        "| 5 → 6 | — | discovery tables only (no columns added) |",
        "",
    ]
    return "\n".join(out)


def main() -> int:
    doc = io.open(DOC, encoding="utf-8").read()
    if "version **4**." in doc:
        doc = doc.replace("version **4**.", "version **6**.", 1)
    section = build_section()
    if SECTION_START in doc:
        start = doc.index(SECTION_START)
        end = doc.index(SECTION_END, start)
        doc = doc[:start] + section + "\n" + doc[end:]
    else:
        doc = doc.replace(SECTION_END, section + "\n" + SECTION_END, 1)
    io.open(DOC, "w", encoding="utf-8").write(doc)

    tables = [s for s in statements("discoverySchemaV6") if s.upper().startswith("CREATE TABLE")]
    indexes = [s for s in statements("discoverySchemaV6") if s.upper().startswith("CREATE INDEX")]
    print(f"wrote {len(tables)} tables and {len(indexes)} indexes into {DOC.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
