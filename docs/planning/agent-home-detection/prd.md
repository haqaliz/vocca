# PRD — `agent-home-detection`

> **Phase:** P4 (Actions/MCP, C13 follow-on to `agent-presets`) · **Slug:**
> `agent-home-detection` · **Branch:** `feat/agent-home-detection/aliz`
> **Source:** inline brief (`docs/planning/_card/issue.md`); founder request.
> **Base:** `origin/master`.

---

## Problem Statement

The Actions-tab **Coding agents** section shows each preset as *detected* or *not
detected*, and detection checks only three absolute directories plus the app's own
PATH. Most coding-agent CLIs a developer actually has are installed under the home
directory — `~/.opencode/bin` (opencode), `~/.local/bin`, `~/.cargo/bin`,
`~/.bun/bin`, `~/.nix-profile/bin` — so Vocca reports "not detected" for tools that
are plainly installed. On the founder's machine: `opencode` lives at
`/Users/aliz/.opencode/bin/opencode` and shows **not detected** (`AgentCLIDetection.swift:71-75`,
`AppBootstrap.swift:2300-2314`).

This is a **demand-pulled** fix (the founder hit it live), and it lifts a recorded
deferral: *"a home-injecting widening is a reviewed edit to `candidatePaths` when
the seam grows one"* (`AgentCLIDetection.swift:56-64`).

## Goals & Success Metrics

| # | Goal | Signal (test) |
|---|------|---------------|
| G1 | Home-installed CLIs are detected | A binary at `<home>/.opencode/bin/opencode` resolves `.detected(path:)` when a home is injected. |
| G2 | No home → unchanged | With `homeDirectory: nil` the check set is byte-identical to today (the 24 checks). |
| G3 | Order is pinned | Absolute trio → home-relative dirs → PATH, name-major; first existence wins. |
| G4 | The resolver stays pure | `AgentCLIDetection.swift` still imports nothing and names no `FileManager`/transport family. |
| G5 | The app wires the real home | The composition root passes `NSHomeDirectory()`; a wiring test pins the call site. |

## Requirements

### Must-have

1. **`AgentCLIDetection.detect` gains an additive `homeDirectory: String?`
   parameter** (default `nil`). When `nil`, behaviour is byte-identical to today.
2. **A new pinned constant `homeRelativeCandidatePaths`** — home-relative directory
   components, joined as `<home>/<component>`: `.local/bin`, `.opencode/bin`,
   `.bun/bin`, `.cargo/bin`, `.nix-profile/bin`, `.volta/bin`, `bin` (the recorded
   spec trio + the demand-pull opencode dir + the common node/bun/volta installers).
   Every entry is relative (no leading `/`, no `~`) — the pin enforces it.
3. **Resolution order**: for each candidate name, ask the absolute
   `candidatePaths`, then the home-expanded dirs (only when a home is injected),
   then the PATH's absolute components. Name-major, first existence wins.
4. **The composition root passes `NSHomeDirectory()`** at the `detectAgents` call
   site (`AppBootstrap.swift:2300`) — the root may name Foundation; `VoccaActions`
   still may not.
5. **Acceptance tests G1-G5** (test-first).

### Should-have

- The home dirs are asked only when a home is present — a `nil`/empty home widens
  nothing (never checks `<empty>/...`).

### Nice-to-have (deferred, named)

- Reading the user's **login-shell PATH** (`.zprofile`/`.zshrc`) — rejected: it
  needs a spawn or file parsing, and the transport lint forbids the former. The
  home-relative list is the honest, spawn-free fix.
- A re-detect affordance on the surface (the `agent-presets` deferral, unchanged).

## Technical Considerations

- **Purity preserved:** string joining only; no Foundation import, no `FileManager`
  (the file's own lint test asserts this). The home comes from the caller.
- **Seam:** unchanged — `ActionConfigFileSystem.fileExists` is still the only
  file-system contact; no new seam, no FileManager-table widening.
- **G5:** `AppBootstrap.swift` changes → the digest is recomputed with
  `shasum -a 256` and re-anchored across all seven pin sites; dictation digests
  unchanged. Floor raised in the same commit.
- **No spawn, no network** — the honest fact is unchanged ("detected" = the binary
  exists at a path, never that it runs).

## Risks & Open Questions

| Risk / Question | Note |
|---|---|
| The home-dir list is a guess at where CLIs live | Pinned + reviewed-edit; the founder's real case (`.opencode/bin`) is included. Extending it is a one-line reviewed edit. |
| `~` expansion correctness | The root injects the real home; the resolver only joins. A trailing slash in the home is normalised (one rule, tested). |
| A home path with a symlink (`/Users/x` vs `/private/...`) | Not this unit's problem: the detected path is whatever the join produces; the row's executable path is absolute and the user may edit it. |
| 24-check pin grows | The exact-check-set test is updated deliberately; with `nil` home it stays 24. |

## Out of Scope

- Reading the login shell's PATH or shell rc files.
- Any change to the eight presets, the argv templates, or the row editor.
- Re-detection on the surface; persisted last-project; tilde paths in the row editor.
- Any dictation/ASR/injection/cleanup/TTS change; cloud.
