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

/// One row of the Cleanup tab: one rung, with the words the spec gives it.
public struct CleanupTabRow: Sendable, Equatable, Identifiable {
    /// The rung this row offers — and the row's identity.
    public let kind: CleanupProviderKind
    /// Whether the file currently names this rung.
    public let isSelected: Bool
    /// Whether this rung has everything the file needs to decode it. A rung that does not is
    /// still shown and still explains itself — hiding it would leave a user with no way to find
    /// out what is missing.
    public let isConfigured: Bool

    public var id: CleanupProviderKind { kind }

    public init(kind: CleanupProviderKind, isSelected: Bool, isConfigured: Bool) {
        self.kind = kind
        self.isSelected = isSelected
        self.isConfigured = isConfigured
    }
}

/// **What the Cleanup tab is showing.**
///
/// ## Two facts, kept apart
///
/// ``selection`` is what `cleanup-config.json` says — the rung the **next** launch will use.
/// ``summary`` is the provider that resolved at this launch — what is cleaning text **now**. They
/// disagree whenever the user has just changed the rung, and also when a hand-edited block
/// degraded, and collapsing them into one field is exactly how a tab ends up reporting a provider
/// Vocca is not using (F3).
///
/// ## The selection is always what is on disk
///
/// It moves on ``CleanupTabAction/saveSucceeded(_:)`` and on nothing else — not on the click, not
/// optimistically, not on a failure. That is what makes "declining leaves the previous choice
/// intact" true by construction rather than by a rollback somebody has to remember to write; on
/// this tab the previous choice is a privacy setting, and the rollback nobody wrote is how a user
/// ends up believing they are on the local rung when the file says otherwise.
public struct CleanupTabState: Sendable, Equatable {
    /// The rung the file names.
    public var selection: CleanupProviderKind
    /// The blocks as the user is editing them, both of them, always.
    public var draft: CleanupConfigDraft
    /// What resolved at launch, or `nil` when nothing has been asked yet.
    public var summary: CleanupSummary?
    /// Whether the config has been read. `false` with the default selection is "we have not
    /// looked yet"; `true` is the file's own answer, and the two must not render the same (the
    /// ``SettingsCopy/dictionaryEmpty`` guard).
    public var isLoaded: Bool
    /// The last refusal or failure, in words. `nil` once something succeeds.
    public var message: String?
    /// The rows, derived from everything above, in the spec's order.
    public var rows: [CleanupTabRow]

    /// The state the window opens in: the zero-network default, and no claim about anything.
    public static let initial = CleanupTabState()

    public init() {
        self.selection = .rules
        self.draft = .empty
        self.summary = nil
        self.isLoaded = false
        self.message = nil
        self.rows = CleanupTabReducer.rows(selection: .rules, draft: .empty)
    }
}

/// Everything that can happen to the Cleanup tab. A closed set, folded exhaustively, with no
/// time-based transition in it — the ``AppsTabAction`` discipline: nothing here changes while a
/// user is reading it.
public enum CleanupTabAction: Sendable, Equatable {
    /// The config file was read; this is what it says.
    case configLoaded(CleanupConfigDraft)
    /// The resolver was asked what is actually running.
    case summaryLoaded(CleanupSummary?)
    /// The user typed in a rung's endpoint field.
    case endpointEdited(CleanupProviderKind, String)
    /// The user typed in a rung's model field.
    case modelEdited(CleanupProviderKind, String)
    /// The write landed. **The only action that moves the selection.**
    case saveSucceeded(CleanupProviderKind)
    /// The write did not land, in the store's own words.
    case saveFailed(String)
    /// A rung could not be chosen yet, with the sentence saying why.
    case selectionRefused(String)
}

/// **What picking a rung must actually do.**
///
/// A returned plan rather than a side effect inside the fold — the ``SpeechTabRemovalPlan`` shape:
/// the reducer is pure, so the decision is a value a test can assert rather than a sequence of
/// calls a page happens to make in the right order today.
public enum CleanupTabPlan: Sendable, Equatable {
    /// Write this to `cleanup-config.json`. The selection moves when the write reports back.
    case write(CleanupConfigDraft)
    /// The rung is missing something the file needs. Nothing is written and nothing moves.
    case refuse(String)
}

/// The Cleanup tab's decisions — pure, clock-free, and holding no store of its own.
public enum CleanupTabReducer {

    public static func reduce(_ state: CleanupTabState, _ action: CleanupTabAction)
        -> CleanupTabState
    {
        var next = state
        switch action {
        case .configLoaded(let draft):
            next.draft = draft
            next.selection = draft.provider
            next.isLoaded = true

        case .summaryLoaded(let summary):
            next.summary = summary

        case .endpointEdited(let kind, let value):
            switch kind {
            case .rules: break  // The local rung has no endpoint; inventing one is not an edit.
            case .ollama: next.draft.ollamaEndpoint = value
            case .byok: next.draft.byokEndpoint = value
            }

        case .modelEdited(let kind, let value):
            switch kind {
            case .rules: break
            case .ollama: next.draft.ollamaModel = value
            case .byok: next.draft.byokModel = value
            }

        case .saveSucceeded(let kind):
            // The one place the selection moves: the file now says this, so the next launch will
            // use it, and the radio may finally point at it.
            next.selection = kind
            next.draft.provider = kind
            next.message = nil

        case .saveFailed(let message):
            next.message = CleanupTabCopy.saveFailed(message)

        case .selectionRefused(let message):
            next.message = message
        }
        next.rows = rows(selection: next.selection, draft: next.draft)
        return next
    }

    /// **What picking `kind` must do**, given what the user has typed.
    ///
    /// Lives here rather than in the page so a caller that skipped the radio button is refused
    /// too: the rule is about choosing a rung, not about one control.
    public static func plan(_ state: CleanupTabState, picking kind: CleanupProviderKind)
        -> CleanupTabPlan
    {
        guard state.draft.isConfigured(kind) else {
            return .refuse(CleanupTabCopy.missingFields(kind))
        }
        var draft = state.draft
        draft.provider = kind
        return .write(draft)
    }

    /// The rows a fact set produces — one per rung, in `CleanupProviderKind.allCases` order, which
    /// is the spec's order (Basic, Local AI, Cloud). Fixed rather than sorted: a settings list
    /// whose rows moved between openings looks like the data changed.
    static func rows(selection: CleanupProviderKind, draft: CleanupConfigDraft) -> [CleanupTabRow] {
        CleanupProviderKind.allCases.map { kind in
            CleanupTabRow(
                kind: kind,
                isSelected: selection == kind,
                isConfigured: draft.isConfigured(kind))
        }
    }
}
