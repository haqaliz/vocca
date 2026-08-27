# PRD — First-run + permissions onboarding (P0)

Phase: **P0** (core dictation loop — milestone 1 "Skeleton + permissions",
`docs/ROADMAP.md:80`). Slug: `first-run-permissions`. Unit of work:
`feat/first-run-permissions/aliz` (no GitHub issue; inline brief in
`docs/planning/_card/issue.md`).

## Problem Statement

A fresh Vocca install meets three silent gates (`CLAUDE.md:536`, design-pass record): no
Accessibility grant means the event tap never exists (`CGEvent.tapCreate` returns `nil`,
`ARCHITECTURE.md:603`); no Microphone grant presents as a broken mic rather than a
permission problem (`ARCHITECTURE.md:83`); and the `LSUIElement` launch makes a failed
launch indistinguishable from a working one. The app is fully wired behind those gates —
the loop, the ladder, the widget, the settings window — but nothing ever tells the user to
open them. The P0 success signal "cold install on a clean Mac reaches 'ready' in under 60
seconds" (`ROADMAP.md:80`) is unreachable, and with it the P0 gate (7 days of daily use,
`ROADMAP.md:100`). The design pass named this the highest-value unbuilt surface
(`CLAUDE.md:530-536`).

The flow is already specified: `PRODUCT_SPEC.md:207-244` (§6 First run) defines five steps
(WELCOME → PERMISSIONS → MODEL → TRY IT → DONE), the denial-never-a-dead-end doctrine, and
the Accessibility-fatal `[Restart Vocca]` path; `ARCHITECTURE.md:589-608` (§13) defines the
permissions matrix, the two-not-three doctrine, and the tap-recreation requirement. This
capability builds that surface.

## Goals & Success Metrics

| # | Goal | Metric | Source |
|---|------|--------|--------|
| G1 | Cold install reaches "ready" | **< 60 s** from first launch to the DONE step | `ROADMAP.md:80` (strict; §6's "two minutes" is the P5 restatement) |
| G2 | No silent gate | Every permission state (granted, denied, revoked, pending) has visible, honest copy; zero states with no explanation | `PRODUCT_SPEC.md:244`, `ARCHITECTURE.md:603` |
| G3 | Copy fidelity | PERMISSIONS/MODEL/TRY IT/DONE copy pinned byte-for-byte against `PRODUCT_SPEC.md:211-244` | the `BadgeCopy` precedent (`BadgeCopyTests`, `BadgeCopy.swift:17-21`) |
| G4 | Zero-network invariant holds | The onboarding path makes no network calls; the MODEL download is user-initiated only; the default-configuration probe stays green | `ROADMAP.md:139`, zero-network probe |
| G5 | Completion is real | "Onboarding complete" requires a successful TRY IT dictation (real session, real transcript into the window's field) | `PRODUCT_SPEC.md:239` |
| G6 | Transcript-loss invariant untouched | 0% loss; no new path can swallow a transcript | `ROADMAP.md:25,96` |

## User Personas & Scenarios

- **Fresh install, non-technical user** (P5 onboarding target): launches Vocca, meets the
  five steps, grants both permissions one at a time with plain reasons and direct
  settings-pane buttons, skips or waits on the model, says something into TRY IT, sees
  their words land in the field, reaches DONE. No terminal, no config file, no account
  (`PRODUCT_SPEC.md:209`).
- **Fresh install, privacy-conscious user**: the copy says what Vocca does and doesn't do
  ("Audio never leaves this Mac", "Everything runs on your Mac"); denial is never a dead
  end — the mic-denied screen names the exact toggle; the Accessibility screen states
  plainly that without it the hotkey cannot work and offers `[Restart Vocca]`.
- **Reinstall / revoked user**: the window re-shows at launch until completion
  (decided: persisted flag, re-shows until done); the menu bar offers a way back in after
  completion.

## Requirements

### Must-have

**M1 — Five-step flow** (`PRODUCT_SPEC.md:211-242`). WELCOME (title copy + [Get
started]) → PERMISSIONS (Accessibility then Microphone, one at a time, each with plain
reason, live ✓/✗, and a direct button to the exact System Settings pane; the two pane
paths already exist privately at `AppBootstrap.swift:441-446`) → MODEL ("Downloading the
speech model (≈600 MB, one time)": progress, resumable, cancellable, "Skip for now",
reusing the shipped `ModelDownloadSession`/`DownloadState`/`DownloadWindow` machinery,
which today has no caller) → TRY IT (live text field in the window itself; "Hold ⌥Space
and say something") → DONE ("Vocca lives in your menu bar. Hold ⌥Space anywhere.").

**M2 — Denial is never a dead end** (`PRODUCT_SPEC.md:244`). Every denial screen
explains what still works without it and how to grant it later. Microphone denied: the
window says exactly which toggle to flip (button opens `Privacy_Microphone` pane) and the
flow continues. Accessibility denied: stated plainly as the one fatal permission, with a
`[Restart Vocca]` button.

**M3 — Restart works** (decided: quit + auto-relaunch). `[Restart Vocca]` terminates the
app and relaunches it, so the freshly-granted process creates its tap with a live mask
(`ARCHITECTURE.md:604`: a mask cleared at creation cannot be re-enabled). The relaunch is
a one-file adapter behind a seam (terminate + `NSWorkspace`/`launchApplication` family —
new surface, no precedent in Sources; must not be executed by CI, tap-adapter precedent).
Only shown on the Accessibility path.

**M4 — Completion flag, persisted, re-shows until done** (decided). "Onboarding complete"
= TRY IT success, written to a small persisted store. The window auto-shows at launch
until the flag is set; after completion it is reachable from the menu bar (a "Welcome…"
reopen item). The read must be synchronous for the `main()` decision (window-server rule:
`main()` shows, `configure` never constructs a window; `AppBootstrap.swift:388-430`).
Persistence: no `UserDefaults` exists anywhere today; the repo idiom is JSON behind
one-file FileManager seams pinned at exactly three rows
(`InjectionSeamBoundaryTests.swift:1288-1295`). Decision: a **UserDefaults-backed
one-file seam** for this scalar flag (synchronous by nature; new seam family = a
deliberate, reviewed table amendment — the lints are designed for amendment), with the
fourth FileManager row as the fallback if the plan finds a reason to prefer it.

**M5 — Live ✓/✗ on permissions**. Accessibility: status read + the existing
`com.apple.accessibility.api` grant-change signal (`TapHealthTimer.accessibilityGrantChanged()`,
`Sources/VoccaHotkey/TapHealthTimer.swift:166-168`) drives the ✓/✗ and the
grant-received transition. Microphone: authorization-status read (the read surface does
not exist in Sources today — no `AVCaptureDevice.authorizationStatus`/`AVAudioApplication`
anywhere; new adapter). Both reads are adapters behind injected seams; the flow's
decisions live above the seams and are fully headless-tested.

**M5b — The flow presents the prompts itself.** Each PERMISSIONS sub-step calls the
system request (`AVCaptureDevice.requestAccess(for: .audio)`; Accessibility has no
request API — the pane button is its prompt, per `ARCHITECTURE.md:603`), so the TCC
prompt lands at the moment we control — the C1 PRD M26 precedent
(`audio-capture-hotkey/prd.md:201-203`) — one at a time, never a wall of dialogs
(`ARCHITECTURE.md:589`).

**M5c — "Granted but not armed" is its own state.** The tap is created at launch with
whatever mask the grant allows; a grant arriving afterwards flips the live ✓ while the
existing tap stays deaf until re-creation (`ARCHITECTURE.md:604`). The PERMISSIONS screen
must therefore render Accessibility as three distinct, explained states — *not granted* /
*granted, restart to arm* / *armed* — with the restart path (M3) attached to the middle
one. A ✓ that hides a dead tap is the silent gate this capability exists to kill.

**M6 — TRY IT is a real dictation** (decided: dedicated onboarding target). TRY IT runs a
real session through the composed pipeline whose final transcript is delivered into the
onboarding window's own text field — not through the system-wide ladder (the AX allowlist
is seeded with three apps, not Vocca). "Success here = onboarding complete"
(`PRODUCT_SPEC.md:239`). The transcript delivery path is a seam (the
`JournalTranscriptHolder` handoff shape) so the headless suite can drive a full
dictation → field cycle.

**M7 — TRY IT without a model is honest** (decided, closes `PRODUCT_SPEC.md:349` open
question 4). When the MODEL step was skipped and no model is installed, TRY IT shows the
pipeline's `.modelUnavailable` state with a [Download now] affordance and a way forward;
the flow still reaches DONE. Never a dead end; never an auto-download (the "Skip for now
… never blocks the whole product" rule, `PRODUCT_SPEC.md:233-235`).

**M8 — Headless state machine** (the capability's acceptance spine). A Core-owned
pure reducer over injected permission-status reads covers the closed decision table: both
granted; each denied (both denial screens); revoked mid-flow; grant arriving mid-flow
(✓/✗ flip, and the Accessibility three-state *not granted / granted-restart-to-arm /
armed* transition of M5c); model present/absent/skipped/downloading/failed; TRY IT
success and failure; restart offered only on the Accessibility path; DONE reachable only
after TRY IT success. Copy pinned byte-for-byte against §6. Test floor 1114 raised in the
same commit (`Scripts/test-with-floor.sh:1036`).

**M9 — Probe stays green.** Onboarding is never constructed by `configure` (window-server
object); the default-configuration probe (`PROBE-BOOTSTRAP`…`PROBE-CYCLE`) is unchanged;
the MODEL download is never on a CI-triggerable path. The zero-network invariant
(`ZeroNetworkTests`) keeps passing.

**M10 — Smoke rows.** `docs/SMOKE_CHECKLIST.md` gains the real-machine rows: fresh-install
onboarding run (steps 5-10 are the existing permission rows), grant → restart → dictate,
skip-model → TRY IT unavailable state, menu-bar reopen after completion.

### Should-have

**S1 — Mid-flow grant recovery.** When the user grants Accessibility and returns to the
window without restarting, the window's ✓/✗ reflects it via the grant-change signal
(M5) — the restart button remains the spec'd path to a working tap
(`PRODUCT_SPEC.md:244`).

**S2 — Window placement/behavior.** Onboarding is the second focus-taking window: it
follows the `SettingsWindow` activation-policy dance exactly (`.regular` on show,
`.accessory` on close, `SettingsWindow.swift:47-76`), and every close path returns to
`.accessory` (SMOKE_CHECKLIST step 80's load-bearing row).

**S3 — Mid-flow close resumes at the first incomplete step.** Closing the window on any
step leaves the completion flag unset; the next launch re-shows the window and the flow
resumes at the first step whose precondition is unmet — derived deterministically from the
permission-status reads and the model-presence read, never from extra persisted step
state.

### Nice-to-have

**N1 — Accessibility status visible in Settings** (§7 has no permission surface today;
net-new, defer unless the window work makes it free).

## Technical Considerations

- **Layer mapping** (ARCHITECTURE.md:75-98): reducer vocabulary in `VoccaCore`
  (stdlib-only — no Foundation, pinned by `CoreBoundaryTests`); permission-status reads
  and the relaunch in adapter modules, each one file per seam (H7 shape) with reviewed
  seam-table amendments where a family is new; window + store in `VoccaUI`; wiring in
  `VoccaBootstrap` (lazy root property, the `settingsWindow` shape at
  `AppBootstrap.swift:731-757`).
- **New seam rows needed (all deliberate, reviewed amendments to
  `InjectionSeamBoundaryTests`/`ModuleBoundaryTests`)**: completion flag (UserDefaults
  family); microphone authorization status (AVFoundation is confined to two `VoccaAudio`
  files today — either the read lives in the existing capture file or a third file gets a
  reviewed row); relaunch (AppKit family); Accessibility status read (ApplicationServices
  — may land in the existing `AXSource.swift` file to keep that seam's count at one, or a
  reviewed new row). The two pane URLs already exist (`AppBootstrap.swift:441-446`) — lift
  them into the seam rather than duplicating.
- **MODEL step** reuses the uncalled shipped machinery: `StoreModelDownloadSession`
  (`AppBootstrap.swift:196-207`), `DownloadState.skipped` terminal
  (`Sources/VoccaUI/DownloadState.swift:21-51`), `DownloadWindow.present` (no caller
  today), `ModelStore.isPresent` for the installed check, `ShippedModelManifest`.
- **TRY IT target**: a dedicated onboarding transcript sink, not the ladder; the real
  session/engine/pipeline with only the delivery end swapped. Readiness gate
  (`DictationEngineResolver`) already refuses `.modelUnavailable` before the mic opens —
  M7 surfaces that state.
- **Restart**: terminate + relaunch; must not loop, must not be on a CI path; the
  relaunch adapter is translation only.
- **Concurrency**: onboarding state lives in a `@MainActor` store like `WidgetStateStore`;
  the reducer itself is a pure function over a closed action set, the house pattern
  (MenuBar/EnginePicker/Failsafe/DownloadState reducers).

## Risks & Open Questions

| # | Risk / Question | Mitigation / Decision |
|---|-----------------|-----------------------|
| R1 | The three silent gates stay silent in a path we didn't cover (e.g. Settings-pane navigation returns to a stale window) | Live ✓/✗ via injected status reads + grant-change signal; every state has copy (G2); smoke rows cover the real TCC paths |
| R2 | Restart is invisible when it fails (an `LSUIElement` quit is silent — the local-dev-launch defect class) | Relaunch adapter verified on the founder machine; smoke row: grant → restart → dictate |
| R3 | TRY IT's field receives the transcript via a path that diverges from the shipped loop and quietly breaks | Dedicated sink is a seam with headless full-cycle tests; the real cycle is smoke step 62-68 plus the new onboarding rows |
| R4 | The completion flag drifts from the spec's definition (TRY IT success) | M4 pins it; reducer tests assert no other transition sets it |
| R5 | Copy drifts from §6 | Byte-for-byte pinning tests (G3, the `BadgeCopy` rule) |
| R6 | New adapter files trip seam lints | Amendment is planned, not discovered: each new family named above gets its reviewed table edit in the same commit |
| R7 | "Under 60 seconds" is aspirational on a slow network for the MODEL step | The step is skippable and resumable; the 60 s target measures the *flow to DONE*, which skip makes achievable (G1, `ROADMAP.md:80`) |
| R8 | Stale `ROADMAP.md:308` risk R9 still names Input Monitoring | This PRD's risk table must not repeat it; the doctrine is `ARCHITECTURE.md:597-599` (Accessibility covers hotkey + typing; two permissions, not three) |
| R9 | The `_card/understanding.md` staleness (it held llm-cleanup content) | Replaced by this capability's understanding note; llm-cleanup's real home is `docs/planning/llm-cleanup/` |
| R10 | **The stale-tap trap**: a ✓-visible Accessibility grant with a dead tap re-creates the silent gate | M5c renders "granted but not armed" as its own explained state with the restart path attached; headless tests cover all three states and the grant-arrives-mid-flow transition |
| R11 | The 60 s target silently excludes a real MODEL download on a slow network | The step is skippable and resumable; the target measures flow-to-DONE, and the MODEL step's honest progress is its own metric (R7) |

## Out of Scope

- Cleanup/Speech settings surfaces (the read-only tabs stay read-only; the cleanup
  provider stays `cleanup-config.json`).
- Hotkey rebinding, sounds, launch-at-login (§7 General breadth).
- The permission-status display in Settings (§7 — N1, deferred).
- CONVERSING mode, VAD/endpointing, TTS (P3).
- Anything cloud in the OSS core (none is suggested; the BYOK/BYOK-egress story is
  untouched). macOS-only.

## Aspect decomposition (proposed — confirm at review gate)

| # | Aspect | Boundary | Depends on |
|---|--------|----------|-----------|
| A1 | `flow-reducer` | Core vocabulary + `OnboardingState`/`OnboardingAction`/reducer + `OnboardingCopy` (pinned to §6) + headless table tests | — |
| A2 | `permission-reads` | Status-read adapters (Accessibility, Microphone) behind injected seams + pane-opener lift + relaunch adapter; seam-table amendments; adapter tests over fakes; executed by nothing in CI | A1 |
| A3 | `completion-store` | Persisted completion flag (UserDefaults-backed one-file seam), synchronous read, write-on-success, tests | A1 |
| A4 | `try-it-target` | Dedicated onboarding transcript sink: real cycle → window field; model-unavailable state (M7); headless full-cycle tests | A1, A2 |
| A5 | `onboarding-window` | Five-step window (focus policy, TRY IT field, MODEL via shipped download machinery), root wiring (lazy, settings-window shape), `main()` auto-show until complete, menu-bar reopen item | A1–A4 |
| A6 | `smoke-checklist` | SMOKE_CHECKLIST rows: fresh-install onboarding, grant → restart → dictate, skip-model → unavailable, reopen | A5 |

Build order A1 → (A2 ∥ A3) → A4 → A5 → A6, each raising the test floor in its commit.