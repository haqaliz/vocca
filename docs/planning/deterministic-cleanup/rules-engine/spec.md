# Spec — rules-engine

Aspect of `deterministic-cleanup` (C5, P1) · `docs/planning/deterministic-cleanup/prd.md` (requirements **M2** + **N2**)
Depends on `cleanup-seam` (must land first: `CleanupContext`, `ReplacementRule`, `CleanupProvider` in
VoccaCore — verified absent from `Sources/` today, doc-only in `prd.md:71, 177-181` and `ARCHITECTURE.md:220-225`).
The first VoccaText aspect to ship — it performs the module move (see Dependencies).

## Problem slice

Raw ASR text is injected verbatim (`ROADMAP.md:72`): "um so like we need to ship this period" is what
lands in the field today. `ARCHITECTURE.md:511` names the fix: `RulesCleanup` is a pure function over
`(String, [ReplacementRule]) -> String` — filler removal, sentence segmentation and terminal
punctuation, capitalization, spoken-punctuation commands, number/unit normalization, then user
dictionary rules in declared order; "Pure means table-driven tests". The binding constraint is not
the rules but the invariant they must not break: cleanup can never lose or corrupt text (I5,
`ARCHITECTURE.md:19`) — a rule that rewrites text outside its own match is a worse bug than the
fillers. Budget: 10 ms (`ARCHITECTURE.md:310`), enforced by the caller, not here.

## In scope

1. **The module move (task 1 of this aspect's plan).** VoccaText goes from `leafModules`
   (`ModuleBoundaryTests.swift:72-74`) to `adapterModules` (`:99-101`) and `Package.swift:90-94`'s
   VoccaText target gains `dependencies: ["VoccaCore"]` — the deliberate, reviewed edit the file
   demands (`:76-98`: "moving a module here is how a leaf stops being bound by rule 1, so it must be
   visible in a diff"). Rationale recorded in that doc comment in the `VoccaASR`/`VoccaInject`/
   `VoccaAudio` pattern: the module implements vocabulary a seam owns.
2. **`RulesCleanup` in `Sources/VoccaText/Rules/`** (M2, `prd.md:75-83`): a pure function
   `(String, [ReplacementRule]) -> String` applying six rule classes in fixed order:
   (1) filler removal (**frequency-tuned, not blanket**), (2) spoken-punctuation commands
   resolved to their symbols + N2 literal tokens, (3) sentence segmentation + terminal punctuation,
   (4) capitalization, (5) bounded number/unit normalization, (6) user-dictionary rules in declared
   order. Execution order deliberately reorders ARCHITECTURE's listing: the spoken-command class
   must produce its symbols *before* segmentation so the boundary exists; the *observable order of
   effects* matches `ARCHITECTURE.md:511`.
3. **Token protection** (M2): no punctuation or capitalization changes inside tokens containing
   `/ . - _ @` (URLs, paths, code identifiers, email addresses) — the engine's own "cannot corrupt
   text outside its match" guarantee, tested as its own table class.
4. **N2 — literal-token handling** (`prd.md:149-150`): ASR emitting literal `"."`, `"?"`, or
   `"newline"` tokens as well as the spelled words (whisper emits both).
5. **`Tests/HarnessTests/RulesCleanupTests.swift`** — the acceptance tables below, written first
   (failing) per `CAPABILITY_ROADMAP.md:13`, in the hand-written-row table shape of
   `InjectionLadderTests.swift:322` (`struct Row`) / `WERTests.swift` named-rule tests.
6. **Perf smoke** — a ~2,400-word input cleans under a generous named bound in CI (see Isolation);
   the honest <10 ms measurement belongs to `eval-harness`.

## Out of scope

- **Dictionary persistence** — JSON store, load/save, invalid-entry handling, `ReplacementRule`
  semantics (case-sensitivity, word-boundary) are the `user-dictionary` aspect (M3, S1, S2). This
  aspect only *applies* the `[ReplacementRule]` it receives, in order.
- **No LLM / Ollama / BYOK** (C6), **no settings UI**, **no full ITN** (bounded rules only,
  `prd.md:218`).
- **No pipeline wiring**: budget enforcement via `Task` cancellation, Esc re-check, never-empty
  fallback, held-text-is-cleaned-text, degrade counting, the `LatencySpan.cleanup` flip, the
  `ShippingCleanup` factory, probe changes — all `pipeline-wiring` (M4-M8, S4).
- **No proper-noun capitalization** — no entity knowledge; that is the user dictionary's job.
- **No heuristic sentence segmentation** without a punctuation signal (see Open questions 6).

## Isolation / honesty decisions

- **Pure function, deterministic, total.** `(String, [ReplacementRule]) -> String`, no state, no
  clock, no IO, no network, no randomness; `nonisolated`; returns a new `String` and never mutates
  its input. Determinism is explicit: no `Locale`-dependent formatting (`String(format:)`,
  `NumberFormatter`, `LocalizedStringKey`) — digit words map through explicit tables only, so
  output is byte-identical across machines and process invocations.
- **Stdlib-only imports.** VoccaText may import `VoccaCore` (and only it, per the adapter rule) —
  the module move is what permits that; no system frameworks enter this aspect. The rules engine
  uses `String`/`Substring` machinery only.
- **The latency-gloss decision (two honest halves, benchmark-gate precedent).** This aspect ships a
  coarse perf smoke in CI: a ~2,400-word input must clean under a generous named bound (~250 ms, a
  single constant — ~25× the 10 ms budget, flake-proof on a loaded runner, tight enough to trip on
  a pathological rewrite). The honest <10 ms p50/p95 numbers are the `eval-harness` aspect's
  job — CI here proves the function is *not pathologically slow*, never a product number.
- **CI executes the real thing** — the rare aspect with no TCC/Accessibility/microphone dependency:
  every acceptance row below runs the shipped function headlessly, now and forever.
- **Totality is a property, tested as one**: no input (emoji, RTL, newlines, lone long tokens)
  may crash the function; characters outside a rule's match pass through byte-identical.

## Acceptance criteria (tests written first)

All rows below are the table content of `Tests/HarnessTests/RulesCleanupTests.swift`, one table per
rule class plus combination tables; rows assert exact output strings, hand-written per the
`InjectionLadderTests.swift:322` precedent (never derived from the implementation).

- B1 **Fillers** (table `fillerRows`): `("um we should go", "we should go")`;
  `("uh i think it works", "i think it works")`; `("er we ship it", "we ship it")`;
  `("you know it was hard", "it was hard")`; `("hmm maybe", "maybe")`. **The "like" rows**:
  `("like we could ship it", "we could ship it")` (utterance-initial, followed by pronoun →
  discourse marker, removed); `("I like pizza", "I like pizza")` (verb — survives, exact match);
  `("it looks like rain", "it looks like rain")` (preposition — survives, exact match). Multiple
  fillers in one row: `("um you know like we are late", "we are late")`.
- B2 **Segmentation + terminal punctuation** (table `segmentationRows`): no signal → a single
  terminal period appended, **no boundary inserted**: `("we are late it is fine",
  "We are late it is fine.")`; already terminated → unchanged: `("We are late.",
  "We are late.")` (never doubled); signal-driven boundary insertion is covered by the B4/B9
  rows, because segmentation acts only where a signal exists (Open question 6).
- B3 **Capitalization** (table `capitalizationRows`): `("i think", "I think")`;
  `("i'm here", "I'm here")`; sentence-initial after a boundary: `("we are late. it is fine",
  "We are late. It is fine.")`; protected tokens not capitalized *inside* (B6 rows carry the
  interaction).
- B4 **Spoken punctuation** (table `spokenPunctuationRows`): `("we are done period",
  "We are done.")`; `("are you ready question mark", "Are you ready?")`;
  `("wow exclamation point", "Wow!")`; `("please pause comma we are live",
  "Please pause, we are live.")`; `("first line new line second line", "First line\nSecond line.")`;
  command mid-utterance creates a boundary: `("we are done period then we rest",
  "We are done. Then we rest.")`; the word-with-symbol-already-present row (N2 interplay, below).
- B5 **Number/unit normalization** (table `numberRows`, bounded cardinals + units only):
  `("twelve", "12")`; `("twenty five", "25")`; `("one hundred", "100")`;
  `("forty percent", "40 percent")` (unit word untouched — symbol rendering is Open question 3);
  `("twelve dollars", "12 dollars")`. **No decimal rows** until Open question 2 resolves. Digits
  already present are unchanged: `("build 42", "build 42")`.
- B6 **Token protection + cannot-corrupt class** (tables `protectionRows` + `noCorruptionRows`):
  `("email me at aliz@vocca.dev period", "Email me at aliz@vocca.dev.")`; `("the build is v2.4.1 it
  is stable", "The build is v2.4.1 it is stable.")` — the `.` inside the token is **not** a
  boundary, `it` stays lowercase; `("run deploy-vocca.sh now", "Run deploy-vocca.sh now.")`;
  `("checkout /Users/aliz/dev then test", "Checkout /Users/aliz/dev then test.")`; `("my_repo is
  fine", "My_repo is fine.")`. **Cannot-corrupt rows**: a rule's edit is confined to its match
  span — `("I like pizza um and twelve apples", "I like pizza and 12 apples")` (filler removal
  takes the filler plus its adjacent space, nothing else; no double spaces, no mangled neighbors);
  `("um kawa", "kawa")`.
- B7 **Dictionary rules in declared order** (table `dictionaryRows`): `("we should ship kawa this
  week", "We should ship Kawa this week")` with `[kawa → Kawa]`; built-ins run before the
  dictionary: `("um twelve kawa", "12 Kawa")` with `[kawa → Kawa]`; overlapping rules apply
  first-match-in-declared-order: `[("hello world", "hi"), ("world", "earth")]` on `("hello world
  today", "Hi today")` — the first rule consumes the phrase before the second sees it.
- B8 **Combination rows** (table `combinationRows`): the PRD scenario (`prd.md:52-54`):
  `("um so like we need to ship this period", "We need to ship this.")` — pins the demo; with
  dictionary: `("we should ship kawa this week period", "We should ship Kawa this week.")`;
  `("i think we are ready question mark we ship now", "I think we are ready? We ship now.")`.
- B9 **N2 literal tokens** (table `literalTokenRows`): `("we are done. then we rest",
  "We are done. Then we rest.")` (literal `.` emitted, next sentence capitalized);
  `("press return newline then continue", "Press return\nThen continue.")` (literal `newline`
  word → newline); `("are you ready?", "Are you ready?")` (literal `?` terminal, unchanged shape);
  `("we are done . then we rest", "We are done. Then we rest.")` (space-separated literal `.`);
  `("we are done period.", "We are done.")` — the ASR emitted both the word and the symbol:
  the symbol wins, the word is dropped (provisional; Open question 4).
- B10 **Determinism** (table `determinismRows`): for a representative input set, N repeated calls
  and two independently constructed call sequences yield byte-identical output — the pure-function
  claim asserted, not assumed.
- B11 **Empty / hostile / identity** (table `boundaryRows`): `("", "")`; `("   ", "   ")` (the
  never-empty guard is the pipeline's job, M4 — this function is identity on whitespace);
  already-clean input is identity: `("This is already clean.", "This is already clean.")`; hostile
  inputs (emoji, RTL text, a 5,000-char unbroken token, embedded newlines) return a `String`,
  no crash, all non-matching characters byte-preserved.
- B12 **Perf smoke**: a generated ~2,400-word utterance (mixed fillers, numbers, punctuation
  commands — see Open question 7 for the arithmetic) cleans under the named ~250 ms bound,
  asserted in CI, deterministic enough to gate.

## Dependencies / sequencing

- **`cleanup-seam` must land first**: `CleanupContext`, `ReplacementRule`, `CleanupProvider` are
  Core types this aspect consumes; they do not exist in `Sources/` today (verified: only doc
  references in `prd.md`/`ARCHITECTURE.md`). `ReplacementRule` carries `caseSensitive`/
  `wordBoundary`; their semantics ship with `user-dictionary` — this aspect reads them, does not
  define them.
- **Task 1 of this aspect — the module move.** VoccaText is currently a leaf importing nothing
  (`Package.swift:90-94`, `dependencies: []`). The first VoccaText aspect to ship must perform the
  move: `Package.swift` gains `dependencies: ["VoccaCore"]` on the VoccaText target, and
  `ModuleBoundaryTests` moves `"VoccaText"` from `leafModules` (`:72-74`) to `adapterModules`
  (`:99-101`) with the rationale paragraph the file's own discipline demands (`:76-98`).
  **This aspect is that first mover — the module move is task #1 of its plan, and the
  `user-dictionary` aspect depends on it already being done.** The move lands with this aspect's
  first commit, carrying no behavior, so the adapter-rule diff is visible in isolation.
- **`Sources/VoccaText/Placeholder.swift` stays.** `VoccaTextPlaceholder` is referenced by the
  probe witness list (`VoccaNetworkProbe.swift:276`); replacing it is `pipeline-wiring`'s M7.
- **Test floor**: `Scripts/test-with-floor.sh:908` pins 836 while the suite runs 876 (the PRD M8
  review finding, `prd.md:120-123`). The floor pin must be raised no later than this aspect's merge
  (by `cleanup-seam`'s tests if they land first, else here); entry point
  `Scripts/test-with-floor.sh`, suite green after every commit.
- Rough plan: task 1 module move → task 2 RulesCleanup skeleton + B11/B10 rows → task 3 fillers
  (B1) → task 4 spoken punctuation + N2 (B4, B9) → task 5 segmentation/terminal + capitalization
  (B2, B3) → task 6 numbers (B5) → task 7 protection + no-corruption (B6) → task 8 dictionary
  application (B7) → task 9 combination + smoke (B8, B12). Independent of `audio-capture`, C6, C8.

## Open questions / risks

1. **Filler list + thresholds.** Exact membership is unpinned. "so" is the hard one: the PRD
   scenario (`prd.md:52`) removes it, but "so that we can", "I think so", "and so on" must survive —
   provisional: sentence-initial discourse "so" only, rows pinned by B8, and a verb/preposition
   survival row required before "so" ships. "like" removal needs a small flank heuristic
   (preceded by sentence start/punctuation and followed by a pronoun → discourse) rather than a
   static list — provisional rows in B1; the heuristic's exact flank set is the open item.
2. **"twelve point five".** Decimal handling is out of B5 until decided: join as "12.5", or leave
   words, or treat "point" as out of the bounded list. Risk: silently drifting into ITN territory.
3. **Unit rendering.** "twelve dollars" → "12 dollars" (provisional) vs "$12"; "forty percent" →
   "40 percent" vs "40%". Symbol insertion is a formatting policy; deciding it wrongly touches
   every number row.
4. **Word + symbol both present (N2).** `"period."` → symbol wins, word dropped (provisional, B9).
   Risk: ASR emitting "period" *before* the symbol ("period.") vs the reverse (". period") — both
   must converge on one period; the reversed row is not yet pinned.
5. **"new line" / "period" as genuine words.** "a new line in the document", "the period of the
   sine wave" — false positives turn real text into commands. Provisional: the command requires a
   word-boundary context (e.g. "period" followed by utterance end or another command, preceded by
   a sentence-final context); rows to be pinned when the context rule is decided — this is the
   same false-positive family as the filler "like" and the token-protection class.
6. **Segmentation without a signal.** No heuristic sentence-splitting without punctuation —
   otherwise filler removal creates false boundaries. Provisional decision: boundaries exist only
   at spoken commands, literal tokens, and end of input; ML-style segmentation is out of scope
   and flagged as a future option if pairwise scores show it as the main gap.
7. **The smoke's word count.** ~2,400 words at "typical dictation speed" over 120 s implies
   ~1200 wpm, which is not speech. At ~150 wpm a 120 s ceiling utterance is ~300 words, so 2,400
   words is ~8× a maximum-length utterance — deliberately generous headroom, kept as the smoke
   input (the honesty framing is corrected here, not the number).
8. **Protected-token first letter.** "v2.4.1" at sentence start: capitalizing the first character
   ("V2.4.1") is probably fine; "aliz@vocca.dev" → "Aliz@vocca.dev" is wrong (email local-parts).
   Provisional split: first-character capitalization allowed for `/`- and `-`-tokens, forbidden
   for `@`-tokens; pinned when B6 rows finalize.
