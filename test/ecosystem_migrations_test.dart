import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/ecosystem/ecosystem_database.dart';

void main() {
  group('ecosystem migrations', () {
    test('a fresh install replays every step in order', () {
      final steps = migrationsBetween(0, ecosystemDatabaseVersion);
      expect(steps.length, ecosystemDatabaseVersion);
      for (var i = 0; i < steps.length; i++) {
        expect(steps[i].fromVersion, i);
        expect(steps[i].toVersion, i + 1);
      }
    });

    test('a v2 database only runs the steps it is missing', () {
      final steps = migrationsBetween(2, 4);
      expect(steps.map((step) => step.toVersion), <int>[3, 4]);
    });

    test('no steps when the database is already current', () {
      expect(migrationsBetween(ecosystemDatabaseVersion, ecosystemDatabaseVersion), isEmpty);
      expect(migrationsBetween(5, 3), isEmpty);
    });

    test('every statement is a single idempotent DDL/DML statement', () {
      for (final migration in ecosystemMigrations) {
        expect(migration.statements, isNotEmpty);
        for (final statement in migration.statements) {
          final trimmed = statement.trim();
          expect(
            trimmed.toUpperCase().startsWith('CREATE') ||
                trimmed.toUpperCase().startsWith('ALTER'),
            isTrue,
            reason: 'unexpected statement: $trimmed',
          );
          // One statement per entry: `db.execute` cannot run a batch.
          expect(trimmed.split(';').length, 1, reason: 'multiple statements');
        }
      }
    });

    test('v1 creates every table the ecosystem modules use', () {
      final schema = ecosystemSchemaV1.join('\n');
      for (final table in <String>[
        tableListeningEvents,
        tableTrackHistory,
        tableFavoritePlaylists,
        tableStreamCache,
        tablePodcastSubscriptions,
        tablePodcastEpisodes,
        tableRecognitionHistory,
        tableOfflineCollections,
        tableSmartPlaylistState,
        tableSocialCache,
        tableAccountState,
        tableSyncTombstones,
        tableEcosystemMeta,
      ]) {
        expect(schema.contains('CREATE TABLE IF NOT EXISTS $table'), isTrue,
            reason: '$table missing from v1');
      }
    });

    test('migration metadata survives a JSON round trip', () {
      final json = ecosystemMigrations.first.toJson();
      expect(json['from'], 0);
      expect(json['to'], 1);
      expect(json['statements'], isA<List<Object?>>());
    });
  });
}
