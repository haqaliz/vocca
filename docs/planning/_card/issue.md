# feat/agent-presets — inline brief

No GitHub issue filed; the source is the vocca-next-style handoff after the
coding-agent-handoff unit (2026-10-01) and the Wispr Flow deep dive (how a commercial
dictation tool handles its "do things" layer: zero-friction in-app authoring, snippets,
learned dictionary — with the blast-radius tradeoff named).

## Brief

The coding-agent-handoff unit shipped the BYO-binary registry (`coding-agents.json`,
absolute paths, env keys) — power-user-shaped, and the founder's own feedback is that
hand-writing JSON with absolute paths + API keys is hard for users. This unit makes the
authoring UX match the Wispr lesson: **discover installed coding-agent CLIs and render
them as pickable, editable presets in the Coding agents section** — the file stays the
source of truth; the authoring becomes a menu.

Scope (following the coding-agent-handoff precedent, same safety spine):
- A **known-agents catalog** (code-level, seeded like the intent synonyms): `claude`,
  `codex`, `gemini`, `opencode` (+ decide the set) — each with its non-interactive
  invocation shape (e.g. `claude -p <task>`, `codex exec ...`).
- **Discovery**: path checks for the known binaries (no PATH execution — absolute
  candidate paths per binary + `which`-style resolution), rendered as "installed /
  not detected" in the section.
- **Preset picker**: "Add from known agents" → a form pre-filled with the discovered
  executable path + a template argv (with a sane default task string the user edits) →
  saves a real row through the existing `CodingAgentRegistry.save` path. No magic: the
  row is ordinary, editable in the file, byte-pinned.
- **Safety unchanged**: presets are outwardFacing by construction, always-confirm, no
  readOnly, nothing spawns by default (a preset is created only by an explicit user
  action; discovery itself spawns nothing and makes no network calls).
- Tests first: catalog pins, discovery over an injected path source (no real `which` in
  CI), the picker's save round trip, the composed default still `agents=0
  spawnsSubprocess=false`, a PROBE-AGENT-PRESETS row or a probe extension.

Out of scope: {{task}} utterance seeding (deferred), parameters ($N slots), interactive
sessions, desktop-app (MCP-host) integrations, anything cloud.

## Labels (proposed)

feat, C13 follow-on, P4