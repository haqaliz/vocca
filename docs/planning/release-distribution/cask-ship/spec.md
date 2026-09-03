# Spec: cask-ship

> Aspect of `release-distribution` (`docs/planning/release-distribution/prd.md`). Sources:
> PRD M3, S1, S2; `homebrew/vocca.rb`; `STATUS.md:928-933`.

## What this aspect is

Turns the published v0.2.0 DMG into an installable product: fill the cask's placeholder
`version`/`sha256` from the release's `SHA256SUMS.txt`, verify the `zap` surface against the
app's real Application Support paths, publish `Casks/vocca.rb` to the `haqaliz/homebrew-vocca`
tap, and prove `brew install --cask haqaliz/vocca/vocca` on the founder's machine — with the
quarantine step intact and the launch confirmed via the menu bar item, never the absence of a
dialog (`runbook.md:263-265`). Also disposes of the broken v0.1.0 GitHub asset (S1).

## Requirements

- **M3 (cask ship).**
  - `version "0.2.0"`, `sha256 "<the release's>"` from `SHA256SUMS.txt` — the URL pattern
    `releases/download/v#{version}/Vocca-v#{version}.dmg` already matches the workflow's
    artifact name (`Vocca-${VERSION}.dmg`, `VERSION=v0.2.0`), so the URL line is unchanged.
  - `zap trash:` paths checked against reality: `~/Library/Application Support/Vocca`
    (models, `recovery/`, `strategies.json`, `dictionary.json`, `cleanup-config.json`),
    Preferences plist, Saved Application State. Correction only if a path is wrong.
  - The `DO NOT PUBLISH THIS TO THE TAP YET` header block (`homebrew/vocca.rb:10-14`) is
    replaced by the ship record (version, sha256, date, release URL).
  - Published to `haqaliz/homebrew-vocca` as `Casks/vocca.rb` (the tap is the mirror; the
    repo's `homebrew/vocca.rb` stays the source of truth).
  - `brew install --cask haqaliz/vocca/vocca` on the founder's machine: install → `xattr -dr
    com.apple.quarantine /Applications/Vocca.app` → `open` → menu bar item present →
    `pgrep -x Vocca` returns a pid. The quarantine caveats stay (still unnotarized).
- **S1 (v0.1.0 disposition).** The GitHub `v0.1.0` release hosts the uninstallable zip.
  Recommended (PRD OQ2, approved): delete the broken asset and rewrite its notes to say the
  release is superseded by v0.2.0. Recorded regardless of choice.
- **S2 (second Mac).** If a second Mac that has never built Vocca is reachable: mount the
  DMG, drag, `xattr`, launch, `pgrep`; record `spctl -a -vvv -t exec` output — expected
  `rejected` — as the pre-notarization baseline.

## Out of scope

Notarization (blocked — not purchased); removing the quarantine workaround
(`runbook.md` step 7 — depends on notarization); Sparkle; any cask change that touches the
entitlements or bundle id.