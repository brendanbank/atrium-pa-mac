import Foundation

/// Where Atrium PA lives and which OAuth client speaks to it.
///
/// The **client secret is deliberately absent from this struct** — it
/// lives in the Keychain (`Keychain.swift`) and is never written to
/// disk in the clear. This file is user-editable JSON alongside
/// `allowlist.json`, so anything in it is something the user can read in
/// a text editor; a bearer-equivalent credential does not belong there.
///
/// Mint the client in atrium-pa's admin UI
/// (`/api/pa/admin/oauth-clients`) with the `pa.ingest` scope, put the
/// client ID here, and paste the secret into
/// *Set Atrium PA Client Secret…* in the menu.
public struct AtriumConfig: Codable, Equatable {

    /// Base URL of the Atrium PA deployment, no trailing slash.
    ///
    /// **No default.** It was pre-filled with one deployment's address
    /// for a while, which was convenient for exactly one person and
    /// wrong for everybody else — a checkout of this repository should
    /// not arrive pointing at somebody's server. An empty value is what
    /// makes the connection prompt appear on first launch, which is the
    /// right first question to be asked.
    public var baseURL: String

    /// Shown as placeholder text, so the field says what shape of thing
    /// it wants without asserting a destination.
    public static let baseURLExample = "https://atrium-pa.example.com"

    /// OAuth `client_id` for the client-credentials grant.
    public var clientID: String

    /// ISO hint passed to `upload_audio` as `language`. Atrium PA caps
    /// this at 8 characters. `nil` lets the transcriber auto-detect.
    public var language: String?

    /// Days the uploaded `.m4a` is kept after Atrium PA confirms the
    /// transcript is ready. **Negative means keep it for ever**, which
    /// is the default.
    ///
    /// It is the copy worth keeping: 16 kHz mono AAC, about 17 MB an
    /// hour, still playable and still re-uploadable. Atrium PA sweeps
    /// its own audio vault at ~90 days, so after that this is the only
    /// copy of a meeting that exists anywhere.
    public var localRetentionDays: Int

    /// Days the 48 kHz `.caf` masters are kept after the transcript is
    /// ready. `0` — the default — means delete them as soon as the
    /// upload has landed and been transcribed. Negative means keep them.
    ///
    /// They are 41× the size of the `.m4a` (measured: a 36-second
    /// capture is 6.9 MB of masters against 170 KB of AAC — 690 MB an
    /// hour against 17). What they buy is 48 kHz and channel separation,
    /// mic left and far-end right. Nothing uses either today: the server
    /// downmixes to 16 kHz mono because pyannote runs there. They are
    /// kept as an option on per-channel diarization later, which is not
    /// worth 690 MB an hour by default.
    public var masterRetentionDays: Int = 0

    /// Where new recordings are written. `nil` means the default folder
    /// inside Application Support.
    ///
    /// A meeting recorder fills a disk faster than anything else on it,
    /// and the internal one is not always the right disk. Existing
    /// recordings are not moved when this changes — each queue item
    /// carries the folder it was written to. See
    /// `AppPaths.recordingsOverride`.
    public var recordingsDirectory: String?

    /// What a saved transcript is written as. Markdown by default: it
    /// reads as plain text anyway and pastes into anything that
    /// understands structure.
    public var transcriptFormat: TranscriptFormat = .markdown

    /// Master switch. Off means recordings still queue up on disk and
    /// nothing is sent — useful while the OAuth client is being minted.
    public var uploadEnabled: Bool

    /// Whether the connection dialog has been offered unprompted.
    ///
    /// It appears by itself on the first launch that has no credentials,
    /// because an uploader nobody has connected is an uploader that
    /// silently does nothing. It appears exactly once: dismissing it is
    /// an answer, and an app that re-asks every launch teaches you to
    /// dismiss it without reading. After that it lives in the menu.
    public var didPromptForConnection: Bool = false

    public static let defaults = AtriumConfig(
        baseURL: "",
        clientID: "",
        language: nil,
        localRetentionDays: -1,
        uploadEnabled: true,
        didPromptForConnection: false,
        masterRetentionDays: 0)

    /// True once there is enough here to attempt an upload. The secret
    /// is checked separately because it lives in the Keychain.
    public var isConfigured: Bool {
        !baseURL.isEmpty && !clientID.isEmpty
    }

    // MARK: - Derived endpoints

    private var base: URL? {
        URL(string: baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL)
    }

    /// `POST /mcp` — the JSON-RPC surface. Mounted at the root, not
    /// under `/api`.
    public var mcpURL: URL? { base?.appending(path: "mcp") }

    /// Root the OAuth endpoints hang off: `/oauth/register`,
    /// `/oauth/authorize`, `/oauth/token`.
    public var oauthBase: URL? { base }

    /// `POST /oauth/token` — RFC 6749 §4.4 client credentials. Also at
    /// the root, where OAuth clients expect it.
    public var tokenURL: URL? { base?.appending(path: "oauth/token") }

    // MARK: - Persistence

    /// Load the user's config, falling back to defaults.
    ///
    /// Same posture as `Allowlist.load()`: a malformed file falls back
    /// rather than crashing. The app runs unattended, and refusing to
    /// start because of a stray comma would silently cost meetings.
    public static func load() -> AtriumConfig {
        guard let data = try? Data(contentsOf: AppPaths.configFile) else {
            return .defaults
        }
        var decoded: AtriumConfig
        do {
            decoded = try JSONDecoder().decode(AtriumConfig.self, from: data)
        } catch {
            // Falling back is right — the app runs unattended and
            // refusing to start over a stray comma would silently cost
            // meetings — but falling back *quietly* is not. `.defaults`
            // has no `clientID`, so an unreadable config signs the user
            // out with no dialog, no log line and no way to tell that
            // from an expired token.
            Log.write("config: unreadable, falling back to defaults — \(error)")
            return .defaults
        }
        // One-time migration to the two-tier retention split. A file
        // with no `masterRetentionDays` predates it, and its single
        // `localRetentionDays` — 7 by default — deleted the `.m4a` along
        // with the masters. Keeping the small copy and dropping the
        // large one is what the split is for, so an old file that never
        // had the choice gets the new defaults rather than the old
        // behaviour by accident.
        if !data.contains(Data("masterRetentionDays".utf8)) {
            decoded.masterRetentionDays = defaults.masterRetentionDays
            decoded.localRetentionDays = defaults.localRetentionDays
            Log.write(
                "config: migrated to split retention — masters "
                    + "\(decoded.masterRetentionDays)d, uploads "
                    + "\(decoded.localRetentionDays)d")
            try? decoded.save()
        }
        AppPaths.recordingsOverride = decoded.recordingsDirectory.map {
            URL(fileURLWithPath: $0)
        }
        return decoded
    }

    /// Decoding tolerates a file written by an older build.
    ///
    /// The synthesized `Codable` throws on a missing non-optional key,
    /// and `load()` answers a throw with `.defaults` — which has no
    /// `clientID`. So adding one field to this struct would have signed
    /// every existing install out, silently. Fields present in the first
    /// version stay required, so a genuinely broken file still reports
    /// itself. Same reasoning as `QueueItem.init(from:)`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        clientID = try c.decode(String.self, forKey: .clientID)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        localRetentionDays =
            try c.decodeIfPresent(Int.self, forKey: .localRetentionDays)
            ?? Self.defaults.localRetentionDays
        uploadEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .uploadEnabled) ?? true
        didPromptForConnection =
            try c.decodeIfPresent(Bool.self, forKey: .didPromptForConnection) ?? false
        masterRetentionDays =
            try c.decodeIfPresent(Int.self, forKey: .masterRetentionDays)
            ?? Self.defaults.masterRetentionDays
        recordingsDirectory =
            try c.decodeIfPresent(String.self, forKey: .recordingsDirectory)
        transcriptFormat =
            try c.decodeIfPresent(TranscriptFormat.self, forKey: .transcriptFormat)
            ?? .markdown
    }

    public init(
        baseURL: String, clientID: String, language: String?,
        localRetentionDays: Int, uploadEnabled: Bool, didPromptForConnection: Bool,
        masterRetentionDays: Int, recordingsDirectory: String? = nil,
        transcriptFormat: TranscriptFormat = .markdown
    ) {
        self.baseURL = baseURL
        self.clientID = clientID
        self.language = language
        self.localRetentionDays = localRetentionDays
        self.uploadEnabled = uploadEnabled
        self.didPromptForConnection = didPromptForConnection
        self.masterRetentionDays = masterRetentionDays
        self.recordingsDirectory = recordingsDirectory
        self.transcriptFormat = transcriptFormat
    }

    public func save() throws {
        try AppPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: AppPaths.configFile, options: .atomic)
    }

    public static func seedIfMissing() {
        guard !FileManager.default.fileExists(atPath: AppPaths.configFile.path) else {
            return
        }
        try? defaults.save()
    }
}
