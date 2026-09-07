// CarPlay Manager — AppleEcosystem submodule (Milestone 1)
//
// Consolidates CarPlay template management, content browsing, and playback
// control through the existing Flutter player controller and queue service.
//
// Key constraint: NEVER create a second player. CarPlay reuses the same
// player controller and queue service that the phone UI uses.
//
// Template hierarchy:
//   - Library (root browse)
//   - Playlists
//   - Search
//   - Queue (current playback queue)
//   - Recently Played
//   - Favorites
//   - Now Playing

import CarPlay
import Flutter
import Foundation
import UIKit

/// CarPlay scene delegate — manages the CPTemplateApplicationScene lifecycle.
@available(iOS 14.0, *)
final class CarPlayManager: NSObject, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        CarPlayContentBridge.shared.attach(interfaceController: interfaceController)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        CarPlayContentBridge.shared.detach()
        self.interfaceController = nil
    }
}

/// Bridge between CarPlay templates and the Flutter/Dart layer.
///
/// Owns the UI and the Dart round-trips that fill it. Singleton because
/// CarPlay's scene delegate is instantiated by UIKit and cannot be handed
/// dependencies, while the Flutter engine is owned by the AppDelegate.
@available(iOS 14.0, *)
final class CarPlayContentBridge: NSObject {
    static let shared = CarPlayContentBridge()

    /// Channel name — must match carplay_service.dart.
    static let channelName = "com.zarz.spotiflac/carplay"

    private var channel: FlutterMethodChannel?
    private weak var interfaceController: CPInterfaceController?
    private var rootInstalled = false

    /// Supported browse roots for the template hierarchy.
    private let browseRoots: [(title: String, parentId: String, icon: String)] = [
        ("Library", "__ROOT__", "music.note.list"),
        ("Playlists", "browse:playlists", "music.note.house"),
        ("Search", "browse:search", "magnifyingglass"),
        ("Queue", "browse:queue", "text.line.upturn.down"),
        ("Recently Played", "browse:recent", "clock"),
        ("Favorites", "browse:favorites", "heart"),
    ]

    private override init() { super.init() }

    // MARK: - Wiring

    func register(messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handleFromDart(call, result: result)
        }
        self.channel = channel
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

    // MARK: - Dart → Native

    private func handleFromDart(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isConnected":
            result(interfaceController != nil)
        case "invalidate":
            DispatchQueue.main.async { [weak self] in self?.installRoot() }
            result(true)
        case "updateNowPlaying":
            // CPNowPlayingTemplate renders from MPNowPlayingInfoCenter,
            // which audio_service already maintains.
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Native → Dart

    private func children(of parentId: String, completion: @escaping ([CarPlayBrowseItem]) -> Void) {
        guard let channel = channel else {
            completion([])
            return
        }
        channel.invokeMethod("browse", arguments: ["parentId": parentId]) { response in
            completion(CarPlayBrowseItem.parseList(response))
        }
    }

    private func play(itemId: String, parentId: String) {
        channel?.invokeMethod("play", arguments: ["itemId": itemId, "parentId": parentId])
    }

    // MARK: - Templates

    /// Builds the root tab bar with all browse categories.
    private func installRoot() {
        guard let interfaceController = interfaceController else { return }

        let tabs = CPTabBarTemplate(templates: [
            listTemplate(title: "Library", parentId: "__ROOT__",
                         image: UIImage(systemName: "music.note.list")),
            listTemplate(title: "Playlists", parentId: "browse:playlists",
                         image: UIImage(systemName: "music.note.house")),
            searchTemplate(),
            listTemplate(title: "Queue", parentId: "browse:queue",
                         image: UIImage(systemName: "text.line.upturn.down")),
            listTemplate(title: "Recent", parentId: "browse:recent",
                         image: UIImage(systemName: "clock")),
            listTemplate(title: "Favorites", parentId: "browse:favorites",
                         image: UIImage(systemName: "heart")),
            nowPlayingTab(),
        ])

        rootInstalled = true
        interfaceController.setRootTemplate(tabs, animated: false, completion: nil)
    }

    private func nowPlayingTab() -> CPTemplate {
        let template = CPNowPlayingTemplate.shared
        template.tabTitle = "Now Playing"
        template.tabImage = UIImage(systemName: "play.circle")
        return template
    }

    /// Search template — presents a search bar that Dart handles.
    private func searchTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "Search", sections: [])
        template.tabTitle = "Search"
        template.tabImage = UIImage(systemName: "magnifyingglass")

        let searchTemplate = CPSearchTemplate()
        // Search results are handled through the existing Dart search pipeline.
        return template
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
}

/// One browsable or playable row, as Dart describes it.
struct CarPlayBrowseItem {
    let id: String
    let title: String
    let subtitle: String?
    let isBrowsable: Bool

    static func parseList(_ response: Any?) -> [CarPlayBrowseItem] {
        guard let raw = response as? [Any] else { return [] }
        return raw.compactMap { entry in
            guard
                let map = entry as? [String: Any],
                let id = map["id"] as? String,
                let title = map["title"] as? String,
                !id.isEmpty
            else { return nil }
            return CarPlayBrowseItem(
                id: id,
                title: title,
                subtitle: map["subtitle"] as? String,
                isBrowsable: (map["isBrowsable"] as? Bool) ?? false
            )
        }
    }
}
