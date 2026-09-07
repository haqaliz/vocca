# Aspect spec: usage-tab

> Parent PRD: `docs/planning/daily-use-ledger/prd.md` · Aspect 5 of 5, the last
> Depends on: `usage-wiring` (the window is live, loaded at launch, folded per session)

## Problem slice

Put the ledger in front of the user: a sixth Settings tab showing what Vocca observed, and a
control that clears it.

`PRODUCT_SPEC.md:338` already promises this — *"**No usage analytics.** Metrics are local and
inspectable."* Inspectable has been aspirational until now. This is the aspect that makes it true,
and the tab's job is as much **privacy disclosure** as dashboard: it is the screen a sceptical
local-first user opens to check what Vocca keeps about them.

## In scope

- `SettingsTab.usage` — the **sixth** case (`general, speech, cleanup, dictionary, apps` exist).
- `Sources/VoccaUI/Usage/UsageTabState.swift` — a snapshot row type, `UsageTabState`,
  `UsageTabAction`, `UsageTabReducer`. Pure, `VoccaCore` only, no SwiftUI.
- `Sources/VoccaUI/Usage/UsageTabCopy.swift` — every user-visible string.
- `Sources/VoccaUI/Usage/UsageSettingsPage.swift` — the view, internal, thin.
- `SettingsBindings` closures to load and clear, wired in `AppBootstrap.showSettings()`.
- A `PRODUCT_SPEC.md` entry under §7, because the copy tests pin strings **against the spec**.

## What it shows

Streak, days active, sessions, the outcome tallies, the rung breakdown, latency, and the
onboarding column kept separate. All of it read once, per the house pattern.

## Five honesty requirements — each testable, none negotiable

1. **Never a gate verdict.** The tab reports what Vocca observed. It must not state or imply that
   the P0 gate has passed. A "7-day streak" rendered as an achievement badge is the overclaim this
   repository's rules forbid; a streak stated as a fact about days is not.
2. **"Not recorded" is distinct from zero.** A day with no latency samples renders `n/a`, never
   `0 ms` (`LatencySpan.Presence.notPresent`; `LatencyBenchmarkRealEngineTests.swift:75-76`).
3. **A percentile is a bound, not a spot value.** `LatencyBucketBound` exists so the UI cannot
   render bucket resolution as false precision. Copy says "at most 400 ms", never "400 ms".
   Overflow reads as "over 5 s", never an invented number.
4. **The rung tallies are not an injection-success rate.** The matrix owns that denominator, and
   it is structurally capped at 17/20 on this machine (`docs/STATUS.md:44-46`). The tab shows
   counts of what happened, never a percentage that could be mistaken for the P2 figure.
5. **Onboarding is labelled, not merged.** A setup demo's numbers sit under their own heading.

## The Clear control

`confirmationDialog` with `.destructive` and `.cancel` — the **Speech** treatment
(`SpeechSettingsPage.swift:36-37,59-70`), not the Apps one. The codebase draws the line at
reset-what-was-derived (a plain button plus a scoping sentence) versus delete-bytes-off-disk (a
confirmation), and clearing the ledger deletes bytes and is unrecoverable.

Clear must empty **both** the in-memory window and the file, pinned by a test. A disclosure whose
Clear is cosmetic is worse than no disclosure.

## House patterns to follow, not reinvent

- **No `ObservableObject`, no actor observation.** `@State` plus a snapshot struct pulled once
  through an async closure in `.task` (`AppsSettingsPage.swift:33,74-76`). The snapshot type exists
  so actor-owned types never cross the module line (`AppsTabState.swift:17-23`).
- **The tab must not change while it is being read** (`AppsTabState.swift:102-104`): "nothing here
  should change while a user is reading it". No live ticking.
- **Read through a fresh store**, as the Apps tab does (`AppBootstrap.swift:1258`, `:703-714`).
- **No `DesignTokens`.** `VoccaTheme` is the widget's vocabulary; no settings page uses it, and
  colouring a "delivered" count with `VoccaTheme.State.delivered` would violate the badge/state
  separation at `DesignTokens.swift:41-43`.
- **Views are executed by nothing in CI.** The reducer is tested, the copy is tested, the view is
  not — and its doc comment says so, as every page's does.

## Acceptance criteria (tests written first)

| # | Test | Asserts |
|---|---|---|
| E1 | `SettingsTab.allCases` is the six shipped tabs, and `usage` has a distinct title, symbol and id | The exact-list pin, deliberately updated from five |
| E2 | The reducer's default state is "not loaded yet" and renders differently from "loaded, empty" | `AppsTabReducerTests`' first structural test — the two must not look alike |
| E3 | A loaded snapshot produces rows for the days it holds, newest first | Ordering is a decision, not an accident |
| E4 | A day with no latency samples renders the `n/a` copy, never `0` | Honesty 2 |
| E5 | A percentile renders as a bound ("at most N ms"); an overflow renders as "over 5 s" | Honesty 3 |
| E6 | Onboarding counts render under their own label and are never summed into the real-work totals | Honesty 5 |
| E7 | No rendered string is a percentage of injection success | Honesty 4 |
| E8 | Clear empties the in-memory state **and** asks the store to clear; a cancelled dialog clears nothing | The control is real |
| E9 | Copy is pinned byte-for-byte against `PRODUCT_SPEC.md`'s wording | `AppsTabCopyTests`' convention |
| E10 | `UsageTabState` equality distinguishes every field | The structural precedent |
| E11 | A wiring pin over `showSettings()` — the bindings read the usage store and the clear closure reaches it | `SessionKindWiringTests` / `SpeechTabWiringTests` shape |

## Risks

| Risk | Mitigation |
|---|---|
| The tab reads as a gate verdict | Honesty 1, pinned in copy tests; no badge, no checkmark, no "passed" |
| A percentile printed as a spot value | `LatencyBucketBound` makes the honest rendering the easy one; E5 pins it |
| The rung tallies get quoted as an FMS number | E7, and copy that names them counts |
| Copy lands with no spec behind it | The `PRODUCT_SPEC.md` entry ships in this aspect, before the copy tests pin it |
| A sixth tab crowds a 640×500 window | The detail area is ~450×500; keep the page to one screen with no nested panels (`PRODUCT_SPEC.md:250`) |

## Note

This is the aspect that ships to users. Everything before it was internal: a defect fix, pure
vocabulary, a file, and wiring. This is the part a Product Hunt visitor opens.
