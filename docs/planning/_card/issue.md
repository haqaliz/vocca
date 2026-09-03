# Card: feat/release-distribution

> Inline brief — no GitHub issue exists. Source: `vocca-next` handoff, 2026-09-03.

## Brief

First real, installable Vocca release — the runbook's non-gated half, per
`docs/planning/notarization/runbook.md` and the `release-packaging` unit's recorded gaps
(`docs/STATUS.md:890-934`). The DMG mechanism and its symlink gate landed 2026-08-28 but have
never run against Vocca's own bundle (`release.yml` fires only on a `v*` tag; no tag pushed
since). The cask ships placeholder `version`/`sha256` and nothing has ever been installed from
the tap. The Apple Developer Program is **not bought yet** — the notarization half of the
runbook (Developer ID, `notarize.sh`, Gatekeeper-clean distribution) is recorded as blocked
pending the $99 purchase, exactly as the runbook's own status line frames it.

Prerequisites: an Apple Development signature exists (measured at
`runbook.md:14-25` — hardened runtime on, secure timestamp, `LSUIElement` app, mic
entitlement only), `Scripts/sign.sh` and `Scripts/notarize.sh` exist, the DMG packaging
step exists in the release workflow, and `homebrew/vocca.rb` is the cask source of truth
with `haqaliz/homebrew-vocca` the tap.

Acceptance:

- A real DMG is built from Vocca's own bundle on a `v*` tag: the packaging step runs
  against the real app, mounts the DMG it built, asserts `Versions/Current` is still a
  symlink, and `codesign --verify` passes on the mounted app — the gate
  `STATUS.md:901-905` says exists but has never executed.
- The cask's placeholder `version`/`sha256` are replaced with the real DMG's values and
  `brew install` from the tap succeeds on a clean install path; `zap` paths are checked
  against the app's real Application Support surface.
- Every runbook step that does not require the paid program is executed and recorded
  with its verification gate; every step that requires Developer ID is recorded as
  **blocked — not purchased** rather than skipped silently.
- Suite floor 1755 never drops (`Scripts/test-with-floor.sh`).
- `docs/STATUS.md` gains the unit's entry; `CLAUDE.md` and `SMOKE_CHECKLIST.md` are synced
  where the release state they describe changes.

Caveat: this is a release/execution unit, not a feature build — the founder's machine is
the target, and the riskiest discovery of the previous packaging unit (the symlink-following
`zip -r` defect that shipped an uninstallable v0.1.0) says the real-bundle execution may
surface defects CI cannot catch. The notarization half stays recorded-not-executed until
the $99 purchase; nothing here claims Gatekeeper-clean distribution. No gate passes as a
result of this unit (the P2 gate's third leg, ≥5 external users, is untouched).