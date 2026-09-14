# Card: feat/kokoro-binding (implementation unit)

> Inline brief — no GitHub issue exists (`gh issue list` → empty; Issues are empty for
> `haqaliz/vocca`). Source: the merged PRD-gate unit (`docs/planning/kokoro-binding/prd.md`,
> PR #35, merged 2026-09-13) + `docs/STATUS.md:13-17` (the recorded follow-on) +
> `ARCHITECTURE.md:706` (RESOLVED 2026-09-12).

## Brief

Implement **Kokoro-82M** behind the shipped `SpeechSynthesizer` seam — C9's second half
(`CAPABILITY_ROADMAP.md:238-253`), the recorded follow-on to `kokoro-voice-output`. The
runtime decision is **already made** (four founder-ratified choices, 2026-09-12): CoreML/ANE
via a Swift port, **Jud/kokoro-coreml** (vetted at the plan gate), provisioning via **DI from
the composition root** (C2 store reused unchanged), **one voice (af_heart)**. The unit's
**first step is the vetting gate**: license (Apache-2.0 expected, verified against the repo's
LICENSE file), model-byte provenance (HF repo + digests pinned from the ACTUAL bytes), the
phonemization mechanism (Misaki G2P, verified against the actual API), and per-sentence
cancel/chunk semantics (verified against the port's code — a port that cannot interrupt per
sentence re-opens the pick; mweinbach's packages are the recorded alternates).

Acceptance (the parameterized suite from `kokoro-voice-output` — one entry joins it):
`KokoroEngine` identity `"kokoro-82m"`, voiceName from plain data; known text → non-empty
audio of pinned plausible duration; **cancellation halts ≤50 ms** wall-clock with zero chunks
after + safe re-invoke (the SystemSynthesizer generation-tagged flag pattern; the contract
must NOT depend on the port's streaming shape — baseline is one render per sentence, cancel
between calls, PRD R1b); **time-to-first-audio measured warm and compared against the system
renderer's recorded ~178.8 ms baseline** (the P3 ≤300 ms budget, recorded never gated;
cold-load cost is a provisioning/prepare fact, never speak latency). The Kokoro engine joins
the zero-network probe (construct + empty-speak + cancel; **init pure-local** — no model
load/download in init); provisioning follows the C2 store pattern (download → verify →
marker; TTS manifest + af_heart artifact with digests pinned in-repo from actual bytes; the
port's own downloaders never run — no URL is ever handed to the port); the default
configuration stays zero-egress. Lints: a new Kokoro-runtime family lint (one permitted file —
`VoccaSpeech/Kokoro/KokoroEngine.swift` — planted-violation + comment-strip controls); no new
URLSession file; AVFoundation expected-set row only if AVFAudio is touched. Floor 1949;
the unit's tests ratchet it in the same commit.

## Aspect decomposition (from the PRD)

| Aspect | Boundary |
|--------|----------|
| `port-vetting` | License, provenance, phonemization, cancel/chunk semantics verified against the port's code; `Package.swift` lands the dependency; the record. |
| `engine-binding` | `KokoroEngine` (one file, the seam conformance), the family lint, the env-gated suite entry, the probe wiring — test-first. |
| `provisioning` | The TTS manifest + af_heart artifact + digests, the bootstrap's store-provision + inject path, the port-downloader suppression pin, the record (STATUS/CLAUDE.md/ARCHITECTURE.md/SMOKE 129/floor). |

## Caveats (binding)

- The P2 and P3 gates stay **uncleared**; this unit builds ahead of them — the recorded
  posture (`docs/STATUS.md:110-111`), not a drift. TTFA stays recorded, never gated; no
  Kokoro number exists until the engine runs.
- The port is young/single-maintainer (2026-03, ~10 stars): the vetting gate records the
  dependency's state honestly; a port that fails the vetting re-opens the pick.
- The port's own networking surface must never run (zero-network default); the probe + the
  seam family lint are the enforcement.
