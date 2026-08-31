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

import VoccaBootstrap
import VoccaCore
import VoccaInject
import VoccaUI
import XCTest

@testable import VoccaAudio

/// The speculative feed's composed acceptance (`speculative-feed` phase (c)): a real root over
/// fakes drives a scripted session through the feed — the `BenchmarkHarness` shape (fake graph +
/// real ring + real converter + `MicrophoneSource`, a streaming stub engine in the resolver, a
/// ledger injector, the real `WidgetStateStore`, fake timers) — and asserts the production
/// guard at the wiring level: **zero injector calls before the final**, the final's text equals
/// the batch result for the same audio, and the widget's provisional text is cleared on the
/// terminal adoption.
///
/// What this file pins, criterion by criterion:
///
/// - The feed is armed by `.opening` and ticks at the pinned cadence.
/// - The sub-minimum suppression is wired end to end: nothing reaches the store while the
///   accumulated buffer is below the threshold (and nothing empty ever does).
/// - The partials reach the widget store — provisional text during the session's display
///   window (the reducer keeps partials while RECORDING or TRANSCRIBING; the route runs at
///   key-up), **never** the injector.
/// - Exactly one injector call, carrying the final; the final's text equals the batch result
///   for the same audio (the deterministic `StubEngine.text` transcription, hand-computed).
/// - The store's `partialText` is cleared on the terminal adoption and never survives into a
///   DELIVERED state.
@MainActor
final class SpeculativeFeedIntegrationTests: XCTestCase {

    /// **The production guard at the wiring level.** A composed root drives one session: the
    /// feed drains the scripted buffer on its ticks, the router terminates it at key-up and
    /// routes the stream, and the loop's ledgers show exactly one injection — the final's — with
    /// the widget's provisional text appearing (and being cleared) around it.
    func testAComposedRootDrivesAScriptedSessionThroughTheFeedToOneFinalInjection() async throws {
        let clock = BenchmarkClock()
        let keyboard = Keyboard()
        let ledger = LatencyLedger()
        let sessionBox = LatencySessionBox()
        let graph = BenchmarkGraph(
            ring: AudioRingBuffer(capacity: 1 << 12), clock: clock,
            stopAdvance: .milliseconds(3))
        let feedTimer = FakeTimer()
        let microphone = try MicrophoneSource(
            graph: graph,
            recorder: ledger,
            clock: clock,
            sessionIDProvider: { sessionBox.sessionID },
            feedSchedule: (schedule: { feedTimer.start(every: $0, $1) }, unschedule: { feedTimer.stop() }),
            feedSubMinimum: { $0 < 4 })
        let engine = StreamingStubEngine(
            identity: EngineIdentity(
                id: "speculative-feed-integration-engine",
                displayName: "Speculative feed integration engine", isLocal: true),
            partials: ["hel", "hello "],
            finalText: "1 2 3 4 5 6 7 8")
        let injector = IntegrationLedgerInjector()
        let sink = StoreFoldingPartialSink()
        let pipeline = DictationPipeline(
            engine: engine, injector: injector, holder: BenchmarkHolder(),
            recorder: ledger, clock: clock, partialSink: sink)
        let resolver = DictationEngineResolver(selection: .defaultSelection) { _ in engine }
        let focusedApp = FakeFocusedApp(
            identity: FocusedAppIdentity(
                bundleID: "com.example.Notes", windowTitle: "The Draft"))
        let targetResolution = TargetResolution(
            focusedApp: focusedApp, secureInput: FakeSecureInput())
        let holder = BenchmarkHolder()
        let panel = RecordingPanel(holder: holder)
        let configuration = HotkeyConfiguration(
            keyCode: 49, modifiers: [.option], activation: .holdToTalk)
        let toggleConfiguration = HotkeyConfiguration(
            keyCode: 49, modifiers: [.option], activation: .toggle)
        let root = DictationLoopRoot(
            configuration: configuration,
            ceiling: SessionCeiling.default,
            clock: clock,
            audioSource: microphone,
            keyState: TruthfulKeyState(keyboard),
            watchdogTimer: FakeTimer(),
            healthTimer: FakeTimer(),
            deferOpening: { $0() },
            tap: FakeHotkeyEventSource(),
            secureInput: FakeSecureInputState(),
            resolver: resolver,
            targetResolution: targetResolution,
            panel: panel,
            pipeline: pipeline,
            recorder: ledger,
            sessionBox: sessionBox,
            toggleConfiguration: toggleConfiguration,
            toggleSource: RecordingAudioSource(),
            toggleTimer: FakeTimer(),
            runningAppName: FakeRunningAppName(),
            widgetClock: FakeTimer(),
            liveLevel: BenchmarkLevelSource(level: 0),
            holdFeed: microphone.feed)
        root.markEnginePrepared()
        sink.store = root.widgetStore
        // The shipped default mode is `.toggle`; this test drives the hold-to-talk machine, so
        // the mode is switched first — which is also the exercise of the mode-routing hook: the
        // router's active feed follows the mode (the §2c note's slot, set by the root).
        root.setActiveMode(.holdToTalk)

        // 1. Key-down → `.opening` → the feed is armed, at the pinned cadence.
        keyboard.hold(configuration)
        _ = root.holdToTalk.scheduledWatchdog.receive(
            keyEvent(.keyDown, configuration: configuration, at: clock.now))
        XCTAssertEqual(
            feedTimer.startCount, 1,
            "the feed is armed by `.opening` — a session that reaches `.recording` has been "
                + "draining since key-down")
        XCTAssertEqual(
            feedTimer.cadencesRequested, [SpeculativeFeed.cadence],
            "the feed ticks at the single-source-pinned cadence, never another")

        // 2. A scripted growing buffer, fired between feed ticks. The sub-minimum holds the
        //    first tick: nothing reaches the store before the threshold, and nothing empty does.
        write([1, 2], to: graph.ring)
        feedTimer.tick()
        XCTAssertNil(
            root.widgetStore.state.partialText,
            "no partial before the sub-minimum threshold — the first tick is held back")
        write([3, 4], to: graph.ring)
        feedTimer.tick()
        write([5, 6], to: graph.ring)
        feedTimer.tick()
        write([7, 8], to: graph.ring)
        XCTAssertNil(
            root.widgetStore.state.partialText,
            "nothing is presented mid-session before the terminal — the route runs at key-up")

        // 3. Key-up → `.ended(.completed)`: the router terminates the feed (appending the
        //    remainder `endCapture` drained) and routes the stream.
        _ = root.holdToTalk.scheduledWatchdog.receive(
            keyEvent(.keyUp, configuration: configuration, at: clock.now))
        keyboard.release(49)

// 4. The final lands: the route reaches the injector — parked there before recording,
        //    so the guard is asserted deterministically: while the route holds the final, the
        //    injector's ledger is empty, the partials are in the store (the sink→store wiring is
        //    live; the reducer keeps provisional text in RECORDING and TRANSCRIBING), and
        //    nothing has been delivered yet.
        var turns = 0
        var parked = await injector.parked
        while parked == 0 && turns < 20_000 {
            await Task.yield()
            turns += 1
            parked = await injector.parked
        }
        let callsBeforeFinal = await injector.callCount
        XCTAssertEqual(
            callsBeforeFinal, 0,
            "the guard at the wiring level: zero injector calls before the final — the route is "
                + "holding the final, and the ledger is still empty")
        XCTAssertEqual(
            root.widgetStore.state.partialText, "hello ",
            "the scripted partials reached the widget store — the sink→store wiring is live")
        await injector.openGate()

        // 5. The final's injection: exactly one call, carrying the batch result for the same
        //    audio — `StubEngine.text`'s deterministic transcription of the scripted samples,
        //    hand-computed — and the store's provisional text is cleared on the terminal
        //    adoption (never into DELIVERED).
        turns = 0
        var injected = await injector.callCount
        while injected < 1 && turns < 20_000 {
            await Task.yield()
            turns += 1
            injected = await injector.callCount
        }
        let calls = await injector.calls
        XCTAssertEqual(
            calls.map(\.text), ["1 2 3 4 5 6 7 8"],
            """
            Exactly one injector call, carrying the final — whose text equals the batch result \
            for the same audio ("1 2 3 4 5 6 7 8": the samples joined with spaces). The feed \
            must be invisible to a batch engine: the whole audio, in order, through the stream.
            """)
        XCTAssertEqual(
            calls.map(\.target),
            [TargetContext(bundleID: "com.example.Notes", windowTitle: "The Draft", isSecureInput: false)],
            "the injection lands in the context resolved at key-down")
        guard case .delivered = root.widgetStore.state.state else {
            return XCTFail("the delivered transcript is the session's terminal display state")
        }
        XCTAssertNil(
            root.widgetStore.state.partialText,
            "no provisional text survives into DELIVERED — the final is the only text there")
        XCTAssertEqual(feedTimer.stopCount, 1, "the feed's timer is stopped exactly once, at the terminal")

        // 6. Nothing after: a second injection never lands.
        turns = 0
        while turns < 500 {
            await Task.yield()
            turns += 1
        }
        let finalCount = await injector.callCount
        XCTAssertEqual(
            finalCount, 1,
            "no second injection — the final is the stream's only route to the injector")
    }

    // MARK: - Terminal cancellation completeness (phase (d))

    /// **Escape mid-session** — `handleSessionCancelKey` → the machine's `cancel()` →
    /// `.ended(.userCancelled)`: the feed is cancelled (timer stopped once, stream finished with
    /// nothing appended), the batch route's cancelled row finalizes `.aborted`, and the
    /// injector's ledger is never touched after the cancellation.
    func testEscapeMidSessionCancelsTheFeedAndNeverTouchesTheInjector() async throws {
        let harness = try Harness(prepared: true)
        harness.useHoldMode()
        harness.press()
        write([1, 2], to: harness.graph.ring)
        harness.feedTimer.tick()
        write([3, 4], to: harness.graph.ring)
        harness.feedTimer.tick()

        _ = harness.root.cancel()

        try await harness.drain(until: { await harness.ledger.snapshot().count == 1 })
        XCTAssertEqual(harness.feedTimer.stopCount, 1, "the cancelled session stops the feed exactly once")
        let chunks = await Self.collect(harness.holdFeed.chunks)
        XCTAssertEqual(
            chunks.map(\.samples), [[1, 2, 3, 4]],
            "the chunks yielded before the cancellation are the stream's whole content — cancel "
                + "appends nothing to it")
        let after = await Self.collect(harness.holdFeed.chunks)
        XCTAssertTrue(
            after.isEmpty,
            "the chunk stream terminates — nothing is yielded after the cancellation")
        let calls = await harness.injector.calls
        XCTAssertEqual(
            calls, [],
            "the injector is never touched after the cancellation — Esc is a discard, not a delivery")
        let records = await harness.ledger.snapshot()
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(
            record.outcome, .aborted,
            "the cancelled row stays on the batch route: `.aborted`, never `.emptySkip`")
    }

    /// **`.captureUnavailable`** — the readiness gate refuses (the harness never marks the engine
    /// prepared), so the session never begins: the feed is cancelled, the stream is finished
    /// with nothing appended, and the refusal finalizes `.failed` — no session record leaks.
    func testCaptureUnavailableCancelsTheFeedAndFinalizesFailed() async throws {
        let harness = try Harness(prepared: false)
        harness.useHoldMode()
        harness.press()

        XCTAssertEqual(harness.feedTimer.startCount, 1, "the feed was armed at `.opening`")
        try await harness.drain(until: { await harness.ledger.snapshot().count == 1 })
        XCTAssertEqual(harness.feedTimer.stopCount, 1, "the refusal stops the feed exactly once")
        let chunks = await Self.collect(harness.holdFeed.chunks)
        XCTAssertTrue(chunks.isEmpty, "a capture that never happened appends nothing")
        let records = await harness.ledger.snapshot()
        XCTAssertEqual(
            records.count, 1,
            "the refusal finalizes exactly one record — nothing stays in flight")
        XCTAssertEqual(
            records.first?.outcome, .failed,
            "a capture that never happened is finalized failed, attributed to no engine")
    }

    /// **Every retained end reason, closed set.** The PRD names `.keyUp`, `.toggledOff`,
    /// `.ceilingReached` and `.pollDetectedRelease` as if exhaustive; `.modifierReleased`,
    /// `.tapDisabled` and every `SystemTrigger` are terminals too. All of them flow through the
    /// same `.ended(.completed)` row — so every one must end with the feed stopped exactly once,
    /// the stream finished, and exactly one final routed (the `.completed` path, the same as
    /// key-up). The test enumerates the closed set rather than trusting the router to.
    func testEveryRetainedEndReasonEndsWithTheFeedStoppedAndExactlyOneFinalRouted() async throws {
        let rows: [(reason: RetainedEndReason, drive: (Harness) -> Void)] = [
            (.keyUp, { $0.keyUp() }),
            (.modifierReleased, { $0.modifierReleased() }),
            (.tapDisabled, { $0.tapDisabled() }),
            (.ceilingReached, { $0.ceilingReached() }),
            (.pollDetectedRelease, { $0.pollDetectedRelease() }),
            (.toggledOff, { $0.toggledOff() }),
            (.systemEvent(.willSleep), { $0.systemTrigger() }),
        ]

        for row in rows {
            let harness = try Harness(prepared: true)
            let isToggle = row.reason == .toggledOff
            let ring = isToggle ? harness.toggleGraph.ring : harness.graph.ring
            let feedTimer = isToggle ? harness.toggleFeedTimer : harness.feedTimer
            if !isToggle {
                harness.useHoldMode()
            }
            // One machine per row — at most one session in flight, the machine's own invariant:
            // the toggle row presses the toggle machine, every other row the hold machine.
            if isToggle {
                harness.pressToggle()
            } else {
                harness.press()
            }
            write([1, 2], to: ring)
            feedTimer.tick()
            write([3, 4], to: ring)
            feedTimer.tick()
            write([5, 6], to: ring)
            feedTimer.tick()
            write([7, 8], to: ring)

            row.drive(harness)

            try await harness.drain(until: { await harness.injector.callCount == 1 })
            XCTAssertEqual(
                feedTimer.stopCount, 1,
                "\(row.reason): the terminal stops the feed exactly once")
            let calls = await harness.injector.calls
            XCTAssertEqual(
                calls.map(\.text), ["1 2 3 4 5 6 7 8"],
                "\(row.reason): exactly one final routed, carrying the batch result — the same "
                    + ".completed path as key-up")
            let records = await harness.ledger.snapshot()
            XCTAssertEqual(
                records.count, 1, "\(row.reason): exactly one record — nothing left in flight")
            guard case .some(.delivered) = records.first?.outcome else {
                return XCTFail("\(row.reason): the completed session must be delivered")
            }
            let feed = isToggle ? harness.toggleFeed : harness.holdFeed
            let chunks = await Self.collect(feed.chunks)
            XCTAssertTrue(
                chunks.isEmpty,
                "\(row.reason): the stream was consumed by the route and is finished — "
                    + "nothing is left to strand")
        }
    }

    /// **A terminal arriving mid-drain-tick cannot strand a chunk.** A stop event and a feed
    /// tick are both main-actor and therefore serialized (the `SessionWatchdog.wake() →
    /// machine.tick()` ordering pin). The observable contract, proven through the composed
    /// root with a recording engine: the engine receives exactly the chunks before the terminal
    /// plus the remainder — nothing more, nothing stranded — the stream ended exactly once.
    func testATerminalMidDrainTickCannotStrandAChunk() async throws {
        let recorder = RecordingStreamEngine()
        let harness = try Harness(prepared: true, engine: recorder)
        harness.useHoldMode()
        harness.press()
        write([1, 2], to: harness.graph.ring)
        harness.feedTimer.tick()
        // Captured but never ticked — the terminal lands mid-drain, before the next tick.
        write([3, 4], to: harness.graph.ring)

        harness.keyUp()

        try await harness.drain(until: { await harness.injector.callCount == 1 })
        let calls = await harness.injector.calls
        XCTAssertEqual(
            calls.map(\.text), ["1 2 3 4"],
            "the final is the deterministic transcription of the audio the engine actually "
                + "received — the whole session, in order")
        let received = await recorder.received
        XCTAssertEqual(
            received, [[1, 2], [3, 4]],
            "the engine received exactly the tick's chunk and the endCapture remainder — "
                + "nothing stranded at the terminal, nothing yielded after it")
        XCTAssertEqual(
            harness.feedTimer.stopCount, 1,
            "the terminal stops the feed exactly once — the stream ended exactly once")
    }

    // MARK: - Helpers

    /// **The recording engine** — a streaming engine whose final is derived from the audio it
    /// actually received (the `StubEngine.text` deterministic transcription), and whose received
    /// chunk ledger is read back by the test. This is the strongest form of the
    /// batch-equivalence claim: the final's text is the batch result of exactly the samples the
    /// engine saw, and the ledger proves nothing was stranded at the terminal.
    private actor RecordingStreamEngine: ASREngine {
        let identity = EngineIdentity(
            id: "recording-stream-engine", displayName: "Recording stream engine", isLocal: true)
        let supportsStreaming = true
        private(set) var received: [[Float]] = []

        func prepare() async throws {}

        func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
            Transcript(
                text: Self.text(for: buffer.samples), segments: [], engine: identity,
                isFinal: true, audioDuration: buffer.audioDuration)
        }

        nonisolated func stream(
            _ chunks: AsyncStream<AudioBuffer>
        ) -> AsyncThrowingStream<Transcript, Error> {
            AsyncThrowingStream { continuation in
                let task = Task { await self.run(chunks, continuation: continuation) }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
        }

        private func run(
            _ chunks: AsyncStream<AudioBuffer>,
            continuation: AsyncThrowingStream<Transcript, Error>.Continuation
        ) async {
            var all: [Float] = []
            for await chunk in chunks {
                received.append(chunk.samples)
                all.append(contentsOf: chunk.samples)
            }
            continuation.yield(Transcript(
                text: Self.text(for: all), segments: [], engine: identity,
                isFinal: true, audioDuration: 0))
            continuation.finish()
        }

        /// The deterministic transcription: `[1, 2, 3]` becomes `"1 2 3"` — the `StubEngine`
        /// rule, so the batch result of the same audio is the same string.
        private static func text(for samples: [Float]) -> String {
            samples.map { String(Int($0)) }.joined(separator: " ")
        }
    }

    /// The composed harness the closed-set rows share: the `BenchmarkHarness` shape with **both**
    /// feeds wired (hold and toggle, each with its own fake timer), a scripted streaming engine
    /// whose final is the deterministic batch result of the scripted samples (or a caller-built
    /// recording engine), an ungated ledger injector, and the real widget store fed by the sink.
    @MainActor
    private final class Harness {
        let clock = BenchmarkClock()
        let keyboard = Keyboard()
        let ledger = LatencyLedger()
        let sessionBox = LatencySessionBox()
        let graph: BenchmarkGraph
        let toggleGraph: BenchmarkGraph
        let feedTimer = FakeTimer()
        let toggleFeedTimer = FakeTimer()
        let watchdogTimer: FakeTimer
        let injector: IntegrationLedgerInjector
        let root: DictationLoopRoot
        let holdFeed: SpeculativeFeed
        let toggleFeed: SpeculativeFeed
        let engine: any ASREngine
        let configuration: HotkeyConfiguration
        let toggleConfiguration: HotkeyConfiguration

        init(prepared: Bool, engine: (any ASREngine)? = nil) throws {
            configuration = HotkeyConfiguration(
                keyCode: 49, modifiers: [.option], activation: .holdToTalk)
            toggleConfiguration = HotkeyConfiguration(
                keyCode: 49, modifiers: [.option], activation: .toggle)
            graph = BenchmarkGraph(
                ring: AudioRingBuffer(capacity: 1 << 12), clock: clock,
                stopAdvance: .milliseconds(3))
            let microphone = try MicrophoneSource(
                graph: graph,
                recorder: ledger,
                clock: clock,
                sessionIDProvider: { [sessionBox] in sessionBox.sessionID },
                feedSchedule: (schedule: { [feedTimer] in feedTimer.start(every: $0, $1) }, unschedule: { [feedTimer] in feedTimer.stop() }),
                feedSubMinimum: { $0 < 4 })
            toggleGraph = BenchmarkGraph(
                ring: AudioRingBuffer(capacity: 1 << 12), clock: clock,
                stopAdvance: .milliseconds(3))
            let toggleMicrophone = try MicrophoneSource(
                graph: toggleGraph,
                recorder: ledger,
                clock: clock,
                sessionIDProvider: { [sessionBox] in sessionBox.sessionID },
                feedSchedule: (schedule: { [toggleFeedTimer] in toggleFeedTimer.start(every: $0, $1) }, unschedule: { [toggleFeedTimer] in toggleFeedTimer.stop() }),
                feedSubMinimum: { $0 < 4 })
            holdFeed = microphone.feed
            toggleFeed = toggleMicrophone.feed
            let shipped = StreamingStubEngine(
                identity: EngineIdentity(
                    id: "speculative-feed-integration-engine",
                    displayName: "Speculative feed integration engine", isLocal: true),
                partials: ["hel", "hello "],
                finalText: "1 2 3 4 5 6 7 8")
            self.engine = engine ?? shipped
            let engine = self.engine
            injector = IntegrationLedgerInjector(gated: false)
            let sink = StoreFoldingPartialSink()
            let pipeline = DictationPipeline(
                engine: engine, injector: injector, holder: BenchmarkHolder(),
                recorder: ledger, clock: clock, partialSink: sink)
            let resolver = DictationEngineResolver(selection: .defaultSelection) { _ in engine }
            let targetResolution = TargetResolution(
                focusedApp: FakeFocusedApp(
                    identity: FocusedAppIdentity(
                        bundleID: "com.example.Notes", windowTitle: "The Draft")),
                secureInput: FakeSecureInput())
            let watchdogTimer = FakeTimer()
        self.watchdogTimer = watchdogTimer
        root = DictationLoopRoot(
                configuration: configuration,
                ceiling: SessionCeiling.default,
                clock: clock,
                audioSource: microphone,
                keyState: TruthfulKeyState(keyboard),
                watchdogTimer: watchdogTimer,
                healthTimer: FakeTimer(),
                deferOpening: { $0() },
                tap: FakeHotkeyEventSource(),
                secureInput: FakeSecureInputState(),
                resolver: resolver,
                targetResolution: targetResolution,
                panel: RecordingPanel(holder: BenchmarkHolder()),
                pipeline: pipeline,
                recorder: ledger,
                sessionBox: sessionBox,
                toggleConfiguration: toggleConfiguration,
                toggleSource: RecordingAudioSource(),
                toggleTimer: FakeTimer(),
                runningAppName: FakeRunningAppName(),
                widgetClock: FakeTimer(),
                liveLevel: BenchmarkLevelSource(level: 0),
                holdFeed: holdFeed,
                toggleFeed: toggleFeed)
            sink.store = root.widgetStore
            if prepared {
                root.markEnginePrepared()
            }
        }

        /// The hold-to-talk machine, and the router's active feed with it (the mode-routing
        /// hook). The shipped default mode is `.toggle`; the hold rows switch first.
        func useHoldMode() {
            root.setActiveMode(.holdToTalk)
        }

        /// Key-down into the toggle machine — `.opening` arms the toggle feed (the shipped
        /// default mode routes to it).
        func pressToggle() {
            keyboard.hold(toggleConfiguration)
            _ = root.toggle.scheduledWatchdog.receive(
                RawKeyEvent(
                    kind: .keyDown, keyCode: toggleConfiguration.keyCode,
                    modifiers: toggleConfiguration.modifiers, isAutorepeat: false,
                    timestamp: clock.now))
        }

        /// Key-down into the hold machine — `.opening` arms the hold feed.
        func press() {
            keyboard.hold(configuration)
            _ = root.holdToTalk.scheduledWatchdog.receive(
                RawKeyEvent(
                    kind: .keyDown, keyCode: configuration.keyCode,
                    modifiers: configuration.modifiers, isAutorepeat: false, timestamp: clock.now))
        }

        func keyUp() {
            _ = root.holdToTalk.scheduledWatchdog.receive(
                RawKeyEvent(
                    kind: .keyUp, keyCode: configuration.keyCode,
                    modifiers: configuration.modifiers, isAutorepeat: false, timestamp: clock.now))
            keyboard.release(configuration.keyCode)
        }

        /// Stop rule (b)/(c): the configured modifier comes up — a `.flagsChanged` with none of
        /// the binding's modifiers carried.
        func modifierReleased() {
            _ = root.holdToTalk.scheduledWatchdog.receive(
                RawKeyEvent(
                    kind: .flagsChanged, keyCode: configuration.keyCode, modifiers: [],
                    isAutorepeat: false, timestamp: clock.now))
        }

        /// Stop rule (d): the OS disabled the event tap.
        func tapDisabled() {
            _ = root.holdToTalk.scheduledWatchdog.receive(
                RawKeyEvent(
                    kind: .tapDisabled, keyCode: configuration.keyCode, modifiers: [],
                    isAutorepeat: false, timestamp: clock.now))
        }

        /// Stop rule (e): the session hit its ceiling — the watchdog's own timer fires past it.
        func ceilingReached() {
            clock.now += SessionCeiling.default + WatchdogPolicy.pollInterval
            watchdogTimer.tick()
        }

        /// Stop rule (f): the physical-key poll finds the binding released.
        func pollDetectedRelease() {
            keyboard.release(configuration.keyCode)
            watchdogTimer.tick()
        }

        /// Toggle mode: the next matching key-down while recording.
        func toggledOff() {
            _ = root.toggle.scheduledWatchdog.receive(
                RawKeyEvent(
                    kind: .keyDown, keyCode: toggleConfiguration.keyCode,
                    modifiers: toggleConfiguration.modifiers, isAutorepeat: false,
                    timestamp: clock.now))
        }

        /// One system trigger — the closed set's representative: the machine is about to sleep.
        func systemTrigger() {
            _ = root.observe(.willSleep)
        }

        func drain(until condition: @escaping () async -> Bool) async throws {
            var attempts = 0
            while !(await condition()) && attempts < 20_000 {
                await Task.yield()
                attempts += 1
            }
            let held = await condition()
            XCTAssertTrue(held, "the condition did not hold within 20 000 turns")
        }
    }

    /// One recorded injection — the ledger injector's row.
    private struct RecordedIntegrationInjection: Equatable {
        let text: String
        let target: TargetContext
    }

    /// The injector, with a ledger — the `LedgerInjectorDouble` shape: every call recorded in
    /// order, so "never called before the final" is an assertion on a counter rather than an
    /// absence the test cannot see. **Gated** (the default) so the guard is deterministic:
    /// `inject` parks before recording, so a test that observes `parked == 1` is guaranteed to
    /// find an empty ledger — the route is holding the final, and the injection has not happened.
    /// Ungated for the closed-set rows, where each row's ledger is read after the route settled.
    private actor IntegrationLedgerInjector: TextInjector {
        private let gated: Bool
        private(set) var calls: [RecordedIntegrationInjection] = []
        private(set) var parked = 0
        private var gate: CheckedContinuation<Void, Never>?

        init(gated: Bool = true) {
            self.gated = gated
        }

        var callCount: Int { calls.count }

        func inject(_ text: String, into target: TargetContext) async -> InjectionResult {
            if gated {
                parked += 1
                await withCheckedContinuation { gate = $0 }
            }
            calls.append(RecordedIntegrationInjection(text: text, target: target))
            return InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false, elapsed: .zero)
        }

        func openGate() {
            gate?.resume()
            gate = nil
        }
    }

    /// The sink→store wiring, as the composition root wires it — the `WidgetStorePartialSink`
    /// shape: a mutex count, a weak store box filled after the root is built, and the fold
    /// dispatched to the main actor (the store's one isolation domain).
    private final class StoreFoldingPartialSink: PartialTranscriptSink, @unchecked Sendable {
        private let countLock = NSLock()
        private var count = 0
        weak var store: WidgetStateStore?

        func presentPartial(_ partial: String) {
            countLock.lock()
            count += 1
            countLock.unlock()
            Task { @MainActor in
                store?.presentPartial(partial)
            }
        }
    }

    /// The collected chunks of a finished stream — the stream is single-shot and buffers its
    /// yields, so iterating after the route consumed it sees everything (and a second iteration
    /// sees nothing: the stream ended exactly once).
    @MainActor
    private static func collect(_ stream: AsyncStream<AudioBuffer>) async -> [AudioBuffer] {
        var chunks: [AudioBuffer] = []
        for await chunk in stream {
            chunks.append(chunk)
        }
        return chunks
    }

    /// Write `samples` into `ring` the way the realtime producer would — whole blocks, refused
    /// whole when there is no room.
    private func write(_ samples: [Float], to ring: AudioRingBuffer) {
        _ = samples.withUnsafeBufferPointer { pointer in
            ring.write(pointer.baseAddress!, count: pointer.count)
        }
    }

    private func keyEvent(
        _ kind: RawKeyEvent.Kind, configuration: HotkeyConfiguration, at timestamp: Duration
    ) -> RawKeyEvent {
        RawKeyEvent(
            kind: kind, keyCode: configuration.keyCode, modifiers: configuration.modifiers,
            isAutorepeat: false, timestamp: timestamp)
    }
}