import 'dart:async';

import 'package:flutter/services.dart';

import 'package:spotiflac_android/core/data/extension_payload.dart';
import 'package:spotiflac_android/core/domain/cancellation_token.dart';
import 'package:spotiflac_android/core/domain/core_errors.dart';
import 'package:spotiflac_android/core/domain/entities.dart';
import 'package:spotiflac_android/core/domain/ports.dart';
import 'package:spotiflac_android/services/download_request_payload.dart';
import 'package:spotiflac_android/services/platform_bridge.dart';

/// Builds the native download request for one job. The composition root
/// (presentation layer) owns payload construction because it needs settings,
/// extension flags, and track metadata — the adapter owns transport and
/// normalization.
typedef BridgePayloadBuilder =
    FutureOr<DownloadRequestPayload> Function(QueueJob job, String tempPath);

/// [DownloadBackend] over the gomobile bridge (`downloadByStrategy`).
///
/// Responsibilities of THIS class (and nothing else):
///  - reset the native cancel latch, invoke the backend, decode the result
///  - normalize every failure shape (`error_type` strings, PlatformException
///    codes) into [CoreError] before it crosses into the application layer
///  - imperative abort wiring: [abort] cancels the platform transfer behind a
///    job id synchronously (fire-and-forget), driven from the job's
///    cancellation token listener in the engine composition
///
/// Payload encoding stays in the injected [BridgePayloadBuilder]; transaction
/// staging/commit stays in the DownloadManager + StorageRepository. This
/// adapter never writes to the final destination directly — the backend
/// writes to a staged target the payload builder derives from `tempPath`.
class BridgeDownloadBackend implements DownloadBackend {
  BridgeDownloadBackend({
    required BridgePayloadBuilder payloadBuilder,
    this.useExtensions = true,
    this.useFallback = true,
  }) : _payloadBuilder = payloadBuilder;

  final BridgePayloadBuilder _payloadBuilder;
  final bool useExtensions;
  final bool useFallback;

  @override
  void abort(String jobId) {
    // Fire-and-forget by contract: the invoke itself is cheap and the native
    // side flips a latch the transfer observes on its next read/write cycle.
    unawaited(
      PlatformBridge.cancelDownload(jobId).then<void>(
        (_) {},
        onError: (Object _) {},
      ),
    );
  }

  @override
  Future<DownloadTaskResult> download(DownloadTask task) async {
    final token = task.cancellation;
    token.throwIfCancelled(jobId: task.job.id);

    // A stale native cancel latch from a previous attempt must not veto this
    // run before it starts.
    try {
      await PlatformBridge.resetDownloadCancel(task.job.id);
    } catch (_) {
      // Non-fatal: the latch only matters when abort() was actually called.
    }
    token.throwIfCancelled(jobId: task.job.id);

    Map<String, dynamic> response;
    try {
      final payload = await _payloadBuilder(task.job, task.tempPath);
      token.throwIfCancelled(jobId: task.job.id);
      response = await PlatformBridge.downloadByStrategy(
        payload: payload,
        useExtensions: useExtensions,
        useFallback: useFallback,
      );
    } on JobCancelledException {
      rethrow;
    } on PlatformException catch (error) {
      return DownloadTaskResult.failure(
        normalizePlatformException(
          error,
          contextMessage: 'Download channel error (${error.code})',
        ),
      );
    } catch (error) {
      return DownloadTaskResult.failure(
        normalizeCoreError(
          error,
          fallback: CoreErrorCategory.network,
          fallbackMessage: 'Download invocation failed: $error',
        ),
      );
    }

    token.throwIfCancelled(jobId: task.job.id);
    if (response['success'] == true) {
      return const DownloadTaskResult.success();
    }
    final Object? rawError = response['error'] ?? response['message'];
    final errorMessage = rawError?.toString();
    return DownloadTaskResult.failure(
      CoreError(
        category: coreCategoryForBackendError(
          errorType: response['error_type'],
          errorMessage: errorMessage,
        ),
        message: errorMessage ?? 'Download failed',
      ),
    );
  }
}
