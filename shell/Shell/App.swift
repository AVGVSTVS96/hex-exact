import ExactKit
import ExactUpdates
import UIKit

/// The shell: a plain UIKit app that holds what Exact defers (the WebRTC call, Siri, the Live
/// Activity) and shows one Exact session as its whole screen. The call reaches the screen through
/// `Bridge` and the app's native module; `hexexact://go/<path>` opens a screen (Siri, tests), and
/// `hexexact://demo[/<path>]` starts the demo call (scripts/sim's `call:` paths).
///
/// Exact's own delivery stays on (ExactUpdates), so a new plan reaches the screen over the air.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  static let exact: ExactApp = {
    let app = ExactApp.shared
    ExactUpdates.install(on: app)
    return app
  }()

  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    NotificationCenter.default.addObserver(forName: EndCall.ended, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { Call.shared.end() }
    }
    NotificationCenter.default.addObserver(forName: MuteCall.toggled, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { Call.shared.toggleMute() }
    }
    MainActor.assumeIsolated {
      CallLiveActivity.clearLeftovers()
      Bridge.connect()
    }
    return true
  }

  func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    configuration.delegateClass = SceneDelegate.self
    return configuration
  }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate, ExactSessionDelegate {
  var window: UIWindow?
  private var session: ExactSession?
  private var screen: Screen?

  func scene(_ scene: UIScene, willConnectTo _: UISceneSession, options: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    let session = AppDelegate.exact.makeSession(delegate: self, label: "screen")
    self.session = session
    let screen = Screen(session: session)
    self.screen = screen
    let window = ExactWindow(windowScene: scene)
    window.rootViewController = screen
    window.makeKeyAndVisible()
    self.window = window
    options.urlContexts.first.map { open($0.url) }
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    session?.becameActive()
  }

  func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
    contexts.first.map { open($0.url) }
  }

  /// An embedded session hands every `openURL` to its host: hex's own scheme stays here, and a link
  /// out (Telegram, T3 Code, a web page) goes to iOS, its answer back to the screen.
  func exactSession(_ session: ExactSession, command name: String, args: [Any]) {
    guard name == "openURL", let link = args.first as? String, let url = URL(string: link) else { return }
    MainActor.assumeIsolated {
      guard url.scheme != "hexexact" else { return open(url) }
      UIApplication.shared.open(url) { opened in session.answerOpenURL(args, opened: opened) }
    }
  }

  @MainActor
  private func open(_ url: URL) {
    guard url.scheme == "hexexact" else { return }
    switch url.host() {
    case "demo":
      Call.shared.startDemo()
      if !url.path().isEmpty, url.path() != "/" { session?.navigate(url.path()) }
    case "go":
      screen?.follow(url)
      session?.navigate(url.path().isEmpty ? "/" : url.path() + (url.query().map { "?" + $0 } ?? ""))
    default: break
    }
  }
}
