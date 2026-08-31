// Copyright 2026 The Vocca Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import whisper

/// Why the bridge's C work failed, in the bridge's own vocabulary — typed errors the engine maps
/// onto ``VoccaError`` with the cause intact, never stringified.
public enum WhisperCAPIError: Error, Sendable, Equatable {
    /// `whisper_init_from_file_with_params` returned nil: the model file was missing or not a
    /// readable whisper model.
    case contextCreationFailed(modelFileURL: URL)
    /// `transcribe` was called on a context that has not prepared (the engine's load-state guard
    /// prevents it; the case exists so the bridge never force-unwraps).
    case contextNotPrepared
    /// `whisper_full` returned a nonzero status — the C layer's own error code, carried intact.
    case transcriptionFailed(code: Int32)
}

/// **The one file in `Sources/` permitted to name the whisper C ABI** (the two-sided seam lint,
/// `WhisperSeamTests`): the translation of the C surface into Swift values, with no decisions in
/// it beyond direct argument forwarding and unit conversion — the H7 doctrine in the same shape as
/// `CGEventTapSource` and `ParakeetEngine`.
///
/// ## What this file is, and is not
///
/// It is the adapter: thin glue. **CI never executes a line of it** — a whisper model cannot reach
/// a hosted runner — and that is acceptable because everything this file *decides* lives above it,
/// in ``WhisperTranscriptMapper``, ``WhisperLoadState``, ``WhisperCppParameters`` and
/// ``WhisperCppEngineIdentity`` — all headless, all in `WhisperCoreTests`. The decisions here are
/// reduced to: initialise the context once, run `whisper_full` once, read the segments out, free
/// the context. Nothing else.
///
/// The C pointer (``OpaquePointer`` is not `Sendable` in Swift 6) never leaves this object, and
/// this object never leaves the engine actor's isolation domain: the engine owns it, calls it only
/// on its own executor, and the non-`Sendable` ``WhisperContext`` seam (the `MonotonicClock`
/// precedent) is what keeps the C ABI from crossing any boundary.
///
/// ## Units and translation facts (verified against the pinned v1.9.2 header and source)
///
/// - Segment timestamps are **centiseconds** — each raw unit is 10 ms (`seek = offset_ms/10`, the
///   header's "in centiseconds" wording) — and are converted by the pure
///   ``WhisperTranscriptMapper/seconds(fromCentiseconds:)``, never divided here.
/// - `whisper_full_default_params` defaults `language` to `"en"` — *not* auto-detection. The
///   parameters contract (`WhisperCppParameters.language == nil` means auto) is honoured by
///   translating nil to the explicit `"auto"` sentinel the C layer recognises.
public final class WhisperCAPI: WhisperContext {

    /// The translated parameter values, held for the context's lifetime.
    private let parameters: WhisperCppParameters

    /// The C context — nil until `prepare` succeeds. Confined to this object, which is confined
    /// to the engine actor.
    private var context: OpaquePointer?

    public init(parameters: WhisperCppParameters = .init()) {
        self.parameters = parameters
    }

    /// Creates the C context for the model at `modelFileURL` — once. A second call is a no-op, so
    /// the engine's load-once idempotence has a translation-level backstop.
    ///
    /// - Throws: ``WhisperCAPIError/contextCreationFailed(modelFileURL:)`` when the C layer
    ///   refuses the file (missing, corrupt, or the wrong architecture).
    public func prepare(modelFileURL: URL) throws {
        guard context == nil else { return }
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        guard let ctx = whisper_init_from_file_with_params(modelFileURL.path, cparams) else {
            throw WhisperCAPIError.contextCreationFailed(modelFileURL: modelFileURL)
        }
        context = ctx
    }

    /// Runs the full model over the samples and reads the segments out, translated.
    ///
    /// - Throws: ``WhisperCAPIError/transcriptionFailed(code:)`` with the C layer's own nonzero
    ///   `whisper_full` status, or ``WhisperCAPIError/contextNotPrepared`` if the context does
    ///   not exist.
    public func transcribe(samples: [Float]) throws -> [WhisperSegment] {
        guard let context else {
            throw WhisperCAPIError.contextNotPrepared
        }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(parameters.threads)
        params.no_timestamps = false
        params.single_segment = false
        // The C default is "en"; nil means auto-detect in this product's vocabulary, so nil is
        // translated to the explicit "auto" sentinel. The buffer outlives the call below.
        let languageBuffer: [CChar] = Array(parameters.language?.utf8CString ?? "auto".utf8CString)
        params.language = languageBuffer.withUnsafeBufferPointer { $0.baseAddress }

        let status = samples.withUnsafeBufferPointer { buffer in
            whisper_full(context, params, buffer.baseAddress, Int32(samples.count))
        }
        guard status == 0 else {
            throw WhisperCAPIError.transcriptionFailed(code: status)
        }

        let segmentCount = Int(whisper_full_n_segments(context))
        return (0..<segmentCount).map { index in
            let cIndex = Int32(index)
            let text = whisper_full_get_segment_text(context, cIndex).map { String(cString: $0) } ?? ""
            let start = WhisperTranscriptMapper.seconds(
                fromCentiseconds: whisper_full_get_segment_t0(context, cIndex))
            let end = WhisperTranscriptMapper.seconds(
                fromCentiseconds: whisper_full_get_segment_t1(context, cIndex))
            // Segment confidence is deliberately nil: the C API exposes per-*token* log
            // probabilities, not a segment-level probability, and deriving one would be a decision,
            // not translation — the spec allows nil ("engine exposes none").
            return WhisperSegment(text: text, start: start, end: end, tokenProbability: nil)
        }
    }

    /// One streaming pass over the current buffer: a full decode with a new-segment callback
    /// registered, harvesting each newly generated segment into a per-call box (whisper.cpp's
    /// canonical stream pattern — repeated `whisper_full` on the growing buffer, this method
    /// called once per pass). The returned list is everything the decode produced — the answer
    /// a batch decode of the same buffer yields, **by construction**: the params here must stay
    /// field-for-field identical to ``transcribe(samples:)``'s, the call is the same
    /// `whisper_full` machinery, and the audio is the same buffer.
    ///
    /// - Throws: the same contract as ``transcribe(samples:)``.
    public func transcribeStreaming(samples: [Float]) throws -> [WhisperSegment] {
        guard let context else {
            throw WhisperCAPIError.contextNotPrepared
        }

        // Must stay field-for-field identical to `transcribe(samples:)`'s params construction:
        // the streamed final equals the batch transcription by construction only while this
        // holds. The duplication is deliberate and is the pin — no test executes the CAPI, so a
        // shared helper could drift the batch path with nothing in CI to catch it; a shared
        // helper becomes safe only after SMOKE step 19's real run.
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(parameters.threads)
        params.no_timestamps = false
        // `single_segment` stays false: the header's "useful for streaming" note applies to the
        // stateful incremental pattern (`whisper_full_with_state`, N2 — deferred), not to this
        // one. Forcing single-segment here would change segmentation versus the batch path and
        // break the final ≡ batch by-construction guarantee.
        params.single_segment = false
        // The C default is "en"; nil means auto-detect in this product's vocabulary, so nil is
        // translated to the explicit "auto" sentinel. The buffer outlives the call below.
        let languageBuffer: [CChar] = Array(parameters.language?.utf8CString ?? "auto".utf8CString)
        params.language = languageBuffer.withUnsafeBufferPointer { $0.baseAddress }

        // The per-call harvest box: a `@convention(c)` callback cannot capture, so the box rides
        // in `new_segment_callback_user_data`, retained for the call and released on every path
        // (the `defer` below). The callback fires on the calling thread inside `whisper_full`,
        // which the engine actor serializes — "Not thread safe for same context" is satisfied
        // by the single-executor rule. The box lives only within the call: no cross-call state,
        // no leak, no use-after-free, and it never leaves the actor.
        let box = SegmentHarvestBox()
        let retained = Unmanaged.passRetained(box)
        params.new_segment_callback = { ctx, _, nNew, userData in
            guard let ctx, let userData else { return }
            Unmanaged<SegmentHarvestBox>.fromOpaque(userData)
                .takeUnretainedValue()
                .harvest(context: ctx, nNew: nNew)
        }
        params.new_segment_callback_user_data = retained.toOpaque()
        defer { retained.release() }

        let status = samples.withUnsafeBufferPointer { buffer in
            whisper_full(context, params, buffer.baseAddress, Int32(samples.count))
        }
        guard status == 0 else {
            throw WhisperCAPIError.transcriptionFailed(code: status)
        }

        return box.segments
    }

    /// Frees the C context. Runs wherever the last release happens, which is not this object's
    /// choice — so it takes the shipped teardown route (the `DeinitIsolationTests` rule, in the
    /// same shape as `MainRunLoopTimer`, `CGEventTapSource`, `ScheduledWatchdog` and
    /// `TapHealthTimer`): the `deinit` calls the non-asserting ``tearDown()``, never an entry
    /// point that could assert an isolation domain.
    deinit {
        tearDown()
    }

    /// The non-asserting teardown, reached only from `deinit`.
    ///
    /// `whisper_free` is a plain C function that frees an opaque context — it has no isolation
    /// concept to assert, and it is safe wherever the last release happens.
    private func tearDown() {
        if let context {
            whisper_free(context)
        }
    }
}

/// The per-call harvest box: collects the segments the new-segment callback reports during one
/// `whisper_full` decode. A `@convention(c)` closure cannot capture, so the box rides in the
/// callback's `user_data` pointer — retained per call by ``WhisperCAPI/transcribeStreaming(samples:)``
/// and released on every path, never crossing a boundary.
private final class SegmentHarvestBox {

    /// The segments harvested so far, in decode order — the callback's report of `n_new`
    /// segments is the last `n_new` of the context's segment list, so each new segment is
    /// appended exactly once.
    var segments: [WhisperSegment] = []

    /// Appends the `n_new` segments the callback reports, translated exactly as the batch
    /// readout in `transcribe(samples:)` translates them (the parity comment there applies —
    /// both paths must produce identical values from the same context).
    func harvest(context: OpaquePointer, nNew: Int32) {
        let total = Int(whisper_full_n_segments(context))
        let start = max(0, total - Int(nNew))
        for index in start..<total {
            let cIndex = Int32(index)
            let text = whisper_full_get_segment_text(context, cIndex).map { String(cString: $0) } ?? ""
            let startTime = WhisperTranscriptMapper.seconds(
                fromCentiseconds: whisper_full_get_segment_t0(context, cIndex))
            let endTime = WhisperTranscriptMapper.seconds(
                fromCentiseconds: whisper_full_get_segment_t1(context, cIndex))
            // Segment confidence is deliberately nil — see the batch readout's comment.
            segments.append(WhisperSegment(text: text, start: startTime, end: endTime, tokenProbability: nil))
        }
    }
}
