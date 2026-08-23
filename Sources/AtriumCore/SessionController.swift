import Foundation

/// Tunables for the meeting state machine. Defaults are the settled
/// design values; they are here rather than inline so they can be moved
/// into the config file once tuned against real meetings.
public struct SessionPolicy {

    public init() {}

    /// How long the mic must stay released before a meeting is over.
    /// Teams and Zoom both hold the input device open well past the end
    /// of a call, and Zoom keeps it running while you are muted, so the
    /// release edge is not a clean signal.
    public var endDebounce: TimeInterval = 45

    /// Re-acquisition inside this window is a reconnect, not a new
    /// meeting, and is merged into the previous recording.
    public var mergeWindow: TimeInterval = 120

    /// Hard ceiling on one recording. At 16 kHz mono AAC a 3-hour file is
    /// ~45 MB, well under Atrium PA's 300 MiB per-file limit.
    public var maxDuration: TimeInterval = 3 * 3600

    /// A candidate must show far-end audio inside this window or it is
    /// discarded. This is what makes Chrome usable: the mic grab arrives
    /// from `com.google.Chrome.helper` with no tab identity and window
    /// titles are redacted without Screen Recording, so a Meet call is
    /// indistinguishable from any other site using the mic. A real call
    /// has two-way audio; a mic test does not.
    public var farEndConfirmationWindow: TimeInterval = 60

    /// How long a recording runs before the app asks whether it should
    /// still be running, and how often it asks again.
    ///
    /// An hour, then every half hour. A meeting app that never released
    /// the microphone would otherwise record until the three-hour cap,
    /// and nothing here can tell that from a long call — only the person
    /// in the room can.
    ///
    /// **The reminder never stops a recording.** It cannot be dismissed
    /// into stopping, and an unanswered one means carry on: the failure
    /// this app cannot recover from is a meeting it did not record, and
    /// a wasted hour of disk is not in the same category. Stopping is a
    /// deliberate press on the notification's own button.
    public var runawayReminderAfter: TimeInterval = 3600
    public var runawayReminderRepeat: TimeInterval = 1800

    /// Recordings shorter than this are dropped as blips — permission
    /// probes, notification sounds, a mis-click.
    public var minimumDuration: TimeInterval = 90
}

/// One recording session.
public final class Session {
    public let id = UUID()
    public let bundleID: String
    public let startedAt: Date
    public var endedAt: Date?
    /// Set once any far-end audio is observed (see `farEndConfirmationWindow`).
    public var farEndConfirmed = false

    /// Started by the user from the menu rather than by an app grabbing
    /// the microphone.
    ///
    /// A manual session skips every heuristic in `SessionPolicy`. Those
    /// windows exist to answer "is this a meeting?" from indirect
    /// evidence, and there is no evidence to weigh when somebody has
    /// pressed record: no far-end gate (an in-person conversation has no
    /// far-end at all), no minimum duration, no merge on reconnect.
    public let isManual: Bool

    public init(bundleID: String, startedAt: Date = Date(), isManual: Bool = false) {
        self.bundleID = bundleID
        self.startedAt = startedAt
        self.isManual = isManual
        self.farEndConfirmed = isManual
    }

    public var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }
}

/// Reason a session ended, so the caller knows whether to keep the audio.
public enum SessionOutcome {
    case completed(Session)
    /// Dropped before it became a recording worth keeping.
    case discarded(Session, reason: String)
}

/// Turns raw mic acquire/release edges into meeting sessions.
///
/// The mapping is not one-to-one: apps flap the mic, hold it after a
/// call, and reconnect mid-meeting. See `SessionPolicy` for why each
/// window exists.
public final class SessionController {

    public let policy: SessionPolicy
    private let allowlist: () -> Allowlist
    private let queue = DispatchQueue(label: "com.atrium-mac.sessions")

    /// Bundle IDs currently holding the mic that we care about.
    private var holders: Set<String> = []
    private var current: Session?
    /// Bumped on every state change; a pending end-timer whose generation
    /// is stale simply does nothing. Cheaper and less error-prone than
    /// cancelling timers.
    private var generation = 0
    private var lastEndedAt: Date?
    private var lastEndedBundle: String?

    public var onStart: ((Session) -> Void)?
    public var onEnd: ((SessionOutcome) -> Void)?

    public init(policy: SessionPolicy = SessionPolicy(), allowlist: @escaping () -> Allowlist) {
        self.policy = policy
        self.allowlist = allowlist
    }

    /// Feed a mic event in. Safe to call from any thread.
    public func handle(_ event: MicEvent) {
        queue.async { self.handleLocked(event) }
    }

    /// Start recording because the user asked, not because an app took
    /// the microphone.
    ///
    /// This is the path for the meetings the detector cannot see: a
    /// conversation in the room, a call on a phone lying on the desk, or
    /// simply an app that is not on the allowlist. It is also the only
    /// way to exercise capture end to end without joining a real call,
    /// which is what makes it worth having during development.
    ///
    /// A manual session already counts as far-end confirmed, so the 60 s
    /// gate cannot discard it, and `stopCurrent()` ends it.
    public func startManual(label: String = "manual recording") {
        queue.async {
            guard self.current == nil else { return }
            self.generation += 1
            let session = Session(bundleID: label, isManual: true)
            self.current = session
            self.lastEndedAt = nil
            self.lastEndedBundle = nil
            self.onStart?(session)
            self.scheduleHardCap(for: session)
        }
    }

    /// Whether a session is running right now. Drives the menu title,
    /// which has to say either "Start Recording" or "Stop Recording".
    public var isRecording: Bool { queue.sync { current != nil } }

    /// Stop the active session now, keeping what has been captured.
    ///
    /// This is the red square on the floating panel. It bypasses the
    /// end-debounce and the merge window — an explicit stop means the
    /// meeting is over, so a reconnect 30 s later must start a *new*
    /// recording rather than silently resuming one the user just ended.
    ///
    /// It also bypasses the far-end confirmation: if you deliberately
    /// stopped it, you want the audio, even if only your side was heard.
    public func stopCurrent() {
        queue.async {
            guard let session = self.current else { return }
            session.endedAt = Date()
            self.current = nil
            self.generation += 1
            self.lastEndedAt = nil
            self.lastEndedBundle = nil
            self.onEnd?(.completed(session))
        }
    }

    /// Discard the active session and its audio.
    public func discardCurrent() {
        queue.async {
            guard let session = self.current else { return }
            self.discard(session, reason: "stopped by user")
        }
    }

    /// Report that far-end (system) audio was heard for the active session.
    /// Report that capture is actually running now.
    ///
    /// The far-end confirmation window is armed from here rather than
    /// from the moment the session began, because those are not the same
    /// instant and the gap can be most of the window.
    ///
    /// Measured: `AudioHardwareCreateProcessTap` blocks while macOS shows
    /// the audio-capture permission dialog — 44 seconds on a first run.
    /// The session had started, the 60-second clock was already running,
    /// and capture began with 16 seconds left of it. A real Teams meeting
    /// was discarded as "not a call" and its files deleted, because
    /// nobody happened to speak in those 16 seconds.
    public func noteCaptureStarted() {
        queue.async {
            guard let session = self.current, !session.isManual else { return }
            self.scheduleFarEndCheck(for: session)
        }
    }
    public func noteFarEndAudio() {
        queue.async {
            guard let current = self.current, !current.farEndConfirmed else { return }
            current.farEndConfirmed = true
        }
    }

    // MARK: - Private

    private func handleLocked(_ event: MicEvent) {
        guard let bundleID = event.bundleID else {
            Log.write("mic: ignoring \(event.executable) — no bundle ID")
            return
        }
        guard allowlist().matches(bundleID: bundleID) else {
            // Logged rather than dropped in silence. "The orange dot came
            // on and nothing happened" is otherwise unanswerable without
            // a debugger, and the answer is usually here.
            if event.capturing {
                Log.write("mic: \(bundleID) is capturing but is not on the allowlist")
            }
            return
        }

        if event.capturing {
            Log.write("mic: \(bundleID) matched the allowlist — starting or resuming")
            holders.insert(bundleID)
            startOrResume(bundleID: bundleID)
        } else {
            holders.remove(bundleID)
            if holders.isEmpty {
                scheduleEnd()
            }
        }
    }

    private func startOrResume(bundleID: String) {
        generation += 1

        if current != nil {
            // Already recording — a second app grabbing the mic (or the
            // same one reconnecting) folds into the running session.
            return
        }

        // Merge with the session that just ended if this is a reconnect.
        if let lastEndedAt, let lastEndedBundle,
            Date().timeIntervalSince(lastEndedAt) < policy.mergeWindow,
            lastEndedBundle == bundleID
        {
            // Caller is responsible for reopening the same output file;
            // we signal it by starting a session stamped with the old
            // start time so duration stays continuous.
            let resumed = Session(bundleID: bundleID, startedAt: lastEndedAt)
            current = resumed
            self.lastEndedAt = nil
            self.lastEndedBundle = nil
            onStart?(resumed)
            return
        }

        let session = Session(bundleID: bundleID)
        current = session
        onStart?(session)
        scheduleHardCap(for: session)
        // The far-end window is armed by `noteCaptureStarted()`, once
        // audio is actually flowing — not here. See there for why.
    }

    private func scheduleEnd() {
        let mine = generation
        queue.asyncAfter(deadline: .now() + policy.endDebounce) { [weak self] in
            guard let self, self.generation == mine, self.holders.isEmpty,
                let session = self.current
            else { return }
            // A manual recording is not ended by an app letting go of
            // the microphone — it was never started by one. Otherwise a
            // Chrome tab that briefly grabbed the mic during an in-room
            // conversation would end the recording 45 s later.
            guard !session.isManual else { return }
            self.finish(session, force: false)
        }
    }

    private func scheduleHardCap(for session: Session) {
        queue.asyncAfter(deadline: .now() + policy.maxDuration) { [weak self] in
            guard let self, self.current === session else { return }
            self.finish(session, force: true)
        }
    }

    private func scheduleFarEndCheck(for session: Session) {
        queue.asyncAfter(deadline: .now() + policy.farEndConfirmationWindow) {
            [weak self] in
            guard let self, self.current === session, !session.farEndConfirmed else {
                return
            }
            let holder = session.bundleID
            self.discard(session, reason: "no far-end audio within "
                + "\(Int(self.policy.farEndConfirmationWindow))s — not a call")

            // Still holding the microphone? Then this is not "not a
            // call" — it is "not a call *yet*", and giving up for good
            // loses the meeting.
            //
            // Joining early is the case. Teams grabs the microphone the
            // moment you join, and the lobby is silent: the window
            // expires, the session is discarded, and no further event
            // ever arrives because the app never let go of the
            // microphone — so nothing restarts when people start
            // talking. Sitting in a waiting room for two minutes cost
            // the entire meeting.
            //
            // A fresh candidate with the window re-armed keeps the
            // question open at the cost of one discarded file per
            // window, and catches the meeting within one window of the
            // first far-end audio.
            guard self.holders.contains(holder) else { return }
            Log.write("mic: \(holder) still holds the microphone — watching again")
            self.startOrResume(bundleID: holder)
        }
    }

    private func finish(_ session: Session, force: Bool) {
        session.endedAt = Date()
        current = nil
        generation += 1
        lastEndedAt = force || session.isManual ? nil : session.endedAt
        lastEndedBundle = force || session.isManual ? nil : session.bundleID

        // A session the user started deliberately is kept whatever the
        // heuristics say about it.
        if session.isManual {
            onEnd?(.completed(session))
            return
        }

        if !session.farEndConfirmed {
            Log.write("session \(session.bundleID) discarded — no far-end audio")
            onEnd?(.discarded(session, reason: "no far-end audio — not a call"))
            return
        }
        if session.duration < policy.minimumDuration {
            onEnd?(
                .discarded(
                    session,
                    reason: "shorter than \(Int(policy.minimumDuration))s — blip"))
            return
        }
        Log.write(
            String(
                format: "session %@ completed — %.0fs", session.bundleID,
                session.duration))
        onEnd?(.completed(session))
    }

    private func discard(_ session: Session, reason: String) {
        Log.write("session \(session.bundleID) discarded — \(reason)")
        session.endedAt = Date()
        current = nil
        generation += 1
        lastEndedAt = nil
        lastEndedBundle = nil
        onEnd?(.discarded(session, reason: reason))
    }
}
