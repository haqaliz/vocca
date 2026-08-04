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

/// A keyboard event, reduced to the five facts the session rules actually consult.
///
/// Plain data on purpose. No `CGEvent` ever crosses this boundary — that is precisely what makes
/// the start and stop rules testable: a test constructs one of these directly, with no event tap,
/// no Accessibility grant and no keyboard. `VoccaHotkey` builds these from real `CGEvent`s at the
/// seam, and that translation is the only part of the path a CI runner cannot execute.
public struct RawKeyEvent: Sendable, Hashable {

    /// What the event is. Exhaustive and payload-free, so every rule that switches on it must
    /// state a policy for each kind — adding a sixth kind here is a compile error at each switch
    /// rather than a silent inheritance of someone else's branch.
    public enum Kind: Sendable, Hashable, CaseIterable {
        case keyDown
        case keyUp
        /// A modifier was pressed or released. Carries no key code of its own that matters here:
        /// what matters is ``RawKeyEvent/modifiers``, which is read fresh from every event.
        case flagsChanged
        /// The OS disabled the event tap (`tapDisabledByTimeout` / `tapDisabledByUserInput`).
        /// The key-up for an in-flight session is never coming, which is why this is an event and
        /// not an error: it is a stop trigger like any other.
        case tapDisabled
    }

    public let kind: Kind

    /// The virtual key code, as macOS numbers them. Meaningless to compare across layouts, which
    /// is fine — it is only ever compared against the configured hotkey's code.
    public let keyCode: UInt16

    /// The modifiers carried *by this event*. Always the event's own flags, never a running total
    /// maintained across events — see ``ModifierSet`` for why that distinction is load-bearing.
    public let modifiers: ModifierSet

    /// `true` when macOS generated this key-down by holding the key, not by a fresh press.
    /// A session must neither restart nor end on one.
    public let isAutorepeat: Bool

    /// Time since an arbitrary, process-local, monotonic origin.
    ///
    /// A `Duration` rather than a `Date` deliberately: only *differences* between two of these are
    /// meaningful, and that is all the ceiling and the poll interval ever need. A wall-clock
    /// reading would make both wrong across an NTP step or a daylight-saving change, and would put
    /// a clock read inside a module whose defining property is that it has no I/O. The value is
    /// supplied by the caller — the module never reads a clock itself.
    public let timestamp: Duration

    public init(
        kind: Kind,
        keyCode: UInt16,
        modifiers: ModifierSet,
        isAutorepeat: Bool,
        timestamp: Duration
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isAutorepeat = isAutorepeat
        self.timestamp = timestamp
    }
}
