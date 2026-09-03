# PRD: release-distribution

**Unit:** `release-distribution` · **Branch:** `feat/release-distribution/aliz` · **Phase:** P5 (reach — distribution), unblocking the P2 gate's third leg · **Date:** 2026-09-03

> Inline brief only (no GitHub issue) — see `docs/planning/_card/issue.md`. Template shape: the
> landed `injection-matrix-record` unit. Execution unit, not a feature build: the founder's
> machine and the GitHub release surface are the targets; code changes only where a
> first-execution defect surfaces or a claim needs correcting. The notarization half is
> **recorded as blocked** — the Apple Developer Program is not purchased
> (`docs/planning/notarization/runbook.md:1-5`); nothing here claims Gatekeeper-clean
> distribution.

## Problem Statement

The product has **no installable release**. `v0.1.0` shipped a `zip -r` archive that cannot
launch on any Mac — the symlink-following defect that flattened `whisper.framework`
(`STATUS.md:890-905`) — and the DMG mechanism that replaced it has **never run against
Vocca's own bundle**: "The DMG has never been built. The packaging step and its symlink gate
have not run — `release.yml` fires only on a `v*` tag, and no tag has been pushed since"
(`STATUS.md:928-930`). The cask ships placeholder `version`/`sha256` and must not reach the
tap until a DMG release exists (`homebrew/vocca.rb:10-14`); nothing has ever been installed
from the tap (`STATUS.md:931-933`).

Meanwhile the release surfaces carry claims that are **stale against the tree**: the release
notes heredoc says "This build has not been proven to dictate … latency and injection success
are unmeasured" (`release.yml:244-246`), and the README status/install callouts say "never
been run on a real machine" (`README.md:56-58, 74-76`) — both contradicted by
`p2-gate-measurement`'s first real dictations delivered with the loop's invariants holding
(`STATUS.md:162-170`). A release that ships those sentences ships claims the repo itself has
already retracted.

The notarization half is blocked on the $99 Developer Program (not bought; the existing
certificate is Apple Development, measured at `runbook.md:14-25`). The runbook is explicit
that its steps are the day-the-program-is-bought play (`runbook.md:1-5`). This unit executes
every step that does **not** require it, and records every step that does as **blocked —
not purchased** rather than skipped silently.

## Goals & Success Metrics

- **G1 — First installable release.** `v0.2.0` DMG built from Vocca's own bundle on a `v*`
  tag: the packaging step mounts the DMG it built, asserts `Versions/Current` is still a
  symlink, runs `codesign --verify --deep --strict` on the mounted app (`release.yml:197-204`),
  and the artifact + `SHA256SUMS.txt` land on the GitHub Release. Tag version == bundle
  `CFBundleShortVersionString` (the workflow's own gate, `release.yml:134-144`).
- **G2 — Real cask.** `homebrew/vocca.rb` filled with the real version + sha256 from the
  release's `SHA256SUMS.txt`; `Casks/vocca.rb` published to `haqaliz/homebrew-vocca`;
  `brew install --cask haqaliz/vocca/vocca` executed on the founder's machine with the
  quarantine step (still required — unnotarized), app launches, `pgrep -x Vocca` returns a
  pid. `zap` paths checked against the app's real Application Support surface.
- **G3 — Claims corrected to match the tree.** Release notes, README install/status callouts,
  and the checklist's release rows say what is actually true: the loop has delivered on a real
  machine; the matrix/latency-gate numbers and notarization remain unmeasured/blocked. No
  sentence ships that the repo's own honesty block has retracted.
- **G4 — Runbook dispositioned.** Every non-gated step of `runbook.md` executed with its
  verification gate recorded; every Developer-ID-gated step recorded as **blocked — not
  purchased** with the runbook's own gate text; the Step-6 bundle-id question answered by the
  founder (the last cheap moment to change `dev.vocca.Vocca`).
- **G5 — No regressions, no overclaim.** Suite floor 1755 never drops
  (`Scripts/test-with-floor.sh`); any fix lands test-first; no gate is claimed (the P2 gate's
  third leg — ≥5 external users — is enabled by this release, not passed by it).

## User Personas & Scenarios

- **The first-time user.** Lands on the GitHub release (or `brew install`) after a launch
  post. Must be able to install without a Terminal archaeology session, must not be told the
  app "has not been proven to dictate", and must get the honest quarantine step — exactly
  once — because launching a quarantined app **deletes** it silently (`homebrew/vocca.rb:23-26`).
- **The founder.** Executes the runbook steps and records the disposition. The unit's
  deliverable is a release he can point people at, plus a runbook status that says which
  steps remain and why.
- **The P2 gate.** The consumer of the third leg (≥5 external users, `ROADMAP.md:180`). This
  unit produces the install path that leg depends on; it does not claim the leg.

## Requirements

### Must-have

- **M1 — Version bump to 0.2.0.** `App/Info.plist` `CFBundleShortVersionString` +
  `MARKETING_VERSION` in both `Vocca.xcodeproj` configurations (currently 0.1.0 at
  `project.pbxproj:298,330`), tag `v0.2.0` pushed so the workflow's tag==bundle gate is the
  first real execution of the match check.
- **M2 — First real-bundle release execution.** Push `v0.2.0`; `release.yml` runs the suite
  (floor), builds Release, signs with the imported Apple Development identity, verifies the
  tag, runs the suite against the signed bundle, packages the DMG, mounts it, symlink-gates,
  `codesign --verify`s, creates the GitHub Release. Every step's outcome recorded. A
  first-execution defect (v0.1.0 precedent: the packaging step had never run and shipped
  broken) is fixed test-first and the run re-executed — never shipped broken because the tag
  is out.
- **M3 — Cask ship.** Fill `version` + `sha256` from the release's `SHA256SUMS.txt`; verify
  `zap` paths against the real Application Support surface; `brew style --cask` and
  `brew audit --cask` clean locally; push `Casks/vocca.rb` to `haqaliz/homebrew-vocca`;
  `brew install --cask haqaliz/vocca/vocca` on the founder's machine; `xattr` first-launch
  sequence; `pgrep -x Vocca` returns a pid; launch confirmed via the menu bar item (not the
  absence of a dialog — `runbook.md:263-265`).
- **M4 — Stale-claim correction in the shipped surfaces.** `release.yml` notes heredoc
  (`release.yml:244-246`), `README.md` status + install callouts (`README.md:56-58, 74-76`),
  and the cask caveats reworded to the measured truth (loop proven on the founder's machine;
  matrix/latency-gate numbers and notarization still unmeasured/blocked). `SMOKE_CHECKLIST.md`
  steps 60-61 stay true as written — `notarize.sh` genuinely has never run end-to-end.
- **M5 — Cask-version drift guard (test-first).** A CI test asserting
  `homebrew/vocca.rb`'s `version` equals the bundle's `CFBundleShortVersionString` — the
  same class of guard as the workflow's tag==bundle check (`release.yml:134-144`), headless
  (no Homebrew needed), so a release can never ship a cask pointing at another version or a
  placeholder. Written before the version bump lands (RED on `0.0.0-PLACEHOLDER`).
- **M6 — Runbook disposition + record-and-sync.** `runbook.md`'s "Status as of v0.1.0"
  section replaced with the v0.2.0 state; every blocked step named **blocked — not
  purchased**; `docs/STATUS.md` entry with the house honesty block ("What this unit is NOT,
  and must not be claimed:"); `CLAUDE.md` front-door sync; test floor re-recorded.

### Should-have

- **S1 — v0.1.0 broken-artifact disposition.** The GitHub release still hosts the
  uninstallable zip. Either delete the asset + rewrite its notes to point at v0.2.0, or
  mark it deprecated — a broken artifact is the first thing a `releases/latest` visitor
  finds. Founder decision (OQ2).
- **S2 — Cask install verification beyond the founder's machine.** If a second Mac is
  reachable, the runbook's "machine that has never built Vocca" check (`runbook.md:239-265`)
  runs against the unnotarized DMG: mount, drag, `xattr`, launch, `spctl` output recorded
  (expected: `rejected` — the recorded baseline the notarized release will be measured
  against).

### Nice-to-have

- **N1 — `SPARKLE_*` seams untouched.** Nothing for Step 8; only the note that Sparkle stays
  "then, and only then" (`runbook.md:318-330`).

## Technical Considerations

- **What executes where.** The workflow steps (M1/M2) run in GitHub Actions on tag push; the
  cask (M3) is a local + tap-repo operation; the claim fixes (M4) are local commits in this
  repo; the guard (M5) is a headless test in `Tests/HarnessTests/` following
  `BundleConfigurationTests`'s bundle-contract pattern. Sequencing: M5 (guard, RED) → M1
  (bump, GREEN) → M2 (tag + run) → M3 (cask) → M4/M6 (claims + records). M2 and M3 depend
  on each other in that order — the cask's sha256 comes from the M2 artifact.
- **What the release does NOT need from the paid program.** The Apple Development signature
  is measured (`runbook.md:14-25`): hardened runtime on, real secure timestamp, mic
  entitlement only, no provisioning profile — so the DMG, its symlink gate, and
  `codesign --verify` all run today. The release stays unnotarized and honest about it; the
  runbook's Step-7 cleanup stays unexecuted until the Developer ID lands.
- **Test-first surface.** M5 is the only new code and is strictly RED→GREEN. M4's claim fixes
  are prose, pinned where the repo already pins (no test changes expected — the floor stays
  1755 unless a defect fix adds one). Any first-execution defect found by M2/M3 lands the
  same way: test first, then fix.
- **Privacy/security.** No new entitlements (`BundleConfigurationTests` asserts the
  checked-in set; the release must never carry `get-task-allow` or
  `disable-library-validation` — `runbook.md:142-147`). No new egress: the release workflow
  already runs the zero-network suite as its gate (`release.yml:106-109`).
- **Rough sizing (feasibility signal):** M5 is a small headless test; M1/M4/M6 are
  mechanical edits; M2 is founder/CI machine-time (one tag push + one workflow run, ~40-min
  timeout, `release.yml:65`); M3 is founder machine-time. The execution-riskiest step is M2 —
  the same step that shipped v0.1.0 broken.

## Risks & Open Questions

- **R1 — The real-bundle execution surfaces a defect CI cannot catch.** The v0.1.0 precedent
  is exact: the packaging step had never run and shipped a bundle that cannot launch on any
  Mac (`STATUS.md:890-905`). Stopping rule: the defect is fixed test-first and the run
  re-executed; a broken artifact is never published because the tag is already out — the
  workflow's own rule ("A tag run that ends green must have produced a release",
  `release.yml:27-30`) extends to "a release that ends broken is retracted".
- **R2 — Cask install fails for environment reasons.** Tap repo state (currently a README
  and no cask, `STATUS.md:931-933`), Homebrew version drift (the `--no-quarantine` removal
  precedent, `homebrew/vocca.rb:20-22`), or a quarantine-deleted install. Recorded with the
  exact error, never silently worked around; the cask's honesty about the quarantine step
  stays until notarization lands.
- **R3 — The GitHub token/scope reality.** `release.yml` uses `permissions: contents: write`
  (`release.yml:55-56`); a tag push from a fork or a token without that scope fails at the
  Release step. Recorded as an environment outcome, not a code fix.
- **OQ1 — `vocca.dev` ownership (runbook step 6).** Unverified here. If the domain is not
  owned, changing `dev.vocca.Vocca` now is the last cheap moment — afterwards it costs every
  user's TCC grants again (`runbook.md:296-300`). Founder decision at the review gate.
- **OQ2 — v0.1.0 asset disposition (S1).** Delete the broken asset + point notes at v0.2.0,
  or leave it as history? Recommended: delete + point — `releases/latest` is the first
  impression a launch post makes.
- **OQ3 — Version number.** `v0.2.0` proposed (first installable release; the broken v0.1.0
  stays history). Confirm.

## Out of Scope

- **Notarization, Developer ID, and the paid program** (blocked — not purchased; every
  runbook step 1-3, 5, 7-8 recorded as such, executed the day the program lands).
- Sparkle / auto-update (runbook step 8 — "then, and only then").
- The injection matrix run, whisper WER, F2 cleanup eval, and any phase-gate claim.
- The P2 gate's third leg (≥5 external users) — this release is its prerequisite, not its
  pass.
- Any entitlement, signing-identity, or bundle-id change beyond the version bump.
- Removing the quarantine workaround (runbook step 7 — depends on notarization).