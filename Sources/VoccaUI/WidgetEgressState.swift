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

import Foundation

/// Whether an active cleanup provider sends text off the machine — the egress badge's reducer
/// state (`egress-badge` M8, `PRODUCT_SPEC.md:250-264`).
///
/// The badge is **launch-derived**: the provider is resolve-once (`cleanup-config`), so the
/// composition root folds exactly one `WidgetAction/egressChanged` at launch — `.active(endpoint:)`
/// when a `requiresNetwork == true` provider is selected, `.none` otherwise. There is no
/// per-session transition in the reducer at all (`spec.md:57-58`), and no action other than the
/// wiring's own fold can change it — non-dismissable is structural, not a timer rule
/// (`spec.md:52-54`).
///
/// ``active(endpoint:)`` carries the configured endpoint for the hover copy (`BadgeCopy`), never
/// the key — `byok-provider`'s hygiene applies to every surface the badge renders.
public enum WidgetEgressState: Equatable, Sendable {
    /// No cleanup provider needs the network — the default, and the rules path's byte-for-byte
    /// state.
    case none
    /// A `requiresNetwork == true` provider is active; text is sent to `endpoint`.
    case active(endpoint: String)

    /// The wiring's fold from a resolved cleanup provider (`root-wiring`): `.active(endpoint:)`
    /// when the provider declares the network, `.none` otherwise. The one call the composition
    /// root makes at launch (resolve-once) — extracted here so the headless suite asserts the
    /// exact fold the root uses. `endpoint` is the resolver's ``egressEndpoint()``; the fallback
    /// is dead-but-honest (a `requiresNetwork` provider always has a validated endpoint), never
    /// the key.
    public static func fromResolvedProvider(
        requiresNetwork: Bool,
        endpoint: String?
    ) -> WidgetEgressState {
        requiresNetwork ? .active(endpoint: endpoint ?? "unknown endpoint") : .none
    }
}
