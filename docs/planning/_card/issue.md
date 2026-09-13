# Card: feat/kokoro-voice-output

> Inline brief — no GitHub issue exists (`gh issue list` → empty; Issues are empty for
> `haqaliz/vocca`). Source: the handoff of 2026-09-12.

## Brief

Build C9, the first P3 capability: the SpeechSynthesizer seam with two real implementations
(CAPABILITY_ROADMAP.md:238-253). VoccaSpeech is the last placeholder module; this unit gives
it its purpose. Shipped test-first: the `SpeechSynthesizer` protocol (`speak(String) ->
AudioStream`, cancellation as a first-class operation — C10's barge-in depends on halting
mid-utterance), **Kokoro-82M** as the first implementation (voice selection + rate control),
**macOS AVSpeechSynthesizer** as the shipped second (proves the seam, zero-download fallback),
and sentence-level chunking so speech begins before the full reply is synthesized.

Acceptance tests written first: both implementations run the same parameterized suite —
known text produces non-empty audio of plausible duration; **cancellation halts output within
50 ms**; safe to cancel and immediately re-invoke without deadlock or audio-session
corruption; time-to-first-audio benchmarked with a ≤300 ms assertion (P3's metric,
ROADMAP.md:209).

Caveat: the P2 gate is not cleared — the matrix feature was closed by founder decision
2026-09-12 (docs/STATUS.md), so this builds ahead of the gate with the record naming that
posture; and Kokoro is an external model dependency (Apache-2.0) — the download/verify path
follows the C2 model-provisioning pattern, and the zero-network default must hold with
AVSpeechSynthesizer as the shipped fallback.