import AVFoundation
import Foundation
import WebRTC

/// One call with hex: the microphone and hex's voice over WebRTC, and the data channel that carries
/// mute and End. It speaks to hex's voice server the way the stable app does: the offer goes to
/// `POST /session`, the answer comes back, and `DELETE /session` ends it.
@MainActor
final class Call: NSObject {
  enum Status: String { case idle, connecting, connected, ending }

  static let shared = Call()
  static let changed = Notification.Name("CallChanged")

  private(set) var status = Status.idle
  private(set) var muted = false
  private(set) var sessionId: String?
  private(set) var started: Date?
  private(set) var failure: String?

  private let hex = HexServer()
  private let factory: RTCPeerConnectionFactory
  private var peer: RTCPeerConnection?
  private var channel: RTCDataChannel?
  private var microphone: RTCAudioTrack?

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

  func start(voice: String = "marin") {
    guard status == .idle else { return }
    failure = nil
    muted = false
    set(.connecting)
    Task {
      do {
        let offer = try await makeOffer()
        let opened = try await hex.open(sdp: offer, voice: voice)
        guard status == .connecting, let peer else { return hex.close(opened.id) }
        sessionId = opened.id
        try await peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: opened.sdp))
      } catch {
        fail(error.localizedDescription)
      }
    }
  }

  func toggleMute() {
    guard status == .connected else { return }
    muted.toggle()
    microphone?.isEnabled = !muted
    send(["type": muted ? "session.input_audio.mute" : "session.input_audio.unmute"])
    changed()
  }

  func end() {
    guard status == .connecting || status == .connected else { return }
    set(.ending)
    send(["type": "session.close"])
    if let sessionId { hex.close(sessionId) }
    hangUp()
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
      set(.connected)
    case "session.closed":
      hangUp()
    case "error":
      fail((event["error"] as? [String: Any])?["message"] as? String ?? "hex's voice session failed.")
    default:
      break
    }
  }

  private func fail(_ message: String) {
    failure = message
    if let sessionId { hex.close(sessionId) }
    hangUp()
  }

  private func hangUp() {
    channel?.close()
    peer?.close()
    channel = nil
    peer = nil
    microphone = nil
    sessionId = nil
    started = nil
    set(.idle)
  }

  private func set(_ next: Status) {
    status = next
    changed()
  }

  private func changed() {
    NotificationCenter.default.post(name: Self.changed, object: self)
  }
}

extension Call: RTCPeerConnectionDelegate {
  nonisolated func peerConnection(_ peer: RTCPeerConnection, didChange state: RTCPeerConnectionState) {
    guard state == .failed else { return }
    Task { @MainActor in fail("The audio connection failed. Check your connection and try again.") }
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

struct Refusal: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}

/// hex's voice server, at the address and token the build put in Info.plist.
struct HexServer: Sendable {
  struct Opened { let id: String; let sdp: String }

  let origin = (Bundle.main.object(forInfoDictionaryKey: "HexURL") as? String ?? "")
  let token = Bundle.main.object(forInfoDictionaryKey: "HexToken") as? String ?? ""

  func open(sdp: String, voice: String) async throws -> Opened {
    let data = try await request("POST", "/session", ["sdp": sdp, "voice": voice, "from": "app"])
    guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let id = (body["session"] as? [String: Any])?["id"] as? String,
      let answer = (body["transport"] as? [String: Any])?["sdp"] as? String
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
