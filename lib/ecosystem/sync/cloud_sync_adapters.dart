/// Concrete [CloudSyncProvider] adapters (Feature Group 2).
///
/// The port itself lives in `core/sync/cloud_sync_provider.dart` — the app
/// talks to that interface only, so these adapters are a configuration
/// decision made once at composition time.
///
/// All three use plain REST:
///   * Firebase  → Cloud Firestore REST (`users/{uid}/sync_{scope}`)
///   * Supabase  → PostgREST (`sync_records` table, upsert merge)
///   * Self-hosted → the reference contract in `docs/API_CONTRACTS.md`
///     and `server/schema.sql`
///
/// Authentication is *not* re-implemented here: every adapter asks a
/// [SyncAuthBridge] (backed by [AccountService]) for a token, so accounts and
/// sync can never drift into two sessions.
library;

import 'package:spotimusic/core/sync/cloud_sync_provider.dart';
import 'package:spotimusic/core/sync/sync_entities.dart';
import 'package:spotimusic/ecosystem/account/account_service.dart';
import 'package:spotimusic/ecosystem/account/auth_adapters.dart';
import 'package:spotimusic/ecosystem/account/auth_provider.dart';

/// Supplies the identity + token a sync adapter needs.
abstract interface class SyncAuthBridge {
  Future<UserProfile?> currentUser();

  Future<UserProfile> signIn(Map<String, Object?> credentials);

  Future<void> signOut();

  Future<String?> accessToken();
}

/// Bridges [AccountService] into the sync layer.
class AccountServiceAuthBridge implements SyncAuthBridge {
  AccountServiceAuthBridge(this._account);

  final AccountService _account;

  @override
  Future<String?> accessToken() => _account.accessToken();

  @override
  Future<UserProfile?> currentUser() async {
    final user = _account.state.user;
    if (user == null) return null;
    return UserProfile(
      userId: user.id,
      providerId: user.providerId,
      displayName: user.displayName,
      avatarUrl: user.avatarUrl,
      email: user.email,
    );
  }

  @override
  Future<UserProfile> signIn(Map<String, Object?> credentials) async {
    final method = credentials['method']?.toString() ?? 'email';
    switch (method) {
      case 'email':
        await _account.signInWithEmail(
          email: credentials['email']?.toString() ?? '',
          password: credentials['password']?.toString() ?? '',
        );
        break;
      case 'anonymous':
        await _account.continueAsGuest();
        break;
      default:
        throw const SyncAuthException('unsupported sign-in method');
    }
    final user = await currentUser();
    if (user == null) {
      throw const SyncAuthException('sign-in produced no profile');
    }
    return user;
  }

  @override
  Future<void> signOut() => _account.signOut();
}

/// Shared REST plumbing for the three adapters.
abstract class RestSyncAdapter implements CloudSyncProvider {
  RestSyncAdapter({required this.auth, AuthHttp? http})
    : _http = http ?? AuthHttp();

  final SyncAuthBridge auth;
  final AuthHttp _http;

  Future<Map<String, String>> authHeaders() async {
    final token = await auth.accessToken();
    return <String, String>{
      'Accept': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  /// Resolves the signed-in user id, throwing when unauthenticated.
  Future<String> requireUserId() async {
    final user = await auth.currentUser();
    if (user == null) {
      throw const SyncAuthException('sign in before syncing');
    }
    return user.userId;
  }

  Future<Map<String, Object?>> getJson(
    Uri uri, {
    Map<String, String>? headers,
  }) async {
    return _guard(() async => _http.getJson(uri, headers: await authHeaders()));
  }

  Future<Map<String, Object?>> postJson(
    Uri uri,
    Map<String, Object?> body, {
    Map<String, String>? headers,
  }) async {
    final mergedHeaders = <String, String>{
      ...?headers,
      ...await authHeaders(),
    };
    return _guard(
      () => _http.postJson(uri, body: body, headers: mergedHeaders),
    );
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on AuthException catch (error) {
      if (error is AuthUnauthorizedException) {
        throw SyncAuthException(error.message);
      }
      throw SyncUnavailableException(error.message);
    }
  }

  @override
  Future<UserProfile?> currentUser() => auth.currentUser();

  @override
  Future<UserProfile> signIn(Map<String, Object?> credentials) =>
      auth.signIn(credentials);

  @override
  Future<void> signOut() => auth.signOut();

  /// Backend-specific pull.
  Future<List<SyncRecord>> fetchRecords(SyncScope scope, int? sinceRevision);

  /// Backend-specific push; returns server revision per record id.
  Future<Map<String, int>> uploadRecords(
    SyncScope scope,
    List<SyncRecord> records,
  );

  @override
  Future<List<SyncRecord>> pull(SyncScope scope, {int? sinceRevision}) {
    return fetchRecords(scope, sinceRevision);
  }

  @override
  Future<Map<String, int>> push(SyncScope scope, List<SyncRecord> records) {
    if (records.isEmpty) {
      return Future<Map<String, int>>.value(const <String, int>{});
    }
    return uploadRecords(scope, records);
  }
}

// ---------------------------------------------------------------------------
// Firebase — Cloud Firestore REST
// ---------------------------------------------------------------------------

/// Firestore-backed sync. Stores one collection per scope under the user.
class FirebaseSyncAdapter extends RestSyncAdapter {
  FirebaseSyncAdapter({
    required this.projectId,
    required super.auth,
    super.http,
    this.databaseId = '(default)',
  });

  final String projectId;
  final String databaseId;

  static const String _base = 'https://firestore.googleapis.com/v1';

  @override
  String get id => 'firebase';

  @override
  String get displayName => 'Firebase (Firestore)';

  String _collection(SyncScope scope) => 'sync_${scope.wireId}';

  Uri _documentsUri(String userId, SyncScope scope) => Uri.parse(
    '$_base/projects/$projectId/databases/$databaseId/documents/'
    'users/$userId/${_collection(scope)}',
  );

  @override
  Future<List<SyncRecord>> fetchRecords(
    SyncScope scope,
    int? sinceRevision,
  ) async {
    final userId = await requireUserId();
    final uri = _documentsUri(userId, scope).replace(
      queryParameters: <String, String>{
        'pageSize': '500',
        'orderBy': 'revision',
      },
    );
    final json = await getJson(uri);
    final documents = json['documents'];
    if (documents is! List) return const <SyncRecord>[];
    final records = <SyncRecord>[];
    for (final raw in documents) {
      if (raw is! Map) continue;
      final document = Map<String, Object?>.from(raw);
      final fields = document['fields'];
      if (fields is! Map) continue;
      final record = _recordFromFirestore(
        scope,
        Map<String, Object?>.from(fields),
      );
      if (record == null) continue;
      if (sinceRevision != null && record.revision <= sinceRevision) continue;
      records.add(record);
    }
    return records;
  }

  @override
  Future<Map<String, int>> uploadRecords(
    SyncScope scope,
    List<SyncRecord> records,
  ) async {
    final userId = await requireUserId();
    final revisions = <String, int>{};
    for (final record in records) {
      final uri = _documentsUri(userId, scope).replace(
        queryParameters: <String, String>{'documentId': record.recordId},
      );
      // `POST ?documentId=` is create-or-overwrite in Firestore REST, which is
      // exactly the idempotent upsert the push contract requires.
      await postJson(uri, <String, Object?>{'fields': _fieldsFor(record)});
      revisions[record.recordId] = record.revision;
    }
    return revisions;
  }

  static Map<String, Object?> _fieldsFor(SyncRecord record) {
    return <String, Object?>{
      'recordId': <String, Object?>{'stringValue': record.recordId},
      'revision': <String, Object?>{'integerValue': '${record.revision}'},
      'updatedAt': <String, Object?>{
        'timestampValue': record.updatedAt.toUtc().toIso8601String(),
      },
      'deleted': <String, Object?>{'booleanValue': record.deleted},
      'payload': _encodeValue(record.payload),
    };
  }

  /// Recursively encodes a JSON-shaped map into Firestore's typed value wire
  /// format. Unknown shapes degrade to a string so a push never fails on an
  /// exotic field.
  static Map<String, Object?> _encodeValue(Object? value) {
    if (value == null) return <String, Object?>{'nullValue': null};
    if (value is bool) return <String, Object?>{'booleanValue': value};
    if (value is int) return <String, Object?>{'integerValue': '$value'};
    if (value is double) return <String, Object?>{'doubleValue': value};
    if (value is String) return <String, Object?>{'stringValue': value};
    if (value is DateTime) {
      return <String, Object?>{
        'timestampValue': value.toUtc().toIso8601String(),
      };
    }
    if (value is List) {
      return <String, Object?>{
        'arrayValue': <String, Object?>{
          'values': value.map(_encodeValue).toList(growable: false),
        },
      };
    }
    if (value is Map) {
      return <String, Object?>{
        'mapValue': <String, Object?>{
          'fields': value.map(
            (key, entry) => MapEntry(key.toString(), _encodeValue(entry)),
          ),
        },
      };
    }
    return <String, Object?>{'stringValue': value.toString()};
  }

  static Object? _decodeValue(Object? raw) {
    if (raw is! Map) return null;
    final typed = Map<String, Object?>.from(raw);
    if (typed.containsKey('nullValue')) return null;
    final stringValue = typed['stringValue'];
    if (stringValue != null) return stringValue.toString();
    if (typed.containsKey('booleanValue')) return typed['booleanValue'] == true;
    final integerValue = typed['integerValue'];
    if (integerValue != null) {
      return int.tryParse(integerValue.toString()) ?? integerValue;
    }
    final doubleValue = typed['doubleValue'];
    if (doubleValue is num) return doubleValue.toDouble();
    final timestamp = typed['timestampValue'];
    if (timestamp != null) return timestamp.toString();
    final array = typed['arrayValue'];
    if (array is Map) {
      final values = Map<String, Object?>.from(array)['values'];
      if (values is List) {
        return values.map(_decodeValue).toList(growable: false);
      }
      return const <Object?>[];
    }
    final map = typed['mapValue'];
    if (map is Map) {
      final fields = Map<String, Object?>.from(map)['fields'];
      if (fields is Map) {
        return fields.map(
          (key, value) => MapEntry(key.toString(), _decodeValue(value)),
        );
      }
      return const <String, Object?>{};
    }
    return null;
  }

  static SyncRecord? _recordFromFirestore(
    SyncScope scope,
    Map<String, Object?> fields,
  ) {
    final payloadRaw = _decodeValue(fields['payload']);
    final recordId = _decodeValue(fields['recordId'])?.toString();
    final updatedAtRaw = _decodeValue(fields['updatedAt'])?.toString();
    final revisionRaw = _decodeValue(fields['revision']);
    final updatedAt = updatedAtRaw == null ? null : DateTime.tryParse(
      updatedAtRaw,
    );
    if (recordId == null || updatedAt == null) return null;
    return SyncRecord(
      scope: scope,
      recordId: recordId,
      revision: revisionRaw is int
          ? revisionRaw
          : int.tryParse(revisionRaw?.toString() ?? '') ?? 0,
      updatedAt: updatedAt.toUtc(),
      deleted: _decodeValue(fields['deleted']) == true,
      payload: payloadRaw is Map
          ? Map<String, Object?>.from(payloadRaw)
          : const <String, Object?>{},
    );
  }
}

// ---------------------------------------------------------------------------
// Supabase — PostgREST
// ---------------------------------------------------------------------------

/// Supabase-backed sync against the `sync_records` table (see
/// `server/schema.sql`).
class SupabaseSyncAdapter extends RestSyncAdapter {
  SupabaseSyncAdapter({
    required String baseUrl,
    required this.anonKey,
    required super.auth,
    super.http,
  }) : _baseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');

  final String _baseUrl;
  final String anonKey;

  @override
  String get id => 'supabase';

  @override
  String get displayName => 'Supabase';

  Map<String, String> get _extraHeaders => <String, String>{'apikey': anonKey};

  @override
  Future<List<SyncRecord>> fetchRecords(
    SyncScope scope,
    int? sinceRevision,
  ) async {
    final userId = await requireUserId();
    final filters = <String>[
      'select=*',
      'user_id=eq.$userId',
      'scope=eq.${scope.wireId}',
      if (sinceRevision != null) 'revision=gt.$sinceRevision',
      'order=revision.asc',
      'limit=1000',
    ];
    final uri = Uri.parse('$_baseUrl/rest/v1/sync_records?${filters.join('&')}');
    final headers = await authHeadersSync();
    final response = await _guard(() => _http.getJson(uri, headers: headers));
    final rows = response['rows'];
    final source = rows is List ? rows : response['data'] is List
        ? response['data']! as List
        : null;
    if (source == null) return const <SyncRecord>[];
    final records = <SyncRecord>[];
    for (final raw in source) {
      if (raw is! Map) continue;
      final record = _recordFromRow(scope, Map<String, Object?>.from(raw));
      if (record != null) records.add(record);
    }
    return records;
  }

  Future<Map<String, String>> authHeadersSync() async {
    return <String, String>{..._extraHeaders, ...await authHeaders()};
  }

  @override
  Future<Map<String, int>> uploadRecords(
    SyncScope scope,
    List<SyncRecord> records,
  ) async {
    final userId = await requireUserId();
    final body = records
        .map(
          (record) => <String, Object?>{
            'user_id': userId,
            'scope': scope.wireId,
            'record_id': record.recordId,
            'revision': record.revision,
            'updated_at': record.updatedAt.toUtc().toIso8601String(),
            'deleted': record.deleted,
            'payload': record.payload,
          },
        )
        .toList(growable: false);
    final uri = Uri.parse('$_baseUrl/rest/v1/sync_records');
    final headers = await authHeadersSync();
    final decoded = await _guard(
      () => _http.postJsonList(
        uri,
        body,
        headers: <String, String>{
          ...headers,
          'Prefer': 'resolution=merge-duplicates,return=representation',
        },
      ),
    );
    final returned = decoded is List ? decoded : const <Object?>[];
    final revisions = <String, int>{};
    for (final raw in returned) {
      if (raw is! Map) continue;
      final row = Map<String, Object?>.from(raw);
      final recordId = row['record_id']?.toString();
      if (recordId == null) continue;
      revisions[recordId] = row['revision'] is num
          ? (row['revision']! as num).toInt()
          : 0;
    }
    if (revisions.isEmpty) {
      for (final record in records) {
        revisions[record.recordId] = record.revision;
      }
    }
    return revisions;
  }

  static SyncRecord? _recordFromRow(SyncScope scope, Map<String, Object?> row) {
    final recordId = row['record_id']?.toString();
    final updatedAtRaw = row['updated_at']?.toString();
    if (recordId == null || updatedAtRaw == null) return null;
    final updatedAt = DateTime.tryParse(updatedAtRaw);
    if (updatedAt == null) return null;
    final payload = row['payload'];
    return SyncRecord(
      scope: scope,
      recordId: recordId,
      revision: (row['revision'] as num?)?.toInt() ?? 0,
      updatedAt: updatedAt.toUtc(),
      deleted: row['deleted'] == true,
      payload: payload is Map
          ? Map<String, Object?>.from(payload)
          : const <String, Object?>{},
    );
  }
}

// ---------------------------------------------------------------------------
// Self-hosted
// ---------------------------------------------------------------------------

/// Endpoint layout for [SelfHostedSyncAdapter].
class SelfHostedSyncConfig {
  const SelfHostedSyncConfig({
    required this.baseUrl,
    this.pullPath = '/v1/sync/pull',
    this.pushPath = '/v1/sync/push',
    this.mePath = '/v1/sync/me',
    this.apiKey = '',
  });

  final String baseUrl;
  final String pullPath;
  final String pushPath;
  final String mePath;
  final String apiKey;

  Map<String, Object?> toJson() => <String, Object?>{
    'baseUrl': baseUrl,
    'pullPath': pullPath,
    'pushPath': pushPath,
    'mePath': mePath,
    'apiKey': apiKey,
  };

  static SelfHostedSyncConfig fromJson(Map<String, Object?> json) {
    return SelfHostedSyncConfig(
      baseUrl: json['baseUrl']?.toString() ?? '',
      pullPath: json['pullPath']?.toString() ?? '/v1/sync/pull',
      pushPath: json['pushPath']?.toString() ?? '/v1/sync/push',
      mePath: json['mePath']?.toString() ?? '/v1/sync/me',
      apiKey: json['apiKey']?.toString() ?? '',
    );
  }
}

/// Adapter for a self-hosted SpotiFLAC sync server.
class SelfHostedSyncAdapter extends RestSyncAdapter {
  SelfHostedSyncAdapter({
    required this.config,
    required super.auth,
    super.http,
  });

  SelfHostedSyncConfig config;

  @override
  String get id => 'selfhosted';

  @override
  String get displayName => config.baseUrl.isEmpty
      ? 'Self-hosted (not configured)'
      : config.baseUrl;

  String get _base =>
      config.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');

  Map<String, String> get _extraHeaders => config.apiKey.isEmpty
      ? const <String, String>{}
      : <String, String>{'X-Api-Key': config.apiKey};

  @override
  Future<List<SyncRecord>> fetchRecords(
    SyncScope scope,
    int? sinceRevision,
  ) async {
    final response = await postJson(
      Uri.parse('$_base${config.pullPath}'),
      <String, Object?>{
        'scope': scope.wireId,
        'sinceRevision': ?sinceRevision,
      },
      headers: _extraHeaders,
    );
    final records = response['records'];
    if (records is! List) return const <SyncRecord>[];
    final parsed = <SyncRecord>[];
    for (final raw in records) {
      if (raw is! Map) continue;
      final record = SyncRecord.tryParse(Map<String, Object?>.from(raw));
      if (record != null && record.scope == scope) parsed.add(record);
    }
    return parsed;
  }

  @override
  Future<Map<String, int>> uploadRecords(
    SyncScope scope,
    List<SyncRecord> records,
  ) async {
    final response = await postJson(
      Uri.parse('$_base${config.pushPath}'),
      <String, Object?>{
        'scope': scope.wireId,
        'records': records
            .map((record) => record.toJson())
            .toList(growable: false),
      },
      headers: _extraHeaders,
    );
    final raw = response['revisions'];
    final revisions = <String, int>{};
    if (raw is Map) {
      for (final entry in raw.entries) {
        final value = entry.value;
        revisions[entry.key.toString()] = value is num
            ? value.toInt()
            : int.tryParse(value?.toString() ?? '') ?? 0;
      }
    }
    if (revisions.isEmpty) {
      for (final record in records) {
        revisions[record.recordId] = record.revision;
      }
    }
    return revisions;
  }
}
