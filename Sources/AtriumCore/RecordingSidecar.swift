import Foundation

/// What a recording on disk is, and whether anyone has finished with it.
///
/// It answers one question after the fact: **is this still waiting to be
/// dealt with?** The normal path is start → stop → encode → enqueue →
/// delete the sidecar, so a sidecar left behind means the app did not get
/// to finish. It is the marker a crash cannot clean up, which is exactly
/// why it is the right one: anything the app must remember to write on
/// the way down is what it will fail to write in precisely the cases that
/// matter.
///
/// ## Segments
///
/// A meeting is not always one continuous recording. The lid closes, the
/// machine sleeps, the app is quit or killed — and the meeting carries on
/// afterwards. Rather than treat each interruption as the end of one
/// recording and the start of an unrelated one, a session owns a *list*
/// of segments, each a pair of files at their own devices' rates.
/// Recording resumes into a new segment and the encoder concatenates them
/// in order.
///
/// Nothing is recorded while the machine is asleep, so concatenation is
/// the correct join: the gap holds no audio to represent.
public struct RecordingSidecar: Codable, Equatable {

    /// One continuous stretch of recording.
    public struct Segment: Codable, Equatable {
        public var micFile: String
        public var farFile: String
        public var micRate: Double
        public var farRate: Double
        public var startedAt: Date

        public init(
            micFile: String, farFile: String, micRate: Double, farRate: Double,
            startedAt: Date
        ) {
            self.micFile = micFile
            self.farFile = farFile
            self.micRate = micRate
            self.farRate = farRate
            self.startedAt = startedAt
        }

        public var micURL: URL { AppPaths.recordings.appending(path: micFile) }
        public var farURL: URL { AppPaths.recordings.appending(path: farFile) }
    }

    public var bundleID: String
    public var startedAt: Date
    public var isManual: Bool
    public var segments: [Segment]

    /// Set while recording is live or was cut short by the machine going
    /// away, cleared when the meeting ends deliberately.
    ///
    /// This is what separates "resume this" from "finish this". Sleep and
    /// an abrupt exit leave it true; the user pressing stop, or the
    /// session controller deciding the meeting is over, clear it. Without
    /// the distinction the app would either resume recordings that were
    /// deliberately ended, or abandon ones the machine interrupted.
    public var interrupted: Bool

    public init(
        bundleID: String, startedAt: Date, isManual: Bool,
        segments: [Segment] = [], interrupted: Bool = true
    ) {
        self.bundleID = bundleID
        self.startedAt = startedAt
        self.isManual = isManual
        self.segments = segments
        self.interrupted = interrupted
    }

    public init(session: Session, segments: [Segment] = []) {
        self.init(
            bundleID: session.bundleID, startedAt: session.startedAt,
            isManual: session.isManual, segments: segments)
    }

    // MARK: - On disk

    /// One sidecar per session, named for the session rather than for any
    /// one of its segments.
    public static func url(forStem stem: String) -> URL {
        AppPaths.recordings.appending(path: "\(stem).json")
    }

    public func write(stem: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(self).write(
                to: Self.url(forStem: stem), options: .atomic)
        } catch {
            // Not fatal: without it a recording interrupted by a crash is
            // merely not recovered automatically. Losing the recording
            // would be fatal; losing the note about it is not.
            Log.write("could not write the recording sidecar — \(error)")
        }
    }

    public static func read(at url: URL) -> RecordingSidecar? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(RecordingSidecar.self, from: data)
    }

    public static func remove(stem: String) {
        try? FileManager.default.removeItem(at: url(forStem: stem))
    }

    /// Every session nobody finished with, oldest first, with the stem
    /// each was filed under.
    public static func orphans() -> [(stem: String, sidecar: RecordingSidecar)] {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: AppPaths.recordings, includingPropertiesForKeys: nil)
        else { return [] }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let sidecar = read(at: url) else { return nil }
                return (url.deletingPathExtension().lastPathComponent, sidecar)
            }
            .sorted { $0.1.startedAt < $1.1.startedAt }
    }

    /// Delete every file this session produced. Used when a session is
    /// discarded — a mic test that was never a call.
    public func discardFiles(stem: String) {
        for segment in segments {
            try? FileManager.default.removeItem(at: segment.micURL)
            try? FileManager.default.removeItem(at: segment.farURL)
        }
        Self.remove(stem: stem)
    }
}
