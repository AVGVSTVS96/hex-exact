import ActivityKit
import AppIntents
import Foundation
import os

// Siri hands hex the words the way the app's chat does, into hex's Siri topic, then waits for
// hex's reply, however long its work takes, and speaks it.
struct AskHex: AppIntent, ProgressReportingIntent, LiveActivityIntent {
  static let title: LocalizedStringResource = "Ask hex"
  static let description = IntentDescription(
    "Sends a question or request to hex, Bassim's own assistant that runs his projects, servers and tasks, and returns hex's reply.",
    searchKeywords: ["hex", "assistant", "tasks", "running", "tell hex"])

  @Parameter(
    title: "Request",
    description: "What to ask or tell hex, word for word as the person said it.",
    requestValueDialog: "What should I ask hex?")
  var request: String

  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    let words = request.trimmingCharacters(in: .whitespacesAndNewlines)
    let hex = try Hex()
    let working = OSAllocatedUnfairLock<String?>(initialState: nil)
    let pill = Pill(words, on: progress)
    // The Live Activity's Stop stops hex too, once hex has started on these words. A stop before then
    // would end whatever else hex is doing in the topic. Closing Siri only ends the wait: iOS reports
    // that as the user cancelling, and hex's answer still lands in the Siri topic.
    let stop: @Sendable () -> Void = { if let topic = working.withLock({ $0 }) { hex.stop(topic) } }
    let ask = { try await pill.stoppable(onStop: stop) { try await hex.ask(words, pill: pill, working: working) } }
    let answer: String
    do {
      if #available(iOS 27, *) {
        answer = try await performBackgroundTask(operation: ask)
      } else {
        answer = try await ask()
      }
    } catch {
      await pill.end()
      throw error
    }
    await pill.end()
    return .result(value: answer, dialog: "\(answer)")
  }
}

// iOS ends an intent after 30 seconds unless it runs as a long-running task that reports progress.
@available(iOS 27, *)
extension AskHex: LongRunningIntent, CancellableIntent {}

// Xcode 27.3's Swift is the first with ToolIntent; older Xcodes build the intent without it.
#if compiler(>=6.4.2)
  @available(iOS 27.3, *)
  extension AskHex: ToolIntent {}
#endif

private struct Topic: Decodable {
  let id: String
  let place: String
  let `where`: String
}

private struct Board: Decodable {
  let tasks: [Topic]
}

private struct Turn: Decodable {
  let from: String
  let text: String
}

private struct Sent: Decodable {
  let key: String
}

private struct Chat: Decodable {
  let version: Double
  let turns: [Turn]
  let waiting: [Sent]
}

// The app server gives a step a brief that fits the Live Activity whole; older ones give only text.
private struct Step: Decodable {
  let text: String
  let brief: String?
  let at: Date
}

// An app server older than ?after= on a task's page answers without a version.
private struct Page: Decodable {
  let version: Double?
  let steps: [Step]?
}

private struct HexError: Error, CustomLocalizedStringResourceConvertible {
  let localizedStringResource: LocalizedStringResource
}

private struct Refused: Error, CustomLocalizedStringResourceConvertible {
  let status: Int
  let localizedStringResource: LocalizedStringResource
}

private struct Unreachable: Error, CustomLocalizedStringResourceConvertible {
  let localizedStringResource: LocalizedStringResource = "Can't reach hex. Check that Tailscale is on."
}

private struct Hex {
  // Past this, hex is stuck rather than busy.
  static let patience: TimeInterval = 600
  static let stuck = "hex has been on it for ten minutes and still hasn't answered."
  // The topic's id, kept once found: a topic quiet for a week drops off hex's board.
  static let kept = "siriTopic"

  // Each ask's timings, read off the phone with `log collect`: how long the app had been running when
  // Siri started the ask says whether asking launched it.
  static let log = Logger(subsystem: "com.shahidy.hexexact", category: "siri")

  let origin: String
  let token: String

  init() throws {
    let info = Bundle.main.infoDictionary ?? [:]
    guard let url = info["HexURL"] as? String, URL(string: url)?.host != nil else {
      throw HexError(localizedStringResource: "This hex app was built without hex's address.")
    }
    origin = url.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    token = info["HexToken"] as? String ?? ""
  }

  func ask(_ words: String, pill: Pill, working: OSAllocatedUnfairLock<String?>) async throws -> String {
    guard !words.isEmpty else { throw HexError(localizedStringResource: "Tell me what to ask hex.") }
    let start = Date()
    // How long hex takes isn't known ahead, so the ring fills on a curve that slows as it goes:
    // a third full at 5s, two thirds at 20s, and full only once hex answers.
    let ticking = Task {
      while !Task.isCancelled {
        let waited = -start.timeIntervalSinceNow
        pill.update { $0.filled = waited / (waited + 10) }
        try await Task.sleep(for: .seconds(1))
      }
    }
    defer { ticking.cancel() }

    // Others post in the topic too, so the answer is the reply that starts with this ask's tag.
    let id = UUID().uuidString.prefix(6).lowercased()
    let tag = "#siri-\(id)"
    let key = "app-siri-\(id)"
    let said = "(asked Siri: reply once, starting with \(tag), then one short spoken sentence; name each command you run in four words or fewer; anything to do on this iPhone itself, like a setting, Focus, alarm or Shortcut, goes on its own last line as For Siri to do: <what to tell Siri>, and Siri does it) \(words)"
    let topic = try await send(said, key: key)
    let sent = Date()
    Self.log.notice("\(tag): app up \(launched(), format: .fixed(precision: 2))s, posted in \(sent.timeIntervalSince(start), format: .fixed(precision: 2))s")

    let following = Task { await follow(topic, since: sent, pill: pill) }
    defer { following.cancel() }

    let end = sent.addingTimeInterval(Self.patience)
    var latest: Chat?
    while true {
      do {
        latest = try await get(chat(topic) + (latest.map { "?after=\(Int64($0.version))" } ?? ""), within: 40)
      } catch is Unreachable {
        try await Task.sleep(for: .seconds(2))
      }
      if let latest {
        if let reply = latest.turns.first(where: { $0.from == "hex" && $0.text.contains(tag) }) {
          Self.log.notice("\(tag): answered in \(-start.timeIntervalSinceNow, format: .fixed(precision: 2))s")
          ticking.cancel()
          pill.update { $0.filled = 1 }
          return String(reply.text.replacingOccurrences(of: tag, with: "").drop { " :-–—\n".contains($0) })
        }
        let waiting = latest.waiting.contains { $0.key.hasSuffix(key) }
        if !waiting { working.withLock { $0 = topic } }
        pill.update {
          $0.waiting = waiting
          $0.started = $0.started || !waiting
        }
      }
      guard end.timeIntervalSinceNow > 1 else { return Self.stuck }
    }
  }

  // Seconds since iOS started the app's process.
  private func launched() -> Double {
    var process = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&name, 4, &process, &size, nil, 0) == 0 else { return -1 }
    let started = process.kp_proc.p_starttime
    return Date().timeIntervalSince1970 - Double(started.tv_sec) - Double(started.tv_usec) / 1e6
  }

  // Posting first, before reading anything, starts hex on the words as soon as it can. The key
  // makes a second post of the same words deliver once.
  private func send(_ said: String, key: String) async throws -> String {
    if let kept = UserDefaults.standard.string(forKey: Self.kept) {
      do {
        try await post(said, key: key, to: kept)
        return kept
      } catch let refused as Refused where refused.status == 404 {}
    }
    let board: Board = try await get("/tasks")
    guard let siri = board.tasks.first(where: { $0.place == "Siri" && $0.where == "Telegram" }) else {
      throw HexError(localizedStringResource: "hex has no Siri topic. Ask hex to open one in Telegram.")
    }
    try await post(said, key: key, to: siri.id)
    UserDefaults.standard.set(siri.id, forKey: Self.kept)
    return siri.id
  }

  private func post(_ said: String, key: String, to topic: String) async throws {
    do {
      _ = try await call(chat(topic), body: ["text": said, "key": key])
    } catch let refused as Refused where refused.status == 409 {
      throw HexError(localizedStringResource: "hex's Siri topic isn't taking messages right now. Ask in Telegram.")
    }
  }

  // The subtitle shows what hex is doing for this ask, as its topic's page lists each step.
  private func follow(_ topic: String, since sent: Date, pill: Pill) async {
    var after: Double?
    while !Task.isCancelled {
      guard let read: Page = try? await get(page(topic) + (after.map { "?after=\(Int64($0))" } ?? ""), within: 40),
        let version = read.version
      else { return }
      if let step = read.steps?.first(where: { $0.at >= sent }) {
        pill.update { $0.step = step.brief ?? step.text }
      }
      after = version
    }
  }

  // Fired without waiting: iOS may suspend the app moments after a cancel.
  func stop(_ topic: String) {
    Self.log.notice("stopping hex in \(topic, privacy: .public)")
    URLSession.shared.dataTask(with: request(page(topic) + "/stop", body: [:], timeout: 10)).resume()
  }

  private func page(_ topic: String) -> String {
    "/tasks/\(topic.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? topic)"
  }

  private func chat(_ topic: String) -> String { page(topic) + "/chat" }

  private func get<T: Decodable>(_ path: String, within timeout: TimeInterval = 30) async throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let text = try decoder.singleValueContainer().decode(String.self)
      return (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))) ?? .distantPast
    }
    return try decoder.decode(T.self, from: try await call(path, timeout: timeout))
  }

  private func request(_ path: String, body: [String: String]?, timeout: TimeInterval) -> URLRequest {
    var request = URLRequest(url: URL(string: origin + path)!, timeoutInterval: timeout)
    if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try? JSONEncoder().encode(body)
    }
    return request
  }

  private func call(_ path: String, body: [String: String]? = nil, timeout: TimeInterval = 30)
    async throws -> Data
  {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request(path, body: body, timeout: timeout))
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch {
      throw Unreachable()
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      // hex explains a refusal in plain words; its bare 404 says nothing.
      let said = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      throw Refused(
        status: status,
        localizedStringResource: "\(said.isEmpty || said == "\(status)" ? "hex answered HTTP \(status)." : said)")
    }
    return data
  }
}

// The Live Activity that shows while hex works on his words is the app's own (AskActivity.swift):
// iOS shows it in place of its own pill for this long-running intent, so its layout is ours. The progress still feeds iOS's pill, which shows when Live Activities are
// off for the app. The title says what the second line is: his words while hex is being asked,
// hex's step once it works.
private final class Pill: Sendable {
  struct State {
    var waiting = false
    var started = false
    var step: String?
    var filled = 0.0
  }

  private typealias Shown = AskAttributes.ContentState

  private let state = OSAllocatedUnfairLock(initialState: State())
  private let shown = OSAllocatedUnfairLock<Shown?>(initialState: nil)
  private let heard: String
  private let progress: Progress
  private let activity: Activity<AskAttributes>?
  private let changes: AsyncStream<Shown>.Continuation
  private let showing: Task<Void, Never>

  init(_ words: String, on progress: Progress) {
    // Siri writes the name as "Hex"; hex gets the words as heard.
    heard = words.replacingOccurrences(of: #"\bHex\b"#, with: "hex", options: .regularExpression)
    self.progress = progress
    progress.totalUnitCount = 1000
    // One left up by an ask the app didn't live to finish.
    for left in Activity<AskAttributes>.activities {
      Task { await left.end(nil, dismissalPolicy: .immediate) }
    }
    let first = Self.shown(State(), heard: heard)
    activity = try? Activity.request(attributes: AskAttributes(), content: .init(state: first, staleDate: nil))
    let (stream, changes) = AsyncStream.makeStream(of: Shown.self, bufferingPolicy: .bufferingNewest(1))
    self.changes = changes
    showing = Task { [activity] in
      for await shown in stream { await activity?.update(.init(state: shown, staleDate: nil)) }
    }
    update { _ in }
  }

  func update(_ change: (inout State) -> Void) {
    let next = state.withLock { state in
      change(&state)
      return Self.shown(state, heard: heard)
    }
    let changed = shown.withLock { shown in
      defer { shown = next }
      return shown != next
    }
    guard changed else { return }
    progress.completedUnitCount = Int64(1000 * next.filled)
    if progress.localizedDescription != next.title { progress.localizedDescription = next.title }
    if progress.localizedAdditionalDescription != next.line { progress.localizedAdditionalDescription = next.line }
    changes.yield(next)
  }

  // Runs the ask until it ends or Stop on the Live Activity is tapped, which stops it.
  func stoppable<T: Sendable>(onStop: @escaping @Sendable () -> Void, _ operation: @escaping @Sendable () async throws -> T)
    async throws -> T
  {
    let work = Task { try await operation() }
    let watching = Task { [id = activity?.id] in
      guard let id else { return }
      for await stop in NotificationCenter.default.notifications(named: StopAsk.stopped) {
        guard stop.object as? String == id else { continue }
        onStop()
        work.cancel()
        return
      }
    }
    defer { watching.cancel() }
    return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
  }

  func end() async {
    changes.finish()
    await showing.value
    await activity?.end(nil, dismissalPolicy: .immediate)
  }

  private static func shown(_ state: State, heard: String) -> Shown {
    let title = state.filled >= 1 ? "hex answered" : state.step != nil || state.started ? "hex is working on it" : state.waiting ? "Waiting for hex" : "Asking hex"
    // The ring moves in hundredths, so a second's tick isn't a redraw.
    return Shown(title: title, line: state.step ?? heard, filled: (state.filled * 100).rounded() / 100)
  }
}
