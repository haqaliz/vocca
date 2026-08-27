# Vocca: Project Context for Claude Code

This file orients a coding agent working in this repository. Read it first.

> **Status:** the **C1 skeleton, the C2 ASR half, the C3 second ASR engine, the C4 injection
> ladder, the P0 dictation loop, the C5 deterministic-cleanup unit and the C6 llm-cleanup
> unit** exist; the product
> does not. C1 (audio
> capture + global hotkey) merged 2026-08-12; C2 (local ASR) merged 2026-08-09; C3
> (second-asr-engine) landed 2026-08-11; C4 (the
> injection ladder and its failsafe surface) landed 2026-08-09; the
> **dictation-loop unit landed 2026-08-12** — the loop wired end to end, the live widget
> shipped, the zero-network probe driving a full cycle; the **rules-engine aspect landed
> 2026-08-15** — the deterministic cleanup, pure and CI-executed (below); the
> **pipeline-wiring aspect landed 2026-08-15** — the loop cleans by default, the cleanup
> span is recorded, and the probe drives the real rules provider (below); the
> **eval-harness aspect landed 2026-08-15** — the held-out scorer, the stand-in corpus, the
> provisional targets and the F2 step (below).
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
>   amended in that commit). `VoccaASR`, `VoccaInject` and `VoccaUI` have since shipped behind their
>   seams (recorded below); `VoccaAudio`, `VoccaText` and `VoccaSpeech` — `VoccaAudio` has since
>   shipped behind its seam and `VoccaText` has since become the cleanup adapter module —
>   deterministic rules in C5, the LLM providers in C6 (both recorded below); `VoccaSpeech` is the
>   one module still a placeholder, and
>   **the loop is wired** — `AppBootstrap.configure` composes tap → session machine → `MicrophoneSource`
>   → engine → ladder → failsafe → widget, driven end to end by the zero-network probe. The C1 acceptance (100 cycles, 100 started,
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
>   drag, and App Nap on an `LSUIElement` app. **`test-with-floor.sh` compiles that harness too**,
>   after the floor check — because `swift build` and `swift test` never see `Tools/`, and a check
>   that lived only in CI is what let a `RepeatingTimer` change break the harness with every local
>   signal green and master red on merge.
> - `Tests/HarnessTests/`: 836 tests — the **zero-network invariant** (a `dyld` interposer over
>   `connect(2)` driving a probe binary that now drives a full session through the real machine and
>   watchdog, two complete ladder runs through the real injector, and a full dictation cycle
>   through the composed root), module-boundary lint,
>   licence-header lint, package-manifest coverage guard, the
>   built-bundle/entitlement contracts, the session machine's own decision-table, mutation, and
>   invariant coverage, the hotkey flag translation with its `fn` rule, the `HotkeyEventSource` seam
>   with H6 pinned in **both** directions at the far end of it, the H7 seam lint — per-seam since
>   the injection-adapters amendment: the tap adapter is the one file permitted to speak CoreGraphics
>   in the tap seam, and the keystroke adapter (`VoccaInject/Keystroke/KeystrokeSource.swift`) is the
>   one in the keystroke seam, one file per seam, ever — the pasteboard, AX, Carbon and `FileManager`
>   families joined the same rule in the adapters and failsafe-surface amendments, one file each
>   (`SystemPasteboard`, `AXSource`, `SecureInputRead`, `FileSystemJournalStore`) —
>   the event-type classification and its mask, the tap callback's own body — lifted out of the
>   adapter so that it has somewhere to run, with H6 pinned in both directions at the last point
>   before the C ABI — the callback-safe split of a tap disablement, and the
>   tap-health policy — where the load-bearing test is that **every** entry point ends an in-flight session,
>   driven over a closed set of all eight, in both activation modes, because a session that outlives
>   its tap is a hot mic. The one exception is the ~1 s health poll, which asserts the *opposite* and
>   has to: it runs once a second for as long as Vocca runs. Phase 5 added the two timers' scheduling
>   decisions, the **H10 run-loop-mode mechanism measured in the suite** (a `.default`-mode timer
>   delivers none of its due fires through an event-tracking gesture; the shipped `.common` one
>   delivers all of them — the suite runs at 20 ms over 0.4 s; the 0-of-33 figures are
>   `Scripts/measure-timers.sh`'s, at 150 ms over 5 s, and CI does not run it),
>   and `OwnershipGraphTests` — which pins the four sole-owner edges a review had measured as
>   held by no test at all. Phase 6 added the Secure Input decision over an injected read — the state
>   itself cannot be entered by a test, since `IsSecureEventInputEnabled` is set by other people's
>   software — including that a blocked poll ends a session that started *after* the block began,
>   which is the fifth instance in this aspect of a guard justified by a claim about what cannot be
>   in flight. The final review closed two more: the Secure Input reinterpretation now runs on **all
>   five** entry points that can answer `delivering` — a machine woken with Terminal's *Secure
>   Keyboard Entry* ticked, a grant notification over a password field, and a recovered timeout all
>   reported *ready* while deaf, which is the sixth instance of that same shape — and
>   `DeinitIsolationTests` pins the rule that **a `deinit` must not reach an isolation
>   precondition**: two `deinit`s routed into `MainRunLoopTimer.stop()`, whose
>   `MainActor.preconditionIsolated` is not compiled out at `-O`, so releasing the tap source off the
>   main actor was a release-build crash. The rule is now a lint over `Sources/`, because
>   `audio-capture` will need it a fourth time.
> - `.github/workflows/ci.yml`: three jobs — headless suite under strict concurrency (any warning
>   fails), plus a bundle contract per configuration (Debug and Release). Every `swift test` runs
>   through `Scripts/test-with-floor.sh`, because `swift test` exits 0 when it discovers nothing —
>   and that script is now the whole of the headless job's check, the measurement harness's compile
>   included, so nothing CI checks is unreachable from a developer's machine.
>
> **C2 (`local-asr`) merged 2026-08-09 — the ASR half of the dictation loop.** The
> `ASREngine` seam now exists as code in `VoccaCore` (`transcribe`, batch-default `stream`,
> `prepare`; attribution non-optional, the empty-buffer policy, `AudioBuffer.missingSampleCount`
> as the I1 completeness link's carrier), with **Parakeet TDT 0.6B v3 via FluidAudio** as the
> first implementation — the repository's first external dependency (`from: "0.12.4"`,
> Apache-2.0). The model lifecycle is real: `ModelStore` (actor, single-flight, atomic
> verified-marker commit, SDK-shaped `sdkDirectory` layout, recursive presence),
> `ModelDownloader` (resume/verify/retry over an injected transport), `DefaultModelTransport`
> as **the one file permitted to name `URLSession`** (H8 lint — the first of `ARCHITECTURE.md`'s
> two named network types), and `ModelHub.offlineMode = true` at engine construction so the
> SDK's own download path is structurally dead. The F1 spike is recorded (`docs/planning/local-asr/parakeet-engine/spike_20260809.md`):
> **RTF 0.0122 on M4 Max (word-perfect), warm load 0.111 s, 470 MB artifact, 79 MiB peak RSS**,
> and the layout finding that shaped the store (`load(from: D)` resolves to
> `<D.parent>/<repo.folderName>/`). The fixture suite is real: `WER` scorer (table-tested),
> parameterized harness proven with stubs, six fixtures + goldens (TTS stand-ins pending the
> founder's recordings), a provisioning script, the real SHA-256 manifest, and an
> **env-gated real-engine WER run that passed on the first real run** (15.4 s, all provisional
> tolerances met). The minimal download window ships in `VoccaUI` over a Core-owned
> `ModelDownloadSession` seam with a tested state reducer.
>
> **What C2 is NOT, and must not be claimed:**
> - **The Parakeet adapter is executed by nothing in CI** (the tap-adapter precedent): the
>   CoreML model cannot reach a hosted runner. Every decision is above the seam and tested;
>   the real-engine numbers come from `ParakeetEngineWERTests` with `VOCCA_MODEL_DIR` set
>   (it skips visibly otherwise), per `SMOKE_CHECKLIST.md` step 18.
> - **The F1 runner verdict is pending**: whether the real-model suite can run in CI on a
>   macos-15 runner is unanswered (`asr-spike.yml`, `workflow_dispatch`); the two wiring paths
>   are recorded in `docs/planning/local-asr/fixture-suite/ci-wiring-decision_20260809.md`.
> - **The C1→C2 completeness bridge is gated** on the `audio-capture` merge: the captured
>   buffer's `refusedSampleCount` → `AudioBuffer.missingSampleCount` conversion is the last
>   unshipped link; the contract is already carried end to end.
> - **The provisional WER tolerances are provisional** (TTS stand-ins are unnaturally clean);
>   the founder's real recordings (F2) set the numbers, in exactly one place.
>
> **C3 (`second-asr-engine`) landed 2026-08-11 — the whisper.cpp half of the ASR story, behind the
> same seam.** The `ASREngine` seam now has a second implementation, `WhisperCppEngine` in
> `VoccaASR/Whisper/` — a whisper.cpp-backed actor over the **`WhisperCpp` binary target** (the
> repository's first binary dependency: the official v1.9.2 XCFramework, fetched by SPM at resolve
> time, never at runtime), with `WhisperCAPI.swift` the bridge — the one file permitted to name the
> `whisper_` / `WHISPER_` / `import whisper` family, seam-pinned two-sided by `WhisperSeamTests`
> (the H7/H8b precedent; `VoccaBridge` stays reserved for a second C-ABI consumer, per the
> `ARCHITECTURE.md` §2 amendment). The engine is an actor with its own parameters, load state and
> segment mapping, and every transcript carries `WhisperCppEngineIdentity` — attribution is
> non-optional, exactly as Parakeet's is. The model lifecycle is reused, not duplicated: two GGUF
> manifests (turbo and q5_0 tiers) with verified digests ship in `VoccaASR/Models/Manifests/`, and
> a suite test round-trips a manifest through the existing `ModelStore` over a stub transport. The
> real-engine WER run was extracted into a shared parameterized runner: `WhisperCppEngineWERTests`
> is env-gated by `VOCCA_MODEL_DIR` exactly like Parakeet's (it skips visibly otherwise), and the
> runtime swap is pinned — a session resolves its engine once, at start, and only the identity
> differs at the boundary. The Speech-tab picker ships in `VoccaUI`: `EnginePickerStateReducer`
> (the never-auto-switch rule) and `EnginePickerCopy` tested headless, with `EnginePickerView`
> thin glue over them.
>
> **What C3 is NOT, and must not be claimed:**
> - **The whisper real-engine WER run has not happened.** `WhisperCppEngineWERTests` skips without
>   `VOCCA_MODEL_DIR`; the founder runs it on hardware with the provisioned artifacts, per
>   `SMOKE_CHECKLIST.md` step 19. The provisional tolerances are **seeded from Parakeet's table,
>   not measured** on whisper's output — `tolerances_20260810.md` is the one place the mechanism is
>   explained, and nothing passes or fails a release gate on the numbers until they are
>   re-baselined from a real run.
> - **The picker panel is executed by nothing in CI** (the window-server precedent): the reducer
>   and the copy are the tested half; `SMOKE_CHECKLIST.md` step 20 is the panel's first execution.
> - **The weights-license record is DRAFT** pending the founder's sign-off
>   (`docs/planning/second-asr-engine/model-lifecycle/license_20260810.md`): whisper.cpp and ggml
>   are MIT-verified from primary sources, but the converted GGUF weights' own provenance is the
>   founder's open item, and `THIRD_PARTY_NOTICES.md`'s weights entry stays marked pending until
>   the record is signed.
> - **The F1 runner verdict is still pending for both engines** — whether the real-model suite can
>   run on a macos-15 hosted runner is unanswered, and C3's entry in
>   `docs/planning/local-asr/fixture-suite/ci-wiring-decision_20260809.md` records the same
>   env-gated decision for whisper rather than re-deciding it.
> - **The loop exists, but its real-machine execution does not** — nothing connects session → ASR →
>   injection in a way CI can run (no Accessibility, no TCC, no microphone on a hosted runner);
>   `SMOKE_CHECKLIST.md` steps 62–68 are the loop's first execution, and the picker's engine
>   switch is exercised against a live session there.
>
> **C4 (`injection-ladder`) landed 2026-08-09 — the injection half of the dictation loop.** The
> `TextInjector` seam exists as code in `VoccaCore` (`inject`, `resolve`, `failsafe` over
> `TargetContext`, the rung and result vocabulary, and `HeldTranscript` carried through the
> single-slot `TranscriptHolder` seam — held, and durable before `hold` returns), with **the ladder
> decision and `LadderInjector` in `VoccaInject/Ladder/`**: the allowlist gate over the seeded
> three-app list, the per-app rung order (accessibility → clipboard-paste → keystroke), the
> never-clobber clipboard restore, and the read-back-verified AX rung — every decision over
> injected seams. The adapters are translation with no decisions in them, each the one file in its
> H7 seam: `KeystrokeSource` (the keystroke seam's one CGEvent file), `SystemPasteboard` (save/set/
> paste/restore, invisible to a clipboard manager), `AXSource` (allowlist-gated, read-back-verified),
> and `SystemSecureInputRead` (one Carbon line, read fresh at resolution time — the injection half
> of the Secure Input story). The recovery journal (`VoccaInject/Journal/`) makes the failsafe's
> durability real: a `hold` does not return until the transcript is on disk
> (`~/Library/Application Support/Vocca/recovery/`, atomic temp+rename), bounded, purged on resolve,
> with `FileSystemJournalStore` the one file permitted to name `FileManager`. The FAILSAFE window
> ships in `VoccaUI` — a non-activating `NSPanel` that never takes focus, ⌘C / ⏎ / ✕ key
> equivalents over an injected copy seam, cause-specific reason copy, and a tested state reducer
> whose decision table runs headless, including the never-auto-dismiss rule: no time-based
> transition exists in it at all. The zero-network probe now drives the ladder too — two complete
> runs through the real injector, replacing the `VoccaInject` placeholder — and the suite floor is
> 623 tests.
>
> **The `dictation-loop` unit landed 2026-08-12 — the P0 loop, wired.** `VoccaCore` holds the
> decisions the loop is made of: `DictationPipeline` (a cancelled session never injects — Esc
> during TRANSCRIBING cancels the in-flight transcription — an empty short press skips the
> injector entirely, and every other `.ended` transcribes and injects, surfacing
> `.transcriptHeld` or a reason-only notice), `DictationEngineResolver` (resolve-once at launch,
> single-flight background `prepare()` with the existing download surface, and a readiness gate
> that refuses a dictation with `.modelUnavailable` before the microphone ever opens), and the
> `WidgetProjection`/`LiveLevelSource` seams the widget renders through. The composition root
> (`AppBootstrap.configure`) composes the real adapters: `CGEventTapSource` → `ScheduledWatchdog`
> → `SessionMachine` over `MicrophoneSource`/`AudioCaptureGraph`, the engine per selection
> (`ShippingLadder`, `ShippingPasteboard`, `ShippedModelManifest` are the new public composition
> factories), `LadderInjector` with the seeded allowlist and `JournalTranscriptHolder` as both
> handoff and panel holder, `TargetResolution` (made public for the root, translation only),
> `FailsafePanel`, and the live widget. `SessionKeyPolicy` routes **Escape** into the machine's
> `cancel()` during OPENING/RECORDING and cancels an in-flight transcription — `PRODUCT_SPEC.md:129`
> is now code, not a promise. The live widget ships its five P0 states (IDLE/OPENING/RECORDING/
> TRANSCRIBING/DELIVERED) as a projection of the machine's effects over a headless reducer with
> injected-clock timers (2 s esc hint, 3 s elapsed, 110 s ceiling warning derived from the
> configured ceiling, 600 ms DELIVERED collapse), a waveform driven by a **real** input level
> published from the capture graph's realtime callback (`MicrophoneLevelSource`, the 
> `@realtime`-marked accounting), and Reduce Motion → static meter; `WidgetPanel` overrides
> `canBecomeKey = false` so the "never takes focus" claim is real. `FailsafeReason` gained
> `.modelUnavailable` and `.transcriptionFailed` with a reason-only, dismiss-only panel variant.
> The zero-network probe now drives a **full dictation cycle** through the composed root
> (`PROBE-CYCLE`: press → mic opens over a scripted graph → frames → transcribe → inject →
> idle, zero `connect(2)`, no download started), which is how it caught and fixed a real defect —
> `ShippedModelManifest` could never load in an SPM build. Test floor: 836.
>
> **What the dictation loop is NOT, and must not be claimed:**
> - **Its first execution is the founder's machine.** No part of the loop runs in CI — no tap, no
>   TCC, no microphone, no window server; `SMOKE_CHECKLIST.md` steps 62–68 (with the model
>   downloaded first) are the loop's only real run, exactly as steps 22–35 were the adapters'.
> - **CONVERSING and the settings surface are out of scope** (P3, C11); the toggle machine is
>   wired and tested but has no visible control yet; sounds are deferred to a settings surface.
> - **C5 and C6 shipped in full except their settings surface** (C5: the rules engine, the
>   dictionary store, the pipeline wiring and the eval harness; C6: the Ollama and BYOK rungs,
>   opted into by a hand-edited `cleanup-config.json` — both recorded below). **The Cleanup-tab
>   settings UI and C8 (strategy memory) remain unbuilt.** The ladder does not learn.
>
> **The `latency-instrumentation` unit landed 2026-08-14 — C7's first slice: the loop's
> numbers, measured and gated.** `VoccaCore` now owns the local-only vocabulary the loop
> records through: `LatencySpan` (captureClose/asr/cleanup/inject — cleanup's span has been
> recorded since C5's pipeline-wiring slice landed; the `notPresent` state survives for a
> nil-cleanup pipeline), the five `SessionOutcomeClass` cases
> (delivered-by-rung / failsafeHeld / aborted / failed / emptySkip — never force-labeled, so
> the P0 first-method-success metric is derived, not stored), `SessionRecord` with engine
> attribution, the `LatencyRecorder` seam, and the bounded in-memory `LatencyLedger` actor
> (cap 512, loud refusal of duplicates and double-finalize, pure `describe()`). The loop
> records end to end: the router begins a record at `.opening`, `DictationPipeline` finalizes
> on every row of its own decision table (ASR span measured around `transcribe` with the
> injected clock, inject span from `InjectionResult.elapsed`), the capture-close span is
> measured on the `stop()` caller's side — never on the realtime thread — and the
> zero-network probe's cycle now prints the record (`PROBE-LATENCY`) with the interposer
> proving zero `connect(2)`. Whisper's owned clock now records the shared `EngineTiming`
> kinds exactly like Parakeet's. The benchmark half ships as two honest halves: a headless
> fixture-replay harness + regression gate in CI (a seeded slow injector must fail it — a
> gate that cannot fail proves nothing) and an env-gated real-engine run
> (`VOCCA_LATENCY_BENCH` + `VOCCA_MODEL_DIR`, visible skip otherwise) that prints per-span
> p50/p95 with the process's suppression state beside every row; `SMOKE_CHECKLIST.md` steps
> 69–70 are its first execution. Test floor: 876.
>
> **What the latency-instrumentation unit is NOT, and must not be claimed:**
> - **The numbers are unmeasured.** The env-gated real run has not happened; the provisional
>   tolerances (p50 ≤ 400 ms / p95 ≤ 800 ms, `ROADMAP.md:171`) are targets in one named
>   table, recorded not gated, until the founder's first run re-baselines them.
> - **Warm start and widget-only streaming partials remain unbuilt** (the rest of C7), and
>   speculative-ASR correctness under revision is still `ARCHITECTURE.md` open question 2.
>   *(Amended by the `warm-start-streaming` unit, landed 2026-08-25: the warm-start launch
>   preload is pinned and gated, and the widget-only streaming *mechanism* shipped — the real
>   streaming adapters and the speculative feed remain deferred, recorded below.)*
> - **The ledger is in-memory**: no persistence, no UI surface, nothing ever transmitted.
>
> **The `rules-engine` aspect landed 2026-08-15 — C5's first slice: the deterministic cleanup,
> pure.** The seam shipped first (`CleanupProvider`/`CleanupContext`/`ReplacementRule` in
> `VoccaCore`); `VoccaText/Rules/RulesCleanup.swift` now implements the pure function
> `ARCHITECTURE.md:511` names — `(String, [ReplacementRule]) -> String`, six fixed stages:
> frequency-tuned filler removal (`like` is verb/preposition-protected, `so` sentence-initial
> only), spoken-punctuation commands resolved to their symbols (plus N2 literal tokens, the
> `period.` word+symbol shape converging on the symbol), segmentation + terminal punctuation
> (boundaries only at signals — no ML-style splitting), capitalization, bounded number/unit
> normalization (explicit tables, no `Locale`), then the user dictionary in declared order
> (first match wins, replacement never re-scanned). The token-protection class is one
> mechanism: nothing is rewritten inside `/ . - _ @` tokens, an internal `.` is never a
> boundary, `@`-tokens are never first-char-capitalized. Stdlib-only and byte-deterministic,
> the B1–B12 acceptance tables run the shipped function headlessly in CI — the rare aspect
> with no TCC/Accessibility/microphone dependency — including a ~2,400-word perf smoke under a
> named 250 ms bound (the honest <10 ms numbers are the eval-harness aspect's). The module
> move landed with it: VoccaText is an adapter module (the boundary suite's reviewed rule-1
> relaxation, `ModuleBoundaryTests`). Test floor: 894.
>
> **What the rules-engine aspect is NOT, and must not be claimed:**
> - **It shipped unwired, and the wiring is a separate aspect.** The engine itself ships no
>   `CleanupProvider` conformance — `ShippingCleanup` is pipeline-wiring's M6, landed
>   2026-08-15 (below), and the raw-vs-clean text story changed there, not here.
> - **The dictionary is applied, not stored**: persistence and the full `caseSensitive`/
>   `wordBoundary` semantics are the `user-dictionary` aspect's; the <10 ms product numbers
>   are the eval-harness aspect's.
>
> **The `pipeline-wiring` aspect landed 2026-08-15 — C5's second slice: the loop cleans by
> default.** `DictationPipeline` gains the optional `cleanup:` stage between transcribe and
> inject — `nil` is today's behavior, byte for byte (the B2 test) — with the caller-enforced
> budget race over the injected clock (`withThrowingTaskGroup`: the provider and a
> deadline-watcher child polling `clock.now` via `Task.yield()`, never a wall-clock timer),
> the never-empty fallback (an empty/whitespace clean result routes the raw text), and the
> post-cleanup cancellation re-check (Esc during cleanup finalizes `.aborted` and injects
> nothing — `PRODUCT_SPEC.md:129`). The cleanup span is recorded on **every** answer — the
> timed-out and throwing paths included — so a silently degrading cleanup is visible in the
> ledger, never silent forever. `ShippingCleanup.make()` (VoccaText) is wired as the default
> cleanup stage in the composition root: `requiresNetwork == false` (declared, not defaulted),
> the `"rules-cleanup"` identity, lazy dictionary load with the empty fallback. The
> zero-network probe drives the **real** rules provider through the cycle
> (`cleanup.engine=rules-cleanup`, zero `connect(2)` unchanged), the `VoccaTextPlaceholder`
> witness is gone, and the cycle's `PROBE-LATENCY` renders the recorded cleanup span. Test
> floor: 925.
>
> **The `eval-harness` aspect landed 2026-08-15 — the C5 unit's last slice: the number the P1
> gate is judged on, measured not claimed.** `CleanupPairwiseScorer` is the deterministic blind
> pairwise-preference comparator (the judge answers `left|right|tie|noPreference` over A/B
> sides and never sees labels — blindness is mechanical, in the mapping; `tie`/`noPreference`
> are excluded from the denominator by design), with the oracle judge for CI and the seeded
> presentation order for the founder's ballot. The corpus is the checked-in stand-in set —
> `Tests/CleanupPairs/`, 24 pairs = 4×6 classes, generated by
> `Scripts/provision-cleanup-fixtures.sh` from goldens with deterministic ASR-ish injection
> (`FIXTURES.md` is the matrix, never assumed), including the planted
> `numbers-units-planted-raw-preferred` pair whose `raw == clean` — the can-lose proof, and the
> recovery guarantee is a committed test (every non-planted pair is recovered by the shipped
> rules; 23/24 preferred, the planted pair the one loss). The headless run scores the corpus in
> CI; the latency gate asserts the p50 under the 10 ms budget and a seeded-slow rule genuinely
> fails it (a gate that cannot fail proves nothing); the `0.80` preference figure and the 10 ms
> budget live in exactly one file — `ProvisionalCleanupTargets` — pinned by a single-source
> scan, and the env-gated real run (`VOCCA_CLEANUP_EVAL`, wav sidecars transcribed by the real
> Parakeet engine with attribution asserted) **records, never gates**. `SMOKE_CHECKLIST.md`
> step 73 is the F2 recording task — the founder's real held-out set that re-baselines the
> provisional targets. Test floor: 958.
>
> **What the eval harness is NOT, and must not be claimed:**
> - **CI produces mechanism numbers only.** The stand-in preference percentage (23/24) is a
>   harness-sanity number; the ≥ 80% / 10 ms figures are **provisional** until the founder's F2
>   run re-baselines them, in exactly one file (`ProvisionalCleanupTargets`), via the measure →
>   margin → founder-signed procedure (`tolerances_20260815.md`).
> - **The env-gated real run has not run.** It skips visibly in CI; step 73 is its first
>   execution, and F2 is still ownerless beyond that step (the same open item the ASR tolerances
>   already await).
>
> **The `llm-cleanup` unit landed 2026-08-19 — C6, the Ollama and BYOK rungs of the cleanup
> ladder, behind the same seam.** All eight aspects shipped (in order: `provider-budget`,
> `llm-transport`, `ollama-provider`, `byok-provider`, `cleanup-chain`, `cleanup-config`,
> `egress-badge`, `root-wiring`; each planned in `docs/planning/llm-cleanup/<aspect>/`). The
> cleanup seam now has **three real implementations** (rules, Ollama, BYOK — the roadmap's
> "two real implementations, not one implementation and a promise"): `OllamaCleanupProvider`
> (`VoccaText/LLM/`) posts `/api/generate` at the configured endpoint/model, `BYOKCleanupProvider`
> speaks OpenAI-compatible chat completions with `Authorization: Bearer <key>` and maps 401/403
> to a first-class `unauthorized` (never retried, the key-hygiene sweep pins the sentinel out of
> every error), and **`DefaultLLMTransport` is the second named network type** —
> `ARCHITECTURE.md:16`'s BYOK client, the second file permitted to name `URLSession` (H8 lint,
> reviewed amendment). The degrade is structural, not post-hoc: `ChainedCleanupProvider`
> (`cleanup-chain`) runs rules first, rewrites the rules output, and on any LLM throw or
> empty answer returns the rules output — rethrowing only `CancellationError` when the task is
> cancelled, so a cancelled session never injects a stale result. The opt-in mechanism is a
> hand-edited `cleanup-config.json` in Application Support (`CleanupProviderKind` + tolerant
> decode, absent/invalid ⇒ rules with a loud log), read once by the `CleanupResolver` actor
> (resolve-once, single-flight, the `DictationEngineResolver` shape), with the rules dictionary
> store derived from the same directory — and `CleanupConfigStore` is the third `FileManager`
> seam row. The egress badge (`egress-badge`) is reducer state, not view state: `WidgetEgressState`
> (`.none`/`.active(endpoint:)`), the closed `WidgetAction` set gains `egressChanged`, the
> never-auto-dismiss rule holds (no action but the wiring's launch fold touches it), and
> `BadgeCopy` pins `PRODUCT_SPEC.md:250-264` byte-for-byte (the ☁︎ U+2601 U+FE0F glyph, the
> "Cleanup runs on <endpoint>. Your text is sent there." hover). The composition root
> (`AppBootstrap.configure`) builds the resolver (real `DefaultLLMTransport` +
> `SystemKeychainKeyProvider`), resolves in `pipelineAssembly`, and folds the badge from the
> resolved provider's `requiresNetwork` + endpoint in a launch task; the zero-network probe
> wires the resolver with fakes over an absent config and its cycle report now carries
> `egress=none` — zero `connect(2)` unchanged, `cleanup.engine=rules-cleanup` unchanged.
> `SMOKE_CHECKLIST.md` steps 74–76 are the LLM rungs' first execution (Ollama live and stopped,
> the BYOK real run with the key in the Keychain, and the badge both directions). S2
> (ledger cleanup attribution) and N1 (configurable LLM budget) were deliberately skipped as
> the plan's "only if cheap" gates; `ARCHITECTURE.md` §11 now says "provider-declared" and §13
> names `cleanup-config.json` + the Keychain item. Test floor: 1052.
>
> **What the llm-cleanup unit is NOT, and must not be claimed:**
> - **No real LLM cleanup runs in CI.** The providers are executed over stub transports; the
>   Keychain adapter (`SystemKeychainKeyProvider`) is translation-only, executed by nothing (the
>   tap-adapter precedent); `SMOKE_CHECKLIST.md` steps 74–76 are the real runs' only execution.
> - **LLM rewrite quality is unmeasured, and this unit must not imply otherwise.** There is no
>   harness for LLM-over-rules output and no claim "LLM > rules"; the founder's real Ollama run
>   is a smoke observation, not a gate number (`prd.md` "quality not implied").
> - **The 5 s LLM budget is unmeasured** — a declared ceiling, cancelable by Esc, tuned from the
>   founder's real run, not a measured number.
> - **S2 and N1 were skipped** as the plan's "only if cheap" gates: the ledger cannot yet say
>   *which* cleanup ran, and the LLM budget is not user-configurable.
>
> **The `warm-start-streaming` unit landed 2026-08-25 — the C7 remainder, built as the
> mechanism the seam was waiting for.** `VoccaCore` owns the two new pieces of vocabulary:
> `WarmStartTargets.maxFirstAfterLaunchMultiple` (the 1.2 bound, `ROADMAP.md:174`'s "within
> 20% of steady-state", in exactly one place and pinned by a single-source scan) and the pure
> `WarmStartRatio` evaluator (`.withinBound`/`.exceedsBound`/`.insufficientSamples` — an empty
> side is never fabricated into a ratio, the `notPresent` precedent; the steady-state
> representative is the median, the p50 discipline). The launch preload was already wired
> (`startEnginePreparation` → `prepareIfNeeded` once, never on the session path) — it is now
> pinned by test rather than asserted by comment, including that `configure` itself never
> prepares (`WarmStartLaunchTests`). The benchmark gate gained a warm-start verdict *row*, not
> a span: the closed four-span session record is unchanged, the ratio is cross-session in
> `EngineTiming` samples, and a seeded-slow stub whose first transcription is 2× steady-state
> genuinely fails the gate (a gate that cannot fail proves nothing). The env-gated real run
> (`VOCCA_LATENCY_BENCH` + `VOCCA_MODEL_DIR`) prints the ratio with the suppression state
> beside it and **records, never gates** (`tolerances_20260825.md`). The streaming half ships
> as the mechanism, honestly scoped: `PartialTranscriptSink` (a new Core seam, stdlib-only,
> widget-only by construction), `DictationPipeline.routeStreaming(chunks:target:sessionID:)`
> consuming `engine.stream(_:)` **unconditionally** — the seam's batch default is the
> degradation, and no caller branches on `supportsStreaming` anywhere (the no-branch pin is a
> test) — with the **permanent guard** pinned across the closed route set: zero `TextInjector`
> calls before the final, cancellation at every boundary finalizes `.aborted` and injects
> nothing, and a pipeline built without a sink is byte-for-byte today's pipeline. The widget
> gained bounded provisional text (`partialText`, a new closed-set `WidgetAction.partial`,
> truncated at a named cap, cleared on every state adoption, never surviving into DELIVERED,
> Reduce Motion → the view stays static). The probe gained a `streaming-cycle` mode driving
> the route through the composed root with a stub engine under the interposer — zero
> `connect(2)`, partials folded into the store — and the default configuration's
> `PROBE-CYCLE`/`PROBE-LATENCY` strings are unchanged. Test floor: 1087.
>
> **What the warm-start-streaming unit is NOT, and must not be claimed:**
> - **No real engine streams.** Both engines still report `supportsStreaming == false`; the
>   widget's partial text is unobservable with a real model until the streaming adapters land.
>   `ARCHITECTURE.md:630` open question 2 (speculative final-vs-batch equivalence) is
>   untouched — no latency number is claimed from this mechanism, and the recorded p50/p95
>   budget is still post-key-up only.
> - **The real warm-start ratio is unmeasured.** CI proves the mechanism (the gate can fail);
>   the founder's env-gated run (`SMOKE_CHECKLIST.md` steps 77) produces the first measured
>   number and re-baselines the 1.2 bound via the record's measure → margin → founder-signed
>   procedure, in exactly one file (`WarmStartRatio.swift`).
> - **The speculative pre-key-up feed, the real streaming adapters, and re-warm-after-idle
>   remain deferred** (the live capture→chunk source, the `supportsStreaming == true`
>   implementations, and the idle policy the resolver's sticky-`isPrepared` has no counterpart
>   for).
>
> **What C4 is NOT, and must not be claimed:**
> - **The adapters and the window are executed by nothing in CI** (the tap-adapter precedent): no
>   Accessibility or Automation grant, no real pasteboard session, no window server on a hosted
>   runner. Every decision is above the seam and tested; `SMOKE_CHECKLIST.md` steps 22–35 are the
>   adapters' and the panel's only execution.
> - **The loop is wired** (the `dictation-loop` unit above); CONVERSING and the settings surface
>   are out of scope (only the FAILSAFE and the five live states ship); C8 (strategy
>   memory) remains unbuilt; C5 and C6 shipped in full except their settings surface — the
>   rules dictionary and the cleanup-provider choice are JSON-editable, the Cleanup tab waits
>   for the deferred settings surface; C7's
>   latency-instrumentation slice shipped
>   (below), its warm-start and widget-streaming halves did not — the `warm-start-streaming`
>   unit shipped the warm-start pin and gate plus the widget-streaming mechanism (above); the
>   real streaming adapters and the speculative feed remain deferred.
>
> **The `fix/local-dev-launch` branch landed 2026-08-25 — three defects that made a locally
> built Vocca unusable, none of them reachable by CI, two of them silent on the machine as
> well.** They are worth recording together because they share one cause: the app is
> `LSUIElement`, so **a failed launch and a successful one look exactly the same** — no window,
> no Dock icon, no crash dialog. The symptom was "I clicked the app and nothing opened", which
> is also what working looks like. (1) The Parakeet manifest declared `config.json` as 2 bytes
> with the SHA-256 of the literal string `{}` — a placeholder, never a measurement — so
> verification failed with `checksumMismatch(file: "config.json")`, the `verified` marker was
> never committed, and **the default engine could not be provisioned on any machine** from
> `ac381d0` until now; exactly one entry was wrong, the other twelve small files re-verified
> clean. (2) The hardened runtime's Library Validation requires embedded frameworks to share the
> app's Team ID, and the self-signed dev identity has none — so since C3 embedded
> `whisper.framework`, `dyld` refused to map it and **every self-signed build died before
> `main()`**; `Scripts/sign.sh --local-dev` now injects
> `com.apple.security.cs.disable-library-validation` into a *temporary* copy of the
> entitlements, exactly as Debug already injects `get-task-allow`, so `App/Vocca.entitlements`
> is untouched and `BundleConfigurationTests` still asserts it absent from the checked-in set.
> (3) `configure` read `setActivationPolicy(.accessory)`'s `false` as failure when it merely
> means "made no change" — `LSUIElement` having already set the policy — so every launch logged
> a focus-stealing failure that had not happened, while printing the correct policy in its own
> message; the resulting policy is what is checked now. Test floor unchanged at 1087: no test
> changed, and none of the three was catchable by one.
>
> **What that branch does NOT prove, and must not be claimed:**
> - **Dictation still has not run.** The app launches, the tap delivers, the engine prepares —
>   audio → transcript → injection remains unexercised, exactly as `SMOKE_CHECKLIST.md`
>   steps 62–68 say.
> - **The manifest digests are pinned to what the repository serves today**, the corrected entry
>   included. The **whisper manifests were generated the same way and have still never been
>   downloaded** — the same defect may be sitting in them.
> - **`--local-dev` bundles are not release bundles.** They carry an entitlement the shipped
>   bundle must not, so a smoke run using the flag is inspecting a different entitlement set,
>   and such a bundle must never reach `Scripts/notarize.sh`. A Developer ID identity removes
>   the need for the flag entirely.
>
> **The design pass landed 2026-08-26/27 — Vocca stopped being invisible.** Three merges
> (`fix/waveform-*`, `feat/design-tokens-menubar`, `feat/settings-window`) built the first
> surfaces the app has ever had beyond the pill, chosen from eleven prototypes generated against
> the surface briefs. The prototypes split cleanly and the picks follow that split: the stronger
> set understood the *product* — it documented Secure Input recovery, the 600 ms collapse, and
> shape-only state encoding — and the other understood the *person*, writing "Your words are safe
> here — copy them in." Structure from one, voice from the other.
>
> **`VoccaTheme`** is the token layer, and it names **system colours rather than the designs' hex
> pairs**. Those pairs are correct and are exactly what `NSColor` already resolves to, so naming
> the system colour keeps them from drifting when Apple retunes them, and picks up Increase
> Contrast and the user's chosen accent — neither of which a literal can follow. The designs
> hardcoded because they were authored on the web, where that machinery does not exist.
>
> **The menu bar item** (`MenuBarState`, `MenuBarCopy`, `MenuBarItem`) is the surface that ends
> the class of failure this whole stretch was made of. Vocca is `LSUIElement`, so a Vocca running
> perfectly and a Vocca that died at launch looked identical — and *every* bug found in these two
> days was silent for exactly that reason. Seven states, each reachable from something the loop
> already reports; **precedence is a pure reducer** (activity outranks housekeeping; among
> blockers, no-Accessibility outranks all because it makes the rest moot, and Secure Input comes
> last because it needs no action and ends on its own). Shape carries state and colour carries
> nothing, which is the platform's rule as much as the design's — a template image has one colour
> to draw with — so the accessibility requirement is satisfied by construction. `NSStatusBar` is a
> window-server object, so the item is built in `main()`, never `configure`: the `LiveWidget`
> rule, applied again.
>
> **The settings window** (`SettingsTab`, `SettingsView`, `SettingsWindow`) retires the first of
> the hand-edited JSON files. General switches activation mode — which had swapped defaults the
> day before with **no way to change it at all** — and Dictionary reads and writes the same store
> the rules engine loads from, so an edit applies to the next dictation. It is **the one window
> allowed to take focus**, which costs an activation-policy switch: an `LSUIElement` process
> cannot make a window key, so `show()` becomes `.regular` and `windowWillClose` returns to
> `.accessory`. Failing to return would leave Vocca able to steal the field it exists to type
> into.
>
> **What the design pass did NOT build, and must not be claimed:**
> - **Speech and Cleanup are read-only tabs.** They report what Vocca is using and say where the
>   choice still lives; the cleanup provider is still `cleanup-config.json`. The hotkey is
>   displayed rather than rebindable. Each says so in words, because a control that looks editable
>   and is not teaches a user the app is broken.
> - **First run and permissions do not exist.** The highest-value surface in the design direction
>   is still unbuilt, and a fresh install still meets the same three silent gates.
> - **No colour, type or spacing was copied from a prototype's canned rendering.** Both prototypes'
>   waveforms are hardcoded arrays with no level input — the bar geometry was taken and nothing
>   else, because a canned waveform is the one thing `PRODUCT_SPEC.md:88` forbids outright.
> - **"Pause Vocca" and recent-transcript history were deliberately not built**, though both
>   prototypes drew them. Vocca has no pause, and the recovery journal is purged on resolve — so a
>   history is a privacy decision, not a layout one. Building either from a mockup would be
>   shipping a feature nobody decided on.
> - **None of it has been seen in motion.** The pill renders only during a dictation, and
>   dictation has still never been observed delivering text end to end.
>
> > **The `short-press-toggle` change landed 2026-08-25 — the first real dictation's two findings.**
> Pressing the hotkey produced *"Voice processing failed. Nothing was lost — you can try again."*
> The cause was not the model: FluidAudio's transcribe guard throws `ASRError.invalidAudioData`
> below **0.3 s** (4 800 samples at 16 kHz), `ParakeetEngine` mapped that to
> `.transcriptionFailed`, and the pipeline surfaced it — so **a quick tap of ⌥Space showed a
> failure notice**, while a press capturing *exactly zero* samples skipped cleanly. The seam had
> already promised otherwise in as many words: `ASREngine`'s contract says "a 20 ms press captures
> almost nothing, and silence is a transcript, not an error", and a 20 ms press is **320 samples,
> not zero** — its own worked example was the failing case. The engine now answers empty below the
> SDK's minimum, read live from `ASRConstants` rather than copied, with the decision lifted into
> `ParakeetEngine.isBelowSDKMinimum` so a test can reach it (the adapter itself is executed by
> nothing in CI). `WhisperCppEngine` deliberately gained **no** guard: whisper.cpp is understood to
> pad rather than refuse, which is reasoning about the C library and not a measurement, and a
> guessed threshold would answer empty for audio whisper would have transcribed. Second, **toggle
> became the shipped default** (`DictationLoopRoot.defaultMode`) — the founder's call, since
> holding a key for a whole utterance is what produces accidentally-short presses. Both machines
> are still constructed and owned; only the tap's route changed, and `activeMode` now derives from
> the same constant as the routing sink's initial target, because they are two assignments in one
> initializer and a root reporting a mode its events do not reach is a hotkey driving the wrong
> machine. Test floor: 1088.
>
> **What that change does NOT prove, and must not be claimed:**
> - **The dictation loop still has not delivered text end to end.** The failure notice proves the
>   tap, the microphone, the session machine and the pipeline all ran; it proves nothing about
>   injection. `SMOKE_CHECKLIST.md` steps 62–68 remain unexecuted.
> - **The 0.3 s boundary is FluidAudio's, measured on this machine** (4 799 samples threw, 4 800
>   transcribed) — not a Vocca constant, and not verified for whisper, whose first real run is
>   still step 19.
> - **Toggle's cost is now paid by default**: it has no finger-as-ground-truth, so a forgotten
>   session runs to the 120 s ceiling. That was an opt-in cost when hold-to-talk was the default.
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
>   asserting it is a `Bool` asserts nothing. `docs/SMOKE_CHECKLIST.md` steps 55–57 are its only
>   confirmation.
> - **`SystemPhysicalKeyState` — `CGEventSourceKeyState` and `CGEventSourceFlagsState` — is executed
>   by nothing**, for the same reason the tap adapter is not: it lives in `CGEventTapSource.swift`
>   because those identifiers match the H7 seam prefix and one file per seam may name them — the tap
>   seam's one file holds its physical-key reads, exactly as the keystroke seam's one file holds its
>   synthesis. What the answers *mean* is above the seam, in `SessionWatchdog`, and is tested there.
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
