import AppKit
import AtriumCore
import Foundation

/// A modal message with one button.
///
/// This was the credentials form once — base URL, client ID, secret —
/// and it is worth saying where that went: everything it collected now
/// lives in `SettingsWindow`'s Atrium PA pane, and the secret is never
/// typed at all, because signing in happens through the browser and the
/// server issues the client. What is left is the "here is what
/// happened" half, which every one of those flows still needs.
///
enum ConnectionSheet {

    static func report(title: String, message: String, success: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = success ? .informational : .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
