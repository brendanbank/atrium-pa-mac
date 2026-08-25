import AVFoundation
import AppKit
import AtriumCore

/// One voice in a recording, as a row.
///
/// Everything a decision about this voice needs, on one line and visible
/// at once: which voice it is, how much it said, what it sounds like,
/// and who it might be. The window that holds these used to ask about
/// one voice at a time behind a Next button, so comparing two voices —
/// which is the actual task when a recording has four people in it —
/// meant remembering the previous one.
final class VoiceRow: NSView {

    /// The column geometry, shared with the header above the list so the
    /// two cannot drift apart.
    enum Columns {
        static let name: CGFloat = 330
        static let spinner: CGFloat = 16
        static let play: CGFloat = 34
        static let newButton: CGFloat = 58
        static let detach: CGFloat = 34
        static let choices: CGFloat = 260
        static let spacing: CGFloat = 8
    }

    /// The three states a voice arrives in, flattened.
    ///
    /// They differ in what is already true about them, not in what can
    /// be done: all three end in `name_speaker` with a person.
    enum Kind {
        /// Nobody has put a name to it.
        case unnamed
        /// A name is applied, but as a guess nobody agreed to. Shown
        /// because the wrong answer is *already written* across every
        /// turn this voice spoke.
        case unconfirmed(name: String, percent: Int?, band: String?)
        /// Settled. Shown so the row of voices is the whole cast rather
        /// than only the awkward ones — "who else is in this recording"
        /// is most of the context for answering "who is this".
        case identified(name: String, percent: Int?)
    }

    let key: String
    let voiceCluster: Int?
    let turnCount: Int
    let kind: Kind

    /// Ask the window to do the parts that need the client.
    var onPlay: ((VoiceRow) -> Void)?
    var onPick: ((VoiceRow, Int) -> Void)?
    var onNew: ((VoiceRow) -> Void)?
    /// Take the name back off this voice. Enabled only where there is
    /// one to take off.
    var onDetach: ((VoiceRow) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let play = NSButton()
    private let newButton = NSButton()
    private let detachButton = NSButton()
    private let choices = NSPopUpButton()
    private let spinner = NSProgressIndicator()

    /// Candidates behind the menu, parallel to its items after the first.
    private var candidates: [MCPClient.SpeakerCandidate] = []

    /// `unknownNumber` counts only the voices nobody has claimed, so
    /// the numbering matches what is actually being asked about.
    init(
        key: String, voiceCluster: Int?, turnCount: Int, kind: Kind,
        unknownNumber: Int?
    ) {
        self.key = key
        self.voiceCluster = voiceCluster
        self.turnCount = turnCount
        self.kind = kind
        super.init(frame: .zero)
        build(unknownNumber: unknownNumber)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Layout

    private func build(unknownNumber: Int?) {
        translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 13, weight: .medium)
        // Who this is, not which row it happens to be on. "Voice 6"
        // next to "Hernan Ruiz" in the line below was the row showing
        // the least useful thing it knew. A number is only the answer
        // when there is no name to give.
        switch kind {
        case .identified(let name, let percent):
            label.stringValue = Self.titled(name, percent: percent)
        case .unconfirmed(let name, let percent, _):
            label.stringValue = Self.titled(name, percent: percent)
        case .unnamed:
            label.stringValue = unknownNumber.map { "\($0) unknown" } ?? "unknown"
        }
        label.lineBreakMode = .byTruncatingTail

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.stringValue = describeKind()

        // A filled triangle, which is what "play" looks like everywhere
        // else on this machine. It becomes a stop square while playing —
        // see `setPlaying`.
        play.image = NSImage(
            systemSymbolName: "play.fill", accessibilityDescription: "Play this voice")
        play.bezelStyle = .rounded
        play.isEnabled = false
        play.toolTip = "Hear a few seconds of this voice"
        play.target = self
        play.action = #selector(playTapped)

        newButton.title = "New"
        newButton.bezelStyle = .rounded
        newButton.toolTip = "This is somebody Atrium PA does not know yet"
        newButton.target = self
        newButton.action = #selector(newTapped)

        // Undoing a name should feel like undoing something. The server
        // refuses to overwrite one in place for the same reason:
        // anchoring a voice to the wrong person propagates backwards
        // through every recording it appears in.
        detachButton.image = NSImage(
            systemSymbolName: "person.badge.minus",
            accessibilityDescription: "Detach this voice from the person")
        detachButton.bezelStyle = .rounded
        detachButton.toolTip =
            "Detach this voiceprint from the person it is named as, so it can "
            + "be named again"
        detachButton.target = self
        detachButton.action = #selector(detachTapped)

        choices.target = self
        choices.action = #selector(pickTapped)
        choices.isEnabled = false
        // Named, not vague. Fifteen seconds of "Looking…" reads as a
        // hang; fifteen seconds of "Asking Atrium PA…" reads as a wait
        // on something identifiable.
        choices.addItem(withTitle: "Asking Atrium PA…")

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let names = NSStackView(views: [label, status])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 1

        let row = NSStackView(views: [
            names, spinner, play, newButton, detachButton, choices,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Columns.spacing
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            // Wide enough to be worth reading, and free to take
            // whatever the controls do not. Every row is pinned to the
            // list's width and every control is fixed, so this ends up
            // identical on each row — which is what alignment needs.
            // Sizing it to its *content* is what made the buttons a
            // staircase before.
            names.widthAnchor.constraint(greaterThanOrEqualToConstant: Columns.name),
            // The spinner is hidden rather than removed while idle, so
            // without a fixed width the row shifts sideways the moment a
            // request finishes.
            spinner.widthAnchor.constraint(equalToConstant: Columns.spinner),
            play.widthAnchor.constraint(equalToConstant: Columns.play),
            newButton.widthAnchor.constraint(equalToConstant: Columns.newButton),
            detachButton.widthAnchor.constraint(equalToConstant: Columns.detach),
            choices.widthAnchor.constraint(equalToConstant: Columns.choices),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        names.setContentHuggingPriority(.init(1), for: .horizontal)
    }

    /// A name carries its match percentage unless the match is certain.
    ///
    /// A name shown bare reads as settled. Most of these are not: they
    /// come from a voiceprint comparison that returned a number, and
    /// 62% and 100% must not look the same at a glance — the whole
    /// question this window asks is which of them to believe. Only a
    /// match with nothing left to doubt gets to appear as a plain name.
    static func titled(_ name: String, percent: Int?) -> String {
        guard let percent, percent < 100 else { return name }
        return "\(name) (\(percent)%)"
    }

    private func describeKind() -> String {
        let turns = Self.count(turnCount, "turn")
        switch kind {
        case .unnamed:
            return "\(turns) · nobody has named this voice"
        case .unconfirmed(_, let percent, let band):
            // Percentage *and* band, never one alone — 44% and 91% must
            // not read alike, and the band is the server's own reading
            // of what the number means. The name itself is the row's
            // title now, so it is not repeated here.
            let confidence =
                percent.map { "\($0)% \(band ?? "match")" } ?? (band ?? "a guess")
            return "\(turns) · a guess at \(confidence), nobody has agreed"
        case .identified:
            return "\(turns) · identified"
        }
    }

    // MARK: - State

    /// Swap the triangle for a square while this row is sounding.
    ///
    /// A clip is a few seconds of somebody talking and there are several
    /// rows of them, so starting the wrong one — or wanting to stop
    /// halfway and try the next — is the normal case rather than the
    /// exception. A play button with no way back is a control you have
    /// to wait out.
    func setPlaying(_ playing: Bool) {
        play.image = NSImage(
            systemSymbolName: playing ? "stop.fill" : "play.fill",
            accessibilityDescription: playing ? "Stop" : "Play this voice")
        play.toolTip =
            playing ? "Stop" : (play.toolTip ?? "Hear a few seconds of this voice")
    }

    var isPlaying: Bool {
        play.image?.accessibilityDescription == "Stop"
    }

    /// Named during this session, or already named when it arrived.
    private(set) var isSettled = false

    /// Still worth asking about.
    ///
    /// A row that has just been named stops counting, which the heading
    /// depends on — it read "6 of 6 voices still need a name" with four
    /// of them freshly named on screen.
    var isActionable: Bool {
        if isSettled { return false }
        if case .identified = kind { return false }
        return voiceCluster != nil
    }

    /// Whether there is a name here to take back off.
    /// Who this row currently claims to be, for the confirmation.
    var currentName: String {
        switch kind {
        case .identified(let name, _), .unconfirmed(let name, _, _): return name
        case .unnamed: return label.stringValue
        }
    }

    var canDetach: Bool {
        if case .unnamed = kind, !isSettled { return false }
        return voiceCluster != nil
    }

    func showBusy(_ busy: Bool) {
        if busy {
            spinner.startAnimation(nil)
            status.stringValue = "\(describeKind()) · asking Atrium PA who this is…"
        } else {
            spinner.stopAnimation(nil)
        }
        choices.isEnabled = !busy && isActionable
        newButton.isEnabled = !busy && isActionable
        detachButton.isEnabled = !busy && canDetach
    }

    /// Fill the menu once the server has said who this might be.
    func offer(_ evidence: MCPClient.SpeakerEvidence) {
        // A declined invitee was not in the room. Dropped rather than
        // greyed out: a wrong suggestion costs more than a missing one.
        candidates = evidence.candidates.filter(\.isPlausible)
        choices.removeAllItems()
        choices.addItem(withTitle: isActionable ? "Who is this?" : settledName())
        choices.lastItem?.representedObject = nil
        for candidate in candidates {
            choices.addItem(withTitle: Self.label(for: candidate))
            choices.lastItem?.representedObject = candidate.personID
        }
        choices.selectItem(at: 0)
        choices.isEnabled = isActionable
        newButton.isEnabled = isActionable
        detachButton.isEnabled = canDetach
        play.isEnabled = !evidence.samples.isEmpty

        var notes: [String] = [describeKind()]
        if evidence.otherRecordings > 0 {
            notes.append(
                evidence.otherRecordings == 1
                    ? "also in 1 other recording"
                    : "also in \(evidence.otherRecordings) other recordings")
        }
        // The "clip may no longer play" caveat lives on the play button
        // rather than in this sentence. It was true of every row, so as
        // a suffix it was pure noise repeated seven times — and it is
        // about that button, which is where somebody looks when it does
        // not work.
        if let sample = evidence.samples.first, !sample.hasPersistedSnippet {
            play.toolTip =
                "The server may have already swept the audio this clip "
                + "comes from, in which case it will not play."
        }
        status.stringValue = notes.joined(separator: " · ")
        status.toolTip = status.stringValue
    }

    /// What a settled row shows in place of a question.
    private func settledName() -> String {
        if case .identified(let name, _) = kind { return name }
        return "Named"
    }

    func candidate(forPersonID personID: Int) -> MCPClient.SpeakerCandidate? {
        candidates.first { $0.personID == personID }
    }

    /// What happened, in the row rather than in a status line somewhere
    /// else — with four voices on screen, a single shared message cannot
    /// say which one it is about.
    func settled(as name: String, turns: Int, recordings: Int) {
        isSettled = true
        label.stringValue = name
        status.stringValue =
            "named — \(Self.count(turns, "turn")) across "
            + Self.count(recordings, "recording")
        status.textColor = .systemGreen
        choices.removeAllItems()
        choices.addItem(withTitle: name)
        choices.isEnabled = false
        newButton.isEnabled = false
        detachButton.isEnabled = true
    }

    /// Back to a question, after the name was taken off.
    func detached(unknownNumber: Int?) {
        isSettled = false
        label.stringValue = unknownNumber.map { "\($0) unknown" } ?? "unknown"
        status.stringValue = "the name was taken off this voice"
        status.textColor = .secondaryLabelColor
        detachButton.isEnabled = false
        newButton.isEnabled = true
        choices.isEnabled = true
        choices.selectItem(at: 0)
    }

    /// "1 turn", "29 turns" — never "1 turn(s)".
    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)" + (n == 1 ? "" : "s")
    }

    func failed(_ message: String) {
        status.stringValue = message
        status.textColor = .systemRed
        showBusy(false)
    }

    func unavailable(_ message: String) {
        status.stringValue = "\(describeKind()) · \(message)"
        choices.removeAllItems()
        choices.addItem(withTitle: "—")
        choices.isEnabled = false
        newButton.isEnabled = false
        detachButton.isEnabled = false
        play.isEnabled = false
        showBusy(false)
    }

    private static func label(for candidate: MCPClient.SpeakerCandidate) -> String {
        var parts = [candidate.displayName]
        if let percent = candidate.matchPercent, let band = candidate.band {
            parts.append("— \(percent)% \(band)")
        } else if let rsvp = candidate.rsvp {
            parts.append("— invited, \(rsvp)")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Actions

    @objc private func playTapped() { onPlay?(self) }
    @objc private func newTapped() { onNew?(self) }
    @objc private func detachTapped() { onDetach?(self) }

    @objc private func pickTapped() {
        guard let personID = choices.selectedItem?.representedObject as? Int else {
            return
        }
        onPick?(self, personID)
    }

    /// Put the menu back to its unanswered state.
    ///
    /// Used when a name is not applied after all — a cancelled duplicate
    /// prompt, or a failure. Leaving the person selected would show an
    /// answer the server never received.
    func resetChoice() {
        choices.selectItem(at: 0)
    }
}
