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

import Darwin
import Foundation
import VoccaASR
import VoccaAudio
import VoccaCore
import VoccaHotkey
import VoccaInject
import VoccaSpeech
import VoccaText
import VoccaUI

/// Test fixture for `ZeroNetworkTests`. It exists as a separate executable because the network
/// interposer is delivered with `DYLD_INSERT_LIBRARIES`, and the `xctest` host that runs the
/// suite is an Apple-signed hardened binary that strips that variable — so the code being
/// observed has to live in a process we launch ourselves.
///
/// This is deliberately *not* a package product: it ships nothing and is built only because the
/// test target depends on it.
@main
struct VoccaNetworkProbe {

    /// Default time to keep the process alive after the default-configuration path returns,
    /// before declaring the run complete.
    ///
    /// **This is the difference between the invariant catching real egress and missing it.**
    /// Almost nothing Vocca will do is synchronous — audio-engine start-up, ASR model loading and
    /// TTS warm-up all kick off work and return immediately. Without a settle window, a
    /// fire-and-forget `URLSession.shared.dataTask(...).resume()` in the default path exits with
    /// the probe before the connection is ever attempted, and the test reports a clean run.
    ///
    /// 0.75s is comfortably more than an order of magnitude above the ~10–20 ms a loopback
    /// `connectx` takes to appear, with headroom for a cold first use of the URL loading system,
    /// while keeping local iteration fast.
    ///
    /// It remains a **floor, not a proof of quiescence** — egress deferred past the window is
    /// still missed, and the honest fix for slow work is for the mode that starts it to await it
    /// explicitly. But the failure direction is a false *green*, which is the dangerous one, and
    /// a loaded CI machine can push work that normally lands at 0.3s well past this. So the
    /// window is overridable via ``settleEnvironmentVariable`` and the harness raises it
    /// substantially on CI, where wall-clock cost matters far less than a missed connection.
    private static let defaultSettleWindow: TimeInterval = 0.75

    /// Overrides ``defaultSettleWindow``, in seconds. Set by the test harness.
    private static let settleEnvironmentVariable = "VOCCA_PROBE_SETTLE_SECONDS"

    /// The work the probe knows how to do.
    ///
    /// Modelled as an enum rather than matched as a string so that ``needsSettle`` is decided by
    /// an exhaustive `switch`. Adding a mode then fails to compile until someone states whether
    /// it needs a settle window — where a string comparison would have silently given a new mode
    /// none, which is the same fail-open shape the settle window was added to remove.
    private enum Mode: String {
        case defaultConfiguration = "default-configuration"
        case deliberateConnect = "deliberate-connection"
        case deliberateConnectx = "deliberate-connectx"

        /// Whether deferred egress is possible in this mode, and so whether the process must be
        /// held open after the work returns.
        var needsSettle: Bool {
            switch self {
            case .defaultConfiguration:
                // Arbitrary product code, nearly all of it asynchronous. This is the whole reason
                // the window exists.
                return true
            case .deliberateConnect, .deliberateConnectx:
                // One synchronous connection, recorded before the call returns. A window here
                // buys nothing and only slows the suite down.
                return false
            }
        }
    }

    static func main() {
        let rawMode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
        guard let mode = Mode(rawValue: rawMode) else {
            fputs("PROBE-UNKNOWN-MODE\t\(rawMode)\n", stderr)
            exit(64)
        }

        switch mode {
        case .defaultConfiguration:
            let modules = exerciseDefaultConfiguration()
            // Reported so the test can assert every module in the package was actually driven
            // through here, rather than trusting a comment to stay true.
            print("PROBE-MODULES\t\(modules.joined(separator: ","))")
        case .deliberateConnect:
            guard exerciseDeliberateConnect() else {
                fputs("PROBE-FAILED\t\(mode.rawValue)\terrno=\(errno)\n", stderr)
                exit(2)
            }
        case .deliberateConnectx:
            guard exerciseDeliberateConnectx() else {
                fputs("PROBE-FAILED\t\(mode.rawValue)\terrno=\(errno)\n", stderr)
                exit(2)
            }
        }

        if mode.needsSettle {
            settle(for: settleWindow())
        }

        // Asserted by both tests. Without checking it, a probe that did nothing at all — or a
        // stub that printed one line and exited 0 — is indistinguishable from a clean run.
        print("PROBE-OK\t\(mode.rawValue)")
        exit(0)
    }

    /// The shortest override that is accepted.
    ///
    /// Zero — "settle for no time at all" — is rejected along with negatives and garbage. It
    /// parses cleanly, so it would sail through a naive check while disabling the window
    /// entirely: a fail-open value in a knob whose entire purpose is to fail closed. The floor is
    /// an order of magnitude above the ~10–20 ms a loopback `connectx` takes to appear, so any
    /// accepted value still leaves the window doing its job.
    private static let minimumSettleWindow: TimeInterval = 0.25

    /// ``defaultSettleWindow``, unless the harness overrode it.
    ///
    /// A missing, unparseable, or too-short override is fatal rather than ignored. Quietly
    /// falling back to the default would mean a CI job that believed it was running a long window
    /// silently ran a short one — the exact false-green this override exists to prevent.
    private static func settleWindow() -> TimeInterval {
        guard let raw = ProcessInfo.processInfo.environment[settleEnvironmentVariable] else {
            return defaultSettleWindow
        }
        guard let seconds = TimeInterval(raw), seconds >= minimumSettleWindow else {
            fputs(
                "PROBE-BAD-SETTLE\t\(settleEnvironmentVariable)=\(raw)\tminimum=\(minimumSettleWindow)\n",
                stderr)
            exit(65)
        }
        return seconds
    }

    /// Keeps the process alive, and the main run loop pumping, for ``settleWindow``.
    ///
    /// The deadline loop — not the run loop — is what guarantees the duration:
    /// `RunLoop.run(mode:before:)` returns immediately when no input source is attached, so
    /// `runUntilDate:` alone cannot be relied on to wait.
    ///
    /// The keep-alive timer supplies that source, and is not decoration. Measured on this
    /// machine, the probe takes 0.76s wall with the timer attached and 1.61s without, because
    /// with no source the loop degenerates into a busy-spin that burns a core and never actually
    /// services anything. Running the loop rather than sleeping the thread is what lets work
    /// scheduled onto the main queue or onto a `CFRunLoop` source execute at all.
    private static func settle(for seconds: TimeInterval) {
        guard seconds > 0 else { return }
        let deadline = Date().addingTimeInterval(seconds)
        let keepAlive = Timer(timeInterval: 0.05, repeats: true) { _ in }
        RunLoop.current.add(keepAlive, forMode: .default)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: deadline)
        }
        keepAlive.invalidate()
    }

    // MARK: - The invariant path

    /// Exercises everything Vocca does in its default configuration, and returns the names of the
    /// modules it drove.
    ///
    /// **This function is the scope of the zero-network guarantee — keep it honest.** The
    /// assertion in `testDefaultConfigurationMakesZeroNetworkConnections` only covers code that
    /// actually runs here. Today the modules are placeholders, so all this can do is link every
    /// one of them and force each to load. As capabilities land (audio capture, ASR model
    /// loading, TTS, injection, the default text-cleanup pipeline), their default-configuration
    /// start-up work must be invoked from here.
    ///
    /// That instruction is enforced rather than merely written down: the returned module list is
    /// checked against the package manifest and the `Sources/` listing, so adding any module
    /// without driving it from here fails the suite — whatever the module is called. The enforcement is at module granularity —
    /// it can tell that a module was reached, not that a module's *work* was exercised — so
    /// growing the body below as capabilities land is still a judgement call this test can
    /// prompt but cannot make.
    private static func exerciseDefaultConfiguration() -> [String] {
        let placeholders: [Any.Type] = [
            VoccaCorePlaceholder.self,
            VoccaAudioPlaceholder.self,
            VoccaHotkeyPlaceholder.self,
            VoccaASRPlaceholder.self,
            VoccaTextPlaceholder.self,
            VoccaInjectPlaceholder.self,
            VoccaSpeechPlaceholder.self,
            VoccaUIPlaceholder.self,
        ]
        // `String(reflecting:)` on a metatype yields "ModuleName.TypeName", so each module name is
        // derived from the type itself rather than written out by hand. A module cannot be
        // reported as covered without a real type from it being referenced here.
        return placeholders.compactMap { placeholder in
            String(reflecting: placeholder).split(separator: ".").first.map(String.init)
        }
    }

    // MARK: - The positive-control paths

    /// Binds a `SOCK_STREAM` listener on `127.0.0.1` with a kernel-assigned port, then reaches it
    /// with `connect(2)`. Deterministic, DNS-free, and works offline — a positive control must
    /// never be able to fail because a network was unavailable.
    private static func exerciseDeliberateConnect() -> Bool {
        withLoopbackListener { destination in
            let clientFD = socket(AF_INET, SOCK_STREAM, 0)
            guard clientFD >= 0 else { return false }
            defer { close(clientFD) }
            return connect(clientFD, destination, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }

    /// The same connection, made with `connectx(2)` instead.
    ///
    /// This mode exists because `connectx` — not `connect` — is the call `URLSession` and
    /// `Network.framework` actually reach the kernel through, which makes it the single most
    /// important hook in the interposer for real-world egress. Reaching it directly with a raw
    /// socket keeps the positive control DNS-free, offline-safe, and free of any CFNetwork
    /// linkage, so the coverage costs this package no networking surface.
    private static func exerciseDeliberateConnectx() -> Bool {
        withLoopbackListener { destination in
            let clientFD = socket(AF_INET, SOCK_STREAM, 0)
            guard clientFD >= 0 else { return false }
            defer { close(clientFD) }
            var endpoints = sa_endpoints_t()
            endpoints.sae_srcif = 0
            endpoints.sae_srcaddr = nil
            endpoints.sae_srcaddrlen = 0
            endpoints.sae_dstaddr = destination
            endpoints.sae_dstaddrlen = socklen_t(MemoryLayout<sockaddr_in>.size)
            return connectx(clientFD, &endpoints, 0, 0, nil, 0, nil, nil) == 0
        }
    }

    /// Stands up a loopback listener on a kernel-assigned port and hands `body` a pointer to its
    /// address, valid for the duration of the call.
    private static func withLoopbackListener(
        _ body: (UnsafePointer<sockaddr>) -> Bool
    ) -> Bool {
        let listenerFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenerFD >= 0 else { return false }
        defer { close(listenerFD) }

        var bindAddress = loopbackAddress(port: 0)
        let didBind = withUnsafePointer(to: &bindAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenerFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard didBind, listen(listenerFD, 1) == 0 else { return false }

        var assigned = sockaddr_in()
        var assignedSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        let didReadBack = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenerFD, $0, &assignedSize) == 0
            }
        }
        guard didReadBack else { return false }

        var destination = loopbackAddress(port: assigned.sin_port)
        return withUnsafePointer(to: &destination) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0) }
        }
    }

    /// `port` is in network byte order, matching `sockaddr_in.sin_port`.
    private static func loopbackAddress(port: in_port_t) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        return address
    }
}
