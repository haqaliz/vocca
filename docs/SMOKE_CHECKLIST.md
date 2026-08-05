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

   If `dev-identity.sh` refuses because the keychain is in a partial state (a certificate imported
   by an earlier run that failed or was interrupted before it was trusted), reset it rather than
   rerunning — a second certificate with the same name makes which one signs the app, and therefore
   whether TCC grants survive, a coin flip:
   `security delete-keychain ~/Library/Keychains/vocca-dev.keychain-db && rm -f ~/Library/Application\ Support/Vocca/dev-keychain.pass`

2. Sign it — **with the Release path spelled out**:
   `./Scripts/sign.sh .build/xcode-release/Build/Products/Release/Vocca.app`

   `Scripts/sign.sh` defaults to the *Debug* bundle, because that is the daily dev loop. A bare
   `./Scripts/sign.sh` here signs Debug and leaves the Release bundle carrying whatever `xcodebuild`
   gave it, which is not what step 3 then inspects and not what `Scripts/notarize.sh` submits.

   The script reads `VoccaBuildConfiguration` out of the bundle and signs Debug and Release
   differently: Debug gets `com.apple.security.get-task-allow` added so a debugger can still
   attach, Release gets `App/Vocca.entitlements` exactly. It reads the entitlements back out of the
   finished signature and fails if either rule was not met, so a silent mismatch here is a failed
   command rather than a surprise at notarization.

3. Confirm the signature is what you expect:
   `codesign -d --verbose=2 .build/xcode-release/Build/Products/Release/Vocca.app`
   — `runtime` must be inside the parentheses on the `flags=` line (`flags=0x10000(runtime)`), not
   merely somewhere in the output. The output begins with the path you passed, so "the word
   `runtime` appears" is not the same claim.

4. Confirm the entitlements are exactly one:
   `codesign -d --entitlements :- --xml .build/xcode-release/Build/Products/Release/Vocca.app`
   — `com.apple.security.device.audio-input` and nothing else; in particular **no**
   `com.apple.security.get-task-allow`, which Release must not carry. CI asserts this too; confirm
   it by eye anyway on the artefact you are actually shipping, because CI tested a bundle it built
   itself.

### Permissions, on a machine that has never run Vocca

This is the step most likely to be skipped and most likely to be broken, because it can only be done
once per machine without resetting state. Use a fresh user account or
`tccutil reset Microphone dev.vocca.Vocca` and `tccutil reset Accessibility dev.vocca.Vocca`.

5. Launch the app. Confirm **no Dock icon and no menu bar** appear (`LSUIElement`).
6. Trigger capture. Confirm the **microphone prompt appears**, and that its text is the
   `NSMicrophoneUsageDescription` string, not a generic one.
7. Grant it. Confirm audio actually arrives — that dictation produces text, not silence.
8. Deny it on a second fresh account. Confirm Vocca says something useful rather than appearing to
   work and producing nothing.
9. Confirm the Accessibility prompt appears when the global hotkey is first registered, and that
   after granting, the hotkey fires from **another app's** front window — not just when Vocca is
   frontmost.
10. Quit, rebuild, relaunch. Confirm the grants **survived** — this is what catches an identity
   regression, and it is invisible to every other check in this repository.

### Behaviour in the real world

11. Hotkey capture works while a full-screen app is frontmost.
12. Injection lands correctly in at least: a native Cocoa field (Notes), a browser field (Safari and
    Chrome), and an Electron app (VS Code or Slack). These fail differently and one working says
    little about the others.
13. The widget never takes focus: the app you were typing in stays frontmost throughout a capture.
14. Under Activity Monitor, confirm no network activity during a normal dictation cycle. CI asserts
    the invariant against the composition root; this confirms it for the shipping app, which
    contains one file (`App/VoccaApp.swift`) the probe cannot reach.

15. **Toggle mode**, which CI can reach only through the seam and never through a real tap. Press,
    release, talk, press again: confirm the microphone closed and the transcript survived, and
    confirm the hotkey's bare key (Space, for `⌥Space`) still types normally *between* the two
    presses. Both halves matter and neither is observable from the state machine's own tests:
    a lost stopping press costs **up to 120 s of open microphone** in this mode — there is no
    physical-key poll behind it — and a claim mistakenly held for the session would leave that key
    dead for the same span. This is also the only place `SessionMachine.observePhysicalKey(isDown:)`
    being deliberately mode-blind would be caught: if a session ends ~150 ms after every toggle-on,
    something is calling it past the watchdog.

16. **The implicit-`fn` key codes**, which is the one part of the hotkey path whose *completeness* no
    test can assert. Each of the 30 key codes in
    `HotkeyFlagTranslation.keyCodesCarryingFunctionImplicitly` is pinned against `Events.h`, so none
    of them is *wrong*. Nothing pins that none is **missing** — and a missing one produces no crash,
    no log and no failing test, only a binding that never fires. So it has to be pressed.

    Bind and press, confirming each starts a session on key-down and ends it on key-up:
    - a bare **`F13`** — an F-key with no legacy system action attached, so nothing else intercepts it;
    - a bare **arrow key** — these set `numericPad` *and* `fn`, so they exercise the drop rule too;
    - a bare **Forward Delete** (`fn`+Backspace on a laptop, which the HID layer delivers as
      `kVK_ForwardDelete`);
    - a bare **Home** or **End** (`fn`+Left / `fn`+Right on a laptop) — laptops have no dedicated
      key, and this is the reason those four codes are in the set at all.

    Then the **inverse**, which is the failure the founder's decision exists to avoid causing: bind
    **`fn`+`A`** and confirm it still fires. If stripping has been made unconditional, this one dies
    while all of the above still pass.

    If an **external, non-Apple keyboard** is to hand, repeat the F-key press on it. Its driver may
    set the bit differently, and that case is not reachable from any test or from Apple's
    documentation.

### The tap adapter's conformance obligations — a code review, not a gesture

*(Added 2026-08-05, `hotkey-source` phase 3.)* The tap-health policy is entirely testable and
entirely tested. **Its correctness rests on four things the adapter must do that no CI run can ever
check**, because `CGEvent.tapCreate` returns `nil` without an Accessibility grant and TCC cannot be
granted on a hosted runner. Each has a doc comment stating the obligation; a doc comment is the only
enforcement there will ever be, so it is listed here as something a human confirms before a release.

17. **`start(delivering:)` on an already-started source tears the old tap down first.** The policy
    re-creates by calling `start` once and relies on this rather than calling `stop()` itself, because
    doing both would second-guess the contract. An adapter that merely overwrote its stored port leaks
    a `CFMachPort` and a run-loop source and leaves a **second tap installed whose callback still
    points at the previous context** — a use-after-free on the next keystroke, reached by a caller who
    did everything the protocol documents. `TapHealthPolicyTests` pins this against the *fake*; the
    adapter can forget it entirely with the whole suite green.

18. **`resumeDelivery()` reads the result back.** `CGEventTapEnable` returns `Void` and cannot fail
    loudly, so an adapter that reports `.resumed` because it made the call reports a dead tap as
    healthy — and the re-creation acceptance H4 requires never happens. Confirm the implementation
    calls `CGEventTapIsEnabled` afterwards and answers from *that*.

19. **`resumeDelivery()` answers `.failed` when it holds no tap**, and **`isDelivering` answers
    `false`**. The policy tracks tap existence itself and does not ask without one, so this is
    defence in depth — which is exactly why it needs confirming rather than assuming: it is the second
    of the two places "healthy while deaf" could be reached from, and the first one shipped.

20. **`isDelivering` is a question put to the system, never a cached flag.** It is the read the ~1 s
    health poll is made of, and the whole point of that poll is to find out about a tap that died and
    told nobody. An adapter answering from a remembered value reports the last thing Vocca was told,
    which is precisely what the poll exists to bypass.

21. **The disable notifications reach `TapHealthPolicy.tapWasDisabled(_:)`, not the sink.** Routing
    `kCGEventTapDisabledByTimeout` / `…ByUserInput` into `HotkeyEventSink` ends the session correctly
    and leaves the tap dead forever — `SessionRules.swift:106-113` names that failure as a sibling of
    the stuck-microphone bug rather than a lesser cousin. Also confirm the two are **not** collapsed
    into one call: one means Vocca's own callback was too slow and the other does not.

### If notarizing

17. `Scripts/notarize.sh` has **never run end to end** — there is no Developer ID configured. The
    first real release must treat notarization as unproven and budget time for it, including for
    the possibility that a rejected entitlement or a missing hardened-runtime flag only shows up
    there.

18. It submits `.build/xcode-release/Build/Products/Release/Vocca.app` by default — the same bundle
    steps 1–4 built, signed and inspected. That is only true if step 2 was run with the Release path
    given explicitly; a bare `./Scripts/sign.sh` signs Debug and this step then submits an
    unmodified Release build.

    If it reports *"the notary service is unreachable"*, that is a network failure and **not** a
    missing credential — do not run `store-credentials` again on the strength of it. The two are
    reported differently on purpose: the older version of the script probed credentials with a
    network call and told an offline machine with perfectly good credentials that it had none.

---

## When this file is wrong

Add to it. A limitation discovered by a human at 11pm before a release and not written down here
will be discovered again by the next person, at 11pm, before the next release.
