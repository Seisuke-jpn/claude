import SwiftUI
import UIKit

/// Apple Pencil の入力を受け取って線を描くビュー
final class InkCanvasView: UIView, UIGestureRecognizerDelegate {
    private let model: InkModel
    private let rasterizer = InkRasterizer()
    private let strokeRecognizer = StrokeGestureRecognizer(target: nil, action: nil)

    var allowFinger: Bool {
        get { strokeRecognizer.allowFinger }
        set { strokeRecognizer.allowFinger = newValue }
    }

    init(model: InkModel) {
        self.model = model
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isMultipleTouchEnabled = true
        model.onChange = { [weak self] in self?.setNeedsDisplay() }

        strokeRecognizer.delegate = self
        strokeRecognizer.onBegin = { [weak self] point in
            guard let self else { return }
            self.model.begin(at: self.normalized(point))
        }
        strokeRecognizer.onAppend = { [weak self] point in
            guard let self else { return }
            self.model.append(self.normalized(point))
        }
        strokeRecognizer.onEnd = { [weak self] in
            self?.model.end()
        }
        addGestureRecognizer(strokeRecognizer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func normalized(_ p: CGPoint) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGPoint(x: p.x / bounds.width, y: p.y / bounds.height)
    }

    // 他のジェスチャーに線の入力を横取りされないようにする
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        rasterizer.committed(for: model, size: bounds.size)?.draw(in: bounds)
        if let current = model.current {
            InkDrawing.draw(current, in: ctx, size: bounds.size)
        }
    }
}

struct InkCanvas: UIViewRepresentable {
    let model: InkModel
    let allowFinger: Bool

    func makeUIView(context: Context) -> InkCanvasView {
        InkCanvasView(model: model)
    }

    func updateUIView(_ view: InkCanvasView, context: Context) {
        view.allowFinger = allowFinger
    }
}
