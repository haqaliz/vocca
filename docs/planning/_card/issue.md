# Issue card — warm-start-streaming

**Source:** inline brief (no GitHub issue exists; `gh issue list` is empty; the id is a
descriptive slug, per `vocca-begin-fast`).

**Type:** `feat` · **Branch:** `feat/warm-start-streaming/aliz`

## Brief

Build the deferred C7 remainder: warm start (ASR model pre-warmed at launch and after idle
via the `ASREngine.prepare()` hook, so first-dictation-after-launch lands within 20% of
steady-state) plus widget-only streaming partials (partials rendered in the widget only, the
target app untouched until final injection, zero `TextInjector` calls before key-up). The
first slice is warm start; widget streaming is the second in the same unit.

Acceptance tests first: a warm-start test asserting first-dictation-after-launch within 20%
of steady-state over an injected clock; a streaming test asserting zero injection calls
before key-up across the closed route set; a seam test asserting `ASREngine`'s optional
`supportsStreaming` degrades gracefully (whisper batches, Parakeet streams) with no caller
branching on engine identity.

**Caveat:** `ARCHITECTURE.md:630` open question 2 — speculative final-vs-batch equivalence
is unmeasured, so keep the streaming slice's correctness claim to the widget guard and
record, never claim a latency number CI didn't produce; the real numbers wait for the
founder's `VOCCA_LATENCY_BENCH` run (`SMOKE_CHECKLIST.md` steps 71–72).
