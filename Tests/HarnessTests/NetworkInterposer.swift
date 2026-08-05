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

/// Test-side driver for the `dyld` interposition shim in `Sources/CVoccaNetworkInterposer`.
///
/// **How this works, and why it is shaped this way.**
///
/// The shim interposes libSystem's outbound-networking entry points — `connect`, `connectx`,
/// `sendto`, `sendmsg`, `getaddrinfo`, `getnameinfo`, `gethostbyname`, `socket` — so it sits
/// below every networking abstraction on the system and sees URLSession, Network.framework and
/// raw BSD sockets alike. Interposition is delivered with `DYLD_INSERT_LIBRARIES`.
///
/// That delivery mechanism cannot be pointed at the test process itself. The `xctest` host
/// SwiftPM runs the suite under is Apple-signed with the hardened runtime, which strips
/// `DYLD_INSERT_LIBRARIES` before `main()` — verified, not assumed. Interposition tuples in an
/// image that is itself `dlopen`ed (as an `.xctest` bundle is) are likewise ignored by `dyld`,
/// so linking the shim into the test bundle does nothing either. The code under observation
/// therefore runs in a child process we launch ourselves: `VoccaNetworkProbe`, an ad-hoc-signed
/// SwiftPM executable with no hardened runtime, where insertion works.
///
/// Consequences worth stating plainly, because they bound what the tests prove:
///
/// - This is a **CI gate, not a runtime guard**. The shipped, signed, hardened app bundle cannot
///   be instrumented this way and is not instrumented by it.
/// - The guarantee covers **only the code the probe actually runs**. See
///   `VoccaNetworkProbe.exerciseDefaultConfiguration()`.
/// - Egress performed on Vocca's behalf by a *different* process — an XPC call into a system
///   daemon, or exec'ing an Apple-signed helper, which does not inherit the insertion — is
///   invisible here. So is a hand-rolled `syscall()` that skips the libSystem stubs entirely,
///   though such a call would still have to create a socket, which is recorded.
enum NetworkInterposer {

    /// Begins a fresh observation window. Each session gets its own log file, so concurrent or
    /// repeated runs cannot read each other's events.
    static func startObserving() throws -> Session {
        let artifacts = try BuildArtifacts.locate()
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-network-interposer-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else {
            throw NetworkInterposerError.couldNotCreateLog(logURL.path)
        }
        return Session(artifacts: artifacts, logURL: logURL)
    }

    /// One observation window: start it, run the probe under it, then stop it and read what was
    /// seen. A session is single-use and confined to the test method that created it.
    final class Session {
        /// How long the probe should wait for deferred egress after its work returns.
        ///
        /// The probe's own default (0.75s) is tuned for fast local iteration. On CI it is raised
        /// by nearly an order of magnitude, because the two costs are wildly asymmetric: a few
        /// extra seconds of wall clock against a real outbound connection slipping through
        /// unnoticed. A loaded CI machine can easily push work that lands at 0.3s locally out
        /// past a sub-second window, and that failure is a silent green.
        ///
        /// This does not make the window a guarantee — deferred egress past *any* window is still
        /// missed, and slow work must be awaited explicitly by whatever starts it. It moves the
        /// boundary to where scheduling jitter is very unlikely to reach it.
        static let settleWindow: TimeInterval = isContinuousIntegration ? 6.0 : 0.75

        private static var isContinuousIntegration: Bool {
            let environment = ProcessInfo.processInfo.environment
            return environment["CI"] != nil || environment["GITHUB_ACTIONS"] != nil
                || environment["CONTINUOUS_INTEGRATION"] != nil
        }

        private let artifacts: BuildArtifacts
        private let logURL: URL

        // Captured from the probe run so a failure message can show what the child printed.
        private var probeStandardOutput = ""
        private var probeStandardError = ""

        fileprivate init(artifacts: BuildArtifacts, logURL: URL) {
            self.artifacts = artifacts
            self.logURL = logURL
        }

        /// Launches the probe with the shim inserted and waits for it. Returns the probe's exit
        /// status; the caller asserts on it, because a probe that failed to run is a probe whose
        /// silence means nothing.
        @discardableResult
        func runProbe(mode: ProbeMode, timeout: TimeInterval = 60) throws -> Int32 {
            let process = Process()
            process.executableURL = artifacts.probe
            process.arguments = [mode.rawValue]

            var environment = ProcessInfo.processInfo.environment
            environment["DYLD_INSERT_LIBRARIES"] = artifacts.shim.path
            environment["VOCCA_NETWORK_INTERPOSER_LOG"] = logURL.path
            environment["VOCCA_PROBE_SETTLE_SECONDS"] = String(Self.settleWindow)
            process.environment = environment

            let output = Pipe()
            let errorOutput = Pipe()
            process.standardOutput = output
            process.standardError = errorOutput

            try process.run()

            // Polled rather than run through `terminationHandler` so that no mutable state has
            // to cross a `@Sendable` boundary — this stays clean under Swift 6 strict
            // concurrency without an `nonisolated(unsafe)` escape hatch.
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                usleep(5_000)
            }
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
                throw NetworkInterposerError.probeTimedOut(mode: mode, seconds: timeout)
            }
            process.waitUntilExit()

            probeStandardOutput = String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            probeStandardError = String(
                decoding: errorOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return process.terminationStatus
        }

        /// Ends the window and returns everything the shim recorded.
        func stopObserving() throws -> NetworkObservation {
            let contents = try String(contentsOf: logURL, encoding: .utf8)
            try? FileManager.default.removeItem(at: logURL)
            return NetworkObservation(
                rawLog: contents,
                probeStandardOutput: probeStandardOutput,
                probeStandardError: probeStandardError)
        }
    }
}

// MARK: - Probe modes

/// The paths `VoccaNetworkProbe` knows how to execute. The raw values are the probe's argv[1].
enum ProbeMode: String {
    /// Everything Vocca does by default. The invariant asserts this observes nothing.
    case defaultConfiguration = "default-configuration"
    /// One deliberate loopback TCP connection via `connect(2)`.
    case deliberateConnection = "deliberate-connection"
    /// The same connection via `connectx(2)` — the call `URLSession` and `Network.framework`
    /// actually use, and therefore the hook whose coverage matters most.
    case deliberateConnectx = "deliberate-connectx"
}

// MARK: - Observations

/// A single call the shim intercepted.
struct ObservedNetworkEvent {
    /// `NETWORK`, `RESOLUTION`, or `OTHER`.
    let classification: String
    /// The libSystem function, e.g. `connectx`.
    let call: String
    /// What was contacted, e.g. `127.0.0.1:53201` — enough to name it in a failure message.
    let detail: String

    var description: String { "\(call) → \(detail)" }
}

/// Everything one observation window recorded.
struct NetworkObservation {
    let rawLog: String
    let probeStandardOutput: String
    let probeStandardError: String

    /// Whether the shim's constructor ran in the probe process.
    ///
    /// Every zero-assertion must be guarded by this. `interposerDidLoad == false` with zero
    /// events is not a clean run; it is a run in which nothing was watching, and reporting it as
    /// a pass would be exactly the false green these tests exist to prevent.
    var interposerDidLoad: Bool {
        rawLog.split(separator: "\n").contains { $0.hasPrefix("LOADED\t") }
    }

    /// Whether the probe reported that it ran `mode` to completion.
    ///
    /// Must be asserted alongside ``interposerDidLoad``. That flag proves something was watching;
    /// this one proves there was something to watch. A probe replaced by a stub that prints a
    /// line and exits 0 satisfies neither the exit-status check nor this one.
    func probeCompleted(mode: ProbeMode) -> Bool {
        probeStandardOutput.split(separator: "\n").contains("PROBE-OK\t\(mode.rawValue)")
    }

    /// The Vocca modules the probe reported driving in `defaultConfiguration` mode.
    ///
    /// The probe derives these from type metadata (`String(reflecting:)` on a placeholder type
    /// yields `Module.Type`), so a name cannot appear here unless a type from that module was
    /// genuinely referenced.
    var reportedModules: Set<String> {
        for line in probeStandardOutput.split(separator: "\n") where line.hasPrefix("PROBE-MODULES\t") {
            let payload = line.dropFirst("PROBE-MODULES\t".count)
            return Set(payload.split(separator: ",").map(String.init))
        }
        return []
    }

    /// The activation policy the probe *observed* after calling `AppBootstrap.configure(_:)`, or
    /// `nil` if the probe never reported one.
    ///
    /// This is an effect, not a reference, and the distinction is the whole point. `VoccaBootstrap`
    /// appearing in ``reportedModules`` only proves a type from it was mentioned — deleting the
    /// `configure(_:)` call while keeping `AppBootstrap.self` in the placeholder list left the
    /// suite 2/2 green. Requiring an observed `accessory` here means the call has to have actually
    /// run and actually worked.
    ///
    /// It also removes the cheap way out of a headless-CI failure: if `NSApplication.shared` ever
    /// fails on a runner, deleting the call is a one-line change that would otherwise go green.
    var reportedActivationPolicy: String? {
        for line in probeStandardOutput.split(separator: "\n")
        where line.hasPrefix("PROBE-BOOTSTRAP\tactivationPolicy=") {
            return String(line.dropFirst("PROBE-BOOTSTRAP\tactivationPolicy=".count))
        }
        return nil
    }

    /// What the probe *observed* after driving one complete session through the real
    /// `SessionMachine` and `SessionWatchdog`, or `nil` if the probe never reported one.
    ///
    /// The second effect-not-reference post-condition, and it exists for the same reason as
    /// ``reportedActivationPolicy``. `VoccaCore` appearing in ``reportedModules`` proves only that a
    /// type from it was named — while the module was a placeholder that was all there was to prove,
    /// and it no longer is. This payload is a line of `key=value` fields the probe can only produce
    /// by running the machine: the outcome the custody funnel returned, the buffer it carried, the
    /// microphone ledger, the elapsed time the watchdog's wakes accumulated, and the schedule the
    /// watchdog derived. Deleting the drive takes the whole line with it and the assertion fails on
    /// `nil`.
    var reportedSessionLifecycle: String? {
        for line in probeStandardOutput.split(separator: "\n")
        where line.hasPrefix("PROBE-SESSION\t") {
            return String(line.dropFirst("PROBE-SESSION\t".count))
        }
        return nil
    }

    var events: [ObservedNetworkEvent] {
        rawLog.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 4, fields[0] == "EVENT" else { return nil }
            return ObservedNetworkEvent(
                classification: String(fields[1]),
                call: String(fields[2]),
                detail: fields[3...].joined(separator: "\t"))
        }
    }

    /// Outbound AF_INET / AF_INET6 traffic. This is what the invariant asserts to be empty.
    var networkConnections: [ObservedNetworkEvent] {
        events.filter { $0.classification == "NETWORK" }
    }
    var networkConnectionCount: Int { networkConnections.count }
    var networkConnectionDescriptions: [String] { networkConnections.map(\.description) }

    /// Hostname lookups, counted separately: a DNS query leaves the machine on its own.
    var nameResolutions: [ObservedNetworkEvent] {
        events.filter { $0.classification == "RESOLUTION" }
    }
    var nameResolutionCount: Int { nameResolutions.count }
    var nameResolutionDescriptions: [String] { nameResolutions.map(\.description) }

    /// Recorded but never asserted on: AF_UNIX and friends, plus unconnected IP sockets.
    var otherEvents: [ObservedNetworkEvent] {
        events.filter { $0.classification == "OTHER" }
    }

    /// Attached to every assertion so a failure explains itself without a second run.
    var diagnosticSummary: String {
        var lines: [String] = []
        lines.append("--- network interposer diagnostics ---")
        lines.append("interposer loaded: \(interposerDidLoad)")
        lines.append("NETWORK events:    \(networkConnectionCount)")
        lines.append("RESOLUTION events: \(nameResolutionCount)")
        lines.append("OTHER events:      \(otherEvents.count)")
        if !events.isEmpty {
            lines.append("all observed calls:")
            for event in events {
                lines.append("  [\(event.classification)] \(event.description)")
            }
        }
        let out = probeStandardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = probeStandardError.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("probe stdout: \(out.isEmpty ? "(empty)" : out)")
        lines.append("probe stderr: \(err.isEmpty ? "(empty)" : err)")
        lines.append("--------------------------------------")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Errors

enum NetworkInterposerError: Error, CustomStringConvertible {
    case artifactNotFound(name: String, searchedIn: [String])
    case couldNotCreateLog(String)
    case probeTimedOut(mode: ProbeMode, seconds: TimeInterval)

    var description: String {
        switch self {
        case .artifactNotFound(let name, let searched):
            return """
                Could not find the build artifact '\(name)'. It is built because the HarnessTests \
                target depends on it, so this usually means the package layout changed. \
                Searched: \(searched.joined(separator: ", "))
                """
        case .couldNotCreateLog(let path):
            return "Could not create the interposer log file at \(path)"
        case .probeTimedOut(let mode, let seconds):
            return "VoccaNetworkProbe did not exit within \(seconds)s in mode '\(mode.rawValue)'"
        }
    }
}

// MARK: - Locating the built artifacts

/// Anchors `Bundle(for:)` so the products directory is derived from where this test bundle
/// actually is, rather than from a hardcoded `.build/debug` path. That keeps it correct under
/// `--configuration release` and a custom `--scratch-path`.
private final class BundleAnchor {}

private struct BuildArtifacts {
    let shim: URL
    let probe: URL

    static func locate() throws -> BuildArtifacts {
        let productsDirectory = Bundle(for: BundleAnchor.self).bundleURL
            .deletingLastPathComponent()
        let searched = [productsDirectory.path]

        let shim = productsDirectory.appendingPathComponent("lib_VoccaNetworkInterposerTestFixture.dylib")
        guard FileManager.default.isReadableFile(atPath: shim.path) else {
            throw NetworkInterposerError.artifactNotFound(
                name: "lib_VoccaNetworkInterposerTestFixture.dylib", searchedIn: searched)
        }
        let probe = productsDirectory.appendingPathComponent("VoccaNetworkProbe")
        guard FileManager.default.isExecutableFile(atPath: probe.path) else {
            throw NetworkInterposerError.artifactNotFound(
                name: "VoccaNetworkProbe", searchedIn: searched)
        }
        return BuildArtifacts(shim: shim, probe: probe)
    }
}
