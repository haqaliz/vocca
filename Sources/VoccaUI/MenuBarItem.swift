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
import VoccaCore

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

    /// The hotkey as the user sees it, for the copy that names it — **asked, never captured**.
    ///
    /// The status item is built once and retained until quit, so a captured string would keep
    /// naming the launch chord in the VoiceOver label for the rest of the session, however many
    /// times the user rebound it.
    private let hotkey: () -> String

    /// What to run when the user picks the blocked state's button.
    private let onAction: (MenuBarState) -> Void
    /// What to run when the user picks a mode row — the mode machine's explicit start/stop
    /// (`dual-mode` D8). The menu offers; the machine routes: while a session of the other mode
    /// is active, the machine refuses (R1). The routing is `converse-wiring`'s +
    /// `mode-machine`'s work — this aspect ships the surface.
    private let onSelectMode: (SessionMode) -> Void
    /// What to run when the user picks the context kill row — the one-action revoke (`context-provider`
    /// M9): the wiring stops the reads, discards the in-flight snapshot, and folds the badge
    /// clear. Defaulted so `AppBootstrap`'s construction compiles unchanged; the wiring is
    /// `bootstrap-wiring`'s (recorded hand-off).
    private let onKillContext: () -> Void
    /// What to run for Settings.
    private let onOpenSettings: () -> Void
    /// What to run for Quit.
    private let onQuit: () -> Void

    /// The state currently drawn. Kept so a fold that changes nothing does not rebuild the menu
    /// under a user who has it open.
    private var state: MenuBarState?

    /// The mode the menu was last drawn with — the third input to the idempotence guard, so a
    /// mode change rebuilds the menu's checkmark exactly when it must.
    private var renderedMode: SessionMode?

    /// Whether the context kill row was last drawn — the fourth input to the idempotence guard,
    /// so a stale `true` cannot keep the row alive after a kill fold (D7).
    private var renderedContextReading: Bool = false

    /// The hotkey string the label was last drawn with. Part of the idempotence guard rather than
    /// a separate refresh call, so a rebind heals the label on the next condition tick — the ~1 s
    /// health poll — with nothing for a caller to forget to wire.
    private var renderedHotkey: String?

    /// - Parameters:
    ///   - hotkey: the chord in display form, asked afresh on every render.
    ///   - onAction: invoked for a blocked state's call to action.
    ///   - onOpenSettings: invoked for the Settings item.
    ///   - onQuit: invoked for the Quit item.
    ///   - onSelectMode: invoked for a mode row — defaulted so `AppBootstrap`'s construction
    ///     compiles unchanged; `converse-wiring` wires it to the mode machine.
    ///   - onKillContext: invoked for the context kill row — defaulted so `AppBootstrap`'s
    ///     construction compiles unchanged; `bootstrap-wiring` wires it to the kill handler.
    public init(
        hotkey: @escaping () -> String,
        onAction: @escaping (MenuBarState) -> Void,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onSelectMode: @escaping (SessionMode) -> Void = { _ in },
        onKillContext: @escaping () -> Void = {}
    ) {
        self.hotkey = hotkey
        self.onAction = onAction
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        self.onSelectMode = onSelectMode
        self.onKillContext = onKillContext
        // `.variableLength` because the item is an icon whose symbol changes width between states.
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        apply(.ready)
    }

    /// Draws a state: the icon, its accessibility label, and the menu behind it.
    ///
    /// Idempotent by state (and by mode, and by the context-reading fact), so the ~1 s health
    /// poll that feeds this can call it every tick without rebuilding an open menu out from
    /// under the user's cursor.
    public func apply(
        _ next: MenuBarState, mode: SessionMode = .dictation, contextReading: Bool = false
    ) {
        let hotkeyNow = hotkey()
        guard next != state || mode != renderedMode || hotkeyNow != renderedHotkey
            || contextReading != renderedContextReading
        else { return }
        state = next
        renderedMode = mode
        renderedHotkey = hotkeyNow
        renderedContextReading = contextReading

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
                MenuBarCopy.accessibilityLabel(for: next, hotkey: hotkeyNow))
        }

        item.menu = menu(for: next, mode: mode, contextReading: contextReading)
    }

    /// Builds the menu for a state and mode.
    ///
    /// Rebuilt per state rather than mutated, because the shape differs: a blocked state carries a
    /// call to action that a working one has no row for at all.
    ///
    /// Minimal by design (`PRODUCT_SPEC.md:328-330`): the state lives in the icon and the
    /// VoiceOver label, the menu carries commands. A readout row ("Vocca is ready", "Press
    /// ⌥Space…") was removed on the founder's call — the menu is for doing, not telling.
    ///
    /// The mode section (`PRODUCT_SPEC.md:361`, D8) is the one addition beyond that minimal set:
    /// the two mode rows, the active one checked (from the current mode), each row selecting its
    /// mode explicitly — the menu offers, the machine routes. The context kill row (`widget-indicator`
    /// D7) follows, present only while `contextReading` — a kill row shown when nothing is being
    /// read would be an invitation (M9).
    private func menu(for state: MenuBarState, mode: SessionMode, contextReading: Bool) -> NSMenu {
        let menu = NSMenu()

        if let actionTitle = MenuBarCopy.actionTitle(for: state) {
            let action = NSMenuItem(
                title: actionTitle, action: #selector(runAction), keyEquivalent: "")
            action.target = self
            menu.addItem(action)
            menu.addItem(.separator())
        }

        for rowMode in [SessionMode.dictation, SessionMode.conversing] {
            let row = NSMenuItem(
                title: MenuBarCopy.modeTitle(rowMode),
                action: #selector(selectMode(_:)),
                keyEquivalent: "")
            row.target = self
            row.representedObject = rowMode
            row.state = rowMode == mode ? .on : .off
            row.setAccessibilityLabel(MenuBarCopy.modeToggleTitle(rowMode))
            menu.addItem(row)
        }
        menu.addItem(.separator())

        if contextReading {
            let kill = NSMenuItem(
                title: MenuBarCopy.contextKillRowTitle,
                action: #selector(killContext),
                keyEquivalent: "")
            kill.target = self
            kill.setAccessibilityLabel(MenuBarCopy.contextKillAccessibilityLabel)
            menu.addItem(kill)
            menu.addItem(.separator())
        }

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

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? SessionMode else { return }
        onSelectMode(mode)
    }

    @objc private func killContext() { onKillContext() }

    @objc private func openSettings() { onOpenSettings() }

    @objc private func quit() { onQuit() }
}
