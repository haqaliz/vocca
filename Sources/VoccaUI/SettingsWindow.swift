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

    public init(bindings: SettingsBindings) {
        self.bindings = bindings
    }

    /// Shows the window, creating it on first use, and brings it to the front.
    ///
    /// Idempotent: a second Settings… while the window is open raises the existing one rather than
    /// stacking another. Menu items get double-clicked.
    public func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false)
            window.title = "Vocca Settings"
            window.contentView = NSHostingView(rootView: SettingsView(bindings: bindings))
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
    }

    /// Returns the app to its accessory life when the window closes.
    ///
    /// Without this Vocca keeps a Dock icon and a menu bar for the rest of the session, having
    /// been a background agent for its whole existence up to that point — and the next dictation
    /// would then be typed by an app that can steal focus.
    public func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
