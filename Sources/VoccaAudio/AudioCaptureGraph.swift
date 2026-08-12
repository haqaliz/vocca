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

import AVFoundation
import Foundation

/// Why a capture graph could not be built or started.
///
/// Its own type rather than an `NSError` passed through, because the two failures below mean
/// different things to a user — one is "no input device", the other is "the device refused" — and
/// `CaptureStart.unavailable` is one bit. Phase 5 is what turns these into something the widget can
/// say; this phase only makes sure the distinction survives to it.
public enum AudioCaptureGraphError: Error, CustomStringConvertible {
    /// The input node reports a format no audio can arrive in — 0 Hz, or no channels.
    ///
    /// What a Mac with no input device answers, and what a hosted CI runner answers. It is a
    /// construction failure rather than a start failure because a graph built on it would declare a
    /// `CapturedAudioFormat` describing nothing.
    case noInputFormat(sampleRate: Double, channelCount: Int)

    /// `AVAudioEngine.start()` threw.
    case engineWouldNotStart(any Error)

    public var description: String {
        switch self {
        case .noInputFormat(let sampleRate, let channelCount):
            return
                "the input node reports \(sampleRate) Hz × \(channelCount) ch, which no audio can arrive in"
        case .engineWouldNotStart(let underlying):
            return "AVAudioEngine.start() failed: \(underlying)"
        }
    }
}

/// **The `AVAudioEngine` capture graph. The only file in this package CI cannot execute a line of.**
///
/// `AVAudioSinkNode` is unsupported in manual rendering mode and a hosted runner has no microphone,
/// so there is no offline equivalent of this path — not a permission problem like `hotkey-source`'s
/// tap, an architectural one. Every guard here is therefore a source lint, a type, or a review, and
/// never a passing test. Read that as the constraint it is: **anything in this file with a decision
/// in it is a decision nothing will ever check.**
///
/// So the decisions are not here. They are:
///
/// - the **channel policy** — interleave every channel, do not keep channel 0 — in
///   ``AudioBufferListInterleaver``, which a test drives with a hand-built `AudioBufferList`;
/// - the **format conversion** to 16 kHz mono, in ``AudioFormatConverter``, tested against synthetic
///   sine waves;
/// - the **overrun policy**, in ``AudioRingBuffer``, tested under TSan with two real threads.
///
/// What is left is this file: build the graph, start it, stop it. The realtime path does not exist
/// here at all — the sink node's block is ``AudioBufferListInterleaver/receive(timestamp:frameCount:audioBufferList:)``,
/// which lives in that type because it is the only place it can be owned without a cycle and the
/// only place its copy can be executed by a test (see its header for the measured leak that
/// decided it).
///
/// ## The shape, and why each part of it is fixed
///
/// - **`AVAudioSinkNode`, not `installTap(onBus:)`.** `installTap`'s `bufferSize` has a documented
///   range of [100, 400] ms and its block is *not* the realtime thread. Phase 3 measured what that
///   costs: first audio **104.5 ms** after `start()` returns through `installTap`, against **7.6 ms**
///   through a sink node — a 14× gap on the number P2's latency budget is spent from.
/// - **Connected at the input node's own output format.** The sink node does not convert. Handing it
///   any other format is how a graph silently produces nothing.
/// - **Engine, sink, interleaver and ring allocated for the object's lifetime.** Only
///   `start()`/`stop()` per press — never a graph rebuild, which `prd.md` M23 forbids and which
///   would put an allocation and a reconnect on the press path.
/// - **The engine is never left running between sessions.** `AVAudioEngine.h:465-466`: any time a
///   running engine has had its input node enabled, the microphone indicator appears. A warm engine
///   lights macOS's orange dot permanently — the single most damaging signal this product can emit,
///   and the reason start-on-demand is mandated rather than preferred.
///
/// ## `prepare()` is deliberately not called, and this is the amendment
///
/// `prd.md` M23 mandated *"`prepare()` after every stop"* as the mitigation for start-on-demand, on
/// intuition, before anything was measured. Phase 3 measured it
/// (`Scripts/measure-engine-start.sh prepare-matrix`, 30 rows per cell): with any realistic gap
/// between sessions it saves **7.6 ms off a ~114 ms start — 6.7%** — and costs **~55 ms of CPU**,
/// spent immediately after the user stops talking, which is precisely when ASR wants the core. Back
/// to back it saves 49 ms, but back to back is not a user pattern, and whatever it warms is torn
/// down inside one second.
///
/// **And the arithmetic is device-dependent**: on the built-in microphone array `prepare()` costs
/// **11.8 ms** rather than 55, against a 42 ms start. So it is not that `prepare()` is free there and
/// expensive here — it is that neither figure is worth a per-session cost paid at the worst moment.
///
/// M23 is amended in `prd.md` rather than implemented-and-flagged. The numbers are recorded in both
/// places on purpose: without them, someone re-adds `prepare()` from the same intuition in a year.
///
/// ## Isolation
///
/// Not `Sendable`, and it holds a `AVAudioEngine` which is not either. It belongs to whichever
/// domain the session lives in — `@MainActor`, alongside the tap, the machine and both timers. The
/// **sink block is the exception and is not in that domain**: CoreAudio calls it on its own realtime
/// thread, which is what every rule in ``AudioBufferListInterleaver`` is written for.
public final class AudioCaptureGraph {

    /// The engine. Built once; started and stopped per session.
    private let engine = AVAudioEngine()

    /// Held so the node is not deallocated while the engine references it.
    private var sink: AVAudioSinkNode?

    /// Where the realtime thread writes. Allocated once, for the app's lifetime.
    public let ring: AudioRingBuffer

    /// The channel policy and the scratch it needs.
    private let interleaver: AudioBufferListInterleaver

    /// **What is actually in the ring**, as a claim the rest of the package reads.
    ///
    /// Taken from the input node's own output format and from the same `channelCount` the
    /// interleaver was built with — not written out separately. That is the whole guard against the
    /// defect `plan_20260806.md` calls the one no test will catch: a declared `channelCount: 2` over
    /// a ring holding only channel 0 makes the downmix average channel 0 against itself. Here there
    /// is one number, used twice, and `AudioBufferListInterleavingTests` drives the interleaver at
    /// each channel count and reads the ring back.
    public let captureFormat: CapturedAudioFormat

    /// The observer token for `AVAudioEngineConfigurationChangeNotification`, removed on teardown.
    private var configurationObserver: (any NSObjectProtocol)?

    /// Whether the engine is running. Read rather than remembered — the engine is the only thing
    /// that knows, and a second flag beside it is the shape this package prohibits module-wide.
    public var isRunning: Bool { engine.isRunning }

    /// - Parameters:
    ///   - ringCapacity: samples the ring holds. A power of two; see ``AudioRingBuffer``.
    ///   - onConfigurationChange: called when the device graph is invalidated underneath a running
    ///     engine — a device unplugged, a default changed, a sample rate switched. **It must end the
    ///     session and keep the audio**, which is the existing `SystemTrigger.audioConfigurationChanged`
    ///     route; Phase 5 wires it. Called on whatever thread `NotificationCenter` delivers on, so a
    ///     conformance hops to the session's domain itself.
    public init(
        ringCapacity: Int,
        onConfigurationChange: @escaping @Sendable () -> Void
    ) throws {
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        let channelCount = Int(inputFormat.channelCount)
        guard inputFormat.sampleRate > 0, channelCount > 0 else {
            // A Mac with no input device, and every hosted CI runner. Refused at construction rather
            // than at `start()`, because a graph built on this would declare a `CapturedAudioFormat`
            // that describes nothing and hand it downstream.
            throw AudioCaptureGraphError.noInputFormat(
                sampleRate: inputFormat.sampleRate, channelCount: channelCount)
        }

        self.ring = AudioRingBuffer(capacity: ringCapacity)
        self.captureFormat = CapturedAudioFormat(
            sampleRate: inputFormat.sampleRate, channelCount: channelCount)

        // Headroom over what the unit says it will ask for. `maximumFramesToRender` is what the
        // input unit is configured for, and a device whose buffer frame size changes underneath a
        // running engine is a real thing — the configuration-change notification below is the same
        // event. Oversize is counted rather than trapped (`oversizedSampleCount`), and the headroom
        // is what makes the count expected to stay zero.
        let maximumFrameCount = max(Int(engine.inputNode.auAudioUnit.maximumFramesToRender), 4096)
        self.interleaver = AudioBufferListInterleaver(
            channelCount: channelCount, maximumFrameCount: maximumFrameCount, ring: self.ring)

        // **The block is the interleaver's `receive`, and it lives there on purpose — this is the
        // ownership decision, and it is a measured one.** `AVAudioSinkNode(receiverBlock:
        // self.render)` with a bound method on the graph captures the graph, so
        // graph → node → block → graph is a cycle and the graph's `deinit` never runs. The graph's
        // `deinit` is what stops the engine, and constraint 2 of `spec.md` is that a running
        // engine with input enabled lights macOS's orange microphone indicator — so that leak is
        // not a memory footnote, it is the privacy defect the constraint exists to prevent,
        // reached by the one route no test in this repository looks at. A 30-line probe against
        // the real framework confirmed it: `deinit` did not run at all, and with the block moved
        // to an object that holds no reference back, both objects released normally. `receive`
        // captures the interleaver, which holds the ring and nothing that holds it — the graph
        // stays releasable, and therefore its engine stoppable by release. The whole argument is
        // `AudioBufferListInterleaver`'s header, written where the block is.
        let sink = AVAudioSinkNode(receiverBlock: interleaver.receive)
        self.sink = sink
        engine.attach(sink)
        // The input node's OWN format. The sink node does not convert, so any other format here is a
        // graph that runs and produces nothing.
        engine.connect(engine.inputNode, to: sink, format: inputFormat)

        self.configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in
            onConfigurationChange()
        }
    }

    deinit {
        // Non-asserting, and it must stay that way: a `deinit` runs wherever the last release
        // happens, and this package has now been bitten four times by an isolation precondition
        // reached from one. The work is in `tearDown()`, named for what the deinit lint permits —
        // see its doc for why stopping the engine here is the whole of this object's point.
        tearDown()
    }

    /// Stop the engine and drop the configuration-change observer, asserting nothing.
    ///
    /// The deinit's route out, and the newest place this repository has needed exactly this shape:
    /// `AVAudioEngine.stop()` is synchronous, tears down the I/O and asserts no isolation domain,
    /// and `removeObserver` is a token-based removal that needs no domain. Both are the whole of
    /// why this object can be released from any thread — and why the method is named `tearDown`
    /// and not `stop`: a `deinit` reaching an asserting teardown is a defect `DeinitIsolationTests`
    /// exists to see, and a name it permits is not a carve-out it can see past.
    private func tearDown() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        engine.stop()
    }

    // MARK: - The session

    /// Open the microphone.
    ///
    /// **Called off the tap callback**, on a later turn of the run loop — see
    /// `CaptureStartTiming.whenTheOwnerAsks`, which this cost is the reason for. Phase 3 measured it:
    /// 114 ms median on the analog headphone-jack input, 42 ms on the built-in microphone array.
    public func start() throws {
        do {
            try engine.start()
        } catch {
            throw AudioCaptureGraphError.engineWouldNotStart(error)
        }
    }

    /// Close the microphone, and do not return until it is closed.
    ///
    /// `AVAudioEngine.stop()` is synchronous and tears down the I/O. Phase 3 measured it at 7.7 ms
    /// median. **No `prepare()` follows it** — see this type's header for the measurement that
    /// removed it.
    public func stop() {
        engine.stop()
    }
}
