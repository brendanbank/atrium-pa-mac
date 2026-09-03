import AVFoundation
import AtriumCore
import Foundation

/// Writes a meeting to disk as it happens: **one file per stream, each
/// at its own device's sample rate**.
///
/// ## Incremental, because the failure is a crash and not a clean exit
///
/// Every drain writes straight through. There is no accumulate-then-
/// flush stage, so a crash, a force-quit or a kernel panic costs the
/// last drain interval and nothing more. That is also why the container
/// is CAF: its data chunk may declare an unknown length and be read to
/// end-of-file, so a file whose header was never finalised is still
/// decodable. Measured — a process SIGKILLed after 4.0 s left a file
/// that read back at 3.925 s. A truncated WAV has a byte count in its
/// header that is simply wrong.
///
/// ## Two files, and why this is not the obvious design
///
/// The obvious design is one interleaved stereo file, mic left and
/// far-end right, and that is what this was. It does not survive contact
/// with real hardware, because the two sources do not agree on a sample
/// rate: measured on this machine, the input device runs at 24 kHz while
/// the tap's aggregate device runs at 48 kHz. One file means one rate,
/// which means converting one of them *during capture*.
///
/// That is the worst place to do it. A resampler in the drain loop loses
/// samples at every call boundary — surplus output that the caller did
/// not ask for, discarded twenty-five times a second — and its ratio
/// error is indistinguishable from clock drift to the alignment logic
/// downstream, which then "corrects" a systematic error by inserting
/// silence and discarding audio. Padded 3,584 frames and dropped 3,072
/// in a five-second recording, each one a splice. It buzzed.
///
/// So nothing is converted here. Each stream is written raw, at its own
/// rate, to its own file, and the two are reconciled exactly once —
/// offline, in `AudioEncoder`, where there is no realtime constraint and
/// the answer can be recomputed if it is wrong.
///
/// This also removes `StreamAligner` from the capture path entirely.
/// Live alignment was a control loop guessing at a ratio; offline
/// alignment is division: each file's own length tells you the rate its
/// clock really ran at.
///
/// The one thing still done live is the *start*: both streams are given
/// a moment to deliver, whatever they have buffered is discarded, and
/// both files begin together. That bounds the start offset to one drain
/// interval, 40 ms, which no transcript will ever notice.
final class AudioRecorder {

    struct Stats {
        /// Frames written to each file, at that file's own rate.
        var micFramesWritten = 0
        var farFramesWritten = 0
        var micRate: Double = 48_000
        var farRate: Double = 48_000
        /// Frames each producer had to drop — a slow consumer, i.e. a bug.
        var tapOverruns: UInt64 = 0
        var micOverruns: UInt64 = 0
        /// Frames the AVAudioEngine tap actually delivered, and how many
        /// times it fired. Zero callbacks is "the engine never ran";
        /// callbacks with no frames is "it ran and produced nothing".
        /// Those have different causes and the log has to tell them
        /// apart.
        var micFramesProduced = 0
        var micCallbacks = 0

        /// Set when the default input device changed while recording.
        /// The microphone's IOProc is bound to one device id, so a
        /// change is the likeliest reason for a stream that ends early.
        var inputDeviceChanged = false

        /// How many times the capture followed the default input to a
        /// different device during this segment.
        var inputDeviceSwitches = 0

        /// The same for the far end, which follows the default output.
        var outputDeviceSwitches = 0

        /// How much far-end audio is missing relative to the microphone.
        /// The tap dying is as real a failure as the microphone dying,
        /// and until now only one of them was reported.
        var farShortfall: TimeInterval { max(0, micDuration - farDuration) }

        /// How long the microphone had been delivering nothing when the
        /// segment closed.
        var micSilentForSeconds: TimeInterval?

        var micDuration: TimeInterval { Double(micFramesWritten) / micRate }
        var farDuration: TimeInterval { Double(farFramesWritten) / farRate }

        /// The longer of the two: what the meeting actually lasted.
        var duration: TimeInterval { max(micDuration, farDuration) }

        /// Whether the microphone stopped well before the far end did.
        ///
        /// Not drift. A device that stops leaves a hole at the end, and
        /// `AudioEncoder` refuses to stretch the audio to cover it — so
        /// this is the number that says how much of the meeting has no
        /// microphone in it.
        var micShortfall: TimeInterval { max(0, farDuration - micDuration) }

        /// How far the two clocks disagreed, as a fraction. This is now
        /// an *observation* rather than something corrected live — the
        /// encoder uses each file's own length to derive the rate its
        /// clock really ran at, so a non-zero value here costs nothing.
        var clockSkew: Double {
            guard micDuration > 0, farDuration > 0 else { return 0 }
            return micDuration / farDuration - 1
        }

        var summary: String {
            String(
                format:
                    "mic %.1fs @%.0fHz, far %.1fs @%.0fHz, skew %+.3f%%, "
                    + "overruns %llu/%llu",
                micDuration, micRate, farDuration, farRate, clockSkew * 100,
                micOverruns, tapOverruns)
                + " micFrames \(micFramesProduced) in \(micCallbacks) callbacks"
                // Said plainly rather than left to be derived from two
                // durations, because a short microphone stream is the
                // one failure here that produces a usable-looking file
                // with half the conversation missing.
                + (inputDeviceSwitches > 0
                    ? " — followed the input device \(inputDeviceSwitches) time(s)" : "")
                + (outputDeviceSwitches > 0
                    ? " — followed the output device \(outputDeviceSwitches) time(s)"
                    : "")
                + (farShortfall > 1
                    ? String(format: " — FAR END SHORT BY %.1fs", farShortfall) : "")
                + (micShortfall > 1
                    ? String(
                        format: " — MICROPHONE SHORT BY %.1fs%@%@", micShortfall,
                        inputDeviceChanged
                            ? " (the default input device changed mid-recording)" : "",
                        micSilentForSeconds.map {
                            String(format: ", silent for the last %.1fs", $0)
                        } ?? "")
                    : "")
        }
    }

    /// A finished 48 kHz stereo master, ready to be encoded and queued.
    struct Recording {
        let session: Session
        /// Filed under this stem: the sidecar and every segment.
        let stem: String
        let segments: [RecordingSidecar.Segment]
        let duration: TimeInterval
        let micPeak: Float
        let farEndPeak: Float
        let stats: Stats

        /// True when a whole stream came back as zeroes. For the far-end
        /// this is the documented TCC failure — the tap is created, the
        /// IOProc fires on schedule, and every sample is 0.0 — so it is
        /// worth saying out loud rather than shipping silence to a
        /// transcription service.
        var farEndSilent: Bool { farEndPeak == 0 }
        var micSilent: Bool { micPeak == 0 }
    }

    /// A snapshot for the meters. Mono per stream: the panel answers
    /// "is sound arriving", not "what does the stereo image look like".
    struct Levels {
        var mic: [Float] = []
        var farEnd: [Float] = []
        var micPeak: Float = 0
        var farEndPeak: Float = 0
    }

    static let sampleRate: Double = 48_000

    enum RecorderError: Error, CustomStringConvertible {
        case bufferAllocationFailed

        var description: String {
            switch self {
            case .bufferAllocationFailed: return "could not allocate the write buffer"
            }
        }
    }

    // MARK: - Tunables

    /// How often the ring buffers are drained to disk. 40 ms is under
    /// the 33 ms UI frame it feeds and far under the 30 s the rings
    /// hold, so it is neither a latency nor an overrun risk.
    private let drainInterval: TimeInterval = 0.04

    /// Watches for either stream going quiet. Separate from the drain
    /// timer because a stall check that runs 25 times a second would be
    /// its own kind of noise.
    private var stallCheck: Timer?

    /// How long to wait for the first mic buffer before recording the
    /// far-end alone. A denied or absent mic must not cost the meeting.
    private let micStartGrace: TimeInterval = 2.0

    // MARK: - State

    private let tap = ProcessTap()
    private let mic = MicCapture()
    private let queue = DispatchQueue(label: "com.atrium-mac.recorder")

    private var micFile: AVAudioFile?
    private var farFile: AVAudioFile?
    private var micBuffer: AVAudioPCMBuffer?
    private var farBuffer: AVAudioPCMBuffer?
    private var timer: DispatchSourceTimer?

    private var session: Session?
    private var micURL: URL?
    private var farURL: URL?
    private var stem: String?
    private var sidecar: RecordingSidecar?
    private var stats = Stats()
    private var started = false
    private var startRequestedAt = Date()

    private var farEndPeak: Float = 0
    private var micPeak: Float = 0

    private let levelsLock = NSLock()
    private var levelsSnapshot = Levels()

    var isRecording: Bool { queue.sync { farFile != nil || micFile != nil } }

    // MARK: - Lifecycle

    /// Open the file and start both streams.
    ///
    /// Throws only when nothing can be recorded at all. A stream that
    /// fails to open is returned as a warning instead: the far-end half
    /// of a call is still worth having if the mic is denied, and the mic
    /// half is still worth having if the tap fails.
    @discardableResult
    func start(session: Session, resuming: RecordingSidecar? = nil) throws -> [String] {
        try AppPaths.ensureDirectories()

        // Start the streams first: their devices decide the file rates,
        // so there is nothing to open until they are running.
        //
        // Order matters between them. Creating the tap's aggregate device
        // is a CoreAudio hardware reconfiguration, which knocks over an
        // input client that started a moment earlier.
        var warnings: [String] = []
        // Rebuilding the tap reconfigures CoreAudio hardware, which is
        // exactly what knocks over an input client — the reason the tap
        // is started before the microphone below. When that happens
        // mid-recording the microphone can stop with no device change to
        // notice, so it is checked once the dust settles.
        tap.onRebuilt = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.mic.restartIfStalled()
            }
        }
        do {
            try tap.start()
        } catch {
            warnings.append("far-end tap failed — \(error)")
        }
        do {
            try mic.start()
        } catch {
            warnings.append("microphone unavailable — \(error)")
        }

        // A session may already own segments: sleep and an abrupt exit
        // close the current one, and the meeting continues into the next.
        let stem = AppPaths.stem(for: session)
        var sidecar = resuming ?? RecordingSidecar(session: session)
        let index = sidecar.segments.count
        let micDestination = AppPaths.recordings
            .appending(path: "\(stem).s\(index).mic.caf")
        let farDestination = AppPaths.recordings
            .appending(path: "\(stem).s\(index).far.caf")
        // `outputRate`, not `deviceRate`: the file is written at one
        // rate for its whole life, and the microphone may move to a
        // device that runs at another. See `MicCapture.drain`.
        let micRate = mic.outputRate > 0 ? mic.outputRate : mic.deviceRate
        let farRate = tap.outputRate > 0 ? tap.outputRate : tap.tapRate

        // Mono Int16 CAF per stream, each at its own device's rate.
        func settings(rate: Double) -> [String: Any] {
            [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        }
        let micFile = try AVAudioFile(
            forWriting: micDestination, settings: settings(rate: micRate),
            commonFormat: .pcmFormatFloat32, interleaved: false)
        let farFile = try AVAudioFile(
            forWriting: farDestination, settings: settings(rate: farRate),
            commonFormat: .pcmFormatFloat32, interleaved: false)

        // Written before a single frame is recorded, so a recording
        // interrupted by a crash is recoverable on the next launch. It
        // is deleted once every segment has been encoded and queued.
        sidecar.segments.append(
            .init(
                micFile: micDestination.lastPathComponent,
                farFile: farDestination.lastPathComponent,
                micRate: micRate, farRate: farRate, startedAt: Date()))
        sidecar.interrupted = true
        sidecar.write(stem: stem)

        let capacity = AVAudioFrameCount(drainInterval * 8 * max(micRate, farRate))
        guard
            let micBuffer = AVAudioPCMBuffer(
                pcmFormat: micFile.processingFormat, frameCapacity: capacity),
            let farBuffer = AVAudioPCMBuffer(
                pcmFormat: farFile.processingFormat, frameCapacity: capacity)
        else { throw RecorderError.bufferAllocationFailed }

        Log.write(
            "recording: mic \(Int(micRate)) Hz -> \(micDestination.lastPathComponent), "
                + "far \(Int(farRate)) Hz -> \(farDestination.lastPathComponent)")

        queue.sync {
            self.micFile = micFile
            self.farFile = farFile
            self.micBuffer = micBuffer
            self.farBuffer = farBuffer
            self.session = session
            self.micURL = micDestination
            self.farURL = farDestination
            self.stem = stem
            self.sidecar = sidecar
            self.stats = Stats()
            self.stats.micRate = micRate
            self.stats.farRate = farRate
            self.micWindow = []
            self.farWindow = []
            self.started = false
            self.startRequestedAt = Date()
            self.farEndPeak = 0
            self.micPeak = 0
        }
        levelsLock.lock()
        levelsSnapshot = Levels()
        levelsLock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + drainInterval, repeating: drainInterval)
        // Both streams are checked for having stopped, not only for
        // their device having changed. A device that vanishes takes the
        // stream with it and updates the default-device property some
        // time later — 28 seconds later, measured — and everything in
        // between is audio nobody recorded.
        stallCheck?.invalidate()
        stallCheck = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self] _ in
            guard let self, self.isRecording else { return }
            self.tap.restartIfStalled()
            self.mic.restartIfStalled()
            // Cheap, and only logs on change — catches a clean input
            // device appearing mid-call, which is how a WhatsApp capture
            // escapes the contended voice-processed built-in. See #12.
            self.mic.logInputDevicesIfChanged("mid-recording")
        }
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
        return warnings
    }

    /// Stop, flush what is buffered, and close the file.
    ///
    /// Returns `nil` when nothing was recording. Safe to call from the
    /// sleep notification and from `applicationWillTerminate` — both
    /// treat the file as complete, which is the settled behaviour for
    /// lid-close mid-meeting.
    /// Close the current segment.
    ///
    /// `interrupted: true` means the machine went away — sleep, quit,
    /// a crash — and the meeting may continue. The sidecar stays on disk
    /// saying so, which is what lets the next launch, or the wake
    /// handler, pick the session back up rather than treat it as over.
    @discardableResult
    func finish(interrupted: Bool = false) -> Recording? {
        timer?.cancel()
        timer = nil
        stallCheck?.invalidate()
        stallCheck = nil

        // Drain *before* stopping the producers. `ProcessTap.stop()`
        // destroys its ring, so the order here is the difference between
        // keeping the last second of the meeting and dropping it.
        let recording = queue.sync { () -> Recording? in
            guard self.farFile != nil || self.micFile != nil,
                let session, let stem, var sidecar
            else { return nil }

            drainLocked(final: true)

            stats.tapOverruns = tap.overruns
            stats.micOverruns = mic.overruns
            stats.micFramesProduced = mic.framesProduced
            stats.micCallbacks = mic.callbacks
            stats.inputDeviceChanged = mic.deviceChangedDuringCapture
            stats.inputDeviceSwitches = mic.deviceSwitches
            stats.outputDeviceSwitches = tap.deviceSwitches
            stats.micSilentForSeconds = mic.silentFor
            sidecar.interrupted = interrupted
            sidecar.write(stem: stem)

            let recording = Recording(
                session: session,
                stem: stem,
                segments: sidecar.segments,
                duration: stats.duration,
                micPeak: micPeak,
                farEndPeak: farEndPeak,
                stats: stats)

            // AVAudioFile finalises the CAF header when it deallocates,
            // and there is no explicit close. Releasing it here, inside
            // the block, is what guarantees the file on disk is complete
            // by the time this function returns to a caller that is
            // about to read it.
            self.micFile = nil
            self.farFile = nil
            self.micBuffer = nil
            self.farBuffer = nil
            self.session = nil
            self.micURL = nil
            self.farURL = nil
            self.stem = nil
            self.sidecar = nil
            return recording
        }

        mic.stop()
        tap.stop()
        publishIdleLevels()
        return recording
    }

    /// Stop and delete. Used when the session controller discards a
    /// candidate — a mic test that was never a call.
    func discard() {
        guard let recording = finish() else { return }
        RecordingSidecar(
            bundleID: recording.session.bundleID,
            startedAt: recording.session.startedAt,
            isManual: recording.session.isManual,
            segments: recording.segments
        ).discardFiles(stem: recording.stem)
    }

    /// Latest meter data. Cheap enough for a 30 fps timer.
    func levels() -> Levels {
        levelsLock.lock()
        defer { levelsLock.unlock() }
        return levelsSnapshot
    }

    // MARK: - The drain

    private func drain() {
        drainLocked(final: false)
    }

    private func drainLocked(final: Bool) {
        guard let micFile, let farFile, let micBuffer, let farBuffer else { return }

        // Start both files together. Each producer has its own latency
        // and they do not begin at the same instant, so whatever is
        // already in the rings is pre-roll of unknown age. Discard it
        // once, on the first drain where both have delivered, and start
        // from a common moment. That bounds the offset between the two
        // files to one drain interval.
        if !started {
            let bothReady = mic.available > 0 && tap.available > 0
            let graceExpired =
                Date().timeIntervalSince(startRequestedAt) > micStartGrace
            guard bothReady || graceExpired || final else { return }
            _ = mic.drain(maxFrames: mic.available)
            _ = tap.drain(maxFrames: tap.available)
            started = true
            return
        }

        // No alignment, no padding, no dropping. Each stream is written
        // exactly as it arrived, at its own rate. Whatever the clocks
        // did to each other is recoverable afterwards from the two file
        // lengths, which is where it is now dealt with.
        let micWritten = write(
            stream: mic.drain(maxFrames: Int(micBuffer.frameCapacity)),
            to: micFile, using: micBuffer)
        if micWritten.frames > 0 {
            stats.micFramesWritten += micWritten.frames
            micPeak = max(micPeak, micWritten.peak)
        }

        let farWritten = write(
            stream: tap.drain(maxFrames: Int(farBuffer.frameCapacity)),
            to: farFile, using: farBuffer)
        if farWritten.frames > 0 {
            stats.farFramesWritten += farWritten.frames
            farEndPeak = max(farEndPeak, farWritten.peak)
        }

        if micWritten.frames == 0 && farWritten.frames == 0 {
            if !final { publishIdleLevels() }
            return
        }
        publishLevels(
            mic: micWritten.samples, farEnd: farWritten.samples,
            micPeak: micWritten.peak, farEndPeak: farWritten.peak)
    }

    private func write(
        stream samples: [Float], to file: AVAudioFile, using buffer: AVAudioPCMBuffer
    ) -> (frames: Int, peak: Float, samples: [Float]) {
        let frames = min(samples.count, Int(buffer.frameCapacity))
        guard frames > 0, let channel = buffer.floatChannelData?[0] else {
            return (0, 0, [])
        }
        var peak: Float = 0
        for index in 0..<frames {
            let value = samples[index]
            channel[index] = value
            peak = max(peak, abs(value))
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        do {
            try file.write(from: buffer)
        } catch {
            // Disk full, or the volume went away. The session still ends
            // normally and the partial file is still uploadable.
            Log.write("atrium-mac: write failed — \(error)")
            return (0, peak, [])
        }
        return (frames, peak, Array(samples[0..<frames]))
    }

    // MARK: - Meters

    /// FFT width the panel's analyzer needs before it will produce a
    /// frame. Publishing less than this just makes the meter idle.
    private static let meterFrames = 1024

    /// Rolling windows for the meters, so a drain smaller than the FFT
    /// still drives the display.
    ///
    /// This published only the current block once. That is fine at
    /// 48 kHz, where a 40 ms drain carries ~1920 frames, and silently
    /// wrong on a device running slower — the analyser needs 1024 and
    /// simply idled, so the bars sat flat while the recording was fine.
    private var micWindow: [Float] = []
    private var farWindow: [Float] = []

    private func publishLevels(
        mic micFrames: [Float], farEnd farFrames: [Float],
        micPeak: Float, farEndPeak: Float
    ) {
        micWindow.append(contentsOf: micFrames)
        farWindow.append(contentsOf: farFrames)
        if micWindow.count > Self.meterFrames {
            micWindow.removeFirst(micWindow.count - Self.meterFrames)
        }
        if farWindow.count > Self.meterFrames {
            farWindow.removeFirst(farWindow.count - Self.meterFrames)
        }

        levelsLock.lock()
        levelsSnapshot = Levels(
            mic: micWindow, farEnd: farWindow, micPeak: micPeak, farEndPeak: farEndPeak)
        levelsLock.unlock()
    }

    private func publishIdleLevels() {
        levelsLock.lock()
        levelsSnapshot = Levels()
        levelsLock.unlock()
    }
}
