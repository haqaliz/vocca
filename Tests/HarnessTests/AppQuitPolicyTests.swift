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

        func makePolicy() -> AppQuitPolicy {
            AppQuitPolicy(
                keepInTray: { self.keepInTray },
                stayInTray: { self.stayInTrayCalls += 1 })
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
}