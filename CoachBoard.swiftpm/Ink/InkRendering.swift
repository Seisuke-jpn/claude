import UIKit
import PencilKit

enum InkDrawing {
    /// 線を CGContext に描く。size はボードの実サイズ（ピクセル）。
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

/// 録画用に「確定済みの線（PencilKit）＋描いている途中の線」を1枚の画像にする
@MainActor
final class InkRasterizer {
    private var committedImage: UIImage?
    private var cacheVersion = -1
    private var cacheSize: CGSize = .zero

    private func makeFormat() -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        return format
    }

    private func committed(for model: InkModel, size: CGSize) -> UIImage? {
        guard !model.drawing.strokes.isEmpty, model.canvasSize.width > 0, size.width > 0 else { return nil }
        if let image = committedImage, cacheVersion == model.committedVersion, cacheSize == size {
            return image
        }
        let rect = CGRect(origin: .zero, size: model.canvasSize)
        let scale = size.width / model.canvasSize.width
        var image: UIImage?
        // ダークモードだと PencilKit が色を反転させるので、ライト扱いで書き出す
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = model.drawing.image(from: rect, scale: scale)
        }
        committedImage = image
        cacheVersion = model.committedVersion
        cacheSize = size
        return image
    }

    /// 何も描かれていなければ nil
    func image(for model: InkModel, size: CGSize) -> CGImage? {
        let base = committed(for: model, size: size)
        let live = model.liveStroke
        guard base != nil || live != nil, size.width > 0, size.height > 0 else { return nil }
        return UIGraphicsImageRenderer(size: size, format: makeFormat()).image { ctx in
            base?.draw(in: CGRect(origin: .zero, size: size))
            if let live {
                InkDrawing.draw(live, in: ctx.cgContext, size: size)
            }
        }.cgImage
    }
}
