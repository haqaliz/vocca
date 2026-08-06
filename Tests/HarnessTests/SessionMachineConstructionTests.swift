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
import XCTest

/// **Every `SessionMachine` built in `Sources/` must say which capture-start timing it wants.**
///
/// `SessionMachine.init` defaults `captureStartTiming` to `.immediately`, and that default is right:
/// it is what the machine did before the engine start was measured, and it keeps the pre-existing
/// tests exercising the identical transition, which is what makes the deferred timing provably
/// additive rather than a rewrite.
///
/// But `.immediately` is **not what ships**. It opens the microphone inside the tap callback, and
/// `AVAudioEngine.start()` was measured at 114 ms (`CaptureStartTiming`). So the default is safe for
/// a test and wrong for the application, and the two are told apart by nothing at all at the call
/// site — a forgotten fifth argument compiles, runs, passes 412 tests and ships the exact callback
/// this aspect exists to prevent.
///
/// A review of the commit that introduced the timing found precisely that state: the shipped case
/// appeared nowhere in `Sources/` outside its own declaration, and the mitigation on record —
/// "`ScheduledWatchdog` is what makes that owner impossible to get wrong" — was not true.
/// `ScheduledWatchdog` accepts a machine with either timing and never inspects it.
///
/// ## Why a lint rather than a precondition
///
/// The obvious alternative is for `ScheduledWatchdog.init` to `precondition` the timing. It was
/// rejected: `.immediately` beneath a `ScheduledWatchdog` is a *working* configuration — merely a
/// slow one — and several suites legitimately build exactly that to test the timer without a run
/// loop in the way. A precondition would forbid a correct combination in order to catch a missing
/// argument.
///
/// This rule forbids only the **silence**. Either case may be named; neither may be inherited. That
/// is the smallest thing that turns "someone must remember" into "the build says so", and it is the
/// same shape `CoreBoundaryTests` and `HotkeySeamBoundaryTests` already use.
///
/// **It is written now, while there is no composition root to argue with.** When `VoccaBootstrap`
/// stops being a placeholder, the first `SessionMachine(` it writes fails this test until it says
/// what it means.
final class SessionMachineConstructionTests: XCTestCase {

    /// Where a construction was found, for a failure message that names the file and the line.
    struct Construction {
        let file: String
        let line: Int
        let namesTheTiming: Bool
    }

    /// Text-scanned, for the reason every lint in this harness is: it needs no build-system
    /// integration. The scan errs towards *finding* constructions — one it failed to recognise would
    /// be one this rule silently permits, which is the only direction that matters here.
    ///
    /// **The argument list is delimited by balancing parentheses, not by a line budget**, and the
    /// first version of this scan used a ten-line window. That version reported the network probe's
    /// construction — the one construction in the tree, and one that *does* name the timing — as
    /// silent, because a doc comment sitting between the call and the argument pushed it to line
    /// twelve. A fixed window makes the rule sensitive to how the call is formatted, which is the
    /// one thing a lint about a *named argument* must not be.
    private func constructions() throws -> [Construction] {
        let sources = try PackageRootLocator.find(from: #filePath).appendingPathComponent("Sources")
        return try SwiftSourceScanner.swiftFiles(under: sources).flatMap { file in
            // Comments are stripped first, so a construction discussed in prose is not a
            // construction — including the ones in this rule's own failure message.
            Self.classify(
                SwiftSourceScanner.stripComments(
                    from: try String(contentsOf: file, encoding: .utf8)),
                file: file.lastPathComponent)
        }
    }

    /// **The verdict, separated from the file walk so that it can be put a question with a known
    /// answer.**
    ///
    /// It was one function with the walk until a review hard-coded `namesTheTiming: true` and watched
    /// all 416 tests pass. The rule above then approves every construction it finds, for ever, and
    /// the durable half of this aspect's most expensive finding asserts nothing — while
    /// ``testTheScanFindsTheConstructionItIsMeantToPolice``, written for exactly this class of rot,
    /// goes on passing because it only ever checked that the scan found *something*. Finding a
    /// construction and always approving it is the same rot from the other side.
    ///
    /// Split out and driven from literal fixtures below, so the classifier has to be able to answer
    /// `false`.
    static func classify(_ source: String, file: String) -> [Construction] {
        var found: [Construction] = []
        var searchFrom = source.startIndex

        while let call = source.range(of: "SessionMachine(", range: searchFrom..<source.endIndex) {
            searchFrom = call.upperBound

            // Balanced, so the argument list ends where the call ends. Searching the whole file
            // instead is invisible today — there is one construction per file — and wrong the first
            // time a file has two, one of them silent.
            var depth = 1
            var cursor = call.upperBound
            while cursor < source.endIndex, depth > 0 {
                if source[cursor] == "(" { depth += 1 }
                if source[cursor] == ")" { depth -= 1 }
                if depth > 0 { cursor = source.index(after: cursor) }
            }

            found.append(
                Construction(
                    file: file,
                    line: source[source.startIndex..<call.lowerBound].filter { $0 == "\n" }.count + 1,
                    namesTheTiming: source[call.upperBound..<cursor].contains("captureStartTiming")))
        }
        return found
    }

    /// The rule.
    func testEverySessionMachineBuiltInSourcesNamesItsCaptureStartTiming() throws {
        let silent = try constructions().filter { !$0.namesTheTiming }

        XCTAssertTrue(
            silent.isEmpty,
            """
            \(silent.map { "\($0.file):\($0.line)" }.joined(separator: ", ")) builds a SessionMachine \
            without naming `captureStartTiming:`, so it inherits the `.immediately` default.

            `.immediately` opens the microphone inside the tap callback, and AVAudioEngine.start() \
            was measured at 114 ms — see CaptureStartTiming. That is the callback stall, the input \
            lag in front of the whole keyboard, and the kCGEventTapDisabledByTimeout risk this \
            aspect exists to remove.

            Pass `captureStartTiming: .whenTheOwnerAsks` and make sure the owner drives \
            `completePendingOpening()` — `ScheduledWatchdog` does it for you. If you genuinely want \
            the inline open, say `.immediately` explicitly; this rule forbids the silence, not the \
            choice.
            """)
    }

    /// **Guards the guard.** A scan that found nothing would pass the rule above while asserting
    /// nothing at all — the classic way a source lint rots, and one this harness has been bitten by
    /// before.
    func testTheScanFindsTheConstructionItIsMeantToPolice() throws {
        let found = try constructions()

        XCTAssertFalse(
            found.isEmpty,
            """
            The scan found no SessionMachine construction anywhere in Sources/, so the rule above is \
            vacuous. Either the scan broke or the network probe's drive was removed — and that drive \
            is the only end-to-end exercise of the shipped capture-start timing in the package.
            """)
        XCTAssertTrue(
            found.contains { $0.file == "SessionLifecycleDrive.swift" },
            "The zero-network probe's drive is the construction this rule most exists for.")
    }

    /// **Guards the guard, from the other side: the classifier must be able to answer `false`.**
    ///
    /// The test above proves the scan *finds* things. It does not prove the verdict means anything —
    /// and a review demonstrated the gap by hard-coding `namesTheTiming: true`, which left the whole
    /// rule vacuous with 416 tests green. Two literal fixtures close it: one construction that names
    /// the timing and one that does not, over the same classifier the rule uses.
    ///
    /// The second fixture is the one that matters. It also puts both constructions in **one source**,
    /// which is what pins the argument list being delimited by balanced parentheses rather than by
    /// searching the whole file — a weaker classifier that scans the file would call both of these
    /// `true`, and today no real file has two constructions to catch it out.
    func testTheClassifierCanTellANamedTimingFromASilentOne() {
        let fixture = """
            let named = SessionMachine(
                configuration: configuration, ceiling: SessionCeiling.default, clock: clock,
                audioSource: microphone, captureStartTiming: .whenTheOwnerAsks)
            let silent = SessionMachine(
                configuration: configuration, ceiling: SessionCeiling.default, clock: clock,
                audioSource: microphone)
            """

        let found = SessionMachineConstructionTests.classify(fixture, file: "Fixture.swift")

        XCTAssertEqual(found.count, 2, "both constructions must be found")
        XCTAssertEqual(
            found.map(\.namesTheTiming), [true, false],
            """
            The classifier cannot tell a construction that names `captureStartTiming:` from one that \
            does not, so the rule above approves everything it finds and asserts nothing. That is \
            the state a review reached by hard-coding this verdict, with the whole suite green.
            """)
        XCTAssertEqual(found.map(\.line), [1, 4], "and it must report where")
    }
}
