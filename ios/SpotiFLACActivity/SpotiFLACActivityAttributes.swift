import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Shared Live Activity contract (Milestone 2).
///
/// Compiled into **both** the app target (which starts/updates/ends the
/// activity) and the widget-extension target (which renders it). The two
/// must agree byte-for-byte on this type or `Activity<Attributes>` lookups
/// silently fail at runtime, which is why it lives in one file rather than
/// being duplicated.
///
/// Requires iOS 16.1; every use site is availability-gated because the app
/// deploys to iOS 15.
#if canImport(ActivityKit)
@available(iOS 16.1, *)
struct SpotiFLACActivityAttributes: ActivityAttributes {
    /// The parts that change while the activity is live.
    public struct ContentState: Codable, Hashable {
        /// Track title.
        public var title: String
        /// Artist line.
        public var artist: String
        /// Whether audio is currently playing (drives the play/pause glyph).
        public var isPlaying: Bool
        /// Playback position in milliseconds at `updatedAt`.
        public var positionMs: Int
        /// Track duration in milliseconds; 0 when unknown (live streams).
        public var durationMs: Int
        /// When this state was produced, as epoch milliseconds.
        ///
        /// The widget derives a *self-advancing* progress bar from this plus
        /// `isPlaying` instead of requiring an update every second: Live
        /// Activity updates are rate-limited by the system, so a
        /// once-per-second push would be throttled and the bar would stutter.
        public var updatedAt: Int

        public init(
            title: String,
            artist: String,
            isPlaying: Bool,
            positionMs: Int,
            durationMs: Int,
            updatedAt: Int
        ) {
            self.title = title
            self.artist = artist
            self.isPlaying = isPlaying
            self.positionMs = positionMs
            self.durationMs = durationMs
            self.updatedAt = updatedAt
        }

        /// The interval the widget animates its progress bar across, so the
        /// UI keeps moving between throttled updates.
        public var progressInterval: ClosedRange<Date>? {
            guard durationMs > 0 else { return nil }
            let snapshot = Date(timeIntervalSince1970: Double(updatedAt) / 1000.0)
            let start = snapshot.addingTimeInterval(-Double(positionMs) / 1000.0)
            let end = start.addingTimeInterval(Double(durationMs) / 1000.0)
            guard end > start else { return nil }
            return start...end
        }

        /// Fraction played at the moment the state was produced.
        public var fractionComplete: Double {
            guard durationMs > 0 else { return 0 }
            return min(1, max(0, Double(positionMs) / Double(durationMs)))
        }
    }

    /// Fixed for the lifetime of the activity.
    public var albumTitle: String

    public init(albumTitle: String) {
        self.albumTitle = albumTitle
    }
}
#endif
