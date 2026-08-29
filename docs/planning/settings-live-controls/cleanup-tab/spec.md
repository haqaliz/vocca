# Aspect 5: `cleanup-tab`

**Merge order: last — the severable tail.** Depends on aspect 2. May become its own branch
without weakening anything merged before it.

## Problem slice

Two defects in one surface. `AppBootstrap.swift:938` passes `cleanupSummary: { ("Built-in rules",
nil) }` — a literal. A user on Ollama or BYOK sees the Cleanup tab report **"Built-in rules"** with
no endpoint, while the widget's egress badge correctly shows the cloud marker.
`SettingsView.swift:186` calls the egress line *"the point of this tab … where they can check
before it ever does"*, and today that line can never appear. And the choice itself is still a
hand-edited `cleanup-config.json` (`SettingsCopy.cleanupNotEditable`).

`PRODUCT_SPEC.md:264-274` specifies the surface, including: *"Selecting the cloud rung shows a
one-time confirmation naming exactly what gets sent. Not a checkbox buried in a paragraph — a
dialog the user has to read."*

**User outcome:** scenario S3 — the person checking, before they dictate something sensitive,
whether anything leaves their Mac gets a true answer.

## In scope

- **R1** The summary reports the **resolved** provider's name and endpoint (subsumes F3), so the
  tab and the egress badge agree.
- **R2** The three rungs as an editable choice, written to `cleanup-config.json` — the same file
  the resolver reads, never a second copy that drifts.
- **R3** **The one-time confirmation dialog** naming exactly what gets sent, on selecting the cloud
  rung. A must-have, never traded away.
- **R4** The BYOK key continues to live in the Keychain via the existing seam; the config file
  never holds it.

## Out of scope

- Changing the cleanup providers themselves, the chain's degrade behaviour, or the 5 s budget.
- Making the LLM budget configurable (deliberately skipped as C6's N1).
- Any claim that LLM cleanup beats rules — unmeasured, and `prd.md`'s "quality not implied" holds.

## Acceptance criteria (tests first)

1. The summary is derived from the resolved provider, not a literal: with a stubbed BYOK provider
   the tab reports its endpoint; with rules it reports no endpoint. **This test fails today.**
2. A written choice round-trips through `cleanup-config.json` and is what the resolver reads.
3. R3: selecting the cloud rung requires the confirmation before the choice is persisted; declining
   leaves the previous choice intact.
4. Copy pinned byte-for-byte to `PRODUCT_SPEC.md:264-274`, including the ⚠️ line.
5. **The zero-network probe stays green** with the default configuration, and its `egress=none`
   report is unchanged — the permanent release blocker (`ROADMAP.md` principle 2).
6. The egress badge stays non-dismissable; no test may relax it.

## Risks

- This aspect touches the one surface `ROADMAP.md` principle 2 says must survive an audit of the
  actual code paths. A regression here is a positioning-fatal risk (R11 in the roadmap register),
  not a UI bug. The probe is the gate.
- Writing the config from the UI while the resolver has already resolved once means the change
  applies at the next resolve. Say so in the UI rather than implying immediacy.
