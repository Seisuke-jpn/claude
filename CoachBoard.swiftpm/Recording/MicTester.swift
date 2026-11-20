import AVFoundation
import Foundation

/// 音声設定画面の「マイクをテスト」。録画せずに、選んだマイクの音が届くかを確認する。
@MainActor
final class MicTester: ObservableObject {
    @Published private(set) var isTesting = false
    @Published private(set) var level: Float = 0
    @Published private(set) var status = ""
    @Published private(set) var inputName: String?
    /// テストで録った音を聞き直せるか
    @Published private(set) var canPlayBack = false
    @Published private(set) var isPlayingBack = false

    private var mic: MicRecorder?
    private var timer: Timer?
    private var startedAt = Date()
    private var lastResult: MicRecorder.Result?
    private var player: AVAudioPlayer?
    private var playbackTimer: Timer?

    func start() async {
        guard !isTesting else { return }
        discardRecording()
        guard await AVAudioApplication.requestRecordPermission() else {
            status = "マイクが許可されていません（設定アプリ → CoachBoard → マイク で許可できます）"
            return
        }
        do {
            let warning = try await MicSettings.configureSessionForRecording()
            let recorder = MicRecorder(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("MicTest", isDirectory: true))
            try recorder.start(noiseReduction: MicSettings.effectiveNoiseReduction)
            mic = recorder
            isTesting = true
            startedAt = Date()
            status = warning ?? "話しかけてください…"
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        } catch {
            status = "マイクを開始できませんでした：\(error.localizedDescription)"
            MicSettings.restorePlaybackSession()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let mic {
            lastResult = mic.stop()
            canPlayBack = lastResult != nil
        }
        mic = nil
        guard isTesting else { return }
        isTesting = false
        level = 0
        inputName = nil
        MicSettings.restorePlaybackSession()
    }

    /// テストで録った音を再生する（いちばん長い区間）
    func playBack() {
        guard let segment = lastResult?.segments.max(by: { duration(of: $0) < duration(of: $1) }) else { return }
        do {
            MicSettings.restorePlaybackSession()
            let newPlayer = try AVAudioPlayer(contentsOf: segment.url)
            newPlayer.play()
            player = newPlayer
            isPlayingBack = true
            playbackTimer?.invalidate()
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let player = self.player else { return }
                    if !player.isPlaying {
                        self.isPlayingBack = false
                        self.playbackTimer?.invalidate()
                        self.playbackTimer = nil
                    }
                }
            }
        } catch {
            status = "テスト録音を再生できませんでした：\(error.localizedDescription)"
        }
    }

    /// 画面を閉じるときなどに、テスト録音を消す
    func discardRecording() {
        player?.stop()
        player = nil
        playbackTimer?.invalidate()
        playbackTimer = nil
        isPlayingBack = false
        lastResult?.removeFiles()
        lastResult = nil
        canPlayBack = false
    }

    private func duration(of segment: MicRecorder.Segment) -> Double {
        let size = (try? segment.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Double(size)
    }

    /// 設定を変えたときにテストをやり直す
    func restartIfTesting() {
        guard isTesting else { return }
        stop()
        Task { await start() }
    }

    private func update() {
        guard let mic else { return }
        level = mic.currentLevel
        inputName = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName
        let restarts = mic.restartCount
        let restartNote = restarts > 1 ? "（音声経路の切り替え \(restarts) 回：途切れの原因になります）" : ""
        if mic.isReceivingAudio {
            if !restartNote.isEmpty {
                status = "音が届いています" + restartNote
            } else if MicSettings.selectedInput == MicSettings.bluetoothID {
                status = "音が届いています（Bluetooth マイクはイヤホン側の雑音処理を使います）"
            } else if mic.voiceProcessingActive {
                status = "音が届いています（ノイズ除去オン）"
            } else if mic.fellBackFromVoiceProcessing {
                status = "音が届いています（このマイクではノイズ除去が使えなかったため、ノイズ除去なし）"
            } else {
                status = "音が届いています"
            }
        } else if Date().timeIntervalSince(startedAt) > 4 {
            status = "音が届いていません。別のマイクを選ぶか、ノイズ除去をオフにして試してください。"
        }
    }
}
