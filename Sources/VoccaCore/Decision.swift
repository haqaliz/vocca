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

/// Whether the observed key event continues on to the focused application.
///
/// Separate from ``Decision/Action`` because the two are genuinely independent: a hotkey press
/// that starts a session must not also type a space into the user's document, and an event this
/// module has no interest in must not be eaten on its way to the app that does.
public enum EventPropagation: Sendable, Hashable, CaseIterable {
    /// Hand the event on. Anything Vocca does not claim must reach the focused application
    /// untouched — swallowing by accident makes the whole machine feel broken.
    case passThrough

    /// Consume the event. The user pressed Vocca's hotkey, not their editor's.
    case swallow
}

/// What the caller must do about one observed event.
///
/// The four values the session rules produce are all expressible here, and named as such because
/// the spec names them:
///
/// | Intent | Value |
/// |---|---|
/// | start | `Decision(action: .start, eventPropagation: .swallow)` |
/// | stop | `Decision(action: .stop(reason), eventPropagation: .swallow)` |
/// | ignore | `Decision(action: .ignore, eventPropagation: .passThrough)` |
/// | swallow and ignore | `Decision(action: .ignore, eventPropagation: .swallow)` |
///
/// **The caller cannot *silently* drop one** — which is the true claim, and narrower than it is
/// tempting to write. `decide(event, state:)` on its own warns that the result is unused, and CI
/// fails the build on any warning; `_ = decide(event, state:)` is one character longer and is
/// silent. No Swift type can prevent that. What is arranged is that ignoring a decision has to be
/// written down:
///
/// 1. `decide(_:state:)` returns this and is not — must never be — `@discardableResult`, which is
///    the one line that would remove even the bare-drop warning. `CoreBoundaryTests` asserts that
///    the annotation appears nowhere in this module.
/// 2. There is no "nothing to do" value. `.ignore` still carries a propagation choice, so even the
///    uninteresting events force the caller to state whether the app downstream sees them.
/// 3. Nothing here is readable except by destructuring it. There is no `isStart` shortcut to
///    consult while leaving the rest of the decision on the floor; both fields are the API.
///
/// No convenience constructors, deliberately. Which events get swallowed is policy, and policy
/// belongs to the decision function — a default here would be that policy written where nobody
/// reviewing the rules would look for it.
public struct Decision: Sendable, Hashable {

    /// The session-level instruction. Exhaustive and switched without `default:` everywhere, so a
    /// fifth action cannot silently inherit an existing branch.
    public enum Action: Sendable, Hashable {
        /// Open the microphone and begin a session.
        case start

        /// End the in-flight session through the single stop funnel, for this reason.
        case stop(EndReason)

        /// This event changes nothing about the session.
        case ignore
    }

    public let action: Action
    public let eventPropagation: EventPropagation

    public init(action: Action, eventPropagation: EventPropagation) {
        self.action = action
        self.eventPropagation = eventPropagation
    }
}
