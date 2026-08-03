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

import XCTest

/// Vocca's headline promise is that audio and text never leave the machine. These two tests are
/// what make that claim auditable rather than marketing, and they are a permanent release
/// blocker: **if one of them ever fails, the product code is wrong, not the test.** Weakening
/// either assertion to restore a green build defeats the entire point of having them.
///
/// The pair is deliberately structured so that neither test can go green vacuously:
///
/// - ``testInterposerDetectsAnOutboundConnection`` is the **positive control**. It drives the
///   probe through a code path that deliberately opens one outbound TCP connection and asserts
///   the interposer saw it. If this fails, the interposer is blind, and the other test's green
///   means nothing.
/// - ``testDefaultConfigurationMakesZeroNetworkConnections`` is the **invariant**. It drives the
///   probe through Vocca's default configuration and asserts nothing was contacted.
///
/// Both run the *same* binary through the *same* instrumentation, differing only in which mode
/// the probe is asked to execute. That shared mechanism is what makes the positive control a
/// meaningful guarantee about the invariant rather than a separate, unrelated experiment.
final class ZeroNetworkTests: XCTestCase {

    // MARK: - Test A: the positive control

    /// Proves the detection mechanism actually works.
    ///
    /// The probe binds a `SOCK_STREAM` listener on `127.0.0.1` port 0 (kernel-assigned) and
    /// connects to it. That is deterministic, needs no DNS, and works offline and in CI — the
    /// test never depends on the internet being reachable.
    ///
    /// Loopback deliberately *counts* as a network connection here. Vocca's default
    /// configuration talks to nothing at all, including `localhost`: the opt-in local LLM
    /// (Ollama) that a user may later enable lives on loopback, and this test exists precisely
    /// to catch it becoming reachable by default.
    func testInterposerDetectsAnOutboundConnection() throws {
        let session = try NetworkInterposer.startObserving()
        let exit = try session.runProbe(mode: .deliberateConnection)
        let observation = try session.stopObserving()

        XCTAssertEqual(exit, 0, "Probe did not run cleanly:\n\(observation.diagnosticSummary)")
        XCTAssertTrue(
            observation.interposerDidLoad,
            """
            The interposer never loaded into the probe process, so it observed nothing and \
            could not have observed anything. Do not read this as "no connections were made".
            \(observation.diagnosticSummary)
            """)
        XCTAssertGreaterThanOrEqual(
            observation.networkConnectionCount, 1,
            """
            The probe deliberately opened one outbound TCP connection to a loopback listener \
            and the interposer did not see it. The interposer is blind, which means \
            testDefaultConfigurationMakesZeroNetworkConnections cannot be trusted either.
            \(observation.diagnosticSummary)
            """)
    }

    // MARK: - Test B: the invariant

    /// Asserts Vocca's default configuration makes zero network calls.
    ///
    /// **This test is only as strong as the path it exercises.** Today the package is a set of
    /// placeholder modules, so the probe's default-configuration path is correspondingly small:
    /// it links every Vocca module and touches each one. As the package grows, that path in
    /// `Sources/VoccaNetworkProbe/main.swift` **must grow with it** — every new piece of
    /// start-up, model-loading, or default-pipeline work belongs there. If it does not, this
    /// assertion quietly becomes vacuous: it will keep passing while asserting nothing about
    /// the code that was actually added.
    func testDefaultConfigurationMakesZeroNetworkConnections() throws {
        let session = try NetworkInterposer.startObserving()
        let exit = try session.runProbe(mode: .defaultConfiguration)
        let observation = try session.stopObserving()

        XCTAssertEqual(exit, 0, "Probe did not run cleanly:\n\(observation.diagnosticSummary)")

        // Checked before the zero-assertions: without it, a failure to instrument would present
        // itself as a perfect score.
        XCTAssertTrue(
            observation.interposerDidLoad,
            """
            The interposer never loaded into the probe process. Zero observed connections here \
            is the absence of evidence, not evidence of absence — treat this as a failure.
            \(observation.diagnosticSummary)
            """)

        XCTAssertEqual(
            observation.networkConnectionCount, 0,
            """
            Vocca's default configuration must make zero network calls. The probe contacted:
            \(observation.networkConnectionDescriptions.joined(separator: "\n"))
            Fix the code. Do not weaken this test.
            \(observation.diagnosticSummary)
            """)

        XCTAssertEqual(
            observation.nameResolutionCount, 0,
            """
            Vocca's default configuration must resolve no hostnames. A DNS lookup leaves the \
            machine even when the connection that follows it never opens. The probe resolved:
            \(observation.nameResolutionDescriptions.joined(separator: "\n"))
            Fix the code. Do not weaken this test.
            \(observation.diagnosticSummary)
            """)
    }
}
