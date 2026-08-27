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
import Foundation
import VoccaCore

/// **The TRY IT delivery sink — A4's stand-in replaced by the real delivery end (A5).** The
/// window-free object the composition root builds in `configure` and the loop's
/// ``OnboardingInjector`` holds: the A4 `PendingOnboardingSink`'s role, with the delivery
/// semantics the A4 seam documented — the sink forwards the transcript to the registered
/// destination (the onboarding window's field binding), and a delivery with no registered
/// destination **fails honestly**: the binding is gone — the window closed mid-dictation — so
/// the sink throws, the pipeline surfaces the reason-only failure (`OnboardingInjector.swift`'s
/// documented refusal), and the store folds ``OnboardingAction/tryItFailed``. Never a fabricated
/// success, never a silent idle.
///
/// The stand-in held the latest transcript in memory across the gap until the window shipped;
/// the shipped sink does not, because the gap is closed: the window is shown at launch until
/// the completion flag is set (`main()`'s auto-show, M4), so the destination is registered
/// before any dictation can occur — the only window with no destination is a window the user
/// closed, and for that window the honest refusal is the surface the A4 seam already promised.
///
/// ## Delivery semantics belong to the sink's destination
///
/// ``deliver(_:)`` forwards to the registered destination — the field binding's appender, which
/// makes the text visible where the user is looking — and then completes the flow: the sink
/// folds ``OnboardingAction/tryItSucceeded(_:)`` into its store (G5: "success here = onboarding
/// complete"), which writes the persisted flag (A3). The destination is registered by the
/// window when it is built; the composition root owns the sink-to-window wiring.
///
/// ## Isolation
///
/// `@MainActor`, like everything on the loop's UI side (the `PendingOnboardingSink` precedent):
/// the sink's store folds and the destination's field append both live in the one domain the
/// window renders from. The `Sendable` conformance is satisfied through the async method — a
/// caller on any actor hops to the main actor.
@MainActor
public final class OnboardingDeliverySink: OnboardingTranscriptSink {

    /// Why a delivery cannot happen: no destination is registered — the window was never built
    /// (unreachable in the shipped graph: the window auto-shows at launch until completion) or
    /// was closed mid-dictation. The A4 documented refusal, thrown so the pipeline surfaces the
    /// reason-only failure rather than a fabricated delivered result.
    public enum DeliveryError: Error {
        case destinationUnavailable
    }

    /// The flow the delivery completes.
    private let store: OnboardingStore

    /// The registered destination — the window's field appender, answering whether the delivery
    /// happened (`false` = the binding is gone — the window closed mid-dictation). `nil` until
    /// the window is built, and the absence is the honest refusal above.
    private var destination: ((String) -> Bool)?

    /// - Parameter store: The flow's store — the sink completes it on a landed delivery.
    public init(store: OnboardingStore) {
        self.store = store
    }

    /// Delivers `transcript` to the registered destination — the field binding at ship — and
    /// completes the flow. Throws ``DeliveryError/destinationUnavailable`` when no destination
    /// is registered **or** the destination refused (the window closed mid-dictation), after
    /// folding ``OnboardingAction/tryItFailed`` — the honest refusal the A4 seam documented,
    /// never a fabricated success and never a completion the user did not see land.
    public func deliver(_ transcript: String) async throws {
        guard let destination else {
            store.fold(.tryItFailed)
            throw DeliveryError.destinationUnavailable
        }
        guard destination(transcript) else {
            store.fold(.tryItFailed)
            throw DeliveryError.destinationUnavailable
        }
        store.fold(.tryItSucceeded(transcript))
    }

    /// Registers the delivery destination — called by the onboarding window's constructor, so
    /// the root's sink-to-window wiring is the window's own registration. The answer is whether
    /// the delivery landed (the window appends and answers `true` only while it is presented).
    public func register(_ destination: @escaping @MainActor (String) -> Bool) {
        self.destination = destination
    }
}

/// The TRY IT field's observable text — owned by the window, bound into the view, appended by
/// the sink's destination. A small `ObservableObject` rather than a `@Published` on the window
/// because the window is an `NSObject` (the `NSWindowDelegate` conformance) and `@Published`
/// requires the `ObservableObject` conformance this type carries.
@MainActor
public final class OnboardingFieldModel: ObservableObject {
    /// The field's text — the delivered transcripts, appended, plus anything the user types.
    @Published public var text = ""

    public init() {}

    /// Appends one delivered transcript to the field — the sink's destination at ship: the text
    /// lands where the user is looking, joined by a space so several dictations read as several
    /// sentences rather than one run-on.
    func append(_ transcript: String) {
        text = text.isEmpty ? transcript : "\(text) \(transcript)"
    }
}

/// What the onboarding window can do, injected so the window knows nothing about the composition
/// root and the root knows nothing about SwiftUI — the ``SettingsBindings`` closure-seam shape
/// (`SettingsView.swift:24-58`): every closure here is a seam the app fills with something real
/// and a test fills with a fake.
@MainActor
public struct OnboardingBindings {

    /// Opens the Accessibility pane in System Settings — the pane button's action (A2's
    /// ``SystemSettingsPane``), the Accessibility prompt itself (M5c: the pane is its prompt).
    public var openAccessibilityPane: () -> Void

    /// Opens the Microphone pane in System Settings — the exact toggle the M2 denial surface
    /// names.
    public var openMicrophonePane: () -> Void

    /// The mic request (M5b) — fires the system prompt at the moment the flow controls it. The
    /// wiring calls `MicrophoneAuthorization.requestAccess()` and folds the answer into the
    /// store; the window never sees AVFoundation.
    public var requestMicrophoneAccess: () -> Void

    /// Builds a download session for the MODEL step — user-initiated only, from the window. `nil`
    /// when the shipped manifest could not be loaded (a broken install — the step shows its
    /// title and Skip, nothing else).
    public var makeDownloadSession: () -> (any ModelDownloadSession)?

    /// The relaunch (M3): quit + relaunch the same bundle (A2's ``AppRelaunch``), single-fire
    /// guarded by the window.
    public var restart: () -> Void

    public init(
        openAccessibilityPane: @escaping () -> Void,
        openMicrophonePane: @escaping () -> Void,
        requestMicrophoneAccess: @escaping () -> Void,
        makeDownloadSession: @escaping () -> (any ModelDownloadSession)?,
        restart: @escaping () -> Void
    ) {
        self.openAccessibilityPane = openAccessibilityPane
        self.openMicrophonePane = openMicrophonePane
        self.requestMicrophoneAccess = requestMicrophoneAccess
        self.makeDownloadSession = makeDownloadSession
        self.restart = restart
    }
}