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

/// **What asking for a new hotkey binding can answer** — `hotkey-rebinding/rebind-boundary` M5.
///
/// Three answers rather than a `Bool`, because *nothing changed* and *we would not change it* lead
/// to different sentences on the page, and a caller that cannot tell them apart writes one of them
/// wrong.
///
/// **Returned, not merely logged.** This follows the Speech tab's model-removal shape rather than
/// activation mode's silent no-op: a rebind that appears not to have registered invites a second
/// attempt, and the second attempt is made on a keyboard whose binding the user is no longer sure
/// of. The recorder in the General tab renders this value; nothing about the outcome is discovered
/// by reading a log.
///
/// Lives in `VoccaCore` because both ends need it and they cannot see each other: the mechanism is
/// the composition root's (`VoccaBootstrap`) and the surface is `VoccaUI`'s, which may import only
/// `VoccaCore` among Vocca modules (`ModuleBoundaryTests`).
public enum RebindOutcome: Sendable, Equatable {
    /// The chord is bound. It takes effect on the next press — nothing in flight was touched.
    case rebound

    /// The chord asked for is the one already bound. Nothing was rebuilt and nothing was written;
    /// re-choosing the running binding must not cost a rebuild.
    case unchanged

    /// The binding was **not** changed, and this is why.
    case refused(RebindRefusal)
}

/// **Why a rebind was refused.**
///
/// A closed set, and `CaseIterable` so that the exhaustiveness test can iterate it: a fourth reason
/// must state itself here — and be given copy — rather than reaching a user as a rebind that
/// silently did nothing.
public enum RebindRefusal: Sendable, Equatable, CaseIterable {
    /// **A session is in flight**, in one of the two machines — not necessarily the routed one.
    ///
    /// The load-bearing refusal. A rebind is a rebuild, and rebuilding under a running session
    /// would discard the machine that owns the open microphone: the session would be stranded on a
    /// key nobody is holding, which is roadmap C1-A, *stuck recording*, rated Fatal for trust. The
    /// user gets the new binding on their next press instead, which costs them nothing they can
    /// see.
    case sessionInFlight

    /// **The chord may not be bound** — ``HotkeyBindingRules`` refused it.
    ///
    /// Overwhelmingly a bare text-entry key: binding one makes that key untypeable on the whole
    /// machine, and the way out is a Settings window the user now needs that keyboard to reach.
    case notBindable
}
