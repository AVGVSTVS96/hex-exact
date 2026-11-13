import ActivityKit
import Foundation

/// Keeps the call's Live Activity in step with the call: started when it connects, updated on
/// mute, ended when it hangs up.
@MainActor
enum CallLiveActivity {
  private static var current: Activity<CallAttributes>?

  static func follow(_ call: Call) {
    switch call.status {
    case .idle, .ending:
      guard let activity = current else { return }
      current = nil
      Task { await activity.end(nil, dismissalPolicy: .immediate) }
    case .connecting, .connected:
      let state = CallAttributes.ContentState(line: "hex", muted: call.muted, since: call.started)
      if let activity = current {
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
      } else if ActivityAuthorizationInfo().areActivitiesEnabled {
        current = try? Activity.request(attributes: CallAttributes(), content: ActivityContent(state: state, staleDate: nil))
      }
    }
  }
}
