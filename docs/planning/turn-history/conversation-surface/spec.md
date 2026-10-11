# conversation-surface — aspect spec

Aspect 3 of `turn-history`. Source: `../prd.md` (approved 2026-10-11), aspects 1-2 shipped.
Planning decisions: the menu row is **one-action** (the C12 kill-row shape) while the Settings
Forget is **destructive-confirmed** (the Usage-clear shape) — the split is recorded and remains
open to the founder at review; the tab is inserted after `.actions`; the store is constructed in
AppBootstrap with an `onChange` fold into `MenuBarConditions.isHistoryPresent`.

## Problem slice / outcome

The visible half: recent turns render in an eighth Settings tab with interrupted markers and a
confirmed Forget; a "Forget conversation" menu row appears only while history exists and clears
it in one action; both are wired from the composition root. The widget bubble and the non-key
panel are untouched.

## In scope

- `SettingsTab`: eighth case `.conversation` (title "Conversation", symbol), page switch row,
  `SettingsTabTests`/`SettingsCopy` narrative updated.
- `VoccaUI/Conversation/`: `ConversationTabState` (+`ConversationSnapshot`, `ConversationTurnRow`,
  actions, reducer), `ConversationTabCopy`, `ConversationSettingsPage` — the Usage-tab shape:
  read-on-open `.task`, list rows, interrupted marker, empty state ("No conversation yet."),
  destructive-confirmed Forget; the bound disclosed in copy ("keeps the last 50 turns").
- `SettingsBindings` gains `loadConversationSnapshot: () async -> ConversationSnapshot` (default
  empty) and `clearConversation: () async -> Void` (default no-op).
- `MenuBarConditions.isHistoryPresent` (defaulted false); `MenuBarItem` gains the defaulted
  `onForgetConversation` closure, `apply(..., historyPresent:)`, and the conditional row
  (mirroring the context kill block); `MenuBarCopy` gains the row title + accessibility label.
- `AppBootstrap` (the unit's **only** hash-sensitive edit): construct
  `ConversationHistoryStore()` (default directory), launch-load task, root slot, pass the store
  as the driver's `conversationRecorder`, `onChange` → `updateMenuBarConditions`, the two
  SettingsBindings closures mapped from the store, the menu closure → `store.clear()`, and the
  call-site forward of both conditions (F1 below).
- Pins: source-scan additions to `AppBootstrapWiringTests` (store construction, recorder passed,
  bindings closures present, the call site forwards both conditions); `MenuBarStateTests`
  additions (fact default, row shape over the defaulted closure, copy pinned); one deliberate G5
  re-anchor (seven sites, `shasum -a 256`, dictation digests unchanged).

## Out of scope

The store (aspect 1); the driver hook (aspect 2); docs/floor/SMOKE (aspect 4); widget/expanded
panel surfaces; copy-a-turn; live-updating tab (read-on-open only); any change to the card,
bubble, mode machine, context surfaces, or dictation.

## Acceptance criteria (the failing tests, written first)

S1 **Tab**: `SettingsTab.allCases` has eight cases in order (…, actions, conversation, usage);
title/symbol pinned; the page switch routes `.conversation` to the new page; sidebar iterates.
S2 **Page**: read-on-open loads a snapshot once; rows render utterance + reply + an interrupted
marker; empty state copy; Forget is destructive-confirmed, awaits `clearConversation` **before**
folding `.cleared` (the usage "store first, page second" order, pinned); reducer/state/copy
suites green.
S3 **Menu surface**: `MenuBarConditions().isHistoryPresent == false`; `apply(.ready,
historyPresent: true/false)` constructs/deconstructs the row and never fires the closure (the
kill-row test's shape); copy exact-equality pinned ("Forget conversation", accessibility label).
S4 **The call-site fix (finding F1, recorded)**: `onMenuBarConditionsChanged` forwards
`contextReading: conditions.isContextReading` **and** `historyPresent:
conditions.isHistoryPresent` to `apply`. The finding: before this unit the shipped call site
never forwarded the context fact, so the C12 kill row could not render at runtime (tests called
`apply` directly; the row is window-server glue executed by nothing in CI). The fix is pinned by
a source-scan test on the call site and changes exactly that behavior.
S5 **Clear paths**: the menu closure clears the store and folds the condition false; the Settings
path clears and the tab reflects `.cleared`; after clear the store file is gone (asserted in the
wiring suite over a temp store).
S6 **Composition pins**: AppBootstrap constructs the store with the real directory helper; the
launch-load and the `onChange` fold update `isHistoryPresent` (non-empty → true, empty → false);
the recorder passed to `composeConverseWiring` is the store; probes byte-identical
(`PROBE-CONVERSE`, `PROBE-INTENT-DEFAULT`, `PROBE-CODING-AGENT`); zero-network suite green.
S7 **G5**: exactly one deliberate re-anchor computed with `shasum -a 256` and applied at all seven
sites with history comments; dictation digests `1baeb2de…`/`ce70ca10…` unchanged.

## Risks

The menu behavior change (F1) is a restored intended surface, not a new feature — recorded in the
unit record, not hidden in a diff. The one-action/confirmed split is a UX decision the founder
can flip at review (copy and tests are localized). The AppBootstrap edit is one commit; the G5
re-anchor is the unit's single deliberate one.
