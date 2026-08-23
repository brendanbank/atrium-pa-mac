import AVFoundation
import Foundation

/// Turns the 48 kHz stereo local master into the 16 kHz mono AAC file
/// that actually gets uploaded.
///
/// The split is deliberate and is recorded in DESIGN.md #12. Atrium PA
/// downmixes to 16 kHz mono on arrival anyway — that is what pyannote
/// consumes — so uploading stereo buys nothing today. It costs a great
/// deal: 48 kHz stereo Int16 is ~11 MB per minute, so a three-hour
/// meeting is ~2 GB against a 300 MiB per-file server limit, while the
/// same meeting at 32 kbps mono AAC is ~43 MB. The local copy keeps the
/// channels separate in case diarization later learns to use the fact
/// that one side of the conversation is on a known channel.
public enum AudioEncoder {

    public static let uploadSampleRate: Double = 16_000
    /// 32 kbps mono AAC. Speech-band audio at 16 kHz has nothing above
    /// 8 kHz to preserve, and this is the rate at which three hours
    /// lands comfortably inside the server's per-file ceiling.
    public static let uploadBitRate = 32_000

    public static let uploadContentType = "audio/mp4"

    public enum EncodeError: Error, CustomStringConvertible {
        case emptySource
        case bufferAllocationFailed
        case converterUnavailable
        case conversionFailed(String)

        public var description: String {
            switch self {
            case .emptySource: return "the recording has no audio in it"
            case .bufferAllocationFailed: return "could not allocate a conversion buffer"
            case .converterUnavailable: return "no 48 kHz → 16 kHz converter available"
            case .conversionFailed(let why): return "conversion failed — \(why)"
            }
        }
    }

    /// Per-channel gains for the downmix, and how they were arrived at.
    public struct Mix: Equatable {
        public var mic: Float
        public var farEnd: Float
        public var summary: String

        public init(mic: Float, farEnd: Float, summary: String = "") {
            self.mic = mic
            self.farEnd = farEnd
            self.summary = summary
        }
    }

    /// Target loudness for each side of the conversation, as RMS.
    /// −20 dBFS is a conventional speech level: well clear of the noise
    /// floor, with enough headroom that summing two of them survives.
    static let targetRMS: Float = 0.1

    /// Below this a channel is treated as carrying nothing. Amplifying
    /// room tone by 30 dB produces a very loud recording of a room, and
    /// the far-end channel is *legitimately* silent whenever nobody
    /// else is on the call.
    static let silenceFloorRMS: Float = 0.0003

    /// Ceiling on how far a quiet channel may be lifted (~+34 dB).
    static let maxGain: Float = 50

    /// Highest sample the mix may reach: −1 dBFS of headroom.
    static let ceiling: Float = 0.89

    /// Work out what each channel should be multiplied by.
    ///
    /// **Why not just average the two channels.** Because the two sides
    /// of a call are not recorded at comparable levels and never will
    /// be. The far end arrives post-gain from the meeting app, already
    /// normalised; your own microphone arrives raw, from a metre away,
    /// off a laptop lid. Measured on this project's own recordings: a
    /// mic peak of 0.04 against a far-end peak of 0.70, a 25 dB gap.
    /// `(L+R)/2` preserves that gap and attenuates both by a further
    /// 6 dB, so a transcript loses your half of the conversation first
    /// — and that is the half nobody else's notes can replace.
    ///
    /// Worse in the case measured on a real recording: with the far end
    /// digitally silent, averaging halves the only channel that has any
    /// audio in it, for nothing. The uploaded file came out 6 dB below
    /// the master at −51.5 dBFS RMS.
    ///
    /// So each channel is measured and lifted to a common speech level
    /// independently. This is not faithful to the original mix and is
    /// not trying to be: the file exists to be transcribed, and what
    /// matters is that both voices are intelligible.
    public static func mix(for source: URL) throws -> Mix {
        let file = try AVAudioFile(forReading: source)
        let format = file.processingFormat
        guard file.length > 0 else { throw EncodeError.emptySource }
        guard format.channelCount >= 2 else {
            return Mix(mic: 1, farEnd: 0, summary: "mono source, passed through")
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384)
        else { throw EncodeError.bufferAllocationFailed }

        var sumSquares = [Double](repeating: 0, count: 2)
        var peaks = [Float](repeating: 0, count: 2)
        var frames = 0

        while file.framePosition < file.length {
            buffer.frameLength = 0
            try file.read(into: buffer)
            let count = Int(buffer.frameLength)
            if count == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            for channel in 0..<2 {
                var squares: Double = 0
                var peak: Float = 0
                for index in 0..<count {
                    let value = data[channel][index]
                    squares += Double(value) * Double(value)
                    peak = max(peak, abs(value))
                }
                sumSquares[channel] += squares
                peaks[channel] = max(peaks[channel], peak)
            }
            frames += count
        }
        guard frames > 0 else { throw EncodeError.emptySource }

        let micRMS = Float((sumSquares[0] / Double(frames)).squareRoot())
        let farRMS = Float((sumSquares[1] / Double(frames)).squareRoot())
        return gains(micRMS: micRMS, micPeak: peaks[0], farRMS: farRMS, farPeak: peaks[1])
    }

    /// The gain arithmetic on its own, so `make test` can drive it with
    /// figures taken from real recordings instead of synthesising an
    /// hour of audio.
    public static func gains(
        micRMS: Float, micPeak: Float, farRMS: Float, farPeak: Float
    ) -> Mix {
        func gain(rms: Float) -> Float {
            guard rms > silenceFloorRMS else { return 0 }
            return min(targetRMS / rms, maxGain)
        }

        var micGain = gain(rms: micRMS)
        var farGain = gain(rms: farRMS)

        // Everything is silent. Pass it through rather than writing
        // zeroes times zero: the upload is useless either way, and an
        // untouched copy is the one you can actually diagnose.
        if micGain == 0 && farGain == 0 {
            micGain = 1
            farGain = 1
        }

        // Headroom. Sum-of-peaks is the true worst case, but it assumes
        // both sides peak on the same sample, which in a conversation is
        // rare and costs real level to defend against. Allow for partial
        // overlap and let the clamp in the encode catch the remainder: a
        // handful of clipped samples is inaudible to a transcriber, and
        // 6 dB of lost level is not.
        let predicted = max(micPeak * micGain, farPeak * farGain) * 1.4
        if predicted > ceiling {
            let trim = ceiling / predicted
            micGain *= trim
            farGain *= trim
        }

        return Mix(
            mic: micGain, farEnd: farGain,
            summary: String(
                format: "mic rms %.5f x%.2f, far-end rms %.5f x%.2f",
                micRMS, micGain, farRMS, farGain))
    }

    /// Encode a whole session — every segment, in order — into one
    /// uploadable file.
    ///
    /// A meeting interrupted by sleep or by the app quitting resumes into
    /// a new segment rather than becoming a second unrelated recording,
    /// so what gets uploaded is the meeting, not the piece of it that
    /// happened to fall between two interruptions.
    ///
    /// The segments are joined by concatenation with no gap. Nothing was
    /// recorded while the machine was asleep, so there is no audio for a
    /// gap to represent, and padding one in would only push every later
    /// timestamp away from the words that go with it.
    public static func encodeForUpload(
        segments: [RecordingSidecar.Segment], to destination: URL
    ) throws -> URL {
        guard !segments.isEmpty else { throw EncodeError.emptySource }
        try? FileManager.default.removeItem(at: destination)

        var mixed: [Float] = []
        for (index, segment) in segments.enumerated() {
            let part = try combine(micURL: segment.micURL, farURL: segment.farURL)
            if part.isEmpty {
                Log.write("encode: segment \(index) had nothing in it, skipped")
                continue
            }
            mixed.append(contentsOf: part)
        }
        guard !mixed.isEmpty else { throw EncodeError.emptySource }

        if segments.count > 1 {
            Log.write(
                String(
                    format: "encode: joined %d segments into %.1fs",
                    segments.count, Double(mixed.count) / uploadSampleRate))
        }
        try write(mixed, to: destination)
        return destination
    }

    /// Combine the two per-stream recordings into the uploadable file.
    ///
    /// This is where the sample rates finally meet, and doing it here
    /// rather than during capture is the whole point of writing two
    /// files. Offline there is no realtime constraint, no ring buffer,
    /// no drain boundary to lose samples across, and the answer can be
    /// recomputed if it turns out to be wrong.
    ///
    /// **Alignment is division, not a control loop.** Both files started
    /// within one drain interval of each other, so their lengths
    /// describe the same stretch of wall-clock time. If the microphone
    /// file holds 24 kHz × N frames and the far-end file 48 kHz × M, and
    /// those imply different durations, then one clock did not run at
    /// its nominal rate — and the ratio tells us which and by how much.
    /// Resampling the microphone from its *effective* rate rather than
    /// its nominal one absorbs the difference exactly, with no silence
    /// inserted and no audio discarded.
    ///
    /// Live, that same disagreement had to be guessed at continuously,
    /// and every guess was a splice.
    public static func encodeForUpload(micURL: URL, farURL: URL) throws -> URL {
        let destination = farURL.deletingPathExtension()
            .deletingPathExtension()
            .appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: destination)
        let mixed = try combine(micURL: micURL, farURL: farURL)
        guard !mixed.isEmpty else { throw EncodeError.emptySource }
        try write(mixed, to: destination)
        return destination
    }

    /// One segment, reconciled and mixed, at the upload rate.
    ///
    /// This is where the sample rates finally meet, and doing it here
    /// rather than during capture is the whole point of writing two
    /// files. Offline there is no realtime constraint, no ring buffer, no
    /// drain boundary to lose samples across, and the answer can be
    /// recomputed if it turns out to be wrong.
    ///
    /// **Alignment is division, not a control loop.** Both files started
    /// within one drain interval of each other, so their lengths describe
    /// the same stretch of wall-clock time. If the microphone file holds
    /// 24 kHz × N frames and the far-end file 48 kHz × M, and those imply
    /// different durations, then one clock did not run at its nominal
    /// rate — and the ratio says which, and by how much. Resampling the
    /// microphone from its *effective* rate rather than its nominal one
    /// absorbs the difference exactly, with no silence inserted and no
    /// audio discarded.
    ///
    /// Live, that same disagreement had to be guessed at continuously,
    /// and every guess was a splice.
    static func combine(micURL: URL, farURL: URL) throws -> [Float] {
        let mic = try? Stream(url: micURL)
        let far = try? Stream(url: farURL)
        guard mic != nil || far != nil else { return [] }

        // The far end is the timebase: its device runs continuously
        // whether or not anything is playing, so its length is the most
        // trustworthy measure of how long this segment lasted.
        let reference = far ?? mic!
        let seconds = reference.duration
        guard seconds > 0 else { return [] }

        let micEffective = mic.map { $0.effectiveRate(over: seconds) }
        if let mic, let micEffective, mic.rate > 0 {
            Log.write(
                String(
                    format:
                        "encode: mic %.2fs @%.0fHz (effective %.1f Hz, skew %+.3f%%), "
                        + "far %.2fs @%.0fHz",
                    mic.duration, mic.rate, micEffective,
                    (micEffective / mic.rate - 1) * 100,
                    far?.duration ?? 0, far?.rate ?? 0))
        }

        let micSamples = try mic?.read(resampledTo: uploadSampleRate, from: micEffective)
        let farSamples = try far?.read(resampledTo: uploadSampleRate, from: far?.rate)

        let mix = gains(
            micRMS: rms(micSamples), micPeak: peak(micSamples),
            farRMS: rms(farSamples), farPeak: peak(farSamples))
        Log.write("encode: \(mix.summary)")

        let frames = Int((seconds * uploadSampleRate).rounded())
        var mixed = [Float](repeating: 0, count: max(frames, 1))
        for index in 0..<mixed.count {
            var value: Float = 0
            if let micSamples, index < micSamples.count {
                value += micSamples[index] * mix.mic
            }
            if let farSamples, index < farSamples.count {
                value += farSamples[index] * mix.farEnd
            }
            mixed[index] = max(-1, min(1, value))
        }
        return mixed
    }

    /// One recorded stream, read on demand.
    private struct Stream {
        let file: AVAudioFile
        let rate: Double
        let frames: Int

        init(url: URL) throws {
            file = try AVAudioFile(forReading: url)
            rate = file.fileFormat.sampleRate
            frames = Int(file.length)
            guard rate > 0, frames > 0 else { throw EncodeError.emptySource }
        }

        var duration: TimeInterval { Double(frames) / rate }

        /// The rate this clock *actually* ran at, given that the stream
        /// covers `seconds` of wall-clock time.
        func effectiveRate(over seconds: TimeInterval) -> Double {
            guard seconds > 0 else { return rate }
            return Double(frames) / seconds
        }

        func read(resampledTo target: Double, from source: Double?) throws -> [Float] {
            let sourceRate = source ?? rate
            var raw = [Float]()
            raw.reserveCapacity(frames)
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: 16_384)
            else { throw EncodeError.bufferAllocationFailed }
            file.framePosition = 0
            while file.framePosition < file.length {
                buffer.frameLength = 0
                try file.read(into: buffer)
                let count = Int(buffer.frameLength)
                if count == 0 { break }
                guard let data = buffer.floatChannelData else { break }
                let channels = Int(buffer.format.channelCount)
                if channels == 1 {
                    raw.append(contentsOf: UnsafeBufferPointer(start: data[0], count: count))
                } else {
                    let scale = 1 / Float(channels)
                    for frame in 0..<count {
                        var sum: Float = 0
                        for channel in 0..<channels { sum += data[channel][frame] }
                        raw.append(sum * scale)
                    }
                }
            }
            guard sourceRate != target else { return raw }
            guard let resampler = Resampler(from: sourceRate, to: target) else {
                throw EncodeError.converterUnavailable
            }
            var out = [Float]()
            out.reserveCapacity(Int(Double(raw.count) * target / sourceRate) + 64)
            var offset = 0
            while offset < raw.count {
                let count = min(8192, raw.count - offset)
                resampler.push(Array(raw[offset..<(offset + count)]))
                out.append(contentsOf: resampler.pull(maxFrames: Int.max))
                offset += count
            }
            return out
        }
    }

    private static func rms(_ samples: [Float]?) -> Float {
        guard let samples, !samples.isEmpty else { return 0 }
        var total: Double = 0
        for value in samples { total += Double(value) * Double(value) }
        return Float((total / Double(samples.count)).squareRoot())
    }

    private static func peak(_ samples: [Float]?) -> Float {
        guard let samples else { return 0 }
        return samples.reduce(0) { max($0, abs($1)) }
    }

    private static func write(_ samples: [Float], to destination: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: uploadSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: uploadBitRate,
        ]
        let output = try AVAudioFile(
            forWriting: destination, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: output.processingFormat, frameCapacity: 16_384),
            let channel = buffer.floatChannelData?[0]
        else { throw EncodeError.bufferAllocationFailed }

        var offset = 0
        while offset < samples.count {
            let count = min(Int(buffer.frameCapacity), samples.count - offset)
            for index in 0..<count { channel[index] = samples[offset + index] }
            buffer.frameLength = AVAudioFrameCount(count)
            try output.write(from: buffer)
            offset += count
        }
    }

    /// Encode `source` (the CAF master) to a sibling `.m4a`.
    ///
    /// Two passes: one to measure each channel, one to write. The first
    /// is sequential I/O over a file that is about to be read anyway,
    /// and it is what lets the downmix level-match the two sides of the
    /// conversation rather than averaging them blind — see `mix(for:)`.
    ///
    /// Returns the destination URL. Runs synchronously and is CPU-bound;
    /// call it off the main thread.
    public static func encodeForUpload(source: URL) throws -> URL {
        let mix = try mix(for: source)
        Log.write("encode: \(mix.summary)")
        return try encodeForUpload(source: source, mix: mix)
    }

    public static func encodeForUpload(source: URL, mix: Mix) throws -> URL {
        let destination = source.deletingPathExtension().appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: destination)

        let input = try AVAudioFile(forReading: source)
        let inputFormat = input.processingFormat
        guard input.length > 0 else { throw EncodeError.emptySource }

        // Downmix to mono at the source rate first, then resample. Doing
        // both in one AVAudioConverter means trusting its channel map;
        // this way the mix is ours and the converter only ever sees
        // mono in, mono out.
        guard
            let monoSourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate,
                channels: 1, interleaved: false),
            let monoTargetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: uploadSampleRate,
                channels: 1, interleaved: false)
        else { throw EncodeError.bufferAllocationFailed }

        guard let converter = AVAudioConverter(from: monoSourceFormat, to: monoTargetFormat)
        else { throw EncodeError.converterUnavailable }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: uploadSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: uploadBitRate,
        ]
        let output = try AVAudioFile(
            forWriting: destination, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)

        let chunkFrames: AVAudioFrameCount = 16_384
        let ratio = uploadSampleRate / inputFormat.sampleRate
        guard
            let readBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat, frameCapacity: chunkFrames),
            let monoBuffer = AVAudioPCMBuffer(
                pcmFormat: monoSourceFormat, frameCapacity: chunkFrames),
            let outBuffer = AVAudioPCMBuffer(
                pcmFormat: monoTargetFormat,
                frameCapacity: AVAudioFrameCount(Double(chunkFrames) * ratio) + 64)
        else { throw EncodeError.bufferAllocationFailed }

        var reachedEnd = false

        // Pull-style conversion: the converter asks for input whenever
        // its resampler needs more, which is the only way to get
        // sample-rate conversion right across chunk boundaries.
        while true {
            outBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) {
                _, inputStatus in
                if reachedEnd {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    readBuffer.frameLength = 0
                    try input.read(into: readBuffer, frameCount: chunkFrames)
                } catch {
                    inputStatus.pointee = .endOfStream
                    reachedEnd = true
                    return nil
                }
                let frames = Int(readBuffer.frameLength)
                if frames == 0 {
                    inputStatus.pointee = .endOfStream
                    reachedEnd = true
                    return nil
                }
                downmix(readBuffer, into: monoBuffer, frames: frames, mix: mix)
                inputStatus.pointee = .haveData
                return monoBuffer
            }

            if status == .error {
                throw EncodeError.conversionFailed(
                    conversionError?.localizedDescription ?? "unknown")
            }
            if outBuffer.frameLength > 0 {
                try output.write(from: outBuffer)
            }
            if status == .endOfStream || (status == .inputRanDry && reachedEnd) {
                break
            }
            if outBuffer.frameLength == 0 && reachedEnd { break }
        }

        return destination
    }

    /// Average the channels. The master is mic-left / far-end-right, so
    /// an average is the right mix: each speaker arrives at half
    /// amplitude and neither can clip the other.
    /// Sum the two channels at the gains `mix` chose, and clamp.
    ///
    /// The clamp is a backstop, not the level control: `gains` already
    /// left −1 dBFS of headroom against each channel's measured peak.
    /// It exists for the case both sides peak on the same sample, which
    /// the headroom calculation deliberately does not pay full price to
    /// avoid.
    private static func downmix(
        _ source: AVAudioPCMBuffer, into destination: AVAudioPCMBuffer, frames: Int,
        mix: Mix
    ) {
        guard let input = source.floatChannelData,
            let output = destination.floatChannelData?[0]
        else { return }

        if source.format.channelCount == 1 {
            let gain = mix.mic
            for frame in 0..<frames {
                output[frame] = max(-1, min(1, input[0][frame] * gain))
            }
        } else {
            for frame in 0..<frames {
                let summed = input[0][frame] * mix.mic + input[1][frame] * mix.farEnd
                output[frame] = max(-1, min(1, summed))
            }
        }
        destination.frameLength = AVAudioFrameCount(frames)
    }
}
