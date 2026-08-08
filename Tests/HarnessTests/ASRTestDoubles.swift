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

    init(identity: EngineIdentity) {
        self.identity = identity
    }

    func prepare() async throws {
        prepareCount += 1
    }

    func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        Transcript(
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
