import Foundation

/// One recording waiting to reach Atrium PA.
///
/// Persisted as its own JSON file so the queue survives a reboot with no
/// database and no locking: adding an item is one atomic write, and a
/// half-written file loses one recording rather than the queue.
public struct QueueItem: Codable, Equatable {

    public enum State: String, Codable {
        /// Needs an upload URL minted and the bytes PUT.
        case pending
        /// Bytes are in. Waiting for the pipeline to produce a transcript.
        case uploaded
        /// Transcript exists. The local retention clock starts here.
        case ready
        /// Refused in a way that retrying would reproduce exactly.
        case failed
    }

    public var id: UUID
    /// File names, not paths: the Recordings directory is allowed to
    /// move with the user's home directory.
    public var audioFile: String
    /// Every local file this upload came from — two per segment, since
    /// each stream is recorded separately and a meeting interrupted by
    /// sleep has more than one segment. Retention sweeps them all.
    public var masterFiles: [String]
    /// What this recording is called **locally**. Not necessarily sent.
    ///
    /// For a detected session this is a label for the source — "Teams
    /// meeting", "WhatsApp call" — which is useful in this app's own
    /// list and wrong to send upstream. See `titleIsHumanSupplied`.
    public var title: String?

    /// Whether `title` came from a person rather than from whichever
    /// process happened to hold the microphone.
    ///
    /// On the server, `title` means "what this recording is about". It
    /// is the primary label in the captures list and carries a scoring
    /// bonus over the body in keyword search. A source label therefore
    /// makes every Teams recording identical in the list and matches
    /// every search for "teams" or "meeting" — measured, 33 of the last
    /// 43 uploads were affected.
    ///
    /// So a source label stays here and is never sent. Sending nothing
    /// is better than sending something wrong: the server generates a
    /// title from the transcript, which is a description of the content
    /// rather than of the app that captured it. Nothing is lost either
    /// way — the capturing process is already in the filename
    /// (`20260824-090544-modulehost.m4a`), which the server keeps.
    public var titleIsHumanSupplied: Bool = false

    public var occurredAt: Date
    public var language: String?
    public var sizeBytes: Int
    public var state: State
    public var captureID: Int?
    public var transcriptID: Int?
    public var attempts: Int
    public var nextAttemptAt: Date
    public var lastError: String?
    public var enqueuedAt: Date
    public var completedAt: Date?

    /// Voices in the finished transcript nobody has named.
    ///
    /// Kept on the item rather than re-fetched, because the meeting may
    /// have finished while the laptop was shut: the notification and the
    /// menu badge both have to survive a reboot, and the poll that
    /// learned this may not happen again.
    public var unknownSpeakers: [MCPClient.UnknownSpeaker]

    /// Set once the "transcript ready" notification has been posted, so
    /// a restart does not announce the same meeting twice.
    public var notifiedAt: Date?

    /// Voices Atrium PA has already put a name to, but only as a guess,
    /// and which nobody has confirmed. They do not appear in
    /// `unknownSpeakers` — the server considers them answered — so
    /// without this the app would show nothing to do while the web UI
    /// asks for a confirmation.
    public var provisionalSpeakers: [MCPClient.ProvisionalMatch] = []

    /// Names this app asked for, in the order it asked.
    ///
    /// **Not what the window shows.** It once was, on the reasoning that
    /// reading the roster back needed `pa.read` and this app did not
    /// have it. It does now — `knownSpeakers` is the server's answer —
    /// and the two had already drifted: capture 12359 recorded
    /// "Dana Ellis" here while Atrium PA had Alex Rivera, and the
    /// window believed the local copy because nothing compared them.
    ///
    /// Kept because it is a record of what was done from this Mac, which
    /// is the first question when a name turns out to be wrong.
    public var namedSpeakers: [String]

    /// Who the server says was in this recording. The roster, refreshed
    /// alongside the unnamed and unconfirmed lists.
    public var knownSpeakers: [MCPClient.TranscriptSpeaker] = []

    /// Absolute directory these files live in.
    ///
    /// Stamped at enqueue rather than derived, because the recordings
    /// folder is configurable and a recording does not move when the
    /// setting does. `nil` means "wherever recordings go now", which is
    /// what every item written before this field existed says — and is
    /// correct for them, since the folder could not be changed then.
    public var directory: String?

    public init(
        id: UUID,
        audioFile: String,
        masterFiles: [String],
        title: String?,
        titleIsHumanSupplied: Bool = false,
        occurredAt: Date,
        language: String?,
        sizeBytes: Int,
        state: State,
        captureID: Int?,
        transcriptID: Int?,
        attempts: Int,
        nextAttemptAt: Date,
        lastError: String?,
        enqueuedAt: Date,
        completedAt: Date?,
        unknownSpeakers: [MCPClient.UnknownSpeaker] = [],
        notifiedAt: Date? = nil,
        namedSpeakers: [String] = [],
        directory: String? = nil,
        provisionalSpeakers: [MCPClient.ProvisionalMatch] = [],
        knownSpeakers: [MCPClient.TranscriptSpeaker] = []
    ) {
        self.id = id
        self.audioFile = audioFile
        self.masterFiles = masterFiles
        self.title = title
        self.titleIsHumanSupplied = titleIsHumanSupplied
        self.occurredAt = occurredAt
        self.language = language
        self.sizeBytes = sizeBytes
        self.state = state
        self.captureID = captureID
        self.transcriptID = transcriptID
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
        self.enqueuedAt = enqueuedAt
        self.completedAt = completedAt
        self.unknownSpeakers = unknownSpeakers
        self.notifiedAt = notifiedAt
        self.namedSpeakers = namedSpeakers
        self.directory = directory
        self.provisionalSpeakers = provisionalSpeakers
        self.knownSpeakers = knownSpeakers
    }

    /// Decoding tolerates a file written by an older build.
    ///
    /// The synthesized `Codable` will not: a non-optional field added
    /// later has no key in a file written before it existed, so decoding
    /// throws and the item is unreadable. That is not a cosmetic
    /// problem here — an unreadable item is a recording that has
    /// vanished from the queue, which is exactly what the durable queue
    /// exists to prevent. Measured: adding `namedSpeakers` orphaned a
    /// real, already-uploaded capture.
    ///
    /// Fields present since the first version stay required, so a
    /// genuinely corrupt file is still reported as one.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        audioFile = try c.decode(String.self, forKey: .audioFile)
        masterFiles = try c.decodeIfPresent([String].self, forKey: .masterFiles) ?? []
        title = try c.decodeIfPresent(String.self, forKey: .title)
        occurredAt = try c.decode(Date.self, forKey: .occurredAt)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        sizeBytes = try c.decode(Int.self, forKey: .sizeBytes)
        state = try c.decode(State.self, forKey: .state)
        captureID = try c.decodeIfPresent(Int.self, forKey: .captureID)
        transcriptID = try c.decodeIfPresent(Int.self, forKey: .transcriptID)
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        nextAttemptAt = try c.decodeIfPresent(Date.self, forKey: .nextAttemptAt) ?? .distantPast
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        enqueuedAt = try c.decodeIfPresent(Date.self, forKey: .enqueuedAt) ?? occurredAt
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        unknownSpeakers =
            try c.decodeIfPresent([MCPClient.UnknownSpeaker].self, forKey: .unknownSpeakers)
            ?? []
        notifiedAt = try c.decodeIfPresent(Date.self, forKey: .notifiedAt)
        namedSpeakers = try c.decodeIfPresent([String].self, forKey: .namedSpeakers) ?? []
        // Absent means an item written before the distinction existed,
        // and everything written then carried a source-derived title.
        // Defaulting to false is therefore both the safe answer and the
        // true one — it cannot resurrect a "Teams meeting" title on a
        // retry of an old queue file.
        titleIsHumanSupplied =
            try c.decodeIfPresent(Bool.self, forKey: .titleIsHumanSupplied) ?? false
        directory = try c.decodeIfPresent(String.self, forKey: .directory)
        provisionalSpeakers =
            try c.decodeIfPresent(
                [MCPClient.ProvisionalMatch].self, forKey: .provisionalSpeakers) ?? []
        knownSpeakers =
            try c.decodeIfPresent(
                [MCPClient.TranscriptSpeaker].self, forKey: .knownSpeakers) ?? []
    }

    /// What the activity window shows in the Status column.
    public var statusDescription: String {
        switch state {
        case .pending: return lastError == nil ? "waiting to upload" : "retrying"
        case .uploaded: return "transcribing"
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }

    /// What it shows under Speakers.
    public var speakerDescription: String {
        let unnamed = nameableSpeakers.count
        let unconfirmed = provisionalSpeakers.count

        // Settled names first — the server's, not ours. A voice matched
        // at high confidence and anchored is somebody Atrium PA is sure
        // about; anything less is counted below as work, not shown as a
        // name.
        let settled = knownSpeakers.filter { !$0.isProvisional }.map(\.displayName)

        var parts: [String] = []
        if !settled.isEmpty { parts.append(settled.joined(separator: ", ")) }
        if unnamed > 0 { parts.append("\(unnamed) unnamed") }
        if unconfirmed > 0 { parts.append("\(unconfirmed) to confirm") }
        if !parts.isEmpty { return parts.joined(separator: " · ") }

        // Known to be unnamed, but not yet nameable. Voice clustering
        // finishes *after* the transcript is ready, and an entry with no
        // `voice_cluster_id` cannot be named through the API — so the
        // server can be reporting two unnamed voices while this app can
        // act on neither.
        let waiting = unknownSpeakers.count - unnamed
        if waiting > 0 {
            return waiting == 1
                ? "1 unnamed, still matching" : "\(waiting) unnamed, still matching"
        }

        // Not "all identified". An empty `unknown_speakers` means the
        // server is offering nothing to name — which also happens when
        // a voice was dismissed, or when diarization attributed nothing
        // at all. Measured: transcript 846 reports `speakers: []` and
        // `unknown_speakers: []`, so "all identified" was the exact
        // opposite of the truth.
        return state == .ready ? "nothing to name" : "—"
    }

    /// Voices that can actually be named through the API.
    public var nameableSpeakers: [MCPClient.UnknownSpeaker] {
        unknownSpeakers.filter(\.isNameable)
    }

    /// Everything waiting on a human: voices with no name, and names
    /// applied as a guess. Both are questions; only one of them was ever
    /// asked.
    public var openSpeakerQuestions: Int {
        nameableSpeakers.count + provisionalSpeakers.count
    }

    /// The folder this recording's files are actually in.
    private var folder: URL {
        directory.map { URL(fileURLWithPath: $0) } ?? AppPaths.recordings
    }

    public var audioURL: URL { folder.appending(path: audioFile) }
    public var masterURLs: [URL] { masterFiles.map { folder.appending(path: $0) } }
}

/// Durable, unattended delivery of finished recordings to Atrium PA.
///
/// Auto-upload means nobody is watching when it fails, which is the
/// whole argument for a queue on disk rather than a retry loop in
/// memory (DESIGN.md #10). Lid-close mid-meeting is normal; so is
/// closing the laptop and opening it on a different network an hour
/// later.
///
/// ## Re-minting, and why a retry never reuses a URL
///
/// The upload URL is one-shot and expires after 30 minutes. A retry
/// therefore always restarts from `upload_audio`, never from the URL it
/// was handed last time. That is safe to do even when the previous
/// attempt may have succeeded: ingest is keyed on the sha256 of the
/// bytes, so re-uploading an identical file returns the capture that
/// already exists instead of transcribing it twice.
///
/// ## The awkward interval
///
/// `capture_id` is persisted the moment `upload_audio` returns, before
/// the PUT is attempted. A crash in between then leaves an item that
/// knows its capture but not whether the bytes landed —
/// `get_upload_status` answers that: `awaiting_upload` means they did
/// not, and the item goes back to `pending` for a fresh URL.
public actor UploadQueue {

    public struct Summary: Sendable, Equatable {

        public init() {}
        public var pending = 0
        public var uploaded = 0
        public var ready = 0
        public var failed = 0
        public var lastError: String?
        public var isConfigured = false
        /// Voices waiting to be named, across every recording.
        public var unnamedVoices = 0

        public var hasWork: Bool { pending > 0 || uploaded > 0 }
    }

    /// Atrium PA's `upload_audio_max_bytes`. Checked here so an
    /// oversized file fails locally with a clear reason instead of
    /// burning a mint/PUT round trip to be told the same thing.
    public static let maxUploadBytes = 300 * 1024 * 1024

    /// How often the queue wakes up to look for work.
    private let tickInterval: TimeInterval = 20
    /// Gap between status polls once the bytes are in. Transcription of
    /// a long recording takes minutes, so a tighter poll is just load.
    private let pollInterval: TimeInterval = 30

    private var items: [UUID: QueueItem] = [:]
    private var config: AtriumConfig
    /// Set by the self-test so the queue can be driven against a stubbed
    /// transport. Nothing in the app sets it — the app always resolves a
    /// client from the config and the keychain.
    private var clientOverride: MCPClient?
    private var runner: Task<Void, Never>?
    private var isDraining = false

    /// Called on every state change so the menu bar can show a count.
    private let onChange: @Sendable (Summary) -> Void

    /// Called once per recording, when its transcript first lands.
    /// Separate from `onChange` because it fires exactly once and
    /// carries the item — it is what the notification is posted from.
    private var onReady: (@Sendable (QueueItem) -> Void)?

    /// Called when voices that arrived unnameable become nameable. A
    /// separate hook from `onReady` because it happens after the
    /// "transcript ready" notification has already been posted, and it
    /// is the one that has something to ask for.
    private var onSpeakersBecameNameable: (@Sendable (QueueItem) -> Void)?

    public func setOnSpeakersBecameNameable(
        _ handler: @escaping @Sendable (QueueItem) -> Void
    ) {
        onSpeakersBecameNameable = handler
    }

    /// Set the ready hook. An actor's stored properties cannot be
    /// assigned from outside it, so this is the door.
    public func setOnReady(_ handler: @escaping @Sendable (QueueItem) -> Void) {
        onReady = handler
    }

    public init(config: AtriumConfig, onChange: @escaping @Sendable (Summary) -> Void) {
        self.config = config
        self.onChange = onChange
    }

    // MARK: - Lifecycle

    public func start() {
        loadFromDisk()
        publish()
        guard runner == nil else { return }
        let interval = UInt64(tickInterval * 1_000_000_000)
        runner = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    public func stop() {
        runner?.cancel()
        runner = nil
    }

    public func setClientForTesting(_ client: MCPClient) {
        clientOverride = client
    }

    public func updateConfig(_ config: AtriumConfig) {
        self.config = config
        publish()
    }

    // MARK: - Enqueue

    /// Take ownership of a finished recording.
    ///
    /// `audioURL` is the `.m4a` that gets uploaded; `masterURL` is the
    /// 48 kHz stereo CAF, kept locally under the same retention clock
    /// and never sent.
    @discardableResult
    public func enqueue(
        audioURL: URL, masterURLs: [URL] = [], title: String?, occurredAt: Date
    ) -> QueueItem? {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: audioURL.path)
        let sizeBytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard sizeBytes > 0 else {
            Log.write("atrium-mac: refusing to queue an empty file at \(audioURL.path)")
            return nil
        }

        var item = QueueItem(
            id: UUID(),
            audioFile: audioURL.lastPathComponent,
            masterFiles: masterURLs.map { $0.lastPathComponent },
            title: title,
            occurredAt: occurredAt,
            language: config.language,
            sizeBytes: sizeBytes,
            state: .pending,
            captureID: nil,
            transcriptID: nil,
            attempts: 0,
            nextAttemptAt: Date(),
            lastError: nil,
            enqueuedAt: Date(),
            completedAt: nil,
            // Absolute, and recorded now. The folder is configurable,
            // and a recording does not move when the setting does.
            directory: audioURL.deletingLastPathComponent().path)

        if sizeBytes > Self.maxUploadBytes {
            item.state = .failed
            item.lastError =
                "\(sizeBytes) bytes exceeds Atrium PA's \(Self.maxUploadBytes)-byte "
                + "per-file limit"
        }

        items[item.id] = item
        persist(item)
        publish()
        Task { await self.tick() }
        return item
    }

    /// Put every failed item back in the queue. The menu's manual
    /// retry — a failure caused by a mis-typed base URL or an unminted
    /// client should not need the file re-recorded.
    public func retryFailed() {
        for (id, var item) in items where item.state == .failed {
            guard item.sizeBytes <= Self.maxUploadBytes else { continue }
            item.state = item.captureID == nil ? .pending : .uploaded
            item.attempts = 0
            item.nextAttemptAt = Date()
            item.lastError = nil
            items[id] = item
            persist(item)
        }
        publish()
        Task { await self.tick() }
    }

    public func summary() -> Summary { currentSummary() }

    /// Record that a voice has been dealt with — named or dismissed — so
    /// the badge goes down and stays down across a restart.
    public func resolveSpeaker(itemID: UUID, key: String, namedAs name: String? = nil) {
        guard var item = items[itemID] else { return }
        item.unknownSpeakers.removeAll { $0.key == key }
        if let name, !name.isEmpty, !item.namedSpeakers.contains(name) {
            item.namedSpeakers.append(name)
        }
        items[itemID] = item
        persist(item)
        publish()
    }

    /// Remember that this recording has been announced, so a restart
    /// does not announce it again.
    public func markNotified(itemID: UUID) {
        guard var item = items[itemID], item.notifiedAt == nil else { return }
        item.notifiedAt = Date()
        items[itemID] = item
        persist(item)
    }

    /// How long after a transcript lands to keep asking who was in it.
    ///
    /// `ready` means readable, not finished: voice clustering runs on
    /// afterwards, and until it does an unnamed voice arrives with no
    /// `voice_cluster_id` and cannot be named. Measured on capture
    /// 12359 — at the moment the queue stopped polling, two unnamed
    /// speakers, neither with a cluster; minutes later both had one and
    /// one had been matched to a person. Nothing re-asked, so the app
    /// showed "nothing to name" against a web UI showing two.
    private let speakerFollowUpWindow: TimeInterval = 30 * 60
    private let speakerFollowUpInterval: TimeInterval = 120

    /// In memory rather than on the item: a restart re-checking a few
    /// captures costs one request each and saves a schema field.
    private var lastSpeakerCheck: [UUID: Date] = [:]

    /// The last pipeline state reported per item, so a poll every 30
    /// seconds logs transitions rather than repetitions.
    private var lastReportedStatus: [UUID: String] = [:]

    /// Once per launch. See `backfillRosters`.
    private var didBackfillRosters = false

    /// Re-ask about recently finished recordings whose speakers are not
    /// yet actionable.
    private func followUpOnSpeakers(using client: MCPClient) async {
        let now = Date()
        let due = items.values.filter { item in
            guard item.state == .ready, item.captureID != nil,
                let completedAt = item.completedAt,
                now.timeIntervalSince(completedAt) < speakerFollowUpWindow
            else { return false }
            // Everything in the window, not only items with nothing to
            // show. A recording can have an unnamed voice *and* a
            // guessed name still to be confirmed, and the guess arrives
            // later than the transcript — so "we already have something
            // to do" was a reason to stop asking that hid the other
            // half. The window and the rate limit are what bound this.
            let last = lastSpeakerCheck[item.id] ?? .distantPast
            return now.timeIntervalSince(last) >= speakerFollowUpInterval
        }

        for item in due {
            lastSpeakerCheck[item.id] = now
            let before = item.nameableSpeakers.count
            let refreshed = await refreshSpeakers(itemID: item.id)
            if let refreshed, refreshed.nameableSpeakers.count > before {
                Log.write(
                    "capture \(item.captureID ?? 0): "
                        + "\(refreshed.nameableSpeakers.count) voice(s) became "
                        + "nameable after the transcript was ready")
                onSpeakersBecameNameable?(refreshed)
            }
        }
    }

    /// Fetch the roster once for finished recordings that have never
    /// had one.
    ///
    /// Everything uploaded before the roster was read from the server
    /// has an empty `knownSpeakers` and, quite possibly, a stale local
    /// list of names this app once asked for. The follow-up window is 30
    /// minutes from completion, so it will never revisit them. This is
    /// the one-off catch-up, run at startup, bounded to items that have
    /// nothing at all.
    private func backfillRosters(using client: MCPClient) async {
        let missing = items.values.filter {
            $0.state == .ready && $0.captureID != nil && $0.transcriptID != nil
                && $0.knownSpeakers.isEmpty
        }
        guard !missing.isEmpty else { return }
        Log.write("queue: reading the speaker roster for \(missing.count) recording(s)")
        for item in missing {
            lastSpeakerCheck[item.id] = Date()
            await refreshSpeakers(itemID: item.id)
        }
        publish()
    }

    /// Re-ask the server about everything, now.
    ///
    /// What the Refresh button does. The queue polls on its own timer and
    /// stops entirely once an item is terminal, so between those points
    /// the window can be showing a state the server left some time ago —
    /// a transcript that has since finished, or voices that have since
    /// been clustered. This is the "no, ask again" that a person needs
    /// when they can see the web UI saying something different.
    ///
    /// Ignores the follow-up window and the rate limit: it was asked for
    /// explicitly.
    public func refreshAll() async {
        // Anything unfinished becomes due immediately.
        for (id, item) in items where item.state == .pending || item.state == .uploaded {
            var due = item
            due.nextAttemptAt = Date()
            items[id] = due
        }
        await tick()

        // And every finished one is re-asked about its speakers.
        let finished = items.values.filter { $0.state == .ready && $0.captureID != nil }
        for item in finished {
            lastSpeakerCheck[item.id] = Date()
            await refreshSpeakers(itemID: item.id)
        }
        Log.write("queue: refreshed \(items.count) item(s) on request")
        publish()
    }

    /// Ask the server again which voices in this recording are unnamed.
    ///
    /// The list on the item is a snapshot taken when the transcript
    /// landed, and the queue stops polling once an item is terminal — so
    /// it can be hours stale, and it is wrong in both directions.
    /// Diarization can attribute a voice after the fact, and a voice
    /// dismissed from the web UI stops being offered. Naming is a
    /// deliberate act on one recording, so re-asking first costs one
    /// request at exactly the moment somebody is about to act on the
    /// answer.
    ///
    /// Returns the refreshed item, or nil if there is nothing to ask
    /// about or nobody to ask.
    @discardableResult
    public func refreshSpeakers(itemID: UUID) async -> QueueItem? {
        guard let item = items[itemID], let captureID = item.captureID else {
            return nil
        }
        guard case .success(let client) = resolveClient() else { return items[itemID] }

        do {
            let status = try await client.uploadStatus(captureID: captureID)

            // Names applied as a guess live in `speakers[]`, not in
            // `unknown_speakers[]`, so they need their own question.
            var roster: [MCPClient.TranscriptSpeaker] = []
            if let transcriptID = item.transcriptID {
                roster = (try? await client.speakers(transcriptID: transcriptID)) ?? []
            }
            let provisional: [MCPClient.ProvisionalMatch] = roster
                .filter(\.isProvisional)
                .compactMap { speaker in
                    guard let cluster = speaker.voiceCluster,
                        let person = speaker.personID
                    else { return nil }
                    return MCPClient.ProvisionalMatch(
                        key: speaker.key, voiceCluster: cluster, personID: person,
                        displayName: speaker.displayName,
                        matchPercent: speaker.matchPercent, band: speaker.band,
                        turnCount: speaker.turnCount)
                }

            guard var current = items[itemID] else { return nil }
            if current.knownSpeakers != roster {
                Log.write(
                    "queue: capture \(captureID) roster is now "
                        + (roster.isEmpty
                            ? "empty"
                            : roster.map(\.displayName).joined(separator: ", ")))
                current.knownSpeakers = roster
                items[itemID] = current
                persist(current)
            }
            if current.provisionalSpeakers != provisional {
                Log.write(
                    "queue: capture \(captureID) has \(provisional.count) "
                        + "unconfirmed match(es), was "
                        + "\(current.provisionalSpeakers.count)")
                current.provisionalSpeakers = provisional
                items[itemID] = current
                persist(current)
                publish()
            }
            if current.unknownSpeakers != status.unknownSpeakers {
                Log.write(
                    "queue: capture \(captureID) now reports "
                        + "\(status.unknownSpeakers.count) unnamed voice(s), was "
                        + "\(current.unknownSpeakers.count)")
                current.unknownSpeakers = status.unknownSpeakers
                items[itemID] = current
                persist(current)
                publish()
            }
            return current
        } catch {
            Log.write("queue: could not re-check speakers on \(captureID) — \(error)")
            return items[itemID]
        }
    }

    /// Bytes as something a person can read.
    static func readableSize(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: value < 10 && unit > 0 ? "%.1f %@" : "%.0f %@",
                      value, units[unit])
    }

    /// Delete a recording from this machine.
    ///
    /// The audio, the masters and the queue entry — everything this app
    /// put on disk for it. What it cannot touch is Atrium PA's own copy
    /// and transcript: deleting a capture there is gated on `pa.write`,
    /// which is the browser session's permission and not this app's
    /// bearer, and there is no MCP tool for it. So this is honestly a
    /// *local* delete, and the caller says so.
    ///
    /// Returns what was actually removed, for the log — a delete that
    /// silently found nothing is worth telling apart from one that
    /// worked.
    @discardableResult
    public func deleteItem(id: UUID) -> [String] {
        guard let item = items[id] else { return [] }
        var removed: [String] = []
        for url in [item.audioURL] + item.masterURLs {
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed.append(url.lastPathComponent)
            }
        }
        items[id] = nil
        try? FileManager.default.removeItem(at: itemURL(id))
        publish()
        Log.write(
            "deleted \(item.audioFile) locally — removed "
                + (removed.isEmpty ? "no files (already gone)"
                    : removed.joined(separator: ", ")))
        return removed
    }

    /// Pin every item that has no directory to `folder`.
    ///
    /// Called just before the recordings folder changes. Items written
    /// before this field existed — and any written while the default was
    /// in force — say nothing about where they are, which means "wherever
    /// recordings go now". That answer stops being true the moment the
    /// setting moves, so it is written down first. Without this, changing
    /// the folder would leave a queue whose every file had vanished.
    public func pinDirectories(to folder: URL) {
        for (id, item) in items where item.directory == nil {
            var pinned = item
            pinned.directory = folder.path
            items[id] = pinned
            persist(pinned)
        }
        Log.write("queue: pinned existing recordings to \(folder.path)")
    }

    private func resolveClient() -> Result<MCPClient, MCPClient.ClientError> {
        if let clientOverride { return .success(clientOverride) }
        return MCPClient.shared(config: config)
    }

    /// Every recording still carrying voices to name, newest first.
    public func awaitingNames() -> [QueueItem] {
        items.values
            .filter { !$0.nameableSpeakers.isEmpty }
            .sorted { $0.enqueuedAt > $1.enqueuedAt }
    }

    public func allItems() -> [QueueItem] {
        items.values.sorted { $0.enqueuedAt > $1.enqueuedAt }
    }

    // MARK: - The loop

    /// One pass: sweep retention, then work the queue until nothing is
    /// due. Exposed so a test can drive it deterministically instead of
    /// waiting on the timer.
    public func tick() async {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        sweepRetention()

        guard config.uploadEnabled else { return }
        let client: MCPClient
        switch resolveClient() {
        case .success(let made):
            client = made
        case .failure(let error):
            // Not an item failure — nothing has been attempted. Items
            // stay pending and the menu says what is missing.
            recordGlobal(error: error.description)
            return
        }

        while let item = nextDueItem() {
            await process(item, using: client)
        }
        await followUpOnSpeakers(using: client)
        if !didBackfillRosters {
            didBackfillRosters = true
            await backfillRosters(using: client)
        }
        publish()
    }

    private func nextDueItem() -> QueueItem? {
        let now = Date()
        return items.values
            .filter { ($0.state == .pending || $0.state == .uploaded) && $0.nextAttemptAt <= now }
            .sorted { $0.enqueuedAt < $1.enqueuedAt }
            .first
    }

    private func process(_ item: QueueItem, using client: MCPClient) async {
        var item = item
        do {
            switch item.state {
            case .pending:
                try await send(&item, using: client)
            case .uploaded:
                try await poll(&item, using: client)
            case .ready, .failed:
                return
            }
            item.attempts = 0
            // Not on a terminal failure. `poll` records the pipeline's
            // own explanation and returns *normally* — it did not throw,
            // because nothing went wrong on this side — so clearing the
            // error here wiped the only account of why a recording never
            // became a transcript. Observed as a queue item reading
            // `failed` with `lastError: null`, where the server had said
            // "the recording produced no speech".
            if item.state != .failed { item.lastError = nil }
        } catch let error as MCPClient.ClientError {
            note(&item, error: error.description, retryable: error.isRetryable)
        } catch {
            // URLSession transport errors — offline, DNS, TLS. Always
            // worth retrying; this is the lid-closed-on-a-train case.
            note(&item, error: error.localizedDescription, retryable: true)
        }
        items[item.id] = item
        persist(item)
        publish()
    }

    private func send(_ item: inout QueueItem, using client: MCPClient) async throws {
        guard FileManager.default.fileExists(atPath: item.audioURL.path) else {
            item.state = .failed
            item.lastError = "the audio file is gone from disk"
            return
        }

        Log.write(
            "upload: asking for a URL for \(item.audioFile) "
                + "(\(Self.readableSize(item.sizeBytes)), "
                + (item.titleIsHumanSupplied
                    ? "“\(item.title ?? "")”)" : "no title — the server will "
                        + "derive one from the transcript)")
                + (item.attempts > 0 ? " — attempt \(item.attempts + 1)" : ""))

        let ticket = try await client.requestUpload(
            filename: item.audioFile,
            sizeBytes: item.sizeBytes,
            title: item.titleIsHumanSupplied ? item.title : nil,
            occurredAt: item.occurredAt,
            language: item.language)
        Log.write(
            "upload: capture \(ticket.captureID) reserved, URL good for "
                + "\(ticket.expiresIn)s")

        // Persisted before the PUT: a crash during the transfer must
        // leave something we can ask about rather than a capture we
        // have forgotten the id of.
        item.captureID = ticket.captureID
        items[item.id] = item
        persist(item)

        let started = Date()
        try await client.putAudio(fileURL: item.audioURL, to: ticket.uploadURL)
        let seconds = Date().timeIntervalSince(started)
        Log.write(
            String(
                format: "upload: capture %d sent %@ in %.1fs (%@/s)",
                ticket.captureID, Self.readableSize(item.sizeBytes), seconds,
                Self.readableSize(Int(Double(item.sizeBytes) / max(seconds, 0.001)))))

        item.state = .uploaded
        item.nextAttemptAt = Date().addingTimeInterval(pollInterval)
    }

    private func poll(_ item: inout QueueItem, using client: MCPClient) async throws {
        guard let captureID = item.captureID else {
            item.state = .pending
            item.nextAttemptAt = Date()
            return
        }

        let status = try await client.uploadStatus(captureID: captureID)

        // Only when it moves. Polling every 30 seconds and logging each
        // answer would bury the transitions in repetitions of the same
        // one, which is exactly what the activity window used to do to
        // this file.
        if status.status != lastReportedStatus[item.id] {
            lastReportedStatus[item.id] = status.status
            Log.write(
                "pipeline: capture \(captureID) is \(status.status)"
                    + (status.detail.map { " — \($0)" } ?? ""))
        }

        switch status.status {
        case "ready":
            item.state = .ready
            item.transcriptID = status.transcriptID
            item.completedAt = Date()
            item.nextAttemptAt = .distantFuture
            item.unknownSpeakers = status.unknownSpeakers
            Log.write(
                "pipeline: capture \(captureID) ready — transcript "
                    + "\(status.transcriptID.map(String.init) ?? "?"), "
                    + {
                        let total = status.unknownSpeakers.count
                        let actionable = status.unknownSpeakers.filter(\.isNameable).count
                        if total == 0 { return "no voices to name" }
                        if actionable == total { return "\(total) unnamed voice(s)" }
                        // The difference is voices the server knows are
                        // unnamed but has not finished clustering, which
                        // cannot be named yet. Saying only the total made
                        // the notification below look wrong when it
                        // reported the actionable count.
                        return "\(total) unnamed voice(s), \(actionable) nameable "
                            + "so far"
                    }()
                    + String(
                        format: ", %.0fs after it was queued",
                        Date().timeIntervalSince(item.enqueuedAt)))
            onReady?(item)
        case "failed":
            item.state = .failed
            item.lastError = status.detail ?? "the pipeline reported a failure"
            Log.write(
                "pipeline: capture \(captureID) FAILED — \(item.lastError ?? "")"
                    + ". The audio stays on disk.")
        case "awaiting_upload":
            Log.write(
                "pipeline: capture \(captureID) never received the bytes — "
                    + "starting again with a fresh URL")
            // The bytes never landed, or the reservation outlived them.
            // Start over with a fresh URL — never re-PUT the old one.
            item.state = .pending
            item.captureID = nil
            item.nextAttemptAt = Date()
        default:
            item.nextAttemptAt = Date().addingTimeInterval(pollInterval)
        }
    }

    // MARK: - Failure bookkeeping

    private func note(_ item: inout QueueItem, error: String, retryable: Bool) {
        item.lastError = error
        item.attempts += 1
        guard retryable else {
            item.state = .failed
            Log.write(
                "upload: \(item.audioFile) gave up after \(item.attempts) attempt(s) "
                    + "— \(error). The audio stays on disk.")
            return
        }
        // Exponential, capped at an hour, with jitter so a queue of
        // items that all failed at once does not retry in lockstep.
        let backoff = min(60 * pow(2, Double(item.attempts - 1)), 3600)
        item.nextAttemptAt = Date().addingTimeInterval(
            backoff + Double.random(in: 0...min(backoff * 0.2, 60)))
        Log.write(
            String(
                format: "upload: %@ failed (attempt %d) — %@. Trying again in ~%.0fs.",
                item.audioFile, item.attempts, error, backoff))
    }

    private func recordGlobal(error: String) {
        var summary = currentSummary()
        summary.lastError = error
        onChange(summary)
    }

    // MARK: - Retention

    /// Delete local copies once Atrium PA has confirmed the transcript
    /// and the retention window has passed (DESIGN.md #11 — long enough
    /// to re-drive a failed transcription, bounded disk use).
    ///
    /// Only `ready` items are swept. A failed upload keeps its audio
    /// indefinitely: it is the only copy, and deleting it would make the
    /// failure permanent.
    /// Two tiers, because the two files are worth very different
    /// amounts.
    ///
    /// The 48 kHz masters are 41× the size of the uploaded AAC — 690 MB
    /// an hour against 17 — and buy nothing today, since the server
    /// downmixes to 16 kHz mono anyway. The `.m4a` is the copy worth
    /// keeping: small, playable, re-uploadable, and after Atrium PA
    /// sweeps its own vault at ~90 days it is the only copy of a meeting
    /// that exists anywhere.
    ///
    /// Both windows count from `completedAt`, and both only ever touch
    /// a `ready` item — a failed upload keeps its audio indefinitely,
    /// because it is the only copy and deleting it would make the
    /// failure permanent.
    private func sweepRetention() {
        /// `nil` means never. Negative days is the sentinel for "keep
        /// it", so that `0` can keep its literal meaning: delete as
        /// soon as the upload has landed.
        func cutoff(_ days: Int) -> Date? {
            days < 0 ? nil : Date().addingTimeInterval(-Double(days) * 86_400)
        }

        // Tier one: the masters, on their own clock.
        if let masterCutoff = cutoff(config.masterRetentionDays) {
            for (id, item) in items {
                guard item.state == .ready, !item.masterFiles.isEmpty,
                    let completedAt = item.completedAt, completedAt < masterCutoff
                else { continue }
                for master in item.masterURLs {
                    try? FileManager.default.removeItem(at: master)
                }
                var trimmed = item
                // Cleared, not merely deleted from disk: the list is
                // what a later sweep and the activity window read, and
                // an item still claiming files that are gone is an item
                // that lies about what it has.
                trimmed.masterFiles = []
                items[id] = trimmed
                persist(trimmed)
                Log.write(
                    "retention: dropped the masters for \(item.audioFile) "
                        + "(\(item.masterFiles.count) file(s))")
            }
        }

        // Tier two: the upload, and with it the queue entry.
        guard let uploadCutoff = cutoff(config.localRetentionDays) else { return }
        for (id, item) in items {
            guard item.state == .ready, let completedAt = item.completedAt,
                completedAt < uploadCutoff
            else { continue }
            try? FileManager.default.removeItem(at: item.audioURL)
            for master in item.masterURLs {
                try? FileManager.default.removeItem(at: master)
            }
            items[id] = nil
            try? FileManager.default.removeItem(at: itemURL(id))
            Log.write("retention: removed \(item.audioFile) and its queue entry")
        }
    }

    // MARK: - Persistence

    private func itemURL(_ id: UUID) -> URL {
        AppPaths.queue.appending(path: "\(id.uuidString).json")
    }

    private func persist(_ item: QueueItem) {
        do {
            try AppPaths.ensureDirectories()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(item).write(to: itemURL(item.id), options: .atomic)
        } catch {
            Log.write("atrium-mac: could not persist queue item \(item.id) — \(error)")
        }
    }

    private func loadFromDisk() {
        try? AppPaths.ensureDirectories()
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: AppPaths.queue, includingPropertiesForKeys: nil)
        else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                var item = try? decoder.decode(QueueItem.self, from: data)
            else {
                // A file we cannot read is a file we cannot act on.
                // Leave it: a truncated item is evidence, and deleting
                // it would be the app quietly discarding a meeting.
                Log.write("atrium-mac: unreadable queue item at \(file.lastPathComponent)")
                continue
            }
            // A process that died mid-attempt leaves a future backoff
            // stamp for no reason. Anything already due stays due.
            if item.nextAttemptAt > Date().addingTimeInterval(3600),
                item.state != .ready
            {
                item.nextAttemptAt = Date()
            }
            items[item.id] = item
        }
    }

    // MARK: - Reporting

    private func currentSummary() -> Summary {
        var summary = Summary()
        summary.isConfigured = config.isConfigured && config.uploadEnabled
        for item in items.values {
            // Both kinds: a name applied on a 66% guess is as much a
            // question as no name at all, and the menu badge is where
            // somebody notices there is one.
            summary.unnamedVoices += item.openSpeakerQuestions
            switch item.state {
            case .pending: summary.pending += 1
            case .uploaded: summary.uploaded += 1
            case .ready: summary.ready += 1
            case .failed:
                summary.failed += 1
                summary.lastError = item.lastError ?? summary.lastError
            }
        }
        return summary
    }

    private func publish() {
        onChange(currentSummary())
    }
}
