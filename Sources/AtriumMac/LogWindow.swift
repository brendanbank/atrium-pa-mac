import AppKit
import AtriumCore

/// One recording's own lines, pulled out of a log that interleaves all
/// of them.
///
/// `~/Library/Logs/AtriumMac.log` is the only account of what happened
/// to a recording — an app launched through LaunchServices has no
/// stderr, which is why the log exists at all. But it is chronological
/// and everything is in it, so answering "what happened to *that* one?"
/// meant reading the whole file. This filters it to the handles one
/// recording is known by.
final class LogWindow: NSWindow {

    private let text = NSTextView()
    private let heading = NSTextField(labelWithString: "")

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        title = "Recording Log"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 480, height: 240)
        buildContent()
    }

    /// Show every line mentioning any of `keys`.
    func present(title recordingTitle: String, keys: [String]) {
        let lines = Log.entries(matching: keys)
        heading.stringValue =
            lines.isEmpty
            ? "No log lines mention this recording."
            : "\(lines.count) line(s) — matched on \(keys.joined(separator: ", "))"
        text.string =
            lines.isEmpty
            // Not an error. The log is trimmed on launch, and a
            // recording old enough can genuinely have nothing left in
            // it — which is worth saying rather than showing an empty
            // box that looks like a failure to load.
            ? "Nothing in \(Log.fileURL.lastPathComponent) mentions "
                + "\(keys.joined(separator: " or ")).\n\n"
                + "The log is trimmed on launch, so an older recording may have "
                + "scrolled out of it."
            : lines.joined(separator: "\n")

        self.title = "Log — \(recordingTitle)"
        center()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Newest at the bottom, which is where the interesting part of a
        // failure usually is.
        text.scrollToEndOfDocument(nil)
    }

    private func buildContent() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 420))

        heading.frame = NSRect(x: 16, y: 386, width: 728, height: 18)
        heading.font = .systemFont(ofSize: 11)
        heading.textColor = .secondaryLabelColor
        heading.lineBreakMode = .byTruncatingTail
        heading.autoresizingMask = [.width, .minYMargin]
        view.addSubview(heading)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 46, width: 760, height: 334))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        text.isEditable = false
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.autoresizingMask = [.width]
        text.textContainerInset = NSSize(width: 6, height: 6)
        // Wrapping off: a log line is a record, and rewrapping it makes
        // the timestamps stop lining up, which is most of what makes a
        // log readable at a glance.
        text.isHorizontallyResizable = true
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        scroll.hasHorizontalScroller = true
        scroll.documentView = text
        view.addSubview(scroll)

        let copy = NSButton(frame: NSRect(x: 16, y: 10, width: 120, height: 28))
        copy.title = "Copy All"
        copy.bezelStyle = .rounded
        copy.target = self
        copy.action = #selector(copyAll)
        copy.autoresizingMask = [.maxXMargin]
        view.addSubview(copy)

        let openFull = NSButton(frame: NSRect(x: 144, y: 10, width: 150, height: 28))
        openFull.title = "Open Full Log"
        openFull.bezelStyle = .rounded
        openFull.target = self
        openFull.action = #selector(openFullLog)
        openFull.autoresizingMask = [.maxXMargin]
        view.addSubview(openFull)

        contentView = view
    }

    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.string, forType: .string)
    }

    @objc private func openFullLog() {
        NSWorkspace.shared.open(Log.fileURL)
    }
}
