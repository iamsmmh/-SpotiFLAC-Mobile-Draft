import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:spotiflac_android/utils/logger.dart';
import 'package:spotiflac_android/utils/path_match_keys.dart';
import 'package:sqflite/sqflite.dart';

final _log = AppLogger('AppSqlite');

/// Caches an asynchronously-created value while also coalescing concurrent
/// callers onto the same in-flight initialization.
class SingleFlightInitializer<T extends Object> {
  T? _value;
  Future<T>? _initializing;

  Future<T> getOrCreate(Future<T> Function() create) {
    final value = _value;
    if (value != null) return Future<T>.value(value);

    final initializing = _initializing;
    if (initializing != null) return initializing;

    late final Future<T> future;
    future = Future<T>.sync(create)
        .then((value) {
          _value = value;
          return value;
        })
        .whenComplete(() {
          if (identical(_initializing, future)) {
            _initializing = null;
          }
        });
    _initializing = future;
    return future;
  }

  void reset() {
    _value = null;
  }
}

/// Opens a database file in the app documents directory with the shared
/// WAL + synchronous=NORMAL configuration.
Future<Database> openAppDatabase(
  String fileName, {
  required int version,
  required Future<void> Function(Database db, int version) onCreate,
  required Future<void> Function(Database db, int oldVersion, int newVersion)
  onUpgrade,
  bool foreignKeys = false,
  bool incrementalAutoVacuum = true,
}) async {
  final dbPath = await getApplicationDocumentsDirectory();
  final path = join(dbPath.path, fileName);

  _log.i('Initializing database at: $path');

  return openDatabase(
    path,
    version: version,
    onConfigure: (db) async {
      // Set this before any other PRAGMA so transient writer contention waits
      // instead of immediately surfacing SQLITE_BUSY during startup.
      await db.rawQuery('PRAGMA busy_timeout = 5000');
      if (foreignKeys) {
        await db.execute('PRAGMA foreign_keys = ON');
      }
      if (incrementalAutoVacuum) {
        final tables = await db.rawQuery('''
          SELECT 1
          FROM sqlite_master
          WHERE type = 'table'
            AND name NOT LIKE 'sqlite_%'
            AND name != 'android_metadata'
          LIMIT 1
        ''');
        // Changing from NONE must happen outside a transaction and before the
        // first application table is created. Android may already have added
        // its internal android_metadata table at this point.
        if (tables.isEmpty) {
          await db.execute('PRAGMA auto_vacuum = INCREMENTAL');
        }
      }
      await db.rawQuery('PRAGMA journal_mode = WAL');
      await db.execute('PRAGMA synchronous = NORMAL');
    },
    onCreate: onCreate,
    onUpgrade: onUpgrade,
  );
}

String normalizeLookupText(String? value) {
  return (value ?? '').trim().toLowerCase();
}

Future<void> addColumnIfMissing(
  Database db,
  String table,
  String column,
  String type,
) async {
  final columns = await db.rawQuery('PRAGMA table_info($table)');
  final exists = columns.any(
    (row) => (row['name']?.toString().toLowerCase() ?? '') == column,
  );
  if (!exists) {
    await db.execute('ALTER TABLE $table ADD COLUMN $column $type');
  }
}

/// Loads rows whose [column] matches any of [rawValues] (chunked IN clauses)
/// into [destination], keeping the first row seen per value.
Future<void> loadRowsByColumn(
  DatabaseExecutor db, {
  required String table,
  required String column,
  required Iterable<String> rawValues,
  required Map<String, Map<String, dynamic>> destination,
  required Map<String, dynamic> Function(Map<String, Object?> row) mapRow,
  String? orderBy,
}) async {
  final values = rawValues.where((value) => value.isNotEmpty).toSet().toList();
  const chunkSize = 450;
  for (var start = 0; start < values.length; start += chunkSize) {
    final end = (start + chunkSize).clamp(0, values.length);
    final chunk = values.sublist(start, end);
    final placeholders = List.filled(chunk.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT * FROM $table WHERE $column IN ($placeholders)'
      '${orderBy == null ? '' : ' ORDER BY $orderBy'}',
      chunk,
    );
    for (final row in rows) {
      final key = row[column] as String?;
      if (key != null && key.isNotEmpty) {
        destination.putIfAbsent(key, () => mapRow(row));
      }
    }
  }
}

Future<void> createPathKeyTable(DatabaseExecutor db, String table) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $table (
      item_id TEXT NOT NULL,
      path_key TEXT NOT NULL,
      PRIMARY KEY (item_id, path_key)
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_${table}_key ON $table(path_key)',
  );
}

Future<void> backfillPathKeys(
  Database db,
  String sourceTable,
  String keyTable,
) async {
  final rows = await db.query(sourceTable, columns: ['id', 'file_path']);
  final batch = db.batch();
  for (final row in rows) {
    putPathKeysInBatch(
      batch,
      keyTable,
      row['id'] as String,
      row['file_path'] as String?,
    );
  }
  await batch.commit(noResult: true);
}

void putPathKeysInBatch(
  Batch batch,
  String table,
  String id,
  String? filePath,
) {
  batch.delete(table, where: 'item_id = ?', whereArgs: [id]);
  for (final key in buildPathMatchKeys(filePath)) {
    batch.insert(table, {
      'item_id': id,
      'path_key': key,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }
}
