# Vocca: Architecture

> **Status: authoritative.** Per `CLAUDE.md`, this document governs technical direction once it exists — it now does. Where this contradicts the "proposed" tech direction in `CLAUDE.md`, this wins. Where it contradicts `docs/ROADMAP.md` on *sequencing*, the roadmap wins.

This is the build document. `ROADMAP.md` says what we prove and when; `CAPABILITY_ROADMAP.md` says what gets built in what order; **this says what the things actually are** — the types, the interfaces, the threading rules, and the failure semantics that let fourteen capabilities built weeks apart line up.

---

## 1. The invariants the architecture exists to enforce

Every structural decision below traces to one of these. If a design choice doesn't serve one, it's a preference, not architecture.

| # | Invariant | How the architecture enforces it |
|---|-----------|----------------------------------|
| **I1** | **A transcript is never lost** | `TranscriptCustody` (§10) owns every transcript from ASR completion to confirmed delivery. Nothing can drop it, including a crash. |
| **I2** | **Zero network in the default config** | Network access is confined to two named types: **`ModelDownloader`** (the model store's download machinery, `VoccaASR/Models/`, which owns the first file permitted to name `URLSession` — asserted by a lint, H8) and **`DefaultLLMTransport`** (`VoccaText/LLM/`, the second `URLSession`-naming file, named by `llm-transport` as C6's BYOK client — the H8 lint confines both, and a third file never joins them). A CI interposer asserts zero connections on the default path (§14). |
| **I3** | **Latency is budgeted per span** | The dictation pipeline (§6) has an explicit per-stage budget; every stage reports its own timing. |
| **I4** | **Every seam has ≥2 implementations** | §5 lists them. A seam with one implementation is an assertion, not a seam. |
| **I5** | **Cleanup and context can never break dictation** | Both are architecturally *optional* stages that degrade to pass-through on any failure or timeout. |
| **I6** | **The UI thread never blocks on I/O, models, or AX** | Actor isolation (§7). AX calls on the main thread freeze the app — this is a documented macOS trap, not a theoretical one. |

---

## 2. Process and language model

**One process. One language. No IPC on the latency path.**

```
Vocca.app  (single process, Swift 6, strict concurrency)
│
├── VoccaBootstrap Swift    — @main, composition root         @MainActor
├── VoccaUI        SwiftUI  — widget, settings, onboarding    @MainActor
├── VoccaCore      Swift    — orchestration, session state    actors
├── VoccaAudio     Swift    — capture, playback, VAD          realtime + actor
├── VoccaHotkey    Swift    — the CGEvent tap behind the seam tap callback + actor
├── VoccaASR       Swift    — ASREngine implementations       actor
├── VoccaText      Swift    — cleanup, dictionary             actor (pure-ish)
├── VoccaInject    Swift    — AX / Pasteboard / CGEvent       actor (never main)
├── VoccaSpeech    Swift    — SpeechSynthesizer impls         actor
└── VoccaBridge    C/C++    — reserved: second C-ABI consumer  isolated
```

> **Amended (`second-asr-engine`, 2026-08-10).** This row used to read *"whisper.cpp, Kokoro if
> needed"* — the assumption that a C-ABI consumer needs its own C/C++ module. C3 proved
> otherwise: the whisper.cpp bridge ships **inside `VoccaASR`** as `VoccaASR/Whisper/WhisperCAPI.swift`,
> one file per seam (the H7/H8b precedent — the one file permitted to name the `whisper_` /
> `WHISPER_` / `import whisper` family, pinned two-sided by `WhisperSeamTests`). The bridge is
> translated C with no decisions, so it needs no module boundary of its own; it only needs the
> lint. `VoccaBridge` stays reserved for a *second* C-ABI consumer that genuinely needs its own
> module boundary — Kokoro (C9) would be the first candidate, and the reserve is written, not
> promised.

**Why single-process Swift** (locked in planning): direct access to `AXUIElement`, `CGEvent`, and `NSPasteboard` without a bridge; FluidAudio's CoreML/ANE models drop in natively; and nothing sits between key-up and text-on-screen except our own code. A Tauri/Rust shell would buy cross-platform we explicitly deferred and cost us the ANE path — the fastest ASR route available on this hardware.

**Swift 6 strict concurrency is on from commit one.** Retrofitting it onto an audio pipeline with a realtime thread, an actor graph, and main-thread UI is materially harder than starting with it.

Modules are **Swift Package Manager targets** in one repository. The dependency graph is strictly acyclic and **points inward to the core**: `VoccaCore ← {VoccaAudio, VoccaHotkey, VoccaASR, VoccaText, VoccaInject, VoccaSpeech}`, with one deliberate outward exception — the composition root: `VoccaBootstrap → {VoccaCore, VoccaAudio, VoccaHotkey, VoccaASR, VoccaInject, VoccaUI}`. It is the only module permitted to import adapters, and it is itself imported by nothing but the zero-network probe (see §14).

> **Amended (`dictation-loop`, 2026-08-12).** This paragraph previously read
> `VoccaBootstrap → VoccaUI → VoccaCore ← {…}` — the root had no edges because the loop was not
> wired. The dictation-loop unit gave the root its edges: `configure` composes the tap, the
> session machine, the microphone, the engine, the ladder and both panels, so the root must name
> the adapters. The amendment is exactly the rule it appears to break: the *adapters* still point
> only at the core (the seam lints enforce it file by file), and the root's imports are what make
> the composed loop drivable by `VoccaNetworkProbe` inside §14's coverage guard. `VoccaBootstrap`
> gained `VoccaCore`, `VoccaAudio`, `VoccaHotkey`, `VoccaASR`, `VoccaInject` and `VoccaUI`; it is
> still imported by no module except the probe.

> **Amended (`deterministic-cleanup`, 2026-08-15).** The inward-ring graph above has declared
> `VoccaText` since planning — the enforced lint never matched it until the rules-engine aspect
> moved the module to the adapters (the reviewed `ModuleBoundaryTests` edit, `VoccaAudio`'s
> precedent): declaration and enforcement now agree, because `VoccaText/Rules/` implements the
> `CleanupProvider` seam's engine, whose vocabulary (`ReplacementRule`) lives in the core.

**`VoccaCore` imports nothing** — not Foundation, not a system framework, and not a sibling module. It owns the seams (`HotkeyEventSource`, `SessionAudioSource`, `ASREngine`, `SpeechSynthesizer`, …) and the plain-data vocabulary they are phrased in (`RawKeyEvent`, `ModifierSet`, `SessionOutcome`, …). **Adapters depend on the core** to implement those seams, and each imports `VoccaCore` and no other Vocca module. This is what makes each capability testable in isolation: every branch worth testing is expressed in types a `swift test` run can construct on a machine with no permissions, no microphone and no network, and the untestable half is reduced to translation with no decisions in it.

> **Amended (`hotkey-source`, 2026-08-05).** This paragraph previously declared the arrow the other way — `VoccaCore → {leaves}`, with "leaf modules never import `VoccaCore`". That was never consistent with the enforced rule that `VoccaCore` imports nothing at all (`CoreBoundaryTests`, an empty allow-list), and so it was never realised: the core could not depend on a leaf without an import the other lint forbids. It went unnoticed because every leaf was a placeholder. `VoccaHotkey` is the first module to implement a core-owned seam — its flag translation returns a `ModifierSet` — which forced the resolution. The direction above is the one that survives: `VoccaCore` importing an adapter is the actual architectural error, because it is what would drag `CGEvent` and `AVAudioEngine` into the one module that must have neither. **The empty allow-list is the property being protected, and it is unchanged.** A module that has not yet implemented a seam stays a leaf and may still import nothing; `VoccaAudio` moves when `SessionAudioSource` gets a real implementation.
>
> **Amended (`local-asr`, 2026-08-09).** `VoccaASR` joined as the second adapter, implementing the `ASREngine` seam (Parakeet via FluidAudio) and the model store. Its move is the reviewed edit `ModuleBoundaryTests` demands — and it carries the same confinement discipline as `VoccaHotkey`'s, one file further out: the SDK itself is confined to exactly one `Sources/` file by the H8b lint (`ParakeetSeamTests`), so the dependency can never leak a decision (or an egress path — `ModelHub` is in the linted family) into a module CI can test.

**But SwiftPM alone cannot produce a shippable app, and that is a structural fact, not a packaging detail.** An SPM `.executable` builds a bare Mach-O, not a bundle — and macOS TCC keys every grant to a **bundle identifier plus a code signature**. A bare executable therefore cannot carry `NSMicrophoneUsageDescription` (so the microphone prompt has nothing to say), and cannot durably hold a Microphone or Accessibility grant across rebuilds. So the repository also carries a **thin Xcode app target** (`App/`, `Vocca.xcodeproj`) that owns *only* bundle assembly, `Info.plist`, entitlements, and signing. Every line of real code stays in the local SPM packages — which is what keeps modules testable headlessly and keeps them inside the zero-network coverage guard (§14), since the guard walks package targets.

One entitlement deserves naming here because it is routinely misfiled as sandbox-only: **`com.apple.security.device.audio-input` is a hardened-runtime capability and applies *outside* the sandbox too.** We are not sandboxed (§13) and we are hardened-runtime, so we still need it. Omit it and the microphone is denied outright — and the permission prompt never appears at all, which presents as "the mic is broken" rather than as a permissions problem.

---

## 3. Directory layout

```
Sources/
  VoccaBootstrap/            # @main, composition root, permission bootstrap.
                             #   Deliberately an SPM target and not the Xcode app
                             #   target, so the composition root is inside §14's
                             #   zero-network coverage guard like everything else.
  VoccaUI/
    Widget/                  # the floating pill + its states
    Settings/
    Onboarding/              # the five-step first-run flow (shipped `first-run-permissions`,
                             #   2026-08-27)
  VoccaCore/
    Session/                 # DictationSession, ConverseSession, SessionMode
    Custody/                 # TranscriptCustody — I1 lives here
    Pipeline/                # stage orchestration + latency spans
    Config/                  # Configuration, persistence, defaults
  VoccaAudio/
    Capture/                 # AudioCapture impls
    Playback/                # duckable output for barge-in
    VAD/                     # VoiceActivityDetector, TurnDetector
  VoccaHotkey/               # The CGEvent tap, and the flag translation above it.
                             #   The HotkeyEventSource seam it implements is declared
                             #   in VoccaCore with every other seam (§2) — a module
                             #   that imports nothing cannot name CGEventFlags, which
                             #   makes half of acceptance H7 a compile-time property
                             #   rather than a text lint. Amended `hotkey-source`,
                             #   2026-08-05; this line used to place the seam here.
                             #   Separate from VoccaInject even though both speak
                             #   CGEvent: one reads the keyboard, one writes it, and
                             #   they fail for entirely different reasons.
  VoccaASR/
    Parakeet/                # FluidAudio-backed
    Whisper/                 # whisper.cpp-backed; WhisperCAPI.swift is the bridge —
                             #   the one file in Sources/ permitted to name the C ABI,
                             #   seam-pinned two-sided (WhisperSeamTests). Amended
                             #   `second-asr-engine`, 2026-08-10.
    Models/                  # ModelRegistry, download, verify
  VoccaText/
    Rules/                   # deterministic cleanup
    Dictionary/              # user replacement rules
    LLM/                     # Ollama, BYOK
  VoccaInject/
    Ladder/                  # the four-rung strategy
    Keystroke/               # the one CGEvent-naming file in the module (H7 per-seam table)
    Accessibility/           # AX wrappers, Secure Input detection
    Clipboard/               # save/set/paste/restore protocol
    Memory/                  # InjectionStrategyStore
  VoccaSpeech/
    Kokoro/
    System/                  # AVSpeechSynthesizer
  VoccaContext/              # P4 — ContextProvider
  VoccaActions/              # P4 — ActionProvider, MCP client
  VoccaBridge/               # RESERVED — a second C-ABI consumer (Kokoro, C9) would
                             #   claim it. C3's whisper bridge lives in VoccaASR/Whisper/
                             #   instead (see the §2 amendment). Amended `second-asr-engine`,
                             #   2026-08-10.
  VoccaNetworkProbe/         # TEST-ONLY. Links every module and exercises it under
                             #   the interposer for §14. Never shipped.
  CVoccaNetworkInterposer/   # TEST-ONLY. dyld interposer over connect(2), loaded
                             #   into the probe. Never shipped, never linked by app code.
App/                         # the thin Xcode app target — Info.plist, entitlements,
                             #   signing. No logic lives here (§2).
Tests/
  <mirrors Sources>/
  Fixtures/                  # audio, transcripts, golden outputs
  Harness/                   # app matrix driver, fault injection, benchmarks
```

> **Amended (`injection-adapters`, 2026-08-09).** Acceptance H7 became a **per-seam** rule when the
> injection ladder's keystroke rung needed a second `CGEvent`-naming file. The tap seam keeps its
> rule untouched — one permitted file, `VoccaHotkey/CGEventTapSource.swift` — and the keystroke
> seam gains one permitted file of its own, `VoccaInject/Keystroke/KeystrokeSource.swift`, the sole
> CoreGraphics-naming file in its module. The seam lint's permitted-file list is now a table keyed
> by seam (`InjectionSeamBoundaryTests`): one file per seam, ever, with the old tree-wide
> "at most one file" assertion replaced by a per-seam count assertion (the successor of
> `HotkeySeamBoundaryTests.testAtMostOneFileMayNameEventTypes`, not a weakening). Both permitted
> files are pinned two-sided — each must actually name the family, and nothing else in `Sources/`
> may — and the laundering-route rules (no typealias in a permitted file, no `@_exported` of a
> non-Vocca module anywhere, no extension of a CoreGraphics type under a local protocol) now hold
> against the table's union.

---

## 4. Core types

These are the contracts every seam speaks. They're deliberately small and `Sendable` — they cross actor boundaries constantly.

```swift
// ─── Audio ────────────────────────────────────────────────────────────────
/// Immutable PCM. 16 kHz mono Float32 is the canonical interchange format;
/// engines that want something else convert internally, never the caller.
struct AudioBuffer: Sendable {
    let samples: [Float]          // 16 kHz mono, -1.0...1.0
    let sampleRate: Int           // always 16_000 at seam boundaries
    var duration: TimeInterval { Double(samples.count) / Double(sampleRate) }
}

// ─── Transcription ────────────────────────────────────────────────────────
struct Transcript: Sendable {
    let text: String
    let segments: [TranscriptSegment]
    let engine: EngineIdentity     // never nil — I1 depends on attribution
    let isFinal: Bool              // false for streaming partials (C7)
    let audioDuration: TimeInterval
}

struct TranscriptSegment: Sendable {
    let text: String
    let range: Range<TimeInterval>
    let confidence: Float?         // nil where the engine exposes none
}

struct EngineIdentity: Sendable, Hashable {
    let id: String                 // "parakeet-tdt-0.6b-v3", "whisper-large-v3-turbo"
    let displayName: String
    let isLocal: Bool              // false ⇒ egress badge is mandatory
}

// ─── Injection ────────────────────────────────────────────────────────────
struct TargetContext: Sendable {
    let bundleID: String?
    let windowTitle: String?
    let isSecureInput: Bool        // IsSecureEventInputEnabled() at capture time
    let axElement: AXElementRef?   // opaque; nil when AX is unavailable
}

enum InjectionRung: String, Sendable, CaseIterable {
    case accessibility, clipboardPaste, keystrokeSynthesis, widgetFailsafe
}

struct InjectionResult: Sendable {
    let rung: InjectionRung         // which rung actually delivered
    let attempted: [InjectionRung]  // full ladder trace, for C8's memory
    let verified: Bool              // did we read back and confirm?
    let elapsed: Duration
}

// ─── Cleanup ──────────────────────────────────────────────────────────────
struct CleanupContext: Sendable {
    let target: TargetContext
    let mode: SessionMode
    let dictionary: [ReplacementRule]
    let budget: Duration            // exceed it and we return raw — I5
}

// ─── Errors ───────────────────────────────────────────────────────────────
enum VoccaError: Error, Sendable {
    case permissionDenied(Permission)
    case modelUnavailable(EngineIdentity, reason: String)
    case captureFailed(underlying: String)
    case transcriptionFailed(EngineIdentity, underlying: String)
    case injectionExhausted(attempted: [InjectionRung])  // ⇒ failsafe, never a loss
    case cleanupTimedOut                                  // ⇒ raw text, never a loss
    case cancelled
}
```

**A deliberate absence:** there is no `case transcriptLost`. It is not representable, because no code path is allowed to produce it. `injectionExhausted` is not a loss — it means the ladder fell through to the widget, which is a *successful* outcome under I1.

---

## 5. The seams

Each protocol below is the pluggable boundary named in `CAPABILITY_ROADMAP.md`. The "implementations at ship" column is the I4 proof.

| Seam | Protocol | Implementations at ship | Hosted tier slots in? |
|------|----------|------------------------|----------------------|
| Capture | `AudioCapture` | `PushToTalkCapture`, `StreamingCapture` (C10) | No — always local |
| ASR | `ASREngine` | `ParakeetEngine`, `WhisperCppEngine` | **Yes** |
| Cleanup | `CleanupProvider` | `RulesCleanup`, `OllamaCleanup`, `BYOKCleanup` | **Yes** |
| Injection | `TextInjector` | `LadderInjector` + per-rung strategies | No — always local |
| Strategy memory | `InjectionStrategyStore` | `PersistentInjectionStrategyStore`, `EphemeralInjectionStrategyStore` (tests) | No |
| TTS | `SpeechSynthesizer` | `KokoroSynthesizer`, `SystemSynthesizer` | **Yes** |
| VAD | `VoiceActivityDetector` | `SileroVAD`, `EnergyVAD` (fallback/tests) | No |
| Turn detection | `TurnDetector` | `ParakeetEOU`, `SilenceThresholdDetector` | No |
| Context | `ContextProvider` | `AccessibilityContext`, `NullContext` | **No — by design** |
| Actions | `ActionProvider` | `MCPProvider`, `ShellProvider` | No |

> *Status (core-memory aspect, 2026-08-27): the `InjectionStrategyStore` seam and its
> implementations remain unbuilt; the Core vocabulary they will persist — `InjectionStrategy`
> and the pure decisions in `VoccaCore/StrategyMemory/` — shipped in this unit's first aspect
> (see §9).*

```swift
protocol ASREngine: Sendable {
    var identity: EngineIdentity { get }
    var supportsStreaming: Bool { get }

    func prepare() async throws               // warm-start hook (C7)
    func transcribe(_ buffer: AudioBuffer) async throws -> Transcript

    /// Streaming engines yield partials then exactly one isFinal. Batch
    /// engines get a default impl that yields one final — callers never branch.
    func stream(_ chunks: AsyncStream<AudioBuffer>) -> AsyncThrowingStream<Transcript, Error>
}

protocol CleanupProvider: Sendable {
    var identity: ProviderIdentity { get }
    var requiresNetwork: Bool { get }         // true ⇒ egress badge, enforced in UI
    func clean(_ transcript: Transcript, context: CleanupContext) async throws -> String
}

protocol TextInjector: Sendable {
    func inject(_ text: String, into target: TargetContext) async -> InjectionResult
}

protocol SpeechSynthesizer: Sendable {
    var identity: VoiceIdentity { get }
    func speak(_ text: String) -> AsyncThrowingStream<AudioChunk, Error>
    func cancel() async                        // must halt ≤50 ms — barge-in depends on it
}
```

**`requiresNetwork` is load-bearing.** The widget reads it directly to decide whether the egress badge shows. A provider cannot make a network call without declaring it, because the CI interposer (§14) fails the build if a provider with `requiresNetwork == false` opens a socket.

---

## 6. The dictation path and its latency budget

The P2 gate is p50 ≤ 400 ms, p95 ≤ 800 ms from key-up to text-on-screen. That budget is allocated, not hoped for:

```
⌥Space DOWN
   │
   ├─ [ ? ms]   AudioCapture.begin() — engine started ON DEMAND, not kept warm.
   │             Cost is deliberately unquantified here: measure it, see below.
   ├─           widget → .recording, live waveform
   ├─           speculative ASR consumes the buffer as it fills  ◄── C7
   │
⌥Space UP ═══════════════ latency clock starts here ═══════════════
   │
   ├─ [ ≤30 ms] capture close + final buffer assembly
   ├─ [≤250 ms] ASREngine finalizes  (most work already done speculatively)
   ├─ [ ≤10 ms] CleanupProvider — rules path; budget-capped, degrades to raw
   ├─ [≤100 ms] TextInjector ladder — rung chosen from strategy memory (C8)
   │
   └─ text on screen                          p50 target ≤400 ms
```

**Why speculative ASR is the whole trick.** Without it, a 10-second utterance pays full ASR cost after key-up and p50 lands near a second. With it, only the tail is unprocessed at key-up, and Parakeet's RTF (~0.042 on M4) makes that tail cheap. Everything else in the budget is small by comparison — which is also why cleanup gets 10 ms and not 200: at P1 the default is rules, and if an LLM is opted into, the user has knowingly bought latency.

**Why the audio engine is *not* kept warm — privacy beats the milliseconds.** An earlier version of this document assumed a permanently-running `AVAudioEngine`, on the reasoning that a warm engine makes `begin()` nearly free. The SDK forecloses it: `AVAudioEngine.h:465-466` states that "if the engine has at any point previously had its inputNode enabled and permission to record was granted, then any time the engine is running, the mic-in-use indicator will appear." A warm engine therefore means macOS's **orange microphone dot is lit permanently, whether or not we are recording** — which for a tool whose entire pitch is "your audio never leaves your Mac" is the single most damaging signal we could emit. It would say, continuously and in the OS's own voice, the opposite of the promise. So the engine starts on `⌥Space` down and stops on release; when Vocca is idle, the dot is dark, because nothing is listening.

Three mitigations make the on-demand start cheap without running the engine:

1. **`prepare()` after every stop**, so allocation and graph setup are already done when `start()` is called.
2. **Allocate the engine, sink node, converter and ring buffer once, for the app's lifetime.** A press does `start()`/`stop()` and nothing else — never a graph rebuild, which is the genuinely expensive operation.
3. **Measure the start cost; do not assume it.** This span is inside the pre-key-up window and so outside the p50 clock, but it delays the waveform — the "it heard me" signal — and `PRODUCT_SPEC.md` promises that within one frame. Treat it as a first-class number with its own acceptance threshold rather than a rounding error.

The same header notes that an app switching between output-only and input-output configurations may want **two engine instances**, one per configuration. Worth remembering at C9, when TTS playback arrives and the naive move is to reuse the capture engine.

Note that this is separate from, and does not contradict, the **model** warm-start in C7 (`ASREngine.prepare()`, `ROADMAP.md`'s warm-start metric). A resident CoreML model holds no audio device and lights nothing; keeping the ASR engine warm is free of this problem entirely. It is specifically the *audio* engine that must go cold.

Every stage emits a span into a **local-only** `LatencyRecorder`. Never transmitted, inspectable in settings, and the CI benchmark asserts against it so a regression names its own culprit.

**The C7 remainder, as shipped (2026-08-25, `warm-start-streaming`).** The warm-start hook is
pinned and gated: launch runs `prepareIfNeeded()` exactly once (never on the session path),
`EngineTiming`'s `.firstAfterLaunch`-vs-`.warmTranscribe` samples feed a pure
`WarmStartRatio` evaluator against the 1.2 bound (`WarmStartTargets`, in exactly one file),
and the benchmark gate carries the verdict as a row — the closed four-span session record is
unchanged. The widget-only streaming *mechanism* ships behind a new Core seam
(`PartialTranscriptSink`): `DictationPipeline.routeStreaming` consumes `stream(_:)`
unconditionally (the seam's batch default is the degradation — no caller branches on
`supportsStreaming`), partials reach the widget store only, and the zero-injection-before-
final guard is a permanent test. **What is not shipped and must not be implied:** no real
engine streams yet (both `supportsStreaming == false`), the speculative pre-key-up feed is
deferred, and open question 2 below stands exactly as written — the widget guard and the
record are the claims, never a latency number CI did not produce.

---

## 7. Threading and concurrency

```
┌─ Realtime audio thread ─────────────────────────────────────┐
│  AVAudioSinkNode receiver block — NOT installTap (see below)│
│  No allocation, no locks, no logging, no Swift runtime      │
│  calls that can allocate. Writes into a lock-free ring      │
│  buffer and nothing else.                                   │
└──────────────────────┬──────────────────────────────────────┘
                       │ drain
┌─ AudioActor ─────────▼──────────────────────────────────────┐
│  Owns the ring buffer, session lifecycle, watchdog.         │
└──────────────────────┬──────────────────────────────────────┘
                       │
┌─ SessionMachine (VoccaCore), owned by whoever owns the tap ─┐
│  The orchestrator. Owns SessionMode, drives the pipeline,   │
│  owns TranscriptCustody. Single source of truth for state.  │
└───┬──────────┬──────────┬──────────┬────────────────────────┘
    │          │          │          │
 ASRActor  TextActor  InjectActor  SpeechActor
    │          │          │          │
┌───▼──────────▼──────────▼──────────▼────────────────────────┐
│  @MainActor — SwiftUI only. Renders state. Never computes,  │
│  never blocks, never touches AX.                            │
└─────────────────────────────────────────────────────────────┘
```

**Three rules that are not negotiable:**

1. **AX calls never run on the main thread.** `AXUIElementCopyAttributeValue` against an unresponsive app blocks for the full AX timeout, and on the main thread that is a frozen UI — a documented, commonly-hit macOS trap. `InjectActor` owns every AX call, with an explicit per-call timeout below the system default.
2. **The realtime audio thread does nothing but write samples.** Any allocation or lock there produces glitches that sound like a broken product.
3. **`SessionMachine` is the only place session state lives.** The widget renders a projection of it. No component infers session state from its own local flags — that's how you get stuck-recording bugs that only reproduce on someone else's machine.

   `SessionMachine` (`VoccaCore`, C1) is **synchronous and not `Sendable`** — not the actor this
   section originally sketched. A `CGEvent` tap callback is a synchronous C function that must
   return *this event's* disposition, swallow or pass through, before it returns; `await` cannot
   appear on that path, because by the time an actor hop resolved, the event would already have
   reached the focused application. So isolation belongs to whoever owns the tap, not to the
   machine itself: `hotkey-source` constructs it on `@MainActor`, runs the tap on the main run
   loop, and uses `MainActor.assumeIsolated` inside the callback. Everything the machine *returns*
   (`SessionEffect`, `SessionOutcome`) is `Sendable` and crosses freely to the actor that
   transcribes. One consequence is not optional: the machine must be **constructed** in the
   isolation domain that owns it — passing an already-built instance into an actor's `init` from
   outside is a `sending` diagnostic, not a warning, because the machine still carries no
   concurrency safety of its own once it exists.

**The capture primitive is `AVAudioSinkNode`, not `installTap`.** This document previously said "AVAudioEngine tap", which cannot satisfy rule 2 above — the rule and the mechanism were in direct contradiction, and the mechanism was the wrong one. Two reasons, both from the headers:

- **`installTap` is not documented as realtime.** `AVAudioNode.h:30` says only "CAUTION: This callback may be invoked on a thread other than the main thread" — a warning about thread-safety, not a realtime guarantee. `AVAudioSinkNode.h:64` is the API that actually states its block "will be called on the realtime thread." If we are going to write realtime-discipline code, it needs to run on the thread that has those constraints, not on one that merely might.
- **`installTap` has a 100 ms floor.** `AVAudioNode.h:86` gives its `bufferSize` as "Supported range is [100, 400] ms". A 100 ms minimum buffer is **25% of P2's entire 400 ms p50 budget**, spent before a single sample reaches us and bought nothing. That is not a cost we can optimize away later; it is structural to the API.

`AVAudioSinkNode.h:38` also notes the node "does not support format conversion", so the connection must use the input node's own output format — hardware will hand us 44.1/48 kHz, or 16 kHz over Bluetooth HFP. Conversion to the canonical 16 kHz mono Float32 of `AudioBuffer` (§4) happens on the **consumer** side, off the realtime thread, because `AVAudioConverter` allocates.

**One consequence shapes the seam.** `AVAudioSinkNode.h:48` records that the sink node is **unsupported in manual rendering mode** — the offline mode that would otherwise let CI drive audio through the real graph with no hardware. There is therefore no offline equivalent of the realtime path, which is why the `AudioCaptureSource` seam must sit **above** the node rather than wrap it. A seam drawn below the node would be untestable headlessly, permanently. See `docs/SMOKE_CHECKLIST.md` for what this costs us in CI coverage and what has to be checked by hand instead.

---

## 8. Audio session lifecycle and the watchdog

```
  idle ──key-down──► recording ──key-up──► transcribing ──► delivering ──► idle
                         │                                       │
                         └──watchdog / cancel──► aborting ────────┘
```

**The watchdog exists because key-up is not guaranteed.** The hotkey can be stolen by another app, the system can sleep, the app can lose focus mid-press, `CGEvent` taps get disabled by the system under load. A capture session that outlives its key-up is a hot mic the user didn't ask for — an unacceptable failure in a privacy-first tool.

So: every session carries a hard ceiling (default 120 s, configurable), *and* a key-state poll that verifies the physical key is still down. Either tripping ends the session **and still runs the pipeline on what was captured** — an unexpectedly-ended session yields its transcript to custody rather than discarding it. I1 has no exceptions.

`CGEvent` tap health is monitored and re-armed on `tapDisabledByTimeout` / `tapDisabledByUserInput`, which macOS issues without warning.

**Re-arming is only half of it, and the other half is the one that matters.** *(Amended 2026-08-05, `hotkey-source` phase 3.)* A disabled tap receives nothing at all, so the key-up that would have ended an in-flight session is never coming — which means every recovery must **end the session first**, before it does anything that could fail. That is unconditional across every route into `TapHealthPolicy`: the two disable notifications, `NSWorkspace.didWakeNotification` (taps die silently across sleep/wake), `com.apple.accessibility.api`, arming, and a deliberate teardown — and a health poll, which ends on every answer except "the tap is delivering and is not blocked", because it runs once a second for as long as Vocca does. That one exception is the reason the rule is worth having: a poll that ended unconditionally would end every session within a second of its start. A re-created tap always ends any in-flight session, because a tap that died may have dropped the key-up.

The two disable reasons **recover identically and are reported distinctly**: `tapDisabledByTimeout` means our own callback was too slow, and `tapDisabledByUserInput` means it was not. Only the diagnosis differs, which is why the policy returns where the tap stands and reports what happened through a separate channel — the seam itself cannot carry the distinction, since `RawKeyEvent.Kind.tapDisabled` is one kind for both.

---

## 9. The injection ladder

The single most failure-prone subsystem, and the reason its design is defensive rather than elegant.

**The premise:** `AXUIElementSetAttributeValue` on `kAXSelectedTextAttribute` **returns `.success` while inserting nothing** in a large class of apps (Electron, custom text views, browser-based editors). An AX-primary design therefore has a *silent* data-loss mode. So AX is used only where we've verified it works, and only with read-back confirmation.

```swift
func inject(_ text: String, into target: TargetContext) async -> InjectionResult {
    var attempted: [InjectionRung] = []

    // Rung 0 — refuse honestly rather than fail mysteriously.
    if target.isSecureInput {
        return failsafe(text, attempted: [], reason: .secureInput)
    }

    for rung in strategyStore.orderedLadder(for: target.bundleID) {
        attempted.append(rung)
        if let result = await attempt(rung, text, target, attempted) {
            strategyStore.recordSuccess(rung, for: target.bundleID)
            return result
        }
        strategyStore.recordFailure(rung, for: target.bundleID)
    }
    return failsafe(text, attempted: attempted, reason: .exhausted)   // I1
}
```

| Rung | Mechanism | Guard |
|------|-----------|-------|
| 1 `accessibility` | Set `kAXSelectedTextAttribute` | **Allowlist-gated + read-back verified.** Success without verification counts as failure. |
| 2 `clipboardPaste` | Save → set → synth ⌘V → settle → restore | The workhorse. Clipboard protocol below. |
| 3 `keystrokeSynthesis` | `CGEvent` unicode keystrokes | Slow; for fields that refuse paste. Chunked, rate-limited. |
| 4 `widgetFailsafe` | Text held in widget, ⌘C copies | **Always succeeds.** The floor under I1. |

**Clipboard protocol** — the fiddly part, because clipboard managers (Raycast, Alfred, Paste, Maccy) race us for pasteboard ownership:

```
1. snapshot NSPasteboard (all types, not just .string) + changeCount
2. write text, note new changeCount
3. synthesize ⌘V
4. settle delay (~80 ms, adaptive per app from strategy memory)
5. restore snapshot — but ONLY if changeCount is still ours.
   If a manager took ownership, we do NOT clobber it; we log and move on.
   Stomping the user's clipboard manager is worse than leaving our text there.
```

**Strategy memory (C8)** persists the winning rung per bundle ID, seeds known-hostile apps at first run, demotes on failure, and re-probes on a decay schedule so an app update that fixes AX is eventually noticed rather than permanently written off.

*Status (core-memory aspect, 2026-08-27): the **pure vocabulary** shipped in `VoccaCore/StrategyMemory/` — the per-app `InjectionStrategy` value, `StrategyMemory.orderedRungs` (the projection), `reprobeEligibility`, the record fold and the absolute override (S2), stdlib-only with integer epoch seconds and headless-tested. The store (§5), the memory-backed order, `LadderInjector` recording, the Apps tab and the matrix remain unbuilt — the ladder still does not learn end to end.*

---

## 10. `TranscriptCustody` — how I1 is actually enforced

An invariant that lives only in prose gets violated. This one has an owner.

```swift
actor TranscriptCustody {
    /// Takes ownership the instant ASR produces text. Returns a token that
    /// MUST be resolved. A token deinit'd unresolved is a fatal error in
    /// debug and a recovery-journal write in release.
    func take(_ text: String, session: SessionID) -> CustodyToken
    func resolve(_ token: CustodyToken, delivered: InjectionResult)
    func surrender(_ token: CustodyToken)   // → widget failsafe, still delivered
}
```

- Custody begins at ASR completion, **before** cleanup. Cleanup failure therefore cannot lose text; the raw string is already held.
- Every transcript is journaled to disk (`~/Library/Application Support/Vocca/recovery/`) until resolved, so a crash mid-injection is recoverable on next launch. Journal entries are deleted on resolve, and the directory is bounded and purged on a retention policy — a privacy tool must not accumulate a shadow archive of everything you ever said.
- The unresolved-token check is a test assertion, not just a runtime one: the fault-injection harness (§14) forces every rung to fail and asserts custody always resolves.

> **Amended (`failsafe-surface`, 2026-08-09).** The recovery half of custody shipped:
> `VoccaInject/Journal/` implements the journaling bullet above, behind the core's
> `TranscriptHolder` seam — the ladder hands a `HeldTranscript` to `hold`, which is **durable
> before it returns** (PRD R6: the write is part of the failsafe hand-off, not after it, so a
> crash between ladder exhaustion and the journal write cannot lose a transcript — asserted by
> test, not documented). The decisions live in `RecoveryJournal` — bounded eviction (oldest
> first, at a capacity the composition root sets), purge-on-resolve, load-on-launch — over an
> injected `JournalStore` seam, and `FileSystemJournalStore` is the one file in `VoccaInject`
> permitted to name `FileManager` (the journal seam's entry in the H7 per-seam table; the
> family is scoped to the module because `VoccaASR` already names `FileManager` in three files).
> Each write is an atomic temp-write-then-rename, and the journal is exercised headlessly over
> fakes *and* against a real temp directory — `FileManager` works in CI, so this adapter is
> tested, not merely linted. The `TranscriptCustody` actor above remains the future ownership
> shape; the journal is its recovery half's first implementation.

---

## 11. Cleanup pipeline

```
Transcript ──► [custody taken] ──► RulesCleanup ──► optional LLM ──► String
                     │                   │               │
                     │              always runs     opt-in only
                     │              (<10 ms)        provider-declared budget,
                     │                              caller-enforced
                     │
                     └── on ANY failure or timeout at any stage:
                         the raw transcript proceeds to injection (I5)
```

The budget lives in `CleanupContext` and is **provider-declared**: each provider declares its own
`budget` (`CleanupProvider.budget`, 10 ms for rules, 5 s for an LLM rung), the caller
(`SessionActor`) races the *declared* number with `Task` cancellation rather than trusting the
provider, and expiry is not an error the user sees — it's a silent degrade to raw text, counted
in local metrics. At P1 the default is rules, and if an LLM is opted into, the user has knowingly
bought latency (`prd.md` M1).

`RulesCleanup` is a pure function over `(String, [ReplacementRule]) -> String`: filler removal, sentence segmentation and terminal punctuation, capitalization, spoken-punctuation commands, number/unit normalization, then user dictionary rules in declared order. Pure means table-driven tests, and table-driven tests mean the rule set can grow safely.

The user dictionary is plain JSON in Application Support — hand-editable and version-controllable, because the people who need a custom dictionary most (developers, clinicians, lawyers) are exactly the people who will want to sync it.

---

## 12. Voice loop (P3) — full duplex and barge-in

```
        ┌──────────────── continuous capture ────────────────┐
        │                                                    │
  mic ──┼──► SileroVAD ──► speech? ──► ParakeetEOU ──► turn? ─┼──► ASR ──► agent
        │        │                                           │
        │        └── speech detected DURING playback ────────┼──► BARGE-IN
        │                                                    │
  spk ◄─┴──── SpeechSynthesizer ◄── duckable output ──────────┘
                     ▲
                     └── cancel() must halt ≤50 ms
```

**Barge-in signal path**, budgeted to the 200 ms gate: VAD fires (~30 ms frame) → `SessionActor` receives interrupt → `synthesizer.cancel()` (≤50 ms) → output ducked and stopped → interrupted reply discarded → capture already running, so the interrupting words are **already in the buffer**. That last point is why capture is continuous rather than started on interrupt: starting capture at interrupt time loses the first syllables, which is precisely what makes barge-in feel broken.

**Echo rejection** is not optional and must be verified on speakers, not headphones — headphones make the problem vanish and speakers are how people actually use it. Approach: known-output reference cancellation, plus a hard gate that discards capture whose energy correlates with the synthesizer's own output within the playback window.

**Turn detection scoring** weights false cutoffs **5× worse** than late commits. Being interrupted mid-sentence is the failure users won't forgive; waiting an extra 200 ms is one they never notice.

**Hold-to-talk remains available forever** as the escape hatch. When endpointing misjudges, the user must always have a mode where their finger is the ground truth.

That is unchanged by the 2026-08-25 amendment making **toggle the shipped default** (`ROADMAP.md`, `PRODUCT_SPEC.md`): "available forever" is a statement about the mode existing, not about it being the default. Both configurations of the machine are constructed and owned at every launch; `DictationLoopRoot.defaultMode` decides only which one the tap's events reach, and `setActiveMode(_:)` moves that route. The escape hatch this paragraph is about is therefore still there, and the endpointing argument it rests on is untouched — it concerns P3's VAD, which P0 does not run in either mode.

---

## 13. Models, storage, and permissions

**Storage layout** — nothing ships in the app bundle except code, so the download stays small:

```
~/Library/Application Support/Vocca/
  models/<engine-id>/<version>/     # downloaded, checksum-verified, resumable
  config.json                       # settings
  cleanup-config.json               # cleanup provider selection — hand-editable (llm-cleanup)
  dictionary.json                   # user replacement rules — hand-editable
  strategies.json                   # per-app injection memory
  recovery/                         # transcript journal (bounded, purged)
  metrics.sqlite                    # local-only latency/success — never sent
```

The BYOK cleanup rung's key lives **not here but in the login Keychain**, as
`dev.vocca.Vocca.byok-key` (app-only access, `byok-provider`): the key is never readable from the
config file, a log, or a crash surface — the file names the endpoint and the model, never the
secret.

**The onboarding completion flag is `UserDefaults`, behind a one-file seam.** `CompletionFlagStore`
(`VoccaUI/Onboarding/`) is the repository's first UserDefaults-naming file (the seam table's
reviewed amendment), key `onboarding.complete`. The read is synchronous because `main()` decides
whether to show the onboarding window on it (window-server rule: `main()` shows, `configure` never
constructs a window); only TRY IT success writes it (R4, reducer-pinned).

**Permissions matrix.** Each is requested *at the moment it's first needed*, with copy explaining what we do and don't do — never in a first-run wall of dialogs:

| Permission | Needed for | Requested at | If denied |
|-----------|------------|--------------|-----------|
| Microphone | All capture | The onboarding flow's PERMISSIONS step (`requestAccess` on the row's appear — one at a time, never a wall) | Hard block, with a direct link to the settings pane |
| **Accessibility** | **Global hotkey tap** + AX injection + context | **First launch** — the pane button is its prompt (no request API exists) | **Hard block — no hotkey, no product** |
| Automation (per-app) | Some AX targets | Per app, on demand | That app drops to clipboard rung |

> **Amended (`first-run-permissions`, 2026-08-27).** The matrix's prompts are now presented by the
> five-step onboarding window (`VoccaUI/Onboarding/`), one at a time, never a wall: the Microphone
> row calls `MicrophoneAuthorization.requestAccess` as it appears — `MicrophoneAuthorization` is
> the third AVFoundation-naming file in `VoccaAudio` (the expected-set lint's reviewed amendment)
> — and the Accessibility row's pane button is its prompt, per the note below. The reads feeding
> the live ✓/✗ are `MicrophoneAuthorization.authorizationStatus()` and
> `AXSource.isProcessTrusted()`. `SystemSettingsPane` (the two frozen pane URLs, lifted from
> `AppBootstrap`) and `AppRelaunch` (terminate + relaunch — executed by nothing in CI, the
> tap-adapter precedent) are the AppKit glue files in `VoccaUI`. The onboarding window is the
> **second focus-taking window**, following the `SettingsWindow` activation-policy dance exactly
> (`.regular` on show, `.accessory` on close). TRY IT's transcript lands through a dedicated
> delivery sink (`OnboardingDeliverySink`) — the composed pipeline with only the delivery end
> swapped, a one-decision composition (`injectorComposition(completionFlag:)`: the ladder once
> `onboarding.complete`, the onboarding sink until then). The real-machine rows are
> `SMOKE_CHECKLIST.md` steps 81–86.

**The hotkey needs Accessibility, not Input Monitoring.** This table previously assigned Input Monitoring to the global hotkey tap. That is wrong, and it is wrong in the direction that would have shipped a broken product. `CGEvent.h:274-279`: event taps "may only receive key up and down events if access for assistive devices is enabled … If the tap is not permitted to monitor these events when the tap is created, then the appropriate bits in the mask are cleared. If that results in an empty mask, then NULL is returned."

Input Monitoring covers a **listen-only** tap. Vocca cannot use one: `⌥Space` must be **swallowed**, because if it passes through, macOS inserts U+00A0 NO-BREAK SPACE into the very field the user is dictating into — a bug that corrupts the output of every single dictation. Swallowing requires an active tap (`kCGEventTapOptionDefault`), and an active keyboard tap requires **Accessibility**. Accessibility supersedes Input Monitoring, so the grant that makes injection work is the same grant that makes the hotkey work.

Two operational consequences:

- **`CGEvent.tapCreate` returning `nil` *is* the permission check.** There is no separate API that reports the grant, and no entitlement or `NS*UsageDescription` key exists for Accessibility — the system dialog's text is fixed and we cannot add a word to it. Our onboarding copy is therefore the *only* explanation the user will ever read for the scariest permission macOS asks for.
- **After a grant, the tap must be destroyed and re-created.** Its event mask was cleared at creation time, when we had no permission; `CGEventTapEnable` re-enables a tap but cannot restore a mask that was emptied. Re-arming the old tap yields a live tap that receives nothing — a silent failure. Observe `com.apple.accessibility.api` and rebuild.

**The silver lining is that the incremental cost is zero.** C4's injection ladder needs Accessibility regardless, so moving the hotkey onto the same grant removes an entire permission from onboarding rather than adding one. The correction makes first run shorter, not longer.

**Entitlements:** the app is **not sandboxed** (AX injection into arbitrary apps is incompatible with the sandbox), is Developer ID signed, hardened-runtime enabled, and notarized. It carries `com.apple.security.device.audio-input`, which — as §2 notes — is a hardened-runtime capability and is required even outside the sandbox. Signing and notarization are wired up in **week 1** — the combination of non-sandboxed + Accessibility + an active keyboard event tap draws review scrutiny, and that is not a discovery to make at ship time.

---

## 14. Testing architecture

Every seam has a fake; every capability's acceptance from `CAPABILITY_ROADMAP.md` is a test that exists before its code.

| Harness | What it does | Gates |
|---------|--------------|-------|
| **Fixture suite** | Canonical audio → expected transcript, run **parameterized over every `ASREngine`** | C2, C3 |
| **Offline assertion** | Fixture suite re-run with the network interface down | C2 |
| **Fault injection** | Forces each injection rung to fail — including AX's *silent* success-with-no-insert — in every combination | C4 |
| **App matrix driver** | UI automation across 20+ real apps, semi-automated per release | C4, C8 |
| **Network interposer** | Asserts **zero outbound connections** on the default path | C6 — **permanent release blocker** |
| **Benchmark harness** | Replays fixtures, asserts p50/p95, fails CI on regression | C7 |
| **Conversational set** | Labelled turn boundaries; scores endpointing with 5× false-cutoff weight | C10 |
| **Custody audit** | Asserts no `CustodyToken` is ever deinit'd unresolved | I1, all phases |

The load-bearing tests are the failure-path ones. Any competent implementation passes the happy path; what distinguishes this product is that the ladder's fourth rung always catches, and only fault injection proves it.

---

## 15. Deliberately not in this architecture

- **No cross-platform abstraction layer.** macOS-only is locked; a speculative platform seam would cost us the ANE path and buy nothing. Revisit only after the macOS experience is genuinely good.
- **No plugin runtime or scripting engine.** Extension happens through the Swift seams and (P4) MCP. A second extension mechanism is a second security surface.
- **No cloud anything in the OSS core.** BYOK is the user bringing *their* endpoint. The hosted tier is a later, separate, opt-in layer that slots into three existing seams and removes nothing.
- **No per-user telemetry.** Metrics are local, inspectable, and never transmitted. P5's "weekly active installs" is opt-in and aggregate-only.
- **No dependency on a single model checkpoint.** Two ASR engines and two synthesizers ship from the start, precisely so a model going stale is a settings change and not a crisis.

---

## 16. Open questions

Flagged honestly rather than papered over. None blocks C1.

1. **Kokoro in Swift.** Whether we bind Kokoro through a C/C++ shim, an ONNX/CoreML conversion, or a bundled MLX path is unresolved. It's contained behind `SpeechSynthesizer` and doesn't block anything before C9 — and `SystemSynthesizer` means we can ship a talking Vocca regardless.
2. **Speculative-ASR correctness under revision.** Parakeet's streaming output can revise earlier tokens. The final-on-key-up result must be identical to a batch transcription of the same buffer, or the latency win is bought with accuracy. Needs measurement in C7, not assumption.
3. **AX allowlist bootstrap.** Whether the initial allowlist is hand-curated, community-contributed, or learned entirely from strategy memory. Leaning hand-curated for the top ~10 apps, then learned.
4. **Echo rejection on speakers** may need more than reference cancellation on some hardware. Budget real time for this in C10; it's the kind of problem that looks solved in a quiet room and isn't.
5. **Recovery-journal retention.** Bounded and purged — but the exact window is a genuine privacy-versus-recoverability tradeoff that deserves a deliberate decision, not a default.
