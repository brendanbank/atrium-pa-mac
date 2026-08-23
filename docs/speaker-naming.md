# Naming the voices in a recording

A user story. Written before the voiceprint-download work landed so that
what arrived could be judged against something; updated once it did
(atrium-pa `ac0ee711`, "let the operator hear an unnamed voice without
leaving the client").

---

## The story

> **As a** person whose meetings this app records,
> **I want** a notification when a transcript is ready, and a way to name
> any voices in it that nobody has identified,
> **so that** the transcript says who said what — this time and in every
> recording of those people afterwards.

Naming a voice is not a per-transcript chore. An unnamed voice cluster
matches nothing, so the same person comes back unknown in every later
recording; naming it once fixes this transcript *and* all of them, and
`name_speaker` reports how many. That is the whole reason this is worth
building a UI for rather than leaving to a browser tab nobody opens.

---

## Why this belongs on the Mac and not only in the web UI

Atrium PA already has a naming surface — the captures page shows
`x medium/low match – verify` and hands the operator a player and a
person picker. This is not a replacement for it. It exists because the
Mac has three things the browser does not:

1. **It knows when the transcript became ready**, because it is the
   thing that uploaded the recording and is already polling
   `get_upload_status`. Nobody has to remember to go and look.
2. **It has the audio locally** — as well as the server's snippet, now
   that `identify_speaker` returns one. Two sources, and they fail in
   opposite directions: the local master is instant and offline but is
   swept after seven days, and the snippet outlives it but needs a live
   URL that expires in five minutes. Preferring the local file and
   falling back is strictly better than either alone.
3. **It knows which channel each turn came from.** The microphone
   channel is the operator by construction, not by similarity — the one
   piece of speaker evidence no amount of voiceprint matching can
   produce.

Point 3 is deliberately *not* in the acceptance criteria below. It is
the part most likely to be reshaped by the voiceprint work, and the
story stands up without it.

---

## The flow

```
  transcript ready
        │
        ▼
  ┌─────────────────────────────────────────┐
  │ Notification                            │
  │ Teams meeting — transcript ready        │
  │ 2 voices need a name                    │
  └─────────────────────────────────────────┘
        │  click
        ▼
  ┌─────────────────────────────────────────┐
  │ Voice 1 of 2 · 47 turns                 │
  │  ▶ ──────●───────  0:04 / 0:06          │
  │                                         │
  │  “…thanks Anna, that covers it”         │
  │                                         │
  │  Anna Jansen          71%  medium       │
  │  Bob de Vries         44%  low          │
  │  ─────────────────────────────────      │
  │  Search for someone else…               │
  │  + New person…                          │
  │                                         │
  │  [ Not now ]  [ Skip this voice ]  [ Name ]
  └─────────────────────────────────────────┘
        │  Name
        ▼
  “Named Anna Jansen — 47 turns across 3 recordings”
```

---

## Acceptance criteria

### Notification

1. When a queued upload reaches `ready`, a standard macOS notification is
   posted through `UNUserNotificationCenter`.
2. It says which meeting, and how many voices need naming. With none, it
   still confirms the transcript is ready — that is the thing the user
   was waiting for.
3. Clicking it opens the naming window. Clicking it when there is
   nothing to name opens the transcript in the browser.
4. It is posted **once per recording**. A transcript that is polled
   again, or an app that restarts, does not re-notify.
5. Notifications the user never saw — laptop shut, Do Not Disturb — are
   not lost: the menu keeps the count until the voices are named or
   skipped.

### The naming window

6. Lists every entry from `unknown_speakers[]`, with its turn count.
7. For each voice, plays a sample with play/pause and a seek bar,
   preferring the **local master files** — instant, offline, no round
   trip — and falling back to the snippet `identify_speaker` returns
   once retention has swept them.

   The snippets arrive as `audio_samples[]`:
   `{sample_id, audio_url, expires_in_seconds, has_persisted_snippet}`,
   ordered by id so "the second one" means the same clip twice. The URL
   is token-authenticated — no bearer, the token *is* the credential,
   the same contract as our upload URL — and lives 300 s, so it is
   fetched when the user presses play, not cached when the window
   opens. Re-call `identify_speaker` for a fresh one rather than
   retrying a stale URL.

7a. `has_persisted_snippet: false` means the server would fall back to
   slicing the source, which its own retention may already have purged.
   Say "this one may no longer play" rather than offering a control that
   404s. Every server-side failure answers 404 by design — expired,
   forged, purged and wrong-owner are deliberately indistinguishable —
   so the UI cannot diagnose *why* and should not pretend to.

7b. Audio is fetched to the app and played there. There is deliberately
   no inline-base64 path on the server side: audio bytes in a tool
   result are conversation content, and conversation content reaches a
   model provider. Recordings of people's voices do not go there. The
   same reasoning applies to us — snippet bytes stay between this app
   and the vault.
8. Shows the evidence `identify_speaker` returns: names said aloud,
   candidate attendees with their RSVP, voiceprint suggestions with
   `match_pct` and its band, and how many other recordings this voice
   appears in.
9. Offers three ways to name, in this order:
   - **a suggested person**, with the match percentage and band shown —
     never a bare name, because a 44% guess and a 91% match must not
     look alike;
   - **an existing person**, found by search;
   - **a new person**, taking a full name and an optional email.
10. A declined invitee is not offered as a suggestion. `identify_speaker`
    returns the RSVP; an attendee who said no was not in the room.
11. Naming calls `name_speaker` with `evidence.summary` describing what
    the choice was actually based on, and reports the returned
    `turns_updated` and `recordings_affected` back to the user.
12. Creating a person whose email already exists fails with the existing
    person returned inline; the UI offers that person rather than
    creating a duplicate.
13. **Skip** dismisses a voice so it is not asked about again
    (`dismiss_speaker`). **Not now** leaves it pending.
14. An entry whose `voice_cluster_id` is `null` cannot be named here —
    the UI says so and links to the web UI.
15. Nothing is ever named without an explicit press. No auto-anchoring,
    including on a high match; the tool's own contract requires a yes
    every time, and a recorder that silently attributes speech to people
    is a different and much worse product.

### Boring but load-bearing

16. Pending voices survive a quit, a crash and a reboot — they live on
    the queue item, next to `captureID`.
17. The window works while offline for playback and refuses politely for
    naming, rather than appearing to succeed.
18. Naming requires the `pa.label` scope. Credentials issued before this
    feature hold only `pa.ingest`, so the app detects the missing scope
    and offers to sign in again rather than failing at the call.

---

## What this needs that we do not have yet

- **`pa.label` in the login scope.** One line in `OAuthLogin.scope`; it
  is in the server's `DEFAULT_SCOPES` and `DISCOVERABLE_SCOPES`, so
  dynamic registration can be granted it. It does not retrofit onto an
  existing token — signing in again is required, once.
- **`unknown_speakers[]` kept.** `get_upload_status` returns it today and
  `MCPClient.UploadStatus` drops it on the floor.
- **Turn timing mapped back to the masters.** Only needed for the local
  playback path; the snippet route needs none of it. The rest still applies: `get_transcript_turns`
  gives `start_time_ms` in *uploaded* time, and the upload is the
  concatenation of a meeting's segments. Playing a turn means finding
  which segment it lands in and subtracting the ones before it. The
  segment lengths are already on the sidecar, so this is arithmetic —
  but it is arithmetic that is silently wrong on any meeting that was
  interrupted, which is the case nobody tests by hand.
- **Notification authorisation.** `UNUserNotificationCenter` needs a
  bundled, signed app and an explicit authorisation request. We have the
  bundle. Ad-hoc signing gets a fresh identity on every rebuild, so the
  grant will reset during development exactly as the microphone one
  does — worth expecting rather than debugging twice. Whether it works
  at all under ad-hoc signing is **unverified** and is the first thing
  to prove.

## Open questions

- **How much to ask, and when.** A three-hour meeting with six unknown
  voices is six decisions. Ask about all of them at once, or only the
  ones with real evidence and leave the rest to the web UI?
- **Whether to notify at all when nothing needs naming.** Criterion 2
  says yes, on the grounds that "your transcript is ready" is the thing
  the user actually wanted. It may turn out to be noise.
- **Whether the local channel evidence belongs here at all.** The
  snippet download does not make it redundant — it settles *hearing* a
  voice, not *knowing* which one is you — but it does lower the value.
  With a clip that plays in one press, recognising your own voice takes
  a second, and an inference that could be wrong buys less than it did.
  Still out of the criteria.
