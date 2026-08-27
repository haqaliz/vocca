# PRD: injection-strategy-memory

> **Unit:** C8 (P2) — Injection matrix + per-app strategy memory
> **Slug:** `injection-strategy-memory` · **Owner:** aliz · **Date:** 2026-08-27
> **Source:** `docs/planning/_card/issue.md` (inline brief from `vocca-next`).
> **Authority:** `docs/technical/CAPABILITY_ROADMAP.md:178-193` (C8), `docs/technical/ARCHITECTURE.md` §5/§9/§13,
> `docs/ROADMAP.md` P2, `docs/product/PRODUCT_SPEC.md:275`, `docs/SMOKE_CHECKLIST.md` matrix section.

---

## Problem Statement

The ladder (C4) is built and wired, but it does not **learn**. `LadderInjector` retries a rung
that has failed for a given app on *every* dictation — latency the user pays repeatedly for
information we already hold (`CAPABILITY_ROADMAP.md:180`). The default rung order is recomputed
from scratch each time by `DefaultInjectionStrategyOrder` (`InjectionStrategyOrder.swift:51-65`),
which knows only the allowlist, never the app's history. Worse, the `SeededInjectionAllowlist`
blesses exactly three apps for the accessibility rung (`SeededInjectionAllowlist.swift:46-53`);
every Electron/browser app is stuck on clipboard forever — yet the code's own comment promises
those apps reach accessibility "only through C8's learned memory" (`SeededInjectionAllowlist.swift:30`).
And the injection-success number the P2 gate and P5 publication are judged on — ≥95%
first-method-success across a 20+ app matrix (`ROADMAP.md:172`, `CAPABILITY_ROADMAP.md:189`) —
does not exist as a measured artifact anywhere.

This unit closes all three: the ladder learns which rung works per bundle ID and starts there;
a non-allowlisted app can be *promoted* to the accessibility rung after the memory earns it
(read-back verified); and the expanded matrix becomes the founder's measured number, with the
learning mechanism proven headlessly in CI.

The target user is the founder first (every Vocca release is also its own user-test), then the
external beta users the P2 gate requires (`ROADMAP.md:180`). A first-time Google Docs user must
not pay the AX discovery cost on their first dictation (`CAPABILITY_ROADMAP.md:185`).

## Goals & Success Metrics

| # | Metric | Target | Where judged |
|---|--------|--------|--------------|
| G1 | Injection success across the matrix, **with memory active** | **≥95% first-method-success** over the expanded 20+ app set | Founder-machine matrix run (`SMOKE_CHECKLIST.md` new rows); CI proves the mechanism, not the number |
| G2 | Memory learns | Tried-first → demote-on-fail → re-probe rediscovers, all headless | `CAPABILITY_ROADMAP.md:189` acceptance, in CI |
| G3 | Clipboard hygiene | Pasteboard survives **100 consecutive dictations** with a clipboard manager running | Headless racing-fake test in CI; real run = smoke step 28 (`SMOKE_CHECKLIST.md:495-511`, `ROADMAP.md:85`) |
| G4 | Zero network untouched | Default configuration still makes **zero network calls** | `ZeroNetworkTests` probe, permanent release blocker (`ROADMAP.md:139`) |
| G5 | Latency budget | Memory-chosen rung stays inside the ladder's ≤100 ms budget | `ARCHITECTURE.md:318`; the **read** is a pure in-memory lookup, and the **persist** happens off the session path (see T-2) |

## User Personas & Scenarios

1. **The founder (primary).** Dictates daily into Notes/Mail/TextEdit, VS Code, Slack, Docs.
   Today Slack and Docs repeat the clipboard discovery every time. After this unit: the first
   failure demotes AX, the next dictation starts at the rung that works, and a successful run
   confirms the strategy.
2. **A first-time Google Docs user (seeded hostile).** Their very first dictation starts at
   clipboard, never tries AX against Docs' custom editor — the discovery cost is paid by the
   seed, not by the user (`CAPABILITY_ROADMAP.md:185`).
3. **An external beta user (P2 gate).** Uses the Apps tab to see, per app, how Vocca types
   (`typing directly` / `pasting` / `manual only`), override a wrong call, or reset what was
   learned (`PRODUCT_SPEC.md:275`). Their dictation contributes to the measured ≥95% number.

## Requirements

### Must-have (the shipped unit)

| # | Requirement | Decision | Test |
|---|-------------|----------|------|
| R1 | `InjectionStrategyStore` seam, separated from `TextInjector` so learning is testable without real apps | Protocol in `VoccaCore` (stdlib-only, per `CoreBoundaryTests`), implementations in `VoccaInject/Memory/`: `PersistentStore` + `EphemeralStore` (`ARCHITECTURE.md:260`) | Store unit tests over the injected seam; `EphemeralStore` in every headless test |
| R2 | Persist winning rung per bundle ID; start there next time | Learned strategy = ordered rung list per bundle ID, `.clipboardPaste` can **never** be demoted (it is the workhorse, `ROADMAP.md:47`); `.widgetFailsafe` never appears in a strategy (`injector-seam plan:66`) | Memory order test: pre-seeded demotion → next `orderedRungs(for:)` starts at the working rung |
| R3 | Demote on failure | If the tried-first rung fails and a later rung succeeds, the failed rung is demoted (removed from the attempt list) for that app; a rung absent from the strategy map is skipped by the decision (`InjectionLadderDecision.swift:110-116`) | Demote test: first rung fails → second succeeds → next order excludes the failed rung |
| R4 | Re-probe on a decay schedule, so a fixed app is rediscovered "not permanently written off" | Time-based re-probe: a demoted rung is re-included **once** after a re-probe window (~7 days, provisional); re-probe success restores it, failure re-demotes with a fresh window. Re-probe is lazy — evaluated on the next dictation for that app, no timers | Rediscover test with injected clock: window elapsed → re-tested → success → restored; failure → still demoted |
| R5 | Seeded defaults for known-hostile apps | Seed data (not decisions): Google Docs, Slack begin with AX excluded (start at clipboard); the P0 matrix's hostile class (`ROADMAP.md:91`) | Seed test: `orderedRungs` for seeded hostile app excludes `.accessibility` on first dictation |
| R6 | Learned promotion to the accessibility rung | `MemoryBackedInjectionStrategyOrder` **also conforms to `InjectionAllowlist`** and is handed to both rung and order at `ShippingLadder.make` (one source of truth — the two can never disagree, `ShippingLadder.swift:47-50`). A non-allowlisted app that delivers via clipboard is probed for AX after the re-probe window; a **read-back-verified** AX success promotes it permanently (`SeededInjectionAllowlist.swift:30`) | Promotion test: app not in seed, clipboard success → window elapses → AX attempted → verified success → next `orderedRungs` includes AX and the rung strategy's own allowlist gate passes it |
| R7 | User-visible per-app override | New **Apps** tab in Settings (`PRODUCT_SPEC.md:275`): per-app strategy + plain-language health column (`typing directly` / `pasting` / `manual only`) + **"reset what Vocca learned"** button. Reached through `SettingsBindings` closures wired to the same store the ladder reads (`AppBootstrap.swift:844-847` pattern) | Headless reducer/copy tests; view is glue executed by nothing in CI (window-server rule) |
| R8 | Recording | The write side lives in `LadderInjector.inject` (`LadderInjector.swift:74-89`) — the one place that sees `target.bundleID`, the order, and the full `InjectionResult` together; records on both success and the catch residual. **The persist is off the latency path** (async write, never awaited by the injector — see T-2). Secure Input refusals and `bundleID == nil` write nothing (no rung was attempted — `SMOKE_CHECKLIST.md` step 27) | Recording test: delivered/failsafe results mutate the store as specified; rung-0 refusals leave it untouched; the injector never awaits the persist |
| R9 | Persistence: `strategies.json`, atomic, tolerant | `~/Library/Application Support/Vocca/strategies.json` (`ARCHITECTURE.md:580`); the `FileSystemDictionaryStore` shape exactly (atomic temp-write→`replaceItemAt`, tolerant load that never throws, never rewrites on load, corrupt → skip + loud log, `DictionaryStoreTests` precedent). One-file-per-seam: new FileManager row `"strategy"` in `VoccaInject`, exact-set pin amended three→four seams (`InjectionSeamBoundaryTests.swift:1151-1155, 1293-1304`) | Real store against real temp dirs in CI; torn-write / corrupt-file / missing-file pins |
| R10 | Matrix + smoke rows | The expanded 20+ app list (P0 set + additions to reach 20+, `ROADMAP.md:89-91`), **the concrete list settled in the `matrix-smoke` aspect** (the docs contradict "20 apps"/"20+ apps" and name no P2 set — the aspect owns the decision), each row naming its expected rung; a semi-automated harness script in `Scripts/` driving the fixed-phrase gesture + `pbpaste` byte-compare; founder-machine, per `SMOKE_CHECKLIST.md` discipline (a row naming `.accessibility` with nothing in the field is a bug, not a pass) | Harness + checklist rows are the founder's evidence for ≥95% (G1); headless half proven by R2-R6 |

### Should-have

| # | Requirement | Note |
|---|-------------|------|
| S1 | Cap remembered apps (bounded store) | The ledger's cap-512 precedent (`LatencyLedger.swift:50`); a bounded memory + "reset what Vocca learned" (R7) keeps the learned allowlist from growing unboundedly |
| S2 | Per-app override beats memory | An explicit override (R7) pins the rung order for that app and is **absolute**: memory neither demotes, promotes, nor re-probes a overridden app — the override wins and learning is frozen for it (`CAPABILITY_ROADMAP.md:186`); the Apps tab shows the override distinctly from learned state |

### Nice-to-have

| # | Requirement | Note |
|---|-------------|------|
| N1 | Strategy provenance in the ledger | Which rung memory chose vs which actually landed — cheap to add once recording exists; not required by any gate |

## Technical Considerations

- **Read side.** A second `InjectionStrategyOrder` implementation — promised verbatim by
  `InjectionStrategyOrder.swift:19-22`, `LadderInjector.swift:58-59`, and the C4 injector-seam
  plan (`plan_20260809.md:35,66,82`). The decision function `InjectionLadderDecision.decide`
  needs **zero changes**: an absent rung already counts as failed, and `attempted` is already the
  demotion input (`InjectionResult.swift:23-24`).
- **T-2 · The persist never touches the latency path.** The read (R2-R6) is a pure in-memory
  lookup into the loaded strategy; the write (R8) is a detached/async persist the injector never
  awaits — the ≤100 ms ladder budget (`ARCHITECTURE.md:318`) is measured around the synchronous
  inject, so a fire-and-forget save cannot regress it. The store loads once, in the custody
  chain, before `LadderInjector` is constructed (`AppBootstrap.swift:134-141`), the
  `RecoveryJournal` load-on-launch precedent.
- **Promotion (R6) is the load-bearing design.** The AX rung re-checks the allowlist inside its
  own `tryInject` (`AccessibilityRungStrategy.swift:98-100`). A memory that only swapped the
  order could demote but never promote. Making the memory-backed order *also* the allowlist
  handed to both rung and order keeps the two gates one source of truth — this is the interview
  decision "memory can promote".
- **Core owns vocabulary, stdlib-only.** `VoccaCore` imports nothing (`CoreBoundaryTests.swift:116,257-279`).
  The strategy value type and the pure decision functions (demote, re-probe eligibility,
  ordered-rungs projection) live in Core, timestamps as integer epoch seconds (no `Foundation`).
  The JSON/FileManager work lives in the `VoccaInject` adapter.
- **Zero network.** A disk store is invisible to the network interposer (it records only socket/
  DNS entry points, `NetworkInterposer.swift:21-24`). The absent-file path must be silent under
  `AppBootstrap.configure` — the probe drives configure (`VoccaNetworkProbe.swift:232-238`), the
  `CleanupConfigStore` precedent. If the probe's report gains strategy fields, extend the
  constants through the guard-the-guard tests, never by pasting probe output.
- **Lint surface.** One new FileManager row (`"strategy"` in `VoccaInject`) and the exact-set pin
  amendment (three→four seams) — the reviewed-amendment pattern the config row established
  (`InjectionSeamBoundaryTests.swift:1151-1155, 1293-1304`). `VoccaUI` imports only `VoccaCore`
  (`ModuleBoundaryTests`), so the Apps tab reaches the store through root-wired bindings.
- **Composition.** Construct the persistent store in the custody chain beside `RecoveryJournal`
  (`AppBootstrap.swift:134-141`), swap the order at `ShippingLadder.make` (`ShippingLadder.swift:66-68`).
- **Privacy.** `strategies.json` holds bundle IDs + rung identifiers only — no text, no
  transcript, no timestamps of content. Local-only; never egressed (invariant 2).

## Risks & Open Questions

| # | Risk / Question | Mitigation / Note |
|---|-----------------|-------------------|
| X1 | **AX promotion learned as good when it is not.** A lying AX that passes read-back (silent insert that coincidentally verifies) would be promoted. | Bounded by the existing read-back verification; promotion is one-shot, re-probe-verified, and the Apps tab shows the learned state + reset. The founder's matrix run (G1) is the calibration. |
| X2 | **Re-probe parameters are provisional** (~7 days, one-shot). | Marked provisional in exactly one place; re-baselined from the founder's real matrix run, the `WarmStartRatio`/`ProvisionalCleanupTargets` precedent. |
| X3 | **A demoted-to-empty strategy** (all non-workhorse rungs demoted). | `.clipboardPaste` can never be demoted (R2), so no strategy is ever empty; re-probe keeps the rest alive. |
| X4 | **Ladder budget.** Memory read adds a lookup to the ≤100 ms ladder path. | Pure in-memory read after load-on-launch; store load is off the session path (custody chain, `AppBootstrap.swift:134-141`). |
| X5 | **Corrupt/old strategies.json.** | Tolerant decode, never fatal, never rewritten on load (R9) — the `CleanupConfigStore`/dictionary precedent. |
| X6 | **Does the learned allowlist collide with C12's per-app context opt-in?** | C12 is a different store (`ARCHITECTURE.md` adjacency); this unit does not touch context. Flag in C12 planning. |
| X7 | **Real-matrix execution is founder-only** (Automation grants). | Same honest scope as WER/latency: CI proves the mechanism, the smoke rows are the only real execution (`SMOKE_CHECKLIST.md:392-396`). |

## Out of Scope

- **Adaptive settle delay** (~80 ms base, adaptive per app). `ARCHITECTURE.md:472` assigns it to
  C8, but the interview deferred it — the clipboard settle stays fixed this unit. Recorded for a
  follow-up slice.
- **The ≥95% matrix number in CI.** Founder-machine only; CI proves the learning mechanism.
- **Per-app Automation-denial detection.** The existing TCC denial already drops an app to the
  clipboard rung naturally (smoke 29, `ARCHITECTURE.md:602`); memory records that drop as a
  failure and demotes AX accordingly.
- **C12 context provider** and its per-app opt-in store (different seam, same directory adjacency).
- **No cloud, no egress, no telemetry.** Nothing in this unit sends a byte off-device.
- **Settings tabs beyond Apps** (Speech/Cleanup read-only tabs stay as shipped).

## Aspect decomposition (proposed)

| Aspect | One-line boundary |
|--------|-------------------|
| `core-memory` | `InjectionStrategy` value type + pure decision functions (demote-on-fail, re-probe eligibility, ordered-rungs projection) in `VoccaCore`, stdlib-only, headless tests |
| `store-seam` | `InjectionStrategyStore` protocol + `EphemeralStore` + `PersistentStore` (`strategies.json`, one FileManager file), lint amendment |
| `memory-order` | `MemoryBackedInjectionStrategyOrder` (+ `InjectionAllowlist` conformance), recording in `LadderInjector`, wiring in `ShippingLadder.make` + `AppBootstrap`, seeded hostile defaults; the R2-R6 acceptance tests |
| `apps-tab` | Settings Apps tab: per-app strategy + health column + reset-learned; `SettingsBindings` closures; headless reducer/copy tests; thin view glue |
| `matrix-smoke` | Expanded 20+ app list, new smoke checklist rows, semi-automated harness script (founder-machine) |

*(Aspect names pending confirmation — see the review gate. Adaptive settle stays out per the interview.)*
