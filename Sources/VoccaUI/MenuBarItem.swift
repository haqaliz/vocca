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

/// **The status item, and nothing else.** Translation from a ``MenuBarState`` to an `NSStatusItem`
/// and an `NSMenu`, with no decisions in it.
///
/// Every decision this surface could make is above it and tested headlessly: which state the
/// conditions resolve to (``MenuBarStateReducer``), which symbol and words that state carries
/// (``MenuBarCopy``). What is left here is an image, a title and a menu — the tap adapter's
/// division of labour, applied to a window-server object CI cannot create.
///
/// This file is therefore **executed by nothing in CI**, on purpose. A hosted runner has no menu
/// bar, `NSStatusBar.system` has nothing to attach to, and the smoke checklist is where it is
/// first run.
@MainActor
public final class MenuBarItem {

    /// The status item, retained for the app's lifetime. Released only at quit: an item that is
    /// deallocated disappears from the menu bar, which is the failure this whole surface exists to
    /// prevent.
    private let item: NSStatusItem

    /// The hotkey as the user sees it, for the copy that names it.
    private let hotkey: String

    /// What to run when the user picks the blocked state's button.
    private let onAction: (MenuBarState) -> Void
    /// What to run for Settings.
    private let onOpenSettings: () -> Void
    /// What to run for Quit.
    private let onQuit: () -> Void

    /// The state currently drawn. Kept so a fold that changes nothing does not rebuild the menu
    /// under a user who has it open.
    private var state: MenuBarState?

    /// - Parameters:
    ///   - hotkey: the chord in display form, e.g. `⌥Space`.
    ///   - onAction: invoked for a blocked state's call to action.
    ///   - onOpenSettings: invoked for the Settings item.
    ///   - onQuit: invoked for the Quit item.
    public init(
        hotkey: String,
        onAction: @escaping (MenuBarState) -> Void,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.hotkey = hotkey
        self.onAction = onAction
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        // `.variableLength` because the item is an icon whose symbol changes width between states.
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        apply(.ready)
    }

    /// Draws a state: the icon, its accessibility label, and the menu behind it.
    ///
    /// Idempotent by state, so the ~1 s health poll that feeds this can call it every tick without
    /// rebuilding an open menu out from under the user's cursor.
    public func apply(_ next: MenuBarState) {
        guard next != state else { return }
        state = next

        if let button = item.button {
            // A **template** image: monochrome, tinted by the system for a light or dark menu bar
            // automatically. It is also why shape is the only channel the state has — see
            // `MenuBarCopy.symbolName(for:)`.
            let image = NSImage(
                systemSymbolName: MenuBarCopy.symbolName(for: next),
                accessibilityDescription: nil)
            image?.isTemplate = true
            button.image = image
            button.setAccessibilityLabel(
                MenuBarCopy.accessibilityLabel(for: next, hotkey: hotkey))
        }

        item.menu = menu(for: next)
    }

    /// Builds the menu for a state.
    ///
    /// Rebuilt per state rather than mutated, because the shape differs: a blocked state carries a
    /// call to action that a working one has no row for at all.
    private func menu(for state: MenuBarState) -> NSMenu {
        let menu = NSMenu()

        // The status block: what Vocca is doing, then what that means. Disabled because it is a
        // readout, not a command — an enabled row invites a click that would do nothing.
        let title = NSMenuItem(
            title: MenuBarCopy.statusTitle(for: state), action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let detail = NSMenuItem(
            title: MenuBarCopy.statusDetail(for: state, hotkey: hotkey),
            action: nil, keyEquivalent: "")
        detail.isEnabled = false
        // The detail is a sentence, not a label, so it is set small — the size AppKit uses for
        // secondary text in a menu.
        detail.attributedTitle = NSAttributedString(
            string: MenuBarCopy.statusDetail(for: state, hotkey: hotkey),
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        menu.addItem(detail)

        if let actionTitle = MenuBarCopy.actionTitle(for: state) {
            menu.addItem(.separator())
            let action = NSMenuItem(
                title: actionTitle, action: #selector(runAction), keyEquivalent: "")
            action.target = self
            menu.addItem(action)
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit Vocca", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func runAction() {
        guard let state else { return }
        onAction(state)
    }

    @objc private func openSettings() { onOpenSettings() }

    @objc private func quit() { onQuit() }
}
