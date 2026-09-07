import AuthenticationServices
import CarPlay
import Flutter
import Intents
import UIKit
import UniformTypeIdentifiers
import Gobackend

// MARK: - gomobile error bridging
//
// gomobile binds package-level Go functions to plain C functions with a
// trailing `NSError **` out-parameter. Unlike Objective-C *methods*, plain
// functions are NOT imported into Swift as `throws`, so the error pointer
// must be passed and checked explicitly. `goCall` converts that convention
// back into idiomatic Swift `throws`:
//
//     let json: String? = try goCall { GobackendFooJSON(arg, $0) }
//
@discardableResult
private func goCall<T>(_ body: (NSErrorPointer) -> T) throws -> T {
    var goError: NSError?
    let result = body(&goError)
    if let goError = goError { throw goError }
    return result
}

@main
@objc class AppDelegate: FlutterAppDelegate {
    private let CHANNEL = "com.zarz.spotiflac/backend"
    private let DOWNLOAD_PROGRESS_STREAM_CHANNEL = "com.zarz.spotiflac/download_progress_stream"
    private let LIBRARY_SCAN_PROGRESS_STREAM_CHANNEL = "com.zarz.spotiflac/library_scan_progress_stream"
    private let LARGE_JSON_RESULT_FILE_KEY = "__json_file"
    private let LARGE_JSON_RESULT_FILE_THRESHOLD_BYTES = 256 * 1024
    private let streamQueue = DispatchQueue(label: "com.zarz.spotiflac.progress_stream", qos: .utility)
    private var downloadProgressTimer: DispatchSourceTimer?
    private var downloadProgressEventSink: FlutterEventSink?
    private var lastDownloadProgressPayload: String?
    private var lastDownloadProgressSeq: Int64 = 0
    private var libraryScanProgressTimer: DispatchSourceTimer?
    private var libraryScanProgressEventSink: FlutterEventSink?
    private var lastLibraryScanProgressPayload: String?
    private var backendChannel: FlutterMethodChannel?
    private var pendingSessionGrantEvents: [[String: Any]] = []
    
    private let securityScopedAccessLock = NSLock()
    private var securityScopedAccesses: [String: URL] = [:]

    /// Pending Flutter result for the native folder picker
    private var pendingDirectoryPickerResult: FlutterResult?

    /// Whether a download queue is active; while true a background task is
    /// started on each background entry to extend execution time. Main-thread only.
    private var downloadsActive = false
    private var downloadBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// Strong reference to the in-flight ASWebAuthenticationSession; the
    /// session is deallocated (and its sheet dismissed) without it.
    private var activeWebAuthSession: AnyObject?

    // MARK: - Apple ecosystem (Milestone 2)
    //
    // Each controller owns one method channel and is retained for the app's
    // lifetime. They are created only once a binary messenger exists, so a
    // messenger-less launch degrades to "feature unavailable" rather than a
    // crash — the same policy the backend channel already follows.
    private var audioSessionController: AudioSessionController?
    private var airPlayController: AirPlayController?
    private var liveActivityController: LiveActivityController?
    private var siriIntentHandler: AnyObject?
    
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            GobackendSetAppVersion(version)
        }
        
        // Never force-cast the root view controller: `window` is nil at this
        // point in a UIScene-based launch (and in unit-test hosts), which
        // turned a recoverable setup failure into a launch crash. Fall back to
        // the engine owned by the app delegate's registrar, and finally bail
        // out gracefully - Dart-side calls then surface as MissingPluginException
        // instead of the process dying before the first frame.
        guard let messenger = resolveBinaryMessenger() else {
            NSLog("[SpotiFLAC] No FlutterBinaryMessenger available at launch; backend channels are disabled.")
            GeneratedPluginRegistrant.register(with: self)
            return super.application(application, didFinishLaunchingWithOptions: launchOptions)
        }
        let channel = FlutterMethodChannel(
            name: CHANNEL,
            binaryMessenger: messenger
        )
        backendChannel = channel
        if !pendingSessionGrantEvents.isEmpty {
            let events = pendingSessionGrantEvents
            pendingSessionGrantEvents.removeAll()
            for event in events {
                channel.invokeMethod("extensionSessionGrantCompleted", arguments: event)
            }
        }
        let downloadProgressEvents = FlutterEventChannel(
            name: DOWNLOAD_PROGRESS_STREAM_CHANNEL,
            binaryMessenger: messenger
        )
        let libraryScanProgressEvents = FlutterEventChannel(
            name: LIBRARY_SCAN_PROGRESS_STREAM_CHANNEL,
            binaryMessenger: messenger
        )
        
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handleMethodCall(call: call, result: result)
        }
        downloadProgressEvents.setStreamHandler(
            ClosureStreamHandler(
                onListen: { [weak self] _, events in
                    self?.startDownloadProgressStream(events)
                    return nil
                },
                onCancel: { [weak self] _ in
                    self?.stopDownloadProgressStream()
                    return nil
                }
            )
        )
        libraryScanProgressEvents.setStreamHandler(
            ClosureStreamHandler(
                onListen: { [weak self] _, events in
                    self?.startLibraryScanProgressStream(events)
                    return nil
                },
                onCancel: { [weak self] _ in
                    self?.stopLibraryScanProgressStream()
                    return nil
                }
            )
        )
        
        registerAppleIntegrations(messenger: messenger)

        GeneratedPluginRegistrant.register(with: self)
        if let url = launchOptions?[.url] as? URL {
            _ = handleExtensionOAuthRedirect(url: url)
        }
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    /// Resolves a binary messenger without force-casting `window`.
    ///
    /// Order of preference:
    ///   1. the root `FlutterViewController` (classic, non-scene launch),
    ///   2. any `FlutterViewController` reachable from a connected scene
    ///      (iOS 13+ / UIScene lifecycle, where `window` is still nil in
    ///      `didFinishLaunchingWithOptions`),
    ///   3. the registrar backed by FlutterAppDelegate's engine,
    ///   4. `nil` - the caller degrades gracefully instead of crashing.
    private func resolveBinaryMessenger() -> FlutterBinaryMessenger? {
        if let controller = window?.rootViewController as? FlutterViewController {
            return controller.binaryMessenger
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for sceneWindow in windowScene.windows {
                if let controller = sceneWindow.rootViewController as? FlutterViewController {
                    return controller.binaryMessenger
                }
            }
        }
        // UIScene may not have attached any window yet, while FlutterAppDelegate
        // already owns the engine/plugin registry. Its registrar provides the
        // same messenger without requiring a view controller or a force-cast.
        if let registrar = registrar(forPlugin: "SpotiFLACBackendChannels") {
            return registrar.messenger()
        }
        return nil
    }

    /// Extension return URLs:
    /// - OAuth: spotiflac://callback?code=...&state=<extension_id>
    /// - Signed session: spotiflac://session-grant?grant=...&state=<extension_id>
    @discardableResult
    private func handleExtensionOAuthRedirect(url: URL) -> Bool {        guard let route = ExtensionCallbackParser.parse(url) else { return false }
        streamQueue.async {
            var err: NSError?
            var response: String?
            // gomobile binds package-level Go functions that return an
            // `error` as plain C functions with a trailing `NSError **`
            // out-parameter; `goCall` converts that back into Swift `throws`
            // so the failure surfaces through `catch`.
            do {
                if route.isSessionGrant {
                    GobackendSetExtensionSessionGrantByID(route.extensionId, route.code)
                    response = try goCall { GobackendInvokeExtensionActionJSON(route.extensionId,
                        "completeGrant", $0) }
                } else {
                    GobackendSetExtensionAuthCodeByID(route.extensionId, route.code)
                    response = try goCall { GobackendInvokeExtensionActionJSON(route.extensionId,
                        "completeSpotifyLogin", $0) }
                }
            } catch {
                err = error as NSError
            }
            if err == nil && route.isSessionGrant {
                do {
                    try self.requireSuccessfulExtensionAction(
                        extensionId: route.extensionId,
                        actionName: "completeGrant",
                        response: response
                    )
                } catch {
                    err = error as NSError
                }
            }
            if let err = err {
                NSLog(
                    "SpotiFLAC: Extension callback complete failed: \(err.localizedDescription)")
            } else if route.isSessionGrant {
                DispatchQueue.main.async { [weak self] in
                    self?.notifySessionGrantCompleted(
                        extensionId: route.extensionId
                    )
                }
            }
        }
        return true
    }

    private func requireSuccessfulExtensionAction(
        extensionId: String,
        actionName: String,
        response: String?
    ) throws {
        let text = response ?? ""
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "SpotiFLAC",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Extension \(actionName) for \(extensionId) returned invalid JSON: \(String(text.prefix(240)))"
                ]
            )
        }
        if (obj["success"] as? Bool) == true {
            return
        }
        let error =
            (obj["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ??
            (obj["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ??
            String(text.prefix(240))
        throw NSError(
            domain: "SpotiFLAC",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey: "Extension \(actionName) failed for \(extensionId): \(error)"
            ]
        )
    }

    private func notifySessionGrantCompleted(extensionId: String) {
        let payload: [String: Any] = [
            "extension_id": extensionId,
            "success": true,
        ]
        if let channel = backendChannel {
            channel.invokeMethod("extensionSessionGrantCompleted", arguments: payload)
        } else {
            pendingSessionGrantEvents.append(payload)
        }
    }

    override func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        if handleExtensionOAuthRedirect(url: url) {
            return true
        }
        return super.application(app, open: url, options: options)
    }

    deinit {
        stopDownloadProgressStream()
        stopLibraryScanProgressStream()
        (activeWebAuthSession as? ASWebAuthenticationSession)?.cancel()
        activeWebAuthSession = nil
        endBackgroundDownloadTask()
        releaseAllSecurityScopedAccesses()
    }

    private func startDownloadProgressStream(_ eventSink: @escaping FlutterEventSink) {
        stopDownloadProgressStream()
        // `downloadProgressEventSink` is main-thread-only state; the payload /
        // sequence cursor is owned exclusively by `streamQueue` (see below).
        downloadProgressEventSink = eventSink

        streamQueue.async { [weak self] in
            guard let self else { return }
            self.lastDownloadProgressPayload = nil
            self.lastDownloadProgressSeq = 0

            let timer = DispatchSource.makeTimerSource(queue: self.streamQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(800))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let payload = GobackendGetAllDownloadProgressDelta(self.lastDownloadProgressSeq) as String? ?? ""
                if payload.isEmpty || payload == self.lastDownloadProgressPayload {
                    return
                }
                self.updateDownloadProgressSeq(payload)
                self.lastDownloadProgressPayload = payload
                DispatchQueue.main.async { [weak self] in
                    self?.downloadProgressEventSink?(self?.parseJsonPayload(payload))
                }
            }
            self.downloadProgressTimer = timer
            timer.resume()
        }
    }

    private func stopDownloadProgressStream() {
        downloadProgressEventSink = nil
        // Timer + cursor live on `streamQueue`; mutating them from the main
        // thread (onCancel / deinit) while the handler is running was an
        // unsynchronized read-write race on a Swift String and Int64.
        streamQueue.sync {
            downloadProgressTimer?.setEventHandler {}
            downloadProgressTimer?.cancel()
            downloadProgressTimer = nil
            lastDownloadProgressPayload = nil
            lastDownloadProgressSeq = 0
        }
    }

    private func startLibraryScanProgressStream(_ eventSink: @escaping FlutterEventSink) {
        stopLibraryScanProgressStream()
        libraryScanProgressEventSink = eventSink

        streamQueue.async { [weak self] in
            guard let self else { return }
            self.lastLibraryScanProgressPayload = nil

            let timer = DispatchSource.makeTimerSource(queue: self.streamQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(800))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let payload = GobackendGetLibraryScanProgressJSON() as String? ?? "{}"
                if payload == self.lastLibraryScanProgressPayload {
                    return
                }
                self.lastLibraryScanProgressPayload = payload
                DispatchQueue.main.async { [weak self] in
                    self?.libraryScanProgressEventSink?(self?.parseJsonPayload(payload))
                }
            }
            self.libraryScanProgressTimer = timer
            timer.resume()
        }
    }

    private func stopLibraryScanProgressStream() {
        libraryScanProgressEventSink = nil
        streamQueue.sync {
            libraryScanProgressTimer?.setEventHandler {}
            libraryScanProgressTimer?.cancel()
            libraryScanProgressTimer = nil
            lastLibraryScanProgressPayload = nil
        }
    }

    private func parseJsonPayload(_ payload: String) -> Any {
        guard let data = payload.data(using: .utf8) else {
            return payload
        }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return payload
        }
    }

    private func updateDownloadProgressSeq(_ payload: String) {
        guard let data = payload.data(using: .utf8) else { return }
        do {
            if let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
               let seq = obj["seq"] as? NSNumber,
               seq.int64Value > lastDownloadProgressSeq {
                lastDownloadProgressSeq = seq.int64Value
            }
        } catch {
        }
    }

    private func bridgeJsonResult(_ payload: String) -> Any {
        if payload.utf8.count < LARGE_JSON_RESULT_FILE_THRESHOLD_BYTES {
            return payload
        }

        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("bridge_json_\(UUID().uuidString).json")
            try payload.write(to: url, atomically: true, encoding: .utf8)
            return [LARGE_JSON_RESULT_FILE_KEY: url.path]
        } catch {
            NSLog("SpotiFLAC: failed to spill large bridge JSON result to file: \(error.localizedDescription)")
            return payload
        }
    }
    
    /// Battery/charging snapshot for the download scheduler ("only while
    /// charging", "not below N%"). Monitoring is enabled lazily and stays on;
    /// UIDevice reports -1 / .unknown when it is off or on the simulator.
    private func readPowerStatus() -> [String: Any] {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled {
            device.isBatteryMonitoringEnabled = true
        }
        let state = device.batteryState
        let level = device.batteryLevel
        let percent = level >= 0 ? Int((level * 100).rounded()) : -1
        return [
            "charging": state == .charging || state == .full,
            "level": percent,
            "known": state != .unknown,
        ]
    }

    private func handleMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "beginBackgroundDownloadTask":
            downloadsActive = true
            result(nil)
            return
        case "endBackgroundDownloadTask":
            downloadsActive = false
            endBackgroundDownloadTask()
            result(nil)
            return
        case "pickIosDirectory":
            pickIosDirectory(result: result)
            return
        case "getPowerStatus":
            result(readPowerStatus())
            return
        case "audioEffectsCapabilities":
            // The music pipeline renders through AVPlayer, whose output cannot
            // host AudioUnit effects without re-routing decoding through an
            // AVAudioEngine graph. Report the chain as unavailable so the
            // settings UI disables the stages instead of pretending.
            result([
                "equalizer": false,
                "bass_boost": false,
                "virtualizer": false,
                "enhancer": false,
                "compressor": false,
                "limiter": false,
                "engine": "unavailable (AVPlayer)",
            ])
            return
        case "applyAudioEffects":
            result(["attached": false, "players": [], "reason": "unsupported on iOS"])
            return
        case "startWebAuthSession":
            let args = call.arguments as? [String: Any] ?? [:]
            let urlString = (args["url"] as? String) ?? ""
            let callbackScheme = (args["callback_scheme"] as? String) ?? "spotiflac"
            startWebAuthSession(
                urlString: urlString,
                callbackScheme: callbackScheme,
                result: result
            )
            return
        default:
            break
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let response = try self.invokeGoMethod(call: call)
                DispatchQueue.main.async {
                    result(response)
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "ERROR", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    /// Runs a verification/OAuth page inside ASWebAuthenticationSession. The
    /// session intercepts the callback scheme in-process — no OS-level URL
    /// scheme registration is involved — so the flow completes even where the
    /// app's scheme is not registered with iOS (sideload containers such as
    /// LiveContainer). The callback URL is fed into the same deep-link handler
    /// the OS path uses. Returns whether the session was presented; completion
    /// is delivered later through the existing grant-event plumbing.
    private func startWebAuthSession(
        urlString: String,
        callbackScheme: String,
        result: @escaping FlutterResult
    ) {
        guard #available(iOS 13.0, *) else {
            result(false)
            return
        }
        guard let url = URL(string: urlString), url.scheme?.lowercased() == "https" else {
            result(false)
            return
        }
        let scheme = callbackScheme.isEmpty ? "spotiflac" : callbackScheme
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: scheme
        ) { [weak self] callbackURL, error in
            self?.activeWebAuthSession = nil
            guard let callbackURL = callbackURL else {
                if let error = error {
                    NSLog("SpotiFLAC: web auth session ended: \(error.localizedDescription)")
                }
                return
            }
            _ = self?.handleExtensionOAuthRedirect(url: callbackURL)
        }
        session.presentationContextProvider = self
        // Share Safari's cookie store so captcha providers see an established
        // browsing context instead of a blank ephemeral one.
        session.prefersEphemeralWebBrowserSession = false
        activeWebAuthSession = session
        let started = session.start()
        if !started {
            activeWebAuthSession = nil
        }
        result(started)
    }

    override func applicationDidEnterBackground(_ application: UIApplication) {
        super.applicationDidEnterBackground(application)
        if downloadsActive {
            beginBackgroundDownloadTask()
        }
    }

    override func applicationWillEnterForeground(_ application: UIApplication) {
        super.applicationWillEnterForeground(application)
        endBackgroundDownloadTask()
    }

    private func beginBackgroundDownloadTask() {
        if downloadBackgroundTask != .invalid { return }
        downloadBackgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "SpotiFLACDownloads"
        ) { [weak self] in
            self?.endBackgroundDownloadTask()
        }
    }

    private func endBackgroundDownloadTask() {
        if downloadBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(downloadBackgroundTask)
            downloadBackgroundTask = .invalid
        }
    }
    
    private func invokeGoMethod(call: FlutterMethodCall) throws -> Any? {
        switch call.method {
        case "downloadByStrategy":
            let requestJson = try requireMethodString(call.arguments, call.method)
            let response: String? = try goCall { GobackendDownloadByStrategy(requestJson, $0) }
            return response

        case "getAllDownloadProgress":
            let response = GobackendGetAllDownloadProgress()
            return parseJsonPayload(response as String? ?? "{}")

        case "clearItemProgress":
            let args = Self.argsDict(call.arguments)
            let itemId = try requireString(args, "item_id", call.method)
            GobackendClearItemProgress(itemId)
            return nil

        case "cancelDownload":
            let args = Self.argsDict(call.arguments)
            let itemId = try requireString(args, "item_id", call.method)
            GobackendCancelDownload(itemId)
            return nil

        case "resetDownloadCancel":
            let args = Self.argsDict(call.arguments)
            let itemId = try requireString(args, "item_id", call.method)
            GobackendResetDownloadCancel(itemId)
            return nil

        case "setDownloadDirectory":
            let args = Self.argsDict(call.arguments)
            let path = try requireString(args, "path", call.method)
            try goCall { GobackendSetDownloadDirectory(path, $0) }
            return nil

        case "setNetworkCompatibilityOptions", "setSongLinkNetworkOptions":
            let args = Self.argsDict(call.arguments)
            let allowHTTP = args["allow_http"] as? Bool ?? false
            let insecureTLS = args["insecure_tls"] as? Bool ?? false
            GobackendSetNetworkCompatibilityOptions(allowHTTP, insecureTLS)
            return nil

        case "setAllowPrivateNetwork":
            let args = Self.argsDict(call.arguments)
            let allowed = args["allowed"] as? Bool ?? false
            GobackendSetAllowPrivateNetwork(allowed)
            return nil

        case "checkDuplicatesBatch":
            let args = Self.argsDict(call.arguments)
            let outputDir = try requireString(args, "output_dir", call.method)
            let tracksJson = optionalString(args, "tracks", "[]")
            let response: String? = try goCall { GobackendCheckDuplicatesBatch(outputDir, tracksJson, $0) }
            return response

        case "preBuildDuplicateIndex":
            let args = Self.argsDict(call.arguments)
            let outputDir = try requireString(args, "output_dir", call.method)
            try goCall { GobackendPreBuildDuplicateIndex(outputDir, $0) }
            return nil

        case "invalidateDuplicateIndex":
            let args = Self.argsDict(call.arguments)
            let outputDir = try requireString(args, "output_dir", call.method)
            GobackendInvalidateDuplicateIndex(outputDir)
            return nil

        case "startLanWebPlayer":
            let args = Self.argsDict(call.arguments)
            let config = optionalString(args, "config", "{}")
            let response: String? = try goCall { GobackendStartLanWebPlayer(config, $0) }
            return response

        case "stopLanWebPlayer":
            try goCall { GobackendStopLanWebPlayer($0) }
            return nil

        case "getLanWebPlayerStatus":
            let response = GobackendGetLanWebPlayerStatus()
            return response

        case "setExtensionImportedCookies":
            let args = Self.argsDict(call.arguments)
            let extensionId = try requireString(args, "extension_id", call.method)
            let cookiesText = try requireString(args, "cookies_text", call.method)
            let response: String? = try goCall { GobackendSetExtensionImportedCookies(extensionId, cookiesText, $0) }
            return response

        case "getExtensionImportedCookiesInfo":
            let args = Self.argsDict(call.arguments)
            let extensionId = try requireString(args, "extension_id", call.method)
            let response: String? = try goCall { GobackendGetExtensionImportedCookiesInfo(extensionId, $0) }
            return response

        case "clearExtensionImportedCookies":
            let args = Self.argsDict(call.arguments)
            let extensionId = try requireString(args, "extension_id", call.method)
            try goCall { GobackendClearExtensionImportedCookies(extensionId, $0) }
            return nil

        case "buildFilename":
            let args = Self.argsDict(call.arguments)
            let template = try requireString(args, "template", call.method)
            let metadata = optionalString(args, "metadata", "{}")
            let response: String? = try goCall { GobackendBuildFilename(template, metadata, $0) }
            return response

        case "sanitizeFilename":
            let args = Self.argsDict(call.arguments)
            let filename = try requireString(args, "filename", call.method)
            let response = GobackendSanitizeFilename(filename)
            return response
            
        case "getLyricsLRC":
            let args = Self.argsDict(call.arguments)
            let spotifyId = try requireString(args, "spotify_id", call.method)
            let trackName = try requireString(args, "track_name", call.method)
            let artistName = try requireString(args, "artist_name", call.method)
            let filePath = args["file_path"] as? String ?? ""
            let durationMs = args["duration_ms"] as? Int64 ?? 0
            let response: String? = try goCall { GobackendGetLyricsLRC(spotifyId, trackName, artistName, filePath, durationMs, $0) }
            return response

        case "getLyricsLRCWithSource":
            let args = Self.argsDict(call.arguments)
            let spotifyId = try requireString(args, "spotify_id", call.method)
            let trackName = try requireString(args, "track_name", call.method)
            let artistName = try requireString(args, "artist_name", call.method)
            let filePath = args["file_path"] as? String ?? ""
            let durationMs = args["duration_ms"] as? Int64 ?? 0
            let response: String? = try goCall { GobackendGetLyricsLRCWithSource(spotifyId, trackName, artistName, filePath, durationMs, $0) }
            return response
            
        case "embedLyricsToFile":
            let args = Self.argsDict(call.arguments)
            let filePath = try requireString(args, "file_path", call.method)
            let lyrics = try requireString(args, "lyrics", call.method)
            let response: String? = try goCall { GobackendEmbedLyricsToFile(filePath, lyrics, $0) }
            return response
            
        case "rewriteSplitArtistTags":
            let args = Self.argsDict(call.arguments)
            let filePath = try requireString(args, "file_path", call.method)
            let artist = try requireString(args, "artist", call.method)
            let albumArtist = try requireString(args, "album_artist", call.method)
            let response: String? = try goCall { GobackendRewriteSplitArtistTagsExport(filePath, artist, albumArtist, $0) }
            return response
            
        case "cleanupConnections":
            GobackendCleanupConnections()
            return nil

        case "downloadCoverToFile":
            let args = Self.argsDict(call.arguments)
            let coverURL = try requireString(args, "cover_url", call.method)
            let outputPath = try requireString(args, "output_path", call.method)
            try goCall { GobackendDownloadCoverToFile(coverURL, outputPath, false, $0) }
            return "{\"success\":true}"

        case "extractCoverToFile":
            let args = Self.argsDict(call.arguments)
            let audioPath = try requireString(args, "audio_path", call.method)
            let outputPath = try requireString(args, "output_path", call.method)
            try goCall { GobackendExtractCoverToFile(audioPath, outputPath, $0) }
            return "{\"success\":true}"

        case "fetchAndSaveLyrics":
            let args = Self.argsDict(call.arguments)
            let trackName = try requireString(args, "track_name", call.method)
            let artistName = try requireString(args, "artist_name", call.method)
            let spotifyId = try requireString(args, "spotify_id", call.method)
            let durationMs = args["duration_ms"] as? Int64 ?? 0
            let outputPath = try requireString(args, "output_path", call.method)
            let audioFilePath = args["audio_file_path"] as? String ?? ""
            try goCall { GobackendFetchAndSaveLyrics(trackName,
                artistName,
                spotifyId,
                durationMs,
                outputPath,
                audioFilePath, $0) }
            return "{\"success\":true}"

        case "reEnrichFile":
            let args = Self.argsDict(call.arguments)
            let requestJson = args["request_json"] as? String ?? "{}"
            let response: String? = try goCall { GobackendReEnrichFile(requestJson, $0) }
            return response
            
        case "readFileMetadata":
            let args = Self.argsDict(call.arguments)
            let filePath = try requireString(args, "file_path", call.method)
            let response: String? = try goCall { GobackendReadFileMetadata(filePath, $0) }
            return response
            
        case "editFileMetadata":
            let args = Self.argsDict(call.arguments)
            let filePath = try requireString(args, "file_path", call.method)
            let metadataJson = args["metadata_json"] as? String ?? "{}"
            let response: String? = try goCall { GobackendEditFileMetadata(filePath, metadataJson, $0) }
            return response
            
        case "getProviderMetadata":
            let args = Self.argsDict(call.arguments)
            let providerId = try requireString(args, "provider_id", call.method)
            let resourceType = try requireString(args, "resource_type", call.method)
            let resourceId = try requireString(args, "resource_id", call.method)
            let response: String? = try goCall { GobackendGetProviderMetadataJSON(providerId, resourceType, resourceId, $0) }
            return response

        case "searchDeezerByISRC":
            let args = Self.argsDict(call.arguments)
            let isrc = try requireString(args, "isrc", call.method)
            let itemId = args["item_id"] as? String ?? ""
            let response: String? = try goCall { GobackendSearchDeezerByISRCForItemID(isrc, itemId, $0) }
            return response

        case "getDeezerExtendedMetadata":
            let args = Self.argsDict(call.arguments)
            let trackId = try requireString(args, "track_id", call.method)
            let response: String? = try goCall { GobackendGetDeezerExtendedMetadata(trackId, $0) }
            return response

        case "convertSpotifyToDeezer":
            let args = Self.argsDict(call.arguments)
            let resourceType = try requireString(args, "resource_type", call.method)
            let spotifyId = try requireString(args, "spotify_id", call.method)
            let response: String? = try goCall { GobackendConvertSpotifyToDeezer(resourceType, spotifyId, $0) }
            return response

        case "getSpotifyIDFromDeezerTrack":
            let args = Self.argsDict(call.arguments)
            let deezerTrackId = try requireString(args, "deezer_track_id", call.method)
            let response: String? = try goCall { GobackendGetSpotifyIDFromDeezerTrack(deezerTrackId, $0) }
            return response
            
        case "getTidalURLFromDeezerTrack":
            let args = Self.argsDict(call.arguments)
            let deezerTrackId = try requireString(args, "deezer_track_id", call.method)
            let response: String? = try goCall { GobackendGetTidalURLFromDeezerTrack(deezerTrackId, $0) }
            return response
            
        case "getTrackCacheSize":
            let response = GobackendGetTrackCacheSize()
            return response
            
        case "clearTrackCache":
            GobackendClearTrackIDCache()
            return nil
            
        case "getLogsSince":
            let args = Self.argsDict(call.arguments)
            let index = args["index"] as? Int ?? 0
            let response = GobackendGetLogsSince(Int(index))
            return response
            
        case "clearLogs":
            GobackendClearLogs()
            return nil

        case "releaseMemory":
            GobackendReleaseMemory()
            return nil

        case "releaseMemoryUnderPressure":
            GobackendReleaseMemoryUnderPressure()
            return nil

        case "getGoRuntimeMetrics":
            return GobackendGetRuntimeMetricsJSON()
            
        case "setLoggingEnabled":
            let args = Self.argsDict(call.arguments)
            let enabled = args["enabled"] as? Bool ?? false
            GobackendSetLoggingEnabled(enabled)
            return nil
            
        case "initExtensionSystem":
            let args = Self.argsDict(call.arguments)
            let extensionsDir = try requireString(args, "extensions_dir", call.method)
            let dataDir = try requireString(args, "data_dir", call.method)
            try goCall { GobackendInitExtensionSystem(extensionsDir, dataDir, $0) }
            return nil
            
        case "loadExtensionsFromDir":
            let args = Self.argsDict(call.arguments)
            let dirPath = try requireString(args, "dir_path", call.method)
            let response: String? = try goCall { GobackendLoadExtensionsFromDir(dirPath, $0) }
            return response
            
        case "loadExtensionFromPath":
            let args = Self.argsDict(call.arguments)
            let filePath = try requireString(args, "file_path", call.method)
            let response: String? = try goCall { GobackendLoadExtensionFromPath(filePath, $0) }
            return response
            
        case "unloadExtension":
            let args = Self.argsDict(call.arguments)
            let extensionId = try requireString(args, "extension_id", call.method)
            try goCall { GobackendUnloadExtensionByID(extensionId, $0) }
            return nil
            
        case "getInstalledExtensions":
            let response: String? = try goCall { GobackendGetInstalledExtensions($0) }
            return response
            
        case "setExtensionEnabled":
            let args = Self.argsDict(call.arguments)
            let extensionId = try requireString(args, "extension_id", call.method)
            let enabled = args["enabled"] as? Bool ?? false
            try goCall { GobackendSetExtensionEnabledByID(extensionId, enabled, $0) }
            return nil
            
        case "setProviderPriority":
            let args = Self.argsDict(call.arguments)
            let priorityJson = try requireString(args, "priority", call.method)
            try goCall { GobackendSetProviderPriorityJSON(priorityJson, $0) }
            return nil
            
        case "getProviderPriority":
            let response: String? = try goCall { GobackendGetProviderPriorityJSON($0) }
            return response

        case "setDownloadFallbackExtensionIds":
            let args = Self.argsDict(call.arguments)
            let extensionIdsJson = args["extension_ids"] as? String ?? ""
            try goCall { GobackendSetExtensionFallbackProviderIDsJSON(extensionIdsJson, $0) }
            return nil
            
        case "setMetadataProviderPriority":
            let args = Self.argsDict(call.arguments)
            let priorityJson = try requireString(args, "priority", call.method)
            try goCall { GobackendSetMetadataProviderPriorityJSON(priorityJson, $0) }
            return nil
            
        case "getMetadataProviderPriority":
            let response: String? = try goCall { GobackendGetMetadataProviderPriorityJSON($0) }
            return response
            
        case "getExtensionSettings":
            let args = Self.argsDict(call.arguments)
            let extensionId = try requireString(args, "extension_id", call.method)
            let response: String? = try goCall { GobackendGetExtensionSettingsJSON(extensionId, $0) }
            return response

        case "checkExtensionHealth":
            let args = Self.argsDict(call.arguments)
            let extensionId = try requireString(args, "extension_id", call.method)
            let response: String? = try goCall { GobackendCheckExtensionHealthJSON(extensionId, $0) }
            return response
            
        case "setExtensionSettings":
            let args = Self.argsDict(call.arguments)
            let extensionId = try requireString(args, "extension_id", call.method)
            let settingsJson = try requireString(args, "settings", call.method)
            try goCall { GobackendSetExtensionSettingsJSON(extensionId, settingsJson, $0) }
            return nil
            
        case "invokeExtensionAction":
            let args = Self.argsDict(call.arguments)
            let extensionId = try requireString(args, "extension_id", call.method)
            let actionName = try requireString(args, "action", call.method)
            let response: String? = try goCall { GobackendInvokeExtensionActionJSON(extensionId, actionName, $0) }
            return response
            
        case "searchTracksWithMetadataProviders":
            let args = Self.argsDict(call.arguments)
            let query = try requireString(args, "query", call.method)
            let limit = args["limit"] as? Int ?? 20
            let includeExtensions = args["include_extensions"] as? Bool ?? true
            let response: String? = try goCall { GobackendSearchTracksWithMetadataProvidersJSON(query, Int(limit), includeExtensions, $0) }
            return response

        case "searchTracksWithMetadataProvider":
            let args = Self.argsDict(call.arguments)
            let extensionId = args["extension_id"] as? String ?? ""
            let query = args["query"] as? String ?? ""
            let limit = args["limit"] as? Int ?? 20
            let response: String? = try goCall { GobackendSearchTracksWithMetadataProviderJSON(extensionId, query, Int(limit), $0) }
            return response
            
        case "enrichTrackWithExtension":
            let args = Self.argsDict(call.arguments)
            let extensionId = try requireString(args, "extension_id", call.method)
            let trackJson = args["track"] as? String ?? "{}"
            let response: String? = try goCall { GobackendEnrichTrackWithExtensionJSON(extensionId, trackJson, $0) }
            return response

        case "downloadWithExtensions":
            let requestJson = try requireMethodString(call.arguments, call.method)
            let response: String? = try goCall { GobackendDownloadWithExtensionsJSON(requestJson, $0) }
            return response
            
        case "removeExtension":
            let args = Self.argsDict(call.arguments)
            let extensionId = try requireString(args, "extension_id", call.method)
            try goCall { GobackendRemoveExtensionByID(extensionId, $0) }
            return nil
            
        case "upgradeExtension":
            let args = Self.argsDict(call.arguments)
            let filePath = try requireString(args, "file_path", call.method)
            let response: String? = try goCall { GobackendUpgradeExtensionFromPath(filePath, $0) }
            return response
            
        case "checkExtensionUpgrade":
            let args = Self.argsDict(call.arguments)
            let filePath = try requireString(args, "file_path", call.method)
            let response: String? = try goCall { GobackendCheckExtensionUpgradeFromPath(filePath, $0) }
            return response
            
        case "cleanupExtensions":
            GobackendCleanupExtensions()
            return nil
            
        case "getExtensionPendingAuth":
            let args = Self.argsDict(call.arguments)
            let extensionId = try requireString(args, "extension_id", call.method)
            let response: String? = try goCall { GobackendGetExtensionPendingAuthJSON(extensionId, $0) }
            return response
            
        case "setExtensionAuthCode":
            let args = Self.argsDict(call.arguments)
            let extensionId = try requireString(args, "extension_id", call.method)
            let authCode = try requireString(args, "auth_code", call.method)
            GobackendSetExtensionAuthCodeByID(extensionId, authCode)
            return nil

        case "completeExtensionSessionGrant":
            let args = Self.argsDict(call.arguments)
            let extensionId = try requireString(args, "extension_id", call.method)
            let grant = try requireString(args, "grant", call.method)
            GobackendSetExtensionSessionGrantByID(extensionId, grant)
            let response: String? = try goCall { GobackendInvokeExtensionActionJSON(extensionId, "completeGrant", $0) }
            try requireSuccessfulExtensionAction(
                extensionId: extensionId,
                actionName: "completeGrant",
                response: response
            )
            return true
            
        case "setExtensionTokens":
            let args = Self.argsDict(call.arguments)
            let extensionId = try requireString(args, "extension_id", call.method)
            let accessToken = try requireString(args, "access_token", call.method)
            let refreshToken = args["refresh_token"] as? String ?? ""
            let expiresIn = args["expires_in"] as? Int ?? 0
            GobackendSetExtensionTokensByID(extensionId, accessToken, refreshToken, Int(expiresIn))
            return nil
            
        case "clearExtensionPendingAuth":
            let args = Self.argsDict(call.arguments)
            let extensionId = try requireString(args, "extension_id", call.method)
            GobackendClearExtensionPendingAuthByID(extensionId)
            return nil
            
        case "isExtensionAuthenticated":
            let args = Self.argsDict(call.arguments)
            let extensionId = try requireString(args, "extension_id", call.method)
            let response = GobackendIsExtensionAuthenticatedByID(extensionId)
            return response
            
        case "getAllPendingAuthRequests":
            let response: String? = try goCall { GobackendGetAllPendingAuthRequestsJSON($0) }
            return response
            
        case "getPendingFFmpegCommand":
            let args = Self.argsDict(call.arguments)
            let commandId = try requireString(args, "command_id", call.method)
            let response: String? = try goCall { GobackendGetPendingFFmpegCommandJSON(commandId, $0) }
            return response
            
        case "setFFmpegCommandResult":
            let args = Self.argsDict(call.arguments)
            let commandId = try requireString(args, "command_id", call.method)
            let success = args["success"] as? Bool ?? false
            let output = args["output"] as? String ?? ""
            let errorMsg = args["error"] as? String ?? ""
            GobackendSetFFmpegCommandResult(commandId, success, output, errorMsg)
            return nil
            
        case "getAllPendingFFmpegCommands":
            let response: String? = try goCall { GobackendGetAllPendingFFmpegCommandsJSON($0) }
            return response
            
        case "customSearchWithExtension":
            let args = Self.argsDict(call.arguments)
            let extensionId = try requireString(args, "extension_id", call.method)
            let query = try requireString(args, "query", call.method)
            let optionsJson = args["options"] as? String ?? ""
            let requestId = args["request_id"] as? String ?? ""
            let response: String? = try goCall { GobackendCustomSearchWithExtensionJSONWithRequestID(extensionId,
                query,
                optionsJson,
                requestId, $0) }
            return response

        case "cancelExtensionRequest":
            let args = Self.argsDict(call.arguments)
            let requestId = args["request_id"] as? String ?? ""
            GobackendCancelExtensionRequestJSON(requestId)
            return nil

        case "handleURLWithExtension":
            let args = Self.argsDict(call.arguments)
            let url = try requireString(args, "url", call.method)
            let response: String? = try goCall { GobackendHandleURLWithExtensionJSON(url, $0) }
            return response
            
        case "findURLHandler":
            let args = Self.argsDict(call.arguments)
            let url = try requireString(args, "url", call.method)
            let response = GobackendFindURLHandlerJSON(url)
            return response
            
        case "getTrackPlatformLinks":
            let args = Self.argsDict(call.arguments)
            let spotifyId = args["spotify_id"] as? String ?? ""
            let isrc = args["isrc"] as? String ?? ""
            let response: String? = try goCall { GobackendGetTrackPlatformLinksJSON(spotifyId, isrc, $0) }
            return response

        case "fetchMusicBrainzTags":
            let args = Self.argsDict(call.arguments)
            let isrc = args["isrc"] as? String ?? ""
            let albumName = args["album_name"] as? String ?? ""
            let genre = (try? goCall { GobackendFetchMusicBrainzGenreByISRC(isrc, $0) }) ?? ""
            let albumArtist = (try? goCall { GobackendFetchMusicBrainzAlbumArtistByISRC(isrc, albumName, $0) }) ?? ""
            let payload: [String: Any] = [
                "genre": genre,
                "album_artist": albumArtist,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            return String(data: data, encoding: .utf8) ?? "{}"
            
        case "runPostProcessingV2":
            let args = Self.argsDict(call.arguments)
            let inputJson = args["input"] as? String ?? ""
            let metadataJson = args["metadata"] as? String ?? ""
            let response: String? = try goCall { GobackendRunPostProcessingV2JSON(inputJson, metadataJson, $0) }
            return response
            
        case "initExtensionRepo":
            let args = Self.argsDict(call.arguments)
            let cacheDir = try requireString(args, "cache_dir", call.method)
            try goCall { GobackendInitExtensionRepoJSON(cacheDir, $0) }
            return nil
            
        case "setRepoRegistryUrl":
            let args = Self.argsDict(call.arguments)
            let registryUrl = args["registry_url"] as? String ?? ""
            try goCall { GobackendSetRepoRegistryURLJSON(registryUrl, $0) }
            return nil
            
        case "getRepoRegistryUrl":
            let response: String? = try goCall { GobackendGetRepoRegistryURLJSON($0) }
            return response
            
        case "clearRepoRegistryUrl":
            try goCall { GobackendClearRepoRegistryURLJSON($0) }
            return nil
            
        case "getRepoExtensions":
            let args = Self.argsDict(call.arguments)
            let forceRefresh = args["force_refresh"] as? Bool ?? false
            let response: String? = try goCall { GobackendGetRepoExtensionsJSON(forceRefresh, $0) }
            return response
            
        case "searchRepoExtensions":
            let args = Self.argsDict(call.arguments)
            let query = args["query"] as? String ?? ""
            let category = args["category"] as? String ?? ""
            let response: String? = try goCall { GobackendSearchRepoExtensionsJSON(query, category, $0) }
            return response
            
        case "getRepoCategories":
            let response: String? = try goCall { GobackendGetRepoCategoriesJSON($0) }
            return response
            
        case "downloadRepoExtension":
            let args = Self.argsDict(call.arguments)
            let extensionId = try requireString(args, "extension_id", call.method)
            let destDir = try requireString(args, "dest_dir", call.method)
            let response: String? = try goCall { GobackendDownloadRepoExtensionJSON(extensionId, destDir, $0) }
            return response
            
        case "clearRepoCache":
            try goCall { GobackendClearRepoCacheJSON($0) }
            return nil
            
        case "getExtensionHomeFeed":
            let args = Self.argsDict(call.arguments)
            let extensionId = try requireString(args, "extension_id", call.method)
            let requestId = args["request_id"] as? String ?? ""
            let response: String? = try goCall { GobackendGetExtensionHomeFeedJSONWithRequestID(extensionId, requestId, $0) }
            return response
            
        case "setLibraryCoverCacheDir":
            let args = Self.argsDict(call.arguments)
            let cacheDir = try requireString(args, "cache_dir", call.method)
            GobackendSetLibraryCoverCacheDirJSON(cacheDir)
            return nil
            
        case "scanLibraryFolder":
            let args = Self.argsDict(call.arguments)
            let folderPath = try requireString(args, "folder_path", call.method)
            let response: String? = try goCall { GobackendScanLibraryFolderJSON(folderPath, $0) }
            return bridgeJsonResult(response as String? ?? "[]")

        case "scanLibraryFolderToNDJSONFile":
            guard
                let args = call.arguments as? [String: Any],
                let folderPath = args["folder_path"] as? String,
                !folderPath.isEmpty,
                let outputPath = args["output_path"] as? String,
                !outputPath.isEmpty
            else {
                throw invalidArgumentsError(call.method)
            }
            var count = 0
            // `(int, error)` in Go binds to a BOOL C function whose
            // non-nullable first result comes back through an out-pointer,
            // followed by the `NSError **` out-parameter.
            let succeeded = try goCall { errPtr in
                withUnsafeMutablePointer(to: &count) { countPtr in
                    GobackendScanLibraryFolderToNDJSONFileJSON(folderPath, outputPath, countPtr, errPtr)
                }
            }
            if !succeeded {
                throw NSError(
                    domain: "SpotiFLAC",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Library scan failed"]
                )
            }
            return ["path": outputPath, "count": count]
            
        case "scanLibraryFolderIncremental":
            let args = Self.argsDict(call.arguments)
            let folderPath = try requireString(args, "folder_path", call.method)
            let existingFiles = args["existing_files"] as? String ?? "{}"
            let response: String? = try goCall { GobackendScanLibraryFolderIncrementalJSON(folderPath, existingFiles, $0) }
            return bridgeJsonResult(response as String? ?? "{}")
            
        case "getLibraryScanProgress":
            let response = GobackendGetLibraryScanProgressJSON()
            return parseJsonPayload(response as String? ?? "{}")
            
        case "cancelLibraryScan":
            GobackendCancelLibraryScanJSON()
            return nil
            
        case "readAudioMetadata":
            let args = Self.argsDict(call.arguments)
            let filePath = try requireString(args, "file_path", call.method)
            let response: String? = try goCall { GobackendReadAudioMetadataJSON(filePath, $0) }
            return response
        
        case "resolveIosBookmark":
            let args = Self.argsDict(call.arguments)
            let bookmarkBase64 = try requireString(args, "bookmark", call.method)
            return try resolveIosBookmark(bookmarkBase64)
            
        case "startAccessingIosBookmark":
            guard
                let args = call.arguments as? [String: Any],
                let bookmarkBase64 = args["bookmark"] as? String,
                !bookmarkBase64.isEmpty
            else {
                throw invalidArgumentsError(call.method)
            }
            return try startAccessingIosBookmark(bookmarkBase64)
            
        case "stopAccessingIosBookmark":
            guard
                let args = call.arguments as? [String: Any],
                let token = args["token"] as? String,
                !token.isEmpty
            else {
                throw invalidArgumentsError(call.method)
            }
            stopAccessingIosBookmark(token: token)
            return nil
            
        case "createIosBookmarkFromPath":
            let args = Self.argsDict(call.arguments)
            let path = try requireString(args, "path", call.method)
            return try createIosBookmarkFromPath(path)
            
        case "setLyricsProviders":
            let args = Self.argsDict(call.arguments)
            let providersJson = args["providers_json"] as? String ?? "[]"
            try goCall { GobackendSetLyricsProvidersJSON(providersJson, $0) }
            return "{\"success\":true}"
            
        case "getLyricsProviders":
            let response: String? = try goCall { GobackendGetLyricsProvidersJSON($0) }
            return response
            
        case "getAvailableLyricsProviders":
            let response: String? = try goCall { GobackendGetAvailableLyricsProvidersJSON($0) }
            return response
            
        case "setLyricsFetchOptions":
            let args = Self.argsDict(call.arguments)
            let optionsJson = args["options_json"] as? String ?? "{}"
            try goCall { GobackendSetLyricsFetchOptionsJSON(optionsJson, $0) }
            return "{\"success\":true}"
            
        case "getLyricsFetchOptions":
            let response: String? = try goCall { GobackendGetLyricsFetchOptionsJSON($0) }
            return response
            
        case "parseCueSheet":
            let args = Self.argsDict(call.arguments)
            let cuePath = try requireString(args, "cue_path", call.method)
            let audioDir = args["audio_dir"] as? String ?? ""
            let response: String? = try goCall { GobackendParseCueSheet(cuePath, audioDir, $0) }
            return response
            
        default:
            throw NSError(
                domain: "SpotiFLAC",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Method not implemented: \(call.method)"]
            )
        }
    }

    // MARK: - Safe argument extraction
    //
    // A `as!`/forced-unwrap on `call.arguments` traps the process
    // (fatalError) — it does NOT throw, so it cannot be caught by the
    // `do/catch` in `handleMethodCall`, and a single malformed or nil
    // argument kills the app. These helpers return optionals so callers
    // can throw a catchable bridge error instead.
    private static func argsDict(_ arguments: Any?) -> [String: Any] {
        return (arguments as? [String: Any]) ?? [:]
    }

    @discardableResult
    private func requireString(_ args: [String: Any]?, _ key: String, _ method: String) throws -> String {
        guard let value = args?[key] as? String else {
            throw NSError(
                domain: "SpotiFLAC",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "\(method): missing or invalid string argument '\(key)'"]
            )
        }
        return value
    }

    private func optionalString(_ args: [String: Any]?, _ key: String, _ fallback: String = "") -> String {
        return args?[key] as? String ?? fallback
    }

    private func requireMethodString(_ arguments: Any?, _ method: String) throws -> String {
        guard let value = arguments as? String else {
            throw NSError(
                domain: "SpotiFLAC",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "\(method): expected a string payload"]
            )
        }
        return value
    }

    // MARK: - Native Folder Picker

    /// Present a native folder picker and return `{path, bookmark}` where the
    /// security-scoped bookmark is created inside the picker callback, while
    /// the picker's access grant is still active. Returns nil on cancel.
    private func pickIosDirectory(result: @escaping FlutterResult) {
        if pendingDirectoryPickerResult != nil {
            result(FlutterError(
                code: "PICKER_ACTIVE",
                message: "A folder picker is already active",
                details: nil
            ))
            return
        }
        guard var topController = window?.rootViewController else {
            result(FlutterError(
                code: "NO_VIEW_CONTROLLER",
                message: "No view controller available to present the folder picker",
                details: nil
            ))
            return
        }
        while let presented = topController.presentedViewController {
            topController = presented
        }
        pendingDirectoryPickerResult = result
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        topController.present(picker, animated: true)
    }

    // MARK: - iOS Security-Scoped Bookmark Helpers

    /// Create a security-scoped bookmark from a filesystem path (e.g. from FilePicker).
    /// The path must currently be accessible (within the same picker session).
    /// Returns base64-encoded bookmark data.
    private func createIosBookmarkFromPath(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        do {
            #if os(macOS)
            let options: URL.BookmarkCreationOptions = .withSecurityScope
            #else
            let options: URL.BookmarkCreationOptions = []
            #endif
            let bookmarkData = try url.bookmarkData(
                options: options,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return bookmarkData.base64EncodedString()
        } catch {
            throw NSError(
                domain: "SpotiFLAC",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create bookmark for path \(path): \(error.localizedDescription)"]
            )
        }
    }
    
    /// Resolve a base64-encoded security-scoped bookmark and return the resolved path.
    /// Does NOT start accessing the resource.
    private func resolveIosBookmark(_ bookmarkBase64: String) throws -> String {
        guard let bookmarkData = Data(base64Encoded: bookmarkBase64) else {
            throw NSError(
                domain: "SpotiFLAC",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid base64 bookmark data"]
            )
        }
        
        var isStale = false
        let url: URL
        do {
            #if os(macOS)
            let options: URL.BookmarkResolutionOptions = .withSecurityScope
            #else
            let options: URL.BookmarkResolutionOptions = []
            #endif
            url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw NSError(
                domain: "SpotiFLAC",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to resolve bookmark: \(error.localizedDescription)"]
            )
        }
        
        return url.path
    }
    
    private func invalidArgumentsError(_ method: String) -> NSError {
        return NSError(
            domain: "SpotiFLAC",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Invalid arguments for \(method)"]
        )
    }

    /// Starts an independently owned security-scoped lease.
    private func startAccessingIosBookmark(_ bookmarkBase64: String) throws -> [String: String] {
        guard let bookmarkData = Data(base64Encoded: bookmarkBase64) else {
            throw NSError(
                domain: "SpotiFLAC",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid base64 bookmark data"]
            )
        }
        
        var isStale = false
        let url: URL
        do {
            #if os(macOS)
            let options: URL.BookmarkResolutionOptions = .withSecurityScope
            #else
            let options: URL.BookmarkResolutionOptions = []
            #endif
            url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw NSError(
                domain: "SpotiFLAC",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to resolve bookmark: \(error.localizedDescription)"]
            )
        }
        
        guard url.startAccessingSecurityScopedResource() else {
            throw NSError(
                domain: "SpotiFLAC",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to start accessing security-scoped resource at \(url.path)"]
            )
        }
        
        let token = UUID().uuidString
        securityScopedAccessLock.lock()
        securityScopedAccesses[token] = url
        securityScopedAccessLock.unlock()
        return ["path": url.path, "token": token]
    }
    
    /// Releases only the lease identified by the caller's token.
    private func stopAccessingIosBookmark(token: String) {
        securityScopedAccessLock.lock()
        let url = securityScopedAccesses.removeValue(forKey: token)
        securityScopedAccessLock.unlock()
        url?.stopAccessingSecurityScopedResource()
    }

    private func releaseAllSecurityScopedAccesses() {
        securityScopedAccessLock.lock()
        let urls = Array(securityScopedAccesses.values)
        securityScopedAccesses.removeAll()
        securityScopedAccessLock.unlock()
        for url in urls {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

@available(iOS 13.0, *)
extension AppDelegate: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return window ?? ASPresentationAnchor()
    }
}

extension AppDelegate: UIDocumentPickerDelegate {
    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard let result = pendingDirectoryPickerResult else { return }
        pendingDirectoryPickerResult = nil
        guard let url = urls.first else {
            result(nil)
            return
        }
        // The bookmark must be created here, from the picker's own URL, while
        // its security-scoped grant is active. A URL rebuilt from the path
        // string later has no grant, so bookmark creation either fails or
        // yields a bookmark that cannot re-open the folder.
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let bookmarkData = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            result([
                "path": url.path,
                "bookmark": bookmarkData.base64EncodedString(),
            ])
        } catch {
            result(FlutterError(
                code: "BOOKMARK_FAILED",
                message: "Failed to create bookmark for \(url.path): \(error.localizedDescription)",
                details: nil
            ))
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pendingDirectoryPickerResult?(nil)
        pendingDirectoryPickerResult = nil
    }
}

private final class ClosureStreamHandler: NSObject, FlutterStreamHandler {
    typealias ListenHandler = (_ arguments: Any?, _ events: @escaping FlutterEventSink) -> FlutterError?
    typealias CancelHandler = (_ arguments: Any?) -> FlutterError?

    private let onListenHandler: ListenHandler
    private let onCancelHandler: CancelHandler

    init(
        onListen: @escaping ListenHandler,
        onCancel: @escaping CancelHandler = { _ in nil }
    ) {
        self.onListenHandler = onListen
        self.onCancelHandler = onCancel
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        onListenHandler(arguments, events)
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        onCancelHandler(arguments)
    }
}

// MARK: - Apple ecosystem integration (Milestone 2)

extension AppDelegate {
    /// Creates the AirPlay / CarPlay / Siri / Live Activity channels.
    ///
    /// Called once, after a binary messenger is known to exist. Ordering
    /// matters only for CarPlay: the scene may already be connected (CarPlay
    /// can launch the app), so `CarPlayBridge.register` refreshes the
    /// templates if it finds an interface controller waiting.
    func registerAppleIntegrations(messenger: FlutterBinaryMessenger) {
        audioSessionController = AudioSessionController(messenger: messenger)
        airPlayController = AirPlayController(
            messenger: messenger, host: window?.rootViewController)
        liveActivityController = LiveActivityController(messenger: messenger)

        if #available(iOS 15.0, *) {
            siriIntentHandler = SiriIntentHandler(messenger: messenger)
        }
        if #available(iOS 14.0, *) {
            CarPlayBridge.shared.register(messenger: messenger)
        }
    }

    /// Routes "Hey Siri, play …" to the in-process intent handler.
    ///
    /// Handling the intent in the app (rather than in a separate Intents
    /// extension) means the handler can talk straight to the live Flutter
    /// engine, and one fewer target needs provisioning.
    override func application(
        _ application: UIApplication,
        handlerFor intent: INIntent
    ) -> Any? {
        if #available(iOS 15.0, *), intent is INPlayMediaIntent {
            return siriIntentHandler
        }
        return super.application(application, handlerFor: intent)
    }

    /// Declares the CarPlay scene so UIKit instantiates our delegate for it.
    ///
    /// CarPlay scenes carry the `CPTemplateApplicationSceneSessionRoleApplication`
    /// role; everything else falls through to Flutter's default handling.
    override func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if #available(iOS 14.0, *),
           connectingSceneSession.role == .carTemplateApplication {
            let configuration = UISceneConfiguration(
                name: "CarPlay", sessionRole: connectingSceneSession.role)
            configuration.delegateClass = CarPlaySceneDelegate.self
            return configuration
        }
        return UISceneConfiguration(
            name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}
