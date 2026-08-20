# Spec — byok-provider

Aspect of `llm-cleanup` (C6) · `docs/planning/llm-cleanup/prd.md`
Requirements: **M4** (owned here) + **M5** (owned here).
Depends on: `llm-transport` (the seam + stub). Runs in parallel with `ollama-provider`.

## Problem slice

Rung 3 of the cleanup ladder (`ROADMAP.md:120`): the user's own cloud endpoint, egress
**Yes — badged at point of use**, off by default, key never in a log. This is the first
`Security`/Keychain code in the repo (no `SecItem` anywhere in `Sources/` today) — the seam
and its lint row are new surface, and the key-hygiene acceptance is the unit's sharpest edge
(`CAPABILITY_ROADMAP.md:142`).

## In scope

1. **`KeyProvider` seam + `SystemKeychainKeyProvider`** in `Sources/VoccaText/LLM/` —
   `func key() throws -> String?` (nil = absent). The system adapter is the **one file in
   `Sources/` permitted to name the `Security`/`SecItem`/`kSec` family** — a new seam row in
   the H7 shape (`InjectionSeamBoundaryTests`): the family table, the one-file-per-seam rule,
   the two-sided pin, and a planted-identifier negative control. Item
   `dev.vocca.Vocca.byok-key` in the default keychain (`prd.md` Data Model). The adapter is
   translation only — executed by nothing in CI.
2. **`BYOKCleanupProvider`** — a `CleanupProvider` conformer (struct, `Sendable`):
   `identity = ProviderIdentity(id: "byok-cleanup", displayName: "BYOK")` (reserved at
   `ProviderIdentity.swift:31`), `requiresNetwork = true` **declared**, `budget = .seconds(5)`
   declared, `clean(_:context:)`: reads the key via the injected `KeyProvider` (absent ⇒
   throw `.keyUnavailable` — never a prompt, never a silent skip), builds the OpenAI-compatible
   chat-completions request (`Authorization: Bearer <key>`, v1 contract, `prd.md` Risks),
   calls the injected `LLMTransport`, parses `choices[0].message.content`, returns the text.
3. **Failure taxonomy, all throwing** (the chain degrades): key absent, keychain
   locked/unreadable, unreachable, **401/403** (mapped distinctly; never a retry loop), other
   server status, malformed/empty/whitespace content.
4. **Key-hygiene acceptance**: a stub key provider returns a sentinel value; every failure
   path runs with captured logs + error descriptions; the sentinel appears in **none** of
   them. The request header *does* carry it (asserted) — the point is the logs/errors, not
   the wire.

## Out of scope

- The fallback (the chain owns degrade-to-rules).
- Config loading — `cleanup-config` builds the provider; this aspect takes `endpoint: URL`,
  `model: String?`, `keyProvider`, `transport` at init.
- Multiple endpoints/profiles, key rotation UI, any write path into the Keychain — a read
  seam only; the key gets there by the user's own means (`security add-generic-password`) or
  the future settings surface.
- The egress badge (its own aspect) — the provider only declares `requiresNetwork`.

## Isolation / honesty decisions

- **The Keychain is a seam like every other system family.** One file names the family; the
  provider holds a `KeyProvider` reference; tests inject a stub with a sentinel. The real
  adapter's first execution is the founder's BYOK smoke step (`root-wiring` M10).
- **Errors never carry the key or the body** (the transport already keeps bodies out of
  errors, `llm-transport` B2); the provider's own errors are key-free vocabulary.
- **401/403 is a first-class outcome**, not a retry trigger: a wrong key is a user error, and
  a retry loop would hammer the user's endpoint (`prd.md` M4 fix).
- **Off by default is structural**: nothing constructs this provider unless the config
  selects `byok` (`cleanup-config`), and the zero-network probe's default path never sees it.

## Acceptance criteria (tests written first)

Failing XCTests in `Tests/HarnessTests/` — `BYOKCleanupProviderTests.swift` and
`KeychainSeamTests.swift`:

- B1 **Identity, network, budget.** `"byok-cleanup"`; `requiresNetwork == true`; 5 s.
- B2 **Request shape.** Recorded request: configured endpoint, `Authorization: Bearer
  <sentinel>`, chat-completions JSON (`model`, `messages` with the system instruction + the
  transcript).
- B3 **Happy path.** `choices[0].message.content` yields the cleaned text.
- B4 **Key absent** ⇒ `.keyUnavailable`, no request recorded, no retry.
- B5 **Keychain locked/unreadable** ⇒ throw, no request recorded.
- B6 **401/403** ⇒ distinct throw, no retry, no key in the error.
- B7 **Every other failure mode throws** — unreachable, other status, malformed, empty,
  whitespace.
- B8 **Key hygiene.** Sentinel absent from every captured log line and every error
  description across all failure paths (the logged and thrown surface is asserted complete).
- B9 **The Keychain seam row.** The family table has exactly one permitted file
  (`VoccaText/LLM/SystemKeychainKeyProvider.swift`); two-sided pin passes; a planted
  `SecItem` in any other `Sources/` file is detected; `kSec`/`SecItem` prefixes covered.
- B10 **Boundary discipline.** Full suite green under the floor; Swift 6 clean; Apache
  headers; no new dependency (Security is a system framework).

## Dependencies / sequencing

- `llm-transport` green first. Parallel with `ollama-provider` (same shape, independent).
- Precedents: the H7 seam tables (`InjectionSeamBoundaryTests.swift:244-303` — the family
  table shape), `SystemPasteboard` (adapter = translation, executed by nothing),
  `StubTransport` (stub + gate), `ProviderIdentity.swift:31`.

## Open questions / risks

- **Generic-password vs internet-password item class.** `kSecClassGenericPassword` for
  `dev.vocca.Vocca.byok-key` (no server host to key an internet item on). The plan pins the
  search/query constants.
- **The founder's key entry path** is out of scope (see above) — the smoke step documents
  the one-liner, and the future settings surface writes it.
- **OpenAI shape is the v1 contract** (`prd.md` Risks): provider-agnostic means *an* agreed
  shape; a non-OpenAI endpoint is a follow-on, not this unit.
