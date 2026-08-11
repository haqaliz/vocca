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

/// The outcome of one ``TextInjector/inject(_:into:)`` call — what the ladder's decision
/// function returns and the loop wiring consumes.
///
/// The four fields of `ARCHITECTURE.md:172-177`, and three of them carry a specific reading:
///
/// - `rung == .widgetFailsafe` is a *successful* outcome under I1 (`ARCHITECTURE.md:199`): a
///   transcript that reached the failsafe is not lost, and nothing downstream may treat it as an
///   error — the failsafe window rendering it is delivery, not failure;
/// - `attempted` is the full ladder trace, in attempt order — exactly the input C8's per-app
///   strategy memory demotes on, so it must survive the round trip intact;
/// - `verified` carries the read-back truth and nothing more: the AX rung's
///   `succeeded(verified: false)` counts as *failure* (`ARCHITECTURE.md:400`), and the
///   *decision* interprets that — this struct only carries the fact so every consumer reads one
///   shape.
///
/// `elapsed` is accumulated from the injected ``MonotonicClock`` — deltas, never a wall clock,
/// the negative-delta rule from `SessionMachine.tick()` applied to the ladder's budget.
public struct InjectionResult: Sendable, Equatable {
    /// The rung that delivered the text. `.widgetFailsafe` is a success.
    public var rung: InjectionRung
    /// The full ladder trace, in attempt order.
    public var attempted: [InjectionRung]
    /// Whether the insert was read back and confirmed. `false` for the rungs that have no
    /// read-back (clipboard, keystroke) and for the failsafe.
    public var verified: Bool
    /// Total ladder time, from the injected clock.
    public var elapsed: Duration

    /// The decision function's answer, as the loop wiring receives it. Plain memberwise and
    /// public — the Phase C fault-injection suite builds results by hand.
    public init(rung: InjectionRung, attempted: [InjectionRung], verified: Bool, elapsed: Duration) {
        self.rung = rung
        self.attempted = attempted
        self.verified = verified
        self.elapsed = elapsed
    }
}
