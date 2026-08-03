# C1 — Understanding note (Phase 2)

Written before any PRD work. Sources: `docs/ROADMAP.md`, `docs/technical/CAPABILITY_ROADMAP.md`,
`docs/technical/ARCHITECTURE.md`, `docs/product/PRODUCT_SPEC.md`, `CLAUDE.md`, `VISION.md`,
plus a macOS platform dig verified against the **macOS 26.5 SDK headers** on this machine.

Evidence labels below: **[SDK]** = quoted from a local Apple header and re-verified directly;
**[COMMON]** = corroborated field reports; **[UNVERIFIED]** = could not confirm, treated as risk.

---

## 1. What the work is really asking

Build the **front door**: hold `⌥Space`, audio is captured, release, capture ends — with a
widget that visibly tells the truth about the microphone, and a session lifecycle that
**cannot** leave the mic open when the user thinks it's closed.

There is no ASR, no injection, no cleanup, no TTS. The deliverable is a loop that starts and
stops correctly 100% of the time, and a project skeleton that can be signed and notarized.

**The real risk is not "does it record".** It's *stuck recording* — a capture session that
outlives its key-up. In a product whose pitch is "your audio never has to leave it"
(`CLAUDE.md:18`), a hot mic the user didn't ask for is the worst available failure, and it is
strictly a C1 failure because no later capability can detect or repair it.
`PRODUCT_SPEC.md:11` states the invariant in UI terms: *"There is no state where Vocca is
listening and doesn't look like it."*

C1 also carries `ROADMAP.md:80`'s week-1 "Skeleton + permissions" milestone (code-signed,
non-sandboxed, honest permission copy), which has no home anywhere in C1–C14. R9
(`ROADMAP.md:308`) says notarize from week 1 rather than discovering it at ship time.

---

## 2. Affected areas

Greenfield — **there is no code in this repository**. C1 creates:

| Area | What lands |
|---|---|
| Build setup | Xcode app target + local SPM packages (see §3.5), entitlements, Info.plist, signing |
| `VoccaCore` | Session state machine, `decide(event,state)` pure function, watchdog, custody-free for now |
| `VoccaAudio` | `AudioCaptureSource` seam, ring buffer, `AVAudioSinkNode` graph, `AVAudioConverter` |
| `VoccaHotkey` (new) | `HotkeyEventSource` seam, `CGEventTap` impl, optional Carbon fallback |
| `VoccaUI` | `NSPanel` widget (IDLE/RECORDING), menu-bar indicator, permission/onboarding screens |
| `Tests` | Table-driven decode tests, state-machine tests, ring-buffer TSan tests, converter tests |

`ARCHITECTURE.md:51-90`'s directory layout has no `VoccaHotkey`; the tap currently has no
named home. Proposing one.

---

## 3. Findings that change the design

These are corrections to authoritative docs, not preferences. Each is header-verified.

### 3.1 `installTap` cannot satisfy the architecture's own realtime rule — use `AVAudioSinkNode`

`ARCHITECTURE.md:253-257` mandates: *"AVAudioEngine tap. No allocation, no locks, no logging
… Writes into a lock-free ring buffer and nothing else."*

But **[SDK]** `AVAudioNode.h:86`: *"the requested size of the incoming buffers in sample
frames. **Supported range is [100, 400] ms.**"* and `AVAudioNode.h:30`: *"CAUTION: This
callback **may be invoked on a thread other than the main thread**"* — which is all Apple
documents. It is not the realtime IO thread, and it imposes a **100 ms floor**.

**[SDK]** `AVAudioSinkNode.h:64`: *"The block will be called **on the realtime thread**"*;
`:38` *"restricted to be used in the input chain and does not support format conversion"*.
Device-IO-sized buffers (~512 frames ≈ 10.7 ms at 48 kHz).

→ **`AVAudioSinkNode` is the correct primitive.** `installTap` would spend 100 ms of a
p50 ≤ 400 ms budget (`ROADMAP.md:171`) doing nothing. `ARCHITECTURE.md` §7 should be amended.

### 3.2 Warm-start and the orange mic dot are in direct conflict

**[SDK]** `AVAudioEngine.h:465-466`: *"if the engine has at any point previously had its
inputNode enabled and permission to record was granted, then **any time the engine is
running, the mic-in-use indicator will appear**."*

`ARCHITECTURE.md:236` wants the engine "already warm" for latency. Keeping it running would
light macOS's orange mic indicator **permanently** — the single most damaging possible signal
for a product whose promise is privacy, and a direct violation of `PRODUCT_SPEC.md:11`.

→ **Privacy wins; start on demand.** Keep engine/sink/converter/ring buffer allocated for the
app lifetime, `prepare()` after each stop, `start()`/`stop()` per press. Engine-start latency
must be **measured, not assumed**. `ROADMAP.md:98` says latency is recorded but not gated at
P0, so C1 can measure honestly and let C7 optimize.

### 3.3 The hotkey needs **Accessibility**, not Input Monitoring — the spec has this wrong

**[SDK]** `CGEvent.h:274-279`: taps *"may only receive key up and down events if access for
assistive devices is enabled … If the tap is not permitted to monitor these events when the
tap is created, then the appropriate bits in the mask are cleared. **If that results in an
empty mask, then NULL is returned.**"*

**[COMMON]** `.listenOnly` → Input Monitoring; `.defaultTap` (can swallow) → Accessibility,
which supersedes Input Monitoring.

We **must** use `.defaultTap`, because on US layouts `⌥Space` inserts U+00A0 NO-BREAK SPACE.
Not swallowing it means invisible corruption **in the exact field being dictated into**.

→ Therefore C1 requires **Accessibility**. But:
- `PRODUCT_SPEC.md:153` says *"Input Monitoring — so ⌥Space works everywhere"*
- `PRODUCT_SPEC.md:173` says *"Only Input Monitoring is genuinely fatal"*
- `ARCHITECTURE.md:435` assigns Input Monitoring to "Global hotkey tap", and `:434` assigns
  Accessibility to "AX injection + context", requested at "First dictation attempt"

All three are misassigned. **Accessibility is the fatal permission, and it is needed at C1,
not deferred to C4.** Silver lining: since C4 needs Accessibility anyway, the hotkey's
permission cost is **zero incremental** — but the onboarding copy and the permission matrix
must be rewritten.

Two consequences: `tapCreate` returning `nil` **is** the permission check; and after a grant
the tap must be **destroyed and re-created** (its mask was cleared at creation) —
`CGEventTapEnable` will not resurrect it.

### 3.4 Secure Input kills the hotkey, not just injection

**[SDK]** `IsSecureEventInputEnabled()` in `CarbonEventsCore.h`. When any app enables secure
input (password fields, 1Password, Terminal with Secure Keyboard Entry, lock screen), taps
receive **no key events at all**.

`ARCHITECTURE.md:311` treats Secure Input purely as injection rung 0. It also silently
disables capture — in exactly the contexts users will test first. C1 needs its own detection
and a distinct widget state, or the product looks broken.

### 3.5 SPM alone cannot produce a signable app

An SPM `.executable` builds a bare Mach-O, not a `.app`. TCC identity is bound to
**bundle identifier + code signature**; a bare executable has no `CFBundleIdentifier`, cannot
carry `NSMicrophoneUsageDescription`, and cannot durably hold Accessibility/Microphone grants.

`ARCHITECTURE.md:45` says "Modules are Swift Package Manager targets in one repository" —
true, but incomplete. → **Thin Xcode app target + local SPM packages.** `swift test` then runs
everything above the seams on a plain CI runner; Xcode owns bundle/plist/entitlements/notarize.

Also required: **`com.apple.security.device.audio-input`** is a *hardened-runtime* capability
that applies **outside** the sandbox. With hardened runtime on and this missing, the mic is
denied and **the prompt never appears** — silent failure. And there is **no** entitlement or
`NS*UsageDescription` key for Accessibility/Input Monitoring, so **onboarding UI is the only
explanation the user ever gets** for the two scariest permissions on macOS.

### 3.6 The stuck-recording bug has a known shape — and a known wrong fix

Releasing Option before Space produces a `flagsChanged`, not a `keyUp`. **[COMMON]**
[Handy #840](https://github.com/cjpais/Handy/issues/840) is this exact regression in a
shipping OSS dictation app: v0.1.4 read modifiers from each event's flags and was correct;
v0.2.0 accumulated state on `flagsChanged` and permanently desynced after one missed event.

→ **Derive modifier state from every event's flags; never accumulate.** Session must end on
*any* of: Space `keyUp`; `flagsChanged` losing `.maskAlternate`; any event whose flags lost
it; tap-disabled; 120 s ceiling; physical-key poll says released. Not a subset — all six.

**[SDK]** `CGEventSource.h:123-133` — `CGEventSourceKeyState` / `CGEventSourceFlagsState` with
`.combinedSessionState` read **current physical** key state independent of the tap. This is
the correct API for the "verify the key is still down" poll (`ARCHITECTURE.md:294`).

### 3.7 Tap health is not optional

**[SDK]** `CGEventTypes.h:127-131` — `kCGEventTapDisabledByTimeout` / `ByUserInput` are
delivered **out of band**. A tap-disable means the key-up will never arrive, so it must end
the session. **[COMMON]** taps also die silently across sleep/wake
([ghostty #11819](https://github.com/ghostty-org/ghostty/discussions/11819)) and across
re-signing, where the symptom is *non-nil tap, `tapIsEnabled` true, callback never fires*
([danielraffel](https://danielraffel.me/til/2026/02/19/cgevent-taps-and-code-signing-the-silent-disable-race/)).

→ Health poll + re-enable + re-create, from C1. Plus a **stable local dev signing identity**
(never ad-hoc), or TCC grants silently stop applying between debug builds.

---

## 4. Testability — this determines the whole structure

**Nothing that needs TCC can run in CI.** `CGEvent.tapCreate` returns `nil` without
Accessibility **[SDK]**; synthesized events need `PostEvent`; there is no microphone; and
**[SDK]** `AVAudioSinkNode.h:48` — the sink node is unsupported in **manual rendering mode**,
so the realtime path cannot be exercised offline at all.

C1's acceptance as written in `CAPABILITY_ROADMAP.md:42` ("100 synthetic key-down/key-up
pairs") therefore **cannot** be a test of the real tap. It must be a test of the decision
logic. Two narrow seams make that work:

```swift
protocol HotkeyEventSource: Sendable {      // real = CGEventTap; test = manual driver
    var events: AsyncStream<RawKeyEvent> { get }   // RawKeyEvent is POD — no CGEvent escapes
}
protocol AudioCaptureSource: Sendable {     // real = AVAudioEngine+SinkNode; test = synthetic
    func begin(into: AudioRingBuffer) throws
}
```

**Rule:** `CGEvent`, `CFMachPort`, `AVAudioEngine`, `AVAudioSinkNode` appear in exactly two
files, and neither contains a branch worth testing. Because the sink node can't run offline,
**`AudioCaptureSource` must sit above the node**, or that code is untested forever.

Headlessly testable, and it should be nearly all the logic: the `decide(_:state:)` pure
function (every §3.6 case, table-driven); the session machine with an injected clock; the
ring buffer under TSan; `AVAudioConverter` resampling against a synthetic sine.

---

## 5. Scope: C1-as-briefed vs C1-as-specified

`PRODUCT_SPEC.md` requires materially more widget/hotkey surface than
`CAPABILITY_ROADMAP.md:31-46` describes. Every item below is a genuine spec requirement that
the C1 text omits:

| Requirement | Source | In C1 text? |
|---|---|---|
| IDLE→RECORDING within **one frame (16 ms)** | `:71` | No |
| Waveform tracks **real input level** ("a fake waveform is a lie") | `:77-78` | No |
| Elapsed timer after 3s; **110s warning** before the 120s ceiling | `:79-80` | No |
| `Esc` cancels; `esc to cancel` hint after 2s | `:95` | No |
| Widget draggable, bottom-center default, 30% idle opacity, fades after 10s | `:22,27-28` | No |
| Menu-bar icon as a **second always-visible mic indicator** | `:257` | No |
| Recording-start tick, **default ON**, defeatable | `:74` | No |
| VoiceOver on every state incl. transition announcements; Reduce Motion → static meter | `:247,249` | No |
| Hotkey **rebindable to arbitrary keys**, conflict detection | `:181,251` | No |
| **Toggle alternative to hold-to-talk** | `:251` | **Contradicts** |

The platform dig independently argues for rebinding regardless of accessibility: **[COMMON]**
`⌥Space` is Alfred's default hotkey, and macOS 15.0/15.1 briefly blocked Carbon registration
of Option-only chords ([FB15168205](https://github.com/feedback-assistant/reports/issues/552)).

---

## 6. Contradictions requiring a decision

1. **Hold-to-talk only vs. toggle alternative.** `CAPABILITY_ROADMAP.md:36` says hold-to-talk
   **only**; `PRODUCT_SPEC.md:251` calls a toggle *"a real accessibility need, not a
   preference"*. `CLAUDE.md` gives `PRODUCT_SPEC.md` authority on user-visible behavior.
   Reading them together, "only" was excluding **VAD/endpointing**, not a toggle — but this
   needs deciding, not assuming.
2. **Permission assignment** — §3.3. Three documents are wrong against the SDK.
3. **Warm start vs. the orange dot** — §3.2.
4. **`installTap` vs `AVAudioSinkNode`** — §3.1.
5. **Onboarding cannot complete.** `PRODUCT_SPEC.md:166-168` defines completion as speaking
   into a live field and seeing text; steps 3–4 need the ASR model. The spec flags this
   itself at `:276`. C1 ships a deliberately truncated first-run.
6. **Target indicator `→ AppName`** (`PRODUCT_SPEC.md:63,73`) appears at t=0 in RECORDING.
   Reachable without AX via `NSWorkspace.frontmostApplication`, but `TargetContext` is C4's.
   Scope decision, not an impossibility.
7. **Tooling assumes Python.** The `vocca-worktrees` / `vocca-begin-fast` skills reference
   `pyproject.toml`, `uv sync`, `src/vocca/`, `uv run pytest`. `ARCHITECTURE.md:3` is
   authoritative and locks Swift 6 + SPM. **Resolved: Swift.** Skills should be updated.

---

## 7. Open questions for the interview

1. Does C1 ship the **toggle mode** and **rebinding**, or only fixed `⌥Space` + a fast follow?
2. Does C1 ship the **menu-bar indicator**, or is the floating widget alone sufficient?
3. Is the **Carbon `RegisterEventHotKey` fallback** worth it? It needs no TCC grant, so it
   gives a working hotkey during onboarding *before* Accessibility is granted — but it can't
   see `flagsChanged`, so it can't implement the release-Option-first stop rule.
4. Does the **target indicator** (`→ AppName`) land in C1 or wait for C4?
5. Should the **zero-network CI test** be stood up at C1? `CLAUDE.md:108-110` calls it a
   permanent release blocker for all configs; it's currently scheduled at C6. C1 is when the
   test suite is created and there is no network code at all — the cheapest possible moment.
   Related: `PRODUCT_SPEC.md:206` promises a real *"Vocca has made 0 network connections"*
   counter.
6. What is the **acceptance metric for engine-start latency**, given §3.2 forbids warm-start?
7. Do we amend `ARCHITECTURE.md` and `PRODUCT_SPEC.md` as part of this PR, or file follow-ups?
   §3.1–3.4 are corrections to documents marked authoritative; leaving them stale means the
   next capability inherits wrong guidance.

---

## 8. Guardrail check

Clean. C1 is macOS-native by construction, has no network path, adds no cloud, and does not
touch the local/hosted seam. Two tripwires to watch during implementation:

- `ROADMAP.md:74` forbids *"settings UI beyond permissions and one hotkey"* — hotkey
  rebinding is arguably within "one hotkey"; anything more is not.
- The watchdog must stay a **dumb timer**. If it starts making speech-boundary decisions it
  becomes VAD, which P0 explicitly defers to P3 (`ROADMAP.md:45`).
- Apache-2.0 headers belong on the first source files (`CLAUDE.md`, `ROADMAP.md:49`).
