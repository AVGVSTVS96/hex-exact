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

/// The call on the Lock Screen and in the Dynamic Island: how long it's run, whether you're
/// muted, and End.
struct CallActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: CallAttributes.self) { context in
      HStack(spacing: 14) {
        Image("hex").resizable().frame(width: 48, height: 48)
        Words(state: context.state)
        Spacer(minLength: 0)
        End()
      }
      .padding(16)
      .activityBackgroundTint(Color(uiColor: .systemBackground))
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          HStack(spacing: 12) {
            Image("hex").resizable().frame(width: 44, height: 44)
            Words(state: context.state)
          }
        }
        DynamicIslandExpandedRegion(.trailing) { End() }
      } compactLeading: {
        Image("hex").resizable().frame(width: 24, height: 24)
      } compactTrailing: {
        Elapsed(state: context.state).frame(maxWidth: 52)
      } minimal: {
        Image(systemName: context.state.muted ? "mic.slash.fill" : "waveform")
      }
    }
  }
}

private struct Words: View {
  let state: CallAttributes.ContentState
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(state.line).font(.headline)
      HStack(spacing: 6) {
        if state.muted { Image(systemName: "mic.slash.fill") }
        Elapsed(state: state)
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
    }
  }
}

private struct Elapsed: View {
  let state: CallAttributes.ContentState
  var body: some View {
    if let since = state.since {
      Text(since, style: .timer).monospacedDigit()
    } else {
      Text("Connecting")
    }
  }
}

private struct End: View {
  var body: some View {
    Button(intent: EndCall()) {
      Image(systemName: "phone.down.fill")
        .font(.title3)
        .frame(width: 44, height: 44)
    }
    .buttonStyle(.borderedProminent)
    .buttonBorderShape(.circle)
    .tint(.red)
  }
}
