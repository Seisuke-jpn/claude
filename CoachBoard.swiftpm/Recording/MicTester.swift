import AVFoundation
import Foundation

/// 音声設定画面の「マイクをテスト」。録画せずに、選んだマイクの音が届くかを確認する。
@MainActor
final class MicTester: ObservableObject {
    @Published private(set) var isTesting = false
    @Published private(set) var level: Float = 0
    @Published private(set) var status = ""
    @Published private(set) var inputName: String?

    private var mic: MicRecorder?
    private var timer: Timer?
    private var startedAt = Date()

    func start() async {
        guard !isTesting else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            status = "マイクが許可されていません（設定アプリ → CoachBoard → マイク で許可できます）"
            return
        }
        do {
            let warning = try MicSettings.configureSessionForRecording()
            let recorder = MicRecorder(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("MicTest", isDirectory: true))
            try recorder.start(noiseReduction: MicSettings.noiseReduction)
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
        mic?.stop()?.removeFiles()
        mic = nil
        guard isTesting else { return }
        isTesting = false
        level = 0
        inputName = nil
        MicSettings.restorePlaybackSession()
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
        if mic.isReceivingAudio {
            if mic.voiceProcessingActive {
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
