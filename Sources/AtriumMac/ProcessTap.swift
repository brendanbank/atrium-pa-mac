import AtriumCore
import CRingBuffer
import AVFoundation
import AtriumCore
import CoreAudio
import Foundation

/// Captures system ("far-end") audio via a CoreAudio process tap.
///
/// Chosen over ScreenCaptureKit deliberately: SCK's audio capture
/// requires the full Screen Recording grant, whereas a process tap needs
/// only audio capture consent, and it can be scoped to specific
/// processes so it does not sweep up the user's music.
///
/// **The app must be a real, signed `.app` bundle launched normally.**
/// This is not a packaging nicety — it is the difference between working
/// and silently not working. Measured with the identical binary:
///
/// | launch context | frames delivered | peak amplitude |
/// |---|---|---|
/// | bare CLI, ad-hoc signed, no Info.plist | 556,032 | 0.000000 |
/// | `.app` bundle via LaunchServices | 559,104 | 0.757179 |
///
/// Note the failure mode: the tap is created successfully, the aggregate
/// device builds, and the IOProc fires on schedule delivering a perfectly
/// timed stream of **zeroes**. Nothing errors. Check `peakAmplitude`
/// before trusting a recording.
final class ProcessTap {

    enum TapError: Error, CustomStringConvertible {
        case tapCreationFailed(OSStatus)
        case noTapUID
        case noDefaultOutputDevice
        case aggregateCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case startFailed(OSStatus)
        case ringAllocationFailed
        case converterUnavailable(Double)

        var description: String {
            switch self {
            case .tapCreationFailed(let s): return "AudioHardwareCreateProcessTap failed (\(s))"
            case .noTapUID: return "tap has no UID"
            case .noDefaultOutputDevice: return "no default output device"
            case .aggregateCreationFailed(let s): return "aggregate device failed (\(s))"
            case .ioProcCreationFailed(let s): return "IOProc creation failed (\(s))"
            case .startFailed(let s): return "AudioDeviceStart failed (\(s))"
            case .ringAllocationFailed: return "ring buffer allocation failed"
            case .converterUnavailable(let rate):
                return "cannot resample \(Int(rate)) Hz far-end audio to 48 kHz"
            }
        }
    }

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private var ring: OpaquePointer?

    /// What the aggregate device actually runs at, read at start rather
    /// than assumed. See the note in `start()`.
    private(set) var tapRate: Double = 48_000

    /// The rate `drain` delivers at, whatever aggregate is underneath.
    ///
    /// Fixed at the first `start()`, for the same reason
    /// `MicCapture.outputRate` is: the master file is opened at this
    /// rate and cannot change halfway through. The aggregate is built
    /// around the default *output* device, and that device can change —
    /// AirPods arriving is the ordinary case — bringing a different rate
    /// with it.
    private(set) var outputRate: Double = 0
    private var rateAdapter: Resampler?

    /// The exclusion list this tap was built with, so a rebuild uses the
    /// same one. Excluding our own process is what stops the recording
    /// feeding back into itself.
    private var excluded: [AudioObjectID] = []

    /// The output device UID the current aggregate was built around.
    ///
    /// Compared before rebuilding, because **creating an aggregate
    /// device re-fires the default-output-device property**. Without
    /// this the first rebuild triggers the next: measured, ten rebuilds
    /// in under two seconds, each one costing far-end audio. The
    /// microphone has always had the equivalent guard —
    /// `device != deviceID` — and the tap did not.
    private var builtAroundUID: String?

    /// Times the tap followed the output device during this capture.
    private(set) var deviceSwitches = 0
    private var isFollowingDevice = false

    /// When the IOProc last delivered, on the system clock.
    ///
    /// The far-end tap runs continuously whether or not anything is
    /// playing, so "no frames for a second" means the stream is gone —
    /// not that the meeting went quiet. That is what makes a stall
    /// detectable here at all.
    private(set) var lastFrameSeconds: TimeInterval = 0

    /// Frames the tap has produced, and when it started producing them.
    /// Together these give the rate it is *really* running at, which is
    /// not always the rate it reports.
    private(set) var framesProduced: Int = 0
    private var producingSince: TimeInterval = 0

    /// Seconds since the tap last delivered, or nil if it never has.
    var silentFor: TimeInterval? {
        guard lastFrameSeconds > 0 else { return nil }
        return ProcessInfo.processInfo.systemUptime - lastFrameSeconds
    }
    private var outputListener: AudioObjectPropertyListenerBlock?

    /// Called after the tap has been rebuilt around a new output device.
    ///
    /// Rebuilding creates an aggregate device, which is a CoreAudio
    /// hardware reconfiguration — the same one that knocks over an input
    /// client started a moment earlier, which is why `AudioRecorder`
    /// starts the tap before the microphone. Doing it mid-recording can
    /// therefore silence the microphone, so whoever owns both is told
    /// and can check.
    var onRebuilt: (() -> Void)?
    private var tapChannels: Int = 2

    /// Pre-allocated mono scratch for the realtime callback.
    private var scratch: UnsafeMutablePointer<Float>?
    private var scratchCapacity = 0
    private var loggedLayout = false

    /// Nominal rate, kept only as a fallback when the device refuses to
    /// describe itself.
    static let workingRate: Double = 48_000

    /// Highest absolute sample seen since `start()`. Zero after a
    /// meaningful run means the tap is muted — see the class docs.
    private(set) var peakAmplitude: Float = 0

    /// Seconds of audio the ring can hold before the producer drops
    /// frames. 30 s at 48 kHz stereo is ~11 MB — cheap insurance against
    /// a slow consumer during a disk stall.
    private let ringSeconds: Double = 30

    // MARK: - Lifecycle

    /// Start tapping. Pass process object IDs to scope the tap, or an
    /// empty array to tap everything except this process.
    func start(excluding excludedProcesses: [AudioObjectID] = []) throws {
        excluded = excludedProcesses
        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: excludedProcesses)
        description.name = "Atrium PA meeting capture"
        description.isPrivate = true  // invisible to other apps
        // Never alter what the user hears — a tap that mutes the meeting
        // would be worse than no recording at all.
        description.muteBehavior = CATapMuteBehavior.unmuted

        var tap: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr else { throw TapError.tapCreationFailed(tapStatus) }
        tapID = tap

        guard let tapUID = CA.tapUID(tap) else { throw TapError.noTapUID }
        guard let outputUID = CA.defaultOutputDeviceUID() else {
            throw TapError.noDefaultOutputDevice
        }

        // The tap only becomes readable through an aggregate device that
        // includes it. Private so it never appears in Sound preferences.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Atrium PA capture",
            kAudioAggregateDeviceUIDKey: "com.atrium-mac.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        var device: AudioObjectID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(
            aggregate as CFDictionary, &device)
        guard aggStatus == noErr else {
            cleanup()
            throw TapError.aggregateCreationFailed(aggStatus)
        }
        aggregateID = device

        // Ask the device what it is actually going to hand us.
        //
        // This used to assume 48 kHz stereo. AirPods are the case that
        // proves it wrong: while the microphone is in use they run a
        // bidirectional profile at a much lower rate, so the tap
        // delivered roughly a third of the expected frames. Those frames
        // were then written into a file stamped 48 kHz — a recording
        // that plays back fast — and each drain carried too few samples
        // for the panel's FFT, so the bars never moved. Two symptoms,
        // one hardcoded constant.
        var format = AudioStreamBasicDescription()
        var formatAddress = CA.address(
            kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput)
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioObjectGetPropertyData(
            device, &formatAddress, 0, nil, &formatSize, &format) == noErr,
            format.mSampleRate > 0, format.mChannelsPerFrame > 0
        {
            tapRate = format.mSampleRate
            tapChannels = Int(format.mChannelsPerFrame)
        } else {
            tapRate = Self.workingRate
            tapChannels = 2
        }
        // The first aggregate to arrive sets the rate the file is
        // written at; later ones are resampled to it in `drain`.
        if outputRate == 0 { outputRate = tapRate }
        rateAdapter =
            tapRate == outputRate ? nil : Resampler(from: tapRate, to: outputRate)
        if tapRate != outputRate, rateAdapter == nil {
            // Silently writing frames at the wrong rate is the failure
            // this whole arrangement exists to prevent, so say so.
            Log.write(
                "tap: could not build a resampler from \(Int(tapRate)) to "
                    + "\(Int(outputRate)) Hz — the far end will be at the wrong speed")
        }
        builtAroundUID = CA.defaultOutputDeviceUID()
        framesProduced = 0
        producingSince = ProcessInfo.processInfo.systemUptime
        Log.write(
            "tap: aggregate device runs at \(Int(tapRate)) Hz, \(tapChannels) ch")

        // Check what it is *actually* delivering, a moment later.
        //
        // An aggregate built around a Bluetooth device reports the rate
        // it had when it was created, and the link can settle to another
        // one after that — AirPods drop to 24 kHz when they are also the
        // input. Measured: the aggregate said 48000 while delivering
        // frames at about half that, so a 28-second stretch of call
        // became 13 seconds of far-end audio and the rest looked like
        // loss.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.checkDeliveredRate()
        }

        // Mono at the device's own rate. Mono because the recorder wants
        // one far-end channel and folding here is a handful of adds on a
        // thread that is already touching the samples; at the device's
        // rate because resampling on a realtime thread would mean
        // allocating on a realtime thread.
        guard let ring = arb_create(Int(ringSeconds * tapRate), 1) else {
            cleanup()
            throw TapError.ringAllocationFailed
        }
        self.ring = ring

        let scratchFrames = 16_384
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrames)
        scratch.initialize(repeating: 0, count: scratchFrames)
        self.scratch = scratch
        self.scratchCapacity = scratchFrames
        loggedLayout = false

        let ringPointer = ring
        let channelCount = tapChannels
        var proc: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
            &proc, device, DispatchQueue(label: "com.atrium-mac.render")
        ) { [weak self] _, inInputData, _, _, _ in
            // RENDER THREAD. No allocation, no locks, no ARC traffic.
            //
            // Note: must use UnsafeMutableAudioBufferListPointer here.
            // Taking a pointer to `mBuffers` via withUnsafePointer lets it
            // escape and dangle, which is an immediate SIGBUS.
            guard let self, let scratch = self.scratch else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            guard let first = buffers.first, let data = first.mData else { return }

            // One line, once, describing what the device actually hands
            // over. The device's *stream format* and the shape of the
            // buffer list it delivers are not the same question, and
            // guessing at the second is how the frame count ends up
            // wrong — which does not look like a bug, it looks like a
            // recording that lags further behind every second.
            if !self.loggedLayout {
                self.loggedLayout = true
                let shape = (0..<buffers.count).map {
                    "[\(buffers[$0].mNumberChannels)ch \(buffers[$0].mDataByteSize)B]"
                }.joined()
                Log.write("tap: IOProc buffer list = \(buffers.count) buffer(s) \(shape)")
            }

            var localPeak: Float = 0
            var frames = 0

            if buffers.count == 1 {
                // Interleaved: one buffer holding every channel.
                let sampleCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                frames = min(sampleCount / max(channelCount, 1), self.scratchCapacity)
                let samples = data.bindMemory(to: Float.self, capacity: sampleCount)
                let scale = 1 / Float(max(channelCount, 1))
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channelCount {
                        sum += samples[frame * channelCount + channel]
                    }
                    let value = sum * scale
                    scratch[frame] = value
                    let magnitude = abs(value)
                    if magnitude > localPeak { localPeak = magnitude }
                }
            } else {
                // Planar: one buffer per channel.
                frames = min(
                    Int(first.mDataByteSize) / MemoryLayout<Float>.size,
                    self.scratchCapacity)
                let scale = 1 / Float(buffers.count)
                for frame in 0..<frames { scratch[frame] = 0 }
                for buffer in buffers {
                    guard let channelData = buffer.mData else { continue }
                    let samples = channelData.bindMemory(to: Float.self, capacity: frames)
                    for frame in 0..<frames { scratch[frame] += samples[frame] * scale }
                }
                for frame in 0..<frames {
                    let magnitude = abs(scratch[frame])
                    if magnitude > localPeak { localPeak = magnitude }
                }
            }

            if frames > 0 {
                _ = arb_write(ringPointer, scratch, frames)
                self.framesProduced += frames
                // One store of a POD on a realtime thread; see
                // MicCapture for why nothing more happens here.
                self.lastFrameSeconds = ProcessInfo.processInfo.systemUptime
            }
            if localPeak > self.peakAmplitude { self.peakAmplitude = localPeak }
        }

        guard ioStatus == noErr, let proc else {
            cleanup()
            throw TapError.ioProcCreationFailed(ioStatus)
        }
        procID = proc

        let startStatus = AudioDeviceStart(device, proc)
        guard startStatus == noErr else {
            cleanup()
            throw TapError.startFailed(startStatus)
        }
        watchForOutputDeviceChange()
    }

    /// Follow the default output device.
    ///
    /// The aggregate is built around one output UID, resolved once. When
    /// the default output changes the tap is left wrapped around a
    /// device that is no longer playing the call, and the far end simply
    /// stops. Measured: a 38-second recording whose far end ended at 19
    /// seconds when the output moved, with nothing in the log to say so.
    private func watchForOutputDeviceChange() {
        removeOutputListener()
        var address = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.followDefaultOutputDevice()
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address,
            DispatchQueue.main, block) == noErr
        {
            outputListener = block
        }
    }

    private func removeOutputListener() {
        guard let outputListener else { return }
        var address = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address,
            DispatchQueue.main, outputListener)
        self.outputListener = nil
    }

    /// Compare the rate the aggregate claims against what it delivers.
    ///
    /// The claimed rate decides how many frames a second of audio is,
    /// so believing a wrong one stretches or squashes the far end for
    /// the rest of the recording. This does not correct it — the file is
    /// already open at `outputRate` — but it says so plainly, which is
    /// the difference between a diagnosable recording and a mystery.
    private func checkDeliveredRate() {
        guard procID != nil, producingSince > 0, framesProduced > 0 else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - producingSince
        guard elapsed > 1 else { return }

        let delivered = Double(framesProduced) / elapsed
        let ratio = delivered / tapRate
        guard ratio < 0.9 || ratio > 1.1 else { return }
        Log.write(
            String(
                format: "tap: the aggregate claims %.0f Hz but is delivering %.0f — "
                    + "the far end will be %.0f%% of its true length",
                tapRate, delivered, ratio * 100))
    }

    /// Rebuild if the tap has stopped delivering.
    ///
    /// Measured: AirPods going away took the aggregate's sub-device with
    /// them and the far end stopped, while
    /// `kAudioHardwarePropertyDefaultOutputDevice` did not change for
    /// another 28 seconds. Watching the device property alone lost that
    /// half-minute; the stream going quiet is the earlier and more
    /// direct signal, and the tap runs continuously whether or not
    /// anything is playing, so quiet means gone rather than silent.
    @discardableResult
    func restartIfStalled(quietFor threshold: TimeInterval = 1.5) -> Bool {
        guard procID != nil, let silent = silentFor, silent > threshold else {
            return false
        }
        Log.write(
            String(
                format: "tap: no far-end frames for %.1fs — rebuilding", silent))
        followDefaultOutputDevice(force: true)
        return true
    }

    private func followDefaultOutputDevice(force: Bool = false) {
        guard procID != nil else { return }
        // Re-entrancy: `start()` below creates an aggregate, which fires
        // this listener again while we are still inside it.
        guard !isFollowingDevice else { return }

        let current = CA.defaultOutputDeviceUID()
        if !force, let current, current == builtAroundUID {
            // The property fired but the device did not actually change,
            // which is what building an aggregate looks like from here.
            return
        }

        let wasRate = tapRate
        deviceSwitches += 1

        if aggregateID != 0, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        cleanup()

        isFollowingDevice = true
        defer { isFollowingDevice = false }
        do {
            try start(excluding: excluded)
            Log.write(
                "tap: followed the default output device — now \(Int(tapRate)) Hz "
                    + "(was \(Int(wasRate)))"
                    + (rateAdapter == nil
                        ? "" : ", resampling to \(Int(outputRate)) Hz for the file"))
            onRebuilt?()
        } catch {
            // The microphone keeps recording. Half a meeting is worth
            // more than none, and the encoder pads the far end.
            Log.write(
                "tap: could not follow the default output device — \(error). "
                    + "The far end is silent for the rest of this recording.")
        }
    }

    func stop() {
        removeOutputListener()
        builtAroundUID = nil
        outputRate = 0
        rateAdapter = nil
        deviceSwitches = 0
        if aggregateID != 0, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        cleanup()
    }

    /// Drain up to `maxFrames` interleaved frames. Call from a normal
    /// thread; never from the render callback.
    /// Drain up to `maxFrames` mono frames **at the device's own rate**.
    ///
    /// Not converted here, for the same reason `MicCapture.drain` is
    /// not: a resampler in the drain loop loses samples at every call
    /// boundary, and its ratio error is indistinguishable from clock
    /// drift to whatever aligns the streams afterwards. The far end gets
    /// its own file at its own rate; the rates meet once, offline, in
    /// `AudioEncoder`.
    func drain(maxFrames: Int) -> [Float] {
        guard let ring, maxFrames > 0 else { return [] }

        guard let rateAdapter else {
            var out = [Float](repeating: 0, count: maxFrames)
            let got = out.withUnsafeMutableBufferPointer { buffer -> Int in
                arb_read(ring, buffer.baseAddress!, maxFrames)
            }
            out.removeLast(out.count - got)
            return out
        }

        // Only after the output device has changed to one with a
        // different rate. The comment above still holds for the ordinary
        // case: nothing is resampled while a single device is running.
        let wanted = rateAdapter.inputNeeded(forOutput: maxFrames)
        if wanted > 0 {
            var raw = [Float](repeating: 0, count: wanted)
            let got = raw.withUnsafeMutableBufferPointer { buffer -> Int in
                arb_read(ring, buffer.baseAddress!, wanted)
            }
            if got > 0 {
                raw.removeLast(raw.count - got)
                rateAdapter.push(raw)
            }
        }
        return rateAdapter.pull(maxFrames: maxFrames)
    }

    /// Frames waiting, at the device's rate.
    var available: Int {
        guard let ring else { return 0 }
        return arb_available(ring)
    }

    /// Frames the render thread had to drop because the consumer was too
    /// slow. Non-zero is a bug worth surfacing, not a statistic to hide.
    var overruns: UInt64 {
        guard let ring else { return 0 }
        return arb_overruns(ring)
    }

    private func cleanup() {
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
        if let ring {
            arb_destroy(ring)
            self.ring = nil
        }
        if let scratch {
            scratch.deallocate()
            self.scratch = nil
            scratchCapacity = 0
        }
    }

    deinit { stop() }
}
