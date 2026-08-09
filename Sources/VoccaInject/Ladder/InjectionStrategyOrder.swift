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

/// The order in which the ladder's rungs are attempted, for the target application.
///
/// The decision takes this seam's answer — the resolved rung list — and nothing else, so C8's
/// per-app strategy memory will be a *second implementation of this protocol* rather than a change
/// to the decision: the store remembers what failed for a given application and returns a
/// demoted order, and the ladder's rows re-test unchanged.
///
/// Two contracts hold over every implementation, because both are load-bearing for the decision
/// and the decision does not enforce them:
///
/// - ``InjectionRung/widgetFailsafe`` never appears in the attempt list. The failsafe is the
///   decision's terminal, not a rung to be tried — `plan_20260809.md` §3 pins the default, and a
///   second implementation that returned it would hand the decision a rung that cannot exist in
///   its strategy map.
/// - ``InjectionRung/accessibility`` appears only for allowlisted applications. It is the
///   read-back-verified rung, and offering it where it is not allowed would skip the guard that
///   makes its verification meaningful.
public protocol InjectionStrategyOrder: Sendable {
    /// The rungs to attempt, in order, for the focused application — `nil` when nothing is
    /// focused.
    func orderedRungs(for bundleID: String?) -> [InjectionRung]
}

/// The C4 pinned order: allowlisted applications start at accessibility; everyone else starts at
/// clipboard.
///
/// `ROADMAP.md:47`'s "clipboard-paste primary, AX opportunistic" is satisfied in exactly one
/// direction: AX is *first* only for allowlisted bundle identifiers — and since the C4 default
/// allowlist is empty (``EmptyInjectionAllowlist``), the ladder users actually run is
/// `clipboard → keystroke`, with accessibility available the moment the allowlist is seeded.
///
/// The allowlist is read at every call rather than cached: the focused application can change
/// between injections, and a stale answer would offer the verification rung to an application the
/// allowlist has since stopped trusting.
public struct DefaultInjectionStrategyOrder: InjectionStrategyOrder {
    /// The gatekeeper for the accessibility rung — injected, so the adapters aspect can seed it.
    public let allowlist: any InjectionAllowlist

    public init(allowlist: any InjectionAllowlist) {
        self.allowlist = allowlist
    }

    public func orderedRungs(for bundleID: String?) -> [InjectionRung] {
        guard let bundleID, allowlist.contains(bundleID: bundleID) else {
            return [.clipboardPaste, .keystrokeSynthesis]
        }
        return [.accessibility, .clipboardPaste, .keystrokeSynthesis]
    }
}
