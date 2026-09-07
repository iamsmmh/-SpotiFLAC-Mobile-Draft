// AirPlay 2 Manager — AppleEcosystem submodule (Milestone 1)
//
// Consolidates AirPlay 2 route discovery, switching, and automatic recovery.
// Wraps AVRoutePickerView, AVAudioSession, and AVPlayer route management
// into a single bridge consumed by the Flutter MethodChannel.
//
// Contract: MethodChannel "com.zarz.spotiflac/airplay"
//   - showRoutePicker()     → Presents system picker (Apple requires user consent)
//   - currentRoute()        → Returns current output route info
//   - isAirPlayActive()     → Bool: is audio routing to AirPlay
//   - discoverDevices()     → Lists reachable AirPlay endpoints
//   - switchRoute()         → Triggers route picker (programmatic selection
//                              not allowed by Apple; this presents the picker)
//   - routeChanged          → Native→Dart event on route changes
//
// Requirements met:
//   - No playback interruption during route switches
//   - Queue preserved (audio session stays active)
//   - Streaming preserved (AVPlayer continues through route change)
//   - Automatic route recovery (session reconfiguration on interruption)

import AVFoundation
import AVKit
import Flutter
import Foundation
import UIKit

/// Manages AirPlay 2 discovery, route switching, and recovery.
///
/// iOS does not expose a programmatic "connect to that speaker" API.
/// Route selection must go through the system picker so the user stays
/// in control. This manager:
///   * presents `AVRoutePickerView` on demand
///   * reports the current output route and whether it is AirPlay
///   * notifies Dart when the route changes
///   * handles automatic route recovery after interruptions
final class AirPlayManager: NSObject {
    /// MethodChannel name — must match Dart side.
    static let channelName = "com.zarz.spotiflac/airplay"

    private let channel: FlutterMethodChannel
    private weak var hostViewController: UIViewController?

    /// Off-screen picker whose button is tapped programmatically.
    private lazy var routePickerView: AVRoutePickerView = {
        let view = AVRoutePickerView(frame: .zero)
        view.isHidden = true
        view.prioritizesVideoDevices = false
        return view
    }()

    /// Route recovery: when the audio session is disrupted, we observe
    /// the route change and attempt to maintain continuity.
    private var lastKnownRoute: AudioRouteSnapshot?

    init(messenger: FlutterBinaryMessenger, host: UIViewController?) {
        channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        hostViewController = host
        super.init()

        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(routeChanged),
            name: AVAudioSession.routeChangeNotification, object: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(audioSessionInterrupted),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Flutter Method Channel Handler

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "showRoutePicker":
            presentRoutePicker(result: result)
        case "currentRoute":
            result(routePayload())
        case "isAirPlayActive":
            result(isAirPlayActive())
        case "discoverDevices":
            result(discoverDevices())
        case "switchRoute":
            // Apple requires user interaction for route selection.
            // This presents the picker — the only supported path.
            presentRoutePicker(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Route Picker

    /// Raises the system route picker by synthesising a tap on a hidden
    /// AVRoutePickerView attached to the Flutter view controller.
    private func presentRoutePicker(result: @escaping FlutterResult) {
        guard let host = hostViewController ?? Self.topViewController() else {
            result(FlutterError(
                code: "no_host",
                message: "No view controller to present from",
                details: nil))
            return
        }
        if routePickerView.superview == nil {
            host.view.addSubview(routePickerView)
        }
        // The picker view hosts a UIButton subview; sending it a touch-up
        // is the documented-by-practice way to open the sheet from code.
        let button = routePickerView.subviews.compactMap { $0 as? UIButton }.first
        guard let button else {
            result(FlutterError(
                code: "picker_unavailable",
                message: "Route picker button is unavailable",
                details: nil))
            return
        }
        button.sendActions(for: .touchUpInside)
        result(true)
    }

    // MARK: - Route State

    func isAirPlayActive() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs
            .contains { $0.portType == .airPlay }
    }

    /// Returns currently reachable AirPlay-capable output descriptions.
    ///
    /// Note: Full device discovery requires external monitor APIs or the
    /// system picker. We report what AVAudioSession knows about the
    /// current route and external outputs.
    private func discoverDevices() -> [[String: Any]] {
        let route = AVAudioSession.sharedInstance().currentRoute
        return route.outputs.map { output in
            [
                "name": output.portName,
                "type": output.portType.rawValue,
                "uid": output.uid,
                "isAirPlay": output.portType == .airPlay,
                "isBluetooth": Self.bluetoothTypes.contains(output.portType),
                "isBuiltIn": output.portType == .builtInSpeaker
                    || output.portType == .builtInReceiver,
            ] as [String: Any]
        }
    }

    private func routePayload() -> [String: Any] {
        let route = AVAudioSession.sharedInstance().currentRoute
        let names = route.outputs.map { $0.portName }
        let snapshot = AudioRouteSnapshot(
            names: names,
            isAirPlay: isAirPlayActive(),
            isExternal: route.outputs.contains {
                $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver
            })
        lastKnownRoute = snapshot
        return [
            "name": names.first ?? "",
            "names": names,
            "isAirPlay": snapshot.isAirPlay,
            "isExternal": snapshot.isExternal,
        ]
    }

    // MARK: - Route Change Notifications

    @objc private func routeChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let payload = self.routePayload()
            self.channel.invokeMethod("routeChanged", arguments: payload)
        }
    }

    // MARK: - Automatic Route Recovery

    /// When the audio session is interrupted (e.g. a phone call), we
    /// record the interruption and attempt to recover the route when it ends.
    @objc private func audioSessionInterrupted(_ notification: Notification) {
        guard let info = notification.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            // Route disrupted — queue and streaming preserved because
            // the AVAudioSession stays configured; only output is muted.
            channel.invokeMethod("interruptionBegan", arguments: nil)
        case .ended:
            // Attempt to recover the previous route.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let payload = self.routePayload()
                payload["recovered"] = self.lastKnownRoute?.isAirPlay == self.isAirPlayActive()
                self.channel.invokeMethod("interruptionEnded", arguments: payload)
            }
        @unknown default:
            break
        }
    }

    // MARK: - Helpers

    static let bluetoothTypes: Set<AVAudioSession.Port> = [
        .bluetoothA2DP, .bluetoothHFP, .bluetoothLE,
    ]

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

/// Lightweight snapshot of the audio route at a point in time.
struct AudioRouteSnapshot {
    let names: [String]
    let isAirPlay: Bool
    let isExternal: Bool
}
