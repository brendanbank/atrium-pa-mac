import AppKit
import AtriumCore
import UserNotifications

/// Everything configurable, in one window instead of scattered through
/// a menu.
///
/// `NSTabViewController` with `.toolbar`, which is the shape macOS
/// settings windows had for a decade and still the one AppKit gives you
/// without a nib. It resizes itself to each pane, so panes are laid out
/// at their natural height and the window follows.
///
/// Every control here writes through to `config.json` immediately. There
/// is no OK button: a settings window with an Apply step invites the
/// question "did that save?", and the answer should be visible instead.
final class SettingsWindow: NSWindowController {

    /// Hooks back to the delegate, which owns the config and the queue.
    struct Actions {
        var config: () -> AtriumConfig
        var save: (AtriumConfig) -> Void
        var logIn: () -> Void
        var logOut: () -> Void
        var testConnection: () -> Void
        var isSignedIn: () -> Bool
        var notificationStatus: () -> UNAuthorizationStatus
        var editAllowlist: () -> Void
        var reloadAllowlist: () -> Void
        var moveRecordings: (URL?) -> Void
    }

    private let actions: Actions
    private let tabs = SettingsTabs()

    init(actions: Actions) {
        self.actions = actions
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 300),
            // Resizable, because the explanations under each control
            // wrap and a wider window is a shorter one. The height
            // follows the tab that is showing.
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 240)
        super.init(window: window)

        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(
            pane(GeneralPane(actions: actions), "General", "gearshape"))
        tabs.addTabViewItem(
            pane(AccountPane(actions: actions), "Atrium PA", "person.crop.circle"))
        tabs.addTabViewItem(
            pane(StoragePane(actions: actions), "Recordings", "folder"))
        tabs.addTabViewItem(
            pane(PermissionsPane(actions: actions), "Permissions", "lock.shield"))
        window.contentViewController = tabs
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func pane(
        _ controller: NSViewController, _ title: String, _ symbol: String
    ) -> NSTabViewItem {
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    /// Open on a named tab. Used by `--settings <tab>`, which is how
    /// each pane gets exercised without a human clicking through them.
    func present(tab: String?) {
        present()
        // After showing, not before. Selecting a tab on a controller
        // whose view has not loaded does not stick — the window came up
        // on General whatever was asked for.
        guard let tab else { return }
        let index = tabs.tabViewItems.firstIndex {
            $0.label.lowercased() == tab.lowercased()
        }
        Log.write(
            "settings: asked for tab “\(tab)” — "
                + (index.map { "index \($0)" } ?? "no such tab"))
        guard let index else { return }
        tabs.selectedTabViewItemIndex = index
        if let pane = tabs.tabViewItems[index].viewController {
            tabs.fitWindow(to: pane)
        }
    }

    /// Re-read every pane that has been shown.
    ///
    /// Called when something outside this window changes what it
    /// displays — a browser sign-in completing, most of all. Panes that
    /// have never been selected have no views yet and must not be
    /// touched; `viewWillAppear` refreshes those when they appear.
    func refreshPanes() {
        for item in tabs.tabViewItems {
            guard let pane = item.viewController, pane.isViewLoaded else { continue }
            (pane as? SettingsPane)?.refresh()
        }
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        // Open at the width the panes are laid out for.
        // `NSTabViewController` honours a child's preferred *height* and
        // ignores its width, so without this the window opens at its
        // minimum and the explanations wrap into a tall column.
        if let window, window.frame.width < BasePane.paneWidth {
            window.setContentSize(
                NSSize(
                    width: BasePane.paneWidth,
                    height: window.contentLayoutRect.height))
        }
        window?.center()
        showWindow(nil)
        // Panes refresh themselves in `viewWillAppear`, which is the
        // only point at which their views are guaranteed to exist.
        // The frame, because this window has been the wrong size twice:
        // once far too tall from a mis-computed content height, once
        // with its contents sunk to the bottom.
        // Every pane's fitting size, not just the window's. This window
        // has come out the wrong size twice, and the useful question
        // both times was "which pane is asking for that?".
        let sizes = tabs.tabViewItems.compactMap { item -> String? in
            guard let pane = item.viewController else { return nil }
            let fitting = pane.view.fittingSize
            return "\(item.label) \(Int(fitting.width))×\(Int(fitting.height))"
        }
        if let pane = tabs.tabViewItems[tabs.selectedTabViewItemIndex].viewController {
            tabs.fitWindow(to: pane)
        }
        Log.write(
            "settings: shown \(NSStringFromRect(window?.frame ?? .zero)) — "
                + sizes.joined(separator: ", "))
    }
}

/// A pane that re-reads the config when the window is shown.
protocol SettingsPane {
    func refresh()
}

/// A tab controller that resizes its window to the pane on show.
///
/// The stock one sizes from `preferredContentSize` at switch time and
/// then leaves the window alone. That is fine while every pane is the
/// same height and wrong the moment one grows: the window keeps whatever
/// size it had and the last row of the taller pane is simply below the
/// bottom edge, with no scrollbar to say so.
final class SettingsTabs: NSTabViewController {

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        guard let pane = item?.viewController else { return }
        (pane as? BasePane)?.sizeToContent()
        fitWindow(to: pane)
    }

    /// Grow or shrink to the pane, keeping the top-left corner still —
    /// a settings window that walks up the screen as you click through
    /// its tabs is its own small annoyance.
    func fitWindow(to pane: NSViewController) {
        guard let window = view.window else { return }
        // Touch the view first. A view controller that has never been
        // shown has not run `loadView`, so its `preferredContentSize` is
        // still zero — and reading it before loading is how this
        // silently did nothing.
        _ = pane.view
        (pane as? BasePane)?.sizeToContent()

        let wanted = pane.preferredContentSize
        guard wanted.height > 0 else { return }


        let chrome = window.frame.height - window.contentLayoutRect.height
        var frame = window.frame
        let top = frame.maxY
        frame.size.height = wanted.height + chrome
        frame.size.width = max(frame.width, wanted.width)
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: true, animate: false)
        // Only when the window could not be given what the pane asked
        // for, which is the failure that hides a control below the
        // bottom edge.
        let got = window.contentLayoutRect.height
        if got + 1 < wanted.height {
            Log.write(
                String(
                    format: "settings: window is %.0f tall for a pane wanting %.0f "
                        + "— something is below the bottom edge",
                    got, wanted.height))
        }
    }
}

// MARK: - Shared layout helpers

/// A pane built as a column of labelled rows.
///
/// Auto Layout, not frames. The first version placed everything at fixed
/// coordinates computed for a 560-point view, which broke in three ways
/// at once the moment `NSTabViewController` gave the pane a different
/// size: subviews with no autoresizing mask keep their distance from the
/// *bottom*, so the whole form sank to the floor of the window; fixed
/// widths ran off the right edge; and a mis-computed content height made
/// the window far taller than anything in it.
///
/// So: a vertical stack pinned to the top and both sides, rows that
/// stretch with it, and a height that follows the content.
class BasePane: NSViewController, SettingsPane {

    let actions: SettingsWindow.Actions

    /// Width of the label gutter. One number, so every row in every pane
    /// lines up on the same colon.
    private static let labelWidth: CGFloat = 132

    private let stack = NSStackView()

    init(actions: SettingsWindow.Actions) {
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 200))

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            // Greater-than, not equal: the pane may be taller than its
            // content — the tab view sizes every pane to the largest —
            // but the content still starts at the top rather than being
            // centred or pushed to the bottom.
            view.bottomAnchor.constraint(
                greaterThanOrEqualTo: stack.bottomAnchor, constant: 24),
            // A floor on the width, and the reason is the height.
            //
            // `NSTabViewController` sizes the window from each pane's
            // fitting size, and the explanations under the controls
            // wrap — so a narrow solve makes them several lines tall and
            // the window comes out enormous. Measured before this line:
            // 520 × 588 for a pane with four checkboxes in it. Asking
            // for the width the pane is designed at makes the wrapping,
            // and therefore the height, come out right.
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 600),
        ])

        build()
        // Sized here as well as in `viewWillAppear`, because
        // `NSTabViewController` reads `preferredContentSize` while
        // switching to a pane — which is *before* that pane's
        // `viewWillAppear` runs. Setting it only there left the window
        // one step behind, and a row added to a pane fell below the
        // bottom edge.
        sizeToContent()
    }

    /// The width every pane is laid out at.
    ///
    /// Fixed rather than derived from the content. The explanations
    /// under the controls wrap, so their natural width is whatever the
    /// longest sentence happens to be — 744 points on one pane, 600 on
    /// another — and a settings window that changes width as you click
    /// between tabs is worse than one that is occasionally roomy.
    static let paneWidth: CGFloat = 620

    override func viewWillAppear() {
        super.viewWillAppear()
        sizeToContent()
        // Here, not in `present()`. A tab's view is not loaded until
        // that tab is first selected, so refreshing every pane when the
        // window opens wrote into controls that did not exist yet —
        // `build()` then created them empty and nothing filled them in.
        // The Permissions pane showed three labels and no answers.
        //
        // `viewWillAppear` fires when a pane is actually about to be
        // seen, which is also the moment its contents could be stale.
        refresh()
    }

    /// Tell the tab controller how tall this pane needs to be.
    ///
    /// `NSTabViewController` sizes the window from the selected child's
    /// `preferredContentSize`, and only recomputes it when the tab
    /// changes — so without this the window keeps whatever size it was
    /// created with. Measured before: a 600 × 588 window for a pane
    /// whose content is 286 points tall.
    ///
    /// The height has to be solved *at* `paneWidth`, because the wrapping
    /// hints are taller at narrower widths.
    func sizeToContent() {
        view.frame.size.width = Self.paneWidth
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(
            width: Self.paneWidth, height: max(stack.fittingSize.height + 48, 160))
        // Only when it looks wrong. This was a running commentary while
        // the pane layout was being fixed; now that it is, a line per
        // tab switch is noise. The condition is the bug it was written
        // for — content that does not start at the top of the pane.
        let topInset = view.frame.height - stack.frame.maxY
        if topInset > 40 || stack.frame.width < 100 {
            Log.write(
                "settings: \(String(describing: type(of: self))) content looks "
                    + "misplaced — \(Int(topInset))pt from the top, "
                    + "\(Int(stack.frame.width))pt wide")
        }
    }

    /// Subclasses add rows here.
    func build() {}
    func refresh() {}

    // MARK: Rows

    /// A labelled row: label in the gutter, control beside it, an
    /// optional explanation underneath the control.
    ///
    /// `stretches` is for the controls that should take the width of the
    /// window — a path, a URL, a menu — as opposed to a checkbox, which
    /// should stay the width of its own title.
    func row(
        _ label: String, _ control: NSView, stretches: Bool = false,
        note: String? = nil
    ) {
        let gutter = NSTextField(labelWithString: label)
        gutter.alignment = .right
        gutter.translatesAutoresizingMaskIntoConstraints = false
        gutter.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        gutter.setContentCompressionResistancePriority(.required, for: .horizontal)

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 5
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(control)
        if stretches {
            control.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        if let note {
            let hint = Self.hint(note)
            column.addArrangedSubview(hint)
            hint.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }

        let line = NSStackView(views: [gutter, column])
        line.orientation = .horizontal
        // The label sits level with the top of the control rather than
        // on its baseline, because a control with an explanation under
        // it is two lines tall and baseline alignment would drop the
        // label to the middle of them.
        line.alignment = .top
        line.spacing = 10
        line.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        // The label is fixed; everything else absorbs the slack.
        column.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    /// A row of buttons, aligned with the controls above and below it.
    func buttons(_ label: String, _ items: [NSButton], note: String? = nil) {
        let group = NSStackView(views: items)
        group.orientation = .horizontal
        group.spacing = 10
        group.alignment = .centerY
        // Buttons keep their natural width; the trailing space is slack.
        group.setHuggingPriority(.defaultHigh, for: .horizontal)
        row(label, group, note: note)
    }

    /// A heading spanning the full width, for a pane that needs one.
    func section(_ title: String) {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(header)
    }

    /// Secondary text under a control. `wrappingLabelWithString` rather
    /// than a plain label: it is the one that actually wraps to the
    /// width it is given instead of running off the edge.
    static func hint(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.isSelectable = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    /// A push button, sized to its own title.
    static func button(_ title: String, _ target: AnyObject, _ action: Selector)
        -> NSButton
    {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }
}

// MARK: - General

final class GeneralPane: BasePane, NSTextFieldDelegate {

    private let startAtLogin = NSButton()
    private let showPanel = NSButton()
    private let uploadEnabled = NSButton()
    private let language = NSTextField()

    override func build() {
        startAtLogin.setButtonType(.switch)
        startAtLogin.title = "Start Atrium PA Capture when I log in"
        startAtLogin.target = self
        startAtLogin.action = #selector(toggleLogin)
        row(
            "Startup:", startAtLogin,
            note: "A recorder that is not running when the meeting starts has "
                + "missed the meeting.")

        showPanel.setButtonType(.switch)
        showPanel.title = "Show the floating panel"
        showPanel.target = self
        showPanel.action = #selector(togglePanel)
        row(
            "Panel:", showPanel,
            note: "It carries the record button and the live meter — the only "
                + "way to see that audio is actually arriving.")

        uploadEnabled.setButtonType(.switch)
        uploadEnabled.title = "Upload recordings to Atrium PA"
        uploadEnabled.target = self
        uploadEnabled.action = #selector(toggleUpload)
        row(
            "Uploads:", uploadEnabled,
            note: "Off means recordings still queue up on disk and nothing is "
                + "sent. Nothing is lost.")

        language.placeholderString = "auto-detect"
        language.target = self
        language.action = #selector(saveLanguage)
        // Same reason as the server field: a text field that only
        // commits on Return loses whatever was typed if the window is
        // closed instead.
        language.delegate = self
        language.translatesAutoresizingMaskIntoConstraints = false
        // Two letters, so it does not stretch to the window like a path
        // would. Widening this one would only advertise room for
        // something that is never longer than "auto-detect".
        language.widthAnchor.constraint(equalToConstant: 140).isActive = true
        row(
            "Language:", language,
            note: "An ISO hint for the transcriber, like “en” or “nl”. Blank "
                + "lets it decide.")
    }

    override func refresh() {
        let config = actions.config()
        startAtLogin.state = LoginItem.isEnabled ? .on : .off
        showPanel.state = PanelVisibility.isVisible() ? .on : .off
        uploadEnabled.state = config.uploadEnabled ? .on : .off
        language.stringValue = config.language ?? ""
    }

    @objc private func toggleLogin() {
        if !LoginItem.setEnabled(startAtLogin.state == .on) {
            startAtLogin.state = LoginItem.isEnabled ? .on : .off
        }
    }

    @objc private func togglePanel() {
        PanelVisibility.setVisible(showPanel.state == .on)
    }

    @objc private func toggleUpload() {
        var config = actions.config()
        config.uploadEnabled = uploadEnabled.state == .on
        actions.save(config)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === language else { return }
        saveLanguage()
    }

    @objc private func saveLanguage() {
        var config = actions.config()
        let typed = language.stringValue.trimmingCharacters(in: .whitespaces)
        config.language = typed.isEmpty ? nil : String(typed.prefix(8))
        actions.save(config)
    }
}

/// The panel is owned by the delegate, not by the config, so the switch
/// talks to it through here rather than through a saved field.
enum PanelVisibility {
    nonisolated(unsafe) static var isVisible: () -> Bool = { true }
    nonisolated(unsafe) static var setVisible: (Bool) -> Void = { _ in }
}

// MARK: - Atrium PA

final class AccountPane: BasePane, NSTextFieldDelegate {

    private let baseURL = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private lazy var signInOut = Self.button("Log In…", self, #selector(signInOrOut))

    override func build() {
        baseURL.placeholderString = AtriumConfig.baseURLExample
        baseURL.target = self
        baseURL.action = #selector(saveBaseURL)
        // Saved as it is typed, not on Return.
        //
        // `NSTextField`'s action fires when *editing ends*, and clicking
        // a button in the same window does not reliably end editing
        // first. So typing an address and pressing Log In read the
        // config as it was before the address was typed, and reported
        // "No Atrium PA address" over a window with the address plainly
        // visible in it. Writing through on every keystroke is also what
        // the rest of this window does.
        baseURL.delegate = self
        row(
            "Server:", baseURL, stretches: true,
            note: "The Atrium PA deployment recordings are sent to. Changing it "
                + "means signing in again.")

        status.lineBreakMode = .byTruncatingMiddle
        status.textColor = .secondaryLabelColor
        row("Account:", status, stretches: true)

        buttons(
            "", [signInOut, Self.button("Test Connection", self, #selector(test))])

        buttons(
            "Triggers:",
            [
                Self.button("Edit Allowlist…", self, #selector(editAllowlist)),
                Self.button("Reload", self, #selector(reloadAllowlist)),
            ],
            note: "Bundle-ID prefixes that may start a recording. Helpers hold "
                + "the microphone, so the match is on the prefix.")
    }

    override func refresh() {
        baseURL.stringValue = actions.config().baseURL
        updateStatus()
    }

    private func updateStatus() {
        let config = actions.config()
        let signedIn = actions.isSignedIn()
        signInOut.isEnabled = true
        signInOut.title = signedIn ? "Log Out" : "Log In…"
        // The client id is not shown. It is a machine identifier the
        // user never types, never needs and cannot act on — it was only
        // ever there because it was easy to print.
        status.stringValue =
            signedIn
            ? "Signed in" : config.baseURL.isEmpty ? "No server set" : "Not signed in"
    }

    /// Called on every keystroke. Deliberately does not `refresh()` —
    /// rewriting the field while somebody is typing in it moves the
    /// insertion point.
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === baseURL else { return }
        commitBaseURL()
        updateStatus()
    }

    @objc private func saveBaseURL() {
        commitBaseURL()
        refresh()
    }

    private func commitBaseURL() {
        var config = actions.config()
        let typed = baseURL.stringValue.trimmingCharacters(in: .whitespaces)
        config.baseURL = typed.hasSuffix("/") ? String(typed.dropLast()) : typed
        actions.save(config)
    }

    @objc private func signInOrOut() {
        // Belt to the braces above: end editing so any field still being
        // typed into has committed before this reads the config.
        view.window?.makeFirstResponder(nil)

        // Disabled until the answer comes back, because the browser flow
        // finishes on its own schedule and this button changes meaning
        // when it does. Pressing it twice signed the user in and then
        // straight back out — the title still said "Log In…" while the
        // action had already become "Log Out".
        signInOut.isEnabled = false
        signInOut.title = actions.isSignedIn() ? "Logging out…" : "Waiting for browser…"

        if actions.isSignedIn() { actions.logOut() } else { actions.logIn() }
    }

    @objc private func test() {
        view.window?.makeFirstResponder(nil)
        actions.testConnection()
    }
    @objc private func editAllowlist() { actions.editAllowlist() }
    @objc private func reloadAllowlist() { actions.reloadAllowlist() }
}

// MARK: - Recordings

final class StoragePane: BasePane {

    private let folder = NSTextField(labelWithString: "")
    private let masters = NSPopUpButton()
    private let uploads = NSPopUpButton()
    private let transcriptFormat = NSPopUpButton()

    /// Retention offered as choices rather than a number field. The
    /// meaning of `0` and of a negative number is exactly the kind of
    /// thing a text box hides.
    private static let windows: [(String, Int)] = [
        ("As soon as it is transcribed", 0),
        ("1 day", 1), ("7 days", 7), ("30 days", 30), ("90 days", 90),
        ("Keep for ever", -1),
    ]

    override func build() {
        folder.lineBreakMode = .byTruncatingHead
        folder.textColor = .secondaryLabelColor
        folder.isSelectable = true
        row("Folder:", folder, stretches: true)

        buttons(
            "",
            [
                Self.button("Choose…", self, #selector(chooseFolder)),
                Self.button("Reveal", self, #selector(revealFolder)),
                Self.button("Use Default", self, #selector(useDefault)),
            ],
            note: "Recordings already made stay where they are and keep working "
                + "— only new ones go to the new folder.")

        for (title, _) in Self.windows { masters.addItem(withTitle: title) }
        masters.target = self
        masters.action = #selector(saveMasters)
        row(
            "Keep masters:", masters, stretches: true,
            note: "The 48 kHz originals: 690 MB an hour, against 17 for the "
                + "uploaded copy. Nothing reads them today.")

        for (title, _) in Self.windows { uploads.addItem(withTitle: title) }
        uploads.target = self
        uploads.action = #selector(saveUploads)
        row(
            "Keep uploads:", uploads, stretches: true,
            note: "The small m4a. Atrium PA sweeps its own copy at ~90 days, "
                + "after which this is the only one anywhere.")

        for format in TranscriptFormat.allCases {
            transcriptFormat.addItem(withTitle: format.label)
        }
        transcriptFormat.target = self
        transcriptFormat.action = #selector(saveTranscriptFormat)
        row(
            "Transcripts:", transcriptFormat, stretches: true,
            note: "What “Save Transcript to Downloads” writes. Markdown keeps "
                + "the structure; plain text is for anywhere the asterisks "
                + "would be read literally.")
    }

    override func refresh() {
        let config = actions.config()
        transcriptFormat.selectItem(
            at: TranscriptFormat.allCases.firstIndex(of: config.transcriptFormat) ?? 0)
        folder.stringValue = AppPaths.recordings.path
        folder.toolTip = AppPaths.recordings.path
        masters.selectItem(at: index(of: config.masterRetentionDays))
        uploads.selectItem(at: index(of: config.localRetentionDays))
    }

    private func index(of days: Int) -> Int {
        Self.windows.firstIndex { $0.1 == days }
            ?? (days < 0 ? Self.windows.count - 1 : 0)
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = AppPaths.recordings
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        actions.moveRecordings(chosen)
        // The move is asynchronous — it pins the existing queue first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refresh()
        }
    }

    @objc private func useDefault() {
        actions.moveRecordings(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refresh()
        }
    }

    @objc private func revealFolder() {
        try? AppPaths.ensureDirectories()
        NSWorkspace.shared.open(AppPaths.recordings)
    }

    @objc private func saveMasters() {
        var config = actions.config()
        config.masterRetentionDays = Self.windows[masters.indexOfSelectedItem].1
        actions.save(config)
    }

    @objc private func saveTranscriptFormat() {
        var config = actions.config()
        config.transcriptFormat =
            TranscriptFormat.allCases[transcriptFormat.indexOfSelectedItem]
        actions.save(config)
    }

    @objc private func saveUploads() {
        var config = actions.config()
        config.localRetentionDays = Self.windows[uploads.indexOfSelectedItem].1
        actions.save(config)
    }
}

// MARK: - Permissions

final class PermissionsPane: BasePane {

    private var built: [(detail: NSTextField, open: NSButton)] = []

    override func build() {
        for check in Permissions.all(notificationStatus: actions.notificationStatus()) {
            let detail = BasePane.hint("")
            let open = Self.button("Settings…", self, #selector(openSettings(_:)))
            open.isHidden = true

            let group = NSStackView(views: [detail, open])
            group.orientation = .horizontal
            group.alignment = .top
            group.spacing = 10
            detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
            open.setContentHuggingPriority(.required, for: .horizontal)

            built.append((detail, open))
            row(check.name + ":", group, stretches: true)
        }
    }

    override func refresh() {
        let checks = Permissions.all(notificationStatus: actions.notificationStatus())
        // Logged as well as shown: "the pane was blank" and "the pane
        // said no" are different problems and looked identical once.
        Log.write(
            "settings: permissions — "
                + checks.map { "\($0.name) \($0.state.summary)" }
                .joined(separator: ", "))
        for (index, check) in checks.enumerated() where index < built.count {
            let (detail, open) = built[index]
            switch check.state {
            case .granted:
                detail.stringValue = "Granted."
                detail.textColor = .systemGreen
                open.isHidden = true
            case .missing(let why, let settings):
                detail.stringValue = "\(why) \(check.consequence)"
                detail.textColor = .systemRed
                open.isHidden = settings == nil
                open.identifier = settings.map {
                    NSUserInterfaceItemIdentifier($0.absoluteString)
                }
            case .unknown(let why):
                detail.stringValue = why
                detail.textColor = .secondaryLabelColor
                open.isHidden = true
            }
        }
    }

    @objc private func openSettings(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let url = URL(string: raw) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
