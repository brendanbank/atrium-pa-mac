import AVFoundation
import Foundation

/// Sample-rate conversion for one mono stream, with **no samples lost at
/// the seams**.
///
/// This exists because getting that wrong is not obvious from the code
/// and is very obvious in the ears. Both capture paths convert on the
/// consumer side — the microphone from its device rate, the process tap
/// from the output device's rate — and both were written as:
///
/// ```swift
/// let count = min(Int(output.frameLength), maxFrames)
/// return Array(UnsafeBufferPointer(start: outputData, count: count))
/// ```
///
/// A resampler does not emit exactly `in × ratio` frames per call. It
/// emits whatever its filter has finished, which is sometimes more than
/// was asked for — and that surplus was being dropped on the floor.
/// Every drain, twenty-five times a second, a few samples vanished from
/// the middle of the stream. That is not a level problem or a drift
/// problem; it is a periodic discontinuity, and it sounds like buzzing
/// and squealing over the audio.
///
/// So conversion is `push`/`pull`: everything the converter produces is
/// kept, and the caller takes what it needs. What it does not take stays
/// for next time.
///
/// Not thread-safe, and not for a realtime thread: it allocates. Both
/// callers use it from their drain, which is an ordinary thread.
public final class Resampler {

    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    /// Converted frames the caller has not taken yet.
    private var pending: [Float] = []

    public let inputRate: Double
    public let outputRate: Double

    public init?(from inputRate: Double, to outputRate: Double, chunk: AVAudioFrameCount = 16_384) {
        guard inputRate > 0, outputRate > 0,
            let source = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1,
                interleaved: false),
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: 1,
                interleaved: false),
            let converter = AVAudioConverter(from: source, to: target),
            let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunk),
            let output = AVAudioPCMBuffer(
                pcmFormat: target,
                frameCapacity: AVAudioFrameCount(
                    Double(chunk) * outputRate / inputRate) + 1024)
        else { return nil }

        self.converter = converter
        self.input = input
        self.output = output
        self.inputRate = inputRate
        self.outputRate = outputRate
    }

    /// Frames already converted and waiting.
    public var available: Int { pending.count }

    /// How many input frames are needed to satisfy `outputFrames`,
    /// accounting for what is already converted.
    public func inputNeeded(forOutput outputFrames: Int) -> Int {
        let shortfall = max(0, outputFrames - pending.count)
        guard shortfall > 0 else { return 0 }
        return Int((Double(shortfall) * inputRate / outputRate).rounded(.up)) + 2
    }

    /// Feed input. Everything produced is retained.
    public func push(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0, count <= Int(input.frameCapacity),
            let inputData = input.floatChannelData?[0]
        else { return }
        inputData.update(from: samples, count: count)
        input.frameLength = AVAudioFrameCount(count)

        output.frameLength = 0
        var error: NSError?
        var delivered = false
        let status = converter.convert(to: output, error: &error) { [input] _, inputStatus in
            if delivered {
                // `noDataNow`, not `endOfStream`: ending the stream would
                // reset the resampler's filter state and click on every
                // call.
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return input
        }

        guard status != .error, let outputData = output.floatChannelData?[0],
            output.frameLength > 0
        else { return }
        pending.append(
            contentsOf: UnsafeBufferPointer(
                start: outputData, count: Int(output.frameLength)))
    }

    public func push(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            push(base, count: buffer.count)
        }
    }

    /// Take up to `maxFrames`. Anything not taken is kept for next time.
    public func pull(maxFrames: Int) -> [Float] {
        guard maxFrames > 0, !pending.isEmpty else { return [] }
        let count = min(maxFrames, pending.count)
        let result = Array(pending[0..<count])
        pending.removeFirst(count)
        return result
    }

    public func reset() {
        pending.removeAll(keepingCapacity: true)
        converter.reset()
    }
}
