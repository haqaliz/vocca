# Spec: resolver-fallback

> Aspect of `electron-target-resolution` (PRD rev 2026-09-12, M1-M6, R1-R5, S1, N1).

## Problem slice

The injection ladder refuses at rung 0 with `.noFocusedField` in Chromium/Electron apps
because the AX focused-app read answers nil, and clipboardPaste — which needs no AX field —
never runs. This aspect adds the gated frontmost-app fallback to target resolution. The
ladder's decision table and `TargetContext` stay byte-for-byte unchanged: `bundleID == nil`
keeps meaning "genuinely no usable target".

## In scope

- **R1 (seam):** `FrontmostAppReading` protocol (async, `AnyObject`+`Sendable`, the
  `FocusedAppReading` shape) in `Sources/VoccaInject/Accessibility/TargetResolution.swift`,
  answering `FrontmostAppIdentity(bundleID: String?, isRegular: Bool)` (a plain-data struct —
  `isRegular` is the adapter's raw translation of `.regular`, no AppKit type crosses the
  seam). `SystemFrontmostApp` adapter in a **new file**
  `Sources/VoccaInject/Accessibility/SystemFrontmostApp.swift` — the only file in
  `VoccaInject` naming `NSWorkspace` (pinned). `nil` when there is no frontmost app.
- **R2 (the gate, in `TargetResolution.resolve()`):** the fallback fires **only** when the AX
  identity's `bundleID == nil`, and then **iff** frontmost bundleID non-nil **and**
  `isRegular` **and** not in `SeededNoFieldApps`. On fallback: `windowTitle = nil` (ratified).
  `isSecureInput` is read once, fresh, exactly as today, on every path. **M6:** when AX answers
  non-nil, the frontmost read is never consulted (read-count pin).
- **R3 (seed):** `Sources/VoccaInject/Allowlist/SeededNoFieldApps.swift` —
  `public enum SeededNoFieldApps { public static let bundleIDs: Set<String> = ["com.apple.finder"] }`
  with the reasoning documented (Finder is the desktop; dock/menu-bar/utility apps are
  `.accessory`/`.prohibited` and excluded by the R2 policy gate, so the seed carries only
  `.regular` no-field apps; extensible).
- **R4 (wiring):** `TargetResolution.init` gains the frontmost seam;
  `AppBootstrap.swift:186-187` and every test construction site updated (compile RED first;
  `TargetResolutionSurfaceTests.swift:49` is the reviewed recipe pin).
- **R5 (untouched):** `InjectionLadderDecision.swift`, `TargetContext.swift` (no new fields),
  `SecureInputReading`, the clipboard protocol — no changes. The existing
  `testNoFocusedFieldRefusesAtRungZeroWithAnEmptyTrace` (`InjectionLadderTests.swift:121`)
  and `testNothingFocusedResolvesToNilBundleID` (`AccessibilityRungTests.swift:216`) stay green
  and continue to pin the genuine case.
- **S1 (boundary pin):** `InjectionSeamBoundaryTests` gains a one-file family row: `NSWorkspace`
  confined to `SystemFrontmostApp.swift` (the `NSRunningApplication` use in `AXSource.swift:174`
  predates the family and stays).

## Out of scope

- No ladder decision changes, no `TargetContext` fields, no UI copy, no clipboard protocol
  changes, no harness changes, no row-set decisions.

## Acceptance criteria (test-first)

1. **RED:** the new resolver tests fail against the current code (no seam, no gate — compile
   failures and/or gate absent); the recipe test breaks with the init change.
2. **GREEN:** all new tests pass; every existing resolver/ladder/recipe test passes; the
   `NSWorkspace` boundary pin passes; `Scripts/test-with-floor.sh` passes (floor 1936 — the
   count rises by the new tests, floor never drops).
3. The five gate directions are pinned: fallback fires (AX nil + regular + unseeded frontmost
   with bundleID); does not fire for `.accessory`; does not fire for `com.apple.finder`;
   does not fire when the frontmost has no bundleID; **never consults the frontmost read when
   AX answers** (read-count == 0).
4. Secure Input is read on the fallback path too (fresh single read).

## Dependencies & sequencing

- First aspect; the proof aspect consumes the shipped build.
- No dependency on the harness changes from the previous unit (they are on master already).

## Open questions / risks

- The gate's empirical assumption (`NSWorkspace.shared.frontmostApplication` answers Electron
  apps reliably) is verified in the proof aspect, not here.
- The adapter is glue executed by nothing in CI (the AX/tap precedent); its decisions are all
  above the seam, tested headlessly.