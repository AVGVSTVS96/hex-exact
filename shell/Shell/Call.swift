import AVFoundation
import Foundation
import UIKit
import WebRTC

/// One call with hex: the microphone and hex's voice over WebRTC, and the data channel that carries
/// captions, mute and End. It speaks to hex's voice server as the stable app's `LiveSession` does:
/// the offer goes to `POST /session`, the answer comes back, `session.close` (or `DELETE /session`)
/// ends it. A connection that drops carries on in a new session for the same call; a phone call or
/// Siri pauses it.
///
/// Everything the screen shows of it goes through `Bridge`: `state` on each change, `captions` as
/// words arrive, and the two audio levels for the orb.
@MainActor
final class Call: NSObject {
  enum Status: String { case idle, connecting, live, reconnecting, ending }

  static let shared = Call()
  static let changed = Notification.Name("CallChanged")

  private(set) var status = Status.idle
  private(set) var muted = false
  /// Another app (a phone call, Siri) has the audio: the mic is off and hex waits.
  private(set) var interrupted = false
  /// The call's id, which is also its first session's.
  private(set) var id: String?
  private(set) var started: Date?
  private(set) var failure: String?
  /// How the last call ended (`you`, `hex`, `dropped`, `expired`, `no-connect`) and how long it ran.
  private(set) var ending = ""
  private(set) var seconds = 0
  private(set) var captions = Captions()
  private(set) var demo = false
  /// What the mic picks up and what hex says, 0…1, while the call is live and the app in front.
  private(set) var levels = (input: Float(0), output: Float(0))

  private let hex = HexServer()
  private let factory: RTCPeerConnectionFactory
  private var link: Link?
  private var voice = "marin"
  /// Each start and stop moves it on, so what an older attempt finishes late is dropped.
  private var generation = 0
  private var startup: Task<Void, Never>?
  private var meter: Timer?
  private var commands = 0
  private var muteCommand: (id: String, muted: Bool)?
  private var muteRetry: Task<Void, Never>?
  private var closing = false
  private var serverClosed = false
  private var serverEnding: String?
  private var confirmClosed: (() -> Void)?
  private var lostAt = Date.distantPast
  private var tries = 0
  /// Milliseconds from the call's start to the session now carrying it, so its words follow on.
  private var shift: Double = 0
  private var active = true
  private var scripted: [Task<Void, Never>] = []

  private static let closeUnconfirmed = "Audio stopped, but the server could not confirm session closure. Check your network before starting another call."
  private static let carriesOn: Set<String> = ["expired", "connection_lost", "remote_hangup"]
  private static let retries: [Double] = [0, 1, 2, 4, 8]
  private static let giveUp: TimeInterval = 150

  override private init() {
    RTCInitializeSSL()
    // Speaker, not the earpiece, and Bluetooth when it's on, as the stable app sets it.
    let audio = RTCAudioSessionConfiguration.webRTC()
    audio.mode = AVAudioSession.Mode.videoChat.rawValue
    audio.categoryOptions = [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP]
    RTCAudioSessionConfiguration.setWebRTC(audio)
    factory = RTCPeerConnectionFactory()
    super.init()
    let center = NotificationCenter.default
    center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
      guard let info = note.userInfo, let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: raw)
      else { return }
      let reason = (info[AVAudioSessionInterruptionReasonKey] as? UInt).flatMap(AVAudioSession.InterruptionReason.init)
      if type == .began, reason == .appWasSuspended { return }
      MainActor.assumeIsolated { Call.shared.interrupt(type == .began) }
    }
    center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { Call.shared.setActive(true) }
    }
    center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { Call.shared.setActive(false) }
    }
  }

  // MARK: Start

  /// `about` is a task id, or `asks` to go through what waits on Bassim.
  func start(voice: String = "marin", about: String = "") {
    guard status == .idle, !closing else { return }
    begin(demo: false)
    self.voice = voice
    let generation = generation
    Task {
      do {
        let link = try Link(factory: factory, call: self)
        guard generation == self.generation else { return link.close() }
        self.link = link
        let offer = try await link.offer()
        guard generation == self.generation else { return }
        let opened = try await hex.open(sdp: offer, voice: voice, about: about)
        guard generation == self.generation else { return hex.close(opened.id) }
        id = opened.id
        captions.call = opened.id
        startup = after(25, generation) { $0.stop(failure: "The voice session did not start. Please try again.") }
        try await link.answer(opened.sdp)
      } catch {
        if generation == self.generation { stop(failure: error.localizedDescription) }
      }
    }
  }

  /// The demo call (`hexexact://demo`): no microphone and no server for the call itself, four
  /// scripted lines, and hex speaking, so the call's screens can be shot on the simulator.
  func startDemo() {
    guard status == .idle, !closing else { return }
    begin(demo: true)
    id = "demo"
    captions.call = "demo"
    let generation = generation
    scripted = [after(0.8, generation) { $0.heard(["type": "session.started"]) }]
    let lines: [(String, Double, String)] = [
      ("session.input_transcript.delta", 4, "What's left on the voice app's Duo pass?"),
      ("session.output_transcript.delta", 9, "Layout moves the buttons into the top bar, glass makes them native, and Tasks gets its own way back to the call."),
      ("session.input_transcript.delta", 22, "And the transcript beside Tasks?"),
      ("session.output_transcript.delta", 26, "That's in the layout pass too."),
    ]
    for (type, at, text) in lines {
      scripted.append(after(0.8 + at, generation) {
        $0.heard(["type": type, "delta": text, "start_ms": at * 1000, "end_ms": (at + 4) * 1000])
      })
    }
  }

  private func begin(demo: Bool) {
    generation += 1
    self.demo = demo
    failure = nil
    ending = ""
    muted = false
    interrupted = false
    id = nil
    started = nil
    seconds = 0
    shift = 0
    serverClosed = false
    serverEnding = nil
    muteCommand = nil
    captions = Captions()
    set(.connecting)
  }

  // MARK: Mute and interruptions

  func toggleMute() {
    guard status == .live else { return }
    if interrupted {
      interrupt(false)
      if !muted { return }
    }
    muted.toggle()
    if muted { link?.microphone(on: false) }
    hear(input: 0)
    changed()
    sendMute(muted)
  }

  /// The mic stays as he set it until hex confirms, and an unconfirmed change goes out again rather
  /// than ending a call that may be fine: a lost connection ends it by its own path.
  private func sendMute(_ muted: Bool) {
    muteRetry?.cancel()
    commands += 1
    let id = "mute-\(commands)"
    muteCommand = (id, muted)
    send(["type": muted ? "session.input_audio.mute" : "session.input_audio.unmute", "event_id": id])
    muteRetry = after(5, generation) { call in
      if call.muteCommand?.id == id { call.sendMute(muted) }
    }
  }

  private func confirmMute(_ event: [String: Any], muted confirmed: Bool) {
    guard let command = muteCommand, event["client_event_id"] as? String == command.id, command.muted == confirmed else { return }
    muteRetry?.cancel()
    muteCommand = nil
    if !command.muted, !muted, !interrupted { link?.microphone(on: true) }
  }

  func interrupt(_ began: Bool) {
    guard status == .live, link != nil || demo, began != interrupted else { return }
    if !muted {
      link?.microphone(on: !began)
      commands += 1
      send(["type": began ? "session.input_audio.mute" : "session.input_audio.unmute", "event_id": "interruption-\(commands)"])
    }
    interrupted = began
    hear(input: 0)
    changed()
    if let id, !demo { hex.mark(id, began ? "paused" : "resumed") }
  }

  // MARK: What hex says

  private func send(_ event: [String: String]) {
    if demo { return echo(event) }
    _ = link?.send(event)
  }

  /// The demo's voice answers each command as hex's would.
  private func echo(_ event: [String: String]) {
    let type = event["type"] ?? ""
    let generation = generation
    scripted.append(after(0.15, generation) { call in
      if type == "session.close" {
        call.heard(["type": "session.closed"])
      } else {
        call.heard(["type": type + "d", "client_event_id": event["event_id"] ?? ""])
      }
    })
  }

  fileprivate func heard(_ event: [String: Any], from link: Link? = nil) {
    if let link, link !== self.link { return }
    switch event["type"] as? String {
    case "session.started":
      startup?.cancel()
      if status == .reconnecting { return resumed() }
      guard status == .connecting else { return }
      started = Date()
      captions.started = started
      set(.live)
      startMeter()
      Feedback.went(live: true)
    case "session.input_transcript.delta":
      caption("you", event)
    case "session.output_transcript.delta":
      caption("hex", event)
    case "session.input_audio.muted":
      confirmMute(event, muted: true)
    case "session.input_audio.unmuted":
      confirmMute(event, muted: false)
    case "session.closed":
      serverClosed = true
      confirmClosed?()
      guard !closing else { return }
      let reason = event["reason"] as? String
      if let reason, Self.carriesOn.contains(reason) {
        lose("The voice session ended.", reason: reason)
      } else {
        serverEnding = Self.ending(reason)
        stop()
      }
    case "error":
      // hex reports these and the call carries on, as the stable app logs them.
      NSLog("hex call: %@", ((event["error"] as? [String: Any])?["message"] as? String) ?? "error")
    default:
      break
    }
  }

  private static func ending(_ reason: String?) -> String {
    reason == "expired" ? "expired" : reason == "connection_lost" ? "dropped" : "hex"
  }

  private func caption(_ who: String, _ event: [String: Any]) {
    guard let delta = event["delta"] as? String, !delta.isEmpty else { return }
    let elapsed = started.map { Date().timeIntervalSince($0) * 1000 } ?? 0
    let start = (event["start_ms"] as? NSNumber).map { $0.doubleValue + shift } ?? elapsed
    let end = (event["end_ms"] as? NSNumber).map { $0.doubleValue + shift } ?? start
    captions.add(who, delta, start: start, end: end)
    Bridge.captionsChanged()
  }

  // MARK: Carrying on after a drop

  fileprivate func failed(_ message: String, link: Link) {
    guard link === self.link, !closing else { return }
    lose(message)
  }

  /// Only a hang-up ends a call. A connection that fails, or a session OpenAI ends on its own, has
  /// the call carry on in a new session hex opens for the same call, with the call so far.
  private func lose(_ failure: String, reason: String? = nil) {
    if status == .reconnecting { return retry() }
    guard status == .live, id != nil, !demo else {
      if let reason { serverEnding = Self.ending(reason) }
      return stop(failure: reason == nil ? failure : nil)
    }
    lostAt = Date()
    tries = 0
    stopMeter()
    muteRetry?.cancel()
    muteCommand = nil
    set(.reconnecting)
    carryOn()
  }

  private func carryOn() {
    guard let call = id else { return }
    let generation = generation
    let reconnecting = { [weak self] in self?.generation == generation && self?.status == .reconnecting }
    link?.close()
    link = nil
    Task {
      var made: Link?
      do {
        let link = try Link(factory: factory, call: self)
        made = link
        guard reconnecting() else { return link.close() }
        self.link = link
        link.microphone(on: !(muted || interrupted))
        let opened = try await hex.open(sdp: try await link.offer(), voice: voice, about: "", continues: call)
        guard reconnecting() else { return }
        startup = after(25, generation) { $0.retry() }
        try await link.answer(opened.sdp)
      } catch HexServer.Gone.call {
        guard reconnecting() else { return }
        serverClosed = true
        serverEnding = "dropped"
        stop()
      } catch {
        if reconnecting(), made === link { retry() }
      }
    }
  }

  private func retry() {
    startup?.cancel()
    if Date().timeIntervalSince(lostAt) > Self.giveUp {
      serverClosed = true
      return stop(failure: "The connection to hex was lost.")
    }
    let wait = Self.retries[min(tries, Self.retries.count - 1)]
    tries += 1
    startup = after(wait, generation) { call in
      if call.status == .reconnecting { call.carryOn() }
    }
  }

  private func resumed() {
    shift = started.map { Date().timeIntervalSince($0) * 1000 } ?? 0
    set(.live)
    startMeter()
    commands += 1
    if muted {
      sendMute(true)
    } else if interrupted {
      send(["type": "session.input_audio.mute", "event_id": "interruption-\(commands)"])
    }
  }

  // MARK: End

  func end() {
    switch status {
    case .connecting, .live, .reconnecting: stop()
    case .idle, .ending: break
    }
  }

  /// Hangs up: says so on the data channel and waits up to 1.5 s for hex to confirm, else closes the
  /// session over HTTP. `failure` ends it as dropped (or couldn't connect) with that message.
  private func stop(failure: String? = nil) {
    guard !closing, status != .idle else { return }
    let connected = status == .live || status == .reconnecting
    let kind = failure != nil ? (connected ? "dropped" : "no-connect") : serverEnding ?? (connected ? "you" : "")
    let wasLive = started != nil
    generation += 1
    startup?.cancel()
    muteRetry?.cancel()
    scripted.forEach { $0.cancel() }
    scripted = []
    muteCommand = nil
    stopMeter()
    closing = true
    seconds = started.map { Int(Date().timeIntervalSince($0)) } ?? 0
    let link = self.link
    let id = self.id
    link?.microphone(on: false)
    set(.ending)
    Task {
      var confirmed = serverClosed
      if !confirmed, link != nil || demo { confirmed = await closeConfirmed() }
      link?.close()
      self.link = nil
      var closeError: String?
      if !confirmed, let id, !demo {
        do { try await hex.closeNow(id) } catch { closeError = Self.closeUnconfirmed }
      }
      confirmClosed = nil
      self.failure = failure ?? closeError
      ending = kind
      muted = false
      interrupted = false
      self.id = nil
      started = nil
      closing = false
      demo = false
      set(.idle)
      if wasLive { Feedback.went(live: false) }
    }
  }

  private func closeConfirmed() async -> Bool {
    await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
      var settled = false
      let settle = { (value: Bool) in
        guard !settled else { return }
        settled = true
        done.resume(returning: value)
      }
      confirmClosed = { settle(true) }
      if demo {
        echo(["type": "session.close", "event_id": "close-you-app"])
      } else if link?.send(["type": "session.close", "event_id": "close-you-app"]) != true {
        return settle(false)
      }
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(1500))
        settle(false)
      }
    }
  }

  // MARK: Media

  /// Photos and videos Bassim sends into the live call: shown at once as sending, uploaded, then
  /// handed to the call, where hex has a look.
  func share(_ picked: [Picked]) {
    guard status == .live, let id, !picked.isEmpty else { return }
    let at = Date().timeIntervalSince1970 * 1000
    let key = captions.sending(picked, at: at)
    Bridge.captionsChanged()
    Task {
      do {
        var sent: [Media] = []
        for item in picked { sent.append(try await hex.upload(item)) }
        if !demo { try await hex.share(sent.map(\.id), into: id) }
        captions.sent(key, sent)
      } catch {
        captions.unsent(key, (error as? LocalizedError)?.errorDescription ?? "hex didn't take it")
      }
      Bridge.captionsChanged()
    }
  }

  func retryShare(_ key: String) {
    guard let picked = captions.picked(key) else { return }
    captions.drop(key)
    share(picked)
  }

  // MARK: Levels

  private func setActive(_ active: Bool) {
    self.active = active
    if active { startMeter() } else { stopMeter() }
  }

  /// The levels the orb follows, read from WebRTC's stats as the stable app reads them.
  private func startMeter() {
    meter?.invalidate()
    meter = nil
    guard active, status == .live else { return }
    meter = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
      MainActor.assumeIsolated { Call.shared.measure() }
    }
  }

  private func stopMeter() {
    meter?.invalidate()
    meter = nil
    hear(input: 0, output: 0)
  }

  private func measure() {
    if demo {
      let wave = Float(0.45 + 0.35 * sin(Date().timeIntervalSince1970 * 5))
      return hear(input: 0, output: wave)
    }
    link?.levels { input, output in
      Task { @MainActor in
        let call = Call.shared
        guard call.status == .live else { return }
        call.hear(input: call.muted || call.interrupted ? 0 : min(1, input * 5), output: min(1, output * 5))
      }
    }
  }

  private func hear(input: Float? = nil, output: Float? = nil) {
    let next = (input: input ?? levels.input, output: output ?? levels.output)
    guard next != levels else { return }
    levels = next
    Bridge.levelsChanged(levels)
  }

  // MARK: Plumbing

  /// `body` once, `seconds` from now, if no start or stop came between.
  @discardableResult
  private func after(_ seconds: Double, _ generation: Int, _ body: @escaping (Call) -> Void) -> Task<Void, Never> {
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
      guard !Task.isCancelled, generation == self.generation else { return }
      body(self)
    }
  }

  private func set(_ next: Status) {
    status = next
    changed()
  }

  private func changed() {
    NotificationCenter.default.post(name: Self.changed, object: self)
  }
}

/// One session's connection: the peer, its data channel and the mic. A call that carries on after a
/// drop gets a new one, and whatever the old one says late is ignored.
private final class Link: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
  private var peer: RTCPeerConnection!
  private var channel: RTCDataChannel?
  private var mic: RTCAudioTrack?
  private weak var call: Call?
  private var closed = false
  private var disconnect: Task<Void, Never>?
  private var energies: [String: (energy: Double, duration: Double)] = [:]

  @MainActor
  init(factory: RTCPeerConnectionFactory, call: Call) throws {
    self.call = call
    super.init()
    let config = RTCConfiguration()
    config.iceServers = []
    config.sdpSemantics = .unifiedPlan
    let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    guard let peer = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
      throw Refusal("Could not prepare the audio connection.")
    }
    self.peer = peer
    let track = factory.audioTrack(with: factory.audioSource(with: constraints), trackId: "mic")
    peer.add(track, streamIds: ["hex"])
    mic = track
    let events = RTCDataChannelConfiguration()
    events.isOrdered = true
    channel = peer.dataChannel(forLabel: "oai-events", configuration: events)
    channel?.delegate = self
  }

  /// The whole offer at once, every candidate in it, as hex's server takes it.
  @MainActor
  func offer() async throws -> String {
    let wants = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true"], optionalConstraints: nil)
    let offer = try await peer.offer(for: wants)
    try await peer.setLocalDescription(offer)
    for _ in 0..<100 where peer.iceGatheringState != .complete {
      try await Task.sleep(for: .milliseconds(100))
    }
    guard peer.iceGatheringState == .complete, let sdp = peer.localDescription?.sdp, !sdp.isEmpty else {
      throw Refusal("Could not establish an audio route. Check your network and try again.")
    }
    return sdp
  }

  @MainActor
  func answer(_ sdp: String) async throws {
    try await peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp))
  }

  func microphone(on: Bool) { mic?.isEnabled = on }

  func send(_ event: [String: String]) -> Bool {
    guard !closed, let channel, channel.readyState == .open, let data = try? JSONSerialization.data(withJSONObject: event) else { return false }
    return channel.sendData(RTCDataBuffer(data: data, isBinary: false))
  }

  func levels(_ answer: @escaping @Sendable (Float, Float) -> Void) {
    guard !closed else { return }
    peer.statistics { [weak self] report in
      guard let self else { return }
      var input: Double = 0, output: Double = 0
      for (key, stats) in report.statistics {
        let values = stats.values
        guard values["kind"] as? String == "audio" || stats.type == "media-source" else { continue }
        var level = (values["audioLevel"] as? NSNumber)?.doubleValue
        if let energy = (values["totalAudioEnergy"] as? NSNumber)?.doubleValue,
          let duration = (values["totalSamplesDuration"] as? NSNumber)?.doubleValue
        {
          if level == nil, let last = energies[key], duration > last.duration {
            level = sqrt(max(0, (energy - last.energy) / (duration - last.duration)))
          }
          energies[key] = (energy, duration)
        }
        if stats.type == "media-source" { input = max(input, level ?? 0) }
        if stats.type == "inbound-rtp" { output = max(output, level ?? 0) }
      }
      answer(Float(input), Float(output))
    }
  }

  func close() {
    guard !closed else { return }
    closed = true
    disconnect?.cancel()
    mic?.isEnabled = false
    channel?.close()
    peer.close()
  }

  private func failed(_ message: String) {
    Task { @MainActor in
      guard !self.closed else { return }
      self.call?.failed(message, link: self)
    }
  }

  func peerConnection(_ peer: RTCPeerConnection, didChange state: RTCPeerConnectionState) {
    disconnect?.cancel()
    if state == .failed { failed("The audio connection failed. Check your connection and try again.") }
    if state == .disconnected {
      disconnect = Task {
        try? await Task.sleep(for: .seconds(7))
        if !Task.isCancelled { failed("The audio connection was lost. Try starting again.") }
      }
    }
  }

  func dataChannelDidChangeState(_ channel: RTCDataChannel) {
    if channel.readyState == .closed { failed("The voice connection closed. Start a new conversation to reconnect.") }
  }

  func dataChannel(_ channel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
    guard let event = (try? JSONSerialization.jsonObject(with: buffer.data)) as? [String: Any] else { return }
    Task { @MainActor in
      guard !self.closed else { return }
      self.call?.heard(event, from: self)
    }
  }

  func peerConnection(_ peer: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
  func peerConnection(_ peer: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
  func peerConnection(_ peer: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
  func peerConnectionShouldNegotiate(_ peer: RTCPeerConnection) {}
  func peerConnection(_ peer: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
  func peerConnection(_ peer: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
  func peerConnection(_ peer: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
  func peerConnection(_ peer: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
  func peerConnection(_ peer: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

/// The live call's words, merged as the stable app merges them: a delta joins the last turn of the
/// same side unless more than two seconds of call time passed, turns sort by when they started, and
/// the last 200 stay. Photos and videos sent into the call sit among them, as Bassim's.
struct Captions {
  struct Turn {
    var id: String
    var who: String
    var text: String
    var start: Double
    var end: Double
    var media: [Media] = []
    var picked: [Picked] = []
    /// "sending", why it wasn't sent, or "" once sent.
    var note = ""
  }

  var call = ""
  var started: Date?
  private(set) var turns: [Turn] = []
  private var next = 0

  mutating func add(_ who: String, _ delta: String, start: Double, end: Double) {
    if let i = turns.lastIndex(where: { $0.who == who && $0.picked.isEmpty }), start - turns[i].end <= 2000 {
      turns[i].text += delta
      turns[i].end = max(turns[i].end, end)
      return
    }
    turns.append(Turn(id: "\(next)", who: who, text: delta, start: start, end: end))
    next += 1
    tidy()
  }

  mutating func sending(_ picked: [Picked], at: Double) -> String {
    let start = at - (started?.timeIntervalSince1970 ?? at / 1000) * 1000
    let key = "m\(next)"
    next += 1
    turns.append(Turn(id: key, who: "you", text: "", start: start, end: start, media: picked.map(\.shown), picked: picked, note: "sending"))
    tidy()
    return key
  }

  mutating func sent(_ key: String, _ media: [Media]) {
    guard let i = turns.firstIndex(where: { $0.id == key }) else { return }
    turns[i].media = media
    turns[i].note = ""
  }

  mutating func unsent(_ key: String, _ why: String) {
    guard let i = turns.firstIndex(where: { $0.id == key }) else { return }
    turns[i].note = why
  }

  func picked(_ key: String) -> [Picked]? { turns.first { $0.id == key }?.picked }

  mutating func drop(_ key: String) { turns.removeAll { $0.id == key } }

  private mutating func tidy() {
    turns.sort { $0.start < $1.start }
    if turns.count > 200 { turns.removeFirst(turns.count - 200) }
  }

  /// Each turn's instant in epoch milliseconds, so the screen can set the call's asks among them.
  var shown: [[String: Any]] {
    let zero = (started ?? Date()).timeIntervalSince1970 * 1000
    return turns.map {
      ["id": $0.id, "who": $0.who, "text": $0.text, "at": zero + $0.start, "media": $0.media.map(\.json), "note": $0.note]
    }
  }
}

struct Refusal: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}

/// hex's voice server, at the address and token the build put in Info.plist.
struct HexServer: Sendable {
  struct Opened { let id: String; let sdp: String }
  enum Gone: Error { case call }

  let origin = (Bundle.main.object(forInfoDictionaryKey: "HexURL") as? String ?? "")
  let token = Bundle.main.object(forInfoDictionaryKey: "HexToken") as? String ?? ""

  /// A new call, or with `continues` a new session for a call that dropped (410: it's gone).
  func open(sdp: String, voice: String, about: String, continues: String? = nil) async throws -> Opened {
    var body = ["sdp": sdp, "voice": voice, "from": "app"]
    if !about.isEmpty { body["about"] = about }
    if let continues { body["continues"] = continues }
    let (data, status) = try await request("POST", "/session", json: body)
    if status == 410, continues != nil { throw Gone.call }
    try check(status, data)
    guard let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let id = (reply["session"] as? [String: Any])?["id"] as? String,
      let answer = (reply["transport"] as? [String: Any])?["sdp"] as? String
    else { throw Refusal("hex's voice server answered with something unexpected.") }
    return Opened(id: continues ?? id, sdp: answer)
  }

  func close(_ sessionId: String) {
    Task { try? await closeNow(sessionId) }
  }

  func closeNow(_ sessionId: String) async throws {
    let (data, status) = try await request("DELETE", "/session", json: ["sessionId": sessionId])
    try check(status, data)
  }

  /// A pause or resume in the call's record, so hex's voice waits while another app has the audio.
  func mark(_ call: String, _ kind: String) {
    Task { _ = try? await request("POST", "/calls/\(call)/moments", json: ["kind": kind]) }
  }

  func upload(_ item: Picked) async throws -> Media {
    let bytes = try Data(contentsOf: item.file)
    let (data, status) = try await request("POST", "/media", body: bytes, type: item.type, timeout: 300)
    try check(status, data)
    guard let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let id = reply["id"] as? String else {
      throw Refusal("hex answered the upload with something unexpected.")
    }
    return Media(id: id, kind: reply["kind"] as? String ?? item.kind, aspect: item.aspect)
  }

  func share(_ ids: [String], into call: String) async throws {
    let (data, status) = try await request("POST", "/calls/\(call)/media", json: ["media": ids])
    if status == 409 { throw Refusal("The call has ended") }
    try check(status, data)
  }

  private func check(_ status: Int, _ data: Data) throws {
    guard !(200..<300).contains(status) else { return }
    let text = String(decoding: data, as: UTF8.self)
    let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
    throw Refusal(String((message ?? (text.isEmpty ? "hex refused (\(status))" : text)).prefix(300)))
  }

  private func request(_ method: String, _ path: String, json: Any) async throws -> (Data, Int) {
    try await request(method, path, body: try JSONSerialization.data(withJSONObject: json), type: "application/json")
  }

  private func request(_ method: String, _ path: String, body: Data, type: String, timeout: TimeInterval = 60) async throws -> (Data, Int) {
    guard let url = URL(string: origin + path) else { throw Refusal("This app was built without hex's address.") }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = method
    request.setValue(type, forHTTPHeaderField: "Content-Type")
    if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    request.httpBody = body
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    } catch {
      throw Refusal("Cannot reach hex. Check that Tailscale is on, then try again.")
    }
  }
}
