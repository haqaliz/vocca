# Spec: claims-and-record

> Aspect of `release-distribution` (`docs/planning/release-distribution/prd.md`). Sources:
> PRD M4, M6, G3, G4; `release.yml:244-246`; `README.md:56-58, 74-76`;
> `docs/planning/notarization/runbook.md` (status section); `docs/STATUS.md` (house honesty
> block pattern).

## What this aspect is

Makes every release-facing claim match the measured tree, and records the unit. The
release notes still say "This build has not been proven to dictate … latency and injection
success are unmeasured" (`release.yml:244-246`) and the README says "never been run on a
real machine" (`README.md:56-58`) — both retracted by `p2-gate-measurement` (first real
dictations delivered, `STATUS.md:162-170`). This aspect rewrites those surfaces to the
measured truth, keeps the claims that are still true (`notarize.sh` genuinely never run
end-to-end — `SMOKE_CHECKLIST.md:1050-1053`), records the runbook's blocked steps as
**blocked — not purchased**, and lands the house record-and-sync (STATUS entry, CLAUDE
front-door sync, floor re-record).

## Requirements

- **M4 (claims).**
  - `release.yml` notes heredoc: replace "not proven to dictate" with the measured state —
    dictation proven on the founder's machine (SMOKE 62-68); injection matrix, latency-gate
    numbers, and notarization unmeasured/blocked. Keep the `xattr` instructions and the
    `LSUIElement` note verbatim in substance.
  - `README.md` status callouts (`:56-58`) and install callout (`:74-76`): same correction —
    "the loop has delivered on a real machine; the matrix and latency numbers are not yet
    published; notarization pending".
  - `SMOKE_CHECKLIST.md` steps 60-61: unchanged (still true) — verified, not edited.
  - Cask caveats: unchanged unless a claim is stale (checked in cask-ship Phase 1).
- **M6 (record).**
  - `runbook.md` "Status as of v0.1.0" → v0.2.0 state: what executed (DMG, cask, install
    proof, claims), what is blocked — Steps 0 (purchase), 1 (Developer ID cert), 2 (identity
    switch), 3 (notarize + staple), 5 (TCC reset tests), 7 (quarantine workaround removal),
    8 (Sparkle) — each named **blocked — not purchased** with the runbook's gate text.
  - `docs/STATUS.md`: new entry with the house honesty block ("What this unit is NOT, and
    must not be claimed:") — no gate passed, no notarization claim, matrix/latency-gate
    numbers still unmeasured.
  - `CLAUDE.md`: front-door sync (release state sentence).
  - Test floor re-recorded (expected 1756 after version-bump).

## Out of scope

Notarization claims (none — blocked), Sparkle, any gate claim, the matrix run, and the P2
gate's third leg.