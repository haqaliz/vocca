<p align="center">
  <img src="https://raw.githubusercontent.com/haqaliz/vocca/master/assets/vocca-app-icon.png" alt="Vocca" width="104" />
</p>

# Vocca

**Speak; it appears, or it answers instantly, on your machine, and yours to change.**

Vocca is an open-source, macOS, local-first voice tool. Hold a hotkey and talk, and polished text types itself into *any* app. Talk to it and it talks back through local Kokoro TTS and it can *act*.

Your audio never has to leave your Mac.

<p align="center">

[![CI](https://img.shields.io/github/actions/workflow/status/haqaliz/vocca/ci.yml?label=CI&color=3fb950)](https://github.com/haqaliz/vocca/actions/workflows/ci.yml)
[![Status](https://img.shields.io/badge/status-P0%20in%20development-3fb950)](docs/ROADMAP.md)
[![Release](https://img.shields.io/github/v/release/haqaliz/vocca?color=3fb950&label=release)](https://github.com/haqaliz/vocca/releases/latest)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
[![macOS](https://img.shields.io/badge/platform-macOS%20(Apple%20Silicon)-333333?logo=apple&logoColor=white)](docs/technical/ARCHITECTURE.md)
[![Swift](https://img.shields.io/badge/swift-6.0-orange?logo=swift&logoColor=white)](https://www.swift.org/)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-3fb950)](CONTRIBUTING.md)

[Why](#why) · [Install](#install) · [What it will do](#what-it-will-do) · [Building & signing](#building--signing) · [Architecture](docs/technical/ARCHITECTURE.md) · [Vision](VISION.md) · [Roadmap](docs/ROADMAP.md) · [Product spec](docs/product/PRODUCT_SPEC.md) · [Contributing](#contributing)

</p>

---

> ### ⚠️ Status: early the loop has delivered, the product is not yet proven
>
> **The P0 dictation loop is wired and tested: press `⌥Space`, talk, press again, and the words are
> transcribed locally and typed into the focused app** (hold-to-talk is the other mode, the
> General settings tab switches between them, and the shortcut itself is rebindable there)
> capture, hotkey, two ASR engines
> (Parakeet via FluidAudio and whisper.cpp), deterministic cleanup, the injection ladder with
> its failsafe, and the live widget are all shipped behind tested seams, and the zero-network
> probe drives a full dictation cycle end to end. Cleanup by a local Ollama model or a BYOK
> endpoint ships too, opt-in and badged whenever it is on chosen in the Cleanup settings tab,
> which asks for a confirmation naming exactly what gets sent before any text may leave the Mac.
> `cleanup-config.json` stays hand-editable as a second, supported path.
> **Engine switching ships** the Speech tab picks the engine and the Whisper tier, downloads a
> model and removes one, without a restart and **whisper is now verified, on both tiers**:
> its first real transcriptions have happened, and it scored **WER 0.0000 on all six fixtures
> on both tiers** (turbo and q5_0), with the digests in its shipped manifests compared against
> the provisioned bytes and passing (`docs/SMOKE_CHECKLIST.md` steps 19 and 102; the bytes come
> from `ggerganov/whisper.cpp`, closing the provenance gap). Its WER tolerances were seeded from
> Parakeet's table and the real runs cleared them with margin, so the seeded tables stand rather
> than being re-baselined. What is *not* measured on whisper is latency: its Core ML encoder is
> absent from the shipped manifest, so it runs on Metal/CPU which affects speed, not accuracy.
> **A real-machine pass has happened** the first real dictations delivered on the founder's
> Mac (`docs/SMOKE_CHECKLIST.md` steps 62–68), with the loop's invariants holding and
> **v0.2.0 is the first installable release** (signed, **not notarized**: the quarantine command
> in [Install](#install) is required until the Developer Program purchase lands).
>
> The numbers are still largely unmeasured: the injection matrix has one recorded row of its
> run, and the latency-gate p50/p95 have been measured but **not on the input the gate names**
> the recorded figures come from a 60-second fixture, where the gate specifies a 10-second
> utterance so they are not the gate's numbers. Whisper's accuracy *has* now had its real run
> (WER 0.0000, both tiers). The rest is pending its checklist execution, not claimed. The plan vision, phased
> roadmap, capability backlog, architecture, product spec is all still here and still governs.
>
> If you're here from a link expecting a download: install it, and know that it is signed but
> **not notarized** the quarantine command matters (opening a quarantined app does not warn,
> macOS deletes it), and the numbers above are still pending. Star the repo if you want to
> watch them get measured.

---

## Why

Wispr Flow proved that voice-to-text-everywhere is a daily habit worth paying for. But it's closed, cloud, and rented it structurally cannot be private, local, or open.

Good open-source Mac dictation now exists ([VoiceInk](https://github.com/Beingpax/VoiceInk), [FluidVoice](https://github.com/altic-dev/FluidVoice), Handy, Whispering), and we're glad it does it means dictation quality is table stakes rather than a differentiator. What still doesn't exist is the *combination*:

**great dictation + a voice agent that can actually do things + fully local + extensible.**

That combination is the open lane, and it's what Vocca is for.

## Install

> **Vocca has dictated on a real machine** (founder-run, `docs/SMOKE_CHECKLIST.md` steps
> 62–68), but the injection matrix, the latency-gate numbers, and notarization are still
> pending. Install it to look at what's possible and run the `xattr` line before the first
> launch.

Apple Silicon, macOS 15 or later.

### Homebrew

```bash
brew install --cask haqaliz/vocca/vocca
xattr -dr com.apple.quarantine /Applications/Vocca.app   # before opening it
open /Applications/Vocca.app
```

### Download

Grab `Vocca-vX.Y.Z.dmg` from the [latest release](https://github.com/haqaliz/vocca/releases/latest),
open it, and drag **Vocca** to Applications. Then clear the quarantine flag once and launch:

```bash
xattr -dr com.apple.quarantine /Applications/Vocca.app
open /Applications/Vocca.app
```

> **Run the `xattr` line before you open Vocca the first time.** Opening it while it is still
> quarantined does not just show a warning macOS **deletes `/Applications/Vocca.app`**, and not
> to the Trash. If that has already happened, install again and run the line first. (If you are
> following older instructions that pass `--no-quarantine` to Homebrew: that flag no longer
> exists and the command will fail.)

> **Why the extra command?** Vocca is signed with an Apple Development certificate hardened
> runtime, secure timestamp and is **not notarized yet**, so macOS quarantines it on download
> and refuses to open it. There is no device restriction: the bundle carries no provisioning
> profile and its only entitlement is microphone access, so Gatekeeper is the sole obstacle. On
> macOS 15 the Control-click → Open shortcut is gone, so it is the command above or System
> Settings → Privacy & Security → **Open Anyway** after a blocked launch. Notarization is the
> next distribution milestone ([runbook](docs/planning/notarization/runbook.md)); when it lands,
> both of these disappear.

### First launch

Vocca is `LSUIElement` **no Dock icon, no window**. A successful launch and a failed one look
identical, so look for the menu bar item. A first-run window walks you through the two
permissions and the model download:

- **Microphone** Vocca cannot hear you without it.
- **Accessibility** Vocca cannot type into other apps without it, and macOS requires a restart
  of the app after granting it.
- **The speech model** (~470 MB, Parakeet) downloads once. This is the only network request
  Vocca's default configuration ever makes; it is asserted by a CI test that is a permanent
  release blocker.

Verify a download against `SHA256SUMS.txt` on the release.

### Uninstall

```bash
brew uninstall --cask vocca          # the app
brew uninstall --zap --cask vocca    # also the models, dictionary, and learned per-app settings
```

A BYOK API key, if you configured one, is in your login Keychain and is not removed by either
delete it in Keychain Access.

## What it looks like

Settings is a sidebar window; the dictation surface itself is a small always-on-top widget that
never takes focus. Screenshots are of the shipping build.

<p align="center">
  <img src="https://raw.githubusercontent.com/haqaliz/vocca/master/assets/screenshots/general.png" alt="General settings: the dictation shortcut, and toggle versus hold-to-talk" width="720" />
</p>

**General** the hotkey and how it activates. Toggle (press to start, press to stop) and
hold-to-talk both ship; the shortcut is rebindable. The two caveats under the recorder are there
because Vocca genuinely cannot see shortcuts other apps have taken, and says so rather than
implying a check it does not perform.

<p align="center">
  <img src="https://raw.githubusercontent.com/haqaliz/vocca/master/assets/screenshots/cleanup.png" alt="Cleanup settings: deterministic rules by default, local Ollama and BYOK both opt-in, with an explicit warning when text would leave the Mac" width="720" />
</p>

**Cleanup** deterministic rules are the default and run entirely on your Mac. A local Ollama
model and your own API key are both opt-in, and the moment a choice would send text off the
machine it is badged at the point of use: *"Text leaves your Mac."* The footer states which one is
actually cleaning your text right now, because a setting that needs a restart is a setting that
can lie to you.

<p align="center">
  <img src="https://raw.githubusercontent.com/haqaliz/vocca/master/assets/screenshots/apps.png" alt="Apps settings: the per-app strategy memory, showing which injection method Vocca learned for each application" width="720" />
</p>

**Apps** the per-app strategy memory. Vocca learns which rung of the injection ladder actually
works for each application and stops retrying what is known to fail. "Learned" means it worked
that out by itself; you can pin a method instead, and reset what it learned without losing your
pins.

## What it will do

1. **Dictate anywhere** press `⌥Space`, talk, press again. Polished text lands in whatever app has focus. (Prefer holding the key instead, or a different shortcut? Settings → General.)
2. **Clean it up** fillers gone, punctuation right, your names spelled your way. Deterministic by default; a local LLM if you want one.
3. **Type reliably** a four-rung injection ladder that ends, always, in your words being recoverable. Losing a transcript is treated as a bug with no acceptable rate.
4. **Talk back** local Kokoro TTS, real turn-taking, and barge-in you can interrupt.
5. **Act** voice that drives MCP tools, commands, and coding agents, with the active app and your selection as context.

## Principles

- **Local-first, literally.** The default configuration makes **zero network calls** asserted by a CI test that is a permanent release blocker. Any egress is opt-in and badged at the moment it happens.
- **A transcript is never lost.** Every failure path ends with your text recoverable and copyable.
- **Everything pluggable.** ASR, cleanup, TTS, and actions each sit behind an interface with **two real implementations shipped** because a seam with one implementation is an assertion, not a seam.
- **The local core is never crippled.** A future hosted tier may only ever be *added* to a seam. Nothing local gets removed, degraded, or feature-gated to sell it.
- **Gets better as local models improve.** Our value is the integration, the UX, and the action layer never a wrapper around one checkpoint.

## Planned stack

| Layer | Choice | Why |
|-------|--------|-----|
| Shell + core | Native SwiftUI, single Swift 6 process | Direct AX/CGEvent/Pasteboard access, no IPC on the latency path |
| ASR (default) | [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) via [FluidAudio](https://github.com/FluidInference/FluidAudio) | CoreML on the Neural Engine; ~24× realtime on M4; low power |
| ASR (second) | [whisper.cpp large-v3-turbo](https://github.com/ggml-org/whisper.cpp) | **Shipped, selectable and accuracy-verified** a real second implementation behind `ASREngine`: proves the seam and hedges ecosystem risk. Both tiers scored WER 0.0000 on all six fixtures and both manifests' digests verified against the provisioned bytes (founder run, [`docs/SMOKE_CHECKLIST.md`](docs/SMOKE_CHECKLIST.md) steps 19 and 102). Its latency is unmeasured: no Core ML encoder ships, so it runs Metal/CPU |
| TTS | [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) | Small, fast time-to-first-audio, Apache-2.0 |
| VAD / turn-taking | Silero VAD + Parakeet EOU 120M | Frame-level VAD alone doesn't do turn-taking |
| Cleanup | Rules → Ollama → BYOK | **Shipped** rules by default (~0 MB, <5 ms, no network); Ollama and BYOK are opt-in, degrade to the rules output on any failure, and are badged at point of use. LLM rewrite quality is unmeasured |
| Actions | MCP | The action layer, gated on confirmation and an audit log |

Platform: **macOS on Apple Silicon.** No Windows or Linux until the Mac experience is genuinely good.

## Documentation

| Document | What it covers |
|----------|----------------|
| [`VISION.md`](VISION.md) | The thesis, the moat, the non-goals |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | Six phases (P0–P5), each with milestones, metrics, and an exit gate |
| [`docs/technical/CAPABILITY_ROADMAP.md`](docs/technical/CAPABILITY_ROADMAP.md) | C1–C14: the independently-shippable build backlog |
| [`docs/technical/ARCHITECTURE.md`](docs/technical/ARCHITECTURE.md) | **Authoritative.** Types, seams, threading, failure semantics |
| [`docs/product/PRODUCT_SPEC.md`](docs/product/PRODUCT_SPEC.md) | Widget states, interaction, onboarding, settings |
| [`docs/SMOKE_CHECKLIST.md`](docs/SMOKE_CHECKLIST.md) | What CI structurally cannot cover, and the manual steps before a release |
| [`CLAUDE.md`](CLAUDE.md) | Orientation for coding agents working in this repo |

## Building & signing

Vocca ships **unsandboxed** `com.apple.security.app-sandbox` is deliberately absent from
`App/Vocca.entitlements`. The sandbox would confine the process to a container and cut it off
from the Accessibility API and system-wide text injection the whole product depends on, so it
isn't an option here the way it is for most Mac apps.

macOS keys every TCC permission grant (Microphone, Accessibility) on the app's **code identity**,
not just its bundle identifier. Ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`) mints a fresh identity
on every build, which silently revokes those grants each rebuild. To avoid that during
development:

```sh
./Scripts/dev-identity.sh          # once: creates a stable, local, self-signed "Vocca Development" identity
xcodebuild -project Vocca.xcodeproj -scheme Vocca -configuration Debug \
    -derivedDataPath .build/xcode ARCHS=arm64 build
./Scripts/sign.sh --local-dev      # re-signs .build/xcode/Build/Products/Debug/Vocca.app with it
```

**`--local-dev` is not optional for a self-signed build without it the app does not start.**
The hardened runtime enables Library Validation, which requires every embedded framework to carry
the same Team ID as the app, and a self-signed identity has no Team ID at all. Since the bundle
embeds `whisper.framework`, `dyld` refuses to map it and the process dies before `main()`:

```
Library not loaded: @rpath/whisper.framework/Versions/Current/whisper
Reason: ... (non-platform) have different Team IDs
```

It dies *invisibly*: Vocca is `LSUIElement`, so there is no window, no Dock icon and no crash
dialog a failed launch and a successful one look exactly the same. The flag injects
`com.apple.security.cs.disable-library-validation` into a temporary copy of the entitlements only,
so `App/Vocca.entitlements` stays as it is and the shipped bundle is unaffected. A real Developer
ID identity removes the need for it entirely: the framework is then re-signed with a matching Team
ID and Library Validation is satisfied. Never pass it for a bundle you intend to ship or notarize.

Because a launch is silent either way, check it the way the app reports on itself:

```sh
pgrep -lf "MacOS/Vocca"                                          # is it alive?
log show --predicate 'subsystem == "dev.vocca.Vocca"' \
    --last 5m --info --style compact                             # what does it say?
```

The loop logs its own readiness there `the event tap is delivering` versus `no Accessibility
grant the hotkey is deaf until it is granted`, and any engine-preparation failure.

`dev-identity.sh` is idempotent and wires the identity in via `Config/Signing.local.xcconfig`
(git-ignored, host-local). Without it, `Config/Signing.xcconfig` falls back to `-` a fresh clone
with no identity still builds, just back to the ad-hoc, re-grant-every-time behavior.

**To reset the dev identity**, delete the keychain the script owns and rerun it:

```sh
security delete-keychain ~/Library/Keychains/vocca-dev.keychain-db
rm -f ~/Library/Application\ Support/Vocca/dev-keychain.pass
./Scripts/dev-identity.sh
```

That is also what to do if `dev-identity.sh` refuses to run because a certificate is present but
not trusted the state an earlier run leaves behind if it failed or was interrupted partway. It
deliberately will not create a second certificate with the same name on top of the first: `codesign`
would then be choosing between two leaf certificates, and which leaf signs the app is exactly what
macOS keys your Microphone and Accessibility grants on.

`Scripts/sign.sh` defaults to the **Debug** bundle. It reads `VoccaBuildConfiguration` out of the
bundle and signs the two configurations differently Debug additionally gets
`com.apple.security.get-task-allow`, without which no debugger can attach; Release gets
`App/Vocca.entitlements` and nothing else. `--local-dev` is independent of that and adds its one
entitlement to either configuration. For a release build, pass the path:
`./Scripts/sign.sh .build/xcode-release/Build/Products/Release/Vocca.app`. The full release order is
in [`docs/SMOKE_CHECKLIST.md`](docs/SMOKE_CHECKLIST.md).

This identity is self-signed and proves nothing to anyone but this Mac. **Notarization
(`Scripts/notarize.sh`) is unproven** there is no Apple Developer ID or `notarytool` credential
configured yet, so the script has never run end to end. It detects that and exits 0 with an
explicit skip message rather than failing; see the comment at the top of the script for how to
configure real credentials once there's a Developer ID to notarize with.

## Continuous integration

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every push and pull request, on a
pinned `macos-15` runner with an explicitly selected Xcode. Three jobs:

| Job | Runs | Proves |
|---|---|---|
| **Headless suite** | `swift build --build-tests -Xswiftc -strict-concurrency=complete`, then `swift test` | The package compiles with **zero** strict-concurrency warnings (any warning fails the job) and the whole suite passes module boundaries, licence headers, the package manifest, and the zero-network invariant. |
| **Bundle contract (Debug)** | `xcodebuild -configuration Debug`, then `swift test` with `VOCCA_APP_BUNDLE` set | A real signed `Vocca.app` carries the microphone entitlement and usage string, runs unsandboxed with the hardened runtime actually in the signature, and was built from the checked-in `App/` sources. |
| **Bundle contract (Release)** | The same for Release | All of the above, **plus** that the Release bundle's entitlement set equals `App/Vocca.entitlements` exactly. Debug may carry `com.apple.security.get-task-allow`; Release may not, and the suite knows which bundle it is looking at. |

**No secrets, ever.** The app target signs ad-hoc `Config/Signing.xcconfig` falls back to
`CODE_SIGN_IDENTITY = "-"` when the host-local override is absent which needs no Developer ID, no
keychain and no repository secret. That is what makes the bundle assertions *mandatory* in CI rather
than skipped: with `VOCCA_APP_BUNDLE` set, a missing bundle is a hard failure, not a skip.

### Releases

Push a `v*` tag (e.g. `git tag v0.1.0 && git push origin v0.1.0`) to trigger
[`.github/workflows/release.yml`](.github/workflows/release.yml): it runs the whole suite, builds
Release, signs it with the workflow's imported identity (via `Scripts/sign.sh`, hardened runtime
and secure timestamp), re-runs the suite against the *signed* bundle, verifies the tag version
equals `CFBundleShortVersionString`, and uploads `Vocca-macos.zip` (with SHA256) to a GitHub
Release. Required secrets: `APPLE_CERT_P12_BASE64` + `APPLE_CERT_PASSWORD` (an exported Apple
Development .p12 see the workflow header). Without them a tag push fails loudly at the signing
step; there is no path to a green run that produced no release.

**Releases are signed, not notarized.** `Scripts/notarize.sh` has never run end to end it needs a
paid Developer ID Application certificate plus a `notarytool` credential, neither of which exists
so a GitHub Release from this workflow runs only on the machine that built it; Gatekeeper will not
launch it elsewhere. The release notes say so out loud. Notarization lands when a Developer ID does.

CI also sets `CI=1`, which raises the zero-network probe's settle window from 0.75s to 6s so that
deferred egress on a loaded runner cannot slip past it.

### What CI does not run

Everything that needs hardware or a permission grant, which is most of what can actually break:
`CGEvent.tapCreate` returns `nil` without an Accessibility grant and TCC cannot be granted on a
hosted runner; there is no microphone; and `AVAudioSinkNode` is unsupported in manual rendering
mode, so the realtime capture path has no offline equivalent to exercise. Read
[`docs/SMOKE_CHECKLIST.md`](docs/SMOKE_CHECKLIST.md) it states the limits precisely and lists the
manual steps required before a release. **A green badge here is a narrower claim than it looks.**

## Non-goals

- Cross-platform before macOS is genuinely good.
- Cloud in the open core, or any audio leaving the device by default.
- A crippled free tier to upsell a hosted one.
- An over-built assistant before dictation is excellent.
- A searchable archive of everything you've ever said.

## Contributing

Early. What exists is the skeleton described at the top of this file a package, an app bundle, signing scripts and CI not a working product, so there is not yet much to build *on*. Once C1 lands, the seams in [`ARCHITECTURE.md`](docs/technical/ARCHITECTURE.md) are the extension points, and "add your own ASR engine" is an explicitly supported path.

If you do open a PR now, the bar it has to clear is CI: `swift test` (with the test-count floor in `Scripts/test-with-floor.sh`) and both bundle contracts, green. Issues and discussion about the plan itself are welcome too.

## License

Apache-2.0. The patent grant matters for a tool doing system-level input injection, and it's the friendlier choice for the open-core structure described in the roadmap. Dependencies and model artifacts (with the weight-license record) are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
