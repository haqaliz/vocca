# Spec — cleanup-config

Aspect of `llm-cleanup` (C6) · `docs/planning/llm-cleanup/prd.md`
Requirements: **M7** (owned here).
Depends on: `ollama-provider`, `byok-provider`, `cleanup-chain` (the resolver builds them) —
the config *types* and *store* half is provider-independent and may land earlier.

## Problem slice

Both LLM rungs are opt-in, off by default, never silently re-enabled (`ROADMAP.md:131`), and
the Cleanup tab ships with the deferred settings surface — so the opt-in mechanism for this
unit is a hand-edited JSON file in Application Support (the `dictionary.json` precedent,
`PRODUCT_SPEC.md:304`), read **once at launch** and resolved into exactly one provider (the
`DictationEngineResolver` resolve-once shape, `DictationEngineResolver.swift:50-149`). The
repo has zero persistence today (no `UserDefaults`/`AppStorage` anywhere) — this aspect is the
first read of a configuration file, and it must be the only write path the future settings
surface also uses.

## In scope

1. **`CleanupConfig` + `CleanupProviderKind` in `Sources/VoccaText/Cleanup/`** — Codable:
   `provider: CleanupProviderKind` (`rules | ollama | byok`), `ollama: {endpoint, model}?`,
   `byok: {endpoint, model?}?`. Decode tolerates unknown keys; invalid entries skip with a
   loud injectable log; a missing file is the default (`rules`), not an error.
2. **`CleanupConfigStore`** — the FileManager-naming file (third row in the FileManager seam
   table, per-module-scoped to `VoccaText` alongside the dictionary row,
   `InjectionSeamBoundaryTests.swift:917-941`): the journal-store shape (atomic
   temp+rename on save, tolerant load, injected directory for tests,
   `FileSystemJournalStore.swift:40-73`). No save path is required this unit (the settings
   surface writes later) — load + the seam row are the deliverable; the atomic save shape is
   kept for symmetry with the dictionary store or omitted until a writer exists (the plan
   pins it; the seam row is the requirement).
3. **`CleanupResolver`** — an actor, resolve-once: constructed with the store, a transport
   factory, and a key-provider factory (injected so the probe wires fakes); `resolve() async
   throws -> any CleanupProvider` runs at most once (single-flight, the
   `DictationEngineResolver` shape): `rules` ⇒ `ShippingRulesCleanupProvider`; `ollama` ⇒
   `ChainedCleanupProvider(rules:, llm: OllamaCleanupProvider(...))`; `byok` ⇒ chain with
   `BYOKCleanupProvider(...)`; absent file / unknown kind / invalid provider block ⇒ **rules +
   one loud log** (never partially configured, never silently different from the file).
4. **Defaults.** Ollama endpoint `http://localhost:11434` (`prd.md` Data Model); a missing
   `model` for an `ollama` selection is a loud-log degrade to rules (no model, no call).

## Out of scope

- The providers, the chain, the badge — their aspects.
- Any write path / settings UI — JSON is hand-edited this unit; the future settings surface
  writes this same file (`prd.md` M7: "no other write path exists").
- Per-mode selection (C11), configurable budgets (`prd.md` N1).

## Isolation / honesty decisions

- **Absent ⇒ rules, silently.** No file is the default configuration, and the zero-network
  probe runs exactly that path. An invalid file is different: loud log, rules — a user who
  hand-edits badly must be told, not silently reset.
- **The resolver is the single source of "which provider runs."** The composition root holds
  its answer; nothing else reads the file; a mid-session re-read is structurally impossible
  (resolve-once), so a provider swap can never happen mid-dictation (the
  `EngineSelectionConsumptionTests` never-swap precedent).
- **The store executes in CI** (FileManager works on a hosted runner; the dictionary store
  precedent) — the real store runs against real temp directories in the suite.

## Acceptance criteria (tests written first)

Failing XCTests in `Tests/HarnessTests/` — `CleanupConfigTests.swift`,
`CleanupConfigStoreTests.swift`, `CleanupResolverTests.swift`:

- B1 **Kind decode.** `rules|ollama|byok` round-trip; an unknown kind string skips with a
  loud log (injected logger count asserted).
- B2 **Config decode table.** Valid full config; missing file ⇒ default; unknown keys
  tolerated; `ollama` without `model` ⇒ invalid (loud); `byok` without `endpoint` ⇒ invalid
  (loud); wrong-typed fields ⇒ invalid (loud); never throws.
- B3 **Store.** Load with no file ⇒ default, no log; load of a valid file ⇒ decoded; load of
  a corrupt file ⇒ default + loud log, file never rewritten; injected-directory contract.
- B4 **Resolver resolve-once.** `resolve()` is single-flight (an async gate observes no
  overlap) and returns the same provider instance to every caller; a second resolve after the
  first never re-reads the file.
- B5 **Resolver decision table.** Absent file ⇒ rules provider; `rules` ⇒ rules; `ollama`
  valid ⇒ chain whose LLM stage is the Ollama provider with the configured endpoint/model;
  `byok` valid ⇒ chain over the BYOK provider; `ollama` with missing model ⇒ rules + loud
  log; unknown kind ⇒ rules + loud log.
- B6 **The FileManager seam row.** The table has exactly three entries (`journal`,
  `dictionary`, `config`); two-sided pin passes; a planted `FileManager` in any other
  `VoccaText` file is detected; the scan covers both module roots.
- B7 **Boundary discipline.** Full suite green under the floor; Swift 6 clean; Apache
  headers; no new dependency.

## Dependencies / sequencing

- The types/store half needs nothing from C6 (may run right after `llm-transport`);
  the resolver needs the providers and the chain. The plan sequences the resolver tasks after
  `cleanup-chain`.
- Precedents: `FileSystemDictionaryStore` (store shape + seam row), `DictationEngineResolver`
  (resolve-once + single-flight), `EngineSelectionConsumptionTests` (never-swap),
  `AppBootstrap.swift:318` (the logger category precedent).

## Open questions / risks

- **Save path now or never?** No writer exists this unit; adding an untested-by-consumer save
  API is pretend-fidelity (the dictionary store's own discipline). Lean: load-only this
  aspect; the settings surface adds save. The plan pins it.
- **File name.** `cleanup-config.json` (dedicated, per-concern like `dictionary.json`) vs
  `config.json` (the deferred settings file, `ARCHITECTURE.md:554`) — the PRD decided
  dedicated; the plan records the future settings surface adopting it.
- **Transport/key factories as init parameters** keep the resolver headless (the probe wires
  stubs) — the plan pins the exact injection shape.
