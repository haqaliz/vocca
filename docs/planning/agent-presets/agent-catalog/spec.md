# Aspect spec: agent-catalog

> Source: `docs/planning/agent-presets/prd.md` R1 · Date 2026-10-01.

## Problem slice and user outcome

The code-level known-agents catalog: eight coding-agent CLIs, each with candidate binary
names and a non-interactive argv template, pinned verbatim by tests (the `EngineCandidate`
and intent-synonym precedent — a reviewed edit, never a runtime discovery). User outcome:
the Coding agents section can offer "claude", "codex", "gemini", "opencode", "aider",
"cursor", "q", and one more as pre-filled starting points, without Vocca ever claiming
the CLI behaves as the template says.

## In-scope requirements

- **`KnownAgentPreset`** (in `VoccaActions`, beside the registry): `id`, `displayName`,
  `candidateNames: [String]` (e.g. `["claude"]`, `["claude-code", "claude"]`), and a
  non-interactive argv template with a `<task>` placeholder string (e.g. claude:
  `["-p", "<task>"]`; codex: `["exec", "<task>"]`; gemini: `["-p", "<task>"]`; opencode:
  `["run", "<task>"]`; aider: `["--message", "<task>"]`; cursor: `["run", "<task>"]`;
  q: `["-p", "<task>"]`; the eighth reviewed in during planning, e.g. crush:
  `["run", "<task>"]`).
- **`KnownAgentPresets.all`**: the closed set of exactly eight — pinned by tests (the
  count, the ids, the templates verbatim). A retune is a reviewed edit; the pin is the
  record of the decision.
- **The placeholder contract**: `<task>` is a *string the editor pre-fills and the user
  may edit*; this slice never substitutes it (N1 stays deferred). The pin asserts no
  preset template is empty and each contains exactly one `<task>` occurrence (or none —
  the q/crush templates decided in planning).

## Out-of-scope

- Detection (own aspect), the editor (own aspect), any runtime behavior, any claim about
  a CLI's real flags (the templates are seeds, and the copy says so).

## Acceptance criteria (test-first)

1. `KnownAgentPresets.all` holds exactly eight presets, ids and display names as pinned.
2. Each preset's argv template is pinned verbatim; a changed template fails loudly.
3. Each preset carries ≥1 candidate name; names are non-empty, ≤64 chars.
4. The seed lives in `VoccaActions` and names no transport family (the transport lint
   stays green; no FileManager naming — the catalog is pure data).

## Dependencies / sequencing

None — pure data + pins. Before `agent-detection` (reads the candidate names) and
`agent-authoring` (pre-fills from the presets).