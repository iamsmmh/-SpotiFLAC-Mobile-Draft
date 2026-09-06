/// Recognition backends (Feature Group 10).
///
/// [RecognitionProvider] is the port; adapters implement it. The shipped
/// adapter is **AcoustID**, which pairs with the on-device Chromaprint
/// fingerprinter and is free for open-source clients — but it requires a user
/// supplied API key. No key is bundled: [AcoustIdRecognitionProvider.isConfigured]
/// is false until the user pastes one in Settings, and the service then reports
/// [RecognitionOutcome.unavailable] rather than pretending to work.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:spotiflac_android/ecosystem/recognition/recognition_models.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('Recognition');

/// A music identification backend.
abstract interface class RecognitionProvider {
  /// Stable id, stored on results and used for provider-priority settings.
  String get providerId;

  /// Human-readable name.
  String get displayName;

  /// False when the provider lacks credentials/config; the service skips it.
  bool get isConfigured;

  /// Identifies [fingerprint]. Implementations must not throw for ordinary
  /// failures — return an [RecognitionAttempt] with the right outcome.
  Future<RecognitionAttempt> identify(AudioFingerprint fingerprint);
}

/// AcoustID (acoustid.org) — Chromaprint lookup with MusicBrainz metadata.
class AcoustIdRecognitionProvider implements RecognitionProvider {
  AcoustIdRecognitionProvider({required this.apiKey, http.Client? client})
    : _client = client ?? http.Client();

  /// User-supplied AcoustID application key.
  final String apiKey;

  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 15);

  @override
  String get providerId => 'acoustid';

  @override
  String get displayName => 'AcoustID';

  @override
  bool get isConfigured => apiKey.trim().isNotEmpty;

  @override
  Future<RecognitionAttempt> identify(AudioFingerprint fingerprint) async {
    if (!isConfigured) {
      return const RecognitionAttempt(
        outcome: RecognitionOutcome.unavailable,
        providerId: 'acoustid',
        message: 'AcoustID API key not configured',
      );
    }
    if (fingerprint.isEmpty) {
      return const RecognitionAttempt(
        outcome: RecognitionOutcome.fingerprintFailed,
        providerId: 'acoustid',
        message: 'empty fingerprint',
      );
    }

    final uri = Uri.https('api.acoustid.org', '/v2/lookup');
    try {
      final response = await _client
          .post(
            uri,
            body: <String, String>{
              'client': apiKey.trim(),
              'duration': '${fingerprint.duration.inSeconds}',
              'fingerprint': fingerprint.fingerprint,
              'meta': 'recordings releasegroups compress',
              'format': 'json',
            },
          )
          .timeout(_timeout);

      if (response.statusCode != 200) {
        return RecognitionAttempt(
          outcome: RecognitionOutcome.unavailable,
          providerId: providerId,
          message: 'HTTP ${response.statusCode}',
        );
      }
      return parseResponse(response.body);
    } catch (error) {
      _log.w('AcoustID lookup failed: $error');
      return RecognitionAttempt(
        outcome: RecognitionOutcome.unavailable,
        providerId: providerId,
        message: '$error',
      );
    }
  }

  /// Pure decoder for the AcoustID v2 payload, exposed for tests.
  ///
  /// Flattens `results[].recordings[]` into one ranked candidate list: AcoustID
  /// scores per *fingerprint match*, and each match can carry several
  /// recordings (different releases of the same song).
  static RecognitionAttempt parseResponse(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return const RecognitionAttempt(
        outcome: RecognitionOutcome.unavailable,
        providerId: 'acoustid',
        message: 'malformed JSON',
      );
    }
    if (decoded is! Map) {
      return const RecognitionAttempt(
        outcome: RecognitionOutcome.unavailable,
        providerId: 'acoustid',
        message: 'unexpected payload',
      );
    }
    final payload = Map<String, Object?>.from(decoded);

    if (payload['status'] != 'ok') {
      final error = payload['error'];
      final message = error is Map
          ? Map<String, Object?>.from(error)['message']?.toString() ??
              'lookup rejected'
          : 'lookup rejected';
      return RecognitionAttempt(
        outcome: RecognitionOutcome.unavailable,
        providerId: 'acoustid',
        message: message,
      );
    }

    final results = payload['results'];
    if (results is! List || results.isEmpty) {
      return const RecognitionAttempt(
        outcome: RecognitionOutcome.noMatch,
        providerId: 'acoustid',
      );
    }

    final now = DateTime.now().toUtc();
    final candidates = <RecognitionResult>[];
    for (final entry in results) {
      if (entry is! Map) continue;
      final match = Map<String, Object?>.from(entry);
      final score = match['score'] is num
          ? (match['score']! as num).toDouble()
          : 0.0;
      final acoustId = match['id']?.toString() ?? '';
      final recordings = match['recordings'];
      if (recordings is! List) continue;

      for (final recording in recordings) {
        if (recording is! Map) continue;
        final row = Map<String, Object?>.from(recording);
        final title = row['title']?.toString() ?? '';
        if (title.isEmpty) continue;

        final recordingId = row['id']?.toString() ?? '';
        candidates.add(
          RecognitionResult(
            resultId: 'acoustid:${recordingId.isEmpty ? acoustId : recordingId}',
            title: title,
            artist: _artistsOf(row['artists']),
            album: _releaseOf(row['releasegroups']),
            providerId: 'acoustid',
            confidence: score.clamp(0.0, 1.0).toDouble(),
            identifiedAt: now,
            externalIds: <String, String>{
              if (acoustId.isNotEmpty) 'acoustid': acoustId,
              if (recordingId.isNotEmpty) 'musicbrainz': recordingId,
            },
          ),
        );
      }
    }

    if (candidates.isEmpty) {
      return const RecognitionAttempt(
        outcome: RecognitionOutcome.noMatch,
        providerId: 'acoustid',
      );
    }
    candidates.sort((a, b) => b.confidence.compareTo(a.confidence));
    return RecognitionAttempt(
      outcome: RecognitionOutcome.matched,
      providerId: 'acoustid',
      results: candidates,
    );
  }

  /// Joins credited artists in order, respecting the `joinphrase` field.
  static String _artistsOf(Object? raw) {
    if (raw is! List) return '';
    final buffer = StringBuffer();
    for (final artist in raw) {
      if (artist is! Map) continue;
      final credit = Map<String, Object?>.from(artist);
      final name = credit['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      buffer.write(name);
      final join = credit['joinphrase']?.toString() ?? '';
      buffer.write(join);
    }
    return buffer.toString().trim();
  }

  static String _releaseOf(Object? raw) {
    if (raw is! List) return '';
    for (final group in raw) {
      if (group is! Map) continue;
      final title = Map<String, Object?>.from(group)['title']?.toString() ?? '';
      if (title.isNotEmpty) return title;
    }
    return '';
  }

  void dispose() => _client.close();
}
