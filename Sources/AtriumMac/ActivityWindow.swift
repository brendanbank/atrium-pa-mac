import AppKit
import AtriumCore
import Foundation

/// The window that answers "what has this thing been doing?".
///
/// Until now the app was a status item and two floating panels, and the
/// only record of a meeting was a capped in-memory list in a menu nobody
/// opens. That is fine for something you never think about and wrong for
/// something that records your conversations and uploads them: when a
/// meeting does not arrive, the question is *which* meeting, *when*, and
/// *what happened to it* — and a menu that holds ten lines until the next
/// launch cannot answer any of the three.
///
/// So: one row per recording, oldest habits of the queue made visible —
/// what it is, where it got to, and who was in it.
///
/// ## Who is speaking, and what is missing from it
///
/// The Speakers column shows the voices *this app* named, plus a count of
/// the ones nobody has. It does not show the full roster the server may
/// have identified on its own, because reading that back needs the
/// `pa.read` scope — which would also let this token read the user's mail
/// and calendar. A recorder does not need that, so it does not ask for
/// it, and the column says what it knows first-hand rather than
/// pretending to omniscience.
final class ActivityWindow: NSWindow {

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let accountLabel = NSTextField(labelWithString: "")
    private var accountButton = NSButton()
    private var startAtLogin = NSButton()
    private var nameButton = NSButton()
    private var openButton = NSButton()
    private var retryButton = NSButton()

    private var items: [QueueItem] = []

    /// What the last log line said, so an unchanged window stays quiet.
    private var lastLoggedSummary = ""
    private var refreshTimer: Timer?

    /// Hooks back to the delegate, which owns the queue and the client.
    var onReload: ((@escaping ([QueueItem]) -> Void) -> Void)?
    var onNameVoices: ((QueueItem) -> Void)?
    /// Open this recording's page in Atrium PA. Addressed by capture
    /// id, not transcript id — see `AppDelegate.openInAtriumPA`.
    var onOpenInAtriumPA: ((Int) -> Void)?
    var onRetry: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onShowLog: ((QueueItem) -> Void)?
    var onSaveTranscript: ((QueueItem) -> Void)?
    var onDelete: ((QueueItem) -> Void)?
    var onLogIn: (() -> Void)?
    var onLogOut: (() -> Void)?
    /// Who we are signed in as, in words, plus whether we are signed in
    /// at all — the button below reads "Log out" or "Log in…" from the
    /// same answer, so they cannot disagree.
    var onAccountStatus: (() -> (description: String, signedIn: Bool))?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        title = "Atrium PA Capture"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 560, height: 260)
        buildContent()
    }

    func present() {
        center()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        reload()
        // The panel taught this lesson once already: a window that does
        // not appear is indistinguishable from one that was never asked
        // to, unless it says so itself.
        Log.write(
            "activity: shown visible=\(isVisible) frame=\(NSStringFromRect(frame))")

        // While the window is up, keep it current: an upload moves
        // through pending → transcribing → ready on its own, and a row
        // that stays stale is a row that gets refreshed by quitting.
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) {
            [weak self] _ in
            guard let self, self.isVisible else { return }
            self.reload()
        }
    }

    override func close() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        super.close()
    }

    func reload() {
        onReload? { [weak self] items in
            guard let self else { return }
            // Hold the selection across the refresh. The window reloads
            // itself every five seconds so an upload's progress shows
            // without being asked for, and `reloadData()` drops the
            // selection — so a row selected and then thought about for
            // a moment deselected itself under the pointer.
            let selectedID = self.selected?.id
            self.items = items
            self.table.reloadData()
            if let selectedID,
                let row = items.firstIndex(where: { $0.id == selectedID })
            {
                self.table.selectRowIndexes([row], byExtendingSelection: false)
            }
            self.emptyLabel.isHidden = !items.isEmpty
            self.updateAccount()
            self.updateButtons()
            // Only when it changes. This reloads every five seconds
            // while the window is open, and logging each pass made 87%
            // of the log file one repeated sentence — burying the
            // uploads, the state changes and the failures it exists to
            // record.
            let summary =
                "\(items.count) recording(s) — "
                + "\(self.accountLabel.stringValue.lowercased()), "
                + "start at login \(LoginItem.statusDescription)"
            if summary != self.lastLoggedSummary {
                self.lastLoggedSummary = summary
                Log.write("activity: \(summary)")
            }
        }
    }

    private var selected: QueueItem? {
        let row = table.selectedRow
        return items.indices.contains(row) ? items[row] : nil
    }

    private func updateButtons() {
        let item = selected
        openButton.isEnabled = item?.captureID != nil
        // Enabled on any uploaded recording, not only one with a cached
        // unnamed voice: pressing it re-asks the server, which is the
        // only way to find a voice that appeared after the transcript
        // landed. See `UploadQueue.refreshSpeakers`.
        nameButton.isEnabled = item?.captureID != nil
        nameButton.title =
            (item?.provisionalSpeakers.isEmpty == false && item?.nameableSpeakers.isEmpty == true)
            ? "Confirm voices…" : "Name voices…"
        retryButton.isEnabled = item?.state == .failed
    }

    /// The account strip, refreshed from the delegate rather than
    /// cached: signing in happens in a browser, and the answer can
    /// change while this window is open.
    private func updateAccount() {
        guard let status = onAccountStatus?() else { return }
        accountLabel.stringValue = status.description
        accountButton.title = status.signedIn ? "Log out" : "Log in…"
        accountButton.action =
            status.signedIn ? #selector(logOut) : #selector(logIn)
        startAtLogin.state = LoginItem.isEnabled ? .on : .off
    }

    // MARK: - The row menu

    private func rowMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [
            ("Name Voices…", #selector(nameVoices)),
            ("Open in Atrium PA", #selector(openInAtriumPA)),
            ("Save Transcript to Downloads", #selector(saveTranscript)),
            ("Show Log Entries…", #selector(showLog)),
            ("Show Audio in Finder", #selector(revealAudio)),
            ("Copy Capture ID", #selector(copyCaptureID)),
            ("Retry Upload", #selector(retry)),
            ("Delete Recording…", #selector(deleteRecording)),
        ] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        menu.delegate = self
        return menu
    }

    /// Show the audio file itself, not the folder.
    ///
    /// `activateFileViewerSelecting` opens Finder with the file
    /// highlighted; opening the folder would leave somebody hunting
    /// through a directory named by timestamp.
    @objc private func revealAudio() {
        guard let item = selected else { return }
        let audio = item.audioURL
        guard FileManager.default.fileExists(atPath: audio.path) else {
            ConnectionSheet.report(
                title: "The audio is gone",
                message: "\(item.audioFile) is no longer on disk. Retention "
                    + "removes uploaded recordings on the schedule set in "
                    + "Settings › Recordings.",
                success: false)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([audio])
    }

    @objc private func saveTranscript() {
        guard let item = selected else { return }
        onSaveTranscript?(item)
    }

    @objc private func showLog() {
        guard let item = selected else { return }
        onShowLog?(item)
    }

    @objc private func deleteRecording() {
        guard let item = selected else { return }
        onDelete?(item)
    }

    @objc private func copyCaptureID() {
        guard let id = selected?.captureID else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(id), forType: .string)
    }

    // MARK: - Actions

    @objc private func logIn() {
        onLogIn?()
    }

    @objc private func logOut() {
        onLogOut?()
    }

    @objc private func toggleStartAtLogin() {
        let wanted = startAtLogin.state == .on
        if !LoginItem.setEnabled(wanted) {
            // Registration can succeed and still be parked behind a
            // switch in System Settings. Put the checkbox back where
            // macOS actually is rather than where the click left it.
            startAtLogin.state = LoginItem.isEnabled ? .on : .off
            accountLabel.stringValue =
                "Start at login: \(LoginItem.statusDescription)"
        }
    }

    @objc private func nameVoices() {
        guard let item = selected else { return }
        onNameVoices?(item)
    }

    @objc private func openInAtriumPA() {
        guard let id = selected?.captureID else { return }
        onOpenInAtriumPA?(id)
    }

    /// Ask the server for the current state of every recording.
    ///
    /// The queue polls on its own schedule and stops once an item is
    /// finished, so this is the answer to "the web says something
    /// different" — which is a question that has been asked.
    @objc private func refreshNow() {
        Log.write("activity: refresh requested")
        onRefresh?()
        // The work is asynchronous; show what arrives when it arrives.
        for delay in [1.0, 3.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.reload()
            }
        }
    }

    @objc private func retry() {
        onRetry?()
        // The queue works asynchronously; give it a moment before asking
        // what changed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.reload()
        }
    }

    @objc private func revealRecordings() {
        try? AppPaths.ensureDirectories()
        NSWorkspace.shared.open(AppPaths.recordings)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Layout

    private func buildContent() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 420))
        view.autoresizingMask = [.width, .height]

        for (title, width, identifier) in [
            ("When", CGFloat(140), "when"),
            ("Meeting", CGFloat(200), "meeting"),
            ("Status", CGFloat(140), "status"),
            ("Speakers", CGFloat(200), "speakers"),
        ] {
            let column = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.rowSizeStyle = .default
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openInAtriumPA)
        // Right-click acts on the row under the pointer, which is not
        // necessarily the selected one — `menu(for:)` below selects it
        // first so the menu and the buttons cannot disagree about what
        // they are about to act on.
        table.menu = rowMenu()

        accountLabel.frame = NSRect(x: 16, y: 386, width: 460, height: 18)
        accountLabel.lineBreakMode = .byTruncatingMiddle
        accountLabel.textColor = .secondaryLabelColor
        // Fixed width, pinned left. Growing with the window would slide
        // it back under the right-anchored controls.
        accountLabel.autoresizingMask = [.maxXMargin, .minYMargin]
        view.addSubview(accountLabel)

        startAtLogin.setButtonType(.switch)
        startAtLogin.title = "Start at login"
        startAtLogin.toolTip =
            "Launch Atrium PA Capture when you log in, so it is already "
            + "running when the meeting starts"
        startAtLogin.target = self
        startAtLogin.action = #selector(toggleStartAtLogin)
        startAtLogin.sizeToFit()
        // Sized to its own title and anchored to the Log out button.
        // Given a wide frame and a right-aligned title, AppKit draws the
        // tick box at the left edge of that frame — which put it in the
        // middle of the account line, looking like a checkbox belonging
        // to the text it was sitting on.
        startAtLogin.setFrameOrigin(
            NSPoint(x: 720 - 16 - 92 - 12 - startAtLogin.frame.width, y: 382))
        startAtLogin.autoresizingMask = [.minXMargin, .minYMargin]
        view.addSubview(startAtLogin)

        accountButton.frame = NSRect(x: 720 - 16 - 92, y: 380, width: 92, height: 28)
        accountButton.bezelStyle = .rounded
        accountButton.title = "Log in…"
        accountButton.target = self
        accountButton.action = #selector(logIn)
        accountButton.autoresizingMask = [.minXMargin, .minYMargin]
        view.addSubview(accountButton)

        scroll.frame = NSRect(x: 0, y: 52, width: 720, height: 322)
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        view.addSubview(scroll)

        emptyLabel.stringValue =
            "No recordings yet. Press the green triangle to record, or join a "
            + "meeting in an app on the allowlist."
        emptyLabel.frame = NSRect(x: 24, y: 180, width: 672, height: 20)
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        view.addSubview(emptyLabel)

        var x: CGFloat = 16
        func button(_ title: String, _ action: Selector, width: CGFloat) -> NSButton {
            let button = NSButton(frame: NSRect(x: x, y: 12, width: width, height: 30))
            button.title = title
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.autoresizingMask = [.maxXMargin]
            x += width + 8
            view.addSubview(button)
            return button
        }

        _ = button("Refresh", #selector(refreshNow), width: 90)
        nameButton = button("Name voices…", #selector(nameVoices), width: 130)
        openButton = button("Open in Atrium PA", #selector(openInAtriumPA), width: 150)
        retryButton = button("Retry", #selector(retry), width: 70)
        _ = button("Recordings…", #selector(revealRecordings), width: 120)

        let quitButton = NSButton(
            frame: NSRect(x: 720 - 16 - 80, y: 12, width: 80, height: 30))
        quitButton.title = "Quit"
        quitButton.bezelStyle = .rounded
        quitButton.target = self
        quitButton.action = #selector(quit)
        quitButton.autoresizingMask = [.minXMargin]
        view.addSubview(quitButton)

        contentView = view
    }
}

// MARK: - The row menu

extension ActivityWindow: NSMenuDelegate {

    /// Select the row that was right-clicked before the menu opens.
    ///
    /// AppKit's `clickedRow` survives only for the duration of the
    /// event, and every action here reads `selected`. Without this,
    /// right-clicking a row while another is selected acted on the
    /// selected one — which is the kind of thing that names the wrong
    /// person's voice.
    func menuWillOpen(_ menu: NSMenu) {
        let clicked = table.clickedRow
        if items.indices.contains(clicked) {
            table.selectRowIndexes([clicked], byExtendingSelection: false)
        }
        let item = selected
        for entry in menu.items {
            switch entry.title {
            case "Name Voices…": entry.isEnabled = item?.captureID != nil
            case "Open in Atrium PA": entry.isEnabled = item?.captureID != nil
            case "Save Transcript to Downloads":
                entry.isEnabled = item?.transcriptID != nil
            case "Show Log Entries…": entry.isEnabled = item != nil
            case "Show Audio in Finder": entry.isEnabled = item != nil
            case "Copy Capture ID": entry.isEnabled = item?.captureID != nil
            case "Retry Upload": entry.isEnabled = item?.state == .failed
            case "Delete Recording…": entry.isEnabled = item != nil
            default: break
            }
        }
    }
}

// MARK: - Table

extension ActivityWindow: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard items.indices.contains(row), let identifier = tableColumn?.identifier
        else { return nil }
        let item = items[row]

        let text: String
        var colour: NSColor = .labelColor
        switch identifier.rawValue {
        case "when":
            let formatter = DateFormatter()
            formatter.dateFormat = "d MMM HH:mm"
            text = formatter.string(from: item.occurredAt)
        case "meeting":
            text = item.title ?? "Recording"
        case "status":
            text = item.statusDescription
            switch item.state {
            case .failed: colour = .systemRed
            case .ready: colour = .systemGreen
            default: colour = .secondaryLabelColor
            }
        default:
            text = item.speakerDescription
            if item.openSpeakerQuestions > 0 { colour = .systemOrange }
        }

        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        field.textColor = colour
        field.font = .systemFont(ofSize: 12)
        // A failure is worth the whole sentence, and the column is never
        // wide enough for it.
        if identifier.rawValue == "status", let error = item.lastError {
            field.toolTip = error
        }
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }
}
