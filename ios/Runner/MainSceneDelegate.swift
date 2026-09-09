import UIKit
import Flutter

/// The main (phone) UI scene.
///
/// Info.plist declares `UIApplicationSceneManifest` (required for the CarPlay
/// template scene), which opts the app into the UIScene lifecycle: the system
/// keeps the launch storyboard on screen until a *scene delegate* creates a
/// window. Before this delegate existed, `application:configurationForConnecting:`
/// returned a main-role configuration with no delegate class and no storyboard,
/// so the window was never created and the app sat on the splash screen forever
/// while the process ran headless — the Flutter engine has no scene support of
/// its own (see `FlutterAppDelegate.rootFlutterViewController`, which only
/// inspects the app delegate's `window` property).
///
/// The Flutter view controller attaches to the engine the app delegate
/// pre-warms at launch (see `AppDelegate.sharedFlutterEngine`), so plugin
/// registration, the backend channels and the Apple ecosystem controllers all
/// keep working exactly as in the legacy storyboard lifecycle.
@available(iOS 13.0, *)
final class MainSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        let controller = FlutterViewController(
            engine: AppDelegate.sharedFlutterEngine,
            nibName: nil,
            bundle: nil)
        _ = controller.loadDefaultSplashScreenView()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window

        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }

        // The engine (and several AppDelegate helpers) resolve the root
        // FlutterViewController through the app delegate's `window`
        // (`FlutterAppDelegate.window`). In the scene lifecycle that property
        // is only ever assigned here — UIKit no longer sets it.
        appDelegate.window = window

        // In the UIScene lifecycle the cold-launch URL / user activity are no
        // longer delivered through `launchOptions` — they arrive with the
        // scene connection. Forward them through the same paths the app
        // delegate used in the legacy lifecycle.
        for context in connectionOptions.urlContexts {
            appDelegate.application(
                UIApplication.shared,
                open: context.url,
                options: [:])
        }
        for activity in connectionOptions.userActivities {
            appDelegate.handleSceneUserActivity(activity)
        }
    }

    /// Warm-launch `spotiflac://` deep links, OAuth callbacks and share
    /// intents. Routed through the app delegate's existing
    /// `application:open:options:` override so extension OAuth callbacks,
    /// signed-session grants and plugin URL handling behave identically to
    /// the legacy lifecycle.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        for context in URLContexts {
            _ = appDelegate.application(
                UIApplication.shared,
                open: context.url,
                options: [:])
        }
    }

    /// Share sheet / universal link continuations (NSUserActivity) also move
    /// from the app delegate to the scene delegate in the scene lifecycle.
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        appDelegate.handleSceneUserActivity(userActivity)
    }
}
