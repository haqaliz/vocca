# First-run + permissions onboarding

## Brief

Build the P0 first-run + permissions surface, the last unshipped P0 deliverable
(`docs/ROADMAP.md:80`) and the design pass's highest-value unbuilt surface. The flow is
already spec'd in `docs/product/PRODUCT_SPEC.md` §6 (WELCOME → PERMISSIONS one at a time →
MODEL with skip → TRY IT → DONE, denial-never-a-dead-end, Accessibility-fatal `[Restart
Vocca]`) and `docs/technical/ARCHITECTURE.md` §13:589-603 — write the acceptance tests
first: a headless state machine over *injected* permission-status reads covering every
denial path and the restart requirement, copy pinned byte-for-byte against §6 (the
`BadgeCopy` precedent), the onboarding window driven through the existing
composition-root/preferences surface with the zero-network probe still green, and the
`TRY IT` step driving a real dictation into the window's own field once smoke-verified.

Caveat: TCC grants cannot happen in CI and `CGEvent.tapCreate == nil` is the Accessibility
check, so the adapters are seam-only and `docs/SMOKE_CHECKLIST.md` gains the real-machine
rows (grant → restart → dictate) — the suite proves the flow's decisions, the founder's
machine proves the prompts.

## Source

Inline brief from `vocca-next` handoff (no GitHub issue exists for this work).
Owner: `aliz`. Type: `feat`. Slug: `first-run-permissions`.