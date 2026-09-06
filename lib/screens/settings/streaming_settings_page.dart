import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/audio/crossfade_manager.dart';
import 'package:spotiflac_android/audio/normalization_manager.dart';
import 'package:spotiflac_android/audio/replaygain_processor.dart';
import 'package:spotiflac_android/engine/audio_characteristics.dart';
import 'package:spotiflac_android/engine/crossfade_policy.dart';
import 'package:spotiflac_android/engine/smart_play.dart';
import 'package:spotiflac_android/engine/streaming_engine.dart';
import 'package:spotiflac_android/providers/audio_engine_provider.dart';
import 'package:spotiflac_android/providers/engine_settings_provider.dart';
import 'package:spotiflac_android/providers/playback_statistics_provider.dart';
import 'package:spotiflac_android/providers/streaming_engine_provider.dart';
import 'package:spotiflac_android/screens/settings/listening_statistics_page.dart';
import 'package:spotiflac_android/screens/settings/streaming_integrity_page.dart';
import 'package:spotiflac_android/theme/app_tokens.dart';
import 'package:spotiflac_android/utils/gain_format.dart';
import 'package:spotiflac_android/widgets/app_sliver_header.dart';
import 'package:spotiflac_android/widgets/liquid/liquid_glass.dart';
import 'package:spotiflac_android/widgets/settings_group.dart';

/// Settings → Streaming & Glass.
///
/// NOTE(l10n): the engine surface is English-first while the feature set
/// stabilizes; the strings will move to the ARB tree in a follow-up pass so
/// the existing Crowdin pipeline stays the single source of translation.
class StreamingSettingsPage extends ConsumerStatefulWidget {
  const StreamingSettingsPage({super.key});

  @override
  ConsumerState<StreamingSettingsPage> createState() =>
      _StreamingSettingsPageState();
}

class _StreamingSettingsPageState
    extends ConsumerState<StreamingSettingsPage> {
  static const List<(PlaybackModePreference, String, IconData)> _modes = [
    (PlaybackModePreference.smart, 'Smart Play', Icons.auto_awesome_outlined),
    (PlaybackModePreference.stream, 'Stream', Icons.cloud_outlined),
    (PlaybackModePreference.download, 'Download', Icons.download_outlined),
    (
      PlaybackModePreference.downloadAndPlay,
      'Download & Play',
      Icons.play_circle_outline,
    ),
    (
      PlaybackModePreference.localOnly,
      'Local only',
      Icons.phonelink_ring_outlined,
    ),
  ];

  static const List<(String, AudioQualityLevel)> _qualityOptions = [
    ('Auto', AudioQualityLevel.auto),
    ('Low · 128kbps', AudioQualityLevel.low),
    ('Normal · 192kbps', AudioQualityLevel.normal),
    ('High · 320kbps', AudioQualityLevel.high),
    ('Lossless · FLAC', AudioQualityLevel.lossless),
    ('Hi-Res', AudioQualityLevel.hires),
  ];

  static const List<(String, String)> _visualizerStyles = [
    ('Spectrum', 'spectrum'),
    ('Waveform', 'waveform'),
    ('Circular', 'circular'),
    ('Bars', 'bars'),
  ];

  static const List<(int, String)> _cacheLimits = [
    (0, 'Unlimited'),
    (256, '256 MB'),
    (512, '512 MB'),
    (1024, '1 GB'),
    (2048, '2 GB'),
    (4096, '4 GB'),
  ];

  static String _cacheLimitLabel(int mb) {
    for (final entry in _cacheLimits) {
      if (entry.$1 == mb) return entry.$2;
    }
    return '$mb MB';
  }

  static String _cacheLimitDescription(int mb) => mb <= 0
      ? 'Ephemeral stream and metadata cache can grow freely'
      : 'Oldest cached files are removed once the cache exceeds '
            '${_cacheLimitLabel(mb)}';

  static String _qualityPolicyDescription(EngineSettings settings) {
    final policy = settings.qualityPolicy;
    if (policy.autoProfile) {
      return 'Auto: Wi-Fi lossless · mobile high · poor normal · roaming high';
    }
    return 'Wi-Fi ${policy.wifiProfile.label}, '
        'mobile ${policy.mobileProfile.label}, '
        'poor ${policy.poorProfile.label}, '
        'roaming ${policy.roamingProfile.label}';
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(engineSettingsProvider);
    final notifier = ref.read(engineSettingsProvider.notifier);
    final diagnostics = ref.watch(engineDiagnosticsProvider);
    final audio = ref.watch(audioEngineSettingsProvider);
    final audioNotifier = ref.read(audioEngineSettingsProvider.notifier);

    return CustomScrollView(
      slivers: [
        AppSliverHeader.page(title: 'Streaming & Glass'),
        _section(
          context,
          'Smart Play',
          SettingsGroup(
            children: [
              SettingsItem(
                icon: Icons.route_outlined,
                title: 'Playback mode',
                subtitle: _playbackModeDescription(settings.playbackMode),
                trailing: Text(
                  _playbackModeLabel(settings.playbackMode),
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onTap: () => _pickMode(context, settings, notifier),
              ),
              SettingsSwitchItem(
                icon: Icons.swap_horiz,
                title: 'Local first',
                subtitle:
                    'Keep playing the downloaded copy even when a stream is available',
                value: settings.localFirst,
                onChanged: notifier.setLocalFirst,
              ),
              SettingsSwitchItem(
                icon: Icons.cloud_outlined,
                title: 'Streaming enabled',
                subtitle: 'Allow the engine to resolve and play provider streams',
                value: settings.streamingEnabled,
                onChanged: notifier.setStreamingEnabled,
              ),
              SettingsSwitchItem(
                icon: Icons.cloud_off_outlined,
                title: 'Offline mode',
                subtitle:
                    'Local files only — never resolve streams or reach the '
                    'network while enabled',
                value: settings.offlineMode,
                onChanged: notifier.setOfflineMode,
                showDivider: false,
              ),
            ],
          ),
        ),
        _section(
          context,
          'Offline & storage policy',
          SettingsGroup(
            children: [
              SettingsItem(
                icon: Icons.sd_storage_outlined,
                title: 'Cache limit',
                subtitle: _cacheLimitDescription(settings.maxCacheSizeMb),
                trailing: Text(
                  _cacheLimitLabel(settings.maxCacheSizeMb),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onTap: () => _pickCacheLimit(context, settings, notifier),
              ),
              SettingsSwitchItem(
                icon: Icons.auto_delete_outlined,
                title: 'Auto-clean cache',
                subtitle:
                    'Prune the oldest cached files when the limit is reached',
                value: settings.autoCleanCache,
                onChanged: notifier.setAutoCleanCache,
                showDivider: false,
              ),
            ],
          ),
        ),
        _section(
          context,
          'Quality & network policies',
          SettingsGroup(
            children: [
              SettingsItem(
                icon: Icons.high_quality_outlined,
                title: 'Requested quality',
                subtitle: _qualityPolicyDescription(settings),
                trailing: _qualityChip(settings.qualityProfile),
                onTap: () => _pickQuality(context, settings, notifier),
              ),
              _networkProfileItem(
                context,
                'Wi-Fi',
                'Lossless when available',
                settings.wifiProfile,
                'wifi',
                notifier,
              ),
              _networkProfileItem(
                context,
                'Mobile data',
                'Higher quality, higher data use',
                settings.mobileProfile,
                'mobile',
                notifier,
              ),
              _networkProfileItem(
                context,
                'Poor connection',
                'Smaller buffers, stepped-down quality',
                settings.poorProfile,
                'poor',
                notifier,
              ),
              _networkProfileItem(
                context,
                'Roaming',
                'More conservative quality while roaming',
                settings.roamingProfile,
                'roaming',
                notifier,
              ),
              SettingsSwitchItem(
                icon: Icons.auto_fix_high,
                title: 'Adaptive quality',
                subtitle:
                    'Step quality down on slow links and back up when the network recovers',
                value: settings.adaptiveQuality,
                onChanged: notifier.setAdaptiveQuality,
                showDivider: false,
              ),
            ],
          ),
        ),
        _section(
          context,
          'Resilience',
          SettingsGroup(
            children: [
              _StepperItem(
                icon: Icons.replay_outlined,
                title: 'Max stream attempts',
                subtitle: 'Before the engine gives up on a failed source',
                value: settings.maxStreamAttempts,
                min: 1,
                max: 8,
                onChanged: notifier.setMaxStreamAttempts,
              ),
              _StepperItem(
                icon: Icons.timer_outlined,
                title: 'Preflight timeout',
                subtitle: 'Seconds to wait for a stream URL to answer',
                value: settings.streamTimeoutSeconds,
                suffix: 's',
                min: 3,
                max: 60,
                step: 3,
                onChanged: notifier.setStreamTimeoutSeconds,
              ),
              _StepperItem(
                icon: Icons.upcoming_outlined,
                title: 'Preload window',
                subtitle: 'Next tracks preflighted before they play',
                value: settings.preloadWindow,
                min: 1,
                max: 5,
                onChanged: notifier.setPreloadWindow,
              ),
              SettingsSwitchItem(
                icon: Icons.trending_up_outlined,
                title: 'Preload next track',
                subtitle: 'Validate the next URL while the current song plays',
                value: settings.preloadNextTrack,
                onChanged: notifier.setPreloadNextTrack,
              ),
              SettingsSwitchItem(
                icon: Icons.refresh_outlined,
                title: 'Refresh expired URLs',
                subtitle: 'Ask the adapter for a fresh URL before retrying',
                value: settings.autoRefreshExpiredUrls,
                onChanged: notifier.setAutoRefreshExpiredUrls,
              ),
              SettingsSwitchItem(
                icon: Icons.memory_outlined,
                title: 'Buffer preview streams',
                subtitle: 'Keep the stream pre-buffered for instant start',
                value: settings.bufferPreviewStreams,
                onChanged: notifier.setBufferPreviewStreams,
              ),
              SettingsSwitchItem(
                icon: Icons.sd_storage_outlined,
                title: 'Cache streams',
                subtitle:
                    'Off by default: provider terms decide whether a stream may be stored',
                value: settings.cacheStreams,
                onChanged: notifier.setCacheStreams,
                showDivider: false,
              ),
            ],
          ),
        ),
        _section(
          context,
          'Audio pipeline',
          SettingsGroup(
            children: [
              SettingsSwitchItem(
                icon: Icons.linked_camera_outlined,
                title: 'Gapless playback',
                subtitle:
                    'Splice consecutive lossless tracks without a silence gap',
                value: settings.gaplessEnabled,
                onChanged: notifier.setGaplessEnabled,
              ),
              _StepperItem(
                icon: Icons.swap_horiz_rounded,
                title: 'Crossfade',
                subtitle: settings.crossfadeSeconds == 0
                    ? 'Off — tracks change without overlap'
                    : 'Overlap the end of a track with the start of the next',
                value: settings.crossfadeSeconds,
                suffix: 's',
                min: 0,
                max: CrossfadeSettings.maxSeconds,
                onChanged: notifier.setCrossfadeSeconds,
              ),
              SettingsSwitchItem(
                icon: Icons.auto_awesome_outlined,
                title: 'Smart crossfade',
                subtitle:
                    'Skip the overlap between album tracks, lossless pairs '
                    'and short interludes',
                value: settings.crossfadeSmart,
                enabled: settings.crossfadeSeconds > 0,
                onChanged: settings.crossfadeSeconds > 0
                    ? notifier.setCrossfadeSmart
                    : null,
              ),
              _StepperItem(
                icon: Icons.storage_outlined,
                title: 'Low-bandwidth buffer',
                subtitle: 'Extra lookahead buffered on poor connections',
                value: settings.lowBandwidthBufferSeconds,
                suffix: 's',
                min: 5,
                max: 120,
                step: 5,
                onChanged: notifier.setLowBandwidthBufferSeconds,
              ),
              _StepperItem(
                icon: Icons.downloading_outlined,
                title: 'Prebuffer head',
                subtitle: 'Bytes of the next stream warmed while playing',
                value: settings.prebufferHeadBytesKb,
                suffix: ' KB',
                min: 64,
                max: 8192,
                step: 64,
                onChanged: notifier.setPrebufferHeadBytesKb,
              ),
            ],
          ),
        ),
        _section(
          context,
          'Gain & loudness',
          SettingsGroup(
            children: [
              const SettingsSectionHeader(title: 'ReplayGain'),
              SettingsChoiceGrid(
                children: [
                  for (final mode in ReplayGainMode.values)
                    SettingsChoiceChip(
                      label: mode.label,
                      isSelected: audio.replayGainMode == mode,
                      onTap: () => audioNotifier.setReplayGainMode(mode),
                    ),
                ],
              ),
              _DbStepperItem(
                icon: Icons.add_chart_outlined,
                title: 'Pre-amp',
                subtitle: 'Extra gain applied on top of the selected tag',
                value: audio.replayGainPreAmpDb,
                min: ReplayGainConfig.minPreAmpDb,
                max: ReplayGainConfig.maxPreAmpDb,
                step: 0.5,
                suffix: ' dB',
                enabled: audio.replayGainMode != ReplayGainMode.off,
                onChanged: audioNotifier.setPreAmpDb,
              ),
              SettingsSwitchItem(
                icon: Icons.hearing_disabled_outlined,
                title: 'Prevent clipping',
                subtitle:
                    'Pull the volume down when the tagged peak would clip',
                value: audio.preventClipping,
                enabled: audio.replayGainMode != ReplayGainMode.off,
                onChanged: audio.replayGainMode != ReplayGainMode.off
                    ? audioNotifier.setPreventClipping
                    : null,
              ),
              const SettingsSectionHeader(title: 'Loudness normalization'),
              SettingsSwitchItem(
                icon: Icons.graphic_eq_outlined,
                title: 'Normalize loudness',
                subtitle:
                    'Master switch for the engine gain path — ReplayGain and '
                    'the target below both ride it',
                value: audio.normalizationEnabled,
                onChanged: audioNotifier.setNormalizationEnabled,
              ),
              SettingsChoiceGrid(
                children: [
                  for (final target in LoudnessTarget.values)
                    SettingsChoiceChip(
                      label: target.label,
                      isSelected: audio.normalizationEnabled &&
                          audio.loudnessTargetLufs == target.targetLufs,
                      onTap: () => audioNotifier
                          .setLoudnessTargetLufs(target.targetLufs),
                    ),
                ],
              ),
              const SettingsSectionHeader(title: 'Crossfade curve'),
              SettingsSwitchItem(
                icon: Icons.auto_awesome_motion_outlined,
                title: 'Automatic curve',
                subtitle:
                    'Pick the curve from the fade length and the pair of tracks',
                value: audio.fadeCurveAuto,
                enabled: settings.crossfadeSeconds > 0,
                onChanged: settings.crossfadeSeconds > 0
                    ? (value) => audioNotifier.setFadeCurve(auto: value)
                    : null,
              ),
              SettingsChoiceGrid(
                children: [
                  for (final curve in FadeCurveKind.values)
                    SettingsChoiceChip(
                      label: curve.label,
                      isSelected: !audio.fadeCurveAuto &&
                          audio.fadeCurve == curve,
                      onTap: () => audioNotifier.setFadeCurve(
                        curve: curve,
                        auto: false,
                      ),
                    ),
                ],
              ),
              SettingsInfoCard(
                icon: Icons.info_outline,
                message:
                    'Gain comes from the ReplayGain/R128 tags read by the '
                    'metadata engine. Tracks without tags play at their '
                    'mastered level; use a manual override on the track menu '
                    'to tune one song.',
              ),
            ],
          ),
        ),
        _section(
          context,
          'Recovery & privacy',
          SettingsGroup(
            children: [
              SettingsSwitchItem(
                icon: Icons.history_rounded,
                title: 'Engine savepoints',
                subtitle:
                    'Remember queue, modes and volume for resume after restart',
                value: settings.saveEngineSavepoints,
                onChanged: notifier.setSaveEngineSavepoints,
              ),
              SettingsSwitchItem(
                icon: Icons.insights_outlined,
                title: 'Listening statistics',
                subtitle:
                    'Plays, skips and minutes — stored only on this device',
                value: settings.trackListeningStats,
                onChanged: notifier.setTrackListeningStats,
              ),
              SettingsItem(
                icon: Icons.query_stats_outlined,
                title: 'Listening Statistics',
                subtitle: _listeningSummary(),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openListeningStatistics(context),
              ),
              SettingsItem(
                icon: Icons.clear_all_outlined,
                title: 'Clear restore memory',
                subtitle:
                    'Forget the last queue/savepoint (keeps downloaded files)',
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _clearSavepoint(context),
                showDivider: false,
              ),
            ],
          ),
        ),
        _section(
          context,
          'Liquid Glass UI',
          SettingsGroup(
            children: [
              SettingsSwitchItem(
                icon: Icons.blur_on_outlined,
                title: 'Liquid Glass',
                subtitle:
                    'Frosted mini/full player. Off restores the classic player',
                value: settings.glassUiEnabled,
                onChanged: notifier.setGlassUiEnabled,
              ),
              _GlassSliderItem(
                icon: Icons.blur_on_outlined,
                title: 'Frost blur',
                subtitle: 'Backdrop blur strength of glass surfaces',
                value: settings.glassBlurSigma,
                min: 4,
                max: 40,
                display: '${settings.glassBlurSigma.round()}',
                onChanged: notifier.setGlassBlurSigma,
              ),
              _GlassSliderItem(
                icon: Icons.opacity_outlined,
                title: 'Glass tint',
                subtitle: 'Translucency of the glass body',
                value: settings.glassTintAlpha,
                min: 0,
                max: 0.45,
                display: '${(settings.glassTintAlpha * 100).round()}%',
                onChanged: notifier.setGlassTintAlpha,
              ),
              SettingsSwitchItem(
                icon: Icons.auto_awesome_outlined,
                title: 'Sheen',
                subtitle: 'Slow light sweep across glass surfaces',
                value: settings.glassSheenEnabled,
                onChanged: notifier.setGlassSheenEnabled,
              ),
              SettingsSwitchItem(
                icon: Icons.touch_app_outlined,
                title: 'Pointer glow',
                subtitle: 'Light follows touch on glass controls',
                value: settings.glassPointerGlow,
                onChanged: notifier.setGlassPointerGlow,
              ),
              SettingsItem(
                icon: Icons.graphic_eq_outlined,
                title: 'Visualizer',
                subtitle: 'Style used in the full glass player',
                trailing: Text(
                  settings.visualizerStyle.capitalized,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onTap: () => _pickVisualizer(context, settings, notifier),
              ),
              SettingsSwitchItem(
                icon: Icons.battery_std_outlined,
                title: 'Performance mode',
                subtitle: 'Fewer visualizer bars and no motion effects',
                value: settings.visualizerPerformanceMode,
                onChanged: notifier.setVisualizerPerformanceMode,
              ),
              SettingsSwitchItem(
                icon: Icons.photo_size_select_large_outlined,
                title: 'Large artwork',
                subtitle: 'Show the full artwork behind the glass player',
                value: settings.largeArtworkMode,
                onChanged: notifier.setLargeArtworkMode,
                showDivider: false,
              ),
            ],
          ),
        ),
        _section(
          context,
          'Diagnostics',
          SettingsGroup(
            children: [
              SettingsItem(
                icon: Icons.monitor_heart_outlined,
                title: 'Engine status',
                subtitle: diagnostics.summaryLine,
                onTap: () => _showDiagnostics(context, diagnostics),
              ),
              SettingsItem(
                icon: Icons.route_outlined,
                title: 'Streaming integrity',
                subtitle:
                    '${diagnostics.integrityFailures} failures · '
                    '${diagnostics.integritySuccesses} ok — per-URL reasons',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const StreamingIntegrityPage(),
                  ),
                ),
              ),
              SettingsSwitchItem(
                icon: Icons.terminal_outlined,
                title: 'Diagnostics logging',
                subtitle: 'Record engine events to the Diagnostics Center',
                value: settings.diagnosticsEnabled,
                onChanged: notifier.setDiagnosticsEnabled,
                showDivider: false,
              ),
            ],
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  Widget _section(BuildContext context, String title, Widget child) {
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(
        context.tokens.pagePadding,
        context.tokens.pagePadding * 0.5,
        context.tokens.pagePadding,
        context.tokens.pagePadding * 0.5,
      ),
      sliver: SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8, left: 4),
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            child,
          ],
        ),
      ),
    );
  }

  Widget _networkProfileItem(
    BuildContext context,
    String title,
    String subtitle,
    AudioQualityLevel level,
    String profile,
    EngineSettingsNotifier notifier,
  ) {
    return SettingsItem(
      icon: Icons.network_wifi_outlined,
      title: title,
      subtitle: subtitle,
      trailing: _qualityChip(level),
      onTap: () => _pickNetworkLevel(context, title, level, profile, notifier),
    );
  }

  Widget _qualityChip(AudioQualityLevel level) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.primaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        level.label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: Theme.of(context).colorScheme.onPrimaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  String _playbackModeLabel(PlaybackModePreference mode) => switch (mode) {
    PlaybackModePreference.smart => 'Smart',
    PlaybackModePreference.stream => 'Stream',
    PlaybackModePreference.download => 'Download',
    PlaybackModePreference.downloadAndPlay => 'Download & Play',
    PlaybackModePreference.localOnly => 'Local only',
  };

  String _playbackModeDescription(PlaybackModePreference mode) => switch (mode) {
    PlaybackModePreference.smart =>
      'Local → stream → download & play → why not',
    PlaybackModePreference.stream => 'Always stream, never download first',
    PlaybackModePreference.download => 'Queue the file, don’t stream',
    PlaybackModePreference.downloadAndPlay =>
      'Download the file, then start playback',
    PlaybackModePreference.localOnly => 'Never touch the network',
  };

  String _listeningSummary() {
    final stats = ref.watch(playbackStatisticsProvider);
    final listened = formatListenedMs(stats.listenedMs);
    return '${stats.plays} plays · ${stats.skips} skips · $listened listened · '
        '${stats.streakDays}d streak';
  }

  void _openListeningStatistics(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const ListeningStatisticsPage(),
      ),
    );
  }

  Future<void> _clearSavepoint(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear restore memory?'),
        content: const Text(
          'The saved queue and volume/position snapshot will be forgotten. '
          'Downloaded files are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(engineSavepointProvider.notifier).clear();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Restore memory cleared')),
      );
    }
  }

  Future<void> _pickMode(
    BuildContext context,
    EngineSettings settings,
    EngineSettingsNotifier notifier,
  ) async {
    final picked = await showLiquidBottomSheet<PlaybackModePreference>(
      context: context,
      title: 'Playback mode',
      subtitle: const Text(
        'Smart Play follows the ladder: downloaded → local → stream → '
        'download & play → unavailable.',
      ),
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: _modes.map((entry) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GlassChip(
              icon: entry.$3,
              label: '${entry.$2} — ${_playbackModeDescription(entry.$1)}',
              selected: entry.$1 == settings.playbackMode,
              onTap: () => Navigator.of(sheetContext).pop(entry.$1),
            ),
          );
        }).toList(growable: false),
      ),
    );
    if (picked != null) {
      await notifier.setPlaybackMode(picked);
    }
  }

  Future<void> _pickQuality(
    BuildContext context,
    EngineSettings settings,
    EngineSettingsNotifier notifier,
  ) async {
    final picked = await showLiquidBottomSheet<AudioQualityLevel>(
      context: context,
      title: 'Requested quality',
      subtitle: const Text('The engine asks providers for this quality first.'),
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: _qualityOptions.map((entry) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GlassChip(
              label: entry.$1,
              selected: entry.$2 == settings.qualityProfile,
              onTap: () => Navigator.of(sheetContext).pop(entry.$2),
            ),
          );
        }).toList(growable: false),
      ),
    );
    if (picked != null) {
      await notifier.setQualityProfile(picked);
    }
  }

  Future<void> _pickNetworkLevel(
    BuildContext context,
    String title,
    AudioQualityLevel current,
    String profile,
    EngineSettingsNotifier notifier,
  ) async {
    final picked = await showLiquidBottomSheet<AudioQualityLevel>(
      context: context,
      title: '$title quality',
      subtitle: const Text('Applied to this network profile.'),
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: _qualityOptions.map((entry) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GlassChip(
              label: entry.$1,
              selected: entry.$2 == current,
              onTap: () => Navigator.of(sheetContext).pop(entry.$2),
            ),
          );
        }).toList(growable: false),
      ),
    );
    if (picked != null) {
      await notifier.setNetworkProfile(profile, level: picked);
    }
  }

  Future<void> _pickCacheLimit(
    BuildContext context,
    EngineSettings settings,
    EngineSettingsNotifier notifier,
  ) async {
    final picked = await showLiquidBottomSheet<int>(
      context: context,
      title: 'Cache limit',
      subtitle: const Text(
        'A hard cap on the ephemeral stream/metadata cache. Downloaded music '
        'is never deleted.',
      ),
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: _cacheLimits.map((entry) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GlassChip(
              label: entry.$2,
              selected: entry.$1 == settings.maxCacheSizeMb,
              onTap: () => Navigator.of(sheetContext).pop(entry.$1),
            ),
          );
        }).toList(growable: false),
      ),
    );
    if (picked != null) {
      await notifier.setMaxCacheSizeMb(picked);
    }
  }

  Future<void> _pickVisualizer(
    BuildContext context,
    EngineSettings settings,
    EngineSettingsNotifier notifier,
  ) async {
    final picked = await showLiquidBottomSheet<String>(
      context: context,
      title: 'Visualizer',
      subtitle: const Text('Rendered procedurally — no audio analysis needed.'),
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: _visualizerStyles.map((entry) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GlassChip(
              label: entry.$1,
              selected: entry.$2 == settings.visualizerStyle,
              onTap: () => Navigator.of(sheetContext).pop(entry.$2),
            ),
          );
        }).toList(growable: false),
      ),
    );
    if (picked != null) {
      await notifier.setVisualizerStyle(picked);
    }
  }

  Future<void> _showDiagnostics(
    BuildContext context,
    StreamingDiagnostics diagnostics,
  ) async {
    final providers = diagnostics.health.snapshot();
    final events = diagnostics.log.events.take(12).toList(growable: false);
    final bandwidthLabel = diagnostics.effectiveBandwidthLabel;
    await showLiquidBottomSheet<void>(
      context: context,
      title: 'Diagnostics Center',
      subtitle: Text(
        'Phase: ${diagnostics.session.phase.name} · '
        'providers: ${providers.length} · '
        'ok ${diagnostics.successes} · '
        'failed ${diagnostics.failures}'
        '${bandwidthLabel == null ? '' : ' · ~$bandwidthLabel'}',
      ),
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                const Icon(Icons.speed_outlined, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Effective bandwidth',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                Text(
                  bandwidthLabel ?? '—',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (providers.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No provider activity yet'),
            ),
          for (final provider in providers.take(6))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Icon(
                    provider.isAvailable
                        ? Icons.circle
                        : Icons.remove_circle_outline,
                    size: 14,
                    color: provider.isAvailable
                        ? Colors.greenAccent
                        : Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      provider.providerId,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  Text(
                    '${provider.successCount}✓ ${provider.failureCount}✗ '
                    '${provider.lastLatencyMs ?? '—'}ms',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          const Divider(),
          for (final event in events)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    switch (event.severity) {
                      EngineEventSeverity.info => Icons.info_outline,
                      EngineEventSeverity.warning => Icons.warning_amber,
                      EngineEventSeverity.error => Icons.error_outline,
                    },
                    size: 16,
                    color: switch (event.severity) {
                      EngineEventSeverity.info =>
                        Theme.of(context).colorScheme.onSurfaceVariant,
                      EngineEventSeverity.warning =>
                        Theme.of(context).colorScheme.tertiary,
                      EngineEventSeverity.error =>
                        Theme.of(context).colorScheme.error,
                    },
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${event.category}: ${event.message}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Settings row with − / + steppers (IconButtons always carry tooltips).
class _StepperItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final int value;
  final int min;
  final int max;
  final int step;
  final String? suffix;
  final ValueChanged<int> onChanged;

  const _StepperItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.step = 1,
    this.suffix,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SettingsItem(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            tooltip: 'Decrease $title',
            onPressed: value <= min
                ? null
                : () => onChanged((value - step).clamp(min, max)),
            visualDensity: VisualDensity.compact,
            color: colorScheme.onSurfaceVariant,
          ),
          SizedBox(
            width: 40,
            child: Text(
              '$value${suffix ?? ''}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: 'Increase $title',
            onPressed: value >= max
                ? null
                : () => onChanged((value + step).clamp(min, max)),
            visualDensity: VisualDensity.compact,
            color: colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

/// Settings row with − / + steppers for a fractional (dB) value.
///
/// Mirrors [_StepperItem] — the int-only stepper cannot express the 0.5 dB
/// granularity of a ReplayGain pre-amp.
class _DbStepperItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final double value;
  final double min;
  final double max;
  final double step;
  final String? suffix;
  final bool enabled;
  final ValueChanged<double> onChanged;

  const _DbStepperItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.step = 0.5,
    this.suffix,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // Stepping accumulates float error (0.1 + 0.2), so round to the step grid.
    final snapped = ((value / step).round() * step).clamp(min, max).toDouble();
    final foreground = enabled
        ? colorScheme.onSurfaceVariant
        : colorScheme.onSurfaceVariant.withValues(alpha: 0.4);
    return SettingsItem(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            tooltip: 'Decrease $title',
            onPressed: !enabled || snapped <= min
                ? null
                : () => onChanged((snapped - step).clamp(min, max).toDouble()),
            visualDensity: VisualDensity.compact,
            color: foreground,
          ),
          SizedBox(
            width: 72,
            child: Text(
              '${formatGainDb(snapped)}${suffix ?? ''}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: 'Increase $title',
            onPressed: !enabled || snapped >= max
                ? null
                : () => onChanged((snapped + step).clamp(min, max).toDouble()),
            visualDensity: VisualDensity.compact,
            color: foreground,
          ),
        ],
      ),
    );
  }
}

/// Settings row with a glass slider control (Liquid Glass knobs).
class _GlassSliderItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final double value;
  final double min;
  final double max;
  final String display;
  final ValueChanged<double> onChanged;

  const _GlassSliderItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsItem(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: SizedBox(
        width: 120,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              display,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            GlassSlider(
              value: ((value - min) / (max - min)).clamp(0.0, 1.0),
              onChanged: (v) => onChanged(min + (max - min) * v),
            ),
          ],
        ),
      ),
    );
  }
}

extension on String {
  String get capitalized => isEmpty
      ? this
      : '${this[0].toUpperCase()}${substring(1)}';
}
