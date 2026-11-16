import UIKit

/// The frame around the Exact screen: hex's pages (Now, Feed, Ideas, Goals) as the system's tabs,
/// and Calls, Tasks and Settings, with Back on a page opened over Home, as its bar buttons. iOS
/// puts them where a phone's bars go: on the iPhone Duo folded, in the vertical bar down the
/// screen's edge under the status icons, and the page stops at that column (its safe area), as
/// it does open like a book; open like a laptop, the bar along the top and the tab bar at the foot.
/// A page opened over Home (Back shows) hides the tabs, as a pushed page does.
///
/// The screen asks for them (`op: bars` through Bridge: the pages, the one showing, whether Back
/// shows, whether anything needs Bassim) and until it does the frame draws nothing, so a screen
/// from before it keeps its own bars. Each tap goes back in the pose (`Screen.bars`): `tap` says
/// what (`page:<id>`, `open:calls|tasks|settings`, `back`) and `taps` counts, so the same tap
/// twice is heard twice. The one Exact screen moves into whichever tab shows.
final class Frame: UITabBarController, UITabBarControllerDelegate {
  static let asked = Notification.Name("HexBars")

  private let screen: Screen
  private var pages: [String] = []
  private var page = ""
  private var shown = false
  private var back = false
  private var needs = false
  private var taps = 0
  private var stacks: [String: UINavigationController] = [:]

  init(screen: Screen) {
    self.screen = screen
    super.init(nibName: nil, bundle: nil)
    delegate = self
    screen.bars = ["frame": true, "bars": false, "tap": "", "taps": 0]
    setViewControllers([stack("now")], animated: false)
    setTabBarHidden(true, animated: false)
    NotificationCenter.default.addObserver(forName: Self.asked, object: nil, queue: .main) { [weak self] note in
      let ask = note.userInfo ?? [:]
      MainActor.assumeIsolated { self?.follow(ask) }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  // The tab controller loads its view while its tabs are first set, before one is selected, so the
  // screen goes in once it lays out.
  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    hold()
  }

  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { screen.supportedInterfaceOrientations }

  /// What the screen asked for: `pages` (none or one: no tabs), `page`, `shown` (the bars at all),
  /// `back` and `needs`.
  private func follow(_ ask: [AnyHashable: Any]) {
    let pages = ask["pages"] as? [String] ?? []
    let page = ask["page"] as? String ?? ""
    let shown = ask["shown"] as? Bool ?? false
    let back = ask["back"] as? Bool ?? false
    let needs = ask["needs"] as? Bool ?? false
    if pages != self.pages {
      self.pages = pages
      setViewControllers((pages.isEmpty ? ["now"] : pages).map(stack), animated: false)
    }
    if let at = pages.firstIndex(of: page), at != selectedIndex { selectedIndex = at }
    self.page = page
    if shown != self.shown || back != self.back || needs != self.needs {
      self.shown = shown
      self.back = back
      self.needs = needs
      stacks.values.forEach(dress)
    }
    let tabs = shown && pages.count > 1 && !back
    if isTabBarHidden == tabs { setTabBarHidden(!tabs, animated: false) }
    hold()
    say(tap: screen.bars["tap"] as? String ?? "", counted: false)
  }

  /// A page's tab: a stack whose root holds the Exact screen while the tab shows.
  private func stack(_ id: String) -> UINavigationController {
    if let made = stacks[id] { return made }
    let holder = UIViewController()
    holder.view.backgroundColor = .clear
    let made = UINavigationController(rootViewController: holder)
    made.navigationBar.prefersLargeTitles = false
    let tab: (title: String, symbol: String) = switch id {
    case "feed": ("Feed", "newspaper")
    case "ideas": ("Ideas", "lightbulb")
    case "goals": ("Goals", "flag")
    default: ("Now", "smallcircle.filled.circle")
    }
    made.tabBarItem = UITabBarItem(title: tab.title, image: UIImage(systemName: tab.symbol), tag: 0)
    made.tabBarItem.accessibilityIdentifier = "tab-\(id)"
    stacks[id] = made
    dress(made)
    return made
  }

  private func dress(_ stack: UINavigationController) {
    guard let holder = stack.viewControllers.first else { return }
    let item = { (symbol: String, label: String, tap: String) -> UIBarButtonItem in
      let made = UIBarButtonItem(title: label, image: UIImage(systemName: symbol), primaryAction: UIAction(title: label) { [weak self] _ in
        self?.say(tap: tap, counted: true)
      })
      made.accessibilityLabel = label
      made.accessibilityIdentifier = "bar-\(tap.replacingOccurrences(of: "open:", with: ""))"
      return made
    }
    let tasks = item("list.bullet", "Tasks", "open:tasks")
    if needs {
      // hex.ask's colour (app.tamber), as the app's own dot was.
      var dot = UIBarButtonItem.Badge.indicator()
      dot.backgroundColor = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0xF2 / 255, green: 0xC5 / 255, blue: 0x8A / 255, alpha: 1)
        : UIColor(red: 0xA3 / 255, green: 0x5F / 255, blue: 0, alpha: 1) }
      tasks.badge = dot
    }
    // Folded on its side, the Duo's column has room for one button and tucks the rest under More,
    // keeping the last of these: Tasks, so its dot stays in sight.
    holder.navigationItem.rightBarButtonItems = [
      item("slider.horizontal.3", "Settings", "open:settings"),
      item("clock.arrow.circlepath", "Calls", "open:calls"), tasks,
    ]
    holder.navigationItem.leftBarButtonItem = back ? item("chevron.backward", "Back", "back") : nil
    stack.setNavigationBarHidden(!shown, animated: false)
  }

  /// The Exact screen, in the tab that shows.
  private func hold() {
    guard isViewLoaded, let holder = (selectedViewController as? UINavigationController)?.viewControllers.first,
      screen.parent !== holder
    else { return }
    if screen.parent != nil {
      screen.willMove(toParent: nil)
      screen.view.removeFromSuperview()
      screen.removeFromParent()
    }
    holder.addChild(screen)
    screen.view.frame = holder.view.bounds
    screen.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    holder.view.addSubview(screen.view)
    screen.didMove(toParent: holder)
  }

  private func say(tap: String, counted: Bool) {
    if counted { taps += 1 }
    screen.bars = ["frame": true, "bars": shown, "tap": tap, "taps": taps]
    screen.view.setNeedsLayout()
  }

  func tabBarController(_ tabs: UITabBarController, shouldSelect next: UIViewController) -> Bool {
    // The shown tab again: back to that page's top, as a tab bar does.
    if next === selectedViewController, let id = stacks.first(where: { $0.value === next })?.key {
      say(tap: "page:\(id)", counted: true)
    }
    return true
  }

  func tabBarController(_ tabs: UITabBarController, didSelect next: UIViewController) {
    hold()
    guard let id = stacks.first(where: { $0.value === next })?.key, id != page else { return }
    page = id
    say(tap: "page:\(id)", counted: true)
  }
}
