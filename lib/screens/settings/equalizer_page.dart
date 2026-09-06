import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' show ShareParams, SharePlus, XFile;
import 'package:spotiflac_android/engine/audio_effects.dart';
import 'package:spotiflac_android/providers/audio_effects_provider.dart';
import 'package:spotiflac_android/theme/app_tokens.dart';
import 'package:spotiflac_android/utils/logger.dart';
import 'package:spotiflac_android/widgets/app_sliver_header.dart';
import 'package:spotiflac_android/widgets/liquid/liquid_glass.dart';
import 'package:spotiflac_android/widgets/settings_group.dart';

final _log = AppLogger('EqualizerPage');

/// Settings → Equalizer & effects.
///
/// 10-band equalizer with built-in and user presets (save / import / export),
/// bass boost, virtualizer, loudness enhancer, compressor and limiter. Stages
/// the device cannot provide are shown disabled with the reason.
class EqualizerPage extends ConsumerStatefulWidget {
  const EqualizerPage({super.key});

  @override
  ConsumerState<EqualizerPage> createState() => _EqualizerPageState();
}

class _EqualizerPageState extends ConsumerState<EqualizerPage> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(audioEffectsProvider);
    final notifier = ref.read(audioEffectsProvider.notifier);
    final settings = state.settings;
    final caps = state.capabilities;
    final active = settings.enabled;
    final compressorOn =
        active && caps.compressor && settings.compressorEnabled;
    final limiterOn = active && caps.limiter && settings.limiterEnabled;

    return CustomScrollView(
      slivers: [
        AppSliverHeader.page(title: 'Equalizer & effects'),
        _section(
          context,
          null,
          SettingsGroup(
            children: [
              SettingsSwitchItem(
                icon: Icons.graphic_eq_rounded,
                title: 'Audio effects',
                subtitle: _statusSubtitle(state),
                value: settings.enabled,
                onChanged: caps.any ? notifier.setEnabled : null,
                enabled: caps.any,
                showDivider: false,
              ),
            ],
          ),
        ),
        _section(
          context,
          'Equalizer',
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _PresetBar(
                state: state,
                enabled: active && caps.equalizer,
                onSelect: notifier.applyPreset,
                onSave: () => _savePreset(context),
                onManage: () => _managePresets(context),
              ),
              const SizedBox(height: 12),
              GlassCard(
                padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
                child: _EqualizerBands(
                  gains: settings.bandGainsDb,
                  enabled: active && caps.equalizer,
                  onChanged: notifier.setBandGain,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: active && !settings.isEqualizerFlat
                        ? notifier.resetEqualizer
                        : null,
                    icon: const Icon(Icons.restart_alt_rounded, size: 18),
                    label: const Text('Reset to flat'),
                  ),
                ],
              ),
            ],
          ),
        ),
        _section(
          context,
          'Enhancements',
          SettingsGroup(
            children: [
              _SliderItem(
                icon: Icons.speaker_outlined,
                title: 'Bass boost',
                subtitle: caps.bassBoost
                    ? 'Low-frequency emphasis'
                    : 'Not available on this device',
                value: settings.bassBoost,
                min: 0,
                max: 1,
                display: '${(settings.bassBoost * 100).round()}%',
                enabled: active && caps.bassBoost,
                onChanged: notifier.setBassBoost,
              ),
              _SliderItem(
                icon: Icons.surround_sound_outlined,
                title: 'Virtualizer',
                subtitle: caps.virtualizer
                    ? 'Wider stereo image on headphones'
                    : 'Not available on this device',
                value: settings.virtualizer,
                min: 0,
                max: 1,
                display: '${(settings.virtualizer * 100).round()}%',
                enabled: active && caps.virtualizer,
                onChanged: notifier.setVirtualizer,
              ),
              _SliderItem(
                icon: Icons.volume_up_outlined,
                title: 'Loudness enhancer',
                subtitle: caps.enhancer
                    ? 'Extra gain for quiet recordings'
                    : 'Not available on this device',
                value: settings.enhancerGainDb,
                min: 0,
                max: 12,
                display: '+${settings.enhancerGainDb.toStringAsFixed(1)} dB',
                enabled: active && caps.enhancer,
                onChanged: notifier.setEnhancerGainDb,
                showDivider: false,
              ),
            ],
          ),
        ),
        _section(
          context,
          'Dynamics',
          SettingsGroup(
            children: [
              SettingsSwitchItem(
                icon: Icons.compress_rounded,
                title: 'Compressor',
                subtitle: caps.compressor
                    ? 'Evens out loud and quiet passages'
                    : 'Requires Android 9 or newer',
                value: settings.compressorEnabled && caps.compressor,
                enabled: active && caps.compressor,
                onChanged: active && caps.compressor
                    ? notifier.setCompressorEnabled
                    : null,
              ),
              _SliderItem(
                icon: Icons.vertical_align_bottom_rounded,
                title: 'Threshold',
                subtitle: 'Level above which compression starts',
                value: settings.compressorThresholdDb,
                min: -40,
                max: 0,
                display: '${settings.compressorThresholdDb.round()} dB',
                enabled: compressorOn,
                onChanged: notifier.setCompressorThresholdDb,
              ),
              _SliderItem(
                icon: Icons.linear_scale_rounded,
                title: 'Ratio',
                subtitle: 'How strongly peaks are reduced',
                value: settings.compressorRatio,
                min: 1,
                max: 20,
                display: '${settings.compressorRatio.toStringAsFixed(1)}:1',
                enabled: compressorOn,
                onChanged: notifier.setCompressorRatio,
              ),
              SettingsSwitchItem(
                icon: Icons.shield_outlined,
                title: 'Limiter',
                subtitle: caps.limiter
                    ? 'Hard ceiling against clipping after boosts'
                    : 'Requires Android 9 or newer',
                value: settings.limiterEnabled && caps.limiter,
                enabled: active && caps.limiter,
                onChanged: active && caps.limiter
                    ? notifier.setLimiterEnabled
                    : null,
              ),
              _SliderItem(
                icon: Icons.vertical_align_top_rounded,
                title: 'Ceiling',
                subtitle: 'Peaks never exceed this level',
                value: settings.limiterThresholdDb,
                min: -12,
                max: 0,
                display: '${settings.limiterThresholdDb.toStringAsFixed(1)} dB',
                enabled: limiterOn,
                onChanged: notifier.setLimiterThresholdDb,
                showDivider: false,
              ),
            ],
          ),
        ),
        _section(
          context,
          'Presets',
          SettingsGroup(
            children: [
              SettingsItem(
                icon: Icons.save_alt_rounded,
                title: 'Save current curve',
                subtitle: 'Store the equalizer as a named preset',
                onTap: active && caps.equalizer
                    ? () => _savePreset(context)
                    : null,
              ),
              SettingsItem(
                icon: Icons.ios_share_rounded,
                title: 'Export presets',
                subtitle: _presetCountLabel(state.userPresets.length),
                onTap: _busy || !_canExport(state)
                    ? null
                    : () => _exportPresets(context),
              ),
              SettingsItem(
                icon: Icons.file_download_outlined,
                title: 'Import presets',
                subtitle: 'Merge presets from an exported file',
                onTap: _busy ? null : () => _importPresets(context),
                showDivider: false,
              ),
            ],
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }

  static String _presetCountLabel(int count) {
    if (count == 0) return 'No saved presets yet';
    return '$count saved ${count == 1 ? 'preset' : 'presets'}';
  }

  /// Something to export: saved presets, or an unsaved manual curve.
  static bool _canExport(AudioEffectsState state) =>
      state.userPresets.isNotEmpty ||
      (state.settings.presetName == null && !state.settings.isEqualizerFlat);

  String _statusSubtitle(AudioEffectsState state) {
    final caps = state.capabilities;
    if (!caps.any) {
      return 'Not available on this device';
    }
    if (!state.settings.enabled) {
      return 'Off — playback is untouched';
    }
    if (!state.settings.hasActiveStage) {
      return 'On — every stage is neutral';
    }
    if (state.attached) return 'Active (${caps.engine})';
    final reason = state.attachReason;
    if (reason == 'no active player session') {
      return 'Applies when playback starts';
    }
    return reason == null || reason.isEmpty
        ? 'Waiting for playback'
        : 'Not applied: $reason';
  }

  Future<void> _savePreset(BuildContext context) async {
    final notifier = ref.read(audioEffectsProvider.notifier);
    final controller = TextEditingController(
      text: ref.read(audioEffectsProvider).settings.presetName ?? '',
    );
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Save preset'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(labelText: 'Preset name'),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || !context.mounted) return;
    final saved = await notifier.saveCurrentAsPreset(name);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          saved == null
              ? 'Choose a name that is not a built-in preset'
              : 'Saved "${saved.name}"',
        ),
      ),
    );
  }

  Future<void> _managePresets(BuildContext context) async {
    final notifier = ref.read(audioEffectsProvider.notifier);
    await showLiquidBottomSheet<void>(
      context: context,
      title: 'Presets',
      builder: (sheetContext) => Consumer(
        builder: (context, ref, _) {
          final state = ref.watch(audioEffectsProvider);
          final presets = state.allPresets;
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.6,
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: presets.length,
              itemBuilder: (context, index) {
                final preset = presets[index];
                final selected = state.settings.presetName == preset.name;
                return ListTile(
                  leading: Icon(
                    preset.builtIn
                        ? Icons.auto_awesome_outlined
                        : Icons.person_outline,
                  ),
                  title: Text(preset.name),
                  subtitle: Text(_curveSummary(preset.gainsDb)),
                  selected: selected,
                  trailing: preset.builtIn
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Delete ${preset.name}',
                          onPressed: () => notifier.deletePreset(preset),
                        ),
                  onTap: () {
                    notifier.applyPreset(preset);
                    Navigator.of(sheetContext).pop();
                  },
                );
              },
            ),
          );
        },
      ),
    );
  }

  static String _curveSummary(List<double> gains) {
    return gains
        .map((g) => g == 0 ? '0' : (g > 0 ? '+${g.round()}' : '${g.round()}'))
        .join(' ');
  }

  Future<void> _exportPresets(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final payload = ref.read(audioEffectsProvider.notifier).exportPresets();
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final file = File(
        p.join(
          dir.path,
          'spotiflac_eq_$stamp.${EqualizerPresetCodec.fileExtension}',
        ),
      );
      await file.writeAsString(payload, flush: true);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: 'Equalizer presets'),
      );
    } catch (e, stack) {
      _log.e('Failed to export EQ presets: $e', e, stack);
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not export presets')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importPresets(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final picked = await FilePicker.pickFile(type: FileType.any);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      final text = utf8.decode(bytes, allowMalformed: true);
      final count = await ref
          .read(audioEffectsProvider.notifier)
          .importPresets(text);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            count == 0
                ? 'No presets found in that file'
                : 'Imported $count ${count == 1 ? 'preset' : 'presets'}',
          ),
        ),
      );
    } catch (e, stack) {
      _log.e('Failed to import EQ presets: $e', e, stack);
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not read that file')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _section(BuildContext context, String? title, Widget child) {
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
            if (title != null)
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
}

class _PresetBar extends StatelessWidget {
  final AudioEffectsState state;
  final bool enabled;
  final ValueChanged<EqualizerPreset> onSelect;
  final VoidCallback onSave;
  final VoidCallback onManage;

  const _PresetBar({
    required this.state,
    required this.enabled,
    required this.onSelect,
    required this.onSave,
    required this.onManage,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = state.settings.presetName;
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          if (current == null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: const Text('Custom'),
                selected: true,
                onSelected: enabled ? (_) => onSave() : null,
                avatar: const Icon(Icons.tune_rounded, size: 16),
              ),
            ),
          for (final preset in state.allPresets)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(preset.name),
                selected: preset.name == current,
                onSelected: enabled ? (_) => onSelect(preset) : null,
                avatar: preset.builtIn
                    ? null
                    : Icon(
                        Icons.person_outline,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
              ),
            ),
          ActionChip(
            label: const Text('Manage'),
            avatar: const Icon(Icons.more_horiz_rounded, size: 16),
            onPressed: onManage,
          ),
        ],
      ),
    );
  }
}

/// Ten vertical faders (−12…+12 dB) with a frequency label under each.
class _EqualizerBands extends StatelessWidget {
  final List<double> gains;
  final bool enabled;
  final void Function(int band, double gainDb) onChanged;

  const _EqualizerBands({
    required this.gains,
    required this.enabled,
    required this.onChanged,
  });

  static String _label(int hz) => hz >= 1000
      ? '${(hz / 1000).toStringAsFixed(hz % 1000 == 0 ? 0 : 1)}k'
      : '$hz';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: enabled ? scheme.onSurfaceVariant : scheme.outline,
    );
    return SizedBox(
      height: 220,
      child: Row(
        children: [
          for (var i = 0; i < equalizerBandFrequencies.length; i++)
            Expanded(
              child: Column(
                children: [
                  Text(
                    gains[i] == 0
                        ? '0'
                        : '${gains[i] > 0 ? '+' : ''}${gains[i].round()}',
                    style: labelStyle,
                  ),
                  Expanded(
                    child: RotatedBox(
                      quarterTurns: 3,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 7,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 14,
                          ),
                        ),
                        child: Slider(
                          value: gains[i].clamp(
                            equalizerMinGainDb,
                            equalizerMaxGainDb,
                          ),
                          min: equalizerMinGainDb,
                          max: equalizerMaxGainDb,
                          divisions:
                              ((equalizerMaxGainDb - equalizerMinGainDb) * 2)
                                  .round(),
                          label: '${gains[i].toStringAsFixed(1)} dB',
                          onChanged: enabled
                              ? (value) => onChanged(i, value)
                              : null,
                        ),
                      ),
                    ),
                  ),
                  Text(_label(equalizerBandFrequencies[i]), style: labelStyle),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SliderItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final double value;
  final double min;
  final double max;
  final String display;
  final bool enabled;
  final ValueChanged<double> onChanged;
  final bool showDivider;

  const _SliderItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.enabled,
    required this.onChanged,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SettingsItem(
      icon: icon,
      title: title,
      subtitle: subtitle,
      showDivider: showDivider,
      trailing: SizedBox(
        width: 130,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              display,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: enabled ? null : scheme.outline,
              ),
            ),
            GlassSlider(
              value: ((value - min) / (max - min)).clamp(0.0, 1.0),
              enabled: enabled,
              onChanged: (v) => onChanged(min + (max - min) * v),
            ),
          ],
        ),
      ),
    );
  }
}
