import SwiftUI

/// 書き出し時の音量バランス設定
struct AudioSettingsView: View {
    @AppStorage(NarrationMixSettings.Keys.gameVolume) private var gameVolume = 0.8
    @AppStorage(NarrationMixSettings.Keys.micVolume) private var micVolume = 1.0
    @AppStorage(NarrationMixSettings.Keys.ducking) private var ducking = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("録画の音量バランス")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Label("動画（ゲーム）の音：\(Int(gameVolume * 100))%", systemImage: "gamecontroller")
                Slider(value: $gameVolume, in: 0...1)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("マイク（声）：\(Int(micVolume * 100))%", systemImage: "mic")
                Slider(value: $micVolume, in: 0...1)
            }

            Toggle(isOn: $ducking) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("話している間はゲーム音を下げる")
                    Text("声が聞き取りやすくなります（ラジオやゲーム実況と同じ手法）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("動画の音は、録画停止後に元の動画ファイルから取り出して、再生・停止・スローのタイミング通りに重ねます。イヤホンで聞いていても録画に入ります。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// 録画中のマイク音量メーター（声が拾えているかの確認用）
struct MicLevelMeter: View {
    let level: Float

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "mic.fill")
                .font(.caption)
                .foregroundStyle(level > 0.05 ? Color.green : Color.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    Capsule()
                        .fill(Color.green)
                        .frame(width: geo.size.width * CGFloat(level))
                }
            }
            .frame(width: 60, height: 6)
        }
        .animation(.linear(duration: 0.1), value: level)
    }
}
