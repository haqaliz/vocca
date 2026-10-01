# Aspect spec: agent-authoring

> Source: `docs/planning/agent-presets/prd.md` R3, R4, S1, S2 · Date 2026-10-01.

## Problem slice and user outcome

The authoring surface: "Add coding agent" in the Coding agents section — choose a preset
(or blank), the editor pre-fills (executable/argv from the preset, projectDirectory from a
remembered last value, S2), edit every row field, Save writes a real row through
`CodingAgentRegistry.save`. Edit/remove of existing rows (S1) rides the same editor.
User outcome: a row is authored in the app, never in JSON; the file stays the truth.

## In-scope requirements

- **The save path** (the one-line gap): `SettingsBindings` gains
  `saveAgents: (CodingAgentFile) async throws -> Void` with a no-op default (the
  bindings doctrine); `AppBootstrap.showSettings` fills it
  (`guard let registry = self?.agentRegistry else { return }; try await registry.save(file)`
  — the `agentRegistry` root slot exists). This is an `AppBootstrap.swift` change → the
  **G5 re-anchor** lands in this aspect's REFACTOR (deliberate, computed, dictation
  digests unchanged).
- **The reducer**: `ActionsTabState` gains the Servers-editor pattern — agent drafts
  (id/executable/arguments/projectDirectory/timeout/environment pairs/clause),
  `editingAgentID`, actions `.agentEditorOpened(presetID:)` / `.agentEditorClosed` /
  `.agentDraftFieldEdited(...)` / `.agentSaveRequested` / `.agentEditStarted(id:)` /
  `.agentEditCancelled` / `.agentRemoved(id:)`, and the id-minting rule (stable UUID
  minted once — an edit never looks like delete-plus-add). Save folds
  `saveSucceeded`/`saveFailed` (the Servers pattern; failure loud, draft kept).
- **Validation before save** (the definition's own rules): absolute executable path, no
  `~`, timeout 1…600, caps; **duplicate-id refusal** (the registry's first-wins would
  silently skip a dup); **the `<task>` placeholder warning** (PRD critique gap 1): a
  save whose argv still contains `<task>` is refused with a loud explanation naming the
  placeholder — the row the user saves must be a row that means something (the honest
  sentence principle still holds; the refusal is at Save, never at confirm).
- **The editor UI** (`ActionsTabPage`): preset chooser (the detected facts from
  `agent-detection` rendered beside each preset) → pre-filled form (all row fields;
  environment as key/value pairs) → Save/Cancel; edit/remove buttons on agent rows
  (mirroring the server rows, remove cascades enablement).
- **Copy** (`ActionsTabCopy`): "Add coding agent", the preset chooser title, the
  detection fact ("detected — <path>" / "not detected"), the placeholder-warning text,
  the D2 copy unchanged.

## Out-of-scope

- Detection (own aspect); `{{task}}` substitution (deferred); persisted last-project
  (S2 is in-memory only); anything touching the gate/card/audit.

## Acceptance criteria (test-first)

1. The save binding writes a row the registry's own load reads back (write → reload →
   row present; byte-stable; caps refused loudly).
2. The reducer mints a stable id once per add; edit mutates in place; remove cascades
   the enablement key.
3. A duplicate id is refused at Save with the loud copy; an invalid row (relative path,
   timeout 0) is refused; a `<task>`-containing argv is refused with the placeholder
   warning.
4. Save failure folds `saveFailed` and keeps the draft; save success clears it.
5. A preset pick pre-fills executable/argv (candidate path from detection if detected,
   else the first candidate name unresolved); a blank pick starts empty.
6. The composed default is unchanged: the section with no rows still reads the empty
   state; `agents=0 spawnsSubprocess=false` (the PROBE post-condition is untouched).
7. G5: the `AppBootstrap.swift` digest re-anchored deliberately in REFACTOR; the two
   dictation digests unchanged.

## Dependencies / sequencing

After `agent-catalog` + `agent-detection` (the chooser needs both). Before
`agent-pins` (the round-trip pins) and `agent-record`.

## Open questions

- None — S1 edit/remove is in scope; if the aspect balloons, add-first/edit-remove-next
  is the recorded fallback (PRD S1).