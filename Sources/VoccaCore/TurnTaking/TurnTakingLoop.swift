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

/// The barge-in coordinator (R6, `prd.md:136-142`) — the composed heart of C10.
///
/// States: **listening** (continuous capture + VAD) → **uttering** (speech accumulating) →
/// **committed** (the turn detector fires) → reply scheduled → **playing** (ducked,
/// cancellable) → barge-in (VAD speech during playback → the owner's `synthesizer.cancel()`
/// within ≤50 ms + duck → the reply is discarded → the interrupting words are preserved —
/// capture is continuous and never stopped at interrupt time, so the words were already in
/// the buffer).
///
/// ## The `SessionMachine` shape, exactly
///
/// Synchronous, **not** `Sendable`, isolation belongs to the capture feed's owner — never an
/// actor: the loop's feed path must not hop (the barge-in decision rides the capture frame).
/// Everything handed back (``TurnEffect``, ``TurnState``) is `Sendable` so it can cross. The
/// loop **never creates a `Task`**: all async work (speak/play/cancel) is the owner's,
/// driven by the effects — this is what keeps the machine synchronous and the 200 ms path
/// headless over the injected clock.
///
/// ## What the loop does not own
///
/// **The microphone.** Capture start/stop is the owner's, driven by `.started`/`.stopped` —
/// the loop holds no mic seam, so no silent listening state can exist from this aspect's
/// work (`PRODUCT_SPEC.md:11`). **The synthesizer and the playback engine.** The loop names
/// no engine; `.speakReply` and `.bargeIn` are the owner's to apply. **Time.** The clock is
/// injected; the only readings are the playback window's `(start, end)`.
///
/// ## The machine's own seam-custody words (`SessionMachine.swift:571-577`)
///
/// "A component which cannot classify its own state must fail closed." Applied here:
/// `start()` while not `.idle` is **refused** (one consumer at a time — the review-gate
/// ownership pin), `feed` while `.idle` is refused (no fabricated decisions for frames the
/// machine did not ask for), `scheduleReply` is refused in `.uttering` (never speak over the
/// user), in `.playing` (no double speech) and in `.idle`, and double `stop()` is a no-op.
///
/// ## The review-gate fixes (binding)
///
/// 1. **Stream continuity** — `fedFrameCount` numbers every fed frame (gated or not), so
///    the sequence stays contiguous across the interrupt boundary, and the barge-in frame
///    begins the new utterance (the seed only carries the frames accepted during the window
///    — the interrupting words are preserved from the first syllable).
/// 2. **The reply-end race** — speech onset exactly as the last reply chunk lands is a
///    **new utterance immediately** in both orderings (barge-in while the window is open,
///    fresh utterance after it closes): never a dropped first syllable, never a stale commit.
/// 3. **Ownership** — one consumer at a time, a second `start()` refused.
///
/// ## The playback window and the echo gate
///
/// `reportPlaybackStarted()` opens the window at `clock.now` (only while `.playing`);
/// `reportPlaybackChunk(_:)` decodes the chunk into the trailing reference buffer (≤ 16 000
/// samples ≈ 1 s — Float32 little-endian → mono by arithmetic mean → decimated to 16 kHz by
/// nearest-neighbour; a chunk rate < 16 kHz traps loudly, the "loud by construction"
/// precedent — the producers ship uniform-format streams); `reportPlaybackEnded()` closes
/// the window and returns to `.listening`. While the window is open and a reference is held,
/// every fed frame runs ``EchoGate/decision(capture:reference:gain:)`` first — `.discard`
/// drops the frame before the VAD sees it (`gatedFrameCount`), `.accept(samples:)`
/// classifies the residue or the raw frame. With no reference yet the accept is vacuous —
/// barge-in still works before the first chunk (the honest un-gated path). The reference
/// resets per playback session (on start and on end — a stale reference from a previous
/// reply must never gate the next one's window).
///
/// ## Capture failure
///
/// `reportCaptureFailed()` returns any state to `.idle` and emits `.captureFailed` —
/// **deliberately no trap**: the `endCapture` trap guards a transcript hand-over that was
/// owed, and the voice loop owes nothing (the `StreamingCapture` stop-path rationale); the
/// half-uttered turn is discarded with the state entered, and a later `start()` runs fresh.
public final class TurnTakingLoop {
    /// The machine's current state.
    public private(set) var state: TurnState = .idle

    /// Every frame the loop was asked to classify or gate — the stream-continuity sequence.
    public private(set) var fedFrameCount = 0

    /// Every frame the echo gate discarded during playback — the echo-zero counter.
    public private(set) var gatedFrameCount = 0

    /// The VAD — owned as `var` because the seam is `mutating` (the voice-detection plan's
    /// blessed shape; never `@unchecked`).
    private var vad: any VoiceActivityDetector

    /// The turn detector — a scored commit/keep-listening decision per candidate pause.
    private let turnDetector: any TurnDetector

    /// The only time source: the playback window's start/end readings.
    private let clock: any MonotonicClock

    /// The echo gate — a pure value; the loop owns its composition in the feed path.
    private let gate: EchoGate

    /// The owner's effect sink — applied by the owner, never by the loop.
    private let onEffect: (TurnEffect) -> Void

    /// The N1 hook — the state-change callback, present in the loop, wired by nothing.
    private let onStateChange: (TurnState) -> Void

    /// The turn's speech frames (never the pause frames).
    private var utteranceFrames: [AudioBuffer] = []

    /// The candidate pause, as samples since the last speech frame.
    private var pauseSamples: [Float] = []

    /// The accepted frames seen during the open playback window — the pre-barge-in seed.
    private var speechSeedFrames: [AudioBuffer] = []

    /// The playback window: open between `reportPlaybackStarted()` and
    /// `reportPlaybackEnded()`, at the clock readings.
    private var playbackWindow: (start: Duration, end: Duration)?

    /// The trailing reference, ≤ 16 000 samples, fed by `reportPlaybackChunk(_:)`.
    private var trailingReference: [Float] = []

    public init(
        vad: any VoiceActivityDetector,
        turnDetector: any TurnDetector,
        clock: any MonotonicClock,
        gate: EchoGate,
        onEffect: @escaping (TurnEffect) -> Void,
        onStateChange: @escaping (TurnState) -> Void = { _ in }
    ) {
        self.vad = vad
        self.turnDetector = turnDetector
        self.clock = clock
        self.gate = gate
        self.onEffect = onEffect
        self.onStateChange = onStateChange
    }

    // MARK: - The public surface (thin funnels)

    /// `.idle → .listening`, emits `.started`. **A second start while not `.idle` is
    /// refused** — state unchanged, nothing emitted (the ownership pin: one consumer at a
    /// time, the `isOpeningTheMicrophone` fail-closed doctrine). A fresh start resets the
    /// accumulators; the fed/gated counters are lifetime counts and keep numbering.
    public func start() {
        guard state == .idle else { return }
        resetAccumulators()
        transition(to: .listening)
        onEffect(.started)
    }

    /// Any non-idle state → `.idle`, emits `.stopped` once. A second `stop()` is a no-op.
    /// Capture teardown is the owner's — the loop holds no mic seam.
    public func stop() {
        guard state != .idle else { return }
        transition(to: .idle)
        onEffect(.stopped)
    }

    /// Feeds one capture frame. `.idle` is refused (the machine does not fabricate decisions
    /// for frames it did not ask for — not counted). Otherwise `fedFrameCount` grows by one
    /// and the frame is routed by state:
    ///
    /// - `.listening`: VAD speech flips to `.uttering` (`.speechBegan`, frame accumulated);
    ///   silence is nothing.
    /// - `.uttering`: speech clears the pause and accumulates (a speech frame restarts the
    ///   candidate pause — the veto-tolerance rule); silence extends the pause and runs the
    ///   turn detector **on every silence frame** (below threshold keep listening — the R3
    ///   scored decision, never a timer); the first `.commit` → `.committed` with exactly the
    ///   speech frames.
    /// - `.committed`: speech starts a **fresh** utterance (accumulators reset — the owner's
    ///   pending reply is superseded); silence is nothing.
    /// - `.playing`: the echo gate first (window open + reference held); `.discard` counts
    ///   the gated frame and returns — the frame never reaches the VAD. `.accept(samples:)`
    ///   classifies the residue or the raw frame: VAD speech → **barge-in** (the seed plus
    ///   this frame start the new utterance, `.bargeIn` exactly once per reply — the
    ///   interrupting words are preserved from the first syllable); VAD silence → the frame
    ///   joins the seed (silence during playback never gates and never barge-ins).
    public func feed(_ frame: AudioBuffer) {
        guard state != .idle else { return }
        fedFrameCount += 1

        switch state {
        case .idle:
            break  // unreachable — refused above.

        case .listening:
            switch vad.classify(frame) {
            case .speech:
                utteranceFrames.append(frame)
                transition(to: .uttering)
                onEffect(.speechBegan)
            case .silence:
                break
            }

        case .uttering:
            switch vad.classify(frame) {
            case .speech:
                pauseSamples.removeAll(keepingCapacity: true)
                utteranceFrames.append(frame)
            case .silence:
                pauseSamples.append(contentsOf: frame.samples)
                let pause = AudioBuffer(samples: pauseSamples, sampleRate: 16_000)
                let utterance = AudioBuffer(
                    samples: utteranceFrames.flatMap(\.samples), sampleRate: 16_000)
                if turnDetector.decide(pause, utterance: utterance).commitment == .commit {
                    transition(to: .committed)
                    onEffect(.turnCommitted(utterance: utteranceFrames))
                }
            }

        case .committed:
            switch vad.classify(frame) {
            case .speech:
                resetAccumulators()
                utteranceFrames.append(frame)
                transition(to: .uttering)
                onEffect(.speechBegan)
            case .silence:
                break
            }

        case .playing:
            let classification: SpeechActivity
            if playbackWindow != nil, !trailingReference.isEmpty {
                switch EchoGate.decision(
                    capture: frame.samples, reference: trailingReference, gain: gate.gain)
                {
                case .discard:
                    gatedFrameCount += 1
                    return
                case .accept(let samples):
                    classification = vad.classify(
                        AudioBuffer(samples: samples ?? frame.samples, sampleRate: 16_000))
                }
            } else {
                classification = vad.classify(frame)
            }

            switch classification {
            case .speech:
                utteranceFrames = speechSeedFrames + [frame]
                speechSeedFrames.removeAll(keepingCapacity: true)
                transition(to: .uttering)
                onEffect(.bargeIn)
            case .silence:
                speechSeedFrames.append(frame)
            }
        }
    }

    /// Schedules a reply: `.committed` or `.listening` → `.playing`, emits
    /// `.speakReply(text:)`, resets the accumulators. Refused in `.uttering` (never speak
    /// over the user), in `.playing` (a second reply is a driver bug — no double speech),
    /// and in `.idle`.
    public func scheduleReply(_ text: String) {
        guard state == .committed || state == .listening else { return }
        resetAccumulators()
        transition(to: .playing)
        onEffect(.speakReply(text: text))
    }

    /// Opens the playback window at `clock.now` — only while `.playing`; else a no-op.
    /// The reference for this session starts empty (the first chunk populates it).
    public func reportPlaybackStarted() {
        guard state == .playing else { return }
        trailingReference.removeAll(keepingCapacity: true)
        playbackWindow = (clock.now, clock.now)
    }

    /// Decodes one rendered chunk into the trailing reference. Float32 little-endian →
    /// frames, mono by arithmetic mean, decimated to 16 kHz by nearest-neighbour. A chunk
    /// rate below 16 kHz traps loudly — the producers ship uniform-format streams (the
    /// "loud by construction" precedent).
    public func reportPlaybackChunk(_ chunk: AudioChunk) {
        precondition(
            chunk.sampleRate >= Double(AudioBuffer.interchangeSampleRate),
            "a playback chunk below the 16 kHz interchange rate cannot be decimated — the "
                + "producers ship uniform-format streams")
        let channelCount = max(chunk.channelCount, 1)
        var interleaved: [Float] = []
        interleaved.reserveCapacity(chunk.bytes.count / 4)
        var byteIndex = 0
        while byteIndex + MemoryLayout<Float>.size <= chunk.bytes.count {
            var bits: UInt32 = 0
            for offset in 0..<4 {
                bits |= UInt32(chunk.bytes[byteIndex + offset]) << (8 * offset)
            }
            interleaved.append(Float(bitPattern: bits))
            byteIndex += MemoryLayout<Float>.size
        }

        var mono: [Float] = []
        var frame = 0
        while frame + channelCount <= interleaved.count {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += interleaved[frame + channel]
            }
            mono.append(sum / Float(channelCount))
            frame += channelCount
        }

        let ratio = chunk.sampleRate / Double(AudioBuffer.interchangeSampleRate)
        let decimatedCount = Int(Double(mono.count) / ratio)
        let decimated = (0..<decimatedCount).map { index in
            mono[Int((Double(index) * ratio).rounded())]
        }
        trailingReference.append(contentsOf: decimated)
        if trailingReference.count > 16_000 {
            trailingReference.removeFirst(trailingReference.count - 16_000)
        }
    }

    /// Closes the playback window; `.playing → .listening` (the natural end — no stale
    /// accumulator, no stale reference). A barge-in that already left `.playing` makes this
    /// a no-op.
    public func reportPlaybackEnded() {
        playbackWindow = nil
        trailingReference.removeAll(keepingCapacity: true)
        if state == .playing {
            transition(to: .listening)
        }
    }

    /// Any state → `.idle`, emits `.captureFailed`. **No trap — deliberately**: the
    /// `endCapture` trap guards a transcript hand-over that was owed; the voice loop owes
    /// nothing, and the half-uttered turn is discarded with the state entered.
    public func reportCaptureFailed() {
        resetAccumulators()
        transition(to: .idle)
        onEffect(.captureFailed)
    }

    // MARK: - Private

    /// The state-change hook (N1) fires on every successful transition.
    private func transition(to newState: TurnState) {
        state = newState
        onStateChange(newState)
    }

    /// Drops the utterance, the candidate pause and the seed — and the playback session's
    /// window and reference, so a fresh start (or a reply that supersedes the current one)
    /// never gates against stale state. The window is re-opened by `reportPlaybackStarted()`.
    private func resetAccumulators() {
        utteranceFrames.removeAll(keepingCapacity: true)
        pauseSamples.removeAll(keepingCapacity: true)
        speechSeedFrames.removeAll(keepingCapacity: true)
        playbackWindow = nil
        trailingReference.removeAll(keepingCapacity: true)
    }
}