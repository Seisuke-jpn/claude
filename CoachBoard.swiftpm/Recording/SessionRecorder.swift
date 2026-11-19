import AVFoundation
import CoreImage
import QuartzCore
import UIKit

/// 「動画の今のフレーム（停止中は止めたフレーム）＋手描きの線」を 30fps で合成し続けて録画する。
/// 動画を止めても録画は止まらない。
@MainActor
final class SessionRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    /// 録画経過秒（1秒単位で更新）
    @Published private(set) var elapsed: Int = 0
    @Published var errorMessage: String?

    private var writer: MovieWriter?
    private var captureSession: AVCaptureSession?
    private var displayLink: CADisplayLink?
    private var startedAt: CFTimeInterval = 0

    private weak var player: PlayerController?
    private weak var ink: InkModel?
    private let rasterizer = InkRasterizer(scale: 1)
    private var lastInkVersion = -1
    private var inkImage: CIImage?

    func start(player: PlayerController, ink: InkModel, url: URL) async {
        guard !isRecording, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        let size = Self.outputSize(for: player.presentationSize)

        let newWriter: MovieWriter
        do {
            if micGranted { try configureAudioSessionForRecording() }
            newWriter = try MovieWriter(url: url, size: size, includeAudio: micGranted)
            try newWriter.start()
        } catch {
            restoreAudioSession()
            errorMessage = "録画を開始できませんでした：\(error.localizedDescription)"
            return
        }

        if micGranted {
            let session = makeCaptureSession(delegate: newWriter)
            captureSession = session
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    session.startRunning()
                    continuation.resume()
                }
            }
        } else {
            errorMessage = "マイクが許可されていないため、音声なしで録画します。（設定アプリ → CoachBoard → マイク で許可できます）"
        }

        self.player = player
        self.ink = ink
        writer = newWriter
        lastInkVersion = -1
        inkImage = nil
        player.refreshCurrentFrame()

        startedAt = CACurrentMediaTime()
        elapsed = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link

        UIApplication.shared.isIdleTimerDisabled = true
        isRecording = true
    }

    /// 録画を止めてファイルを確定する。成功したら保存先 URL を返す。
    func stop() async -> URL? {
        guard isRecording, let writer else { return nil }
        isBusy = true
        defer { isBusy = false }

        displayLink?.invalidate()
        displayLink = nil

        if let session = captureSession {
            captureSession = nil
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    session.stopRunning()
                    continuation.resume()
                }
            }
        }

        let result = await writer.finish()
        self.writer = nil
        isRecording = false
        UIApplication.shared.isIdleTimerDisabled = false
        restoreAudioSession()

        switch result {
        case .success(let url):
            return url
        case .failure(let error):
            errorMessage = "録画を保存できませんでした：\(error.localizedDescription)"
            return nil
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let writer else { return }
        // 音声と同じ時計（ホストクロック）で時刻を付ける
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        let pixelBuffer = player?.currentPixelBuffer()
        let orientation = player?.orientation ?? .up

        // 線が変わったときだけ画像を作り直す
        if let ink, ink.version != lastInkVersion {
            lastInkVersion = ink.version
            if let image = rasterizer.full(for: ink, size: writer.size)?.cgImage {
                inkImage = CIImage(cgImage: image)
            } else {
                inkImage = nil
            }
        }
        let inkFrame = inkImage

        writer.queue.async {
            writer.appendFrame(video: pixelBuffer, orientation: orientation, ink: inkFrame, time: time)
        }

        let seconds = Int(CACurrentMediaTime() - startedAt)
        if seconds != elapsed { elapsed = seconds }
    }

    // MARK: - 設定

    private func makeCaptureSession(delegate: MovieWriter) -> AVCaptureSession {
        let session = AVCaptureSession()
        session.automaticallyConfiguresApplicationAudioSession = false
        session.beginConfiguration()
        if let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(input) {
            session.addInput(input)
        }
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(delegate, queue: delegate.queue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        session.commitConfiguration()
        return session
    }

    private func configureAudioSessionForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)
    }

    private func restoreAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    /// 長い辺 1920 / 短い辺 1080 に収まるサイズ（偶数）にする
    static func outputSize(for source: CGSize) -> CGSize {
        let w = max(source.width, 2), h = max(source.height, 2)
        let scale = min(1920 / max(w, h), 1080 / min(w, h))
        func even(_ v: CGFloat) -> CGFloat { max(2, ((v * scale) / 2).rounded(.down) * 2) }
        return CGSize(width: even(w), height: even(h))
    }
}
