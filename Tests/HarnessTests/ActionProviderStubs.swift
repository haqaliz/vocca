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

import Synchronization
import VoccaCore
import XCTest

// The action seam's **executing** test double, and the self-check that proves it executes
// (`action-seam` plan Phase 4, PRD M10).
//
// ## Why a stub that acts has to exist before the aspects that need it
//
// Two later acceptances are counting assertions over the set of things that can run:
// `confirmation-gate` must assert that a dry-run invokes a provider **zero** times (PRD M5/G2),
// and `audit-log` must assert that **every executed action** is reconstructible from its entry
// (M6). Today the only implementation in the tree is ``NullActionProvider``, which serves no
// tools and never acts — so both assertions would range over an empty set and pass without
// witnessing anything. "Zero invocations occurred" is trivially true where no invocation was
// ever possible.
//
// ``RecordingActionProvider`` is the non-empty domain those assertions need: a provider that
// genuinely executes, keeps a log of what it was asked and can be configured to fail the test
// outright the moment `invoke` is reached.
//
// ## Describe and invoke are logged separately, and that is the whole point
//
// The dry-run acceptance is not "the provider was not touched" — dry-run is *expected* to call
// ``ActionProvider/describe(_:)``, because a preview that could not render the sentence would
// have nothing to preview. The claim is narrower and sharper: `describe` may be called, `invoke`
// must not be. A single combined call counter cannot express it, so the log records the two
// operations as distinct cases of ``RecordedActionCall`` and the counters are derived from it.
//
// ## What this file deliberately cannot do
//
// It cannot call ``ActionProvider/invoke(_:confirmation:)``. That call needs an
// `ActionConfirmation`, whose initializer is `internal` to `VoccaCore` and whose construction
// the `action-seam` family lint confines across `Sources/` **and** `Tests/` alike
// (`ActionSeamBoundaryTests`). Forging one here to make a test convenient would defeat the exact
// structural refusal the unit exists to establish. So the end-to-end path through `invoke`
// belongs to `confirmation-gate`, which is the aspect that mints legitimately; what is pinned
// here is everything reachable without a token — see ``RecordingActionProvider/execute(_:)`` for
// how the invoke *body* is watched, and why watching it is not a bypass.

// MARK: - The call log

/// One entry in a ``RecordingActionProvider``'s call log: which operation, and on what.
///
/// Two cases rather than a counter, because the dry-run acceptance distinguishes them (see this
/// file's header). `Equatable` so a test can assert the exact sequence — order matters, since
/// "described, then invoked" and "invoked, then described" are different stories about a gate.
enum RecordedActionCall: Sendable, Equatable {
    /// ``ActionProvider/describe(_:)`` was called. Pure; dry-run is allowed to do this.
    case describe(ActionInvocation)

    /// The acting operation ran. Dry-run must never produce one of these.
    case invoke(ActionInvocation)
}

// MARK: - The executing stub

/// A test-only ``ActionProvider`` that **genuinely executes**, logging every call, with a mode
/// that fails the test if it is ever invoked.
///
/// Where ``NullActionProvider`` is the shipped default that does nothing, this is its opposite
/// and the reason the later acceptances are not vacuous: it serves tools, it acts, and it
/// remembers. Its side effect is an execution counter rather than anything in the world — a test
/// double that deleted files to prove it can delete files would be a worse test double, and the
/// counter is what the assertions actually read.
///
/// A `final class` with immutable, `Sendable` storage and a `Mutex` for the log, kept that way
/// after the seam went `async` (`async-seam`): this stub's work genuinely *is* synchronous, so a
/// `Mutex` says so and the counters stay readable without an `await` from the many assertions
/// that read them. An `actor` would be the honest shape for a stub whose work suspends, and
/// ``SuspendingActionProvider`` below is exactly that — the two are kept apart so each one
/// witnesses what it actually is. `@unchecked Sendable` remains not a thing this house writes.
final class RecordingActionProvider: ActionProvider {

    /// What happens when the acting operation is reached.
    enum InvokeBehavior: Sendable {
        /// Genuinely execute: log the call, count an execution, return this outcome.
        ///
        /// The payload is what makes the `.succeeded` and `.failed(reasonKey:)` paths drivable
        /// from a caller — `audit-log` has to record both, and a stub that could only succeed
        /// would leave the failure branch of the entry untested.
        case executes(ActionOutcome)

        /// **Fail the test the moment this is reached.**
        ///
        /// C13's wording for the dry-run acceptance is "asserted by a stub that fails the test
        /// if invoked", and the emphasis is on *fails the test*: reporting the violation by
        /// returning ``ActionOutcome/failed(reasonKey:)`` would put the outcome in the caller's
        /// hands, and a caller that ignored the return value — which a dry-run path, expecting
        /// to make no call at all, plausibly would — would swallow the very fact being asserted.
        /// A failure that the code under test can discard is not an assertion.
        case failsTheTestIfInvoked
    }

    /// How a ``InvokeBehavior/failsTheTestIfInvoked`` violation is reported.
    ///
    /// Injected rather than hard-wired to `XCTFail` for one reason: a stub nobody has watched
    /// fail is not evidence. The self-check below installs a recording reporter and asserts it
    /// fired, which is how the fail-if-invoked wiring is exercised without taking the whole suite
    /// down with it. The default *is* `XCTFail`, and that default is itself watched — see
    /// ``ActionProviderStubsTests/testTheShippedDefaultReporterFailsTheTestForReal()``.
    typealias FailureReporter = @Sendable (_ message: String, _ file: StaticString, _ line: UInt)
        -> Void

    private struct Log {
        var calls: [RecordedActionCall] = []
        var executions = 0
        var reportedViolations = 0
    }

    private let log = Mutex<Log>(Log())

    private let behavior: InvokeBehavior
    private let describedRadius: BlastRadius
    private let reportFailure: FailureReporter
    private let file: StaticString
    private let line: UInt

    /// The tools this provider serves. Non-empty by default — an empty list would make it a
    /// second ``NullActionProvider`` and reintroduce the empty domain this type exists to fill.
    let toolIDs: [String]

    /// - Parameters:
    ///   - toolIDs: What the provider claims to serve.
    ///   - describedRadius: The radius every ``describe(_:)`` reports. Configurable because the
    ///     gate branches on exactly this value, so a caller needs to drive both sides of
    ///     ``BlastRadius/requiresConfirmation``. Defaults to ``BlastRadius/destructive``: the
    ///     side that must be stopped is the side a test that forgot to choose should get.
    ///   - behavior: Execute and return an outcome, or fail the test if reached.
    ///   - file: Where the failure is attributed — the construction site, which is the line a
    ///     reader needs when a dry-run turns out not to be dry.
    ///   - line: See `file`.
    ///   - reportFailure: How a violation is reported. Defaults to `XCTFail`.
    init(
        toolIDs: [String] = ["stub-tool"],
        describedRadius: BlastRadius = .destructive,
        behavior: InvokeBehavior = .executes(.succeeded),
        file: StaticString = #filePath,
        line: UInt = #line,
        reportFailure: @escaping FailureReporter = { message, file, line in
            XCTFail(message, file: file, line: line)
        }
    ) {
        self.toolIDs = toolIDs
        self.describedRadius = describedRadius
        self.behavior = behavior
        self.file = file
        self.line = line
        self.reportFailure = reportFailure
    }

    // MARK: The seam

    /// Renders the sentence, logs the call, and **acts on nothing** — the pure half of the seam.
    ///
    /// The sentence names the tool so that an audit assertion can tell two descriptions apart;
    /// the stub is not trying to be plausible prose, it is trying to be distinguishable.
    func describe(_ invocation: ActionInvocation) async -> ActionSummary {
        log.withLock { $0.calls.append(.describe(invocation)) }
        return ActionSummary(
            sentence: "Stub would run \(invocation.toolID) on \(invocation.providerID).",
            blastRadius: describedRadius)
    }

    /// The acting half of the seam. Forwards to ``execute(_:)`` once the type system has
    /// established that a confirmation exists.
    ///
    /// `async` because the seam is; it suspends nowhere, which keeps ``execute(_:)`` — the body
    /// the self-check watches — synchronous and directly callable. The forwarding line stays a
    /// single expression with no logic of its own, so what the self-check watches is still what
    /// a real invocation runs.
    func invoke(_ invocation: ActionInvocation, confirmation: ActionConfirmation) async
        -> ActionOutcome
    {
        execute(invocation)
    }

    // MARK: The body, and why it is reachable

    /// **The body ``invoke(_:confirmation:)`` runs**, minus the token it cannot be handed here.
    ///
    /// This file cannot mint an `ActionConfirmation` — by design, and enforced by a lint — so the
    /// only way to watch the recording and the fail-if-invoked wiring actually work is to call
    /// the body directly. `invoke` above is a single forwarding line with no logic of its own, so
    /// what the self-check watches is what a real invocation runs.
    ///
    /// **This is not a bypass of the confirmation contract**, in the only direction that would
    /// matter. Both routes append the same ``RecordedActionCall/invoke(_:)`` and bump the same
    /// counter, so a later test that called this instead of going through the gate would make a
    /// dry-run assertion *fail* — an unexplained invocation appears in the log either way. The
    /// door it opens leads towards stricter assertions, never towards a vacuous pass. Nothing in
    /// `Sources/` can reach it at all.
    @discardableResult
    func execute(_ invocation: ActionInvocation) -> ActionOutcome {
        switch behavior {
        case .executes(let outcome):
            log.withLock {
                $0.calls.append(.invoke(invocation))
                $0.executions += 1
            }
            return outcome

        case .failsTheTestIfInvoked:
            // Logged before the report, so the call is on the record even if the reporter is the
            // default and the test stops here: the log is the evidence of what happened, and the
            // failure is the consequence.
            log.withLock {
                $0.calls.append(.invoke(invocation))
                $0.reportedViolations += 1
            }
            reportFailure(
                "the stub was invoked: \(invocation.providerID)/\(invocation.toolID). This "
                    + "provider was configured to fail the test if it ever acted — something "
                    + "reached the acting half of the seam that must not have.", file, line)
            // The return value is immaterial: the test has already failed. `.notInvoked` because
            // this mode genuinely did not execute — it refused and reported.
            return .notInvoked
        }
    }

    // MARK: What a test reads

    /// Every call, in the order they were made.
    var calls: [RecordedActionCall] { log.withLock { $0.calls } }

    /// How many times the pure half was called. Dry-run may make this non-zero.
    var describeCount: Int {
        log.withLock {
            $0.calls.filter {
                if case .describe = $0 { return true } else { return false }
            }.count
        }
    }

    /// How many times the acting half was reached. **This is the number the dry-run acceptance
    /// asserts is zero.**
    var invokeCount: Int {
        log.withLock {
            $0.calls.filter {
                if case .invoke = $0 { return true } else { return false }
            }.count
        }
    }

    /// How many invocations genuinely executed — reached the acting half *and* did the work.
    /// Differs from ``invokeCount`` only under ``InvokeBehavior/failsTheTestIfInvoked``, which
    /// records the call and refuses to perform it.
    var executionCount: Int { log.withLock { $0.executions } }

    /// How many times the fail-if-invoked mode reported a violation.
    var reportedViolationCount: Int { log.withLock { $0.reportedViolations } }
}

// MARK: - The suspending stub

/// A provider whose work is **genuinely asynchronous**: an `actor` whose every operation
/// suspends before it answers (`async-seam`, 2026-09-19).
///
/// ``RecordingActionProvider`` is a `final class` whose bodies never suspend, so it would
/// witness a synchronous seam just as happily — it cannot demonstrate what this aspect added.
/// This one can, and the demonstration is its own existence: an actor's isolated methods are
/// reachable only through an `await`, so under the previous synchronous contract **there was no
/// way to write this conformance at all**. That is not a hypothetical about some future adapter;
/// it is exactly what stopped the second real provider — one backed by the audit store, itself
/// an actor — from being written, which is the finding this aspect exists to act on.
///
/// The suspension is real rather than spelled: each operation `await`s `Task.yield()` and counts
/// the hop, so ``suspensionCount`` is evidence that a suspension happened rather than a claim
/// that one could.
///
/// There is no fail-if-invoked mode here. The acting counter is actor state read after the fact,
/// which is what the refusal-under-suspension assertion needs; ``RecordingActionProvider`` keeps
/// the mode that fails at the moment of the violation, and the refusal legs that want it use it.
actor SuspendingActionProvider: ActionProvider {

    /// The tools this provider serves. `nonisolated` because the seam's requirement is, and
    /// because an immutable list of `String` has no state to protect.
    nonisolated let toolIDs: [String]

    private let describedRadius: BlastRadius
    private let outcome: ActionOutcome

    private var log: [RecordedActionCall] = []
    private var suspensions = 0

    /// - Parameters:
    ///   - toolIDs: What the provider claims to serve.
    ///   - describedRadius: The radius every ``describe(_:)`` reports. Defaults to
    ///     ``BlastRadius/destructive`` — the side that must be stopped is the side a caller that
    ///     forgot to choose should get.
    ///   - outcome: What ``invoke(_:confirmation:)`` returns once it is reached.
    init(
        toolIDs: [String] = ["suspending-tool"],
        describedRadius: BlastRadius = .destructive,
        outcome: ActionOutcome = .succeeded
    ) {
        self.toolIDs = toolIDs
        self.describedRadius = describedRadius
        self.outcome = outcome
    }

    // MARK: The seam

    /// Suspends, then renders the sentence. Still pure: it touches nothing outside its own log.
    func describe(_ invocation: ActionInvocation) async -> ActionSummary {
        await Task.yield()
        suspensions += 1
        log.append(.describe(invocation))
        return ActionSummary(
            sentence: "Suspending stub would run \(invocation.toolID) on \(invocation.providerID).",
            blastRadius: describedRadius)
    }

    /// Suspends, then acts — the acting half, reachable only with a token the gate minted.
    func invoke(_ invocation: ActionInvocation, confirmation: ActionConfirmation) async
        -> ActionOutcome
    {
        await Task.yield()
        suspensions += 1
        log.append(.invoke(invocation))
        return outcome
    }

    // MARK: What a test reads

    /// Every call, in the order they were made.
    var calls: [RecordedActionCall] { log }

    /// How many times the pure half was called.
    var describeCount: Int {
        log.filter { if case .describe = $0 { return true } else { return false } }.count
    }

    /// How many times the acting half was reached. **The number the refusal assertion reads.**
    var invokeCount: Int {
        log.filter { if case .invoke = $0 { return true } else { return false } }.count
    }

    /// How many times an operation actually suspended — one per call, and the evidence that
    /// "asynchronous" here is behaviour rather than a keyword.
    var suspensionCount: Int { suspensions }
}

// MARK: - The self-check

/// The stub, measured against itself.
///
/// A test double is code, and code that nothing checks is code that silently stops doing its job.
/// These assertions are not about the action seam — `ActionSeamTests` owns that — they are about
/// whether the instrument the later acceptances will be read through actually reads. Two claims
/// carry the weight: the log distinguishes `describe` from `invoke`, and the fail-if-invoked mode
/// **really fails**, watched here rather than assumed.
final class ActionProviderStubsTests: XCTestCase {

    private func makeInvocation(
        providerID: String = "dev.vocca.stub", toolID: String = "stub-tool",
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> ActionInvocation {
        try XCTUnwrap(
            ActionInvocation(providerID: providerID, toolID: toolID),
            "a non-empty provider id and tool id must construct an invocation", file: file,
            line: line)
    }

    /// A reporter that records instead of failing, so a violation can be *observed*.
    private final class ViolationRecorder: Sendable {
        private let messages = Mutex<[String]>([])

        var recorded: [String] { messages.withLock { $0 } }

        /// Captures `self` rather than the lock: `Mutex` is noncopyable, so it cannot be lifted
        /// into a local for the closure to hold. The recorder is a `Sendable` final class, so
        /// capturing it in an escaping `@Sendable` closure is honest.
        var reporter: RecordingActionProvider.FailureReporter {
            { message, _, _ in self.messages.withLock { $0.append(message) } }
        }
    }

    // MARK: - 1. The log distinguishes the two operations, and keeps their order

    /// `describe` and `invoke` are recorded **separately and in sequence**.
    ///
    /// This is the claim the dry-run acceptance is built on. If the two collapsed into one
    /// counter, "describe may be called, invoke must not be" would be inexpressible and the
    /// acceptance would quietly become "the provider was never touched" — a different, and
    /// wrong, assertion.
    func testTheStubRecordsDescribeAndInvokeSeparatelyAndInOrder() async throws {
        let first = try makeInvocation(toolID: "list-files")
        let second = try makeInvocation(toolID: "delete-downloads")
        let provider = RecordingActionProvider(toolIDs: ["list-files", "delete-downloads"])

        _ = await provider.describe(first)
        _ = provider.execute(second)
        _ = await provider.describe(second)

        XCTAssertEqual(
            provider.calls, [.describe(first), .invoke(second), .describe(second)],
            "the log is the exact sequence of operations, not a bag of counts — order is what "
                + "tells 'described then invoked' apart from 'invoked then described'")
        XCTAssertEqual(provider.describeCount, 2)
        XCTAssertEqual(
            provider.invokeCount, 1,
            "exactly one call reached the acting half — the number the dry-run acceptance reads")
        XCTAssertEqual(provider.calls.count, 3, "no call went unrecorded")
    }

    /// Describing, repeatedly, leaves the acting counter at **zero**.
    ///
    /// The rehearsal of `confirmation-gate`'s acceptance against the instrument that will make
    /// it, run here so the instrument is known to be capable of reporting a non-zero count (the
    /// test above) before a later suite reads zero from it and calls that evidence.
    func testDescribingNeverExecutesAnything() async throws {
        let invocation = try makeInvocation()
        let provider = RecordingActionProvider()

        for _ in 0..<5 {
            _ = await provider.describe(invocation)
        }

        XCTAssertEqual(provider.describeCount, 5, "every preview was recorded")
        XCTAssertEqual(provider.invokeCount, 0, "the pure half must not reach the acting half")
        XCTAssertEqual(provider.executionCount, 0, "and nothing executed")
    }

    // MARK: - 2. It genuinely executes, and the outcome is the caller's to choose

    /// The stub actually acts — an observable execution, and the configured outcome returned.
    ///
    /// Both outcome paths are driven because `audit-log` has to record both, and a stub that
    /// could only succeed would leave the failure branch of the entry unwritten.
    func testTheStubExecutesAndReturnsTheConfiguredOutcome() throws {
        let invocation = try makeInvocation()

        let succeeding = RecordingActionProvider(behavior: .executes(.succeeded))
        XCTAssertEqual(succeeding.execute(invocation), .succeeded)
        XCTAssertEqual(
            succeeding.executionCount, 1,
            "the execution is observable — this is what makes the domain non-empty")

        let failing = RecordingActionProvider(
            behavior: .executes(.failed(reasonKey: "stub.diskFull")))
        XCTAssertEqual(
            failing.execute(invocation), .failed(reasonKey: "stub.diskFull"),
            "a provider that tried and failed reports the reason key it was configured with")
        XCTAssertEqual(
            failing.executionCount, 1,
            "a failed action still ran — 'tried and failed' is not 'never ran', and the audit "
                + "log's one real question is which happened")

        XCTAssertEqual(succeeding.executionCount + failing.executionCount, 2)
    }

    /// It is a real conformance to the seam, usable wherever a provider is expected.
    ///
    /// Read through the existential, because that is how the gate and the audit log will hold it:
    /// a stub that only worked as its concrete type would not exercise the seam at all.
    func testTheStubIsAGenuineProviderBehindTheSeam() async throws {
        let invocation = try makeInvocation(toolID: "delete-downloads")
        let concrete = RecordingActionProvider(
            toolIDs: ["delete-downloads"], describedRadius: .outwardFacing)
        let provider: any ActionProvider = concrete

        XCTAssertEqual(provider.toolIDs, ["delete-downloads"], "it serves a tool, unlike the default")

        let summary = await provider.describe(invocation)
        XCTAssertEqual(
            summary.blastRadius, .outwardFacing,
            "the radius is the caller's to choose — the gate branches on exactly this value")
        XCTAssertTrue(
            summary.sentence.contains("delete-downloads"),
            "the sentence names the tool, so two descriptions are distinguishable in a log")
        XCTAssertEqual(
            concrete.calls, [.describe(invocation)],
            "the call through the existential landed in the same log")

        let crossing: @Sendable () -> Int = { concrete.invokeCount }
        XCTAssertEqual(crossing(), 0, "the stub crosses an isolation boundary as a Sendable value")
    }

    // MARK: - 3. The fail-if-invoked mode, watched failing

    /// The fail-if-invoked mode fires, observed through an injected reporter.
    ///
    /// The violation is captured rather than raised so this suite can assert on it. The message
    /// is asserted to name the invocation, because a failure that does not say *what* ran sends
    /// the reader back to the log to find out.
    func testTheFailIfInvokedModeReportsAViolationWhenInvoked() throws {
        let invocation = try makeInvocation(providerID: "dev.vocca.stub", toolID: "delete-downloads")
        let recorder = ViolationRecorder()
        let provider = RecordingActionProvider(
            behavior: .failsTheTestIfInvoked, reportFailure: recorder.reporter)

        XCTAssertEqual(recorder.recorded.count, 0, "nothing has been reported yet")

        let outcome = provider.execute(invocation)

        XCTAssertEqual(recorder.recorded.count, 1, "invoking the stub reported exactly one violation")
        let message = try XCTUnwrap(recorder.recorded.first)
        XCTAssertTrue(
            message.contains("dev.vocca.stub/delete-downloads"),
            "the failure names what ran: \(message)")
        XCTAssertEqual(provider.reportedViolationCount, 1)
        XCTAssertEqual(
            provider.invokeCount, 1,
            "the violating call is on the record — the log is the evidence, the failure the "
                + "consequence")
        XCTAssertEqual(
            provider.executionCount, 0,
            "this mode refuses rather than executes; the failure is the whole of its behaviour")
        XCTAssertEqual(
            outcome, .notInvoked,
            "the returned value is immaterial once the test has failed, and `.notInvoked` is the "
                + "honest one — but no caller may rely on reading it, which is why the mode "
                + "reports rather than returns")
    }

    /// In fail-if-invoked mode, **describing is still free**.
    ///
    /// Without this leg the mode would be useless to the acceptance it exists for: a dry-run
    /// calls `describe`, and a stub that fired on the preview would fail every correct dry-run.
    func testTheFailIfInvokedModeDoesNotFireOnDescribe() async throws {
        let invocation = try makeInvocation()
        let recorder = ViolationRecorder()
        let provider = RecordingActionProvider(
            behavior: .failsTheTestIfInvoked, reportFailure: recorder.reporter)

        for _ in 0..<3 {
            _ = await provider.describe(invocation)
        }

        XCTAssertEqual(
            recorder.recorded, [],
            "dry-run is expected to describe — a preview that could not render the sentence "
                + "would have nothing to preview")
        XCTAssertEqual(provider.describeCount, 3)
        XCTAssertEqual(provider.invokeCount, 0)
    }

    /// **The default reporter is watched failing for real.**
    ///
    /// The test above proves the wiring fires; this one proves what it is wired to. The stub's
    /// default reporter is `XCTFail`, and a mode that merely *claims* to fail the test is the
    /// thing this whole file exists to refuse. `XCTExpectFailure` lets the failure be raised and
    /// then absorbed: if the stub stopped failing — a behaviour swapped for a returned value, a
    /// default quietly changed — the expected failure would not arrive and this test would fail
    /// for the absence.
    func testTheShippedDefaultReporterFailsTheTestForReal() throws {
        let invocation = try makeInvocation()
        let provider = RecordingActionProvider(behavior: .failsTheTestIfInvoked)

        XCTExpectFailure(
            "the fail-if-invoked mode must raise a real test failure when it is invoked",
            strict: true
        ) {
            _ = provider.execute(invocation)
        }

        XCTAssertEqual(
            provider.reportedViolationCount, 1,
            "the default path reported exactly once — and the failure it raised was the one "
                + "absorbed above")
    }
}
