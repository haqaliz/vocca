// Copyright 2026 The Vocca Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import AVFAudio
import Foundation
import Synchronization
import VoccaCore

/// The `SpeechSynthesizer` seam's first real implementation (`system-synthesizer/spec.md` R3):
/// macOS `AVSpeechSynthesizer` rendering PCM buffers instead of playing them.
///
/// ``speak(_:)`` chunks the text with ``SentenceChunker`` and renders **one ``AVSpeechUtterance``
/// per sentence chunk** through `write(_:toBufferCallback:)`. Each utterance's buffers are
/// aggregated into **one ``AudioChunk`` per sentence** — the seam's "chunks arrive as sentences
/// complete" shape — with rate/channels from the buffer's format and duration = frames ÷ rate,
/// bridged into an `AsyncThrowingStream<AudioChunk, Error>`. `cancel()` terminates the stream
/// promptly (≤50 ms), drops the in-flight utterance's partial, and cancel-then-re-invoke is safe
/// — the barge-in contract (`CAPABILITY_ROADMAP.md:248`).
///
/// Voice and rate are **plain data inputs** (N1 — the knobs the follow-on UI turns): the
/// initializer takes a system voice identifier and a rate, and ``identity`` is
/// `engineID: "system"` with the configured identifier as its voice name. Zero network by
/// construction — this file renders, it never plays audio and never dials out.
///
/// ## Why `@unchecked Sendable`
///
/// The seam is `Sendable` and `AVSpeechSynthesizer` is not, so the adapter is the boundary that
/// declares the conformance. The warrant is the same as `AudioRingBuffer`'s: every byte of
/// mutable state — the cancelled flag, the renderer's busy generation, the parked waits — lives
/// under one `Mutex`, and the `AVSpeechSynthesizer` instance never leaves this class. The write
/// callback is synchronous and fires on the renderer's internal queue, which is exactly why the
/// check-and-yield is atomic under the lock: once `cancel()` has run, no further chunk can be
/// yielded.
///
/// ## The write-callback bridge, and what the first real run measured
///
/// `write(_:toBufferCallback:)` delivers the utterance's PCM in ~256-frame buffers at 22050 Hz
/// mono and signals completion with a **zero-length buffer**. Two behaviours of the renderer were
/// measured on real hardware (2026-09-13, the first env-gated run) and shaped this design:
///
/// - **The renderer runs far ahead of the consumer** — it rendered an ~8 s utterance in ~0.36 s
///   wall — so per-buffer delivery lets the producer over-fill the stream, and a chunk read after
///   `cancel()` is an artifact of buffering, not of a barge-in leaking. Aggregating per sentence
///   (the seam's own granularity — "chunks arrive as sentences complete") paces the stream at
///   sentence boundaries, where the cancel lands deterministically between two.
/// - **`stopSpeaking(at: .immediate)` breaks the next `write`** — the re-invoked utterance
///   rendered nothing after it. `cancel()` therefore never calls it: the in-flight write is left
///   to drain in the background, its buffers dropped as stale, and the next session's write is
///   queued until the renderer's completion signal actually arrives. `cancel()` terminates the
///   stream without waiting on the renderer; the renderer's completion is what releases the queue.
///
/// ## The queue
///
/// The renderer accepts one write at a time, so writes are serialized by generation: a write is
/// issued only when the renderer is idle, and the completion callback (tagged with the write's
/// generation) is the only thing that makes it idle again. A stale callback — from a write the
/// cancel already released — matches no generation and delivers nothing. Cancellation resumes the
/// session's wait without touching the queue, so the queue survives a cancel and the re-invoked
/// session renders fully once the drain completes.
public final class SystemSynthesizer: SpeechSynthesizer, @unchecked Sendable {

    /// The system speech engine's stable key — the `engineID` every chunk this synthesizer
    /// produces is attributable to.
    public static let engineID = "system"

    /// Which synthesizer this is: the system engine, with the configured voice's identifier as
    /// the voice name.
    public let identity: VoiceIdentity

    /// The configured system voice; `nil` lets the renderer pick its default.
    private let voice: AVSpeechSynthesisVoice?

    /// The configured speaking rate — plain data, the N1 knob.
    private let rate: Float

    /// The renderer. Touched only through `write`, never exposed.
    private let synthesizer: AVSpeechSynthesizer

    /// All mutable state, under one lock — the `Mutex` the rest of the package uses at the
    /// `@unchecked Sendable` boundaries.
    private let lock = Mutex<SystemSynthesizerState>(SystemSynthesizerState())

    public init(voiceIdentifier: String?, rate: Float = AVSpeechUtteranceDefaultSpeechRate) {
        self.identity = VoiceIdentity(engineID: Self.engineID, voiceName: voiceIdentifier)
        self.voice = voiceIdentifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
        self.rate = rate
        self.synthesizer = AVSpeechSynthesizer()
    }

    /// Renders `text` into a stream of PCM chunks: one chunk per sentence, in rendering order,
    /// `speak("")` an empty stream that never throws.
    public func speak(_ text: String) -> AsyncThrowingStream<AudioChunk, Error> {
        let sentences = Self.utteranceTexts(for: text)
        return AsyncThrowingStream { continuation in
            let task = Task {
                await self.render(sentences, into: continuation)
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    /// Halts any in-flight ``speak(_:)``: sets the flag and resumes the session's waits, so the
    /// stream terminates promptly. The renderer's in-flight write is left to drain — its buffers
    /// are dropped as stale, and the re-invoked session's write is queued behind its completion
    /// (measured: `stopSpeaking` here would break the next write entirely).
    public func cancel() async {
        let (owedCompletion, owedAcquirers) = lock.withLock { state -> (CheckedContinuation<Bool, Never>?, [CheckedContinuation<Int?, Never>]) in
            state.isCancelled = true
            let owed = state.pendingCompletion.map {
                state.pendingCompletion = nil
                return $0.completion
            }
            let acquirers = state.acquireWaiters
            state.acquireWaiters = []
            return (owed, acquirers)
        }
        owedCompletion?.resume(returning: false)
        for acquirer in owedAcquirers {
            acquirer.resume(returning: nil)
        }
    }

    // MARK: - The pure half

    /// The chunker's sentences, as the utterance list — one utterance per sentence chunk.
    static func utteranceTexts(for text: String) -> [String] {
        SentenceChunker.sentenceChunks(of: text)
    }

    /// Builds the utterance carrying `text` with the configured voice and rate as plain data.
    func makeUtterance(for text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        return utterance
    }

    // MARK: - The write-callback bridge

    /// Converts a rendered buffer into the seam's chunk shape: duration = frames ÷ rate,
    /// payload = the buffer's frame data. A zero-length buffer — the write callback's
    /// end-of-utterance signal — is dropped, never a chunk.
    ///
    /// The converter reads the interleaved single-buffer shape the system renderer delivers:
    /// one audio buffer holding every frame's every channel, byte length = frames ×
    /// bytes-per-frame. A buffer outside that shape converts to nothing.
    static func audioChunk(from buffer: AVAudioPCMBuffer) -> AudioChunk? {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }
        let bufferList = buffer.audioBufferList.pointee
        guard bufferList.mNumberBuffers == 1 else { return nil }
        guard
            let data = bufferList.mBuffers.mData,
            buffer.format.streamDescription.pointee.mBytesPerFrame > 0
        else { return nil }

        let byteCount = frameCount * Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        var bytes = [UInt8](repeating: 0, count: byteCount)
        bytes.withUnsafeMutableBytes { $0.baseAddress?.copyMemory(from: data, byteCount: byteCount) }

        let sampleRate = buffer.format.sampleRate
        return AudioChunk(
            bytes: bytes,
            sampleRate: sampleRate,
            channelCount: Int(buffer.format.channelCount),
            duration: Double(frameCount) / sampleRate)
    }

    /// Renders the sentence list into `continuation`, one write at a time, terminating the
    /// stream when done — or at the cancel.
    private func render(
        _ sentences: [String], into continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) async {
        lock.withLock { $0.isCancelled = false }

        for sentence in sentences {
            if Task.isCancelled || lock.withLock({ $0.isCancelled }) { break }
            let utterance = makeUtterance(for: sentence)
            guard await renderOne(utterance, into: continuation) else { break }
        }
        continuation.finish()
    }

    /// Renders one utterance, yielding its sentence as a single aggregated chunk. Returns
    /// `false` when the cancel landed mid-write — the stream's caller then stops.
    private func renderOne(
        _ utterance: AVSpeechUtterance,
        into continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) async -> Bool {
        guard let generation = await acquireRenderer() else { return false }

        let accumulator = WriteAccumulator()
        return await withCheckedContinuation { (completion: CheckedContinuation<Bool, Never>) in
            lock.withLock { state in
                state.pendingCompletion = PendingWrite(
                    generation: generation, completion: completion)
            }

            synthesizer.write(utterance) { [self] buffer in
                // The renderer delivers PCM buffers; a non-PCM delivery is outside the contract
                // and is dropped without disturbing the completion accounting.
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }
                handleWriteCallback(
                    pcmBuffer, generation: generation, accumulator: accumulator,
                    into: continuation)
            }
        }
    }

    /// Waits for the renderer to be idle, and claims it for one write. Returns the write's
    /// generation, or `nil` when the cancel landed while waiting.
    private func acquireRenderer() async -> Int? {
        await withCheckedContinuation { (acquirer: CheckedContinuation<Int?, Never>) in
            lock.withLock { state in
                guard !state.isCancelled else {
                    acquirer.resume(returning: nil)
                    return
                }
                if state.inFlight != nil {
                    state.acquireWaiters.append(acquirer)
                } else {
                    let generation = state.nextGeneration
                    state.nextGeneration += 1
                    state.inFlight = generation
                    acquirer.resume(returning: generation)
                }
            }
        }
    }

    /// The `write(toBufferCallback:)` bridge: frames in, one sentence-chunk out at completion,
    /// completion accounted.
    ///
    /// Runs on the renderer's internal queue. The check-and-yield is atomic under the lock, so
    /// once `cancel()` has run, no further chunk is yielded into the stream — a barge-in never
    /// leaks the tail of the utterance. A callback whose generation is no longer in flight is a
    /// stale delivery from a cancelled write and delivers nothing.
    private func handleWriteCallback(
        _ buffer: AVAudioPCMBuffer,
        generation: Int,
        accumulator: WriteAccumulator,
        into continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) {
        lock.withLock { state in
            guard state.inFlight == generation else { return }

            if buffer.frameLength == 0 {
                // The write completed: the renderer is idle again, the sentence chunk (if any
                // frames accumulated and the session still awaits this write) is yielded, and the
                // next waiting session is granted the renderer.
                state.inFlight = nil
                if let pending = state.pendingCompletion, pending.generation == generation {
                    state.pendingCompletion = nil
                    if !state.isCancelled, let chunk = accumulator.chunk() {
                        _ = continuation.yield(chunk)
                    }
                    pending.completion.resume(returning: true)
                }
                grantRendererIfIdle(in: &state)
                return
            }

            guard !state.isCancelled else { return }
            accumulator.append(buffer)
        }
    }

    /// Hands the now-idle renderer to the oldest waiting session, if any.
    private func grantRendererIfIdle(in state: inout SystemSynthesizerState) {
        guard state.inFlight == nil, !state.acquireWaiters.isEmpty, !state.isCancelled else {
            return
        }
        let acquirer = state.acquireWaiters.removeFirst()
        let generation = state.nextGeneration
        state.nextGeneration += 1
        state.inFlight = generation
        acquirer.resume(returning: generation)
    }
}

/// The synthesizer's mutable state, guarded by ``SystemSynthesizer/lock``.
///
/// ``isCancelled`` is raised by `cancel()` and lowered by a re-invoked `speak`, so the second
/// session starts fresh. ``inFlight`` is the generation of the write currently on the renderer
/// — the completion callback is the only thing that clears it, which is what serializes writes.
/// ``pendingCompletion`` is the session awaiting its write's completion (resumed exactly once),
/// and ``acquireWaiters`` are sessions parked until the renderer is idle.
private struct SystemSynthesizerState {
    var isCancelled = false
    var nextGeneration = 0
    var inFlight: Int?
    var pendingCompletion: PendingWrite?
    var acquireWaiters: [CheckedContinuation<Int?, Never>] = []
}

/// The session awaiting one write's completion.
private struct PendingWrite {
    let generation: Int
    let completion: CheckedContinuation<Bool, Never>
}

/// The per-utterance accumulator: the write's PCM frames, aggregated into the sentence's one
/// chunk. Written only from the renderer's callback queue, so no lock of its own is needed.
private final class WriteAccumulator {
    private var bytes: [UInt8] = []
    private var frameCount = 0
    private var format: AVAudioFormat?

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let piece = SystemSynthesizer.audioChunk(from: buffer) else { return }
        bytes.append(contentsOf: piece.bytes)
        frameCount += Int(buffer.frameLength)
        format = buffer.format
    }

    func chunk() -> AudioChunk? {
        guard frameCount > 0, let format else { return nil }
        return AudioChunk(
            bytes: bytes,
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount),
            duration: Double(frameCount) / format.sampleRate)
    }
}