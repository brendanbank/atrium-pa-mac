import Foundation

/// Narrowing the recordings list to the ones somebody is looking for.
///
/// `localRetentionDays` defaults to keeping the uploaded `.m4a` for
/// ever, which is the right call — after Atrium PA sweeps its own vault
/// at ~90 days it is the only copy of a meeting anywhere. The
/// consequence is a list that only grows: a year of daily meetings is
/// around 500 rows.
///
/// ## What is actually slow, and what is not
///
/// Measured rather than assumed. A queue item is ~1250 bytes on disk, so
/// 500 of them is 0.6 MB read **once** at `start()` — `loadFromDisk` is
/// not on a timer, and the window's five-second refresh reads
/// `allItems()` from memory and sorts it. Neither needs paging.
///
/// What does not scale is the person. Finding the meeting that failed,
/// or the four that still want a name, means reading every row. So this
/// is a search problem rather than a performance one, and the fix is to
/// answer questions rather than to load fewer rows.
public struct QueueFilter {

    /// The questions worth one click, taken from what the list is
    /// actually scanned for.
    public enum Scope: String, CaseIterable {
        case all
        /// Anything with an open question about who spoke — including a
        /// name the server guessed at low confidence, which is as much a
        /// question as no name at all.
        case needsName
        /// Refused in a way retrying would reproduce. Its audio is kept
        /// indefinitely, so this is the list that can still be rescued.
        case failed
        /// Not finished yet: bytes to send, or a transcript to wait for.
        case inProgress
        case ready

        public var label: String {
            switch self {
            case .all: return "All"
            case .needsName: return "Needs a name"
            case .failed: return "Failed"
            case .inProgress: return "In progress"
            case .ready: return "Ready"
            }
        }
    }

    public var scope: Scope
    public var text: String

    public init(scope: Scope = .all, text: String = "") {
        self.scope = scope
        self.text = text
    }

    public var isNarrowing: Bool {
        scope != .all || !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Dates are searched as they are *displayed*, not as ISO strings.
    ///
    /// Somebody looking for a meeting types what they saw in the window
    /// — "24 Aug", "Aug", "14:32" — not `2026-08-24T14:32:00Z`. Matching
    /// the rendered form is what makes the obvious query work.
    private static let searchableDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy HH:mm EEEE MMMM"
        return formatter
    }()

    public func apply(to items: [QueueItem]) -> [QueueItem] {
        let needle = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespaces)

        return items.filter { item in
            guard matches(scope: item) else { return false }
            guard !needle.isEmpty else { return true }
            return Self.haystack(for: item).contains(needle)
        }
    }

    private func matches(scope item: QueueItem) -> Bool {
        switch scope {
        case .all: return true
        case .needsName: return item.openSpeakerQuestions > 0
        case .failed: return item.state == .failed
        case .inProgress: return item.state == .pending || item.state == .uploaded
        case .ready: return item.state == .ready
        }
    }

    /// Everything the row shows, flattened.
    ///
    /// Searching what is on screen rather than a chosen subset of fields
    /// means a query that matches something visible always finds it —
    /// including a speaker's name, which is often the only thing anyone
    /// remembers about a meeting.
    static func haystack(for item: QueueItem) -> String {
        var parts = [
            item.title ?? "Recording",
            searchableDate.string(from: item.occurredAt),
            item.statusDescription,
            item.speakerDescription,
        ]
        parts.append(contentsOf: item.knownSpeakers.compactMap(\.displayName))
        parts.append(contentsOf: item.namedSpeakers)
        return parts.joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
}
