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

import VoccaConversation

// The probe's half of the zero-network invariant for `VoccaConversation`, the adapter module
// the `history-store` aspect reserves for the conversation store — and the third instance of
// the D1 rule (`plan_20261011.md`): a module, not a folder in `VoccaBootstrap`, because rooting
// a FileManager seam in the composition root would force permitting `AppBootstrap.swift`.
//
// ## Phase 1: the scaffold drive
//
// Adding a `.library` product made `VoccaConversation` a shipping target, which
// `ZeroNetworkTests`' `modulesRequiringCoverage` requires the probe to witness and
// `justifiedExclusions` refuses to let anyone exclude. Phase 1 drives the module's target
// scaffold: the store type exists and compiles, and the witness is taken from the store this
// drive constructed — the `ContextDrive` Phase-1 shape (a stub surface, a witness minted *by*
// the call, so the `VoccaConversation` coverage entry cannot outlive the call that stands for
// it).
//
// ## What this drive does not do (yet)
//
// It does **not** run the store's round trip: the seam, the caps, the atomic commit and the
// `ConversationRecording` conformance land in Phase 2, which rewrites this drive to run them —
// a launch-shaped load, a record, a reload and a clear, over a temporary directory, never the
// location a real install keeps its conversation.

extension VoccaNetworkProbe {

    /// One pass over the module's default-configuration surface, and the post-condition the
    /// coverage list reads.
    struct ConversationDrive {
        /// The observation, as one line of `key=value` fields.
        let report: String

        /// A type minted **by this drive**, from which `VoccaConversation`'s name is derived
        /// for the coverage list — the store this drive constructed, never a type literal.
        let moduleWitness: Any.Type
    }

    /// **Drives the conversation module's Phase-1 scaffold, and reports what happened.**
    ///
    /// Nothing here asserts. The probe reports and the suite asserts, for the reason every other
    /// drive gives: an assertion living in the observed process can be deleted by the same edit
    /// that breaks what it observes, and its failure would arrive as an exit status rather than
    /// as a named expectation.
    static func exerciseConversation() -> ConversationDrive {
        let store = ConversationHistoryStore()
        return ConversationDrive(
            report: "phase=scaffold",
            moduleWitness: type(of: store))
    }
}