import ActivityKit
import Foundation

/// Keeps the call's Live Activity in step with the call: started as it connects, updated as it goes
/// live, mutes, pauses or reconnects, and gone the moment the call ends.
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
    case .ending, .idle:
      guard let activity = current else { return }
      current = nil
      since = nil
      Task { await activity.end(nil, dismissalPolicy: .immediate) }
    case .connecting, .live, .reconnecting:
      if call.status == .live, since == nil { since = call.started ?? Date() }
      let shown = call.status == .live ? (call.interrupted ? "paused" : "live") : call.status.rawValue
      let state = CallAttributes.ContentState(state: shown, muted: call.muted, since: since, orb: Prefs.orb)
      if let activity = current {
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
      } else if ActivityAuthorizationInfo().areActivitiesEnabled {
        current = try? Activity.request(attributes: CallAttributes(), content: ActivityContent(state: state, staleDate: nil))
      }
    }
  }
}
