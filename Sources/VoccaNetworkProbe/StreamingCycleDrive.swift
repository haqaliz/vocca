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

import Dispatch
import Foundation
import Synchronization
import VoccaASR
import VoccaAudio
import VoccaBootstrap
import VoccaCore
import VoccaInject
import VoccaText
import VoccaUI

// The probe's half of the zero-network invariant for the `widget-streaming` wiring (S4's tail):
// the pipeline's widget-only sink folded into the widget store, exercised end to end.
//
// `DictationCycleDrive` proves the **batch** route through the composed root; this drive proves
// the **streaming** route over the same composition — a streaming stub engine in the resolver's
// slot, a scripted chunk source handed to `DictationPipeline.routeStreaming`, and the partial
// sink wired to the root's widget store. Nothing else differs: the ladder is the real
// `LadderInjector` over the probe's rung fakes, the cleanup stage is the real rules resolver over
// an isolated throwaway directory, the latency ledger records the route's one finalized record,
// and the download session is a ledger whose `starts=0` is read back into the report.
//
// **Nothing here needs a permission and nothing here can reach the network** — the same charter
// as the cycle drive. The streaming route adds no network name (the `CoreBoundaryTests` rule:
// no Foundation/Dispatch/Darwin in `VoccaCore`), and the fold the partials land in is the
// widget store's own, on the main actor. The interposer's `connect(2)` observation is the
// suite's assertion, not a belief.

// MARK: - The seams the streaming cycle needs

/// **The ASR engine, with streaming in it** — the probe's stand-in for a future streaming
/// engine, in the ``StreamingStubEngine`` shape (`ASRTestDoubles.swift:126-239`): a scripted
/// sequence of partial transcripts (`isFinal == false`), then exactly one final transcript.
///
/// Deliberately **not** the batch shape: this drive exists to exercise the streaming route, and
/// the batch default is the cycle drive's half of the story (its report's `engine.transcribes=1`
/// is the seam's default measured through the composed root). The ledgers — ``prepareCount``,
/// ``transcribeCalls`` — are the report's observables: the streaming path must never prepare
/// (preparation is the launch path's job, pinned by the warm-start aspect) and must never fall
/// back to `transcribe`.
actor ProbeStreamingEngine: ASREngine {

    /// A deterministic identity, distinct from both shipped engines' and from the cycle drive's
    /// stub — the report's attribution is this id, so a composition that quietly built the real
    /// engine would be caught by the identity alone.
    let identity: EngineIdentity

    /// `true` — this is the streaming half; the batch default is ``ProbeEngine``'s, and both
    /// shapes must terminate the same way: partials, then exactly one final.
    let supportsStreaming = true

    /// The scripted partials, yielded in order before the final.
    private let partials: [String]

    /// The scripted final transcript's text, yielded after the partials.
    private let finalText: String

    /// How many times `prepare()` was called — the report's `engine.prepares=` field. The
    /// streaming drive never prepares; the observable count is what makes that a fact.
    private(set) var prepareCount = 0

    /// How many times `transcribe(_:)` was called — the report's `engine.transcribes=` field: a
    /// streaming route that fell back to the batch call would show a non-zero count here.
    private(set) var transcribeCalls = 0

    init(identity: EngineIdentity, partials: [String], finalText: String) {
        self.identity = identity
        self.partials = partials
        self.finalText = finalText
    }

    func prepare() async throws {
        prepareCount += 1
    }

    func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        transcribeCalls += 1
        return Transcript(
            text: finalText, segments: [], engine: identity, isFinal: true,
            audioDuration: buffer.audioDuration)
    }

    /// `nonisolated` for the reason `StreamingStubEngine` documents: the seam's `stream` is a
    /// synchronous requirement, and the producer task carries the asynchrony.
    nonisolated func stream(
        _ chunks: AsyncStream<AudioBuffer>
    ) -> AsyncThrowingStream<Transcript, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.runStream(chunks, continuation: continuation)
            }
            // A consumer that stops early must not leave the scripted task pending.
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// The scripted stream body: drain the chunks, yield the partials, then yield the final.
    /// Every stop observes cancellation — a cancelled stream finishes by throwing
    /// ``CancellationError``, so the route's discard path is exercised honestly.
    private func runStream(
        _ chunks: AsyncStream<AudioBuffer>,
        continuation: AsyncThrowingStream<Transcript, Error>.Continuation
    ) async {
        for await _ in chunks {
            guard !Task.isCancelled else {
                continuation.finish(throwing: CancellationError())
                return
            }
        }
        guard !Task.isCancelled else {
            continuation.finish(throwing: CancellationError())
            return
        }
        for partial in partials {
            guard !Task.isCancelled else {
                continuation.finish(throwing: CancellationError())
                return
            }
            continuation.yield(Transcript(
                text: partial, segments: [], engine: identity, isFinal: false,
                audioDuration: 0))
        }
        continuation.yield(Transcript(
            text: finalText, segments: [], engine: identity, isFinal: true, audioDuration: 0))
        continuation.finish()
    }
}

/// **The widget-streaming wiring's sink→store adapter** — the pipeline's widget-only sink
/// (`PartialTranscriptSink`) folded into the root's `@MainActor` widget store.
///
/// The pipeline is assembled *before* the root (the composition root's `pipelineAssembly`
/// shape), and the store is created *by* the root's initializer — so the store is reached
/// through a weak box filled after the root is built. Weak, like every box in this module: the
/// root owns the store, and the sink must not extend its lifetime.
///
/// The dispatch is fire-and-forget by the seam's own contract (`PartialTranscriptSink`'s
/// documentation): emitting adds no suspension to the streaming path, and the fold lands on the
/// main actor — the store's one isolation domain. The drive drains until the store carries the
/// last partial, which is the dispatched folds' observable landing point.
///
/// `@unchecked Sendable` is the claim `LedgerPartialSink` makes for the same reason: the
/// protocol's `presentPartial` is synchronous, so an actor double cannot witness it honestly;
/// the mutex serializes the counter and the box is written once, before any partial can arrive.
final class WidgetStorePartialSink: PartialTranscriptSink, @unchecked Sendable {
    private let countLock = Mutex(0)

    /// The root's widget store, filled after the root is built. `nil` until then, and a sink
    /// whose box was never filled presents partials to nothing — the honest absent-store answer.
    weak var store: WidgetStateStore?

    /// How many partials the pipeline presented — the report's `partials=` field: the store
    /// keeps only the newest partial, so the presentation count is the witness that **each**
    /// partial reached the wiring.
    var presentationCount: Int {
        countLock.withLock { $0 }
    }

    func presentPartial(_ partial: String) {
        countLock.withLock { $0 += 1 }
        Task { @MainActor in
            store?.presentPartial(partial)
        }
    }
}

// MARK: - The drive

/// One recorded injection — the row the pipeline's injector call leaves in the ledger. The
/// cycle drive's `InjectionObservation` shape, local to this file: the two drives' row types
/// are private to their files, so this one cannot drift from the drive that records it.
private struct StreamingInjectionObservation {
    let text: String
    let target: TargetContext
    let result: InjectionResult
}

/// The injector, with a ledger in front of the ladder — the cycle drive's
/// `ProbeInjectorLedger` shape, local to this file for the same file-scoped reason: every call
/// the pipeline made is recorded, and the ladder's own answer is returned unchanged.
actor StreamingInjectorLedger: TextInjector {
    private let inner: any TextInjector
    private var calls: [StreamingInjectionObservation] = []

    init(inner: any TextInjector) {
        self.inner = inner
    }

    func inject(_ text: String, into target: TargetContext) async -> InjectionResult {
        let result = await inner.inject(text, into: target)
        calls.append(StreamingInjectionObservation(text: text, target: target, result: result))
        return result
    }

    /// The ledger read — every recorded call, in order.
    fileprivate var recorded: [StreamingInjectionObservation] {
        calls
    }
}

extension VoccaNetworkProbe {

    /// The streaming cycle's observation, as one line of `key=value` fields. Asserted whole —
    /// see `ZeroNetworkTests.expectedStreamingCycleLifecycle`.
    struct StreamingCycleReport {
        let report: String
    }

    /// The scripted utterance the streaming cycle carries, spelled once here so the expected
    /// report and the script cannot drift.
    static let streamingPartials = ["hel", "hello "]
    static let streamingFinalText = "hello world"

    /// **Drives one streaming dictation cycle through the composed root, and reports what
    /// happened.**
    ///
    /// The composition is the root `AppBootstrap.configure` builds — same type, same recipe —
    /// with probe fakes in every adapter slot CI cannot touch. The cycle: the streaming stub
    /// engine in the resolver's slot, a scripted chunk source handed to the pipeline's
    /// ``DictationPipeline/routeStreaming(chunks:target:sessionID:)`` (the live feed is out of
    /// scope — this unit's chunk source is scripted by construction), each partial folded into
    /// the widget store through the sink, and the one final routed through the real cleanup
    /// stage and the real ladder into the injector.
    ///
    /// Nothing here asserts. The probe reports and the suite asserts, for the same reason every
    /// other drive gives.
    static func exerciseStreamingCycle() -> StreamingCycleReport {
        let semaphore = DispatchSemaphore(value: 0)
        let box = StreamingCycleBox()
        Task { @MainActor in
            box.value = await buildStreamingCycle()
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return box.value!
    }

    /// Stores the drive's result across the `@Sendable` boundary. Main-thread-only; see the
    /// drive's own comment for why that makes the unchecked annotation honest.
    private final class StreamingCycleBox: @unchecked Sendable {
        var value: StreamingCycleReport?
    }

    /// Builds the composed root over probe fakes, drives one streaming cycle through it, and
    /// assembles the report.
    @MainActor
    private static func buildStreamingCycle() async -> StreamingCycleReport {
        let clock = ProbeClock()
        let ledger = LatencyLedger()
        let sessionBox = LatencySessionBox()

        // The microphones — the real `MicrophoneSource` over scripted graphs, exactly as the
        // cycle drive wires them. Neither is ever opened here: the streaming drive calls the
        // pipeline directly and never presses the hotkey, so the machines stay idle and the
        // graphs' ledgers stay at zero — the honest composition, not a shortcut.
        let graph = ProbeGraph()
        let microphone = try! MicrophoneSource(
            graph: graph,
            recorder: ledger,
            clock: clock,
            sessionIDProvider: { sessionBox.sessionID })
        let toggleGraph = ProbeGraph()
        let toggleMicrophone = try! MicrophoneSource(
            graph: toggleGraph,
            recorder: ledger,
            clock: clock,
            sessionIDProvider: { sessionBox.sessionID })

        // The engine lifecycle, with the builder substituted: every path that would construct a
        // real engine constructs the streaming stub instead, so a model download is structurally
        // unreachable from this composition.
        let engine = ProbeStreamingEngine(
            identity: EngineIdentity(
                id: "probe-streaming-engine", displayName: "Probe streaming engine", isLocal: true),
            partials: Self.streamingPartials,
            finalText: Self.streamingFinalText)
        let resolver = DictationEngineResolver(selection: .defaultSelection) { _ in engine }

        // The ladder: the real `LadderInjector` over the probe's rung fakes, with the shipped
        // seeded allowlist and the shared probe handoff — the cycle drive's exact wiring, so the
        // streaming final travels the same decision table the batch final does.
        let handoff = ProbeInjectionHandoff()
        let ladder = LadderInjector(
            strategies: [
                .clipboardPaste: ProbeInjectionStrategy(
                    rung: .clipboardPaste, outcome: .succeeded(verified: false)),
                .keystrokeSynthesis: ProbeInjectionStrategy(
                    rung: .keystrokeSynthesis, outcome: .failed),
            ],
            order: DefaultInjectionStrategyOrder(allowlist: SeededInjectionAllowlist()),
            handoff: handoff,
            clock: clock)
        let injectorLedger = StreamingInjectorLedger(inner: ladder)

        // The cleanup stage: the real resolver over an isolated throwaway directory whose absent
        // `cleanup-config.json` is the default configuration (rules, zero network) — the cycle
        // drive's exact wiring, so `injected` carries the cleaned final.
        let probeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-probe-\(UUID().uuidString)")
        let cleanupResolver = CleanupResolver(
            store: CleanupConfigStore(directory: probeDirectory, log: { _ in }),
            transport: { ProbeLLMTransport() },
            keyProvider: { ProbeKeyProvider() },
            log: { _ in })
        let cleanup = try! await cleanupResolver.resolve()

        // The sink: assembled with the pipeline, wired to the store after the root is built —
        // the store is the root's own, created inside its initializer.
        let sink = WidgetStorePartialSink()

        // The pipeline, injected — the `DictationLoopTests` shape, with the sink wired. The
        // ASR span is measured with the shipped `ContinuousMonotonicClock`, like the cycle
        // drive's.
        let pipeline = DictationPipeline(
            engine: engine, injector: injectorLedger, holder: handoff,
            recorder: ledger, clock: ContinuousMonotonicClock(), cleanup: cleanup,
            partialSink: sink)

        let targetResolution = TargetResolution(
            focusedApp: ProbeFocusedApp(
                identity: FocusedAppIdentity(
                    bundleID: "com.example.WordProcessor", windowTitle: "Document 1")),
            secureInput: ProbeSecureInputRead(active: false))

        let panel = ProbePanel()
        let downloadSession = ProbeDownloadSession()
        let appName = ProbeRunningAppName()

        let root = DictationLoopRoot(
            configuration: HotkeyConfiguration(
                keyCode: spaceKeyCode, modifiers: [.option], activation: .holdToTalk),
            ceiling: SessionCeiling.default,
            clock: clock,
            audioSource: microphone,
            keyState: ProbeKeyState(),
            watchdogTimer: ProbeTimer(),
            healthTimer: ProbeTimer(),
            deferOpening: { $0() },
            tap: ProbeTap(),
            secureInput: ProbeSecureInputState(),
            resolver: resolver,
            targetResolution: targetResolution,
            panel: panel,
            pipeline: pipeline,
            recorder: ledger,
            sessionBox: sessionBox,
            toggleConfiguration: HotkeyConfiguration(
                keyCode: spaceKeyCode, modifiers: [.option], activation: .toggle),
            toggleSource: toggleMicrophone,
            toggleTimer: ProbeTimer(),
            runningAppName: appName,
            widgetClock: ProbeTimer(),
            liveLevel: MicrophoneLevelSource(graph: graph),
            holdFeed: microphone.feed,
            toggleFeed: toggleMicrophone.feed)
        root.markEnginePrepared()
        sink.store = root.widgetStore

        // The widget's session state: partials are kept only while the widget is RECORDING or
        // TRANSCRIBING (the reducer's S3 rule), so the store adopts RECORDING before the route
        // runs — the state a live session's widget would already be in.
        root.widgetStore.fold(.state(.recording))

        // MARK: The cycle

        // The scripted chunk source — the live feed's stand-in, out of scope for this unit by
        // construction (spec: "the chunk source is scripted in this unit").
        let chunks = AsyncStream<AudioBuffer> { continuation in
            continuation.yield(AudioBuffer(
                samples: [1, 2, 3], sampleRate: AudioBuffer.interchangeSampleRate))
            continuation.finish()
        }
        let target = TargetContext(
            bundleID: "com.example.WordProcessor", windowTitle: "Document 1", isSecureInput: false)

        // The record the router would have minted at `.opening` — the streaming route's own
        // finalize row, closed exactly once.
        let sessionID = await ledger.beginSession()

        let surface = await pipeline.routeStreaming(
            chunks: chunks, target: target, sessionID: sessionID)

        // The sink's folds land on the main actor fire-and-forget; drain until the store
        // carries the **last partial** — the final transcript is never a partial, by the
        // seam's own contract (`isFinal == false` is the boundary the sink renders behind), so
        // the store's carried text settles on the script's last partial, not on the final.
        var turns = 0
        while root.widgetStore.state.partialText != Self.streamingPartials.last && turns < 20_000 {
            await Task.yield()
            turns += 1
        }

        let observation = await injectorLedger.recorded.first
        let prepares = await engine.prepareCount
        let transcribes = await engine.transcribeCalls
        let downloadStarts = await downloadSession.startCount()
        let holds = await handoff.held.count

        let recordCount: Int
        if let rootLedger = root.latencyLedger {
            recordCount = await rootLedger.snapshot().count
        } else {
            recordCount = 0
        }

        let fields = [
            "surface=\(describe(surface))",
            "partials=\(sink.presentationCount)",
            "partial.last=\(spell(root.widgetStore.state.partialText ?? ""))",
            "injected=\(spell(observation?.text ?? ""))",
            "rung=\(describe(observation?.result.rung))",
            "attempted=\(describe(observation?.result.attempted))",
            "engine.prepares=\(prepares)",
            "engine.transcribes=\(transcribes)",
            "download.starts=\(downloadStarts)",
            "holds=\(holds)",
            "records=\(recordCount)",
        ]

        return StreamingCycleReport(report: fields.joined(separator: " "))
    }

    // MARK: - Spelling the observation

    /// The stub's transcript spelling, space-free — the report grammar is space-separated
    /// `key=value` fields, so a text with spaces is reported without them.
    private static func spell(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "-")
    }

    /// Every `describe` below is an exhaustive switch written out by hand rather than
    /// `String(describing:)`, for the reason the other drives give: the markers the suite
    /// matches on are this package's own vocabulary.

    private static func describe(_ surface: PipelineSurface) -> String {
        switch surface {
        case .idle: return "idle"
        case .transcriptHeld: return "transcriptHeld"
        case .reasonOnly: return "reasonOnly"
        }
    }

    private static func describe(_ rung: InjectionRung) -> String {
        switch rung {
        case .accessibility: return "accessibility"
        case .clipboardPaste: return "clipboardPaste"
        case .keystrokeSynthesis: return "keystrokeSynthesis"
        case .widgetFailsafe: return "widgetFailsafe"
        }
    }

    private static func describe(_ rung: InjectionRung?) -> String {
        rung.map(describe) ?? "none"
    }

    private static func describe(_ attempted: [InjectionRung]?) -> String {
        attempted?.map(describe).joined(separator: ",") ?? "none"
    }
}