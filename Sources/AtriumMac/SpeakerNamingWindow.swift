import AVFoundation
import AppKit
import AtriumCore
import Foundation

/// "Who was that?" — one voice at a time.
///
/// The window exists because naming a voice is worth interrupting for
/// *once* and never again: an unnamed cluster matches nothing, so the
/// same person comes back unknown in every later recording, and naming
/// them here fixes this transcript and all of them. `name_speaker`
/// reports how many, and so does this.
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
final class SpeakerNamingWindow: NSWindow, NSTextFieldDelegate {

    /// Called with the `unknown_speakers[]` key once a voice has been
    /// named or dismissed, so the badge can come down and stay down.
    /// The name is carried too when there was one, because the activity
    /// window has no other way to learn it — reading the roster back
    /// would need `pa.read`.
    var onResolved: ((String, String?) -> Void)?

    /// One thing to ask about. Both kinds end in the same call —
    /// `name_speaker` with a person — so they share the whole window;
    /// only the heading and what is pre-filled differ.
    enum Question {
        /// Nobody has put a name to this voice.
        case unnamed(MCPClient.UnknownSpeaker)
        /// Atrium PA has, but only as a guess, and nobody has agreed.
        case unconfirmed(MCPClient.ProvisionalMatch)

        var voiceCluster: Int? {
            switch self {
            case .unnamed(let speaker): return speaker.voiceCluster
            case .unconfirmed(let match): return match.voiceCluster
            }
        }

        var key: String {
            switch self {
            case .unnamed(let speaker): return speaker.key
            case .unconfirmed(let match): return match.key
            }
        }

        var turnCount: Int {
            switch self {
            case .unnamed(let speaker): return speaker.turnCount
            case .unconfirmed(let match): return match.turnCount
            }
        }
    }

    private var item: QueueItem?
    private var client: MCPClient?
    private var queue: [Question] = []
    private var index = 0

    /// The person the user has settled on, when they picked one from a
    /// list rather than typing a new one.
    ///
    /// Cleared the moment the name field is edited by hand: at that
    /// point the typed text is the answer and the earlier selection is
    /// not. See `controlTextDidChange`.
    private var selectedPersonID: Int?
    private var evidence: MCPClient.SpeakerEvidence?
    private var player: AVAudioPlayer?

    // Views
    private let heading = NSTextField(labelWithString: "")
    private let quote = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let playButton = NSButton()
    private let candidates = NSPopUpButton()
    private let searchField = NSTextField()
    private let searchButton = NSButton()
    private let searchResults = NSPopUpButton()
    private let newName = NSTextField()
    private let newEmail = NSTextField()
    /// People the last search returned, parallel to `searchResults`.
    private var found: [MCPClient.Person] = []
    private let spinner = NSProgressIndicator()
    private let nameButton = NSButton()
    private let skipButton = NSButton()
    private let laterButton = NSButton()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        title = "Name this voice"
        isReleasedWhenClosed = false
        buildContent()
    }

    // MARK: - Presenting

    /// Shown as a sheet on the main window when there is one, so naming
    /// is part of the app rather than a second window floating loose
    /// with no obvious relationship to the recording it belongs to.
    func present(item: QueueItem, client: MCPClient, host: NSWindow?) {
        self.item = item
        self.client = client
        // Unconfirmed guesses first: they are the ones with a wrong
        // answer already applied to every turn.
        queue =
            item.provisionalSpeakers.map(Question.unconfirmed)
            + item.nameableSpeakers.map(Question.unnamed)
        index = 0

        if let host, host.isVisible {
            if isVisible { orderOut(nil) }
            host.beginSheet(self)
        } else {
            center()
            makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        showCurrent()
    }

    /// Close whichever way it was opened.
    private func finish() {
        player?.stop()
        if let host = sheetParent {
            host.endSheet(self)
        } else {
            close()
        }
    }

    private var current: Question? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    private func showCurrent() {
        player?.stop()
        player = nil
        evidence = nil
        candidates.removeAllItems()
        newName.stringValue = ""
        newEmail.stringValue = ""
        searchField.stringValue = ""
        searchResults.removeAllItems()
        searchResults.isEnabled = false
        found = []
        quote.stringValue = ""
        setBusy(true)

        guard let speaker = current, let item, let client else {
            finish()
            return
        }
        selectedPersonID = nil
        switch speaker {
        case .unnamed:
            heading.stringValue =
                "Voice \(index + 1) of \(queue.count) · \(speaker.turnCount) turns"
            nameButton.title = "Name"
        case .unconfirmed(let match):
            // Say what is already applied and how sure the server is,
            // because pressing Name here is agreeing to something that
            // has *already* been written across every turn this voice
            // spoke — the question is whether to let it stand.
            let confidence =
                match.matchPercent.map { "\($0)% \(match.band ?? "match")" }
                ?? (match.band ?? "a guess")
            heading.stringValue =
                "Voice \(index + 1) of \(queue.count) · \(speaker.turnCount) turns "
                + "· applied as \(match.displayName) on \(confidence)"
            nameButton.title = "Confirm"
            // Pre-filled into the field that decides, not held
            // invisibly somewhere else.
            newName.stringValue = match.displayName
            selectedPersonID = match.personID
        }
        detail.stringValue = "Gathering evidence…"

        guard let captureID = item.captureID, let cluster = speaker.voiceCluster else {
            detail.stringValue = "This voice cannot be named from here."
            setBusy(false)
            return
        }

        Task { [weak self] in
            do {
                let found = try await client.identifySpeaker(
                    captureID: captureID, voiceCluster: cluster)
                await MainActor.run { self?.render(found) }
            } catch {
                await MainActor.run { self?.renderFailure(error) }
            }
        }
    }

    private func render(_ found: MCPClient.SpeakerEvidence) {
        evidence = found
        setBusy(false)
        // What the window is actually showing. Without this the only way
        // to know whether the evidence arrived is to look at the screen,
        // which is not something a test can do.
        Log.write(
            "naming: cluster shows \(found.candidates.count) candidate(s), "
                + "\(found.spokenNames.count) spoken name(s), "
                + "\(found.samples.count) clip(s), status \(found.status)")

        // A declined invitee was not in the room. Dropped rather than
        // shown greyed out — a wrong suggestion costs more than a
        // missing one.
        let usable = found.candidates.filter(\.isPlausible)
        // "Someone else" first and selected, so a suggestion is never
        // the answer by default. Picking one is an act.
        candidates.addItem(withTitle: "Nobody yet — type a name below")
        candidates.lastItem?.representedObject = nil
        for candidate in usable {
            candidates.addItem(withTitle: Self.label(for: candidate))
            candidates.lastItem?.representedObject = candidate.personID
        }
        candidates.isEnabled = true
        candidates.target = self
        candidates.action = #selector(chooseCandidate)
        // An unconfirmed guess arrives with its person already in the
        // field; select the matching row so the window is not showing
        // two different answers.
        if let selectedPersonID,
            let row = candidates.itemArray.firstIndex(where: {
                $0.representedObject as? Int == selectedPersonID
            })
        {
            candidates.selectItem(at: row)
        }

        quote.stringValue = found.spokenNames.first.map { "“\($0)”" } ?? ""

        var lines: [String] = []
        if found.otherRecordings > 0 {
            lines.append(
                found.otherRecordings == 1
                    ? "also in 1 other recording"
                    : "also in \(found.otherRecordings) other recordings")
        }
        if found.status == "provisional" {
            lines.append("a name is already applied as a guess")
        }
        if let sample = found.samples.first, !sample.hasPersistedSnippet {
            // The server would have to slice the source, which its own
            // retention may already have purged. Better to say so than
            // to offer a control that fails with a 404 nobody can read.
            lines.append("this clip may no longer play")
        }
        detail.stringValue = lines.joined(separator: " · ")
        playButton.isEnabled = !found.samples.isEmpty
    }

    private func renderFailure(_ error: Error) {
        setBusy(false)
        Log.write("naming: could not gather evidence — \(error)")
        candidates.addItem(withTitle: "Someone else…")
        if case MCPClient.ClientError.loginRequired(let why) = error {
            detail.stringValue = "Sign in again — \(why)"
        } else {
            detail.stringValue = "Could not gather evidence — \(error)"
        }
    }

    private static func label(for candidate: MCPClient.SpeakerCandidate) -> String {
        var parts = [candidate.displayName]
        if let percent = candidate.matchPercent, let band = candidate.band {
            // Percentage *and* band, never one alone: the band is the
            // server's own judgement of what the number means, and 44%
            // and 91% must not read alike.
            parts.append("— \(percent)% \(band)")
        } else if let rsvp = candidate.rsvp {
            parts.append("— invited, \(rsvp)")
        }
        return parts.joined(separator: " ")
    }

    /// Copy the chosen suggestion into the name field.
    ///
    /// The field is the answer — see `chosen`. Before this, a
    /// suggestion silently outranked whatever was typed below it, so a
    /// name typed with a suggestion still selected named the suggestion
    /// instead. Two visible answers, one of them ignored.
    @objc private func chooseCandidate() {
        guard let personID = candidates.selectedItem?.representedObject as? Int else {
            // "Nobody yet" — hand the question back to the field.
            selectedPersonID = nil
            return
        }
        selectedPersonID = personID
        newName.stringValue =
            candidates.selectedItem?.title.components(separatedBy: " — ").first ?? ""
        newEmail.stringValue = ""
    }

    // MARK: - Searching for somebody already known

    @objc private func search() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        // Two characters, enforced here as well as in the client: a
        // one-letter search returns most of the address book, which is
        // not a dropdown anybody can use.
        guard query.count >= 2 else {
            detail.stringValue = "Type at least two characters to search."
            return
        }
        guard let client else { return }

        searchButton.isEnabled = false
        searchResults.removeAllItems()
        searchResults.isEnabled = false
        detail.stringValue = "Searching…"

        Task { [weak self] in
            do {
                let people = try await client.searchPeople(matching: query)
                await MainActor.run { self?.showResults(people, query: query) }
            } catch {
                await MainActor.run {
                    self?.searchButton.isEnabled = true
                    if case MCPClient.ClientError.loginRequired(let why) = error {
                        // Searching needs pa.read, which a token issued
                        // before this feature does not carry.
                        self?.detail.stringValue = "Sign in again to search — \(why)"
                    } else {
                        self?.detail.stringValue = "Search failed — \(error)"
                    }
                }
            }
        }
    }

    private func showResults(_ people: [MCPClient.Person], query: String) {
        searchButton.isEnabled = true
        found = people
        searchResults.removeAllItems()

        guard !people.isEmpty else {
            detail.stringValue = "Nobody in Atrium PA matches “\(query)”."
            return
        }
        for person in people { searchResults.addItem(withTitle: person.label) }
        searchResults.isEnabled = true
        searchResults.target = self
        searchResults.action = #selector(chooseSearchResult)
        detail.stringValue =
            people.count == 1
            ? "1 match — pick it to fill the name below"
            : "\(people.count) matches — pick one to fill the name below"
        // Nothing is chosen until it is picked, and picking fills the
        // field below. The list does not answer for you.
        chooseSearchResult()
    }

    /// Typing over a chosen person makes it a different person.
    ///
    /// Without this, editing "Alex Rivera" to "Alex Riveras" would
    /// still name person #5 — the id from the selection would outlive
    /// the name it belonged to, and the window would show one thing and
    /// do another.
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === newName else { return }
        let typed = newName.stringValue.trimmingCharacters(in: .whitespaces)
        guard let selectedPersonID else { return }
        let chosenName =
            (candidates.selectedItem?.representedObject as? Int == selectedPersonID
                ? candidates.selectedItem?.title.components(separatedBy: " — ").first
                : nil)
            ?? found.first { $0.id == selectedPersonID }?.displayName
            ?? currentProvisionalName
        if typed != chosenName {
            self.selectedPersonID = nil
            candidates.selectItem(at: 0)
            searchResults.isEnabled = false
            detail.stringValue = "Will create a new person called “\(typed)”."
        }
    }

    /// The name a provisional guess arrived with, for the comparison
    /// above.
    private var currentProvisionalName: String? {
        if case .unconfirmed(let match) = current { return match.displayName }
        return nil
    }

    /// Fill the name field from the search results.
    @objc private func chooseSearchResult() {
        guard found.indices.contains(searchResults.indexOfSelectedItem) else { return }
        let person = found[searchResults.indexOfSelectedItem]
        selectedPersonID = person.id
        newName.stringValue = person.displayName
        newEmail.stringValue = person.email ?? ""
        // The suggestion list is no longer the answer.
        candidates.selectItem(at: 0)
    }

    /// The person the user settled on.
    ///
    /// **The name field is the only input.** Every list above it writes
    /// into that field rather than competing with it, so what the window
    /// shows is what it will do. This used to be a precedence order —
    /// search beat suggestions beat the typed name — which meant a name
    /// typed under a selected suggestion was silently discarded, and the
    /// window gave no sign of which of its three answers it preferred.
    private var chosen: (id: Int?, name: String) {
        let typed = newName.stringValue.trimmingCharacters(in: .whitespaces)
        // The id only survives while the name still matches the person
        // it came from; `controlTextDidChange` drops it on any edit.
        return (selectedPersonID, typed)
    }

    // MARK: - Actions

    @objc private func play() {
        guard let sample = evidence?.samples.first, let client else { return }
        setBusy(true)
        Task { [weak self] in
            do {
                let data = try await client.fetchSample(sample)
                await MainActor.run {
                    self?.setBusy(false)
                    self?.player = try? AVAudioPlayer(data: data)
                    self?.player?.play()
                }
            } catch {
                await MainActor.run {
                    self?.setBusy(false)
                    self?.detail.stringValue = "That clip is no longer available."
                }
            }
        }
    }

    @objc private func name() {
        guard let speaker = current, let item, let client,
            let captureID = item.captureID, let cluster = speaker.voiceCluster
        else { return }

        let (personID, displayName) = chosen
        let typed = displayName
        guard !typed.isEmpty else {
            // The field is the answer, so an empty field is no answer —
            // even if a list above it has a row highlighted.
            detail.stringValue =
                "Type a name, or pick somebody above to fill it in."
            return
        }

        setBusy(true)
        let summary = evidenceSummary(personID: personID)
        let email = newEmail.stringValue.trimmingCharacters(in: .whitespaces)
        let key = speaker.key

        Task { [weak self] in
            do {
                let result = try await client.nameSpeaker(
                    captureID: captureID, voiceCluster: cluster, personID: personID,
                    newPerson: personID == nil ? (typed, email.isEmpty ? nil : email) : nil,
                    evidence: summary)
                await MainActor.run {
                    // Logged as well as shown. Otherwise there is no way
                    // to tell afterwards whether a voice was named from
                    // here or from the web UI — and that is the first
                    // question asked when a name turns out to be wrong.
                    Log.write(
                        "naming: named cluster \(cluster) as "
                            + (personID.map { "person \($0)" }
                                ?? "new person “\(typed)”")
                            + " — \(result.turnsUpdated) turn(s), "
                            + "\(result.recordingsAffected) recording(s)")
                    // The blast radius is the point: naming reaches
                    // backwards through every recording this voice is in.
                    self?.detail.stringValue =
                        "Named — \(result.turnsUpdated) turns across "
                        + "\(result.recordingsAffected) recording(s)"
                    self?.onResolved?(key, personID == nil ? typed : displayName)
                    self?.advance()
                }
            } catch {
                await MainActor.run {
                    Log.write("naming: could not name cluster \(cluster) — \(error)")
                    self?.setBusy(false)
                    self?.detail.stringValue = "Could not name — \(error)"
                }
            }
        }
    }

    /// What the decision actually rested on, stored server-side.
    ///
    /// Not decoration: it is what someone reads later when they wonder
    /// why this voice is called this. So it says what was true, not
    /// "named from atrium-mac".
    private func evidenceSummary(personID: Int?) -> String {
        var parts: [String] = []
        if let match = evidence?.candidates.first(where: { $0.personID == personID }),
            let percent = match.matchPercent, let band = match.band
        {
            parts.append("\(percent)% \(band) voiceprint match")
        }
        if let spoken = evidence?.spokenNames.first {
            parts.append("named aloud: “\(spoken)”")
        }
        if let rsvp = evidence?.candidates.first(where: { $0.personID == personID })?.rsvp {
            parts.append("invitee (\(rsvp))")
        }
        parts.append("confirmed by the operator in Atrium PA Capture")
        return parts.joined(separator: "; ")
    }

    @objc private func skip() {
        guard let speaker = current, let item, let client,
            let captureID = item.captureID, let cluster = speaker.voiceCluster
        else { return }
        let key = speaker.key
        Task { [weak self] in
            do {
                try await client.dismissSpeaker(voiceCluster: cluster)
                Log.write("naming: dismissed cluster \(cluster)")
            } catch {
                Log.write("naming: could not dismiss cluster \(cluster) — \(error)")
            }
            await MainActor.run {
                self?.onResolved?(key, nil)
                self?.advance()
            }
        }
    }

    @objc private func later() {
        finish()
    }

    /// Escape. A sheet has no close button and `performClose` does
    /// nothing on one, so without this the only way out was the "Not
    /// now" button — and a window you cannot dismiss with the key
    /// everybody reaches for feels stuck.
    override func cancelOperation(_ sender: Any?) {
        finish()
    }

    private func advance() {
        index += 1
        if current == nil {
            finish()
        } else {
            showCurrent()
        }
    }

    private func setBusy(_ busy: Bool) {
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        spinner.isHidden = !busy
        nameButton.isEnabled = !busy
        skipButton.isEnabled = !busy
    }

    // MARK: - Layout

    private func buildContent() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 420))

        heading.frame = NSRect(x: 20, y: 376, width: 390, height: 20)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        view.addSubview(heading)

        playButton.frame = NSRect(x: 20, y: 336, width: 110, height: 28)
        playButton.title = "▶ Listen"
        playButton.bezelStyle = .rounded
        playButton.target = self
        playButton.action = #selector(play)
        playButton.isEnabled = false
        view.addSubview(playButton)

        spinner.frame = NSRect(x: 142, y: 340, width: 18, height: 18)
        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        view.addSubview(spinner)

        quote.frame = NSRect(x: 20, y: 304, width: 420, height: 20)
        quote.font = .systemFont(ofSize: 12)
        quote.textColor = .secondaryLabelColor
        quote.lineBreakMode = .byTruncatingTail
        view.addSubview(quote)

        detail.frame = NSRect(x: 20, y: 280, width: 420, height: 20)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .tertiaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        view.addSubview(detail)

        view.addSubview(label("Suggestions — pick one to fill the name", y: 248))
        candidates.frame = NSRect(x: 20, y: 218, width: 420, height: 26)
        view.addSubview(candidates)

        view.addSubview(label("Search Atrium PA — pick one to fill the name", y: 188))
        searchField.frame = NSRect(x: 20, y: 158, width: 320, height: 24)
        searchField.placeholderString = "Name (at least 2 characters)"
        // Return in the field searches rather than naming: pressing
        // Enter after typing a name should look it up, not commit a new
        // person with that name.
        searchField.target = self
        searchField.action = #selector(search)
        view.addSubview(searchField)

        searchButton.frame = NSRect(x: 348, y: 156, width: 92, height: 28)
        searchButton.title = "Search"
        searchButton.bezelStyle = .rounded
        searchButton.target = self
        searchButton.action = #selector(search)
        view.addSubview(searchButton)

        searchResults.frame = NSRect(x: 20, y: 126, width: 420, height: 26)
        searchResults.isEnabled = false
        view.addSubview(searchResults)

        view.addSubview(label("This voice is:", y: 98))
        newName.frame = NSRect(x: 20, y: 68, width: 200, height: 24)
        newName.placeholderString = "Full name"
        newName.delegate = self
        view.addSubview(newName)
        newEmail.frame = NSRect(x: 228, y: 68, width: 212, height: 24)
        newEmail.placeholderString = "Email (optional)"
        view.addSubview(newEmail)

        // A sheet draws no title bar, so it has no close button unless
        // one is put there.
        let close = NSButton(frame: NSRect(x: 424, y: 388, width: 20, height: 20))
        close.bezelStyle = .circular
        close.isBordered = false
        close.image = NSImage(
            systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        close.contentTintColor = .secondaryLabelColor
        close.target = self
        close.action = #selector(later)
        close.toolTip = "Close — the voices stay on the list"
        view.addSubview(close)

        laterButton.frame = NSRect(x: 20, y: 20, width: 90, height: 30)
        laterButton.title = "Not now"
        // The canonical escape route. `cancelOperation` covers the case
        // where the window itself is first responder; a button carrying
        // the escape key equivalent covers the case where a text field
        // is, which is most of the time here.
        laterButton.keyEquivalent = "\u{1b}"
        laterButton.bezelStyle = .rounded
        laterButton.target = self
        laterButton.action = #selector(later)
        view.addSubview(laterButton)

        skipButton.frame = NSRect(x: 116, y: 20, width: 130, height: 30)
        skipButton.title = "Skip this voice"
        skipButton.bezelStyle = .rounded
        skipButton.target = self
        skipButton.action = #selector(skip)
        skipButton.toolTip =
            "Stop being asked about this voice. Nothing is deleted, and "
            + "pressing “Name voices…” on this recording again offers to bring "
            + "it back."
        view.addSubview(skipButton)

        nameButton.frame = NSRect(x: 352, y: 20, width: 88, height: 30)
        nameButton.title = "Name"
        nameButton.bezelStyle = .rounded
        nameButton.keyEquivalent = "\r"
        nameButton.target = self
        nameButton.action = #selector(name)
        view.addSubview(nameButton)

        contentView = view
    }

    private func label(_ text: String, y: CGFloat) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = NSRect(x: 20, y: y, width: 420, height: 16)
        field.font = .systemFont(ofSize: 11, weight: .medium)
        field.textColor = .secondaryLabelColor
        return field
    }
}
