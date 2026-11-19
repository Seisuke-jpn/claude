import SwiftUI
import UIKit
import PencilKit

/// 画面上の手描き。描画そのものは PencilKit（メモアプリと同じエンジン）に任せる。
/// 書き始め・書き終わりの補正や Pencil の遅延対策は PencilKit 側で行われる。
final class InkBoardView: UIView, PKCanvasViewDelegate, UIGestureRecognizerDelegate, UIScribbleInteractionDelegate {
    private let model: InkModel
    private let canvas = PKCanvasView()
    /// 録画用に「描いている途中の線」を追いかけるだけの認識（描画はしない）
    private let liveRecognizer = StrokeGestureRecognizer(target: nil, action: nil)
    private var isApplying = false

    init(model: InkModel) {
        self.model = model
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false

        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.contentInsetAdjustmentBehavior = .never
        // アプリはダークモードなので、色が反転しないよう描画面だけライト扱いにする
        canvas.overrideUserInterfaceStyle = .light
        canvas.drawingPolicy = .pencilOnly
        canvas.delegate = self
        canvas.drawing = model.drawing
        addSubview(canvas)

        liveRecognizer.delegate = self
        liveRecognizer.onBegin = { [weak self] point in self?.model.liveBegin(at: point) }
        liveRecognizer.onAppend = { [weak self] point in self?.model.liveAppend(point) }
        liveRecognizer.onEnd = { [weak self] in self?.model.liveEnd() }
        liveRecognizer.onTouchDelay = { [weak self] ms in self?.model.lastTouchDelayMs = ms }
        canvas.addGestureRecognizer(liveRecognizer)

        // 描画面では「スクリブル（手書き文字入力）」を起動させない。
        // スクリブルが手書きかどうか判定している間、書き始めのペン入力が保留されることがあるため。
        let scribble = UIScribbleInteraction(delegate: self)
        addInteraction(scribble)
        canvas.addInteraction(UIScribbleInteraction(delegate: self))

        model.applyDrawing = { [weak self] drawing in
            guard let self else { return }
            self.isApplying = true
            self.canvas.drawing = drawing
            self.isApplying = false
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        model.updateCanvasSize(bounds.size)
        canvas.tool = model.currentTool
    }

    func configure(allowFinger: Bool) {
        canvas.drawingPolicy = allowFinger ? .anyInput : .pencilOnly
        liveRecognizer.allowFinger = allowFinger
        canvas.tool = model.currentTool
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isApplying else { return }
        model.canvasDidChange(canvasView.drawing)
    }

    func scribbleInteraction(_ interaction: UIScribbleInteraction, shouldBeginAt location: CGPoint) -> Bool {
        false
    }

    // PencilKit の描画と同時に、録画用の追跡も動かす
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

struct InkCanvas: UIViewRepresentable {
    let model: InkModel
    let allowFinger: Bool
    // 色・太さが変わったときに updateUIView を呼ばせるために受け取る
    let colorIndex: Int
    let widthLevel: Int

    func makeUIView(context: Context) -> InkBoardView {
        InkBoardView(model: model)
    }

    func updateUIView(_ view: InkBoardView, context: Context) {
        view.configure(allowFinger: allowFinger)
    }
}
