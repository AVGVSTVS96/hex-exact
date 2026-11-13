import Foundation
import QuartzCore
import UIKit

/// The Exact screen's half of the bridge to the Swift shell (shell/Shell/Bridge.swift): the call's
/// state and words for `app.ts`, its commands for the shell, and the orb. The two halves meet on
/// NotificationCenter. With no shell around (a plain `exact ios` build, the agent), the call stays
/// idle and its commands go nowhere.
///
///   app.ts  native.watch('call');     native.call({op: 'call'})      → the call's state
///           native.watch('captions'); native.call({op: 'captions'})  → its words
///           native.later({op: 'start' | 'mute' | 'end', voice?, about?})
///   view    hex-orb state=… silenced=… tint=… still=…                         → levels straight from the shell
final class Hex: ExactModule {
  override class var views: [String: ExactNativeFactory] {
    ["hex-orb": ExactNativeFactory(for: Hex.self) { _, props, events in OrbInstance(props, events) }]
  }

  static let idle: [String: Any] = [
    "status": "idle", "id": "", "muted": false, "hexMuted": false, "interrupted": false,
    "started": 0, "error": "", "ending": "", "seconds": 0, "shell": false,
  ]

  private var state = Hex.idle
  private var captions: [String: Any] = ["call": "", "turns": [[String: Any]]()]
  private var observers: [NSObjectProtocol] = []

  required init(context: ExactModuleContext) {
    super.init(context: context)
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: Notification.Name("HexCallState"), object: nil, queue: .main) { [weak self] note in
      guard let self, let info = note.userInfo as? [String: Any] else { return }
      self.state = info
      self.context.changed("call")
    })
    observers.append(center.addObserver(forName: Notification.Name("HexCaptions"), object: nil, queue: .main) { [weak self] note in
      guard let self, let info = note.userInfo as? [String: Any] else { return }
      self.captions = info
      self.context.changed("captions")
    })
    center.post(name: Notification.Name("HexCallAsk"), object: nil)
  }

  override func call(_ request: [String: Any]) throws -> [String: Any] {
    switch request["op"] as? String {
    case "call": return state
    case "captions": return captions
    default: throw ExactNativeRefusal("hex answers call and captions")
    }
  }

  override func later(_ request: [String: Any], reply: ExactReply) {
    guard state["shell"] as? Bool == true else {
      return reply.send(["ok": false, "error": "Calls run in the hex Exact app on the phone."])
    }
    NotificationCenter.default.post(name: Notification.Name("HexCallCommand"), object: nil, userInfo: request)
    reply.send(["ok": true, "error": ""])
  }

  override func destroy() {
    observers.forEach(NotificationCenter.default.removeObserver)
  }
}

let exactModule: ExactModule.Type = Hex.self

/// `hex-orb`: hex, drawn. A sphere of slowly turning colour that breathes while idle, wakes while
/// connecting, swells with your voice while hex listens and with hex's while it speaks, and dims
/// when muted. Levels come from the shell many times a second, so they never cross into the
/// Contract.
final class OrbInstance: ExactNativeInstance {
  private let orb = OrbView()
  private var observer: NSObjectProtocol?

  init(_ props: [String: String], _ events: ExactNativeEvents) {
    super.init(events: events)
    try? setProps(props)
    observer = NotificationCenter.default.addObserver(forName: Notification.Name("HexCallLevels"), object: nil, queue: .main) { [weak self] note in
      let input = (note.userInfo?["input"] as? NSNumber)?.floatValue ?? 0
      let output = (note.userInfo?["output"] as? NSNumber)?.floatValue ?? 0
      self?.orb.levels(input: CGFloat(input), output: CGFloat(output))
    }
    events.intrinsicSize(CGSize(width: 240, height: 240))
  }

  override var view: ExactNativeView { orb }

  override func setProps(_ props: [String: String]) throws {
    orb.configure(status: props["state"] ?? "idle", muted: props["silenced"] == "true",
                  tint: props["tint"].flatMap(UIColor.init(hex:)), still: props["still"] == "true")
  }

  override func destroy() {
    observer.map(NotificationCenter.default.removeObserver)
  }
}

final class OrbView: UIView {
  private let glow = CAGradientLayer()
  private let ball = CALayer()
  private let swirl = CAGradientLayer()
  private let counter = CAGradientLayer()
  private let shade = CAGradientLayer()
  private let shine = CAGradientLayer()
  private var status = ""
  private var muted = false
  private var still = false
  private var level: CGFloat = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    glow.type = .radial
    layer.addSublayer(glow)
    ball.masksToBounds = true
    layer.addSublayer(ball)
    for conic in [swirl, counter] {
      conic.type = .conic
      conic.startPoint = CGPoint(x: 0.5, y: 0.5)
      conic.endPoint = CGPoint(x: 0.5, y: 0)
      ball.addSublayer(conic)
    }
    counter.opacity = 0.55
    shade.type = .radial
    shade.startPoint = CGPoint(x: 0.42, y: 0.38)
    shade.endPoint = CGPoint(x: 1.05, y: 1.05)
    shade.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.15).cgColor, UIColor.black.withAlphaComponent(0.75).cgColor]
    shade.locations = [0, 0.55, 1]
    ball.addSublayer(shade)
    shine.type = .radial
    shine.startPoint = CGPoint(x: 0.3, y: 0.24)
    shine.endPoint = CGPoint(x: 0.62, y: 0.56)
    shine.colors = [UIColor.white.withAlphaComponent(0.45).cgColor, UIColor.white.withAlphaComponent(0).cgColor]
    ball.addSublayer(shine)
    tint(nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layoutSubviews() {
    super.layoutSubviews()
    let side = min(bounds.width, bounds.height) * 0.78
    let frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ball.frame = frame
    ball.cornerRadius = side / 2
    let wide = side * 1.5
    for conic in [swirl, counter] {
      conic.bounds = CGRect(x: 0, y: 0, width: wide, height: wide)
      conic.position = CGPoint(x: side / 2, y: side / 2)
    }
    shade.frame = ball.bounds
    shine.frame = ball.bounds
    glow.frame = frame.insetBy(dx: -side * 0.32, dy: -side * 0.32)
    glow.startPoint = CGPoint(x: 0.5, y: 0.5)
    glow.endPoint = CGPoint(x: 1, y: 1)
    CATransaction.commit()
    animate()
  }

  func configure(status: String, muted: Bool, tint color: UIColor?, still: Bool) {
    let changed = status != self.status || muted != self.muted || still != self.still
    self.status = status
    self.muted = muted
    self.still = still || UIAccessibility.isReduceMotionEnabled
    tint(color)
    if changed { animate() }
  }

  /// A single colour (a persona colour) tints the sphere; none keeps hex's own spectrum.
  private func tint(_ color: UIColor?) {
    let colors: [UIColor] = color.map { c in [c, c.withAlphaComponent(0.55), c.mix(.systemIndigo), c, c.mix(.white), c] }
      ?? [.systemPink, .systemPurple, .systemIndigo, .systemTeal, .systemGreen, .systemYellow, .systemOrange, .systemRed, .systemPink]
    swirl.colors = colors.map(\.cgColor)
    counter.colors = colors.reversed().map { $0.withAlphaComponent(0.8).cgColor }
    glow.colors = [(color ?? .systemPurple).withAlphaComponent(0.28).cgColor, UIColor.clear.cgColor]
  }

  private var live: Bool { status == "live" }

  private func animate() {
    for conic in [swirl, counter] { conic.removeAllAnimations() }
    ball.removeAnimation(forKey: "breathe")
    glow.removeAnimation(forKey: "breathe")
    alpha = muted ? 0.55 : 1
    guard !still else { return }
    let busy = status == "connecting" || status == "ending"
    let turn = live ? 9.0 : busy ? 4.0 : 18.0
    for (conic, direction) in [(swirl, 1.0), (counter, -1.3)] {
      let spin = CABasicAnimation(keyPath: "transform.rotation.z")
      spin.byValue = direction * .pi * 2
      spin.duration = turn * abs(direction)
      spin.repeatCount = .infinity
      conic.add(spin, forKey: "spin")
    }
    guard !live else { return }
    let breathe = CABasicAnimation(keyPath: "transform.scale")
    breathe.fromValue = busy ? 0.94 : 0.965
    breathe.toValue = 1.0
    breathe.duration = busy ? 0.7 : 3.2
    breathe.autoreverses = true
    breathe.repeatCount = .infinity
    breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    ball.add(breathe, forKey: "breathe")
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0.55
    fade.toValue = 1
    fade.duration = breathe.duration
    fade.autoreverses = true
    fade.repeatCount = .infinity
    glow.add(fade, forKey: "breathe")
  }

  /// The louder side moves the orb: hex speaking (over 0.035, as the stable app reads it) or you.
  func levels(input: CGFloat, output: CGFloat) {
    guard live, !still else { return }
    let target = output > 0.035 ? min(1, output * 2.2) : muted ? 0 : min(1, input * 1.6)
    level += (target - level) * (target > level ? 0.55 : 0.18)
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.12)
    let scale = 1 + level * 0.12
    ball.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
    glow.opacity = Float(0.6 + level * 0.4)
    CATransaction.commit()
  }
}

private extension UIColor {
  convenience init?(hex: String) {
    let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
    self.init(red: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
  }

  func mix(_ other: UIColor) -> UIColor {
    var (r1, g1, b1, a1, r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0, 0, 0, 0, 0)
    getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
    other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
    return UIColor(red: (r1 + r2) / 2, green: (g1 + g2) / 2, blue: (b1 + b2) / 2, alpha: 1)
  }
}
