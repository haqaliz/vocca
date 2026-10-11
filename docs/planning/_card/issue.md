# Brief (no GitHub issue exists; inline brief, 2026-10-11)

**Unit:** `feat turn-history` — the P3 conversation-state deliverable.

**Source:** `docs/ROADMAP.md:205` — the P3 "Conversation state" row: **"Bounded, inspectable,
local turn history — with a visible 'forget' control"** — kept alive as "a separate, unclaimed
P3 item" by `docs/technical/CAPABILITY_ROADMAP.md:1063-1064`. Chosen by `vocca-next`
(2026-10-11) as the last unshipped row of P3's deliverables table; its dependencies are
shipped: C9 (`kokoro-voice-output` + `kokoro-binding`), C10 (`turn-taking-barge-in`), C11
(`dual-mode`). The repo has zero GitHub issues; this brief is the source.

**Goal.** Give CONVERSING mode a conversation state: a bounded, local record of completed
turns (what the user said and what Vocca replied), inspectable on a surface, with a visible
"forget" control that clears it. Today only the current reply is visible (the bubble,
`reply-text-rendering`); the moment the next turn starts or the mode changes, the exchange is
gone. The roadmap's own words tie the three properties together — bounded, inspectable,
local — into one deliverable; the unit must not grow into a browser.

**Acceptance (write first):**
1. The converse driver records each **completed turn** into a **bounded** local store; at the
   cap it **refuses** (cap-refuse-never-clamp is the repo convention) rather than evicting or
   clamping.
2. An **inspect surface** lists the stored turns.
3. One **visible forget action** clears the store, and the surface reflects the clear.
4. The store is **local**: the zero-network suite is unaffected, and no turn text reaches any
   other file (the `usage.json` byte-level pin precedent).

**Caveats / known tensions to reconcile (do not paper over):**
- **No gate passes.** This would be the 22nd unit built ahead of the uncleared gates under the
  recorded posture (`docs/STATUS.md:117`). The project's binding constraint is real use (P0
  7-day streak, P1 blind ballot, P2 external users) — no code unit advances that; say so in
  the record.
- **`PRODUCT_SPEC.md:409`** (a deliberate non-goal): "**No transcript history browser.** A
  searchable archive of everything you've ever said is a liability, not a feature, in a
  privacy-first tool. The recovery journal is bounded, purposeful, and purged." The unit must
  reconcile this with `ROADMAP.md:205` — bounded window, purposeful, purged; never searchable
  or archival.
- **`PRODUCT_SPEC.md:421`** (§13.3): "Converse-mode transcript surface. Where the agent's
  replies render — inside the widget, or an expanded panel — is a genuine P3 design question
  that deserves its own pass with mockups."
- **The widget panel is non-key** (`WidgetPanel.canBecomeKey == false`; recorded blocker of
  the N1 copy affordance, `reply-text-rendering`). Any in-widget interaction (select/copy/
  forget) hits this; the menu-bar "Stop reading context" kill row (C12) and the Settings tabs
  are the precedents for interactive surfaces.
- This is the **first store of conversation content** — every other persisted store carries
  metadata only. The store's shape, bound, purge semantics, and no-other-file-reaches-it pin
  are the unit's core privacy work.

**Context to verify in the dig:**
- `ConverseLoopDriver` (`VoccaBootstrap/ConverseWiring.swift`): where a turn completes
  (cleaned transcript + reply text, `converseReplySink`); the turn/session lifecycle.
- `WidgetReducerState.replyText`, the `.replyPresented` action, `ReplyClearSuppressionBox`,
  `WidgetTiming.maxReplyCharacters = 2000` (`reply-text-rendering`).
- `SessionModeMachine` / `ModeSession` reset semantics — what "turn" and "session" mean and
  what survives a mode transition (`dual-mode`).
- Menu bar construction (kill-row precedent), `SettingsTab` structure (Usage tab precedent).
- Store precedents: `PersistentUsageStore` (atomic, shape-only, byte-level pin),
  `PersistentConsentStore` (cap 512, refuse-never-clamp), `IntentPhraseStore`,
  `ActionConfigStore`.
- Test patterns: `TurnTakingComposedAcceptanceTests`, `ReplyRenderingInvariantTests`, the
  zero-network suite, and the G5 wiring pins.
