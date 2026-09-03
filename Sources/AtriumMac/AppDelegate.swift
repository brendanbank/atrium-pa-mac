import AppKit
import AtriumCore
import UserNotifications
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private let monitor = MicMonitor()
    private var controller: SessionController!
    private var allowlist = Allowlist.load()
    private var config = AtriumConfig.load()

    /// Built in `applicationDidFinishLaunching`, not here. A stored
    /// property is initialised while the delegate is being constructed,
    /// which is before AppKit is ready to hand out windows.
    private var panel: RecordingPanel!
    private let recorder = AudioRecorder()
    private let notifier = Notifier()
    private var uploadQueue: UploadQueue!
    private let micAnalyzer = SpectrumAnalyzer()
    private let farEndAnalyzer = SpectrumAnalyzer()
    private var meterTimer: Timer?
    /// Asks, on a timer, whether a long-running recording should still
    /// be running. Never answers for the user — see
    /// `SessionPolicy.runawayReminderAfter`.
    private var reminderTimer: Timer?

    /// Most recent sessions, newest first. Capped — this is a menu, not
    /// an archive; durable history belongs in the upload queue.
    private var recent: [(String, Date, String)] = []
    private var isPaused = false
    /// The panel is on screen by default: it holds the only start
    /// control, so hiding it by default would hide the feature.
    private var isPanelVisible = true
    private var activeSession: Session?
    /// Held across a sleep so the wake handler knows what to resume.
    private var interruptedSession: Session?
    private var queueSummary = UploadQueue.Summary()
    private let updater = Updater()

    /// Reached through the responder chain from the App menu.
    ///
    /// A menu item with no target walks the chain looking for anything
    /// that answers this selector, which is what lets `MainMenu` stay a
    /// plain description of the menu rather than needing a reference to
    /// whatever happens to own the updater.
    @objc func checkForUpdatesFromMenu(_ sender: Any?) {
        updater.checkForUpdates(sender)
    }
    private var namingWindow: SpeakerNamingWindow?
    private var activityWindow: ActivityWindow?
    /// The **Capture** menu in the menu bar. Held so its submenu can be
    /// rebuilt in step with the status item's.
    private var captureMenuItem: NSMenuItem?
    private var settingsWindow: SettingsWindow?
    private var logWindow: LogWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.trim()
        Log.write("launched \(Bundle.main.bundleURL.path)")
        Log.write("args: \(CommandLine.arguments.dropFirst().joined(separator: " "))")
        Log.write("microphone TCC: \(MicCapture.authorizationDescription)")
        // Ask explicitly. `AVAudioEngine.start()` succeeds whether or not
        // the grant exists; without it the input tap simply never fires
        // and the mic channel records silence with nothing logged.
        MicCapture.requestAuthorization { [weak self] granted in
            Log.write(
                "microphone TCC after request: "
                    + "\(MicCapture.authorizationDescription) (granted=\(granted))")
            DispatchQueue.main.async { self?.reportPermissionsWhenSettled() }
        }
        Allowlist.seedIfMissing()
        AtriumConfig.seedIfMissing()
        try? AppPaths.ensureDirectories()

        controller = SessionController(allowlist: { [weak self] in
            self?.allowlist ?? .defaults
        })
        // What a relaunch would cost, asked at the moment it matters.
        //
        // A meeting this app fails to record cannot be recovered, and a
        // pending upload's `.m4a` is the only copy of that conversation
        // once Atrium PA sweeps its vault. An update can wait for both.
        updater.isBusy = { [weak self] in
            guard let self else { return (true, "still starting up") }
            if self.controller.isRecording {
                return (true, "a recording is running")
            }
            if self.queueSummary.hasWork {
                return (
                    true,
                    "\(self.queueSummary.pending + self.queueSummary.uploaded) "
                        + "recording(s) still uploading")
            }
            return (false, "")
        }
        updater.start()

        controller.onStart = { [weak self] session in
            DispatchQueue.main.async { self?.sessionStarted(session) }
        }
        controller.onEnd = { [weak self] outcome in
            DispatchQueue.main.async { self?.sessionEnded(outcome) }
        }

        monitor.onEvent = { [weak self] event in
            guard let self, !self.isPaused else { return }
            self.controller.handle(event)
        }
        monitor.start()

        panel = RecordingPanel()
        panel.onStart = { [weak self] in self?.controller.startManual() }
        panel.onStop = { [weak self] in self?.controller.stopCurrent() }
        panel.onMenu = { [weak self] in self?.buildMenu() }
        captureMenuItem = MainMenu.installCaptureMenu()
        if let settings = MainMenu.settingsItem() {
            settings.target = self
            settings.action = #selector(showSettings)
        }

        uploadQueue = UploadQueue(config: config) { [weak self] summary in
            DispatchQueue.main.async {
                self?.queueSummary = summary
                self?.refreshMenu()
                // The window's own timer would get there within five
                // seconds; this gets there when the queue actually
                // changed, which includes the first load right after
                // launch — otherwise the window opens saying "no
                // recordings yet" on a machine that has some.
                self?.activityWindow?.reload()
            }
        }
        let notifier = self.notifier
        Task { [weak self] in
            await self?.uploadQueue.setOnReady { item in
                DispatchQueue.main.async {
                    guard item.notifiedAt == nil else { return }
                    notifier.transcriptReady(
                        title: item.title ?? "Meeting",
                        captureID: item.captureID ?? 0,
                        transcriptID: item.transcriptID,
                        unnamedVoices: item.openSpeakerQuestions)
                    Task { await self?.uploadQueue.markNotified(itemID: item.id) }
                }
            }
            // Voices that turn up nameable *after* the transcript was
            // announced get their own notification. The first one said
            // "ready to read" because at that moment there was genuinely
            // nothing to ask for.
            await self?.uploadQueue.setOnSpeakersBecameNameable { item in
                DispatchQueue.main.async {
                    notifier.transcriptReady(
                        title: item.title ?? "Meeting",
                        captureID: item.captureID ?? 0,
                        transcriptID: item.transcriptID,
                        unnamedVoices: item.openSpeakerQuestions)
                    self?.activityWindow?.reload()
                }
            }
            await self?.uploadQueue.start()
        }

        notifier.onOpenNaming = { [weak self] captureID in
            self?.openNaming(captureID: captureID)
        }
        notifier.onOpenTranscript = { [weak self] captureID in
            self?.openInAtriumPA(captureID: captureID)
        }

        notifier.onStopRecording = { [weak self] in
            Log.write("stopping on the user's press from the recording reminder")
            self?.controller.stopCurrent()
        }
        notifier.onStatusChange = { [weak self] in
            self?.refreshMenu()
            self?.reportPermissionsWhenSettled()
        }
        notifier.start()
        observeSleep()
        buildStatusItem()
        recoverOrphanedRecordings()
        if isPanelVisible { panel.show() }
        refreshMenu()

        // Off the main thread, then prompt: whether to offer signing in
        // depends on the answer, and asking for it here directly is what
        // used to hang the launch.
        refreshCredentialState { [weak self] in
            self?.promptForConnectionIfNeeded()
            self?.verifyLoginOnLaunch()
        }

        // Judged when the answers arrive, not on a timer.
        //
        // Both requests raise a dialog, and a person takes longer to
        // answer one than any delay worth waiting. Measured with a
        // three-second delay: "permissions: nothing refused" was logged
        // at 16:22:34 and the notification answer arrived at 16:22:37 —
        // so a refusal on the launch that asked for it would have been
        // missed, which is the one launch where saying so matters.
        reportPermissionsWhenSettled()

        // Offer any trigger apps added to the defaults since this file
        // was written. A beat after launch, so it does not stack on the
        // permission dialogs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.offerNewAllowlistDefaults()
        }

        // Show the main window on launch. This is a `.regular` app, and
        // an app that comes to the front showing nothing reads exactly
        // like a launch that failed.
        //
        // Not conditional on how it was launched.
        // `NSApplicationLaunchIsDefaultLaunchKey` looked like the way to
        // stay quiet when macOS starts us at login, but measured on
        // 26.5 it is false for a plain `open` as well, so it cannot tell
        // the two apart. `--record-now` is the one case that means
        // something else: it was asked for a recording, not a window.
        if !CommandLine.arguments.contains("--record-now") {
            showActivity()
        }

        // `open "Atrium PA Capture.app" --args --record-now` starts a
        // manual recording straight away. Meant for a Shortcut or a
        // Stream Deck key — and it is how the recording path gets
        // exercised without a human clicking a menu, which is otherwise
        // impossible to do from a script.
        // Prove the notification path without waiting for a meeting.
        if CommandLine.arguments.contains("--notify-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.notifier.transcriptReady(
                    title: "Teams meeting", captureID: 99_999, transcriptID: 1,
                    unnamedVoices: 2)
            }
        }

        // `--name-voices` opens the naming window on whatever is
        // waiting, so the one part of this feature that needs a click
        // can still be exercised from a script.
        if CommandLine.arguments.contains("--name-voices") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.openNamingFromMenu()
            }
        }

        // `--unname <capture> <cluster>` takes a name back off a voice
        // and stops it being asked about again. The correction path,
        // driven from here rather than from the self-test runner
        // because this process already holds the credentials — the
        // runner is a different binary and reading the keychain from it
        // costs a login-password prompt.
        if let index = CommandLine.arguments.firstIndex(of: "--unname"),
            CommandLine.arguments.count > index + 2,
            let captureID = Int(CommandLine.arguments[index + 1]),
            let cluster = Int(CommandLine.arguments[index + 2])
        {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.unname(captureID: captureID, cluster: cluster)
            }
        }

        // `--start-at-login` drives the login-item registration from a
        // script, for the same reason `--login` drives the browser flow:
        // the alternative is a human ticking a checkbox.
        if CommandLine.arguments.contains("--start-at-login") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                Log.write("login item: before \(LoginItem.statusDescription)")
                self?.toggleStartAtLogin()
                Log.write("login item: after \(LoginItem.statusDescription)")
            }
        }

        // `--settings` opens the settings window from a script, for the
        // same reason `--login` drives the browser flow: a window that
        // only a human can open is a window no test ever sees.
        if let index = CommandLine.arguments.firstIndex(of: "--settings") {
            let tab = CommandLine.arguments.count > index + 1
                ? CommandLine.arguments[index + 1] : nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.openSettings(tab: tab)
            }
        }

        // `--save-transcript` saves the newest finished recording's
        // transcript, for the same reason the other flags exist: a menu
        // item only a human can reach is one no test ever runs.
        if CommandLine.arguments.contains("--save-transcript") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                Task { [weak self] in
                    let items = await self?.uploadQueue.allItems() ?? []
                    guard let newest = items.first(where: { $0.transcriptID != nil })
                    else {
                        Log.write("no finished recording to save a transcript for")
                        return
                    }
                    await MainActor.run { self?.saveTranscript(newest) }
                }
            }
        }

        // `--refresh` is the Refresh button, for a script.
        if CommandLine.arguments.contains("--refresh") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                Task { await self?.uploadQueue.refreshAll() }
            }
        }

        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.showActivity()
            }
        }

        // `--login` drives the browser flow from a script, the same way
        // `--record-now` drives recording. Both exist because the
        // alternative is a human clicking a menu, which is not something
        // a test can do.
        if CommandLine.arguments.contains("--login") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.logIn()
            }
        }

        if CommandLine.arguments.contains("--record-now") {
            // After the grant resolves, not before: `requestAccess` is
            // asynchronous, and starting the engine while the answer is
            // still pending is how you get a recording whose left
            // channel is silence.
            MicCapture.requestAuthorization { [weak self] _ in
                self?.controller.startManual(label: "launched with --record-now")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Close the file *synchronously*. The ordinary end-of-session
        // path cannot be used here: `stopCurrent()` reports back through
        // `DispatchQueue.main.async`, and there is no next turn of the
        // main run loop during termination — the block would simply
        // never run and the recording would be abandoned mid-write.
        //
        // Encoding is not attempted either. It is CPU-bound and macOS
        // does not wait politely; the sidecar left beside the file is
        // what gets it encoded and queued on the next launch.
        if activeSession != nil {
            let recording = recorder.finish(interrupted: true)
            Log.write(
                "quit: segment closed — "
                    + "\(recording?.stats.summary ?? "nothing was recording")")
        }
        monitor.stop()
    }

    // MARK: - Sleep

    /// Lid-close mid-meeting is normal, and it is the case the whole
    /// durable-queue design exists for (DESIGN.md #10). Treat sleep as
    /// the end of the recording: close the file, hand it to the queue,
    /// and let a reconnect after wake start a new one.
    private func observeSleep() {
        let centre = NSWorkspace.shared.notificationCenter
        centre.addObserver(
            self, selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        centre.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        centre.addObserver(
            self, selector: #selector(systemWillPowerOff),
            name: NSWorkspace.willPowerOffNotification, object: nil)
    }

    /// Close the current segment, but keep the session.
    ///
    /// Sleep is not the end of a meeting — it is the middle of one with
    /// the lid shut. The files are finalised so nothing is half-written
    /// across the suspend, the sidecar records that this was an
    /// interruption, and `systemDidWake` opens a new segment.
    @objc private func systemWillSleep() {
        guard activeSession != nil else { return }
        let recording = recorder.finish(interrupted: true)
        Log.write(
            "sleep: segment closed — \(recording?.stats.summary ?? "nothing recording")")
        interruptedSession = activeSession
        panel.update(micLevels: [], micPeak: 0, farEndLevels: [], farEndPeak: 0)
    }

    @objc private func systemDidWake() {
        guard let session = interruptedSession else { return }
        interruptedSession = nil
        guard let (stem, sidecar) = RecordingSidecar.orphans().first(where: {
            $0.sidecar.startedAt == session.startedAt
        }) else { return }

        do {
            _ = try recorder.start(session: session, resuming: sidecar)
            Log.write("wake: resumed \(stem) as segment \(sidecar.segments.count)")
            panel.beginRecording()
            startMeterTimer()
        } catch {
            // Could not pick it back up. What was already recorded is
            // still on disk with its sidecar, so the next launch will
            // encode and queue it rather than lose it.
            Log.write("wake: could not resume — \(error)")
            note(session.bundleID, Date(), "could not resume after sleep — \(error)")
            activeSession = nil
            controller.stopCurrent()
        }
        refreshMenu()
    }

    @objc private func systemWillPowerOff() {
        guard activeSession != nil else { return }
        _ = recorder.finish(interrupted: true)
        Log.write("shutdown: segment closed, will resume on next launch")
    }

    /// Encode and queue anything a previous run did not finish with.
    ///
    /// A `.caf` still carrying its sidecar was interrupted — by a quit
    /// mid-meeting, a crash, or a flat battery. This is what turns
    /// "the app died during my call" from a lost recording into a
    /// recording that arrives a minute late.
    private func recoverOrphanedRecordings() {
        for (stem, sidecar) in RecordingSidecar.orphans() {
            guard !sidecar.segments.isEmpty else {
                RecordingSidecar.remove(stem: stem)
                continue
            }
            note(
                sidecar.bundleID, sidecar.startedAt,
                "recovered \(sidecar.segments.count) segment(s) from an interrupted run")
            Log.write("recovering \(stem): \(sidecar.segments.count) segment(s)")
            encodeAndQueue(
                stem: stem, sidecar: sidecar,
                title: MeetingTitle.title(
                    bundleID: sidecar.bundleID, isManual: sidecar.isManual),
                occurredAt: sidecar.startedAt)
        }
    }

    // MARK: - Session plumbing

    private func sessionStarted(_ session: Session) {
        activeSession = session
        panel.beginRecording()
        refreshMenu()

        // Off the main thread, because starting capture can block for a
        // long time. `AudioHardwareCreateProcessTap` waits while macOS
        // shows the audio-capture permission dialog — measured at 44
        // seconds on a first run — and doing that on the main thread
        // freezes the menu bar, the panel, and anything else this app
        // owns for the duration.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let warnings = try self.recorder.start(session: session)
                DispatchQueue.main.async {
                    for warning in warnings {
                        // Into the log as well as the menu: a stream that
                        // failed to open is the difference between a
                        // usable recording and half a conversation, and
                        // nobody is watching the menu at the time.
                        Log.write("stream warning: \(warning)")
                        self.note(session.bundleID, Date(), warning)
                    }
                    self.startMeterTimer()
                    self.startReminderTimer(for: session)
                    // Nothing is waiting to be detected while a
                    // recording runs, so stop paying for a fast poll.
                    self.monitor.setRecording(true)
                    // Only now does the far-end confirmation window make
                    // sense to start counting.
                    self.controller.noteCaptureStarted()
                }
            } catch {
                Log.write("could not start recording — \(error)")
                DispatchQueue.main.async {
                    self.note(
                        session.bundleID, Date(), "could not start recording — \(error)")
                    self.controller.discardCurrent()
                }
            }
        }
    }

    /// 30 fps is plenty for a confidence meter and keeps the panel cheap
    /// enough to leave running for a three-hour meeting.
    /// Ask once an hour, then every half hour, for as long as it runs.
    ///
    /// Nothing here can tell a long meeting from an app that grabbed the
    /// microphone and never gave it back — Teams and Zoom both hold the
    /// input device past the end of a call. The person in the room can
    /// tell. So the app asks, and carries on regardless of the answer:
    /// only the notification's own Stop button ends anything.
    private func startReminderTimer(for session: Session) {
        reminderTimer?.invalidate()
        let policy = controller.policy
        let timer = Timer(
            fire: Date().addingTimeInterval(policy.runawayReminderAfter),
            interval: policy.runawayReminderRepeat, repeats: true
        ) { [weak self] _ in
            guard let self, let running = self.activeSession, running === session
            else { return }
            self.notifier.stillRecording(
                title: MeetingTitle.title(
                    bundleID: running.bundleID, isManual: running.isManual),
                running: Date().timeIntervalSince(running.startedAt))
        }
        RunLoop.main.add(timer, forMode: .common)
        reminderTimer = timer
    }

    private func stopReminderTimer() {
        reminderTimer?.invalidate()
        reminderTimer = nil
        notifier.clearRecordingReminder()
    }

    private func startMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) {
            [weak self] _ in
            self?.updateMeters()
        }
    }

    private func sessionEnded(_ outcome: SessionOutcome) {
        activeSession = nil
        meterTimer?.invalidate()
        meterTimer = nil
        stopReminderTimer()
        monitor.setRecording(false)
        panel.endRecording()
        panel.update(micLevels: [], micPeak: 0, farEndLevels: [], farEndPeak: 0)

        switch outcome {
        case .completed(let session):
            guard let recording = recorder.finish() else {
                note(session.bundleID, session.startedAt, "nothing was captured")
                refreshMenu()
                return
            }
            handleFinished(recording)
        case .discarded(let session, let reason):
            recorder.discard()
            note(session.bundleID, session.startedAt, "discarded — \(reason)")
        }
        refreshMenu()
    }

    /// Encode and queue. Both are off the main thread: AAC encoding a
    /// three-hour meeting is CPU-bound and would otherwise freeze the
    /// menu bar for the duration.
    private func handleFinished(_ recording: AudioRecorder.Recording) {
        let session = recording.session
        var status = String(format: "recorded %.0fs", recording.duration)
        if recording.farEndSilent {
            // The documented silent failure: the tap is created, the
            // IOProc fires on schedule, and every sample is zero. Say so
            // rather than shipping silence to a transcription service.
            status += " — far-end was SILENT (check the app bundle / TCC)"
        }
        if recording.micSilent {
            status += " — mic was silent"
        }
        note(session.bundleID, session.startedAt, status)
        Log.write(
            "session \(session.bundleID) — \(recording.stats.summary), "
                + String(format: "micPeak %.6f farEndPeak %.6f", recording.micPeak, recording.farEndPeak))

        encodeAndQueue(
            stem: recording.stem,
            sidecar: RecordingSidecar(
                bundleID: session.bundleID, startedAt: session.startedAt,
                isManual: session.isManual, segments: recording.segments,
                interrupted: false),
            title: MeetingTitle.title(
                bundleID: session.bundleID, isManual: session.isManual),
            occurredAt: session.startedAt)
    }

    private func encodeAndQueue(
        stem: String, sidecar: RecordingSidecar, title: String, occurredAt: Date
    ) {
        let queue = uploadQueue!
        let destination = AppPaths.recordings.appending(path: "\(stem).m4a")
        let bundleID = sidecar.bundleID

        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let uploadURL = try AudioEncoder.encodeForUpload(
                    segments: sidecar.segments, to: destination)
                let masters = sidecar.segments.flatMap { [$0.micURL, $0.farURL] }
                Task {
                    await queue.enqueue(
                        audioURL: uploadURL, masterURLs: masters, title: title,
                        occurredAt: occurredAt)
                    // Only now is this session someone else's problem.
                    // Until the sidecar is gone the next launch picks it
                    // up again, which is what we want if anything above
                    // this line failed.
                    RecordingSidecar.remove(stem: stem)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.note(bundleID, occurredAt, "encode failed — \(error)")
                    self?.refreshMenu()
                }
            }
        }
    }

    // MARK: - Meters

    private func updateMeters() {
        let levels = recorder.levels()

        if levels.mic.count >= 1024 {
            micAnalyzer.process(samples: levels.mic, channels: 1)
        } else {
            micAnalyzer.idle()
        }

        if levels.farEnd.count >= 1024 {
            farEndAnalyzer.process(samples: levels.farEnd, channels: 1)
        } else {
            farEndAnalyzer.idle()
        }

        // Any far-end energy at all confirms this is a real call, which
        // is what keeps a Chrome mic-probe from being recorded.
        if farEndAnalyzer.instantPeak > 0.002 {
            controller.noteFarEndAudio()
        }

        // `displayLevels`, not `levels`: the panel is an indicator, not
        // a meter. See SpectrumAnalyzer.displayLevels.
        panel.update(
            micLevels: micAnalyzer.displayLevels,
            micPeak: micAnalyzer.instantPeak,
            farEndLevels: farEndAnalyzer.displayLevels,
            farEndPeak: farEndAnalyzer.instantPeak)
    }

    /// Turn `com.microsoft.teams2.helper` into `Teams` for the menu.
    ///
    /// Shares its table with the title sent to Atrium PA, so the menu
    /// and the transcript list cannot drift apart — and so the menu
    /// stops saying "Meet" for a Chrome grab that may have been
    /// anything. See `MeetingTitle`.
    private func friendlyName(_ bundleID: String) -> String {
        MeetingTitle.shortName(bundleID: bundleID)
    }

    private func note(_ bundleID: String, _ at: Date, _ status: String) {
        recent.insert((bundleID, at, status), at: 0)
        if recent.count > 10 { recent.removeLast(recent.count - 10) }
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "waveform", accessibilityDescription: "Atrium PA")
        statusItem = item
    }

    /// Rebuild every surface that shows the menu.
    ///
    /// Three of them, all from `buildMenu()`: the status item, the
    /// **Capture** menu in the menu bar, and the panel's grip. A fresh
    /// `NSMenu` each time rather than one shared instance — a menu can
    /// only be attached in one place at a time, and handing the same
    /// object to two owners makes it disappear from whichever asked
    /// first.
    private func refreshMenu() {
        statusItem?.button?.image = NSImage(
            systemSymbolName: activeSession != nil
                ? "waveform.circle.fill" : "waveform",
            accessibilityDescription: statusLine)

        statusItem?.menu = buildMenu()
        captureMenuItem?.submenu = buildMenu()
    }

    /// What the app is doing, in three words. One copy, because the
    /// status item's accessibility label and the menu's first line have
    /// to agree and were computed separately.
    private var statusLine: String {
        if isPaused { return "Paused" }
        if let activeSession {
            return "Recording — \(friendlyName(activeSession.bundleID))"
        }
        return "Idle"
    }

    /// Everything this app can be told to do, in one list.
    ///
    /// Built here rather than in `MainMenu` because almost every entry
    /// depends on state — what is recording, what is queued, whether we
    /// are signed in — and a menu that says "Start Recording" while a
    /// recording is running is worse than no menu.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu(title: "Capture")
        menu.addItem(withTitle: statusLine, action: nil, keyEquivalent: "")

        menu.addItem(
            withTitle: "Show Recordings…", action: #selector(showActivity),
            keyEquivalent: "o").target = self

        menu.addItem(.separator())

        // The manual control. Detection covers the meeting apps on the
        // allowlist; this covers everything else, and it is the only way
        // to see the panel and the meters without joining a real call.
        let recording = activeSession != nil
        let toggle = menu.addItem(
            withTitle: recording ? "Stop Recording" : "Start Recording Now",
            action: recording ? #selector(stopRecording) : #selector(startRecording),
            keyEquivalent: "r")
        toggle.target = self

        menu.addItem(
            withTitle: "Discard Current Recording",
            action: #selector(discardCurrent), keyEquivalent: "").target = self
        menu.addItem(
            withTitle: isPaused ? "Resume Detection" : "Pause Detection",
            action: #selector(togglePause), keyEquivalent: "").target = self

        menu.addItem(.separator())
        addUploadSection(to: menu)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Recent", action: nil, keyEquivalent: "").isEnabled = false

        if recent.isEmpty {
            let empty = menu.addItem(withTitle: "  (nothing yet)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            for (bundle, at, status) in recent {
                let entry = menu.addItem(
                    withTitle: "  \(formatter.string(from: at))  "
                        + "\(friendlyName(bundle)) — \(status)",
                    action: nil, keyEquivalent: "")
                entry.isEnabled = false
            }
        }

        menu.addItem(.separator())
        menu.addItem(
            withTitle: isFullyConfigured ? "Log in to Atrium PA again…" : "Log in to Atrium PA…",
            action: #selector(logIn), keyEquivalent: "").target = self
        if isFullyConfigured {
            menu.addItem(
                withTitle: "Log out of Atrium PA", action: #selector(logOut),
                keyEquivalent: "").target = self
        }
        let atLogin = menu.addItem(
            withTitle: "Start at Login", action: #selector(toggleStartAtLogin),
            keyEquivalent: "")
        atLogin.target = self
        atLogin.state = LoginItem.isEnabled ? .on : .off
        // Everything that used to be four separate menu entries now
        // lives behind one, in the place macOS puts settings.
        menu.addItem(
            withTitle: "Settings…", action: #selector(showSettings),
            keyEquivalent: ",").target = self
        menu.addItem(
            withTitle: isPanelVisible ? "Hide Panel" : "Show Panel",
            action: #selector(togglePanel), keyEquivalent: "").target = self
        menu.addItem(
            withTitle: "Open Recordings Folder", action: #selector(openRecordings),
            keyEquivalent: "").target = self
        menu.addItem(
            withTitle: "Open Log", action: #selector(openLog),
            keyEquivalent: "").target = self

        menu.addItem(.separator())
        // No ⌘Q here. This menu is now also the Capture menu in the menu
        // bar, and the App menu already carries that key equivalent —
        // two menu items claiming ⌘Q is one too many.
        // Targeted at NSApp rather than left to the responder chain.
        // This menu is also shown from the panel's grip, and the panel
        // is a non-activating panel that never becomes key — so there is
        // no key window to start walking from, and a nil-target item can
        // come up disabled. Every other entry here already names its
        // target; this one was the exception.
        let quit = menu.addItem(
            withTitle: "Quit Atrium PA Capture",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp

        return menu
    }

    private func addUploadSection(to menu: NSMenu) {
        let header = menu.addItem(withTitle: "Uploads", action: nil, keyEquivalent: "")
        header.isEnabled = false

        let line: String
        if !config.isConfigured {
            line = "  not connected — see Settings › Atrium PA"
        } else if !isFullyConfigured {
            line = "  not signed in — see Log in to Atrium PA…"
        } else if !config.uploadEnabled {
            line = "  paused in config.json"
        } else if queueSummary.pending == 0 && queueSummary.uploaded == 0
            && queueSummary.failed == 0
        {
            line = "  nothing waiting"
        } else {
            var parts: [String] = []
            if queueSummary.pending > 0 { parts.append("\(queueSummary.pending) to send") }
            if queueSummary.uploaded > 0 {
                parts.append("\(queueSummary.uploaded) transcribing")
            }
            if queueSummary.failed > 0 { parts.append("\(queueSummary.failed) failed") }
            line = "  " + parts.joined(separator: ", ")
        }
        menu.addItem(withTitle: line, action: nil, keyEquivalent: "").isEnabled = false

        if queueSummary.unnamedVoices > 0 {
            let count = queueSummary.unnamedVoices
            let entry = menu.addItem(
                withTitle: count == 1 ? "Name 1 voice…" : "Name \(count) voices…",
                action: #selector(openNamingFromMenu), keyEquivalent: "")
            entry.target = self
        }

        if notifier.status == .denied {
            let entry = menu.addItem(
                withTitle: "  notifications are off — open Settings…",
                action: #selector(openNotificationSettings), keyEquivalent: "")
            entry.target = self
            entry.toolTip =
                "macOS asks once. After a refusal it can only be changed in "
                    + "System Settings › Notifications."
        }

        if let error = queueSummary.lastError {
            let truncated = error.count > 60 ? String(error.prefix(60)) + "…" : error
            let entry = menu.addItem(
                withTitle: "  last error: \(truncated)", action: nil, keyEquivalent: "")
            entry.isEnabled = false
            entry.toolTip = error
        }

        if queueSummary.failed > 0 {
            menu.addItem(
                withTitle: "Retry Failed Uploads", action: #selector(retryUploads),
                keyEquivalent: "").target = self
        }
    }

    // MARK: - Actions

    @objc private func startRecording() {
        controller.startManual()
    }

    @objc private func stopRecording() {
        controller.stopCurrent()
    }

    @objc private func togglePause() {
        isPaused.toggle()
        refreshMenu()
    }

    @objc private func discardCurrent() {
        controller.discardCurrent()
    }

    @objc private func editAllowlist() {
        Allowlist.seedIfMissing()
        NSWorkspace.shared.open(Allowlist.configURL)
    }

    /// Offer trigger apps added to the shipped defaults since the
    /// user's allowlist was written — see `Allowlist.unofferedDefaults`.
    ///
    /// The alternative, merging them in silently, would re-add a prefix
    /// the user deliberately removed. This app asks rather than decides,
    /// and the offered-set is what lets "Not now" be a real answer
    /// instead of a question repeated every launch.
    private func offerNewAllowlistDefaults() {
        let offered = Allowlist.loadOffered()
        let additions = Allowlist.unofferedDefaults(
            current: allowlist.prefixes, offered: offered)
        guard !additions.isEmpty else { return }

        // Recorded as offered whatever the answer is, so declining
        // settles it. Written before the dialog returns would be wrong —
        // a crash mid-prompt should leave it still to ask — but after
        // the answer, both paths mark it seen.
        func remember() {
            Allowlist.saveOffered(offered.union(additions))
        }

        let names = additions
            .map { Self.allowlistDisplayName(for: $0) }
            .reduce(into: [String]()) { list, name in
                if !list.contains(name) { list.append(name) }
            }
        let joined = Self.sentenceList(names)

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Record \(joined)?"
        alert.informativeText =
            "This version of Atrium PA Capture can record \(joined), which your "
            + "allowlist does not cover yet. Add them?\n\nYou can always change "
            + "the allowlist later from the menu."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Not Now")

        if alert.runModal() == .alertFirstButtonReturn {
            var updated = allowlist
            updated.prefixes.append(contentsOf: additions)
            do {
                try updated.save()
                allowlist = updated
                Log.write(
                    "allowlist: added \(additions.joined(separator: ", ")) on the "
                        + "user's yes")
                refreshMenu()
            } catch {
                Log.write("allowlist: could not add \(additions) — \(error)")
            }
        } else {
            Log.write("allowlist: user declined \(additions.joined(separator: ", "))")
        }
        remember()
    }

    /// A human name for a bundle-ID prefix, for the offer dialog. Falls
    /// back to the prefix itself rather than inventing one.
    private static func allowlistDisplayName(for prefix: String) -> String {
        switch prefix {
        case "com.tinyspeck.slackmacgap": return "Slack"
        case "com.apple.Safari": return "Safari"
        case "com.microsoft.edgemac": return "Edge"
        case "company.thebrowser": return "Arc"
        case "com.google.Chrome": return "Chrome"
        case "com.microsoft.teams2": return "Teams"
        case "us.zoom.xos": return "Zoom"
        case "net.whatsapp.WhatsApp": return "WhatsApp"
        case "com.apple.FaceTime", "com.apple.avconferenced": return "FaceTime"
        default: return prefix
        }
    }

    /// "Slack", "Slack and Safari", "Slack, Safari and Edge".
    private static func sentenceList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default:
            return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }

    @objc private func reloadAllowlist() {
        allowlist = Allowlist.load()
        refreshMenu()
    }

    @objc private func toggleStartAtLogin() {
        let wanted = !LoginItem.isEnabled
        if !LoginItem.setEnabled(wanted) && wanted {
            ConnectionSheet.report(
                title: "Could not start at login",
                message: "macOS says: \(LoginItem.statusDescription). If it "
                    + "needs approval, switch Atrium PA Capture on in System "
                    + "Settings › General › Login Items.",
                success: false)
        }
        refreshMenu()
        activityWindow?.reload()
    }

    /// Clicking the Dock icon, or the app in the switcher, with no
    /// window on screen. Without this the app comes forward showing
    /// nothing, which reads exactly like a launch that failed.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        if !hasVisibleWindows { showActivity() }
        return true
    }

    /// Closing the window is not quitting. Recording continues from the
    /// menu bar; ⌘Q is how you leave.
    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    @objc private func togglePanel() {
        isPanelVisible.toggle()
        if isPanelVisible { panel.show() } else { panel.hide() }
        refreshMenu()
    }

    /// The main window: what has been recorded, where each one got to,
    /// and who was in it.
    @objc private func showActivity() {
        let window = activityWindow ?? ActivityWindow()
        activityWindow = window
        window.onReload = { [weak self] deliver in
            Task {
                let items = await self?.uploadQueue.allItems() ?? []
                await MainActor.run { deliver(items) }
            }
        }
        window.onNameVoices = { [weak self] item in self?.presentNaming(for: item) }
        window.onOpenInAtriumPA = { [weak self] captureID in
            self?.openInAtriumPA(captureID: captureID)
        }
        window.onRetry = { [weak self] in
            Task { await self?.uploadQueue.retryFailed() }
        }
        window.onRefresh = { [weak self] in
            Task { await self?.uploadQueue.refreshAll() }
        }
        window.onShowLog = { [weak self] item in self?.showLog(for: item) }
        window.onSaveTranscript = { [weak self] item in self?.saveTranscript(item) }
        window.onDelete = { [weak self] item in self?.confirmDelete(item) }
        window.onLogIn = { [weak self] in self?.logIn() }
        window.onLogOut = { [weak self] in self?.logOut() }
        window.onAccountStatus = { [weak self] in
            self?.accountStatus ?? ("not connected", false)
        }
        window.present()
    }

    @objc private func openNamingFromMenu() {
        Task { [weak self] in
            // The newest recording with voices waiting, or failing that
            // the newest finished one — which re-asks the server and,
            // if everything in it was skipped, offers to bring those
            // back. Falling back matters: `awaitingNames()` reads the
            // cached list, and the cache being empty is exactly the
            // case worth investigating rather than the case to give up
            // on.
            let waiting = await self?.uploadQueue.awaitingNames().first
            let all = await self?.uploadQueue.allItems() ?? []
            let newest =
                waiting ?? all.first { $0.state == .ready && $0.captureID != nil }
            guard let newest else { return }
            await MainActor.run { self?.presentNaming(for: newest) }
        }
    }

    /// Undo a naming: take the name off, then stop asking about it.
    ///
    /// Take the name back off a voice.
    ///
    /// This used to be two calls: `unname_speaker`, then
    /// `dismiss_speaker` to stop it being offered again. Atrium PA
    /// removed dismissal entirely — it only ever reached two of six read
    /// surfaces, so a "dismissed" voice still appeared in the labeling
    /// queues and the web UI reported it as merged or deleted when it
    /// was neither. Three clusters on the whole deployment had ever been
    /// dismissed, all from testing it.
    ///
    /// One call is also the better behaviour. The reason to unname a
    /// voice is almost always that it is someone *else*, not nobody — so
    /// having it come back and be asked about is the point, not a
    /// consolation.
    private func unname(captureID: Int, cluster: Int) {
        guard let client = makeClient() else {
            Log.write("unname: not signed in")
            return
        }
        Task {
            do {
                try await client.unnameSpeaker(voiceCluster: cluster)
                Log.write("unname: removed the name from cluster \(cluster)")
            } catch {
                Log.write("unname: failed on cluster \(cluster) — \(error)")
            }
        }
    }

    private func openNaming(captureID: Int) {
        Task { [weak self] in
            let items = await self?.uploadQueue.awaitingNames() ?? []
            let match = items.first { $0.captureID == captureID } ?? items.first
            guard let match else { return }
            await MainActor.run { self?.presentNaming(for: match) }
        }
    }

    /// Re-check with the server, then open the sheet on what it says.
    ///
    /// The cached list is a snapshot from when the transcript landed.
    /// Opening the sheet on a stale empty list is what made the window
    /// appear and vanish in the same frame: `showCurrent()` finds
    /// nothing to ask about and closes itself immediately.
    private func presentNaming(for item: QueueItem) {
        Task { [weak self] in
            let fresh = await self?.uploadQueue.refreshSpeakers(itemID: item.id) ?? item
            await MainActor.run { self?.presentNaming(resolved: fresh) }
        }
    }

    private func presentNaming(resolved item: QueueItem) {
        // Any cast at all is worth showing, not only the awkward parts.
        //
        // This used to require an *unanswered* question, which was right
        // when the window asked about one voice at a time: no question,
        // no window. The window now lists everybody in the recording and
        // is the only place a name can be taken back off — so refusing
        // to open it once everything was named left no way to correct a
        // mistake, and said "no unnamed voices" as though that were the
        // only reason to look.
        guard item.openSpeakerQuestions > 0 || !item.knownSpeakers.isEmpty else {
            reportNothingToName(in: item)
            return
        }
        guard let client = makeClient() else {
            ConnectionSheet.report(
                title: "Not signed in",
                message: "Log in to Atrium PA before naming voices.", success: false)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let window = namingWindow ?? SpeakerNamingWindow()
        namingWindow = window
        window.onResolved = { [weak self] key, name in
            Task {
                await self?.uploadQueue.resolveSpeaker(
                    itemID: item.id, key: key, namedAs: name)
                await MainActor.run { self?.activityWindow?.reload() }
            }
        }
        window.present(item: item, client: client, host: activityWindow)
    }

    /// Nothing to name, and nothing hiding behind a flag any more.
    ///
    /// This used to list voices that had been *skipped* and offer to ask
    /// about them again — skipping hid a voice from
    /// `unknown_speakers[]`, so without a way back it was a decision
    /// with no undo. Atrium PA removed dismissal, so there is no such
    /// list: a recording with nothing to name genuinely has nothing.
    private func reportNothingToName(in item: QueueItem) {
        ConnectionSheet.report(
            title: "No voices to name",
            message: item.transcriptID == nil
                ? "This recording has no transcript yet."
                : "Atrium PA is not offering any voices for this recording. A "
                    + "recording where diarization attributed nothing has none "
                    + "to offer.",
            success: true)
        activityWindow?.reload()
    }

    private func openInAtriumPA(captureID: Int) {
        guard let base = URL(string: config.baseURL) else { return }
        let target = base.appending(path: "pa/captures/\(captureID)")
        Log.write("opening \(target.path)")
        NSWorkspace.shared.open(target)
    }

    private func makeClient() -> MCPClient? {
        switch MCPClient.shared(config: config) {
        case .success(let client): return client
        case .failure: return nil
        }
    }

    @objc private func openNotificationSettings() {
        Notifier.openSettings()
    }

    @objc private func openLog() {
        Log.write("log opened from the menu")
        NSWorkspace.shared.open(Log.fileURL)
    }

    @objc private func openRecordings() {
        try? AppPaths.ensureDirectories()
        NSWorkspace.shared.open(AppPaths.recordings)
    }

    @objc private func retryUploads() {
        Task { await uploadQueue.retryFailed() }
    }

    /// Offer the connection dialog on the first launch with no
    /// credentials.
    ///
    /// Without this the app looks like it is working — it detects
    /// meetings, records them, queues them — and nothing ever reaches
    /// Atrium PA, with the only clue a line in a menu nobody opens. The
    /// upload lane needs one setup step and this is where to ask for it.
    ///
    /// Deferred to the next turn of the run loop so the status item and
    /// panel are up first; a modal sheet over a half-built app looks
    /// like a crash report.
    /// Report only once, and only once every grant has an answer.
    private var permissionsReported = false

    /// Wait for the dialogs to be answered, then judge.
    ///
    /// `notDetermined` means the question is still on screen. Reporting
    /// then would either be wrong or would stack a second dialog on top
    /// of the first. An unanswered dialog is not a refusal, so if
    /// somebody walks away this stays quiet — the next launch asks
    /// again.
    private func reportPermissionsWhenSettled() {
        guard !permissionsReported else { return }
        let micSettled = MicCapture.isAuthorizationDetermined
        let notificationsSettled = notifier.status != .notDetermined
        guard micSettled && notificationsSettled else { return }
        permissionsReported = true
        reportMissingPermissions()
    }

    /// Say so, once, when a grant this app depends on has been refused.
    ///
    /// Every one of these has failed silently during development, and a
    /// silent failure in a recorder is indistinguishable from the
    /// recorder not being installed. The check runs on launch because
    /// the useful time to learn the microphone is off is before the
    /// meeting, not after it.
    private func reportMissingPermissions() {
        let problems = Permissions.problems(
            notificationStatus: notifier.status)
        guard !problems.isEmpty else {
            Log.write("permissions: nothing refused")
            return
        }
        Log.write(
            "permissions: refused — "
                + problems.map(\.name).joined(separator: ", "))

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText =
            problems.count == 1
            ? "\(problems[0].name) access is turned off"
            : "\(problems.count) permissions are turned off"
        alert.informativeText =
            problems
            .map { "\($0.name): \($0.consequence)" }
            .joined(separator: "\n\n")
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        showSettings()
    }

    /// Prove the stored credentials still work, rather than assuming.
    ///
    /// Being "configured" only means a client id is on disk and a secret
    /// is in the keychain. A refresh token that has been revoked, or
    /// issued by a server that has since moved, looks identical until
    /// the first upload fails — hours later, after a meeting. Minting a
    /// token on launch costs one request and moves that discovery to a
    /// moment when it can still be fixed.
    private func verifyLoginOnLaunch() {
        guard isFullyConfigured, config.uploadEnabled else { return }
        let saved = config
        Task { [weak self] in
            guard case .success(let client) = MCPClient.shared(config: saved) else {
                return
            }
            do {
                _ = try await client.accessToken()
                Log.write("login: credentials still good")
            } catch {
                Log.write("login: stored credentials do not work — \(error)")
                await MainActor.run {
                    guard let self else { return }
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = "Atrium PA will not accept this sign-in"
                    alert.informativeText =
                        "Recordings will queue up on disk until it does — "
                        + "nothing is lost.\n\n\(error)"
                    alert.addButton(withTitle: "Log In…")
                    alert.addButton(withTitle: "Settings…")
                    alert.addButton(withTitle: "Later")
                    switch alert.runModal() {
                    case .alertFirstButtonReturn: self.logIn()
                    case .alertSecondButtonReturn: self.showSettings()
                    default: break
                    }
                }
            }
        }
    }

    private func promptForConnectionIfNeeded() {
        // `--login` is an explicit instruction to do the thing this
        // prompt asks about, and `runModal` blocks the main thread, so
        // asking first would deadlock the flag it is asking about.
        guard !CommandLine.arguments.contains("--login") else { return }
        guard config.uploadEnabled, !config.didPromptForConnection,
            !isFullyConfigured
        else { return }

        config.didPromptForConnection = true
        try? config.save()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Log.write("no credentials on launch — offering to sign in")
            NSApp.activate(ignoringOtherApps: true)
            // With no address there is nothing to log in *to*, and
            // offering to anyway is a dead end: `logIn()` refuses,
            // reporting an error, on the first launch of a fresh
            // install. Ask for the address first, in the one place it
            // can be typed. `FirstRun` decides, so the rule is testable.
            let needsAddress =
                FirstRun.offer(for: self.config, hasSecret: self.hasStoredSecret)
                == .openSettings

            let alert = NSAlert()
            alert.messageText = "Connect to Atrium PA"
            alert.informativeText =
                "Atrium PA Capture records meetings and uploads them for "
                + "transcription."
                + (needsAddress
                    ? "\n\nIt needs the address of your Atrium PA server, then "
                        + "one sign-in. Both are in Settings › Atrium PA."
                    : "\n\nSign in once and it will keep uploading on its own.")
                + "\n\nRecordings are kept on disk until then, so nothing is "
                + "lost if you do this later."
            alert.addButton(withTitle: needsAddress ? "Open Settings…" : "Log in…")
            alert.addButton(withTitle: "Not now")
            if alert.runModal() == .alertFirstButtonReturn {
                if needsAddress {
                    self.openSettings(tab: "Atrium PA")
                } else {
                    self.logIn()
                }
            }
        }
    }

    /// Configured *and* holding a secret. `AtriumConfig.isConfigured`
    /// cannot answer the second half: the secret is in the keychain, not
    /// in the config file.
    ///
    /// Reads a cached answer, never the keychain — see
    /// `refreshCredentialState`.
    private var isFullyConfigured: Bool {
        config.isConfigured && hasStoredSecret
    }

    /// Whether the keychain currently holds a secret for `clientID`.
    ///
    /// Cached deliberately. `SecItemCopyMatching` is a synchronous round
    /// trip to securityd, and when securityd decides to ask for the
    /// login password it raises an **app-modal** dialog with that call
    /// still on the stack. `refreshMenu()` used to read it directly,
    /// which froze the whole app during launch: sampled, the main thread
    /// sat inside `SecItemCopyMatching` for the entire run — no window,
    /// no menu, no log line after "panel shown".
    ///
    /// `make trust-keychain` stops the prompt appearing at all. This
    /// stops it being able to take the UI with it when it does.
    private var hasStoredSecret = false

    /// Re-read the keychain off the main thread and update the UI.
    private func refreshCredentialState(then: (() -> Void)? = nil) {
        let clientID = config.clientID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let present =
                !clientID.isEmpty && Keychain.clientSecret(for: clientID) != nil
            DispatchQueue.main.async {
                guard let self else { return }
                let changed = self.hasStoredSecret != present
                self.hasStoredSecret = present
                if changed {
                    self.refreshMenu()
                    self.activityWindow?.reload()
                    self.settingsWindow?.refreshPanes()
                }
                then?()
            }
        }
    }

    /// What the account strip in the activity window says.
    private var accountStatus: (description: String, signedIn: Bool) {
        if config.baseURL.isEmpty {
            return ("Not connected — set a server address in Settings › Atrium PA", false)
        }
        let host = URL(string: config.baseURL)?.host ?? config.baseURL
        if !isFullyConfigured {
            return ("Not signed in to \(host)", false)
        }
        return ("Signed in to \(host)", true)
    }

    /// Sign out: forget the credentials, keep the recordings.
    ///
    /// The queue keeps running against a client it can no longer mint a
    /// token for, which would fail every item in it, so it is told to
    /// stand down at the same time. Nothing on disk is deleted — a
    /// recording that has not been uploaded is still the only copy, and
    /// signing out is not a request to throw it away.
    @objc private func logOut() {
        guard isFullyConfigured else { return }
        let clientID = config.clientID
        Keychain.removeRefreshToken(for: clientID)
        Keychain.removeClientSecret(for: clientID)
        Log.write("logout: cleared credentials for \(clientID)")

        var updated = config
        updated.clientID = ""
        try? updated.save()
        config = updated

        hasStoredSecret = false
        MCPClient.forgetShared()
        note(clientID, Date(), "signed out of Atrium PA")
        refreshMenu()
        activityWindow?.reload()
        settingsWindow?.refreshPanes()
        Task { [weak self] in await self?.uploadQueue.updateConfig(updated) }
    }

    /// Sign in through the browser.
    ///
    /// Registers this app with Atrium PA, opens the consent page, and
    /// keeps the refresh token that comes back. Nothing to paste: the
    /// client ID and secret are issued by the server during the flow.
    @objc private func logIn() {
        guard config.baseURL.isEmpty == false else {
            ConnectionSheet.report(
                title: "No Atrium PA address",
                message: "Type the address of your Atrium PA server into the "
                    + "Server field in Settings › Atrium PA, then sign in.",
                success: false)
            return
        }
        Log.write("login: starting browser flow")

        let current = config
        // Reuse the registered client if there is one, so signing in
        // again does not leave a trail of registrations behind.
        let existing = Keychain.clientSecret(for: current.clientID).map {
            (id: current.clientID, secret: $0)
        }

        Task { [weak self] in
            do {
                let result = try await OAuthLogin.run(
                    config: current, existingClient: existing,
                    openURL: { NSWorkspace.shared.open($0) })

                var updated = current
                updated.clientID = result.clientID
                try? Keychain.setClientSecret(result.clientSecret, for: result.clientID)
                try? Keychain.setRefreshToken(result.refreshToken, for: result.clientID)
                try? updated.save()

                // Signing in can land on a *different* client than the
                // one we started with: a registration's scope ceiling is
                // fixed when it is created, so widening what the app asks
                // for forces a new one. Leaving the old secret behind
                // would mean a credential in the keychain that nothing
                // can use and nothing will ever clean up.
                if result.clientID != current.clientID, !current.clientID.isEmpty {
                    Keychain.removeRefreshToken(for: current.clientID)
                    Keychain.removeClientSecret(for: current.clientID)
                    Log.write(
                        "login: replaced client \(current.clientID) with "
                            + "\(result.clientID)")
                }

                await MainActor.run {
                    guard let self else { return }
                    self.config = updated
                    self.hasStoredSecret = true
                    MCPClient.forgetShared()
                    self.note(updated.clientID, Date(), "signed in to Atrium PA")
                    self.settingsWindow?.refreshPanes()
                    ConnectionSheet.report(
                        title: "Signed in",
                        message: "Atrium PA granted scope \(result.scope). "
                            + "Queued recordings will start uploading.",
                        success: true)
                    self.refreshMenu()
                }
                await self?.uploadQueue.updateConfig(updated)
                await self?.uploadQueue.tick()
            } catch {
                Log.write("login: failed — \(error)")
                await MainActor.run {
                    self?.settingsWindow?.refreshPanes()
                    ConnectionSheet.report(
                        title: "Not signed in", message: String(describing: error),
                        success: false)
                }
            }
        }
    }

    /// The settings window, built once and re-read each time it opens.
    @objc private func showSettings() {
        openSettings(tab: nil)
    }

    /// Deliberately not an overload of `showSettings()`. Two methods of
    /// that name make `#selector(showSettings)` ambiguous, and the
    /// compiler says so in the menu-building code rather than here.
    private func openSettings(tab: String?) {
        let window = settingsWindow ?? SettingsWindow(actions: settingsActions())
        settingsWindow = window
        window.present(tab: tab)
    }

    private func settingsActions() -> SettingsWindow.Actions {
        // The panel is owned here, not by the config, so the switch in
        // General talks to it through these two closures.
        PanelVisibility.isVisible = { [weak self] in self?.isPanelVisible ?? false }
        PanelVisibility.setVisible = { [weak self] wanted in
            guard let self, wanted != self.isPanelVisible else { return }
            self.togglePanel()
        }

        return SettingsWindow.Actions(
            config: { [weak self] in self?.config ?? .defaults },
            save: { [weak self] updated in self?.applyConfig(updated) },
            logIn: { [weak self] in self?.logIn() },
            logOut: { [weak self] in self?.logOut() },
            testConnection: { [weak self] in
                guard let saved = self?.config else { return }
                Task { await self?.testConnection(saved) }
            },
            // Cached, never read from the keychain here: this is called
            // during layout, and `SecItemCopyMatching` on the main
            // thread is what froze the whole app once already.
            isSignedIn: { [weak self] in self?.isFullyConfigured ?? false },
            notificationStatus: { [weak self] in self?.notifier.status ?? .notDetermined },
            editAllowlist: { [weak self] in self?.editAllowlist() },
            reloadAllowlist: { [weak self] in self?.reloadAllowlist() },
            moveRecordings: { [weak self] folder in self?.setRecordingsFolder(folder) })
    }

    /// Save a config edited from the settings window and tell everything
    /// that reads it.
    private func applyConfig(_ updated: AtriumConfig) {
        // A cached client holds a bearer for the old server and the old
        // client id.
        if updated.baseURL != config.baseURL || updated.clientID != config.clientID {
            MCPClient.forgetShared()
        }
        config = updated
        try? config.save()
        let saved = config
        Task { [weak self] in await self?.uploadQueue.updateConfig(saved) }
        refreshMenu()
    }

    /// Point new recordings somewhere else.
    ///
    /// Existing recordings are not moved. Every queue item is stamped
    /// with its current folder *first*, so the ones already on disk stay
    /// findable — without that, changing this setting would leave a
    /// queue whose every file had vanished, which looks exactly like
    /// data loss.
    private func setRecordingsFolder(_ folder: URL?) {
        let previous = AppPaths.recordings
        Task { [weak self] in
            await self?.uploadQueue.pinDirectories(to: previous)
            await MainActor.run {
                guard let self else { return }
                var updated = self.config
                updated.recordingsDirectory = folder?.path
                AppPaths.recordingsOverride = folder
                try? AppPaths.ensureDirectories()
                self.applyConfig(updated)
                Log.write(
                    "recordings folder is now \(AppPaths.recordings.path) "
                        + "(was \(previous.path))")
                self.activityWindow?.reload()
            }
        }
    }

    /// Delete a recording — here, and optionally in Atrium PA.
    ///
    /// The server half is `delete_capture`, which needs the
    /// `pa.ingest:delete` scope. A sign-in from before that scope
    /// existed does not carry it and cannot grow it, so the failure is
    /// reported as "sign in again" rather than as a bare FORBIDDEN.
    ///
    /// Three things the dialog has to say, none of them obvious:
    ///
    /// * The server delete is a **soft** delete. It is reversible for a
    ///   grace window, and reversing it is the only clean way back —
    ///   which is why it matters that the tool ships with its own undo.
    /// * It does **not** remove the audio. Atrium PA's vault is swept by
    ///   a separate job on file age, so a deleted capture's audio sits
    ///   there until its own TTL runs out. "Deleted" does not mean
    ///   "gone", and a dialog that implied it would be lying.
    /// * Re-uploading the same file afterwards does not work, and does
    ///   not fail cleanly: the duplicate check skips deleted rows, so
    ///   the upload proceeds and collides with a dedup key that was
    ///   deliberately retained. So "delete it and send it again" is not
    ///   a recovery, and the dialog should not let somebody discover
    ///   that on their own.
    private func confirmDelete(_ item: QueueItem) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Delete “\(item.title ?? item.audioFile)”?"

        var detail =
            "Removes the audio and the queue entry from this Mac. "
            + "This cannot be undone."
        if item.captureID != nil {
            detail +=
                "\n\nAtrium PA can be told to delete its copy too. That hides "
                + "the recording and its transcript and is reversible for about "
                + "90 days — but it does not erase the audio from the server, "
                + "which is removed later on its own schedule.\n\n"
                + "Uploading the same recording again during those 90 days will "
                + "fail, so deleting is not a way to start over."
        }
        alert.informativeText = detail
        alert.alertStyle = .warning

        alert.addButton(withTitle: "Delete From This Mac")
        if item.captureID != nil {
            alert.addButton(withTitle: "Delete Here and in Atrium PA")
        }
        alert.addButton(withTitle: "Cancel")

        let choice = alert.runModal()
        let localOnly = choice == .alertFirstButtonReturn
        let everywhere = item.captureID != nil && choice == .alertSecondButtonReturn
        guard localOnly || everywhere else { return }

        if everywhere, let captureID = item.captureID {
            deleteOnServer(captureID: captureID, then: item)
        } else {
            deleteLocally(item)
        }
    }

    private func deleteLocally(_ item: QueueItem) {
        Task { [weak self] in
            await self?.uploadQueue.deleteItem(id: item.id)
            await MainActor.run { self?.activityWindow?.reload() }
        }
    }

    /// Server first, then disk.
    ///
    /// That order on purpose: if the server call fails, the item is
    /// still here to try again with. Deleting locally first and then
    /// failing would leave a capture in Atrium PA that this app no
    /// longer has a row for — unreachable from the one place the user
    /// was working.
    private func deleteOnServer(captureID: Int, then item: QueueItem) {
        guard let client = makeClient() else {
            ConnectionSheet.report(
                title: "Not signed in",
                message: "Log in to Atrium PA before deleting from it. Nothing "
                    + "has been deleted.",
                success: false)
            return
        }

        Task { [weak self] in
            do {
                let result = try await client.deleteCapture(
                    captureID: captureID, deleted: true,
                    reason: "deleted from Atrium PA Capture on the Mac")
                Log.write(
                    "delete: capture \(captureID) status \(result.status), "
                        + "changed \(result.changed), "
                        + "alreadyDeleted \(result.alreadyDeleted)")
                await self?.uploadQueue.deleteItem(id: item.id)
                await MainActor.run { self?.activityWindow?.reload() }
            } catch {
                Log.write("delete: capture \(captureID) failed — \(error)")
                await MainActor.run {
                    // Nothing local was touched, so the row is still
                    // there to try again from.
                    if case MCPClient.ClientError.loginRequired(let why) = error {
                        ConnectionSheet.report(
                            title: "Log in to Atrium PA again",
                            message: "Deleting needs a permission your current "
                                + "sign-in does not have. Choose “Log in to "
                                + "Atrium PA again…”, then try again. Nothing has "
                                + "been deleted.\n\n\(why)",
                            success: false)
                    } else {
                        ConnectionSheet.report(
                            title: "Could not delete from Atrium PA",
                            message: "Nothing has been deleted, here or there."
                                + "\n\n\(error)",
                            success: false)
                    }
                }
            }
        }
    }

    /// Write the transcript to Downloads, with names against it.
    ///
    /// Markdown rather than the raw export: the JSON has both the
    /// cleaned and the verbatim text of every turn and is the right
    /// archival artefact, but nobody reads it. What is wanted in a
    /// Downloads folder is the conversation.
    ///
    /// Unconfirmed names are written as unconfirmed. A transcript that
    /// has left this app gets quoted and forwarded, and by then nobody
    /// can see the match percentage that produced the name.
    private func saveTranscript(_ item: QueueItem) {
        guard let transcriptID = item.transcriptID else { return }
        guard let client = makeClient() else {
            ConnectionSheet.report(
                title: "Not signed in",
                message: "Log in to Atrium PA before downloading a transcript.",
                success: false)
            return
        }

        Task { [weak self] in
            do {
                let export = try await client.transcriptExport(transcriptID: transcriptID)
                if export.quarantined {
                    await MainActor.run {
                        ConnectionSheet.report(
                            title: "That transcript is quarantined",
                            message: "Atrium PA exports metadata only for a "
                                + "quarantined recording — there are no turns to "
                                + "save.",
                            success: false)
                    }
                    return
                }

                let data = try await client.fetchExport(export)
                let document = try TranscriptDocument(data: data)
                let format = self?.config.transcriptFormat ?? .markdown
                // The document's own title, not the local one. The
                // local title names the app that did the capturing, so
                // it filed every Teams call as "Teams meeting.md" and
                // they overwrote each other in Downloads. Only a title
                // a person typed beats the transcript's own.
                let name = TranscriptDocument.filename(
                    title: item.titleIsHumanSupplied
                        ? (item.title ?? document.title) : document.title,
                    occurredAt: item.occurredAt, format: format)
                let destination = try FileManager.default.url(
                    for: .downloadsDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true
                ).appending(path: name)

                try Data(document.rendered(as: format).utf8)
                    .write(to: destination, options: .atomic)
                Log.write(
                    "transcript \(transcriptID) saved to \(destination.lastPathComponent) "
                        + "— \(document.turns.count) turn(s), "
                        + "\(document.speakers.count) speaker(s)")

                await MainActor.run {
                    // Revealed rather than announced: the file is the
                    // point, and a dialog saying "saved" is one more
                    // thing to dismiss before getting to it.
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            } catch {
                Log.write("transcript \(transcriptID): could not save — \(error)")
                await MainActor.run {
                    if case MCPClient.ClientError.loginRequired(let why) = error {
                        ConnectionSheet.report(
                            title: "Log in to Atrium PA again",
                            message: "Downloading a transcript needs a permission "
                                + "your current sign-in does not have.\n\n\(why)",
                            success: false)
                    } else {
                        ConnectionSheet.report(
                            title: "Could not save the transcript",
                            message: String(describing: error), success: false)
                    }
                }
            }
        }
    }

    /// This recording's own lines from the app log.
    private func showLog(for item: QueueItem) {
        let window = logWindow ?? LogWindow()
        logWindow = window
        // The handles one recording is known by, in the places it is
        // known by them: the file stem while it is captured and encoded,
        // the capture id once Atrium PA has one, the transcript id after
        // that. No single one appears on every line of its own story.
        var keys = [(item.audioFile as NSString).deletingPathExtension]
        if let captureID = item.captureID { keys.append("capture \(captureID)") }
        if let transcriptID = item.transcriptID {
            keys.append("transcript \(transcriptID)")
        }
        window.present(title: item.title ?? item.audioFile, keys: keys)
    }

    /// Mint a token and read the queue back. A credential that is wrong
    /// should say so now, not silently in three hours when a meeting
    /// fails to arrive.
    private func testConnection(_ config: AtriumConfig) async {
        switch MCPClient.shared(config: config) {
        case .failure(let error):
            await MainActor.run {
                ConnectionSheet.report(
                    title: "Not connected", message: error.description, success: false)
            }
        case .success(let client):
            do {
                _ = try await client.accessToken()
                await MainActor.run {
                    ConnectionSheet.report(
                        title: "Connected",
                        message: "Atrium PA issued a token for scope pa.ingest.",
                        success: true)
                }
                await uploadQueue.tick()
            } catch {
                await MainActor.run {
                    ConnectionSheet.report(
                        title: "Not connected",
                        message: String(describing: error), success: false)
                }
            }
        }
    }
}
