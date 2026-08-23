import Accelerate
import Foundation

/// Real-time FFT into a handful of log-spaced bands, for the confidence
/// meter in the recording window.
///
/// This exists because the failure mode this app must guard against is
/// *silent*: a mis-permissioned process tap delivers perfectly-timed
/// buffers of pure zeroes and nothing errors. A number on screen that
/// moves when you speak is the cheapest possible proof that real audio
/// is reaching disk.
///
/// Not thread-safe. Use one instance per stream, driven from one thread.
public final class SpectrumAnalyzer {

    /// Power-of-two FFT width. 1024 @ 48 kHz ≈ 21 ms per frame, and
    /// ~47 Hz per bin — fine for a visual meter.
    private let fftSize: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    /// Log-spaced band edges (bin indices), low → high.
    private let bandEdges: [Int]

    private var window: [Float]
    private var realPart: [Float]
    private var imagPart: [Float]
    private var magnitudes: [Float]

    /// Smoothed per-band levels, 0…1. Fast attack, slow decay so a
    /// transient is visible rather than flickering past.
    public private(set) var levels: [Float]

    /// Peak magnitude of the most recent input, before any smoothing.
    /// Zero over a sustained period means the stream is muted.
    public private(set) var instantPeak: Float = 0

    /// `instantPeak` with the same attack/decay as the bands, so the
    /// indicator does not flicker between syllables.
    private var smoothedPeak: Float = 0

    private let attack: Float = 0.55
    private let decay: Float = 0.12

    public init(fftSize: Int = 1024, bandCount: Int = 20, sampleRate: Double = 48_000) {
        self.fftSize = fftSize
        self.log2n = vDSP_Length(log2(Float(fftSize)))
        self.setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        // Hann window: cheap, and good enough to stop spectral leakage
        // making every band look equally loud.
        var w = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&w, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.window = w

        self.realPart = [Float](repeating: 0, count: fftSize / 2)
        self.imagPart = [Float](repeating: 0, count: fftSize / 2)
        self.magnitudes = [Float](repeating: 0, count: fftSize / 2)
        self.levels = [Float](repeating: 0, count: bandCount)

        // Log-spaced edges from ~40 Hz to Nyquist. Linear bands would
        // put almost every speech formant in the first two bars.
        let nyquist = Float(sampleRate / 2)
        let lowHz: Float = 40
        var edges: [Int] = []
        for i in 0...bandCount {
            let fraction = Float(i) / Float(bandCount)
            let hz = lowHz * pow(nyquist / lowHz, fraction)
            let bin = Int((hz / nyquist) * Float(fftSize / 2))
            edges.append(min(max(bin, 0), fftSize / 2 - 1))
        }
        self.bandEdges = edges
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Feed interleaved or mono samples. Interleaved stereo is folded to
    /// mono first — the meter shows "is there sound", not stereo image.
    public func process(samples: [Float], channels: Int = 1) {
        guard samples.count >= fftSize * channels else { return }

        var mono = [Float](repeating: 0, count: fftSize)
        if channels == 1 {
            mono = Array(samples.prefix(fftSize))
        } else {
            for frame in 0..<fftSize {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += samples[frame * channels + channel]
                }
                mono[frame] = sum / Float(channels)
            }
        }

        var peak: Float = 0
        vDSP_maxmgv(mono, 1, &peak, vDSP_Length(fftSize))
        instantPeak = peak
        smoothedPeak += (peak - smoothedPeak) * (peak > smoothedPeak ? attack : decay)

        vDSP_vmul(mono, 1, window, 1, &mono, 1, vDSP_Length(fftSize))

        realPart.withUnsafeMutableBufferPointer { realBuffer in
            imagPart.withUnsafeMutableBufferPointer { imagBuffer in
                var split = DSPSplitComplex(
                    realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)

                mono.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self, capacity: fftSize / 2
                    ) { typed in
                        vDSP_ctoz(typed, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }

                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        // Normalise, convert to a dB-ish scale, fold into bands.
        let scale = 2.0 / Float(fftSize)
        for index in 0..<magnitudes.count {
            magnitudes[index] *= scale
        }

        for band in 0..<levels.count {
            let start = bandEdges[band]
            let end = max(bandEdges[band + 1], start + 1)

            // Loudest bin in the band, not the mean.
            //
            // The bands are log-spaced, so the top ones span hundreds of
            // bins. Averaging across them buries a speech formant under
            // its own neighbouring silence, and the meter reads far
            // lower than the audio actually is. Peak-per-band is the
            // usual choice for a level display for exactly this reason.
            var peakBin: Float = 0
            for bin in start..<min(end, magnitudes.count) {
                peakBin = max(peakBin, magnitudes[bin])
            }

            let db = 20 * log10(max(peakBin, 1e-7))
            let normalised = max(0, min(1, (db - Self.floorDB) / (Self.ceilingDB - Self.floorDB)))

            // Expand the bottom of the range. `pow` with an exponent
            // below 1 is a root, which lifts small values — the opposite
            // of an exponential, which would push them further down.
            // What is wanted here is more resolution where the signal
            // actually sits.
            let shaped = pow(normalised, Self.expansion)

            let previous = levels[band]
            let coefficient = shaped > previous ? attack : decay
            levels[band] = previous + (shaped - previous) * coefficient
        }
    }

    /// Display range, in dB of per-bin FFT magnitude.
    ///
    /// Not 0 dB at the top: a single FFT bin of ordinary speech never
    /// gets near full scale, because the energy is spread across the
    /// spectrum and the window scales it down further. Measured on this
    /// project's own recordings, a mic peak around 0.05 — a quiet room
    /// at a normal talking distance — puts band peaks in the −60 to
    /// −30 dB region. A meter whose top is 0 dB therefore spends its
    /// life in the bottom sixth of its travel, which is what "the bars
    /// are low" meant.
    ///
    /// These two numbers are the meter's calibration and are the right
    /// place to tune it. `make test` pins them against synthesised tones
    /// at known amplitudes.
    private static let floorDB: Float = -72
    private static let ceilingDB: Float = -18

    /// Gamma applied after normalisation. Below 1 lifts quiet signals.
    ///
    /// Deliberately *not* an automatic gain that rescales to a rolling
    /// maximum. That would make a stream carrying nothing but noise
    /// display as full-height bars, and this meter exists to answer
    /// "is real audio arriving" — an indicator that looks healthy when
    /// the audio is dead is worse than no indicator.
    private static let expansion: Float = 0.7

    /// What the panel should actually draw.
    ///
    /// **This is an indicator, not a meter.** It answers "is audio
    /// arriving", and it is shaped for that question rather than for
    /// reporting loudness faithfully. Two parts:
    ///
    /// * **Presence** — how tall the bars are overall, derived from the
    ///   block's own peak amplitude in the time domain, mapped across a
    ///   speech-shaped range.
    /// * **Shape** — the relative heights, from the band levels
    ///   normalised against their own maximum so the spectrum always
    ///   uses the full width of the display.
    ///
    /// The reason the two are separated is the mistake this replaced.
    /// Drawing raw band levels meant the bars tracked *per-FFT-bin*
    /// magnitude, and real speech spreads its energy over hundreds of
    /// bins, so no single bin ever gets far up the scale. A pure tone
    /// measured 0.94 of full height while an actual voice barely moved
    /// the display — the meter was correct and useless.
    ///
    /// Normalising the shape is a per-frame automatic gain, and on its
    /// own it would be dangerous here: it would render a stream of pure
    /// noise as confident full-height bars, which is the one thing this
    /// indicator must never do. `presence` is what makes it safe,
    /// because it is an *absolute* gate — below `presenceFloorDB`
    /// nothing is drawn at all, no matter what shape the noise has.
    public var displayLevels: [Float] {
        let presence = self.presence
        guard presence > 0, let loudest = levels.max(), loudest > 0 else {
            return [Float](repeating: 0, count: levels.count)
        }
        return levels.map { ($0 / loudest) * presence }
    }

    /// 0…1: how strongly a signal is present, from the smoothed
    /// time-domain peak. Zero means silence, not "quiet".
    public var presence: Float {
        let db = 20 * log10(max(smoothedPeak, 1e-7))
        let span = Self.presenceCeilingDB - Self.presenceFloorDB
        let normalised = max(0, min(1, (db - Self.presenceFloorDB) / span))
        return pow(normalised, Self.presenceExpansion)
    }

    /// Range of block peak amplitude the indicator spans.
    ///
    /// −52 dB is about 0.0025 — above room tone and a noise floor, below
    /// any speech worth recording. −14 dB is about 0.2, which a voice
    /// close to the microphone reaches. Measured on this project's own
    /// recordings, a normal voice in a quiet room peaks around 0.04–0.10,
    /// which lands comfortably in the upper half of that span.
    private static let presenceFloorDB: Float = -52
    private static let presenceCeilingDB: Float = -14
    private static let presenceExpansion: Float = 0.6

    /// Fold `levels` onto `count` display bars, each taking the loudest
    /// source band in its slice.
    ///
    /// Lives here rather than in the view so it can be tested, because
    /// getting it wrong is silent. It point-sampled once — position 0,
    /// 0.5, 1 of a 20-band array — which reads bands 0, 10 and 19 and
    /// ignores the other seventeen. A voice whose energy sits between
    /// them then moves nothing, and the panel reads "not recording"
    /// while the recording is perfectly fine. The fewer bars are drawn,
    /// the more of the spectrum that mistake discards.
    public static func fold(levels: [Float], into count: Int) -> [Float] {
        guard !levels.isEmpty, count > 0 else {
            return [Float](repeating: 0, count: max(count, 0))
        }
        let width = Double(levels.count) / Double(count)
        return (0..<count).map { index in
            let start = min(Int((Double(index) * width).rounded(.down)), levels.count - 1)
            let end = max(
                start + 1, min(Int((Double(index + 1) * width).rounded(.down)), levels.count))
            var peak: Float = 0
            for source in start..<end { peak = max(peak, levels[source]) }
            return peak
        }
    }

    /// Decay toward silence when no audio is arriving, so the meter
    /// visibly falls to zero rather than freezing on the last frame.
    public func idle() {
        instantPeak = 0
        smoothedPeak *= (1 - decay)
        for band in 0..<levels.count {
            levels[band] *= (1 - decay)
        }
    }
}
