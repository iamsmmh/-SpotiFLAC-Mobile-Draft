import 'dart:async';

import 'package:flutter/services.dart';

import 'package:spotiflac_android/core/data/extension_payload.dart';
import 'package:spotiflac_android/core/domain/cancellation_token.dart';
import 'package:spotiflac_android/core/domain/core_errors.dart';
import 'package:spotiflac_android/core/domain/entities.dart';
import 'package:spotiflac_android/core/domain/ports.dart';

/// Transport for one provider invocation against the native extension runtime.
/// The bridge-side pieces (gomobile FFI, JS sandbox, request sequencing) stay
/// behind this closure so the driver layer stays unit-testable.
typedef ExtensionInvokeFn =
    Future<Map<String, Object?>> Function(ExtensionRequest request);

/// Optional synchronous abort hook: fires when the per-call cancellation
/// token is cancelled (wired to `cancelExtensionRequest` on the native side
/// by the composition root).
typedef ExtensionAbortFn = void Function();

/// [ExtensionDriver] that binds one dynamic provider (extension) to the
/// native runtime.
///
/// Isolation contract:
///  - every object thrown by [invoker] is normalized to [CoreError] with
///    [providerId] attribution — JS exceptions, gomobile boundary errors, and
///    channel failures all land in the same taxonomy
///  - payload maps are copied defensively (`Map<String, Object?>.from`) so a
///    provider mutating its own buffer later can't corrupt engine state
///  - typed extraction helpers ([ExtensionPayloadDecoder]) turn malformed
///    payloads into [CoreErrorCategory.format] provider failures
class GomobileExtensionDriver implements ExtensionDriver {
  GomobileExtensionDriver({
    required this.providerId,
    required ExtensionInvokeFn invoker,
    ExtensionAbortFn? onAbort,
  }) : _invoker = invoker,
       _onAbort = onAbort;

  @override
  final String providerId;

  final ExtensionInvokeFn _invoker;
  final ExtensionAbortFn? _onAbort;

  @override
  Future<ExtensionPayload> resolve(
    ExtensionRequest request,
    CancellationToken cancellation,
  ) async {
    cancellation.throwIfCancelled();
    void Function()? abortListener;
    final onAbort = _onAbort;
    if (onAbort != null) {
      abortListener = onAbort;
      cancellation.addListener(abortListener);
    }
    try {
      final raw = await _invoker(request);
      cancellation.throwIfCancelled();
      return ExtensionPayload(Map<String, Object?>.from(raw));
    } on JobCancelledException {
      rethrow;
    } on CoreError catch (error) {
      throw error.providerId == null
          ? error.copyWith(providerId: providerId)
          : error;
    } on PlatformException catch (error) {
      throw normalizePlatformException(error, providerId: providerId);
    } catch (error) {
      throw normalizeCoreError(
        error,
        providerId: providerId,
        fallback: CoreErrorCategory.provider,
        fallbackMessage: 'Provider "$providerId" failed: $error',
      );
    } finally {
      if (abortListener != null) {
        cancellation.removeListener(abortListener);
      }
    }
  }

  /// Test/factory helper: strict decoding of [payload] with this driver's
  /// provider attribution on format failures.
  ExtensionPayloadDecoder decoderFor(ExtensionPayload payload) =>
      ExtensionPayloadDecoder(payload.data, providerId: providerId);
}
