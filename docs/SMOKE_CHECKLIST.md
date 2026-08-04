# Manual smoke checklist

**A green CI badge on this repository is not a statement that Vocca works.** It is a statement that
the package compiles under Swift 6 strict concurrency, that the suite passes, and that the signed
`Vocca.app` is configured the way macOS requires. Every one of those is worth having. None of them
touches the parts of Vocca most likely to be broken.

This file exists so nobody has to guess where the line is. It states what CI structurally cannot
cover — not "has not got round to", *cannot* — and then lists what a human has to do by hand before
a release.

---

## What CI cannot cover, and why

### 1. Accessibility / Input Monitoring, and therefore the global hotkey

`CGEvent.tapCreate` returns `nil` when the calling process has no Accessibility grant. Not an error,
not an exception — `nil`. Any code path that ends in an event tap is unreachable on a hosted runner,
which means the global hotkey, push-to-talk, and every later capability built on intercepting keys.

There is no way to grant it. TCC has no programmatic grant API by design; that is the point of TCC.
The only two routes that exist are:

- editing `TCC.db` directly, which requires System Integrity Protection to be disabled — impossible
  on a GitHub-hosted runner and a terrible idea on a self-hosted one, and
- an MDM-delivered PPPC profile, which requires an enrolled, supervised device.

Neither is available to this project, and neither should be pursued to make a badge greener. A
self-hosted runner with SIP off would be a machine whose security posture is worse than any user's,
attesting to behaviour on machines that are not like it.

### 2. The microphone

A hosted runner has no audio input device. `AVCaptureDevice.default(for: .audio)` has nothing to
return. Even with the entitlement present and the grant somehow given, there is no signal — so
"audio actually arrives, at the expected sample rate, with the expected latency" cannot be asserted
anywhere in CI.

CI asserts the *preconditions* for the microphone instead, which is a real and different thing: the
`NSMicrophoneUsageDescription` string is present and non-empty, the
`com.apple.security.device.audio-input` entitlement is embedded in the signed binary, the sandbox is
off, and the hardened runtime is on. Those are the four settings whose absence produces a silent
denial with no prompt and no error, and they are exactly the failures that are cheap to catch in a
test and expensive to catch by hand.

### 3. Offline rendering is not a substitute — the realtime path has no offline twin

The usual escape hatch for testing audio without hardware is `AVAudioEngine`'s manual rendering
mode: drive the graph from a file, assert on the output, no device needed. It does not apply here.
**`AVAudioSinkNode` is unsupported in manual rendering mode.** The sink node is how Vocca takes
realtime buffers off the engine, so the realtime capture path cannot be exercised offline *at all* —
not slowly, not partially. An offline test would necessarily be testing a different graph than the
one that ships.

This is a design constraint worth remembering, not just a CI limitation: any assertion about capture
has to come from a human with a microphone, or from a fixture that has deliberately swapped the
graph and therefore proves less than it appears to.

### 4. TCC prompts, and grants surviving a rebuild

Whether the permission dialog appears, says the right thing, and whether the resulting grant
*persists* across rebuilds are all unverifiable in CI. The last one is the one that bites: macOS
keys grants on code identity, so an ad-hoc-signed rebuild mints a new identity and silently drops
every grant. `Scripts/dev-identity.sh` exists precisely because of this, and whether it worked is
something only a human at a Mac can see.

### 5. Anything about how it feels

Latency, whether the widget steals focus, whether text lands in the right field of an arbitrary app.
These are the two make-or-break UX battles named in `CLAUDE.md`, and neither has a CI shape.

---

## What CI does cover

Stated positively, so the checklist below does not re-check things a machine already checked:

| Job | Proves |
|---|---|
| Headless suite | The package builds with **zero** strict-concurrency warnings, and all tests pass: module boundaries, licence headers, the package manifest, and the zero-network invariant (with the settle window raised to 6s). |
| Bundle contract (Debug) | A real `xcodebuild` Debug build produces a signed `Vocca.app` whose processed `Info.plist` and embedded entitlements match the checked-in sources, with the hardened runtime actually in the signature. |
| Bundle contract (Release) | The same for Release, **plus** that the Release bundle carries no entitlement beyond what `App/Vocca.entitlements` declares — in particular not `com.apple.security.get-task-allow`, which Debug is allowed and Release is not. |

---

## Manual steps before a release

Run these on a Mac, on the build you intend to ship, in order. Record the result; an unrun step is a
failed step.

### Build and identity

1. `./Scripts/dev-identity.sh` if this machine has no stable identity yet, then build Release:
   `xcodebuild -project Vocca.xcodeproj -scheme Vocca -configuration Release -derivedDataPath .build/xcode-release build`
2. Confirm the signature is what you expect:
   `codesign -d --verbose=2 .build/xcode-release/Build/Products/Release/Vocca.app`
   — `runtime` must be in the flags.
3. Confirm the entitlements are exactly one:
   `codesign -d --entitlements :- --xml .build/xcode-release/Build/Products/Release/Vocca.app`
   — `com.apple.security.device.audio-input` and nothing else. CI asserts this too; confirm it by
   eye anyway on the artefact you are actually shipping, because CI tested a bundle it built itself.

### Permissions, on a machine that has never run Vocca

This is the step most likely to be skipped and most likely to be broken, because it can only be done
once per machine without resetting state. Use a fresh user account or
`tccutil reset Microphone dev.vocca.Vocca` and `tccutil reset Accessibility dev.vocca.Vocca`.

4. Launch the app. Confirm **no Dock icon and no menu bar** appear (`LSUIElement`).
5. Trigger capture. Confirm the **microphone prompt appears**, and that its text is the
   `NSMicrophoneUsageDescription` string, not a generic one.
6. Grant it. Confirm audio actually arrives — that dictation produces text, not silence.
7. Deny it on a second fresh account. Confirm Vocca says something useful rather than appearing to
   work and producing nothing.
8. Confirm the Accessibility prompt appears when the global hotkey is first registered, and that
   after granting, the hotkey fires from **another app's** front window — not just when Vocca is
   frontmost.
9. Quit, rebuild, relaunch. Confirm the grants **survived** — this is what catches an identity
   regression, and it is invisible to every other check in this repository.

### Behaviour in the real world

10. Hotkey capture works while a full-screen app is frontmost.
11. Injection lands correctly in at least: a native Cocoa field (Notes), a browser field (Safari and
    Chrome), and an Electron app (VS Code or Slack). These fail differently and one working says
    little about the others.
12. The widget never takes focus: the app you were typing in stays frontmost throughout a capture.
13. Under Activity Monitor, confirm no network activity during a normal dictation cycle. CI asserts
    the invariant against the composition root; this confirms it for the shipping app, which
    contains one file (`App/VoccaApp.swift`) the probe cannot reach.

### If notarizing

14. `Scripts/notarize.sh` has **never run end to end** — there is no Developer ID configured. The
    first real release must treat notarization as unproven and budget time for it, including for
    the possibility that a rejected entitlement or a missing hardened-runtime flag only shows up
    there.

---

## When this file is wrong

Add to it. A limitation discovered by a human at 11pm before a release and not written down here
will be discovered again by the next person, at 11pm, before the next release.
