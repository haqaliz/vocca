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
import VoccaInject
import XCTest

/// The accessibility rung of the injection ladder, and the resolution that feeds the ladder its
/// target (`docs/planning/injection-ladder/injection-adapters/plan_20260809.md` §2 Phase C).
///
/// Everything the rung can be asked over a seam lives here — the `TapHealthPolicy` precedent
/// again: the AX adapter (`AXSource`) is executed by nothing in CI (it needs an Accessibility
/// grant, and TCC cannot be granted on a hosted runner), so every decision sits above it, over
/// injected handles:
///
/// - the allowlist gate in its C12 shape: an unallowlisted application is declined **before**
///   any AX call — not read-then-discard, but never read, asserted with a seam that fails the
///   test if it is touched;
/// - the verification rule: the rung reports `succeeded(verified:)` from an injected
///   insert+read-back reader, faithfully — the *interpretation* ("unverified = failure") is the
///   decision function's, already pinned in the seam aspect's fault suite;
/// - target resolution over injected reads: the focused application's identity and a fresh
///   Secure Input read land in a ``TargetContext``, and the context carries no AX element (PRD
///   R1 — the element is resolved inside the adapter file and never crosses the seam).
///
/// The class is `@MainActor` like the ladder it drives; every rung and resolver under test is
/// itself an actor, so the tests cross the same boundary the composition root will.
@MainActor
final class AccessibilityRungTests: XCTestCase {

    // MARK: - Small builders

    private func target(
        bundleID: String?, secureInput: Bool = false
    ) -> TargetContext {
        TargetContext(bundleID: bundleID, windowTitle: nil, isSecureInput: secureInput)
    }

    // MARK: - The allowlist gate (the never-read shape)

    /// The gate's load-bearing shape: an unallowlisted bundle ID is declined *before* any AX
    /// call — the "not read-then-discard, but never read" shape C12 requires of context. The
    /// assertion is the seam itself: either of its three methods failing the test is the
    /// violation.
    func testUnallowlistedBundleDeclinesBeforeAnyAXCall() async {
        let rung = AccessibilityRungStrategy(
            allowlist: FakeInjectionAllowlist(allowed: ["com.example.Allowed"]),
            insert: ForbiddenAXSeam())

        let attempt = await rung.tryInject(
            "the words", into: target(bundleID: "com.example.Unknown"))

        XCTAssertEqual(attempt, .failed, "a declined rung reports that it did not deliver")
    }

    /// Nothing focused is declined too: a `nil` bundle ID cannot be allowlisted, so the rung
    /// must not reach for the focused element on its behalf.
    func testNilBundleDeclinesBeforeAnyAXCall() async {
        let rung = AccessibilityRungStrategy(
            allowlist: FakeInjectionAllowlist(allowed: ["com.example.Allowed"]),
            insert: ForbiddenAXSeam())

        let attempt = await rung.tryInject("the words", into: target(bundleID: nil))

        XCTAssertEqual(attempt, .failed)
    }

    /// The C4 default allowlist is empty, so the rung consulted with it declines an app that
    /// would otherwise be served — the default ladder is `clipboard → keystroke → failsafe`,
    /// with accessibility appearing the moment the allowlist is seeded.
    func testEmptyAllowlistDeclinesBeforeAnyAXCall() async {
        let rung = AccessibilityRungStrategy(
            allowlist: EmptyInjectionAllowlist(),
            insert: ForbiddenAXSeam())

        let attempt = await rung.tryInject(
            "the words", into: target(bundleID: "com.example.Notes"))

        XCTAssertEqual(attempt, .failed)
    }

    /// Positive control: an allowlisted app proceeds through resolve → insert → read-back, with
    /// the received text reaching the insert. The "never read" tests only mean something
    /// against this shape.
    func testAllowlistedBundleProceedsToTheInsert() async {
        let seam = RecordingAXSeam()
        let rung = AccessibilityRungStrategy(
            allowlist: FakeInjectionAllowlist(allowed: ["com.example.Allowed"]),
            insert: seam)

        let attempt = await rung.tryInject(
            "the words", into: target(bundleID: "com.example.Allowed"))

        XCTAssertEqual(attempt, .succeeded(verified: false), "read-back returned nil, so the rung must not claim verification")
        let resolveCalls = await seam.resolveCalls
        XCTAssertEqual(resolveCalls, 1)
        let insertCalls = await seam.insertCalls
        XCTAssertEqual(insertCalls, ["the words"], "the rung must pass the received text verbatim")
        let readBackCalls = await seam.readBackCalls
        XCTAssertEqual(readBackCalls, 1)
    }

    // MARK: - The verification rule

    /// A read-back that confirms the text reports `succeeded(verified: true)` — the rung's
    /// whole job is to report the confirmation truth, and only the truth.
    func testVerifiedWhenReadBackConfirmsTheInsert() async {
        let seam = RecordingAXSeam(readBack: "the words")
        let rung = AccessibilityRungStrategy(
            allowlist: FakeInjectionAllowlist(allowed: ["com.example.Allowed"]),
            insert: seam)

        let attempt = await rung.tryInject(
            "the words", into: target(bundleID: "com.example.Allowed"))

        XCTAssertEqual(attempt, .succeeded(verified: true))
    }

    /// A read-back that differs reports `succeeded(verified: false)` — the field holds
    /// something else, so the insert was not confirmed. Interpreting that as failure is the
    /// decision's, not this rung's.
    func testUnverifiedWhenReadBackDiffers() async {
        let seam = RecordingAXSeam(readBack: "other words")
        let rung = AccessibilityRungStrategy(
            allowlist: FakeInjectionAllowlist(allowed: ["com.example.Allowed"]),
            insert: seam)

        let attempt = await rung.tryInject(
            "the words", into: target(bundleID: "com.example.Allowed"))

        XCTAssertEqual(attempt, .succeeded(verified: false))
    }

    /// A read-back that cannot be produced reports `succeeded(verified: false)` too — no
    /// read-back is no verification, never a success.
    func testUnverifiedWhenReadBackReturnsNil() async {
        let seam = RecordingAXSeam()
        let rung = AccessibilityRungStrategy(
            allowlist: FakeInjectionAllowlist(allowed: ["com.example.Allowed"]),
            insert: seam)

        let attempt = await rung.tryInject(
            "the words", into: target(bundleID: "com.example.Allowed"))

        XCTAssertEqual(attempt, .succeeded(verified: false))
    }

    /// When the system says the insert was not made, the rung reports `.failed` — and never
    /// asks for a read-back of something that was not written.
    func testReportsFailedWhenTheInsertFailsWithoutAskingForAReadBack() async {
        let seam = RecordingAXSeam(insertResult: false)
        let rung = AccessibilityRungStrategy(
            allowlist: FakeInjectionAllowlist(allowed: ["com.example.Allowed"]),
            insert: seam)

        let attempt = await rung.tryInject(
            "the words", into: target(bundleID: "com.example.Allowed"))

        XCTAssertEqual(attempt, .failed)
        let insertCalls = await seam.insertCalls
        XCTAssertEqual(insertCalls, ["the words"])
        let readBackCalls = await seam.readBackCalls
        XCTAssertEqual(readBackCalls, 0, "no read-back may be asked for when nothing was inserted")
    }

    /// A rung that cannot resolve the focused element — no Automation permission, no focused
    /// field — reports `.failed`: the fall-through row of the plan's edge-case table
    /// (`plan §6`), on which the ladder drops to the clipboard rung.
    func testRungThatCannotResolveTheFocusedAppReportsFailed() async {
        let seam = RecordingAXSeam(resolveResult: false)
        let rung = AccessibilityRungStrategy(
            allowlist: FakeInjectionAllowlist(allowed: ["com.example.Allowed"]),
            insert: seam)

        let attempt = await rung.tryInject(
            "the words", into: target(bundleID: "com.example.Allowed"))

        XCTAssertEqual(attempt, .failed)
        let insertCalls = await seam.insertCalls
        XCTAssertTrue(insertCalls.isEmpty, "no insert may be attempted when the focused element could not be resolved")
        let readBackCalls = await seam.readBackCalls
        XCTAssertEqual(readBackCalls, 0)
    }

    // MARK: - Target resolution over injected reads

    /// The focused application resolves to its bundle ID and window title — the two identity
    /// facts the ladder reads off the context.
    func testFocusedAppResolvesToBundleIDAndWindowTitle() async {
        let resolver = TargetResolution(
            focusedApp: FakeFocusedAppReader(
                identity: FocusedAppIdentity(
                    bundleID: "com.example.Notes", windowTitle: "Notes - The Draft")),
            secureInput: FakeSecureInputReader())

        let context = await resolver.resolve()

        XCTAssertEqual(context.bundleID, "com.example.Notes")
        XCTAssertEqual(context.windowTitle, "Notes - The Draft")
        XCTAssertFalse(context.isSecureInput)
    }

    /// Nothing focused resolves to a `nil` bundle ID — the exact shape the decision's
    /// `.noFocusedField` row keys on (`PRODUCT_SPEC.md:113`).
    func testNothingFocusedResolvesToNilBundleID() async {
        let resolver = TargetResolution(
            focusedApp: FakeFocusedAppReader(),
            secureInput: FakeSecureInputReader())

        let context = await resolver.resolve()

        XCTAssertNil(context.bundleID, "nothing focused must drive the .noFocusedField row")
        XCTAssertNil(context.windowTitle)
        XCTAssertFalse(context.isSecureInput)
    }

    /// A focused application that yields no bundle identifier resolves to `nil` too: an app
    /// that cannot be identified cannot be allowlist-gated, so it is the same `.noFocusedField`
    /// row — the decision about what to do when there is no usable focus is the resolver's.
    func testFocusedAppWithoutBundleIDResolvesToNilBundleID() async {
        let resolver = TargetResolution(
            focusedApp: FakeFocusedAppReader(
                identity: FocusedAppIdentity(bundleID: nil, windowTitle: "Untitled")),
            secureInput: FakeSecureInputReader())

        let context = await resolver.resolve()

        XCTAssertNil(context.bundleID)
        XCTAssertEqual(context.windowTitle, "Untitled")
    }

    /// Secure Input is read *at resolution time*, freshly, every time — never cached at
    /// construction. The fake's answer changes between two resolutions, and the second context
    /// carries the new answer: a stale answer would type into a password field.
    func testSecureInputIsReadFreshAtResolutionTime() async {
        let secureInput = FakeSecureInputReader()
        let resolver = TargetResolution(
            focusedApp: FakeFocusedAppReader(
                identity: FocusedAppIdentity(bundleID: "com.example.Notes", windowTitle: nil)),
            secureInput: secureInput)

        await secureInput.set(active: false)
        let first = await resolver.resolve()
        XCTAssertFalse(first.isSecureInput)

        await secureInput.set(active: true)
        let second = await resolver.resolve()
        XCTAssertTrue(second.isSecureInput, "the read must happen at resolution time, not construction")
    }

    /// The Secure Input read is unconditional — it happens even when nothing is focused,
    /// because the decision checks `isSecureInput` before it checks `bundleID` and both rows
    /// need their answer fresh.
    func testSecureInputIsReadEvenWhenNothingIsFocused() async {
        let resolver = TargetResolution(
            focusedApp: FakeFocusedAppReader(),
            secureInput: FakeSecureInputReader(active: true))

        let context = await resolver.resolve()

        XCTAssertNil(context.bundleID)
        XCTAssertTrue(context.isSecureInput)
    }

    // MARK: - The target carries no AX element (PRD R1)

    /// PRD R1, pinned: a ``TargetContext`` a test builds by hand carries exactly the three
    /// fields the decision reads — the AX element is resolved inside the adapter file and never
    /// crosses the seam (`TargetContext`'s doc comment tells you why the type cannot even name
    /// it). A field added here is a reviewed change to the seam, not a silent one.
    func testTargetContextCarriesNoAXElement() {
        let context = TargetContext(
            bundleID: "com.example.Notes", windowTitle: nil, isSecureInput: false)
        let names = Mirror(reflecting: context).children.map { $0.label ?? "<nil>" }

        XCTAssertEqual(
            names, ["bundleID", "windowTitle", "isSecureInput"],
            "an AX element (or anything else) must not cross the seam into the decision's context")
    }
}

// MARK: - Test doubles

/// **An AX seam that fails the test if it is touched** — the never-read shape's tripwire.
///
/// The allowlist gate's assertion is this object: for an unallowlisted application, all three
/// methods failing the test *is* the test. An actor, per the repo's boundary doctrine
/// (`ASRTestDoubles.swift:36-38`): the seam crosses into the rung actor, and a fake on that
/// boundary must cross it honestly.
private actor ForbiddenAXSeam: AccessibilityInserting {
    func resolveFocusedElement() async -> Bool {
        XCTFail("The AX rung resolved the focused element for an unallowlisted application - the never-read shape was violated")
        return false
    }

    func insertSelectedText(_ text: String) async -> Bool {
        XCTFail("The AX rung inserted into an unallowlisted application - the never-read shape was violated")
        return false
    }

    func readBackValue() async -> String? {
        XCTFail("The AX rung read back from an unallowlisted application - the never-read shape was violated")
        return nil
    }
}

/// **A real insert+read-back seam, recording every call** — the raw answers fixed at
/// construction so a test varies exactly one thing. An actor, for the same boundary reason as
/// ``ForbiddenAXSeam``.
private actor RecordingAXSeam: AccessibilityInserting {
    private let resolveResult: Bool
    private let insertResult: Bool
    private let readBack: String?

    private(set) var resolveCalls = 0
    private(set) var insertCalls: [String] = []
    private(set) var readBackCalls = 0

    init(resolveResult: Bool = true, insertResult: Bool = true, readBack: String? = nil) {
        self.resolveResult = resolveResult
        self.insertResult = insertResult
        self.readBack = readBack
    }

    func resolveFocusedElement() async -> Bool {
        resolveCalls += 1
        return resolveResult
    }

    func insertSelectedText(_ text: String) async -> Bool {
        insertCalls.append(text)
        return insertResult
    }

    func readBackValue() async -> String? {
        readBackCalls += 1
        return readBack
    }
}

/// **A focused-app query the test dictates** — with the answer fixed at construction, like
/// ``FakeInjectionStrategy``'s outcome: resolution happens at most once per test in the tests
/// that use this, and the ones that need the focus to *change* use ``FakeSecureInputReader``'s
/// mutable shape instead. An actor, for the same boundary reason as ``ForbiddenAXSeam``.
private actor FakeFocusedAppReader: FocusedAppReading {
    private let identity: FocusedAppIdentity?
    private(set) var readCount = 0

    init(identity: FocusedAppIdentity? = nil) {
        self.identity = identity
    }

    func focusedApp() async -> FocusedAppIdentity? {
        readCount += 1
        return identity
    }
}

/// **A Secure Input read the test dictates** — mutable, because the freshness contract ("read at
/// resolution time, not construction") can only be shown by changing the answer between two
/// resolutions. An actor, for the same boundary reason as ``ForbiddenAXSeam``.
private actor FakeSecureInputReader: SecureInputReading {
    private var active: Bool
    private(set) var readCount = 0

    init(active: Bool = false) {
        self.active = active
    }

    func set(active: Bool) {
        self.active = active
    }

    func isSecureInputActive() async -> Bool {
        readCount += 1
        return active
    }
}
