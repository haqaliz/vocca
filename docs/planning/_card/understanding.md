# feat/turn-history — understanding note

Source: `docs/planning/_card/issue.md` (inline brief, vocca-next handoff 2026-10-11). Codebase
maps: four parallel exploration passes over the worktree (PR lineage #55–#59, docs map, source
map, plus the roadmap sweep).

## What this work is really asking

`docs/ROADMAP.md:205` — the P3 deliverables table's last unshipped row: **"Conversation state |
Bounded, inspectable, local turn history — with a visible 'forget' control"**. The repo's own
docs keep it visible across four consecutive C13 amendments: "not machinery, named so it is not
lost … a separate, unclaimed P3 item" (`docs/technical/CAPABILITY_ROADMAP.md:1063-1064`; also
`:873-877`, `:946-947`, `:1003-1004`). Dependencies are shipped: C9 (TTS), C10
(turn-taking/barge-in), C11 (dual-mode).

Today there is **no conversation state beyond the live turn**: the reply bubble is single-turn
by construction — `reply-text-rendering` (PR #56) renders the current reply and the carrier's
`nil` clears it on the next utterance, barge-in, or session end. The moment the turn ends, the
exchange is gone. This unit is the first store of **conversation content** in the tree.

## The code as it stands (map)

**Driver** — `Sources/VoccaBootstrap/ConverseLoopDriver.swift` (`@MainActor`, :83). A turn's two
texts exist at exactly one point: `runUtterancePipeline(utterance:)` (:371) — the cleaned
transcript (:404-409) and the computed reply (:420-442, before `loop.scheduleReply`). Effect
application (:331): `.speakReply(text)` → `converseReplySink(text)` **before** render (:345-346);
`.bargeIn` → `converseReplySink(nil)` (:352); `.captureFailed` → `failureSink` (:359). The
init's `onStateChange` (:272-281) sends the sink `nil` when state returns to `.listening`/`.idle`.
`ConverseTurnFailure` (`Sources/VoccaCore/TurnTaking/ConverseTurnFailure.swift:27`):
`.asrFailed` / `.replyFailed` / `.captureFailed`.

**Widget** — `Sources/VoccaUI/WidgetStateReducer.swift`: `WidgetReducerState.replyText` (:115),
`.replyPresented` (:209; lands only while `.conversing` :349-362, `nil` clears from any state),
adoption keeps `replyText` across phase changes inside `.conversing` (:407-420) and clears it on
`.recording/.transcribing/.delivered/.idle/.opening`; `WidgetTiming.maxReplyCharacters = 2000`
(:242). **The panel is non-key**: `WidgetPanel.canBecomeKey == false` (`WidgetPanel.swift:134`) —
the recorded blocker of the N1 copy affordance.

**Mode machine** — `Sources/VoccaCore/Mode/SessionModeMachine.swift:59`: one `session` slot
replaced per start (:74), epoch-minted `ModeSession` (:31); **carryover is unrepresentable**, and
the mode-transition invariant demands full reset of buffer, transcript, target (C11; exercised
by `ModeResetTests`, cited `ARCHITECTURE.md:996`). A history store must not be that transcript
field. Session end paths: `applyModeEffect` (`AppBootstrap.swift:3512-3542`), `converseLoopEnded`
(:3599).

**Surfaces (precedents)** — menu bar: `MenuBarItem.swift:30/87/153`, the C12 kill row
(`onKillContext`, :93; "Stop reading context", `MenuBarCopy.swift:157`) shown only while
`contextReading` (:177-186). Settings: `SettingsTab.swift:29` (7 cases; `.usage` :45),
`SettingsView.page(for:)` (:451-460); the **Usage tab** is the inspect-and-clear precedent
(`Usage/UsageSettingsPage.swift:38` — read once in `.task` :53-56, destructive-confirmed clear
:57-64 awaiting `bindings.clearUsage()`; `SettingsBindings` :24, wired at `AppBootstrap.swift:2038/:2053`).

**Stores (precedents)** — all actors, atomic temp→`replaceItemAt`, tolerant decode, injected
`log`, one file naming `FileManager` (the seam-lint pattern): `PersistentUsageStore`
(`usage.json`, v1 :158; byte-level pin "no transcript text" :390 of its test file; shape-only
per `ARCHITECTURE.md:906-910`), `PersistentConsentStore` (cap 512, **refuses never clamps**
:224-237), `IntentPhraseStore` (caps refuse :70-79), `RecoveryJournal` — the only other
bounded **text** store: **bounded eviction oldest-first at a composition-root-set capacity,
purge-on-resolve, load-on-launch** (`ARCHITECTURE.md:817-821`), under the principle "a privacy
tool must not accumulate a shadow archive of everything you ever said" (:809). Every store is
versioned JSON behind a one-file seam (`ARCHITECTURE.md:913-919`).

**Composition** — the converse wiring is composed at `AppBootstrap.swift:582-621`
(`composeConverseWiring(… converseReplySink: { root.widgetStore.presentReply(...) })`); stores
are constructed near their modules. Any `AppBootstrap.swift` edit re-anchors the **G5 digest at
7 pin sites** (`TurnTakingComposedAcceptanceTests:380`, `AgentPresetsInvariantTests:419`,
`SpokenTaskInvariantTests:328`, `ActiveProjectInvariantTests:470`, `WiringBaselineTests:365`,
`AuthBaselineInvariantTests:399`, `ReplyRenderingInvariantTests:577`), `shasum -a 256`, never
edited-to-match; dictation digests unchanged. Floor script: `Scripts/test-with-floor.sh:2467`
(`MINIMUM_EXECUTED_TESTS=3161`).

No `turnHistory`/`HistoryStore` naming exists anywhere in `Sources/` or `Tests/`. Zero GitHub
issues exist; there is no demand-pull record for this (or any recent) unit.

## Tensions and contradictions surfaced (not papered over)

1. **The deliverable vs the privacy non-goal.** `ROADMAP.md:205` asks for a history;
   `PRODUCT_SPEC.md:409` says "**No transcript history browser.** A searchable archive of
   everything you've ever said is a liability … bounded, purposeful, and purged", and
   `ARCHITECTURE.md:809` forbids shadow archives. Reconciliation: a **bounded recent-turns
   window with a purge**, never search, never export, never grouping — the recovery journal's
   shape applied to conversation turns.
2. **`PRODUCT_SPEC.md:421` (§13.3) is an open design question** — "where the agent's replies
   render — inside the widget, or an expanded panel … deserves its own pass with mockups". The
   bubble shipped anyway (PR #56); this unit is the *conversation-state* row, not that question.
   The non-key panel means any in-widget interaction (scroll/copy/forget) is out of reach today.
3. **Cap semantics: two precedents conflict.** Settings-like stores **refuse** at cap
   (consent, phrases); the only bounded text store, the recovery journal, **evicts oldest-first**.
   The handoff brief assumed refuse; the dig shows eviction is the text-store precedent. The PRD
   must pick one deliberately and record why.
4. **Barge-in "discarded cleanly" vs history.** The bubble clears on barge-in and dual-mode says
   a failed turn "is not owed". What an interrupted turn leaves in history (marker / nothing /
   the full reply) is a product decision with a privacy flavor.
5. **Mode-reset invariant.** The history store is not `ModeSession.transcript`; mode transitions
   still reset session state fully (C11's tests stay untouched).
6. **Scope boundaries.** CONVERSING turns only — not dictation history, not the recovery
   journal, no search, no timestamps (the usage.json pin keeps even wall-clock time out of
   metadata; ordering may suffice).
7. **No gate passes** — this would be the 22nd unit built ahead of the uncleared gates under the
   recorded posture (`docs/STATUS.md:117-121`). No code unit advances the gates; record it.

## Challenge pass (for the interview)

- **What happens if we don't build it?** The bubble stays single-turn; the P3 table keeps one
  row unshipped; no gate leg blocks on it. It is completeness of the wedge, not a gate-clearing
  unit — say so honestly.
- **Six months later it failed — why?** (a) it drifted into a shadow archive (unbounded, or
  searchable) and violated the product's own privacy line; (b) the inspect/forget surface was
  put in the non-key widget and shipped unusable; (c) interrupted/failed turns were recorded as
  if complete, breaking the "discarded cleanly" expectation; (d) scope creep into dictation
  history, cross-session analytics, or sync.
- **What are we choosing not to build?** Search/browse, export, timestamps, per-session
  grouping, dictation-turn history, in-widget interaction, any cloud/sync.

## Affected areas

`VoccaBootstrap` (driver hook + the store + wiring), `VoccaUI` (settings tab + menu row + copy),
possibly `VoccaCore` (a Foundation-free `ConversationTurn` record), `AppBootstrap` (composition
+ G5 re-anchor), tests (new store suite, reducer/tab suites, zero-network suite untouched, the
7 pin sites), docs (`ARCHITECTURE.md` storage list :898-919, `PRODUCT_SPEC.md` if the surface
lands there, `SMOKE_CHECKLIST.md` rows, the unit record).

## Open questions for the founder (Phase 3)

1. Persistence scope — persisted across launches, this app run, or this session?
2. Cap semantics — evict oldest vs refuse newest; and the bound values.
3. Incomplete turns — interrupted (barge-in) and failed turns: recorded, marked, or dropped?
4. Surfaces — Settings tab + menu forget row, Settings only, or an expanded panel?
