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

import VoccaCore

/// **What the menu bar icon says Vocca is doing** — the app's only always-present surface.
///
/// ## Why this exists at all
///
/// Vocca is `LSUIElement`: no Dock icon, no window, and a floating pill that appears only during a
/// dictation. So a Vocca that is running perfectly and a Vocca that died at launch look *exactly
/// the same* — nothing on screen either way. That is not a hypothetical: an app with no
/// Accessibility grant sat there deaf, an app with no model refused every press, and an app whose
/// embedded framework failed to load never reached `main()`, and all three presented as "I clicked
/// it and nothing happened".
///
/// The menu bar item is the fix, and this type is the part of it worth testing: *which* of the
/// conditions Vocca can be in is the one to show.
///
/// ## The closed set, and what is deliberately not in it
///
/// Every case below is a state the app can actually be in, reachable from something the loop
/// already reports — tap health, the readiness gate, the download session, the session machine.
/// The design proposals also drew a **Paused** state, and it is absent here on purpose: Vocca has
/// no pause. Drawing one would have been a new feature wearing a redesign's clothes, decided by a
/// mockup rather than by anyone. It may well be worth building; it is not worth *implying*.
public enum MenuBarState: Sendable, Hashable, CaseIterable {

    /// Idle and able to dictate: the model is prepared and the tap is delivering.
    case ready

    /// A session is capturing audio right now.
    case listening

    /// Audio is captured and the engine is working.
    case transcribing

    /// No Accessibility grant, so `CGEvent.tapCreate` returns nothing and the hotkey is deaf.
    /// The one state the user cannot fix from inside Vocca — macOS requires them to go to System
    /// Settings themselves, which is why its menu carries a button that takes them there.
    case noAccessibility

    /// No microphone: TCC denied, or the Mac has no input device at all.
    case noMicrophone

    /// The speech model is still arriving. Dictation is refused until it lands, so this is a
    /// blocker rather than a background nicety — but a self-resolving one.
    case downloadingModel

    /// The selected engine is warming up: its model is on disk and a preparation is running right
    /// now. Every launch passes through this, and so does every engine switch.
    ///
    /// Distinguished from ``downloadingModel`` because the waits are different lengths and from
    /// the *absence* of both because that one never ends by itself. Distinguished at all because of
    /// PRD M11: after a switch nothing is wrong, and an icon reporting the same thing it reports
    /// for a missing model would tell the user their switch broke something. It is the same failure
    /// shape as an `LSUIElement` app whose dead launch looks exactly like a live one — this
    /// repository's dominant bug class, which is why M11 calls it a must-have rather than polish.
    case preparingEngine

    /// Another application holds the keyboard (`IsSecureEventInputEnabled`), so no tap in the
    /// session receives key events and the hotkey is temporarily deaf.
    ///
    /// Distinguished from ``noAccessibility`` because the user's move is completely different:
    /// there is nothing to grant and nothing to fix. Leave the password field and it recovers by
    /// itself, which the menu says in those words rather than presenting a failure.
    case secureInput

    /// Whether this state stops a dictation from starting.
    ///
    /// Drives the icon's attention badge and the menu's call-to-action. ``secureInput`` counts:
    /// the hotkey genuinely will not fire. It is still the gentlest of the four, because it is the
    /// only one that ends on its own.
    public var isBlocked: Bool {
        switch self {
        case .ready, .listening, .transcribing: return false
        case .noAccessibility, .noMicrophone, .downloadingModel, .preparingEngine, .secureInput:
            return true
        }
    }

    /// Whether a session is in flight — the two states that are *activity* rather than condition.
    public var isActive: Bool {
        switch self {
        case .listening, .transcribing: return true
        case .ready, .noAccessibility, .noMicrophone, .downloadingModel, .preparingEngine,
            .secureInput:
            return false
        }
    }
}

/// The conditions the menu bar reads, gathered from the parts of the loop that already know them.
///
/// A plain snapshot rather than a stream: the reducer is pure, so the caller decides when to
/// sample, and a test can hand it any combination — including ones that cannot occur, which is how
/// the precedence below is pinned rather than assumed.
public struct MenuBarConditions: Sendable, Hashable {

    /// Whether a session is capturing audio.
    public var isCapturing: Bool
    /// Whether a transcription is in flight.
    public var isTranscribing: Bool
    /// Whether the hotkey is deaf for want of an Accessibility grant.
    ///
    /// Taken as a plain fact rather than as `VoccaHotkey.TapHealth`, so this module keeps its
    /// single dependency on `VoccaCore`. The composition root owns the translation — it is the
    /// only place that already knows both the tap and the widget, and a `TapHealth` case that
    /// means "deaf" is its business, not the menu's.
    public var isHotkeyDeafForPermission: Bool
    /// Whether the engine is prepared. `false` while the model downloads or fails to load.
    public var isEnginePrepared: Bool
    /// Whether a model download is running.
    public var isDownloadingModel: Bool
    /// Whether the selected engine's `prepare()` is running right now.
    ///
    /// Carried beside ``isEnginePrepared`` rather than folded into it, because the two answer
    /// different questions: that one is "may a session start?", this one is "is waiting the
    /// remedy?". Both false together is the state nobody should wait for.
    public var isPreparingEngine: Bool
    /// Whether the microphone is usable. `false` when TCC denied it or the Mac has no input.
    public var isMicrophoneAvailable: Bool
    /// Whether another application holds the keyboard, so no tap receives key events.
    public var isBlockedBySecureInput: Bool

    public init(
        isCapturing: Bool = false,
        isTranscribing: Bool = false,
        isHotkeyDeafForPermission: Bool = false,
        isEnginePrepared: Bool = true,
        isDownloadingModel: Bool = false,
        isPreparingEngine: Bool = false,
        isMicrophoneAvailable: Bool = true,
        isBlockedBySecureInput: Bool = false
    ) {
        self.isCapturing = isCapturing
        self.isTranscribing = isTranscribing
        self.isHotkeyDeafForPermission = isHotkeyDeafForPermission
        self.isEnginePrepared = isEnginePrepared
        self.isDownloadingModel = isDownloadingModel
        self.isPreparingEngine = isPreparingEngine
        self.isMicrophoneAvailable = isMicrophoneAvailable
        self.isBlockedBySecureInput = isBlockedBySecureInput
    }
}

/// The pure reduction from conditions to the one state the icon shows.
public enum MenuBarStateReducer {

    /// Resolves the conditions into a single state.
    ///
    /// ## The precedence, and why it is this way round
    ///
    /// **Activity outranks everything.** If audio is being captured, that is what the icon says,
    /// even if a model download is running in the background for the *other* engine. The user is
    /// mid-sentence; the icon's job at that moment is to confirm Vocca is hearing them, not to
    /// report housekeeping. The blocked states cannot co-occur with capture in practice — you
    /// cannot be recording without a grant, a microphone or a tap — so this ordering costs nothing
    /// real and settles the impossible combinations rather than leaving them to argument.
    ///
    /// **Then blockers, hardest first.** No Accessibility outranks the rest because it is the only
    /// one the user cannot resolve without leaving the app, and because it makes every other
    /// condition moot: a deaf hotkey means no dictation regardless of the microphone or the model.
    /// A missing microphone follows for the same reason — it defeats a grant that is otherwise
    /// fine. A downloading model comes next, being temporary and self-resolving. Secure Input is
    /// last of the four: it is the only one that needs no action at all.
    ///
    /// **Then ready**, which is the absence of everything above.
    public static func state(for conditions: MenuBarConditions) -> MenuBarState {
        if conditions.isCapturing { return .listening }
        if conditions.isTranscribing { return .transcribing }

        if conditions.isHotkeyDeafForPermission { return .noAccessibility }
        if !conditions.isMicrophoneAvailable { return .noMicrophone }
        // A download outranks a warm-up: it is the far longer wait and the one with progress worth
        // showing, so when both are true the download is what the icon reports.
        if conditions.isDownloadingModel { return .downloadingModel }
        // Then the warm-up, which is a wait the user need do nothing about — and which must not
        // read as the state below, where nothing is in flight and waiting is not the remedy (M11).
        if conditions.isPreparingEngine { return .preparingEngine }
        if !conditions.isEnginePrepared { return .downloadingModel }
        // Last of the four blockers: the only one that needs no action, and the only one that ends
        // on its own. A missing microphone or an unprepared engine outlasts a password field, so
        // the user hears about those first.
        if conditions.isBlockedBySecureInput { return .secureInput }
        return .ready
    }
}
