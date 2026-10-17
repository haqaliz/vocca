# feat/phrase-authoring-ui — understanding note

Source: `docs/planning/_card/issue.md` (inline brief, vocca-next handoff 2026-10-17). Codebase
map: three parallel exploration passes over this worktree (phrase layer, Actions-tab UI, action
enablement + F-A gap). Repo is **not greenfield** — v0.5.1, 24 units shipped, test floor **3266**.

## What this work is really asking

The action wedge is built (C13 slices 1–14 shipped) but **founder-only**: a phrase row is a
hand-edit of `intent-phrases.json`, and the audit tools have no Actions-tab enablement row
(F-A; `CAPABILITY_ROADMAP.md:1058`, `:979`; `STATUS.md:1597-1599`). No production caller ever
invokes `IntentPhraseStore.save` today (`IntentPhraseStore.swift:123-143` — only the probe writes
raw bytes and tests call it). This unit adds the **first authoring surface**: an Actions-tab
**Phrases** section (add/edit/remove rows, provider+tool picker, validation) that persists through
the store, plus **audit-tool enablement rows** (default off) so a phrase's target is reachable
without a text editor.

It is a **reachability** slice, not a capability slice: it makes the P4→P5 gate's external-users
leg (`ROADMAP.md:252` — "≥10 external users have run the action layer") *attemptable*. It clears
no gate.

## The code as it stands (map)

**Phrase layer.**
- `IntentPhraseStore` — `Sources/VoccaActions/Config/IntentPhraseStore.swift:64` (`actor`). File
  `intent-phrases.json` at `~/Library/Application Support/Vocca/` (`:100-104`, `:293`).
  - `IntentPhraseFile { version, phrases, keywordFallback }` `:310-328`; row type is
    **`PhraseIntentRow { phrase, providerID, toolID }`** in `VoccaCore`
    (`Sources/VoccaCore/Intent/PhraseIntentResolver.swift:22-43`).
  - `load() async -> IntentPhraseFile` `:109-117` (never throws, never writes); `save(_:) async
    throws` `:123-143`; `encode` `:148-158` (sorted keys; `keywordFallback` **written only when
    true** `:157`); `decode` `:162-233` (tolerant, one log per refusal).
  - Caps refuse never clamp: 256 phrases / 64 KB / phrase 256 / id 128 (`:70-79`).
  - **Shell refusal is load-only** (`:203-208`, `providerID == ShellProvider.providerID`); `save`
    does **no** shell / empty / duplicate / length validation (`:123-143`).
- `PhraseIntentResolver` — `VoccaCore/Intent/PhraseIntentResolver.swift:70`; exact match under one
  public normalization, table order, catalog-gated (enablement is membership by the
  `(providerID, toolID)` pair), never asks, no arguments.
- Per-turn provider: `composeIntentResolverProvider(store:)` reads the file **each turn**
  (`AppBootstrap.swift:1481-1485`), so a saved phrase resolves next turn with no relaunch.
  `composeIntentResolver(file:)` `:1470-1477` builds the phrase (or composite) resolver, excluding
  shell + agent + MCP-prefix from the keyword fallback.

**Actions tab (precedents).**
- `ActionsTabPage.swift` (thin view) + `ActionsTabState.swift` (pure reducer, closed
  `ActionsTabAction` set) + `ActionsTabModel.swift` (plain UI types) + `ActionsTabCopy.swift`.
- The **Coding-agents section** is the row-authoring template: own `agentRows` + `isAgentLoaded`,
  `.agentConfigLoaded` fold, an "Add" chooser, an editor with field validation
  (`definition(from:)` `:617-670`), duplicate-id + `<task>`-placeholder Save refusals, edit/remove
  with enablement cascade. **Shell** is the simpler template for a registry-read row set
  (`shellRows` + `.shellConfigLoaded`).
- **Module boundary:** `VoccaUI` imports only `VoccaCore` (`Package.swift:154-158`); it cannot name
  `VoccaActions` types (`IntentPhraseStore`, `IntentPhraseFile`). The convention is UI-local plain
  types + a root-side mapping (`AppBootstrap.agentFile(from:)` `CodingAgentWiring.swift:189-207`;
  `ActionsAgentFile` `ActionsTabModel.swift:179`). A second spelling is legitimate only while a
  test pins agreement (`AgentAuthoringConstants` precedent, `AgentAuthoringSurfaceTests.swift:78-94`).
- **`PhraseIntentRow` IS in `VoccaCore`** — so `VoccaUI` *could* name it — but the seam lint
  `IntentSeamBoundaryTests.swift:245-261` permits it in an **exact enumerated file set** with no
  `VoccaUI` row, and `:279-337` enforces set equality over `Sources/`.

**Enablement + the F-A gap.**
- `ActionConfigStore` / `action-config.json` (`Sources/VoccaActions/Config/ActionConfigStore.swift:69`)
  — `{ servers, enablement }`, an enablement row is `{ providerID, toolID }`
  (`ActionConfig.swift:89-99`); unknown keys refused; caps refuse never clamp; atomic save.
- **A row renders only if it has a source**: MCP rows come from `discoverySucceeded`; shell/agent
  rows build their own from a registry read (`ShellWiring.listCommands` `:218-231`,
  `CodingAgentWiring.listAgents` `:289-293`). The recorded finding: "the arm surface is not
  generic — an enablement row alone renders nothing" (`CAPABILITY_ROADMAP.md:518-521`).
- `AuditActionProvider` (`Sources/VoccaActions/Providers/AuditActionProvider.swift:71`):
  `providerID = "dev.vocca.audit"` `:77`, tools `audit.count` (read-only) `:80` / `audit.clear`
  (destructive) `:83`, `toolIDs` `:106`, `servedToolID` guard `:190-192`. **No row source is
  surfaced to the tab** — the F-A gap. Enablement is set today only by `wiring.setToolEnabled` in
  tests / a hand-edit of the JSON.

## Tensions and contradictions surfaced (not papered over)

1. **Save-time invariants do not exist yet.** `IntentPhraseStore.save` enforces only count + byte
   caps; the shell refusal and empty/duplicate/length rules are **load-only**. The brief requires
   the shell refusal "at save with loud copy". Decision: mirror the shell refusal in `save` (one
   rule judged in one place) and/or validate in the reducer. Whichever — a shell row must not be
   written, and a duplicate phrase must be handled deliberately (load keeps the **first** row
   `:172-186`; does save refuse a duplicate loudly?).
2. **Byte-preservation vs canonical save.** `save` re-encodes with sorted keys, so "an untouched
   file's bytes are unchanged" can only mean **the UI must not call save when nothing changed**
   (load itself never writes, pinned `IntentPhraseStoreTests.swift:114-122`). The
   `keywordFallback`/`version` fields must survive a round-trip (`:400-407`, `:410-416`).
3. **`keywordFallback` is a hand-edited switch today.** The brief only requires it survives a
   round-trip; exposing a UI toggle for it is the named deferral from `composite-intent-resolver`
   (`CAPABILITY_ROADMAP.md:1129`). In scope or not — a founder call.
4. **Boundary: UI-local row type vs lint widening.** Naming `PhraseIntentRow` in `VoccaUI` needs a
   reviewed widening of `IntentSeamBoundaryTests` (the `ActionsToolKey` precedent exists, but the
   intent-family lint is separate and stricter). The agent precedent (UI-local `ActionsAgentFile` +
   root mapping) avoids a widening but adds a second spelling to pin.
5. **Two things in one brief.** Phrase authoring *and* audit-tool enablement rows — related
   (a phrase needs an enabled target) but independently shippable. Decide: one unit or two aspects.
6. **The audit `audit.clear` tool is destructive.** Rendering it as an enablement row is not the
   same as running it, but the D2 copy must sit on the section (the shell/agent precedent).
7. **No gate passes** — the 25th unit ahead of the uncleared gates (`STATUS.md:70-79`); no real
   surface has been observed; no rate may be quoted. Record it.

## Challenge pass (for the interview)

- **If we don't build it?** Every voice action stays a JSON hand-edit; the P4→P5 external-users
  leg stays unreachable; the wedge stays a demo. Completeness of the wedge, not a gate-clearing
  unit — say so.
- **Six months later it failed — why?** (a) the second spelling drifted from `PhraseIntentRow`
  (no agreement pin); (b) a shell row or a duplicate got saved because validation lived only in
  the UI reducer, not the store; (c) the UI wrote the file on open, churning bytes / clobbering a
  hand-edit; (d) `keywordFallback`/`version` were dropped on save; (e) the audit section welded
  enablement to a run affordance and implied `audit.clear` was safe.
- **What are we choosing not to build?** Argument construction from voice (`$N` slots), the
  intent-seam shell leg, spoken confirm/decline, a full server-config editor rewrite, any cloud.

## Affected areas

`VoccaUI` (Phrases section + reducer/copy + UI-local row/file types; audit section rows),
`VoccaBootstrap` (`AppBootstrap` load/save bindings + the audit row source + the file mapping;
G5 digest re-anchors at **7 pin sites**), possibly `VoccaActions` (`IntentPhraseStore.save`
validation + a `fileURL`/list accessor), `SettingsBindings` (`loadPhrases`/`savePhrases`, audit
list binding), tests (new surface suite + store save-validation suite + the 7 pin sites + lint
tables), docs (`ARCHITECTURE.md` storage list, `PRODUCT_SPEC.md` if the surface lands there,
`SMOKE_CHECKLIST.md`, the unit record).

## Open questions for the founder (Phase 3)

1. **Scope** — one unit (phrase authoring + audit-tool enablement) or two aspects? If one, which
   order?
2. **Save-time validation** — should `IntentPhraseStore.save` gain the shell refusal + duplicate/
   empty/length rules (mirroring load), with the UI showing loud copy; or validate only in the
   reducer (store unchanged)?
3. **`keywordFallback`** — expose a UI toggle now (retires the named deferral), or only preserve
   it across a round-trip?
4. **Boundary** — UI-local `ActionsPhraseRow`/`ActionsPhraseFile` + root mapping (no lint change),
   or name `PhraseIntentRow` in `VoccaUI` (reviewed lint widening)?
5. **Duplicate phrases** — refuse at save (loud) or allow with first-wins (load's rule)?
6. **Audit section** — both tools (`audit.count` + `audit.clear`) as default-off rows, with the
   D2 copy; any copy on the destructive `audit.clear` row specifically?
