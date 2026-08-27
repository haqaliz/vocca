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

/// **The seam for the AX rung's insert+read-back calls** — the raw questions the rung needs
/// answered, taken out of it so the rung is headless-testable (`plan_20260809.md` §2 Phase C).
///
/// Three raw questions, three raw answers, nothing more:
///
/// - is there a focused element to type into at all? (``resolveFocusedElement()``)
/// - did the system accept the write? (``insertSelectedText(_:)``)
/// - what does the field hold now? (``readBackValue()``)
///
/// Comparing the read-back to the text is the rung's, and is what `verified` means; deciding
/// that "unverified" is failure is the decision's, and is already pinned in the seam aspect.
/// Interpreting a `false` — timeout, no permission, no focus — is nobody's here.
///
/// `async`, because the seam crosses into the rung actor: the rung's calls must be awaited, and
/// the fakes that record them must be honest actors crossing that boundary — `@unchecked
/// Sendable` on a counter would be measuring Sendability with the very race the seam exists to
/// avoid (`ASRTestDoubles.swift:36-38`). Class-bound (`AnyObject`) for the reason every other
/// state-read seam in this repo is: a value conformance would be copied into the rung at
/// construction, and a state read copied is a snapshot.
public protocol AccessibilityInserting: AnyObject, Sendable {
    /// Whether a focused UI element could be resolved at all — the first raw answer, asked
    /// before anything is written. `false` when nothing is focused or the system refused the
    /// query.
    func resolveFocusedElement() async -> Bool

    /// Insert `text` into the focused field. Raw: `true` when the system accepted the write,
    /// `false` otherwise.
    func insertSelectedText(_ text: String) async -> Bool

    /// What the focused field contains now, raw; `nil` when it cannot be read.
    func readBackValue() async -> String?
}

/// **The accessibility rung of the injection ladder — allowlist-gated, read-back verified, raw.**
///
/// The `accessibility` rung is the only one that reads back and verifies (`ARCHITECTURE.md:399`)
/// — and the only one that types *through* the focused application rather than past it, which is
/// why it is gated in two places, both enforced here and in the order:
///
/// - ``DefaultInjectionStrategyOrder`` never *proposes* accessibility for an unallowlisted
///   application;
/// - this rung *declines* it even when consulted directly — the C12 shape, "not read-then-
///   discard, but never read": for an unallowlisted bundle ID not one AX call is made, so no
///   order implementation, present or future, can hand an unallowlisted application to a live
///   AX read.
///
/// When the rung *does* act, it answers with raw truth: resolve → insert → read-back, and
/// `succeeded(verified:)` where `verified` is exactly "the read-back confirmed the text". A
/// timeout, a refusal, a read-back that differs — all surface as a `false` or `.failed`; the
/// *interpretation* ("an unverified accessibility success is a failure", `ARCHITECTURE.md:400`)
/// is the decision function's, already pinned there, and this conformance must not pre-decide
/// it.
///
/// ## Isolation
///
/// An **actor** — the one isolation choice that keeps AX calls off the main thread
/// (`ARCHITECTURE.md:323`). The ladder's decision and injector are `@MainActor` and `await`
/// every rung across a suspension point, so a value-typed rung would run its AX calls on the
/// main actor; an actor rung is hopped to, and its calls land on its own executor instead. The
/// seam's three answers are awaited there, one after another, and the raw AX calls themselves
/// run on ``AXSource``'s dedicated queue, with its per-call timeout.
public actor AccessibilityRungStrategy: InjectionRungStrategy {
    /// This strategy implements the accessibility rung.
    public nonisolated var rung: InjectionRung { .accessibility }

    // Internal rather than private: the composition factory must hand this rung and the ladder's
    // order the *same* gate, and that is only assertable if it can be read back
    // (`ShippingLadderMemoryWiringTests`). `nonisolated` because it is an immutable `Sendable`
    // handle — reading it costs no hop and can answer no question about the rung's own state.
    nonisolated let allowlist: any InjectionAllowlist
    private let insert: any AccessibilityInserting

    /// - Parameters:
    ///   - allowlist: The gate the rung enforces itself, before any AX call — the same list the
    ///     order consults, so the rung stays safe even against a wrongly-ordered ladder.
    ///   - insert: The insert+read-back seam. ``AXSource`` is the shipped conformance; tests
    ///     inject a recording fake.
    public init(allowlist: any InjectionAllowlist, insert: any AccessibilityInserting) {
        self.allowlist = allowlist
        self.insert = insert
    }

    public func tryInject(_ text: String, into target: TargetContext) async -> RungAttempt {
        // The gate, in its never-read shape: an unallowlisted application — or no application —
        // is declined before a single AX call. There is no read-then-discard path here.
        guard let bundleID = target.bundleID, allowlist.contains(bundleID: bundleID) else {
            return .failed
        }

        // The three raw answers, in order. Each `false` means "the system did not confirm", and
        // that is all it means: the decision interprets the refusal.
        guard await insert.resolveFocusedElement() else { return .failed }
        guard await insert.insertSelectedText(text) else { return .failed }
        let readBack = await insert.readBackValue()

        // The verification truth, raw: the read-back either confirmed the text or it did not.
        return .succeeded(verified: readBack == text)
    }
}
