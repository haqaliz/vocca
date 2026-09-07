# Understanding: daily-use-ledger

> Phase 2 dig note for `feat/daily-use-ledger`. Sources cited inline. Written against
> `origin/master` @ `6ac909f`.

## What this work is really asking

Make the P0 gate's evidence **recorded rather than remembered**, by persisting the session
record the pipeline already produces and putting it in front of the user in Settings.

The pipeline already builds exactly the right value. `SessionRecord`
(`Sources/VoccaCore/SessionRecord.swift`) carries `outcome`, `spans`, `engine`, and its own
doc-comment states the privacy posture this unit must preserve: *"It records durations and
classes only — never audio, never text (plan §5)."* `SessionOutcomeClass`
(`Sources/VoccaCore/SessionOutcomeClass.swift`) already distinguishes the five exit routes —
`delivered(rung:verified:)`, `failsafeHeld`, `aborted`, `failed`, `emptySkip` — and already
carries the injection rung and read-back truth.

So this unit is **not** new measurement. It is retention, aggregation over calendar days, and a
surface. That is why it is small enough to be worth doing and why the risk is concentrated in
one place: the new on-disk artifact.

## What exists today (verified, not assumed)

| Thing | State | Citation |
|---|---|---|
| `LatencyLedger` | `actor`, cap `maximumRetainedRecords = 512`, drop-oldest at finalize | `LatencyLedger.swift:46,50,91-94` |
| Persistence | **None.** In-memory by construction | `LatencyLedger.swift:28-29`; `docs/STATUS.md:728` |
| UI surface | **None** | `docs/STATUS.md:728` |
| Inspection today | `snapshot()` → `[SessionRecord]`, `describe()` → `String`, headless via the probe's `PROBE-LATENCY` line | `LatencyLedger.swift:98,105`; `VoccaNetworkProbe.swift:281` |
| Clock | The ledger **reads no clock of any kind**; spans arrive pre-measured as `Duration` deltas | `LatencyLedger.swift:32-37` |
| Wall-clock time | **Absent everywhere in the ledger** — no `Date`, no timestamp field | verified by grep over `LatencyLedger.swift`, `SessionRecord.swift`, `LatencySpan.swift` |
| Refusal discipline | Every mutating entry point returns `Bool`; `VoccaCore` permits no `@discardableResult` | `LatencyLedger.swift:40-44` |

## The four constraints that shape the design

### 1. `VoccaCore` imports nothing at all

`grep -rhn "^import" Sources/VoccaCore/` returns **zero results**. The module is pure stdlib —
no Foundation, so no `Date`, no `JSONEncoder`, no `FileManager`. The prior slice states this as
intent: *"vocabulary + ledger live in `VoccaCore` (imports nothing; the histogram needs only
stdlib `Duration`)"* (`docs/planning/latency-instrumentation/prd.md:105-106`).

**Consequence:** the persistence adapter cannot live in `VoccaCore`. The split must mirror the
existing `InjectionStrategyStore` (protocol, `VoccaCore`) / `PersistentInjectionStrategyStore`
(FileManager adapter, `VoccaInject`) precedent — pure vocabulary and pure arithmetic in Core,
Foundation adapter outside it behind a seam.

### 2. A new `FileManager`-naming file needs a new row in the seam lint table, or CI fails

`Tests/HarnessTests/InjectionSeamBoundaryTests.swift:1165-1170` holds
`fileManagerSeamModuleRoots`, today exactly four seams:

```swift
"journal": "VoccaInject",
"dictionary": "VoccaText",
"config": "VoccaText",
"strategy": "VoccaInject",
```

The scan asserts that within each module owning a FileManager seam, no `FileManager` identifier
is named outside that module's permitted files
(`testNoFileManagerIdentifierEscapesTheFileManagerSeamTable`, `:1229`). A ledger-persistence
adapter therefore needs its own seam row **and a decided home module** — and neither `VoccaInject`
nor `VoccaText` is semantically right for it. **This is the unit's main open architectural
question** (see below).

The on-disk precedent to copy is concrete: `~/Library/Application Support/Vocca/strategies.json`,
written by atomic `FileManager.replaceItemAt` with a `homeDirectoryForCurrentUser` fallback
(`PersistentInjectionStrategyStore.swift:62-66,141-148`).

### 3. Time is passed in, never read — and calendar days are harder than the precedent

`StrategyMemory` is the precedent for time in Core: *"No clock — `now` is passed in"*
(`StrategyMemory.swift:35`), windows are plain `UInt64` second arithmetic
(`:26,84,121`).

That precedent does **not** transfer cleanly. `reprobeWindowSeconds` only needs *elapsed*
seconds; a **streak** needs *local calendar days*, and epoch-seconds ÷ 86400 yields UTC days.
Under that arithmetic a founder dictating each evening in a UTC-negative timezone can have two
sessions land on one UTC day and break a streak they actually kept — and DST shifts the boundary
again. The honest shape: the Foundation adapter resolves the **local calendar day** and passes it
in as a plain stdlib value (year/month/day), and `VoccaCore` does pure ordinal arithmetic on it.
The timezone/DST behaviour must be a pinned, named decision, not an accident of `/ 86400`.

### 4. R11 governs, and this unit deliberately revises a stated posture

The prior slice wrote: *"no persistence of audio or text; spans are durations only; **the ledger
never leaves the process**. This is the R11 line, asserted by the probe."*
(`docs/planning/latency-instrumentation/prd.md:118-120`).

This unit changes "never leaves the process" to "persists on this machine, shape-only,
user-clearable." That is a deliberate revision of a recorded posture and must be written up as
one — not slipped in. In its favour: on-disk history was listed as a **nice-to-have deferred by
slice** (`:99`), and out-of-scope *"for this slice"* (`:151-152`), never as forbidden; and
`strategies.json` already establishes that local on-disk state is acceptable in this product.

Against it, and the reason the design must be tight: a dated usage history is more revealing in
kind than a strategy map. `strategies.json` says *which rung works for Slack*. A dated ledger says
*when you were at your desk, how long you talked, and how often* — an activity trace. The
mitigation is aggregation: **persist per-day aggregates, not per-session dated rows.** Day
granularity answers every gate question (streak, loss count, rung tallies, percentiles) and
discards the intra-day timing that makes the file an activity trace.

## The correction this dig produced

The card originally carried "floor 1760 as of `1985da6`". That is wrong and would have caused a
bogus floor edit. `Scripts/test-with-floor.sh:1444` reads `MINIMUM_EXECUTED_TESTS=1758`;
`git show --stat 1985da6` changed **only** `Scripts/injection-matrix.sh`; its message reads
"1760 tests, 0 failures (floor 1758)" — 1760 is the *executed* count. `docs/STATUS.md`'s "Floor
1758 → 1760 tests" is loose prose about that run. **The binding floor is 1758.**

## Scope-guardrail check (`CLAUDE.md`)

- **Local-first / zero network** — passes, and strengthens the claim: the surface lets a
  sceptical user *see* that the numbers are local. Disk is not egress; the zero-network probe is
  unaffected but must be re-run green with persistence enabled.
- **macOS-only, open core, no cloud** — passes; nothing here presumes the hosted tier.
- **Dictation-first** — passes; this is instrumentation on the dictation core, not the agent
  layer.
- **Doesn't cripple the local core to sell the tier** — passes; it is additive and free.
- **Latency/injection are first-class** — the ledger must stay off the critical path. The prior
  slice's rule holds: *"recording is amortized O(1) appends"* (`prd.md:115-117`). A disk write per
  session must be off the dictation path — write on day-rollover / app-background / explicit
  flush, never synchronously inside `finalize`.

## Contradiction to flag, not paper over

**The ledger cannot observe the gate's actual wording.** `ROADMAP.md:102` reads: *"the founder
dictates as their primary text-input method for 7 consecutive days **without once reaching for
the keyboard to fix a Vocca failure**"*.

"Reaching for the keyboard" happens in **another application**. Vocca cannot see it. The ledger
can record what Vocca itself observed — `failsafeHeld`, `failed`, `aborted`, stuck sessions — and
those are strong proxies, but a founder who silently retyped a botched sentence in Slack leaves
**no trace in this ledger**. The surface must therefore present itself as *what Vocca observed*,
never as *the gate is passed*. A "7-day streak" badge that implies gate passage would be exactly
the overclaim this repository's preamble rules forbid.

Related precision: of the P0 gate's three legs, this unit instruments **two**.

| Leg (`ROADMAP.md:102`) | Instrumented here? |
|---|---|
| 7 consecutive days of daily use | **Yes** — streak from per-day aggregates |
| Transcript loss is zero | **Yes** — derived from outcome classes (`failed` vs `failsafeHeld`, which is a *hold*, not a loss — `SessionOutcomeClass.swift:27-28`) |
| Injection success ≥90% **across the matrix** | **No** — "across the matrix" is the matrix harness's job (`Scripts/injection-matrix.sh`), structurally capped at 17/20 on this machine (`docs/STATUS.md:44-46`) |

The ledger's per-rung tallies from real use are a **complement** to the matrix, not a substitute,
and must not be presented as an FMS number — the matrix owns that denominator discipline.

A bonus the roadmap already asks for and this unit can serve: *"Session reliability: 0
stuck-recording or missed-hotkey events across a week of real use"* (`ROADMAP.md:97`).
`SessionWatchdog.swift` and `EndReason.swift` exist, so stuck sessions are already classified —
worth folding into the aggregate rather than inventing later.

## Open questions for the PRD

1. **Which module owns the persistence seam?** `VoccaCore` cannot (no Foundation). `VoccaInject`
   and `VoccaText` are semantically wrong. Candidates: a new small module, or `VoccaBootstrap`
   (which already composes the ledger). Whichever is chosen adds a row to
   `fileManagerSeamModuleRoots` and must satisfy the module-boundary lint.
2. **Retention window.** The in-memory cap is 512 *records*; a day-aggregate file wants a *day*
   bound (30? 90?). Needs a decided number with a stated reason, pinned by a test.
3. **Day-boundary semantics.** Local calendar day; what happens across a timezone change or DST.
   Named and pinned, not emergent.
4. **Migration/corruption.** `strategies.json`'s handling of a missing/corrupt file is the
   precedent to mirror — confirm it degrades to empty rather than throwing.
5. **Write cadence.** Off the dictation critical path — when exactly?
6. **Does the surface get its own Settings tab, or a section in General?** A fifth tab is a
   product decision, and a PH publish is pending (`_card/issue.md`, adjacent context).
7. **Opt-in or on-by-default?** `strategies.json` persists without asking. A usage history is more
   sensitive in kind; R11 argues for at minimum a visible, clearable, honestly-labelled surface,
   and possibly a default-off switch.
