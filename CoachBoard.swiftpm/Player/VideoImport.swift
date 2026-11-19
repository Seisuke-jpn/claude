import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// 読み込んだ動画は一時フォルダにコピーして使う
enum ImportedVideos {
    static var directory: URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportedVideos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func newDestination(ext: String) -> URL {
        directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext.isEmpty ? "mov" : ext)
    }

    /// ファイルアプリから選んだ動画をアプリ内にコピーする
    static func copyIn(_ source: URL) throws -> URL {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let destination = newDestination(ext: source.pathExtension)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// 使っていない古いコピーを消す
    static func removeAll(except keep: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.standardizedFileURL != keep.standardizedFileURL {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// 写真ライブラリ（PhotosPicker）から動画ファイルとして受け取るための型
struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let destination = ImportedVideos.newDestination(ext: received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return MovieFile(url: destination)
        }
    }
}
