# Aspect spec: loss-observability

> Parent PRD: `docs/planning/daily-use-ledger/prd.md` · Aspect 1 of 5 · **Blocks the rest.**

## Problem slice

The P0 gate's hardest leg is transcript loss at **exactly 0%** — `ROADMAP.md:96`: *"This metric
has no acceptable non-zero value."*

`SessionOutcomeClass.failed` is recorded at **six** sites, and only **one** of them means a
transcript was lost. The other five mean nothing was ever produced. A count of `.failed` is
therefore not a loss count, and the gate's zero-loss leg is **unmeasurable in principle** — not
merely unpersisted.

This aspect makes the loss observable, so every later aspect can count it honestly.

## The six sites, adjudicated

Each cite is verbatim from the code's own comment where one exists.

| # | Site | What happened | Loss? |
|---|---|---|---|
| 1 | `DictationPipeline.swift:239` | The stream threw. *"a failed stream is a reason-only notice — nothing was ever produced, so nothing is held and nothing is lost."* | **No** |
| 2 | `DictationPipeline.swift:251` | The stream ended with no final. *"nothing was produced, so the failure is the whole surface."* | **No** |
| 3 | `DictationPipeline.swift:312` | `transcribe` threw. *"Nothing was ever produced, so nothing is held and nothing is lost — the notice is the whole surface."* | **No** |
| 4 | **`DictationPipeline.swift:376`** | The ladder reached `.widgetFailsafe`, but `holder.current()` was `nil` — the journal refused custody. *"the residual (nothing held — the journal refused custody) surfaces the exhaustion reason rather than pretending the text is somewhere it is not."* A transcript existed; nobody has it | **YES — the only one** |
| 5 | `AppBootstrap.swift:2639` | The session ended and found no pipeline; presents `.exhausted` | **No** — audio was captured but never transcribed, so no *transcript* was produced to lose. A failed dictation, not a lost transcript |
| 6 | `AppBootstrap.swift:2694` | A capture that never happened | **No** |

**Sizing correction to the PRD.** The parent PRD called this "S–M, wide blast radius; the
compiler finds every consumer." Having enumerated them, the blast radius is **narrow**: six
`finalize` call sites, one `switch` in `LatencyLedger.describe()`, and the tests. Most of the
`.failed` matches elsewhere in the tree belong to unrelated enums (download state in
`SpeechSettingsPage`/`EnginePickerView`/`OnboardingView`, `TapHealthPolicy`,
`InjectionLadderDecision`, `ProbeInjectionStrategy`) and are untouched. This is an **S**.

## In scope

1. A distinct outcome for the lost case in `SessionOutcomeClass`, so the two meanings cannot be
   conflated by a counter. Name and shape are the plan's decision; `.lost` is the working name.
2. Site 4 changed to it; sites 1, 2, 3, 5, 6 left as `.failed` and **pinned** so a later edit
   cannot quietly reclassify them.
3. `LatencyLedger.describe()` renders the new case distinctly (it switches exhaustively —
   `LatencyLedger.swift:113-125`).
4. Doc comments updated where they enumerate the classes: `SessionOutcomeClass.swift:16-21`,
   `SessionRecord.swift:22-25`.

## Out of scope

- Persistence, aggregation, the Usage tab — later aspects.
- Changing *behaviour*: what the user sees is identical. The failsafe still holds what it can,
  `.exhausted` is still the surface at site 4, no notice text changes. This aspect changes only
  what the ledger can *say* about what happened.
- Re-adjudicating site 5. It is recorded above as "not a transcript loss" with its reason; a
  future unit may add a separate "dictation abandoned" counter, which is not this.

## Acceptance criteria (tests written first)

| # | Test | Asserts |
|---|---|---|
| A1 | The failsafe rung with a holder that returns `nil` finalizes as **lost**, not `.failed` | The defect itself — RED before the change |
| A2 | The failsafe rung with a holder that returns text finalizes as `.failsafeHeld` | Unchanged; the neighbouring branch does not regress |
| A3 | A throwing `transcribe` finalizes as `.failed`, **not** lost | Site 3 stays not-a-loss |
| A4 | A throwing stream, and a stream with no final, each finalize as `.failed`, not lost | Sites 1 and 2 |
| A5 | `describe()` renders the lost case with its own spelling, distinct from `failed` | The headless surface can tell them apart |
| A6 | A source-level pin: exactly one `finalize` site in `Sources/` names the lost case | The scan precedent (`testTheRememberedAppsCapLivesOnlyInTheNamedConstant`, `InjectionStrategyStoreTests.swift:42`) with a vacuity guard in both directions |
| A7 | Exhaustiveness: every `SessionOutcomeClass` case round-trips through `describe()` with a distinct rendering | No two classes render alike |

A1 is the RED test. It must fail against the current tree for the right reason — the failsafe
no-custody path reporting `.failed` — before any production edit.

## Dependencies and sequencing

- **Depends on:** nothing. It is first precisely because the aggregate's file format would
  otherwise encode the defect.
- **Blocks:** `usage-vocabulary` (the fold counts losses), and transitively everything after.

## Risks specific to this aspect

| Risk | Mitigation |
|---|---|
| The probe's `PROBE-LATENCY` line is asserted by the zero-network suite (`VoccaNetworkProbe.swift:277-281`); changing `describe()`'s output could break it | Check the probe's assertions before editing `describe()`; if a fixture pins the exact string, update it in the same commit |
| `SessionOutcomeClass` is `public` API of `VoccaCore` | Nothing outside the package consumes it; the compiler finds every in-tree switch |
| Renaming existing spellings would be a migration | Do **not** rename `failed`; only add. `InjectionRung.swift:29`'s rule ("the raw values are the persisted spelling, so a rename is a migration") is the house instinct even where nothing is persisted yet |
| The new case must not fabricate a rung | Site 4 has no successful rung by definition; the case carries no rung, matching `Presence.notPresent`'s no-fabrication discipline |

## Open question for the plan

**Does the lost case carry a reason?** Site 4's cause is specifically "the journal refused
custody." A payload-free `.lost` is simplest and sufficient for a count; a `.lost(reason:)` would
let a later surface say *why* the only transcript this product promises never to lose was lost.
The plan should decide, with the bias toward the simpler shape unless the reason is free.
