# Aspect spec — `phrase-authoring`

**Parent PRD:** `docs/planning/phrase-authoring-ui/prd.md` · **Modules:** `VoccaUI` + `VoccaBootstrap`
· **Depends on:** `phrase-store-validation` (the save errors) · **Independent of:** `audit-enablement`.

## Problem slice

There is no in-app way to author a phrase: `intent-phrases.json` is a hand-edit, and
`IntentPhraseStore.save` has no production caller. This aspect adds the Actions-tab **Phrases**
section — add/edit/remove rows, a validated target picker, a `keywordFallback` toggle — persisted
through the store, with the UI-local types + root mapping that respect the module boundary.

## In-scope requirements

1. A **Phrases** section in `ActionsTabPage`, mirroring the Coding-agents section: an empty state,
   rows, an "Add phrase" affordance, and an editor (`ActionsTabPage.swift:106-140`, `:354-425`).
2. **UI-local types** in `ActionsTabModel.swift`: `ActionsPhraseRow { phrase, providerID, toolID }`
   and `ActionsPhraseFile { version, phrases, keywordFallback }` — not `PhraseIntentRow`
   (lint-confined, `IntentSeamBoundaryTests.swift:245-261`). An agreement test pins the field
   agreement (the `AgentAuthoringConstants` precedent, `AgentAuthoringSurfaceTests.swift:78-94`).
3. **Reducer** (`ActionsTabState`): a closed set of new actions (`phrasesConfigLoaded`,
   `phraseEditorOpened`, `phraseDraftFieldEdited`, `phraseSaveRequested`, `phraseEditStarted`,
   `phraseEditCancelled`, `phraseRemoved`, `keywordFallbackToggled`) and their folds. Save runs the
   editor validation (empty/duplicate/shell/length) **before** the binding call, surfacing loud
   copy; the store's typed error (from `phrase-store-validation`) is surfaced on a failed save.
4. **Target picker** — the row's `(providerID, toolID)` is chosen from the legitimate targets:
   audit tools, configured coding agents, discovered MCP tools. **A `dev.vocca.shell` target is
   not selectable** (defense in depth beside the store refusal). Implemented as a picker if the
   composed lists are available, else a validated free-text pair.
5. **`keywordFallback` toggle** in the section, written to `IntentPhraseFile.keywordFallback`.
6. **Bindings** — `SettingsBindings.loadPhrases` / `savePhrases` (+ `savePhrases` default that
   changes nothing, `SettingsView.swift:362-380` precedent), wired in the one construction at
   `AppBootstrap.swift:1971-1974`; the root maps `ActionsPhraseFile ⇄ IntentPhraseFile`
   (a `AppBootstrap` mapping helper, the `agentFile(from:)` precedent,
   `CodingAgentWiring.swift:189-207`).
7. **Byte preservation** — the section loads on `.task` and writes **only on an explicit changed
   save**; `version`/`keywordFallback` ride the draft and are written back unchanged unless the
   user toggled the fallback.
8. **Location display** (should-have) — show `intent-phrases.json`'s path (from
   `phrase-store-validation`'s accessor).

## Out of scope

- Any run/invoke affordance — the section authors only.
- Argument construction, shell targets, a new Settings tab, cloud.
- Composing/reading the phrase file at launch — the per-turn provider already owns reads.

## Acceptance criteria (written first — RED)

- `A1` — **M1:** a phrase added via the surface (reducer folds) then `savePhrases` makes the
  composed per-turn provider resolve it on the next turn, **no relaunch** — via the real
  `IntentPhraseStore` over a temp directory and `composeIntentResolverProvider`.
- `A2` — **M3:** loading the section and closing without changes performs **zero** writes (the
  file bytes are unchanged; a spy/filesystem seam proves no `save`).
- `A3` — a load with a hand-set `keywordFallback: true` round-trips through the draft and a save
  (if the user changed a row) preserving `true`; a toggle writes the new value.
- `A4` — a shell target cannot be selected/entered; the reducer refuses it with loud copy.
- `A5` — a duplicate phrase / empty phrase / over-length row is refused in the editor with loud
  copy (mirrors the store).
- `A6` — add/edit-in-place/remove: an edit keeps the row's identity (no duplicate on rename);
  remove deletes the row from the draft and the file.
- `A7` — `savePhrases` failure keeps the draft and sets `saveError`; success clears the draft
  (the agent editor precedent, `AgentAuthoringTests.swift:529-548`).
- `A8` — the boundary: no `VoccaUI` file names `PhraseIntentRow`/`IntentPhraseFile`/
  `IntentPhraseStore`; the agreement test passes; `IntentSeamBoundaryTests` is unmodified.
- `A9` — the Actions-tab family scans stay green: no network/`Process` name, reducer-owns-mutation,
  bindings-claim-nothing defaults.
- `A10` — `SettingsBindings` construction scan (`AppBootstrapWiringTests`) extended to cover the
  new phrases bindings; the composed default probe facts unchanged.

## Dependencies / sequencing

After `phrase-store-validation` fixes the error types. `audit-enablement` can proceed in parallel
(separate section/actions). Both re-anchor G5 once — coordinate so `AppBootstrap` is edited once
(one G5 re-anchor for the unit), or accept two deliberate re-anchors.

## Open questions

- Picker vs free-text target (`PRD` Open Q1) — resolve in the tech plan against the cost of
  composing the agent/MCP/audit lists in the section.
- The editor's phrasing for the picker when a target is configured but not enabled.
