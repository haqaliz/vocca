# Spec — pipeline-wiring

Aspect of `deterministic-cleanup` (C5) · `docs/planning/deterministic-cleanup/prd.md` (requirements
M4-M8 + S4).
Depends on `cleanup-seam` + `rules-engine` + `user-dictionary` (all three landed: `CleanupProvider`/
`CleanupContext`/`ReplacementRule` in VoccaCore, `RulesCleanup` + the dictionary in VoccaText, and
VoccaText's `VoccaCore` dependency in `Package.swift:90-94`).
No Swift code exists for this aspect; this spec is the failing tests written first
(`CAPABILITY_ROADMAP.md:13`).

## Problem slice

Cleanup is a seam and an engine and a dictionary, but **not part of the loop**: the pipeline injects
`transcript.text` verbatim (`DictationPipeline.swift:240`), the latency record carries cleanup only
as an absent span (`ZeroNetworkTests.swift:561-567` asserts `latency.contains("cleanup")` is
*false*), the probe's VoccaText witness is a placeholder type (`VoccaNetworkProbe.swift:276`), and
the smoke checklist says "cleanup is never recorded, C5 unbuilt" (`SMOKE_CHECKLIST.md:1191`). This
aspect makes cleanup live: an optional stage inside `transcribeAndInject` that can only degrade, can
never lose or block text (I5, `ARCHITECTURE.md:19`), is budgeted by the caller (`ARCHITECTURE.md:509`),
and is counted in the ledger so a silently failing cleanup is never silent forever.

## In scope

1. **M4 — Pipeline wiring with the timeout policy.** An optional `cleanup: (any CleanupProvider)? =
   nil` parameter on `DictationPipeline.init` (`DictationPipeline.swift:119-131`), same nil-default
   convention as `recorder`/`clock` — `nil` is today's behavior, byte for byte (the existing
   `testADefaultPipelineWithNoRecorderOrClockRoutesExactlyAsBefore`,
   `DictationPipelineTests.swift:671`, must still pass untouched). Inserted between the empty-text
   guard (`DictationPipeline.swift:235-238`) and `injector.inject` (`:240`):
   - clean runs with the injected clock; on a non-empty result the **cleaned string** is what
     reaches the injector (`:240`) — and therefore what the failsafe's `HeldTranscript` holds and
     the widget surfaces (`:240-253` shape unchanged: held text is cleaned text, P0's
     no-transcript-lost invariant applies to the cleaned result).
   - **Never-empty:** a clean result that is empty/whitespace-only falls back to the raw text —
     the guard at `:235-238` ran before cleanup, so this is cleanup's own guard; cleanup never
     injects `""`.
   - **Budget, caller-enforced:** the pipeline races the `clean` await against the injected clock
     (a `withThrowingTaskGroup` shape); at `start + budget` the provider's task is cancelled and
     raw proceeds. The provider is passed `CleanupContext.budget` as information only — never
     trusted to self-limit (`ARCHITECTURE.md:509`: enforced by the caller, never the provider).
   - **Degrade:** any throw, `CancellationError` or budget expiry → raw proceeds silently (I5,
     `ARCHITECTURE.md:19`) — no new FAILSAFE surface, no reason-only notice; the raw text routes
     exactly as it does today.
   - **Esc re-check:** after the clean await, the post-transcribe cancellation guard shape
     (`:228-231`) runs again — a cancellation that landed during cleanup finalizes `.aborted`
     and injects nothing (`PRODUCT_SPEC.md:129`; the router cancels the route task via
     `AppBootstrap.cancelTranscription`, `AppBootstrap.swift:1036-1041`).
2. **M5 — Cleanup span recorded.** Mirror `recordASRSpan` (`DictationPipeline.swift:267-272`):
   `LatencySpan.recorded(name: .cleanup, elapsed: clock.now - start)` recorded on **every** answer,
   the timed-out and throwing paths included (the ASR-span precedent `:201-203`: a degrade's
   elapsed is real latency). No new vocabulary — `SpanName.cleanup` exists (`LatencySpan.swift:27-29`),
   `LatencyLedger.describe` already renders recorded spans (`LatencyLedger.swift:109-136`), so no
   report code changes. `cleanupNotPresent()` (`LatencySpan.swift:69-71`) stays for the nil-cleanup
   pipeline's untouched records.
3. **M6 — Default-on composition.** A `ShippingCleanup` factory in VoccaText (the `ShippingLadder`
   (`ShippingLadder.swift:43-71`)/`ShippingPasteboard` (`ShippingPasteboard.swift:28-37`) precedent)
   returning the rules provider with `requiresNetwork == false` and a non-optional `identity`;
   wired as the default `cleanup:` argument in `AppBootstrap.configure`'s `pipelineAssembly`
   (`AppBootstrap.swift:293-301`); `VoccaBootstrap` gains `"VoccaText"` in `Package.swift:118-129`.
4. **M7 — Zero-network probe coverage.** `VoccaTextPlaceholder.self` leaves the module-witness list
   (`VoccaNetworkProbe.swift:271-281`); `CycleDrive` gains a `cleanupModuleWitness` in the
   `audioModuleWitness`/`asrModuleWitness` pattern (`DictationCycleDrive.swift:259-264`), minted by
   `buildDictationCycle()` as `type(of: <the provider>)` at the return (`:522-523` shape); the
   drive's pipeline construction (`:388-390`) gains the wired provider — the real `ShippingCleanup`
   rules provider, which is pure and CI-runnable; the cycle report (`:496-517`) gains a cleanup
   fact; the `"1 2 3"` input passes through rules unchanged (`ProbeEngine.swift:43,108`); the
   interposer keeps asserting zero `connect(2)` through the whole cycle.
5. **M8 — Floor raise.** `Scripts/test-with-floor.sh:908` raised from 836 to the new executed total
   (the floor check at `:933`). **Review finding carried from this unit's PRD (`prd.md:120-123`):**
   the floor currently lags the suite — 836 pinned while 876 execute (latency-instrumentation
   shipped 40 tests without raising it). This aspect closes the gap for itself; the discrepancy
   stays recorded here so it is not repeated.
6. **S4 — SMOKE_CHECKLIST edits.** Verbatim assertions gain a cleaned-vs-raw qualifier: step 62's
   "lands verbatim" (`SMOKE_CHECKLIST.md:1011`), the matrix rows' "the field holds the transcript
   verbatim" (`:356`), and step 68's zero-loss wording "landed in the field verbatim or is held
   and copyable in the failsafe" (`:1153-1159`). Benchmark step 69's "`cleanup` is never recorded,
   C5 unbuilt" (`:1191`) flips to the recorded-span expectation (the closed span set becomes
   captureClose/asr/cleanup/inject). New steps in the 62-68 pattern: the dictionary (edit
   `dictionary.json`, dictate a rule's source, expect its target in the field) and a cleanup-failure
   degrade (text still lands raw; the ledger's record shows the cleanup span).

## Out of scope

- The rules engine internals (`rules-engine` aspect, M2/N2) and the dictionary store
  (`user-dictionary` aspect, M3/S1/S2) — this aspect consumes both, changes neither.
- The eval harness (S3) and the F2 task it owns.
- C6: Ollama/BYOK providers, the egress badge, per-mode provider selection (`prd.md:211-215`).
- Any `SpanName`/`Presence` vocabulary change, any `SessionOutcomeClass` change — the degrade
  count lives in the ledger only.
- Cleanup for CONVERSING mode.

## Isolation / honesty decisions

- **Budget enforcement is the caller's job; the provider is never trusted.** A lying or hung
  provider cannot block past the injected-clock race — the pipeline cancels its task and proceeds
  to raw; the post-cleanup `Task.isCancelled` re-check turns a late return (or a return that beat
  the race but arrived after Esc) into a discard. The provider's own `budget` field is advisory.
- **Degrade is silent to the user but counted in the ledger** (`ARCHITECTURE.md:509`, "counted in
  local metrics"): no new surface on timeout/failure — but the cleanup span is recorded on every
  answer, so a silently degrading cleanup is visible in `describe()` (`LatencyLedger.swift:109-136`),
  never silent forever.
- **Zero network stays asserted with cleanup wired.** The rules provider is local by construction;
  the probe's interposer asserts zero `connect(2)` through a cycle whose pipeline runs a real
  cleanup provider — `requiresNetwork == false` is the hook the invariant keys on.
- **CI cannot run the real loop; the probe's scripted graph is the CI-runnable surface.** No tap,
  no TCC, no microphone on a hosted runner — but the rules engine is pure stdlib, so unlike the
  engines the probe drives the **real** shipped rules provider, and the coverage guard
  (`ZeroNetworkTests.swift:1032-1059`; `candidateExclusions` at `:303-309` admits only the probe
  itself and the dyld shim — VoccaText is not excludable) then means a real VoccaText type must be
  minted by a drive call, the `:259-264`/`:522-523` witness shape.
- **The witness cannot be the placeholder.** `VoccaTextPlaceholder` (`Sources/VoccaText/Placeholder.swift:15`)
  satisfies the guard but proves nothing; the acceptance requires a type produced *by* the drive's
  calls, the `DictationCycleDrive.swift:259-264` documentation precedent.

## Acceptance criteria (tests written first)

- B1 **Clean routes through** (`DictationPipelineTests.swift`): with a cleanup provider wired, the
  raw transcript reaches `clean` and the provider's output — not the raw text — is what
  `LedgerTextInjector` records (the ledger-injector convention, `DictationPipelineTests.swift:63-75`).
- B2 **Nil = today** (`DictationPipelineTests.swift`): `cleanup: nil` calls no provider, injects the
  raw text, and the record carries no cleanup span; `testADefaultPipelineWithNoRecorderOrClockRoutesExactlyAsBefore`
  (`:671`) passes unmodified.
- B3 **Hung provider → raw within budget** (`DictationPipelineTests.swift`): a provider that never
  completes, against a short injected-clock budget (`TestClock`, `SessionTestDoubles.swift:34-36`),
  terminates with the raw text reaching the injector — the caller's cancellation fired on the
  injected clock, not on the provider's cooperation.
- B4 **Provider throwing → raw** (`DictationPipelineTests.swift`): a scripted throwing provider;
  raw reaches the injector, the surface is the rung's own (`.idle` for a delivery), and the cleanup
  span is still recorded (elapsed measured on the throwing path).
- B5 **Empty clean result → raw** (`DictationPipelineTests.swift`): the provider returns `""` and
  `"   "`; in both rows the raw text reaches the injector (never-empty).
- B6 **Esc during cleanup → nothing injected** (`DictationPipelineTests.swift`): cancel the task
  driving `route` mid-clean (the pipeline tests' cancellation convention); assert `.idle`, injector
  untouched, record finalized `.aborted` — the post-cleanup re-check.
- B7 **Failsafe holds cleaned text** (`DictationPipelineTests.swift`): `.widgetFailsafe` result;
  the surfaced `HeldTranscript`'s text is the cleaned text, and the holder was read exactly once.
- B8 **Cleanup span recorded** (`ZeroNetworkTests.swift` flip + `DictationPipelineTests.swift`):
  with recorder+clock+cleanup wired, the finalized record's spans include `cleanup` with an elapsed
  equal to the injected clock's delta; `ZeroNetworkTests.swift:561-567` flips from
  `XCTAssertFalse(latency.contains("cleanup"))` to asserting the recorded span, and the
  `PROBE-LATENCY` payload renders it through `describe()` with no new code.
- B9 **Probe coverage** (`ZeroNetworkTests.swift` + `DictationCycleDrive.swift`): the
  `:271-281` witness list no longer names `VoccaTextPlaceholder.self`; `CycleDrive` carries the
  cleanup witness minted by the drive (`:259-264`, `:522-523`); the cycle report (`:496-517`) gains
  the cleanup fact; the interposer still asserts zero `connect(2)`; `transcript=1-2-3` and
  `injected=1-2-3` are unchanged through the rules provider (`ProbeEngine.swift:43,108`). The
  `expectedCycleLifecycle` constant (`:249-293`) and its guard-the-guard test
  (`:830-935`) gain the new field **together** — a field added to one and not the other fails.
- B10 **ShippingCleanup contract** (HarnessTests): the factory returns a provider with
  `requiresNetwork == false` and a non-optional `identity`; `"1 2 3"` through it is the input
  unchanged (identity on the probe's canonical input).
- B11 **Floor raised** (`Scripts/test-with-floor.sh`): `:908` pins the new executed total; the
  full suite under the script stays green at or above it.
- B12 **Checklist** (`docs/SMOKE_CHECKLIST.md`): the verbatim qualifiers (`:356`, `:1011`,
  `:1153-1159`), the step 69 flip (`:1191`), and the new dictionary + degrade steps are present,
  numbered in the existing sequence.

## Dependencies / sequencing

- Depends on: `cleanup-seam` (M1 — `CleanupProvider`/`CleanupContext` in VoccaCore), `rules-engine`
  (M2 — `RulesCleanup`), `user-dictionary` (M3 — `ReplacementRule` semantics + `dictionary.json`;
  VoccaText's `VoccaCore` dependency lands there, `Package.swift:90-94`). The probe coverage guard
  (`ZeroNetworkTests.swift:1032-1059`, union of `Sources/` directories) means this aspect cannot
  pass while VoccaText is a placeholder-only module — the real witness is forced, not optional.
- Entry point `Scripts/test-with-floor.sh`; suite must stay green after every task commit.

## Open questions / risks

- **N1 — cleanup attribution on the record** (`prd.md:146-148`): whether the held transcript or
  `SessionRecord` names which provider cleaned. As designed it does not fall out of M5 cheaply —
  `LatencySpan` carries no provider — so it stays open for C6's per-mode selection rather than
  re-touching the closed record vocabulary here.
- **Degrade count: ledger only, by decision.** `ARCHITECTURE.md:509` says "counted in local
  metrics", which the ledger is; a new `SessionOutcomeClass` would re-touch every consumer of the
  closed set for a number nobody sees. Flagged so the alternative is a decision, not an accident.
- **Dictionary load in the root:** no prepare step. `ShippingCleanup` loads lazily with an
  empty-dictionary fallback — a missing/corrupt `dictionary.json` is an empty rule set (local,
  zero network, never fatal; the loud-log discipline is the dictionary aspect's).
- **The floor-lag finding:** `test-with-floor.sh:908` pins 836 while the suite runs 876; this
  aspect raises the floor to its own executed total and records the latency-instrumentation gap
  (40 tests shipped unfloored) as the review finding `prd.md:120-123` names.
- **Budget race shape:** the caller-enforced budget is an injected-clock `withThrowingTaskGroup`
  race in the pipeline, deliberately *not* a wall-clock timer — the injected clock keeps the
  pipeline's "time enters only through `MonotonicClock`" contract (`LatencySpan.swift:36-38`).
  The 10 ms budget itself (`ARCHITECTURE.md:310`) is recorded, not gated, here: the rules-path
  measurement is the eval-harness aspect's.
