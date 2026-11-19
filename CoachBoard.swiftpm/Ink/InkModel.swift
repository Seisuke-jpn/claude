import UIKit
import PencilKit

/// 描画中の線（録画用）。座標は「ボード（動画の表示領域）」に対する 0〜1 の正規化座標。
struct InkStroke {
    var points: [CGPoint]
    var color: UIColor
    /// ボードの横幅に対する線の太さの割合
    var width: CGFloat
}

/// 手描きの線を管理するモデル。
/// 画面上の描画は Apple 純正の PencilKit（メモアプリと同じエンジン）が担当し、
/// 確定した線は PKDrawing として保持する。
/// PencilKit は「描いている途中の線」を外に出さないので、録画用に途中の線だけ別途追いかける。
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
    /// ボード横幅に対する太さの割合
    static let widths: [CGFloat] = [0.003, 0.006, 0.012]

    @Published var colorIndex = 0
    @Published var widthLevel = 1
    @Published var allowFinger = false
    @Published var clearOnPlay = true
    @Published private(set) var canUndo = false
    @Published private(set) var isEmpty = true
    /// 直近の書き始めで、ペンが触れてからアプリに届くまでにかかった時間（ミリ秒）
    @Published var lastTouchDelayMs: Int?

    /// 確定済みの線（canvasSize の座標系）
    private(set) var drawing = PKDrawing()
    private(set) var canvasSize: CGSize = .zero
    /// 描いている途中の線（録画用）
    private(set) var liveStroke: InkStroke?
    /// 描画内容が変わるたびに増える（途中の線も含む）
    private(set) var version = 0
    /// 確定済みの線が変わるたびに増える
    private(set) var committedVersion = 0

    private var undoStack: [PKDrawing] = []
    private let maxUndo = 100
    private var liveID = 0

    /// 画面の PKCanvasView に線を反映するためのフック（戻す・全消去など）
    var applyDrawing: ((PKDrawing) -> Void)?

    var color: UIColor { Self.palette[colorIndex] }

    func toolWidth(forCanvasWidth width: CGFloat) -> CGFloat {
        let range = PKInkingTool.InkType.monoline.validWidthRange
        let w = Self.widths[widthLevel] * width
        return min(max(w, range.lowerBound), range.upperBound)
    }

    /// 太さが一定のペン（録画用の途中線と見た目を揃えるため monoline を使う）
    var currentTool: PKInkingTool {
        PKInkingTool(.monoline, color: color, width: toolWidth(forCanvasWidth: max(canvasSize.width, 1)))
    }

    // MARK: - PencilKit からの通知

    func canvasDidChange(_ newDrawing: PKDrawing) {
        guard newDrawing != drawing else { return }
        pushUndo()
        drawing = newDrawing
        liveStroke = nil
        committedChanged()
    }

    func updateCanvasSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != canvasSize else { return }
        if canvasSize.width > 0 {
            // 画面回転などでボードの大きさが変わったら線も同じ比率で拡大縮小する
            let s = size.width / canvasSize.width
            let transform = CGAffineTransform(scaleX: s, y: s)
            canvasSize = size
            drawing = drawing.transformed(using: transform)
            undoStack = undoStack.map { $0.transformed(using: transform) }
            applyDrawing?(drawing)
            committedChanged()
        } else {
            canvasSize = size
        }
    }

    // MARK: - 録画用：描いている途中の線

    func liveBegin(at point: CGPoint) {
        liveID += 1
        liveStroke = InkStroke(points: [normalized(point)], color: color,
                               width: toolWidth(forCanvasWidth: max(canvasSize.width, 1)) / max(canvasSize.width, 1))
        bump()
    }

    func liveAppend(_ point: CGPoint) {
        guard liveStroke != nil else { return }
        let p = normalized(point)
        if let last = liveStroke?.points.last, last == p { return }
        liveStroke?.points.append(p)
        bump()
    }

    /// ペンを離した。PencilKit が線を確定するまでは途中の線を出したままにする。
    func liveEnd() {
        let id = liveID
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, self.liveID == id, self.liveStroke != nil else { return }
            self.liveStroke = nil
            self.bump()
        }
    }

    // MARK: - 操作

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        set(previous)
    }

    func clear() {
        guard !drawing.strokes.isEmpty || liveStroke != nil else { return }
        pushUndo()
        set(PKDrawing())
    }

    private func set(_ newDrawing: PKDrawing) {
        drawing = newDrawing
        liveStroke = nil
        applyDrawing?(newDrawing)
        committedChanged()
    }

    private func normalized(_ p: CGPoint) -> CGPoint {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
        return CGPoint(x: p.x / canvasSize.width, y: p.y / canvasSize.height)
    }

    private func pushUndo() {
        undoStack.append(drawing)
        if undoStack.count > maxUndo { undoStack.removeFirst() }
    }

    private func committedChanged() {
        committedVersion += 1
        canUndo = !undoStack.isEmpty
        isEmpty = drawing.strokes.isEmpty
        bump()
    }

    private func bump() {
        version += 1
    }
}
