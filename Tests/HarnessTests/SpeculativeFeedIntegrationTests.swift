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

    // MARK: - Helpers

    /// One recorded injection — the ledger injector's row.
    private struct RecordedIntegrationInjection: Equatable {
        let text: String
        let target: TargetContext
    }

    /// The injector, with a ledger — the `LedgerInjectorDouble` shape: every call recorded in
    /// order, so "never called before the final" is an assertion on a counter rather than an
    /// absence the test cannot see. **Gated** so the guard is deterministic: `inject` parks
    /// before recording, so a test that observes `parked == 1` is guaranteed to find an empty
    /// ledger — the route is holding the final, and the injection has not happened.
    private actor IntegrationLedgerInjector: TextInjector {
        private(set) var calls: [RecordedIntegrationInjection] = []
        private(set) var parked = 0
        private var gate: CheckedContinuation<Void, Never>?

        var callCount: Int { calls.count }

        func inject(_ text: String, into target: TargetContext) async -> InjectionResult {
            parked += 1
            await withCheckedContinuation { gate = $0 }
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