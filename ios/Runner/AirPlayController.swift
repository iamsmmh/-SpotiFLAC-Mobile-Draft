import AVFoundation
import AVKit
import Flutter
import Foundation
import UIKit

/// AirPlay 2 route discovery and switching (Milestone 2).
///
/// iOS deliberately does not expose a programmatic "play on that speaker"
/// API: route selection must go through the system route picker so the user
/// stays in control. What an app *can* do — and what this does — is:
///
///   * present `AVRoutePickerView`'s picker on demand;
///   * report the current output route and whether it is AirPlay;
///   * notify Dart when the route changes, so the now-playing UI can show
///     the speaker name.
///
/// Background playback and continuity across a route switch are properties
/// of the audio session (see AudioSessionController) plus the `audio`
/// background mode in Info.plist; nothing extra is needed here as long as
/// the session stays active across the change.
final class AirPlayController: NSObject {
    /// Channel name; mirrored by `lib/services/apple_integration_service.dart`.
    static let channelName = "com.zarz.spotiflac/airplay"

    private let channel: FlutterMethodChannel
    private weak var hostViewController: UIViewController?

    /// Off-screen picker whose button is tapped programmatically. Apple
    /// provides no other way to raise the route sheet from code.
    private lazy var routePickerView: AVRoutePickerView = {
        let view = AVRoutePickerView(frame: .zero)
        view.isHidden = true
        view.prioritizesVideoDevices = false
        return view
    }()

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
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "showRoutePicker":
            presentRoutePicker(result: result)
        case "currentRoute":
            result(routePayload())
        case "isAirPlayActive":
            result(isAirPlayActive())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Raises the system route picker by synthesising a tap on a hidden
    /// AVRoutePickerView attached to the Flutter view controller.
    private func presentRoutePicker(result: @escaping FlutterResult) {
        guard let host = hostViewController ?? Self.topViewController() else {
            result(FlutterError(code: "no_host",
                                message: "No view controller to present from", details: nil))
            return
        }
        if routePickerView.superview == nil {
            host.view.addSubview(routePickerView)
        }
        // The picker view hosts a UIButton subview; sending it a touch-up is
        // the documented-by-practice way to open the sheet from code.
        let button = routePickerView.subviews.compactMap { $0 as? UIButton }.first
        guard let button else {
            result(FlutterError(code: "picker_unavailable",
                                message: "Route picker button is unavailable", details: nil))
            return
        }
        button.sendActions(for: .touchUpInside)
        result(true)
    }

    private func isAirPlayActive() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs
            .contains { $0.portType == .airPlay }
    }

    private func routePayload() -> [String: Any] {
        let route = AVAudioSession.sharedInstance().currentRoute
        let names = route.outputs.map { $0.portName }
        return [
            "name": names.first ?? "",
            "names": names,
            "isAirPlay": isAirPlayActive(),
            "isExternal": route.outputs.contains {
                $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver
            },
        ]
    }

    @objc private func routeChanged() {
        // Hop to the main queue: route notifications arrive on an internal
        // audio queue, and Flutter channels are main-thread only.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.channel.invokeMethod("routeChanged", arguments: self.routePayload())
        }
    }

    /// Best-effort top view controller, used when the Flutter controller was
    /// not supplied.
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
