# Vocca: Project Context for Claude Code

This file orients a coding agent working in this repository. Read it first.

> **Status (2026-09-01).** The skeleton exists; **the product does not.**
> A Swift 6 package with nine modules — `VoccaCore`, `VoccaAudio`, `VoccaHotkey`,
> `VoccaASR`, `VoccaText`, `VoccaInject`, `VoccaSpeech`, `VoccaUI`, `VoccaBootstrap`.
> `VoccaSpeech` is the one module still a placeholder.
>
> **Built and wired end to end:** C1 (audio capture + global hotkey), C2 (local ASR —
> Parakeet TDT 0.6B v3 via FluidAudio, the repo's first external dependency), C3 (second
> ASR engine), C4 (the injection ladder and its failsafe surface), P0 (the dictation
> loop), C5 (deterministic cleanup), C6 (LLM cleanup), and the C7 remainder
> (`speculative-asr`, merged 2026-09-01) — the speculative pre-key-up feed, the real
> `supportsStreaming == true` adapters (Parakeet sliding-window, whisper batch-by-construction),
> the open-question-2 equivalence measurement (recorded, never gated), and re-warm-after-idle.
> `AppBootstrap.configure` composes tap → session machine → `MicrophoneSource` → engine →
> ladder → failsafe → widget, driven end to end by the zero-network probe.
>
> **Measured for the first time (`p2-gate-measurement`, 2026-09-01):** Parakeet's real WER
> passes all six provisional fixtures offline; the first real streaming final is
> non-empty and attributed; the latency benchmark (both variants) runs at asr p50
> 79–102 ms / p95 354 ms, warm-start at 0.348× (within the 1.2× bound), re-warm at
> 82–85 ms; the equivalence verdict is **NO-GO** (recorded — the latency-win claim is
> blocked, the feed ships); the manifest digests verify against provisioned bytes; the
> first real dictations delivered (founder-reported) with the loop's invariants holding.
> **Still unmeasured: the injection matrix (no machine record; tracked row "unrecorded"),
> whisper's WER (GGUF absent), F2 cleanup eval (not run), and every gate.** See
> `docs/STATUS.md` for the honesty block.
>
> **`settings` (2026-09-01):** the settings window is sidebar-based (Deck-style
> `NavigationSplitView` in a `WindowGroup`-shaped window, sidebar-toggle swept out), and
> General has **Keep in menu bar**
> — with it on, ⌘Q / Dock quit is refused and the app stays in the tray (closes Settings,
> drops the Dock icon), while the tray menu's Quit and onboarding Restart always quit
> (`AppQuitPolicy`, `settings.keepInTray`). Test floor: 1753.
>
> **`App/` + `Vocca.xcodeproj`** build a signed, unsandboxed, hardened-runtime `Vocca.app`
> with the microphone entitlement, `LSUIElement`, and the frozen bundle id `dev.vocca.Vocca`.
> **`Tests/HarnessTests/`: 1753 tests**, including the zero-network invariant (a `dyld`
> interposer over `connect(2)`), module-boundary and per-seam lint, and the built-bundle
> and entitlement contracts. CI runs three jobs; every `swift test` goes through
> `Scripts/test-with-floor.sh`, because `swift test` exits 0 when it discovers nothing.
>
> **The load-bearing caveat:** the `CGEvent` tap adapter is written and is executed by
> nothing — `tapCreate` returns `nil` without an Accessibility grant, so not one line of
> `CGEventTapSource.swift` runs in CI, now or ever. Every decision it would have made was
> moved above the seam and tested there.
>
> **Full history — what landed when, and what each change did and did not do — is in
> [`docs/STATUS.md`](docs/STATUS.md).** Read it before you assume anything about a past
> decision. Keep it, this file, `VISION.md` and `docs/ROADMAP.md` in sync: describe the
> state of the tree this file ships in, write a capability up in the commit that lands it,
> and append new entries to `docs/STATUS.md` — not to this file.
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
  P3** — P0 has no endpointing at all. **Toggle is the default** since 2026-08-25 (⌥Space to
  start, ⌥Space to stop), bounded by the 120 s ceiling, the tap-disabled stop and the system
  triggers rather than by a finger; **hold-to-talk ships alongside it** as the mode where the
  user's finger is the endpointer, and remains an accessibility requirement rather than a
  preference (`PRODUCT_SPEC.md`). The two swapped roles after the hold gesture's short-press
  failure showed up on the first real dictation; neither was removed, and both machines are
  constructed at every launch.
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
