import 'dart:io';

import 'package:spotiflac_android/core/data/sha256.dart';
import 'package:spotiflac_android/core/domain/cancellation_token.dart';
import 'package:spotiflac_android/core/domain/entities.dart';
import 'package:spotiflac_android/core/domain/ports.dart';

/// Content sanity gate for the transactional finalize pipeline.
///
/// Detects container families by magic bytes so error payloads (HTML/JSON
/// error pages, empty stubs) can never be committed into the user's library
/// as if they were audio. This is a *plausibility* check, not a codec
/// validation: deep format validation belongs to FFmpeg probe stages.
class AudioMagicSanityChecker implements MetadataSanityChecker {
  const AudioMagicSanityChecker();

  /// Bytes inspected from the head of the file (16 covers RIFF/WAVE's offset
  /// -8 marker and ftyp's offset-4 box type with room to spare).
  static const int probeLength = 16;

  @override
  Future<SanityReport> inspect(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      return const SanityReport.failure(
        sizeBytes: 0,
        reason: 'staged file does not exist',
      );
    }
    final size = await file.length();
    if (size <= 0) {
      return const SanityReport.failure(
        sizeBytes: 0,
        reason: 'staged file is empty',
      );
    }

    final head = <int>[];
    final raf = await file.open();
    try {
      final bytes = await raf.read(probeLength);
      head.addAll(bytes);
    } finally {
      await raf.close();
    }

    final kind = detectAudioContainer(head);
    if (kind == null) {
      return SanityReport.failure(
        sizeBytes: size,
        reason: 'unrecognized container magic (not audio)',
      );
    }
    return SanityReport.ok(kind: kind, sizeBytes: size);
  }
}

/// Pure magic-byte classifier, usable without dart:io. Returns the container
/// kind label (`flac`, `mp3`, `ogg`, `wav`, `m4a`, `aiff`, `ape`, `wv`,
/// `tta`, `dsf`, `webm`) or null when [head] doesn't start with a known
/// audio signature. [head] may be shorter than 16 bytes.
String? detectAudioContainer(List<int> head) {
  bool startsWith(List<int> signature, [int offset = 0]) {
    if (head.length < offset + signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (head[offset + i] != signature[i]) return false;
    }
    return true;
  }

  if (startsWith(const <int>[0x66, 0x4C, 0x61, 0x43])) return 'flac'; // fLaC
  if (startsWith(const <int>[0x49, 0x44, 0x33])) return 'mp3'; // ID3
  if (head.length >= 2 &&
      head[0] == 0xFF &&
      (head[1] & 0xE0) == 0xE0) {
    return 'mp3'; // MPEG frame sync
  }
  if (startsWith(const <int>[0x4F, 0x67, 0x67, 0x53])) return 'ogg'; // OggS
  if (startsWith(const <int>[0x52, 0x49, 0x46, 0x46]) && // RIFF
      startsWith(const <int>[0x57, 0x41, 0x56, 0x45], 8)) {
    return 'wav'; // ....WAVE
  }
  if (startsWith(const <int>[0x66, 0x74, 0x79, 0x70], 4)) return 'm4a'; // ftyp
  if (startsWith(const <int>[0x4D, 0x41, 0x43, 0x20])) return 'ape'; // "MAC "
  if (startsWith(const <int>[0x77, 0x76, 0x70, 0x6B])) return 'wv'; // wvpk
  if (startsWith(const <int>[0x54, 0x54, 0x41, 0x31])) return 'tta'; // TTA1
  if (startsWith(const <int>[0x44, 0x53, 0x44, 0x20])) return 'dsf'; // "DSD "
  if (startsWith(const <int>[0x46, 0x4F, 0x52, 0x4D])) return 'aiff'; // FORM
  if (startsWith(const <int>[0x1A, 0x45, 0xDF, 0xA3])) return 'webm'; // EBML
  return null;
}

/// Streaming SHA-256 verifier for the integrity gate.
class Sha256FileIntegrityVerifier implements IntegrityVerifier {
  const Sha256FileIntegrityVerifier({
    Future<void> Function()? chunkYield,
  }) : _chunkYield = chunkYield;

  /// Optional hook between chunks (tests use it to inject cancellation);
  /// defaults to yielding to the event loop so large files don't starve UI.
  final Future<void> Function()? _chunkYield;

  static const int _chunkSize = 64 * 1024;

  @override
  Future<String> checksumSha256(
    String path,
    CancellationToken cancellation,
  ) async {
    final accumulator = Sha256Accumulator();
    final file = File(path);
    if (!await file.exists()) {
      throw FileSystemException('Cannot checksum missing file', path);
    }
    final raf = await file.open();
    try {
      while (true) {
        cancellation.throwIfCancelled();
        final chunk = await raf.read(_chunkSize);
        if (chunk.isEmpty) break;
        accumulator.add(chunk);
        await (_chunkYield?.call() ?? Future<void>.delayed(Duration.zero));
      }
    } finally {
      await raf.close();
    }
    return accumulator.digestHex();
  }
}
