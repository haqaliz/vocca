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

import AVFAudio
import Foundation
import Synchronization
import VoccaCore

/// The `PlaybackEngine` seam's first real implementation (`playback-ducking`, C10's P3 voice
/// loop; `ARCHITECTURE.md:107` reserves this directory for it): a `Mutex` state machine over
/// the injected ``MonotonicClock`` and the injected ``PlaybackOutputSeam``, with the real
/// `AVAudioEngine`/`AVAudioSourceNode`/`AudioRingBuffer` output behind the seam — **the first
/// file in `Sources/VoccaAudio/Playback/`, and the one file in it that may name the AVFAudio
/// family** (the `PlaybackSeamBoundaryTests` lint).
///
/// ## The honest CI statement (the `AudioCaptureGraph`/tap-adapter precedent)
///
/// The **realtime device path is executed by nothing in CI**: no hosted runner has audio
/// hardware, the engine's device-rate conversion is `AVAudioEngine`'s own, and the render
/// block's audible result (duck, halt, click-freedom) is SMOKE 132's first real execution
/// (`barge-in-loop`), never a CI number. What CI **does** execute of this adapter: the whole
/// duck/halt **state machine** over the injected clock and a ledger double (the
/// `PlaybackEngineSeamTests` suite — the headless proof), and — when the environment allows —
/// the real adapter headlessly through **manual-rendering mode** (`renderOffline`), where the
/// source node's render block is documented to run on the non-realtime thread
/// (`PlaybackOfflineRenderTests`).
///
/// ## Why `@unchecked Sendable`
///
/// The `SystemSynthesizer` warrant, stated for this type: every mutable byte — the session
/// generation, the cancelled flag, the parked halt ramp, the duck target, the level — lives
/// under the one `Mutex`; the output seam is internally thread-safe (atomics plus the SPSC
/// ring); and no AVFoundation object escapes this file. The output's `enqueue` may wait a
/// bounded poll for ring room (playback never drops a frame — it waits rather than overrunning);
/// the halt therefore rides on that bound in the pathological device-mode case where a cancel
/// lands exactly on a full ring: the ramp parks and the stop is delayed by at most the
/// room-wait's remainder (typically one 1 ms tick — the renderer drains in realtime — bounded
/// by the 3 s ceiling). The offline tests never overlap a room-wait with a halt; the composed
/// 200 ms barge-in budget is `barge-in-loop`'s acceptance over the shipped ramp.
///
/// ## The state machine's timing contract
///
/// `cancelToSilence()` halts to silence at `rampDuration + stop`, never a cut and never a hang:
/// it parks a ``LevelRamp`` from the current level to 0 at the cancel's clock reading,
/// `setGain(0)` (the output ramps its frame-quantized envelope — the same linear shape
/// ``LevelRamp`` computes on the clock axis — while the state machine waits), polls the injected
/// clock at a 1 ms tick until `elapsed ≥ rampDuration` (ceiling 1000 iterations, so a frozen
/// clock cannot hang the barge-in), then stops. The play task polls `isDrained` at the same
/// tick and returns only after the halt's stop — `play` returns after the tail has gone silent.
/// The `<=50 ms` `SpeechSynthesizer.cancel()` contract is consumed, not re-litigated.
public final class SystemPlayback: PlaybackEngine, @unchecked Sendable {

    /// All mutable state, under one lock.
    ///
    /// ``generation`` is the session counter: every `play` bumps it, so a superseded session
    /// (a second `play` while one is active) sees its generation leave the building and stops
    /// — the mechanism that makes cancel-then-replay and the rapid hammer safe, and that keeps
    /// a cancelled session's tail from ever resuming. ``isActive`` is the "a session is in
    /// flight" predicate the no-op guards read. ``cancelled`` is the halt flag the play task
    /// polls (the `SystemSynthesizer` flag discipline). ``halted`` is the halt's completion —
    /// the play task's wait-for-halt reads it, so `play` returns after the stop, never before.
    /// ``currentGain`` is the last target told to the output (1 → 0.5 after a duck → 0 at the
    /// halt); ``duckTarget`` is the recorded N2 knob value. ``ramp``/``rampStartedAt`` are the
    /// parked halt ramp, shared by every halter so a racing cancel and stream-error halt stop
    /// exactly once. ``sessionRate``/``sessionChannels``/``formatLocked`` fix the session format
    /// by the first chunk (a differing chunk is a stream failure).
    private struct State {
        var generation = 0
        var isActive = false
        var cancelled = false
        var halted = false
        var currentGain: Float = 1
        var duckTarget: Float = 1
        var isDucking = false
        var ramp: LevelRamp?
        var rampStartedAt: Duration = .zero
        var sessionRate: Double = 0
        var sessionChannels = 0
        var formatLocked = false
    }

    /// The N2 duck knob — plain data, the level and ramp the halt and duck share.
    private let level: PlaybackLevel

    /// The only way time enters the state machine (the ``MonotonicClock`` contract).
    private let clock: any MonotonicClock

    /// The output, behind the seam — the injected double in tests, the real
    /// ``SystemPlaybackOutput`` at the composition root.
    private let output: any PlaybackOutputSeam

    private let lock = Mutex<State>(State())

    /// Builds the real output (device mode) behind the seam.
    ///
    /// - Parameters:
    ///   - level: the duck knob; traps on an invalid level — loud by construction, the
    ///     ``AudioBuffer`` precedent, and ``PlaybackLevel/isValid`` is the tested predicate.
    ///   - clock: the injected clock; production passes a real one from the composition root
    ///     (the `SessionMachine` precedent).
    public init(level: PlaybackLevel = .default, clock: any MonotonicClock) {
        precondition(level.isValid, "a PlaybackLevel that cannot describe a gain is a programming error: \(level)")
        self.level = level
        self.clock = clock
        self.output = SystemPlaybackOutput(level: level)
    }

    /// The tests' route: the state machine over an injected output seam.
    public init(level: PlaybackLevel = .default, clock: any MonotonicClock, output: any PlaybackOutputSeam) {
        precondition(level.isValid, "a PlaybackLevel that cannot describe a gain is a programming error: \(level)")
        self.level = level
        self.clock = clock
        self.output = output
    }

    deinit {
        // Non-asserting — the `AudioCaptureGraph` precedent: the last release may land anywhere,
        // and `tearDown()` asserts no isolation domain (`DeinitIsolationTests`).
        tearDown()
    }

    /// Plays `stream` to the output, returning after every chunk has been rendered to silence.
    ///
    /// The session format is fixed by the first chunk: the output starts at its rate/channels,
    /// and a chunk that differs afterwards is a stream failure — the halt path runs, then
    /// ``PlaybackError/chunkFormatChanged`` is thrown. Every chunk is decoded (Float32
    /// interleaved) and downmixed to mono by arithmetic mean, then **check-and-enqueued
    /// atomically under the lock** — no frame after a cancel, the `SystemSynthesizer`
    /// check-and-yield discipline. When the stream ends, `play` polls ``PlaybackOutputSeam/isDrained``
    /// until the output has rendered everything, then stops it and returns; a halt (``cancelToSilence()``,
    /// a stream error, or a superseding `play`) ends the session instead — the halt owns the
    /// stop, and `play` returns only after it.
    public func play(_ stream: AsyncThrowingStream<AudioChunk, Error>) async throws {
        let generation = beginSession()

        do {
            for try await chunk in stream {
                let sessionState = lock.withLock { state -> SessionState in
                    guard state.generation == generation else { return .superseded }
                    if !state.formatLocked { return .unstarted }
                    if state.sessionRate != chunk.sampleRate
                        || state.sessionChannels != chunk.channelCount
                    {
                        return .formatChanged
                    }
                    return .ready
                }
                switch sessionState {
                case .superseded:
                    break
                case .formatChanged:
                    await haltSession()
                    throw PlaybackError.chunkFormatChanged
                case .unstarted:
                    // The first chunk: start the output at the session format. A refusal
                    // propagates unwrapped — nothing started, so no halt is owed.
                    try lock.withLock { state -> Void in
                        guard state.generation == generation else { return }
                        try output.start(sampleRate: chunk.sampleRate, channelCount: chunk.channelCount)
                        state.sessionRate = chunk.sampleRate
                        state.sessionChannels = chunk.channelCount
                        state.formatLocked = true
                        state.isActive = true
                    }
                case .ready:
                    break
                }
                if sessionState == .superseded { break }

                let frames = SystemPlayback.monoFrames(from: chunk)
                let enqueued = lock.withLock { state -> Bool in
                    guard state.generation == generation, !state.cancelled else { return false }
                    output.enqueue(frames: frames)
                    return true
                }
                guard enqueued else { break }
            }

            // The stream ended (or the enqueue loop broke on a halt or a supersede). Drain:
            // the session returns when the output reports drained — or when the halt or a
            // superseding play ends it.
            var drained = false
            for _ in 0..<2000 {
                let decision = lock.withLock { state -> DrainDecision in
                    if state.generation != generation { return .superseded }
                    if state.cancelled { return .cancelled }
                    if output.isDrained { return .drained }
                    return .waiting
                }
                switch decision {
                case .drained:
                    drained = true
                case .cancelled:
                    await waitForHalt(generation: generation)
                    return
                case .superseded:
                    return
                case .waiting:
                    try? await Task.sleep(for: .milliseconds(1))
                }
                if drained { break }
            }
            // Drained (or the poll ceiling): stop exactly once, if this session still owns the
            // output — the halt's stop guard makes a racing halt the one that stops.
            let shouldStop = lock.withLock { state -> Bool in
                guard state.generation == generation, state.isActive, !state.halted else { return false }
                state.halted = true
                state.isActive = false
                return true
            }
            if shouldStop { output.stop() }
        } catch {
            // A stream failure: the halt path, then rethrow. A start failure (nothing started),
            // a format-change (its halt already ran), and a superseded session (someone else's)
            // take their own exits and are not halted again.
            let haltOwed = lock.withLock { state in
                state.generation == generation && state.isActive && !state.halted
            }
            if haltOwed { await haltSession() }
            throw error
        }
    }

    /// Ramps the output level to the duck target and keeps playing. Idempotent; a no-op when no
    /// session is active — it never pre-arms the next session.
    public func duck() async {
        lock.withLock { state in
            guard state.isActive, !state.isDucking else { return }
            state.isDucking = true
            state.duckTarget = Float(level.duckGain)
            state.currentGain = Float(level.duckGain)
            output.setGain(Float(level.duckGain))
        }
    }

    /// Halts to silence within the barge-in budget: the shared halt — ramp parked at the clock's
    /// reading, `setGain(0)`, bounded poll to the ramp end, stop exactly once. Idempotent; a
    /// no-op when no session is active.
    public func cancelToSilence() async {
        await haltSession()
    }

    /// Releases the output. Idempotent, synchronous, non-throwing; a later `play` reopens. An
    /// in-flight `play` sees the halt and returns promptly (the release contract).
    public func tearDown() {
        let shouldStop = lock.withLock { state -> Bool in
            state.cancelled = true
            state.halted = true
            let active = state.isActive
            state.isActive = false
            return active
        }
        if shouldStop { output.stop() }
    }

    /// Decodes a chunk's Float32 interleaved bytes and downmixes to mono by arithmetic mean —
    /// the `AudioFormatConverterTests` downmix discipline, including the silent-channel-0
    /// killer. The shipped producers emit Float32, so that is the one interpretation.
    static func monoFrames(from chunk: AudioChunk) -> [Float] {
        let channels = max(chunk.channelCount, 1)
        let frameCount = chunk.bytes.count / (MemoryLayout<Float>.size * channels)
        var frames = [Float]()
        frames.reserveCapacity(frameCount)
        chunk.bytes.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Float.self)
            var index = 0
            while index + channels <= samples.count {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += samples[index + channel]
                }
                frames.append(sum / Float(channels))
                index += channels
            }
        }
        return frames
    }

    // MARK: - The state machine

    private func beginSession() -> Int {
        lock.withLock { state -> Int in
            state.generation += 1
            state.isActive = false
            state.cancelled = false
            state.halted = false
            state.currentGain = 1
            state.duckTarget = 1
            state.isDucking = false
            state.ramp = nil
            state.formatLocked = false
            return state.generation
        }
    }

    /// **The halt** — shared by `cancelToSilence()` and `play`'s failure paths, so a racing
    /// cancel and a stream error stop the output exactly once. Parks the ramp (the first halter
    /// to arrive; the second joins the same ramp), `setGain(0)` (the output's frame-quantized
    /// envelope ducks over the ramp), waits the ramp on the injected clock (bounded — a frozen
    /// clock cannot hang the barge-in), then stops once.
    private func haltSession() async {
        let startedAt = lock.withLock { state -> Duration? in
            guard state.isActive else { return nil }
            if state.ramp == nil {
                state.ramp = LevelRamp(
                    fromGain: state.currentGain, toGain: 0,
                    duration: level.rampDuration, startedAt: clock.now)
                state.rampStartedAt = clock.now
            }
            state.cancelled = true
            if state.currentGain != 0 {
                state.currentGain = 0
                output.setGain(0)
            }
            return state.rampStartedAt
        }
        guard let startedAt else { return }
        await waitForRamp(from: startedAt)
        let shouldStop = lock.withLock { state -> Bool in
            guard state.isActive && !state.halted else { return false }
            state.halted = true
            state.isActive = false
            return true
        }
        if shouldStop { output.stop() }
    }

    /// The bounded ramp wait: `clock.now - startedAt < rampDuration`, 1 ms tick, ceiling 1000
    /// iterations — silence at `rampDuration + stop`, never a cut and never a hang.
    private func waitForRamp(from startedAt: Duration) async {
        let duration = level.rampDuration
        for _ in 0..<1000 {
            if clock.now - startedAt >= duration { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// The play task's bounded wait for the halt's stop: returns when the halt completed or the
    /// session was superseded — the `SessionWatchdogTests` frozen-clock discipline, so `play`
    /// can never hang behind a halt.
    private func waitForHalt(generation: Int) async {
        for _ in 0..<2000 {
            let done = lock.withLock { state in
                state.halted || state.generation != generation
            }
            if done { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

/// The one file in `Sources/VoccaAudio/Playback/` that may name the AVFAudio family
/// (`PlaybackSeamBoundaryTests`): everything the state machine can decide is above it, and the
/// render block below is thin translation plus the realtime envelope.
public protocol PlaybackOutputSeam: AnyObject {
    /// Whether the output is running.
    var isRunning: Bool { get }

    /// Whether every enqueued frame has been rendered. The drain poll reads this; `play` may
    /// return only when it is true.
    var isDrained: Bool { get }

    /// Open the output at the session format. Throws when the device refuses — `play`
    /// propagates the refusal unwrapped. Must not return until the output is actually open.
    func start(sampleRate: Double, channelCount: Int) throws

    /// Enqueue mono Float32 frames at the started rate — the producer's side of the transport.
    func enqueue(frames: [Float])

    /// Set the level target. The output ramps its envelope toward it (frame-quantized, the
    /// ``LevelRamp`` shape on the frame axis) — the duck.
    func setGain(_ gain: Float)

    /// Stop and release the output. Synchronous and non-throwing.
    func stop()
}

/// Everything that can go wrong that is this adapter's own.
public enum PlaybackError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A chunk whose format differs from the session's first chunk — the producers ship
    /// uniform-format streams, so a differing chunk is corruption, not something to guess at.
    /// `play` runs the halt path (the duck), then throws this.
    case chunkFormatChanged

    public var description: String {
        switch self {
        case .chunkFormatChanged:
            return "the playback stream changed format mid-play — the session format is fixed by its first chunk"
        }
    }
}

/// The linear level schedule, as a pure function of the injected clock: from `fromGain` to
/// `toGain` over `duration`, clamped so it never overshoots, complete exactly at the end, and
/// a zero-duration ramp complete at its start. The state machine's halt parks one of these; the
/// real output's render block computes the same shape on the frame axis.
struct LevelRamp {
    let fromGain: Float
    let toGain: Float
    let duration: Duration
    let startedAt: Duration

    init(fromGain: Float, toGain: Float, duration: Duration, startedAt: Duration) {
        self.fromGain = fromGain
        self.toGain = toGain
        self.duration = duration
        self.startedAt = startedAt
    }

    /// The gain at `time`: linear between the endpoints, clamped; before the ramp it is
    /// `fromGain`, a zero-duration ramp is `toGain` from its start.
    func gain(at time: Duration) -> Float {
        let elapsed = time - startedAt
        if duration <= .zero { return toGain }
        if elapsed <= .zero { return fromGain }
        let progress = min(1, max(0, elapsed / duration))
        return fromGain + (toGain - fromGain) * Float(progress)
    }

    /// Whether the ramp has run its full duration by `time`.
    func isComplete(at time: Duration) -> Bool {
        time - startedAt >= duration
    }
}

/// The real output: an `AVAudioEngine` with an `AVAudioSourceNode` (its own instance — O4's
/// two-engine caution, `ARCHITECTURE.md:344`; the capture graph is byte-for-byte untouched), an
/// `AudioRingBuffer` as the producer→render transport, and the frame-quantized envelope in the
/// render block. **The realtime device path here is executed by nothing in CI** — see
/// ``SystemPlayback``'s header for the honest statement; `renderOffline` (manual rendering
/// mode) is what CI can execute.
///
/// ## Why `@unchecked Sendable`
///
/// The same warrant as the state machine that owns this object: every mutable property —
/// `node`, `ring`, `envelope` — is written only under ``SystemPlayback``'s lock (`start`,
/// `stop`, `enqueue`, `setGain` all run inside it), and the render block touches only the
/// ring's SPSC surface and the envelope's atomics. `renderOffline` is the manual-rendering
/// driver — the offline tests' route — and is documented as the caller's serialized driver.
public final class SystemPlaybackOutput: PlaybackOutputSeam, @unchecked Sendable {

    /// Whether the engine runs in manual-rendering mode (`renderOffline` is then the tests'
    /// route — the render block is documented to run on the non-realtime thread there).
    private let manualRendering: Bool

    /// The duck knob, whose ramp the envelope is quantized from.
    private let level: PlaybackLevel

    private let engine = AVAudioEngine()

    /// The session's source node — created at ``start(sampleRate:channelCount:)`` with the
    /// session format (the node's format cannot exist before the first chunk does).
    private var node: AVAudioSourceNode?

    /// The session's producer→render transport. **The consumer role belongs to the render
    /// block alone** — the drain poll reads the frame counters below, never this ring, so the
    /// SPSC warrant's "at most one consumer" holds by construction.
    private var ring: AudioRingBuffer?

    /// Total frames enqueued (producer-written, the one enqueuer) and total frames rendered
    /// (render-block-written, the one renderer): `isDrained` compares the two atomics instead
    /// of reading the ring, so the drain poll never touches the ring's consumer side.
    private let enqueuedFrames = Atomic<Int64>(0)
    private let renderedFrames = Atomic<Int64>(0)

    /// The envelope state, as one object: created at start, captured by the render block (which
    /// therefore holds no reference back to this output — the `AudioBufferListInterleaver`
    /// leak-avoidance precedent) and stored here for the duck and the drain poll. `nil` until
    /// the first session starts.
    private var envelope: EnvelopeState?

    /// - Parameters:
    ///   - manualRendering: drive the engine through `renderOffline` instead of the device —
    ///     the offline tests' route; the plan's pinned attempt, with its recorded fallback.
    ///   - level: the duck knob the envelope quantizes from.
    public init(manualRendering: Bool = false, level: PlaybackLevel = .default) {
        self.manualRendering = manualRendering
        self.level = level
    }

    deinit {
        // Non-asserting — `engine.stop()`/`detach` assert no isolation domain.
        tearDown()
    }

    private func tearDown() {
        if let node {
            engine.detach(node)
        }
        engine.stop()
    }

    public var isRunning: Bool { engine.isRunning }

    public var isDrained: Bool {
        guard let envelope else { return true }
        return envelope.renderedFrames.load(ordering: .relaxed)
            >= envelope.enqueuedFrames.load(ordering: .relaxed)
    }

    /// Open the output at the session format: build the source node (the render block captures
    /// the ring and the envelope atomics, never this object — the `AudioBufferListInterleaver`
    /// leak-avoidance precedent), attach and connect it at the session format, enable manual
    /// rendering mode when configured, and start the engine. The session format is fixed here —
    /// the state machine refuses a differing chunk before this is ever asked again.
    public func start(sampleRate: Double, channelCount: Int) throws {
        guard
            let format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: AVAudioChannelCount(channelCount))
        else {
            throw PlaybackError.chunkFormatChanged
        }

        if manualRendering {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        }

        // The ring's capacity: the smallest power of two ≥ the session rate — roughly a second
        // of audio — so the producer's wait-for-room backpressure engages only when the renderer
        // is behind, never on the chunk cadence itself.
        let ring = AudioRingBuffer(capacity: Self.ringCapacity(for: sampleRate))
        self.ring = ring
        let envelope = EnvelopeState(rampFrames: Self.rampFrameCount(duration: level.rampDuration, sampleRate: sampleRate))
        self.envelope = envelope

        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            Self.render(
                frameCount: frameCount, into: audioBufferList,
                ring: ring, envelope: envelope)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        self.node = node

        try engine.start()
    }

    /// The producer's side: write the block into the ring, **waiting for room when it is full** —
    /// playback never drops a frame, and the wait is a bounded poll (the plan's "it does not
    /// overrun"). Only a write that landed counts toward `isDrained`.
    public func enqueue(frames: [Float]) {
        guard let ring, let envelope else { return }
        var attempts = 0
        var written = false
        while !written && attempts < 3000 {
            written = frames.withUnsafeBufferPointer { pointer in
                ring.write(pointer.baseAddress!, count: pointer.count)
            }
            if !written {
                Thread.sleep(forTimeInterval: 0.001)
                attempts += 1
            }
        }
        if written {
            envelope.enqueuedFrames.store(
                envelope.enqueuedFrames.load(ordering: .relaxed) &+ Int64(frames.count),
                ordering: .relaxed)
        }
    }

    /// The duck: set the envelope's target and restart the frame-quantized ramp toward it. The
    /// ramp starts from the render block's current gain — a duck landing mid-ramp is a
    /// continuation, never a discontinuity.
    public func setGain(_ gain: Float) {
        guard let envelope else { return }
        envelope.targetGain.store(gain, ordering: .relaxed)
        envelope.rampFramesRemaining.store(Int32(envelope.rampFrames), ordering: .relaxed)
    }

    /// Stop and release. A later `play` reopens with a fresh node and ring.
    public func stop() {
        engine.stop()
    }

    /// One offline render pass — the tests' route through manual-rendering mode.
    func renderOffline(into buffer: AVAudioPCMBuffer) throws -> AVAudioEngineManualRenderingStatus {
        try engine.renderOffline(buffer.frameCapacity, to: buffer)
    }

    private static func ringCapacity(for sampleRate: Double) -> Int {
        let target = max(1, Int(sampleRate.rounded()))
        var capacity = 1
        while capacity < target { capacity <<= 1 }
        return capacity
    }

    /// The ramp's length in frames: `rampDuration × rate`, quantized — the frame-quantized twin
    /// of ``LevelRamp``'s clock-axis duration.
    private static func rampFrameCount(duration: Duration, sampleRate: Double) -> Int {
        let seconds =
            Double(duration.components.seconds)
            + Double(duration.components.attoseconds) * 1e-18
        return max(1, Int((seconds * sampleRate).rounded()))
    }

    /// **The render block's body** — runs on the realtime thread in device mode (executed by
    /// nothing in CI) and on the calling thread in manual rendering mode (the offline tests).
    /// Allocates nothing, locks nothing, reads no clock: drains the ring into the buffer,
    /// zero-fills the remainder, applies the frame-quantized linear envelope (the ``LevelRamp``
    /// shape quantized to `rampDuration × rate` frames), and accounts the rendered frames.
    private static func render(
        frameCount: AVAudioFrameCount,
        into audioBufferList: UnsafeMutablePointer<AudioBufferList>,
        ring: AudioRingBuffer,
        envelope: EnvelopeState
    ) {
        let bufferList = audioBufferList.pointee
        guard bufferList.mNumberBuffers == 1, let data = bufferList.mBuffers.mData else { return }
        let floats = data.assumingMemoryBound(to: Float.self)
        let frameCountInt = Int(frameCount)

        let read = ring.read(into: floats, count: frameCountInt)
        if read < frameCountInt {
            for index in read..<frameCountInt { floats[index] = 0 }
        }
        envelope.renderedFrames.store(
            envelope.renderedFrames.load(ordering: .relaxed) &+ Int64(read), ordering: .relaxed)

        let target = envelope.targetGain.load(ordering: .relaxed)
        let current = envelope.currentGain.load(ordering: .relaxed)
        let remaining = Int(envelope.rampFramesRemaining.load(ordering: .relaxed))
        if remaining > 0 {
            let steps = min(frameCountInt, remaining)
            for index in 0..<steps {
                let gain = current + (target - current) * (Float(index + 1) / Float(remaining))
                floats[index] *= gain
            }
            if steps == remaining {
                envelope.currentGain.store(target, ordering: .relaxed)
                for index in steps..<frameCountInt {
                    floats[index] *= target
                }
            } else {
                let endGain = current + (target - current) * (Float(steps) / Float(remaining))
                envelope.currentGain.store(endGain, ordering: .relaxed)
                for index in steps..<frameCountInt {
                    floats[index] *= endGain
                }
            }
            envelope.rampFramesRemaining.store(Int32(remaining - steps), ordering: .relaxed)
        } else {
            // No ramp in flight: the level holds at `current` — the duck's flat region, the
            // halt's silence, and the session's full gain all live here.
            for index in 0..<frameCountInt {
                floats[index] *= current
            }
        }
    }
}

/// The envelope's mutable state, as one object: created at every session start, captured by
/// the render block (which therefore holds no reference back to the output — the
/// `AudioBufferListInterleaver` leak-avoidance precedent) and stored on the output for the duck
/// and the drain poll. Atomics only — the render block's "allocates nothing, locks nothing,
/// reads no clock" warrant holds. The `@unchecked` claim: the render block and the duck
/// serialize their shared state through the atomics, and nothing else lives here.
private final class EnvelopeState: @unchecked Sendable {
    let targetGain = Atomic<Float>(1)
    let currentGain = Atomic<Float>(1)
    let rampFramesRemaining = Atomic<Int32>(0)
    let enqueuedFrames = Atomic<Int64>(0)
    let renderedFrames = Atomic<Int64>(0)

    /// The ramp's total length in frames — fixed at start (`rampDuration × rate`), constant for
    /// the session.
    let rampFrames: Int

    init(rampFrames: Int) {
        self.rampFrames = rampFrames
    }
}

/// The per-chunk decision the play loop makes under the lock.
private enum SessionState: Equatable {
    case superseded
    case unstarted
    case formatChanged
    case ready
}

/// The drain poll's decision.
private enum DrainDecision {
    case drained
    case cancelled
    case superseded
    case waiting
}