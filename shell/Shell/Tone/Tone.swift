import AVFoundation
import Foundation

/// The pitch and tone of Bassim's voice, as the stable app's voice-tone module hears them: a tap on
/// the echo-cancelled mic samples WebRTC renders (tap.c), read 30 times a second while the call is
/// live and the app in front, and turned into how far his voice lifts and brightens from its own
/// running average (tone.c), each -1…1. The orb squashes and stretches with them.
final class Tone: @unchecked Sendable {
  static let shared = Tone()

  private static let tick = 1.0 / 30
  private static let window = 0.048

  private let queue = DispatchQueue(label: "hex.tone", qos: .userInteractive)
  private var timer: DispatchSourceTimer?
  private var routes: NSObjectProtocol?
  private var state = VoiceTone()
  private var samples = [Float](repeating: 0, count: 4096)
  private var rate = Float(48000)
  private var sent = (pitch: Float(0), tone: Float(0))

  func start(_ heard: @escaping @Sendable (Float, Float) -> Void) {
    queue.async { self.begin(heard) }
  }

  func stop() {
    queue.async { self.end() }
  }

  private func begin(_ heard: @escaping @Sendable (Float, Float) -> Void) {
    guard timer == nil, voice_tap_install() else { return }
    voice_tone_reset(&state)
    sent = (0, 0)
    rate = Float(AVAudioSession.sharedInstance().sampleRate)
    routes = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
      let rate = Float(AVAudioSession.sharedInstance().sampleRate)
      self?.queue.async { self?.rate = rate }
    }
    voice_tap_enable(true)
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: Self.tick, leeway: .milliseconds(4))
    timer.setEventHandler { [weak self] in self?.listen(heard) }
    timer.resume()
    self.timer = timer
  }

  private func end() {
    guard let timer else { return }
    timer.cancel()
    self.timer = nil
    voice_tap_enable(false)
    routes.map(NotificationCenter.default.removeObserver)
    routes = nil
  }

  private func listen(_ heard: @Sendable (Float, Float) -> Void) {
    let wanted = min(Int(rate * Float(Self.window)), samples.count)
    let count = Int(voice_tap_read(&samples, Int32(wanted)))
    voice_tone_step(&state, samples, Int32(count), rate, Float(Self.tick))
    guard abs(state.pitch - sent.pitch) > 0.004 || abs(state.tone - sent.tone) > 0.004 else { return }
    sent = (state.pitch, state.tone)
    heard(state.pitch, state.tone)
  }
}
