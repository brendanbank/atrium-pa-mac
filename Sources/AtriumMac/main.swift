import AppKit
import Foundation

/// Menu-bar entry point.
///
/// The status item is still the primary control, but the app runs
/// `.regular` — with a Dock icon, an App menu and ⌘Q — because a
/// menu-bar-only app cannot be brought to the front. `LSUIElement` is
/// correspondingly `false` in the bundle's Info.plist.
///
/// This is deliberately a plain `main.swift` rather than `@main`: the two
/// cannot coexist in a SwiftPM executable target.

setvbuf(stdout, nil, _IONBF, 0)

// NSApplication.shared FIRST. Constructing the delegate before this ran
// meant its stored properties were built with no NSApp in existence,
// which is an AppKit ordering violation — and `RecordingPanel` is one of
// those properties. An NSWindow created before the application object
// exists is not reliably usable afterwards: `NSScreen.main` is nil, so
// the panel never got positioned, and it did not show. The panel is now
// also built later, in applicationDidFinishLaunching; this line is the
// belt to that braces.
let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.regular)
// A SwiftPM executable has no nib, so nothing supplies the App, Edit and
// Window menus — including ⌘Q, and ⌘V in a text field.
MainMenu.install(appName: "Atrium PA Capture")
app.delegate = delegate
app.run()
