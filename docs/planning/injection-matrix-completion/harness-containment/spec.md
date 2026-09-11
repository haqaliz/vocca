# Spec: harness-containment

> Aspect of `injection-matrix-completion` (PRD rev 2026-09-09, M6 + R1).
> **Boundary extended at plan time (2026-09-09):** this aspect also carries the harness's
> FMS-question change, because M3 (memory-ordered FMS, ratified 2026-09-09) cannot be computed
> from the run log as it stands — the landing rung is only recorded on expected-rung passes
> (`rung` is `null` on misses, and the y/N answer records no rung at all).

## Problem slice

Two harness defects stand between the unit and its deliverable:

1. **Self-capture is recordable as PASS.** The harness runs inside a terminal; for the
   Terminal/Warp rows its own scrollback holds the printed phrase, which satisfies the
   containment byte-compare (`386f433` semantics) — a pass can be recorded for a row nothing
   was injected into (`injection-matrix.sh:203-213` documents the hazard). There is no guard.
2. **The FMS question measures the wrong thing.** `run_row` asks "Did the log name `.$rung`
   [the expected rung]?" (`injection-matrix.sh:602`) and a demotion-honored delivery —
   bytes matched, ladder landed on the memory-ordered first method after `.accessibility` was
   demoted — records `failed, note: "log did not name .accessibility"`. Under the ratified
   definition (PRD M3: memory-ordered first method counts), that row is a **success**, and the
   harness currently cannot record it as one.

## In scope

- **R1a — self-capture guard (PRD R1):** a terminal-class row whose target terminal is the
  harness's own host terminal must **not proceed to the comparison half** — VOID with the
  named reason `self-capture: harness runs inside the target terminal`, logged with verdict
  `voided`. Implemented as:
  - `host_terminal_bundle_id()` — walks the parent-process chain from `$$` (bash running the
    script) up to the first ancestor whose command path contains `.app/Contents/MacOS/`,
    derives the bundle id via `plutil -extract CFBundleIdentifier` on that app's Info.plist;
    returns empty (never errors) when no terminal ancestor exists (CI, launched bare).
  - `is_self_capture <target> <host>` — pure predicate: fires only when both arguments are
    non-empty and equal (empty host is unreadable, not self-capture).
  - Wiring in `run_row`: immediately after the frontmost-aim check passes and **before** the
    sentinel copy, for terminal-class rows only: `is_self_capture` fires → VOID + return 3.
- **R1b — self-check pins (CI-safe):**
  - `is_self_capture` fires on equal non-empty ids; does not fire on differing ids, empty
    host, or empty target.
  - `host_terminal_bundle_id` output, when non-empty, is a bundle-id shape (contains a dot).
  - Wiring pin: the self-check greps the script text for the guard call site and the
    `self-capture` void message (the existing seeded-slow-injector/self-check grep pattern).
- **R1c — planted-violation tests (RED→GREEN, `InjectionMatrixHarnessTests.swift` pattern):**
  - Mutilate `is_self_capture` so it never fires → self-check must fail.
  - Remove the guard call site from `run_row` (replace with empty) → wiring grep must fail.
- **R2 — the FMS question (PRD M3, M8):** replace the y/N expected-rung question with a
  landing-rung observation:
  - Ask: "Enter the rung the ladder's log named as landing (accessibility/clipboardPaste/
    keystrokeSynthesis/none)" — founder answers from the log, the script validates against
    the closed vocabulary (answer `none` is refused for deliverable rows).
  - Ask: "Did the log's `attempted:` trace begin with that rung? [y/N]" — the first-method
    fact.
  - Verdicts: bytes false → FAIL `byte mismatch`. Landing not first-attempted → FAIL
    `delivered via fallback rung .<rung>`. Landing == expected AND first-attempted → PASS
    (calibration + FMS). Landing != expected AND first-attempted → PASS with note
    `delivered by memory-ordered first method .<rung> (expected .<expected> demoted)`
    (FMS pass, calibration miss).
  - `log_run_row` records the **observed landing rung** in the `rung` field for every
    deliverable row (null remains for skips/voids/refusals — rows where no rung was
    observed).
  - The refusal path (rung == `none`) is unchanged.
- **R3 — record surface:** the JSONL schema is unchanged (same six fields); only the `rung`
  and `note` values change meaning for misses. No run-log compatibility break: old lines stay
  valid.

## Out of scope

- No change to the byte-compare normalization (`phrase_matches`) — it is pinned and correct.
- No change to the aim/activation logic — pinned by `1985da6` tests.
- No change to the refusal-row flow (step 92) — its four conditions stand.
- No change to `strategies.json` or the Swift memory code.

## Acceptance criteria (test-first)

1. **RED:** the new planted-violation tests fail against the current script (no guard exists
   → self-check can't pass the new pins; `is_self_capture` undefined).
2. **GREEN:** all new pins + planted tests pass; the shipped script's `--self-check` passes;
   the full `Tests/HarnessTests/InjectionMatrixHarnessTests.swift` suite passes.
3. **Behavioral proof on this machine:** `host_terminal_bundle_id` returns the hosting
   terminal's real bundle id when the script runs from a terminal (checked once by hand via
   `bash -c 'source Scripts/injection-matrix.sh; host_terminal_bundle_id'` — hmm, the script
   has no such entry point; see note below), and empty in CI (XCTest Process, no terminal
   ancestor).
4. **Void proof:** running `--row Terminal` from inside Terminal.app (or `--row Warp` from
   inside Warp) yields verdict `voided`, note `self-capture: harness runs inside the target
   terminal`, exit 3 — and **never** a PASS. (Manual, founder-executed, recorded in the run
   log as a void — this is itself a matrix-row re-run artifact.)
5. Floor: `Scripts/test-with-floor.sh` still passes with the floor **never dropping below
   1930**; the executed count rises by the new tests.

## Dependencies & sequencing

- First aspect (the run depends on it: Terminal/Warp re-runs and the FMS tally need the
  guard and the landing-rung recording).
- Depends on nothing else; touches only `Scripts/injection-matrix.sh` +
  `Tests/HarnessTests/InjectionMatrixHarnessTests.swift`.

## Open questions / risks

- **Host-discovery edge (CI):** in the XCTest `Process` there is no terminal ancestor;
  `host_terminal_bundle_id` must return empty without erroring under `set -euo pipefail`.
  The shape pin covers non-empty output; a future refactor of the discovery must keep that.
- **Founder burden:** the landing-rung question adds one keystroke per row. Accepted — it is
  the minimum the ratified FMS metric needs, and it replaces (not adds to) the y/N question
  when the expected rung did not land.
- **Test-time entry point:** `host_terminal_bundle_id` is exercised by the self-check pins
  only via its shape; direct execution from a terminal is a manual check (step 3 above),
  documented in the plan.