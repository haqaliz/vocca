# Card: feat/speculative-asr

> Inline brief — no GitHub issue exists. Source: `vocca-next` handoff, 2026-08-31.

## Brief

Build the last unshipped half of C7 (docs/technical/CAPABILITY_ROADMAP.md C7 amendment):
the speculative pre-key-up ASR feed, the real supportsStreaming engine adapters (Parakeet
streams, whisper.cpp batches), and re-warm-after-idle — in that order, test-first.

Acceptance:

- The ARCHITECTURE.md open question 2 measurement first (final-on-key-up equals batch
  transcription of the same fixture buffer — a go/no-go, since the latency win must not be
  bought with accuracy).
- The existing p50 ≤ 400 ms / p95 ≤ 800 ms benchmark harness and the zero-injection-before-key-up
  guard must pass with the feed live.
- The feed must refuse sub-0.3 s buffers (the short-press failure).
- Warm-start re-warm-after-idle must respect the 20%-of-steady-state bound.

Caveat: both streaming adapters depend on external engine behavior (FluidAudio Parakeet
streaming, whisper.cpp batching) — verify what the SDKs actually expose before designing the
seam around them, and state plainly that no real engine has streamed yet.