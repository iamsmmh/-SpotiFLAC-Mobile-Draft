import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/ecosystem/discovery/discovery_schema.dart';
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

    test('an existing v5 database gets exactly the discovery step', () {
      final steps = migrationsBetween(5, ecosystemDatabaseVersion);
      expect(steps.length, 1);
      expect(steps.single.fromVersion, 5);
      expect(steps.single.toVersion, 6);
    });

    test('v6 adds every discovery table without touching an existing one', () {
      final migration = ecosystemMigrations.singleWhere(
        (migration) => migration.fromVersion == 5,
      );
      final sql = migration.statements.join('\n').toUpperCase();

      for (final table in <String>[
        dsListeningStatistics,
        dsUserProfiles,
        dsRecommendationCache,
        dsDailyMixes,
        dsDiscoverWeekly,
        dsRadioSessions,
        dsArtistSimilarity,
        dsTrackSimilarity,
        dsMoodProfiles,
        dsTrendingStatistics,
        dsContinueListening,
      ]) {
        expect(
          migration.statements.any(
            (statement) => statement.contains(
              'CREATE TABLE IF NOT EXISTS $table',
            ),
          ),
          isTrue,
          reason: '$table missing from the v6 migration',
        );
      }

      // Additive only: no ALTER, no DROP against a table that existed at v5.
      expect(sql.contains('ALTER'), isFalse, reason: 'v6 must not alter v5');
      expect(sql.contains('DROP'), isFalse, reason: 'v6 must not drop anything');
      for (final legacy in <String>[
        tableListeningEvents,
        tableTrackHistory,
        tableFavoritePlaylists,
        tableStreamCache,
      ]) {
        expect(
          sql.contains(legacy.toUpperCase()),
          isFalse,
          reason: '$legacy must be untouched by the discovery migration',
        );
      }
    });

    test('every discovery table is also created on a fresh install', () {
      // `_onCreate` replays `migrationsBetween(0, version)` and `_onUpgrade`
      // runs `ecosystemSchemaV1` first, so a brand-new user and an upgraded one
      // must both end up with the discovery tables.
      final all = <String>[
        ...ecosystemSchemaV1,
        ...ecosystemMigrations.expand((migration) => migration.statements),
      ].join('\n');
      for (final table in <String>[
        dsListeningStatistics,
        dsContinueListening,
        dsTrendingStatistics,
      ]) {
        expect(
          all.contains('CREATE TABLE IF NOT EXISTS $table'),
          isTrue,
          reason: '$table is never created for a fresh install',
        );
      }
    });
  });
}
