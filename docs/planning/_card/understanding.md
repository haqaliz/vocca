# Understanding — C11 dual mode (dictate vs converse)

Synthesis of the Phase 1 brief + the two-agent dig (2026-09-16). Source of truth:
`CAPABILITY_ROADMAP.md:309-325` (C11), `PRODUCT_SPEC.md §5` (the dual-mode defense),
`ARCHITECTURE.md §12` (the P3 loop), the C10 unit records, and the code map.

## What the work really is

C10 shipped the voice-loop machinery (TurnTakingLoop, PlaybackEngine/SystemPlayback,
ContinuousAudioSource/StreamingCapture) **composed into nothing** — the loop holds no mic
seam, appears in `AppBootstrap.configure` zero times, and its only compositions are the
PROBE-TURN drive and the env-gated suites. C11's job is to make that machinery
**user-visible and structurally safe**: the converse mode, its surface, and the
guarantee that it can never leak into an app field.

Concretely, from the records:

1. **The mode machine.** `SessionMode {dictation, conversing}` exists as a declared-never-read
   enum (`Sources/VoccaCore/SessionMode.swift:25-31`). The roadmap's "explicit state machine"
   (`CAPABILITY_ROADMAP.md:321`) does not exist yet. The machine must select between the
   dictation path (SessionMachine-based wirings) and the converse path (TurnTakingLoop),
   with the injection path reachable **only** from dictate.
2. **The second hotkey.** `⌥⇧Space` is the recorded converse chord everywhere
   (PRODUCT_SPEC:192, hotkey-rebinding N3/out-of-scope, STATUS:1786). The stored shape is
   ONE chord (`HotkeyChord`, one key pair in `UserDefaultsSettingsStore`), persisted and
   rebindable; nothing forecloses a second but nothing stores one. Match semantics already
   use equality (`SessionRules.swift:66-72`), so `⌥⇧Space` cannot collide with `⌥Space`.
3. **The CONVERSING widget state.** `WidgetState` is a closed five-case enum (idle/opening/
   recording/transcribing/delivered) + separate `FailsafeState`; every deferral record names
   CONVERSING as the missing sixth state. PRODUCT_SPEC §5 demands **five simultaneous cues**
   (hotkey, shape, color, label, sound — the "four differences" in L188 is prose drift vs the
   five-row table; C11 implements the five). No implicit switching, no mid-session switching;
   converse never shows a target app name; the absence of `→ AppName` is itself a signal.
4. **Per-mode configuration.** Cleanup per-mode is explicitly deferred here (llm-cleanup
   prd:216,267; cleanup-config:48; CleanupContext.mode declared-not-read). Per-mode engine
   choice is also deferred here (engine-picker:39) but has **no reserved stored shape** —
   `EngineSelection` is one value persisted as one tier string; this is an unplanned
   extension that must be scoped deliberately.
5. **The loop wiring (the C10 handoff).** `onStateChange` (N1) present, wired by nothing
   (`TurnTakingLoop.swift:107-108`); the `PlaybackLevel` duck knob (N2) is plain data;
   the composition recipe (capture-stream driver + reply-generator slot + configure-adjacent
   wiring) is explicitly recorded as C11's. The loop's signatures are frozen
   (barge-in-loop plan L268-269, L866-868) — C11 wraps/selects, never modifies.
6. **The structural guarantee.** Acceptance: in converse mode **no `TextInjector` call is
   ever made** — enforced by type or assertion, not discipline. Production inject sites today:
   `DictationPipeline.swift:381` (dictation routeFinal) + two AppBootstrap sites (failsafe
   retry, probe helper).

## Affected areas (file map)

| Area | Today | C11 change |
|---|---|---|
| `VoccaCore/SessionMode.swift` | declared-never-read enum | become the mode machine (or the machine lives beside it) |
| `VoccaCore/CleanupContext.swift` | `mode` declared-not-read | per-mode cleanup resolution consumes it |
| `VoccaCore/EngineSelection.swift` + `PersistedSettings` | single selection | per-mode shape (scope decision) |
| `VoccaCore/WidgetProjection.swift` | closed five-case `WidgetState` | + CONVERSING state(s) |
| `VoccaUI/WidgetStateReducer/Store` + LiveWidget etc. | five states | converse visuals (shape/color/label/sound) |
| `VoccaCore/HotkeyChord.swift` + `UserDefaultsSettingsStore` + `AppBootstrap` rebind | one chord | second chord persist/rebind |
| `AppBootstrap.configure` | dictation wirings only | converse wiring (the C10 recipe) |
| `TurnTakingLoop` + `PlaybackEngine` + `StreamingCapture` | shipped, wired by nothing | wire via the recorded recipe |
| `MatrixEvidence` | already spells both modes | mode now real (evidence rows gain meaning) |
| `Scripts/test-with-floor.sh` | floor 2160 | ratchet per test-adding commit |

## Ambiguities / open questions (for the interview)

- **Q1 — The reply generator's slot.** The loop emits `.speakReply(text:)`; who supplies
  reply text? C13 (actions/agent) is the real generator. C11 must decide: a minimal
  local/conversational stand-in (e.g. seeded echo or rule-based reply) to make the loop
  exercisable, or the slot left empty with the surface showing only state? The P3 gate
  needs a full spoken exchange — that needs *some* reply source.
- **Q2 — Converse transcript surface** (`PRODUCT_SPEC.md:379`, explicitly "C11/C13's
  question"): replies render inside the widget or an expanded panel? Scope for C11 vs C13.
- **Q3 — Per-mode engine selection**: ship per-mode ASR now (stored-shape extension) or
  per-mode cleanup only, with engine deferred? Roadmap lists both; engine-picker defers to
  C11 but no shape is reserved.
- **Q4 — Menu-bar mode toggle** (`PRODUCT_SPEC.md:361`): explicit switch surface — in scope
  for C11 or hotkeys only?
- **Q5 — Settings surface**: converse chord in General + collision warning
  (PRODUCT_SPEC:252) — extend the rebind flow to two chords, or ship the converse chord
  fixed with rebind follow-on?
- **Q6 — Ledger**: converse-mode ledger folding is excluded from C10 but assigned to nobody;
  `SessionKind {dictation, onboarding}`. Count converse sessions or leave the ledger
  dictation-only?
- **Q7 — SMOKE rows**: no dual-mode SMOKE steps exist; C11 should add its rows (mode
  clarity, mis-injection = 0, the full spoken exchange).

## Contradictions surfaced (flag, don't paper over)

1. PRODUCT_SPEC §5 says "four simultaneous differences" but tables five cues (and calls color
   the "third"). C11 implements the five; the spec prose gets corrected in the record.
2. `◈ listening…` (§2 state art) vs `◈ Vocca` (§5 label row) — decide: persistent label
   `◈ Vocca`, in-state listening text `◈ listening…`.
3. Two "modes" collide: hold/toggle **activation** mode (`defaultMode`/`setActiveMode`) vs
   dictate/converse `SessionMode`. Known to the docs (cleanup-seam spec:139-141); C11 must
   not conflate them — the machine routes by **chord**, and the activation mode stays a
   dictation-only configuration.

## Guardrail check

- **In scope**: macOS-only, local-first, no cloud, no egress surface. ✓
- **Dictation-first**: the P0 loop is shipped and digest-pinned; C11 only *adds* the
  converse path and must leave `SessionMachine.swift`/`DictationPipeline.swift` untouched
  (the G5 pin at `TurnTakingComposedAcceptanceTests.swift:317-347` — **C11's wiring lands
  in `AppBootstrap.swift`, which is IN the pin; the pin's own contract requires a
  deliberate, reviewed re-anchor, never an edit-to-match**).
- **Latency/injection battles**: the injection path is untouched; the dictate path keeps
  its pin. Converse adds no injection.
- **Zero-network + transcript-never-lost**: converse wires nothing new to a URL; the loop
  already names no network. The I1 invariant stays dictation-owned.
- **The 5×/200 ms/≤50 ms contracts**: consumed, never re-litigated. `ParakeetEOU` stays
  PENDING; `SilenceThresholdDetector` is the shipped `TurnDetector`.
- **Gates**: P2/P3 uncleared — third unit built ahead under the recorded posture.

## Phase placement

P3 (voice loop), the wedge-starting phase. Not a dictation-core change; no P4 (actions)
scope in this unit.