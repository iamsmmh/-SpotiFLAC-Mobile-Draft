import Flutter
import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Live Activity / Dynamic Island lifecycle (Milestone 2), app side.
///
/// Dart drives this through `com.zarz.spotiflac/live_activity`:
/// `start` when playback begins, `update` on state changes, `end` when
/// playback stops. Rendering lives in the widget extension
/// (`ios/SpotiFLACActivity`).
///
/// Availability: ActivityKit is iOS 16.1+. On anything older every method
/// resolves `false` rather than erroring, so Dart can call them
/// unconditionally and simply observe that activities are unsupported.
final class LiveActivityController: NSObject {
    /// Channel name; mirrored by `lib/services/live_activity_service.dart`.
    static let channelName = "com.zarz.spotiflac/live_activity"

    private let channel: FlutterMethodChannel

    #if canImport(ActivityKit)
    /// The single in-flight activity. Music has one "now playing", so a
    /// second start replaces rather than stacks — otherwise the Dynamic
    /// Island fills with stale entries the user cannot dismiss.
    private var currentActivity: Any?
    #endif

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
    }

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

    private func isSupported() -> Bool {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            return ActivityAuthorizationInfo().areActivitiesEnabled
        }
        #endif
        return false
    }

    // MARK: - Lifecycle

    private func start(arguments: Any?, result: @escaping FlutterResult) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), ActivityAuthorizationInfo().areActivitiesEnabled else {
            result(false)
            return
        }
        guard let map = arguments as? [String: Any] else {
            result(false)
            return
        }
        // Replace any existing activity so only one "now playing" exists.
        endCurrentActivity()

        let attributes = SpotiFLACActivityAttributes(
            albumTitle: (map["album"] as? String) ?? "")
        let state = Self.contentState(from: map)

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil)
            currentActivity = activity
            result(true)
        } catch {
            // Most commonly the per-app activity budget is exhausted. This
            // is cosmetic, so report it without disturbing playback.
            NSLog("SpotiFLAC: Live Activity start failed: \(error.localizedDescription)")
            result(false)
        }
        #else
        result(false)
        #endif
    }

    private func update(arguments: Any?, result: @escaping FlutterResult) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *),
              let activity = currentActivity as? Activity<SpotiFLACActivityAttributes>,
              let map = arguments as? [String: Any]
        else {
            result(false)
            return
        }
        let state = Self.contentState(from: map)
        Task {
            await activity.update(.init(state: state, staleDate: nil))
            await MainActor.run { result(true) }
        }
        #else
        result(false)
        #endif
    }

    private func end(result: @escaping FlutterResult) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else {
            result(false)
            return
        }
        endCurrentActivity()
        result(true)
        #else
        result(false)
        #endif
    }

    #if canImport(ActivityKit)
    @available(iOS 16.1, *)
    private func endCurrentActivity() {
        guard let activity = currentActivity as? Activity<SpotiFLACActivityAttributes> else {
            return
        }
        currentActivity = nil
        Task {
            // .immediate: leaving the island populated after playback stops
            // is exactly the artefact users complain about.
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    @available(iOS 16.1, *)
    static func contentState(from map: [String: Any]) -> SpotiFLACActivityAttributes.ContentState {
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
