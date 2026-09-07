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

/// **The Usage tab** (`PRODUCT_SPEC.md` §7, the **Usage** entry): what Vocca observed, day by
/// day, and the one control that deletes it.
///
/// Thin glue over ``UsageTabReducer`` — the ``AppsSettingsPage`` split. Nothing is decided here:
/// the rows and their order are the reducer's, every word is ``UsageTabCopy``'s, and the two
/// numbers that could be a lie — a latency bound and a rung tally — are rendered by copy that has
/// no code path to a spot value or a percentage.
///
/// **Read once, in `.task`, and never again while the window is open.** The ``AppsTabState`` rule
/// ("nothing here should change while a user is reading it"), which on this page also stops the
/// streak from changing under a reader at midnight — a scheduling detail reported as a fact about
/// them. There is no observation, no timer and no live tick anywhere in this file.
///
/// The Clear control takes the **Speech** removal treatment rather than the Apps reset one: a
/// confirmation with a destructive and a cancel button, because this deletes a file and cannot be
/// undone, where the Apps button resets something that was derived.
///
/// Executed by nothing in CI (the window-server rule). Every decision it renders is tested in
/// `UsageTabReducerTests`, every word in `UsageTabCopyTests`, and what it is plugged into — the
/// Clear that reaches the ledger, the confirmation treatment — in `UsageTabWiringTests`.
struct UsageSettingsPage: View {

    let bindings: SettingsBindings

    @State private var state = UsageTabState.initial
    /// Whether the Clear confirmation is up. `false` at every other moment, including after a
    /// cancel — which folds no action, so cancelling clears nothing by construction.
    @State private var isConfirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ledger
            Divider()
            footer
        }
        .task {
            state = UsageTabReducer.reduce(
                state, .snapshotLoaded(await bindings.loadUsageSnapshot()))
        }
        .confirmationDialog(
            UsageTabCopy.clearConfirmationTitle,
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button(UsageTabCopy.clearConfirmButton, role: .destructive) { clear() }
            Button(UsageTabCopy.clearCancelButton, role: .cancel) { isConfirmingClear = false }
        }
    }

    // MARK: - The three states the page can be in

    /// Unread, read-and-empty, and read-with-days — three renderings that never look alike.
    ///
    /// The first two are the distinction ``UsageTabCopy/loading`` and ``UsageTabCopy/empty`` exist
    /// to draw: a store that failed to load must not tell a daily user they have never dictated.
    @ViewBuilder
    private var ledger: some View {
        if !state.isLoaded {
            centered(UsageTabCopy.loading)
        } else if state.rows.isEmpty {
            centered(UsageTabCopy.empty)
        } else {
            summary
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    columnHeadings
                    ForEach(state.rows) { row in
                        dayRow(row)
                    }
                }
                .padding(12)
            }
        }
    }

    /// The window in one line and a half: the streak as a fact about days, then what the ledger
    /// holds. The two totals sit side by side with no separator glyph invented for them and, more
    /// to the point, are never added — real dictations are one number and the setup demo's
    /// sessions are another, under their own heading below.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(UsageTabCopy.streak(days: state.streak))
            HStack(spacing: 14) {
                Text(UsageTabCopy.daysRecorded(state.daysRecorded))
                Text(UsageTabCopy.dictations(state.dictationCount))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var columnHeadings: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(UsageTabCopy.dayColumn)
            Spacer()
            Text(UsageTabCopy.dictationsColumn)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// One day: the date and its dictations, then the three breakdowns under their own headings.
    ///
    /// A stack rather than a five-column `Table` because the detail area is ~450 pt wide
    /// (`PRODUCT_SPEC.md:250`) and a day's outcomes are several lines of prose: in a table they
    /// would be truncated, and a truncated tally on a disclosure page is a number the user cannot
    /// check. The column headings are the spec's own.
    private func dayRow(_ row: UsageDayRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(UsageTabCopy.dayLabel(row.day))
                Spacer()
                Text(row.dictations, format: .number)
            }
            breakdown(UsageTabCopy.outcomeColumn, lines: Self.outcomeLines(row))
            breakdown(UsageTabCopy.rungColumn, lines: Self.rungLines(row))
            breakdown(
                UsageTabCopy.latencyColumn,
                lines: [
                    UsageTabCopy.latencySummary(
                        median: row.medianLatency, ninetyFifth: row.ninetyFifthLatency)
                ])
        }
    }

    /// One labelled breakdown, its tallies one per line — the shape the spec's own mock has, and
    /// the shape that keeps a count from ever sitting next to a slash.
    @ViewBuilder
    private func breakdown(_ heading: String, lines: [String]) -> some View {
        if !lines.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(heading)
                    .foregroundStyle(.secondary)
                    .frame(width: 128, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(lines, id: \.self) { line in
                        Text(line)
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
        }
    }

    /// The setup demo's own heading and its own noun, then what the page says about itself, then
    /// the control.
    ///
    /// The onboarding block renders only once the ledger has been read: "No sessions" over an
    /// unread file is a claim about a history nobody has looked at yet.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.isLoaded {
                HStack(alignment: .firstTextBaseline) {
                    Text(UsageTabCopy.onboardingHeading)
                    Spacer()
                    Text(UsageTabCopy.onboardingSessions(state.onboardingSessionCount))
                }
                Text(UsageTabCopy.onboardingExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(UsageTabCopy.notAVerdict)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(UsageTabCopy.localOnly)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(UsageTabCopy.retention)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button(UsageTabCopy.clearButton) { isConfirmingClear = true }
                    .disabled(state.rows.isEmpty)
                Text(UsageTabCopy.clearExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
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

    /// The ledger first, the page second. The store is asked to forget before the rows disappear,
    /// so what the user watches empty is the thing that actually emptied — the reverse of the Apps
    /// tab's optimistic write, because this one cannot be retried and there is nothing to undo.
    private func clear() {
        Task {
            await bindings.clearUsage()
            state = UsageTabReducer.reduce(state, .cleared)
        }
    }

    // MARK: - Rendering the tallies

    /// The day's outcomes, one line per class that actually happened. Zeroes are left out rather
    /// than printed: six rows of `0` read as six measurements.
    private static func outcomeLines(_ row: UsageDayRow) -> [String] {
        UsageOutcome.allCases.compactMap { outcome in
            let count = outcome.count(in: row.realWork)
            return count > 0 ? UsageTabCopy.outcomeTally(outcome, count: count) : nil
        }
    }

    /// How the text arrived, per rung — **counts**, never a share. A day whose real work delivered
    /// nothing reads as an em dash, because four zeroes would read as four measurements.
    private static func rungLines(_ row: UsageDayRow) -> [String] {
        let lines = InjectionRung.allCases.compactMap { rung -> String? in
            let count = row.deliveries(via: rung)
            return count > 0 ? UsageTabCopy.rungTally(rung, count: count) : nil
        }
        return lines.isEmpty ? [UsageTabCopy.noDeliveries] : lines
    }
}
