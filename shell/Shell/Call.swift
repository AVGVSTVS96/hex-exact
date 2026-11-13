import AVFoundation
import Foundation
import WebRTC

/// One call with hex: the microphone and hex's voice over WebRTC, and the data channel that carries
/// captions, mute and End. It speaks to hex's voice server the way the stable app does: the offer
/// goes to `POST /session`, the answer comes back, and `DELETE /session` ends it.
///
/// Everything the screen shows of it goes through `Bridge`: `state` on each change, `captions` as
/// words arrive, and the two audio levels for the orb.
@MainActor
final class Call: NSObject {
  enum Status: String { case idle, connecting, live, ending }

  static let shared = Call()
  static let changed = Notification.Name("CallChanged")

  private(set) var status = Status.idle
  private(set) var muted = false
  private(set) var hexMuted = false
  private(set) var sessionId: String?
  private(set) var started: Date?
  private(set) var failure: String?
  /// How the last call ended (`you`, `hex`, `dropped`, `expired`, `no-connect`) and how long it ran.
  private(set) var ending = ""
  private(set) var seconds = 0
  private(set) var captions = Captions()
  /// What the mic picks up and what hex says, 0…1, refreshed while the call is live.
  private(set) var levels = (input: Float(0), output: Float(0))

  private let hex = HexServer()
  private let factory: RTCPeerConnectionFactory
  private var peer: RTCPeerConnection?
  private var channel: RTCDataChannel?
  private var microphone: RTCAudioTrack?
  private var meter: Timer?
  private var muteCount = 0

  override private init() {
    RTCInitializeSSL()
    // Speaker, not the earpiece, and Bluetooth when it's on, as the stable app sets it.
    let audio = RTCAudioSessionConfiguration.webRTC()
    audio.mode = AVAudioSession.Mode.videoChat.rawValue
    audio.categoryOptions = [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP]
    RTCAudioSessionConfiguration.setWebRTC(audio)
    factory = RTCPeerConnectionFactory()
    super.init()
  }

  /// `about` is a task id, or `asks` to go through what waits on Bassim.
  func start(voice: String = "marin", about: String = "") {
    guard status == .idle else { return }
    failure = nil
    ending = ""
    muted = false
    hexMuted = false
    captions = Captions()
    set(.connecting)
    Task {
      do {
        let offer = try await makeOffer()
        let opened = try await hex.open(sdp: offer, voice: voice, about: about)
        guard status == .connecting, let peer else { return hex.close(opened.id) }
        sessionId = opened.id
        captions.call = opened.id
        try await peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: opened.sdp))
      } catch {
        fail(error.localizedDescription, as: "no-connect")
      }
    }
  }

  func toggleMute() {
    guard status == .live else { return }
    muted.toggle()
    microphone?.isEnabled = !muted
    muteCount += 1
    send(["type": muted ? "session.input_audio.mute" : "session.input_audio.unmute", "event_id": "mute-\(muteCount)"])
    changed()
  }

  func end() {
    switch status {
    case .connecting:
      if let sessionId { hex.close(sessionId) }
      hangUp(as: "you")
    case .live:
      set(.ending)
      send(["type": "session.close", "event_id": "close-you-app"])
      if let sessionId { hex.close(sessionId) }
      hangUp(as: "you")
    case .idle, .ending:
      break
    }
  }

  private func makeOffer() async throws -> String {
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
    microphone = track
    let events = RTCDataChannelConfiguration()
    events.isOrdered = true
    channel = peer.dataChannel(forLabel: "oai-events", configuration: events)
    channel?.delegate = self

    let wants = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true"], optionalConstraints: nil)
    let offer = try await peer.offer(for: wants)
    try await peer.setLocalDescription(offer)
    // hex's server takes the whole offer at once, so every candidate goes in it.
    for _ in 0..<100 where peer.iceGatheringState != .complete {
      try await Task.sleep(for: .milliseconds(100))
    }
    guard peer.iceGatheringState == .complete, let sdp = peer.localDescription?.sdp else {
      throw Refusal("Could not establish an audio route. Check your network and try again.")
    }
    return sdp
  }

  private func send(_ event: [String: String]) {
    guard let channel, channel.readyState == .open, let data = try? JSONSerialization.data(withJSONObject: event) else { return }
    channel.sendData(RTCDataBuffer(data: data, isBinary: false))
  }

  private func heard(_ event: [String: Any]) {
    switch event["type"] as? String {
    case "session.started":
      started = Date()
      captions.started = started
      set(.live)
      startMeter()
    case "session.input_transcript.delta":
      caption("you", event)
    case "session.output_transcript.delta":
      caption("hex", event)
    case "session.input_audio.muted":
      hexMutedChanged(event, to: true)
    case "session.input_audio.unmuted":
      hexMutedChanged(event, to: false)
    case "session.closed":
      let reason = event["reason"] as? String
      hangUp(as: reason == "expired" ? "expired" : "hex")
    case "error":
      // The server reports these and the call carries on, as the stable app logs them.
      NSLog("hex call: %@", ((event["error"] as? [String: Any])?["message"] as? String) ?? "error")
    default:
      break
    }
  }

  /// hex muting itself comes as `muted` with no event id of ours.
  private func hexMutedChanged(_ event: [String: Any], to value: Bool) {
    guard (event["client_event_id"] as? String)?.hasPrefix("mute-") != true else { return }
    hexMuted = value
    changed()
  }

  private func caption(_ who: String, _ event: [String: Any]) {
    guard let delta = event["delta"] as? String, !delta.isEmpty else { return }
    captions.add(who, delta, at: (event["start_ms"] as? NSNumber)?.doubleValue)
    Bridge.captionsChanged()
  }

  private func fail(_ message: String, as kind: String) {
    failure = message
    if let sessionId { hex.close(sessionId) }
    hangUp(as: kind)
  }

  private func hangUp(as kind: String) {
    seconds = started.map { Int(Date().timeIntervalSince($0)) } ?? 0
    ending = kind
    meter?.invalidate()
    meter = nil
    levels = (0, 0)
    channel?.close()
    peer?.close()
    channel = nil
    peer = nil
    microphone = nil
    sessionId = nil
    started = nil
    set(.idle)
  }

  /// The levels the orb follows, read from WebRTC's stats as the stable app reads them.
  private func startMeter() {
    meter?.invalidate()
    meter = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.measure() }
    }
  }

  private func measure() {
    peer?.statistics { report in
      var input: Float = 0, output: Float = 0
      for stats in report.statistics.values {
        let level = (stats.values["audioLevel"] as? NSNumber)?.floatValue ?? 0
        if stats.type == "media-source" { input = max(input, level) }
        if stats.type == "inbound-rtp", stats.values["kind"] as? String == "audio" { output = max(output, level) }
      }
      Task { @MainActor in
        self.levels = (self.muted ? 0 : input, output)
        Bridge.levelsChanged(self.levels)
      }
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

/// The live call's words, merged as the stable app merges them: a delta joins the last turn of the
/// same side unless more than two seconds passed, turns sort by when they started, and the last
/// 200 stay.
struct Captions {
  struct Turn { var id: Int; var who: String; var text: String; var start: Double; var last: Date }
  var call = ""
  var started: Date?
  private(set) var turns: [Turn] = []
  private var next = 0

  mutating func add(_ who: String, _ delta: String, at start: Double?) {
    let now = Date()
    if let i = turns.lastIndex(where: { $0.who == who }), now.timeIntervalSince(turns[i].last) < 2 {
      turns[i].text += delta
      turns[i].last = now
      return
    }
    let offset = start ?? started.map { now.timeIntervalSince($0) * 1000 } ?? 0
    turns.append(Turn(id: next, who: who, text: delta, start: offset, last: now))
    next += 1
    turns.sort { $0.start < $1.start }
    if turns.count > 200 { turns.removeFirst(turns.count - 200) }
  }

  /// Each turn's instant in epoch milliseconds, so the screen can set the call's asks among them.
  var shown: [[String: Any]] {
    let zero = (started ?? Date()).timeIntervalSince1970 * 1000
    return turns.map { ["id": "\($0.id)", "who": $0.who, "text": $0.text, "at": zero + $0.start] }
  }
}

struct Refusal: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}

/// hex's voice server, at the address and token the build put in Info.plist.
struct HexServer: Sendable {
  struct Opened { let id: String; let sdp: String }

  let origin = (Bundle.main.object(forInfoDictionaryKey: "HexURL") as? String ?? "")
  let token = Bundle.main.object(forInfoDictionaryKey: "HexToken") as? String ?? ""

  func open(sdp: String, voice: String, about: String) async throws -> Opened {
    var body = ["sdp": sdp, "voice": voice, "from": "app"]
    if !about.isEmpty { body["about"] = about }
    let data = try await request("POST", "/session", body)
    guard let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let id = (reply["session"] as? [String: Any])?["id"] as? String,
      let answer = (reply["transport"] as? [String: Any])?["sdp"] as? String
    else { throw Refusal("hex's voice server answered with something unexpected.") }
    return Opened(id: id, sdp: answer)
  }

  func close(_ sessionId: String) {
    Task { _ = try? await request("DELETE", "/session", ["sessionId": sessionId]) }
  }

  private func request(_ method: String, _ path: String, _ body: [String: String]) async throws -> Data {
    guard let url = URL(string: origin + path) else { throw Refusal("This app was built without hex's address.") }
    var request = URLRequest(url: url, timeoutInterval: 20)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard (200..<300).contains(status) else { throw Refusal("hex refused the call (\(status)).") }
      return data
    } catch let error as Refusal {
      throw error
    } catch {
      throw Refusal("Cannot reach hex. Check that Tailscale is on, then try again.")
    }
  }
}

extension Call: RTCPeerConnectionDelegate {
  nonisolated func peerConnection(_ peer: RTCPeerConnection, didChange state: RTCPeerConnectionState) {
    guard state == .failed else { return }
    Task { @MainActor in fail("The connection to hex was lost.", as: "dropped") }
  }
  nonisolated func peerConnection(_ peer: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
  nonisolated func peerConnection(_ peer: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
  nonisolated func peerConnection(_ peer: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
  nonisolated func peerConnectionShouldNegotiate(_ peer: RTCPeerConnection) {}
  nonisolated func peerConnection(_ peer: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
  nonisolated func peerConnection(_ peer: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
  nonisolated func peerConnection(_ peer: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
  nonisolated func peerConnection(_ peer: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
  nonisolated func peerConnection(_ peer: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

extension Call: RTCDataChannelDelegate {
  nonisolated func dataChannelDidChangeState(_ channel: RTCDataChannel) {}
  nonisolated func dataChannel(_ channel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
    guard let event = (try? JSONSerialization.jsonObject(with: buffer.data)) as? [String: Any] else { return }
    Task { @MainActor in heard(event) }
  }
}
