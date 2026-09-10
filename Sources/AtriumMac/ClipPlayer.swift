import AVFoundation
import Foundation

/// Play a few seconds of somebody's voice.
///
/// This was `AVAudioPlayer`, and it could not stay that way. Atrium PA
/// serves a persisted voice snippet as **Ogg Vorbis** (`audio/ogg`),
/// and `AVAudioPlayer` will not play one. Measured on macOS 26.5
/// against the same 8-second clip, all three shapes of it:
///
/// | attempt | init | `prepareToPlay()` | `play()` |
/// |---|---|---|---|
/// | `AVAudioPlayer(data:)` | succeeds, duration 8.0 | false | false |
/// | `AVAudioPlayer(contentsOf:)` | succeeds, duration 8.0 | false | false |
/// | `fileTypeHint: "org.xiph.ogg-audio"` | succeeds, duration 8.0 | — | false |
///
/// Nothing throws. The initialiser reads the header well enough to
/// report the right duration and then the player silently declines to
/// sound — and the old code kept it behind a `try?` and discarded the
/// `Bool` from `play()`, so pressing the button produced a stop button,
/// no audio, and no log line. It looked exactly like a server that had
/// swept the clip.
///
/// `AVAudioFile` decodes those same bytes without complaint — 128000
/// frames at 16 kHz, peak 0.26 — so the clip was always fine and only
/// the player was wrong. Decode it and play the buffer through an
/// engine.
///
/// The warning elsewhere in this project about `AVAudioEngine` is about
/// **capture**: its input tap delivers nothing on this macOS. The
/// output side is a different code path and is measured working here.
final class ClipPlayer {

    /// Called on the main thread when a clip reaches its own end.
    var onFinish: (() -> Void)?

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var attached = false

    /// Bumped on every start and every stop, so the completion of a
    /// clip that has already been replaced cannot report the one now
    /// playing as finished.
    private var generation = 0

    enum ClipError: Error, CustomStringConvertible {
        case empty
        var description: String { "there is no audio in it" }
    }

    /// Decode `data` and start it.
    ///
    /// Throws rather than failing quietly. Being unable to say *why*
    /// nothing happened is the whole reason this type exists.
    func play(_ data: Data) throws {
        stop()
        let buffer = try Self.decode(data)

        if !attached {
            engine.attach(node)
            attached = true
        }
        // Re-connected per clip: the format is whatever the server sent
        // — 16 kHz mono today — and a connection made for one rate is
        // not a promise about the next one.
        engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
        try engine.start()

        generation += 1
        let generation = self.generation
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) {
            [weak self] _ in
            // Delivered on an audio thread, and it is not the render
            // thread's business to touch AppKit.
            onMainThread {
                guard let self, generation == self.generation else { return }
                self.stop()
                self.onFinish?()
            }
        }
        node.play()
    }

    func stop() {
        generation += 1
        if attached { node.stop() }
        if engine.isRunning { engine.stop() }
    }

    /// Bytes to PCM.
    ///
    /// `AVAudioFile` is the only decoder here that handles Vorbis, and
    /// it reads from a URL rather than from memory — so the bytes go to
    /// a temporary file, are decoded once, and the file is removed
    /// before a note of it is played.
    private static func decode(_ data: Data) throws -> AVAudioPCMBuffer {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-clip-\(UUID().uuidString)")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // The extension is not part of this: measured, `AVAudioFile`
        // opens the same Ogg bytes named `.ogg` or named nothing at
        // all. It sniffs the content, which is as well — the server
        // answers `audio/ogg` or `audio/wav` depending on whether the
        // snippet was persisted or sliced on demand.
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length))
        else { throw ClipError.empty }
        try file.read(into: buffer)
        guard buffer.frameLength > 0 else { throw ClipError.empty }
        return buffer
    }
}
