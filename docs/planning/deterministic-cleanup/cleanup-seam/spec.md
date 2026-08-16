# Spec — cleanup-seam

Aspect of `deterministic-cleanup` (C5 first slice) · `docs/planning/deterministic-cleanup/prd.md`
Depends on nothing else in the unit. Ships the Core-owned seam that `rules-engine` and
`user-dictionary` conform to; `pipeline-wiring` imports its types (prd.md:234).

## Problem slice

The P0 loop injects raw ASR text verbatim — the gap C5 exists to close (`prd.md:12-17`), and
`ARCHITECTURE.md:273-277` has named the seam since planning, but it is **not code**: no
`CleanupProvider`, no `CleanupContext`, no `ReplacementRule` exists in `Sources/VoccaCore/`
(verified by grep — `ProviderIdentity` and `SessionMode` do not exist anywhere in `Sources/`).
`LatencySpan.cleanup` sits in its `notPresent` state (`prd.md:105-108`; `LatencySpan.swift:27-29`)
because the vocabulary it would record does not exist. Building the rules before this seam is the
project's own named failure mode — a capability shipped without its seam is how the pluggable
claim quietly becomes false (`CLAUDE.md`, capability discipline). This aspect is the seam alone:
protocol, context, rule vocabulary, identity, and the contract tests.

## In scope

1. **`CleanupProvider` protocol in VoccaCore** (`ARCHITECTURE.md:273-277`, requirement M1,
   `prd.md:68-74`): `identity: ProviderIdentity` (non-optional — the I1 attribution discipline),
   `requiresNetwork: Bool` with a `false` default (the hook the zero-network invariant keys on;
   C6's egress badge flips it), and
   `func clean(_ transcript: Transcript, context: CleanupContext) async throws -> String`.
   The throwing shape is the deliberate divergence from the non-throwing `TextInjector`
   (`TextInjector.swift:32-36`) documented at `ARCHITECTURE.md:273`: timeout/failure is a
   first-class outcome the caller routes to raw, and the seam must say so. Mirror the `ASREngine`
   doc-comment style (`ASREngine.swift:39-59`), including the cross-reference to the seam's
   ARCHITECTURE section.
2. **`CleanupContext` in VoccaCore** (`ARCHITECTURE.md:220-225`): `target: TargetContext`,
   `mode: SessionMode`, `dictionary: [ReplacementRule]`, `budget: Duration`. Memberwise init,
   free of defaults, public — the `TargetContext` precedent, whose comment explains why a test
   must be able to build it by hand (`TargetContext.swift:47-51`). `Duration` is stdlib, already
   used in Core (`SessionWatchdog.swift:97`), so no import is needed.
3. **`ReplacementRule` in VoccaCore** (`prd.md:177-181`, `ARCHITECTURE.md:512-513`): ordered
   vocabulary — source phrase/word, replacement, `caseSensitive: Bool`, `wordBoundary: Bool`.
   Order is the contract: declared order is application order (`prd.md:180-181`), so the type
   carries no sorting and the seam test asserts order survives a conformer round-trip untouched.
   `Sendable, Hashable, Equatable, Codable` (all stdlib — `Codable` so the `user-dictionary`
   aspect can persist it without Core ever touching JSON).
4. **`ProviderIdentity` in VoccaCore** (new minimal type — decision in Open questions): `id:
   String`, `displayName: String`, mirroring the `EngineIdentity` shape (`EngineIdentity.swift:27-41`)
   minus `isLocal` — for the cleanup family the egress flag is the protocol's `requiresNetwork`
   (`ARCHITECTURE.md:275`), not a property of the identity.
5. **`SessionMode` in VoccaCore** (new minimal enum — decision in Open questions): `case
   dictation, conversing`. Declared, never read at C5.
6. **Seam-contract tests** in `Tests/HarnessTests/CleanupProviderSeamTests.swift` — B1–B5
   below, written before the types exist. The existing boundary suites must pass unchanged
   (B6–B7) — this aspect adds no `Package.swift` edit and no lint exception.

## Out of scope

- **`RulesCleanup`** — the rules implementation is the `rules-engine` aspect (M2); this aspect
  ships no provider at all, so nothing here executes in CI beyond a stub conformer.
- **`dictionary.json` store** — `user-dictionary` aspect (M3); `JSONDecoder`/`FileManager` never
  appear here, and `VoccaText` is untouched (its leaf status and S1's module move stay in the
  `user-dictionary` aspect).
- **Pipeline wiring, timeout policy, Esc re-check, `LatencySpan.cleanup` flip, `ShippingCleanup`,
  probe witness, floor raise** — the `pipeline-wiring` aspect (M4–M8), which imports this
  aspect's types.
- **Anything that consumes `SessionMode.conversing`** — per-mode cleanup selection is C6/C11
  (`prd.md:219-220`); CONVERSING behavior is P3.
- **Provider attribution on the record (N1)** — belongs to `pipeline-wiring` if it lands at all.

## Isolation / honesty decisions

- **Core stays import-free.** `CoreBoundaryTests.swift:116` pins an empty
  `permittedImports` (enforced at `CoreBoundaryTests.swift:259-266`). Every type this aspect
  adds is stdlib-only: `String`, `Bool`, `Duration`, `Sendable`/`Hashable`/`Equatable`/`Codable`.
  No Foundation, no Dispatch, no FileManager, no JSONDecoder — in the seam or in its test.
- **All real I/O lives in VoccaText** (later aspects). The protocol must be implementable by a
  provider with zero system access; the contract is proven with a stub conformer only — the
  tap-adapter honesty discipline: nothing real executes in CI, and no provider ships here to
  pretend otherwise.
- **Nothing in this aspect moves the zero-network story.** `requiresNetwork` defaults to `false`
  and no network-capable code exists in the tree; C6 is the aspect that flips it.
- **Order is a tested fact, not a comment.** `[ReplacementRule]` ordering is the product's
  declared-order rule (`prd.md:180-181`, `CAPABILITY_ROADMAP.md:124`); the seam test asserts a
  conformer receives the array in the order given.

## Acceptance criteria (tests written first)

All B's are failing `XCTest`s in `Tests/HarnessTests/CleanupProviderSeamTests.swift` (plus the
existing boundary suites, which must already pass), written before the types exist. Each new
file carries the Apache license header (house lint).

- B1 **Protocol shape**: a stub `CleanupProvider` conformance compiles and is driven through
  the protocol — `clean(_:context:) async throws -> String` takes the real `Transcript`
  (`Transcript.swift:32-41`, reading `transcript.text`) and a hand-built `CleanupContext`, and
  the stub's returned `String` arrives at the caller unchanged. The signature being `throws`
  is pinned by declaring the stub `throws` and driving a successful call through `try`.
- B2 **`requiresNetwork` default**: a conformer that does not declare `requiresNetwork` reads
  `false`; a second conformer declaring `true` reads `true` — both asserted, so the C6 egress
  hook is real and the default-config zero-network claim (`prd.md:167-168`) is enforced by the
  protocol's default, not by convention.
- B3 **Identity non-optional**: `identity: ProviderIdentity` is a required, non-optional
  property — a conformer must name itself (the I1 discipline `Transcript.swift:16-21` documents
  for engines); the test asserts a stub's identity `id`/`displayName` survive a drive call
  equal (Hashable equality).
- B4 **`CleanupContext` shape**: a context built by hand carries `target` (a real
  `TargetContext`, `TargetContext.swift:35-51`), `mode` (both `SessionMode` cases constructible),
  `dictionary` (a multi-entry ordered array), and `budget` (a `Duration`) — all four asserted
  field-for-field through a conformer that echoes them, including that `budget` arrives
  unchanged (the caller-enforced budget, `prd.md:89-93`, must not be reinterpreted by the seam).
- B5 **`ReplacementRule` vocabulary**: a rule is `Sendable`/`Hashable`/`Equatable`/`Codable`
  with distinct `caseSensitive` and `wordBoundary` flags; a conformer receiving an ordered
  array of ≥ 3 rules observes them in the exact order given (no sorting, no deduplication);
  `Codable` round-trips a rule through JSON text *outside* Core (in the test, where
  `JSONDecoder` is legal) so the `user-dictionary` aspect's persistence contract is proven to
  fit — while Core itself never imports it.
- B6 **Core boundary**: `CoreBoundaryTests` passes with no edits — the new files add zero
  imports (`permittedImports` stays empty, `CoreBoundaryTests.swift:116`); the import lint
  (`CoreBoundaryTests.swift:259-266`) is the assertion.
- B7 **Module boundary unchanged**: `ModuleBoundaryTests` passes with no edits — `VoccaText`
  stays in `leafModules` (`ModuleBoundaryTests.swift:72-74`), no module is added or moved
  (`adapterModules` untouched at `:99-101`), and the package-manifest coverage guard sees no
  `Package.swift` change.

## Dependencies / sequencing

- Depends on nothing in the unit: it consumes C2's and C4's existing Core vocabulary
  (`Transcript`, `TargetContext`) and stdlib `Duration` only.
- Precedes `rules-engine` and `user-dictionary` — both conform to / consume this seam; the
  `CleanupProvider` and `ReplacementRule` names this aspect introduces are what `pipeline-wiring`
  imports (`prd.md:234`: seam → engine + dictionary in parallel → wiring).
- No new module; no `Package.swift` edit; test floor raised in `pipeline-wiring` (M8), not here.

## Open questions / risks

- **`ProviderIdentity`: new type, not a rename.** `ARCHITECTURE.md:273-277` names
  `ProviderIdentity`; the existing `EngineIdentity` (`EngineIdentity.swift:27-41`) is
  engine-domain (its `isLocal` is the ASR egress flag, used by the model store and attribution).
  Renaming it would churn C2/C3 attribution (`Transcript.swift:41`, `LatencyRecorder.swift:40`)
  for no semantic gain, and sharing it would import the engine domain's `isLocal` into a family
  whose egress flag lives on the protocol. **Decision: new minimal type** (`id`,
  `displayName`, no `isLocal`). Residual risk: a future C6 provider that also happens to be an
  engine carries two identities — accepted; the domains stay separate.
- **`SessionMode` does not exist in code** (verified by grep). The machine's "toggle" is a
  *start configuration* of the same session (`SessionRules.swift:51-53`), not the product's
  dictate-vs-converse dual mode. `ARCHITECTURE.md:222` requires the field in `CleanupContext`
  now. **Decision: minimal Core enum `{ dictation, conversing }`**, documented as declared-never-read
  at C5 (per-mode selection is C6/C11, `prd.md:219-220`). Rejected alternative: deferring the
  field — the context struct is defined by ARCHITECTURE now, and a later field addition would
  churn every conformer and test.
- **The throwing shape is the risk, not the feature.** `TextInjector` never throws
  (`TextInjector.swift:36`), and `CAPABILITY_ROADMAP.md:119` still shows the older non-throwing
  signature; a reviewer might "fix" `clean` to match the first doc they read. B1 pins `throws`,
  and the divergence's justification is written into the protocol's doc comment
  (`ARCHITECTURE.md:273` — authoritative over the roadmap's draft wording).
- **`Codable` on `ReplacementRule` is the persistence contract's first mover.** The store
  aspect's JSON shape will be decided there; the seam only guarantees round-trip-ability. If the
  store later needs a different field layout, the rule type changes in `user-dictionary`, not
  here.
