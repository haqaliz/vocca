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

import AppKit
import SwiftUI
import VoccaCore

/// The live widget's pill: the five states rendered from ``WidgetStateStore``'s reducer state.
///
/// This file is **glue, and its rendering is executed by nothing in CI** (the window-server
/// precedent, exactly like ``FailsafeView``): every string is above it in ``WidgetCopy``
/// (`WidgetCopyTests`), the time-based surfaces were already decided by the reducer's injected-clock
/// fold (`WidgetStateReducerTests` — the view never arms a timer and never owns a clock), and the
/// waveform mapping is ``WaveformMapping``'s. What is left here is a `switch` over the state, the
/// Reduce Motion read, and the pill's chrome.
///
/// ## The states, per `PRODUCT_SPEC.md:24-68`
///
/// - **IDLE**: a thin dormant pill at ~30% opacity (`:27`). The spec's 10 s fade (`:28`) is not in
///   the shipped store API — the reducer state carries no idle timestamp — so it is out of scope.
/// - **OPENING**: expanded with the target label, **no waveform** (`:33-38` — the projection's own
///   invariant: no audio exists yet, and a waveform over a dead mic is the spec's named lie, `:88`).
/// - **RECORDING**: the live waveform, the elapsed timer (the reducer's, after 3 s), `esc to cancel`
///   (the reducer's, after 2 s, `:129`), the ceiling warning (the reducer's, derived from the
///   configured ceiling, `:87-90`) — all on the accent background.
/// - **TRANSCRIBING**: the frozen waveform (`:93-95`) and the indeterminate progress — the level
///   refresh is gated off by ``LevelWaveformView``'s `isLive`, which is why the RECORDING and
///   TRANSCRIBING states render in **one branch**: the waveform's `@State` must survive the
///   transition, or the freeze would be a reset to silence.
/// - **DELIVERED**: `✓ → target` (`:50`). The ~600 ms collapse is the store's injected-clock fold
///   (`WidgetTimer/deliveredCollapse`), never a view timer.
///
/// The FAILSAFE is deliberately not here: ``FailsafePanel``/``FailsafeView`` are the existing
/// surface, a separate state machine this view has no handle on.
///
/// The ``WidgetNotice`` is the one addition beyond the five states, and it is the projection's own
/// vocabulary (`WidgetProjection.swift`): a terminal notice rendered over IDLE — the machine said
/// the microphone did not open, and the pill says so instead of letting the press appear to do
/// nothing at all.
@MainActor
public struct WidgetView: View {

    /// The reducer's state — the single thing this view renders, published by the store.
    @ObservedObject public var store: WidgetStateStore
    /// The input level the RECORDING waveform draws — the seam ``LiveLevelSource``, the real
    /// conformance injected by the composition root.
    public let level: any LiveLevelSource

    public init(store: WidgetStateStore, level: any LiveLevelSource) {
        self.store = store
        self.level = level
    }

    public var body: some View {
        content
            .font(.caption)
            .foregroundStyle(isRecording ? Color.white : Color.primary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                isRecording ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.black.opacity(0.25)),
                in: Capsule())
            .opacity(isIdle ? 0.3 : 1)
    }

    /// The state-dependent content. The notice wins over everything — a terminal notice is the
    /// machine's answer, and the state under it is IDLE by construction.
    @ViewBuilder
    private var content: some View {
        if let notice = store.state.notice {
            Text(WidgetCopy.noticeText(notice))
        } else {
            switch store.state.state {
            case .idle:
                Circle()
                    .fill(.primary)
                    .frame(width: 6, height: 6)
            case .opening(let targetAppName):
                Text(WidgetCopy.openingLabel(targetAppName: targetAppName))
            case .recording, .transcribing:
                // One branch on purpose: the waveform's @State must survive RECORDING →
                // TRANSCRIBING (the freeze is a pause, not a reset — see LevelWaveformView).
                HStack(spacing: 8) {
                    LevelWaveformView(
                        level: level,
                        reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                        isLive: isRecording)
                    if isRecording {
                        if let elapsed = store.state.elapsed {
                            Text(WidgetCopy.elapsedText(elapsed))
                        }
                        if store.state.showsEscapeHint {
                            Text(WidgetCopy.escapeHint)
                        }
                        if store.state.showsCeilingWarning {
                            Text(WidgetCopy.ceilingWarning)
                        }
                    } else {
                        Text(WidgetCopy.transcribingProgress)
                    }
                }
            case .delivered(let targetAppName):
                Text(WidgetCopy.deliveredLabel(targetAppName: targetAppName))
            }
        }
    }

    private var isRecording: Bool { store.state.state == .recording }
    private var isIdle: Bool { store.state.state == .idle }
}
