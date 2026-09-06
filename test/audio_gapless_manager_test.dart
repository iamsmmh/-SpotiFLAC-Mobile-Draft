import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/audio/gapless_manager.dart';
import 'package:spotiflac_android/engine/audio_characteristics.dart';
import 'package:spotiflac_android/engine/gapless_policy.dart';

class _Item implements GaplessQueueItem {
  const _Item(
    this.id, {
    this.album = 'album',
    this.characteristics = _flac,
    this.isRemote = false,
  });

  @override
  final String id;
  @override
  final String album;
  @override
  final AudioCharacteristics characteristics;
  @override
  final bool isRemote;

  static const AudioCharacteristics _flac = AudioCharacteristics(
    codec: 'FLAC',
    sampleRateHz: 44100,
    bitDepth: 16,
    channels: 2,
    lossless: true,
  );
  static const AudioCharacteristics _mp3 = AudioCharacteristics(
    codec: 'MP3',
    bitrateKbps: 320,
  );
}

void main() {
  group('GaplessManager.albumRuns', () {
    test('groups consecutive same-album same-transport items', () {
      final runs = GaplessManager.albumRuns([
        const _Item('a1', album: 'X'),
        const _Item('a2', album: 'X'),
        const _Item('a3', album: 'Y'),
        const _Item('a4', album: 'Y'),
        const _Item('a5', album: 'Y', isRemote: true),
      ]);
      expect(runs.length, 2);
      expect(runs[0].startIndex, 0);
      expect(runs[0].endIndex, 2);
      expect(runs[1].startIndex, 2);
      expect(runs[1].endIndex, 4);
    });

    test('single-item albums form no run', () {
      final runs = GaplessManager.albumRuns([
        const _Item('a1', album: 'X'),
        const _Item('a2', album: 'Y'),
      ]);
      expect(runs, isEmpty);
    });

    test('an empty queue produces no runs', () {
      expect(GaplessManager.albumRuns(const <_Item>[]), isEmpty);
    });
  });

  group('GaplessManager.planQueue', () {
    test('marks same-album transitions inside runs', () {
      final manager = GaplessManager()..configure(enabled: true);
      final transitions = manager.planQueue([
        const _Item('a1', album: 'X'),
        const _Item('a2', album: 'X'),
        const _Item('a3', album: 'Y'),
      ]);
      expect(transitions.length, 2);
      expect(transitions[0].sameAlbum, isTrue);
      expect(transitions[1].sameAlbum, isFalse);
      // Two splicable FLACs → seamless.
      expect(transitions[0].decision.kind, GaplessTransitionKind.seamless);
    });

    test('local → stream hops never splice', () {
      final manager = GaplessManager()..configure(enabled: true);
      final transitions = manager.planQueue([
        const _Item('a1'),
        const _Item('a2', isRemote: true),
      ]);
      expect(transitions.single.decision.kind, GaplessTransitionKind.prebuffer);
    });

    test('disabled master switch disables every transition', () {
      final manager = GaplessManager()..configure(enabled: false);
      final transitions = manager.planQueue([
        const _Item('a1'),
        const _Item('a2'),
      ]);
      expect(transitions.single.decision, GaplessDecision.disabled);
    });

    test('repeat-one disables the transition too', () {
      final manager = GaplessManager()..configure(enabled: true);
      final transitions = manager.planQueue(
        [const _Item('a1'), const _Item('a2')],
        repeatOne: true,
      );
      expect(transitions.single.decision, GaplessDecision.disabled);
    });
  });

  group('GaplessManager stats', () {
    test('records decisions per live transition', () {
      final manager = GaplessManager()..configure(enabled: true);
      manager.decideNext(current: const _Item('a'), next: const _Item('b'), sameAlbum: true);
      manager.decideNext(
        current: const _Item('a', characteristics: _Item._mp3),
        next: const _Item('b'),
        sameAlbum: false,
      );
      manager.configure(enabled: false);
      manager.decideNext(current: const _Item('a'), next: const _Item('b'), sameAlbum: false);
      expect(manager.stats.seamless, 1);
      expect(manager.stats.prebuffered, 1);
      expect(manager.stats.skipped, 1);
      expect(manager.stats.total, 3);
    });

    test('resetStats clears counters', () {
      final manager = GaplessManager()..configure(enabled: true);
      manager.decideNext(current: const _Item('a'), next: const _Item('b'), sameAlbum: true);
      manager.resetStats();
      expect(manager.stats.total, 0);
    });
  });
}
