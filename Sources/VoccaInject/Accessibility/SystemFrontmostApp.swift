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

/// **The frontmost-app adapter — the only file in `VoccaInject` permitted to name
/// `NSWorkspace`.**
///
/// ``FrontmostAppReading``'s real conformance: `NSWorkspace.shared.frontmostApplication`, the
/// system's own "which app is in front" fact, translated into plain data — the bundle
/// identifier and whether the application's activation policy is `.regular`. No AppKit type
/// crosses the seam (the R1 shape); ``FrontmostAppIdentity`` is the whole answer.
///
/// `nil` when there is no frontmost application.
///
/// Like the tap and AX adapters, this file is **executed by nothing in CI**: the frontmost
/// application of a hosted runner is not the Chromium app the fallback exists for, so no test
/// can drive it. Every decision about the answer — the `.regular` gate, the seeded no-field
/// set, the M6 read-count discipline — lives above the seam, in ``TargetResolution``, where it
/// is tested headlessly.
public final class SystemFrontmostApp: FrontmostAppReading, Sendable {

    /// The composition root's construction — a plain adapter, no arguments and no grants
    /// required to build it (the read needs no Accessibility grant).
    public init() {}

    /// The frontmost application's identity, raw: its bundle identifier and whether its
    /// activation policy is `.regular`. `nil` when there is no frontmost application.
    public func frontmostApp() async -> FrontmostAppIdentity? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontmostAppIdentity(
            bundleID: app.bundleIdentifier,
            isRegular: app.activationPolicy == .regular)
    }
}