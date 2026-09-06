import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/providers/download_schedule_settings_provider.dart';
import 'package:spotiflac_android/theme/app_tokens.dart';
import 'package:spotiflac_android/widgets/app_sliver_header.dart';
import 'package:spotiflac_android/widgets/settings_group.dart';

/// Settings → Download → Download scheduling.
///
/// Lets users restrict auto-starting downloads to a time window (for example a
/// nightly window) and/or device conditions (charging, minimum battery,
/// WiFi). When the schedule closes, the queue pauses; when it reopens, the
/// queue resumes automatically.
class DownloadScheduleSettingsPage extends ConsumerWidget {
  const DownloadScheduleSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(downloadScheduleSettingsProvider);
    final notifier = ref.read(downloadScheduleSettingsProvider.notifier);

    return CustomScrollView(
      slivers: [
        AppSliverHeader.page(title: 'Download scheduling'),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              context.tokens.pagePadding,
              context.tokens.pagePadding * 0.5,
              context.tokens.pagePadding,
              context.tokens.pagePadding * 0.5,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SettingsGroup(
                  children: [
                    SettingsSwitchItem(
                      icon: Icons.schedule_outlined,
                      title: 'Scheduled downloads',
                      subtitle:
                          'Pause the queue outside the window and resume it automatically',
                      value: settings.enabled,
                      onChanged: notifier.setEnabled,
                    ),
                    _TimeItem(
                      icon: Icons.wb_twilight_outlined,
                      title: 'Start',
                      subtitle: 'Downloads may begin at this time',
                      label: settings.startLabel,
                      enabled: settings.enabled,
                      onChanged: (value) => notifier.setStartMinute(value),
                    ),
                    _TimeItem(
                      icon: Icons.dark_mode_outlined,
                      title: 'End',
                      subtitle: 'Wait until this time before resuming',
                      label: settings.endLabel,
                      enabled: settings.enabled,
                      onChanged: (value) => notifier.setEndMinute(value),
                      showDivider: false,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'A window that ends earlier than it starts crosses midnight, '
                  'e.g. 22:00 → 07:00. Equal start and end times mean "any '
                  'time" so only the conditions below apply.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                _SectionLabel('Conditions'),
                SettingsGroup(
                  children: [
                    SettingsSwitchItem(
                      icon: Icons.wifi_rounded,
                      title: 'Only on WiFi',
                      subtitle:
                          'Hold scheduled downloads on mobile data (independent of the global network mode)',
                      value: settings.requireWifi,
                      enabled: settings.enabled,
                      onChanged: settings.enabled
                          ? notifier.setRequireWifi
                          : null,
                    ),
                    SettingsSwitchItem(
                      icon: Icons.battery_charging_full_rounded,
                      title: 'Only while charging',
                      subtitle: 'Wait for a charger before downloading',
                      value: settings.requireCharging,
                      enabled: settings.enabled,
                      onChanged: settings.enabled
                          ? notifier.setRequireCharging
                          : null,
                    ),
                    _BatteryFloorItem(
                      value: settings.minBatteryPercent,
                      enabled: settings.enabled && !settings.requireCharging,
                      onChanged: notifier.setMinBatteryPercent,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _SectionLabel('Presets'),
                SettingsGroup(
                  children: [
                    SettingsItem(
                      icon: Icons.nightlight_round,
                      title: 'Overnight',
                      subtitle: '22:00 → 07:00, no device conditions',
                      onTap: notifier.applyNightPreset,
                    ),
                    SettingsItem(
                      icon: Icons.power_rounded,
                      title: 'Charging on WiFi',
                      subtitle: 'Any time, only while plugged in and on WiFi',
                      onTap: notifier.applyChargingWifiPreset,
                      showDivider: false,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TimeItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String label;
  final bool enabled;
  final ValueChanged<int> onChanged;
  final bool showDivider;

  const _TimeItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.label,
    required this.enabled,
    required this.onChanged,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsItem(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: Text(
        label,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
      onTap: enabled ? () => _pickTime(context) : null,
      showDivider: showDivider,
    );
  }

  Future<void> _pickTime(BuildContext context) async {
    final initial = _parseMinute(label);
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: initial ~/ 60, minute: initial % 60),
    );
    if (picked == null) return;
    onChanged(picked.hour * 60 + picked.minute);
  }

  int _parseMinute(String value) {
    final parts = value.split(':');
    if (parts.length != 2) return 0;
    final hour = int.tryParse(parts[0]) ?? 0;
    final minute = int.tryParse(parts[1]) ?? 0;
    return hour * 60 + minute;
  }
}

/// "Not below N%" battery floor. Disabled while "Only while charging" is on
/// (a plugged-in device is never held back by its battery level).
class _BatteryFloorItem extends StatelessWidget {
  final int value;
  final bool enabled;
  final ValueChanged<int> onChanged;

  const _BatteryFloorItem({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  static const List<int> _choices = [0, 15, 20, 30, 50];

  @override
  Widget build(BuildContext context) {
    final label = value <= 0 ? 'Off' : 'Below $value%';
    return SettingsItem(
      icon: Icons.battery_alert_rounded,
      title: 'Minimum battery',
      subtitle: 'Pause when unplugged and the battery drops under this level',
      trailing: Text(
        label,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: enabled
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
      onTap: enabled ? () => _pick(context) : null,
      showDivider: false,
    );
  }

  Future<void> _pick(BuildContext context) async {
    final colorScheme = Theme.of(context).colorScheme;
    final picked = await showModalBottomSheet<int>(
      context: context,
      useRootNavigator: true,
      backgroundColor: colorScheme.surfaceContainerHigh,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            for (final choice in _choices)
              ListTile(
                leading: Icon(
                  choice <= 0
                      ? Icons.battery_unknown_rounded
                      : Icons.battery_alert_rounded,
                ),
                title: Text(choice <= 0 ? 'Off' : 'Pause below $choice%'),
                trailing: choice == value
                    ? Icon(Icons.check, color: colorScheme.primary)
                    : null,
                onTap: () => Navigator.pop(sheetContext, choice),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked != null) onChanged(picked);
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
