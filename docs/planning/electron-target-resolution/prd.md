# PRD: Electron Target Resolution

> Source card: `docs/planning/_card/issue.md` (handoff 2026-09-12, from
> `injection-matrix-completion`). Three founder decisions ratified 2026-09-12: **regular-app +
> seeded exclusion-set gate**, **seeded Finder+desktop exclusion set**, **windowTitle nil on
> fallback**.

## Problem Statement

In Chromium/Electron apps (VSCode, Teams, Discord, ChatGPT, Obsidian) the injection ladder
refuses **at rung 0** with `.noFocusedField`: `AXSource.focusedApp()` answers "nothing focused"
(`kAXFocusedApplicationAttribute` on the system-wide element answers nil — fast, within the
0.5 s budget, `AXSource.swift:85-94`), so `TargetContext.bundleID == nil` and
`InjectionLadderDecision.swift:101` fires the refusal **before any rung** — clipboardPaste,
which needs no AX field, never runs. Evidence: 5 recovery journals `{"reason":"noFocusedField"}`
+ usage ledger 2026-09-11 (2 delivered / 5 failsafeHeld); the failing set is exactly the
Chromium apps while every native/WebKit/Gecko app resolves fine (7 of 7 matrix rows landed
2026-09-10). What happens if we don't fix this: 5 of 20 matrix rows stay blocked, FMS stays
uncomputable, and the product's core promise — "type into any app" — fails in the single most
common app class on macOS, with no machine signal that it's failing (the transcript survives
in the failsafe, but the user's expectation of text-on-screen is broken every time).

## Goals & Success Metrics

- **M1 — The 5 Electron rows resolve a target on the shipped build.** VSCode, Teams, Discord,
  ChatGPT, Obsidian deliver via clipboardPaste when a field is focused (matrix rows pass or
  land their expected rung on v0.3.1).
- **M2 — The genuine no-field case still refuses.** With the desktop/Finder frontmost (or any
  excluded app), `.noFocusedField` fires exactly as today — the refusal is structurally
  preserved, pinned by the unchanged `InjectionLadderDecision.swift:97-106` and its test
  (`InjectionLadderTests.swift:121`).
- **M3 — Transcript loss stays 0%.** No path change loses a transcript; the failsafe floor is
  untouched (`.exhausted` and every rung-failure path unchanged).
- **M4 — Test-first in both directions.** RED for "AX nil + field-having regular frontmost →
  bundleID falls back"; RED for "AX nil + no-field frontmost → bundleID stays nil".
- **M5 — The seam lints hold.** `NSWorkspace`/AppKit names confined to one new adapter file;
  `InjectionLadderDecision.swift` and `TargetContext` unchanged; `VoccaCore` gains at most
  plain-data constants.
- **M6 — The fallback never overrides a working AX answer.** When AX answers a non-nil
  bundleID, the frontmost read is not consulted (pinned by a test: AX-answering app → the
  fallback path is untaken and the resolver read counts stay AX-only).

## User Personas & Scenarios

- **The founder (daily user, lives in VSCode/Chrome).** Scenario: dictate into VSCode's editor
  → text lands in the editor. Today it lands in the failsafe with "Nothing was focused."
- **The P2 gate's external users.** Dictation parity across Electron apps is the make-or-break
  surface (ROADMAP.md:180); this unblocks the matrix's Electron rows.
- **A future contributor.** The gate must be readable as a decision in one place: AX lie vs
  genuine no-field, with the exclusion set a named, tested constant.

## Requirements

### Must-have

- **R1 (seam):** `FrontmostAppReading` protocol (async, `AnyObject`+`Sendable`, the
  `FocusedAppReading` shape — `TargetResolution.swift:51-54`) + `SystemFrontmostApp` adapter in
  a **new single file** (`VoccaInject/Accessibility/`), the only file in `VoccaInject` naming
  `NSWorkspace`. Answers the frontmost application's bundle ID (via
  `NSWorkspace.shared.frontmostApplication`), its activation policy (`.regular`),
  `nil` when there is no frontmost app.
- **R2 (the gate, in `TargetResolution.resolve()`):** when the AX identity's `bundleID == nil`:
  fall back to the frontmost bundle ID **iff** it is non-nil **and** the frontmost app's
  activation policy is `.regular` **and** it is not in the seeded no-field set. On fallback,
  `windowTitle` is `nil` (ratified); `isSecureInput` is read exactly as today, and the Secure
  Input precedence (rung-0 refusal #1) is untouched.
- **R3 (seed):** `SeededNoFieldApps` — a seeded, tested constant (mirroring
  `SeededHostileApps`). **Concrete contents: `["com.apple.finder"]`** — Finder *is* the
  desktop; the other no-field contexts (dock `com.apple.dock`, menu-bar apps, utilities) are
  `.accessory`/`.prohibited` activation policy and are already excluded by the R2 policy gate,
  so the seed carries only the `.regular` no-field apps and is extensible as real ones are
  found (the reasoning is documented in the file and pinned by a test).
- **R4 (wiring):** `TargetResolution.init` gains the frontmost seam; the composition root
  (`AppBootstrap.swift:186-187`) and every test construction site are updated — the compile
  pins break first (RED), the recipe test
  (`TargetResolutionSurfaceTests.swift:49`) is the reviewed seam-change pin.
- **R5 (decision untouched):** `InjectionLadderDecision.swift` is byte-for-byte unchanged;
  `TargetContext` shape unchanged (no new fields); `bundleID == nil` in `TargetContext`
  keeps meaning "genuinely no usable target".

### Should-have

- **S1:** a test that the fallback path never names a system identifier outside the adapter
  (the boundary lints already scan; add the positive pin).
- **S2:** the live-proof aspect records the 5 Electron rows on the installed v0.3.1 build,
  the desktop refusal, and any second defect surfaced (e.g. Chromium ⌘V handling) — with the
  honest record (STATUS, tracked-table row, CLAUDE.md sync).

### Nice-to-have

- **N1:** the fallback is documented in `TargetResolution.swift`'s header (the resolver's
  decision list gains the fallback row).

## Technical Considerations

- **Layer/phase:** P2 injection (make-or-break battle #2, `ROADMAP.md:158-167`); the injection
  layer's target-resolution seam. Local-only, no egress, no cloud — no guardrail conflict.
- **The blind-paste widening argument (why the gate is safe):** today, a regular app with no
  text field focused (e.g. a settings window) already resolves via AX and receives a blind
  clipboardPaste (⌘V no-ops). The fallback converts the Chromium lie into the *same treatment
  regular apps already get* — it does not widen the blind-paste surface; the exclusion set
  keeps the desktop case out.
- **Headless testability:** the resolver's three reads are injected seams (AX identity,
  frontmost, secure input) — the gate is a pure decision over them, fully testable; the
  adapter itself (`SystemFrontmostApp`) is glue with no decisions, executed by nothing in CI
  (the AX/tap precedent).
- **Lint map:** `InjectionBoundaryPins`' `NS`-prefix scan covers `VoccaCore` vocabulary files
  and `VoccaInject/Ladder/` (excluding `ShippingLadder.swift`); `TargetResolution.swift`
  (`VoccaInject/Accessibility/`) is outside that scan; `import AppKit` is unrestricted. The
  gate's `NS`-free logic in `resolve()` is clean; the adapter owns the names.
- **Test construction sites:** ~11 sites build `TargetResolution` (AppBootstrap + test files);
  the init change is mechanical but must be part of the RED.
- **Release:** the live-proof aspect needs a v0.3.1 build installed (the release machinery
  exists — `release-distribution`); the matrix runs against the installed build per the
  tracked-table discipline. **Sequencing note:** the founder builds + installs v0.3.1
  (release-distribution recipe) before the `electron-matrix-proof` aspect runs; the code
  aspect (`resolver-fallback`) lands and merges first.
- **Second-defect posture (pre-decided):** if the live-proof shows the fallback resolving but
  Chromium's ⌘V not pasting (delivered-but-invisible), the fix is **in this unit, test-first** —
  the unit's entire point is Electron delivery, and the paste mechanics are a rung-level
  defect (M8). Only a seam-level design change (a new rung, a protocol change) escalates.

## Risks & Open Questions

- **The gate's empirical assumption:** `NSWorkspace.shared.frontmostApplication` reliably
  answers the Electron app. It is AppKit's standard read (the harness's System Events read is
  the same fact); residual risk low, verified in the live-proof.
- **A second Electron defect may surface:** the paste rung's ⌘V into these apps is *unverified*
  (`verified: false` by design). If text lands in the failsafe → delivered-but-invisible in
  an Electron app, the live-proof stops on a second named defect (M8 rule: fix test-first or
  escalate). The risk is named, not papered over.
- **The "regular app with no field" residual:** a regular, non-excluded app whose AX read fails
  and which has no text field gets a blind paste (⌘V no-op, "delivered" recorded) — identical
  to today's regular-app behavior; named as the accepted residual of the ratified gate.
- **The 17/20 ceiling** (3 permanent skips) stands until the founder decides the row-set
  question — out of scope here, recorded not changed.

## Out of Scope

- No changes to the ladder decision table, the allowlist, `SecureInputReading`, the clipboard
  protocol, `phrase_matches`, or the harness.
- No new `TargetContext` fields; no UI copy changes ("Nothing was focused" stays for the
  genuine case).
- No row-set/gate decisions (17/20 ceiling), no app installs, no cloud, no P3+ work.

---

## Aspect decomposition

| Aspect | Boundary |
|--------|----------|
| `resolver-fallback` | The seam + adapter, the gate, the seeded exclusion set, the wiring — code, test-first, lints green. |
| `electron-matrix-proof` | v0.3.1 build + install, the 5 Electron matrix rows + desktop-refusal check, the record (STATUS, tracked-table v0.3.1 row, CLAUDE.md sync). |