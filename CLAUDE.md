# Vocca: Project Context for Claude Code

This file orients a coding agent working in this repository. Read it first.

> **Status:** the **project skeleton for C1 exists**; the product does not. Implementation of C1
> (audio capture + global hotkey) is under way and this is its scaffolding, not its behaviour.
>
> **What is built and enforced:**
> - A Swift 6 package (`Package.swift`) with nine modules — `VoccaCore`, `VoccaAudio`,
>   `VoccaHotkey`, `VoccaASR`, `VoccaText`, `VoccaInject`, `VoccaSpeech`, `VoccaUI`,
>   `VoccaBootstrap`. **`VoccaCore` now holds the session-lifecycle machine** — the session
>   vocabulary, a sealed custody type, a pure decision function, a state machine with a single
>   custody funnel, a watchdog with a ceiling and physical-key poll, toggle mode as a second
>   configuration of the same machine, and **the `HotkeyEventSource` seam plus the `SessionEventSink`
>   that drives a session through it** — driven end-to-end by the zero-network probe. **`VoccaHotkey`
>   holds the pure translation from a macOS event-flag word plus a key code into `ModifierSet`,
>   applying the founder's `fn` rule; the pure classification of a raw event-type number, which also
>   computes the tap's event mask; the tap-health policy — every decision about a dying event tap,
>   taken over an *injected* tap handle with no `CGEvent` call in it, **including what Secure Input
>   means**: when another application holds the keyboard, no tap in the session receives a key event,
>   and the policy reports that as its own answer (`blockedBySecureInput`) rather than as a tap
>   failure, does nothing to the tap, and ends any session in flight — because a tap that is enabled
>   and receiving nothing has no key-up, no second press and no `flagsChanged` left to end one with;
>   **the real `CGEvent` tap
>   adapter, in one file, containing no decisions at all**; and **the two timers that make every
>   "bounded" claim in the product true** — `ScheduledWatchdog`, which is the sink and therefore
>   settles the watchdog's clock after every route into a session, and `TapHealthTimer`, which is the
>   only object an owner holds and so cannot leave the ~1 s health poll unwired. Both run on
>   `MainRunLoopTimer`: a `Timer` on the **main run loop** in its **common** modes, which is measured
>   rather than assumed (see below). It is the first adapter,
>   so it is the first
>   module to depend on `VoccaCore` (see `ARCHITECTURE.md` §2 — the graph points inward to the core,
>   amended in that commit). The other seven modules remain placeholders. **There is still no audio,
>   no ASR and no injection** — the session machine reacts to synthetic key events and an injected
>   clock, and `SessionAudioSource` is still a stub. The C1 acceptance (100 cycles, 100 started,
>   100 ended, 0 overlapping, 0 orphaned) runs over the `HotkeyEventSource` seam with a fake source
>   in the tap's place. **The tap adapter itself is written and is executed by nothing**: `tapCreate`
>   returns `nil` without an Accessibility grant, so not one line of `CGEventTapSource.swift` runs in
>   CI, now or ever. Everything it would have decided was moved above the seam and tested there —
>   including *when* a disablement is acted on, since both disable notifications arrive on the tap's
>   own callback and the recovery would otherwise invalidate the port whose callback is on the stack.
> - `App/` + `Vocca.xcodeproj`: builds a signed, **unsandboxed, hardened-runtime** `Vocca.app`
>   with the microphone entitlement, `LSUIElement`, and the frozen bundle id `dev.vocca.Vocca`.
> - `Scripts/`: `dev-identity.sh` (stable self-signed identity so TCC grants survive rebuilds),
>   `sign.sh`, `notarize.sh`, `test-with-floor.sh`, and **`measure-timers.sh`** — the phase 5
>   measurement harness (`Tools/TimerProbe/`, deliberately not a package target), which links the
>   shipped timer and measures the two hazards CI cannot reach: the run-loop mode during a window
>   drag, and App Nap on an `LSUIElement` app.
> - `Tests/HarnessTests/`: 317 tests — the **zero-network invariant** (a `dyld` interposer over
>   `connect(2)` driving a probe binary that now drives a full session through the real machine and
>   watchdog), module-boundary lint, licence-header lint, package-manifest coverage guard, the
>   built-bundle/entitlement contracts, the session machine's own decision-table, mutation, and
>   invariant coverage, the hotkey flag translation with its `fn` rule, the `HotkeyEventSource` seam
>   with H6 pinned in **both** directions at the far end of it, the H7 seam lint — which now names
>   the tap adapter as the one file in `Sources/` permitted to speak CoreGraphics, and at most one —
>   the event-type classification and its mask, the tap callback's own body — lifted out of the
>   adapter so that it has somewhere to run, with H6 pinned in both directions at the last point
>   before the C ABI — the callback-safe split of a tap disablement, and the
>   tap-health policy — where the load-bearing test is that **every** entry point ends an in-flight session,
>   driven over a closed set of all eight, in both activation modes, because a session that outlives
>   its tap is a hot mic. The one exception is the ~1 s health poll, which asserts the *opposite* and
>   has to: it runs once a second for as long as Vocca runs. Phase 5 added the two timers' scheduling
>   decisions, the **H10 run-loop-mode hazard measured in the suite** (a `.default`-mode timer
>   delivers 0 of 33 fires through an event-tracking gesture; the shipped `.common` one delivers all
>   33), and `OwnershipGraphTests` — which pins the four sole-owner edges a review had measured as
>   held by no test at all. Phase 6 added the Secure Input decision over an injected read — the state
>   itself cannot be entered by a test, since `IsSecureEventInputEnabled` is set by other people's
>   software — including that a blocked poll ends a session that started *after* the block began,
>   which is the fifth instance in this aspect of a guard justified by a claim about what cannot be
>   in flight.
> - `.github/workflows/ci.yml`: three jobs — headless suite under strict concurrency (any warning
>   fails), plus a bundle contract per configuration (Debug and Release). Every `swift test` runs
>   through `Scripts/test-with-floor.sh`, because `swift test` exits 0 when it discovers nothing.
>
> **What is NOT proven, and must not be claimed:**
> - **Notarization is unproven.** `Scripts/notarize.sh` has never run end to end — there is no
>   Apple Developer ID and no `notarytool` credential. Only its credential-detect-and-skip path
>   is exercised.
> - **CI cannot reach the parts most likely to break**: `CGEvent.tapCreate` returns `nil` with no
>   Accessibility grant and TCC cannot be granted on a hosted runner; there is no microphone; and
>   `AVAudioSinkNode` is unsupported in manual rendering mode, so the realtime capture path has no
>   offline equivalent. See `docs/SMOKE_CHECKLIST.md` — it states the limits precisely.
> - **The throttle App Nap would apply is real, is bounded, and is deliberately not worked around.** Every row is
>   now taken with the process's suppression state recorded beside it
>   (`getpriority(PRIO_DARWIN_PROCESS, 0)`) — because the first version of this measurement never
>   checked it, and so measured an unthrottled process and concluded nothing about a throttled one.
>   Under `taskpolicy -b` (the same task suppression App Nap applies) the shipped 150 ms timer runs at
>   a ~262 ms median and delivers ~60% of its due fires; `ProcessInfo.beginActivity(...)` does **not**
>   lift a suppression already in force, in either its keep-awake or its
>   `…AllowingIdleSystemSleep` form. A real backgrounded `LSUIElement` app was **never put into that
>   state** in 300 s of continuous observation — 2000 of 2000 samples read "not suppressed", 2000 of
>   2000 fires on time. So the countermeasure is skipped because the throttle is bounded (a
>   quarter-second late ceiling, no backstop lost), not because it could not be reproduced. What
>   suppression costs is a roughly **fixed ~100 ms per fire**, not a multiplier — 1.7× on the 150 ms
>   watchdog and only ~1.15× on the 1 s poll. Untried, and named as untried: battery power, and an
>   idle machine with the display asleep.
> - **`SystemSecureInputState` is executed by nothing either**, for a different reason worth keeping
>   distinct: `IsSecureEventInputEnabled()` *works* without any grant, so nothing stops it running —
>   what cannot be written is a test worth having. The value is a fact about every other application
>   on the machine, so asserting it is `false` fails on a developer with a password field focused and
>   asserting it is a `Bool` asserts nothing. `docs/SMOKE_CHECKLIST.md` steps 36–38 are its only
>   confirmation.
> - **`SystemPhysicalKeyState` — `CGEventSourceKeyState` and `CGEventSourceFlagsState` — is executed
>   by nothing**, for the same reason the tap adapter is not: it lives in `CGEventTapSource.swift`
>   because those identifiers match the H7 seam prefix and exactly one file may name it. What the
>   answers *mean* is above the seam, in `SessionWatchdog`, and is tested there.
>
> **`ARCHITECTURE.md` is authoritative on technical direction** (see "Tech direction" below).
> Keep these docs in sync as things ship.

---

## What this project is

**Vocca** is an **open-source, macOS, local-first voice tool**. Press a hotkey and talk, and
polished text types itself into *any* app (dictation, Wispr-style). Talk to it and it talks
back through **local Kokoro TTS** and can *act* (a smarter, open take on SKI's voice loop).
It runs on your machine; your audio never has to leave it.

**The name.** *Vocca* — from *voce / vocal*: the voice. Short, and unmistakably what it is.

**Positioning in one line:** the private, local, open-source alternative to Wispr Flow —
with an agent voice-loop that's a step smarter than SKI.

---

## Scope, locked with the founder (do not exceed without asking)

- **macOS only, for now.** No Windows/Linux until the macOS experience is genuinely good.
- **Local Kokoro TTS now** (the SKI approach). Keep TTS pluggable, but Kokoro is the default.
- **Fully open-source core.** The local experience is free and complete.
- **Premium cloud tier is LATER, not now.** The eventual business is a hosted tier running
  *our own trained models* (Wispr-style) — an **open-core** upsell. Design seams for it, but
  do **not** build cloud in the OSS core, and never cripple the local core to sell the tier.

---

## The wedge (read before proposing any feature)

Wispr Flow is closed, cloud, and subscription — so it structurally can't be private/local/
open. OSS dictation tools exist (Whispering, VoiceInk, Handy), but almost none combine
**great dictation + a smart agent voice-loop that can also act + fully local + extensible.**
That combination is the open lane.

**"Smarter than SKI" concretely means:** streaming ASR + real endpointing (not just
push-to-talk), barge-in / interruption, context-awareness (active app + selection), a
**dual mode** (dictate *into a field* vs converse/act), and **actions** (voice → run
commands / drive MCP tools / coding agents). A voice front-end that *does things*, not just
transcribes.

---

## Key strategic constraints (do not violate)

1. **Local-first, private by default.** In the OSS core, audio and text stay on-device. The
   later cloud tier is opt-in and separate.
2. **Everything pluggable (ASR / TTS / LLM).** Kokoro TTS now, but behind an interface, so a
   better local model — or the future hosted model — slots in without a rewrite.
3. **Dictation-first.** Nail "type anywhere, AI-cleaned" as the daily-use hook *before* the
   assistant/agent layer. That's what earns the stars.
4. **Open-core, honestly.** Monetize later via hosted trained models, never by degrading the
   free local experience.
5. **Latency and injection reliability are first-class.** They are the two make-or-break UX
   battles (streaming ASR feel; flawless text insertion across arbitrary apps). Treat them as
   core engineering, not polish-later.
6. **Gets better as local models improve.** A stronger local ASR/TTS/LLM should make Vocca
   better for free — the value is the integration, UX, and the action layer.

---

## The core surface (the product)

1. **Capture** — global hotkey / push-to-talk (streaming + endpointing later).
2. **Local ASR** — speech → text on-device (candidates: Parakeet-MLX, whisper.cpp,
   faster-whisper, MLX-whisper, Moonshine — pick on latency/accuracy in planning).
3. **AI cleanup** — local/BYOK LLM: filler removal, punctuation, tone, custom dictionary.
4. **System-wide injection** — insert the text into the focused field of any app (macOS
   Accessibility API + paste / keystroke synthesis).
5. **Voice-agent loop** — spoken replies via **Kokoro TTS**, turn-taking, later barge-in
   (the "smarter than SKI" layer).
6. **Context + actions (later)** — active-app/selection awareness; voice → MCP tools /
   commands / coding agents.

---

## Tech direction (LOCKED — see `docs/technical/ARCHITECTURE.md`)

Decided in the planning session after a research pass on current local macOS ASR/TTS.
`docs/technical/ARCHITECTURE.md` is authoritative; this is the summary.

- **Widget/UI:** **native SwiftUI**, small always-on-top widget that never takes focus.
- **Core:** **single Swift 6 process**, strict concurrency, no IPC on the latency path.
  (Tauri was rejected: it buys cross-platform we deferred and costs us the ANE path.)
- **ASR:** **Parakeet TDT 0.6B v3 via FluidAudio** (CoreML/ANE) as default, **whisper.cpp
  large-v3-turbo shipped as a real second engine** behind `ASREngine` — not promised later.
- **VAD/endpointing:** Silero VAD + **Parakeet EOU 120M** for turn detection. **Deferred to
  P3** — P0 has no endpointing at all. Hold-to-talk is the default, where the user's finger is
  the endpointer; a **toggle alternative ships alongside it** (`PRODUCT_SPEC.md:257` makes it an
  accessibility requirement), bounded by the 120 s ceiling rather than by a finger.
- **TTS:** **Kokoro-82M** (Apache-2.0) behind `SpeechSynthesizer`, with macOS
  `AVSpeechSynthesizer` as the shipped second implementation.
- **Cleanup:** deterministic rules by default (~0 MB, <5 ms, no network); Ollama and BYOK
  both opt-in, BYOK permanently badged at point of use.
- **Injection:** clipboard-paste primary, AX allowlist-gated and read-back-verified,
  keystroke synthesis, then the **widget failsafe** — because AX silently reports success
  while inserting nothing in many apps.
- **Actions:** MCP for the action/agent layer, gated on confirmation + a local audit log.
- **License:** **Apache-2.0** (patent grant matters for system-level input injection).

**Two invariants govern everything:** a transcript is never lost, and the default
configuration makes zero network calls (asserted by a CI test that is a permanent release
blocker).

---

## Founder profile

Solo / small-team. **Full-stack developer + ML engineer.** The edge here is integration,
UX, and the local-first/action layer — plus the option to train the hosted models later.
No dependency on proprietary data or credentials today.

---

## Quick facts for grounding (do not fabricate beyond these)

- **Wispr Flow** = closed, cloud, subscription dictation that types polished text system-wide;
  its moat is latency + reliability + polish. Vocca's edge is **open + local + private +
  extensible**, which Wispr can't offer.
- **SKI (heyski.io)** = a local floating widget running a voice loop with an agent, speaking
  replies via **local Kokoro TTS**. Vocca is a smarter, more capable superset.
- **OSS dictation already exists** (Whispering, VoiceInk, Handy) — so differentiate on the
  **smart agent loop + actions + fully local + extensible**, not on dictation alone.
- Local ASR/TTS on Apple Silicon is good enough today to run the whole thing offline.

If you need a statistic that isn't here, do not invent one; say it's unverified.

---

## Non-goals / guardrails (restated so the project doesn't drift)

- **No Windows/Linux yet.** macOS-only until it's genuinely good.
- **No cloud in the OSS core.** The hosted trained-model tier is a later, opt-in, separate
  layer — designed-for, not built now.
- **Never cripple the local core** to sell the premium tier.
- **No audio/text egress by default** — private on-device is the promise.
- **Don't over-scope the assistant before dictation is excellent.**

---

## Docs structure

```
README.md                              # Repo front door ✅
VISION.md                              # Narrative thesis, moat, non-goals ✅
CLAUDE.md                              # This file
docs/
  ROADMAP.md                           # P0–P5 phases: milestones, metrics, exit gates ✅
  SMOKE_CHECKLIST.md                   # What CI structurally cannot cover + manual release steps ✅
  technical/CAPABILITY_ROADMAP.md      # C1–C14 independently-shippable build backlog ✅
  technical/ARCHITECTURE.md            # AUTHORITATIVE: types, seams, threading, failures ✅
  product/PRODUCT_SPEC.md              # Widget states, interaction, onboarding, settings ✅
  planning/                            # Per-unit-of-work PRDs, aspect specs and tech plans ✅
    <unit>/prd.md                      #   e.g. audio-capture-hotkey/prd.md
    <unit>/<aspect>/spec.md            #   e.g. audio-capture-hotkey/project-skeleton/spec.md
```

**Which doc wins when they disagree:** `ROADMAP.md` on *sequencing and gates*;
`ARCHITECTURE.md` on *technical design*; `PRODUCT_SPEC.md` on *user-visible behavior*;
`SMOKE_CHECKLIST.md` on *what a green CI badge does and does not mean*; `VISION.md` and this file
on *scope and strategy*. `docs/planning/` is per-unit-of-work and is scoped to the unit it names —
it never overrides the four above.

**The immediate next artifact is code**, continuing at C1 in `CAPABILITY_ROADMAP.md` — the skeleton
above is C1's scaffolding, not C1. Every capability there names its acceptance as a test to write
*before* the implementation.

## Two things a coding agent should know before touching anything

1. **Read the capability's entry in `CAPABILITY_ROADMAP.md` first.** It names the seam, the
   acceptance test, and the dependencies. Building a capability without its seam is how the
   pluggable claim quietly becomes false.
2. **Do not advance phases early.** Gates are there because the most likely failure mode for
   this project is polishing dictation forever and never shipping the wedge — and the second
   most likely is shipping the agent layer on top of dictation that isn't good enough yet.
