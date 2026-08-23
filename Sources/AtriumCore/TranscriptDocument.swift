import Foundation

/// How a saved transcript is written.
public enum TranscriptFormat: String, Codable, CaseIterable {
    case markdown
    case plainText = "text"

    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .plainText: return "txt"
        }
    }

    public var label: String {
        switch self {
        case .markdown: return "Markdown (.md)"
        case .plainText: return "Plain text (.txt)"
        }
    }
}

/// One transcript, as Atrium PA exports it, rendered for a human to read.
///
/// The export is a JSON document — every turn, cleaned and raw, plus the
/// speaker roster. What somebody actually wants in their Downloads folder
/// is the conversation with names against it, so this parses the one and
/// writes the other.
///
/// ## Hedging is not decoration
///
/// atrium-pa is explicit that a `medium` or `low` attribution "may be
/// wrong, so attribute those quotes with a hedge rather than as fact".
/// A transcript that has left this app is quoted, forwarded and
/// remembered, and by then nobody can see the confidence that produced
/// it. So an unconfirmed name is written as unconfirmed, with its
/// percentage, every time it appears.
public struct TranscriptDocument {

    public struct Speaker {
        /// The key turns refer to — `S1`, not the display name.
        public let key: String
        public let label: String
        public let displayName: String?
        public let matchPercent: Int?
        public let band: String?
        public let anchored: Bool

        /// A name nobody committed to. `anchored` settles it, not the
        /// percentage — see `MCPClient.TranscriptSpeaker`.
        public var isProvisional: Bool {
            displayName != nil && !anchored && (band == "low" || band == "medium")
        }

        /// What to print in front of a turn.
        public var attribution: String {
            guard let displayName else { return label }
            guard isProvisional else { return displayName }
            let confidence =
                matchPercent.map { "\($0)% \(band ?? "match")" } ?? (band ?? "a guess")
            return "\(displayName) — unconfirmed, \(confidence)"
        }
    }

    public struct Turn {
        public let speakerKey: String
        public let startMilliseconds: Int
        public let text: String
    }

    public let title: String
    public let startedAt: String?
    public let durationSeconds: Int?
    public let language: String?
    public let summary: String?
    public let speakers: [Speaker]
    public let turns: [Turn]

    public enum ParseError: Error, CustomStringConvertible {
        case notJSON
        case noTurns

        public var description: String {
            switch self {
            case .notJSON: return "the download was not a transcript document"
            case .noTurns: return "the transcript has no turns in it"
            }
        }
    }

    public init(data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ParseError.notJSON }

        let meta = root["transcript"] as? [String: Any] ?? [:]
        title = meta["title"] as? String ?? "Transcript"
        startedAt = meta["starts_at"] as? String
        durationSeconds = meta["duration_seconds"] as? Int
        language = meta["language"] as? String
        summary = root["summary"] as? String

        speakers = (root["speakers"] as? [[String: Any]] ?? []).map { row in
            Speaker(
                key: row["key"] as? String ?? "",
                label: row["label"] as? String ?? "Speaker",
                displayName: row["display_name"] as? String,
                matchPercent: row["match_pct"] as? Int,
                band: row["match_quality"] as? String,
                anchored: row["anchored"] as? Bool ?? false)
        }

        turns = (root["turns"] as? [[String: Any]] ?? []).compactMap { row in
            // `text` is the cleaned rendering where cleanup has run and
            // the original otherwise, decided per turn — which is what
            // somebody reading it wants. `text_raw` stays in the JSON
            // for anyone who needs the verbatim ASR.
            guard let text = row["text"] as? String ?? row["text_raw"] as? String
            else { return nil }
            return Turn(
                speakerKey: row["speaker"] as? String ?? "",
                startMilliseconds: row["start_ms"] as? Int ?? 0,
                text: text)
        }

        guard !turns.isEmpty else { throw ParseError.noTurns }
    }

    // MARK: - Rendering

    public func rendered(as format: TranscriptFormat) -> String {
        switch format {
        case .markdown: return markdown()
        case .plainText: return plainText()
        }
    }

    /// Plain text, for anywhere Markdown's asterisks would be read
    /// literally — a mail body, a note, `grep`.
    ///
    /// Not the Markdown with the punctuation stripped: a timestamp in
    /// front of the name reads better without bold to separate it, and
    /// indenting the speech is what replaces the blank line.
    public func plainText() -> String {
        var out = "\(title)\n"
        out += String(repeating: "=", count: max(title.count, 3)) + "\n"

        var facts: [String] = []
        if let startedAt { facts.append(startedAt) }
        if let durationSeconds { facts.append(Self.duration(durationSeconds)) }
        if let language { facts.append(language) }
        if !facts.isEmpty { out += facts.joined(separator: " · ") + "\n" }

        if let summary, !summary.isEmpty {
            out += "\nSUMMARY\n\n\(summary)\n"
        }

        out += "\nSPEAKERS\n\n"
        for speaker in speakers {
            let name = speaker.displayName ?? "\(speaker.label) — not identified"
            if speaker.isProvisional {
                let confidence =
                    speaker.matchPercent.map { "\($0)% \(speaker.band ?? "")" }
                    ?? (speaker.band ?? "a guess")
                out += "  \(name) — UNCONFIRMED, matched on \(confidence)\n"
            } else {
                out += "  \(name)\n"
            }
        }
        if speakers.contains(where: \.isProvisional) {
            out +=
                "\nNames marked UNCONFIRMED were applied by voice matching and "
                + "nobody\nhas agreed to them. Treat those attributions as a guess.\n"
        }
        out += "\n" + String(repeating: "-", count: 60) + "\n"

        let byKey = Dictionary(uniqueKeysWithValues: speakers.map { ($0.key, $0) })
        var lastAttribution: String?
        for turn in turns {
            let attribution = byKey[turn.speakerKey]?.attribution ?? turn.speakerKey
            if attribution != lastAttribution {
                out += "\n[\(Self.stamp(turn.startMilliseconds))] \(attribution)\n"
                lastAttribution = attribution
            }
            out += "    " + turn.text + "\n"
        }
        return out
    }

    /// Markdown, because it reads as plain text and pastes as structure.
    public func markdown() -> String {
        var out = "# \(title)\n\n"

        var facts: [String] = []
        if let startedAt { facts.append(startedAt) }
        if let durationSeconds { facts.append(Self.duration(durationSeconds)) }
        if let language { facts.append(language) }
        if !facts.isEmpty { out += facts.joined(separator: " · ") + "\n\n" }

        if let summary, !summary.isEmpty {
            out += "## Summary\n\n\(summary)\n\n"
        }

        out += "## Speakers\n\n"
        for speaker in speakers {
            let name = speaker.displayName ?? "\(speaker.label) — not identified"
            if speaker.isProvisional {
                let confidence =
                    speaker.matchPercent.map { "\($0)% \(speaker.band ?? "")" }
                    ?? (speaker.band ?? "a guess")
                out += "- \(name) — **unconfirmed**, matched on \(confidence)\n"
            } else {
                out += "- \(name)\n"
            }
        }
        // Said once, plainly, for anyone who reads only the header.
        if speakers.contains(where: \.isProvisional) {
            out +=
                "\nNames marked *unconfirmed* were applied by voice matching and "
                + "nobody has agreed to them. Treat those attributions as a guess.\n"
        }
        out += "\n---\n\n"

        let byKey = Dictionary(uniqueKeysWithValues: speakers.map { ($0.key, $0) })
        var lastAttribution: String?
        for turn in turns {
            let attribution =
                byKey[turn.speakerKey]?.attribution ?? turn.speakerKey
            // A heading per change of speaker, not per turn: a
            // conversation where somebody says "yes" four times should
            // not be four headings.
            if attribution != lastAttribution {
                out += "\n**\(attribution)** · \(Self.stamp(turn.startMilliseconds))\n\n"
                lastAttribution = attribution
            }
            out += turn.text + "\n"
        }
        return out
    }

    /// `1:23` or `1:02:03` — a position in the recording, not a clock
    /// time, so it starts at zero.
    static func stamp(_ milliseconds: Int) -> String {
        let total = max(milliseconds, 0) / 1000
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    static func duration(_ seconds: Int) -> String {
        seconds >= 3600
            ? "\(seconds / 3600) h \((seconds % 3600) / 60) min"
            : "\(seconds / 60) min \(seconds % 60) s"
    }

    /// A filename that sorts by date and says what it is.
    ///
    /// Sanitised the same way recording stems are: a meeting title comes
    /// from a calendar somebody else controls, and `/` in a filename is
    /// a directory nobody asked for.
    public static func filename(
        title: String, occurredAt: Date, format: TranscriptFormat = .markdown
    ) -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmm"
        stamp.locale = Locale(identifier: "en_US_POSIX")

        let safe = title.map { character -> Character in
            character.isLetter || character.isNumber || character == " "
                || character == "-" ? character : "-"
        }
        let trimmed = String(safe).trimmingCharacters(in: .whitespaces)
        let name = trimmed.isEmpty ? "transcript" : String(trimmed.prefix(60))
        return "\(stamp.string(from: occurredAt)) \(name).\(format.fileExtension)"
    }
}
