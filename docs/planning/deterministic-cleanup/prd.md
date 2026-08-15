# PRD — Deterministic cleanup + custom dictionary (C5)

Slug: `deterministic-cleanup` · Phase: **P1** (`docs/ROADMAP.md:108-146`) · Type: `feat`.
Owner: aliz · Branch: `feat/deterministic-cleanup/aliz`.

> The P0 → P1 gate (`ROADMAP.md:100-104`) is a running calendar gate (founder 7-day daily-use
> log), not a code gate, and is **not** cleared by this unit. Per the roadmap's own schedule this
> is C5's week-5 slot; the gate verdict is recorded separately and nothing here implies P0 passed.

## Problem Statement

The P0 loop injects raw ASR text verbatim (`ROADMAP.md:72`: "Raw ASR text with no cleanup is
acceptable here" — that was P0's discipline, and P1 exists to end it). The gap between raw ASR
and text a person would have typed is mostly mechanical: fillers, missing punctuation,
capitalization, and proper nouns the model has never seen (`CAPABILITY_ROADMAP.md:116`). The
product position is "polished text types itself into any app" — the Wispr wedge — and unpolished
text is a demo-killer: "um so like we need to ship this period" is what the widget injects today.

The cheap part of the problem is solvable with rules — ~0 MB and budgeted at 10 ms
(`ARCHITECTURE.md:310`). Reaching for an LLM first would be the expensive way to solve the cheap
part of the problem (`CAPABILITY_ROADMAP.md:116`), and the LLM rungs are C6. C5 is the rung-1
default: deterministic, unit-testable, local by construction, and the `CleanupProvider` seam that
C6's Ollama/BYOK providers and the future hosted tier slot into
(`CAPABILITY_ROADMAP.md:126`; `ROADMAP.md:288`).

The binding constraint is not the rules. It is the invariant cleanup must obey: **cleanup can
never break dictation** (I5, `ARCHITECTURE.md:19`) — custody of the transcript is taken before
cleanup (`ARCHITECTURE.md:476`), and any timeout or failure degrades silently to the raw text
(`ARCHITECTURE.md:509`). A cleanup step that could lose or block text is a worse bug than the
fillers.

## Goals & Success Metrics

| Goal | Metric | Target | Proven by |
|------|--------|--------|-----------|
| Cleaned text beats raw | Blind pairwise preference, cleaned-over-raw on the held-out set | **≥80%** (provisional — see F2 note) | Eval harness; the number the P1 gate is judged on (`ROADMAP.md:137`) |
| Rules are effectively free | Rules-path latency, measured in harness | **p50 < 10 ms** | `ARCHITECTURE.md:310` (resolves the <5 ms drift at `ROADMAP.md:118`/`CAPABILITY_ROADMAP.md:116` — ARCHITECTURE is authoritative) |
| Cleanup never loses text | Timeouts/failures that still inject raw | **100%** | Hung-provider test + pipeline decision-table tests (`ROADMAP.md:140`) |
| Zero transcript loss | Existing 0% metric, now with cleanup in the loop | 0% | Full dictation-cycle tests incl. cleanup failure injection |
| Zero network in default config | Probe asserts zero `connect(2)` with cleanup wired | 0 calls | Zero-network probe (`ROADMAP.md:139`; C6 makes it a permanent release blocker, `CAPABILITY_ROADMAP.md:142`) |

**Provisional-numbers rule (house style, `latency-instrumentation/prd.md:35-38`):** the ≥80%
preference is a provisional target until the founder's real recordings (F2) exist; CI proves the
mechanism over stand-in pairs, never a product number. The F2 task is added to the smoke checklist
in this unit; until then stand-ins and the provisional figure hold.

## User Personas & Scenarios

**Persona (ICP):** a Mac user who lives in dictation all day and wants it private and local — the
person who will not send their audio to the cloud but still wants polished text typed anywhere.

**Scenario A — Slack message.** Dictates "um so like we need to ship this period". Rules remove
the fillers, capitalize, and render the terminal punctuation: *"We need to ship this."* lands in
the field. What was demo-killing is now the demo.

**Scenario B — jargon and names.** User's dictionary maps `kawa` → `Kawa` and `mcp server` →
`MCP server`. Every utterance about the project comes out spelled the way the user spells it —
the one thing no ASR engine can infer (`CAPABILITY_ROADMAP.md:116`).

**Scenario C — hostile field, per I5.** The user talks into a Secure Input field. Cleanup runs,
fails nothing, and the raw transcript still terminates in the failsafe panel exactly as it does
today (P0 behavior unchanged on every failure path).

## Requirements

### Must-have

- **M1 — `CleanupProvider` seam in VoccaCore** (`ARCHITECTURE.md:273-277`): `identity:
  ProviderIdentity`, `requiresNetwork: Bool` (false for rules — the hook the zero-network
  invariant keys on), `clean(_:context:) async throws -> String` with
  `CleanupContext { target: TargetContext; mode: SessionMode; dictionary: [ReplacementRule];
  budget: Duration }` (`ARCHITECTURE.md:220-225`). The throwing shape is a deliberate divergence
  from the non-throwing `TextInjector` precedent — documented at `ARCHITECTURE.md:273` — because
  timeout/failure is a first-class outcome the caller routes to raw.
- **M2 — `RulesCleanup` in VoccaText**, a pure function over `(String, [ReplacementRule]) ->
  String` (`ARCHITECTURE.md:511`): filler removal (**frequency-tuned, not blanket** — "like" as a
  verb survives; only discourse-marker uses go), sentence segmentation and terminal punctuation,
  capitalization, spoken-punctuation commands ("new line", "period", "comma", "question mark",
  "exclamation point"), and bounded number/unit normalization (twelve → 12; common units; **not**
  a full ITN system). Then user-dictionary rules in declared order. **Token protection:** no
  punctuation or capitalization changes inside tokens containing `/ . - _ @` (URLs, paths, code
  identifiers, email addresses) — the rules engine's own "cannot corrupt text outside its match"
  guarantee, tested as its own table class.
- **M3 — User dictionary**: ordered `ReplacementRule`s with case-sensitivity and word-boundary
  control, stored as hand-editable plain JSON in Application Support (`ARCHITECTURE.md:513`,
  `CAPABILITY_ROADMAP.md:120`). JSON is the first-class edit surface (settings UI is deferred —
  CLAUDE.md; matches the settings-as-JSON stance `PRODUCT_SPEC.md:304`). Invalid entries are
  skipped with a loud local log, never fatal, never corrupting the file on save.
- **M4 — Pipeline wiring with the timeout policy**: cleanup runs inside
  `DictationPipeline.transcribeAndInject` between the empty-text guard
  (`Sources/VoccaCore/DictationPipeline.swift:238`) and the injector call (`:240`); budget
  enforced by the caller via `Task` cancellation, never trusted to the provider
  (`ARCHITECTURE.md:509`); timeout/failure ⇒ raw proceeds silently (`I5`, `ARCHITECTURE.md:19`).
  **Esc interaction:** a cleanup `await` must re-check `Task.isCancelled` before injecting (the
  post-transcribe guard `:228-231` — a cancelled transcription must never inject, and a cleanup
  timeout must not fire after Esc cancelled the session). **Never-empty rule:** a clean result
  that is empty or whitespace-only falls back to the raw text — cleanup must never inject an
  empty string (the pipeline's empty-text guard at `:238` runs before cleanup, so this is the
  cleanup step's own guard). **Held text is cleaned text:** on the failsafe path the
  `HeldTranscript` carries the cleaned text — that is the transcript the user wanted typed and
  will copy (P0's no-transcript-lost invariant applies to the cleaned result). **Degrade is
  counted:** every timeout/failure degrade to raw is recorded in the local latency/metrics
  record (`ARCHITECTURE.md:509` "counted in local metrics"), so a silently degrading cleanup is
  visible in the ledger, never silent forever.
- **M5 — Cleanup span recorded**: `LatencySpan.cleanup` flips from `notPresent`
  (`LatencySpan.swift:27-29, 69-71`) to a recorded span measured with the injected clock
  (mirror `recordASRSpan`, `DictationPipeline.swift:267-272`); the report/describe path needs no
  new code (`LatencyLedger.describe` already renders recorded spans).
- **M6 — Default-on composition**: a `ShippingCleanup` factory in VoccaText (the
  `ShippingLadder`/`ShippingPasteboard` precedent) wired as the default cleanup path in the
  composition root; `VoccaBootstrap` gains the `VoccaText` dependency (Package.swift:118-129).
  **Confirmed with founder: on by default** — the P0 gate judges loss and reliability, not
  verbatim output; smoke-checklist "verbatim" wording gets a cleaned-vs-raw qualifier in this unit.
- **M7 — Zero-network probe covers the cleanup code**: the `VoccaTextPlaceholder.self` witness
  (`VoccaNetworkProbe.swift:276`) becomes a real type minted by a drive call; the probe's
  dictation cycle wires the provider and asserts zero `connect(2)` with cleanup running; the
  `ZeroNetworkTests.swift:561-567` "latency does not contain cleanup" assertion flips to expect
  the recorded span. The probe's `"1 2 3"` input passes through rules unchanged (identity on that
  input) so the cycle report survives.
- **M8 — Test floor raised in the unit that adds tests**: the floor currently lags the suite
  (`Scripts/test-with-floor.sh:908` pins 836; the suite runs 876 — the latency-instrumentation
  merge shipped 40 tests without raising it; that discrepancy is a review finding in this unit
  too). C5 raises the floor with its tests.

### Should-have

- **S1 — Module move**: VoccaText goes from `leafModules` to `adapterModules`
  (`ModuleBoundaryTests.swift:72-74 → 99-101`) with `dependencies: ["VoccaCore"]` in
  Package.swift — the deliberate, reviewed edit that file demands (its own discipline at :76-98).
- **S2 — FileManager seam row**: the dictionary store is a second `FileManager`-naming file; the
  per-seam one-file lint (`InjectionSeamBoundaryTests` FileManager row, :910-912) gains the
  `VoccaText/Dictionary/*` store file beside `Journal/FileSystemJournalStore.swift` — one file per
  seam family, never two unnamed.
- **S3 — Eval harness**: held-out raw→clean pairs scored by a blind pairwise-preference
  comparator (the WER-scorer precedent, `Tests/HarnessTests/WERTests.swift`); TTS stand-in pairs
  run in CI; env-gated real scoring on the founder's machine once F2 exists (the
  `VOCCA_MODEL_DIR` skip pattern, `ParakeetEngineWERTests.swift:52-58`). F2 recording task added
  to the smoke checklist.
- **S4 — SMOKE_CHECKLIST edits**: the verbatim assertions (steps 62-68; matrix rows) gain a
  cleaned-vs-raw qualifier; benchmark step 69's "cleanup is never recorded, C5 unbuilt"
  (`SMOKE_CHECKLIST.md:1189-1191`) flips to the recorded-span expectation; new steps for the
  dictionary and for cleanup-failure degrades, in the 62-68 pattern.

### Nice-to-have

- **N1 — Cleanup identity on the record**: `SessionRecord`/ledger rows carry which provider
  cleaned the text (the attribution discipline ASR already has — I1's sibling). Only if it falls
  out of M5 cheaply; not otherwise.
- **N2 — Spoken "new line" and "period" variants**: handle ASR emitting literal ".", "?", or
  "newline" tokens as well as the spelled words (whisper emits both).

## Technical Considerations

- **Layer:** AI cleanup — sits between ASR and injection in the capture → ASR → cleanup →
  injection → widget pipeline. Phase P1. Local-only OSS core; the seam is the second hosted-tier
  slot (`CAPABILITY_ROADMAP.md:126`) — adding providers later (C6) is a seam-completion, never a
  local-core change (guardrail 5, `CAPABILITY_ROADMAP.md:327`).
- **Latency budget:** cleanup is budgeted **10 ms** (`ARCHITECTURE.md:310` — "cleanup gets 10 ms
  and not 200"); the budget is enforced by the caller with `Task` cancellation
  (`ARCHITECTURE.md:509`). The rules function itself is measured in the harness and must land
  well under the budget so the p95 envelope is untouched.
- **Module boundaries:** `VoccaCore` imports nothing (`CoreBoundaryTests` empty allow-list) — the
  rules function is stdlib-pure, but dictionary persistence (JSON + FileManager) cannot live in
  Core; VoccaText hosts both the pure rules and the persistence adapter. Seam protocol lives in
  VoccaCore (Core owns every seam).
- **The zero-network invariant:** rules are local by construction; the probe keeps asserting zero
  `connect(2)` with the provider wired (M7). Nothing in C5 touches `requiresNetwork = true`
  (that is C6's egress-badge work, `PRODUCT_SPEC.md:250-264`).
- **Test-first:** acceptance below are the failing tests written before the implementation
  (`CAPABILITY_ROADMAP.md:13`). Entry point `Scripts/test-with-floor.sh`; suite must stay green
  after every task commit.
- **Dependencies:** C2 (ASREngine) — met and merged. No new module: VoccaText exists (one
  placeholder file). Independent of C6/C8.

## Data Model

- `CleanupContext` (Core): `target: TargetContext`, `mode: SessionMode`, `dictionary:
  [ReplacementRule]`, `budget: Duration`.
- `ReplacementRule` (Core vocabulary): source phrase/word, replacement, `caseSensitive: Bool`,
  `wordBoundary: Bool`; ordered (declared order is application order —
  `CAPABILITY_ROADMAP.md:120`).
- `dictionary.json` (Application Support, hand-editable, version-controllable): JSON array of
  `ReplacementRule`s; load tolerates invalid entries (skip + loud log); save is atomic
  temp+rename (the journal-store precedent).
- No new latency vocabulary: `SpanName.cleanup` exists; only its `Presence` flips.

## Risks & Open Questions

- **R11 privacy erosion (named, `ROADMAP.md:310`):** rules are local; the probe assertion (M7)
  is the guard. No BYOK code in C5.
- **Filler rules corrupt meaning** ("I like pizza" losing "like"): mitigated by frequency-tuned
  rules — discourse-marker contexts only — with table tests for the ambiguous cases
  (`CAPABILITY_ROADMAP.md:120` "frequency-tuned, not blanket").
- **ITN rabbit hole:** number/unit normalization is a bounded rule list by PRD decision; a full
  inverse-text-normalization system is out of scope and flagged as a future option if the
  pairwise scores show numbers are the main remaining gap.
- **Eval subjectivity:** blind pairwise preference with human-preferred targets is the roadmap's
  own design (`ROADMAP.md:132`); the comparator is deterministic and table-tested so the
  mechanism is not the subjectivity. **Honest caveat:** a held-out set of the founder's own
  recordings, preferred by the founder, is a weak proxy for real users — the roadmap itself
  calibrates P0 against incumbents side-by-side and gates P2 on external confirmation
  (`ROADMAP.md:104, 180`); the ≥80% figure is the P1-gate instrument, and the P2 gate absorbs
  the external bias.
- **F2 ownership (open):** the held-out set needs the founder's real recordings; nothing today
  links F2 to C5 (`local-asr/prd.md:369-372` flags F2 as ownerless). This unit adds the F2 smoke
  task; until recorded, ≥80% stays provisional and CI runs stand-ins.
- **Latency number drift resolved:** 10 ms (ARCHITECTURE), not <5 ms (ROADMAP ladder wording).
- **Open:** none blocking. Esc-during-cleanup semantics are pinned by the M4 cancellation
  re-check; provider attribution (N1) is optional.

## Out of Scope

- **C6** — Ollama and BYOK providers, the egress badge, per-mode provider selection
  (`CAPABILITY_ROADMAP.md:132-146`); this unit ships one implementation (I4 completion is C6's
  job, the C2→C3 "proven rather than asserted" precedent).
- **Settings UI** — no tabs, no editor windows; JSON is the edit surface. The Cleanup tab
  (`PRODUCT_SPEC.md:232-240`) ships with the deferred settings surface.
- **Full inverse text normalization** — bounded rules only.
- **Cleanup for the CONVERSING mode** — mode exists in `CleanupContext`; per-mode selection is
  C6/C11.
- **Streaming, VAD, TTS, agent work** — P1 scope discipline: "Cleanup only" (`ROADMAP.md:112`).
- **Anything network** — the default path stays zero-call; nothing egresses.

## Proposed aspects (for tech-plan; each independently buildable and test-first)

| Aspect | Boundary | Requirements |
|--------|----------|--------------|
| `cleanup-seam` | `CleanupProvider` protocol, `CleanupContext`, `ReplacementRule`, `ProviderIdentity` usage, `requiresNetwork` semantics in VoccaCore | M1 |
| `rules-engine` | Pure `RulesCleanup` function in VoccaText: fillers, segmentation/punctuation, capitalization, spoken punctuation, bounded number/unit | M2, N2 |
| `user-dictionary` | `ReplacementRule` semantics + `dictionary.json` store (load/save/order/case/word-boundary/invalid-entry), FileManager seam row, module move | M3, S1, S2 |
| `pipeline-wiring` | DictationPipeline cleanup parameter, caller-enforced budget, Esc re-check, cleanup span recording + report flips, ShippingCleanup + root wiring + default-on, probe coverage (witness, cycle drive, 561-567 flip), floor raise, smoke-checklist edits | M4-M8, S4 |
| `eval-harness` | Held-out raw→clean pairs, blind pairwise-preference comparator, CI stand-ins + env-gated real scoring, F2 smoke task | S3 |

Rough shape: `cleanup-seam` → `rules-engine` + `user-dictionary` (parallel after the seam) →
`pipeline-wiring` → `eval-harness`. The seam is the only predecessor gate for the engine and
dictionary; wiring depends on both plus the seam; the harness is last and depends on the engine.
