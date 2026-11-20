import SwiftUI
import AVFoundation
import Combine

/// 音声設定：マイクの選択・雑音対策・書き出し時の音量バランス
struct AudioSettingsView: View {
    @AppStorage(NarrationMixSettings.Keys.gameVolume) private var gameVolume = 0.8
    @AppStorage(NarrationMixSettings.Keys.micVolume) private var micVolume = 1.0
    @AppStorage(NarrationMixSettings.Keys.ducking) private var ducking = true
    @AppStorage(MicSettings.Keys.input) private var micInput = MicSettings.builtInID
    @AppStorage(MicSettings.Keys.noiseReduction) private var noiseReduction = true
    @AppStorage(MicSettings.Keys.gate) private var micGate = true

    @StateObject private var catalog = MicInputCatalog()
    @StateObject private var tester = MicTester()

    private var routeChanges: AnyPublisher<Notification, Never> {
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .filter { note in
                // マイクの抜き差しのときだけ一覧を取り直す（一覧取得そのものが起こす通知は無視）
                guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return false }
                return reason == .newDeviceAvailable || reason == .oldDeviceUnavailable
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // MARK: マイク
                Text("マイク")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(catalog.options) { option in
                        Button {
                            micInput = option.id
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: micInput == option.id ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(micInput == option.id ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.name)
                                        .foregroundStyle(.primary)
                                    if let detail = option.detail {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Text("USB-C や Lightning のマイク、有線イヤホンのマイクはつなぐとここに出ます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // マイクのテスト（録画せずに音が届くか確認）
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Button {
                            if tester.isTesting {
                                tester.stop()
                            } else {
                                Task { await tester.start() }
                            }
                        } label: {
                            Label(tester.isTesting ? "テストを止める" : "マイクをテスト",
                                  systemImage: tester.isTesting ? "stop.circle" : "mic.badge.plus")
                        }
                        .buttonStyle(.bordered)
                        if tester.isTesting {
                            MicLevelMeter(level: tester.level)
                        }
                    }
                    if !tester.status.isEmpty {
                        Text(tester.status)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !tester.isTesting, tester.canPlayBack {
                        Button {
                            tester.playBack()
                        } label: {
                            Label(tester.isPlayingBack ? "再生中…" : "テスト録音を聞く", systemImage: "play.circle")
                        }
                        .buttonStyle(.bordered)
                        .disabled(tester.isPlayingBack)
                    }
                    if tester.isTesting, let name = tester.inputName {
                        Text("使用中のマイク：\(name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $noiseReduction) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ノイズ除去")
                        Text("周りの雑音を抑えます。録画中に出る「マイクモード」ボタンから「声を分離」を選ぶと、さらに強力になります。外部マイクで原音のまま録りたいときはオフ。Bluetooth マイクではイヤホン側の雑音処理を使うため、この設定は使いません。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle(isOn: $micGate) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("話していない間はマイクを下げる")
                        Text("話していない間の雑音（キーボード・空調など）を書き出し時に小さくします。声の出だしは切れません。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                // MARK: 音量バランス
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
        }
        .frame(width: 380, height: 560)
        .onAppear { catalog.refresh() }
        .onDisappear {
            tester.stop()
            tester.discardRecording()
        }
        .onChange(of: micInput) { _, _ in tester.restartIfTesting() }
        .onChange(of: noiseReduction) { _, _ in tester.restartIfTesting() }
        .onReceive(routeChanges) { _ in catalog.refresh() }
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
