import CarPlay
import Flutter
import Foundation
import UIKit

/// CarPlay audio-app scene (Milestone 2).
///
/// CarPlay runs in its *own* UIScene, which may be created before, after, or
/// entirely without the phone UI, so this delegate cannot assume a Flutter
/// engine already exists. It resolves the shared engine through
/// `CarPlayBridge`, which the AppDelegate populates on launch; until Dart has
/// registered its handler the templates render a "Loading…" placeholder
/// rather than an empty list, because an empty root template makes CarPlay
/// look broken.
///
/// The content model deliberately mirrors `lib/services/media_browse_tree.dart`
/// (the tree Android Auto already uses) so the two head-unit experiences stay
/// in sync and there is exactly one definition of "what can I browse".
@available(iOS 14.0, *)
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        CarPlayBridge.shared.attach(interfaceController: interfaceController)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        CarPlayBridge.shared.detach()
        self.interfaceController = nil
    }
}

/// Owns the CarPlay UI and the Dart round-trips that fill it.
///
/// A singleton because CarPlay's scene delegate is instantiated by UIKit and
/// cannot be handed dependencies, while the Flutter engine is owned by the
/// AppDelegate: the bridge is the meeting point. All UIKit work happens on
/// the main queue.
@available(iOS 14.0, *)
final class CarPlayBridge: NSObject, CPSearchTemplateDelegate {
    static let shared = CarPlayBridge()

    /// Channel name; mirrored by `lib/services/carplay_service.dart`.
    static let channelName = "com.zarz.spotiflac/carplay"

    private var channel: FlutterMethodChannel?
    private weak var interfaceController: CPInterfaceController?

    /// Set once the root template is installed, so a late Dart registration
    /// can refresh instead of re-installing (which would pop the user's
    /// navigation stack out from under them).
    private var rootInstalled = false

    private override init() { super.init() }

    // MARK: - Wiring

    /// Called by the AppDelegate once the Flutter engine exists.
    func register(messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handleFromDart(call, result: result)
        }
        self.channel = channel
        // Dart may become ready after CarPlay connected; refresh so the
        // placeholder is replaced as soon as real data can be fetched.
        if interfaceController != nil {
            DispatchQueue.main.async { [weak self] in self?.installRoot() }
        }
    }

    func attach(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        rootInstalled = false
        installRoot()
    }

    func detach() {
        interfaceController = nil
        rootInstalled = false
    }

    // MARK: - Dart → native

    private func handleFromDart(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isConnected":
            result(interfaceController != nil)
        case "invalidate":
            // Dart's library changed (a download finished, a playlist was
            // edited); rebuild the visible list.
            DispatchQueue.main.async { [weak self] in self?.installRoot() }
            result(true)
        case "updateNowPlaying":
            // CPNowPlayingTemplate renders from MPNowPlayingInfoCenter, which
            // audio_service already maintains, so there is nothing to push
            // here — acknowledging keeps the Dart API uniform.
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Native → Dart

    /// Asks Dart for a container's children. Errors and timeouts resolve to
    /// an empty list: a head unit must never be left with a spinner.
    private func children(of parentId: String, completion: @escaping ([CarPlayItem]) -> Void) {
        guard let channel = channel else {
            completion([])
            return
        }
        channel.invokeMethod("browse", arguments: ["parentId": parentId]) { response in
            completion(CarPlayItem.parseList(response))
        }
    }

    private func play(itemId: String, parentId: String) {
        channel?.invokeMethod("play", arguments: ["itemId": itemId, "parentId": parentId])
    }

    // MARK: - Templates

    private func installRoot() {
        guard let interfaceController = interfaceController else { return }

        let tabs = CPTabBarTemplate(templates: [
            listTemplate(title: "Library", parentId: "__ROOT__",
                         image: UIImage(systemName: "music.note.list")),
            listTemplate(title: "Playlists", parentId: "browse:playlists",
                         image: UIImage(systemName: "music.note.house")),
            listTemplate(title: "Recent", parentId: "browse:recent",
                         image: UIImage(systemName: "clock")),
            searchTab(),
            nowPlayingTab(),
        ])

        if rootInstalled {
            interfaceController.setRootTemplate(tabs, animated: false, completion: nil)
        } else {
            rootInstalled = true
            interfaceController.setRootTemplate(tabs, animated: false, completion: nil)
        }
    }

    private func nowPlayingTab() -> CPTemplate {
        let template = CPNowPlayingTemplate.shared
        template.tabTitle = "Now Playing"
        template.tabImage = UIImage(systemName: "play.circle")
        return template
    }

    private func searchTab() -> CPSearchTemplate {
        let template = CPSearchTemplate()
        template.tabTitle = "Search"
        template.tabImage = UIImage(systemName: "magnifyingglass")
        template.delegate = self
        return template
    }

    /// Asks Dart for voice / typed search hits.
    private func search(_ query: String, completion: @escaping ([CarPlayItem]) -> Void) {
        guard let channel = channel else {
            completion([])
            return
        }
        channel.invokeMethod("search", arguments: ["query": query]) { response in
            completion(CarPlayItem.parseList(response))
        }
    }

    /// Builds a list template that lazily fills itself from Dart.
    private func listTemplate(title: String, parentId: String, image: UIImage?) -> CPListTemplate {
        let loading = CPListItem(text: "Loading…", detailText: nil)
        let section = CPListSection(items: [loading])
        let template = CPListTemplate(title: title, sections: [section])
        template.tabTitle = title
        template.tabImage = image

        children(of: parentId) { [weak self, weak template] items in
            guard let self = self, let template = template else { return }
            let listItems = items.map { item -> CPListItem in
                let row = CPListItem(text: item.title, detailText: item.subtitle)
                if item.isBrowsable {
                    row.accessoryType = .disclosureIndicator
                }
                row.handler = { [weak self] _, completion in
                    guard let self = self else {
                        completion()
                        return
                    }
                    if item.isBrowsable {
                        self.pushList(title: item.title, parentId: item.id, completion: completion)
                    } else {
                        self.play(itemId: item.id, parentId: parentId)
                        // Surfacing Now Playing immediately is what a driver
                        // expects after tapping a track.
                        self.interfaceController?.pushTemplate(
                            CPNowPlayingTemplate.shared, animated: true) { _, _ in completion() }
                    }
                }
                return row
            }
            let resolved = listItems.isEmpty
                ? [CPListItem(text: "Nothing here yet", detailText: nil)]
                : listItems
            template.updateSections([CPListSection(items: resolved)])
        }
        return template
    }

    private func pushList(title: String, parentId: String, completion: @escaping () -> Void) {
        let template = listTemplate(title: title, parentId: parentId, image: nil)
        interfaceController?.pushTemplate(template, animated: true) { _, _ in completion() }
    }

    // MARK: - CPSearchTemplateDelegate

    /// Runs the driver's typed / voice query against Dart's offline search
    /// (the same tree Android Auto uses) and hands the hits back as one
    /// section. Dart search rows are flat and always playable, so a tap
    /// plays the track directly.
    @objc func template(
        _ template: CPSearchTemplate,
        didSearchForQuery query: String,
        completionHandler: @escaping ([CPListSection]) -> Void
    ) {
        search(query) { items in
            let rows = items.map { item -> CPListItem in
                let row = CPListItem(text: item.title, detailText: item.subtitle)
                if item.isBrowsable {
                    row.accessoryType = .disclosureIndicator
                }
                row.handler = { [weak self] _, completion in
                    guard let self = self else {
                        completion()
                        return
                    }
                    if item.isBrowsable {
                        self.pushList(title: item.title, parentId: item.id, completion: completion)
                    } else {
                        self.play(itemId: item.id, parentId: item.id)
                        // Surfacing Now Playing immediately is what a driver
                        // expects after tapping a track.
                        self.interfaceController?.pushTemplate(
                            CPNowPlayingTemplate.shared, animated: true) { _, _ in completion() }
                    }
                }
                return row
            }
            completionHandler([CPListSection(items: rows)])
        }
    }
}

/// One browsable or playable row, as Dart describes it.
struct CarPlayItem {
    let id: String
    let title: String
    let subtitle: String?
    let isBrowsable: Bool

    /// Parses the `browse` reply. Anything malformed is skipped rather than
    /// failing the whole list — a single bad row must not blank the screen.
    static func parseList(_ response: Any?) -> [CarPlayItem] {
        guard let raw = response as? [Any] else { return [] }
        return raw.compactMap { entry in
            guard
                let map = entry as? [String: Any],
                let id = map["id"] as? String,
                let title = map["title"] as? String,
                !id.isEmpty
            else { return nil }
            return CarPlayItem(
                id: id,
                title: title,
                subtitle: map["subtitle"] as? String,
                isBrowsable: (map["isBrowsable"] as? Bool) ?? false
            )
        }
    }
}
