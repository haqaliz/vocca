# Card: feat/daily-use-ledger

> Inline brief — no GitHub issue exists (`gh issue list` → "No Issues"; Issues are empty for
> `haqaliz/vocca`). Source: the `vocca-next` handoff of 2026-09-06.

## Brief

Persist the in-memory `LatencyLedger` (`Sources/VoccaCore/LatencyLedger.swift`) as a bounded,
local-only, **shape-only** usage ledger and surface it in Settings, so the P0 gate's three legs
(`ROADMAP.md:100-104`) become recorded evidence rather than founder memory.

This is C7's unfulfilled **"never transmitted, inspectable by the user"** clause
(`CAPABILITY_ROADMAP.md:176`) and P0 week 4's **"local-only latency/success counters"**
milestone (`ROADMAP.md:86`). Both halves were deferred by an explicit *scope* decision, not by a
blocker: `docs/planning/latency-instrumentation/prd.md:99` ("A small bounded on-disk history —
deferred: in-memory only this slice (confirmed)") and `:150` ("A settings/UI surface for the
histogram (deferred with the settings work)"). The settings shell that `:150` was waiting on
shipped 2026-09-01 (`Sources/VoccaUI/Settings/`, `SettingsTab.swift`; General/Cleanup/Speech/Apps
tabs exist). `docs/STATUS.md:728` records the current state plainly: "**The ledger is
in-memory**: no persistence, no UI surface, nothing ever transmitted."

## Why this unit, now

`docs/STATUS.md:49` records the P0 gate as unmet — "its 7 consecutive days of founder dictation
have not started accumulating." The gate's three legs are 7 consecutive days, transcript loss
**exactly 0%**, and injection success ≥90% (`ROADMAP.md:100-104`). None of the three has an
instrument today. Every planning doc that touches the gate carves the log out as a founder
activity (`p2-gate-measurement/prd.md:194`, `unmeasured-numbers-sweep/prd.md:249`,
`deterministic-cleanup/prd.md:6`, `llm-cleanup/prd.md:7,10`) — this unit builds the instrument
that makes those legs recordable instead of remembered.

## Acceptance (test-first, before any implementation)

1. The ledger round-trips across a process restart and evicts beyond a bounded retention window.
2. A persisted record for a session carrying a known phrase never contains that phrase in its
   encoded form — **shape only, no transcript text**.
3. Streak accounting: N consecutive local-time days with ≥1 delivered session yields streak N;
   a gap day resets it.
4. The transcript-loss counter increments only when a session ends without recoverable text, so
   the gate's 0% is derivable; per-rung counts yield first-method-success from real use.
5. The zero-network probe and the CI release-blocker stay green with the ledger enabled, and the
   Settings surface offers an explicit clear/reset control.

## Caveats carried in from the handoff

- **This instruments the gate; it does not pass it.** Seven real days of founder dictation still
  have to happen. No streak number may be quoted until they accumulate.
- **R11 governs the design** (`ROADMAP.md` risk register — "privacy promise erodes quietly",
  Med/**Fatal (positioning)**). This introduces a *new on-disk artifact* into a product whose
  promise is that nothing persists. Shape only — counts, span durations, rung outcomes,
  timestamps — never transcript text; user-clearable; the zero-network CI release-blocker stays
  green. The existing `session opened` / `delivery` log lines are the precedent: shape, never
  content.
- **Suite floor**: `Scripts/test-with-floor.sh:1444`, `MINIMUM_EXECUTED_TESTS=1758` — never drops;
  ratcheted in the same commit as any test-count change. Note the STATUS prose "Floor 1758 → 1760"
  (`docs/STATUS.md`, matrix entry) is loose: `1985da6` changed only `Scripts/injection-matrix.sh`
  and its message reads "1760 tests, 0 failures (floor 1758)" — 1760 is the *executed* count, not
  a new floor. The binding Swift floor is **1758**.

## Adjacent context (not this unit's scope)

- The previous unit (`injection-matrix-completion` → `matrix-run` continuation) was recorded as
  the founder's **last milestone before the Product Hunt publish**. A PH publish is therefore
  pending; this unit adds a user-visible Settings surface, so it lands in front of those users.
- The matrix's remaining 7 deliverable rows, step 92, and the Terminal/Warp re-run stay open and
  are **not** this unit's work.
