import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Apple Pencil の線を取りこぼさずに受け取るための専用ジェスチャー認識。
///
/// ビューの touchesBegan で受け取る方式だと、iPadOS のシステムジェスチャー
/// （画面端のスワイプ判定など）がタッチの配信を少し遅らせることがあり、
/// その間にペンが動いた分＝書き始めの部分が欠けてしまう。
/// ジェスチャー認識はタッチを遅延なく最初に受け取れるので、Apple の描画アプリの
/// サンプルと同じくこの方式にしている。さらに「まとめて届いた細かい入力
/// （coalesced touches）」を書き始め・途中・書き終わりのすべてで拾う。
final class StrokeGestureRecognizer: UIGestureRecognizer {
    /// 座標はすべて view の座標系
    var onBegin: ((CGPoint) -> Void)?
    var onAppend: ((CGPoint) -> Void)?
    var onEnd: (() -> Void)?

    var allowFinger = false {
        didSet { updateAllowedTouchTypes() }
    }

    private weak var trackedTouch: UITouch?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
        updateAllowedTouchTypes()
    }

    private func updateAllowedTouchTypes() {
        var types = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        if allowFinger {
            types.append(NSNumber(value: UITouch.TouchType.direct.rawValue))
        }
        allowedTouchTypes = types
    }

    private func samples(of touch: UITouch, in event: UIEvent) -> [UITouch] {
        let coalesced = event.coalescedTouches(for: touch) ?? []
        return coalesced.isEmpty ? [touch] : coalesced
    }

    private func location(of touch: UITouch) -> CGPoint {
        touch.preciseLocation(in: view)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if trackedTouch == nil, let touch = touches.first {
            trackedTouch = touch
            let points = samples(of: touch, in: event).map(location(of:))
            onBegin?(points.first ?? location(of: touch))
            for point in points.dropFirst() { onAppend?(point) }
            state = .began
        }
        for touch in touches where touch !== trackedTouch {
            ignore(touch, for: event)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        for sample in samples(of: touch, in: event) {
            onAppend?(location(of: sample))
        }
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        for sample in samples(of: touch, in: event) {
            onAppend?(location(of: sample))
        }
        finishStroke()
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        // 途中でシステムに取り消されても、そこまで描いた線は残す
        finishStroke()
        state = .cancelled
    }

    override func reset() {
        finishStroke()
        super.reset()
    }

    private func finishStroke() {
        guard trackedTouch != nil else { return }
        trackedTouch = nil
        onEnd?()
    }
}
