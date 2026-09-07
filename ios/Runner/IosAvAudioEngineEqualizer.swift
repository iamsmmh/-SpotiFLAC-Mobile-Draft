import AVFoundation
import Flutter
import Foundation

/// Optional AVAudioEngine parametric EQ (Phase 15).
///
/// The music pipeline still renders through AVPlayer — this graph is *not*
/// inserted into that path (see `applyAudioEffects` in AppDelegate). It exists
/// so a future AVAudioEngine renderer, CarPlay auxiliary output, or a user
/// who opts into the experimental engine can apply the same
/// `AudioEffectsSettings.toPlatformMap()` payload: 10 ISO bands, bass/treble
/// shelves, named presets. Detaching is a no-op when nothing is attached.
@available(iOS 13.0, *)
final class IosAvAudioEngineEqualizer: NSObject {
    static let channelName = "com.zarz.spotiflac/ios_eq"

    private let channel: FlutterMethodChannel
    private let engine = AVAudioEngine()
    private let eq = AVAudioUnitEQ(numberOfBands: 10)
    private var attached = false

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "capabilities":
            result([
                "equalizer": true,
                "bass_boost": true,
                "virtualizer": false,
                "enhancer": false,
                "compressor": false,
                "limiter": false,
                "engine": "AVAudioEngine parametric EQ",
            ])
        case "apply":
            let args = call.arguments as? [String: Any] ?? [:]
            apply(args)
            result(["attached": attached, "bands": eq.bands.count])
        case "detach":
            detach()
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Applies a Dart `IosAvAudioEngineEqPayload.toJson()` map.
    func apply(_ payload: [String: Any]) {
        let enabled = payload["enabled"] as? Bool ?? false
        guard enabled else {
            detach()
            return
        }
        let bands = payload["bands"] as? [[String: Any]] ?? []
        for (index, band) in eq.bands.enumerated() {
            band.filterType = .parametric
            band.bypass = false
            if index < bands.count {
                let entry = bands[index]
                if let hz = entry["frequency_hz"] as? NSNumber {
                    band.frequency = hz.floatValue
                }
                if let gain = entry["gain_db"] as? NSNumber {
                    band.gain = gain.floatValue
                }
                if let bw = entry["bandwidth_octaves"] as? NSNumber {
                    band.bandwidth = bw.floatValue
                } else {
                    band.bandwidth = 0.5
                }
            } else {
                band.bypass = true
            }
        }
        if !attached {
            engine.attach(eq)
            let format = engine.outputNode.inputFormat(forBus: 0)
            engine.connect(eq, to: engine.outputNode, format: format)
            attached = true
        }
    }

    func detach() {
        guard attached else { return }
        engine.disconnectNodeOutput(eq)
        engine.detach(eq)
        attached = false
    }
}
