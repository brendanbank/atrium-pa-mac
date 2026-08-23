import Foundation
import ServiceManagement

/// "Start Atrium PA Capture when I log in."
///
/// `SMAppService.mainApp` registers the bundle itself, so there is no
/// helper target, no launchd plist to write, and nothing left behind in
/// `~/Library/LaunchAgents` if the app is deleted — macOS tracks the
/// registration against the bundle and drops it when the bundle goes.
///
/// It is worth having for this app in particular: a recorder that is not
/// running when the meeting starts has missed the meeting, and nobody
/// remembers to launch it first.
public enum LoginItem {

    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// What macOS thinks, in words — including the case that has no
    /// button: an administrator or a profile can forbid login items, and
    /// an app that silently failed to register would be worse than one
    /// that says so.
    public static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .notRegistered: return "not registered"
        case .notFound: return "not found"
        case .requiresApproval: return "needs approval in System Settings"
        @unknown default: return "unknown"
        }
    }

    @discardableResult
    public static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.write("login item: \(enabled ? "registered" : "unregistered")")
            return true
        } catch {
            // The common failure is `requiresApproval`: macOS accepts the
            // registration but parks it behind a switch in System
            // Settings › General › Login Items. Saying which is the
            // difference between "it did not work" and "go and approve
            // it".
            Log.write(
                "login item: could not \(enabled ? "register" : "unregister") — "
                    + "\(error) (status now \(statusDescription))")
            return false
        }
    }
}
