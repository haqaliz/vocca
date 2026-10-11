# turn-history — PRD

> The P3 conversation-state deliverable — the last unshipped row of P3's deliverables table
> (`ROADMAP.md:205`), kept visible across four consecutive C13 amendments as "a separate,
> unclaimed P3 item" (`CAPABILITY_ROADMAP.md:1063-1064`). Source: inline brief
> (`docs/planning/_card/issue.md`) + `understanding.md`. Dependencies shipped: C9, C10, C11.
> The four interview decisions below were confirmed by the founder 2026-10-11: persisted,
> bounded, forgettable; evict-oldest at the cap; interrupted marked, failed skipped; Settings
> tab + menu forget row. **No gate passes** — this would be the twenty-second unit ahead of the
> uncleared gates under the recorded posture (`STATUS.md:117-121`).

## Problem Statement

CONVERSING has no memory. The reply bubble is single-turn by construction (`reply-text-rendering`):
the next utterance, a barge-in, or the session's end clears it, and `ModeSession.transcript` —
one fill, replaced per start, carryover unrepresentable — is not a history. `ROADMAP.md:205`
asks for "Conversation state | Bounded, inspectable, local turn history — with a visible 'forget'
control"; none of it exists (no store, no surface, and no `turnHistory`/`HistoryStore` naming
anywhere in `Sources/` or `Tests/`). The moment a voice exchange ends, it is gone.

## Goals & Success Metrics

- A spoken CONVERSING exchange is **inspectable after the fact**: recent turns (what the user
  said and what Vocca replied) appear in a Conversation settings tab and survive relaunch.
- It is **bounded and purged by design**: oldest-first eviction at a fixed cap; one visible
  forget action clears disk and every surface; no search, no timestamps, no other metadata.
- **Interrupted turns are honest**: a barge-in'd reply is kept and marked interrupted; turns
  whose ASR or reply failed are not recorded (the dual-mode rule — the turn is not owed).
- Measured by tests and one written-and-runnable, never-gated SMOKE row. **No usage rate is
  claimed**; nothing here is an accuracy or success number.

## Persona & scenario

A Mac user mid-conversation realizes they want back what they said three turns ago — a command,
a path, Vocca's answer — instead of re-asking. They open Settings → Conversation and read the
recent turns. Later, they choose to purge: one click on the menu bar's **Forget conversation**
row (present only while history is non-empty), or the confirmed Forget button in the tab. The
exchange is gone from disk and from every surface.

## Requirements

Must-have
1. **The store.** A `ConversationHistory`-shaped store: versioned JSON under Application Support
   (one file naming `FileManager` — the per-store seam pattern; proposed name `conversation.json`),
   atomic temp→replace, tolerant decode, load-on-launch, clear deletes the file (bytes off disk,
   like the usage clear). Each record is exactly: the cleaned utterance, the reply text, an
   interrupted flag, append order. Nothing else — no wall-clock time, no bundle IDs, no IDs
   beyond what ordering needs.
2. **Bounds.** Composition-root-set caps — proposed `maximumTurns = 50` and
   `maximumTextCharacters = 2000` per text (reusing the bubble's render cap). At the cap, the
   **oldest turn is evicted** (the RecoveryJournal precedent — a deliberate, recorded divergence
   from the settings stores' refuse-never-clamp; copy discloses the window). Worst case stays
   ~≤800 KB and **cannot grow without bound**.
3. **The driver hook.** An additive, defaulted recording seam on `ConverseLoopDriver` (default
   no-op → probes and existing tests byte-identical when unwired): a turn is recorded when its
   reply is committed to speak (the `.speakReply` effect); a subsequent barge-in marks **that**
   turn interrupted — never a neighbor's (ordering pinned by test); failed turns
   (`asrFailed`/`replyFailed`/`captureFailed`) never record. The hook sits after reply
   generation: no change to the ASR, cleanup, TTS, or injection paths.
4. **The inspect surface.** Settings gains an eighth tab, **Conversation** (Usage-tab shape):
   the recent turns in order, interrupted markers visible, and a destructive-confirmed
   **Forget conversation** action (the Usage clear precedent — it removes bytes from disk).
   Read once on open through `SettingsBindings`-style closures wired at the composition root;
   an honest empty state ("No conversation yet.").
5. **The visible forget control.** A **"Forget conversation"** menu-bar row (the C12 context
   kill-row shape — `MenuBarItem`/`MenuBarCopy`), shown only while history is non-empty; one
   action clears the store and every surface.
6. **Privacy pins.** The store never egresses: the zero-network suite is unaffected and the
   store is FileManager-only. A byte-level pin asserts the store's file carries exactly the
   bounded turn list — no timestamps, no extra metadata — and the inverse constraint holds
   (`usage.json` still carries no transcript text). The store's content reaches no other file.
7. **Pins & discipline.** One deliberate G5 re-anchor of `AppBootstrap.swift` (seven pin sites,
   `shasum -a 256`, never edited-to-match; dictation digests unchanged); source-scan pins for
   the new tab/menu wiring (the `AppBootstrapWiringTests` precedents); the test floor raised
   to the real count.
8. **Docs.** `ARCHITECTURE.md`'s storage list gains the file and its bounded/purged semantics;
   `PRODUCT_SPEC.md` gains the tab row and one reconciling sentence against §12 ("No transcript
   history browser" stands — this is a bounded recent-turns window, never a browser); the
   CLAUDE.md / STATUS.md / CAPABILITY_ROADMAP.md sync and the unit record.

Should-have
- **Disclosed bound in copy** — the tab and the menu row say the window is finite ("keeps the
  last 50 turns"), so eviction is never a surprise.
- **SMOKE row** — a spoken exchange appears in the tab; a barge-in'd turn shows the interrupted
  marker; Forget clears the tab, the menu row, and the file — written, runnable, recorded,
  never gated.

Nice-to-have (deferred, named)
- Per-session grouping; wall-clock timestamps; copy-a-turn (blocked by the non-key panel — the
  N1 precedent); an in-widget/expanded-panel surface (`PRODUCT_SPEC.md:421` §13.3); configurable
  retention; merging near-duplicate turns.

## Technical Considerations

- **Phase P3**, layer: TTS / voice-loop (conversation state). Local-only — no cloud, no BYOK,
  no transport; the dictation path is byte-for-byte untouched (digests pinned).
- **Actors.** The driver is `@MainActor`; the store follows the actor + injected-filesystem
  precedent (`PersistentUsageStore`/`PersistentConsentStore`: atomic, tolerant, injected `log`).
  The driver hook is non-blocking and failure-tolerant — a store failure is a value, never a
  thrown interruption of the conversation (the `local-data-provider` lesson).
- **Placement.** The store lives with the converse machinery in `VoccaBootstrap` (beside
  `ConverseLoopDriver`/`ConverseWiring`); `VoccaCore` stays Foundation-free; `VoccaUI` defines
  its own tab view-model and the root maps store types to it (the `UsageSnapshot`/`SettingsBindings`
  precedent). No new module this unit.
- **Interrupt attribution.** The barge-in mark is identity/order-addressed to the turn whose
  reply was playing (the driver's effect order is the only place that knows), not inferred by
  the surface.
- **Load.** One launch-time load (the usage recorder's launch-load precedent); the tab renders
  the loaded snapshot; read-on-open keeps the surface simple and observation-free.
- **Invariants kept:** mode reset is untouched (the history is not `ModeSession.transcript`);
  zero-network default; no-child default; a transcript is never lost; `PROBE-CONVERSE` and the
  other probe lines byte-identical.

## Risks & Open Questions

- **The first conversation-content store raises the privacy bar** (`ARCHITECTURE.md:809` — "must
  not accumulate a shadow archive"; `PRODUCT_SPEC.md:409` — "bounded, purposeful, and purged").
  Mitigated by bound + forget + no search/timestamps + byte pins — but this is the feature's core,
  not a detail, and the plan must treat it as such.
- **Silent eviction** is a deliberate divergence from "caps refuse never clamp" (the settings
  stores) toward the RecoveryJournal's oldest-first eviction; disclosed in copy, pinned by test.
- **Interrupt attribution** must be pinned by an ordering test (a turn after a barge-in must not
  mark the wrong record).
- **The non-key panel** is why the surfaces are Settings + menu only; the widget bubble itself is
  untouched.
- **No gate passes**; no external user has ever run the app. R11-adjacent (privacy erosion) is
  answered locally by the bound + forget, but the retention posture is the unit's own risk to
  own.
- **Open (founder, at the gate):** (a) the menu row one-action vs confirmation — the split
  precedents are the one-action context kill switch vs the confirmed Usage clear; (b) the bound
  values (50 turns / 2000 chars proposed); (c) read-on-open vs live-updating tab.

## Out of Scope

Search/browse, export/sync, wall-clock timestamps, per-session grouping, dictation-turn history,
recovery-journal changes, any widget/expanded-panel surface, in-widget interaction, the copy
affordance, spoken controls, retention policy beyond the fixed bound, cloud, and the P3→P4 gate
evidence work.

## Self-critique (prd-generator, Phase 4)

| Dimension | Rating | Note |
|---|---|---|
| Problem definition | 🟢 | The gap is verified in code (single-turn bubble, no store naming anywhere) and in four recorded deferrals. |
| User understanding | 🟡 | Founder-shaped; zero user requests exist for this (or any) unit — roadmap completeness, not demand. |
| Success metrics | 🟡 | Tests + one never-gated SMOKE row by design; no rate may be quoted. |
| Scope clarity | 🟢 | Flat bounded turns; search, export, timestamps, grouping all explicitly out. |
| Edge cases & risks | 🟡 | See gaps 1-3. |
| Feasibility | 🟢 | Store precedents and a defaulted driver seam over shipped, tested parts. |
| Scope & layer fit | 🟡 | Local-only and pluggable untouched; but it is the 22nd unit ahead of the uncleared gates and the first persisted conversation content — the privacy weight is real. |

### Top gaps

1. 🟡 **The privacy design is the feature.** A persisted record of what the user said is the
   opposite direction from `usage.json`'s no-text pin; the bound, the forget action, the
   no-timestamps rule, and the no-other-file pin are the whole justification. The spec must
   make each one an acceptance test, not a promise.
2. 🟡 **Interrupt marking is a timing contract.** The driver's effect order is the only thing
   that knows which turn a barge-in interrupted; the acceptance must pin an ordering case
   (speak → barge-in → next turn) so a later turn cannot be marked in its place.
3. 🟡 **The forget friction split is unresolved** (menu one-action vs Settings confirmed) —
   carried to the gate as an open question rather than silently chosen.
4. 🟡 **Eviction semantics diverge from the repo's cap convention** — deliberate (RecoveryJournal
   precedent), but the divergence and its copy disclosure must be recorded, or it reads as drift.

### The hard question

The question I'd want answered before greenlighting this: this is a persisted archive of what
people say to Vocca, on a build that has cleared **none** of its gates and that no external user
has ever run — and the deliverable it satisfies is completeness of P3's table, not one leg of
any gate. If the slot is spent here, why is a 50-turn persisted store the right privacy trade
versus an in-memory (app-run) history that satisfies "bounded, inspectable, local" with no bytes
of conversation ever at rest? If the answer is "the 'forget' control implies retention", say so
in the record — and then the bound and the forget action carry the entire privacy argument.
