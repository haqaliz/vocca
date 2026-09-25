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

import CryptoKit
import Foundation
import VoccaCore
import XCTest

/// **The composed acceptance** (`barge-in-loop/plan_20260915.md` Phase 5): the whole headless
/// scenario over doubles and the injected clock — the ≤200 ms halt at the contract
/// thresholds, stream continuity across the interrupt, echo zero on synthetic overlap,
/// silence during playback never gating, the reply-end race, the cancel hammer, the
/// no-trap capture failure, and the dictation-path no-touch pin (G5). The injected clock is
/// the **only** time source; every timing assertion runs at the contract thresholds
/// (30 + ≤50 + ≤20 + margin ≤ 200), never at CI wall time — O5's loaded-runner measurement
/// is why.
final class TurnTakingComposedAcceptanceTests: XCTestCase {

    /// The committed VAD configuration, shared with the seam and harness suites.
    private static let configuration = VADConfiguration(
        onsetRMS: 0.05, offsetRMS: 0.02, minimumSpeech: 0.10, minimumSilence: 0.20)

    /// The real turn detector the composed scenario commits through.
    private static let turnDetector = SilenceThresholdDetector(
        configuration: SilenceThresholdConfiguration(
            commitAfterPause: 0.5, minimumUtteranceDuration: 0.2))

    /// The reply the stub synthesizer renders: 3 chunks of 440 Hz, 0.25 s each — the known
    /// reference the echo rows play back.
    private static func replyChunks() -> [AudioChunk] {
        (0..<3).map { _ in TurnLoopFixtures.chunk(amplitude: 0.4, frequency: 440, samples: 4000) }
    }

    /// Builds a composed driver over a scripted VAD and the real turn detector.
    private func makeDriver(
        vad script: [SpeechActivity], clock: TurnLoopTestClock = TurnLoopTestClock()
    ) -> ComposedTurnDriver {
        ComposedTurnDriver(
            vad: ScriptedVAD(configuration: Self.configuration, script: script),
            turnDetector: Self.turnDetector,
            synth: StubSynthesizer(
                identity: VoiceIdentity(engineID: "composed-stub-synth", voiceName: nil),
                chunks: Self.replyChunks()),
            playback: FakePlaybackEngine(),
            clock: clock)
    }

    /// The shared full-arc script: listening silence, a 4-frame utterance, an 8-frame pause
    /// (commit), the interrupting 4-frame utterance, and its 8-frame pause (commit).
    private static func fullArcScript() -> [SpeechActivity] {
        [.silence, .silence] + [SpeechActivity](repeating: .speech, count: 4)
            + [SpeechActivity](repeating: .silence, count: 8)
            + [SpeechActivity](repeating: .speech, count: 4)
            + [SpeechActivity](repeating: .silence, count: 8)
    }

    /// **The 200 ms gate.** The full arc: start → utterance → commit → reply plays 3 chunks →
    /// window open, reference held → the user's speech frame → `.bargeIn` → cancel/duck →
    /// the interrupting utterance commits → stop. `tSilence − tSpeech ≤ 200 ms` where
    /// `tSilence = tCancel + 50 ms (stub cancel cost) + 20 ms (duck ramp)`, and
    /// `tCancel − tSpeech ≤ 50 ms` (the coordinator's own contribution, at the contract
    /// threshold).
    func testACompleteTurnWithABargeInHaltsWithinTheBudget() async throws {
        let driver = makeDriver(vad: Self.fullArcScript())
        driver.start()

        try await driver.feed(TurnLoopFixtures.silence())
        try await driver.feed(TurnLoopFixtures.silence())
        for _ in 0..<4 { try await driver.feed(TurnLoopFixtures.tone(frequency: 880)) }
        for _ in 0..<8 { try await driver.feed(TurnLoopFixtures.silence()) }
        try await driver.scheduleReply("hello there")

        try await driver.feed(TurnLoopFixtures.tone(frequency: 880))  // the interrupt frame

        let tSpeech = try XCTUnwrap(driver.tSpeech, "the interrupt frame's arrival is recorded")
        let tCancel = try XCTUnwrap(driver.tCancel, "the barge-in's application is recorded")
        let tSilence = try XCTUnwrap(driver.tSilence, "the halt's completion is recorded")

        XCTAssertLessThanOrEqual(
            tCancel - tSpeech, .milliseconds(50),
            "the coordinator's own contribution must fit the ≤50 ms cancel contract — a future "
                + "async refactor cannot silently exceed it")
        XCTAssertLessThanOrEqual(
            tSilence - tSpeech, .milliseconds(200),
            "the whole composed halt fits the 200 ms gate at the contract thresholds "
                + "(30 + ≤50 + ≤20 + margin) — over the injected clock, never at CI wall time")

        for _ in 0..<3 { try await driver.feed(TurnLoopFixtures.tone(frequency: 880)) }
        for _ in 0..<8 { try await driver.feed(TurnLoopFixtures.silence()) }
        driver.stop()

        XCTAssertEqual(
            driver.effects.filter { $0 == .bargeIn }.count, 1,
            "exactly one barge-in for the one reply")
        XCTAssertEqual(
            driver.effects.compactMap { effect in
                if case .turnCommitted = effect { return true } else { return nil }
            }.count, 2,
            "both turns commit")
        XCTAssertEqual(driver.loop.state, .idle)
    }

    /// **Stream continuity** (review-gate fix 1): fed-frame counts stay contiguous across the
    /// interrupt boundary, and the interrupting utterance's first frame is the barge-in
    /// frame — no dropped-chunk window, no eaten first syllable.
    func testTheInterruptingUtteranceSurvivesTheBoundary() async throws {
        let driver = makeDriver(vad: Self.fullArcScript())
        driver.start()

        try await driver.feed(TurnLoopFixtures.silence())
        try await driver.feed(TurnLoopFixtures.silence())
        for _ in 0..<4 { try await driver.feed(TurnLoopFixtures.tone(frequency: 880)) }
        for _ in 0..<8 { try await driver.feed(TurnLoopFixtures.silence()) }
        try await driver.scheduleReply("hello there")

        let beforeInterrupt = driver.loop.fedFrameCount
        try await driver.feed(TurnLoopFixtures.tone(frequency: 880))  // the barge-in frame
        for _ in 0..<3 { try await driver.feed(TurnLoopFixtures.tone(frequency: 880)) }
        for _ in 0..<8 { try await driver.feed(TurnLoopFixtures.silence()) }

        XCTAssertEqual(
            driver.loop.fedFrameCount, beforeInterrupt + 12,
            "fed-frame counts stay contiguous across the interrupt boundary")

        let commits = driver.effects.compactMap { effect -> [AudioBuffer]? in
            if case .turnCommitted(let utterance) = effect { return utterance } else { return nil }
        }
        XCTAssertEqual(
            commits[1].first, TurnLoopFixtures.tone(frequency: 880),
            "the interrupting utterance's first frame is the barge-in frame")
    }

    /// **Echo zero, headless**: during playback, feed the played chunks back as overlapped
    /// capture frames (the exact 0.85-scaled reference) — every echo frame gated, no speech
    /// beyond the first turn's, no barge-in: zero transcription of the loop's own output.
    func testEchoZeroOnSyntheticOverlap() async throws {
        var script: [SpeechActivity] = [.silence, .speech]
        script += [SpeechActivity](repeating: .speech, count: 3)
        script += [SpeechActivity](repeating: .silence, count: 8)
        script += [.silence]  // the post-reply silence frame (accepted, seeded)
        let driver = makeDriver(vad: script)
        driver.start()

        try await driver.feed(TurnLoopFixtures.silence())
        for _ in 0..<4 { try await driver.feed(TurnLoopFixtures.tone(frequency: 880)) }
        for _ in 0..<8 { try await driver.feed(TurnLoopFixtures.silence()) }
        try await driver.scheduleReply("reply")

        let echo = TurnLoopFixtures.echo(of: Self.replyChunks()[0], gain: 0.85)
        try await driver.feed(echo)
        try await driver.feed(echo)
        try await driver.feed(echo)
        try await driver.feed(TurnLoopFixtures.silence())
        driver.reportPlaybackEnded()

        XCTAssertEqual(driver.loop.gatedFrameCount, 3, "every echo frame is gated")
        XCTAssertEqual(
            driver.effects.filter { $0 == .speechBegan }.count, 1,
            "echo never begins speech — only the first turn's .speechBegan exists")
        XCTAssertFalse(driver.effects.contains(.bargeIn), "echo never barge-ins")
    }

    /// Silence during an open playback window is never gated and never speech — the PRD pin
    /// at the composed level.
    func testSilenceDuringPlaybackNeverGates() async throws {
        var script: [SpeechActivity] = [.silence, .speech]
        script += [SpeechActivity](repeating: .speech, count: 3)
        script += [SpeechActivity](repeating: .silence, count: 8)
        script += [SpeechActivity](repeating: .silence, count: 3)
        let driver = makeDriver(vad: script)
        driver.start()

        try await driver.feed(TurnLoopFixtures.silence())
        for _ in 0..<4 { try await driver.feed(TurnLoopFixtures.tone(frequency: 880)) }
        for _ in 0..<8 { try await driver.feed(TurnLoopFixtures.silence()) }
        try await driver.scheduleReply("reply")

        try await driver.feed(TurnLoopFixtures.silence())
        try await driver.feed(TurnLoopFixtures.silence())
        try await driver.feed(TurnLoopFixtures.silence())
        driver.reportPlaybackEnded()

        XCTAssertEqual(driver.loop.gatedFrameCount, 0, "silence during playback never gates")
        XCTAssertEqual(
            driver.effects.filter { $0 == .speechBegan }.count, 1,
            "silence never begins speech")
        XCTAssertFalse(driver.effects.contains(.bargeIn), "silence never barge-ins")
    }

    /// **The reply-end race** (review-gate fix 2) at the composed level: speech onset exactly
    /// as the last reply chunk lands is a new utterance immediately in both orderings — the
    /// frame is retained, and no stale commit or speakReply results.
    func testSpeechAtTheReplyEndIsANewUtteranceInBothOrderings() async throws {
        // Ordering 1: the onset arrives while the window is still open (after the last chunk)
        // — a barge-in.
        let first = makeDriver(vad: Self.fullArcScript())
        first.start()
        try await first.feed(TurnLoopFixtures.silence())
        try await first.feed(TurnLoopFixtures.silence())
        for _ in 0..<4 { try await first.feed(TurnLoopFixtures.tone(frequency: 880)) }
        for _ in 0..<8 { try await first.feed(TurnLoopFixtures.silence()) }
        try await first.scheduleReply("reply")
        try await first.feed(TurnLoopFixtures.tone(frequency: 880))  // the onset, at the final chunk
        for _ in 0..<3 { try await first.feed(TurnLoopFixtures.tone(frequency: 880)) }
        for _ in 0..<8 { try await first.feed(TurnLoopFixtures.silence()) }

        XCTAssertEqual(first.effects.filter { $0 == .bargeIn }.count, 1)
        let firstCommits = first.effects.compactMap { effect -> [AudioBuffer]? in
            if case .turnCommitted(let utterance) = effect { return utterance } else { return nil }
        }
        XCTAssertEqual(
            firstCommits[1].first, TurnLoopFixtures.tone(frequency: 880),
            "order 1: the onset frame is retained as the new utterance's first frame")
        XCTAssertEqual(
            first.effects.filter { if case .speakReply = $0 { return true } else { return false } }
                .count, 1,
            "no stale speakReply after the race")

        // Ordering 2: the window closes first, then the onset — a fresh utterance.
        let second = makeDriver(vad: Self.fullArcScript())
        second.start()
        try await second.feed(TurnLoopFixtures.silence())
        try await second.feed(TurnLoopFixtures.silence())
        for _ in 0..<4 { try await second.feed(TurnLoopFixtures.tone(frequency: 880)) }
        for _ in 0..<8 { try await second.feed(TurnLoopFixtures.silence()) }
        try await second.scheduleReply("reply")
        second.reportPlaybackEnded()
        try await second.feed(TurnLoopFixtures.tone(frequency: 880))  // the onset, just after
        for _ in 0..<3 { try await second.feed(TurnLoopFixtures.tone(frequency: 880)) }
        for _ in 0..<8 { try await second.feed(TurnLoopFixtures.silence()) }

        XCTAssertFalse(second.effects.contains(.bargeIn), "order 2: no barge-in after the window")
        let secondCommits = second.effects.compactMap { effect -> [AudioBuffer]? in
            if case .turnCommitted(let utterance) = effect { return utterance } else { return nil }
        }
        XCTAssertEqual(
            secondCommits[1].first, TurnLoopFixtures.tone(frequency: 880),
            "order 2: the onset frame is retained as the fresh utterance's first frame")
        XCTAssertEqual(
            second.effects.filter { if case .speakReply = $0 { return true } else { return false } }
                .count, 1,
            "no stale speakReply after the race")
    }

    /// **The cancel hammer** (the C9 cancel-then-reinvoke contract consumed): N rapid
    /// speak/barge-in cycles stay stable — every reply discarded, one `.bargeIn` per reply,
    /// the fake playback's ledger shows one halt per cancel, and the loop ends listening.
    func testCancelHammeringStaysStable() async throws {
        let cycles = 3
        var script: [SpeechActivity] = []
        for _ in 0..<cycles {
            script += [SpeechActivity](repeating: .speech, count: 4)
            script += [SpeechActivity](repeating: .silence, count: 8)
            script.append(.speech)
        }
        script += [SpeechActivity](repeating: .speech, count: 4)
        script += [SpeechActivity](repeating: .silence, count: 8)

        let driver = makeDriver(vad: script)
        driver.start()

        for _ in 0..<cycles {
            for _ in 0..<4 { try await driver.feed(TurnLoopFixtures.tone(frequency: 880)) }
            for _ in 0..<8 { try await driver.feed(TurnLoopFixtures.silence()) }
            try await driver.scheduleReply("reply")
            try await driver.feed(TurnLoopFixtures.tone(frequency: 880))  // barge-in
        }
        for _ in 0..<4 { try await driver.feed(TurnLoopFixtures.tone(frequency: 880)) }
        for _ in 0..<8 { try await driver.feed(TurnLoopFixtures.silence()) }
        try await driver.scheduleReply("last")
        driver.reportPlaybackEnded()

        XCTAssertEqual(
            driver.effects.filter { $0 == .bargeIn }.count, cycles,
            "one .bargeIn per reply")
        let haltCount = await driver.playback.haltCount
        XCTAssertEqual(
            haltCount, cycles,
            "the fake playback's ledger shows one halt per cancel")
        XCTAssertEqual(driver.loop.state, .listening, "the loop ends listening")
    }

    /// A capture failure mid-turn returns the loop to `.idle` with `.captureFailed` —
    /// no trap (the loop owes no transcript hand-over) — and a later `start()` runs fresh.
    func testCaptureFailureMidTurnReturnsToIdle() async throws {
        let driver = makeDriver(vad: [.silence, .speech, .speech])
        driver.start()
        try await driver.feed(TurnLoopFixtures.silence())
        try await driver.feed(TurnLoopFixtures.tone(frequency: 880))
        driver.reportCaptureFailed()

        XCTAssertEqual(driver.loop.state, .idle)
        XCTAssertEqual(driver.effects.last, .captureFailed)

        driver.start()
        try await driver.feed(TurnLoopFixtures.tone(frequency: 880))
        XCTAssertEqual(driver.loop.state, .uttering, "a later start runs a fresh loop")
    }

    /// **The G5 pin (extension)**: the dictation path is byte-for-byte untouched by the
    /// voice loop's work. SHA-256 (CryptoKit, the house pattern — nine prior pins) of the
    /// three files, asserted against the digests computed 2026-09-15 in this worktree (the
    /// three files were clean in `git status`; a deliberate edit fails CI until the digest
    /// is recomputed and edited in review — the pin must never be edited to match a moved
    /// tree).
    ///
    /// `AppBootstrap.swift` was re-anchored once, deliberately, on 2026-09-22 by the
    /// `shell-provider` wiring REFACTOR (`ecfcdb4b…` → `e9aa45bb…`, computed, never
    /// edited-to-match): the composition root grew the shell wiring, the card routing and the
    /// Actions-tab bindings. The two dictation digests are unchanged.
    ///
    /// Re-anchored once more, deliberately, on 2026-09-25 by the `phrase-intent-resolver`
    /// wiring REFACTOR (`e9aa45bb…` → `eba72eaf…`, computed with `shasum -a 256`, never
    /// edited-to-match): the composed intent default flipped from `NullIntentResolver` to a
    /// per-turn `PhraseIntentResolver` over `intent-phrases.json`. The two dictation digests
    /// are unchanged.
    func testTheDictationPathIsByteForByteUntouched() throws {
        let root = try PackageRootLocator.find(from: #filePath)
        let pinned: [(file: String, digest: String)] = [
            (
                "Sources/VoccaCore/SessionMachine.swift",
                "1baeb2de2c45149746468bfef49862a08279008d3d2f305be892122d5727537e"
            ),
            (
                "Sources/VoccaCore/DictationPipeline.swift",
                "ce70ca10c15914d6960f07e53da8571a5fa9ec1fb58b8f0051ef051f16c07a84"
            ),
            (
                "Sources/VoccaBootstrap/AppBootstrap.swift",
                "eba72eafd8d71310a09094d2aff51c6e450aba37578a2246556939ffc65233ac"
            ),
        ]

        XCTAssertFalse(pinned.isEmpty, "vacuity guard: the pin must name the files it pins")
        for (file, expected) in pinned {
            let data = try Data(contentsOf: root.appendingPathComponent(file))
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(
                actual, expected,
                """
                \(file) changed byte-for-byte since the barge-in-loop aspect pinned it. The \
                dictation path must be untouched by the voice loop — if the change is a \
                deliberate edit, recompute the digest and edit the pin in review; it must never \
                be edited to match a moved tree.
                """)
        }
    }
}

/// **The composed driver**: feeds scripted frames over the injected clock, applies the loop's
/// effects as the owner would — on `.speakReply` runs the stub's stream into the fake
/// playback and reports the window and its chunks (the window stays open — the reply is
/// still sounding, which is what lets the next speech frame barge in), and on `.bargeIn`
/// records `tCancel = clock.now`, advances the clock through the stub's scripted costs
/// (cancel 50 ms, duck 20 ms), records `tSilence`, and reports playback ended. The injected
/// clock is the only time source.
final class ComposedTurnDriver {
    let clock: TurnLoopTestClock
    let loop: TurnTakingLoop
    let synth: StubSynthesizer
    let playback: FakePlaybackEngine

    /// The full effect record — appended by the `onEffect` hook, never consumed, so tests
    /// read the whole trajectory ("assertions read the ledger, never a believed call").
    private let effectHistory = EffectLedgerBox()
    var effects: [TurnEffect] { effectHistory.values }

    /// The pending effects the drain has not yet applied.
    private let pendingEffects = EffectLedgerBox()

    /// The interrupt frame's arrival instant — recorded by ``feed(_:)`` on every frame.
    private(set) var tSpeech: Duration?
    /// The `.bargeIn` application instant — recorded when the effect is drained.
    private(set) var tCancel: Duration?
    /// `tCancel + cancel cost + duck ramp` — the halt's completion instant.
    private(set) var tSilence: Duration?

    private let cancelCost: Duration
    private let duckRamp: Duration

    init(
        vad: any VoiceActivityDetector,
        turnDetector: any TurnDetector,
        synth: StubSynthesizer,
        playback: FakePlaybackEngine,
        clock: TurnLoopTestClock = TurnLoopTestClock(),
        gate: EchoGate = EchoGate(),
        cancelCost: Duration = .milliseconds(50),
        duckRamp: Duration = .milliseconds(20)
    ) {
        self.clock = clock
        self.synth = synth
        self.playback = playback
        self.cancelCost = cancelCost
        self.duckRamp = duckRamp
        let history = self.effectHistory
        let pending = self.pendingEffects
        self.loop = TurnTakingLoop(
            vad: vad, turnDetector: turnDetector, clock: clock, gate: gate,
            onEffect: { effect in
                history.values.append(effect)
                pending.values.append(effect)
            })
    }

    func start() { loop.start() }
    func stop() { loop.stop() }
    func reportPlaybackEnded() { loop.reportPlaybackEnded() }
    func reportCaptureFailed() { loop.reportCaptureFailed() }

    /// Schedules a reply and immediately applies its effects — the reply's window opens and
    /// its chunks are reported **before** the next frame arrives, which is what arms the
    /// echo gate for it.
    func scheduleReply(_ text: String) async throws {
        loop.scheduleReply(text)
        try await drain()
    }

    /// Advances the clock to the frame's arrival instant, feeds it, and drains the effects.
    func feed(_ frame: AudioBuffer) async throws {
        clock.advance(by: .nanoseconds(62_500 * Int64(frame.samples.count)))
        tSpeech = clock.now
        loop.feed(frame)
        try await drain()
    }

    private func drain() async throws {
        while !pendingEffects.values.isEmpty {
            let effect = pendingEffects.values.removeFirst()
            switch effect {
            case .speakReply(let text):
                // The stub re-renders its script per call: one pass into the fake playback,
                // one pass into the loop's reference (the window stays open — the reply is
                // still sounding until a barge-in or a reportPlaybackEnded closes it).
                var chunks: [AudioChunk] = []
                for try await chunk in synth.speak(text) {
                    chunks.append(chunk)
                }
                try? await playback.play(synth.speak(text))
                loop.reportPlaybackStarted()
                for chunk in chunks {
                    loop.reportPlaybackChunk(chunk)
                }
            case .bargeIn:
                tCancel = clock.now
                clock.advance(by: cancelCost)
                await synth.cancel()
                await playback.cancelToSilence()
                clock.advance(by: duckRamp)
                tSilence = clock.now
                loop.reportPlaybackEnded()
            case .started, .stopped, .speechBegan, .turnCommitted, .captureFailed:
                break
            }
        }
    }
}

/// The effect ledger's box — a final class so the loop's `onEffect` closure can capture it
/// while `self` is still mid-initialization.
private final class EffectLedgerBox {
    var values: [TurnEffect] = []
}