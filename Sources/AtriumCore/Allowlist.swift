import Foundation

/// Which processes may start a recording.
///
/// **Prefix matching is not a convenience, it is a requirement.** Every
/// meeting app grabs the microphone from a helper process, not from its
/// main bundle. Measured on macOS 26.5:
///
/// | app | bundle ID that actually holds the mic |
/// |---|---|
/// | Microsoft Teams | `com.microsoft.teams2.helper` |
/// | Google Meet (Chrome) | `com.google.Chrome.helper` |
/// | Slack | `com.tinyspeck.slackmacgap.helper` |
/// | WhatsApp | `net.whatsapp.WhatsApp` (native, no helper) |
///
/// An exact-match allowlist on the main bundle IDs would match nothing
/// at all. Prefix matching also survives vendors renaming their helpers,
/// which they do between releases.
public struct Allowlist: Codable, Equatable {

    /// Bundle-ID prefixes that may trigger a recording.
    public var prefixes: [String]

    public init(prefixes: [String]) {
        self.prefixes = prefixes
    }

    /// ## FaceTime needs two entries, and the useful one is a daemon
    ///
    /// `com.apple.FaceTime` is the app you quit to end a call, but the
    /// microphone is held by **`com.apple.avconferenced`** — the AV
    /// conference daemon every Apple call goes through. Listing only the
    /// app matches nothing, exactly as an exact-match list on
    /// `com.microsoft.teams2` would.
    ///
    /// `avconferenced` is shared rather than per-app, so it can hold the
    /// input device for things that are not a FaceTime call. That is the
    /// same shape as `com.google.Chrome.helper`, and it is handled the
    /// same way rather than by trying to be cleverer: record
    /// speculatively and let `SessionPolicy.farEndConfirmationWindow`
    /// throw the session away if no far-end audio arrives. A call has
    /// two-way audio; a daemon idling does not.
    ///
    /// Deliberately **not** included: `com.apple.TelephonyUtilities`
    /// (`callservicesd`), which carries iPhone calls relayed to the Mac.
    /// That is a different feature rather than an oversight — add it if
    /// you want phone calls recorded too.
    public static let defaults = Allowlist(prefixes: [
        "com.microsoft.teams2",   // Teams (+ .helper, .modulehost)
        // The browsers, all of them. A meeting in a browser is a
        // meeting, and which browser somebody uses is not a decision
        // this app should be making for them — Chrome being here while
        // Safari was not is an accident of which one got tested first.
        //
        // They are the ambiguous case by design: a browser holds the
        // microphone identically for a call, a dictation box and a
        // voice note. That is what
        // `SessionPolicy.farEndConfirmationWindow` is for — record
        // speculatively, discard within 60 s if no far end appears. The
        // cost of a browser being here is a discarded file; the cost of
        // it being absent is a meeting nobody recorded.
        "com.google.Chrome",      // Meet in Chrome (+ .helper)
        "com.apple.Safari",       // Safari
        "com.microsoft.edgemac",  // Edge
        "company.thebrowser",     // Arc
        "us.zoom.xos",            // Zoom
        "net.whatsapp.WhatsApp",  // WhatsApp (+ .ServiceExtension)
        "com.apple.FaceTime",     // FaceTime, though see avconferenced
        "com.apple.avconferenced",  // ...which is what actually holds it
        "com.tinyspeck.slackmacgap",  // Slack huddles (+ .helper)
    ])

    public func matches(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return prefixes.contains { !$0.isEmpty && bundleID.hasPrefix($0) }
    }

    // MARK: - Persistence

    public static var configURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "AtriumMac/allowlist.json")
    }

    /// Load the user's list, falling back to defaults.
    ///
    /// A malformed file falls back rather than crashing: the app runs
    /// unattended, and refusing to start because a config file has a
    /// stray comma would silently cost meetings.
    public static func load() -> Allowlist {
        guard
            let data = try? Data(contentsOf: configURL),
            let decoded = try? JSONDecoder().decode(Allowlist.self, from: data)
        else { return .defaults }
        return decoded
    }

    public func save() throws {
        let url = Self.configURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Write defaults to disk if no config exists yet, so there is
    /// something for the user to edit.
    public static func seedIfMissing() {
        guard !FileManager.default.fileExists(atPath: configURL.path) else { return }
        try? defaults.save()
    }
}
