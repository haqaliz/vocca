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

/// The five-step onboarding window (`first-run-permissions` A5) — **the second focus-taking
/// window**, following the ``SettingsWindow`` activation-policy dance exactly: `.regular` on
/// show, `.accessory` on every close (`SettingsWindow.swift:47-76`, PRD S2).
///
/// The window is owned by the composition root and **built lazily**: the initializer constructs
/// nothing — the ``NSWindow`` is created on the first ``show()`` through the injected
/// ``makeWindow`` closure — which is what keeps `AppBootstrap.configure` window-free for the
/// zero-network probe (the probe drives `configure`; the window is the smoke checklist's, never
/// CI's).
///
/// ## The tested routing surface
///
/// The parts a test can drive headlessly are exactly the parts this class owns *between* the
/// user's intent and the seam (the ``FailsafePanelContractTests`` shape):
///
/// - **Lazy construction** — ``makeWindow`` is invoked only on the first ``show()``.
/// - **The policy dance** — ``show()`` routes ``.regular`` through the injected
///   ``setActivationPolicy`` seam; ``windowWillClose`` routes ``.accessory`` (every close path).
/// - **Restart is single-fire** — ``restartRequested()`` fires the injected relaunch at most
///   once per presentation (a double-click must not relaunch twice), and a fresh presentation
///   re-arms it, so a failed relaunch remains retryable (R2).
/// - **The delivery wiring** — the initializer registers the field's appender into the root's
///   delivery sink, so TRY IT's transcript lands in the field and completes the flow (M6).
///
/// What CI cannot reach is the focus behaviour itself — whether the `.regular` window actually
/// takes the keyboard — which is the smoke checklist's row.
@MainActor
public final class OnboardingWindow: NSObject, NSWindowDelegate {

    /// The flow's store, driven by the root's reads.
    public let store: OnboardingStore

    /// The TRY IT field's text — bound into the view and appended by the sink's destination.
    public let field: OnboardingFieldModel

    /// The built window, once it exists. `nil` until the first ``show()`` — the laziness that
    /// keeps `configure` window-free.
    public private(set) var presentedWindow: NSWindow?

    /// The activation-policy switch seam — `.regular` on show, `.accessory` on close. The real
    /// seam is `NSApp.setActivationPolicy`; a test substitutes a recorder (the
    /// ``FailsafePanelContractTests`` routing-fakes shape).
    private let setActivationPolicy: (NSApplication.ActivationPolicy) -> Void

    /// The window builder — the real closure constructs the `NSWindow` hosting ``OnboardingView``;
    /// a test substitutes a counting builder for the laziness contract.
    private let makeWindow: () -> NSWindow

    private let bindings: OnboardingBindings
    private var window: NSWindow?
    /// The single-fire restart guard: cleared by every ``show()`` (a fresh presentation re-arms).
    private var restartFired = false
    /// Whether the window is presented — the delivery destination's honesty test: a transcript
    /// must not land in a window the user has closed, and a dictation while the window is down
    /// is the A4 documented refusal, not a hidden completion.
    private var isPresented = false

    /// - Parameters:
    ///   - store: The flow's store — the root's, over the real reads.
    ///   - sink: The root's delivery sink — the window registers its field into it, so TRY IT's
    ///     transcript lands here.
    ///   - bindings: The root's injected actions (panes, mic request, download session, relaunch).
    ///   - setActivationPolicy: The policy-switch seam; `NSApp.setActivationPolicy` at ship.
    ///   - makeWindow: The window builder; the real one hosts ``OnboardingView``, a test
    ///     substitutes a counting builder.
    public init(
        store: OnboardingStore,
        sink: OnboardingDeliverySink,
        bindings: OnboardingBindings,
        setActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Void =
            { NSApp.setActivationPolicy($0) },
        makeWindow: (() -> NSWindow)? = nil
    ) {
        self.store = store
        self.bindings = bindings
        self.setActivationPolicy = setActivationPolicy
        let field = OnboardingFieldModel()
        self.field = field
        self.makeWindow = makeWindow ?? {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false)
            window.title = "Welcome to Vocca"
            window.contentView = NSHostingView(
                rootView: OnboardingView(
                    store: store,
                    bindings: bindings,
                    field: field,
                    onRestart: { [weak window] in
                        window?.owner?.restartRequested()
                    }))
            window.isReleasedWhenClosed = false
            window.center()
            return window
        }
        super.init()
        // The root's sink-to-window wiring: the field's appender is the delivery destination,
        // answering whether the delivery landed — the window must be presented for a transcript
        // to be visible where the user is looking (a closed window refuses, the A4 refusal).
        // The closure is @MainActor like the window, so the sink's main-actor deliver reaches
        // it directly.
        sink.register { [weak self] transcript in
            guard let self, self.isPresented else { return false }
            self.field.append(transcript)
            return true
        }
    }

    /// Shows the window, creating it on first use, and brings it to the front.
    ///
    /// Idempotent: a second call raises the existing window. Routes the activation-policy
    /// switch seam to `.regular` — an `LSUIElement` process cannot make a window key — and
    /// refreshes the flow's statuses, so the rows render the live ✓/✗ the moment they can be
    /// seen.
    public func show() {
        if window == nil {
            let built = makeWindow()
            built.delegate = self
            window = built
            presentedWindow = built
        }
        isPresented = true
        store.refresh()
        setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        restartFired = false
    }

    /// Returns the app to its accessory life when the window closes — every close path, the
    /// `SettingsWindow` rule — drops the presentation flag (a closed window refuses delivery,
    /// the A4 "binding is gone" refusal), and folds the resume into the store (S3: the flow
    /// re-derives the first incomplete step; a completed flow is preserved whole).
    public func windowWillClose(_ notification: Notification) {
        isPresented = false
        setActivationPolicy(.accessory)
        store.fold(.windowClosed)
    }

    /// The [ Restart Vocca ] route (M3/M5c): folds the reducer's request, then fires the
    /// injected relaunch **at most once per presentation** — the single-fire guard against a
    /// double-click relaunching twice. Fires nothing when the offer is not showing.
    public func restartRequested() {
        store.fold(.restartRequested)
        guard store.state.restartOffered, !restartFired else { return }
        restartFired = true
        bindings.restart()
    }
}

private extension NSWindow {
    /// The window's delegate as the onboarding window — the real builder's weak route back to
    /// the object that owns the single-fire guard.
    var owner: OnboardingWindow? { delegate as? OnboardingWindow }
}