# Vocca: Capability Roadmap

The phase plan in [`docs/ROADMAP.md`](../ROADMAP.md) says *what we're proving and when*. This document is the layer beneath it: the **sequenced, one-at-a-time backlog of capabilities** that actually get built, each one independently shippable and each one leaving Vocca more capable than before.

Everything here stays inside the locked scope — macOS only, local Kokoro TTS, fully open-source core, dictation before assistant, no cloud in the OSS core. See the guardrails at the end.

---

## How to read this

- Capabilities are labelled **C1 … C14** in build order. Each is **independently shippable**: it can be merged, released, and used on its own, and nothing after it is required for it to be worth having.
- **Phase tags** map each capability to `ROADMAP.md`. Windows are sequencing guidance, not commitments — real user pull reorders freely.
- Every capability is built **test-first**. Each one names its acceptance as a test we write before the code.
- Every capability names its **pluggable seam** — the interface it establishes or extends — because the seams are what let a better local model, a community contribution, or the future hosted model slot in without a rewrite.

### The single framing

Two invariants govern every capability below, and any capability that violates one is wrong regardless of how useful it seems:

1. **A transcript is never lost.** Every path terminates somewhere the user can recover their words.
2. **The default path makes zero network calls.** Egress is opt-in, badged at the point of use, and never silent.

Beyond those, each capability either makes the loop *more reliable* (injection, engines, failsafes), makes it *feel faster* (warm start, streaming, speculative ASR), or makes it *do more* (voice loop, context, actions). A better base model should make each of these stronger, never redundant — because our value is the integration, not the checkpoint.

### The seam discipline

**A seam with one implementation is not a seam; it's an assertion.** Every interface below ships with **at least two real implementations** before we claim it's pluggable. This is not architectural vanity — it is the only honest test that the later hosted model can slot in, and it's the first thing a skeptical contributor will check.

---

## C1. Audio capture + global hotkey · P0, week 1

**Why it matters.** This is the front door. If the hotkey is flaky or a session gets stuck recording, nothing downstream can rescue it — and a mic that stays hot without the user knowing is a privacy failure in a tool whose entire pitch is privacy.

**What we build:**
- A global `⌥Space` hotkey via a `CGEvent` tap, with key-down starting capture and key-up ending it. **No VAD or endpointing in P0** — in hold-to-talk the user's finger is the endpointer, so "it cut me off mid-sentence" is structurally impossible. Hold-to-talk is the default and **a toggle alternative ships alongside it**, as one configuration of the same state machine: `PRODUCT_SPEC.md:257` makes that an accessibility requirement rather than a preference. Toggle has no physical fact behind it, so it keeps the ceiling, the tap-disabled stop and the system triggers, and is bounded by the ceiling alone in the case where its stopping press is never seen — see `docs/planning/audio-capture-hotkey/session-lifecycle/spec.md`.
- `AVAudioEngine` capture at the ASR's native sample rate (16 kHz mono), into a ring buffer sized for a bounded maximum utterance.
- A floating always-on-top SwiftUI widget: idle pill → live waveform while recording → spinner while transcribing → collapse.
- **Hard session invariants:** capture cannot outlive key-up; a lost key-up event (app switch, sleep, hotkey stolen) triggers a watchdog that ends the session cleanly rather than recording indefinitely.
- Microphone permission requested with copy that says what we do and don't do with audio.

**Acceptance (test-first):** A scripted harness fires 100 synthetic key-down/key-up pairs at varying durations (80 ms to 60 s) and asserts exactly 100 sessions started, 100 ended, zero overlapping, zero orphaned. A separate test kills the key-up mid-session and asserts the watchdog closes capture within its timeout. Buffer contents are asserted against known-length fixtures, so a sample-rate or channel-count regression fails loudly.

**Pluggable seam:** `AudioCapture` — yields `AudioBuffer` chunks and a session lifecycle. Establishing it now means the P3 streaming/full-duplex capture is a second implementation rather than a rewrite of the hot path.

**Dependencies:** none. This is the first brick.

---

## C2. Local ASR behind `ASREngine` · P0, week 2

**Why it matters.** This is the capability the whole product is named after. It also has to be the *fastest credible option*, because latency is one of the two make-or-break battles and ASR owns most of the budget.

**What we build:**
- The `ASREngine` protocol: `transcribe(AudioBuffer) async throws -> Transcript`, where `Transcript` carries text, per-segment timings, a confidence signal where the engine exposes one, and the engine identity that produced it.
- **Parakeet TDT 0.6B v3 via [FluidAudio](https://github.com/FluidInference/FluidAudio)** as the first implementation — CoreML on the Apple Neural Engine. Chosen for RTF ~0.042 on M4 (~24× realtime), a ~2 GB unified-memory floor, 25 European languages with automatic detection, and ANE offload that keeps power draw low enough for all-day use.
- Model download-on-first-run with a progress UI, integrity verification, and a resumable transfer. Models live in Application Support, not in the bundle, so the app download stays small.
- Warm-model residency: the engine loads **once, at first use**, and stays resident — the
  first use is allowed to be slow. Launch preload ("first dictation after launch is not the
  slow one") is **C7's** deliverable, measured against the 20%-of-steady-state metric there.
  *(Amended by the `local-asr` capability: the earlier wording promised the C7 outcome with
  only a load-once mechanism, which cannot deliver it.)*

**Acceptance (test-first):** Fixed audio fixtures (clean speech, accented speech, background noise, a 60-second utterance, a 200 ms utterance) transcribe to expected text within a WER tolerance, **with the network interface down** — the offline assertion is part of the test, not a manual check. A test asserts the engine reports its identity in the `Transcript`, so downstream code can never silently attribute output to the wrong engine.

**Pluggable seam:** `ASREngine`. **This is the seam the hosted tier slots into.** A hosted provider is added alongside the local ones — never in place of them.

**Dependencies:** C1.

---

## C3. Second ASR engine — whisper.cpp · P0, week 2

**Why it matters.** Two independent reasons, and either alone would justify it. First, **it proves the seam is real** — the single most important structural claim in the project, and the one a contributor or an acquirer will test first. Second, it is genuine insurance: Whisper has roughly four production-ready inference paths on Apple Silicon (whisper.cpp, WhisperKit, MLX-Whisper, faster-whisper) against Parakeet's one-to-two community ports. That ecosystem gap is measured in years, and being stranded on a single unmaintained CoreML port is a real failure mode for a project that intends to be around a while.

**What we build:**
- **whisper.cpp large-v3-turbo** behind the same `ASREngine` protocol, via a thin C interoperability bridge, Metal-accelerated.
- Engine selection in settings, switchable without restart, with an honest description of the tradeoff (Parakeet: faster; Whisper: broader language and accuracy coverage).
- A per-engine model-tier choice, so constrained machines can drop to a smaller Whisper model rather than falling off a cliff.

**Acceptance (test-first):** The **same fixture suite from C2 runs against both engines** — one test body, parameterized over implementations. Both must pass their WER tolerances. A separate test swaps the engine at runtime mid-session-boundary and asserts no caller above the seam observes anything except a different `engineIdentity` on the transcript. If adding an engine requires touching a call site, the seam has failed and the test says so.

**Pluggable seam:** `ASREngine`, now proven rather than asserted.

**Dependencies:** C2.

---

## C4. The system-wide injection ladder · P0, week 3

**Why it matters.** This is make-or-break battle #2, and it is where the documented behavior of macOS is actively hostile. `AXUIElementSetAttributeValue` on `kAXSelectedTextAttribute` **returns success while inserting nothing** in a large class of apps — Electron, custom text views, browser-based editors. An AX-primary design therefore has a silent-data-loss failure mode: the user talks for thirty seconds, gets an empty field, and has no transcript to recover. That is the worst bug this product can have, so the ladder is built to make it impossible rather than unlikely.

**What we build — the ladder, in order:**

| Rung | Method | When |
|------|--------|------|
| 1 | AX `kAXSelectedTextAttribute` | **Only** for apps on a verified allowlist, because AX lies |
| 2 | Clipboard + synthesized ⌘V | The workhorse. Save pasteboard → set → paste → restore |
| 3 | `CGEvent` keystroke synthesis | Slow, last-ditch, for fields that refuse paste |
| 4 | **Widget failsafe** | Text held in the widget, ⌘C copies it. **Every path ends here or better** |

- **Secure Input detection** (`IsSecureEventInputEnabled`) short-circuits directly to rung 4 with an explicit message naming the reason — "this looks like a password field, press ⌘C to copy instead." An honest refusal beats a mysterious no-op.
- **Clipboard hygiene:** save → set → paste → settling delay → restore, written to tolerate clipboard managers (Raycast, Alfred, Paste, Maccy) racing us for pasteboard ownership.
- **Verification where possible:** after an AX insert, re-read the field and confirm the text arrived. If it didn't, fall through — this is precisely the check that turns AX's silent lie into a caught failure.

**Acceptance (test-first):** A UI-automation harness drives the P0 app matrix (native AppKit, Electron, browsers including Google Docs' custom editor, terminals, IntelliJ) and asserts injected text appears verbatim. **The load-bearing test is the failure path:** a fault-injection harness forces each rung to fail in sequence — including AX's *silent* failure, simulated as success-with-no-insert — and asserts that in every combination the transcript is recoverable from the widget. Transcript loss is asserted at exactly zero; there is no tolerance band on this test.

**Pluggable seam:** `TextInjector` — `inject(String, into: TargetContext) -> InjectionResult`, where the result names which rung succeeded. C8 consumes those results to build per-app strategy memory.

**Dependencies:** C1. (Independent of C2/C3 — injection is testable against canned strings before ASR exists, and should be.)

---

## C5. Deterministic cleanup + custom dictionary · P1, week 5

**Why it matters.** Most of the gap between raw ASR and text a person would have typed is mechanical: fillers, missing punctuation, capitalization, and proper nouns the model has never seen. Closing that gap with **rules costs ~0 MB and <5 ms** and keeps the default install small and the privacy promise literally true. Reaching for an LLM first would be the expensive way to solve the cheap part of the problem.

**What we build:**
- The `CleanupProvider` protocol: `clean(Transcript, context: CleanupContext) async -> String`.
- A rules implementation: filler removal (um, uh, er, like, you know — frequency-tuned, not blanket), sentence segmentation and terminal punctuation, capitalization, spoken-punctuation commands ("new line", "period"), and number/unit normalization.
- A **user dictionary**: ordered replacement rules for names, jargon, and code identifiers, with case-sensitivity and word-boundary control, editable in settings and stored as plain readable JSON the user can hand-edit or version-control.
- **The timeout policy that makes cleanup safe:** any cleanup exceeding its budget yields the *raw* transcript to the injector. Cleanup must never be able to lose or block text — it is an enhancement layer, and it is architecturally forbidden from being a failure point.

**Acceptance (test-first):** A table-driven suite of raw-transcript → expected-clean pairs covering each rule class in isolation and in combination. A dedicated test asserts a deliberately hung provider still results in the raw transcript reaching the injector within the timeout. A user-dictionary test asserts rules apply in declared order and that a rule can't corrupt text outside its match. And an **evaluation harness** runs a held-out set of real dictation samples, scoring blind pairwise preference of cleaned over raw — the number the P1 gate is judged on.

**Pluggable seam:** `CleanupProvider`. **The second seam the hosted tier slots into** — a trained cleanup/rewrite model is one more implementation behind this interface.

**Dependencies:** C2.

---

## C6. LLM cleanup — Ollama and BYOK · P1, weeks 6–7

**Why it matters.** Rules can't do tone, reflow, or intent-aware rewriting. An LLM can. The design question was never *whether* to offer it but *how to offer it without the privacy promise quietly eroding into "cloud by default because pasting an API key is easier than installing Ollama."* Hence: both rungs are opt-in, and the cloud rung is permanently, visibly badged.

**What we build:**
- **Ollama provider** behind `CleanupProvider`: model discovery, a prompt tuned for cleanup-not-creativity, streaming disabled (we need the whole result before injection anyway), and graceful degradation to rules when Ollama is absent, cold, or slow.
- **BYOK provider**: provider-agnostic endpoint + key config, stored in the Keychain, off by default.
- **The egress badge**: whenever a cloud provider is active, a persistent, non-dismissable indicator in the widget. It appears at the moment text would leave the machine, not buried in a settings panel.
- Per-mode provider selection, so a user can run rules for dictation and an LLM for the P3 assistant without one choice contaminating the other.

**Acceptance (test-first):** Provider tests run against a stubbed Ollama endpoint asserting correct request shape, timeout, and fallback-to-rules on every failure mode (absent, cold, slow, malformed response). The BYOK provider is tested against a stub asserting the key never appears in logs or crash reports. **The permanent release blocker lives here:** a test runs a full dictation cycle in the default configuration with a network interposer asserting **zero outbound connections**. This test is never relaxed, and any change that breaks it is a positioning failure, not a test failure.

**Pluggable seam:** `CleanupProvider`, now with three implementations — rules, local LLM, remote. The remote implementation is also the working proof that a hosted provider integrates cleanly.

**Dependencies:** C5.

---

## C7. Latency instrumentation, warm start, and widget-only streaming · P2, weeks 7–9

**Why it matters.** "It feels fast" is not a metric, and you cannot defend a latency budget you have never measured. This capability turns perceived latency into a number with named spans, so a regression has an address. The streaming piece then buys the *feel* of instant response — deliberately **without** injecting partial text into the target app, because revising text in someone else's field means select-back-and-replace, which breaks in Electron, terminals, and Google Docs exactly where it's least forgivable.

**What we build:**
- **Local-only** latency histograms — never transmitted, inspectable by the user — broken into capture-close, ASR, cleanup, and injection spans, so a p95 regression names its own culprit.
- **Warm start:** model resident and pre-warmed at launch and after idle, so the first dictation after launch is not an outlier.
- **Speculative ASR:** begin transcribing the buffer while the user is still speaking; finalize on key-up. Most of the ASR cost moves off the critical path, which is where the bulk of the p50 win comes from.
- **Widget-only streaming partials:** live text scrolls in the widget as the user talks. The target app stays untouched until the final, atomic injection.

**Acceptance (test-first):** A benchmark harness replays fixture audio end-to-end and asserts p50 ≤ 400 ms and p95 ≤ 800 ms for a 10-second utterance, **failing CI on regression**. A warm-start test asserts first-dictation-after-launch latency lands within 20% of steady-state. A test asserts that during streaming, **zero injection calls occur before key-up** — the guard that keeps partials out of other people's text fields permanently.

**Pluggable seam:** `ASREngine` gains an optional streaming capability, declared by the engine and degraded gracefully when absent (whisper.cpp batches; Parakeet streams). Callers never branch on engine identity.

**Dependencies:** C2, C4.

---

## C8. Injection matrix + per-app strategy memory · P2, weeks 9–11

**Why it matters.** C4 built the ladder; this makes it *learn*. Retrying a rung that has failed for a given app on every single dictation is latency the user pays repeatedly for information we already have. And the matrix itself is what converts "injection works pretty well" into a defensible number — the one we publish in P5.

**What we build:**
- The P0 matrix expanded past **20 apps**, run as a semi-automated harness against each release.
- **Per-bundle-ID strategy memory:** persist which rung succeeded per app; start there next time; re-probe occasionally so an app update that fixes AX support is eventually noticed rather than permanently written off.
- Seeded defaults for known-hostile apps, so a first-time user of Google Docs doesn't pay the discovery cost.
- A user-visible per-app override, for the cases our heuristics get wrong.
- Verified coexistence with clipboard managers (Raycast, Alfred, Paste, Maccy).

**Acceptance (test-first):** The matrix harness asserts ≥95% first-method-success across the 20-app set with memory active. A memory test asserts a learned strategy is tried first on the next dictation, that a subsequent failure demotes it, and that re-probing eventually rediscovers a rung that starts working again. A clipboard test asserts pasteboard contents survive 100 consecutive dictations with a clipboard manager running.

**Pluggable seam:** `InjectionStrategyStore` — the persisted per-app policy, separated from `TextInjector` so the learning logic is testable without driving real apps.

**Dependencies:** C4.

---

## C9. Kokoro voice output · P3, week 12

**Why it matters.** The first half of the voice loop, and the first capability that isn't dictation. Kokoro is the right default not because it's the most expressive local TTS but because it's small, fast to first audio, and — uniquely among the mainstream options — **Apache-2.0 and cleanly commercially safe** (XTTS v2 is non-commercial; Chatterbox and Qwen3-TTS are heavier and aimed at cloning we don't need). For a voice loop, time-to-first-audio beats timbre.

**What we build:**
- The `SpeechSynthesizer` protocol: `speak(String) -> AudioStream`, with cancellation as a first-class operation because C10's barge-in depends on halting mid-utterance.
- **Kokoro-82M** as the first implementation, with voice selection and rate control.
- **macOS `AVSpeechSynthesizer`** as the shipped second implementation. It proves the seam and gives a zero-download fallback so a fresh install can talk before any model finishes downloading.
- Sentence-level chunking so speech begins before the full reply is synthesized.

**Acceptance (test-first):** Both implementations run the same parameterized suite: known text produces non-empty audio of plausible duration; **cancellation halts output within 50 ms** (the precondition for barge-in); the synthesizer is safe to cancel and immediately re-invoke without deadlock or audio-session corruption. Time-to-first-audio is benchmarked with a ≤300 ms assertion.

**Pluggable seam:** `SpeechSynthesizer`, proven by two implementations at ship.

**Dependencies:** none blocking (independently shippable — "Vocca can read your selection aloud" is a useful release on its own, before any conversational loop exists).

---

## C10. Streaming turn-taking + barge-in · P3, weeks 13–15

**Why it matters.** This is the "smarter than SKI" capability. Push-to-talk is fine for dictation and wrong for conversation; a real voice loop needs to know when you've *finished a turn*, which is not the same as knowing when you've stopped making noise. The 2026 consensus pattern is exactly this pairing — a lightweight VAD for frame-level speech/silence plus a small end-of-utterance model scoring "did they finish?" on top — and it's the pattern LiveKit Agents and Pipecat both converged on.

**What we build:**
- **Silero VAD** for frame-level speech/silence, wrapped behind `VoiceActivityDetector`.
- **FluidAudio's Parakeet EOU 120M** behind `TurnDetector`: on a candidate pause, score P(user finished) over the current utterance; below threshold keep listening, above threshold commit the turn.
- **Barge-in:** full-duplex audio. User speech detected during TTS playback ducks and halts output within 200 ms, discards the interrupted reply cleanly, and resumes capture without losing the interrupting words.
- **Echo rejection**, so Vocca never transcribes its own voice — verified on speakers, not just headphones, because headphones make this problem disappear and speakers are how people actually use it.
- **Hold-to-talk remains available forever** as the escape hatch. When endpointing misjudges, the user must always have a mode where their finger is the ground truth.

**Acceptance (test-first):** A recorded conversational set with human-labelled turn boundaries asserts ≥95% correct turn commitment, scored with **false cutoffs weighted 5× worse than late commits** — being interrupted mid-sentence is the failure users won't forgive, and the metric has to say so. A barge-in test injects user speech during synthetic TTS playback and asserts halt within 200 ms with the interrupting audio fully captured. An echo test plays known TTS output through a loopback and asserts zero transcription of it.

**Pluggable seam:** `VoiceActivityDetector` and `TurnDetector` as separate interfaces — deliberately separate, because they answer different questions and the EOU model will be replaced on a faster cycle than the VAD.

**Dependencies:** C1, C2, C9.

---

## C11. Dual mode — dictate vs converse · P3, week 16

**Why it matters.** Small capability, outsized consequence. If the user can ever be unsure whether they're dictating into a field or talking to the agent, they will eventually say something to Vocca that lands in a Slack message to their boss. Mode ambiguity here is not a UX papercut; it's the failure that gets the tool uninstalled.

**What we build:**
- Two distinct hotkeys with two unmistakably different widget states — different color, different shape, different sound. Not a subtle badge on the same pill.
- **No implicit mode switching, ever.** Vocca never infers which mode you meant from what you said.
- Per-mode configuration: different cleanup providers, different ASR engines if the user wants them.
- A visible indicator of the injection *target* in dictate mode ("→ Slack"), so the destination is confirmed before speech, not discovered after.

**Acceptance (test-first):** A test asserts that in converse mode **no `TextInjector` call is ever made** — the structural guarantee that agent conversation cannot leak into an app field, enforced by type or by assertion rather than by discipline. A mode-transition test asserts state is fully reset between modes with no carryover of buffer, transcript, or target.

**Pluggable seam:** `SessionMode` as an explicit state machine, with the injection path only reachable from the dictate state.

**Dependencies:** C4, C10.

---

## C12. Context provider — active app and selection · P4, weeks 17–18

**Why it matters.** The step from "voice assistant" to "voice assistant that knows what you're looking at." Asking "summarize this" only means something if Vocca can see the selection. It is also the capability with the sharpest privacy edge in the whole roadmap — reading other apps' content is exactly the power a privacy-first tool must be most careful with, and must be most visible about.

**What we build:**
- `ContextProvider` yielding active bundle ID, window title, and current selected text via AX.
- **Per-app opt-in** for context capture. Default is off for every app; the user grants each one deliberately. No blanket "allow all."
- A **visible indicator whenever context is being read**, plus a global kill switch reachable in one action.
- Context is **never persisted** beyond the current turn and never leaves the machine — including when a BYOK cleanup provider is active, where context is excluded from the payload unless separately and explicitly permitted.

**Acceptance (test-first):** A test asserts correct app/selection resolution across the C8 app matrix at ≥95%. A **privacy test asserts that with context capture off for an app, no AX read of that app's content occurs at all** — not read-then-discard, but never read. A second asserts context never appears in a BYOK request payload without the separate explicit grant. These two tests are the ones that make the privacy claim auditable rather than promised.

**Pluggable seam:** `ContextProvider`. Notably, **this seam has no hosted counterpart by design** — context is read locally, always, and the hosted tier never sees it.

**Dependencies:** C4 (shares AX infrastructure).

---

## C13. Actions and MCP · P4, weeks 19–22

**Why it matters.** The wedge, finally. This is what no OSS dictation tool has and what turns Vocca from a transcription front-end into something that *does things* — driving MCP tools, running commands, handing work to coding agents. It is also, by a wide margin, the capability with the largest blast radius, which is why it ships gated on safety rather than on capability.

**What we build:**
- Vocca as an **MCP client**: tools discovered, listed, and **individually enabled** — never enabled wholesale.
- An intent layer mapping utterances to tool calls with arguments, including a "not confident" path that asks rather than guesses.
- **Confirmation policy by blast radius:** read-only actions run directly; destructive or outward-facing actions require explicit confirmation that **states what will happen before it happens**, in concrete terms ("send this message to #general") rather than abstract ones ("execute slack_post").
- **Dry-run mode:** every action previewable as "here's what I would do" before it is armed.
- A local, append-only **audit log** with enough detail to reconstruct exactly what happened.
- Coding-agent handoff: voice → an agent session with the active project as context.

**Acceptance (test-first):** Against a stub MCP server, tests assert correct tool discovery, argument construction, and that a disabled tool is never callable. **The safety tests are the load-bearing ones:** a destructive action without confirmation must be *structurally impossible* — asserted by attempting it and requiring the call to be refused, not merely unprompted. Dry-run must produce zero side effects, asserted by a stub that fails the test if invoked. Every executed action must appear in the audit log, asserted by reconstruction.

**Pluggable seam:** `ActionProvider` — MCP is the first implementation; shell commands and coding-agent handoff are additional ones behind the same interface and the same confirmation policy. No provider gets to opt out of the confirmation gate.

**Dependencies:** C10, C11, C12.

---

## C14. Model registry + out-of-tree provider proof · P5, week 23+

**Why it matters.** Two things at once. For users: managing models in-app instead of by hand. For the project: **the only honest test that any of our seams are real.** If someone outside the repository can add an ASR engine that the core has never heard of and it just works, the pluggable claim is true — and by direct implication, the hosted tier slots in without a rewrite. If they can't, every seam above is decoration and we should find that out now rather than at the moment we need it.

**What we build:**
- In-app model management for ASR and TTS: browse, download with progress, switch, remove, see disk usage.
- A documented **provider registration API** so an engine can be contributed without forking.
- **A reference out-of-tree provider**, built in a separate repository, that the core has zero knowledge of.
- An "add your own engine" contributor guide written *from* that reference implementation, so it can't drift from reality.

**Acceptance (test-first):** An integration test loads the out-of-tree provider and runs the **full C2/C3 fixture suite** through it, asserting **zero changes to core source** were required. A registry test asserts download-verify-switch-remove round-trips cleanly and that removing the active model degrades to a fallback rather than breaking dictation.

**Pluggable seam:** all of them, finally proven rather than asserted.

**Dependencies:** C2, C3, C5, C9.

---

## Capability → phase map

| ID | Capability | Phase | Seam established or proven |
|----|-----------|-------|----------------------------|
| C1 | Audio capture + global hotkey | P0 | `AudioCapture` |
| C2 | Local ASR (Parakeet/FluidAudio) | P0 | `ASREngine` ← **hosted slots in here** |
| C3 | Second ASR engine (whisper.cpp) | P0 | `ASREngine` *proven* |
| C4 | System-wide injection ladder | P0 | `TextInjector` |
| C5 | Deterministic cleanup + dictionary | P1 | `CleanupProvider` ← **hosted slots in here** |
| C6 | LLM cleanup (Ollama + BYOK) | P1 | `CleanupProvider` *proven* |
| C7 | Latency, warm start, widget streaming | P2 | `ASREngine` streaming capability |
| C8 | Injection matrix + strategy memory | P2 | `InjectionStrategyStore` |
| C9 | Kokoro voice output | P3 | `SpeechSynthesizer` ← **hosted slots in here** |
| C10 | Streaming turn-taking + barge-in | P3 | `VoiceActivityDetector`, `TurnDetector` |
| C11 | Dual mode | P3 | `SessionMode` |
| C12 | Context provider | P4 | `ContextProvider` — *local only, by design* |
| C13 | Actions and MCP | P4 | `ActionProvider` |
| C14 | Model registry + out-of-tree proof | P5 | all, proven |

---

## Guardrails

Every capability above is checked against these before it ships. A capability that fails one is wrong, however useful it looks.

1. **No transcript is ever lost.** Every path terminates in recoverable text. This has no acceptable non-zero failure rate.
2. **Zero network calls in the default configuration.** Asserted by a CI test (C6) that is a permanent release blocker. Egress is opt-in and badged at the point of use.
3. **macOS only.** No cross-platform abstraction is built speculatively. Cross-platform is a decision for after the macOS experience is genuinely good, and premature abstraction for it would cost us the ANE path.
4. **No cloud in the OSS core.** BYOK is the user bringing *their* endpoint, not us shipping ours. The hosted tier is a later, separate, opt-in layer.
5. **The local core is never crippled.** A hosted provider may only ever be *added* to a seam. No local implementation is removed, degraded, or feature-gated to create upsell pressure. If this rule is ever violated, the open-core promise is broken and the project has lost the thing that made it worth building.
6. **Dictation before assistant.** No capability from C9 onward begins before the P2 gate passes — and that gate requires **external** confirmation of dictation parity, not the founder's own satisfaction. This is the guardrail against the most likely failure mode: polishing dictation forever and never shipping the wedge.
7. **Every seam ships with two implementations.** One implementation and a promise is not a seam.
