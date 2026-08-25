import Foundation

/// What a recording is called **on this Mac**. Never sent upstream.
///
/// The app knows one thing Atrium PA cannot: which application was
/// holding the microphone. That is genuinely useful in this app's own
/// recordings list, where "Teams meeting" next to a timestamp is how
/// somebody finds the call they are looking for.
///
/// ## It used to be sent, and that was wrong
///
/// On the server, `title` means *what this recording is about*: it is
/// the primary label in the captures list and carries a scoring bonus
/// over the body in keyword search. A label describing the **source**
/// answers a different question, and answering the wrong question in
/// that field is worse than leaving it empty — every Teams recording
/// becomes identical in the list, and every search for "teams" or
/// "meeting" matches all of them. Measured: 33 of the last 43 uploads.
///
/// So `upload_audio` is now sent no title at all unless a person
/// supplied one, and the server derives one from the transcript —
/// which describes the conversation rather than the app that captured
/// it. Nothing is lost by omitting it: the capturing process is already
/// in the filename (`20260824-090544-modulehost.m4a`), which the server
/// keeps.
///
/// See `QueueItem.titleIsHumanSupplied`, which is what decides.
public enum MeetingTitle {

    /// Chrome is deliberately "Browser call" and not "Google Meet".
    ///
    /// `com.google.Chrome.helper` grabs the microphone identically for
    /// Meet, for Teams-in-a-browser, for Whereby, for a voice note or a
    /// dictation box — that indistinguishability is the entire reason
    /// `SessionPolicy.farEndConfirmationWindow` exists. Naming it
    /// "Google Meet" would be right most of the time and quietly wrong
    /// the rest, in a field somebody reads months later to work out what
    /// a recording was.
    private static let byPrefix: [(prefix: String, title: String)] = [
        ("com.microsoft.teams2", "Teams meeting"),
        ("com.google.Chrome", "Browser call"),
        ("com.apple.Safari", "Browser call"),
        ("com.microsoft.edgemac", "Browser call"),
        ("company.thebrowser", "Browser call"),
        ("us.zoom.xos", "Zoom call"),
        ("net.whatsapp.WhatsApp", "WhatsApp call"),
        ("com.tinyspeck.slackmacgap", "Slack call"),
    ]

    /// A recording the user started by hand is not a meeting and must
    /// not claim to be one — it is as likely to be a conversation in the
    /// room or a call on a phone on the desk.
    public static let manual = "Recording"

    public static func title(bundleID: String, isManual: Bool) -> String {
        if isManual { return manual }
        for entry in byPrefix where bundleID.hasPrefix(entry.prefix) {
            return entry.title
        }
        // An app somebody added to the allowlist themselves. The bundle
        // id is ugly but true, and truer than "Meeting".
        return "\(bundleID) call"
    }

    /// Short form for the menu bar and the panel — no "meeting" or
    /// "call" suffix, because the menu already says "Recording — ".
    public static func shortName(bundleID: String) -> String {
        for entry in byPrefix where bundleID.hasPrefix(entry.prefix) {
            return entry.title
                .replacingOccurrences(of: " meeting", with: "")
                .replacingOccurrences(of: " call", with: "")
        }
        return bundleID
    }
}
