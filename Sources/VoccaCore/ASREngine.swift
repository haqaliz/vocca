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

/// The pluggable speech-to-text boundary (`ARCHITECTURE.md:219-229`).
///
/// Every ASR adapter is this protocol and nothing else: FluidAudio's Parakeet at C2, whisper.cpp
/// at C3, a hosted provider behind the same seam later (`ARCHITECTURE.md:208` — "the seam the
/// hosted tier slots into"). The input is ``AudioBuffer``, the one format the seam speaks
/// (16 kHz mono, `ARCHITECTURE.md:129-135`), and the output is a ``Transcript`` that must name the
/// engine that produced it — ``Transcript/engine`` is non-optional, so mis-attribution is
/// structurally impossible and the C2 acceptance's identity clause is satisfied by construction.
///
/// ## The seam's contract
///
/// - **The engine is never nil on a transcript.** Attribution is invariant I1; every transcript a
///   conformer returns must carry ``identity``, which is *this* engine's identity.
/// - **A buffer too short to transcribe is a legitimate answer, empty or not.**
///   `transcribe(AudioBuffer(samples: [], ...))` must return a valid empty `Transcript`
///   (`text == ""`, actual `audioDuration`), never throw — a 20 ms press captures almost nothing,
///   and silence is a transcript, not an error (PRD M3). **The same holds for any buffer below
///   whatever minimum the conformer needs**, and that half is load-bearing rather than pedantic:
///   a 20 ms press is 320 samples, *not zero*, so an engine honouring only the literal empty case
///   fails the very example this contract is written around. Parakeet did exactly that —
///   FluidAudio's guard throws below 0.3 s, and the throw reached the user as
///   `.transcriptionFailed`, "Voice processing failed", for a quick tap of the hotkey. A conformer
///   whose backend refuses short audio must answer empty above it, as `ParakeetEngine` now does.
/// - **Engines own the prepare policy.** ``prepare()`` is the warm-start hook; a conformer may
///   require it before ``transcribe(_:)``, or load lazily, or not at all. The seam does not call
///   ``prepare()`` on a caller's behalf — it cannot know when a caller wanted the warm-start cost
///   paid — and it does not enforce the policy. `parakeet-engine` decides the real one.
/// - **Callers never branch on ``supportsStreaming``.** Streaming engines yield partials then
///   exactly one final transcript; batch engines get ``stream(_:)``'s default implementation,
///   which yields one final transcript. Both shapes terminate the same way, so the pipeline is
///   written once (`ARCHITECTURE.md:226-228`).
public protocol ASREngine: Sendable {
    /// Which engine this is: the key the model store's directory is named after and the
    /// attribution every ``Transcript`` carries (`ARCHITECTURE.md:152-156`).
    var identity: EngineIdentity { get }

    /// Whether the engine can yield partial transcripts while audio is still arriving. `false` at
    /// C2 — streaming is C7's capability, and ``stream(_:)``'s default covers every batch engine
    /// in the meantime.
    var supportsStreaming: Bool { get }

    /// The warm-start hook: load the model, ready the engine for transcription.
    ///
    /// The engine owns the policy — whether a conformer requires this before
    /// ``transcribe(_:)``, loads lazily instead, or has nothing to warm up, is the conformer's
    /// decision (`ARCHITECTURE.md:223`). The seam only documents it.
    func prepare() async throws

    /// Transcribes one buffer of 16 kHz mono audio.
    ///
    /// Must return a ``Transcript`` whose ``Transcript/engine`` is ``identity``, and must treat an
    /// empty buffer as a valid empty transcript rather than an error.
    func transcribe(_ buffer: AudioBuffer) async throws -> Transcript

    /// Streaming transcription: partial transcripts as audio arrives, then exactly one
    /// ``Transcript/isFinal`` transcript (`ARCHITECTURE.md:226-228`).
    ///
    /// The default implementation in the extension is the documented batch behaviour: buffer every
    /// chunk into one ``AudioBuffer``, transcribe it once, yield exactly one final ``Transcript``
    /// and finish. A streaming engine (C7) overrides this; **callers never branch on
    /// ``supportsStreaming``.**
    func stream(_ chunks: AsyncStream<AudioBuffer>) -> AsyncThrowingStream<Transcript, Error>
}

extension ASREngine {
    /// The documented batch default (`ARCHITECTURE.md:226-228`): buffer all chunks into one
    /// ``AudioBuffer``, transcribe it once, and yield exactly one final ``Transcript``.
    ///
    /// This is consumer-side — it buffers as it must and allocates as it pleases; realtime
    /// constraints belong to the streaming override, not to this default. It is also the
    /// empty-buffer policy in its stream form: a stream of no chunks transcribes an empty buffer,
    /// which is a valid empty transcript, never an error.
    public func stream(
        _ chunks: AsyncStream<AudioBuffer>
    ) -> AsyncThrowingStream<Transcript, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var samples: [Float] = []
                for await chunk in chunks {
                    guard !Task.isCancelled else { break }
                    samples.append(contentsOf: chunk.samples)
                }
                do {
                    let transcript = try await transcribe(
                        AudioBuffer(samples: samples, sampleRate: AudioBuffer.interchangeSampleRate))
                    continuation.yield(transcript)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // A consumer that stops early must not leave the buffering task pending: the caller's
            // chunks producer would keep the seam alive past the caller's interest in it.
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
