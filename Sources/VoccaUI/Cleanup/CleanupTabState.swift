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
/// ``selection`` is what `cleanup-config.json` says for dictation — the rung the **next** launch
/// will use. ``summary`` is the provider that resolved at this launch — what is cleaning text
/// **now**. They disagree whenever the user has just changed the rung, and also when a
/// hand-edited block degraded, and collapsing them into one field is exactly how a tab ends up
/// reporting a provider Vocca is not using (F3).
///
/// ## Two selections, one file (C11)
///
/// ``converseSelection`` is what the file says for conversations — the same two-facts split,
/// applied to the converse half. Both selections live in the one ``CleanupConfigDraft`` the tab
/// edits: there is exactly one `cleanup-config.json` underneath, and the resolver reads the
/// provider the file names per mode (`CleanupResolver/resolve(mode:)`).
///
/// ## The selection is always what is on disk
///
/// It moves on ``CleanupTabAction/saveSucceeded(_:)`` (dictation) and
/// ``CleanupTabAction/converseSaveSucceeded(_:)`` (converse) and on nothing else — not on the
/// click, not optimistically, not on a failure. That is what makes "declining leaves the
/// previous choice intact" true by construction rather than by a rollback somebody has to
/// remember to write; on this tab the previous choice is a privacy setting, and the rollback
/// nobody wrote is how a user ends up believing they are on the local rung when the file says
/// otherwise.
public struct CleanupTabState: Sendable, Equatable {
    /// The rung the file names for dictation.
    public var selection: CleanupProviderKind
    /// The rung the file names for conversations.
    public var converseSelection: CleanupProviderKind
    /// The blocks as the user is editing them, both of them, always.
    public var draft: CleanupConfigDraft
    /// What resolved at launch, or `nil` when nothing has been asked yet.
    public var summary: CleanupSummary?
    /// What resolved for conversations, or `nil` when nothing has been asked yet.
    public var converseSummary: CleanupSummary?
    /// Whether the config has been read. `false` with the default selection is "we have not
    /// looked yet"; `true` is the file's own answer, and the two must not render the same (the
    /// ``SettingsCopy/dictionaryEmpty`` guard).
    public var isLoaded: Bool
    /// The last refusal or failure, in words. `nil` once something succeeds.
    public var message: String?
    /// The rows, derived from everything above, in the spec's order.
    public var rows: [CleanupTabRow]
    /// The converse picker's rows, derived the same way over the converse selection.
    public var converseRows: [CleanupTabRow]
    /// The rung and mode whose confirmation dialog is open, or `nil`. Only the cloud rung ever
    /// appears here — and while it does, nothing else has moved.
    public var pendingConfirmation: CleanupPendingConfirmation?
    /// Whether the user has read and accepted the cloud-cleanup dialog, as the settings store
    /// remembers it across launches. `false` until ``CleanupTabAction/acknowledgementLoaded(_:)``
    /// says otherwise, which is the safe direction: the worst case is a dialog shown twice.
    public var hasAcknowledgedCloud: Bool

    /// The state the window opens in: the zero-network default, and no claim about anything.
    public static let initial = CleanupTabState()

    public init() {
        self.selection = .rules
        self.converseSelection = .rules
        self.draft = .empty
        self.summary = nil
        self.converseSummary = nil
        self.isLoaded = false
        self.message = nil
        self.pendingConfirmation = nil
        self.hasAcknowledgedCloud = false
        self.rows = CleanupTabReducer.rows(selection: .rules, draft: .empty)
        self.converseRows = CleanupTabReducer.rows(selection: .rules, draft: .empty)
    }
}

/// **What the confirmation dialog is for** — the cloud rung and the picker that asked for it.
///
/// The accept re-plans the same picker (`plan(_:picking:mode:)`), which is what makes the dialog
/// one surface for two sections: the mode names the half of the draft the write moves.
public struct CleanupPendingConfirmation: Sendable, Equatable {
    /// The cloud rung being confirmed.
    public let kind: CleanupProviderKind
    /// Which picker asked — dictate or converse.
    public let mode: SessionMode

    public init(kind: CleanupProviderKind, mode: SessionMode) {
        self.kind = kind
        self.mode = mode
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
    /// The write landed. **The only action that moves the dictation selection.**
    case saveSucceeded(CleanupProviderKind)
    /// The converse write landed. **The only action that moves the converse selection.**
    case converseSaveSucceeded(CleanupProviderKind)
    /// The write did not land, in the store's own words.
    case saveFailed(String)
    /// A rung could not be chosen yet, with the sentence saying why.
    case selectionRefused(String)
    /// The settings store was asked whether the cloud dialog has already been accepted.
    case acknowledgementLoaded(Bool)
    /// What resolved for conversations, or `nil` when nothing has been asked yet.
    case converseSummaryLoaded(CleanupSummary?)
    /// The cloud confirmation was put in front of the user, for one picker. Nothing else moves
    /// while it is up.
    case confirmationRequested(CleanupProviderKind, for: SessionMode)
    /// The user read it and agreed. **Acknowledges; does not write** — the write is the plan's,
    /// and the selection still waits for it to land.
    case confirmationAccepted
    /// The user dismissed it. Nothing is acknowledged, nothing is written, and the previous
    /// choice is untouched — which is true here by construction rather than by a rollback.
    case confirmationDeclined
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
    /// The rung sends text off the machine and the user has not yet agreed to that. Show the
    /// dialog `PRODUCT_SPEC.md:273` requires — *"not a checkbox buried in a paragraph"* — and
    /// write nothing until they accept.
    case confirm(CleanupProviderKind)
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
            next.converseSelection = draft.converseProvider
            next.isLoaded = true

        case .summaryLoaded(let summary):
            next.summary = summary

        case .converseSummaryLoaded(let summary):
            next.converseSummary = summary

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
            // The one place the dictation selection moves: the file now says this, so the next
            // launch will use it, and the radio may finally point at it.
            next.selection = kind
            next.draft.provider = kind
            next.message = nil

        case .converseSaveSucceeded(let kind):
            // The one place the converse selection moves — the dictation doctrine, applied to
            // the converse half (`CleanupTabState.swift:47-53`).
            next.converseSelection = kind
            next.draft.converseProvider = kind
            next.message = nil

        case .saveFailed(let message):
            next.message = CleanupTabCopy.saveFailed(message)

        case .selectionRefused(let message):
            next.message = message

        case .acknowledgementLoaded(let acknowledged):
            next.hasAcknowledgedCloud = acknowledged

        case .confirmationRequested(let kind, let mode):
            // Only the dialog moves. The selections, the draft and the file are all exactly what
            // they were while the user is reading.
            next.pendingConfirmation = CleanupPendingConfirmation(kind: kind, mode: mode)

        case .confirmationAccepted:
            next.hasAcknowledgedCloud = true
            next.pendingConfirmation = nil

        case .confirmationDeclined:
            // Nothing to undo: the selection never moved, so there is no state to restore and no
            // "previous choice" to remember wrongly. The acknowledgement is deliberately *not*
            // set — an agreement earned by dismissing a dialog is not an agreement, and the next
            // attempt asks again.
            next.pendingConfirmation = nil
        }
        next.rows = rows(selection: next.selection, draft: next.draft)
        next.converseRows = rows(selection: next.converseSelection, draft: next.draft)
        return next
    }

    /// **What picking `kind` for `mode` must do**, given what the user has typed.
    ///
    /// Lives here rather than in the page so a caller that skipped the radio button is refused
    /// too: the rule is about choosing a rung, not about one control. The defaulted `mode`
    /// keeps every existing call site a dictate pick — the mode names the half of the draft the
    /// write moves (`provider` or `converseProvider`).
    public static func plan(
        _ state: CleanupTabState,
        picking kind: CleanupProviderKind,
        mode: SessionMode = .dictation
    ) -> CleanupTabPlan {
        guard state.draft.isConfigured(kind) else {
            return .refuse(CleanupTabCopy.missingFields(kind))
        }
        // Refusal first, deliberately: confirming egress to an endpoint the user has not typed
        // would ask them to approve sending text nowhere, and the write would fail anyway.
        if kind.sendsTextOffTheMac && !state.hasAcknowledgedCloud {
            return .confirm(kind)
        }
        var draft = state.draft
        switch mode {
        case .dictation: draft.provider = kind
        case .conversing: draft.converseProvider = kind
        }
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
