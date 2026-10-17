# Source: inline brief (no GitHub issue)

`id` is a slug (`phrase-authoring-ui`); no GitHub issue was fetched — the repository
has **no issues at all** (`gh issue list --state all` returns empty). The brief below
is the source of truth, carried from the `vocca-next` handoff (2026-10-17).

## Brief

Build the first in-app authoring surface for voice actions. Today a phrase row is a
hand-edit of `intent-phrases.json` and the audit tools have no Actions-tab enablement
row (F-A), so the shipped action wedge (`ROADMAP.md:252`) is reachable only by the
founder. Add an Actions-tab **Phrases** section (add/edit/remove rows with a
provider+tool picker and validation) that persists through `IntentPhraseStore` — the
first production save caller — and render the audit tools as enablement rows defaulting
off, routed through the same store the resolver reads.

## Acceptance tests (written first)

- Saving a phrase resolves it on the next turn without a relaunch (the per-turn provider).
- A `dev.vocca.shell` target is refused at save with loud copy, mirroring the load refusal.
- An untouched file's bytes are unchanged and a `keywordFallback`/`version` field
  survives a save round-trip.
- A disabled tool stays uncallable, asserted by attempting the call.

## Phase placement

P4 (Actions/MCP), C13 — a reachability slice. The P4→P5 gate's only non-code leg is
"**≥10 external users** have run the action layer on their own machines"
(`ROADMAP.md:252`); it cannot be attempted while authoring requires a text editor.
No gate is cleared by this unit; this makes the gate attemptable, never passes it.

## Related lineage (merged PRs — no open work items)

- #62 `agent-home-detection`, #61 `mcp-intent-routing`, #59 `intent-provider-routing`,
  #58 `converse-intent-wiring`, #57 `composite-intent-resolver`, #48
  `phrase-intent-resolver` — the C13 voice/action lineage this unit makes authorable.
- #50 `agent-presets` — the in-app row-authoring precedent this unit mirrors.
- #60 `turn-history` — the Settings-tab + store + forget-control precedent.
