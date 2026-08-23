// Feasibility probe #3 — the definitive one.
//
// Probe #2 proved a tap OBJECT can be created. That is not the same as
// audio actually flowing: under a TCC denial the tap is created happily
// and then delivers pure silence. So this probe builds the full chain —
// tap → private aggregate device → IOProc — plays known audio, and
// measures the RMS of what comes back.
//
//   RMS > 0  → real system audio is being captured
//   RMS == 0 → silently muted (the TCC-denial signature)
//
// Build: swiftc -O tap-capture.swift -o tap-capture -framework CoreAudio
// Run:   ./tap-capture

import CoreAudio
import Foundation

func addr(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func defaultOutputDeviceUID() -> String? {
    var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
    var dev = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == noErr
    else { return nil }

    var uidAddr = addr(kAudioDevicePropertyDeviceUID)
    var uid: CFString? = nil
    var uidSize = UInt32(MemoryLayout<CFString?>.size)
    let st = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
        AudioObjectGetPropertyData(dev, &uidAddr, 0, nil, &uidSize, ptr)
    }
    guard st == noErr, let uid else { return nil }
    return uid as String
}

func tapUID(_ tapID: AudioObjectID) -> String? {
    var a = addr(kAudioTapPropertyUID)
    var uid: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    let st = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
        AudioObjectGetPropertyData(tapID, &a, 0, nil, &size, ptr)
    }
    guard st == noErr, let uid else { return nil }
    return uid as String
}

// Unbuffered stdout: a crash in the render thread must not swallow the
// log lines that tell us how far we got.
setvbuf(stdout, nil, _IONBF, 0)

// When launched via LaunchServices (`open Probe.app`) there is no
// terminal to print to — TCC attributes the request to the bundle only
// if it is launched that way, so results also go to a fixed log file.
let logPath = ProcessInfo.processInfo.environment["PROBE_LOG"]
    ?? "/tmp/atrium-probe.log"
var transcript = ""
func print(_ s: String) {
    Swift.print(s)
    transcript += s + "\n"
    try? transcript.write(toFile: logPath, atomically: true, encoding: .utf8)
}

// MARK: - 1. Create the tap

let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
desc.name = "atrium-pa capture probe"
desc.isPrivate = true
desc.muteBehavior = .unmuted

var tapID: AudioObjectID = 0
guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else {
    print("FAIL: could not create tap"); exit(1)
}
guard let tUID = tapUID(tapID) else {
    print("FAIL: no tap UID"); exit(1)
}
print("1. tap created — UID \(tUID)")

// MARK: - 2. Wrap it in a private aggregate device

guard let outUID = defaultOutputDeviceUID() else {
    print("FAIL: no default output device"); exit(1)
}
print("2. default output device UID: \(outUID)")

let aggUID = "com.atrium-pa.probe.\(UUID().uuidString)"
let aggDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "atrium-pa probe",
    kAudioAggregateDeviceUIDKey: aggUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceMainSubDeviceKey: outUID,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
    kAudioAggregateDeviceTapListKey: [[
        kAudioSubTapUIDKey: tUID,
        kAudioSubTapDriftCompensationKey: true,
    ]],
]

var aggID: AudioObjectID = 0
let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
guard aggStatus == noErr else {
    print("FAIL: aggregate device creation failed — status \(aggStatus)")
    AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}
print("3. private aggregate device created — id \(aggID)")

// MARK: - 3. Install an IOProc and measure what arrives

final class Meter: @unchecked Sendable {
    var peak: Float = 0
    var sumSquares: Double = 0
    var frames: Int = 0
    let lock = NSLock()
}
let meter = Meter()

var procID: AudioDeviceIOProcID?
let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
    &procID, aggID, DispatchQueue(label: "probe.io")
) { _, inInputData, _, _, _ in
    // NB: must use UnsafeMutableAudioBufferListPointer — taking a pointer
    // to `list.mBuffers` via withUnsafePointer lets it escape the closure
    // and dangle, which is an immediate SIGBUS in the render thread.
    let buffers = UnsafeMutableAudioBufferListPointer(
        UnsafeMutablePointer(mutating: inInputData))
    var localPeak: Float = 0
    var localSum: Double = 0
    var localFrames = 0
    for buf in buffers {
        guard let data = buf.mData else { continue }
        let n = Int(buf.mDataByteSize) / MemoryLayout<Float32>.size
        let samples = data.bindMemory(to: Float32.self, capacity: n)
        for i in 0..<n {
            let v = samples[i]
            localPeak = max(localPeak, abs(v))
            localSum += Double(v) * Double(v)
        }
        localFrames += n
    }
    meter.lock.lock()
    meter.peak = max(meter.peak, localPeak)
    meter.sumSquares += localSum
    meter.frames += localFrames
    meter.lock.unlock()
}

guard ioStatus == noErr, let procID else {
    print("FAIL: IOProc creation failed — status \(ioStatus)")
    AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}

guard AudioDeviceStart(aggID, procID) == noErr else {
    print("FAIL: AudioDeviceStart failed")
    exit(1)
}
print("4. IOProc running — generating known audio via `say`...")

// MARK: - 4. Generate audio we control, then measure

let say = Process()
say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
say.arguments = ["-r", "180", "Atrium feasibility probe, capturing system audio now."]
try? say.run()
say.waitUntilExit()
Thread.sleep(forTimeInterval: 1.0)

AudioDeviceStop(aggID, procID)
AudioDeviceDestroyIOProcID(aggID, procID)
AudioHardwareDestroyAggregateDevice(aggID)
AudioHardwareDestroyProcessTap(tapID)

meter.lock.lock()
let frames = meter.frames
let peak = meter.peak
let rms = frames > 0 ? sqrt(meter.sumSquares / Double(frames)) : 0
meter.lock.unlock()

print("5. cleaned up (IOProc, aggregate device, tap all destroyed)")
print("")
print("   frames captured : \(frames)")
print("   peak amplitude  : \(String(format: "%.6f", peak))")
print("   RMS             : \(String(format: "%.6f", rms))")
print("")
if frames == 0 {
    print("VERDICT: no audio delivered at all — IOProc never fired.")
    exit(2)
} else if peak == 0 {
    print("VERDICT: SILENCE. Tap works structurally but is muted —")
    print("         this is the TCC-denial signature. A signed .app bundle")
    print("         with NSAudioCaptureUsageDescription is required.")
    exit(3)
} else {
    print("VERDICT: REAL SYSTEM AUDIO CAPTURED. Full chain works end to end.")
    exit(0)
}
