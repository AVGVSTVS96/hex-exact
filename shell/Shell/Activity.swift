import ActivityKit
import Foundation

/// Keeps the call's Live Activity in step with the call: started as it connects, updated on mute,
/// and on hang-up left for two minutes saying how it ended ("You hung up · 3:12").
@MainActor
enum CallLiveActivity {
  private static var current: Activity<CallAttributes>?
  private static var since: Date?

  /// What a previous launch left behind ends at once.
  static func clearLeftovers() {
    for activity in Activity<CallAttributes>.activities {
      Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
  }

  static func follow(_ call: Call) {
    switch call.status {
    case .ending:
      return
    case .idle:
      guard let activity = current else { return }
      current = nil
      let ended = CallAttributes.ContentState(state: "ended", since: since, orb: Prefs.orb, outcome: outcome(call), bad: ["dropped", "no-connect"].contains(call.ending))
      since = nil
      Task { await activity.end(ActivityContent(state: ended, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(120))) }
    case .connecting, .live, .reconnecting:
      if call.status == .live, since == nil { since = call.started ?? Date() }
      let state = CallAttributes.ContentState(
        state: call.status == .live ? (call.muted || call.interrupted ? "muted" : "live") : "connecting",
        since: since, orb: Prefs.orb)
      if let activity = current {
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
      } else if ActivityAuthorizationInfo().areActivitiesEnabled {
        current = try? Activity.request(attributes: CallAttributes(), content: ActivityContent(state: state, staleDate: nil))
      }
    }
  }

  /// The stable app's ending lines, with how long it ran ("You hung up · 3:12").
  private static func outcome(_ call: Call) -> String {
    let line = [
      "you": "You hung up", "hex": "hex hung up", "dropped": "Call dropped", "expired": "Time ran out",
      "no-connect": "Couldn’t connect",
    ][call.ending] ?? "Call ended"
    guard since != nil, call.ending != "no-connect" else { return line }
    let s = call.seconds
    let rest = String(format: "%02d", s % 60)
    return "\(line) · " + (s < 3600 ? "\(s / 60):\(rest)" : "\(s / 3600):\(String(format: "%02d", s / 60 % 60)):\(rest)")
  }
}
