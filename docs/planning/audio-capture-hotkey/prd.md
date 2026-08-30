# PRD — C1: Audio capture + global hotkey

| | |
|---|---|
| **Capability** | C1 (`docs/technical/CAPABILITY_ROADMAP.md:31`) |
| **Phase** | **P0** — core dictation loop, week 1 |
| **Pipeline layer** | **Capture** (first of capture → ASR → cleanup → injection → TTS → actions) |
| **Branch** | `feat/audio-capture-hotkey/aliz` |
| **Dependencies** | None. This is the first brick, and the first code in the repository. |
| **Status** | Awaiting review gate |

Evidence labels: **[SDK]** = quoted from a macOS 26.5 SDK header and re-verified directly on
this machine; **[COMMON]** = corroborated field reports; **[UNVERIFIED]** = flagged as risk.

---

## 1. Problem statement

Vocca has no code. Every capability in the backlog — ASR (C2), the injection ladder (C4),
cleanup (C5) — depends on audio existing and on a session having a beginning and an end.

But C1 is not merely "make recording work." Its real problem is narrower and harder:

> **A capture session must never outlive the user's intent to be recorded.**

macOS does not guarantee the key-up event that ends a hold-to-talk session. The hotkey can be
stolen, the tap can be disabled by the OS without warning, the machine can sleep, the user can
release the modifier before the key. Any of these leaves the microphone open while the widget
says nothing is happening.

For a product whose promise is *"It runs on your machine; your audio never has to leave it"*
(`CLAUDE.md:18`) and whose spec states *"There is no state where Vocca is listening and doesn't
look like it"* (`PRODUCT_SPEC.md:11`), a hot mic is not a bug — it is the end of the product's
reason to exist. And it is **exclusively** a C1 failure: no later capability can detect it,
repair it, or apologise for it.

**Evidence this is real, not theoretical.** [Handy #840](https://github.com/cjpais/Handy/issues/840)
is this exact defect shipping in a comparable OSS macOS dictation tool: v0.1.4 derived modifier
state from each event's flags and worked; v0.2.0 accumulated state on `flagsChanged` and
desynced permanently after a single missed event. Separately,
[ghostty #11819](https://github.com/ghostty-org/ghostty/discussions/11819) documents event taps
dying silently across sleep/wake.

### Secondary problem: the project does not exist

`ROADMAP.md:80` carries a week-1 "Skeleton + permissions" milestone (SwiftUI app, code-signed,
non-sandboxed, honest permission copy) that has **no home in C1–C14**. R9 (`ROADMAP.md:308`,
Med/Med) says sign and notarize from week 1 rather than discovering the friction at ship time.
C1 is where that lands or it never does.

---

## 2. Goals & success metrics

### Primary — session integrity

| Metric | Target | How measured |
|---|---|---|
| Session pairing | **100 started / 100 ended, 0 overlapping, 0 orphaned** across 100 synthetic hold cycles (80 ms – 60 s) | Table-driven test over the `HotkeyEventSource` seam |
| Watchdog closure | Session ends within its timeout when key-up is never delivered | Injected-clock test, each of the six stop paths |
| **Audio discard rate** | **0%** — every terminal transition hands the captured buffer downstream | Asserted on every path in the state machine suite |
| Stuck recording | **0** in a week of real use | `endReason` telemetry (local-only) |

`ROADMAP.md:97` — *"Session reliability: 0 stuck-recording or missed-hotkey events across a week
of real use"* — is the one P0 success metric C1 can move on its own. Injection success and
transcript-loss (`:95`, `:96`) need C4; latency (`:98`) is measured but P2 owns the number.

### Secondary

| Metric | Target | Source |
|---|---|---|
| Cold install → "ready" | **< 60 s** on a clean Mac | `ROADMAP.md:80` |
| IDLE → RECORDING | **≤ 16 ms** (one frame) from key-down | `PRODUCT_SPEC.md:71` |
| Widget focus theft | **0** — `NSApp.isActive` stays false, `frontmostApplication` unchanged | `PRODUCT_SPEC.md:22` |
| Buffer format | 16 kHz mono Float32 asserted against fixtures; a sample-rate or channel regression fails loudly | `CAPABILITY_ROADMAP.md:42` |
| Network connections | **0** on the default path | `CLAUDE.md:108-110` |
| Engine-start latency | **Measured and recorded, not gated** | `ROADMAP.md:98` |

**`endReason` is the headline health signal.** Making it an enum means "% of sessions ended by
watchdog rather than by key-up" is a number we can watch. A rising watchdog share is the early
warning that this subsystem is degrading, and it is the only instrument that would catch it.

---

## 3. Persona & scenario

The Vocca ICP: a Mac user who lives in dictation all day and will not send their audio to the
cloud. At C1 they cannot dictate yet — so the honest scenario is the **installer**:

> They install Vocca, are asked for two of the scariest permissions on macOS, grant them, hold
> `⌥Space`, and see a waveform that moves with their actual voice. Nothing is transcribed.
> The entire value delivered is *"the microphone does exactly what the widget says it does,
> and stops the instant I let go."*

That is the trust transaction the rest of the product is built on.

---

## 4. Requirements

### Must-have

**Project foundation**
- **M1** Thin **Xcode app target** wrapping **local SPM packages** in one repo. An SPM
  `.executable` alone produces a bare Mach-O, not a `.app`; TCC identity is bound to bundle ID
  + signature, so a bare executable cannot durably hold Accessibility or Microphone grants.
  Amends `ARCHITECTURE.md:45`.
- **M2** Signing and notarization wired from the first commit: Developer ID, hardened runtime,
  **not sandboxed**, `com.apple.security.device.audio-input`, `NSMicrophoneUsageDescription`,
  `LSUIElement`, stable `CFBundleIdentifier`, `notarytool` + `stapler`. *Mitigates R9.*
  **`com.apple.security.device.audio-input` is a hardened-runtime capability that applies
  outside the sandbox** — with hardened runtime on and this key missing, the mic is denied and
  **the prompt never appears**.
- **M3** A **stable local development signing identity** (never ad-hoc). **[COMMON]** re-signing
  creates a new code identity and TCC grants silently stop applying; the symptom is a non-nil
  tap, `tapIsEnabled` true, and a callback that never fires
  ([danielraffel](https://danielraffel.me/til/2026/02/19/cgevent-taps-and-code-signing-the-silent-disable-race/)).
- **M4** Apache-2.0 headers on all source (`CLAUDE.md`, `ROADMAP.md:49`).

**Hotkey**
- **M5** `HotkeyEventSource` seam yielding **POD `RawKeyEvent`** values. No `CGEvent` or
  `CFMachPort` escapes the implementation file. *(New seam — `ARCHITECTURE.md:51-90` has no
  home for the tap; proposing `VoccaHotkey`.)*
- **M6** `CGEvent` tap: `.cgSessionEventTap` / `.headInsertEventTap` / **`.defaultTap`**,
  masking `keyDown | keyUp | flagsChanged`. **[SDK]** `CGEvent.h:269-271` — HID-level taps are
  root-only, so `.cgSessionEventTap` is mandatory.
- **M7** **Swallow both the key-down and the matching key-up.** On US layouts `⌥Space` inserts
  U+00A0 NO-BREAK SPACE — not swallowing it corrupts, invisibly, the exact field the user is
  about to dictate into. Swallowing only the down leaves the target app an unpaired key-up.
- **M8** `decide(_ event: RawKeyEvent, state: SessionState) -> Decision` as a **pure function**.
  **Modifier state is derived from each event's flags and never accumulated** — this is the
  Handy #840 defect, and the pure function is where its tests live.
- **M9** Six stop rules, **all of them, not a subset**: (a) Space `keyUp`; (b) `flagsChanged`
  losing `.maskAlternate`; (c) any event whose flags no longer carry it; (d) tap disabled;
  (e) 120 s ceiling; (f) physical-key poll says released. Rule (b) is what covers
  "released Option before Space."
- **M10** **Rebindable hotkey** — `⌥Space` is Alfred's default and a common Raycast binding.
- **M11** **Toggle alternative to hold-to-talk.** `PRODUCT_SPEC.md:251`: *"a real accessibility
  need, not a preference."* Resolves the tension with `CAPABILITY_ROADMAP.md:36`'s
  "hold-to-talk only", which was excluding VAD/endpointing, not a toggle.

**Session lifecycle**
- **M12** Session state machine with an **injected clock**, owning `idle → recording →
  ending → idle`.
- **M13** **One** `endSession(reason:)` funnel. `reason` is an enum. **Every** path hands the
  buffered audio downstream — `discard` is not representable. Mirrors `ARCHITECTURE.md:294`
  ("an unexpectedly-ended session yields its transcript to custody rather than discarding it").
- **M14** Watchdog: 120 s ceiling **and** a 100–250 ms physical-state poll using **[SDK]**
  `CGEventSourceKeyState` / `CGEventSourceFlagsState` with `.combinedSessionState`
  (`CGEventSource.h:123-133`) — these read true physical key state independent of the tap.
  Poll is owned by the session actor, **never** by the tap callback.
- **M15** Additional session-end triggers: `NSWorkspace.willSleepNotification`,
  `screensDidSleepNotification`, `sessionDidResignActiveNotification`,
  `AVAudioEngineConfigurationChangeNotification`, and `IsSecureEventInputEnabled()` going true.

**Tap health**
- **M16** Handle **[SDK]** `kCGEventTapDisabledByTimeout` / `ByUserInput`
  (`CGEventTypes.h:127-131`, delivered **out of band**): re-enable, **and end any in-flight
  session** — that key-up is never coming.
- **M17** ~1 s health poll on `tapIsEnabled`; if re-enable fails, tear down and **re-create**.
- **M18** The tap callback does **nothing** but read type/keycode/flags/autorepeat, decide
  swallow-or-pass, and push a POD value. No I/O, no allocation, no `await`, no engine start.
  **Starting `AVAudioEngine` inside the callback would directly cause `tapDisabledByTimeout`.**

**Audio**
- **M19** `AudioCaptureSource` seam, sitting **above** the node. **[SDK]**
  `AVAudioSinkNode.h:48` — the sink node is unsupported in manual rendering mode, so a seam
  below it would be untestable forever.
- **M20** **`AVAudioSinkNode`, not `installTap`.** **[SDK]** `AVAudioNode.h:86` — installTap's
  *"Supported range is [100, 400] ms"*, and `:30` documents only *"may be invoked on a thread
  other than the main thread."* `AVAudioSinkNode.h:64` is the one that says *"called on the
  realtime thread."* A 100 ms floor is 25% of P2's 400 ms p50 budget, spent on nothing.
  **Amends `ARCHITECTURE.md:253-257`.**
- **M21** SPSC lock-free ring buffer, preallocated, `Synchronization.Atomic`, acquire/release.
  **This is the only type in the codebase that gets `@unchecked Sendable`**, with a comment
  stating the invariant the compiler cannot verify.
- **M22** `AVAudioConverter` → 16 kHz mono Float32, running **on the consumer side, off the
  realtime thread** (it allocates). Hardware will be 44.1/48 kHz — or 16 kHz on Bluetooth HFP.
  Never pass a non-hardware format to the input node.
- **M23** **Engine starts on demand; it is not kept warm.** **[SDK]** `AVAudioEngine.h:465-466`:
  *"if the engine has at any point previously had its inputNode enabled and permission to record
  was granted, then any time the engine is running, the mic-in-use indicator will appear."*
  A permanently-lit orange mic dot is the most damaging possible signal for this product.
  **Privacy wins over warm-start. Amends `ARCHITECTURE.md:236`.** Mitigate with `prepare()`
  after every stop and by keeping engine/sink/converter/buffer allocated for the app lifetime —
  only `start()`/`stop()` per press, never a graph rebuild.

**Permissions**
- **M24** **Accessibility is the required, fatal permission — not Input Monitoring.**
  **[SDK]** `CGEvent.h:274-279`: taps *"may only receive key up and down events if access for
  assistive devices is enabled … If the tap is not permitted to monitor these events when the
  tap is created, then the appropriate bits in the mask are cleared. If that results in an empty
  mask, then NULL is returned."* **[COMMON]** `.defaultTap` → Accessibility; `.listenOnly` →
  Input Monitoring; Accessibility supersedes. We need `.defaultTap` to swallow (M7).
  **Corrects `PRODUCT_SPEC.md:153`, `:173` and `ARCHITECTURE.md:435`.** Incremental cost is
  zero — C4 needs Accessibility anyway.
- **M25** `tapCreate` returning `nil` **is** the permission check. After a grant the tap must be
  **destroyed and re-created** — its mask was cleared at creation and `CGEventTapEnable` will
  not resurrect it. Observe `com.apple.accessibility.api` via `DistributedNotificationCenter`,
  and ship a **"Restart Vocca"** button.
- **M26** Microphone permission requested **explicitly in onboarding** via
  `AVCaptureDevice.requestAccess(for: .audio)`, so the prompt lands at a moment we control
  rather than mid-hotkey.
- **M27** There is **no** entitlement and **no** `NS*UsageDescription` key for Accessibility or
  Input Monitoring. The system dialogs have fixed text. **Our onboarding UI is the only
  explanation the user will ever get** for the two scariest permissions on macOS.

**Widget & onboarding**
- **M28** `NSPanel` with **`.nonactivatingPanel`**, `canBecomeKey` and `canBecomeMain` both
  false, level `.floating`, collection behavior `[.canJoinAllSpaces, .fullScreenAuxiliary,
  .stationary]`, `hidesOnDeactivate = false`; app is `.accessory` / `LSUIElement`.
  **`.nonactivatingPanel` is load-bearing**: `canBecomeKey = false` alone stops keyboard focus
  but a click still *activates the app* and yanks focus from the app being dictated into.
  `.fullScreenAuxiliary` is why the widget survives another app's full-screen space.
- **M29** States **IDLE** and **RECORDING** only. `PRODUCT_SPEC.md:71` — expand within one frame
  (16 ms).
- **M30** Waveform driven by **real input level**. `PRODUCT_SPEC.md:77-78`: *"A fake waveform is
  a lie about whether the mic works."*
- **M31** Elapsed timer after 3 s; **110 s warning** before the 120 s ceiling
  (`PRODUCT_SPEC.md:79-80`) — the UI counterpart of M14.
- **M32** `Esc` cancels and discards during RECORDING; `esc to cancel` hint after 2 s
  (`PRODUCT_SPEC.md:95`). *This is the one place discarding audio is correct — the user asked.*
- **M33** **Secure Input detection** with its own widget state. **[SDK]**
  `IsSecureEventInputEnabled()` (`CarbonEventsCore.h:3044`) — when any app enables secure input
  (password fields, 1Password, Terminal with Secure Keyboard Entry), taps receive **no key
  events at all**. The hotkey dies silently in exactly the contexts users test first.
  `ARCHITECTURE.md:311` treats this as injection-only; it is also a capture concern.
- **M34** **Truncated onboarding**: welcome → permissions (live ✓/✗, direct buttons to the exact
  settings pane, restart button) → done. **No model step, no try-it step.** `PRODUCT_SPEC.md:
  166-168` defines completion as speaking and seeing text, which needs C2; the spec flags this
  gap itself at `:276`. C1's honest completion criterion is *"the waveform moves when I speak."*

**Testing & docs**
- **M35** Headless suite: table-driven `decide` tests covering every case in M9; state-machine
  tests with injected clock (ceiling, poll-released, double-start, stop-without-start,
  stop-twice); ring buffer under TSan; `AVAudioConverter` against a synthetic sine.
  **`CGEvent`, `CFMachPort`, `AVAudioEngine`, `AVAudioSinkNode` appear in exactly two files,
  and neither contains a branch worth testing.**
- **M36** **Zero-network CI test** (network interposer) stood up now, per the review decision.
  `CLAUDE.md:108-110` calls it a permanent release blocker for all configurations; C1 is when
  the suite is created and there is nothing to fix.
- **M37** **Amend `ARCHITECTURE.md` and `PRODUCT_SPEC.md`** in this PR for M20, M23, M24 and M1,
  with SDK citations inline. Both are marked authoritative; leaving them stale means C2 and C4
  inherit wrong guidance, and the permission error would ship in user-facing copy.

### Should-have

- **S1** **Carbon `RegisterEventHotKey` fallback** behind `HotkeyEventSource`. **[SDK]**
  `CarbonEvents.h:4697-4715` — `kEventHotKeyReleased` exists, so Carbon *can* do hold-to-talk.
  It needs **no TCC grant**, giving a working hotkey during onboarding *before* Accessibility is
  granted, and a degradation path if the tap is persistently killed. Cannot be primary: no
  `flagsChanged` visibility, so it cannot implement stop rules (b)/(c).
  **[UNVERIFIED]** its reliability when the modifier is released first.
- **S2** Menu-bar mic indicator (`PRODUCT_SPEC.md:257`) — a second always-visible "we are
  listening" signal, on-brand for a privacy tool because it shows even when the widget doesn't.
- **S3** Local-only `endReason` distribution readout.
- **S4** Recording-start tick, default ON, defeatable (`PRODUCT_SPEC.md:74`).
- **S5** Short engine linger (~1.5 s) to coalesce rapid re-presses, bounding the orange dot to
  real use while cutting repeat start cost.

### Nice-to-have

- **N1** Hotkey conflict detection against system shortcuts (`PRODUCT_SPEC.md:181`).
- **N2** Widget dragging, bottom-center default, 30% idle opacity, fade after 10 s.
- **N3** VoiceOver labelling with transition announcements; Reduce Motion → static level meter.
- **N4** Tap latency health readout from **[SDK]** `CGGetEventTapList`'s
  `min/avg/maxUsecLatency` (`CGEventTypes.h:464-473`) — real self-monitoring for the callback
  budget, which is otherwise **[UNVERIFIED]**.

---

## 5. Technical considerations

**Phase:** P0, week 1. **Layer:** capture. **Prerequisites:** none.

**Local-first:** C1 has no network path at all. M36 makes that permanent rather than incidental.

**Latency:** not gated at P0 (`ROADMAP.md:98`), but two C1 decisions set P2's ceiling — M20
removes a 100 ms floor, and M23 trades warm-start for the privacy of a dark mic indicator. The
engine-start cost M23 introduces must be **measured in C1** so C7 optimizes against data.

**Pluggability:** two new seams, `HotkeyEventSource` and `AudioCaptureSource`. Per
`CAPABILITY_ROADMAP.md:325` a seam needs two real implementations — S1 provides the hotkey's
second. `AudioCapture`'s second is `StreamingCapture` at C10 (`ARCHITECTURE.md:178`), so at C1
its only non-test implementation is the push-to-talk one. **Stated plainly rather than claimed
as proven.**

**Concurrency (Swift 6 strict, on from commit one per `ARCHITECTURE.md:43`):** the tap callback
is a non-capturing `@convention(c)` closure reading a `TapContext` via
`Unmanaged.passUnretained` — the context must be strongly held for the tap's lifetime or it's a
use-after-free. Recommended bridge: a **dedicated thread with its own runloop**, yielding into
an `AsyncStream` consumed by the session actor (`.bufferingNewest`). `MainActor.assumeIsolated`
also works and is sanctioned, but couples the callback's deadline to SwiftUI's main-thread
contention — the exact thing that triggers `tapDisabledByTimeout`. **[SDK]** `CGEvent.h:290-292`
confirms the callback thread is whichever runloop you register on.

Realtime-thread prohibitions (M21): no class instantiation, no Array/Dictionary/String
creation, no `AVAudioPCMBuffer` creation, no escaping-closure boxing, no `Task`/`await`/actor
hop, no `AsyncStream.yield` (allocates), no `DispatchQueue.async`, no locks, no `os_log` with
dynamic args, no existential boxing. Consumer wakes by **polling** the ring at ~10 ms — free
against a 100 ms-scale pipeline and avoids the argument entirely.

**Distribution constraint worth recording:** **[COMMON]** event-tap apps are routinely rejected
from the Mac App Store. Developer ID + Apache-2.0 makes this a non-issue for us, but **MAS is
effectively closed to this architecture** — a permanent strategic fact, not a C1 problem.
Notarization itself is automated malware scanning with no known review gate for this permission
combination; Karabiner, Alfred, Rectangle and Hammerspoon all ship notarized with exactly this
profile.

---

## 6. Risks & open questions

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| **R9** (roadmap) | Notarization friction from non-sandboxed + Accessibility | Med | M2 — sign and notarize from commit one |
| **C1-A** | Stuck recording from a missed key-up | **Fatal (trust)** | M8 + M9 + M14 + M15 + M16 — all five, not a subset. `endReason` as the standing instrument |
| **C1-B** | Silent tap death after sleep/wake or re-signing; symptom is a healthy-looking tap whose callback never fires | High | M17 health poll + re-create; M3 stable dev identity |
| **C1-C** | Secure Input kills the hotkey with no error | Med | M33 detection + distinct state |
| **C1-D** | Engine start-on-demand is too slow, and warm-start is closed off by the orange dot | Med | M23 `prepare()` + persistent graph; S5 linger; **measure before optimizing** |
| **C1-E** | `⌥Space` collides with Alfred/Raycast | Med | M10 rebinding — **shipped 2026-08-30** (`docs/planning/hotkey-rebinding/`). The row was true on paper from C1 until then: M10 was a must-have that reached no aspect spec. Note the limit, because the mitigation is narrower than the risk: rebinding lets the user *move off* a collision, and nothing can *detect* this one — macOS exposes no way to enumerate hotkeys another process registered, so Alfred and Raycast, the two apps this row names, are structurally invisible. The shipped conflict check sees only macOS's own shortcuts, and only those the user has changed themselves. |
| **C1-F** | The realtime path cannot be exercised offline (**[SDK]** sink node ≠ manual rendering) | Med | M19 — seam above the node; accept a small manual smoke checklist |
| **C1-G** | The tap callback's OS deadline is **[UNVERIFIED]** | Med | M18 — do nothing in the callback; N4 for real latency data |
| **C1-H** | **[UNVERIFIED]** Carbon `kEventHotKeyReleased` reliability on modifier-first release | Low | S1 is a fallback only, never primary |

**Open questions**
1. What is the acceptance number for engine-start latency? Deliberately unset — M23 makes it
   measurable, and `ROADMAP.md:98` says P0 records rather than gates. Propose setting it from
   C1's own data before C7 rather than guessing now.
2. Ring buffer capacity: the 120 s ceiling at 48 kHz Float32 mono is ~23 MB preallocated.
   Acceptable, or should the ceiling be configurable downward by default?
3. Does the truncated onboarding's completion criterion ("the waveform moves") need a written
   copy pass, or is that a C2 concern once the try-it step becomes real?

---

## 7. Out of scope

**Later capabilities:** ASR (C2/C3), injection (C4), cleanup (C5/C6), streaming and speculative
ASR (C7), per-app strategy memory (C8), TTS (C9), VAD/endpointing and barge-in (C10), dual mode
(C11), context (C12), actions (C13).

**Widget states** TRANSCRIBING, DELIVERED, FAILSAFE (all need C2/C4) and CONVERSING (P3).

**Target indicator `→ AppName`** (`PRODUCT_SPEC.md:63,73`) — deferred to C4. Reachable now via
`NSWorkspace.frontmostApplication` without any permission, but naming a destination when
nothing will be typed there contradicts `PRODUCT_SPEC.md:11`.

**Onboarding steps 3–4** (model download, try-it) — need C2.

**Settings beyond permissions and the hotkey** — `ROADMAP.md:74` forbids it explicitly.

**VAD.** The watchdog is a dumb timer. The moment it makes a speech-boundary decision it becomes
VAD, which `ROADMAP.md:45` defers to P3.

**Transcript custody / recovery journal** (`ARCHITECTURE.md:350`) — there is no transcript at
C1. M13's "always hand the buffer downstream" is the seam custody will attach to at C2.

---

## 8. Self-critique — areas to strengthen before building

Run against this document per `prd-generator` Workflow 1. Recorded rather than resolved, because
resolving them is a scope decision.

| Dimension | Score |
|---|---|
| Problem definition | 🟢 |
| User understanding | 🟡 — the only "user" at C1 is the founder; ICP validation is structurally impossible until C2 |
| Success metrics | 🟡 — two headline metrics have no instrument |
| Scope clarity | 🟢 |
| Edge cases & risks | 🟢 |
| Stakeholder alignment | 🟡 — no named reviewer for the amendments to authoritative docs |
| Feasibility signal | 🔴 — no effort estimate, and 37 must-haves |
| Scope & layer fit | 🟢 |

**🔴 G1 — 37 must-haves is not one week.** `ROADMAP.md:78-87` budgets week 1 as two milestone
rows. This scope is plausibly 2–4 weeks solo. This is **R10** (`ROADMAP.md:309`, solo-founder
bandwidth, High/Med) materialising. The failure mode is specific and predictable: widget and
onboarding get built, and the session state machine — the only component that can lose the
user's words — gets rushed at the end. **Requires a decision: cut the must/should line, or
re-baseline the window explicitly.** Not a silent overrun.

**🟡 G2 — two metrics have no instrument.**
- *"0 stuck-recording across a week of real use"* is a field observation. The thing that would
  actually measure it is `endReason` telemetry, which is **S3 (should-have)**. If this metric is
  real, S3 is a must.
- *"IDLE → RECORDING ≤ 16 ms"* (`PRODUCT_SPEC.md:71`) has no stated measurement method.
  SwiftUI render timing is not trivially assertable. Either define the instrument or restate it
  as a design constraint rather than a metric.

**🟡 G3 — M37 has no acceptance criteria and no reviewer.** It amends `ARCHITECTURE.md`, which
governs C2–C14. That is more downstream blast radius than any code in this PR. Define what makes
an amendment correct, and who signs it off.

**🟡 G4 — open question 2 is load-bearing.** Ring buffer capacity (~23 MB at 120 s / 48 kHz
Float32 mono) sits inside must-have M21. It needs a decided number before implementation, not
after.

**🟡 G5 — the seam deviation is buried.** `CAPABILITY_ROADMAP.md:325` requires two real
implementations per seam. At C1, `AudioCaptureSource` has exactly one non-test implementation
(its second, `StreamingCapture`, arrives at C10). `HotkeyEventSource` gets its second only if S1
ships. This is an accepted, time-bounded deviation — it should be stated as such where the seams
are introduced, not left for a reader to notice.

### The question to answer before greenlighting

**M23 chose privacy over warm-start — but the cost is unmeasured, and P2's gate is p50 ≤ 400 ms
(`ROADMAP.md:171`).** If start-on-demand turns out to cost 300 ms, which one gives: the privacy
decision that keeps the orange mic indicator dark, or the latency gate the whole P2 phase is
judged on? Deciding that *now*, in the abstract, is far cheaper than deciding it later with a
working build and a deadline.
