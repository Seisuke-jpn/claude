import AVFoundation
import Combine
import ImageIO
import QuartzCore

/// 動画の再生・停止・シークと、録画用のフレーム取り出しを担当する
@MainActor
final class PlayerController: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var hasVideo = false
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published var currentTime: Double = 0
    @Published private(set) var rate: Float = 1
    /// 動画の表示サイズ（回転を考慮済み）。動画が無いときは 16:9 のボード。
    @Published private(set) var presentationSize = CGSize(width: 1920, height: 1080)
    @Published var errorMessage: String?

    var isScrubbing = false
    private(set) var orientation: CGImagePropertyOrientation = .up

    private var videoOutput: AVPlayerItemVideoOutput?
    private var lastPixelBuffer: CVPixelBuffer?
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var isSeeking = false
    private var pendingSeek: Double?

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing, !self.isSeeking, self.pendingSeek == nil else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
            }
        }
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.isPlaying = (status != .paused)
            }
            .store(in: &cancellables)
    }

    // MARK: - 読み込み

    func load(url: URL) async {
        pause()
        let asset = AVURLAsset(url: url)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                errorMessage = "この動画には映像が含まれていません。"
                return
            }
            let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
            let assetDuration = try await asset.load(.duration)

            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            let item = AVPlayerItem(asset: asset)
            item.add(output)
            player.replaceCurrentItem(with: item)

            videoOutput = output
            lastPixelBuffer = nil
            orientation = Self.orientation(for: transform)
            let rotated = naturalSize.applying(transform)
            let size = CGSize(width: abs(rotated.width), height: abs(rotated.height))
            presentationSize = (size.width > 0 && size.height > 0) ? size : CGSize(width: 1920, height: 1080)
            duration = assetDuration.seconds.isFinite ? assetDuration.seconds : 0
            currentTime = 0
            hasVideo = true
        } catch {
            errorMessage = "動画を読み込めませんでした：\(error.localizedDescription)"
        }
    }

    // MARK: - 操作

    func togglePlay() {
        guard hasVideo else { return }
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard hasVideo else { return }
        if duration > 0, currentTime >= duration - 0.05 {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = 0
        }
        player.playImmediately(atRate: rate)
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        if isPlaying { player.rate = newRate }
    }

    /// 1コマ送り / 戻し
    func step(_ count: Int) {
        guard let item = player.currentItem else { return }
        pause()
        item.step(byCount: count)
    }

    /// スライダー操作。シーク中に次の要求が来たら、終わってから最新の位置へ飛ぶ。
    func scrub(to seconds: Double) {
        currentTime = seconds
        pendingSeek = seconds
        if !isSeeking { performSeek() }
    }

    private func performSeek() {
        guard let target = pendingSeek else { return }
        pendingSeek = nil
        isSeeking = true
        let time = CMTime(seconds: target, preferredTimescale: 600)
        Task {
            _ = await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            isSeeking = false
            performSeek()
        }
    }

    /// 停止中に録画を始めたとき、最初のフレームを確実に取り出せるよう現在位置を読み直す
    func refreshCurrentFrame() {
        guard hasVideo, !isPlaying else { return }
        scrub(to: currentTime)
    }

    // MARK: - 録画用

    /// いま画面に出ているフレーム。停止中は最後のフレームをそのまま返す。
    func currentPixelBuffer() -> CVPixelBuffer? {
        guard hasVideo, let output = videoOutput else { return nil }
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: itemTime),
           let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
            lastPixelBuffer = buffer
        } else if lastPixelBuffer == nil,
                  let buffer = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) {
            lastPixelBuffer = buffer
        }
        return lastPixelBuffer
    }

    private static func orientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
        let degrees = Int((atan2(t.b, t.a) * 180 / .pi).rounded())
        switch degrees {
        case 90: return .right
        case -90: return .left
        case 180, -180: return .down
        default: return .up
        }
    }
}
