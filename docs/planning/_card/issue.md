# Card: feat/turn-taking-barge-in

> Inline brief — no GitHub issue exists (`gh issue list` → empty; Issues are empty for
> `haqaliz/vocca`). Source: the `vocca-next` handoff (2026-09-15) + `CAPABILITY_ROADMAP.md`
> C10 entry + `ARCHITECTURE.md` §12 (the P3 voice-loop design).

## Brief

Build **C10 — streaming turn-taking + barge-in** (`CAPABILITY_ROADMAP.md:269-285`): the P3
"*smarter than SKI*" capability. The `SpeechSynthesizer` seam is complete (C9, shipped
2026-09-14) — playback/ducking is this unit's concern (`VoccaAudio/Playback/`, reserved at
`ARCHITECTURE.md:107`), as are the `VoiceActivityDetector` and `TurnDetector` seams
(`ARCHITECTURE.md:262-263`: Silero VAD + EnergyVAD; Parakeet EOU 120M + SilenceThreshold).

The unit's **first step is a port-vetting gate for Silero VAD** (license, provenance,
swift-tools-version, artifact shape) in the C2-store provisioning pattern the
`kokoro-binding` unit just established; the EOU comes from FluidAudio (already a dependency,
the Parakeet precedent). The barge-in signal path is budgeted to the 200 ms gate
(`ARCHITECTURE.md:571-578`): VAD fires → `SessionActor` receives interrupt →
`synthesizer.cancel()` (≤50 ms, the shipped contract) → output ducked and stopped →
interrupted reply discarded → capture already running, so the interrupting words are already
in the buffer (capture is continuous, never started at interrupt time).

Acceptance, written first (per the unit's spec): a recorded conversational set with
human-labelled turn boundaries asserting **≥95% correct turn commitment**, scored with
**false cutoffs weighted 5× worse than late commits**; a barge-in test injecting user speech
during synthetic TTS playback asserting **halt within 200 ms** with the interrupting audio
fully captured; an echo test playing known TTS output through a loopback asserting **zero
transcription of it**; **hold-to-talk remains available forever** as the escape hatch — when
endpointing misjudges, the user's finger is always the ground truth. Echo rejection is
verified on **speakers, not headphones** (`ARCHITECTURE.md:580-586`) — a SMOKE step, never CI.

Lints/seams expected: two new seams with two implementations each; no new network surface
(zero-network default, permanent release blocker); the composition root wires the loop; the
env-gated real suite follows the `VOCCA_*` two-variable gate pattern; floor 1978 ratchets in
the unit's first commit.

## Aspect decomposition (from the PRD)

Pending — the PRD (this unit has no prior PRD-gate unit; the card is the only brief).

## Caveats (binding)

- The P2 and P3 gates stay **uncleared**; this unit builds ahead of them — the recorded
  posture (`docs/STATUS.md`, kokoro-binding entry), not a drift. Turn-commitment and
  echo numbers are **recorded, never gated**; the SMOKE steps are the only real
  executions.
- **Silero VAD provisioning is the nearest feasibility risk** — a Swift port must be
  vetted exactly as Jud/kokoro-coreml was (young/single-maintainer risk recorded, a port
  that fails the vetting re-opens the pick).
- **Full-duplex audio is the first realtime-path change since C1** — playback and capture
  concurrently in `VoccaAudio/Playback/` (reserved, empty today); CI cannot exercise the
  realtime conversation; every decision above the seam is tested there.
- The zero-network invariant and the ≤50 ms cancel contract are load-bearing inputs, not
  re-litigations: the cancel contract ships in C9 (`SpeechSynthesizer`), and nothing here
  may hand a URL to any port.