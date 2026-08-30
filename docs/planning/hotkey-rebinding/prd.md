# PRD: Hotkey rebinding

**Date:** 2026-08-30 · **Phase:** P0 (capability C1, delivering the unshipped must-have **M10**)
**Branch:** `feat/hotkey-rebinding/aliz` · **Slug:** `hotkey-rebinding`
**Inputs:** `docs/planning/_card/issue.md`, `docs/planning/_card/understanding.md`

---

## 1. Problem statement

**`⌥Space` is not Vocca's to take.** It is Alfred's default hotkey and a common Raycast binding,
and Vocca hardcodes it with no way to change it — `AppBootstrap.shippedHotkeyKeyCode: UInt16 = 49`
(`AppBootstrap.swift:573`), compiled in, with no persisted counterpart anywhere in the repo.

This is not newly noticed. It was written down at C1 and then not built:

- `docs/planning/audio-capture-hotkey/prd.md:137` — **M10 "Rebindable hotkey"**, in the
  **Must-have** section, with this exact reasoning.
- `docs/planning/audio-capture-hotkey/prd.md:321` — risk **C1-E** records its mitigation as
  *"M10 rebinding"*.
- M10 was dropped at aspect decomposition with a stated reason —
  `audio-capture-hotkey/hotkey-source/spec.md:88`: *"Hotkey rebinding UI. The configuration is
  already a value; a settings surface is later."* The value was built; the surface never came.

**So the C1 risk register currently asserts a mitigation that does not exist.** That is the real
problem: not a missing feature, a false row. `CLAUDE.md` has repeated "the hotkey is still not
rebindable" through three consecutive units.

**Who has the problem.** Not the founder — ⌥Space works on the authoring machine, and dictation
has been driven with it. The people who have it are **external testers**, and they are on the
critical path: `ROADMAP.md`'s P2 gate requires **≥5 external users** confirming dictation parity,
and it is the first gate that cannot be passed by the founder alone. A tester running Alfred or
Raycast meets a hotkey that does nothing, on an `LSUIElement` app where a broken launch and a
working one look identical. That is a first-run failure with no visible cause.

**Evidence it is real, and its limits.** C1-E is rated **Med** likelihood by the C1 PRD, on the
strength of Alfred's documented default. Nobody has surveyed how many testers actually collide,
and this PRD does not claim a number.

## 2. Goals & success metrics

| Goal | Measure | Gate? |
|---|---|---|
| The C1-E row becomes true | `⌥Space` is changeable from Settings → General, and the new chord starts a dictation | Yes — the unit's definition of done |
| A rebind can never strand a session | No rebind path exists that mutates a machine's binding while it is non-`.idle`; pinned by test over the closed set of session states | Yes — C1-A is **Fatal (trust)** |
| A rebind can never brick the keyboard | The recorder refuses every binding that would swallow a text-entry key; pinned by a closed-set test over the refusal table | Yes |
| Detection claims exactly what it can do | Copy states that Vocca cannot see other apps' shortcuts; pinned byte-for-byte | Yes |
| The surface tells the truth after a change | Settings, the menu bar and onboarding never display a stale chord | Yes |

**Explicitly not a goal:** detecting a collision with Raycast, Alfred or any third-party app. That
is structurally impossible (§5.3) and this unit must not imply otherwise.

**These are gates, not measurements, and the difference matters.** Every row above is a binary
"does it work" — none of them measures whether the unit helped anyone. The stated benefit is that
external testers stop meeting a dead hotkey, and **Vocca will never be able to verify that**:
there is no usage analytics by design (`PRODUCT_SPEC.md:337`, "metrics are local and
inspectable"), so no tester's rescue is ever observable to us. This is a deliberate,
permanent consequence of the privacy stance, not an oversight to be fixed later.

The one proxy that does exist: during `ROADMAP.md`'s P2 gate run (≥5 external users), whether any
tester reports a hotkey collision, and whether they resolved it themselves without help. That is
an anecdote, not a metric, and is recorded as such.

## 3. Persona & scenario

**Sam**, a Mac user who installs Vocca from the README because it is the local, private one. Sam
also runs Raycast on ⌥Space.

Today: Sam grants Accessibility and Microphone, presses ⌥Space, and Raycast opens. Nothing about
Vocca is visibly broken — no window, no error, no Dock icon — so Sam concludes the app does not
work and deletes it. Vocca never learns this happened.

After: Sam opens Settings → General, clicks the shortcut, presses ⌃⌥D, and it takes effect on the
next press. If Sam had instead chosen ⌘Space, Vocca says Spotlight uses it. If Sam chooses ⌥Space
again, Vocca says nothing — because it genuinely cannot see Raycast, and inventing a warning it
cannot substantiate is worse than silence.

## 4. Requirements

### Must-have

- **M1 — The binding is persisted.** `keyCode` and `modifiers` join `SettingsStore` alongside the
  existing `activationMode()`. Reads are synchronous and total; writes are best-effort and never
  throw (the seam's stated contract, `SettingsStore.swift:25-35`). Decode goes through
  `PersistedSettings`' three-answer contract: **absent → ⌥Space, silent**; **malformed → ⌥Space
  plus exactly one loud report**; **known → the value, silent**.
- **M2 — The store keeps its one file.** The new keys live in `UserDefaultsSettingsStore.swift`,
  the single file permitted to name `UserDefaults` for the `settings` seam
  (`InjectionSeamBoundaryTests.swift:1453-1481`). A second file fails the lint outright.
- **M3 — The composition root reads the binding at launch**, replacing both hardcoded
  `HotkeyConfiguration(...)` call sites (`AppBootstrap.swift:399-400,437-438`). Both activation
  modes continue to share one chord.
- **M4 — A rebind rebuilds the wirings on an idle boundary.** *(Decision, §5.1.)* On a new
  binding: refuse if it equals the current one; **refuse if either machine is non-`.idle`**;
  persist; rebuild both `Wiring`s with the new configuration; re-point `ModeRoutingSink.active` at
  the wiring for the current mode. `HotkeyConfiguration` and `SessionMachine.configuration` stay
  immutable — no value is ever mutated under a running session, so `SessionRules.decide` and
  `SessionWatchdog.theBindingIsStillHeld` cannot disagree about what is bound.
- **M4a — The rebuild is atomic, and its failure is loud.** A rebuild that throws or half-completes
  must leave the **previous** wirings built and routed, and must surface the failure — never a
  graph with no routed sink. This is stated as its own requirement because the failure it prevents
  is Vocca's worst-behaved class: an `LSUIElement` app whose hotkey has silently died looks
  exactly like one that is working (`CLAUDE.md`, the `fix/local-dev-launch` findings — three
  defects, "a failed launch and a successful one look exactly the same"). The post-condition is a
  test: after any rebind attempt, successful or not, exactly one wiring is routed and both
  machines are reachable.
- **M5 — The refusal is visible.** A rebind attempted during a dictation surfaces in the tab, not
  only in the log — the Speech tab's model-removal shape (`SpeechTabState.swift:297` → `.refused`),
  not activation mode's silent no-op. Activation mode can be silent because the user gets their
  change on the next press; a rebind that appears not to have registered invites a second attempt.
- **M6 — A binding-validity decision table, in Core, pure.** Given a candidate chord, answer
  `accepted` / `refused(reason)` / `warned(reason)`. Refusals, as a closed set:
  - **modifier-only** — `HotkeyConfiguration` pairs a `keyCode` with a `ModifierSet`; "modifiers
    alone" has no representation.
  - **Escape** — Vocca's own cancel key (`SessionKeyPolicy.swift:56`) and the recorder's abort.
  - **an unmodified text-entry key** — letters, digits, punctuation, Space, Return, Tab, Delete.
    See M7 for what remains allowed.
- **M7 — Single-key bindings, from a safe set.** *(Decision, §5.2.)* `PRODUCT_SPEC.md:322` requires
  bindings *"including to single keys or non-modifier combinations, for users who can't hold
  chords"*. Unmodified bindings are therefore **permitted** from a named set that cannot swallow
  text entry: **F1–F20, Home, End, Page Up, Page Down, Forward Delete, Help, and the keypad keys**.
  This is the set such users actually bind. It is a narrower reading than the spec's words, and
  §7-R3 records the tension rather than hiding it.
- **M8 — Conflict detection against Apple's own shortcuts.** Read `com.apple.symbolichotkeys` for
  Apple's remappable shortcuts and **warn** (never refuse) on a hit, naming the shortcut. Behind a
  seam, with a pure decision above it; the reader is the adapter.
- **M9 — Copy that states its own limit.** The tab says plainly that Vocca cannot see shortcuts
  owned by other applications. `SettingsCopy.hotkeyNotRebindable` is **deleted** — it becomes
  false — and the General tab's copy gains a byte-for-byte pin test, which `SettingsCopy` has
  never had (§7-R5).
- **M10 — The displayed chord is live.** `SettingsBindings.hotkeyDisplayName` becomes a closure.
  It is today a plain `String` captured once (`SettingsView.swift:24-152`) while the window is
  built once and kept for the process lifetime (`AppBootstrap.swift:1031-1035`), so after a rebind
  it would show the old chord until relaunch. The menu bar's `hotkey:` and onboarding's
  "Hold ⌥Space" copy have the same defect and are fixed with it.
- **M11 — A chord renders as a person reads it.** One pure formatter, `⌃⌥⇧⌘` in the platform's
  canonical order plus a key name, used by every surface — no second dialect.
- **M12 — `PRODUCT_SPEC.md:252` is amended.** It promises "conflict detection against system
  shortcuts" without qualification, which is not deliverable (§5.3). The spec line changes in this
  unit rather than being quietly under-delivered.

### Should-have

- **S1 — The recorder surface.** A click-to-record control in Settings → General: press a chord,
  see it, Escape aborts, Return commits. Executed by nothing in CI (window-server precedent), so
  its decisions live in the M6 reducer and the view is thin glue.
- **S2 — The C1-E row is updated** in `audio-capture-hotkey/prd.md` to record M10 as shipped, and
  to say that the detection half cannot cover the apps the risk names.
- **S3 — Smoke steps** appended after step 110: a real rebind, the safe-single-key path, an
  Apple-shortcut warning, a mid-session refusal, and a rebind surviving relaunch.

### Nice-to-have

- **N1 — An empirical arm-and-observe probe** for third-party steals. Deferred: it rests on an
  **unmeasured** assumption about whether another process's `RegisterEventHotKey` starves our tap
  (§7-R4). Not built on an assumption.
- **N2 — A per-app seeded conflicts table** (Raycast/Alfred preference keys). Deferred: it is a
  hand-maintained lookup that goes stale silently.
- **N3 — A second chord for Converse mode** (`PRODUCT_SPEC.md:192`, `⌥⇧Space`). P3; the stored
  shape must not foreclose it.

## 5. Technical considerations

**Phase:** P0. **Layer:** capture only — no ASR, cleanup, injection or TTS code is touched.
**Latency:** not on the dictation path. A rebind happens in a settings window; the per-event cost
of `SessionRules.decide` is unchanged, since it already compares against a configuration value.
**Privacy / local-first:** unchanged and untouched — no network, no new file outside the existing
`UserDefaults` domain. **Pluggability:** unaffected; no seam gains or loses an implementation.

**The tap needs no changes at all.** `VoccaHotkey` is entirely binding-agnostic: the tap's
`eventsOfInterest` mask is built from event *kinds*, never key codes
(`CGEventTapSource.swift:188`, `TapEventClassification.swift`), so it forwards the whole keyboard
unconditionally and per-key matching happens above the seam in `SessionRules.decide`
(`SessionRules.swift:157`). `TapEventDispatch.swift:44-46` says so in its own comment.

### 5.1 Why rebuild rather than mutate *(decided)*

The binding is consumed in two places: `SessionRules.decide` and
`SessionWatchdog.theBindingIsStillHeld` (`SessionWatchdog.swift:444-449`, which re-reads
`machine.configuration` on every ~150 ms poll). Making the configuration mutable is the smaller
change and the watchdog would track it for free — but it opens a window where a rebind lands
between a `keyDown` and its `keyUp`, and the poll and the rules then disagree about what is held.
That is **C1-A, "stuck recording", Fatal (trust)**. Rebuilding both `Wiring`s behind the existing
"both machines `.idle`" guard (`AppBootstrap.swift:1564-1581`) keeps every value immutable and
makes the failure unrepresentable rather than merely unlikely.

### 5.2 Why a safe single-key set *(decided)*

The tap is active, not listen-only, and must be — `ARCHITECTURE.md` §13: a passive tap cannot
swallow the chord, so macOS would insert U+00A0 into the field being dictated into. Consequently a
bound key is **swallowed system-wide**. A bare letter therefore makes that letter untypeable, and
the way back is the Settings window, which needs the keyboard. The spec's accessibility
requirement is real and is served by F-keys and navigation keys, which is what users who cannot
hold chords actually bind; text-entry keys serve no accessibility purpose and carry a bricking
path. We satisfy the need and refuse the trap.

### 5.3 What conflict detection can honestly be *(decided)*

Established, not opinion:

- `com.apple.symbolichotkeys` covers **only Apple's own remappable shortcuts** (Spotlight, Mission
  Control, screenshots, input-source switching). Undocumented, but plainly readable — no
  entitlement needed.
- There is **no API to enumerate hotkeys registered by other processes**, whether via Carbon
  `RegisterEventHotKey` or their own `CGEventTap`. Closed by design.
- **Therefore Raycast and Alfred — the two apps C1-E names — are structurally invisible.** The
  mitigation cannot detect the risk it was written for. It can only let the user move off it.

We ship what is detectable, warn rather than refuse (the user's own Spotlight may be remapped or
disabled), and say the rest in words.

### 5.4 Conventions this unit is bound by

Core owns the pure reducers; `VoccaUI` may import only `VoccaCore` (`ModuleBoundaryTests`). The
`symbolichotkeys` reader is a new adapter and needs a seam row if it names a new API family. Test
floor is **1501** (`Scripts/test-with-floor.sh`), bumped in the same commit that adds tests. Any
tunable constant needs a single-source scan test. New `deinit`s may call only
`tearDown`/`stopWithoutAssertingIsolation`/`deallocate` (`DeinitIsolationTests`). Apache-2.0
header verbatim; smoke steps append after 110.

## 6. Data model

Two new `settings`-seam keys, beside `settings.activationMode`:

| Key | Type | Default | Decode failure |
|---|---|---|---|
| `settings.hotkey.keyCode` | `UInt16` as string | `49` (Space) | ⌥Space + one loud report |
| `settings.hotkey.modifiers` | `ModifierSet` raw bits as string | `[.option]` | ⌥Space + one loud report |

Stored as two keys rather than one encoded chord so a half-written pair degrades to the default
rather than to a chord nobody chose. `.capsLock` is masked out before storage — it is already
masked out of every comparison (`ModifierSet.locking`), so persisting it would store a bit that
can never match.

## 7. Risks & open questions

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| **R1** | A rebind strands an in-flight session (**C1-A**, roadmap) | Low | **Fatal (trust)** | M4 — rebuild on an idle boundary; immutability preserved; pinned over the closed set of session states |
| **R2** | A binding makes the keyboard unusable | Low | High | M6/M7 — closed refusal table, tested as a closed set |
| **R3** | M7 is a **narrower reading than `PRODUCT_SPEC.md:322`'s words.** The spec says "fully rebindable, including to single keys"; we permit single keys only from a safe set | — | Med | Recorded here, not hidden. If a real user needs a refused key, the set is one named table to widen |
| **R4** | The deferred N1 probe rests on an **UNVERIFIED** claim — whether another process's `RegisterEventHotKey` starves our tap has never been measured | — | — | Deferred *because* it is unmeasured. Not built on an assumption |
| **R5** | The copy this unit deletes has **no test that would notice.** `SettingsCopy` has never had a byte-for-byte pin | Med | Low | M9 adds one |
| **R6** | Rebuilding wirings drops watchdog/timer state, mis-points the routing sink, or fails half-way — leaving the hotkey **silently dead** on an app where dead and working look identical | Med | **High** | M4a — atomic rebuild, previous wirings retained on failure, loud surface; post-condition pinned by test after every attempt, successful or not |
| **R7** | The `symbolichotkeys` format is undocumented and may change | Low | Low | Tolerant read; absent or unparseable ⇒ **no warning**, never a refusal. A detection failure must never block a rebind |

**Open questions**

1. Does the rebuild need to re-arm the tap, or only re-point `ModeRoutingSink.active`? The tap is
   binding-agnostic and owned above the wirings, so it should not — to be **confirmed in
   tech-plan** against `AppBootstrap.swift:1502-1512`, not assumed.
2. Should the recorder capture through the existing tap (already receiving the whole keyboard) or
   a local monitor scoped to the window? The former reuses the seam and avoids a new API family;
   the latter is contained. Decided in tech-plan.
3. Where the M7 safe-key set and the M6 refusal table live as one named table, for the
   single-source scan.

## 7a. Rough shape

Four aspects are the natural decomposition (§ Aspect decomposition, to follow): the Core
validity/refusal reducer, the store + launch read, the rebuild-on-idle-boundary mechanism, and
the recorder surface with its copy. The third is the only one carrying Fatal-rated risk; the
fourth is the only one executed by nothing in CI. No aspect depends on hardware to *build*, and
all four depend on the founder's machine to *verify*.

## 8. Out of scope

- **The Converse-mode second chord** (`PRODUCT_SPEC.md:192`) — P3, C11. One chord ships; the
  stored shape does not foreclose a second.
- **Widget position, launch at login, sounds** (`PRODUCT_SPEC.md:252`'s other General rows) —
  still deferred from `settings-live-controls/prd.md:175`.
- **The Privacy tab and its network-connection counter** (`PRODUCT_SPEC.md:277`).
- **Third-party conflict detection** (N1, N2) — see §5.3 and R4.
- **A Carbon `RegisterEventHotKey` fallback** — a C1 should-have (`hotkey-source/spec.md:88-91`),
  unrelated to rebinding: it exists to give a hotkey before Accessibility is granted, and cannot
  see `flagsChanged` so it cannot implement the stop rules.
- **Anything on the C7 streaming path, and the C8 matrix baseline run.**
- **Rebinding Escape** — Vocca's cancel key stays fixed.
- Cross-platform, cloud in the OSS core, hosted-tier work of any kind.

## 9. Self-critique — before building

1. **This does not clear a gate.** The founder can already dictate on ⌥Space; the matrix baseline
   run is what stands between Vocca and three unmeasured gates. This unit was chosen as the best
   available *build*, with that stated. If external testing is not imminent, it can wait.
2. **M8 is the weakest requirement in the PRD, and was kept deliberately.** It detects the
   collisions least likely to happen — most users have not rebound Spotlight — and cannot detect
   the ones C1-E names. The alternative of shipping M1–M7 alone (rebinding, the C1 must-have,
   with no detection at all — the C1 nice-to-have) **was put to the founder and declined**: the
   choice made was "Apple's shortcuts plus honest copy". It is recorded here as the weakest
   must-have so that if the unit runs long, this is the first thing to cut, not the last.
3. **The rebuild in M4 is the largest untested-in-CI surface.** No session, tap or window runs on a
   hosted runner, so what CI can prove is that the *decision* to rebuild is correct and that the
   post-conditions hold over fakes. The real rebuild's first execution is the founder's machine,
   exactly as steps 22–35 were the adapters'.
4. **M7 narrows a spec line by judgement, not by measurement.** No user has asked for a bare letter
   binding; equally, none has been asked. R3 records it.
