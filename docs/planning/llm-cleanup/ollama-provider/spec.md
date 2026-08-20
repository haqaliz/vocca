# Spec — ollama-provider

Aspect of `llm-cleanup` (C6) · `docs/planning/llm-cleanup/prd.md`
Requirements: **M3** (owned here).
Depends on: `llm-transport` (the seam + stub). Runs in parallel with `byok-provider`.

## Problem slice

Rung 2 of the cleanup ladder (`ROADMAP.md:119`): a local LLM via Ollama, egress "None", behind
`CleanupProvider` — with graceful degradation to the rules output on every failure mode
(absent, cold, slow, malformed; `CAPABILITY_ROADMAP.md:137`). Model discovery is deferred with
the Cleanup tab (PRD decision, `prd.md` M3); this unit takes endpoint + model from config.

## In scope

1. **`OllamaCleanupProvider` in `Sources/VoccaText/LLM/`** — a `CleanupProvider` conformer
   (struct over injected dependencies; `Sendable`): `identity = ProviderIdentity(id:
   "ollama-cleanup", displayName: "Ollama")` (`ProviderIdentity.swift:31` — the key is
   reserved), `requiresNetwork = true` **declared**, `budget = .seconds(5)` declared (M1),
   `clean(_:context:)`: builds the `/api/generate` request — `model`, `prompt` (tuned
   cleanup-not-creativity instruction + the transcript), `stream: false`
   (`CAPABILITY_ROADMAP.md:137`) — calls the injected `LLMTransport`, parses `{"response":
   "..."}`, returns the text.
2. **The tuned prompt** — a pinned constant (`CleanupPrompts.ollama`, byte-tested like the
   copy family): instructs cleanup-not-creativity, preserve meaning/names/numbers/identifiers,
   output only the cleaned text. Lives in `VoccaText/LLM/CleanupPrompts.swift` (or the
   provider file; the plan pins it — shared with `byok-provider`'s system instruction).
3. **Failure mapping, all throwing** (the chain degrades, `cleanup-chain`): unreachable,
   server status, malformed/empty/whitespace response — each a typed throw; **never** a retry
   loop, **never** a partial string.
4. **Stub-driven request-shape tests**: URL path `/api/generate`, JSON body fields, `stream:
   false`, the prompt prefix — asserted over `StubLLMTransport`'s ledger.

## Out of scope

- Model discovery (`/api/tags`) — deferred with the Cleanup tab (`prd.md` Out of Scope).
- The fallback itself — the chain (`cleanup-chain`) owns degrade-to-rules; this provider only
  throws honestly.
- Config loading — `cleanup-config` builds the provider from the config; this aspect takes
  `endpoint: URL` + `model: String` at init.

## Isolation / honesty decisions

- **Zero decisions in the transport; the provider owns them all.** Request building, JSON
  parse, error mapping — all headless-testable over the stub.
- **The provider is executed by nothing that dials real network in CI** — the stub stands in;
  the real Ollama run is a founder smoke step (`root-wiring` M10).
- **The 5 s budget is declared, not configurable** (`prd.md` N1 defers configurability).

## Acceptance criteria (tests written first)

Failing XCTests in `Tests/HarnessTests/` — `OllamaCleanupProviderTests.swift`:

- B1 **Identity, network, budget.** `"ollama-cleanup"` identity; `requiresNetwork == true`;
  5 s budget (the seam contract over the shipped provider).
- B2 **Request shape.** Recorded request: path `/api/generate`; body decodes to
  `{model, prompt, stream: false}`; the transcript text is in the prompt; the prompt begins
  with the pinned instruction.
- B3 **Happy path.** A stub `{"response": "cleaned text"}` yields the cleaned text.
- B4 **Every failure mode throws** — unreachable, server status, malformed JSON, missing
  `response` key, empty response, whitespace-only response; each asserted as a throw (the
  caller's decision, never the provider's truncation).
- B5 **Prompt byte-fidelity** — the pinned instruction constant matches the spec'd text
  byte-for-byte (the `EnginePickerCopy` rule).
- B6 **Boundary discipline.** Full suite green under the floor; Swift 6 clean; Apache header;
  no new dependency.

## Dependencies / sequencing

- `llm-transport` (seam + stub + H8 amendment) must be green first.
- Parallel with `byok-provider` (independent, same shape).
- Precedents: `ShippingRulesCleanupProvider` (`ShippingCleanup.swift:32-49` — the conformer
  shape), `StubTransport` (the stub shape), `ProviderIdentity.swift:31` (the reserved key).

## Open questions / risks

- **Prompt placement:** a shared `CleanupPrompts` namespace (both providers) vs per-provider
  constants — the plan pins one; BYOK's system instruction differs in framing (remote service)
  but shares the cleanup-not-creativity core.
- **Ollama's real response contract** (`{"response": "..."}` for `/api/generate`) is
  documented behavior; if the founder's real run shows a different shape (e.g. a `done_reason`
  variant), the parse is tuned there, not assumed here.
