# Understanding: speech-engine-switch

**Phase 2 deep dig, 2026-08-28.** Read against `docs/ROADMAP.md`, `docs/technical/CAPABILITY_ROADMAP.md`,
`docs/product/PRODUCT_SPEC.md` and the shipped source. Every claim below is cited; nothing is
asserted from memory.

---

## 1. What the work is really asking

Where the work sits: **P0, capability C3** — the ASR layer, `ASREngine` seam. Not P2, not the
agent layer. It is squarely dictation-first and local-only: no network beyond the model download
that already exists, no cloud in the OSS core, nothing that touches the hosted-tier seams.

`CAPABILITY_ROADMAP.md:81` lists C3's second bullet as an unbuilt deliverable:

> Engine selection in settings, **switchable without restart**, with an honest description of the
> tradeoff (Parakeet: faster; Whisper: broader language and accuracy coverage).
> A **per-engine model-tier choice**, so constrained machines can drop to a smaller Whisper model
> rather than falling off a cliff.

`PRODUCT_SPEC.md:254-262` specifies the surface exactly — and it is the authority on user-visible
behaviour:

```
◉ Parakeet v3      Fastest. 25 European languages.        [ installed ]
○ Whisper turbo    Slower, broader language coverage.     [ download ]

  Model management: disk used, remove, re-download.
```

So the unit is: **a persisted engine + tier selection, applied without a restart, surfaced as the
Speech tab the product spec already draws.** The per-tier install state and model management are
part of the specified surface, not an extension of it.

## 2. Affected areas

| Area | File | What it does today |
|---|---|---|
| The value | `Sources/VoccaCore/EngineSelection.swift:88` | `EngineSelection(tier:)`; `defaultSelection = .parakeetV3` (`:96`) |
| Identity resolve | `Sources/VoccaUI/EnginePickerView.swift:28` | `EngineSessionStart.resolve(selection:)` — pure, tested, **called by nothing else** |
| Picker reducer | `Sources/VoccaUI/EnginePickerState.swift` | Built and tested in C3; **no constructor anywhere in `Sources/`** |
| Composition | `Sources/VoccaBootstrap/AppBootstrap.swift:196,206,208,355,937` | Five sites, all reading the hardcoded `EngineSelection.defaultSelection` |
| Settings surface | `Sources/VoccaUI/SettingsView.swift:160-176` | Speech tab is read-only, and says so |
| Manifests | `Sources/VoccaASR/Models/Manifests/*.json` | Three: one Parakeet, two Whisper tiers |

## 3. Findings the brief did not anticipate

### F1 — The two Whisper tiers collide in the model store (defect, blocking)

`ModelStore` keys every model directory as `<root>/<engineID>/<version>/`
(`Sources/VoccaASR/Models/ModelStore.swift:89-92`), and `isPresent` / `downloadIfMissing`
(`:103`, `:158`) are keyed on that same pair. But **both** Whisper manifests declare the
identical key:

- `whisper-large-v3-turbo.json` → `engineID: "whisper-large-v3-turbo"`, `version: "1"`, one file
  `ggml-large-v3-turbo.bin`, 1 624 555 275 bytes
- `whisper-large-v3-turbo-q5_0.json` → `engineID: "whisper-large-v3-turbo"`, `version: "1"`, one
  file `ggml-large-v3-turbo-q5_0.bin`, 574 041 195 bytes

`ShippedModelManifest.load(for:)` maps the tiers to the two different files correctly
(`ShippedModelManifest.swift:60-69`) — the collision is in the *store key*, not the lookup. So
once either tier is downloaded, `isPresent` answers `true` for the other, `downloadIfMissing`
short-circuits at `:158`, and the engine is asked to load a `.bin` that is not on disk.

**This is invisible today because no user can select a tier at all.** This unit is what would
expose it — and the specified Speech tab computes its `[installed]` / `[download]` badge from
exactly that key. It has to be fixed inside this unit, not after it.

### F2 — The predicted placeholder-digest defect is NOT present

The brief's stated caveat (`CLAUDE.md`: the Whisper manifests "were generated the same way and
have still never been downloaded — the same defect may be sitting in them") **does not reproduce.**
Checked directly: SHA-256 of the literal `{}` is
`44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a` and of the empty string
`e3b0c44298…`; neither appears in any manifest, no entry has a 0- or 2-byte size, and no digest is
duplicated across files. The declared byte counts (1.62 GB / 574 MB) match the published
`ggml-large-v3-turbo` artifacts in magnitude.

What remains **unverified** is whether the digests match the bytes the repository actually serves —
that needs a real download, and only an env-gated run on the founder's machine can answer it.
Correcting the record: the risk is real but is "unverified", not "defective".

### F3 — The Cleanup tab reports a hardcoded answer (defect, adjacent)

`AppBootstrap.swift:938`: `cleanupSummary: { ("Built-in rules", nil) }`. It is a literal. A user
who opted into Ollama or BYOK via `cleanup-config.json` sees the Cleanup tab say **"Built-in
rules"** with no endpoint — while the widget's egress badge correctly shows the cloud marker.
`SettingsView.swift:186` calls the egress line "the point of this tab… where they can check
*before* it ever does", and today that line cannot appear. Out of scope for this unit, but it
should be filed rather than silently observed.

### F4 — The activation mode is live but not persisted

`AppBootstrap.swift:888`: `activeMode: DictationMode = DictationLoopRoot.defaultMode` — a
constant, read from no store. The General tab's one live control is **lost on every relaunch**.
Same class as this unit, and worth naming in the PRD as either in-scope or explicitly deferred.

## 4. The constraint that shapes the design

**`CompletionFlagStore` is "the one file in `Sources/` permitted to name `UserDefaults`"**
(`Sources/VoccaUI/Onboarding/CompletionFlagStore.swift:17-20`), pinned by the seam table in
`Tests/HarnessTests/InjectionSeamBoundaryTests.swift:1540`. The FileManager table is pinned
harder still — `:1294-1304` asserts it "must name **exactly** the four shipped seams". So a new
persistence file is not a free choice: it either extends an existing seam or ships a lint-table
amendment **in the same commit** (the house process, exactly as `CompletionFlagStore` itself did —
its own doc comment records "the lint table amendment ships in the same commit").

## 5. Contradiction to resolve at the interview

The brief I was handed said *restart-to-apply*, on the reasoning that `DictationEngineResolver`
resolves once at launch. **The repo disagrees with the brief, twice:**

- `CAPABILITY_ROADMAP.md:81` says "switchable **without restart**".
- `Tests/HarnessTests/EngineSelectionConsumptionTests.swift:24-27` already pins the promise:
  *"**No restart needed** (`CAPABILITY_ROADMAP.md:78`): a session begun after a selection change
  reads the new selection — the resolver takes the current `EngineSelection` as its input, so
  nothing about it is cached at launch."*

That doc comment describes `EngineSessionStart.resolve`, a pure function — it is **not** true of
the shipped composition root, where `DictationEngineResolver(selection: .defaultSelection)` is
constructed once at `AppBootstrap.swift:196`. So a passing test currently narrates a promise the
wired app does not keep.

The precedent that resolves it is already in the tree: `setActiveMode`
(`AppBootstrap.swift:1277-1291`) refuses to switch while a session is in flight, logs, and
otherwise applies immediately — the user "gets the change on their next press rather than a broken
session" (`:934`). **Next-session-boundary, no restart** is the house answer, and it satisfies
C3's acceptance ("swaps the engine at runtime mid-session-boundary and asserts no caller above the
seam observes anything except a different `engineIdentity`") without weakening the never-swap rule.

## 6. Open questions for the PRD

1. **Scope of the store.** Extend `CompletionFlagStore` into a general settings store, or ship a
   second UserDefaults seam with the lint-table amendment? (F4 makes this a two-setting question,
   not a one-setting question.)
2. **Does the resolver gain a reset path**, or is it reconstructed per session boundary? This is
   the load-bearing design decision.
3. **How much of `PRODUCT_SPEC.md:260`'s "model management: disk used, remove, re-download"** is
   in this unit versus deferred? Removal has a hard edge: deleting the model for the *active*
   engine mid-session.
4. **Is F1's key collision fixed by versioning the tier into `engineID`** (e.g.
   `whisper-large-v3-turbo-q5_0`) — which changes an on-disk path users may already have — or by
   adding a tier component to the store key? Migration matters either way.
5. **F3 and F4**: in scope, or filed as separate units?

## 7. Guardrail check

- **macOS-only, local-first, dictation-first, open-core**: clean. No cloud in the OSS core; the
  only network is the pre-existing model download, opt-in and user-initiated.
- **Never cripple the local core**: this *strengthens* it — it makes the second local engine
  reachable, which is the mitigation R5 (`docs/ROADMAP.md` risk register, Med/High) is supposed to
  provide and currently provides only on paper.
- **Two make-or-break battles**: touches neither latency nor injection adversely; the tier choice
  is what lets a constrained machine avoid the latency cliff.
- **Seam discipline** (`CAPABILITY_ROADMAP.md:400`, guardrail 7): this is the unit that turns
  "two implementations shipped" from an assertion into something a user can exercise.
