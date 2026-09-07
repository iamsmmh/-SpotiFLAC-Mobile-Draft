import Flutter
import Foundation
import Intents

/// Siri media control (Milestone 2).
///
/// Uses **SiriKit `INPlayMediaIntent`** rather than the newer App Intents
/// framework: App Intents' `AudioPlaybackIntent` requires iOS 16, while this
/// app deploys to iOS 15, and `INPlayMediaIntent` is still the API CarPlay
/// and "Hey Siri, play …" route through for media apps.
///
/// The intent is resolved *in-process* (the app declares
/// `INPlayMediaIntent` in `NSUserActivityTypes` and handles it via
/// `application(_:handle:)`), so no separate Intents extension target is
/// needed — one fewer target to provision, and the handler can talk straight
/// to the running Flutter engine.
///
/// Supported utterances map to Dart as:
///
///   "play <song>"    → kind: "track"
///   "play <album>"   → kind: "album"
///   "play <artist>"  → kind: "artist"
///   "play <playlist>"→ kind: "playlist"
///   "resume"         → kind: "resume"
@available(iOS 15.0, *)
final class SiriIntentHandler: NSObject, INPlayMediaIntentHandling {
    /// Channel name; mirrored by `lib/services/siri_service.dart`.
    static let channelName = "com.zarz.spotiflac/siri"

    private let channel: FlutterMethodChannel

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        super.init()
    }

    // MARK: - INPlayMediaIntentHandling

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        let request = Self.describe(intent)

        // Siri gives the app a short window to respond. Dart replies as soon
        // as it has *accepted* the request (not when audio starts), and a
        // failure to reply still resolves — leaving Siri hanging is worse
        // than reporting an honest failure.
        var settled = false
        let finish: (INPlayMediaIntentResponseCode) -> Void = { code in
            guard !settled else { return }
            settled = true
            completion(INPlayMediaIntentResponse(code: code, userActivity: nil))
        }

        channel.invokeMethod("play", arguments: request) { response in
            if let accepted = response as? Bool, accepted {
                finish(.success)
            } else if response is FlutterError {
                finish(.failure)
            } else {
                finish(.failureUnknownMediaType)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            // `.continueInApp` tells Siri to foreground the app rather than
            // claim a success that never happened.
            finish(.continueInApp)
        }
    }

    func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        // The app searches its own library at play time (Dart owns the
        // extension/provider ladder), so the spoken phrase is passed through
        // unresolved rather than forcing a disambiguation UI on the user.
        guard let items = intent.mediaItems, !items.isEmpty else {
            completion([INPlayMediaMediaItemResolutionResult.unsupported()])
            return
        }
        completion(INPlayMediaMediaItemResolutionResult.successes(with: items))
    }

    // MARK: - Intent → Dart payload

    /// Flattens the intent into the arguments Dart expects.
    static func describe(_ intent: INPlayMediaIntent) -> [String: Any] {
        let item = intent.mediaItems?.first
        let search = intent.mediaSearch

        var kind = "resume"
        if let type = item?.type ?? search?.mediaType {
            kind = describe(type)
        }
        // A search with no media items and no name is a bare "resume".
        let title = item?.title ?? search?.mediaName

        var payload: [String: Any] = ["kind": kind]
        payload["title"] = title ?? ""
        payload["artist"] = item?.artist ?? search?.artistName ?? ""
        payload["album"] = search?.albumName ?? ""
        payload["identifier"] = item?.identifier ?? ""
        payload["shuffle"] = (intent.playShuffled ?? false)
        if title == nil || title?.isEmpty == true {
            payload["kind"] = "resume"
        }
        return payload
    }

    static func describe(_ type: INMediaItemType) -> String {
        switch type {
        case .song, .music: return "track"
        case .album: return "album"
        case .artist: return "artist"
        case .playlist: return "playlist"
        case .podcastShow, .podcastEpisode: return "podcast"
        case .station, .radioStation: return "radio"
        default: return "track"
        }
    }
}
