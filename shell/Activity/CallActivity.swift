import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct Activities: WidgetBundle {
  var body: some Widget {
    CallActivity()
    AskActivity()
  }
}

/// The call on the Lock Screen and in the Dynamic Island, as the stable app draws it: Bassim's orb,
/// "hex", how long it's run (or how it ended), and Mute and End in circles.
struct CallActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: CallAttributes.self) { context in
      HStack(spacing: 14) {
        Orb(name: context.state.orb, size: 48)
        Title(state: context.state)
        Spacer(minLength: 0)
        Controls(state: context.state, size: 44)
      }
      .padding(16)
      .activityBackgroundTint(Color("Background"))
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          HStack(spacing: 12) {
            Orb(name: context.state.orb, size: 44)
            Title(state: context.state)
          }
          .padding(.leading, 6)
          .padding(.top, 6)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Controls(state: context.state, size: 44)
            .padding(.trailing, 6)
            .padding(.top, 6)
        }
      } compactLeading: {
        Orb(name: context.state.orb, size: 24)
      } compactTrailing: {
        if context.state.state == "muted" {
          Image(systemName: "mic.slash.fill").font(.system(size: 14))
        } else if context.state.outcome.isEmpty, let since = context.state.since {
          Text(timerInterval: since...since.addingTimeInterval(86_400), countsDown: false)
            .font(.system(size: 15).monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: 44)
        }
      } minimal: {
        Orb(name: context.state.orb, size: 24)
      }
    }
  }
}

private struct Orb: View {
  let name: String
  let size: CGFloat
  var body: some View {
    Image(name).resizable().scaledToFit().frame(width: size, height: size)
  }
}

private struct Title: View {
  let state: CallAttributes.ContentState
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("hex").font(.system(size: 17, weight: .semibold))
      Group {
        if !state.outcome.isEmpty {
          Text(state.outcome).foregroundStyle(state.bad ? AnyShapeStyle(Color("Bad")) : AnyShapeStyle(.secondary))
        } else if let since = state.since {
          Text(timerInterval: since...since.addingTimeInterval(86_400), countsDown: false)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        } else {
          Text("Connecting").foregroundStyle(.secondary)
        }
      }
      .font(.system(size: 15))
      .lineLimit(1)
    }
  }
}

private struct Controls: View {
  let state: CallAttributes.ContentState
  let size: CGFloat
  var body: some View {
    HStack(spacing: 10) {
      if state.state == "live" || state.state == "muted" {
        Button(intent: MuteCall()) {
          Image(systemName: state.state == "muted" ? "mic.slash.fill" : "mic.fill")
            .font(.system(size: size * 0.38, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background(Color(state.state == "muted" ? "MuteOn" : "MuteOff"), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.state == "muted" ? "Unmute microphone" : "Mute microphone")
      }
      if state.state != "ended" {
        Button(intent: EndCall()) {
          Image(systemName: "xmark")
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(Color("Background"))
            .frame(width: size, height: size)
            .background(Color.primary, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("End conversation")
      }
    }
  }
}
