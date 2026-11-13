import ActivityKit
import AppIntents
import Foundation

// What the Ask hex Live Activity shows, in the app, which starts it (AskHex.swift), and in the Live
// Activity extension, which draws it (AskActivity.swift).
struct AskAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var title: String
    var line: String
    var filled: Double
  }
}

// Stop on the Ask hex Live Activity. iOS runs it in the app, where the ask it names hears it.
struct StopAsk: LiveActivityIntent {
  static let title: LocalizedStringResource = "Stop asking hex"
  static let isDiscoverable = false
  static let stopped = Notification.Name("StopAsk")

  @Parameter(title: "Activity")
  var activity: String

  init() {}

  init(activity: String) {
    self.activity = activity
  }

  func perform() async throws -> some IntentResult {
    NotificationCenter.default.post(name: Self.stopped, object: activity)
    return .result()
  }
}
