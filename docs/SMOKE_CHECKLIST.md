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
error. Step 46 is why that must stay true.

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

### The injection ladder — real apps, which no CI run touches

*(Added 2026-08-09, `injection-adapters` phase E — the matrix PRD R10 demands, `ROADMAP.md:89-91`;*
*step 12 is this section's coarse version.)* Every adapter on the ladder is executed by nothing in
CI (§8): the AX rung needs per-app Automation grants, and the real pasteboard and the ⌘V need a
live session and the same grant. The matrix below is the P0 gate's evidence (`ROADMAP.md:95`) and
the only execution the adapters ever get.

The gesture is the same in every row: **dictate a fixed short phrase** ("the quick brown fox jumps
over the lazy dog"), let the ladder run, then select all, copy, and compare with `pbpaste` —
**byte for byte** — against the phrase, the discipline of step 43. The comparison is against the
transcript Vocca captured, not against your intention: with a clean phrase and the shipped engine
(word-perfect on founder hardware, step 18) the two are the same text, and the distinction is
load-bearing because an ASR mishearing is not an injection failure — what must land verbatim is the
field *versus the transcript*.

*Pass* in every row is the same: the field holds the transcript verbatim and no failsafe appears.
*Failure* in every row is the same shape and must never be silent: the failsafe shows with a
plain-language reason (`PRODUCT_SPEC.md:109-114`) — a report of success with nothing in the field is
the exact silent success the read-back verification exists to catch, and a row that ends that way
is a bug, not a pass. The ladder's log names the rung that landed each insertion
(`.accessibility`, `.clipboardPaste`, `.keystrokeSynthesis`), and every row states which one it
expects.

19. **Native AppKit: Notes, Mail, TextEdit** — the three seeded applications
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

20. **Electron: VS Code, Slack** — not seeded, the AX-lies class, so clipboard leads.

    *Gesture:* dictate the phrase into a VS Code text buffer; into a Slack message input.

    *Pass:* the log names **`.clipboardPaste`** and the field holds the transcript verbatim — the
    field swallows the paste exactly as it swallows the user's own ⌘V.

    *Failure:* the failsafe appears with the exhausted reason — never a silent nothing. The
    per-app-denied variant is step 26.

21. **Browsers: Safari and Chrome — a plain field, and Google Docs' custom editor.**

    *Gesture:* dictate into a plain web input in Safari and in Chrome; then into a Google Docs
    document — the custom editor, which is neither a native field nor a plain input, and the
    matrix's named hostile-to-AX case (`ROADMAP.md:91`).

    *Pass:* `.clipboardPaste` named, verbatim in all three. Google Docs is the row where
    paste-vs-AX earns its keep: the text must land in the document, not in the hidden textarea it
    was pasted into.

    *Failure:* failsafe with the exhausted reason. A Docs row that fails while Safari's passes is
    expected to happen — they fail differently, which is why the row exists.

22. **Terminals: Terminal, iTerm2, Ghostty.** A terminal is a shell before it is a field, so the
    rung matters less than what the shell does with the text.

    *Gesture:* at a `$` prompt in each, dictate the phrase. Nothing executes until ⏎ is pressed,
    so the check is the text sitting at the prompt uninterpreted. Run the row with *Secure
    Keyboard Entry* unticked — ticked, it is the Secure Input class (step 24, and the capture side
    in steps 52–54).

    *Pass:* the phrase sits at the prompt exactly once, byte-identical, and no shell error or
    continuation prompt appears.

    *Failure:* the failsafe; or the phrase split, dropped, or interpreted (a `>` continuation
    prompt means a line got split).

23. **Java/other: IntelliJ.** The AWT field class — one working native field says nothing about
    it, which is why the matrix names it.

    *Gesture:* dictate the phrase into an editor buffer.

    *Pass:* verbatim, `.clipboardPaste` (not seeded).

    *Failure:* failsafe with the exhausted reason.

24. **Known-hostile: a Secure Input field, and 1Password — injection refuses, and no rung is
    attempted.** The injection side of the Secure Input story; the capture side is steps 52–54,
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

25. **Clipboard-manager coexistence: Raycast, Alfred, Paste, Maccy.** The 100-dictation survival
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

26. **Per-app Automation permission denied — the honest drop to the clipboard rung.**

    *Gesture:* in System Settings ▸ Privacy & Security ▸ Automation, deny Vocca's Automation
    permission for Notes (deny the first prompt, or revoke an existing grant — TCC grants per
    app, and this cannot be granted on a runner), then dictate the phrase into Notes.

    *Pass:* the text **still lands verbatim** — the log names `.clipboardPaste` after
    `.accessibility` reported failure. The drop is honest: the rung reports the truth about the
    denial and the ladder falls through, instead of reporting a success it did not have or
    skipping the rung entirely. Re-granting the permission and re-dictating restores step 19's
    `.accessibility` landing.

    *What this step guards:* an adapter that reports `succeeded` for an AX call the TCC layer
    denied — the silent-success class, on the one rung the verification exists to police.

27. **Failsafe copy-without-focus: ⌘C while the target app keeps focus.** The product promise
    (`PRODUCT_SPEC.md:106`): the failsafe window shows, never takes focus, and ⌘C copies.

    *Gesture:* get the failsafe showing with a full transcript (any row above, or step 24's
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

28. **The failsafe appears on ladder exhaustion — and persists.** The never-auto-dismiss promise
    (`PRODUCT_SPEC.md:99-104`): the reducer contains no time-based transition at all, so nothing
    dismisses the window but the user.

    *Gesture:* dictate the phrase into an app the ladder cannot land in — or revoke Automation for
    an allowlisted one (step 26) — and leave the failsafe showing. Keep working in the target app;
    do not touch the window for several minutes.

    *Pass:* the window is still showing, with the same transcript and the same cause-specific
    reason, however long it sits — no auto-dismiss, no dimming, no re-stacking — and the transcript
    is still selectable and copyable throughout.

    *Failure:* the window dismissed itself, changed its copy, or stopped responding. A
    self-dismissal is a regression of the one claim this surface exists to make, not a tweak.

29. **⌘C while the target app keeps focus — the non-activating panel's key equivalent.** Step 27
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

30. **⏎ retry re-runs the ladder against a freshly clicked field.** The retry affordance
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

31. **Relaunch recovery: the failsafe reappears with its captured-at note.** The journal write is
    durable before the window ever shows (the ordering the suite asserts); this is the relaunch half
    only a human can run.

    *Gesture:* get the failsafe showing with a full transcript, quit Vocca (⌘Q), relaunch.

    *Pass:* the failsafe reappears showing the same transcript, with its "captured at" note
    (`PRODUCT_SPEC.md:117`) — loaded back from `~/Library/Application Support/Vocca/recovery/` —
    and copy and retry work exactly as before the quit.

    *Failure:* the failsafe does not reappear, or the transcript is empty, truncated, or missing
    the captured-at note.

32. **The journal: bounded on disk, purged on resolve.** The single-slot seam means at most one
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

33. **`start(delivering:)` on an already-started source tears the old tap down first.** The policy
    re-creates by calling `start` once and relies on this rather than calling `stop()` itself, because
    doing both would second-guess the contract. An adapter that merely overwrote its stored port leaks
    a `CFMachPort` and a run-loop source and leaves a **second tap installed whose callback still
    points at the previous context** — a use-after-free on the next keystroke, reached by a caller who
    did everything the protocol documents. `TapHealthPolicyTests` pins this against the *fake*; the
    adapter can forget it entirely with the whole suite green.

34. **`resumeDelivery()` reads the result back.** `CGEventTapEnable` returns `Void` and cannot fail
    loudly, so an adapter that reports `.resumed` because it made the call reports a dead tap as
    healthy — and the re-creation acceptance H4 requires never happens. Confirm the implementation
    calls `CGEventTapIsEnabled` afterwards and answers from *that*.

35. **`resumeDelivery()` answers `.failed` when it holds no tap**, and **`isDelivering` answers
    `false`**. The policy tracks tap existence itself and does not ask without one, so this is
    defence in depth — which is exactly why it needs confirming rather than assuming: it is the second
    of the two places "healthy while deaf" could be reached from, and the first one shipped.

36. **`isDelivering` is a question put to the system, never a cached flag.** It is the read the ~1 s
    health poll is made of, and the whole point of that poll is to find out about a tap that died and
    told nobody. An adapter answering from a remembered value reports the last thing Vocca was told,
    which is precisely what the poll exists to bypass.

**And one thing a conforming adapter still cannot do**, so that this list is not read as the whole of
it: the health poll asks `CGEventTapIsEnabled`, which catches a tap that was *disabled* silently and
**not** one that is enabled and deaf — created successfully, reporting itself enabled, delivering
nothing. Two known instances: a mask cleared at creation before the Accessibility grant, and Secure
Input. **Phase 6 closed the second and left the first**, because only the second has an API
(`IsSecureEventInputEnabled`); see "What CI cannot cover" §6 and steps 52–54. For the first, step 15's
toggle-mode check and step 46's note are still the only places it would be noticed at all.

37. **The disable notifications reach `TapHealthPolicy.tapWasDisabled(_:)`, not the sink.** Routing
    `kCGEventTapDisabledByTimeout` / `…ByUserInput` into `HotkeyEventSink` ends the session correctly
    and leaves the tap dead forever — `SessionRules.swift:106-113` names that failure as a sibling of
    the stuck-microphone bug rather than a lesser cousin. Also confirm the two are **not** collapsed
    into one call: one means Vocca's own callback was too slow and the other does not.

### The tap itself, which no CI run executes a line of

*(Added 2026-08-06, `hotkey-source` phase 6, from phases 4 and 5.)* Every line of
`Sources/VoccaHotkey/CGEventTapSource.swift` is unreachable in CI — `CGEvent.tapCreate` returns
`nil` without an Accessibility grant — so these are the gestures that execute it. They are ordered
by what their failure costs, not by convenience.

38. **Time how long the microphone indicator takes to go out after a disablement.** The most valuable
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

39. **Force a re-creation, then type exactly one character.** The re-start path — `stop()` at the head
    of `start(delivering:)` — and the only thing standing between a caller who does everything the
    protocol documents and a use-after-free.

    *Gesture:* with the hotkey armed, force a re-creation (sleep and wake the machine, or revoke and
    re-grant Accessibility in System Settings), then type `x` once in TextEdit.

    *Pass:* exactly **one** `x` appears, the hotkey still starts a session afterwards, and nothing
    crashes in the following minute of ordinary typing. A leaked second tap on a stale context
    presents as a doubled character or as a crash on the **next** keystroke — never on the
    re-creation itself, which is why "it re-created fine" is not this step.

40. **Quit while armed**, once mid-session and once armed but idle, then type in another app for ten
    seconds.

    *Pass:* no crash and **no missing characters** — type a known string and compare it, rather than
    judging that it "looked fine". This is `deinit { tearDown() }`; without it a live tap goes on
    calling a C function whose context is freed memory, system-wide.

41. **Provoke a disablement while a drag or a menu is tracking.** H10 covers the tap's own run-loop
    source (`CFRunLoopAddSource`); the deferred recovery is a *different* call
    (`CFRunLoopPerformBlock` + `CFRunLoopWakeUp`) with the same exposure and no test that can see it.

    *Gesture — and it is named, because step 38's method does not work here.* Step 38 provokes
    `kCGEventTapDisabledByTimeout` by attaching a debugger and breaking during a keystroke, which
    halts the process: nothing is then tracking, so the gesture this step asks for cannot be held.
    Use `kCGEventTapDisabledByUserInput` instead, which is reachable without stopping the process —
    **open a menu and hold it open, then toggle Accessibility for Vocca off and on in System
    Settings.** If you would rather keep the timeout route, post a `sleep(3)` onto the main thread
    from a debugger console *before* starting the drag, then start dragging within those three
    seconds. If neither is practical on the machine in front of you, record it as **not performed**,
    the way step 44 records its unavailable case. A step whose gesture is unperformable as written is
    a step that gets ticked.

    *Pass:* the tap recovers **before the gesture ends** — press the hotkey while still dragging or
    while the menu is still open, and confirm a session starts. Recovery only once the gesture ends
    is the failure.

42. **Release Option while still holding Space.** The one gesture that distinguishes an event mask
    with `flagsChanged` in it from one without, and nothing else in this document exercises what that
    bit buys.

    *Gesture:* hold `⌥Space`, speak, then lift **Option** only, keeping Space down.

    *Pass:* the widget leaves the recording state at that instant — **before** Space comes up. If it
    waits for Space, stop rule (b) is not firing. (This is a latency and extensibility failure, not a
    hot mic: rule (a) still ends the session at key-up.)

43. **`⌥Space` must eat nothing and type nothing — with the negative control, which is the half that
    makes it mean anything.**

    *Gesture:* in TextEdit (`Format ▸ Make Plain Text`), type a known sentence with Vocca armed;
    then press `⌥Space` armed; then quit Vocca and press `⌥Space` again. Select all, copy, and run
    `pbpaste | xxd | tail -3` in Terminal.

    *Pass:* the sentence is byte-identical to what you typed; the armed `⌥Space` contributes **no
    bytes at all**; and the unarmed one contributes exactly `c2 a0` — U+00A0 NO-BREAK SPACE. Without
    that last assertion a permanently-swallowing tap and a correctly-swallowing one look identical,
    and the permanently-swallowing one eats the user's whole keyboard.

44. **Hold the hotkey down with no hand on the keyboard.** `CGEventSourceKeyState` is asked with
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

45. **Disarm mid-session.** The manual counterpart to the Critical that phase 5's review found: the
    forward from the wrapper an owner holds to the policy's `disarm()` was, for one commit, held by no
    test at all.

    *Pass:* the microphone indicator goes out, **and** subsequent keystrokes reach the focused app —
    both halves, because a disarm that stops the clock without stopping the tap looks identical to a
    working one until you type.

46. **A note rather than a gesture: if the event mask ever gains a non-keyboard event type, H5 stops
    holding.** `CGEvent.h:274-280` — the keyboard bits are cleared at creation when there is no grant,
    and `tapCreate` returns `NULL` *only* if that leaves the mask empty. One mouse bit therefore yields
    a successful creation, a `.started` report, and a permanently deaf hotkey with **no honest error
    anywhere** — and it is the mask-cleared instance of "enabled and deaf", which the health poll
    cannot see. It changes what a green CI badge means, which is why it is written down here.

### The timers, which is where the last hot mic hides

47. **Stop a *toggle* session mid-drag** — the H10 hazard applied to the **tap's** run-loop source,
    which is the half step 48 does not cover.

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

48. **The ceiling, through a drag, in toggle mode** — the same hazard at its worst, because toggle has
    no physical-key poll behind it and the 120 s ceiling is all there is.

    *Gesture:* start a **toggle** session, then drag a window continuously for a little over two
    minutes.

    *Pass:* the session ends **while you are still dragging**, no later than ~122 s after it started.
    (120 s ceiling, one 150 ms watchdog tick, and a quarter-second of slack for the throttle in step
    49. Not "about two minutes": a session that ends when the drag ends has failed even if the drag
    lasted 121 s.)

    *This, and not step 47, is the **timer's** step.* Toggle has no physical-key poll and no key-up
    rule, so the ceiling is the only thing that can end this session and the watchdog's timer is the
    only thing that can deliver it — which is what isolates `RunLoop.main.add(timer, forMode: .common)`
    from the tap's own run-loop registration. Step 47 covers that registration; this covers the timer.
    The pair is deliberate, because a step that passes when either half works measures neither.

49. **App Nap on battery — and check the suppression state *before* believing the result.** This is
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

50. **App Nap with the display asleep.** Same gesture, same precondition check, same bound. Untried by
    anyone so far, and named as untried rather than assumed to be covered by step 49.

51. **A modifier released with no event reaching the tap.** *This step has no sharp pass criterion and
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

52. **Focus a password field and confirm Vocca reports itself blocked rather than broken.**

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

53. **Start a session, then take the keyboard away.** The hot mic behind Secure Input, and the reason
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

54. **Launch Vocca with Secure Input already held.** The arming path, which is a different branch from
    the poll and the one a user meets first if they leave *Secure Keyboard Entry* ticked.

    *Gesture:* tick it, then start Vocca.

    *Pass:* arming reports **`blockedBySecureInput`**, the log reads `armed` then `secureInputBegan`,
    and — the half that is easy to get wrong — **the tap was still created**: untick Secure Keyboard
    Entry and the hotkey must work **immediately, with no re-creation** (`startCount` unchanged, no
    `recreated` line). An implementation that declined to create a tap while blocked leaves Vocca deaf
    *after* the block passes, with nothing left to notice that it has.

### If notarizing

55. `Scripts/notarize.sh` has **never run end to end** — there is no Developer ID configured. The
    first real release must treat notarization as unproven and budget time for it, including for
    the possibility that a rejected entitlement or a missing hardened-runtime flag only shows up
    there.

56. It submits `.build/xcode-release/Build/Products/Release/Vocca.app` by default — the same bundle
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
