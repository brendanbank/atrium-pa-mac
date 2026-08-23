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

    public static let defaults = Allowlist(prefixes: [
        "com.microsoft.teams2",   // Teams (+ .helper, .modulehost)
        "com.google.Chrome",      // Meet in Chrome (+ .helper)
        "us.zoom.xos",            // Zoom
        "net.whatsapp.WhatsApp",  // WhatsApp (+ .ServiceExtension)
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
