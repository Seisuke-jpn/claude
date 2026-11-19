import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var player = PlayerController()
    @StateObject private var ink = InkModel()
    @StateObject private var recorder = SessionRecorder()
    @StateObject private var recordings = RecordingsStore()
    @Environment(\.scenePhase) private var scenePhase

    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var showRecordings = false
    @State private var isLoadingVideo = false
    @State private var alertMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 0) {
                board
                ToolPalette(ink: ink)
            }
            transportBar
        }
        .background(Color.black.ignoresSafeArea())
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .videos)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.movie]) { result in
            switch result {
            case .success(let url):
                Task { await importFromFiles(url) }
            case .failure(let error):
                alertMessage = "ファイルを開けませんでした：\(error.localizedDescription)"
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task { await importFromPhotos(item) }
        }
        .onChange(of: scenePhase) { _, phase in
            // アプリが裏に回ったら録画を確定させる
            if phase == .background, recorder.isRecording {
                Task { await stopRecording(showList: false) }
            }
        }
        .onReceive(player.$errorMessage.compactMap { $0 }) { message in
            alertMessage = message
            player.errorMessage = nil
        }
        .onReceive(recorder.$errorMessage.compactMap { $0 }) { message in
            alertMessage = message
            recorder.errorMessage = nil
        }
        .alert("お知らせ", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .sheet(isPresented: $showRecordings) {
            RecordingsView(store: recordings)
        }
        .overlay {
            if isLoadingVideo {
                ProgressView("動画を読み込み中…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    // MARK: - 上のバー

    private var topBar: some View {
        HStack(spacing: 12) {
            Menu {
                Button { showPhotoPicker = true } label: {
                    Label("写真ライブラリから", systemImage: "photo.on.rectangle")
                }
                Button { showFileImporter = true } label: {
                    Label("ファイルから", systemImage: "folder")
                }
            } label: {
                Label("動画を開く", systemImage: "film")
            }
            .disabled(recorder.isRecording || recorder.isBusy)

            Spacer()

            if recorder.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 10, height: 10)
                    Text("録画中 \(Self.clock(recorder.elapsed))")
                        .monospacedDigit()
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            Button {
                Task { await toggleRecording() }
            } label: {
                Label(recorder.isRecording ? "録画停止" : "録画開始",
                      systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(recorder.isRecording ? .gray : .red)
            .disabled(recorder.isBusy)

            Button {
                recordings.reload()
                showRecordings = true
            } label: {
                Label("録画一覧", systemImage: "rectangle.stack")
            }
            .disabled(recorder.isRecording)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    // MARK: - ボード（動画＋手描き）

    private var board: some View {
        GeometryReader { geo in
            let rect = AVMakeRect(aspectRatio: player.presentationSize,
                                  insideRect: CGRect(origin: .zero, size: geo.size))
            ZStack {
                ZStack {
                    if player.hasVideo {
                        PlayerSurface(player: player.player)
                    } else {
                        Color(white: 0.12)
                        if ink.isEmpty {
                            Text("動画を開くか、このままメモを書けます（録画にも残ります）")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    InkCanvas(model: ink, allowFinger: ink.allowFinger)
                }
                .frame(width: rect.width, height: rect.height)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: - 下の再生バー

    private var transportBar: some View {
        HStack(spacing: 16) {
            Button { player.step(-1) } label: {
                Image(systemName: "backward.frame.fill")
            }
            Button { togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title)
                    .frame(width: 44)
            }
            Button { player.step(1) } label: {
                Image(systemName: "forward.frame.fill")
            }

            Text(Self.clock(Int(player.currentTime)))
                .monospacedDigit()
                .frame(minWidth: 48)

            Slider(
                value: Binding(get: { player.currentTime }, set: { player.scrub(to: $0) }),
                in: 0...max(player.duration, 0.01),
                onEditingChanged: { editing in player.isScrubbing = editing }
            )

            Text(Self.clock(Int(player.duration)))
                .monospacedDigit()
                .frame(minWidth: 48)

            Menu {
                ForEach([0.25, 0.5, 1.0, 1.5, 2.0], id: \.self) { value in
                    Button(String(format: "%g倍", value)) { player.setRate(Float(value)) }
                }
            } label: {
                Text(String(format: "%g倍", Double(player.rate)))
                    .monospacedDigit()
                    .frame(minWidth: 52)
            }
        }
        .font(.title3)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .disabled(!player.hasVideo)
    }

    // MARK: - 操作

    private func togglePlay() {
        if !player.isPlaying, ink.clearOnPlay {
            ink.clear()
        }
        player.togglePlay()
    }

    private func toggleRecording() async {
        if recorder.isRecording {
            await stopRecording(showList: true)
        } else {
            await recorder.start(player: player, ink: ink, url: recordings.makeNewURL())
        }
    }

    private func stopRecording(showList: Bool) async {
        if await recorder.stop() != nil {
            recordings.reload()
            if showList { showRecordings = true }
        }
    }

    private func importFromPhotos(_ item: PhotosPickerItem) async {
        isLoadingVideo = true
        defer { isLoadingVideo = false }
        do {
            guard let movie = try await item.loadTransferable(type: MovieFile.self) else {
                alertMessage = "動画を取り出せませんでした。"
                return
            }
            await player.load(url: movie.url)
            ImportedVideos.removeAll(except: movie.url)
        } catch {
            alertMessage = "動画を取り出せませんでした：\(error.localizedDescription)"
        }
    }

    private func importFromFiles(_ url: URL) async {
        isLoadingVideo = true
        defer { isLoadingVideo = false }
        do {
            let local = try await Task.detached { try ImportedVideos.copyIn(url) }.value
            await player.load(url: local)
            ImportedVideos.removeAll(except: local)
        } catch {
            alertMessage = "ファイルを読み込めませんでした：\(error.localizedDescription)"
        }
    }

    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
