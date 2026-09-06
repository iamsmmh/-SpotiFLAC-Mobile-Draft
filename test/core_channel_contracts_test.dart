import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/core/data/channel_contracts.dart';

void main() {
  group('CoreChannelNames', () {
    test('matches the bridge channel established with MainActivity', () {
      expect(CoreChannelNames.backend, 'com.zarz.spotiflac/backend');
      expect(
        CoreChannelNames.downloadProgressEvents,
        'com.zarz.spotiflac/download_progress_stream',
      );
    });
  });

  group('method name constants', () {
    test('storage method names match the native handler spellings', () {
      // Locked against MainActivity.kt `when (call.method)` branches and
      // AppDelegate.swift handlers; drift here breaks storage silently.
      expect(StorageChannelMethods.pickSafTree, 'pickSafTree');
      expect(StorageChannelMethods.validateSafTree, 'isSafTreeAccessible');
      expect(StorageChannelMethods.safExists, 'safExists');
      expect(StorageChannelMethods.safDelete, 'safDelete');
      expect(StorageChannelMethods.safStat, 'safStat');
      expect(StorageChannelMethods.safCopyToTemp, 'safCopyToTemp');
      expect(StorageChannelMethods.safCreateFromPath, 'safCreateFromPath');
      expect(StorageChannelMethods.pickIosDirectory, 'pickIosDirectory');
      expect(StorageChannelMethods.createIosBookmark,
          'createIosBookmarkFromPath');
      expect(StorageChannelMethods.startAccessingIosBookmark,
          'startAccessingIosBookmark');
      expect(StorageChannelMethods.stopAccessingIosBookmark,
          'stopAccessingIosBookmark');
    });

    test('download lifecycle names match the native handlers', () {
      expect(DownloadChannelMethods.cancelDownload, 'cancelDownload');
      expect(DownloadChannelMethods.resetDownloadCancel, 'resetDownloadCancel');
      expect(DownloadChannelMethods.clearItemProgress, 'clearItemProgress');
      expect(DownloadChannelMethods.getAllDownloadProgress,
          'getAllDownloadProgress');
      expect(DownloadChannelMethods.startNativeDownloadWorker,
          'startNativeDownloadWorker');
      expect(DownloadChannelMethods.pauseNativeDownloadWorker,
          'pauseNativeDownloadWorker');
      expect(DownloadChannelMethods.resumeNativeDownloadWorker,
          'resumeNativeDownloadWorker');
      expect(DownloadChannelMethods.cancelNativeDownloadWorker,
          'cancelNativeDownloadWorker');
      expect(DownloadChannelMethods.getNativeDownloadWorkerSnapshot,
          'getNativeDownloadWorkerSnapshot');
    });

    test('all storage method names are distinct', () {
      final all = <String>[
        ...StorageChannelMethods.androidSafOps,
        ...StorageChannelMethods.iosSandboxOps,
      ];
      expect(all.toSet(), hasLength(all.length));
    });

    test('all download method names are distinct', () {
      final all = <String>[
        ...DownloadChannelMethods.transferOps,
        ...DownloadChannelMethods.workerLifecycleOps,
      ];
      expect(all.toSet(), hasLength(all.length));
    });
  });

  group('argument builders', () {
    test('SAF ops key their payloads by uri/tree_uri per the Kotlin reads',
        () {
      expect(StorageChannelArgs.safExists('content://x'), <String, Object?>{
        'uri': 'content://x',
      });
      expect(StorageChannelArgs.safDelete('content://x'), <String, Object?>{
        'uri': 'content://x',
      });
      expect(StorageChannelArgs.validateSafTree('content://tree'),
          <String, Object?>{'tree_uri': 'content://tree'});
      expect(
        StorageChannelArgs.safCreateFromPath(
          treeUri: 'content://tree',
          relativeDir: 'Album',
          fileName: 'Song.flac',
          mimeType: 'audio/flac',
          srcPath: '/tmp/song.flac.tmp',
        ),
        <String, Object?>{
          'tree_uri': 'content://tree',
          'relative_dir': 'Album',
          'file_name': 'Song.flac',
          'mime_type': 'audio/flac',
          'src_path': '/tmp/song.flac.tmp',
        },
      );
    });

    test('iOS bookmark ops key by path/bookmark/token per AppDelegate reads',
        () {
      expect(StorageChannelArgs.createIosBookmark('/docs/x'),
          <String, Object?>{'path': '/docs/x'});
      expect(StorageChannelArgs.startAccessingIosBookmark('Ym9va21hcms='),
          <String, Object?>{'bookmark': 'Ym9va21hcms='});
      expect(StorageChannelArgs.stopAccessingIosBookmark('tk'),
          <String, Object?>{'token': 'tk'});
    });

    test('download lifecycle ops key by item_id', () {
      expect(DownloadChannelArgs.cancelDownload('id-1'), <String, Object?>{
        'item_id': 'id-1',
      });
      expect(DownloadChannelArgs.resetDownloadCancel('id-2'),
          <String, Object?>{'item_id': 'id-2'});
      expect(DownloadChannelArgs.clearItemProgress('id-3'),
          <String, Object?>{'item_id': 'id-3'});
    });
  });

  group('SafStatResult.fromMap', () {
    test('round-trips the native safStat shape', () {
      final stat = SafStatResult.fromMap(const <String, Object?>{
        'exists': true,
        'size': 42013000,
        'modified': 1756700000000,
        'mime_type': 'audio/flac',
      });
      expect(stat.exists, isTrue);
      expect(stat.size, 42013000);
      expect(stat.modifiedMillis, 1756700000000);
      expect(stat.mimeType, 'audio/flac');
    });

    test('tolerates numeric width differences and missing mime', () {
      final stat = SafStatResult.fromMap(const <String, Object?>{
        'exists': false,
      });
      expect(stat.exists, isFalse);
      expect(stat.size, 0);
      expect(stat.mimeType, '');
    });

    test('rejects contract drift loudly', () {
      expect(
        () => SafStatResult.fromMap(const <String, Object?>{'exists': 'yes'}),
        throwsFormatException,
      );
    });
  });
}
