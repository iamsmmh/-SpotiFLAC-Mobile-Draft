/// Smart-offline admission policy (Phase 2).
///
/// Auto-downloads of liked songs, Discover Weekly, Daily Mixes and playlists
/// marked offline only run when the device satisfies the user's rules:
///
///   * Wi-Fi only (default on)
///   * Charging only (default on)
///   * Battery above a configurable threshold
///
/// Pure: the scheduler supplies [OfflineDeviceState]; this file never
/// reads platform sensors.
library;

/// Live device facts the scheduler sampled.
class OfflineDeviceState {
  const OfflineDeviceState({
    required this.wifi,
    required this.charging,
    required this.batteryPercent,
    this.online = true,
  });

  final bool wifi;
  final bool charging;

  /// 0–100. Unknown / unavailable is represented as -1 (treated as "allow"
  /// the battery gate so a missing sensor never blocks offline sync).
  final int batteryPercent;
  final bool online;

  bool get batteryKnown => batteryPercent >= 0;
}

/// User-configurable rules. Defaults match Spotify's offline-download
/// conservatism (Wi-Fi + charging).
class OfflineSyncRules {
  const OfflineSyncRules({
    this.wifiOnly = true,
    this.chargingOnly = true,
    this.minBatteryPercent = 20,
    this.enabled = true,
  });

  final bool wifiOnly;
  final bool chargingOnly;

  /// Inclusive lower bound. Clamped to 0–100.
  final int minBatteryPercent;
  final bool enabled;

  OfflineSyncRules copyWith({
    bool? wifiOnly,
    bool? chargingOnly,
    int? minBatteryPercent,
    bool? enabled,
  }) {
    final battery = minBatteryPercent ?? this.minBatteryPercent;
    return OfflineSyncRules(
      wifiOnly: wifiOnly ?? this.wifiOnly,
      chargingOnly: chargingOnly ?? this.chargingOnly,
      minBatteryPercent: battery < 0
          ? 0
          : battery > 100
              ? 100
              : battery,
      enabled: enabled ?? this.enabled,
    );
  }
}

/// Collections the scheduler is allowed to auto-download.
enum OfflineCollectionKind {
  likedSongs,
  discoverWeekly,
  dailyMixes,
  markedPlaylists,
}

/// Admission outcome with a reason the UI can show ("Waiting for Wi-Fi").
class OfflineAdmission {
  const OfflineAdmission.allow(this.reason) : isAllowed = true;

  const OfflineAdmission.deny(this.reason) : isAllowed = false;

  final bool isAllowed;
  final String reason;
}

/// Pure gate.
class OfflineSyncPolicy {
  const OfflineSyncPolicy({this.rules = const OfflineSyncRules()});

  final OfflineSyncRules rules;

  OfflineAdmission admission(OfflineDeviceState state) {
    if (!rules.enabled) {
      return const OfflineAdmission.deny('offline sync disabled');
    }
    if (!state.online) {
      return const OfflineAdmission.deny('offline');
    }
    if (rules.wifiOnly && !state.wifi) {
      return const OfflineAdmission.deny('waiting for Wi-Fi');
    }
    if (rules.chargingOnly && !state.charging) {
      return const OfflineAdmission.deny('waiting for charger');
    }
    if (state.batteryKnown && state.batteryPercent < rules.minBatteryPercent) {
      return OfflineAdmission.deny(
        'battery below ${rules.minBatteryPercent}%',
      );
    }
    return const OfflineAdmission.allow('conditions met');
  }
}
