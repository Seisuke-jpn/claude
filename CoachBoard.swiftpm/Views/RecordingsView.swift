import SwiftUI
import AVKit

/// 録画一覧（再生・写真に保存・共有／ファイルに保存・削除）
struct RecordingsView: View {
    @ObservedObject var store: RecordingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if store.items.isEmpty {
                    Text("まだ録画がありません")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.items) { item in
                    NavigationLink {
                        RecordingDetailView(item: item)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                            Text("\(item.date.formatted(date: .abbreviated, time: .shortened))・\(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            store.delete(item)
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("録画一覧")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

struct RecordingDetailView: View {
    let item: RecordingsStore.Item
    @State private var player: AVPlayer?
    @State private var isSaving = false
    @State private var message: String?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                Color.black
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    Label("写真に保存", systemImage: "square.and.arrow.down")
                }
                .disabled(isSaving)

                ShareLink(item: item.url) {
                    Label("共有・ファイルに保存", systemImage: "square.and.arrow.up")
                }
            }
        }
        .onAppear {
            if player == nil { player = AVPlayer(url: item.url) }
        }
        .onDisappear { player?.pause() }
        .alert("お知らせ", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await RecordingsStore.saveToPhotos(item.url)
            message = "写真ライブラリに保存しました。"
        } catch {
            message = "保存できませんでした：\(error.localizedDescription)"
        }
    }
}
