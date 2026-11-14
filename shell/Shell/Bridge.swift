import Foundation

/// The shell's half of the bridge to the Exact screen. The other half is the app's native module,
/// `app/modules/apple/Hex.swift`, which Exact loads from its own framework; the two meet on
/// NotificationCenter, so neither links the other.
///
///   Hex module ──HexCallCommand {op, …, reply}──▶ Bridge ──▶ Call, MediaPicker
///   Hex module ──HexCallAsk──▶ Bridge ──HexCallState + HexCaptions──▶ Hex module (when it loads)
///   Call ──HexCallState / HexCaptions / HexCallLevels / HexCallTone──▶ Hex module ──▶ app.ts, the orb
///
/// Commands: `start` {voice, about}, `mute`, `end`, `share` {source} (a photo or video into
/// the live call), `attach` {source, most} (for a composer: answers the uploaded media), `retry`
/// {key} (a share that failed). Each may carry Bassim's phone settings, which are kept (Prefs).
@MainActor
enum Bridge {
  static let state = Notification.Name("HexCallState")
  static let captions = Notification.Name("HexCaptions")
  static let levels = Notification.Name("HexCallLevels")
  static let tone = Notification.Name("HexCallTone")
  static let command = Notification.Name("HexCallCommand")
  static let ask = Notification.Name("HexCallAsk")

  typealias Reply = ([String: Any]) -> Void

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
    let reply = request["reply"] as? Reply ?? { _ in }
    Prefs.save(request)
    let call = Call.shared
    switch request["op"] as? String {
    case "start":
      call.start(voice: request["voice"] as? String, about: request["about"] as? String ?? "")
      reply(["ok": true, "error": ""])
    case "mute":
      call.toggleMute()
      reply(["ok": true, "error": ""])
    case "end":
      call.end()
      reply(["ok": true, "error": ""])
    case "retry":
      call.retryShare(request["key"] as? String ?? "")
      reply(["ok": true, "error": ""])
    case "share":
      Task {
        let picked = await MediaPicker.pick(request["source"] as? String ?? "photos", sends: true)
        call.share(picked)
        reply(["ok": true, "error": ""])
      }
    case "attach":
      Task {
        let most = (request["most"] as? NSNumber)?.intValue ?? MediaPicker.most
        let picked = await MediaPicker.pick(request["source"] as? String ?? "photos", most: max(1, most), sends: false)
        do {
          var media: [[String: Any]] = []
          for item in picked { media.append(try await HexServer().upload(item).json) }
          reply(["ok": true, "error": "", "media": media])
        } catch {
          reply(["ok": false, "error": "Not added · " + ((error as? LocalizedError)?.errorDescription ?? "hex didn't take it"), "media": [[String: Any]]()])
        }
      }
    default:
      reply(["ok": false, "error": "The shell doesn't know that command."])
    }
  }

  static func stateChanged() {
    let call = Call.shared
    CallLiveActivity.follow(call)
    NotificationCenter.default.post(name: state, object: nil, userInfo: [
      "status": call.status.rawValue,
      "id": call.id ?? "",
      "muted": call.muted,
      "interrupted": call.interrupted,
      "started": (call.started?.timeIntervalSince1970 ?? 0) * 1000,
      "error": call.failure ?? "",
      "ending": call.ending,
      "seconds": call.seconds,
      "shell": true,
      "demo": call.demo,
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

  /// How far Bassim's voice lifts and brightens, -1…1, 30 times a second while he talks.
  static func toneChanged(pitch: Float, tone: Float) {
    NotificationCenter.default.post(name: Self.tone, object: nil, userInfo: ["pitch": pitch, "tone": tone])
  }
}
