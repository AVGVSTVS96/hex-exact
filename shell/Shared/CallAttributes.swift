import ActivityKit
import AppIntents
import Foundation

/// What the call's Live Activity shows. The app starts and updates it (Activity.swift); the
/// extension draws it (CallActivity.swift). `state`: connecting, live, paused (a phone call or Siri
/// has the audio) or reconnecting; `since` is when it went live; `orb` names Bassim's persona's image.
struct CallAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var state: String
    var muted: Bool
    var since: Date?
    var orb: String
  }
}

/// End on the Live Activity. iOS runs it in the app, where the call is.
struct EndCall: LiveActivityIntent {
  static let title: LocalizedStringResource = "End the call with hex"
  static let isDiscoverable = false
  static let ended = Notification.Name("EndCall")

  func perform() async throws -> some IntentResult {
    NotificationCenter.default.post(name: Self.ended, object: nil)
    return .result()
  }
}

/// Mute or unmute on the Live Activity, in the app as End is.
struct MuteCall: LiveActivityIntent {
  static let title: LocalizedStringResource = "Mute or unmute the call with hex"
  static let isDiscoverable = false
  static let toggled = Notification.Name("MuteCall")

  func perform() async throws -> some IntentResult {
    NotificationCenter.default.post(name: Self.toggled, object: nil)
    return .result()
  }
}
