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
import VoccaHotkey

/// **The tap, minus the tap.**
///
/// `CGEvent.tapCreate` returns `nil` without an Accessibility grant and no hosted runner can be
/// granted one, so the real ``HotkeyEventSource`` is the one thing in this aspect that CI can never
/// execute. This is the same seam with the system call taken out: a test hands it an event, it goes
/// through whatever is above the seam, and the answer comes back here — which is exactly the shape
/// of the `CGEvent` callback, where returning the event means the focused application gets it and
/// returning `nil` means it does not.
///
/// ## Why the ledgers are here rather than beside the machine
///
/// Because **this is the far end of the seam**, and that is the only place H6 can honestly be
/// asserted. `SessionWatchdogTests` already pins both directions of propagation at the *near* end,
/// by reading the `SessionResponse` the watchdog returns. That is a different claim: it says the
/// machine's answer is correct, not that the answer survives the journey back out to the caller. A
/// source that ignored the disposition it was handed — or inverted it, or hard-coded one — would
/// pass every assertion phrased against the response and eat the user's whole keyboard anyway.
///
/// So ``applicationSaw`` is built from the value this object *returns*, never from anything the
/// machine reported about itself, and every H6 assertion is made against it.
final class FakeHotkeyEventSource: RecoverableHotkeyEventSource {

    /// What the next ``start(delivering:)`` reports. A tap genuinely can fail to be created — that
    /// is what a missing Accessibility grant looks like — and what to *do* about it is the tap-health
    /// policy's, not this double's.
    var nextStart: HotkeyEventSourceStart = .started

    /// What the next ``resumeDelivery()`` reports. `CGEventTapEnable` genuinely can fail to take —
    /// which is the whole of acceptance H4, and the only reason the policy has a re-creation path.
    var nextResume: TapResume = .resumed

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var resumeCount = 0

    /// The sink, held for exactly as long as the tap exists. `nil` is "there is no tap", and it is
    /// the state a stopped or unavailable source is in.
    private var sink: (any HotkeyEventSink)?

    /// **A tap that exists and is switched off.** The third state, and the one the whole health
    /// policy is about: the system disabled it out of band, the sink is still attached, the
    /// `CFMachPort` is still alive — and not one keystroke reaches Vocca.
    ///
    /// Modelled separately from "no tap" because the recoveries differ: this one can be switched back
    /// on in place, and a destroyed tap cannot.
    private(set) var isDisabledBySystem = false

    /// Whether a tap exists at all, disabled or not.
    var isAttached: Bool { sink != nil }

    /// Whether events are actually reaching Vocca. A disabled tap is attached and delivers nothing.
    var isDelivering: Bool { sink != nil && !isDisabledBySystem }

    /// Every event that crossed the seam, in order.
    ///
    /// The cardinality guard for every test in this file: a test that drove the machine directly
    /// rather than through the seam would leave this short, and would otherwise be indistinguishable
    /// from one that did the work.
    private(set) var deliveredEvents: [RawKeyEvent] = []

    /// The disposition that came back for each of ``deliveredEvents``, in the same order.
    private(set) var dispositions: [EventPropagation] = []

    /// **The focused application's entire input.** Every event this source returned `.passThrough`
    /// for, in order — including the ones it never delivered anywhere because it was not running.
    ///
    /// A stopped tap does not swallow: no tap means every keystroke reaches the app untouched, which
    /// is the correct and the *safe* behaviour, and it is asserted rather than assumed.
    private(set) var applicationSaw: [RawKeyEvent] = []

    /// Events that arrived while nothing was delivering. Counted rather than dropped silently, so a
    /// test cannot mistake "the pipeline ignored it" for "the pipeline never saw it".
    private(set) var eventsArrivingWhileStopped = 0

    /// Events that arrived while the tap existed but was switched off. Counted separately from the
    /// above for the same reason ``isDisabledBySystem`` is a separate state: a policy that destroyed
    /// the tap and one that left it disabled look identical from a single combined counter.
    private(set) var eventsArrivingWhileDisabled = 0

    /// Run from *inside* ``resumeDelivery()``, once the tap is delivering again and before the answer
    /// comes back. The counterpart of ``RecordingSource/duringEndCapture``, and it models the same
    /// class of hazard on the other seam: switching a tap back on runs through CoreFoundation, which
    /// pumps the run loop, so a key event queued behind the disablement can arrive **in the middle of
    /// the recovery**.
    ///
    /// Fired once and then cleared, for the reason the audio ledger's hooks are: a hook that
    /// re-entered the call it is inside of would recurse until the stack ran out, which reports
    /// `signal 11` instead of naming the invariant that broke.
    var duringResume: (() -> Void)?

    /// The same, for tap creation. `CGEvent.tapCreate` and attaching a run-loop source are the
    /// heavier of the two, so this is the likelier of the two to have an event arrive underneath it.
    var duringStart: (() -> Void)?

    func start(delivering sink: any HotkeyEventSink) -> HotkeyEventSourceStart {
        // **A start on an already-started source is a stop followed by a start**, and this double
        // models it because the real adapter must. Phase 3's charter is "if re-enable fails, tear
        // down and re-create" and "re-create on didWakeNotification" — a caller that re-creates is a
        // caller that calls `start` again, and a conformance that just overwrote its state there
        // would leak a CFMachPort and a run-loop source, and leave a *second* tap installed whose
        // callback still points at the previous context. Given the unretained-context idiom, that is
        // a use-after-free on the next keystroke.
        if isAttached { stop() }

        startCount += 1
        guard nextStart == .started else { return .unavailable }
        self.sink = sink
        // A freshly created tap is not a disabled one. Carrying the old tap's disabled state onto a
        // new one would make re-creation look like a recovery that never worked.
        isDisabledBySystem = false

        // Fired once the tap would really be delivering, because that is when a queued event could
        // really arrive: before this point there is nothing installed for it to arrive through.
        let hook = duringStart
        duringStart = nil
        hook?()

        return .started
    }

    func stop() {
        stopCount += 1
        sink = nil
        isDisabledBySystem = false
    }

    func resumeDelivery() -> TapResume {
        resumeCount += 1
        guard nextResume == .resumed else { return .failed }
        isDisabledBySystem = false

        let hook = duringResume
        duringResume = nil
        hook?()

        return .resumed
    }

    // MARK: - Driving it

    /// The operating system switches the tap off, out of band.
    ///
    /// The state the two `kCGEventTapDisabled…` notifications announce. It is a fact about the tap
    /// and not about the notification, which is why it is set here rather than inferred by the policy
    /// from having been told: a test that only told the policy would leave a tap that still delivers,
    /// and every "the tap recovered" assertion would pass without a recovery.
    func systemDisablesTheTap() {
        isDisabledBySystem = true
    }

    /// One key event arrives at the tap. Returns what the focused application gets, which is what
    /// the `CGEvent` callback's return value means.
    @discardableResult
    func deliver(_ event: RawKeyEvent) -> EventPropagation {
        guard let sink else {
            // No tap: the event was never seen by Vocca at all, so it goes to the application
            // untouched. This is the honest model of a tap that was never created or has been
            // destroyed — and it is why a source that fails to start cannot cost the user their
            // keyboard.
            eventsArrivingWhileStopped += 1
            applicationSaw.append(event)
            return .passThrough
        }

        guard !isDisabledBySystem else {
            // A tap that exists and is switched off. The callback is not called at all, so Vocca
            // never sees the event and the application gets it untouched — which is *why* the key-up
            // that would have ended a session is never coming, and why the policy has to end it.
            eventsArrivingWhileDisabled += 1
            applicationSaw.append(event)
            return .passThrough
        }

        let disposition = sink.receive(event)
        deliveredEvents.append(event)
        dispositions.append(disposition)
        switch disposition {
        case .passThrough: applicationSaw.append(event)
        case .swallow: break
        }
        return disposition
    }

    // MARK: - What the application made of it

    /// Key-downs the application received for `keyCode`. Each one is a character typed into the
    /// field the transcript is about to be injected into.
    func charactersTyped(for keyCode: UInt16) -> Int {
        applicationSaw.filter { $0.kind == .keyDown && $0.keyCode == keyCode }.count
    }

    /// Key-downs **and** key-ups the application received for `keyCode`. Separate from
    /// ``charactersTyped(for:)`` because a key-up types nothing and is invisible to that count —
    /// which is how a whole branch of the claim went unpinned in the merged aspect.
    func keyEventsSeen(for keyCode: UInt16) -> Int {
        applicationSaw.filter {
            $0.keyCode == keyCode && ($0.kind == .keyDown || $0.kind == .keyUp)
        }.count
    }

    /// The key codes the application believes are held: every key-down it saw, minus every key-up.
    /// A non-empty set at the end of a gesture is a key the app thinks is still down.
    var keysTheApplicationBelievesAreDown: Set<UInt16> {
        var down: Set<UInt16> = []
        for event in applicationSaw {
            switch event.kind {
            case .keyDown: down.insert(event.keyCode)
            case .keyUp: down.remove(event.keyCode)
            case .flagsChanged, .tapDisabled: break
            }
        }
        return down
    }
}

// MARK: - Where a session's effects go once they are out of the machine

// No shared `Effect` typealias: `SessionMachineTests` and `SessionWatchdogTests` each declare a
// file-private one, and a module-scope declaration of the same name makes the lookup in those files
// ambiguous rather than shadowed. The full type is written out below instead — it appears three
// times, which is cheaper than renaming a spelling two merged suites already use.

/// The transcribing actor's place in the pipeline, as a ledger.
///
/// **This is the only route by which a test driving the seam can observe an outcome**, and that is
/// the point. ``HotkeyEventSink/receive(_:)`` returns an ``EventPropagation`` and nothing else, so a
/// sink that dropped the ``SessionEffect`` would still answer the tap correctly and still swallow the
/// right keys — and would lose every transcript. Reading outcomes from here rather than from a return
/// value makes that failure visible.
///
/// Shared between `HotkeyEventSourceTests` and `TapHealthPolicyTests` rather than copied, for the
/// reason the top of this file gives: two ledgers that drifted would let one suite's session end look
/// different from the other's.
final class EffectLog {
    private(set) var effects: [SessionEffect<RecordingSource.Buffer>] = []

    func record(_ effect: SessionEffect<RecordingSource.Buffer>) { effects.append(effect) }

    var outcomes: [SessionOutcome<RecordingSource.Buffer>] {
        effects.compactMap { effect in
            switch effect {
            case .ended(let outcome): return outcome
            case .unchanged, .started, .captureUnavailable: return nil
            }
        }
    }

    /// Why each session ended, in order. `nil` for a cancellation, which discards its audio and so
    /// carries no ``RetainedEndReason`` at all.
    var endReasons: [RetainedEndReason?] {
        outcomes.map { outcome in
            switch outcome.content {
            case .completed(let reason, _, _): return reason
            case .cancelled: return nil
            }
        }
    }

    var starts: Int {
        effects.filter { effect in
            switch effect {
            case .started: return true
            case .unchanged, .captureUnavailable, .ended: return false
            }
        }.count
    }
}

/// A sink that writes down every event it is handed and passes it on unchanged.
///
/// The only way to see the event the tap-health policy **synthesises**: that event never travels
/// through the source, because there is no keystroke behind it, so the fake tap's ledgers cannot see
/// it. Interposed here, the exact `RawKeyEvent` the policy minted is a value a test can compare.
///
/// It forwards rather than replaces, so the session underneath is the shipped one and the assertion
/// about the synthetic event and the assertion about what it did are made on the same run.
final class ObservingSink: HotkeyEventSink {
    private let downstream: any HotkeyEventSink
    private(set) var received: [RawKeyEvent] = []

    init(forwardingTo downstream: any HotkeyEventSink) {
        self.downstream = downstream
    }

    func receive(_ event: RawKeyEvent) -> EventPropagation {
        received.append(event)
        return downstream.receive(event)
    }
}

// MARK: - The two mutants, as sinks

/// A sink that swallows everything. **The defect this aspect exists to make unreachable**, kept as a
/// runnable object rather than described in a comment.
///
/// In the merged aspect a watchdog wrapper that hard-coded `.swallow` survived the entire suite,
/// because every propagation assertion covered the swallow direction only. This is that mutation,
/// available to be run: a test whose H6 assertions cannot tell this apart from the real sink is
/// measuring nothing, and says so by failing.
final class AlwaysSwallowingSink: HotkeyEventSink {
    private(set) var received = 0

    func receive(_ event: RawKeyEvent) -> EventPropagation {
        received += 1
        return .swallow
    }
}

/// A sink that passes everything through. The other half of the control, and the less obvious one:
/// it is what a sink that forgot to swallow the hotkey looks like, and it types `⌥Space` —
/// U+00A0 NO-BREAK SPACE on a US layout — into the field the transcript is about to be injected
/// into, invisibly.
final class AlwaysPassingThroughSink: HotkeyEventSink {
    private(set) var received = 0

    func receive(_ event: RawKeyEvent) -> EventPropagation {
        received += 1
        return .passThrough
    }
}
