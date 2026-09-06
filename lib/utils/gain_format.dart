/// Formatting for gain values shown in the audio engine surfaces.
///
/// Gain is displayed as a signed decibel value (`+2.5`, `-1.0`, `0.0`). The
/// same expression was inlined in the download ReplayGain writer, the advanced
/// audio page and the streaming settings page; it lives here so the sign and
/// precision cannot drift between surfaces.
library;

/// Formats [value] as a signed decibel magnitude with [decimals] places.
///
/// Zero is rendered unsigned (`0.0`); negative zero collapses to the same
/// string because `-0.0 < 0` is false in Dart.
String formatGainDb(double value, {int decimals = 1}) {
  final magnitude = value.abs().toStringAsFixed(decimals);
  if (value > 0) return '+$magnitude';
  if (value < 0) return '-$magnitude';
  return magnitude;
}
