# Spec: version-bump

> Aspect of `release-distribution` (`docs/planning/release-distribution/prd.md`). Sources:
> PRD M1, M2, M5; `docs/planning/notarization/runbook.md` step 6; `release.yml:134-144`.

## What this aspect is

The only code-carrying aspect of the unit: a headless drift guard that pins the cask's
version to the bundle's (test-first, RED on the placeholder), the mechanical version bump
0.1.0 → 0.2.0, and the first real-bundle release execution — tag `v0.2.0` pushed so
`release.yml` runs its packaging step against Vocca's own bundle for the first time, with
every step's outcome recorded.

## Requirements

- **M5 (guard, test-first).** A CI test in `Tests/HarnessTests/` asserting
  `homebrew/vocca.rb`'s `version` equals `App/Info.plist`'s `CFBundleShortVersionString`.
  Headless: parses both files, no Homebrew, no bundle required. RED on
  `0.0.0-PLACEHOLDER` (vs 0.1.0), GREEN after the bump.
- **M1 (bump).** `App/Info.plist` `CFBundleShortVersionString` → `0.2.0`;
  `MARKETING_VERSION` → `0.2.0` in both `Vocca.xcodeproj/project.pbxproj` configurations
  (currently `project.pbxproj:298,330`). `CFBundleVersion` left as-is unless the release
  gate demands a change (check: `release.yml` only reads `CFBundleShortVersionString`).
- **M2 (execution).** Tag `v0.2.0` pushed to `origin/master` after the PR merges; the
  workflow runs: suite (floor) → Release build → sign (imported Apple Development identity)
  → tag==bundle gate → suite against the signed bundle → DMG package → mount + symlink gate
  + `codesign --verify --deep --strict` → GitHub Release + `SHA256SUMS.txt`. Every step's
  outcome recorded with the run URL. A first-execution defect is fixed test-first and the
  run re-executed — never shipped broken.

## Out of scope

Notarization and Developer ID (blocked — not purchased); any bundle-id change (OQ1 in the
PRD — decided at the pre-tag checkpoint, and only if the founder answers); the cask
contents beyond the version line (cask-ship aspect); claim fixes in the release notes
(claims-and-record aspect — but its Phase 1 lands in the same PR, before the tag).

## Verification gates

- `./Scripts/test-with-floor.sh` green at floor 1756 (1755 + the new guard test) after the
  bump; RED before it.
- `git log` shows the guard commit before the bump commit (test-first evidence).
- The workflow run for `v0.2.0` ends green AND produced a release with a DMG +
  `SHA256SUMS.txt`; the run log is cited in `record-and-sync`.