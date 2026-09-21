# Spec: enablement-store (persisted per-tool enablement + server config)

> Aspect of `action-surface-wiring` (C13 slice 5). Source: PRD R1 + R4, N1's deferral
> (`action-safety-spine/prd.md:295-297`), the `PersistentConsentStore` shape precedent.

## Problem slice

Slice 1 deferred persisted per-tool enablement to "the slice that introduces real tools to
enable". Real tools exist (`MCPProvider`, `AuditActionProvider`); nothing persists
enablement or server configuration. Without it, M7's default-off is forgettable every
launch and a server configuration cannot exist at all.

## In scope

- **`ActionConfigStore`** (actor, `VoccaActions/Config/`): one byte-pinned JSON file
  `action-config.json` under `<applicationSupport>/Vocca/`, holding two sections:
  - `servers`: `[{id, name, executablePath, arguments}]` — `executablePath` is absolute
    (the `StdioMCPTransport.Configuration` contract; no PATH lookup). Cap: 8 servers.
  - `enablement`: `[{providerID, toolID}]` rows — the persisted form of `ActionEnablement`
    (membership by whole `ActionInvocation`; **no arguments ever**). Cap: 512 rows (the
    consent-store cap).
- Tolerant decode: a corrupt/unreadable file decodes to an **empty config** with a loud
  log — never a throw at load (the audit store's `load()` precedent).
- Byte-pin: the encoder emits exactly the named fields; unknown keys in a decoded file are
  refused (the `ActionAuditEntry` decode precedent); a test asserts no transcript text,
  sentence, or raw arguments can reach the file.
- Atomic writes (tmp + rename-over, the audit store's commit precedent).
- FileManager behind a seam (the `ActionAuditFileSystem` shape; a dedicated
  `ActionConfigFileSystem` protocol — do not widen the audit seam).
- VoccaActions dependency stays exactly `["VoccaCore"]`; the store's own file-system seam
  is the only `FileManager`-naming surface in the module (per-seam permit table precedent).
- **`MCPServerConfiguration`** value type (name, executablePath, arguments; stable id).
- Enablement rows are tolerant of stale tool ids (a tool a server no longer lists keeps its
  row; decode stays valid).

## Out of scope

- Discovery/spawning (the Actions-tab aspect owns the "Discover tools" action).
- Any UI. The store is consumed by the wiring and the tab via closures.
- `ShellProvider`, intent layer, argument building.

## Acceptance (tests written first)

1. Round trip: save servers + enablement → reload → byte-identical semantics; enablement
   rows map 1:1 to `ActionEnablement` membership; **absent is off** (a row never present
   means disabled).
2. Tolerant decode: a garbage file decodes to empty (loud); a file with an unknown key is
   refused per the byte-pin; the file never throws on load.
3. Byte-pin: only the named fields reach disk (assert against encoded bytes with a
   distinctive control string absent); no sentence/arguments can reach the file.
4. Atomicity: a torn write (simulated via the seam) never yields a partially-committed
   file the store would load; commit is tmp + rename-over.
5. Caps enforced: >8 servers refused (loud); >512 enablement rows refused (loud).
6. Persistence across instances: two store instances over the same directory see the same
   config.
7. The store reaches no network name — the zero-network probe drives it (wiring aspect
   owns the probe line; this aspect owns the drive's store round trip).

## Dependencies & sequencing

- Needs nothing from this slice; builds on the audit store's seam/atomicity precedents.
- Run after `sentence-binding` only by convention (independent).