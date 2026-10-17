# PRD — Phrase authoring UI

**Slug:** `phrase-authoring-ui` · **Phase:** P4 (Actions/MCP, C13) — a reachability slice ·
**Source:** inline brief, `docs/planning/_card/issue.md` · **Understanding:** `docs/planning/_card/understanding.md`

---

## Problem Statement

The voice-action wedge is built but **founder-only**. Across C13 slices 1–14 the action
apparatus shipped — the intent layer, the shell/agent/MCP arms, the confirmation card, the
audit trail (`docs/technical/CAPABILITY_ROADMAP.md:394-1170`). But the two things a user must
author to use it at all are hand-edits of JSON:

- a **phrase** is a hand-edit of `intent-phrases.json`; `IntentPhraseStore.save` has **no
  production caller** — only the probe and tests write it
  (`Sources/VoccaActions/Config/IntentPhraseStore.swift:123-143`); and
- the **audit tools have no Actions-tab enablement row** (the recorded finding **F-A**,
  `CAPABILITY_ROADMAP.md:1058`, `:979`), so their enablement is a hand-edit of
  `action-config.json` too.

So the shipped capability is unreachable by anyone who will not open a text editor. The P4→P5
gate's only non-code leg — "**≥10 external users** have run the action layer on their own
machines without a safety incident" (`docs/ROADMAP.md:252`) — cannot be attempted while
authoring is a text edit.

**Evidence it's real:** the repo names this gap in its own records as the reachability blocker
("reachable by the founder only", `docs/STATUS.md:573`; "a phrase-authoring UI (phrases are
hand-edited JSON today)", `CAPABILITY_ROADMAP.md:1058`; F-A at `:979`).

**Honesty about demand:** this is a **roadmap-push** unit, not demand-pull — no external user has
asked for it (no issues exist; `docs/STATUS.md` records "no user request" for the recent C13
units). Its justification is the P4→P5 gate's external-users leg, not a request. Say so.

---

## Goals & Success Metrics

**Goal.** A non-founder Mac user can author a voice phrase and enable its target tool from the
Settings UI — no JSON, no relaunch — and the phrase resolves on the next spoken turn.

**Success metrics (all testable in CI; no rate is claimed).**

| # | Metric | Target |
|---|--------|--------|
| M1 | Round trip — a phrase added via the surface resolves on the next turn through the per-turn provider (`composeIntentResolverProvider`, `AppBootstrap.swift:1481-1485`) | without a relaunch or recomposition |
| M2 | Save-time invariants — a `dev.vocca.shell` row, a duplicate phrase, an empty phrase, and an over-length row are **refused at save** (loud), mirrored from the load rules | 100% of those cases refused |
| M3 | Byte preservation — opening and closing the surface **does not write**; an untouched file's bytes are unchanged; `version` and `keywordFallback` survive a load→save round-trip | byte-identical when unchanged |
| M4 | Audit enablement — `audit.count` and `audit.clear` render as default-off rows; toggling one writes the `(providerID, toolID)` pair the resolver reads | enabled row present after toggle |
| M5 | Default unchanged — the composed default still reads `agents=0 spawnsSubprocess=false`; the audit tools ship **off**; zero network | probe facts byte-identical |

**Non-goal metric:** this unit clears **no gate**. It makes the P4→P5 external-users leg
attemptable. No success, resolution or latency rate may be quoted from it.

---

## User Personas & Scenarios

**Persona — the privacy-first Mac user** (Vocca ICP): dictates all day, wants polished text
everywhere, and will not send audio to the cloud. They have heard Vocca can *act* by voice and
open the Actions tab.

**Scenario A — author a phrase.** In Settings → Actions, the user opens the new **Phrases**
section, clicks "Add phrase", types "count the audit log", and picks the target from a
provider+tool picker (the audit tools, a configured coding agent, or a discovered MCP tool).
Save. Nothing else. Next time they speak that phrase in a CONVERSING session, it resolves.

**Scenario B — enable the target.** The phrase's target must be enabled. The user toggles
`audit.count` on in the new **Audit tools** section (previously impossible without editing
`action-config.json`). A destructive row (`audit.clear`) carries an explicit warning.

**Scenario C — a mistake.** The user types a phrase that names a shell command, or duplicates
an existing phrase. Save is refused with copy that says why; nothing is written.

**Scenario D — a hand-edited file is respected.** A user who edited the JSON by hand opens the
surface, closes it without changes: their bytes are untouched. If they do change a row, the
`keywordFallback` setting they had hand-set is preserved.

---

## Requirements

### Must-have

1. **An Actions-tab `Phrases` section** — the first in-app authoring surface for
   `intent-phrases.json`, mirroring the Coding-agents section's authoring pattern
   (`ActionsTabPage.swift:106-140`, `:354-425`; reducer pattern `ActionsTabState.swift:195-219`,
   `:617-670`). Add / edit / remove rows through a small editor.
2. **A provider+tool picker** for a row's target. Options are the targets a phrase may
   legitimately name: the audit tools (`audit.count`, `audit.clear`), configured coding agents
   (`vocca.agent` + definition id), and discovered MCP tools (`dev.vocca.mcp.<serverID>` + tool
   id). **Shell is not offered** (`dev.vocca.shell` is refused — `IntentPhraseStore.swift:203-208`).
   The picker may be a free-text pair with validation if a full picker is disproportionate; the
   requirement is that a shell target cannot be entered.
3. **Store-level save validation, mirrored from load** (`IntentPhraseStore.save`,
   `IntentPhraseStore.swift:123-143`): refuse (throw) a `dev.vocca.shell` row, a duplicate
   normalized phrase (using the resolver's normalization — the existing agreement test is
   `IntentPhraseStoreTests.swift:314-337`), an empty phrase, and a phrase/id past its length cap.
   One rule judged in one place; the store is the backstop even for non-UI callers.
4. **Loud UI copy** for each refusal, surfaced in the editor (the agent editor's
   `saveError` pattern, `ActionsTabState.swift:373-426`), never a silent drop.
5. **The first production `save` caller** — `SettingsBindings` gains `loadPhrases` / `savePhrases`,
   wired at the composition root (`AppBootstrap.swift:1971-1974` construction site).
6. **Byte preservation** — the surface loads on open and **writes only on an explicit save with
   a change**; `version` and `keywordFallback` are carried in the draft and written back
   unchanged unless the user explicitly toggled the fallback (requirement 8).
7. **Audit-tool enablement rows** — the F-A fix. An **Audit tools** section renders
   `audit.count` and `audit.clear` as enablement rows, default off, reusing `toolRow(_:)`
   (`ActionsTabPage.swift:267-301`), with the section's D2 copy and an explicit destructive
   warning on `audit.clear`. The row source is a wiring list closure mirroring
   `ShellWiring.listCommands` / `CodingAgentWiring.listAgents` (`ShellWiring.swift:218-231`,
   `CodingAgentWiring.swift:289-293`); enablement writes the same `(providerID, toolID)` pair
   `ActionConfigStore` already keys (`ActionConfig.swift:89-99`).
8. **A `keywordFallback` toggle** in the Phrases section, persisting the field the composite
   resolver reads (`AppBootstrap.swift:1470-1477`) — retiring the `composite-intent-resolver`
   named deferral (`CAPABILITY_ROADMAP.md:1129`).

### Should-have

9. The surface shows the on-disk location of `intent-phrases.json` (the `Usage`/`Conversation`
   tab transparency precedent), so the file is discoverable and hand-editable.
10. A `fileURL` (or equivalent) accessor on `IntentPhraseStore` so the location is read once,
    not re-derived in the UI.

### Nice-to-have

11. A "detected/available" hint beside a picker target (e.g. an agent that is configured vs not)
    — the agent-detection affordance precedent (`ActionsTabPage.swift:428-433`). Optional.

---

## Technical Considerations

**Layer.** Actions / voice-loop front-end authoring; touches no audio path. **Local-only, OSS
core** — no network, no cloud; the surface reads and writes one local JSON file.

**Phase.** P4, C13 — a reachability slice of the shipped action layer. Prerequisites are all
shipped (the phrase store, the resolver, the per-turn provider, the Actions tab, the
shell/agent authoring precedent). No new phase dependency.

**Module boundary (the load-bearing constraint).** `VoccaUI` imports only `VoccaCore`
(`Package.swift:154-158`). It cannot name `IntentPhraseStore`/`IntentPhraseFile` (both
`VoccaActions`). `PhraseIntentRow` is in `VoccaCore` but the intent seam lint
`IntentSeamBoundaryTests.swift:245-261` confines it to an exact file set with **no `VoccaUI`
row**. **Decision:** UI-local plain types (`ActionsPhraseRow`, `ActionsPhraseFile`) + a
root-side mapping in `AppBootstrap` (the `AppBootstrap.agentFile(from:)` precedent,
`CodingAgentWiring.swift:189-207`), with an agreement test pinning the second spelling (the
`AgentAuthoringConstants` precedent, `AgentAuthoringSurfaceTests.swift:78-94`). No lint widening.

**Save-time semantics.** `save` re-encodes with `.sortedKeys` (`IntentPhraseStore.swift:148-158`),
so byte preservation means "the UI must not call save when nothing changed"; `load` never writes
(this is pinned: `IntentPhraseStoreTests.swift:114-122`). The new refusals are additive and must
not change the happy-path bytes — the existing exact-bytes pin
(`IntentPhraseStoreTests.swift:299-308`) and the off-file pin (`:410-416`) must stay green.

**Recomposition.** The resolver provider reads the file per turn
(`composeIntentResolverProvider`, `AppBootstrap.swift:1481-1485`), so a saved phrase is live on
the next turn; a fresh `PhraseIntentResolver` is built from the loaded file each turn — no
caching to invalidate. M1 is the acceptance.

**G5 digest.** Any `AppBootstrap.swift` edit re-anchors the deliberate G5 digest at **seven**
pin sites (`TurnTakingComposedAcceptanceTests`, `AuthBaselineInvariantTests`,
`AgentPresetsInvariantTests`, `ActiveProjectInvariantTests`, `SpokenTaskInvariantTests`,
`WiringBaselineTests`, `ReplyRenderingInvariantTests`) plus the floor script's comment —
recomputed with `shasum -a 256`, never edited-to-match. The dictation digests
(`1baeb2de…`/`ce70ca10…`) must remain unchanged.

**Boundary/lint obligations.** The zero-network suite must stay green (no new network name; the
surface touches no socket). The transport-prohibition lint stays at exactly two files. The
FileManager seam table grows only if a new file names `FileManager` (the store already owns its
file; prefer no new seam). The reducer owns all mutation; the view stays glue (the Actions-tab
family scan, `ActionsTabTests.swift:403-423`).

---

## Data Model

`intent-phrases.json` is unchanged in shape (`IntentPhraseStore.swift:310-328`):

```
IntentPhraseFile { version: 1, phrases: [PhraseIntentRow], keywordFallback: Bool }
PhraseIntentRow { phrase: String, providerID: String, toolID: String }
```

The UI-local mirror is identical in the fields it carries (`ActionsPhraseRow`,
`ActionsPhraseFile`) so a round-trip is lossless. Caps unchanged: 256 phrases, 64 KB file,
256-char phrase, 128-char id (`IntentPhraseStore.swift:70-79`).

---

## Risks & Open Questions

- **R-A — the wedge becomes runnable by non-founders (trust).** This unit removes the friction
  that currently keeps action authoring founder-only. R8 (destructive actions) stays mitigated
  in structure (the card + click + sentence binding + audit) and **not retired**; N2 stands (an
  approval asserts a human said yes, cannot verify it). The authoring surface must not add a run
  affordance — it authors and enables only.
- **R-B — silent write / byte churn.** The most likely defect: writing the file on open or on a
  no-op close, clobbering a hand edit. Mitigated by M3 (writes only on an explicit changed save)
  and pinned by the store's existing never-rewrites-on-load test.
- **R-C — second-spelling drift.** `ActionsPhraseRow` vs `PhraseIntentRow` drift. Mitigated by
  the agreement test (must-have 3's precedent).
- **R-D — a shell row through a non-UI path.** If validation lived only in the reducer, a future
  caller could write a shell row. Decision (founder): mirror the refusal in `save`. The store is
  the backstop.
- **R-E — D2 / no spawn.** Unchanged: the surface cannot spawn; the default has zero configured
  servers and zero enabled audit tools; quote no rate. SMOKE observation (a phrase authored in
  the UI resolves in a real CONVERSING session) is the first real check — recorded, never gated.
- **R-F — stale / foreign targets.** A phrase naming a since-removed agent, MCP server, or shell
  target is **inert** (the resolver's catalog gate: a target not enabled/known resolves nothing —
  `PhraseIntentResolver.swift:94-105`). The UI must render such a row honestly ("target not
  configured") rather than as a live phrase, and must never crash on a target it cannot resolve.
  `load` already tolerates a stale row (`ActionConfig`, `:198-208`), so the file is safe; the
  surface's rendering is the gap.
- **R-G — read-on-open staleness / last-writer-wins.** Like the Conversation tab, the section will
  read on open. A hand-edit of `intent-phrases.json` while the section is open (or a second window)
  is not seen, and a save then clobbers it. Mitigation options: re-read immediately before writing
  (detect a change and refuse/reload), or document last-writer-wins. Decide in the tech plan; the
  byte-preservation metric (M3) covers the no-op case only.
- **Open Q1 — picker vs free-text.** A full provider/tool picker needs the list of agents, MCP
  tools, and audit tools composed at the root; if that is disproportionate, a validated free-text
  pair is acceptable. This is the main cost/feasibility driver. Resolve in the aspect spec / tech-plan.
- **Open Q2 — surface for removal.** Whether removing a phrase also disables its now-orphaned
  target (the agent rename cascade precedent, `ActionsTabState.swift:398-416`). Recommendation:
  no — targets stay as the user set them (orthogonal stores).
- **Open Q3 — same-window / cross-window edit conflict.** See R-G — re-read-before-write vs
  documented last-writer-wins.

---

## Out of Scope

- **Argument construction from voice** (`$N` parameter slots) — a voice phrase still carries no
  arguments (`ActionInvocation.arguments = nil`).
- **The intent-seam shell leg** — a shell phrase remains refused by decision.
- **Spoken confirm/decline** (N2) and a session guard.
- **A server-config editor rewrite** or MCP server authoring (out of this slice; discovery/enable
  already shipped).
- **Any cloud, sync, export, or cross-device authoring.**
- **A new Settings tab** — the surface lives in the existing Actions tab (so `SettingsTab` and
  `page(for:)` are untouched).
