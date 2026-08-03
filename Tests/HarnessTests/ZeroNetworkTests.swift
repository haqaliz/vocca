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

/// Raised when the module coverage cross-check cannot be evaluated meaningfully.
private enum ZeroNetworkTestError: Error, CustomStringConvertible {
    case packageRootNotFound(startingFrom: String)
    case noModulesDiscovered(sourcesRoot: String)

    var description: String {
        switch self {
        case .packageRootNotFound(let path):
            return "Could not locate Package.swift by walking up from \(path)"
        case .noModulesDiscovered(let root):
            return
                "No Vocca module directories were found under \(root) — the probe's coverage was not checked against anything"
        }
    }
}

/// Vocca's headline promise is that audio and text never leave the machine. These two tests are
/// what make that claim auditable rather than marketing, and they are a permanent release
/// blocker: **if one of them ever fails, the product code is wrong, not the test.** Weakening
/// either assertion to restore a green build defeats the entire point of having them.
///
/// The pair is deliberately structured so that neither test can go green vacuously:
///
/// - ``testInterposerDetectsAnOutboundConnection`` is the **positive control**. It drives the
///   probe through code paths that deliberately open outbound TCP connections and asserts the
///   interposer saw each one, by name. If this fails, the interposer is blind, and the other
///   test's green means nothing.
/// - ``testDefaultConfigurationMakesZeroNetworkConnections`` is the **invariant**. It drives the
///   probe through Vocca's default configuration and asserts nothing was contacted.
///
/// Both run the *same* binary through the *same* instrumentation, differing only in which mode
/// the probe is asked to execute. That shared mechanism is what makes the positive control a
/// meaningful guarantee about the invariant rather than a separate, unrelated experiment.
final class ZeroNetworkTests: XCTestCase {

    /// Targets under `Sources/` that exist only to support these tests, and are therefore not
    /// expected to appear in the probe's coverage report.
    private static let testOnlyTargets: Set<String> = ["VoccaNetworkProbe"]

    // MARK: - Test A: the positive control

    /// Proves the detection mechanism actually works, for both calls that matter.
    ///
    /// The probe binds a `SOCK_STREAM` listener on `127.0.0.1` port 0 (kernel-assigned) and
    /// connects to it. That is deterministic, needs no DNS, and works offline and in CI — the
    /// test never depends on the internet being reachable.
    ///
    /// It checks `connect(2)` **and** `connectx(2)` separately, and asserts on the name of the
    /// call observed rather than merely on a count. `connectx` is how `URLSession` and
    /// `Network.framework` actually reach the kernel, so it is the hook that carries almost all
    /// real-world egress; asserting only a non-zero count would let that hook be deleted with the
    /// suite still green, which is exactly the blindness this test exists to rule out.
    ///
    /// Loopback deliberately *counts* as a network connection here. Vocca's default configuration
    /// talks to nothing at all, including `localhost`: the opt-in local LLM (Ollama) that a user
    /// may later enable lives on loopback, and this test exists partly to catch it becoming
    /// reachable by default.
    func testInterposerDetectsAnOutboundConnection() throws {
        for (mode, expectedCall) in [
            (ProbeMode.deliberateConnection, "connect"),
            (ProbeMode.deliberateConnectx, "connectx"),
        ] {
            let observation = try runProbe(mode: mode)

            XCTAssertGreaterThanOrEqual(
                observation.networkConnectionCount, 1,
                """
                The probe deliberately opened one outbound TCP connection to a loopback listener \
                in mode '\(mode.rawValue)' and the interposer did not see it. The interposer is \
                blind, which means testDefaultConfigurationMakesZeroNetworkConnections cannot be \
                trusted either.
                \(observation.diagnosticSummary)
                """)

            XCTAssertTrue(
                observation.networkConnections.contains { $0.call == expectedCall },
                """
                The connection in mode '\(mode.rawValue)' was expected to be observed via \
                '\(expectedCall)', and was not. The interposer is missing that hook, so every \
                caller that uses it goes unseen — and for connectx that means URLSession and all \
                of Network.framework.
                \(observation.diagnosticSummary)
                """)
        }
    }

    // MARK: - Test B: the invariant

    /// Asserts Vocca's default configuration makes zero network calls.
    ///
    /// **This test is only as strong as the path it exercises**, which is the body of
    /// `VoccaNetworkProbe.exerciseDefaultConfiguration()`. Two mechanisms defend that from
    /// quietly decaying, and neither replaces reading the function itself:
    ///
    /// - The probe holds the process open for a settle window after the path returns, so
    ///   asynchronous work — which is nearly everything Vocca will do — gets to reach the network
    ///   before the observation ends.
    /// - The module cross-check below fails the suite when a new `Sources/Vocca*` module is added
    ///   without being driven from that function.
    ///
    /// What neither can check is whether an *existing* module's new work is exercised. When a
    /// capability lands, extending that function is still a judgement call.
    func testDefaultConfigurationMakesZeroNetworkConnections() throws {
        let observation = try runProbe(mode: .defaultConfiguration)

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

        // The coverage cross-check. Without it the assertions above stay green while covering an
        // ever-smaller fraction of the product, which is the most likely way this gate rots.
        let onDisk = try voccaModuleDirectories()
        let exercised = observation.reportedModules
        XCTAssertEqual(
            exercised, onDisk,
            """
            The probe's default-configuration path does not cover every Vocca module.
              never driven by the probe: \(onDisk.subtracting(exercised).sorted())
              reported but not on disk:  \(exercised.subtracting(onDisk).sorted())
            A module the probe never reaches is a module the zero-network invariant says nothing \
            about. Drive it from VoccaNetworkProbe.exerciseDefaultConfiguration() — including its \
            default-configuration start-up work, not just a reference to one of its types.
            \(observation.diagnosticSummary)
            """)
    }

    // MARK: - Shared plumbing

    /// Runs one probe mode under the interposer and returns what was observed, having already
    /// asserted the three things that must hold before any observation can be believed: the probe
    /// ran, it ran to completion, and something was watching while it did.
    private func runProbe(
        mode: ProbeMode, file: StaticString = #filePath, line: UInt = #line
    ) throws -> NetworkObservation {
        let session = try NetworkInterposer.startObserving()
        let exitStatus = try session.runProbe(mode: mode)
        let observation = try session.stopObserving()

        XCTAssertEqual(
            exitStatus, 0, "Probe did not run cleanly:\n\(observation.diagnosticSummary)",
            file: file, line: line)

        // Checked before any zero-assertion: a failure to instrument would otherwise present
        // itself as a perfect score.
        XCTAssertTrue(
            observation.interposerDidLoad,
            """
            The interposer never loaded into the probe process, so it observed nothing and could \
            not have observed anything. Zero observed connections here is the absence of \
            evidence, not evidence of absence.
            \(observation.diagnosticSummary)
            """,
            file: file, line: line)

        XCTAssertTrue(
            observation.probeCompleted(mode: mode),
            """
            The probe never reported completing mode '\(mode.rawValue)'. Whatever it did, it was \
            not the work this test believes it was observing.
            \(observation.diagnosticSummary)
            """,
            file: file, line: line)

        return observation
    }

    /// Every `Sources/Vocca*` directory, excluding targets that exist only to support these
    /// tests. Mirrors the discovery `ModuleBoundaryTests` does, and fails loudly rather than
    /// vacuously if the scan finds nothing.
    private func voccaModuleDirectories() throws -> Set<String> {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.pathComponents.count > 1,
            !FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("Package.swift").path)
        {
            dir = dir.deletingLastPathComponent()
        }
        guard dir.pathComponents.count > 1 else {
            throw ZeroNetworkTestError.packageRootNotFound(startingFrom: #filePath)
        }

        let sourcesRoot = dir.appendingPathComponent("Sources")
        let entries = try FileManager.default.contentsOfDirectory(
            at: sourcesRoot, includingPropertiesForKeys: [.isDirectoryKey])
        var modules: Set<String> = []
        for entry in entries {
            let isDirectory =
                (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let name = entry.lastPathComponent
            guard isDirectory, name.hasPrefix("Vocca"), !Self.testOnlyTargets.contains(name) else {
                continue
            }
            modules.insert(name)
        }

        guard !modules.isEmpty else {
            throw ZeroNetworkTestError.noModulesDiscovered(sourcesRoot: sourcesRoot.path)
        }
        return modules
    }
}
