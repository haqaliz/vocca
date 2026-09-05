# PRD: daily-use-ledger

> **Unit:** `feat/daily-use-ledger` · **Phase:** P0 (milestone 7) with a C7 clause ·
> **Base:** `origin/master` @ `6ac909f` · **Written:** 2026-09-06
>
> Sources: `docs/planning/_card/issue.md` (brief), `docs/planning/_card/understanding.md`
> (Phase 2 dig). Every claim below is cited to a file; nothing is asserted from memory.

---

## Problem Statement

**The P0 gate is the only number in this repository that would be evidenced from memory.**

`ROADMAP.md:102` decides whether P0 is done: the founder dictates as their primary text-input
method for **7 consecutive days**, transcript loss is **zero**, injection success is **≥90%
across the matrix**. `docs/STATUS.md:49` records the gate as unmet — "its 7 consecutive days of
founder dictation have not started accumulating."

There is no instrument for it. The pipeline builds a complete `SessionRecord` per session
(`Sources/VoccaCore/SessionRecord.swift`) and hands it to `LatencyLedger`, but
`docs/STATUS.md:728` states the consequence plainly: "**The ledger is in-memory**: no
persistence, no UI surface, nothing ever transmitted." Every planning doc that touches the gate
carves the log out as a founder activity to be done by hand (`p2-gate-measurement/prd.md:194`,
`unmeasured-numbers-sweep/prd.md:249`, `deterministic-cleanup/prd.md:6`,
`llm-cleanup/prd.md:7,10`).

This repository's entire discipline is that a number without a file behind it is not a number.
The `unmeasured-numbers-sweep` unit exists because of that rule; the matrix voided four rows
rather than assert an unverifiable capture. Letting the **gate** be the exception is the
inconsistency this unit closes.

**Evidence the problem is real:** the founder's first real dictations are recorded as
"founder-reported" (`CLAUDE.md`, `p2-gate-measurement` entry) — reported, not instrumented. That
is exactly the standard of evidence the repo rejects everywhere else.

## Goals & Success Metrics

1. **The gate's two observable legs become file-backed.** After seven days of real use, the
   streak and the transcript-loss count are read from a file, not recalled.
2. **Zero new egress.** The zero-network probe stays green with persistence enabled. Disk is not
   network, and this unit must not blur that.
3. **Off the critical path — stated falsifiably.** No disk write occurs inside a dictation. The
   check is concrete: the CI fixture-replay benchmark (`LatencyBenchmarkTests`) stays green
   against `ProvisionalTolerances`, and the benchmark's **closed four-span contract gains no
   span** — the fold is not a measured stage. (The *real-engine* runner records rather than
   gates: `LatencyBenchmarkRealEngineTests.swift:40-41` — "never throws on a blown tolerance"; so
   it is evidence, not the gate.)
4. **The artifact is a tally, not a trace.** The persisted file contains no wall-clock times, no
   per-session rows, no text, and no audio. An inspector reading `usage.json` can tell *how a day
   went*, never *when the user was at their desk*.
5. **The surface never overclaims.** The Usage tab reports what Vocca observed. It never states
   or implies that the P0 gate has passed.

## User Personas & Scenarios

- **The founder running the P0 gate.** Dictates daily for a week, then opens Settings → Usage and
  reads the streak and the loss count instead of reconstructing them. This is the primary user
  and the reason the unit exists.
- **The sceptical local-first user** (the ICP: a Mac user who won't send audio to the cloud).
  Opens Usage precisely to check what Vocca keeps about them, sees a bounded per-day tally with a
  Clear button, and can verify the claim rather than trust it. The surface is a **privacy
  disclosure**, not just a dashboard — this is the framing that makes an on-disk history an asset
  instead of a liability.
- **The release engineer (founder, later contributors).** Compares real-use p50/p95 across
  releases from the retained window, complementing CI's fixture-replay benchmark.

## Requirements

### Must-have

| # | Requirement | Notes |
|---|---|---|
| M1 | **Per-day aggregate vocabulary in `VoccaCore`** — a `CalendarDay` value and a day aggregate carrying session count, a count per `SessionOutcomeClass`, a tally per `InjectionRung`, and pre-computed latency percentiles | Pure stdlib. `VoccaCore` imports **nothing** (verified by grep) — no `Date`, no Foundation |
| M2 | **Folding is pure and total** — a `SessionRecord` folds into a day aggregate for all five outcome classes, with no class coerced at the margin | `SessionOutcomeClass.swift:16-19` forbids force-labelling; the same rule applies here |
| **M2b** | **Distinguish a lost transcript from a reason-only failure.** `.failed` is currently recorded at two sites with opposite meanings, so the gate's zero-loss leg is **not derivable today**. The outcome vocabulary must separate them | See "The transcript-loss defect" below — this is a prerequisite for Goal 1, not an enhancement |
| M3 | **Streak arithmetic over local calendar days** — N consecutive days with ≥1 session yields streak N; a gap day resets it | Day boundary is **local**, supplied by the adapter; not `epochSeconds / 86400` (see Technical) |
| M4 | **Bounded retention: 30 calendar days**, oldest evicted on rollover | Mirrors `maximumRetainedRecords = 512`'s drop-oldest rule (`LatencyLedger.swift:50,91-94`) |
| M5 | **Persistence seam** — a protocol in `VoccaCore`, a `FileManager` adapter outside it, writing `~/Library/Application Support/Vocca/usage.json` atomically | Mirrors `PersistentInjectionStrategyStore.swift:62-66,141-148` exactly, including the `homeDirectoryForCurrentUser` fallback |
| M6 | **Shape-only on disk** — a test asserts a persisted file for a session carrying a known phrase never contains that phrase, and that no field carries a wall-clock time | The hard privacy pin; `SessionRecord.swift:20-21` already promises "durations and classes only" |
| M7 | **Missing or corrupt file degrades to empty**, never throws, never blocks a dictation | Follow the strategy store's precedent |
| M8 | **Writes are off the dictation critical path** — on day rollover, on app termination, and on explicit flush; never synchronously inside `finalize` | Goal 3 |
| M9 | **A `Usage` tab in Settings** showing streak, per-day sessions, outcome tallies, rung breakdown and p50/p95, with a **Clear history** control | User decision, 2026-09-06 |
| M10 | **The Clear control actually clears** — in-memory *and* on disk — and is pinned by a test | The disclosure is worthless if Clear is cosmetic |
| M11 | **Honest copy** — the tab states what Vocca observed and that the data is local; it never renders a gate verdict | See "The overclaim boundary" |
| M12 | **Zero-network probe green** with persistence enabled | Permanent release blocker (`ROADMAP.md` R11) |
| M13 | **"Not recorded" is a distinct state from zero** — a day with no latency samples renders `n/a`, never `0 ms` | The house rule, twice over: `LatencySpan.Presence.notPresent` never fabricates a `0` (`LatencySpan.swift:44-53`), and the benchmark's "no samples, no percentile — a row must print n/a, never a fabricated number" (`LatencyBenchmarkRealEngineTests.swift:75-76`) |
| M14 | **A stdlib-only percentile in `VoccaCore`** | No percentile function ships outside the harness today; the harness's nearest-rank uses `ceil` (Foundation, `LatencyBenchmarkRealEngineTests.swift:456-462`), so it needs a stdlib rewrite, not a move |
| M15 | **A `PRODUCT_SPEC.md` entry for the Usage tab lands with it** | `PRODUCT_SPEC.md:338` anticipates the feature ("No usage analytics. Metrics are local and inspectable") but describes no tab. The house copy-test convention pins strings byte-for-byte **against the spec** (`AppsTabCopyTests` cites `PRODUCT_SPEC.md:275`), so without an entry the copy tests would pin strings with nothing behind them |
| M16 | **The tab does not change while it is being read** — snapshot once in `.task`, no live ticking | `AppsTabState.swift:102-104`: "no time-based transition in it — the widget's never-auto-dismiss discipline, applied to a settings surface for the same reason: nothing here should change while a user is reading it" |

### Should-have

| # | Requirement |
|---|---|
| S1 | Session-reliability counters folded into the aggregate — stuck-session and watchdog-ended counts, since `SessionWatchdog.swift` / `EndReason.swift` already classify them and `ROADMAP.md:97` asks for "0 stuck-recording or missed-hotkey events across a week of real use" |
| S2 | A `describe()`-style headless rendering of the aggregate, so the probe and a script can read it without the UI — matching the existing `PROBE-LATENCY` discipline (`VoccaNetworkProbe.swift:281`) |
| S3 | A `SMOKE_CHECKLIST.md` entry for the founder's first real multi-day run |

### Nice-to-have

| # | Requirement |
|---|---|
| N1 | Engine attribution per day (Parakeet vs whisper), since `SessionRecord.engine` already carries it |
| N2 | An "export" affordance for the founder to attach the file to a gate record |

## Technical Considerations

**Phase placement.** P0 milestone 7 — "Failsafe + telemetry-free instrumentation … **local-only**
latency/success counters" (`ROADMAP.md:86`) — plus C7's unfulfilled "never transmitted,
**inspectable by the user**" clause (`CAPABILITY_ROADMAP.md:176`). **This unit advances no gate**
and must not be described as doing so.

**Pipeline layer.** Instrumentation across the whole capture → ASR → cleanup → injection loop. It
adds no engine, no model, no network path, and touches neither ASR nor the injection ladder's
behaviour.

### Module placement — the constraint that shapes everything

`grep -rhn "^import" Sources/VoccaCore/` returns **zero results**. `VoccaCore` is pure stdlib: no
Foundation, therefore no `Date`, no `JSONEncoder`, no `FileManager`. So:

| Piece | Module | Why |
|---|---|---|
| `CalendarDay`, day aggregate, fold, streak, eviction, percentiles | `VoccaCore` | Pure arithmetic, fully testable headless |
| `UsageStore` protocol | `VoccaCore` | Mirrors `InjectionStrategyStore` (`Sources/VoccaCore/StrategyMemory/InjectionStrategyStore.swift`) |
| `PersistentUsageStore` (FileManager + JSON + local-day resolution) | **UNDECIDED — see below** | The precedent I first cited was wrong |
| `UsageTabState` / `UsageTabReducer` / `UsageTabCopy` / `UsageSettingsPage` | `VoccaUI/Usage/` | Exactly the `Apps/` tab shape: `AppsTabState.swift` (pure state + action + reducer), `AppsTabCopy.swift` (pure copy), `AppsSettingsPage.swift` (thin view — internal, not public, and executed by nothing in CI) |

**How the tab gets its data** — copy the Apps precedent exactly, and note it is *not* what one
would guess: no `ObservableObject`, no observation of the Core actor. A plain `@State` value plus a
**snapshot struct** pulled once through an async closure in `.task`
(`AppsSettingsPage.swift:33,74-76`). The snapshot type exists precisely so actor-owned types never
cross the module line (`AppsTabState.swift:17-23`). The Settings read also constructs a **fresh
store** and loads it rather than reading the live in-memory instance (`AppBootstrap.swift:1258`,
`readAppStrategies()` at `:703-714`) — deliberate, and the right shape here too.

**The Clear control.** The codebase draws a line: reset-what-was-derived gets a plain button plus a
scoping sentence and **no dialog** (`AppsSettingsPage.swift:64-72` — correcting an earlier
assumption that Apps confirms); delete-bytes-off-disk gets a `confirmationDialog` with `.destructive`
and `.cancel` (`SpeechSettingsPage.swift:36-37,59-70`). Clearing the ledger *deletes bytes off
disk and is unrecoverable*, so it takes the **Speech** treatment. Both labels live in the Copy enum.

**Do not reach for `DesignTokens`.** `VoccaTheme` is the widget's vocabulary; **no settings page
uses it** — they use `.font(.caption)`, `.foregroundStyle(.secondary)`, `Form`/`Section`/`Table`.
Using `VoccaTheme.State.delivered` to colour a "delivered" count would also violate the
badge/state separation at `DesignTokens.swift:41-43`.
| Composition and the fold at finalize | `VoccaBootstrap` | Already the composition root; depends on `VoccaUI` (`Package.swift:124-135`); nothing may import it (ModuleBoundaryTests rule 5) |

**Correction (2026-09-06, from the Phase 2 agent sweep):** an earlier draft of this PRD claimed
`VoccaUI/Onboarding/CompletionFlagStore.swift` was a FileManager-backed store and used it to
justify putting the adapter in `VoccaUI`. **That is false.** `CompletionFlagStore` is
**`UserDefaults`**-backed (`CompletionFlagStore.swift:51,57`); it only *mentions* `FileManager` in
a comment contrasting itself with the JSON stores (`:24`). **`VoccaUI` has no filesystem precedent
at all** — a store there would be the first `VoccaUI` file ever to touch the disk.

That matters because the seam lint's own doc explicitly forbids the "we already have a store in
this module" argument for co-locating unrelated state
(`InjectionSeamBoundaryTests.swift:1466-1476`). So the home is a **live decision for
`tech-plan`**, not a settled recommendation:

| Option | For | Against |
|---|---|---|
| **`VoccaUI/Usage/`** | The tab lives there; `VoccaUI` may import Foundation; no new target | First filesystem touch in `VoccaUI`; a UI module owning persistence is poor layering |
| **New `VoccaUsage` module** | Clean seam rooted in its own module, mirrors the Core-protocol/adapter-module split exactly | New SwiftPM target + `ModuleBoundaryTests` update; the prior slice said "prefer none" (`latency-instrumentation/prd.md:110`) — though it said so about *types*, which do stay in Core |
| `VoccaBootstrap` | Already the composition root | **Rejected**: `AppBootstrap.swift:724` already names `FileManager.default.displayName`, so rooting a seam there fails the escape scan immediately or forces permitting `AppBootstrap.swift`, weakening the rule |

Whichever wins, adding a seam requires editing **two** places: the per-seam table
(`InjectionSeamBoundaryTests.swift:1154-1170`) *and* the hard exact-set pin at `:1293-1310` that
asserts the seam keys are exactly `["journal", "dictionary", "config", "strategy"]`.

### Storage format — a conflict with the authoritative doc

`docs/technical/ARCHITECTURE.md:596` already reserves a slot for exactly this data:

```
metrics.sqlite                    # local-only latency/success — never sent
```

`CLAUDE.md` makes `ARCHITECTURE.md` authoritative on technical design, so this cannot simply be
ignored. **Recommendation: JSON, and amend `ARCHITECTURE.md` in this unit.** Thirty day-rows is
well under 10 KB; SQLite would add a dependency and a migration surface to a file that is a tally.
Every other store in the tree is versioned JSON with `.sortedKeys`
(`PersistentInjectionStrategyStore.swift:161-165`). The amendment is a one-line, reviewed edit —
`usage.json` replacing `metrics.sqlite` — and it must land in this unit rather than leaving the
authoritative doc describing a file that does not exist.

### Do not decorate `LatencyLedger`

`DictationLoopRoot.latencyLedger` is typed **concretely** as `LatencyLedger?`
(`AppBootstrap.swift:1512-1516`), and its own doc says a recorder that is not a `LatencyLedger`
"leaves this `nil` rather than pretending an actor behind a different seam is one." The probe
reads that property and prints the `PROBE-LATENCY` line
(`DictationCycleDrive.swift:542-543`, `VoccaNetworkProbe.swift:277-281`), which the zero-network
suite asserts on.

**Consequence:** a persisted recorder that *wraps* `LatencyLedger` would silently null that
property and break the probe. The fold must either extend `LatencyLedger` itself or hang off a
separate sink — never a decorator in the `LatencyRecorder` position.

### The FileManager seam lint — a hard CI gate

`Tests/HarnessTests/InjectionSeamBoundaryTests.swift:1165-1170` holds
`fileManagerSeamModuleRoots`, today four seams rooted at `VoccaInject` and `VoccaText`, and
`testNoFileManagerIdentifierEscapesTheFileManagerSeamTable` (`:1229`) asserts no `FileManager`
identifier is named outside a module's permitted files.

Adding a `"usage": "VoccaUI"` row makes `VoccaUI` a scanned module for the first time. Its permit
set must therefore be the **union** of `CompletionFlagStore.swift` and the new adapter — the same
shape as `VoccaText`'s two-seam union (`:1178-1192`). Missing this fails CI, and it is the single
most likely way this unit goes red unexpectedly.

### Time — why the existing precedent does not transfer

`StrategyMemory` is the house pattern for time in Core: "No clock — `now` is passed in"
(`StrategyMemory.swift:35`), plain `UInt64` second arithmetic (`:26,84,121`). That works for
`reprobeWindowSeconds` because it needs only *elapsed* seconds.

A **streak** needs *local calendar days*. `epochSeconds / 86400` yields **UTC** days: a founder
dictating each evening west of UTC can have two evenings land in one UTC day and lose a streak
they actually kept, and DST moves the boundary again. **Decision:** the Foundation adapter
resolves the local calendar day and passes it in as a plain stdlib `CalendarDay` (year, month,
day); `VoccaCore` does pure ordinal arithmetic. The timezone/DST behaviour is a named, pinned
decision — a test fixes the chosen semantics rather than letting `/ 86400` decide by accident.

### The Settings tab is a reviewed product decision

`SettingsTab.allCases` is **five** today — `general, speech, cleanup, dictionary, apps`
(`Sources/VoccaUI/SettingsTab.swift:27-35`). `SettingsTabTests.testAllCasesAreTheFiveShippedTabs`
pins the exact list, and its failure message says why: "adding or removing one is a product
decision — and the order is the order they read in: how you start, who hears you, what happens to
the text, which words Vocca gets wrong, and where it all ends up."

`Usage` becomes the **sixth**, appended last — it is *how it went*, which follows *where it all
ends up*. The test must be edited deliberately (renamed to six), and every tab needs a distinct
title, symbol and id (`testEveryTabHasADistinctTitleAndSymbol`). `SettingsView.swift:249-250`
switches exhaustively, so the compiler enforces that the page exists.

### Data model (on disk)

```json
{ "version": 1,
  "days": [
    { "day": "2026-09-06",
      "sessions": 34,
      "delivered": 33, "failsafeHeld": 1, "failed": 0, "aborted": 0, "emptySkip": 0,
      "rungs": { "accessibility": 11, "clipboardPaste": 22 },
      "p50Ms": 113, "p95Ms": 358 } ] }
```

At most 30 objects. No wall-clock timestamps, no per-session rows, no text, no audio, no bundle
identifiers beyond the rung tally. A `version` field so a later shape change migrates rather than
corrupts.

**Encoding constraints found in Phase 2:** `SessionRecord`, `SessionOutcomeClass`, `LatencySpan`
and `SpanName` are **not** `Codable`, and `SpanName` has no raw values. `EngineIdentity`,
`InjectionRung` and `Duration` **are**. Since this unit persists aggregates rather than records,
the day row is a new `Codable` projection built for the purpose — but the rung keys must reuse
`InjectionRung`'s raw values, whose own doc calls them "the persisted spelling, so a rename is a
migration, not a refactor" (`InjectionRung.swift:29`).

**Decode discipline to mirror** (`PersistentInjectionStrategyStore.swift:177-215`): not one
`JSONDecoder` pass — `JSONSerialization` for the top level, then one decode **per element**, so a
single bad day row is skipped loudly rather than losing the file. Missing file → empty, silently.
Unreadable or wrong-version → empty, with exactly one loud log through an **injected** logger, so
tests assert the loudness rather than hope for it (`:130-133`). A load **never rewrites the file**
(pinned by `testCorruptElementsAreSkippedLoudlyAndTheFileIsNeverRewritten`).

### Non-functional

- **Latency budget:** zero measurable change to the benchmark gate's p50/p95. The fold is O(1)
  into an existing aggregate; the write is off-path (M8).
- **Size:** 30 rows keeps the file well under ~10 KB.
- **Concurrency:** `LatencyLedger` is an `actor`; the aggregate must be safe to update from the
  same contexts, and the reducer/state stay pure and `Sendable` per the `Apps/` precedent.
- **Test floor:** `Scripts/test-with-floor.sh:1444`, `MINIMUM_EXECUTED_TESTS=1758`, ratcheted in
  the same commit that adds tests.

## The overclaim boundary (a first-class requirement, not a caveat)

**The ledger cannot observe the gate's actual wording.** `ROADMAP.md:102` requires seven days
"**without once reaching for the keyboard to fix a Vocca failure**." Reaching for the keyboard
happens **in another application**. Vocca cannot see it. A founder who silently retyped a botched
sentence in Slack leaves **no trace in this ledger**.

Therefore the surface presents *what Vocca observed*, never a verdict. A "7-day streak" badge
that reads as gate passage is precisely the overclaim this repository's preamble rules forbid.

Of the gate's three legs, this unit instruments **two**:

| Leg (`ROADMAP.md:102`) | Instrumented here? |
|---|---|
| 7 consecutive days of daily use | **Yes** — streak over per-day aggregates |
| Transcript loss is zero | **Yes** — `failed` is a loss; `failsafeHeld` is a **hold**, not a loss (`SessionOutcomeClass.swift:27-28`) |
| Injection success ≥90% **across the matrix** | **No** — the matrix harness owns that denominator; it is structurally capped at 17/20 on this machine (`docs/STATUS.md:44-46`) |

The Usage tab's rung tallies are real-use observations and a **complement** to the matrix. They
must never be rendered as an FMS number.

## Risks & Open Questions

| # | Risk | Tie | Mitigation |
|---|---|---|---|
| U1 | **A dated on-disk usage history reads as surveillance in a product whose promise is that nothing persists** — and a Product Hunt publish is pending (`_card/issue.md`, adjacent context), so this file lands in front of a privacy-primed audience | `ROADMAP.md` **R11**, Med / **Fatal (positioning)** | Per-day aggregates only; no wall-clock times; 30-day bound; Clear button; the tab framed as a disclosure the user can verify. `strategies.json` is the standing precedent that local on-disk state is acceptable here |
| U2 | **This unit deliberately revises a recorded posture.** `latency-instrumentation/prd.md:118-120` wrote "the ledger never leaves the process. This is the R11 line" | R11 | Write the revision up explicitly in `docs/STATUS.md` — a stated posture changed by decision, not drifted. On-disk history was a deferred **nice-to-have** (`:99`) and out of scope "*for this slice*" (`:151-152`), never forbidden |
| U3 | **The FileManager seam scan turns red** the moment `VoccaUI` becomes a scanned module | CI | Permit set = union with `CompletionFlagStore.swift`; write the lint row before the adapter |
| U4 | **Streak semantics wrong across DST or a timezone change** | Correctness | Local `CalendarDay` from the adapter; pinned test; never `/ 86400` |
| U5 | **A vanity dashboard** — nobody opens it, and the week went to a surface instead of the matrix's 7 unrun rows | Opportunity cost | Accepted with eyes open (challenge raised and answered 2026-09-06). The gate-evidence justification stands on its own; the tab is the disclosure half |
| U6 | **A disk write lands on the dictation path** and moves p95 | `ROADMAP.md` R3 | M8; the benchmark gate is the check |
| U7 | **The `.failed` split ripples further than expected** — it is a closed enum several consumers switch over exhaustively | Correctness | Do it first and test-first (`loss-observability`); the compiler finds every consumer |
| U8 | **A decorating recorder silently breaks the zero-network probe** by nulling `DictationLoopRoot.latencyLedger` (`AppBootstrap.swift:1512-1516`) | Release blocker | Never decorate in the `LatencyRecorder` position; the probe's `PROBE-LATENCY` assertion is the tripwire |
| U9 | **`ARCHITECTURE.md` keeps describing `metrics.sqlite`** while the tree ships `usage.json` | Doc authority | Amend `ARCHITECTURE.md:596` in this unit, not later |

## The transcript-loss defect (found in Phase 2 — changes this unit's shape)

The P0 gate's hardest leg is transcript loss at **exactly 0%** — `ROADMAP.md:96`: "This metric has
no acceptable non-zero value." It turns out **the current vocabulary cannot express it.**

`SessionOutcomeClass.failed` is recorded at two sites that mean opposite things:

| Site | Situation | Is a transcript lost? |
|---|---|---|
| `DictationPipeline.swift:312` | `transcribe` threw. The code comment states it: *"Nothing was ever produced, so nothing is held and **nothing is lost** — the notice is the whole surface."* | **No** |
| `DictationPipeline.swift:376` | The ladder reached the failsafe rung, but the journal refused custody — `holder.current()` is `nil`. A transcript existed and nobody has it | **Yes — this is the loss** |

Both finalize as `.failed`. A persisted count of `.failed` is therefore **not** a transcript-loss
count, and a Usage tab reporting one would be stating a number the data cannot support — the exact
failure mode this repository voids matrix rows over.

**So this unit must first make the loss observable**, by separating the two in the outcome
vocabulary (a distinct case, or a flag on `.failed`). It is a closed-set change touching
`SessionOutcomeClass`, `LatencyLedger.describe()`, and every consumer — real work, and it must be
done test-first before any aggregate claims a loss figure.

This *strengthens* the case for the unit: the gate's zero-loss leg is currently unmeasurable **in
principle**, not merely unpersisted. It also means "just read `describe()` from a script" would
not have worked either.

### Edge cases the implementation must decide (each becomes a test)

| # | Case | Required behaviour |
|---|---|---|
| E1 | **A day with zero sessions** | No row is written. A gap in `days` *is* the gap that breaks a streak — absence is the signal, not a zero row |
| E2 | **The clock moves backwards** (timezone change west, DST fall-back, manual date change) | A day that already exists is updated, never duplicated; the aggregate is keyed by `CalendarDay`, so an out-of-order day is idempotent. The streak is computed from the *set* of days present, never from arrival order |
| E3 | **The app runs past midnight** without restarting | Rollover is detected on the next fold, not by a timer — the adapter supplies the current `CalendarDay` at fold time |
| E4 | **The app runs for more than 30 days** without restarting | Eviction happens on rollover, not at load; the in-memory window is bounded identically to the on-disk one |
| E5 | **Clear is pressed while a session is in flight** | The in-flight session folds into a fresh, empty day after clearing. Clear never has to reach into `LatencyLedger`'s in-flight state — that state has no outcome class yet (`LatencyLedger.swift:97-99`) |
| E6 | **Two Vocca processes** | Cannot occur — single-instance `LSUIElement` app. Stated so the atomic-replace write is not mistaken for multi-writer safety |
| E7 | **Corrupt / truncated / future-`version` file** | Degrades to empty and keeps recording (M7); never throws, never blocks a dictation |

**Open questions**

1. **Write cadence, exactly.** Day rollover + termination + explicit flush is the shape; whether
   an additional periodic flush is needed to survive a crash mid-day is a `tech-plan` decision.
   A crash today loses the in-memory ledger entirely, so any persistence is strictly better.
2. **Percentiles from aggregates — an unresolved conflict inside M1.** M1 says "pre-computed
   latency percentiles", but **percentiles do not average**: storing p50/p95 per day makes a
   window-wide "p50 over 30 days" uncomputable from the file. The tab must therefore either show
   per-day percentiles only, or the day row must carry a small bounded latency histogram
   (~20 buckets) from which any window percentile is exact. The histogram costs a few hundred
   bytes per day and keeps the file a tally — no timestamps either way. **`tech-plan` must resolve
   this before M1 is implemented**; shipping per-day-only percentiles and later wanting a window
   figure would be a file-format migration.
3. **Does `Usage` need an onboarding mention?** Out of scope here; flagged for the PH pass.

## Proposed aspect decomposition and rough size

The `Apps/` tab established the shape this unit copies, so the slices are predictable. Sizes are
*rough relative effort*, offered because the challenge phase weighed this unit against the
matrix's unrun rows — not commitments.

| Aspect | Boundary | Rough size |
|---|---|---|
| `loss-observability` | **Prerequisite.** Separate the lost-transcript `.failed` from the reason-only `.failed` in the outcome vocabulary; update `describe()` and every consumer | **S–M** — small surface, wide blast radius; must be first |
| `usage-vocabulary` | `VoccaCore`, pure: `CalendarDay`, day aggregate, the fold from `SessionRecord`, streak arithmetic, 30-day eviction, stdlib-only percentile/histogram maths | **M** — all pure, all headless, the bulk of the tests |
| `usage-store` | `UsageStore` protocol in `VoccaCore`; `PersistentUsageStore` FileManager+JSON adapter in `VoccaUI/Usage/`; atomic write; corrupt→empty; **the new `"usage": "VoccaUI"` seam-lint row and its union permit set** | **S–M** — mirrors `PersistentInjectionStrategyStore` closely; the lint row is the sharp edge |
| `usage-wiring` | `VoccaBootstrap`: fold at finalize, local-day resolution, write cadence off the critical path, composition | **S** |
| `usage-tab` | `VoccaUI/Usage/`: `UsageTabState`/`Reducer`/`Copy`, `UsageSettingsPage`, the sixth `SettingsTab` case, the deliberate edit to `testAllCasesAreTheFiveShippedTabs`, the Clear control | **M** — reducer and copy are where the tests live; the view stays thin |

Sequencing: `loss-observability` → `usage-vocabulary` → `usage-store` → `usage-wiring` →
`usage-tab`. `usage-vocabulary` and `usage-store` can run in parallel once the vocabulary's types
are pinned. `loss-observability` genuinely blocks the rest: an aggregate built on today's
ambiguous `.failed` would encode the defect into the file format.

**Revised size note.** The `loss-observability` prerequisite and the `ARCHITECTURE.md` amendment
were not in the first draft. This unit is larger than the initial sizing implied — closer to five
slices than four, with one of them touching a closed enum that several consumers switch over.

## Out of Scope

- Any network path, telemetry, or aggregate reporting of any kind. Local file only.
- Per-session rows and wall-clock timestamps on disk (explicitly rejected, 2026-09-06).
- Changing `LatencyLedger`'s in-memory cap, its refusal semantics, or the span vocabulary.
- The injection matrix's 7 unrun deliverable rows, step 92, and the Terminal/Warp re-run.
- The 10-second latency fixture (`docs/STATUS.md:187`) — a separate unit.
- Notarization.
- Any claim that a gate has passed as a result of this unit.
