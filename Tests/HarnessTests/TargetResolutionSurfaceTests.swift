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

/// The `loop-wiring` Task 3 pin: the **composition root's construction surface** for target
/// resolution.
///
/// `VoccaBootstrap` must build the ladder's target resolver — `TargetResolution` over the two
/// shipped adapters, ``AXSource`` and ``SystemSecureInputRead`` — and it imports `VoccaInject`
/// like any consumer: no `@testable`. This file does the same, so every name it touches must be
/// `public` in the module; the moment either adapter drops back to `internal`, this file stops
/// compiling and the root's recipe is what breaks.
///
/// Two claims are pinned:
///
/// - **The surface**: the recipe `TargetResolution(focusedApp: AXSource(), secureInput:
///   SystemSecureInputRead())` compiles from outside the module, and the shipped adapters
///   type-erase to the seams the resolver takes. Construction only — running `resolve()` on the
///   real adapters would execute AX calls, which need an Accessibility grant CI cannot have
///   (the tap-adapter precedent, `SMOKE_CHECKLIST.md` steps 22-35).
/// - **The semantics**: the same recipe over the seam fakes resolves `bundleID`,
///   `windowTitle` and `isSecureInput` — the three facts the ladder's decision reads off
///   ``TargetContext`` (`TargetContext.swift:24-34`).
///
/// The fakes are per-file private actors, the repo's boundary norm (`AccessibilityRungTests.swift:
/// 356-389`): the seams cross into the resolver actor, so a double on that boundary must cross
/// it honestly.
final class TargetResolutionSurfaceTests: XCTestCase {

    /// The root's recipe, verbatim: `TargetResolution` with the two shipped adapters. This file
    /// deliberately imports `VoccaInject` without `@testable`, so this is a compile-time pin of
    /// the public surface — and the `is` checks pin that the type-erased values the resolver
    /// received really are the shipped adapters, which is the claim the root relies on when it
    /// injects them.
    func testTheRootsRecipeConstructsOverTheShippedAdapters() {
        let resolver = TargetResolution(
            focusedApp: AXSource(),
            secureInput: SystemSecureInputRead())

        let focusedApp: any FocusedAppReading = AXSource()
        let secureInput: any SecureInputReading = SystemSecureInputRead()
        XCTAssertTrue(focusedApp is AXSource,
            "the value the resolver receives is the shipped AX adapter, not a stand-in")
        XCTAssertTrue(secureInput is SystemSecureInputRead,
            "the value the resolver receives is the shipped Secure Input read, not a stand-in")
        XCTAssertNotNil(resolver)
    }

    /// The recipe's semantics, proven over the seam fakes (the real adapters would need a grant
    /// and real focus): one resolution turns the focused application's identity and the Secure
    /// Input state into the exact ``TargetContext`` the ladder's decision reads.
    func testTheRecipeResolvesBundleIDWindowTitleAndSecureInputOverTheSeamFakes() async {
        let resolver = TargetResolution(
            focusedApp: FakeFocusedAppReader(
                identity: FocusedAppIdentity(
                    bundleID: "com.example.Notes", windowTitle: "Notes - The Draft")),
            secureInput: FakeSecureInputReader(active: true))

        let context = await resolver.resolve()

        XCTAssertEqual(context.bundleID, "com.example.Notes")
        XCTAssertEqual(context.windowTitle, "Notes - The Draft")
        XCTAssertTrue(context.isSecureInput)
    }
}

// MARK: - Test doubles

/// A focused-app query the test dictates — the answer fixed at construction, like
/// ``AccessibilityRungTests``' own fake. An actor, for the boundary reason that one gives.
private actor FakeFocusedAppReader: FocusedAppReading {
    private let identity: FocusedAppIdentity?

    init(identity: FocusedAppIdentity? = nil) {
        self.identity = identity
    }

    func focusedApp() async -> FocusedAppIdentity? {
        identity
    }
}

/// A Secure Input read the test dictates. An actor, for the same boundary reason.
private actor FakeSecureInputReader: SecureInputReading {
    private let active: Bool

    init(active: Bool = false) {
        self.active = active
    }

    func isSecureInputActive() async -> Bool {
        active
    }
}
