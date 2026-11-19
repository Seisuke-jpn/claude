import AVFoundation
import QuartzCore

enum MicError: LocalizedError {
    case unavailable
    var errorDescription: String? { "マイクが見つかりません。" }
}

/// マイクの声だけを別ファイル（CAF）に録音する。
/// 各音声ブロックの録音時刻と音量も記録しておき、
/// 書き出し時に「動画との位置合わせ」「話している間だけゲーム音を下げる」「話していない間はマイクを下げる」に使う。
final class MicRecorder: @unchecked Sendable {
    struct LevelSample {
        /// ホストクロックの秒（録画のフレーム時刻と同じ時計）
        let time: Double
        /// 音量（dBFS）
        let db: Float
    }

    struct Result {
        let url: URL
        /// 録音ファイル先頭のホストクロック秒
        let startHostSeconds: Double
        let levels: [LevelSample]
    }

    let url: URL
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var firstHostSeconds: Double?
    private var levels: [LevelSample] = []
    private var lastDB: Float = -160
    private(set) var voiceProcessingActive = false

    // 低い雑音（エアコン・机の振動など）を落とすハイパスフィルタの状態
    private var hpPrevInput: [Float] = []
    private var hpPrevOutput: [Float] = []
    private var hpAlpha: Float = 1

    init(url: URL) {
        self.url = url
    }

    /// 直近の音量（0〜1）。録画中のメーター表示用。
    var currentLevel: Float {
        lock.lock(); defer { lock.unlock() }
        return max(0, min(1, (lastDB + 60) / 60))
    }

    /// - Parameter noiseReduction: iPad の音声処理（雑音抑制）を使う
    func start(noiseReduction: Bool) throws {
        let input = engine.inputNode
        if noiseReduction {
            do {
                try input.setVoiceProcessingEnabled(true)
                // 音声処理を使うと他の音（動画の音）が小さくされるので、それを最小にする
                var ducking = AVAudioVoiceProcessingOtherAudioDuckingConfiguration()
                ducking.enableAdvancedDucking = false
                ducking.duckingLevel = .min
                input.voiceProcessingOtherAudioDuckingConfiguration = ducking
                voiceProcessingActive = true
            } catch {
                voiceProcessingActive = false
            }
        }
        // 音声処理は出力側も使うので、出力までの経路を用意しておく
        _ = engine.mainMixerNode

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicError.unavailable }

        let channels = Int(format.channelCount)
        hpPrevInput = Array(repeating: 0, count: channels)
        hpPrevOutput = Array(repeating: 0, count: channels)
        let cutoff: Float = 80 // Hz
        let rc = 1 / (2 * Float.pi * cutoff)
        let dt = 1 / Float(format.sampleRate)
        hpAlpha = rc / (rc + dt)

        try? FileManager.default.removeItem(at: url)
        file = try AVAudioFile(forWriting: url, settings: format.settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            self?.handle(buffer, time: time)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            file = nil
            if voiceProcessingActive { try? input.setVoiceProcessingEnabled(false) }
            throw error
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let hostSeconds = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : CACurrentMediaTime()
        lock.lock()
        highPass(buffer)
        let db = Self.rmsDB(buffer)
        if firstHostSeconds == nil { firstHostSeconds = hostSeconds }
        try? file?.write(from: buffer)
        levels.append(LevelSample(time: hostSeconds, db: db))
        lastDB = db
        lock.unlock()
    }

    private func highPass(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData, !buffer.format.isInterleaved else { return }
        let count = Int(buffer.frameLength)
        let channels = min(Int(buffer.format.channelCount), hpPrevInput.count)
        for c in 0..<channels {
            let samples = data[c]
            var prevIn = hpPrevInput[c]
            var prevOut = hpPrevOutput[c]
            for i in 0..<count {
                let x = samples[i]
                let y = hpAlpha * (prevOut + x - prevIn)
                samples[i] = y
                prevIn = x
                prevOut = y
            }
            hpPrevInput[c] = prevIn
            hpPrevOutput[c] = prevOut
        }
    }

    func stop() -> Result? {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if voiceProcessingActive {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
        }
        lock.lock(); defer { lock.unlock() }
        file = nil // ここでファイルが閉じられる
        guard let start = firstHostSeconds else { return nil }
        return Result(url: url, startHostSeconds: start, levels: levels)
    }

    private static func rmsDB(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return -160 }
        let count = Int(buffer.frameLength)
        let samples = channels[0]
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let rms = (sum / Float(count)).squareRoot()
        return 20 * log10(max(rms, 1e-8))
    }
}
