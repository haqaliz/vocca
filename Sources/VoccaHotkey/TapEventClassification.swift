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

/// What one raw macOS event type means to Vocca, in Vocca's own vocabulary.
///
/// Three cases, switched exhaustively and without a `default:`, so that a fourth meaning — a mouse
/// event the mask started asking for, say — is a compile error at the adapter rather than something
/// that quietly inherits an existing branch. The adapter is the half of this capability CI can never
/// execute, so "quietly inherits a branch" there means "is never seen by anybody until a user reports
/// it".
public enum TapEventClass: Sendable, Hashable {
    /// A keyboard event, as the kind the session rules speak. Deliver it to the sink and return the
    /// disposition that comes back.
    ///
    /// Never ``RawKeyEvent/Kind/tapDisabled``: that kind is *synthesised* by
    /// ``TapHealthPolicy`` when it ends a stranded session, and no macOS event type maps onto it.
    /// The out-of-band disablements arrive as ``disabled(_:)`` instead, because they are a
    /// question for the health policy and not an event to deliver.
    /// `TapEventClassificationTests.testNoEventTypeClassifiesAsTheSyntheticKind` pins that.
    case key(RawKeyEvent.Kind)

    /// The operating system switched the tap off, out of band. Not a keystroke: there is nothing to
    /// deliver and nothing for a focused application to receive.
    case disabled(TapDisableReason)

    /// Something the tap was not asked for.
    ///
    /// **Unreachable in production**, because ``TapEventTranslation/eventsOfInterestMask`` requests
    /// exactly the three key kinds and the two disablements are delivered whatever the mask says.
    /// It exists so that the switch above the seam is total *without* a `default:` — which is what
    /// makes widening the mask a decision somebody has to write down here, rather than a new event
    /// type silently landing on whichever branch happened to be last.
    ///
    /// `TapEventClassificationTests.testTheMaskAndTheClassificationAgreeExactly` is what keeps the
    /// two from drifting apart.
    case notOfInterest
}

/// Turns the event-type number macOS puts on a tap callback into a ``TapEventClass``.
///
/// The second of this module's two pure translations, and it exists for the same reason
/// ``HotkeyFlagTranslation`` does: it is a decision — *which events are ours, and what does each one
/// mean* — and every decision in this aspect has to live where a machine with no Accessibility grant,
/// no keyboard and no window server can run it. The tap adapter reads one integer off a real event
/// and calls this; it classifies nothing itself.
///
/// ## Why the numbers are written out rather than imported
///
/// The same reason `HotkeyFlagTranslation` gives: CoreGraphics is deliberately not imported here, so
/// that the seam's forbidden types have no way to reach a file that is not the adapter — which is
/// also what the H7 lint checks from outside.
///
/// It used to give a second reason as well — that this keeps the module a `UInt64` and a `UInt32`
/// away from any framework whose start-up behaviour would have to be argued about inside the
/// zero-network guard — and that clause became false in phase 4, when the module gained CoreGraphics,
/// CoreFoundation, Foundation and Carbon. See `HotkeyFlagTranslation`'s retraction of the identical
/// sentence. What is true is the narrow form: **this file** needs no framework to be read.
///
/// The cost is that a wrong number is not a compile error. Getting the *mask* wrong is the worst
/// failure in this file and it is silent in both directions: too narrow and the hotkey never fires,
/// too wide and Vocca is asked to adjudicate events it has no opinion about. So
/// `TapEventClassificationTests` drives this with `CGEventType`'s own values and rebuilds the mask
/// from them, which turns a transcription error into a test failure rather than a bug report. Do not
/// change a number below without running it.
///
/// Values read from `CGEventTypes.h` (`kCGEvent*`) in the macOS SDK, and measured against it on
/// 2026-08-05.
public enum TapEventTranslation {

    // MARK: - The macOS event-type numbers

    /// `kCGEventKeyDown`.
    private static let keyDownType: UInt32 = 10
    /// `kCGEventKeyUp`.
    private static let keyUpType: UInt32 = 11
    /// `kCGEventFlagsChanged`.
    private static let flagsChangedType: UInt32 = 12
    /// `kCGEventTapDisabledByTimeout`. Note that it is **not** near the others: the two disablements
    /// are at the top of the `UInt32` range, so no arithmetic relates them to the key types and
    /// neither may be extrapolated from a neighbour.
    private static let tapDisabledByTimeoutType: UInt32 = 0xFFFF_FFFE
    /// `kCGEventTapDisabledByUserInput`.
    private static let tapDisabledByUserInputType: UInt32 = 0xFFFF_FFFF

    /// The three key kinds, paired with what each one means. Read as a table rather than as a
    /// `switch` so that ``eventsOfInterestMask`` can be *computed* from the same list the classifier
    /// reads, which is what makes the two incapable of disagreeing.
    private static let keyEventTypes: [(type: UInt32, kind: RawKeyEvent.Kind)] = [
        (keyDownType, .keyDown),
        (keyUpType, .keyUp),
        (flagsChangedType, .flagsChanged),
    ]

    // MARK: - The mask

    /// The events the tap asks for: `keyDown | keyUp | flagsChanged`, as a bit per event type.
    ///
    /// **The single most consequential number in this aspect**, and the reason it is here rather
    /// than in the adapter is that every one of its failure modes is silent:
    ///
    /// - **Too narrow** and the hotkey is deaf, or degraded in a way nothing announces. Dropping
    ///   `keyDown` or `keyUp` is the loud version. Dropping **`flagsChanged`** is the quiet one, and
    ///   it is worth stating precisely, because the obvious summary of it is wrong: it deletes stop
    ///   rule (b) outright and narrows rule (c) to key events, so a session ends at the next
    ///   autorepeat or at key-up rather than the instant the chord is released. `SessionRules.swift`
    ///   puts `.keyDown` and `.flagsChanged` on the same branch and ends on a matching `.keyUp`
    ///   without consulting modifiers at all, so **the session still ends, and never later than the
    ///   finger** — this is a latency and extensibility bug (a modifier-only binding becomes
    ///   impossible to add), not a hot mic. In toggle mode, where `.flagsChanged` is `.ignore`, it
    ///   costs nothing whatsoever. The bit stays because the immediacy is the product, and because
    ///   nothing about its absence is visible from outside.
    /// - **Too wide** and every mouse move on the machine is routed through the session rules, on
    ///   the callback, with the timeout that earns.
    /// - **Too wide, and it is worse than that.** `CGEvent.h:274-280`: a tap that is not permitted to
    ///   monitor keyboard events has *"the appropriate bits in the mask cleared"* at creation, and
    ///   `tapCreate` returns `NULL` **only if that leaves the mask empty**. So `tapCreate` returning
    ///   `nil` *is* the Accessibility permission check — inherited constraint 3, and the whole of
    ///   acceptance H5 — **only because this mask is keyboard types and nothing else.** Add one mouse
    ///   bit and a machine with no grant gets a successful creation, a `.started` report, and a tap
    ///   that is enabled and permanently deaf, with no honest error anywhere: precisely the shape the
    ///   health poll cannot see (`TapHealthPolicy.pollTapHealth()`), assigned to phase 6.
    ///
    /// Computed from ``keyEventTypes`` rather than written as a literal, so that the set the mask
    /// requests and the set the classifier understands are the same list read twice. The two
    /// disablements are deliberately absent: they are delivered to the callback whatever the mask
    /// says, and a bit set for them here would be a bit set outside the range of anything a mask is
    /// consulted for.
    ///
    /// **Every entry must be below 64.** A `CGEventMask` is 64 bits and Swift's `<<` is a smart
    /// shift — it yields `0` for an over-shift rather than trapping — so a key type at or above 64
    /// would classify as a key event while contributing no bit at all, and the "one list read twice"
    /// property would be quietly false. The two disablement constants sitting two lines above this
    /// table are `0xFFFF_FFFE` and `0xFFFF_FFFF`, so the wrong edit is within reach.
    /// `TapEventClassificationTests.testEveryClassifiedKeyTypeIsRepresentableInTheMask` is what makes
    /// it a failure rather than a silence.
    public static let eventsOfInterestMask: UInt64 = keyEventTypes.reduce(into: 0) {
        mask, entry in
        mask |= (1 << UInt64(entry.type))
    }

    // MARK: - The classification

    /// What this event type is.
    ///
    /// - Parameter rawEventType: the event's type number — `CGEventType`'s `rawValue`, taken as an
    ///   integer so that no CoreGraphics type reaches this file.
    /// - Returns: the meaning, in this package's own vocabulary. ``TapEventClass/notOfInterest`` for
    ///   anything the mask never asked for.
    public static func classify(rawEventType: UInt32) -> TapEventClass {
        for entry in keyEventTypes where entry.type == rawEventType {
            return .key(entry.kind)
        }

        switch rawEventType {
        case tapDisabledByTimeoutType: return .disabled(.timeout)
        case tapDisabledByUserInputType: return .disabled(.userInput)
        default: return .notOfInterest
        }
    }
}
