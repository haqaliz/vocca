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

import VoccaContext

// The probe's half of the zero-network invariant for `VoccaContext`, the module
// `ARCHITECTURE.md:151` reserves for the `ContextProvider` seam's real implementation.
//
// The drive constructs the real adapter — `AccessibilityContext` over the real `AXContextSource`
// and `ContextSecureInputRead` — and resolves once. In CI, without an Accessibility grant, the
// AX copies answer an error and the snapshot is the empty one: the drive exercises the honest
// empty path (R1) deterministically, and `AXContextSource`'s **failure path executes in CI**
// (D6, recorded in that file's doc comment). The witness is minted *by* the call —
// `type(of: context)` on the adapter this drive constructed — so the `VoccaContext` entry in
// the probe's coverage list cannot outlive the call it stands for, exactly as the other drives'
// witnesses work.
//
// ## What this drive does not do
//
// It does **not** resolve a non-empty snapshot in CI: the success path needs a grant and a real
// focused application, which stays unreachable on a hosted runner, now and ever. The report's
// fields are the empty-snapshot fields in CI; nothing asserts them, so a grant on a developer
// machine cannot flake the suite.

extension VoccaNetworkProbe {

    /// One pass over the module's default-configuration surface, and the post-condition the
    /// coverage list reads.
    struct ContextDrive {
        /// The observation, as one line of `key=value` fields.
        let report: String

        /// A type minted **by this drive**, from which `VoccaContext`'s name is derived for the
        /// coverage list — the adapter this drive constructed, never a type literal.
        let moduleWitness: Any.Type
    }

    /// **Drives the context module's default-configuration surface, and reports what happened.**
    ///
    /// Nothing here asserts. The probe reports and the suite asserts, for the reason every other
    /// drive gives: an assertion living in the observed process can be deleted by the same edit
    /// that breaks what it observes, and its failure would arrive as an exit status rather than
    /// as a named expectation.
    static func exerciseContext() -> ContextDrive {
        let context = AccessibilityContext(
            axRead: AXContextSource(),
            secureInputRead: ContextSecureInputRead())
        let snapshot = context.resolveCurrent()
        return ContextDrive(
            report: [
                "bundleID=\(snapshot.bundleID ?? "nil")",
                "windowTitle=\(snapshot.windowTitle ?? "nil")",
                "selectedText=\(snapshot.selectedText ?? "nil")",
            ].joined(separator: " "),
            moduleWitness: type(of: context))
    }
}