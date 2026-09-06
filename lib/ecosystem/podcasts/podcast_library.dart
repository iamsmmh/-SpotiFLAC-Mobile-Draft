/// Offline podcast library: downloads, retention and repair (Feature Group 9).
///
/// Owns the *filesystem* side of podcasts; [PodcastRepository] owns the rows.
/// Episode audio lives in `<appSupport>/podcasts/<feed hash>/<episode>.<ext>`,
/// deliberately outside the user's music download folder so podcast files never
/// pollute the library scanner or the download history.
///
/// Retention is per-feed (`keepEpisodes`): after a successful download the
/// oldest downloaded episodes beyond the window are pruned, but an episode the
/// user is part-way through is never deleted.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:spotiflac_android/core/data/sha256.dart';
import 'package:spotiflac_android/ecosystem/podcasts/podcast_models.dart';
import 'package:spotiflac_android/ecosystem/podcasts/podcast_repository.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('PodcastLibrary');

/// Progress callback: bytes received / total (total is -1 when unknown).
typedef EpisodeDownloadProgress = void Function(int received, int total);

/// Outcome of a single episode download.
class EpisodeDownloadResult {
  const EpisodeDownloadResult({
    required this.episodeKey,
    required this.success,
    this.filePath,
    this.bytes = 0,
    this.error,
  });

  final String episodeKey;
  final bool success;
  final String? filePath;
  final int bytes;
  final String? error;
}

/// Result of an integrity sweep.
class PodcastRepairReport {
  const PodcastRepairReport({
    this.missingFiles = const <String>[],
    this.orphanFiles = const <String>[],
    this.reclaimedBytes = 0,
  });

  /// Episodes whose row claimed a download but whose file is gone; their state
  /// has been reset so they can be re-fetched.
  final List<String> missingFiles;

  /// Files on disk with no owning row; deleted.
  final List<String> orphanFiles;

  final int reclaimedBytes;

  bool get isClean => missingFiles.isEmpty && orphanFiles.isEmpty;
}

class PodcastLibrary {
  PodcastLibrary({
    required PodcastRepository repository,
    http.Client? client,
    Directory? rootOverride,
  }) : _repository = repository,
       _client = client ?? http.Client(),
       _rootOverride = rootOverride;

  final PodcastRepository _repository;
  final http.Client _client;
  final Directory? _rootOverride;

  Directory? _root;

  /// In-flight downloads, so a double tap cannot start two writers on one file.
  final Map<String, Future<EpisodeDownloadResult>> _inFlight =
      <String, Future<EpisodeDownloadResult>>{};

  /// Root directory for podcast audio, created on first use.
  Future<Directory> root() async {
    final cached = _root;
    if (cached != null) return cached;
    final base = _rootOverride ?? await getApplicationSupportDirectory();
    final directory = Directory(p.join(base.path, 'podcasts'));
    await directory.create(recursive: true);
    return _root = directory;
  }

  /// Deterministic on-disk location for an episode.
  ///
  /// Both segments are hashed: feed URLs and episode titles routinely contain
  /// characters that are illegal in filenames on one platform or another.
  Future<File> fileFor(PodcastEpisode episode) async {
    final directory = Directory(
      p.join((await root()).path, _hash(episode.feedUrl)),
    );
    await directory.create(recursive: true);
    return File(
      p.join(directory.path, '${_hash(episode.episodeKey)}${_extensionFor(episode.audioUrl)}'),
    );
  }

  // -- Download ------------------------------------------------------------

  /// Downloads an episode to local storage and updates its row.
  ///
  /// Writes to a `.part` file and renames on success, so an interrupted
  /// download can never be mistaken for a complete one.
  Future<EpisodeDownloadResult> download(
    PodcastEpisode episode, {
    EpisodeDownloadProgress? onProgress,
  }) {
    final existing = _inFlight[episode.episodeKey];
    if (existing != null) return existing;

    final operation = _download(episode, onProgress).whenComplete(() {
      _inFlight.remove(episode.episodeKey);
    });
    _inFlight[episode.episodeKey] = operation;
    return operation;
  }

  Future<EpisodeDownloadResult> _download(
    PodcastEpisode episode,
    EpisodeDownloadProgress? onProgress,
  ) async {
    final target = await fileFor(episode);

    // Already downloaded and intact — nothing to do.
    if (await target.exists() && await target.length() > 0) {
      await _repository.setDownloadState(
        episode.episodeKey,
        EpisodeDownloadState.downloaded,
        filePath: target.path,
      );
      return EpisodeDownloadResult(
        episodeKey: episode.episodeKey,
        success: true,
        filePath: target.path,
        bytes: await target.length(),
      );
    }

    await _repository.setDownloadState(
      episode.episodeKey,
      EpisodeDownloadState.downloading,
    );

    final partial = File('${target.path}.part');
    IOSink? sink;
    try {
      final request = http.Request('GET', Uri.parse(episode.audioUrl))
        ..headers['User-Agent'] = 'SpotiFLAC-Mobile/5.0 (podcast client)';
      final response = await _client.send(request);
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }

      final total = response.contentLength ?? -1;
      var received = 0;
      sink = partial.openWrite();
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;

      if (received <= 0) throw const HttpException('empty response body');

      await partial.rename(target.path);
      await _repository.setDownloadState(
        episode.episodeKey,
        EpisodeDownloadState.downloaded,
        filePath: target.path,
      );
      await _enforceRetention(episode.feedUrl);

      return EpisodeDownloadResult(
        episodeKey: episode.episodeKey,
        success: true,
        filePath: target.path,
        bytes: received,
      );
    } catch (error) {
      _log.w('Episode download failed (${episode.title}): $error');
      try {
        await sink?.close();
        if (await partial.exists()) await partial.delete();
      } catch (_) {
        // Cleanup is best-effort; the repair sweep catches leftovers.
      }
      await _repository.setDownloadState(
        episode.episodeKey,
        EpisodeDownloadState.failed,
      );
      return EpisodeDownloadResult(
        episodeKey: episode.episodeKey,
        success: false,
        error: '$error',
      );
    }
  }

  /// Deletes a downloaded episode's file and resets its state, keeping the
  /// listening progress intact.
  Future<void> deleteDownload(PodcastEpisode episode) async {
    final path = episode.filePath;
    if (path != null && path.isNotEmpty) {
      final file = File(path);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (error) {
          _log.w('Could not delete ${episode.title}: $error');
        }
      }
    }
    await _repository.setDownloadState(
      episode.episodeKey,
      EpisodeDownloadState.none,
    );
  }

  /// Unsubscribes and removes every downloaded file for the feed.
  Future<void> unsubscribe(String feedUrl) async {
    for (final episode in await _repository.episodes(feedUrl)) {
      if (episode.isDownloaded) await deleteDownload(episode);
    }
    final directory = Directory(p.join((await root()).path, _hash(feedUrl)));
    if (await directory.exists()) {
      try {
        await directory.delete(recursive: true);
      } catch (error) {
        _log.w('Could not remove feed directory: $error');
      }
    }
    await _repository.unsubscribe(feedUrl);
  }

  /// Fetches new episodes for feeds with auto-download enabled.
  ///
  /// Returns every download attempted this pass.
  Future<List<EpisodeDownloadResult>> syncAutoDownloads({
    int maxPerFeed = 3,
  }) async {
    final results = <EpisodeDownloadResult>[];
    for (final subscription in await _repository.subscriptions()) {
      if (!subscription.autoDownload) continue;
      final episodes = await _repository.episodes(
        subscription.feedUrl,
        limit: maxPerFeed,
        unplayedOnly: true,
      );
      for (final episode in episodes) {
        if (episode.isDownloaded) continue;
        results.add(await download(episode));
      }
    }
    return results;
  }

  // -- Retention & repair --------------------------------------------------

  /// Prunes downloads beyond the feed's retention window, oldest first.
  ///
  /// Episodes that are started-but-unfinished are protected: deleting what
  /// someone is mid-way through is never what they wanted.
  Future<int> _enforceRetention(String feedUrl) async {
    final subscription = await _repository.subscription(feedUrl);
    if (subscription == null) return 0;
    final keep = subscription.keepEpisodes;
    if (keep <= 0) return 0;

    final downloaded = (await _repository.episodes(feedUrl))
        .where((episode) => episode.isDownloaded)
        .toList(growable: false);
    if (downloaded.length <= keep) return 0;

    // episodes() is newest-first, so everything past `keep` is a candidate.
    var removed = 0;
    for (final episode in downloaded.skip(keep)) {
      final inProgress =
          episode.playedPosition > Duration.zero && !episode.isPlayed;
      if (inProgress) continue;
      await deleteDownload(episode);
      removed++;
    }
    return removed;
  }

  /// Verifies every claimed download and reconciles rows with the filesystem.
  Future<PodcastRepairReport> repair() async {
    final missing = <String>[];
    final orphans = <String>[];
    var reclaimed = 0;

    final knownPaths = <String>{};
    for (final episode in await _repository.downloadedEpisodes()) {
      final path = episode.filePath;
      if (path == null || path.isEmpty) {
        missing.add(episode.episodeKey);
        await _repository.setDownloadState(
          episode.episodeKey,
          EpisodeDownloadState.none,
        );
        continue;
      }
      final file = File(path);
      if (!await file.exists() || await file.length() <= 0) {
        missing.add(episode.episodeKey);
        await _repository.setDownloadState(
          episode.episodeKey,
          EpisodeDownloadState.none,
        );
        continue;
      }
      knownPaths.add(p.normalize(file.absolute.path));
    }

    final directory = await root();
    if (await directory.exists()) {
      await for (final entity in directory.list(recursive: true)) {
        if (entity is! File) continue;
        final path = p.normalize(entity.absolute.path);
        // Stale `.part` files are always garbage; complete files are garbage
        // only when no row claims them.
        final isPartial = path.endsWith('.part');
        if (!isPartial && knownPaths.contains(path)) continue;
        try {
          reclaimed += await entity.length();
          await entity.delete();
          orphans.add(path);
        } catch (error) {
          _log.w('Could not delete orphan $path: $error');
        }
      }
    }

    return PodcastRepairReport(
      missingFiles: missing,
      orphanFiles: orphans,
      reclaimedBytes: reclaimed,
    );
  }

  /// Total bytes occupied by downloaded podcast audio.
  Future<int> usedBytes() async {
    final directory = await root();
    if (!await directory.exists()) return 0;
    var total = 0;
    await for (final entity in directory.list(recursive: true)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } catch (_) {
          // File vanished mid-walk; ignore.
        }
      }
    }
    return total;
  }

  void dispose() => _client.close();

  static String _hash(String value) =>
      sha256Hex(utf8.encode(value)).substring(0, 24);

  /// Extension from the audio URL, defaulting to `.mp3` (the podcast norm).
  static String _extensionFor(String audioUrl) {
    final path = Uri.tryParse(audioUrl)?.path ?? '';
    final extension = p.extension(path).toLowerCase();
    const allowed = <String>{
      '.mp3',
      '.m4a',
      '.aac',
      '.ogg',
      '.opus',
      '.wav',
      '.flac',
      '.m4b',
    };
    return allowed.contains(extension) ? extension : '.mp3';
  }
}
