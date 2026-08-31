# Aspect spec: rewarm-after-idle

**Unit:** speculative-asr (C7 remainder) · **Aspect:** rewarm-after-idle
**PRD refs:** M7, Q5, Goal 4

## Problem slice and user outcome

Warm start shipped for the launch path only: launch preload is pinned
(`WarmStartLaunchTests.swift:172,237`), the 1.2 bound lives in `WarmStartTargets`
(`WarmStartRatio.swift:25-29`), but "first dictation after launch is not the slow one"
(`CAPABILITY_ROADMAP.md:69-73`) holds only for the first dictation after *launch* — a coffee
break returns to a cold engine because `DictationEngineResolver.isPrepared` is sticky
(`DictationEngineResolver.swift:80,99`) and a second `prepare()` is a no-op in both engines
(`ParakeetEngine.swift:142`, `WhisperCppEngine.swift:119`). Outcome: after 5 minutes idle, the
engine re-warms in the background (disk-only, no mic dot), and the first dictation after idle
is recorded as its own timing row.

## In-scope requirements

1. **Idle policy.** A new policy object observes the session machine's transitions (the
   watchdog's `wake()`/`schedule` shape, `SessionWatchdog.swift:200-210,312-401`): when the
   machine has been idle for **5 minutes** (constant in exactly one file, single-source
   scanned; founder decision 2026-08-31) with no session and no in-flight prepare, it
   re-invokes `prepareIfNeeded()` once.
2. **A genuine re-warm path in the engines.** Today a second `prepare()` is a no-op after the
   first load — the engines need a real re-warm (e.g. an unload/reload cycle or an explicit
   `warm()` seam) so the idle policy does something. The launch behavior is unchanged: exactly
   one prepare at launch, never on the session path (`configure` never prepares — pinned).
3. **Recorded, not gated.** Idle re-warm is a new `EngineTiming` row (`EngineTiming.swift:23-51`
   — a fourth kind or a separate ledger row), recorded beside suppression state; the 1.2 bound
   remains launch-path-only (`STATUS.md:831-832`) unless the founder's re-baseline procedure
   extends it.
4. **Privacy policy intact.** Model re-warm is disk-only and lights nothing; the *audio* engine
   stays cold when idle (orange-mic-dot policy, `ARCHITECTURE.md:336-346`) — the idle policy
   must never touch the audio engine.

## Out-of-scope boundaries

- No change to the launch warm-start bound or its tests.
- No audio-engine warm-up of any kind.
- No power/battery policy (battery + display-asleep remain untried per STATUS.md's App Nap
  entry) — the policy is time-idle only.

## Acceptance criteria (tests written first)

- The idle policy is pure and headless-tested: idle < 5 min → no prepare; idle ≥ 5 min →
  exactly one re-prepare; a session starting during the window cancels/reschedules; a prepare
  already in flight is not doubled (single-flight, `DictationEngineResolver.swift:129-136`
  precedent).
- The engines' re-warm path is tested with the engine-store doubles: after re-warm, a
  transcribe is warm (recorded), and the launch-prepare-once pins still pass.
- `configure` still never prepares (unchanged pin); zero-network probe still green.
- The new timing row appears in the benchmark output beside suppression state; a SMOKE step
  records the first real observation (rule 1: verify the state was entered — the machine
  must actually have sat idle 5 minutes before the row means anything).

## Dependencies and sequencing

- Depends on `WarmStartRatio`/`EngineTiming`/`DictationEngineResolver` (shipped) and the
  session machine's transition surface. Independent of the other four aspects — parallelizable.
- The 5-minute constant is provisional (Q5): re-baselined by the founder's real run, recorded
  not gated.

## Open questions / risks

- Q5: reload cost unmeasured — a re-warm that itself takes seconds could race the next
  session's opening; the plan must pin the ordering (prepare in flight → session starts →
  what the first dictation waits on).
- The engine-store re-warm path interacts with `EngineTier.storageID` keying
  (settings-live-controls amendment) — re-warm must respect the selected tier, never re-load
  the other one.