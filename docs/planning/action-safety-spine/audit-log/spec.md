# Aspect spec — `audit-log`

**Boundary:** the new `VoccaActions` module and the append-only audit store, its byte-pin,
and its permit-table rows.

**Sequencing:** after `action-seam`. Parallel with `confirmation-gate`.
`transport-prohibition` depends on this (it lints the module this aspect creates).

---

## Problem slice

`CLAUDE.md:327` and `README.md:205` both promise the action layer is "gated on confirmation
**and an audit log**". C13's acceptance: every executed action must appear in it, asserted
by reconstruction.

## In scope

- The `VoccaActions` target: `Package.swift` product + target stanza
  (`dependencies: ["VoccaCore"]` **exactly** — asserted by equality via
  `swift package dump-package`), `swiftSettings: [.swiftLanguageMode(.v6)]`
- `ModuleBoundaryTests`: add `"VoccaActions"` to `adapterModules` with the required
  doc-comment paragraph naming the seam it implements and the lints confining it
- `ActionAuditEntry` (PRD §5) and the append-only store, following
  `FileSystemJournalStore`: **one file per event**, zero-padded 8-digit ordinal, `.tmp`
  mid-commit, `replaceItemAt` rename-over, idempotent removal
- The `*FileSystem` protocol seam + one `FileManager` implementation + the deciding actor —
  the three-part store idiom, verbatim from `PersistentConsentStore`
- Tolerant decode: `static`, pure, **never throws**, injected `onInvalidElement` callback
- Cap with oldest-first ordinal eviction; clearable
- Permit-table rows for the new `FileManager` surface
  (`InjectionSeamBoundaryTests.swift:1186` and its module-root map at `:1201`)

## Out of scope

Wiring into `AppBootstrap` (**explicitly** — this is what keeps the G5 pin untouched); any
UI; persisted enablement (N1); any transport.

## Hard constraints

- **The module directory and the `Package.swift` target must land in the SAME commit** —
  `VoccaContextTargetTests.testTheModuleDirectoryExistsWithSwiftFiles` and the manifest pin
  fail together otherwise (the C12 precedent).
- Nothing in this repo appends to a file. Append-only is **by directory**, not by file mode.
- The instant is monotonic `Duration` components, never a wall clock.

## Acceptance criteria (written RED first)

1. **Reconstruction.** A sequence of executed actions through the M10 stub is recoverable
   from the store in order, with decision and outcome intact. Domain non-empty.
2. Ordinals are monotonic and survive a reload — the counter is rebuilt from entries on disk
   (the journal precedent), not held only in memory.
3. A `.tmp` file mid-commit is neither readable nor listable as an entry.
4. Tolerant decode: a corrupt entry is skipped with the callback fired; the store still
   loads. It never throws.
5. The cap evicts oldest-first by ordinal; clearing empties the directory.
6. **The byte-level pin** (`PersistentConsentStoreTests.swift:469` pattern): exact key-set
   equality on the encoded entry, and **no** `HH:MM`, ISO-8601, Zulu, or epoch-shaped
   values — while permitting `summary`. Includes the vacuity guards (non-empty entry,
   assertions that the fields under test are genuinely populated).
7. `summary` is bounded at 1 KB UTF-8 in exactly one place, asserted at the boundary and
   one byte over it.
8. Module boundary rule 3: `VoccaActions`' imports ∩ Vocca module names − `VoccaCore` = ∅.

## Dependencies

`action-seam`.

## Open questions

- Directory name under Application Support — `actions/` beside `recovery/`, or
  `action-audit/`? Pick one in the plan and pin it.
- Whether eviction is enforced on write or on load. Prefer on write, so the cap is a fact
  about the directory rather than a fact about a reader.
