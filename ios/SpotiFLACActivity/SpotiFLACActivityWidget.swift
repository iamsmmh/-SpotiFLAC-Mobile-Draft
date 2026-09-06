import SwiftUI
import WidgetKit
#if canImport(ActivityKit)
import ActivityKit
#endif

#if canImport(ActivityKit)

/// Lock-screen Live Activity and Dynamic Island presentation (Milestone 2).
///
/// Lives in the widget-extension target. It reads `SpotiFLACActivityAttributes`
/// (shared with the app target) and renders three presentations Apple
/// requires: the lock-screen banner, the expanded island, and the
/// compact/minimal island.
///
/// Progress is driven by `ProgressView(timerInterval:)` rather than a static
/// fraction, so the bar keeps advancing between the system's rate-limited
/// updates instead of freezing until the next push.
@available(iOS 16.1, *)
struct SpotiFLACActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SpotiFLACActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "music.note")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.state.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressBar(state: context.state)
                }
            } compactLeading: {
                Image(systemName: "music.note")
                    .foregroundStyle(.tint)
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .foregroundStyle(.tint)
            } minimal: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .foregroundStyle(.tint)
            }
            .keylineTint(.accentColor)
        }
    }
}

/// Lock-screen / banner presentation.
@available(iOS 16.1, *)
private struct LockScreenView: View {
    let context: ActivityViewContext<SpotiFLACActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.title)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(context.state.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(context.state.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressBar(state: context.state)
            }

            Image(systemName: context.state.isPlaying ? "speaker.wave.2.fill" : "pause.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
        }
        .padding()
    }
}

/// Self-advancing progress bar.
@available(iOS 16.1, *)
private struct ProgressBar: View {
    let state: SpotiFLACActivityAttributes.ContentState

    var body: some View {
        if let interval = state.progressInterval, state.isPlaying {
            // While playing, let SwiftUI animate across the real interval:
            // the bar stays smooth even though ActivityKit throttles updates.
            ProgressView(timerInterval: interval, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.linear)
            .tint(.white)
        } else if state.durationMs > 0 {
            // Paused: freeze at the last known position.
            ProgressView(value: state.fractionComplete)
                .progressViewStyle(.linear)
                .tint(.white)
        } else {
            EmptyView()
        }
    }
}

#endif
