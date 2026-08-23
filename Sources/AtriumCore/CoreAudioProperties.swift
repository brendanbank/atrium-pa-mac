import CoreAudio
import Darwin
import Foundation

/// Thin typed wrappers over the CoreAudio property API.
///
/// Every one of these is a `AudioObjectGetPropertyData` call with the
/// address boilerplate factored out. Kept in one place because the
/// out-parameter dance is easy to get subtly wrong — see `bundleID`.
public enum CA {

    public static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// All audio process objects known to CoreAudio.
    ///
    /// Note this is *every* process that has touched audio, not just the
    /// ones capturing — 47 of them on a normal desktop. Filter by
    /// `isRunningInput`.
    public static func processObjectIDs() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
            size > 0
        else { return [] }

        var ids = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    public static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector)
        -> UInt32?
    {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    public static func pid(_ object: AudioObjectID) -> pid_t? {
        var addr = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    /// Bundle ID of an audio process, if it has one.
    ///
    /// Many audio processes have none (system daemons, some helpers), so
    /// a nil here is normal and must not be treated as an error.
    public static func bundleID(_ object: AudioObjectID) -> String? {
        var addr = address(kAudioProcessPropertyBundleID)
        var cf: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cf) { ptr -> OSStatus in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let cf else { return nil }
        let value = cf as String
        return value.isEmpty ? nil : value
    }

    public static func isRunningInput(_ object: AudioObjectID) -> Bool {
        (uint32(object, kAudioProcessPropertyIsRunningInput) ?? 0) != 0
    }

    public static func tapUID(_ tap: AudioObjectID) -> String? {
        var addr = address(kAudioTapPropertyUID)
        var cf: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cf) { ptr -> OSStatus in
            AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let cf else { return nil }
        return cf as String
    }

    public static func defaultOutputDeviceUID() -> String? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr
        else { return nil }

        var uidAddr = address(kAudioDevicePropertyDeviceUID)
        var cf: CFString?
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cf) { ptr -> OSStatus in
            AudioObjectGetPropertyData(device, &uidAddr, 0, nil, &uidSize, ptr)
        }
        guard status == noErr, let cf else { return nil }
        return cf as String
    }

    /// Executable name for a pid. Used only for logging — the allowlist
    /// matches on bundle ID, never on this.
    public static func executableName(pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "pid \(pid)" }
        return (String(cString: buf) as NSString).lastPathComponent
    }
}
