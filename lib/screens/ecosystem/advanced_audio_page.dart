import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotimusic/engine/advanced_audio.dart';
import 'package:spotimusic/providers/advanced_audio_provider.dart';
import 'package:spotimusic/widgets/app_sliver_header.dart';
import 'package:spotimusic/widgets/settings_group.dart';

/// Advanced audio (Feature Group: advanced audio): parametric EQ, bass and
/// vocal boost, headphone profiles, crossfeed, convolver, loudness target
/// and full-chain presets — applied through the existing platform DSP path.
///
/// Capability honesty (same precedent as the iOS equalizer): crossfeed
/// equalization and the convolver apply where the platform supports them;
/// the loudness policy rides the existing ReplayGain normalization path.
class AdvancedAudioPage extends ConsumerWidget {
  const AdvancedAudioPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chain = ref.watch(advancedAudioProvider);
    final presets = ref.watch(dspPresetsProvider);
    final notifier = ref.read(advancedAudioProvider.notifier);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: 'Advanced audio'),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SettingsGroup(
                    children: [
                      SettingsSwitchItem(
                        title: 'Enable advanced chain',
                        subtitle:
                            'Parametric EQ, boosts and profiles flatten onto '
                            'the system equalizer',
                        value: chain.enabled,
                        onChanged: notifier.setEnabled,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SettingsGroup(
                    children: [
                      const SettingsSectionHeader(title: 'Presets'),
                      presets.when(
                        data: (list) => Wrap(
                          spacing: 8,
                          children: [
                            for (final preset in list)
                              ActionChip(
                                label: Text(preset.name),
                                onPressed: chain.enabled
                                    ? () => notifier.applyPreset(preset)
                                    : null,
                              ),
                          ],
                        ),
                        loading: () => const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('…'),
                        ),
                        error: (error, _) => Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text('$error'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _BoostCard(
                    title: 'Bass boost',
                    subtitle: 'Low shelf at 90 Hz, up to +9 dB',
                    enabled: chain.bassBoost.enabled,
                    amount: chain.bassBoost.amount,
                    onEnabled: (value) => notifier.setBassBoost(
                      chain.bassBoost.copyWith(enabled: value),
                    ),
                    onAmount: (value) => notifier.setBassBoost(
                      chain.bassBoost.copyWith(amount: value),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _BoostCard(
                    title: 'Vocal boost',
                    subtitle: 'Presence lift at 2.8 kHz with mud cut',
                    enabled: chain.vocalBoost.enabled,
                    amount: chain.vocalBoost.amount,
                    onEnabled: (value) => notifier.setVocalBoost(
                      chain.vocalBoost.copyWith(enabled: value),
                    ),
                    onAmount: (value) => notifier.setVocalBoost(
                      chain.vocalBoost.copyWith(amount: value),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const SettingsSectionHeader(title: 'Headphone profile'),
                  SettingsGroup(
                    children: [
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final profile in HeadphoneProfile.values)
                            ChoiceChip(
                              label: Text(profile.title),
                              selected: chain.headphoneProfile == profile,
                              onSelected: chain.enabled
                                  ? (selected) {
                                      if (selected) {
                                        notifier.setHeadphoneProfile(profile);
                                      }
                                    }
                                  : null,
                            ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _BoostCard(
                    title: 'Crossfeed',
                    subtitle:
                        'bs2b-style speaker blend for headphones '
                        '(equalization stage)',
                    enabled: chain.crossfeed.enabled,
                    amount: chain.crossfeed.level,
                    onEnabled: (value) => notifier.setCrossfeed(
                      chain.crossfeed.copyWith(enabled: value),
                    ),
                    onAmount: (value) => notifier.setCrossfeed(
                      chain.crossfeed.copyWith(level: value),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const SettingsSectionHeader(title: 'Loudness normalization'),
                  SettingsGroup(
                    children: [
                      SettingsSwitchItem(
                        title: 'Normalize playback',
                        subtitle:
                            'Rides the existing ReplayGain path; quiet masters '
                            'get up to +${chain.loudness.preampDbMax.toStringAsFixed(0)} dB',
                        value: chain.loudness.enabled,
                        onChanged: (value) => notifier.setLoudness(
                          chain.loudness.copyWith(enabled: value),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const SettingsSectionHeader(title: 'Parametric EQ'),
                  SettingsGroup(
                    children: [
                      for (var i = 0; i < chain.equalizer.bands.length; i++)
                        _BandRow(
                          band: chain.equalizer.bands[i],
                          onChanged: chain.enabled
                              ? (band) => notifier.updateBandAt(i, band)
                              : null,
                          onRemove: chain.enabled
                              ? () => notifier.removeBandAt(i)
                              : null,
                        ),
                      if (chain.equalizer.bands.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('No bands yet — add one below.'),
                        ),
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: OutlinedButton.icon(
                          onPressed: chain.enabled
                              ? () => notifier.addBand(
                                  const ParametricBand(
                                    type: ParametricFilterType.peaking,
                                    frequencyHz: 1000,
                                    gainDb: 3,
                                    q: 1,
                                  ),
                                )
                              : null,
                          icon: const Icon(Icons.add),
                          label: const Text('Add band'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BoostCard extends StatelessWidget {
  const _BoostCard({
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.amount,
    required this.onEnabled,
    required this.onAmount,
  });

  final String title;
  final String subtitle;
  final bool enabled;
  final double amount;
  final ValueChanged<bool> onEnabled;
  final ValueChanged<double> onAmount;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionHeader(title: title),
        SettingsGroup(
          children: [
            SettingsSwitchItem(
              title: 'Enable',
              subtitle: subtitle,
              value: enabled,
              onChanged: onEnabled,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  const Text('Amount'),
                  Expanded(
                    child: Slider(
                      value: amount,
                      onChanged: enabled ? onAmount : null,
                    ),
                  ),
                  Text('${(amount * 100).round()}%'),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _BandRow extends StatelessWidget {
  const _BandRow({
    required this.band,
    required this.onChanged,
    required this.onRemove,
  });

  final ParametricBand band;
  final ValueChanged<ParametricBand>? onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${band.type.label} · ${band.frequencyHz.toStringAsFixed(0)} Hz '
              '· ${band.gainDb >= 0 ? '+' : ''}${band.gainDb.toStringAsFixed(1)} dB '
              '· Q ${band.q.toStringAsFixed(1)}',
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Remove band',
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
