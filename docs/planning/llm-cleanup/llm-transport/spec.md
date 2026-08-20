# Spec — llm-transport

Aspect of `llm-cleanup` (C6) · `docs/planning/llm-cleanup/prd.md`
Requirements: **M2** (owned here).
Depends on: nothing in C6 (the transport is provider-independent; it is the first
`VoccaText/LLM/` file).

## Problem slice

`ARCHITECTURE.md:16` (I2) confines network to two named types: `ModelDownloader` (shipped) and
**"the BYOK client (C6, unnamed here)"** — this aspect names it. The H8 lint permits exactly
one file in `Sources/` to name `URLSession` (`ModelDownloaderSeamTests.swift:61-69`); the
second network type needs a second permitted file, the lint table amended as a reviewed edit
(the FileManager per-module precedent, `InjectionSeamBoundaryTests.swift:908-916`), and every
decision above the seam, tested over an injected transport (the `StubTransport` precedent,
`ModelTransportTestDoubles.swift:34-153`).

## In scope

1. **`LLMTransport` seam + vocabulary in `Sources/VoccaText/LLM/`.** `LLMRequest` (URL,
   headers, body Data — no domain meaning), `LLMResponse` (status, body Data), one method
   `complete(_:) async throws -> LLMResponse`. Typed errors: `.unreachable` (URLError: cannot
   connect), `.serverStatus(Int)` (non-2xx, body deliberately **not** carried in the error),
   `.invalidResponse`, `.cancelled` mapped to `CancellationError`.
2. **`DefaultLLMTransport`** — the second file in `Sources/` permitted to name `URLSession`:
   `URLSession.data(for:)` (JSON-sized bodies, no streaming), session injectable, translation
   only. No decisions: no retry, no timeout of its own (the caller's budget race owns time).
3. **The H8 table amendment.** `filesPermittedToNameURLSession` gains
   `"VoccaText/LLM/DefaultLLMTransport.swift"`; the "one entry, nothing else ever joins it"
   comment is corrected to the two-types reality (I2); the two-sided pin, tree-wide scan,
   planted-violation control, and comment-strip rules all keep working over the new set.
4. **`StubLLMTransport`** test double — an actor with a `Mode` enum
   (`happyPath(response:)` / `failsUnreachable` / `serverStatus(Int)` / `malformedResponse` /
   `hangs(gate:)`), a recorded-requests ledger (request-shape assertions), and an async gate
   (the `StubTransport` shape).

## Out of scope

- Request **shaping** for Ollama or BYOK (their aspects own it — the providers build
  `LLMRequest` from their config).
- Timeouts, retries, backoff — the caller's budget race is the only timeout
  (`prd.md` M1; `ARCHITECTURE.md:515`).
- The key: the BYOK provider's `Authorization` header is built above this seam
  (`byok-provider`); the transport never knows a key exists.

## Isolation / honesty decisions

- **Errors carry no body.** A 401 body, an HTML error page, a malformed JSON — none of it
  rides in the error the caller can log, so a server echo can never leak a key the provider
  put in a header. `.serverStatus(Int)` is deliberately body-less.
- **The transport is executed by nothing in CI.** `URLSession` works on a hosted runner in
  principle, but no test dials the real network (the repo has no network tests and the
  zero-network probe would flag any `connect(2)` in the suite's process). Every decision is
  above the seam; `DefaultLLMTransport` is smoke-verified on the founder's machine
  (`root-wiring` M10).
- **The lint amendment is reviewed, not relaxed.** The planted-violation control stays: a
  third `URLSession` naming file anywhere fails the suite.

## Acceptance criteria (tests written first)

Failing XCTests in `Tests/HarnessTests/` — `LLMTransportTests.swift`:

- B1 **Seam shape.** `LLMRequest`/`LLMResponse`/`LLMTransport` exist; a stub conformer round-trips.
- B2 **DefaultLLMTransport translates.** Over an injected `URLSession`-backed... (see note) —
  at minimum: the happy path passes URL/headers/body through verbatim; `.cancelled` maps to
  `CancellationError`; connection failure maps to `.unreachable`; non-2xx maps to
  `.serverStatus(code)` with no body in the error. (If the real adapter cannot be driven
  headlessly, the decisions above it are asserted via the stub; see Open questions.)
- B3 **H8 table.** The lint's permitted set has exactly the two entries; the two-sided pin
  passes both ways (the permitted file names `URLSession`; nothing else does); a planted
  third file is detected; doc comments may name the family.
- B4 **StubLLMTransport drives request-shape tests.** Recorded requests assert URL, method,
  headers, body; the gate modes arm/hang/release deterministically (the `StubTransport` gate
  precedent).
- B5 **Boundary discipline.** Full suite green under the floor; Swift 6 clean; Apache headers;
  no new dependency (Foundation only).

## Dependencies / sequencing

- Second in the rough shape (`prd.md:273-276`): the transport precedes both providers.
- Precedents: `ModelTransport`/`DefaultModelTransport`
  (`VoccaASR/Models/ModelTransport.swift:41-64`, `DefaultModelTransport.swift:36-100`),
  `ModelDownloaderSeamTests.swift` (the lint), `StubTransport`
  (`ModelTransportTestDoubles.swift:34-153`).

## Open questions / risks

- **Can `DefaultLLMTransport` be tested headlessly?** The repo never dials real network in
  the suite. Options: (a) drive it over an injected `URLSession` with a stub `URLProtocol` —
  new to the repo, adds a test-only dependency on the transport's internals; (b) assert the
  decisions above it via `StubLLMTransport` and leave the real adapter to the founder's smoke
  run (the `SystemPasteboard` precedent). Lean (b): the adapter is translation with no
  decisions, and (a) would build machinery no later aspect reuses.
- **Body in errors:** decided no (isolation above) — a reviewer should confirm the debugging
  cost is acceptable for `malformedResponse` diagnosis (the provider can log status + length,
  never content).
