# Vocca: Project Context for Claude Code

This file orients a coding agent working in this repository. Read it first.

> **Status:** planned, not built. The planning session is **done** — `docs/ROADMAP.md`,
> `docs/technical/CAPABILITY_ROADMAP.md`, `docs/technical/ARCHITECTURE.md`, and
> `docs/product/PRODUCT_SPEC.md` all exist. **`ARCHITECTURE.md` is now authoritative on
> technical direction** (see "Tech direction" below). The next step is implementation,
> starting at **C1** (audio capture + global hotkey). Keep these docs in sync as things ship.

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
  P3** — P0 is hold-to-talk only, where the user's finger is the endpointer.
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
  technical/CAPABILITY_ROADMAP.md      # C1–C14 independently-shippable build backlog ✅
  technical/ARCHITECTURE.md            # AUTHORITATIVE: types, seams, threading, failures ✅
  product/PRODUCT_SPEC.md              # Widget states, interaction, onboarding, settings ✅
```

**Which doc wins when they disagree:** `ROADMAP.md` on *sequencing and gates*;
`ARCHITECTURE.md` on *technical design*; `PRODUCT_SPEC.md` on *user-visible behavior*;
`VISION.md` and this file on *scope and strategy*.

**The immediate next artifact is code**, starting at C1 in `CAPABILITY_ROADMAP.md`. Every
capability there names its acceptance as a test to write *before* the implementation.

## Two things a coding agent should know before touching anything

1. **Read the capability's entry in `CAPABILITY_ROADMAP.md` first.** It names the seam, the
   acceptance test, and the dependencies. Building a capability without its seam is how the
   pluggable claim quietly becomes false.
2. **Do not advance phases early.** Gates are there because the most likely failure mode for
   this project is polishing dictation forever and never shipping the wedge — and the second
   most likely is shipping the agent layer on top of dictation that isn't good enough yet.
