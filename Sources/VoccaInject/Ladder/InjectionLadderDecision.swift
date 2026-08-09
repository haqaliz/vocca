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

/// One ladder run, decided over injected handles — every row of `plan_20260809.md` §3's table in
/// one function, with no I/O, no system API and no clock of its own.
///
/// The rung strategies, the order's answer, the failsafe handoff and the ``MonotonicClock`` all
/// arrive as parameters; what is left here is the half worth testing: which rung wins, what the
/// trace says, whether the transcript is held, and how long it all took. The adapters aspect
/// implements the rung seams; this function decides what their answers *mean*.
///
/// ## Isolation
///
/// `@MainActor`, for the same reason ``LadderInjector`` is: the injected ``MonotonicClock`` is not
/// `Sendable`, so the decision and the injector that holds the clock must share one isolation
/// domain — the repo's standing rule for the latency path, where the whole pipeline lives on the
/// main actor. Purity here means no I/O and no system call, not which actor the function runs on.
///
/// ## The decision table
///
/// | Input state | Decision |
/// |---|---|
/// | `target.isSecureInput` | Failsafe at rung 0: `attempted == []`, reason `.secureInput` — the honest refusal, never an attempt into a password field (`ARCHITECTURE.md:382-384`) |
/// | `target.bundleID == nil` | Failsafe at rung 0: `attempted == []`, reason `.noFocusedField` — before any rung (`PRODUCT_SPEC.md:113`) |
/// | Rung succeeds, verified for accessibility | Stop: `rung` is that rung, `attempted` is the prefix trace through it |
/// | Accessibility succeeds *unverified* | Counts as failure — falls through (the silent-lie catch, `ARCHITECTURE.md:400`) |
/// | Rung fails | Record in `attempted`, try the next rung in order |
/// | Rung absent from the strategy map | Treated as failed and skipped — the map is the truth, no implicit recovery (C8's store may demote a rung to absent) |
/// | Every rung exhausted | Failsafe: reason `.exhausted`, `attempted` is the full trace |
///
/// The failsafe outcome routes the transcript to the handoff with the reason, the target
/// application's name and the capture instant read from the injected clock. `elapsed` is
/// accumulated from that clock's deltas, never a wall clock, and a negative delta contributes
/// nothing — the `SessionMachine.tick()` rule.
///
/// ## Why it can throw
///
/// The one thing here that is not a decision is the hand-off's own failure: the journal reports
/// its inability to take custody by throwing, and this function surfaces that throw rather than
/// swallowing it (plan §8). The journal's durable-before-return contract is what makes the branch
/// unreachable in practice; a `LadderInjector` bound to the non-throwing ``TextInjector`` seam is
/// where the residual lands.
///
/// - Parameters:
///   - text: The transcript to insert, carried verbatim to every rung and to the failsafe.
///   - target: Everything the ladder knows about the focused application.
///   - targetAppName: The focused application's name for the failsafe's "{app}" copy; `nil` when
///     the resolver could not determine it (the failsafe window falls back to a name-less
///     phrasing).
///   - orderedRungs: The rungs to attempt, in order — the answer an ``InjectionStrategyOrder``
///     produced for `target`'s bundle identifier.
///   - strategies: The injected strategy set, keyed by rung. A rung not present is a failed rung.
///   - handoff: Where the failsafe outcome routes the transcript.
///   - clock: The only way time enters — deltas between its readings are the ladder's `elapsed`.
/// - Returns: The outcome: which rung delivered, the prefix trace, the read-back truth, and the
///   accumulated ladder time. `.widgetFailsafe` is a successful outcome under I1.
@MainActor
public func decide(
    text: String,
    target: TargetContext,
    targetAppName: String?,
    orderedRungs: [InjectionRung],
    strategies: [InjectionRung: any InjectionRungStrategy],
    handoff: any FailsafeHandoff,
    clock: any MonotonicClock
) async throws -> InjectionResult {
    var attempted: [InjectionRung] = []
    var elapsed: Duration = .zero
    var lastReading = clock.now

    // The two rung-0 refusals. Checked before any rung runs, so `attempted` stays empty and
    // nothing consumes ladder time — and in the table's order, because a password field with no
    // focused application is still a password field.
    if target.isSecureInput {
        return try await failsafe(
            text: text,
            targetAppName: targetAppName,
            reason: .secureInput,
            attempted: attempted,
            elapsed: elapsed,
            capturedAt: lastReading,
            handoff: handoff)
    }
    if target.bundleID == nil {
        return try await failsafe(
            text: text,
            targetAppName: targetAppName,
            reason: .noFocusedField,
            attempted: attempted,
            elapsed: elapsed,
            capturedAt: lastReading,
            handoff: handoff)
    }

    for rung in orderedRungs {
        let attempt: RungAttempt
        if let strategy = strategies[rung] {
            attempt = await strategy.tryInject(text, into: target)
        } else {
            // A rung the injected strategy set does not contain counts as failed. The map is the
            // truth; there is no implicit recovery, and C8's store may demote a rung to absent.
            attempt = .failed
        }

        // One reading per rung turn; a negative delta contributes nothing (SessionMachine.tick()).
        let reading = clock.now
        let delta = reading - lastReading
        lastReading = reading
        if delta > .zero { elapsed += delta }

        switch attempt {
        case .succeeded(let verified):
            if rung == .accessibility && !verified {
                // The silent lie: an accessibility "success" without read-back confirmation counts
                // as failure and falls through (ARCHITECTURE.md:400).
                attempted.append(rung)
                continue
            }
            // Stop: the winning rung, with the prefix trace through it. The raw verification
            // truth travels in the result; interpreting it was this function's, done above.
            return InjectionResult(
                rung: rung, attempted: attempted + [rung], verified: verified, elapsed: elapsed)
        case .failed:
            attempted.append(rung)
            continue
        }
    }

    // Exhaustion: the full trace is C8's strategy-memory input, so it must survive the round trip
    // intact.
    return try await failsafe(
        text: text,
        targetAppName: targetAppName,
        reason: .exhausted,
        attempted: attempted,
        elapsed: elapsed,
        capturedAt: lastReading,
        handoff: handoff)
}

/// The failsafe terminal: route the transcript to the handoff, then report the outcome.
///
/// A successful outcome under I1 — the text reached the floor, so nothing downstream may treat
/// the result as an error. The handoff's own failure is surfaced by the throw.
@MainActor
private func failsafe(
    text: String,
    targetAppName: String?,
    reason: FailsafeReason,
    attempted: [InjectionRung],
    elapsed: Duration,
    capturedAt: Duration,
    handoff: any FailsafeHandoff
) async throws -> InjectionResult {
    try await handoff.hold(
        HeldTranscript(
            text: text, reason: reason, targetAppName: targetAppName, capturedAt: capturedAt))
    return InjectionResult(
        rung: .widgetFailsafe, attempted: attempted, verified: false, elapsed: elapsed)
}
