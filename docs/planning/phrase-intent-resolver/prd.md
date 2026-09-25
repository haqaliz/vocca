# PRD: PhraseIntentResolver

> C13 slice 8, the intent layer's S1 (`intent-layer/prd.md:188`).
> Source: `docs/planning/_card/issue.md` (inline brief) + `_card/understanding.md`.
> Decisions confirmed with the founder 2026-09-25 ("go" on the recommendations):
> **the composed default becomes `PhraseIntentResolver` over the user's phrase file** (an
> absent file resolves nothing, the same behaviour as Null); **shell targets are refused at load**
> (the arm-surface-only decision stands, `intentShellRows=0` stays asserted); **rows carry
> no arguments**; **exact normalized match only, never `.ask`**; **file-only editing, no
> Settings editor.**

> **Review gate, 2026-09-25 ("gtg").** The founder re-confirmed the default flip after the
> critique restated it plainly: this is the **first shipped configuration that can voice-act**,
> after a two-step opt-in. Calls made by the agent under the delegated-decision posture,
> labelled as such:
> - **(agent call) No Actions-tab change.** The critique asked whether users can find the
>   ids. `ActionsTabPage.swift:240` already renders `providerID / toolID` on every tool row.
> - **(agent call) Enablement of the audit tools stays a documented hand-edit.** The gate
>   review found (F-A below) that the audit tools have **no Actions-tab row at all**. Tool rows
>   come only from MCP discovery (unwired) and the shell section (`ShellWiring.swift:222`).
>   Adding an audit section is a follow-on UI slice, not this unit.
>
> ### Findings at the gate
> - **F-A: the audit tools are not enable-able from the surface.** In the shipped app, the only
>   tools the voice leg can reach are `dev.vocca.audit/*` (MCP is unwired; shell is refused
>   here). Enabling them means hand-editing `action-config.json`. The SMOKE rows document that
>   edit. It is recorded, not fixed.
> - **F-B: SMOKE 148's gesture is not performable as written.** "Enable `audit.clear` in the
>   Actions tab" names a row that does not exist. The record aspect corrects the wording to the
>   hand-edit, and the correction is recorded as a correction.
> - **F-C:** `KeywordIntentResolver.jsonEscaped` emits invalid JSON escapes for control
>   characters (N1).

## Problem Statement

The intent seam (`VoccaCore/Intent/IntentResolver.swift`) ships with one real classifier,
`KeywordIntentResolver`, plus the composed default `NullIntentResolver`. The intent-layer
record calls this the **D3-shaped guardrail-7 caveat** (`CAPABILITY_ROADMAP.md` guardrail 7:
"one implementation and a promise is not a seam"). A default that resolves nothing is not a
second classifier.

The second problem is **tuning, and reach**. The keyword seeds are a Core constant pinned
verbatim by `IntentSeamBoundaryTests`, so correcting a wrong seed is a reviewed code edit.
And the shipped app composes neither classifier: its default is Null, so **no shipped
configuration can voice-act at all**. A user who wants "wipe the log" to mean `audit.clear`
cannot say so. The intent-layer PRD named S1 as
"the day-one tuning path for wrong seeds" and deferred it. The P4 → P5 gate needs ≥3 MCP
tool integrations working **from voice** (`ROADMAP.md`, 🚦 P4 → P5), and resolution is
currently the weakest part of that path.

Evidence it's real: the deferral is recorded three times (`intent-layer/prd.md:188,244`,
`CAPABILITY_ROADMAP.md` C13 shell-provider amendment, `docs/STATUS.md` intent-layer and
shell-provider honesty blocks). No user has asked for it. This is roadmap push, not demand
pull, and the record should say so.

## Goals & Success Metrics

- **Goal 1: the seam has two real classifiers.** `PhraseIntentResolver` conforms to
  `IntentResolver` and passes the same contract suite as `KeywordIntentResolver`.
  - *Metric:* `IntentResolverContractTests` runs its shared rows over both real resolvers,
    and the D3-shaped caveat is retired in the record, stated as retired rather than implied.
- **Goal 2: users can tune voice actions without a code edit.** A hand-edited
  `intent-phrases.json` changes what an utterance resolves to on the next turn, with no relaunch.
  - *Metric:* a composed test writes the file between two turns and the second turn resolves
    differently. SMOKE rows record a founder run, never gated.
- **Goal 3: the safety spine is untouched and still holds.** A phrase hit is a
  `.toolCall` like any other: it goes through `ActionGate` with `approval: .withheld`, an
  outward-facing tool always confirms, and a disabled tool is never reached.
  - *Metric:* the §8 floor pinned over a phrase-resolved invocation (`EscapeValveTests`
    extended). The disabled/unknown-tool rows assert that the provider's call log stays empty.
- **Goal 4: the default configuration's promises are unchanged.** Zero network, no child
  process, and with no phrase file the voice leg resolves nothing.
  - *Metric:* `PROBE-INTENT-DEFAULT` reads `resolver=PhraseIntentResolver … intentResolved=0
    spawnsSubprocess=false intentShellRows=0` inside the zero-network interposer. The dictation
    digests stay unchanged. G5 is re-anchored deliberately, once.

No resolution-accuracy number is claimed. None is computable in CI (the ASR-WER precedent).

## User Personas & Scenarios

The Vocca ICP: a Mac user who dictates all day, keeps it local, and has started using
the converse mode to act.

- **"I can't voice-act at all."** Today the shipped app composes `NullIntentResolver`, so
  "wipe the log" in converse mode just echoes, even with `audit.clear` enabled. The user
  adds `{"phrase": "wipe the log", "providerID": "dev.vocca.audit", "toolID": "audit.clear"}`
  to `intent-phrases.json`. On the next turn the card appears with the gate's sentence, and
  nothing runs until they confirm.
- **"I said it slightly differently."** "Wipe the log, please" doesn't equal the phrase. It
  resolves `.none` and echoes, and the user adds a second row. Brittleness fails to *nothing*,
  never to a wrong tool.
- **"I tried to voice a shell command."** The user writes a row targeting
  `dev.vocca.shell/empty-downloads`. The load skips it with one loud log line and the utterance
  resolves `.none`. Shell stays arm-surface-only.

## Requirements

### Must-have

**R1 — `PhraseIntentRow` (Core vocabulary).** `phrase`, `providerID`, `toolID`, stdlib-only,
`Sendable`/`Equatable`. No arguments field.

**R2 — `PhraseIntentResolver` (Core, Foundation-free).** `init(rows:)`. `resolve(_:against:)`
normalizes the utterance (lowercased, every non-letter/digit run collapsed to one space,
trimmed). Returns `.toolCall(ActionInvocation(providerID:toolID:arguments: nil))` for the
**first** row, in table order, whose normalized phrase equals the normalized utterance **and**
whose target is in the caller's catalog. Otherwise returns `.none`. It **never returns `.ask`**:
an exact matcher has no confidence gradient. Empty or whitespace-only utterances resolve `.none`
before any lookup. It never invents a tool the catalog does not name, and a row targeting a tool
outside the catalog is inert.

**R3 — `IntentPhraseStore` (`VoccaActions/Config/`).** Persists
`<applicationSupport>/Vocca/intent-phrases.json` as `{"version": 1, "phrases": [...]}`.
- **Loading is tolerant:** an absent file is the empty table with no log. An unreadable file, a
  non-object top level, or a wrong version is the empty table plus one loud log. Invalid rows
  are skipped with one loud log each: an empty field, a duplicate normalized phrase (the first
  row wins), a phrase whose normalization is empty, an over-long field, or a
  `dev.vocca.shell` target.
- **Loading never writes.**
- **Saving is atomic:** write a temp file and rename it, with sorted keys.
- **Caps refuse, never clamp:** 256 phrases, 64 KB file, 256-char phrase, 128-char ids.
  Saving over a cap throws, and loading an oversize file loads empty with one loud log.
- **Shape-only:** no enablement, no arguments, no timestamps. It is the
  `FileSystemDictionaryStore`/`ShellCommandRegistry` shape.

**R4 — The shell refusal.** A row whose `providerID == "dev.vocca.shell"` is refused at
load (R3). The resolver never sees it. `intentShellRows=0` stays asserted, now counted over
the phrase table the composed default reads as well as the keyword seeds.

**R5 — Per-call reading, no relaunch.** The wiring reads the phrase file **per resolution**,
never at composition. That keeps the recipe probe-safe (`IntentWiring.swift` "Probe-safe by
construction"), and an edit takes effect on the next turn. `composeIntentWiring` gains a
resolver-*provider* parameter, `@Sendable @MainActor () async -> any IntentResolver`. The
existing `resolver:` form forwards to it, so current call sites and tests are unchanged.

**R6 — The composed default flips.** `AppBootstrap.swift:701`'s `NullIntentResolver()`
becomes a provider that loads the real store and builds `PhraseIntentResolver(rows:)`. This
is a reviewed edit (the N1 precedent) and the G5 pin is re-anchored once in REFACTOR,
computed with `shasum`, never edited to match. `NullIntentResolver` stays shipped; it is
still a valid conformance and the probe's control.

**R7 — The safety acceptances over a phrase hit.**
- A phrase naming an enabled destructive tool is `.confirmationRequired` **by attempting
  the call**, and the provider is not invoked.
- An outward-facing tool resolved by phrase always confirms under every approval, policy and
  mode shape (`EscapeValveTests` extended).
- A phrase naming a disabled or unknown tool resolves `.none`, and the provider's call log
  stays empty.

**R8 — The probe.**
- `PROBE-INTENT-DEFAULT` becomes `resolver=PhraseIntentResolver resolves=1 intentResolved=0
  spawnsSubprocess=false intentShellRows=0`. The `phrases=` count moved to the phrase line in
  planning, because the composed root reads the real Application Support directory, so the
  count would be machine-dependent.
- A new `PROBE-INTENT-PHRASE` line drives a seeded temp table through the composed recipe:
  `phrases=1 resolved=1 card=yes invoked=1 shellRefused=1`.
- Both run inside the zero-network interposer, each with its guard-the-guard pair (a planted
  weakened constant fails loudly).

### Should-have

**S1 — SMOKE rows.** Written and runnable, recorded and never gated, run by nothing in CI:
- add a phrase for `audit.count`, converse it, and see it resolve;
- edit the file mid-session and see the next turn pick the edit up;
- add a shell-target row and see it refused, with the log line visible.

### Nice-to-have

**N1 — Record the keyword escaping defect.** `KeywordIntentResolver.jsonEscaped` emits
`\u{XX}` for control characters, which is not valid JSON. Record it in the unit record as a
finding. Fixing it is a separate reviewed edit, because it touches a pinned resolver.

## Technical Considerations

- **Layer / phase:** Actions (P4, C13). It touches `VoccaCore/Intent/` (the resolver and
  row), `VoccaActions/Config/` (the store), `VoccaBootstrap` (`IntentWiring.swift`,
  `AppBootstrap.swift`), `VoccaNetworkProbe/IntentDrive.swift`, and `Tests/HarnessTests`. It
  does **not** touch capture, ASR, cleanup, injection or TTS, and the dictation digests must
  stay unchanged.
- **Module boundaries:**
  - `VoccaCore`'s import allow-list is empty (`CoreBoundaryTests.swift:116`), so the resolver
    and row are stdlib-only. The normalizer is Foundation-free, like the keyword tokenizer. It
    is a separate private function, not shared: sharing would move pinned code.
  - The store lives in `VoccaActions` (Foundation allowed) next to `ShellCommandRegistry`.
    VoccaActions already depends on VoccaCore, so no manifest edit is needed.
  - `IntentSeamBoundaryTests` confines which files may name each intent type. The new type
    names are a **reviewed widening** of that lint, done in the resolver's REFACTOR.
- **Decode safety (the F1 lesson):** decode with `JSONDecoder` into `String` fields, and
  refuse non-string values. There are no booleans in the shape, so the `NSNumber` collapse
  cannot reach it. Rows decode element-wise, like the dictionary store.
- **Latency:** off the dictation path. It costs one small file read and one normalized-string
  comparison per committed converse turn, at a decision point after cleanup
  (`ReplyGenerator.swift:26-31`). The 64 KB cap bounds the read.
- **Privacy / local-first:** the file holds phrases the user typed and tool identifiers, never
  transcripts, and it never leaves the machine. Zero network. No child process is spawned: the
  shell refusal plus D2's "the default configuration cannot create a shell child".
- **The G5 pin:** `AppBootstrap.swift` changes once, in the wiring REFACTOR. Recompute
  `e9aa45bb…` → new with `shasum -a 256` in the same commit.
- **Test floor:** starts at 2825 (`Scripts/test-with-floor.sh:2030`). Each RED commit raises
  it in the same commit as its tests.

## Risks & Open Questions

| Risk / question | Notes |
|---|---|
| **R8 — unintended actions** (mitigated, not retired) | A phrase is the user's own declaration, so a wrong-but-confident resolution is *less* likely than with keywords. It is still bounded by the gate, not the classifier. N2 stands: an approval asserts a human said yes and cannot verify it. |
| **Exact match is brittle against ASR/cleanup drift** | "Clear the audit log." vs "clear the audit-log" normalize equal, but "clear audit log" does not. That is deliberate: brittleness fails to `.none` (the echo), never to a wrong tool. Real behaviour is unmeasured until the SMOKE run. |
| **The default flip changes the shipped fact line** | `resolver=NullIntentResolver` → `PhraseIntentResolver`. The behaviour with no file is identical (`intentResolved=0`). The honest statement: the shipped app *can* now voice-act if the user writes a phrase file **and** enables the tool. That is a two-step opt-in, recorded as the narrowing of the unwired posture. |
| **Keyword resolver becomes un-composed** | Neither the old default (Null) nor the new one composes the keyword resolver, so nothing is lost in the shipped app. The keyword resolver stays a shipped, tested conformance. |
| **A phrase file edited to target a tool that later disappears** | It's inert: the catalog is per-call enablement, so a missing tool resolves `.none`. |
| **Shell-refusal location** | Refusing at load (store) rather than in the resolver keeps Core ignorant of provider ids. The probe asserts the effect end to end. |
| **Guardrail 7 honesty** | Two real classifiers now exist, but they don't compose: only one resolver is in the default at a time. The record states exactly that. |

## Out of Scope

- **A composite resolver** (phrase first, keyword fallback). It would be a third type and a
  new ordering decision. It's a later slice.
- **Arguments on phrase rows**, `{{utterance}}` templating, and anything MCP-args-bearing.
- **Voice paths to shell commands.** Refused at load; reversing that is its own founder
  decision.
- **A Settings editor** for phrases (file-only, the C5 precedent). Import/export too.
- **Fuzzy or partial matching**, `.ask` from the phrase resolver, and any LLM intent.
- **Fixing `KeywordIntentResolver`'s escaping** (recorded only, N1).
- Coding-agent handoff, reply-text rendering, time-boxed/decaying trust (§8 deferral stands),
  and any change to the dictation path, the MCP transport, or the shell executor. No cloud,
  telemetry or egress.

## Aspect Decomposition

1. **`phrase-resolver`**: `PhraseIntentRow` + `PhraseIntentResolver` in Core (with the one
   public `normalized(_:)`), the contract suite over both real resolvers, and the seam-lint
   widening.
2. **`phrase-table-store`**: `IntentPhraseStore`: the file shape, tolerant decode, caps,
   atomic save, and the shell-row refusal (it reuses the resolver's normalization, so the
   duplicate check and the match cannot disagree).
3. **`wiring`**: the resolver-provider widening of `composeIntentWiring`, the default flip in
   `AppBootstrap`, the per-call reading, the safety acceptances (R7), and the G5 re-anchor.
4. **`probe`**: the `PROBE-INTENT-DEFAULT` update, `PROBE-INTENT-PHRASE`, and the
   guard-the-guard pairs.
5. **`record`**: the STATUS entry, CLAUDE.md / CAPABILITY_ROADMAP amendments, the SMOKE rows,
   and the N1 finding.

Sequencing: 1 → 2 (the store reuses the resolver's row type and normalization) → 3 → 4 → 5.
The planning for 1 and 2 can run in parallel once R1's row signature is fixed.
