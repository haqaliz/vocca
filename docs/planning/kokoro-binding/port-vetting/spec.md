# Spec: port-vetting

> Aspect of `kokoro-binding` (C9 second half). Source: `docs/planning/kokoro-binding/prd.md`
> (R1/R2 + the 2026-09-14 vetting). The vetting evidence is in
> `docs/planning/_card/understanding.md`.

## Problem slice

The dependency decision is made (Jud/kokoro-coreml) but must be **pinned as a fact, not a
preference**: license, model provenance, phonemization, cancel semantics, toolchain — then
the dependency lands in `Package.swift` and CI can build it.

## In-scope

- The vetting record: license (done — Apache-2.0 LICENSE verified verbatim, both repos),
  model provenance (`kokoro-models.tar.gz` @ `models-2026-03-23`), phonemization (bundled
  English G2P + BART fallback — the Misaki correction), cancel semantics (per-sentence
  `synthesize` — R1b verified), toolchain (`swift-tools-version: 6.2` — the CI bump).
- `Package.swift`: the `KokoroCoreML` product dependency for `VoccaSpeech`, pinned
  `.upToNextMinor(from: "0.11.2")`; `VoccaBootstrap` gains the `VoccaSpeech` target
  dependency. Our package's own tools-version stays 6.0.
- CI: `XCODE_MAJOR: "16" → "26"` in `.github/workflows/ci.yml` (verified: the macos-15
  runner image ships Xcode 26.0.1–26.3; the glob `Xcode_26*.app` resolves to 26.3).
- A provenance pin test (test-first): Package.swift must declare the kokoro-coreml package
  URL and the `VoccaSpeech → KokoroCoreML` product edge; VoccaBootstrap must depend on
  VoccaSpeech.

## Out-of-scope

- No engine code (`engine-binding`'s job), no manifest/provisioning (`provisioning`'s job),
  no record edits to STATUS/CLAUDE.md/ARCHITECTURE.md (they ship with `provisioning`; the
  vetting corrections are already recorded in `_card/understanding.md` + this PRD).

## Acceptance (test-first)

1. A new test (e.g. `KokoroDependencyTests`) parses `Package.swift` and asserts: the
   kokoro-coreml package URL is declared, `VoccaSpeech`'s target dependencies include the
   `KokoroCoreML` product, and the `VoccaBootstrap` target depends on `VoccaSpeech`.
   **RED first** — the test fails against the current manifest, then the Package.swift
   edits land, then it passes.
2. `XCODE_MAJOR` is `"26"`; the headless CI job runs the full suite on the new toolchain
   (the CI run is the proof; a wrong glob fails loudly via the existing error path at
   `ci.yml:76-82`).
3. The suite stays green at the 1949 floor (no test-count change expected in this aspect
   beyond the provenance pin).

## Dependencies / sequencing

- First aspect of the unit (everything else needs the dependency to resolve).
- The engine-binding aspect compiles only after this lands.

## Open questions / risks

- The version pin `.upToNextMinor(from: "0.11.2")` rides 0.x semantics (minor = breaking);
  the BART dep comes transitively (`from: 0.4.0` per the port's manifest). A silent port
  update breaking the binding surfaces in the engine-binding suite, not here.