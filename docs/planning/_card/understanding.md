# Understanding — `action-safety-spine` (C13 slice 1)

Written after the Phase 2 dig (four parallel agents over the seam conventions, the
zero-network invariant, the persistence precedents, and the doc reservations).
This is the note the PRD interview starts from. Nothing here is a decision.

---

## 1. What the work is really asking

Build the **safety spine** of C13 (Actions and MCP, P4) — the part C13's own entry says
ships first: *"it ships gated on safety rather than on capability."*

The docs already commit to the shape in two places, so this is not an invention:

- `CLAUDE.md:327` — "**Actions:** MCP for the action/agent layer, gated on confirmation +
  a local audit log."
- `README.md:205` — "| Actions | MCP | The action layer, gated on confirmation and an audit log |"

`ARCHITECTURE.md` reserves the slot on paper and nothing more:

```
  VoccaActions/              # P4 — ActionProvider, MCP client
```

and the seam table's last row:

```
| Actions | `ActionProvider` | `MCPProvider`, `ShellProvider` | No |
```

**`grep -rn "ActionProvider\|VoccaActions\|MCP" Sources/ Package.swift` returns zero hits.**
Entirely greenfield; there is no legacy to reconcile.

---

## 2. The finding that decides the architecture

### Loopback is not an exemption

`Sources/CVoccaNetworkInterposer/interposer.c:69-73` counts **loopback as NETWORK on
purpose** — the opt-in local LLM lives on loopback, and the invariant exists to catch it
becoming reachable by default. The shim interposes **eight** entry points, not just
`connect(2)`: `connect`, `connectx` (the path URLSession and Network.framework actually
take), `sendto`, `sendmsg`, `getaddrinfo`, `getnameinfo`, `gethostbyname`, `socket`.

> An MCP server on `127.0.0.1` over HTTP/SSE is a **zero-network violation**, not a local
> convenience. Stdio is not the *preferable* transport; it is the only transport the
> invariant permits at all.

### But a stdio child is BLIND to the interposer — and that is worse

The interposer is delivered by `DYLD_INSERT_LIBRARIES` into a spawned child. Measured
empirically on this machine (the agent built a minimal `connect`-only interposer with the
same `__DATA,__interpose` technique plus a `LOADED\t<pid>` constructor, and a `posix_spawn`
parent passing `environ` unchanged — what Foundation's `Process` does):

| Spawn shape | Interposer sees it? |
|---|---|
| Locally built ad-hoc binary, direct absolute-path spawn | **SEEN** |
| `node` (nvm, Developer ID, hardened runtime, *carries* `com.apple.security.cs.allow-dyld-environment-variables`) | **SEEN** |
| `/usr/bin/python3`, `/usr/bin/curl`, `/usr/bin/tar` | **BLIND** |
| `/bin/sh -c ./child` (same child that was seen directly) | **BLIND** |
| `./server.js` with `#!/usr/bin/env node` | **BLIND** |

Three rules compose: the env var *is* inherited; a **restricted** child (Apple platform
binary, or hardened-runtime without the dyld-env entitlement) ignores it; and — the killer —
a restricted child **purges `DYLD_*` from the environment it passes on**, so one hop through
any Apple platform binary launders the insertion permanently for the entire descendant tree.

**Therefore `/usr/bin/env node some-server.js` — the single most common way an MCP server is
launched — is blind. Any shell wrapper is blind.**

> The danger is not that stdio MCP *fails* the zero-network test. It is that the test stays
> **green while a child egresses**. That is a false green in the repository's permanent
> release blocker.

**Consequence for this slice:** the safety spine must **spawn nothing**. And it should ship
the lint that makes a future transport a deliberate, reviewed act rather than an accident.

---

## 3. What the tree already gives us

### The store idiom (three parts, repeated verbatim)

`PersistentConsentStore`, `PersistentUsageStore`, `PersistentInjectionStrategyStore` are the
same file shape: a `*FileSystem` protocol seam (5-6 ops, no decisions), one `FileManager`
implementation, and an actor that decides. `persist()` is copy-paste identical: create
directory → encode with `.sortedKeys` → temp-write `<name>.json.tmp` → `replaceItemAt`
rename-over → throw on any failure so the caller knows the file was not updated. Decode is
`static`, pure, **never throws**, and takes an injected `onInvalidElement` callback so
"fails loudly" is asserted rather than hoped.

### Append-only already has a shape — and it is not append I/O

**Nothing in this repo appends to a file.** Every writer is whole-file temp-write→rename.
But `FileSystemJournalStore` (`Sources/VoccaInject/Journal/`) writes **one file per event**,
named by a zero-padded 8-digit ordinal (`00000001.json`) so lexicographic order *is* numeric
order, with a `.tmp` suffix mid-commit that is "never readable, never listable," and
idempotent removal. Append-only-by-directory is the established shape.

### Content and time on disk are already precedented

An early framing of this unit — "the audit log would be the first content-bearing,
time-bearing file in Vocca" — **is false**, and correcting it shrinks the problem.
`JournalEntry` (`Sources/VoccaInject/Journal/JournalStore.swift:32`) already persists:

- `text: String` — *"The undelivered text, exactly as the ladder received it — never rewritten"* (whole transcripts)
- `targetAppName: String?`
- `capturedAtSeconds` / `capturedAtAttoseconds` — the instant as **monotonic `Duration`
  components, never a wall clock**, because *"a wall-clock reading would lie across an NTP
  step or a daylight-saving change."*

That is precisely how an entry gets ordering and elapsed-time without a timestamp.

### The byte-level pins are file-scoped, not global

Exactly two exist — `PersistentConsentStoreTests.swift:469` and
`PersistentUsageStoreTests.swift:390`. Each asserts on encoder output that the file carries
no free text, no `HH:MM`, no ISO-8601, no Zulu suffix, no epoch-looking integer, **and** an
exact key-set equality that "fails on the day" anyone adds a field. Rationale: *"anything
finer than a bundle ID reconstructs when a user granted what."*

They bind their own two files. They do not forbid an audit log — but the audit log must
answer to their *reasoning*, and the journal shows how.

### Prohibition lint machinery exists and fits

`ModelDownloaderSeamTests.swift:72` holds a permitted-file set plus a forbidden identifier
prefix list, walks `Sources/`, strips comments via `SwiftSourceScanner.stripComments`, and
regex-matches the prefix family so `URLSessionConfiguration` is covered by construction. It
asserts **both directions** — no unlisted file names it, *and* every permitted file still
does — because a one-sided check passes vacuously once the implementation moves. A planted
control (`:162`) runs the detector against a deliberately violating sample and requires a
hit; a comment control (`:180`) proves doc comments don't trip it. `:190` is an
**empty-permitted-set** variant scoped to one family, with the file list asserted non-empty
and each file asserted to exist so a rename cannot make it vacuous — exactly the shape for
"no file in `VoccaActions` may name a transport."

**Caveat: there is no lint on `Network.framework`/`NW*` and none on `Process` today.** This
unit would be adding both — closing a real existing gap.

### The one existing subprocess

`TarballExtractor.swift:91` spawns `/usr/bin/tar`, deliberately kept off the probe's path
with a comment saying so. Precedent for "a subprocess the probe does not reach" — and, per
§2, `/usr/bin/tar` is one of the **blind** cases.

### BYOK is the model for a sanctioned-egress provider

Not an exception — *unreachable*. `rules` is the default; `BYOKCleanupProvider` is
constructed at exactly one site (`CleanupResolver.swift:239`) behind a `case .byok:` needing
a persisted config block and a dialable endpoint, so the default-configuration probe never
reaches it. Its socket lives in a lint-permitted transport file, it declares
`requiresNetwork = true` rather than inheriting the offline default, and that flag folds
once at launch into a structurally non-dismissable egress badge.

---

### `VoccaCore` imports nothing — not even Foundation

`CoreBoundaryTests.swift:116` enforces an **empty** import allow-list for `VoccaCore`. The
`ActionProvider` protocol and its vocabulary must therefore be Foundation-free: no `Data`,
no `URL`, no `Date`. This is a hard constraint on the seam's type design, and it is a second
reason the audit log's instant must be a monotonic `Duration` rather than a timestamp.

The division follows from it: `VoccaCore/Actions/` owns the protocol, the plain-data
vocabulary, the pure gate logic and the trivial default; `VoccaActions/` owns the
system-touching conformances (the audit-log store, and later `MCPProvider` / `ShellProvider`)
and imports `VoccaCore` and no other Vocca module.

### The G5 pin is NOT tripped by an unwired unit

The pin lives in `TurnTakingComposedAcceptanceTests.swift:311-347` and hashes exactly three
paths: `SessionMachine.swift`, `DictationPipeline.swift`, `AppBootstrap.swift`. A unit that
adds a new module, new sources, new tests and `Package.swift` entries **without modifying
`AppBootstrap.swift` leaves all three digests intact and never touches the pin.** C11 and C12
each re-anchored only in their wiring aspect. Keeping the safety spine unwired defers the
re-anchor to a later unit entirely — a real argument for machinery-only scope.

### Permit files are test constants, and no subprocess family exists

Mechanically a `private static let … : [String: Set<String>]` **inside a test file** — seam
name → the one source path permitted to name a system-API identifier family. No file on
disk. Doctrine (`InjectionSeamBoundaryTests.swift:75`): *a decision that names the system is
a decision CI cannot reach.* File I/O needs rows in both `:1186` and `:1201`. **Subprocesses
have no family at all** — `Process(` appears once tree-wide, unlinted. A `ShellProvider`
would establish a new family rather than amend one.

### The two-implementation doctrine is doctrine only

**No test enforces it.** A recorded `PENDING` row is therefore viable without fighting CI —
the `ParakeetEOU` Branch B precedent.

### PRODUCT_SPEC says nothing about actions

No confirmation UI, no action surface, no widget action state; "C13" does not appear in the
file. There is no copy to honor and none to contradict — but also no design to inherit.

> **Doc drift noted:** `docs/planning/dual-mode/prd.md:205` cites `PRODUCT_SPEC.md:379` as
> the deferred reply-text rendering. Line 379 is now a §9 Sound table row
> (`| Delivered | softer, higher tick |`). The citation has drifted; the deferral itself
> still stands, the line number does not.

---

## 4. Conventions this unit must follow

- **RED-first commit sequence**, per C12: tests against a module that does not exist, then
  the target. Module directory and the `Package.swift` target land in the *same* commit.
- `Package.swift` target deps are asserted by **equality, not containment**.
  `swiftSettings: [.swiftLanguageMode(.v6)]` on every target, no exceptions.
- CI runs three jobs under **strict concurrency where any warning fails**.
- Floor at `Scripts/test-with-floor.sh:1783` (`MINIMUM_EXECUTED_TESTS=2475`), ratcheted in
  its own commit with a ledger comment paragraph.
- The `ARCHITECTURE.md` reservation comment becomes
  `# P4 — ActionProvider — SHIPPED (<unit-slug>, <date>):` + indented lines naming what is
  actually in the directory. A wrong reservation is annotated, never deleted.
- A seam-table row must declare ≥2 named implementations, or `PENDING` **with a reason**
  (the `ParakeetEOU` Branch B precedent).
- Baseline verified: `Scripts/test-with-floor.sh` exits 0 in this worktree.

---

## 5. Open questions for the PRD interview

**Q1 — The two-implementation doctrine vs. "no real tool execution."**
Guardrail 7: *"A seam with one implementation is not a seam; it's an assertion."* The
reserved row names `MCPProvider` and `ShellProvider`. But this slice is explicitly
*no MCP wire, no real execution* — and `ShellProvider` is the highest-blast-radius component
in the roadmap. So what ships behind `ActionProvider` here? Candidates: a `NullActionProvider`
(shipped default, exposes zero tools, refuses everything) plus something real-but-safe; or a
recorded `PENDING` row with a reason, per the `ParakeetEOU` precedent. **This is the biggest
open scope question.**

**Q2 — Audit log retention and payload bound.**
The recovery journal holds content *evictably* (it is a recovery buffer, purged on delivery).
An audit log exists to be *retained* for reconstruction, and its payload is tool arguments
that may carry arbitrary user text. Whole arguments, or bounded/shape-only? What retention
cap, and is it clearable? Does it get a byte-pin of its own that forbids everything except
the named fields?

**Q3 — Does the spine ship a user-visible surface at all?**
C12 shipped seam + wiring + UI in one unit. C10 shipped machinery with *no* surface. A
confirmation gate is inherently user-visible, but there is nothing to confirm until a real
provider exists. Machinery-only, or a surface?

**Q4 — Is the transport prohibition lint in scope?**
Given §2, the strongest structural guard is a lint forbidding `URLSession`, `NW*`,
`Network`, and `Process` inside `VoccaActions`, so a transport cannot be added without a
reviewed edit. Argument for: it converts the blind-spot into a guard *before* the MCP client
exists. Argument against: it is not in C13's stated acceptance.

**Q5 — How is the blind-spot recorded?**
It cannot be fixed by this unit and must not be silently inherited by the next. A recorded
deviation (the `D1` precedent) naming the false-green risk, so the MCP slice starts from it?
