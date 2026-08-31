# Manual smoke checklist

**A green CI badge on this repository is not a statement that Vocca works.** It is a statement that
the package compiles under Swift 6 strict concurrency, that the suite passes, and that the signed
`Vocca.app` is configured the way macOS requires. Every one of those is worth having. None of them
touches the parts of Vocca most likely to be broken.

This file exists so nobody has to guess where the line is. It states what CI structurally cannot
cover — not "has not got round to", *cannot* — and then lists what a human has to do by hand before
a release.

---

## Two rules to read every step in this file against

Both were earned in this repository, in the phase that measured the timers, and both are things a
smoke checklist violates silently — a step that breaks either of them still gets ticked.

> **1. A negative result about a state must verify the state was entered.**
>
> "I left it backgrounded for five minutes and the timer was fine" is not evidence about App Nap
> unless something checked that the process was actually being throttled. A measurement that closes a
> question which is still open is worse than not measuring, because nobody looks again. Every step
> below that asserts *nothing bad happened* names the precondition to confirm first, and says to
> **void the result** — not fail it, void it — if the precondition did not hold.

> **2. A pass criterion looser than the failure it guards accepts the failure.**
>
> A step reading *"expect the tap-health poll at about 1.8 s"* was written into this file once. The
> measured figure is ~1.2 s at its worst; 1.8 s is a poll that is genuinely broken, and the step
> would have passed it. Direction matters more than precision here: when in doubt make a criterion
> **tighter** than the number you measured, because a tight criterion fails a healthy build noisily
> and a loose one passes a broken build silently.

A corollary of both: **where no sharp criterion exists, the step says so.** Several below do. An
honest "this cannot be given a pass criterion, here is what to look at" is worth more than an
invented threshold that will be ticked without being met.

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

### 6. Secure Input — the state no test can enter

*(Added 2026-08-06, `hotkey-source` phase 6.)* When any application calls `EnableSecureEventInput` —
a password field in Safari or Chrome, 1Password, the login window, Terminal with *Secure Keyboard
Entry* ticked — **every event tap in the login session stops receiving key events**. The tap is
still created, still enabled, and `CGEventTapIsEnabled` still answers `true`. Vocca now reads
`IsSecureEventInputEnabled()` and reports `TapHealth.blockedBySecureInput`, distinctly from a tap
failure, and ends any session in flight because no key event can reach the tap to end it.

**The decision is tested exhaustively; the read is executed by nothing.** A test cannot make
`IsSecureEventInputEnabled()` answer `true`: it is a fact about other people's software, and the one
programmatic route would switch the keyboard off for every tap on the machine running the suite.
Nor is asserting that it answers `false` worth anything — it fails on a developer with a password
field focused, and it asserts nothing about the case that matters. So `SystemSecureInputState`'s one
line is confirmed by hand, in the Secure Input steps below, and by nothing else, ever.

**And it closes only half of a gap.** "Enabled and deaf" has a second instance with no API at all: a
tap created before the Accessibility grant has its event mask cleared at creation. Nothing in the
health poll can see that, and `TapHealthPolicyTests.testThePollCannotSeeATapThatIsEnabledAndDeafForAReasonWithNoRead`
measures what it costs — 120 s of open microphone in both activation modes. It is unreachable today
only because a mask with no keyboard bits left makes `tapCreate` return `NULL`, which is the honest
error. Step 49 is why that must stay true.

### 7. A real window drag, and a real App Nap

The run-loop-mode hazard (**H10**) is *mostly* covered now and it is worth knowing which part:
`MainRunLoopTimerTests` registers `.eventTracking` exactly as AppKit does and fails the build if the
shipped timer stops firing through it, and `Scripts/measure-timers.sh menu` drives a genuine
`NSMenu` tracking session unattended. **Menu tracking is therefore not a manual step.** A window
drag still is — nothing available here can drive one — and so is App Nap on battery or with the
display asleep, which no runner can be put into.

### 8. Real injection into real apps — the ladder's adapters

*(Added 2026-08-09, `injection-adapters` phase E.)* The ladder's *decisions* run headless in CI —
the allowlist gate, the per-app rung order, the never-clobber clipboard restore, the verification
interpretation — all over injected seams. The adapters that speak the real APIs are executed by
nothing a hosted runner can run: the AX rung's calls need per-app Automation grants that TCC only
ever gives a human (§1's wall, applied per application), the clipboard rung's real `NSPasteboard`
is session-bound and its ⌘V needs keystroke synthesis through the same grant, and the Secure Input
read is §6's fact about other people's software. So each adapter is translation with no decisions
in it, its one-file-per-family confinement is pinned by lint, and the matrix steps below are the
only execution the adapters will ever get — including the one thing no read-back can answer:
whether the text landed in the *right field of the right app*, which is a fact about the
application, not about Vocca.

---

## What CI does cover

Stated positively, so the checklist below does not re-check things a machine already checked:

| Job | Proves |
|---|---|
| Headless suite | The package builds with **zero** strict-concurrency warnings, and all tests pass: module boundaries, licence headers, the package manifest, and the zero-network invariant (with the settle window raised to 6s). It also **measures** two things that used to be on this list: the run-loop-mode **mechanism** (a `.default`-mode timer delivers none of its due fires through an event-tracking gesture; the shipped `.common` one delivers all of them), and    every decision about Secure Input over an injected read, and the injection ladder's whole decision surface — allowlist gate, per-app rung order, never-clobber clipboard restore, verification interpretation — over injected seams, and the failsafe surface's reducer and the recovery journal's logic (durable-before-return, bounded eviction, purge-on-resolve) over injected seams and a temp-directory store (§8 is the half CI cannot reach). The 0-of-33 figures quoted elsewhere come from `Scripts/measure-timers.sh`, at 150 ms over 5 s, **which CI does not run** — `MainRunLoopTimerTests` runs at 20 ms over 0.4 s, about twenty fires. It does **compile** that harness (`Tools/TimerProbe`, which no `swift build` sees), so the steps below that tell you to run it are steps you can still run; it cannot execute one, because a hosted runner has no window server session. |
| Bundle contract (Debug) | A real `xcodebuild` Debug build produces a signed `Vocca.app` whose processed `Info.plist` and embedded entitlements match the checked-in sources, with the hardened runtime actually in the signature. |
| Bundle contract (Release) | The same for Release, **plus** that the Release bundle carries no entitlement beyond what `App/Vocca.entitlements` declares — in particular not `com.apple.security.get-task-allow`, which Debug is allowed and Release is not. |

---

## Manual steps before a release

Run these on a Mac, on the build you intend to ship, in order. Record the result; an unrun step is a
failed step.

> **What the release workflow automates and what this is:** `.github/workflows/release.yml` (tag
> `v*`) runs the suite, builds Release, signs with the imported identity, re-runs the suite against
> the signed bundle, and uploads `Vocca-macos.zip` to a GitHub Release. This checklist is not that —
> it is the *proof* path the workflow structurally cannot run: real-microphone capture, real TCC
> prompts, real Accessibility grants, real injection into other apps, on a machine that has never
> run Vocca. Steps 1–4 (build/sign/verify) overlap what the workflow does; the rest of the checklist
> is the reason a tag push must wait until these have passed on a real Mac.

### Build and identity

1. `./Scripts/dev-identity.sh` if this machine has no stable identity yet, then build Release:
   `xcodebuild -project Vocca.xcodeproj -scheme Vocca -configuration Release -derivedDataPath .build/xcode-release ARCHS=arm64 build`

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

   **On a machine with only the self-signed identity, add `--local-dev` or the app will not start
   at all.** The hardened runtime's Library Validation requires embedded frameworks to share the
   app's Team ID, and the self-signed identity has none — so `dyld` refuses to map the embedded
   `whisper.framework` and the process dies before `main()`. Vocca is `LSUIElement`, so this looks
   identical to a normal launch: nothing happens, and nothing is reported.

   Name the divergence rather than forgetting it: a `--local-dev` bundle carries
   `com.apple.security.cs.disable-library-validation`, which the shipped bundle must not, so
   **steps 3 and 4 are then inspecting an entitlement set that is not the release one**, and the
   bundle must never be handed to `Scripts/notarize.sh`. The clean way to run this section is a
   Developer ID identity (`VOCCA_DEV_IDENTITY_NAME`), which satisfies Library Validation through
   the framework re-signing `sign.sh` already does and needs no flag. Until one exists, run steps
   3-4 on the flagless Release bundle to check the signature, and re-sign with `--local-dev` for
   the steps that actually launch the app.

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

    On a fresh install these gates are not met ad hoc — the five-step onboarding window
    (`first-run-permissions`) presents them, one at a time, and steps 81–86 are that flow's
    execution. The rows above remain the direct per-gate checks this block has always been; the
    flow is the shape they take on a machine that has never run Vocca.

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

17. **The first real model download** (`model-downloader`, the one network path CI never executes
    a byte of — the `DefaultModelTransport` is the adapter, and its URLSession code is exercised
    only by a real transfer). This step doubles as the F1 spike's provisioning and generates the
    manifest's checked-in content:
    - Download the artifact once (`FluidInference/parakeet-tdt-0.6b-v3-coreml`) and record the
      file list, sizes and SHA-256s into the pinned manifest JSON.
    - Drive a full `ModelStore.downloadIfMissing` with the default transport and confirm progress
      reaches 1.0, every file verifies, and `isPresent` flips true only at commit.
    - **Kill the process mid-download**, re-run, and confirm it resumes from the `.part` size — a
      Range request, not a restart — and that no file was re-downloaded from zero.
    - Watch the progress surface with the network interface down at the *end*: an already-present
      verified model must never touch the network (immutability, `PRODUCT_SPEC.md:273`).

    **Partly run, 2026-08-25 — and it found the defect this step exists to find.** A full
    `downloadIfMissing` against the real repository completed on founder hardware: 22 files,
    470 MB (matching the F1 spike's recorded artifact size), every file verified, the `verified`
    marker committed, and the engine prepared on the next launch.

    It only got that far after a fix. The checked-in manifest declared `config.json` as 2 bytes
    with the SHA-256 of the literal string `{}` — a placeholder, not a measurement. The real file
    is 475 bytes, so verification failed with `checksumMismatch(file: "config.json")`, the marker
    was never committed, and **the default engine could not be provisioned on any machine** since
    the manifest landed in `ac381d0`. The other twelve small entries were re-verified against the
    repository and all matched, so exactly one entry was ever wrong. Corrected in the
    `fix/local-dev-launch` branch.

    Read that as a caution about this whole step rather than a closed item: a manifest generated
    by a partial run of it looks exactly like one generated by a complete run, and nothing
    downstream can tell the difference — CI cannot reach the model, and the env-gated WER tests
    take an *already-provisioned* `VOCCA_MODEL_DIR` and so never exercise provisioning. The
    whisper manifests were generated the same way and have still never been downloaded.

    Still unrun here, and still the reason this step stays open: the mid-download kill and resume
    (the `.part` Range request), and the network-down immutability check at the end.

18. **The first real transcription** (`parakeet-engine` — the adapter is executed by nothing in
    CI, ever; this step is its only execution). On founder hardware, airplane mode **on** (the
    C2 acceptance's offline clause, `CAPABILITY_ROADMAP.md:60`, at the smoke level):
    - Prepare the engine against the real store + default transport with the model present, and
      transcribe `Tests/Fixtures/spike-clip.wav`; the transcript must match the golden text in
      `Tests/Fixtures/FIXTURES.md` (this is the word-perfect check the spike measured at RTF
      ~0.012 on M4 Max).
    - `prepare()` twice must load once (warm load-once): the second call returns without a
      second load, observed via timing or logs.
    - `prepare()` with the model *absent* must throw `modelUnavailable` with an honest reason —
      never a silent dead end — and a later `prepare` after the download succeeds (retry).
    - With the network interface down the whole time: **zero network activity** — the offline
      flag is enforced structurally, and the interposer covers the probe, so this confirms it
      for the shipping path.

### The second ASR engine — whisper.cpp

*(Added 2026-08-11, `second-asr-engine`.)* Step 18's "the adapter is executed by nothing in CI,
ever" is true twice now: `WhisperCppEngine`'s Metal inference runs no line in any hosted runner, and
the picker panel (step 20) needs a window server. The whisper real-run test shares step 18's
mechanism — the `VOCCA_MODEL_DIR` gate — but **its real run has not happened yet**: the tolerances
`WhisperCppEngineWERTests` asserts are *seeded from Parakeet's table, not measured on whisper's
output* (the only place either table lives is the test files; the mechanism is
`docs/planning/second-asr-engine/fixture-harness/tolerances_20260810.md`). Every line below is
therefore a first execution, not a re-check.

19. **The whisper engine's first real WER run.** The mirror of step 18 with a different provision:

    - Provision the whisper artifacts, then run the whisper test:
      `./Scripts/provision-asr-fixtures.sh --engine whisper-large-v3-turbo` (and the q5_0 tier),
      then `WhisperCppEngineWERTests` with `VOCCA_MODEL_DIR` set to the store-shaped install.
    - *Pass:* all six fixtures within their tolerances, attribution carrying `whisper-large-v3-turbo`
      — with the numbers still **provisional**: copied from Parakeet's first real run as the
      mechanism's required starting point (`PRD M6`), not yet replaced by measured whisper values.
    - Record the per-fixture WERs (the runner's violation errors carry the full ledger) and the
      run's machine + artifact hashes; they are the measurement that re-baselines the tolerance
      table in exactly the two test files.
    - Until this step has been run once, everything this repository says about whisper's accuracy
      is a claim about structure, not about measurement.

20. **The engine picker panel — switch, tier, download.** `EnginePickerView` is executed by nothing
    in CI (a hosted runner has no window server), and its headless half is tested: the
    never-auto-switch rule (a session resolves the engine once, at start — a mid-session selection
    change can never swap the engine under a running session, and the *next* session reads the
    *new* selection, `PRODUCT_SPEC.md:189-196`).

    *Gesture:* in the Speech tab — switch engine Parakeet ↔ Whisper and confirm the honest tradeoff
    copy appears per row; select the Whisper tier (turbo / q5_0 — a model choice, not a different
    engine, so switching tiers must not restart anything); trigger the download and watch the
    progress window reach a verified commit, with Cancel terminating in the state returning to
    idle. Then switch the engine **mid-session** if a session can be started (not yet — no audio
    capture; this is recorded as the first execution once C1's loop exists).

    *Pass:* installed rows show installed; a failed download rests visible with its affordance —
    never auto-retried; the selection the session runs under is the one current at its start.

21. **The weights-license record sign-off.** `docs/planning/second-asr-engine/model-lifecycle/license_20260810.md`
    is **DRAFT**: the whisper.cpp and ggml MIT entries were verified live from primary sources, but
    the converted GGUF weights' own provenance is an open item for the founder's judgment
    (accept the Hugging Face repo's `License: mit` declaration, or have OpenAI's primary source
    fetched and recorded first). Nothing ships as licensed until the record is signed and
    `THIRD_PARTY_NOTICES.md`'s weights entry drops its "pending founder sign-off" parenthetical —
    in the same commit.

### The injection ladder — real apps, which no CI run touches

*(Added 2026-08-09, `injection-adapters` phase E — the matrix PRD R10 demands, `ROADMAP.md:89-91`;*
*step 12 is this section's coarse version.)* Every adapter on the ladder is executed by nothing in
CI (§8): the AX rung needs per-app Automation grants, and the real pasteboard and the ⌘V need a
live session and the same grant. The matrix below is the P0 gate's evidence (`ROADMAP.md:95`) and
the only execution the adapters ever get.

The gesture is the same in every row: **dictate a fixed short phrase** ("the quick brown fox jumps
over the lazy dog"), let the ladder run, then select all, copy, and compare with `pbpaste` —
**byte for byte** — against the phrase, the discipline of step 46. The comparison is against the
transcript Vocca captured, not against your intention: with a clean phrase and the shipped engine
(word-perfect on founder hardware, step 18) the two are the same text, and the distinction is
load-bearing because an ASR mishearing is not an injection failure — what must land verbatim is the
field *versus the transcript*.

*Pass* in every row is the same: the field holds the transcript **cleaned by the shipped rules,
which for a clean phrase is the transcript itself** verbatim and no failsafe appears.
*Failure* in every row is the same shape and must never be silent: the failsafe shows with a
plain-language reason (`PRODUCT_SPEC.md:109-114`) — a report of success with nothing in the field is
the exact silent success the read-back verification exists to catch, and a row that ends that way
is a bug, not a pass. The ladder's log names the rung that landed each insertion
(`.accessibility`, `.clipboardPaste`, `.keystrokeSynthesis`), and every row states which one it
expects.

> **What C8's strategy memory changes about these rows, and what it does not** (memory-order
> aspect, 2026-08-27). The ladder now remembers per application, so a matrix row run **twice**
> can legitimately name different rungs: the first run discovers, the second starts at what
> worked. Run each row on a fresh memory — delete `~/Library/Application Support/Vocca/strategies.json`
> before the matrix — or the rung a row names is the memory's answer rather than the ladder's.
> Two rows keep their expectation for a new reason: Slack (step 23) and Google Docs in Chrome
> (step 24) are the **seeded hostile set** (`SeededHostileApps`), so their `.clipboardPaste`
> result is now seeded rather than incidental. Nothing in the memory can promote an application
> to the accessibility rung without a **read-back-verified** AX win, and no promotion is even
> attempted until a re-probe window (7 days, provisional) has elapsed — so within one matrix
> session, no row's rung can change because of learning alone.

22. **Native AppKit: Notes, Mail, TextEdit** — the three seeded applications
    (`SeededInjectionAllowlist`), the only ones the accessibility rung is offered first.

    *Gesture:* dictate the phrase into a new note in Notes; into the body field of a new message
    in Mail; into a plain-text document in TextEdit (⌘⇧T — rich text reflows and defeats the byte
    compare).

    *Pass:* the log names **`.accessibility`** in all three and the field holds the transcript
    verbatim.

    *Failure:* an allowlisted app that did not land via accessibility. Either the rung reported
    failure and the ladder fell to clipboard (the log names `.clipboardPaste` — an honest drop,
    worth understanding), or the failsafe appeared. What is **not** acceptable: `.accessibility`
    named with nothing in the field — that is the read-back verification lying, or an adapter
    reporting a success it did not verify.

23. **Electron: VS Code, Slack** — not seeded, the AX-lies class, so clipboard leads.

    *Gesture:* dictate the phrase into a VS Code text buffer; into a Slack message input.

    *Pass:* the log names **`.clipboardPaste`** and the field holds the transcript verbatim — the
    field swallows the paste exactly as it swallows the user's own ⌘V.

    *Failure:* the failsafe appears with the exhausted reason — never a silent nothing. The
    per-app-denied variant is step 29.

24. **Browsers: Safari and Chrome — a plain field, and Google Docs' custom editor.**

    *Gesture:* dictate into a plain web input in Safari and in Chrome; then into a Google Docs
    document — the custom editor, which is neither a native field nor a plain input, and the
    matrix's named hostile-to-AX case (`ROADMAP.md:91`).

    *Pass:* `.clipboardPaste` named, verbatim in all three. Google Docs is the row where
    paste-vs-AX earns its keep: the text must land in the document, not in the hidden textarea it
    was pasted into.

    *Failure:* failsafe with the exhausted reason. A Docs row that fails while Safari's passes is
    expected to happen — they fail differently, which is why the row exists.

25. **Terminals: Terminal, iTerm2, Ghostty.** A terminal is a shell before it is a field, so the
    rung matters less than what the shell does with the text.

    *Gesture:* at a `$` prompt in each, dictate the phrase. Nothing executes until ⏎ is pressed,
    so the check is the text sitting at the prompt uninterpreted. Run the row with *Secure
    Keyboard Entry* unticked — ticked, it is the Secure Input class (step 27, and the capture side
    in steps 55–57).

    *Pass:* the phrase sits at the prompt exactly once, byte-identical, and no shell error or
    continuation prompt appears.

    *Failure:* the failsafe; or the phrase split, dropped, or interpreted (a `>` continuation
    prompt means a line got split).

26. **Java/other: IntelliJ.** The AWT field class — one working native field says nothing about
    it, which is why the matrix names it.

    *Gesture:* dictate the phrase into an editor buffer.

    *Pass:* verbatim, `.clipboardPaste` (not seeded).

    *Failure:* failsafe with the exhausted reason.

27. **Known-hostile: a Secure Input field, and 1Password — injection refuses, and no rung is
    attempted.** The injection side of the Secure Input story; the capture side is steps 55–57,
    and both read the same `IsSecureEventInputEnabled` — this read at injection time, fresh
    (PRD R2).

    *Gesture:* get a transcript into the failsafe by any route, then click into a password field
    in Safari or Chrome (or open 1Password — either engages Secure Input), and press ⏎ to re-run
    the ladder against the current focus. The failsafe window never takes focus, so the password
    field stays focused, and Secure Input is on — which is the only way this read can answer.

    *Pass:* the failsafe shows the password-field copy — "This looks like a password field. Vocca
    won't type into it — press ⌘C to paste it yourself." (`PRODUCT_SPEC.md:111`) — the ladder's
    log records `attempted: []` (**no rung was attempted — not even clipboard**), and the full
    transcript is still present and copyable.

    *What a pass is not:* the clipboard rung being tried anyway (pasting into a password field is
    the failure this row exists to forbid), or a silent drop with no failsafe.

28. **Clipboard-manager coexistence: Raycast, Alfred, Paste, Maccy.** The 100-dictation survival
    clause (`ROADMAP.md:85`).

    *Gesture:* with a clipboard manager running, copy a sentinel string ("vocca clipboard
    sentinel"), then dictate the phrase into Notes **100 times in a row**. The manager is free to
    take ownership of the pasteboard at any point — that is its job, and the never-clobber rule
    (`ARCHITECTURE.md:408-414`) is why the ladder does not fight it.

    *Pass, both halves:* all 100 land verbatim (nothing lost), and after the run the sentinel is
    still recoverable — it sits in the manager's history exactly as copied, and a fresh paste
    returns the manager's latest capture, **never** a leftover Vocca transcript and never an empty
    pasteboard. Vocca's save/set/paste/restore round-trip must be invisible to the user's
    clipboard.

    *Why the sentinel:* with a manager running, "the clipboard still has my text" is a test the
    manager passes for Vocca's own transcript too; the sentinel distinguishes "the manager owns
    history" from "Vocca left a write behind".

29. **Per-app Automation permission denied — the honest drop to the clipboard rung.**

    *Gesture:* in System Settings ▸ Privacy & Security ▸ Automation, deny Vocca's Automation
    permission for Notes (deny the first prompt, or revoke an existing grant — TCC grants per
    app, and this cannot be granted on a runner), then dictate the phrase into Notes.

    *Pass:* the text **still lands verbatim** — the log names `.clipboardPaste` after
    `.accessibility` reported failure. The drop is honest: the rung reports the truth about the
    denial and the ladder falls through, instead of reporting a success it did not have or
    skipping the rung entirely. Re-granting the permission and re-dictating restores step 22's
    `.accessibility` landing.

    *What this step guards:* an adapter that reports `succeeded` for an AX call the TCC layer
    denied — the silent-success class, on the one rung the verification exists to police.

30. **Failsafe copy-without-focus: ⌘C while the target app keeps focus.** The product promise
    (`PRODUCT_SPEC.md:106`): the failsafe window shows, never takes focus, and ⌘C copies.

    *Gesture:* get the failsafe showing with a full transcript (any row above, or step 27's
    refusal), then click back into the target app so it is frontmost with its field focused — the
    failsafe must remain showing (it never auto-dismisses, `PRODUCT_SPEC.md:104`). Press ⌘C.

    *Pass:* `pbpaste` returns the **full transcript**, byte-identical; the target app stayed
    frontmost and focused the whole time (the failsafe never took focus — nothing in the target
    app lost focus, and no second click was needed to use it); the failsafe is still showing
    afterwards.

    *Failure:* the transcript pastes into the target field directly (that is paste, not copy); or
    focus jumped to the failsafe (the window took focus — the widget-steals-focus failure); or
    the failsafe dismissed itself.

*(Added 2026-08-09, `failsafe-surface` phase D — the window, the retry loop and the journal's real
store are executed by nothing in CI: the panel needs a live window server, its ⌘C needs the real
pasteboard, and the journal's `FileManager` file only ever runs against a temp directory in the
suite.)* The failsafe reducer's decision table and the journal's logic (durable-before-return,
bounded, purged) are CI-tested; the five steps below are the surface's only other execution.

31. **The failsafe appears on ladder exhaustion — and persists.** The never-auto-dismiss promise
    (`PRODUCT_SPEC.md:99-104`): the reducer contains no time-based transition at all, so nothing
    dismisses the window but the user.

    *Gesture:* dictate the phrase into an app the ladder cannot land in — or revoke Automation for
    an allowlisted one (step 29) — and leave the failsafe showing. Keep working in the target app;
    do not touch the window for several minutes.

    *Pass:* the window is still showing, with the same transcript and the same cause-specific
    reason, however long it sits — no auto-dismiss, no dimming, no re-stacking — and the transcript
    is still selectable and copyable throughout.

    *Failure:* the window dismissed itself, changed its copy, or stopped responding. A
    self-dismissal is a regression of the one claim this surface exists to make, not a tweak.

32. **⌘C while the target app keeps focus — the non-activating panel's key equivalent.** Step 30
    proved the copy *lands*; this step proves the *routing*: the ⌘C key equivalent is handled on
    the panel, so the copy works without the panel ever taking focus.

    *Gesture:* with the failsafe showing (any row above), click back into the target app so its
    field is focused, then press ⌘C, and again a few seconds later.

    *Pass:* `pbpaste` returns the full transcript byte-identical after **both** presses (each ⌘C
    writes the same full text — idempotent); the target app stayed frontmost and focused throughout,
    with no second click anywhere; the failsafe is still showing.

    *Failure:* the target app consumed the ⌘C as its own copy (the key equivalent was not routed),
    focus jumped to the panel (the non-activating claim is false), or a repeat press wrote a partial
    text.

33. **⏎ retry re-runs the ladder against a freshly clicked field.** The retry affordance
    (`PRODUCT_SPEC.md:116`): the target is re-resolved at retry time, never reused from the failed
    run.

    *Gesture:* get the failsafe showing, click into the **correct** field of the target app, and
    press ⏎.

    *Pass:* the ladder re-runs and the transcript lands in the newly focused field — the log names
    the rung that landed it and the failsafe is gone. If the re-run fails, the failsafe returns to
    showing with the same transcript retained — a failed retry never loses the text — and the
    updated reason (`.noFocusedField` when the re-resolution found no field).

    *Failure:* the retry landed in the *old* field (focus was not re-resolved), or the transcript
    vanished between the failed retry and the window's return.

34. **Relaunch recovery: the failsafe reappears with its captured-at note.** The journal write is
    durable before the window ever shows (the ordering the suite asserts); this is the relaunch half
    only a human can run.

    *Gesture:* get the failsafe showing with a full transcript, quit Vocca (⌘Q), relaunch.

    *Pass:* the failsafe reappears showing the same transcript, with its "captured at" note
    (`PRODUCT_SPEC.md:117`) — loaded back from `~/Library/Application Support/Vocca/recovery/` —
    and copy and retry work exactly as before the quit.

    *Failure:* the failsafe does not reappear, or the transcript is empty, truncated, or missing
    the captured-at note.

35. **The journal: bounded on disk, purged on resolve.** The single-slot seam means at most one
    held transcript at a time; the cap and the oldest-first eviction are suite-asserted, and this
    step is the purge half a human can see.

    *Gesture:* with the failsafe showing, list `~/Library/Application Support/Vocca/recovery/` —
    exactly one entry file. Resolve the transcript (⌘C then ✕, or a successful ⏎ retry), then list
    again.

    *Pass:* the directory is empty after the resolve, on both routes — the entry is gone, not
    renamed or truncated — and while a transcript is held the directory holds exactly one file. A
    stale or foreign file left in the directory must never block the journal (a corrupt entry is
    skipped, not fatal).

    *Failure:* the entry survives the resolve, a second hold writes a second entry (unbounded
    growth), or the journal refuses to start with a stale entry present.

### The tap adapter's conformance obligations — a code review, not a gesture

*(Added 2026-08-05, `hotkey-source` phase 3.)* The tap-health policy is entirely testable and
entirely tested. **Its correctness rests on five things the adapter must do that no CI run can ever
check**, because `CGEvent.tapCreate` returns `nil` without an Accessibility grant and TCC cannot be
granted on a hosted runner. Each has a doc comment stating the obligation; a doc comment is the only
enforcement there will ever be, so it is listed here as something a human confirms before a release.

36. **`start(delivering:)` on an already-started source tears the old tap down first.** The policy
    re-creates by calling `start` once and relies on this rather than calling `stop()` itself, because
    doing both would second-guess the contract. An adapter that merely overwrote its stored port leaks
    a `CFMachPort` and a run-loop source and leaves a **second tap installed whose callback still
    points at the previous context** — a use-after-free on the next keystroke, reached by a caller who
    did everything the protocol documents. `TapHealthPolicyTests` pins this against the *fake*; the
    adapter can forget it entirely with the whole suite green.

37. **`resumeDelivery()` reads the result back.** `CGEventTapEnable` returns `Void` and cannot fail
    loudly, so an adapter that reports `.resumed` because it made the call reports a dead tap as
    healthy — and the re-creation acceptance H4 requires never happens. Confirm the implementation
    calls `CGEventTapIsEnabled` afterwards and answers from *that*.

38. **`resumeDelivery()` answers `.failed` when it holds no tap**, and **`isDelivering` answers
    `false`**. The policy tracks tap existence itself and does not ask without one, so this is
    defence in depth — which is exactly why it needs confirming rather than assuming: it is the second
    of the two places "healthy while deaf" could be reached from, and the first one shipped.

39. **`isDelivering` is a question put to the system, never a cached flag.** It is the read the ~1 s
    health poll is made of, and the whole point of that poll is to find out about a tap that died and
    told nobody. An adapter answering from a remembered value reports the last thing Vocca was told,
    which is precisely what the poll exists to bypass.

**And one thing a conforming adapter still cannot do**, so that this list is not read as the whole of
it: the health poll asks `CGEventTapIsEnabled`, which catches a tap that was *disabled* silently and
**not** one that is enabled and deaf — created successfully, reporting itself enabled, delivering
nothing. Two known instances: a mask cleared at creation before the Accessibility grant, and Secure
Input. **Phase 6 closed the second and left the first**, because only the second has an API
(`IsSecureEventInputEnabled`); see "What CI cannot cover" §6 and steps 55–57. For the first, step 15's
toggle-mode check and step 49's note are still the only places it would be noticed at all.

40. **The disable notifications reach `TapHealthPolicy.tapWasDisabled(_:)`, not the sink.** Routing
    `kCGEventTapDisabledByTimeout` / `…ByUserInput` into `HotkeyEventSink` ends the session correctly
    and leaves the tap dead forever — `SessionRules.swift:106-113` names that failure as a sibling of
    the stuck-microphone bug rather than a lesser cousin. Also confirm the two are **not** collapsed
    into one call: one means Vocca's own callback was too slow and the other does not.

### The tap itself, which no CI run executes a line of

*(Added 2026-08-06, `hotkey-source` phase 6, from phases 4 and 5.)* Every line of
`Sources/VoccaHotkey/CGEventTapSource.swift` is unreachable in CI — `CGEvent.tapCreate` returns
`nil` without an Accessibility grant — so these are the gestures that execute it. They are ordered
by what their failure costs, not by convenience.

41. **Time how long the microphone indicator takes to go out after a disablement.** The most valuable
    step in this file, because the two builds it separates are indistinguishable in every other way.

    *Gesture:* start a session, then provoke `kCGEventTapDisabledByTimeout` by holding the main
    thread — attach a debugger and break during a keystroke is the reliable way — and **record the
    screen while you do it** (`⌘⇧5`, 60 fps).

    *Pass:* macOS's orange microphone indicator is out **within 500 ms** of the disablement — 30
    frames at 60 fps, so count them rather than judging by eye. That is the disablement observer
    being held and its synchronous half running.

    *What the criterion is guarding, so it is not loosened:* if `CGEventTapSource.disablementObserver`
    is `nil` — which is what an owner holding the policy instead of the observer produces, with no
    error anywhere — **both halves of a disablement are lost**, and the session is closed by the ~1 s
    health poll instead. That is ≈1 s, or ≈1.2 s under task suppression. A criterion of "about a
    second" would accept exactly the build this step exists to catch. Stopwatch-by-hand is not
    precise enough here; use the recording.

42. **Force a re-creation, then type exactly one character.** The re-start path — `stop()` at the head
    of `start(delivering:)` — and the only thing standing between a caller who does everything the
    protocol documents and a use-after-free.

    *Gesture:* with the hotkey armed, force a re-creation (sleep and wake the machine, or revoke and
    re-grant Accessibility in System Settings), then type `x` once in TextEdit.

    *Pass:* exactly **one** `x` appears, the hotkey still starts a session afterwards, and nothing
    crashes in the following minute of ordinary typing. A leaked second tap on a stale context
    presents as a doubled character or as a crash on the **next** keystroke — never on the
    re-creation itself, which is why "it re-created fine" is not this step.

43. **Quit while armed**, once mid-session and once armed but idle, then type in another app for ten
    seconds.

    *Pass:* no crash and **no missing characters** — type a known string and compare it, rather than
    judging that it "looked fine". This is `deinit { tearDown() }`; without it a live tap goes on
    calling a C function whose context is freed memory, system-wide.

44. **Provoke a disablement while a drag or a menu is tracking.** H10 covers the tap's own run-loop
    source (`CFRunLoopAddSource`); the deferred recovery is a *different* call
    (`CFRunLoopPerformBlock` + `CFRunLoopWakeUp`) with the same exposure and no test that can see it.

    *Gesture — and it is named, because step 41's method does not work here.* Step 41 provokes
    `kCGEventTapDisabledByTimeout` by attaching a debugger and breaking during a keystroke, which
    halts the process: nothing is then tracking, so the gesture this step asks for cannot be held.
    Use `kCGEventTapDisabledByUserInput` instead, which is reachable without stopping the process —
    **open a menu and hold it open, then toggle Accessibility for Vocca off and on in System
    Settings.** If you would rather keep the timeout route, post a `sleep(3)` onto the main thread
    from a debugger console *before* starting the drag, then start dragging within those three
    seconds. If neither is practical on the machine in front of you, record it as **not performed**,
    the way step 47 records its unavailable case. A step whose gesture is unperformable as written is
    a step that gets ticked.

    *Pass:* the tap recovers **before the gesture ends** — press the hotkey while still dragging or
    while the menu is still open, and confirm a session starts. Recovery only once the gesture ends
    is the failure.

45. **Release Option while still holding Space.** The one gesture that distinguishes an event mask
    with `flagsChanged` in it from one without, and nothing else in this document exercises what that
    bit buys.

    *Gesture:* hold `⌥Space`, speak, then lift **Option** only, keeping Space down.

    *Pass:* the widget leaves the recording state at that instant — **before** Space comes up. If it
    waits for Space, stop rule (b) is not firing. (This is a latency and extensibility failure, not a
    hot mic: rule (a) still ends the session at key-up.)

46. **`⌥Space` must eat nothing and type nothing — with the negative control, which is the half that
    makes it mean anything.**

    *Gesture:* in TextEdit (`Format ▸ Make Plain Text`), type a known sentence with Vocca armed;
    then press `⌥Space` armed; then quit Vocca and press `⌥Space` again. Select all, copy, and run
    `pbpaste | xxd | tail -3` in Terminal.

    *Pass:* the sentence is byte-identical to what you typed; the armed `⌥Space` contributes **no
    bytes at all**; and the unarmed one contributes exactly `c2 a0` — U+00A0 NO-BREAK SPACE. Without
    that last assertion a permanently-swallowing tap and a correctly-swallowing one look identical,
    and the permanently-swallowing one eats the user's whole keyboard.

47. **Hold the hotkey down with no hand on the keyboard.** `CGEventSourceKeyState` is asked with
    `.combinedSessionState`, and nothing distinguishes that from `.hidSystemState` or `.privateState`
    except a key that is *logically* down and *physically* is not.

    *Gesture:* with Vocca armed and hold-to-talk bound to `⌥Space`, run `cliclick kd:alt kd:space`
    from Terminal and take your hands off the keyboard.

    *Pass:* a session starts and is **still running 2 s later**. Then `cliclick ku:space ku:alt` and
    confirm it ends.

    *What it discriminates, and why the gesture is inverted:* an earlier version of this step
    released the key by a second route — a second keyboard, or a posted key-up — and **could not
    fail for the reason it exists.** Both of those deliver a genuine `.keyUp` for the bound key code
    to the tap, and stop rule (a) ends the session on that event via `matchesKey` without consulting
    `PhysicalKeyStateReader` at all (`HotkeyEventSource.swift:67-68` says so explicitly). The session
    therefore ended under all three state IDs. Posting only the key-*down* removes rule (a) from the
    picture: `.combinedSessionState` includes events posted into the session, so `isKeyDown` answers
    `true` and the session runs on; `.hidSystemState` reads the hardware alone — no key is physically
    down — so stop rule (f) ends it inside one 150 ms watchdog tick and the step fails within the
    first quarter-second. `.privateState` behaves as `.hidSystemState` does for a key posted by
    another process.

    *If `cliclick` (or an equivalent way to post events) is unavailable:* **this step cannot be
    performed.** Record it as not performed. It is not a pass.

48. **Disarm mid-session.** The manual counterpart to the Critical that phase 5's review found: the
    forward from the wrapper an owner holds to the policy's `disarm()` was, for one commit, held by no
    test at all.

    *Pass:* the microphone indicator goes out, **and** subsequent keystrokes reach the focused app —
    both halves, because a disarm that stops the clock without stopping the tap looks identical to a
    working one until you type.

49. **A note rather than a gesture: if the event mask ever gains a non-keyboard event type, H5 stops
    holding.** `CGEvent.h:274-280` — the keyboard bits are cleared at creation when there is no grant,
    and `tapCreate` returns `NULL` *only* if that leaves the mask empty. One mouse bit therefore yields
    a successful creation, a `.started` report, and a permanently deaf hotkey with **no honest error
    anywhere** — and it is the mask-cleared instance of "enabled and deaf", which the health poll
    cannot see. It changes what a green CI badge means, which is why it is written down here.

### The timers, which is where the last hot mic hides

50. **Stop a *toggle* session mid-drag** — the H10 hazard applied to the **tap's** run-loop source,
    which is the half step 51 does not cover.

    *Gesture:* start a **toggle** session, grab a window's title bar and keep dragging, and press the
    hotkey again mid-drag without letting go of the mouse.

    *Pass:* the session ends and the microphone indicator goes out within about 300 ms of the second
    press, **while the drag is still in progress** — not when you let go of the window.

    *Why toggle, and why the press rather than a release:* this step used to be a hold-to-talk
    session with the hotkey released mid-drag, and it was **looser than either failure it guards.**
    In hold-to-talk two independent mechanisms end that session and they live on different run-loop
    registrations — the key-up, delivered through the tap's `CFRunLoopAddSource`
    (`CGEventTapSource.swift:211`) → stop rule (a); and the physical-key poll, delivered by the
    watchdog's `RunLoop.main.add(timer, forMode:)` (`MainRunLoopTimer.swift:202`) → stop rule (f),
    within 150 ms. Either alone met the criterion, so the step passed with a `.default`-mode timer
    *and* passed with a `.default`-mode tap source; it failed only if both were broken, while its
    rationale quoted the timer measurement as though it tested the timer. Toggle has no physical-key
    poll, so only a delivered event can end this session: with the tap's source in `.defaultMode` the
    second press is not delivered until the drag ends, and the only remaining backstop is the 120 s
    ceiling.

    *Why 300 ms:* measured, the shipped `.common`-mode timer's worst gap through a tracking gesture
    is 151 ms, and a `.default`-mode one delivered **0 fires in 5 s** — the gap is the whole gesture.
    So anything that ends only at the end of the drag is the failure, and 300 ms is comfortably above
    the healthy build and far below the broken one. `Scripts/measure-timers.sh runloop --window`
    prints live counters and the run-loop mode it observed if you want the numbers rather than the
    indicator.

51. **The ceiling, through a drag, in toggle mode** — the same hazard at its worst, because toggle has
    no physical-key poll behind it and the 120 s ceiling is all there is.

    *Gesture:* start a **toggle** session, then drag a window continuously for a little over two
    minutes.

    *Pass:* the session ends **while you are still dragging**, no later than ~122 s after it started.
    (120 s ceiling, one 150 ms watchdog tick, and a quarter-second of slack for the throttle in step
    49. Not "about two minutes": a session that ends when the drag ends has failed even if the drag
    lasted 121 s.)

    *This, and not step 50, is the **timer's** step.* Toggle has no physical-key poll and no key-up
    rule, so the ceiling is the only thing that can end this session and the watchdog's timer is the
    only thing that can deliver it — which is what isolates `RunLoop.main.add(timer, forMode: .common)`
    from the tap's own run-loop registration. Step 50 covers that registration; this covers the timer.
    The pair is deliberate, because a step that passes when either half works measures neither.

52. **App Nap on battery — and check the suppression state *before* believing the result.** This is
    rule 1 of the preamble, and the step is written the way it is because the first version of this
    measurement got it wrong.

    *Gesture:* unplug the machine, leave Vocca backgrounded with another app frontmost for ten
    minutes, then use the hotkey.

    *Precondition to confirm first:* the app is actually being throttled —
    `getpriority(PRIO_DARWIN_PROCESS, <pid>)` reading `1`, or Activity Monitor's **App Nap** column
    showing *Yes* for Vocca. **If it reads 0, void the result.** A timer that behaved perfectly in a
    process that was never suppressed is not evidence about a suppressed one; that exact error was
    published and retracted in this repository.

    *Pass, stated as a bound rather than as "on time":* with suppression confirmed, the 120 s ceiling
    fires within about a second of 120 s, and the ~1 s tap-health poll delivers **44–45 of every 45
    due fires with a worst gap around 1.2 s**. Measured under `taskpolicy -b`: the 150 ms watchdog
    runs at a ~262 ms median (~1.7×), and the 1 s poll at ~1.15× — a roughly fixed ~100 ms of added
    lateness per fire, not a multiplier. A step reading "on time" fails a correct build; a step
    reading "~1.8 s" **accepts a poll that is genuinely broken**, which is what this one said once.

53. **App Nap with the display asleep.** Same gesture, same precondition check, same bound. Untried by
    anyone so far, and named as untried rather than assumed to be covered by step 52.

54. **A modifier released with no event reaching the tap.** *This step has no sharp pass criterion and
    is not given an invented one.*

    The case is a `flagsChanged` that never arrives, which is by definition not producible on purpose —
    that is why the physical-key poll asks about the whole binding rather than the key alone. What is
    checkable is its *consequence*: after any session ended by the poll, the log says
    `.pollDetectedRelease`, and it will not say which half of the binding was released. If a debugging
    session ever needs that distinction, the split is a new `RetainedEndReason` and the place to add it
    is `SessionWatchdog.theBindingIsStillHeld`. Read it as a note to whoever is debugging, not as a
    step that can pass.

### Secure Input

*(New in `hotkey-source` phase 6.)* `SystemSecureInputState` is one Carbon call and **nothing in CI
executes it** — see "What CI cannot cover" §6 for why no test worth having can. Everything the
answer *means* is tested over an injected read; these three steps are the only confirmation that the
answer comes from the system at all.

Any of these turns Secure Input on: ticking **Terminal ▸ Secure Keyboard Entry** (the easiest to hold
for as long as you like), focusing a password field in Safari or Chrome, opening 1Password, or the
login window.

55. **Focus a password field and confirm Vocca reports itself blocked rather than broken.**

    *Gesture:* with Vocca armed and working, tick Terminal's *Secure Keyboard Entry*. Watch the
    health log (`TapHealthNote`) and the widget. Press the hotkey a few times while it holds. Untick
    it.

    *Pass, all four:*
    - within one poll (~1 s) the reported health is **`blockedBySecureInput`** — not `delivering`,
      which is the widget saying *ready* while the hotkey does nothing, and not `notDelivering`,
      which means a tap fault;
    - the log contains **exactly one** `secureInputBegan` line for the whole time it is held, however
      long that is — not one per second;
    - **no** `disabled`, `foundDeadByPoll`, `reenabled` or `recreated` line appears while it holds.
      Any of those is Vocca rebuilding a healthy tap against a state that has nothing to do with the
      tap, and it would go on doing so for as long as the password field is open;
    - after unticking: **exactly one** `secureInputEnded` line, and the hotkey works again **with no
      re-creation** — the tap must be the same one, which the absence of a `recreated` line is what
      says.

56. **Start a session, then take the keyboard away.** The hot mic behind Secure Input, and the reason
    it is a safety item and not only an honesty one.

    *Gesture:* start a **toggle** session (press once, in a normal text field), then tick Terminal's
    *Secure Keyboard Entry*.

    *Pass:* the microphone indicator goes out **within 2 s**, and the transcript survives — the
    dictation you had already spoken must appear, because the session ends as a retaining reason and
    its audio travels with it.

    *What the 2 s is guarding:* the second press that would have stopped this session is an event the
    tap can no longer receive, and toggle has no key-up rule and no physical-key poll behind it. If
    the poll does not close it, what closes it is the **120 s ceiling**. So anything beyond a few
    seconds is the failure, and "it stopped eventually" is not a pass.

57. **Launch Vocca with Secure Input already held.** The arming path, which is a different branch from
    the poll and the one a user meets first if they leave *Secure Keyboard Entry* ticked.

    *Gesture:* tick it, then start Vocca.

    *Pass:* arming reports **`blockedBySecureInput`**, the log reads `armed` then `secureInputBegan`,
    and — the half that is easy to get wrong — **the tap was still created**: untick Secure Keyboard
    Entry and the hotkey must work **immediately, with no re-creation** (`startCount` unchanged, no
    `recreated` line). An implementation that declined to create a tap while blocked leaves Vocca deaf
    *after* the block passes, with nothing left to notice that it has.

### The microphone — `audio-capture`

*(Added 2026-08-12, `audio-capture` phase 6.)* The two acceptances this section records are
marked manual-only in `spec.md`'s table (A6, A7), and the second carries the word "required":
the engine's start cost is the number `prd.md:280` demanded be measured before C7 optimises
against it. Nothing CI runs can produce either — there is no microphone on a hosted runner (§2),
and a test that opened one would light the indicator M23 exists to keep dark.

58. **The orange dot is dark between sessions — and goes out when it is asked to.** The aspect's
    A6, and this aspect's equivalent of the step `hotkey-source` found most valuable: **watch the
    orange dot, and time it.** It carries both privacy constraints on the engine — constraint 2
    (starts on demand, never kept warm; `AVAudioEngine.h:465-466` lights the indicator for as long
    as a running engine has input enabled) and constraint 3 (`endCapture()` must not return until
    the input device is released). The two failures look different, and the gesture must see both.

    *Gesture:* record the screen (`⌘⇧5`, 60 fps) — step 41's discipline, because counting frames is
    the only clock sharp enough for the criterion below. First **light the dot**: start a hold-to-talk
    capture and speak, so the indicator has demonstrated it can light — a dark dot is evidence only
    against a dot known to work (rule 1 of the preamble). Then count down aloud — "three, two, one" —
    and release the hotkey on the beat; the recording's audio marks the release frame. Count the
    frames from there to the dot going out. Then leave Vocca armed and idle for a full minute, and
    watch the dot throughout it.

    *Pass, both halves:*
    - the dot goes out **within 250 ms of the release — 15 frames at 60 fps**; and
    - the dot stays **dark at every moment of the armed-idle minute** — not a glance at the end: a
      dot that lights at second 45 and goes out at 55 is the exact failure, and one glance misses it.

    *What the criteria are guarding, so they are not loosened:* a dot still lit while idle is
    constraint 2 failing — the engine kept warm, the "worst possible signal for this product"
    (`prd.md` M23) — and it has no half-lit form, so the continuous minute is the check and there is
    no bound to loosen. A dot slow to go out after release is constraint 3 failing silently:
    `endCapture()` returned, the machine went `.idle`, the widget showed idle — and the device was
    released on a later run-loop turn, or not at all. That failure has no bounded form either: the
    engine keeps running with input enabled and the dot stays lit until the next session start or a
    quit, so "went out eventually" is not a pass. Healthy, release-to-dark is one watchdog tick at
    most (~150 ms, the physical-key poll's bound) plus the ~8 ms of `stop()` itself; 250 ms (15
    frames) passes that with room to spare and fails a stop deferred by even one tick (~310 ms).
    Step 41's 500 ms criterion was right for *its* failure, which has a bounded degraded form (~1 s
    health poll); this one does not, so the criterion sits tighter. Why the countdown: the release
    instant has no on-screen mark, and a stopwatch is not precise enough for 250 ms — step 41's
    reason, unchanged.

    *If the machine has no input device at all* (no built-in array — e.g. a Mac mini — and nothing
    in the jack): this step cannot be performed. Record it as **not performed**. It is not a pass.

59. **Engine-start latency, measured on this machine and recorded.** The aspect's A7 — manual but
    required, and the one acceptance whose deliverable is a record rather than a verdict. The
    instrument is `Scripts/measure-engine-start.sh`; the `warm` mode builds the graph once and
    `start()`s/`stop()`s per press, 120 iterations at a 1 s gap — the shape M23 mandates, and the
    gap that makes it a measurement of the user's pattern rather than of a tight loop.

    *Gesture:*
    - `./Scripts/measure-engine-start.sh devices` first — **name the device or the number means
      nothing**: the two built-in rows differ by 2.7× on one machine, and the reference machine's
      slowest input was its default only because something was plugged into the jack.
    - `./Scripts/measure-engine-start.sh warm` on the machine's default input device; record the
      device name, n, median and worst. If a Bluetooth HFP headset is reachable, also run
      `./Scripts/measure-engine-start.sh warm --device "<name>"` and record that row.

    *Pass, all three:*
    - the run **exits 0**, every row's four checks verified: mic access authorized, `isRunning`
      true, a non-zero input format, and the realtime sink block actually delivering frames. An
      unverified row voids the record: an engine with an enabled input node and *nothing attached*
      starts happily, reports `isRunning == true`, takes the same ~110 ms and captures nothing —
      timing `start()` and stopping there is how a measurement becomes a fiction;
    - the record **names the device** and states what this machine's default input is. A row reading
      "the built-in input" is not a record — it is the reference table's own mistake, once;
    - the numbers are **this machine's, taken now**. The reference table — **114 ms median / 127 ms
      worst on the analog headphone-jack input, 42 ms median / 53 ms worst on the built-in microphone
      array, 120 and 60 verified sessions**, M4 Max, `plan_20260806.md` §"Result, written after Phase
      3" — is another machine's record, quoted so a wildly divergent same-class median (more than
      ~2×) gets investigated rather than recorded in silence. A release record that reproduces the
      reference table verbatim is a failed step.

    *HFP is unmeasured, and stays unmeasured until a row exists.* No HFP-capable device was reachable
    when the reference numbers were taken; HFP is the configuration most likely to be *worse* than
    any of the measured inputs (16 kHz input — the converter's pass-through case, `spec.md` §"Out of
    scope"); and the one command for whoever has the hardware is written above. If no headset is
    reachable on this machine, the record says **"HFP: unmeasured"** — never "fine". A release that
    ships with HFP unmeasured ships with that sentence in the record, not with an assumption.

### If notarizing

60. `Scripts/notarize.sh` has **never run end to end** — there is no Developer ID configured. The
    first real release must treat notarization as unproven and budget time for it, including for
    the possibility that a rejected entitlement or a missing hardened-runtime flag only shows up
    there.

61. It submits `.build/xcode-release/Build/Products/Release/Vocca.app` by default — the same bundle
    steps 1–4 built, signed and inspected. That is only true if step 2 was run with the Release path
    given explicitly; a bare `./Scripts/sign.sh` signs Debug and this step then submits an
    unmodified Release build.

    If it reports *"the notary service is unreachable"*, that is a network failure and **not** a
    missing credential — do not run `store-credentials` again on the strength of it. The two are
    reported differently on purpose: the older version of the script probed credentials with a
    network call and told an offline machine with perfectly good credentials that it had none.

### The dictation loop — its first execution

*(Added 2026-08-12, `dictation-loop`.)* Nothing in the loop runs in CI: the real tap needs the
Accessibility grant (§1), the microphone needs TCC and hardware (§2), the engine needs real model
bytes (steps 18-19), and the panel needs a window server (steps 31-35). CI drives the *composed
loop* instead — the real machine, watchdog and pipeline over fakes: 100 cycles, failure
injection, cancel-discard, empty-skip (PRD metrics 1, 3, 5). These seven steps are the loop's
first execution with all of it real — the pass/fail of the `dictation-loop` PRD metric 1's
first-execution clause, in the steps 22-35 discipline. Every expected result below was
cross-checked against the shipped machine's `EndReason`/`SessionEffect` vocabulary; where the
shipped app cannot yet produce the plan's claim, the step says so and records **not performed**
(step 47's convention) rather than passing an invented criterion (rule 2 of the preamble).

Two preconditions govern the whole section: **the model must be present and prepared** — the
launch-time background `prepare` (`AppBootstrap.main` → `startEnginePreparation`) runs once, in
the background, and a press before it completes is step 66's gesture, not this section's — and
**the Accessibility and microphone grants must be live** (steps 5-10 — on a fresh account, the
onboarding flow of steps 81–86 is how they become live).

And one half of the plan is **not yet wired in the shipping app**, which is why one of the
steps below cannot pass yet:

- the **toggle mode** selection control belongs to the settings surface, which does not ship yet
  (`PRODUCT_SPEC.md:291`); `setActiveMode` is a wiring seam (`AppBootstrap.swift:700-719`).

The two halves that this section previously listed as unshipped are now wired and their steps
performable: the live pill's window is constructed by the composition root (`LiveWidget`,
`AppBootstrap.swift` — lazily, on the store's first non-IDLE fold, so `configure` creates no
window) and the **Esc** key's route to the machine's `cancel()` is closed end to end
(`SessionKeyPolicy` in `VoccaHotkey`; the root's cancel router in `AppBootstrap.swift`) — see
step 64, which was the blocked step.

62. **First dictation — Notes and TextEdit; a 10-second utterance lands verbatim — the field
    holds the cleaned transcript, which for a clean phrase is the raw text itself.** PRD metric 1.

    *Gesture:* with the model present and the launch-time prepare completed (a trial press starts
    a session), focus a new note in Notes, press `⌥Space` to start, speak a fixed 10-second
    utterance, and press `⌥Space` again to end — **toggle is the shipped default since
    2026-08-25**, so both ends of the session are a press, not a hold and a release. To run this
    row in hold-to-talk, switch the mode first; the gesture is then press, speak, release.
    Select all, copy, and compare with `pbpaste` **byte for byte** — the
    steps 22-35 discipline, against the transcript Vocca produced, not against your intention
    (an ASR mishearing is step 18's matter; a byte difference against what the engine produced is
    an injection matter). Repeat in TextEdit (`⌘⇧T` — rich text reflows and defeats the byte
    compare).

    *Pass:* the field holds the transcript **cleaned by the shipped rules, which for a clean
    phrase is the transcript itself** verbatim in both apps, no failsafe appears, and the
    orange mic indicator (step 58's discipline) is out within a watchdog tick of the second
    press. The
    cycle the machine executes is the plan's sequence — OPENING → RECORDING → TRANSCRIBING →
    DELIVERED → IDLE (`PRODUCT_SPEC.md:77-103`): `.opening` shows the target label with **no
    waveform yet** (`:33-38`), `.started` begins the live waveform — the "it heard me" signal
    (`:84`), tracking real input level, never a canned animation (`:87-88`) — with `esc to
    cancel` after 2 s (`:129`) and the elapsed timer **from 0:00** (`:89`, amended 2026-08-26 —
    it waited 3 s until the counter was seen appearing mid-utterance); TRANSCRIBING freezes the
    waveform with the `○○○` progress (`:93-95`); DELIVERED shows `✓ → Notes` before the ~600 ms
    collapse to IDLE (`:50`, `:98`). The sequence is store-folded and CI-pinned, and the pill's
    window is wired: `LiveWidget` constructs it on the store's first non-IDLE fold, it
    self-drives show/hide from the store, and it never takes focus (`PRODUCT_SPEC.md:22`;
    `WidgetPanel.canBecomeKey` is `false`). The waveform tracks the real input level through
    `MicrophoneLevelSource` over the capture graph — a flat line while speaking is an input-level
    defect, not a display preference.

    *Failure:* the field does not hold the transcript **cleaned by the shipped rules, which for a
    clean phrase is the transcript itself** verbatim; the failsafe appears with a reason instead
    of a delivery; or the mic indicator stays lit after the closing press. A transcribe
    failure surfaces the `.transcriptionFailed` reason-only notice — **"Voice processing failed.
    Nothing was lost — you can try again."** (`FailsafeCopy.swift:54-55`, PRD R5) — never a
    silent idle pretending the text landed.

63. **Secure Input through the loop — no text ever lands in a password field.** PRD metric 1.

    *Gesture:* focus a password field in Safari or Chrome (Secure Input engages — the steps 55-57
    precondition), press `⌥Space`, speak.

    *Pass:* **no session starts at all.** Secure Input makes every event tap in the session deaf
    (steps 55-57), so the press never reaches Vocca — the hotkey is blocked, the mic indicator
    never lights, and no text is captured, transcribed or typed into the field. The refusal copy
    surfaces on the failsafe when the ladder meets a secure-input target at rung 0 with
    `attempted: []` (`InjectionLadderDecision.swift:87-96`): **"This looks like a password field.
    Vocca won't type into it — press ⌘C to paste it yourself."** (`FailsafeCopy.swift:45-46`,
    `PRODUCT_SPEC.md:111`). On this build that copy is reachable by the ⏎-retry route of step 27 —
    a fresh dictation cannot begin over a password field, because the hotkey is deaf — and it is
    a **held** presentation: the transcript is present and ⌘C-copyable, not the reason-only shape
    (no ⌘C/⏎ affordances) that `.modelUnavailable` and `.transcriptionFailed` render
    (`FailsafeCopy.swift:66-72`).

    *Failure:* any text lands in the password field; a session starts while Secure Input is held;
    or the failsafe's reason is anything but the `.secureInput` copy.

64. **Esc during RECORDING and during TRANSCRIBING.** PRD metric 1.

    *Gesture:* press `⌥Space`, speak, and press Esc **during RECORDING** (the live waveform is
    drawing). In a second cycle, press `⌥Space` again to end the capture and press Esc
    **during TRANSCRIBING** (the
    waveform is frozen behind the `○○○` progress, `PRODUCT_SPEC.md:93-95`). Do both over an empty
    Notes field, and watch the field and the mic indicator (step 58's discipline).

    *Pass:* the session is **discarded and nothing lands in the field**: the widget returns to
    IDLE immediately, no injector call and no failsafe, and the mic indicator goes out with the
    discard. The route is CI-pinned end to end — the tap's Escape is classified by
    `SessionKeyPolicy` (a fresh key-down; `Sources/VoccaHotkey/SessionKeyPolicy.swift`), the
    root's cancel router ends a recording session as `.userCancelled` — the only `EndReason`
    permitted to discard (`SessionMachine.swift:440-445`) — and cancels an in-flight transcription
    through the router's task handle, and a cancelled transcription never injects
    (`DictationPipeline.swift:155-186` — the pipeline checks its own cancellation at every
    decision boundary). The key is **swallowed** during the gesture — the focused application
    never sees it — so the app's own Esc behaviour (dismissing a popover, say) must not be
    expected to fire. `PRODUCT_SPEC.md:129`'s cost is honoured: an Esc during
    OPENING — the instant between the press and the microphone opening — opens and closes the
    mic, briefly lighting the indicator (the `stopDeferredByTheOpening` record,
    `SessionMachine.swift:240`); that variant is a third gesture: press `⌥Space` and Esc
    back-to-back, and the indicator's flash is the expected behaviour, not a failure.

    *Failure:* text lands in the field; the failsafe appears with a held transcript or a reason
    notice; the mic indicator stays lit after the Esc (the discard did not close the microphone);
    or a second dictation cannot start immediately after (a stuck session).

65. **The shortest possible session — returns to IDLE, no injector call.** PRD metric 1.

    *Gesture:* **toggle (the shipped default):** press `⌥Space` and press it again immediately
    (~80 ms apart) over an empty Notes field, in a silent room, and watch the field. A single tap
    does *not* end a toggle session — it starts one that runs until the next press or the
    ceiling — so the two-press gesture is what "short press" means in the shipped mode.
    **Hold-to-talk:** the original gesture, a single ~80 ms tap of the chord.

    Both produce the same thing: a capture far shorter than any utterance.

    *Pass:* the gesture returns the widget to IDLE with **no text in the field and no failsafe**.
    The shipped guarantees that make this the honest expectation: a key-up that lands while the
    microphone is opening is held and applied the instant the session exists
    (`SessionMachine.swift:240`, the deferred-stop funnel); the empty-buffer policy decides
    *before* the engine — `samples.isEmpty` means the press never asks the engine, and empty
    text is never pasted (`DictationPipeline.swift:142-148, 166-170`); and a buffer that is
    non-empty but **shorter than the engine's 0.3 s minimum** answers empty in the adapter rather
    than throwing (`ParakeetEngine.isBelowSDKMinimum`, added 2026-08-25).

    That last guarantee is why this row is worth running rather than assuming. Until it existed,
    this exact gesture produced the failsafe's **"Voice processing failed. Nothing was lost — you
    can try again."**: the capture was too brief for FluidAudio's guard, which threw
    `invalidAudioData`, which surfaced as `.transcriptionFailed`. A capture of *exactly* zero
    samples skipped cleanly while one of a few hundred raised an alarm — so a quick tap of the
    hotkey looked like a failure. This row is that bug's regression test on real hardware.

    One bound to state rather than hide: the buffer is the opening window's audio (~42-114 ms,
    `PRODUCT_SPEC.md:105-127`), so in a *noisy* room the buffer may not be empty and a real
    transcript can land — the pass is "no text, no failsafe, back to IDLE", not "guaranteed
    silent".

    *Failure:* a failsafe appears (a transcript was captured and the ladder failed — a real
    injector call), text lands, or the widget is stuck in any state past its window.

66. **Engine-not-ready refusal — the model blocked, the mic never opens.** PRD metric 2.

    *Gesture:* with the model directory moved aside — or the network off so the launch-time
    `prepare` cannot succeed — launch Vocca, then press `⌥Space`.

    *Pass:* the press is refused with the `.modelUnavailable` reason-only notice —
    **"Voice processing isn't ready yet — try again in a moment."** (`FailsafeCopy.swift:52-53`,
    PRD R5) — and the **system mic indicator never lights**: the readiness gate refuses before
    the machine can ask the microphone (`EngineReadinessGate.beginCapture` answers `.unavailable`,
    `AppBootstrap.swift:1098-1117`), so no session begins and no text appears anywhere. The
    refusal repeats for every press until a preparation succeeds — honest and repeatable, never a
    silent dead end (`AppBootstrap.swift:750-759`); `prepare` runs once at launch, so restore the
    model and relaunch. The contrast that makes the copy mean something: with the engine *ready*
    and the microphone genuinely unavailable, the surface is the widget's notice instead —
    **"The microphone didn't open — try again."** (`WidgetCopy.swift:77-82`).

    *Failure:* the mic indicator lights during the refusal (the gate was bypassed), the press
    appears to do nothing at all, or the notice's copy is anything but the `.modelUnavailable`
    text.

67. **A toggle session runs and ends via its triggers (ceiling / tap-disabled / system).**
    PRD metric 5.

    **Performable since 2026-08-25, when toggle became the shipped default** — no mode-selection
    control is needed to reach it any more, because it is the mode a fresh launch is already in.
    (The paragraph below was written when it was the unreachable alternative; it is kept because
    the wiring it describes is unchanged, and because hold-to-talk is now the half that needs
    `setActiveMode` to reach.) The toggle wiring ships:
    the second configuration of the same machine, `activation: .toggle`, constructed and owned
    (`AppBootstrap.swift:273-278, 656-670`), with the machine's toggle end vocabulary — the next
    matching press (`.toggledOff`), the 120 s ceiling (`.ceilingReached`), a dead tap
    (`.tapDisabled`), and the system triggers (`EndReason.swift:50-88`) — and the composed
    toggle cycle is CI-driven over fakes (press → runs → ended via `.toggledOff` / ceiling /
    tap-disabled). What does not ship is the mode-selection control: it belongs to the settings
    surface (`PRODUCT_SPEC.md:291`, amended — the two modes swapped roles and neither was
    removed), and `setActiveMode` is a wiring seam that refuses a switch while a session is in
    flight (`AppBootstrap.swift:700-719`). The gesture, in the mode a fresh launch is already in:
    press `⌥Space`, talk, press again to end — the transcript lands; and the backstops:
    unplug the input device (the one system trigger wired today, `.audioConfigurationChanged`,
    `AppBootstrap.swift:207-222`) and hold a session past the ceiling — the mic indicator must
    go out within a watchdog tick of each stop (step 51's discipline).

68. **20-cycle stability — no crash, no stuck session, zero transcript loss.** PRD metric 3
    (invariant I1), with metric 1's "no crash and no stuck session across 20 cycles" clause.

    *Gesture:* with the model present, dictate 20 cycles into Notes — a mix of ~5-10 s utterances
    and the shortest-possible sessions of step 65. Between sessions, watch the mic indicator
    continuously
    (step 58's discipline, not a glance at the end), and after resolving any failsafe, list
    `~/Library/Application Support/Vocca/recovery/` (step 35's check).

    *Pass:* every cycle ends — the mic indicator goes out within a watchdog tick of each stop
    and stays dark between sessions (a session that does not end keeps it lit: the hot-mic class);
    no crash; and **zero transcript loss** — every spoken utterance either landed in the field
    **cleaned or raw** verbatim or is held and copyable in the failsafe, the two halves of
    invariant I1, enforced by the pipeline's closed terminal set: an injector call, a journaled
    hold, or a reason-only notice that names the failure — never a silent idle
    (`DictationPipeline.swift:47-57`, `prd.md` metric 3).

    *Failure:* a session that does not end (stuck past its window — the hot mic), a crash, or an
    utterance that neither lands, nor is held, nor is accounted for by a reason notice. CI's
    100-cycle composed run (metric 5) makes the same claim over fakes; this step is the first
    time it is made with a real tap, a real mic and a real engine.

69. **The user dictionary through the loop.**

    *Gesture:* edit `~/Library/Application Support/Vocca/dictionary.json` to a rule (e.g.
    `"gotcha"` → `"got you"`), relaunch, dictate the rule's source over Notes.

    *Pass:* the field holds the **target**, not the source — the dictionary is applied by the
    default-on rules provider.

    *Failure:* the source lands unchanged with a clean utterance.

70. **Cleanup-failure degrade: text still lands raw.**

    *Gesture:* with a rules path that fails or times out (e.g. a rule file made unreadable
    mid-session, or a strace'd suspension) dictate over Notes.

    *Pass:* the raw text still lands (I5 — cleanup degrades, never blocks); the ledger's record
    shows the **cleanup span** (step 69's `PROBE-LATENCY`/ledger read discipline — the record is
    local, `describe()` renders it).

    *Failure:* no text lands, or the cleanup failure is silent forever (no span in the record).

### The real-engine latency benchmark — its first measured run

*(Added 2026-08-14, `benchmark-gate`.)* The benchmark's headless half is CI-covered: the span
contract, the regression gate's mechanism (a seeded slow injector must fail it — a gate that
cannot fail proves nothing), and the `ProvisionalTolerances` table are asserted in
`Tests/HarnessTests/LatencyBenchmarkTests.swift`. The real-engine run is executed by nothing in
CI — the steps 18-19 precedent: the model cannot reach a hosted runner, and a CI number would
be about fakes, never about Vocca. These two steps are the run's first execution, on the
founder's machine, and the first real latency data this repository will have.

71. **The first real latency benchmark run — the real engine, on this machine.** The WER
    discipline (step 19) applied to latency: the runner is env-gated exactly like the engine
    tests — without `VOCCA_LATENCY_BENCH` it skips visibly, and the founder's machine is its
    only execution.

    *Gesture:* reuse the steps 17-18 model install if it is still present, or provision one —
    `./Scripts/provision-asr-fixtures.sh --source <model-dir> --root <store-root>` (the
    parakeet default; the script prints the `VOCCA_MODEL_DIR` value to use). Then run the
    benchmark with both env vars set:
    `VOCCA_MODEL_DIR=<version_dir> VOCCA_LATENCY_BENCH=1 swift test --filter LatencyBenchmarkTests`
    — with `VOCCA_LATENCY_BENCH` set but no model, the runner fails loudly with the
    provisioning instructions rather than skipping (the WER pattern).

    *Pass:* the run completes and prints, for each fixture (the 200 ms, the clean and the 60 s
    clips), a per-span p50/p95 row for **captureClose, asr, cleanup and inject** — the closed
    span set the gate checks — the recorded cleanup span (C5 wired) is one of the four — **with
    the process's suppression state beside every row**, and the suppression column reads
    **not-suppressed throughout**. Rule 1 of the preamble applies without softening: a run taken
    while the process was throttled is **voided, not recorded** — a throttled number recorded as
    clean is the exact error this column exists to prevent (step 52's discipline, the
    `measure-timers.sh` precedent).

72. **The record: the printed numbers re-baseline the tolerances table.** The run's deliverable
    is a record, not a verdict — the way step 59's engine-start measurement is. Read the printed
    per-span p50/p95 against the provisional table — **p50 ≤ 400 ms / p95 ≤ 800 ms for a
    10-second utterance** (`ProvisionalTolerances` in `Tests/HarnessTests/LatencyBenchmarkTests.swift`,
    `ROADMAP.md:171`) — and record the measured values in that table, the C3 tolerances
    mechanism (`tolerances_20260810.md`): the table is the one place the numbers live, and
    nothing passes or fails a release gate on them until this run has re-baselined them.

    *Two honest bounds, stated rather than hidden:* the **10-second target is measured on the
    founder's machine, not claimed from CI** — CI proves the span contract and the gate's
    mechanism over seeded fakes and never produces a product latency number; and the fixture
    suite has **no 10-second clip**, so the target is measured over the 60 s fixture (the
    closest length the suite has), and that substitution is recorded beside the numbers, not
    smoothed over. Record the run's machine and model-version alongside, as step 19 records
    its machine and artifact hashes — the numbers are about that machine or they are about
    nothing. Until this step has been run once, everything this repository says about perceived
    latency is a claim about structure, not about measurement.

---

## The cleanup eval harness — the first real scoring run

This section is the first execution of the cleanup eval harness's real half
(`docs/planning/deterministic-cleanup/eval-harness/`). The headless stand-in run and the
mechanism gates run in CI; **nothing in this section is CI** — the F2 recordings are the
founder's artifacts and stay on the machine (R11), and a CI-run preference percentage would be
about stand-ins, never about Vocca. Steps 69-70 are this harness's dictation-loop surface; this
step is the number the P1 gate is judged on (`ROADMAP.md:137`), recorded not gated
(`tolerances_20260815.md`).

73. **F2: record the real held-out set and run the first real scoring.** The stand-in corpus is
    provably recoverable by the shipped rules, so its percentage measures the mechanism, not the
    product. This step replaces the bytes: the founder's own recordings, scored by the founder —
    the first time the ≥ 80% preference figure is measured rather than provisional.

    *Gesture:* record **≥ 40 utterances, ≥ 5 per class**, across the six classes
    (`fillers | punctuation | capitalization | numbers-units | dictionary | token-protection`),
    dictation-length (3-15 s), natural as-spoken speech — fillers and false starts, not reading
    flat. For each, hand-polish the golden clean text (what should have been typed) into
    `<name>.clean.txt` and tag the class into `<name>.class.txt`; keep the corpus in a
    machine-local directory, e.g. `~/Vocca/f2-pairs/` — **never in the repository**. Add a
    `dictionary.json` with the dictionary-class rules. The raw side is the real engine's
    transcript of each recording (16 kHz mono; provision once per machine via
    `./Scripts/provision-asr-fixtures.sh`, then the runner reads the `<name>.wav` sidecar and
    ignores the `.raw.txt` for those pairs — attributed to the Parakeet identity); the
    hand-typed `<name>.raw.txt` variant is the fallback when the engine is not provisioned.

    Run the scorer with `VOCCA_CLEANUP_EVAL=<pairs-dir>`: the first invocation prints the
    seeded ballot (pairs as A/B sides, never labelled); fill `answers.tsv` (the seed line is
    printed at the top; one `name<TAB>left|right|tie|noPreference` line per pair — tie and
    noPreference rows are excluded from the denominator by design,
    `tolerances_20260815.md`); the second invocation prints the verdicts, the seed beside every
    row, the per-class breakdown and the preference percentage.

    *Pass:* the run prints the record — the preference percentage, the per-class breakdown and
    the seed — and the verdicts reproduce the comparator's mapping for the printed seed.
    **"Pass" for this run is the printed record, not a verdict**: the percentage is recorded in
    `docs/planning/deterministic-cleanup/eval-harness/tolerances_20260815.md` and re-baselines
    `ProvisionalCleanupTargets` via the record's measure → margin → founder-signed procedure; a
    result below 80% is a record and a signal to fix the rules, never a gate failure.

    *Failure:* the run cannot score every pair (missing clean target, missing class tag,
    missing answers), the seed is not printed, or the percentage is presented as a verdict.
    Until this step has been run once, everything this repository says about cleanup quality is
    a claim about mechanism, not about measurement.

---

## The LLM cleanup rungs — Ollama and BYOK, their first execution

*(Added 2026-08-19, `llm-cleanup`.)* The LLM rungs' decisions are CI-covered — the providers'
request shaping and failure modes over stub transports, the rules-then-LLM chain's degrade, the
config's tolerant decode, the resolver's resolve-once, the egress badge's reducer — but **no
part of a live LLM cleanup runs in CI**: a real Ollama server, a real remote endpoint, a real
Keychain, a real window-server badge. These steps are the rungs' first execution, on the
founder's machine, exactly as steps 22-35 were the adapters' and 62-68 the loop's. The
configured file is `~/Library/Application Support/Vocca/cleanup-config.json`
(`cleanup-config`); the key lives in the login Keychain under `dev.vocca.Vocca.byok-key`
(entered with the `security` command, never written to the file:
`security add-generic-password -a vocca -s dev.vocca.Vocca.byok-key -w '<key>'`).

74. **The Ollama rung — a real local LLM, live and then stopped.** The shipped provider against
    a real Ollama server: the endpoint live, the model selected, and the rewrite *observed* —
    the first judgment of whether the LLM rung's value ("tone, rewriting, reflow",
    `CAPABILITY_ROADMAP.md:134`) is real, recorded as a smoke observation, never a gate number
    (`prd.md` "quality not implied").

    *Gesture:* hand-edit `cleanup-config.json` to
    `{"provider": "ollama", "ollama": {"endpoint": "http://localhost:11434", "model": "<a real model>"}}`
    (step 3's path, the file is `~/Library/Application Support/Vocca/cleanup-config.json`),
    restart Vocca, dictate a sentence that benefits from rewriting — a false start, a filler,
    a flat reflow — and watch the injected text. Then stop Ollama and dictate again.

    *Pass:* with Ollama up, the injected text is a genuine rewrite of the rules output (tone
    and reflow, not just fillers) within the 5 s budget; **with Ollama stopped, dictation still
    lands the rules output** — the degrade is structural, never a lost dictation
    (`ROADMAP.md:140`). The cleanup span in the ledger (step 70's surface) reflects the LLM's
    time with the rung active.

    *Failure:* with Ollama stopped, a dictation loses text or hangs past the budget race; or
    the rung silently dials an endpoint that is not `cleanup-config.json`'s.

75. **The BYOK rung — a real endpoint, the key in the Keychain.** The shipped provider against
    the user's own endpoint: the key read from the Keychain (never from the file), the rewrite
    observed, and the badge visible while the rung is active. The key-entry one-liner above is
    the whole setup — there is no other path into the key.

    *Gesture:* hand-edit `cleanup-config.json` to
    `{"provider": "byok", "byok": {"endpoint": "<chat-completions URL>", "model": "<model or omit>"}}`,
    enter the key with the `security add-generic-password` one-liner, restart Vocca, dictate.

    *Pass:* the injected text is the endpoint's rewrite within the 5 s budget; the ☁︎ marker
    shows while the rung is active (step 76); a **wrong or absent key** degrades to the rules
    output — the key is never prompted for, never silently skipped, never retried in a loop
    (`byok-provider` B6), and **never appears in any log or error**.

    *Failure:* a key error surfaces as something other than the rules-output degrade; or the
    key appears in a log, the config file, or a crash report.

76. **The badge, both directions — visible while a network provider is active, gone when rules
    is selected.** The egress marker's first appearance (`PRODUCT_SPEC.md:250-264`): the widget
    pill carries the ☁︎ glyph while an LLM rung is active and shows nothing on the default rules
    path — a user must always be able to see, at a glance, whether their text is leaving the
    machine.

    *Gesture:* with an `ollama` or `byok` rung selected (steps 74-75's config), dictate and
    watch the pill through OPENING/RECORDING/TRANSCRIBING; hover the glyph and read the copy.
    Then set `"provider": "rules"` (or delete the file), restart, and dictate again.

    *Pass:* the glyph is present during the three states while an LLM rung is active — with the
    hover copy stating plainly "Cleanup runs on <endpoint>. Your text is sent there." — and
    **absent** (the pill is byte-for-byte the shipped rules surface) when rules is selected. The
    marker cannot be dismissed while active: no click, no key, no timer removes it mid-session.

    *Failure:* the badge appears on the rules path, is absent while an LLM rung is active, is
    dismissable, or its hover copy names anything other than the configured endpoint.

---

## The warm-start run and the streaming mechanism — their first executions

*(Added 2026-08-25, `warm-start-streaming`.)* The warm-start gate's mechanism and the
streaming route's guard are CI-covered (the seeded-slow 2× first transcription must fail the
benchmark gate; the zero-injection-before-final guard; the byte-for-byte batch default under
the interposer). Nothing here is CI: the real ratio needs a real model, and the widget's
partial text is unobservable until a real engine streams — which this unit deliberately does
not ship.

77. **The warm-start real run — the first measured ratio.** The env-gated runner
    (`LatencyBenchmarkRealEngineTests`, the `VOCCA_LATENCY_BENCH` + `VOCCA_MODEL_DIR` WER
    pattern) prints the real engine's `firstAfterLaunch` and `warmTranscribe` samples, the
    ratio, and the process's suppression state beside every row.

    *Gesture:* provision a model as in steps 17–18, then
    `VOCCA_MODEL_DIR=<version_dir> VOCCA_LATENCY_BENCH=1 swift test --filter LatencyBenchmarkRealEngineTests`.

    *Pass:* the run prints the ratio with the suppression column reading **not-suppressed
    throughout** (a throttled run is voided, never recorded as clean — the step-52
    discipline), and the measured row lands in
    `docs/planning/warm-start-streaming/warm-start/tolerances_20260825.md` — **recorded, never
    gated**: a ratio past the 1.2 bound is a record and a signal to fix the warm start, not a
    gate failure. Until this run happens once, the 20%-of-steady-state claim is about
    mechanism, not measurement.

78. **The streaming mechanism, with its honest scope stated.** The probe's `streaming-cycle`
    mode drives a full streaming cycle through the composed root with a stub engine: partials
    fold into the widget store, exactly one final routes to the injector, zero `connect(2)`
    under the interposer (`PROBE-STREAMING`).

    *Pass:* the cycle prints its post-condition with zero network events, and the byte-for-byte
    checks hold — the default configuration's `PROBE-CYCLE`/`PROBE-LATENCY` strings are
    unchanged. **What is not here:** no real engine streams yet (both engines report
    `supportsStreaming == false`), so the widget's partial text is unobservable with a real
    model until the deferred streaming adapters land; `ARCHITECTURE.md:630` open question 2
    (speculative final-vs-batch equivalence) is untouched, and no latency number is claimed
    from this mechanism.

79. **The menu bar item — every state, and the one that cannot be staged.** The surface that
    exists because an `LSUIElement` Vocca that is running perfectly and one that died at launch
    look identical. `MenuBarItem` is executed by nothing in CI: a hosted runner has no menu bar,
    and `NSStatusBar.system` has nothing to attach to.

    *Gesture:* with Vocca running, confirm the icon is present, then drive it through the states
    it can be driven through: **ready** (idle), **listening** and **transcribing** (dictate and
    watch it change and change back), **downloading model** (move the model directory aside and
    relaunch), **no Accessibility** (revoke the grant in System Settings), **no microphone**
    (deny or disconnect). Open the menu in each and confirm it stays minimal.

    **Secure Input is the state that cannot be staged from inside Vocca** — it is set by other
    people's software. Focus a password field (Terminal's *Secure Keyboard Entry*, a login sheet,
    1Password) and confirm the icon becomes the lock and that **no button is offered** — there is
    nothing to press, and offering one would be an action that does nothing.

    *Pass:* every state has its own **shape** at menu bar size, distinguishable without colour
    (the icon is a template image, so colour is not available to it anyway); the VoiceOver label
    carries the state as consequence-then-remedy, while the menu itself carries commands only —
    the blocked states that *can* be acted on offer a button that opens the right System Settings
    pane, then Settings… and Quit Vocca, with no readout rows (the founder's call: the menu is for
    doing, not telling — `PRODUCT_SPEC.md:328-330`); and the ~1 s health poll does not rebuild
    the menu while it is open under the cursor.

    *Failure:* two states sharing a shape (one of them is then invisible); an icon that does not
    change during a dictation; a button on Secure Input; a menu that closes or flickers on its
    own while open; or the icon vanishing at any point — a status item that is deallocated
    disappears silently, which is the exact failure this surface exists to end.

80. **The settings window — and the activation policy it borrows.** The one window in Vocca
    allowed to take focus. Executed by nothing in CI for the usual reason.

    *Gesture:* open it from the menu, visit all four tabs, then **switch the activation mode to
    hold-to-talk, close the window, and dictate** — the change must take effect on the next press.
    Add a dictionary entry, close and reopen the window, and confirm it survived; then dictate the
    entry's source and confirm the replacement lands in the text.

    *Pass:* the window comes to the front and takes keystrokes — an accessory app's window cannot
    become key, which is why `show()` switches to `.regular`. General and Dictionary respond;
    Speech and Cleanup report what Vocca is using and say plainly where those choices still live.
    Choosing Settings… a second time raises the existing window rather than stacking another.

    **The load-bearing row is what happens on close.** `windowWillClose` must return the app to
    `.accessory`: the Dock icon disappears, and the *next dictation is typed by a background agent
    again*. A Vocca left in `.regular` can take focus, which is the one thing it must never do —
    dictate once after closing the window and confirm the text lands in the other app's field
    rather than pulling focus to Vocca.

    *Failure:* the window opens behind the frontmost app or refuses keystrokes; the Dock icon
    survives the close; a dictation after closing the window steals focus; a dictionary edit does
    not survive a reopen, or does not reach the next transcript.

### The first-run onboarding — the five-step flow, its first execution

*(Added 2026-08-27, `first-run-permissions`.)* The onboarding window and its adapters are executed
by nothing in CI: the window is a window-server object, and the TCC prompts it presents cannot be
granted on a hosted runner (§1's wall, and §2's — there is no microphone either). The flow's
reducer, the pinned copy and the permission reads' decisions are the CI-covered half, over
injected seams; these six steps are the flow's only execution, on a machine that has never run
Vocca. The permissions block above (steps 5-10) is the direct per-gate check; this section is the
shape those gates take on a fresh install — the one-at-a-time presentation `ARCHITECTURE.md:589`
demands, never a wall of dialogs.

81. **The fresh-install run — the welcome window, then the two prompts one at a time.**

    *Gesture:* on a clean account (step 5's reset: `tccutil reset Accessibility dev.vocca.Vocca`
    and `tccutil reset Microphone dev.vocca.Vocca`), launch Vocca. The **welcome window appears of
    its own accord** — an `LSUIElement` launch that shows a window is distinguishable from one that
    shows nothing, which is the point of this row (the local-dev-launch defect class). Read the
    WELCOME copy, press [Get started]. On PERMISSIONS: the Accessibility row shows **✗** with the
    §6 reason copy, and its button opens the **exact** `Privacy_Accessibility` pane (step 79's
    discipline — the pane itself, not a Settings root); the Microphone row calls `requestAccess`
    as it appears.

    *Pass:* the two prompts fire **one at a time** — the microphone prompt appears only when its
    row does, never stacked with the Accessibility pane or a second dialog (a wall of dialogs is
    `ARCHITECTURE.md:589`'s named failure); the pane button lands on the exact pane; the prompt's
    text is the `NSMicrophoneUsageDescription` string (step 6's check), not a generic one; nothing
    in the flow needs a terminal, a config file, or an account.

    *Failure:* the window never shows (a silent launch death looks identical to a working launch —
    this row is the only place the difference is visible); both prompts at once; the pane button
    opens the wrong pane; generic prompt text.

82. **Grant → restart → dictate — the three-state Accessibility row, and the restart that arms.**

    *Gesture:* grant Accessibility in System Settings and return to the window **without
    restarting**. The row must show *granted, restart to arm* — the M5c middle state — **never a
    bare ✓ with a dead tap** (the stale-tap trap of `ARCHITECTURE.md:604`: the tap was created
    with its mask cleared and stays deaf until re-creation). Press [Restart Vocca] and wait.

    *Pass:* the app **quits and relaunches itself** — an `LSUIElement` quit that does not come back
    is silent, so watch for the relaunch rather than assuming it; the row then shows *armed*; and
    within **60 s of first launch** the hotkey fires from **another app's** front window (step 9's
    check, the `ROADMAP.md:80` target) — grant → restart → dictate, the whole path, on a real
    grant.

    *Failure:* [Restart Vocca] quits without relaunching; the row shows a ✓ while the tap is deaf
    (the hotkey then does nothing from any app); the hotkey never fires from another app.

83. **Mic denial is not a dead end — the exact toggle, and an honest later refusal.**

    *Gesture:* deny the microphone prompt on a second fresh account (step 8's denial, now through
    the flow) and keep going.

    *Pass:* the window names the **exact toggle** to flip, with a button opening the
    `Privacy_Microphone` pane (step 8's "says something useful", as specific as the copy allows),
    and the flow **continues** past PERMISSIONS — denial never blocks the flow. A later dictation
    presents the honest refusal rather than a silent no-op.

    *Failure:* the flow dead-ends on the denial; the copy names a pane but not the toggle; a later
    dictation appears to work and produces nothing.

84. **Skip the model — TRY IT stays honest, and DONE stays reachable.**

    *Gesture:* on the MODEL step, [Skip for now]. TRY IT must then show the **model-unavailable**
    state with its [Download now] affordance and a way forward, and DONE must remain reachable.
    Then, still without a model, press `⌥Space` from another app.

    *Pass:* the press is refused with the `.modelUnavailable` notice and the **system mic
    indicator never lights** — the readiness gate refuses before the machine can ask the
    microphone (step 66's pass, now reached through the onboarding flow instead: same refusal,
    different route to it). No auto-download starts; the refusal is honest and repeatable, never a
    silent dead end (`PRODUCT_SPEC.md:233-235`); DONE is reachable without the model.

    *Failure:* the mic indicator lights during the refusal; an auto-download starts; TRY IT offers
    no way forward; DONE unreachable.

85. **Completion, and the flag's both directions.**

    *Gesture:* complete TRY IT — speak into the window's field and watch the words land (the
    dedicated onboarding sink delivers to the field; the ladder and steps 22-35 are not involved)
    — then press DONE. Quit and relaunch: the window must **not** re-show. On a second,
    incomplete account: close the window mid-flow and relaunch.

    *Pass:* completion is **TRY IT success** — the `onboarding.complete` flag is set by that and
    by nothing else (PRD R4), and a relaunch with the flag set shows no window; the menu bar
    carries no "Welcome…" row (the founder's call: welcome is one-time, and the Settings window
    is the app's own surface — the tray menu is commands only); on the incomplete account the
    relaunch resumes at the **first incomplete step** — derived from the permission and model
    reads, never from extra persisted step state.

    *Failure:* the window re-shows after DONE; a mid-flow close loses the account's place or
    starts over at WELCOME; TRY IT's words land nowhere (the sink diverged from the real loop —
    R3's surveillance row).

86. **Timing: cold install to DONE — record the number.**

    *Gesture:* on the cleanest account available, from first launch, run the flow end to end —
    model downloaded **or** skipped, and the record must say which — and time it.

    *Pass:* the flow reaches DONE, and the measured number is **recorded beside this step** with
    the machine and the network state. The `ROADMAP.md:80` "under 60 seconds" figure is what this
    row exists to measure, not what it asserts yet: a number past it is a record and a target to
    work on, never a hidden fail.

    *Failure:* the number is not recorded (a claim with no measurement — the rule-1 shape); or
    the flow cannot reach DONE at all.


---

## 12. The injection matrix — memory active, the C8 measurement surface

`ROADMAP.md:172` judges P2 on **≥95% first-method-success across a 20+ app matrix with the
per-app strategy memory active**, and `ROADMAP.md:164` promises that matrix is "run as a
semi-automated harness, tracked per release". Steps 22–35 are the P0 ladder rows and stay exactly
as they are; this section is the expanded matrix, the memory-specific observations, and the
tracked table the number accumulates in.

Nothing here runs in CI, and not for the usual single reason — this section needs a window
server, Automation grants for two dozen applications, a real microphone, a real pasteboard
session, and a week of wall-clock time for one of its rows. `Scripts/injection-matrix.sh
--self-check` is the only part a machine can run: it validates the row table and greps every row
name into this file, so the harness and this section cannot drift apart silently. It is executed
by the suite (`InjectionMatrixHarnessTests`).

**The size question is settled here.** The docs said "20-app matrix" (`ROADMAP.md:172`), "past 20
apps" (`CAPABILITY_ROADMAP.md:183`) and "20+ real apps" (`ARCHITECTURE.md:644`), and named no
concrete set. The figure is **20+**, and the set is the 22 rows below: 20 deliverable rows and 2
refusal rows.

**First-method-success, operationally.** Per row: PASS = the field holds the transcript
byte-for-byte **and** the ladder's log names the row's expected rung as the *landing* rung. A row
that delivered through a fallback (the memory chose accessibility, accessibility failed, clipboard
landed) is a delivery **without** first-method success — a miss for this number, and a
demote-on-fail signal for the memory. The denominator is the **20 deliverable rows**; the two
refusal rows are excluded from numerator and denominator and recorded separately under the
zero-loss invariant. **≥95% = ≥19 of 20.** A skipped row (application not installed) and a voided
row (no Automation grant, so the copy never happened) are neither passes nor failures — they are
recorded as themselves, and a matrix run with many of either is not a matrix run.

### The 22 rows

The set starts from the P0 matrix (`ROADMAP.md:91`) and adds applications that span **failure
classes the P0 set under-samples**, not brands. The class is the invariant: an application that
is not installed is swapped for a same-class one and the swap is recorded in the tracked table.
Bundle identifiers are confirmed with `plutil` against the installed application's
`CFBundleIdentifier` at the baseline run — the `injection-adapters` discipline, and the reason
the seeded lists are trusted.

The expected-rung column is the **steady state**, and it is calibrated by step 87 rather than
asserted in advance. A promotion candidate reads `clipboardPaste` until step 91 observes it flip.

**The bundle identifier column is load-bearing and half of it is still guessed.** The memory keys
on it, the seeds are written in it, and a wrong-but-plausible identifier is invisible: it seeds,
learns and pins nothing while passing every test in the suite. C8's own plan carried
`com.google.docs` — an identifier no application has ever reported — and the only thing that
caught it was reading a real `Info.plist`. `Scripts/injection-matrix.sh --verify-bundle-ids` now
does that for every installed row and exits non-zero on a mismatch. **Confirmed** below means it
was read from an installed application's `CFBundleIdentifier`; **guess** means the application is
not installed here and the identifier has never been seen. Re-run the mode on the founder's
machine and update this column before trusting a guessed row — especially Slack's, which is one
of the two shipped hostile seeds.

Run so far (2026-08-28, authoring machine): **14 confirmed, 0 mismatched, 8 guessed.**

| # | Row | Application | Bundle ID | ID source | Class | Seeded | Expected rung (steady state) |
|---|-----|-------------|-----------|-----------|-------|--------|------------------------------|
| 1 | `matrix-row: Notes` | Notes | `com.apple.Notes` | confirmed | native AppKit | allowlist | `.accessibility` |
| 2 | `matrix-row: Mail` | Mail | `com.apple.mail` | confirmed | native AppKit | allowlist | `.accessibility` |
| 3 | `matrix-row: TextEdit` | TextEdit | `com.apple.TextEdit` | confirmed | native AppKit | allowlist | `.accessibility` |
| 4 | `matrix-row: Xcode` | Xcode | `com.apple.dt.Xcode` | confirmed | native AppKit | no | `.clipboardPaste` — promotion candidate |
| 5 | `matrix-row: Messages` | Messages | `com.apple.MobileSMS` | confirmed | native AppKit | no | `.clipboardPaste` — promotion candidate |
| 6 | `matrix-row: Pages` | Pages | `com.apple.iWork.Pages` | **guess** | native AppKit | no | `.clipboardPaste` — promotion candidate |
| 7 | `matrix-row: VSCode` | Visual Studio Code | `com.microsoft.VSCode` | confirmed | Electron | no | `.clipboardPaste` |
| 8 | `matrix-row: Slack` | Slack | `com.tinyspeck.slackmacgap` | **guess** | Electron | **hostile** | `.clipboardPaste` |
| 9 | `matrix-row: Discord` | Discord | `com.hnc.Discord` | confirmed | Electron | no | `.clipboardPaste` |
| 10 | `matrix-row: Notion` | Notion | `notion.id` | **guess** | Electron | no | `.clipboardPaste` |
| 11 | `matrix-row: Obsidian` | Obsidian | `md.obsidian` | confirmed | Electron | no | `.clipboardPaste` |
| 12 | `matrix-row: Safari` | Safari | `com.apple.Safari` | confirmed | browser | no | `.clipboardPaste` |
| 13 | `matrix-row: Chrome` | Google Chrome | `com.google.Chrome` | confirmed | browser, plain field | **hostile** | `.clipboardPaste` |
| 14 | `matrix-row: GoogleDocs` | Google Chrome | `com.google.Chrome` | confirmed | browser, custom editor | **hostile** | `.clipboardPaste` |
| 15 | `matrix-row: Firefox` | Firefox | `org.mozilla.firefox` | confirmed | browser | no | `.clipboardPaste` |
| 16 | `matrix-row: Terminal` | Terminal | `com.apple.Terminal` | confirmed | terminal | no | `.clipboardPaste` |
| 17 | `matrix-row: iTerm2` | iTerm | `com.googlecode.iterm2` | **guess** | terminal | no | `.clipboardPaste` |
| 18 | `matrix-row: Ghostty` | Ghostty | `com.mitchellh.ghostty` | **guess** | terminal | no | `.clipboardPaste` |
| 19 | `matrix-row: IntelliJ` | IntelliJ IDEA | `com.jetbrains.intellij` | **guess** | Java/AWT | no | `.clipboardPaste` |
| 20 | `matrix-row: Zed` | Zed | `dev.zed.Zed` | **guess** | native, non-AppKit | no | `.clipboardPaste` |
| 21 | `matrix-row: 1Password` | 1Password | `com.1password.1password` | **guess** | known-hostile | — | **no rung attempted** |
| 22 | `matrix-row: PasswordField` | Safari/Chrome password field | `com.apple.Safari` | confirmed | known-hostile | — | **no rung attempted** |

**Rows 13 and 14 share a bundle identifier, and that is the finding, not an oversight.** The
memory keys on the focused application's bundle ID, and Google Docs has none of its own: in a tab
it reports `com.google.Chrome`, and as a Chrome PWA it reports
`com.google.Chrome.app.<per-install hash>`, which cannot be seeded at all. So the hostile seed is
**browser-wide** — the `memory-order` aspect's resolution of the spec's open question — and
Chrome's plain fields are withheld from the accessibility rung along with Docs' editor. The two
rows exist separately because they can still *diverge*: row 13 is where a founder finds out
whether Chrome's plain field would have been accessibility-good, through the re-probe of step 90.
If it repeatedly is, that is an argument for a field-class-scoped seed, and a finding to record
rather than a failure.

### Steps

87. **`matrix-row` baseline calibration — the run that learns.**

    This run has no expected-rung assertions. Its output *is* the expected-rung column for every
    run after it.

    *Gesture:* first run `Scripts/injection-matrix.sh --verify-bundle-ids` and update the ID
    source column above — every **guess** that is now installed becomes confirmed or a mismatch,
    and a mismatch is fixed in the harness table *and* in the shipped seed if the row is seeded.
    Then quit Vocca, delete `~/Library/Application Support/Vocca/strategies.json`, relaunch. Run
    `--dry-run` and record which rows are installed; swap any missing application for a same-class
    one. Then run the full matrix, recording per row: the rung the log named, whether the bytes
    matched, and anything surprising.

    *Pass:* `--verify-bundle-ids` reports zero mismatches, and every installed row produced a
    recorded observation. The per-row table this produces is written into this section as the
    calibrated expectation.

    *Failure:* a row with no recorded observation — or an identifier mismatch left unfixed, which
    means the row's seed and its expected rung describe an application that does not exist.

88. **`matrix-row` the tracked run — the ≥95% number.**

    *Gesture:* with steady-state memory (i.e. **not** freshly reset — the baseline already
    taught it), run `Scripts/injection-matrix.sh`. Per row: dictate the fixed phrase into the
    named field, let the harness do the select-all/copy/byte-compare, and answer whether the log
    named the expected rung.

    *Pass:* ≥19 of the 20 deliverable rows land first-method, and both refusal rows refuse. Append
    a row to the tracked table below.

    *Failure:* fewer than 19 of 20 — recorded, never a silent pass, and the per-row misses are the
    work list. **The number is recorded here, never gated in CI** (`prd.md` X7): CI proves the
    memory's mechanism, this section produces the figure.

89. **`matrix-row` seeded-hostile first run — the discovery cost is paid by the seed, not the user.**

    *Gesture:* on a memory-fresh Vocca (delete `strategies.json`, relaunch), dictate once into
    Slack and once into a Google Docs document — before any other dictation into either.

    *Pass:* the log names **`.clipboardPaste` as the first attempt** in both. No `.accessibility`
    attempt appears at all, so no AX discovery cost is paid on a first use.

    *Failure:* an `.accessibility` first attempt on either. That is R5's seed missing or its
    bundle identifier wrong — and a wrong-but-plausible identifier seeds *nothing* while passing
    every test in the suite, which is exactly what this row exists to catch.
    (`com.tinyspeck.slackmacgap` has never been `plutil`-confirmed; confirm it here.)

90. **`matrix-row` the re-probe — Slack rediscovers, once.**

    *Precondition, verified before anything is asserted:* at least five clipboard deliveries into
    Slack, and the re-probe window has elapsed since the demotion. The window is
    `StrategyMemoryTargets.reprobeWindowSeconds` — read the number from that one file and record
    it beside this row; it is **provisional** and this step is what re-baselines it.

    *Gesture:* after the window has passed, dictate into Slack once more and read the log.

    *Pass:* the log names **one** `.accessibility` attempt, which fails, followed by the clipboard
    landing; `strategies.json` shows the accessibility rung demoted again with a *fresh* window.
    One attempt, not one per dictation.

    *Failure:* no `.accessibility` attempt at all after the window elapsed — R4's decay schedule
    is not running, and an application whose next update fixes accessibility is written off
    forever. Also a failure: a re-probe on *every* dictation, which is the cost C8 exists to stop
    paying.

91. **`matrix-row` the promotion — a candidate earns the accessibility rung.**

    *Precondition:* a promotion candidate (rows 4–6, 19, 20 — Xcode is the first to try) has
    delivered by clipboard at least once, and the window has elapsed.

    *Gesture:* dictate into it after the window; then dictate into it again.

    *Pass:* the first dictation's log names an `.accessibility` attempt that lands **read-back
    verified**; `strategies.json` shows `learnedAllowlist` true for that bundle ID; the *second*
    dictation starts at `.accessibility` with no probe. The Apps tab shows the row as
    `typing directly`.

    *Failure:* a promotion recorded without read-back verification — that is the silent lie the
    whole rung exists to catch, and it must never reach the learned allowlist. Also a failure: the
    accessibility rung landing verified and the app *not* being promoted, which means the memory
    learned nothing from its own success.

92. **`matrix-row` Secure Input in the matrix — refusals teach the memory nothing.**

    Rows 21–22, with memory active. Step 27 already covers the refusal; this row adds the memory.

    *Gesture:* get a transcript into the failsafe, focus a password field (1Password, or any
    sign-in page), press ⏎ to re-run the ladder. Then read `strategies.json`.

    *Pass:* all four — the log records `attempted: []` (no rung, not even clipboard); the failsafe
    shows the password-field copy; the transcript is still present and copyable; and
    `strategies.json` gained **nothing** for that bundle identifier.

    *Failure:* any strategy written from a refusal. A run that attempted no rung learned nothing,
    and recording it would teach the memory that rungs failed which were never tried.

93. **`matrix-row` per release, defined.**

    *Gesture:* run step 88 once per release and append one row to the tracked table.

    *Pass:* the table has a row for this release.

    *Failure:* it does not. An unrun step is a failed step — this file's own rule, applied to the
    one number P2 is judged on.

### Tracked table — one row per release

First-method-success (FMS) = deliverable rows whose expected rung *landed*, over the 20
deliverable rows. Bar: ≥19/20. Recorded, never gated.

| Release | Date | Rows run | Skipped | Voided | FMS | Notes |
|---------|------|----------|---------|--------|-----|-------|
| _(none yet)_ | — | — | — | — | — | The matrix has never been run. Step 87's baseline is its first execution, and until it happens Vocca has **no** measured injection-success number of any kind. |

---

## 13. The Speech tab — the engine picker, its first execution

`PRODUCT_SPEC.md:254-262` specifies this surface, and until the `speech-tab` aspect the tab was
read-only and said so. The machinery under it — the tier-keyed model store, the settings store,
the switch that replaces a resolver without a restart — shipped in three earlier aspects and has
never been touched by a finger.

Nothing here runs in CI, for the window-server reason and three more: the tab downloads a 470 MB
model over a network the zero-network probe forbids, removes it from a real Application Support
directory, and switches an engine whose CoreML load cannot reach a hosted runner. What CI proves
is the half above the glass — `SpeechTabReducerTests` for every decision, `SpeechTabCopyTests` for
every word, `EngineStateAgreementTests` for the three surfaces agreeing, and `SpeechTabWiringTests`
for the gestures reaching the root. **The page itself has never been rendered.**

Run these with the model already downloaded (step 17), and read the menu bar icon during each —
the tab is only one of the three surfaces, and the point of steps 97–99 is what the *other two*
say at the same moment.

94. **The Speech tab renders, and reports what is actually on this Mac.**

    *Gesture:* open Settings > Speech. Compare each row's badge and disk figure against
    `~/Library/Application Support/Vocca/models/` in Finder.

    *Pass:* Parakeet reads `[ installed ]` with a figure matching Finder's for its directory; both
    Whisper tiers read `[ download ]` with no figure at all — not "0 bytes". Each engine row
    carries its status line, and Whisper's says it has never been measured.

    *Failure:* a badge or a figure that disagrees with Finder; a "0 bytes" beside a model that is
    not there; or the two engines presented as equally exercised, which is R7's whole point and
    the one claim in this tab nobody has earned.

95. **One Whisper tier downloads without making the other read installed.**

    The keying defect aspect 1 fixed, seen from the surface a user would have acted on.

    *Gesture:* press [Download] on the Whisper **turbo** row and let it finish. Read both Whisper
    rows.

    *Pass:* turbo reads `[ installed ]` with its figure; **q5_0 still reads `[ download ]` with no
    figure**. Two directories exist under `models/`, each with its own `verified` marker.

    *Failure:* q5_0 reading `[ installed ]`. It would send the next dictation into
    `.modelUnavailable` with no explanation on the page that promised otherwise.

96. **The engine switch takes effect on the next press, with no restart.**

    *Gesture:* with the Whisper model downloaded, select Whisper in the tab. Wait for the menu bar
    to leave its warming state, then dictate a sentence into TextEdit. Quit and relaunch Vocca and
    read the tab.

    *Gesture (second half):* `log show --predicate 'subsystem == "dev.vocca.Vocca"' --last 2m`
    and find the transcript's engine attribution.

    *Pass:* the text lands, the log attributes it to `whisper-large-v3-turbo`, and the tab still
    shows Whisper selected after the relaunch. **This is also whisper's first real transcription
    ever** — `SMOKE_CHECKLIST.md` step 19 remains the WER run, but this is the first time the
    engine has produced text for a user at all.

    *Failure:* text attributed to Parakeet; a required restart; or a selection that reverts.

97. **In-between window (a): the model is removed, and all three surfaces say the same thing.**

    *Gesture:* with Parakeet selected and idle, press [Remove] on its row and confirm. Then read
    the tab, the menu bar icon **and** its menu, and then press ⌥Space.

    *Pass:* all four — the row flips to `[ download ]` with no figure; the menu bar shows the
    missing-model icon and says *"The speech model isn't on this Mac"* (**not** "Downloading…
    works as soon as it finishes", which would promise a wait that never comes); the press is
    refused with the model-unavailable panel; and **the pill returns to idle rather than sitting
    in OPENING**.

    *Failure:* any surface describing a state that ended — especially a pill left mid-gesture. It
    did exactly that until `EngineStateAgreementTests` asked, and this is the row that confirms
    the fix on a real screen.

98. **In-between window (b): the newly selected engine is warming, and nothing calls it broken.**

    *Gesture:* switch engines and, in the seconds before the menu bar settles, read the tab and
    the menu and press ⌥Space once.

    *Pass:* the tab says the engine is getting ready, the menu bar shows the warming state with
    *"Loading the speech model"*, and the press is refused with the model-unavailable panel and
    the pill returning to idle. Nothing anywhere says a model is missing: it is on disk and the
    switch worked.

    *Failure:* a missing-model report during a warm-up. It would tell the user their switch broke
    something.

99. **In-between window (c): a background download blocks nothing.**

    The half a naive wiring gets wrong.

    *Gesture:* with Parakeet selected, prepared and idle, press [Download] on a Whisper row. While
    it runs, read the menu bar and dictate a sentence.

    *Pass:* the menu bar stays ready throughout, the dictation works normally, and the Whisper row
    still shows its progress bar — unblocked is not the same as invisible.

    *Failure:* a menu bar reporting the download as a reason dictation is unavailable. A working
    Vocca would spend the whole transfer saying otherwise.

100. **Removal is refused mid-dictation, and says why.**

    *Gesture:* start a toggle dictation (⌥Space), and while it is recording press [Remove] on the
    selected engine's row.

    *Pass:* nothing is deleted and the tab shows *"Finish the dictation first. Vocca won't remove
    a model while it's listening."* The dictation then completes normally.

    *Failure:* a deletion under a live microphone, or a button that silently does nothing — a
    control that refuses without explaining teaches a user the app is broken.

101. **M12: removing a tier mid-download cancels the transfer rather than breaking it.**

    *Gesture:* start a download on a Whisper row, and at roughly 30% press [Remove] on that same
    row and confirm. Then read the log.

    *Gesture (second half):* `log show --predicate 'subsystem == "dev.vocca.Vocca"' --last 2m`.

    *Pass:* the row returns to `[ download ]`, the directory is gone from `models/`, and the log
    records a **cancellation**, not `ModelDownloadError.transportFailed`.

    *Failure:* a `transportFailed` in the log. It means the directory was deleted under the
    running transfer, and the app blamed the transport for something the app did.

---

## 14. The manifests, and whisper's first real bytes

*(Added 2026-08-29, `verification-smoke`.)* Two claims sit under the engine picker, and shipping a
[Download] button turns both into a 1.6 GB risk a user pays for.

The first is that **the shipped manifests are unverified, not defective.** The placeholder this
repository already shipped once — `ac381d0`'s 2-byte `config.json` carrying the SHA-256 of the
literal string `{}` — does **not** reproduce in any manifest here: that digest
(`44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a`) appears nowhere, no entry
declares a 0- or 2-byte size, and no digest repeats across files. What is open is provenance.
`672367e` added both Whisper manifests with no provisioning run recorded behind it — the same
evidentiary shape as `ac381d0` — and `Scripts/provision-asr-fixtures.sh` gained its whisper support
the day *before* those files landed, with no record it was used. Neither reading is upgraded here.
The comparison has simply never been made, and step 102 is where it is made.

The second is that **whisper has never transcribed anything.** Step 19 is unexecuted, and the
tolerances `WhisperCppEngineWERTests` asserts are seeded from Parakeet's table rather than measured
on whisper's output (`docs/planning/second-asr-engine/fixture-harness/tolerances_20260810.md`).

`ManifestDigestVerificationTests` is the machinery for step 102, and CI runs only half of it: the
planted-mismatch rows, over synthesised files, which are what make a green badge say anything about
the verifier at all. The artifact half skips visibly without `VOCCA_MODEL_DIR` and downloads
nothing — it reads bytes already on this disk. Run these steps **in order**: a transcription
failure after an unverified download cannot be attributed to anything.

102. **The shipped manifests, checked against real bytes for the first time.**

    *Gesture:* provision both Whisper tiers, then run the verification against the root they
    landed in:

    ```
    ./Scripts/provision-asr-fixtures.sh --engine whisper-large-v3-turbo --tier turbo  --root <root>
    ./Scripts/provision-asr-fixtures.sh --engine whisper-large-v3-turbo --tier q5_0   --root <root>
    VOCCA_MODEL_DIR=<root>/whisper-large-v3-turbo/1 \
      swift test --filter testEveryShippedManifestMatchesTheProvisionedBytes
    ```

    Run it a third time with `VOCCA_MODEL_DIR` pointed at the Parakeet install (step 17's), so all
    three shipped manifests are answered for. The run prints `MANIFEST-VERIFY:` naming every tier
    it did **not** find under that root — those tiers are still unverified after the run, and the
    line exists so a partial check is never read as a full one.

    *Pass:* the test passes for each root, and between the runs every tier has appeared in a
    *verified* list rather than in an unverified one. A pass here is the first evidence in this
    repository's history that a Whisper manifest describes the artifact it claims to.

    *Failure:* any verdict line. `manifest declares N bytes, disk has M` is an entry that was
    written rather than measured — the `ac381d0` shape exactly; `manifest declares sha256 …, disk
    has …` with a matching length is a manifest generated from different bytes than the ones the
    URL now serves. Either way the manifest is regenerated from the provisioning run's own output
    and committed with the run recorded, never hand-edited to match.

    *Void — not fail — if:* the provisioning run did not complete. A `.part` file anywhere under
    the version directory, or a transfer that was interrupted, means the precondition (a complete
    artifact) did not hold, and the verification result says nothing about the manifest. Re-run the
    provisioning to completion first. Likewise void the run if `swift test` reported the test as
    **skipped**: that is the env var not reaching the process, not a clean sheet.

103. **Whisper produces text, on both tiers, through the Speech tab.**

    Step 96 is turbo's row and calls itself whisper's first real transcription. This step adds what
    no row covers yet — that the **tier** choice changes which bytes actually run — and it must not
    be attempted until step 102 has passed for the tier in question.

    *Gesture:* with the turbo tier installed and selected, dictate a sentence into TextEdit. Then
    select the q5_0 tier in the Speech tab, wait for the menu bar to leave its warming state, and
    dictate the same sentence again.

    *Gesture (second half):* `log show --predicate 'subsystem == "dev.vocca.Vocca"' --last 5m` and
    read both transcripts' engine attribution and the model directory each load came from.

    *Pass:* both dictations land text, and the second load reads its bytes from
    `whisper-large-v3-turbo-q5_0/1/` — a different directory and a different `verified` marker from
    the first. Both transcripts are attributed to the whisper identity; the two tiers share it,
    because attribution is keyed by engine and storage by tier, and that is correct.

    *Failure:* the second dictation loading from the turbo directory, which is the tier-keying
    defect returning at the only layer that can still hide it. Also a failure: a tier switch that
    requires a restart, or a second dictation that produces no text at all after the first did —
    the q5_0 artifact is a real model, and a tier the picker offers must work or not be offered.

    **This step settles nothing about accuracy.** It says whisper runs. What it is worth is
    ordering: step 104's numbers mean nothing until this passes, because a WER measured through a
    load that took the wrong bytes measures the wrong model.

104. **Re-baseline whisper's WER tolerances from step 19's run, with the run recorded.**

    Step 19 is the run and stays its home; this step is what happens to the numbers afterwards, and
    it exists because a real run that changes no number leaves the seeded table looking measured.
    The procedure is
    `docs/planning/settings-live-controls/verification-smoke/tolerances_20260829.md` — measure →
    margin → founder-signed → land in exactly the two test files.

    *Gesture:* run step 19. Record, in that file's measured-values table: the six per-fixture WERs
    the runner printed, the machine (model identifier and chip), the **artifact hashes** — the
    `sha256` of each file from the manifest step 102 has now verified, so the numbers name the
    bytes they were measured on — and the date. Then apply the margin, take the founder's sign-off,
    and land the signed numbers in `WhisperCppEngineWERTests.swift` and
    `ParakeetEngineWERTests.swift` together.

    *Pass:* the record carries a measured row, and the two tolerance tables carry numbers with a
    measurement and a signature behind them. Until then, every whisper accuracy claim in this
    repository is a claim about structure.

    *Failure:* a run whose numbers exceed the seeded tolerances and a tolerance raised to fit them.
    A failing real run is the correct outcome and re-baselines with data in hand; it is never a
    reason to relax a number quietly. Also a failure: landing whisper's table without Parakeet's —
    the two engines run the same six fixtures, and moving one alone hides a regression in the
    other.

    *Void — not fail — if:* step 102 has not passed for the artifact the run used. A WER measured
    against unverified bytes measures an unknown model, and recording it would close a question
    that is still open — this file's first rule, applied to the one table nobody has measured.

---

## 15. The Cleanup tab — the rungs become a choice, and the dialog before the cloud one

*(Added 2026-08-29, `cleanup-tab`.)* Two things ship here that CI cannot execute, and they fail in
opposite directions.

The first is the **summary line**, which until this aspect was the literal `("Built-in rules", nil)`
— so a user on Ollama or BYOK read "Built-in rules" with no endpoint while the widget's egress
badge, folded from the same resolved provider, correctly showed the cloud marker. Two surfaces
describing one fact, and one of them lying. That is fixed at the derivation, and the derivation is
tested headlessly; what is *not* tested is that the two surfaces agree **on a running Mac**, because
the widget needs a window server and the resolver needs a real `cleanup-config.json`. Step 106 is
that comparison, and it is the only place it has ever been made.

The second is the **one-time cloud confirmation** (`PRODUCT_SPEC.md:273`). Its decisions are pure
and `CleanupCloudConfirmationTests` runs all of them — three planted mutations fail that gate. But
a dialog is not its decision table: whether it is legible, whether the accepting button is the one
a person's hand goes to, and whether it appears at all through SwiftUI's
`confirmationDialog(_:isPresented:)` are questions only a human at a window can answer. **A
confirmation nobody can read is the same as no confirmation**, and this surface is the one
`ROADMAP.md` principle 2 says must survive an audit of the actual code paths — a regression here is
positioning-fatal, not a UI bug.

Nothing in this section may be run against a Vocca whose `cleanup-config.json` you care about. Copy
it aside first; step 105 rewrites it.

105. **The choice is a control, and it reaches the file.**

    *Gesture:* quit Vocca. `cp ~/Library/Application\ Support/Vocca/cleanup-config.json /tmp/` if
    one exists. Launch, open Settings → Cleanup. Read the three rungs against
    `PRODUCT_SPEC.md:266-268`: the names, the two sentences each, and the ⚠️ on the cloud row.
    Select **Local AI**, filling the endpoint and model fields first
    (`http://localhost:11434`, any model name). Then `cat` the file.

    *Pass:* the file names `"provider": "ollama"` with the endpoint and model you typed, is
    pretty-printed with sorted keys, and its slashes are unescaped — it is still a file a person can
    hand-edit, which is a supported path and not merely a legacy one. The ⚠️ renders as a yellow
    warning triangle, not as a thin monochrome outline: the outline is what U+26A0 without its
    variation selector looks like, and a warning that reads as decoration is not a warning.

    *Failure:* a rung that cannot be selected because the fields appear only *after* selection —
    which would make the LLM rungs unreachable. Also a failure: the file gaining a key, a token or
    anything resembling one. The BYOK key lives in the Keychain; a plain file in Application Support
    is not where it goes, and `CleanupConfigStoreTests` asserts the absence but cannot assert what a
    future hand does.

106. **The tab and the egress badge agree, on a machine, in both directions.**

    This is F3's real execution. The defect was a literal, so nothing configuration could do would
    move it; the fix is a derivation, and a derivation can still be wired to the wrong thing.

    *Gesture:* with a **BYOK** rung selected and a key in the Keychain (step 76's key), restart
    Vocca — the resolver resolves once at launch, which is exactly what the tab's own
    "takes effect the next time Vocca restarts" line says. Open Settings → Cleanup and read the
    "Using" line. Then dictate a sentence and watch the recording pill.

    *Pass:* the tab names the BYOK provider and the endpoint you configured, and the pill carries
    the ☁︎ marker while recording. Switch back to **Basic**, restart, and repeat: the tab says
    "Runs on this Mac. Nothing is sent anywhere." and the pill carries no marker.

    *Failure:* the tab and the pill disagreeing in either direction. The badge showing a cloud
    marker over a tab reporting the local rung is the worse of the two — but a tab claiming egress
    that is not happening is not harmless either: a warning that fires wrongly is one people learn
    to ignore.

    *Void — not fail — if:* you did not restart between the change and the reading. The resolver is
    resolve-once by design, and comparing a fresh tab against a stale provider measures nothing.

107. **The cloud confirmation appears, says what is sent, and declining costs nothing.**

    The must-have, and the step this section exists for.

    *Gesture:* with the acknowledgement cleared —
    `defaults delete dev.vocca.Vocca settings.cloudCleanupAcknowledged` with Vocca quit — launch,
    open Settings → Cleanup, and while on a rung that is **not** Basic (Local AI, so the previous
    choice is something a reset would visibly destroy), select **Cloud (BYOK)**. Read the dialog.
    Decline it.

    *Pass:* a dialog appears before anything is written. It names the endpoint, says the text of
    every dictation is sent there with the API key, and says plainly that the **audio is never
    sent**. On declining: the radio is still on Local AI — not Basic, not blank — and
    `cleanup-config.json` still says `"provider": "ollama"`. Select Cloud again: the dialog appears
    **again**, because declining is not agreeing.

    *Failure:* the file changing before the dialog is answered. Also a failure: declining leaving
    the radio on Basic or on nothing — the previous choice is the one that was there, and a reset to
    the default is a setting silently changed by a dialog the user refused.

108. **It is one-time, and it means once.**

    *Gesture:* accept the dialog. Confirm the file now says `"provider": "byok"`. Switch to Basic,
    switch back to Cloud. Then quit Vocca, relaunch, and switch to Cloud once more.

    *Pass:* the dialog does not appear on any of the three later selections. `defaults read
    dev.vocca.Vocca settings.cloudCleanupAcknowledged` reads `acknowledged`.

    *Failure:* the dialog appearing again after a relaunch, which would mean the acknowledgement
    lives in the window rather than in the settings store — the difference between "one-time" and
    "once per window", and the reason people stop reading dialogs.

    *Void — not fail — if:* you cleared the key between steps. This step is about the flag, and a
    rung that refuses for a missing endpoint never reaches the dialog to be asked about.

109. **A rung that cannot work is refused in words, not written.**

    *Gesture:* clear the Ollama **model** field and select Local AI. Then clear the BYOK endpoint
    and select Cloud.

    *Pass:* each is refused with a sentence naming what is missing, and `cleanup-config.json` is
    unchanged both times.

    *Failure:* either selection being written. An `ollama` block with no model does not decode, and
    `CleanupConfig.tolerantDecode` degrades the **whole** config to rules with a loud log — so the
    file would say Local AI, the radio would say Local AI, and Vocca would be running the built-in
    rules. That is the exact class of defect this whole aspect exists to end, reappearing one layer
    down.

110. **Restore your config.**

    *Gesture:* `cp /tmp/cleanup-config.json ~/Library/Application\ Support/Vocca/` if you saved one
    in step 105, or delete the file to return to the shipped default. Restart and confirm the tab
    reads "Runs on this Mac. Nothing is sent anywhere."

    *Pass:* the machine is back where it started, and the zero-network default is what is running.

    *Failure:* leaving a tester's machine pointed at a cloud endpoint after a smoke run — which is
    a real cost, not a tidiness note: every subsequent dictation on that machine sends text to it.

---

## 16. The hotkey becomes rebindable — `hotkey-rebinding`

Nothing in this section runs in CI. The recorder is a window, the rebuild needs a live tap, and the
system-shortcut read looks at *your* preferences — no window server, no Accessibility grant and no
meaningful preferences exist on a hosted runner. These steps are the first execution of all three.

**Before you start:** note the chord you are on (Settings → General) so step 119 can put it back.

111. **A rebind takes effect on the next press, with no restart.**

    *Gesture:* Settings → General → click the shortcut and press `⌃⌥D`. Close Settings. Focus
    TextEdit and press `⌃⌥D`, say a sentence, press again. Then press `⌥Space` and say something.

    *Pass:* `⌃⌥D` starts and ends a dictation and the text lands. `⌥Space` does nothing at all —
    no pill, no menu bar change — and, in a text field, types the non-breaking space it always did
    before Vocca claimed it.

    *Failure:* `⌥Space` still starting a session. The old wiring is still routed, which means the
    rebuild swapped the configuration but not `modeRouting.active`.

    *Void — not fail — if:* you never closed Settings. The window is the one surface allowed to
    take focus, so a chord pressed while it is key goes to the recorder, not the tap.

112. **It survives a relaunch.**

    *Gesture:* quit Vocca entirely (menu bar → Quit). Reopen it. Press `⌃⌥D`.

    *Pass:* the chord still works, and Settings → General still shows it.

    *Failure:* being back on `⌥Space`. The chord was adopted in memory and never persisted, or the
    launch read is not reaching both machines.

113. **A single key works, unmodified — the accessibility requirement, executed for the first time.**

    *Gesture:* rebind to **`F13`** (a bare press, no modifiers). Dictate with it.

    *Pass:* `F13` alone starts and ends a dictation.

    *Failure:* the recorder refusing `F13`, or accepting it and then never firing. The second is the
    one to watch for: macOS sets the `fn` bit on F-keys with no user involvement, so a binding
    stored as `fn`+F13 is unequal to the `[]` the adapter delivers after stripping it, and the
    hotkey silently never matches. This is exactly the failure `ModifierSet`'s documentation
    predicts, reached from the other side.

    *Void — not fail — if:* your keyboard has no `F13`, or a third-party tool has claimed it. Use
    `F14`–`F20` instead; any of them exercises the same rule.

114. **A chord that would cost you a key is refused, in words.**

    *Gesture:* try to bind a bare **`e`** (no modifiers). Then try bare **`Escape`**. Then try
    holding only `⌘` and releasing.

    *Pass:* each is refused with a sentence saying why, the shortcut is unchanged, and nothing is
    written. Then bind `⌃⌥E` — a modified letter — and confirm it **is** accepted.

    *Failure:* any of the three being accepted. A bare `e` makes the letter `e` untypeable on the
    whole machine, and the way back is this window, which needs the keyboard.

115. **A collision with one of macOS's own shortcuts is named.**

    *Gesture:* first **change** a system shortcut so Vocca can see it: System Settings → Keyboard →
    Keyboard Shortcuts → Mission Control, and set "Mission Control" to something distinctive like
    `⌃⌥M`. Then attempt to bind that same chord in Vocca.

    *Pass:* Vocca warns and names the shortcut, and **still lets you bind it** if you confirm — the
    warning is advice, not a veto, because your machine is the authority on your shortcuts.

    *Failure:* a refusal instead of a warning, or a warning naming the wrong shortcut.

    *Void — not fail — if:* Vocca stays silent on a shortcut you did **not** change. Coverage of
    Apple's own shortcuts is known to be incomplete and is **not understood**: on the authoring
    machine, Spotlight's identifiers (64/65) are absent from `com.apple.symbolichotkeys` entirely,
    while other identifiers are present and hold their stock defaults — identifier 118 is `⌃1`,
    "Switch to Desktop 1", untouched. So a missing warning on ⌘Space is a known gap with an unknown
    cause, not a defect this step can adjudicate. **If you do get a warning where this step did not
    predict one, that is information — write it here.**

116. **A rebind during a dictation is refused, and the dictation is unharmed.**

    *This is the only real execution of the hot-mic guard.* Everything CI can prove about it is
    proven over fakes.

    *Gesture:* start a toggle dictation and keep talking. With the session live, open Settings and
    try to rebind. Then close Settings and end the dictation normally.

    *Pass:* the rebind is refused **visibly** — a sentence in the tab, not just a log line — the
    pill keeps recording throughout, and ending the session delivers the text as usual. The chord
    is unchanged afterwards.

    *Failure:* the rebind succeeding. A rebuild mid-session discards the machine that owns the
    recording; the microphone is never closed and no `.ended` is ever delivered. That is a hot mic
    and a lost transcript in one, and it is rated Fatal in the C1 risk register.

    *Also check:* repeat it in the window **immediately after a press**, before the pill appears.
    A press claims the key and leaves an opening owed until a later run-loop turn, and a rebuild
    inside that window strands the pill in OPENING with nothing able to move it.

117. **The three surfaces agree, and the tab states its own limits.**

    *Gesture:* after a rebind, read the chord in Settings → General, in the menu bar's VoiceOver
    label or tooltip, and in a fresh onboarding run (delete the completion flag to see it).

    *Pass:* all three name the same chord, in the same notation. The General tab also says, in
    plain words, that Vocca cannot see shortcuts other applications have claimed **and** that it
    only sees macOS shortcuts you have changed yourself.

    *Failure:* any surface showing the old chord — the display was captured once instead of read
    live — or the tab claiming a complete conflict check.

118. **Several rebinds in a row leave a hotkey that still works.**

    *Gesture:* rebind four or five times in succession — `⌃⌥D`, `F13`, `⌥⇧V`, `⌃⌥D` again —
    dictating once after each.

    *Pass:* every chord works immediately after it is set, and the last one still works after a
    relaunch.

    *Failure:* a chord that stops working after several rebinds, which means a retired timer or
    watchdog is still holding the route. **Watch for the silent shape of this:** Vocca is
    `LSUIElement`, so a dead hotkey looks exactly like a working one until you press it. If nothing
    happens, check the menu bar icon before assuming you mistyped.

119. **Put your chord back.**

    *Gesture:* rebind to whatever you noted before step 111 — `⌥Space` unless you had changed it.
    If you changed a system shortcut in step 115, change that back too.

    *Pass:* the machine is where it started.

    *Failure:* leaving a tester on `F13`, or leaving Mission Control on a chord they did not
    choose. Both are real costs to the next person to use that machine.

120. **First real dictation with the speculative feed live** (batch engine; engines do not stream
    yet — the feed's lifecycle is what these steps observe, never partials that cannot appear).

    *Gesture:* press the hotkey, speak 3–5 s, release.

    *Verify the state was entered:* the log carries the feed's start and stop lines
    (`log stream --subsystem dev.vocca.Vocca | grep "the feed"` — the lines land in
    `SpeculativeFeed.start` / `terminate` / `cancel`).

    *Pass (tighter than the failure):* the mic dot is gone and the widget is IDLE within 5 s of
    key-up (the failure this guards is an orphaned feed = hot mic); the final lands in the field
    exactly as before the feed; no failure notice.

    *Failure:* a feed that never started is caught by the missing start log; a feed that never
    stopped is caught by the mic dot.

121. **Escape mid-session with the feed live.**

    *Gesture:* start a session, speak, press Esc.

    *Verify the state was entered:* the feed's stop log appears and the widget shows the
    discard-to-IDLE transition.

    *Pass (tighter than the failure):* nothing is injected (the field is unchanged), the mic dot
    is out, and the widget is IDLE — the orphaned-feed and injected-after-cancel failures both
    leave the mic dot or the field non-empty.

122. **Sub-0.3 s press with the feed live.**

    *Gesture:* tap the hotkey and release immediately.

    *Verify the state was entered:* the feed flushed a sub-minimum stream (the terminate-with-
    remainder path — the stop log's remainder count is small or zero).

    *Pass (tighter than the failure):* **no** `.transcriptionFailed` notice appears and the widget
    returns to IDLE — the failure this guards is the regression to "Voice processing failed" on a
    quick tap.

123. **Quit mid-recording** (executed by nothing in CI — the window-server rule).

    *Gesture:* start a session, then quit from the menu bar while recording.

    *Verify the state was entered:* the feed's stop log appears (the quit path's `feed.cancel()`
    runs before `terminate`) and the mic dot goes out.

    *Pass:* the process exits cleanly.

    *Failure:* a feed still ticking at process exit — the quit path's cancel is the claim that
    "no feed left running" is true in the code that runs, not only as a property of process death.

---

## When this file is wrong

Add to it. A limitation discovered by a human at 11pm before a release and not written down here
will be discovered again by the next person, at 11pm, before the next release.
