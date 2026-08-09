# bridge-integration — spec

> Aspect of `second-asr-engine` (C3). PRD: `docs/planning/second-asr-engine/prd.md` (M2).

## Problem slice

C3's riskiest unknown, de-risked first: whisper.cpp must resolve, build, and link inside
this package — pinned, reproducible, and cheap in CI. Everything else depends on this
binary target existing and being verified once.

## In-scope

- Add the whisper.cpp **v1.9.2 XCFramework binary target** to `Package.swift`
  (`.binaryTarget` with remote URL + SHA-256 checksum), consumed by `VoccaASR`.
- Compute and pin the checksum from the downloaded release artifact; verify the macOS
  slice set (arm64 + x86_64) before pinning.
- A spike test: package resolves, `swift build` succeeds on a macOS runner (no GPU —
  Metal shaders embed at build time; CPU fallback is the supported CI mode), and a
  trivial C-ABI round-trip (module import + `WHISPER_SAMPLE_RATE` constant read)
  compiles and runs headlessly.
- License/attribution note for the vendored artifact (MIT) recorded where the
  `THIRD_PARTY`/NOTICE surface lives.

## Out-of-scope

- Any engine logic, model lifecycle, or picker — those are sibling aspects.
- Building whisper.cpp from source; WhisperKit.

## Acceptance criteria (test-first)

1. `Package.swift` pins the binary target by URL + checksum; a test
   (`PackageManifest`/`PackageRootConsolidationTests` pattern) asserts the dependency
   is present and that no source target links the C API directly.
2. A headless spike test imports the `whisper` module and asserts the constant
   `WHISPER_SAMPLE_RATE == 16000` — the C-ABI line is proven on any machine.
3. `Scripts/test-with-floor.sh` builds the package on a clean checkout with the new
   dependency (CI and local parity).
4. The checksum is verified from the downloaded artifact, not copied from a doc (the
   research found stale/partial checksums in the wild).

## Dependencies / sequencing

First aspect — nothing depends on it; everything else does. Must land before
`whisper-engine`.

## Open questions

- Exact checksum of `whisper-v1.9.2-xcframework.zip` — computed at implementation time
  (spike step), never guessed.
