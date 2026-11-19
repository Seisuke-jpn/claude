import Foundation
import Photos

/// アプリ内に保存した録画ファイルの一覧
@MainActor
final class RecordingsStore: ObservableObject {
    struct Item: Identifiable, Hashable {
        let url: URL
        let date: Date
        let byteCount: Int64
        var id: URL { url }
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    enum SaveError: LocalizedError {
        case denied
        var errorDescription: String? {
            "写真ライブラリへのアクセスが許可されていません。設定アプリ → CoachBoard → 写真 で許可してください。"
        }
    }

    @Published private(set) var items: [Item] = []

    static var directory: URL {
        let dir = URL.documentsDirectory.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        reload()
    }

    func makeNewURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return Self.directory.appendingPathComponent("Rec_\(formatter.string(from: Date()))").appendingPathExtension("mp4")
    }

    func reload() {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: keys)) ?? []
        items = urls
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return Item(url: url,
                            date: values?.creationDate ?? .distantPast,
                            byteCount: Int64(values?.fileSize ?? 0))
            }
            .sorted { $0.date > $1.date }
    }

    func delete(_ item: Item) {
        try? FileManager.default.removeItem(at: item.url)
        reload()
    }

    static func saveToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
        }
    }
}
