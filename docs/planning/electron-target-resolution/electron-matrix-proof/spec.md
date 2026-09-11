# Spec: electron-matrix-proof

> Aspect of `electron-target-resolution` (PRD M1, M2, S2; the run half). Consumes the
> `resolver-fallback` code once shipped and merged.

## Problem slice

The gate is a decision over injected seams; its empirical truth — that
`NSWorkspace.shared.frontmostApplication` answers Electron apps, that the fallback's
clipboardPaste then **delivers** in them, and that the desktop case still refuses — can only
be proven on the founder's machine with the installed build. This aspect runs that proof and
records it.

## In scope

- **Preconditions:** v0.3.1 built and installed (release-distribution recipe; the bundle
  version verified via `defaults read /Applications/Vocca.app/Contents/Info
  CFBundleShortVersionString`); Vocca running, armed, model prepared; `--verify-bundle-ids`
  exits 0; `strategies.json` snapshot (no reset — memory active); harness `--self-check`
  passes (the guard + landing-rung harness are on master).
- **M1 — the 5 Electron rows:** VSCode, Teams, Discord, ChatGPT, Obsidian on the installed
  v0.3.1 build via `Scripts/injection-matrix.sh --row <name> --run-log <path>`, each with the
  founder's landing-rung answer from the log. Expected rung: `.clipboardPaste` (unseeded);
  PASS = bytes matched AND landing == first `attempted:` rung (memory-ordered FMS).
- **M2 — the desktop refusal:** with the desktop/Finder frontmost (no window), dictate →
  expect the `.noFocusedField` refusal: the failsafe shows "Nothing was focused. Click where
  you want this, then press ⏎." and the recovery journal records
  `{"reason":"noFocusedField"}`. Recorded as the gate's negative proof.
- **S2 — record:** STATUS entry (append-only), tracked-table **v0.3.1 row** (step 93),
  CLAUDE.md front-door sync, floor re-read. The record carries the second-defect posture if
  one surfaces (delivered-but-invisible in an Electron app → fix in-unit test-first per the
  PRD's pre-decided posture).

## Out of scope

- No harness changes, no row-set decisions (17/20 ceiling stands), no app installs.
- No gate claims: the 5 rows passing does not pass any gate; the FMS over 17 stays
  non-computable until the remaining unrun rows and step 92 exist.

## Acceptance criteria

1. Each of the 5 Electron rows has a run-log JSONL line with a verdict (`pass`, `failed` with
   a named reason, or `voided` with a named reason) — no row without a machine artifact.
2. The desktop refusal is recorded (journal + failsafe copy + a note), proving the genuine
   no-field state still refuses.
3. The record names the build, the date, the floor, and the exact FMS math over the rows run;
   no injection-success percentage is quoted outside the denominator discipline.

## Dependencies & sequencing

- Last aspect: needs the merged `resolver-fallback` code, a v0.3.1 build + install
  (founder), and the founder's ~5 × 30 s of dictation.

## Open questions / risks

- If the fallback resolves but Chromium's ⌘V does not paste (delivered-but-invisible), the
  unit stops on a second named defect and the PRD's pre-decided posture applies (fix in-unit,
  test-first — a new rung-level cycle).
- If a row voids (Automation grant, frontmost mismatch), re-run once after fixing the
  precondition; a second void is recorded with the reason.