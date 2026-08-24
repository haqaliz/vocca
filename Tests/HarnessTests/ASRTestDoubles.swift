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

import VoccaCore

// The ASR engine double the seam tests are driven through, and the two identities that stand in
// for the two shipped engines (`CAPABILITY_ROADMAP.md:60`).
//
// Shared rather than copied for the reason `SessionTestDoubles.swift` gives at its top: the seam's
// whole contract — attribution, the empty-buffer policy, the batch streaming default, the prepare
// policy — is measured against this one object, and a second copy that drifted from this one would
// let one suite pass against an engine that behaves differently from the one the others use. It
// stays in one file with the seam tests because it is the seam's double: no engine exists at C2,
// and the stub is the only `ASREngine` the suite will ever execute.

/// **The ASR engine, with the model taken out** — the one thing CI can execute, because the two
/// real engines (`FluidAudio`'s Parakeet, whisper.cpp at C3) both need model files a hosted runner
/// cannot download and a microphone it does not have.
///
/// It is deliberately **not** streaming: it implements `identity`, `supportsStreaming` (false),
/// `prepare()` and `transcribe(_:)` and **no** `stream` — whether it still satisfies the protocol
/// is the first thing the seam tests assert, because that is the claim that the batch default
/// exists (`ARCHITECTURE.md:226-228`).
///
/// It is an **actor**, not a class: `ASREngine` is a `Sendable` protocol, and the double must cross
/// actor boundaries honestly — `@unchecked Sendable` on a counter would be measuring Sendability
/// with the very race the seam exists to avoid.
///
/// ## The transcription is a pure function of the samples
///
/// `transcribe` turns the buffer into `"1 2 3"` — the sample values joined with spaces. That is
/// what makes the batch-default test meaningful: transcribing the merged buffer gives exactly the
/// concatenation of transcribing each chunk, because merging concatenates samples. The stub has no
/// model, so it is the caller's ground truth; the test writes the expected strings by hand rather
/// than asking the stub, which is the difference between pinning a contract and restating an
/// implementation.
actor StubEngine: ASREngine {
    /// The Parakeet stand-in — the C2 default engine's identity
    /// (`"parakeet-tdt-0.6b-v3"`, `ARCHITECTURE.md:153`).
    static func parakeet() -> StubEngine {
        StubEngine(
            identity: EngineIdentity(
                id: "parakeet-tdt-0.6b-v3", displayName: "Parakeet TDT 0.6B v3", isLocal: true))
    }

    /// The whisper.cpp stand-in — the C3 swap test's seed: a different `id`, so its transcripts
    /// must carry a different engine than the Parakeet stub's, or downstream attribution is a lie.
    static func whisper() -> StubEngine {
        StubEngine(
            identity: EngineIdentity(
                id: "whisper-large-v3-turbo", displayName: "Whisper large-v3-turbo", isLocal: true))
    }

    let identity: EngineIdentity

    /// `false` until C7 (`ARCHITECTURE.md:226-228`): the stub is a batch engine, and the seam tests
    /// must measure the batch default, not a stream the stub implemented itself.
    let supportsStreaming = false

    /// How many times `prepare()` was called — the ledger half of the prepare-policy contract. The
    /// seam documents the policy and does not enforce it: **the engine owns it**, and this count is
    /// how a test tells whether `transcribe` honoured it or quietly re-prepared.
    private(set) var prepareCount = 0

    /// How many times `transcribe(_:)` was called — the ledger half of the pipeline contract: a
    /// decision that skips transcription (a cancelled outcome, an empty captured buffer) is
    /// asserted against this count rather than assumed.
    private(set) var transcribeCalls = 0

    init(identity: EngineIdentity) {
        self.identity = identity
    }

    func prepare() async throws {
        prepareCount += 1
    }

    func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        transcribeCalls += 1
        return Transcript(
            text: Self.text(for: buffer.samples),
            segments: [],
            engine: identity,
            isFinal: true,
            audioDuration: buffer.audioDuration)
    }

    /// The deterministic transcription: `[1, 2, 3]` becomes `"1 2 3"`. An empty buffer becomes `""`.
    private static func text(for samples: [Float]) -> String {
        samples.map { String(Int($0)) }.joined(separator: " ")
    }
}

/// **The ASR engine, with streaming in it** — the widget-streaming route's double: a scripted
/// sequence of partial transcripts (`isFinal == false`), then exactly one final transcript, in
/// the shape the seam promises a streaming engine yields (`ASREngine.swift:62-69`).
///
/// It is the opposite half of ``StubEngine``'s claim: the stub proves a conformer without
/// `stream` still satisfies the protocol (the batch default exists), and this one implements
/// `stream` itself so the route has somewhere to run — partials exist only here, never in the
/// batch shape. The script is the test's ground truth: the partials and the final are the
/// strings the tests write their expectations by hand against, never read back from the engine.
///
/// The engine drains the chunks it is fed before yielding anything, so the caller's chunk
/// producer terminates honestly — the shape of the batch default, minus the buffering; the
/// streaming override is free to consume differently, and this double's timing is scripted.
///
/// `error` is the throwing row: the stream finishes with the error **before yielding
/// anything**, so a test can pin that the sink stays untouched on the failure path.
///
/// `gated` is the cancellation row's gate: the stream parks before the final until the test
/// opens it, so the route is *held before the final* and the cancellation lands
/// deterministically — the ``TableEngine`` gate precedent
/// (`DictationPipelineTests.swift:1250-1301`).
actor StreamingStubEngine: ASREngine {
    let identity: EngineIdentity
    /// `true` — this is the streaming half of the story; the batch default is ``StubEngine``'s,
    /// and both shapes must terminate the same way: partials, then exactly one final.
    let supportsStreaming = true

    /// The scripted partials, yielded in order before the final.
    private let partials: [String]
    /// The scripted final transcript's text, yielded after the partials.
    private let finalText: String
    /// When set, the stream finishes with this error before yielding anything.
    private let error: Error?
    /// When `true`, the stream parks before the final until ``openGate()``.
    private let gated: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var transcribeCalls = 0
    private(set) var prepareCount = 0
    /// How many streams are parked at the gate — the cancellation test's synchronisation.
    private(set) var parkedStreams = 0

    init(
        identity: EngineIdentity, partials: [String], finalText: String,
        error: Error? = nil, gated: Bool = false
    ) {
        self.identity = identity
        self.partials = partials
        self.finalText = finalText
        self.error = error
        self.gated = gated
    }

    func prepare() async throws {
        prepareCount += 1
    }

    func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        transcribeCalls += 1
        return Transcript(
            text: finalText, segments: [], engine: identity, isFinal: true,
            audioDuration: buffer.audioDuration)
    }

    /// `nonisolated` because the seam's `stream` is a synchronous requirement (it returns the
    /// stream; the producer task carries the asynchrony): an actor-isolated witness would
    /// cross into actor-isolated code from a nonisolated requirement. The producer hops to the
    /// actor for the scripted body, which is where the mutable state (the gate) lives.
    nonisolated func stream(
        _ chunks: AsyncStream<AudioBuffer>
    ) -> AsyncThrowingStream<Transcript, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.runStream(chunks, continuation: continuation)
            }
            // A consumer that stops early must not leave the scripted task pending: the caller's
            // chunks producer would keep the seam alive past the caller's interest in it (the
            // batch default's shape).
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Resumes the parked stream — the cancellation test's gate, ``TableEngine/openGate()``'s
    /// shape.
    func openGate() {
        gate?.resume()
        gate = nil
    }

    /// The scripted stream body: drain the chunks, yield the partials, park if gated, then
    /// yield the final (or finish with the scripted error). Every stop observes cancellation —
    /// a cancelled stream finishes by throwing ``CancellationError``, so the route's discard
    /// path is exercised honestly rather than by a stream that silently ends.
    private func runStream(
        _ chunks: AsyncStream<AudioBuffer>,
        continuation: AsyncThrowingStream<Transcript, Error>.Continuation
    ) async {
        for await _ in chunks {
            guard !Task.isCancelled else {
                continuation.finish(throwing: CancellationError())
                return
            }
        }
        guard !Task.isCancelled else {
            continuation.finish(throwing: CancellationError())
            return
        }
        if let error {
            continuation.finish(throwing: error)
            return
        }
        for partial in partials {
            guard !Task.isCancelled else {
                continuation.finish(throwing: CancellationError())
                return
            }
            continuation.yield(Transcript(
                text: partial, segments: [], engine: identity, isFinal: false,
                audioDuration: 0))
        }
        if gated {
            // No suspension between the counter and the parked continuation's storage, so a
            // test that observes `parkedStreams == 1` is guaranteed to find the gate set — the
            // ``TableEngine`` synchronisation, by construction.
            parkedStreams += 1
            await withCheckedContinuation { self.gate = $0 }
        }
        guard !Task.isCancelled else {
            continuation.finish(throwing: CancellationError())
            return
        }
        continuation.yield(Transcript(
            text: finalText, segments: [], engine: identity, isFinal: true, audioDuration: 0))
        continuation.finish()
    }
}
