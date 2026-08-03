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

    static func main() {
        let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
        switch mode {
        case "default-configuration":
            exerciseDefaultConfiguration()
        case "deliberate-connection":
            guard exerciseDeliberateConnection() else {
                fputs("PROBE-FAILED\t\(mode)\terrno=\(errno)\n", stderr)
                exit(2)
            }
        default:
            fputs("PROBE-UNKNOWN-MODE\t\(mode)\n", stderr)
            exit(64)
        }
        // The harness treats this marker as proof the requested mode ran to completion. Without
        // it, a probe that crashed on line one would look identical to one that behaved.
        print("PROBE-OK\t\(mode)")
        exit(0)
    }

    // MARK: - The invariant path

    /// Exercises everything Vocca does in its default configuration.
    ///
    /// **This function is the scope of the zero-network guarantee — keep it honest.** The
    /// assertion in `testDefaultConfigurationMakesZeroNetworkConnections` only covers code that
    /// actually runs here. Today the modules are placeholders, so all this can do is link every
    /// one of them and force each to load. As capabilities land (audio capture, ASR model
    /// loading, TTS, injection, the default text-cleanup pipeline), their default-configuration
    /// start-up work must be invoked from here. A capability that is never driven from this
    /// function is a capability the invariant does not cover, and the test will keep passing
    /// while silently covering less and less of the product.
    private static func exerciseDefaultConfiguration() {
        let modules: [Any.Type] = [
            VoccaCorePlaceholder.self,
            VoccaAudioPlaceholder.self,
            VoccaHotkeyPlaceholder.self,
            VoccaASRPlaceholder.self,
            VoccaTextPlaceholder.self,
            VoccaInjectPlaceholder.self,
            VoccaSpeechPlaceholder.self,
            VoccaUIPlaceholder.self,
        ]
        // `String(describing:)` forces each type's metadata to be realized, so the reference
        // cannot be folded away by the optimizer and every module is genuinely loaded.
        var touched = 0
        for module in modules where !String(describing: module).isEmpty {
            touched += 1
        }
        precondition(touched == modules.count, "Failed to touch every Vocca module")
    }

    // MARK: - The positive-control path

    /// Binds a `SOCK_STREAM` listener on `127.0.0.1` with a kernel-assigned port, then connects
    /// to it. Deterministic, DNS-free, and works offline — the positive control must never be
    /// able to fail because a network was unavailable.
    private static func exerciseDeliberateConnection() -> Bool {
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

        let clientFD = socket(AF_INET, SOCK_STREAM, 0)
        guard clientFD >= 0 else { return false }
        defer { close(clientFD) }

        var target = loopbackAddress(port: assigned.sin_port)
        let didConnect = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(clientFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        return didConnect
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
