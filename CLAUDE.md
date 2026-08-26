# atrium-pa-mac — agent guide

Menu-bar macOS app that detects when a meeting app grabs the microphone,
records both sides of the conversation, and uploads the audio to
**Atrium PA** for transcription.

Companion to `atrium-pa` — check it out alongside this one and read it
for the ingest contract.
**This project makes no changes to atrium-pa**; see §"The upload
contract" for why that is a deliberate constraint, not an accident.

---

## The one thing that will waste your day

**A bare binary cannot capture system audio. It fails silently.**

The process tap is created successfully, the aggregate device builds,
the IOProc fires on schedule and delivers a perfectly-timed stream of
**zeroes**. Nothing errors. No permission dialog appears. If you debug
this as an API problem you will get nowhere, because the API is fine.

Measured with the *identical binary*, only the launch context differing:

| launch context | frames delivered | peak amplitude |
|---|---|---|
| bare CLI, ad-hoc signed, `Info.plist=not bound` | 556,032 | **0.000000** |
| `.app` bundle + Info.plist, via LaunchServices | 559,104 | **0.757179** |

So:

* **Always `make run`**, never `swift run` or `./.build/.../AtriumMac`.
  `make run` bundles, signs, and launches through LaunchServices. Exec'ing
  the binary directly makes the *terminal* the responsible process for
  TCC.
* **Ad-hoc signing is enough** (`codesign --sign -`). You do not need a
  paid Developer ID for local work. `make verify` confirms the bundle can
  hold a grant.
* **Check `peakAmplitude` before trusting any recording.** A run that
  produces a file of the right length full of zeroes is the expected
  failure, and it is invisible unless you look.

The `RecordingPanel` exists largely to make this failure visible: it
turns its bars red after ~2 s of sustained silence on *both* streams.
(The per-stream split it once had is gone; the diagnostic moved to the
log — see `HistogramView`.)

## The second silent failure: AVAudioEngine does not capture here

The process tap is not the only API that succeeds and delivers nothing.
`MicCapture` was an `AVAudioEngine` input tap first. On macOS 26.5 it
never fired. Measured, each over a 14 s recording with the microphone
grant reading `authorized` and `engine.start()` returning no error:

| attempt | callbacks | frames |
|---|---|---|
| `installTap` on `inputNode`, `inputFormat(forBus:)` | 0 | 0 |
| `installTap` on `inputNode`, `outputFormat(forBus:)` | 0 | 0 |
| input → silent mixer → main mixer, tap the mixer | 0 | 0 |

Three shapes of the documented recipe, no error, no log line, no audio.
Apple's forums carry the same report against macOS 26 — AVFoundation's
audio-input layer failing while the HAL underneath enumerates and runs
every device normally (FB19024508, developer forums thread 794843).

`MicCapture` now uses a CoreAudio IOProc on the default input device,
exactly as `ProcessTap` does. **Do not "modernise" it back to
AVAudioEngine.** After the switch, the same test recorded
`micFrames 772096 in 1508 callbacks`, micPeak 0.043 / farEndPeak 0.736.

`AVAudioConverter` is still used, but only on the consumer side of the
ring — the device may be at 44.1 kHz or at 16 kHz on a Bluetooth
headset, and resampling on a realtime thread would mean allocating on a
realtime thread.

## Ask for the microphone grant explicitly

`AVCaptureDevice.requestAccess(for: .audio)` is called on launch. Without
it the status sits at `notDetermined`, no dialog ever appears, and audio
capture quietly does not work. This is very probably the answer to the
project's long-standing "no TCC dialog was ever observed" puzzle.

Note for development: **ad-hoc signing gets a fresh code identity on
every rebuild**, so the grant resets to `notDetermined` after each
`make`, and the app re-prompts. That is expected here and would not
happen with a stable signing identity.

The current status is logged on every launch, so the answer is in
`~/Library/Logs/AtriumMac.log` rather than in a guess.

## Diagnostics go to a file, not to `NSLog`

`NSLog` writes to stderr, and an app launched through LaunchServices has
no stderr — which is the *only* way this app is ever launched, because a
bare binary cannot hold the audio-capture grant. So the one launch
context that works is also the one with no diagnostics. `Log.write`
appends to `~/Library/Logs/AtriumMac.log` (menu: **Open Log**).

It writes **synchronously**. It was asynchronous once, which lost every
line written from `applicationWillTerminate` — precisely the moment a
log is for.

## Bundle IDs: match on prefix, never exact

Every meeting app grabs the mic from a **helper process**, not its main
bundle. Measured on macOS 26.5:

| app | bundle ID that actually holds the mic |
|---|---|
| Microsoft Teams | `com.microsoft.teams2.helper` |
| Google Meet (Chrome) | `com.google.Chrome.helper` |
| Slack | `com.tinyspeck.slackmacgap.helper` |
| WhatsApp | `net.whatsapp.WhatsApp` (native — no helper) |

An exact-match allowlist on main bundle IDs matches **nothing**.
`Allowlist.matches(bundleID:)` is prefix-based for this reason. Run
`Probes/dump-procs` to see the live list on any machine.

## The per-process mic listeners do not fire; watch the device instead

`MicMonitor` installs a listener on `kAudioProcessPropertyIsRunningInput`
for every audio process. On macOS 26.5 those listeners **never fire**.
Measured: **46 attached, 0 refused, 0 invoked** — not once, on either
edge, including this app's own capture. Registration succeeds and the
block is simply never called.

That is why every emission logs which mechanism noticed it. The provenance
line was written as a warning that listeners *might* be unreliable;
counting it is what proved they are dead, and a WhatsApp call taking 30
seconds to record is what sent somebody looking.

**The device-level listener does work.** A listener on
`kAudioDevicePropertyDeviceIsRunningSomewhere` for the default input
device fired **166 ms** after capture began. It cannot say *who* started
using the microphone — so the device answers "when" and a scan answers
"who".

Two things that listener needs to stay correct:

* Re-attach when `kAudioHardwarePropertyDefaultInputDevice` changes.
  Connecting AirPods makes a different device the default, and a listener
  on the old one hears nothing. Without this the instant edge works until
  somebody puts headphones on and then quietly stops.
* Keep the poll. It catches the case a device edge cannot see — a process
  starting or stopping while the device is *already* running for someone
  else — and it is what noticed the listeners were dead in the first
  place.

A poll pass costs **58 ms for 46 processes**, essentially all of it the
per-process property read; listing them is 0.0 ms. So it is a backstop
again at 10 s idle / 30 s while recording, rather than the 3 s it needed
when it was the only detector.

Keep the per-process listeners installed. They cost nothing while silent,
and if a later macOS delivers them the provenance line will say so.

## Chrome is opaque, and that is handled by audio, not by identity

`com.google.Chrome.helper` carries no tab identity, and window titles are
redacted without the Screen Recording grant (verified: 47 of 48 windows
returned `<nil>`). So a Google Meet call is indistinguishable from any
other site using the mic.

The resolution is **not** to ask for more permission. It is
`SessionPolicy.farEndConfirmationWindow`: record speculatively, and
discard the session if no far-end audio appears within 60 s. A real call
has two-way audio; a mic test does not. This generalises — it also
catches Teams sitting idle holding the mic.

## `ready` is not the end of the speaker question

`get_upload_status` says `ready` when the transcript is readable. Voice
clustering runs on *after* that, and until it finishes an unnamed voice
arrives with **no `voice_cluster_id`** — which cannot be named through
the API, because naming is addressed by cluster.

Measured on capture 12359: at the moment the queue stopped polling, two
unnamed speakers, neither with a cluster. Minutes later both had one and
one had been matched to a person. Nothing re-asked, so the window said
"nothing to name" while the web UI showed two unnamed voices. Both were
true about different things, which is the worst kind of disagreement.

Two consequences, both handled:

* `speakerDescription` distinguishes **"2 unnamed"** (actionable) from
  **"2 unnamed, still matching"** (known, not yet actionable) from
  **"nothing to name"** (the server is offering nothing). Collapsing the
  middle case into the last one is what produced the contradiction.
* `followUpOnSpeakers()` re-asks for 30 minutes after `completedAt`, at
  most every 2 minutes, for any `ready` item with nothing nameable. When
  voices become nameable it posts a second notification — the first one
  said "ready to read" because at that moment there was genuinely
  nothing to ask for.

**Dismissing a voice no longer exists.** Atrium PA removed it: it only
ever reached two of six read surfaces, so a "dismissed" voice still
appeared in both labeling queues and the web UI reported it as merged or
deleted when it was neither. Three clusters on the whole deployment had
ever been dismissed, all from testing the feature.

`unnameSpeaker` alone is now the whole of "undo this naming", and one
call is the better behaviour anyway — the reason to unname a voice is
almost always that it is somebody *else*, not nobody, so having it come
back and be asked about is the point.

The replacements are **not** drop-ins. `reject_speaker` says *"this
clustering is wrong"* — it nulls turn→cluster and keeps turn→person,
making no claim about who was speaking — where `unname_speaker` says the
opposite: the voice is fine, the name is wrong. Both `reject_speaker`
and `wipe_person_voice_prints` are irreversible, refuse without
`confirmed: true`, and reach **every recording the voice appears in**.
`preview_voice_removal` is the read-only look before either, and its
`recordings` count cannot be recomputed afterwards — nulling
`voice_cluster_id` destroys the evidence of what was touched.

**A guessed name is a question too.** A voice matched at `low` or
`medium` confidence appears in `speakers[]`, not `unknown_speakers[]` —
the server considers it answered — so reading only the unknown list shows
nothing to do while the web asks for a confirmation. Capture 12359's
Speaker 1 was applied as a real person on a **66% "low"** match, across
all 43 turns they spoke.

`provisionalSpeakers(transcriptID:)` reads them out of `speakers[]`,
filtered to `anchored == false` and a low or medium band — a `high` match
is anchored by the server and carries no verify link by design, so
re-asking would be nagging. Confirming one is just `name_speaker` with
that person: a provisional match leaves `cluster.person_id` unset, so the
"already named" refusal does not apply.

The naming window asks about both, guesses first, because a guess has a
possibly-wrong answer already written across every turn.

## The Speakers column is the server's answer, not ours

`QueueItem.namedSpeakers` is a list of names this app *asked for*. It was
also what the window displayed, on the reasoning that reading the roster
back needed `pa.read` and this app did not hold it.

That reason expired when `pa.read` arrived, and the two had already
drifted. Capture 12359 recorded `["Dana Ellis", "Sam Okafor"]`
locally while Atrium PA had **Alex Rivera** and **Sam Okafor
(#2571)** — and the column showed the local copy, in preference to
everything else, with nothing ever comparing them. A name this app
requested is not evidence of a name that was applied: the request can
fail, the person can be merged or renamed, or somebody can change it in
the web UI.

`knownSpeakers` is the roster from `get_transcript`, refreshed alongside
the unnamed and unconfirmed lists, and it is what the column reads.
`namedSpeakers` stays as a record of what was done from this Mac, which
is the first question when a name turns out to be wrong.

**`anchored` is what settles a name**, not the percentage. An anchored
match is one somebody committed to and is shown as a name; an un-anchored
low or medium match is counted as work, however confident it looks.

`backfillRosters()` reads the roster once at startup for finished
recordings that have never had one, because the 30-minute follow-up
window will never revisit anything older.

## One field decides who a voice is

The naming window had three inputs — a suggestion menu, a search result
menu, and a name field — and resolved them by precedence: search beat
suggestions beat what was typed. So a name typed while a suggestion was
still selected named the suggestion, silently, and nothing on screen said
which of the three would win.

Now the menus **write into the name field** and the field is the only
input `chosen` reads. Editing it by hand clears the remembered person id
(`controlTextDidChange`), because "Alex Rivera" edited to "Alex
Riveras" is a different person and must not still name person #5.

**A discard is not the end of the question.** If the app still holds the
microphone, the controller starts a fresh candidate and re-arms the
window. Without that, joining a meeting early lost it entirely: Teams
grabs the mic on join, a lobby is silent, the window expires — and no
further mic event ever arrives, because the app never let go. Nothing
restarted when people began talking. The cost of re-arming is one
discarded file per window while you wait.

**Do not "fix" this by requesting Screen Recording.** Avoiding that grant
is why the project uses CoreAudio process taps instead of
ScreenCaptureKit in the first place.

## Never touch the keychain from the main thread

`SecItemCopyMatching` is a synchronous round trip to securityd, and when
securityd decides to ask for the login password it raises an **app-modal**
dialog with that call still on the stack. `refreshMenu()` read
`Keychain.clientSecret` directly once. The result was an app that
launched, wrote `panel shown`, and then did nothing at all — no window,
no menu, no further log line. Sampled:

```
AppDelegate.refreshMenu()  AppDelegate.swift:559
  Keychain.clientSecret(for:)  Keychain.swift:120
    SecItemCopyMatching  ... mach_msg_trap        ← 1839 of 2497 samples
```

`AppDelegate.hasStoredSecret` now caches the answer and
`refreshCredentialState()` refreshes it on a background queue.
`make trust-keychain` stops the prompt appearing at all; the cache stops
it taking the UI with it when it does.

## The app is `.regular`, not an accessory

It was `LSUIElement` once. A menu-bar-only app cannot be brought to the
front, which means no ⌘Q, no Dock icon, and no way to reach the window
listing recordings. `main.swift` sets `.regular` and installs
`MainMenu` — a SwiftPM executable has no nib, so nothing supplies the
App, Edit and Window menus otherwise, and without the Edit menu ⌘V does
nothing in the field where you type somebody's name.

`ActivityWindow` opens on launch. This is **not** conditional on how the
app was started: `NSApplicationLaunchIsDefaultLaunchKey` looked like the
way to stay quiet when macOS starts the app at login, but measured on
26.5 it reads false for a plain `open` too, so it cannot tell the two
apart.

`LoginItem` (`SMAppService.mainApp`) reports `notFound` until the first
successful `register()` — that is "never registered", not "cannot be".

## A queue file outlives the build that wrote it

`QueueItem` has a hand-written `init(from:)`. The synthesized one throws
on a file missing a field added since it was written, and an item that
does not decode is a recording that has silently left the queue — the
one thing a durable queue exists to prevent. Adding `namedSpeakers`
orphaned a real, already-uploaded capture exactly this way. Fields
present in the first version stay required, so a genuinely corrupt file
is still reported.

## The render thread is not ordinary Swift

`ProcessTap`'s IOProc block runs on a CoreAudio realtime thread. It must
not allocate, lock, or trigger ARC. Swift cannot prove absence of those,
which is why the hand-off buffer lives in C with C11 atomics
(`Sources/CRingBuffer`). Keep it that way.

Two traps already hit in this codebase:

1. **`SIGBUS` from an escaping pointer.** Taking a pointer to
   `AudioBufferList.mBuffers` via `withUnsafePointer { $0 }` lets it
   dangle. Use `UnsafeMutableAudioBufferListPointer(...)`. The crash is
   immediate, exit 138, and swallows buffered stdout so you see *no*
   output at all.
2. **Locks in the callback.** The original probe took an `NSLock` in the
   render block. Fine for a probe, wrong here — that is what
   `arb_write()` replaced.

`arb_overruns()` counts frames the producer had to drop. Non-zero means
the consumer is too slow. Surface it; do not paper over it.

## Recording: the tap is the clock, the mic is held against it

`AudioRecorder` writes 48 kHz stereo CAF — mic left, far-end right —
straight through on a 40 ms timer. No accumulate-then-flush stage, so a
crash costs the last drain interval and nothing else. **Measured**: a
process `SIGKILL`ed after writing 4.0 s left a file that
`AVAudioFile(forReading:)` opened and read back at 3.925 s, peak 0.5.
CAF is what makes that work; a truncated WAV has a byte count in its
header that is simply wrong.

The two streams do not share a clock. The far-end tap runs off the
output device and delivers frames continuously whether or not anything
is playing, so it is the master timebase; the mic is held against it by
`StreamAligner`, which pads when the mic is short and discards the
*oldest* buffered frames when it runs long. Discarding the oldest is the
whole point — discarding the newest would move the offset later rather
than remove it.

Two counters, `micPaddedFrames` and `micDroppedFrames`, are in every
session's log line. Do not read them as "errors". On a fast mic clock a
large `dropped` is the correction *working*; what would be wrong is a
growing backlog, or `padded` climbing on a stream that is keeping up.
`StreamAligner` is in `AtriumCore` precisely so this can be simulated —
`make test` runs an hour of ±0.05% clock error in about a millisecond.

Steady-state consequence worth knowing: correction only starts above
`jitterSlack`, so once a fast mic clock is being corrected the mic
channel sits ~100 ms behind the far-end. That is a constant, not a
drift, and the file is downmixed to mono before upload anyway.

## A microphone that stops is silent about stopping

`MicCapture` resolves the default input device once at `start()` and
binds its IOProc to that device id. When the default input changes
mid-recording, the old device stops, the callback stops being called, and
**nothing errors** — the recording just ends up short.

Measured on a 13-minute WhatsApp call: far end 832.6 s against wall
clock, microphone 802.4 s. Every callback delivered a full 480 frames, so
there was no gap in the middle; the stream simply ended at 17:05:08,
fourteen seconds after the other app released the microphone and thirty
before the session did. The far-end tap was unaffected because it runs
off the output side.

**The encoder used to hide this.** `combine()` reconciles the two lengths
by resampling the microphone from its *effective* rate — frames over the
far end's duration — which absorbs genuine clock drift exactly. Applied
to a stream that lost audio it stretches the whole recording to cover a
hole in one place: 46260 Hz against a nominal 48000, slowing every word
by 3.6% and dropping the pitch about 62 cents. It is also a plausible
reason a voice matched its own print at only 66%.

So `maximumDriftCorrection` caps it at 0.5% — an order of magnitude above
any crystal, far below any loss. Inside the cap it is drift and is
absorbed; outside it the nominal rate is used and the mix loop leaves
silence where the audio is missing. Silence in the right place beats
speech in the wrong one.

Three things now say so out loud: the session line reports
`MICROPHONE SHORT BY <n>s`, `MicCapture` logs when the default input
device changes mid-recording, and it tracks how long the IOProc has been
delivering nothing. None of that existed, which is why a 30-second hole
had to be found by arithmetic on a frame count.

**The capture follows the default input now.** On a change it tears the
IOProc down, resolves the new device and starts again —
`MicCapture.followDefaultInputDevice`. Two things make that safe:

* `outputRate` is fixed at the first `start()` and `drain()` resamples to
  it, because `AudioRecorder` opened the master file at that rate and a
  file cannot change rate halfway through. Measured switching to AirPods
  mid-recording: the device arrives at **24 kHz** against the built-in
  48, and the file stays 48. The resampling is on the consumer side, as
  everything must be — allocating on a CoreAudio realtime thread is the
  rule this design is arranged around.
* The listener is removed before it is re-added. `start()` runs again on
  every switch, and a second registration means two rebinds per change,
  each tearing down what the other just built.

The rebind costs about **a second** of microphone audio, which is the
device teardown and spin-up. That is reported rather than hidden.

**A residual that stopped mattering.** The drift cap is a percentage,
and a lost second is not proportional to anything — so a gap under 0.5%
of the recording is absorbed as drift rather than padded. That was worth
worrying about while a device switch could cost thirty seconds: in an
hour, anything up to eighteen would have slipped under the cap and been
smeared across the whole recording.

It no longer can. Following the device bounds a switch to about a second,
and the two-second stall check bounds an unnoticed stop to two or three.
A few seconds inside an hour is under 0.1% — inside the cap, absorbed,
and genuinely inaudible.

So this is not worth fixing, and the reason is worth keeping: the fix was
never needed on its own terms. It was needed because something else was
broken, and fixing that removed the input this depended on. If the
session line ever reports a large shortfall again, revisit it — the
numbers are all in the log.

## The log is for the pipeline, not for the window

87% of the log file was once a single line — `activity: listing N
recording(s)`, written every five seconds by the window's refresh timer,
2447 times out of 2807. Meanwhile the upload path logged almost nothing:
no request, no PUT, no state changes. The file recorded that a window was
open and not that a meeting had been uploaded.

Two rules that follow:

* **A repeating check logs transitions, not answers.** The window logs
  only when its summary changes; `poll` logs only when the pipeline's
  state changes, not on each of the thirty-second polls that return the
  same one.
* **A diagnostic added to chase a bug becomes an alarm when the bug is
  fixed.** The settings-pane geometry lines were a running commentary
  while the layout was wrong; they now fire only when the content is
  *not* where it should be.

What the upload lane says now: queued with its size, the URL request,
the capture id, bytes and throughput of the PUT, each pipeline
transition, ready with its transcript id and how long the whole thing
took, and every failure with its retry interval.

## Neither stream is the length of the recording

`combine` takes the far end as the timebase for *drift*, because its
device runs continuously whether or not anything is playing. It used to
take it as the **length** as well, and those are not the same thing.

Measured: a 38-second recording whose far-end tap died at 19 seconds.
Using the far end as the length discarded 19 seconds of microphone —
silently, into a file that looked complete.

So the length is the reference only when the disagreement was small
enough to absorb as drift, in which case the microphone has been
resampled to fit it anyway. Otherwise one of the two stopped early and
the mix runs as long as the *longer*, with silence where the other is
missing. The log says which one, because it is not always the
microphone.

## Following a device is three problems, not one

Both captures now follow their device. Getting there found three things
that only appear when you try it.

**Watching the device property is not enough.** AirPods going away took
the aggregate's sub-device with them and the far end stopped, while
`kAudioHardwarePropertyDefaultOutputDevice` did not change for another
**28 seconds**. So both streams are checked every two seconds for having
gone *quiet*. That works for the far end precisely because the tap runs
continuously whether or not anything is playing: silence means the stream
is gone, not that the meeting paused.

**Creating an aggregate re-fires the property you are listening to.** The
first rebuild triggers the next — measured, ten in under two seconds,
each costing far-end audio. `ProcessTap` compares the output device UID
before acting, which is the guard `MicCapture` always had, plus a
re-entrancy guard because the re-fire arrives while still inside the
rebuild.

**A rebuild can silence the microphone.** Creating an aggregate is the
hardware reconfiguration that knocks over an input client — the
documented reason the tap starts before the microphone. Mid-recording
that hazard lands in the middle, so `MicCapture.restartIfStalled` exists
and the recorder calls it after a rebuild.

## A device that lies about its rate

An aggregate reports the rate it had when it was created, and a Bluetooth
link settles afterwards. Measured: the aggregate claimed **48000 while
delivering 16571** — AirPods in hands-free mode run at 16 kHz. Written
into a file that says 48000, that audio is a third of its true length and
plays three times too fast.

`checkDeliveredRate` corrects it, but only when **two independent
sources agree**: the device's own rate re-read a couple of seconds after
the aggregate was built, and the rate frames are actually arriving at.
The device's figure is the one adopted — it is exact where a frame count
is approximate — and the measurement's only job is to corroborate it,
within 15%.

Both halves of that are scar tissue.

Correcting on the **measurement alone** ruined a recording. The window
started at `start()`, so it counted the aggregate's spin-up before its
first frame as slow delivery: a healthy 48 kHz device read as 18924 Hz,
snapped to 16000, and the far end came out three times too long and an
octave and a half down. The window now starts after frames are flowing.

**Not correcting at all** was worse, and that is the part that was got
wrong on purpose. After the above, the correction was reverted to
report-only on the reasoning that an uncorrected mismatch merely costs
some far-end audio while a false correction ruins the channel. That
asymmetry was imaginary. Measured on a real 552-second Teams call:

```
mic 551.2s @24000Hz   far 275.6s @48000Hz   farEndPeak 0.917949
```

Exactly half. Nine minutes of conversation written at double speed, an
octave up, unusable — not "short", *destroyed*. Leaving it alone is not
the conservative option; it is just a different way to lose the far end.

**Every second before it fires costs half a second of alignment.** Frames
arriving at 24000 into a file labelled 48000 take half the space they
should, so everything after the correction sits early by half the
exposure, for the whole recording. Measured on the same switch:

| baseline at | corrected after | mic − far |
|---|---|---|
| +2 s, 3 s window | 4.9 s | 2.44 s |
| +0.5 s, 1.5 s window | 1.9 s | 0.92 s |

A 2:1 ratio needs no precision, so the window is as short as it can be
while still excluding the spin-up.

**It has to keep asking.** A Bluetooth link settles on its own schedule,
and a single check that arrives before the device admits its real rate
finds nothing, never asks again, and writes the entire call at the wrong
speed. So a check that corrects nothing schedules another, up to six
times; adopting a rate stops it.

Progression across five runs of the same switch, which is the honest
measure of whether this converged:

| | rebuilds | far end short by |
|---|---|---|
| nothing following | — | 61.4 s |
| device property only | 1 | 61.4 s, noticed 28 s late |
| + stall detection | 10 | 11.9 s |
| + UID guard | 1 | 15.4 s |
| + correcting a corroborated rate | 1 | 0.92 s |

## Two retention windows, because the two files are not worth the same

The 48 kHz `.caf` masters are **41×** the size of the uploaded AAC —
measured on a 36-second capture, 6.9 MB against 170 KB, so 690 MB an hour
against 17. `masterRetentionDays` defaults to `0`: they go as soon as the
transcript is ready. `localRetentionDays` defaults to **negative, meaning
never** — the `.m4a` is small, playable and re-uploadable, and after
Atrium PA sweeps its own vault at ~90 days it is the only copy of a
meeting anywhere.

Negative is the "keep it" sentinel so that `0` keeps its literal meaning.
Both windows only ever touch a `ready` item; a failed upload keeps its
audio indefinitely.

`AtriumConfig` has a hand-written `init(from:)` for the same reason
`QueueItem` does, and here the stakes are higher: `load()` answers a
decode failure with `.defaults`, which has no `clientID`, so one added
field would have signed every install out with nothing logged.

## The app asks whether it should still be recording; it never decides

Nothing in this app can tell a three-hour meeting from an app that
grabbed the microphone and never gave it back. `SessionPolicy` says it
plainly: Teams and Zoom hold the input device well past the end of a
call, and Zoom keeps it running while muted. The person in the room can
tell, so after an hour — then every half hour — a passive notification
asks.

**Silence means carry on.** The reminder has one button, and pressing it
is the only way it ever stops anything. A meeting this app failed to
record cannot be recovered; an hour of wasted disk can. A unit test
asserts the session machinery has no threshold that ends a recording on
its own.

## Starting a recording by hand

Detection covers the allowlist. **Start Recording Now** in the menu
covers everything else — a conversation in the room, a call on a phone
on the desk, an app nobody has added yet. A manual session skips every
heuristic in `SessionPolicy`: no far-end gate (an in-person conversation
has no far-end at all), no 90 s floor, no merge on reconnect, and an app
grabbing and releasing the mic cannot end it.

It is also the only way to see the panel and the meters without joining
a real call, which makes it the first thing to reach for when checking
whether capture works on a machine.

## Deleting, and the three things it does not do

`Delete Recording…` removes the audio, the masters and the queue entry
locally, and optionally tells Atrium PA to delete its copy
(`delete_capture`, scope `pa.ingest:delete`). The server call goes
**first**: if it fails the item is still here to retry from, whereas
deleting locally first would leave a capture nothing on this Mac has a
row for.

Three things the dialog has to say, none of which are obvious and all of
which came from atrium-pa correcting the request in
`docs/atrium-pa-delete-capture-request.md`:

1. **It is a soft delete**, reversible for ~90 days. Which is why
   `deleted` is a required boolean rather than a verb — `deleted: false`
   restores, and that is the only clean way back.
2. **It does not erase the audio.** The vault is swept by a separate job
   on file age, independent of deletion, so a deleted capture's audio
   sits there until its own TTL runs out. Saying "deleted" and meaning
   "gone" is the failure this note exists to prevent.
3. **Re-uploading the same file afterwards fails, and fails opaquely.**
   The duplicate check skips deleted rows, so the upload is not
   recognised as a duplicate, proceeds, and collides with a dedup key
   that is deliberately retained — an internal error with a trace id, for
   the whole grace window. "Delete it and send it again" is not a
   recovery; restoring is.

`pa.ingest:delete` is deliberately absent from the server's discovery
document, so a client that registers without naming its scopes never
gets it. `OAuthLogin.register()` sends `scope` explicitly, which is what
makes this work — and is load-bearing rather than incidental.

## One MCPClient, because the server rotates refresh tokens

Atrium PA rotates refresh tokens and detects reuse: presenting one that
has already been rotated revokes **the whole chain**, and everything
afterwards fails with `invalid_grant — refresh_token has been revoked`.

Four places used to build their own `MCPClient` — the queue, the launch
check, naming, deleting — each with its own in-memory bearer, all reading
the same refresh token out of the keychain. Two of them refreshing at
once is not a duplicated request, it is a signed-out account. Measured on
a launch where the roster backfill and `verifyLoginOnLaunch` overlapped.

Two defences, and both are needed:

* `MCPClient.shared(config:)` returns one instance per
  server-and-client-id, so there is one token and most refreshes never
  happen. `forgetShared()` on sign-in, sign-out and any change of server
  or client id — a cached client holds a bearer for the old identity.
* `accessToken()` is **single-flight**. An actor serialises calls but not
  across an `await`: two callers can both find no valid token, both
  refresh, and the second is a reuse. The first publishes its `Task`
  before suspending and the rest wait on it.

## Saving a transcript

`get_transcript_download` returns a URL good for 300 seconds serving the
whole document — every turn, cleaned and raw, plus the roster. **No
Authorization header**: the token is in the path, exactly as it is for an
upload URL.

`TranscriptDocument` renders it into ~/Downloads — Markdown or plain
text, per `AtriumConfig.transcriptFormat` — because the JSON is the
archival artefact and nobody reads it. Turns join to speakers
on `key`, and a heading is written per *change* of speaker rather than
per turn.

An unconfirmed name is written as unconfirmed, with its percentage, every
time it appears — atrium-pa is explicit that a low or medium attribution
"may be wrong", and a transcript that has left this app gets quoted and
forwarded long after the confidence is out of sight.

## The upload contract

Atrium PA's ingest lane already exists (F-26) and **this project adds
nothing to it**:

1. `upload_audio(filename, content_type, size_bytes, title?, occurred_at?, language?)`
   over MCP JSON-RPC → returns `{capture_id, upload_url}`.
2. `PUT` the bytes to that URL. The token *is* the auth — no bearer.
3. Poll `get_upload_status(capture_id)` until ready.

Constraints that are already enforced server-side, so respect them here:

* **300 MiB per file** (`upload_audio_max_bytes`). A 3-hour recording at
  16 kHz mono AAC is ~45 MB, hence `SessionPolicy.maxDuration`.
* **Upload token TTL is 30 minutes.** On retry, **re-mint** the token;
  never retry a stale URL.
* **No MIME allow-list** server-side — validation is "does ffmpeg decode
  it". `.m4a` is fine.
* Audio is swept from the server vault after ~90 days by a
  provider-neutral retention job.

Auth is OAuth `client_credentials` bound to `client.owner_user_id`. Mint
the client in atrium-pa's admin UI (`/api/pa/admin/oauth-clients`); store
the secret in the Keychain, never in the repo or the config file.

**Do not add a REST endpoint to atrium-pa** to make this nicer. That was
considered and explicitly rejected: for a single personal client it is
permanent added attack surface to save ~40 lines of Swift.

### Where the credentials live

* **base URL and client ID** → `config.json`, next to `allowlist.json`.
  Plain text the user is meant to read. **There is no default base URL** —
  a checkout should not arrive pointing at somebody's deployment, and an
  empty one is what makes the connection prompt appear on first launch.
* **client secret** → the login Keychain, service
  `com.atrium-mac.capture.oauth`, account = client ID. Nowhere else.
  It is an account-level credential bound to `client.owner_user_id`, not
  a scoped upload token, so it must not sit in a file beside the
  recordings it protects. A unit test asserts `config.json` never
  contains the word "secret".
* Entered through **Atrium PA Connection…** in the menu. *Save & Test*
  mints a token immediately and says whether it worked, so a wrong
  credential is found now rather than in three hours when a meeting
  fails to arrive.

The secret field is never pre-filled on reopen — blank means "keep what
is stored", which is both the safe default and the honest one.

### `UploadQueue`, and the two awkward intervals

One JSON file per item under `Queue/`, written atomically. Adding an
item is one rename; a half-written file loses one recording rather than
the queue.

* **A retry never reuses an upload URL.** It restarts at `upload_audio`
  and mints a fresh one. Safe even if the previous attempt actually
  succeeded, because ingest is keyed on the sha256 of the bytes — an
  identical re-upload returns the existing capture instead of
  transcribing twice.
* **`capture_id` is persisted before the PUT.** A crash mid-transfer
  otherwise leaves a capture whose id we have forgotten.
  `get_upload_status` resolves it: `awaiting_upload` means the bytes
  never landed, so the item goes back to `pending`.

Retention sweeps only `ready` items. A **failed** upload keeps its audio
indefinitely — it is the only copy, and deleting it would make the
failure permanent.

## Tests: `make test`, not `swift test`

XCTest and swift-testing both ship with Xcode. This project builds with
the Command Line Tools alone, so `swift test` does not work here at all
and the tests are an ordinary executable
(`Sources/AtriumSelfTest`, `make test`). No discovery, no parallelism,
no XCTest reporting — an exit code and 41 assertions that run anywhere.

`AtriumCore` exists to make that possible: everything that does not
touch AppKit or a capture device lives there, and both the app and the
test runner depend on it.

**Capture is deliberately untested there and cannot be tested there.** A
bare binary gets a stream of zeroes from the process tap, so an
assertion that audio flows would fail in the test runner and pass in the
real app — worse than no test. That question belongs to
`make -C Probes bundle && open Probes/Probe.app`.

`make test-live` uploads for real: mints a token, speaks a clip with
`say`, encodes it through the real encoder, PUTs it, and polls until the
transcript is ready. It leaves a real capture in the transcript list,
which is why it never runs by default. Credentials come from
`ATRIUM_BASE_URL` / `ATRIUM_CLIENT_ID` / `ATRIUM_CLIENT_SECRET`, falling
back to the saved config plus the Keychain. Prefer the environment: the
Keychain item was written by the ad-hoc-signed `.app`, and a different
binary reading it can raise an interactive prompt — a test that blocks
on a dialog is not one you can script.

## Settled design decisions

Do not silently revisit these; they came out of a full design review.

| Decision | Outcome |
|---|---|
| Audience | Personal, single-tenant. Ad-hoc signing, no Developer ID |
| Triggers | Teams, Meet-in-Chrome, WhatsApp, Zoom. **No calendar integration** |
| Chrome disambiguation | Speculative record + 60 s far-end confirmation |
| Allowlist | Bundle-ID prefix match, user-editable JSON |
| Session bounds | 45 s end-debounce, merge within 2 min, 3 h hard cap |
| Transport | MCP JSON-RPC. Zero atrium-pa changes |
| Failure handling | Durable on-disk queue, finalize on sleep, re-mint token |
| Local retention | Masters dropped once uploaded, `.m4a` kept for ever |
| Format | 48 kHz stereo local (mic L / far-end R), 16 kHz mono uploaded |
| UI | Main window + menu bar + small always-on-top panel with live spectrum |
| Consent UX | None — personal use |

Note the format split: the server downmixes to 16 kHz mono anyway
(pyannote runs there), so stereo upload buys nothing *today*. The local
copy keeps the channels separate in case diarization later learns to use
them.

## Handing it to somebody else

**The build is universal**, so it runs on Intel Macs as well as Apple
Silicon. They run macOS well past this app's 14.2 floor, and an
arm64-only build refuses to launch on them saying nothing useful; the
cost of including them is about 1.8 MB. `make ARCHS=arm64` builds only
for this machine when iterating.

One trap that is guarded rather than remembered: a multi-arch build does
**not** populate `.build/release/`. That path stays single-arch, so the
hardcoded `BIN` bundled an arm64-only binary out of a universal build
and said nothing — measured, `lipo -archs .build/release/AtriumMac`
still reported `arm64` after `swift build --arch arm64 --arch x86_64`.
`BIN` now asks SwiftPM with `--show-bin-path`, and `bundle` refuses
outright if the binary it copied is missing an architecture that was
asked for. **Intel is untested** — there is no Intel Mac here — so it is
built, signed and notarized for x86_64 but never run on it.

`make dmg` writes `build/Atrium PA Capture <version>.dmg` containing the
app and a symlink to `/Applications` — the drag-and-drop install every
Mac user already knows. `hdiutil` and `ln` do all of it: no `create-dmg`,
and no Finder AppleScript to place icons against a background image,
because this project builds with the Command Line Tools alone and a
prettier window is not worth a dependency that fails on somebody else's
machine.

**An unnotarized image is refused by the Mac that downloads it.**
Gatekeeper quarantines anything arriving from elsewhere, and on macOS 15+
the Control-click bypass is gone — the recipient must go to System
Settings › Privacy & Security and press Open Anyway, for every release.
`make notarize` removes that, and needs the Developer ID.

Two things happen automatically once `security find-identity` reports a
Developer ID, and neither should be turned on before then:

* **The hardened runtime**, which notarization requires — and which
  blocks the microphone unless `Resources/AtriumMac.entitlements` asks
  for it. A hardened build without that entitlement records silence and
  does not say why.
* **Signing the disk image itself**, not only the app inside it.

The app is deliberately **not sandboxed**. A sandboxed process cannot
create a CoreAudio process tap at all, and that tap is how the far end of
a call is recorded.

Stapling is not optional: without it the first launch needs the network
to check the notarization, so an image opened on a train is refused.

**And it takes two submissions, not one.** Stapling a disk image tickets
the image and nothing inside it — measured: after `stapler staple` on
the dmg, the app it contained still reported *"does not have a ticket
stapled to it"*. Since the whole point of the image is that somebody
drags the app out of it, the copy they keep is the one that needs the
ticket. So `make notarize` staples the app first, builds the image
around the stapled app, and notarizes the image in its own right.

That ordering is load-bearing: `notarize` used to depend on `dmg`, which
depends on `bundle`, which **re-signs the app and throws the ticket
away** one step before the image is built. `dmg-image` packages without
that prerequisite. Putting it back would look like an obvious tidy-up.

Two things this cost before they were fixed, both worth not repeating.
`make notarize` printed "NOT notarized — you need a Developer ID" and
then submitted anyway, so Apple spent four minutes reporting three
things `CODESIGN_IDENTITY` already knew; it refuses up front now. And
`make signing-identity` reported on the *local dev* certificate while
builds were signing with the Developer ID — the one command you would
run to answer "what is this signing with?" answered a different
question.

## Updating an installed copy, and the two keys that takes

Apple offers **no** auto-update mechanism outside the App Store, and this
app can never ship there — the App Store requires sandboxing and a
sandboxed process cannot create a process tap at all. So updates are
Sparkle's, from a signed appcast at `docs/appcast.xml`, served by GitHub
Pages and pointing at release assets.

**The signature is what makes it safe, not the host.** Sparkle assumes
the server is hostile. Two keys, and they are separate on purpose:

| key | issued by | proves | if stolen |
|---|---|---|---|
| Developer ID | Apple | Gatekeeper trusts this app to run | Apple revokes; every copy stops launching |
| EdDSA | us, in the login Keychain | *this update* came from us | an attacker can push a malicious update |

A compromised CDN, or a compromised GitHub account — which is the case
actually worth defending against — can serve whatever it likes and the
update is refused, because the EdDSA private half never leaves this Mac.
Reusing the Developer ID for both would put its private key wherever
releases are built and collapse two failure modes into one.

**`CFBundleVersion` is what Sparkle compares.** It sat at `1` for both
0.1.0 and 0.1.1, which would have shipped an updater that never offered
anything: the feed would list a build the app considered equal to
itself. It is now derived from the marketing version at bundle time —
0.2.0 becomes 200 — so there is no second number to remember.

**A recorder cannot just relaunch.** Sparkle installs by quitting and
reopening. `Updater.isBusy` refuses while a recording is running or the
queue still has work, because a meeting this app fails to record cannot
be recovered and a pending upload's `.m4a` is the only copy of that
conversation once Atrium PA sweeps its vault. The postponement **holds
the install handler and retries every minute**, rather than declining:
a postponed update with nothing watching for the moment to resume lasts
until the next launch, and an app that starts at login and runs for
weeks would never update at all.

**Two build details that are easy to get wrong.** The Sparkle framework
arrives unsigned from SwiftPM and has to be signed *inside out* — the
XPC services, then the framework, then the app — or the app fails its
own verification. And the appcast's enclosure URLs are rewritten after
`generate_appcast` runs (`Tools/fix-appcast.py`), because GitHub puts the
tag in the asset path so every version needs a different prefix and
`--download-url-prefix` holds only one. The alternative, hosting images
on Pages so the prefix is constant, grows the git history by a disk
image per release for ever.

## The icon is atrium's own mark, drawn rather than imported

`Resources/AppIcon.icns` is committed, so a fresh checkout builds without
extra tools. `Tools/make-icon.swift` (`make icon`) is where it comes
from — a binary blob with no source is a blob nobody can change.

The art is copied from atrium's `frontend/public/logo.svg`: "frame &
void", an outer square around an open courtyard with a lintel across the
upper third. At 16 and 32 pt it switches to `favicon.svg`, which drops
the lintel and thickens the strokes — that file exists precisely because
the full mark does not survive being scaled down, so it is followed
rather than second-guessed.

CoreGraphics rather than librsvg or ImageMagick: the mark is two
rectangles and a line, and this project builds with the Command Line
Tools alone. Two details that are not optional — the plate is 824/1024
with a 185/824 corner radius, which is the shape every system icon uses,
and the mark's box is y-flipped, because SVG measures y downwards and
CoreGraphics upwards. Without the flip the lintel crosses the lower third
and the mark is subtly upside down.

The menu-bar item keeps its `waveform` symbol. It has a job the mark
cannot do: it changes to `waveform.circle.fill` while recording, and a
status item that never changes says nothing.

## Settings live in one window, and it writes through

`SettingsWindow` is an `NSTabViewController` with `.toolbar` — General,
Atrium PA, Recordings, Permissions. Every control saves on change; there
is no OK button, because an Apply step invites "did that save?" and the
answer should be visible instead.

Two things it must not do. It must not read the keychain on the main
thread — `isSignedIn` is the cached `hasStoredSecret`, for the reason in
"Never touch the keychain from the main thread". And the recordings
folder must not be changed without first pinning every existing queue
item to where it already is (`UploadQueue.pinDirectories`), or the whole
queue resolves against the new folder and finds nothing.

`AppPaths.recordingsOverride` is ignored while `rootOverride` is set, so
a user's configured folder can never leak into a test run.

**A pane that grows must make its window grow.** `NSTabViewController`
reads `preferredContentSize` *while switching* — before the incoming
pane's `viewWillAppear` — and then leaves the window alone. Set it only
in `viewWillAppear` and the window is permanently one step behind: adding
a row to the Recordings pane put it below the bottom edge, with no
scrollbar to say so. So `BasePane` sizes itself in `loadView` as well,
and `SettingsTabs.fitWindow(to:)` resizes on every switch, keeping the
top-left corner still.

`fitWindow` touches `pane.view` before reading `preferredContentSize`: a
controller that has never been shown has not run `loadView`, so the size
is zero and the resize silently does nothing.

## Two startup checks, because both failures are silent

`reportMissingPermissions()` and `verifyLoginOnLaunch()` run a few
seconds after launch. Being "configured" only means a client id is on
disk and a secret is in the keychain — a revoked refresh token looks
identical until an upload fails hours later, after a meeting. Minting a
token on launch moves that discovery to a point where it can be fixed.

The audio-capture grant is deliberately reported as **unknown**, not
green. macOS offers no way to ask, and a tap created without it does not
error — it delivers zeroes. `Permissions.audioCapture` says so rather
than inventing a tick.

## Build and run

```sh
make            # build + bundle + sign
make run        # ...and launch via LaunchServices  ← use this
make install    # copy to /Applications, where an app belongs
make dmg        # a disk image with an Applications link, to hand over
make notarize   # ...submitted and stapled. Needs a Developer ID
make verify     # confirm the bundle can hold a TCC grant
make test       # unit tests (no network, no microphone)
make test-live  # ...plus a real upload to Atrium PA. Needs credentials
make probes     # build the standalone feasibility probes
make icon       # redraw Resources/AppIcon.icns (committed; rarely needed)
make appcast    # sign the built image into docs/appcast.xml (run by notarize)
```

`~/Library/Application Support/AtriumMac/`, all seeded on first launch:

```
allowlist.json      bundle-ID prefixes that may trigger a recording
config.json         base URL, client ID, language, retention, on/off
Recordings/         48 kHz stereo .caf masters + the .m4a sent upstream
Queue/              one JSON file per pending upload
```

The client secret is not in any of them — see "Where the credentials
live" above.

## Probes are diagnostics, not dead code

`Probes/` holds the original feasibility tools. They are the fastest way
to answer "is it my code or is it this machine?":

| probe | answers |
|---|---|
| `mic-detect` | which processes hold the mic, live |
| `dump-procs` | every audio process + bundle ID (find helper IDs here) |
| `tap-probe` | can a process tap be created at all |
| `tap-capture` | does audio actually *flow* — prints peak/RMS |
| `win-titles` | are window titles readable without Screen Recording |

`make -C Probes bundle` demonstrates the CLI-vs-bundle A/B directly.

## Still unproven

Be honest about these; do not write code that assumes them settled.

1. **No TCC dialog was ever observed** during development. `TCC.db` is
   unreadable without Full Disk Access and `tccd` logs are redacted, so
   it is unknown whether the bundled run was granted or simply never
   gated. Verify on a clean machine before trusting onboarding.
2. **Clock drift** between the mic stream and the tap stream over a long
   call is untested. This is the main remaining engineering risk, and it
   is why `kAudioSubTapDriftCompensationKey` is on.
3. **The far-end confirmation threshold** (`instantPeak > 0.002`) is a
   guess. Tune it against real meetings, not in the abstract.
