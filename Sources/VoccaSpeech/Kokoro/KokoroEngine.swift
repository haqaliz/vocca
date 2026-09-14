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
import KokoroCoreML
import Synchronization
import VoccaCore

/// The errors a ``KokoroEngine`` stream can throw — the recorded, mapped surface the seam's
/// consumers match on (`kokoro-binding`/`engine-binding` spec acceptance 1).
///
/// The port's own error is never leaked raw: ``modelsUnavailable(_:)`` is the mapped identity for
/// the port's absent-models throw (carrying the directory the models were absent from), and
/// ``portFailure(_:)`` wraps anything else the port throws mid-synthesis — propagated, never
/// swallowed.
public enum KokoroEngineError: Error, Sendable {
    /// The model directory held no models — the recorded absent-models identity.
    case modelsUnavailable(URL)
    /// Any other port error, propagated as-is rather than swallowed.
    case portFailure(any Error)
}

/// The `SpeechSynthesizer` seam's second real implementation (`kokoro-binding`/`engine-binding`
/// spec): Kokoro-82M through the `KokoroCoreML` port, rendering PCM instead of playing it.
///
/// ``speak(_:)`` chunks the text with ``SentenceChunker`` and calls the port's **synchronous**
/// `synthesize(text:voice:speed:)` once per sentence chunk, converting the port's
/// `[Float]` samples (24 kHz mono) into one ``AudioChunk`` per sentence — the seam's
/// "chunks arrive as sentences complete" shape, bridged into an
/// `AsyncThrowingStream<AudioChunk, Error>`. `cancel()` terminates the stream promptly (≤50 ms),
/// drops the in-flight call's orphaned result, and cancel-then-re-invoke is safe — the barge-in
/// contract (`CAPABILITY_ROADMAP.md:248`).
///
/// Voice and rate are **plain data inputs** (the N1 knobs the follow-on UI turns), and
/// ``identity`` is `engineID: "kokoro-82m"` with the configured voice as its voice name.
///
/// ## Why `@unchecked Sendable`
///
/// The seam is `Sendable` and the port engine is not, so the adapter is the boundary that
/// declares the conformance — the SystemSynthesizer warrant shape: every byte of mutable state
/// — the cancelled flag, the stream generation, the parked in-flight continuation, the lazily
/// constructed port engine and its memoized failure — lives under one `Mutex`, and the port
/// engine never leaves this class.
///
/// ## The lazy construction, and why the init is pure
///
/// The port's init does model-loading work: it checks the model directory, loads the tokenizer
/// and voice store, and spawns a background warmup thread. That is a prepare fact — never
/// construction cost — so ``init(modelDirectory:voice:rate:)`` stores plain data only and the
/// port engine is constructed lazily on the first **non-empty** speak (outside the lock,
/// memoized along with any thrown error: a failed construction fails every subsequent speak
/// with the same recorded error). `speak("")` short-circuits before any port touch.
///
/// ## The cancel design
///
/// The port's `synthesize` is synchronous (~100 ms per sentence) and has no stop API this
/// adapter will call. `cancel()` therefore terminates the stream **from the cancel itself**: it
/// finishes the in-flight stream's continuation immediately — the consumer's `next()` returns
/// nil fast, inside the ≤50 ms contract, without waiting for the in-flight call — and bumps the
/// generation. The orphaned render result is dropped by the generation check and never yielded;
/// the re-invoked session resets the flag at registration and reuses the memoized port engine.
public final class KokoroEngine: SpeechSynthesizer, @unchecked Sendable {

    /// The Kokoro engine's stable key — the `engineID` every chunk this synthesizer produces is
    /// attributable to, and the seam's own vocabulary for this engine.
    public static let engineID = "kokoro-82m"

    /// Which synthesizer this is: the Kokoro engine, with the configured voice as its voice name.
    public let identity: VoiceIdentity

    /// The model directory — plain data, resolved at first non-empty speak.
    private let modelDirectory: URL

    /// The configured voice — plain data, the N1 knob.
    private let voice: String

    /// The configured speaking rate, `nil` for the port's default — plain data, the N1 knob.
    private let rate: Float?

    /// All mutable state, under one lock — the `Mutex` the rest of the package uses at the
    /// `@unchecked Sendable` boundaries.
    private let lock = Mutex<KokoroEngineState>(KokoroEngineState())

    public init(modelDirectory: URL, voice: String, rate: Float? = nil) {
        self.modelDirectory = modelDirectory
        self.voice = voice
        self.rate = rate
        self.identity = VoiceIdentity(engineID: Self.engineID, voiceName: voice)
    }

    /// Renders `text` into a stream of PCM chunks: one chunk per sentence, in rendering order,
    /// `speak("")` an empty stream that never throws — and never touches the port.
    public func speak(_ text: String) -> AsyncThrowingStream<AudioChunk, Error> {
        let sentences = SentenceChunker.sentenceChunks(of: text)
        guard !sentences.isEmpty else {
            return AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                await self.render(sentences, into: continuation)
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    /// Halts any in-flight ``speak(_:)``: flags the cancel, bumps the generation, and finishes
    /// the in-flight stream's continuation **immediately** — the ≤50 ms contract must not wait
    /// for the ~100 ms synchronous port call still running. The orphaned result is dropped by
    /// generation and never yielded; the port's own stop API is never called.
    public func cancel() async {
        let owed = lock.withLock { state -> AsyncThrowingStream<AudioChunk, Error>.Continuation? in
            state.isCancelled = true
            state.generation += 1
            let owed = state.inFlightContinuation
            state.inFlightContinuation = nil
            return owed
        }
        owed?.finish()
    }

    // MARK: - The pure half

    /// Converts the port's Float32 samples into the seam's chunk shape: one little-endian
    /// `bitPattern` per sample, 24 kHz mono, duration = count ÷ 24000. An empty sample array —
    /// which would be a zero-duration chunk — converts to nothing.
    static func audioChunk(fromSamples samples: [Float]) -> AudioChunk? {
        guard !samples.isEmpty else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(samples.count * 4)
        for sample in samples {
            let bits = sample.bitPattern.littleEndian
            bytes.append(UInt8(truncatingIfNeeded: bits >> 0))
            bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
            bytes.append(UInt8(truncatingIfNeeded: bits >> 16))
            bytes.append(UInt8(truncatingIfNeeded: bits >> 24))
        }
        return AudioChunk(
            bytes: bytes,
            sampleRate: 24_000,
            channelCount: 1,
            duration: Double(samples.count) / 24_000)
    }

    // MARK: - The port bridge

    /// The port engine, constructed lazily on first use and memoized — along with any thrown
    /// error, so a failed construction fails every subsequent speak with the same recorded error.
    ///
    /// Construction happens **outside the lock** (it is a model load); the memoization is under
    /// it. The first constructed engine wins; a later concurrent construction is discarded.
    private func portEngine() throws -> KokoroCoreML.KokoroEngine {
        if let engine = lock.withLock({ $0.portEngine }) { return engine }
        if let failure = lock.withLock({ $0.portFailure }) { throw failure }

        do {
            let engine = try KokoroCoreML.KokoroEngine(modelDirectory: modelDirectory)
            lock.withLock { state in
                if state.portEngine == nil {
                    state.portEngine = engine
                }
            }
            return engine
        } catch {
            let failure = Self.mapError(error)
            lock.withLock { state in
                if state.portFailure == nil {
                    state.portFailure = failure
                }
            }
            throw failure
        }
    }

    /// Maps the port's thrown error onto the recorded surface: the port's absent-models case
    /// becomes ``KokoroEngineError/modelsUnavailable(_:)`` carrying the directory, everything
    /// else is wrapped, never swallowed — and an already-mapped error passes through unchanged.
    private static func mapError(_ error: Error) -> KokoroEngineError {
        if let mapped = error as? KokoroEngineError { return mapped }
        if let kokoroError = error as? KokoroError,
            case .modelsNotAvailable(let directory) = kokoroError
        {
            return .modelsUnavailable(directory)
        }
        return .portFailure(error)
    }

    /// Renders the sentence list into `continuation`, one synchronous port call per sentence,
    /// terminating the stream when done — or at the cancel, or at the first thrown error.
    private func render(
        _ sentences: [String], into continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) async {
        let generation = lock.withLock { state -> Int in
            state.isCancelled = false
            state.inFlightContinuation = continuation
            return state.generation
        }

        for sentence in sentences {
            if Task.isCancelled || lock.withLock({ $0.isCancelled || $0.generation != generation }) {
                break
            }
            do {
                let port = try portEngine()
                let result = try port.synthesize(text: sentence, voice: voice, speed: rate ?? 1.0)
                guard !Task.isCancelled else { break }
                guard let chunk = Self.audioChunk(fromSamples: result.samples) else { continue }
                let isCurrent = lock.withLock { state -> Bool in
                    !state.isCancelled && state.generation == generation
                }
                guard isCurrent else { break }
                _ = continuation.yield(chunk)
            } catch {
                continuation.finish(throwing: Self.mapError(error))
                return
            }
        }
        continuation.finish()
    }
}

/// The synthesizer's mutable state, guarded by ``KokoroEngine/lock``.
///
/// ``isCancelled`` is raised by `cancel()` and lowered by a re-invoked `speak`, so the second
/// session starts fresh. ``generation`` is bumped by every cancel — an orphaned render whose
/// generation no longer matches delivers nothing. ``inFlightContinuation`` is the current
/// session's stream, finished directly by the cancel. ``portEngine`` is the lazily constructed
/// port engine (constructed outside the lock, memoized under it) and ``portFailure`` the
/// memoized construction failure that fails every subsequent speak with the same error.
private struct KokoroEngineState {
    var isCancelled = false
    var generation = 0
    var inFlightContinuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?
    var portEngine: KokoroCoreML.KokoroEngine?
    var portFailure: KokoroEngineError?
}