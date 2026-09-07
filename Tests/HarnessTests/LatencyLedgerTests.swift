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

import VoccaCore
import XCTest

/// The bounded ledger actor — `LatencyLedger` — driven through the recorder seam (spec
/// `core-ledger.md` A1, A3, A4, A5, A7, A8 + the plan's §6 edge policy).
///
/// Every write here is accepted or refused through the seam's `Bool` returns (never a crash,
/// never a silent drop — spec A3, plan §6), and every result is consumed: `VoccaCore` permits no
/// `@discardableResult`, so an ignored refusal is a compiler warning and a CI failure.
///
/// The clock story is the isolation decision, pinned honestly: **the ledger takes no clock at
/// all.** Time enters `VoccaCore` only through the injected ``MonotonicClock`` on the *caller's*
/// side — the caller measures a delta between two readings and passes it in; recording is a pure
/// append of caller-measured deltas (spec "Isolation decisions", A7).
/// `testSpansRecordExactlyTheDeltasTheCallerHandedIn` drives a hand-moved ``TestClock`` double
/// (the `SessionTestDoubles` precedent) and asserts the deltas survive verbatim — the ledger can
/// neither fabricate nor distort a duration.
final class LatencyLedgerTests: XCTestCase {

    private let engine = EngineIdentity(
        id: "parakeet-tdt-0.6b-v3", displayName: "Parakeet", isLocal: true)

    // MARK: - A1 closed-set coverage

    /// A table over **all six** outcome classes — every route the P0 pipeline can exit by —
    /// drives begin → record (one span per name, in pipeline order) → finalize. Exactly one
    /// record per begin, the class finalize was given is the class the record carries, and the
    /// spans keep call order.
    func testClosedSetEveryOutcomeClassYieldsExactlyOneRecord() async throws {
        let ledger = LatencyLedger()

        func engine(for outcome: SessionOutcomeClass) -> EngineIdentity? {
            switch outcome {
            case .aborted, .emptySkip:
                return nil
            case .delivered, .failsafeHeld, .failed, .lost:
                return self.engine
            }
        }

        let cases: [SessionOutcomeClass] = [
            .delivered(rung: .accessibility, verified: true),
            .failsafeHeld,
            .aborted,
            .failed,
            .lost,
            .emptySkip,
        ]
        var ids: [SessionRecord.ID] = []
        for (index, outcome) in cases.enumerated() {
            let id = await ledger.beginSession()
            ids.append(id)

            let captureClose = await ledger.recordSpan(
                LatencySpan.recorded(name: .captureClose, elapsed: .milliseconds(2)), for: id)
            XCTAssertTrue(captureClose)
            let asr = await ledger.recordSpan(
                LatencySpan.recorded(name: .asr, elapsed: .milliseconds(Int64(80 + index * 10))),
                for: id)
            XCTAssertTrue(asr)
            let cleanup = await ledger.recordSpan(LatencySpan.cleanupNotPresent(), for: id)
            XCTAssertTrue(cleanup)
            let inject = await ledger.recordSpan(
                LatencySpan.recorded(name: .inject, elapsed: .milliseconds(9)), for: id)
            XCTAssertTrue(inject)
            let finalized = await ledger.finalize(
                id: id, outcome: outcome, engine: engine(for: outcome), kind: .dictation)
            XCTAssertTrue(finalized)
        }

        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.count, 6, "exactly one record per begin — no path produces no record")
        for (index, outcome) in cases.enumerated() {
            XCTAssertEqual(snapshot[index].id, ids[index])
            XCTAssertEqual(
                snapshot[index].outcome, outcome,
                "the class finalize was given is the class the record carries")
            XCTAssertEqual(
                snapshot[index].spans.map(\.name), SpanName.allCases,
                "spans keep the order they were recorded in")
            XCTAssertEqual(
                snapshot[index].engine, engine(for: outcome),
                "attribution lands as given — nil only on the two never-asked paths")
        }
    }

    // MARK: - A3 duplicate refusal

    /// Recording a second span with the same name for the same session is a wiring bug and must
    /// fail loudly: the recorder returns `false`, the test asserts it, and the first span survives
    /// unchanged — the duplicate overwrites nothing and appends nothing false. A *different* name
    /// for the same session is still accepted.
    func testDuplicateSpanNameIsRefusedAndTheFirstSurvivesUnchanged() async throws {
        let ledger = LatencyLedger()
        let id = await ledger.beginSession()

        let first = LatencySpan.recorded(name: .asr, elapsed: .milliseconds(120))
        let accepted = await ledger.recordSpan(first, for: id)
        XCTAssertTrue(accepted)

        let duplicate = LatencySpan.recorded(name: .asr, elapsed: .milliseconds(9_999))
        let refused = await ledger.recordSpan(duplicate, for: id)
        XCTAssertFalse(
            refused, "a duplicate span name is refused loudly, never recorded (spec A3)")

        let other = LatencySpan.recorded(name: .inject, elapsed: .milliseconds(7))
        let acceptedOther = await ledger.recordSpan(other, for: id)
        XCTAssertTrue(
            acceptedOther, "a different name for the same session is still accepted")

        let finalized = await ledger.finalize(
            id: id, outcome: .failed, engine: engine, kind: .dictation)
        XCTAssertTrue(finalized)

        let snapshot = await ledger.snapshot()
        let record = try XCTUnwrap(snapshot.first)
        XCTAssertEqual(
            record.spans, [first, other],
            "the first span survives unchanged; the duplicate appended nothing false")
    }

    // MARK: - A4 bounded

    /// The cap is a fixed, documented, asserted constant. Fill far past it (600 sessions, in
    /// process, no timers, no sleeps) and the oldest records drop — exactly the first
    /// `total − cap` mints — the newest survives, and the cap holds after further writes.
    func testBoundedTheOldestDropsTheNewestSurvivesAndTheCapHolds() async throws {
        XCTAssertEqual(
            LatencyLedger.maximumRetainedRecords, 512,
            "the cap is fixed, documented, and pinned here — a change is a deliberate decision")

        let ledger = LatencyLedger()
        let total = LatencyLedger.maximumRetainedRecords + 88
        var first: SessionRecord.ID?
        var last: SessionRecord.ID?
        for session in 0..<total {
            let id = await ledger.beginSession()
            if session == 0 { first = id }
            if session == total - 1 { last = id }
            _ = await ledger.recordSpan(
                LatencySpan.recorded(name: .captureClose, elapsed: .milliseconds(Int64(session))),
                for: id)
            _ = await ledger.finalize(
                id: id, outcome: .emptySkip, engine: nil, kind: .dictation)
        }

        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.count, LatencyLedger.maximumRetainedRecords)
        let firstSurviving = try XCTUnwrap(snapshot.first)
        let oldestSurviving = SessionRecord.ID(
            rawValue: try XCTUnwrap(first).rawValue + (total - LatencyLedger.maximumRetainedRecords))
        XCTAssertEqual(
            firstSurviving.id, oldestSurviving,
            "the oldest records dropped — exactly the first total−cap mints, in mint order")
        XCTAssertEqual(try XCTUnwrap(snapshot.last).id, try XCTUnwrap(last), "the newest survives")

        for _ in 0..<40 {
            let id = await ledger.beginSession()
            _ = await ledger.finalize(
                id: id, outcome: .emptySkip, engine: nil, kind: .dictation)
        }
        let after = await ledger.snapshot()
        XCTAssertEqual(
            after.count, LatencyLedger.maximumRetainedRecords, "the cap holds after further writes")
        XCTAssertNotEqual(
            try XCTUnwrap(after.last).id, try XCTUnwrap(last),
            "the newest of the later writes survives")
    }

    // MARK: - A5 pure describe

    /// `describe()` is deterministic — two calls over the same ledger are identical — and renders
    /// in mint order, carrying every session's id, class, span names and elapseds. It is
    /// `String`-only; nothing here reads a clock.
    func testDescribeIsDeterministicAndContainsEveryRecord() async throws {
        let ledger = LatencyLedger()

        func label(of outcome: SessionOutcomeClass) -> String {
            switch outcome {
            case .delivered(let rung, let verified):
                return "delivered(\(rung), \(verified))"
            case .failsafeHeld:
                return "failsafeHeld"
            case .aborted:
                return "aborted"
            case .failed:
                return "failed"
            case .lost:
                return "lost"
            case .emptySkip:
                return "emptySkip"
            }
        }

        let captureElapsed = Duration.milliseconds(2)
        let asrElapsed = Duration.milliseconds(143)
        let injectElapsed = Duration.milliseconds(9)

        let cases: [SessionOutcomeClass] = [
            .delivered(rung: .clipboardPaste, verified: false),
            .failsafeHeld,
            .aborted,
            .failed,
            .emptySkip,
        ]
        var ids: [SessionRecord.ID] = []
        for (index, outcome) in cases.enumerated() {
            let id = await ledger.beginSession()
            ids.append(id)
            _ = await ledger.recordSpan(
                LatencySpan.recorded(name: .captureClose, elapsed: captureElapsed), for: id)
            _ = await ledger.recordSpan(
                LatencySpan.recorded(name: .asr, elapsed: asrElapsed), for: id)
            _ = await ledger.recordSpan(LatencySpan.cleanupNotPresent(), for: id)
            _ = await ledger.recordSpan(
                LatencySpan.recorded(name: .inject, elapsed: injectElapsed), for: id)
            _ = await ledger.finalize(
                id: id, outcome: outcome, engine: (index == 1 || index == 3) ? engine : nil,
                kind: .dictation)
        }

        let first = await ledger.describe()
        let second = await ledger.describe()
        XCTAssertEqual(first, second, "describe() is deterministic over the same ledger")

        for (index, id) in ids.enumerated() {
            XCTAssertTrue(
                first.contains("session \(id.rawValue):"),
                "describe() must name every session id — missing \(id)")
            XCTAssertTrue(
                first.contains(label(of: cases[index])),
                "describe() must carry the class — missing \(label(of: cases[index]))")
            for name in SpanName.allCases {
                XCTAssertTrue(
                    first.contains("\(name)"),
                    "describe() must carry every span name — missing \(name)")
            }
        }
        XCTAssertTrue(first.contains("\(captureElapsed)"), "describe() must carry the elapseds")
        XCTAssertTrue(first.contains("\(asrElapsed)"))
        XCTAssertTrue(first.contains("\(injectElapsed)"))
        XCTAssertTrue(
            first.contains("notPresent"),
            "the cleanup span before C5 renders as notPresent — never a fabricated 0")

        let firstSession = try XCTUnwrap(first.range(of: "session \(ids[0].rawValue):"))
        let secondSession = try XCTUnwrap(first.range(of: "session \(ids[1].rawValue):"))
        XCTAssertLessThan(
            firstSession.lowerBound, secondSession.lowerBound,
            "describe() renders in mint order")
    }

    // MARK: - Every class renders as its own string (`loss-observability` A5/A7)

    /// No two ``SessionOutcomeClass`` cases render alike through `describe()` — `lost` and
    /// `failed` above all — and no case's rendering is a substring of another's.
    ///
    /// `describe()` is the headless surface: it is what the zero-network probe prints and what a
    /// reader of a run has to count from. The P0 gate fixes transcript loss at exactly zero
    /// (`ROADMAP.md:96` — "This metric has no acceptable non-zero value"), so a `lost` that
    /// rendered as `failed` would let a run in which the product lost a transcript read as a run
    /// in which it lost none. The substring half matters for the same reason and for one more:
    /// every consumer of this string in the tree reads it with `contains`, so a spelling that
    /// nests inside another spelling is a miscount waiting for the first reader.
    ///
    /// The exhaustive `switch` in `describe()` forces a *seventh* class to be handled; nothing in
    /// the compiler forces it to be handled with a spelling nobody else already uses. This test
    /// is what forces that.
    ///
    /// Each class is rendered in a ledger of its own with no spans and no engine, so every line
    /// is identical but for the class label: a fresh ledger always mints id 0, which makes the
    /// comparison below a comparison of labels and of nothing else.
    func testEveryOutcomeClassRendersAsItsOwnStringThroughDescribe() async throws {
        let classes: [SessionOutcomeClass] = [
            .delivered(rung: .accessibility, verified: true),
            .failsafeHeld,
            .aborted,
            .failed,
            .lost,
            .emptySkip,
        ]

        let prefix = "session 0: "
        let suffix = ", , engine none, kind dictation"
        var labels: [String] = []
        for outcome in classes {
            let ledger = LatencyLedger()
            let id = await ledger.beginSession()
            let finalized = await ledger.finalize(
                id: id, outcome: outcome, engine: nil, kind: .dictation)
            XCTAssertTrue(finalized)
            let line = await ledger.describe()
            XCTAssertTrue(
                line.hasPrefix(prefix) && line.hasSuffix(suffix),
                "describe()'s line shape is what isolates the class label — got \(line)")
            labels.append(String(line.dropFirst(prefix.count).dropLast(suffix.count)))
        }

        XCTAssertEqual(
            Set(labels).count, classes.count,
            """
            Two outcome classes render as the same string, so a reader of describe() cannot tell \
            them apart. The P0 gate counts transcript loss at exactly zero (ROADMAP.md:96) off \
            this surface, and two classes sharing a spelling make that count a guess: \(labels)
            """)
        let lost = try XCTUnwrap(classes.firstIndex(of: .lost))
        let failed = try XCTUnwrap(classes.firstIndex(of: .failed))
        XCTAssertNotEqual(
            labels[lost], labels[failed],
            """
            A lost transcript and a failure that had none to lose render identically, so the \
            transcript-loss count read off describe() would include every failure that never \
            produced anything — the exact conflation this class exists to end.
            """)
        for (index, label) in labels.enumerated() {
            for (otherIndex, otherLabel) in labels.enumerated() where otherIndex != index {
                XCTAssertFalse(
                    otherLabel.contains(label),
                    "\(label) nests inside \(otherLabel) — every reader of describe() matches "
                        + "with `contains`, so a nested spelling counts the outer class as the "
                        + "inner one")
            }
        }
    }

    // MARK: - A7 injected clock

    /// The ledger never reads a clock of its own — time enters only through the injected
    /// ``MonotonicClock`` on the caller's side, and the caller passes deltas (spec "Isolation
    /// decisions"). This test drives a hand-moved ``TestClock`` double (the `SessionTestDoubles`
    /// precedent) and pins that the recorded elapseds equal **exactly** the deltas handed in,
    /// verbatim — the ledger can neither fabricate nor distort a duration.
    func testSpansRecordExactlyTheDeltasTheCallerHandedIn() async throws {
        let clock = TestClock()
        clock.now = .milliseconds(250)
        let captureStart = clock.now
        clock.now = .milliseconds(262)
        let captureDelta = clock.now - captureStart
        clock.now = .milliseconds(1_462)
        let asrStart = clock.now
        clock.now = .milliseconds(1_610)
        let asrDelta = clock.now - asrStart

        let ledger = LatencyLedger()
        let id = await ledger.beginSession()
        let captureClose = await ledger.recordSpan(
            LatencySpan.recorded(name: .captureClose, elapsed: captureDelta), for: id)
        XCTAssertTrue(captureClose)
        let asr = await ledger.recordSpan(
            LatencySpan.recorded(name: .asr, elapsed: asrDelta), for: id)
        XCTAssertTrue(asr)
        let cleanup = await ledger.recordSpan(LatencySpan.cleanupNotPresent(), for: id)
        XCTAssertTrue(cleanup)
        let finalized = await ledger.finalize(
            id: id, outcome: .failed, engine: engine, kind: .dictation)
        XCTAssertTrue(finalized)

        let snapshot = await ledger.snapshot()
        let record = try XCTUnwrap(snapshot.first)
        XCTAssertEqual(
            record.spans[0].elapsed, captureDelta,
            "the caller's measured delta survives verbatim — the ledger reads no clock of its own")
        XCTAssertEqual(record.spans[1].elapsed, asrDelta)
        XCTAssertEqual(
            record.spans[2].presence, .notPresent,
            "a span that never ran stays notPresent — the ledger fabricates no duration")
    }

    // MARK: - A8 isolation

    /// Recording from non-main `Task` contexts — eight concurrent workers × 25 sessions through
    /// the seam — compiles and runs clean under strict concurrency: the actor serialises, every
    /// begin is finalized exactly once, and the types are `Sendable`.
    func testIsolationRecordingFromNonMainTaskContexts() async throws {
        func requireSendable<T: Sendable>(_ value: T) -> T { value }

        let ledger = LatencyLedger()
        let recorder: LatencyRecorder = ledger
        let engine = self.engine
        _ = requireSendable(recorder)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<25 {
                        let id = await recorder.beginSession()
                        _ = await recorder.recordSpan(
                            LatencySpan.recorded(name: .asr, elapsed: .milliseconds(10)), for: id)
                        _ = await recorder.finalize(
                            id: id, outcome: .failed, engine: engine, kind: .dictation)
                    }
                }
            }
        }

        let snapshot = await ledger.snapshot()
        XCTAssertEqual(
            snapshot.count, 200,
            "8 concurrent workers × 25 sessions — every begin finalized exactly once, nothing lost, nothing duplicated")
        XCTAssertTrue(
            snapshot.allSatisfy { $0.outcome == .failed && $0.spans.count == 1 },
            "concurrent writes interleave correctly on the actor")
    }

    // MARK: - Edge policy (plan §6)

    /// A session finalizes once: the second `finalize` is refused, and a `recordSpan` after
    /// finalize is refused too — the first finalize and the already-recorded spans stand
    /// unchanged. Refusals are the loud failure; never a crash, never a silent drop.
    func testFinalizeTwiceAndRecordAfterFinalizeAreRefused() async throws {
        let ledger = LatencyLedger()
        let id = await ledger.beginSession()
        let recorded = await ledger.recordSpan(
            LatencySpan.recorded(name: .asr, elapsed: .milliseconds(30)), for: id)
        XCTAssertTrue(recorded)
        let finalized = await ledger.finalize(
            id: id, outcome: .failed, engine: engine, kind: .dictation)
        XCTAssertTrue(finalized)

        let secondFinalize = await ledger.finalize(
            id: id, outcome: .delivered(rung: .accessibility, verified: true), engine: engine,
            kind: .dictation)
        XCTAssertFalse(secondFinalize, "finalize twice is refused (plan §6)")
        let afterFinalize = await ledger.recordSpan(
            LatencySpan.recorded(name: .inject, elapsed: .milliseconds(5)), for: id)
        XCTAssertFalse(afterFinalize, "recordSpan after finalize is refused (plan §6)")

        let snapshot = await ledger.snapshot()
        let record = try XCTUnwrap(snapshot.first)
        XCTAssertEqual(record.spans.count, 1, "the refused post-finalize span must not appear")
        XCTAssertEqual(record.outcome, .failed, "the first finalize stands")
    }

    /// An id that was never minted — or one long forgotten — is refused by both mutating entry
    /// points. Refusal is the loud failure; never a crash, and nothing is recorded.
    func testUnknownSessionIDIsRefusedNeverACrash() async throws {
        let ledger = LatencyLedger()
        let ghost = SessionRecord.ID(rawValue: 999_999)
        let recorded = await ledger.recordSpan(
            LatencySpan.recorded(name: .asr, elapsed: .milliseconds(1)), for: ghost)
        XCTAssertFalse(recorded, "recordSpan for an unknown id is refused")
        let finalized = await ledger.finalize(
            id: ghost, outcome: .aborted, engine: nil, kind: .dictation)
        XCTAssertFalse(finalized, "finalize for an unknown id is refused")

        let snapshot = await ledger.snapshot()
        XCTAssertTrue(snapshot.isEmpty, "the refused writes recorded nothing")
    }

    // MARK: - The sink (usage-wiring Phase 1)

    /// **A finalized record reaches the installed sink, once, complete.**
    ///
    /// The usage ledger folds a session the moment it becomes a record — not from `snapshot()`,
    /// which is bounded at 512 and drops oldest at finalize, so a busy stretch could evict a
    /// record before anything folded it (`usage-wiring/spec.md` §1). The sink is the seam that
    /// makes "exactly once, at the moment it becomes a record" true.
    ///
    /// Delivery order is finalize order, and the record delivered is the record retained —
    /// asserted against `snapshot()` rather than against a hand-built expectation, so the two
    /// can never drift.
    func testAFinalizedRecordReachesTheInstalledSinkExactlyOnce() async throws {
        let delivered = DeliveredRecords()
        let ledger = ledger(deliveringTo: { delivered.append($0) })

        let first = await ledger.beginSession()
        let asr = await ledger.recordSpan(
            LatencySpan.recorded(name: .asr, elapsed: .milliseconds(80)), for: first)
        XCTAssertTrue(asr)
        let firstFinalized = await ledger.finalize(
            id: first, outcome: .delivered(rung: .accessibility, verified: true), engine: engine,
            kind: .dictation)
        XCTAssertTrue(firstFinalized)

        let second = await ledger.beginSession()
        let secondFinalized = await ledger.finalize(
            id: second, outcome: .emptySkip, engine: nil, kind: .onboarding)
        XCTAssertTrue(secondFinalized)

        let received = delivered.all
        XCTAssertEqual(
            received.count, 2,
            """
            each finalize delivers exactly once: got \(received.count) deliveries for two \
            finalizes. Fewer means a session was never folded; more means a day would be \
            double-counted.
            """)
        let snapshot = await ledger.snapshot()
        XCTAssertEqual(
            received, snapshot,
            """
            the record delivered is the record retained, in finalize order — a sink that carries \
            anything else folds a session the ledger cannot show.
            """)
        XCTAssertEqual(received.first?.kind, .dictation)
        XCTAssertEqual(received.last?.kind, .onboarding)
    }

    /// **A refused finalize delivers nothing.** Nothing became a record, so nothing may be
    /// folded: an unknown id and a second finalize both leave the sink untouched. Without this,
    /// a retry loop above the ledger would count a day twice.
    func testARefusedFinalizeDeliversNothing() async throws {
        let delivered = DeliveredRecords()
        let ledger = ledger(deliveringTo: { delivered.append($0) })

        let ghost = SessionRecord.ID(rawValue: 999_999)
        let refused = await ledger.finalize(
            id: ghost, outcome: .aborted, engine: nil, kind: .dictation)
        XCTAssertFalse(refused)
        XCTAssertEqual(delivered.all, [], "a finalize for an unknown id folds nothing")

        let id = await ledger.beginSession()
        let finalized = await ledger.finalize(
            id: id, outcome: .failed, engine: engine, kind: .dictation)
        XCTAssertTrue(finalized)
        XCTAssertEqual(delivered.all.count, 1)

        let again = await ledger.finalize(
            id: id, outcome: .lost, engine: engine, kind: .dictation)
        XCTAssertFalse(again, "finalize twice is refused (plan §6)")
        XCTAssertEqual(
            delivered.all.count, 1,
            "the refused second finalize must not deliver — a double fold is a double count")
    }

    /// **Every record crosses the sink, including the ones the cap later evicts.**
    ///
    /// The cap is a bound on what the ledger *shows*, not on what happened. A day's count is the
    /// number of sessions, so the sink must see all 600 finalizes while `snapshot()` keeps the
    /// last 512 — this is precisely the loss the spec rejected `snapshot()`-polling for.
    func testTheSinkSeesEveryFinalizeEvenWhenTheCapEvictsTheRecord() async throws {
        let delivered = DeliveredRecords()
        let ledger = ledger(deliveringTo: { delivered.append($0) })
        let total = LatencyLedger.maximumRetainedRecords + 88

        for _ in 0..<total {
            let id = await ledger.beginSession()
            let finalized = await ledger.finalize(
                id: id, outcome: .failed, engine: engine, kind: .dictation)
            XCTAssertTrue(finalized)
        }

        let snapshot = await ledger.snapshot()
        XCTAssertEqual(
            snapshot.count, LatencyLedger.maximumRetainedRecords,
            "the cap is unchanged by the sink")
        XCTAssertEqual(
            delivered.all.count, total,
            """
            the sink saw \(delivered.all.count) of \(total) finalizes. The cap bounds what the \
            ledger shows, never what happened — a fold that lost the evicted records would \
            undercount a busy day.
            """)
        XCTAssertEqual(
            delivered.all.map(\.id.rawValue), Array(0..<total),
            "delivery is finalize order, whole, with nothing dropped in the middle")
    }

    /// **A ledger with a sink and a ledger without one are indistinguishable.**
    ///
    /// `snapshot()`, `describe()`, the cap and the refusal answers are the ledger's whole
    /// observable surface, and the zero-network probe reads `describe()` for its `PROBE-LATENCY`
    /// line — a permanent release blocker. The same drive runs over both ledgers and every
    /// answer must match, including the refusals.
    func testASinkChangesNothingTheLedgerAnswers() async throws {
        func drive(_ ledger: LatencyLedger) async -> (answers: [Bool], described: String,
            snapshot: [SessionRecord])
        {
            var answers: [Bool] = []
            let id = await ledger.beginSession()
            answers.append(
                await ledger.recordSpan(
                    LatencySpan.recorded(name: .asr, elapsed: .milliseconds(40)), for: id))
            answers.append(
                await ledger.recordSpan(
                    LatencySpan.recorded(name: .asr, elapsed: .milliseconds(41)), for: id))
            answers.append(await ledger.recordSpan(LatencySpan.cleanupNotPresent(), for: id))
            answers.append(
                await ledger.finalize(
                    id: id, outcome: .delivered(rung: .clipboardPaste, verified: false),
                    engine: engine, kind: .dictation))
            answers.append(
                await ledger.finalize(id: id, outcome: .lost, engine: engine, kind: .dictation))
            answers.append(
                await ledger.recordSpan(
                    LatencySpan.recorded(name: .inject, elapsed: .milliseconds(3)), for: id))
            let ghost = SessionRecord.ID(rawValue: 4242)
            answers.append(
                await ledger.finalize(id: ghost, outcome: .aborted, engine: nil, kind: .onboarding))
            return (answers, await ledger.describe(), await ledger.snapshot())
        }

        let delivered = DeliveredRecords()
        let withSink = await drive(ledger(deliveringTo: { delivered.append($0) }))
        let withoutSink = await drive(LatencyLedger())

        XCTAssertEqual(
            withSink.answers, withoutSink.answers,
            """
            the sink changed what finalize (or a span write) answered: \(withSink.answers) vs \
            \(withoutSink.answers). The sink observes; it must never decide.
            """)
        XCTAssertEqual(
            withSink.described, withoutSink.described,
            """
            describe() differs with a sink installed. The zero-network probe counts P0's numbers \
            off this line — it is a permanent release blocker, and the sink may not touch it.
            """)
        XCTAssertEqual(withSink.snapshot, withoutSink.snapshot, "snapshot() is unchanged too")
        XCTAssertEqual(
            delivered.all.count, 1,
            "the drive finalizes exactly one session successfully, so exactly one is delivered")
    }

    /// **No sink installed is the shipped default, and it delivers nothing.**
    ///
    /// The ledger `AppBootstrap` composed before this aspect — and every test above — builds
    /// `LatencyLedger()` with no argument. That call must keep compiling and keep behaving: a
    /// record still lands in `snapshot()`, and the observer that was never installed stays empty.
    func testALedgerWithNoSinkRetainsTheRecordAndDeliversNothing() async throws {
        let neverInstalled = DeliveredRecords()
        let ledger = LatencyLedger()

        let id = await ledger.beginSession()
        let finalized = await ledger.finalize(
            id: id, outcome: .failsafeHeld, engine: engine, kind: .dictation)
        XCTAssertTrue(finalized, "finalize answers on its own terms with no sink to consult")

        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.count, 1, "the record is retained exactly as before")
        XCTAssertEqual(snapshot.first?.outcome, .failsafeHeld)
        XCTAssertEqual(
            neverInstalled.all, [],
            "a sink that was never installed receives nothing — the default is silence")
    }

    /// The ledger under test, with `sink` installed.
    ///
    /// A one-line factory rather than a construction repeated in five tests: the RED for this
    /// phase was these tests failing on delivery counts against a ledger that had nowhere to
    /// install a sink, and the factory is the single line that changed to make them pass.
    private func ledger(
        deliveringTo sink: @escaping @Sendable (SessionRecord) -> Void
    ) -> LatencyLedger {
        LatencyLedger(sink: sink)
    }
}

/// The records a ledger's sink delivered, in delivery order.
///
/// `@unchecked Sendable` over a lock, the ``PrinterSpy`` shape: the sink is `@Sendable` and is
/// invoked from inside the ledger actor, so the box crosses an isolation boundary and the lock is
/// what makes the crossing sound. The sink is synchronous by design, so appends here cannot
/// suspend the ledger mid-finalize.
private final class DeliveredRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [SessionRecord] = []

    func append(_ record: SessionRecord) {
        lock.lock()
        defer { lock.unlock() }
        records.append(record)
    }

    var all: [SessionRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }
}
