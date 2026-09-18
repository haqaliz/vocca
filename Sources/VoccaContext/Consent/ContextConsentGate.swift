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

/// **The never-read gate: the decision that declines before any content read** (PRD M4, D5).
///
/// The `AccessibilityRungStrategy.swift:99-104` shape, one level up: an unallowlisted bundle
/// ID — or a nil one — is declined **before a single AX call**. "There is no read-then-discard
/// path here": ``allows(bundleID:)`` is a pure decision over the loaded consent set, and the
/// only way past it is a consented, valid bundle ID.
///
/// ## The ordering contract (D6) — for `bootstrap-wiring`
///
/// The gate sits **between** the metadata read and the content read:
///
/// 1. the metadata read (bundle ID + window title — allowed unconditionally, M5's scoping:
///    the dictate path already reads them for the failsafe copy and matrix evidence);
/// 2. **this gate** — consent off → the refusal, and the content read never happens;
/// 3. the content read (selected text) — only for a consented app.
///
/// The ordering is asserted structurally in ``ContextConsentGateTests`` (recording fakes and
/// the planted-violation control): the gate is the decision, never the read — a composition
/// that consults the content read before the gate fails the acceptance.
///
/// The gate is a value over a `Set<String>` snapshot, `Sendable` — a decision carries no
/// mutable state, because a gate that could change between the decision and the read would be
/// a gate the composition could not trust.
public struct ContextConsentGate: Sendable {
    private let consented: Set<String>

    /// A gate over a consent snapshot as loaded from the store.
    public init(consented: Set<String>) {
        self.consented = consented
    }

    /// Whether the bundle ID may have its content read: nil → false, invalid → false,
    /// valid-but-unconsented → false, consented → true. A pure decision — no read, no side
    /// effect, no throw.
    public func allows(bundleID: String?) -> Bool {
        guard let bundleID, ConsentBundleID.isValid(bundleID) else { return false }
        return consented.contains(bundleID)
    }
}