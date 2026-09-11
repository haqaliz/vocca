# Card: feat/electron-target-resolution

> Inline brief — no GitHub issue exists (`gh issue list` → empty; Issues are empty for
> `haqaliz/vocca`). Source: the `vocca-next`/`injection-matrix-completion` handoff of 2026-09-12.

## Brief

Fix the injection ladder's target resolution for Chromium/Electron apps (VSCode, Teams,
Discord, ChatGPT, Obsidian): dictation completes but delivery refuses at rung 0 with
`.noFocusedField` because `AXSource.focusedApp()` answers "nothing focused" for Chromium apps,
so `TargetContext.bundleID == nil` and clipboardPaste — which needs no AX field — never runs.

Evidence: 5 recovery journals `{"reason":"noFocusedField"}` + usage ledger 2026-09-11
(2 delivered / 5 failsafeHeld); the failing set is exactly the Chromium apps while
native/WebKit/Gecko apps resolve fine (7 of 7 matrix rows landed 2026-09-10).

Caveat: the `.noFocusedField` refusal exists to stop text landing in the wrong place — the fix
must be a GATED frontmost-app fallback (NSWorkspace frontmost bundleID) that distinguishes a
Chromium "nothing focused" lie from a genuine no-field state, or it recreates the silent-drop
shape R1 forbids.

Tests first: RED for a resolution where AX answers nil but the frontmost app is a
field-having app → bundleID must fall back; RED for the genuine-no-field case → must still
refuse. Acceptance: the 5 Electron rows pass the matrix on v0.3.1, transcript loss stays 0%,
the rung-0 refusal is structurally impossible for a frontmost app with a focused field, and
the 17/20 ceiling record stands until the gate decision on the 3 permanent skips.