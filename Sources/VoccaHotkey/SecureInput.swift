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

import Carbon.HIToolbox

/// **Whether some application has switched the keyboard off for everybody.**
///
/// Secure Input — `EnableSecureEventInput`, in `CarbonEventsCore.h` — is how a password field asks
/// the window server to stop delivering key events to event taps. **Any** application can turn it
/// on: the login window, a password field in Safari or Chrome, 1Password, Terminal with *Secure
/// Keyboard Entry* ticked. While it is on, a tap that was created correctly, is enabled, and reports
/// itself enabled receives **no key events at all**.
///
/// That is the failure this seam exists for, and its shape is what makes it worth a system call of
/// its own: it looks exactly like a Vocca bug, and it happens in the contexts a user is most likely
/// to try the hotkey in first. Without this read the only honest thing Vocca could say is *"the tap
/// is fine"*, while the hotkey does nothing.
///
/// ## What a conformance owes, and what it must not do
///
/// Answer the question **now**, from the system, every time. This is a state that changes under
/// Vocca's feet with no notification — there is no Secure Input equivalent of
/// `kCGEventTapDisabledByUserInput` — which is why the ~1 s poll is what reads it and why a cached
/// answer would be a report of the world as it was when some other app last happened to tell us
/// something.
///
/// **It must not decide anything.** What the answer *means* — that this is not a tap failure, that
/// there is nothing to recover, and that a session in flight can no longer be ended by a key
/// event — is ``TapHealthPolicy``'s, above the seam, where it is tested. This protocol carries one
/// `Bool` across that line.
///
/// ## Class-bound, for the reason every other seam here is
///
/// A value-typed conformance would be copied into the policy at construction, and a *state read*
/// copied is a snapshot: the fake would answer the same thing forever, and so a test could not
/// express the one behaviour that matters here — Secure Input coming on, and going off again.
public protocol SecureInputStateReader: AnyObject {
    /// `true` when some application is holding Secure Input and no event tap is receiving key
    /// events.
    ///
    /// Not *"Vocca's tap is broken"* and not *"permission is missing"*. Both of those have their own
    /// answers, and reporting this as either is the confusion `TapHealth.blockedBySecureInput` was
    /// added to prevent.
    var isSecureInputActive: Bool { get }
}

/// **The shipped read: one Carbon call, and nothing else.**
///
/// `IsSecureEventInputEnabled()` returns whether *any* process in this login session currently holds
/// Secure Input. It needs no entitlement, no Accessibility grant and no tap — which is what makes it
/// the one instance of "enabled and deaf" that has an API at all
/// (``TapHealthPolicy/pollTapHealth()`` records the other, and it has none).
///
/// ## Why this is not in `CGEventTapSource.swift`
///
/// Because nothing forces it to be, and the alternative costs something. H7's lint permits exactly
/// one file to name a CoreGraphics event type, which is why phase 5's physical-key reader had to
/// share the tap's file; `IsSecureEventInputEnabled` is Carbon, matches no seam prefix, and is under
/// no such constraint. Keeping it here keeps the tap adapter's file to the thing it is —
/// `tapCreate`, a `CFMachPort` and a C callback, none of which this call has anything to do with.
///
/// ## It is executed by nothing in CI, and the reason is not the usual one
///
/// Unlike `tapCreate`, this call *works* without a grant — it was run under
/// `swiftc -swift-version 6` while this was written and answered `false`. What cannot be written is
/// a **test worth having**: the value is a fact about every other application on the machine, so an
/// assertion that it is `false` fails on a developer who happens to have a password field focused,
/// and an assertion that it is *a `Bool`* asserts nothing the compiler did not. The state is set by
/// software this process cannot drive, so there is no way to make it `true` on purpose from a test.
///
/// So the decision that reads it is tested exhaustively over ``SecureInputStateReader``, and the
/// call itself is confirmed by a human — `docs/SMOKE_CHECKLIST.md`, the Secure Input step, which
/// exists because this line is otherwise the only unwatched part of the mechanism.
///
/// ## Isolation
///
/// Asserts the main actor, for the reason ``SystemPhysicalKeyState`` does: it is read from the
/// ~1 s health poll, which is a `Timer` on the main run loop, and the policy that reads it is
/// non-`Sendable` and lives in that one domain. The object holds no state, so the assertion is about
/// where its *callers* are rather than about a race inside it.
public final class SystemSecureInputState: SecureInputStateReader {

    public init() {}

    public var isSecureInputActive: Bool {
        MainActor.preconditionIsolated(
            """
            A SystemSecureInputState was read off the main actor. It is read by the tap-health \
            poll, which is a Timer on the main run loop, and the policy it answers is deliberately \
            non-Sendable and lives in that one domain.
            """)
        return IsSecureEventInputEnabled()
    }
}
