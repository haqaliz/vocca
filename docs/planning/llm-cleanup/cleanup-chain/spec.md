# Spec — cleanup-chain

Aspect of `llm-cleanup` (C6) · `docs/planning/llm-cleanup/prd.md`
Requirements: **M6** (owned here).
Depends on: `ollama-provider` and `byok-provider` (the LLM stage's shape) — not on their
internal details, only that they exist and throw honestly.

## Problem slice

The §11 pipeline is "Transcript → RulesCleanup → optional LLM → String" — **rules always run
first**, the LLM stage rewrites the rules output, and on any LLM failure the rules output
stands (`ARCHITECTURE.md:506-512`). "Fallback to rules" is therefore structural, not a
post-hoc rescue: the chain produces rules output first, then attempts the LLM stage on top of
it. This aspect is the composition that makes C6's degrade guarantee ("never breaks
dictation", `ROADMAP.md:140`) one line of code rather than a contract every caller re-checks.

## In scope

1. **`ChainedCleanupProvider` in `Sources/VoccaText/LLM/`** — a `CleanupProvider` conformer
   over `rules: any CleanupProvider` and `llm: (any CleanupProvider)?` (nil = rules-only):
   - `identity` = the LLM stage's when present, else the rules provider's (the ledger must
     attribute the *decisive* stage);
   - `requiresNetwork` = `llm?.requiresNetwork ?? rules.requiresNetwork` (the badge keys on
     it, `ARCHITECTURE.md:296`);
   - `budget` = `llm?.budget ?? rules.budget` (the LLM's declared 5 s covers the whole call;
     rules runs first, inside it);
   - `clean(_:context:)`: `let base = try rules.clean(...)`; if no LLM stage, return `base`;
     guard `base` non-empty/non-whitespace (the never-empty rule,
     `DictationPipeline.swift:360-366` — an empty rules result routes raw at the pipeline,
     but the chain must not feed an empty string to the LLM); build
     `Transcript(text: base)` and call `llm.clean(...)`; if the LLM throws, **return `base`**
     (degrade); if the LLM returns empty/whitespace, return `base`; else return the LLM's
     result.
2. **The degrade is a return, not a rethrow** — the chain swallows the LLM stage's throw
   deliberately (documented) and returns the rules output, so the pipeline's raw-degrade
   (which fires only on chain throw) is reserved for rules-stage failures.
3. **Cancellation honesty**: an LLM stage cancelled by the budget race or Esc throws
   `CancellationError`; the chain must re-check `Task.isCancelled` before returning `base`
   and rethrow cancellation — a cancelled session must never inject (the pipeline's
   post-cleanup re-check is the backstop, `DictationPipeline.swift:262-267`, but the chain
   should not paper over cancellation with a stale rules result).

## Out of scope

- The providers themselves (their aspects), the config/selection (its aspect), the badge
  (its aspect).
- Timeout logic — the pipeline's budget race owns it (M1); the chain only declares the LLM's
  budget.
- Per-mode selection — deferred to C11 (`prd.md` Out of Scope).

## Isolation / honesty decisions

- **The chain is the only place in C6 where a provider result is replaced by another
  provider's result.** That makes the degrade policy a single tested function instead of a
  promise repeated in two providers and a caller.
- **The LLM stage's throw is a *policy*, not an accident**: swallowed-throw + cancellation
  rethrow are both explicit branches with their own tests (a reviewer must be able to see the
  difference).
- **Identity follows the decisive stage** — with an LLM active, attribution says "ollama"
  even though rules ran; the ledger's cleanup span already records *that* a cleanup happened
  (C5), and identity records *which* one decided the output.

## Acceptance criteria (tests written first)

Failing XCTests in `Tests/HarnessTests/` — `CleanupChainTests.swift`:

- B1 **Rules-only passthrough.** `llm == nil`: identity/requiresNetwork/budget are the rules
  provider's; output is exactly the rules output; the LLM slot is never consulted.
- B2 **Chain composition.** With an LLM stage: the LLM stub receives the **rules output** as
  its transcript (asserted via the stub's recorded input), and the LLM's result is returned.
- B3 **LLM throws ⇒ rules output stands.** Every LLM failure mode (throw, timeout-expiry
  shape) returns the rules output, and the chain does not rethrow.
- B4 **LLM returns empty/whitespace ⇒ rules output stands.**
- B5 **Cancellation rethrow.** The LLM stage is cancelled (injected cancellation): the chain
  rethrows `CancellationError`; it does not return a stale rules result.
- B6 **Propagation.** `requiresNetwork` and `budget` propagate from the LLM stage when
  present; identity = LLM's; all three flip back to rules when absent.
- B7 **Never-empty into the LLM.** An empty/whitespace rules output skips the LLM stage and
  returns the rules output as-is (the LLM stub records no call).
- B8 **Boundary discipline.** Full suite green under the floor; Swift 6 clean; Apache header;
  no new dependency.

## Dependencies / sequencing

- After `ollama-provider`/`byok-provider` (their conformer shape is the input) — either
  provider alone suffices to build against, since the chain is provider-agnostic.
- Precedents: the never-empty guard (`DictationPipeline.swift:360-366`), the shipped rules
  conformer (`ShippingCleanup.swift:32-49`), `ScriptedCleanupProvider` (throw/hang doubles,
  `DictationPipelineTests.swift:1090-1166`).

## Open questions / risks

- **Transcript construction for the LLM stage.** The seam takes `Transcript` (Core type with
  `missingSampleCount`); the chain builds `Transcript(text: base)` with zero missing samples
  — the completeness link (I1) is already closed upstream at capture; the chain's synthetic
  transcript must not claim samples it doesn't have. The plan pins the exact init.
- **Double-clean semantics.** The LLM rewrites rules output, so the dictionary's effects
  survive (they're in `base`); an LLM that re-introduces fillers is an LLM-quality problem
  the founder's real run judges (`prd.md` "quality not implied").
