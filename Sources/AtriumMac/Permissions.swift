import AVFoundation
import AppKit
import AtriumCore
import UserNotifications

/// What this app needs before it can do its job, and whether it has it.
///
/// The point is to answer "why did nothing record?" *before* the meeting
/// rather than after it. Every grant here has already failed silently at
/// least once during development, and a silent failure in a recorder is
/// indistinguishable from the recorder not being there.
enum Permissions {

    enum State {
        case granted
        case missing(why: String, settings: URL?)
        /// Cannot be established without trying — see `audioCapture`.
        case unknown(String)

        var isProblem: Bool {
            if case .missing = self { return true }
            return false
        }

        /// One word, for the log. The full reason belongs on screen, not
        /// in a line somebody is scanning for a state change.
        var summary: String {
            switch self {
            case .granted: return "granted"
            case .missing: return "refused"
            case .unknown: return "unknown"
            }
        }
    }

    struct Check {
        let name: String
        let state: State
        /// What stops working without it, in the user's terms.
        let consequence: String
    }

    // MARK: - The individual grants

    static var microphone: State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined:
            return .unknown("not asked yet — the app asks on launch")
        case .denied, .restricted:
            return .missing(
                why: "refused in System Settings",
                settings: URL(
                    string: "x-apple.systempreferences:com.apple.preference.security"
                        + "?Privacy_Microphone"))
        @unknown default: return .unknown("unrecognised status")
        }
    }

    static func notifications(_ status: UNAuthorizationStatus) -> State {
        switch status {
        case .authorized, .provisional, .ephemeral: return .granted
        case .notDetermined:
            return .unknown("not asked yet — the app asks on launch")
        case .denied:
            return .missing(
                why: "refused — you will not be told when a transcript is ready",
                settings: URL(
                    string: "x-apple.systempreferences:"
                        + "com.apple.Notifications-Settings.extension"))
        @unknown default: return .unknown("unrecognised status")
        }
    }

    /// The audio-capture grant, which **cannot be queried**.
    ///
    /// There is no API that answers "may I create a process tap?". The
    /// only way to find out is to create one — and a tap created without
    /// the grant does not error, it delivers a perfectly-timed stream of
    /// zeroes. So this reports honestly that it is unknown until a
    /// recording has been made, rather than inventing a green tick.
    ///
    /// What catches it in practice is the recording itself: the panel
    /// turns its bars red after two seconds of silence on both streams,
    /// and every session logs its peak amplitude.
    static var audioCapture: State {
        .unknown(
            "macOS offers no way to ask. It is settled the first time a "
                + "recording runs — watch the panel, which turns red if nothing "
                + "is arriving.")
    }

    /// Everything, in the order it matters.
    static func all(notificationStatus: UNAuthorizationStatus) -> [Check] {
        [
            Check(
                name: "Microphone", state: microphone,
                consequence: "Without it your own voice is not recorded."),
            Check(
                name: "System audio", state: audioCapture,
                consequence:
                    "Without it the other participants are not recorded — and "
                    + "the failure is silent, which is why the panel shows a "
                    + "live meter."),
            Check(
                name: "Notifications", state: notifications(notificationStatus),
                consequence:
                    "Without it nothing tells you a transcript is ready or that "
                    + "a voice needs naming. The menu still carries the count."),
        ]
    }

    /// Problems worth interrupting somebody about on launch.
    static func problems(notificationStatus: UNAuthorizationStatus) -> [Check] {
        all(notificationStatus: notificationStatus).filter { $0.state.isProblem }
    }
}
