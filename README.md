# Atrium PA Capture

A small macOS menu-bar app that notices when a meeting starts, records
both sides of it, and hands the audio to
[Atrium PA](https://github.com/Brendan-Bank/atrium-pa) for transcription.

No "join your meeting" bot, no calendar integration, no cloud middleman.
It watches CoreAudio for the moment an app grabs the microphone, and it
stops when that app lets go.

## Why both sides matter

A recording of only your own microphone gives you a transcript of your
half of the conversation. For extracting action items and open loops —
which is the point — most of what you care about is what *other people*
said. So this captures two streams:

- **Mic** — your voice, via `AVAudioEngine`.
- **Far end** — the other participants, via a CoreAudio **process tap**.

The process tap is chosen over ScreenCaptureKit deliberately:
ScreenCaptureKit's audio capture requires the full Screen Recording
grant, whereas a tap needs only audio-capture consent and can be scoped
so it doesn't sweep up your music.

## The floating panel

While recording, a small always-on-top panel shows a live spectrum for
each stream. This is not decoration. The characteristic failure of an
audio-capture app on macOS is *silent*: a mis-permissioned tap delivers
perfectly-timed buffers of pure zeroes and nothing errors. A meter that
moves when you speak is the cheapest possible proof that real audio is
reaching disk — and the panel turns a stream red after ~2 s of silence.

The panel is non-activating, so clicking or dragging it never pulls focus
out of your meeting. The red square stops the recording and keeps what
has been captured.

It appears when a recording starts and not before, so if you have never
seen it, pick **Start Recording Now** from the menu — that is also the
quickest way to check that capture works on a new machine.

## Recording by hand

Detection covers the apps on the allowlist. **Start Recording Now**
covers everything else: a conversation in the room, a call on a phone on
the desk, an app you have not added yet.

A manual recording skips every heuristic — no 60 s far-end gate (an
in-person conversation has no far end at all), no 90 s minimum, and an
app grabbing the mic in the background cannot end it. Stop it with the
red square or from the menu.

## Requirements

- macOS **14.2+** (CoreAudio process objects and process taps)
- Swift 6 toolchain
- An Atrium PA instance and an OAuth client with the `pa.ingest` scope

## Build

```sh
make run
```

**Use `make run`, not `swift run`.** A bare binary cannot hold the
audio-capture TCC grant, so the tap silently records silence. The bundle
is load-bearing. `make verify` checks that the bundle is capable of
holding a grant.

Ad-hoc signing is sufficient for personal use — no paid Developer ID
required.

## Connecting to Atrium PA

Mint an OAuth client with the `pa.ingest` scope in Atrium PA's admin UI
(`/api/pa/admin/oauth-clients`), then open **Atrium PA Connection…** in
the menu and paste in the base URL, client ID and secret. *Save & Test*
mints a token straight away and tells you whether it worked.

The base URL and client ID go to `config.json`. **The secret goes to
your login keychain and nowhere else** — it is an account-level
credential, not a scoped upload token, so it has no business sitting in
a file next to the recordings.

Until it is configured, recordings still happen; they queue up on disk
and the menu says `not configured`.

## What happens to a finished recording

1. Written incrementally during the meeting as 48 kHz stereo CAF — your
   mic on the left, the far end on the right. A crash costs the last
   40 ms, not the file.
2. Encoded to 16 kHz mono AAC (~41 MB for three hours), which is what
   Atrium PA wants anyway; it downmixes on arrival.
3. Queued on disk, one JSON file per upload, so a reboot or a closed lid
   loses nothing.
4. `upload_audio` over MCP → `PUT` the bytes → poll `get_upload_status`
   until the transcript is ready.
5. The local copies are deleted 7 days after that. A failed upload keeps
   its audio indefinitely — it is the only copy.

Closing the lid mid-meeting finalises the recording and treats it as
complete rather than abandoning it.

## Tests

```sh
make test        # unit tests: drift, session state machine, queue, wire format
make test-live   # ...plus a real upload to your Atrium PA
```

These are a plain executable rather than `swift test`, because XCTest and
swift-testing ship with Xcode and this project otherwise needs only the
Command Line Tools.

`make test-live` needs credentials and leaves a real capture behind:

```sh
export ATRIUM_BASE_URL=https://…
export ATRIUM_CLIENT_ID=…
export ATRIUM_CLIENT_SECRET=…
make test-live
```

Capture itself is not covered and cannot be: a bare test binary gets a
stream of zeroes from the process tap, so the assertion would fail there
and pass in the real app. Use `make -C Probes bundle` and
`open Probes/Probe.app` for that question.

## Configuration

`~/Library/Application Support/AtriumMac/allowlist.json`, seeded on first
launch:

```json
{
  "prefixes": [
    "com.microsoft.teams2",
    "com.google.Chrome",
    "us.zoom.xos",
    "net.whatsapp.WhatsApp"
  ]
}
```

Matching is by **prefix**, which is required rather than convenient:
every one of these apps grabs the microphone from a helper process
(`com.microsoft.teams2.helper`, `com.google.Chrome.helper`, …), so an
exact-match list would match nothing. Run `Probes/dump-procs` to see the
live bundle IDs on your machine.

## How a meeting is detected

1. A process in the allowlist starts capturing microphone input.
2. Recording begins immediately, speculatively.
3. If no far-end audio appears within 60 s, the session is discarded — it
   was a mic test, not a call. This is what makes Chrome usable, since a
   Meet tab is indistinguishable from any other site using the mic.
4. When the mic is released for 45 s, the meeting is over. Re-acquisition
   within 2 minutes is treated as a reconnect and merged.
5. Recordings shorter than 90 s are dropped as blips.

## Status

Working: mic detection, far-end capture, session state machine,
allowlist, floating panel, manual recording, incremental stereo
recording with drift correction, AAC encoding, the durable upload queue,
OAuth credentials in the Keychain, and sleep/quit finalisation.

Unverified, and stated as such: no TCC prompt has ever been observed
during development, so whether a bundled run is *granted* or simply
never *gated* is unknown — verify on a clean machine. Real-hardware
clock drift over a long call has been simulated but not measured. The
far-end confirmation threshold (`instantPeak > 0.002`) is still a guess.
See `docs/DESIGN.md` §"Open risks".

## Probes

`Probes/` holds standalone single-file tools used to establish
feasibility. They remain the fastest way to distinguish a bug in this app
from a problem with the machine — see `CLAUDE.md`.

## Licence

BSD-2-Clause — see [LICENSE](LICENSE).
