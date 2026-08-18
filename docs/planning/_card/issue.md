# Issue Card — llm-cleanup

> No GitHub issue exists for this unit of work (invoked by slug via `vbf feat llm-cleanup`).
> Source of truth is the inline brief below, which comes from the `vocca-next` recommendation
> (handoff prompt) and the repo's own planning docs.

## Brief

Build C6 from `docs/technical/CAPABILITY_ROADMAP.md:132` — the Ollama and BYOK rungs behind the
existing `CleanupProvider` seam (rules is the only implementation today, and `ROADMAP.md:28`
requires two). Both rungs are opt-in: Ollama talks to a local endpoint with graceful fallback to
rules on absent/cold/slow/malformed responses; BYOK stores the key in the Keychain, is off by
default, never logs the key, and gains a persistent, non-dismissable egress badge in the widget
the moment text would leave the machine.

Caveats to respect:

- The P0/P1 gates (`docs/ROADMAP.md:100-104`, `docs/ROADMAP.md:142-146`) are running calendar
  gates, not cleared — this is the roadmap's own week-6/7 slot, so the 7-day daily-use log and
  the F2 recordings (`SMOKE_CHECKLIST.md` step 73) stay in parallel, unaffected.
- Zero network in the default configuration must be preserved: both new rungs are opt-in, and
  the zero-network dictation-cycle probe (permanent release blocker, `docs/ROADMAP.md:139`)
  must still pass.
- The real Ollama run and the badge's first appearance are smoke-check items on the founder's
  machine — CI is stub-only.

Acceptance tests come first, per the repo's test-first rule (`docs/technical/CAPABILITY_ROADMAP.md:13`):

1. A stubbed Ollama endpoint asserting correct request shape, timeout, and fallback to rules on
   every failure mode (absent, cold, slow, malformed response).
2. A BYOK stub asserting the key never appears in logs or crash reports.
3. The egress badge: a persistent, non-dismissable widget indicator whenever a cloud provider
   is active — appearing at the moment text would leave the machine, with a tested state
   reducer (no time-based dismissal).
4. The permanent release blocker: a full dictation cycle in the default configuration with a
   network interposer asserting zero outbound connections.

Phase: P1. Layer: AI cleanup (`CleanupProvider`, rungs 2–3). Scope: macOS-only, local-first,
dictation-first, open-core — BYOK is opt-in + badged + off by default; nothing cripples the
local core.
