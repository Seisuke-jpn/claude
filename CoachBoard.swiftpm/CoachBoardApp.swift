import SwiftUI
import AVFoundation

@main
struct CoachBoardApp: App {
    init() {
        // マナーモードでも動画の音が出るように再生用のオーディオ設定にしておく
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
