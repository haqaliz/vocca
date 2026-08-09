# Aspect: Failsafe surface — durable custody + the FAILSAFE window

**Aspect slug:** `failsafe-surface` · Part of `docs/planning/injection-ladder/prd.md`

## Problem slice and user outcome

The floor of I1: when every rung fails, the transcript is durably held, visibly presented,
copyable without focus, and recoverable across restarts. Outcome: the "never lose a word"
invariant ends its run in the widget failsafe exactly as `PRODUCT_SPEC.md:99-117` defines it.

## In-scope requirements

- **Recovery journal** (`VoccaInject`, one-file, no decisions — PRD R8): atomic writes under
  `~/Library/Application Support/Vocca/recovery/` (`ARCHITECTURE.md:437`); bounded (oldest
  dropped first), purged on resolution; **committed as part of the failsafe hand-off, not
  after it** (PRD R6 — closes the crash-between-exhaustion-and-journal window). A new
  one-file seam lint confines `FileManager`/the path to this file.
- **FAILSAFE window** (`VoccaUI`, PRD R7): non-activating `NSPanel` (`.nonactivatingPanel`),
  shown on demand, never takes focus (`PRODUCT_SPEC.md:22`); selectable text, long
  transcripts scroll, never auto-dismisses (`:99-105`); cause-specific reason in plain
  language — `.secureInput`: "This looks like a password field. Vocca won't type into it —
  press ⌘C to paste it yourself." (`:111`); `.exhausted`: "Couldn't type into {app}. Press
  ⌘C to paste it manually, or ⏎ to try again." (`:112`); `.noFocusedField`: "Nothing was
  focused. Click where you want this, then press ⏎." (`:113`); ⌘C/⏎/✕ via the panel's
  key-equivalent path (copies without taking focus); retry re-runs the ladder against
  current focus (`:116`); relaunch reloads unresolved transcripts with a captured-at note
  (`:117`).
- **Core-owned custody seam** (from the injector-seam aspect's `HeldTranscript`): the
  window consumes it; the journal adapter and the window are both implementations of the
  same hand-off contract.
- **`SMOKE_CHECKLIST.md` additions** (PRD R10): real-app matrix steps (native AppKit:
  Notes/Mail/TextEdit; Electron: VS Code/Slack; browsers: Safari/Chrome + Google Docs;
  terminals: Terminal/iTerm2/Ghostty; IntelliJ; hostile: Secure Input field, 1Password —
  `ROADMAP.md:91`), clipboard-manager coexistence (Raycast/Alfred/Paste/Maccy), Secure Input
  failsafe gestures, failsafe copy-without-focus, journal-restart recovery.

## Out-of-scope boundaries

- No IDLE/RECORDING/TRANSCRIBING/DELIVERED/CONVERSING states — the full six-state widget is
  a separate unit (`PRODUCT_SPEC.md:26-61`).
- No loop wiring; no per-app memory; no adaptive settle; no accessibility-revoked-mid-session
  observer (N1, enum case reserved).
- No failsafe sound (N2), no onboarding/settings surfaces.

## Acceptance criteria (written first)

- A1: Journal: write → reload (launch-equivalent) → text present; resolve → purged; bound
  enforced (oldest dropped first); write is atomic (no partial files on simulated crash —
  temp-file + rename).
- A2: **Journal-atomicity**: after the failsafe path returns, the journal file exists —
  the durability ordering is asserted, not assumed (PRD R6).
- A3: Copy path: held text lands on the pasteboard via the window's ⌘C path — testable
  in-process (NSPasteboard works headless).
- A4: Retry: the retry action re-runs the ladder against a re-resolved target (fresh
  `TargetContext`), asserted over injected handles and a stale-target decision-table row.
- A5: The window's state machine (idle → holding → dismissed/retried) is tested over the
  Core seam with no AppKit in the test (the `ModelDownloadSession` pattern).
- A6: The new FileManager one-file lint is two-sided pinned; zero-network suite stays green.
- A7: SMOKE_CHECKLIST additions present and cross-referenced from the matrix gate
  (`ROADMAP.md:95`).

## Dependencies and sequencing

After `injection-adapters` (the rungs the retry re-runs exist; `VoccaInject` is an adapter
module so the journal file can live there). Consumes the `HeldTranscript` seam from
`injector-seam`.

## Open questions / risks

- The non-activating panel's key-equivalent handling is the piece CI cannot touch (window
  server); the decision logic is all above the seam, and the copy path is pasteboard-tested
  in-process — the panel chrome is a smoke step.
- Journal location/format is fixed by the aspect; migration concerns are nil (greenfield —
  nothing exists to migrate).
- Whether retry needs its own bounded retry-count policy (a user hammering ⏎ against a
  dead field): decision-table row in A4 — exhaustion per attempt, failsafe persists.
