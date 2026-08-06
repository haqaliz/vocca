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

/// **A session, plugged into a ``HotkeyEventSource``.**
///
/// Three lines of body, and every one of them is a place the merged aspects found a defect:
///
/// 1. **The event goes to the watchdog, not to the machine.** ``SessionWatchdog`` is where every
///    input a session has arrives, and a key event is the only input that can move the machine into
///    `.recording` — so it is the only one after which ``SessionWatchdog/schedule`` changes and the
///    owner must start its timer. An owner routing key events past it would be reading the schedule
///    off the object the session did *not* start through.
/// 2. **The effect leaves by a different door.** ``HotkeyEventSink/receive(_:)`` can only return an
///    ``EventPropagation``, and ``SessionEffect`` is the only thing in this module that ever carries
///    a ``SessionOutcome``. A sink that dropped it would answer the tap correctly, swallow exactly
///    the right keys, and lose every word the user said. So it is handed to ``deliverEffect``, which
///    the owner supplies, and there is no version of this class that does not have one.
/// 3. **The disposition is returned unchanged.** Not adjusted, not clamped, not decided here. That
///    is inherited constraint 4, and it is the one with the blast radius: this method sees nearly
///    every keystroke the user makes all day, in every application, because stop rule (c) needs
///    events Vocca has no interest in. A hard-coded `.swallow` here is not an edge case — it is the
///    user's entire keyboard, gone, for as long as Vocca runs. That exact mutation survived a green
///    119-test suite in `session-lifecycle` because the assertions covered the swallow direction
///    only, and `HotkeyEventSourceTests` now pins both directions at the far end of the seam, where
///    a source that ignored the answer would also be caught.
///
/// ## Why it is a class the owner builds rather than a closure it writes
///
/// The closure form — `source.start { watchdog.observe($0).eventPropagation }` — compiles, is
/// shorter, and silently discards the ``SessionEffect``. Every transcript, on the floor, with a
/// green suite and a working hotkey. Making the effect a constructor parameter is what turns that
/// from a thing an owner must remember into a thing an owner cannot omit.
///
/// ## Isolation
///
/// Not `Sendable`, and it cannot be: it holds a ``SessionWatchdog``, which holds a
/// ``SessionMachine``, which is deliberately not `Sendable` because a `CGEvent` tap callback is a
/// synchronous C function that cannot `await`. So the tap, this sink, the watchdog, the machine and
/// the timer all live in one isolation domain — `@MainActor` in `hotkey-source` — and everything
/// ``SessionEffect`` carries is `Sendable`, so it can cross to the actor that transcribes.
public final class SessionEventSink<Audio: CapturedAudio>: HotkeyEventSink {
    private let watchdog: SessionWatchdog<Audio>
    private let deliverEffect: (SessionEffect<Audio>) -> Void

    /// - Parameters:
    ///   - watchdog: The session every event is routed through. Held rather than the machine
    ///     directly, so that there is no second door into the session for an input to arrive by.
    ///   - deliverEffect: Where what the session did goes next. Called for **every** event, including
    ///     the overwhelming majority that produce ``SessionEffect/unchanged`` — filtering here would
    ///     be this class forming an opinion about which effects matter, which is the owner's to have.
    public init(
        watchdog: SessionWatchdog<Audio>,
        deliverEffect: @escaping (SessionEffect<Audio>) -> Void
    ) {
        self.watchdog = watchdog
        self.deliverEffect = deliverEffect
    }

    public func receive(_ event: RawKeyEvent) -> EventPropagation {
        let response = watchdog.observe(event)
        deliverEffect(response.effect)
        return response.eventPropagation
    }
}
