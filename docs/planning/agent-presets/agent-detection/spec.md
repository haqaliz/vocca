# Aspect spec: agent-detection

> Source: `docs/planning/agent-presets/prd.md` R2 · Date 2026-10-01.

## Problem slice and user outcome

"Detected / not detected" facts for the known agents, resolved when the Coding agents
section opens — over the injected file-system seam, spawning nothing. User outcome: the
section shows which of the eight CLIs are installed so a user picks a preset that will
actually run.

## In-scope requirements

- **`AgentCLIDetection`** (in `VoccaActions`): a pure, injectable resolver —
  `detect(catalog:seam:environment:) -> [KnownAgentID: AgentDetection]` where
  `AgentDetection = .detected(path: String) | .notDetected`. Resolution order per
  preset's candidate names: (1) the **candidate path list** (the MVP — known absolute
  directories: `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/local/sbin`, `~/.local/bin`,
  `~/.cargo/bin`, `~/.nix-profile/bin`, plus `Applications`-adjacent none — each joined
  with the candidate name), (2) the app process's own `PATH` (split on `:`, absolute
  components only, no empty segments) — **demoted to should-have if the suite balloons**
  (PRD critique gap 3: the candidate-path list is the MVP cap).
- **The seam**: existence checks ride the injected `ActionConfigFileSystem.fileExists`
  (already shipped, already injected into the registry) — **no new FileManager-naming
  file, no lint table edit** (the dig's finding: a new seam row would be a deliberate
  ninth-seam widening; the seam ride avoids it).
- **The honest fact**: detection = the binary exists at a resolved path. Never a
  version, never "ready to run". The surface copy says exactly that.
- **Determinism**: candidate paths are checked in order; the first existence wins; the
  environment (PATH) is injected, never read globally in the test path.

## Out-of-scope

- Running or versioning any binary; watching for installs (a re-detect affordance is
  N2); anything but the pure resolver + the facts.

## Acceptance criteria (test-first)

1. A preset whose candidate name exists in the first candidate path → `.detected` with
   that path.
2. First-wins ordering: a binary present in two candidate paths reports the earlier one.
3. PATH resolution: an injected PATH string resolves a name not in the candidate list
   (absolute components only; `~`/relative/empty segments skipped).
4. Absent everywhere → `.notDetected`, quietly.
5. The resolver spawns nothing and names no forbidden family (transport lint green;
   FileManager named only via the seam protocol, never the identifier family).
6. An injected seam records the exact existence checks (a recording fake — headless,
   no real FS in the unit tests; one real-FS smoke row optional).

## Dependencies / sequencing

After `agent-catalog` (candidate names). Before `agent-authoring` (the section renders
the facts).

## Open questions

- None — the MVP cap (candidate paths first, PATH second) is recorded in the plan.