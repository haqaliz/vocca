# Spec — store-seam

Aspect of `injection-strategy-memory` (C8, P2) · `docs/planning/injection-strategy-memory/prd.md`
Requirements: **R1** (owned here), **R9** (owned here), **S1** (owned here), **X5** (owned here)
+ **T-2**'s store-shape half (owned here; the fire-and-forget wiring is `memory-order`'s).
Depends on: `core-memory` (the `InjectionStrategy` value type must exist in
`Sources/VoccaCore/StrategyMemory/` before any of this compiles) — verify at start, stop-and-flag
if absent (the user-dictionary module-move precedent).

## Problem slice

C8's learning logic needs somewhere to put what it learns, and the house rule says where that can
live: **the protocol in `VoccaCore` (stdlib-only — `CoreBoundaryTests`), the implementations in
`VoccaInject/Memory/`** (`ARCHITECTURE.md:135`, `:260`). Nothing persists yet: `strategies.json`
(`ARCHITECTURE.md:580`) is a line in the storage layout, not a file. The store must not drag
`Data`/`JSONEncoder` into the protocol (Core imports nothing), it must be the same tolerant,
atomic shape the dictionary store established (`FileSystemDictionaryStore`), and it must extend
the FileManager seam table — the `"strategy"` row is the **fourth** seam, so the exact-set pin
(`InjectionSeamBoundaryTests.swift:1293-1304`) moves three→four, and the two-sided lint must
prove the one permitted file names `FileManager` and nothing else in `VoccaInject`'s strategy
seam does.

The slice is deliberately seam-only: the store is what `memory-order`'s recorder writes and
`apps-tab`'s reset reads, but nothing here learns, records, wires or renders.

## In scope

1. **The `InjectionStrategyStore` protocol, in `Sources/VoccaCore/StrategyMemory/`**
   (`prd.md:63` R1). Stdlib-only — the shared vocabulary's contract: `load`/`save`/`update` over
   `InjectionStrategy`-shaped values; no `Data`, no `JSONEncoder`, no `URL` in the protocol
   (the file-system seam lives with the adapter, dictionary-shaped). The bounded-store constant
   (S1) lives beside it, in the `WarmStartTargets`/`LatencyLedger.maximumRetainedRecords` shape:
   a named value in exactly one file, pinned by a single-source scan.
2. **Two implementations in `Sources/VoccaInject/Memory/`** (`prd.md:63`, `ARCHITECTURE.md:260`):
   - `EphemeralInjectionStrategyStore` — in-memory, for every headless test (`prd.md:63`);
     imports nothing but `VoccaCore`.
- `PersistentInjectionStrategyStore` — **the seam's one `FileManager`-naming file**
      (`Sources/VoccaInject/Memory/PersistentInjectionStrategyStore.swift`): real JSON at
      `~/Library/Application Support/Vocca/strategies.json` (`ARCHITECTURE.md:580` names the
      file; the PRD R9's "`strategies.json`" is that same name), the `FileSystemDictionaryStore`
      shape exactly — injected
     file-system seam, atomic temp-write→`replaceItemAt` commit (the moveItem-regression
     lesson, `FileSystemDictionaryStore.swift:60-66`), tolerant load that never throws and
     never rewrites, `.sortedKeys` encode for byte-stable files, injected `log` closure.
3. **Persistence contract** (R9): missing→empty silently; corrupt→skip + one loud log per
   skipped element, never fatal, **file bytes unchanged after load**; a save writes only the
   in-memory set the app produced (a save normalizes the file); unknown top-level version →
   loud + empty (version-tolerant, X5).
4. **The bounded store (S1)** — cap ~512 remembered apps, the `LatencyLedger` cap-512
   precedent; **refusal, never eviction** (see Isolation decisions); the refusal is a `Bool`
   answer on `update`, testable at a tiny injected capacity.
5. **The FileManager seam-lint amendment (R9's second half)** — the per-seam table gains
   `"strategy": ["Memory/PersistentInjectionStrategyStore.swift"]`, the module-root table gains
   `"strategy": "VoccaInject"`, and the exact-set pin becomes **four** shipped seams. The
   generic per-seam machinery (exactly-one-per-seam loop, two-sided pin, per-module union scan)
   covers the new row automatically — VoccaInject's union becomes journal + strategy, exactly
   the multi-seam-module case the `dictionary`/`config` pair already exercises in VoccaText.

## Out of scope

- **The learning itself** — demote-on-fail, re-probe eligibility, ordered-rungs projection,
  seeds, promotion: all `core-memory`/`memory-order`.
- **Recording in `LadderInjector`** (R8), **the memory-backed order and allowlist** (R2–R6),
  **the Apps tab and reset-learned UI** (R7), **seeding** (R5) — `memory-order`/`apps-tab`.
- **Wiring**: nothing in `AppBootstrap.configure`, `ShippingLadder.make`, or the probe report —
  `memory-order` owns composition. This aspect adds no code to `configure`, so the zero-network
  probe stays green by construction; the store's own obligation is that the absent-file path is
  **silent** (tested), the `CleanupConfigStore` precedent.
- **The fire-and-forget persist** (T-2's wiring half): the detached task the injector never
  awaits is `memory-order`'s; this aspect's share is that `update` is one atomic persist with a
  throw channel the caller's catch can see.
- **Cap on load/save**: `load` is uncapped (the file is what it is — hand-editable, same as the
  dictionary) and `save` is the deliberate wholesale write (reset-learned writes the empty set);
  the cap binds the **learning** path (`update`) only.
- **C12's per-app context opt-in** (`prd.md:144`), adaptive settle delay (`prd.md:137-139`),
  any UI, any network.

## Isolation / honesty decisions

- **The protocol is the only Core surface; the decisions stay out of it.** `update` upserts by
  the strategy's own bundle ID (the value carries its key — the contract `core-memory`'s type
  must satisfy). Whether a rung *should* be demoted or a window has *elapsed* is nowhere in this
  aspect — the store moves strategies, it does not decide about them.
- **Both implementations are actors.** The store is stateful by design: `load()` once at launch
  (the custody-chain load, `prd.md:99` T-2), then `update`/`save` mutate the held set and
  persist the **whole set** atomically. An actor is the honest Swift 6 shape for that state; the
  atomic rename means a concurrent read sees the old or the new complete file, never a partial
  one — the dictionary's concurrency argument, extended to racing updates (each persist writes
  its snapshot of the held set; the last rename wins with a complete file, and the in-memory set
  carries the other entry forward to the next persist).
- **Cap policy: loud refusal, never eviction.** The `LatencyLedger` precedent is cited both
  ways on purpose: it *evicts* (drop-oldest) and it *refuses* (duplicates, double-finalize) —
  and eviction there drops **transient in-memory records**, not durable user-value data. A
  learned strategy is the product of real dictations; silently evicting Slack's strategy because
  512 other apps were tried into would unlearn what the memory exists to remember, invisibly.
  At the cap, `update` of a **new** bundle ID returns `false` (loud to the caller; the file is
  untouched); updates of known apps always succeed. `load`/`save` are uncapped — the file is
  user-owned, and reset-learned (R7) is the user's own eviction mechanism. The refusal is
  `@discardableResult`-free and testable at a capacity of 2.
- **`update` throws on persist failure, returns `Bool` for the refusal.** Two different
  outcomes, two channels, neither silent: a failed save means the file was *not* updated while
  the held set says it was — the caller (memory-order's recorder, in its detached task) must be
  able to see and log it (the dictionary's "a failed save means the caller must know"). A cap
  refusal is *expected policy* at saturation, not an error. The ephemeral store never throws
  (nothing can fail) — the protocol allows the throw; the implementation simply has no way to.
- **The store is executed by CI, not merely linted.** `FileManager` works on a hosted runner —
  the journal/dictionary precedent: the real persistent store runs against real temp
  directories in the suite, and the lint row only proves *where* `FileManager` may be named.
- **Schema: versioned top-level, element-wise tolerant.** The file is
  `{"version": 1, "strategies": [<InjectionStrategy>, ...]}` — a version field is the honest
  mechanism for "version-tolerant" (X5): a file a future version wrote is skipped loudly by this
  build, never mis-read. The wrapper container is this aspect's own private Codable type in the
  adapter file; the elements are `core-memory`'s `InjectionStrategy`. Decode is the dictionary's
  element-wise path (`FileSystemDictionaryStore.decode(_:onInvalidElement:)`): top level via
  `JSONSerialization`, each element through its own `JSONDecoder` so one bad entry skips, not
  the file. **Content constraint:** bundle IDs + `InjectionRung` raw values + integer epoch
  seconds only — no text, no transcripts, nothing content-shaped (`prd.md:120-121`). A
  save normalizes (unknown fields are not re-emitted), the dictionary's decision
  (`spec.md:141-144` there).
- **Loudness is injected and asserted, not hoped.** The persistent store takes
  `log: @Sendable (String) -> Void` defaulting to `Logger(subsystem: "dev.vocca.Vocca",
  category: "strategy-memory")`; tests inject the shared `LogCollector` and assert exact counts.

## Acceptance criteria (tests written first)

Failing XCTests in `Tests/HarnessTests/InjectionStrategyStoreTests.swift` (both stores; the
real persistent store against real temp dirs; the shared `LogCollector`), plus the seam-lint
edit in `InjectionSeamBoundaryTests.swift`:

- S1 **`update` is an atomic temp-write→rename pair** — the `RecordingInjectionStrategyFileSystem`
  double (real temp dir) records exactly `[tempWrite, rename]`; the committed file decodes; no
  `.tmp` remains.
- S2 **A failed `update` after the temp write leaves the previous committed content** — the torn
  half (`FailingRenameInjectionStrategyFileSystem`): `update` v1 through the real file system,
  then a rename-throwing double; the second `update` **throws**; the committed file is v1's
  bytes, never partial; the leftover `.tmp` is never readable by a fresh store.
- S3 **`save` is the same atomic pair** — wholesale replace, `.sortedKeys` byte-stable: save →
  read bytes → save again → identical bytes.
- S4 **Missing file loads empty silently** — absent directory → `load()` returns `[]`, no
  throw, injected log collector empty (the zero-network/silent-launch contract).
- S5 **Corrupt elements are skipped loudly and the file is never rewritten** — a real file
  holding valid + invalid elements loads the valid ones, emits exactly one captured log per
  skipped element, and the file's bytes are **byte-identical** afterwards.
- S6 **A whole file that is not an object loads empty with one loud log** — bytes unchanged.
- S7 **An unknown version loads empty with one loud log** — a `"version": 2` file (or a missing
  version) → `[]`, one log, bytes unchanged (version-tolerant, X5).
- S8 **A stray `.tmp` from a crash is never read** — planted temp beside a committed file →
  committed content only.
- S9 **Round trip and byte stability through the real store** — two apps updated, a fresh store
  over the same directory loads both with rungs and timestamps intact.
- S10 **The cap refuses a new app and keeps known apps flowing** — ephemeral store at capacity
  2: two new apps accepted; a third **new** app → `update` returns `false` and is not held;
  `update` of a known app → `true`. (`@discardableResult`-free: the ignored `Bool` is a
  compiler warning in Core-derived code — the `LatencyLedger` refusal discipline.)
- S11 **A cap refusal is not a persist** — persistent store at capacity: refused `update`
  leaves the file bytes untouched.
- S12 **`save` replaces the whole set and bypasses the cap** — a deliberate write of more
  entries than the capacity into an at-cap store succeeds and round-trips (reset-learned and
  future editing paths).
- S13 **`update` throws when the directory cannot be created** — `RefusingCreateDirectory`
  double → throw (the journal's refused-write contract).
- S14 **Ephemeral semantics mirror the protocol end to end** — load/update/save/reset
  (`save([])` clears) headless, no disk.
- S15 **The FileManager seam table names exactly the four shipped seams** — the exact-set pin,
  renamed `testTheFileManagerSeamTableNamesExactlyTheFourShippedSeams`, set
  `["journal", "dictionary", "config", "strategy"]`.
- S16 **The strategy seam is one file, two-sided** — the existing generic pins over the new
  row: exactly one file per seam; the permitted file names `FileManager`; nothing else in
  `VoccaInject`'s strategy seam (or the module) does — the per-module union scan proves it, and
  `EphemeralInjectionStrategyStore.swift` names no `FileManager`.
- S17 **Boundary discipline** — full suite green under the floor after every commit; the aspect
  **ends by raising the floor** in `Scripts/test-with-floor.sh` to the new count; no new
  dependencies; strict concurrency clean; Apache headers (`LicenseHeaderTests`);
  `CoreBoundaryTests`/`ModuleBoundaryTests` pass **unedited**.

## Dependencies / sequencing

- **`core-memory` must have landed.** This aspect's tests instantiate `InjectionStrategy`
  (`Sources/VoccaCore/StrategyMemory/`). **Verify at start** (`InjectionStrategy.swift` exists
  with the bundle-ID key and the store's contract); if absent, stop and flag the sequencing
  break — do not build the protocol against a guessed shape (the user-dictionary module-move
  precedent).
- The protocol's contract with `core-memory`'s type, pinned here: `InjectionStrategy` is
  `Sendable`, `Equatable`, `Codable`; exposes its bundle ID as the store's key; carries only
  rung identifiers and integer epoch timestamps (no `Foundation` time types, no text).
- **The seam-lint machinery is already per-seam module-rooted** (the user-dictionary aspect's
  amendment) — the `"strategy"` row is a table edit, not new machinery.
- Runs before `memory-order` (which consumes both this protocol and the stores); the
  `apps-tab` and `matrix-smoke` aspects follow the unit's order.
- Precedents to mirror: `FileSystemDictionaryStore.swift` (atomic write, tolerant load, seam
  shape, `replaceItemAt` lesson), `DictionaryStoreTests.swift` (recorded pair, failing rename,
  refusing create, `LogCollector`), `InjectionSeamBoundaryTests.swift:1151-1166, 1293-1304`
  (per-seam table, roots, exact-set pin), `LatencyLedger.swift:50` (cap 512, refusal shape).

## Open questions / risks

- **`ARCHITECTURE.md:580` names the file `strategies.json`.** Resolved: the file ships as
  `strategies.json`, the doc's name — no docs amendment, and consistent with the siblings
  (`cleanup-config.json`, `dictionary.json`) that already follow the same layout table.
- **`ARCHITECTURE.md:260` names the implementations `PersistentStore`/`EphemeralStore`; the
  shared unit vocabulary fixes `PersistentInjectionStrategyStore`/`EphemeralInjectionStrategyStore`.**
  Same docs-sync treatment; the full names are the code names.
- **The exact timestamp fields of `InjectionStrategy` are core-memory's to name.** This
  aspect's constraint: integer epoch seconds, no text; the schema's element shape follows
  whatever the type is Codable over. If core-memory ships a field set that violates the
  constraint (a wall clock, a transcript), stop and flag — the schema is the privacy boundary.
- **Seeds (R5) count toward the cap once they are in the file** — but the cap binds only
  `update`-time insertions of *new* bundle IDs, so a seeded file loads uncapped. Whether seeds
  should instead be excluded from the remembered count is `memory-order`'s call; the store's
  semantics are pinned here and documented for it.
- **`update`'s throw channel** depends on `memory-order`'s detached-task recorder catching and
  logging it (T-2's wiring half). If that aspect prefers a non-throwing recorder, revisit here
  — the throw is the honest surface for "the file was not updated".