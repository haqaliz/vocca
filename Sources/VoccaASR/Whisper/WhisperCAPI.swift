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
        var languageBuffer: [CChar] = Array(parameters.language?.utf8CString ?? "auto".utf8CString)
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
