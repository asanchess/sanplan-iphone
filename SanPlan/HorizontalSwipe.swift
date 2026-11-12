import SwiftUI
import UIKit

/// A sideways swipe on a row inside a ScrollView that never takes vertical drags away from scrolling.
///
/// A SwiftUI `DragGesture` attached to scroll content (even with `simultaneousGesture`) stops the
/// ScrollView from scrolling when the finger lands on that row (iOS 18+). This pan recognizer only
/// begins when the movement is mostly horizontal, so an up/down drag stays with the ScrollView.
/// Used by money operations, workout history and habit rows.
struct HorizontalSwipe: UIGestureRecognizerRepresentable {
    /// Horizontal translation in points since the swipe began (negative: to the left).
    var onChanged: (CGFloat) -> Void
    /// Final translation and the translation the swipe's speed points to; (0, 0) when cancelled.
    var onEnded: (_ translation: CGFloat, _ predicted: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed:
            onChanged(translation)
        case .ended:
            let velocity = recognizer.velocity(in: recognizer.view).x
            onEnded(translation, translation + velocity * 0.2)
        case .cancelled, .failed:
            onEnded(0, 0)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.2
        }
    }
}
