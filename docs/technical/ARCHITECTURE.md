# Vocca: Architecture

> **Status: authoritative.** Per `CLAUDE.md`, this document governs technical direction once it exists — it now does. Where this contradicts the "proposed" tech direction in `CLAUDE.md`, this wins. Where it contradicts `docs/ROADMAP.md` on *sequencing*, the roadmap wins.

This is the build document. `ROADMAP.md` says what we prove and when; `CAPABILITY_ROADMAP.md` says what gets built in what order; **this says what the things actually are** — the types, the interfaces, the threading rules, and the failure semantics that let fourteen capabilities built weeks apart line up.

---

## 1. The invariants the architecture exists to enforce

Every structural decision below traces to one of these. If a design choice doesn't serve one, it's a preference, not architecture.

| # | Invariant | How the architecture enforces it |
|---|-----------|----------------------------------|
| **I1** | **A transcript is never lost** | `TranscriptCustody` (§10) owns every transcript from ASR completion to confirmed delivery. Nothing can drop it, including a crash. |
| **I2** | **Zero network in the default config** | Network access is confined to two named types. A CI interposer asserts zero connections on the default path (§14). |
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
├── VoccaUI        SwiftUI  — widget, settings, onboarding    @MainActor
├── VoccaCore      Swift    — orchestration, session state    actors
├── VoccaAudio     Swift    — capture, playback, VAD           realtime + actor
├── VoccaASR       Swift    — ASREngine implementations        actor
├── VoccaText      Swift    — cleanup, dictionary              actor (pure-ish)
├── VoccaInject    Swift    — AX / Pasteboard / CGEvent        actor (never main)
├── VoccaSpeech    Swift    — SpeechSynthesizer implementations actor
└── VoccaBridge    C/C++    — whisper.cpp, Kokoro if needed    isolated
```

**Why single-process Swift** (locked in planning): direct access to `AXUIElement`, `CGEvent`, and `NSPasteboard` without a bridge; FluidAudio's CoreML/ANE models drop in natively; and nothing sits between key-up and text-on-screen except our own code. A Tauri/Rust shell would buy cross-platform we explicitly deferred and cost us the ANE path — the fastest ASR route available on this hardware.

**Swift 6 strict concurrency is on from commit one.** Retrofitting it onto an audio pipeline with a realtime thread, an actor graph, and main-thread UI is materially harder than starting with it.

Modules are **Swift Package Manager targets** in one repository. The dependency graph is strictly acyclic and points inward: `VoccaUI → VoccaCore → {VoccaAudio, VoccaASR, VoccaText, VoccaInject, VoccaSpeech}`. Leaf modules never import `VoccaCore` and never import each other. This is what makes each capability testable in isolation.

---

## 3. Directory layout

```
Sources/
  VoccaApp/                  # @main, app delegate, permission bootstrap
  VoccaUI/
    Widget/                  # the floating pill + its states
    Settings/
    Onboarding/
  VoccaCore/
    Session/                 # DictationSession, ConverseSession, SessionMode
    Custody/                 # TranscriptCustody — I1 lives here
    Pipeline/                # stage orchestration + latency spans
    Config/                  # Configuration, persistence, defaults
  VoccaAudio/
    Capture/                 # AudioCapture impls
    Playback/                # duckable output for barge-in
    VAD/                     # VoiceActivityDetector, TurnDetector
  VoccaASR/
    Parakeet/                # FluidAudio-backed
    Whisper/                 # whisper.cpp-backed
    Models/                  # ModelRegistry, download, verify
  VoccaText/
    Rules/                   # deterministic cleanup
    Dictionary/              # user replacement rules
    LLM/                     # Ollama, BYOK
  VoccaInject/
    Ladder/                  # the four-rung strategy
    Accessibility/           # AX wrappers, Secure Input detection
    Clipboard/               # save/set/paste/restore protocol
    Memory/                  # InjectionStrategyStore
  VoccaSpeech/
    Kokoro/
    System/                  # AVSpeechSynthesizer
  VoccaContext/              # P4 — ContextProvider
  VoccaActions/              # P4 — ActionProvider, MCP client
  VoccaBridge/               # C interop shims
Tests/
  <mirrors Sources>/
  Fixtures/                  # audio, transcripts, golden outputs
  Harness/                   # app matrix driver, fault injection, benchmarks
```

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
| Strategy memory | `InjectionStrategyStore` | `PersistentStore`, `EphemeralStore` (tests) | No |
| TTS | `SpeechSynthesizer` | `KokoroSynthesizer`, `SystemSynthesizer` | **Yes** |
| VAD | `VoiceActivityDetector` | `SileroVAD`, `EnergyVAD` (fallback/tests) | No |
| Turn detection | `TurnDetector` | `ParakeetEOU`, `SilenceThresholdDetector` | No |
| Context | `ContextProvider` | `AccessibilityContext`, `NullContext` | **No — by design** |
| Actions | `ActionProvider` | `MCPProvider`, `ShellProvider` | No |

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
   ├─ [~5 ms]   AudioCapture.begin() — engine already warm (C7)
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

Every stage emits a span into a **local-only** `LatencyRecorder`. Never transmitted, inspectable in settings, and the CI benchmark asserts against it so a regression names its own culprit.

---

## 7. Threading and concurrency

```
┌─ Realtime audio thread ─────────────────────────────────────┐
│  AVAudioEngine tap. No allocation, no locks, no logging,    │
│  no Swift runtime calls that can allocate. Writes into a    │
│  lock-free ring buffer and nothing else.                    │
└──────────────────────┬──────────────────────────────────────┘
                       │ drain
┌─ AudioActor ─────────▼──────────────────────────────────────┐
│  Owns the ring buffer, session lifecycle, watchdog.         │
└──────────────────────┬──────────────────────────────────────┘
                       │
┌─ SessionActor (VoccaCore) ──────────────────────────────────┐
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
3. **`SessionActor` is the only place session state lives.** The widget renders a projection of it. No component infers session state from its own local flags — that's how you get stuck-recording bugs that only reproduce on someone else's machine.

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

---

## 11. Cleanup pipeline

```
Transcript ──► [custody taken] ──► RulesCleanup ──► optional LLM ──► String
                     │                   │               │
                     │              always runs     opt-in only
                     │              (<10 ms)        budget-capped
                     │
                     └── on ANY failure or timeout at any stage:
                         the raw transcript proceeds to injection (I5)
```

The budget lives in `CleanupContext`, is enforced by the caller (`SessionActor`) with `Task` cancellation rather than trusted to the provider, and expiry is not an error the user sees — it's a silent degrade to raw text, counted in local metrics.

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

---

## 13. Models, storage, and permissions

**Storage layout** — nothing ships in the app bundle except code, so the download stays small:

```
~/Library/Application Support/Vocca/
  models/<engine-id>/<version>/     # downloaded, checksum-verified, resumable
  config.json                       # settings
  dictionary.json                   # user replacement rules — hand-editable
  strategies.json                   # per-app injection memory
  recovery/                         # transcript journal (bounded, purged)
  metrics.sqlite                    # local-only latency/success — never sent
```

**Permissions matrix.** Each is requested *at the moment it's first needed*, with copy explaining what we do and don't do — never in a first-run wall of dialogs:

| Permission | Needed for | Requested at | If denied |
|-----------|------------|--------------|-----------|
| Microphone | All capture | First dictation attempt | Hard block, with a direct link to the settings pane |
| Accessibility | AX injection + context | First dictation attempt | Degrade to clipboard rung — still fully usable |
| Input Monitoring | Global hotkey tap | First launch | Hard block — no hotkey, no product |
| Automation (per-app) | Some AX targets | Per app, on demand | That app drops to clipboard rung |

**Entitlements:** the app is **not sandboxed** (AX injection into arbitrary apps is incompatible with the sandbox), is Developer ID signed, hardened-runtime enabled, and notarized. Signing and notarization are wired up in **week 1** — the combination of non-sandboxed + Accessibility + Input Monitoring draws review scrutiny, and that is not a discovery to make at ship time.

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
