# Spec — root-wiring

Aspect of `llm-cleanup` (C6) · `docs/planning/llm-cleanup/prd.md`
Requirements: **M9** (owned here) + **M10** (owned here) + **S1**, **S2**, **N1** (owned here).
Depends on: all seven predecessor aspects.

## Problem slice

The unit's surface is only real when the composition root composes it: the resolver selects
the provider once at launch (`AppBootstrap.swift:294-303` hardwires
`ShippingCleanup.make()` today), the badge state is folded from the resolved provider's
`requiresNetwork`, and the zero-network probe must keep proving the default path makes zero
calls **with the new surface wired** — including the module-coverage cross-check
(`ZeroNetworkTests.swift:578-592`) that fails anything not driven from
`exerciseDefaultConfiguration()`. This aspect is where C6 meets the product's two permanent
invariants.

## In scope

1. **Composition root.** `AppBootstrap.configure` constructs `CleanupConfigStore` +
   `CleanupResolver` (real transport/key factories as defaults), replaces the hardwired
   `ShippingCleanup.make()` with `await resolver.resolve()` in `pipelineAssembly`
   (`AppBootstrap.swift:294-303`), and after resolve folds
   `WidgetAction.egressChanged(.active(endpoint:))` — or `.none` — into the widget store
   (`egress-badge`).
2. **Probe coverage.** `DictationCycleDrive` wires the resolver with an **absent config in a
   temp directory** (default ⇒ rules) and fakes in the transport/key slots; the cycle report
   gains `egress=none` and keeps `cleanup.engine=rules-cleanup`
   (`DictationCycleDrive.swift:516-538`); `ZeroNetworkTests` asserts the new field and the
   unchanged zero-`connect(2)`/zero-resolution numbers (`ZeroNetworkTests.swift:382-593`).
3. **Test floor.** `MINIMUM_EXECUTED_TESTS` raised in the same commits as the tests that land
   it (`Scripts/test-with-floor.sh:963`).
4. **SMOKE_CHECKLIST steps (M10)** — founder steps in the 62–68 pattern: the Ollama real run
   (rewrite observed with Ollama up; degrade to rules observed with Ollama stopped), the BYOK
   run with a real endpoint (rewrite observed; badge visible), and the badge's first
   appearance **both directions** (visible while a network provider is active, gone when
   rules is selected). Key entry one-liner documented.
5. **ARCHITECTURE.md sync (S1).** I2's "BYOK client (C6, unnamed here)" named
   (`ARCHITECTURE.md:16`); §11's budget line gains "provider-declared"; §13's storage list
   (`ARCHITECTURE.md:551-559`) gains `cleanup-config.json` and the Keychain item.
6. **Attribution (S2, only if cheap).** `SessionRecord` carries the cleanup provider identity
   (the C5-deferred N1); the ledger can say *which* cleanup ran.
7. **Configurable budget (N1, only if cheap).** `budgetSeconds` in `cleanup-config.json`
   overriding the declared 5 s — folded only if the config decode falls out naturally.

## Out of scope

- The Cleanup tab / settings UI (`prd.md` Out of Scope), per-mode selection (C11), model
  discovery.
- Any default-path behavior change: the default stays rules, zero calls, forever — the probe
  assertions are the proof and this aspect must not touch their thresholds.

## Isolation / honesty decisions

- **The probe wires fakes, never the real network.** The resolver's transport/key factories
  are injected; the probe passes stubs; the only real adapter in the default path is
  `ShippingRulesCleanupProvider` (as today) — so "zero `connect(2)` with the new surface
  wired" is a real claim over the composed root.
- **Loopback counts as network** (`interposer.c:70-73`): if any wiring bug routes an Ollama
  call into the default path, the interposer sees `connect(2)` to 127.0.0.1 and the build
  fails — the badge and the resolver are the only gates between the user's config and the
  loop.
- **Resolve-once is the never-swap guarantee** — the wiring calls `resolve()` exactly once,
  before the readiness gate, exactly as the engine resolver does (`DictationEngineResolver.swift:92-99`);
  a mid-session provider swap is structurally impossible.

## Acceptance criteria (tests written first)

Failing XCTests in `Tests/HarnessTests/` — `ZeroNetworkTests` extensions and
`AppBootstrapWiringTests` (where the root is testable):

- B1 **Probe cycle asserts `egress=none`** with the resolver wired and absent config; the
  existing `cleanup.engine=rules-cleanup` assertion passes unchanged.
- B2 **Zero network, unchanged.** `testDefaultConfigurationMakesZeroNetworkConnections`
  passes over the new wiring: 0 connections, 0 name resolutions, interposer loaded,
  `PROBE-OK`.
- B3 **Module coverage cross-check passes** over the new surface (nothing new left undriven).
- B4 **Wiring table.** The composition root resolves rules when config is absent (probe
  report), folds `.none`; a resolver double folded through the root's widget store yields
  `.active(endpoint:)` for a `requiresNetwork == true` provider (headless, the store is a
  `@MainActor` observable the tests already drive).
- B5 **Floor raised.** The floor constant equals the suite's executed count after the last
  test-adding commit of this aspect (and of every aspect before it).
- B6 **SMOKE_CHECKLIST has the new steps** with pass criteria tighter than the failure they
  guard (the checklist's own rule, `SMOKE_CHECKLIST.md:14-37`).
- B7 **Attribution (if S2 lands).** A dictation-cycle record carries the cleanup identity;
  the probe's `PROBE-LATENCY` renders it.
- B8 **Boundary discipline.** Full suite green; Swift 6 clean; no new dependency.

## Dependencies / sequencing

- Last: needs the resolver (`cleanup-config`), the badge state (`egress-badge`), the
  providers, and the chain.
- Precedents: `AppBootstrap.configure`'s engine-resolver wiring
  (`AppBootstrap.swift:182, 294-303`), `DictationCycleDrive` (the probe's composed root),
  `ZeroNetworkTests` (the assertion shape + guard-the-guard tests).

## Open questions / risks

- **Where the endpoint string for the badge comes from** (`egress-badge`'s open question):
  the wiring reads it from the resolved provider — the plan pins the property (e.g.
  `CleanupProvider` gains nothing; the resolver returns the endpoint alongside the provider,
  or the badge copy is built in the root from the config it already decoded).
- **Attribution scope creep (S2):** only if the record type change is a one-liner; otherwise
  it stays the C5-deferred N1. The plan marks it a skip-candidate.
- **The probe's `ShippingCleanup.make(store:)` call site** becomes resolver-driven — the
  probe's temp store must keep supplying the rules store, or `dictionary.json` reads land in
  the real Application Support during the probe run (a test-isolation bug, not a network
  one).
