import AppKit
import AtriumCore

/// The panel's histogram: a few bars, bottom-up, one combined signal.
///
/// This is a "is anything being recorded" indicator and nothing more.
/// Both streams are folded into one bar per band, taking whichever is
/// louder, so the full height of the view is available to the loudest
/// thing in the room and a bar moves whether the talking is yours or
/// theirs.
///
/// **What that costs, stated so nobody rediscovers it the hard way.** An
/// earlier version drew the streams mirrored — microphone up, far end
/// down — because the characteristic failure of this app is silent: a
/// mis-permissioned process tap is created happily, fires its IOProc on
/// schedule, and delivers perfectly-timed zeroes. Two halves made that
/// visible at a glance; one merged bar cannot, because a healthy
/// microphone will keep the bars moving while the far end is dead.
///
/// The diagnostic did not go away, it moved: every session logs
/// `micFrames`, `micPeak` and `farEndPeak` to
/// `~/Library/Logs/AtriumMac.log`, and a completed recording whose
/// far-end was silent says so in the menu. What survives here is the
/// unambiguous case — *nothing at all* arriving — which turns the bars
/// red.
final class HistogramView: NSView {

    /// Combined bands, 0…1, low frequency first.
    var levels: [Float] = [] {
        didSet {
            folded = SpectrumAnalyzer.fold(levels: levels, into: Self.barCount)
            needsDisplay = true
        }
    }

    private var folded: [Float] = []

    /// Neither stream has produced anything for a sustained period.
    /// Not "it is quiet" — "it is not recording".
    var isSilent = false { didSet { needsDisplay = true } }

    /// Five thin bars. This is a peripheral-vision check, not an
    /// analyser: enough of them to read as *audio* rather than as a
    /// progress bar, few enough to be legible at 22 pt tall. The
    /// analyser still computes 20 bands; `SpectrumAnalyzer.fold`
    /// resamples them onto these, so this number can be changed on its
    /// own without touching anything upstream.
    static let barCount = 5

    /// Bars are drawn at a fixed width and a fixed gap, then centred,
    /// rather than stretched to fill. A meter made of thick blocks reads
    /// as a level gauge; thin ones close together read as a signal.
    /// Spreading five thin bars across the full width just made five
    /// lonely lines.
    private static let barWidth: CGFloat = 3
    private static let barGap: CGFloat = 2

    /// Bars are drawn to 80% of the height the level asks for.
    ///
    /// Purely a display choice, and deliberately here rather than in
    /// `SpectrumAnalyzer`: the analyser's job is to answer "how loud,
    /// 0 to 1" and its tests pin that answer. Ordinary speech was
    /// driving the bars to the ceiling, where everything looks equally
    /// loud and the meter stops carrying information. Headroom is what
    /// makes a loud moment look loud.
    private static let displayScale: CGFloat = 0.8

    /// One grey, not a ramp.
    ///
    /// The bars used to run magenta → cyan → green → amber across the
    /// band index. It was legible, but it implied the colours *meant*
    /// something, and they did not — this meter answers one question and
    /// the answer is a height, not a hue. A near-white grey has more
    /// contrast against the dark backing than any of those hues did, and
    /// it leaves red free to mean the one thing worth shouting about.
    private static let barColour = NSColor(white: 0.88, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        // A slightly lifted panel, so the meter reads as a well rather
        // than as a hole. The panel behind this is flat black now — it
        // used to be a HUD blur sampling the meeting window, which meant
        // the bars had no stable contrast to work against.
        NSColor(white: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()

        let count = Self.barCount
        let barWidth = Self.barWidth
        let gap = Self.barGap
        let inset: CGFloat = 3
        // Centred as a group. The view can be wider than the bars need;
        // the bars stay together rather than spreading out to meet the
        // edges.
        let span = barWidth * CGFloat(count) + gap * CGFloat(count - 1)
        let origin = max(inset, (bounds.width - span) / 2)
        let limit = (bounds.height - inset * 2) * Self.displayScale
        let minimum: CGFloat = 2
        let colour = isSilent ? NSColor.systemRed : Self.barColour

        for index in 0..<count {
            let x = origin + CGFloat(index) * (barWidth + gap)

            let height = max(minimum, level(at: index, of: count) * limit)
            let rect = NSRect(x: x, y: inset, width: barWidth, height: height)
            let radius = min(barWidth, height) / 2

            // Height carries the level; opacity does not. Fading quiet
            // bars was costing contrast exactly where it is needed most —
            // a low bar is the one you are squinting at to decide whether
            // anything is arriving at all.
            colour.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
    }

    /// Fold the analyser's bands onto the bars actually drawn. The
    /// arithmetic lives in `SpectrumAnalyzer.fold` so it can be tested;
    /// see there for why point-sampling was wrong.
    private func level(at index: Int, of count: Int) -> CGFloat {
        CGFloat(folded.indices.contains(index) ? folded[index] : 0)
    }
}
