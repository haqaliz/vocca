# Aspect spec: usage-store

> Parent PRD: `docs/planning/daily-use-ledger/prd.md` · Aspect 3 of 5
> Depends on: `usage-vocabulary` (complete — `UsageWindow`, `DayAggregate`, `CalendarDay`,
> `LatencyHistogram` all exist and are pure)
> Blocks: `usage-wiring`, `usage-tab`

## Problem slice

Give the usage window a home on disk: `~/Library/Application Support/Vocca/usage.json`, written
atomically, read tolerantly, and **shape-only** — counts, buckets and dates, never a transcript,
never a wall-clock time, never audio.

This is the aspect that creates the artifact. Until now the unit has added defect fixes and pure
vocabulary; nothing new is persisted about a user. After this, something is.

## The module decision — resolved

The PRD left this open. It resolves to a **new adapter module, `VoccaUsage`**, on the rules the
tree already states.

`ModuleBoundaryTests.swift:39-45` names rule 3: *"An **adapter** module imports `VoccaCore` and
nothing else among Vocca modules."* Its long comment records that the tree deliberately settled on
ports-and-adapters — the core owns the seams and imports nothing; adapters depend on the core to
implement them. A `FileManager`-backed store implementing a `VoccaCore` seam is exactly that
shape, and `adapterModules` (`:107`) is the set it joins.

Why not the alternatives:

| Option | Rejected because |
|---|---|
| `VoccaUI/Usage/` | `VoccaUI` has **no** filesystem precedent — `CompletionFlagStore` is `UserDefaults`-backed and only mentions `FileManager` in a comment. A UI module owning persistence inverts the layering, and the seam lint's own doc forbids the "we already have a store here" argument (`InjectionSeamBoundaryTests.swift:1466-1476`). It is also unnecessary: the Apps tab never imports its store — `AppBootstrap.readAppStrategies()` reads and hands the UI a snapshot through a `SettingsBindings` closure (`AppBootstrap.swift:1258`, `:703-714`), and the Usage tab will do the same |
| `VoccaBootstrap` | `AppBootstrap.swift:724` already names `FileManager.default.displayName`, so rooting a seam there either fails the escape scan or forces permitting `AppBootstrap.swift`, weakening the rule |
| `VoccaInject` / `VoccaText` | Semantically wrong; neither owns instrumentation |

Small modules are normal here — `VoccaSpeech` is a module with a placeholder in it.

## In scope

- **`UsageStore` protocol in `VoccaCore`** — stdlib-only, no file I/O, mirroring
  `InjectionStrategyStore.swift`'s split exactly (that file is 67 lines of protocol + constants;
  the implementation lives entirely in its adapter module).
- **`PersistentUsageStore` actor in `VoccaUsage`** — the one file permitted to name `FileManager`,
  behind an injected filesystem seam and an injected log, following
  `PersistentInjectionStrategyStore.swift` closely.
- **The persisted format**, versioned, hand-readable, shape-only.
- **`Package.swift`** — the `VoccaUsage` library and target; `VoccaBootstrap` gains the dependency.
- **Lint updates**: `ModuleBoundaryTests.adapterModules`; a new `"usage": "VoccaUsage"` row in
  `filesPermittedToNameFileManagerIdentifiersBySeam` **and** `fileManagerSeamModuleRoots`, plus the
  hard exact-set pin at `InjectionSeamBoundaryTests.swift:1293-1310` that asserts the seam keys are
  exactly the current four.
- **`ARCHITECTURE.md:596`** — it reserves `metrics.sqlite # local-only latency/success — never
  sent`. The tree will ship `usage.json`. `CLAUDE.md` makes that doc authoritative on technical
  design, so it is amended here, not later. (JSON over SQLite: thirty day-rows is well under 10 KB,
  every other store in the tree is versioned JSON, and SQLite would add a dependency and a
  migration surface to a file that is a tally.)

## The format

```json
{ "version": 1,
  "bucketUpperBoundsMilliseconds": [25, 50, 75, 100, 150, 200, 300, 400, 600, 800,
                                    1200, 1600, 2400, 3200, 5000],
  "days": [
    { "day": "2026-09-06",
      "realWork":   { "delivered": 33, "failsafeHeld": 1, "aborted": 0, "failed": 0,
                      "lost": 0, "emptySkip": 2,
                      "deliveriesByRung": { "accessibility": 11, "clipboardPaste": 22 } },
      "onboarding": { "delivered": 0, "failsafeHeld": 0, "aborted": 0, "failed": 0,
                      "lost": 1, "emptySkip": 0, "deliveriesByRung": {} },
      "realWorkLatencyBuckets": [0, 0, 2, 9, 14, 6, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0] } ] }
```

**The bounds are written into the file, deliberately.** Bucket counts are meaningless without the
bounds that produced them: change the constant in a later release and every retained day silently
re-reads as different latencies. Recording them makes a mismatch **detectable and loud** rather
than a quiet reinterpretation. A file whose bounds differ from the running build's is not repaired
and not partially trusted — it loads empty, with one loud log.

Rung tallies are keyed by `InjectionRung`'s raw values, which its own doc calls "the persisted
spelling, so a rename is a migration, not a refactor" (`InjectionRung.swift:29`), and keyed by
string so the file stays hand-readable — the property `dictionary.json` and `cleanup-config.json`
are given in `ARCHITECTURE.md`.

`day` is `YYYY-MM-DD`. `CalendarDay`'s failable init is the parser's gate: an impossible date in a
hand-edited file yields `nil` and the row is skipped, never repaired into a plausible one.

## Out of scope

- Reading a clock or resolving "today" (`usage-wiring`).
- Folding real sessions into the window, or any write cadence (`usage-wiring`).
- Any UI (`usage-tab`).
- Migration machinery. Version 1 is the first version; a future version-2 file loads empty rather
  than being guessed at.

## Acceptance criteria (tests written first)

| # | Test | Asserts |
|---|---|---|
| C1 | A window round-trips through save and load unchanged | The format carries everything the vocabulary holds |
| C2 | A missing file loads empty, **silently** — no log | The strategy store's contract (`InjectionStrategyStore.swift:15-29`) |
| C3 | A corrupt day row is skipped with exactly one loud log, and the remaining rows load | Per-element decode, not one `JSONDecoder` pass |
| C4 | **A load never rewrites the file** — bytes are byte-identical afterwards | `testCorruptElementsAreSkippedLoudlyAndTheFileIsNeverRewritten`'s precedent |
| C5 | A whole file that is not an object, and an unknown `version`, each load empty with one loud log | Tolerance gates |
| C6 | **A file whose `bucketUpperBoundsMilliseconds` differ from the build's loads empty, loudly** | The reinterpretation trap |
| C7 | Save is an atomic temp-write-then-rename pair; a failed rename leaves the previous committed content intact | `PersistentInjectionStrategyStore.swift:255-262` |
| C8 | A stray `.tmp` file from a crash is never read | Its precedent test |
| C9 | An impossible date in a hand-edited file skips that row rather than repairing it | `CalendarDay.init?` as the gate |
| C10 | **No transcript text, and no wall-clock time, can appear in the encoded bytes** — encode a window whose sessions carried a known phrase and assert the bytes do not contain it, nor any `:` time-of-day pattern | The unit's central privacy promise (PRD M6), asserted on the artifact itself |
| C11 | At most 30 days are ever written | Retention survives the round trip |
| C12 | The path is `~/Library/Application Support/Vocca/usage.json`, with the `homeDirectoryForCurrentUser` fallback | `PersistentInjectionStrategyStore.swift:139-147` |

## Risks specific to this aspect

| Risk | Mitigation |
|---|---|
| **The new FileManager seam row turns CI red.** Adding `"usage": "VoccaUsage"` also requires editing the exact-set pin at `:1293-1310`, which asserts the keys are exactly the current four | Write the lint rows and the pin update in the same commit as the adapter, and run the full suite before assuming it is contained |
| A bounds change silently reinterprets history | C6 — the bounds live in the file and a mismatch loads empty, loudly |
| The privacy promise is asserted in prose but not on the bytes | C10 asserts it on the encoded artifact |
| A partially-written file on power loss | Atomic temp + `replaceItemAt`, C7/C8 |
| Adding a module is more disruptive than expected | `adapterModules` already exists as a category; the change is one Package.swift target, one lint set, one seam row |

## Debt this aspect creates, for `usage-wiring` to discharge

Adding a `.library` product makes `VoccaUsage` a **shipping** target, and `ZeroNetworkTests`'
`modulesRequiringCoverage` requires every shipping module to be witnessed by the zero-network
probe — `justifiedExclusions` refuses to let a shipping target be excluded
(`ZeroNetworkTests.swift:1330`). With no format yet, there is no default-configuration work in the
module to drive, so Phase 1 satisfies it with a **metatype reference**
(`PersistentUsageStore.self`) alongside the three remaining placeholder modules.

**That is bookkeeping, not proof.** A reference shows the module was reached; it does not show the
module makes no network call. The probe's other drives are written under an effect-not-reference
rule, and this entry is the exception.

**`usage-wiring` must replace it with a real witness**: once `AppBootstrap` loads a window at
launch, that load is the effect the probe should exercise. Recorded here rather than only in the
code comment beside it, because a comment asking a future slice for something is how a temporary
exception becomes permanent.

## Note

This aspect creates the first on-disk artifact of the unit. Everything before it was reversible by
deleting code; after it, a user's machine has a file. That is why C10 asserts the shape-only
promise against the actual bytes rather than against the type's documentation.
