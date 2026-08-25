import AppKit

/// A view whose origin is the top-left.
///
/// AppKit measures from the bottom-left, so a stack view used directly
/// as a scroll view's document view lays its rows out from the bottom —
/// a short list then appears halfway down an otherwise empty window,
/// which reads as a layout accident rather than as a short list.
/// `NSStackView` cannot be flipped itself, so it goes inside one of
/// these.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
