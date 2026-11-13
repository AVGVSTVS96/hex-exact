import Foundation

/// The shell's half of the bridge to the Exact screen. The other half is the app's native module,
/// `app/modules/apple/Hex.swift`, which Exact loads from its own framework; the two meet on
/// NotificationCenter, so neither links the other.
///
///   Hex module ──HexCallCommand {op: start|mute|end, voice, about}──▶ Bridge ──▶ Call
///   Hex module ──HexCallAsk──▶ Bridge ──HexCallState + HexCaptions──▶ Hex module (when it loads)
///   Call ──HexCallState / HexCaptions / HexCallLevels──▶ Hex module ──▶ app.ts, the orb
@MainActor
enum Bridge {
  static let state = Notification.Name("HexCallState")
  static let captions = Notification.Name("HexCaptions")
  static let levels = Notification.Name("HexCallLevels")
  static let command = Notification.Name("HexCallCommand")
  static let ask = Notification.Name("HexCallAsk")

  private static var pending = false

  static func connect() {
    let center = NotificationCenter.default
    center.addObserver(forName: Call.changed, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { stateChanged() }
    }
    center.addObserver(forName: ask, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated {
        stateChanged()
        postCaptions()
      }
    }
    center.addObserver(forName: command, object: nil, queue: .main) { note in
      let request = note.userInfo ?? [:]
      MainActor.assumeIsolated { run(request) }
    }
  }

  private static func run(_ request: [AnyHashable: Any]) {
    let call = Call.shared
    switch request["op"] as? String {
    case "start": call.start(voice: request["voice"] as? String ?? "marin", about: request["about"] as? String ?? "")
    case "mute": call.toggleMute()
    case "end": call.end()
    default: break
    }
  }

  static func stateChanged() {
    let call = Call.shared
    CallLiveActivity.follow(call)
    NotificationCenter.default.post(name: state, object: nil, userInfo: [
      "status": call.status.rawValue,
      "id": call.sessionId ?? "",
      "muted": call.muted,
      "hexMuted": call.hexMuted,
      "interrupted": false,
      "started": (call.started?.timeIntervalSince1970 ?? 0) * 1000,
      "error": call.failure ?? "",
      "ending": call.ending,
      "seconds": call.seconds,
      "shell": true,
    ])
  }

  /// Words arrive many times a second; the screen gets them at most every 80 ms.
  static func captionsChanged() {
    guard !pending else { return }
    pending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
      MainActor.assumeIsolated {
        pending = false
        postCaptions()
      }
    }
  }

  private static func postCaptions() {
    let captions = Call.shared.captions
    NotificationCenter.default.post(name: Self.captions, object: nil, userInfo: ["call": captions.call, "turns": captions.shown])
  }

  static func levelsChanged(_ levels: (input: Float, output: Float)) {
    NotificationCenter.default.post(name: Self.levels, object: nil, userInfo: ["input": levels.input, "output": levels.output])
  }
}
