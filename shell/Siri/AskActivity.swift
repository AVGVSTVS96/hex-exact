import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// The Ask hex Live Activity, laid out like the call's: the icon and both lines as one block, centred
// on each other, and Stop at the far edge.
struct AskActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: AskAttributes.self) { context in
      HStack(spacing: 14) {
        AskIcon(size: 48)
        AskWords(state: context.state)
        Spacer(minLength: 0)
        AskStop(activity: context.activityID, filled: context.state.filled)
      }
      .padding(16)
      .activityBackgroundTint(Color(uiColor: .systemBackground))
    } dynamicIsland: { context in
      DynamicIsland {
        // WHY: iOS offers the leading region about 110pt however wide the island is; 280pt is what's
        // left of Stop on the Duo's island, open or folded, less the gap the icon has to the text.
        DynamicIslandExpandedRegion(.leading, priority: 1) {
          HStack(spacing: 12) {
            AskIcon(size: 44)
            AskWords(state: context.state)
          }
          .frame(width: 280, alignment: .leading)
        }
        DynamicIslandExpandedRegion(.trailing) {
          AskStop(activity: context.activityID, filled: context.state.filled)
        }
      } compactLeading: {
        AskIcon(size: 24)
      } compactTrailing: {
        AskRing(filled: context.state.filled).frame(width: 20, height: 20)
      } minimal: {
        AskRing(filled: context.state.filled).frame(width: 20, height: 20)
      }
    }
  }
}

private struct AskIcon: View {
  let size: CGFloat

  var body: some View {
    Image("hex")
      .resizable()
      .frame(width: size, height: size)
      .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
  }
}

private struct AskWords: View {
  // The call Live Activity's second line (src/live/call-activity.tsx).
  static let secondary = Color(
    uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.63, alpha: 1) : UIColor(white: 0.43, alpha: 1) })

  let state: AskAttributes.ContentState

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(state.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
      Text(state.line).font(.system(size: 15)).foregroundStyle(Self.secondary)
    }
    .lineLimit(1)
  }
}

private struct AskRing: View {
  let filled: Double

  var body: some View {
    ZStack {
      Circle().stroke(.primary.opacity(0.2), lineWidth: 3)
      Circle()
        .trim(from: 0, to: filled)
        .stroke(.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }
    .padding(1.5)
  }
}

private struct AskStop: View {
  let activity: String
  let filled: Double

  var body: some View {
    if #available(iOS 17, *) {
      Button(intent: StopAsk(activity: activity)) { face }.buttonStyle(.plain)
    } else {
      face
    }
  }

  private var face: some View {
    ZStack {
      AskRing(filled: filled)
      RoundedRectangle(cornerRadius: 3, style: .continuous).fill(.primary).frame(width: 14, height: 14)
    }
    .frame(width: 44, height: 44)
  }
}
