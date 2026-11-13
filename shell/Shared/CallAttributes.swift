import ActivityKit
import AppIntents
import Foundation

/// What the call's Live Activity shows. The app starts and updates it (Activity.swift); the
/// extension draws it (CallActivity.swift).
struct CallAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var line: String
    var muted: Bool
    var since: Date?
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
