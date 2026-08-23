import Foundation

/// What a recording is called, from the only evidence the Mac has.
///
/// The app knows one thing Atrium PA cannot: which application was
/// holding the microphone. Everything else worth putting in a title —
/// the meeting's real name, who was invited — the server already
/// derives, by correlating the recording's `occurred_at` against the
/// calendar (`atrium_pa/correlator`), and it does that better than a
/// window title ever would. So this says what is known and stops.
///
/// Lives in `AtriumCore` rather than beside the menu so it can be
/// tested; the wording ends up in `upload_audio(title:)` and in the
/// user's transcript list, which is not somewhere to guess.
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
