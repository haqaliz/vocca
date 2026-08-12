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

    /// The store observation, cancelled with the window.
    private var observation: AnyCancellable?

    /// The box the `@Sendable` sink writes so the main-actor task can reach the window — the
    /// ``AppBootstrap`` `WeakBox` shape, kept here rather than reused because that one is private
    /// to the composition root.
    private let box = WidgetPanelBox()

    public init(store: WidgetStateStore, levelSource: any LiveLevelSource) {
        self.store = store
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 30),
            styleMask: [.nonactivatingPanel, .titled],
            backing: .buffered,
            defer: false)
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: WidgetView(store: store, level: levelSource))
        box.value = self
        observation = store.$state.sink { [weak box] state in
            Task { @MainActor in
                box?.value?.apply(state)
            }
        }
        apply(store.state)
    }

    // MARK: - The window follows the store

    /// The single funnel the store's every publication flows through: show a non-IDLE widget (or a
    /// notice), hide a returned-to-IDLE one. Read, not remembered: `isVisible` is the window's own
    /// answer, so a stale belief about visibility is impossible.
    @MainActor
    private func apply(_ state: WidgetReducerState) {
        let shouldShow = state.state != .idle || state.notice != nil
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
