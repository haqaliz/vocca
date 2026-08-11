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

/// **The identity of the focused application, raw** — what the AX system reported, before any
/// decision about what it means.
///
/// `bundleID == nil` when the query answered "nothing focused" *or* the focused application
/// yielded no bundle identifier; `windowTitle == nil` when there is no focused window to name.
/// The AX element itself never leaves the adapter (`TargetContext`'s PRD R1 shape): this struct
/// is the whole answer the focused-app query carries across the seam, and it is buildable by a
/// test — which is exactly what makes resolution headless-testable.
public struct FocusedAppIdentity: Sendable, Equatable {
    /// The focused application's bundle identifier; `nil` when nothing is focused or the
    /// focused application has none.
    public var bundleID: String?
    /// The focused window's title; `nil` when there is none to report.
    public var windowTitle: String?

    public init(bundleID: String?, windowTitle: String?) {
        self.bundleID = bundleID
        self.windowTitle = windowTitle
    }
}

/// **The seam for "which application is focused"** — the AX-focused-app query, taken out of the
/// resolver so resolution is headless-testable (`plan_20260809.md` §2 Phase C).
///
/// Answer the question **now**, every time. The focused application is a fact that changes under
/// Vocca's feet with no notification, and a cached answer would be a report of the world as it
/// was at some earlier injection.
///
/// `async`, because the seam crosses into the resolver actor — the fakes that answer it must be
/// honest actors, per the repo's boundary doctrine (`ASRTestDoubles.swift:36-38`). Class-bound
/// (`AnyObject`) for the reason every other state-read seam in this repo is
/// (``SecureInputStateReader``, in `VoccaHotkey`): a value-typed conformance would be copied at
/// construction, and a state read copied is a snapshot — the fake could not express focus
/// changing between resolutions.
public protocol FocusedAppReading: AnyObject, Sendable {
    /// The focused application's identity, raw; `nil` when nothing is focused.
    func focusedApp() async -> FocusedAppIdentity?
}

/// **The seam for "is Secure Input in force right now"** — the Carbon read, taken out of the
/// resolver so resolution is headless-testable.
///
/// Answer the question **now**, every time — Secure Input is a state that changes with no
/// notification, and the ladder's rung-0 refusal depends on the fresh read (PRD R2). What the
/// answer *means* — that no rung may attempt into a password field — is the decision's,
/// already pinned in the seam aspect. Unlike ``SecureInputStateReader`` (a synchronous `var`,
/// because its consumer, the tap-health policy, never crosses a boundary), this seam is `async`:
/// it crosses into the resolver actor. Class-bound for the same reason ``FocusedAppReading``
/// is.
public protocol SecureInputReading: AnyObject, Sendable {
    /// `true` when some application is holding Secure Input and no event tap is receiving key
    /// events.
    func isSecureInputActive() async -> Bool
}

/// **Focused-app resolution: turns the two injected reads into the ladder's ``TargetContext``.**
///
/// The decision about *which* application is focused is the AX call's raw output
/// (``FocusedAppReading``); the decisions that stand between the raw output and the ladder are
/// here:
///
/// - no focused application → `bundleID == nil`, the exact shape the decision's
///   `.noFocusedField` row keys on (`ARCHITECTURE.md:385-387`, `PRODUCT_SPEC.md:113`);
/// - a focused application that yields no bundle identifier → `bundleID == nil` too: an app
///   that cannot be identified cannot be allowlist-gated, so it is the same "no usable target"
///   row;
/// - Secure Input is read **once, at resolution time** (PRD R2) and carried in
///   ``TargetContext/isSecureInput`` — the fresh read, never a cached one, because the state
///   changes with no notification and the rung-0 refusal depends on it.
///
/// The window title is carried for the failsafe window's "{app}" copy; it is not a decision.
///
/// ## Isolation
///
/// An **actor**, for the same reason ``AccessibilityRungStrategy`` is: the focused-app query is
/// an AX call (``AXSource`` is the real conformance), and ``ARCHITECTURE.md:323``'s rule is that
/// AX calls never run on the main thread. The ladder's composition root is `@MainActor` — a
/// synchronous resolver it called directly would run its AX call on the main thread, which is
/// the frozen-UI shape the rule exists to prevent. A struct is what the *decision* half uses
/// (`decide` receives an already-resolved ``TargetContext``); this is the adapter half, where
/// the call is.
public actor TargetResolution {
    private let focusedApp: any FocusedAppReading
    private let secureInput: any SecureInputReading

    public init(focusedApp: any FocusedAppReading, secureInput: any SecureInputReading) {
        self.focusedApp = focusedApp
        self.secureInput = secureInput
    }

    /// One resolution: the focused application's identity and the Secure Input state, as a
    /// ``TargetContext`` the ladder can decide over.
    public func resolve() async -> TargetContext {
        let identity = await focusedApp.focusedApp()
        return TargetContext(
            bundleID: identity?.bundleID,
            windowTitle: identity?.windowTitle,
            isSecureInput: await secureInput.isSecureInputActive())
    }
}
