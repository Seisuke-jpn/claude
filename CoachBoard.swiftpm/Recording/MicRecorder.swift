import AVFoundation
import QuartzCore

enum MicError: LocalizedError {
    case unavailable
    var errorDescription: String? { "マイクが見つかりません。" }
}

/// マイクの声を録音する。
///
/// マイクの切り替えやノイズ除去の開始で iPad の音声経路が変わると、AVAudioEngine は自動で止まってしまう。
/// その通知を受けたら作り直して録音を続ける（経路が変わるたびに別ファイル＝区間として保存）。
/// また、ノイズ除去（音声処理）を使うと音が来ない機種・組み合わせがあるため、
/// 2 秒たっても音が来なければノイズ除去なしに自動で切り替える。
final class MicRecorder: @unchecked Sendable {
    struct LevelSample {
        /// ホストクロックの秒（録画のフレーム時刻と同じ時計）
        let time: Double
        /// 音量（dBFS）
        let db: Float
    }

    /// 1 つの録音ファイル（音声経路が変わるまでの区間）
    struct Segment {
        let url: URL
        /// ファイル先頭のホストクロック秒
        let startHostSeconds: Double
    }

    struct Result {
        let segments: [Segment]
        let levels: [LevelSample]

        func removeFiles() {
            for segment in segments { try? FileManager.default.removeItem(at: segment.url) }
        }
    }

    private let directory: URL
    private let engine = AVAudioEngine()
    /// 入力を「音を出さずに」エンジンにつないでおくためのミキサー（つながっていないと音が来ない場合がある）
    private let sink = AVAudioMixerNode()
    private let queue = DispatchQueue(label: "CoachBoard.MicRecorder")
    private var observer: NSObjectProtocol?

    // queue 上でのみ触る
    private var running = false
    private var wantsVoiceProcessing = false
    private var pendingRestart: DispatchWorkItem?

    // lock で守る（録音スレッドからも触る）
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var currentURL: URL?
    private var currentStart: Double?
    private var finished: [Segment] = []
    private var levels: [LevelSample] = []
    private var lastDB: Float = -160
    private var bufferCount = 0
    private var peakDB: Float = -160
    private var _voiceProcessingActive = false
    private var _fellBack = false
    private var _restartCount = 0
    private var hpPrevInput: [Float] = []
    private var hpPrevOutput: [Float] = []
    private var hpAlpha: Float = 1

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 直近の音量（0〜1）。メーター表示用。
    var currentLevel: Float {
        lock.lock(); defer { lock.unlock() }
        return max(0, min(1, (lastDB + 60) / 60))
    }

    /// 録音を始めてから音のデータが届いたか
    var isReceivingAudio: Bool {
        lock.lock(); defer { lock.unlock() }
        return bufferCount > 0 && peakDB > -100
    }

    var voiceProcessingActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return _voiceProcessingActive
    }

    /// 音声経路の変化で録音を作り直した回数（多いと音が途切れる原因になる）
    var restartCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _restartCount
    }

    /// ノイズ除去で音が来なかったため、ノイズ除去なしに切り替えた
    var fellBackFromVoiceProcessing: Bool {
        lock.lock(); defer { lock.unlock() }
        return _fellBack
    }

    func start(noiseReduction: Bool) throws {
        engine.attach(sink)
        try queue.sync {
            wantsVoiceProcessing = noiseReduction
            try startEngine()
        }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: nil) { [weak self] _ in
            self?.queue.async { self?.scheduleRestart() }
        }
        scheduleWatchdog()
    }

    func stop() -> Result? {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        return queue.sync {
            running = false
            pendingRestart?.cancel()
            pendingRestart = nil
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            if engine.inputNode.isVoiceProcessingEnabled {
                try? engine.inputNode.setVoiceProcessingEnabled(false)
            }
            lock.lock(); defer { lock.unlock() }
            closeCurrentSegment()
            guard !finished.isEmpty else { return nil }
            return Result(segments: finished, levels: levels)
        }
    }

    // MARK: - エンジンの開始・作り直し（queue 上）

    private func startEngine() throws {
        let input = engine.inputNode

        if wantsVoiceProcessing, !input.isVoiceProcessingEnabled {
            do {
                try input.setVoiceProcessingEnabled(true)
            } catch {
                wantsVoiceProcessing = false
            }
        } else if !wantsVoiceProcessing, input.isVoiceProcessingEnabled {
            try? input.setVoiceProcessingEnabled(false)
        }
        if input.isVoiceProcessingEnabled {
            // 音声処理を使うと他の音（動画の音）が小さくされるので、それを最小にする
            var ducking = AVAudioVoiceProcessingOtherAudioDuckingConfiguration()
            ducking.enableAdvancedDucking = false
            ducking.duckingLevel = .min
            input.voiceProcessingOtherAudioDuckingConfiguration = ducking
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicError.unavailable }

        // 入力 → 無音のミキサー → 出力 とつないで、エンジンが入力を確実に読み込むようにする
        engine.disconnectNodeOutput(input)
        engine.connect(input, to: sink, format: format)
        engine.connect(sink, to: engine.mainMixerNode, format: nil)
        sink.outputVolume = 0

        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        let newFile = try AVAudioFile(forWriting: url, settings: format.settings,
                                      commonFormat: format.commonFormat, interleaved: format.isInterleaved)

        let cutoff: Float = 80 // Hz：これより低い音（空調・振動）をカット
        let rc = 1 / (2 * Float.pi * cutoff)
        let dt = 1 / Float(format.sampleRate)

        lock.lock()
        closeCurrentSegment()
        file = newFile
        currentURL = url
        currentStart = nil
        hpPrevInput = Array(repeating: 0, count: Int(format.channelCount))
        hpPrevOutput = Array(repeating: 0, count: Int(format.channelCount))
        hpAlpha = rc / (rc + dt)
        _voiceProcessingActive = input.isVoiceProcessingEnabled
        lock.unlock()

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            self?.handle(buffer, time: time)
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    /// 経路の変化は短い間に何度も続くことがあるので、落ち着くまで待ってから1回だけ作り直す
    private func scheduleRestart() {
        guard running else { return }
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.handleConfigurationChange() }
        pendingRestart = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func handleConfigurationChange() {
        guard running else { return }
        pendingRestart = nil
        lock.lock()
        _restartCount += 1
        lock.unlock()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try startEngine()
        } catch {
            running = false
        }
    }

    private func scheduleWatchdog() {
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.running else { return }
            guard !self.isReceivingAudio, self.engine.inputNode.isVoiceProcessingEnabled else { return }
            // ノイズ除去を使うと音が来なかった → ノイズ除去なしでやり直す
            self.lock.lock()
            self._fellBack = true
            self.lock.unlock()
            self.wantsVoiceProcessing = false
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            do {
                try self.startEngine()
            } catch {
                self.running = false
            }
        }
    }

    /// 現在のファイルを区間として確定する（lock 内で呼ぶ）
    private func closeCurrentSegment() {
        file = nil // ここでファイルが閉じられる
        if let url = currentURL {
            if let start = currentStart {
                finished.append(Segment(url: url, startHostSeconds: start))
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        currentURL = nil
        currentStart = nil
    }

    // MARK: - 録音データの処理（録音スレッド）

    private func handle(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let hostSeconds = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : CACurrentMediaTime()
        lock.lock()
        defer { lock.unlock() }
        guard let file else { return }
        highPass(buffer)
        let db = Self.rmsDB(buffer)
        if currentStart == nil { currentStart = hostSeconds }
        try? file.write(from: buffer)
        levels.append(LevelSample(time: hostSeconds, db: db))
        lastDB = db
        bufferCount += 1
        peakDB = max(peakDB, db)
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
