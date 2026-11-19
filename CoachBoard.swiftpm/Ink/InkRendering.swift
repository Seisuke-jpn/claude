import UIKit

enum InkDrawing {
    /// 線を CGContext に描く。size はボードの実サイズ（ポイントまたはピクセル）。
    static func draw(_ stroke: InkStroke, in ctx: CGContext, size: CGSize) {
        let pts = stroke.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        guard let first = pts.first else { return }
        let lineWidth = max(1, stroke.width * size.width)

        ctx.saveGState()
        ctx.setStrokeColor(stroke.color.cgColor)
        ctx.setFillColor(stroke.color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        if pts.count == 1 {
            ctx.fillEllipse(in: CGRect(x: first.x - lineWidth / 2, y: first.y - lineWidth / 2,
                                       width: lineWidth, height: lineWidth))
        } else {
            let path = CGMutablePath()
            path.move(to: first)
            if pts.count == 2 {
                path.addLine(to: pts[1])
            } else {
                // 中点を通る二次曲線でなめらかにする
                for i in 1..<(pts.count - 1) {
                    let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
                    path.addQuadCurve(to: mid, control: pts[i])
                }
                path.addLine(to: pts[pts.count - 1])
            }
            ctx.addPath(path)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }
}

/// 線を画像化する。確定済みの線はキャッシュしておき、描画中の線だけを毎回重ねる。
@MainActor
final class InkRasterizer {
    private let scale: CGFloat?
    private var committedImage: UIImage?
    private var cacheVersion = -1
    private var cacheSize: CGSize = .zero

    /// scale が nil なら画面の解像度、1 ならピクセル等倍（録画用）
    init(scale: CGFloat? = nil) {
        self.scale = scale
    }

    private func makeFormat() -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat.preferred()
        if let scale { format.scale = scale }
        format.opaque = false
        format.preferredRange = .standard
        return format
    }

    func committed(for model: InkModel, size: CGSize) -> UIImage? {
        guard !model.strokes.isEmpty, size.width > 0, size.height > 0 else { return nil }
        if let image = committedImage, cacheVersion == model.committedVersion, cacheSize == size {
            return image
        }
        let strokes = model.strokes
        let image = UIGraphicsImageRenderer(size: size, format: makeFormat()).image { ctx in
            for stroke in strokes {
                InkDrawing.draw(stroke, in: ctx.cgContext, size: size)
            }
        }
        committedImage = image
        cacheVersion = model.committedVersion
        cacheSize = size
        return image
    }

    /// 確定済み＋描画中の線をまとめた画像。何も描かれていなければ nil。
    func full(for model: InkModel, size: CGSize) -> UIImage? {
        let base = committed(for: model, size: size)
        guard let current = model.current, size.width > 0, size.height > 0 else { return base }
        return UIGraphicsImageRenderer(size: size, format: makeFormat()).image { ctx in
            base?.draw(in: CGRect(origin: .zero, size: size))
            InkDrawing.draw(current, in: ctx.cgContext, size: size)
        }
    }
}
