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

/// **The hotkey recorder** — thin glue over ``HotkeyRecorderReducer``.
///
/// ## How a chord is captured, and how it is deliberately not
///
/// Through a **first-responder override in Vocca's own window**: while the capture view is first
/// responder it sees `keyDown`, `flagsChanged` and `performKeyEquivalent` and consumes them, and
/// everywhere else on the machine the keyboard is untouched. It is the ``FailsafePanel`` pattern,
/// which already takes ⌘C / ⏎ / ✕ this way.
///
/// The two alternatives were rejected and must stay rejected (`plan_20260830.md` §0):
///
/// - **Diverting the `CGEvent` tap.** The tap swallows what it takes, system-wide. A recorder stuck
///   in the recording state would be eating the user's entire keyboard, and the way out of that
///   needs the keyboard. It would also make the recorder depend on the Accessibility grant, which
///   is precisely the permission a user with a dead hotkey has come here to work around.
/// - **A global `NSEvent` monitor.** The same swallow risk, over a wider area than is needed.
///
/// ## What silence means, and what it must not be read as
///
/// A chord the system claims first — ⌘Space with Spotlight enabled, ⌘Tab — may never reach this
/// responder at all. **"Nothing arrived" is indistinguishable from "nothing was pressed"**, so no
/// inference is built on it: the recorder simply keeps waiting until Escape or a click away. It is
/// the same wall `shortcut-conflicts` hit, and the reason a conflict *probe* is deliberately not
/// built here.
///
/// ## Executed by nothing in CI
///
/// A hosted runner has no window server (the window-server precedent). The reducer, the copy and
/// the wiring are the tested half; `SMOKE_CHECKLIST.md` is where this file first runs.
struct HotkeyRecorderView: View {

    let bindings: SettingsBindings

    @State private var state: HotkeyRecorderState = .idle
    /// The modifiers held right now, for the live preview while a chord is being pressed. Display
    /// only: nothing is bound from it, and a modifier alone is refused by the rules anyway.
    @State private var heldModifiers: ModifierSet = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(SettingsCopy.hotkeyLabel) {
                ZStack {
                    // The capture view sits behind the label so it can be made first responder
                    // without changing the layout.
                    HotkeyCaptureView(
                        isRecording: state.isRecording,
                        onKeyEvent: { rawFlags, keyCode in
                            let chord = bindings.chordForKeyEvent(rawFlags, keyCode)
                            apply(.chordCaptured(chord, bindings.validateChord(chord)))
                        },
                        // Through the same seam the chord is, with a key code the `fn` rule does
                        // not touch — so an explicitly-held fn shows, and this view still
                        // translates nothing itself.
                        onFlagsChanged: { heldModifiers = bindings.chordForKeyEvent($0, 0).modifiers },
                        onAbort: { apply(.cancelled) })
                    .frame(width: 0, height: 0)

                    Button(action: { apply(.began) }) {
                        Text(chordLabel)
                            .font(.system(.body, design: .rounded))
                            .frame(minWidth: 96)
                    }
                    .help(SettingsCopy.hotkeyRecordButton)
                }
            }

            if state.isRecording {
                Text(SettingsCopy.hotkeyRecordingPrompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if case .confirming(_, let warning) = state.phase {
                warningRow(warning)
            }

            if let notice = state.notice {
                Text(text(for: notice))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        // The chord is applied here rather than inside `apply`, so that the one place a rebind can
        // be triggered is a state the reducer put the recorder into — not a branch in a button.
        .onChange(of: state.chordToApply) { _, chord in
            guard let chord else { return }
            apply(.rebindAnswered(bindings.rebind(chord)))
        }
    }

    /// What the control reads while it is not recording: the chord that is actually bound, asked
    /// afresh so a rebind is visible the moment it lands.
    private var chordLabel: String {
        switch state.phase {
        case .recording:
            // The modifiers so far, so a user holding ⌃⌥ can see the recorder is listening. Empty
            // renders the prompt's job, not a blank box.
            let held = HotkeyChordFormatter.describe(keyCode: 0, modifiers: heldModifiers)
            return held.isEmpty ? SettingsCopy.hotkeyRecordButton : held
        case .confirming(let chord, _):
            return HotkeyChordFormatter.describe(
                keyCode: chord.keyCode, modifiers: chord.modifiers)
        case .idle, .applying:
            return bindings.hotkeyDisplayName()
        }
    }

    @ViewBuilder
    private func warningRow(_ warning: HotkeyBindingWarning) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch warning {
            case .usedBySystemShortcut(let name):
                Text(SettingsCopy.hotkeySystemShortcutWarning(name: name))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(SettingsCopy.hotkeyUseAnyway) { apply(.confirmed) }
                Button(SettingsCopy.hotkeyCancel) { apply(.cancelled) }
            }
        }
    }

    private func text(for notice: HotkeyRecorderNotice) -> String {
        switch notice {
        case .chordRefused(let refusal): return SettingsCopy.hotkeyRefusal(refusal)
        case .rebindRefused(let refusal): return SettingsCopy.hotkeyRebindRefusal(refusal)
        }
    }

    /// The single funnel every transition flows through — the ``FailsafePanel`` shape. The reducer
    /// is pure and tested (`HotkeyRecorderReducerTests`); this is glue.
    private func apply(_ action: HotkeyRecorderAction) {
        state = HotkeyRecorderReducer.reduce(state, action)
        if !state.isRecording { heldModifiers = [] }
    }
}

/// The `NSView` that takes the keyboard **while it is first responder, and only then**.
///
/// It makes no decisions: it reads the raw modifier word and the virtual key code off the event and
/// hands them up. Every question about what those mean — which modifiers, the `fn` rule, whether
/// the chord may be bound — is answered above it, by code that runs headlessly.
private struct HotkeyCaptureView: NSViewRepresentable {

    let isRecording: Bool
    let onKeyEvent: (UInt64, UInt16) -> Void
    let onFlagsChanged: (UInt64) -> Void
    let onAbort: () -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onKeyEvent = onKeyEvent
        view.onFlagsChanged = onFlagsChanged
        view.onAbort = onAbort
        return view
    }

    func updateNSView(_ view: KeyCaptureNSView, context: Context) {
        view.onKeyEvent = onKeyEvent
        view.onFlagsChanged = onFlagsChanged
        view.onAbort = onAbort
        view.isRecording = isRecording
        if isRecording {
            view.window?.makeFirstResponder(view)
        } else if view.window?.firstResponder === view {
            view.window?.makeFirstResponder(nil)
        }
    }
}

/// The responder itself.
final class KeyCaptureNSView: NSView {

    var isRecording = false
    var onKeyEvent: ((UInt64, UInt16) -> Void)?
    var onFlagsChanged: ((UInt64) -> Void)?
    var onAbort: (() -> Void)?

    /// Escape's virtual key code. Handled here rather than folded as a capture, because the rules
    /// refuse every Escape chord as ``HotkeyBindingRefusal/reservedByVocca`` — so folding one would
    /// answer a user's *abort* with a refusal notice.
    private static let escapeKeyCode: UInt16 = 53

    /// Only while recording, so the settings window's ordinary focus behaviour is untouched the
    /// rest of the time.
    override var acceptsFirstResponder: Bool { isRecording }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        capture(event)
    }

    /// ⌘-chords reach a view this way rather than through `keyDown`, and the app would otherwise
    /// act on them — ⌘Q during a recording would quit Vocca instead of binding ⌘Q. Returning `true`
    /// consumes the event, which is safe precisely because it happens only while recording and only
    /// inside this window.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        capture(event)
        return true
    }

    /// The live preview of what is being held. It also **consumes** the event while recording, so a
    /// lone modifier does not travel on to the rest of the window.
    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        onFlagsChanged?(UInt64(event.modifierFlags.rawValue))
    }

    /// Clicking away aborts — the recorder must not stay armed while the user's attention is
    /// somewhere else, waiting to bind whatever they type next.
    override func resignFirstResponder() -> Bool {
        if isRecording { onAbort?() }
        return super.resignFirstResponder()
    }

    private func capture(_ event: NSEvent) {
        guard event.keyCode != Self.escapeKeyCode else {
            onAbort?()
            return
        }
        onKeyEvent?(UInt64(event.modifierFlags.rawValue), event.keyCode)
    }

}
