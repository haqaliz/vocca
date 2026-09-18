# Aspect spec — `transport-prohibition`

**Boundary:** the lint that forbids any transport or subprocess identifier inside
`VoccaActions`, plus its controls.

**Sequencing:** after `audit-log` (it lints the module that aspect creates). Before `record`.

---

## Problem slice — why this exists at all

The Phase 2 dig (recorded as deviation **D2**) measured that Vocca's permanent release
blocker goes **blind** through a spawned child:

- `interposer.c:69-73` counts **loopback as NETWORK on purpose** — an MCP server on
  `127.0.0.1` over HTTP/SSE is a violation, not a local convenience. Stdio is the only
  transport the invariant permits.
- But `DYLD_INSERT_LIBRARIES` is **stripped and purged** by restricted children, so
  `/usr/bin/env node server.js`, any `/bin/sh -c` wrapper, and any Apple platform binary are
  **BLIND**. One hop launders the insertion for the entire descendant tree.

**The failure mode is a green test while a child egresses.** This aspect cannot fix that. It
makes reaching for a transport a **reviewed edit** rather than an accident, so the false
green cannot be introduced silently.

## In scope

- A prohibition lint over `VoccaActions` forbidding the identifier families:
  `URLSession*`, `NW*`, `Network`, `Process`, `posix_spawn`, `NSTask`, `system`
- The `ModelDownloaderSeamTests.swift:190` shape: an **empty-permitted-set** variant scoped
  to one family, file list asserted non-empty, each file asserted to exist
- Planted control (`:162` shape) — the detector fires on a deliberately violating sample,
  asserting the exact identifiers found
- Comment-strip control (`:180` shape) — a doc comment naming the family does not trip it,
  which is what lets the module document what it forbids
- A doc comment in the lint recording **D2** and why the prohibition exists, so the next
  reader does not delete it as redundant

## Out of scope

Any change to the interposer; any attempt to make subprocess egress visible (not solvable
here); linting modules other than `VoccaActions`.

## Notes from the dig

- **No subprocess lint family exists anywhere in the tree.** `Process(` appears exactly once
  — `Sources/VoccaASR/Models/TarballExtractor.swift:91`, deliberately off the probe's path
  and unlinted. This aspect **establishes** a family rather than amending one.
- There is currently **no lint on `Network.framework` / `NW*`** either. This closes a real
  existing gap, not just a hypothetical one.
- `TarballExtractor` must **not** be swept up — the lint is scoped to `VoccaActions`.

## Acceptance criteria (written RED first)

1. No file under `Sources/VoccaActions/` names any forbidden identifier family.
2. The permitted set is **empty**, and the assertion is not vacuous: the scanned file list is
   non-empty and each scanned file exists.
3. The planted control fires, naming the exact identifiers found in the violating sample.
4. The comment-strip control passes: a doc comment naming `URLSession` does not trip it.
5. The detector is a pure `static func` over a `String`, never re-implemented per call site.
6. Scanning nothing **throws or fails** rather than passing (the `ModeProhibitionTests`
   directory-scan framing).

## Dependencies

`audit-log` (the module must exist to be linted).

## Open question

Should the lint also cover `VoccaCore/Actions/`? Core already cannot import Foundation, so
`URLSession` is structurally impossible there — but `Process` is too, for the same reason.
Probably redundant; confirm in the plan and record the reasoning either way.
