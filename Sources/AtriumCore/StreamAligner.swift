import Foundation

/// Keeps a slave audio stream locked to a master one that does not share
/// its clock.
///
/// Extracted from `AudioRecorder` so the arithmetic can be tested
/// without a microphone, a process tap or a TCC grant — which is the
/// only way to test it at all on a machine where a bare binary captures
/// silence. Clock drift between the mic and the tap is the main
/// remaining engineering risk in this project (DESIGN.md §"Open risks"),
/// and it is not a risk you can debug by reading a waveform three hours
/// in.
///
/// The master is the process tap: it is driven by the output device and
/// delivers frames continuously whether or not anything is playing, so
/// it is a dependable timebase. Each cycle the caller says how many
/// frames the master produced (`wanted`) and how many the slave has
/// buffered (`available`), and gets back what to do:
///
/// * **skip** — discard this many of the *oldest* buffered frames.
///   Discarding the oldest is what actually removes an accumulated
///   offset; discarding the newest would merely move it later.
/// * **take** — write this many.
/// * **pad** — append this much silence because the slave was short.
///
/// Two things are being corrected at once and it matters that they are
/// separable:
///
/// * `owed` is silence already written. It is a real, permanent channel
///   offset until it is repaid by skipping, so it is repaid even when
///   the buffer is nowhere near full. Without this, ordinary buffer
///   jitter would ratchet the two channels apart over a long call — pad
///   on one hiccup, and the late frames simply live in the buffer for
///   the rest of the meeting.
/// * `excess` is backlog past `jitterSlack`, which means the slave clock
///   is genuinely running faster than the master. Left alone it would
///   end as a ring-buffer overrun, which is the same lost audio with no
///   number attached to it.
///
/// Corrections are capped per cycle so they are spread out rather than
/// arriving as one audible splice.
public struct StreamAligner {

    public struct Decision: Equatable {
        public var skip: Int
        public var take: Int
        public var pad: Int

        public init(skip: Int, take: Int, pad: Int) {
            self.skip = skip
            self.take = take
            self.pad = pad
        }
    }

    /// Backlog tolerated as ordinary jitter before it is read as the
    /// slave clock running fast.
    public let jitterSlack: Int
    /// Ceiling on one cycle's correction.
    public let maxCorrection: Int
    /// Ceiling on accumulated silence debt, so a long stall on the slave
    /// side cannot create a debt that takes the rest of the meeting to
    /// repay.
    public let maxOwed: Int

    /// Silence written that has not yet been repaid.
    public private(set) var owed = 0
    public private(set) var paddedFrames = 0
    public private(set) var droppedFrames = 0

    public init(
        jitterSlack: Int, maxCorrection: Int, maxOwed: Int,
        catchUpThreshold: Int = Int.max
    ) {
        self.jitterSlack = jitterSlack
        self.maxCorrection = maxCorrection
        self.maxOwed = maxOwed
        self.catchUpThreshold = catchUpThreshold
    }

    /// Backlog past which the gentle correction gives up and catches up
    /// in one go.
    ///
    /// `maxCorrection` bounds how fast drift can be worked off — 48
    /// frames per 40 ms drain is 2.5%. That is generous against clock
    /// drift, which is measured in hundredths of a percent, and useless
    /// against a *rate* mismatch. A Bluetooth input resampled to the
    /// recorder's working rate measured **4.8%** against the output
    /// clock, and once the mismatch exceeds what the correction can
    /// remove, the backlog grows every single drain and never comes
    /// back: the microphone channel falls further behind for as long as
    /// the recording lasts.
    ///
    /// So there is a ceiling. Past it, the excess is discarded in one
    /// step rather than a slice at a time. That is an audible splice,
    /// once, against a delay that would otherwise reach minutes on a
    /// long call — and `droppedFrames` records it either way.
    public let catchUpThreshold: Int

    public mutating func plan(wanted: Int, available: Int) -> Decision {
        guard wanted > 0 else { return Decision(skip: 0, take: 0, pad: 0) }

        let excess = max(0, available - wanted - jitterSlack)

        // Gentle by default, decisive when the gentle path cannot win.
        let allowance = excess > catchUpThreshold ? excess : maxCorrection
        // Never skip into frames this cycle needs: falling behind is
        // better than deliberately throwing away audio we are about to
        // write silence in place of.
        let skip = min(min(owed + excess, allowance), max(0, available - wanted))
        let take = min(wanted, max(0, available - skip))
        let pad = wanted - take

        droppedFrames += skip
        owed -= min(owed, skip)
        paddedFrames += pad
        owed = min(owed + pad, maxOwed)

        return Decision(skip: skip, take: take, pad: pad)
    }

    /// Net misalignment in frames: positive means the slave channel is
    /// running behind the master.
    public var netOffset: Int { paddedFrames - droppedFrames }
}
