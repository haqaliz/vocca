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
            .font(VoccaTheme.Text.panel)
            .foregroundStyle(isRecording ? Color.white : Color.primary)
            .lineLimit(1)
            .padding(.horizontal, VoccaTheme.Panel.horizontalPadding)
            .frame(height: VoccaTheme.Panel.height)
            .background(background, in: Capsule())
            // A hairline over the fill. The pill floats over arbitrary wallpaper, so it cannot
            // borrow a window's edge — without this it dissolves into a light desktop exactly
            // where it is most needed.
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
            .opacity(panelOpacity)
    }

    /// The pill's fill: the recording accent, or a neutral vibrancy for every other state.
    private var background: AnyShapeStyle {
        isRecording
            ? AnyShapeStyle(VoccaTheme.State.recording)
            : AnyShapeStyle(.regularMaterial)
    }

    /// Idle sits at 68% and no lower here.
    ///
    /// The design drops it to 28% after ten seconds of no interaction, but **never to zero** —
    /// "the panel does not disappear, it is always findable". The timed step is the reducer's to
    /// drive and is not wired yet; what this must not do in the meantime is what the old value
    /// did, which was render idle at 30% permanently and call it a resting state.
    private var panelOpacity: Double {
        isIdle ? VoccaTheme.Panel.idleOpacity : 1
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
                // A microphone, not an anonymous dot: idle is the state a user is most likely to
                // see without context, and it should say which app is sitting there.
                Image(systemName: "mic")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            case .opening(let targetAppName):
                HStack(spacing: 4) {
                    Text(WidgetCopy.openingLabel(targetAppName: targetAppName))
                    egressMarker
                }
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
                            // Monospaced digits: the timer counts every second, and proportional
                            // figures make the whole pill twitch as the width changes under them.
                            Text(WidgetCopy.elapsedText(elapsed))
                                .font(VoccaTheme.Text.panelTimer)
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
                    egressMarker
                }
            case .delivered(let targetAppName):
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(VoccaTheme.State.delivered)
                    Text(WidgetCopy.deliveredLabel(targetAppName: targetAppName))
                }
            }
        }
    }

    /// The egress marker (`PRODUCT_SPEC.md:250-264`): the ☁︎ glyph while an active cleanup
    /// provider sends text off the machine, with the hover copy stating where it goes. Rendered
    /// in the opening/recording/transcribing branches only — DELIVERED is deliberately excluded
    /// (the text has left by then, `egress-badge` B1). Display-only: the pill never becomes key.
    ///
    /// ## Why it is amber, and why a rule separates it
    ///
    /// The design's rationale, kept because it is right: amber is distinct from every state colour
    /// — the accent is opening, red is recording, green is delivered — so the badge can never be
    /// misread as a phase. It is not a state at all; it is a different *category* of fact sharing
    /// one pill, and the hairline divider says so before the colour does.
    ///
    /// Its presence is the whole message. When cleanup runs on-device the badge is absent, so
    /// **showing at all means text is leaving this machine** — which is why nothing here has a
    /// subtler variant for "a little bit of network".
    @ViewBuilder
    private var egressMarker: some View {
        if case .active(let endpoint) = store.state.egress {
            HStack(spacing: VoccaTheme.Panel.itemSpacing - 3) {
                Rectangle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 0.5, height: 12)
                Text(BadgeCopy.egressGlyph)
                    .foregroundStyle(VoccaTheme.egress)
                    .help(BadgeCopy.egressHoverText(endpoint: endpoint))
            }
        }
    }

    private var isRecording: Bool { store.state.state == .recording }
    private var isIdle: Bool { store.state.state == .idle }
}
