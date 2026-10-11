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

import SwiftUI
import VoccaCore

/// **The Conversation tab** (`turn-history` `conversation-surface` D2): the recent CONVERSING
/// turns — what the user said and what Vocca replied — and the one confirmed control that
/// deletes them from disk.
///
/// Thin glue over ``ConversationTabReducer`` — the ``UsageSettingsPage`` split. Nothing is
/// decided here: the rows and their order are the reducer's, every word is
/// ``ConversationTabCopy``'s, and the interrupted marker renders exactly the flag the driver's
/// barge-in mark wrote.
///
/// **Read once, in `.task`, and never again while the window is open.** The ``UsageSettingsPage``
/// rule ("nothing here should change while a user is reading it"), which here is also the whole
/// surface contract: there is no observation path, no timer and no live tick anywhere in this
/// file. A turn recorded while the window is open is seen at the next open.
///
/// The Forget control takes the **Usage** removal treatment: a confirmation with a destructive
/// and a cancel button, because this deletes a file and cannot be undone — and the store is
/// asked **before** the page empties ("store first, page second", the
/// ``UsageSettingsPage/clear()`` order), so what the user watches disappear is the thing that
/// actually disappeared.
///
/// Executed by nothing in CI (the window-server rule). Every decision it renders is tested in
/// `ConversationTabReducerTests`, every word in `ConversationTabCopyTests`, and what it is
/// plugged into — the Forget that reaches the store — in `ConversationWiringTests`.
struct ConversationSettingsPage: View {

    let bindings: SettingsBindings

    @State private var state = ConversationTabState.initial
    /// Whether the Forget confirmation is up. `false` at every other moment, including after a
    /// cancel — which folds no action, so cancelling clears nothing by construction.
    @State private var isConfirmingForget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            turns
            Divider()
            footer
        }
        .task {
            state = ConversationTabReducer.reduce(
                state, .snapshotLoaded(await bindings.loadConversationSnapshot()))
        }
        .confirmationDialog(
            ConversationTabCopy.forgetConfirmationTitle,
            isPresented: $isConfirmingForget,
            titleVisibility: .visible
        ) {
            Button(ConversationTabCopy.forgetConfirmButton, role: .destructive) { forget() }
            Button(ConversationTabCopy.forgetCancelButton, role: .cancel) {
                isConfirmingForget = false
            }
        }
    }

    // MARK: - The two renderings

    /// Unread, read-and-empty, and read-with-turns — three renderings that never look alike
    /// (the ``UsageTabCopy/loading``/``empty`` distinction).
    @ViewBuilder
    private var turns: some View {
        if !state.isLoaded {
            centered(ConversationTabCopy.loading)
        } else if state.rows.isEmpty {
            centered(ConversationTabCopy.empty)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(state.rows) { row in
                        turnRow(row)
                    }
                }
                .padding(12)
            }
        }
    }

    /// One turn: what the user said, then what Vocca replied, then the interrupted marker when
    /// a barge-in cut the reply — the three fields of the store's record, no more (`prd.md` R1:
    /// no timestamps, no session, nothing invented between them).
    private func turnRow(_ row: ConversationTurnRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.utterance)
            Text(row.reply)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if row.interrupted {
                Text(ConversationTabCopy.interruptedMarker)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The window and the control: the bound disclosed, the privacy line, then the Forget
    /// button with its explanation.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.isLoaded {
                Text(ConversationTabCopy.boundDisclosure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(ConversationTabCopy.localOnly)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button(ConversationTabCopy.forgetButton) { isConfirmingForget = true }
                        .disabled(state.rows.isEmpty)
                    Text(ConversationTabCopy.forgetExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private func centered(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - The gesture

    /// The store first, the page second — the ``UsageSettingsPage/clear()`` order, pinned: the
    /// store is asked to forget **before** the rows disappear, so what the user watches empty
    /// is the thing that actually emptied. The reverse order would empty the page on a deletion
    /// the disk refused, and the user would leave believing the file was gone while it sat
    /// beside them.
    private func forget() {
        Task {
            await bindings.clearConversation()
            state = ConversationTabReducer.reduce(state, .cleared)
        }
    }
}