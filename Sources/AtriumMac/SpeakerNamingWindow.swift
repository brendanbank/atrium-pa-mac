import AVFoundation
import AppKit
import AtriumCore
import Foundation

/// "Who was in this recording?" — every voice at once.
///
/// This asked about one voice at a time behind a Next button. That is
/// the wrong shape for the actual task: a recording has three or four
/// people in it, and telling them apart means comparing them. Behind a
/// wizard, comparing two voices meant remembering the previous one.
///
/// So every voice is a row — including the ones already identified.
/// "Who else is in this recording" is most of the context for answering
/// "who is this", and hiding the settled ones threw it away.
///
/// ## What it will not do
///
/// It never names anybody without a press. Not on a 91% match, not on a
/// unanimous attendee list. That is the tool's own contract — *"get an
/// explicit yes before every call, even on a high match"* — and it is
/// also the difference between a recorder and something that quietly
/// decides who said what about people who are not in the room.
///
/// Evidence is shown, never summarised into a verdict. A match
/// percentage appears next to its band because 44% and 91% must not read
/// the same, and an invitee who declined is not offered at all: the
/// server returns the RSVP, and somebody who said no was not there.
final class SpeakerNamingWindow: NSWindow, AVAudioPlayerDelegate {

    /// Called with the speaker key once a voice has been named, so the
    /// badge can come down and stay down. The name is carried too
    /// because the activity window has no other way to learn it.
    var onResolved: ((String, String?) -> Void)?

    private var item: QueueItem?
    private var client: MCPClient?
    private var rows: [VoiceRow] = []
    private let newPersonSheet = NewPersonSheet()
    private var evidenceByKey: [String: MCPClient.SpeakerEvidence] = [:]
    private var player: AVAudioPlayer?
    /// Which row is sounding, so its button can be put back.
    private var playingRow: VoiceRow?
    /// Bumped on every play or stop, so a clip that finishes
    /// downloading after the user changed their mind does not start
    /// playing anyway.
    private var playGeneration = 0

    private let heading = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let doneButton = NSButton()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        title = "Who was in this recording?"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 560, height: 260)
        buildContent()
    }

    // MARK: - Presenting

    func present(item: QueueItem, client: MCPClient, host: NSWindow?) {
        self.item = item
        self.client = client
        buildRows(for: item)

        // A sheet, and it has to be one.
        //
        // A sheet is modal to the window it belongs to, opens centred on
        // it, and cannot be left behind — which is what this needs,
        // because naming voices is a flow with a Done at the end.
        //
        // The alternative, a titled window run with `NSApp.runModal`,
        // buys a title bar and a close button and costs everything else.
        // `present` is reached from inside a `MainActor.run` block, so
        // `runModal` blocks *the main actor* for the whole session:
        // every `await` that needs it stops, and the evidence requests
        // that fill these rows never come back. Sampled while it hung,
        // the main thread sat in `runModalForWindow:` underneath a
        // concurrency thunk, and the ten-second mic reconcile had
        // stopped firing too.
        //
        // So: no title bar here. Done and Escape are the way out.
        if let host, host.isVisible {
            if isVisible { orderOut(nil) }
            host.beginSheet(self)
        } else {
            center()
            makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        gatherEvidence()
    }

    private func finish() {
        stopPlayback()
        if let host = sheetParent {
            host.endSheet(self)
        } else {
            close()
        }
    }

    /// Escape. A sheet has no close button and `performClose` does
    /// nothing on one, so without this the only way out is the button.
    override func cancelOperation(_ sender: Any?) { finish() }

    /// The red button goes through here rather than through `finish`,
    /// so a clip left playing would keep playing over a closed window.
    override func close() {
        stopPlayback()
        super.close()
    }

    // MARK: - Rows

    /// Unconfirmed first, then unnamed, then settled.
    ///
    /// Order is by how much the question needs answering. An unconfirmed
    /// guess is first because a wrong answer is *already applied* to
    /// every turn that voice spoke; the identified ones are last because
    /// they are context rather than work.
    private func buildRows(for item: QueueItem) {
        stopPlayback()
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        evidenceByKey = [:]

        // Only the unclaimed voices are numbered. Numbering all of them
        // would put a "4" beside a person's name, which is a label for
        // the list rather than for them.
        var unknowns = 0
        func add(key: String, cluster: Int?, turns: Int, kind: VoiceRow.Kind) {
            var unknownNumber: Int?
            if case .unnamed = kind {
                unknowns += 1
                unknownNumber = unknowns
            }
            let row = VoiceRow(
                key: key, voiceCluster: cluster, turnCount: turns, kind: kind,
                unknownNumber: unknownNumber)
            row.onPlay = { [weak self] in self?.play($0) }
            row.onPick = { [weak self] in self?.pick($0, personID: $1) }
            row.onNew = { [weak self] in self?.createPerson(for: $0) }
            row.onDetach = { [weak self] in self?.detach($0) }
            rows.append(row)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        for match in item.provisionalSpeakers {
            add(
                key: match.key, cluster: match.voiceCluster, turns: match.turnCount,
                kind: .unconfirmed(
                    name: match.displayName, percent: match.matchPercent,
                    band: match.band))
        }
        for speaker in item.nameableSpeakers {
            add(
                key: speaker.key, cluster: speaker.voiceCluster,
                turns: speaker.turnCount, kind: .unnamed)
        }
        // Anchored names only. An un-anchored one is already above as an
        // unconfirmed guess, and listing it twice would ask the same
        // question in two places.
        let asked = Set(item.provisionalSpeakers.map(\.key))
        for speaker in item.knownSpeakers
        where speaker.anchored && !asked.contains(speaker.key) {
            add(
                key: speaker.key, cluster: speaker.voiceCluster,
                turns: speaker.turnCount,
                kind: .identified(
                    name: speaker.displayName, percent: speaker.matchPercent))
        }

        refreshHeading()
    }

    /// One request per voice, all at once.
    ///
    /// Serially would mean the last row in a four-person meeting waits
    /// for three round trips before it can say anything, and the point
    /// of showing them together is being able to look at them together.
    /// Ask the server who each voice might be.
    ///
    /// Measured: six voices, all asked at once, all answered about
    /// **fifteen seconds** later. That is the server's own latency for
    /// `identify_speaker` — it compares a voiceprint against every
    /// person it knows — and it is long enough that a row which only
    /// spins looks broken. So the wait says what it is waiting for.
    private func gatherEvidence() {
        guard let item, let client, let captureID = item.captureID else {
            rows.forEach { $0.unavailable("not uploaded yet") }
            return
        }
        for row in rows {
            guard let cluster = row.voiceCluster else {
                row.unavailable("no voice cluster — cannot be named from here")
                continue
            }
            row.showBusy(true)
            Task { [weak self] in
                do {
                    let found = try await client.identifySpeaker(
                        captureID: captureID, voiceCluster: cluster)
                    // Kept. Six of these take about fifteen seconds, so
                    // "is it working or is it stuck?" is a real question
                    // and this is the only thing that answers it.
                    Log.write(
                        "naming: cluster \(cluster) has \(found.candidates.count) "
                            + "candidate(s), \(found.samples.count) clip(s)")
                    onMainThread {
                        self?.evidenceByKey[row.key] = found
                        row.showBusy(false)
                        row.offer(found)
                    }
                } catch {
                    onMainThread {
                        Log.write(
                            "naming: no evidence for cluster \(cluster) — \(error)")
                        row.failed(Self.describe(error))
                    }
                }
            }
        }
    }

    // MARK: - Playing

    private func play(_ row: VoiceRow) {
        // The same button stops it. Pressing play on the row that is
        // already sounding is the obvious way to make it stop, so that
        // is what it does.
        if row.isPlaying {
            stopPlayback()
            return
        }
        guard let client, let sample = evidenceByKey[row.key]?.samples.first else {
            return
        }
        stopPlayback()

        playGeneration += 1
        let generation = playGeneration
        // Shown before the bytes arrive, because fetching takes long
        // enough that a button which does not react reads as broken.
        row.setPlaying(true)
        playingRow = row

        Task { [weak self] in
            do {
                let data = try await client.fetchSample(sample)
                onMainThread {
                    guard let self, generation == self.playGeneration else { return }
                    self.player = try? AVAudioPlayer(data: data)
                    self.player?.delegate = self
                    self.player?.play()
                }
            } catch {
                onMainThread {
                    guard let self, generation == self.playGeneration else { return }
                    self.stopPlayback()
                    row.failed("that clip is no longer available")
                }
            }
        }
    }

    /// Silence whatever is sounding and put its button back.
    private func stopPlayback() {
        playGeneration += 1
        player?.stop()
        player = nil
        playingRow?.setPlaying(false)
        playingRow = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully: Bool) {
        // A clip that ran to its end leaves a stop button that would do
        // nothing, which is the same wrong state as one that never
        // started.
        DispatchQueue.main.async { [weak self] in self?.stopPlayback() }
    }

    // MARK: - Naming

    private func pick(_ row: VoiceRow, personID: Int) {
        let name =
            row.candidate(forPersonID: personID)?.displayName ?? "person \(personID)"
        apply(row: row, personID: personID, newPerson: nil, displayName: name)
    }

    /// Somebody Atrium PA may or may not already know.
    ///
    /// The sheet searches as the name is typed and says so in place when
    /// one already exists, so the duplicate check happens *before* the
    /// decision rather than as a second dialog after it. Naming a voice
    /// from this app has created a duplicate person before, and the
    /// search that would have prevented it was in another window.
    private func createPerson(for row: VoiceRow) {
        guard let client else { return }
        newPersonSheet.present(on: self, client: client) { [weak self] outcome in
            switch outcome {
            case .cancel:
                row.resetChoice()
            case .use(let personID, let name):
                self?.apply(
                    row: row, personID: personID, newPerson: nil, displayName: name)
            case .create(let name, let email):
                self?.apply(
                    row: row, personID: nil, newPerson: name, email: email,
                    displayName: name)
            }
        }
    }

    private func apply(
        row: VoiceRow, personID: Int?, newPerson: String?, email: String? = nil,
        displayName: String
    ) {
        guard let item, let client, let captureID = item.captureID,
            let cluster = row.voiceCluster
        else { return }

        row.showBusy(true)
        let summary = evidenceSummary(for: row, personID: personID)

        Task { [weak self] in
            let resolved = personID
            do {
                let result = try await client.nameSpeaker(
                    captureID: captureID, voiceCluster: cluster, personID: resolved,
                    newPerson: resolved == nil ? (displayName, email) : nil,
                    evidence: summary)
                onMainThread {
                    // Logged as well as shown: otherwise there is no way
                    // to tell afterwards whether a voice was named from
                    // here or in the web UI, and that is the first
                    // question asked when a name turns out to be wrong.
                    Log.write(
                        "naming: named cluster \(cluster) as "
                            + (resolved.map { "person \($0)" }
                                ?? "new person “\(displayName)”")
                            + " — \(result.turnsUpdated) turn(s), "
                            + "\(result.recordingsAffected) recording(s)")
                    row.showBusy(false)
                    // The blast radius is the point: naming reaches
                    // backwards through every recording this voice is in.
                    row.settled(
                        as: displayName, turns: result.turnsUpdated,
                        recordings: result.recordingsAffected)
                    self?.onResolved?(row.key, displayName)
                    self?.refreshHeading()
                }
            } catch {
                onMainThread {
                    Log.write("naming: could not name cluster \(cluster) — \(error)")
                    row.showBusy(false)
                    row.resetChoice()
                    row.failed("could not name — \(Self.describe(error))")
                }
            }
        }
    }

    /// Take the name back off a voice.
    ///
    /// Confirmed first, because it is not local: `unname_speaker` is
    /// addressed by voice cluster rather than by capture, so it reaches
    /// backwards through every recording that voice appears in — the
    /// same blast radius naming has, in the other direction.
    private func detach(_ row: VoiceRow) {
        guard let client, let cluster = row.voiceCluster else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Detach this voice from \(row.currentName)?"
        alert.informativeText =
            "The name comes off this voiceprint everywhere it appears, not "
            + "only in this recording. It can be named again afterwards."
        alert.addButton(withTitle: "Detach")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        row.showBusy(true)
        Task { [weak self] in
            do {
                try await client.unnameSpeaker(voiceCluster: cluster)
                onMainThread {
                    Log.write("naming: detached cluster \(cluster)")
                    row.showBusy(false)
                    row.detached(unknownNumber: nil)
                    // The badge counted this voice as answered; it is a
                    // question again.
                    self?.onResolved?(row.key, nil)
                    self?.refreshHeading()
                }
            } catch {
                onMainThread {
                    Log.write("naming: could not detach cluster \(cluster) — \(error)")
                    row.showBusy(false)
                    row.failed("could not detach — \(Self.describe(error))")
                }
            }
        }
    }

    private func refreshHeading() {
        let open = rows.filter(\.isActionable).count
        let voices = rows.count == 1 ? "voice" : "voices"
        heading.stringValue =
            open == 0
            ? "\(rows.count) \(voices) — nothing left to name"
            : "\(open) of \(rows.count) \(voices) still "
                + (open == 1 ? "needs" : "need") + " a name"
    }

    /// What the decision actually rested on, stored server-side.
    ///
    /// Not decoration: it is what someone reads later when they wonder
    /// why this voice is called this. So it says what was true.
    private func evidenceSummary(for row: VoiceRow, personID: Int?) -> String {
        var parts: [String] = []
        let evidence = evidenceByKey[row.key]
        if let match = evidence?.candidates.first(where: { $0.personID == personID }),
            let percent = match.matchPercent, let band = match.band
        {
            parts.append("\(percent)% \(band) voiceprint match")
        }
        if let spoken = evidence?.spokenNames.first {
            parts.append("named aloud: “\(spoken)”")
        }
        if let rsvp = evidence?.candidates
            .first(where: { $0.personID == personID })?.rsvp
        {
            parts.append("invitee (\(rsvp))")
        }
        parts.append("confirmed by the operator in Atrium PA Capture")
        return parts.joined(separator: "; ")
    }

    private static func describe(_ error: Error) -> String {
        if case MCPClient.ClientError.loginRequired(let why) = error {
            return "sign in again — \(why)"
        }
        return "\(error)"
    }

    // MARK: - Layout

    private func buildContent() {
        let view = NSView()

        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(heading)

        // Outside the scroll view on purpose: a header that scrolls
        // away stops being a header the moment the list is long enough
        // to need one.
        let voiceHeader = Self.columnHeader("Voice", width: VoiceRow.Columns.name)
        voiceHeader.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [
            voiceHeader,
            Self.columnHeader("", width: VoiceRow.Columns.spinner),
            Self.columnHeader("", width: VoiceRow.Columns.play),
            Self.columnHeader("", width: VoiceRow.Columns.newButton),
            Self.columnHeader("", width: VoiceRow.Columns.detach),
            Self.columnHeader("Identify as", width: VoiceRow.Columns.choices),
        ])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = VoiceRow.Columns.spacing
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rule)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        // Hug upwards. Without this a list shorter than the window
        // spreads its rows down the whole height, which reads as a
        // layout accident rather than a short list.
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // A flipped container, or the list sits at the *bottom* of the
        // scroll view and fills the space above it with nothing. AppKit
        // measures from the bottom-left unless told otherwise, and a
        // stack view cannot be flipped, so the document view is a
        // wrapper that can be — this is why the rows appeared halfway
        // down an empty window.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        doneButton.title = "Done"
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.target = self
        doneButton.action = #selector(done)
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(doneButton)

        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            heading.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),

            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            header.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 14),
            rule.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            rule.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            rule.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),

            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: doneButton.topAnchor, constant: -12),

            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),

            doneButton.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -20),
            doneButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            doneButton.widthAnchor.constraint(equalToConstant: 90),
        ])
        contentView = view
    }

    private static func columnHeader(_ title: String, width: CGFloat) -> NSView {
        let field = NSTextField(labelWithString: title.uppercased())
        field.font = .systemFont(ofSize: 10, weight: .bold)
        field.textColor = .secondaryLabelColor
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: width).isActive = true
        return field
    }

    @objc private func done() { finish() }
}
