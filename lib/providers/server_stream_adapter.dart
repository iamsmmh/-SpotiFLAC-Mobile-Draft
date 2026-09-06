/// Streaming-engine adapter for self-hosted music servers.
///
/// Lives in its own file (not next to the registry providers) so the
/// engine provider can import it without a circular import: the engine
/// chain gains every enabled server as one [StreamSourceAdapter].
library;

import 'package:spotiflac_android/core/streaming/stream_provider.dart';
import 'package:spotiflac_android/engine/audio_characteristics.dart';
import 'package:spotiflac_android/engine/streaming_engine.dart';
import 'package:spotiflac_android/ecosystem/servers/music_server_registry.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/streaming_engine_provider.dart'
    show StreamSourceAdapter;

class ServerStreamAdapter implements StreamSourceAdapter {
  const ServerStreamAdapter({required this.registry});

  final MusicServerRegistry registry;

  @override
  String get id => 'music_servers';

  @override
  Future<List<StreamDescriptor>> candidatesFor(Track track) async {
    final results = <StreamDescriptor>[];
    for (final provider in registry.enabledProviders) {
      try {
        final source = await provider.resolveTrack(track);
        if (source == null) continue;
        results.add(_descriptorOf(source));
      } catch (_) {
        // One unreachable server must not break the whole chain.
        continue;
      }
    }
    return results;
  }

  StreamDescriptor _descriptorOf(StreamSource source) {
    final bitrate = source.bitrate <= 0 ? 320 : source.bitrate;
    final format = source.format.toUpperCase();
    final quality = format.contains('FLAC')
        ? AudioQualityLevel.lossless
        : bitrate >= 320
        ? AudioQualityLevel.high
        : bitrate >= 128
        ? AudioQualityLevel.normal
        : AudioQualityLevel.low;
    return StreamDescriptor(
      id: 'server:${source.providerId}',
      providerId: source.providerId,
      kind: StreamSourceKind.httpStream,
      uri: source.url,
      quality: quality,
      // Self-hosted servers serve the user's own files.
      cachePermitted: source.cachePermitted,
      priority: 6,
    );
  }
}
