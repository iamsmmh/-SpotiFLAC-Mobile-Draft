// Live Activities — AppleEcosystem submodule (Milestone 1)
//
// Manages Live Activity lifecycle for lock-screen and Dynamic Island
// presentation of now-playing information.
//
// Uses ActivityKit (iOS 16.1+) with backward-compatible branching:
//   - iOS 16.2+: ActivityContent-based API (request/update/end)
//   - iOS 16.1: contentState-based API (deprecated but present)
//   - <16.1: no-ops gracefully
//
// Update triggers:
//   - Every playback state change (play/pause/seek)
//   - Every queue transition (track change)
//   - Rate-limited to avoid exceeding ActivityKit budget

import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif
import Flutter

/// Live Activity lifecycle manager.
///
/// Dart drives this through `com.zarz.spotiflac/live_activity`:
///   - `start`  → when playback begins
///   - `update` → on state changes (throttled)
///   - `end`    → when playback stops
///
/// Rendering lives in the widget extension (ios/SpotiFLACActivity).
final class LiveActivityController: NSObject {
    /// Channel name — mirrored by Dart side.
    static let channelName = "com.zarz.spotiflac/live_activity"

    private let channel: FlutterMethodChannel

    #if canImport(ActivityKit)
    /// The single in-flight activity. Music has one "now playing",
    /// so a second start replaces rather than stacks.
    private var currentActivity: Any?
    #endif

    /// Tracks the last pushed state for throttling decisions.
    private var lastPushedPayload: IslandUpdatePayload?

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
    }

    // MARK: - Channel Handler

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isSupported":
            result(isSupported())
        case "start":
            start(arguments: call.arguments, result: result)
        case "update":
            update(arguments: call.arguments, result: result)
        case "end":
            end(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Support Check

    private func isSupported() -> Bool {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            return ActivityAuthorizationInfo().areActivitiesEnabled
        }
        #endif
        return false
    }

    // MARK: - Start

    private func start(arguments: Any?, result: @escaping FlutterResult) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *),
              ActivityAuthorizationInfo().areActivitiesEnabled,
              let map = arguments as? [String: Any]
        else {
            result(false)
            return
        }

        // Replace any existing activity.
        endCurrentActivity()

        let attributes = SpotiFLACActivityAttributes(
            albumTitle: (map["album"] as? String) ?? "")
        let state = Self.contentState(from: map)
        lastPushedPayload = IslandUpdatePayload(
            title: state.title,
            artist: state.artist,
            isPlaying: state.isPlaying,
            positionMs: state.positionMs,
            durationMs: state.durationMs
        )

        do {
            let activity: Activity<SpotiFLACActivityAttributes>
            if #available(iOS 16.2, *) {
                activity = try Activity.request(
                    attributes: attributes,
                    content: .init(state: state, staleDate: nil),
                    pushType: nil)
            } else {
                // iOS 16.1 only (deprecated in 16.2 but still present).
                activity = try Activity.request(
                    attributes: attributes,
                    contentState: state,
                    pushType: nil)
            }
            currentActivity = activity
            result(true)
        } catch {
            NSLog("SpotiFLAC: Live Activity start failed: \(error.localizedDescription)")
            result(false)
        }
        #else
        result(false)
        #endif
    }

    // MARK: - Update

    private func update(arguments: Any?, result: @escaping FlutterResult) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *),
              let activity = currentActivity as? Activity<SpotiFLACActivityAttributes>,
              let map = arguments as? [String: Any]
        else {
            result(false)
            return
        }

        let newState = Self.contentState(from: map)
        let newPayload = IslandUpdatePayload(
            title: newState.title,
            artist: newState.artist,
            isPlaying: newState.isPlaying,
            positionMs: newState.positionMs,
            durationMs: newState.durationMs
        )

        // Apply the update policy: only push when the widget can't
        // interpolate correctly.
        if !DynamicIslandUpdatePolicy.shouldPush(from: lastPushedPayload, to: newPayload) {
            result(true)  // Acknowledge without pushing.
            return
        }
        lastPushedPayload = newPayload

        Task {
            if #available(iOS 16.2, *) {
                await activity.update(.init(state: newState, staleDate: nil))
            } else {
                await activity.update(using: newState)
            }
            await MainActor.run { result(true) }
        }
        #else
        result(false)
        #endif
    }

    // MARK: - End

    private func end(result: @escaping FlutterResult) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else {
            result(false)
            return
        }
        endCurrentActivity()
        lastPushedPayload = nil
        result(true)
        #else
        result(false)
        #endif
    }

    // MARK: - Helpers

    #if canImport(ActivityKit)
    @available(iOS 16.1, *)
    private func endCurrentActivity() {
        guard let activity = currentActivity as? Activity<SpotiFLACActivityAttributes> else {
            return
        }
        currentActivity = nil
        Task {
            // .immediate: leaving the island populated after playback
            // stops is exactly the artefact users complain about.
            if #available(iOS 16.2, *) {
                await activity.end(nil, dismissalPolicy: .immediate)
            } else {
                await activity.end(using: nil, dismissalPolicy: .immediate)
            }
        }
    }

    @available(iOS 16.1, *)
    static func contentState(
        from map: [String: Any]
    ) -> SpotiFLACActivityAttributes.ContentState {
        SpotiFLACActivityAttributes.ContentState(
            title: (map["title"] as? String) ?? "",
            artist: (map["artist"] as? String) ?? "",
            isPlaying: (map["isPlaying"] as? Bool) ?? false,
            positionMs: (map["positionMs"] as? Int) ?? 0,
            durationMs: (map["durationMs"] as? Int) ?? 0,
            updatedAt: (map["updatedAt"] as? Int)
                ?? Int(Date().timeIntervalSince1970 * 1000)
        )
    }
    #endif
}
