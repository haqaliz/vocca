# Aspect spec — `download-ui`

Parent PRD: [`../prd.md`](../prd.md) · Capability C2 · Phase P0
Depends on: asr-seam, model-downloader, parakeet-engine, fixture-suite (committed)

---

## Problem slice

The downloader, the store, and the engine exist; the user has no way to see or drive the
model's first arrival. The PRD's minimal surface (M15): a bare progress window with a Skip
button, honest copy, shown when the engine is missing.

**The structural constraint that shapes this aspect:** `VoccaUI` may import **only**
`VoccaCore` among Vocca modules (the module-boundary lint). The store lives in `VoccaASR`.
So the UI cannot touch the store — the contract between them must be a **seam owned by
Core**: `ModelDownloadSession`. The UI is a consumer of that seam; the store-binding
adapter is an adapter; the composition root wires them. That is the same inward arrow the
whole repository runs on.

**User outcome:** first launch with no model → a small window shows the download
progressing, then completes (or skips); the widget's eventual "engine missing" state is the
honest `modelUnavailable` the engine already throws.

**The honesty line:** the window itself is executed by nothing in CI (a real window needs a
window server session); the *decisions* — the state reducer — are pure and tested, and the
session adapter is fully headless over the stub transport.

---

## In scope

- **Core seam** (`VoccaCore`): `ModelDownloadEvent` (`.progress(Double)`, `.committed`,
  `.failed(String)`, `.cancelled`) and `ModelDownloadSession` (`events: AsyncStream<ModelDownloadEvent>`,
  `cancel()`).
- **The adapter** (`VoccaASR`): `StoreModelDownloadSession` — binds a `ModelStore` +
  `ModelManifest` + transport; drives `downloadIfMissing`, feeding progress 0...1, `.committed`
  on success, `.failed(reason)` on error, and **`.cancelled` when the user cancels** (the
  store's `.interrupted` maps to the skip semantics — the `.part` survives for the next
  attempt). Headless tests over the stub transport.
- **The reducer** (`VoccaUI`): `DownloadState` (`.idle`, `.downloading(Double)`, `.committed`,
  `.failed(String)`, `.skipped`) + `DownloadStateReducer.reduce(_:event:)` — pure, table-tested:
  monotonic progress clamped 0...1, no regression after `.committed`, cancelled → `.skipped`.
- **The window** (`VoccaUI`): `DownloadProgressView` (SwiftUI: progress bar + status line +
  Skip) hosted in a small `NSWindow` via `NSHostingView`; thin glue over the reducer. The
  first real `VoccaUI` code.
- **Skip semantics:** Skip = `cancel()`; the engine stays unavailable and answers
  `modelUnavailable` with an honest reason (already shipped).

## Out of scope

- The full onboarding step 3 with copy and try-it semantics — the C1 widget aspect.
- The widget's "engine missing" visual state — the widget aspect.
- The engine picker — C3. Registry UI — C14.

---

## Acceptance criteria (tests written first)

1. **Reducer table**: every event × state transition: monotonic progress (a backwards value is
   clamped), `.committed` is terminal, `.failed` and `.cancelled` are terminal, progress after
   a terminal state is ignored, `.cancelled` reads as `.skipped` at the UI.
2. **Session happy path**: over the stub transport + temp store, events end in `.committed`
   with monotonic progress reaching 1.0.
3. **Session failure**: a corrupt-serving transport ends in `.failed` naming the cause, with
   the store not present.
4. **Session skip**: `cancel()` mid-download ends in `.cancelled`, the `.part` survives, and
   the next run resumes from it.
5. **Module discipline**: `VoccaUI` imports only `VoccaCore` among Vocca modules (the lint
   stays green — the seam is what makes that possible); the seam carries no store types.
