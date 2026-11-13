import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A photo or video Bassim picked, as a file on this phone until it's uploaded.
struct Picked {
  let file: URL
  let kind: String
  let type: String
  let aspect: Double

  /// How it shows while it sends: the screen's thumbnail reads a `file:` id from this phone.
  var shown: Media { Media(id: file.absoluteString, kind: kind, aspect: aspect) }
}

/// A photo or video hex holds, by the id `POST /media` gave it.
struct Media {
  let id: String
  let kind: String
  let aspect: Double
  var json: [String: Any] { ["id": id, "kind": kind, "aspect": aspect] }
}

/// The Camera and Photos, as the stable app offers them: at most four at a time, clips up to a
/// minute, videos as 720p H.264 so a minute isn't 4K.
@MainActor
enum MediaPicker {
  static let most = 4
  static let clipSeconds: Double = 60

  /// What Bassim picked, or nothing if he cancelled. `sends` words the camera's button (Send in a
  /// call, Add in a composer).
  static func pick(_ source: String, most: Int = most, sends: Bool) async -> [Picked] {
    guard let top = presenter() else { return [] }
    return source == "camera" ? await camera(on: top, sends: sends) : await photos(on: top, most: most)
  }

  private static func presenter() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    var top = scene?.keyWindow?.rootViewController
    while let next = top?.presentedViewController { top = next }
    return top
  }

  // MARK: Photos

  private static func photos(on top: UIViewController, most: Int) async -> [Picked] {
    var config = PHPickerConfiguration()
    config.filter = .any(of: [.images, .videos])
    config.selectionLimit = most
    config.preferredAssetRepresentationMode = .compatible
    let results: [PHPickerResult] = await withCheckedContinuation { done in
      let picker = PHPickerViewController(configuration: config)
      let delegate = PhotosDelegate { results in done.resume(returning: results) }
      picker.delegate = delegate
      objc_setAssociatedObject(picker, &PhotosDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN)
      top.present(picker, animated: true)
    }
    var picked: [Picked] = []
    for result in results {
      let provider = result.itemProvider
      if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
        guard let file = await copy(provider, UTType.movie) else { continue }
        let asset = AVURLAsset(url: file)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        if duration > clipSeconds + 0.5 {
          tooLong(on: top)
          return []
        }
        if let clip = await clip(file) { picked.append(clip) }
      } else if let file = await copy(provider, UTType.image) {
        let image = UIImage(contentsOfFile: file.path)
        let size = image?.size ?? CGSize(width: 1, height: 1)
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "image/jpeg"
        picked.append(Picked(file: file, kind: "photo", type: type, aspect: size.width / max(size.height, 1)))
      }
    }
    return picked
  }

  private static func tooLong(on top: UIViewController) {
    let alert = UIAlertController(title: "Videos up to a minute", message: "Pick a shorter video, or trim it in Photos.", preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    top.present(alert, animated: true)
  }

  /// The picker's file is gone once its callback returns, so it's copied out first.
  private static func copy(_ provider: NSItemProvider, _ type: UTType) async -> URL? {
    await withCheckedContinuation { done in
      provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
        guard let url else { return done.resume(returning: nil) }
        let out = scratch(url.pathExtension.isEmpty ? (type == .movie ? "mov" : "jpg") : url.pathExtension)
        done.resume(returning: (try? FileManager.default.copyItem(at: url, to: out)) == nil ? nil : out)
      }
    }
  }

  nonisolated static func scratch(_ ext: String) -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hex-media", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext.lowercased())
  }

  /// A clip as hex takes it: H.264 at 720p, in an MP4.
  static func clip(_ file: URL) async -> Picked? {
    let asset = AVURLAsset(url: file)
    let out = scratch("mp4")
    guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { return nil }
    do {
      try await export.export(to: out, as: .mp4)
    } catch {
      return nil
    }
    var aspect = 16.0 / 9
    if let track = try? await asset.loadTracks(withMediaType: .video).first,
      let loaded = try? await track.load(.naturalSize, .preferredTransform)
    {
      let shown = loaded.0.applying(loaded.1)
      aspect = abs(shown.width) / max(abs(shown.height), 1)
    }
    return Picked(file: out, kind: "video", type: "video/mp4", aspect: aspect)
  }

  // MARK: Camera

  private static func camera(on top: UIViewController, sends: Bool) async -> [Picked] {
    await withCheckedContinuation { done in
      var answered = false
      let finish = { (picked: [Picked]) in
        guard !answered else { return }
        answered = true
        done.resume(returning: picked)
      }
      let sheet = CameraSheet(sends: sends) { picked in
        top.presentedViewController?.dismiss(animated: true)
        finish(picked)
      }
      let host = DismissWatcher(rootView: sheet) { finish([]) }
      host.overrideUserInterfaceStyle = .dark
      host.view.backgroundColor = .black
      if let presentation = host.sheetPresentationController {
        presentation.detents = [.medium(), .large()]
        presentation.selectedDetentIdentifier = .large
        presentation.prefersGrabberVisible = true
        presentation.preferredCornerRadius = 32
      }
      top.present(host, animated: true)
    }
  }
}

private final class PhotosDelegate: NSObject, PHPickerViewControllerDelegate {
  nonisolated(unsafe) static var key = 0
  let done: ([PHPickerResult]) -> Void
  init(_ done: @escaping ([PHPickerResult]) -> Void) { self.done = done }
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    done(results)
  }
}

/// A hosted sheet that says when it's swiped away.
private final class DismissWatcher<Content: View>: UIHostingController<Content> {
  private let dismissed: () -> Void
  init(rootView: Content, dismissed: @escaping () -> Void) {
    self.dismissed = dismissed
    super.init(rootView: rootView)
  }
  @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    dismissed()
  }
}

/// The camera, as the stable app's sheet: tap the shutter for a photo, hold it for a video (up to a
/// minute, a red ring filling as it runs), flip between cameras, then look it over and Send or Add.
private struct CameraSheet: View {
  let sends: Bool
  let done: ([Picked]) -> Void
  @StateObject private var camera = CameraModel()
  @State private var pressing = false
  @State private var holdTask: Task<Void, Never>?

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      switch camera.stage {
      case .denied:
        VStack(spacing: 14) {
          Image(systemName: "camera.fill").font(.system(size: 34)).foregroundStyle(.secondary)
          Text("Allow hex to use the camera in Settings.").multilineTextAlignment(.center)
          Button("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
          }
          .buttonStyle(.borderedProminent)
        }
        .padding(32)
      case .live, .recording:
        live
      case .review(let picked):
        review(picked)
      }
    }
    .preferredColorScheme(.dark)
    .task { await camera.start(muted: Call.shared.status != .idle) }
    .onDisappear { camera.stop() }
  }

  private var live: some View {
    VStack(spacing: 0) {
      CameraPreview(session: camera.session)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .overlay(alignment: .top) {
          if camera.stage == .recording {
            Text("● \(Self.clock(camera.recorded))")
              .font(.subheadline.monospacedDigit().weight(.semibold))
              .foregroundStyle(.white)
              .padding(.horizontal, 12).padding(.vertical, 6)
              .background(.red, in: Capsule())
              .padding(.top, 14)
              .transition(.opacity)
          }
        }
        .padding(.horizontal, 12)
        .padding(.top, 20)
      ZStack {
        shutter
        HStack {
          Spacer()
          Button { camera.flip() } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
              .font(.system(size: 20, weight: .medium))
              .frame(width: 48, height: 48)
          }
          .buttonStyle(.glass)
          .buttonBorderShape(.circle)
          .disabled(camera.stage == .recording)
          .opacity(camera.stage == .recording ? 0 : 1)
          .accessibilityLabel("Flip camera")
        }
        .padding(.horizontal, 28)
      }
      .frame(height: 112)
      Text(camera.stage == .recording ? "Release to stop" : "Hold for video")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.bottom, 16)
    }
    .animation(.smooth(duration: 0.2), value: camera.stage)
  }

  private var shutter: some View {
    ZStack {
      Circle().strokeBorder(.white, lineWidth: 4).frame(width: 76, height: 76)
      Circle()
        .trim(from: 0, to: camera.recorded / MediaPicker.clipSeconds)
        .stroke(.red, style: StrokeStyle(lineWidth: 4, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .frame(width: 72, height: 72)
      RoundedRectangle(cornerRadius: camera.stage == .recording ? 8 : 31, style: .continuous)
        .fill(camera.stage == .recording ? Color.red : Color.white)
        .frame(width: camera.stage == .recording ? 30 : 62, height: camera.stage == .recording ? 30 : 62)
        .scaleEffect(pressing && camera.stage != .recording ? 0.9 : 1)
    }
    .contentShape(Circle())
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in
          guard !pressing else { return }
          pressing = true
          holdTask = Task {
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, pressing else { return }
            camera.record()
          }
        }
        .onEnded { _ in
          pressing = false
          holdTask?.cancel()
          if camera.stage == .recording { camera.stopRecording() } else { camera.photo() }
        }
    )
    .accessibilityLabel("Take a photo, or hold for video")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { camera.photo() }
    .sensoryFeedback(.impact(weight: .light), trigger: camera.stage == .recording)
  }

  private func review(_ picked: Picked) -> some View {
    VStack(spacing: 0) {
      Group {
        if picked.kind == "photo", let image = UIImage(contentsOfFile: picked.file.path) {
          Image(uiImage: image).resizable().scaledToFit()
        } else {
          LoopingVideo(url: picked.file)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.horizontal, 12)
      .padding(.top, 20)
      HStack {
        Button("Retake") { camera.retake() }
          .font(.body.weight(.medium))
          .buttonStyle(.glass)
        Spacer()
        Button { done([picked]) } label: {
          Image(systemName: "arrow.up")
            .font(.system(size: 22, weight: .semibold))
            .frame(width: 56, height: 56)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .accessibilityLabel(sends ? "Send" : "Add")
      }
      .padding(.horizontal, 28)
      .frame(height: 112)
    }
  }

  static func clock(_ seconds: Double) -> String {
    let whole = Int(seconds)
    return "\(whole / 60):" + String(format: "%02d", whole % 60)
  }
}

@MainActor
private final class CameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate {
  enum Stage: Equatable {
    case live, recording, denied, review(Picked)
    static func == (a: Stage, b: Stage) -> Bool {
      switch (a, b) {
      case (.live, .live), (.recording, .recording), (.denied, .denied): true
      case (.review(let x), .review(let y)): x.file == y.file
      default: false
      }
    }
  }

  @Published var stage = Stage.live
  @Published var recorded: Double = 0
  nonisolated let session = AVCaptureSession()
  private let photos = AVCapturePhotoOutput()
  private let movies = AVCaptureMovieFileOutput()
  private var position = AVCaptureDevice.Position.back
  private var input: AVCaptureDeviceInput?
  private var clock: Timer?
  private let queue = DispatchQueue(label: "hex.camera")

  /// While a call holds the mic, a clip is recorded without sound, as the stable app does.
  func start(muted: Bool) async {
    guard await AVCaptureDevice.requestAccess(for: .video) else { return stage = .denied }
    session.beginConfiguration()
    session.sessionPreset = .high
    attach(position)
    if !muted, await AVCaptureDevice.requestAccess(for: .audio), let mic = AVCaptureDevice.default(for: .audio),
      let audio = try? AVCaptureDeviceInput(device: mic), session.canAddInput(audio)
    {
      session.addInput(audio)
    }
    if session.canAddOutput(photos) { session.addOutput(photos) }
    if session.canAddOutput(movies) { session.addOutput(movies) }
    movies.maxRecordedDuration = CMTime(seconds: MediaPicker.clipSeconds, preferredTimescale: 600)
    session.commitConfiguration()
    let session = session
    queue.async { session.startRunning() }
  }

  func stop() {
    clock?.invalidate()
    let session = session
    queue.async { session.stopRunning() }
  }

  private func attach(_ position: AVCaptureDevice.Position) {
    if let input { session.removeInput(input) }
    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
      let next = try? AVCaptureDeviceInput(device: device), session.canAddInput(next)
    else { return }
    session.addInput(next)
    input = next
  }

  func flip() {
    position = position == .back ? .front : .back
    session.beginConfiguration()
    attach(position)
    session.commitConfiguration()
  }

  func photo() {
    guard stage == .live, session.isRunning else { return }
    photos.capturePhoto(with: AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]), delegate: self)
  }

  func record() {
    guard stage == .live, session.isRunning else { return }
    stage = .recording
    recorded = 0
    movies.startRecording(to: MediaPicker.scratch("mov"), recordingDelegate: self)
    let began = Date()
    clock = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.recorded = min(MediaPicker.clipSeconds, Date().timeIntervalSince(began)) }
    }
  }

  func stopRecording() {
    clock?.invalidate()
    movies.stopRecording()
  }

  func retake() {
    stage = .live
    recorded = 0
  }

  nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
    guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.8) else { return }
    let file = MediaPicker.scratch("jpg")
    try? jpeg.write(to: file)
    let aspect = image.size.width / max(image.size.height, 1)
    Task { @MainActor in self.stage = .review(Picked(file: file, kind: "photo", type: "image/jpeg", aspect: aspect)) }
  }

  nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
    Task { @MainActor in
      self.clock?.invalidate()
      guard let clip = await MediaPicker.clip(url) else { return self.stage = .live }
      self.stage = .review(clip)
    }
  }
}

private struct CameraPreview: UIViewRepresentable {
  let session: AVCaptureSession
  final class Preview: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
  }
  func makeUIView(context: Context) -> Preview {
    let view = Preview()
    view.preview.session = session
    view.preview.videoGravity = .resizeAspectFill
    view.backgroundColor = .black
    return view
  }
  func updateUIView(_ view: Preview, context: Context) {}
}

private struct LoopingVideo: UIViewRepresentable {
  let url: URL
  final class Player: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var looper: AVPlayerLooper?
  }
  func makeUIView(context: Context) -> Player {
    let view = Player()
    let player = AVQueuePlayer()
    player.isMuted = true
    view.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
    (view.layer as! AVPlayerLayer).player = player
    (view.layer as! AVPlayerLayer).videoGravity = .resizeAspect
    player.play()
    return view
  }
  func updateUIView(_ view: Player, context: Context) {}
}
