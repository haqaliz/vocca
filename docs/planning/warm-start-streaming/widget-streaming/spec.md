# Spec — widget-streaming (slice 2 of warm-start-streaming)

## Problem slice

The C7 streaming vocabulary ships unused: `ASREngine.stream(_:)` has a batch default
(`ASREngine.swift:80-103`), `Transcript.isFinal` already means "false for streaming partials"
(`Transcript.swift:43-44`), and the never-branch-on-`supportsStreaming` rule is pinned
(`ASREngine.swift:35-38`). Nothing consumes the seam, the widget has no partial-text state
(`WidgetReducerState` carries no text), and "zero injection before key-up" is true only by
construction, never by test.

## In-scope

- **S1** A pipeline streaming route: `DictationPipeline` gains `routeStreaming(chunks:)` that
  consumes `engine.stream(chunks)` (the batch default makes degradation structural), emits
  partials (`isFinal == false`) to an injected widget-only sink, and routes exactly one final
  transcript through cleanup → inject with the existing decision table. The chunk source is
  scripted in this unit; the live mic feed is out of scope.
- **S2** The permanent guard: zero `TextInjector` calls before the final, asserted across the
  closed route set (cancelled before final, empty final, throwing stream, post-cleanup
  cancellation).
- **S3** Widget partial state: `WidgetReducerState.partialText` (bounded), a new
  `WidgetAction` carrying partials, the reducer fold (shown during `.recording`/`.transcribing`,
  cleared on adoption of idle/delivered/notice), Reduce Motion → the view stays static.
- **S4** Degradation + swap seam tests: a streaming stub yields partials then one final; a
  batch stub yields one final and never touches the sink; the test source contains no branch
  on `supportsStreaming` (the `EngineSwapTests` pattern).

## Out-of-scope boundaries

- Real streaming Parakeet/whisper adapters (`supportsStreaming == true` implementations).
- The speculative pre-key-up feed (capture-side chunk source).
- Any latency-number claim: partials are provisional by definition; no span change to the
  closed four-span session set.

## Acceptance criteria (testable)

1. `routeStreaming` with a streaming stub emits each partial to the sink in order, then
   routes the final through cleanup → inject exactly once.
2. **The guard:** with an injector double, zero injector calls occur before the final in
   every route of the closed set; the final always injects (or holds via failsafe).
3. Cancellation re-checks hold: Esc before the final finalizes `.aborted`, nothing injected,
   no sink touch after cancellation.
4. Batch stub through the same route: one final, zero partials, identical outcome to the
   batch route (byte-for-byte behaviour with a nil sink).
5. The reducer: partials show only in `.recording`/`.transcribing`; every other adoption
   clears `partialText`; the closed `WidgetAction` set stays closed (exhaustive switch test).
6. The zero-network probe's cycle is unchanged: batch route, zero `connect(2)`.

## Dependencies & sequencing

- After slice 1 (`warm-start`): the pipeline, reducer, and benchmark-gate surfaces are warm.
- Depends on the shipped `latency-instrumentation` unit's recorder/span vocabulary.

## Open questions / risks

- Whether the pipeline emits partials only while `.recording` or also during `.transcribing`:
  the sink carries the partials; the *state* the widget shows them in is the reducer's call
  (S3), and the live feed timing is out of scope — the route renders whatever the stream
  produces.
- `ARCHITECTURE.md:630` open question 2 (speculative final-vs-batch equivalence) is not
  touched: no real engine streams in this unit, so no accuracy claim is made or implied.