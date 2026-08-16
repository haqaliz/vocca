# Understanding — deterministic-cleanup (C5)

> Phase 2 output of `vbf feat deterministic-cleanup`. Sources: code map (agent, file:line cited),
> doc map (agent, file:line cited), `docs/planning/_card/issue.md`.

## What the work really is

C5 ("Deterministic cleanup + custom dictionary", `docs/technical/CAPABILITY_ROADMAP.md:114-128`,
phase P1) is four things, in build order:

1. **The `CleanupProvider` seam in VoccaCore** — per ARCHITECTURE.md:273-277: `identity`,
   `requiresNetwork` (false for rules; the hook the zero-network invariant and the C6 egress badge
   key on), and `clean(_:context:) async throws -> String` with `CleanupContext { target, mode,
   dictionary: [ReplacementRule], budget: Duration }` (ARCHITECTURE.md:220-225).
2. **The `RulesCleanup` implementation in VoccaText** — a pure function over
   `(String, [ReplacementRule]) -> String` (ARCHITECTURE.md:511): filler removal (frequency-tuned,
   not blanket), sentence segmentation + terminal punctuation, capitalization, spoken-punctuation
   commands ("new line", "period"), number/unit normalization, then user-dictionary rules in
   declared order. Plus the user dictionary as hand-editable JSON in Application Support
   (ARCHITECTURE.md:513).
3. **Pipeline wiring with the timeout policy** — cleanup runs between ASR and injection inside
   `DictationPipeline.transcribeAndInject` (insertion point between `Sources/VoccaCore/DictationPipeline.swift:238`
   and `:240`); budget is enforced by the caller via `Task` cancellation, never trusted to the
   provider (ARCHITECTURE.md:509); any failure/timeout degrades silently to the raw transcript —
   I5 and custody-before-cleanup (ARCHITECTURE.md:476) make cleanup structurally incapable of
   losing text.
4. **The eval harness** — held-out raw→clean pairs scored by blind pairwise preference, the number
   the P1 gate is judged on (ROADMAP.md:137, CAPABILITY_ROADMAP.md:124).

## What the code says (wins over prose)

- **The insertion point is real and small**: `transcribeAndInject` (DictationPipeline.swift:190-262);
  cleanup consumes the `Transcript` at line 238 and yields the string handed to `injector.inject`
  at line 240. **Esc-cancellation interacts**: the post-transcribe guard at lines 228-231
  ("a cancelled transcription must never inject") means a cleanup `await` must re-check
  `Task.isCancelled` before injecting — a timeout yielding raw must not fire after Esc cancelled
  the session, or the never-inject-on-cancel invariant breaks (AppBootstrap.swift:1029-1041).
- **The latency vocabulary already anticipates C5**: `LatencySpan.cleanup` exists as a `notPresent`
  state (`Sources/VoccaCore/LatencySpan.swift:27-29, 69-71`); the pipeline records a real span
  (`recordCleanupSpan` beside `recordASRSpan`, DictationPipeline.swift:267-272); `describe()` needs
  no change. `SessionOutcomeClass` and `PipelineSurface` are closed sets and survive unchanged —
  raw injection on timeout is still `delivered`/`failsafeHeld`.
- **VoccaText is a leaf module with a placeholder** (`Sources/VoccaText/Placeholder.swift`).
  Making it implement a seam is a deliberate module move: `leafModules` → `adapterModules` in
  `Tests/HarnessTests/ModuleBoundaryTests.swift:72-74 → 99-101` + a `VoccaCore` dependency in
  Package.swift. The rules engine itself is stdlib-pure (vocabulary-only core, CoreBoundaryTests
  empty import list) — but dictionary persistence (JSON + FileManager) cannot live in VoccaCore.
- **The zero-network invariant forces the probe to drive VoccaText**: the coverage guard
  (ZeroNetworkTests.swift:1032-1059) fails on any module the probe never runs; the placeholder
  witness `VoccaTextPlaceholder.self` (VoccaNetworkProbe.swift:276) becomes a real type minted by
  a drive call, and `DictationCycleDrive.buildDictationCycle()` (line 388-390) wires the provider.
  The probe's `"1 2 3"` input must pass through cleanup unchanged (identity on that input) or the
  cycle report breaks. **ZeroNetworkTests.swift:561-567 asserts the latency payload does NOT
  contain "cleanup" — that assertion flips the day C5 records a span.**
- **VoccaBootstrap does not depend on VoccaText** (Package.swift:118-129) — a `ShippingCleanup`
  factory in VoccaText (following `ShippingLadder`/`ShippingPasteboard` precedent) requires adding
  the dependency to the composition root.
- **Test floor lags**: `Scripts/test-with-floor.sh:908` pins 836; the suite actually runs 876
  (latency-instrumentation shipped 40 tests without raising it — a review finding). C5 raises it.
- **SMOKE_CHECKLIST verbatim assumptions**: steps 62-68 and the matrix assert injected text is
  "verbatim" (e.g. :1011, :356); benchmark step 71 says "cleanup is never recorded, C5 unbuilt"
  (:1189-1191). Both need C5-qualified edits.

## What the docs add (the requirements)

- Rung-1 scope (ROADMAP.md:122, CAPABILITY_ROADMAP.md:120): fillers (frequency-tuned, not blanket),
  segmentation + terminal punctuation, capitalization, spoken-punctuation commands, number/unit
  normalization, user dictionary (ordered, case-sensitive, word-boundary-controlled, JSON,
  hand-editable/version-controllable).
- Metrics (ROADMAP.md:137-140): blind pairwise preference ≥80% cleaned-over-raw (rung 1);
  rules-path latency **<10 ms** (ARCHITECTURE.md:310 budget — the ROADMAP ladder's "<5 ms" at
  :118/:116 is a drift to resolve; ARCHITECTURE is authoritative, 10 ms); zero-network default
  test (a release blocker forever); 100% of timeouts/failures still inject raw.
- Eval harness: ROADMAP.md:132 says "run in CI" but repo discipline (C2/C3 precedent) is TTS
  stand-ins in CI + env-gated real scoring on the founder's machine; the held-out set is the
  **F2 founder recordings** — nothing in the docs links F2 to C5's harness; the PRD must claim it.
- Seam-count tension: I4 / guardrail 7 demand two implementations, but C5 ships only RulesCleanup;
  the second (Ollama) is C6 — the PRD states I4 completion is C6's job, matching the C2→C3
  "proven rather than asserted" precedent.
- PRODUCT_SPEC: Cleanup tab (:232-240), egress badge for `requiresNetwork` (:250-264, C6),
  settings-as-JSON/no-account (:304); silent on timeout UX, per-mode selection, spoken punctuation,
  dictionary-editing mechanics — C5 has freedom, bounded by "no nested panels" (:219).

## Open questions for the interview

1. **Default-on at merge?** ROADMAP.md:48 says rules are the cleanup default; but the P0 gate
   (7-day daily-use log, ROADMAP.md:100-104) is still running, and cleanup changing injected text
   mid-gate muddies the gate's observations. Build default-on (per roadmap) or default-off until
   the gate verdict? (PRD position to confirm with founder.)
2. **Dictionary edit surface**: settings UI doesn't exist yet (deferred per CLAUDE.md). C5 should
   ship JSON as the first-class edit surface (matches PRODUCT_SPEC no-account/settings-as-JSON);
   the Cleanup-tab UI comes with the settings surface later. Confirm scope.
3. **Eval harness posture**: CI via TTS stand-ins + env-gated real scoring against F2 recordings,
   provisional ≥80% until the founder's real recordings land. Confirm the founder will record F2
   (it is the same corpus the WER tolerances already await).
4. **Latency number**: settle on 10 ms (ARCHITECTURE.md:310) and note the <5 ms drift.
5. **Bounded ITN scope**: number/unit normalization stays a bounded rule set (twelve → 12, known
   units), not a full inverse-text-normalization system — confirm.

## Contradictions flagged (not papered over)

- `<5 ms` (ROADMAP.md:118, CAPABILITY_ROADMAP.md:116) vs `<10 ms` (ROADMAP.md:138, ARCHITECTURE.md:310,503).
- "Two implementations at ship" (guardrail 7) vs C5's single implementation (C6 completes it).
- Eval "run in CI" (ROADMAP.md:132) vs repo WER discipline (stand-ins + env-gated real runs).
- SMOKE_CHECKLIST verbatim/never-recorded-cleanup assertions vs C5 wiring.

## Placement

Layer: AI cleanup (`CleanupProvider`). Phase: P1. Local-only, macOS-only, dictation-first — no
guardrail violations; the zero-network default is preserved (rules are local by construction) and
the probe keeps asserting it.
