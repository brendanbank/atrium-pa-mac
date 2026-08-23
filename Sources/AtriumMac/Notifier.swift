import AppKit
import AtriumCore
import Foundation
import UserNotifications

/// Standard macOS notifications, for the one thing this app has to say
/// unprompted: your transcript is ready, and here is what it needs from
/// you.
///
/// ## Why this is a class with a delegate and not two lines
///
/// A notification that cannot be *clicked* is a worse version of the
/// menu-bar badge that already exists. The value is entirely in the
/// click taking you to the thing — so this owns the delegate, and the
/// delegate is what turns a tap into "open the naming window for capture
/// 412".
///
/// ## Ad-hoc signing
///
/// `UNUserNotificationCenter` requires a bundled, signed app — which is
/// why `make run` matters here for the same reason it matters for audio
/// capture. Authorisation is per code identity, and ad-hoc signing mints
/// a fresh one on every build, so the permission resets after each
/// `make` during development exactly as the microphone grant does. That
/// is expected here and would not happen with a stable identity.
///
/// The status is logged on every launch, so "no notification appeared"
/// is answered by the log rather than by a guess.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {

    /// Carried on the notification and handed back on click.
    private enum Key {
        static let captureID = "captureID"
        static let transcriptID = "transcriptID"
        static let unnamedVoices = "unnamedVoices"
    }

    private static let readyCategory = "transcript-ready"
    private static let recordingCategory = "still-recording"
    private static let stopAction = "stop-recording"

    /// Latest known authorisation, for the menu.
    ///
    /// Worth surfacing because "denied" is a dead end the app cannot
    /// talk its way out of: macOS prompts once per application, and
    /// after a refusal `requestAuthorization` returns the same refusal
    /// without showing anything. An app that kept quietly not notifying
    /// would look broken; one that says so, and offers the Settings
    /// pane, is merely switched off.
    private(set) var status: UNAuthorizationStatus = .notDetermined

    /// Called on the main thread whenever `status` changes.
    var onStatusChange: (() -> Void)?

    /// Open System Settings at this app's notification row.
    static func openSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        if let url { NSWorkspace.shared.open(url) }
    }

    /// Called on the main thread when the user clicks a notification for
    /// a recording that has voices to name.
    var onOpenNaming: ((Int) -> Void)?
    /// Called with the capture id when they click one that has nothing
    /// to name, so it opens the recording in Atrium PA instead.
    var onOpenTranscript: ((Int) -> Void)?

    /// The user pressed **Stop Recording** on a runaway reminder. The
    /// only way a reminder ever ends a recording.
    var onStopRecording: (() -> Void)?

    private var centre: UNUserNotificationCenter? {
        // Throws rather than returns nil when there is no bundle — a
        // `swift run` binary has no bundle identifier, and asking for
        // the notification centre there traps the process. Guarding on
        // the bundle id keeps the self-test runnable.
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    func start() {
        guard let centre else {
            Log.write("notifications: no bundle identifier, disabled")
            return
        }
        centre.delegate = self
        centre.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.readyCategory, actions: [], intentIdentifiers: [],
                options: []),
            // One button, and it is the only thing on this notification
            // that stops anything. Ignoring it — or dismissing it —
            // leaves the recording running, which is the whole design:
            // a meeting this app failed to record cannot be recovered,
            // and an hour of wasted disk can.
            UNNotificationCategory(
                identifier: Self.recordingCategory,
                actions: [
                    UNNotificationAction(
                        identifier: Self.stopAction, title: "Stop Recording",
                        options: [.destructive])
                ],
                intentIdentifiers: [], options: []),
        ])

        centre.getNotificationSettings { [weak self] settings in
            Log.write(
                "notifications: authorization "
                    + Self.describe(settings.authorizationStatus))
            self?.publish(settings.authorizationStatus)

            // Only ask when nobody has answered. Asking again after a
            // refusal shows nothing and returns the refusal, so the only
            // effect would be a misleading log line every launch.
            guard settings.authorizationStatus == .notDetermined else { return }
            centre.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    Log.write("notifications: request failed — \(error)")
                } else {
                    Log.write("notifications: granted=\(granted)")
                }
                centre.getNotificationSettings { settings in
                    self?.publish(settings.authorizationStatus)
                }
            }
        }
    }

    private func publish(_ status: UNAuthorizationStatus) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.status != status else { return }
            self.status = status
            self.onStatusChange?()
        }
    }

    /// Post the one notification this app sends.
    ///
    /// `unnamedVoices` of zero still notifies: "your transcript is
    /// ready" is the thing the user was actually waiting for, and a
    /// recorder that only ever speaks up to ask for work would be a
    /// chore rather than an assistant.
    func transcriptReady(
        title meetingTitle: String, captureID: Int, transcriptID: Int?,
        unnamedVoices: Int
    ) {
        guard let centre else { return }
        guard status != .denied else {
            // Not an error and not worth retrying. The menu carries the
            // count regardless, which is why a refused notification
            // costs visibility rather than the feature.
            Log.write("notifications: suppressed for capture \(captureID) — denied")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "\(meetingTitle) — transcript ready"
        content.body =
            unnamedVoices == 0
            // Not "everyone was identified" — an empty `unknown_speakers`
            // means nothing is being offered to name, which is not the
            // same claim and is often not true. See
            // `QueueItem.speakerDescription`.
            ? "Ready to read in Atrium PA."
            : unnamedVoices == 1
                ? "1 voice needs a name." : "\(unnamedVoices) voices need a name."
        content.sound = .default
        content.categoryIdentifier = Self.readyCategory
        content.userInfo = [
            Key.captureID: captureID,
            Key.transcriptID: transcriptID as Any,
            Key.unnamedVoices: unnamedVoices,
        ]

        // Identified by capture, so a recording polled twice replaces
        // its own notification rather than stacking a second one.
        let request = UNNotificationRequest(
            identifier: "ready-\(captureID)", content: content, trigger: nil)
        centre.add(request) { error in
            if let error {
                Log.write("notifications: could not post — \(error)")
            } else {
                Log.write(
                    "notifications: posted for capture \(captureID), "
                        + "\(unnamedVoices) unnamed")
            }
        }
    }

    /// "This has been recording for two hours — still going?"
    ///
    /// Posted on a timer while a session runs. It exists because nothing
    /// in this app can tell a long meeting from an app that grabbed the
    /// microphone and never let go: Teams and Zoom both hold the input
    /// device well past the end of a call, and Zoom keeps it running
    /// while muted. The person in the room can tell, so ask them —
    /// without ever acting on silence.
    func stillRecording(title meetingTitle: String, running: TimeInterval) {
        guard let centre, status != .denied else { return }

        let minutes = Int(running / 60)
        let spoken =
            minutes >= 120
            ? "\(minutes / 60) hours"
            : minutes >= 60
                ? "1 hour \(minutes - 60) minutes" : "\(minutes) minutes"

        let content = UNMutableNotificationContent()
        content.title = "Still recording — \(meetingTitle)"
        content.body =
            "Running for \(spoken). It keeps going unless you stop it."
        content.categoryIdentifier = Self.recordingCategory
        // No sound. This repeats every half hour for as long as the
        // recording runs, and a chime that often during a meeting is
        // its own reason to quit the app.
        content.interruptionLevel = .passive

        // One identifier for the whole session, so the reminder replaces
        // itself rather than stacking a column of them by hour three.
        let request = UNNotificationRequest(
            identifier: "still-recording", content: content, trigger: nil)
        centre.add(request) { error in
            if let error {
                Log.write("notifications: reminder failed — \(error)")
            } else {
                Log.write("notifications: still-recording reminder at \(minutes)m")
            }
        }
    }

    /// Take the reminder down when the recording stops, so a stale
    /// "still recording" cannot sit in Notification Centre saying
    /// something that is no longer true.
    func clearRecordingReminder() {
        centre?.removeDeliveredNotifications(withIdentifiers: ["still-recording"])
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show it even when this app is frontmost. A menu-bar app is never
    /// really "in front", and suppressing the alert because a panel
    /// happens to be on screen would lose it entirely.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let captureID = info[Key.captureID] as? Int
        let unnamed = info[Key.unnamedVoices] as? Int ?? 0

        if response.actionIdentifier == Self.stopAction {
            DispatchQueue.main.async { [weak self] in
                Log.write("notifications: stop pressed on the recording reminder")
                self?.onStopRecording?()
                completionHandler()
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            // Naming only when there was something to name. Clicking a
            // "ready to read" notification used to open the naming
            // window on an empty list, which showed a window and closed
            // it in the same frame.
            if let captureID, unnamed > 0 {
                self?.onOpenNaming?(captureID)
            } else if let captureID {
                self?.onOpenTranscript?(captureID)
            }
            completionHandler()
        }
    }

    private static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }
}
