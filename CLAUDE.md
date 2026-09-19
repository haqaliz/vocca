# Vocca: Project Context for Claude Code

This file orients a coding agent working in this repository. Read it first.

> **Status (2026-09-19).** The skeleton exists; **the product does not.**
> A Swift 6 package with **twelve library modules** — `VoccaCore`, `VoccaAudio`, `VoccaHotkey`,
> `VoccaASR`, `VoccaText`, `VoccaInject`, `VoccaSpeech`, `VoccaContext`, `VoccaActions`,
> `VoccaUI`, `VoccaUsage`, `VoccaBootstrap` — plus `VoccaNetworkProbe`, the executable that
> drives the composition inside the zero-network interposer.
> **C9 is complete** — `VoccaSpeech` is no longer a placeholder and both TTS implementations are real.
>
> **`action-safety-spine` (C13 slice 1, shipped 2026-09-19):** the safety spine of Actions/MCP
> ships as **machinery only** — the gate exists before anything can execute, which is the whole
> point. `VoccaCore/Actions/` holds the `ActionProvider` seam with its **`describe`/`invoke`
> split** (a pure `describe` renders the concrete sentence; only `invoke` acts — without the
> split, "dry-run never touches the provider" and "the confirmation states concretely what will
> happen" cannot both hold), the Foundation-free vocabulary, `BlastRadius`,
> `ActionConfirmation` (`public struct`, **`internal` init**) and `ActionGate`; `VoccaActions/`
> holds the append-only audit store (one file per event, ordinal names, monotonic `Duration`
> instants, a byte-level pin whose one deliberate divergence is that **`summary` may carry
> text**). **Nothing executes** — `NullActionProvider` exposes zero tools, and the gate is the
> only site that may mint a confirmation (a lint spanning `Sources/` **and** `Tests/` confines
> construction to `ActionGate.swift`, so a forging test fails even though it would compile). The
> load-bearing acceptance holds: a destructive invocation without a token is refused **by
> attempting the call**, not by observing that no prompt appeared. Two trust boundaries are
> recorded rather than implied — **the blast radius is the provider's own claim**, so local
> policy may only *escalate* it, never de-escalate (a lying provider can only cause the user to
> be asked more often than necessary); and **`ActionApproval.granted` asserts a human approved
> and cannot verify it** (N2). **Deviation D2, measured not assumed:** the zero-network
> interposer counts loopback as NETWORK on purpose, so an MCP server on `127.0.0.1` is a
> violation and stdio is the only permitted transport — but a restricted child ignores
> `DYLD_INSERT_LIBRARIES` *and purges it from the environment it passes on*, so
> `/usr/bin/env node server.js`, any shell wrapper and any Apple platform binary are **blind**.
> The failure mode is a **green test while a child egresses**; the transport prohibition lint
> makes reaching for a transport a reviewed edit, and `PROBE-ACTIONS` proves only that the audit
> store reaches no network name. **No gate passes; guardrail 7 is unmet (D3 — `MCPProvider` and
> `ShellProvider` both PENDING, and `NullActionProvider` is a shipped default rather than a
> second implementation); R8 is mitigated in structure, never measured — nothing executes, so
> there is nothing to count.** The G5 pin was **not** re-anchored: this slice wires nothing into
> the composition root and all three digests are unchanged. No SMOKE rows (steps stop at 143) —
> deliberate, since nothing executes. Test floor: **2551**.
>
> **`context-provider` (C12, shipped 2026-09-18):** the context half of the wedge is real —
> the seam with two local implementations, the per-app consent gate, the visible indicator and
> the one-action kill switch, the BYOK exclusion grant. The `ContextProvider` seam in
> `VoccaCore/Context/` (`ContextSnapshot`, `NullContext` — the shipped default, reads nothing)
> and the new **`VoccaContext`** module: `AccessibilityContext` behind its own per-seam AX and
> Secure Input permit files (Secure Input refused first, failures resolve to the empty snapshot,
> never a throw; recorded deviation D1 — the seam is synchronous/non-throwing, so the adapter is
> an actor with a `nonisolated` witness) and `PersistentConsentStore` (`context-consent.json`,
> bundle IDs only, capped 512, the byte-level pin). `ContextConsentGate` is the never-read
> decision — an unconsented app is **declined before any AX call** (not read-then-discard, never
> read). `ContextGrantGate` is the AND-gate (per-app consent **and** the global off-by-default
> BYOK grant, never either alone) owning the ≤4 KB bound; the gated payload field is declared
> last so the absent-grant body is byte-identical to today's. The widget carries the persistent
> `eye` badge (never lights on Secure Input — a reducer row), the menu bar the one-action
> **"Stop reading context"** kill row, the Apps tab the per-app **"Allow context"** consent
> (default off, never a blanket allow), General the Context section, Cleanup the
> **"Include app context in cloud cleanup"** toggle. The additive `AppBootstrap` composition
> (`ContextWiring.swift`) is driven by `PROBE-CONTEXT` inside the zero-network interposer; the
> G5 pin was deliberately re-anchored twice (`6d98acf4…0448` → `9895f45a…` → `464b0d5a…`, never
> an edit-to-match; the dictation files' digests unchanged). SMOKE 139-143 are **written and
> runnable** — the first real resolution run, the consent/never-read audit, the indicator, the
> one-action kill switch, the BYOK never-in-payload audit — recorded, never gated, executed by
> nothing in CI; **no context-accuracy percentage exists until the founder runs SMOKE 139 on a
> machine with an Accessibility grant**. The two privacy acceptances (never-read,
> never-in-payload) are structural — asserted in CI and observed on the real surface by SMOKE
> 140/143. **No gate passes; this is the fourth unit built ahead of the uncleared P2/P3 gates
> under the recorded posture**; context is never persisted beyond the turn and never egresses —
> the seam has no hosted counterpart by design; zero network. Test floor: **2475**.
>
> **`dual-mode` (C11, shipped 2026-09-16):** the CONVERSING surface is real — the mode
> machine, the wired loop, the honest reply stand-in. The `SessionModeMachine` with the closed
> 7-row transition table and the epoch-minted `ModeSession` reset carrier (the acceptance
> asserts **no `TextInjector` call is ever made from the converse path** — type/assertion, not
> discipline — and the mode-transition test asserts full state reset with no carryover of
> buffer, transcript, or target); the `ReplyGenerator` seam with `EchoReplyGenerator` (the
> shipped default — your words back byte-for-byte) and `AcknowledgmentReplyGenerator` ("Vocca
> is listening."); the additive converse composition in `VoccaBootstrap` (`ConverseWiring.swift`,
> `ConverseLoopDriver` + `ConverseTurnFailure`) driven by `PROBE-CONVERSE` inside the
> zero-network interposer; the CONVERSING widget state with its five cues (notched pill,
> distinct hue, `◈` labels, lower tick, never a target name); the per-mode cleanup selection
> consumed at last (`resolve(mode: .conversing)`); the persisted converse chord `⌥⇧Space` with
> the two-chord rebind surface, the collision refusal and the in-flight refusal; and the
> routing close that made the machine the chords' owner (chord press → `machine.observe` →
> driver start/stop, the stop chord leg, system-trigger stops, the menu toggle, the projection
> feed). SMOKE 134-138 are **written and runnable** — the full spoken exchange (≥5 turns, ≥1
> barge-in, keyboard untouched), mode clarity (0 mis-injections), the chord rebind, the
> menu-bar toggle, the never-injects check — recorded, never gated, executed by nothing in CI.
> The G5 pin was deliberately re-anchored four times (additive converse wiring in
> `AppBootstrap` each time — final digest `6d98acf4…0448`, never an edit-to-match); the
> dictation files' digests are unchanged and the PRODUCT_SPEC five-cue prose drift was
> corrected (O7). **No gate passes; the P3 gate's conversational leg stays formally unmet until
> C13's real agent** (the shipped reply generator is an honest stand-in); the dictation path is
> byte-for-byte untouched (the pin proves it); zero network. Test floor: **2350**.
>
> **`turn-taking-barge-in` (C10, shipped 2026-09-15):** the P3 voice loop ships as **machinery,
> not surface**. The seams and implementations are real: `VoiceActivityDetector` — `SileroVAD`
> over FluidAudio's `VadManager` (C2-store-provisioned, path-injected, the offline pin recorded,
> the "Beta Status" doc comment a recorded risk note) plus the pure `EnergyVAD` fallback;
> `TurnDetector` — `SilenceThresholdDetector` shipped, `ParakeetEOU` **PENDING — Branch B** (the
> EOU exists in the pinned SDK 0.15.7 only as the ASR-integrated `StreamingEouAsrManager`, never
> a standalone scored call); `ContinuousAudioSource` + `StreamingCapture` (the loop's continuous
> capture, one conformance, ownership refused at a second start); `PlaybackEngine` +
> `SystemPlayback` (`VoccaAudio/Playback/`'s first file, the offline manual-rendering tests
> green); and the `TurnTakingLoop` coordinator with the `EchoGate` and the 5×-weighted
> `TurnCommitmentScorer` (scripted corpus in CI: passing 1.0000, planted 0.0000 — the gate that
> cannot fail proves nothing — late-commit 0.2500). The composed **headless** halt measures
> **70 ms** at the contract thresholds over the injected clock — labeled headless, never a real
> claim. The real VAD's classify cost measured **0.2 ms** on the founder's machine 2026-09-15
> (`VAD-CLASSIFY-LATENCY 0.2ms … recorded-never-gated`). SMOKE 131-133 are **written and
> runnable** — the real conversational set (≥95%, 5× weight), the ≤200 ms real-playback halt
> (`TURN-HALT <ms>ms recorded-never-gated`), echo rejection on speakers (0 instances,
> `ECHO-LOOPBACK <device> recorded-never-gated`) — recorded, never gated, executed by nothing in
> CI (the env-gated suite skips visibly). The dictation path is byte-for-byte untouched
> (digest-pinned), and the zero-network invariant stays green over `PROBE-TURN`. **No gate
> passes; no user-visible surface ships in this unit** (the CONVERSING surface is C11's). Test
> floor: **2160**.
>
> **`kokoro-voice-output` + `kokoro-binding` (C9, shipped 2026-09-12 → 2026-09-14):** the
> `SpeechSynthesizer` seam is real (`VoccaCore/Speech/`: `AudioChunk`, `VoiceIdentity`, the
> protocol with cancellation as a first-class operation — the ≤50 ms halt contract C10's
> barge-in depends on — and the `SentenceChunker` with its shipped shallow abbreviation rule),
> and **both implementations are real**. The **system renderer**
> (`VoccaSpeech/System/SystemSynthesizer.swift`, AVSpeechSynthesizer `write(toBufferCallback:)`,
> one utterance per sentence chunk, cancel via a generation-tagged flag queue — `stopSpeaking`
> kills the re-invoke, found and fixed test-first on real speech) measured **~178.8 ms**
> time-to-first-audio on the founder's machine (SMOKE 129 — recorded, never gated). The
> **Kokoro engine** (`VoccaSpeech/Kokoro/KokoroEngine.swift`) is the runtime decision
> **implemented** — Jud/kokoro-coreml (Apache-2.0) CoreML/ANE, provisioned through the C2
> store with the path injected from the composition root, one voice (af_heart), with the
> vetting gate's three corrections recorded: the phonemizer is the port's bundled English G2P
> + BART fallback (not Misaki), both dependencies declare `swift-tools-version: 6.2` (CI moved
> Xcode 16 → 26), and the artifact is the single `models-2026-03-23` tarball with
> `vocab_index.json` absent (the port's bundled-tokenizer fallback covers it); the VoccaBridge
> C-shim reservation is recorded as overtaken by the ecosystem. **Kokoro TTFA measured
> 232.5 ms warm** (SMOKE 130 — recorded, never gated, under the P3 ≤300 ms budget). The
> parameterized suite runs over a stub in CI and over both real renderers env-gated; the
> zero-network probe drives both modules. **No gate passes; no user-visible surface ships in
> this unit** (playback/ducking is C10's, the converse surface is C11's). Test floor: **1978**.
>
> **`daily-use-ledger` (2026-09-07):** the P0 gate's observable legs are now recorded rather than
> remembered — and one of them was **not computable at all** until this unit. `SessionOutcomeClass`
> `.failed` covered six sites of which only one meant a transcript was lost, so the gate's
> zero-loss leg (`ROADMAP.md:96`) was unmeasurable *in principle*; `.lost` now separates them at
> exactly one site. Shipped: `SessionKind` (onboarding separable from real work — its injector
> never holds, so a refused TRY IT is a lost transcript), `CalendarDay` with hand-written
> proleptic-Gregorian arithmetic, `DayAggregate`'s fold, `UsageWindow` (30 days; a streak counts
> only days a transcript existed), a bounded latency histogram whose bounds straddle the P2 targets
> so "is p95 ≤ 800 ms?" answers exactly, the new **`VoccaUsage`** adapter module persisting
> `~/Library/Application Support/Vocca/usage.json` atomically and shape-only, the wiring (ledger
> sink, folds held until the launch load, writes debounced at 60 s and **never inside a
> dictation**), and a sixth Settings tab, **Usage**. Test floor: **1930**.
> **No gate passes.** This instruments the P0 gate; it does not meet it — seven consecutive days
> have not accumulated, no streak number exists, and no real session has been folded on this
> machine. The gate's matrix leg is untouched, and the tab's rung tallies are counts, never an
> injection-success rate. Two postures were deliberately revised and recorded, not drifted: the
> ledger no longer "never leaves the process" (it persists, clearable, with a byte-level pin that
> no transcript text or wall-clock time can reach the file), and `ARCHITECTURE.md` now names
> `usage.json` where it had reserved `metrics.sqlite`. See `docs/STATUS.md`.
>
> **`unmeasured-numbers-sweep` (2026-09-04):** the sweep's numbers are recorded, never gated —
> SMOKE 102 verified both whisper tiers against the shipped manifests (bytes from
> `ggerganov/whisper.cpp`, Hugging Face — the provenance gap is closed); whisper's first real
> WER runs — **both tiers (turbo + q5_0), all six fixtures WER 0.0000** (the seeded tables
> cleared with margin — no re-baseline; the tolerances stand); the streamed cycle verified on
> real audio (10 partials; streamed final == batch text-for-text); short-audio measured
> (0.2/0.5/1 s transcribe through both paths — no refusal-and-throw); the O(n²) cost row
> recorded (7.82×/8.09×, never gated); the latency composite recorded both variants (batch
> total p50 113 / p95 358; streaming 115/365, **over the 60 s fixture** — the suite has no
> 10-second clip — suppression not-suppressed, cleanup `notPresent`), with the margin row in
> `tolerances_20260825.md` **pending founder ratification**; whisper's Core ML encoder observed
> absent from the shipped manifest (Metal/CPU — affects latency, not accuracy). The engine-picker
> copy decision is **surfaced, not signed** — the taglines stay the spec's own words. Test floor:
> 1758. **Still unmeasured: the rest of the matrix, F2 (corpus not recorded — founder session
> pending), the external-users leg, the release/notarization, and every gate.** See
> `docs/STATUS.md` for the honesty block.
>
> **`release-distribution` (2026-09-03):** the first installable release exists —
> `v0.2.0`, a real-bundle DMG with the symlink gate executed, the cask published to
> `haqaliz/homebrew-vocca` and `brew install` proven on the founder's machine (spctl
> `rejected` — the recorded pre-notarization baseline). The notarization half of
> `docs/planning/notarization/runbook.md` is recorded **blocked — not purchased** (no
> Apple Developer Program); the quarantine `xattr` line is still required everywhere.
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
> **The matrix feature is closed by founder decision (2026-09-12).** Its last code shipped
> test-first: the **gated frontmost-app fallback** (`electron-target-resolution`, PR #33) —
> Chromium/Electron apps (VSCode, Teams, Discord, ChatGPT, Obsidian) resolve a target now
> instead of refusing at rung 0 with `.noFocusedField`, because the fallback supplies the
> frontmost app's bundle ID when AX answers nil, gated on `.regular` policy + a seeded
> no-field set (`["com.apple.finder"]`); the ladder decision and `TargetContext` are
> byte-for-byte untouched, so a genuine no-field state still refuses. Floor 1936 → 1949.
> **The feature is closed, not finished** — the live proof (5 Electron matrix rows on v0.3.1
> + the desktop-refusal check) was waived by founder decision; FMS stays not computable, no
> gate passes, and no injection-success percentage may be quoted. Open threads named in the
> record: step 92, GoogleDocs, the 3 permanent skips (17/20 ceiling), the P2 external-users
> leg. See `docs/STATUS.md` for the honesty block.
>
> **`injection-matrix-record` (2026-09-03):** the matrix's evidence chain is real — the app
> emits `session opened` + `delivery` info lines (shape-only, no transcript text) from the
> ladder's delivery seam, and `Scripts/injection-matrix.sh` writes its promised per-row JSONL
> run log — and the first tracked row is recorded with **file-based** evidence: Notes ran,
> the accessibility rung was demoted with a fresh re-probe window (`strategies.json`), the
> row failed byte-compare. The matrix run is **incomplete** (1 of 20 deliverable rows run —
> the Notes control row on v0.2.1: `bytes_matched: true` after the byte-compare defect fix,
> rung miss as the demotion-honored outcome; FMS **not computable**); the unit concluded
> early by founder decision — the remaining 16 rows + step 92 are unexecuted and resumable;
> `--verify-bundle-ids` 19 confirmed / 0 mismatched; the unified-log evidence chain is now
> **proven live** (`session opened` + `delivery rung=clipboardPaste` captured for the control
> row) — the file chain stays load-bearing. The byte-compare normalization defect was fixed
> test-first (self-check pin, CI-driven). A pre-existing re-warm test flake was fixed deterministically
> (an entry counter on `DictationEngineResolver`, behavior-invisible). **Still unmeasured: the
> rest of the matrix and every gate.**
> See `docs/STATUS.md` for the honesty block.
>
> **Measured for the first time (`p2-gate-measurement`, 2026-09-01):** Parakeet's real WER
> passes all six provisional fixtures offline; the first real streaming final is
> non-empty and attributed; the latency benchmark (both variants) runs at asr p50
> 79–102 ms / p95 354 ms, warm-start at 0.348× (within the 1.2× bound), re-warm at
> 82–85 ms; the equivalence verdict is **NO-GO** (recorded — the latency-win claim is
> blocked, the feed ships); the manifest digests verify against provisioned bytes; the
> first real dictations delivered (founder-reported) with the loop's invariants holding.
> **Still unmeasured: the rest of the matrix and every gate.** See
> `docs/STATUS.md` for the honesty block.
>
> **`settings` (2026-09-01):** the settings window is sidebar-based (Deck-style
> `NavigationSplitView` in a `WindowGroup`-shaped window, sidebar-toggle swept out), and
> General has **Keep in menu bar**
> — with it on, ⌘Q / Dock quit is refused and the app stays in the tray (closes Settings,
> drops the Dock icon), while the tray menu's Quit and onboarding Restart always quit
> (`AppQuitPolicy`, `settings.keepInTray`). Test floor: 1758.
>
> **`App/` + `Vocca.xcodeproj`** build a signed, unsandboxed, hardened-runtime `Vocca.app`
> with the microphone entitlement, `LSUIElement`, and the frozen bundle id `dev.vocca.Vocca`.
> **`Tests/HarnessTests/`: 2551 tests**, including the zero-network invariant (a `dyld`
> interposer over **eight** libSystem entry points — `connect`, `connectx`, `sendto`,
> `sendmsg`, three resolvers and `socket`; `connect` alone would let a URLSession request
> through unseen, and **loopback counts as NETWORK on purpose**), module-boundary and per-seam
> lint, and the built-bundle and entitlement contracts. CI runs three jobs; every `swift test` goes through
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
