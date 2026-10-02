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

/// **The seam for "what is this process's working directory right now"** — the focused
/// application's cwd via libproc, taken out of the adapter so resolution is headless-testable
/// over an injected closure (the `AgentCLIDetection` shape: a pure mapping over an injected
/// system read).
///
/// Answer the question **now**, every time — the working directory is a fact that changes
/// under Vocca's feet with no notification, and a cached answer would be a report of the
/// world as it was at some earlier resolution.
///
/// Synchronous, for the reason ``ContextAXReading`` is: the exposure it feeds —
/// ``AccessibilityContext``'s `workingDirectory()` — is synchronous (the metadata lane's
/// witness shape, `working-directory-source` spec R1). The real read is a single libproc
/// syscall; nothing here spawns, connects or provisions.
///
/// ## The never-throw doctrine
///
/// Any failure — a pid that cannot exist, a process whose path the kernel will not report, a
/// C string that did not terminate — answers `nil`, never a throw (R1). The honest fact is
/// "no working directory to report", and a caller that distinguishes the failure modes has
/// missed the point: the metadata lane's answer is a `String?`.
///
/// ## Naming (the file's own contract)
///
/// This file names no AX prefix, no FileManager identifier, and no `Process`-prefixed
/// identifier (the transport lint's deliberate prefix family, `ActionTransportProhibitionTests`
/// — the repo discipline extends the naming rule here even though that lint scans
/// `VoccaActions` only): the seam's vocabulary is the pid and the path, and nothing else.
public enum WorkingDirectoryRead {

    /// Resolve `pid`'s working directory through the injected libproc read.
    ///
    /// The seam's only observable side effect is the closure call — `libprocRead(pid)`, once,
    /// nothing else — which is exactly what makes it headless-testable with a recording fake
    /// (`WorkingDirectoryReadTests` pins the call shape). In the shipped composition the
    /// closure is ``libprocCwd``, wired by ``AccessibilityContext``'s default.
    ///
    /// - Parameters:
    ///   - pid: The process to ask about — the focused application's pid in the shipped
    ///     composition, any pid in the suite.
    ///   - libprocRead: The seam's system read — ``libprocCwd`` in the shipped composition, a
    ///     recording fake in the suite.
    /// - Returns: The closure's answer, unchanged; `nil` when the closure answered `nil`.
    public static func resolve(
        pid: pid_t,
        libprocRead: @escaping @Sendable (pid_t) -> String?
    ) -> String? {
        libprocRead(pid)
    }

    /// The libproc adapter: one `proc_pidinfo(PROC_PIDVNODEPATHINFO)` call, the C string
    /// carried in `pvi_cdir.vip_path` (the current working directory's path — `vi_cwd`, the
    /// vnode-info half) decoded, every failure → `nil`.
    ///
    /// The one place this seam names libproc. Executed by nothing in CI on its success path
    /// (a real process with a reportable path is a machine fact, not a hosted-runner one —
    /// the ``AXContextSource`` posture); the **failure** path runs in CI, deterministically
    /// and grant-free: a pid that cannot exist answers `nil` (`WorkingDirectoryReadTests`),
    /// which is the whole of the never-throw doctrine a headless runner can reach.
    public static func libprocCwd(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
            return nil
        }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
}