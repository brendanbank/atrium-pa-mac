import AVFoundation
import AtriumCore
import Foundation

/// Tests that need nothing but this machine.
///
/// Note what is *not* here: capture. A bare binary cannot hold the
/// audio-capture TCC grant, so `ProcessTap` in this process would create
/// a tap, fire its IOProc on schedule, and deliver a stream of zeroes —
/// a test asserting "audio flows" would fail here and pass in the
/// bundled app, which is worse than no test. Capture is verified by
/// `Probes/tap-capture` inside a real bundle, and by the mic and far-end
/// meters on the recording panel.
///
/// What *is* here is everything that failure mode has been hiding: the
/// drift arithmetic, the session state machine, the queue's durability,
/// the JSON-RPC envelope, and the encode step.
enum UnitTests {

    static func run(_ h: Harness) {
        alignment(h)
        allowlist(h)
        configuration(h)
        sessions(h)
        queue(h)
        jsonRPC(h)
        encoding(h)
        meter(h)
    }

    // MARK: - SpectrumAnalyzer

    /// The panel's whole job is to say "audio is arriving" at a glance,
    /// so how far the bars actually travel for real speech levels is a
    /// property worth pinning rather than eyeballing. These numbers are
    /// the meter's calibration.
    private static func meter(_ h: Harness) {
        h.group("SpectrumAnalyzer — how far the bars travel")

        /// Feed a steady tone at `amplitude` until the smoothing settles,
        /// and report the tallest band.
        func settledPeak(amplitude: Float, hz: Double = 300) -> Float {
            let analyzer = SpectrumAnalyzer()
            let frames = 1024
            var phase = 0.0
            let step = 2 * Double.pi * hz / 48_000
            // Enough blocks for the fast-attack smoothing to converge.
            for _ in 0..<40 {
                var block = [Float](repeating: 0, count: frames)
                for index in 0..<frames {
                    block[index] = amplitude * Float(sin(phase))
                    phase += step
                }
                analyzer.process(samples: block, channels: 1)
            }
            return analyzer.levels.max() ?? 0
        }

        /// Broadband noise at a given peak amplitude — far closer to
        /// speech than a sine, and the case a sine was hiding: a tone
        /// puts all its energy in one FFT bin and reads high, while real
        /// speech spreads over hundreds of bins and reads low.
        /// Deterministic, so a failure is reproducible.
        func settledDisplay(noiseAmplitude: Float) -> Float {
            let analyzer = SpectrumAnalyzer()
            var state: UInt64 = 0x2545_F491_4F6C_DD1D
            for _ in 0..<40 {
                var block = [Float](repeating: 0, count: 1024)
                for index in 0..<1024 {
                    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    let unit = Float(Double((state >> 33) & 0xFFFF) / 65535.0) * 2 - 1
                    block[index] = unit * noiseAmplitude
                }
                analyzer.process(samples: block, channels: 1)
            }
            return analyzer.displayLevels.max() ?? 0
        }

        h.test("broadband speech at a normal level nearly fills the bars") {
            // The case that matters. A voice in a quiet room measured
            // 0.043–0.096 peak on this project's own recordings.
            let level = settledDisplay(noiseAmplitude: 0.05)
            h.note(String(format: "broadband 0.05 → %.2f of full height", level))
            try expect(
                level > 0.6,
                "real speech only reaches \(level) — the indicator is not doing "
                    + "its one job")
        }

        h.test("a very quiet voice still registers clearly") {
            let level = settledDisplay(noiseAmplitude: 0.01)
            h.note(String(format: "broadband 0.01 → %.2f of full height", level))
            try expect(level > 0.35, "a quiet voice only reaches \(level)")
        }

        h.test("room tone stays near the floor — presence is an absolute gate") {
            // The danger of normalising the shape: noise must not read as
            // healthy. This is the assertion that keeps the indicator
            // honest.
            let level = settledDisplay(noiseAmplitude: 0.0008)
            h.note(String(format: "room tone 0.0008 → %.2f of full height", level))
            try expect(
                level < 0.25,
                "a noise floor displays at \(level) — the indicator would look "
                    + "healthy on a dead stream")
        }

        h.test("a quiet room at speaking distance drives the bars visibly") {
            // 0.05 is what this project's own recordings measured for a
            // normal voice in a quiet room (micPeak 0.043–0.096).
            let level = settledPeak(amplitude: 0.05)
            h.note(String(format: "amplitude 0.05 → %.2f of full height", level))
            try expect(
                level > 0.45,
                "a normal speaking level only reaches \(level) — the meter is "
                    + "spending its life at the bottom of its travel")
            try expect(level < 1, "already clipped at a quiet level: \(level)")
        }

        h.test("a loud signal approaches full height without pinning early") {
            let level = settledPeak(amplitude: 0.5)
            h.note(String(format: "amplitude 0.50 → %.2f of full height", level))
            try expect(level > 0.8, "a loud signal only reaches \(level)")
        }

        h.test("louder always reads higher — the meter is monotonic") {
            var previous: Float = -1
            for amplitude in [Float(0.005), 0.02, 0.05, 0.15, 0.4, 0.9] {
                let level = settledPeak(amplitude: amplitude)
                try expect(
                    level >= previous,
                    "\(amplitude) read \(level), lower than the step below it")
                previous = level
            }
        }

        h.test("folding to a few bars never drops part of the spectrum") {
            // The panel draws 5 bars from 20 bands. Energy anywhere in
            // the spectrum has to move something, or the meter says "not
            // recording" while the recording is fine.
            for band in 0..<20 {
                var levels = [Float](repeating: 0, count: 20)
                levels[band] = 1
                for bars in [3, 5, 7] {
                    let folded = SpectrumAnalyzer.fold(levels: levels, into: bars)
                    try expect(
                        folded.contains(where: { $0 >= 1 }),
                        "band \(band) vanished when folded onto \(bars) bars: \(folded)")
                }
            }
        }

        h.test("folding preserves the loudest band and never invents level") {
            let levels: [Float] = (0..<20).map { Float($0) / 19 }
            let folded = SpectrumAnalyzer.fold(levels: levels, into: 5)
            h.note(
                "20 bands ramped 0→1 folded to 5 bars: "
                    + "\(folded.map { String(format: "%.2f", $0) })")
            try expectEqual(folded.count, 5, "bar count")
            try expectEqual(folded.max(), levels.max(), "loudest band survives")
            try expect(
                folded.allSatisfy { $0 <= 1 }, "fold invented level above the source")
            try expect(
                zip(folded, folded.dropFirst()).allSatisfy { $0 <= $1 },
                "a rising spectrum folded to something non-monotonic: \(folded)")
        }

        h.test("silence stays at the floor — a dead stream must look dead") {
            let analyzer = SpectrumAnalyzer()
            for _ in 0..<40 {
                analyzer.process(samples: [Float](repeating: 0, count: 1024), channels: 1)
            }
            let level = analyzer.displayLevels.max() ?? 0
            h.note(String(format: "silence → %.4f of full height", level))
            try expect(level < 0.02, "silence reads \(level) — that is not a floor")
            try expectEqual(analyzer.instantPeak, 0, "instantPeak on silence")
        }
    }

    // MARK: - StreamAligner

    private static func makeAligner(
        slack: Int = 12_000, correction: Int = 48, owed: Int = 48_000
    ) -> StreamAligner {
        StreamAligner(jitterSlack: slack, maxCorrection: correction, maxOwed: owed)
    }

    private static func alignment(_ h: Harness) {
        h.group("StreamAligner — mic held against the tap clock")

        h.test("a stream that keeps up is left alone") {
            var aligner = makeAligner()
            for _ in 0..<100 {
                let decision = aligner.plan(wanted: 1920, available: 1920)
                try expectEqual(decision, .init(skip: 0, take: 1920, pad: 0))
            }
            try expectEqual(aligner.netOffset, 0, "net offset")
        }

        h.test("a short buffer is padded and the debt is recorded") {
            var aligner = makeAligner()
            let decision = aligner.plan(wanted: 1920, available: 1900)
            try expectEqual(decision, .init(skip: 0, take: 1900, pad: 20))
            try expectEqual(aligner.owed, 20, "owed")
        }

        h.test("padding is repaid by discarding the oldest frames") {
            var aligner = makeAligner()
            _ = aligner.plan(wanted: 1920, available: 1900)  // pad 20
            try expectEqual(aligner.owed, 20, "owed after the hiccup")

            // The 20 late frames are now sitting in the buffer. They must
            // be discarded, not written: writing them would leave the mic
            // channel 20 frames behind for the rest of the meeting.
            let decision = aligner.plan(wanted: 1920, available: 1940)
            try expectEqual(decision, .init(skip: 20, take: 1920, pad: 0))
            try expectEqual(aligner.owed, 0, "owed after repayment")
            try expectEqual(aligner.netOffset, 0, "net offset")
        }

        h.test("a correction never exceeds the per-cycle cap") {
            var aligner = makeAligner(correction: 48)
            // Backlog far past the jitter window: the mic clock is fast.
            let decision = aligner.plan(wanted: 1920, available: 60_000)
            try expectEqual(decision.skip, 48, "skip")
            try expectEqual(decision.take, 1920, "take")
        }

        h.test("a correction never eats frames this cycle needs") {
            var aligner = makeAligner()
            _ = aligner.plan(wanted: 1920, available: 0)  // owe a full block
            let decision = aligner.plan(wanted: 1920, available: 1920)
            try expectEqual(decision.skip, 0, "skip")
            try expectEqual(decision.pad, 0, "pad")
        }

        h.test("silence debt is capped so a stall cannot become permanent") {
            var aligner = makeAligner(owed: 4800)
            for _ in 0..<100 { _ = aligner.plan(wanted: 1920, available: 0) }
            try expectEqual(aligner.owed, 4800, "owed is clamped")
        }

        /// Run `cycles` drains against a mic clock running at `rate`
        /// times the master's, returning the aligner and the backlog it
        /// left in the buffer.
        func simulate(rate: Double, hours: Double, slack: Int = 4800)
            -> (aligner: StreamAligner, backlog: Int)
        {
            var aligner = makeAligner(slack: slack)
            let cycles = Int(hours * 3600 / 0.04)
            var produced = 0.0
            var consumed = 0.0
            var backlog = 0
            for _ in 0..<cycles {
                produced += 1920 * rate
                let arrived = Int(produced) - Int(consumed)
                consumed = Double(Int(produced))
                backlog += arrived
                let decision = aligner.plan(wanted: 1920, available: backlog)
                backlog -= decision.skip + decision.take
            }
            return (aligner, backlog)
        }

        h.test("an hour of a fast mic clock is absorbed, not written as gaps") {
            // The case the whole class exists for. 0.05% is a plausible
            // disagreement between two nominally-48 kHz clocks — a USB
            // interface against the built-in output. Over an hour it is
            // 1.8 seconds of surplus mic audio.
            //
            // Note what is asserted, because `netOffset` is the wrong
            // number here: discarding the surplus is the *correct*
            // behaviour, so a large `droppedFrames` is success, not
            // drift. What must hold is that nothing is written as
            // silence, the backlog stops growing (or the ring overruns
            // and the audio is lost with no number attached), and the
            // residual channel offset is a small constant.
            let (aligner, backlog) = simulate(rate: 1.0005, hours: 1)
            let surplus = Int(3600 * 48_000 * 0.0005)
            h.note(
                "surplus \(surplus) frames, dropped \(aligner.droppedFrames), "
                    + "backlog \(backlog) (\(backlog / 48) ms)")

            try expectEqual(aligner.paddedFrames, 0, "silence written into a fast stream")
            try expect(
                aligner.droppedFrames > surplus - 6000,
                "only \(aligner.droppedFrames) of \(surplus) surplus frames removed — "
                    + "the correction cannot keep up")
            try expect(
                backlog <= 4800 + 1920,
                "backlog settled at \(backlog) frames rather than the jitter window")
            try expect(
                backlog / 48 <= 150,
                "the mic channel ends up \(backlog / 48) ms behind the far-end")
        }

        h.test("an hour of a slow mic clock is padded, and stays wall-clock aligned") {
            // The mirror case: the mic produces less than the master
            // consumes. There is no audio to discard, so the deficit has
            // to be written as silence — which is right, because that is
            // what keeps the mic channel aligned to wall-clock time
            // rather than sliding earlier.
            let (aligner, backlog) = simulate(rate: 0.9995, hours: 1)
            let deficit = Int(3600 * 48_000 * 0.0005)
            h.note("deficit \(deficit) frames, padded \(aligner.paddedFrames)")

            try expectEqual(aligner.droppedFrames, 0, "audio discarded from a slow stream")
            try expectNear(
                Double(aligner.paddedFrames), Double(deficit), tolerance: 6000,
                "padding should track the deficit")
            try expect(backlog < 1920, "backlog \(backlog) — a slow stream cannot build one")
        }

        h.test("a perfectly matched clock needs no correction at all") {
            let (aligner, _) = simulate(rate: 1.0, hours: 1)
            try expectEqual(aligner.paddedFrames, 0, "padded")
            try expectEqual(aligner.droppedFrames, 0, "dropped")
        }
    }

    // MARK: - Allowlist

    private static func allowlist(_ h: Harness) {
        h.group("Allowlist — prefix match, because helpers hold the mic")

        h.test("a recording is called what it actually was") {
            try expectEqual(
                MeetingTitle.title(bundleID: "com.microsoft.teams2.helper", isManual: false),
                "Teams meeting", "Teams")
            try expectEqual(
                MeetingTitle.title(bundleID: "us.zoom.xos", isManual: false),
                "Zoom call", "Zoom")

            // Chrome is "Browser call" on purpose. The helper grabs the
            // microphone identically for Meet, Teams-in-a-browser,
            // Whereby, a voice note or a dictation box — that is the
            // whole reason the far-end gate exists — so naming it
            // "Google Meet" would be quietly wrong in a field somebody
            // reads months later to work out what a recording was.
            try expectEqual(
                MeetingTitle.title(bundleID: "com.google.Chrome.helper", isManual: false),
                "Browser call", "Chrome must not claim to be Meet")

            // A recording started by hand is as likely to be a
            // conversation in the room as a call, so it claims neither.
            try expectEqual(
                MeetingTitle.title(bundleID: "launched with --record-now", isManual: true),
                "Recording", "manual")

            // An app the user added themselves: ugly, but true.
            try expectEqual(
                MeetingTitle.title(bundleID: "com.example.app", isManual: false),
                "com.example.app call", "unknown bundle")
        }

        h.test("the menu and the transcript list cannot drift apart") {
            // One table behind both. The menu used to say "Meet" while
            // the upload said something else.
            try expectEqual(
                MeetingTitle.shortName(bundleID: "com.google.Chrome.helper"),
                "Browser", "short name")
            try expectEqual(
                MeetingTitle.shortName(bundleID: "com.microsoft.teams2.helper"),
                "Teams", "short name")
        }


        h.test("the helper processes that actually hold the mic match") {
            let list = Allowlist.defaults
            // Measured on macOS 26.5; see CLAUDE.md.
            for bundleID in [
                "com.microsoft.teams2.helper",
                "com.microsoft.teams2.modulehost",
                "com.google.Chrome.helper",
                "net.whatsapp.WhatsApp",
                "us.zoom.xos",
            ] {
                try expect(list.matches(bundleID: bundleID), "\(bundleID) did not match")
            }
        }

        h.test("unrelated processes do not match") {
            let list = Allowlist.defaults
            for bundleID in ["com.apple.corespeechd", "com.apple.Safari", ""] {
                try expect(
                    !list.matches(bundleID: bundleID), "\(bundleID) matched by mistake")
            }
            try expect(!list.matches(bundleID: nil), "nil matched")
        }

        h.test("an empty prefix cannot match everything") {
            let list = Allowlist(prefixes: [""])
            try expect(
                !list.matches(bundleID: "com.apple.corespeechd"),
                "an empty prefix swallowed an unrelated bundle ID")
        }
    }

    // MARK: - Config

    private static func configuration(_ h: Harness) {
        h.group("AtriumConfig — endpoints and persistence")

        h.test("a config written before a field existed still signs you in") {
            // `load()` answers a decode failure with `.defaults`, and
            // `.defaults` has no clientID — so one added field would
            // have signed every install out, with no dialog and no log
            // line to tell that from an expired token.
            try withTemporaryRoot {
                let legacy = """
                    {"baseURL":"https://pa.example.invalid","clientID":"dcr_abc",
                     "localRetentionDays":7,"uploadEnabled":true,
                     "didPromptForConnection":true}
                    """
                try AppPaths.ensureDirectories()
                try Data(legacy.utf8).write(to: AppPaths.configFile)

                let loaded = AtriumConfig.load()
                try expectEqual(loaded.clientID, "dcr_abc", "the client survived")
                try expectEqual(
                    loaded.baseURL, "https://pa.example.invalid", "the address survived")

                // ...and it is migrated to the split, rather than
                // silently keeping the old single window that deleted
                // the small copy along with the big one.
                try expectEqual(
                    loaded.masterRetentionDays, 0, "masters go once uploaded")
                try expect(loaded.localRetentionDays < 0, "the m4a is kept")

                // Written back, so the file says what the app believes.
                let reloaded = AtriumConfig.load()
                try expectEqual(
                    reloaded.localRetentionDays, loaded.localRetentionDays,
                    "the migration did not persist")
            }
        }

        h.test("a recording stays findable when the folder moves under it") {
            // Every queue item carries the absolute folder it was written
            // to. Without that, pointing the app at a new disk would
            // resolve yesterday's recordings against today's folder and
            // find nothing — a queue full of files that cannot be
            // opened, which looks exactly like data loss.
            try withTemporaryRoot {
                let old = AppPaths.recordings
                let item = QueueItem(
                    id: UUID(), audioFile: "meeting.m4a",
                    masterFiles: ["meeting.mic.caf"], title: nil, occurredAt: Date(),
                    language: nil, sizeBytes: 1, state: .ready, captureID: 1,
                    transcriptID: nil, attempts: 0, nextAttemptAt: .distantPast,
                    lastError: nil, enqueuedAt: Date(), completedAt: Date(),
                    directory: old.path)

                AppPaths.recordingsOverride = URL(fileURLWithPath: "/tmp/somewhere-else")
                defer { AppPaths.recordingsOverride = nil }

                try expectEqual(
                    item.audioURL.path, old.appending(path: "meeting.m4a").path,
                    "the recording followed the setting instead of staying put")
                try expectEqual(
                    item.masterURLs.first?.path,
                    old.appending(path: "meeting.mic.caf").path, "master path")
            }
        }

        h.test("an item written before the folder was configurable still resolves") {
            // `directory` is absent from every file written before the
            // setting existed, and for those "wherever recordings go now"
            // is the right answer — the folder could not be changed then.
            try withTemporaryRoot {
                let legacy = """
                    {"id":"E13EBD45-5578-427A-8C7C-B64D478F2CFE",
                     "audioFile":"old.m4a","masterFiles":[],"occurredAt":
                     "2026-08-22T14:55:12Z","sizeBytes":1,"state":"ready",
                     "attempts":0,"nextAttemptAt":"2026-08-22T14:55:12Z",
                     "enqueuedAt":"2026-08-22T14:55:12Z"}
                    """
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let item = try decoder.decode(QueueItem.self, from: Data(legacy.utf8))
                try expect(item.directory == nil, "no directory recorded")
                try expectEqual(
                    item.audioURL.path,
                    AppPaths.recordings.appending(path: "old.m4a").path,
                    "a legacy item must resolve against the current folder")
            }
        }

        h.test("the log can be filtered down to one recording") {
            try withTemporaryRoot {
                Log.write("session com.microsoft.teams2.helper started")
                Log.write("queue: capture 12353 now reports 1 unnamed voice(s)")
                Log.write("retention: dropped the masters for 20260822-165512.m4a")
                Log.write("mic: something entirely unrelated")

                let mine = Log.entries(matching: ["20260822-165512", "capture 12353"])
                try expectEqual(mine.count, 2, "matched lines")
                try expect(
                    mine.allSatisfy {
                        $0.contains("20260822-165512") || $0.contains("capture 12353")
                    },
                    "an unrelated line came through: \(mine)")

                // A recording nothing was written about returns nothing,
                // rather than the whole file.
                try expect(
                    Log.entries(matching: ["capture 999"]).isEmpty,
                    "an unknown key matched something")
                try expect(
                    Log.entries(matching: []).isEmpty,
                    "no keys must not mean every line")
            }
        }

        h.test("a fresh install is not offered a login it cannot complete") {
            // Shipped once: with no default server address, the
            // first-launch prompt offered "Log in…", `OAuthLogin.run`
            // refused for want of an address, and the error named a menu
            // item that had been removed when settings were
            // consolidated. Three steps, and the last one pointed at a
            // control that did not exist.
            try expectEqual(
                FirstRun.offer(for: .defaults, hasSecret: false), .openSettings,
                "a fresh install must be asked for an address first")

            var addressed = AtriumConfig.defaults
            addressed.baseURL = "https://atrium-pa.example.com"
            try expectEqual(
                FirstRun.offer(for: addressed, hasSecret: false), .logIn,
                "with an address, the missing piece is the sign-in")

            var signedIn = addressed
            signedIn.clientID = "dcr_abc"
            try expectEqual(
                FirstRun.offer(for: signedIn, hasSecret: true), .nothing,
                "a configured install must not be interrupted")
            // A client id with no secret is not signed in — the secret
            // lives in the keychain, which the config cannot see.
            try expectEqual(
                FirstRun.offer(for: signedIn, hasSecret: false), .logIn,
                "a client id alone is not a sign-in")
        }

        h.test("a fresh install points at nobody") {
            // The default used to be one particular deployment, which was
            // convenient for one person and wrong for everyone else — a
            // checkout should not arrive pointing at somebody's server.
            // Empty is also what makes the connection prompt appear on
            // first launch, which is the right first question.
            try expect(
                AtriumConfig.defaults.baseURL.isEmpty,
                "a default deployment address is baked in")
            try expect(
                !AtriumConfig.defaults.isConfigured,
                "a fresh config claims to be usable")

            try withTemporaryRoot {
                // ...and an existing config with an address keeps it.
                let saved = """
                    {"baseURL":"https://atrium-pa.example.com","clientID":"c",
                     "localRetentionDays":-1,"masterRetentionDays":0,
                     "uploadEnabled":true,"didPromptForConnection":true}
                    """
                try AppPaths.ensureDirectories()
                try Data(saved.utf8).write(to: AppPaths.configFile)
                try expectEqual(
                    AtriumConfig.load().baseURL, "https://atrium-pa.example.com",
                    "an existing address was overwritten")
            }
        }

        h.test("a config that already chose its retention is left alone") {
            try withTemporaryRoot {
                let chosen = """
                    {"baseURL":"https://pa.example.invalid","clientID":"c",
                     "localRetentionDays":30,"masterRetentionDays":3,
                     "uploadEnabled":true,"didPromptForConnection":true}
                    """
                try AppPaths.ensureDirectories()
                try Data(chosen.utf8).write(to: AppPaths.configFile)
                let loaded = AtriumConfig.load()
                try expectEqual(loaded.localRetentionDays, 30, "m4a window")
                try expectEqual(loaded.masterRetentionDays, 3, "master window")
            }
        }


        h.test("endpoints are derived at the root, not under /api") {
            var config = AtriumConfig.defaults
            config.baseURL = "https://example.invalid"
            try expectEqual(config.mcpURL?.path, "/mcp", "mcp path")
            try expectEqual(config.tokenURL?.path, "/oauth/token", "token path")
        }

        h.test("a trailing slash does not produce a double slash") {
            var config = AtriumConfig.defaults
            config.baseURL = "https://example.invalid/"
            try expectEqual(
                config.mcpURL?.absoluteString, "https://example.invalid/mcp", "mcp url")
        }

        h.test("isConfigured needs both a base URL and a client ID") {
            var config = AtriumConfig.defaults
            try expect(!config.isConfigured, "empty config claimed to be configured")
            config.baseURL = "https://example.invalid"
            try expect(!config.isConfigured, "a base URL alone is not enough")
            config.clientID = "abc"
            try expect(config.isConfigured, "a base URL and client ID should suffice")
        }

        h.test("a malformed config file falls back rather than crashing") {
            try withTemporaryRoot {
                try AppPaths.ensureDirectories()
                try Data("{ not json".utf8).write(to: AppPaths.configFile)
                try expectEqual(AtriumConfig.load(), .defaults, "fallback")
            }
        }

        h.test("the client secret is never written to the config file") {
            try withTemporaryRoot {
                var config = AtriumConfig.defaults
                config.baseURL = "https://example.invalid"
                config.clientID = "client-abc"
                try config.save()
                let text = try String(contentsOf: AppPaths.configFile, encoding: .utf8)
                try expect(
                    !text.lowercased().contains("secret"),
                    "config.json mentions a secret: \(text)")
            }
        }
    }

    // MARK: - SessionController

    private static func sessions(_ h: Harness) {
        h.group("SessionController — what counts as a meeting")

        func event(_ bundleID: String, capturing: Bool) -> MicEvent {
            MicEvent(
                objectID: 1, pid: 42, bundleID: bundleID, executable: "helper",
                capturing: capturing)
        }

        h.test("a process outside the allowlist starts nothing") {
            var started = 0
            let controller = SessionController(allowlist: { .defaults })
            controller.onStart = { _ in started += 1 }
            controller.handle(event("com.apple.corespeechd", capturing: true))
            Thread.sleep(forTimeInterval: 0.1)
            try expectEqual(started, 0, "sessions started")
        }

        h.test("an allowlisted helper starts a session") {
            var session: Session?
            let controller = SessionController(allowlist: { .defaults })
            controller.onStart = { session = $0 }
            controller.handle(event("com.google.Chrome.helper", capturing: true))
            try expect(waitUntil { session != nil }, "no session started")
            try expectEqual(session?.farEndConfirmed, false, "far-end pre-confirmed")
        }

        h.test("FaceTime is recognised by the daemon that holds the mic") {
            // `com.apple.FaceTime` is the app you quit to end a call;
            // `com.apple.avconferenced` is what actually takes the input
            // device. An allowlist carrying only the app matches nothing
            // — the same failure an exact-match list has against
            // `com.microsoft.teams2.helper`.
            try expect(
                Allowlist.defaults.matches(bundleID: "com.apple.avconferenced"),
                "avconferenced is not matched, so FaceTime records nothing")
            try expect(
                Allowlist.defaults.matches(bundleID: "com.apple.FaceTime"),
                "FaceTime itself is not matched")
            // Relayed iPhone calls are a different feature, left out on
            // purpose rather than forgotten.
            try expect(
                !Allowlist.defaults.matches(bundleID: "com.apple.TelephonyUtilities"),
                "callservicesd matched — phone calls would record unasked")
        }

        h.test("a session with no far-end audio is discarded, not kept") {
            var policy = SessionPolicy()
            policy.farEndConfirmationWindow = 0.15
            var outcome: SessionOutcome?
            let controller = SessionController(policy: policy, allowlist: { .defaults })
            controller.onEnd = { outcome = $0 }
            controller.handle(event("com.google.Chrome.helper", capturing: true))
            controller.noteCaptureStarted()
            try expect(waitUntil { outcome != nil }, "the far-end gate never fired")
            guard case .discarded = outcome else {
                throw Harness.Failure(
                    message: "expected .discarded, got \(String(describing: outcome))",
                    file: #file, line: #line)
            }
        }

        h.test("the runaway reminder asks late and never answers itself") {
            let policy = SessionPolicy()
            // An hour before the first question, then every half hour.
            // Sooner and a normal meeting gets interrupted; later and a
            // runaway reaches the three-hour cap unasked.
            try expectEqual(policy.runawayReminderAfter, 3600, "first reminder")
            try expectEqual(policy.runawayReminderRepeat, 1800, "repeat")
            try expect(
                policy.runawayReminderAfter < policy.maxDuration,
                "a reminder that never fires before the hard cap is no reminder")

            // The reminder is not a policy that can end a session: there
            // is no threshold here that stops anything, only one that
            // asks. Ending is `stopCurrent()`, driven by the
            // notification's button. Assert the session machinery has no
            // idea the reminder exists — if that ever changes, silence
            // could start costing recordings.
            var outcome: SessionOutcome?
            var fast = policy
            fast.runawayReminderAfter = 0.05
            fast.runawayReminderRepeat = 0.05
            fast.farEndConfirmationWindow = 600
            let controller = SessionController(policy: fast, allowlist: { .defaults })
            controller.onEnd = { outcome = $0 }
            controller.startManual()
            Thread.sleep(forTimeInterval: 0.4)
            try expect(
                outcome == nil,
                "a reminder interval ended a session on its own — it must only ask")
        }

        h.test("joining early does not cost the meeting") {
            // The bug: Teams grabs the microphone the moment you join,
            // and a lobby is silent. The far-end window expired, the
            // session was discarded as "not a call", and no further mic
            // event ever arrived — because the app never let go of the
            // microphone. Nothing restarted when people started talking,
            // so waiting two minutes in a lobby lost the whole meeting.
            var policy = SessionPolicy()
            policy.farEndConfirmationWindow = 0.15
            var starts = 0
            var discards = 0
            let controller = SessionController(policy: policy, allowlist: { .defaults })
            controller.onStart = { _ in
                starts += 1
                // Each candidate re-arms its own window once capture is
                // up, exactly as the app does.
                controller.noteCaptureStarted()
            }
            controller.onEnd = { outcome in
                if case .discarded = outcome { discards += 1 }
            }

            controller.handle(event("com.microsoft.teams2.helper", capturing: true))
            try expect(waitUntil { discards >= 2 }, "the watch was not re-armed")
            try expect(
                starts >= 3,
                "a discarded candidate must be replaced while the mic is still held, "
                    + "got \(starts) start(s)")

            // And when somebody finally speaks, that candidate survives.
            controller.noteFarEndAudio()
            let settled = discards
            Thread.sleep(forTimeInterval: 0.5)
            try expectEqual(
                discards, settled, "a confirmed session was discarded anyway")
        }

        h.test("letting go of the microphone stops the re-arming") {
            // The other half: once the app releases the microphone there
            // is nothing left to wait for, and a candidate that keeps
            // replacing itself would record the desk for ever.
            var policy = SessionPolicy()
            policy.farEndConfirmationWindow = 0.15
            policy.endDebounce = 0.05
            var starts = 0
            let controller = SessionController(policy: policy, allowlist: { .defaults })
            controller.onStart = { _ in
                starts += 1
                controller.noteCaptureStarted()
            }

            controller.handle(event("com.microsoft.teams2.helper", capturing: true))
            controller.handle(event("com.microsoft.teams2.helper", capturing: false))
            Thread.sleep(forTimeInterval: 0.6)
            try expectEqual(starts, 1, "restarted after the microphone was released")
        }

        h.test("the far-end window is measured from capture, not from detection") {
            // The bug this exists for, from a real Teams meeting. Capture
            // does not begin when the session does: on a first run
            // `AudioHardwareCreateProcessTap` blocked for 44 seconds
            // behind the audio-capture permission dialog. The window had
            // been running the whole time, so the recording was judged
            // and thrown away with 16 seconds of audio in it.
            var policy = SessionPolicy()
            policy.farEndConfirmationWindow = 0.4
            var outcome: SessionOutcome?
            let controller = SessionController(policy: policy, allowlist: { .defaults })
            controller.onEnd = { outcome = $0 }

            controller.handle(event("com.microsoft.teams2.helper", capturing: true))
            // Capture takes longer to come up than the whole window.
            Thread.sleep(forTimeInterval: 0.6)
            try expect(
                outcome == nil,
                "discarded before capture had even started — the window was "
                    + "counting against a recording that did not exist yet")

            controller.noteCaptureStarted()
            Thread.sleep(forTimeInterval: 0.15)
            try expect(outcome == nil, "the window restarted but expired immediately")

            // And it does still fire, once capture has had its full say.
            try expect(
                waitUntil(2) { outcome != nil }, "the gate never fired after capture")
        }

        h.test("far-end audio inside the window keeps the session alive") {
            var policy = SessionPolicy()
            policy.farEndConfirmationWindow = 0.3
            var outcome: SessionOutcome?
            let controller = SessionController(policy: policy, allowlist: { .defaults })
            controller.onEnd = { outcome = $0 }
            controller.handle(event("com.google.Chrome.helper", capturing: true))
            controller.noteCaptureStarted()
            Thread.sleep(forTimeInterval: 0.05)
            controller.noteFarEndAudio()
            Thread.sleep(forTimeInterval: 0.5)
            try expect(outcome == nil, "a confirmed call was discarded anyway")
        }

        h.test("a blip shorter than the floor is dropped") {
            var policy = SessionPolicy()
            policy.endDebounce = 0.05
            policy.minimumDuration = 60
            policy.farEndConfirmationWindow = 30
            var outcome: SessionOutcome?
            let controller = SessionController(policy: policy, allowlist: { .defaults })
            controller.onEnd = { outcome = $0 }
            controller.handle(event("us.zoom.xos", capturing: true))
            controller.noteFarEndAudio()
            Thread.sleep(forTimeInterval: 0.05)
            controller.handle(event("us.zoom.xos", capturing: false))
            try expect(waitUntil { outcome != nil }, "the session never ended")
            guard case .discarded(_, let reason) = outcome else {
                throw Harness.Failure(
                    message: "expected .discarded, got \(String(describing: outcome))",
                    file: #file, line: #line)
            }
            try expect(reason.contains("blip"), "unexpected reason: \(reason)")
        }

        h.test("releasing the mic does not end a session inside the debounce") {
            var policy = SessionPolicy()
            policy.endDebounce = 0.4
            policy.farEndConfirmationWindow = 30
            var outcome: SessionOutcome?
            let controller = SessionController(policy: policy, allowlist: { .defaults })
            controller.onEnd = { outcome = $0 }
            controller.handle(event("com.microsoft.teams2.helper", capturing: true))
            controller.handle(event("com.microsoft.teams2.helper", capturing: false))
            Thread.sleep(forTimeInterval: 0.1)
            try expect(outcome == nil, "ended before the debounce elapsed")
            // A reconnect inside the window folds back into the session.
            controller.handle(event("com.microsoft.teams2.helper", capturing: true))
            Thread.sleep(forTimeInterval: 0.5)
            try expect(outcome == nil, "a reconnect ended the session anyway")
        }

        h.test("a manual recording bypasses every gate") {
            var policy = SessionPolicy()
            policy.farEndConfirmationWindow = 0.1
            policy.minimumDuration = 600
            var started: Session?
            var outcome: SessionOutcome?
            let controller = SessionController(policy: policy, allowlist: { .defaults })
            controller.onStart = { started = $0 }
            controller.onEnd = { outcome = $0 }

            controller.startManual()
            try expect(waitUntil { started != nil }, "manual start did not fire")
            try expectEqual(started?.isManual, true, "isManual")
            try expectEqual(
                started?.farEndConfirmed, true, "a manual session must not need far-end")

            // Long enough for the far-end gate to have fired had it applied.
            Thread.sleep(forTimeInterval: 0.3)
            try expect(outcome == nil, "the far-end gate discarded a manual recording")

            controller.stopCurrent()
            try expect(waitUntil { outcome != nil }, "stop did not end the session")
            guard case .completed = outcome else {
                throw Harness.Failure(
                    message: "a manual recording was not kept: "
                        + "\(String(describing: outcome))",
                    file: #file, line: #line)
            }
        }

        h.test("an app grabbing and releasing the mic cannot end a manual recording") {
            var policy = SessionPolicy()
            policy.endDebounce = 0.1
            var outcome: SessionOutcome?
            let controller = SessionController(policy: policy, allowlist: { .defaults })
            controller.onEnd = { outcome = $0 }
            controller.startManual()
            Thread.sleep(forTimeInterval: 0.05)
            controller.handle(event("com.google.Chrome.helper", capturing: true))
            controller.handle(event("com.google.Chrome.helper", capturing: false))
            Thread.sleep(forTimeInterval: 0.4)
            try expect(outcome == nil, "a Chrome tab ended the user's recording")
        }
    }

    // MARK: - UploadQueue

    private static func queue(_ h: Harness) {
        h.group("UploadQueue — durability and retention")

        h.test("the speakers column reports the server, not what we asked for") {
            // Capture 12359 recorded ["Dana Ellis", "Sam Okafor"]
            // locally while Atrium PA had Alex Rivera and Sam
            // Okafor. The column showed the local copy, in preference
            // to everything else, and nothing ever compared them.
            let roster = [
                MCPClient.TranscriptSpeaker(
                    key: "Speaker 1", voiceCluster: 1205, personID: 5,
                    displayName: "Alex Rivera", matchPercent: 100, band: "high",
                    anchored: true, turnCount: 43),
                MCPClient.TranscriptSpeaker(
                    key: "Speaker 2", voiceCluster: 1204, personID: 2572,
                    displayName: "Sam Okafor (#2571)", matchPercent: 100,
                    band: "high", anchored: true, turnCount: 43),
            ]
            let item = QueueItem(
                id: UUID(), audioFile: "a.m4a", masterFiles: [], title: nil,
                occurredAt: Date(), language: nil, sizeBytes: 1, state: .ready,
                captureID: 12359, transcriptID: 848, attempts: 0,
                nextAttemptAt: .distantPast, lastError: nil, enqueuedAt: Date(),
                completedAt: Date(), unknownSpeakers: [], notifiedAt: nil,
                namedSpeakers: ["Dana Ellis", "Sam Okafor"],
                knownSpeakers: roster)

            try expectEqual(
                item.speakerDescription, "Alex Rivera, Sam Okafor (#2571)",
                "the local list won over the server's roster")
            try expect(
                !item.speakerDescription.contains("Dana"),
                "a name this app asked for is not evidence it was applied")
        }

        h.test("an anchored high match is a name; anything less is work") {
            let guess = MCPClient.TranscriptSpeaker(
                key: "Speaker 1", voiceCluster: 1205, personID: 5,
                displayName: "Alex Rivera", matchPercent: 66, band: "low",
                anchored: false, turnCount: 43)
            try expect(guess.isProvisional, "66% low, un-anchored, is a guess")

            let settled = MCPClient.TranscriptSpeaker(
                key: "Speaker 1", voiceCluster: 1205, personID: 5,
                displayName: "Alex Rivera", matchPercent: 100, band: "high",
                anchored: true, turnCount: 43)
            try expect(!settled.isProvisional, "anchored is settled")

            // Anchored is what settles it, not the percentage: a name
            // somebody committed to stops being a question even if the
            // voiceprint later disagrees.
            let committed = MCPClient.TranscriptSpeaker(
                key: "Speaker 2", voiceCluster: 1204, personID: 9,
                displayName: "Sam", matchPercent: 40, band: "low",
                anchored: true, turnCount: 12)
            try expect(!committed.isProvisional, "an anchored name is not re-asked")
        }

        h.test("a guessed name is a question, not an answer") {
            // A low or medium match lands in `speakers[]`, not
            // `unknown_speakers[]`, so the app used to see nothing to do
            // while the web asked for a confirmation. Capture 12359:
            // Speaker 1 was applied as "Alex Rivera" on a 66% low
            // match, across all 43 turns they spoke.
            let guessed = MCPClient.ProvisionalMatch(
                key: "Speaker 1", voiceCluster: 1205, personID: 5,
                displayName: "Alex Rivera", matchPercent: 66, band: "low",
                turnCount: 43)
            let item = QueueItem(
                id: UUID(), audioFile: "a.m4a", masterFiles: [], title: nil,
                occurredAt: Date(), language: nil, sizeBytes: 1, state: .ready,
                captureID: 12359, transcriptID: 848, attempts: 0,
                nextAttemptAt: .distantPast, lastError: nil, enqueuedAt: Date(),
                completedAt: Date(),
                unknownSpeakers: [
                    MCPClient.UnknownSpeaker(
                        key: "Speaker 2", voiceCluster: 1204, turnCount: 43,
                        nameSpeakerURL: nil)
                ],
                provisionalSpeakers: [guessed])

            try expectEqual(item.openSpeakerQuestions, 2, "both are questions")
            try expectEqual(
                item.speakerDescription, "1 unnamed · 1 to confirm",
                "an unconfirmed guess must be visible as work")
        }

        h.test("a voice with no cluster yet is unnamed, not absent") {
            // Capture 12359: at the moment the queue stopped polling the
            // server reported two unnamed speakers, neither carrying a
            // voice_cluster_id — clustering runs on after the transcript
            // is ready. `nameableSpeakers` filters those out, so the
            // window said "nothing to name" while the web UI said two.
            // Both statements were about different things.
            func waiting(_ count: Int) -> QueueItem {
                QueueItem(
                    id: UUID(), audioFile: "a.m4a", masterFiles: [], title: nil,
                    occurredAt: Date(), language: nil, sizeBytes: 1, state: .ready,
                    captureID: 12359, transcriptID: 848, attempts: 0,
                    nextAttemptAt: .distantPast, lastError: nil, enqueuedAt: Date(),
                    completedAt: Date(),
                    unknownSpeakers: (0..<count).map {
                        MCPClient.UnknownSpeaker(
                            key: "Speaker \($0)", voiceCluster: nil, turnCount: 43,
                            nameSpeakerURL: nil)
                    })
            }

            try expectEqual(
                waiting(2).speakerDescription, "2 unnamed, still matching",
                "two known-unnamed voices must not read as none")
            try expectEqual(
                waiting(1).speakerDescription, "1 unnamed, still matching", "one")
            try expect(
                waiting(2).nameableSpeakers.isEmpty,
                "a voice with no cluster cannot be named through the API")
        }

        h.test("an empty unknown_speakers list is not a claim that everyone is named") {
            // Measured against transcript 846: the server reported
            // `speakers: []` *and* `unknown_speakers: []` — nobody named
            // and nothing offered — while the window said "all
            // identified", which was the exact opposite of the truth. An
            // empty list means there is nothing this app can act on, and
            // that is all it may say.
            func item(unknown: [MCPClient.UnknownSpeaker], named: [String]) -> QueueItem {
                QueueItem(
                    id: UUID(), audioFile: "a.m4a", masterFiles: [], title: nil,
                    occurredAt: Date(), language: nil, sizeBytes: 1, state: .ready,
                    captureID: 1, transcriptID: 2, attempts: 0, nextAttemptAt: .distantPast,
                    lastError: nil, enqueuedAt: Date(), completedAt: Date(),
                    unknownSpeakers: unknown, notifiedAt: nil, namedSpeakers: named)
            }

            try expectEqual(
                item(unknown: [], named: []).speakerDescription, "nothing to name",
                "an empty list must not read as a roll call")
            // Named *from here* is not the same as named. The roster is
            // the server's; this list is only a record of what this Mac
            // asked for, and the two drifted on capture 12359 — local
            // "Dana Ellis" against a server saying Alex Rivera.
            try expectEqual(
                item(unknown: [], named: ["Anna"]).speakerDescription,
                "nothing to name",
                "a local record of a request must not be shown as the roster")
        }

        h.test("a queue file written by an older build still decodes") {
            // A recording is in the queue for hours or days. Adding a
            // field to QueueItem must not make yesterday's file
            // unreadable — an unreadable item is a recording that has
            // silently left the queue, which is the one thing the
            // durable queue exists to prevent. This exact JSON, missing
            // `namedSpeakers`, orphaned a real uploaded capture.
            let legacy = """
                {"attempts":0,"audioFile":"20260822-165512-manual.m4a",
                 "captureID":12353,"completedAt":"2026-08-22T14:57:26Z",
                 "enqueuedAt":"2026-08-22T14:56:01Z",
                 "id":"E13EBD45-5578-427A-8C7C-B64D478F2CFE",
                 "masterFiles":["a.caf","b.caf"],
                 "nextAttemptAt":"4001-01-01T00:00:00Z",
                 "notifiedAt":"2026-08-22T14:57:26Z",
                 "occurredAt":"2026-08-22T14:55:12Z","sizeBytes":170677,
                 "state":"ready","title":"a meeting","transcriptID":846,
                 "unknownSpeakers":[]}
                """
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let item = try decoder.decode(QueueItem.self, from: Data(legacy.utf8))
            try expectEqual(item.captureID, 12353, "capture id")
            try expectEqual(item.transcriptID, 846, "transcript id")
            try expectEqual(item.state, .ready, "state")
            try expect(item.namedSpeakers.isEmpty, "the missing field defaults to empty")
        }

        h.test("an item survives a round trip through JSON") {
            let item = QueueItem(
                id: UUID(), audioFile: "a.m4a", masterFiles: ["a.caf"], title: "Standup",
                occurredAt: Date(timeIntervalSince1970: 1_700_000_000), language: "nl",
                sizeBytes: 4096, state: .uploaded, captureID: 77, transcriptID: nil,
                attempts: 2, nextAttemptAt: Date(timeIntervalSince1970: 1_700_000_100),
                lastError: "timed out", enqueuedAt: Date(timeIntervalSince1970: 1),
                completedAt: nil)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(
                QueueItem.self, from: try encoder.encode(item))
            try expectEqual(decoded, item, "round trip")
        }

        h.asyncTest("a queued item is on disk and reloads after a restart") {
            try await withTemporaryRootAsync {
                let file = try makeFile(named: "meeting.m4a", bytes: 2048)
                let first = UploadQueue(config: .defaults) { _ in }
                let enqueued = await first.enqueue(
                    audioURL: file, masterURLs: [], title: "A meeting",
                    occurredAt: Date())
                try expect(enqueued != nil, "enqueue returned nil")

                let onDisk = try FileManager.default.contentsOfDirectory(
                    atPath: AppPaths.queue.path)
                try expectEqual(onDisk.count, 1, "queue files on disk")

                // A fresh instance is what happens after a reboot.
                let second = UploadQueue(config: .defaults) { _ in }
                await second.start()
                await second.stop()
                let items = await second.allItems()
                try expectEqual(items.count, 1, "items after reload")
                try expectEqual(items.first?.state, .pending, "state after reload")
                try expectEqual(items.first?.sizeBytes, 2048, "size after reload")
            }
        }

        h.asyncTest("a file over the server's per-file ceiling fails locally") {
            try await withTemporaryRootAsync {
                // Sparse: 300 MiB of real bytes would be a silly thing to
                // write to check an integer comparison.
                let file = try makeSparseFile(
                    named: "huge.m4a", bytes: UploadQueue.maxUploadBytes + 1)
                let queue = UploadQueue(config: .defaults) { _ in }
                let item = await queue.enqueue(
                    audioURL: file, masterURLs: [], title: nil, occurredAt: Date())
                try expectEqual(item?.state, .failed, "state")
                try expect(
                    item?.lastError?.contains("per-file limit") == true,
                    "unhelpful reason: \(item?.lastError ?? "nil")")
            }
        }

        h.asyncTest("an empty file is refused rather than queued") {
            try await withTemporaryRootAsync {
                let file = try makeFile(named: "empty.m4a", bytes: 0)
                let queue = UploadQueue(config: .defaults) { _ in }
                let item = await queue.enqueue(
                    audioURL: file, masterURLs: [], title: nil, occurredAt: Date())
                try expect(item == nil, "an empty file was queued")
            }
        }

        h.asyncTest("local copies are swept once the retention window passes") {
            try await withTemporaryRootAsync {
                var config = AtriumConfig.defaults
                config.localRetentionDays = 7
                config.uploadEnabled = true
                config.baseURL = ""  // keeps tick() from attempting a network call

                let audio = try makeFile(named: "old.m4a", bytes: 128)
                let master = try makeFile(named: "old.caf", bytes: 256)

                let queue = UploadQueue(config: config) { _ in }
                guard
                    var item = await queue.enqueue(
                        audioURL: audio, masterURLs: [master], title: nil,
                        occurredAt: Date())
                else { throw Harness.Failure(message: "enqueue failed", file: #file, line: #line) }

                // Backdate a completed upload past the window, the way it
                // would look eight days after the transcript arrived.
                item.state = .ready
                item.completedAt = Date().addingTimeInterval(-8 * 86_400)
                try writeItem(item)

                let reloaded = UploadQueue(config: config) { _ in }
                await reloaded.start()
                await reloaded.tick()
                await reloaded.stop()

                try expect(
                    !FileManager.default.fileExists(atPath: audio.path),
                    "the uploaded file was not swept")
                try expect(
                    !FileManager.default.fileExists(atPath: master.path),
                    "the local master was not swept")
                try expectEqual(await reloaded.allItems().count, 0, "items left")
            }
        }

        h.asyncTest("the masters go early and the upload stays") {
            // The default split: 690 MB an hour of 48 kHz masters is not
            // worth keeping once the transcript exists, and 17 MB an
            // hour of AAC is — it is still playable, still re-uploadable,
            // and after Atrium PA sweeps its own vault at ~90 days it is
            // the only copy of the meeting anywhere.
            try await withTemporaryRootAsync {
                var config = AtriumConfig.defaults
                config.masterRetentionDays = 0
                config.localRetentionDays = -1  // keep the m4a for ever
                config.uploadEnabled = true
                config.baseURL = ""

                let audio = try makeFile(named: "kept.m4a", bytes: 128)
                let micMaster = try makeFile(named: "kept.mic.caf", bytes: 4096)
                let farMaster = try makeFile(named: "kept.far.caf", bytes: 4096)

                let queue = UploadQueue(config: config) { _ in }
                guard
                    var item = await queue.enqueue(
                        audioURL: audio, masterURLs: [micMaster, farMaster],
                        title: nil, occurredAt: Date())
                else {
                    throw Harness.Failure(
                        message: "enqueue failed", file: #file, line: #line)
                }
                item.state = .ready
                item.completedAt = Date().addingTimeInterval(-60)
                try writeItem(item)

                let reloaded = UploadQueue(config: config) { _ in }
                await reloaded.start()
                await reloaded.tick()
                await reloaded.stop()

                try expect(
                    !FileManager.default.fileExists(atPath: micMaster.path)
                        && !FileManager.default.fileExists(atPath: farMaster.path),
                    "the masters survived their window")
                try expect(
                    FileManager.default.fileExists(atPath: audio.path),
                    "the uploaded copy was swept although retention says keep it")

                // The item stays, so the recording is still in the
                // window — and it no longer claims files it does not
                // have, which a later sweep and the UI both read.
                let remaining = await reloaded.allItems()
                try expectEqual(remaining.count, 1, "items left")
                try expect(
                    remaining.first?.masterFiles.isEmpty == true,
                    "the item still lists masters that are gone")
            }
        }

        h.asyncTest("negative retention means never, for both tiers") {
            try await withTemporaryRootAsync {
                var config = AtriumConfig.defaults
                config.masterRetentionDays = -1
                config.localRetentionDays = -1
                config.baseURL = ""

                let audio = try makeFile(named: "forever.m4a", bytes: 128)
                let master = try makeFile(named: "forever.caf", bytes: 256)

                let queue = UploadQueue(config: config) { _ in }
                guard
                    var item = await queue.enqueue(
                        audioURL: audio, masterURLs: [master], title: nil,
                        occurredAt: Date())
                else {
                    throw Harness.Failure(
                        message: "enqueue failed", file: #file, line: #line)
                }
                // A year old and still kept.
                item.state = .ready
                item.completedAt = Date().addingTimeInterval(-365 * 86_400)
                try writeItem(item)

                let reloaded = UploadQueue(config: config) { _ in }
                await reloaded.start()
                await reloaded.tick()
                await reloaded.stop()

                try expect(
                    FileManager.default.fileExists(atPath: audio.path)
                        && FileManager.default.fileExists(atPath: master.path),
                    "a negative window deleted something")
            }
        }

        h.asyncTest("deleting a recording takes its files and its queue entry") {
            try await withTemporaryRootAsync {
                var config = AtriumConfig.defaults
                config.baseURL = ""

                let audio = try makeFile(named: "gone.m4a", bytes: 128)
                let master = try makeFile(named: "gone.mic.caf", bytes: 256)

                let queue = UploadQueue(config: config) { _ in }
                guard
                    let item = await queue.enqueue(
                        audioURL: audio, masterURLs: [master], title: nil,
                        occurredAt: Date())
                else {
                    throw Harness.Failure(
                        message: "enqueue failed", file: #file, line: #line)
                }

                let removed = await queue.deleteItem(id: item.id)
                try expectEqual(removed.count, 2, "files removed")
                try expect(
                    !FileManager.default.fileExists(atPath: audio.path)
                        && !FileManager.default.fileExists(atPath: master.path),
                    "the audio survived a delete")
                try expectEqual(await queue.allItems().count, 0, "items left")

                // Deleting the same thing twice is not an error — a
                // second press, or a file already swept by retention,
                // must not throw.
                try expect(
                    await queue.deleteItem(id: item.id).isEmpty,
                    "a second delete reported work it did not do")
            }
        }

        h.asyncTest("a failed upload keeps its audio — it is the only copy") {
            try await withTemporaryRootAsync {
                var config = AtriumConfig.defaults
                config.localRetentionDays = 0

                let audio = try makeFile(named: "stuck.m4a", bytes: 128)
                let queue = UploadQueue(config: config) { _ in }
                guard
                    var item = await queue.enqueue(
                        audioURL: audio, masterURLs: [], title: nil, occurredAt: Date())
                else { throw Harness.Failure(message: "enqueue failed", file: #file, line: #line) }
                item.state = .failed
                item.completedAt = Date().addingTimeInterval(-90 * 86_400)
                try writeItem(item)

                let reloaded = UploadQueue(config: config) { _ in }
                await reloaded.start()
                await reloaded.tick()
                await reloaded.stop()

                try expect(
                    FileManager.default.fileExists(atPath: audio.path),
                    "a failed upload's audio was deleted")
            }
        }

        h.asyncTest("a pipeline failure keeps the reason it failed") {
            try await withTemporaryRootAsync {
                // Observed for real: the server answered
                // status=failed, detail="the recording produced no
                // speech", and the item ended up `failed` with
                // lastError nil — because poll() returns normally when
                // it records a terminal failure, and the success
                // bookkeeping then cleared it.
                var config = AtriumConfig.defaults
                config.baseURL = "https://example.invalid"
                config.clientID = "test-client"
                StubProtocol.handler = { request in
                    if request.url?.path == "/oauth/token" {
                        return (200, #"{"access_token":"tok","expires_in":3600}"#)
                    }
                    return (
                        200,
                        """
                        {"jsonrpc":"2.0","id":1,"result":{"isError":false,
                         "structuredContent":{"capture_id":7,"status":"failed",
                          "detail":"the recording produced no speech"}}}
                        """
                    )
                }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [StubProtocol.self]
                let stubbed = MCPClient(
                    config: config, secret: "test-secret",
                    session: URLSession(configuration: configuration))

                let file = try makeFile(named: "dud.m4a", bytes: 512)
                let queue = UploadQueue(config: config) { _ in }
                guard
                    var item = await queue.enqueue(
                        audioURL: file, title: nil, occurredAt: Date())
                else { throw Harness.Failure(message: "enqueue", file: #file, line: #line) }
                item.state = .uploaded
                item.captureID = 7
                try writeItem(item)

                let reloaded = UploadQueue(config: config) { _ in }
                await reloaded.start()
                await reloaded.setClientForTesting(stubbed)
                await reloaded.tick()
                await reloaded.stop()

                let stored = await reloaded.allItems().first
                try expectEqual(stored?.state, .failed, "state")
                try expect(
                    stored?.lastError?.contains("no speech") == true,
                    "the reason was thrown away: \(stored?.lastError ?? "nil")")
            }
        }

        h.asyncTest("without credentials nothing is attempted and nothing fails") {
            try await withTemporaryRootAsync {
                let file = try makeFile(named: "waiting.m4a", bytes: 512)
                var seen: UploadQueue.Summary?
                let queue = UploadQueue(config: .defaults) { seen = $0 }
                _ = await queue.enqueue(
                    audioURL: file, masterURLs: [], title: nil, occurredAt: Date())
                await queue.tick()
                let items = await queue.allItems()
                try expectEqual(items.first?.state, .pending, "state")
                try expectEqual(items.first?.attempts, 0, "attempts should not be burnt")
                try expect(seen?.lastError?.contains("not configured") == true,
                    "the menu was not told why: \(seen?.lastError ?? "nil")")
            }
        }
    }

    // MARK: - JSON-RPC

    private static func jsonRPC(_ h: Harness) {
        h.group("MCPClient — the wire contract with Atrium PA")

        func client(_ handler: @escaping StubProtocol.Handler) -> MCPClient {
            var config = AtriumConfig.defaults
            config.baseURL = "https://example.invalid"
            config.clientID = "test-client"
            StubProtocol.handler = handler
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubProtocol.self]
            return MCPClient(
                config: config, secret: "test-secret",
                session: URLSession(configuration: configuration))
        }

        h.test("an invalid_scope callback is recoverable, not a dead end") {
            // atrium-pa pins `allowed_scopes` at registration (RFC 7591
            // §2) and forbids widening on refresh (RFC 6749 §6), so a
            // client registered for `pa.ingest pa.label` can never be
            // granted `pa.read` — signing in again with it fails exactly
            // the same way. The flow has to notice and register anew,
            // which it can only do because the failure comes back as a
            // redirect to the loopback rather than as an error page.
            let rejection = OAuthLogin.LoginError.scopeRejected(
                "unknown or disallowed scope(s): ['pa.read']")
            try expect(
                rejection.description.contains("pa.read"),
                "the scope the server refused must survive into the message")

            // A plain denial must stay a denial: retrying a registration
            // when the user pressed Cancel would reopen the browser on
            // somebody who has just said no.
            let denial = OAuthLogin.LoginError.denied("access_denied")
            if case .scopeRejected = denial {
                throw Harness.Failure(
                    message: "a denial must not read as a scope problem",
                    file: #file, line: #line)
            }
        }

        h.test("PKCE challenge is the S256 of the verifier, url-safe and unpadded") {
            // RFC 7636 §4.2. Atrium PA rejects anything but S256, and a
            // challenge computed even slightly wrong fails at the very
            // end of the flow — after the user has already signed in.
            let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
            let expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
            try expectEqual(OAuthLogin.challenge(for: verifier), expected, "S256")
            try expect(
                !expected.contains("=") && !expected.contains("+")
                    && !expected.contains("/"),
                "the challenge must be url-safe base64 without padding")
        }

        h.test("verifiers are url-safe and long enough to be worth having") {
            var seen = Set<String>()
            for _ in 0..<50 {
                let verifier = OAuthLogin.randomURLSafe(64)
                try expect(verifier.count >= 43, "too short: \(verifier.count)")
                try expect(
                    verifier.allSatisfy {
                        $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
                    },
                    "not url-safe: \(verifier)")
                seen.insert(verifier)
            }
            try expectEqual(seen.count, 50, "verifiers repeated")
        }

        h.test("the callback's query is read out of the raw request line") {
            let request =
                "GET /callback?code=abc123&state=xyz HTTP/1.1\r\n"
                + "Host: 127.0.0.1:52341\r\n\r\n"
            let query = CallbackListener.parseQuery(fromRequestLine: request)
            try expectEqual(query["code"], "abc123", "code")
            try expectEqual(query["state"], "xyz", "state")
        }

        h.test("a denied consent comes back as an error, not a code") {
            let request = "GET /callback?error=access_denied&state=xyz HTTP/1.1\r\n\r\n"
            let query = CallbackListener.parseQuery(fromRequestLine: request)
            try expectEqual(query["error"], "access_denied", "error")
            try expect(query["code"] == nil, "a denial must not look like a grant")
        }

        h.test("a loopback listener binds and reports its port") {
            let listener = try CallbackListener()
            defer { listener.stop() }
            h.note("bound 127.0.0.1:\(listener.port)")
            try expect(listener.port > 0, "no port assigned")
        }

        h.asyncTest("the browser's redirect reaches the app without leaving the machine") {
            // The whole question about laptops, settled by doing it. The
            // server never connects here: it 302s the *browser*, which is
            // already on this machine, and the browser then fetches a
            // loopback URL. This test is that fetch — a plain HTTP client
            // talking to 127.0.0.1, with nothing routable involved.
            let listener = try CallbackListener()
            defer { listener.stop() }

            let url = URL(
                string: "http://127.0.0.1:\(listener.port)/callback"
                    + "?code=the-code&state=the-state")!
            Task.detached {
                // A moment for the accept loop to be waiting.
                try? await Task.sleep(nanoseconds: 200_000_000)
                _ = try? await URLSession.shared.data(from: url)
            }

            let query = try await listener.waitForCallback(timeout: 10)
            try expectEqual(query["code"], "the-code", "code")
            try expectEqual(query["state"], "the-state", "state")
        }

        h.asyncTest("a login nobody finishes gives the port back") {
            let listener = try CallbackListener()
            defer { listener.stop() }
            do {
                _ = try await listener.waitForCallback(timeout: 0.3)
                throw Harness.Failure(
                    message: "an abandoned login reported success",
                    file: #file, line: #line)
            } catch is CallbackListener.ListenerError {
                // expected: it times out rather than holding the socket
            }
        }

        h.test("form encoding escapes what a secret might contain") {
            let encoded = OAuthLogin.formEncoded([
                "client_secret": "a+b/c=d&e f",
                "grant_type": "refresh_token",
            ])
            try expect(
                !encoded.contains("a+b/c=d&e f"),
                "an unescaped secret would corrupt the form: \(encoded)")
            try expect(encoded.contains("grant_type=refresh_token"), "plain field")
        }

        h.test("login asks for the scopes the app actually uses, and no more") {
            let asked = Set(OAuthLogin.scope.split(separator: " ").map(String.init))
            try expect(asked.contains("pa.ingest"), "cannot upload without pa.ingest")
            try expect(asked.contains("pa.label"), "cannot name a voice without pa.label")
            // pa.read arrived with the "search for an existing person"
            // box in the naming window: every person-lookup tool on the
            // server requires it, and without one the name field can
            // only create duplicates of people Atrium PA already knows.
            // It is genuinely wide — mail, calendar, transcripts — and
            // is here because a feature needs it, not by drift.
            try expect(asked.contains("pa.read"), "person search needs pa.read")
            // Separate from pa.ingest on the server's insistence and
            // ours: folding deletion into the upload scope would have
            // re-granted it to every token already issued, against a
            // consent screen that cannot be shown again.
            try expect(
                asked.contains("pa.ingest:delete"),
                "deleting a capture needs pa.ingest:delete")
            try expect(!asked.contains("pa.admin"), "pa.admin has no use here")

            // The registration request must name its scopes. The server
            // does not advertise pa.ingest:delete in its discovery
            // document, precisely so a client that registers without
            // saying what it wants never receives it — so asking
            // explicitly is load-bearing, not incidental.
            try expect(
                !OAuthLogin.scope.isEmpty,
                "an empty scope at registration inherits the discoverable set")
        }

        h.asyncTest("unknown speakers are kept, not discarded") {
            let mcp = client { request in
                if request.url?.path == "/oauth/token" {
                    return (200, #"{"access_token":"tok","expires_in":3600}"#)
                }
                return (
                    200,
                    """
                    {"jsonrpc":"2.0","id":1,"result":{"isError":false,
                     "structuredContent":{"capture_id":991,"status":"ready",
                     "transcript_id":55,
                     "unknown_speakers":[
                       {"key":"a","voice_cluster_id":88,"turn_count":47,
                        "name_speaker_url":"https://example.invalid/n/88"},
                       {"key":"b","voice_cluster_id":null,"turn_count":3}]}}}
                    """
                )
            }
            let status = try await mcp.uploadStatus(captureID: 991)
            try expectEqual(status.unknownSpeakers.count, 2, "kept")
            try expectEqual(status.unknownSpeakers[0].voiceCluster, 88, "cluster")
            try expectEqual(status.unknownSpeakers[0].turnCount, 47, "turns")
            // The null-cluster entry cannot be named through the API at
            // all — offering it would be a dead end.
            try expect(status.unknownSpeakers[0].isNameable, "88 should be nameable")
            try expect(!status.unknownSpeakers[1].isNameable, "null cluster is not")
        }

        h.asyncTest("identify_speaker gathers evidence and names nobody") {
            let mcp = client { request in
                if request.url?.path == "/oauth/token" {
                    return (200, #"{"access_token":"tok","expires_in":3600}"#)
                }
                return (
                    200,
                    """
                    {"jsonrpc":"2.0","id":1,"result":{"isError":false,
                     "structuredContent":{"speaker_status":"unknown",
                      "voiceprint_suggestions":[
                        {"person_id":17,"display_name":"Anna","match_pct":71,
                         "match_quality":"medium"}],
                      "candidate_attendees":[
                        {"person_id":9,"display_name":"Bob","rsvp":"declined"}],
                      "spoken_evidence":[{"quote":"thanks Anna"}],
                      "other_recordings":[{"capture_id":1},{"capture_id":2}],
                      "audio_samples":[
                        {"sample_id":5,
                         "audio_url":"https://example.invalid/api/pa/voice/snippets/t",
                         "expires_in_seconds":300,"has_persisted_snippet":true}]}}}
                    """
                )
            }
            let found = try await mcp.identifySpeaker(captureID: 412, voiceCluster: 88)
            try expectEqual(found.otherRecordings, 2, "other recordings")
            try expectEqual(found.spokenNames.first, "thanks Anna", "spoken evidence")
            try expectEqual(found.samples.first?.sampleID, 5, "sample")
            try expect(
                found.samples.first?.hasPersistedSnippet == true, "persisted snippet")

            // A declined invitee was not in the room, so the UI must not
            // offer them however plausible the name looks.
            let bob = found.candidates.first { $0.displayName == "Bob" }
            try expect(bob != nil, "the attendee should still be reported")
            try expect(!(bob?.isPlausible ?? true), "a decline must not be suggestible")
            let anna = found.candidates.first { $0.displayName == "Anna" }
            try expectEqual(anna?.matchPercent, 71, "match percent")
            try expectEqual(anna?.band, "medium", "band, never invented locally")
        }

        h.asyncTest("naming reports what it changed") {
            var sent: [String: Any] = [:]
            let mcp = client { request in
                if request.url?.path == "/oauth/token" {
                    return (200, #"{"access_token":"tok","expires_in":3600}"#)
                }
                let body =
                    (try? JSONSerialization.jsonObject(with: request.httpBodyData ?? Data()))
                    as? [String: Any]
                sent = (body?["params"] as? [String: Any])?["arguments"] as? [String: Any]
                    ?? [:]
                return (
                    200,
                    """
                    {"jsonrpc":"2.0","id":1,"result":{"isError":false,
                     "structuredContent":{"turns_updated":47,
                      "recordings_affected":3}}}
                    """
                )
            }
            let result = try await mcp.nameSpeaker(
                captureID: 412, voiceCluster: 88, personID: 17, newPerson: nil,
                evidence: "71% medium match")
            try expectEqual(result.turnsUpdated, 47, "turns")
            try expectEqual(result.recordingsAffected, 3, "recordings")
            try expect(sent["evidence"] != nil, "evidence is required and is stored")
            try expect(
                sent["create_person"] == nil,
                "person_id and create_person are mutually exclusive")
        }

        h.asyncTest("unname and dismiss are addressed by voice, not by capture") {
            // Both were sending capture_id, which the server rejects
            // outright: a name belongs to the *voice*, not to the
            // recording it was noticed in. Caught only by calling it for
            // real, so it is pinned here.
            var sent: [String: Any] = [:]
            var toolName = ""
            let mcp = client { request in
                if request.url?.path == "/oauth/token" {
                    return (200, #"{"access_token":"tok","expires_in":3600}"#)
                }
                let body =
                    (try? JSONSerialization.jsonObject(with: request.httpBodyData ?? Data()))
                    as? [String: Any]
                let params = body?["params"] as? [String: Any]
                toolName = params?["name"] as? String ?? ""
                sent = params?["arguments"] as? [String: Any] ?? [:]
                return (
                    200,
                    #"{"jsonrpc":"2.0","id":1,"result":{"isError":false,"structuredContent":{}}}"#
                )
            }

            try await mcp.unnameSpeaker(voiceCluster: 88)
            try expectEqual(toolName, "unname_speaker", "tool")
            try expectEqual(sent["voice_cluster_id"] as? Int, 88, "cluster")
            try expect(
                sent["capture_id"] == nil,
                "capture_id is rejected by the server: \(sent)")

            try await mcp.dismissSpeaker(voiceCluster: 88)
            try expectEqual(toolName, "dismiss_speaker", "tool")
            try expectEqual(sent["voice_cluster_id"] as? Int, 88, "cluster")
            try expect(sent["capture_id"] == nil, "capture_id is rejected")
            // `dismissed` is required — the tool is a setter with an
            // undo, not a verb.
            try expectEqual(sent["dismissed"] as? Bool, true, "dismissed flag")

            try await mcp.dismissSpeaker(voiceCluster: 88, dismissed: false)
            try expectEqual(sent["dismissed"] as? Bool, false, "undismiss")
        }

        h.asyncTest("a missing scope reads as sign-in, not as a bare 403") {
            let mcp = client { request in
                if request.url?.path == "/oauth/token" {
                    return (200, #"{"access_token":"tok","expires_in":3600}"#)
                }
                return (
                    200,
                    """
                    {"jsonrpc":"2.0","id":1,"result":{"isError":true,
                     "structuredContent":{"error":{"code":"FORBIDDEN",
                      "message":"pa.label required"}}}}
                    """
                )
            }
            do {
                _ = try await mcp.identifySpeaker(captureID: 1, voiceCluster: 1)
                throw Harness.Failure(
                    message: "FORBIDDEN was accepted", file: #file, line: #line)
            } catch let error as MCPClient.ClientError {
                guard case .loginRequired = error else {
                    throw Harness.Failure(
                        message: "a token issued before pa.label should say to sign in, "
                            + "got \(error)",
                        file: #file, line: #line)
                }
            }
        }

        h.asyncTest("the token request is a client-credentials grant for pa.ingest") {
            var seenAuth: String?
            var seenBody: String?
            let mcp = client { request in
                if request.url?.path == "/oauth/token" {
                    seenAuth = request.value(forHTTPHeaderField: "Authorization")
                    seenBody = request.httpBodyString
                    return (200, #"{"access_token":"tok","expires_in":3600}"#)
                }
                return (404, "")
            }
            let token = try await mcp.accessToken()
            try expectEqual(token, "tok", "token")
            try expectEqual(
                seenAuth,
                "Basic " + Data("test-client:test-secret".utf8).base64EncodedString(),
                "client_secret_basic")
            try expect(
                seenBody?.contains("grant_type=client_credentials") == true,
                "grant type: \(seenBody ?? "nil")")
            try expect(
                seenBody?.contains("scope=pa.ingest") == true,
                "scope was not narrowed: \(seenBody ?? "nil")")
        }

        h.asyncTest("upload_audio never asks for the inline branch") {
            var arguments: [String: Any] = [:]
            let mcp = client { request in
                if request.url?.path == "/oauth/token" {
                    return (200, #"{"access_token":"tok","expires_in":3600}"#)
                }
                let body =
                    (try? JSONSerialization.jsonObject(with: request.httpBodyData ?? Data()))
                    as? [String: Any]
                let params = body?["params"] as? [String: Any]
                arguments = params?["arguments"] as? [String: Any] ?? [:]
                return (
                    200,
                    """
                    {"jsonrpc":"2.0","id":1,"result":{"isError":false,
                     "structuredContent":{"capture_id":991,
                     "upload_url":"https://example.invalid/api/pa/uploads/audio/tkn",
                     "upload_expires_in_seconds":1800,"status":"awaiting_upload"}}}
                    """
                )
            }
            let ticket = try await mcp.requestUpload(
                filename: "a.m4a", sizeBytes: 1234, title: "Standup",
                occurredAt: Date(timeIntervalSince1970: 0), language: "nl")
            try expectEqual(ticket.captureID, 991, "capture id")
            try expectEqual(ticket.expiresIn, 1800, "ttl")
            try expect(
                arguments["data_b64"] == nil,
                "the client asked for the inline branch, which it must never do")
            try expectEqual(
                arguments["content_type"] as? String, "audio/mp4", "content type")
            try expectEqual(arguments["size_bytes"] as? Int, 1234, "size")
            try expect(arguments["occurred_at"] != nil, "occurred_at was not sent")
        }

        h.asyncTest("an in-band isError result is surfaced, not silently accepted") {
            let mcp = client { request in
                if request.url?.path == "/oauth/token" {
                    return (200, #"{"access_token":"tok","expires_in":3600}"#)
                }
                return (
                    200,
                    """
                    {"jsonrpc":"2.0","id":1,"result":{"isError":true,
                     "content":[{"type":"text","text":"quota"}],
                     "structuredContent":{"error":{"code":"VALIDATION_ERROR",
                     "message":"audio storage quota exceeded"}}}}
                    """
                )
            }
            do {
                _ = try await mcp.uploadStatus(captureID: 1)
                throw Harness.Failure(
                    message: "an isError result was accepted as success",
                    file: #file, line: #line)
            } catch let error as MCPClient.ClientError {
                try expect(
                    error.description.contains("quota exceeded"),
                    "message lost: \(error.description)")
                try expect(!error.isRetryable, "a validation error must not be retried")
            }
        }

        h.asyncTest("a 5xx is retryable and a 4xx is not") {
            try expect(
                MCPClient.ClientError.http(503, "").isRetryable, "503 should retry")
            try expect(
                MCPClient.ClientError.http(429, "").isRetryable, "429 should retry")
            try expect(
                !MCPClient.ClientError.http(400, "").isRetryable, "400 must not retry")
        }

        h.asyncTest("the PUT carries no bearer — the path token is the auth") {
            var putHeaders: [String: String]?
            let mcp = client { request in
                if request.url?.path == "/oauth/token" {
                    return (200, #"{"access_token":"tok","expires_in":3600}"#)
                }
                putHeaders = request.allHTTPHeaderFields
                return (200, "{}")
            }
            let file = try makeTemporaryFile(bytes: 32)
            defer { try? FileManager.default.removeItem(at: file) }
            try await mcp.putAudio(
                fileURL: file,
                to: URL(string: "https://example.invalid/api/pa/uploads/audio/tkn")!)
            try expect(
                putHeaders?["Authorization"] == nil,
                "the PUT sent an Authorization header")
            try expectEqual(
                putHeaders?["Content-Type"], "audio/mp4", "content type")
        }

        h.asyncTest("get_upload_status reads the pipeline vocabulary") {
            let mcp = client { request in
                if request.url?.path == "/oauth/token" {
                    return (200, #"{"access_token":"tok","expires_in":3600}"#)
                }
                return (
                    200,
                    """
                    {"jsonrpc":"2.0","id":1,"result":{"isError":false,
                     "structuredContent":{"capture_id":991,"status":"ready",
                     "transcript_id":55,"detail":"1 voice is still unnamed"}}}
                    """
                )
            }
            let status = try await mcp.uploadStatus(captureID: 991)
            try expectEqual(status.status, "ready", "status")
            try expectEqual(status.transcriptID, 55, "transcript id")
            try expect(status.isReady, "isReady")
            try expect(status.isTerminal, "isTerminal")
            try expect(!status.needsBytes, "needsBytes")
        }

        h.asyncTest("skipped voices are reachable again, with their cluster ids") {
            var sentArguments: [String: Any] = [:]
            let mcp = client { request in
                if request.url?.path == "/oauth/token" {
                    return (200, #"{"access_token":"tok","expires_in":3600}"#)
                }
                if let body = request.httpBodyData,
                    let json = try? JSONSerialization.jsonObject(with: body)
                        as? [String: Any],
                    let params = json["params"] as? [String: Any],
                    let arguments = params["arguments"] as? [String: Any]
                {
                    sentArguments = arguments
                }
                return (
                    200,
                    """
                    {"jsonrpc":"2.0","id":1,"result":{"isError":false,
                     "structuredContent":{"unknown_speakers":[
                       {"key":"S1","voice_cluster_id":1202,"turn_count":4,
                        "dismissed":true},
                       {"key":"S2","voice_cluster_id":1203,"turn_count":9}]}}}
                    """
                )
            }

            let skipped = try await mcp.dismissedSpeakers(transcriptID: 846)
            // Only the dismissed one. The other entry is a live question
            // and restoring it would be meaningless.
            try expectEqual(skipped.count, 1, "dismissed voices")
            try expectEqual(skipped.first?.voiceCluster, 1202, "cluster id")
            try expect(skipped.first?.isDismissed == true, "dismissed flag")

            // Without this flag the server filters dismissed voices out,
            // which is what makes their cluster ids unreachable — and a
            // restore needs the id.
            try expectEqual(
                sentArguments["include_dismissed"] as? Bool, true, "include_dismissed")
            try expectEqual(
                sentArguments["transcript_id"] as? Int, 846, "transcript id")
        }

        h.asyncTest("restoring a voice sets dismissed to false, addressed by cluster") {
            var sentArguments: [String: Any] = [:]
            var toolName = ""
            let mcp = client { request in
                if request.url?.path == "/oauth/token" {
                    return (200, #"{"access_token":"tok","expires_in":3600}"#)
                }
                if let body = request.httpBodyData,
                    let json = try? JSONSerialization.jsonObject(with: body)
                        as? [String: Any],
                    let params = json["params"] as? [String: Any]
                {
                    toolName = params["name"] as? String ?? ""
                    sentArguments = params["arguments"] as? [String: Any] ?? [:]
                }
                return (
                    200,
                    #"{"jsonrpc":"2.0","id":1,"result":{"isError":false,"structuredContent":{"turn_count":4}}}"#
                )
            }

            try await mcp.restoreSpeaker(voiceCluster: 1202)
            try expectEqual(toolName, "dismiss_speaker", "tool")
            try expectEqual(sentArguments["voice_cluster_id"] as? Int, 1202, "cluster")
            // The flag is required and has no default server-side, so
            // sending it wrong means dismissing what we meant to restore.
            try expectEqual(sentArguments["dismissed"] as? Bool, false, "direction")
            try expect(sentArguments["capture_id"] == nil, "a cluster is not a capture")
        }

        h.asyncTest("delete_capture is a setter, and reports what it found") {
            var sentArguments: [String: Any] = [:]
            var toolName = ""
            let mcp = client { request in
                if request.url?.path == "/oauth/token" {
                    return (200, #"{"access_token":"tok","expires_in":3600}"#)
                }
                if let body = request.httpBodyData,
                    let json = try? JSONSerialization.jsonObject(with: body)
                        as? [String: Any],
                    let params = json["params"] as? [String: Any]
                {
                    toolName = params["name"] as? String ?? ""
                    sentArguments = params["arguments"] as? [String: Any] ?? [:]
                }
                return (
                    200,
                    """
                    {"jsonrpc":"2.0","id":1,"result":{"isError":false,
                     "structuredContent":{"capture_id":12353,"status":"deleted",
                      "deleted":true,"deleted_at":"2026-08-23T13:00:00Z",
                      "already_deleted":false,"changed":true,
                      "transcript_id":846}}}
                    """
                )
            }

            let result = try await mcp.deleteCapture(
                captureID: 12353, reason: "a test")
            try expectEqual(toolName, "delete_capture", "tool")
            try expectEqual(result.captureID, 12353, "capture id")
            try expectEqual(result.status, "deleted", "status")
            try expect(result.changed, "changed")
            try expect(!result.alreadyDeleted, "alreadyDeleted")

            // Required and explicit, like `dismiss_speaker(dismissed:)`.
            // Sending it wrong deletes what was meant to be restored.
            try expectEqual(sentArguments["deleted"] as? Bool, true, "direction")
            try expectEqual(sentArguments["capture_id"] as? Int, 12353, "capture id")
            try expectEqual(sentArguments["reason"] as? String, "a test", "reason")
        }

        h.asyncTest("a retried delete is a legible no-op, not a failure") {
            // The server answers a second delete with 200 and
            // `already_deleted: true`, `changed: false`. A client that
            // treated that as an error would report a failure for work
            // that had succeeded — which is the whole point of the
            // idempotent contract.
            let mcp = client { request in
                if request.url?.path == "/oauth/token" {
                    return (200, #"{"access_token":"tok","expires_in":3600}"#)
                }
                return (
                    200,
                    """
                    {"jsonrpc":"2.0","id":1,"result":{"isError":false,
                     "structuredContent":{"capture_id":12353,"status":"deleted",
                      "deleted":true,"already_deleted":true,"changed":false}}}
                    """
                )
            }
            let result = try await mcp.deleteCapture(captureID: 12353)
            try expect(result.alreadyDeleted, "alreadyDeleted")
            try expect(!result.changed, "changed")
        }

        h.asyncTest("restoring sends deleted false") {
            var sentArguments: [String: Any] = [:]
            let mcp = client { request in
                if request.url?.path == "/oauth/token" {
                    return (200, #"{"access_token":"tok","expires_in":3600}"#)
                }
                if let body = request.httpBodyData,
                    let json = try? JSONSerialization.jsonObject(with: body)
                        as? [String: Any],
                    let params = json["params"] as? [String: Any]
                {
                    sentArguments = params["arguments"] as? [String: Any] ?? [:]
                }
                return (
                    200,
                    #"{"jsonrpc":"2.0","id":1,"result":{"isError":false,"structuredContent":{"capture_id":1,"status":"ready","deleted":false,"already_deleted":false,"changed":true}}}"#
                )
            }
            let result = try await mcp.deleteCapture(captureID: 1, deleted: false)
            try expectEqual(sentArguments["deleted"] as? Bool, false, "direction")
            try expect(!result.deleted, "deleted")
            // Restoring is the only clean way back: re-uploading the same
            // bytes during the grace window collides with a dedup key
            // that is deliberately retained, and fails opaquely.
            try expectEqual(result.status, "ready", "status after restore")
        }

        h.asyncTest("a missing scope reads as sign in again, on every path") {
            // FORBIDDEN arrives three ways: an HTTP status with an error
            // envelope, a JSON-RPC error member, and a tool result with
            // isError. It was recognised on one of them, so the other two
            // surfaced the raw "requires scope 'pa.read'" — which reads
            // like a bug in the app rather than an instruction to the
            // person who can fix it.
            let bodies: [(String, Int, String)] = [
                (
                    "HTTP status", 403,
                    #"{"error":{"code":"FORBIDDEN","message":"requires scope 'pa.read'"}}"#
                ),
                (
                    "JSON-RPC error member", 200,
                    #"{"jsonrpc":"2.0","id":1,"error":{"code":"FORBIDDEN","message":"requires scope 'pa.read'"}}"#
                ),
                (
                    "tool result", 200,
                    #"{"jsonrpc":"2.0","id":1,"result":{"isError":true,"structuredContent":{"error":{"code":"FORBIDDEN","message":"requires scope 'pa.read'"}}}}"#
                ),
            ]
            for (shape, status, body) in bodies {
                let mcp = client { request in
                    if request.url?.path == "/oauth/token" {
                        return (200, #"{"access_token":"tok","expires_in":3600}"#)
                    }
                    return (status, body)
                }
                do {
                    _ = try await mcp.dismissedSpeakers(transcriptID: 1)
                    throw Harness.Failure(
                        message: "\(shape): a forbidden call succeeded",
                        file: #file, line: #line)
                } catch let error as MCPClient.ClientError {
                    guard case .loginRequired(let why) = error else {
                        throw Harness.Failure(
                            message: "\(shape): got \(error), wanted loginRequired",
                            file: #file, line: #line)
                    }
                    try expect(
                        why.contains("pa.read"),
                        "\(shape): the server names the scope; pass it through")
                }
            }
        }

        h.asyncTest("searching for a person asks only for people, and labels them") {
            var sentArguments: [String: Any] = [:]
            let mcp = client { request in
                if request.url?.path == "/oauth/token" {
                    return (200, #"{"access_token":"tok","expires_in":3600}"#)
                }
                if let body = request.httpBodyData,
                    let json = try? JSONSerialization.jsonObject(with: body)
                        as? [String: Any],
                    let params = json["params"] as? [String: Any],
                    let arguments = params["arguments"] as? [String: Any]
                {
                    sentArguments = arguments
                }
                return (
                    200,
                    """
                    {"jsonrpc":"2.0","id":1,"result":{"isError":false,
                     "structuredContent":{"results":[
                       {"id":42,"type":"person","display_name":"Anna Petrova",
                        "primary_email":"anna@example.invalid","uri":"person://42"},
                       {"id":43,"type":"person","display_name":"Anna Lee",
                        "primary_email":null}]}}}
                    """
                )
            }

            // The envelope key is `results`. This fixture said `hits`
            // once, which is the shape the parser expected and not the
            // shape the server sends — so the test passed while the
            // feature returned an empty dropdown for every query.
            let people = try await mcp.searchPeople(matching: "  Anna  ", limit: 5)
            try expectEqual(people.count, 2, "results decoded")
            try expectEqual(people.first?.id, 42, "person id")
            // The label is what the dropdown shows, and the email is the
            // only thing distinguishing two people called Anna.
            try expectEqual(
                people.first?.label, "Anna Petrova — anna@example.invalid", "label")
            try expectEqual(people.last?.label, "Anna Lee", "label without an email")

            try expectEqual(sentArguments["query"] as? String, "Anna", "query is trimmed")
            try expectEqual(sentArguments["limit"] as? Int, 5, "limit is passed through")
            try expectEqual(
                sentArguments["types"] as? [String], ["person"],
                "a person search must not drag in emails and transcripts")
        }

        h.asyncTest("a one-character search never reaches the server") {
            // The floor is enforced in the client as well as in the
            // window: one letter matches most of the address book, which
            // is not a dropdown anybody can use — and it is a request
            // nobody meant to send.
            var calls = 0
            let mcp = client { _ in
                calls += 1
                return (200, #"{"access_token":"tok","expires_in":3600}"#)
            }
            try await expectEqual(mcp.searchPeople(matching: "a").count, 0, "hits")
            try expectEqual(calls, 0, "requests made")
        }

    }

    // MARK: - Encoding

    private static func encoding(_ h: Harness) {
        h.group("TranscriptDocument — the export, made readable")

        /// The real shape, taken from transcript 848's export.
        let exportJSON = """
            {"schema_version":1,
             "transcript":{"id":848,"title":"WhatsApp call",
               "starts_at":"2026-08-23T14:51:45Z","duration_seconds":832,
               "language":"nl"},
             "speakers":[
               {"key":"S1","label":"Speaker 2","voice_cluster_id":1204,
                "person_id":2572,"display_name":"Sam Okafor","match_pct":100,
                "match_quality":"high","anchored":true,"turn_count":43},
               {"key":"S2","label":"Speaker 1","voice_cluster_id":1205,
                "person_id":5,"display_name":"Alex Rivera","match_pct":66,
                "match_quality":"low","anchored":false,"turn_count":43},
               {"key":"S3","label":"Speaker 3","voice_cluster_id":null,
                "person_id":null,"display_name":null,"turn_count":2}],
             "turns":[
               {"sequence":0,"speaker":"S1","start_ms":1900,"end_ms":16600,
                "text":"Can you hear me?","text_raw":"can you hear me"},
               {"sequence":1,"speaker":"S1","start_ms":16600,"end_ms":18000,
                "text":"Yes?","text_raw":"yes"},
               {"sequence":2,"speaker":"S2","start_ms":18000,"end_ms":22000,
                "text":"Yes, I can hear you.","text_raw":"yes i can hear you"},
               {"sequence":3,"speaker":"S3","start_ms":3700000,"end_ms":3701000,
                "text":"Hello.","text_raw":"hello"}],
             "summary":null}
            """

        h.test("a transcript renders with names, timestamps and hedges") {
            let document = try TranscriptDocument(data: Data(exportJSON.utf8))
            try expectEqual(document.turns.count, 4, "turns")
            try expectEqual(document.speakers.count, 3, "speakers")

            let text = document.markdown()
            try expect(text.hasPrefix("# WhatsApp call"), "title")
            try expect(text.contains("**Sam Okafor** · 0:01"), "settled name")

            // The hedge is the point. atrium-pa is explicit that a low
            // or medium attribution may be wrong, and a transcript that
            // has left this app gets quoted and forwarded long after the
            // percentage is out of sight.
            try expect(
                text.contains("**Alex Rivera — unconfirmed, 66% low**"),
                "an unconfirmed name must say so where it is used: \(text)")
            try expect(
                text.contains("Names marked *unconfirmed*"),
                "and once in the header, for whoever reads only that")

            // A voice nobody identified keeps its label in the body —
            // "Speaker 3" is self-evidently not a person's name, and
            // repeating "not identified" on every heading is noise. The
            // roster says it once.
            try expect(text.contains("**Speaker 3** · "), "unidentified in the body")
            try expect(
                text.contains("- Speaker 3 — not identified"),
                "the roster must say which voices nobody named")

            // One heading per change of speaker, not per turn.
            try expectEqual(
                text.components(separatedBy: "**Sam Okafor**").count - 1, 1,
                "consecutive turns from one speaker repeated the heading")

            // Past an hour the stamp grows a field rather than wrapping.
            try expect(text.contains("· 1:01:40"), "hour-long stamp: \(text)")
        }

        h.test("plain text carries the same facts without the punctuation") {
            let document = try TranscriptDocument(data: Data(exportJSON.utf8))
            let text = document.rendered(as: .plainText)

            try expect(text.hasPrefix("WhatsApp call\n===="), "title")
            try expect(!text.contains("**"), "markdown emphasis leaked into text")
            try expect(!text.contains("# "), "a markdown heading leaked into text")
            try expect(text.contains("[0:01] Sam Okafor"), "attributed turn")

            // The hedge has to survive the format change — it is the
            // part that stops a guess being read as fact.
            try expect(
                text.contains("Alex Rivera — unconfirmed, 66% low"),
                "the hedge was lost in plain text: \(text)")
            try expect(text.contains("UNCONFIRMED"), "and in the roster")
        }

        h.test("the format decides the extension") {
            let when = Date(timeIntervalSince1970: 1_787_000_000)
            try expect(
                TranscriptDocument.filename(title: "a", occurredAt: when, format: .markdown)
                    .hasSuffix(".md"), "markdown")
            try expect(
                TranscriptDocument.filename(title: "a", occurredAt: when, format: .plainText)
                    .hasSuffix(".txt"), "plain text")
            try expectEqual(TranscriptFormat.plainText.rawValue, "text", "stored value")
        }

        h.test("a filename sorts by date and cannot escape the folder") {
            let when = ISO8601DateFormatter().date(from: "2026-08-23T14:51:45Z")!
            let name = TranscriptDocument.filename(title: "WhatsApp call", occurredAt: when)
            try expect(name.hasSuffix(".md"), "extension")
            try expect(name.contains("WhatsApp call"), "title kept")

            // A meeting title comes from a calendar somebody else
            // controls. A slash in it is a directory nobody asked for.
            let hostile = TranscriptDocument.filename(
                title: "../../etc/passwd", occurredAt: when)
            try expect(!hostile.contains("/"), "a path separator survived: \(hostile)")
            try expect(!hostile.contains(".."), "a traversal survived: \(hostile)")
        }

        h.test("a document with no turns is an error, not an empty file") {
            let empty = #"{"transcript":{"title":"x"},"speakers":[],"turns":[]}"#
            do {
                _ = try TranscriptDocument(data: Data(empty.utf8))
                throw Harness.Failure(
                    message: "an empty transcript parsed", file: #file, line: #line)
            } catch is TranscriptDocument.ParseError {
                // Expected: writing a file with a header and nothing
                // under it looks like the transcript is empty rather
                // than like the export was.
            }
        }

        h.group("AudioEncoder — 48 kHz stereo master to 16 kHz mono AAC")

        h.test("a measured rate is snapped to one a device really runs at") {
            // Measured with AirPods: an aggregate reporting 48000 while
            // delivering 16571 frames a second. Hands-free runs the link
            // at 16 kHz; 16571 is that, sampled over a slightly wrong
            // interval. Feeding the raw measurement into a resampler
            // would bake a 3.6% error into every second.
            try expectEqual(AudioRates.nearestStandard(to: 16571), 16000, "AirPods")
            try expectEqual(AudioRates.nearestStandard(to: 47_950), 48000, "near 48k")
            try expectEqual(AudioRates.nearestStandard(to: 24_100), 24000, "near 24k")
            try expectEqual(AudioRates.nearestStandard(to: 44_050), 44100, "near 44.1k")

            // Half way between two is still one of them, not the average.
            let between = AudioRates.nearestStandard(to: 20_000)
            try expect(
                between == 16000 || between == 22050,
                "snapping invented a rate: \(between)")
        }

        h.test("drift is corrected; a stream that lost audio is not stretched") {
            // The distinction this number draws, from a 13-minute call
            // where the input device stopped 30 seconds early: an
            // effective rate of 46260 against a nominal 48000 is not a
            // clock, it is the size of a hole. Resampling from it slowed
            // every word by 3.6% and dropped the pitch ~62 cents — for
            // the whole recording, not for the missing part.
            let cap = AudioEncoder.maximumDriftCorrection

            // A real crystal. StreamAligner's own tests simulate ±0.05%.
            try expect(0.0005 < cap, "0.05% drift must be absorbed, not padded")
            try expect(0.002 < cap, "0.2% is still a plausible clock")

            // The failure that prompted this.
            let observed = 46260.3 / 48000 - 1
            try expect(
                abs(observed) > cap,
                "3.6% must not be treated as drift, got a cap of \(cap)")

            // And the cap sits far from both, rather than just above one.
            try expect(
                cap > 0.002 && cap < 0.01,
                "the cap should separate clocks from losses with room either "
                    + "side, got \(cap)")
        }


        h.test("a synthesised master encodes to a mono 16 kHz m4a") {
            try withTemporaryRoot {
                let master = try SyntheticAudio.writeStereoCAF(
                    to: AppPaths.recordings.appending(path: "synthetic.caf"),
                    seconds: 3, leftHz: 440, rightHz: 660)

                let uploaded = try AudioEncoder.encodeForUpload(source: master)
                try expectEqual(uploaded.pathExtension, "m4a", "extension")

                let file = try AVAudioFile(forReading: uploaded)
                try expectEqual(
                    file.fileFormat.sampleRate, 16_000, "upload sample rate")
                try expectEqual(file.fileFormat.channelCount, 1, "upload channels")

                let seconds = Double(file.length) / file.fileFormat.sampleRate
                try expectNear(seconds, 3, tolerance: 0.25, "duration")

                let size = try FileManager.default.attributesOfItem(
                    atPath: uploaded.path)[.size] as? Int ?? 0
                h.note("3 s → \(size) bytes; a 3 h meeting extrapolates to ~\(size * 3600 / 1_048_576 / 3) MB")
                try expect(size > 0, "the encoder produced an empty file")

                // Both channels must survive the downmix: an encoder that
                // dropped the far-end would look fine on duration alone.
                try expect(
                    try SyntheticAudio.peak(of: uploaded) > 0.05,
                    "the encoded file is silent")
            }
        }

        h.test("a silent far-end no longer halves the only live channel") {
            // Measured on a real recording: mic rms 0.00532 / peak
            // 0.0358, far end digitally silent. Averaging produced an
            // upload 6 dB below the master at -51.5 dBFS RMS.
            let mix = AudioEncoder.gains(
                micRMS: 0.00532, micPeak: 0.0358, farRMS: 0, farPeak: 0)
            h.note(String(format: "mic x%.1f, far-end x%.1f", mix.mic, mix.farEnd))
            try expectEqual(mix.farEnd, 0, "a silent channel contributes nothing")
            try expect(
                mix.mic > 1,
                "the only channel with audio was attenuated (x\(mix.mic))")
            let resulting = 0.00532 * mix.mic
            try expect(
                resulting > 0.03,
                "mic ends at rms \(resulting) — still too quiet to transcribe well")
        }

        h.test("both sides of a real call arrive at comparable levels") {
            // Also measured: a far end 25 dB above the microphone.
            // Averaging preserves that gap, which loses your own half
            // of the conversation first.
            let mix = AudioEncoder.gains(
                micRMS: 0.0045, micPeak: 0.0959, farRMS: 0.085, farPeak: 0.7356)
            let micOut = 0.0045 * mix.mic
            let farOut = 0.085 * mix.farEnd
            let gapDB = abs(20 * log10(micOut / farOut))
            h.note(
                String(
                    format: "mic x%.1f -> rms %.3f, far-end x%.2f -> rms %.3f, gap %.1f dB",
                    mix.mic, micOut, mix.farEnd, farOut, gapDB))
            try expect(gapDB < 6, "the two sides still differ by \(gapDB) dB")
        }

        h.test("gains leave headroom rather than clipping the mix") {
            let mix = AudioEncoder.gains(
                micRMS: 0.2, micPeak: 0.95, farRMS: 0.2, farPeak: 0.95)
            let worst = 0.95 * mix.mic + 0.95 * mix.farEnd
            h.note(String(format: "worst-case sum %.2f", worst))
            try expect(worst < 1.6, "a loud pair would clip hard: \(worst)")
            try expect(mix.mic > 0 && mix.farEnd > 0, "a loud pair was muted")
        }

        h.test("room tone is not amplified into a roar") {
            let mix = AudioEncoder.gains(
                micRMS: 0.00001, micPeak: 0.00004, farRMS: 0.00001, farPeak: 0.00004)
            h.note(String(format: "mic x%.1f, far-end x%.1f", mix.mic, mix.farEnd))
            try expectEqual(mix.mic, 1, "silence should pass through untouched")
            try expectEqual(mix.farEnd, 1, "silence should pass through untouched")
        }

        h.test("two native-rate files combine into one upload") {
            try withTemporaryRoot {
                // The rates this machine actually reported: input at
                // 24 kHz, tap at 48 kHz.
                let mic = try SyntheticAudio.writeMonoCAF(
                    to: AppPaths.recordings.appending(path: "take.mic.caf"),
                    rate: 24_000, frames: 24_000 * 4, hz: 300)
                let far = try SyntheticAudio.writeMonoCAF(
                    to: AppPaths.recordings.appending(path: "take.far.caf"),
                    rate: 48_000, frames: 48_000 * 4, hz: 900)

                let uploaded = try AudioEncoder.encodeForUpload(micURL: mic, farURL: far)
                let file = try AVAudioFile(forReading: uploaded)
                try expectEqual(file.fileFormat.sampleRate, 16_000, "upload rate")
                try expectEqual(file.fileFormat.channelCount, 1, "upload channels")
                let seconds = Double(file.length) / file.fileFormat.sampleRate
                h.note(String(format: "4.00s in -> %.2fs out", seconds))
                try expectNear(seconds, 4, tolerance: 0.15, "duration")
                try expect(
                    try SyntheticAudio.peak(of: uploaded) > 0.1,
                    "the combined upload is silent")
            }
        }

        h.test("a mic clock running fast is absorbed, not spliced") {
            try withTemporaryRoot {
                // The case that produced the buzzing. Live, a clock
                // disagreement was corrected by discarding audio 25 times
                // a second. Offline it is one division: the file's own
                // length says what the clock really ran at, so it is
                // resampled from there.
                //
                // The skew here is a *plausible* one. It used to be 5%,
                // which made the effect vivid and is not a thing a
                // crystal does — and once `maximumDriftCorrection`
                // existed to tell drift from loss, 5% fell on the far
                // side of it and the test was asserting the old
                // behaviour.
                let skew = AudioEncoder.maximumDriftCorrection * 0.6
                let mic = try SyntheticAudio.writeMonoCAF(
                    to: AppPaths.recordings.appending(path: "skew.mic.caf"),
                    rate: 24_000, frames: Int(24_000.0 * 4 * (1 + skew)), hz: 300)
                let far = try SyntheticAudio.writeMonoCAF(
                    to: AppPaths.recordings.appending(path: "skew.far.caf"),
                    rate: 48_000, frames: 48_000 * 4, hz: 900)

                let uploaded = try AudioEncoder.encodeForUpload(micURL: mic, farURL: far)
                let file = try AVAudioFile(forReading: uploaded)
                let seconds = Double(file.length) / file.fileFormat.sampleRate
                h.note(
                    String(
                        format: "mic %+.2f%% fast, far 4.00s -> output %.3fs",
                        skew * 100, seconds))
                // Absorbed: the output tracks the far end rather than
                // running long by the mic's surplus. The tolerance is
                // tighter than the surplus itself, so an uncorrected
                // stream would fail this.
                try expectNear(
                    seconds, 4, tolerance: 4 * skew * 0.5,
                    "duration follows the far end")
                try expect(
                    try SyntheticAudio.peak(of: uploaded) > 0.1, "output is silent")
            }
        }

        h.test("a stream that stopped early does not truncate the other one") {
            try withTemporaryRoot {
                // Measured: a 38-second recording where the far-end tap
                // died at 19 s. The far end is the timebase for drift,
                // and using it as the *length* discarded 19 seconds of
                // microphone — silently, into a file that looked
                // complete.
                let mic = try SyntheticAudio.writeMonoCAF(
                    to: AppPaths.recordings.appending(path: "long.mic.caf"),
                    rate: 24_000, frames: 24_000 * 8, hz: 300)
                let far = try SyntheticAudio.writeMonoCAF(
                    to: AppPaths.recordings.appending(path: "short.far.caf"),
                    rate: 48_000, frames: 48_000 * 4, hz: 900)

                let uploaded = try AudioEncoder.encodeForUpload(micURL: mic, farURL: far)
                let file = try AVAudioFile(forReading: uploaded)
                let seconds = Double(file.length) / file.fileFormat.sampleRate
                h.note(String(format: "mic 8.00s, far 4.00s -> output %.2fs", seconds))
                try expectNear(
                    seconds, 8, tolerance: 0.1,
                    "the mix was cut to the shorter stream, losing captured audio")
            }
        }

        h.test("one stream missing still produces an upload") {
            try withTemporaryRoot {
                // A denied microphone must not cost the meeting.
                let far = try SyntheticAudio.writeMonoCAF(
                    to: AppPaths.recordings.appending(path: "solo.far.caf"),
                    rate: 48_000, frames: 48_000 * 3, hz: 700)
                let missing = AppPaths.recordings.appending(path: "solo.mic.caf")

                let uploaded = try AudioEncoder.encodeForUpload(
                    micURL: missing, farURL: far)
                let file = try AVAudioFile(forReading: uploaded)
                let seconds = Double(file.length) / file.fileFormat.sampleRate
                try expectNear(seconds, 3, tolerance: 0.15, "duration")
                try expect(
                    try SyntheticAudio.peak(of: uploaded) > 0.1,
                    "the far end alone should still be audible")
            }
        }

        h.test("a session interrupted by sleep encodes as one meeting") {
            try withTemporaryRoot {
                // Three segments: the meeting, the lid closing, the
                // meeting continuing, a quit, and the rest. Each pair is
                // what one uninterrupted stretch of recording leaves on
                // disk.
                var segments: [RecordingSidecar.Segment] = []
                for (index, seconds) in [2.0, 3.0, 1.5].enumerated() {
                    let mic = try SyntheticAudio.writeMonoCAF(
                        to: AppPaths.recordings.appending(path: "m.s\(index).mic.caf"),
                        rate: 24_000, frames: Int(24_000 * seconds), hz: 300)
                    let far = try SyntheticAudio.writeMonoCAF(
                        to: AppPaths.recordings.appending(path: "m.s\(index).far.caf"),
                        rate: 48_000, frames: Int(48_000 * seconds), hz: 900)
                    segments.append(
                        .init(
                            micFile: mic.lastPathComponent,
                            farFile: far.lastPathComponent,
                            micRate: 24_000, farRate: 48_000,
                            startedAt: Date(timeIntervalSince1970: Double(index) * 100)))
                }

                let uploaded = try AudioEncoder.encodeForUpload(
                    segments: segments,
                    to: AppPaths.recordings.appending(path: "m.m4a"))
                let file = try AVAudioFile(forReading: uploaded)
                let seconds = Double(file.length) / file.fileFormat.sampleRate
                h.note(String(format: "2.0 + 3.0 + 1.5 -> %.2fs", seconds))
                // Concatenated, not padded: nothing was recorded while
                // the machine was away, so there is no gap to represent.
                try expectNear(seconds, 6.5, tolerance: 0.2, "joined duration")
                try expect(
                    try SyntheticAudio.peak(of: uploaded) > 0.1, "joined output is silent")
            }
        }

        h.test("a sidecar survives a round trip and reports its segments") {
            try withTemporaryRoot {
                let sidecar = RecordingSidecar(
                    bundleID: "com.microsoft.teams2.helper",
                    startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    isManual: false,
                    segments: [
                        .init(
                            micFile: "a.s0.mic.caf", farFile: "a.s0.far.caf",
                            micRate: 24_000, farRate: 48_000,
                            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
                    ],
                    interrupted: true)
                sidecar.write(stem: "a")

                // What the next launch sees: an unfinished session, and
                // enough to pick it back up.
                let orphans = RecordingSidecar.orphans()
                try expectEqual(orphans.count, 1, "orphaned sessions")
                try expectEqual(orphans.first?.stem, "a", "stem")
                try expectEqual(orphans.first?.sidecar, sidecar, "round trip")
                try expect(
                    orphans.first?.sidecar.interrupted == true,
                    "an interrupted session must say so, or it is never resumed")

                RecordingSidecar.remove(stem: "a")
                try expectEqual(RecordingSidecar.orphans().count, 0, "after removal")
            }
        }

        h.test("a three-hour meeting stays inside the server's per-file limit") {
            // Arithmetic, not a three-hour test: 32 kbps mono AAC.
            let bytes = AudioEncoder.uploadBitRate / 8 * 3 * 3600
            h.note("3 h at \(AudioEncoder.uploadBitRate) bps ≈ \(bytes / 1_048_576) MB")
            try expect(
                bytes < UploadQueue.maxUploadBytes,
                "\(bytes) exceeds the \(UploadQueue.maxUploadBytes)-byte ceiling")
        }

        h.test("encoding an empty file fails loudly instead of uploading silence") {
            try withTemporaryRoot {
                let empty = try SyntheticAudio.writeStereoCAF(
                    to: AppPaths.recordings.appending(path: "empty.caf"),
                    seconds: 0, leftHz: 440, rightHz: 660)
                do {
                    _ = try AudioEncoder.encodeForUpload(source: empty)
                    throw Harness.Failure(
                        message: "an empty recording encoded without complaint",
                        file: #file, line: #line)
                } catch is AudioEncoder.EncodeError {
                    // expected
                }
            }
        }
    }
}
