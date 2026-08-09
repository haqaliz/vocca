# Aspect: Injection adapters — the real-API half, one file each

**Aspect slug:** `injection-adapters` · Part of `docs/planning/injection-ladder/prd.md`

## Problem slice and user outcome

The `VoccaInject` module becomes real: the leaf→adapter move and the four one-file,
no-decision adapters that speak the system APIs the seam cannot name. Outcome: the ladder's
decisions run headless (injector-seam aspect); the adapters are translation with no
decisions in them — the tap-adapter precedent (`CLAUDE.md`).

## In-scope requirements

- **Module move:** `VoccaInject` leaf → adapter (`ModuleBoundaryTests.swift:72-85`,
  `Package.swift:72-76`): imports `VoccaCore` and nothing else among Vocca modules
  (`:223-243`); probe's `VoccaInjectPlaceholder` reference replaced
  (`VoccaNetworkProbe.swift:22`).
- **H7 amendment** (PRD R4 — the dig's biggest structural find): the `CGEvent`/`CGKeyCode`
  family gains a second permitted file — the keystroke adapter — under a **per-seam
  permitted-file structure**: the tap adapter keeps its rule untouched; the keystroke
  adapter gets its own entry, forbidden-prefix list, and window scope. Both pins two-sided
  (each permitted file must actually name its family; no other file may;
  laundering routes closed — `HotkeySeamBoundaryTests.swift:81-98, 201-209, 235-249`).
  Record the amendment in `ARCHITECTURE.md` and `CLAUDE.md`.
- **Keystroke adapter** (the sole CGEvent file in `VoccaInject`): `typeText(_:)` chunked +
  rate-limited (policy above the seam), and `pressPaste()` — the ⌘V the clipboard rung
  calls through the protocol. No decisions in the file.
- **Clipboard adapter:** snapshot all pasteboard types + `changeCount`, write, note ours,
  settle (~80 ms fixed), restore **only if `changeCount` is still ours** — never clobber a
  manager (`ARCHITECTURE.md:408-414`). Names no `CGEvent` — the paste goes through the
  keystroke seam.
- **AX adapter:** insert via `kAXSelectedTextAttribute` + read-back verification, raw
  results only; per-call timeout below the system default; never on the main thread
  (`ARCHITECTURE.md:323`); target resolution (focused app → `TargetContext`).
- **Secure Input adapter:** one Carbon line (`IsSecureEventInputEnabled`) behind the Core
  `SecureInputStateReader` seam (`SystemSecureInputState` precedent, `SecureInput.swift:92-105`).
- **New one-file seam lints, H9-style** (PRD R5): exactly one file may name
  `AXUIElement`/ApplicationServices; exactly one may name the `NSPasteboard` family;
  exactly one may name `IsSecureEventInputEnabled`. Re-export tables govern what the lints
  must catch (`HotkeySeamBoundaryTests.swift:462-478`).
- **Deinit-isolation rule** (`DeinitIsolationTests`): any `deinit` in the new adapters uses
  only the non-asserting teardowns — the fourth object to inherit the rule.
- **Zero-network probe drives the injection path** (PRD R9): the probe runs the ladder over
  the real adapters with a **default configuration that cannot touch a hostile API on a
  runner** — i.e. adapters are exercised through injected handles; the module-coverage
  cross-check (`ZeroNetworkTests.swift:311-325`) must pass with the new module real.

## Out-of-scope boundaries

- No decision logic in this module (all in `VoccaCore` per the seam aspect).
- No strategy memory (C8), no adaptive settle, no allowlist learning.
- No failsafe UI, no journal (failsafe aspect).
- No loop wiring.

## Acceptance criteria (written first)

- A1: Module-boundary lints green with `VoccaInject` in `adapterModules`; probe drives it;
  zero-network suite green.
- A2: H7 amendment: exactly two permitted files (`CGEventTapSource.swift`,
  keystroke adapter), each two-sided pinned; planted violations fail; the count assertion
  re-aimed at the per-seam level.
- A3: Each new seam lint has the H7/H8 two-sided form with positive controls.
- A4: Clipboard adapter: a racing-fake-manager test asserts restore is skipped when
  `changeCount` moved (never clobber); the save/set/paste/restore ordering is pinned by an
  event-logging fake pasteboard (headless — `NSPasteboard` itself works in-process, so the
  adapter is testable headless where AX is not).
- A5: AX adapter: insert + read-back return raw outcomes; the adapter itself is executed by
  nothing in CI (TCC) — its contract is pinned by the seam tests and the smoke checklist
  (documented, not fake-tested).
- A6: Keystroke adapter: `pressPaste()` and `typeText(_:)` compile behind the protocol;
  chunking policy is tested above the seam.
- A7: Secure Input adapter: one Carbon line, behind the Core seam, tested via the injected
  read (the decision suite from the seam aspect); the real read is a smoke step
  (`SMOKE_CHECKLIST.md` steps 36–38 pattern).

## Dependencies and sequencing

After `injector-seam` (consumes the injected-handle protocol and `TargetContext` shape).
Before `failsafe-surface` (the rungs the failsafe rung falls back on must exist).

## Open questions / risks

- **The H7 amendment is the highest-risk edit in C4** — a release-blocking lint whose
  doctrine says "nothing else ever joins it" (`HotkeySeamBoundaryTests.swift:74-75`). The
  amendment is reviewed as a standalone commit with both pins moved deliberately; the old
  `<= 1` count test is replaced, not weakened.
- Whether `pressPaste` belongs in the keystroke adapter vs. the clipboard adapter: decided
  here (keystroke) — the clipboard file must stay CGEvent-free for the lint structure to be
  one-file-per-family.
- The AX adapter's target resolution (focused app → `TargetContext`) is the part most
  likely to need review against real app focus states; smoke checklist covers it.
