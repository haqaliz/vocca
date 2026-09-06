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

import AppKit
import Synchronization
import VoccaBootstrap
import XCTest

/// **The quit policy's decision table** — the "keep in tray" option's tested half.
///
/// `applicationShouldTerminate` is executed by nothing in CI (a hosted runner never answers a
/// user's ⌘Q), so every decision the delegate can make lives in this table: whether the option
/// is on, whether the quit was marked intentional, and what the refused quit does. The wiring —
/// that the tray menu's Quit and the onboarding restart mark themselves, and that the policy is
/// installed as the application delegate by `main()` — is the smoke checklist's rows.
@MainActor
final class AppQuitPolicyTests: XCTestCase {

    /// The seams a test can drive: the option's answer and the refused quit's consequence,
    /// recorded rather than performed.
    @MainActor
    private final class Probe {
        var keepInTray = false
        var stayInTrayCalls = 0
        /// What the policy told AppKit about a deferred termination, in order. Recorded rather
        /// than sent: a real reply on a real `NSApplication` would be a test host asking to be
        /// terminated.
        var replies: [Bool] = []

        func makePolicy() -> AppQuitPolicy {
            AppQuitPolicy(
                keepInTray: { self.keepInTray },
                stayInTray: { self.stayInTrayCalls += 1 },
                replyWhenFinished: { self.replies.append($0) })
        }

        func makePolicy(finishing work: TerminationWork) -> AppQuitPolicy {
            AppQuitPolicy(
                keepInTray: { self.keepInTray },
                stayInTray: { self.stayInTrayCalls += 1 },
                flushBeforeTerminating: work.work,
                replyWhenFinished: { self.replies.append($0) })
        }
    }

    /// The shipped default quits: option off, any quit is `terminateNow` and the tray return
    /// never runs. The option must not change the behaviour of the other 99% of installs.
    func testWithTheOptionOffEveryQuitTerminatesNow() {
        let probe = Probe()
        let policy = probe.makePolicy()

        XCTAssertEqual(policy.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertEqual(probe.stayInTrayCalls, 0)

        policy.markIntentionalQuit()
        XCTAssertEqual(policy.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertEqual(probe.stayInTrayCalls, 0)
    }

    /// With the option on, a quit nobody marked intentional is refused and returns the app to
    /// the tray — the whole point of the option.
    func testWithTheOptionOnAnUnmarkedQuitIsRefusedAndReturnsToTheTray() {
        let probe = Probe()
        probe.keepInTray = true
        let policy = probe.makePolicy()

        XCTAssertEqual(policy.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(probe.stayInTrayCalls, 1, "the refused quit must run its consequence once")
    }

    /// A marked quit — the tray menu's Quit or the onboarding restart, whichever marks it —
    /// always terminates, whatever the option: the escape hatch the copy promises ("Use Quit
    /// Vocca to quit").
    func testAMarkedIntentionalQuitTerminatesWithTheOptionOn() {
        let probe = Probe()
        probe.keepInTray = true
        let policy = probe.makePolicy()

        policy.markIntentionalQuit()
        XCTAssertEqual(policy.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertEqual(probe.stayInTrayCalls, 0)
    }

    /// The mark is consumed by the quit it was made for: a refused quit leaves it clear, and the
    /// next quit is refused again. A mark that leaked would turn the option off after the first
    /// ⌘Q — the option silently stopped working.
    func testTheIntentionalMarkIsConsumedByTheQuitItWasMadeFor() {
        let probe = Probe()
        probe.keepInTray = true
        let policy = probe.makePolicy()

        policy.markIntentionalQuit()
        XCTAssertEqual(policy.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertEqual(probe.stayInTrayCalls, 0)

        XCTAssertEqual(policy.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(
            probe.stayInTrayCalls, 1,
            "the mark must not leak into the next quit — the option keeps refusing")
    }

    /// The option is asked at quit time, never cached: a toggle flipped in Settings while the
    /// window is up is honoured by the very next quit.
    func testTheOptionIsAskedAtQuitTimeNotCaptured() {
        let probe = Probe()
        let policy = probe.makePolicy()

        XCTAssertEqual(policy.applicationShouldTerminate(NSApplication.shared), .terminateNow)

        probe.keepInTray = true
        XCTAssertEqual(policy.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(probe.stayInTrayCalls, 1)
    }

    // MARK: - The work that must finish before the process ends (usage-wiring Phase 4)

    /// **A quit that has work to finish defers the termination and replies when it is done.**
    ///
    /// The daily-use ledger's unwritten counts live only in memory, and committing them is
    /// asynchronous. `.terminateNow` would end the process while the save was still in flight, so
    /// a policy with work installed answers `.terminateLater` — AppKit's documented "I will tell
    /// you when" — runs the work, and then replies.
    ///
    /// The reply is injected rather than sent to `NSApplication.shared`: a test host that told
    /// AppKit a real termination could proceed would be asking to be killed mid-suite.
    func testAQuitWithWorkToFinishDefersAndRepliesWhenTheWorkIsDone() async {
        let probe = Probe()
        let work = TerminationWork()
        let policy = probe.makePolicy(finishing: work)

        XCTAssertEqual(
            policy.applicationShouldTerminate(NSApplication.shared), .terminateLater,
            "a quit with work to finish must defer — `.terminateNow` races the save it exists for")

        await work.ran()
        XCTAssertEqual(work.runCount, 1, "the work runs exactly once per quit")
        XCTAssertEqual(
            probe.replies, [true],
            """
            the policy never told AppKit the termination could proceed. `.terminateLater` without \
            a reply is an app that refuses to quit.
            """)
    }

    /// With keep-in-tray on, a refused quit runs **no** termination work.
    ///
    /// The app is not ending: it is going back to the menu bar, where the ordinary write cadence
    /// goes on running. Committing here would put a file write on every ⌘Q of a session.
    func testARefusedQuitRunsNoTerminationWork() {
        let probe = Probe()
        probe.keepInTray = true
        let work = TerminationWork()
        let policy = probe.makePolicy(finishing: work)

        XCTAssertEqual(policy.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(work.runCount, 0, "a quit that was refused has nothing to finish")
        XCTAssertEqual(probe.replies, [], "a refused quit owes AppKit no reply")
    }

    /// The shipped default — no work installed — is `.terminateNow`, exactly as before.
    ///
    /// Pinned so the deferral cannot become the general case: an app that answers
    /// `.terminateLater` with nothing to do and nothing to reply with never quits at all.
    func testWithNoWorkInstalledTheQuitIsUnchanged() {
        let probe = Probe()
        let policy = probe.makePolicy()

        XCTAssertEqual(policy.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertEqual(probe.replies, [], "nothing was deferred, so nothing is replied to")
    }
}

/// The termination work a test installs: it records that it ran and lets the test await it,
/// because the whole point of `.terminateLater` is that the work outlives the delegate call.
private final class TerminationWork: Sendable {
    private let runs = Mutex<Int>(0)
    private let waiters = Mutex<[CheckedContinuation<Void, Never>]>([])

    var runCount: Int { runs.withLock { $0 } }

    /// The closure the policy is given.
    var work: @Sendable () async -> Void {
        { self.run() }
    }

    private func run() {
        runs.withLock { $0 += 1 }
        let pending = waiters.withLock { value -> [CheckedContinuation<Void, Never>] in
            defer { value = [] }
            return value
        }
        for waiter in pending { waiter.resume() }
    }

    /// Suspends until the work has run at least once.
    func ran() async {
        guard runCount == 0 else { return }
        await withCheckedContinuation { continuation in
            let alreadyRan = waiters.withLock { value -> Bool in
                guard runCount == 0 else { return true }
                value.append(continuation)
                return false
            }
            if alreadyRan { continuation.resume() }
        }
    }
}
