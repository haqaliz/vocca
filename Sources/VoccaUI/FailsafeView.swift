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

/// The FAILSAFE pill's content, hosted by ``FailsafePanel`` (``SpeechSettingsPage``'s shape: the
/// SwiftUI view is thin — everything with a branch in it is above, in ``FailsafeCopy`` and the
/// reducer, both tested headlessly; this file renders their answers).
///
/// Rendered from ``FailsafeState`` and nothing else: the transcript as real, **selectable,
/// scrollable text** (`PRODUCT_SPEC.md:105` — not an image, not truncated, long transcripts
/// scroll), the cause-specific reason line (`FailsafeCopy/reasonText(for:targetAppName:)`), the
/// ⌘C/⏎/✕ affordances legend, and the three affordances themselves — each routing to the closure
/// the panel injects, so Copy/Retry/✕ go through exactly the same handlers as the key
/// equivalents do.
///
/// `hidden` renders nothing: a panel showing nothing is a panel not shown.
public struct FailsafeView: View {

    /// The reducer's state — the single thing this view renders.
    public let state: FailsafeState
    /// ⌘C: copy the held transcript.
    public let onCopy: () -> Void
    /// ⏎: re-run the ladder against current focus.
    public let onRetry: () -> Void
    /// ✕: dismiss and release the held transcript.
    public let onDismiss: () -> Void

    public init(
        state: FailsafeState,
        onCopy: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.state = state
        self.onCopy = onCopy
        self.onRetry = onRetry
        self.onDismiss = onDismiss
    }

    public var body: some View {
        switch state {
        case .hidden:
            EmptyView()
        case .presenting(let transcript), .retrying(let transcript), .copied(let transcript):
            VStack(alignment: .leading, spacing: 10) {
                ScrollView {
                    Text(transcript.text)
                        .textSelection(.enabled)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 48, maxHeight: 160)

                Text(
                    FailsafeCopy.reasonText(
                        for: transcript.reason, targetAppName: transcript.targetAppName))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Under the reason, above the keys: the reassurance is the answer to "have I
                // lost it?", which is the question the reason line provokes and never settles.
                Text(FailsafeCopy.custodyLine(for: state))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text(FailsafeCopy.affordancesLine(for: state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                HStack {
                    Button("Copy", action: onCopy)
                    Button("Retry", action: onRetry)
                    Spacer()
                    Button("✕", action: onDismiss)
                }
            }
            .padding(16)
            .frame(width: 420)
        case .reasonOnly(let reason):
            VStack(alignment: .leading, spacing: 10) {
                Text(FailsafeCopy.reasonText(for: reason, targetAppName: nil))
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Text(FailsafeCopy.affordancesLine(for: state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                HStack {
                    Spacer()
                    Button("✕", action: onDismiss)
                }
            }
            .padding(16)
            .frame(width: 420)
        }
    }
}
