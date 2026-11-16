import ExactKit
import ExactUpdates
import SafariServices
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
  private var frame: Frame?

  func scene(_ scene: UIScene, willConnectTo _: UISceneSession, options: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    let session = AppDelegate.exact.makeSession(delegate: self, label: "screen")
    self.session = session
    let screen = Screen(session: session)
    self.screen = screen
    let window = ExactWindow(windowScene: scene)
    let frame = Frame(screen: screen)
    self.frame = frame
    window.rootViewController = frame
    window.makeKeyAndVisible()
    self.window = window
    options.urlContexts.first.map { open($0.url) }
    // A launch argument (`-HexOpen <link>`) opens a link too, without the prompt iOS shows before
    // `simctl openurl` hands one over (scripts/sim).
    UserDefaults.standard.string(forKey: "HexOpen").flatMap(URL.init(string:)).map { open($0) }
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    session?.becameActive()
    front = Date().timeIntervalSince1970
    sayFront(scene)
  }

  func sceneWillResignActive(_ scene: UIScene) {
    front = nil
    sayFront(scene)
  }

  func windowScene(_ scene: UIWindowScene, didUpdateEffectiveGeometry _: UIWindowScene.Geometry) {
    sayFront(scene)
  }

  /// scripts/phone takes a picture of the real Duo only while hex Exact alone fills its screen, so
  /// no other app's window is ever in it: `Library/HexFront` holds when the app last came to the
  /// front and whether its window fills the screen, and is gone while it's anywhere else.
  private var front: TimeInterval?
  private func sayFront(_ scene: UIScene) {
    let file = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appending(path: "HexFront")
    guard let front, let scene = scene as? UIWindowScene else {
      try? FileManager.default.removeItem(at: file)
      return
    }
    let fills = scene.coordinateSpace.bounds.size == scene.screen.bounds.size
    try? "\(front) \(fills ? "full" : "part")".write(to: file, atomically: true, encoding: .utf8)
  }

  func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
    contexts.first.map { open($0.url) }
  }

  /// An embedded session hands every `openURL` to its host: hex's own scheme stays here, a web page
  /// opens in Safari's sheet over the app (an app that claims its link, like Telegram, takes it
  /// instead), and any other link (T3 Code) goes to iOS; its answer goes back to the screen.
  func exactSession(_ session: ExactSession, command name: String, args: [Any]) {
    guard name == "openURL", let link = args.first as? String, let url = URL(string: link) else { return }
    MainActor.assumeIsolated {
      guard url.scheme != "hexexact" else { return open(url) }
      guard url.scheme == "https" || url.scheme == "http" else {
        return UIApplication.shared.open(url) { opened in session.answerOpenURL(args, opened: opened) }
      }
      UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { [weak self] opened in
        if !opened, let frame = self?.frame {
          var top: UIViewController = frame
          while let shown = top.presentedViewController { top = shown }
          top.present(SFSafariViewController(url: url), animated: true)
        }
        session.answerOpenURL(args, opened: true)
      }
    }
  }

  @MainActor
  private func open(_ url: URL) {
    guard url.scheme == "hexexact" else { return }
    switch url.host() {
    case "demo":
      Call.shared.startDemo()
      if !url.path().isEmpty, url.path() != "/" { go(url.path()) }
    case "go":
      screen?.follow(url)
      go(url.path().isEmpty ? "/" : url.path() + (url.query().map { "?" + $0 } ?? ""))
    default: break
    }
  }

  /// `navigate` drops a location the session hears before it has booted, as it does on a launch
  /// from a link; `openURL` keeps that one as the launch location, and navigates once booted.
  @MainActor
  private func go(_ location: String) {
    URL(string: location).map { _ = session?.openURL($0) }
  }
}
