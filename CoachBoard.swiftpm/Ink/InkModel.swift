import UIKit

/// 1本の線。座標は「ボード（動画の表示領域）」に対する 0〜1 の正規化座標で持つ。
/// こうしておくと、画面サイズと録画サイズが違っても同じ位置に描ける。
struct InkStroke {
    var points: [CGPoint]
    var color: UIColor
    /// ボードの横幅に対する線の太さの割合
    var width: CGFloat
}

/// 手描きの線を管理するモデル。画面表示と録画の両方がここを参照する。
@MainActor
final class InkModel: ObservableObject {
    static let palette: [UIColor] = [
        UIColor(red: 1.00, green: 0.27, blue: 0.33, alpha: 1), // 赤
        UIColor(red: 1.00, green: 0.85, blue: 0.20, alpha: 1), // 黄
        UIColor(red: 0.20, green: 0.90, blue: 0.95, alpha: 1), // シアン
        UIColor(red: 0.35, green: 0.95, blue: 0.45, alpha: 1), // 緑
        UIColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1), // 白
        UIColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1)  // 黒
    ]
    static let widths: [CGFloat] = [0.003, 0.006, 0.012]

    @Published var colorIndex = 0
    @Published var widthLevel = 1
    @Published var allowFinger = false
    @Published var clearOnPlay = true
    @Published private(set) var canUndo = false
    @Published private(set) var isEmpty = true

    private(set) var strokes: [InkStroke] = []
    private(set) var current: InkStroke?
    /// 描画内容が変わるたびに増える（描画中の線も含む）
    private(set) var version = 0
    /// 確定済みの線が変わるたびに増える
    private(set) var committedVersion = 0

    private var undoStack: [[InkStroke]] = []
    private let maxUndo = 100

    /// 画面のビューが再描画するためのフック
    var onChange: (() -> Void)?

    var color: UIColor { Self.palette[colorIndex] }

    func begin(at point: CGPoint) {
        current = InkStroke(points: [point], color: color, width: Self.widths[widthLevel])
        bump()
    }

    func append(_ point: CGPoint) {
        guard current != nil else { return }
        if let last = current?.points.last, last == point { return }
        current?.points.append(point)
        bump()
    }

    func end() {
        guard let stroke = current else { return }
        current = nil
        pushUndo()
        strokes.append(stroke)
        committedChanged()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        current = nil
        strokes = previous
        committedChanged()
    }

    func clear() {
        guard !strokes.isEmpty || current != nil else { return }
        current = nil
        pushUndo()
        strokes = []
        committedChanged()
    }

    private func pushUndo() {
        undoStack.append(strokes)
        if undoStack.count > maxUndo { undoStack.removeFirst() }
    }

    private func committedChanged() {
        committedVersion += 1
        canUndo = !undoStack.isEmpty
        isEmpty = strokes.isEmpty
        bump()
    }

    private func bump() {
        version += 1
        onChange?()
    }
}
