# Spec — user-dictionary

Aspect of `deterministic-cleanup` (C5) · `docs/planning/deterministic-cleanup/prd.md`
Requirements: **M3** (owned here) + **S1** (owned by `rules-engine` task 1; verified here) + **S2**
(owned here).
Depends on: `cleanup-seam` (the `ReplacementRule` type) and `rules-engine` task 1 (the module
move) — both predecessors per the PRD's rough shape (`prd.md:234-236`).

## Problem slice

The P0 loop injects raw ASR text; P1's cleanup applies user-dictionary rules last, in declared
order (`prd.md:84-88`, `ARCHITECTURE.md:511`). The edit surface is **plain JSON in Application
Support** — hand-editable and version-controllable (`ARCHITECTURE.md:513`), the one way the
people who need a dictionary most (developers, clinicians, lawyers) will ever maintain it,
because the settings UI is deferred. Nothing stores it yet: `VoccaText` is a leaf placeholder
(`Sources/VoccaText/Placeholder.swift`, the module's only file). The store must not drag the
file system into `VoccaCore` (Core imports nothing), and it must not break the seam doctrine:
`FileManager` is a seam family with exactly one permitted file per seam
(`InjectionSeamBoundaryTests.swift:910-912`), and the dictionary store is a second
`FileManager`-naming file — the lint row must be extended, not skirted (S2).

## In scope

1. **`ReplacementRule` semantics as data.** Declared order **is** application order
   (`prd.md:180-181`, `CAPABILITY_ROADMAP.md:120`); `caseSensitive` and `wordBoundary` are the
   two controls; the JSON round-trip preserves order and flags. The type itself lives in
   `VoccaCore` (cleanup-seam); this aspect pins the semantics and the Codable contract over it,
   from VoccaText, in headless tests.
2. **The `dictionary.json` store — `Sources/VoccaText/Dictionary/`.** One thin adapter in the
   journal-store shape (`FileSystemJournalStore`): **load** from
   `~/Library/Application Support/Vocca/dictionary.json` (`ARCHITECTURE.md:549`); a missing file
   is an empty dictionary, not an error; invalid entries are **skipped with a loud local log** —
   never fatal, and a failed parse never rewrites the user's file. **Save** is atomic
   temp-write-then-rename (the journal precedent, `FileSystemJournalStore.swift:69-72`), so a
   crash mid-save can never leave a readable partial file. Plain JSON array — no schema beyond
   the array shape.
3. **The FileManager seam lint row gains the dictionary seam (S2).** The per-seam table
   (`InjectionSeamBoundaryTests.swift:910-912`) gains one entry for the dictionary store file —
   the per-family-table pattern the file itself established: one file per seam, ever, pinned
   two-sided (the permitted file names the family; nothing else in its module does). Because
   the table's paths are module-relative and the existing scan root is hardcoded to
   `Sources/VoccaInject` (:950), the table (or its scan) must become **per-seam module-rooted**:
   the journal row keeps scanning `VoccaInject`, the dictionary row scans `VoccaText`. The
   existing generic machinery — the exactly-one-per-seam loop (:989-998), the two-sided pin
   (:1001+), the planted-identifier detection (:929) — covers the new row automatically.
4. **Module-move verification (S1).** The move is `rules-engine`'s task 1; this aspect verifies
   it at start (see Dependencies) and does no planning of it.

## Out of scope

- The settings UI and the Cleanup tab (`prd.md:216-218`); JSON is the first-class edit surface.
- Rule **application** (matching, chained replacement) — that is `rules-engine` (M2).
- JSON schema versioning beyond tolerant loading — no version field, no migrations; a plain
  array with tolerant reads is the whole contract.
- Sync/cloud of any kind — local file, zero network, hand-editable and version-controllable
  *by the user's own tooling* (git, dotfiles).
- The module move itself (rules-engine task 1), the probe witness, pipeline wiring (M7,
  pipeline-wiring), and the M8 floor raise (pipeline-wiring owns the floor constant; tests
  added here count toward it).

## Isolation / honesty decisions

- **Persistence lives in VoccaText; Core is import-free.** The store is a thin adapter with
  zero decisions — directory creation, temp-write, rename, read — exactly the
  `FileSystemJournalStore` shape (`FileSystemJournalStore.swift:40-73`). Every decision (which
  entries are valid, what to skip, order) is above the file, in headless tests.
- **The store is executed by CI, not merely linted.** `FileManager` works on a hosted runner —
  the journal precedent (`RecoveryJournalTests.swift:26-28`): a linted-but-never-run adapter is
  not an adapter shown to work. The real store runs against a real temp directory in the suite.
- **Corruption tolerance policy.** A corrupt entry (bad JSON element, wrong types, missing
  field) is skipped and the rest loads; the load is **never fatal**; the user's file is **never
  rewritten by a failed parse** — save only ever writes an in-memory state the app itself
  produced, so a crash or a hand-edit error can never clobber the user's edit surface. The
  skip is loud: `Logger(subsystem: "dev.vocca.Vocca", category: "dictionary")` (the
  `AppBootstrap.swift:318` precedent), injectable in tests so the loudness is asserted.
- **Atomic writes are the durability contract.** Save is exactly two events — write
  `<name>.tmp`, rename over `dictionary.json` — the protocol the journal pins as a recorded
  pair (`RecoveryJournalTests.swift:44-58`) and this store mirrors: a crash between the two
  leaves a `.tmp` that load never reads, never a partial `dictionary.json`.

## Acceptance criteria (tests written first)

Failing XCTests in `Tests/HarnessTests/` — `UserDictionaryTests.swift` (semantics + round-trip)
and `DictionaryStoreTests.swift` (the real store against a temp directory, plus the seam lint
edits):

- B1 **Declared order is application order.** Rules applied in declared order; a later rule
  whose match overlaps an earlier rule's output region re-replaces that region (chained
  application) — e.g. `[("mcp" → "MCP"), ("mcp server" → "MCP server")]` and the reverse,
  asserted both ways.
- B2 **`caseSensitive` off** matches "kawa", "Kawa" and "KAWA"; **on** matches only the exact
  casing the rule declares.
- B3 **`wordBoundary` on** prevents "cat" from matching inside "catalog" but matches "cat"
  bounded by whitespace or punctuation ("cat." and "the cat,"); **off** matches inside words.
- B4 **JSON round-trip** through the store's encoder/decoder preserves rule order and both
  flags exactly (encode → decode → identical array).
- B5 **Corrupt entries are skipped, never fatal.** A file containing a valid element, a
  wrong-typed element (`"source": 42`), a missing-field element, and a non-JSON fragment loads
  the valid one, emits exactly one loud log per skipped entry (captured via the injected
  logger), and does not throw.
- B6 **Atomic save.** The store's save is the temp-write→rename pair (recorded, journal-style
  — `RecoveryJournalTests.swift:44-58`); with an injected failure after the temp write, the
  committed `dictionary.json` is the previous content (or absent), never partial, and the
  leftover `.tmp` is never readable as a dictionary.
- B7 **The FileManager seam row (S2).** `filesPermittedToNameFileManagerIdentifiersBySeam`
  (`InjectionSeamBoundaryTests.swift:910-912`) has exactly two entries — `journal` →
  `Journal/FileSystemJournalStore.swift`, `dictionary` → `Dictionary/<store>.swift` — the
  exactly-one-per-seam loop and the two-sided pin both pass over the new row, the scan covers
  both module roots, and a planted `FileManager` identifier in any other `VoccaText` file is
  detected.
- B8 **Missing file is an empty dictionary** — load with no file present returns `[]`, no
  error, no log.
- B9 **Boundary discipline.** Full suite green under the floor after every commit; no new
  dependencies; strict concurrency clean (Swift 6 mode); the new files carry the Apache header
  (`LicenseHeaderTests`).

## Dependencies / sequencing

- **`cleanup-seam`** — the `ReplacementRule` type in `VoccaCore` (source phrase/word,
  replacement, `caseSensitive: Bool`, `wordBoundary: Bool`, ordered — `prd.md:179-181`),
  Codable, plus `CleanupContext.dictionary: [ReplacementRule]` (`prd.md:177`). Not yet merged
  in this worktree (no `ReplacementRule` in `Sources/VoccaCore/` today).
- **`rules-engine` task 1 — the module move: already done by rules-engine.** By the time this
  aspect runs, `VoccaText` is in `adapterModules` (`ModuleBoundaryTests.swift:72-74` → `:99-101`)
  and its target declares `dependencies: ["VoccaCore"]` (`Package.swift:90-94`). **Verify both
  at start; if either is absent, stop and flag the sequencing break** — the store cannot import
  Core's types without it. This aspect does no planning of the move.
- Runs in parallel with the rest of `rules-engine` after the seam (the PRD's rough shape,
  `prd.md:234-236`); nothing here depends on the rules function itself.
- Precedent files to mirror: `FileSystemJournalStore.swift` (atomic write, path resolution,
  tolerant load), `RecoveryJournalTests.swift` (recorded-pair atomicity, real-dir execution),
  `InjectionSeamBoundaryTests.swift` (per-family seam table).

## Open questions / risks

- **Application Support path resolution.** Adopt the journal's absolute-path contract: the
  store takes an injected directory `URL` (tests pass temp dirs); the default initializer
  resolves Application Support with the journal's defensive fallback
  (`FileSystemJournalStore.swift:54-60`), pointed at `Vocca/dictionary.json` (`ARCHITECTURE.md:549`).
- **Must save preserve unknown fields?** Decode is tolerant on read (skip unknown keys —
  stock `JSONDecoder` behavior — and skip invalid entries). Encode writes only known fields;
  save rewrites the array from in-memory rules. Because the file is user-owned and
  version-controlled, re-emitting unknown fields would be pretend-fidelity — decide no, and
  document that a save normalizes the file.
- **Concurrent load/save.** Single process, one writer: load once at session start (the rules
  engine reads the dictionary via `CleanupContext`); decide whether the store is an actor or
  serialized by the caller before any save path exists. No multi-process story today.
- **Case comparison is deliberately locale-independent** — simple Unicode case folding
  (lowercased), not `localizedStandard*`: deterministic rules must not vary with the user's
  locale. Same discipline for the word-boundary set: an explicit, small boundary definition
  (whitespace, punctuation, start/end), table-tested, not `CharacterSet` heuristics that drift.
- **The store's logger is injectable** so B5's "loud" is asserted headless, not hoped.
