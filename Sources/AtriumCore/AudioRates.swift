import Foundation

/// Sample rates real devices run at, and how to recognise one.
///
/// In `AtriumCore` rather than beside the tap that needs it, because
/// everything touching a capture device lives in the app target and
/// cannot be tested — and this is arithmetic, which can.
public enum AudioRates {

    /// The rates CoreAudio devices actually use.
    public static let standard: [Double] = [
        8000, 16000, 22050, 24000, 32000, 44100, 48000, 96000,
    ]

    /// The nearest real rate to a measured one.
    ///
    /// A rate derived from frames over elapsed time is close but never
    /// exact. Measured with AirPods: an aggregate device reporting 48000
    /// while delivering 16571 frames a second — hands-free runs the link
    /// at 16 kHz, and 16571 is that number sampled over a slightly wrong
    /// interval. Resampling from 16571 instead of 16000 would bake a
    /// 3.6% error into every second of the recording, which is the same
    /// size of mistake as the one this was written to fix.
    public static func nearestStandard(to measured: Double) -> Double {
        standard.min { abs($0 - measured) < abs($1 - measured) } ?? measured
    }
}
