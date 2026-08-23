// Feasibility prototype: detect when any process acquires / releases the mic.
//
// Uses only public CoreAudio process-object APIs (macOS 14.2+):
//   kAudioHardwarePropertyProcessObjectList  — enumerate audio processes
//   kAudioProcessPropertyPID / BundleID      — identify them
//   kAudioProcessPropertyIsRunningInput      — the acquire/release edge
//
// Observing this requires NO TCC permission. Only capturing does.
//
// Build: swiftc -O mic-detect.swift -o mic-detect -framework CoreAudio
// Run:   ./mic-detect [seconds]

import CoreAudio
import Foundation

// MARK: - CoreAudio property helpers

func addr(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
}

func processObjectIDs() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard
        AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr,
        size > 0
    else { return [] }

    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr
    else { return [] }
    return ids
}

func uint32Property(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var a = addr(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func pidProperty(_ obj: AudioObjectID) -> pid_t? {
    var a = addr(kAudioProcessPropertyPID)
    var value: pid_t = 0
    var size = UInt32(MemoryLayout<pid_t>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func bundleIDProperty(_ obj: AudioObjectID) -> String? {
    var a = addr(kAudioProcessPropertyBundleID)
    var cf: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &cf) { ptr -> OSStatus in
        AudioObjectGetPropertyData(obj, &a, 0, nil, &size, ptr)
    }
    guard status == noErr, let cf else { return nil }
    let s = cf as String
    return s.isEmpty ? nil : s
}

func isRunningInput(_ obj: AudioObjectID) -> Bool {
    (uint32Property(obj, kAudioProcessPropertyIsRunningInput) ?? 0) != 0
}

// MARK: - Process naming

/// Bundle ID is often absent for helper processes; fall back to the
/// executable name so the log is still readable.
func processName(pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "pid \(pid)" }
    return (String(cString: buf) as NSString).lastPathComponent
}

func label(_ obj: AudioObjectID) -> String {
    let pid = pidProperty(obj) ?? -1
    let name = pid > 0 ? processName(pid: pid) : "?"
    if let bundle = bundleIDProperty(obj) {
        return "\(name) [\(bundle)] pid=\(pid)"
    }
    return "\(name) pid=\(pid)"
}

// MARK: - Monitor

let stamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func emit(_ line: String) {
    print("[\(stamp.string(from: Date()))] \(line)")
    fflush(stdout)
}

final class Monitor {
    private let queue = DispatchQueue(label: "mic-detect")
    /// Processes we've attached an IsRunningInput listener to.
    private var watched: [AudioObjectID: Bool] = [:]
    private var blocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]

    func start() {
        queue.sync { rescan(announceExisting: true) }
        watchProcessList()
    }

    /// The process list churns constantly — every app that touches audio
    /// gets an object. Attach an input listener to each new one.
    private func rescan(announceExisting: Bool) {
        let ids = Set(processObjectIDs())

        for obj in ids where blocks[obj] == nil {
            let running = isRunningInput(obj)
            watched[obj] = running
            if running && announceExisting {
                emit("ALREADY CAPTURING  \(label(obj))")
            } else if running {
                emit("MIC ACQUIRED       \(label(obj))")
            }
            attachInputListener(obj)
        }

        // Drop listeners for processes that went away.
        for (obj, block) in blocks where !ids.contains(obj) {
            var a = addr(kAudioProcessPropertyIsRunningInput)
            AudioObjectRemovePropertyListenerBlock(obj, &a, queue, block)
            if watched[obj] == true {
                emit("MIC RELEASED       (process exited) pid-object \(obj)")
            }
            blocks[obj] = nil
            watched[obj] = nil
        }
    }

    private func attachInputListener(_ obj: AudioObjectID) {
        var a = addr(kAudioProcessPropertyIsRunningInput)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let now = isRunningInput(obj)
            let before = self.watched[obj] ?? false
            guard now != before else { return }
            self.watched[obj] = now
            emit(now ? "MIC ACQUIRED       \(label(obj))"
                     : "MIC RELEASED       \(label(obj))")
        }
        if AudioObjectAddPropertyListenerBlock(obj, &a, queue, block) == noErr {
            blocks[obj] = block
        }
    }

    private func watchProcessList() {
        var a = addr(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rescan(announceExisting: false)
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &a, queue, block)
        if status != noErr {
            emit("WARNING: could not watch process list (status \(status))")
        }
    }

    func snapshot() {
        queue.sync {
            let ids = processObjectIDs()
            emit("--- \(ids.count) audio process objects; "
                 + "\(ids.filter { isRunningInput($0) }.count) currently capturing input ---")
            for obj in ids where isRunningInput(obj) {
                emit("    capturing: \(label(obj))")
            }
        }
    }
}

// MARK: - Main

let duration = CommandLine.arguments.count > 1
    ? Double(CommandLine.arguments[1]) ?? 30
    : 30

emit("mic-detect starting — watching for \(Int(duration))s")
emit("no TCC permission requested; this only observes CoreAudio state")

let monitor = Monitor()
monitor.start()
monitor.snapshot()
emit("--- listening for acquire/release events ---")

DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
    emit("--- done ---")
    monitor.snapshot()
    exit(0)
}

dispatchMain()
