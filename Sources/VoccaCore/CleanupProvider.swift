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

/// The pluggable text-cleanup boundary (`ARCHITECTURE.md:273-277`).
///
/// Every cleanup adapter is this protocol and nothing else: the deterministic rules engine
/// (`RulesCleanup`), Ollama and BYOK behind the same seam, the hosted tier later
/// (`ARCHITECTURE.md:251` — "Cleanup | `CleanupProvider` | ... | **Yes**" for the hosted column).
/// Raw ASR text goes in with a ``CleanupContext`` describing the session; polished text comes
/// back.
///
/// ## The seam's contract
///
/// - **A provider always names itself.** ``identity`` is non-optional — the I1 attribution
///   discipline ``Transcript`` documents for engines (`Transcript.swift:16-21`) applies here too:
///   a cleaned string with no provider attached could be mis-attributed in a log, and which
///   provider cleaned what is exactly the data the cleanup latency span records.
/// - **`requiresNetwork` is the egress hook, defaulting to `false`.** A provider that sends text
///   off the device declares `true`, and the UI badges the point of use (`ARCHITECTURE.md:275`).
///   The default-config zero-network claim is enforced by this default, not by convention — the
///   `rules-engine` provider stays silent on it and is offline by construction.
/// - **The throwing shape is deliberate.** ``clean(_:context:)`` throws where ``TextInjector``
///   deliberately does not (`TextInjector.swift:18-23`): injection exhaustion is not an error —
///   it is the failsafe handing the text back — but a cleanup that times out or fails *is* a
///   first-class outcome, and the caller routes it to raw (`ARCHITECTURE.md:234` —
///   `cleanupTimedOut` "⇒ raw text, never a loss"). The seam must say so, or a provider failure
///   looks like an empty transcript.
/// - **The context is the caller's, not the provider's.** ``CleanupContext`` is built by the
///   caller (its ``CleanupContext/budget`` is caller-enforced — `ARCHITECTURE.md:224`); a
///   conformer reads it and must not reinterpret it.
///
/// The first conformer is the rules engine (`RulesCleanup`), with the adapters aspect's
/// vocabulary: the core owns the contract; the adapters own the system calls.
public protocol CleanupProvider: Sendable {
    /// Which provider this is: the attribution every cleaned string carries and the log's key.
    var identity: ProviderIdentity { get }

    /// Whether cleaning sends text off the device. `false` by default (see the extension); a
    /// conformer that needs the network declares `true` and earns the egress badge.
    var requiresNetwork: Bool { get }

    /// The deadline the caller enforces on one ``clean(_:context:)`` call, in the caller's clock
    /// (`ARCHITECTURE.md:515`). The provider declares how long it may take; the pipeline races it
    /// and routes a slow provider to raw. Defaults to `.milliseconds(10)` (see the extension); a
    /// conformer that needs seconds — an LLM round-trip — declares them here. The provider reads
    /// ``CleanupContext/budget`` as information only; enforcement lives with the caller, never
    /// here.
    var budget: Duration { get }

    /// Cleans one transcript into the text to inject.
    ///
    /// Reads ``Transcript/text`` and returns the polished text, or throws when the cleanup cannot
    /// be completed — the caller routes a throw to the raw text rather than losing it. A conformer
    /// should honour ``CleanupContext/budget``, but the caller owns the deadline.
    func clean(_ transcript: Transcript, context: CleanupContext) async throws -> String
}

extension CleanupProvider {
    /// The zero-network default (`ARCHITECTURE.md:275`): a provider that does not declare
    /// ``requiresNetwork`` is offline by construction, and the default configuration makes zero
    /// network calls. The first conformer (the rules engine) stays silent here on purpose.
    public var requiresNetwork: Bool { false }

    /// The shipped cleanup budget default (`ARCHITECTURE.md:515`): a provider that declares
    /// nothing is raced at 10 ms — the C5 number, pinned so a conformer that says nothing costs
    /// the rules budget. A conformer that needs more declares it.
    public var budget: Duration { .milliseconds(10) }
}
