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
        let channels = max(Int(format.mChannelsPerFrame), 1)
        let isInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        guard let ring = arb_create(Int(ringSeconds * deviceRate), 1) else {
            cleanup()
            throw MicError.ringAllocationFailed
        }
        self.ring = ring

        peakAmplitude = 0
        framesProduced = 0
        callbacks = 0

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
            }
            if localPeak > self.peakAmplitude { self.peakAmplitude = localPeak }
        }

        guard status == noErr, let proc else {
            cleanup()
            throw MicError.ioProcCreationFailed(status)
        }
        procID = proc

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

    func stop() {
        guard isRunning else { return }
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
    func drain(maxFrames: Int) -> [Float] {
        guard let ring, maxFrames > 0 else { return [] }
        var out = [Float](repeating: 0, count: maxFrames)
        let got = out.withUnsafeMutableBufferPointer { buffer -> Int in
            arb_read(ring, buffer.baseAddress!, maxFrames)
        }
        out.removeLast(out.count - got)
        return out
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
