import AVFoundation
import UIKit

/// The call's sounds and haptics, as the stable app plays them: a chime and a success tap when the
/// call goes live, a lower chime and a soft tap when it ends. Each follows Bassim's Sounds and
/// Haptics settings, which the screen sends with each command (Prefs).
@MainActor
enum Feedback {
  private static var players: [String: AVAudioPlayer] = [:]

  static func went(live: Bool) {
    if Prefs.haptics {
      if live {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
      } else {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
      }
    }
    if Prefs.sounds { play(live ? "connect" : "end") }
  }

  private static var preview: AVAudioPlayer?
  private static let previewEnded = PreviewEnded()

  /// A voice's sample on the Voice page, as the stable app plays it: heard with the silent switch
  /// on, other audio ducked while it plays and let go after. Only between calls (the page locks the
  /// voice during one), so the call's audio session is never touched.
  static func preview(_ voice: String) {
    guard Call.shared.status == .idle,
      let url = Bundle.main.url(forResource: "voice-\(voice)", withExtension: "m4a"),
      let player = try? AVAudioPlayer(contentsOf: url)
    else { return }
    preview?.stop()
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, options: [.duckOthers])
    try? session.setActive(true)
    player.delegate = previewEnded
    preview = player
    player.play()
  }

  fileprivate static func letGo(_ player: AVAudioPlayer) {
    guard player === preview, Call.shared.status == .idle else { return }
    preview = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private static func play(_ name: String) {
    let player = players[name] ?? Bundle.main.url(forResource: name, withExtension: "wav").flatMap { try? AVAudioPlayer(contentsOf: $0) }
    players[name] = player
    player?.currentTime = 0
    player?.play()
  }
}

private final class PreviewEnded: NSObject, AVAudioPlayerDelegate {
  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
    MainActor.assumeIsolated { Feedback.letGo(player) }
  }
}

/// What Bassim chose on this phone, as the screen last sent it.
enum Prefs {
  static var sounds: Bool { UserDefaults.standard.object(forKey: "hex.sounds") as? Bool ?? true }
  static var haptics: Bool { UserDefaults.standard.object(forKey: "hex.haptics") as? Bool ?? true }
  static var persona: String { UserDefaults.standard.string(forKey: "hex.persona") ?? "opal" }
  static var color: String { UserDefaults.standard.string(forKey: "hex.personaColor") ?? "" }
  static var palette: String { UserDefaults.standard.string(forKey: "hex.palette") ?? "original" }

  static func save(_ request: [AnyHashable: Any]) {
    let defaults = UserDefaults.standard
    if let on = request["sounds"] as? Bool { defaults.set(on, forKey: "hex.sounds") }
    if let on = request["haptics"] as? Bool { defaults.set(on, forKey: "hex.haptics") }
    for key in ["persona", "personaColor", "palette"] {
      if let value = request[key] as? String { defaults.set(value, forKey: "hex.\(key)") }
    }
  }

  /// The Live Activity's orb: one image per persona and colour (or Opal's palette), as the stable
  /// app ships them (Activity/Orbs.xcassets).
  static var orb: String {
    let persona = ["obsidian", "mana", "opal", "halo", "glint", "command"].contains(persona) ? persona : "opal"
    switch persona {
    case "mana": return "orb-mana"
    case "opal": return palette == "original" || palette.isEmpty ? "orb-opal" : "orb-opal-\(palette)"
    default:
      let colors = ["ffffff", "ffb3c7", "ffcda8", "ffeda6", "d5f2b6", "c4f3e5", "a9ccff", "cdb8ff"]
      let color = color.lowercased().replacingOccurrences(of: "#", with: "")
      return "orb-\(persona)-\(colors.contains(color) ? color : "ffffff")"
    }
  }
}
