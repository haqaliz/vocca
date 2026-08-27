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
import VoccaCore
@testable import VoccaInject
import XCTest

/// **The write side of C8's strategy memory** (`memory-order/spec.md` T11–T15): what a ladder run
/// leaves behind, and what it must not.
///
/// Two claims here are load-bearing and neither is provable by reading the code:
///
/// - **the injector never awaits the persist.** The ladder's ≤100 ms budget
///   (`ARCHITECTURE.md:318`) is measured around the synchronous inject, and a recorder that
///   awaited a file write would put a disk on the latency path of every single dictation. The
///   gated store below is what turns "fire and forget" from a comment into a measurement: with
///   its gate shut, a persist *cannot* complete, so an inject that returns anyway is an inject
///   that did not wait;
/// - **rapid dictations persist in order.** Two presses a keystroke apart spawn two detached
///   writes of the whole snapshot, and the older one landing last would overwrite what the newer
///   one learned. The chain is what prevents it, and the gate is what makes the race reliably
///   reproducible — both writes are parked at the same gate before either is released.
///
/// The third claim is the honest refusal: a run in which **no rung was attempted** — Secure Input,
/// nothing focused — must write nothing at all (`SMOKE_CHECKLIST.md` step 27). The recorder is
/// still called on those paths; deciding they are empty is its job, not the injector's.
final class InjectionStrategyRecordingTests: XCTestCase {

    private static let unknown = "com.example.Editor"
    private static let allowlisted = "com.apple.Notes"

    private func makeMemory(
        store: any InjectionStrategyStore,
        clock: TestEpochClock
    ) -> MemoryBackedInjectionStrategyOrder {
        MemoryBackedInjectionStrategyOrder(
            seed: FakeInjectionAllowlist(allowed: SeededInjectionAllowlist.seedBundleIDs),
            strategies: [],
            hostileBundleIDs: [],
            store: store,
            now: clock.read)
    }

    // MARK: - T11 · A run that attempted no rung is not a lesson

    /// The two rung-0 refusals and the no-focused-application case leave the store untouched.
    /// Recording them would teach the memory that the accessibility rung failed for an
    /// application it was never offered to — and Secure Input is a fact about the *field*, not
    /// about the app's accessibility support.
    func testRungZeroRefusalsWriteNothing() async {
        let store = GatedInjectionStrategyStore()
        let memory = makeMemory(store: store, clock: TestEpochClock(0))

        // Secure Input: the decision refuses before any rung, so the trace is empty.
        await memory.record(
            bundleID: Self.allowlisted,
            orderedRungs: [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            result: InjectionResult(
                rung: .widgetFailsafe, attempted: [], verified: false, elapsed: .zero))
        // Nothing focused: there is no application to remember this against at all.
        await memory.record(
            bundleID: nil,
            orderedRungs: [.clipboardPaste, .keystrokeSynthesis],
            result: InjectionResult(
                rung: .widgetFailsafe, attempted: [], verified: false, elapsed: .zero))

        await memory.drainPendingPersists()
        let written = await store.updates
        XCTAssertTrue(
            written.isEmpty,
            """
            A run that attempted no rung was recorded as a lesson. Secure Input and \
            no-focused-field are refusals *before* the ladder — writing them teaches the memory \
            that rungs failed which were never tried.
            """)
        XCTAssertTrue(
            memory.snapshot().isEmpty,
            "The in-memory snapshot grew an entry for a run that attempted nothing.")
    }

    // MARK: - T12 · Deliveries and fall-throughs are both recorded

    /// A clipboard delivery for an unlisted application leaves the promotion candidate marker,
    /// and an exhausted ladder leaves the demotion derived from the trace it fell through.
    func testDeliveredAndFailsafeResultsRecordIntoTheStore() async {
        let store = GatedInjectionStrategyStore()
        let memory = makeMemory(store: store, clock: TestEpochClock(100))

        await memory.record(
            bundleID: Self.unknown,
            orderedRungs: [.clipboardPaste, .keystrokeSynthesis],
            result: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero))
        await memory.drainPendingPersists()

        let candidate = await store.updates.last
        XCTAssertEqual(candidate?.bundleID, Self.unknown)
        XCTAssertEqual(
            candidate?.demotedRungs, [.accessibility],
            "A clipboard delivery for an unlisted app left no promotion candidate behind.")
        XCTAssertEqual(
            candidate?.reprobeWindows[.accessibility],
            100 + StrategyMemoryTargets.reprobeWindowSeconds,
            "The candidate's probe was not scheduled a window from the delivery.")

        // The fall-through: every rung attempted, the failsafe took custody. The trace is what
        // the demotion is derived from, so it must arrive intact.
        await memory.record(
            bundleID: Self.allowlisted,
            orderedRungs: [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            result: InjectionResult(
                rung: .widgetFailsafe, attempted: [.accessibility, .clipboardPaste],
                verified: false, elapsed: .zero))
        await memory.drainPendingPersists()

        let exhausted = await store.updates.last
        XCTAssertEqual(exhausted?.bundleID, Self.allowlisted)
        XCTAssertEqual(
            exhausted?.demotedRungs, [.accessibility],
            """
            The exhausted ladder's trace did not become a demotion — or it demoted the clipboard \
            workhorse, which must never be demoted at all.
            """)
    }

    // MARK: - T13 · The injector returns before the disk does

    /// The latency claim, measured: with the store's gate shut a persist cannot complete, and
    /// `inject` returns anyway. Opening the gate then lets it land — which is what proves the
    /// write was spawned at all rather than skipped.
    @MainActor
    func testInjectorNeverAwaitsThePersist() async {
        let store = GatedInjectionStrategyStore()
        await store.closeGate()
        let memory = makeMemory(store: store, clock: TestEpochClock(0))
        let ladder = LadderInjector(
            strategies: [
                .clipboardPaste: FakeInjectionStrategy(
                    rung: .clipboardPaste, outcome: .succeeded(verified: false))
            ],
            order: memory,
            handoff: RecordingFailsafeHandoff(),
            clock: TestClock(),
            recorder: memory)

        let result = await ladder.inject(
            "hello",
            into: TargetContext(bundleID: Self.unknown, windowTitle: nil, isSecureInput: false))

        XCTAssertEqual(result.rung, .clipboardPaste)
        let duringGate = await store.updates
        XCTAssertTrue(
            duringGate.isEmpty,
            """
            The injection waited for the strategy store. The ladder's whole latency budget is \
            100 ms and a disk write is not inside it — the persist is detached by contract.
            """)
        XCTAssertEqual(
            memory.orderedRungs(for: Self.unknown), [.clipboardPaste, .keystrokeSynthesis],
            "Precondition: the in-memory apply already happened.")

        await store.openGate()
        await memory.drainPendingPersists()
        let afterGate = await store.updates
        XCTAssertEqual(
            afterGate.count, 1,
            "The persist was never spawned — the memory would be forgotten at the next launch.")
    }

    /// The other half of R8: the residual the injector reports when the failsafe handoff refuses
    /// custody still travels through the recorder. It writes nothing, because its trace is empty
    /// — but the seam is called, so a future outcome carrying a trace cannot be silently dropped
    /// by that branch.
    @MainActor
    func testCatchResidualStillCallsTheRecorder() async {
        let recorder = CountingStrategyRecorder()
        let handoff = RecordingFailsafeHandoff()
        await handoff.refuseNextHold()
        let ladder = LadderInjector(
            strategies: [:],
            order: FakeInjectionStrategyOrder(rungs: [.clipboardPaste]),
            handoff: handoff,
            clock: TestClock(),
            recorder: recorder)

        let result = await ladder.inject(
            "hello",
            into: TargetContext(bundleID: Self.unknown, windowTitle: nil, isSecureInput: false))

        XCTAssertEqual(result.rung, .widgetFailsafe)
        let calls = await recorder.calls
        XCTAssertEqual(
            calls.count, 1,
            "The handoff-refusal residual never reached the recorder — the one ladder path that "
            + "skips the seam is the one nobody would notice skipping it.")
        XCTAssertEqual(calls.first?.bundleID, Self.unknown)
        XCTAssertEqual(calls.first?.result.attempted, [])
    }

    // MARK: - T14 · The next dictation reads memory, not disk

    /// The apply is synchronous and the persist is not, so the projection must already reflect the
    /// outcome while the write is still parked. A memory that only became true after the disk
    /// agreed would re-try the failed rung on the very next press.
    func testRecordingMutationIsVisibleToTheNextProjectionWithoutThePersist() async {
        let store = GatedInjectionStrategyStore()
        await store.closeGate()
        let memory = makeMemory(store: store, clock: TestEpochClock(0))

        await memory.record(
            bundleID: Self.allowlisted,
            orderedRungs: [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            result: InjectionResult(
                rung: .clipboardPaste, attempted: [.accessibility, .clipboardPaste],
                verified: false, elapsed: .zero))

        XCTAssertEqual(
            memory.orderedRungs(for: Self.allowlisted), [.clipboardPaste, .keystrokeSynthesis],
            """
            The demotion is not visible until the disk write completes. The next dictation can \
            arrive milliseconds later; it must read what was just learned, not what was last \
            saved.
            """)
        let written = await store.updates
        XCTAssertTrue(written.isEmpty, "Precondition: the persist is still parked at the gate.")
    }

    // MARK: - T15 · Rapid records land in order

    /// Two dictations in quick succession, both parked at the same gate before either is
    /// released: without the chain their order is whatever the scheduler picks, and the older
    /// snapshot landing last silently un-learns the newer one.
    func testRapidRecordsPersistInOrder() async {
        let store = GatedInjectionStrategyStore()
        await store.closeGate()
        let memory = makeMemory(store: store, clock: TestEpochClock(0))

        await memory.record(
            bundleID: Self.allowlisted,
            orderedRungs: [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            result: InjectionResult(
                rung: .clipboardPaste, attempted: [.accessibility, .clipboardPaste],
                verified: false, elapsed: .zero))
        await memory.record(
            bundleID: Self.unknown,
            orderedRungs: [.clipboardPaste, .keystrokeSynthesis],
            result: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero))

        await store.openGate()
        await memory.drainPendingPersists()

        let written = await store.updates
        XCTAssertEqual(
            written.map(\.bundleID), [Self.allowlisted, Self.unknown],
            """
            Two rapid dictations persisted out of order. Each write carries the whole snapshot, \
            so the older one landing last is the newer one being forgotten.
            """)
    }
}
