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

/// The mode machine's input vocabulary: a **decided** mode intent, never a key event.
///
/// D3: the chord→mode mapping is the hotkey aspect's problem — the second chord's persistence,
/// rebinding, and the equality match (`SessionRules.swift:187`) — and it delivers the *decision*
/// here; the machine never sees a chord. The machine is chord-agnostic (no keyboard in
/// `VoccaCore` tests), and the equality semantics below it are pinned already — consumed, not
/// re-litigated.
///
/// The three cases are the whole of the input surface: `observe`'s switch is exhaustive over
/// this enum, so a fourth input has to be given a meaning at the transition table before it can
/// exist.
public enum SessionModeIntent: Sendable, Equatable {
    /// Start (or re-address) the given mode's session.
    ///
    /// From `.idle` this mints the epoch-minted record and activates the mode. While the *same*
    /// mode is active it is session control — the dictate chord's toggle-off / hold-release, or
    /// the converse stop affordance's chord leg. While the *other* mode is active it is
    /// `.refused`: starts are keyed to a mode, never inferred, and the refusal cannot be
    /// bypassed by a second opinion.
    case start(SessionMode)

    /// The stop affordance (R4/O5): ends the active session; `.unchanged` when idle.
    ///
    /// The exact surface — the converse chord again, Escape, the menu-bar toggle (`prd.md:142-145`)
    /// — is the widget aspect's decision; the machine exposes the stop so that aspect has one
    /// seam to wire.
    case stop

    /// A system-level trigger: every case ends the active session (`SystemTrigger`'s five),
    /// because continuous listening never outlives them (R4).
    case system(SystemTrigger)
}