import AVFoundation
import Foundation
import Flutter

/// AVAudioSession ownership for SpotiFLAC (Milestone 2).
///
/// `audio_session` (the Flutter plugin) configures the *category*, but it
/// does not surface the events a music app has to react to: interruptions
/// from a phone call, a Bluetooth device connecting mid-track, or headphones
/// being unplugged. Those arrive as `AVAudioSession` notifications and are
/// forwarded to Dart here so the player can pause, resume, or stop according
/// to Apple's rules rather than guessing.
///
/// Why this is native rather than Dart: the notifications carry
/// `AVAudioSession.InterruptionOptions` / `RouteChangeReason`, which have no
/// Flutter equivalent, and the "should resume" decision must be made inside
/// the interruption-ended callback to be honoured by the system.
final class AudioSessionController: NSObject {
    /// Channel name; mirrored by `lib/services/apple_integration_service.dart`.
    static let channelName = "com.zarz.spotiflac/audio_session"

    private let channel: FlutterMethodChannel
    private let session = AVAudioSession.sharedInstance()

    /// Whether playback was interrupted by the system (as opposed to the
    /// user pausing). Only a system interruption may auto-resume.
    private var wasInterrupted = false

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        observe()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Method channel

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "activate":
            do {
                try session.setActive(true, options: [])
                result(true)
            } catch {
                result(FlutterError(code: "activate_failed",
                                    message: error.localizedDescription, details: nil))
            }
        case "deactivate":
            do {
                // NotifyOthersOnDeactivation lets a paused podcast app or the
                // system resume where it left off, which is the behaviour
                // users expect after our playback ends.
                try session.setActive(false, options: [.notifyOthersOnDeactivation])
                result(true)
            } catch {
                result(FlutterError(code: "deactivate_failed",
                                    message: error.localizedDescription, details: nil))
            }
        case "currentRoute":
            result(currentRoutePayload())
        case "isOtherAudioPlaying":
            result(session.isOtherAudioPlaying)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Notifications

    private func observe() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleInterruption(_:)),
                           name: AVAudioSession.interruptionNotification, object: session)
        center.addObserver(self, selector: #selector(handleRouteChange(_:)),
                           name: AVAudioSession.routeChangeNotification, object: session)
        center.addObserver(self, selector: #selector(handleMediaServicesReset(_:)),
                           name: AVAudioSession.mediaServicesWereResetNotification, object: session)
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            wasInterrupted = true
            channel.invokeMethod("interruptionBegan", arguments: nil)
        case .ended:
            var shouldResume = false
            if let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                // .shouldResume is the system telling us the interrupting
                // audio finished cleanly. Resuming without it (e.g. after the
                // user answered a call and kept talking) is against the HIG
                // and gets apps rejected.
                shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                    .contains(.shouldResume)
            }
            let resume = shouldResume && wasInterrupted
            wasInterrupted = false
            channel.invokeMethod("interruptionEnded", arguments: ["shouldResume": resume])
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let rawReason = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        else { return }

        var payload = currentRoutePayload()
        payload["reason"] = describe(reason)

        // Unplugging headphones (or a Bluetooth device going away) must pause
        // rather than blast the track out of the speaker. Apple models both
        // as `.oldDeviceUnavailable`.
        payload["shouldPause"] = (reason == .oldDeviceUnavailable)

        channel.invokeMethod("routeChanged", arguments: payload)
    }

    @objc private func handleMediaServicesReset(_ notification: Notification) {
        // The audio server crashed: every session object is invalid and has
        // to be rebuilt from scratch. Dart re-creates the player.
        wasInterrupted = false
        channel.invokeMethod("mediaServicesReset", arguments: nil)
    }

    // MARK: - Route description

    private func currentRoutePayload() -> [String: Any] {
        let route = session.currentRoute
        let outputs = route.outputs.map { output -> [String: Any] in
            [
                "name": output.portName,
                "type": output.portType.rawValue,
                "uid": output.uid,
                "isAirPlay": output.portType == .airPlay,
                "isBluetooth": Self.bluetoothPortTypes.contains(output.portType),
                "isHeadphones": output.portType == .headphones,
                "isBuiltIn": output.portType == .builtInSpeaker
                    || output.portType == .builtInReceiver,
            ]
        }
        return [
            "outputs": outputs,
            "isAirPlay": route.outputs.contains { $0.portType == .airPlay },
            "isBluetooth": route.outputs.contains { Self.bluetoothPortTypes.contains($0.portType) },
        ]
    }

    static let bluetoothPortTypes: Set<AVAudioSession.Port> = [
        .bluetoothA2DP, .bluetoothHFP, .bluetoothLE,
    ]

    private func describe(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .unknown: return "unknown"
        case .newDeviceAvailable: return "newDeviceAvailable"
        case .oldDeviceUnavailable: return "oldDeviceUnavailable"
        case .categoryChange: return "categoryChange"
        case .override: return "override"
        case .wakeFromSleep: return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
        case .routeConfigurationChange: return "routeConfigurationChange"
        @unknown default: return "unknown"
        }
    }
}
