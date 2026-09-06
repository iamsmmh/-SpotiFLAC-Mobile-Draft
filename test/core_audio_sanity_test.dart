import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/core/data/audio_sanity.dart';
import 'package:spotiflac_android/core/data/sha256.dart';
import 'package:spotiflac_android/core/domain/cancellation_token.dart';

void main() {
  group('detectAudioContainer magic-byte matrix', () {
    test('detects every supported container family', () {
      expect(detectAudioContainer(utf8.encode('fLaC++++')), 'flac');
      expect(detectAudioContainer(utf8.encode('ID3\x04\x00')), 'mp3');
      expect(
        detectAudioContainer(const <int>[0xFF, 0xFB, 0x90, 0x00]),
        'mp3',
        reason: 'MPEG frame sync at the head must classify as mp3',
      );
      expect(detectAudioContainer(utf8.encode('OggS0000')), 'ogg');
      expect(
        detectAudioContainer(utf8.encode('RIFF\x00\x00\x00\x00WAVE')),
        'wav',
      );
      expect(
        detectAudioContainer(
          const <int>[0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41],
        ),
        'm4a',
        reason: 'ftyp box type sits at offset 4',
      );
      expect(detectAudioContainer(utf8.encode('MAC ')), 'ape');
      expect(detectAudioContainer(utf8.encode('wvpk')), 'wv');
      expect(detectAudioContainer(utf8.encode('TTA1')), 'tta');
      expect(detectAudioContainer(utf8.encode('DSD ')), 'dsf');
      expect(detectAudioContainer(utf8.encode('FORM')), 'aiff');
    });

    test('rejects non-audio payloads', () {
      expect(detectAudioContainer(utf8.encode('<html><body>')), isNull);
      expect(detectAudioContainer(utf8.encode('{"error":true}')), isNull);
      expect(detectAudioContainer(utf8.encode('PK\x03\x04')), isNull);
      expect(detectAudioContainer(const <int>[]), isNull);
      expect(detectAudioContainer(const <int>[0xFF]), isNull);
    });

    test('does not detect RIFF without the WAVE form type', () {
      expect(detectAudioContainer(utf8.encode('RIFF\x00\x00\x00\x00AVI ')),
          isNull);
    });
  });

  group('AudioMagicSanityChecker.inspect', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('core_sanity_test');
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('passes a plausible audio file and reports its size', () async {
      final file = File('${root.path}/ok.flac');
      await file.writeAsBytes(
        List<int>.from(utf8.encode('fLaC'))..addAll(List.filled(100, 0xAB)),
      );
      final report = await const AudioMagicSanityChecker().inspect(file.path);
      expect(report.ok, isTrue);
      expect(report.kind, 'flac');
      expect(report.sizeBytes, 104);
    });

    test('fails missing, empty, and non-audio files', () async {
      const checker = AudioMagicSanityChecker();

      final missing = await checker.inspect('${root.path}/ghost.flac');
      expect(missing.ok, isFalse);

      final empty = File('${root.path}/empty.flac');
      await empty.create();
      final emptyReport = await checker.inspect(empty.path);
      expect(emptyReport.ok, isFalse);
      expect(emptyReport.reason, contains('empty'));

      final html = File('${root.path}/error.flac');
      await html.writeAsString('<html>429 Too Many Requests</html>');
      final htmlReport = await checker.inspect(html.path);
      expect(htmlReport.ok, isFalse);
      expect(htmlReport.reason, contains('magic'));
    });
  });

  group('Sha256FileIntegrityVerifier', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('core_verify_test');
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('streams a file and matches the one-shot digest', () async {
      final bytes = List<int>.generate(
        200000, // spans three 64 KiB chunks
        (i) => (i * 7 + 3) & 0xFF,
      );
      final file = File('${root.path}/big.bin');
      await file.writeAsBytes(bytes);

      final source = CancellationTokenSource();
      final digest = await const Sha256FileIntegrityVerifier()
          .checksumSha256(file.path, source.token);
      expect(digest, sha256Hex(bytes));
    });

    test('honours cancellation between chunks', () async {
      final bytes = List<int>.filled(200000, 0x42);
      final file = File('${root.path}/big.bin');
      await file.writeAsBytes(bytes);

      final source = CancellationTokenSource();
      // Inject cancellation after the first chunk through the yield hook.
      var yields = 0;
      final verifier = Sha256FileIntegrityVerifier(
        chunkYield: () async {
          yields++;
          if (yields >= 1) source.cancel('user');
        },
      );
      await expectLater(
        verifier.checksumSha256(file.path, source.token),
        throwsA(isA<JobCancelledException>()),
      );
    });

    test('throws a FileSystemException for missing files', () async {
      final source = CancellationTokenSource();
      expect(
        const Sha256FileIntegrityVerifier()
            .checksumSha256('${root.path}/ghost.bin', source.token),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
