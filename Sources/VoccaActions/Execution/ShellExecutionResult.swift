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

import Foundation

/// What came of a shell run — the value ``ShellExecutor`` returns for one invocation.
///
/// ## Failure is a value, never a throw
///
/// The engine feeds the ``ActionProvider`` seam, whose `invoke` is `async` and deliberately
/// **not** `async throws` (`ActionProvider.swift:52-57`): an outcome that must be returned is an
/// outcome that cannot be dropped by omitting a `catch`, and the audit record must be written
/// either way. So the engine's failures are this type's `.failed` case, with a **bounded
/// reason key** — never a message — for the same reason ``ActionOutcome/failed(reasonKey:)``
/// gives: the provider maps the key straight into an ``ActionOutcome``, and a free-form error
/// string would carry unbounded bytes the audit seam must not persist.
///
/// ## Why not `ActionOutcome` itself
///
/// ``ActionOutcome/succeeded`` carries no payload, and the acceptance reads the exit code back
/// off a successful run. The engine needs a channel for the code and for the captured output,
/// so it returns this type and the provider folds it into ``ActionOutcome`` — success with
/// exit 0, and every `.failed` key carried across unchanged. The fold lives with the provider,
/// not here: naming ``ActionOutcome`` from this file would trip the action-family seam lint,
/// and the provider is the file that already owes its Family-A rows.
public struct ShellExecutionResult: Sendable, Equatable {

    /// The run's outcome. ``succeeded`` carries the exit code so the caller can read it back;
    /// ``failed`` carries one of the bounded reason keys below.
    public enum Status: Sendable, Equatable {
        /// The child exited with status 0.
        case succeeded(exitCode: Int32)
        /// The run failed — by exit code, by timeout, by signal, or at launch. The key is
        /// bounded; the audit entry it feeds may not be.
        case failed(reasonKey: String)
    }

    /// The outcome status.
    public let status: Status

    /// The child's stdout, **bounded** by ``ShellExecutor/Configuration/maximumOutputBytes``.
    /// Overflow is truncated, never fatal — what is retained is the head of the stream.
    public let standardOutput: Data

    /// The child's stderr, bounded by the same cap.
    public let standardError: Data

    /// Whether either stream was truncated at the bound.
    ///
    /// A cap that is claimed rather than measured is not a cap, and this flag is the measurement:
    /// a caller that needs to know the output was cut has the fact in hand, rather than having to
    /// compare byte counts against a bound it is not supposed to know.
    public let outputWasTruncated: Bool

    public init(
        status: Status,
        standardOutput: Data,
        standardError: Data,
        outputWasTruncated: Bool
    ) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.outputWasTruncated = outputWasTruncated
    }

    // MARK: - The bounded reason keys

    /// The closed set of failure keys this engine may produce.
    ///
    /// Each key is spelled for ``ActionOutcome/failed(reasonKey:)`` and the provider folds them
    /// into ``ActionOutcome`` **unchanged** — never translated, abbreviated or re-spelled — so
    /// this list is exactly the vocabulary the audit seam can ever see from a shell run. Pinned
    /// by test so a new key is a reviewed addition here, not a stray literal the provider never
    /// mapped.
    public static let boundedFailureKeys: [String] = [
        exitCodeReasonKey,
        timedOutReasonKey,
        signalReasonKey,
        launchFailedReasonKey,
    ]

    /// The child exited with a non-zero status.
    ///
    /// `"shell.exitCode"` — the dotted, namespaced shape the audit seam expects, and the key the
    /// provider folds into ``ActionOutcome/failed(reasonKey:)`` unchanged.
    public static let exitCodeReasonKey = "shell.exitCode"

    /// The child reached the injected-clock ceiling and was terminated.
    public static let timedOutReasonKey = "shell.timedOut"

    /// The child was terminated by an uncaught signal.
    public static let signalReasonKey = "shell.signal"

    /// The child could not be launched at all.
    public static let launchFailedReasonKey = "shell.launchFailed"
}