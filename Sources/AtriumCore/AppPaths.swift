import Foundation

/// Every on-disk location the app owns, in one place.
///
/// All of it lives under Application Support rather than a cache
/// directory: a queued recording that has not reached Atrium PA yet is
/// not reproducible, so it must not be something the OS is entitled to
/// delete under disk pressure.
public enum AppPaths {

    /// Redirects every path below to somewhere else. Set by the
    /// self-test runner so a test can exercise the real queue — the
    /// same writes, the same atomic renames, the same reload path —
    /// without touching the recordings of an actual meeting.
    ///
    /// Nothing in the app ever sets this.
    public static var rootOverride: URL?

    public static var supportDirectory: URL {
        if let rootOverride { return rootOverride }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AtriumMac")
    }

    /// Where *new* recordings are written.
    ///
    /// Settable, because a meeting recorder fills a disk faster than
    /// anything else on it and the internal one is not always the right
    /// disk. Set from `AtriumConfig.recordingsDirectory` at launch.
    ///
    /// **Changing this does not move what is already on disk.** Every
    /// `QueueItem` carries the absolute directory it was written to, so
    /// existing recordings stay reachable from wherever they are; only
    /// new ones land here. Resolving old items against the new folder
    /// would have made a queue full of files that cannot be found —
    /// which looks exactly like data loss and is unrecoverable once the
    /// queue entries are gone.
    public static var recordingsOverride: URL?

    public static var recordings: URL {
        // Never while a test has redirected the tree: `rootOverride`
        // exists so a test cannot touch a real meeting, and an override
        // read from the user's config would defeat that.
        if rootOverride == nil, let recordingsOverride { return recordingsOverride }
        return supportDirectory.appending(path: "Recordings")
    }

    /// Where recordings would go with no override — what the settings
    /// window shows as "Default".
    public static var defaultRecordings: URL {
        supportDirectory.appending(path: "Recordings")
    }

    /// One JSON file per upload, which is what makes the queue durable
    /// across a reboot. See `UploadQueue`.
    public static var queue: URL { supportDirectory.appending(path: "Queue") }

    public static var configFile: URL { supportDirectory.appending(path: "config.json") }

    /// Create the directory tree. Called on launch; cheap and idempotent.
    public static func ensureDirectories() throws {
        for url in [supportDirectory, recordings, queue] {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true)
        }
    }

    /// `20260821-140311-teams` — sorts chronologically in Finder and
    /// still says at a glance which app triggered it.
    public static func stem(for session: Session) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = .current
        let app = session.isManual
            ? "manual"
            : session.bundleID.split(separator: ".").last.map(String.init) ?? "recording"
        return "\(formatter.string(from: session.startedAt))-\(sanitise(app))"
    }

    /// Keep file names to something a shell, a URL and Finder all agree
    /// on. A manual session's label is free text, and a bundle ID from a
    /// vendor is not a promise about characters.
    private static func sanitise(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(
            text.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "recording" : String(trimmed.prefix(40))
    }
}
