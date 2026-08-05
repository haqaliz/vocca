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

/// Runs `work` on a later turn of the run loop the tap is attached to.
///
/// The one system call ``CallbackSafeTapDisablement`` needs and the one thing it must not perform
/// itself: a run loop is exactly the sort of thing this module keeps below the seam, and a test that
/// had to wait for a real one would be measuring a scheduler rather than a decision. Injected, so a
/// test supplies a queue it drains by hand and sees the two halves of a disablement land in order.
///
/// The shipped implementation is ``CGEventTapSource/deferralToALaterMainRunLoopTurn``, which is in
/// the adapter's file because `CFRunLoopPerformBlock` is a seam type and only that file may name one.
///
/// **An implementation must not run `work` before it returns.** One that did would be an identity
/// function wearing a scheduler's name, and would put back the exact hazard the split removes — a
/// `CFMachPort` invalidated inside its own callback — with every test in
/// `CallbackSafeTapDisablementTests` still green, because they drive the deferral by hand.
public typealias RunLoopDeferral = (@escaping () -> Void) -> Void

/// What the tap tells when the operating system switches it off underneath it.
///
/// **The adapter's entire knowledge of what a disablement means**: that somebody should be told, and
/// which of the two reasons it was. Not what to do about it, not whether to recover, and above all
/// not *when* — which is the decision this file exists for, and which sits here where a test can run
/// it rather than in the callback where nothing can.
///
/// One method, returning nothing. There is nothing for the adapter to do with an answer: a
/// ``TapHealth`` describes where the tap stands, and the tap's own callback is the one place in this
/// package with no use for that — it has an event to dispose of and no way to act on a tap that is,
/// by construction, already off.
public protocol TapDisablementObserver: AnyObject {
    /// The operating system disabled the tap, and the tap's callback is still on the stack.
    ///
    /// Called from inside a synchronous C function that must return a disposition, so an
    /// implementation owes the caller a prompt return — and owes the *user* a closed microphone
    /// before it takes one.
    func tapWasDisabledOnTheCallback(_ reason: TapDisableReason)
}

/// **Decision A: a disablement, split across a run-loop turn.**
///
/// `kCGEventTapDisabledByTimeout` and `…ByUserInput` are delivered *to the tap's callback*, so
/// ``TapHealthPolicy/tapWasDisabled(_:)`` — which ends the session, re-enables, and on the failing
/// path tears the tap down and builds a new one — would otherwise run with the callback on the
/// stack. Its last step calls ``HotkeyEventSource/stop()``, which invalidates the `CFMachPort` this
/// callback belongs to and removes the run-loop source currently dispatching it. That is the hazard,
/// and it is not a style objection: it is a use-after-free reached by a caller doing exactly what
/// the policy documents.
///
/// ## What was decided, and what was decided against
///
/// **The ending happens now; the recovery happens later.** Two lines, and each is a choice:
///
/// 1. **The microphone closes on the callback**, synchronously, before this method returns. Deferring
///    it too would have been simpler and is wrong: the session is stranded from the instant the tap
///    goes off — the key-up that would have ended it is never coming — and the entire justification
///    for ``TapHealthPolicy``'s *end first, unconditionally* rule is immediacy. A run-loop turn is
///    usually microseconds and is not bounded by anything; the one state where it is *not* quick is
///    a busy main thread, which is precisely the state a `.timeout` disablement reports. Deferring
///    the ending would therefore have been slowest exactly when it mattered most.
/// 2. **The recovery is deferred, whole.** Not just the teardown: telling the two apart would mean
///    predicting inside the callback whether `resumeDelivery()` is going to take, which is a decision
///    made from a guess, and the cheap half is worth nothing on its own — a tap that re-enables one
///    turn later than it might have is a tap that was off for one turn.
///
/// **Constraint 7 is still violated by (1), and knowingly.** *"Do nothing in the tap callback"*
/// exists because a slow callback earns `kCGEventTapDisabledByTimeout`, and closing an
/// `AVAudioEngine` is not nothing. What makes it acceptable *here* and nowhere else is that on this
/// route the tap is **already disabled**: it delivers nothing until something enables it again, so no
/// work done on this callback can earn a second timeout. The same reasoning does not transfer to the
/// key-down path — see ``HotkeyEventSink/receive(_:)``, where the tap is live and the engine start is
/// still an open question.
///
/// ## What the deferral does not promise
///
/// **That it runs at all.** A main thread that never returns to its run loop never performs the
/// block, and the tap stays dead — which is a real state and is already covered: the ~1 s health poll
/// exists for a tap that dies with nobody told, and this is that, with one extra reason. What is
/// *not* left open is the microphone. The ending is the half that does not depend on the run loop,
/// which is the other half of why it is the half that is not deferred.
///
/// **That it runs only once, or in any particular order against other entry points.** A second
/// disablement cannot arrive before the first block runs — a disabled tap delivers nothing, including
/// disablements — but a wake or a grant notification can, and each of those ends the session itself
/// and re-creates. The deferred ``TapHealthPolicy/tapWasDisabled(_:)`` landing after one of them is
/// harmless for the reason the policy's rule is unconditional: it ends a session that is already
/// ended, and re-enables a tap that is already delivering.
///
/// ## Isolation
///
/// Not `Sendable`, and it cannot be — it holds a ``TapHealthPolicy``, which holds the sink, the
/// watchdog and the machine, all deliberately non-`Sendable` because a tap callback is a synchronous
/// C function that cannot `await`. It lives in the same single isolation domain as everything else
/// here, and the deferral must schedule onto that domain rather than onto any thread that happens to
/// be free.
public final class CallbackSafeTapDisablement: TapDisablementObserver {
    private let policy: TapHealthPolicy
    private let deferRecovery: RunLoopDeferral

    /// - Parameters:
    ///   - policy: every decision about a dying tap. Held strongly, which is why the adapter holds
    ///     *this* object weakly — the policy holds the source, so a strong edge back would close a
    ///     cycle around the one object whose teardown frees a `CFMachPort`.
    ///   - deferRecovery: how to reach a later turn of the tap's run loop. See ``RunLoopDeferral``
    ///     for the one thing an implementation must not do.
    public init(policy: TapHealthPolicy, deferRecovery: @escaping RunLoopDeferral) {
        self.policy = policy
        self.deferRecovery = deferRecovery
    }

    public func tapWasDisabledOnTheCallback(_ reason: TapDisableReason) {
        // Now, on the callback, because a stranded session has no other way out and a run-loop turn
        // is not a bound on anything.
        policy.endAnyInFlightSessionWithoutRecovering()

        // Later, off the callback, because the recovery ends in a teardown of the port this callback
        // belongs to. `policy` is captured strongly on purpose: the block must be able to run even
        // if the owner has released this observer in the meantime, or a disarm racing a disablement
        // would leave a tap that nothing ever re-enables.
        //
        // The return value is discarded, and this is the one caller for which that is right: there
        // is nobody left to tell. The entry point that produced it returned a turn ago, to a C
        // function that had an event to dispose of and no use for a TapHealth. The diagnosis is not
        // lost with it — `tapWasDisabled` sends `.disabled(reason)` and every recovery note down the
        // policy's own note channel, which is where an owner reads about this anyway.
        deferRecovery { [policy] in
            _ = policy.tapWasDisabled(reason)
        }
    }
}
