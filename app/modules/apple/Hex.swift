import AVFoundation
import Foundation
import QuartzCore
import QuickLook
import UIKit
#if canImport(RiveRuntime)
  import RiveRuntime
#endif

/// The Exact screen's half of the bridge to the Swift shell (shell/Shell/Bridge.swift): the call's
/// state and words for `app.ts`, its commands for the shell, the orb, and hex's photos and videos.
/// The two halves meet on NotificationCenter. With no shell around (a plain `exact ios` build, the
/// agent), the call stays idle and its commands are refused.
///
///   app.ts  native.watch('call');     native.call({op: 'call'})      → the call's state
///           native.watch('captions'); native.call({op: 'captions'})  → its words and shared media
///           native.watch('pose');     native.call({op: 'pose'})      → the Duo's bar side, fold, occlusions
///           native.later({op: start | mute | end | preview | share | attach | retry, …})
///   views   hex-orb state=… silenced=… persona=… tint=… palette=… reaction=… still=… speak=…
///           hex-media media=<id> kind=photo|video anchor=top|center  → an authed thumbnail; tap to look
///           hex-color hue=#RRGGBB custom=true|false change=…  → iOS's colour well; change hears #RRGGBB
final class Hex: ExactModule {
  override class var views: [String: ExactNativeFactory] {
    [
      "hex-orb": ExactNativeFactory(for: Hex.self) { _, props, events in OrbInstance(props, events) },
      "hex-media": ExactNativeFactory(for: Hex.self, reuse: true) { _, props, events in MediaInstance(props, events) },
      "hex-color": ExactNativeFactory(for: Hex.self) { _, props, events in ColorInstance(props, events) },
    ]
  }

  static let idle: [String: Any] = [
    "status": "idle", "id": "", "muted": false, "interrupted": false,
    "started": 0, "error": "", "ending": "", "seconds": 0, "shell": false, "demo": false,
  ]

  private var state = Hex.idle
  private var captions: [String: Any] = ["call": "", "turns": [[String: Any]]()]
  private var pose: [String: Any] = ["bar": "", "fold": [String: Any](), "occlusions": [[String: Any]]()]
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
    observers.append(center.addObserver(forName: Notification.Name("HexPose"), object: nil, queue: .main) { [weak self] note in
      guard let self, let info = note.userInfo as? [String: Any] else { return }
      self.pose = info
      self.context.changed("pose")
    })
    center.post(name: Notification.Name("HexCallAsk"), object: nil)
    center.post(name: Notification.Name("HexPoseAsk"), object: nil)
  }

  override func call(_ request: [String: Any]) throws -> [String: Any] {
    switch request["op"] as? String {
    case "call": return state
    case "captions": return captions
    case "pose": return pose
    case "build": return ["number": Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0]
    default: throw ExactNativeRefusal("hex answers call, captions, pose and build")
    }
  }

  /// A command for the shell, answered when the shell has done it (a pick answers once uploaded).
  override func later(_ request: [String: Any], reply: ExactReply) {
    guard state["shell"] as? Bool == true else {
      return reply.send(["ok": false, "error": "Calls run in the hex Exact app on the phone.", "media": [[String: Any]]()])
    }
    var command = request
    let answer: ([String: Any]) -> Void = { result in
      var result = result
      if result["media"] == nil { result["media"] = [[String: Any]]() }
      reply.send(result)
    }
    command["reply"] = answer
    NotificationCenter.default.post(name: Notification.Name("HexCallCommand"), object: nil, userInfo: command)
  }

  override func destroy() {
    observers.forEach(NotificationCenter.default.removeObserver)
  }
}

let exactModule: ExactModule.Type = Hex.self

private let personas = ["obsidian", "mana", "opal", "halo", "glint", "command"]
/// The persona colours that have their own shade on a light screen, as the stable app keeps them.
private let onLight: [String: String] = [
  "#FFFFFF": "#1C1C1E", "#FFB3C7": "#D9487A", "#FFCDA8": "#E07A3C", "#FFEDA6": "#C29A1A",
  "#D5F2B6": "#5E9E2E", "#C4F3E5": "#2FA585", "#A9CCFF": "#2F6FD8", "#CDB8FF": "#7B5BD6",
]
/// Opal and Mana keep their own colours; the rest take the one Bassim chose.
private let tinted: Set<String> = ["obsidian", "halo", "glint", "command"]

// MARK: The orb

/// `hex-orb`: hex, as the persona Bassim picked (Obsidian, Mana, Opal, Halo, Glint, Command; the
/// stable app's Rive files). It listens while you talk, thinks while the call connects or ends,
/// speaks with hex's voice, and rests when muted or idle. Around it, the stable app's motion: it
/// breathes while idle, wakes with a spring as the call goes live, swells with your voice and rises
/// and squashes with its pitch and tone, by the "Reacts to you" amount. Levels and tone come from the
/// shell many times a second, so they never cross into the Contract. A new `speak` plays a short
/// phrase's worth of it, so Settings shows what each amount looks like.
final class OrbInstance: ExactNativeInstance {
  private let orb = OrbView()
  private var observers: [NSObjectProtocol] = []
  private var spoken: String?

  init(_ props: [String: String], _ events: ExactNativeEvents) {
    super.init(events: events)
    try? setProps(props)
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: Notification.Name("HexCallLevels"), object: nil, queue: .main) { [weak self] note in
      let input = (note.userInfo?["input"] as? NSNumber)?.floatValue ?? 0
      let output = (note.userInfo?["output"] as? NSNumber)?.floatValue ?? 0
      self?.orb.levels(input: CGFloat(input), output: CGFloat(output))
    })
    observers.append(center.addObserver(forName: Notification.Name("HexCallTone"), object: nil, queue: .main) { [weak self] note in
      let pitch = (note.userInfo?["pitch"] as? NSNumber)?.floatValue ?? 0
      let tone = (note.userInfo?["tone"] as? NSNumber)?.floatValue ?? 0
      self?.orb.voiced(pitch: CGFloat(pitch), tone: CGFloat(tone))
    })
    events.intrinsicSize(CGSize(width: 240, height: 240))
  }

  override var view: ExactNativeView { orb }

  override func setProps(_ props: [String: String]) throws {
    let reaction: CGFloat = (["off": 0, "lively": 0.16] as [String: CGFloat])[props["reaction"] ?? ""] ?? 0.07
    orb.configure(
      status: props["state"] ?? "idle", silenced: props["silenced"] == "true",
      persona: personas.contains(props["persona"] ?? "") ? props["persona"]! : "opal",
      tint: (props["tint"] ?? "").isEmpty ? "#FFFFFF" : props["tint"]!.uppercased(),
      palette: Int(props["palette"] ?? ""), reaction: reaction, still: props["still"] == "true")
    let speak = props["speak"] ?? ""
    if let spoken, speak != spoken { orb.speak() }
    spoken = speak
  }

  override func destroy() {
    observers.forEach(NotificationCenter.default.removeObserver)
  }
}

final class OrbView: UIView {
  /// wake → breath → heard (loudness) → voice (pitch and tone) → the persona, so each motion moves
  /// on its own layer.
  private let wake = UIView()
  private let breath = UIView()
  private let heard = UIView()
  private let voice = UIView()
  private var face: UIView?
  #if canImport(RiveRuntime)
    private var rive: RiveViewModel?
    private var colors: RiveDataBindingViewModel.Instance?
  #endif
  private var drawn: DrawnOrb?

  private var status = ""
  private var silenced = false
  private var persona = ""
  private var tint = ""
  private var palette: Int?
  private var reaction: CGFloat = 0.07
  private var still = false
  private var speaking = false
  private var level: CGFloat = 0
  private var tone = (pitch: CGFloat(0), tone: CGFloat(0))
  private var phrase = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    for (outer, inner) in [(self, wake), (wake, breath), (breath, heard), (heard, voice)] { outer.addSubview(inner) }
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layoutSubviews() {
    super.layoutSubviews()
    for view in [wake, breath, heard, voice] {
      view.bounds = CGRect(origin: .zero, size: bounds.size)
      view.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
    face?.frame = voice.bounds
  }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle { paint() }
  }

  func configure(status: String, silenced: Bool, persona: String, tint: String, palette: Int?, reaction: CGFloat, still: Bool) {
    let woke = status != self.status
    let swapped = persona != self.persona
    self.status = status
    self.silenced = silenced
    self.tint = tint
    self.palette = palette
    self.reaction = reaction
    self.still = still || UIAccessibility.isReduceMotionEnabled
    if swapped {
      self.persona = persona
      load()
    }
    paint()
    act()
    if woke || swapped { move() }
    if !reacting, phrase == 0 { react(level: 0, pitch: 0, tone: 0) }
  }

  private var reacting: Bool { status == "live" && !silenced && !still && reaction > 0 }

  /// The Rive persona, or (without Rive, as in a plain Exact build) hex's drawn sphere.
  private func load() {
    let old = face
    face = nil
    #if canImport(RiveRuntime)
      if Bundle.main.url(forResource: persona, withExtension: "riv") != nil {
        let model = RiveViewModel(fileName: persona, in: .main, stateMachineName: "default", fit: .contain, autoPlay: true)
        rive = model
        if let file = model.riveModel?.riveFile, let artboard = model.riveModel?.artboard, tinted.contains(persona),
          let instance = file.defaultViewModel(for: artboard)?.createDefaultInstance()
        {
          model.riveModel?.stateMachine?.bind(viewModelInstance: instance)
          colors = instance
        } else {
          colors = nil
        }
        let view = model.createRiveView()
        view.backgroundColor = .clear
        face = view
      } else {
        rive = nil
        colors = nil
        face = nil
      }
    #endif
    if face == nil {
      let sphere = DrawnOrb()
      drawn = sphere
      face = sphere
    } else {
      drawn = nil
    }
    if let face {
      face.frame = voice.bounds
      face.alpha = 0
      voice.addSubview(face)
      UIView.animate(withDuration: old == nil ? 0 : 0.15) {
        face.alpha = 1
        old?.alpha = 0
      } completion: { _ in old?.removeFromSuperview() }
    }
  }

  /// The chosen colour (its light shade on a light screen). Rive writes the file's own colour back on
  /// the first frame after binding, so it's set again once that has drawn.
  private func paint() {
    let light = traitCollection.userInterfaceStyle == .light
    let color = UIColor(hex: light ? onLight[tint] ?? tint : tint) ?? .white
    drawn?.tint(tinted.contains(persona) ? color : nil)
    #if canImport(RiveRuntime)
      guard let colors else { return }
      let set = { [weak self] in
        guard self?.colors === colors else { return }
        colors.colorProperty(fromPath: "color")?.value = color
      }
      set()
      for delay in [0.05, 0.3] { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: set) }
    #endif
  }

  /// The persona's state: thinking while the call connects or ends, speaking with hex's voice,
  /// resting when muted, listening otherwise.
  private func act() {
    let live = status == "live"
    let busy = status == "connecting" || status == "reconnecting" || status == "ending"
    let mood = busy ? "thinking" : !live || silenced ? "idle" : speaking ? "speaking" : "listening"
    drawn?.configure(mood: mood, still: still)
    #if canImport(RiveRuntime)
      guard let rive else { return }
      for input in ["listening", "thinking", "speaking", "asleep"] { rive.setInput(input, value: input == mood) }
      if persona == "opal", let palette { rive.setInput("color", value: Double(palette)) }
      if still {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in if self?.still == true { self?.rive?.pause() } }
      } else {
        rive.play()
      }
    #endif
  }

  /// How awake it is: resting small and dim, half woken while connecting, full size when live.
  private func move() {
    let awake: CGFloat = status == "live" ? 1 : status == "idle" ? 0 : 0.5
    let scale = 0.86 + 0.14 * awake
    let alpha = min(1, 0.5 + 0.5 * awake)
    breath.layer.removeAnimation(forKey: "breath")
    if still {
      wake.transform = CGAffineTransform(scaleX: scale, y: scale)
      wake.alpha = alpha
      return
    }
    if awake == 1 {
      UIView.animate(withDuration: 0.64, delay: 0, usingSpringWithDamping: 0.45, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
        self.wake.transform = CGAffineTransform(scaleX: scale, y: scale)
        self.wake.alpha = alpha
      }
    } else {
      UIView.animate(withDuration: awake == 0 ? 0.82 : 0.41, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
        self.wake.transform = CGAffineTransform(scaleX: scale, y: scale)
        self.wake.alpha = alpha
      }
    }
    if awake == 0 {
      let breathe = CABasicAnimation(keyPath: "transform.scale")
      breathe.fromValue = 1
      breathe.toValue = 1.025
      breathe.duration = 2.6
      breathe.autoreverses = true
      breathe.repeatCount = .infinity
      breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      breath.layer.add(breathe, forKey: "breath")
    }
  }

  /// hex speaking past 0.035 turns the persona to speaking; Bassim's own voice swells it.
  func levels(input: CGFloat, output: CGFloat) {
    let now = output > 0.035
    if now != speaking {
      speaking = now
      act()
    }
    drawn?.levels(input: input, output: output)
    guard phrase == 0 else { return }
    react(level: reacting ? max(0, input - 0.06) / 0.94 : 0, pitch: tone.pitch, tone: tone.tone)
  }

  /// His voice's pitch lifts the orb and its tone stretches it tall (bright) or wide (dark).
  func voiced(pitch: CGFloat, tone: CGFloat) {
    guard phrase == 0 else { return }
    react(level: level, pitch: reacting ? pitch : 0, tone: reacting ? tone : 0)
  }

  /// A short spoken phrase's loudness, pitch and tone, as the stable app's Settings plays it when
  /// "Reacts to you" changes.
  func speak() {
    guard !still, reaction > 0 else { return }
    phrase += 1
    let take = phrase
    let steps: [(CGFloat, CGFloat, CGFloat)] = [(0.9, -0.2, 0.2), (0.35, -0.35, -0.1), (0.75, 0.1, 0.3), (0.25, 0.35, 0), (0.6, 0.9, 0.5), (0, 0, 0)]
    for (i, step) in steps.enumerated() {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 * Double(i)) { [weak self] in
        guard let self, self.phrase == take else { return }
        self.react(level: step.0, pitch: step.1, tone: step.2, force: true)
        if i == steps.count - 1 { self.phrase = 0 }
      }
    }
  }

  /// The stable app's `heard`: scale with loudness, a lift of 0.4 of its size with pitch, and up to
  /// 30% taller and narrower with tone, each times the reaction amount.
  private func react(level: CGFloat, pitch: CGFloat, tone: CGFloat, force: Bool = false) {
    let amount = reaction
    if force || abs(level - self.level) > 0.005 {
      self.level = level
      let scale = 1 + amount * level
      UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
        self.heard.transform = CGAffineTransform(scaleX: scale, y: scale)
      }
    }
    guard force || abs(pitch - self.tone.pitch) > 0.004 || abs(tone - self.tone.tone) > 0.004 else { return }
    self.tone = (pitch, tone)
    let lift = -0.4 * amount * bounds.height * pitch
    UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
      self.voice.transform = CGAffineTransform(translationX: 0, y: lift).scaledBy(x: 1 - 0.3 * amount * tone, y: 1 + 0.3 * amount * tone)
    }
  }
}

/// hex's own sphere, drawn, where Rive isn't linked: slowly turning colour, faster while busy.
final class DrawnOrb: UIView {
  private let ball = CALayer()
  private let swirl = CAGradientLayer()
  private let counter = CAGradientLayer()
  private let shade = CAGradientLayer()
  private let shine = CAGradientLayer()
  private var mood = ""
  private var still = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
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
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ball.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    ball.cornerRadius = side / 2
    for conic in [swirl, counter] {
      conic.bounds = CGRect(x: 0, y: 0, width: side * 1.5, height: side * 1.5)
      conic.position = CGPoint(x: side / 2, y: side / 2)
    }
    shade.frame = ball.bounds
    shine.frame = ball.bounds
    CATransaction.commit()
    spin()
  }

  func tint(_ color: UIColor?) {
    let colors: [UIColor] = color.map { c in [c, c.withAlphaComponent(0.55), c.mix(.systemIndigo), c, c.mix(.white), c] }
      ?? [.systemPink, .systemPurple, .systemIndigo, .systemTeal, .systemGreen, .systemYellow, .systemOrange, .systemRed, .systemPink]
    swirl.colors = colors.map(\.cgColor)
    counter.colors = colors.reversed().map { $0.withAlphaComponent(0.8).cgColor }
  }

  func configure(mood: String, still: Bool) {
    guard mood != self.mood || still != self.still else { return }
    self.mood = mood
    self.still = still
    spin()
  }

  private func spin() {
    for conic in [swirl, counter] { conic.removeAllAnimations() }
    guard !still else { return }
    let turn = mood == "thinking" ? 4.0 : mood == "idle" ? 18.0 : 9.0
    for (conic, direction) in [(swirl, 1.0), (counter, -1.3)] {
      let spin = CABasicAnimation(keyPath: "transform.rotation.z")
      spin.byValue = direction * .pi * 2
      spin.duration = turn * abs(direction)
      spin.repeatCount = .infinity
      conic.add(spin, forKey: "spin")
    }
  }

  func levels(input: CGFloat, output: CGFloat) {
    guard mood == "speaking" || mood == "listening", !still else { return }
    let level = output > 0.035 ? min(1, output) : min(1, input)
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.12)
    let scale = 1 + level * 0.08
    ball.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
    CATransaction.commit()
  }
}

// MARK: Media

/// `hex-color`: the persona's own colour, picked with iOS's colour well (Exact has no colour input).
/// It shows the colour chosen; a pick says it as `#RRGGBB`. `custom` rings it when that colour is
/// none of the presets.
final class ColorInstance: ExactNativeInstance {
  private let well = UIColorWell()

  init(_ props: [String: String], _ events: ExactNativeEvents) {
    super.init(events: events)
    well.supportsAlpha = false
    well.title = "Persona color"
    well.addAction(UIAction { [weak self] _ in self?.picked() }, for: .valueChanged)
    try? setProps(props)
  }

  override var view: ExactNativeView { well }

  override func setProps(_ props: [String: String]) throws {
    let custom = props["custom"] == "true"
    well.accessibilityLabel = custom ? "Custom color, selected" : "Custom color"
    if let color = UIColor(hex: props["hue"] ?? ""), custom { well.selectedColor = color }
  }

  private func picked() {
    guard let color = well.selectedColor else { return }
    var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
    color.resolvedColor(with: well.traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
    let byte = { (v: CGFloat) in Int((min(max(v, 0), 1) * 255).rounded()) }
    events.change(String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b)))
  }
}

/// `hex-media`: a photo or video hex holds (`media` is its id from `POST /media`), or one still on
/// this phone while it sends (a `file:` id). It fills its box, cropped about its centre, or showing
/// its top with `anchor=top` (a screenshot taller than its box); a video wears a play badge.
/// Tap it to look at it full screen, with Quick Look's swipe and pinch.
final class MediaInstance: ExactNativeInstance {
  private let thumb = MediaThumb()

  init(_ props: [String: String], _ events: ExactNativeEvents) {
    super.init(events: events)
    try? setProps(props)
  }

  override var view: ExactNativeView { thumb }

  override func setProps(_ props: [String: String]) throws {
    thumb.top = props["anchor"] == "top"
    thumb.show(id: props["media"] ?? "", video: props["kind"] == "video")
  }

  override func prepareForReuse() throws { thumb.show(id: "", video: false) }
}

final class MediaThumb: UIView, QLPreviewControllerDataSource {
  private static let cache = NSCache<NSString, UIImage>()
  private let image = UIImageView()
  private let badge = UIImageView(image: UIImage(systemName: "play.circle.fill"))
  private var id = ""
  private var file: URL?
  var top = false { didSet { if top != oldValue { setNeedsLayout() } } }

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    backgroundColor = .tertiarySystemFill
    image.contentMode = .scaleAspectFill
    image.clipsToBounds = true
    addSubview(image)
    badge.tintColor = .white
    badge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 26, weight: .regular)
    badge.layer.shadowOpacity = 0.35
    badge.layer.shadowRadius = 4
    badge.layer.shadowOffset = .zero
    addSubview(badge)
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(look)))
    isAccessibilityElement = true
    accessibilityTraits = [.image, .button]
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layoutSubviews() {
    super.layoutSubviews()
    image.frame = bounds
    if top, let size = image.image?.size, size.width > 0, size.height / size.width > bounds.height / max(bounds.width, 1) {
      image.frame.size.height = bounds.width * size.height / size.width
    }
    badge.sizeToFit()
    badge.center = CGPoint(x: bounds.midX, y: bounds.midY)
  }

  func show(id: String, video: Bool) {
    badge.isHidden = !video
    accessibilityLabel = video ? "Video" : "Photo"
    guard id != self.id else { return }
    self.id = id
    image.image = nil
    file = nil
    guard !id.isEmpty else { return }
    if let cached = Self.cache.object(forKey: id as NSString) {
      image.image = cached
      setNeedsLayout()
      return
    }
    Task.detached(priority: .userInitiated) { [weak self] in
      let loaded = await Self.load(id)
      await MainActor.run {
        guard let self, self.id == id, let loaded else { return }
        Self.cache.setObject(loaded.image, forKey: id as NSString)
        self.file = loaded.file
        UIView.transition(with: self.image, duration: 0.2, options: .transitionCrossDissolve) { self.image.image = loaded.image }
        self.setNeedsLayout()
      }
    }
  }

  /// A local file (a still from a clip), or `GET /media/:id` with hex's token: a photo, or a still
  /// from a video.
  private static func load(_ id: String) async -> (image: UIImage, file: URL)? {
    if id.hasPrefix("file:"), let url = URL(string: id) {
      if let image = UIImage(contentsOfFile: url.path) { return (image, url) }
      let frames = AVAssetImageGenerator(asset: AVURLAsset(url: url))
      frames.appliesPreferredTrackTransform = true
      guard let still = try? await frames.image(at: .zero).image else { return nil }
      return (UIImage(cgImage: still), url)
    }
    let origin = Bundle.main.object(forInfoDictionaryKey: "HexURL") as? String ?? ""
    let token = Bundle.main.object(forInfoDictionaryKey: "HexToken") as? String ?? ""
    // An id that is a path (an ask's screenshot, `/asks/<id>/shots/<n>`) is read from there.
    let path = id.hasPrefix("/") ? id : "/media/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)"
    guard !origin.isEmpty, let url = URL(string: "\(origin)\(path)") else { return nil }
    var request = URLRequest(url: url, timeoutInterval: 90)
    if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    guard let (data, response) = try? await URLSession.shared.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data)
    else { return nil }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("hex-media-\(id.replacingOccurrences(of: "/", with: "_").prefix(64)).jpg")
    try? data.write(to: file)
    return (image, file)
  }

  @objc private func look() {
    guard file != nil, var top = window?.rootViewController else { return }
    while let next = top.presentedViewController { top = next }
    let preview = QLPreviewController()
    preview.dataSource = self
    top.present(preview, animated: true)
  }

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int { file == nil ? 0 : 1 }
  func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { (file ?? URL(fileURLWithPath: "/")) as NSURL }
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
