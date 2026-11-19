import AVFoundation
import CoreImage
import ImageIO

enum RecorderError: LocalizedError {
    case setupFailed
    case noFrames

    var errorDescription: String? {
        switch self {
        case .setupFailed: return "録画の準備に失敗しました。"
        case .noFrames: return "録画時間が短すぎたため保存できませんでした。"
        }
    }
}

/// 合成したフレームを mp4（映像のみ）に書き込む。音は録画停止後に NarrationMixer で重ねる。
/// すべての処理は `queue` 上で行う（メインスレッドを止めないため）。
final class MovieWriter: @unchecked Sendable {
    let queue = DispatchQueue(label: "CoachBoard.MovieWriter", qos: .userInitiated)
    let url: URL
    let size: CGSize

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let background = CIColor(red: 0.12, green: 0.12, blue: 0.13)

    // 以下は queue 上でのみ触る
    private var sessionStarted = false
    private var finished = false
    private var startTime: CMTime = .zero
    private var lastVideoTime: CMTime?

    init(url: URL, size: CGSize) throws {
        self.url = url
        self.size = size
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let width = Int(size.width), height = Int(size.height)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60
            ] as [String: Any]
        ])
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ])
        guard writer.canAdd(videoInput) else { throw RecorderError.setupFailed }
        writer.add(videoInput)

    }

    func start() throws {
        guard writer.startWriting() else { throw writer.error ?? RecorderError.setupFailed }
    }

    /// 1フレーム書き込む。video が nil なら無地のボード（雑談メモ用）。
    func appendFrame(video: CVPixelBuffer?, orientation: CGImagePropertyOrientation, ink: CIImage?, time: CMTime) {
        guard !finished, writer.status == .writing else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: time)
            startTime = time
            sessionStarted = true
        }
        if let last = lastVideoTime, time <= last { return }
        // エンコーダが追いつかないときはこのフレームを捨てる（録画自体は続く）
        guard videoInput.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }

        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let output = buffer else { return }

        let rect = CGRect(origin: .zero, size: size)
        var image = CIImage(color: background).cropped(to: rect)

        if let video {
            var frame = CIImage(cvPixelBuffer: video).oriented(orientation)
            let extent = frame.extent
            if extent.width > 0, extent.height > 0 {
                let scale = min(size.width / extent.width, size.height / extent.height)
                let w = extent.width * scale, h = extent.height * scale
                frame = frame
                    .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .transformed(by: CGAffineTransform(translationX: (size.width - w) / 2, y: (size.height - h) / 2))
                image = frame.composited(over: image)
            }
        }
        if let ink {
            image = ink.composited(over: image)
        }

        ciContext.render(image, to: output, bounds: rect, colorSpace: colorSpace)
        if adaptor.append(output, withPresentationTime: time) {
            lastVideoTime = time
        }
    }

    func finish() async -> Result<URL, Error> {
        await withCheckedContinuation { continuation in
            queue.async {
                self.finished = true
                guard self.sessionStarted, self.lastVideoTime != nil else {
                    self.writer.cancelWriting()
                    try? FileManager.default.removeItem(at: self.url)
                    continuation.resume(returning: .failure(RecorderError.noFrames))
                    return
                }
                self.videoInput.markAsFinished()
                self.writer.finishWriting {
                    if self.writer.status == .completed {
                        continuation.resume(returning: .success(self.url))
                    } else {
                        continuation.resume(returning: .failure(self.writer.error ?? RecorderError.setupFailed))
                    }
                }
            }
        }
    }
}
