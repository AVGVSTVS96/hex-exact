import ExactKit
import ExactUpdates
import UIKit

/// The shell: a plain UIKit app that holds what Exact defers (the WebRTC call, Siri, the Live
/// Activity) and shows one Exact session as its whole screen.
///
///   Exact screen ──openURL("hexexact://call" | "…/mute" | "…/end")──▶ shell ──▶ Call
///   Call ──changed──▶ shell ──navigate("/call/<status>/<muted>")──▶ Exact screen
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

  func scene(_ scene: UIScene, willConnectTo _: UISceneSession, options: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    let session = AppDelegate.exact.makeSession(delegate: self, label: "screen")
    self.session = session
    let screen = UIViewController()
    let view = ExactView(session: session)
    view.frame = screen.view.bounds
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    screen.view.addSubview(view)
    let window = ExactWindow(windowScene: scene)
    window.rootViewController = screen
    window.makeKeyAndVisible()
    self.window = window
    NotificationCenter.default.addObserver(forName: Call.changed, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.show(Call.shared) }
    }
    options.urlContexts.first.map { open($0.url) }
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    session?.becameActive()
  }

  func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
    contexts.first.map { open($0.url) }
  }

  func exactSession(_ session: ExactSession, command name: String, args: [Any]) {
    guard name == "openURL", let link = args.first as? String, let url = URL(string: link) else { return }
    MainActor.assumeIsolated { open(url) }
  }

  @MainActor
  private func open(_ url: URL) {
    guard url.scheme == "hexexact" else { return }
    switch url.host() {
    case "call": Call.shared.start()
    case "mute": Call.shared.toggleMute()
    case "end": Call.shared.end()
    default: break
    }
  }

  @MainActor
  private func show(_ call: Call) {
    CallLiveActivity.follow(call)
    session?.navigate(location(of: call))
  }

  @MainActor
  private func location(of call: Call) -> String {
    switch (call.status, call.failure) {
    case (.idle, nil): "/"
    case (.idle, let failure?): "/failed/\(failure.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"
    case (let status, _): "/call/\(status.rawValue)/\(call.muted ? "muted" : "open")"
    }
  }
}
