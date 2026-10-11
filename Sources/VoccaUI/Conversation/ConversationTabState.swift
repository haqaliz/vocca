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

/// The conversation as the Conversation tab was handed it: the recent turns, in append order.
///
/// The turns travel as the window's own rows — `VoccaUI` imports only `VoccaCore`
/// (`ModuleBoundaryTests`), so the store's `ConversationTurn`s are mapped to these at the
/// composition root, the `UsageSnapshot`/`SettingsBindings` precedent: the wiring answers a
/// plain value and the tab is testable with no store and no file system at all.
public struct ConversationSnapshot: Sendable, Equatable {
    /// The turns the store holds, in append order — the oldest first, as kept. Display order is
    /// the reducer's question (``ConversationTabReducer`` renders newest first, the
    /// ``UsageDayRow`` argument), not the store's.
    public var turns: [ConversationTurnRow]

    public init(turns: [ConversationTurnRow]) {
        self.turns = turns
    }
}

/// One row of the Conversation table: what the user said, what Vocca replied, and whether a
/// barge-in cut the reply off.
///
/// The store's record and this row are the same three fields — no wall-clock time, no session,
/// no IDs beyond what ordering needs (`prd.md` R1) — translated once at the root so the tab
/// never grows a second opinion about what a turn is.
public struct ConversationTurnRow: Sendable, Equatable, Identifiable {
    /// The turn's append position — the row's identity, stable across a reload (the store has
    /// no other ID, and order is the only thing bound to a turn).
    public let position: Int
    /// The cleaned utterance the user spoke.
    public let utterance: String
    /// The reply text that was committed to speak.
    public let reply: String
    /// Whether a barge-in interrupted this turn's reply.
    public let interrupted: Bool

    public var id: Int { position }

    public init(
        position: Int, utterance: String, reply: String, interrupted: Bool = false
    ) {
        self.position = position
        self.utterance = utterance
        self.reply = reply
        self.interrupted = interrupted
    }
}

/// What the Conversation tab is showing.
public struct ConversationTabState: Sendable, Equatable {
    /// The rows being rendered, **newest first** — the ``UsageDayRow`` ordering: a person
    /// opening this tab is looking for the latest exchange.
    public var rows: [ConversationTurnRow]
    /// Whether the window has been read. `false` with no rows is "we haven't looked yet"; `true`
    /// with no rows is the empty state, and the two must not render the same (the
    /// ``UsageTabState`` guard — a store that failed to load must never present itself as "no
    /// conversation" to a user who conversed an hour ago).
    public var isLoaded: Bool

    /// The state the window opens in.
    public static let initial = ConversationTabState(rows: [], isLoaded: false)

    public init(rows: [ConversationTurnRow], isLoaded: Bool) {
        self.rows = rows
        self.isLoaded = isLoaded
    }
}

/// Everything that can happen to the Conversation tab. A closed set, folded exhaustively, with
/// no time-based transition in it — the widget's never-auto-dismiss discipline, applied to a
/// settings surface for the same reason the Usage tab applies it: nothing here should change
/// while a user is reading it, which is also what makes the read-on-open page honest.
public enum ConversationTabAction: Sendable, Equatable {
    /// The window was read; these are its turns.
    case snapshotLoaded(ConversationSnapshot)
    /// The user forgot the conversation, and the store said so.
    case cleared
}

/// The Conversation tab's decisions — pure and clock-free: which order the stored turns render
/// in, and what a clear does to the window.
public enum ConversationTabReducer {

    public static func reduce(
        _ state: ConversationTabState, _ action: ConversationTabAction
    ) -> ConversationTabState {
        var next = state
        switch action {
        case .snapshotLoaded(let snapshot):
            // Newest first, the `rows(from:)` argument: the store keeps append order because
            // eviction takes from the front, and the tab renders the latest exchange first
            // because that is what a person opening it is looking for. The flip is a display
            // decision, made here where it is tested — never in the wiring.
            next.rows = snapshot.turns.reversed()
            next.isLoaded = true

        case .cleared:
            // `isLoaded` stays true. The file was read and is now empty; dropping back to the
            // unread state would put the page into "we haven't looked yet", which is a
            // different claim and a false one — the user has just watched it be emptied.
            next.rows = []
        }
        return next
    }
}