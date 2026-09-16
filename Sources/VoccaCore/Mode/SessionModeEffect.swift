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

/// What one input did to the mode machine.
///
/// An enum rather than an optional outcome, for the reason every enum in this module is one
/// (`SessionEffect.swift:21-23`): it is switched without a `default:`, so a fifth thing the
/// machine can do has to be given a meaning at every call site instead of quietly landing in
/// someone else's branch.
///
/// ## The delivery contract for the wiring aspect
///
/// - `.started(m, epoch:)` → the owner activates m's wiring — dictate: the P0 loop; converse:
///   the turn loop — and the epoch-minted record is in flight.
/// - `.sessionControl(m)` → the owner forwards to the *active* wiring: dictate — the rules
///   decide (toggle-off / hold-release, never re-implemented here); converse — the stop
///   affordance's chord leg.
/// - `.refused` → a no-op: nothing delivered, nothing minted, the key's propagation stays the
///   routing table's concern. The other-mode chord is never a switch.
/// - `.stopped(m, epoch:, session:)` → the owner routes the stop to the active wiring and hands
///   the record onward (a transcript is never lost — the record is the typed carrier).
/// - `.unchanged` → nothing happened; the input was not one this state had anything to do with
///   (a stop or system trigger with no session).
public enum SessionModeEffect<Audio: CapturedAudio>: Sendable {
    /// A session began: the mode is active, the record minted at `epoch`.
    case started(SessionMode, epoch: UInt64)

    /// The active mode's own chord: session control for the running wiring.
    case sessionControl(SessionMode)

    /// The other mode's chord while one is active: refused, never a switch.
    case refused

    /// A session ended: the mode's record — buffer, transcript, target — travels out here.
    case stopped(SessionMode, epoch: UInt64, session: ModeSession<Audio>)

    /// Nothing happened — the input did not match this state.
    case unchanged
}

extension SessionModeEffect: Equatable where Audio: Equatable {}