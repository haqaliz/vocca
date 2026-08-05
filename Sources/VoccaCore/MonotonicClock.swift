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

/// The only way time enters this module.
///
/// One property, returning a `Duration` since an arbitrary, process-local origin — the same
/// convention ``RawKeyEvent/timestamp`` documents, and for the same reason: only *differences*
/// between two readings are meaningful, and that is all the ceiling ever needs. A wall-clock reading
/// would be wrong across an NTP step or a daylight-saving change, and `Date` is unreachable here
/// anyway.
///
/// ## Why it is injected rather than read
///
/// `spec.md` requires the ceiling and poll tests to be deterministic and instant, and a test cannot
/// wait 120 s to find out whether the ceiling fires. So the session machine reads this and nothing
/// else, and a test hands it a clock it moves by hand.
///
/// **The import lint does not enforce this on its own, and it is worth being precise about why.**
/// `CoreBoundaryTests` keeps `Foundation`, `Dispatch` and `Darwin` out of `VoccaCore`, which removes
/// `Date()`, `DispatchTime.now()` and `mach_absolute_time()`. It does not remove
/// `ContinuousClock().now`: `ContinuousClock` and `SuspendingClock` are *standard library* types, so
/// they need no import and an allow-list of imports cannot see them arrive. That gap is closed by a
/// second, narrower lint (`CoreBoundaryTests.testVoccaCoreReadsNoClockOfItsOwn`) naming those two
/// types directly. Both are needed: the allow-list closes the frameworks, and that lint closes the
/// standard library.
///
/// ## Why not the standard library's `Clock`
///
/// `Swift.Clock` requires an `Instant: InstantProtocol` and an `async` `sleep(until:tolerance:)`.
/// The session machine never sleeps — it is driven, by key events and by the watchdog's ticks — so
/// conforming would mean writing a suspension point nothing calls, in a module whose defining
/// property is that it does no I/O. Naming this protocol `Clock` would also shadow that one at every
/// use site inside the module.
///
/// ## What an implementation owes
///
/// **Monotonicity.** Readings must not go backwards. The machine does not *trust* that — it
/// accumulates elapsed time from the deltas between readings and contributes nothing for a negative
/// one, so a clock that steps backwards can extend a session by **at most one tick interval** *per
/// backward step* rather than by the whole jump (see ``SessionMachine/tick()`` for the arithmetic).
/// A conformance that reads a wall clock still fails the user in a way this module cannot see: it
/// will jump forwards too, and a forward jump ends a session early.
///
/// **And it must advance.** Monotonicity on its own is satisfied by a clock that never moves, and
/// that is the conformance this module cannot survive: ``SessionMachine/elapsed`` accumulates
/// *deltas*, so readings that stall disable the 120 s ceiling outright — not delay it, disable it.
/// Nothing looks wrong while it happens. The watchdog's timer goes on firing, and its poll goes on
/// answering correctly, because the poll reads no clock at all. So the residual is exactly the case
/// the ceiling exists to bound — a key reported physically down with nobody behind it — now with no
/// bound whatsoever. A cached reading, or a frozen test double that reaches a release build, is all
/// it takes. `SessionWatchdogTests.testAClockThatNeverAdvancesDisablesTheCeilingButNotThePoll`
/// measures both halves of that: 10 000 wakes with `elapsed` at zero and the session still
/// recording, and the poll still ending it the moment the key comes up.
public protocol MonotonicClock {
    /// Time since an arbitrary, process-local origin. Never a wall-clock reading.
    var now: Duration { get }
}
