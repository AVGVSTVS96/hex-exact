import ExactKit
import UIKit

/// The window's root: the Exact screen, the ways it may turn, and what the Duo's frame takes from it.
///
/// A plain iPhone stays upright; iPad and iPhone Duo turn however they're held. The Duo is the
/// iPhone with a vertical bar edge: iOS gives its cover screen one in every orientation, and no other
/// iPhone one. That edge arrives a moment after iOS first asks, so until it does the screen's shape
/// answers: the Duo's are near square, every other iPhone's 16 by 9 or taller.
///
/// Its pose (which side the system bars sit on, where the fold lies, what the cameras cover) goes to
/// the screen as `HexPose` each time it changes, as Exact's viewport reports only segments and safe
/// areas. `hexexact://go/…?split=first|second&share=0.4` draws the app in part of the window, as
/// Split View would, and `report=pose` keeps each pose in the `HexPose` default for tests.
final class Screen: UIViewController {
  static let pose = Notification.Name("HexPose")
  static let asked = Notification.Name("HexPoseAsk")

  let exact: ExactView
  private var split: (side: String, share: CGFloat)?
  private var reporting = false
  private var reported: NSDictionary?
  private var barSeen = false
  private var edgeKnown = false

  init(session: ExactSession) {
    exact = ExactView(session: session)
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    view.addSubview(exact)
    NotificationCenter.default.addObserver(forName: Self.asked, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.reported = nil
        self?.view.setNeedsLayout()
      }
    }
    if #available(iOS 27.1, *) {
      registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) { (screen: Self, _) in
        screen.edgeKnown = true
        screen.setNeedsUpdateOfSupportedInterfaceOrientations()
        screen.view.setNeedsLayout()
      }
    }
  }

  /// Opened with `split=` or `report=`: how much of the window the app takes, and whether to log.
  func follow(_ url: URL) {
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let value = { (name: String) in query.first { $0.name == name }?.value }
    if let side = value("split") {
      let share = Double(value("share") ?? "").map { CGFloat($0) }.flatMap { $0 > 0 && $0 < 1 ? $0 : nil } ?? 0.5
      split = side == "first" || side == "second" ? (side, share) : nil
    }
    if value("report") == "pose" { reporting = true }
    reported = nil
    view.setNeedsLayout()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    var frame = view.bounds
    if let split {
      frame.size.width = (view.bounds.width * split.share).rounded()
      if split.side == "second" { frame.origin.x = view.bounds.width - frame.width }
    }
    exact.frame = frame
    exact.backgroundColor = split == nil ? nil : .systemBackground
    view.backgroundColor = split == nil ? .systemBackground : .separator
    let pose = NSDictionary(dictionary: current())
    guard pose != reported else { return }
    reported = pose
    NotificationCenter.default.post(name: Self.pose, object: nil, userInfo: pose as? [String: Any])
    if reporting, let data = try? JSONSerialization.data(withJSONObject: pose) {
      UserDefaults.standard.set(String(data: data, encoding: .utf8), forKey: "HexPose")
    }
  }

  /// In the Exact screen's own points: bar `left`, `right` or "", the fold's rectangle (or none), and
  /// what the cameras and system bars cover.
  private func current() -> [String: Any] {
    var pose: [String: Any] = ["bar": "", "fold": [String: Any](), "occlusions": [[String: Any]]()]
    guard #available(iOS 27.1, *) else { return pose }
    let rtl = traitCollection.layoutDirection == .rightToLeft
    switch traitCollection.verticalBarEdge {
    case .leading: pose["bar"] = rtl ? "right" : "left"
    case .trailing: pose["bar"] = rtl ? "left" : "right"
    default: break
    }
    if let fold = exact.reservedRegions(kind: .division, options: .includeInactive).first {
      pose["fold"] = rect(fold.frame)
    }
    pose["occlusions"] = exact.reservedRegions(kind: .occlusion).map { rect($0.frame) }
    return pose
  }

  private func rect(_ frame: CGRect) -> [String: Any] {
    ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
  }

  override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
    turns ? .all : .portrait
  }

  /// Once seen, a bar edge stays seen: iOS leaves it unspecified in orientations without a vertical
  /// bar, so an answer read fresh each time could undo the turn it allowed.
  private var turns: Bool {
    if UIDevice.current.userInterfaceIdiom == .pad { return true }
    guard #available(iOS 27.1, *) else { return false }
    if traitCollection.verticalBarEdge != .unspecified { barSeen = true }
    return barSeen || (!edgeKnown && squareScreen)
  }

  private var squareScreen: Bool {
    let size = (view.window?.windowScene?.screen ?? UIScreen.main).bounds.size
    return max(size.width, size.height) / min(size.width, size.height) < 1.6
  }
}
