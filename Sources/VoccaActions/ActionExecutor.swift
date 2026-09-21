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

import OSLog
import VoccaCore

/// **The one caller of ``ActionGate`` in the shipped configuration** (`executor` aspect,
/// `action-surface-wiring` C13 slice 5): the actor that submits an invocation and records
/// whatever the gate decided.
///
/// ## Why this actor exists
///
/// ``ActionGate`` cannot write the audit store — `VoccaCore` is Foundation-free and the log is a
/// file — so the round trip R8 demands ("every executed action must appear in the audit log,
/// asserted by reconstruction") needs a caller that does both. This is that caller, and it is the
/// only one: the surface and the probe both go through it, so there is exactly one code path from
/// "submitted through the gate" to "recorded in the store".
///
/// ## The no-dropped-audit-record rule lives here
///
/// A decision the gate returns is recorded **always**, whatever it is — the refusals no less than
/// the runs, because a log that recorded only the actions that happened would be a log that
/// reported a clean history of a machine where most actions were stopped on purpose. And when the
/// store itself refuses to write, that is **surfaced, never thrown**: the gate already decided and
/// the provider may already have acted, so throwing would lose the record *and* fail the turn.
/// The honest shape of a failed record is the returned ``ExecutedDecision/auditRecorded`` being
/// `false` plus a loud log line — a caller that cannot tell will report a clean history of an
/// action that happened, which is the one lie an audit log must not tell.
///
/// ## The approved-sentence obligation
///
/// The sentence a human was shown is the caller's own fact — only the layer that drew the card
/// knows it. The executor accepts it and hands it to the gate verbatim, so an approval granted
/// against one sentence cannot be replayed against another (the N2 binding's caller side): the
/// gate refuses the moment its own freshly-rendered sentence differs. An executor that dropped the
/// sentence would silently narrow the binding to nothing, which is why the parameter is forwarded
/// and never defaulted away.
///
/// ## What it owns, and what it does not
///
/// The provider is injected at construction — the executor is per-provider, because the gate's
/// decision is a function of the specific seam it would reach. The store and the loud-log closure
/// are injected too. The clock is the one thing it owns, and it is the ``MonotonicClock`` contract
/// in its smallest form: a process-local origin and a `Duration` difference, never a wall clock
/// (`FileSystemActionAuditStore` records instants as monotonic `Duration` components, and two
/// entries from different runs are not comparable — ordering within a run is the write ordinal's
/// job).
public actor ActionExecutor<Provider: ActionProvider> {

    /// What a submission came to: the gate's decision, and whether the audit store accepted it.
    ///
    /// `auditRecorded == false` is a **loud fact**, not an error: the decision stands, and the
    /// caller must treat the record as missing rather than assume it happened.
    public struct ExecutedDecision: Sendable, Equatable {
        /// What ``ActionGate`` decided.
        public let decision: ActionDecision

        /// Whether the decision was committed to the audit store. `false` means it was **not**.
        public let auditRecorded: Bool

        public init(decision: ActionDecision, auditRecorded: Bool) {
            self.decision = decision
            self.auditRecorded = auditRecorded
        }
    }

    private let provider: Provider
    private let store: FileSystemActionAuditStore
    private let log: @Sendable (String) -> Void
    private let clock: ExecutorMonotonicClock

    /// - Parameters:
    ///   - provider: The seam this executor submits to. Per-provider by construction: the gate
    ///     decides about a *specific* provider's tool, so an executor that could be pointed at any
    ///     of them would carry the wrong seam into the decision.
    ///   - store: The audit log every decision is recorded into.
    ///   - log: The loud half of the recording-failure policy — the same injectable shape the
    ///     store uses, so "the failure was logged loudly" is asserted rather than hoped.
    ///     Defaults to an OSLog error line, like the store's own.
    public init(
        provider: Provider,
        store: FileSystemActionAuditStore,
        log: @escaping @Sendable (String) -> Void = {
            Logger(subsystem: "dev.vocca.Vocca", category: "action-executor").error("\($0)")
        }
    ) {
        self.provider = provider
        self.store = store
        self.log = log
        self.clock = ExecutorMonotonicClock()
    }

    /// Submits an invocation to the gate, then records whatever the gate decided.
    ///
    /// The parameter list is the gate's, unchanged, with one addition by obligation:
    /// `approvedSentence` is **the exact sentence a human was shown**, forwarded verbatim — the
    /// N2 binding's caller-side contract (see the type documentation).
    ///
    /// - Parameters:
    ///   - invocation: The provider and tool being asked for.
    ///   - enablement: Which tools may act — the gate's answer is a pure function of this.
    ///   - policy: The local floors under the provider's blast-radius claim. Escalate-only.
    ///   - approval: Whether a human said yes to **this** invocation.
    ///   - approvedSentence: The exact sentence the human was shown when they approved, or `nil`
    ///     for no binding. Forwarded to the gate verbatim — never invented, never defaulted.
    ///   - mode: Live or dry-run.
    /// - Returns: The gate's decision and whether the audit store committed it. A recording
    ///   failure is a returned `false`, never a throw.
    public func submit(
        _ invocation: ActionInvocation,
        enablement: ActionEnablement,
        policy: ActionRadiusPolicy,
        approval: ActionApproval,
        approvedSentence: String?,
        mode: ActionGate.Mode
    ) async -> ExecutedDecision {
        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: enablement, policy: policy,
            approval: approval, approvedSentence: approvedSentence, mode: mode)

        do {
            _ = try await store.record(invocation, decision: decision, at: clock.now)
            return ExecutedDecision(decision: decision, auditRecorded: true)
        } catch {
            log(
                "action-executor: could not record the decision for "
                    + "\(invocation.providerID)/\(invocation.toolID) (\(decision)): \(error)")
            return ExecutedDecision(decision: decision, auditRecorded: false)
        }
    }
}

/// The executor's clock — the ``MonotonicClock`` contract in its smallest form, and the
/// `ContinuousStdioClock` shape: `ContinuousClock` is a standard-library type, the origin is
/// captured at construction, and ``now`` is a `Duration` since that process-local origin, never a
/// wall clock.
private struct ExecutorMonotonicClock: MonotonicClock, Sendable {
    private let origin = ContinuousClock.now

    var now: Duration { ContinuousClock.now - origin }
}