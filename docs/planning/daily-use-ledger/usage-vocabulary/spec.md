# Aspect spec: usage-vocabulary

> Parent PRD: `docs/planning/daily-use-ledger/prd.md` · Aspect 2 of 5
> Depends on: `loss-observability` (complete — `SessionOutcomeClass.lost` exists)
> Blocks: `usage-store`, `usage-wiring`, `usage-tab`

## Problem slice

Turn the per-session records the pipeline already produces into **per-day aggregates** that
answer the P0 gate's questions — how many consecutive days, how many transcripts lost, how the
latency sat — as pure, headless arithmetic in `VoccaCore`.

Everything here is a value type and a pure function. Nothing in this aspect reads a clock, touches
a disk, or renders a view. That is what makes it the aspect with the most tests and the fewest
ways to go wrong.

## Founder decisions carried in (2026-09-06)

1. **Session kind is tagged.** Onboarding "TRY IT" runs through the same ledger
   (`AppBootstrap.swift:454` passes the same `recorder: ledger` under both injector
   compositions), and because the onboarding injector never holds — the sink owns delivery —
   every refused TRY IT is a `.lost`. Aggregates therefore separate onboarding from real work, so
   the gate figure is about daily use while a setup failure stays visible rather than hidden.
2. **Latency is stored as a bounded histogram per day**, not as pre-computed p50/p95, because
   percentiles do not average and a 30-day figure must be computable and defensible. This is a
   file-format decision; changing it later is a migration.

## In scope

### Half A — session kind in the record

- `SessionKind` (`dictation` / `onboarding`), stdlib-only, in `VoccaCore`.
- `SessionRecord` gains `kind`.
- `LatencyRecorder.finalize` gains a `kind:` parameter. Small blast radius: one production
  conformance (`LatencyLedger`), one test stub (`LatencyVocabularyTests.swift:232`), and the call
  sites in `DictationPipeline` and `AppBootstrap`.
- This aspect supplies the **type and the plumbing**; `usage-wiring` supplies the real value from
  `injectorComposition`. Until then the composition passes `.dictation` and the onboarding branch
  passes `.onboarding` — which is already knowable at `AppBootstrap.swift:443-457`, so wiring it
  correctly here is cheap and avoids a knowingly-wrong intermediate state.

### Half B — the aggregate

- **`CalendarDay`** — year, month, day as plain integers. `Comparable`, `Hashable`. Includes a
  pure proleptic-Gregorian **day-number** conversion so "consecutive" is integer subtraction.
  `VoccaCore` has no `Calendar` and no clock, so this arithmetic must be written, not borrowed.
- **`DayAggregate`** — for one `CalendarDay`: total sessions, a count per `SessionOutcomeClass`,
  a tally per `InjectionRung` for delivered sessions, a latency histogram, and the same counts
  again for onboarding sessions kept separate from real work.
- **The fold** — `SessionRecord` → `DayAggregate`, total over all six outcome classes and both
  kinds, coercing nothing at the margin.
- **Streak** — over a set of `CalendarDay`s: N consecutive days each having ≥1 **non-onboarding**
  session yields streak N; a gap resets it. Streak is about daily use as primary text input, so
  an onboarding-only day is not a day of use.
- **Retention** — 30 days, oldest evicted; a day with no sessions is absent rather than zero
  (absence is the signal that breaks a streak).
- **Latency histogram** — fixed bucket upper bounds, pinned as a named constant, straddling the
  P2 targets (p50 ≤ 400 ms, p95 ≤ 800 ms, `ROADMAP.md:171`) so the gate's question is answerable
  exactly at a bucket boundary.
- **Nearest-rank percentile over the histogram**, stdlib-only. The harness's existing helper uses
  Foundation's `ceil` (`LatencyBenchmarkRealEngineTests.swift:456-462`), so this is a rewrite, not
  a move.

## Out of scope

- Persistence, JSON, `FileManager`, any file format on disk (`usage-store`).
- Reading the real clock or resolving "today" into a `CalendarDay` (`usage-wiring` — the adapter
  supplies it, exactly as `LatencySpan.elapsed` arrives already measured).
- Any UI, copy, or tab (`usage-tab`).
- Changing `LatencyLedger`'s in-memory cap, its refusal semantics, or the span vocabulary.
- Engine attribution per day (PRD N1, nice-to-have).

## Acceptance criteria (tests written first)

### Half A

| # | Test | Asserts |
|---|---|---|
| B1 | A record finalized under the onboarding composition carries `.onboarding`; one under the ladder carries `.dictation` | The kind is real, not a constant |
| B2 | `describe()` renders the kind, distinctly | The headless surface can tell them apart |

### Half B — the fold and the day

| # | Test | Asserts |
|---|---|---|
| B3 | Folding one record of each of the six outcome classes yields the six counts, nothing coerced | Totality |
| B4 | Onboarding sessions land in the onboarding counts and **never** in the real-work counts | Decision 1 |
| B5 | A delivered record's rung increments exactly that rung's tally; a non-delivered record increments none | No fabricated rung |
| B6 | `lost` is counted separately from `failed`, and `failsafeHeld` counts as neither | The `loss-observability` distinction survives the fold |

### Half B — days, streaks, retention

| # | Test | Asserts |
|---|---|---|
| B7 | Day-number arithmetic is correct across a month boundary, a leap day (2028-02-29), a non-leap February (2026-02-28 → 03-01), and a year boundary | The hand-written calendar maths |
| B8 | N consecutive days with ≥1 real session yields streak N | The gate's first leg |
| B9 | A gap day resets the streak; an out-of-order insertion does not duplicate a day | E1/E2 from the PRD |
| B10 | A day with only onboarding sessions does not extend a streak | Decision 1 |
| B11 | Retention keeps at most 30 days, evicting oldest first | M4 |

### Half B — latency

| # | Test | Asserts |
|---|---|---|
| B12 | A sample lands in the bucket whose upper bound it is ≤, and a sample above the last bound lands in the overflow bucket | Bucketing |
| B13 | Percentiles over a known histogram match a hand-computed nearest rank, including the single-sample and all-in-one-bucket cases | The maths |
| B14 | **No samples yields no percentile** — `nil`, never `0` | `LatencySpan.Presence.notPresent`'s no-fabrication rule and `LatencyBenchmarkRealEngineTests.swift:75-76` |
| B15 | Percentiles over a multi-day window are computed from summed buckets, not from averaged per-day percentiles | Decision 2 — the reason the histogram exists |
| B16 | The bucket bounds live in exactly one named constant, pinned by a source scan | They are the persisted spelling; a silent change is a migration |

## Risks specific to this aspect

| Risk | Mitigation |
|---|---|
| Hand-written calendar arithmetic is subtly wrong (leap years, month lengths) | B7 covers the four boundary classes explicitly. Use the standard proleptic-Gregorian day-number algorithm; do not invent one |
| Bucket bounds chosen carelessly become a migration | Pin them in one constant (B16), straddle the P2 targets exactly, and document that a change is a format migration |
| A percentile reported to false precision | The histogram gives bucket resolution, not milliseconds. The honest report is the bucket's upper bound — which answers the gate's actual question ("is p95 ≤ 800 ms?") exactly. `usage-tab` must render it as a bound, never as a spot value |
| The `finalize` signature change ripples | It does not: one production conformance, one stub, two call-site files. The compiler names them all |
| Scope creep into wiring | The adapter supplies "today" and the real composition kind. This aspect never reads a clock |

## Note on unit scope

This is the second time the unit has grown: `loss-observability` was added when the transcript-loss
defect surfaced, and Half A here was added by the onboarding decision. Both were discoveries from
reading the code rather than changes of mind, and both are recorded. The unit is now five aspects
with a sixth's worth of work in this one. Worth stating plainly rather than letting the estimate
drift silently.
