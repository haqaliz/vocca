# C4 — Understanding note

Written after the Phase 2 dig over the saved card (`docs/planning/_card/issue.md`), the
authoritative docs, and the shipped code on `master`. Sources: `docs/technical/ARCHITECTURE.md`,
`docs/product/PRODUCT_SPEC.md`, `docs/ROADMAP.md`, `docs/technical/CAPABILITY_ROADMAP.md`,
`docs/SMOKE_CHECKLIST.md`, the C1/C2 planning docs, and the `Sources/` + `Tests/HarnessTests/`
code (worktree state = master @ 1ad6ee4 + the C4 card).

---

## 1. What the work is really asking

Build the second make-or-break UX battle: text that comes out of the ASR seam lands in the
focused field of any app, or — if every rung fails — is held somewhere the user can copy it.
The seam is `TextInjector` (`ARCHITECTURE.md:239-241`), the ladder has four rungs
(`ARCHITECTURE.md:398-403`), and the load-bearing guarantee is I1: **transcript loss is
exactly zero, and the widget failsafe terminates every path** (`ARCHITECTURE.md:193-199`).

The real risk is not "does paste work". It's R1 — AX reports success while inserting
nothing (`ROADMAP.md:300`) — and the clipboard-manager race on restore
(`ROADMAP.md:85`, `ARCHITECTURE.md:405-415`). The design answer is already locked:
AX only on a verified allowlist with read-back verification (success without verification
counts as failure, `ARCHITECTURE.md:400`), clipboard save→set→⌘V→settle→restore where the
restore **never clobbers a manager that took ownership** (`:412-414`), and Secure Input
short-circuits at the top of the decision function with an honest refusal
(`:382-384`, `PRODUCT_SPEC.md:111`).

## 2. Affected areas

| Area | What lands |
|---|---|
| `VoccaCore` | `TextInjector` seam, `TargetContext`, `InjectionRung`, `InjectionResult`, `VoccaError.injectionExhausted`; failsafe/custody seam consumed by `VoccaUI`; ladder decision function (pure, over injected rung handles + injected strategy order + injected clock). All import-free. |
| `VoccaInject` (new adapter module) | One-file, no-decision adapters: AX insert + read-back (`Accessibility/`), pasteboard save/set/paste/restore (`Clipboard/`), keystroke synthesis (`Ladder/` or `Keystroke/`), Secure Input read. Module moves **leaf → adapter** (`ModuleBoundaryTests.swift:72-85`, `Package.swift`). |
| `VoccaUI` | The FAILSAFE surface: persistent, non-focus-taking, selectable text, ⌘C, cause-specific reason, retry (`PRODUCT_SPEC.md:48-55, 99-117`). First real surface beyond the download window. |
| Lints | **H7 amendment** (the keystroke rung must name `CGEvent`/`CGKeyCode`, which today only `VoccaHotkey/CGEventTapSource.swift` may do, tree-wide, ≤1 file, "nothing else ever joins it" — `HotkeySeamBoundaryTests.swift:81-98, 201-209`); new H9-style seam lints confining AX/ApplicationServices, NSPasteboard/AppKit, and the Carbon Secure Input read to one file each; zero-network probe must drive the new modules (`ZeroNetworkTests.swift:311-325`); deinit-isolation rule applies to the fourth object (`DeinitIsolationTests`). |
| Docs | `ARCHITECTURE.md` (amendment record), `SMOKE_CHECKLIST.md` (real-app matrix, clipboard-manager, Secure Input failsafe steps), `CLAUDE.md` status. |

## 3. Findings that change the design

### 3.1 The keystroke rung directly conflicts with H7 — the lint must be amended
`CGEventTapSource.swift` is the one file permitted to name `CGEvent`/`CFMachPort`/
`CGKeyCode`/`CFRunLoop`, the scan is tree-wide with a `≤ 1` count assertion
(`HotkeySeamBoundaryTests.swift:201-209`). Rung 3's keystroke adapter must name at least
`CGEvent` and `CGKeyCode`, and it cannot live in `VoccaHotkey` (module boundary; and
`ARCHITECTURE.md:89-91` mandates the separation — "one reads the keyboard, one writes it").
C4 must amend H7 to a per-seam permitted-file structure (the tap adapter keeps its rule;
the keystroke adapter gains its own), with the lint pinned in both directions like every
other seam lint. This is a deliberate, reviewed edit — the same discipline as the M16/M17
amendments. **The card's caveats did not name this; it is the dig's biggest find.**

### 3.2 `TargetContext.axElement: AXElementRef?` (ARCHITECTURE.md:165) is unimplementable as written
`VoccaCore` imports nothing (`CoreBoundaryTests.swift:98-116`) and `AXElementRef` requires
ApplicationServices/CoreFoundation. The seam must either drop the AX element (resolved
inside the adapter from the bundle ID) or carry an import-free opaque handle. The adapter
module, not the Core seam, names the AX type.

### 3.3 `VoccaInject` is a leaf in the enforced lints today
`leafModules` includes it (`ModuleBoundaryTests.swift:72-74`), `Package.swift:72-76` has no
dependencies. C4 performs the reviewed leaf→adapter move exactly as `VoccaHotkey` and
`VoccaASR` did. An adapter imports `VoccaCore` **and nothing else among Vocca modules**
(`:223`) — so the ladder cannot import `VoccaUI`; the failsafe is wired through Core-owned
types, mirroring `ModelDownloadSession`.

### 3.4 Secure Input: reuse the Core seam, add one more Carbon line
C1 already shipped `SecureInputStateReader` in `VoccaCore` (faked in
`DeinitIsolationTests.swift:85`) and `SystemSecureInputState` in `VoccaHotkey`
(`SecureInput.swift:92-105`, one Carbon call, works without a grant). `VoccaInject` cannot
import `VoccaHotkey`, so it gets its own one-file adapter behind the same Core seam, under
a new one-file lint for `IsSecureEventInputEnabled`. Note the carrier gap: when Secure
Input kills a session, the end reason is `.tapDisabled` (`TapHealthPolicyTests.swift:2005-2010`),
not `.systemEvent(.secureInputEnabled)` — C4's decision of *why* the injector refuses must
come from its own read at injection time, not from the session outcome.

### 3.5 The default rung order must be pinned at C4
`strategyStore.orderedLadder(for:)` (`ARCHITECTURE.md:386-393`) is C8's per-app memory —
at C4 the store is empty, so the PRD must pin the C4 default order (AX for allowlisted
apps only, clipboard elsewhere, keystroke last, failsafe always) and the seam must accept
an injected order so C8 slots in without a rewrite.

### 3.6 The "app matrix" acceptance is not headlessly executable — seam split is the resolution
Real-app AX insertion needs TCC + real apps; the matrix is a manual gate (P0 bar ≥90%,
`ROADMAP.md:95`; `SMOKE_CHECKLIST.md` step 12 pattern). The load-bearing fault-injection
suite (each rung forced to fail, including AX's silent success-with-no-insert) runs at the
seam level over injected rung handles — the tap-adapter precedent. `SMOKE_CHECKLIST.md`
gains the real-app steps.

### 3.7 Rung 4 is `VoccaUI`'s first real surface, and the full widget does not exist yet
`VoccaUI` ships only the download window today. `PRODUCT_SPEC.md:26-61` defines all six
widget states but none are built. C4's rung 4 must land a minimal-but-real FAILSAFE
surface (persistent, selectable text, ⌘C without focus, cause-specific reason, retry, never
auto-dismisses — `PRODUCT_SPEC.md:99-117`). The full six-state widget is a separate unit;
the roadmap's week-4 milestone ("Failsafe + telemetry-free instrumentation",
`ROADMAP.md:86`) confirms failsafe is its own deliverable.

### 3.8 The zero-network probe must drive the new modules
Every module under `Sources/` must be driven by the probe's default-configuration path
(`ZeroNetworkTests.swift:311-325`); the probe references `VoccaInjectPlaceholder`
(`VoccaNetworkProbe.swift:22`). C4's plan updates the probe to run a full injection path
with injected adapters (real AX is a manual step, but the ladder, the failsafe, and the
pasteboard copy path are all probe-drivable and all local — no network is added).

### 3.9 Stale references to fix while here
`CAPABILITY_ROADMAP.md:324` says the zero-network test is "(C6)" — it shipped at C1.
`ARCHITECTURE.md` §10 (`TranscriptCustody`, :421-440) is design-only; C4 lands at least the
Core-owned failsafe/custody seam. `ARCHITECTURE.md:311` was already corrected by C1's M33.

## 4. Ambiguities and open questions

1. **Failsafe scope**: minimal FAILSAFE-only window (my lean — matches week-4 milestone and
   keeps C4 the ladder capability) vs. the full six-state widget. Ask the user.
2. **Crash-recovery journal** (`PRODUCT_SPEC.md:117`, `ARCHITECTURE.md:437`): include a
   minimal bounded recovery journal in rung 4, or defer it to the widget unit? My lean:
   include — it is what makes "never lost" survive a restart, and it is small and testable.
3. **Loop wiring**: C4's seam is testable against canned strings and the composition root
   does not exist; my lean is C4 does **not** wire session→ASR→inject (that is a
   follow-on unit once `audio-capture` merges). Confirm with the user.
4. **Accessibility-revoked-mid-session** (`PRODUCT_SPEC.md:114`): the reason enum carries
   the case; the TCC observer wiring is deferred (it maps to the tap's domain per
   `ARCHITECTURE.md:515`).
5. **Allowlist bootstrap**: ship a small hand-curated seed allowlist (top ~10 apps,
   `ARCHITECTURE.md:558`'s leaning); C8 learns the rest.

## 5. Phase and constraints

P0, week 3 (`ROADMAP.md:84`). Dependencies: C1 (the `audio-capture` merge is the
precondition per the card; the ladder itself is independent of C2/C3 — `CAPABILITY_ROADMAP.md:110`
and testable against canned strings). Retires R1 (High/Fatal) and R2 (High/Med)
(`ROADMAP.md:300-301`). Guardrail check: local-only (pasteboard/AX/CGEvent are all local),
macOS-only, dictation-first, no cloud, no crippling — clean on all six.
