// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'download_queue_provider.dart';

class _AlbumRgTrackEntry {
  String filePath;
  final String trackId;
  final double integratedLufs;
  final double truePeakLinear;
  final double durationSecs;

  _AlbumRgTrackEntry({
    required this.filePath,
    required this.trackId,
    required this.integratedLufs,
    required this.truePeakLinear,
    required this.durationSecs,
  });
}

class _AlbumRgAccumulator {
  final List<_AlbumRgTrackEntry> entries = [];
}

extension _DownloadQueueReplayGain on DownloadQueueNotifier {
  String _albumRgKey(Track track) {
    if (track.albumId != null && track.albumId!.isNotEmpty) {
      return 'id:${track.albumId}';
    }
    return 'name:${track.albumName}|${track.albumArtist ?? ''}';
  }

  /// Purge a track's stale ReplayGain accumulator entry, dropping the whole
  /// album accumulator once it becomes empty.
  void _purgeAlbumRgEntry(Track track) {
    final key = _albumRgKey(track);
    final accumulator = _albumRgData[key];
    if (accumulator == null) return;
    accumulator.entries.removeWhere((e) => e.trackId == track.id);
    if (accumulator.entries.isEmpty) {
      _albumRgData.remove(key);
    }
  }

  /// Store a track's ReplayGain scan result for later album gain computation.
  void _storeTrackReplayGainForAlbum(
    Track track,
    String filePath,
    ReplayGainResult rg,
  ) {
    final key = _albumRgKey(track);
    _albumRgData.putIfAbsent(key, () => _AlbumRgAccumulator());
    // Remove any stale entry for this track (e.g. from a previous failed
    // attempt that was retried).  Without this, the same track can accumulate
    // multiple entries and bias the album loudness calculation.
    _albumRgData[key]!.entries.removeWhere((e) => e.trackId == track.id);
    _albumRgData[key]!.entries.add(
      _AlbumRgTrackEntry(
        filePath: filePath,
        trackId: track.id,
        integratedLufs: rg.integratedLufs,
        truePeakLinear: rg.truePeakLinear,
        durationSecs: track.duration.toDouble(),
      ),
    );
  }

  /// Replace the temp path stored in the accumulator with the final output
  /// path.  For SAF downloads the embed happens on a temp file which is later
  /// deleted — this ensures the album-gain writer targets the real file.
  void _updateAlbumRgFilePath(Track track, String finalPath) {
    final key = _albumRgKey(track);
    final accumulator = _albumRgData[key];
    if (accumulator == null) return;
    for (final entry in accumulator.entries) {
      if (entry.trackId == track.id) {
        entry.filePath = finalPath;
        break;
      }
    }
  }

  /// After a track completes, check whether all tracks from the same album
  /// in the current queue are done.  If so, compute album gain and write it
  /// to every track's file.
  Future<void> _checkAndWriteAlbumReplayGain(Track track) async {
    final settings = ref.read(settingsProvider);
    if (!settings.embedReplayGain) return;

    final key = _albumRgKey(track);
    final accumulator = _albumRgData[key];
    if (accumulator == null || accumulator.entries.isEmpty) return;

    // Find queue items for this album that are STILL in the queue.
    // Completed tracks may have already been removed by removeItem(), so
    // their absence means they finished successfully (not that they're
    // still pending).
    final albumItemsInQueue = state.items
        .where((item) => _albumRgKey(item.track) == key)
        .toList();

    final pending = albumItemsInQueue.where(
      (item) =>
          item.status == DownloadStatus.queued ||
          item.status == DownloadStatus.downloading ||
          item.status == DownloadStatus.finalizing,
    );
    if (pending.isNotEmpty) return;

    // If any item is failed/skipped, the user might retry it later.
    // Don't finalize album RG with partial data — wait until all album
    // tracks are either completed (and possibly removed) or retried.
    final retryable = albumItemsInQueue.where(
      (item) =>
          item.status == DownloadStatus.failed ||
          item.status == DownloadStatus.skipped,
    );
    if (retryable.isNotEmpty) return;

    // The accumulator entries represent successfully scanned tracks.  Entries
    // are only added after a successful ReplayGain scan, removed on retry or
    // when a non-completed item is removed from the queue, so every entry
    // here corresponds to a track that completed (or is about to complete)
    // its download.
    final validEntries = accumulator.entries.toList();

    // Single-track albums: album gain == track gain, no extra write needed.
    if (validEntries.length <= 1) {
      _albumRgData.remove(key);
      return;
    }

    // Compute album gain using duration-weighted power-mean of LUFS values.
    // album_loudness = 10 * log10( Σ(10^(Li/10) * di) / Σ(di) )
    // This weights longer tracks more, matching "whole program" loudness.
    double sumWeightedPower = 0;
    double sumDuration = 0;
    double maxPeak = 0;
    for (final entry in validEntries) {
      final weight = entry.durationSecs > 0 ? entry.durationSecs : 1.0;
      sumWeightedPower += pow(10, entry.integratedLufs / 10.0) * weight;
      sumDuration += weight;
      if (entry.truePeakLinear > maxPeak) {
        maxPeak = entry.truePeakLinear;
      }
    }
    final albumLufs = 10.0 * _log10(sumWeightedPower / sumDuration);
    const replayGainReferenceLufs = -18.0;
    final albumGainDb = replayGainReferenceLufs - albumLufs;

    final albumGain =
        '${albumGainDb >= 0 ? "+" : ""}${albumGainDb.toStringAsFixed(2)} dB';
    final albumPeak = maxPeak.toStringAsFixed(6);

    _log.i(
      'Album ReplayGain for "$key": gain=$albumGain, peak=$albumPeak (${validEntries.length} tracks, album LUFS=${albumLufs.toStringAsFixed(1)})',
    );

    for (final entry in validEntries) {
      try {
        await _writeAlbumReplayGain(entry.filePath, albumGain, albumPeak);
      } catch (e) {
        _log.w('Failed to write album ReplayGain to ${entry.filePath}: $e');
      }
    }

    _albumRgData.remove(key);
  }

  /// Write album ReplayGain tags to a single file.
  Future<void> _writeAlbumReplayGain(
    String filePath,
    String albumGain,
    String albumPeak,
  ) async {
    final lower = filePath.toLowerCase();
    if (lower.endsWith('.flac') ||
        lower.endsWith('.ape') ||
        lower.endsWith('.wv') ||
        lower.endsWith('.mpc')) {
      // Native writer — only touches the provided fields, preserves the rest.
      await PlatformBridge.editFileMetadata(filePath, {
        'replaygain_album_gain': albumGain,
        'replaygain_album_peak': albumPeak,
      });
    } else if (isContentUri(filePath)) {
      // SAF content:// URI — FFmpeg can read it but can't write back directly.
      // Get the temp output from FFmpeg, then copy it to the SAF URI.
      String? tempPath;
      final ok = await FFmpegService.writeAlbumReplayGainTags(
        filePath,
        albumGain,
        albumPeak,
        returnTempPath: true,
        onTempReady: (path) => tempPath = path,
      );
      if (ok && tempPath != null) {
        try {
          final safOk = await PlatformBridge.writeTempToSaf(
            tempPath!,
            filePath,
          );
          if (!safOk) {
            _log.w('SAF write-back failed for album RG: $filePath');
          }
        } finally {
          try {
            final tmp = File(tempPath!);
            if (await tmp.exists()) await tmp.delete();
          } catch (e) {
            _log.d('best-effort step failed: $e');
          }
        }
      } else {
        _log.w('FFmpeg album ReplayGain write failed for SAF: $filePath');
      }
    } else {
      // Local MP3 / Opus — use FFmpeg copy-with-metadata approach.
      final ok = await FFmpegService.writeAlbumReplayGainTags(
        filePath,
        albumGain,
        albumPeak,
      );
      if (!ok) {
        _log.w('FFmpeg album ReplayGain write failed for: $filePath');
      }
    }
  }

  /// Re-check album ReplayGain for all albums that still have accumulator data.
  /// Called after removing/dismissing a failed or skipped item, which may
  /// unblock an album that was waiting for retryable items to be resolved.
  void _retriggerAlbumRgChecks() {
    if (_albumRgData.isEmpty) return;
    final settings = ref.read(settingsProvider);
    if (!settings.embedReplayGain) return;

    // Snapshot the keys — _checkAndWriteAlbumReplayGain may mutate the map.
    final keys = _albumRgData.keys.toList();
    for (final key in keys) {
      final acc = _albumRgData[key];
      if (acc == null || acc.entries.isEmpty) continue;
      // Use the first entry's trackId to find a representative track.
      // _checkAndWriteAlbumReplayGain only needs it for _albumRgKey(), so any
      // track from the album works.
      final albumItems = state.items
          .where((item) => _albumRgKey(item.track) == key)
          .toList();
      // If there are no items left in queue for this album but we have
      // accumulator data, all items were completed and removed.  Use a
      // synthetic call — we need a Track to call the check, but the items
      // are gone.  For this case, directly check conditions inline.
      if (albumItems.isEmpty) {
        // All items removed → no pending/retryable.  Trigger computation.
        if (acc.entries.length > 1) {
          _computeAndWriteAlbumRg(key, acc);
        }
        continue;
      }
      final representative = albumItems.first;
      _checkAndWriteAlbumReplayGain(representative.track);
    }
  }

  /// Compute album RG and write it — extracted from _checkAndWriteAlbumReplayGain
  /// for use when no queue items remain (all completed and removed).
  Future<void> _computeAndWriteAlbumRg(
    String key,
    _AlbumRgAccumulator accumulator,
  ) async {
    final validEntries = accumulator.entries.toList();
    if (validEntries.length <= 1) {
      _albumRgData.remove(key);
      return;
    }

    double sumWeightedPower = 0;
    double sumDuration = 0;
    double maxPeak = 0;
    for (final entry in validEntries) {
      final weight = entry.durationSecs > 0 ? entry.durationSecs : 1.0;
      sumWeightedPower += pow(10, entry.integratedLufs / 10.0) * weight;
      sumDuration += weight;
      if (entry.truePeakLinear > maxPeak) {
        maxPeak = entry.truePeakLinear;
      }
    }
    final albumLufs = 10.0 * _log10(sumWeightedPower / sumDuration);
    const replayGainReferenceLufs = -18.0;
    final albumGainDb = replayGainReferenceLufs - albumLufs;

    final albumGain =
        '${albumGainDb >= 0 ? "+" : ""}${albumGainDb.toStringAsFixed(2)} dB';
    final albumPeak = maxPeak.toStringAsFixed(6);

    _log.i(
      'Album ReplayGain for "$key": gain=$albumGain, peak=$albumPeak (${validEntries.length} tracks, album LUFS=${albumLufs.toStringAsFixed(1)})',
    );

    for (final entry in validEntries) {
      try {
        await _writeAlbumReplayGain(entry.filePath, albumGain, albumPeak);
      } catch (e) {
        _log.w('Failed to write album ReplayGain to ${entry.filePath}: $e');
      }
    }

    _albumRgData.remove(key);
  }
}
