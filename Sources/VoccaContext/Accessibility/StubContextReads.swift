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

/// **The module's Phase-1 CI-safe stub**: a ``ContextAXReading`` and
/// ``ContextSecureInputReading`` conformance answering an empty ``RawContextRead`` and `false`
/// — every field `nil`, Secure Input inactive.
///
/// The probe's drive constructs this stub and performs the module's one read, so the
/// `VoccaContext` entry in the probe's coverage list is minted *by* a call into the module the
/// moment the target exists — before the real AX files land (Phase 3). It names no AX identifier
/// and no Carbon call, so the per-seam lint tables stay untouched until the real files replace
/// it. **Deleted when ``AXContextSource`` and ``ContextSecureInputRead`` land** — this type is
/// the module's scaffolding, never its surface.
public final class StubContextReads: ContextAXReading, ContextSecureInputReading {

    public init() {}

    /// The empty answer: nothing focused, no title, no selection.
    public func readContext() -> RawContextRead? {
        RawContextRead(bundleID: nil, windowTitle: nil, selectedText: nil)
    }

    /// Secure Input inactive — the CI-safe answer, since no other application's state is
    /// consulted.
    public func isSecureInputActive() -> Bool {
        false
    }
}