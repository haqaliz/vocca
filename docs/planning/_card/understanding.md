# Understanding — llm-cleanup (C6)

Phase P1 · Layer: AI cleanup (`CleanupProvider`, rungs 2–3) · `docs/technical/CAPABILITY_ROADMAP.md:132-146`

## What the work is really asking

Complete P1's cleanup ladder: give `CleanupProvider` a **second and third implementation** —
`OllamaCleanup` (local HTTP to an Ollama instance) and `BYOKCleanup` (user's own cloud endpoint,
key in the Keychain) — plus the **egress badge** (`PRODUCT_SPEC.md:250-264`) that makes the
privacy promise visible at the moment text would leave the machine. This is the roadmap's
"two real implementations, not one implementation and a promise" rule applied to the cleanup
seam (`ROADMAP.md:28`), and the BYOK rung is the working proof that a hosted provider slots
into the seam (`ROADMAP.md:285-290`).

## What already exists (shipped, git-backed)

- The seam is C6-ready: `CleanupProvider` with `requiresNetwork` (default `false`,
  `Sources/VoccaCore/CleanupProvider.swift:45-65`), `CleanupContext` (target/mode/dictionary/budget),
  `ProviderIdentity` with `"ollama-cleanup"`/`"byok-cleanup"` machine keys **already reserved**
  (`Sources/VoccaCore/ProviderIdentity.swift:31`), and a seam doc that names C6 as the plan
  (`CleanupProvider.swift:15-21`).
- `ARCHITECTURE.md` I2 names **the BYOK client as the second permitted network type** ("unnamed
  here", `ARCHITECTURE.md:16`); `:296` makes `requiresNetwork` load-bearing for the badge;
  `:257` lists `OllamaCleanup`/`BYOKCleanup` in the seam table; §11's diagram is
  **rules-always-then-optional-LLM** (`ARCHITECTURE.md:506-512`) — the "fallback to rules"
  acceptance is structurally the chain design, not a post-hoc fallback.
- `ARCHITECTURE.md:322` settles the budget doctrine in advance: "at P1 the default is rules,
  and if an LLM is opted into, the user has knowingly bought latency."
- The pipeline already enforces the budget race, routes any throw/timeout to raw (never loses
  text), re-checks cancellation post-cleanup, records the cleanup span on every answer, and
  passes `dictionary: []` by design (`Sources/VoccaCore/DictationPipeline.swift:316-367`).
- Composition root wires `cleanup: ShippingCleanup.make()` hardwired
  (`Sources/VoccaBootstrap/AppBootstrap.swift:294-303`); **no selection mechanism exists**
  (the ASR picker's own state is in-memory and unwired; zero `UserDefaults`/`AppStorage`
  anywhere in the repo; persistence is deferred to C14).
- Enforcement that must not break: the H8 lint lets exactly **one** file name `URLSession`
  (`Tests/HarnessTests/ModelDownloaderSeamTests.swift:61-69` — a second file needs a reviewed
  table edit, per the FileManager per-module precedent); the zero-network probe's module
  coverage cross-check requires anything new to be driven from `exerciseDefaultConfiguration()`
  (`ZeroNetworkTests.swift:578-592`); **loopback counts as a network connection** — an Ollama
  call on the default path fails the build (`interposer.c:70-73`); test floor 958 must be
  raised in the same commit as new tests (`Scripts/test-with-floor.sh:963`).
- No Keychain usage exists in `Sources/` anywhere — a `Security` family would be the first,
  needing a one-file seam row in the H7 shape. No `LLM/` directory in `VoccaText` yet, but
  `ARCHITECTURE.md:128` plans it. No smoke steps for Ollama/BYOK/badge exist.

## Design tensions to resolve (open questions for the PRD)

1. **The 10 ms budget vs an LLM round-trip.** `cleanupBudget = .milliseconds(10)` is a private
   constant in the pipeline (`DictationPipeline.swift:108-113`) and the provider is cancelled at
   expiry. An LLM stage needs seconds. The architecture's own answer is "the user knowingly
   bought latency" (`ARCHITECTURE.md:322`); the PRD must pick the mechanism: a provider-declared
   budget, or a pipeline rule (network provider ⇒ larger budget). The chain shape (§11) means
   rules output is produced first and survives LLM failure, so the fallback is cheap.
2. **Selection mechanism with the settings surface deferred.** The Cleanup tab ships later
   (`deterministic-cleanup/prd.md:216-217`); the card's acceptance has no selection-UI item.
   Both rungs must be off by default. Options: a hand-edited JSON config in Application Support
   (the `dictionary.json`/`config.json` precedent, `ARCHITECTURE.md:554`) resolved once at
   launch (the `DictationEngineResolver` resolve-once shape), or test/smoke-only wiring until
   settings. Must not contradict "never silently re-enabled" (`ROADMAP.md:131`).
3. **Badge plumbing.** The widget store exists (`WidgetStateStore`/`WidgetStateReducer`); the
   badge is a static-per-launch property of the configured provider's `requiresNetwork`
   (`ARCHITECTURE.md:296`), rendered in the recording pill as ☁︎ with hover copy naming the
   endpoint (`PRODUCT_SPEC.md:250-264`), non-dismissable, reducer-tested with copy pinned
   byte-for-byte (the `EnginePickerCopy` precedent). No mechanism currently pushes the provider
   into the widget store.
4. **Ollama surface.** Default `http://localhost:11434`; model discovery (`/api/tags`) vs a
   configured model name; tuned cleanup prompt; streaming disabled (`CAPABILITY_ROADMAP.md:137`).
5. **Keychain.** BYOK key lives in the Keychain (`issue.md:11`); a `Security` one-file seam +
   lint row is new surface; ARCHITECTURE.md §13 storage list has no Keychain entry and should
   be amended in this unit.

## Affected areas

`VoccaCore` (budget mechanism if pipeline changes), `VoccaText` (new `LLM/` dir: Ollama
provider, BYOK provider, chain, HTTP transport, Keychain store), `VoccaUI` (badge state +
copy), `VoccaBootstrap` (selection + wiring), `VoccaNetworkProbe` (drive the new surface with
fakes; zero-network must stay), seam lints (URLSession table amendment, new Keychain row),
`SMOKE_CHECKLIST.md` (new founder steps), test floor raise.

## Ambiguities / contradictions flagged (not papered over)

- C5's PRD says the seam's `dictionary` field is "declared, not read" and the pipeline passes
  `[]` — an LLM rung will not receive the user dictionary through `CleanupContext`; decide
  whether the chain passes it to the rules stage only (its own store) and the LLM stage stays
  dictionary-free.
- `CAPABILITY_ROADMAP.md:140` lists per-mode provider selection as a C6 deliverable, but the
  C5 PRD (written after) defers it to C6/C11 — with `SessionMode` currently `.dictation`-only
  in the pipeline's usage, per-mode selection is best deferred to C11; flag it as an explicit
  scope cut in the PRD.
- The H8 lint's "one entry, nothing else ever joins it" comment predates I2's amendment naming
  the BYOK client; the table edit is therefore a reviewed amendment (the FileManager precedent),
  not a weakening — the PRD must say so.
- No dependency needed: Foundation `URLSession` on macOS 15 suffices; no new package.

## Phase / scope placement

Phase P1 (week 6–7 slot). Dictation-first, local-first, open-core: Ollama is local; BYOK is
opt-in, Keychain-stored, badged, off by default; nothing cripples the local core; the
zero-network release blocker stays green.
