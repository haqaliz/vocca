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
import VoccaCore
import VoccaUI
import XCTest

/// The onboarding window's headless contracts (`first-run-permissions` A5) — the
/// ``FailsafePanelContractTests`` routing-fakes shape: the parts of the window that are not
/// chrome, driven headlessly. The window itself is glue "executed by nothing in CI" (a real
/// window needs a window server session — `SMOKE_CHECKLIST.md`'s onboarding rows are its first
/// execution), so what is asserted here is everything the window decides *between* the user's
/// intent and the seam:
///
/// - **Lazy construction** — the window is built only on ``show()``, never in its initializer,
///   which is what keeps `AppBootstrap.configure` window-free for the zero-network probe.
/// - **The activation-policy dance** (S2, the `SettingsWindow` shape): ``show()`` routes through
///   the injected policy-switch seam with `.regular`, ``windowWillClose`` routes through the
///   return seam with `.accessory` — every close path (SMOKE_CHECKLIST's load-bearing row).
/// - **Focus-taking** — the one window (with Settings) allowed to become key: the built window
///   canBecomeKey, because TRY IT's field must take a keystroke.
/// - **Restart is single-fire** (M3): the relaunch route fires the injected relaunch at most
///   once per presentation — a double-click must not relaunch twice — and a re-presentation
///   re-arms it, so a failed relaunch remains retryable (R2).
/// - **The TRY IT delivery wiring** (M6): the window registers its field into the root's
///   delivery sink, so a real dictation's transcript appends to the field and completes the
///   flow; a delivery with no registered destination fails honestly — the A4 documented refusal,
///   folded as ``OnboardingAction/tryItFailed`` and thrown, never a fabricated success.
@MainActor
final class OnboardingWindowContractTests: XCTestCase {

    // MARK: - The probe

    /// The raw status facts and the completion write, recorded — the ``OnboardingStoreTests``
    /// probe shape.
    private final class Probe {
        var trusted = true
        var tapArmed = true
        var microphone: MicrophoneAuthorizationStatus = .granted
        var completeCalls = 0

@MainActor
        func makeStore() -> OnboardingStore {
            OnboardingStore(
                accessibilityTrusted: { self.trusted },
                tapArmed: { self.tapArmed },
                microphoneStatus: { self.microphone },
                markComplete: { self.completeCalls += 1 })
        }
    }

    /// The activation-policy seam's recording channel.
    private final class PolicyRecorder {
        var policies: [NSApplication.ActivationPolicy] = []
        func apply(_ policy: NSApplication.ActivationPolicy) {
            policies.append(policy)
        }
    }

    /// The relaunch binding's recording channel.
    private final class RelaunchRecorder {
        var relaunches = 0
        func fire() {
            relaunches += 1
        }
    }

    /// A counting window builder — the laziness probe.
    private final class CountingBuilder {
        var builds = 0
        @MainActor
        func build() -> NSWindow {
            builds += 1
            return NSWindow()
        }
    }

    /// One fixture: the store over the probe, the delivery sink over the store, the recording
    /// seams (the activation-policy recorder is wired into the window by the fixture itself), and
    /// the window over all of them.
    @MainActor
    private final class Fixture {
        let probe: Probe
        let store: OnboardingStore
        let sink: OnboardingDeliverySink
        let policies: PolicyRecorder
        let relaunches: RelaunchRecorder
        let bindings: OnboardingBindings
        let window: OnboardingWindow

        init(
            probe: Probe = Probe(),
            makeWindow: (() -> NSWindow)? = nil
        ) {
            self.probe = probe
            let store = probe.makeStore()
            self.store = store
            self.sink = OnboardingDeliverySink(store: store)
            let policies = PolicyRecorder()
            self.policies = policies
            let relaunches = RelaunchRecorder()
            self.relaunches = relaunches
            self.bindings = OnboardingBindings(
                openAccessibilityPane: {},
                openMicrophonePane: {},
                requestMicrophoneAccess: {},
                makeDownloadSession: { nil },
                restart: { relaunches.fire() },
                hotkeyDisplayName: { "⌥Space" })
            self.window = OnboardingWindow(
                store: store,
                sink: sink,
                bindings: bindings,
                setActivationPolicy: { policies.apply($0) },
                makeWindow: makeWindow)
        }
    }

    // MARK: - Lazy construction

    /// The window is built lazily — constructed only on the first `show()`, never in its
    /// initializer: the property that keeps `configure` window-free (the probe's charter), held
    /// at the window's own surface.
    func testTheWindowIsConstructedLazilyOnTheFirstShow() {
        let builder = CountingBuilder()
        let fixture = Fixture(makeWindow: { builder.build() })

        XCTAssertEqual(builder.builds, 0, "the initializer must not construct the window")

        fixture.window.show()
        XCTAssertEqual(builder.builds, 1, "the first show constructs the window")

        fixture.window.show()
        XCTAssertEqual(builder.builds, 1, "a second show raises the existing window, not another")
    }

    // MARK: - The activation-policy dance (S2)

    /// `show()` routes through the policy-switch seam with `.regular` — the focus-taking
    /// window's entrance (`SettingsWindow`'s dance): an `LSUIElement` process cannot make a
    /// window key without briefly becoming a regular application.
    func testShowRoutesTheActivationPolicySwitchSeamToRegular() {
        let fixture = Fixture()
        fixture.window.show()
        fixture.window.show()

        XCTAssertEqual(
            fixture.policies.policies,
            [.regular, .regular],
            "every show must route the .regular switch — an accessory app's window cannot "
                + "become key")
    }

    /// `windowWillClose` routes the return seam with `.accessory` — every close path drops back
    /// to the accessory life (SMOKE_CHECKLIST step 80's load-bearing row: without it Vocca keeps
    /// a Dock icon and can steal the field it exists to type into).
    func testWindowWillCloseRoutesTheReturnSeamToAccessory() {
        let fixture = Fixture()
        fixture.window.show()

        fixture.window.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertEqual(fixture.policies.policies, [.regular, .accessory])
    }

    /// Closing the window folds `windowClosed` into the store: the flow resumes at the first
    /// incomplete step (S3) — a WELCOME window closed on a machine whose permissions are already
    /// met resumes at MODEL, not at the button the user already pressed.
    func testClosingTheWindowFoldsTheResumeIntoTheStore() {
        let probe = Probe()
        probe.trusted = true
        probe.tapArmed = true
        probe.microphone = .granted
        let fixture = Fixture(probe: probe)

        fixture.window.show()
        fixture.window.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertEqual(
            fixture.store.state.step, .model,
            "closing resumes at the first incomplete step — permissions met, no model decision")
    }

    // MARK: - Focus taking

    /// The built window can become key — the one property that makes TRY IT's field typeable:
    /// the inverse of `WidgetPanel`'s override, and every bit as deliberate. The real builder is
    /// used so the assertion is about the shipped window, not a stand-in.
    func testTheBuiltWindowCanBecomeKey() {
        let fixture = Fixture()
        fixture.window.show()

        XCTAssertTrue(
            fixture.window.presentedWindow?.canBecomeKey == true,
            "the onboarding window must be able to become key — TRY IT's field needs the "
                + "keyboard")
    }

    // MARK: - Restart is single-fire (M3)

    /// `[Restart Vocca]` fires the injected relaunch at most once per presentation: a
    /// double-click must not terminate and relaunch twice. A fresh presentation re-arms, so a
    /// failed relaunch remains retryable (R2 — the reducer keeps the offer after a request).
    func testRestartIsSingleFirePerPresentation() {
        let probe = Probe()
        probe.trusted = true
        probe.tapArmed = false
        let fixture = Fixture(probe: probe)
        fixture.store.fold(.accessibilityStatusChanged(.grantedNotArmed))

        fixture.window.restartRequested()
        fixture.window.restartRequested()
        fixture.window.restartRequested()

        XCTAssertEqual(
            fixture.relaunches.relaunches, 1,
            "a double-click must not relaunch twice")

        fixture.window.show()
        fixture.window.restartRequested()
        XCTAssertEqual(
            fixture.relaunches.relaunches, 2,
            "a fresh presentation re-arms the restart — a failed relaunch remains retryable")
    }

    /// A stray restart route on a window that is not showing the offer is a no-op — the route
    /// folds the reducer's request and fires nothing (the offer rides only on
    /// `grantedNotArmed`, M5c).
    func testRestartOutsideTheGrantedNotArmedStateFiresNothing() {
        let fixture = Fixture()

        fixture.window.restartRequested()

        XCTAssertEqual(fixture.relaunches.relaunches, 0)
        XCTAssertFalse(fixture.store.state.restartOffered)
    }

    // MARK: - The TRY IT delivery wiring (M6)

    /// The window registers its field into the root's delivery sink: a real dictation's
    /// transcript appends to the field — visible where the user is looking — and completes the
    /// flow (G5: "success here = onboarding complete"), writing the persisted flag.
    func testDeliveredTextAppendsToTheFieldAndCompletesTheFlow() async throws {
        let fixture = Fixture()
        fixture.window.show()

        try await fixture.sink.deliver("hello world")

        XCTAssertEqual(fixture.window.field.text, "hello world")
        XCTAssertTrue(fixture.store.state.completed)
        XCTAssertEqual(fixture.store.state.deliveredTranscript, "hello world")
        XCTAssertEqual(fixture.probe.completeCalls, 1)
    }

    /// A second dictation appends after the first — the field is a live transcript surface, and
    /// a completed flow stays completed (the reducer's guard, held at the sink).
    func testASecondDeliveryAppendsAndDoesNotUncomplete() async throws {
        let fixture = Fixture()
        fixture.window.show()
        try await fixture.sink.deliver("first")
        try await fixture.sink.deliver("second")

        XCTAssertEqual(fixture.window.field.text, "first second")
        XCTAssertTrue(fixture.store.state.completed)
        XCTAssertEqual(fixture.probe.completeCalls, 1)
    }

    /// A delivery while the window is **closed** refuses — the A4 documented "binding is gone"
    /// shape: the window answers `false`, the sink folds `tryItFailed` and throws, and the flow
    /// does **not** complete behind the user's back (a transcript must never land in a window
    /// nobody is looking at, and completion must be seen, G5).
    func testADeliveryToAClosedWindowFailsHonestly() async {
        let fixture = Fixture()
        fixture.window.show()
        fixture.window.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        do {
            try await fixture.sink.deliver("orphaned")
            XCTFail("a delivery to a closed window must throw — the binding is gone")
        } catch {
            // The expected refusal.
        }

        XCTAssertEqual(fixture.window.field.text, "", "nothing may land in a closed window")
        XCTAssertFalse(fixture.store.state.completed)
        XCTAssertEqual(fixture.probe.completeCalls, 0)
    }

    /// A delivery with no registered destination fails honestly — the A4 documented refusal
    /// (the binding is gone — the window closed mid-dictation): the sink throws, so the
    /// pipeline surfaces the reason-only failure and never fabricates a delivered result, and
    /// the store folds `tryItFailed` — the failure surface's own state, never a silent idle.
    func testADeliveryWithNoRegisteredDestinationFailsHonestly() async {
        let probe = Probe()
        let store = probe.makeStore()
        let sink = OnboardingDeliverySink(store: store)

        do {
            try await sink.deliver("orphaned")
            XCTFail("a delivery with no destination must throw — the A4 refusal")
        } catch {
            // The expected refusal.
        }

        XCTAssertFalse(store.state.completed)
        XCTAssertEqual(
            store.state.step, .welcome,
            "tryItFailed keeps the flow where it was — the failure is the surface's, never a "
                + "completion")
        XCTAssertEqual(probe.completeCalls, 0)
    }
}