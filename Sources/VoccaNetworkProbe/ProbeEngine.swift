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

// The probe's half of the zero-network invariant for `VoccaASR`.
//
// While `VoccaASR` held a placeholder, naming `VoccaASRPlaceholder` in the probe's module list was
// all the invariant could say about it. The module now holds the real engines (Parakeet,
// whisper.cpp), the model lifecycle (store, downloader, transport, manifest loader) and the
// download window's session seam — none of which a hosted runner can execute with model bytes,
// which is why the env-gated WER suites are the real-model execution path and this probe is not.
//
// So the probe drives what of the module CAN run headless (the shipped manifest loader, in
// `DictationCycleDrive`), and substitutes this stub engine everywhere the composition would
// construct a real one. The substitution is what makes "the probe must never trigger a real model
// download" a structural fact rather than a discipline: no code path in the probe's composition
// can ever build a `ParakeetEngine` or a `WhisperCppEngine`, because the builder slot is this
// object's.

/// **The ASR engine, with the model taken out** — the probe's stand-in for the two shipped
/// engines, in the `StubEngine` shape (`ASRTestDoubles.swift:48-97`).
///
/// Deliberately **not** streaming: it implements `identity`, `supportsStreaming` (false),
/// `prepare()` and `transcribe(_:)` and no `stream`, so it measures the batch default exactly as
/// the seam's own double does. It is an **actor**, not a class: `ASREngine` is a `Sendable`
/// protocol, and the double must cross actor boundaries honestly — the same boundary doctrine
/// `ASRTestDoubles.swift:36-38` records for the suite's stub.
///
/// ## The transcription is a pure function of the samples — and the completeness link is echoed
///
/// `transcribe` turns the buffer into `"1 2 3"` — the sample values joined with spaces, the
/// `StubEngine` transcription — and **carries the buffer's `missingSampleCount` onto the
/// ``Transcript``**, which is the completeness link's own documented journey
/// (`AudioBuffer.swift:50-57`: "the engine carries it onto the Transcript"). The stub has no
/// model, so it is the caller's ground truth; the cycle drive's report reads the echoed count
/// back, which is how the probe witnesses that the capture ring's refusal count travelled
/// session → hand-over → engine without masquerading as complete.
actor ProbeEngine: ASREngine {

    /// A deterministic identity, distinct from both shipped engines' — the report's
    /// `engine=` field is this id, so a composition that quietly built the real engine would be
    /// caught by the identity alone (the real id would be `parakeet-tdt-0.6b-v3`).
    let identity = EngineIdentity(
        id: "probe-stub-engine", displayName: "Probe stub engine", isLocal: true)

    /// `false`, like the suite's stub: the probe measures the batch default, not a stream this
    /// stub implemented itself.
    let supportsStreaming = false

    /// How many times `prepare()` was called — the ledger half of the prepare-policy contract.
    /// The cycle drive asserts this is exactly one (resolve-once, warmed once), so a composition
    /// that re-prepared — or never prepared — is caught by the count.
    private(set) var prepareCount = 0

    /// How many times `transcribe(_:)` was called — the ledger half of the pipeline contract: the
    /// drive's report reads this, so a pipeline that skipped transcription is caught by the count.
    private(set) var transcribeCalls = 0

    init() {}

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
            audioDuration: buffer.audioDuration,
            missingSampleCount: buffer.missingSampleCount)
    }

    /// The deterministic transcription: `[1, 2, 3]` becomes `"1 2 3"`. An empty buffer becomes `""`.
    private static func text(for samples: [Float]) -> String {
        samples.map { String(Int($0)) }.joined(separator: " ")
    }
}
