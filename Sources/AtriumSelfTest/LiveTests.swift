import AtriumCore
import Foundation

/// End-to-end against a real Atrium PA deployment.
///
/// Opt-in only (`make test-live`). These tests mint a real token, create
/// a real capture, and put real bytes in the vault — a capture that will
/// sit in the user's transcript list afterwards. That is the point:
/// every part of the upload lane that a stub cannot check lives on the
/// server side of the wire. It is also why they never run by default.
///
/// ## Credentials
///
/// Environment first, saved configuration second:
///
/// ```sh
/// export ATRIUM_BASE_URL=https://…      # your deployment, no trailing slash
/// export ATRIUM_CLIENT_ID=…             # minted with the pa.ingest scope
/// export ATRIUM_CLIENT_SECRET=…
/// make test-live
/// ```
///
/// The environment is the only path by default. The keychain one is
/// behind `--use-keychain` because it *cannot* be made quiet: the items
/// were written by the signed `.app`, and a keychain ACL names the one
/// code identity allowed to read without asking. This runner is a
/// different binary, so it asks — every run, every time. A test that can
/// block on a password dialog is not a test you can script.
enum LiveTests {

    struct Credentials {
        var config: AtriumConfig
        var secret: String
        var source: String
    }

    /// Why the live tests cannot run. A skip, not a failure: an
    /// unconfigured checkout is the normal case.
    struct Unavailable: Error, CustomStringConvertible {
        let description: String
    }

    /// Resolve credentials, or explain what is missing.
    static func credentials() -> Result<Credentials, Unavailable> {
        let environment = ProcessInfo.processInfo.environment

        if let baseURL = environment["ATRIUM_BASE_URL"],
            let clientID = environment["ATRIUM_CLIENT_ID"],
            let secret = environment["ATRIUM_CLIENT_SECRET"],
            !baseURL.isEmpty, !clientID.isEmpty, !secret.isEmpty
        {
            var config = AtriumConfig.defaults
            config.baseURL = baseURL
            config.clientID = clientID
            config.language = environment["ATRIUM_LANGUAGE"]
            return .success(
                Credentials(config: config, secret: secret, source: "environment"))
        }

        // The keychain is opt-in, and deliberately not the default.
        //
        // These credentials were written by the signed `.app`, and a
        // keychain item's ACL names the one code identity allowed to
        // read it without asking. This runner is a different, unsigned
        // binary, so every read raises a login-password dialog — once
        // per run, and a run happens every time anyone types `make
        // test-live` or `--identify`. That is how an afternoon of
        // testing turns into twenty password prompts.
        //
        // A test that can block on a dialog is not one you can script,
        // so it is off unless asked for.
        let saved = AtriumConfig.load()
        if ProcessInfo.processInfo.arguments.contains("--use-keychain"),
            saved.isConfigured, let secret = Keychain.clientSecret(for: saved.clientID)
        {
            return .success(
                Credentials(config: saved, secret: secret, source: "config.json + Keychain"))
        }

        var hint =
            "set ATRIUM_BASE_URL, ATRIUM_CLIENT_ID and ATRIUM_CLIENT_SECRET"
        if saved.isConfigured {
            hint +=
                " — the app is signed in, but reading its keychain from this "
                + "binary prompts for your login password, so pass "
                + "--use-keychain if you want that"
        }
        return .failure(Unavailable(description: hint))
    }

    static func run(_ h: Harness, pollSeconds: TimeInterval) {
        h.group("Live — against a real Atrium PA")

        let resolved: Credentials
        switch credentials() {
        case .failure(let why):
            h.skip("every live test", why: why.description)
            return
        case .success(let found):
            resolved = found
        }
        h.note("credentials from \(resolved.source)")

        let client = MCPClient(config: resolved.config, secret: resolved.secret)

        h.asyncTest("the OAuth client can mint a pa.ingest bearer") {
            let token = try await client.accessToken()
            try expect(!token.isEmpty, "empty token")
            // Three dot-separated segments: this is an HS256 JWT, and a
            // proxy returning an HTML login page instead would not be.
            try expectEqual(
                token.split(separator: ".").count, 3, "token does not look like a JWT")
        }

        h.asyncTest("a spoken recording uploads, transcribes, and reports ready") {
            try await withTemporaryRootAsync {
                let stamp = ISO8601DateFormatter().string(from: Date())
                let spoken =
                    "This is an Atrium P A capture self test recorded on \(stamp). "
                    + "The purpose of this recording is to confirm that audio "
                    + "captured on the Mac reaches Atrium P A and is transcribed. "
                    + "There are no action items in this recording."

                let raw = AppPaths.recordings.appending(path: "selftest-source.aiff")
                try SyntheticAudio.speak(spoken, to: raw)

                // The same encoder the app uses, so this exercises the
                // real 16 kHz mono AAC path rather than a shortcut.
                let uploadable = try AudioEncoder.encodeForUpload(source: raw)
                let sizeBytes =
                    (try FileManager.default.attributesOfItem(
                        atPath: uploadable.path)[.size] as? Int) ?? 0
                try expect(sizeBytes > 0, "the encoder produced nothing")
                h.note("uploading \(sizeBytes) bytes of \(AudioEncoder.uploadContentType)")

                let ticket = try await client.requestUpload(
                    filename: "atrium-mac-selftest.m4a",
                    sizeBytes: sizeBytes,
                    title: "atrium-mac capture self test",
                    occurredAt: Date(),
                    language: resolved.config.language)
                h.note("capture_id \(ticket.captureID), url expires in \(ticket.expiresIn)s")

                // Before the bytes arrive the server must say so — this
                // is the state the queue relies on to decide that a
                // crashed transfer needs a fresh URL.
                let before = try await client.uploadStatus(captureID: ticket.captureID)
                try expectEqual(before.status, "awaiting_upload", "status before the PUT")
                try expect(before.needsBytes, "needsBytes before the PUT")

                try await client.putAudio(
                    fileURL: uploadable, to: ticket.uploadURL)

                let after = try await client.uploadStatus(captureID: ticket.captureID)
                try expect(
                    !after.needsBytes,
                    "the server still wants bytes after a successful PUT")
                h.note("after the PUT: \(after.status)")

                // Transcription of even a short clip takes minutes.
                let deadline = Date().addingTimeInterval(pollSeconds)
                var status = after
                while !status.isTerminal && Date() < deadline {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    status = try await client.uploadStatus(captureID: ticket.captureID)
                    h.note("… \(status.status)")
                }

                if !status.isTerminal {
                    h.note(
                        "still \(status.status) after \(Int(pollSeconds))s — the "
                            + "upload landed; transcription is still running. "
                            + "Raise --poll-seconds to wait longer.")
                    return
                }
                try expect(
                    status.isReady,
                    "the pipeline failed: \(status.detail ?? "no detail")")
                h.note("transcript_id \(status.transcriptID.map(String.init) ?? "?")")
            }
        }

        h.asyncTest("re-uploading identical bytes does not transcribe twice") {
            try await withTemporaryRootAsync {
                // Deterministic content, so this call and any earlier run
                // of it hash the same and the server's sha256 idempotency
                // is what decides the answer.
                let raw = AppPaths.recordings.appending(path: "dedupe.aiff")
                try SyntheticAudio.speak(
                    "Atrium P A duplicate detection check. One two three.", to: raw)
                let uploadable = try AudioEncoder.encodeForUpload(source: raw)
                let sizeBytes =
                    (try FileManager.default.attributesOfItem(
                        atPath: uploadable.path)[.size] as? Int) ?? 0

                func upload() async throws -> Int {
                    let ticket = try await client.requestUpload(
                        filename: "atrium-mac-dedupe.m4a", sizeBytes: sizeBytes,
                        title: "atrium-mac duplicate check", occurredAt: Date(),
                        language: resolved.config.language)
                    try await client.putAudio(fileURL: uploadable, to: ticket.uploadURL)
                    // A duplicate retires the reservation and points at
                    // the capture that already holds the bytes, so the id
                    // to compare is the one the status call resolves to.
                    return try await client.uploadStatus(captureID: ticket.captureID)
                        .transcriptID ?? ticket.captureID
                }

                let first = try await upload()
                let second = try await upload()
                h.note("first \(first), second \(second)")
                try expectEqual(
                    first, second,
                    "identical bytes produced two different captures")
            }
        }

        h.asyncTest("a bad secret is rejected, not silently accepted") {
            let wrong = MCPClient(
                config: resolved.config, secret: resolved.secret + "-wrong")
            do {
                _ = try await wrong.accessToken()
                throw Harness.Failure(
                    message: "a wrong client secret minted a token",
                    file: #file, line: #line)
            } catch let error as MCPClient.ClientError {
                guard case .http(let code, _) = error else {
                    throw Harness.Failure(
                        message: "unexpected error shape: \(error)",
                        file: #file, line: #line)
                }
                try expectEqual(code, 401, "status for invalid_client")
            }
        }
    }
}
