# feat/active-project-detection — inline brief

No GitHub issue filed; the source is the founder's own request (2026-10-01), following the
`vocca.agent` rename and the projectDirectory cwd-fix.

## Brief

The founder works across many projects (`~/dev/manifold`, `~/dev/foresight`, `~/dev/at`,
…) and wants the agent handoff's project directory **detected from context**, not
hand-configured per row. The focused app's **working directory** is the signal: you are
in VS Code/terminal/iTerm on `~/dev/manifold` → that is the project.

Decisions (founder, 2026-10-01):
- **Metadata level**: the cwd of the focused app is a directory path, not document
  content — read like bundle ID/window title (no per-app consent), shown in the agent's
  confirmation sentence + under the existing context indicator; the BYOK payload rule
  stays: metadata travels, content (selection) stays gated.
- **Explicit wins, empty = detect**: a row with an explicit `projectDirectory` uses it;
  a row with it EMPTY detects the focused app's cwd at arm time and renders the resolved
  directory in the confirmation sentence (the sentence binding applies).
- **Ship + measure**: `proc_pidinfo(PROC_PIDVNODEPATHINFO)` on the frontmost app's PID
  is expected to work for same-user processes on an unsandboxed app but has NEVER been
  measured here — ship the read with a SMOKE row measuring it on the founder's real apps
  (VS Code, terminal, iTerm) before any "works everywhere" claim.

Scope: C12-extension + agent-provider integration. `ContextSnapshot` gains a
`workingDirectory` field (a seam change — all pins updated); `AccessibilityContext`'s AX
metadata read already resolves the focused app's PID; the new read is a libproc call over
an injected closure (headless-testable); the agent wiring resolves the snapshot at arm
time (the `root.contextResolution` slot exists) and renders the resolved directory in the
argv-derived sentence. The composed default still spawns nothing; zero network; the
dictation path untouched (digest-pinned).

Out of scope: window-title heuristics (C12 explicitly never scores titles), a configured
project list, anything cloud.

## Labels (proposed)

feat, C12 follow-on, P4