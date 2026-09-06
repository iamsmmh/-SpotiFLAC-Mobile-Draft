/// CarPlay bridge (Milestone 2) — Dart side.
///
/// The native `CarPlayBridge` asks Dart for the children of a container and
/// tells Dart when the driver taps a row. Both are answered from the
/// **existing** [MediaBrowseTree] — the same tree Android Auto browses — so
/// there is exactly one definition of "what can I browse", and a change to
/// the library surfaces on both head-unit platforms at once.
///
/// This deliberately does *not* introduce a parallel content model. The only
/// CarPlay-specific work here is flattening [MediaItem] into the small map
/// the Swift side renders, and routing a tap back into playback.
library;

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:spotiflac_android/services/apple_integration_service.dart'
    show isAppleHost;
import 'package:spotiflac_android/services/media_browse_tree.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('CarPlay');

/// Starts playback of [itemId], which lives inside [parentId].
///
/// Mirrors the Android Auto contract: tapping a track inside an album plays
/// the *album* from that track, so the container is part of the request.
typedef CarPlayPlayCallback =
    Future<void> Function(String itemId, String parentId);

/// Serves the CarPlay content hierarchy from [MediaBrowseTree].
class CarPlayService {
  static const MethodChannel _channel = MethodChannel(
    'com.zarz.spotiflac/carplay',
  );

  /// Maximum rows returned to a head unit.
  ///
  /// CarPlay hard-caps list templates (historically 12 sections / a few
  /// hundred rows) and, more importantly, a driver cannot scroll a long list
  /// safely. Deep libraries are reached by drilling into containers.
  static const int maxRows = 100;

  final MediaBrowseTree _tree;
  final CarPlayPlayCallback _onPlay;

  bool _registered = false;

  CarPlayService({
    required MediaBrowseTree tree,
    required CarPlayPlayCallback onPlay,
  }) : _tree = tree,
       _onPlay = onPlay;

  /// Installs the handler. No-op off iOS and idempotent.
  void register() {
    if (_registered || !isAppleHost) return;
    _registered = true;
    _channel.setMethodCallHandler(_handle);
  }

  Future<Object?> _handle(MethodCall call) async {
    switch (call.method) {
      case 'browse':
        final args = call.arguments;
        final parentId = args is Map ? args['parentId']?.toString() : null;
        return browse(parentId ?? AudioService.browsableRootId);
      case 'play':
        final args = call.arguments;
        if (args is! Map) return false;
        final itemId = args['itemId']?.toString();
        if (itemId == null || itemId.isEmpty) return false;
        final parentId = args['parentId']?.toString() ?? '';
        await _play(itemId, parentId);
        return true;
      default:
        return null;
    }
  }

  /// Returns the rows for [parentId] in the shape the Swift side expects.
  ///
  /// Never throws: an exception here leaves the head unit showing a
  /// permanent "Loading…", which is worse than an empty list.
  Future<List<Map<String, Object?>>> browse(String parentId) async {
    try {
      final children = await _tree.children(parentId);
      final rows = <Map<String, Object?>>[];
      for (final item in children.take(maxRows)) {
        rows.add(<String, Object?>{
          'id': item.id,
          'title': item.title,
          'subtitle': _subtitleFor(item),
          'isBrowsable': item.playable != true,
        });
      }
      return rows;
    } catch (error, stack) {
      _log.e('CarPlay browse failed for "$parentId"', error, stack);
      return const <Map<String, Object?>>[];
    }
  }

  /// The secondary line: artist, falling back to album, then the existing
  /// display subtitle.
  static String? _subtitleFor(MediaItem item) {
    final artist = item.artist?.trim();
    if (artist != null && artist.isNotEmpty) return artist;
    final album = item.album?.trim();
    if (album != null && album.isNotEmpty) return album;
    final subtitle = item.displaySubtitle?.trim();
    if (subtitle != null && subtitle.isNotEmpty) return subtitle;
    return null;
  }

  Future<void> _play(String itemId, String parentId) async {
    try {
      await _onPlay(itemId, parentId);
    } catch (error, stack) {
      // A failed play must not propagate into the platform channel: CarPlay
      // would surface it as an opaque error sheet mid-drive.
      _log.e('CarPlay play failed for "$itemId"', error, stack);
    }
  }

  /// Tells CarPlay to rebuild its visible list (a download finished, a
  /// playlist changed).
  Future<void> invalidate() async {
    if (!isAppleHost) return;
    try {
      await _channel.invokeMethod<bool>('invalidate');
    } on MissingPluginException {
      // Older build without the channel; nothing to refresh.
    } catch (error, stack) {
      _log.e('CarPlay invalidate failed', error, stack);
    }
  }

  /// Whether a CarPlay head unit is currently connected.
  Future<bool> isConnected() async {
    if (!isAppleHost) return false;
    try {
      return await _channel.invokeMethod<bool>('isConnected') ?? false;
    } on MissingPluginException {
      return false;
    } catch (error, stack) {
      _log.e('CarPlay isConnected failed', error, stack);
      return false;
    }
  }

  void dispose() {
    if (!_registered) return;
    _registered = false;
    if (isAppleHost) {
      _channel.setMethodCallHandler(null);
    }
  }
}
