import AVFoundation
import AtriumCore
import CRingBuffer
import CoreAudio
import Foundation

/// Microphone capture, straight off the default input device with a
/// CoreAudio IOProc.
///
/// ## Why not AVAudioEngine
///
/// This was an `AVAudioEngine` input tap first. On macOS 26.5, in this
/// app, it does not work — and it does not say so. Measured, each over a
/// 14 s recording with the microphone grant reading `authorized` and
/// `engine.start()` returning without error:
///
/// | attempt | callbacks | frames |
/// |---|---|---|
/// | `installTap` on `inputNode`, `inputFormat(forBus:)` | 0 | 0 |
/// | `installTap` on `inputNode`, `outputFormat(forBus:)` | 0 | 0 |
/// | input → silent mixer → main mixer, tap the mixer | 0 | 0 |
///
/// Three shapes of the documented recipe, no error, no log line, no
/// audio. The recording came out with a left channel of pure silence,
/// and the only evidence anything was wrong was the recorder's own
/// padding counter reading 100%.
///
/// This is not specific to this app. Apple's own forums carry the same
/// report against macOS 26 — AVFoundation's audio-input layer failing
/// while the CoreAudio HAL underneath it enumerates and runs every
/// device normally (FB19024508, thread 794843). It is also the same
/// *class* of failure the whole project is built around: an audio API
/// that succeeds and delivers nothing.
///
/// So this talks to the HAL directly, exactly as `ProcessTap` does, and
/// the HAL is demonstrably healthy on this machine. More code, no
/// surprises.
///
/// ## What the callback may do
///
/// The IOProc runs on a CoreAudio realtime thread under the constraints
/// described in `ProcessTap`: no allocation, no locks, no ARC traffic.
/// It downmixes to mono into a pre-allocated scratch buffer, hands off
/// through `CRingBuffer`, and does nothing else.
///
/// **Sample-rate conversion is deliberately not done there.** A device
/// may be at 44.1 kHz, or at 16 kHz on a Bluetooth headset in its voice
/// profile, while the recorder's working format is 48 kHz. Resampling on
/// a realtime thread means allocating on a realtime thread, so the ring
/// holds mono at the *device* rate and `drain` converts on the consumer
/// side, where allocation is allowed.
final class MicCapture {

    enum MicError: Error, CustomStringConvertible {
        case noInputDevice
        case unsupportedFormat(String)
        case ringAllocationFailed
        case ioProcCreationFailed(OSStatus)
        case startFailed(OSStatus)
        case converterUnavailable(Double)

        var description: String {
            switch self {
            case .noInputDevice:
                return "no default input device — no microphone available"
            case .unsupportedFormat(let what):
                return "input device format unusable — \(what)"
            case .ringAllocationFailed:
                return "mic ring buffer allocation failed"
            case .ioProcCreationFailed(let status):
                return "mic IOProc creation failed (\(status))"
            case .startFailed(let status):
                return "AudioDeviceStart on the input device failed (\(status))"
            case .converterUnavailable(let rate):
                return "cannot resample \(Int(rate)) Hz mic input to 48 kHz"
            }
        }
    }

    /// Nominal working rate, kept only as a fallback when the device
    /// refuses to describe itself.
    static let sampleRate: Double = 48_000

    /// What the input device actually runs at. The recorder writes the
    /// microphone to its own file at this rate and never converts it
    /// during capture — see the note on `drain`.
    private(set) var deviceRate: Double = 48_000

    /// The rate `drain` delivers at, whatever device is underneath.
    ///
    /// Fixed at the first `start()` and held for the life of the
    /// capture, because `AudioRecorder` opens the master file at this
    /// rate and a file cannot change rate halfway through. When the
    /// microphone moves to a device that runs at a different rate —
    /// AirPods in hands-free mode are 16 kHz where the built-in mic is
    /// 48 — the difference is resampled on the way out rather than
    /// written into a file that claims otherwise.
    private(set) var outputRate: Double = 0

    /// Set when the device underneath is not running at `outputRate`.
    private var rateAdapter: Resampler?

    /// Devices this capture has been through, for the session log.
    private(set) var deviceSwitches = 0

    /// True only while `start()` is being called to follow a device
    /// change, so it can tell a fresh capture from a continuation.
    private var isFollowingDevice = false

    /// Whether this app may use the microphone, in words.
    /// Whether the microphone question has been answered either way.
    /// `notDetermined` means the dialog is still on screen.
    static var isAuthorizationDetermined: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) != .notDetermined
    }

    static var authorizationDescription: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    /// Ask for the microphone grant, and report what we ended up with.
    ///
    /// This call is what makes the dialog appear. Without it macOS does
    /// not necessarily prompt, and an ad-hoc-signed build gets a fresh
    /// identity on every rebuild, so it lands back on `notDetermined`
    /// each time — which is very probably why no TCC dialog was ever
    /// observed during this project's development.
    ///
    /// Safe to call on every launch: once a decision is recorded it is
    /// returned without prompting again.
    static func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // MARK: - State

    private var deviceID: AudioObjectID = 0

    /// When the IOProc last delivered anything, and how much.
    ///
    /// A microphone that stops is silent in every sense: the callback
    /// simply stops being called, no error is raised, and the recording
    /// ends up short with nothing to say why. Measured on a 13-minute
    /// call, the input stream ended 30 seconds before the far end and
    /// the only trace was a frame count that did not add up.
    private(set) var lastFrameSeconds: TimeInterval = 0

    /// Seconds since the IOProc last delivered anything, or nil if it
    /// never did.
    var silentFor: TimeInterval? {
        guard lastFrameSeconds > 0 else { return nil }
        return ProcessInfo.processInfo.systemUptime - lastFrameSeconds
    }
    private var deviceListener: AudioObjectPropertyListenerBlock?

    /// Set when the default input device changes while we are recording,
    /// so the session log can say that is what happened.
    private(set) var deviceChangedDuringCapture = false
    private var procID: AudioDeviceIOProcID?
    /// Mono at the device's own rate.
    private var ring: OpaquePointer?
    private var isRunning = false

    /// Pre-allocated mono scratch for the realtime callback.
    private var scratch: UnsafeMutablePointer<Float>?
    private var scratchCapacity = 0

    /// 30 s at 48 kHz mono is ~5.7 MB. Matches `ProcessTap`.
    private let ringSeconds: Double = 30

    /// Highest absolute sample since `start()`. Zero after a meaningful
    /// run means the mic is muted or denied.
    private(set) var peakAmplitude: Float = 0

    /// Frames handed to the ring, and how many times the IOProc fired.
    /// Zero callbacks is "the device never ran"; callbacks with no
    /// frames is "it ran and produced nothing". Those have different
    /// causes, telling them apart is what found the bug above, and both
    /// are reported in the session log line.
    private(set) var framesProduced: Int = 0
    private(set) var callbacks: Int = 0

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }

        var device = AudioObjectID(0)
        var address = CA.address(
            kAudioHardwarePropertyDefaultInputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size,
                &device) == noErr, device != 0
        else { throw MicError.noInputDevice }
        deviceID = device

        var format = AudioStreamBasicDescription()
        var formatAddress = CA.address(
            kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput)
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard
            AudioObjectGetPropertyData(
                device, &formatAddress, 0, nil, &formatSize, &format) == noErr,
            format.mSampleRate > 0, format.mChannelsPerFrame > 0
        else {
            cleanup()
            throw MicError.noInputDevice
        }

        // Everything below assumes 32-bit float, which is what CoreAudio
        // hands out for input on every device this has been seen on. If
        // that is ever false, say so rather than reinterpreting the bytes
        // and recording noise.
        guard format.mFormatID == kAudioFormatLinearPCM,
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            format.mBitsPerChannel == 32
        else {
            cleanup()
            throw MicError.unsupportedFormat(
                "expected 32-bit float PCM, got formatID \(format.mFormatID) "
                    + "flags \(format.mFormatFlags) bits \(format.mBitsPerChannel)")
        }

        deviceRate = format.mSampleRate
        // The first device to arrive sets the rate everything downstream
        // is built for.
        if outputRate == 0 { outputRate = deviceRate }
        rateAdapter =
            deviceRate == outputRate
            ? nil : Resampler(from: deviceRate, to: outputRate)
        let channels = max(Int(format.mChannelsPerFrame), 1)
        let isInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        guard let ring = arb_create(Int(ringSeconds * deviceRate), 1) else {
            cleanup()
            throw MicError.ringAllocationFailed
        }
        self.ring = ring

        // Counters survive a device switch. `start()` runs again on
        // every rebind, and zeroing here made the session line report
        // only the frames since the last switch — under a heading that
        // reads like the whole recording. These numbers are what a short
        // stream gets diagnosed from, so they have to cover it.
        if !isFollowingDevice {
            peakAmplitude = 0
            framesProduced = 0
            callbacks = 0
        }

        // Allocated once, so the realtime callback never does. CoreAudio
        // asks for 512–4096 frames in practice; this is far above that.
        let scratchFrames = 16_384
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrames)
        scratch.initialize(repeating: 0, count: scratchFrames)
        self.scratch = scratch
        self.scratchCapacity = scratchFrames

        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &proc, device, DispatchQueue(label: "com.atrium-mac.mic-render")
        ) { [weak self] _, inInputData, _, _, _ in
            // RENDER THREAD. No allocation, no locks, no ARC traffic.
            //
            // Note: UnsafeMutableAudioBufferListPointer, not
            // withUnsafePointer on mBuffers — the latter lets the pointer
            // escape and dangle, which is an immediate SIGBUS. Same trap
            // as ProcessTap.
            guard let self, let ring = self.ring, let scratch = self.scratch else {
                return
            }
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            guard let first = buffers.first, first.mData != nil else { return }

            self.callbacks += 1
            var localPeak: Float = 0
            var frames = 0

            if isInterleaved {
                guard let data = first.mData else { return }
                let sampleCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                frames = min(sampleCount / channels, self.scratchCapacity)
                let samples = data.bindMemory(to: Float.self, capacity: sampleCount)
                let scale = 1 / Float(channels)
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels {
                        sum += samples[frame * channels + channel]
                    }
                    let value = sum * scale
                    scratch[frame] = value
                    let magnitude = abs(value)
                    if magnitude > localPeak { localPeak = magnitude }
                }
            } else {
                // One buffer per channel, each already mono.
                frames = min(
                    Int(first.mDataByteSize) / MemoryLayout<Float>.size,
                    self.scratchCapacity)
                let scale = 1 / Float(buffers.count)
                for frame in 0..<frames { scratch[frame] = 0 }
                for buffer in buffers {
                    guard let channelData = buffer.mData else { continue }
                    let samples = channelData.bindMemory(to: Float.self, capacity: frames)
                    for frame in 0..<frames {
                        scratch[frame] += samples[frame] * scale
                    }
                }
                for frame in 0..<frames {
                    let magnitude = abs(scratch[frame])
                    if magnitude > localPeak { localPeak = magnitude }
                }
            }

            if frames > 0 {
                self.framesProduced += Int(arb_write(ring, scratch, frames))
                // One store of a POD, no allocation and no lock: this
                // runs on a CoreAudio realtime thread. It is the only
                // way to tell "the microphone went quiet" from "the
                // microphone stopped being called".
                self.lastFrameSeconds = ProcessInfo.processInfo.systemUptime
            }
            if localPeak > self.peakAmplitude { self.peakAmplitude = localPeak }
        }

        guard status == noErr, let proc else {
            cleanup()
            throw MicError.ioProcCreationFailed(status)
        }
        procID = proc

        watchForDeviceChange()
        let startStatus = AudioDeviceStart(device, proc)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(device, proc)
            procID = nil
            cleanup()
            throw MicError.startFailed(startStatus)
        }
        isRunning = true

        Log.write(
            "mic started: device \(device) at \(Int(deviceRate)) Hz, \(channels) ch, "
                + "\(isInterleaved ? "interleaved" : "planar"), "
                + "tcc \(Self.authorizationDescription)")
    }

    /// Move the capture to whatever is now the default input.
    ///
    /// Two failures come from staying put, and which one you get depends
    /// on whether the old device keeps running. Measured both ways:
    /// a WhatsApp call where the old device stopped and the recording
    /// lost its last 30 seconds, and a switch to AirPods where the old
    /// device kept going and the rest of the take was recorded from the
    /// built-in microphone instead — 37.2 s of audio, no shortfall, and
    /// entirely the wrong input.
    ///
    /// The rate is allowed to change here; `outputRate` is not, and
    /// `drain` resamples the difference. The master file was opened at
    /// `outputRate` and cannot be told otherwise halfway through.
    private func followDefaultInputDevice() {
        guard isRunning else { return }

        var device = AudioObjectID(0)
        var address = CA.address(kAudioHardwarePropertyDefaultInputDevice)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size,
                &device) == noErr, device != 0
        else {
            Log.write("mic: the default input changed but resolves to nothing")
            return
        }
        guard device != deviceID else { return }

        let from = deviceID
        let fromRate = deviceRate
        deviceChangedDuringCapture = true
        deviceSwitches += 1

        // Tear the old one down first. `AudioDeviceStop` waits for an
        // in-flight callback to finish, so nothing is reading the ring
        // by the time it is freed.
        if from != 0, let procID {
            AudioDeviceStop(from, procID)
            AudioDeviceDestroyIOProcID(from, procID)
        }
        self.procID = nil
        isRunning = false
        cleanup()

        isFollowingDevice = true
        defer { isFollowingDevice = false }
        do {
            try start()
            Log.write(
                "mic: followed the default input from device \(from) "
                    + "(\(Int(fromRate)) Hz) to \(deviceID) (\(Int(deviceRate)) Hz)"
                    + (rateAdapter == nil
                        ? "" : ", resampling to \(Int(outputRate)) Hz for the file"))
        } catch {
            // The recording continues with a silent microphone rather
            // than stopping: the far end is still being captured, and
            // half a meeting is worth more than none. The session line
            // reports the shortfall.
            Log.write(
                "mic: could not follow the default input from device \(from) — "
                    + "\(error). The microphone is now silent for this recording.")
        }
    }

    /// Notice the default input device moving out from under us.
    ///
    /// The IOProc is bound to one device id, resolved once at `start()`.
    /// When the default input changes — a call ending and a Bluetooth
    /// headset leaving hands-free mode is the ordinary case — the old
    /// device stops and the callback simply stops being called. Nothing
    /// errors. The recording is short and silent about why.
    ///
    /// This does not re-bind mid-recording: tearing down an IOProc and
    /// building another against a different device, at a different rate,
    /// while a file is being written at the first rate, is a larger
    /// change than the evidence yet justifies. What it does is make the
    /// cause visible in the session log, so a short microphone stream
    /// can be attributed rather than guessed at.
    private func watchForDeviceChange() {
        // Removed first. `start()` runs again on every device switch, and
        // a second registration would mean two rebinds per change, each
        // tearing down the IOProc the other just built.
        removeDeviceListener()
        var address = CA.address(kAudioHardwarePropertyDefaultInputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isRunning else { return }
            self.followDefaultInputDevice()
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address,
            DispatchQueue.main, block) == noErr
        {
            deviceListener = block
        }
    }

    private func removeDeviceListener() {
        guard let deviceListener else { return }
        var address = CA.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address,
            DispatchQueue.main, deviceListener)
        self.deviceListener = nil
    }

    func stop() {
        guard isRunning else { return }
        removeDeviceListener()
        // Released here and not in `cleanup()`, which the device-switch
        // path also calls: the output rate has to survive a switch,
        // because the file being written is at that rate.
        outputRate = 0
        rateAdapter = nil
        deviceSwitches = 0
        deviceChangedDuringCapture = false
        if deviceID != 0, let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        isRunning = false
        cleanup()
    }

    private func cleanup() {
        if let ring {
            arb_destroy(ring)
            self.ring = nil
        }
        if let scratch {
            scratch.deallocate()
            self.scratch = nil
            scratchCapacity = 0
        }
        deviceID = 0
    }

    // MARK: - Consumer side

    /// Drain up to `maxFrames` mono frames **at the device's own rate**.
    ///
    /// Deliberately not converted to a common rate here. Converting
    /// during capture put a resampler in the drain loop, where every
    /// call boundary is a chance to lose samples at the seam, and where
    /// any ratio error is indistinguishable from clock drift to the
    /// alignment logic downstream — which then "corrects" it by
    /// inserting silence or discarding audio, twenty-five times a
    /// second. That is what the buzzing was.
    ///
    /// The microphone now gets its own file at its own rate, and the
    /// rates are reconciled once, offline, in `AudioEncoder`.
    /// Frames at `outputRate`, whichever device is underneath.
    ///
    /// The resampling happens here, on an ordinary thread, and never in
    /// the IOProc — allocating on a CoreAudio realtime thread is the
    /// rule this whole design is arranged around. `Resampler` keeps its
    /// own state across calls, so a device switch does not put a seam in
    /// the audio.
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

        // Ask the ring for as much as this many output frames needs.
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

    /// Frames the producer dropped because the consumer was too slow.
    var overruns: UInt64 {
        guard let ring else { return 0 }
        return arb_overruns(ring)
    }

    deinit { stop() }
}
