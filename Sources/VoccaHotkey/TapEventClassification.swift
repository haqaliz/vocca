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
/// The same two reasons `HotkeyFlagTranslation` gives, pointing the same way: CoreGraphics is
/// deliberately not imported here, so that the seam's forbidden types have no way to reach a file
/// that is not the adapter, and so that this module stays a `UInt64` and a `UInt32` away from any
/// framework whose start-up behaviour would have to be argued about inside the zero-network guard.
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
    /// than in the adapter is that both of its failure modes are silent:
    ///
    /// - **Too narrow** and the hotkey is deaf. Dropping `flagsChanged` in particular does not break
    ///   loudly — it deletes stop rules (b) and (c), so `⌥Space` still starts a session and
    ///   releasing Option before Space no longer ends one. A hot mic to the ceiling, every time, from
    ///   one absent bit.
    /// - **Too wide** and every mouse move on the machine is routed through the session rules, on
    ///   the callback, with the timeout that earns.
    ///
    /// Computed from ``keyEventTypes`` rather than written as a literal, so that the set the mask
    /// requests and the set the classifier understands are the same list read twice. The two
    /// disablements are deliberately absent: they are delivered to the callback whatever the mask
    /// says, and a bit set for them here would be a bit set outside the range of anything a mask is
    /// consulted for.
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
