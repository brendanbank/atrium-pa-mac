import AtriumCore
import Foundation

/// `make test` / `make test-live`.
///
/// Usage:
///
///   atrium-selftest                     unit tests only
///   atrium-selftest --live              also upload to a real Atrium PA
///   atrium-selftest --live --poll-seconds 600
///   atrium-selftest --only live         skip the unit tests
///
/// Exit code 0 means everything passed.

setvbuf(stdout, nil, _IONBF, 0)

let arguments = CommandLine.arguments
let wantsLive = arguments.contains("--live") || arguments.contains("--only=live")
let onlyLive = arguments.contains("--only=live")
    || (arguments.firstIndex(of: "--only").map { arguments.count > $0 + 1 && arguments[$0 + 1] == "live" } ?? false)

var pollSeconds: TimeInterval = 300
if let index = arguments.firstIndex(of: "--poll-seconds"), arguments.count > index + 1,
    let value = Double(arguments[index + 1])
{
    pollSeconds = value
}

if arguments.contains("--help") || arguments.contains("-h") {
    print(
        """
        atrium-selftest — tests for the parts of atrium-mac that do not
        need a microphone.

          --live                 also run the end-to-end upload tests
          --only live            run only the live tests
          --poll-seconds <n>     how long to wait for a transcript (default 300)

        Live tests need credentials:

          ATRIUM_BASE_URL, ATRIUM_CLIENT_ID, ATRIUM_CLIENT_SECRET

        or a configured app (config.json plus the Keychain entry).

        Capture itself is NOT tested here and cannot be: a bare binary
        cannot hold the audio-capture TCC grant, so the process tap would
        deliver a stream of zeroes and any assertion about audio flowing
        would fail here while passing in the real app. Use
        `make -C Probes bundle && open Probes/Probe.app` for that.
        """)
    exit(0)
}

// `--encode <file.caf>` re-encodes an existing master with the current
// downmix logic and prints what it chose. A diagnostic, not a test: it
// is how you check a real recording against a change to the mix without
// waiting for another meeting.
if let index = arguments.firstIndex(of: "--encode"), arguments.count > index + 1 {
    let source = URL(fileURLWithPath: arguments[index + 1])
    do {
        let mix = try AudioEncoder.mix(for: source)
        print("mix: \(mix.summary)")
        let output = try AudioEncoder.encodeForUpload(source: source, mix: mix)
        print("wrote \(output.path)")
        exit(0)
    } catch {
        print("encode failed: \(error)")
        exit(1)
    }
}

// `--identify <capture_id> <voice_cluster_id>` runs the evidence half of
// the naming flow against a real deployment and prints what came back.
// A diagnostic, not a test: it reads, names nobody, and changes nothing.
if let index = arguments.firstIndex(of: "--identify"), arguments.count > index + 2,
    let captureID = Int(arguments[index + 1]),
    let cluster = Int(arguments[index + 2])
{
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        switch LiveTests.credentials() {
        case .failure(let why):
            print("no credentials: \(why.description)")
        case .success(let resolved):
            let client = MCPClient(
                config: resolved.config, secret: resolved.secret,
                refreshToken: Keychain.refreshToken(for: resolved.config.clientID))
            do {
                let found = try await client.identifySpeaker(
                    captureID: captureID, voiceCluster: cluster)
                print("status: \(found.status)")
                print("other recordings: \(found.otherRecordings)")
                for quote in found.spokenNames { print("spoken: \(quote)") }
                for candidate in found.candidates {
                    let match =
                        candidate.matchPercent.map { "\($0)% \(candidate.band ?? "?")" }
                        ?? candidate.rsvp.map { "invited, \($0)" } ?? "-"
                    print(
                        "candidate: \(candidate.displayName) [\(candidate.source)] "
                            + "\(match) plausible=\(candidate.isPlausible)")
                }
                for sample in found.samples {
                    print(
                        "sample \(sample.sampleID): expires in \(sample.expiresIn)s, "
                            + "persisted=\(sample.hasPersistedSnippet)")
                    let data = try await client.fetchSample(sample)
                    print("  fetched \(data.count) bytes")
                    let scratch = FileManager.default.temporaryDirectory
                        .appending(path: "atrium-snippet-\(sample.sampleID)")
                    try data.write(to: scratch)
                    print("  wrote \(scratch.path)")
                }
            } catch {
                print("failed: \(error)")
            }
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

let harness = Harness()

print("atrium-mac self test")

if !onlyLive {
    UnitTests.run(harness)
}

if wantsLive {
    LiveTests.run(harness, pollSeconds: pollSeconds)
} else if !onlyLive {
    print("")
    print(
        "\u{001B}[2mLive upload tests skipped. Run `make test-live` to exercise "
            + "the real ingest lane.\u{001B}[0m")
}

exit(harness.summarise())
