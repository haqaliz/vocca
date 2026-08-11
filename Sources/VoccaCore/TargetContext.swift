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

/// Everything the ladder knows about the application the user is typing into.
///
/// Deliberately small and deliberately free of system types. `ARCHITECTURE.md:161-166` once
/// carried an `axElement` on this struct; the aspect decision is that the AX element is resolved
/// *inside* `VoccaInject`, not here — `VoccaCore` imports nothing, so a Core-owned context could
/// not name `AXElementRef` anyway, but the reason is design rather than capability: the decision
/// function must be testable over a context a test builds by hand, and an opaque handle a test
/// cannot fabricate would make the whole ladder untestable above the seam.
///
/// The two fields the decision actually reads are the two refusals:
///
/// - `bundleID == nil` means *nothing is focused*, and the decision fails over to the widget
///   before any rung runs (reason `.noFocusedField`, `PRODUCT_SPEC.md:113`);
/// - `isSecureInput` means the user is typing into a password field, and the decision refuses at
///   rung 0 with reason `.secureInput` (`ARCHITECTURE.md:382-384`) — an honest refusal, never a
///   silent no-op.
///
/// `windowTitle` is carried for the failsafe window's "{app}" copy
/// (`PRODUCT_SPEC.md:112`), not for any decision. `Equatable` is what the Phase C
/// decision-table tests assert over.
public struct TargetContext: Sendable, Equatable {
    /// The focused application's bundle identifier; `nil` when nothing is focused.
    public var bundleID: String?
    /// The focused window's title; `nil` when there is none to report.
    public var windowTitle: String?
    /// Whether Secure Input was in force at capture time — the read the resolver makes once, at
    /// injection time, and this struct carries into the decision.
    public var isSecureInput: Bool

    /// A context as the resolver observed it: the focused app, its window, and the Secure Input
    /// state. Plain memberwise — a test builds these by hand, so the init is public and free of
    /// defaults that could hide a missing resolver read.
    public init(bundleID: String?, windowTitle: String?, isSecureInput: Bool) {
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.isSecureInput = isSecureInput
    }
}
