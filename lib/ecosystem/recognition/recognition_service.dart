/// Music recognition orchestration + history (Feature Group 10).
///
/// [MusicRecognitionService] wires capture → fingerprint → provider chain →
/// history. Providers are tried in registration order and the first real answer
/// wins, mirroring how the app already chains lyrics and metadata providers.
///
/// [RecognitionHistoryRepository] persists hits to `ec_recognition_history`.
library;

import 'dart:io';

import 'package:spotiflac_android/ecosystem/ecosystem_database.dart';
import 'package:spotiflac_android/ecosystem/recognition/fingerprint_engine.dart';
import 'package:spotiflac_android/ecosystem/recognition/recognition_models.dart';
import 'package:spotiflac_android/ecosystem/recognition/recognition_provider.dart';
import 'package:spotiflac_android/utils/logger.dart';
import 'package:sqflite/sqflite.dart';

final _log = AppLogger('RecognitionService');

/// Port for recognition history storage.
///
/// Declared as an interface so the service can be unit-tested against an
/// in-memory double: a class with private fields cannot be `implement`ed from
/// another library.
abstract interface class RecognitionHistoryStore {
  /// Most recent first.
  Future<List<RecognitionResult>> recent({int limit});

  Future<void> save(RecognitionResult result);

  Future<void> remove(String resultId);

  Future<void> clear();

  Future<int> count();
}

/// SQLite-backed [RecognitionHistoryStore].
class RecognitionHistoryRepository implements RecognitionHistoryStore {
  RecognitionHistoryRepository({EcosystemDatabase? database})
    : _database = database ?? EcosystemDatabase.instance;

  final EcosystemDatabase _database;

  /// Most recent first.
  @override
  Future<List<RecognitionResult>> recent({int limit = 100}) async {
    final db = await _database.database;
    final rows = await db.query(
      tableRecognitionHistory,
      orderBy: 'identified_at DESC',
      limit: limit,
    );
    return rows
        .map(RecognitionResult.fromRow)
        .where((result) => result.resultId.isNotEmpty)
        .toList(growable: false);
  }

  /// Saves a hit. Re-identifying the same song refreshes its timestamp rather
  /// than creating a duplicate row.
  @override
  Future<void> save(RecognitionResult result) async {
    final db = await _database.database;
    await db.insert(
      tableRecognitionHistory,
      result.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> remove(String resultId) async {
    final db = await _database.database;
    await db.delete(
      tableRecognitionHistory,
      where: 'result_id = ?',
      whereArgs: <Object?>[resultId],
    );
  }

  @override
  Future<void> clear() async {
    final db = await _database.database;
    await db.delete(tableRecognitionHistory);
  }

  @override
  Future<int> count() async {
    final db = await _database.database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS total FROM $tableRecognitionHistory',
    );
    final value = rows.isEmpty ? null : rows.first['total'];
    return value is num ? value.toInt() : 0;
  }
}

/// Captures audio to a temporary file for fingerprinting.
///
/// Kept as a port because microphone capture is platform work: the app's
/// existing `PlatformBridge` grows a `captureAudio` method, and tests inject a
/// recorder that returns a fixture file.
abstract interface class RecognitionRecorder {
  /// Records roughly [duration] of audio and returns the sample.
  Future<RecognitionSample> record(Duration duration);

  /// Aborts an in-progress capture.
  Future<void> cancel();
}

/// Orchestrates one identification.
class MusicRecognitionService {
  MusicRecognitionService({
    required RecognitionRecorder recorder,
    required List<RecognitionProvider> providers,
    FingerprintEngine? fingerprintEngine,
    RecognitionHistoryStore? history,
  }) : _recorder = recorder,
       _providers = providers,
       _fingerprintEngine =
           fingerprintEngine ?? const ChromaprintFingerprintEngine(),
       _history = history ?? RecognitionHistoryRepository();

  /// Default capture length — long enough for Chromaprint, short enough that
  /// the user is not left waiting.
  static const Duration defaultCaptureDuration = Duration(seconds: 12);

  final RecognitionRecorder _recorder;
  final List<RecognitionProvider> _providers;
  final FingerprintEngine _fingerprintEngine;
  final RecognitionHistoryStore _history;

  RecognitionHistoryStore get history => _history;

  /// Providers that are actually usable right now.
  List<RecognitionProvider> get availableProviders =>
      _providers.where((provider) => provider.isConfigured).toList(
        growable: false,
      );

  bool get hasConfiguredProvider => availableProviders.isNotEmpty;

  /// Records from the microphone and identifies what is playing.
  ///
  /// The captured file is always deleted, even on failure — we never retain
  /// raw audio of the user's surroundings.
  Future<RecognitionAttempt> identifyFromMicrophone({
    Duration duration = defaultCaptureDuration,
    bool saveToHistory = true,
  }) async {
    if (!hasConfiguredProvider) {
      return const RecognitionAttempt(
        outcome: RecognitionOutcome.unavailable,
        message: 'no recognition provider is configured',
      );
    }

    RecognitionSample? sample;
    try {
      sample = await _recorder.record(duration);
      return await identifyFromSample(sample, saveToHistory: saveToHistory);
    } catch (error) {
      _log.w('Capture failed: $error');
      return RecognitionAttempt(
        outcome: RecognitionOutcome.fingerprintFailed,
        message: '$error',
      );
    } finally {
      await _deleteSample(sample);
    }
  }

  /// Identifies an existing audio file (a downloaded track with no tags, a
  /// shared clip, ...).
  Future<RecognitionAttempt> identifyFromSample(
    RecognitionSample sample, {
    bool saveToHistory = true,
  }) async {
    final AudioFingerprint fingerprint;
    try {
      fingerprint = await _fingerprintEngine.fingerprint(sample);
    } on FingerprintException catch (error) {
      return RecognitionAttempt(
        outcome: RecognitionOutcome.fingerprintFailed,
        message: error.message,
      );
    }

    var lastFailure = const RecognitionAttempt(
      outcome: RecognitionOutcome.unavailable,
      message: 'no recognition provider is configured',
    );

    for (final provider in _providers) {
      if (!provider.isConfigured) continue;
      final attempt = await provider.identify(fingerprint);
      if (attempt.isMatch) {
        if (saveToHistory) await _history.save(attempt.best!);
        return attempt;
      }
      // A definitive "not in the database" is worth reporting once every
      // provider agrees; keep it as the best answer so far.
      if (attempt.outcome == RecognitionOutcome.noMatch) {
        lastFailure = attempt;
      } else if (lastFailure.outcome != RecognitionOutcome.noMatch) {
        lastFailure = attempt;
      }
    }
    return lastFailure;
  }

  Future<void> cancel() => _recorder.cancel();

  Future<void> _deleteSample(RecognitionSample? sample) async {
    if (sample == null) return;
    try {
      final file = File(sample.filePath);
      if (await file.exists()) await file.delete();
    } catch (error) {
      _log.w('Could not delete recognition sample: $error');
    }
  }
}
