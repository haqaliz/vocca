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

import Combine
import VoccaCore

/// **The live pill's window, owned lazily**: constructed the first time the store has something
/// to show, and self-driving show/hide from the store from then on.
///
/// The FAILSAFE window is *told* when to present — `FailsafePanel/presentHeldTranscript()` is
/// the root's call, because that seam has no push (`FailsafePanel.swift:33-42`). The live pill is
/// the opposite shape: ``WidgetPanel`` observes the store's `@Published` state and orders itself
/// front and out (`WidgetPanel.swift:36-45`), so the only thing missing was the object that
/// **holds** the window and decides **when it may exist**. This is that object, and it is the
/// composition root's hand on the window, exactly as `DictationLoopRoot` holds the event tap:
/// a window nobody owns is a window that can vanish under the widget.
///
/// ## Why the window is created lazily
///
/// `AppBootstrap.configure` is driven by the zero-network probe, and the probe's charter is that
/// nothing it can reach may create windows — the window-server rows of `SMOKE_CHECKLIST.md` are
/// the smoke section's, not CI's. So ``LiveWidget``'s initializer creates nothing: it holds the
/// store and the level source and subscribes, and the window is constructed on the first state
/// fold that gives it something to show — a non-IDLE state, or the terminal notice over IDLE
/// (`WidgetPanel/apply(_:)`'s own should-show rule, applied here one fold early). From that
/// instant the panel's own observation drives everything; this object's remaining job is to keep
/// the window alive.
///
/// ## Isolation
///
/// `@MainActor`, like the panel and the store: the `@Published` observation hops to the main
/// actor (the ``WidgetPanel`` shape — the sink is `@Sendable` and the window is not), and every
/// fold the root makes happens there anyway.
@MainActor
public final class LiveWidget {

    /// The store the panel renders and follows — the same instance the effect stream folds.
    public let store: WidgetStateStore

    /// The injected input level the waveform draws — the real `VoccaAudio` conformance
    /// (`MicrophoneLevelSource`) at ship, a fake in the headless tests.
    public let level: any LiveLevelSource

    /// The window, once it exists. `nil` until the first non-IDLE state or terminal notice —
    /// the laziness that keeps `configure` window-free.
    public private(set) var presentedPanel: WidgetPanel?

    /// The store observation, cancelled with this object. Without it, a widget that never left
    /// IDLE would never exist at all — the subscription is what notices the first fold that
    /// orders it into being.
    private var observation: AnyCancellable?

    /// - Parameters:
    ///   - store: The root's widget store — the one the effect stream folds
    ///     (`DictationLoopRoot/widgetStore`).
    ///   - level: The level source the waveform draws; the composition root injects the real
    ///     `MicrophoneLevelSource` over the capture graph.
    public init(store: WidgetStateStore, level: any LiveLevelSource) {
        self.store = store
        self.level = level
        observation = store.$state.sink { [weak self] state in
            Task { @MainActor in
                self?.presentIfNeeded(state)
            }
        }
        presentIfNeeded(store.state)
    }

    /// Constructs the window the first time the store has something to show.
    ///
    /// The panel's own store observation does the showing from then on; the two guards are what
    /// make the creation lazy — an IDLE store with no notice (the state `configure` leaves) is a
    /// no-op, and an existing panel is one.
    private func presentIfNeeded(_ state: WidgetReducerState) {
        guard state.state != .idle || state.notice != nil else { return }
        guard presentedPanel == nil else { return }
        presentedPanel = WidgetPanel(store: store, levelSource: level)
    }
}
