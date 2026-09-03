# Notarization runbook — what to do the day the $99 program is bought

Everything Vocca needs to become a normally installable Mac app, in order, with the
verification gate for each step. Nothing here is possible without the paid
[Apple Developer Program](https://developer.apple.com/programs/) ($99/yr).

This is the deck runbook (`../deck/docs/planning/notarization/runbook.md`) adapted to Vocca.
Where the two projects differ, the difference is called out rather than silently dropped —
Vocca is unsandboxed by design, embeds a third-party framework, and depends on two TCC grants
instead of one, and each of those changes what this costs.

## Status as of v0.2.0

**The first installable release exists; the notarization half of this runbook is blocked —
not purchased.** The Apple Developer Program has not been bought, so nothing here that needs
a Developer ID has run. What the `release-distribution` unit (2026-09-03) executed instead,
all measured rather than assumed:

- **`v0.2.0` DMG built from Vocca's own bundle** — the packaging step ran for the first
  time against the real app: the workflow mounted the DMG it built, asserted
  `whisper.framework/Versions/Current` is still a symlink (the v0.1.0 zip defect's gate),
  and `codesign --verify --deep --strict` passed on the mounted app. Published to
  [the release](https://github.com/haqaliz/vocca/releases/tag/v0.2.0) with `SHA256SUMS.txt`.
- **The cask shipped and installed.** `homebrew/vocca.rb` carries the real version + sha256;
  `Casks/vocca.rb` is published to `haqaliz/homebrew-vocca`; `brew install --cask
  haqaliz/vocca/vocca` was executed and the app launched (`pgrep -x Vocca` returned a pid).
  `spctl` on the installed app reports **`rejected`** — `origin=Apple Development:
  haqaliz@aol.com` — the recorded pre-notarization baseline.
- **Claims corrected.** The release notes and README no longer say the loop "has not been
  proven to dictate" (retracted by `p2-gate-measurement`'s first real dictations, SMOKE
  62-68); they state the measured truth: real-machine pass happened; matrix, latency-gate
  numbers, and notarization pending.
- **`v0.1.0` has no GitHub release** — only a tag; the broken zip asset from the
  `release-packaging` unit's post-mortem was never attached to a release, so
  `releases/latest` points at v0.2.0 with nothing to dispose.

**Blocked — not purchased (each named, none silently skipped):**

| Step | State |
|------|-------|
| 0 (program + individual/org) | **blocked — not purchased.** Individual is the path of no change when it lands (existing cert is `O=Ali Haqiqi`, team `K6X49DG8VF`) |
| 1 (Developer ID Application cert + secrets) | **blocked — not purchased** |
| 2 (identity switch; `--local-dev` deletion) | **blocked** — the self-signed path still exists and is still required locally |
| 3 (notarize + staple in CI) | **blocked** — `Scripts/notarize.sh` still never run end to end; its credential-detect-and-skip path remains the only executed half |
| 4 (verification gates on a second Mac) | partially **blocked** — `spctl` baseline recorded on the founder's machine; the notarized `accepted` side awaits Step 3; no second Mac was reachable |
| 5 (TCC reset re-test) | **blocked** — identity unchanged; the TCC re-prompt cost was however observed on the founder's machine (evidence build → CI-signed v0.2.0 re-prompted) |
| 6 (bundle-id decision) | **decided 2026-09-03**: `vocca.dev` is **not owned**; the founder chose to keep the frozen `dev.vocca.Vocca` (recorded in `docs/planning/release-distribution/version-bump/plan_20260903.md`) |
| 7 (quarantine-workaround removal) | **blocked** — all `xattr` instructions still required and still shipped |
| 8 (Sparkle) | **blocked** — "then, and only then" still holds |

The bundle state measured at v0.1.0 (`Authority=Apple Development: haqaliz@aol.com
(YJ32Z93LB5)`, `TeamIdentifier=K6X49DG8VF`, hardened runtime on, mic entitlement only, no
provisioning profile) is unchanged at v0.2.0 — same certificate, same two consequences
(no device restriction; Gatekeeper is the sole obstacle).

## Why this is worth $99

1. **Gatekeeper stops refusing the app.** No `xattr`, no trip through System Settings →
   Privacy & Security. On macOS 15 the old Control-click → Open shortcut is gone, so today's
   workaround is a Terminal command, and that is where most first-time users give up. For
   Vocca this compounds: the app is `LSUIElement`, so a Gatekeeper-blocked launch produces no
   window, no Dock icon and no dialog the user connects to the cause. It looks exactly like a
   working launch, and exactly like every other silent failure this project has already spent
   two days chasing.

2. **Apple Development certificates are not a distribution channel**, regardless of what
   Gatekeeper can be talked into. They are issued for development, capped, and renewed on a
   yearly cycle tied to one person's account.

### What expiry actually costs

Deck's runbook argues that a development signature dies with its certificate on 2027-08-09.
Vocca's signature carries a real secure timestamp, which is the mechanism that lets a
signature outlive its certificate — so the same claim does not obviously apply here.

**Treat this as unverified.** Nobody has watched a timestamped Apple Development signature
cross its certificate's expiry, and the interesting question is not whether the signature
validates but what Gatekeeper does with a development-signed app afterwards, which is a
different code path from the Developer ID one. Do not plan around Vocca surviving
2027-08-09; plan around notarizing well before it.

## Step 0 — Decide individual or organization (do this first, it is hard to undo)

Gatekeeper shows the team name in its dialogs, and it is baked into the certificate.

| | Individual | Organization |
|---|---|---|
| Name users see | `Ali Haqiqi` | the company name |
| Requires | an Apple ID | a legal entity + a free [D-U-N-S number](https://developer.apple.com/support/D-U-N-S/) |
| Time to enrol | hours to ~2 days | ~1–2 weeks (D-U-N-S lookup, then a verification call) |
| Cost | $99/yr | $99/yr |

The existing certificate is already an individual one (`O=Ali Haqiqi`, team `K6X49DG8VF`), so
individual is the path of no change.

Converting individual → organization later issues a **new team ID**, which means a new signing
identity, which resets every user's TCC grant. For deck that costs a re-prompt. **For Vocca it
costs the Accessibility grant**, without which the app does nothing at all and — being
`LSUIElement` — says nothing about why. Decide once, here.

## Step 1 — Create the Developer ID Application certificate

Xcode → Settings → Accounts → select the team → **Manage Certificates…** → **+** →
**Developer ID Application**. (Or the
[certificates page](https://developer.apple.com/account/resources/certificates).)

Vocca does **not** need a Developer ID *Installer* certificate — that is for `.pkg` installers,
and Vocca ships a `.dmg`.

Apple caps Developer ID Application certificates per account (5 at the time of writing) and
they cannot be deleted freely, so do not create throwaways.

Export it for CI, private key included:

```bash
# Keychain Access → login → Certificates → right-click the
# "Developer ID Application: …" entry → Export → .p12 → set a strong password.
base64 -i DeveloperID.p12 | pbcopy
```

Update the GitHub repository secrets:

| Secret | New value |
|---|---|
| `APPLE_CERT_P12_BASE64` | the base64 above (replaces the Apple Development export) |
| `APPLE_CERT_PASSWORD` | the .p12 password |
| `APPLE_ID` | **new** — the Apple ID the program is enrolled under |
| `APPLE_APP_SPECIFIC_PASSWORD` | **new** — appleid.apple.com → Sign-In & Security |
| `APPLE_TEAM_ID` | **new** — `K6X49DG8VF` unless Step 0 changed it |

An App Store Connect API key is the tidier long-term option for CI (no coupling to one
person's 2FA); the three secrets above are enough to start.

**Gate:** `security find-identity -v -p codesigning` lists
`Developer ID Application: … (TEAMID)`.

**Watch for this one:** `.github/workflows/release.yml` picks the signing identity with
`security find-identity -v -p codesigning | … | head -1`. That is safe today because the CI
keychain is created fresh and holds exactly one certificate. If both a Development and a
Developer ID certificate are ever imported into the same keychain, `head -1` becomes a coin
flip. Replace the secret rather than adding to it, or pin the identity name explicitly.

## Step 2 — Switch the project to Developer ID

Vocca needs **less** here than deck did: the hardened runtime is already enabled on Release
(`flags=0x10000(runtime)` above), `App/Vocca.entitlements` already contains exactly one
entitlement, and `Scripts/sign.sh` already verifies the entitlement set it produced by reading
it back out of the finished signature.

What changes:

- Nothing in `App/Vocca.entitlements`. Microphone access is not a gated entitlement and needs
  no provisioning profile. **Do not add anything here** — `BundleConfigurationTests` asserts
  the checked-in set, and Release must never carry `get-task-allow` or
  `com.apple.security.cs.disable-library-validation`.
- Local builds stop needing `Scripts/sign.sh --local-dev`. The flag exists only because the
  self-signed "Vocca Development" identity has **no Team ID**, so Library Validation refuses to
  map the embedded `whisper.framework`. A Developer ID has a Team ID, and `sign.sh` already
  re-signs embedded frameworks before the app, so the framework and the app match and the
  problem disappears. Once every developer has a Developer ID, `--local-dev` should be deleted
  rather than left as a footgun that produces bundles which must never be notarized.
- `Scripts/dev-identity.sh` and the self-signed identity stay, for contributors without one.

**Gate:** after a local Release build and `Scripts/sign.sh`,

```bash
codesign -dvvv .build/xcode-release/Build/Products/Release/Vocca.app 2>&1 \
  | grep -E "Authority=Developer ID|flags=.*runtime|Timestamp="
```

shows the Developer ID authority, the `runtime` flag, and a `Timestamp=`.

### Hardened runtime: what to watch

Vocca already runs under it, so nothing should newly break — but the identity change is the
moment to confirm rather than assume:

- **The embedded `whisper.framework`** is the one thing Library Validation cares about, and
  Step 2 is exactly what fixes it. If `dyld` still refuses it after the switch, the framework
  was not re-signed with the new identity — check `sign.sh`'s inner-binary loop ran.
- **CoreML / ANE (Parakeet via FluidAudio)** needs no entitlement.
- **CGEvent taps, the Accessibility API, and the pasteboard** are gated by TCC, not by the
  hardened runtime. No entitlement exists for them and none is needed.
- Vocca uses no JIT, no `DYLD_INSERT_LIBRARIES` in the shipped app (the zero-network probe's
  interposer is test-only and never enters the bundle), and no unsigned executable memory — so
  none of the corresponding exception entitlements apply. **If you find yourself adding one,
  stop:** every hardened-runtime exception is a line an auditor reads as "this app opted out of
  a protection", which is a bad look for a tool whose pitch is privacy.

If a hardened-runtime crash does appear, `log stream --predicate 'sender == "AMFI"'` names the
restriction it hit.

## Step 3 — Notarize and staple in CI

Two passes: the `.app` gets its own ticket so it launches offline once dragged out of the
image, then the `.dmg` gets one so the image itself opens cleanly. Stapling only the DMG leaves
the installed app relying on an online Gatekeeper check.

**Reuse `Scripts/notarize.sh` rather than inlining `notarytool` in the workflow.** The script
already does the app pass correctly — `ditto -c -k --keepParent`, submit, `--wait`, staple —
and has a credential-detect-and-skip path that is the only part of it ever executed. Two
notarization implementations that can drift is exactly the failure `Scripts/test-with-floor.sh`
exists to prevent elsewhere. The script authenticates with a stored keychain profile
(`VOCCA_NOTARY_PROFILE`, default `vocca-notary`), so CI creates that profile from the secrets
first:

```bash
xcrun notarytool store-credentials "vocca-notary" \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_SPECIFIC_PASSWORD"

./Scripts/notarize.sh .build/xcode-release/Build/Products/Release/Vocca.app
```

Locally, run the same `store-credentials` line once and the script works unchanged.

Then, in `.github/workflows/release.yml`, the ordering constraint. The **DMG must be built from
the already-stapled app**, so the notarize step goes *between* "Run the suite against the
signed bundle" and "Package Vocca.dmg", and a second pass notarizes the image after
`hdiutil create` and before `shasum`:

```bash
xcrun notarytool submit "Vocca-${VERSION}.dmg" --keychain-profile "vocca-notary" --wait
xcrun stapler staple "Vocca-${VERSION}.dmg"
```

**Staple before `shasum`**, or the published checksum will not match the bytes users download —
and `homebrew/vocca.rb` carries that checksum, so getting it wrong breaks every `brew install`
until the cask is re-pushed.

When a submission comes back `Invalid`, the reason is never in the summary:

```bash
xcrun notarytool log <submission-id> --keychain-profile "vocca-notary"
```

The likely first-run causes here, in order: the embedded `whisper.framework` still carrying the
old identity; a stray `com.apple.security.cs.disable-library-validation` from a `--local-dev`
signature; or an archive that flattened the framework's symlinks (the v0.1.0 defect — this is
why the DMG step gates on `Versions/Current` still being a symlink).

Notarization normally returns in minutes, but Apple gives no SLA — allow for a slow run before
assuming the workflow hung.

## Step 4 — Verification gates

Download the published DMG on a machine that has never built Vocca, then:

```bash
spctl -a -vvv -t exec /Applications/Vocca.app
#   → accepted   source=Notarized Developer ID     (today: "rejected")

codesign -dvvv /Applications/Vocca.app 2>&1 | grep -E "Authority=Developer ID|Timestamp="
#   → the Developer ID authority, and a real Timestamp=

xcrun stapler validate /Applications/Vocca.app
xcrun stapler validate Vocca-vX.Y.Z.dmg
#   → The validate action worked!

codesign --verify --deep --strict --verbose=2 /Applications/Vocca.app
#   → no output, exit 0     ← the check v0.1.0 fails

codesign -d --entitlements - /Applications/Vocca.app 2>&1 | grep -cE "get-task-allow|disable-library-validation"
#   → 0
```

Then the functional pass, on a **second Mac outside the signing team** — the assumption this
project has never once tested:

- [ ] The DMG opens with **no Gatekeeper prompt at all**, and dragging to Applications works
- [ ] The app launches with no `xattr` command — confirm via the menu bar item, not by the
      absence of a dialog, because absence of a dialog is also what failure looks like
- [ ] `pgrep -x Vocca` returns a pid

## Step 5 — Re-test what the identity change resets

TCC grants are keyed to the code signature's designated requirement, so switching from Apple
Development to Developer ID **invalidates every existing grant**. Users are re-prompted once;
that is expected, but it must be confirmed to still *work* — and for Vocca this is the
highest-risk step in the runbook, because both grants are load-bearing and the app is silent
when they are missing.

Reset and re-run rather than trusting an already-granted machine:
`tccutil reset Microphone dev.vocca.Vocca` and `tccutil reset Accessibility dev.vocca.Vocca`.

- [ ] The **Microphone** prompt appears, with Vocca's own `NSMicrophoneUsageDescription` copy
- [ ] The **Accessibility** prompt appears, and the first-run window's three-state row
      (not granted / granted, restart to arm / armed) reflects reality
- [ ] After granting Accessibility and restarting, the hotkey fires **from another app's front
      window** — not just when Vocca is frontmost
- [ ] Quit, relaunch: the grants survived
- [ ] A full dictation lands text (`docs/SMOKE_CHECKLIST.md` steps 62–68)

Not reset by the identity change, and worth confirming precisely because it is easy to assume
the opposite: everything under `~/Library/Application Support/Vocca` — the downloaded models,
`dictionary.json`, `strategies.json`, `cleanup-config.json`, the `recovery/` journal — is keyed
by path, not by code identity, and survives. A user does **not** re-download the model.

## Step 6 — Ride the same release with the other install-invalidating changes

The Developer ID switch already forces every user to re-grant permissions, so anything else
with the same cost should ship in the same version rather than inflicting a second round.

- [ ] **The bundle identifier.** `dev.vocca.Vocca` is already frozen and asserted by
      `BundleConfigurationTests`, so unlike deck there is nothing to rename — *provided*
      `vocca.dev` is a domain that is actually owned or intended. That is unverified here. If it
      is not, this release is the last cheap moment to change it: afterwards it costs every
      user's TCC grants again.
- [ ] **Sparkle** — see Step 8.

## Step 7 — Drop the quarantine workaround everywhere

Once a notarized release is out, these all become wrong and read as amateurish:

- [ ] `homebrew/vocca.rb` — the header comment block and the whole `caveats` stanza; mirror the
      file to the tap
- [ ] `README.md` — the `xattr` line in **both** the Homebrew and Download blocks, the
      "run it before you open it" callout, and the "Why the extra command?" callout
- [ ] `.github/workflows/release.yml` — the header comment's notarization paragraph and the
      release-notes heredoc (the install instructions become "download, drag, open")
- [ ] `docs/SMOKE_CHECKLIST.md` — steps 60–61 stop being "never run"; add the notarized-install
      row on a second Mac
- [ ] `CLAUDE.md` — the "Notarization is unproven" bullet under *What is NOT proven*
- [ ] This file — replace the "Status as of v0.1.0" section with what shipped

## Step 8 — Then, and only then, Sparkle

Auto-update is pointless before notarization: the downloaded update would be Gatekeeper-blocked
exactly like the first install. Immediately after, it is necessary — otherwise the next version
ships and nobody who installed the previous one ever hears about it.

Sparkle signs its appcast with an EdDSA key separate from the Apple certificate; generate it
with Sparkle's `generate_keys` and keep the private half in the repository secrets.

One Vocca-specific caution: Sparkle relaunches the app, and **the Accessibility grant is armed
at launch**. Confirm that an update-and-relaunch leaves the hotkey armed rather than requiring
the user to restart again — the first-run window's "granted, restart to arm" state exists
because that transition is not automatic.

## What $99 does *not* unlock: the Mac App Store

Vocca cannot ship on the Mac App Store as architected, and no amount of paperwork changes that.
MAS requires every executable in the bundle to be sandboxed, and Vocca is **deliberately
unsandboxed** — `com.apple.security.app-sandbox` is absent from `App/Vocca.entitlements` on
purpose, because the sandbox cuts the process off from the Accessibility API and the
system-wide text injection the entire product is. Sandboxing Vocca deletes Vocca.

The program covers both distribution paths, so nothing is lost by buying it; the deliverable is
a notarized DMG plus a Homebrew cask, which is also what a launch post should link to.

## Rollback

If notarization keeps failing and a release is urgent, restore the Apple Development `.p12` to
`APPLE_CERT_P12_BASE64`, remove the notarize steps from the workflow, and ship as today — the
unnotarized path stays valid, with the `xattr` instructions already written. Keep the
notarization steps behind a `if: steps.signing.outputs.available == 'true'`-style guard so a
fork without secrets still builds.

## Cost and time summary

| Item | Cost | Elapsed |
|---|---|---|
| Apple Developer Program (individual) | $99/yr | hours – 2 days |
| Apple Developer Program (organization) | $99/yr | 1–2 weeks (D-U-N-S first) |
| Steps 1–3 (cert, secrets, CI wiring) | — | ~half a day |
| Steps 4–5 (verification, second Mac, both TCC grants) | — | ~2 hours |
| Steps 6–8 (bundle ID decision, Sparkle) | — | ~1–2 days |
