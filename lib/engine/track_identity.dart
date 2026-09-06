library;
import 'dart:math' as math;

import 'package:spotiflac_android/models/track.dart';

/// Canonical track identity: the key architectural upgrade that turns
/// "Spotify metadata" → "provider metadata" → "download source" → "local FLAC"
/// into a single logical track.
///
/// The rest of the engine never compares raw provider IDs or raw title strings.
/// Everything flows through [TrackIdentityInput] → [CanonicalTrackKey] and gets
/// scored by [TrackIdentityMatcher], so provider A's hit and provider B's hit
/// for the same song collapse to one entry in the library, one download
/// candidate list, and one streaming source ranking.

/// Normalizes free-text metadata for matching.
///
/// Rules are deliberately conservative: the goal is to recognize the same song
/// written differently, not to guess what an unknown string means. Removing
/// punctuation, case, diacritics, whitespace and "(remastered ...)"/"(Live ...)"
/// parentheticals covers the vast majority of real-world metadata drift while
/// keeping "Night" and "Nights" distinct (title-only fuzzy scoring handles the
/// remaining noise).
class TrackTextNormalizer {
  const TrackTextNormalizer._();

  static final RegExp _parenthetical = RegExp(r'\([^)]*\)|\[[^\]]*\]');
  static final RegExp _nonAlnum = RegExp(r'[^a-z0-9]+');
  static final RegExp _collapse = RegExp(r'\s+');

  /// Lowercases, strips diacritics and parentheticals, and collapses
  /// punctuation into single spaces.
  static String normalize(String? value) {
    final source = (value ?? '').trim().toLowerCase();
    if (source.isEmpty) return '';

    var out = source.replaceAll(_parenthetical, ' ').trim();
    if (out.isEmpty) out = source;

    // Strip combining marks before non-alphanumeric passes so "Café" and
    // "Cafe" collide as intended.
    out = _stripDiacritics(out);
    out = out.replaceAll(_nonAlnum, ' ').trim();
    out = out.replaceAll(_collapse, ' ');
    // Common filler that adds no match signal ("the" at the start of a title
    // only matters when everything else is equal; removing it is what makes
    // "The Chain" == "Chain" work).
    if (out.startsWith('the ')) out = out.substring(4);
    return out;
  }

  /// Removes diacritical marks without pulling in the ICU tables: precomposed
  /// Latin characters (é, ñ, ł, ř, ...) are transliterated to their base
  /// letters and combining marks are dropped.
  static String _stripDiacritics(String input) {
    final buffer = StringBuffer();
    for (final rune in input.runes) {
      if (_isCombiningMark(rune)) continue;
      final composed = _precomposedBase(rune);
      if (composed != null) {
        buffer.write(composed);
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  /// Transliterates a single precomposed Latin code point to its base letters,
  /// or null when the code point needs no transliteration.
  static String? _precomposedBase(int rune) {
    if (rune < 0x00C0 || rune > 0x017F) return null;
    return _precomposedLatin[rune];
  }

  /// Small, dependency-free combining-mark table covering Latin/Greek/Cyrillic
  /// supplement ranges (U+0300–U+036F). Keeps the engine free of a package
  /// dependency; returns false for anything outside that plane.
  static bool _isCombiningMark(int rune) =>
      rune >= 0x0300 && rune <= 0x036F;

  /// Precomposed Latin characters (Latin-1 + Latin Extended-A) → base letters.
  /// Kept as an explicit table so the engine stays dependency-free and
  /// deterministic; covers every diacritic that commonly appears in track
  /// titles across EN/DE/FR/ES/PT/PL/CZ/TR/SE/NO/IS/FI.
  static const Map<int, String> _precomposedLatin = {
    0x00C0: 'A', 0x00C1: 'A', 0x00C2: 'A', 0x00C3: 'A', 0x00C4: 'A',
    0x00C5: 'A', 0x00C6: 'AE', 0x00C7: 'C', 0x00C8: 'E', 0x00C9: 'E',
    0x00CA: 'E', 0x00CB: 'E', 0x00CC: 'I', 0x00CD: 'I', 0x00CE: 'I',
    0x00CF: 'I', 0x00D0: 'D', 0x00D1: 'N', 0x00D2: 'O', 0x00D3: 'O',
    0x00D4: 'O', 0x00D5: 'O', 0x00D6: 'O', 0x00D8: 'O', 0x00D9: 'U',
    0x00DA: 'U', 0x00DB: 'U', 0x00DC: 'U', 0x00DD: 'Y', 0x00DE: 'TH',
    0x00DF: 'SS', 0x00E0: 'a', 0x00E1: 'a', 0x00E2: 'a', 0x00E3: 'a',
    0x00E4: 'a', 0x00E5: 'a', 0x00E6: 'ae', 0x00E7: 'c', 0x00E8: 'e',
    0x00E9: 'e', 0x00EA: 'e', 0x00EB: 'e', 0x00EC: 'i', 0x00ED: 'i',
    0x00EE: 'i', 0x00EF: 'i', 0x00F0: 'd', 0x00F1: 'n', 0x00F2: 'o',
    0x00F3: 'o', 0x00F4: 'o', 0x00F5: 'o', 0x00F6: 'o', 0x00F8: 'o',
    0x00F9: 'u', 0x00FA: 'u', 0x00FB: 'u', 0x00FC: 'u', 0x00FD: 'y',
    0x00FE: 'th', 0x00FF: 'y', 0x0100: 'A', 0x0101: 'a', 0x0102: 'A',
    0x0103: 'a', 0x0104: 'A', 0x0105: 'a', 0x0106: 'C', 0x0107: 'c',
    0x010C: 'C', 0x010D: 'c', 0x010E: 'D', 0x010F: 'd', 0x0110: 'D',
    0x0111: 'd', 0x0112: 'E', 0x0113: 'e', 0x0118: 'E', 0x0119: 'e',
    0x011A: 'E', 0x011B: 'e', 0x011E: 'G', 0x011F: 'g', 0x0122: 'G',
    0x0123: 'g', 0x012A: 'I', 0x012B: 'i', 0x012E: 'I', 0x012F: 'i',
    0x0136: 'K', 0x0137: 'k', 0x0139: 'L', 0x013A: 'l', 0x013D: 'L',
    0x013E: 'l', 0x0141: 'L', 0x0142: 'l', 0x0143: 'N', 0x0144: 'n',
    0x0145: 'N', 0x0146: 'n', 0x0147: 'N', 0x0148: 'n', 0x014C: 'O',
    0x014D: 'o', 0x0150: 'O', 0x0151: 'o', 0x0154: 'R', 0x0155: 'r',
    0x0158: 'R', 0x0159: 'r', 0x015A: 'S', 0x015B: 's', 0x015E: 'S',
    0x015F: 's', 0x0160: 'S', 0x0161: 's', 0x0162: 'T', 0x0163: 't',
    0x0164: 'T', 0x0165: 't', 0x016A: 'U', 0x016B: 'u', 0x016E: 'U',
    0x016F: 'u', 0x0170: 'U', 0x0171: 'u', 0x0172: 'U', 0x0173: 'u',
    0x0179: 'Z', 0x017A: 'z', 0x017B: 'Z', 0x017C: 'z', 0x017D: 'Z',
    0x017E: 'z',
  };
}

/// Normalized string similarity (0..1) used by the fuzzy match scores.
///
/// Uses a bounded Damerau-Levenshtein distance (substitutions, insertions,
/// deletions, and adjacent transpositions — "Gafla" vs "Galfa") normalized by
/// the longest input. Long strings stop early once the edit distance exceeds
/// the threshold so a 200-character metadata blob cannot burn real time.
class StringSimilarity {
  const StringSimilarity._();

  static double similarity(String a, String b) {
    final na = TrackTextNormalizer.normalize(a);
    final nb = TrackTextNormalizer.normalize(b);
    if (na.isEmpty || nb.isEmpty) return 0;
    if (na == nb) return 1;
    final distance = _editDistance(na, nb);
    final longest = math.max(na.length, nb.length);
    if (longest == 0) return 1;
    return (1 - (distance / longest)).clamp(0.0, 1.0);
  }

  static int _editDistance(String a, String b) {
    final m = a.length;
    final n = b.length;
    if (m == 0) return n;
    if (n == 0) return m;
    // Distance can never exceed 2/3 of the longer string before similarity
    // drops below the meaningful threshold; bail out early on very long
    // strings (metadata blobs, multi-line comments).
    final limit = math.min(12, math.max(3, (math.max(m, n) * 0.5).floor()));
    // Optimal string alignment (Damerau) distance. `oneBack` holds row i-1
    // and `twoBack` row i-2; the transposition rule must consult the cell
    // d[i-2][j-2] (two rows up), not d[i-1][j-2], otherwise adjacent swaps
    // are never credited and the distance is overestimated.
    var oneBack = List<int>.generate(n + 1, (i) => i);
    var twoBack = List<int>.filled(n + 1, 0);
    for (var i = 1; i <= m; i++) {
      final current = List<int>.filled(n + 1, 0);
      current[0] = i;
      var rowMin = current[0];
      for (var j = 1; j <= n; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        current[j] = math.min(
          math.min(current[j - 1] + 1, oneBack[j] + 1),
          oneBack[j - 1] + cost,
        );
        if (j > 1 &&
            i > 1 &&
            a.codeUnitAt(i - 1) == b.codeUnitAt(j - 2) &&
            a.codeUnitAt(i - 2) == b.codeUnitAt(j - 1)) {
          current[j] = math.min(current[j], twoBack[j - 2] + 1);
        }
        rowMin = math.min(rowMin, current[j]);
      }
      if (rowMin > limit) return math.max(m, n);
      twoBack = oneBack;
      oneBack = current;
    }
    return oneBack[n];
  }
}

/// Identity payload extracted from any track-shaped object (provider search
/// result, download-history row, local-library row).
class TrackIdentityInput {
  final String title;
  final String artist;
  final String album;
  final String? albumArtist;
  final String? isrc;
  final int durationSeconds;
  final String? releaseDate;
  final Map<String, String> providerIds;

  const TrackIdentityInput({
    required this.title,
    required this.artist,
    this.album = '',
    this.albumArtist,
    this.isrc,
    this.durationSeconds = 0,
    this.releaseDate,
    this.providerIds = const {},
  });

  factory TrackIdentityInput.fromTrack(Track track) => TrackIdentityInput(
    title: track.name,
    artist: track.artistName,
    album: track.albumName,
    albumArtist: track.albumArtist,
    isrc: track.isrc,
    durationSeconds: track.duration,
    releaseDate: track.releaseDate,
    providerIds: {
      if (track.id.isNotEmpty) track.source ?? 'app': track.id,
      if (track.deezerId != null && track.deezerId!.isNotEmpty)
        'deezer': track.deezerId!,
    },
  );

  String get normalizedTitle => TrackTextNormalizer.normalize(title);
  String get normalizedArtist => TrackTextNormalizer.normalize(artist);

  /// The strongest unique identifier available. ISRCs are globally unique per
  /// recording and are what the streaming/download providers key on when they
  /// expose them.
  String? get strongestId {
    final normalizedIsrc = TrackTextNormalizer.normalize(isrc);
    if (normalizedIsrc.isNotEmpty && normalizedIsrc.length >= 8) {
      return 'isrc:$normalizedIsrc';
    }
    return null;
  }
}

/// Deterministic, process-stable hash (FNV-1a) used for canonical stable ids.
/// Dart's `hashCode` is randomized per process and cannot be persisted, and
/// Dart `int` is 64-bit signed on the VM — so we fold two 32-bit FNV-1a runs
/// (one over the code units, one over a rotated view) into a 16-hex string.
class StableHasher {
  const StableHasher._();

  static const int _fnvPrime = 0x01000193;
  static const int _fnvOffset = 0x811C9DC5;
  static const int _mask = 0xFFFFFFFF;

  static String fnv1a(String input) {
    var hashA = _fnvOffset;
    var hashB = _fnvOffset;
    for (final codeUnit in input.codeUnits) {
      hashA = ((hashA ^ codeUnit) * _fnvPrime) & _mask;
      hashB = ((hashB ^ (codeUnit + 0x1F)) * _fnvPrime) & _mask;
    }
    return hashA.toRadixString(16).padLeft(8, '0') +
        hashB.toRadixString(16).padLeft(8, '0');
  }
}

/// Canonical key for one logical track.
///
/// [matchKey] is the primary lookup key (ISRC when present, otherwise a
/// normalized title+artist fingerprint). [providerIds] keep every known
/// provider identity reachable from the canonical record so a later source can
/// be resolved without a fresh search.
class CanonicalTrackKey {
  final String stableId;
  final String? isrc;
  final String normalizedTitle;
  final String normalizedArtist;
  final String normalizedAlbum;
  final int durationSeconds;
  final String? releaseYear;
  final Map<String, String> providerIds;

  const CanonicalTrackKey({
    required this.stableId,
    this.isrc,
    required this.normalizedTitle,
    required this.normalizedArtist,
    this.normalizedAlbum = '',
    this.durationSeconds = 0,
    this.releaseYear,
    this.providerIds = const {},
  });

  factory CanonicalTrackKey.fromInput(TrackIdentityInput input) =>
      CanonicalTrackKey.fromFingerprint(input, variant: null);

  /// Builds a key whose stable id is derived from the same fingerprint but is
  /// disambiguated by [variant] (e.g. a collision suffix). Used by the index
  /// when two fuzzy-identical inputs actually resolve to different tracks.
  factory CanonicalTrackKey.fromFingerprint(
    TrackIdentityInput input, {
    String? variant,
  }) {
    final isrc = TrackTextNormalizer.normalize(input.isrc);
    final title = input.normalizedTitle;
    final artist = input.normalizedArtist;
    final year = _yearOf(input.releaseDate);

    final fingerprint = isrc.isNotEmpty
        ? 'isrc:$isrc'
        : 'ttl:$title|$artist|${_durationBucket(input.durationSeconds)}';
    final stableId = variant == null || variant.isEmpty
        ? StableHasher.fnv1a(fingerprint)
        : '${StableHasher.fnv1a(fingerprint)}-$variant';
    return CanonicalTrackKey(
      stableId: stableId,
      isrc: isrc.isNotEmpty ? isrc : null,
      normalizedTitle: title,
      normalizedArtist: artist,
      normalizedAlbum: TrackTextNormalizer.normalize(input.album),
      durationSeconds: input.durationSeconds,
      releaseYear: year,
      providerIds: Map.unmodifiable(input.providerIds),
    );
  }

  static String? _yearOf(String? releaseDate) {
    if (releaseDate == null) return null;
    final match = RegExp(r'(19|20)\d{2}').firstMatch(releaseDate);
    return match?.group(0);
  }

  /// Rounds durations to a 5s bucket so a 3:41 vs 3:42 provider mismatch still
  /// matches, while 3:41 vs 4:20 clearly does not.
  static String _durationBucket(int seconds) =>
      seconds <= 0 ? 'unknown' : '${(seconds / 5).round()}';

  @override
  bool operator ==(Object other) =>
      other is CanonicalTrackKey && other.stableId == stableId;

  @override
  int get hashCode => stableId.hashCode;
}

/// Component-wise match result used by the UI (similarity explanations,
/// "potential duplicate" review).
class TrackMatchScore {
  final double isrc;
  final double providerId;
  final double title;
  final double artist;
  final double album;
  final double duration;
  final double year;

  const TrackMatchScore({
    required this.isrc,
    required this.providerId,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.year,
  });

  /// Weighted overall score in 0..1.
  double get overall {
    final scored =
        (isrc * 0.40) +
        (providerId * 0.10) +
        (title * 0.22) +
        (artist * 0.12) +
        (album * 0.08) +
        (duration * 0.05) +
        (year * 0.03);
    return scored.clamp(0.0, 1.0);
  }

  bool get isExactMatch => isrc >= 0.999 && title >= 0.8 && artist >= 0.8;

  bool get likelyDuplicate => overall >= 0.78 || (isrc >= 0.999);

  String describe() {
    final parts = <String>[
      if (isrc >= 0.999) 'exact ISRC',
      if (providerId >= 0.999) 'shared provider id',
      if (title >= 0.9) 'same title',
      if (artist >= 0.9) 'same artist',
      if (album >= 0.9) 'same album',
      if (duration >= 0.9) 'same duration',
    ];
    return parts.isEmpty ? 'weak similarity' : parts.join(' · ');
  }
}

/// Pure matcher: no I/O, no network, no state. Everything the engine needs to
/// decide "is this the same track" lives here so it is trivially unit-testable.
class TrackIdentityMatcher {
  const TrackIdentityMatcher();

  static const double exactTieBreak = 1.0;

  TrackMatchScore score(
    TrackIdentityInput a,
    TrackIdentityInput b, {
    bool sameProviderId = false,
  }) {
    final isrcA = TrackTextNormalizer.normalize(a.isrc);
    final isrcB = TrackTextNormalizer.normalize(b.isrc);
    final isrc =
        isrcA.isNotEmpty && isrcA == isrcB ? exactTieBreak : 0.0;

    final providerId = sameProviderId ? exactTieBreak : 0.0;

    final title = StringSimilarity.similarity(a.title, b.title);
    final artist = StringSimilarity.similarity(a.artist, b.artist);
    final album = StringSimilarity.similarity(a.album, b.album);

    final duration =
        a.durationSeconds <= 0 || b.durationSeconds <= 0
            ? 0.5 // unknown duration is neutral, not a mismatch
            : (_within(a.durationSeconds, b.durationSeconds, 8)
                  ? exactTieBreak
                  : _within(a.durationSeconds, b.durationSeconds, 20)
                  ? 0.7
                  : 0.0);

    final year = _sameYear(a.releaseDate, b.releaseDate)
        ? exactTieBreak
        : (a.releaseDate == null || b.releaseDate == null ? 0.5 : 0.0);

    return TrackMatchScore(
      isrc: isrc,
      providerId: providerId,
      title: title,
      artist: artist,
      album: album,
      duration: duration,
      year: year,
    );
  }

  /// Two records represent the same logical track.
  bool isSameTrack(
    TrackIdentityInput a,
    TrackIdentityInput b, {
    bool sameProviderId = false,
  }) {
    final isrcA = TrackTextNormalizer.normalize(a.isrc);
    final isrcB = TrackTextNormalizer.normalize(b.isrc);
    if (isrcA.isNotEmpty && isrcA == isrcB) return true;

    final normalizedTitleA = a.normalizedTitle;
    final normalizedTitleB = b.normalizedTitle;
    if (normalizedTitleA.isEmpty || normalizedTitleB.isEmpty) return false;

    // Title + artist fuzzy match with hard duration guard: "Karma" by Taylor
    // Swift and "Karma" by someone else must never collapse.
    final titleOk =
        normalizedTitleA == normalizedTitleB ||
        StringSimilarity.similarity(a.title, b.title) >= 0.92;
    final artistOk =
        StringSimilarity.similarity(a.artist, b.artist) >= 0.85;
    if (!titleOk || !artistOk) return false;

    final durationOk =
        a.durationSeconds <= 0 ||
        b.durationSeconds <= 0 ||
        _within(a.durationSeconds, b.durationSeconds, 20);
    if (!durationOk) return false;

    // Album mismatch on a near-identical title+artist is usually a different
    // live/remaster edition; treat it as a match only when both sides actually
    // know the album and disagree strongly.
    if (a.album.isNotEmpty && b.album.isNotEmpty) {
      final albumScore = StringSimilarity.similarity(a.album, b.album);
      if (albumScore < 0.35) return false;
    }
    return true;
  }

  static bool _within(int a, int b, int toleranceSeconds) =>
      (a - b).abs() <= toleranceSeconds;

  static bool _sameYear(String? a, String? b) {
    final ya = CanonicalTrackKey._yearOf(a);
    final yb = CanonicalTrackKey._yearOf(b);
    if (ya == null || yb == null) return false;
    return ya == yb;
  }
}

/// Groups identity inputs by canonical key, collapsing exact matches and
/// attaching a signature for near-duplicate detection.
class TrackIdentityIndex {
  final Map<String, CanonicalTrackKey> _byStableId = {};
  final Map<String, List<TrackIdentityInput>> _members = {};
  final Map<String, int> _siblingCounts = {};
  final TrackIdentityMatcher matcher;

  TrackIdentityIndex({TrackIdentityMatcher? matcher})
    : matcher = matcher ?? const TrackIdentityMatcher();

  String _siblingSerial(String parentStableId) {
    final count = _siblingCounts[parentStableId] ?? 0;
    return count.toRadixString(16);
  }

  int get length => _members.length;

  List<TrackIdentityInput> membersOf(CanonicalTrackKey key) =>
      List.unmodifiable(_members[key.stableId] ?? const []);

  /// Inserts [input] under its canonical key. Returns the key of the existing
  /// group when the input matched and was merged, or a new key otherwise.
  CanonicalTrackKey insert(TrackIdentityInput input) {
    final key = CanonicalTrackKey.fromInput(input);
    final existing = _byStableId[key.stableId];
    if (existing == null) {
      _byStableId[key.stableId] = key;
      _members[key.stableId] = [input];
      return key;
    }
    final members = _members[key.stableId]!;
    if (!members.any((member) => matcher.isSameTrack(member, input))) {
      // ISRC collision is authoritative; fuzzy collision is not — create a
      // sibling group only when no existing member really matches.
      if (!_hasStrongIsrcMatch(input, members)) {
        final sibling = CanonicalTrackKey.fromFingerprint(
          TrackIdentityInput(
            title: input.title,
            artist: input.artist,
            album: input.album,
            albumArtist: input.albumArtist,
            isrc: input.isrc,
            durationSeconds: input.durationSeconds,
            releaseDate: input.releaseDate,
            providerIds: input.providerIds,
          ),
          // Different tracks can share title/artist/duration (live takes,
          // covers, remixes). The variant suffix keeps the stable id unique so
          // the sibling group is reachable through its own composite key.
          variant: 's${_siblingSerial(key.stableId)}',
        );
        _byStableId[sibling.stableId] = sibling;
        _members[sibling.stableId] = [input];
        _siblingCounts[key.stableId] =
            (_siblingCounts[key.stableId] ?? 0) + 1;
        return sibling;
      }
    }
    members.add(input);
    return existing;
  }

  bool _hasStrongIsrcMatch(
    TrackIdentityInput candidate,
    List<TrackIdentityInput> members,
  ) {
    final candidateIsrc = TrackTextNormalizer.normalize(candidate.isrc);
    if (candidateIsrc.isEmpty) return false;
    for (final member in members) {
      if (TrackTextNormalizer.normalize(member.isrc) == candidateIsrc) {
        return true;
      }
    }
    return false;
  }

  /// All canonical groups, stable-id ordered for deterministic iteration.
  List<CanonicalTrackKey> get keys =>
      _byStableId.keys.map((id) => _byStableId[id]!).toList(growable: false);
}
