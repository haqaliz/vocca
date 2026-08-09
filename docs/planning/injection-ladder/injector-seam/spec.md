# Aspect: Injector seam — pure ladder over injected handles

**Aspect slug:** `injector-seam` · Part of `docs/planning/injection-ladder/prd.md`

## Problem slice and user outcome

The seam and the decision half of C4, entirely in `VoccaCore` (imports nothing,
`CoreBoundaryTests.swift:98-116`): the vocabulary (`TextInjector`, `TargetContext`,
`InjectionRung`, `InjectionResult`, `VoccaError.injectionExhausted`), the pure ladder
decision function, and the injected-handle structure that makes every failure combination
headlessly testable. Outcome: the "never lose a word" guarantee becomes a tested fact at
the decision layer before any system API exists.

## In-scope requirements

- `TextInjector` protocol: `inject(_ text: String, into target: TargetContext) async -> InjectionResult` (`ARCHITECTURE.md:239-241`), `Sendable`.
- Types (`ARCHITECTURE.md:160-177`): `TargetContext` (`bundleID`, `windowTitle`,
  `isSecureInput`; **no `AXElementRef`** — resolved in the adapter; amendment note to
  `ARCHITECTURE.md:161-166`), `InjectionRung` (`accessibility, clipboardPaste,
  keystrokeSynthesis, widgetFailsafe`), `InjectionResult` (`rung`, `attempted: [InjectionRung]`,
  `verified: Bool`, `elapsed: Duration`), `VoccaError.injectionExhausted(attempted:)`;
  **no `transcriptLost` case** (`ARCHITECTURE.md:199`).
- The ladder decision function, pure: rung-0 Secure Input refusal (`attempted: [],
  reason: .secureInput`, `ARCHITECTURE.md:382-384`); iterate an **injected** rung order
  (C8 slot-in point; at C4 the default order is pinned: AX for allowlisted bundle IDs →
  clipboard → keystroke → failsafe); AX success-without-verification counts as failure
  (`ARCHITECTURE.md:400`); exhaustion → failsafe with reason `.exhausted`; `elapsed` from
  the injected `MonotonicClock` (`CoreBoundaryTests.swift:707`).
- An injected rung-handle protocol (`RungStrategy`-shaped) over which the decision runs:
  each handle reports raw outcomes (inserted/verified, pasted, typed, held); the decision
  layer interprets. Fake handles for the suite.
- An injected allowlist provider (should-have S1: seeded list of known-good bundle IDs;
  decision, not data, lives here).
- `FailsafeReason` (`secureInput, exhausted, noFocusedField`; `accessibilityRevoked` case
  reserved per `PRODUCT_SPEC.md:114` — detection deferred, N1).
- Core-owned `HeldTranscript` seam (the `ModelDownloadSession` pattern,
  `download-ui/plan_20260809.md:32-37`): hold / retrieve / release / retry — the contract
  the failsafe rung's implementation and the `VoccaUI` surface both speak. Journal-atomicity
  contract (PRD R6): the failsafe path must be durable before it returns.
- The `SecureInputStateReader` seam already in `VoccaCore` (C1) is reused by the decision
  (an injected read; the real Carbon line is the adapters aspect's).

## Out-of-scope boundaries

- No system APIs in any file this aspect creates — the one-file adapters that name
  `CGEvent`/`AXUIElement`/`NSPasteboard`/Carbon are the adapters aspect's.
- The `VoccaInject` **module move (leaf → adapter)** is part of this aspect: the ladder's
  pure decision function and `LadderInjector` live in `VoccaInject/Ladder/` per
  `ARCHITECTURE.md:100-104`, with the `TapHealthPolicy` precedent (pure decisions in the
  adapter module, tested over injected handles). The move is the reviewed
  `ModuleBoundaryTests` edit the adapters aspect would otherwise need first.
- No strategy memory, no per-app learning (C8), no adaptive settle delay.
- No loop wiring (session → ASR → inject).
- No `VoccaUI` work (failsafe aspect).

## Acceptance criteria (written first, headless)

- A1: `TextInjector`/types exist in `VoccaCore` and the Core boundary lints stay green
  (zero imports; no `@discardableResult`; no mutable global state).
- A2: Table-driven decision suite over fake handles: every rung ordering, every failure
  combination, both activation paths (dictate-mode default; no converse mode exists yet).
- A3: **Fault injection**: each rung forced to fail in sequence, including a fake that
  returns success-with-no-insert; the ladder falls through and the transcript reaches the
  failsafe handle in every combination — zero-loss assertion, no tolerance band
  (`CAPABILITY_ROADMAP.md:106`).
- A4: Secure Input refusal returns before any rung is attempted (`attempted == []`) with
  reason `.secureInput` and the product copy as its message carrier.
- A5: Default rung order pinned: allowlisted-AX-first, clipboard, keystroke, failsafe;
  a custom injected order changes the sequence without touching the decision code (C8
  readiness).
- A6: `elapsed` measured from the injected clock; ladder budget ≤100 ms is asserted with
  realistic fake-handle costs.
- A7: `HeldTranscript` seam state transitions (hold → retrieve → release → retry) tested
  with no UI and no files.

## Dependencies and sequencing

First aspect — nothing depends on it within C4; it depends on nothing new (C1/C2 already
shipped the Core seam discipline). The adapters aspect consumes the injected-handle
protocol; the failsafe aspect consumes `HeldTranscript`.

## Open questions / risks

- Whether `TargetContext` should carry the resolved target's `bundleID` as non-optional
  `String` when focus resolution fails (decision: `.noFocusedField` fires before rungs run;
  resolution is the adapters' concern — the seam only carries what the decision needs).
- The `RungStrategy` naming/arities will be settled by the failing tests (A2/A3), not by
  prose.
