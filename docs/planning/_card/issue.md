# Card: feat/intent-layer

> Inline brief — no GitHub issue. Source: the `vocca-next` recommendation (2026-09-22),
> itself grounded in the C13 slice records (`action-safety-spine`, `local-data-provider`,
> `mcp-protocol`, `stdio-transport`, `action-surface-wiring`).

## The unit

**C13 slice 6 of N: the intent layer** — the named remaining C13 machinery
(`CAPABILITY_ROADMAP.md:450-451`): utterance → tool call with correctly built arguments,
the "not confident" ask path that asks rather than guesses, and voice-triggered actions
feeding the shipped arm/confirm surface (the surface PRD's own words: "the voice path needs
the intent layer", `action-surface-wiring/prd.md:222`).

- The intent layer as a **new seam** in `VoccaCore` — local and deterministic first, no LLM
  in the OSS core, a pluggable seam for a stronger local model later.
- The **§8 escape-valve decision** this slice owes (the "next slice's conversation",
  `action-safety-spine/prd.md:338-344`): time-boxed trust / a never-silenceable blast-radius
  floor / decaying per-tool trust — decided here, with the never-silenceable floor asserted
  in a test.
- Voice-issued actions run through the existing gate → executor → audit round trip; every
  decision recorded.

**Acceptances, written first per repo test-first doctrine:**
1. A matched utterance yields a tool call with correct arguments on the stub server.
2. An ambiguous utterance yields the ask path with zero provider side effects on the call log.
3. Every voice-issued action lands in the audit store via the executor round trip — a guess
   never executes.
4. The §8 floor test: an outward-facing tool always confirms even with trust active.
5. PROBE drives the composed intent wiring inside the zero-network interposer.

**Caveat (record in the unit):** the classifier is local and deterministic first behind the
new seam; its real accuracy is unmeasurable in CI (env-gated real runs, the ASR-WER
precedent); the "not confident" threshold is a judgment call this PRD sets with the §8
decision, not a deferral.