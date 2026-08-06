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
import XCTest

@testable import VoccaHotkey

/// **A `deinit` must not reach an isolation precondition, and this is the whole of that rule.**
///
/// `MainRunLoopTimer.stop()` and all four of `CGEventTapSource`'s seam members open with
/// `MainActor.preconditionIsolated`. A precondition is **not** compiled out at `-O`, and a `deinit`
/// runs wherever the last release happens — which is not its object's choice. So a `deinit` that
/// reaches an asserting entry point is a release-build crash on a thread nobody chose.
///
/// Two files state that rule in their own documentation and two others broke it, in the same phase
/// that wrote it down: `ScheduledWatchdog` and `TapHealthTimer` both called the asserting `stop()`.
/// The chain that reaches it is the package's own — `CGEventTapSource.deinit` (deliberately
/// non-asserting, because it "runs wherever the last release happens") → `tearDown()` → `sink = nil`
/// → `ScheduledWatchdog.deinit` → `stop()` → trap.
///
/// **Nothing else in the suite can see this**, and that is why this file exists rather than an
/// assertion added to an existing test: every test in `HarnessTests` releases on the main actor, so
/// the precondition passes in all of them and the trap is invisible. The only observable fact is
/// *which entry point* the `deinit` took. The first two tests below ask the shipped objects; the
/// third asks the source tree, so that the fourth object to own a timer inherits the rule instead of
/// rediscovering it — `audio-capture` adds at least one.
final class DeinitIsolationTests: XCTestCase {

    // MARK: - The two objects that broke it

    /// `ScheduledWatchdog` tears its timer down through the non-asserting entry point.
    ///
    /// The teardown itself is asserted as well as the route, because the route is only worth having
    /// if it still stops the clock: a `deinit` that took the safe entry point and left a 150 ms timer
    /// running on the main run loop would trade a crash for a timer nothing can reach.
    func testReleasingAScheduledWatchdogTakesTheNonAssertingTeardown() {
        let timer = FakeTimer()

        do {
            let clock = TestClock()
            let keyboard = Keyboard()
            let machine = SessionMachine(
                configuration: HotkeyConfiguration(
                    keyCode: 49, modifiers: [.option], activation: .holdToTalk),
                ceiling: SessionCeiling.default, clock: clock, audioSource: RecordingSource())
            let watchdog = SessionWatchdog(machine: machine, keyState: TruthfulKeyState(keyboard))
            _ = ScheduledWatchdog(watchdog: watchdog, timer: timer) { _ in }
        }

        XCTAssertEqual(
            timer.stopCount, 0,
            """
            ScheduledWatchdog.deinit called the asserting stop(). MainRunLoopTimer.stop() opens with \
            MainActor.preconditionIsolated, which -O does not remove, and a deinit runs wherever the \
            last release happens. CGEventTapSource.deinit is documented as running anywhere and its \
            tearDown() sets `sink = nil` — and the sink is this object, so that chain ends in a \
            precondition failure in a release build.
            """)
        XCTAssertEqual(
            timer.stopWithoutAssertingIsolationCount, 1,
            "and it must still stop the clock — the safe route is not the same as no route")
        XCTAssertFalse(timer.isRunning)
    }

    /// The same for `TapHealthTimer`, whose timer is the ~1 s health poll.
    func testReleasingATapHealthTimerTakesTheNonAssertingTeardown() {
        let timer = FakeTimer()

        do {
            let policy = TapHealthPolicy(
                source: FakeHotkeyEventSource(), sink: AlwaysPassingThroughSink(),
                clock: TestClock(), secureInput: FakeSecureInputState()
            ) { _ in }
            let runtime = TapHealthTimer(policy: policy, timer: timer) { _ in }
            runtime.arm()
            XCTAssertTrue(timer.isRunning, "precondition: there is a clock to stop")
        }

        XCTAssertEqual(
            timer.stopCount, 0,
            """
            TapHealthTimer.deinit called the asserting stop(), for the same reason and at the same \
            cost as ScheduledWatchdog's. It is the one object an owner holds, so its release is the \
            release most likely to happen somewhere surprising.
            """)
        XCTAssertEqual(timer.stopWithoutAssertingIsolationCount, 1)
        XCTAssertFalse(timer.isRunning)
    }

    // MARK: - The rule, over the source tree

    /// **No `deinit` anywhere in `Sources/` calls anything that might assert its isolation.**
    ///
    /// The two tests above pin the two objects that got it wrong. This pins the *rule*, because the
    /// review that found them observed that this was the third time the rule had been needed and
    /// that `audio-capture` will need it a fourth — it adds at least one more object that owns a
    /// timer or a device handle and tears it down in `deinit`. A rule stated in a doc comment is
    /// re-discovered; a rule with a lint behind it is inherited.
    ///
    /// **What it permits is an allow-list and not a deny-list**, which is the direction that stays
    /// correct as the package grows: a `deinit` may call the teardowns named below and nothing else.
    /// A deny-list of `stop()` would pass the first `deinit` that reached `isDelivering`,
    /// `resumeDelivery()` or `endCapture()`.
    func testNoDeinitInTheSourcesReachesAnAssertingTeardown() throws {
        let root = try PackageRootLocator.find(from: #filePath)
        let sources = root.appendingPathComponent("Sources")
        let files = SwiftSourceScanner.swiftFiles(under: sources)
        XCTAssertFalse(files.isEmpty, "the lint found no sources to lint, which is not a pass")

        var found = 0
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for body in Self.deinitBodies(inSource: source) {
                found += 1
                let offenders = Self.callNames(inBody: body).subtracting(Self.permittedInADeinit)
                XCTAssertTrue(
                    offenders.isEmpty,
                    """
                    \(file.lastPathComponent): a deinit calls \
                    \(offenders.sorted().joined(separator: ", ")).

                    A deinit runs wherever the last release happens, so it must reach nothing that \
                    asserts an isolation domain — MainActor.preconditionIsolated is not compiled out \
                    at -O, and the crash lands in a release build on a thread the object did not \
                    choose. Route it to a non-asserting teardown instead, as MainRunLoopTimer, \
                    CGEventTapSource, ScheduledWatchdog and TapHealthTimer all do; if this call is a \
                    new such teardown, add it to `permittedInADeinit` with the reason it is safe.
                    """)
            }
        }

        XCTAssertGreaterThanOrEqual(
            found, 5,
            """
            The scan found \(found) deinits and there are at least five in Sources/ \
            (MainRunLoopTimer, CGEventTapSource, ScheduledWatchdog, TapHealthTimer, and — the \
            fourth time this rule was needed, exactly as predicted — AudioRingBuffer, which frees \
            the realtime thread's sample storage). A lint that parses nothing passes everything.
            """)
    }

    /// The positive controls, without which the test above is a scan that finds nothing and says so
    /// approvingly. Both halves: the shape that must be rejected, and the shape that must not be.
    func testTheDeinitLintCatchesThePlantedViolationsAndClearsTheShippedShape() {
        let violation = """
            final class Owner {
                deinit {
                    timer.stop()
                }
            }
            """
        let bodies = Self.deinitBodies(inSource: violation)
        XCTAssertEqual(bodies.count, 1, "the extractor did not find a planted deinit")
        XCTAssertEqual(
            Self.callNames(inBody: bodies[0]).subtracting(Self.permittedInADeinit), ["stop"],
            "the exact shape this file exists to forbid was not reported")

        let shipped = """
            final class Owner {
                deinit {
                    timer.stopWithoutAssertingIsolation()
                }
            }
            """
        XCTAssertTrue(
            Self.callNames(inBody: Self.deinitBodies(inSource: shipped)[0])
                .subtracting(Self.permittedInADeinit).isEmpty,
            "the shipped shape was reported as a violation, so the lint fails a correct build")

        // And a `deinit` written across several statements, because the extractor is brace-balanced
        // rather than line-based and a one-line-only reader would pass everything below the first.
        let multiple = """
            deinit {
                if somethingHolds {
                    handle.stop()
                }
                tearDown()
            }
            """
        XCTAssertEqual(
            Self.callNames(inBody: Self.deinitBodies(inSource: multiple)[0])
                .subtracting(Self.permittedInADeinit), ["stop"],
            "a call nested inside a deinit's own braces was not seen")

        // A commented-out violation is not one. Comments are stripped before the scan for the same
        // reason the import lint strips them.
        let commented = """
            deinit {
                // timer.stop()
                tearDown()
            }
            """
        XCTAssertTrue(
            Self.callNames(inBody: Self.deinitBodies(inSource: commented)[0])
                .subtracting(Self.permittedInADeinit).isEmpty,
            "a commented-out call was read as real, which makes the lint unusable")
    }

    // MARK: - The scan

    /// What a `deinit` may call.
    ///
    /// Each of these is a teardown written *without* an isolation assertion, precisely so that a
    /// `deinit` can reach it: `MainRunLoopTimer.tearDown()`, `CGEventTapSource.tearDown()`, and
    /// `RepeatingTimer.stopWithoutAssertingIsolation()`, whose shipped implementation is the first
    /// of those. Adding a name here is a claim that it asserts nothing, and it is checkable in one
    /// read.
    /// `AudioRingBuffer.deinit` frees the ring's preallocated sample storage. `deallocate()` is
    /// `free(3)` behind a pointer method — it takes no lock this process owns, reaches no actor,
    /// and asserts no isolation domain — so it is safe on whatever thread the last release lands
    /// on, which is the whole of the rule.
    static let permittedInADeinit: Set<String> = [
        "tearDown",
        "stopWithoutAssertingIsolation",
        "deallocate",
    ]

    /// The body of every `deinit` in `source`, brace-balanced, with comments already stripped.
    ///
    /// Deliberately a text scan, like ``SwiftSourceScanner`` and for the same reason — it has to run
    /// from a test with no build-system integration. It inherits that type's known limit: it is not
    /// string-literal aware. A `{` inside a string literal within a `deinit` would unbalance the
    /// body, which fails towards reading *too much* and so towards over-reporting, the safe
    /// direction for a lint.
    static func deinitBodies(inSource source: String) -> [String] {
        let text = Array(SwiftSourceScanner.stripComments(from: source))
        var bodies: [String] = []
        var index = 0

        while index < text.count {
            guard
                let start = Self.nextDeinitBrace(in: text, from: index)
            else { break }
            guard
                let found = SwiftSourceScanner.bracedBody(in: text, openingBraceIndex: start)
            else { break }

            bodies.append(found.body)
            index = found.closingBraceIndex + 1
        }
        return bodies
    }

    /// The index of the `{` opening the next `deinit` body at or after `from`, or `nil`.
    ///
    /// The `deinit` keyword is matched as a whole word — a member called `deinitialise` is not one —
    /// and only whitespace may separate it from its brace, which is the whole of the grammar.
    private static func nextDeinitBrace(in text: [Character], from: Int) -> Int? {
        let keyword = Array("deinit")
        var index = from
        while index + keyword.count < text.count {
            defer { index += 1 }
            guard Array(text[index..<(index + keyword.count)]) == keyword else { continue }
            if index > 0, text[index - 1].isLetter || text[index - 1].isNumber
                || text[index - 1] == "_"
            {
                continue
            }
            var after = index + keyword.count
            while after < text.count, text[after].isWhitespace { after += 1 }
            guard after < text.count, text[after] == "{" else { continue }
            return after
        }
        return nil
    }

    /// Every name called in `body`: the identifier immediately preceding a `(`.
    ///
    /// The parse moved to ``SwiftSourceScanner`` when `audio-capture`'s realtime lint needed the
    /// same one. This forwards rather than duplicating, for the reason that type's own header
    /// gives: a second copy is a second chance to diverge, and the divergence would be invisible —
    /// both lints would still pass.
    static func callNames(inBody body: String) -> Set<String> {
        SwiftSourceScanner.callNames(inBody: body)
    }
}
