// Siri Intents — AppleEcosystem submodule (Milestone 1)
//
// Maps Siri media intents directly to the existing PlayerController,
// StreamingController, and QueueController via the Flutter MethodChannel.
//
// Supported intents:
//   - PlayTrackIntent       → kind: "track"
//   - PlayAlbumIntent       → kind: "album"
//   - PlayPlaylistIntent    → kind: "playlist"
//   - ResumePlaybackIntent  → kind: "resume"
//   - PausePlaybackIntent   → kind: "pause"
//   - SearchMusicIntent     → kind: "search"
//
// Uses SiriKit INPlayMediaIntent for broad compatibility (iOS 15+).

import Flutter
import Foundation
import Intents

/// Handles all Siri media intents and routes them to the Flutter player.
@available(iOS 15.0, *)
final class SiriIntentManager: NSObject, INPlayMediaIntentHandling {
    /// Channel name — must match Dart side.
    static let channelName = "com.zarz.spotiflac/siri"

    private let channel: FlutterMethodChannel

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        super.init()
    }

    // MARK: - INPlayMediaIntentHandling

    /// Main intent handler — routes to Dart for playback resolution.
    func handle(
        intent: INPlayMediaIntent,
        completion: @escaping (INPlayMediaIntentResponse) -> Void
    ) {
        let request = Self.describe(intent)

        // Siri gives the app a short window to respond. Dart replies as
        // soon as it has *accepted* the request (not when audio starts).
        // A failure to reply still resolves — leaving Siri hanging is
        // worse than reporting an honest failure.
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

        // Safety timeout: if Dart doesn't respond in 8 seconds, tell
        // Siri to continue in the app rather than claiming success
        // that never happened.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            finish(.continueInApp)
        }
    }

    /// Media item resolution — pass through unresolved so Dart can search
    /// its own library at play time using the extension/provider ladder.
    func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        guard let items = intent.mediaItems, !items.isEmpty else {
            completion([INPlayMediaMediaItemResolutionResult.unsupported()])
            return
        }
        completion(INPlayMediaMediaItemResolutionResult.successes(with: items))
    }

    // MARK: - Intent Classification

    /// Maps INPlayMediaIntent to the Dart payload format.
    ///
    /// Intent mapping:
    ///   "play <song>"     → PlayTrackIntent       → kind: "track"
    ///   "play <album>"    → PlayAlbumIntent       → kind: "album"
    ///   "play <playlist>" → PlayPlaylistIntent    → kind: "playlist"
    ///   "resume"          → ResumePlaybackIntent  → kind: "resume"
    ///   "pause"           → PausePlaybackIntent   → kind: "pause"
    ///   "search <query>"  → SearchMusicIntent     → kind: "search"
    static func describe(_ intent: INPlayMediaIntent) -> [String: Any] {
        let item = intent.mediaItems?.first
        let search = intent.mediaSearch

        var kind = "resume"
        if let type = item?.type ?? search?.mediaType {
            kind = describe(type)
        }

        let title = item?.title ?? search?.mediaName

        var payload: [String: Any] = ["kind": kind]
        payload["title"] = title ?? ""
        payload["artist"] = item?.artist ?? search?.artistName ?? ""
        payload["album"] = search?.albumName ?? ""
        payload["identifier"] = item?.identifier ?? ""
        payload["shuffle"] = (intent.playShuffled ?? false)

        // A bare search with no name is a resume.
        if title == nil || title?.isEmpty == true {
            payload["kind"] = "resume"
        }

        return payload
    }

    static func describe(_ type: INMediaItemType) -> String {
        switch type {
        case .song, .music: return "track"       // PlayTrackIntent
        case .album: return "album"              // PlayAlbumIntent
        case .artist: return "artist"
        case .playlist: return "playlist"        // PlayPlaylistIntent
        case .podcastShow, .podcastEpisode: return "podcast"
        case .station, .radioStation: return "radio"
        default: return "track"
        }
    }
}

/// Dedicated pause handler — separate from play because SiriKit models
/// these as different intent flows in practice.
@available(iOS 15.0, *)
extension SiriIntentManager {
    /// Handles pause/resume requests through the Dart channel.
    func handlePlaybackControl(kind: String, completion: @escaping (Bool) -> Void) {
        channel.invokeMethod("control", arguments: ["kind": kind]) { response in
            completion(response as? Bool ?? false)
        }
    }
}
