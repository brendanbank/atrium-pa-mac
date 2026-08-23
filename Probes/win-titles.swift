import CoreGraphics
import Foundation
// Can we read window TITLES without Screen Recording permission?
// If yes, a Chrome tab like "Meet - abc-defg-hij" is addressable.
let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    print("FAIL: no window list"); exit(1)
}
var withTitle = 0, total = 0
for w in list {
    guard let owner = w[kCGWindowOwnerName as String] as? String else { continue }
    total += 1
    let name = w[kCGWindowName as String] as? String
    if let name, !name.isEmpty { withTitle += 1 }
    if ["Google Chrome","Safari","Microsoft Teams","zoom.us","WhatsApp"].contains(owner) {
        print("  \(owner): title=\(name.map { "\"\($0)\"" } ?? "<nil/redacted>")")
    }
}
print("windows: \(total), with readable title: \(withTitle)")
print(withTitle == 0 ? "VERDICT: titles REDACTED — needs Screen Recording permission"
                     : "VERDICT: titles readable")
