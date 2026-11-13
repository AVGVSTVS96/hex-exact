import ActivityKit
import AppIntents
import Foundation

/// What the call's Live Activity shows. The app starts and updates it (Activity.swift); the
/// extension draws it (CallActivity.swift). `state`: connecting (reconnecting too), live, muted or
/// ended; `orb` names Bassim's persona's image; an ended call says how it ended in `outcome`.
struct CallAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var state: String
    var since: Date?
    var orb: String
    var outcome: String = ""
    var bad: Bool = false
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
