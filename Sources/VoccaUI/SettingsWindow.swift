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

/// The settings window, owned for the app's lifetime and shown on demand.
///
/// **The one window in Vocca that is allowed to take focus.** Everything else — the pill, the
/// failsafe — is built around never stealing the field the user is dictating into. This is the
/// exception, and it is safe precisely because it is modal to the user's intent: they asked for it
/// from the menu, so there is no dictation in flight to interrupt.
///
/// That also means the app must briefly become a regular application to show it. An `LSUIElement`
/// process has no Dock icon and cannot ordinarily bring a window to the front or give it a menu
/// bar, so `show()` switches the activation policy to `.regular` for as long as the window is up
/// and drops back to `.accessory` when it closes. Without that the window appears behind whatever
/// the user was in, unfocusable — which is exactly the "nothing happened" this surface exists to
/// end.
///
/// Glue, and executed by nothing in CI: a hosted runner has no window server.
@MainActor
public final class SettingsWindow: NSObject, NSWindowDelegate {

    private let bindings: SettingsBindings
    private var window: NSWindow?
    /// The sweep that keeps the sidebar-toggle toolbar item out of the titlebar — SwiftUI's
    /// `NavigationSplitView` re-adds it on re-render, so a single removal does not stick.
    /// `nil` while the window is closed, so the sweep runs only while settings is up.
    private var sidebarSweepTimer: Timer?

    public init(bindings: SettingsBindings) {
        self.bindings = bindings
    }

    /// Shows the window, creating it on first use, and brings it to the front.
    ///
    /// Idempotent: a second Settings… while the window is open raises the existing one rather than
    /// stacking another. Menu items get double-clicked.
    public func show() {
        if window == nil {
            // The four pieces that make an `NSWindow` host a split view the way SwiftUI's own
            // `WindowGroup` does — the shape `DeckApp` gets for free by being a `WindowGroup`
            // (`../deck/native/DeckApp/DeckApp.swift:18-27`) and this window has to ask for:
            //
            // - `.fullSizeContentView`, so the content area reaches the top of the window and the
            //   sidebar can run the window's full height with the traffic lights sitting on it,
            //   instead of starting below a titlebar drawn across everything.
            // - `contentViewController`, not `contentView`: the sidebar's full-height layout and
            //   the titlebar's safe area are negotiated through the hosting *controller*. Hand
            //   AppKit a bare `NSHostingView` and SwiftUI has no window integration to negotiate
            //   with — it falls back to drawing the sidebar as an inset panel inside the content.
            // - `.unified` toolbar style, so the window title sits at the head of the detail
            //   column rather than centred over both columns.
            // - the toolbar itself, kept (see `removeSidebarToggleIfPresent`).
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false)
            window.title = "Vocca Settings"
            window.titleVisibility = .visible
            window.toolbarStyle = .unified
            window.contentViewController = NSHostingController(
                rootView: SettingsView(bindings: bindings))
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            self.window = window
        }

        // `.regular` first, then activate: an accessory app's window cannot become key, and a
        // settings window that cannot take a keystroke is a picture of settings.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        startSidebarSweep()
    }

    /// Returns the app to its accessory life when the window closes.
    ///
    /// Without this Vocca keeps a Dock icon and a menu bar for the rest of the session, having
    /// been a background agent for its whole existence up to that point — and the next dictation
    /// would then be typed by an app that can steal focus.
    public func windowWillClose(_ notification: Notification) {
        sidebarSweepTimer?.invalidate()
        sidebarSweepTimer = nil
        NSApp.setActivationPolicy(.accessory)
    }

    /// Closes the window, if one is up — the refused-quit's consequence, and the one other caller
    /// of the close path there is. Goes through the window's own delegate, so the accessory
    /// return and the sweep teardown happen exactly as they do for the user's own close.
    public func close() {
        window?.close()
    }

    // MARK: - The sidebar toggle

    /// The sidebar is pinned open (`columnVisibility: .constant(.all)`) — there is nothing to
    /// toggle — so the toolbar's sidebar-toggle button is removed and kept removed, the `DeckApp`
    /// shape (`../deck/native/DeckApp/DeckApp.swift:722-729`): find the item by its private
    /// identifier and drop it, scanning backwards so removals cannot shift the indices being
    /// examined. The timer re-arms the removal on every tick because SwiftUI re-inserts the item
    /// when the split view re-renders; a single post-show removal survives only until the first
    /// tab switch.
    ///
    /// **The toolbar itself stays.** An earlier version dropped it once the toggle was gone, to be
    /// rid of the divider the button stood next to; what it was actually dropping was the unified
    /// titlebar the split view is laid out against — the title fell back to the centre of a plain
    /// titlebar and the sidebar stopped reaching the top of the window. Deck keeps its toolbar for
    /// the same reason, and removes only the item.
    private func startSidebarSweep() {
        guard sidebarSweepTimer == nil else { return }
        sidebarSweepTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.removeSidebarToggleIfPresent() }
        }
        removeSidebarToggleIfPresent()
    }

    private func removeSidebarToggleIfPresent() {
        guard let toolbar = window?.toolbar else { return }
        for index in toolbar.items.indices.reversed() {
            if toolbar.items[index].itemIdentifier.rawValue
                == "com.apple.SwiftUI.navigationSplitView.toggleSidebar" {
                toolbar.removeItem(at: index)
            }
        }
    }
}
