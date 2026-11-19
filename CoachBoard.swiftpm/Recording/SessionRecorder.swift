import AVFoundation
import CoreImage
import QuartzCore
import UIKit

/// 録画の司令塔。
/// - 映像：「動画の今のフレーム（停止中は止めたフレーム）＋手描きの線」を 30fps で合成し続ける
/// - 声：マイクを別ファイルに録音
/// - 動画の音：「いつ・動画のどこを・何倍速で流していたか」を記録しておき、
///   録画停止後に動画ファイルから音を取り出して同じタイミングに並べ、声と重ねて書き出す
@MainActor
final class SessionRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var isProcessing = false
    /// 録画経過秒（1秒単位で更新）
    @Published private(set) var elapsed: Int = 0
    /// マイクの音量（0〜1）。録画中のメーター用。
    @Published private(set) var micLevel: Float = 0
    @Published var errorMessage: String?

    private var writer: MovieWriter?
    private var mic: MicRecorder?
    private var displayLink: CADisplayLink?
    private var startedAt: CFTimeInterval = 0
    private var tickCount = 0

    private weak var player: PlayerController?
    private weak var ink: InkModel?
    private let rasterizer = InkRasterizer()
    private var lastInkVersion = -1
    private var inkImage: CIImage?

    private var wallOrigin: Double?
    private var samples: [PlaybackSample] = []
    private var sourceURL: URL?
    private var finalURL: URL?

    func start(player: PlayerController, ink: InkModel, url: URL) async {
        guard !isRecording, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        let micGranted = await AVAudioApplication.requestRecordPermission()
        let size = Self.outputSize(for: player.presentationSize)
        let temp = FileManager.default.temporaryDirectory

        let newWriter: MovieWriter
        do {
            newWriter = try MovieWriter(url: temp.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4"),
                                        size: size)
            try newWriter.start()
        } catch {
            errorMessage = "録画を開始できませんでした：\(error.localizedDescription)"
            return
        }

        if micGranted {
            do {
                try configureAudioSessionForRecording()
                let recorder = MicRecorder(url: temp.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf"))
                try recorder.start()
                mic = recorder
            } catch {
                errorMessage = "マイクを開始できなかったため、声なしで録画します：\(error.localizedDescription)"
            }
        } else {
            errorMessage = "マイクが許可されていないため、声なしで録画します。（設定アプリ → CoachBoard → マイク で許可できます）"
        }

        self.player = player
        self.ink = ink
        writer = newWriter
        finalURL = url
        sourceURL = player.hasVideo ? player.sourceURL : nil
        samples = []
        samples.reserveCapacity(30 * 60 * 10)
        wallOrigin = nil
        lastInkVersion = -1
        inkImage = nil
        player.refreshCurrentFrame()

        startedAt = CACurrentMediaTime()
        elapsed = 0
        tickCount = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link

        UIApplication.shared.isIdleTimerDisabled = true
        isRecording = true
    }

    /// 録画を止めて、映像・動画の音・声を重ねた mp4 を作る。成功したら保存先 URL を返す。
    func stop() async -> URL? {
        guard isRecording, let writer, let finalURL else { return nil }
        isBusy = true
        defer { isBusy = false }

        displayLink?.invalidate()
        displayLink = nil
        let micResult = mic?.stop()
        mic = nil
        micLevel = 0

        let videoResult = await writer.finish()
        self.writer = nil
        isRecording = false
        UIApplication.shared.isIdleTimerDisabled = false
        restoreAudioSession()

        let videoOnly: URL
        switch videoResult {
        case .success(let url):
            videoOnly = url
        case .failure(let error):
            if let micResult { try? FileManager.default.removeItem(at: micResult.url) }
            errorMessage = "録画を保存できませんでした：\(error.localizedDescription)"
            return nil
        }

        isProcessing = true
        defer { isProcessing = false }
        let segments = PlaybackTimeline.segments(from: samples)
        let sampleCount = samples.count
        let playingCount = samples.filter { $0.rate > 0 }.count
        samples = []
        do {
            let report = try await NarrationMixer.makeFinalMovie(videoOnly: videoOnly,
                                                    source: sourceURL,
                                                    segments: segments,
                                                    mic: micResult,
                                                    wallOrigin: wallOrigin ?? 0,
                                                    settings: NarrationMixSettings.current,
                                                    output: finalURL)
            if sourceURL != nil, report.gameSeconds < 0.1 {
                // 原因を特定するための情報を出す
                errorMessage = """
                動画の音を録画に重ねられませんでした。お手数ですが、この画面のスクリーンショットを送ってください。
                記録 \(sampleCount) 件（うち再生中 \(playingCount) 件）／再生区間 \(segments.count) 個／元動画の音声トラック \(report.sourceAudioTracks) 本／声 \(Int(report.micSeconds)) 秒
                """
            }
        } catch {
            // 音の合成に失敗しても映像だけは残す
            try? FileManager.default.removeItem(at: finalURL)
            try? FileManager.default.moveItem(at: videoOnly, to: finalURL)
            errorMessage = "音声を重ねられなかったため、映像のみ保存しました：\(error.localizedDescription)"
        }
        if let micResult { try? FileManager.default.removeItem(at: micResult.url) }
        return FileManager.default.fileExists(atPath: finalURL.path) ? finalURL : nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let writer else { return }
        // マイクと同じ時計（ホストクロック）で時刻を付ける
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        if wallOrigin == nil { wallOrigin = time.seconds }

        let frame = player?.currentFrame()
        if let frame, player?.hasVideo == true {
            samples.append(PlaybackSample(wall: time.seconds, video: frame.itemTime, rate: frame.rate))
        }
        let pixelBuffer = frame?.buffer
        let orientation = player?.orientation ?? .up

        // 線が変わったときだけ画像を作り直す
        if let ink, ink.version != lastInkVersion {
            lastInkVersion = ink.version
            if let image = rasterizer.image(for: ink, size: writer.size) {
                inkImage = CIImage(cgImage: image)
            } else {
                inkImage = nil
            }
        }
        let inkFrame = inkImage

        writer.queue.async {
            writer.appendFrame(video: pixelBuffer, orientation: orientation, ink: inkFrame, time: time)
        }

        tickCount += 1
        if tickCount % 3 == 0, let mic {
            micLevel = mic.currentLevel
        }
        let seconds = Int(CACurrentMediaTime() - startedAt)
        if seconds != elapsed { elapsed = seconds }
    }

    // MARK: - オーディオ設定

    /// AirPods などで聞きながら、声は iPad 本体のマイクで録る。
    /// （AirPods のマイクを使うと通話モードになり、聞こえる音質が大きく下がるため）
    private func configureAudioSessionForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)
        if let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtInMic)
        }
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
