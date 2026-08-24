import Foundation

/// Deciding whether a typed name is somebody the roster already knows.
///
/// Naming a voice from this app created a duplicate person: a second
/// record beside an existing one with the same name, which Atrium PA
/// disambiguated by appending the older person's id to the display name.
/// That is live mess in the operator's data and it compounds — the next
/// recording offers two identical-looking candidates, and picking the
/// wrong one splits a voice's history across both.
///
/// ## Why this is exact-after-normalising rather than fuzzy
///
/// The cost of the two mistakes is not symmetric. A missed duplicate is
/// what happens today and is recoverable by merging. A false positive
/// steers somebody into attributing a meeting to the wrong person, and
/// naming reaches *backwards* through every recording that voice appears
/// in — so a wrong answer here is not one wrong label, it is all of them.
///
/// So this only reports a duplicate when the names are the same once
/// case, accents, punctuation and spacing stop counting. "Alex Rivera"
/// and "alex rivera" are the same person; "Alex Rivera" and "Alex
/// Riveras" are not, and the app must not guess that they are.
public enum PersonMatch {

    /// Compare on this rather than on the raw string.
    ///
    /// Atrium PA appends the older person's id when two people share a
    /// display name — `Sam Okafor (#2571)` — so a roster entry can carry
    /// the evidence of a previous duplicate in its own name. Stripping
    /// that is what lets the *second* duplicate be caught.
    public static func normalise(_ name: String) -> String {
        var text = name

        // Drop a trailing disambiguator: "Sam Okafor (#2571)".
        if let range = text.range(
            of: #"\s*\(#\d+\)\s*$"#, options: [.regularExpression])
        {
            text.removeSubrange(range)
        }

        // Fold case and accents together — `Renée` typed without the
        // accent is the same person, and on a UK keyboard it usually is.
        text =
            text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        // Everything that is not a letter or a digit goes, spaces
        // included. "O'Brien", "OBrien" and "O Brien" are one person
        // with three keyboards, and so are "Ann Marie" and "Annmarie" —
        // which only works if word boundaries stop counting too.
        //
        // This does widen matching slightly: two names that differ only
        // in where the spaces fall now compare equal. That is the right
        // direction here, because the names it conflates are the ones
        // people actually type two ways.
        return text.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    /// People from the roster whose name is the typed one.
    ///
    /// Returns every match rather than the first: two genuinely distinct
    /// people can share a name, and that is precisely the case where the
    /// user has to choose rather than be chosen for.
    public static func duplicates(
        of typed: String, in people: [MCPClient.Person]
    ) -> [MCPClient.Person] {
        let target = normalise(typed)
        guard !target.isEmpty else { return [] }
        return people.filter { normalise($0.displayName) == target }
    }
}
