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
// Phase 1 drives the module's CI-safe stub surface: construct `StubContextReads` and perform
// the module's one read. The witness is minted *by* the call — `type(of: raw)` on the answer
// the read returned — so the `VoccaContext` entry in the probe's coverage list cannot outlive
// the call it stands for, exactly as the other drives' witnesses work.
//
// ## What this drive does not do
//
// It does **not** perform a real context resolution: that needs the AX adapter, which lands in
// Phase 3. The stub answers the empty read, which is also the honest shape of a real read in CI
// (no Accessibility grant → the AX calls answer failure → the empty snapshot), so the report's
// field vocabulary is the Phase-3 report's already.

extension VoccaNetworkProbe {

    /// One pass over the module's default-configuration surface, and the post-condition the
    /// coverage list reads.
    struct ContextDrive {
        /// The observation, as one line of `key=value` fields.
        let report: String

        /// A type minted **by this drive**, from which `VoccaContext`'s name is derived for the
        /// coverage list — the answer of the read this drive performed, never a type literal.
        let moduleWitness: Any.Type
    }

    /// **Drives the context module's default-configuration surface, and reports what happened.**
    ///
    /// Nothing here asserts. The probe reports and the suite asserts, for the reason every other
    /// drive gives: an assertion living in the observed process can be deleted by the same edit
    /// that breaks what it observes, and its failure would arrive as an exit status rather than
    /// as a named expectation.
    static func exerciseContext() -> ContextDrive {
        let stub = StubContextReads()
        let raw = stub.readContext()
        // `type(of:)` on the optional answer would report `Swift.Optional<...>` — the witness
        // must be the module's own type, so the empty answer stands in for `nil` (the same
        // value the report reads).
        let answer = raw ?? RawContextRead(bundleID: nil, windowTitle: nil, selectedText: nil)
        return ContextDrive(
            report: [
                "bundleID=\(answer.bundleID ?? "nil")",
                "windowTitle=\(answer.windowTitle ?? "nil")",
                "selectedText=\(answer.selectedText ?? "nil")",
            ].joined(separator: " "),
            moduleWitness: type(of: answer))
    }
}