# feat/coding-agent-handoff — inline brief

No GitHub issue filed; the source is the `vocca-next` handoff (2026-09-30).

## Brief

Build C13's last P4 deliverable: voice → a coding agent session seeded with the active
project as context (ROADMAP.md:239; remaining-machinery list CAPABILITY_ROADMAP.md:551).
It is the thinnest-specified piece left — no PRD exists; write the design pass first, since
a stateful agent session does not fit the one-shot describe/invoke tool-call shape. Follow
the shell-provider precedent: an ActionProvider behind the shared gate/audit machinery,
enablement default off, a fixed-argv sentence that describe and invoke share, and the D2
honesty language — a child's egress is unprovable, so the default configuration must still
spawn nothing. Tests first: a stub agent asserts refusal-without-approval by attempting the
call, audit reconstruction of every executed handoff, context never leaves the machine
without its grant, and a PROBE-CODING-AGENT row inside the zero-network interposer
(spawnsSubprocess=false). Any G5 re-anchor is deliberate, never edit-to-match.

## Labels (proposed)

feat, P4, C13