# Card: feat/kokoro-binding

> Inline brief — no GitHub issue exists (`gh issue list` → empty; Issues are empty for
> `haqaliz/vocca`). Source: the `kokoro-voice-output` record + handoff of 2026-09-12
> (the recorded follow-on card, `docs/STATUS.md`).

## Brief

Bind **Kokoro-82M** behind the shipped `SpeechSynthesizer` seam (C9's second half,
`CAPABILITY_ROADMAP.md:238-253`): the runtime decision recorded in `ARCHITECTURE.md:706`
(C/C++ shim via the reserved `VoccaBridge` vs ONNX/CoreML on the ANE vs bundled MLX) is
**made here, not deferred again** — the unit's first job is a research-grounded choice, then
the binding ships test-first with the phonemizer (espeak-ng) provisioned as the hidden cost
of every option.

Acceptance (the parameterized suite from `kokoro-voice-output` — one entry joins it):
known text → non-empty audio of pinned plausible duration; **cancellation halts ≤50 ms**;
cancel-and-re-invoke safe; time-to-first-audio measured and **compared against the system
renderer's recorded ~178.8 ms baseline** (the P3 ≤300 ms budget, recorded never gated).
The Kokoro engine joins the zero-network probe; the model provisioning follows the C2 store
pattern (download → verify → marker; the manifest ships in-repo); the phonemizer (espeak-ng
or equivalent) is provisioned locally with its own verify step; the default configuration
stays zero-egress.

Caveat: the runtime decision is genuinely open — the options differ in dependency weight
(VoccaBridge C shim vs CoreML conversion vs MLX), build risk, and phonemizer coupling; the
record must name the tradeoffs as decided, not as vibes. The P3 gate stays uncleared; TTFA
and the P3 budget remain recorded, never gated.