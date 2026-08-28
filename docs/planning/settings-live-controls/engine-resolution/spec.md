# Aspect 3: `engine-resolution`

**Merge order: 3rd.** Depends on aspect 2.

## Problem slice

Five sites read the hardcoded `EngineSelection.defaultSelection`
(`AppBootstrap.swift:196,206,208,355,937`), and `DictationEngineResolver` stores its selection at
`init` (`DictationEngineResolver.swift:83-85`), documenting *"resolution is never repeated, only
preparation is"* (`:29-31`) with `isPrepared` sticky.

`CAPABILITY_ROADMAP.md:81` requires switching **without restart**. The house precedent for a live
setting is `setActiveMode` (`AppBootstrap.swift:1277-1291`): refuse while a session is in flight,
log, otherwise apply — *"a user who changes this while dictating gets the change on their next
press rather than a broken session"* (`:934`).

**A contract that is currently untrue:** `EngineSelectionConsumptionTests.swift:24-27` documents
*"No restart needed … nothing about it is cached at launch."* That is true of the pure
`EngineSessionStart.resolve`, and false of the wired root. This aspect makes it true; the doc
comment is corrected either way.

**User outcome:** change the engine, press, and the next dictation uses it.

## In scope

- **R1** All five sites read the persisted selection; `defaultSelection` is reached only on an
  empty/invalid store.
- **R2** **Next-session-boundary switching.** A change while a session is in flight is refused and
  logged; otherwise it applies to the next session. A running session is never swapped.
- **R3** **Eager preparation on switch** (PRD M10). Selecting a different engine starts its
  `prepare()` immediately, so the first press afterwards is not refused by `engineIfReady()` for a
  model that is already on disk.
- **R4** A *preparing* state distinguishable from *unavailable*, so the in-between window does not
  look like a failure (PRD M11).
- **R5** Activation mode read from the store at launch (PRD M7), so `activeMode` no longer derives
  from a constant.
- **R6** The corrected doc comment on `EngineSelectionConsumptionTests`.

## Out of scope

- The Speech page itself (aspect 4) and the Cleanup page (aspect 5).
- Any new latency claim. The C7 warm-start bound covers the **launch** path only; this aspect
  must not imply a post-switch warm-start number (PRD R-F).

## Acceptance criteria (tests first)

1. A store holding Whisper ⇒ the root resolves the whisper identity; an empty store ⇒ Parakeet.
   Driven over the seam, headless.
2. **A session in flight is never swapped:** a selection change mid-session leaves the running
   session's `engineIdentity` unchanged, and the change is refused and logged.
3. A session started *after* a change resolves the **new** engine — no restart, C3's acceptance.
4. R3: a switch triggers `prepare()` on the newly selected engine exactly once, without a press.
5. R4: with a switch in flight, the reported state is *preparing*, not *unavailable*, and the two
   are distinguishable in the projection the UI and menu bar read.
6. R5: activation mode survives a simulated relaunch.
7. The zero-network probe stays green and its `PROBE-CYCLE`/`PROBE-LATENCY` output is unchanged for
   the default configuration.

## Risks

- The resolver is an actor with sticky `isPrepared`. Replacing it per switch must not break the
  single-flight guarantee or start two preparations of the same engine.
- The readiness gate is what keeps "refuse before the microphone opens" true. Any change here is
  changing a safety property, not a convenience.
