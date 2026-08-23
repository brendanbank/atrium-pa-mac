import AVFoundation
import AtriumCore
import Foundation

// MARK: - Temporary roots

/// Run `body` with every AppPaths location redirected into a fresh
/// temporary directory, then clean up.
///
/// The point is to exercise the real code — real atomic writes, the real
/// reload path — rather than a mock file layer, without any chance of a
/// test deleting a meeting that has not been uploaded yet.
func withTemporaryRoot(_ body: () throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "atrium-selftest-\(UUID().uuidString)")
    AppPaths.rootOverride = root
    defer {
        AppPaths.rootOverride = nil
        try? FileManager.default.removeItem(at: root)
    }
    try AppPaths.ensureDirectories()
    try body()
}

/// Async variant. Deliberately a different name rather than an
/// overload: inside an async closure the compiler happily picks the
/// synchronous one, and the failure is a confusing diagnostic at every
/// call site rather than here.
func withTemporaryRootAsync(_ body: () async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "atrium-selftest-\(UUID().uuidString)")
    AppPaths.rootOverride = root
    defer {
        AppPaths.rootOverride = nil
        try? FileManager.default.removeItem(at: root)
    }
    try AppPaths.ensureDirectories()
    try await body()
}

func makeFile(named name: String, bytes: Int) throws -> URL {
    let url = AppPaths.recordings.appending(path: name)
    try Data(repeating: 0x41, count: bytes).write(to: url)
    return url
}

/// A file that *reports* a size without occupying it. Used to check the
/// 300 MiB ceiling without writing 300 MiB.
func makeSparseFile(named name: String, bytes: Int) throws -> URL {
    let url = AppPaths.recordings.appending(path: name)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: UInt64(bytes))
    return url
}

func makeTemporaryFile(bytes: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "atrium-selftest-\(UUID().uuidString).bin")
    try Data(repeating: 0x42, count: bytes).write(to: url)
    return url
}

/// Write a queue item straight to disk, to set up a state the queue
/// would otherwise take days to reach.
func writeItem(_ item: QueueItem) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(item).write(
        to: AppPaths.queue.appending(path: "\(item.id.uuidString).json"),
        options: .atomic)
}

// MARK: - Synthetic audio

/// Audio the tests can make for themselves.
///
/// Capture is what this process cannot do — a bare binary gets a stream
/// of zeroes from the process tap — so everything downstream of capture
/// is fed from here instead. A generated tone is also better than a
/// recording for the encoder tests: its amplitude and duration are known
/// exactly, so "the far-end channel was dropped" is a detectable
/// failure rather than a judgement call.
enum SyntheticAudio {

    /// A 48 kHz stereo CAF in the same format `AudioRecorder` writes:
    /// mic-shaped content on the left, far-end-shaped on the right.
    @discardableResult
    static func writeStereoCAF(
        to url: URL, seconds: Double, leftHz: Double, rightHz: Double
    ) throws -> URL {
        try? FileManager.default.removeItem(at: url)
        let sampleRate = 48_000.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)

        let total = Int(seconds * sampleRate)
        guard total > 0 else { return url }

        let chunk = 4800
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk))
        else { throw Harness.Failure(message: "no buffer", file: #file, line: #line) }

        var written = 0
        while written < total {
            let frames = min(chunk, total - written)
            guard let channels = buffer.floatChannelData else { break }
            for frame in 0..<frames {
                let t = Double(written + frame) / sampleRate
                channels[0][frame] = Float(0.5 * sin(2 * .pi * leftHz * t))
                channels[1][frame] = Float(0.5 * sin(2 * .pi * rightHz * t))
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            try file.write(from: buffer)
            written += frames
        }
        return url
    }

    /// A mono CAF at an arbitrary rate, holding `frames` frames of a
    /// tone — one half of a two-file recording.
    ///
    /// `frames` is given directly rather than as a duration so a test can
    /// say "this clock produced 5% more frames than its nominal rate
    /// implies", which is the whole case the offline alignment exists
    /// for.
    @discardableResult
    static func writeMonoCAF(
        to url: URL, rate: Double, frames: Int, hz: Double, amplitude: Float = 0.5
    ) throws -> URL {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        guard frames > 0,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: 4800)
        else { return url }

        var written = 0
        while written < frames {
            let count = min(4800, frames - written)
            guard let channel = buffer.floatChannelData?[0] else { break }
            for index in 0..<count {
                let t = Double(written + index) / rate
                channel[index] = amplitude * Float(sin(2 * .pi * hz * t))
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            written += count
        }
        return url
    }

    /// Highest absolute sample in a file. The one number that separates
    /// "recorded" from the silent-tap failure this whole project is
    /// shaped around.
    static func peak(of url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: 16_384)
        else { return 0 }
        var peak: Float = 0
        // Bound the loop on `framePosition` rather than on a zero-length
        // read: reading past the end of a compressed file throws rather
        // than returning zero frames.
        while file.framePosition < file.length {
            buffer.frameLength = 0
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let channels = buffer.floatChannelData else { break }
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<frames {
                    peak = max(peak, abs(channels[channel][frame]))
                }
            }
        }
        return peak
    }

    /// Real speech, via `say`. Used by the live test: a tone would be
    /// uploaded and transcribed into nothing, which proves the transport
    /// but leaves the pipeline untested.
    static func speak(_ text: String, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, "--data-format=LEF32@22050", text]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
            FileManager.default.fileExists(atPath: url.path)
        else {
            throw Harness.Failure(
                message: "`say` failed with status \(process.terminationStatus)",
                file: #file, line: #line)
        }
    }
}

// MARK: - Network stub

/// Intercepts URLSession traffic so the JSON-RPC contract can be tested
/// without a server.
///
/// The live tests do the opposite — they talk to a real deployment — and
/// both are worth having: this one pins the exact bytes we send, that
/// one proves the other end accepts them.
final class StubProtocol: URLProtocol {

    typealias Handler = @Sendable (URLRequest) -> (Int, String)

    nonisolated(unsafe) static var handler: Handler?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(
                self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLRequest {
    /// URLProtocol hands back a request whose body has been turned into
    /// a stream, so `httpBody` is nil by the time a stub sees it.
    var httpBodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return data
    }

    var httpBodyString: String? {
        httpBodyData.flatMap { String(data: $0, encoding: .utf8) }
    }
}
