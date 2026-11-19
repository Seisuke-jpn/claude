import SwiftUI
import UIKit

/// Apple Pencil の入力を受け取って線を描くビュー
final class InkCanvasView: UIView {
    private let model: InkModel
    private let rasterizer = InkRasterizer()
    private weak var activeTouch: UITouch?
    var allowFinger = false

    init(model: InkModel) {
        self.model = model
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isMultipleTouchEnabled = true
        model.onChange = { [weak self] in self?.setNeedsDisplay() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func normalized(_ p: CGPoint) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGPoint(x: p.x / bounds.width, y: p.y / bounds.height)
    }

    private func canDraw(with touch: UITouch) -> Bool {
        touch.type == .pencil || (allowFinger && touch.type == .direct)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first(where: { canDraw(with: $0) }) else { return }
        activeTouch = touch
        model.begin(at: normalized(touch.location(in: self)))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        // Pencil は画面の更新より細かく入力が来るので、まとめて取り出す
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        for sample in samples {
            model.append(normalized(sample.location(in: self)))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        model.append(normalized(touch.location(in: self)))
        model.end()
        activeTouch = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        model.end()
        activeTouch = nil
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
