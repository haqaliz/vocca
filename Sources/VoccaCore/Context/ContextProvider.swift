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

/// The pluggable context boundary (C12 PRD M1, `CAPABILITY_ROADMAP.md:416` — **local only by
/// design, no hosted counterpart**): the active application and selection snapshot a turn
/// starts from.
///
/// The seam is the plainest possible boundary: the caller asks for the current snapshot and
/// gets it — **input is nothing** (no `prepare()`, no capability flag, no provider identity; a
/// snapshot is consumed immediately and discarded, nothing downstream attributes it) and
/// **output is the plain-data ``ContextSnapshot``**, read at turn start, off the
/// key-release → text-on-screen critical path (`prd.md:149-151`).
///
/// The call is **synchronous and non-throwing** (PRD R1, `prd.md:166-170`): a failure resolves
/// to an empty snapshot, never throws — expressed in the type system, so the adapter cannot be
/// caught mid-turn and the ``NullContext``-style honesty the PRD names is the empty snapshot.
/// `AccessibilityContext` inherits this posture structurally: the later adapter cannot invent
/// a throwing shape without a reviewed signature change here (the frozen-signature doctrine).
///
/// Two implementations ship behind this seam (`CAPABILITY_ROADMAP.md:432`, the seam doctrine
/// met, not exempted — the split is across aspects by design):
///
/// - ``NullContext`` — this aspect's shipped default in `VoccaCore`: reads nothing, the honest
///   stand-in until the consent gate is on;
/// - `AccessibilityContext` — `accessibility-context`'s aspect, in the new `VoccaContext`
///   module (`ARCHITECTURE.md:151,281`): every AX read, gated on consent.
///
/// The seam itself carries **no consent and no state** — the consent gate, the widget
/// indicator, and the kill switch are the later aspects' (`consent-store`, `widget-indicator`).
public protocol ContextProvider: Sendable {

    /// The current active-application snapshot: bundle identifier, window title, and selection.
    ///
    /// - Returns: the snapshot as observed at the call's moment. A failure resolves to the
    ///   all-absent snapshot, never a throw.
    func resolveCurrent() -> ContextSnapshot
}