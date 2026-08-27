# apps-tab — spec

> Aspect of `injection-strategy-memory` (C8, P2). PRD: `docs/planning/injection-strategy-memory/prd.md`
> (R7, S2, X1). Product pin: `docs/product/PRODUCT_SPEC.md:275` (§7 **Apps**).
>
> **Sequencing note:** the **LAST** aspect of the unit — built after `core-memory`,
> `store-seam` and `memory-order`, per the review gate, so it is built against the shipped
> `InjectionStrategy` value type, the shipped `InjectionStrategyStore`, and the calibrated
> matrix's learned-state shapes rather than against promises. It is planned here in parallel,
> but its tests are written against what those aspects have already shipped.

## Problem slice

The ladder learns (R2–R6 ship in `core-memory`/`store-seam`/`memory-order`), but nothing
says so to the user, and nothing lets them overrule it. `PRODUCT_SPEC.md:275` promises an
**Apps** tab: "per-app injection strategy and overrides, with a plain-language health column
(`typing directly` / `pasting` / `manual only`) and a 'reset what Vocca learned' button."
This aspect is that surface — the one place the user sees what Vocca learned per app, pins a
wrong call absolutely (S2), and wipes the learned state without touching what they told it
explicitly. It is a display + override + reset surface over the store the ladder reads; it
adds **no** memory logic of its own.

## In-scope

- **A fifth `SettingsTab` case (`.apps`)** (`Sources/VoccaUI/SettingsTab.swift`): appended to
  `SettingsTab.allCases`, with `title: "Apps"` and a symbol. The `ForEach(SettingsTab.allCases)`
  in `SettingsView` and the exhaustive `page(for:)` switch gain the branch — a new case cannot
  break the existing tab iteration (no tab test exists today; the exhaustive switch is the
  compile-time guard).
- **The Apps page** (`Sources/VoccaUI/Apps/AppsSettingsPage.swift`, glue): a `Table` of per-app
  rows — the `DictionarySettingsPage` template (`SettingsView.swift:203-285`): Table + row
  actions + `saveError` surface, reachable through `SettingsBindings` closures wired by
  `AppBootstrap.showSettings` to the **same persistent store the ladder reads** (the dictionary
  pattern, `AppBootstrap.swift:844-847`). **The page never touches `VoccaInject`** — the module
  boundary rule (`ModuleBoundaryTests`, `VoccaUI` imports only `VoccaCore`) is the same
  mechanism the dictionary tab already satisfies.
- **A pure headless reducer + state** (`Sources/VoccaUI/Apps/AppsTabState.swift`), the house
  style (`EnginePickerStateReducer` / `FailsafeStateReducer` / `OnboardingReducer`): over an
  **injected store snapshot** it derives the row set (bundleID + display name + health +
  overridden flag), folds override set/clear, folds reset-learned, and folds save success/failure
  into the `saveError` surface. No clock, no I/O, no store call in the reducer.
- **Pinned copy** (`Sources/VoccaUI/Apps/AppsTabCopy.swift`), the `BadgeCopy`/`EnginePickerCopy`
  shape: the health labels and the reset-button wording pinned **byte-for-byte** against
  `PRODUCT_SPEC.md:275`.
- **Override semantics (S2), made visible and testable here**: an override is an **absolute,
  frozen** pin — memory neither demotes, promotes, nor re-probes an overridden app. The override
  round-trips through the same `strategies.json` via the `store-seam` aspect. The Apps tab shows
  an overridden row distinctly from a learned row, and its health column shows the override's
  health, never the learned one.
- **Reset-learned semantics, decided here**: "reset what Vocca learned" clears learned state
  (demotions, learned allowlist, re-probe windows, learned rungs) for **all** apps back to their
  seeded baselines and **preserves explicit overrides**. See *Reset* below for the rationale and
  the exact testable contract.

## Out-of-scope

- **No matrix, no harness, no measured number** — the ≥95% matrix and its 20+ app list are the
  `matrix-smoke` aspect; this tab renders the store's existing learned state, whatever the
  matrix later measures.
- **No memory logic beyond display + override + reset.** Demote-on-fail, re-probe eligibility,
  promotion and the `orderedRungs(for:)` projection are `core-memory`/`memory-order` decisions.
  This aspect does **not** implement the freeze — it writes the override that `memory-order`'s
  decisions honor, and pins the freeze contract with a test over those shipped decisions (S2).
- **No hotkey rebind, no permission status display** (N1, deferred), no activation-mode work —
  the General tab and the deferred settings surface own those.
- **No per-app override for apps Vocca has never seen being injected into as a "matrix"** — an
  override on an unknown app *creates* its row (the override IS a strategy), but this aspect
  does not enumerate the user's installed apps; rows are exactly the apps present in the store
  snapshot.
- **No display-name resolution machinery in the reducer** — names arrive in the injected
  snapshot (the wiring resolves them via LaunchServices); CI feeds fake names.

## Acceptance criteria (test-first)

Named test cases (all under `Tests/HarnessTests/`, the headless half):

1. **Health mapping table — every effective-first-rung state maps to the spec's three labels.**
   `AppsTabCopyTests.testHealthLabelsMatchTheSpec` pins `typing directly` / `pasting` /
   `manual only` byte-for-byte to `PRODUCT_SPEC.md:275`; `AppsTabReducerTests` pins the mapping
   for every state: learned first rung `.accessibility` → `typing directly`;
   `.clipboardPaste` → `pasting` (this is what a **seeded-hostile** Docs/Slack app and a
   **demoted-AX** app both read, per the shared vocabulary); `.keystrokeSynthesis` →
   `manual only`; `.widgetFailsafe` never appears in a strategy (R2) and maps defensively to
   `manual only` (documented, one row). `testHealthMappingTableForEveryEffectiveFirstRung`.
2. **Override pins the order and freezes learning.** `testOverrideSetPinsTheRungsAndMarksTheRowOverridden`
   asserts the row flips to overridden and its health becomes the override's (not the learned
   first rung). `testADemoteOrReProbeEventForAnOverriddenAppLeavesItUntouched` drives the
   `memory-order` decision entry point (Core) with the overridden strategy the reducer produced
   and asserts the strategy is **byte-for-byte unchanged** — S2's absolute freeze, pinned
   end-to-end. (Sequencing: this is why the aspect is LAST; if the freeze is absent the test
   fails until `memory-order` lands it — a blocker by construction, not by review.)
3. **Reset restores seeded defaults and preserves overrides (decision made: overrides survive).**
   `testResetRestoresSeededDefaultsForEveryApp` asserts a previously **promoted** app returns to
   its seeded baseline rung, a **demoted** app's demotion and re-probe window are cleared, the
   learned allowlist is cleared, and every non-overridden app equals
   `InjectionStrategy.seededBaseline(bundleID:)`. `testResetPreservesExplicitOverrides` asserts
   an overridden app keeps its override and still shows the override's health after reset.
   `testResetOnAnEmptyStoreIsANoOp`.
4. **Copy pins against `PRODUCT_SPEC.md:275`.** `AppsTabCopyTests.testResetButtonCopyMatchesTheSpec`
   pins `reset what Vocca learned`; `testOverrideMethodLabelsMapToTheHealthVocabulary` pins the
   three picker methods to the three health labels (type directly / paste / manual).
5. **The tab renders from reducer state.** `testSnapshotLoadedBuildsRowsSortedByDisplayName`
   asserts the reducer's derived rows (bundleID, displayName, health, isOverridden) are what the
   page's `Table` renders — the page is thin glue over `AppsTabState` (the `EnginePickerView` /
   `DictionarySettingsPage` pattern), executed by nothing in CI (window-server rule).
   `testDefaultStateIsLoadedFalseWithNoRows` and `testAnEmptyStoreShowsTheEmptyState` pin the
   empty surface.
6. **Existing tab tests still pass; the new case is total.** No `SettingsTab` test exists
   today, so the guard is: `SettingsTab.allCases` gains `.apps` (a test asserts the case exists,
   its title, and that `allCases` count is 5), `SettingsView.page(for:)`'s exhaustive switch
   compiles with the new branch, and the whole suite stays green at the raised floor.
7. **Save failure is a surface, never a swallow.** `testSaveFailureSurfacesAnErrorAndSaveSuccessClearsIt`
   — the `DictionarySettingsPage` rule: a store write that fails is visible, and a later success
   clears it.

## Dependencies / sequencing

- **Before:** `core-memory` (`InjectionStrategy` value type, pure decisions, seeded-baseline
  entry), `store-seam` (`InjectionStrategyStore` protocol + `PersistentStore` round-tripping the
  `overrideRungs` field through `strategies.json`), `memory-order` (the freeze in its decision
  functions, the recorder). This aspect consumes all three; it is the LAST aspect, per the review
  gate.
- **Contract with `store-seam`:** the override is a field on the per-app `InjectionStrategy` —
  `overrideRungs: [InjectionRung]?`, `nil` = learned — so it round-trips through the **same**
  `strategies.json` with **no** new file, **no** new `FileManager` seam row, and **no** exact-set
  pin amendment. Tolerant decode: an absent/unknown `override` field decodes to `nil` (the
  `CleanupConfigStore`/dictionary precedent).
- **Contract with `memory-order`:** its pure decisions are no-ops for a strategy with
  `overrideRungs != nil` (S2's absolute freeze). This aspect's test 2 pins that contract.
- **Wiring:** `AppBootstrap.showSettings` fills the new `SettingsBindings` closures from the real
  persistent store the ladder reads — `loadStrategies` (snapshot + display names), `saveOverride`,
  `clearOverride`, `resetLearned` — the `AppBootstrap.swift:844-847` dictionary pattern exactly.
- **Test floor:** `Scripts/test-with-floor.sh` floor (1210 today) is raised in the same commit as
  the new tests.

## Open questions

- **Q1 — Reset and overrides (decision made: overrides survive).** "Reset what Vocca learned"
  is scoped by its own wording to *learning*; an override is an explicit instruction, and a reset
  that silently undid a user's pin would be the same "taught a user the app is broken" failure
  `SettingsCopy.hotkeyNotRebindable` exists to avoid. Overrides survive; the two tests pin it. A
  future "reset everything" that also clears overrides would be a separate, plainly-worded
  button.
- **Q2 — Does the reset need a confirmation?** `PRODUCT_SPEC.md:275` names the button but not a
  confirm dialog. This aspect ships the button without one (the spec's mock has none); a
  confirmation is a view-server concern and can be added without a reducer change — flag for the
  smoke run.
- **Q3 — Display names.** Rows need a human name per bundleID; the wiring resolves via
  LaunchServices and the snapshot carries it, but the resolution order (unknown app → show the
  bundleID raw, or a placeholder) is a small product decision — default: show the bundleID when
  no name resolves, so a row is never nameless. Confirm in the smoke run.
- **Q4 — Manual-only override's fallback.** `.manual` pins `[.keystrokeSynthesis, .clipboardPaste]`
  — keystroke first (so health = `manual only`) with clipboard as the non-demotable workhorse
  fallback (R2's never-empty invariant). A stricter "never touch the clipboard" manual mode
  would contradict R2's premise; not offered unless the founder asks.
- **Q5 — The freeze's exact Core symbol.** Test 2 drives the `memory-order` decision entry
  point; the plan names the role, the implementer resolves the exact shipped symbol once
  `memory-order` lands (it precedes this aspect).
