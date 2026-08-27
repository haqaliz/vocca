# Spec — memory-order

Aspect of `injection-strategy-memory` (C8, P2) · `docs/planning/injection-strategy-memory/prd.md`
Requirements: **R2, R3, R4, R5, R6, R8** (owned here); **X1** (bounded here), **X3** (closed here).
Depends on: `core-memory` (`InjectionStrategy` + the pure decision functions + the
`InjectionStrategyStore` protocol, `Sources/VoccaCore/StrategyMemory/`), `store-seam` (the store
implementations), the shipped C4 ladder (`InjectionStrategyOrder`, `InjectionAllowlist`,
`LadderInjector`, `InjectionLadderDecision.decide`, `ShippingLadder`).

## Problem slice

C4's ladder does not learn. `DefaultInjectionStrategyOrder` (`InjectionStrategyOrder.swift:51-65`)
recomputes the same two answers on every dictation from the allowlist alone, so Slack and Google
Docs pay the AX discovery cost on every single press — and every other app is stuck on clipboard
forever (`SeededInjectionAllowlist.swift:30` promises those apps reach AX "only through C8's
learned memory"). The repository's own seams already promise the fix: `InjectionStrategyOrder`'s
doc comment names the memory as a *second implementation of this protocol*
(`InjectionStrategyOrder.swift:19-22`), `LadderInjector`'s does the same (`LadderInjector.swift:58-59`),
and `InjectionLadderDecision.decide` was built so it needs **zero changes**: a rung absent from the
strategy map counts as failed (`InjectionLadderDecision.swift:110-116`), the exhausted trace is
the demotion input (`:142-151`), and `InjectionResult.attempted` carries that trace intact
(`InjectionResult.swift:36`, `InjectionRung.swift:24-25`).

This aspect is the half that makes those promises code: the memory-backed order + allowlist
conformance (the read side), the recording hook in `LadderInjector.inject` (the write side), the
seeded hostile defaults (R5), and the composition-root wiring that hands the memory to both the
order *and* the AX rung so the two can never disagree (R6 — the load-bearing design).

## In scope

1. **`MemoryBackedInjectionStrategyOrder`** (`Sources/VoccaInject/Ladder/`, new file) — a type
   conforming to **both** `InjectionStrategyOrder` and `InjectionAllowlist`, per PRD R6. It holds
   the in-memory loaded strategy snapshot (loaded once, off the session path — the custody chain,
   PRD T-2), the seeded allowlist, the seeded hostile set, the injected store for recording, and
   an injected `now` supplier (integer epoch seconds, Core's timestamp rule — the re-probe is
   lazy, evaluated on the next `orderedRungs(for:)`, no timers, PRD R4). `orderedRungs(for:)`
   projects through Core's pure decision; `contains(bundleID:)` answers the same Core eligibility
   decision so the two gates can never disagree (R6). `@MainActor` final class — the
   `LadderInjector` isolation precedent: the ladder crosses no actor boundaries on the latency
   path, and the isolation satisfies the protocols' `Sendable` requirements
   (`LadderInjector.swift:32-37`).
2. **The recording seam + the `LadderInjector.inject` hook** (R8) — an injected
   `InjectionStrategyRecording` seam; `LadderInjector` gains an optional
   `recorder: (any InjectionStrategyRecording)? = nil` parameter (nil ⇒ byte-for-byte today's
   injector, the `warm-start-streaming` "built without a sink" precedent). `inject`
   (`LadderInjector.swift:74-89`) calls it on both the delivered and the catch-residual paths with
   `target.bundleID`, the order's answer, and the full result — the one place all three are visible
   together (PRD R8). The *persist* is fire-and-forget: a detached task the injector never awaits
   (PRD T-2 — the ≤100 ms ladder budget is measured around the synchronous inject).
3. **Seeded hostile defaults** (R5) — a data file, the `SeededInjectionAllowlist` shape:
   `Sources/VoccaInject/Allowlist/SeededHostileApps.swift`, two bundle identifiers (Google Docs,
   Slack) whose `.accessibility` is demoted from the first dictation. Data, not decisions: the
   fold into the strategy is Core's pure merge, applied once at load
   (`InjectionStrategy` factory, consumed from `core-memory`), and a learned entry always beats
   the seed — so a verified AX promotion of Docs later is honored, never re-demoted at launch.
4. **`ShippingLadder` wiring** (R6) — a second factory `makeWithMemory(memory:handoff:clock:)`;
   the existing `make` stays byte-for-byte (the zero-network probe's cycle drive composes its own
   ladder, but `ShippingLadder` is the shipped public surface — untouched callers must not move).
   The factory hands the **same instance** to the order slot, the
   `AccessibilityRungStrategy` allowlist slot (`ShippingLadder.swift:60-68`), and the injector's
   recorder slot — one source of truth in three roles, so a memory that promoted an app can never
   be contradicted by the rung's own gate (`AccessibilityRungStrategy.swift:98-100`).
5. **`AppBootstrap` custody-chain wiring** (`AppBootstrap.swift:124-143`) — the persistent store
   is constructed and the strategy loaded **before** `LadderInjector`, inside the existing
   `custodyTask` (the `RecoveryJournal` load-on-launch precedent, PRD T-2); the assembled
   memory-backed ladder replaces the `ShippingLadder.make` call at `:138-139`. The absent-file
   path is silent (the `CleanupConfigStore` precedent): no file ⇒ empty strategy ⇒ the projection
   is `DefaultInjectionStrategyOrder`'s behavior byte-for-byte, so `configure` under the probe
   stays green with zero `connect(2)`.
6. **The zero-network probe** — the probe's cycle drive (`DictationCycleDrive.swift:379-389`)
   composes its ladder over the memory-backed order with a temp-directory store holding no file;
   the report gains one strategy field (e.g. `strategy=absent`); `ZeroNetworkTests` extends
   `expectedCycleLifecycle` through the **guard-the-guard** tests, never by pasting probe output.
7. **The R2–R6/R8 acceptance tests** (PRD's "learned-tried-first, demote, rediscover, seeded
   hostile, learned promotion"), headless in `Tests/HarnessTests/` — the test names in the
   acceptance section below.

## Out of scope

- **The store file format, persistence, and the `EphemeralStore`/`PersistentStore`
  implementations (R9)** — `store-seam`'s. This aspect consumes `InjectionStrategyStore`; it adds
  no `FileManager`-naming file and no seam-row amendment (the `"strategy"` row and the
  three→four exact-set pin are `store-seam`'s).
- **`InjectionStrategy` itself and the pure decision functions** (demote-on-fail, re-probe
  eligibility, ordered-rungs projection, the load-time hostile merge) — `core-memory`'s, stdlib
  only. This aspect's tests drive them *through* the memory-backed adapter.
- **The Apps tab, per-app override, reset-learned (R7/S2)** — `apps-tab`. Nothing here builds UI
  or a second write path into the store.
- **The expanded matrix and its smoke rows (R10)** — `matrix-smoke`. No new smoke rows land here;
  the seeded hostile data only *keeps* smoke steps 23–24's clipboard expectation true.
- **N1 (ledger attribution), adaptive settle, C12 context, egress** — the PRD's exclusions.

## Isolation / honesty decisions

- **One instance, three roles.** The memory is handed to the order, the AX rung's allowlist, and
  the injector's recorder as the *same object* (`ShippingLadder.makeWithMemory`). The two gates
  (order projection, rung gate) and the write side (recorder) can then never disagree about what
  is learned — the PRD's "one source of truth" (`ShippingLadder.swift:47-50`).
- **`contains(bundleID:)` must include window-elapsed candidates, or promotion is structurally
  dead.** The naive reading — `contains` = seed ∪ learned-promoted only — deadlocks R6: a
  candidate's AX probe runs *through* `AccessibilityRungStrategy.tryInject`, whose own gate
  (`AccessibilityRungStrategy.swift:98-100`) declines anything `contains` rejects, so the probe
  would never happen. The resolution: `contains` and the projection both answer Core's one
  eligibility decision — seed-allowlisted, learned-promoted, **or a clipboard-success candidate
  whose re-probe window has elapsed**. Same decision, two questions, zero disagreement. The
  window-elapsed candidate is *not* yet trusted: its probe failing re-demotes it with a fresh
  window (X1 bounded — promotion is one-shot, re-probe-verified).
- **`widgetFailsafe` never appears in a strategy** (the protocol contract,
  `InjectionStrategyOrder.swift:26-33`) and **`.clipboardPaste` can never be demoted** (R2 — the
  workhorse, `ROADMAP.md:47`); therefore the projection is **never empty** (X3 closed: demote
  removes a failed rung from the attempt list; clipboard is exempt, so at minimum
  `[.clipboardPaste, .keystrokeSynthesis]` survives). "Start at the winning rung" (R2) is the
  demoted list's head — with the shipped two-rung ladder (AX, clipboard; keystroke absent from
  the strategy map, `ShippingLadder.swift:30-36`) the winner is always first unless the winner is
  the never-demoted workhorse, which the exempt-clause makes correct by design.
- **The read is a pure in-memory lookup; the write is two-phase.** `orderedRungs(for:)` is
  synchronous and touches no I/O (X4). Recording applies the mutation to the in-memory snapshot
  *synchronously* (value math, microseconds) so the next dictation sees it, then spawns a
  detached task for the persist — the injector awaits the seam's return, never the disk (T-2).
  A crash between apply and persist loses only the latest mutation: bounded, re-learned.
- **Absent file ⇒ silent empty ⇒ byte-for-byte C4 ordering.** The default configuration's probe
  drive runs the memory-backed ladder over a temp directory with no file; zero `connect(2)`
  unchanged (G4). The store's load is `CleanupConfigStore`'s shape: absent ⇒ silent, corrupt ⇒
  loud + never rewritten (R9's policy, enforced by `store-seam`).
- **The seeded hostile fold is load-time, launch-minted.** The hostile demotion's re-probe clock
  starts at load (the fold is a pure merge into the snapshot; the projection stays pure — no
  read-path mutation). A learned entry for the same app always wins the merge, so the seed is the
  *initial condition*, never a permanent veto ("an app update that fixes AX support is eventually
  rediscovered", R4).
- **Out-of-order persists are prevented, off the latency path.** Rapid dictations spawn racing
  detached writes; the recorder chains them (each detached task awaits the previous persist's
  task handle *inside* the detached context) so a stale snapshot never overwrites a newer one —
  with the chain's awaits strictly outside the injector's own await.

## Acceptance criteria (tests written first, in `Tests/HarnessTests/`)

`MemoryBackedInjectionStrategyOrderTests.swift` (the order + allowlist + projection):

- **T1 · `testLearnedStrategyIsTriedFirst`** (R2) — a pre-seeded strategy with AX demoted for app
  X answers `orderedRungs(for: X)` starting at the working rung; the same app with no entry
  answers the C4 ordering.
- **T2 · `testDemoteOnFailThroughDecideOverTheMemoryOrder`** (R3) — the *real* `LadderInjector`
  over the memory order with fake rung strategies (the fault-injection pattern): first rung
  fails, second succeeds; the resulting `InjectionResult.attempted` feeds the recorder; the next
  `orderedRungs(for:)` excludes the failed rung.
- **T3 · `testReprobeRediscoveryAfterWindowWithInjectedClock`** (R4) — demoted; `now` before the
  window ⇒ excluded; advance the injected clock past the 604 800 s window ⇒ re-included exactly
  once; verified success ⇒ restored. Companion `testReprobeFailureReDemotesWithFreshWindow`:
  failure ⇒ still demoted with a fresh window.
- **T4 · `testSeededHostileExcludesAXOnFirstDictation`** (R5) — Google Docs' and Slack's bundle
  IDs with an empty learned store answer `[.clipboardPaste, .keystrokeSynthesis]` on the very
  first call.
- **T5 · `testLearnedPromotionReachesAXAndItsGate`** (R6 — the load-bearing flow) — app not in
  the seed: clipboard success recorded ⇒ candidate; window elapses (injected clock) ⇒
  `orderedRungs` includes AX **and** `contains(bundleID:)` is true (the gate's question); the AX
  rung's own gate over the same instance passes; verified AX success recorded ⇒ permanent
  promotion: `contains` true and AX first thereafter.
- **T6 · `testPromotionProbeFailureReDemotesTheCandidate`** (X1) — a candidate whose probe
  attempt fails is not promoted; re-demoted with a fresh window.
- **T7 · `testWidgetFailsafeNeverAppearsInAnyProjection`** — the closed projection space (nil
  bundleID, unknown, seeded, hostile, demoted, candidate, promoted × window before/after) never
  contains `.widgetFailsafe` (protocol contract, `InjectionStrategyOrder.swift:26-33`).
- **T8 · `testClipboardPasteIsNeverDemoted`** + **`testProjectionNeverEmpty`** (R2/X3) — the
  exempt clause and the never-empty guarantee across the closed space; a strategy with every
  other rung demoted still projects at least `[.clipboardPaste]`.
- **T9 · `testLearnedEntryOverridesTheHostileSeed`** — a promoted Google Docs answers with AX
  despite the seed — the merge's learned-wins clause.
- **T10 · `testAbsentFileIsSilentAndDefaultsToTheC4Ordering`** — an empty snapshot is byte-for-byte
  `DefaultInjectionStrategyOrder` for seeded, unknown and nil bundle IDs.

`InjectionStrategyRecordingTests.swift` (R8, over the real recorder + a fake store):

- **T11 · `testRungZeroRefusalsWriteNothing`** — secure-input and no-focused-field results (and
  `bundleID == nil`) leave the store untouched — `SMOKE_CHECKLIST.md` step 27's "no rung was
  attempted".
- **T12 · `testDeliveredAndFailsafeResultsRecordIntoTheStore`** — delivered-by-clipboard records
  the candidate marker; exhausted-failsafe records the demotion from the intact `attempted`
  trace (`InjectionLadderDecision.swift:142-151` — the trace must survive the round trip).
- **T13 · `testInjectorNeverAwaitsThePersist`** (T-2) — a store whose `record` blocks on a gate:
  `inject` returns while the persist is still pending; releasing the gate completes it; the
  snapshot lands. Companion `testCatchResidualStillCallsTheRecorder`: the handoff-refusal
  residual routes through the seam too (PRD R8's "both success and the catch residual").
- **T14 · `testRecordingMutationIsVisibleToTheNextProjectionWithoutThePersist`** — the
  in-memory apply, not the disk write, is what the next `orderedRungs` reads.
- **T15 · `testRapidRecordsPersistInOrder`** — the chained-persist funnel: two records in quick
  succession land in order on the store.

`ShippingLadderMemoryWiringTests.swift` + `AppBootstrap` wiring tests:

- **T16 · `testOrderAndRungShareTheSameAllowlistInstance`** (R6 — the identity pin) —
  `makeWithMemory` hands the order slot, the `AccessibilityRungStrategy` allowlist slot and the
  recorder slot the same instance.
- **T17 · `testConfigureAssemblesMemoryBeforeTheInjector`** — the extracted custody-chain
  assembly builds store → loaded strategy → memory → ladder in order over a temp-directory store.
- **T18 · `testProbeMemoryDefaultAbsentFileSilentZeroNetwork`** — the probe's cycle drive over
  the memory-backed order and an absent-file store: zero `connect(2)`, the report's
  `strategy=absent` field, `rung=clipboardPaste`/`attempted=clipboardPaste` unchanged; the
  `expectedCycleLifecycle` extension lands through the guard-the-guard test
  (`testTheAssertedCyclePostConditionStillDescribesACompleteDictationCycle`), never by pasting
  probe output.

Boundary discipline (with every phase): the full suite green under the floor, Swift 6 clean,
zero warnings, Apache headers, no new module, no `Package.swift` edit.

## Dependencies / sequencing

- **`core-memory` first** — this aspect consumes, and its tests drive: `InjectionStrategy`
  (per-app state: demoted entries with timestamps, promotion candidates, promoted entries),
  the pure decisions `orderedRungs(for:strategy:seedBundleIDs:now:)`,
  `mutation(from:result:bundleID:now:) -> Mutation?` (nil for rung-0 refusals), the re-probe
  window constant **604 800 s (PROVISIONAL, in exactly one place in Core, pinned by a
  single-source scan** — the `WarmStartTargets` precedent), and the load-time hostile merge
  `seeded(hostileBundleIDs:now:)`. The exact signatures are the interface contract below.
- **`store-seam` second** — `InjectionStrategyStore` (`load() async -> InjectionStrategy`,
  `record(_ strategy: InjectionStrategy) async` — whole-snapshot, atomic, tolerant) and the
  `EphemeralStore` for headless tests. The FileManager seam-row amendment is theirs.
- **Interface contract this aspect declares** (for the sibling plans): the projection consumes
  the seed **as data** (`Set<String>`), never the `VoccaInject` protocol — Core is stdlib-only
  (`CoreBoundaryTests`). The recorder's store call is whole-snapshot. The strategy's persisted
  rung spellings are `InjectionRung`'s raw values (`InjectionRung.swift:24-25`).
- **This aspect lands after both**; the probe and `AppBootstrap` changes are its last phases.
  Precedents: `LadderInjector`'s isolation and optional-injected-seam pattern
  (`warm-start-streaming`'s `PartialTranscriptSink`), `CleanupConfigStore`'s absent-file
  silence, the fault-injection suite's hand-built `InjectionResult`s
  (`InjectionResult.swift:43-50`), the `RecoveryJournal` load-on-launch custody chain.

## Open questions / risks

- **Exact Core signatures.** The shared vocabulary fixes `InjectionStrategy` and
  `InjectionStrategyStore`; the pure-function shapes above are this aspect's declared need —
  confirm against `core-memory`'s spec when it lands. Low risk: the adapter's whole job is
  delegation, so a renamed parameter is a one-line change.
- **`contains()` includes window-elapsed candidates** — resolved *here* (see the honesty
  decisions); `core-memory` must model the candidate state in `InjectionStrategy` or the
  promotion deadlock returns. This is the aspect's one design finding beyond the PRD's words.
- **Hostile-seed clock start.** Launch-time mint (the fold's `now`) means a seeded app's first
  AX probe can come 7 days after *install* rather than 7 days after *first use* — a lazy mint
  would need a read-path mutation, which the pure-projection rule forbids. Launch-time is the
  lean; flag if the founder prefers otherwise.
- **Bundle identifiers are unverified data.** `com.google.docs` and `com.tinyspeck.slackmacgap`
  must be confirmed from the installed apps' `Info.plist` against `CFBundleIdentifier` — the
  `SeededInjectionAllowlist` plutil convention — before merge; the pinned test catches a typo in
  review but not a wrong identifier.
- **Probe field spelling** (`strategy=absent` vs another token) — pinned by the guard-the-guard
  test at implementation time; the report's field list
  (`DictationCycleDrive.swift:516-538`) is the one place the grammar joins.
- **Whole-snapshot `record`** assumes `store-seam`'s API carries the full snapshot; if the store
  takes deltas instead, the recorder's chained-persist funnel stays, only the payload changes.