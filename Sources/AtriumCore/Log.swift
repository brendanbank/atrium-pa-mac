import Foundation

/// Append-only log at `~/Library/Logs/AtriumMac.log`.
///
/// `NSLog` is not enough for this app. It writes to stderr, and an app
/// launched through LaunchServices has no stderr to write to — which is
/// the only way this app is ever launched, because a bare binary cannot
/// hold the audio-capture grant. The unified log swallows it too unless
/// the process was started under a debugger. So the one launch context
/// that works is also the one with no diagnostics, which is how a panel
/// that never appeared cost an afternoon.
///
/// It records what an unattended recorder is asked about afterwards:
/// whether a session started, whether audio was actually flowing, and
/// why an upload failed at 3am.
public enum Log {

    /// Where the self-test sends its output, for the whole run.
    ///
    /// Following `AppPaths.rootOverride` alone was not enough, and the
    /// gap cost an afternoon. That override is scoped to the tests that
    /// ask for a temporary tree; every other test left it `nil`, so
    /// their output went to the real file. The result was 130 lines
    /// reading `no far-end audio within 0s` sitting among genuine
    /// sessions — fixtures, from a suite that tunes the window to 0.15 s
    /// to stay fast, and `Int(0.15)` is `0`. A healthy app was diagnosed
    /// as broken from its own log.
    ///
    /// So the log's destination is now decided separately from where
    /// config lives. They are different questions: a live test needs the
    /// real credentials *and* must not write to the real log, which one
    /// switch cannot express.
    public static var fileURLOverride: URL?

    public static var fileURL: URL {
        if let fileURLOverride { return fileURLOverride }
        // Also follows `AppPaths.rootOverride`, so a test that redirects
        // the whole tree gets a log inside it.
        if let root = AppPaths.rootOverride {
            return root.appending(path: "AtriumMac.log")
        }
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/AtriumMac.log")
    }

    /// Trimmed to this on launch. Big enough to hold a few days of
    /// meetings, small enough that nobody has to think about it.
    private static let maxBytes = 512 * 1024

    private static let queue = DispatchQueue(label: "com.atrium-mac.log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// Append one line, **synchronously**.
    ///
    /// It was asynchronous once. That lost every line written from
    /// `applicationWillTerminate` — the block was still queued when the
    /// process exited — which is precisely the moment a log is for. A
    /// diagnostic that works except during shutdown and crashes is not a
    /// diagnostic. The cost is a file append per event, and events here
    /// are session starts and upload failures, not audio frames.
    public static func write(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        // Also to stderr: `swift run` and the probes do have one.
        FileHandle.standardError.write(Data(line.utf8))
        guard let data = line.data(using: .utf8) else { return }
        queue.sync {
            let url = fileURL
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Drop the front of the file if it has grown past `maxBytes`.
    /// Called once on launch — a rotation scheme with generations would
    /// be more than this needs.
    public static func trim() {
        queue.sync {
            let url = fileURL
            guard
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[
                    .size] as? Int, size > maxBytes,
                let data = try? Data(contentsOf: url)
            else { return }
            let kept = data.suffix(maxBytes / 2)
            try? Data("… earlier entries trimmed …\n".utf8 + kept).write(
                to: url, options: .atomic)
        }
    }

    /// Every line mentioning any of `keys`, oldest first.
    ///
    /// What one recording did, pulled out of a log that interleaves all
    /// of them. The keys are the handles a recording is known by in
    /// different places — its file stem while it is being captured and
    /// encoded, its capture id once Atrium PA has one, its transcript id
    /// after that — because no single one of them appears on every line
    /// of its own story.
    public static func entries(matching keys: [String], limit: Int = 500) -> [String] {
        let wanted = keys.filter { !$0.isEmpty }
        guard !wanted.isEmpty,
            let text = try? String(contentsOf: fileURL, encoding: .utf8)
        else { return [] }

        let matched = text.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { line in wanted.contains { line.contains($0) } }
            .map(String.init)
        return matched.count > limit ? Array(matched.suffix(limit)) : matched
    }
}
