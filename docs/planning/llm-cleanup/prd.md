# PRD — LLM cleanup: Ollama and BYOK (C6)

Slug: `llm-cleanup` · Phase: **P1** (`docs/ROADMAP.md:108-146`) · Type: `feat`.
Owner: aliz · Branch: `feat/llm-cleanup/aliz`.

> The P0/P1 gates (`ROADMAP.md:100-104, 142-146`) are running calendar gates (founder 7-day
> daily-use log; F2-held-out preference), not code gates, and are **not** cleared by this unit.
> Per the roadmap's own schedule this is C6's week-6/7 slot; the gate verdicts are recorded
> separately and nothing here implies P0/P1 passed. The F2 recordings (`SMOKE_CHECKLIST.md`
> step 73) and the daily-use log run in parallel and are unaffected by this unit.

## Problem Statement

C5 shipped rung 1 of the cleanup ladder: deterministic rules, ~0 MB, <10 ms, local by
construction. Rungs 2 and 3 — **Ollama** (local LLM) and **BYOK** (the user's own cloud
endpoint) — are the rest of P1's declared surface: the P1 deliverables table lists "all three
rungs implemented and hot-swappable" (`ROADMAP.md:128`), and the roadmap's pluggable rule is
"two real implementations, not one implementation and a promise" (`ROADMAP.md:28`) —
`CleanupProvider` has exactly one implementation today (`ShippingRulesCleanupProvider`,
`Sources/VoccaText/Cleanup/ShippingCleanup.swift:32-49`). Rules cannot do tone, reflow, or
intent-aware rewriting; an LLM can (`CAPABILITY_ROADMAP.md:134`). And the BYOK rung is the
working proof that the later hosted tier slots into the cleanup seam
(`ROADMAP.md:285-290`).

The design question was never *whether* to offer the LLM rungs but *how to offer them without
the privacy promise quietly eroding* — hence the three constraints this unit exists to honor:
both rungs opt-in, the cloud rung **permanently, visibly badged** at the moment text would
leave the machine (`ROADMAP.md:122, 131`; `PRODUCT_SPEC.md:250-264`), and the default
configuration's zero-network invariant untouched (`ROADMAP.md:139` — a CI test that is a
permanent release blocker).

## Goals & Success Metrics

| Goal | Metric | Target | Proven by |
|------|--------|--------|-----------|
| Cleanup seam has two real implementations | `CleanupProvider` conformers | 3 (rules, Ollama, BYOK) | `ROADMAP.md:28`; seam tests |
| LLM rungs degrade, never break dictation | Failure/timeout paths that still inject text | 100% of the rules output, or raw on chain failure | Stub-transport failure-mode tests + pipeline decision-table tests (`ROADMAP.md:140`) |
| Cloud rung is visibly private-by-design | Egress badge shown while a `requiresNetwork == true` provider is active; absent otherwise | always when active, never when not | Badge reducer decision table (`ARCHITECTURE.md:296`); probe assertion |
| Key never leaks | BYOK key absent from logs/crash reports/errors on every failure path | 0 occurrences | Key-sentinel tests over captured logs |
| Default config stays zero-network | Probe asserts zero `connect(2)`/resolutions with the new surface wired | 0 calls | Zero-network probe (`ROADMAP.md:139`; release blocker, `CAPABILITY_ROADMAP.md:142`) |
| LLM latency is bounded and honest | Provider-declared budget enforced by the caller | 10 ms rules / 5 s LLM (declared, per `ARCHITECTURE.md:322` "the user has knowingly bought latency") | Budget race tests with injected clock |

## User Personas & Scenarios

**Persona (ICP):** a Mac user who lives in dictation all day and wants it private and local —
the person who will not send their audio to the cloud but still wants polished text typed
anywhere (`deterministic-cleanup/prd.md:48-50`).

**Scenario A — Ollama user.** A developer already runs Ollama locally. They hand-edit
`cleanup-config.json` to select `ollama` with their model. Dictated text now gets true
rewriting — tone and reflow, not just fillers — entirely on-device. When Ollama is stopped
mid-session or responds slowly, the loop still lands text (the rules output), never nothing.
`ROADMAP.md:119` (rung 2: "None" egress).

**Scenario B — BYOK user.** A power user with their own endpoint configures it in
`cleanup-config.json` and their key in the Keychain. The moment dictation begins, the widget
pill carries the ☁︎ marker (`PRODUCT_SPEC.md:250-264`) — non-dismissable while the provider is
active — and hovering it states plainly what leaves the machine. Their key is never in a log,
crash report, or error surface. `ROADMAP.md:120` (rung 3: egress **Yes — badged at point of use**).

**Scenario C — default user.** Nothing is configured. The loop behaves byte-for-byte as today:
rules, zero network, no badge. The opt-in never happens silently and never re-enables itself
(`ROADMAP.md:131`).

## Requirements

### Must-have

- **M1 — Provider-declared cleanup budget.** `CleanupProvider` gains `budget: Duration` as a
  protocol requirement with a default of 10 ms (`CleanupProvider.swift:45-59`), and
  `DictationPipeline` races the **provider's own declared budget** instead of the hardcoded
  constant (`DictationPipeline.swift:108-113, 316-367`) — same caller-enforced
  `withThrowingTaskGroup` mechanism, same raw-degrade, same span recording. The rules provider
  declares 10 ms explicitly (the B10 declared-not-defaulted contract,
  `ShippingCleanup.swift:29-31`); Ollama and BYOK declare 5 s. Enforcement stays with the
  caller, never trusted to the provider (`ARCHITECTURE.md:509`); `CleanupContext.budget`
  carries the same value as information (`ARCHITECTURE.md:515`). Existing pipeline tests
  (B1–B8) pass unchanged via the default.
- **M2 — `LLMTransport` seam + `DefaultLLMTransport` (the second named network type).**
  `ARCHITECTURE.md:16` (I2) names the BYOK client as the second permitted network type; this
  unit names it: an `LLMTransport` seam in VoccaText (`complete(_ request: LLMRequest) async
  throws -> LLMResponse`, JSON in/out) with **one** real implementation, `DefaultLLMTransport`,
  the second file permitted to name `URLSession` — the H8 table in
  `ModelDownloaderSeamTests.swift:61-69` gains the entry as a **reviewed amendment** (the
  FileManager per-module precedent, `InjectionSeamBoundaryTests.swift:908-916`), and the lint
  comment's "nothing else ever joins it" is corrected in the same commit. `LLMRequest`/`LLMResponse`
  vocabulary is Core-free (VoccaText-owned) and every decision — request shaping, timeout, error
  translation — lives above the seam; the real adapter contains translation only.
- **M3 — Ollama provider** (`OllamaCleanupProvider` in `VoccaText/LLM/`): endpoint (default
  `http://localhost:11434`) and model name **from the config, not discovered** (decision:
  `/api/tags` model discovery has no surface until the Cleanup tab ships, `PRODUCT_SPEC.md:232-240`;
  deferred with it). Requests hit `/api/generate` with `stream: false` (we need the whole result
  before injection anyway, `CAPABILITY_ROADMAP.md:137`), a tuned cleanup-not-creativity prompt
  (`CAPABILITY_ROADMAP.md:137`), and the user's text. Request shape, timeout, and fallback on
  every failure mode — absent, cold, slow, malformed — are tested against a **stubbed transport**
  (the `StubTransport` precedent, `ModelTransportTestDoubles.swift:34-153`).
- **M4 — BYOK provider** (`BYOKCleanupProvider` in `VoccaText/LLM/`): provider-agnostic
  endpoint + model from the config, **key from the Keychain** (`issue.md:11`), `Authorization:
  Bearer <key>` header, OpenAI-compatible chat-completions request shape as the v1 contract.
  **Off by default**; the key is never re-readable from anywhere but the Keychain store. The
  **key-hygiene acceptance**: a stub with a sentinel key runs every failure path and asserts
  the sentinel never appears in captured logs, error descriptions, or crash surfaces
  (`CAPABILITY_ROADMAP.md:142`). **Failure taxonomy extended to the key's own failure modes:**
  key absent, keychain locked/unreadable, and 401/403 from the endpoint are each first-class
  paths that throw — never a prompt, never a silent disable, never a retry loop — and land in
  the same "chain falls back to the rules output" degrade as every other LLM failure.
- **M5 — The Keychain seam.** A `SystemKeychain`-shaped adapter — the **one file in
  `Sources/` permitted to name the `Security`/`SecItem`/`kSec` family** — plus a new
  one-file-per-seam row in the H7 shape (`InjectionSeamBoundaryTests`). The BYOK provider
  depends on a `KeyProvider` seam with the system adapter as the real implementation and a
  stub in tests (the `SystemPasteboard` precedent: adapter = translation, executed by nothing
  in CI). No Keychain code exists anywhere in `Sources/` today — this is the first.
- **M6 — Rules-then-LLM chain** (`ChainedCleanupProvider` in `VoccaText/LLM/`): the §11
  pipeline is "RulesCleanup → optional LLM" (`ARCHITECTURE.md:506-512`) — rules always run
  first, the LLM stage rewrites the **rules output**, and on any LLM failure/timeout the rules
  output stands ("fallback to rules" is structural, not post-hoc). The chain's declared budget
  covers both stages (10 ms rules-only; 5 s with an LLM stage). Empty/whitespace LLM output
  routes to the rules output (the never-empty rule, `DictationPipeline.swift:360-366`).
- **M7 — Opt-in config + resolve-once selection.** A hand-edited `cleanup-config.json` in
  Application Support (the `dictionary.json` precedent — JSON is the edit surface until the
  Cleanup tab ships, `PRODUCT_SPEC.md:304`): `provider: rules|ollama|byok`, Ollama
  `endpoint`/`model`, BYOK `endpoint`/`model`. A `CleanupResolver` (the
  `DictationEngineResolver` resolve-once shape, `DictationEngineResolver.swift:50-149`)
  resolves **once at launch**: absent file ⇒ rules; unknown/invalid provider ⇒ rules with a
  loud local log (never silently partial); no re-resolution mid-session, ever. The config
  store is the second `FileManager`-naming file in VoccaText — the FileManager seam table
  gains the row (`InjectionSeamBoundaryTests.swift:917-941`). The later settings surface
  writes this same file (`ROADMAP.md:131` "never silently re-enabled": no other write path
  exists).
- **M8 — The egress badge.** `WidgetReducerState` gains egress state (`WidgetEgressState`:
  `.none` or `.active(endpoint: String)`, driven by a new `WidgetAction` folded at wiring time
  from the resolved provider's `requiresNetwork` — "the widget reads it directly",
  `ARCHITECTURE.md:296`). While an active provider requires network, the recording pill shows
  the ☁︎ glyph (`PRODUCT_SPEC.md:250-264` — byte-fidelity-pinned, the `EnginePickerCopy` rule,
  `EnginePickerCopyTests.swift:28-30`) during the opening/recording/transcribing states, with
  hover copy stating plainly "Cleanup runs on \<endpoint\>. Your text is sent there."
  **Non-dismissable while active** — no time-based transition exists in the reducer (the
  `FailsafeStateReducer` never-auto-dismiss precedent). The closed `WidgetAction` set gains
  the case as a deliberate edit (its structural pins update with it). The zero-network probe's
  cycle asserts the badge is **absent** on the default path (rules ⇒ `.none`).
- **M9 — Probe coverage + wiring.** `AppBootstrap.configure` resolves the provider via the
  resolver and wires the chain + badge; the probe's default-configuration path drives the new
  surface **with fakes** (stub transport, stub key provider, absent config) and asserts zero
  `connect(2)` unchanged (`ZeroNetworkTests.swift:382-593`; loopback counts as network,
  `interposer.c:70-73`); the cycle report asserts `cleanup.engine=rules-cleanup` and
  `egress=none` (`DictationCycleDrive.swift:516-538`). Anything new that is not driven from
  `exerciseDefaultConfiguration()` fails the module-coverage cross-check
  (`ZeroNetworkTests.swift:578-592`) — the probe's new assertions ARE the coverage.
- **M10 — Test floor + smoke steps.** `MINIMUM_EXECUTED_TESTS` raised in the same commits as
  the tests that land it (`Scripts/test-with-floor.sh:963`). `SMOKE_CHECKLIST.md` gains
  founder steps in the 62–68 pattern: the Ollama real run (endpoint live, model selected,
  rewrite observed, degrade observed with Ollama stopped), the BYOK run with a real endpoint,
  and the badge's first appearance — **both directions** (visible while active, gone when
  rules is selected).

### Should-have

- **S1 — ARCHITECTURE.md sync.** I2's "BYOK client (C6, unnamed here)" gets its name
  (`ARCHITECTURE.md:16`); §11's budget line gains "provider-declared"; §13's storage list
  (`ARCHITECTURE.md:551-559`) gains `cleanup-config.json` and the Keychain item; the H8 lint
  comment corrected with the M2 amendment.
- **S2 — Attribution.** `SessionRecord` carries the cleanup provider identity alongside engine
  attribution (C5's deferred N1) — the ledger can then say *which* cleanup ran, not just how
  long. Only if it falls out of M9 cheaply.

### Nice-to-have

- **N1 — Configurable LLM budget.** `budgetSeconds` in `cleanup-config.json` overrides the 5 s
  declared default. Small surface; only if the config decode falls out naturally.
- **N2 — Ollama `keep_alive` hint.** Optional request field to hold the model warm between
  dictations. Requires measurement on the founder's machine to be worth it; not this unit
  unless trivial.

## Technical Considerations

- **Layer:** AI cleanup — rungs 2–3 behind the shipped `CleanupProvider` seam; sits between
  ASR and injection with the existing caller-enforced budget race.
- **The 10 ms budget problem (the unit's central design tension):** `cleanupBudget` is a
  private constant in the pipeline (`DictationPipeline.swift:113`); an LLM round-trip is
  seconds. Resolved by M1 — provider-declared budget — matching the architecture's own
  doctrine: "at P1 the default is rules, and if an LLM is opted into, the user has knowingly
  bought latency" (`ARCHITECTURE.md:322`). The chain (M6) keeps rules first so the degrade is
  to *cleaned* text, not raw, whenever the LLM stage fails.
- **The latency tradeoff for opted-in users, stated plainly:** with an LLM rung active, every
  dictation waits up to the 5 s budget before text lands, with the widget holding its
  existing TRANSCRIBING state (and, when `requiresNetwork`, the badge) meanwhile. The P2
  loop-level latency targets (`ROADMAP.md:171`) apply to the default rules path; an opted-in
  LLM user is consciously outside them for as long as the rung is on. This is accepted at the
  review gate, not papered over — the escape hatch is the config file and Esc, both of which
  exist before this unit ships.
- **LLM rewrite quality is unmeasured, and this unit must not imply otherwise.** The eval
  harness scores rules-over-raw (`ProvisionalCleanupTargets`; `eval-harness` aspect); there is
  no harness for LLM-over-rules output, and no claim "LLM > rules" is made or tested here. The
  rung ships because the roadmap defines rung 2's value proposition ("tone, rewriting, reflow",
  `CAPABILITY_ROADMAP.md:134`), and the founder's real Ollama run (smoke step) is the first
  judgment of it — recorded honestly as a smoke observation, not a gate number.
- **Network discipline (unchanged, load-bearing):** `ARCHITECTURE.md:296` — a provider cannot
  make a network call without declaring `requiresNetwork == true`, because the interposer
  fails the build if one with `false` opens a socket. Both new providers declare `true`; the
  default path selects rules, so the probe sees nothing. The H8 table edit (M2) is a reviewed
  amendment per I2's two-named-types design, not a weakening — the PRD's predecessor (C5)
  deliberately touched no `requiresNetwork == true` code (`deterministic-cleanup/prd.md:166-168`).
- **Module shape:** no new module, no new dependency. Providers live in
  `Sources/VoccaText/LLM/` (`ARCHITECTURE.md:128` plans the directory); VoccaText is an
  adapter module importing only `VoccaCore` (`ModuleBoundaryTests.swift:99-107`). Foundation
  `URLSession` on macOS 15 is the HTTP surface; no SPM client package, no
  `THIRD_PARTY_NOTICES.md` entry.
- **`CleanupContext.dictionary` stays `[]` from the pipeline** (declared-not-read,
  `DictationPipeline.swift:311-313`): the rules stage reads its own store; the LLM stage does
  not receive the user dictionary. The chain passes rules output, not the dictionary.
- **Esc/cancellation:** the pipeline's post-cleanup cancellation re-check is unchanged
  (`DictationPipeline.swift:262-267`) — Esc during a 5 s LLM cleanup cancels the chain and
  injects nothing; the LLM call must be cancellation-cooperative (URLSession throws
  `CancellationError` on cancel). A cancellation-swallowing provider can return late but the
  caller re-check still gates injection.
- **Per-mode selection deferred** to C11: `SessionMode` is `.dictation`-only in the pipeline
  today; `CleanupContext.mode` stays declared-not-read (`deterministic-cleanup/prd.md:219-220`).
- **Badge is the only widget UI in this unit:** the Cleanup tab's three-rung picker
  (`PRODUCT_SPEC.md:232-240`) ships with the deferred settings surface; the badge
  (`PRODUCT_SPEC.md:250-264`) is required now. The widget pill never becomes key
  (`WidgetPanel.swift:90-99`) and the badge is display-only + hover — no focus implications;
  the hover surface is the first in the codebase (no tooltip precedent exists).

## Data Model

- `CleanupConfig` (VoccaText, Codable): `provider: CleanupProviderKind` (`rules | ollama |
  byok` — absent/invalid ⇒ rules, loud log), `ollama: { endpoint: String = "http://localhost:11434",
  model: String }?`, `byok: { endpoint: String, model: String? }?`. Stored at
  `~/Library/Application Support/Vocca/cleanup-config.json` (the `dictionary.json` shape:
  atomic temp+rename on save; tolerant load, `FileSystemDictionaryStore.swift:178-189`).
- `LLMRequest`/`LLMResponse` (VoccaText): the transport vocabulary — endpoint-relative,
  JSON body, streaming off. Ollama `/api/generate` shape for the Ollama provider; OpenAI
  chat-completions shape for BYOK (v1 contract, flagged).
- Keychain item: `dev.vocca.Vocca.byok-key` in the default (login) keychain, app-only access
  (not sandboxed — the app has no entitlement restrictions, `ARCHITECTURE.md:580`).
- `WidgetEgressState` (VoccaUI): `.none` | `.active(endpoint: String)` — reducer state, so
  the decision table runs headless.
- No new latency vocabulary: `LatencySpan.cleanup` already records the span on every answer,
  timed-out paths included (`DictationPipeline.swift:359, 377-382`).

## Risks & Open Questions

- **R11 privacy erosion (named, `ROADMAP.md:310`):** the seam's `requiresNetwork`, the
  probe's zero-connection assertion, the off-by-default config, and the non-dismissable badge
  are the four guards; none may be weakened in this unit, and the zero-network test is a
  release blocker (`CAPABILITY_ROADMAP.md:142`).
- **The 5 s LLM budget is unmeasured.** It is a declared ceiling (and cancelable by Esc), not
  a measured number; the founder's real Ollama run (smoke step) is what validates it, and a
  number too generous shows up as p95 latency in the ledger — honest, not hidden. If the real
  run shows Ollama slower than 5 s on a typical utterance, the budget is tuned, not the
  invariant.
- **H8 table amendment risk:** the lint's "one entry, nothing else ever joins it" wording
  (`ModelDownloaderSeamTests.swift:63-64`) predates I2's two-types amendment; the edit is
  reviewed in this unit and the comment corrected — a future review must not read the edit as
  a weakening. The seam tests' planted-violation controls keep it honest.
- **Keychain is unexecutable in CI** (the tap-adapter precedent): the `SystemKeychain`
  adapter is translation only; every decision is above the seam and tested over a stub key
  provider; the founder's BYOK smoke step is the adapter's only execution.
- **Open:** the BYOK OpenAI-compatible shape is a v1 contract decision (provider-agnostic
  means *an* agreed shape, not every shape); flag in review, do not gold-plate.

## Out of Scope

- **The Cleanup tab / settings UI** — ships with the deferred settings surface
  (`deterministic-cleanup/prd.md:216-217`); this unit's edit surface is
  `cleanup-config.json` + the Keychain.
- **Per-mode provider selection** — deferred to C11 with CONVERSING (`CAPABILITY_ROADMAP.md:140`;
  `deterministic-cleanup/prd.md:219-220`).
- **Ollama model discovery (`/api/tags`)** — no surface until the Cleanup tab.
- **Streaming LLM output, tools/agents, anything beyond cleanup** — P1 scope discipline
  ("Cleanup only", `ROADMAP.md:112`).
- **Anything cloud in the OSS core** — BYOK is the user's endpoint and their key; no Vocca
  infrastructure, no egress beyond the user's own config (`ARCHITECTURE.md:607`).
- **Changes to the zero-network default** — the default path stays rules, zero calls, forever.

## Proposed aspects (for tech-plan; each independently buildable and test-first)

| Aspect | Boundary | Requirements |
|--------|----------|--------------|
| `provider-budget` | `CleanupProvider.budget` requirement + default; pipeline races the provider's budget; rules declares 10 ms; B1–B8 unchanged + new budget tests | M1 |
| `llm-transport` | `LLMRequest`/`LLMResponse`, `LLMTransport` seam, `DefaultLLMTransport` (second URLSession file), H8 table amendment + lint-comment correction, stub transport doubles | M2 |
| `ollama-provider` | `OllamaCleanupProvider`: config read, `/api/generate` request shape, tuned prompt, stub-tested failure modes | M3 |
| `byok-provider` | `BYOKCleanupProvider` + `KeyProvider` seam + `SystemKeychain` adapter + Security seam row + key-hygiene tests | M4, M5 |
| `cleanup-chain` | `ChainedCleanupProvider`: rules-first then LLM on rules output, chain budget, empty-fallback | M6 |
| `cleanup-config` | `cleanup-config.json` store (FileManager row), `CleanupProviderKind`, `CleanupResolver` resolve-once semantics | M7 |
| `egress-badge` | `WidgetEgressState` + action + reducer table, `BadgeCopy` pinned to `PRODUCT_SPEC.md:250-264`, glyph + hover, probe asserts `egress=none` | M8 |
| `root-wiring` | AppBootstrap resolver + chain + badge wiring; probe drives new surface with fakes, zero `connect(2)` stays; floor raise; ARCHITECTURE.md sync; smoke steps | M9, M10, S1, S2, N1 |

Rough shape: `provider-budget` → `llm-transport` → {`ollama-provider` ‖ `byok-provider`} →
`cleanup-chain` → `cleanup-config` → `egress-badge` → `root-wiring`. The budget is the only
predecessor gate (protocol change); the two providers are parallel after the transport; the
chain and config depend on the providers; the badge and wiring are last and depend on all.
