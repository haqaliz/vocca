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
import Combine
import SwiftUI
import VoccaCore

/// The live widget's window: a **non-activating panel that never takes focus** (`PRODUCT_SPEC.md:22`)
/// hosting ``WidgetView``.
///
/// This file is **glue, and its chrome is executed by nothing in CI** (the ``FailsafePanel``
/// precedent): the states, the copy and the timing are all above it and tested headlessly. What is
/// here is the window's shape and its self-driving show/hide.
///
/// ## The one way this panel differs from ``FailsafePanel``, and why
///
/// ``FailsafePanel`` overrides `canBecomeKey` to `true` — it must receive ⌘C / ⏎ / ✕ while the
/// target app stays active. **This panel does not, and must not.** The live widget's job is to stay
/// out of the user's way while they dictate *into another app's field*; a panel that can become key
/// is one keypress from stealing the field the user is typing into. The FAILSAFE's key handling is
/// its whole point; the live pill's key handling is its whole absence — there are no key
/// equivalents here, nothing to copy and nothing to retry.
///
/// ## How the window follows the store (the seam has no push)
///
/// The shipped ``WidgetStateStore`` publishes its reducer state (`@Published state`) and nothing
/// else — there is no "widget became idle" notification to subscribe to, and the composition root
/// does not (yet) hold this window to tell it. So the panel observes the store: any non-IDLE state
/// — or a terminal ``WidgetNotice`` — orders the window front without activating; a return to IDLE
/// orders it out. The observation is the ``AppBootstrap`` shape — a `@Sendable` sink that hops to
/// the main actor to reach the window, which is why the box below is `@unchecked Sendable`: the
/// sink writes the box and the main-actor task reads it, and both ends of that edge are confined to
/// what the closure chain already documents.
///
/// ## The shape, mirroring ``FailsafePanel``
///
/// `styleMask [.nonactivatingPanel, .titled]`, `level = .floating`, `isReleasedWhenClosed = false`,
/// `hidesOnDeactivate = false`, `collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary]` —
/// the same conventions the FAILSAFE window ships with, minus the keyness that would make the live
/// widget take focus. Showing is `orderFrontRegardless()` and nothing else — no `makeKey`, so the
/// panel orders in without activating Vocca and never claims the keyboard.
public final class WidgetPanel: NSPanel {

    /// The store the pill renders and the window follows.
    private let store: WidgetStateStore

    /// The sound seam the `apply` diff drives — defaulted so every existing construction site
    /// (`LiveWidget`, the binding tests) compiles unchanged (`dual-mode` D6).
    private let soundPlayer: any WidgetSoundPlaying

    /// The confirmation card's Confirm/Decline closures — supplied by the wiring, the
    /// ``MenuBarItem`` closure-seam precedent (`confirmation-card`). Defaulted to no-ops so every
    /// existing construction site compiles unchanged; `VoccaUI` never names a provider or the
    /// gate — the closures are the seam, and the store's generation check is the guard on the
    /// confirm side.
    private let onConfirmAction: @Sendable () -> Void
    private let onDeclineAction: @Sendable () -> Void

    /// The state the previous `apply` saw — the diff the sound selection reads. A converse entry
    /// plays the tick; a phase change or any dictation transition plays nothing.
    ///
    /// Initialised to `.idle`, the pre-session state, not to the store's current state: the
    /// window is created **lazily on the first non-IDLE fold** (`LiveWidget`), so by the time
    /// this initializer runs the store already holds the state that fold produced — the diff
    /// against the store's current state would be converse→converse and the entry tick would
    /// never play on the one apply that can. Diffing against the pre-session IDLE makes the
    /// initial `apply` the tick's play (the `widget-converse` D6 edge case, pinned by
    /// `WidgetPanelBindingTests`).
    private var lastState: WidgetState = .idle

    /// The store observation, cancelled with the window.
    private var observation: AnyCancellable?

    /// The box the `@Sendable` sink writes so the main-actor task can reach the window — the
    /// ``AppBootstrap`` `WeakBox` shape, kept here rather than reused because that one is private
    /// to the composition root.
    private let box = WidgetPanelBox()

    public init(
        store: WidgetStateStore,
        levelSource: any LiveLevelSource,
        soundPlayer: any WidgetSoundPlaying = SystemWidgetSoundPlayer(),
        onConfirmAction: @Sendable @escaping () -> Void = {},
        onDeclineAction: @Sendable @escaping () -> Void = {}
    ) {
        self.store = store
        self.soundPlayer = soundPlayer
        self.onConfirmAction = onConfirmAction
        self.onDeclineAction = onDeclineAction
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 30),
            styleMask: [.nonactivatingPanel, .titled],
            backing: .buffered,
            defer: false)
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: WidgetView(
            store: store, level: levelSource,
            onConfirmAction: onConfirmAction, onDeclineAction: onDeclineAction))
        box.value = self
        observation = store.$state.sink { [weak box] state in
            Task { @MainActor in
                box?.value?.apply(state)
            }
        }
        apply(store.state)
    }

    // MARK: - Key handling

    /// **Never becomes key — the inverse of `FailsafePanel`'s override, and every bit as
    /// deliberate.**
    ///
    /// The FAILSAFE overrides `canBecomeKey` to `true` so ⌘C / ⏎ / ✕ reach it while the target
    /// app keeps the field. The live pill has no affordances — nothing to copy, nothing to retry —
    /// and its whole job is to stay out of the way: a titled `NSPanel` can become key by default,
    /// and a pill that can is one keypress from stealing the field the user is dictating into
    /// (`PRODUCT_SPEC.md:22` — "It does not take focus — ever"). The override makes the absence
    /// explicit rather than inherited, and `WidgetPanelBindingTests` pins it.
    public override var canBecomeKey: Bool { false }

    // MARK: - The window follows the store

    /// The single funnel the store's every publication flows through: show a non-IDLE widget, a
    /// notice, or a presented confirmation card (and hide a returned-to-IDLE one with no card and
    /// no notice). Read, not remembered: `isVisible` is the window's own answer, so a stale
    /// belief about visibility is impossible.
    ///
    /// The sound hook rides the same funnel (`dual-mode` D6): the selection's verdict on the
    /// `lastState → state.state` diff plays — the converse entry tick exactly once per entry, and
    /// nothing else (the phase change is silent; the dictation transitions are silent because
    /// the dictate tick is not built). The first entry to converse creates the panel on the
    /// same fold, so the initial `apply` here is the one that plays.
    @MainActor
    private func apply(_ state: WidgetReducerState) {
        if let sound = WidgetSoundSelection.sound(from: lastState, to: state.state) {
            soundPlayer.play(sound)
        }
        lastState = state.state
        let shouldShow = state.state != .idle || state.notice != nil || state.confirmation != nil
        if shouldShow {
            if !isVisible {
                orderFrontRegardless()
            }
            // The pill's width is its content's (IDLE is a dot, RECORDING is a waveform plus
            // timers) — the window refits so the capsule always hugs what it shows.
            setContentSize(contentView?.fittingSize ?? frame.size)
        } else if isVisible {
            orderOut(nil)
        }
    }
}

/// The weak hand the `@Sendable` sink writes so the main-actor task can reach the panel.
///
/// `@unchecked Sendable` because the sink's closure is `@Sendable` and arrives on whatever thread
/// `@Published` emits from: the box is written at construction and read inside the main-actor task,
/// so every access is confined to the main actor — the annotation is the compiler's view of that
/// confinement, not a substitute for it (the ``AppBootstrap`` `WeakBox` precedent).
private final class WidgetPanelBox: @unchecked Sendable {
    weak var value: WidgetPanel?

    init() {}
}
