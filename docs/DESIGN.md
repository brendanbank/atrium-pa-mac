# Design record

Decisions and the evidence behind them. Written so a future change can
tell which choices were reasoned and which were arbitrary.

## Measured facts

All measured on macOS 26.5.2, Swift 6.3.3, SDK 26.5, Apple silicon.

### The bundle is what unlocks audio capture

Identical binary, two launch contexts:

| launch context | frames | peak amplitude | RMS |
|---|---|---|---|
| bare CLI (`adhoc, linker-signed`, `Info.plist=not bound`) | 556,032 | 0.000000 | 0.000000 |
| `.app` bundle + Info.plist, launched via LaunchServices | 559,104 | 0.757179 | 0.122199 |

The failure is silent — the IOProc fires on schedule and delivers zeroes.
No error, no dialog.

**Unresolved:** no TCC prompt was ever observed, and `TCC.db` could not
be read (needs Full Disk Access) nor `tccd` logs inspected (redacted). It
is therefore unknown whether the bundled run was *granted* or simply
never *gated*. Verify on a clean machine.

### An unfinalised CAF is still readable

`AudioRecorder` writes incrementally so that a crash costs the tail
rather than the file. That only holds if the container tolerates a
header nobody got to finish, so it was measured rather than assumed.

A process wrote 4.0 s of 48 kHz stereo through `AVAudioFile` and then
`SIGKILL`ed itself without closing the file:

| | |
|---|---|
| written before the kill | 4.000 s |
| `AVAudioFile(forReading:)` | opened without error |
| recovered | **3.925 s**, 188,416 frames |
| peak amplitude | 0.500000 (the synthesised tone, intact) |

The 75 ms lost is the block still in flight. Reproduce by killing the
app mid-recording and opening the `.caf` it leaves behind.

This is the argument for CAF over WAV: a truncated WAV carries a byte
count in its header that is confidently wrong.

### AVAudioEngine does not capture the microphone on macOS 26.5

The process tap is not the only API here that succeeds and delivers
nothing. Three shapes of the documented `AVAudioEngine` input recipe,
each over a 14 s recording, microphone grant `authorized`,
`engine.start()` returning no error:

| attempt | callbacks | frames |
|---|---|---|
| `installTap` on `inputNode`, `inputFormat(forBus:)` | 0 | 0 |
| `installTap` on `inputNode`, `outputFormat(forBus:)` | 0 | 0 |
| input → silent mixer → main mixer, tap the mixer | 0 | 0 |
| **CoreAudio IOProc on the default input device** | **1508** | **772,096** |

No error, no log line, no audio. The only evidence was the recorder's
own padding counter reading 100% — every frame of the mic channel
written as silence. Apple's forums carry the same report against
macOS 26: AVFoundation's audio-input layer failing while the HAL
underneath enumerates and runs every device normally (FB19024508,
developer forums thread 794843).

`MicCapture` therefore uses the HAL directly, as `ProcessTap` does.
After the switch, a recording with speech playing measured micPeak
0.0432 / farEndPeak 0.7356, drift +0.000%, zero padding.

### The missing TCC prompt was a missing request

`AVCaptureDevice.authorizationStatus(for: .audio)` read `notDetermined`
on every launch, and nothing in the app had ever called
`requestAccess`. macOS does not prompt on its own, so the grant was
never asked for and never given. That is almost certainly the answer to
the "no TCC dialog was ever observed" puzzle below.

Ad-hoc signing compounds it: a rebuild produces a new code identity, so
the grant resets to `notDetermined` after every `make` and the app
re-prompts. That would not happen with a stable signing identity.

### Meeting apps hold the mic from helper processes

Live audio process objects (47 total on a normal desktop):

```
com.microsoft.teams2.helper        Microsoft Teams WebView Helper
com.microsoft.teams2.modulehost    Microsoft Teams ModuleHost
com.google.Chrome.helper           Google Chrome Helper
com.tinyspeck.slackmacgap.helper   Slack Helper
net.whatsapp.WhatsApp              WhatsApp        (native, no helper)
```

Hence prefix matching. Reproduce with `Probes/dump-procs`.

### Window titles are redacted

Of 48 on-screen windows, 1 had a readable title. Every Chrome and Teams
window returned `<nil>` for `kCGWindowName`. Reading them requires the
Screen Recording grant. Reproduce with `Probes/win-titles`.

This is why Chrome disambiguation is done by audio shape rather than by
identifying the tab.

### Detection needs no permission

Enumerating `kAudioHardwarePropertyProcessObjectList` and observing
`kAudioProcessPropertyIsRunningInput` works with no TCC grant at all. The
first run immediately caught `corespeechd` (the "Hey Siri" listener)
holding the mic — a useful reminder that raw mic-acquisition is noisy and
the allowlist is not optional.

## Decisions

| # | Decision | Rationale |
|---|---|---|
| 1 | Personal single-tenant | Ad-hoc signing proven sufficient; no $99 Developer Program needed until this ships to someone else |
| 2 | Separate repo from atrium-pa | atrium-pa's CI is Python-shaped; the only coupling here is an HTTP contract |
| 3 | Far-end audio in v1 | A transcript of only your own half is close to useless for action-item extraction |
| 4 | Allowlist: Teams, Meet, WhatsApp, Zoom. No calendar | Calendar-gating would miss ad-hoc calls, which are most of them |
| 5 | No consent UX | Personal use |
| 6 | Chrome: speculative record + 60 s far-end gate | No extra permission; generalises to Teams idling with the mic open |
| 7 | Prefix match, editable JSON | Exact match matches nothing; vendors rename helpers between releases |
| 8 | 45 s debounce, 2 min merge, 3 h cap | Apps hold the mic past the call; 3 h ≈ 45 MB, well under the 300 MiB server limit |
| 9 | MCP JSON-RPC, no atrium-pa changes | A permanent REST route is added attack surface to save ~40 lines of Swift |
| 10 | Durable on-disk queue | Auto-upload means nobody is watching when it fails; lid-close mid-meeting is common |
| 11 | 7-day local retention | Enough to re-drive a failed transcription, bounded disk use |
| 12 | 48 kHz stereo local, 16 kHz mono upload | Server downmixes to mono anyway (pyannote); local keeps channels in case that changes |
| 13 | Menu bar + floating panel, no quota display | No client-readable quota endpoint exists, and adding one would reverse #9 |
| 14 | CAF for the local master, not WAV | Measured above: an unfinalised CAF reads back; an unfinalised WAV lies about its length |
| 15 | Far-end tap is the master clock, mic is slaved to it | The tap runs continuously off the output device whether or not anything is playing, so it is a timebase; the mic stream is not |
| 16 | Drift corrected by discarding the *oldest* buffered mic frames | Discarding the newest moves the offset later in the file instead of removing it |
| 17 | Client secret in the Keychain, everything else in `config.json` | The secret is account-level and bound to `client.owner_user_id`; it is not a scoped upload token and does not belong beside the recordings |
| 18 | Manual "Start Recording Now" that bypasses every gate | The gates infer "is this a meeting?" from indirect evidence; there is nothing to infer once somebody has pressed record. Also covers in-person conversations, which have no far-end at all |
| 19 | Tests as an executable, not `swift test` | XCTest and swift-testing ship with Xcode; the project otherwise needs only the Command Line Tools, and a 10 GB IDE is a poor prerequisite for checking that an upload works |
| 20 | CoreAudio HAL for the microphone, not AVAudioEngine | Measured above: AVAudioEngine delivers zero callbacks on 26.5. Consistent with `ProcessTap`, and with the project's rule that the low-level API is the one that works |
| 21 | Request the microphone grant explicitly on launch | macOS does not prompt on its own; without the call the status stays `notDetermined` and capture silently produces nothing |
| 22 | Panel shows one consolidated bar set, not two | It answers "is this recording", and one tall bar that moves when anybody speaks answers it better. Per-stream detail moved to the log line, which is where it is read after the fact anyway |

### Rejected

- **ScreenCaptureKit for far-end audio** — requires the full Screen
  Recording grant. Process taps need only audio-capture consent and can
  be scoped per-process.
- **Reading Chrome tab titles** — same grant, same objection.
- **A REST facade on atrium-pa** — considered, then rejected on attack
  surface. Reversible if a second client ever appears.
- **Calendar/EventKit integration** — would not have fired for the
  ad-hoc calls that matter most.
- **Objective-C** — CoreAudio is a C API and identical from both; modern
  AppKit/AVFoundation are Swift-first. The realtime constraint is real
  but is answered by C, not Objective-C.

## Open risks

1. **Clock drift** between mic and tap streams over a long call.
   `kAudioSubTapDriftCompensationKey` is enabled; unverified over hours
   *on real hardware*. `StreamAligner` now handles it explicitly and is
   simulated in `make test` at ±0.05% over an hour — one hour of a fast
   mic clock leaves 4,800 frames (100 ms) of backlog and writes no
   silence; one hour of a slow one pads 86,400 frames and discards
   nothing. What is still unproven is the *rate* real hardware drifts
   at, which only a long call with an external interface will show.
   `micPaddedFrames` / `micDroppedFrames` in the session log line are
   the measurement to collect.
2. **Far-end threshold** `instantPeak > 0.002` is a guess pending real
   meetings.
3. **TCC prompt behaviour** on a clean machine. Partly answered: the
   microphone grant was never being *requested*, and once it is, the
   status goes to `authorized` and capture works. What is still unknown
   is the audio-capture (process tap) grant — no dialog has been seen
   for it even now, so whether the bundled run is granted or simply
   never gated remains open. `~/Library/Logs/AtriumMac.log` records the
   microphone status on every launch; the tap has no equivalent API to
   ask.
