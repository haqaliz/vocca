# Understanding — `agent-home-detection`

Phase 2 dig. Worktree `feat/agent-home-detection/aliz`, base `origin/master`.

## What the work is really asking

`AgentCLIDetection` (`Sources/VoccaActions/Config/AgentCLIDetection.swift`) decides
the "detected / not detected" fact the Actions-tab Coding-agents section shows. It
checks **only** three absolute dirs (`/opt/homebrew/bin`, `/usr/local/bin`,
`/usr/local/sbin`) plus the app's own PATH, absolute components only.

Real case: `opencode` is installed at `~/.opencode/bin/opencode` → **not detected**,
because home-relative dirs were deliberately excluded (recorded deferral: *"a
home-injecting widening is a reviewed edit to `candidatePaths` when the seam grows
one"* — `AgentCLIDetection.swift:56-64`). The user wants this to work automatically.

## The blocker, and how this unit lifts it

The file-system seam (`ActionConfigFileSystem`) has no home accessor, and
`VoccaActions` must not name `FileManager`/Foundation for one (a lint-table
widening). The clean lift: **inject the home directory from the composition root**
(which already names Foundation) as a new `detect(...)` parameter, and expand a
new **home-relative candidate list** against it. `AgentCLIDetection` stays
Foundation-free and names no `FileManager` — it only does string joining.

## Current shape (verified)

- `AgentCLIDetection.detect(catalog:fileExists:path:)` — pure; candidatePaths then
  the PATH's absolute components, name-major (`:88-125`).
- `candidatePaths` is a pinned constant (3 absolute dirs) — `AgentCLIDetectionTests:251`.
- The composition root calls it at `AppBootstrap.swift:2300-2314`, injecting the
  seam and `ProcessInfo.processInfo.environment["PATH"]`.
- Tests: `AgentCLIDetectionTests.swift` (acceptances 1-6 + the constant pin) and a
  detection pin in `AgentPresetsInvariantTests.swift:537`.

## Affected areas

- `Sources/VoccaActions/Config/AgentCLIDetection.swift` — the new parameter + the
  home-relative list.
- `Sources/VoccaBootstrap/AppBootstrap.swift` — pass `NSHomeDirectory()` (a
  composition-root edit → **G5 re-anchor**).
- `Tests/HarnessTests/AgentCLIDetectionTests.swift`, `AgentPresetsInvariantTests.swift`
  — pins; `Scripts/test-with-floor.sh` — floor.

## Layer / phase

Actions (P4, C13) — a follow-on to `agent-presets`. Local-only, no spawn, no
network. Honest fact unchanged: "detected" = the binary exists at a path.

## Open questions

1. Which home-relative dirs ship? (the recorded trio `.local/bin`, `.cargo/bin`,
   `.nix-profile/bin`; the demand-pull `.opencode/bin`; plus `.bun/bin`,
   `.volta/bin`, and a bare `bin`).
2. Order: absolute trio → home dirs → PATH, or home dirs interleaved?
3. When no home is injected (`nil`), behaviour is byte-identical to today.
