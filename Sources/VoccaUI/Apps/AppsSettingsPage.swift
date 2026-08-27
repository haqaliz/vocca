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

/// **The Apps tab** (`PRODUCT_SPEC.md:275`): what Vocca learned about typing into each
/// application, what the user pinned over it, and the one button that clears the first without
/// touching the second.
///
/// Thin glue over ``AppsTabReducer`` — the ``EnginePickerView``/``DictionarySettingsPage`` split.
/// Every gesture folds an action **and** writes the folded truth through the same binding, so
/// what the table shows and what the file holds cannot drift; the write's outcome folds back as
/// `saveSucceeded`/`saveFailed`, which is the only reason `saveError` exists.
///
/// Executed by nothing in CI (the window-server rule). Every decision it renders is tested in
/// `AppsTabReducerTests` and every word in `AppsTabCopyTests`.
struct AppsSettingsPage: View {

    let bindings: SettingsBindings

    @State private var state = AppsTabState.initial

    var body: some View {
        VStack(spacing: 0) {
            if state.isLoaded && state.rows.isEmpty {
                Spacer()
                Text(AppsTabCopy.empty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Spacer()
            } else {
                Table(state.rows) {
                    TableColumn(AppsTabCopy.appColumn, value: \.displayName)
                    TableColumn(AppsTabCopy.healthColumn) { row in
                        Text(AppsTabCopy.healthLabel(row.health))
                    }
                    TableColumn(AppsTabCopy.stateColumn) { row in
                        methodPicker(for: row)
                    }
                }
            }

            if let saveError = state.saveError {
                Text(AppsTabCopy.saveError(saveError))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button(AppsTabCopy.resetButton) { apply(.resetLearned) }
                    .disabled(state.rows.isEmpty)
                Text(AppsTabCopy.resetExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(8)
        }
        .task {
            state = AppsTabReducer.reduce(state, .snapshotLoaded(await bindings.loadStrategies()))
        }
    }

    /// One row's control: the three methods, plus the learned state as the "no pin" choice.
    ///
    /// An overridden row whose stored order is none of the three shows no selection rather than
    /// being silently rewritten to the nearest one — a hand-edited `strategies.json` is the
    /// user's file, and the picker is not entitled to reinterpret it.
    @ViewBuilder
    private func methodPicker(for row: AppsRow) -> some View {
        Picker(
            "",
            selection: Binding(
                get: { row.isOverridden ? row.method : nil },
                set: { method in
                    if let method {
                        apply(.overrideSet(bundleID: row.bundleID, method: method))
                    } else {
                        apply(.overrideCleared(bundleID: row.bundleID))
                    }
                })
        ) {
            Text(AppsTabCopy.learnedBadge).tag(AppsTabMethod?.none)
            ForEach(AppsTabMethod.allCases, id: \.self) { method in
                Text("\(AppsTabCopy.overriddenBadge): \(AppsTabCopy.methodLabel(method))")
                    .tag(AppsTabMethod?.some(method))
            }
        }
        .labelsHidden()
    }

    /// Folds the action and writes the result through, in that order — the table updates at the
    /// speed of a value type and the file catches up. A failed write is surfaced, never
    /// swallowed: a pin that silently fails to save is one the user sets again next launch.
    private func apply(_ action: AppsTabAction) {
        state = AppsTabReducer.reduce(state, action)
        let snapshot = state.rows.compactMap { state.entries[$0.bundleID] }
        Task {
            do {
                try await bindings.saveStrategies(snapshot)
                state = AppsTabReducer.reduce(state, .saveSucceeded)
            } catch {
                state = AppsTabReducer.reduce(
                    state, .saveFailed(error.localizedDescription))
            }
        }
    }
}
