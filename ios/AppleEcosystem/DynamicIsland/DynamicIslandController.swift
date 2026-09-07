// Dynamic Island — AppleEcosystem submodule (Milestone 1)
//
// Manages Dynamic Island display for live playback information.
// Uses ActivityKit to present compact, expanded, and lock screen views.
//
// Display regions:
//   - Compact Leading:  Play/Pause glyph
//   - Compact Trailing: Track progress indicator
//   - Expanded (Supplementary): Artwork + Track + Artist
//   - Expanded (Content): Full now-playing with controls
//   - Lock Screen: Track + Artist + Progress bar
//
// Update triggers:
//   - Every playback state change (play/pause/seek)
//   - Every queue transition (track change)
//   - Periodic progress updates (rate-limited by ActivityKit)

import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif
import SwiftUI

/// Dynamic Island controller — manages the compact/expanded presentation
/// of now-playing information on supported devices.
///
/// Works in tandem with LiveActivityController. The Dynamic Island is
/// the compact presentation mode of a Live Activity on iOS 16.1+.
final class DynamicIslandController: NSObject {
    /// Channel name — shared with LiveActivityController.
    static let channelName = "com.zarz.spotiflac/live_activity"

    #if canImport(ActivityKit)
    @available(iOS 16.1, *)
    static func activityAttributes() -> SpotiFLACActivityAttributes {
        SpotiFLACActivityAttributes(albumTitle: "")
    }

    /// Returns the Dynamic Island presentation layout hints.
    /// These describe which content goes where in the Island.
    @available(iOS 16.1, *)
    static func islandLayout(for state: SpotiFLACActivityAttributes.ContentState) -> IslandLayout {
        return IslandLayout(
            compactLeading: state.isPlaying ? "▶" : "⏸",
            compactTrailing: state.fractionComplete,
            expandedArtwork: nil,  // Filled by widget extension
            expandedTitle: state.title,
            expandedArtist: state.artist,
            progressInterval: state.progressInterval
        )
    }
    #endif
}

/// Describes the Dynamic Island layout for a given playback state.
struct IslandLayout {
    let compactLeading: String
    let compactTrailing: Double
    let expandedArtwork: String?
    let expandedTitle: String
    let expandedArtist: String
    let progressInterval: ClosedRange<Date>?
}

/// Update policy for Dynamic Island content.
///
/// ActivityKit rate-limits updates, so we implement intelligent throttling:
/// - State changes (play/pause): immediate
/// - Track changes: immediate
/// - Progress: only when the widget can't interpolate (seek, >5s drift)
enum DynamicIslandUpdatePolicy {
    /// Whether an update from `old` to `new` should be sent immediately.
    static func shouldPush(
        from old: IslandUpdatePayload?,
        to new: IslandUpdatePayload
    ) -> Bool {
        guard let old = old else { return true }

        // Track change — always push.
        if old.title != new.title || old.artist != new.artist {
            return true
        }

        // State change — always push.
        if old.isPlaying != new.isPlaying {
            return true
        }

        // Seek detection: if position jumped by more than 5 seconds,
        // the widget's interpolation is wrong and needs correction.
        let positionDelta = abs(new.positionMs - old.positionMs)
        if positionDelta > 5000 {
            return true
        }

        // Otherwise, let the widget interpolate.
        return false
    }
}

/// Payload for an Island update, used by the update policy.
struct IslandUpdatePayload {
    let title: String
    let artist: String
    let isPlaying: Bool
    let positionMs: Int
    let durationMs: Int
}
