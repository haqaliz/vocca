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

/// Which focused applications may be typed into through the accessibility rung.
///
/// Accessibility insertion is the only rung that reads back and verifies — and it is also the
/// rung most likely to be wrong about itself, which is why it is **allowlist-gated** as well as
/// verified (`ARCHITECTURE.md:398-399`): a bundle identifier the allowlist does not know is never
/// offered the first rung at all. `DefaultInjectionStrategyOrder` is the consumer; the decision
/// never reads this protocol, so the gating cannot skip a decision-table row.
///
/// The C4 default is ``EmptyInjectionAllowlist`` — nothing is allowed, making clipboard the de
/// facto primary rung (`ROADMAP.md:47`). The seeded list of trustworthy applications ships with
/// the adapters aspect, as data rather than as a decision.
public protocol InjectionAllowlist: Sendable {
    /// Whether `bundleID` may be reached through the accessibility rung.
    func contains(bundleID: String) -> Bool
}

/// The C4 default allowlist: nothing is allowed.
///
/// Deliberately empty — the seeded list lands in the adapters aspect — so the default ladder is
/// exactly `clipboard → keystroke → failsafe`, and accessibility becomes available only to
/// applications a later aspect explicitly lists. A default that allowed everything would make the
/// verification rung's guard invisible in the state most users run in.
public struct EmptyInjectionAllowlist: InjectionAllowlist {
    public init() {}

    public func contains(bundleID: String) -> Bool {
        false
    }
}
