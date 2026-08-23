// Feasibility probe #2: can we tap another process's OUTPUT audio?
//
// This is the far-end / "what the other side said" half of a meeting
// recorder. Without it you only transcribe your own voice.
//
// Uses AudioHardwareCreateProcessTap (macOS 14.2+) — the alternative to
// ScreenCaptureKit, which needs the full Screen Recording grant.
//
// This probe CREATES a tap, reads back its stream format, and destroys
// it. It does not read or write any audio.
//
// Build: swiftc -O tap-probe.swift -o tap-probe -framework CoreAudio
// Run:   ./tap-probe

import CoreAudio
import Foundation

func addr(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

func fourCC(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF),
                 UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
    let s = String(bytes: bytes, encoding: .ascii) ?? ""
    let printable = s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "!" || $0 == "?" }
    return printable && s.count == 4 ? "\(status) '\(s)'" : "\(status)"
}

print("tap-probe — testing AudioHardwareCreateProcessTap on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

// A global stereo tap excluding nothing: the broadest possible request,
// so a failure here is a permission verdict, not a scoping mistake.
let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
desc.name = "atrium-pa feasibility probe"
desc.isPrivate = true          // not visible to other apps
desc.muteBehavior = .unmuted   // do not alter what the user hears

var tapID: AudioObjectID = 0
let status = AudioHardwareCreateProcessTap(desc, &tapID)

guard status == noErr else {
    print("RESULT: tap creation FAILED — status \(fourCC(status))")
    print("        (a permission denial here is the expected TCC gate:")
    print("         NSAudioCaptureUsageDescription / System Audio Recording)")
    exit(1)
}

print("RESULT: tap created OK — AudioObjectID \(tapID)")

// Read back the stream format the tap will deliver.
var fmtAddr = addr(kAudioTapPropertyFormat)
var asbd = AudioStreamBasicDescription()
var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
if AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &size, &asbd) == noErr {
    print("        format: \(asbd.mSampleRate) Hz, "
          + "\(asbd.mChannelsPerFrame) ch, "
          + "\(asbd.mBitsPerChannel)-bit, "
          + "flags 0x\(String(asbd.mFormatFlags, radix: 16))")
} else {
    print("        (could not read tap format)")
}

var uidAddr = addr(kAudioTapPropertyUID)
var uid: CFString? = nil
var uidSize = UInt32(MemoryLayout<CFString?>.size)
let uidStatus = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
    AudioObjectGetPropertyData(tapID, &uidAddr, 0, nil, &uidSize, ptr)
}
if uidStatus == noErr, let uid {
    print("        tap UID: \(uid as String)")
    print("        → this UID is what you feed to an aggregate device to pull PCM")
}

let destroyed = AudioHardwareDestroyProcessTap(tapID)
print("        tap destroyed — status \(fourCC(destroyed))")
print("VERDICT: far-end (system) audio capture is available on this machine.")
