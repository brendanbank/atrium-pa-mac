import CoreAudio
import Foundation
func addr(_ s: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}
var a = addr(kAudioHardwarePropertyProcessObjectList)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
var ids = [AudioObjectID](repeating: 0, count: Int(size)/MemoryLayout<AudioObjectID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
for obj in ids {
    var pa = addr(kAudioProcessPropertyPID); var pid: pid_t = 0
    var ps = UInt32(MemoryLayout<pid_t>.size)
    AudioObjectGetPropertyData(obj, &pa, 0, nil, &ps, &pid)
    var ba = addr(kAudioProcessPropertyBundleID); var cf: CFString? = nil
    var bs = UInt32(MemoryLayout<CFString?>.size)
    let st = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(obj, &ba, 0, nil, &bs, $0) }
    let bundle = (st == noErr && cf != nil) ? (cf! as String) : "<none>"
    var buf = [CChar](repeating: 0, count: 4096)
    let name = proc_pidpath(pid, &buf, UInt32(buf.count)) > 0
        ? (String(cString: buf) as NSString).lastPathComponent : "?"
    print("pid=\(pid)  bundle=\(bundle)   exe=\(name)")
}
