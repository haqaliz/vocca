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
final class FakeHotkeyEventSource: HotkeyEventSource {

    /// What the next ``start(delivering:)`` reports. A tap genuinely can fail to be created — that
    /// is what a missing Accessibility grant looks like — and what to *do* about it is Phase 3's
    /// policy, not this double's.
    var nextStart: HotkeyEventSourceStart = .started

    private(set) var startCount = 0
    private(set) var stopCount = 0

    /// The sink, held for exactly as long as the source is delivering. `nil` is "there is no tap",
    /// and it is the state a stopped or unavailable source is in.
    private var sink: (any HotkeyEventSink)?

    /// Whether events are being delivered anywhere at all.
    var isDelivering: Bool { sink != nil }

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

    func start(delivering sink: any HotkeyEventSink) -> HotkeyEventSourceStart {
        // **A start on an already-started source is a stop followed by a start**, and this double
        // models it because the real adapter must. Phase 3's charter is "if re-enable fails, tear
        // down and re-create" and "re-create on didWakeNotification" — a caller that re-creates is a
        // caller that calls `start` again, and a conformance that just overwrote its state there
        // would leak a CFMachPort and a run-loop source, and leave a *second* tap installed whose
        // callback still points at the previous context. Given the unretained-context idiom, that is
        // a use-after-free on the next keystroke.
        if isDelivering { stop() }

        startCount += 1
        guard nextStart == .started else { return .unavailable }
        self.sink = sink
        return .started
    }

    func stop() {
        stopCount += 1
        sink = nil
    }

    // MARK: - Driving it

    /// One key event arrives at the tap. Returns what the focused application gets, which is what
    /// the `CGEvent` callback's return value means.
    @discardableResult
    func deliver(_ event: RawKeyEvent) -> EventPropagation {
        guard let sink else {
            // No tap: the event was never seen by Vocca at all, so it goes to the application
            // untouched. This is the honest model of a tap that was never created, has been
            // destroyed, or is disabled — and it is why a source that fails to start cannot cost
            // the user their keyboard.
            eventsArrivingWhileStopped += 1
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
