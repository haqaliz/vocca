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

/// The FAILSAFE window — the ladder's last rung made visible, as a **non-activating panel** that
/// never takes focus (`PRODUCT_SPEC.md:22`) but can still answer its key equivalents while the
/// user stays in the target app.
///
/// This file is **glue, and its chrome is executed by nothing in CI.** Every decision the window
/// can make is above it and tested headlessly — the custody vocabulary in ``FailsafeState`` and
/// its reducer, the copy in ``FailsafeCopy``, and the panel's own contracts (delivery, copy
/// routing, retry routing, dismiss-and-release, relaunch) in `FailsafePanelContractTests`, which
/// drives this class's routing methods against a fake holder and recording handlers. What CI
/// cannot reach is the *focus behaviour*: whether a non-activating panel that `canBecomeKey`
/// still lets the target app keep its field, whether ⌘C lands while the target app is frontmost,
/// and whether Esc dismisses — those are the smoke checklist's rows (`SMOKE_CHECKLIST.md:429-442`),
/// run on the founder's machine.
///
/// ## How custody arrives (the seam has no push)
///
/// ``TranscriptHolder`` offers `hold`/`current`/`release` and nothing else — there is no
/// "transcript held" notification to subscribe to. The composition root therefore *tells* the
/// panel when a failsafe has fired (after awaiting the holder's `hold`), and the panel answers by
/// reading `current()`: ``presentHeldTranscript()`` is that read, and ``loadJournalOnLaunch()``
/// is the same read at startup, carrying the unresolved entry's captured-at note
/// (`PRODUCT_SPEC.md:117`). The voice-processing loop's refusals have no transcript to read —
/// ``presentReasonOnly(_:)`` takes the reason itself as the whole payload (PRD R5). Neither is a
/// poll — the window adds no timer and no loop.
///
/// ## The injected handlers
///
/// ⌘C routes through the injected ``copyHandler``, ⏎ through the injected ``retryHandler`` — and
/// **neither this file nor any other in `VoccaUI` names `NSPasteboard`.** The copy's write is the
/// composition root's job: it wires the handler to the pasteboard adapter
/// (`VoccaInject/Clipboard/SystemPasteboard.swift`), keeping the pasteboard seam at exactly one
/// file (`InjectionSeamBoundaryTests`' pasteboard family) and `VoccaUI` a pure Core-seam consumer
/// (`ModuleBoundaryTests`: `VoccaUI` imports only `VoccaCore` among Vocca modules).
///
/// ⌘C always copies the held transcript **in full** (`PRODUCT_SPEC.md:106`): the pill offers the
/// transcript's whole text, not selection copying — the affordances line says "⌘C to copy", and
/// that is what it means. The state's `.copied` case records that the full text went to the
/// handler, so a repeat ⌘C carries the same text again.
///
/// ## The key trick
///
/// `styleMask` includes `.nonactivatingPanel` (ordering the window never activates Vocca) and
/// ``canBecomeKey`` is overridden to `true`: a non-activating panel *can* become key without
/// activating its app, and a key panel receives `performKeyEquivalent`/`keyDown` — which is how
/// ⌘C / ⏎ / ✕ reach the routing methods while the target app keeps focus. Whether the target
/// app's field survives that keyness is exactly the smoke-only question above.
public final class FailsafePanel: NSPanel {

    /// What ⌘C does with the held text — the composition root wires it to the pasteboard adapter.
    public typealias FailsafeCopyHandler = (HeldTranscript) -> Void
    /// What ⏎ does with the held text — the composition root wires it to a ladder re-run against
    /// current focus (`PRODUCT_SPEC.md:116`).
    public typealias FailsafeRetryHandler = (HeldTranscript) -> Void

    private let holder: any TranscriptHolder
    private let copyHandler: FailsafeCopyHandler
    private let retryHandler: FailsafeRetryHandler

    /// The reducer's state — the single funnel everything below reads, and the single thing the
    /// view renders. `FailsafePanelContractTests` asserts on it directly.
    public private(set) var state: FailsafeState = .hidden

    public init(
        holder: any TranscriptHolder,
        copyHandler: @escaping FailsafeCopyHandler,
        retryHandler: @escaping FailsafeRetryHandler
    ) {
        self.holder = holder
        self.copyHandler = copyHandler
        self.retryHandler = retryHandler
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
            styleMask: [.nonactivatingPanel, .titled],
            backing: .buffered,
            defer: false)
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        render()
    }

    // MARK: - Custody in

    /// The failsafe fired: read the holder and present what it holds. The composition root calls
    /// this after the ladder's `hold` answers — the *delivery* (the seam has no push).
    ///
    /// `nil` when nothing is held: a failsafe that did not leave a transcript shows nothing.
    @discardableResult
    public func presentHeldTranscript() async -> HeldTranscript? {
        guard let transcript = await holder.current() else { return nil }
        apply(.transcriptHeld(transcript))
        return transcript
    }

    /// The relaunch read: present the journal's unresolved entry with its captured-at note intact
    /// (`PRODUCT_SPEC.md:117`). The note is carried by the transcript and flows untouched.
    @discardableResult
    public func loadJournalOnLaunch() async -> HeldTranscript? {
        guard let transcript = await holder.current() else { return nil }
        apply(.relaunchLoaded(transcript))
        return transcript
    }

    /// A reason-only notice (PRD R5): the voice-processing loop failed with `reason` and no text
    /// was ever held — the panel shows the cause and the ✕ affordance, nothing to copy and
    /// nothing to retry. The composition root calls this after a `.modelUnavailable` or
    /// `.transcriptionFailed` refusal; unlike the custody entries there is no holder read — the
    /// reason is the whole payload, so the notice is dispatched and ordered front in one call.
    ///
    /// `@MainActor` like every entry on this window: the panel is an `NSPanel` subclass.
    public func presentReasonOnly(_ reason: FailsafeReason) {
        apply(.reasonShown(reason))
        showWindow()
    }

    // MARK: - The intents (⌘C, ⏎, ✕)

    /// ⌘C: the reducer decides *what* is copied — the full held text — and the handler delivers
    /// exactly that, once. A stray ⌘C on a failsafe that never fired is a no-op: nothing held,
    /// nothing written to the pasteboard.
    ///
    /// Not named `copy`: `NSObject.copy()` is inherited by every AppKit class, so the name would
    /// be ambiguous at every call site that can see both.
    public func copyTranscript() {
        guard let transcript = heldTranscript(from: state) else { return }
        apply(.copyRequested)
        copyHandler(transcript)
    }

    /// ⏎: re-run the ladder against current focus. The transcript is *retained* through the
    /// re-run — custody is not released into it — and a failed re-run re-holds, returning the
    /// panel to `presenting` with the text intact (`PRODUCT_SPEC.md:116`).
    public func retryTranscript() {
        guard let transcript = heldTranscript(from: state) else { return }
        apply(.retryRequested)
        retryHandler(transcript)
    }

    /// ✕: the *only* path from a presented transcript to `hidden` — and the only route that
    /// releases the held transcript (`PRODUCT_SPEC.md:104`). A stray ✕ on a hidden failsafe
    /// releases nothing: it must not purge a journal the user has not resolved.
    public func dismissTranscript() async {
        let wasHolding = heldTranscript(from: state) != nil
        apply(.dismissRequested)
        if wasHolding {
            await holder.release()
        }
    }

    // MARK: - Chrome (smoke-only)

    /// Orders the panel front without activating Vocca, and makes it key — the standard
    /// non-activating-panel-with-key trick. Whether the target app's field survives is the smoke
    /// checklist's question, not CI's.
    public func showWindow() {
        orderFrontRegardless()
        makeKey()
    }

    /// Orders the panel out. Paired with ``dismiss()`` by the composition root and the ✕ path.
    public func hideWindow() {
        orderOut(nil)
    }

    // MARK: - Key handling

    /// The whole point of the subclass: a non-activating panel may still become key, so ⌘C / ⏎
    /// / ✕ reach the routing methods while the target app stays active.
    public override var canBecomeKey: Bool { true }

    /// ⌘C — the copy key equivalent. Handled here rather than by a menu so it works while the
    /// panel is key and the target app is active.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
            event.charactersIgnoringModifiers?.lowercased() == "c"
        {
            copyTranscript()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// ⏎ (key code 36) and ✕/Esc (key code 53): the two intents that are not key equivalents.
    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36:  // Return — the ⏎ affordance
            retryTranscript()
        case 53:  // Escape — the ✕ affordance
            Task { await dismissTranscript() }
            hideWindow()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - The reducer funnel

    /// The single funnel every transition flows through: reduce onto ``state``, then re-render.
    /// The reducer is pure (`FailsafeStateReducerTests`); this is glue.
    private func apply(_ action: FailsafeAction) {
        state = FailsafeStateReducer.reduce(state, action: action)
        render()
    }

    /// Re-hosts the content with the current state. The view's closures route through `self`
    /// weakly — the hosting view is held by the window's `contentView`, so a strong capture would
    /// be a retain cycle.
    private func render() {
        contentView = NSHostingView(
            rootView: FailsafeView(
                state: state,
                onCopy: { [weak self] in self?.copyTranscript() },
                onRetry: { [weak self] in self?.retryTranscript() },
                onDismiss: { [weak self] in
                    Task { [weak self] in
                        guard let self else { return }
                        await self.dismissTranscript()
                        self.hideWindow()
                    }
                }))
    }

    /// The held transcript any shown state carries — `hidden` holds nothing, a reason-only
    /// notice holds nothing (no text ever existed, PRD R5), and a hidden panel has nothing to
    /// copy, retry or release.
    private func heldTranscript(from state: FailsafeState) -> HeldTranscript? {
        switch state {
        case .hidden, .reasonOnly:
            return nil
        case .presenting(let transcript), .retrying(let transcript), .copied(let transcript):
            return transcript
        }
    }
}
