import AppKit
import AtriumCore

/// The transport control: a green right-pointing triangle to start, a
/// red square to stop.
///
/// Play/stop rather than record-dot/stop. The two shapes differ in
/// outline as well as colour, so the state is readable at 16 pt, in
/// peripheral vision, and to anyone who cannot tell red from green —
/// which a red dot and a red square are not.
///
/// Drawn rather than an SF Symbol because `play.fill` and `stop.fill`
/// both turn to mush at this size.
final class TransportButton: NSButton {

    var isRecording = false {
        didSet { needsDisplay = true }
    }

    private var isHovered = false
    private var trackingAreaRef: NSTrackingArea?

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = isHovered ? 0 : 1.5
        let shape = bounds.insetBy(dx: inset, dy: inset)
        let colour = isRecording ? NSColor.systemRed : NSColor.systemGreen
        (isHovered ? colour : colour.withAlphaComponent(0.9)).setFill()

        if isRecording {
            NSBezierPath(roundedRect: shape, xRadius: 2, yRadius: 2).fill()
            return
        }

        // A right-pointing triangle, nudged right by an eighth of its
        // width: an equilateral triangle in a square box reads as
        // left-heavy because its visual centre sits behind its
        // geometric one.
        let nudge = shape.width / 8
        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: shape.minX + nudge, y: shape.minY))
        triangle.line(to: NSPoint(x: shape.maxX, y: shape.midY))
        triangle.line(to: NSPoint(x: shape.minX + nudge, y: shape.maxY))
        triangle.close()
        triangle.fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }
}

/// The grab handle: three dots down the far-left edge.
///
/// It does two jobs, and it exists because the panel has no title bar to
/// do either. Dragging it moves the window — the dots are the only
/// affordance saying the panel *can* be moved. Clicking it (or
/// right-clicking, or a two-finger tap) opens the app's whole menu, the
/// same list the status item carries, which matters when the panel is
/// sitting over a full-screen meeting and the menu bar is hidden.
final class PanelGrip: NSView {

    /// Supplies the menu to show. Built on demand rather than held,
    /// because almost every entry in it depends on what is happening
    /// right now.
    var onMenu: (() -> NSMenu?)?

    private var isHovered = false
    private var trackingAreaRef: NSTrackingArea?

    override func draw(_ dirtyRect: NSRect) {
        let dots = 3
        let diameter: CGFloat = 2.5
        let spacing: CGFloat = 4.5
        let total = diameter + spacing * CGFloat(dots - 1)
        let x = bounds.midX - diameter / 2
        var y = bounds.midY + total / 2 - diameter

        // Brighter under the pointer. The panel never takes focus, so
        // hover is the only feedback available to say this is a control
        // and not decoration.
        // A shadow under each dot, so they stay legible even if the
        // material behind them ends up light after all.
        NSColor(white: 0, alpha: 0.55).setFill()
        var shadowY = y - 1
        for _ in 0..<dots {
            NSBezierPath(
                ovalIn: NSRect(
                    x: x - 0.5, y: shadowY, width: diameter + 1, height: diameter + 1)
            ).fill()
            shadowY -= spacing
        }

        NSColor(white: 1, alpha: isHovered ? 1 : 0.8).setFill()
        for _ in 0..<dots {
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: diameter, height: diameter))
                .fill()
            y -= spacing
        }
    }

    // MARK: - Click or drag

    /// One handle, two gestures: press and move to drag, press and
    /// release without moving to open the menu.
    ///
    /// Both were asked for on the same three dots, and a handle that
    /// only drags hides the menu while one that only opens a menu cannot
    /// be moved. The threshold is what separates them — 3 pt, because a
    /// deliberate click still wobbles a pixel or two.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = event.locationInWindow

        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                showMenu(with: next)
                return
            }
            let moved = hypot(
                next.locationInWindow.x - start.x, next.locationInWindow.y - start.y)
            if moved > 3 {
                // `performDrag` runs its own event loop until the mouse
                // is released, so there is nothing to write after it.
                window.performDrag(with: next)
                return
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        showMenu(with: event)
    }

    private func showMenu(with event: NSEvent) {
        guard let menu = onMenu?() else { return }
        Log.write("panel: grip menu opened with \(menu.numberOfItems) item(s)")
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
            owner: self)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }
}

/// A very small always-on-top panel: one button, one histogram.
///
/// Four deliberate choices:
///
/// * **`.floating` window level** — it stays above the meeting window,
///   which is the only place it is useful.
/// * **`.nonactivatingPanel`** — clicking or dragging it must never pull
///   focus out of Zoom/Teams mid-sentence.
/// * **Visible while idle, not only while recording.** It carries the
///   start control now, so hiding it when there is nothing to stop would
///   hide the only way to begin. Hide it from the menu if it is in the
///   way; drag it anywhere.
/// * **No title, no clock.** Everything that is not the transport, the
///   audio or the grip lives in the menu.
///
/// It has no title bar, so `PanelGrip` — the three dots on the left —
/// supplies both of the things a title bar would: somewhere to drag
/// from, and a right-click menu. That menu is the only way to reach the
/// app or quit it while a full-screen meeting is hiding the menu bar.
///
/// The histogram consolidates both streams into one set of bars. See
/// `HistogramView` for what that costs and where the per-stream
/// diagnostic went instead.
final class RecordingPanel: NSPanel {

    private let histogram = HistogramView()
    private let button = TransportButton()
    private let grip = PanelGrip()

    /// The button was pressed. `onStart` when idle, `onStop` when live.
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?

    /// Supplies the menu the grip shows — the same one the status item
    /// and the **Capture** menu carry.
    var onMenu: (() -> NSMenu?)?

    private var isRecording = false
    /// Set once the panel has been given a position. After that, where
    /// it sits is the user's business.
    private var hasBeenPlaced = false

    /// Consecutive silent frames per stream, so the warning needs a
    /// sustained silence rather than one quiet buffer.
    private var micSilentFrames = 0
    private var farEndSilentFrames = 0
    private let silentFrameThreshold = 60  // ~2 s at 30 fps

    static let panelSize = NSSize(width: 76, height: 34)

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isFloatingPanel = true
        // Always dark, whatever the system is set to. `.hudWindow` is a
        // *light* material in light appearance, which left the grip's
        // white dots invisible against it — and the histogram draws a
        // near-black backing and near-white bars on the assumption of a
        // dark surround. Pinning the appearance makes both true at once
        // instead of true half the time.
        appearance = NSAppearance(named: .darkAqua)
        hidesOnDeactivate = false
        // Visible on every Space, and over full-screen meeting windows.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        // Dragging is the grip's job. Making the whole background a
        // drag handle meant a missed press on the transport button moved
        // the panel instead of starting a recording.
        isMovableByWindowBackground = false

        buildContent()

        // Survives a relaunch. Without it the panel returned to the
        // top-right corner on every `make run`, which is often enough to
        // be worth one line.
        setFrameAutosaveName("AtriumRecordingPanel")
        hasBeenPlaced = frame.origin != .zero
    }

    // Borderless panels refuse key status by default. Keep it that way:
    // the panel must never take focus from the meeting.
    override var canBecomeKey: Bool { false }

    // MARK: - Layout

    private func buildContent() {
        // Flat black, not a blur.
        //
        // `NSVisualEffectView` with `.hudWindow` sampled whatever was
        // behind it, so the panel's own darkness depended on the meeting
        // window under it — light against a slide deck, dark against a
        // video tile. Everything drawn on top assumes a dark surround:
        // white grip dots, near-white bars, a near-black histogram
        // backing. A fixed colour makes that assumption true instead of
        // usually true.
        let container = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.cornerRadius = 8
        container.layer?.masksToBounds = true

        grip.frame = NSRect(x: 2, y: 5, width: 12, height: 24)
        grip.onMenu = { [weak self] in self?.onMenu?() }
        grip.toolTip = "Click for the menu · drag to move"
        container.addSubview(grip)

        button.frame = NSRect(x: 17, y: 9, width: 16, height: 16)
        button.isBordered = false
        button.title = ""
        button.target = self
        button.action = #selector(transportTapped)
        button.toolTip = "Start recording"
        container.addSubview(button)

        histogram.frame = NSRect(x: 37, y: 6, width: 31, height: 22)
        container.addSubview(histogram)

        contentView = container
    }

    /// Put it top-right, but only when there is nowhere better.
    ///
    /// "Nowhere better" means two things, and neither of them is "the
    /// panel is being shown again". Moving it on every `show()` meant
    /// pressing record threw the panel back to the corner it had just
    /// been dragged out of — the one gesture guaranteed to happen while
    /// somebody is looking at it.
    ///
    /// So: place it the first time, and place it again if where it sits
    /// is no longer on any screen. The second case is real — docking a
    /// laptop, or unplugging a display, otherwise leaves the panel at
    /// coordinates nothing can show.
    ///
    /// `NSScreen.main` is nil before the application object exists,
    /// which is why none of this can happen in `init`.
    private func positionIfNeeded() {
        if hasBeenPlaced && isOnAScreen { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(
            NSPoint(
                x: visible.maxX - Self.panelSize.width - 16,
                y: visible.maxY - Self.panelSize.height - 16))
        hasBeenPlaced = true
    }

    /// Whether enough of the panel is visible to grab. A sliver poking
    /// past the edge is not somewhere it can be dragged back from.
    private var isOnAScreen: Bool {
        NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(frame)
            return overlap.width >= 24 && overlap.height >= 16
        }
    }

    // MARK: - Visibility

    func show() {
        positionIfNeeded()
        orderFrontRegardless()
        Log.write(
            "panel shown visible=\(isVisible) frame=\(NSStringFromRect(frame)) "
                + "screens=\(NSScreen.screens.count)")
    }

    func hide() {
        orderOut(nil)
    }

    // MARK: - State

    @objc private func transportTapped() {
        if isRecording {
            onStop?()
        } else {
            onStart?()
        }
    }

    func beginRecording() {
        isRecording = true
        button.isRecording = true
        button.toolTip = "Stop recording and keep what has been captured"
        micSilentFrames = 0
        farEndSilentFrames = 0
        histogram.isSilent = false
        show()
    }

    func endRecording() {
        isRecording = false
        button.isRecording = false
        button.toolTip = "Start recording"
        histogram.levels = []
        histogram.isSilent = false
    }

    /// Push new meter data.
    ///
    /// The two streams are consolidated into one bar per band, taking
    /// whichever is louder: the panel answers "is this recording", and
    /// for that question a single tall bar that moves when *anybody*
    /// speaks beats two short ones. Which stream is which is answered by
    /// the log line and the menu, not here — see `HistogramView`.
    func update(
        micLevels: [Float], micPeak: Float, farEndLevels: [Float], farEndPeak: Float
    ) {
        let bands = max(micLevels.count, farEndLevels.count)
        var combined = [Float](repeating: 0, count: bands)
        for index in 0..<bands {
            let mic = index < micLevels.count ? micLevels[index] : 0
            let farEnd = index < farEndLevels.count ? farEndLevels[index] : 0
            combined[index] = max(mic, farEnd)
        }
        histogram.levels = combined

        micSilentFrames = micPeak > 0 ? 0 : micSilentFrames + 1
        farEndSilentFrames = farEndPeak > 0 ? 0 : farEndSilentFrames + 1

        // Red only when *neither* stream is producing anything. A quiet
        // room is not a fault; a recording with no audio arriving at all
        // is. Warn only while recording, too — an idle panel is silent by
        // definition and a red bar there would train you to ignore it.
        histogram.isSilent =
            isRecording && micSilentFrames > silentFrameThreshold
            && farEndSilentFrames > silentFrameThreshold
    }
}
