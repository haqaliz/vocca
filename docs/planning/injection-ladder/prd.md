# C4 — System-wide injection ladder — PRD

**Slug:** `injection-ladder` · **Phase:** P0, week 3 (`docs/ROADMAP.md:84`) · **Owner:** aliz
**Sources:** `docs/planning/_card/issue.md` (brief), `docs/planning/_card/understanding.md` (dig),
`docs/technical/CAPABILITY_ROADMAP.md` C4 (lines 89–110), `docs/technical/ARCHITECTURE.md`
(§4 types, §8 TextInjector, §10 custody), `docs/product/PRODUCT_SPEC.md` (§3–4 widget/failsafe),
`docs/ROADMAP.md` (P0, risks R1/R2/R9).

---

## 1. Problem Statement

The P0 dictation loop is capture → ASR → inject. Capture (C1, in flight) and ASR (C2, merged)
exist, but the transcript has nowhere to go — `TextInjector` is prose in `ARCHITECTURE.md:239-241`
and `VoccaInject` is a placeholder leaf. The capability is the second make-or-break UX battle
(`CLAUDE.md` constraint 5): text that comes out of the ASR seam must land in the focused field
of any app, and when every rung fails it must be held somewhere the user can copy it.

The macOS environment is actively hostile to this:

- **R1 — AX silently no-ops** (`ROADMAP.md:300`, High likelihood / **Fatal** impact):
  `AXUIElementSetAttributeValue` on `kAXSelectedTextAttribute` returns success while inserting
  nothing in Electron, custom text views, and browser editors. A silent data-loss failure mode
  is the worst bug this product can have.
- **R2 — Secure Input blocks everything** (`ROADMAP.md:301`, High / Med): password fields and
  some terminals refuse event taps entirely. An honest refusal beats a mysterious no-op.
- **Clipboard managers race the restore** (`ROADMAP.md:85`, `ARCHITECTURE.md:405-415`): Raycast,
  Alfred, Paste, and Maccy take pasteboard ownership mid-dictation; stomping them is worse than
  leaving our text there.

**The non-negotiable:** a transcript is never lost (`ROADMAP.md:25`, I1). Every failure path
terminates in the widget failsafe with recoverable, copyable text and a plain-language reason.

## 2. Goals & Success Metrics

| Goal | Metric | How it's measured |
|---|---|---|
| Text lands where it should | ≥90% first-method-success across the P0 app matrix (`ROADMAP.md:95`) | Manual matrix gate (`SMOKE_CHECKLIST.md` additions) — real apps cannot run on a hosted runner |
| Never lose a word | **0%** transcript loss; no tolerance band (`ROADMAP.md:96`, `CAPABILITY_ROADMAP.md:106`) | Seam-level fault-injection suite in CI: every rung forced to fail in sequence, including AX's silent success-with-no-insert; transcript recoverable in every combination |
| Ladder stays inside the latency budget | Ladder ≤100 ms (`ARCHITECTURE.md:271`) | Injected-clock elapsed assertions in the suite |
| Clipboard survives the manager race | Restore never clobbers a manager's take-over; 100-dictation survival at the C8 gate (`ROADMAP.md:85`) | Headless pasteboard tests with a racing fake manager |
| Honest refusal on Secure Input | Secure Input short-circuits to the failsafe with the product copy (`PRODUCT_SPEC.md:111`) | Decision tested over the injected `SecureInputStateReader`; real read is a smoke step |
| Failsafe holds text through restarts | Unresolved transcripts reappear on next launch (`PRODUCT_SPEC.md:117`) | Recovery-journal tests: write, relaunch-equivalent reload, purge on resolution |

## 3. User Personas & Scenarios

**ICP** (per `VISION.md`): a Mac user who lives in dictation all day and wants it private and
local — won't send audio to the cloud, still wants polished text typed anywhere.

| Scenario | What must happen |
|---|---|
| Dictate into Notes (native AppKit) | Text lands, `✓ → Notes` confirmation (widget states come later; the seam's result carries the rung) |
| Dictate into Google Docs (custom editor) | AX is not on the allowlist or read-back fails → clipboard rung lands it |
| Dictate into Slack (Electron) | Same ladder, same guarantee |
| Password field focused | Secure Input detected at injection time → failsafe immediately, "This looks like a password field. Vocca won't type into it — press ⌘C to paste it yourself." (`PRODUCT_SPEC.md:111`) |
| Wrong window focused | Failsafe holds the text; user clicks the right field, presses ⏎, the ladder re-runs against current focus (`PRODUCT_SPEC.md:116`) |
| Every rung failed | Failsafe persists (never auto-dismisses), text selectable, ⌘C works without the window taking focus (`PRODUCT_SPEC.md:99-106`) |
| App restart after an unresolved transcript | The text is still there, with a note of when it was captured (`PRODUCT_SPEC.md:117`) |

## 4. Requirements

### Must-have (each with its acceptance test — written first)

**R1 — `TextInjector` seam in `VoccaCore`, import-free.**
`inject(_ text: String, into target: TargetContext) async -> InjectionResult`
(`ARCHITECTURE.md:239-241`). Types: `TargetContext` (`bundleID`, `windowTitle`, `isSecureInput`
— **no `AXElementRef` in Core**: the Core boundary imports nothing, `CoreBoundaryTests.swift:98-116`;
the AX element is resolved inside the adapter, amendment to `ARCHITECTURE.md:161-166`),
`InjectionRung` (`accessibility, clipboardPaste, keystrokeSynthesis, widgetFailsafe`),
`InjectionResult` (`rung`, `attempted: [InjectionRung]`, `verified: Bool`, `elapsed: Duration`),
`VoccaError.injectionExhausted(attempted:)` — and deliberately **no** `transcriptLost`
(`ARCHITECTURE.md:193-199`).
*Acceptance:* boundary lint accepts the new Core vocabulary (still zero imports); the
decision table over the ladder is fully driven by the headless suite.

**R2 — The ladder decision function, pure and above the seam.**
(`ARCHITECTURE.md:378-395`) Rung 0: `target.isSecureInput` → failsafe with `attempted: []`,
reason `.secureInput`. Then iterate an **injected** rung order (`strategyStore.orderedLadder(for:)`
is C8's; at C4 the default order is pinned: AX only for allowlisted bundle IDs, clipboard
everywhere else, keystroke last, failsafe always). AX rung: success without read-back
verification counts as failure (`ARCHITECTURE.md:400`). Exhaustion → failsafe, reason
`.exhausted`. `elapsed` from the injected `MonotonicClock` (`CoreBoundaryTests.swift:707`).
*Acceptance:* table-driven suite over injected fake rung handles — every ordering, every
failure combination, both activation paths; **fault injection drives each rung to fail in
sequence, including a fake that returns success-with-no-insert, and asserts the transcript is
recoverable in every combination** (`CAPABILITY_ROADMAP.md:106`).

**R3 — One-file, no-decision rung adapters in `VoccaInject` (leaf → adapter).**
- **AX adapter** (`Accessibility/`): insert + read-back, raw results only; per-call timeout
  below the system default; never on the main thread (`ARCHITECTURE.md:323`).
- **Clipboard adapter** (`Clipboard/`): snapshot all pasteboard types + `changeCount`, write,
  note our `changeCount`, settle (~80 ms, fixed at C4), restore **only if `changeCount` is
  still ours** — never clobber a manager (`ARCHITECTURE.md:408-414`). The ⌘V itself is NOT
  this file's job: it calls the keystroke seam (`pressPaste()`), so the clipboard adapter
  names no `CGEvent` — the one-CGEvent-file structure stays airtight.
- **Keystroke adapter** (`Keystroke/`): the **sole** `CGEvent`-naming file in `VoccaInject`
  (per the H7 amendment, R4). Exposes two operations behind a protocol:
  `typeText(_:)` (chunked, rate-limited — `ARCHITECTURE.md:403`) and `pressPaste()`
  (the ⌘V the clipboard rung needs). No decisions in the file; the chunking policy lives
  above the seam.
- **Secure Input read**: one Carbon line behind the Core `SecureInputStateReader` seam
  (C1 shipped the seam; `VoccaInject` cannot import `VoccaHotkey`, so it gets its own
  adapter file — `SystemSecureInputState` precedent, `SecureInput.swift:92-105`).
*Acceptance:* module move lands `VoccaInject` in `adapterModules` with only the `VoccaCore`
dependency (`ModuleBoundaryTests.swift:223-243`, `Package.swift`); the probe's
`VoccaInjectPlaceholder` reference is replaced by real probe drive.

**R4 — The H7 amendment (the dig's biggest structural find).**
Rung 3 must name `CGEvent`/`CGKeyCode`; H7 today permits exactly one file tree-wide and
"nothing else ever joins it" (`HotkeySeamBoundaryTests.swift:81-98, 201-209`). Amend the lint
to a **per-seam permitted-file structure**: the tap adapter keeps its rule; the keystroke
adapter gains its own entry, its own forbidden-prefix list (plus the window the scan checks).
*Acceptance:* both permitted files pass the two-sided pins (each must actually name its
family); planted violations still fail; `ARCHITECTURE.md` and `CLAUDE.md` record the
amendment.

**R5 — New seam lints, H9-style.**
Exactly one file may name `AXUIElement`/`ApplicationServices`; exactly one may name
`NSPasteboard`/`AppKit` pasteboard; exactly one may name `IsSecureEventInputEnabled`
(the re-export tables at `HotkeySeamBoundaryTests.swift:462-478` govern what the lint must
catch — AppKit re-exports the CGEvent family, so the keystroke/⌘V question is covered by R4).
*Acceptance:* each lint has the H7/H8 two-sided form (one file may, no other may) plus the
laundering-route checks.

**R6 — Failsafe rung: always succeeds, text handed to a Core-owned custody seam.**
`VoccaUI` may import only `VoccaCore` (`ModuleBoundaryTests.swift:281`), so the held-text
surface is a Core seam in the `ModelDownloadSession` pattern (`download-ui/plan_20260809.md:32-37`):
hold/release/retry of a `HeldTranscript`. **The journal commit (R8) is atomic with this
hand-off** — the text is durable before the ladder returns, closing the crash-between-
exhaustion-and-journal window; "rung 4 always succeeds" is only true if the floor is
durable, not just visible. *Acceptance:* the ladder's failsafe path resolves through the
seam; a test asserts the held text survives a simulated ladder-exhaustion and is
retrievable; a test asserts the journal file exists before the failsafe path returns.

**R7 — Minimal FAILSAFE window in `VoccaUI`.**
Persistent (never auto-dismisses), selectable text, long transcripts scroll, ⌘C copies
without the window taking focus, cause-specific reason in plain language, ⏎ retry re-runs the
ladder against current focus, ✕ dismisses (`PRODUCT_SPEC.md:48-55, 99-117`). Reasons at C4:
`.secureInput`, `.exhausted`, `.noFocusedField` ("Nothing was focused. Click where you want
this, then press ⏎." — `PRODUCT_SPEC.md:113`). **Mechanism:** a non-activating `NSPanel`
(`.nonactivatingPanel`), shown on demand — the window never takes focus (`PRODUCT_SPEC.md:22`);
⌘C/⏎/✕ are handled via the panel's key-equivalent path so the copy works while focus stays
in the target app. *Acceptance:* headless tests over the Core seam (hold/release/retry state
transitions); the copy path is pasteboard-testable in process; focus non-taking and window
chrome are smoke steps (`SMOKE_CHECKLIST.md`).

**R8 — Recovery journal.**
Bounded, purged, under `~/Library/Application Support/Vocca/recovery/`
(`ARCHITECTURE.md:437`): unresolved transcripts persist across launches and reappear in the
failsafe with a captured-at note (`PRODUCT_SPEC.md:117`). *Acceptance:* write → reload
(launch-equivalent) → text present; resolve → purge; bound enforced (oldest dropped first).

**R9 — Zero-network probe drives the injection path.**
Every module must be driven by the probe's default-configuration path
(`ZeroNetworkTests.swift:311-325`); a full dictation-path drive including the ladder (with
injected adapters) proves the C4 additions add no network. *Acceptance:* suite green with the
interposer; pasteboard/AX/keystroke adapters run against injected handles in the probe.

**R10 — `SMOKE_CHECKLIST.md` additions.**
Real-app matrix steps (native AppKit: Notes/Mail/TextEdit; Electron: VS Code/Slack; browsers:
Safari/Chrome + Google Docs; terminals; IntelliJ; hostile: Secure Input field, 1Password —
`ROADMAP.md:91`), clipboard-manager coexistence, Secure Input failsafe gestures, failsafe
copy-without-focus. *Acceptance:* the checklist's own "add to it" rule (`SMOKE_CHECKLIST.md:604-607`).

### Should-have

- **S1 — Seed allowlist**: hand-curated top ~10 bundle IDs (`ARCHITECTURE.md:558`'s leaning),
  decided above the seam (an injected allowlist provider), editable and inspectable; C8 learns
  the rest.
- **S2 — Deinit-isolation rule extended**: the fourth object in `Sources/` inheriting the
  non-asserting-teardown rule if `VoccaInject` owns a timer/handle (`DeinitIsolationTests`).

### Nice-to-have

- **N1 — Accessibility-revoked-mid-session** detection: the reason enum carries the case
  (`PRODUCT_SPEC.md:114`); the TCC observer wiring is deferred (maps to the tap domain,
  `ARCHITECTURE.md:515`).
- **N2 — Failsafe sound** (`PRODUCT_SPEC.md:242`), keyboard-operability pass
  (`PRODUCT_SPEC.md:256`).

## 5. Technical Considerations

- **Phase:** P0, week 3. **Dependencies:** C1 — the ladder itself is testable against canned
  strings before ASR exists (`CAPABILITY_ROADMAP.md:110`); the *loop wiring*
  (session → ASR → inject) is explicitly out of scope (see §8). Independent of C2/C3.
- **Module graph:** `VoccaCore ← VoccaInject` (adapter move; imports `VoccaCore` and nothing
  else among Vocca modules); `VoccaUI → VoccaCore` only. All seam vocabulary import-free;
  adapters one-file, no decisions — the tap-adapter precedent (`CLAUDE.md`).
- **Threading:** AX calls never on the main thread, explicit per-call timeout; the UI thread
  renders state only (`ARCHITECTURE.md:316-323`).
- **Latency:** ladder ≤100 ms budget (`ARCHITECTURE.md:271`); measured via injected clock;
  no streaming, no speculative work at C4.
- **Privacy/local-first:** all four rungs are local APIs — no network is added to the default
  path (R9 enforces it). Clipboard restore never clobbers a manager. No context capture
  (that's C12). BYOK/cloud untouched.
- **Pluggability:** the injected rung order is the C8 slot-in point; the rung-strategy seam
  means `TextInjector` ships with the ladder orchestration *and* the per-rung strategies as
  its implementations (`ARCHITECTURE.md:212`), keeping the "two implementations" rule honest.

## 6. Risks & Open Questions

| # | Risk / Question | Mitigation / Decision |
|---|---|---|
| 1 | **H7 amendment breaks a release-blocking lint** if the per-seam structure is botched | The amendment is a reviewed edit with two-sided pins (permitted file must name its family; no other may); planted-violation positive controls retained; record in `ARCHITECTURE.md` |
| 2 | **R1 resurfaces**: AX verification misses a lying app | Verification is a raw read-back the adapter returns; the *decision* is above the seam and fault-tested; manual matrix catches the rest |
| 3 | **R2**: Secure Input state at injection time | Read at injection time via the Core seam, not from the session outcome (whose reason is `.tapDisabled`) — see `understanding.md §3.4` |
| 4 | **Clipboard-manager race** | Never-clobber restore rule pinned by a racing-fake-manager test |
| 5 | **Open:** allowlist contents | S1: seed list from the matrix's known-good apps; learning is C8 |
| 6 | **Open:** does read-back verification apply to the clipboard rung? | Docs mandate it only for AX; pin that decision in the aspect spec (no verification for paste — the paste is the ⌘V itself, verified by nothing short of re-reading the field) |
| 7 | **Open:** retry (⏎) semantics when the target changed | Retry re-resolves the target at press time (`PRODUCT_SPEC.md:116`); stale-target handling is a decision-table row in the aspect spec |
| 8 | **R9** cross-check: new modules must be probe-driven or the suite fails | Probe drive is a must-have task in the plan, not an afterthought |

## 7. Out of Scope

- **Full six-state widget** (IDLE/RECORDING/TRANSCRIBING/DELIVERED/CONVERSING) — a separate
  unit; C4 lands the FAILSAFE surface only (`PRODUCT_SPEC.md:26-61`).
- **Loop wiring** (session end → ASR → cleanup → inject): follow-on unit gated on the
  `audio-capture` merge; C4 is seam-level and testable against canned strings.
- **Per-app strategy memory, adaptive settle delay** (C8, `CAPABILITY_ROADMAP.md:168-184`).
- **Latency histograms, warm start, streaming partials** (C7).
- **Context provider / selection** (C12). **Cleanup** (C5). **TTS / voice loop** (C9+).
- **Accessibility-revoked-mid-session detection** (N1) and **failsafe sound** (N2).
- Nothing in this capability touches the network, the hosted tier, or any other platform.

## 8. Non-Functional Requirements

- Test-first: every must-have acceptance is a failing test written before its code.
- Core stays import-free; strict concurrency clean (any warning fails CI);
  Apache-2.0 licence headers on every new file; per-task commits on
  `feat/injection-ladder/aliz`.
- Zero network on the default path — asserted by the interposer suite (R9), release blocker.
- Measured, not assumed: `elapsed` and settle behavior use injected clocks; nothing in the
  adapters decides.
